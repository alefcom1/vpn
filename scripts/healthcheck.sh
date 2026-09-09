#!/usr/bin/env bash
# Проверка живости. Запускать из cron раз в 10 минут.
# Алерт в Telegram, если заданы TG_TOKEN и TG_CHAT (можно положить в /opt/vpn/healthcheck.env).
set -uo pipefail

[ -f /opt/vpn/healthcheck.env ] && . /opt/vpn/healthcheck.env

XRAY_PORT="${XRAY_REALITY_PORT:-443}"
PANEL_PORT="${PANEL_HTTPS_PORT:-8443}"
DISK_LIMIT_PCT="${DISK_LIMIT_PCT:-85}"
TRAFFIC_LIMIT_GIB="${TRAFFIC_LIMIT_GIB:-18000}"   # 20 ТБ Hetzner, порог с запасом

problems=()

for c in remnanode remnawave caddy; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
        problems+=("контейнер $c не запущен")
    fi
done

for p in "$XRAY_PORT" "$PANEL_PORT"; do
    if ! ss -lnt "sport = :$p" | grep -q LISTEN; then
        problems+=("порт $p не слушается")
    fi
done

disk=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "${disk:-0}" -ge "$DISK_LIMIT_PCT" ]; then
    problems+=("диск занят на ${disk}%")
fi

if command -v vnstat >/dev/null; then
    used=$(vnstat --oneline b 2>/dev/null | cut -d';' -f11)
    used_gib=$(( ${used:-0} / 1073741824 ))
    if [ "$used_gib" -ge "$TRAFFIC_LIMIT_GIB" ]; then
        problems+=("трафик за месяц ${used_gib} ГиБ — близко к лимиту")
    fi
fi

if [ ${#problems[@]} -eq 0 ]; then
    exit 0
fi

msg="VPN $(hostname): $(printf '%s; ' "${problems[@]}")"
echo "$msg" >&2

if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ]; then
    curl -fsS --max-time 10 -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" --data-urlencode "text=${msg}" >/dev/null || true
fi
exit 1
