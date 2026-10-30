#!/usr/bin/env bash
# 文件操作窄桩由真实记录函数间接调用。
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

roundtrip() {
    t_fresh
    t_run 0 sbd_record_write "$SBD_STATE" '{"name":"中文","text":"a\\b\nquote\"","format":1,"revision":0}'
    t_assert '内容原样可读' jq -e '.name=="中文" and .text=="a\\b\nquote\""' "$SBD_STATE"
    t_run 0 sbd_record_read "$SBD_STATE"
}
invalid_records() {
    t_fresh
    cp "$SBD_STATE" "$CASE_TMP/before" || exit 1
    local value
    for value in '' '[]' 'null' '{} {}' '{bad'; do
        t_run 1 sbd_record_write "$SBD_STATE" "$value"
        t_assert '坏记录不截断旧文件' cmp -s "$SBD_STATE" "$CASE_TMP/before"
    done
}
write_failure() {
    t_fresh
    cp "$SBD_STATE" "$CASE_TMP/before" || exit 1
    mv() { return 1; }
    t_run 1 sbd_record_write "$SBD_STATE" '{"replacement":true}'
    t_assert '替换失败保留原字节' cmp -s "$SBD_STATE" "$CASE_TMP/before"
}
partial_copy() {
    t_fresh
    cp "$SBD_STATE" "$CASE_TMP/before" || exit 1
    cp() { printf 'partial' > "${!#}"; return 1; }
    t_run 1 sbd_record_write "$SBD_STATE" '{"replacement":true}'
    t_assert '部分 copy 不提交' cmp -s "$SBD_STATE" "$CASE_TMP/before"
}
directory_target() {
    t_fresh
    mkdir "$CASE_TMP/target" || exit 1
    printf 'keep' > "$CASE_TMP/target/keep" || exit 1
    t_run 1 sbd_atomic_file "$SBD_STATE" "$CASE_TMP/target"
    t_contains "$CASE_TMP/target/keep" keep
}
missing_read() { t_run 1 sbd_record_read "$CASE_TMP/missing"; t_contains "$CASE_TMP/output" '不存在'; }
policy_records_contract() {
    t_fresh
    cp "$SBD_STATE" "$CASE_TMP/state.json" || exit 1
    local value
    for value in '{"route_rules":[{"id":"a","expected":{},"index":-1}]}' '{"dns_rules":[{"id":"a","expected":{},"index":0.5}]}' '{"dns_servers":[{"id":"a","expected":null}]}' '{"rule_sets":{}}'; do
        jq -n --argjson policy "$value" '{format:1,nodes:[],policy:$policy}' > "$CASE_TMP/registry.json" || exit 1
        t_run 1 sbd_records_check "$CASE_TMP"
        t_contains "$CASE_TMP/output" '策略登记'
    done
}
t_case '记录真实编码与读取' roundtrip
t_case '坏 JSON 不能覆盖旧记录' invalid_records
t_case 'mv 失败保留旧记录' write_failure
t_case '部分写入不提交' partial_copy
t_case '目录目标不会生成嵌套文件' directory_target
t_case '缺失记录显式失败' missing_read
t_case '策略登记类型和规则位置不能作为有效事实提交' policy_records_contract
t_finish
