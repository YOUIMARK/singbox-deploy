#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/policy.sh"

cancel_contract() {
    t_fresh
    t_run 0 sbd_rules_menu <<< 0
    t_run 0 sbd_rules_menu < /dev/null
    t_run 2 sbd_rule_set_prompt <<< $'1\ndomains\n1'
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
json_fields_contract() {
    t_policy_seed
    sbd_policy_json_prompt > "$CASE_TMP/prompt" 2>&1 <<< "$ROOT/tests/fixtures/route-policy.json" || exit 1
    t_assert '原生 JSON 文件读取真实对象' jq -e '.action=="route" and .outbound=="direct"' <<< "$SBD_REPLY"
    printf '{}\n{}\n' > "$CASE_TMP/multiple.json" || exit 1
    t_run 2 sbd_policy_json_prompt <<< "$CASE_TMP/multiple.json"
    t_run 2 sbd_policy_json_prompt < /dev/null
    t_run 1 sbd_rule_url ftp://example.com/rules.srs
    t_run 0 sbd_rule_url 'https://example.com/rules.srs?version=1'
    sbd_policy_match_prompt > "$CASE_TMP/prompt" 2>&1 <<< $'4\nbad\n192.0.2.1/24' || exit 1
    t_assert 'CIDR 错误只重问该字段' jq -e '.ip_cidr==["192.0.2.0/24"]' <<< "$SBD_MATCH"
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
t_case '规则集菜单取消及必填 EOF 无副作用' cancel_contract
t_case '本地源版本 1 经核心编译和原生配置校验' local_contract
t_case '版本 5 IP 规则编译后作为 SRS 导入' binary_contract
t_case '坏 JSON/SRS 真实失败与材料回收' invalid_contract
t_case '路由规则 CRUD、稳定关联和无私有配置字段' route_contract
t_case '高级 JSON、URL 与匹配字段输入契约' json_fields_contract
t_case '省略 type 的原生 inline 规则集引用与删除' inline_contract
t_finish
