#!/usr/bin/env bash
# =============================================================================
# Desplegament automàtic de FreeScout (nfrastack/freescout) + MariaDB
# darrere d'un túnel de Cloudflare (HTTPS el posa Cloudflare, sense ports 80/443).
#
# Ús:
#   sudo ./deploy-freescout.sh             # instal·la o actualitza (idempotent)
#   sudo ./deploy-freescout.sh --update    # només actualitza imatges i reinicia
#   sudo ./deploy-freescout.sh --reconfigure  # torna a demanar domini/token
#   sudo ./deploy-freescout.sh --status
# =============================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/freescout}"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

c_info="\033[1;34m"; c_ok="\033[1;32m"; c_err="\033[1;31m"; c_off="\033[0m"
info() { echo -e "${c_info}[*]${c_off} $*"; }
ok()   { echo -e "${c_ok}[✓]${c_off} $*"; }
die()  { echo -e "${c_err}[✗]${c_off} $*" >&2; exit 1; }

# ---------------------------------------------------------------- prerequisits
[[ $EUID -eq 0 ]] || die "Executa'l com a root: sudo $0"
[[ -r /etc/os-release ]] && . /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *ubuntu* || "${ID_LIKE:-}" == *debian* ]] \
  || die "Aquest script està pensat per a Ubuntu/Debian."

MODE="install"
case "${1:-}" in
  --update) MODE="update" ;;
  --reconfigure) MODE="reconfigure" ;;
  --status) MODE="status" ;;
  "" ) ;;
  *) die "Opció desconeguda: $1" ;;
esac

install_docker() {
  info "Docker no trobat. Instal·lant Docker Engine + Compose plugin..."
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
    ok "Docker ja instal·lat: $(docker --version)"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    info "Falta el plugin 'docker compose'. Instal·lant..."
    apt-get update -y || true
    # 1) repo oficial de Docker, 2) paquet d'Ubuntu, 3) binari oficial de GitHub
    apt-get install -y docker-compose-plugin       || apt-get install -y docker-compose-v2       || install_compose_binary
    docker compose version >/dev/null 2>&1 || die "No s'ha pogut instal·lar 'docker compose'."
  fi
  command -v openssl >/dev/null 2>&1 || { apt-get update -y; apt-get install -y openssl; }
  systemctl is-active --quiet docker || systemctl enable --now docker
}

# ---------------------------------------------------------------- configuració
rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }

load_env() { [[ -f "$ENV_FILE" ]] && set -a && . "$ENV_FILE" && set +a || true; }

ask() { # ask VAR "pregunta" [secret]
  local var="$1" prompt="$2" secret="${3:-}" optional="${4:-}" val=""
  while [[ -z "$val" ]]; do
    if [[ -n "$secret" ]]; then read -r -s -p "$prompt: " val </dev/tty; echo
    else read -r -p "$prompt: " val </dev/tty; fi
    [[ -n "$optional" ]] && break
  done
  printf -v "$var" '%s' "$val"
}

configure() {
  mkdir -p "$INSTALL_DIR"
  load_env

  if [[ "$MODE" == "reconfigure" || -z "${DOMAIN:-}" ]]; then
    ask DOMAIN "Nom de domini (p.ex. suport.exemple.com)"
  fi
  if [[ "$MODE" == "reconfigure" || -z "${TUNNEL_TOKEN+x}" ]]; then
    echo "Token del túnel de Cloudflare (Zero Trust > Networks > Tunnels > el teu túnel > Docker)."
    echo "És el text llarg després de '--token'. Deixa-ho buit per no instal·lar cloudflared."
    ask TUNNEL_TOKEN "Token del túnel" secret optional
  fi
  if [[ "$MODE" == "reconfigure" || -z "${ACME_EMAIL:-}" ]]; then
    ask ACME_EMAIL "Email de l'administrador de FreeScout"
  fi
  if [[ "$MODE" == "reconfigure" || -z "${ADMIN_EMAIL:-}" ]]; then
    ADMIN_EMAIL="$ACME_EMAIL"
  fi

  # Secrets: es generen una sola vegada i es conserven en actualitzacions
  DB_PASS="${DB_PASS:-$(rand 28)}"
  DB_ROOT_PASS="${DB_ROOT_PASS:-$(rand 28)}"
  ADMIN_PASS="${ADMIN_PASS:-$(rand 20)}"
  FREESCOUT_TAG="${FREESCOUT_TAG:-latest}"
  HTTP_PORT="${HTTP_PORT:-8080}"   # només a 127.0.0.1, per al túnel de Cloudflare
  TZ_NAME="${TZ_NAME:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

  umask 077
  cat > "$ENV_FILE" <<EOF
DOMAIN=$DOMAIN
TUNNEL_TOKEN=$TUNNEL_TOKEN
ACME_EMAIL=$ACME_EMAIL
HTTP_PORT=$HTTP_PORT
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
    ports:
      - "127.0.0.1:${HTTP_PORT}:80"
    volumes:
      - freescout_data:/data
      - freescout_logs:/logs
    networks: [freescout]

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: freescout-cloudflared
    restart: unless-stopped
    profiles: ["tunnel"]
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${TUNNEL_TOKEN}
    depends_on:
      - freescout
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
  freescout_data:
  freescout_logs:
  freescout_db:
EOF
}

deploy() {
  cd "$INSTALL_DIR"
  load_env
  # cloudflared només s'aixeca si s'ha indicat el token del túnel
  if [[ -n "${TUNNEL_TOKEN:-}" ]]; then export COMPOSE_PROFILES=tunnel; else unset COMPOSE_PROFILES; fi
  info "Descarregant imatges (pull)..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p freescout pull
  info "Aixecant serveis..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p freescout up -d --remove-orphans
  docker image prune -f >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- execució
if [[ "$MODE" == "status" ]]; then
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p freescout ps
  exit 0
fi

ensure_docker

if [[ "$MODE" == "update" ]]; then
  [[ -f "$ENV_FILE" && -f "$COMPOSE_FILE" ]] || die "No hi ha cap instal·lació a $INSTALL_DIR. Executa sense --update."
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
echo "  URL:       https://$DOMAIN   (la 1a càrrega pot trigar 2-5 min)"
echo "  Admin:     $ADMIN_EMAIL"
echo "  Password:  $ADMIN_PASS"
echo "  Config:    $ENV_FILE (permisos 600)"
echo
if [[ -n "${TUNNEL_TOKEN:-}" ]]; then
  echo "Túnel: cloudflared ja corre (contenidor freescout-cloudflared)."
  echo "  A Cloudflare > Tunnels > Public Hostname: $DOMAIN -> HTTP -> freescout-app:80"
else
  echo "Túnel: publica $DOMAIN cap a http://localhost:$HTTP_PORT (cloudflared extern)"
fi
echo "Actualitzar:  sudo $0 --update"
