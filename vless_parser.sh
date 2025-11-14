#!/bin/bash

# Парсер VLESS URL в конфигурацию xray

parse_vless_url() {
    local vless_url="$1"

    # Проверяем что это VLESS URL
    if [[ ! "$vless_url" =~ ^vless:// ]]; then
        echo "Error: Not a valid VLESS URL" >&2
        return 1
    fi

    # Убираем префикс vless://
    local url_without_prefix="${vless_url#vless://}"

    # Извлекаем имя/тег (после #)
    local name=""
    if [[ "$url_without_prefix" =~ \#(.+)$ ]]; then
        name="${BASH_REMATCH[1]}"
        url_without_prefix="${url_without_prefix%#*}"
    fi

    # Разделяем на основную часть и параметры (по ?)
    local main_part="${url_without_prefix%%\?*}"
    local params_part=""
    if [[ "$url_without_prefix" == *"?"* ]]; then
        params_part="${url_without_prefix#*\?}"
    fi

    # Парсим основную часть: UUID@HOST:PORT
    local uuid="${main_part%%@*}"
    local host_port="${main_part#*@}"
    local host="${host_port%:*}"
    local port="${host_port##*:}"

    # Инициализируем параметры значениями по умолчанию
    local flow=""
    local security="none"
    local type="tcp"
    local alpn=""
    local sni=""
    local fp=""
    local pbk=""
    local path=""
    local headerType=""

    # Парсим параметры
    if [ -n "$params_part" ]; then
        IFS='&' read -ra PARAMS <<< "$params_part"
        for param in "${PARAMS[@]}"; do
            key="${param%%=*}"
            value="${param#*=}"
            # URL decode value
            value=$(printf '%b' "${value//%/\\x}")

            case "$key" in
                flow) flow="$value" ;;
                security) security="$value" ;;
                type) type="$value" ;;
                alpn) alpn="$value" ;;
                sni) sni="$value" ;;
                fp) fp="$value" ;;
                pbk) pbk="$value" ;;
                path) path="$value" ;;
                headerType) headerType="$value" ;;
            esac
        done
    fi

    # Выводим результат в формате JSON
    cat <<EOF
{
    "uuid": "$uuid",
    "host": "$host",
    "port": $port,
    "flow": "$flow",
    "security": "$security",
    "type": "$type",
    "alpn": "$alpn",
    "sni": "$sni",
    "fp": "$fp",
    "pbk": "$pbk",
    "path": "$path",
    "headerType": "$headerType",
    "name": "$name"
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
