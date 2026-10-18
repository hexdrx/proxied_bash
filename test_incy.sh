#!/bin/bash

# Тесты коробки INCY: incy_state.py на фикстурах, обвязка vpn, а по запросу —
# сквозной прогон с настоящим клиентом INCY.
#
#   ./test_incy.sh                     быстрые тесты (без сети и без INCY)
#   INCY_E2E=1 ./test_incy.sh          + сквозной тест: локальные VLESS-серверы
#                                        и подписка, настоящий INCY, vpn curl
#
# Сквозной тест берёт уже установленный клиент из ~/.local/share/vpn/incy/app,
# иначе VPN_INCY_ASSET (скачанный zip/dmg) или скачивает его (~160 МБ).
# Нужны: python3, xray (или тот, что внутри INCY), на Linux — Xvfb.
# Идёт около минуты: проверяет, что INCY не рвёт соединение через 20 с.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Конфиг -----------------------------------------------------------------

E2E="${INCY_E2E:-0}"
E2E_INCY_PORT=18899              # не мешать настоящей коробке на 18808
E2E_HOLD_SECONDS=25              # INCY 3.8.8 гасил xray через 20 с — проверяем, что нет
PYTHON="${VPN_PYTHON:-python3}"

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

check_fails() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$2" -ne 0 ]; then
        pass "$1"
    else
        fail "$1" "expected a non-zero exit code"
    fi
}

TMP_DIR=$(mktemp -d)
E2E_PIDS=""
cleanup() {
    local pid
    for pid in $E2E_PIDS; do kill "$pid" 2>/dev/null; done
    if [ -n "$E2E_STARTED" ]; then
        VPN_PROXY_FILE="$TMP_DIR/e2e/vpn_proxy" VPN_CACHE_DIR="$TMP_DIR/e2e/cache" \
            VPN_INCY_DIR="$TMP_DIR/e2e/incy" bash "$SCRIPT_DIR/vpn" stop all > /dev/null 2>&1
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "======================================"
echo "  INCY box tests"
echo "======================================"

command -v "$PYTHON" > /dev/null 2>&1 || { echo "python3 not found"; exit 1; }

# --- incy_state.py на фикстурах ----------------------------------------------

state() {
    INCY_ACTION="$1" INCY_HOME="$FIX_HOME" INCY_OS="${FIX_OS:-linux}" INCY_PORT=18808 \
        INCY_QUERY="$2" "$PYTHON" -I "$SCRIPT_DIR/incy_state.py"
}

# Минимальная схема базы INCY: только колонки, которые читает incy_state.py
make_fixture() {
    FIX_HOME="$1"
    mkdir -p "$FIX_HOME/.config/incy" "$FIX_HOME/.local/share/incy" "$FIX_HOME/.cache/incy"
    "$PYTHON" -I - "$FIX_HOME/.local/share/incy/incy.db" <<'EOF'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE subscriptions (id TEXT, name TEXT, customName TEXT, url TEXT,
    orderIndex INTEGER, createdAt INTEGER, lastUpdated INTEGER);
CREATE TABLE servers (id TEXT, name TEXT, subscriptionId TEXT,
    orderIndex INTEGER, createdAt INTEGER);
INSERT INTO subscriptions VALUES ('s2', 'second', NULL, 'https://b.invalid', 1, 20, 5);
INSERT INTO subscriptions VALUES ('s1', 'sub', 'My VPN', 'https://a.invalid', 0, 10, 7);
INSERT INTO servers VALUES ('id-nl', '🇳🇱 Netherlands', 's1', 1, 1);
INSERT INTO servers VALUES ('id-de', '🇩🇪 Germany', 's1', 0, 1);
INSERT INTO servers VALUES ('id-de2', '🇩🇪 Germany 2', 's2', 0, 1);
INSERT INTO servers VALUES ('id-jp', '🇯🇵 Japan', 's2', 1, 1);
""")
db.commit()
EOF
    # Пользователь что-то поменял в окне INCY — это должно пережить seed
    echo '{"appTheme":"BLUE","tunnelMode":"TUN","socksPort":10808,"autoConnect":false}' \
        > "$FIX_HOME/.config/incy/preferences.json"
    cat > "$FIX_HOME/.cache/incy/xray_config.json" <<'EOF'
{"inbounds":[
 {"protocol":"dokodemo-door","port":10813,"listen":"127.0.0.1","tag":"api-in"},
 {"protocol":"mixed","port":18808,"listen":"127.0.0.1",
  "settings":{"auth":"password","accounts":[{"user":"incy_ab12","pass":"p@ss:w/rd"}]}}]}
EOF
}

echo ""
echo "incy_state.py:"

make_fixture "$TMP_DIR/home"
PREFS="$FIX_HOME/.config/incy/preferences.json"
pref() { "$PYTHON" -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$PREFS" "$1"; }

state seed
check_eq "seed: режим PROXY_ONLY"           "$(pref tunnelMode)" "PROXY_ONLY"
check_eq "seed: порт коробки"                "$(pref socksPort)" "18808"
check_eq "seed: автоподключение"             "$(pref autoConnect)" "True"
check_eq "seed: пароль на порту"             "$(pref socks5AuthEnabled)" "True"
check_eq "seed: только localhost"            "$(pref allowLanConnections)" "False"
check_eq "seed: чужие настройки сохранены"   "$(pref appTheme)" "BLUE"

check_eq "counts" "$(state counts)" "$(printf '2\t4')"

SERVERS="$(state servers)"
check_eq "порядок: подписка, затем сервер" \
    "$(printf '%s\n' "$SERVERS" | cut -f3 | tr '\n' '|')" "🇩🇪 Germany|🇳🇱 Netherlands|🇩🇪 Germany 2|🇯🇵 Japan|"
check_eq "имя подписки: customName" "$(printf '%s\n' "$SERVERS" | head -1 | cut -f4)" "My VPN"

check_eq "select: без запроса — первый"  "$(state select)" "🇩🇪 Germany"
check_eq "select: по номеру"             "$(state select 4)" "🇯🇵 Japan"
check_eq "select: отмечен в списке"      "$(state servers | awk -F'\t' '$1 == "*" { print $3 }')" "🇯🇵 Japan"
check_eq "select: без запроса — текущий" "$(state select)" "🇯🇵 Japan"
check_eq "select: подстрока без регистра" "$(state select NETH)" "🇳🇱 Netherlands"
check_eq "select: точное имя важнее подстроки" "$(state select '🇩🇪 Germany')" "🇩🇪 Germany"
check_eq "current" "$(state current)" "🇩🇪 Germany"

OUT="$(state select Germ 2>&1)"; RC=$?
check_fails    "select: неоднозначный запрос" "$RC"
check_contains "select: варианты перечислены" "$OUT" "Germany 2"
state select zz > /dev/null 2>&1; check_fails "select: нет совпадений" $?
state select 9 > /dev/null 2>&1;  check_fails "select: номер вне списка" $?

# Обновление подписки пересоздаёт записи: id другой, имя то же
"$PYTHON" -I -c 'import sqlite3, sys
db = sqlite3.connect(sys.argv[1]); db.execute("UPDATE servers SET id = id || \"-new\""); db.commit()' \
    "$FIX_HOME/.local/share/incy/incy.db"
check_eq "select: после обновления — по имени" "$(state select)" "🇩🇪 Germany"

check_eq "last-updated: самое старое" "$(state last-updated)" "5"
state mark-stale
check_eq "mark-stale" "$(state last-updated)" "0"

check_eq "endpoint" "$(state endpoint)" "$(printf '18808\tmixed\tincy_ab12')"
check_eq "proxy-url: пароль экранирован" "$(state proxy-url)" "http://incy_ab12:p%40ss%3Aw%2Frd@127.0.0.1:18808"

# HWID: фиксация и чтение
state_hwid() { INCY_ACTION="$1" INCY_HOME="$FIX_HOME" INCY_OS=linux INCY_HWID="$2" "$PYTHON" -I "$SCRIPT_DIR/incy_state.py"; }
check_eq "hwid: пусто, пока не задан" "$(state_hwid hwid)" ""
state_hwid set-hwid "1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D" > /dev/null
check_eq "hwid: записан в файл" "$(cat "$FIX_HOME/.config/incy/hwid")" "1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D"
check_eq "hwid: прочитан обратно" "$(state_hwid hwid)" "1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D"
INCY_ACTION=seed INCY_HOME="$FIX_HOME" INCY_OS=linux INCY_PORT=18808 INCY_HWID="FEEDFACE-0000-1111-2222-333344445555" "$PYTHON" -I "$SCRIPT_DIR/incy_state.py"
check_eq "hwid: seed фиксирует заданный" "$(state_hwid hwid)" "FEEDFACE-0000-1111-2222-333344445555"
state_hwid set-hwid "nope" > /dev/null 2>&1; check_fails "hwid: мусор отвергнут" $?
state_hwid set-hwid "1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6" > /dev/null 2>&1; check_fails "hwid: неверная длина отвергнута" $?

FIX_HOME="$TMP_DIR/empty" state counts > /dev/null
check_eq "пустая коробка: counts без ошибки" "$(FIX_HOME="$TMP_DIR/empty" state counts)" "$(printf '0\t0')"
FIX_HOME="$TMP_DIR/empty" state proxy-url > /dev/null 2>&1; check_fails "пустая коробка: proxy-url — ошибка" $?

check_eq "macOS: путь настроек" \
    "$(FIX_OS=darwin state paths | head -1 | cut -f2)" "$FIX_HOME/Library/Application Support/incy/preferences.json"

# Пустышка для проверки INCY: слушает и уходит сама после первого подключения
STUB_PORT=$("$PYTHON" -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
INCY_ACTION=probe-stub INCY_STUB_PORT=$STUB_PORT INCY_STUB_LIFETIME=10 "$PYTHON" -I "$SCRIPT_DIR/incy_state.py" &
STUB_PID=$!
sleep 0.5
TESTS_RUN=$((TESTS_RUN + 1))
if (exec 3<>"/dev/tcp/127.0.0.1/$STUB_PORT") 2>/dev/null; then pass "probe-stub: слушает"; else fail "probe-stub: слушает"; fi
sleep 3
TESTS_RUN=$((TESTS_RUN + 1))
if kill -0 "$STUB_PID" 2>/dev/null; then
    fail "probe-stub: уходит после первой проверки"
    kill "$STUB_PID"
else
    pass "probe-stub: уходит после первой проверки"
fi

# --- incy_box.sh и vpn без запуска INCY ----------------------------------------

echo ""
echo "incy_box.sh / vpn:"

VPN_INCY_DIR="$TMP_DIR/bx" VPN_CACHE_DIR="$TMP_DIR/bx-cache" source "$SCRIPT_DIR/incy_box.sh"

check_eq "хэш ссылки стабилен" "$(incy_link_hash 'incy://x')" "$(incy_link_hash 'incy://x')"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -n "$(incy_expected_sha256 "$(incy_asset)")" ]; then
    pass "sha256 закреплён для $(incy_asset)"
else
    fail "sha256 закреплён для $(incy_asset)"
fi
if [ "$(incy_os)" = "linux" ]; then
    incy_bwrap_args ":99"
    check_contains "bwrap: X-сокет экрана" "${INCY_BWRAP[*]}" "/tmp/.X11-unix/X99"
    TESTS_RUN=$((TESTS_RUN + 1))
    case " ${INCY_BWRAP[*]} " in
        *" $HOME "*) fail "bwrap: домашний каталог не пробрасывается" ;;
        *)           pass "bwrap: домашний каталог не пробрасывается" ;;
    esac
fi

VPN_ENV="VPN_PROXY_FILE=$TMP_DIR/vpn_proxy VPN_CACHE_DIR=$TMP_DIR/cache VPN_INCY_DIR=$TMP_DIR/incy"

echo 'happ://crypt3/AAAA' > "$TMP_DIR/vpn_proxy"
OUT="$(env $VPN_ENV bash "$SCRIPT_DIR/vpn" true 2>&1)"; RC=$?
check_fails    "happ:// отвергается" "$RC"
check_contains "happ:// — объяснение" "$OUT" "not supported"

echo 'incy://crypt1/AAAA' > "$TMP_DIR/vpn_proxy"
OUT="$(env $VPN_ENV bash "$SCRIPT_DIR/vpn" -c de true 2>&1)"; RC=$?
check_fails    "incy: -c отвергается до запуска INCY" "$RC"
check_contains "incy: подсказка про vpn use" "$OUT" "vpn use"
TESTS_RUN=$((TESTS_RUN + 1))
[ ! -d "$TMP_DIR/incy" ] && pass "incy: -c ничего не скачивает" || fail "incy: -c ничего не скачивает"

# --- Сквозной тест с настоящим INCY -------------------------------------------

if [ "$E2E" != "1" ]; then
    echo ""
    echo "  – сквозной тест пропущен (INCY_E2E=1 ./test_incy.sh)"
else
    echo ""
    echo "End-to-end (real INCY):"
    E2E_DIR="$TMP_DIR/e2e"
    mkdir -p "$E2E_DIR/incy" "$E2E_DIR/www"
    export VPN_PROXY_FILE="$E2E_DIR/vpn_proxy" VPN_CACHE_DIR="$E2E_DIR/cache"
    export VPN_INCY_DIR="$E2E_DIR/incy" VPN_INCY_PORT=$E2E_INCY_PORT VPN_COUNTRY_FILE="$E2E_DIR/country"
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY

    # Клиент: уже установленный (только чтение) или скачивание/VPN_INCY_ASSET
    REAL_APP="${XDG_DATA_HOME:-$HOME/.local/share}/vpn/incy/app"
    [ -d "$REAL_APP" ] && ln -s "$REAL_APP" "$VPN_INCY_DIR/app"
    E2E_STARTED=1
    ( source "$SCRIPT_DIR/incy_box.sh" && { incy_installed || incy_install; } ) || { echo "cannot install INCY"; exit 1; }

    XRAY_BIN="$(command -v xray || find -L "$VPN_INCY_DIR/app/" -type f -name xray 2>/dev/null | head -1)"
    [ -x "$XRAY_BIN" ] || { echo "xray not found"; exit 1; }

    free_port() { "$PYTHON" -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
    PORT_A=$(free_port); PORT_B=$(free_port); PORT_SUB=$(free_port); PORT_WWW=$(free_port)
    UUID=11111111-2222-3333-4444-555555555555

    for name in a b; do
        port=$PORT_A; [ "$name" = "b" ] && port=$PORT_B
        cat > "$E2E_DIR/server_$name.json" <<EOF
{"log":{"loglevel":"warning","access":"$E2E_DIR/access_$name.log"},
 "inbounds":[{"listen":"127.0.0.1","port":$port,"protocol":"vless",
   "settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
   "streamSettings":{"network":"tcp","security":"none"}}],
 "outbounds":[{"protocol":"freedom","settings":{"finalRules":[{"action":"allow"}]}}]}
EOF
        : > "$E2E_DIR/access_$name.log"
        "$XRAY_BIN" run -c "$E2E_DIR/server_$name.json" > "$E2E_DIR/server_$name.out" 2>&1 &
        E2E_PIDS="$E2E_PIDS $!"
    done

    printf '%s\n' \
        "vless://$UUID@127.0.0.1:$PORT_A?type=tcp&security=none&encryption=none#Alpha" \
        "vless://$UUID@127.0.0.1:$PORT_B?type=tcp&security=none&encryption=none#Bravo" \
        > "$E2E_DIR/links.txt"
    cat > "$E2E_DIR/subsrv.py" <<EOF
import base64, http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open("$E2E_DIR/sub_headers.log", "a") as f:
            f.write(json.dumps(dict(self.headers)) + "\n")
        body = base64.b64encode(open("$E2E_DIR/links.txt", "rb").read())
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", $PORT_SUB), H).serve_forever()
EOF
    "$PYTHON" -I "$E2E_DIR/subsrv.py" &
    E2E_PIDS="$E2E_PIDS $!"
    echo "hello-through-incy" > "$E2E_DIR/www/index.txt"
    (cd "$E2E_DIR/www" && exec "$PYTHON" -m http.server "$PORT_WWW" --bind 127.0.0.1) > /dev/null 2>&1 &
    E2E_PIDS="$E2E_PIDS $!"
    sleep 1

    # Тестовая подписка — простым add-линком; crypt1 INCY разбирает так же
    echo "incy://add/http://127.0.0.1:$PORT_SUB/sub" > "$VPN_PROXY_FILE"
    URL="http://127.0.0.1:$PORT_WWW/index.txt"
    VPN="bash $SCRIPT_DIR/vpn"

    check_eq "vpn curl через INCY" "$($VPN curl -sS -m 15 "$URL" 2>/dev/null)" "hello-through-incy"
    check_contains "трафик ушёл на сервер Alpha" "$(cat "$E2E_DIR/access_a.log")" "accepted"
    check_contains "подписку забрал INCY (x-client)" "$(cat "$E2E_DIR/sub_headers.log")" '"x-client": "INCY"'
    check_contains "INCY прислал HWID"               "$(cat "$E2E_DIR/sub_headers.log")" '"x-hwid"'
    check_contains "в окружении команды — порт INCY" "$($VPN env 2>/dev/null)" "127.0.0.1:$E2E_INCY_PORT"

    check_eq "vpn list: два сервера" "$($VPN list 2>/dev/null | grep -c .)" "2"
    $VPN use bravo > /dev/null 2>&1
    $VPN curl -sS -m 15 "$URL" > /dev/null 2>&1
    check_contains "vpn use: трафик на Bravo" "$(cat "$E2E_DIR/access_b.log")" "accepted"

    echo "  … держим соединение ${E2E_HOLD_SECONDS}s"
    sleep "$E2E_HOLD_SECONDS"
    check_eq "соединение живо после ${E2E_HOLD_SECONDS}s" "$($VPN curl -sS -m 15 "$URL" 2>/dev/null)" "hello-through-incy"

    check_contains "vpn status" "$($VPN status 2>/dev/null)" "running"
    check_contains "заглушки перехватили системные вызовы INCY" "$(cat "$VPN_CACHE_DIR/incy-box/shim.log" 2>/dev/null)" "xdg-mime"
    $VPN stop all > /dev/null 2>&1
    TESTS_RUN=$((TESTS_RUN + 1))
    if (source "$SCRIPT_DIR/incy_box.sh" && incy_running); then
        fail "vpn stop all гасит INCY"
    else
        pass "vpn stop all гасит INCY"
    fi
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
