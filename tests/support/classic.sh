#!/usr/bin/env bash

t_classic_uri() {
    python3 - "$SBD_REGISTRY" "$SBD_EXPORTS/$NODE_ID.txt" "$NODE_ID" <<'PY'
import base64, json, sys
from urllib.parse import urlsplit, unquote, parse_qs
node = next(n for n in json.load(open(sys.argv[1]))["nodes"] if n["id"] == sys.argv[3])
c = node["client"]
u = urlsplit(open(sys.argv[2]).read().strip())
q = parse_qs(u.query, keep_blank_values=True)
assert u.hostname == c["server"] and u.port == c["server_port"]
assert unquote(u.fragment) == node["name"] and u.path == ""
if node["profile"] == "shadowsocks":
    assert u.scheme == "ss" and not q
    info = u.netloc.rsplit("@", 1)[0]
    if c["method"].startswith("2022-"):
        method, password = map(unquote, info.split(":", 1))
    else:
        assert "=" not in info and "+" not in info and "/" not in info
        method, password = base64.urlsafe_b64decode(info + "=" * (-len(info) % 4)).decode().split(":", 1)
    assert method == c["method"] and password == c["password"]
else:
    assert unquote(u.username) == c["uuid"] and "password" not in c
    assert q["sni"] == [c["tls"]["server_name"]]
    assert not any(k in q for k in ("aid", "alterId", "alter_id", "private_key"))
    if node["profile"].endswith("_ws"):
        assert u.scheme == c["type"] and q["type"] == ["ws"] and q["security"] == ["tls"]
        assert q["path"] == [c["transport"]["path"]] and q["host"] == [node["ingress"]["host"]]
        assert q["encryption"] == ["auto" if u.scheme == "vmess" else "none"]
        assert "flow" not in q and "ed" not in q
    else:
        assert u.scheme == "vless" and q["security"] == ["reality"] and q["type"] == ["tcp"]
        assert q["flow"] == ["xtls-rprx-vision"] and q["fp"] == ["chrome"]
        assert q["pbk"] == [c["tls"]["reality"]["public_key"]]
        assert q["sid"] == [c["tls"]["reality"]["short_id"]]
        assert "transport" not in c
assert "null" not in open(sys.argv[2]).read()
PY
}
