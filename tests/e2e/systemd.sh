#!/usr/bin/env bash
# 必须显式授权；只创建唯一命名的临时 unit，不操作生产 singbox-deploy。
# shellcheck disable=SC2329,SC2034
set -u
umask 077
[[ "${1:-}" = --allow-system-service && "$EUID" = 0 ]] || {
    printf '需要 root 并显式传入 --allow-system-service；本脚本会临时创建 systemd unit\n' >&2; exit 1;
}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
for rel in lib/input.sh lib/host.sh lib/records.sh lib/schema.sh lib/engine.sh lib/apply.sh; do . "$ROOT/$rel" || exit 1; done
[[ -x "${SBD_TEST_BIN:-}" ]] || { _error '请设置真实 Linux SBD_TEST_BIN'; exit 1; }
scratch=$(mktemp -d /tmp/singbox-systemd-e2e.XXXXXX) || exit 1
sbd_paths "$scratch" "$scratch/test.lock" "$scratch/sd" || exit 1
SBD_SERVICE="singbox-deploy-e2e-$$"
unit="/run/systemd/system/$SBD_SERVICE.service"
sbd_service_file() { printf '%s\n' "$unit"; }
sbd_logrotate_file() { printf '%s/logrotate\n' "$scratch"; }
cleanup() {
    local rc=0
    if [[ -f "$unit" ]]; then
        systemctl stop "$SBD_SERVICE" || rc=1
        systemctl disable "$SBD_SERVICE" || rc=1
        systemctl reset-failed "$SBD_SERVICE" >/dev/null 2>&1 || :
        rm -f -- "$unit" || rc=1
        systemctl daemon-reload || rc=1
    fi
    case "$scratch" in /tmp/singbox-systemd-e2e.*) rm -rf -- "$scratch" || rc=1 ;; *) rc=1 ;; esac
    [[ "$rc" = 0 ]] || { _error '临时服务清理未完成'; return 1; }
}
trap 'cleanup || exit 1' EXIT
PASS=0
pass() { PASS=$((PASS + 1)); printf 'E2E 通过: %s\n' "$1"; }
need() { "$@" || { _error 'E2E 断言失败'; exit 1; }; }
need test ! -e "$unit"
need sbd_directories
need mkdir -p "$SBD_APP/support" "$SBD_APP/presets" "$scratch/candidate/engine"
need cp "$ROOT/support/validate_schema.py" "$SBD_APP/support/"
need cp "$ROOT/presets/base.json" "$SBD_APP/presets/"
need cp -a "${SBD_TEST_BIN%/*}/." "$scratch/candidate/engine/"
need sbd_record_write "$SBD_STATE" '{"format":1,"revision":0,"manager_version":"0.1.0"}'
need sbd_record_write "$SBD_REGISTRY" '{"format":1,"nodes":[]}'
printf '1.14.4\n' > "$scratch/candidate/version" || exit 1
printf 'sing-box-1.14.4-linux-amd64.tar.gz\n' > "$scratch/candidate/asset" || exit 1
need sbd_engine_commit "$scratch/candidate"
need test "$(sbd_service_state)" = stopped
need test "$(sbd_service_enabled)" = enabled
pass '真实首次安装默认自启且保持停止'
need systemd-analyze verify "$unit"
pass '生成的真实 systemd unit 验证'
need sbd_write_lock sbd_engine_control_locked restart
pid=$(systemctl show "$SBD_SERVICE" -p MainPID --value) || exit 1
need test "$(readlink "/proc/$pid/exe")" = "$SBD_BINARY"
pass '真实 systemd 启动目标核心进程'
need sbd_engine_commit "$scratch/candidate"
new_pid=$(systemctl show "$SBD_SERVICE" -p MainPID --value) || exit 1
need test "$pid" != "$new_pid"
need test ! -e "/proc/$pid/exe"
need test "$(readlink "/proc/$new_pid/exe")" = "$SBD_BINARY"
pass '真实运行中升级退出旧进程并运行新核心'
need cp "$SBD_STATE" "$scratch/state-before"
need cp "$SBD_CONFIG" "$scratch/config-before"
mv() {
    if [[ "${!#}" = "$SBD_STATE" && ! -f "$scratch/injected" ]]; then : > "$scratch/injected"; return 1; fi
    command mv "$@"
}
rc=0
sbd_engine_commit "$scratch/candidate" || rc=$?
need test "$rc" = 1
unset -f mv
need cmp -s "$SBD_STATE" "$scratch/state-before"
need cmp -s "$SBD_CONFIG" "$scratch/config-before"
need test "$(sbd_service_state)" = running
need test "$(sbd_service_enabled)" = enabled
pass '真实服务中 state 提交失败恢复旧文件和运行态'
need sbd_write_lock sbd_engine_control_locked stop
need test "$(sbd_service_state)" = stopped
need sbd_engine_stopped
pass '真实服务停止及进程退出确认'
need sbd_service_render openrc "$scratch/openrc.init"
need sh -n "$scratch/openrc.init"
need sbd_logrotate_render "$scratch/logrotate.conf"
need logrotate -d "$scratch/logrotate.conf"
need python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"x"*1100000)' "$SBD_LOG"
need logrotate -f -s "$scratch/logrotate.state" "$scratch/logrotate.conf"
need test -f "$SBD_LOG.1.gz"
pass '真实 logrotate 按配置轮换临时日志'
printf 'E2E RESULT passed=%s failed=0\n' "$PASS"
