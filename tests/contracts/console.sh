#!/usr/bin/env bash
# ROOT 来自 harness；加载锁的路径桩由真实入口调用。
# shellcheck disable=SC2153,SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

empty_menu() {
    t_fresh
    t_run 0 sbd_dispatch 17 <<< 0
    t_contains "$CASE_TMP/output" '日志设置'
    t_run 0 sbd_dispatch 18 <<< 0
    t_contains "$CASE_TMP/output" '脚本维护'
    t_run 0 sbd_dispatch 19 <<< 0
    t_contains "$CASE_TMP/output" '核心管理'
    t_run 0 sbd_dispatch 5 <<< 0
    t_contains "$CASE_TMP/output" '节点链接'
    t_run 0 sbd_dispatch 8 <<< 0
    t_contains "$CASE_TMP/output" '证书管理'
    t_run 0 sbd_dispatch 2
    t_contains "$CASE_TMP/output" '暂无节点'
    t_run 0 sbd_dispatch 7 <<< 0
    t_contains "$CASE_TMP/output" '分流设置'
    t_run 0 sbd_dispatch 6 <<< 0
    t_contains "$CASE_TMP/output" 'DNS 设置'
    t_run 0 sbd_dispatch 9 <<< 0
    t_contains "$CASE_TMP/output" '隧道管理'
    t_run 2 sbd_dispatch 1 < /dev/null
    t_contains "$CASE_TMP/output" '添加节点'
    t_run 1 sbd_dispatch 3 < /dev/null
    t_contains "$CASE_TMP/output" '暂无可选择资料'
    t_run 1 sbd_dispatch 4 < /dev/null
    t_contains "$CASE_TMP/output" '暂无可选择资料'
    t_run 2 sbd_dispatch 20 <<< $'1\nn'
    t_absent "$CASE_TMP/output" '[成功]'
    t_assert '卸载预览取消保留部署文件' test -f "$SBD_APP/manifest.txt"
}
check_menu() {
    t_seed
    t_run 0 sbd_dispatch 16
    t_contains "$CASE_TMP/output" '未验证网络连通'
    printf '{broken' > "$SBD_CONFIG" || exit 1
    t_run 1 sbd_dispatch 16
    t_absent "$CASE_TMP/output" '[成功]'
}
cancel_menu() {
    t_fresh
    t_run 0 sbd_console <<< 0
    t_run 0 sbd_console < /dev/null
    t_assert '取消不初始化配置' test ! -e "$SBD_CONFIG"
}
entry_arguments() {
    t_run 0 bash "$ROOT/singbox-deploy.sh" --help
    t_contains "$CASE_TMP/output" sd
    t_run 0 bash "$ROOT/singbox-deploy.sh" --version
    t_contains "$CASE_TMP/output" 0.1.0
    t_run 1 bash "$ROOT/singbox-deploy.sh" unknown
    t_run 1 bash "$ROOT/singbox-deploy.sh"
    t_contains "$CASE_TMP/output" '源码目录不是部署目录'
    t_run 1 bash "$ROOT/singbox-deploy.sh" --version unexpected
}
loader_lock() {
    t_fresh
    . "$SBD_APP/singbox-deploy.sh"
    sbd_loader_lock_path() { printf '%s\n' "$SBD_LOCK"; }
    sbd_cli_require_root() { return 0; }
    exec {held}>"$SBD_LOCK" || exit 1
    flock -n "$held" || exit 1
    t_run 1 sbd_bootstrap
    t_contains "$CASE_TMP/output" '正在进行'
}
status_fixture() {
    t_fresh
    sbd_backend() { printf 'systemd\n'; }
    sbd_service_file() { printf '%s/unit\n' "$CASE_TMP"; }
    sbd_service_render systemd "$CASE_TMP/unit" || exit 1
    printf 'running\n' > "$CASE_TMP/runtime" || exit 1
    printf 'enabled\n' > "$CASE_TMP/enabled" || exit 1
    systemctl() {
        case "$1" in
            show)
                if [[ "$(cat "$CASE_TMP/runtime")" = running ]]; then printf 'ActiveState=active\nSubState=running\nMainPID=123\n'
                else printf 'ActiveState=inactive\nSubState=dead\nMainPID=0\n'; fi ;;
            is-enabled) cat "$CASE_TMP/enabled"; [[ "$(cat "$CASE_TMP/enabled")" = enabled ]] ;;
            *) return 1 ;;
        esac
    }
}
status_contract() {
    status_fixture
    cp "$SBD_STATE" "$CASE_TMP/state" || exit 1
    t_run 0 sbd_status
    t_contains "$CASE_TMP/output" '服务: 运行中'
    t_contains "$CASE_TMP/output" '开机自启: 已开启'
    t_contains "$CASE_TMP/output" '托管节点: 0 个'
    t_contains "$CASE_TMP/output" '事务: 无待处理现场'
    t_contains "$CASE_TMP/output" '日志命令: journalctl -u singbox-deploy'
    t_contains "$CASE_TMP/output" "$SBD_CONFIG"
    t_contains "$CASE_TMP/output" "$SBD_EXPORTS"
    t_absent "$CASE_TMP/output" '当前阶段'
    printf 'stopped\n' > "$CASE_TMP/runtime" || exit 1
    printf 'disabled\n' > "$CASE_TMP/enabled" || exit 1
    t_run 0 sbd_console <<< 0
    t_contains "$CASE_TMP/output" '服务: 已停止'
    t_contains "$CASE_TMP/output" '开机自启: 已关闭'
    t_assert '主菜单摘要不写 state' cmp -s "$SBD_STATE" "$CASE_TMP/state"
    t_assert '主菜单摘要不初始化配置' test ! -e "$SBD_CONFIG"
}
status_unknown() {
    status_fixture
    systemctl() { return 1; }
    t_run 1 sbd_status
    t_contains "$CASE_TMP/output" '服务: 未知'
    t_contains "$CASE_TMP/output" '开机自启: 未知'
    t_absent "$CASE_TMP/output" '已停止'
    t_absent "$CASE_TMP/output" '[成功]'
    t_run 0 sbd_console <<< 0
    t_contains "$CASE_TMP/output" '状态摘要读取不完整'
    t_contains "$CASE_TMP/output" '[18] 脚本维护'
    printf '{bad' > "$SBD_REGISTRY" || exit 1
    t_run 1 sbd_status
    t_contains "$CASE_TMP/output" '托管节点: 未知'
    t_absent "$CASE_TMP/output" '托管节点: 0'
}
status_pending() {
    status_fixture
    mkdir -p "$SBD_WORK/active" || exit 1
    printf '{"kind":"config","phase":"pending"}\n' > "$SBD_WORK/active/journal.json" || exit 1
    t_run 0 sbd_status
    t_contains "$CASE_TMP/output" 'config 未完成，待恢复'
    t_assert '摘要不自动执行恢复' test -d "$SBD_WORK/active"
    printf '{"kind":"config","phase":"accepted"}\n' > "$SBD_WORK/active/journal.json" || exit 1
    t_run 0 sbd_status
    t_contains "$CASE_TMP/output" 'config 已接受，待完成收尾'
    printf '{}\n' > "$SBD_WORK/active/journal.json" || exit 1
    t_run 1 sbd_status
    t_contains "$CASE_TMP/output" '未知现场'
    t_assert '坏恢复现场不被状态页删除' test -d "$SBD_WORK/active"
}
status_log_path() {
    status_fixture
    printf '{"log":{"disabled":true,"output":"custom.log"}}\n' > "$SBD_CONFIG" || exit 1
    t_run 0 sbd_status
    t_contains "$CASE_TMP/output" '已禁用'
    t_contains "$CASE_TMP/output" "$SBD_ROOT/custom.log"
    t_absent "$CASE_TMP/output" '日志命令:'
}
direct_logs() {
    t_seed
    sbd_backend() { printf 'openrc\n'; }
    printf 'homepage-native-log\n' > "$SBD_LOG" || exit 1
    t_run 0 sbd_dispatch 13
    t_contains "$CASE_TMP/output" homepage-native-log
    t_contains "$CASE_TMP/output" "$SBD_LOG"
    t_absent "$CASE_TMP/output" '请选择'
    rm -- "$SBD_LOG" || exit 1
    t_run 1 sbd_dispatch 13
    t_contains "$CASE_TMP/output" '日志文件尚不存在'
    t_absent "$CASE_TMP/output" '[成功]'
}
t_case '菜单编号分派到已交付模块' empty_menu
t_case '检查菜单不假报成功' check_menu
t_case '菜单退出与 EOF 无副作用' cancel_menu
t_case '入口参数与源码/部署边界' entry_arguments
t_case '加载模块与安装发布使用同一把锁' loader_lock
t_case '主菜单真实读取服务/自启及节点数，不创建配置' status_contract
t_case '服务/自启/登记读取失败显示未知而非假停止' status_unknown
t_case '状态摘要区分待恢复/待收尾，不自动改事务现场' status_pending
t_case '状态摘要按实际 log.output 显示路径与禁用事实' status_log_path
t_case '首页查看日志直接读取真实文件、缺失不假报成功' direct_logs
t_finish
