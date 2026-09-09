#!/usr/bin/env bash
# Обновляет geo-файлы под российские списки и перезапускает ноду.
# Источник: runetfreedom/russia-v2ray-rules-dat — даёт категории
# geosite:ru-blocked, geosite:ru-available-only-inside, geoip:ru-whitelist и др.
set -euo pipefail

ASSETS_DIR="${ASSETS_DIR:-/opt/remnanode/xray-assets}"
BASE="https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release"
MIN_SIZE=100000   # защита от скачанной страницы с ошибкой вместо .dat

mkdir -p "$ASSETS_DIR"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for f in geoip.dat geosite.dat; do
    curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/$f" "$BASE/$f"
    size=$(stat -c%s "$tmp/$f")
    if [ "$size" -lt "$MIN_SIZE" ]; then
        echo "ОШИБКА: $f подозрительно мал ($size байт), обновление отменено" >&2
        exit 1
    fi
done

# Файлы меняем только после того, как оба скачались целиком
for f in geoip.dat geosite.dat; do
    mv -f "$tmp/$f" "$ASSETS_DIR/$f"
done

echo "geo-файлы обновлены в $ASSETS_DIR"

if docker ps --format '{{.Names}}' | grep -qx remnanode; then
    docker restart remnanode >/dev/null
    echo "нода перезапущена"
fi
