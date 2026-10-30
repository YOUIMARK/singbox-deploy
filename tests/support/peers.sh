#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/policy.sh"

t_peer_add() {
    local type="$1" value area=endpoints file="endpoint-$1.json"
    if [[ "$type" = cloudflared ]]; then area=connectors; file=inbound-cloudflared.json; fi
    value=$(cat "$ROOT/tests/fixtures/$file") || exit 1
    t_run 0 sbd_apply sbd_peer_change "$area" add "$(jq -r .tag <<< "$value")" "$value"
}

t_peer_reserved() {
    python3 - "$SBD_CONFIG" "$1" <<'PY'
import base64, json, sys
c=json.load(open(sys.argv[1]))
value=c["endpoints"][0]["peers"][0]["reserved"]
if isinstance(value,str):
    value=list(base64.b64decode(value,validate=True))
assert value==json.loads(sys.argv[2])
assert "reserved" not in c["endpoints"][0]
PY
}
