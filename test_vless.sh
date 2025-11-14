#!/bin/bash

# Тестовый скрипт для проверки парсинга VLESS URL

echo "======================================"
echo "  VLESS Parser Test"
echo "======================================"
echo ""

# Пример VLESS URL
VLESS_URL='vless://12345678-1234-1234-1234-123456789abc@example.com:443?flow=xtls-rprx-vision&security=reality&type=tcp&alpn=h2,http/1.1&sni=example.com&fp=chrome&pbk=YOUR_PUBLIC_KEY_HERE#example'

if [ -n "$1" ]; then
    VLESS_URL="$1"
fi

echo "Testing VLESS URL:"
echo "$VLESS_URL"
echo ""
echo "Parsed result:"
echo "======================================"

# Парсим VLESS URL
source ./vless_parser.sh
parse_vless_url "$VLESS_URL"

echo ""
echo "======================================"
echo ""
echo "To test with your own VLESS URL:"
echo "  ./test_vless.sh 'your_vless_url_here'"
echo ""
