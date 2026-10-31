#!/usr/bin/env bash
#
# Добавляет домены в список и сразу пересобирает PAC.
#
#   sudo bash proxy/add-domain.sh example.com another.org
#
# Поддомены подхватываются сами: example.com покрывает и www.example.com.
set -euo pipefail
trap 'echo "ОШИБКА: строка $LINENO, код выхода $?" >&2' ERR

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${DIR:-/opt/webproxy}"
LIST="$SRC_DIR/domains.txt"

[ $# -gt 0 ] || { echo "укажи хотя бы один домен" >&2; exit 1; }

for d in "$@"; do
    # Принимаем и голый домен, и вставленную целиком ссылку.
    d=$(sed -E 's#^[a-z]+://##; s#/.*$##; s#^www\.##' <<<"$d" | tr -d ' \r')
    if grep -qxF "$d" "$LIST"; then
        echo "  уже есть: $d"
    else
        printf '%s\n' "$d" >> "$LIST"
        echo "  добавлен: $d"
    fi
done

DIR="$DIR" OUT="$DIR/pac/proxy.pac" bash "$SRC_DIR/gen-pac.sh"

cat <<'NOTE'

Теперь обнови PAC на устройстве: macOS кэширует файл и сама не перечитает.
Настройки → Сеть → Wi-Fi → Подробности → Прокси: выключить
«Автоконфигурация прокси», ОК, зайти снова, включить, ОК.
NOTE
