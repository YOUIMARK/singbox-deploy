#!/usr/bin/env bash
# 只有指定文件/服务失败边界用窄桩；HTTP 下载、编译、Schema、format/check 都是真实函数。
# shellcheck disable=SC2329,SC2016
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/policy.sh"

local_update() {
    t_policy_seed
    cp "$ROOT/tests/fixtures/rule-set-domains.json" "$CASE_TMP/source.json" || exit 1
    t_policy_local domains "$CASE_TMP/source.json"
    local old new
    old=$(jq -r '.route.rule_set[0].path' "$SBD_CONFIG") || exit 1
    cp "$ROOT/tests/fixtures/rule-set-ips.json" "$CASE_TMP/source.json" || exit 1
    t_run 0 sbd_apply sbd_rule_set update domains
    new=$(jq -r '.route.rule_set[0].path' "$SBD_CONFIG") || exit 1
    t_assert '更新使用新版本路径' test "$old" != "$new"
    t_assert '最近恢复源仍能读取旧文件' test -s "$old"
    t_assert '新文件与核心解析内容一致' jq -e '.version==5 and .rules[0].ip_cidr!=null' "${new%/*}/source.json"
    t_run 0 sbd_apply sbd_resolver_default strategy prefer_ipv4
    t_assert '淘汰旧恢复源后才回收旧材料' test ! -e "${old%/*}"
    t_assert '当前材料仍保留' test -s "$new"
    t_assert '导入的外部源文件不被删除' test -s "$CASE_TMP/source.json"
}
remote_lazy() {
    t_policy_seed
    t_policy_http
    local value
    value=$(jq -n --arg url "https://127.0.0.1:$POLICY_HTTP_PORT/missing.srs" '{type:"remote",tag:"remote",format:"binary",url:$url,update_interval:"1h",http_client:{version:2,domain_resolver:"system"}}') || exit 1
    t_run 0 sbd_apply sbd_rule_set add remote "$value"
    t_assert '4B：check/提交不主动发起远程下载' test ! -e "$CASE_TMP/requests"
    t_assert '不写种子或弃用下载字段，保留显式 HTTP client' jq -e '.route.rule_set[0]|.type=="remote" and (has("initial_path") or has("download_detour")|not) and has("http_client")' "$SBD_CONFIG"
    t_assert '按需设置原生 cache_file' jq -e '.experimental.cache_file.enabled==true and (.experimental.cache_file.path|endswith("/assets/cache.db"))' "$SBD_CONFIG"
    t_assert '配置检查不冒充实际启动缓存' test ! -e "$SBD_ASSET_DIR/cache.db"
    t_assert 'remote 不创建本地规则材料' test ! -e "$SBD_ASSET_DIR/rule-sets"
    t_entry_save
    t_run 1 sbd_apply sbd_rule_set update remote
    t_contains "$CASE_TMP/output" 'update_interval'
    t_entry_unchanged
    t_assert '人工更新入口也不假冒立即刷新' test ! -e "$CASE_TMP/requests"
}
rule_set_references() {
    t_policy_seed
    t_policy_local
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' '{"rule_set":"domains","action":"route","server":"system"}'
    t_entry_save
    t_run 1 sbd_apply sbd_rule_set delete domains
    t_entry_unchanged
    local id
    id=$(t_policy_id dns_rules) || exit 1
    t_run 0 sbd_apply sbd_policy_rule dns_rules delete "$id"
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"type":"logical","mode":"or","rules":[{"rule_set":"domains"}],"action":"route","outbound":"direct"}'
    t_entry_save
    t_run 1 sbd_apply sbd_rule_set delete domains
    t_entry_unchanged
}
drift_contract() {
    t_policy_seed
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"domain":"a.example","action":"reject"}'
    local id
    id=$(t_policy_id route_rules) || exit 1
    t_patch_config '.route.rules[0].domain="manual.example"'
    t_entry_save
    t_run 1 sbd_apply sbd_policy_rule route_rules delete "$id"
    t_contains "$CASE_TMP/output" '漂移'
    t_entry_unchanged
}
server_references() {
    t_policy_seed
    t_policy_udp
    t_run 0 sbd_apply sbd_resolver_default final upstream
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_server delete upstream
    t_entry_unchanged
    t_run 0 sbd_apply sbd_resolver_default final system
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"domain":"example.com","action":"resolve","server":"upstream"}'
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_server delete upstream
    t_entry_unchanged
    t_run 0 sbd_apply sbd_policy_rule route_rules delete "$(t_policy_id route_rules)"
    t_run 0 sbd_apply sbd_resolver_server add doh '{"type":"https","tag":"doh","server":"dns.example.com","domain_resolver":"upstream"}'
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_server delete upstream
    t_entry_unchanged
}
native_actions() {
    t_policy_seed
    local value
    for value in '{"protocol":"tls","action":"sniff"}' '{"domain":"example.com","action":"resolve","server":"system"}' '{"port":53,"action":"hijack-dns"}' '{"network":"udp","action":"reject"}' '{"domain":"example.org","action":"route","outbound":"direct"}'; do
        t_run 0 sbd_apply sbd_policy_rule route_rules add '' "$value"
    done
    t_assert '五种原生动作不创建 block/dns 特殊出口' jq -e '(.route.rules|length==5) and all(.outbounds[]; .type!="block" and .type!="dns")' "$SBD_CONFIG"
}
retirement_failure() {
    t_policy_seed
    t_policy_local
    local old
    old=$(jq -r '.policy.rule_sets[0].directory' "$SBD_REGISTRY") || exit 1
    t_run 0 sbd_apply sbd_rule_set update domains
    rm() {
        if [[ "${!#}" = "$old" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command rm "$@"
    }
    t_run 1 sbd_apply sbd_resolver_default strategy prefer_ipv4
    t_assert '材料收尾错误显形且事实已接受' jq -e '.phase=="accepted"' "$SBD_WORK/active/journal.json"
    t_assert '材料失败不假装已经删除' test -d "$old"
    unset -f rm
    t_run 0 sbd_recover
    t_assert '恢复只重试收尾并回收旧材料' test ! -e "$old"
    t_assert '恢复不回退已提交策略' jq -e '.dns.strategy=="prefer_ipv4"' "$SBD_CONFIG"
}
t_case '本地更新独立路径、最近恢复源和安全淘汰' local_update
t_case 'remote 4B 延迟下载、原生缓存与无伪刷新' remote_lazy
t_case 'DNS/逻辑路由存活引用阻止删除规则集' rule_set_references
t_case '规则漂移拒绝覆盖并保留旧导出' drift_contract
t_case 'DNS 默认项和 bootstrap 存活引用阻止删除' server_references
t_case '原生路由 route/reject/sniff/resolve/hijack-dns' native_actions
t_case '旧规则材料回收失败可重试而不回退已接受事实' retirement_failure
t_finish
