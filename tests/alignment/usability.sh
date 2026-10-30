#!/usr/bin/env bash
# 只替换明确的服务/文件失败边界，其余走真实创建、事务、Schema/check 和分享适配器。
# shellcheck disable=SC2329,SC2016
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/entries.sh"

profile_edit_flow() {
    t_seed
    local profile hidden
    for profile in shadowsocks vmess_ws vless_ws vless_reality hysteria2 anytls anyreality; do
        t_entry_add "$profile"
        case "$profile" in shadowsocks|vmess_ws|vless_ws) hidden=6 ;; *) hidden=8 ;; esac
        t_run 0 sbd_entry_change_prompt <<< "$(printf '1\n%s\n1\nmenu-%s\ny\n' "$hidden" "$profile")"
        t_contains "$CASE_TMP/output" '选择显示的编号'
        t_assert '真实菜单只重问操作后提交选定节点' jq -e --arg name "menu-$profile" '.nodes[0].name==$name' "$SBD_REGISTRY"
        t_run 0 sbd_apply sbd_entry_change "$NODE_ID" delete ''
    done
}
classic_delivery() {
    t_seed
    t_run 0 sbd_entry_create_prompt <<< $'4\n1\n1\nfixture-secret\n127.0.0.1\n19504\nexample.com\n29504\nSS交付\ny\n1\n0'
    local id link
    id=$(jq -r '.nodes[0].id' "$SBD_REGISTRY") || exit 1
    link=$(cat "$SBD_EXPORTS/$id.txt") || exit 1
    t_contains "$CASE_TMP/output" "$link"
    t_contains "$CASE_TMP/output" "$id"
    t_contains "$CASE_TMP/output" '含凭据'
    t_assert '创建与交付使用同一个稳定 ID' test "$SBD_NEW_ENTRY_ID" = "$id"
    t_assert '只读交付不提交第二次修订' jq -e '.revision==1' "$SBD_STATE"
}
creation_failure_no_delivery() {
    t_seed
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_entry_create_prompt <<< $'4\n1\n1\nfixture-secret\n127.0.0.1\n19504\nexample.com\n29504\n失败节点\ny\n1\n0'
    t_assert '到达提交失败边界' test -f "$CASE_TMP/failed"
    t_absent "$CASE_TMP/output" '当前节点资料'
    t_absent "$CASE_TMP/output" '[成功]'
    t_unchanged
}
view_failure_keeps_commit() {
    t_seed
    cat() {
        if [[ "${!#}" = "$SBD_EXPORTS"/node.*.txt ]]; then return 1; fi
        command cat "$@"
    }
    t_run 1 sbd_entry_create_prompt <<< $'4\n1\n1\nfixture-secret\n127.0.0.1\n19504\nexample.com\n29504\n查看失败\ny\n1'
    t_contains "$CASE_TMP/output" '节点已提交，但资料查看失败'
    t_assert '查看失败不撤销已经提交的节点' jq -e '.nodes|length==1' "$SBD_REGISTRY"
    t_assert '保留实际已提交修订' jq -e '.revision==1' "$SBD_STATE"
    t_run 0 sbd_check_config
}
summary_with_live_records() {
    t_seed
    t_entry_add shadowsocks
    t_entry_add vless_ws
    sbd_backend() { printf 'openrc\n'; }
    sbd_service_enabled() { printf 'disabled\n'; }
    t_entry_save
    t_run 0 sbd_console <<< 0
    t_contains "$CASE_TMP/output" '托管节点: 2 个'
    t_contains "$CASE_TMP/output" '服务: 已停止'
    t_absent "$CASE_TMP/output" "$SBD_LOG"
    t_absent "$CASE_TMP/output" "$SBD_CONFIG"
    t_entry_unchanged
    local id
    id=$(jq -r '.nodes[0].id' "$SBD_REGISTRY") || exit 1
    t_assert '状态摘要不泄露链接或凭据' test -s "$SBD_EXPORTS/$id.txt"
    t_absent "$CASE_TMP/output" "$(cat "$SBD_EXPORTS/$id.txt")"
    t_run 0 sbd_dispatch 10
    t_contains "$CASE_TMP/output" "$SBD_LOG"
    t_contains "$CASE_TMP/output" "$SBD_CONFIG"
    t_entry_unchanged
}
fixed_identity_contract() {
    t_seed
    local spec
    spec=$(jq '.id="node.0000000000000001"' "$ROOT/tests/fixtures/entry-shadowsocks.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    t_assert '创建请求 ID 只作内部身份，不改变配置字段' jq -e '.nodes[0].id=="node.0000000000000001"' "$SBD_REGISTRY"
    t_assert '原生配置不混入私有 id' jq -e '.inbounds[0]|.tag=="node.0000000000000001" and (has("id")|not)' "$SBD_CONFIG"
    t_entry_save
    spec=$(jq '.listen_port=19604' <<< "$spec") || exit 1
    t_run 1 sbd_apply sbd_entry_create "$spec"
    t_contains "$CASE_TMP/output" 'ID 已存在'
    t_entry_unchanged
}
t_case '七档真实编辑菜单拒绝隐藏编号后只重问操作' profile_edit_flow
t_case 'Shadowsocks 创建后立即查看该节点真实 URI' classic_delivery
t_case '创建事务失败不进入交付菜单、不假报成功' creation_failure_no_delivery
t_case '提交后资料读取失败明确区分，不撤销已提交节点' view_failure_keeps_commit
t_case '主菜单精简摘要、详细状态保留实际路径且不写事实' summary_with_live_records
t_case '预先确定的创建 ID 不污染配置或覆盖已有节点' fixed_identity_contract
t_finish
