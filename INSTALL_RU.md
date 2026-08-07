# Быстрая установка

## Шаг 1: Установка

```bash
sudo ./install.sh
```

## Шаг 2: Настройка прокси

Отредактируйте файл с данными прокси:

```bash
nano ~/.vpn_proxy
```

Укажите один из трёх форматов:

```
https://example.com/sub/vless/UUID     # подписка (выбор страны)
vless://UUID@HOST:PORT?params#name     # одиночный VLESS сервер
IP:PORT:USER:PASS                      # HTTP-прокси
```

Пример HTTP-прокси:
```
168.80.200.220:8000:myuser:mypassword
```

Для VLESS и подписки нужен [xray-core](https://github.com/XTLS/Xray-core):
```bash
brew install xray   # macOS
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install   # Linux
```

## Шаг 3: Использование

Запускайте любые команды через прокси добавив префикс `vpn`:

```bash
# Проверить IP
vpn curl ifconfig.me

# Скачать файл
vpn wget https://example.com/file.zip

# Установить пакеты
vpn apt update
vpn npm install
```

## Шаг 4: Выбор страны (для подписки)

```bash
vpn list                     # доступные страны
vpn use de                   # выбрать Германию по умолчанию
vpn curl ifconfig.me         # запрос через Германию
vpn -c jp curl ifconfig.me   # разово через Японию
vpn status                   # что сейчас запущено
vpn stop all                 # остановить всё
```

## Готово!

Теперь вы можете запускать любые команды через прокси.

Для смены прокси просто измените `~/.vpn_proxy` - изменения применятся сразу.

## Удаление

```bash
sudo ./uninstall.sh
```
