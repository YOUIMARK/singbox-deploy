#!/usr/bin/env bash
# HTTP 端口由 source 本助手的对齐套件消费。
# shellcheck disable=SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/entries.sh"

t_policy_seed() {
    t_seed
    cp "$ROOT/tests/fixtures/base-system.json" "$SBD_CONFIG" || exit 1
    sbd_prepare_config "$SBD_CONFIG_DIR" || exit 1
    cp "$SBD_CONFIG" "$CASE_TMP/old-config" || exit 1
    cp "$SBD_SCHEMA" "$CASE_TMP/old-schema" || exit 1
}

t_policy_local() {
    local tag="${1:-domains}" file="${2:-$ROOT/tests/fixtures/rule-set-domains.json}" value
    value=$(jq -n --arg tag "$tag" --arg path "$file" '{type:"local",tag:$tag,path:$path,format:"source"}') || exit 1
    t_run 0 sbd_apply sbd_rule_set add "$tag" "$value"
}

t_policy_id() { jq -er --arg area "$1" '.policy[$area][-1].id' "$SBD_REGISTRY"; }

t_policy_udp() {
    local tag="${1:-upstream}" value
    value=$(jq -n --arg tag "$tag" '{type:"udp",tag:$tag,server:"192.0.2.53",server_port:53}') || exit 1
    t_run 0 sbd_apply sbd_resolver_server add "$tag" "$value"
}

t_policy_http() {
    python3 - "$CASE_TMP" <<'PY' > "$CASE_TMP/http.log" 2>&1 &
import http.server, pathlib, sys
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with (root / "requests").open("a") as f:
            f.write(self.path + "\n")
        path = root / self.path.lstrip("/").split("?", 1)[0]
        data = path.read_bytes() if path.is_file() else b"not found"
        self.send_response(200 if path.is_file() else 404)
        self.end_headers()
        self.wfile.write(data)
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
(root / "http-port").write_text(str(server.server_port))
server.serve_forever()
PY
    local pid=$! n=0
    # shellcheck disable=SC2064
    trap "kill $pid 2>/dev/null; wait $pid 2>/dev/null || :" EXIT
    while [[ ! -s "$CASE_TMP/http-port" && "$n" -lt 200 ]]; do sleep 0.01; n=$((n+1)); done
    t_assert 'HTTP fixture 真实就绪' test -s "$CASE_TMP/http-port"
    POLICY_HTTP_PORT=$(cat "$CASE_TMP/http-port") || exit 1
}
