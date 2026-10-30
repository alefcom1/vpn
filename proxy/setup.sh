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
PROXY_PORT="${PROXY_PORT:-18443}"
PROXY_USER="${PROXY_USER:-web}"

[ "$(id -u)" -eq 0 ] || { echo "запускать от root" >&2; exit 1; }
command -v docker >/dev/null || { echo "нет docker" >&2; exit 1; }

mkdir -p "$DIR"

# Пароль генерируем один раз: перезапуск setup.sh не должен отвязывать
# уже настроенные браузеры.
if [ -f "$DIR/credentials" ]; then
    . "$DIR/credentials"
    echo "Используются сохранённые учётные данные из $DIR/credentials"
else
    # Без конвейера: `... | head -c N` ломается под pipefail через SIGPIPE.
    PROXY_PASS=$(openssl rand -hex 16)
    cat > "$DIR/credentials" <<CRED
PROXY_USER=$PROXY_USER
PROXY_PASS=$PROXY_PASS
PROXY_PORT=$PROXY_PORT
CRED
    chmod 600 "$DIR/credentials"
fi

sed -e "s|__PROXY_USER__|$PROXY_USER|g" \
    -e "s|__PROXY_PASS__|$PROXY_PASS|g" \
    -e "s|__PROXY_PORT__|$PROXY_PORT|g" \
    "$SRC_DIR/3proxy.cfg.tmpl" > "$DIR/3proxy.cfg"
chmod 600 "$DIR/3proxy.cfg"

install -m 0644 "$SRC_DIR/docker-compose.yml" "$DIR/docker-compose.yml"
printf 'PROXY_PORT=%s\n' "$PROXY_PORT" > "$DIR/.env"

cd "$DIR" && docker compose up -d

sleep 2
docker ps --format '{{.Names}}' | grep -qx webproxy \
    || { echo "контейнер не поднялся:"; docker logs webproxy --tail 20; exit 1; }

ip=$(curl -s --max-time 5 https://api.ipify.org || echo "<IP сервера>")

cat <<SUMMARY

Прокси работает.

  Адрес : $ip
  Порт  : $PROXY_PORT
  Логин : $PROXY_USER
  Пароль: $PROXY_PASS

Проверка с любой машины:

  curl -x http://$PROXY_USER:$PROXY_PASS@$ip:$PROXY_PORT -s https://api.ipify.org

Должен вернуться $ip, а не твой домашний адрес.

Настройка браузера — docs/PROXY.md
Учётные данные сохранены в $DIR/credentials

SUMMARY
