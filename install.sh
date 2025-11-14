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

echo "Step 1: Installing vpn script to /usr/local/bin..."
cp "$SCRIPT_DIR/vpn" /usr/local/bin/vpn
chmod +x /usr/local/bin/vpn
echo "✓ Script installed"

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
    echo "   Format: IP:PORT:USER:PASS"
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
echo "  2. Use vpn command to run apps through proxy:"
echo "     vpn curl ifconfig.me"
echo "     vpn wget https://example.com"
echo "     vpn apt update"
echo ""
echo "To uninstall:"
echo "  sudo rm /usr/local/bin/vpn"
echo "  rm ~/.vpn_proxy"
echo ""
