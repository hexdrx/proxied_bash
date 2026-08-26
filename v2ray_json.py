#!/usr/bin/env python3
"""Turns a v2ray-JSON subscription body into a list of `vless://` links.

Not every panel answers with share links. Some (Remnawave among them) serve an
array of whole Xray configs — one per server, each carrying its own `inbounds`,
`routing` and a display name in `remarks`:

    [{"remarks":"🇩🇪 Германия","outbounds":[{"tag":"proxy","protocol":"vless",…}]}]

Only the proxy outbound is of interest: `vpn` builds its own inbounds and picks
the server itself, so the provider's routing rules would be dead weight at best
and would override the country choice at worst.

Entries on protocols this tool cannot carry (hysteria, trojan, …) are dropped
rather than emitted as links that fail later at `xray -test`.

Usage:  v2ray_json.py < body      -> prints one vless:// link per line
Exits 1 (silently) when the body is not v2ray-JSON, so callers can fall through
to the base64/plain-text path.
"""

import json
import sys
from urllib.parse import quote, urlencode


def _non_empty(value):
    return value if isinstance(value, str) and value else None


def outbound_to_vless(outbound, remark):
    """Maps one Xray `vless` outbound onto a vless:// share link."""
    settings = outbound.get("settings") or {}
    vnext = (settings.get("vnext") or [None])[0]
    if not isinstance(vnext, dict):
        return None
    host = _non_empty(vnext.get("address"))
    port = vnext.get("port")
    user = (vnext.get("users") or [None])[0]
    if not host or not isinstance(port, int) or not isinstance(user, dict):
        return None
    uuid = _non_empty(user.get("id"))
    if not uuid:
        return None

    stream = outbound.get("streamSettings") or {}
    network = (stream.get("network") or "tcp").lower()
    security = (stream.get("security") or "none").lower()

    def section(key):
        return stream.get(key) or {}

    # VLESS has no encryption layer of its own; the share-link scheme still
    # spells it out, and some clients reject a link without it.
    params = [("encryption", "none"), ("type", network), ("security", security)]

    def put(name, value):
        if value:
            params.append((name, value))

    # Xray writes an unset field as "", which must not become "&flow=".
    put("flow", _non_empty(user.get("flow")))

    if security == "reality":
        reality = section("realitySettings")
        put("sni", _non_empty(reality.get("serverName")))
        put("fp", _non_empty(reality.get("fingerprint")))
        put("pbk", _non_empty(reality.get("publicKey")))
        put("sid", _non_empty(reality.get("shortId")))
    elif security == "tls":
        tls = section("tlsSettings")
        put("sni", _non_empty(tls.get("serverName")))
        put("fp", _non_empty(tls.get("fingerprint")))
        alpn = tls.get("alpn")
        if isinstance(alpn, list) and alpn:
            put("alpn", ",".join(alpn))

    if network == "grpc":
        put("serviceName", _non_empty(section("grpcSettings").get("serviceName")))
    elif network in ("ws", "httpupgrade"):
        ws = section("wsSettings" if network == "ws" else "httpupgradeSettings")
        put("path", _non_empty(ws.get("path")))
        # "host" is the modern spelling; older panels still emit a Host header.
        put("host", _non_empty(ws.get("host"))
            or _non_empty((ws.get("headers") or {}).get("Host")))
    elif network in ("http", "h2"):
        http = section("httpSettings")
        put("path", _non_empty(http.get("path")))
        hosts = http.get("host")
        put("host", hosts[0] if isinstance(hosts, list) and hosts else _non_empty(hosts))
    elif network in ("xhttp", "splithttp"):
        xhttp = section("xhttpSettings" if network == "xhttp" else "splithttpSettings")
        put("path", _non_empty(xhttp.get("path")))
        put("host", _non_empty(xhttp.get("host")))
        put("mode", _non_empty(xhttp.get("mode")))

    link = "vless://%s@%s:%d?%s" % (uuid, host, port, urlencode(params))
    if remark:
        link += "#" + quote(remark, safe="")
    return link


def links_from_body(body):
    """Returns a list of links, or None when the body is not v2ray-JSON."""
    text = body.strip()
    if not text or text[0] not in "[{":
        return None
    try:
        root = json.loads(text)
    except ValueError:
        return None

    # A single-server subscription may arrive as a bare object.
    if isinstance(root, dict):
        configs = [root]
    elif isinstance(root, list):
        configs = [c for c in root if isinstance(c, dict)]
    else:
        return None
    # JSON with no `outbounds` anywhere is some other format entirely (clash, a
    # panel error page); let the caller keep looking.
    if not any("outbounds" in c for c in configs):
        return None

    links = []
    for config in configs:
        outbounds = config.get("outbounds")
        if not isinstance(outbounds, list):
            continue
        proxy = next((o for o in outbounds
                      if isinstance(o, dict) and o.get("protocol") == "vless"), None)
        if proxy is None:
            continue
        link = outbound_to_vless(proxy, config.get("remarks") or "")
        if link:
            links.append(link)
    return links


def main():
    links = links_from_body(sys.stdin.read())
    if links is None:
        return 1
    sys.stdout.write("".join(link + "\n" for link in links))
    return 0


if __name__ == "__main__":
    sys.exit(main())
