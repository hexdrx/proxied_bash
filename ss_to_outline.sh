#!/bin/bash

# Менеджер локального outline-proxy для Outline / Shadowsocks (ss://) ключей.
# По образцу vless_to_xray.sh, но движок — собственный Go-хелпер outline-proxy,
# который умеет Outline-префикс (xray/sing-box не умеют).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTLINE_PID_FILE="/tmp/outline_vpn.pid"
OUTLINE_LOG_FILE="/tmp/outline_vpn.log"
OUTLINE_HTTP_PORT=18082  # отдельный высокий порт (1082 часто занимает VS Code)

# Подключаем парсер ss://
source "$SCRIPT_DIR/ss_parser.sh"

# Определяем платформу для выбора пребилт-бинарника (linux-amd64, darwin-arm64, ...)
outline_platform() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
    esac
    printf '%s-%s' "$os" "$arch"
}

# Определяем путь к бинарнику/исходникам outline-proxy.
#   * установленный бинарник: $SCRIPT_DIR/outline-proxy (файл)
#   * пребилт в репо:        $SCRIPT_DIR/outline-proxy/bin/outline-proxy-<os>-<arch>
#   * локальная сборка:      $SCRIPT_DIR/outline-proxy/outline-proxy
OUTLINE_SRC_DIR="$SCRIPT_DIR/outline-proxy"

resolve_outline_bin() {
    if [ -f "$SCRIPT_DIR/outline-proxy" ] && [ -x "$SCRIPT_DIR/outline-proxy" ]; then
        echo "$SCRIPT_DIR/outline-proxy"; return 0
    fi
    local prebuilt="$OUTLINE_SRC_DIR/bin/outline-proxy-$(outline_platform)"
    if [ -x "$prebuilt" ]; then
        echo "$prebuilt"; return 0
    fi
    if [ -x "$OUTLINE_SRC_DIR/outline-proxy" ]; then
        echo "$OUTLINE_SRC_DIR/outline-proxy"; return 0
    fi
    return 1
}

OUTLINE_BIN="$(resolve_outline_bin || echo "$OUTLINE_SRC_DIR/outline-proxy")"

# Гарантирует наличие бинарника: пребилт для платформы, иначе сборка из исходников.
ensure_binary() {
    local resolved
    if resolved="$(resolve_outline_bin)"; then
        OUTLINE_BIN="$resolved"
        return 0
    fi

    if [ ! -f "$OUTLINE_SRC_DIR/main.go" ]; then
        echo "Error: outline-proxy binary not found and no source to build it from." >&2
        echo "Expected a prebuilt binary for $(outline_platform) in $OUTLINE_SRC_DIR/bin/" >&2
        return 1
    fi

    if ! command -v go &> /dev/null; then
        echo "Error: outline-proxy is not built and Go is not installed." >&2
        echo "Install Go (https://go.dev/dl/) and re-run, or build manually:" >&2
        echo "  (cd \"$OUTLINE_SRC_DIR\" && go build -o outline-proxy .)" >&2
        return 1
    fi

    echo "Building outline-proxy helper (first run, may take a moment)..."
    if ! ( cd "$OUTLINE_SRC_DIR" && GOTOOLCHAIN=auto go build -o outline-proxy . ); then
        echo "Error: failed to build outline-proxy" >&2
        return 1
    fi
    OUTLINE_BIN="$OUTLINE_SRC_DIR/outline-proxy"
    return 0
}

start_outline() {
    local ss_url="$1"

    ensure_binary || return 1

    # Уже запущен?
    if [ -f "$OUTLINE_PID_FILE" ]; then
        local old_pid
        old_pid="$(cat "$OUTLINE_PID_FILE")"
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "outline-proxy is already running (PID: $old_pid)"
            return 0
        fi
    fi

    local transport name
    transport="$(clean_ss_url "$ss_url")" || return 1
    name="$(ss_url_name "$ss_url")"

    "$OUTLINE_BIN" -transport "$transport" -localAddr "127.0.0.1:${OUTLINE_HTTP_PORT}" \
        &> "$OUTLINE_LOG_FILE" &
    local pid=$!
    echo "$pid" > "$OUTLINE_PID_FILE"

    sleep 2

    if kill -0 "$pid" 2>/dev/null; then
        echo "outline-proxy started (PID: $pid)${name:+ — $name}"
        echo "HTTP proxy: 127.0.0.1:${OUTLINE_HTTP_PORT}"
        return 0
    else
        echo "Error: outline-proxy failed to start" >&2
        cat "$OUTLINE_LOG_FILE" >&2
        rm -f "$OUTLINE_PID_FILE"
        return 1
    fi
}

stop_outline() {
    if [ -f "$OUTLINE_PID_FILE" ]; then
        local pid
        pid="$(cat "$OUTLINE_PID_FILE")"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            echo "outline-proxy stopped (PID: $pid)"
        fi
        rm -f "$OUTLINE_PID_FILE"
    else
        echo "outline-proxy is not running"
    fi
}

status_outline() {
    if [ -f "$OUTLINE_PID_FILE" ]; then
        local pid
        pid="$(cat "$OUTLINE_PID_FILE")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "outline-proxy is running (PID: $pid)"
            echo "HTTP proxy: 127.0.0.1:${OUTLINE_HTTP_PORT}"
        else
            echo "outline-proxy is not running (stale PID file)"
        fi
    else
        echo "outline-proxy is not running"
    fi
}

# Прямой запуск как CLI
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "$1" in
        start)
            [ -z "$2" ] && { echo "Usage: $0 start <ss_url>"; exit 1; }
            start_outline "$2"
            ;;
        stop)
            stop_outline
            ;;
        restart)
            [ -z "$2" ] && { echo "Usage: $0 restart <ss_url>"; exit 1; }
            stop_outline
            start_outline "$2"
            ;;
        status)
            status_outline
            ;;
        *)
            echo "Usage: $0 {start|stop|restart|status} [ss_url]"
            exit 1
            ;;
    esac
fi
