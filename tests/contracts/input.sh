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
prompt_once() {
    sbd_read_required 字段 > "$CASE_TMP/prompt" 2>&1 <<< '值' || exit 1
    t_assert '重定向输入只打印一次字段提示' test "$(grep -Fc -- '  字段: ' "$CASE_TMP/prompt")" = 1
}
t_case '十进制规范化' numbers
t_case '拒绝溢出和表达式' rejected
t_case '字段错误只重问当前字段' retry_field
t_case '必答 EOF 取消' eof_cancel
t_case '字段提示只输出一次' prompt_once
t_finish
