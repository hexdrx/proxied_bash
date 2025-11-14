#!/bin/bash

# Генератор конфигурации xray из VLESS URL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XRAY_CONFIG_DIR="$HOME/.config/xray"
XRAY_CONFIG_FILE="$XRAY_CONFIG_DIR/config.json"
XRAY_PID_FILE="/tmp/xray_vpn.pid"
LOCAL_SOCKS_PORT=1080
LOCAL_HTTP_PORT=1081

# Создаем директорию для конфигурации
mkdir -p "$XRAY_CONFIG_DIR"

generate_xray_config() {
    local vless_url="$1"

    # Парсим VLESS URL
    source "$SCRIPT_DIR/vless_parser.sh"
    local parsed_json=$(parse_vless_url "$vless_url")

    if [ $? -ne 0 ]; then
        echo "Error: Failed to parse VLESS URL" >&2
        return 1
    fi

    # Извлекаем значения из JSON (простой парсинг)
    local uuid=$(echo "$parsed_json" | grep '"uuid"' | cut -d'"' -f4)
    local host=$(echo "$parsed_json" | grep '"host"' | cut -d'"' -f4)
    local port=$(echo "$parsed_json" | grep '"port"' | cut -d':' -f2 | tr -d ' ,')
    local flow=$(echo "$parsed_json" | grep '"flow"' | cut -d'"' -f4)
    local security=$(echo "$parsed_json" | grep '"security"' | cut -d'"' -f4)
    local type=$(echo "$parsed_json" | grep '"type"' | cut -d'"' -f4)
    local alpn=$(echo "$parsed_json" | grep '"alpn"' | cut -d'"' -f4)
    local sni=$(echo "$parsed_json" | grep '"sni"' | cut -d'"' -f4)
    local fp=$(echo "$parsed_json" | grep '"fp"' | cut -d'"' -f4)
    local pbk=$(echo "$parsed_json" | grep '"pbk"' | cut -d'"' -f4)

    # Конвертируем alpn в массив JSON
    local alpn_array="[]"
    if [ -n "$alpn" ]; then
        alpn_array="["
        IFS=',' read -ra ALPN_PARTS <<< "$alpn"
        for i in "${!ALPN_PARTS[@]}"; do
            if [ $i -gt 0 ]; then
                alpn_array+=","
            fi
            alpn_array+="\"${ALPN_PARTS[$i]}\""
        done
        alpn_array+="]"
    fi

    # Строим секцию flow (если есть)
    local flow_section=""
    if [ -n "$flow" ]; then
        flow_section="\"flow\": \"$flow\","
    fi

    # Строим секцию security
    local security_section="{}"
    if [ "$security" = "reality" ]; then
        security_section=$(cat <<EOF
{
    "serverName": "$sni",
    "fingerprint": "$fp",
    "publicKey": "$pbk"
}
EOF
)
    elif [ "$security" = "tls" ]; then
        security_section=$(cat <<EOF
{
    "serverName": "$sni",
    "fingerprint": "$fp",
    "alpn": $alpn_array
}
EOF
)
    fi

    # Генерируем конфигурацию xray
    cat > "$XRAY_CONFIG_FILE" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "port": $LOCAL_SOCKS_PORT,
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "udp": true
            },
            "tag": "socks-in"
        },
        {
            "port": $LOCAL_HTTP_PORT,
            "protocol": "http",
            "settings": {},
            "tag": "http-in"
        }
    ],
    "outbounds": [
        {
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": "$host",
                        "port": $port,
                        "users": [
                            {
                                "id": "$uuid",
                                "encryption": "none",
                                $flow_section
                                "level": 0
                            }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": "$type",
                "security": "$security",
                "realitySettings": $security_section
            },
            "tag": "proxy"
        }
    ]
}
EOF

    echo "Xray config generated at: $XRAY_CONFIG_FILE"
}

start_xray() {
    # Проверяем установлен ли xray
    if ! command -v xray &> /dev/null; then
        echo "Error: xray is not installed!" >&2
        echo "Please install xray: https://github.com/XTLS/Xray-core" >&2
        echo "" >&2
        echo "Quick install:" >&2
        echo "  bash -c \"\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install" >&2
        return 1
    fi

    # Проверяем запущен ли уже xray
    if [ -f "$XRAY_PID_FILE" ]; then
        local old_pid=$(cat "$XRAY_PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "Xray is already running (PID: $old_pid)"
            return 0
        fi
    fi

    # Запускаем xray в фоне
    xray -c "$XRAY_CONFIG_FILE" &> /tmp/xray_vpn.log &
    local xray_pid=$!
    echo "$xray_pid" > "$XRAY_PID_FILE"

    # Ждем немного чтобы xray запустился
    sleep 2

    # Проверяем что xray запустился
    if kill -0 "$xray_pid" 2>/dev/null; then
        echo "Xray started successfully (PID: $xray_pid)"
        echo "SOCKS proxy: 127.0.0.1:$LOCAL_SOCKS_PORT"
        echo "HTTP proxy: 127.0.0.1:$LOCAL_HTTP_PORT"
        return 0
    else
        echo "Error: Failed to start xray" >&2
        cat /tmp/xray_vpn.log >&2
        return 1
    fi
}

stop_xray() {
    if [ -f "$XRAY_PID_FILE" ]; then
        local pid=$(cat "$XRAY_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            echo "Xray stopped (PID: $pid)"
        fi
        rm -f "$XRAY_PID_FILE"
    else
        echo "Xray is not running"
    fi
}

# Основная функция
main() {
    case "$1" in
        start)
            if [ -z "$2" ]; then
                echo "Usage: $0 start <vless_url>"
                exit 1
            fi
            generate_xray_config "$2"
            start_xray
            ;;
        stop)
            stop_xray
            ;;
        restart)
            if [ -z "$2" ]; then
                echo "Usage: $0 restart <vless_url>"
                exit 1
            fi
            stop_xray
            generate_xray_config "$2"
            start_xray
            ;;
        status)
            if [ -f "$XRAY_PID_FILE" ]; then
                local pid=$(cat "$XRAY_PID_FILE")
                if kill -0 "$pid" 2>/dev/null; then
                    echo "Xray is running (PID: $pid)"
                    echo "SOCKS proxy: 127.0.0.1:$LOCAL_SOCKS_PORT"
                    echo "HTTP proxy: 127.0.0.1:$LOCAL_HTTP_PORT"
                else
                    echo "Xray is not running (stale PID file)"
                fi
            else
                echo "Xray is not running"
            fi
            ;;
        *)
            echo "Usage: $0 {start|stop|restart|status} [vless_url]"
            exit 1
            ;;
    esac
}

# Если скрипт вызван напрямую
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
