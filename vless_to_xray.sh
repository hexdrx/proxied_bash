#!/bin/bash

# Генератор конфигурации xray из VLESS URL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XRAY_CONFIG_DIR="$HOME/.config/xray"
XRAY_CONFIG_FILE="$XRAY_CONFIG_DIR/config.json"
XRAY_PID_FILE="/tmp/xray_vpn.pid"
LOCAL_SOCKS_PORT=1080
LOCAL_HTTP_PORT=1081

# Экранирование строки для вставки в JSON
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# generate_xray_config <vless_url> [config_file] [socks_port] [http_port]
generate_xray_config() {
    local vless_url="$1"
    local config_file="${2:-$XRAY_CONFIG_FILE}"
    local socks_port="${3:-$LOCAL_SOCKS_PORT}"
    local http_port="${4:-$LOCAL_HTTP_PORT}"

    # Парсим VLESS URL — результат попадает в переменные VLESS_*
    source "$SCRIPT_DIR/vless_parser.sh"
    if ! parse_vless_vars "$vless_url"; then
        echo "Error: Failed to parse VLESS URL" >&2
        return 1
    fi

    mkdir -p "$(dirname "$config_file")"

    # Конвертируем alpn в массив JSON
    local alpn_array="[]"
    if [ -n "$VLESS_ALPN" ]; then
        local ALPN_PARTS i
        alpn_array="["
        IFS=',' read -ra ALPN_PARTS <<< "$VLESS_ALPN"
        for i in "${!ALPN_PARTS[@]}"; do
            if [ "$i" -gt 0 ]; then
                alpn_array+=","
            fi
            alpn_array+="\"$(json_escape "${ALPN_PARTS[$i]}")\""
        done
        alpn_array+="]"
    fi

    # Секция flow (только если задан)
    local flow_section=""
    if [ -n "$VLESS_FLOW" ]; then
        flow_section="\"flow\": \"$(json_escape "$VLESS_FLOW")\","
    fi

    # Секция безопасности: reality / tls / без шифрования
    local security_section=""
    case "$VLESS_SECURITY" in
        reality)
            security_section="\"realitySettings\": {
                    \"serverName\": \"$(json_escape "$VLESS_SNI")\",
                    \"fingerprint\": \"$(json_escape "$VLESS_FP")\",
                    \"publicKey\": \"$(json_escape "$VLESS_PBK")\",
                    \"shortId\": \"$(json_escape "$VLESS_SID")\",
                    \"spiderX\": \"$(json_escape "$VLESS_SPX")\"
                },"
            ;;
        tls)
            local allow_insecure="false"
            if [ "$VLESS_ALLOWINSECURE" = "1" ] || [ "$VLESS_ALLOWINSECURE" = "true" ]; then
                allow_insecure="true"
            fi
            security_section="\"tlsSettings\": {
                    \"serverName\": \"$(json_escape "$VLESS_SNI")\",
                    \"fingerprint\": \"$(json_escape "$VLESS_FP")\",
                    \"allowInsecure\": $allow_insecure,
                    \"alpn\": $alpn_array
                },"
            ;;
    esac

    # Заголовок Host для транспортов: явный host= или SNI
    local host_header="$VLESS_HOSTHEADER"
    if [ -z "$host_header" ]; then
        host_header="$VLESS_SNI"
    fi

    # Секция транспорта
    local transport_section=""
    case "$VLESS_TYPE" in
        xhttp|splithttp)
            local xhttp_mode="${VLESS_MODE:-auto}"
            transport_section="\"xhttpSettings\": {
                    \"path\": \"$(json_escape "${VLESS_PATH:-/}")\",
                    \"host\": \"$(json_escape "$host_header")\",
                    \"mode\": \"$(json_escape "$xhttp_mode")\"
                },"
            ;;
        ws)
            transport_section="\"wsSettings\": {
                    \"path\": \"$(json_escape "${VLESS_PATH:-/}")\",
                    \"headers\": { \"Host\": \"$(json_escape "$host_header")\" }
                },"
            ;;
        httpupgrade)
            transport_section="\"httpupgradeSettings\": {
                    \"path\": \"$(json_escape "${VLESS_PATH:-/}")\",
                    \"host\": \"$(json_escape "$host_header")\"
                },"
            ;;
        grpc)
            transport_section="\"grpcSettings\": {
                    \"serviceName\": \"$(json_escape "$VLESS_SERVICENAME")\"
                },"
            ;;
    esac

    # xray называет транспорт splithttp старым именем — приводим к xhttp
    local network="$VLESS_TYPE"
    if [ "$network" = "splithttp" ]; then
        network="xhttp"
    fi

    # Генерируем конфигурацию xray
    cat > "$config_file" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "127.0.0.1",
            "port": $socks_port,
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "udp": true
            },
            "tag": "socks-in"
        },
        {
            "listen": "127.0.0.1",
            "port": $http_port,
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
                        "address": "$(json_escape "$VLESS_HOST")",
                        "port": $VLESS_PORT,
                        "users": [
                            {
                                "id": "$(json_escape "$VLESS_UUID")",
                                "encryption": "none",
                                $flow_section
                                "level": 0
                            }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": "$(json_escape "$network")",
                "security": "$(json_escape "$VLESS_SECURITY")",
                $security_section
                $transport_section
                "sockopt": {}
            },
            "tag": "proxy"
        }
    ]
}
EOF

    echo "Xray config generated at: $config_file"
}

# start_xray [config_file] [pid_file] [log_file]
start_xray() {
    local config_file="${1:-$XRAY_CONFIG_FILE}"
    local pid_file="${2:-$XRAY_PID_FILE}"
    local log_file="${3:-/tmp/xray_vpn.log}"

    # Проверяем установлен ли xray
    if ! command -v xray &> /dev/null; then
        echo "Error: xray is not installed!" >&2
        echo "Please install xray: https://github.com/XTLS/Xray-core" >&2
        echo "" >&2
        echo "Quick install:" >&2
        echo "  brew install xray" >&2
        echo "  bash -c \"\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install" >&2
        return 1
    fi

    # Проверяем запущен ли уже xray
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "Xray is already running (PID: $old_pid)"
            return 0
        fi
    fi

    # Запускаем xray в фоне
    xray -c "$config_file" &> "$log_file" &
    local xray_pid=$!
    echo "$xray_pid" > "$pid_file"

    # Ждем немного чтобы xray запустился
    sleep 1

    # Проверяем что xray запустился
    if kill -0 "$xray_pid" 2>/dev/null; then
        echo "Xray started successfully (PID: $xray_pid)"
        return 0
    else
        echo "Error: Failed to start xray" >&2
        cat "$log_file" >&2
        rm -f "$pid_file"
        return 1
    fi
}

# stop_xray [pid_file]
stop_xray() {
    local pid_file="${1:-$XRAY_PID_FILE}"

    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            echo "Xray stopped (PID: $pid)"
        fi
        rm -f "$pid_file"
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
