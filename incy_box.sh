#!/bin/bash

# Официальный клиент INCY в изолированной «коробке» как локальный прокси для vpn.
#
# Зачем: провайдеры банят, когда подписку забирает не их клиент. INCY ходит
# за подпиской со своими заголовками (x-client, x-hwid, ...), поэтому vpn
# больше ничего не расшифровывает, а поднимает настоящий INCY в режиме
# PROXY_ONLY и пускает команды через его локальный порт.
#
# Изоляция:
#   * INCY видит подменённый домашний каталог (-Duser.home): его настройки,
#     база и логи живут в $INCY_DIR/home и не смешиваются с обычным INCY;
#   * networksetup / gsettings / xdg-mime / ... подменены заглушками —
#     INCY при выходе выключает системный прокси и регистрирует incy://
#     обработчиком, коробке этого делать нельзя;
#   * Linux: окно рисуется в Xvfb, сам INCY запускается в bubblewrap
#     (ФС только для чтения, домашний каталог пользователя не виден);
#   * macOS: обычный запуск свёрнутым, без иконки в доке.
# HWID по умолчанию считается из machine-id/hostname/пользователя — провайдер
# видит то же устройство, что и обычный INCY на этой машине. Если нужно, чтобы
# несколько своих установок (например VM на маке и сам мак) считались одним
# устройством, HWID можно закрепить: VPN_INCY_HWID=<UUID> или `vpn incy hwid <UUID>`.
#
# Используется из vpn через source; можно вызывать и напрямую (см. конец).
# Совместимо с bash 3.2 (системный bash на macOS).

INCY_BOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Конфиг -----------------------------------------------------------------

INCY_VERSION="${VPN_INCY_VERSION:-3.8.8}"
INCY_RELEASES="https://github.com/INCY-DEV/incy-platforms/releases/download"
INCY_DIR="${VPN_INCY_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/vpn/incy}"
INCY_RUN_DIR="${VPN_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/vpn}/incy-box"
# INCY 3.8.8 проверяет готовность xray TCP-подключением именно к 10808 (какой бы
# socksPort ни стоял) и через 20 с без ответа гасит xray. Поэтому по умолчанию и
# держим локальный порт = 10808: тогда INCY сам себе отвечает на проверку, а
# «полные» конфиги провайдеров (LEDOKOL и т.п.), жёстко прошитые на 10808,
# работают без конфликтов. Если 10808 уже занят другим клиентом — задай
# VPN_INCY_PORT=<свободный>; для обычных подписок проверку закроет пустышка ниже
# (но провайдерский full-config, прошитый на 10808, на другом порту не поедет).
INCY_PORT="${VPN_INCY_PORT:-10808}"
INCY_PROBE_PORT=10808
# Если вход INCY — SOCKS (бывает у «полных» конфигов провайдеров, напр. LEDOKOL),
# curl/git понимают socks5h://, а клиенты на Node/undici (Claude Code и др.) — нет
# (unsupportedProxyProtocol). Поэтому в таком случае коробка поднимает локальный
# http→socks мостик на этом порту и отдаёт всем обычный http://-прокси.
INCY_HTTP_PORT="${VPN_INCY_HTTP_PORT:-$((INCY_PORT + 1))}"
INCY_SANDBOX="${VPN_INCY_SANDBOX:-auto}"      # auto | on | off (только Linux)
INCY_HWID="${VPN_INCY_HWID:-}"                # зафиксированный HWID (пусто — по машине)
INCY_PYTHON="${VPN_PYTHON:-python3}"
INCY_START_TIMEOUT="${VPN_INCY_TIMEOUT:-60}"  # секунд на запуск JVM и подключение
INCY_STOP_TIMEOUT=15
INCY_VNC_PORT="${VPN_INCY_VNC_PORT:-5917}"
INCY_XVFB_SCREEN="1280x800x24"
# Частота кадров окна INCY в Xvfb. Окно никто не смотрит, а без лимита Skiko
# рисует анимации программно на полной скорости и держит ядро CPU на 100%.
INCY_FPS="${VPN_INCY_FPS:-1}"
# Уже скачанный релизный файл (zip/dmg) вместо загрузки с GitHub — для машин,
# где GitHub недоступен. sha256 проверяется так же.
INCY_ASSET_FILE="${VPN_INCY_ASSET:-}"

INCY_STATE_PY="$INCY_BOX_DIR/incy_state.py"
INCY_APP_DIR="$INCY_DIR/app"
INCY_HOME_DIR="$INCY_DIR/home"
INCY_SHIM_DIR="$INCY_DIR/shim"
INCY_LINK_HASH_FILE="$INCY_DIR/link.sha256"
INCY_PID_FILE="$INCY_RUN_DIR/incy.pid"
INCY_LOG_FILE="$INCY_RUN_DIR/incy.out"
INCY_XVFB_PID_FILE="$INCY_RUN_DIR/xvfb.pid"
INCY_XVFB_DISPLAY_FILE="$INCY_RUN_DIR/xvfb.display"
INCY_VNC_PID_FILE="$INCY_RUN_DIR/vnc.pid"
INCY_STUB_PID_FILE="$INCY_RUN_DIR/probe-stub.pid"
INCY_BRIDGE_PID_FILE="$INCY_RUN_DIR/http-bridge.pid"
INCY_BRIDGE_CFG="$INCY_RUN_DIR/http-bridge.json"
INCY_LOCK_DIR="$INCY_RUN_DIR/lock"

# Утилиты, через которые INCY лезет в систему. В коробке все — заглушки.
INCY_SHIM_TOOLS="networksetup osascript gsettings kwriteconfig5 kwriteconfig6 dbus-send xdg-mime xdg-settings notify-send"

# sha256 релизных файлов. Для другой версии (VPN_INCY_VERSION) проверка
# пропускается с предупреждением.
incy_expected_sha256() {
    case "$INCY_VERSION/$1" in
        3.8.8/incy-linux-x64-portable.zip)   echo 8eaca5d647fc36d31242bee9f6d0601642bb54fdbd695bb358053a4f6a7ae4b3 ;;
        3.8.8/incy-linux-arm64-portable.zip) echo 1c5c98aa9ae18773074dea8ebb2e913aa7747c3229b91bd9c31bf2aeaeee7b7b ;;
        3.8.8/incy-macos-arm64.dmg)          echo 6679fa578a96805931c5e581ef0dc656da52df9873c4b8c7e3f3bc282164796c ;;
        3.8.8/incy-macos-intel.dmg)          echo 18a68f334951a1de704a2990c4219ec551a90163f05e0fefd541c6f7d97375a1 ;;
    esac
}

# --- Платформа --------------------------------------------------------------

incy_err() {
    echo "Error: $*" >&2
    return 1
}

incy_os() {
    case "$(uname -s)" in
        Linux)  echo linux ;;
        Darwin) echo darwin ;;
        *)      incy_err "INCY box supports Linux and macOS only" ;;
    esac
}

# Имя релизного файла под эту машину
incy_asset() {
    local os arch
    os="$(incy_os)" || return 1
    case "$(uname -m)" in
        x86_64|amd64)  arch=x64 ;;
        arm64|aarch64) arch=arm64 ;;
        *) incy_err "unsupported CPU architecture: $(uname -m)"; return 1 ;;
    esac
    if [ "$os" = "linux" ]; then
        echo "incy-linux-${arch}-portable.zip"
    else
        [ "$arch" = "x64" ] && arch=intel
        echo "incy-macos-${arch}.dmg"
    fi
}

incy_sha256() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Путь к исполняемому файлу INCY внутри коробки
incy_launcher() {
    if [ "$(incy_os)" = "linux" ]; then
        echo "$INCY_APP_DIR/bin/incy"
        return 0
    fi
    local app exe
    for app in "$INCY_APP_DIR"/*.app; do
        [ -d "$app" ] || continue
        exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null)
        [ -n "$exe" ] && { echo "$app/Contents/MacOS/$exe"; return 0; }
    done
    return 1
}

incy_installed() {
    local launcher
    launcher="$(incy_launcher 2>/dev/null)" || return 1
    [ -x "$launcher" ] && [ "$(cat "$INCY_APP_DIR/.version" 2>/dev/null)" = "$INCY_VERSION" ]
}

# --- Установка --------------------------------------------------------------

incy_unzip() {
    if command -v unzip > /dev/null 2>&1; then
        unzip -q -o "$1" -d "$2"
    else
        "$INCY_PYTHON" -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"
    fi
}

# Скачивает релиз, сверяет sha256 и раскладывает в $INCY_APP_DIR.
# Домашний каталог INCY (подписка, настройки) при обновлении не трогается.
incy_install() {
    local os asset url tmp expected actual new_dir
    os="$(incy_os)" || return 1
    asset="$(incy_asset)" || return 1
    url="$INCY_RELEASES/desktop-v$INCY_VERSION/$asset"

    mkdir -p "$INCY_DIR" || return 1
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/incy-install.XXXXXX")" || return 1
    new_dir="$INCY_APP_DIR.new"

    if [ -n "$INCY_ASSET_FILE" ]; then
        echo "Installing INCY $INCY_VERSION from $INCY_ASSET_FILE..." >&2
        cp "$INCY_ASSET_FILE" "$tmp/$asset" || { rm -rf "$tmp"; incy_err "cannot read $INCY_ASSET_FILE"; return 1; }
    else
        command -v curl > /dev/null 2>&1 || { rm -rf "$tmp"; incy_err "curl is required to download INCY"; return 1; }
        echo "Downloading INCY $INCY_VERSION ($asset)..." >&2
        if ! curl -fL --retry 2 --progress-bar -o "$tmp/$asset" "$url"; then
            rm -rf "$tmp"
            incy_err "failed to download $url (or set VPN_INCY_ASSET to a downloaded $asset)"
            return 1
        fi
    fi

    expected="$(incy_expected_sha256 "$asset")"
    actual="$(incy_sha256 "$tmp/$asset")"
    if [ -z "$expected" ]; then
        echo "Warning: no pinned checksum for INCY $INCY_VERSION, sha256=$actual" >&2
    elif [ "$expected" != "$actual" ]; then
        rm -rf "$tmp"
        incy_err "checksum mismatch for $asset (expected $expected, got $actual)"
        return 1
    fi

    rm -rf "$new_dir"
    mkdir -p "$new_dir"
    if [ "$os" = "linux" ]; then
        if ! incy_unzip "$tmp/$asset" "$tmp/x" || [ ! -d "$tmp/x/incy" ]; then
            rm -rf "$tmp" "$new_dir"
            incy_err "failed to unpack $asset"
            return 1
        fi
        mv "$tmp/x/incy/"* "$new_dir/"
        # zip не хранит права, а portable-маркер не должен включиться в будущих
        # версиях: настройки обязаны жить в нашем home, а не рядом с бинарём
        chmod +x "$new_dir/bin/incy" "$new_dir"/lib/app/resources/bin/* 2>/dev/null
        find "$new_dir/lib/runtime" -name jspawnhelper -exec chmod +x {} + 2>/dev/null
        rm -rf "$new_dir/config"
    else
        local mnt="$tmp/mnt"
        mkdir -p "$mnt"
        if ! hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$tmp/$asset" > /dev/null; then
            rm -rf "$tmp" "$new_dir"
            incy_err "failed to mount $asset"
            return 1
        fi
        cp -R "$mnt"/*.app "$new_dir/"
        hdiutil detach "$mnt" -quiet || hdiutil detach "$mnt" -force -quiet
        xattr -dr com.apple.quarantine "$new_dir" 2>/dev/null
    fi
    rm -rf "$tmp"

    echo "$INCY_VERSION" > "$new_dir/.version"
    INCY_APP_DIR="$new_dir" incy_launcher > /dev/null || { rm -rf "$new_dir"; incy_err "INCY launcher not found in $asset"; return 1; }
    # Обновление версии: старый INCY не должен работать из удаляемого каталога
    incy_stop --keep-display
    rm -rf "$INCY_APP_DIR"
    mv "$new_dir" "$INCY_APP_DIR"
    echo "INCY $INCY_VERSION installed to $INCY_APP_DIR" >&2
}

# --- Состояние INCY (через incy_state.py) -----------------------------------

incy_state() {
    local action="$1" query="$2" hwid="${3:-$INCY_HWID}"
    command -v "$INCY_PYTHON" > /dev/null 2>&1 || { incy_err "INCY box needs python3 (set VPN_PYTHON to override)"; return 1; }
    [ -f "$INCY_STATE_PY" ] || { incy_err "incy_state.py not found at $INCY_STATE_PY"; return 1; }
    INCY_ACTION="$action" INCY_HOME="$INCY_HOME_DIR" INCY_OS="$(incy_os)" \
        INCY_PORT="$INCY_PORT" INCY_QUERY="$query" INCY_HWID="$hwid" \
        INCY_HTTP_PORT="$INCY_HTTP_PORT" \
        "$INCY_PYTHON" -I "$INCY_STATE_PY"
}

incy_db_counts() {
    incy_state counts 2>/dev/null || printf '0\t0\n'
}

# Путь к файлу INCY: prefs | db | xray
incy_path() {
    incy_state paths | awk -F'\t' -v kind="$1" '$1 == kind { print $2 }'
}

# --- Процессы ---------------------------------------------------------------

incy_port_open() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

incy_pid_alive() {
    local pid
    [ -f "$1" ] || return 1
    pid="$(cat "$1" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

incy_running() {
    incy_pid_alive "$INCY_PID_FILE"
}

# Процессы коробки запускаются в своей сессии: Ctrl-C в терминале и закрытие
# терминала их не задевают, а остановить можно всю группу разом.
incy_detach_cmd() {
    if command -v setsid > /dev/null 2>&1; then
        INCY_DETACH=(setsid)
    else
        # macOS: утилиты setsid нет, python3 коробке нужен всё равно
        INCY_DETACH=("$INCY_PYTHON" -I -c 'import os, sys
try:
    os.setsid()
except OSError:
    pass
os.execvp(sys.argv[1], sys.argv[1:])')
    fi
}

# Останавливает группу процессов: TERM, ожидание, затем KILL
incy_kill_group() {
    local pid="$1" i
    [ -n "$pid" ] || return 0
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || return 0
    for i in $(seq 1 $((INCY_STOP_TIMEOUT * 4))); do
        kill -0 -- "-$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.25
    done
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
}

# Простая блокировка на mkdir (flock на macOS нет)
incy_lock() {
    local i holder
    mkdir -p "$INCY_RUN_DIR" || return 1
    for i in $(seq 1 $((INCY_START_TIMEOUT * 2 + 60))); do
        if mkdir "$INCY_LOCK_DIR" 2>/dev/null; then
            echo $$ > "$INCY_LOCK_DIR/pid"
            return 0
        fi
        holder="$(cat "$INCY_LOCK_DIR/pid" 2>/dev/null)"
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            rm -rf "$INCY_LOCK_DIR"
            continue
        fi
        sleep 0.5
    done
    incy_err "INCY box is busy (lock $INCY_LOCK_DIR)"
}

incy_unlock() {
    rm -rf "$INCY_LOCK_DIR"
}

# --- Xvfb (Linux) -----------------------------------------------------------

# Печатает DISPLAY виртуального экрана, поднимая Xvfb при необходимости
incy_xvfb_start() {
    local num i
    num="$(cat "$INCY_XVFB_DISPLAY_FILE" 2>/dev/null)"
    if incy_pid_alive "$INCY_XVFB_PID_FILE" && [ -n "$num" ]; then
        echo ":$num"
        return 0
    fi
    command -v Xvfb > /dev/null 2>&1 || {
        incy_err "Xvfb not found. Install it: sudo apt install xvfb"
        return 1
    }

    incy_detach_cmd
    rm -f "$INCY_XVFB_DISPLAY_FILE"
    # -displayfd: Xvfb сам выбирает свободный номер экрана и пишет его в fd 3.
    # -noreset: без него Xvfb сбрасывается, когда отключается последний клиент,
    # и теряет режим из incy_xvfb_rate ещё до запуска INCY
    "${INCY_DETACH[@]}" Xvfb -displayfd 3 -screen 0 "$INCY_XVFB_SCREEN" -nolisten tcp -noreset \
        3> "$INCY_XVFB_DISPLAY_FILE" < /dev/null > "$INCY_RUN_DIR/xvfb.log" 2>&1 &
    echo $! > "$INCY_XVFB_PID_FILE"

    for i in $(seq 1 40); do
        num="$(tr -d '[:space:]' < "$INCY_XVFB_DISPLAY_FILE" 2>/dev/null)"
        if [ -n "$num" ]; then
            echo "$num" > "$INCY_XVFB_DISPLAY_FILE"
            incy_xvfb_rate ":$num"
            echo ":$num"
            return 0
        fi
        incy_pid_alive "$INCY_XVFB_PID_FILE" || break
        sleep 0.25
    done
    cat "$INCY_RUN_DIR/xvfb.log" >&2 2>/dev/null
    incy_err "failed to start Xvfb"
}

# У режима Xvfb нет таймингов (dot clock 0): Skiko считает частоту экрана как
# 0/0 = NaN и перестаёт ограничивать кадры. Даём экрану режим на INCY_FPS Гц.
incy_xvfb_rate() {
    local display="$1" w h rest clock
    command -v xrandr > /dev/null 2>&1 || {
        echo "Warning: xrandr not found, INCY will use a full CPU core (sudo apt install x11-xserver-utils)" >&2
        return 0
    }
    w="${INCY_XVFB_SCREEN%%x*}"
    rest="${INCY_XVFB_SCREEN#*x}"
    h="${rest%%x*}"
    clock="$(awk -v w="$w" -v h="$h" -v f="$INCY_FPS" \
        'BEGIN { printf "%.6f", (w + 20) * (h + 10) * f / 1000000 }')"
    DISPLAY="$display" xrandr --newmode incy "$clock" \
        "$w" $((w + 10)) $((w + 15)) $((w + 20)) "$h" $((h + 2)) $((h + 5)) $((h + 10)) > /dev/null 2>&1
    DISPLAY="$display" xrandr --addmode screen incy > /dev/null 2>&1
    DISPLAY="$display" xrandr --output screen --mode incy > /dev/null 2>&1 || \
        echo "Warning: could not set ${INCY_FPS} Hz mode on Xvfb, INCY will use a full CPU core" >&2
}

# Skiko не опускает лимит кадров ниже 60 (MinMainstreamMonitorRefreshRate).
# Окно в коробке никто не смотрит, поэтому порог правим на 1, а реальную частоту
# задаёт режим Xvfb (incy_xvfb_rate). Повторный вызов ничего не меняет; после
# обновления INCY jar распакован заново, и патч накладывается снова.
incy_skiko_patch() {
    local jar
    for jar in "$INCY_APP_DIR"/lib/app/skiko-awt-[0-9]*.jar; do
        [ -f "$jar" ] || continue
        "$INCY_PYTHON" -I - "$jar" <<'EOF' || echo "Warning: failed to patch $jar, INCY will render at 60 fps" >&2
import os, shutil, struct, sys, zipfile
src = sys.argv[1]
name = "org/jetbrains/skiko/DisplayKt.class"
old = b"\x06" + struct.pack(">d", 60.0)
new = b"\x06" + struct.pack(">d", 1.0)
with zipfile.ZipFile(src) as z:
    if z.read(name).count(old) != 1:
        sys.exit(0)
tmp = src + ".new"
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(tmp, "w") as zout:
    for info in zin.infolist():
        body = zin.read(info)
        if info.filename == name:
            body = body.replace(old, new)
        zout.writestr(info, body, compress_type=info.compress_type)
shutil.copystat(src, tmp)
os.replace(tmp, src)
EOF
    done
}

incy_xvfb_stop() {
    incy_pid_alive "$INCY_XVFB_PID_FILE" && incy_kill_group "$(cat "$INCY_XVFB_PID_FILE")"
    rm -f "$INCY_XVFB_PID_FILE" "$INCY_XVFB_DISPLAY_FILE"
}

# --- Песочница (Linux) ------------------------------------------------------

INCY_SANDBOX_PROBED=""

# Работает ли bubblewrap здесь (на части систем user namespaces закрыты)
incy_sandbox_usable() {
    if [ -z "$INCY_SANDBOX_PROBED" ]; then
        INCY_SANDBOX_PROBED=no
        if command -v bwrap > /dev/null 2>&1 \
           && bwrap --ro-bind / / --dev /dev --proc /proc true > /dev/null 2>&1; then
            INCY_SANDBOX_PROBED=yes
        fi
    fi
    [ "$INCY_SANDBOX_PROBED" = "yes" ]
}

incy_sandbox_enabled() {
    [ "$(incy_os)" = "linux" ] || return 1
    case "$INCY_SANDBOX" in
        off|0|no) return 1 ;;
        on|1|yes)
            incy_sandbox_usable && return 0
            incy_err "VPN_INCY_SANDBOX=on, but bubblewrap is missing or cannot create a sandbox here"
            return 2
            ;;
        *)  incy_sandbox_usable ;;
    esac
}

# Аргументы bwrap: система только для чтения, домашний каталог пользователя
# не виден, писать можно только в home коробки. Сеть, hostname и uid общие с
# хостом — от них зависит HWID.
incy_bwrap_args() {
    local display="$1" dir resolv
    INCY_BWRAP=(bwrap --unshare-pid --unshare-cgroup-try
        --ro-bind /usr /usr --ro-bind /etc /etc
        --proc /proc --dev /dev --tmpfs /dev/shm --tmpfs /tmp --tmpfs /var/tmp)
    for dir in bin sbin lib lib32 lib64 libx32; do
        if [ -L "/$dir" ]; then
            INCY_BWRAP+=(--symlink "$(readlink "/$dir")" "/$dir")
        elif [ -d "/$dir" ]; then
            INCY_BWRAP+=(--ro-bind "/$dir" "/$dir")
        fi
    done
    # resolv.conf обычно ссылка в /run (systemd-resolved, NetworkManager)
    resolv="$(realpath /etc/resolv.conf 2>/dev/null)"
    [ -n "$resolv" ] && [ "${resolv#/etc/}" = "$resolv" ] && INCY_BWRAP+=(--ro-bind-try "$(dirname "$resolv")" "$(dirname "$resolv")")
    INCY_BWRAP+=(--ro-bind-try /var/lib/dbus/machine-id /var/lib/dbus/machine-id
        --ro-bind-try /sys /sys
        --ro-bind "/tmp/.X11-unix/X${display#:}" "/tmp/.X11-unix/X${display#:}"
        --ro-bind "$INCY_APP_DIR" "$INCY_APP_DIR"
        --ro-bind "$INCY_SHIM_DIR" "$INCY_SHIM_DIR"
        --bind "$INCY_HOME_DIR" "$INCY_HOME_DIR"
        --bind "$INCY_RUN_DIR" "$INCY_RUN_DIR"
        --chdir "$INCY_HOME_DIR")
}

# --- Запуск INCY ------------------------------------------------------------

# Пустышка на INCY_PROBE_PORT (см. Конфиг). Если там уже кто-то слушает
# (обычный INCY, v2rayN), проверка INCY и так пройдёт. Уходит сама через
# пару секунд после того, как INCY её проверил.
incy_stub_start() {
    [ "$INCY_PORT" = "$INCY_PROBE_PORT" ] && return 0
    incy_pid_alive "$INCY_STUB_PID_FILE" && return 0
    incy_port_open "$INCY_PROBE_PORT" && return 0
    incy_detach_cmd
    INCY_ACTION=probe-stub INCY_STUB_PORT="$INCY_PROBE_PORT" \
        INCY_STUB_LIFETIME=$((INCY_START_TIMEOUT * 2 + 30)) \
        "${INCY_DETACH[@]}" "$INCY_PYTHON" -I "$INCY_STATE_PY" \
        < /dev/null >> "$INCY_RUN_DIR/probe-stub.log" 2>&1 &
    echo $! > "$INCY_STUB_PID_FILE"
}

incy_stub_stop() {
    incy_pid_alive "$INCY_STUB_PID_FILE" && kill "$(cat "$INCY_STUB_PID_FILE")" 2>/dev/null
    rm -f "$INCY_STUB_PID_FILE"
}

# --- http→socks мостик (для socks-входа INCY) -------------------------------

# Путь к xray: отдельный бинарь рядом не кладём, берём тот, что в составе INCY.
incy_xray_bin() {
    command -v xray 2>/dev/null && return 0
    local bin
    bin="$(find -L "$INCY_APP_DIR" -type f -name xray 2>/dev/null | head -1)"
    [ -n "$bin" ] && { echo "$bin"; return 0; }
    return 1
}

# Поднимает http→socks мостик, если его ещё нет. Возвращает 0, когда мостик готов.
incy_bridge_start() {
    local xray i
    if incy_pid_alive "$INCY_BRIDGE_PID_FILE" && incy_port_open "$INCY_HTTP_PORT"; then
        return 0
    fi
    incy_bridge_stop
    if incy_port_open "$INCY_HTTP_PORT"; then
        incy_err "http bridge port $INCY_HTTP_PORT is busy (set VPN_INCY_HTTP_PORT)"
        return 1
    fi
    xray="$(incy_xray_bin)" || { incy_err "xray binary not found for the http bridge"; return 1; }
    incy_state bridge-config > "$INCY_BRIDGE_CFG" || return 1

    incy_detach_cmd
    "${INCY_DETACH[@]}" "$xray" run -c "$INCY_BRIDGE_CFG" \
        < /dev/null > "$INCY_RUN_DIR/http-bridge.log" 2>&1 &
    echo $! > "$INCY_BRIDGE_PID_FILE"

    for i in $(seq 1 40); do
        incy_pid_alive "$INCY_BRIDGE_PID_FILE" || { tail -n 10 "$INCY_RUN_DIR/http-bridge.log" >&2; incy_err "http bridge exited"; return 1; }
        incy_port_open "$INCY_HTTP_PORT" && return 0
        sleep 0.25
    done
    incy_err "http bridge did not come up on $INCY_HTTP_PORT"
}

incy_bridge_stop() {
    incy_pid_alive "$INCY_BRIDGE_PID_FILE" && incy_kill_group "$(cat "$INCY_BRIDGE_PID_FILE")"
    rm -f "$INCY_BRIDGE_PID_FILE"
}

# Печатает прокси-URL, который коробка отдаёт наружу. Для mixed-входа — http://
# напрямую; для socks-входа поднимает мостик и отдаёт http:// на него (чтобы
# работали и curl, и Node-клиенты вроде Claude Code).
incy_proxy_url() {
    local proto
    proto="$(incy_state endpoint | cut -f2)"
    if [ "$proto" = "socks" ]; then
        incy_bridge_start || return 1
        echo "http://127.0.0.1:$INCY_HTTP_PORT"
    else
        incy_state proxy-url
    fi
}

incy_make_shims() {
    local tool
    mkdir -p "$INCY_SHIM_DIR" || return 1
    for tool in $INCY_SHIM_TOOLS; do
        cat > "$INCY_SHIM_DIR/$tool" <<EOF
#!/bin/sh
# Заглушка коробки INCY: в систему INCY отсюда не дотягивается.
echo "\$(date '+%Y-%m-%d %H:%M:%S') $tool \$*" >> "$INCY_RUN_DIR/shim.log"
exit 0
EOF
        chmod +x "$INCY_SHIM_DIR/$tool"
    done
}

# Собирает команду запуска INCY в INCY_CMD. Окружение — с нуля: без XDG_*,
# DBus и рабочего стола INCY не дотянется до настроек и трея пользователя.
incy_build_cmd() {
    local display="$1" launcher
    shift
    launcher="$(incy_launcher)" || { incy_err "INCY is not installed"; return 1; }

    INCY_CMD=(env -i
        "PATH=$INCY_SHIM_DIR:$PATH"
        "HOME=$INCY_HOME_DIR"
        "USER=${USER:-$(id -un)}"
        "LOGNAME=${LOGNAME:-${USER:-$(id -un)}}"
        "LANG=${LANG:-en_US.UTF-8}"
        "JAVA_TOOL_OPTIONS=-Duser.home=$INCY_HOME_DIR")
    [ -n "$TZ" ] && INCY_CMD+=("TZ=$TZ")
    [ -n "$display" ] && INCY_CMD+=("DISPLAY=$display")

    local sandbox_rc=1
    if [ "$(incy_os)" = "linux" ]; then
        incy_sandbox_enabled
        sandbox_rc=$?
        [ "$sandbox_rc" -eq 2 ] && return 1
    fi
    if [ "$sandbox_rc" -eq 0 ]; then
        incy_bwrap_args "$display"
        INCY_CMD+=("${INCY_BWRAP[@]}")
    fi
    INCY_CMD+=("$launcher" "$@")
}

# Запускает INCY в фоне. Дополнительные аргументы (deep link) уходят INCY.
incy_start() {
    local display="" pid i

    if incy_running; then
        return 0
    fi
    if incy_port_open "$INCY_PORT"; then
        incy_err "port $INCY_PORT is already taken by another program (set VPN_INCY_PORT)"
        return 1
    fi

    mkdir -p "$INCY_RUN_DIR" "$INCY_HOME_DIR" || return 1
    incy_make_shims || return 1
    incy_state seed || return 1
    if [ "$(incy_os)" = "linux" ]; then
        incy_skiko_patch
        display="$(incy_xvfb_start)" || return 1
    fi
    incy_build_cmd "$display" "$@" || return 1
    incy_detach_cmd

    # INCY пишет xray_config.json при подключении — его появление и есть сигнал
    rm -f "$(incy_path xray)"
    incy_stub_start
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') start ===" >> "$INCY_LOG_FILE"
    (cd "$INCY_HOME_DIR" && exec "${INCY_DETACH[@]}" "${INCY_CMD[@]}") \
        < /dev/null >> "$INCY_LOG_FILE" 2>&1 &
    pid=$!
    echo "$pid" > "$INCY_PID_FILE"

    # Второй экземпляр на том же home сразу отдаёт аргументы первому и выходит
    for i in 1 2 3 4; do
        sleep 0.5
        kill -0 "$pid" 2>/dev/null && continue
        rm -f "$INCY_PID_FILE"
        incy_stub_stop
        tail -n 20 "$INCY_LOG_FILE" >&2
        incy_err "INCY exited right after start (see $INCY_LOG_FILE)"
        return 1
    done
}

# Ждёт, пока INCY подключится: свежий xray_config.json и открытый порт
incy_wait_ready() {
    local xray i rc=1
    xray="$(incy_path xray)"
    for i in $(seq 1 $((INCY_START_TIMEOUT * 2))); do
        if ! incy_running; then
            tail -n 20 "$INCY_LOG_FILE" >&2
            incy_err "INCY stopped while connecting"
            break
        fi
        if [ -n "$xray" ] && [ -f "$xray" ] && incy_port_open "$INCY_PORT"; then
            rc=0
            break
        fi
        sleep 0.5
    done
    # Пустышка уходит сама сразу после проверки INCY; здесь гасим её только
    # при неудаче, иначе можно убить её раньше, чем INCY до неё достучится
    [ "$rc" -eq 0 ] && return 0
    incy_stub_stop
    [ "$i" -lt $((INCY_START_TIMEOUT * 2)) ] || \
        incy_err "INCY did not connect within ${INCY_START_TIMEOUT}s (see 'vpn incy log')"
    return 1
}

# Остановка. --keep-display оставляет Xvfb для быстрого перезапуска.
incy_stop() {
    if incy_running; then
        incy_kill_group "$(cat "$INCY_PID_FILE")"
    fi
    rm -f "$INCY_PID_FILE"
    incy_stub_stop
    incy_bridge_stop
    if [ "$1" != "--keep-display" ]; then
        incy_vnc_stop
        incy_xvfb_stop
    fi
}

# --- Подписка ---------------------------------------------------------------

incy_link_hash() {
    if command -v sha256sum > /dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -d' ' -f1
    else
        printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
    fi
}

# Отдаёт ссылку INCY один раз. Ссылка передаётся аргументом при старте:
# пересылка уже запущенному INCY обрабатывается им несколько раз и плодит
# дубли подписки. Сменилась ссылка в ~/.vpn_proxy — база INCY пересоздаётся.
incy_import() {
    local link="$1" hash subs servers i db
    hash="$(incy_link_hash "$link")"
    read -r subs servers <<< "$(incy_db_counts)"

    if [ "$subs" -gt 0 ] && [ "$(cat "$INCY_LINK_HASH_FILE" 2>/dev/null)" = "$hash" ]; then
        return 0
    fi

    incy_stop --keep-display
    if [ "$subs" -gt 0 ]; then
        echo "Subscription link changed, re-importing it into INCY..." >&2
        db="$(incy_path db)"
        [ -n "$db" ] && rm -f "$db" "$db-wal" "$db-shm"
    else
        echo "Importing the subscription into INCY..." >&2
    fi

    incy_start "$link" || return 1
    for i in $(seq 1 $((INCY_START_TIMEOUT * 2))); do
        read -r subs servers <<< "$(incy_db_counts)"
        [ "$servers" -gt 0 ] && break
        incy_running || { tail -n 20 "$INCY_LOG_FILE" >&2; incy_err "INCY stopped while importing the link"; return 1; }
        sleep 0.5
    done
    if [ "$servers" -eq 0 ]; then
        incy_stop --keep-display
        incy_err "INCY did not load any servers from the link (see 'vpn incy log')"
        return 1
    fi
    echo "$hash" > "$INCY_LINK_HASH_FILE"

    # Выбор сервера пишется в настройки, пока INCY не запущен
    incy_stop --keep-display
    echo "INCY loaded $servers server(s), using: $(incy_state select)" >&2
}

# --- Публичные операции -----------------------------------------------------

# Гарантирует установленный, импортированный и подключённый INCY.
# Печатает URL локального прокси.
incy_ensure() {
    local link="$1" rc=0
    incy_lock || return 1
    # INCY жив, но порт закрыт — сам отключился (переподключение после
    # обновления подписки и т.п.). Перезапуск это лечит.
    if incy_running && ! incy_port_open "$INCY_PORT"; then
        echo "INCY lost its connection, restarting it..." >&2
        incy_stop --keep-display
    fi
    {
        { incy_installed || incy_install; } &&
        incy_import "$link" &&
        { incy_running || { incy_state select > /dev/null && incy_start; }; } &&
        incy_wait_ready
    } || rc=1
    incy_unlock
    [ "$rc" -eq 0 ] || return 1
    incy_proxy_url
}

incy_restart() {
    local rc=0
    incy_lock || return 1
    incy_stop --keep-display
    { incy_start && incy_wait_ready; } || rc=1
    incy_unlock
    return $rc
}

# Перечитать подписку. Отдельной команды у INCY нет: при старте он обновляет
# устаревшие подписки, поэтому помечаем их устаревшими и перезапускаем.
incy_update() {
    local rc=0 i
    incy_lock || return 1
    incy_stop --keep-display
    if incy_state mark-stale && incy_start && incy_wait_ready; then
        for i in $(seq 1 40); do
            [ "$(incy_state last-updated 2>/dev/null)" != "0" ] && break
            sleep 0.5
        done
        [ "$(incy_state last-updated 2>/dev/null)" = "0" ] && \
            echo "Warning: INCY has not refreshed the subscription yet (see 'vpn incy log')" >&2
        # Обновление пересоздаёт записи серверов: если выбранного больше нет,
        # выбираем его заново (по имени) и переподключаемся
        if ! incy_state current > /dev/null 2>&1; then
            incy_stop --keep-display
            { incy_state select > /dev/null && incy_start && incy_wait_ready; } || rc=1
        fi
    else
        rc=1
    fi
    incy_unlock
    return $rc
}

# Список серверов в формате, похожем на `vpn list`
incy_list() {
    incy_state servers | awk -F'\t' '{ printf "%s %3d  %s  (%s)\n", $1, $2, $3, $4 }'
}

# Выбрать сервер (номер, имя или кусок имени) и переподключиться
incy_use() {
    local query="$1" name rc=0
    incy_lock || return 1
    incy_stop --keep-display
    if name="$(incy_state select "$query")"; then
        echo "Default server: $name"
        { incy_start && incy_wait_ready; } || rc=1
    else
        rc=1
    fi
    incy_unlock
    return $rc
}

incy_status() {
    local port proto user server sandbox="off"
    if ! incy_installed; then
        echo "  INCY box: not installed (first 'vpn <command>' installs it)"
        return 0
    fi
    incy_sandbox_enabled > /dev/null 2>&1 && sandbox="bubblewrap"
    [ "$(incy_os)" = "darwin" ] && sandbox="n/a on macOS"
    if incy_running; then
        read -r port proto user <<< "$(incy_state endpoint 2>/dev/null)"
        server="$(incy_state current 2>/dev/null)"
        echo "  INCY $INCY_VERSION  running (PID $(cat "$INCY_PID_FILE"))  ${proto:-mixed}=127.0.0.1:${port:-$INCY_PORT}  user=${user:-?}"
        if [ "$proto" = "socks" ] && incy_pid_alive "$INCY_BRIDGE_PID_FILE"; then
            echo "  http bridge (for Node/curl/git): http://127.0.0.1:$INCY_HTTP_PORT"
        fi
        echo "  server: ${server:-?}   sandbox: $sandbox"
    else
        echo "  INCY $INCY_VERSION  not running   sandbox: $sandbox"
    fi
}

# HWID коробки. Без аргумента — печатает текущий; с аргументом — закрепляет
# заданный UUID (чтобы VM и мак считались у провайдера одним устройством) и
# переподключает INCY, чтобы новый HWID попал в запрос подписки.
incy_hwid() {
    local want="$1" rc=0 current
    if [ -z "$want" ]; then
        current="$(incy_state hwid '' '')"
        if [ -n "$current" ]; then
            echo "$current"
        else
            echo "HWID not set yet — run 'vpn incy setup' once, then 'vpn incy hwid'" >&2
            return 1
        fi
        return 0
    fi

    incy_installed || { incy_err "install INCY first: vpn incy setup"; return 1; }
    incy_lock || return 1
    incy_stop --keep-display
    if incy_state set-hwid '' "$want" > /dev/null; then
        echo "HWID pinned: $want"
        # Переподключаемся только если подписка уже импортирована
        if [ "$(incy_db_counts | cut -f2)" -gt 0 ]; then
            { incy_start && incy_wait_ready; } || rc=1
        fi
    else
        rc=1
    fi
    incy_unlock
    return $rc
}

# Показать окно INCY. Linux: VNC к виртуальному экрану (только localhost),
# macOS: обычное окно.
incy_ui() {
    local launcher display pw
    incy_running || { incy_err "INCY is not running (run any 'vpn <command>' first)"; return 1; }
    launcher="$(incy_launcher)" || return 1

    if [ "$(incy_os)" = "linux" ]; then
        command -v x11vnc > /dev/null 2>&1 || { incy_err "x11vnc not found. Install it: sudo apt install x11vnc"; return 1; }
        display=":$(cat "$INCY_XVFB_DISPLAY_FILE")"
        if ! incy_pid_alive "$INCY_VNC_PID_FILE"; then
            pw="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
            x11vnc -storepasswd "$pw" "$INCY_RUN_DIR/vnc.pass" > /dev/null 2>&1
            incy_detach_cmd
            "${INCY_DETACH[@]}" x11vnc -display "$display" -localhost -rfbport "$INCY_VNC_PORT" \
                -rfbauth "$INCY_RUN_DIR/vnc.pass" -forever -shared -quiet \
                < /dev/null > "$INCY_RUN_DIR/vnc.log" 2>&1 &
            echo $! > "$INCY_VNC_PID_FILE"
            echo "$pw" > "$INCY_RUN_DIR/vnc.pw"
            chmod 600 "$INCY_RUN_DIR/vnc.pw" "$INCY_RUN_DIR/vnc.pass"
        fi
        echo "INCY window is available over VNC on 127.0.0.1:$INCY_VNC_PORT"
        echo "  password: $(cat "$INCY_RUN_DIR/vnc.pw")"
        echo "  from another machine: ssh -L $INCY_VNC_PORT:127.0.0.1:$INCY_VNC_PORT <this-host>"
        echo "  close it with: vpn incy ui stop"
    fi

    # Второй экземпляр без аргументов просит первый показать окно
    incy_build_cmd "$display" || return 1
    "${INCY_CMD[@]}" < /dev/null > /dev/null 2>&1
    [ "$(incy_os)" = "darwin" ] && echo "INCY window opened. Settings you change there are kept."
    return 0
}

incy_vnc_stop() {
    incy_pid_alive "$INCY_VNC_PID_FILE" && incy_kill_group "$(cat "$INCY_VNC_PID_FILE")"
    rm -f "$INCY_VNC_PID_FILE" "$INCY_RUN_DIR/vnc.pw" "$INCY_RUN_DIR/vnc.pass"
}

incy_log() {
    local own
    own="$(dirname "$(incy_path xray 2>/dev/null)")/incy.log"
    echo "--- $INCY_LOG_FILE"
    tail -n "${1:-40}" "$INCY_LOG_FILE" 2>/dev/null
    echo "--- $own"
    tail -n "${1:-40}" "$own" 2>/dev/null
}

# Забыть подписку и настройки INCY (сам клиент остаётся)
incy_reset() {
    incy_lock || return 1
    incy_stop
    rm -rf "$INCY_HOME_DIR" "$INCY_LINK_HASH_FILE" "$INCY_SHIM_DIR"
    incy_unlock
    echo "INCY box reset: subscription and settings removed"
}

# --- Прямой запуск для отладки ----------------------------------------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "$1" in
        install) incy_install ;;
        ensure)  [ -n "$2" ] || { echo "Usage: $0 ensure <incy://link>"; exit 1; }; incy_ensure "$2" ;;
        start)   incy_start && incy_wait_ready ;;
        stop)    incy_stop ;;
        restart) incy_restart ;;
        update)  incy_update && incy_list ;;
        status)  incy_status ;;
        list)    incy_list ;;
        use)     incy_use "$2" ;;
        ui)      incy_ui ;;
        hwid)    incy_hwid "$2" ;;
        log)     incy_log "$2" ;;
        reset)   incy_reset ;;
        *)
            echo "Usage: $0 {install|ensure <link>|start|stop|restart|update|status|list|use <server>|ui|hwid [uuid]|log|reset}"
            exit 1
            ;;
    esac
fi
