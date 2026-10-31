#!/usr/bin/env bash
#
# Поднимает HTTP-прокси для браузера. Ничего общего с существующими
# сервисами: отдельный контейнер, отдельный порт, свой каталог.
#
#   sudo ./proxy/setup.sh
#
set -euo pipefail

# Без этого любая неудачная команда убивает скрипт молча — как случилось
# с генерацией пароля через `tr | head`: head закрывает канал, tr получает
# SIGPIPE, pipefail превращает это в выход с кодом 141 и пустым выводом.
trap 'echo "ОШИБКА: строка $LINENO, код выхода $?" >&2' ERR

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${DIR:-/opt/webproxy}"

# Явно переданные в окружении значения должны побеждать сохранённые,
# поэтому запоминаем их до того, как подхватим credentials.
env_PROXY_PORT="${PROXY_PORT:-}"
env_PROXY_USER="${PROXY_USER:-}"
env_PAC_PORT="${PAC_PORT:-}"

[ "$(id -u)" -eq 0 ] || { echo "запускать от root" >&2; exit 1; }
command -v docker >/dev/null || { echo "нет docker" >&2; exit 1; }

mkdir -p "$DIR" "$DIR/pac"

# Сохранённые значения подхватываем, чтобы повторный запуск не менял пароль
# и не отвязывал уже настроенные устройства.
if [ -f "$DIR/credentials" ]; then
    . "$DIR/credentials"
    echo "Используются сохранённые учётные данные из $DIR/credentials"
fi

PROXY_PORT="${env_PROXY_PORT:-${PROXY_PORT:-18443}}"
PROXY_USER="${env_PROXY_USER:-${PROXY_USER:-web}}"
PAC_PORT="${env_PAC_PORT:-${PAC_PORT:-18444}}"

# Файл, созданный прежней версией скрипта, этих полей не содержит.
# Добираем недостающее, иначе set -u завершит работу на первой подстановке.
PROXY_PASS="${PROXY_PASS:-$(openssl rand -hex 16)}"
# Случайный путь к PAC: файл раздаётся без TLS и авторизации, поэтому
# угадываемый адрес выдал бы адрес и порт прокси любому сканеру.
PAC_TOKEN="${PAC_TOKEN:-$(openssl rand -hex 8)}"

cat > "$DIR/credentials" <<CRED
PROXY_USER=$PROXY_USER
PROXY_PASS=$PROXY_PASS
PROXY_PORT=$PROXY_PORT
PAC_PORT=$PAC_PORT
PAC_TOKEN=$PAC_TOKEN
CRED
chmod 600 "$DIR/credentials"

sed -e "s|__PROXY_USER__|$PROXY_USER|g" \
    -e "s|__PROXY_PASS__|$PROXY_PASS|g" \
    -e "s|__PROXY_PORT__|$PROXY_PORT|g" \
    "$SRC_DIR/3proxy.cfg.tmpl" > "$DIR/3proxy.cfg"
chmod 600 "$DIR/3proxy.cfg"

install -m 0644 "$SRC_DIR/docker-compose.yml" "$DIR/docker-compose.yml"
install -m 0644 "$SRC_DIR/pac-Caddyfile" "$DIR/pac-Caddyfile"
mkdir -p "$DIR/pac"
cat > "$DIR/.env" <<ENV
PROXY_PORT=$PROXY_PORT
PAC_PORT=$PAC_PORT
PAC_TOKEN=$PAC_TOKEN
ENV

PROXY_HOST="${PROXY_HOST:-$(curl -s --max-time 5 https://api.ipify.org)}"
DIR="$DIR" PROXY_HOST="$PROXY_HOST" OUT="$DIR/pac/proxy.pac" \
    bash "$SRC_DIR/gen-pac.sh" >/dev/null

# --force-recreate обязателен: 3proxy читает конфиг только при старте,
# и без пересоздания смена пароля молча не применилась бы.
cd "$DIR" && docker compose up -d --force-recreate

sleep 2
for c in webproxy webproxy-pac; do
    docker ps --format '{{.Names}}' | grep -qx "$c" \
        || { echo "контейнер $c не поднялся:"; docker logs "$c" --tail 20; exit 1; }
done

ip="${PROXY_HOST:-<IP сервера>}"

cat <<SUMMARY

Прокси работает.

  Адрес : $ip
  Порт  : $PROXY_PORT
  Логин : $PROXY_USER
  Пароль: $PROXY_PASS

Проверка с любой машины:

  curl -x http://$PROXY_USER:$PROXY_PASS@$ip:$PROXY_PORT -s https://api.ipify.org

Должен вернуться $ip, а не твой домашний адрес.

Адрес PAC-файла для браузера:

  http://$ip:$PAC_PORT/$PAC_TOKEN.pac

Настройка браузера — docs/PROXY.md
Учётные данные сохранены в $DIR/credentials
Сменить пароль: rm $DIR/credentials && bash proxy/setup.sh

SUMMARY
