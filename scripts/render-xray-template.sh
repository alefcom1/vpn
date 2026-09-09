#!/usr/bin/env bash
#
# Собирает готовый к вставке в панель конфиг Xray из шаблона и .env.
# Ключи REALITY генерирует при первом запуске и дописывает в .env,
# чтобы повторный запуск давал тот же конфиг и не отвалились клиенты.
#
# Использование:
#   ./scripts/render-xray-template.sh            # базовый шаблон
#   ./scripts/render-xray-template.sh --ru-guard # + блокировка РФ-направления
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
TEMPLATE="$REPO_DIR/server/xray/config-template.json"
OUT="${OUT:-/opt/vpn/xray-config.json}"

[ "${1:-}" = "--ru-guard" ] && TEMPLATE="$REPO_DIR/server/xray/config-template-ru-guard.json"
[ -f "$ENV_FILE" ] || { echo "нет $ENV_FILE" >&2; exit 1; }

set -a; . "$ENV_FILE"; set +a

[ -n "${REALITY_DEST:-}" ] || {
    echo "в .env не задан REALITY_DEST — сначала подбери сайт-донор (docs/INSTALL.md, шаг 6)" >&2
    exit 1
}

# Ключи генерируем один раз и запоминаем: смена ключа отключает всех клиентов.
if [ -z "${REALITY_PRIVATE_KEY:-}" ]; then
    echo "Генерирую ключи REALITY и дописываю в $ENV_FILE" >&2
    keys=$(bash "$REPO_DIR/scripts/gen-reality-keys.sh" | grep '^REALITY_\|^GRPC_')
    printf '\n# --- сгенерировано render-xray-template.sh, не менять ---\n%s\n' "$keys" >> "$ENV_FILE"
    set -a; eval "$keys"; set +a
fi

python3 - "$TEMPLATE" "$OUT" <<'PY'
import json, os, sys

src, dst = sys.argv[1], sys.argv[2]
raw = open(src).read()

subs = {
    "__REALITY_DEST__":        os.environ["REALITY_DEST"],
    "__REALITY_PRIVATE_KEY__": os.environ["REALITY_PRIVATE_KEY"],
    "__REALITY_SHORT_ID__":    os.environ["REALITY_SHORT_ID"],
    "__GRPC_SERVICE_NAME__":   os.environ["GRPC_SERVICE_NAME"],
}
for k, v in subs.items():
    raw = raw.replace(k, v)

cfg = json.loads(raw)   # падаем здесь, а не в панели, если что-то не подставилось

ports = {
    "VLESS-TCP-REALITY":  int(os.environ.get("XRAY_REALITY_PORT", 443)),
    "VLESS-GRPC-REALITY": int(os.environ.get("XRAY_GRPC_PORT", 2087)),
    "HYSTERIA2":          int(os.environ.get("HY2_PORT", 443)),
}
for inb in cfg["inbounds"]:
    if inb["tag"] in ports:
        inb["port"] = ports[inb["tag"]]

left = [k for k in subs if k in json.dumps(cfg)]
if left:
    sys.exit("не подставлены плейсхолдеры: " + ", ".join(left))

os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
with open(dst, "w") as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY

cat >&2 <<EOF

Конфиг записан: $OUT
Вставить его целиком в панель: Xray Config (шаблон конфига ядра).

Для настройки inbound'ов в панели понадобится:
  REALITY public key : ${REALITY_PUBLIC_KEY}
  REALITY short id   : ${REALITY_SHORT_ID}
  REALITY SNI / dest : ${REALITY_DEST}
  gRPC serviceName   : ${GRPC_SERVICE_NAME}
  Hysteria2 SNI      : ${HY2_DOMAIN:-<HY2_DOMAIN>}

EOF
