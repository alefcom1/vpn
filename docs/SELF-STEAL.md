# Self-steal: вернуть REALITY на порт 443

## Зачем

REALITY на нестандартном порту работает, но выделяется: обычный HTTPS живёт на 443,
и одинокий TLS-сервис на 8443 — сам по себе повод присмотреться.

Self-steal убирает компромисс. Xray занимает 443, а существующий reverse proxy
работает за ним и служит донором маскировки. Трафик, не прошедший аутентификацию
REALITY, Xray передаёт на донора как есть — значит любой сканер, зонд или
случайный посетитель получает **настоящие сайты с валидным сертификатом**.

Это лучше любого чужого донора: не нужно искать сайт с подходящим TLS, гадать
о его доступности из РФ и надеяться, что он не «затаскан» публичными сервисами.
Донор — свой, он всегда доступен и всегда отвечает правдой.

## Что меняется

```
До:   интернет → :443 Caddy → сайты
                 :8443 Xray → VPN

После: интернет → :443 Xray ─┬─ REALITY-клиент → VPN
                             └─ всё остальное → :8443 Caddy → сайты
```

## Цена

| Что | Почему |
|---|---|
| Правка боевого прокси | Меняется публикация портов и глобальный блок конфига |
| Простой ~30–60 секунд | Момент, когда Caddy уже отпустил 443, а Xray ещё не занял |
| PROXY protocol обязателен | Иначе сайты видят адрес docker-моста вместо посетителей |
| `allow` покрывает всю docker-подсеть | Любой контейнер на машине сможет подделать IP клиента |
| Судьбы связаны крепче | Падает Xray — падают и сайты, он теперь входная точка |

Последний пункт — главный. До self-steal сайты от VPN не зависели.

## Предусловия

- VPN уже работает на 8443, панель открывается, нода зелёная.
- Домены для SNI обслуживаются этим же прокси и имеют валидный сертификат.
- **Домен панели в SNI не добавлять** — он не должен светиться в конфигах клиентов.
- Caddy 2.7 или новее (`docker exec <caddy> caddy version`) — в более старых
  нет обёртки `proxy_protocol`.

## Порядок

### 1. Резервные копии

```bash
cp /home/massimo/remarka-lab/sitelens/Caddyfile{,.pre-selfsteal}
cp /home/massimo/remarka-lab/sitelens/docker-compose.yml{,.pre-selfsteal}
cp /opt/vpn/xray-config.json /opt/vpn/xray-config.pre-selfsteal.json
```

### 2. Включить PROXY protocol заранее

Содержимое `server/caddy/selfsteal.Caddyfile` добавить в глобальный блок Caddyfile.

```bash
docker exec sitelens-caddy-1 caddy reload --config /etc/caddy/Caddyfile
```

**Сайты должны продолжать работать.** `fallback_policy` по умолчанию `ignore`,
поэтому соединения без PROXY-заголовка обрабатываются как раньше. Если что-то
отвалилось — вернуть файл из копии и разбираться, дальше не идти.

### 3. Добавить внутренний порт, не убирая 443

В compose существующего прокси, рядом с `- "443:443"`:

```yaml
      - "127.0.0.1:8443:443"
```

```bash
cd /home/massimo/remarka-lab/sitelens && docker compose up -d
curl -skI --resolve example.com:8443:127.0.0.1 https://example.com:8443/ | head -1
```

Ответ должен прийти. Контейнер пересоздастся — это несколько секунд.

### 4. Подготовить конфиг Xray

```bash
nano /root/vpn/.env
```

```ini
SELFSTEAL=yes
SELFSTEAL_DEST=127.0.0.1:8443
SELFSTEAL_SNI=example.com,www.example.com
SELFSTEAL_XVER=2
XRAY_REALITY_PORT=443
```

```bash
/root/vpn/scripts/render-xray-template.sh
```

Полученный `/opt/vpn/xray-config.json` **сохранить в панели, но пока не применять
к живой ноде** — 443 ещё занят, Xray на него не встанет.

### 5. Переключение

Две команды подряд — здесь и происходит простой:

```bash
# убрать "443:443" из compose прокси, оставив "127.0.0.1:8443:443"
cd /home/massimo/remarka-lab/sitelens && docker compose up -d
docker restart remnanode
```

### 6. Проверка

```bash
ss -lntp | grep ':443 '                       # 443 держит xray, не caddy
curl -sI -o /dev/null -w '%{http_code}\n' https://example.com/
docker logs sitelens-caddy-1 --tail 20        # в логах реальные IP, не 172.x
```

Затем снаружи:

- сайты открываются, сертификат валиден;
- `curl -Ik https://178.105.192.76` отдаёт сайт, а не пустоту;
- VPN подключается по новому конфигу;
- Hysteria2 на 443/udp по-прежнему работает.

**Если в логах Caddy вместо реальных IP видны адреса `172.x`** — заголовок не доехал.
Поменять `SELFSTEAL_XVER=1`, перегенерировать конфиг, применить.

### 7. Откат

```bash
cd /home/massimo/remarka-lab/sitelens
cp docker-compose.yml.pre-selfsteal docker-compose.yml
cp Caddyfile.pre-selfsteal Caddyfile
docker compose up -d
```

И вернуть VPN на прежний порт:

```bash
sed -i 's/^SELFSTEAL=yes/SELFSTEAL=no/;s/^XRAY_REALITY_PORT=443/XRAY_REALITY_PORT=8443/' /root/vpn/.env
/root/vpn/scripts/render-xray-template.sh
```

Применить конфиг в панели и `docker restart remnanode`.

## Что остаётся на 443/udp

Hysteria2. HTTP/3 у прокси выключён блоком `protocols h1 h2` именно поэтому:
иначе браузеры получали бы Alt-Svc с обещанием h3 на 443/udp, уходили туда,
упирались в Hysteria2 и ждали таймаута перед откатом на HTTP/2.

## Выпуск сертификатов после переключения

Порт 80 остаётся у прокси, поэтому ACME по HTTP-01 продолжает работать без изменений.
Если продление всё же начнёт падать — смотреть `docker logs sitelens-caddy-1` и
проверять, что 80 никем не занят.
