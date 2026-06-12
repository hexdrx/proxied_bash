#!/bin/bash

# Парсер Outline / Shadowsocks (ss://) URL.
#
# Задача — подготовить "чистую" transport-строку для outline-proxy:
#   * проверить префикс ss://
#   * отрезать #fragment (имя профиля, часто с эмодзи)
#   * убрать клиентский параметр outline=1 (транспорту не нужен)
#   * СОХРАНИТЬ параметр prefix (маскировка хендшейка под TLS)
# userinfo (base64 method:password, SIP002) не трогаем — outline-sdk его понимает.

# Возвращает очищенный transport-URL в stdout.
clean_ss_url() {
    local ss_url="$1"

    if [[ ! "$ss_url" =~ ^ss:// ]]; then
        echo "Error: Not a valid Shadowsocks/Outline URL" >&2
        return 1
    fi

    # Отрезаем #fragment (имя), если есть
    local without_fragment="${ss_url%%#*}"

    # Делим на базовую часть и query (по первому ?)
    local base="${without_fragment%%\?*}"
    local query=""
    if [[ "$without_fragment" == *"?"* ]]; then
        query="${without_fragment#*\?}"
    fi

    # Чистим query: выкидываем параметр outline (и пустые сегменты)
    local cleaned=""
    if [ -n "$query" ]; then
        local IFS='&'
        local param
        for param in $query; do
            [ -z "$param" ] && continue
            case "$param" in
                outline=*) continue ;;
            esac
            if [ -z "$cleaned" ]; then
                cleaned="$param"
            else
                cleaned="$cleaned&$param"
            fi
        done
    fi

    if [ -n "$cleaned" ]; then
        echo "${base}?${cleaned}"
    else
        echo "$base"
    fi
}

# Возвращает имя профиля (часть после #), если есть.
ss_url_name() {
    local ss_url="$1"
    if [[ "$ss_url" == *"#"* ]]; then
        printf '%b' "${ss_url#*#}"
    fi
}

# Прямой запуск — для отладки
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ $# -eq 0 ]; then
        echo "Usage: $0 <ss_url>"
        exit 1
    fi
    echo "Transport: $(clean_ss_url "$1")"
    echo "Name:      $(ss_url_name "$1")"
fi
