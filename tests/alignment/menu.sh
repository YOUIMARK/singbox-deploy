#!/usr/bin/env bash
# 服务状态是窄桩；菜单、事实读取和选择器均运行真实函数。
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

menu_fixture() {
    t_fresh
    sbd_service_state() { printf 'stopped\n'; }
    sbd_service_enabled() { printf 'disabled\n'; }
    sbd_backend() { printf 'openrc\n'; }
}
main_numbers() {
    menu_fixture
    cp "$SBD_STATE" "$CASE_TMP/state-before" || exit 1
    cp "$SBD_REGISTRY" "$CASE_TMP/registry-before" || exit 1
    COLUMNS=80 t_run 0 sbd_console <<< 0
    local number
    for number in {0..20}; do
        t_assert "主菜单编号 $number 只出现一次" test "$(grep -oF "[$number]" "$CASE_TMP/output" | wc -l)" = 1
    done
    t_contains "$CASE_TMP/output" '【节点管理】'
    t_contains "$CASE_TMP/output" '【网络设置】'
    t_contains "$CASE_TMP/output" '【服务控制】'
    t_contains "$CASE_TMP/output" '【配置与维护】'
    t_contains "$CASE_TMP/output" '【核心管理】'
    t_contains "$CASE_TMP/output" '系统: '
    t_contains "$CASE_TMP/output" 'init: openrc'
    t_absent "$CASE_TMP/output" '--------'
    t_absent "$CASE_TMP/output" "$SBD_CONFIG"
    t_absent "$CASE_TMP/output" "$SBD_EXPORTS"
    t_absent "$CASE_TMP/output" "$SBD_LOG"
    t_absent "$CASE_TMP/output" '事务: 无待处理现场'
    t_assert '主菜单编号按阅读顺序递增、组间留白且右列固定' python3 - "$CASE_TMP/output" <<'PY'
import sys, unicodedata, re
text = open(sys.argv[1]).read()
assert [int(n) for n in re.findall(r'\[(\d+)\]', text)] == list(range(1, 21)) + [0]
labels = ['添加节点', '查看节点', '修改节点', '删除节点', '节点链接',
          'DNS 设置', '分流设置', '证书管理', '隧道管理',
          '重启服务', '停止服务', '查看状态', '查看日志', '启用自启', '关闭自启',
          '检查配置', '日志与监控', '脚本维护', 'sing-box 核心管理', '卸载脚本']
for number, label in enumerate(labels, 1):
    assert f'[{number}] {label}' in text
for old in ('部署状态', '独立 DNS', '分享与客户端资料', '维护与显式协调', '原生观测'):
    assert old not in text
assert '\n\n  【节点管理】\n' in text
assert '\n\n  【服务控制】\n' in text
assert '\n\n  [0] 退出\n' in text
assert '核心: ' in next(line for line in text.splitlines() if '  |  服务:' in line)
for item in ('[2]', '[4]', '[7]', '[9]', '[11]', '[13]', '[15]', '[17]', '[20]'):
    line = next(line for line in text.splitlines() if item in line)
    prefix = line[:line.index(item)]
    width = sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in prefix)
    assert width == 26, (item, width, line)
PY
    t_run 0 sbd_dispatch 12
    t_contains "$CASE_TMP/output" "$SBD_CONFIG"
    t_contains "$CASE_TMP/output" "$SBD_EXPORTS"
    t_contains "$CASE_TMP/output" "$SBD_LOG"
    t_assert '状态页不写 state' cmp -s "$SBD_STATE" "$CASE_TMP/state-before"
    t_assert '状态页不写 registry' cmp -s "$SBD_REGISTRY" "$CASE_TMP/registry-before"
    t_assert '不初始化业务配置' test ! -e "$SBD_CONFIG"
}
unknown_brief() {
    menu_fixture
    sbd_service_state() { return 1; }
    sbd_service_enabled() { return 1; }
    t_run 1 sbd_status brief
    t_contains "$CASE_TMP/output" '服务: 未知'
    t_contains "$CASE_TMP/output" '开机自启: 未知'
    t_absent "$CASE_TMP/output" '已停止'
    t_absent "$CASE_TMP/output" '[成功]'
    printf '{bad' > "$SBD_REGISTRY" || exit 1
    t_run 0 sbd_console <<< 0
    t_contains "$CASE_TMP/output" '托管节点: 未知'
    t_contains "$CASE_TMP/output" '状态摘要读取不完整'
    t_contains "$CASE_TMP/output" '[18] 脚本维护'
}
pending_brief() {
    menu_fixture
    mkdir -p "$SBD_WORK/active" || exit 1
    local phase
    for phase in pending accepted; do
        printf '{"kind":"config","phase":"%s"}\n' "$phase" > "$SBD_WORK/active/journal.json" || exit 1
        cp "$SBD_WORK/active/journal.json" "$CASE_TMP/journal" || exit 1
        t_run 0 sbd_status brief
        if [[ "$phase" = pending ]]; then t_contains "$CASE_TMP/output" 'config 未完成，待恢复'
        else t_contains "$CASE_TMP/output" 'config 已接受，待完成收尾'; fi
        t_assert '摘要不恢复或修改事务记录' cmp -s "$SBD_WORK/active/journal.json" "$CASE_TMP/journal"
    done
    printf '{}\n' > "$SBD_WORK/active/journal.json" || exit 1
    t_run 1 sbd_status brief
    t_contains "$CASE_TMP/output" '事务: 未知现场'
    t_assert '坏现场仍保留' test -d "$SBD_WORK/active"
}
selectors_literal() {
    menu_fixture
    local values='[{"id":"node.one","name":"100% \\n 节点"},{"id":"node.two","name":"第二个"}]'
    t_run 0 sbd_entry_choose "$values" 选择 <<< 2
    t_assert '选择器保持稳定 ID' test "$SBD_REPLY" = node.two
    t_contains "$CASE_TMP/output" '[1] 100% \n 节点 (node.one)'
    t_contains "$CASE_TMP/output" '[2] 第二个 (node.two)'
    t_run 0 sbd_policy_pick '["system","remote"]' 上游 <<< 1
    t_assert '策略选择返回原值' test "$SBD_REPLY" = system
    t_contains "$CASE_TMP/output" '[1] system'
}
numbered_navigation() {
    menu_fixture
    local number title
    while IFS='|' read -r number title; do
        t_run 0 sbd_console <<< "$(printf '%s\n0\n0\n' "$number")"
        t_contains "$CASE_TMP/output" "  $title"
        t_assert '输入编号确实进入相应子菜单' test "$(grep -Fc "  $title" "$CASE_TMP/output")" = 1
    done <<'MENUS'
5|节点链接
6|DNS 设置
7|分流设置
8|证书管理
9|隧道管理
17|日志与监控
18|脚本维护
19|核心管理
MENUS
}
host_unknown() {
    menu_fixture
    sbd_system_label() { _error '注入系统名称读取失败'; return 1; }
    sbd_backend() { _error '注入 init 检测失败'; return 1; }
    t_run 1 sbd_status brief
    t_contains "$CASE_TMP/output" '系统: 未知'
    t_contains "$CASE_TMP/output" 'init: 未知'
    t_absent "$CASE_TMP/output" '[成功]'
    t_run 0 sbd_console <<< 0
    t_contains "$CASE_TMP/output" '状态摘要读取不完整'
    t_contains "$CASE_TMP/output" '[18] 脚本维护'
}
t_case '主菜单顺序编号、分组留白、状态分隔且详细状态只读' main_numbers
t_case '精简摘要保留未知状态和失败返回码' unknown_brief
t_case '精简摘要不隐藏待恢复、待收尾或未知现场' pending_brief
t_case '动态选择列表样式统一且保持标签和稳定 ID' selectors_literal
t_case '按首页新编号真实进入全部子菜单、旧子菜单编号不变' numbered_navigation
t_case '系统与 init 读取失败显示未知、仍可进入维护' host_unknown
t_finish
