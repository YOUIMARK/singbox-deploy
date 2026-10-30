#!/usr/bin/env bash

t_entry_add() {
    local profile="$1" spec
    spec=$(cat "$ROOT/tests/fixtures/entry-$profile.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    NODE_ID=$(jq -r '.nodes[-1].id' "$SBD_REGISTRY") || exit 1
}

t_entry_save() {
    local key
    ENTRY_SAVED=$(mktemp -d "$CASE_TMP/saved.XXXXXX") || exit 1
    for key in config schema state registry; do
        cp "$(sbd_resource_path "$key")" "$ENTRY_SAVED/$key" || exit 1
    done
    cp -a "$SBD_EXPORTS" "$ENTRY_SAVED/exports" || exit 1
}

t_entry_unchanged() {
    local key
    for key in config schema state registry; do
        t_assert "$key 保留原字节" cmp -s "$(sbd_resource_path "$key")" "$ENTRY_SAVED/$key"
    done
    t_assert '全部导出保留原字节' sbd_tree_compare "$ENTRY_SAVED/exports" "$SBD_EXPORTS"
}

t_entry_uri() {
    python3 - "$SBD_REGISTRY" "$SBD_EXPORTS/$NODE_ID.txt" "$1" <<'PY'
import hashlib, json, ssl, sys
from urllib.parse import urlsplit, unquote, parse_qs
node = json.load(open(sys.argv[1]))["nodes"][-1]
u = urlsplit(open(sys.argv[2]).read().strip())
q = parse_qs(u.query, keep_blank_values=True)
assert u.hostname == node["client"]["server"]
assert u.port == node["client"]["server_port"]
assert unquote(u.username) == node["client"]["password"]
assert unquote(u.fragment) == node["name"]
assert q["sni"] == [node["client"]["tls"]["server_name"]]
assert "1" not in q.get("insecure", [])
profile = sys.argv[3]
if profile == "anyreality":
    assert u.scheme == "anytls" and q["security"] == ["reality"] and q["fp"] == ["chrome"]
    assert q["pbk"] == [node["client"]["tls"]["reality"]["public_key"]]
    assert q["sid"] == [node["client"]["tls"]["reality"]["short_id"]]
    assert not any(k in q for k in ("uuid", "flow", "private_key"))
else:
    assert u.scheme == ("hysteria2" if profile == "hysteria2" else "anytls")
    cert_id = node["certificate_id"]
    registry = json.load(open(sys.argv[1]))
    cert = next(x for x in registry["tls"]["certificates"] if x["id"] == cert_id)
    der = ssl.PEM_cert_to_DER_cert(open(cert["certificate_path"]).read())
    sha = hashlib.sha256(der).hexdigest()
    assert q["pinSHA256" if profile == "hysteria2" else "pcs"] == [sha]
    assert sha != cert["public_key_sha256"]
if profile == "hysteria2":
    assert not any(k in q for k in ("up", "down", "up_mbps", "down_mbps", "congestion", "bbr_profile"))
    obfs = node["client"].get("obfs")
    if obfs:
        assert q["obfs"] == [obfs["type"]] and q["obfs-password"] == [obfs["password"]]
        if obfs["type"] == "gecko":
            assert q["minPacketSize"] == [str(obfs.get("min_packet_size", 512))]
            assert q["maxPacketSize"] == [str(obfs.get("max_packet_size", 1200))]
PY
}
