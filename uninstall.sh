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

VPN_CACHE_DIR="${XDG_CACHE_HOME:-$REAL_HOME/.cache}/vpn"

echo "Stopping xray if running..."
if [ -f "/tmp/xray_vpn.pid" ]; then
    pid=$(cat /tmp/xray_vpn.pid)
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        echo "✓ Stopped xray (PID: $pid)"
    fi
    rm -f /tmp/xray_vpn.pid
fi

# Инстансы, поднятые под каждую страну подписки
for pid_file in "$VPN_CACHE_DIR"/*/xray.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        echo "✓ Stopped xray for $(basename "$(dirname "$pid_file")") (PID: $pid)"
    fi
    rm -f "$pid_file"
done

echo "Stopping outline-proxy if running..."
if [ -f "/tmp/outline_vpn.pid" ]; then
    pid=$(cat /tmp/outline_vpn.pid)
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        echo "✓ Stopped outline-proxy (PID: $pid)"
    fi
    rm -f /tmp/outline_vpn.pid
fi
rm -f /tmp/outline_vpn.log

# Коробка INCY: останавливаем от имени пользователя, чьи это процессы
INCY_BOX="/usr/local/bin/incy_box.sh"
INCY_DIR="${XDG_DATA_HOME:-$REAL_HOME/.local/share}/vpn/incy"
if [ -f "$INCY_BOX" ]; then
    echo "Stopping INCY box if running..."
    sudo -H -u "$REAL_USER" bash -c "source '$INCY_BOX' && incy_stop" 2>/dev/null
fi

echo ""
echo "Removing vpn scripts from /usr/local/bin..."
if [ -f "/usr/local/bin/vpn" ]; then
    rm -f /usr/local/bin/vpn
    echo "✓ Removed /usr/local/bin/vpn"
else
    echo "✗ /usr/local/bin/vpn not found"
fi

if [ -f "/usr/local/bin/vless_parser.sh" ]; then
    rm -f /usr/local/bin/vless_parser.sh
    echo "✓ Removed /usr/local/bin/vless_parser.sh"
fi

if [ -f "/usr/local/bin/vless_to_xray.sh" ]; then
    rm -f /usr/local/bin/vless_to_xray.sh
    echo "✓ Removed /usr/local/bin/vless_to_xray.sh"
fi

if [ -f "/usr/local/bin/subscription.sh" ]; then
    rm -f /usr/local/bin/subscription.sh
    echo "✓ Removed /usr/local/bin/subscription.sh"
fi

if [ -f "/usr/local/bin/v2ray_json.py" ]; then
    rm -f /usr/local/bin/v2ray_json.py
    echo "✓ Removed /usr/local/bin/v2ray_json.py"
fi

for f in incy_box.sh incy_state.py incy_link.py; do
    if [ -f "/usr/local/bin/$f" ]; then
        rm -f "/usr/local/bin/$f"
        echo "✓ Removed /usr/local/bin/$f"
    fi
done

if [ -f "/usr/local/bin/ss_parser.sh" ]; then
    rm -f /usr/local/bin/ss_parser.sh
    echo "✓ Removed /usr/local/bin/ss_parser.sh"
fi

if [ -f "/usr/local/bin/ss_to_outline.sh" ]; then
    rm -f /usr/local/bin/ss_to_outline.sh
    echo "✓ Removed /usr/local/bin/ss_to_outline.sh"
fi

if [ -f "/usr/local/bin/outline-proxy" ]; then
    rm -f /usr/local/bin/outline-proxy
    echo "✓ Removed /usr/local/bin/outline-proxy"
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
echo "Do you want to remove xray configuration from $REAL_HOME/.config/xray? (y/N)"
read -r response2

if [[ "$response2" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    if [ -d "$REAL_HOME/.config/xray" ]; then
        rm -rf "$REAL_HOME/.config/xray"
        echo "✓ Removed $REAL_HOME/.config/xray"
    else
        echo "✗ $REAL_HOME/.config/xray not found"
    fi
else
    echo "Keeping xray configuration"
fi

echo ""
echo "Do you want to remove the subscription cache $VPN_CACHE_DIR and selected country? (y/N)"
read -r response3

if [[ "$response3" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    rm -rf "$VPN_CACHE_DIR"
    rm -f "$REAL_HOME/.vpn_country"
    echo "✓ Removed subscription cache and selected country"
else
    echo "Keeping subscription cache"
fi

if [ -d "$INCY_DIR" ]; then
    echo ""
    echo "Do you want to remove the INCY client and its data $INCY_DIR? (y/N)"
    read -r response4

    if [[ "$response4" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        rm -rf "$INCY_DIR"
        echo "✓ Removed INCY box"
    else
        echo "Keeping INCY box"
    fi
fi

echo ""
echo "======================================"
echo "  Uninstall Complete!"
echo "======================================"
