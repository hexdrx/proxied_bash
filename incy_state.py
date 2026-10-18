#!/usr/bin/env python3
"""Чтение и правка состояния изолированного INCY (см. incy_box.sh).

INCY хранит всё в трёх местах внутри своего домашнего каталога:
  preferences.json  — настройки (режим, порт, выбранный сервер, ...)
  incy.db           — SQLite: подписки и серверы
  xray_config.json  — конфиг, который INCY сгенерировал при подключении

Скрипт ничего не расшифровывает и в сеть не ходит: только локальные файлы
INCY. URL подписки из базы не читается — он не нужен ни для одной операции.
В базу пишется ровно одно — отметка «подписка устарела» (mark-stale), чтобы
INCY сам перечитал её при старте; всё остальное там только читается.

Вызывается из incy_box.sh. Параметры приходят через переменные окружения
(блок «Конфиг» ниже), результат — в stdout. Только stdlib, Python 3.8+
(на маке системный python3 из Command Line Tools).
"""

import json
import os
import re
import sqlite3
import sys
import time
from urllib.parse import quote

# --- Конфиг -----------------------------------------------------------------

ACTION = os.environ.get("INCY_ACTION", "")          # см. ACTIONS внизу файла
INCY_HOME = os.environ.get("INCY_HOME", "")         # подменённый user.home INCY
INCY_OS = os.environ.get("INCY_OS", "linux")        # linux|darwin
INCY_PORT = os.environ.get("INCY_PORT", "18808")    # локальный mixed-порт
INCY_QUERY = os.environ.get("INCY_QUERY", "")       # номер / имя сервера для select
INCY_HWID = os.environ.get("INCY_HWID", "")         # зафиксированный HWID (пусто — не трогать)
INCY_STUB_PORT = int(os.environ.get("INCY_STUB_PORT", "10808"))
INCY_STUB_LIFETIME = float(os.environ.get("INCY_STUB_LIFETIME", "120"))
INCY_STUB_LINGER = 2.0    # сколько ещё держать порт после первой проверки INCY

# Настройки, которые коробка навязывает INCY при каждом запуске. Остальные
# ключи (то, что пользователь поменял в окне INCY) не трогаем.
FORCED_PREFS = {
    "tunnelMode": "PROXY_ONLY",     # ни TUN, ни системного прокси — только порт
    "autoConnect": True,            # после старта сразу подключаться
    "startMinimized": True,
    "hideDockIconMac": True,
    "minimizeToTray": False,
    "autostart": False,             # никаких автозапусков в систему
    "sendHWID": True,               # провайдер должен видеть обычный INCY
    "socks5AuthEnabled": True,      # порт закрыт паролем
    "httpAuthEnabled": True,
    "allowLanConnections": False,   # слушать только 127.0.0.1
    "allowLanHotspot": False,
    "allowLanViaProxy": False,
    "hasLaunchedBefore": True,      # без онбординга
    "showProxyOnlyButton": True,
    "updateOnLaunch": True,         # `vpn update` = перезапуск INCY
}

DB_RETRIES = 10           # база может быть занята пишущим INCY
DB_RETRY_DELAY = 0.3

# Пути INCY (из LinuxPaths / MacPaths клиента)
PATHS = {
    "linux": {
        "prefs": (".config", "incy", "preferences.json"),
        "db": (".local", "share", "incy", "incy.db"),
        "xray": (".cache", "incy", "xray_config.json"),
        "hwid": (".config", "incy", "hwid"),
    },
    "darwin": {
        "prefs": ("Library", "Application Support", "incy", "preferences.json"),
        "db": ("Library", "Application Support", "incy", "incy.db"),
        "xray": ("Library", "Caches", "incy", "xray_config.json"),
        "hwid": ("Library", "Application Support", "incy", "hwid"),
    },
}

# INCY доверяет файлу hwid, если в нём ровно 36 символов и есть дефис, и
# использует его как есть, не пересчитывая (llc.itdev.incy.c.c.e в клиенте).
# Требуем канонический UUID 8-4-4-4-12, чтобы в заголовок не ушёл мусор.
HWID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}"
                     r"-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")


class StateError(Exception):
    pass


def path_of(kind):
    if not INCY_HOME:
        raise StateError("INCY_HOME is not set")
    if INCY_OS not in PATHS:
        raise StateError("unsupported INCY_OS: %s" % INCY_OS)
    return os.path.join(INCY_HOME, *PATHS[INCY_OS][kind])


# --- preferences.json -------------------------------------------------------

def load_prefs():
    path = path_of("prefs")
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        try:
            data = json.load(f)
        except ValueError:
            raise StateError("%s is not valid JSON" % path)
    if not isinstance(data, dict):
        raise StateError("%s is not a JSON object" % path)
    return data


def save_prefs(prefs):
    path = path_of("prefs")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(prefs, f, ensure_ascii=False)
    os.replace(tmp, path)


def seed():
    """Сливает FORCED_PREFS и порт в настройки, не теряя чужих ключей.

    Если задан INCY_HWID — закрепляет его (см. write_hwid). Иначе файл hwid
    не трогается: INCY сам считает HWID из machine-id/hostname этой машины.
    """
    prefs = load_prefs()
    prefs.update(FORCED_PREFS)
    prefs["socksPort"] = int(INCY_PORT)
    save_prefs(prefs)
    if INCY_HWID:
        write_hwid(INCY_HWID)


# --- HWID -------------------------------------------------------------------

def read_hwid():
    """Текущий HWID из файла INCY ("" — если его ещё нет)."""
    path = path_of("hwid")
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def write_hwid(value):
    """Фиксирует HWID: пишет UUID в файл, который INCY читает и не перезаписывает.

    Нужно, чтобы несколько установок на одной машине (например VM на маке и
    сам мак) считались у провайдера одним устройством. INCY перезатрёт файл
    только если он невалиден, поэтому значение проверяем.
    """
    value = value.strip()
    if not HWID_RE.match(value):
        raise StateError("HWID must be a UUID like 1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D")
    path = path_of("hwid")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(value)
    os.replace(tmp, path)


def hwid_cmd():
    """Печатает закреплённый/текущий HWID (пусто — ещё не создан)."""
    print(read_hwid())


def set_hwid_cmd():
    write_hwid(INCY_HWID)
    print(INCY_HWID.strip())


# --- incy.db ----------------------------------------------------------------

def query_db(sql, params=()):
    path = path_of("db")
    if not os.path.exists(path):
        return []
    last_error = None
    for _ in range(DB_RETRIES):
        try:
            # mode=ro: коробка только читает базу, пишет в неё один INCY
            db = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=2)
            try:
                return db.execute(sql, params).fetchall()
            finally:
                db.close()
        except sqlite3.OperationalError as e:
            # Свежая база без таблиц — INCY ещё не дошёл до миграций
            if "no such table" in str(e):
                return []
            last_error = e
            time.sleep(DB_RETRY_DELAY)
    raise StateError("cannot read %s: %s" % (path, last_error))


def list_servers():
    """[(id, name, subscription_name)] в том порядке, что показывает INCY."""
    rows = query_db(
        "SELECT s.id, s.name, COALESCE(NULLIF(sub.customName, ''), sub.name, '') "
        "FROM servers s LEFT JOIN subscriptions sub ON sub.id = s.subscriptionId "
        "ORDER BY sub.orderIndex IS NULL, sub.orderIndex, sub.createdAt, "
        "s.orderIndex, s.createdAt")
    return [(r[0], r[1] or "", r[2] or "") for r in rows]


def counts():
    subs = query_db("SELECT count(*) FROM subscriptions")
    servers = query_db("SELECT count(*) FROM servers")
    return (subs[0][0] if subs else 0), (servers[0][0] if servers else 0)


def last_updated():
    """Самое старое время обновления подписок (мс), 0 — если не обновлялись."""
    rows = query_db("SELECT min(COALESCE(lastUpdated, 0)) FROM subscriptions")
    print(rows[0][0] if rows and rows[0][0] is not None else 0)


def mark_stale():
    """Сбрасывает время обновления подписок: при старте INCY перечитает их.

    updateOnLaunch в INCY срабатывает только для устаревших подписок, а
    отдельной команды «обновить» у клиента нет. Вызывать при остановленном INCY.
    """
    path = path_of("db")
    if not os.path.exists(path):
        raise StateError("INCY database not found: %s" % path)
    db = sqlite3.connect(path, timeout=5)
    try:
        db.execute("UPDATE subscriptions SET lastUpdated = 0")
        db.commit()
    finally:
        db.close()


def find_server(servers, query):
    """Номер из `vpn list`, точное имя или подстрока имени (без регистра)."""
    q = query.strip()
    if q.isdigit():
        idx = int(q)
        if 1 <= idx <= len(servers):
            return servers[idx - 1]
        raise StateError("no server #%d (see 'vpn list')" % idx)

    low = q.lower()
    exact = [s for s in servers if s[1].lower() == low]
    if len(exact) == 1:
        return exact[0]
    partial = exact or [s for s in servers if low in s[1].lower()]
    if len(partial) == 1:
        return partial[0]
    if not partial:
        raise StateError("no server matches '%s' (see 'vpn list')" % q)
    names = "\n".join("  %s" % s[1] for s in partial)
    raise StateError("'%s' matches several servers, be more specific:\n%s" % (q, names))


def select():
    servers = list_servers()
    if not servers:
        raise StateError("INCY has no servers yet (subscription not imported?)")
    prefs = load_prefs()

    if INCY_QUERY:
        chosen = find_server(servers, INCY_QUERY)
    else:
        # Без запроса: оставляем текущий. Обновление подписки пересоздаёт
        # записи серверов с новыми id, поэтому запасной ключ — имя сервера.
        current = prefs.get("selectedServerId")
        last_name = prefs.get("lastConnectedServerName")
        chosen = (next((s for s in servers if s[0] == current), None)
                  or next((s for s in servers if last_name and s[1] == last_name), None)
                  or servers[0])

    prefs["selectedServerId"] = chosen[0]
    prefs["lastConnectedServerName"] = chosen[1]
    save_prefs(prefs)
    print(chosen[1])


def current():
    selected = load_prefs().get("selectedServerId")
    for sid, name, _ in list_servers():
        if sid == selected:
            print(name)
            return
    raise StateError("no server selected")


def servers_table():
    selected = load_prefs().get("selectedServerId")
    for idx, (sid, name, sub) in enumerate(list_servers(), 1):
        mark = "*" if sid == selected else " "
        print("%s\t%d\t%s\t%s" % (mark, idx, name, sub))


# --- xray_config.json -------------------------------------------------------

def local_inbound():
    """(port, user, password) локального входа, который поднял INCY."""
    path = path_of("xray")
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError) as e:
        raise StateError("cannot read %s: %s" % (path, e))

    for inbound in cfg.get("inbounds", []):
        # mixed = SOCKS5 и HTTP на одном порту; socks — на случай старых версий
        if inbound.get("protocol") not in ("mixed", "socks"):
            continue
        if inbound.get("listen") not in ("127.0.0.1", "localhost"):
            continue
        accounts = (inbound.get("settings") or {}).get("accounts") or []
        user = accounts[0].get("user", "") if accounts else ""
        password = accounts[0].get("pass", "") if accounts else ""
        return inbound.get("port"), user, password, inbound.get("protocol")
    raise StateError("no local mixed/socks inbound in %s" % path)


def endpoint():
    port, user, _, protocol = local_inbound()
    print("%s\t%s\t%s" % (port, protocol, user))


def proxy_url():
    """URL для http_proxy/https_proxy. Пароль внутри: печатается только в vpn."""
    port, user, password, protocol = local_inbound()
    if protocol != "mixed":
        raise StateError("INCY exposes a %s inbound, HTTP proxy needs 'mixed'" % protocol)
    auth = ""
    if user:
        auth = "%s:%s@" % (quote(user, safe=""), quote(password, safe=""))
    print("http://%s127.0.0.1:%s" % (auth, port))


def paths():
    for kind in ("prefs", "db", "xray"):
        print("%s\t%s" % (kind, path_of(kind)))


def probe_stub():
    """Пустышка на 127.0.0.1:10808 на время подключения INCY.

    INCY 3.8.8 после старта xray ждёт TCP-ответа именно на 10808, даже если
    socksPort в настройках другой, а через 20 с без ответа останавливает
    xray. Пустышка просто принимает и закрывает соединения и сама уходит
    через INCY_STUB_LINGER после первой проверки, чтобы не занимать чужой
    порт дольше нужного. Без проверок — через INCY_STUB_LIFETIME.
    """
    import socket

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("127.0.0.1", INCY_STUB_PORT))
    except OSError as e:
        raise StateError("cannot listen on 127.0.0.1:%d: %s" % (INCY_STUB_PORT, e))
    srv.listen(16)
    deadline = time.monotonic() + INCY_STUB_LIFETIME
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            return
        srv.settimeout(left)
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            return
        conn.close()
        deadline = min(deadline, time.monotonic() + INCY_STUB_LINGER)


ACTIONS = {
    "seed": seed,
    "servers": servers_table,
    "select": select,
    "current": current,
    "counts": lambda: print("%d\t%d" % counts()),
    "last-updated": last_updated,
    "mark-stale": mark_stale,
    "endpoint": endpoint,
    "proxy-url": proxy_url,
    "paths": paths,
    "probe-stub": probe_stub,
    "hwid": hwid_cmd,
    "set-hwid": set_hwid_cmd,
}


def main():
    action = ACTIONS.get(ACTION)
    if action is None:
        sys.stderr.write("incy_state.py: unknown INCY_ACTION '%s'\n" % ACTION)
        return 2
    try:
        action()
    except StateError as e:
        sys.stderr.write("Error: %s\n" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
