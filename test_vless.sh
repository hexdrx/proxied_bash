#!/bin/bash

# Тесты парсера VLESS, генератора конфига xray и разбора подписки.
#
#   ./test_vless.sh              запустить все тесты
#   ./test_vless.sh <vless_url>  разобрать одну ссылку и показать результат

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Разовый разбор ссылки — как раньше
if [ -n "$1" ]; then
    source "$SCRIPT_DIR/vless_parser.sh"
    parse_vless_url "$1"
    exit $?
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() { echo "  ✓ $1"; }
fail() {
    echo "  ✗ $1"
    [ -n "$2" ] && echo "      $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

check_eq() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "expected '$3', got '$2'"
    fi
}

check_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$2" | grep -q -- "$3"; then
        pass "$1"
    else
        fail "$1" "output does not contain '$3'"
    fi
}

check_not_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$2" | grep -q -- "$3"; then
        fail "$1" "output unexpectedly contains '$3'"
    else
        pass "$1"
    fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "======================================"
echo "  VLESS / subscription tests"
echo "======================================"

# --- Парсер --------------------------------------------------------------

echo ""
echo "Parser:"

source "$SCRIPT_DIR/vless_parser.sh"

XHTTP_URL='vless://12345678-1234-1234-1234-123456789abc@germany.example.top:3478?security=reality&allowInsecure=0&encryption=none&type=xhttp&path=/&sni=germany.example.top&fp=qq&pbk=KlwRflaYhBtz2jm2FlDWfVe0R04t5LVARoJXhi0BLBo&mode=packet-up#🇩🇪 Германия (GE)'

parse_vless_vars "$XHTTP_URL"
check_eq "uuid"          "$VLESS_UUID"     "12345678-1234-1234-1234-123456789abc"
check_eq "host"          "$VLESS_HOST"     "germany.example.top"
check_eq "port"          "$VLESS_PORT"     "3478"
check_eq "type=xhttp"    "$VLESS_TYPE"     "xhttp"
check_eq "mode"          "$VLESS_MODE"     "packet-up"
check_eq "security"      "$VLESS_SECURITY" "reality"
check_eq "name с эмодзи" "$VLESS_NAME"     "🇩🇪 Германия (GE)"

# Процентное кодирование в имени
parse_vless_vars 'vless://uuid@h.example.com:443?type=tcp#%F0%9F%87%AF%F0%9F%87%B5%20Japan'
check_eq "percent-encoded name" "$VLESS_NAME" "🇯🇵 Japan"

# SNI по умолчанию — сам хост
parse_vless_vars 'vless://uuid@h.example.com:443?security=tls&type=tcp'
check_eq "sni по умолчанию" "$VLESS_SNI" "h.example.com"

# --- Генератор конфига ---------------------------------------------------

echo ""
echo "Xray config generation:"

source "$SCRIPT_DIR/vless_to_xray.sh"

CFG="$TMP_DIR/xhttp.json"
generate_xray_config "$XHTTP_URL" "$CFG" 10800 10801 > /dev/null
CFG_BODY=$(cat "$CFG")

check_contains "xhttp -> xhttpSettings"   "$CFG_BODY" '"xhttpSettings"'
check_contains "xhttp mode пробрасывается" "$CFG_BODY" '"mode": "packet-up"'
check_contains "reality -> realitySettings" "$CFG_BODY" '"realitySettings"'
check_contains "порт socks"                "$CFG_BODY" '"port": 10800'
check_contains "порт http"                 "$CFG_BODY" '"port": 10801'
check_contains "слушаем только localhost"  "$CFG_BODY" '"listen": "127.0.0.1"'

TLS_URL='vless://uuid@h.example.com:443?security=tls&type=ws&path=/ws&sni=h.example.com&alpn=h2,http/1.1&fp=chrome'
CFG_TLS="$TMP_DIR/tls.json"
generate_xray_config "$TLS_URL" "$CFG_TLS" 10802 10803 > /dev/null
CFG_TLS_BODY=$(cat "$CFG_TLS")

check_contains     "tls -> tlsSettings"        "$CFG_TLS_BODY" '"tlsSettings"'
check_not_contains "tls без realitySettings"   "$CFG_TLS_BODY" '"realitySettings"'
check_contains     "ws -> wsSettings"          "$CFG_TLS_BODY" '"wsSettings"'
check_contains     "alpn массивом"             "$CFG_TLS_BODY" '"alpn": \["h2","http/1.1"\]'

# Конфиги должны быть валидны для самого xray
if command -v xray > /dev/null 2>&1; then
    for cfg in "$CFG" "$CFG_TLS"; do
        TESTS_RUN=$((TESTS_RUN + 1))
        if out=$(xray -test -c "$cfg" 2>&1); then
            pass "xray -test принимает $(basename "$cfg")"
        else
            fail "xray -test принимает $(basename "$cfg")" "$out"
        fi
    done
else
    echo "  – xray не установлен, проверка конфигов пропущена"
fi

# --- Подписка ------------------------------------------------------------

echo ""
echo "Subscription:"

VPN_CACHE_DIR="$TMP_DIR/cache"
source "$SCRIPT_DIR/subscription.sh"

# Фикстура: список ссылок в base64, как отдаёт настоящая подписка
cat > "$TMP_DIR/plain.txt" <<'EOF'
# Test VPN
vless://uuid@germany.example.top:3478?security=reality&type=xhttp&mode=packet-up&pbk=KEY#🇩🇪 Германия (GE)
vless://uuid@netherlands.example.top:3478?security=reality&type=xhttp&mode=packet-up&pbk=KEY#🇳🇱 Нидерланды (NL)
vless://uuid@britain.example.top:3478?security=reality&type=xhttp&mode=packet-up&pbk=KEY#🇬🇧 Британия (GB)
vless://uuid@avito.example.top:3478?security=reality&type=xhttp&mode=packet-up&pbk=KEY#🤳 Для соц-сетей
EOF
base64 < "$TMP_DIR/plain.txt" | tr -d '\n' > "$TMP_DIR/sub.b64"

COUNT=$(sub_fetch "file://$TMP_DIR/sub.b64")
check_eq "base64-подписка разобрана" "$COUNT" "4"

check_eq "слаг из кода в скобках" "$(sub_find ge | cut -f1)" "ge"
check_eq "алиас de -> germany"    "$(sub_find de | cut -f1)" "ge"
check_eq "алиас uk -> britain"    "$(sub_find uk | cut -f1)" "gb"
check_eq "поиск по хосту"         "$(sub_find netherlands | cut -f1)" "nl"
check_eq "поиск по префиксу"      "$(sub_find neth | cut -f1)" "nl"
check_eq "подстрока в названии"   "$(sub_find соц | cut -f1)" "avito"
check_eq "без кода -> слаг из хоста" "$(sub_find avito | cut -f1)" "avito"

TESTS_RUN=$((TESTS_RUN + 1))
if sub_find zz > /dev/null 2>&1; then
    fail "несуществующая страна отвергается"
else
    pass "несуществующая страна отвергается"
fi

check_eq "кэш отсортирован по слагу" "$(cut -f1 "$VPN_SERVERS_FILE" | tr '\n' ' ')" "avito gb ge nl "

# Подписка без base64 (некоторые провайдеры отдают plain text)
rm -f "$VPN_SERVERS_FILE"
COUNT_PLAIN=$(sub_fetch "file://$TMP_DIR/plain.txt")
check_eq "plain-text подписка разобрана" "$COUNT_PLAIN" "4"

echo ""
echo "v2ray-JSON subscription:"

# Часть панелей (Remnawave) отдаёт не список ссылок, а массив целых
# Xray-конфигов. Значения выдуманы; важна структура: grpc+reality, ws+tls
# и одна запись на протоколе, который клиент не тянет.
cat > "$TMP_DIR/sub.json" <<'JSON'
[
 {"remarks":"🇩🇪 Германия","inbounds":[{"protocol":"socks"}],"outbounds":[
   {"tag":"proxy","protocol":"vless",
    "settings":{"vnext":[{"address":"germany.example.top","port":443,
      "users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none","flow":""}]}]},
    "streamSettings":{"network":"grpc",
      "grpcSettings":{"serviceName":"abcdef0123456789","authority":"","mode":false},
      "security":"reality",
      "realitySettings":{"serverName":"germany.example.top","fingerprint":"chrome",
        "publicKey":"e4Vx7ENhom990GOG_B1aEUNfF4d09JEnWWc8ggszBdA","shortId":"0123abcd"},
      "sockopt":{"tcpMaxSeg":1000}}},
   {"tag":"direct","protocol":"freedom"}]},
 {"remarks":"📶 Белые списки","outbounds":[
   {"tag":"proxy","protocol":"vless",
    "settings":{"vnext":[{"address":"cdn.example.top","port":8443,
      "users":[{"id":"66666666-7777-8888-9999-000000000000","encryption":"none","flow":""}]}]},
    "streamSettings":{"network":"ws",
      "wsSettings":{"path":"/api/v1/assets","host":"cdn-edge.example.top","headers":{}},
      "security":"tls",
      "tlsSettings":{"serverName":"cdn.example.top","fingerprint":"chrome","alpn":["http/1.1"]}}}]},
 {"remarks":"🎮 Игровой EU","outbounds":[
   {"tag":"proxy","protocol":"hysteria"},{"tag":"direct","protocol":"freedom"}]}
]
JSON

rm -f "$VPN_SERVERS_FILE"
COUNT_JSON=$(sub_fetch "file://$TMP_DIR/sub.json")
# Запись на hysteria отброшена, а не выдана ссылкой, падающей позже
check_eq "v2ray-json: разобрана, hysteria пропущена" "$COUNT_JSON" "2"

JSON_DE=$(sub_find germany | cut -f4)
check_contains "v2ray-json: grpc"      "$JSON_DE" "type=grpc"
check_contains "v2ray-json: reality"   "$JSON_DE" "security=reality"
check_contains "v2ray-json: pbk"       "$JSON_DE" "pbk=e4Vx7ENhom990GOG_B1aEUNfF4d09JEnWWc8ggszBdA"
check_contains "v2ray-json: sid"       "$JSON_DE" "sid=0123abcd"
check_contains "v2ray-json: sni"       "$JSON_DE" "sni=germany.example.top"
check_contains "v2ray-json: serviceName" "$JSON_DE" "serviceName=abcdef0123456789"
# flow в JSON пустая строка — она не должна превратиться в "&flow="
check_not_contains "v2ray-json: пустой flow отброшен" "$JSON_DE" "flow="
check_eq "v2ray-json: имя из remarks" "$(sub_find germany | cut -f3)" "🇩🇪 Германия"

JSON_WS=$(sub_find cdn | cut -f4)
check_contains "v2ray-json: ws"        "$JSON_WS" "type=ws"
check_contains "v2ray-json: порт"      "$JSON_WS" ":8443"
check_contains "v2ray-json: path"      "$JSON_WS" "path=%2Fapi%2Fv1%2Fassets"
check_contains "v2ray-json: host-заголовок" "$JSON_WS" "host=cdn-edge.example.top"
check_contains "v2ray-json: alpn"      "$JSON_WS" "alpn=http%2F1.1"

# Ссылки должны доживать до рабочего конфига xray, а не только до парсера
if command -v xray > /dev/null 2>&1; then
    for pair in "json_de:$JSON_DE" "json_ws:$JSON_WS"; do
        generate_xray_config "${pair#*:}" "$TMP_DIR/${pair%%:*}.json" 10804 10805 > /dev/null
        TESTS_RUN=$((TESTS_RUN + 1))
        if out=$(xray -test -c "$TMP_DIR/${pair%%:*}.json" 2>&1); then
            pass "v2ray-json: xray -test принимает ${pair%%:*}"
        else
            fail "v2ray-json: xray -test принимает ${pair%%:*}" "$out"
        fi
    done
else
    echo "  – xray не установлен, проверка конфигов пропущена"
fi

# --- Итог ----------------------------------------------------------------

echo ""
echo "======================================"
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "  All $TESTS_RUN tests passed"
    echo "======================================"
    exit 0
else
    echo "  $TESTS_FAILED of $TESTS_RUN tests FAILED"
    echo "======================================"
    exit 1
fi
