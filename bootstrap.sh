#!/usr/bin/env bash
#
# Разворачивает VPN-стек на чистом Debian 12/13:
#   Caddy (TLS) -> Remnawave (панель + подписка) -> Remnawave Node (Xray/REALITY)
#
# Идемпотентен: повторный запуск не ломает уже настроенное.
# Перед запуском: cp .env.example .env && отредактировать.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

PANEL_DIR=/opt/remnawave
NODE_DIR=/opt/remnanode
CADDY_DIR=/opt/caddy
VPN_DIR=/opt/vpn

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] ОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

# Заменяет KEY=... в файле, добавляет строку если ключа нет.
set_env() {
    local key=$1 val=$2 file=$3
    if grep -qE "^${key}=" "$file"; then
        # значение может содержать / и & — используем | и экранируем
        local esc=${val//\\/\\\\}; esc=${esc//|/\\|}; esc=${esc//&/\\&}
        sed -i -E "s|^${key}=.*|${key}=${esc}|" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$file"
    fi
}

render() {
    local src=$1 dst=$2; shift 2
    local content; content=$(cat "$src")
    while [ $# -gt 0 ]; do
        content=${content//"$1"/"$2"}
        shift 2
    done
    printf '%s\n' "$content" > "$dst"
}

# ---------------------------------------------------------------- проверки ---
[ "$(id -u)" -eq 0 ] || die "запускать от root"
[ -f "$ENV_FILE" ] || die "нет $ENV_FILE — скопируй .env.example и заполни"

set -a; . "$ENV_FILE"; set +a

: "${SUB_DOMAIN:=${PANEL_DOMAIN:-}}"
: "${SSH_PORT:=22}"
: "${SSH_ALLOW_IP:=}"
: "${PANEL_HTTPS_PORT:=8443}"
: "${XRAY_REALITY_PORT:=443}"
: "${XRAY_GRPC_PORT:=2087}"
: "${NODE_PORT:=2222}"

[ -n "${PANEL_DOMAIN:-}" ] || die "в .env не задан PANEL_DOMAIN"
[ -n "${ACME_EMAIL:-}" ]  || die "в .env не задан ACME_EMAIL"

# ------------------------------------------------------------------ пакеты ---
log "Базовые пакеты и обновления"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -qq upgrade
apt-get install -y -qq --no-install-recommends \
    curl ca-certificates gnupg jq nftables chrony vnstat \
    unattended-upgrades openssl iproute2 sqlite3
systemctl enable --now chrony vnstat >/dev/null 2>&1 || true

# ------------------------------------------------------------------ sysctl ---
log "Сетевой тюнинг (BBR + fq)"
install -m 0644 "$REPO_DIR/server/sysctl/99-vpn.conf" /etc/sysctl.d/99-vpn.conf
sysctl --system >/dev/null
[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ] \
    || warn "BBR не активировался — проверь, что ядро его поддерживает"

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
systemctl daemon-reexec

# --------------------------------------------------------------------- SSH ---
log "Настройка SSH"
if [ -s /root/.ssh/authorized_keys ] || compgen -G "/home/*/.ssh/authorized_keys" >/dev/null; then
    cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
Port ${SSH_PORT}
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
EOF
    sshd -t && systemctl reload ssh 2>/dev/null || systemctl reload sshd
else
    warn "не найден authorized_keys — вход по паролю НЕ отключён, иначе потеряешь доступ"
fi

# ------------------------------------------------------------------ docker ---
if ! command -v docker >/dev/null; then
    log "Установка Docker"
    curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "нет плагина docker compose"

# ---------------------------------------------------------------- firewall ---
log "Firewall (nftables)"
if [ -n "$SSH_ALLOW_IP" ]; then
    ssh_rule="ip saddr ${SSH_ALLOW_IP} tcp dport ${SSH_PORT} accept"
else
    ssh_rule="tcp dport ${SSH_PORT} accept"
    warn "SSH_ALLOW_IP не задан — SSH открыт всему интернету"
fi
render "$REPO_DIR/server/nftables/vpn.nft.tmpl" /etc/nftables.conf \
    "__SSH_RULE__"          "$ssh_rule" \
    "__PANEL_HTTPS_PORT__"  "$PANEL_HTTPS_PORT" \
    "__XRAY_REALITY_PORT__" "$XRAY_REALITY_PORT" \
    "__XRAY_GRPC_PORT__"    "$XRAY_GRPC_PORT" \
    "__NODE_PORT__"         "$NODE_PORT"
nft -c -f /etc/nftables.conf || die "ruleset nftables не проходит проверку"
systemctl enable --now nftables >/dev/null
nft -f /etc/nftables.conf

# ------------------------------------------------------------------ панель ---
log "Remnawave (панель)"
mkdir -p "$PANEL_DIR"
cd "$PANEL_DIR"

if [ ! -f docker-compose.yml ]; then
    curl -fsSL --retry 3 -o docker-compose.yml \
        https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml
fi

if [ ! -f .env ]; then
    curl -fsSL --retry 3 -o .env \
        https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample

    set_env APP_SECRET            "$(openssl rand -hex 64)" .env
    set_env METRICS_PASS          "$(openssl rand -hex 64)" .env
    set_env WEBHOOK_SECRET_HEADER "$(openssl rand -hex 64)" .env

    pgpw=$(openssl rand -hex 24)
    set_env POSTGRES_PASSWORD "$pgpw" .env
    sed -i -E "s|^(DATABASE_URL=\"postgresql://postgres:)[^@]*(@.*)|\1${pgpw}\2|" .env

    chmod 600 .env
else
    log ".env панели уже существует — секреты не трогаем"
fi

# Публичные адреса. Панель живёт за Caddy на нестандартном порту,
# поэтому порт обязан попасть в ссылки подписки.
if [ "$PANEL_HTTPS_PORT" = "443" ]; then
    pub_host="$SUB_DOMAIN"
else
    pub_host="${SUB_DOMAIN}:${PANEL_HTTPS_PORT}"
fi
set_env PANEL_DOMAIN     "$PANEL_DOMAIN"          .env
set_env FRONT_END_DOMAIN "$PANEL_DOMAIN"          .env
set_env SUB_PUBLIC_DOMAIN "${pub_host}/api/sub"   .env

# Порты панели наружу торчать не должны: снаружи только Caddy.
# Важно: docker обходит INPUT-цепочку nftables, поэтому привязка к 127.0.0.1 —
# не «дополнительная мера», а единственное, что здесь работает.
sed -i -E 's|^([[:space:]]*-[[:space:]]*)"?([0-9]{2,5}):([0-9]{2,5})"?[[:space:]]*$|\1"127.0.0.1:\2:\3"|' \
    docker-compose.yml

cfg=$(docker compose config)
n_pub=$(grep -c 'published:' <<<"$cfg" || true)
n_loc=$(grep -c 'host_ip: 127.0.0.1' <<<"$cfg" || true)
[ "$n_pub" -eq "$n_loc" ] || die "в docker-compose.yml остались порты, открытые наружу ($n_loc из $n_pub привязаны к 127.0.0.1) — поправь вручную"

docker compose up -d

# ------------------------------------------------------------------- caddy ---
log "Caddy (TLS для панели и подписки)"
mkdir -p "$CADDY_DIR"
install -m 0644 "$REPO_DIR/server/caddy/docker-compose.yml" "$CADDY_DIR/docker-compose.yml"
render "$REPO_DIR/server/caddy/Caddyfile.tmpl" "$CADDY_DIR/Caddyfile" \
    "__ACME_EMAIL__"       "$ACME_EMAIL" \
    "__PANEL_HTTPS_PORT__" "$PANEL_HTTPS_PORT" \
    "__PANEL_DOMAIN__"     "$PANEL_DOMAIN"
(cd "$CADDY_DIR" && docker compose up -d)

# -------------------------------------------------------------------- нода ---
log "Remnawave Node (Xray)"
mkdir -p "$NODE_DIR/xray-assets"
install -m 0644 "$REPO_DIR/server/node/docker-compose.yml" "$NODE_DIR/docker-compose.yml"

if [ ! -f "$NODE_DIR/.env" ]; then
    cat > "$NODE_DIR/.env" <<EOF
NODE_PORT=${NODE_PORT}
# Значение выдаёт панель при создании ноды (Nodes -> Create).
# Скопировать строку целиком сюда и запустить: cd ${NODE_DIR} && docker compose up -d
SSL_CERT=PASTE_FROM_PANEL
EOF
    chmod 600 "$NODE_DIR/.env"
fi

ASSETS_DIR="$NODE_DIR/xray-assets" bash "$REPO_DIR/scripts/update-geo.sh"

if grep -q PASTE_FROM_PANEL "$NODE_DIR/.env"; then
    warn "нода не запущена: в $NODE_DIR/.env нет ключа от панели"
else
    (cd "$NODE_DIR" && docker compose up -d)
fi

# --------------------------------------------------------------------- cron ---
log "Регулярные задачи"
mkdir -p "$VPN_DIR"
install -m 0755 "$REPO_DIR/scripts/update-geo.sh"  "$VPN_DIR/update-geo.sh"
install -m 0755 "$REPO_DIR/scripts/healthcheck.sh" "$VPN_DIR/healthcheck.sh"
[ -f "$VPN_DIR/healthcheck.env" ] || cat > "$VPN_DIR/healthcheck.env" <<EOF
# Заполнить, чтобы получать алерты в Telegram
TG_TOKEN=
TG_CHAT=
XRAY_REALITY_PORT=${XRAY_REALITY_PORT}
PANEL_HTTPS_PORT=${PANEL_HTTPS_PORT}
EOF
chmod 600 "$VPN_DIR/healthcheck.env"

cat > /etc/cron.d/vpn <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 4 * * 1 root ${VPN_DIR}/update-geo.sh >/dev/null 2>&1
*/10 * * * * root ${VPN_DIR}/healthcheck.sh >/dev/null 2>&1
EOF

# ------------------------------------------------------------------- итоги ---
cat <<EOF

$(log "Готово")

Панель:    https://${PANEL_DOMAIN}:${PANEL_HTTPS_PORT}
Подписка:  https://${pub_host}/api/sub/<short-uuid>

Дальше вручную:
  1. Открыть панель, создать администратора, СРАЗУ включить 2FA.
  2. Nodes -> Create: адрес 172.17.0.1, порт ${NODE_PORT}. Скопировать выданный ключ
     в ${NODE_DIR}/.env, затем: cd ${NODE_DIR} && docker compose up -d
  3. Сгенерировать ключи REALITY:  ${REPO_DIR}/scripts/gen-reality-keys.sh
  4. Подобрать REALITY_DEST по критериям из docs/RUNBOOK.md.
  5. Вставить шаблон Xray (server/xray/config-template.json) в панель,
     подставив __REALITY_DEST__, __REALITY_PRIVATE_KEY__, __REALITY_SHORT_ID__,
     __GRPC_SERVICE_NAME__.
  6. Templates -> Xray-JSON и Subscription page, HAPP Routing — см. docs/RUNBOOK.md.

EOF
