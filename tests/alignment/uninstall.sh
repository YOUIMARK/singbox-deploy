#!/usr/bin/env bash
# 服务边界窄桩只操作 CASE_TMP 内的文件，不触碰宿主 unit/runlevel。
# shellcheck disable=SC2329,SC2016,SC2153
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/peers.sh"

u_seed() {
    t_policy_seed
    SBD_BINARY="$SBD_ENGINE/sing-box"
    cp "$SBD_TEST_BIN" "$SBD_BINARY" || exit 1
    printf 'sing-box\n' > "$SBD_ENGINE/.sbd-files" || exit 1
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
    t_assert '服务定义和命令已删除' test ! -e "$CASE_TMP/etc/service"
    t_assert '命令链接不存在' test ! -L "$SBD_COMMAND"
    t_assert '核心已移除' test ! -e "$SBD_BINARY"
    t_contains "$SBD_APP/user-notes.txt" 'unknown user'
    t_assert '卸载事实写入 state' jq -e '.installed==false' "$SBD_STATE"
}
uninstall_purge() {
    u_seed
    local value
    value=$(jq --arg dir "$SBD_DATA/tailscale/legacy" '.state_directory=$dir' "$ROOT/tests/fixtures/endpoint-tailscale.json") || exit 1
    jq --argjson value "$value" '.endpoints=[$value]' "$SBD_CONFIG" > "$CASE_TMP/legacy" || exit 1
    cp "$CASE_TMP/legacy" "$SBD_CONFIG" || exit 1
    local dir plan
    dir=$(jq -r '.endpoints[0].state_directory' "$SBD_CONFIG") || exit 1
    mkdir -p "$dir/Taildrop" || exit 1
    printf 'fixture native state\n' > "$dir/state" || exit 1
    printf 'unknown user file\n' > "$SBD_ROOT/user-notes.txt" || exit 1
    printf 'external keep\n' > "$CASE_TMP/external.pem" || exit 1
    mkdir -p "$SBD_DATA/tailscale/user-unmanaged" || exit 1
    printf 'unmanaged state\n' > "$SBD_DATA/tailscale/user-unmanaged/state" || exit 1
    jq --arg path "$SBD_DATA/tailscale/user-unmanaged" '.endpoints += [{type:"tailscale",tag:"user-unmanaged",state_directory:$path}]' "$SBD_CONFIG" > "$CASE_TMP/custom" || exit 1
    cp "$CASE_TMP/custom" "$SBD_CONFIG" || exit 1
    plan=$(sbd_uninstall_plan purge) || exit 1
    t_run 0 sbd_write_lock sbd_uninstall_locked purge "$plan"
    t_assert '已移除的功能不再授予认证数据删除权' test -s "$dir/state"
    t_assert '清除配置文件' test ! -e "$SBD_CONFIG"
    t_assert '清除状态' test ! -e "$SBD_STATE"
    t_contains "$SBD_ROOT/user-notes.txt" 'unknown user'
    t_contains "$CASE_TMP/external.pem" 'external keep'
    t_contains "$SBD_DATA/tailscale/user-unmanaged/state" 'unmanaged state'
}
uninstall_failure() {
    u_seed
    local plan
    plan=$(sbd_uninstall_plan keep) || exit 1
    sbd_engine_stopped() { _error 'fixture stop failure'; return 1; }
    t_run 1 sbd_write_lock sbd_uninstall_locked keep "$plan"
    t_assert '未确认停止不删除入口或服务' test -L "$SBD_COMMAND"
    t_assert '未确认停止不删除服务定义' test -f "$CASE_TMP/etc/service"
    t_assert '保留可重试清单' test -f "$SBD_DATA/uninstall.json"
}
uninstall_foreign() {
    u_seed
    printf 'foreign service\n' > "$CASE_TMP/etc/service" || exit 1
    local plan
    plan=$(sbd_uninstall_plan purge) || exit 1
    t_run 1 sbd_write_lock sbd_uninstall_locked purge "$plan"
    t_assert '外来服务拒绝卸载，核心保留' test -x "$SBD_BINARY"
    t_contains "$CASE_TMP/etc/service" 'foreign service'
}
uninstall_cancel() {
    u_seed
    t_run 2 sbd_uninstall_menu <<< $'1\nn'
    t_assert '预览后取消不删核心' test -x "$SBD_BINARY"
    t_assert '预览后取消不删命令' test -L "$SBD_COMMAND"
    t_assert '取消不创建卸载清单' test ! -e "$SBD_DATA/uninstall.json"
}
uninstall_partial_failure() {
    u_seed
    local plan
    plan=$(sbd_uninstall_plan keep) || exit 1
    rm() { if [[ "${!#}" = "$CASE_TMP/etc/service" ]]; then return 1; fi; command rm "$@"; }
    t_run 1 sbd_write_lock sbd_uninstall_locked keep "$plan"
    t_assert '删除步骤失败必须保留可重试现场' test -f "$SBD_DATA/uninstall.json"
    t_assert '服务文件失败时尚未删除管理器' test -f "$SBD_APP/singbox-deploy.sh"
    t_absent "$CASE_TMP/output" '[成功]'
}
history_engine() {
    u_seed
    mkdir -p "$CASE_TMP/candidate/engine" || exit 1
    cp "$SBD_TEST_BIN" "$CASE_TMP/candidate/engine/sing-box" || exit 1
    printf 'old-library\n' > "$SBD_ENGINE/libcronet.so" || exit 1
    printf 'new-library\n' > "$CASE_TMP/candidate/engine/libcronet.so" || exit 1
    printf '1.14.4\n' > "$CASE_TMP/candidate/version" || exit 1
    printf 'sing-box-1.14.4-linux-amd64.tar.gz\n' > "$CASE_TMP/candidate/asset" || exit 1
    sbd_service_enabled() { printf 'disabled\n'; }
    t_run 0 sbd_engine_commit "$CASE_TMP/candidate"
    t_contains "$SBD_ENGINE/libcronet.so" new-library
    t_run 0 sbd_history_restore
    t_contains "$SBD_ENGINE/libcronet.so" old-library
    t_run 0 sbd_check_config
}
history_install() {
    u_seed
    . "$SBD_APP/install.sh"
    cp "$SBD_APP/VERSION" "$CASE_TMP/version" || exit 1
    mkdir "$CASE_TMP/release" || exit 1
    cp -a "$SBD_APP/." "$CASE_TMP/release/" || exit 1
    printf '0.1.1\n' > "$CASE_TMP/release/VERSION" || exit 1
    t_run 0 sbd_install_publish "$CASE_TMP/release" "$SBD_ROOT" "$SBD_COMMAND" "$SBD_LOCK"
    t_contains "$SBD_APP/VERSION" 0.1.1
    t_run 0 sbd_history_restore
    t_assert '完整恢复管理器文件和记录' cmp -s "$SBD_APP/VERSION" "$CASE_TMP/version"
    t_assert '命令仍指向正确入口' test "$(readlink "$SBD_COMMAND")" = "$SBD_APP/singbox-deploy.sh"
}
t_case '保留模式卸载运行文件，原路径数据与未知文件保留' uninstall_keep
t_case '明确 purge 只清已知自有数据，外部/未知文件保留' uninstall_purge
t_case '卸载停止失败保留入口和可重试记录' uninstall_failure
t_case '外来服务不能借卸载入口删除' uninstall_foreign
t_case '卸载预览取消保留所有运行文件' uninstall_cancel
t_case '卸载删除边界失败不假报成功且保留重试记录' uninstall_partial_failure
t_case '恢复最近核心事务的包/配置/服务/状态完整资源组' history_engine
t_case '恢复最近管理器事务的发布文件和命令完整资源组' history_install
t_finish
