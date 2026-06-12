# Outline / Shadowsocks (ss://) — руководство

Поддержка ключей Outline и обычного Shadowsocks в `vpn`, включая
Outline-специфичный параметр `prefix` (маскировка хендшейка под TLS для обхода
DPI).

## Почему отдельный движок

Параметр `prefix` из Outline не поддерживается ни **xray-core**, ни **sing-box**
(фичу [отклонили](https://github.com/SagerNet/sing-box/issues/3230)), ни mihomo.
Единственная реализация — [outline-sdk](https://github.com/Jigsaw-Code/outline-sdk)
от Jigsaw (Go). Поэтому для `ss://` используется собственный маленький хелпер
`outline-proxy` на базе outline-sdk, который поднимает локальный HTTP-прокси и
дайлит Shadowsocks-соединение с сохранением префикса.

Если префикс вам не нужен — Shadowsocks-ключ без `prefix` тоже будет работать
через этот же хелпер.

## Требования

- Ничего: в репозитории лежат готовые бинарники `outline-proxy` под
  Linux (amd64) и macOS (arm64/amd64) в `outline-proxy/bin/`. `install.sh`
  сам выбирает нужный по `uname`.
- [Go](https://go.dev/dl/) — **только** если нужна другая платформа (нет
  пребилта): тогда `install.sh` соберёт хелпер из исходников.

## Формат ключа

SIP002 / Outline:

```
ss://BASE64(method:password)@HOST:PORT?outline=1&prefix=...#имя
```

- `BASE64(method:password)` — userinfo, например `chacha20-ietf-poly1305:PASSWORD`
  в base64. Декодировать не нужно — outline-sdk понимает base64.
- `outline=1` — клиентский маркер Outline; для транспорта не нужен, скрипт его
  убирает.
- `prefix=...` — URL-encoded байты, которые добавляются в начало хендшейка
  (например `%17%03%03%3F` → байты `\x17\x03\x03\x3F`, заголовок TLS-записи).
  Скрипт его **сохраняет**.
- `#имя` — имя профиля (может содержать эмодзи); скрипт его отрезает.

## Настройка

Поместите ключ в `~/.vpn_proxy` (одна строка):

```bash
nano ~/.vpn_proxy
```

```
ss://key@example.com:993/?outline=1&prefix=%17%03%03%3F#My Server
```


## Использование

```bash
vpn curl https://ifconfig.me
vpn wget https://example.com
vpn git clone https://github.com/...
```

При первом запуске скрипт:
1. Чистит URL (`ss_parser.sh`): отрезает имя, убирает `outline=1`, сохраняет `prefix`.
2. Запускает `outline-proxy` в фоне на `127.0.0.1:18082`.
3. Экспортирует `http_proxy/https_proxy` на локальный прокси и запускает команду.

Повторные запуски переиспользуют уже работающий `outline-proxy`.

## Управление хелпером

```bash
# Статус
ss_to_outline.sh status

# Остановить
ss_to_outline.sh stop

# Перезапустить с новым ключом
ss_to_outline.sh restart "ss://..."
```

Файлы времени выполнения:
- PID: `/tmp/outline_vpn.pid`
- Лог: `/tmp/outline_vpn.log`
- Порт локального HTTP-прокси: `127.0.0.1:18082` (отдельный от xray/VLESS — `1081`)

## Проверка парсера

```bash
./test_ss.sh                # юнит-тесты ss_parser.sh
./ss_parser.sh "ss://...#name"   # показать очищенный transport-URL и имя
```

## Ручная сборка хелпера

```bash
cd outline-proxy
go build -o outline-proxy .
```

## Troubleshooting

- **"outline-proxy failed to start"** — посмотрите `/tmp/outline_vpn.log`.
  Частые причины: занят порт 18082, неверный ключ, нет сети до сервера.
- **"Go is not installed"** — установите Go и повторите, либо соберите хелпер
  вручную (см. выше).
- **Соединение проходит, но IP не сменился** — проверьте, что в `~/.vpn_proxy`
  именно ваш `ss://` ключ, и что `ss_to_outline.sh status` показывает running.
- **Префикс не нужен / мешает** — уберите `prefix=...` из ключа; всё остальное
  продолжит работать.
