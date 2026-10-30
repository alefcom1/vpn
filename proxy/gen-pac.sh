#!/usr/bin/env bash
#
# Собирает PAC-файл из domains.txt и кладёт туда, откуда его заберёт браузер.
#
#   sudo bash proxy/gen-pac.sh
#
set -euo pipefail
trap 'echo "ОШИБКА: строка $LINENO, код выхода $?" >&2' ERR

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${DIR:-/opt/webproxy}"
LIST="${LIST:-$SRC_DIR/domains.txt}"
OUT="${OUT:-$DIR/proxy.pac}"

[ -f "$DIR/credentials" ] || { echo "нет $DIR/credentials — сначала setup.sh" >&2; exit 1; }
. "$DIR/credentials"

PROXY_HOST="${PROXY_HOST:-$(curl -s --max-time 5 https://api.ipify.org)}"
[ -n "$PROXY_HOST" ] || { echo "не определить внешний адрес, задай PROXY_HOST=" >&2; exit 1; }

domains=$(grep -vE '^\s*#|^\s*$' "$LIST" | tr -d ' \r' | sort -u)
count=$(wc -l <<<"$domains")
js_list=$(sed 's/.*/"&"/' <<<"$domains" | paste -sd, -)

cat > "$OUT" <<PAC
// Сгенерирован gen-pac.sh из domains.txt — правьте список, не этот файл.
// Доменов в списке: $count
function FindProxyForURL(url, host) {
    var PROXY = "PROXY $PROXY_HOST:$PROXY_PORT";
    var DIRECT = "DIRECT";
    var list = [$js_list];

    host = host.toLowerCase();

    // Локальные адреса и имена без точки — всегда напрямую,
    // иначе внутренние сервисы начнут ходить кругом через сервер.
    if (host.indexOf(".") < 0 || isPlainHostName(host)) return DIRECT;
    if (shExpMatch(host, "*.local") ||
        isInNet(host, "127.0.0.0", "255.0.0.0") ||
        isInNet(host, "10.0.0.0", "255.0.0.0") ||
        isInNet(host, "172.16.0.0", "255.240.0.0") ||
        isInNet(host, "192.168.0.0", "255.255.0.0")) return DIRECT;

    for (var i = 0; i < list.length; i++) {
        var d = list[i];
        if (host === d || host.slice(-(d.length + 1)) === "." + d) return PROXY;
    }
    return DIRECT;
}
PAC

chmod 644 "$OUT"
echo "PAC собран: $OUT (доменов: $count, прокси: $PROXY_HOST:$PROXY_PORT)"
echo
echo "Отдать его браузеру можно двумя способами — см. docs/PROXY.md."
