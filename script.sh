#!/bin/bash
#
# Script de configuración automática de VPS
# - Swap file (1G)
# - Nginx como reverse proxy (stream/SNI)
# - Docker + x-ui
# Uso: sudo bash setup-vps.sh
#

set -euo pipefail

# ─── Colores ─────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✔]${NC} $*"; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✘]${NC} $*" >&2; }

# ─── Verificar root ──────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "Este script debe ejecutarse como root (usa sudo)."
    exit 1
fi

info "Iniciando configuración del VPS..."
sleep 1

# ─── 1. Actualizar sistema ───────────────────────────────
log "Actualizando paquetes del sistema..."
apt update -y && apt upgrade -y

# ─── 2. Instalar dependencias ────────────────────────────
log "Instalando nginx, libnginx-mod-stream, curl, iptables y wget..."
apt install -y nginx libnginx-mod-stream curl iptables wget

# ─── 3. Configurar Swap ──────────────────────────────────
SWAP_SIZE="1G"
SWAP_PATH="/swapfile"

if swapon --show | grep -q "$SWAP_PATH"; then
    warn "Swap ya activo en $SWAP_PATH. Omitiendo."
elif grep -qE "^\s*${SWAP_PATH}\s" /etc/fstab 2>/dev/null; then
    warn "$SWAP_PATH ya está en /etc/fstab pero no activo. Activando..."
    swapon "$SWAP_PATH" || error "No se pudo activar el swap existente."
else
    log "Configurando swap de $SWAP_SIZE en $SWAP_PATH..."

    # Descargar script oficial de swap
    wget -q https://raw.githubusercontent.com/Cretezy/Swap/master/swap.sh -O /tmp/swap.sh

    # Ejecutarlo con el tamaño y ruta deseados
    sh /tmp/swap.sh "$SWAP_SIZE" "$SWAP_PATH"

    # Ajustar swappiness para servidores (opcional pero recomendado)
    if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
        sysctl -p >/dev/null
        info "vm.swappiness ajustado a 10."
    fi

    # Limpiar
    rm -f /tmp/swap.sh

    log "Swap configurado correctamente."
fi

# Mostrar estado del swap
info "Estado del swap:"
swapon --show || true
free -h | grep -i swap || true

# ─── 4. Instalar Docker ──────────────────────────────────
if command -v docker &>/dev/null; then
    warn "Docker ya está instalado. Omitiendo."
else
    log "Instalando Docker..."
    curl -fsSL https://get.docker.com | sh
fi

# ─── 5. Configurar nginx.conf ────────────────────────────
log "Escribiendo /etc/nginx/nginx.conf..."

# Backup del original
if [[ ! -f /etc/nginx/nginx.conf.bak ]]; then
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    info "Backup creado en /etc/nginx/nginx.conf.bak"
fi

cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;

include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

stream {

    upstream oxxo {
        server 127.0.0.1:8443;
    }

    upstream telcel {
        server 127.0.0.1:7443;
    }

    map $ssl_preread_server_name $backend {
        www.freedompop.mx      oxxo;
        freedompop.mx          oxxo;

        pbs.twimg.com          telcel;
        video.twimg.com        telcel;
        www.twitter.com        telcel;
        analytics.twitter.com  telcel;

        default                oxxo;
    }

    server {
        listen 443 reuseport;
        proxy_pass $backend;
        ssl_preread on;
    }
}

http {

    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    access_log /var/log/nginx/access.log;

    gzip on;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# ─── 6. Validar y reiniciar nginx ────────────────────────
log "Validando configuración de nginx..."
if nginx -t; then
    log "Reiniciando nginx..."
    systemctl restart nginx
    systemctl enable nginx
else
    error "Configuración de nginx inválida. Abortando."
    exit 1
fi

# ─── 7. Limpiar reglas de iptables ───────────────────────
log "Restableciendo iptables (ACCEPT + flush)..."
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -t raw -F
iptables -t raw -X

# Persistir reglas si está disponible
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save || true
elif command -v iptables-save &>/dev/null; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 || true
fi

# ─── 8. Detener x-ui previo si existe ────────────────────
if docker ps -a --format '{{.Names}}' | grep -q '^x-ui$'; then
    warn "Contenedor x-ui ya existe. Deteniéndolo y eliminándolo..."
    docker stop x-ui || true
    docker rm x-ui || true
fi

# ─── 9. Crear directorios necesarios ─────────────────────
log "Preparando directorios para x-ui..."
mkdir -p "$PWD/db" "$PWD/cert"

# ─── 10. Levantar x-ui ───────────────────────────────────
log "Levantando contenedor x-ui..."
docker run -itd --network=host \
    -v "$PWD/db/:/etc/x-ui/" \
    -v "$PWD/cert/:/root/cert/" \
    --name x-ui --restart=unless-stopped \
    ghcr.io/alireza0/x-ui:v1.11.3

# ─── 11. Resumen final ───────────────────────────────────
echo
log "=========================================="
log " Configuración completada con éxito"
log "=========================================="
echo
info "Estado de nginx:      $(systemctl is-active nginx)"
info "Estado de docker:     $(systemctl is-active docker)"
info "Contenedor x-ui:      $(docker ps --filter name=x-ui --format '{{.Status}}')"
info "Swap:                 $(swapon --show=NAME,SIZE --noheadings | tr -s ' ' | tr '\n' ' ')"
echo
warn "Accede a x-ui en: http://<IP_DEL_VPS>:2053 (por defecto)"
warn "Credenciales por defecto: admin / admin  → ¡CÁMBIALAS!"
echo
info "Backup de nginx.conf original: /etc/nginx/nginx.conf.bak"
echo
