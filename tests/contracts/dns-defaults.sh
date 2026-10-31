#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/policy.sh"

fresh_defaults() {
    t_fresh
    t_stopped
    t_run 0 sbd_apply sbd_entry_create "$(cat "$ROOT/tests/fixtures/entry-shadowsocks.json")"
    t_assert '首次创建内置三家直连 DoH、原生 evaluate/respond/race' jq -e '.dns.final=="cloudflare" and (.dns.servers|length==4) and (.dns.rules|length==9) and .dns.rules[0].server=="cloudflare" and .dns.rules[1].server=="quad9" and .dns.rules[2].server=="controld" and all(.dns.rules[3:][];.action=="respond" and .race) and .route.rules[0]=={action:"sniff"} and .route.rules[1]=={protocol:"dns",action:"hijack-dns"} and .route.rules[2]=={action:"resolve"} and .route.rules[3]=={ip_is_private:true,action:"reject"} and (.route.rules|length==4)' "$SBD_CONFIG"
    t_assert 'DoH 使用独立 bootstrap，不关闭证书校验、不套代理' jq -e 'all(.dns.servers[]|select(.type=="https");.domain_resolver=="system" and .tls.enabled and (.tls.insecure // false)==false and (has("detour")|not))' "$SBD_CONFIG"
    t_run 0 sbd_resolver_summary
    t_contains "$CASE_TMP/output" '上游竞速: 开启'
    t_contains "$CASE_TMP/output" 'https://dns.quad9.net/dns-query'
    t_contains "$CASE_TMP/output" 'https://freedns.controld.com/p0'
    t_run 0 sbd_apply sbd_resolver_switch local
    t_assert '新默认切换单上游会关闭本包竞速，不残留截获规则' jq -e '.dns.final=="system" and ((.dns.rules // [])|length==0)' "$SBD_CONFIG"
    t_run 0 sbd_resolver_summary
    t_contains "$CASE_TMP/output" '上游竞速: 关闭'
    t_run 0 sbd_resolver_menu <<< $'9\ny\n0'
    t_contains "$CASE_TMP/output" '上游竞速: 开启'
    t_assert '反复恢复默认不复制上游或规则' jq -e '(.dns.servers|length==4) and (.dns.rules|length==9) and (.route.rules|length==4)' "$SBD_CONFIG"
}
old_config() {
    t_policy_seed
    t_run 0 sbd_apply sbd_observe_change level info
    t_assert '普通管理不会把旧配置自动迁移为默认竞速' jq -e '.dns.final=="system" and ((.dns.rules // [])|length==0)' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' '{"domain":"custom.example","action":"route","server":"system"}'
    t_run 0 sbd_apply sbd_resolver_switch default
    t_assert '旧用户显式恢复默认，保留原有 DNS 规则的优先级' jq -e '.dns.rules[0].domain=="custom.example" and (.dns.rules|length==10) and .route.rules[0].action=="resolve"' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_resolver_switch https://dns.google/dns-query
    t_assert '切回单上游只移除面板竞速组，自定义规则保留' jq -e '.dns.final=="google" and (.dns.rules|length==1) and .dns.rules[0].domain=="custom.example"' "$SBD_CONFIG"
}
custom_race() {
    t_policy_seed
    t_run 0 sbd_resolver_menu <<< $'6\nhttps://dns.alidns.com/dns-query,https://doh.pub/dns-query\ny\n0'
    t_assert '多地址一次提交固定 tag 与两路竞速，无内部字段提问' jq -e '.dns.final=="alidns" and (.dns.rules|length==6) and .dns.rules[0].server=="alidns" and .dns.rules[1].server=="dnspod" and .route.rules[0].action=="resolve"' "$SBD_CONFIG"
    t_absent "$CASE_TMP/output" '上游数量'
    t_absent "$CASE_TMP/output" 'evaluate tag'
    t_run 0 sbd_apply sbd_resolver_switch default
    t_run 0 sbd_apply sbd_resolver_switch default
    t_assert '多路切换与反复恢复不会积累竞速规则' jq -e '(.dns.rules|length==9) and (.route.rules|length==1)' "$SBD_CONFIG"
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_switch 'https://dns.google/dns-query,https://dns.google/dns-query'
    t_entry_unchanged
}
race_failure() {
    t_policy_seed
    t_entry_save
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_apply sbd_resolver_switch default
    t_assert '默认竞速仍到达 state 提交边界' test -e "$CASE_TMP/failed"
    t_entry_unchanged
}
native_race() {
    t_assert '真实 SOCKS 域名转发走三路竞速，最快上游失联时仍使用其余响应' python3 "$ROOT/tests/support/dns_race.py" "$SBD_TEST_BIN" "$ROOT/presets/base.json"
}
t_case '新配置默认 DoH 竞速、代理目标接入和单上游切换' fresh_defaults
t_case '旧配置不静默迁移，显式恢复默认保留自定义规则' old_config
t_case '自定义多个地址自动竞速、重复拒绝和幂等切换' custom_race
t_case '默认 DNS 组配置与 state 提交失败完整回滚' race_failure
t_case '真实核心竞速、对照绕过和最快上游失联回退' native_race
t_finish
