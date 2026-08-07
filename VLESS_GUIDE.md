# Руководство по использованию VLESS

## Что такое VLESS?

VLESS - это облегченный протокол для безопасного соединения, используемый в xray-core. Он обеспечивает шифрование и обход блокировок.

## Быстрый старт

### 1. Установка xray-core

```bash
# Автоматическая установка
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Проверка установки
xray version
```

### 2. Установка VPN Proxy Wrapper

```bash
sudo ./install.sh
```

### 3. Настройка VLESS ключа

Откройте файл конфигурации:
```bash
nano ~/.vpn_proxy
```

Вставьте ваш VLESS ключ (замените пример своим ключом):
```
vless://12345678-1234-1234-1234-123456789abc@example.com:443?flow=xtls-rprx-vision&security=reality&type=tcp&alpn=h2,http/1.1&sni=example.com&fp=chrome&pbk=YOUR_PUBLIC_KEY_HERE#example
```

Сохраните файл (Ctrl+O, Enter, Ctrl+X).

### 4. Использование

Теперь просто добавьте `vpn` перед любой командой:

```bash
# Проверить IP (должен показать IP вашего VPN сервера)
vpn curl ifconfig.me

# Скачать файл через VPN
vpn wget https://example.com/file.zip

# Обновить пакеты через VPN
vpn apt update

# Клонировать git репозиторий через VPN
vpn git clone https://github.com/user/repo.git
```

## Формат VLESS URL

```
vless://UUID@HOST:PORT?параметры#имя
```

### Основные параметры:

- **UUID** - уникальный идентификатор пользователя
- **HOST** - адрес VPN сервера
- **PORT** - порт подключения (обычно 443)

### Дополнительные параметры (опциональные):

- `flow` - режим передачи данных (например, xtls-rprx-vision)
- `security` - тип шифрования (tls, reality, none)
- `type` - тип сетевого транспорта (tcp, ws, xhttp, httpupgrade, grpc)
- `sni` - имя сервера для TLS/Reality (по умолчанию берётся сам хост)
- `alpn` - протоколы уровня приложения (h2, http/1.1)
- `fp` - fingerprint браузера (chrome, firefox, safari, qq)
- `pbk` - публичный ключ для Reality
- `sid` - short ID для Reality
- `spx` - spiderX для Reality
- `path` - путь для WebSocket / xhttp / httpupgrade
- `mode` - режим xhttp (auto, packet-up, stream-up, stream-one)
- `host` - заголовок Host для WebSocket / xhttp
- `serviceName` - имя сервиса для gRPC
- `#имя` - имя подключения (для удобства)

## Примеры VLESS URL

### VLESS с Reality (рекомендуется)
```
vless://UUID@example.com:443?security=reality&sni=example.com&fp=chrome&pbk=PUBLIC_KEY&flow=xtls-rprx-vision&type=tcp#MyVPN
```

### VLESS с TLS
```
vless://UUID@example.com:443?security=tls&sni=example.com&alpn=h2,http/1.1&type=tcp#MyVPN
```

### VLESS с WebSocket
```
vless://UUID@example.com:443?type=ws&security=tls&path=/websocket&sni=example.com#MyVPN
```

### VLESS с XHTTP + Reality
```
vless://UUID@example.com:3478?security=reality&type=xhttp&mode=packet-up&path=/&sni=example.com&fp=qq&pbk=PUBLIC_KEY#MyVPN
```

### VLESS без шифрования (не рекомендуется)
```
vless://UUID@example.com:8080?security=none&type=tcp#MyVPN
```

## Подписка вместо одного ключа

Многие провайдеры выдают не отдельный ключ, а ссылку на подписку - список
серверов по странам. Её можно положить в `~/.vpn_proxy` целиком:

```
https://cdn.example.com/sub/vless/12345678-1234-1234-1234-123456789abc
```

После этого доступен выбор страны:

```bash
vpn list                     # список стран из подписки
vpn use de                   # выбрать страну по умолчанию
vpn curl ifconfig.me         # запрос через выбранную страну
vpn -c jp curl ifconfig.me   # разово через другую
vpn update                   # перечитать подписку
```

Список серверов кэшируется в `~/.cache/vpn/servers.tsv` и обновляется раз в
сутки. Для каждой страны поднимается отдельный процесс xray, так что команды
через разные страны можно запускать одновременно.

## Управление xray

При первом запуске команды с `vpn`, xray запустится автоматически в фоновом режиме.

### Проверить статус
```bash
vpn status
```

### Остановить
```bash
vpn stop de     # одну страну
vpn stop all    # все
```

### Посмотреть логи и конфигурацию
```bash
# Для подписки - по стране
cat ~/.cache/vpn/de/xray.log
cat ~/.cache/vpn/de/config.json

# Для одиночного VLESS
cat ~/.cache/vpn/single/xray.log
cat ~/.cache/vpn/single/config.json
```

### Управление напрямую (одиночный VLESS)
```bash
vless_to_xray.sh status
vless_to_xray.sh stop
vless_to_xray.sh restart "vless://..."
```

## Как работает VLESS режим

1. Вы запускаете команду с префиксом `vpn`
2. Скрипт определяет VLESS URL в `~/.vpn_proxy` (или берёт нужную страну из подписки)
3. Генерируется конфигурация для xray
4. Xray запускается в фоне (если еще не запущен) на свободной паре портов -
   SOCKS5 и HTTP на 127.0.0.1, начиная с 1080
5. Скрипт перенаправляет вашу команду через локальный HTTP прокси
6. Xray шифрует трафик и отправляет на VPN сервер

Порты не фиксированы: каждая страна получает свою пару, чтобы несколько
подключений могли работать одновременно. Посмотреть их можно через `vpn status`.

## Поддерживаемые протоколы VLESS

- ✅ VLESS + TCP + Reality (самый безопасный)
- ✅ VLESS + XHTTP + Reality
- ✅ VLESS + TCP + TLS
- ✅ VLESS + WebSocket + TLS
- ✅ VLESS + HTTPUpgrade + TLS
- ✅ VLESS + gRPC + TLS
- ✅ VLESS + TCP без шифрования

## Troubleshooting

### xray не установлен
```bash
# Установите xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Проверьте установку
which xray
xray version
```

### Ошибка при парсинге VLESS URL
```bash
# Проверьте формат URL
cat ~/.vpn_proxy

# URL должен начинаться с vless://
# Не должно быть лишних пробелов или переносов строк
```

### Соединение не устанавливается
```bash
# Что запущено и на каких портах
vpn status

# Логи и конфиг (подставьте свою страну или single)
cat ~/.cache/vpn/de/xray.log
cat ~/.cache/vpn/de/config.json

# Проверьте доступность сервера
ping HOST

# Проверьте что конфиг валиден для xray
xray -test -c ~/.cache/vpn/de/config.json
```

### Медленное соединение
```bash
# Попробуйте другой VLESS сервер
# Проверьте параметр flow - для Reality обычно используется xtls-rprx-vision
# Проверьте параметр alpn - рекомендуется h2,http/1.1
```

## Получение VLESS ключей

VLESS ключи обычно предоставляются:
1. Вашим VPN провайдером
2. В панелях управления VPN серверами (x-ui, v2-ui, 3x-ui)
3. Можно настроить свой собственный VLESS сервер

**Важно:** Используйте только доверенные источники VLESS ключей!

## Безопасность

- Файл `~/.vpn_proxy` содержит ваш VLESS ключ
- Установите права доступа: `chmod 600 ~/.vpn_proxy`
- Не делитесь VLESS ключом с другими
- Не добавляйте `~/.vpn_proxy` в git
- Регулярно меняйте VLESS ключи

## Дополнительные ресурсы

- [Xray-core GitHub](https://github.com/XTLS/Xray-core)
- [Документация Xray](https://xtls.github.io/)
- [VLESS Protocol](https://github.com/XTLS/Xray-core/discussions/716)
