#!/usr/bin/env bash
# ROOT 来自 harness；文件动作窄桩由真实安装器调用。
# shellcheck disable=SC2329,SC2153
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$ROOT/install.sh"

fresh_install() {
    local version
    t_fresh empty
    version=$(cat "$ROOT/VERSION") || exit 1
    t_run 0 sbd_install_publish "$ROOT" "$SBD_ROOT" "$SBD_COMMAND" "$SBD_LOCK"
    t_assert 'sd 指向部署入口' test "$(readlink "$SBD_COMMAND")" = "$SBD_APP/singbox-deploy.sh"
    t_assert '入口有执行位' test -x "$SBD_APP/singbox-deploy.sh"
    t_assert '管理器事实已提交' jq -e --arg version "$version" '.manager_version==$version and .revision==0' "$SBD_STATE"
    t_assert '空登记表' jq -e '.nodes==[]' "$SBD_REGISTRY"
    t_assert '不自动创建配置' test ! -e "$SBD_CONFIG"
    t_assert '不自动创建旧布局配置' test ! -e "$SBD_LEGACY_CONFIG" -a ! -e "$SBD_LEGACY_SCHEMA"
    t_assert '不自动装核心' test ! -e "$SBD_ROOT/bin/sing-box"
    t_run 0 "$SBD_COMMAND" --version
    t_contains "$CASE_TMP/output" "$version"
}
preserve_config() {
    t_fresh
    printf '{用户原有内容' > "$SBD_CONFIG" || exit 1
    cp "$SBD_CONFIG" "$CASE_TMP/before" || exit 1
    sbd_service_restore() { return 1; }
    t_run 0 sbd_install_publish "$ROOT" "$SBD_ROOT" "$SBD_COMMAND" "$SBD_LOCK"
    t_assert '管理器更新不碰业务配置' cmp -s "$SBD_CONFIG" "$CASE_TMP/before"
}
command_collision() {
    t_fresh
    printf 'other command' > "$SBD_COMMAND" || exit 1
    t_run 1 sbd_install_publish "$ROOT" "$SBD_ROOT" "$SBD_COMMAND" "$SBD_LOCK"
    t_contains "$SBD_COMMAND" 'other command'
}
state_failure() {
    t_fresh
    printf '0.0.9\n' > "$SBD_APP/VERSION" || exit 1
    sbd_record_write "$SBD_STATE" '{"format":1,"revision":4,"manager_version":"0.0.9"}' || exit 1
    cp "$SBD_STATE" "$CASE_TMP/old-state" || exit 1
    ln -s "$SBD_APP/singbox-deploy.sh" "$SBD_COMMAND" || exit 1
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_install_publish "$ROOT" "$SBD_ROOT" "$SBD_COMMAND" "$SBD_LOCK"
    t_assert '失败发生在 state 提交' test -e "$CASE_TMP/failed"
    t_contains "$SBD_APP/VERSION" 0.0.9
    t_assert '恢复旧 state 字节' cmp -s "$SBD_STATE" "$CASE_TMP/old-state"
    t_assert '命令仍是链接' test -L "$SBD_COMMAND"
    t_assert '普通失败已收尾' test ! -e "$SBD_WORK/active"
}
crashed_install() {
    local version
    t_fresh
    version=$(cat "$ROOT/VERSION") || exit 1
    printf '0.0.9\n' > "$SBD_APP/VERSION" || exit 1
    cp "$SBD_STATE" "$CASE_TMP/old-state" || exit 1
    mv() { if [[ "${!#}" = "$SBD_STATE" ]]; then kill -KILL "$BASHPID"; fi; command mv "$@"; }
    t_run 137 sbd_install_publish "$ROOT" "$SBD_ROOT" "$SBD_COMMAND" "$SBD_LOCK"
    t_contains "$SBD_APP/VERSION" "$version"
    unset -f mv
    sbd_service_restore() { return 1; }
    t_run 0 sbd_recover
    t_contains "$SBD_APP/VERSION" 0.0.9
    t_assert '安装恢复不碰服务' cmp -s "$SBD_STATE" "$CASE_TMP/old-state"
}
broken_manifest() {
    t_fresh
    printf '../escape\n' >> "$SBD_APP/manifest.txt" || exit 1
    t_run 1 sbd_install_validate "$SBD_APP"
    t_contains "$CASE_TMP/output" '路径无效'
}
main_local_install() {
    t_fresh empty
    # 只替换权限谓词和目标路径；文件发布、复核与恢复运行真实代码。
    sbd_install_require_root() { return 0; }
    sbd_dependencies() { return 0; }
    sbd_install_target() {
        case "$1" in
            root) printf '%s/root\n' "$CASE_TMP" ;;
            command) printf '%s/bin/sd\n' "$CASE_TMP" ;;
            lock) printf '%s/root/run/write.lock\n' "$CASE_TMP" ;;
            *) return 1 ;;
        esac
    }
    t_run 0 sbd_install_main --local --no-menu
    t_contains "$CASE_TMP/output" '管理器已安装'
    t_contains "$CASE_TMP/output" '请在核心管理菜单中安装核心'
    t_absent "$CASE_TMP/output" '业务模块仍未实现'
    t_assert '真实安装入口落地命令' test -L "$CASE_TMP/bin/sd"
    t_run 0 "$CASE_TMP/bin/sd" --help
    t_assert '不自动初始化业务配置' test ! -e "$CASE_TMP/root/confs/config.json"
}
fetch_https_only() {
    local target="$CASE_TMP/release.tar.gz"
    t_run 1 sbd_install_fetch http://example.com/pkg "$target"
    t_contains "$CASE_TMP/output" '安装下载地址必须使用 HTTPS'
    command() {
        if [[ "$*" = '-v curl' ]]; then return 1; fi
        builtin command "$@"
    }
    t_run 1 sbd_install_fetch https://example.com/pkg "$target"
    t_contains "$CASE_TMP/output" '需要 curl 才能安全下载发布文件'
    t_assert '拒绝时不留下下载文件' test ! -e "$target"
    unset -f command
    # 桩 curl 记录参数：安装器下载同样禁止 HTTPS→HTTP 重定向降级。
    curl() {
        printf '%s\n' "$*" >> "$CASE_TMP/http-calls"
        while [[ "$#" -gt 0 ]]; do
            if [[ "$1" = -o ]]; then printf 'payload\n' > "$2"; fi
            shift
        done
    }
    : > "$CASE_TMP/http-calls"
    t_run 0 sbd_install_fetch https://example.com/pkg "$target"
    t_assert '发布文件已写入' test -s "$target"
    t_contains "$CASE_TMP/http-calls" '--proto =https'
    t_contains "$CASE_TMP/http-calls" '--proto-redir =https'
}
root_guard() {
    if [[ "$EUID" = 0 ]]; then
        t_run 0 sbd_install_require_root
    else
        t_run 1 sbd_install_require_root
        t_contains "$CASE_TMP/output" 'root'
    fi
}
t_case '首次发布清单、命令、记录成组提交' fresh_install
t_case '更新管理器不碰配置和服务' preserve_config
t_case '已有其他 sd 不覆盖' command_collision
t_case '安装 state 失败整组还原' state_failure
t_case '安装 SIGKILL 后同一记录恢复' crashed_install
t_case '坏清单不能逃逸路径' broken_manifest
t_case '真实 --local --no-menu 安装入口隔离运行' main_local_install
t_case '真实权限谓词拒绝非 root 安装' root_guard
t_case '安装下载限制初始与重定向协议' fetch_https_only
t_finish
