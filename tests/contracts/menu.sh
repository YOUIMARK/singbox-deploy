#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

plain_menu() {
    COLUMNS=80 t_run 0 sbd_ui_menu '核心管理' '@安装与更新' '[1] 安装' '[2] 指定版本' '[0] 返回'
    t_assert '标题恰好一次' test "$(grep -c 核心管理 "$CASE_TMP/output")" = 1
    t_contains "$CASE_TMP/output" '[1] 安装'
    t_contains "$CASE_TMP/output" '[2] 指定版本'
    t_contains "$CASE_TMP/output" '[0] 返回'
    t_absent "$CASE_TMP/output" $'\033'
}
column_layout() {
    local cols
    for cols in 80 100; do
        COLUMNS="$cols" t_run 0 sbd_ui_rows '[1] 核心管理' '[2] 节点管理' '[3] 独立 DNS' '[4] TLS 与证书'
        t_assert '宽屏两行四项' test "$(wc -l < "$CASE_TMP/output")" = 2
        t_assert '中文按显示列对齐' python3 - "$CASE_TMP/output" "$cols" <<'PY'
import sys, unicodedata
lines = open(sys.argv[1]).read().splitlines()
for line, item in zip(lines, ('[2]', '[4]')):
    prefix = line[:line.index(item)]
    width = sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in prefix)
    assert width == 34, (line, width)
PY
    done
}
narrow_layout() {
    COLUMNS=40 t_run 0 sbd_ui_rows '[1] 核心管理' '[2] 节点管理'
    t_assert '窄屏单列' test "$(wc -l < "$CASE_TMP/output")" = 2
    COLUMNS=80 t_run 0 sbd_ui_rows '[1] 这是一段超过半列宽度的菜单标签不得挤在另一项上' '[2] 节点管理'
    t_assert '过长标签单独成行' test "$(wc -l < "$CASE_TMP/output")" = 2
    t_assert '中文和 ASCII 宽度' test "$(sbd_ui_width '中文 DNS')" = 8
    COLUMNS=00080 t_assert '宽度先去前导零' test "$(COLUMNS=00080 sbd_ui_columns)" = 80
    COLUMNS=invalid t_assert '无效宽度使用 80' test "$(COLUMNS=invalid sbd_ui_columns)" = 80
}
stable_pairs() {
    COLUMNS=80 t_run 0 sbd_ui_rows '[1] 这是一段超过半列宽度的菜单标签不得挤在另一项上' '[2] 节点管理' '[3] DNS' '[4] TLS'
    t_assert '长项退为单列不重排后续配对' test "$(wc -l < "$CASE_TMP/output")" = 3
    t_assert '原配对中的右项独占一行' test "$(sed -n '2p' "$CASE_TMP/output")" = '  [2] 节点管理'
    t_contains "$CASE_TMP/output" '[3] DNS'
    t_assert '后续两个编号仍在同一行' grep -Eq '\[3\].*\[4\]' "$CASE_TMP/output"
}
byte_widths() {
    local locale
    for locale in C C.UTF-8; do
        t_assert '空文本宽度为零' test "$(LC_ALL="$locale" sbd_ui_width '')" = 0
        t_assert '截图状态标签宽度正确' test "$(LC_ALL="$locale" sbd_ui_width '开机自启: 已关闭')" = 16
        t_assert '节点计数标签宽度正确' test "$(LC_ALL="$locale" sbd_ui_width '托管节点: 0 个')" = 14
        t_assert '中文菜单标签宽度正确' test "$(LC_ALL="$locale" sbd_ui_width '[3] 分享与客户端资料')" = 20
    done
}
width_failure() {
    # 由真实 sbd_ui_width 调用失败边界。
    # shellcheck disable=SC2329
    od() { return 1; }
    t_run 1 sbd_ui_rows '[1] 核心管理' '[2] 节点管理'
    t_contains "$CASE_TMP/output" '读取菜单显示宽度失败'
    t_absent "$CASE_TMP/output" '[2] 节点管理'
}
literal_labels() {
    # 此处刻意传入 shell 字面文本，验证渲染不求值。
    # shellcheck disable=SC2016
    local label='[1] 百分比 100% \\n $(touch forbidden)'
    COLUMNS=80 t_run 0 sbd_ui_menu "$label" "$label" '[0] 返回'
    t_contains "$CASE_TMP/output" "$label"
    t_assert '标签不作为命令求值' test ! -e forbidden
}
pipe_does_not_pause() {
    {
        sbd_ui_menu 测试 '[1] 操作' '[0] 返回'
        sbd_ui_pause
        sbd_read_integer 请选择 0 1 || exit 1
    } > "$CASE_TMP/output" 2>&1 <<< 1
    t_assert '重定向时停留不消耗编号' test "$SBD_REPLY" = 1
    t_absent "$CASE_TMP/output" '按回车'
    t_absent "$CASE_TMP/output" $'\033'
}
pty_case() {
    t_assert '真实 PTY 验证' python3 "$ROOT/tests/support/menu_pty.py" "$ROOT" "$CASE_TMP" "$1"
}
t_case '非终端标题与编号完整且无 ANSI' plain_menu
t_case '80/100 列双栏及中文对齐' column_layout
t_case '窄屏与长标签回退单列' narrow_layout
t_case '长项回退不改变后续编号配对' stable_pairs
t_case 'C/UTF-8 下截图中的中文标签按字节正确计宽' byte_widths
t_case '计宽工具失败明确返回错误、不继续错位渲染' width_failure
t_case '菜单标签不解释格式符或反斜杠' literal_labels
t_case '管道输入不清屏不暂停不吞编号' pipe_does_not_pause
t_case '真实终端着色、清屏、删除警示' pty_case colors
t_case 'NO_COLOR 关闭颜色但保留清屏' pty_case no_color
t_case 'TERM=dumb 不清屏不暂停' pty_case dumb
t_case '详细状态等回车后重绘、子菜单返回不额外暂停' pty_case navigation
t_case '失败信息保持至回车、未假报成功' pty_case failure
t_case '暂停处 EOF 后退出且不循环重绘' pty_case eof
t_finish
