#!/usr/bin/env bash
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

service_fixture() {
    t_fresh
    sbd_backend() { printf 'systemd\n'; }
    sbd_service_file() { printf '%s/unit\n' "$CASE_TMP"; }
    printf 'ExecStart=%s run -c %s -D %s\n' "$SBD_BINARY" "$SBD_CONFIG" "$SBD_ROOT" > "$CASE_TMP/unit" || exit 1
    systemctl() {
        case "$1" in
            show) cat "$CASE_TMP/runtime" ;;
            restart|stop) printf '%s\n' "$1" >> "$CASE_TMP/actions" ;;
            *) return 1 ;;
        esac
    }
    printf 'ActiveState=active\nSubState=running\nMainPID=123\n' > "$CASE_TMP/runtime" || exit 1
    sleep() { :; }
}
absent_service() {
    service_fixture
    rm "$CASE_TMP/unit" || exit 1
    t_assert '未创建服务不是运行中' test "$(sbd_service_state)" = stopped
}
systemd_states() {
    service_fixture
    t_assert '读取运行态' test "$(sbd_service_state)" = running
    printf 'ActiveState=failed\nSubState=failed\nMainPID=0\n' > "$CASE_TMP/runtime" || exit 1
    t_assert '读取明确停止态' test "$(sbd_service_state)" = stopped
    printf 'ActiveState=activating\nSubState=start\nMainPID=0\n' > "$CASE_TMP/runtime" || exit 1
    t_run 1 sbd_service_state
}
foreign_unit() {
    service_fixture
    printf 'ExecStart=/other/sing-box run\n' > "$CASE_TMP/unit" || exit 1
    t_run 1 sbd_service_state
    t_run 1 sbd_service_action stop
    t_assert '不操作外来同名服务' test ! -e "$CASE_TMP/actions"
}
restart_window() {
    service_fixture
    t_run 0 sbd_service_restore running
    t_contains "$CASE_TMP/actions" restart
    printf 'ActiveState=failed\nSubState=failed\nMainPID=0\n' > "$CASE_TMP/runtime" || exit 1
    t_run 1 sbd_service_restore running
    t_contains "$CASE_TMP/output" '未持续运行'
}
stop_verified() {
    service_fixture
    t_run 1 sbd_service_restore stopped
    t_contains "$CASE_TMP/actions" stop
    t_contains "$CASE_TMP/output" '未停止'
    printf 'ActiveState=inactive\nSubState=dead\nMainPID=0\n' > "$CASE_TMP/runtime" || exit 1
    t_run 0 sbd_service_restore stopped
}
openrc_states() {
    t_fresh
    sbd_backend() { printf 'openrc\n'; }
    sbd_service_file() { printf '%s/unit\n' "$CASE_TMP"; }
    printf 'command="%s"\ncommand_args="run -c %s -D %s"\n' "$SBD_BINARY" "$SBD_CONFIG" "$SBD_ROOT" > "$CASE_TMP/unit" || exit 1
    rc-service() { printf ' * status: started\n'; }
    t_assert 'OpenRC started' test "$(sbd_service_state)" = running
    rc-service() { printf ' * status: stopped\n'; return 3; }
    t_assert 'OpenRC stopped' test "$(sbd_service_state)" = stopped
    rc-service() { printf 'not started\n'; }
    t_run 1 sbd_service_state
    rc-service() { printf 'unknown\n'; return 1; }
    t_run 1 sbd_service_state
}
no_inherited_lock() {
    service_fixture
    action() { printf '%s' "$SBD_WRITE_FD" > "$CASE_TMP/fd"; sbd_service_action restart; }
    systemctl() {
        local fd
        fd=$(cat "$CASE_TMP/fd") || return 1
        [[ ! -e "/proc/$BASHPID/fd/$fd" ]] || return 1
        # 父进程仍应持锁；关闭子进程 fd 不等于提前释放父进程锁。
        if flock -n "$SBD_LOCK" true; then return 1; fi
    }
    t_run 0 sbd_write_lock action
}
t_case '未安装服务明确停止' absent_service
t_case 'systemd 运行、停止、未知三态' systemd_states
t_case '外来同名服务拒绝操作' foreign_unit
t_case '重启必须持续运行' restart_window
t_case 'stop 成功不等于已停止' stop_verified
t_case 'OpenRC 状态与失败可见' openrc_states
t_case '服务子进程不继承写锁' no_inherited_lock
menu_cancel() {
    t_fresh
    t_run 0 sbd_engine_menu <<< 0
    t_assert '核心菜单标题只打印一次，不随 printf 参数重复' test "$(grep -Fc '核心管理' "$CASE_TMP/output")" = 1
    t_run 0 sbd_engine_menu < /dev/null
    t_assert '取消不装核心' test ! -e "$SBD_ENGINE/sing-box"
}
t_case '核心菜单退出与 EOF 不安装核心' menu_cancel
control_fixture() {
    service_fixture
    cp -- "$ROOT/tests/fixtures/valid.json" "$SBD_CONFIG" || exit 1
    sbd_prepare_config "$SBD_CONFIG_DIR" || exit 1
    printf 'disabled\n' > "$CASE_TMP/enabled" || exit 1
    systemctl() {
        printf '%s\n' "$1" >> "$CASE_TMP/actions"
        case "$1" in
            show) cat "$CASE_TMP/runtime" ;;
            restart) printf 'ActiveState=active\nSubState=running\nMainPID=123\n' > "$CASE_TMP/runtime" ;;
            stop) printf 'ActiveState=inactive\nSubState=dead\nMainPID=0\n' > "$CASE_TMP/runtime" ;;
            is-enabled) cat "$CASE_TMP/enabled"; [[ "$(cat "$CASE_TMP/enabled")" = enabled ]] ;;
            enable) printf 'enabled\n' > "$CASE_TMP/enabled" ;;
            disable) printf 'disabled\n' > "$CASE_TMP/enabled" ;;
            *) return 1 ;;
        esac
    }
}
direct_controls() {
    control_fixture
    cp "$SBD_STATE" "$CASE_TMP/state-before" || exit 1
    t_run 0 sbd_dispatch 11
    t_assert '首页停止确实确认运行态' test "$(sbd_service_state)" = stopped
    t_contains "$CASE_TMP/output" '已确认服务停止'
    t_run 0 sbd_dispatch 10
    t_assert '首页重启确实确认运行态' test "$(sbd_service_state)" = running
    t_contains "$CASE_TMP/output" '服务已持续运行'
    t_run 0 sbd_dispatch 14
    t_assert '首页启用自启复验' test "$(sbd_service_enabled)" = enabled
    t_run 0 sbd_dispatch 15
    t_assert '首页关闭自启复验' test "$(sbd_service_enabled)" = disabled
    t_assert '服务入口不伪造配置修订' cmp -s "$SBD_STATE" "$CASE_TMP/state-before"
    t_run 1 sbd_engine_control unsupported
    t_contains "$CASE_TMP/output" '核心控制动作无效'
}
direct_restart_failure() {
    control_fixture
    printf '{bad' > "$SBD_CONFIG" || exit 1
    : > "$CASE_TMP/actions"
    t_run 1 sbd_dispatch 10
    t_contains "$CASE_TMP/output" '服务操作未完成'
    t_absent "$CASE_TMP/output" '[成功]'
    t_absent "$CASE_TMP/actions" restart
    t_absent "$CASE_TMP/actions" stop
}
direct_control_failure() {
    control_fixture
    sbd_service_restore() { _error '注入服务控制失败'; return 1; }
    t_run 1 sbd_dispatch 11
    t_contains "$CASE_TMP/output" '服务操作未完成'
    t_absent "$CASE_TMP/output" '[成功]'
    exec {held}>"$SBD_LOCK" || exit 1
    flock -n "$held" || exit 1
    t_run 1 sbd_dispatch 14
    t_contains "$CASE_TMP/output" '另一个操作'
    t_absent "$CASE_TMP/output" '[成功]'
}
t_case '首页重启停止和自启直达真实加锁控制与复验' direct_controls
t_case '首页重启前真实 Schema/check 失败不操作服务' direct_restart_failure
t_case '首页服务控制失败或锁冲突明确报错、不假报成功' direct_control_failure
t_finish
