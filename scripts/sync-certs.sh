#!/usr/bin/env bash
# Отдаёт ноде сертификат Hysteria2, выписанный Caddy.
#
# Xray читает файлы сертификата при старте, поэтому после продления нужен
# перезапуск ноды. Скрипт сравнивает содержимое и перезапускает ТОЛЬКО когда
# сертификат реально изменился — иначе ежедневный cron рвал бы соединения впустую.
set -euo pipefail

CADDY_DATA="${CADDY_DATA:-/opt/caddy/data}"
SSL_DIR="${SSL_DIR:-/opt/remnanode/ssl}"
HY2_DOMAIN="${HY2_DOMAIN:-}"

[ -n "$HY2_DOMAIN" ] || { echo "не задан HY2_DOMAIN" >&2; exit 1; }

# Хранилище Caddy может быть как каталогом на хосте, так и томом внутри
# чужого контейнера — во втором случае читаем через docker exec.
CADDY_CONTAINER="${CADDY_CONTAINER:-}"

if [ -n "$CADDY_CONTAINER" ]; then
    in_caddy() { docker exec "$CADDY_CONTAINER" sh -c "$1"; }
    src_crt=$(in_caddy "find /data/caddy/certificates -name '${HY2_DOMAIN}.crt' 2>/dev/null | head -1")
    fetch() { in_caddy "cat '$1'"; }
else
    src_crt=$(find "$CADDY_DATA/caddy/certificates" -name "${HY2_DOMAIN}.crt" 2>/dev/null | head -1)
    fetch() { cat "$1"; }
fi

if [ -z "$src_crt" ]; then
    echo "сертификат для ${HY2_DOMAIN} ещё не выписан — проверь логи своего reverse proxy" >&2
    exit 1
fi
src_key="${src_crt%.crt}.key"

mkdir -p "$SSL_DIR"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

changed=0
for pair in "$src_crt:cert.pem" "$src_key:cert.key"; do
    src=${pair%%:*}; name=${pair##*:}; dst="$SSL_DIR/$name"
    fetch "$src" > "$tmp/$name" || { echo "не прочитать $src" >&2; exit 1; }
    [ -s "$tmp/$name" ] || { echo "$src пуст" >&2; exit 1; }
    if [ ! -f "$dst" ] || ! cmp -s "$tmp/$name" "$dst"; then
        install -m 0644 "$tmp/$name" "$dst"
        changed=1
    fi
done
chmod 0640 "$SSL_DIR/cert.key"

if [ "$changed" -eq 0 ]; then
    exit 0
fi

echo "сертификат ${HY2_DOMAIN} обновлён"
if docker ps --format '{{.Names}}' | grep -qx remnanode; then
    docker restart remnanode >/dev/null
    echo "нода перезапущена"
fi
