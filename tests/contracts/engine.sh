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
    sbd_service_process_running() { return 0; }
    t_assert 'OpenRC 自有进程在运行' test "$(sbd_service_state)" = running
    sbd_service_process_running() { return 1; }
    t_assert 'OpenRC crashed 或未知文本按无自有进程判定停止' test "$(sbd_service_state)" = stopped
}
service_render_alignment() {
    t_fresh
    sbd_go_memlimit_mb() { printf '40\n'; }
    sbd_service_render systemd "$CASE_TMP/systemd" || exit 1
    t_contains "$CASE_TMP/systemd" 'Documentation=https://sing-box.sagernet.org'
    t_contains "$CASE_TMP/systemd" 'Environment="GOMEMLIMIT=40MiB"'
    t_contains "$CASE_TMP/systemd" "ExecStart=$SBD_BINARY -D $SBD_ROOT -c $SBD_CONFIG run"
    t_contains "$CASE_TMP/systemd" 'ExecReload=/bin/kill -HUP $MAINPID'
    t_contains "$CASE_TMP/systemd" 'RestartSec=10s'
    t_contains "$CASE_TMP/systemd" 'LimitNOFILE=infinity'
    sbd_service_render openrc "$CASE_TMP/openrc" || exit 1
    t_contains "$CASE_TMP/openrc" 'export GOMEMLIMIT="40MiB"'
    t_contains "$CASE_TMP/openrc" 'extra_commands="checkconfig"'
    t_contains "$CASE_TMP/openrc" 'extra_started_commands="reload"'
    t_contains "$CASE_TMP/openrc" "--disable-color -D $SBD_ROOT -c $SBD_CONFIG"
    t_contains "$CASE_TMP/openrc" '"$command" check -D'
    t_contains "$CASE_TMP/openrc" '$supervisor "$RC_SVCNAME" --signal HUP'
    t_run 0 sh -n "$CASE_TMP/openrc"
}
t_case '未安装服务明确停止' absent_service
t_case 'systemd 运行、停止、未知三态' systemd_states
t_case '重启必须持续运行' restart_window
t_case 'stop 成功不等于已停止' stop_verified
t_case 'OpenRC 按自有进程判活，crashed 不报未知' openrc_states
t_case '服务定义与官方 systemd/OpenRC 对齐' service_render_alignment
control_fixture() {
    service_fixture
    cp -- "$ROOT/tests/fixtures/valid.json" "$SBD_CONFIG" || exit 1
    t_prepare_live || exit 1
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
t_case '首页重启停止和自启直达真实加锁控制与复验' direct_controls
t_finish
