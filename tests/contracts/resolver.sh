#!/usr/bin/env bash
# shellcheck disable=SC2016
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/policy.sh"

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
    t_run 0 sbd_apply sbd_resolver_switch 'local,https://dns.example.com/dns-query'
    t_assert '多上游切换生成原生 evaluate 与 NOERROR/NXDOMAIN 竞速' jq -e '
        (.dns.rules|length==6)
        and ([.dns.rules[]|select(.action=="evaluate")]|length==2)
        and ([.dns.rules[]|select(.action=="respond" and .race==true)]|length==4)
        and ([.dns.rules[]|select(.action=="respond" and .response_rcode=="NOERROR")]|length==2)
        and ([.dns.rules[]|select(.action=="respond" and .response_rcode=="NXDOMAIN")]|length==2)
    ' "$SBD_CONFIG"
    t_assert '首个选中上游成为默认 DNS，并补上原生 resolve 动作' jq -e '.dns.final=="system" and .route.default_domain_resolver=="system" and .route.rules[0].action=="resolve"' "$SBD_CONFIG"
    t_assert '竞速组 ID 只在管理记录中保存' jq -e '.policy.dns_rules|length==6 and ([.[].group]|unique)==["dns.default.race"]' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_policy_edit '{"area":"dns_rules","action":"delete_group","id":"dns.default.race"}'
    t_assert '竞速组完整删除' jq -e '(.dns.rules // [])==[]' "$SBD_CONFIG"
}
t_case '六种新格式 DNS 上游真实 Schema/check' typed_contract
t_case '域名 bootstrap、默认策略与循环拒绝' bootstrap_contract
t_case 'DNS 查询分流和响应 IP 原生规则' dns_rules_contract
t_case '多上游切换生成原生竞速组与整体删除' race_contract
t_finish
