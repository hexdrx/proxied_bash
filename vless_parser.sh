#!/bin/bash

# Парсер VLESS URL в конфигурацию xray

# URL-декодирование значения (%XX -> байт)
vless_urldecode() {
    local value="$1"
    # Экранируем обратные слэши, чтобы printf %b их не съел
    value="${value//\\/\\\\}"
    printf '%b' "${value//%/\\x}"
}

# Разбирает VLESS URL и складывает результат в переменные VLESS_*.
# Используется генератором конфига — надёжнее, чем парсить обратно JSON.
parse_vless_vars() {
    local vless_url="$1"

    # Проверяем что это VLESS URL
    if [[ ! "$vless_url" =~ ^vless:// ]]; then
        echo "Error: Not a valid VLESS URL" >&2
        return 1
    fi

    # Убираем префикс vless://
    local url_without_prefix="${vless_url#vless://}"

    # Извлекаем имя/тег (после #)
    VLESS_NAME=""
    if [[ "$url_without_prefix" == *"#"* ]]; then
        VLESS_NAME=$(vless_urldecode "${url_without_prefix#*#}")
        url_without_prefix="${url_without_prefix%%#*}"
    fi

    # Разделяем на основную часть и параметры (по ?)
    local main_part="${url_without_prefix%%\?*}"
    local params_part=""
    if [[ "$url_without_prefix" == *"?"* ]]; then
        params_part="${url_without_prefix#*\?}"
    fi

    # Парсим основную часть: UUID@HOST:PORT
    VLESS_UUID="${main_part%%@*}"
    local host_port="${main_part#*@}"
    VLESS_HOST="${host_port%:*}"
    VLESS_PORT="${host_port##*:}"

    # Значения по умолчанию
    VLESS_FLOW=""
    VLESS_SECURITY="none"
    VLESS_TYPE="tcp"
    VLESS_ALPN=""
    VLESS_SNI=""
    VLESS_FP=""
    VLESS_PBK=""
    VLESS_SID=""
    VLESS_SPX=""
    VLESS_PATH=""
    VLESS_MODE=""
    VLESS_HEADERTYPE=""
    VLESS_SERVICENAME=""
    VLESS_HOSTHEADER=""
    VLESS_ALLOWINSECURE="0"

    # Парсим параметры
    if [ -n "$params_part" ]; then
        local param key value
        local PARAMS
        IFS='&' read -ra PARAMS <<< "$params_part"
        for param in "${PARAMS[@]}"; do
            key="${param%%=*}"
            value=$(vless_urldecode "${param#*=}")

            case "$key" in
                flow) VLESS_FLOW="$value" ;;
                security) VLESS_SECURITY="$value" ;;
                type) VLESS_TYPE="$value" ;;
                alpn) VLESS_ALPN="$value" ;;
                sni) VLESS_SNI="$value" ;;
                fp) VLESS_FP="$value" ;;
                pbk) VLESS_PBK="$value" ;;
                sid) VLESS_SID="$value" ;;
                spx) VLESS_SPX="$value" ;;
                path) VLESS_PATH="$value" ;;
                mode) VLESS_MODE="$value" ;;
                headerType) VLESS_HEADERTYPE="$value" ;;
                serviceName) VLESS_SERVICENAME="$value" ;;
                host) VLESS_HOSTHEADER="$value" ;;
                allowInsecure) VLESS_ALLOWINSECURE="$value" ;;
            esac
        done
    fi

    # SNI по умолчанию — сам хост
    if [ -z "$VLESS_SNI" ]; then
        VLESS_SNI="$VLESS_HOST"
    fi

    return 0
}

parse_vless_url() {
    parse_vless_vars "$1" || return 1

    # Выводим результат в формате JSON
    cat <<EOF
{
    "uuid": "$VLESS_UUID",
    "host": "$VLESS_HOST",
    "port": $VLESS_PORT,
    "flow": "$VLESS_FLOW",
    "security": "$VLESS_SECURITY",
    "type": "$VLESS_TYPE",
    "alpn": "$VLESS_ALPN",
    "sni": "$VLESS_SNI",
    "fp": "$VLESS_FP",
    "pbk": "$VLESS_PBK",
    "sid": "$VLESS_SID",
    "spx": "$VLESS_SPX",
    "path": "$VLESS_PATH",
    "mode": "$VLESS_MODE",
    "headerType": "$VLESS_HEADERTYPE",
    "serviceName": "$VLESS_SERVICENAME",
    "name": "$VLESS_NAME"
}
EOF
}

# Если скрипт вызван напрямую
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ $# -eq 0 ]; then
        echo "Usage: $0 <vless_url>"
        exit 1
    fi
    parse_vless_url "$1"
fi
