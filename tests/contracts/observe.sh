#!/usr/bin/env bash
# 服务后端只由日志生产函数间接调用。
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/policy.sh"

cancel_contract() {
    t_fresh
    t_run 0 sbd_observe_menu <<< 0
    t_run 0 sbd_observe_menu < /dev/null
    t_run 2 sbd_observe_menu <<< $'2\n9090'
    t_assert '取消不创建配置' test ! -e "$SBD_CONFIG"
}
api_contract() {
    t_policy_seed
    t_run 0 sbd_apply sbd_observe_change api '{"port":"009090","secret":"secret-special+/@"}'
    t_assert 'API 只监听 loopback，带 secret，不下载面板' jq -e '.experimental.clash_api|.external_controller=="127.0.0.1:9090" and .secret=="secret-special+/@" and (has("external_ui")|not)' "$SBD_CONFIG"
    t_run 0 sbd_observe_menu <<< $'1\n0'
    t_absent "$CASE_TMP/output" secret-special
    t_run 0 sbd_apply sbd_observe_change api_off
    t_assert '空 controller 为原生禁用' jq -e '(.experimental.clash_api.external_controller // "")==""' "$SBD_CONFIG"
    t_entry_save
    t_run 1 sbd_apply sbd_observe_change api '{"port":9090,"secret":""}'
    t_entry_unchanged
}
cache_log_contract() {
    t_policy_seed
    printf 'opaque native DB fixture\n' > "$SBD_DATA/cache.db" || exit 1
    t_run 0 sbd_apply sbd_observe_change cache_on
    t_run 0 sbd_apply sbd_observe_change dns_cache true
    t_assert '使用原生新缓存字段，不用 rdrc' jq -e '.experimental.cache_file|.enabled and .store_dns and (has("store_rdrc") or has("rdrc_timeout")|not)' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_observe_change cache_off
    t_contains "$SBD_DATA/cache.db" 'opaque native'
    t_run 0 sbd_apply sbd_observe_change level debug
    t_run 0 sbd_apply sbd_observe_change log_off
    t_assert '关闭用 disabled，不造 none level' jq -e '.log.disabled and .log.level=="debug"' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_observe_change log_service
    t_assert '服务日志不留下 output' jq -e '(.log.disabled // false)==false and (.log|has("output")|not)' "$SBD_CONFIG"
}
api_fixture() {
    t_policy_seed
    python3 - "$CASE_TMP" <<'PY' > "$CASE_TMP/http.log" 2>&1 &
import http.server,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get('Authorization')!='Bearer fixture-secret':
            self.send_response(401); self.end_headers(); return
        self.send_response(200); self.end_headers()
        if self.path=='/traffic': data={'up':12,'down':34}
        else: data={'uploadTotal':100,'downloadTotal':200,'connections':[{'id':'c1','upload':5,'download':8,'start':'now','metadata':{'secret':'not-to-show'}}]}
        self.wfile.write((json.dumps(data)+'\n').encode())
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
(root/'port').write_text(str(server.server_port)); server.serve_forever()
PY
    local pid=$! n=0 value
    # shellcheck disable=SC2064
    trap "kill $pid 2>/dev/null; wait $pid 2>/dev/null || :" EXIT
    while [[ ! -s "$CASE_TMP/port" && "$n" -lt 200 ]]; do sleep 0.01; n=$((n+1)); done
    t_assert '真实 HTTP fixture 启动' test -s "$CASE_TMP/port"
    value=$(jq -n --argjson port "$(cat "$CASE_TMP/port")" '{port:$port,secret:"fixture-secret"}') || exit 1
    t_run 0 sbd_apply sbd_observe_change api "$value"
    t_run 0 sbd_observe_query traffic
    t_assert '流量采样解析真实 HTTP' jq -e '.up==12 and .down==34' "$CASE_TMP/output"
    t_run 0 sbd_observe_query connections
    t_assert '连接概要保留计数' jq -e '.uploadTotal==100 and .connections[0].id=="c1"' "$CASE_TMP/output"
    t_absent "$CASE_TMP/output" not-to-show
    value=$(jq '.secret="wrong"' <<< "$value") || exit 1
    t_run 0 sbd_apply sbd_observe_change api "$value"
    t_run 1 sbd_observe_query connections
    t_absent "$CASE_TMP/output" fixture-secret
    t_run 1 sbd_observe_query unsupported
}
log_contract() {
    t_policy_seed
    sbd_backend() { printf 'openrc\n'; }
    t_run 1 sbd_observe_logs
    printf 'native-log-fixture\n' > "$SBD_LOG" || exit 1
    t_run 0 sbd_observe_logs
    t_contains "$CASE_TMP/output" "$SBD_LOG"
    t_contains "$CASE_TMP/output" native-log-fixture
}
t_case '观测菜单 EOF/取消无副作用' cancel_contract
t_case '原生 API loopback/secret 设置与禁用' api_contract
t_case '原生缓存及日志开关不删除缓存 DB' cache_log_contract
t_case '原生 API HTTP 样本、鉴权失败和秘密不回显' api_fixture
t_case '日志路径事实与缺失失败' log_contract
t_finish
