#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/policy.sh"

cancel_contract() {
    t_fresh
    t_run 0 sbd_rules_menu <<< 0
    t_run 0 sbd_rules_menu < /dev/null
    t_assert '取消不创建配置' test ! -e "$SBD_CONFIG"
    t_assert '取消不创建规则材料' test ! -e "$SBD_DATA/rule-sets"
}
local_contract() {
    t_policy_seed
    t_policy_local
    local path
    path=$(jq -r '.route.rule_set[0].path' "$SBD_CONFIG") || exit 1
    # 官方 format 对 .srs 扩展名省略可推导的 format。
    t_assert '源文件编译为原生本地 SRS' jq -e '.route.rule_set[0]|.type=="local" and (.format // "binary")=="binary" and (.path|endswith(".srs"))' "$SBD_CONFIG"
    t_assert '源 JSON 保留原始版本' jq -e '.version==1' "${path%/*}/source.json"
    t_run 0 "$SBD_BINARY" rule-set decompile -o "$CASE_TMP/decoded.json" "$path"
    t_assert '实际规则集内容被核心解析' jq -e '.rules[0].domain_suffix|index("example.com")!=null' "$CASE_TMP/decoded.json"
    t_assert '外部源文件没有被改写' cmp -s "$ROOT/tests/fixtures/rule-set-domains.json" "${path%/*}/source.json"
    t_run 0 sbd_apply sbd_policy_begin
}
binary_contract() {
    t_policy_seed
    "$SBD_BINARY" rule-set compile -o "$CASE_TMP/input.srs" "$ROOT/tests/fixtures/rule-set-ips.json" || exit 1
    local value
    value=$(jq -n --arg path "$CASE_TMP/input.srs" '{type:"local",tag:"ips",format:"binary",path:$path}') || exit 1
    t_run 0 sbd_apply sbd_rule_set add ips "$value"
    t_assert '输入 SRS 通过真实解析后保留原字节' cmp -s "$CASE_TMP/input.srs" "$(jq -r '.route.rule_set[0].path' "$SBD_CONFIG")"
}
invalid_contract() {
    t_policy_seed
    printf 'not a rule-set' > "$CASE_TMP/bad.srs" || exit 1
    local value
    value=$(jq -n --arg path "$CASE_TMP/bad.srs" '{type:"local",tag:"broken",format:"binary",path:$path}') || exit 1
    t_run 1 sbd_apply sbd_rule_set add broken "$value"
    t_unchanged
    t_assert '坏 SRS 候选材料已回收' test -z "$(find "$SBD_DATA/rule-sets" -mindepth 1 -maxdepth 1 -type d)"
    value=$(jq -n --arg path "$CASE_TMP/bad.srs" '{type:"local",tag:"broken",format:"source",path:$path}') || exit 1
    t_run 1 sbd_apply sbd_rule_set add broken "$value"
    t_unchanged
}
route_contract() {
    t_policy_seed
    local rule id
    rule=$(cat "$ROOT/tests/fixtures/route-policy.json") || exit 1
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' "$rule" 0
    id=$(t_policy_id route_rules) || exit 1
    t_assert '管理 ID 不污染原生规则字段' jq -e '.route.rules[0]|(has("id") or has("managed") or has("tag"))|not' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_policy_rule route_rules replace "$id" '{"domain_suffix":["example.org"],"action":"reject"}'
    t_assert '替换后仍是同一管理 ID' test "$(t_policy_id route_rules)" = "$id"
    t_assert '动作写入实际配置' jq -e '.route.rules[0].action=="reject"' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_policy_rule route_rules delete "$id"
    t_assert '规则和关联一起删除' jq -e '(.route.rules // [])==[]' "$SBD_CONFIG"
}
inline_contract() {
    t_policy_seed
    t_run 0 sbd_apply sbd_rule_set add inline-domains '{"tag":"inline-domains","rules":[{"domain_suffix":"example.com"}]}'
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"rule_set":"inline-domains","action":"route","outbound":"direct"}'
    t_assert '官方可省略 type 的 inline 仍可管理' jq -e '.route.rule_set[0]|(.type // "inline")=="inline" and .rules[0].domain_suffix=="example.com"' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_policy_rule route_rules delete "$(t_policy_id route_rules)"
    t_run 0 sbd_apply sbd_rule_set delete inline-domains
    t_assert 'inline 不创建文件材料' test ! -e "$SBD_DATA/rule-sets"
}
menu_add_remote() {
    t_policy_seed
    t_run 0 sbd_rules_menu <<< $'4\n2\nhttps://example.com/geosite-cn.srs\n\ny\n0'
    t_contains "$CASE_TMP/output" '规则集 geosite-cn 已添加'
    t_assert '菜单添加远端规则集并写显式 HTTP client' jq -e '.route.rule_set[0] | .type=="remote" and .tag=="geosite-cn" and (.format // "binary")=="binary" and .url=="https://example.com/geosite-cn.srs" and .update_interval=="24h0m0s" and .http_client=={version:2}' "$SBD_CONFIG"
    t_assert '远端规则集启用核心缓存' jq -e '.experimental.cache_file.enabled==true and (.experimental.cache_file.path|endswith("/cache.db"))' "$SBD_CONFIG"
    t_assert '规则集归属登记到 registry' jq -e '.policy.rule_sets[0].id=="geosite-cn"' "$SBD_REGISTRY"
    t_run 0 sbd_rules_menu <<< $'3\n0'
    t_contains "$CASE_TMP/output" 'geosite-cn  remote binary'
}
menu_add_local() {
    t_policy_seed
    t_run 0 sbd_rules_menu <<< "$(printf '4\n3\n%s\n\ny\n0\n' "$ROOT/tests/fixtures/rule-set-domains.json")"
    t_contains "$CASE_TMP/output" '规则集 rule-set-domains 已添加'
    local path
    path=$(jq -r '.route.rule_set[0].path' "$SBD_CONFIG") || exit 1
    t_assert '菜单导入本地文件编译为 SRS' test -f "$path"
    t_assert '源 JSON 保留原始版本且不被改写' cmp -s "$ROOT/tests/fixtures/rule-set-domains.json" "${path%/*}/source.json"
}
menu_add_preset() {
    t_policy_seed
    t_run 0 sbd_rules_menu <<< $'4\n1\n4\ny\n0'
    t_contains "$CASE_TMP/output" '规则集 geosite-cn 已添加'
    t_assert '预设目录写入与 s-ui 同源的规则集地址' jq -e '.route.rule_set[0] | .tag=="geosite-cn" and .url=="https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs" and (.format // "binary")=="binary" and .update_interval=="24h0m0s"' "$SBD_CONFIG"
}
menu_delete_referenced() {
    t_policy_seed
    t_run 0 sbd_apply sbd_rule_set add inline-domains '{"tag":"inline-domains","rules":[{"domain_suffix":"example.com"}]}'
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"rule_set":"inline-domains","action":"reject"}'
    t_entry_save
    t_run 0 sbd_rules_menu <<< $'5\n1\n0'
    t_contains "$CASE_TMP/output" '仍有 1 条路由/DNS 规则引用 inline-domains'
    t_entry_unchanged
    t_run 0 sbd_apply sbd_policy_rule route_rules delete "$(t_policy_id route_rules)"
    t_run 0 sbd_rules_menu <<< $'5\n1\ny\n0'
    t_contains "$CASE_TMP/output" '规则集 inline-domains 已删除'
    t_assert '删除后不再保留原生规则集' jq -e '(.route.rule_set // [])==[]' "$SBD_CONFIG"
}
defaults_restore() {
    t_policy_seed
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"domain":"custom.example","action":"route","outbound":"direct"}'
    t_run 0 sbd_rules_menu <<< $'6\ny\n0'
    t_contains "$CASE_TMP/output" '默认路由规则已补齐'
    t_assert '补齐默认规则且保留自定义规则' jq -e '.route.rules[0]=={action:"sniff"} and .route.rules[1]=={protocol:"dns",action:"hijack-dns"} and .route.rules[2]=={action:"resolve"} and .route.rules[3]=={ip_is_private:true,action:"reject"} and .route.rules[4].domain=="custom.example" and (.route.rules|length==5)' "$SBD_CONFIG"
    t_assert '路由规则不再由脚本登记' jq -e '((.policy.route_rules // [])|length)==0' "$SBD_REGISTRY"
    t_run 0 sbd_rules_menu <<< $'6\ny\n0'
    t_assert '反复补齐不复制规则' jq -e '(.route.rules|length)==5' "$SBD_CONFIG"
}
t_case '规则集菜单取消及必填 EOF 无副作用' cancel_contract
t_case '本地源版本 1 经核心编译和原生配置校验' local_contract
t_case '版本 5 IP 规则编译后作为 SRS 导入' binary_contract
t_case '坏 JSON/SRS 真实失败与材料回收' invalid_contract
t_case '路由规则 CRUD、稳定关联和无私有配置字段' route_contract
t_case '省略 type 的原生 inline 规则集引用与删除' inline_contract
t_case '菜单添加远端规则集、缓存与归属登记' menu_add_remote
t_case '菜单按预设目录添加规则集' menu_add_preset
t_case '菜单导入本地规则集并保留源文件' menu_add_local
t_case '被规则引用的规则集拒绝删除，解除后真实删除' menu_delete_referenced
t_case '补齐默认路由规则并保留自定义规则' defaults_restore
t_finish
