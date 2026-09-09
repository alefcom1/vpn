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
: "${HY2_PORT:=443}"
: "${HY2_PORT_HOPPING:=}"

# На машине, где уже крутится чужой продакшен, скрипт не имеет права менять
# общесистемные вещи: firewall, SSH и sysctl принадлежат не ему.
: "${SHARED_HOST:=no}"
if [ "$SHARED_HOST" = "yes" ]; then
    : "${MANAGE_FIREWALL:=no}"
    : "${MANAGE_SSH:=no}"
    : "${MANAGE_SYSCTL:=no}"
    : "${USE_EXTERNAL_PROXY:=yes}"
    # Панель должна быть достижима из чужого reverse proxy, который живёт
    # в bridge-сети и до 127.0.0.1 хоста не дотянется.
    : "${PANEL_BIND:=172.17.0.1}"
else
    : "${MANAGE_FIREWALL:=yes}"
    : "${MANAGE_SSH:=yes}"
    : "${MANAGE_SYSCTL:=yes}"
    : "${USE_EXTERNAL_PROXY:=no}"
    : "${PANEL_BIND:=127.0.0.1}"
fi

[ -n "${PANEL_DOMAIN:-}" ] || die "в .env не задан PANEL_DOMAIN"
[ -n "${ACME_EMAIL:-}" ]  || die "в .env не задан ACME_EMAIL"
[ -n "${HY2_DOMAIN:-}" ]  || die "в .env не задан HY2_DOMAIN"

# ------------------------------------------------------------------ пакеты ---
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
if [ "$SHARED_HOST" = "yes" ]; then
    # Чужой продакшен не обновляем: apt upgrade может перезапустить сервисы,
    # о которых этот скрипт ничего не знает. Ставим только необходимое.
    log "Минимальный набор пакетов (SHARED_HOST=yes, обновление системы пропущено)"
    apt-get install -y -qq --no-install-recommends \
        curl ca-certificates jq openssl iproute2
else
    log "Базовые пакеты и обновления"
    apt-get -y -qq upgrade
    apt-get install -y -qq --no-install-recommends \
        curl ca-certificates gnupg jq nftables chrony vnstat \
        unattended-upgrades openssl iproute2 sqlite3
    systemctl enable --now chrony vnstat >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------ sysctl ---
if [ "$MANAGE_SYSCTL" = "yes" ]; then
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
else
    log "Сетевой тюнинг пропущен (SHARED_HOST=yes)"
fi

# --------------------------------------------------------------------- SSH ---
if [ "$MANAGE_SSH" = "yes" ]; then
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
else
    log "Настройка SSH пропущена (SHARED_HOST=yes)"
fi

# ------------------------------------------------------------------ docker ---
if ! command -v docker >/dev/null; then
    log "Установка Docker"
    curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "нет плагина docker compose"

# ---------------------------------------------------------------- firewall ---
if [ "$MANAGE_FIREWALL" = "yes" ]; then
log "Firewall (nftables)"
if [ -n "$SSH_ALLOW_IP" ]; then
    ssh_rule="ip saddr ${SSH_ALLOW_IP} tcp dport ${SSH_PORT} accept"
else
    ssh_rule="tcp dport ${SSH_PORT} accept"
    warn "SSH_ALLOW_IP не задан — SSH открыт всему интернету"
fi
# Port hopping: диапазон UDP-портов редиректится на порт Hysteria2
if [ -n "$HY2_PORT_HOPPING" ]; then
    hop_input="        udp dport ${HY2_PORT_HOPPING} accept"
    hop_nat=$(cat <<EOF

table inet hy2nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        udp dport ${HY2_PORT_HOPPING} redirect to :${HY2_PORT}
    }
}
EOF
)
else
    hop_input=""
    hop_nat=""
fi

render "$REPO_DIR/server/nftables/vpn.nft.tmpl" /etc/nftables.conf \
    "__SSH_RULE__"          "$ssh_rule" \
    "__PANEL_HTTPS_PORT__"  "$PANEL_HTTPS_PORT" \
    "__XRAY_REALITY_PORT__" "$XRAY_REALITY_PORT" \
    "__XRAY_GRPC_PORT__"    "$XRAY_GRPC_PORT" \
    "__HY2_PORT__"          "$HY2_PORT" \
    "__HY2_HOPPING_INPUT__" "$hop_input" \
    "__HY2_HOPPING_NAT__"   "$hop_nat" \
    "__NODE_PORT__"         "$NODE_PORT"
nft -c -f /etc/nftables.conf || die "ruleset nftables не проходит проверку"
systemctl enable --now nftables >/dev/null
nft -f /etc/nftables.conf

# Страховка: если ruleset когда-либо сбрасывался целиком (в том числе прошлой
# версией этого скрипта), цепочки docker в iptables-nft уничтожены, и docker
# не поднимет ни одной сети, пока не пересоздаст их при старте.
if systemctl is-active --quiet docker; then
    systemctl restart docker
    for _ in $(seq 1 15); do docker info >/dev/null 2>&1 && break; sleep 1; done
    docker info >/dev/null 2>&1 || die "docker не поднялся после перезапуска"
fi
else
    log "Firewall пропущен (SHARED_HOST=yes)"
    warn "порты ${XRAY_REALITY_PORT}/tcp, ${XRAY_GRPC_PORT}/tcp и ${HY2_PORT}/udp открыть самостоятельно"
    warn "порт ${NODE_PORT}/tcp должен быть доступен ТОЛЬКО из docker-сетей (172.16.0.0/12)"
fi

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

# Порты панели наружу торчать не должны: снаружи только reverse proxy.
# Важно: docker обходит INPUT-цепочку nftables, поэтому привязка к локальному
# адресу — не «дополнительная мера», а единственное, что здесь работает.
#
# Контейнерная часть может быть записана как ${APP_PORT:-3000}, поэтому
# сопоставляем по хостовому порту, а не по обеим числам.
sed -i -E 's|^([[:space:]]*-[[:space:]]*)['"'"'"]?([0-9]{1,3}(\.[0-9]{1,3}){3}:)?([0-9]{2,5}):([^'"'"'"[:space:]]+)['"'"'"]?[[:space:]]*$|\1127.0.0.1:\4:\5|' \
    docker-compose.yml

# Наружу через чужой прокси отдаём ТОЛЬКО порт приложения. Метрики и PostgreSQL
# остаются на localhost: на общей машине адрес docker-моста виден всем соседним
# контейнерам, и база панели оказалась бы доступна любому из них.
if [ "$PANEL_BIND" != "127.0.0.1" ]; then
    sed -i -E "s|^([[:space:]]*-[[:space:]]*)127\.0\.0\.1:3000:|\1${PANEL_BIND}:3000:|" docker-compose.yml
fi

bind_re=${PANEL_BIND//./\\.}
cfg=$(docker compose config)
n_pub=$(grep -c 'published:' <<<"$cfg" || true)
n_ok=$(grep -cE "host_ip: (127\.0\.0\.1|${bind_re})" <<<"$cfg" || true)
[ "$n_pub" -eq "$n_ok" ] || die "в docker-compose.yml остались порты, открытые наружу ($n_ok из $n_pub привязаны к localhost или ${PANEL_BIND}) — поправь вручную"

if [ "$PANEL_BIND" != "127.0.0.1" ]; then
    n_ext=$(grep -cE "host_ip: ${bind_re}" <<<"$cfg" || true)
    [ "$n_ext" -eq 1 ] || die "на ${PANEL_BIND} должен смотреть ровно один порт (приложение), а смотрит $n_ext — проверь docker-compose.yml"
fi

docker compose up -d

# ------------------------------------------------------------------- caddy ---
if [ "$USE_EXTERNAL_PROXY" = "yes" ]; then
log "Свой Caddy не поднимается — используется внешний reverse proxy"
warn "проксировать panel.${PANEL_DOMAIN#panel.} на ${PANEL_BIND}:3000 нужно в своём прокси"
warn "сертификат для ${HY2_DOMAIN} тоже выдаёт он: см. docs/SHARED-HOST.md"
else
log "Caddy (TLS для панели и подписки)"
mkdir -p "$CADDY_DIR"
install -m 0644 "$REPO_DIR/server/caddy/docker-compose.yml" "$CADDY_DIR/docker-compose.yml"
render "$REPO_DIR/server/caddy/Caddyfile.tmpl" "$CADDY_DIR/Caddyfile" \
    "__ACME_EMAIL__"       "$ACME_EMAIL" \
    "__PANEL_HTTPS_PORT__" "$PANEL_HTTPS_PORT" \
    "__PANEL_DOMAIN__"     "$PANEL_DOMAIN" \
    "__HY2_DOMAIN__"       "$HY2_DOMAIN"
mkdir -p "$CADDY_DIR/data" "$CADDY_DIR/config" "$CADDY_DIR/logs"
(cd "$CADDY_DIR" && docker compose up -d)
fi

# -------------------------------------------------------------------- нода ---
log "Remnawave Node (Xray)"
mkdir -p "$NODE_DIR/xray-assets" "$NODE_DIR/ssl"
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

log "Сертификат для Hysteria2"
# Caddy выписывает сертификат не мгновенно — ждём, но не блокируем установку
for i in $(seq 1 12); do
    if HY2_DOMAIN="$HY2_DOMAIN" CADDY_DATA="$CADDY_DIR/data" SSL_DIR="$NODE_DIR/ssl" \
       bash "$REPO_DIR/scripts/sync-certs.sh"; then
        break
    fi
    [ "$i" -eq 12 ] && warn "сертификат для ${HY2_DOMAIN} не выписан: проверь A-запись (без проксирования CF) и порт 80, потом запусти /opt/vpn/sync-certs.sh"
    sleep 5
done

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
install -m 0755 "$REPO_DIR/scripts/sync-certs.sh"  "$VPN_DIR/sync-certs.sh"
[ -f "$VPN_DIR/healthcheck.env" ] || cat > "$VPN_DIR/healthcheck.env" <<EOF
# Заполнить, чтобы получать алерты в Telegram
TG_TOKEN=
TG_CHAT=
XRAY_REALITY_PORT=${XRAY_REALITY_PORT}
PANEL_HTTPS_PORT=${PANEL_HTTPS_PORT}
HY2_PORT=${HY2_PORT}
EOF
chmod 600 "$VPN_DIR/healthcheck.env"

cat > /etc/cron.d/vpn <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 4 * * 1 root ${VPN_DIR}/update-geo.sh >/dev/null 2>&1
*/10 * * * * root ${VPN_DIR}/healthcheck.sh >/dev/null 2>&1
23 5,17 * * * root HY2_DOMAIN=${HY2_DOMAIN} CADDY_DATA=${CADDY_DIR}/data SSL_DIR=${NODE_DIR}/ssl ${VPN_DIR}/sync-certs.sh >/dev/null 2>&1
EOF

# ------------------------------------------------------------------- итоги ---
cat <<EOF

$(log "Готово")

Панель:     https://${PANEL_DOMAIN}:${PANEL_HTTPS_PORT}
Подписка:   https://${pub_host}/api/sub/<short-uuid>
Hysteria2:  ${HY2_DOMAIN}:${HY2_PORT}/udp

Дальше вручную:
  1. Открыть панель, создать администратора, СРАЗУ включить 2FA.
  2. Nodes -> Create: адрес 172.17.0.1, порт ${NODE_PORT}. Скопировать выданный ключ
     в ${NODE_DIR}/.env, затем: cd ${NODE_DIR} && docker compose up -d
  3. Подобрать REALITY_DEST (docs/INSTALL.md, шаг 7) и записать в ${REPO_DIR}/.env
  4. ${REPO_DIR}/scripts/render-xray-template.sh
     -> готовый конфиг в /opt/vpn/xray-config.json и значения для хостов
  5. Вставить этот конфиг в панель (Xray Config), затем создать хосты
     по таблице из docs/INSTALL.md, шаг 12.
  6. Templates -> Xray-JSON и Subscription page, HAPP Routing — docs/INSTALL.md, шаг 13.
  7. Hysteria2: inbound HYSTERIA2 уже в шаблоне. Проверить, что A-запись
     ${HY2_DOMAIN} указывает на сервер БЕЗ проксирования Cloudflare (UDP не проксируется).

EOF
