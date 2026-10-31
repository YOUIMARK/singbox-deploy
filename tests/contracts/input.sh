#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

numbers() {
    t_assert '端口先去前导零' test "$(sbd_integer 00065535 1 65535)" = 65535
    t_assert '全零菜单选择' test "$(sbd_integer 0000 0 10)" = 0
    t_assert '八进制样式按十进制' test "$(sbd_integer 00008 1 65535)" = 8
}
rejected() {
    t_run 1 sbd_integer 65536 1 65535
    t_run 1 sbd_integer 999999999999999999999999999 0 65535
    t_run 1 sbd_integer '1+2' 0 10
    t_run 1 sbd_integer -1 0 10
    t_run 1 sbd_integer '' 0 10
}
retry_field() {
    sbd_read_integer 端口 1 65535 > "$CASE_TMP/prompt" 2>&1 <<< $'错误\n00080' || exit 1
    t_assert '只重问后保留正确值' test "$SBD_REPLY" = 80
    t_contains "$CASE_TMP/prompt" '十进制整数'
}
eof_cancel() {
    t_run 2 sbd_read_required 密码 < /dev/null
    t_contains "$CASE_TMP/output" '已取消'
    t_run 2 sbd_read_integer 端口 1 65535 <<< '不是端口'
    t_contains "$CASE_TMP/output" '已取消'
}
secret_and_optional() {
    sbd_read_secret 密码 > "$CASE_TMP/prompt" 2>&1 <<< $'\nfixture-secret' || exit 1
    t_assert '密钥完整保留' test "$SBD_REPLY" = fixture-secret
    t_absent "$CASE_TMP/prompt" fixture-secret
    t_contains "$CASE_TMP/prompt" '此字段不能为空'
    t_run 2 sbd_read_secret 密码 < /dev/null
    sbd_read_optional 备注 > "$CASE_TMP/prompt" 2>&1 <<< '' || exit 1
    t_assert '可选字段接受显式空行' test -z "$SBD_REPLY"
    t_run 2 sbd_read_optional 备注 < /dev/null
    sbd_read_optional 临时令牌 true > "$CASE_TMP/prompt" 2>&1 <<< fixture-token || exit 1
    t_assert '可选令牌不丢字节' test "$SBD_REPLY" = fixture-token
    t_absent "$CASE_TMP/prompt" fixture-token
}
t_case '十进制规范化' numbers
t_case '拒绝溢出和表达式' rejected
t_case '字段错误只重问当前字段' retry_field
t_case '必答 EOF 取消' eof_cancel
t_case '秘密输入不回显与可选字段 EOF 取消' secret_and_optional
pause_labels() {
    NO_COLOR=1
    sbd_ui_terminal() { return 0; }
    SBD_UI_PAGE=7
    t_run 0 sbd_ui_pause 7 <<< ''
    t_contains "$CASE_TMP/output" '按回车返回菜单'
    t_run 0 sbd_ui_pause 7 '按回车退出…' <<< ''
    t_contains "$CASE_TMP/output" '按回车退出'
    t_absent "$CASE_TMP/output" '返回菜单'
}
t_case '卸载后暂停提示退出而非返回菜单' pause_labels
t_finish
