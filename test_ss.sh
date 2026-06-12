#!/bin/bash

# Тесты парсера ss:// (ss_parser.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ss_parser.sh"

PASS=0
FAIL=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name"
        echo "      expected: $expected"
        echo "      actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

echo "======================================"
echo "  ss:// Parser Tests"
echo "======================================"

URL='ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpQQVNTV09SRA@example.com:993/?outline=1&prefix=%17%03%03%3F#🇳🇱 Нидерланды (NL)'

# outline=1 убран, prefix сохранён, fragment отрезан
check "drops outline=1, keeps prefix" \
    'ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpQQVNTV09SRA@example.com:993/?prefix=%17%03%03%3F' \
    "$(clean_ss_url "$URL")"

# имя извлекается
check "extracts name" \
    '🇳🇱 Нидерланды (NL)' \
    "$(ss_url_name "$URL")"

# URL без query остаётся как есть (только fragment отрезан)
check "no-query url passthrough" \
    'ss://dXNlcg@host:443' \
    "$(clean_ss_url 'ss://dXNlcg@host:443#name')"

# несколько параметров: outline убирается, остальные сохраняются по порядку
check "keeps other params" \
    'ss://abc@h:1/?prefix=%17&foo=bar' \
    "$(clean_ss_url 'ss://abc@h:1/?prefix=%17&outline=1&foo=bar')"

# не-ss URL отвергается
if clean_ss_url 'vless://x@h:1' >/dev/null 2>&1; then
    check "rejects non-ss url" "rejected" "accepted"
else
    check "rejects non-ss url" "rejected" "rejected"
fi

echo "======================================"
echo "  PASS: $PASS   FAIL: $FAIL"
echo "======================================"
[ "$FAIL" -eq 0 ]
