#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

plain_menu() {
    COLUMNS=80 t_run 0 sbd_ui_menu '核心管理' '@安装与更新' '[1] 安装' '[2] 指定版本' '[0] 返回'
    t_assert '标题恰好一次' test "$(grep -c 核心管理 "$CASE_TMP/output")" = 1
    t_contains "$CASE_TMP/output" '[1] 安装'
    t_contains "$CASE_TMP/output" '[2] 指定版本'
    t_contains "$CASE_TMP/output" '[0] 返回'
    t_contains "$CASE_TMP/output" '【安装与更新】'
    t_absent "$CASE_TMP/output" '--------'
    t_absent "$CASE_TMP/output" $'\033'
}
section_spacing() {
    t_run 0 sbd_ui_menu '核心管理' '@安装与更新' '[1] 安装' '@服务控制' '[2] 启动' '[0] 返回'
    t_assert '标题到首组及各组之间只留一行' python3 - "$CASE_TMP/output" <<'PY'
import sys
text = open(sys.argv[1]).read()
assert '\n  【核心管理】\n\n  【安装与更新】\n' in text, text
assert '\n  [1] 安装\n\n  【服务控制】\n' in text, text
assert '\n  [2] 启动\n\n  [0] 返回\n' in text, text
assert '\n\n\n' not in text, text
PY
    t_run 0 sbd_ui_menu '节点管理' '[1] 列出节点' '[0] 返回'
    t_contains "$CASE_TMP/output" $'  【节点管理】\n\n  [1] 列出节点'
}
compact_prompts() {
    { sbd_ui_menu '添加节点' '[1] Hysteria2' '[0] 返回上一级'
      sbd_read_required '监听 IP'
      sbd_read_required '监听端口'
    } > "$CASE_TMP/output" 2>&1 <<< $'::\n23456\n'
    t_assert '首个字段与上文隔一行、连续字段紧排' python3 - "$CASE_TMP/output" <<'PY'
import sys
text = open(sys.argv[1]).read()
assert '\n\n  监听 IP: \n  监听端口: \n' in text, text
assert '监听 IP: \n  监听端口' in text, text
PY
    { sbd_info '提示一条'; sbd_read_required '继续'; } > "$CASE_TMP/output" 2>&1 <<< 'x'
    t_assert '非提示输出之后仍空一行' python3 - "$CASE_TMP/output" <<'PY'
import sys
text = open(sys.argv[1]).read()
assert '\n\n  继续: \n' in text, text
PY
}
centered_title() {
    COLUMNS=80 t_run 0 sbd_ui_begin 'sing-box 部署管理脚本 (singbox-deploy)' true
    t_assert '标题按显示列在紧凑标题区居中' python3 - "$CASE_TMP/output" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
assert lines == ['      sing-box 部署管理脚本 (singbox-deploy)', ''], lines
PY
    COLUMNS=40 t_run 0 sbd_ui_begin 'sing-box 部署管理脚本 (singbox-deploy)' true
    t_contains "$CASE_TMP/output" '  sing-box 部署管理脚本 (singbox-deploy)'
}
status_rows() {
    COLUMNS=80 t_run 0 sbd_ui_status_row '核心: 未安装' '服务: 已停止' '托管节点: 0 个'
    t_contains "$CASE_TMP/output" '  核心: 未安装  |  服务: 已停止  |  托管节点: 0 个'
    COLUMNS=40 t_run 0 sbd_ui_status_row '核心: 未安装' '服务: 已停止' '托管节点: 0 个'
    t_assert '窄屏状态按完整字段换行' test "$(wc -l < "$CASE_TMP/output")" = 2
    t_contains "$CASE_TMP/output" '  核心: 未安装  |  服务: 已停止'
    t_contains "$CASE_TMP/output" '  托管节点: 0 个'
    t_assert '换行不留下悬空分隔符' test "$(tail -n 1 "$CASE_TMP/output")" = '  托管节点: 0 个'
}
status_table() {
    local cols
    for cols in 80 100; do
        COLUMNS="$cols" t_run 0 sbd_ui_status_table \
            '系统: Debian GNU/Linux 13 (trixie)' 'init: systemd' '' \
            '核心: 1.14.4' '服务: 运行中' '托管节点: 10 个' \
            '开机自启: 已开启' '配置: 已存在' '管理器: 0.1.0'
        t_assert '三行状态分隔符按显示列对齐' python3 - "$CASE_TMP/output" "$cols" <<'PY'
import sys, unicodedata
lines = open(sys.argv[1]).read().splitlines()
def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in s)
assert len(lines) == 3, lines
bars = [[width(line[:i]) for i, c in enumerate(line) if c == '|'] for line in lines]
assert bars[0][0] == bars[1][0] == bars[2][0], bars
assert bars[1][1] == bars[2][1], bars
assert all(width(line) <= int(sys.argv[2]) for line in lines), lines
PY
    done
    COLUMNS=40 t_run 0 sbd_ui_status_table \
        '系统: Debian GNU/Linux 13 (trixie)' 'init: systemd' '' \
        '核心: 未安装' '服务: 未知' '托管节点: 未知' \
        '开机自启: 已关闭' '配置: 未创建' '管理器: 0.1.0'
    t_contains "$CASE_TMP/output" '  系统: Debian GNU/Linux 13 (trixie)'
    t_contains "$CASE_TMP/output" '  init: systemd'
    t_contains "$CASE_TMP/output" '托管节点: 未知'
    t_assert '窄屏分隔符不悬空且不输出 ANSI' python3 - "$CASE_TMP/output" <<'PY'
import sys, unicodedata
text = open(sys.argv[1]).read()
assert '\x1b' not in text
for line in text.splitlines():
    assert not line.strip().startswith('|') and not line.strip().endswith('|'), line
    assert sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in line) <= 40, line
PY
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
    assert width == 26, (line, width)
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
short_option_spacing() {
    local cols
    for cols in 80 100; do
        COLUMNS="$cols" t_run 0 sbd_ui_options '[1] 添加原生竞速组' '[2] 删除竞速组' '[3] DNS' '[4] TLS'
        t_assert '短选项右列固定且至少间隔六个显示列' python3 - "$CASE_TMP/output" <<'PY'
import re, sys, unicodedata
lines = open(sys.argv[1]).read().splitlines()
assert len(lines) == 2, lines
for line in lines:
    items = list(re.finditer(r'\[\d+\]', line))
    assert len(items) == 2, line
    prefix = line[:items[1].start()]
    assert sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in prefix) == 26, line
    assert len(prefix) - len(prefix.rstrip()) >= 6, line
PY
    done
    COLUMNS=80 t_run 0 sbd_ui_options '[1] DNS' '[2] TLS' '[3] JSON 替换托管上游' '[4] 删除上游'
    t_assert '长短选项混合时整组单列、不再交错布局' test "$(wc -l < "$CASE_TMP/output")" = 4
    COLUMNS=80 t_run 0 sbd_ui_options '[1] DNS' '[2] TLS'
    t_assert '上一组的单列状态不泄漏到下一组' test "$(wc -l < "$CASE_TMP/output")" = 1
}
long_submenus() {
    t_fresh
    local menu count argument cols
    local -a command=()
    while read -r menu count argument; do
        command=("$menu")
        [[ -z "$argument" ]] || command+=("$argument")
        for cols in 40 80 100; do
            COLUMNS="$cols" t_run 0 "${command[@]}" <<< 0
            t_assert '真实长文案子菜单统一单列、编号与原文完整保留' python3 - "$CASE_TMP/output" "$count" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
lines = [line for line in text.splitlines() if re.search(r'\[\d+\]', line)]
assert len(lines) <= int(sys.argv[2]) + 1, lines
assert [int(n) for n in re.findall(r'\[(\d+)\]', text)] == list(range(1, int(sys.argv[2]) + 1)) + [0], text
assert all(re.match(r'^  \[\d+\] ', line) for line in lines), lines
assert '\x1b' not in text, text
if 'DNS 设置' in text:
    assert '[4] Cloudflare（DoH）' in text
    assert '[9] 恢复默认 DoH 竞速' in text
PY
        done
    done <<'MENUS'
sbd_resolver_menu 9
sbd_rules_menu 6
sbd_tls_menu 5
sbd_peers_menu 5
sbd_observe_menu 5
sbd_time_menu 4
sbd_maintenance_menu 6
sbd_engine_menu 6
sbd_export_menu 3
sbd_export_node_menu 2 fixture-node
MENUS
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
    t_run 1 sbd_ui_status_table '系统: Debian' 'init: systemd' ''
    t_contains "$CASE_TMP/output" '读取菜单显示宽度失败'
    t_absent "$CASE_TMP/output" '系统: Debian'
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
t_case '首个分组不叠加标题空行、其余分组间距不变' section_spacing
t_case '主菜单标题居中、窄屏不增加多余缩进' centered_title
t_case '子菜单标题用【】、向导字段提示紧排' compact_prompts
t_case '状态用分隔符紧凑排列、窄屏按字段换行' status_rows
t_case 'Debian 状态分隔符跨行对齐且窄屏完整换行' status_table
t_case '80/100 列双栏及中文对齐' column_layout
t_case '窄屏与长标签回退单列' narrow_layout
t_case '长项回退不改变后续编号配对' stable_pairs
t_case '短选项双列留足间隔、长短混排统一单列' short_option_spacing
t_case 'DNS/规则/证书/隧道/观测/维护/核心/链接真实菜单排版' long_submenus
t_case 'C/UTF-8 下截图中的中文标签按字节正确计宽' byte_widths
t_case '计宽工具失败明确返回错误、不继续错位渲染' width_failure
t_case '菜单标签不解释格式符或反斜杠' literal_labels
t_case '管道输入不清屏不暂停不吞编号' pipe_does_not_pause
t_case '真实终端标题与所有编号使用 Xray 配色' pty_case colors
t_case '真实终端系统/init 与状态值着色且标题置顶' pty_case status_colors
t_case '状态表 NO_COLOR 保留对齐与原始文本' pty_case status_no_color
t_case 'NO_COLOR 关闭颜色但保留清屏' pty_case no_color
t_case 'TERM=dumb 不清屏不暂停' pty_case dumb
t_case '详细状态等回车后重绘、子菜单返回不额外暂停' pty_case navigation
t_case '窄屏真实终端状态换行与连续编号导航' pty_case navigation_narrow
t_case '真实终端进入 DNS 后单列展示且返回保留首页双列' pty_case dns_layout
t_case '失败信息保持至回车、未假报成功' pty_case failure
t_case '暂停处 EOF 后退出且不循环重绘' pty_case eof
t_finish
