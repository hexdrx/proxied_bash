#!/bin/bash

echo "======================================"
echo "  VPN Proxy Wrapper - Uninstall"
echo "======================================"
echo ""

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges"
    echo "Please run with sudo: sudo ./uninstall.sh"
    exit 1
fi

# Получаем имя пользователя
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo ~$REAL_USER)

echo "Removing /usr/local/bin/vpn..."
if [ -f "/usr/local/bin/vpn" ]; then
    rm -f /usr/local/bin/vpn
    echo "✓ Removed /usr/local/bin/vpn"
else
    echo "✗ /usr/local/bin/vpn not found"
fi

echo ""
echo "Do you want to remove proxy configuration file $REAL_HOME/.vpn_proxy? (y/N)"
read -r response

if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    if [ -f "$REAL_HOME/.vpn_proxy" ]; then
        rm -f "$REAL_HOME/.vpn_proxy"
        echo "✓ Removed $REAL_HOME/.vpn_proxy"
    else
        echo "✗ $REAL_HOME/.vpn_proxy not found"
    fi
else
    echo "Keeping configuration file"
fi

echo ""
echo "======================================"
echo "  Uninstall Complete!"
echo "======================================"
