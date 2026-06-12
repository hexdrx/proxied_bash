# VPN Proxy Wrapper

Простая утилита для запуска любых команд через HTTP прокси, VLESS или Outline в Linux.

## Описание

`vpn` - это bash-скрипт, который позволяет запускать любые команды через HTTP/HTTPS прокси, VLESS или Outline/Shadowsocks протокол. Прокси настраивается один раз в файле `~/.vpn_proxy`, после чего вы можете запускать любую программу через прокси просто добавив префикс `vpn` перед командой.

## Возможности

- Работает с любыми программами, поддерживающими переменные окружения HTTP_PROXY/HTTPS_PROXY
- Поддержка HTTP прокси с авторизацией (логин/пароль)
- Поддержка VLESS протокола (через xray-core)
- Автоматический запуск xray для VLESS подключений
- Поддержка Outline/Shadowsocks (ss://) с Outline-префиксом (через outline-sdk)
- Автоматический запуск локального outline-proxy для ss:// подключений
- Простое обновление прокси через текстовый файл
- Не требует настройки каждой программы отдельно
- Легкая установка и удаление

## Установка

### Автоматическая установка

```bash
sudo ./install.sh
```

Скрипт автоматически:
1. Установит `vpn` в `/usr/local/bin/`
2. Создаст файл конфигурации `~/.vpn_proxy` из примера
3. Установит правильные права доступа

### Ручная установка

```bash
# Копируем скрипт
sudo cp vpn /usr/local/bin/vpn
sudo chmod +x /usr/local/bin/vpn

# Создаем файл с прокси
cp vpn_proxy.example ~/.vpn_proxy
chmod 600 ~/.vpn_proxy

# Редактируем прокси данные
nano ~/.vpn_proxy
```

## Настройка

Отредактируйте файл `~/.vpn_proxy` и укажите данные вашего прокси в одном из поддерживаемых форматов:

### HTTP Proxy

```
IP:PORT:USER:PASS
```

**Примеры:**

```
# С авторизацией
168.80.200.220:8000:username:password

# Без авторизации
192.168.1.1:3128::
```

**Важно:** Формат строгий - четыре поля разделенные двоеточием. Если логин/пароль не нужны, оставьте их пустыми, но двоеточия должны быть.

### VLESS Protocol

Для использования VLESS протокола необходимо установить [xray-core](https://github.com/XTLS/Xray-core).

**Быстрая установка xray:**
```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

**Формат VLESS URL:**
```
vless://UUID@HOST:PORT?параметры#имя
```

**Пример:**
```
vless://12345678-1234-1234-1234-123456789abc@example.com:443?flow=xtls-rprx-vision&security=reality&type=tcp&alpn=h2,http/1.1&sni=example.com&fp=chrome&pbk=YOUR_PUBLIC_KEY_HERE#example
```

При использовании VLESS, скрипт автоматически:
1. Парсит VLESS URL
2. Генерирует конфигурацию для xray
3. Запускает xray в фоновом режиме (если еще не запущен)
4. Использует локальный HTTP прокси от xray (127.0.0.1:1081)

### Outline / Shadowsocks (ss://)

Поддерживаются ключи Outline и обычный Shadowsocks, включая Outline-специфичный
параметр `prefix` (маскировка хендшейка под TLS для обхода DPI). Префикс не умеют
ни xray, ни sing-box, поэтому для `ss://` используется собственный хелпер
`outline-proxy` на базе [outline-sdk](https://github.com/Jigsaw-Code/outline-sdk).

В репозитории есть готовые бинарники `outline-proxy` под Linux (amd64) и
macOS (arm64/amd64) — `install.sh` выбирает нужный по `uname`, Go не требуется.
Для других платформ хелпер собирается из исходников (нужен [Go](https://go.dev/dl/)).

**Формат ss:// URL (SIP002 / Outline):**
```
ss://BASE64(method:password)@HOST:PORT?outline=1&prefix=...#имя
```

**Пример:**
```
ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpQQVNTV09SRA@example.com:993/?outline=1&prefix=%17%03%03%3F#My Server
```

При использовании Outline, скрипт автоматически:
1. Чистит URL (отрезает имя, убирает `outline=1`, сохраняет `prefix`)
2. Запускает `outline-proxy` в фоне (если ещё не запущен)
3. Использует локальный HTTP прокси от outline-proxy (127.0.0.1:1082)

Подробности — в [OUTLINE_GUIDE.md](OUTLINE_GUIDE.md).

## Использование

### Базовое использование

Просто добавьте `vpn` перед любой командой:

```bash
# Проверить IP через прокси
vpn curl ifconfig.me

# Скачать файл
vpn wget https://example.com/file.zip

# Клонировать git репозиторий
vpn git clone https://github.com/user/repo.git

# Установить npm пакеты
vpn npm install

# Обновить apt пакеты
vpn apt update
```

### Примеры использования

```bash
# Проверка что прокси работает
curl ifconfig.me           # Покажет ваш реальный IP
vpn curl ifconfig.me       # Покажет IP прокси-сервера

# Скачивание через прокси
vpn wget https://releases.ubuntu.com/22.04/ubuntu-22.04.3-desktop-amd64.iso

# Работа с Docker через прокси
vpn docker pull nginx

# Python pip через прокси
vpn pip install requests

# Браузерные команды через прокси
vpn lynx https://google.com
```

## Обновление прокси

Для смены прокси просто отредактируйте файл `~/.vpn_proxy`:

```bash
nano ~/.vpn_proxy
```

Изменения применятся немедленно при следующем запуске команды с `vpn`.

## Поддерживаемые программы

Работает со всеми программами, которые используют стандартные переменные окружения:
- `http_proxy`
- `https_proxy`
- `HTTP_PROXY`
- `HTTPS_PROXY`

### Протестированные программы:
- ✅ curl
- ✅ wget
- ✅ git
- ✅ apt / apt-get
- ✅ npm / yarn
- ✅ pip
- ✅ docker
- ✅ lynx / w3m
- ✅ python requests
- ✅ go get
- ✅ composer

### Могут не работать:
- ❌ ssh (используйте ProxyCommand в ~/.ssh/config)
- ❌ Некоторые GUI приложения (нужна настройка в самом приложении)
- ❌ Программы использующие только SOCKS прокси

## Удаление

```bash
sudo rm /usr/local/bin/vpn
rm ~/.vpn_proxy
```

## Безопасность

**Важно:** Файл `~/.vpn_proxy` содержит ваш логин и пароль в открытом виде!

Рекомендации:
- Установите права `600` на файл (только владелец может читать)
- Не добавляйте файл в git репозиторий
- Используйте отдельный пароль для прокси

```bash
chmod 600 ~/.vpn_proxy
```

## Структура файлов

```
proxied_bash/
├── vpn                   # Основной скрипт
├── vless_parser.sh       # Парсер VLESS URL
├── vless_to_xray.sh      # Генератор конфигурации xray из VLESS
├── ss_parser.sh          # Парсер Outline/Shadowsocks (ss://) URL
├── ss_to_outline.sh      # Менеджер локального outline-proxy
├── outline-proxy/        # Go-хелпер (Outline-префикс) на базе outline-sdk
├── vpn_proxy.example     # Пример конфигурации
├── install.sh            # Скрипт установки
├── uninstall.sh          # Скрипт удаления
└── README.md             # Эта документация
```

## Как это работает

### HTTP Proxy режим

Скрипт `vpn`:
1. Читает данные прокси из `~/.vpn_proxy`
2. Парсит формат `IP:PORT:USER:PASS`
3. Устанавливает переменные окружения:
   - `http_proxy=http://USER:PASS@IP:PORT`
   - `https_proxy=http://USER:PASS@IP:PORT`
   - `HTTP_PROXY=...`
   - `HTTPS_PROXY=...`
4. Запускает вашу команду с этими переменными

### VLESS режим

Когда в `~/.vpn_proxy` указан VLESS URL:
1. Скрипт определяет что это VLESS по префиксу `vless://`
2. Вызывает `vless_parser.sh` для парсинга URL
3. Вызывает `vless_to_xray.sh` для генерации конфигурации xray
4. Запускает xray в фоне (если еще не запущен)
5. Xray создает локальный SOCKS (порт 1080) и HTTP (порт 1081) прокси
6. Скрипт устанавливает переменные окружения на локальный HTTP прокси
7. Запускает вашу команду через локальный прокси

### Outline режим

Когда в `~/.vpn_proxy` указан ss:// URL:
1. Скрипт определяет что это Outline/Shadowsocks по префиксу `ss://`
2. Вызывает `ss_parser.sh` для очистки URL (имя, `outline=1`, `prefix`)
3. Вызывает `ss_to_outline.sh` для запуска хелпера `outline-proxy`
4. `outline-proxy` поднимает локальный HTTP прокси (порт 1082) и дайлит
   Shadowsocks-соединение с сохранением Outline-префикса
5. Скрипт устанавливает переменные окружения на локальный HTTP прокси
6. Запускает вашу команду через локальный прокси

## Управление xray (для VLESS)

При использовании VLESS, вы можете управлять xray напрямую:

```bash
# Проверить статус xray
vless_to_xray.sh status

# Остановить xray
vless_to_xray.sh stop

# Перезапустить с новой конфигурацией
vless_to_xray.sh restart "vless://..."
```

## Управление outline-proxy (для Outline)

При использовании Outline вы можете управлять хелпером напрямую:

```bash
# Проверить статус
ss_to_outline.sh status

# Остановить
ss_to_outline.sh stop

# Перезапустить с новым ключом
ss_to_outline.sh restart "ss://..."
```

## Troubleshooting

### Команда не работает через прокси

Проверьте что программа поддерживает HTTP_PROXY переменные:

```bash
# Для curl - должно работать
vpn curl -v ifconfig.me

# Проверка переменных
vpn env | grep -i proxy
```

### HTTP прокси недоступен

```bash
# Проверьте доступность прокси
nc -zv PROXY_IP PROXY_PORT

# Или через telnet
telnet PROXY_IP PROXY_PORT
```

### VLESS не работает

```bash
# Проверьте установлен ли xray
which xray

# Проверьте статус xray
vless_to_xray.sh status

# Проверьте логи xray
cat /tmp/xray_vpn.log

# Проверьте конфигурацию xray
cat ~/.config/xray/config.json
```

### Неверный формат файла

**Для HTTP прокси** - проверьте что в `~/.vpn_proxy` ровно одна строка в формате:
```
IP:PORT:USER:PASS
```

**Для VLESS** - проверьте что URL начинается с `vless://`:
```
vless://UUID@HOST:PORT?параметры#имя
```

Без пробелов, без лишних символов.

## Лицензия

Свободное использование без ограничений.

## Автор

Создано для упрощения работы с HTTP прокси в Linux.
