#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/policy.sh"

address_parser() {
    t_fresh
    local address
    for address in local 1.1.1.1 2001:db8::53 udp://1.1.1.1 tcp://dns.example.com:5353 tls://dns.example.com quic://dns.example.com https://cloudflare-dns.com 'https://[2001:db8::53]:8443/custom-path'; do
        t_run 0 python3 "$SBD_APP/support/dns_settings.py" parse "$address"
    done
    t_run 0 python3 "$SBD_APP/support/dns_settings.py" parse 'https://[2001:db8::53]:08443/custom-path'
    t_assert 'IPv6 URL、前导零端口与自定义 path 正确拆分' jq -e '.server=="2001:db8::53" and .server_port==8443 and .path=="/custom-path" and .tls=={enabled:true,server_name:"2001:db8::53"}' "$CASE_TMP/output"
    for address in '' 'bad/path' 'https://user:pass@dns.example.com' 'https://dns.example.com:' 'https://dns.example.com:0' 'https://dns.example.com:65536' 'https://dns.example.com?a=b' 'https://dns.example.com#fragment' 'tls://dns.example.com/wrong-path' 'http://dns.example.com' 'https://2001:db8::1' 'https://dns.example.com bad' $'dns.example.com\033[2J'; do
        t_run 1 python3 "$SBD_APP/support/dns_settings.py" parse "$address"
        t_contains "$CASE_TMP/output" '[错误]'
    done
}
presets_and_reuse() {
    t_policy_seed
    local address tag
    while read -r address tag; do
        t_run 0 sbd_apply sbd_resolver_switch "$address"
        t_run 0 sbd_check_config
        t_assert '查询与拨号 DNS 默认指向同一个实际对象' jq -e '.dns.final==.route.default_domain_resolver and (.dns.final as $tag|any(.dns.servers[];.tag==$tag))' "$SBD_CONFIG"
        t_assert '预设默认 tag 固定且可读' test "$(jq -r '.dns.final' "$SBD_CONFIG")" = "$tag"
    done <<'PRESETS'
https://dns.alidns.com/dns-query alidns
https://doh.pub/dns-query dnspod
https://1.1.1.1/dns-query cloudflare
https://dns.google/dns-query google
local system
PRESETS
    local count
    count=$(jq '.dns.servers|length' "$SBD_CONFIG") || exit 1
    t_assert '默认本地 resolver 被复用' test "$count" = 5
    t_run 0 sbd_apply sbd_resolver_switch https://dns.alidns.com/dns-query
    t_assert '反复切换不重复增加相同上游' test "$(jq '.dns.servers|length' "$SBD_CONFIG")" = "$count"
    t_assert '域名上游有独立本地 bootstrap、启用系统 CA' jq -e '.dns.servers[]|select(.server=="dns.alidns.com")|.domain_resolver=="system" and .tls=={enabled:true,server_name:"dns.alidns.com"}' "$SBD_CONFIG"
}
custom_types() {
    t_policy_seed
    local address
    for address in 1.1.1.1 'udp://[2001:db8::53]:5353' tcp://1.1.1.1:5353 tls://cloudflare-dns.com quic://dns.example.com https://dns.example.com:8443/resolve; do
        t_run 0 sbd_apply sbd_resolver_switch "$address"
    done
    t_assert 'DoH 自定义端口与路径保留' jq -e '.dns.final as $tag|.dns.servers[]|select(.tag==$tag)|.server_port==8443 and .path=="/resolve"' "$SBD_CONFIG"
}
preserve_config() {
    t_policy_seed
    t_policy_udp
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' '{"domain_suffix":["example.com"],"action":"route","server":"upstream"}'
    t_run 0 sbd_apply sbd_resolver_default strategy prefer_ipv6
    jq '.route.default_domain_resolver={server:"system",strategy:"ipv4_only"} | .dns.reverse_mapping=true' "$SBD_CONFIG" > "$CASE_TMP/extra.json" || exit 1
    cp "$CASE_TMP/extra.json" "$SBD_CONFIG" || exit 1
    t_entry_save
    t_run 0 sbd_apply sbd_resolver_switch https://dns.google/dns-query
    t_assert '旧服务器、DNS/route 规则和高级字段不丢失' python3 - "$ENTRY_SAVED/config" "$SBD_CONFIG" <<'PY'
import json, sys
old, new = [json.load(open(path)) for path in sys.argv[1:]]
for server in old['dns']['servers']:
    assert server in new['dns']['servers']
assert new['dns']['rules'] == old['dns']['rules']
assert new['dns']['strategy'] == 'prefer_ipv6' and new['dns']['reverse_mapping']
assert new['route']['default_domain_resolver'] == {'server': new['dns']['final'], 'strategy': 'ipv4_only'}
for key in ('inbounds', 'outbounds', 'ntp', 'experimental'):
    assert old.get(key) == new.get(key), key
PY
    t_assert '旧托管规则和上游登记不变' python3 - "$ENTRY_SAVED/registry" "$SBD_REGISTRY" <<'PY'
import json, sys
old, new = [json.load(open(path)) for path in sys.argv[1:]]
for area, records in old['policy'].items():
    for record in records:
        assert record in new['policy'][area]
PY
    t_assert '切换 DNS 不修改客户端导出' sbd_tree_compare "$ENTRY_SAVED/exports" "$SBD_EXPORTS"
}
collision_and_bootstrap() {
    t_policy_seed
    # 先为目标生成稳定 tag，再把同名对象替换成非托管配置，验证不会接管覆盖。
    t_run 0 sbd_apply sbd_resolver_switch https://dns.example.com/dns-query
    local tag
    tag=$(jq -r '.dns.final' "$SBD_CONFIG") || exit 1
    jq --arg tag "$tag" '(.dns.servers[]|select(.tag==$tag))={type:"udp",tag:$tag,server:"192.0.2.53",server_port:53} | (.dns.servers[]|select(.tag=="system"))={type:"udp",tag:"system",server:"192.0.2.54",server_port:53}' "$SBD_CONFIG" > "$CASE_TMP/custom.json" || exit 1
    cp "$CASE_TMP/custom.json" "$SBD_CONFIG" || exit 1
    jq '.policy.dns_servers=[]' "$SBD_REGISTRY" > "$CASE_TMP/registry.json" || exit 1
    cp "$CASE_TMP/registry.json" "$SBD_REGISTRY" || exit 1
    t_run 0 sbd_apply sbd_resolver_switch https://dns.example.com/dns-query
    t_assert '生成标识碰撞时不覆盖或接管旧对象、bootstrap 独立' jq -e --arg old "$tag" '.dns.final!=$old and any(.dns.servers[];.tag==$old and .server=="192.0.2.53") and (.dns.final as $tag|.dns.servers[]|select(.tag==$tag)|.domain_resolver!="system" and .domain_resolver!=$tag)' "$SBD_CONFIG"
    t_run 0 sbd_check_config
}
fixed_tag_collision() {
    t_policy_seed
    t_run 0 sbd_apply sbd_resolver_server add alidns '{"type":"udp","tag":"alidns","server":"192.0.2.53","server_port":53}'
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_switch https://dns.alidns.com/dns-query
    t_contains "$CASE_TMP/output" '预设 tag alidns 已被不同配置占用'
    t_entry_unchanged
    t_run 0 sbd_apply sbd_resolver_server delete alidns
    jq '.dns.servers += [{type:"udp",tag:"google",server:"192.0.2.54",server_port:53}]' "$SBD_CONFIG" > "$CASE_TMP/config" || exit 1
    cp "$CASE_TMP/config" "$SBD_CONFIG" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_switch https://dns.google/dns-query
    t_contains "$CASE_TMP/output" '预设 tag google 已被不同配置占用'
    t_entry_unchanged
    jq '(.dns.servers[]|select(.tag=="system"))={type:"udp",tag:"system",server:"192.0.2.55",server_port:53}' "$SBD_CONFIG" > "$CASE_TMP/config" || exit 1
    cp "$CASE_TMP/config" "$SBD_CONFIG" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_switch local
    t_contains "$CASE_TMP/output" '预设 tag system 已被不同配置占用'
    t_entry_unchanged
}
fixed_tag_reuse() {
    t_policy_seed
    t_run 0 sbd_apply sbd_resolver_switch https://dns.google/dns-query
    jq '.policy.dns_servers=[]' "$SBD_REGISTRY" > "$CASE_TMP/registry" || exit 1
    cp "$CASE_TMP/registry" "$SBD_REGISTRY" || exit 1
    local count
    count=$(jq '.dns.servers|length' "$SBD_CONFIG") || exit 1
    t_run 0 sbd_apply sbd_resolver_switch https://dns.google/dns-query
    t_assert '相同固定 tag 的非托管对象只复用，不接管或复制' jq -e --argjson count "$count" '.dns.final=="google" and (.dns.servers|length==$count)' "$SBD_CONFIG"
    t_assert '复用不自动创建托管记录' jq -e '.policy.dns_servers==[]' "$SBD_REGISTRY"
}
legacy_tags_retained() {
    t_policy_seed
    t_run 0 sbd_apply sbd_resolver_server add dns.quick.legacy '{"type":"https","tag":"dns.quick.legacy","server":"dns.google","server_port":443,"path":"/dns-query","tls":{"enabled":true,"server_name":"dns.google"},"domain_resolver":"system"}'
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' '{"domain_suffix":["example.com"],"action":"route","server":"dns.quick.legacy"}'
    t_entry_save
    t_run 0 sbd_apply sbd_resolver_switch https://dns.google/dns-query
    t_assert '重新选预设采用固定 tag，旧 tag 和规则引用原样保留' jq -e '.dns.final=="google" and .route.default_domain_resolver=="google" and .dns.rules[0].server=="dns.quick.legacy" and any(.dns.servers[];.tag=="dns.quick.legacy") and any(.dns.servers[];.tag=="google")' "$SBD_CONFIG"
    t_assert '旧托管对象未被改名或移除' python3 - "$ENTRY_SAVED/registry" "$SBD_REGISTRY" <<'PY'
import json, sys
old, new = [json.load(open(path)) for path in sys.argv[1:]]
for record in old['policy']['dns_servers']:
    assert record in new['policy']['dns_servers']
PY
}
no_implicit_race() {
    t_policy_seed
    t_assert '初始配置仅为系统 DNS，没有竞速规则' jq -e '.dns.final=="system" and (.dns.servers|length==1) and ((.dns.rules // [])|length==0)' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_resolver_switch https://1.1.1.1/dns-query
    t_run 0 sbd_apply sbd_resolver_switch https://dns.google/dns-query
    t_assert '添加多个预设只切换默认 DNS，不自动生成 evaluate/respond 竞速' jq -e '.dns.final=="google" and ((.dns.rules // [])|length==0)' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_resolver_race '["cloudflare","google"]' '{"domain_suffix":["example.com"]}'
    t_run 0 sbd_apply sbd_resolver_switch https://doh.pub/dns-query
    t_assert '用户显式创建的竞速仍保留且使用固定 tag' jq -e '.dns.final=="dnspod" and (.dns.rules|length==4) and .dns.rules[0].server=="cloudflare" and .dns.rules[1].server=="google" and .dns.rules[2].race and .dns.rules[3].race' "$SBD_CONFIG"
}
menu_flow() {
    t_policy_seed
    t_run 0 sbd_resolver_menu <<< $'4\ny\n0'
    t_contains "$CASE_TMP/output" '当前 DNS: https://cloudflare-dns.com/dns-query'
    t_absent "$CASE_TMP/output" 'DNS 上游 tag'
    t_absent "$CASE_TMP/output" 'TLS SNI'
    t_absent "$CASE_TMP/output" '上游连接方式'
    t_run 0 sbd_resolver_menu <<< $'6\nbad/path\nhttps://dns.google:8443/custom\ny\n7\n3\ny\n0'
    t_contains "$CASE_TMP/output" '当前 DNS: https://dns.google:8443/custom'
    t_contains "$CASE_TMP/output" '解析策略: IPv6 优先'
    t_assert '首页简易入口实际提交解析策略' jq -e '.dns.strategy=="prefer_ipv6"' "$SBD_CONFIG"
    t_run 0 sbd_resolver_menu <<< $'8\n0'
    t_absent "$CASE_TMP/output" 'DNS 高级设置'
    t_contains "$CASE_TMP/output" '"default_domain_resolver"'
}
cancellation() {
    t_policy_seed
    t_entry_save
    local input
    for input in $'0' $'4\nn\n0' $'4' $'6\n\n0' $'6' $'7\n0\n0' $'7\n2\nn\n0' $'9\nn\n0'; do
        t_run 0 sbd_resolver_menu <<< "$input"
        t_entry_unchanged
    done
    t_run 0 sbd_resolver_menu < /dev/null
    t_entry_unchanged
    t_run 1 sbd_apply sbd_resolver_switch 'https://bad/path with space'
    t_entry_unchanged
}
state_failure() {
    t_policy_seed
    t_entry_save
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_resolver_menu <<< $'2\ny\n0'
    t_assert '到达 state 提交失败边界' test -e "$CASE_TMP/failed"
    t_absent "$CASE_TMP/output" '[成功]'
    t_entry_unchanged
}
activation_failure() {
    t_policy_seed
    t_entry_save
    sbd_service_state() { printf 'running\n'; }
    sbd_service_restore() {
        if [[ ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; _error '模拟服务启动失败'; return 1; fi
    }
    t_run 1 sbd_resolver_menu <<< $'4\ny\n0'
    t_assert '到达服务激活失败边界' test -e "$CASE_TMP/failed"
    t_absent "$CASE_TMP/output" '[成功]'
    t_entry_unchanged
}
drift_and_summary() {
    t_policy_seed
    t_policy_udp
    jq '(.dns.servers[]|select(.tag=="upstream")).server="192.0.2.99"' "$SBD_CONFIG" > "$CASE_TMP/drift" || exit 1
    cp "$CASE_TMP/drift" "$SBD_CONFIG" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_switch local
    t_contains "$CASE_TMP/output" '漂移'
    t_entry_unchanged
    t_run 0 sbd_resolver_summary
    t_contains "$CASE_TMP/output" '当前 DNS: 系统 DNS'
    printf '{bad' > "$SBD_CONFIG" || exit 1
    t_run 1 sbd_resolver_summary
    t_run 0 sbd_resolver_menu <<< 0
    t_contains "$CASE_TMP/output" 'DNS 摘要读取失败'
    t_absent "$CASE_TMP/output" '当前 DNS: 系统 DNS'
}
cold_summary() {
    t_fresh
    t_run 0 sbd_resolver_menu <<< $'8\n0'
    t_contains "$CASE_TMP/output" '当前 DNS: 未创建配置'
    t_contains "$CASE_TMP/output" '以下为新配置默认值'
    t_assert '只读菜单不创建业务配置' test ! -e "$SBD_CONFIG"
}
preset_pty() {
    t_assert '真实终端预设切换、默认恢复和一次回车停留' python3 "$ROOT/tests/support/menu_pty.py" "$ROOT" "$CASE_TMP" dns_preset
}

t_case 'DNS 完整地址解析、IPv6/自定义端口/path 与错误拒绝' address_parser
t_case '五种常用预设原生校验、独立 bootstrap 与反复切换复用' presets_and_reuse
t_case '六种自定义协议可真正提交并保留端口和 path' custom_types
t_case '切换保留规则/上游/策略/拨号解析器选项/导出与托管事实' preserve_config
t_case '自动 tag 不覆盖自定义对象、无本地 DNS 时新增安全 bootstrap' collision_and_bootstrap
t_case '固定 tag 被托管或自定义不同配置占用时失败并保留旧事实' fixed_tag_collision
t_case '相同固定 tag 对象直接复用且不自动接管' fixed_tag_reuse
t_case '旧散列 tag 与引用不自动迁移，重选预设使用固定 tag' legacy_tags_retained
t_case '默认与预设切换不启用竞速，显式竞速组仍保留' no_implicit_race
t_case '首页预设、自定义/策略/恢复默认与查看配置实际导航提交' menu_flow
t_case '取消、EOF、无效地址不改变当前配置与登记' cancellation
t_case 'state 提交失败整组回滚且不假报成功' state_failure
t_case '运行中服务激活失败恢复旧配置与管理事实' activation_failure
t_case '漂移拒绝变更、坏配置不冒充默认系统 DNS' drift_and_summary
t_case '尚未创建配置时摘要不假装系统 DNS 已运行' cold_summary
t_case 'DNS 简易首页真实终端切换和默认恢复' preset_pty
t_finish
