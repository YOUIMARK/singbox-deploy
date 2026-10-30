#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/policy.sh"

cancel_contract() {
    t_fresh
    t_run 0 sbd_resolver_menu <<< 0
    t_run 0 sbd_resolver_menu < /dev/null
    t_run 2 sbd_resolver_server_prompt <<< $'2\nupstream\n192.0.2.53'
    t_assert 'EOF 不创建配置' test ! -e "$SBD_CONFIG"
}
typed_contract() {
    t_policy_seed
    local type value tag
    for type in local udp tcp tls https quic; do
        tag="test-$type"
        value=$(jq -n --arg type "$type" --arg tag "$tag" '{type:$type,tag:$tag} + (if $type!="local" then {server:"192.0.2.53",server_port:853} else {} end) + (if $type=="tls" or $type=="https" or $type=="quic" then {tls:{enabled:true,server_name:"dns.example.com"}} else {} end) + (if $type=="https" then {path:"/dns-query"} else {} end)') || exit 1
        t_run 0 sbd_apply sbd_resolver_server add "$tag" "$value"
    done
    t_assert '六种 typed 上游均存在且不写 address 旧字段' jq -e '.dns.servers|length==7 and all(.[];has("address")|not)' "$SBD_CONFIG"
}
bootstrap_contract() {
    t_policy_seed
    t_run 0 sbd_apply sbd_resolver_server add doh '{"type":"https","tag":"doh","server":"dns.example.com","domain_resolver":"system","tls":{"enabled":true,"server_name":"dns.example.com"}}'
    t_run 0 sbd_apply sbd_resolver_default final doh
    t_run 0 sbd_apply sbd_resolver_default resolver doh
    t_run 0 sbd_apply sbd_resolver_default strategy ipv4_only
    t_assert 'DNS final、拨号解析器与全局策略是原生独立项' jq -e '.dns.final=="doh" and .route.default_domain_resolver=="doh" and .dns.strategy=="ipv4_only" and .dns.servers[1].domain_resolver=="system"' "$SBD_CONFIG"
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_server replace doh '{"type":"https","tag":"doh","server":"dns.example.com","domain_resolver":"doh"}'
    t_contains "$CASE_TMP/output" '循环'
    t_entry_unchanged
}
dns_rules_contract() {
    t_policy_seed
    t_policy_udp
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' '{"domain_suffix":["example.com"],"action":"route","server":"upstream"}'
    t_assert '域名 DNS 分流在 dns.rules 而非 route.rules' jq -e '.dns.rules[0].server=="upstream" and ((.route.rules // [])|length==0)' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' '{"action":"evaluate","server":"upstream","tag":"answer"}'
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' '{"match_response":"answer","ip_cidr":["192.0.2.0/24"],"action":"respond"}'
    t_assert '响应 IP 使用新 evaluate/match_response' jq -e '.dns.rules[2].match_response=="answer" and .dns.rules[2].action=="respond"' "$SBD_CONFIG"
}
race_contract() {
    t_policy_seed
    t_policy_udp
    t_run 0 sbd_apply sbd_resolver_race '["system","upstream"]' '{"domain_suffix":["example.com"]}'
    t_assert '原生两个 evaluate 和两个 respond/race，不添加 Xray 布尔开关' jq -e '(.dns|has("enableParallelQuery")|not) and (.dns.rules|length==4) and .dns.rules[0].action=="evaluate" and .dns.rules[1].action=="evaluate" and .dns.rules[2].action=="respond" and .dns.rules[2].race==true and .dns.rules[3].race==true' "$SBD_CONFIG"
    t_assert '竞速不偷偷改变默认上游' jq -e '.dns.final=="system"' "$SBD_CONFIG"
    t_assert '组 ID 只在管理记录中保存' jq -e '.policy.dns_rules|length==4 and ([.[].group]|unique|length==1)' "$SBD_REGISTRY"
    local group request
    group=$(jq -r '.policy.dns_rules[0].group' "$SBD_REGISTRY") || exit 1
    request=$(jq -n --arg group "$group" '{area:"dns_rules",action:"delete_group",id:$group}') || exit 1
    t_run 0 sbd_apply sbd_policy_edit "$request"
    t_assert '竞速组完整删除' jq -e '(.dns.rules // [])==[]' "$SBD_CONFIG"
}
server_prompt_contract() {
    t_policy_seed
    sbd_resolver_server_prompt > "$CASE_TMP/prompt" 2>&1 <<< $'5\ndoh\nbad/path\ndns.example.com\n00443\n1\n\n\n\n' || exit 1
    t_assert '上游域名错误只重问，SNI/DoH/端口默认正常' jq -e '.type=="https" and .tag=="doh" and .server=="dns.example.com" and .server_port==443 and .domain_resolver=="system" and .tls.server_name=="dns.example.com" and .path=="/dns-query"' <<< "$SBD_POLICY_VALUE"
    t_run 0 sbd_apply sbd_resolver_server add doh "$SBD_POLICY_VALUE"
}
bootstrap_detour_cycle() {
    t_policy_seed
    t_policy_udp
    jq '.outbounds += [{type:"socks",tag:"bootstrap-proxy",server:"proxy.example.com",server_port:1080,domain_resolver:"upstream"}]' "$SBD_CONFIG" > "$CASE_TMP/outbound" || exit 1
    cp "$CASE_TMP/outbound" "$SBD_CONFIG" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_server replace upstream '{"type":"udp","tag":"upstream","server":"192.0.2.53","detour":"bootstrap-proxy"}'
    t_contains "$CASE_TMP/output" '循环'
    t_entry_unchanged
}
t_case 'DNS 菜单退出、EOF 无副作用' cancel_contract
t_case '六种新格式 DNS 上游真实 Schema/check' typed_contract
t_case '域名 bootstrap、默认策略与循环拒绝' bootstrap_contract
t_case 'DNS 查询分流和响应 IP 原生规则' dns_rules_contract
t_case '原生 DNS 竞速组与整体删除' race_contract
t_case 'DoH 字段重问和明确 bootstrap 向导' server_prompt_contract
t_case 'DNS 经出站拨号的 bootstrap 环路拒绝提交' bootstrap_detour_cycle
t_finish
