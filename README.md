# vpn

Личный VPN на Hetzner: Remnawave (панель) + Remnawave Node (Xray-core),
VLESS + XTLS-Vision + REALITY на TCP/443, Hysteria2 на UDP/443 как резерв.
Клиент — Happ.
Раздельный трафик: российские ресурсы напрямую, заблокированные — через тоннель.

## Быстрый старт

```bash
cp .env.example .env && nano .env
./bootstrap.sh
```

## Документация

- [docs/INSTALL.md](docs/INSTALL.md) — пошаговая установка с нуля
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
scripts/render-xray-template  готовый конфиг Xray для панели
scripts/update-geo        списки блокировок (cron)
scripts/healthcheck       мониторинг + алерты в Telegram
```

Секреты в репозиторий не коммитятся: см. `.env.example` и `.gitignore`.
