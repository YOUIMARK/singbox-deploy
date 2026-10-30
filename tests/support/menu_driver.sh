#!/usr/bin/env bash
# 由真实 PTY 驱动；只替换宿主机服务查询，不执行系统服务操作。
# shellcheck disable=SC2329,SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/harness.sh"
case "$1" in
    colors|no_color|dumb)
        sbd_ui_menu '终端菜单' '[1] 核心管理' '[2] 删除节点' '[0] 返回'
        sbd_ui_pause
        ;;
    status_colors|status_no_color)
        sbd_ui_begin 'sing-box 部署管理脚本 (singbox-deploy)' true
        sbd_ui_status_table '系统: Debian GNU/Linux 13 (trixie)' 'init: systemd' '' \
            '核心: 未安装' '服务: 运行中' '托管节点: 10 个' \
            '开机自启: 已关闭' '配置: 未创建' '管理器: 0.1.0'
        sbd_ui_status_row '服务: 已停止' '开机自启: 已开启' '配置: 已存在'
        sbd_ui_status_row '核心: 1.14.4' '服务: 未知' '托管节点: 未知'
        sbd_read_required '结束预览' || exit 1
        ;;
    navigation|navigation_narrow|dns_layout|failure)
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
