#!/usr/bin/env bash
# Генерирует пару ключей X25519 для REALITY, shortId и имя gRPC-сервиса.
# Xray ждёт base64url без паддинга — openssl отдаёт DER, из него берём сырые 32 байта.
set -euo pipefail

b64url() { base64 | tr '+/' '-_' | tr -d '=\n'; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
openssl genpkey -algorithm X25519 -out "$tmp" 2>/dev/null

priv=$(openssl pkey -in "$tmp" -outform DER | tail -c 32 | b64url)
pub=$(openssl pkey -in "$tmp" -pubout -outform DER | tail -c 32 | b64url)

echo "REALITY_PRIVATE_KEY=$priv"
echo "REALITY_PUBLIC_KEY=$pub"
echo "REALITY_SHORT_ID=$(openssl rand -hex 8)"
echo "GRPC_SERVICE_NAME=$(openssl rand -hex 8)"
echo
echo "Приватный ключ -> в шаблон конфига Xray в панели."
echo "Публичный ключ -> в настройки inbound'а (его получают клиенты)."
