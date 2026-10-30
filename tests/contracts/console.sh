#!/usr/bin/env bash
# ROOT 来自 harness；加载锁的路径桩由真实入口调用。
# shellcheck disable=SC2153,SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

empty_menu() {
    t_fresh
    t_run 0 sbd_dispatch 8 <<< 0
    t_contains "$CASE_TMP/output" '原生观测'
    t_run 0 sbd_dispatch 11 <<< 0
    t_contains "$CASE_TMP/output" '维护与显式协调'
    t_run 0 sbd_dispatch 1 <<< 0
    t_contains "$CASE_TMP/output" '核心管理'
    t_run 0 sbd_dispatch 3 <<< 0
    t_contains "$CASE_TMP/output" '客户端资料'
    t_run 0 sbd_dispatch 7 <<< 0
    t_contains "$CASE_TMP/output" 'TLS 与证书'
    t_run 0 sbd_dispatch 2 <<< 0
    t_contains "$CASE_TMP/output" '节点管理'
    t_run 0 sbd_dispatch 4 <<< 0
    t_contains "$CASE_TMP/output" '规则集与路由'
    t_run 0 sbd_dispatch 5 <<< 0
    t_contains "$CASE_TMP/output" '独立 DNS'
    t_run 0 sbd_dispatch 6 <<< 0
    t_contains "$CASE_TMP/output" 'Endpoints 与 Cloudflared'
}
check_menu() {
    t_seed
    t_run 0 sbd_dispatch 9
    t_contains "$CASE_TMP/output" '未验证网络连通'
    printf '{broken' > "$SBD_CONFIG" || exit 1
    t_run 1 sbd_dispatch 9
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
t_case '菜单编号分派到真实未实现入口' empty_menu
t_case '检查菜单不假报成功' check_menu
t_case '菜单退出与 EOF 无副作用' cancel_menu
t_case '入口参数与源码/部署边界' entry_arguments
t_case '加载模块与安装发布使用同一把锁' loader_lock
t_finish
