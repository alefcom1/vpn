# vpn

Личный VPN на Hetzner: Remnawave (панель) + Remnawave Node (Xray-core),
VLESS + XTLS-Vision + REALITY, клиент — Happ.
Раздельный трафик: российские ресурсы напрямую, заблокированные — через тоннель.

## Быстрый старт

```bash
cp .env.example .env && nano .env
./bootstrap.sh
```

## Документация

- [docs/PLAN.md](docs/PLAN.md) — план работ, выбор протоколов, риски
- [docs/RUNBOOK.md](docs/RUNBOOK.md) — процедуры: запуск, выдача доступов, авария

## Структура

```
bootstrap.sh              установка «с нуля» на чистый Debian
server/sysctl/            BBR + сетевой тюнинг
server/nftables/          firewall
server/caddy/             reverse proxy и TLS
server/node/              Remnawave Node (Xray)
server/xray/              шаблоны конфига Xray для панели
scripts/gen-reality-keys  ключи REALITY
scripts/update-geo        списки блокировок (cron)
scripts/healthcheck       мониторинг + алерты в Telegram
```

Секреты в репозиторий не коммитятся: см. `.env.example` и `.gitignore`.
