#!/bin/bash

# Загрузка, кэширование и разбор VLESS-подписки.
#
# Подписка — это HTTP(S) URL, отдающий список vless:// ссылок,
# обычно в base64. Каждая ссылка — отдельная страна, название
# лежит во фрагменте после #.

_SUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _SUB_DIR="/usr/local/bin"

# Нужен vless_urldecode для названий стран
if ! type vless_urldecode >/dev/null 2>&1; then
    source "$_SUB_DIR/vless_parser.sh"
fi

VPN_CACHE_DIR="${VPN_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/vpn}"
VPN_SERVERS_FILE="$VPN_CACHE_DIR/servers.tsv"
# Как часто перечитывать подписку, секунд (по умолчанию сутки)
VPN_SUB_TTL="${VPN_SUB_TTL:-86400}"

# Алиасы: код страны -> метка хоста в подписке.
# Провайдеры пишут коды как попало (у этого Германия помечена GE),
# поэтому даём привычным кодам дорогу к нужному серверу.
_sub_aliases() {
    cat <<'EOF'
de germany
ge germany
gb britain
uk britain
en britain
us america
usa america
ae emirates
uae emirates
nl netherlands
es spain
ua ukraine
il israel
ru russia
ca canada
fr france
kz kazakhstan
tr turkey
se sweden
jp japan
pl poland
EOF
}

_sub_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Возраст файла в секундах (macOS/Linux)
_sub_file_age() {
    local file="$1" mtime now
    mtime=$(stat -f %m "$file" 2>/dev/null) || mtime=$(stat -c %Y "$file" 2>/dev/null) || return 1
    now=$(date +%s)
    echo $((now - mtime))
}

# Декодирует тело подписки: base64 (в т.ч. url-safe/без паддинга) или plain text
_sub_decode() {
    local raw="$1" compact padded

    # Уже готовый список — отдаём как есть
    if printf '%s' "$raw" | grep -q '^[[:space:]]*vless://'; then
        printf '%s\n' "$raw"
        return 0
    fi

    # Убираем переводы строк и приводим url-safe алфавит к обычному
    compact=$(printf '%s' "$raw" | tr -d '\n\r \t' | tr '_-' '/+')
    # Добавляем паддинг до кратности 4
    padded="$compact"
    while [ $(( ${#padded} % 4 )) -ne 0 ]; do
        padded="${padded}="
    done

    printf '%s' "$padded" | base64 -d 2>/dev/null
}

# Определяет слаг страны по названию и хосту.
# "🇳🇱 Нидерланды (NL)" -> nl;  без кода в скобках -> метка хоста
_sub_slug() {
    local name="$1" host_label="$2"

    if [[ "$name" =~ \(([A-Za-z][A-Za-z])\)[[:space:]]*$ ]]; then
        _sub_lower "${BASH_REMATCH[1]}"
        return 0
    fi

    _sub_lower "$host_label"
}

# Скачивает подписку и перезаписывает кэш серверов.
# При ошибке сети старый кэш остаётся нетронутым.
sub_fetch() {
    local url="$1"
    local tmp_raw tmp_out body line vless_url name host host_label slug
    local count=0

    mkdir -p "$VPN_CACHE_DIR"
    tmp_raw="$VPN_CACHE_DIR/.sub.raw.$$"
    tmp_out="$VPN_CACHE_DIR/.servers.$$"

    if ! curl -fsSL --max-time 30 "$url" -o "$tmp_raw" 2>/dev/null; then
        rm -f "$tmp_raw"
        echo "Error: failed to download subscription from $url" >&2
        return 1
    fi

    body=$(_sub_decode "$(cat "$tmp_raw")")
    rm -f "$tmp_raw"

    if [ -z "$body" ]; then
        echo "Error: subscription is empty or not decodable" >&2
        return 1
    fi

    : > "$tmp_out"
    while IFS= read -r line; do
        # Пропускаем комментарии и всё, что не vless://
        case "$line" in
            vless://*) ;;
            *) continue ;;
        esac

        vless_url="$line"

        # Имя после #
        name=""
        if [[ "$vless_url" == *"#"* ]]; then
            name="${vless_url#*#}"
            name=$(vless_urldecode "$name")
        fi

        # Хост между @ и :порт
        host="${vless_url#vless://}"
        host="${host%%\?*}"
        host="${host%%#*}"
        host="${host#*@}"
        host="${host%:*}"
        host_label=$(_sub_lower "${host%%.*}")

        [ -z "$name" ] && name="$host_label"

        slug=$(_sub_slug "$name" "$host_label")
        [ -z "$slug" ] && continue

        printf '%s\t%s\t%s\t%s\n' "$slug" "$host_label" "$name" "$vless_url" >> "$tmp_out"
        count=$((count + 1))
    done <<< "$body"

    if [ "$count" -eq 0 ]; then
        rm -f "$tmp_out"
        echo "Error: no vless:// entries found in subscription" >&2
        return 1
    fi

    # Провайдер отдаёт серверы в произвольном порядке — сортируем,
    # чтобы список и выбор по умолчанию были стабильными
    sort -t"$(printf '\t')" -k1,1 "$tmp_out" -o "$tmp_out"
    mv "$tmp_out" "$VPN_SERVERS_FILE"
    echo "$count"
    return 0
}

# Обновляет кэш, если он устарел. sub_refresh <url> [force]
# Если сеть недоступна, но кэш есть — работаем на нём.
sub_refresh() {
    local url="$1" force="$2" age

    if [ "$force" != "force" ] && [ -s "$VPN_SERVERS_FILE" ]; then
        age=$(_sub_file_age "$VPN_SERVERS_FILE")
        if [ -n "$age" ] && [ "$age" -lt "$VPN_SUB_TTL" ]; then
            return 0
        fi
    fi

    if sub_fetch "$url" > /dev/null; then
        return 0
    fi

    if [ -s "$VPN_SERVERS_FILE" ]; then
        echo "Warning: subscription update failed, using cached server list" >&2
        return 0
    fi

    return 1
}

# Печатает строки кэша: slug \t host_label \t name \t url
sub_servers() {
    if [ ! -s "$VPN_SERVERS_FILE" ]; then
        echo "Error: no cached servers, run 'vpn update' first" >&2
        return 1
    fi
    cat "$VPN_SERVERS_FILE"
}

# Ищет сервер по запросу. Печатает найденную строку кэша.
# Порядок: точный слаг -> метка хоста -> алиас -> префикс -> подстрока в названии
sub_find() {
    local query
    query=$(_sub_lower "$1")
    local matches alias_target

    [ -s "$VPN_SERVERS_FILE" ] || {
        echo "Error: no cached servers, run 'vpn update' first" >&2
        return 1
    }

    # 1. Точное совпадение слага
    matches=$(awk -F'\t' -v q="$query" '$1 == q' "$VPN_SERVERS_FILE")

    # 2. Точное совпадение метки хоста
    if [ -z "$matches" ]; then
        matches=$(awk -F'\t' -v q="$query" '$2 == q' "$VPN_SERVERS_FILE")
    fi

    # 3. Алиас кода страны -> метка хоста
    if [ -z "$matches" ]; then
        alias_target=$(_sub_aliases | awk -v q="$query" '$1 == q { print $2; exit }')
        if [ -n "$alias_target" ]; then
            matches=$(awk -F'\t' -v q="$alias_target" '$2 == q' "$VPN_SERVERS_FILE")
        fi
    fi

    # 4. Совпадение по префиксу слага или хоста
    if [ -z "$matches" ]; then
        matches=$(awk -F'\t' -v q="$query" 'index($1, q) == 1 || index($2, q) == 1' "$VPN_SERVERS_FILE")
    fi

    # 5. Подстрока в названии (в нижнем регистре: "нидер", "соц")
    if [ -z "$matches" ]; then
        matches=$(awk -F'\t' -v q="$query" 'index(tolower($3), q) > 0' "$VPN_SERVERS_FILE")
    fi

    if [ -z "$matches" ]; then
        echo "Error: no country matches '$1'. Run 'vpn list' to see available ones." >&2
        return 1
    fi

    if [ "$(printf '%s\n' "$matches" | wc -l)" -gt 1 ]; then
        echo "Error: '$1' is ambiguous, matches:" >&2
        printf '%s\n' "$matches" | awk -F'\t' '{ printf "  %-8s %s\n", $1, $3 }' >&2
        return 1
    fi

    printf '%s\n' "$matches"
}
