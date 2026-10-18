#!/bin/bash

set -e

echo "======================================"
echo "  VPN Proxy Wrapper - Installation"
echo "======================================"
echo ""

# Проверка прав root для установки в /usr/local/bin
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges to install to /usr/local/bin"
    echo "Please run with sudo: sudo ./install.sh"
    exit 1
fi

# Определяем директорию скрипта
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "Step 1: Installing vpn scripts to /usr/local/bin..."
cp "$SCRIPT_DIR/vpn" /usr/local/bin/vpn
chmod +x /usr/local/bin/vpn
echo "✓ Main script installed"

# Устанавливаем VLESS support скрипты
if [ -f "$SCRIPT_DIR/vless_parser.sh" ]; then
    cp "$SCRIPT_DIR/vless_parser.sh" /usr/local/bin/vless_parser.sh
    chmod +x /usr/local/bin/vless_parser.sh
    echo "✓ VLESS parser installed"
fi

if [ -f "$SCRIPT_DIR/vless_to_xray.sh" ]; then
    cp "$SCRIPT_DIR/vless_to_xray.sh" /usr/local/bin/vless_to_xray.sh
    chmod +x /usr/local/bin/vless_to_xray.sh
    echo "✓ VLESS to xray converter installed"
fi

if [ -f "$SCRIPT_DIR/subscription.sh" ]; then
    cp "$SCRIPT_DIR/subscription.sh" /usr/local/bin/subscription.sh
    chmod +x /usr/local/bin/subscription.sh
    echo "✓ Subscription support installed"
fi

# Хелпер на python3 (только stdlib): подписки в формате v2ray-JSON
if [ -f "$SCRIPT_DIR/v2ray_json.py" ]; then
    cp "$SCRIPT_DIR/v2ray_json.py" /usr/local/bin/v2ray_json.py
    chmod +x /usr/local/bin/v2ray_json.py
    echo "✓ v2ray-JSON subscription helper installed"
fi

# Коробка с официальным клиентом INCY для incy:// ссылок.
# Сам клиент (~160 МБ) скачивается при первом запуске, в домашний каталог.
if [ -f "$SCRIPT_DIR/incy_box.sh" ] && [ -f "$SCRIPT_DIR/incy_state.py" ]; then
    cp "$SCRIPT_DIR/incy_box.sh" /usr/local/bin/incy_box.sh
    cp "$SCRIPT_DIR/incy_state.py" /usr/local/bin/incy_state.py
    chmod +x /usr/local/bin/incy_box.sh /usr/local/bin/incy_state.py
    echo "✓ INCY box installed (client is downloaded on first use)"
fi

# Старый расшифровщик incy:// убран: провайдеры банят за такие подписки
if [ -f /usr/local/bin/incy_link.py ]; then
    rm -f /usr/local/bin/incy_link.py
    echo "✓ Removed obsolete incy_link.py"
fi

# Устанавливаем Outline/Shadowsocks support скрипты
if [ -f "$SCRIPT_DIR/ss_parser.sh" ]; then
    cp "$SCRIPT_DIR/ss_parser.sh" /usr/local/bin/ss_parser.sh
    chmod +x /usr/local/bin/ss_parser.sh
    echo "✓ Outline (ss) parser installed"
fi

if [ -f "$SCRIPT_DIR/ss_to_outline.sh" ]; then
    cp "$SCRIPT_DIR/ss_to_outline.sh" /usr/local/bin/ss_to_outline.sh
    chmod +x /usr/local/bin/ss_to_outline.sh
    echo "✓ Outline manager installed"
fi

# Устанавливаем outline-proxy хелпер (поддержка Outline-префикса).
# Приоритет: готовый пребилт под платформу (Go не нужен) -> локальная сборка ->
# сборка из исходников через go (фолбэк для платформ без пребилта).
if [ -d "$SCRIPT_DIR/outline-proxy" ]; then
    # Определяем платформу
    OS_NAME="$(uname -s | tr '[:upper:]' '[:lower:]')"
    ARCH_NAME="$(uname -m)"
    case "$ARCH_NAME" in
        x86_64|amd64)  ARCH_NAME="amd64" ;;
        arm64|aarch64) ARCH_NAME="arm64" ;;
    esac
    PREBUILT="$SCRIPT_DIR/outline-proxy/bin/outline-proxy-${OS_NAME}-${ARCH_NAME}"

    OUTLINE_INSTALLED=""
    if [ -x "$PREBUILT" ]; then
        cp "$PREBUILT" /usr/local/bin/outline-proxy
        chmod +x /usr/local/bin/outline-proxy
        echo "✓ outline-proxy helper installed (prebuilt ${OS_NAME}-${ARCH_NAME})"
        OUTLINE_INSTALLED="yes"
    elif [ -x "$SCRIPT_DIR/outline-proxy/outline-proxy" ]; then
        cp "$SCRIPT_DIR/outline-proxy/outline-proxy" /usr/local/bin/outline-proxy
        chmod +x /usr/local/bin/outline-proxy
        echo "✓ outline-proxy helper installed (local build)"
        OUTLINE_INSTALLED="yes"
    elif command -v go &> /dev/null; then
        echo "No prebuilt for ${OS_NAME}-${ARCH_NAME}; building outline-proxy from source..."
        BUILD_USER="${SUDO_USER:-$USER}"
        if sudo -u "$BUILD_USER" bash -c "cd '$SCRIPT_DIR/outline-proxy' && GOTOOLCHAIN=auto go build -o outline-proxy ." \
           || ( cd "$SCRIPT_DIR/outline-proxy" && GOTOOLCHAIN=auto go build -o outline-proxy . ); then
            cp "$SCRIPT_DIR/outline-proxy/outline-proxy" /usr/local/bin/outline-proxy
            chmod +x /usr/local/bin/outline-proxy
            echo "✓ outline-proxy helper built and installed"
            OUTLINE_INSTALLED="yes"
        fi
    fi

    if [ -z "$OUTLINE_INSTALLED" ]; then
        echo "⚠️  outline-proxy not installed (no prebuilt for ${OS_NAME}-${ARCH_NAME} and no Go)."
        echo "   Install Go (https://go.dev/dl/) and re-run, or build manually:"
        echo "     (cd \"$SCRIPT_DIR/outline-proxy\" && go build -o outline-proxy .)"
    fi
fi

echo ""
echo "Step 2: Setting up proxy configuration..."

# Получаем имя пользователя который запустил sudo
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo ~$REAL_USER)

# Если файл vpn_proxy.example существует и ~/.vpn_proxy не существует
if [ -f "$SCRIPT_DIR/vpn_proxy.example" ] && [ ! -f "$REAL_HOME/.vpn_proxy" ]; then
    echo "Creating ~/.vpn_proxy from example..."
    cp "$SCRIPT_DIR/vpn_proxy.example" "$REAL_HOME/.vpn_proxy"
    chown $REAL_USER:$REAL_USER "$REAL_HOME/.vpn_proxy"
    chmod 600 "$REAL_HOME/.vpn_proxy"
    echo "✓ Config file created: $REAL_HOME/.vpn_proxy"
    echo ""
    echo "⚠️  IMPORTANT: Edit ~/.vpn_proxy with your proxy details!"
    echo "   Supported formats:"
    echo "     Subscription: https://example.com/sub/vless/UUID"
    echo "     INCY: incy://crypt1/PAYLOAD"
    echo "     VLESS: vless://UUID@HOST:PORT?params#name"
    echo "     Outline/Shadowsocks: ss://BASE64@HOST:PORT?params#name"
    echo "     HTTP Proxy: IP:PORT:USER:PASS"
else
    if [ -f "$REAL_HOME/.vpn_proxy" ]; then
        echo "✓ Config file already exists: $REAL_HOME/.vpn_proxy"
    else
        echo "Creating empty ~/.vpn_proxy..."
        touch "$REAL_HOME/.vpn_proxy"
        chown $REAL_USER:$REAL_USER "$REAL_HOME/.vpn_proxy"
        chmod 600 "$REAL_HOME/.vpn_proxy"
        echo "IP:PORT:USER:PASS" > "$REAL_HOME/.vpn_proxy"
        echo "✓ Config file created: $REAL_HOME/.vpn_proxy"
        echo ""
        echo "⚠️  IMPORTANT: Edit ~/.vpn_proxy with your proxy details!"
    fi
fi

echo ""
echo "======================================"
echo "  Installation Complete!"
echo "======================================"
echo ""
echo "Usage:"
echo "  1. Edit your proxy settings:"
echo "     nano ~/.vpn_proxy"
echo ""
echo "     Supported formats:"
echo "       Subscription: https://example.com/sub/vless/UUID"
echo "       INCY: incy://crypt1/PAYLOAD"
echo "       VLESS: vless://UUID@HOST:PORT?params#name"
echo "       Outline/Shadowsocks: ss://BASE64@HOST:PORT?params#name"
echo "       HTTP: IP:PORT:USER:PASS"
echo ""
echo "  2. Use vpn command to run apps through proxy:"
echo "     vpn curl ifconfig.me"
echo "     vpn wget https://example.com"
echo "     vpn apt update"
echo ""
echo "  3. With a subscription you can pick a country:"
echo "     vpn list                     # available countries"
echo "     vpn use de                   # set the default one"
echo "     vpn -c jp curl ifconfig.me   # one-off override"
echo ""
echo "  4. For VLESS: Install xray-core if not already installed"
echo "     https://github.com/XTLS/Xray-core"
echo ""
echo "  5. For Outline (ss://): the outline-proxy helper is installed from a"
echo "     prebuilt binary, or built from source if Go is available"
echo ""
echo "  6. For INCY (incy://): the official client runs isolated in the background."
echo "     Linux needs: sudo apt install xvfb bubblewrap unzip   (x11vnc for 'vpn incy ui')"
echo "     macOS needs nothing extra. Then: vpn incy setup"
echo ""
echo "To uninstall:"
echo "  sudo ./uninstall.sh"
echo ""
