#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/entries.sh"

protocol_back() {
    t_fresh
    cp "$SBD_STATE" "$CASE_TMP/state" && cp "$SBD_REGISTRY" "$CASE_TMP/registry" || exit 1
    local input
    for input in 0 000 $'8\n0'; do
        t_run 2 sbd_entry_create_prompt <<< "$input"
        t_contains "$CASE_TMP/output" '[0] 返回上一级'
        t_absent "$CASE_TMP/output" '监听 IP'
        t_absent "$CASE_TMP/output" '分享链接:'
    done
    t_run 2 sbd_entry_create_prompt < /dev/null
    t_assert '返回或 EOF 不写 state' cmp -s "$SBD_STATE" "$CASE_TMP/state"
    t_assert '返回或 EOF 不写 registry' cmp -s "$SBD_REGISTRY" "$CASE_TMP/registry"
    t_assert '返回不初始化配置或材料' test ! -e "$SBD_CONFIG"
    t_assert '返回不开始事务' test ! -e "$SBD_WORK/active"
}
back_before_checks() {
    t_fresh
    local binary="$SBD_BINARY"
    SBD_BINARY="$CASE_TMP/missing-core"
    printf '{bad' > "$SBD_CONFIG" || exit 1
    t_run 2 sbd_entry_create_prompt <<< 0
    t_absent "$CASE_TMP/output" '[错误]'
    t_run 1 sbd_entry_create_prompt <<< 1
    t_contains "$CASE_TMP/output" '核心未安装'
    SBD_BINARY="$binary"
    t_run 1 sbd_entry_create_prompt <<< 1
    t_contains "$CASE_TMP/output" '[错误]'
    t_absent "$CASE_TMP/output" '监听 IP'
    t_assert '真实创建仍受配置/核心前置校验约束' test ! -e "$SBD_WORK/active"
}
selector_back() {
    local values='[{"id":"node.one","name":"第一个"},{"id":"node.two","name":"第二个"}]'
    t_run 2 sbd_entry_choose "$values" 选择节点 true <<< 0
    t_contains "$CASE_TMP/output" '[0] 返回上一级'
    t_run 2 sbd_entry_choose "$values" 选择节点 true < /dev/null
    t_run 0 sbd_entry_choose "$values" 选择节点 true <<< 2
    t_assert '有效编号仍返回稳定 ID' test "$SBD_REPLY" = node.two
    t_run 0 sbd_entry_choose "$values" 选择证书 <<< $'0\n1'
    t_assert '未启用返回的旧字段选择器保持原语义' test "$SBD_REPLY" = node.one
    t_absent "$CASE_TMP/output" '[0] 返回上一级'
}
edit_delete_back() {
    t_seed
    t_entry_add shadowsocks
    t_entry_save
    t_run 2 sbd_dispatch 3 <<< 0
    t_contains "$CASE_TMP/output" '[0] 返回上一级'
    t_absent "$CASE_TMP/output" '选择操作'
    t_run 2 sbd_dispatch 4 <<< 0
    t_absent "$CASE_TMP/output" '将删除节点'
    t_entry_unchanged
}
links_back() {
    t_seed
    t_entry_add shadowsocks
    t_entry_save
    local link
    link=$(cat "$SBD_EXPORTS/$NODE_ID.txt") || exit 1
    t_run 0 sbd_export_menu <<< $'3\n0\n0'
    t_contains "$CASE_TMP/output" '[0] 返回上一级'
    t_absent "$CASE_TMP/output" '当前节点链接'
    t_absent "$CASE_TMP/output" "$link"
    t_assert '返回的是节点链接菜单，不越级退出' test "$(grep -c '^  节点链接$' "$CASE_TMP/output")" = 2
    t_run 0 sbd_export_menu <<< $'3'
    t_entry_unchanged
}
pty_back() {
    t_assert '真实终端逐层返回且无需回车暂停' python3 "$ROOT/tests/support/menu_pty.py" "$ROOT" "$CASE_TMP" "$1"
}

t_case '协议菜单 0/前导零/重问/EOF 返回且无副作用' protocol_back
t_case '缺核心或坏配置也能返回，真实创建仍校验' back_before_checks
t_case '节点列表返回与旧选择器语义互不干扰' selector_back
t_case '修改/删除节点列表返回不进入操作或确认' edit_delete_back
t_case '查看单节点返回上一级且不显示凭据/改状态' links_back
t_case '真实终端添加/修改/删除/链接列表的返回层级' pty_back back_navigation
t_case '缺核心的真实终端添加页可直接返回首页' pty_back back_no_core
t_finish
