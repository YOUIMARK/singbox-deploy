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
bad_update() {
    t_policy_seed
    cp "$ROOT/tests/fixtures/rule-set-domains.json" "$CASE_TMP/source.json" || exit 1
    t_policy_local domains "$CASE_TMP/source.json"
    t_entry_save
    printf 'bad source' > "$CASE_TMP/source.json" || exit 1
    t_run 1 sbd_apply sbd_rule_set update domains
    t_entry_unchanged
    t_assert '更新失败只保留原有材料' test "$(find "$SBD_DATA/rule-sets" -mindepth 1 -maxdepth 1 -type d | wc -l)" = 1
    t_contains "$CASE_TMP/source.json" 'bad source'
}
local_download() {
    t_policy_seed
    t_policy_http
    cp "$ROOT/tests/fixtures/rule-set-domains.json" "$CASE_TMP/source.json" || exit 1
    local value origin
    value='{"type":"local","tag":"downloaded"}'
    origin=$(jq -n --arg url "http://127.0.0.1:$POLICY_HTTP_PORT/source.json" '{kind:"url",value:$url,format:"source"}') || exit 1
    t_run 0 sbd_apply sbd_rule_set add downloaded "$value" "$origin"
    t_run 0 sbd_apply sbd_rule_set update downloaded
    t_assert '人工添加/更新真实下载两次' test "$(wc -l < "$CASE_TMP/requests")" = 2
    t_entry_save
    origin=$(jq '.value += ".missing"' <<< "$origin") || exit 1
    t_run 1 sbd_apply sbd_rule_set replace downloaded "$value" "$origin"
    t_entry_unchanged
}
remote_lazy() {
    t_policy_seed
    t_policy_http
    local value
    value=$(jq -n --arg url "http://127.0.0.1:$POLICY_HTTP_PORT/missing.srs" '{type:"remote",tag:"remote",format:"binary",url:$url,update_interval:"1h",http_client:{version:2,domain_resolver:"system"}}') || exit 1
    t_run 0 sbd_apply sbd_rule_set add remote "$value"
    t_assert '4B：check/提交不主动发起远程下载' test ! -e "$CASE_TMP/requests"
    t_assert '不写种子或弃用下载字段，保留显式 HTTP client' jq -e '.route.rule_set[0]|.type=="remote" and (has("initial_path") or has("download_detour")|not) and has("http_client")' "$SBD_CONFIG"
    t_assert '按需设置原生 cache_file' jq -e '.experimental.cache_file.enabled==true and (.experimental.cache_file.path|endswith("/data/cache.db"))' "$SBD_CONFIG"
    t_assert '配置检查不冒充实际启动缓存' test ! -e "$SBD_DATA/cache.db"
    t_assert 'remote 不创建本地规则材料' test ! -e "$SBD_DATA/rule-sets"
    t_entry_save
    t_run 1 sbd_apply sbd_rule_set update remote
    t_contains "$CASE_TMP/output" 'update_interval'
    t_entry_unchanged
    t_assert '人工更新入口也不假冒立即刷新' test ! -e "$CASE_TMP/requests"
}
cache_preservation() {
    t_policy_seed
    local content
    content=$(jq --arg path "$CASE_TMP/custom.db" '.experimental.cache_file={enabled:false,path:$path,cache_id:"custom"}' "$SBD_CONFIG") || exit 1
    printf '%s\n' "$content" > "$SBD_CONFIG" || exit 1
    t_run 0 sbd_apply sbd_rule_set add remote '{"type":"remote","tag":"remote","format":"binary","url":"https://example.com/a.srs"}'
    t_assert '已有 cache 关闭选择和字段不被覆盖' jq -e '(.experimental.cache_file.enabled // false)==false and .experimental.cache_file.cache_id=="custom" and (.experimental.cache_file.path|endswith("custom.db"))' "$SBD_CONFIG"
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
shared_ip_set() {
    t_policy_seed
    t_policy_local ips "$ROOT/tests/fixtures/rule-set-ips.json"
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"rule_set":"ips","action":"route","outbound":"direct"}'
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' '{"action":"evaluate","server":"system","tag":"answer"}'
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' '{"match_response":"answer","rule_set":"ips","action":"respond"}'
    t_assert 'route 与 DNS 响应匹配引用同一个原生 rule_set' jq -e '.route.rule_set|length==1' "$SBD_CONFIG"
    t_run 0 sbd_check_config
}
reorder_preserve() {
    t_policy_seed
    jq '.route.rules=[{protocol:"bittorrent",action:"reject"},{network:"udp",action:"route",outbound:"direct"}]' "$SBD_CONFIG" > "$CASE_TMP/custom" || exit 1
    cp "$CASE_TMP/custom" "$SBD_CONFIG" || exit 1
    sbd_prepare_config "$SBD_CONFIG_DIR" || exit 1
    jq '.route.rules' "$SBD_CONFIG" > "$CASE_TMP/custom-rules" || exit 1
    local a b
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"domain":"a.example","action":"reject"}' 0
    a=$(t_policy_id route_rules) || exit 1
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"domain":"b.example","action":"reject"}' 2
    b=$(t_policy_id route_rules) || exit 1
    t_run 0 sbd_apply sbd_policy_rule route_rules move "$b" '{}' 1
    t_run 0 sbd_apply sbd_policy_rule route_rules delete "$a"
    t_assert '规则 ID 和位置随插入/移动/删除同步' jq -e --arg id "$b" '.policy.route_rules|length==1 and .[0].id==$id and .[0].index==0' "$SBD_REGISTRY"
    t_assert '未托管规则保留原始次序和值' jq -e --slurpfile old "$CASE_TMP/custom-rules" '.route.rules[1:] == $old[0]' "$SBD_CONFIG"
}
drift_contract() {
    t_policy_seed
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"domain":"a.example","action":"reject"}'
    local id
    id=$(t_policy_id route_rules) || exit 1
    jq '.route.rules[0].domain="manual.example"' "$SBD_CONFIG" > "$CASE_TMP/drift" || exit 1
    cp "$CASE_TMP/drift" "$SBD_CONFIG" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_policy_rule route_rules delete "$id"
    t_contains "$CASE_TMP/output" '漂移'
    t_entry_unchanged
}
unmanaged_contract() {
    t_policy_seed
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_server replace system '{"type":"local","tag":"system"}'
    t_contains "$CASE_TMP/output" '显式接管'
    t_entry_unchanged
    t_run 1 sbd_apply sbd_resolver_server add system '{"type":"local","tag":"system"}'
    t_contains "$CASE_TMP/output" '占用'
    t_entry_unchanged
}
missing_reference() {
    t_policy_seed
    t_run 1 sbd_apply sbd_policy_rule route_rules add '' '{"domain":"a.example","action":"route","outbound":"not-found"}'
    t_contains "$CASE_TMP/output" '引用不存在'
    t_unchanged
    t_run 1 sbd_apply sbd_resolver_default final not-found
    t_unchanged
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
http_references() {
    t_policy_seed
    t_policy_udp
    t_run 0 sbd_apply sbd_rule_set add remote '{"type":"remote","tag":"remote","format":"binary","url":"https://example.com/a.srs","http_client":{"version":2,"domain_resolver":"upstream"}}'
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_server delete upstream
    t_entry_unchanged
}
dns_order_contract() {
    t_policy_seed
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' '{"action":"evaluate","tag":"answer","server":"system"}'
    local id
    id=$(t_policy_id dns_rules) || exit 1
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' '{"action":"respond","match_response":"answer"}'
    t_entry_save
    t_run 1 sbd_apply sbd_policy_rule dns_rules delete "$id"
    t_entry_unchanged
    t_run 1 sbd_apply sbd_policy_rule dns_rules move "$id" '{}' 1
    t_entry_unchanged
}
node_dns_reference() {
    t_policy_seed
    t_entry_add vless_ws
    local value
    value=$(jq -n --arg id "$NODE_ID" '{inbound:$id,action:"route",server:"system"}') || exit 1
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' "$value"
    t_entry_save
    t_run 1 sbd_apply sbd_entry_change "$NODE_ID" delete ''
    t_contains "$CASE_TMP/output" '仍被路由'
    t_entry_unchanged
}
running_contract() {
    t_policy_seed
    sbd_service_state() { printf 'running\n'; }
    sbd_service_restore() { printf '%s\n' "$1" >> "$CASE_TMP/service-actions"; }
    t_policy_local
    t_contains "$CASE_TMP/service-actions" running
    local old count
    old=$(jq -r '.route.rule_set[0].path' "$SBD_CONFIG") || exit 1
    count=$(wc -l < "$CASE_TMP/service-actions") || exit 1
    t_run 0 sbd_apply sbd_rule_set update domains
    t_assert '独立新路径更新会按需重启运行中核心' test "$(wc -l < "$CASE_TMP/service-actions")" = "$((count+1))"
    t_assert '更新不提前覆盖旧内容' test -s "$old"
}
state_failure() {
    t_policy_seed
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_policy_local_failure() {
        local value
        value=$(jq -n --arg path "$ROOT/tests/fixtures/rule-set-domains.json" '{type:"local",tag:"domains",path:$path,format:"source"}') || return 1
        sbd_rule_set "$1" add domains "$value"
    }
    t_run 1 sbd_apply t_policy_local_failure
    t_assert '到达 state 提交边界' test -f "$CASE_TMP/failed"
    t_unchanged
    t_assert 'state 失败回收新规则文件' test -z "$(find "$SBD_DATA/rule-sets" -mindepth 1 -maxdepth 1 -type d)"
}
kill_recovery() {
    t_policy_seed
    local value
    value=$(jq -n --arg path "$ROOT/tests/fixtures/rule-set-domains.json" '{type:"local",tag:"domains",path:$path,format:"source"}') || exit 1
    mv() { if [[ "${!#}" = "$SBD_STATE" ]]; then kill -KILL "$BASHPID"; fi; command mv "$@"; }
    t_run 137 sbd_apply sbd_rule_set add domains "$value"
    t_assert '强杀前候选配置已发布' jq -e '.route.rule_set|length==1' "$SBD_CONFIG"
    unset -f mv
    t_run 0 sbd_recover
    t_unchanged
    t_assert '强杀恢复回收新规则材料' test -z "$(find "$SBD_DATA/rule-sets" -mindepth 1 -maxdepth 1 -type d)"
}
menus_contract() {
    t_policy_seed
    t_run 0 sbd_rules_menu <<< "$(printf '2\n1\nmenu-set\n1\n%s\ny\n0\n' "$ROOT/tests/fixtures/rule-set-domains.json")"
    t_run 0 sbd_resolver_advanced_menu <<< $'2\n2\nmenu-dns\n192.0.2.53\n\n\ny\n0'
    t_run 0 sbd_policy_rules_menu route_rules <<< $'2\n2\nexample.com\n1\n1\n\ny\n0'
    t_run 0 sbd_policy_rules_menu dns_rules <<< $'2\n2\nexample.com\n1\n2\n\ny\n0'
    t_run 0 sbd_resolver_advanced_menu <<< $'7\n8\n2\n1\n2\n\ny\n0'
    t_assert '编号菜单提交了真实 DNS 竞速和路由' jq -e '(.route.rules|length==1) and (.dns.rules|length==5) and .dns.rules[0].server=="menu-dns"' "$SBD_CONFIG"
}
advanced_menu() {
    t_policy_seed
    t_run 0 sbd_policy_rules_menu route_rules <<< "$(printf '3\n%s\n\ny\n0\n' "$ROOT/tests/fixtures/route-policy.json")"
    t_assert '高级原生文件经真实菜单提交' jq -e '.route.rules[0].outbound=="direct"' "$SBD_CONFIG"
    sbd_policy_duration_prompt > "$CASE_TMP/prompt" 2>&1 <<< $'not-a-duration\n12h' || exit 1
    t_assert 'duration 由核心解析，错误只重问该字段' test "$SBD_REPLY" = 12h
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
remote_activation_failure() {
    t_policy_seed
    sbd_service_state() { printf 'running\n'; }
    sbd_service_restore() {
        if [[ ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; _error '模拟首次远端获取导致启动失败'; return 1; fi
    }
    t_run 1 sbd_apply sbd_rule_set add remote '{"type":"remote","tag":"remote","url":"https://example.com/a.srs","format":"binary"}'
    t_assert '到达服务激活边界' test -f "$CASE_TMP/failed"
    t_unchanged
    t_absent "$CASE_TMP/output" '[成功]'
}
wizard_replace() {
    t_policy_seed
    t_policy_udp
    t_run 0 sbd_resolver_advanced_menu <<< $'9\n1\n3\n192.0.2.54\n\n\ny\n0'
    t_assert '上游向导修改保留 tag' jq -e '.dns.servers[1]|.tag=="upstream" and .type=="tcp" and .server=="192.0.2.54"' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"domain":"before.example","action":"route","outbound":"direct"}'
    local id
    id=$(t_policy_id route_rules) || exit 1
    t_run 0 sbd_policy_rules_menu route_rules <<< $'7\n1\n2\nafter.example\n2\ny\n0'
    t_assert '规则向导替换保留管理 ID' test "$(t_policy_id route_rules)" = "$id"
    t_assert '规则向导替换为选定原生动作' jq -e '.route.rules[0]|.domain_suffix=="after.example" and .action=="reject"' "$SBD_CONFIG"
}
t_case '本地更新独立路径、最近恢复源和安全淘汰' local_update
t_case '坏源更新保留活跃文件且不回滚外部文件' bad_update
t_case '人工 URL 添加/更新真实下载与失败回滚' local_download
t_case 'remote 4B 延迟下载、原生缓存与无伪刷新' remote_lazy
t_case 'remote 保留已有原生 cache_file 选择' cache_preservation
t_case 'DNS/逻辑路由存活引用阻止删除规则集' rule_set_references
t_case '同一 IP 规则集用于路由与新版 DNS 响应匹配' shared_ip_set
t_case '规则插入/移动/删除保持稳定关联及自定义规则' reorder_preserve
t_case '规则漂移拒绝覆盖并保留旧导出' drift_contract
t_case '不自动接管自定义上游或覆盖已有 tag' unmanaged_contract
t_case '跨对象引用失败不冒充 native check 完整验证' missing_reference
t_case 'DNS 默认项和 bootstrap 存活引用阻止删除' server_references
t_case 'remote HTTP client 的 DNS 引用阻止悬空' http_references
t_case 'evaluate/respond 删除和重排维护原生顺序依赖' dns_order_contract
t_case 'DNS inbound 引用也阻止删除托管节点' node_dns_reference
t_case '运行中本地规则集新路径变更按需重启' running_contract
t_case '规则集 state 写失败恢复配置和新材料' state_failure
t_case '规则集发布后 SIGKILL 可恢复全部旧事实' kill_recovery
t_case '规则/DNS/竞速完整编号菜单真实提交' menus_contract
t_case '高级 JSON 菜单与核心 duration 字段重问' advanced_menu
t_case '原生路由 route/reject/sniff/resolve/hijack-dns' native_actions
t_case '旧规则材料回收失败可重试而不回退已接受事实' retirement_failure
t_case 'remote 激活失败不假报成功并恢复完整旧版本' remote_activation_failure
t_case '常用向导替换上游和规则保留原生/管理标识' wizard_replace
t_finish
