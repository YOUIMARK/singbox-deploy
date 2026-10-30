#!/usr/bin/env bash
# 由真实 PTY 驱动；只替换宿主机服务查询，不执行系统服务操作。
# shellcheck disable=SC2329,SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/harness.sh"
case "$1" in
    colors|no_color|dumb)
        sbd_ui_menu '终端菜单' '[1] 核心管理' '[2] 删除节点' '[0] 返回'
        sbd_ui_pause
        ;;
    navigation|navigation_narrow|failure)
        t_fresh
        SBD_BINARY="$CASE_TMP/missing-core"
        sbd_service_state() { printf 'stopped\n'; }
        sbd_service_enabled() { printf 'disabled\n'; }
        sbd_backend() { printf 'openrc\n'; }
        sbd_console
        ;;
    eof)
        sbd_ui_begin 'EOF 测试'
        sbd_ui_pause
        rc=0
        sbd_read_required 不应再次读取 || rc=$?
        [[ "$rc" = 2 && "$SBD_UI_EOF" = true ]] || exit 1
        ;;
    *) exit 1 ;;
esac
