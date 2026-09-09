#!/usr/bin/env bash
#
# Одна команда — полная картина: сверяет то, что отдаётся клиенту в подписке,
# с тем, что реально стоит в конфиге Xray, и проверяет донора.
#
# Использование:  sudo ./scripts/diagnose.sh <short-uuid>
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
CFG="${CFG:-/opt/vpn/xray-config.json}"
SHORT_UUID="${1:-}"

[ -f "$ENV_FILE" ] || { echo "нет $ENV_FILE" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

if [ -z "$SHORT_UUID" ]; then
    SHORT_UUID=$(docker exec remnawave-db psql -U postgres -d postgres -t -A -c \
        'select short_uuid from users limit 1' 2>/dev/null \
        || docker exec remnawave-db psql -U postgres -d postgres -t -A -c \
        'select "shortUuid" from users limit 1' 2>/dev/null)
fi

SUB_HOST="${SUB_DOMAIN:-${PANEL_DOMAIN:-}}"
SUB=$(curl -s --max-time 10 "https://${SUB_HOST}/api/sub/${SHORT_UUID}")
SUB_PLAIN=$(printf '%s' "$SUB" | base64 -d 2>/dev/null || printf '%s' "$SUB")

export SUB_PLAIN="$SUB_PLAIN"
python3 - "$CFG" <<'PY'
import base64, json, re, subprocess, sys, os

cfg_path = sys.argv[1]
sub = os.environ.get("SUB_PLAIN", "")

def b64u_dec(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

def b64u_enc(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")

def pub_from_priv(priv_b64u):
    """Публичный ключ X25519 из приватного. Собираем DER-обёртку PKCS#8
    вокруг сырых 32 байт и просим openssl посчитать пару — так не нужен
    ни xray, ни сторонние библиотеки."""
    raw = b64u_dec(priv_b64u)
    if len(raw) != 32:
        return None, f"приватный ключ {len(raw)} байт вместо 32"
    der = bytes.fromhex("302e020100300506032b656e04220420") + raw
    try:
        out = subprocess.run(
            ["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
            input=der, capture_output=True, check=True).stdout
    except Exception as e:
        return None, f"openssl: {e}"
    return b64u_enc(out[-32:]), None

ok, bad = [], []
def check(cond, good, err):
    (ok if cond else bad).append(good if cond else err)

try:
    cfg = json.load(open(cfg_path))
except Exception as e:
    print(f"не прочитать {cfg_path}: {e}"); sys.exit(1)

inb = next((i for i in cfg["inbounds"] if i.get("tag") == "VLESS-TCP-REALITY"), None)
if not inb:
    print("в конфиге нет инбаунда VLESS-TCP-REALITY"); sys.exit(1)
rs = inb["streamSettings"]["realitySettings"]

# --- что отдано клиенту -----------------------------------------------------
line = next((l for l in sub.splitlines() if l.startswith("vless://") and "type=tcp" in l), "")
if not line:
    print("В подписке нет записи VLESS/TCP.")
    print("Ответ сервера:", (sub[:200] or "<пусто>"))
    sys.exit(1)

q = dict(re.findall(r"[?&]([^=&]+)=([^&#]*)", line))
sub_port = re.search(r"@[^:]+:(\d+)", line)
sub_port = int(sub_port.group(1)) if sub_port else None

print("=== что панель отдаёт клиенту ===")
for k in ("security", "sni", "pbk", "sid", "flow", "fp", "type"):
    print(f"  {k:9}= {q.get(k, '—')}")
print(f"  port     = {sub_port}")

print("\n=== что стоит в конфиге Xray ===")
print(f"  dest     = {rs.get('dest')}")
print(f"  sni      = {rs.get('serverNames')}")
print(f"  shortIds = {rs.get('shortIds')}")
print(f"  xver     = {rs.get('xver')}")
print(f"  port     = {inb.get('port')}")

# --- сверка -----------------------------------------------------------------
derived, err = pub_from_priv(rs.get("privateKey", ""))
if err:
    bad.append(f"не вывести публичный ключ: {err}")
else:
    check(derived == q.get("pbk"),
          "публичный ключ соответствует приватному",
          f"КЛЮЧИ НЕ СОВПАДАЮТ: клиенту отдан pbk={q.get('pbk')}, "
          f"а приватному ключу в конфиге соответствует {derived}")

check(q.get("sni") in (rs.get("serverNames") or []),
      "SNI из подписки есть в serverNames",
      f"SNI не совпадает: клиент шлёт {q.get('sni')}, сервер ждёт {rs.get('serverNames')}")

check(sub_port == inb.get("port"),
      "порт совпадает",
      f"порт не совпадает: в подписке {sub_port}, в конфиге {inb.get('port')}")

sid = q.get("sid", "")
sids = rs.get("shortIds") or []
check(sid in sids,
      f"shortId принят (клиент шлёт {'пустой' if sid == '' else sid})",
      f"shortId не совпадает: клиент шлёт '{sid}', в конфиге {sids}")

check(q.get("security") == "reality", "security=reality", f"security={q.get('security')}")

print("\n=== итог ===")
for m in ok:
    print("  [ok]  " + m)
for m in bad:
    print("  [!!]  " + m)
if not bad:
    print("\n  Конфигурация согласована. Причина не в параметрах REALITY —")
    print("  следующий шаг: loglevel debug в панели и docker logs -f remnanode.")
PY
