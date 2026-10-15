#!/usr/bin/env bash
# =============================================================================
# Desplegament autom脿tic de FreeScout (nfrastack/freescout) + MariaDB + Traefik
# HTTPS autom脿tic amb Let's Encrypt via Cloudflare DNS-01 (token d'API).
#
# 脷s:
#   sudo ./deploy-freescout.sh             # instal路la o actualitza (idempotent)
#   sudo ./deploy-freescout.sh --update    # nom茅s actualitza imatges i reinicia
#   sudo ./deploy-freescout.sh --reconfigure  # torna a demanar domini/token
#   sudo ./deploy-freescout.sh --status
# =============================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/freescout}"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

c_info="\033[1;34m"; c_ok="\033[1;32m"; c_err="\033[1;31m"; c_off="\033[0m"
info() { echo -e "${c_info}[*]${c_off} $*"; }
ok()   { echo -e "${c_ok}[鉁揮${c_off} $*"; }
die()  { echo -e "${c_err}[鉁梋${c_off} $*" >&2; exit 1; }

# ---------------------------------------------------------------- prerequisits
[[ $EUID -eq 0 ]] || die "Executa'l com a root: sudo $0"
[[ -r /etc/os-release ]] && . /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *ubuntu* || "${ID_LIKE:-}" == *debian* ]] \
  || die "Aquest script est脿 pensat per a Ubuntu/Debian."

MODE="install"
case "${1:-}" in
  --update) MODE="update" ;;
  --reconfigure) MODE="reconfigure" ;;
  --status) MODE="status" ;;
  "" ) ;;
  *) die "Opci贸 desconeguda: $1" ;;
esac

install_docker() {
  info "Docker no trobat. Instal路lant Docker Engine + Compose plugin..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg openssl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_compose_binary() {
  local arch; arch="$(uname -m)"
  local dest=/usr/local/lib/docker/cli-plugins
  info "Descarregant docker compose (binari oficial)..."
  install -m 0755 -d "$dest"
  curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}"     -o "$dest/docker-compose" || return 1
  chmod +x "$dest/docker-compose"
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    install_docker
  else
    ok "Docker ja instal路lat: $(docker --version)"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    info "Falta el plugin 'docker compose'. Instal穕ant..."
    apt-get update -y || true
    # 1) repo oficial de Docker, 2) paquet d'Ubuntu, 3) binari oficial de GitHub
    apt-get install -y docker-compose-plugin       || apt-get install -y docker-compose-v2       || install_compose_binary
    docker compose version >/dev/null 2>&1 || die "No s'ha pogut instal穕ar 'docker compose'."
  fi
  command -v openssl >/dev/null 2>&1 || { apt-get update -y; apt-get install -y openssl; }
  systemctl is-active --quiet docker || systemctl enable --now docker
}

# ---------------------------------------------------------------- configuraci贸
rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }

load_env() { [[ -f "$ENV_FILE" ]] && set -a && . "$ENV_FILE" && set +a || true; }

ask() { # ask VAR "pregunta" [secret]
  local var="$1" prompt="$2" secret="${3:-}" val=""
  while [[ -z "$val" ]]; do
    if [[ -n "$secret" ]]; then read -r -s -p "$prompt: " val </dev/tty; echo
    else read -r -p "$prompt: " val </dev/tty; fi
  done
  printf -v "$var" '%s' "$val"
}

configure() {
  mkdir -p "$INSTALL_DIR"
  load_env

  if [[ "$MODE" == "reconfigure" || -z "${DOMAIN:-}" ]]; then
    ask DOMAIN "Nom de domini (p.ex. suport.exemple.com)"
  fi
  if [[ "$MODE" == "reconfigure" || -z "${CF_DNS_API_TOKEN:-}" ]]; then
    echo "Token d'API de Cloudflare amb permisos: Zone:DNS:Edit + Zone:Zone:Read"
    ask CF_DNS_API_TOKEN "Token de Cloudflare" secret
  fi
  if [[ "$MODE" == "reconfigure" || -z "${ACME_EMAIL:-}" ]]; then
    ask ACME_EMAIL "Email per a Let's Encrypt"
  fi
  if [[ "$MODE" == "reconfigure" || -z "${ADMIN_EMAIL:-}" ]]; then
    ADMIN_EMAIL="$ACME_EMAIL"
  fi

  # Secrets: es generen una sola vegada i es conserven en actualitzacions
  DB_PASS="${DB_PASS:-$(rand 28)}"
  DB_ROOT_PASS="${DB_ROOT_PASS:-$(rand 28)}"
  ADMIN_PASS="${ADMIN_PASS:-$(rand 20)}"
  FREESCOUT_TAG="${FREESCOUT_TAG:-latest}"
  TZ_NAME="${TZ_NAME:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

  umask 077
  cat > "$ENV_FILE" <<EOF
DOMAIN=$DOMAIN
CF_DNS_API_TOKEN=$CF_DNS_API_TOKEN
ACME_EMAIL=$ACME_EMAIL
ADMIN_EMAIL=$ADMIN_EMAIL
ADMIN_PASS=$ADMIN_PASS
DB_PASS=$DB_PASS
DB_ROOT_PASS=$DB_ROOT_PASS
FREESCOUT_TAG=$FREESCOUT_TAG
TZ_NAME=$TZ_NAME
EOF
  chmod 600 "$ENV_FILE"
  umask 022
}

write_compose() {
  cat > "$COMPOSE_FILE" <<'EOF'
services:
  traefik:
    image: traefik:v3
    container_name: freescout-traefik
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --certificatesresolvers.cf.acme.email=${ACME_EMAIL}
      - --certificatesresolvers.cf.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.cf.acme.dnschallenge=true
      - --certificatesresolvers.cf.acme.dnschallenge.provider=cloudflare
      - --certificatesresolvers.cf.acme.dnschallenge.resolvers=1.1.1.1:53,1.0.0.1:53
    environment:
      - CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_letsencrypt:/letsencrypt
    networks: [freescout]

  freescout:
    image: docker.io/nfrastack/freescout:${FREESCOUT_TAG}
    container_name: freescout-app
    restart: unless-stopped
    depends_on:
      freescout-db:
        condition: service_healthy
    environment:
      - TIMEZONE=${TZ_NAME}
      - CONTAINER_ENABLE_MONITORING=FALSE
      - DB_TYPE=mysql
      - DB_HOST=freescout-db
      - DB_PORT=3306
      - DB_NAME=freescout
      - DB_USER=freescout
      - DB_PASS=${DB_PASS}
      - APP_URL=https://${DOMAIN}
      - SETUP_TYPE=AUTO
      - ADMIN_EMAIL=${ADMIN_EMAIL}
      - ADMIN_PASS=${ADMIN_PASS}
      - ENABLE_AUTO_UPDATE=TRUE
      - SCHEDULER_TYPE=service
      - FREESCOUT_APP_PROXY=*
      - FREESCOUT_APP_TRUSTED_PROXIES=*
      - FREESCOUT_APP_FORCE_HTTPS=true
      - FREESCOUT_APP_TIMEZONE=${TZ_NAME}
    volumes:
      - freescout_data:/data
      - freescout_logs:/logs
    labels:
      - traefik.enable=true
      - traefik.docker.network=freescout_freescout
      - traefik.http.routers.freescout.rule=Host(`${DOMAIN}`)
      - traefik.http.routers.freescout.entrypoints=websecure
      - traefik.http.routers.freescout.tls.certresolver=cf
      - traefik.http.services.freescout.loadbalancer.server.port=80
    networks: [freescout]

  freescout-db:
    image: mariadb:lts
    container_name: freescout-db
    restart: unless-stopped
    environment:
      - MYSQL_ROOT_PASSWORD=${DB_ROOT_PASS}
      - MYSQL_DATABASE=freescout
      - MYSQL_USER=freescout
      - MYSQL_PASSWORD=${DB_PASS}
    volumes:
      - freescout_db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 20
    networks: [freescout]

networks:
  freescout:

volumes:
  traefik_letsencrypt:
  freescout_data:
  freescout_logs:
  freescout_db:
EOF
}

deploy() {
  cd "$INSTALL_DIR"
  info "Descarregant imatges (pull)..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p freescout pull
  info "Aixecant serveis..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p freescout up -d --remove-orphans
  docker image prune -f >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- execuci贸
if [[ "$MODE" == "status" ]]; then
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p freescout ps
  exit 0
fi

ensure_docker

if [[ "$MODE" == "update" ]]; then
  [[ -f "$ENV_FILE" && -f "$COMPOSE_FILE" ]] || die "No hi ha cap instal路laci贸 a $INSTALL_DIR. Executa sense --update."
  deploy
  ok "Actualitzat."
  exit 0
fi

configure
write_compose
deploy

load_env
echo
ok "FreeScout desplegat."
echo "  URL:       https://$DOMAIN   (el certificat i la 1a c脿rrega poden trigar 2-5 min)"
echo "  Admin:     $ADMIN_EMAIL"
echo "  Password:  $ADMIN_PASS"
echo "  Config:    $ENV_FILE (permisos 600)"
echo
echo "Recorda: al DNS de Cloudflare, crea un registre A de $DOMAIN cap a la IP d'aquest servidor"
echo "Actualitzar:  sudo $0 --update"
