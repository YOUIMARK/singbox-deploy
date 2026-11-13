#!/usr/bin/env bash
# 服务边界窄桩只操作 CASE_TMP 内的文件，不触碰宿主 unit/runlevel。
# shellcheck disable=SC2329,SC2016,SC2153
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/peers.sh"

u_seed() {
    t_policy_seed
    SBD_BINARY="$SBD_BIN_DIR/sing-box"
    cp "$SBD_TEST_BIN" "$SBD_BINARY" || exit 1
    printf 'sing-box\n' > "$SBD_BIN_DIR/.sbd-files" || exit 1
    ln -s "$SBD_APP/singbox-deploy.sh" "$SBD_COMMAND" || exit 1
    mkdir "$CASE_TMP/etc" || exit 1
    sbd_backend() { printf 'systemd\n'; }
    sbd_service_file() { printf '%s/etc/service\n' "$CASE_TMP"; }
    sbd_logrotate_file() { printf '%s/etc/logrotate\n' "$CASE_TMP"; }
    sbd_service_set_enabled() { printf '%s\n' "$1" > "$CASE_TMP/enabled"; }
    sbd_service_reload() { printf 'reload\n' >> "$CASE_TMP/actions"; }
    sbd_service_render systemd "$CASE_TMP/etc/service" || exit 1
}
uninstall_keep() {
    u_seed
    printf 'unknown user file\n' > "$SBD_APP/user-notes.txt" || exit 1
    local plan
    plan=$(sbd_uninstall_plan keep) || exit 1
    t_run 0 sbd_write_lock sbd_uninstall_locked keep "$plan"
    t_assert '保留原路径配置和数据' test -s "$SBD_CONFIG"
    t_assert '保留模式保留配置目录' test -d "$SBD_CONF_DIR"
    t_assert '服务定义和命令已删除' test ! -e "$CASE_TMP/etc/service"
    t_assert '命令链接不存在' test ! -L "$SBD_COMMAND"
    t_assert '核心已移除' test ! -e "$SBD_BINARY"
    t_contains "$SBD_APP/user-notes.txt" 'unknown user'
    t_assert '卸载事实写入 state' jq -e '.installed==false' "$SBD_STATE"
    t_assert 'keep 模式仍清空临时 work 目录' test ! -e "$SBD_WORK"
}
uninstall_purge() {
    u_seed
    local value
    value=$(jq --arg dir "$SBD_STATE_DIR/tailscale/legacy" '.state_directory=$dir' "$ROOT/tests/fixtures/endpoint-tailscale.json") || exit 1
    jq --argjson value "$value" '.endpoints=[$value]' "$SBD_CONFIG" > "$CASE_TMP/legacy" || exit 1
    cp "$CASE_TMP/legacy" "$SBD_CONFIG" || exit 1
    local dir plan
    dir=$(jq -r '.endpoints[0].state_directory' "$SBD_CONFIG") || exit 1
    mkdir -p "$dir/Taildrop" || exit 1
    printf 'fixture native state\n' > "$dir/state" || exit 1
    printf 'unknown user file\n' > "$SBD_ROOT/user-notes.txt" || exit 1
    printf 'unknown config file\n' > "$SBD_CONF_DIR/user-notes.txt" || exit 1
    printf '{"log":{"level":"warn"}}\n' > "$SBD_CONF_DIR/01_log.json" || exit 1
    printf '{"log":{"level":"warn"}}\n' > "$SBD_CONF_DIR/00_base.json" || exit 1
    printf 'external keep\n' > "$CASE_TMP/external.pem" || exit 1
    mkdir -p "$SBD_STATE_DIR/tailscale/user-unmanaged" || exit 1
    printf 'unmanaged state\n' > "$SBD_STATE_DIR/tailscale/user-unmanaged/state" || exit 1
    mkdir -p -- "$SBD_ROOT/run" || exit 1
    printf 'lock\n' > "$SBD_LOCK" || exit 1
    jq --arg path "$SBD_STATE_DIR/tailscale/user-unmanaged" '.endpoints += [{type:"tailscale",tag:"user-unmanaged",state_directory:$path}]' "$SBD_CONFIG" > "$CASE_TMP/custom" || exit 1
    cp "$CASE_TMP/custom" "$SBD_CONFIG" || exit 1
    plan=$(sbd_uninstall_plan purge) || exit 1
    t_run 0 sbd_write_lock sbd_uninstall_locked purge "$plan"
    t_assert '已移除的功能不再授予认证数据删除权' test -s "$dir/state"
    t_assert '清除单配置文件' test ! -e "$SBD_CONFIG"
    t_assert '清除同目录 Schema' test ! -e "$SBD_SCHEMA"
    t_assert '清除已登记的旧分片' test ! -e "$SBD_CONF_DIR/01_log.json"
    t_assert '清除旧布局分片' test ! -e "$SBD_CONF_DIR/00_base.json"
    t_contains "$SBD_CONF_DIR/user-notes.txt" 'unknown config file'
    t_assert '清除状态' test ! -e "$SBD_STATE"
    t_assert '清除部署私有写锁' test ! -e "$SBD_LOCK"
    t_contains "$SBD_ROOT/user-notes.txt" 'unknown user'
    t_contains "$CASE_TMP/external.pem" 'external keep'
    t_contains "$SBD_STATE_DIR/tailscale/user-unmanaged/state" 'unmanaged state'
}
uninstall_failure() {
    u_seed
    local plan
    plan=$(sbd_uninstall_plan keep) || exit 1
    sbd_engine_stopped() { _error 'fixture stop failure'; return 1; }
    t_run 1 sbd_write_lock sbd_uninstall_locked keep "$plan"
    t_assert '未确认停止不删除入口或服务' test -L "$SBD_COMMAND"
    t_assert '未确认停止不删除服务定义' test -f "$CASE_TMP/etc/service"
    t_assert '保留可重试清单' test -f "$SBD_STATE_DIR/uninstall.json"
}
history_engine() {
    u_seed
    mkdir -p "$CASE_TMP/candidate/engine" || exit 1
    cp "$SBD_TEST_BIN" "$CASE_TMP/candidate/engine/sing-box" || exit 1
    printf 'old-library\n' > "$SBD_BIN_DIR/libcronet.so" || exit 1
    printf 'new-library\n' > "$CASE_TMP/candidate/engine/libcronet.so" || exit 1
    printf '1.14.4\n' > "$CASE_TMP/candidate/version" || exit 1
    printf 'sing-box-1.14.4-linux-amd64.tar.gz\n' > "$CASE_TMP/candidate/asset" || exit 1
    sbd_service_enabled() { printf 'disabled\n'; }
    t_run 0 sbd_engine_commit "$CASE_TMP/candidate"
    t_contains "$SBD_BIN_DIR/libcronet.so" new-library
    t_run 0 sbd_history_restore
    t_contains "$SBD_BIN_DIR/libcronet.so" old-library
    t_run 0 sbd_check_config
}
t_case '保留模式卸载运行文件，原路径数据与未知文件保留' uninstall_keep
t_case '明确 purge 只清已知自有数据，外部/未知文件保留' uninstall_purge
t_case '卸载停止失败保留入口和可重试记录' uninstall_failure
t_case '恢复最近核心事务的包/配置/服务/状态完整资源组' history_engine
t_finish
