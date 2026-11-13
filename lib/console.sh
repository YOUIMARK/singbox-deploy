#!/usr/bin/env bash

sbd_terminal() {
    [[ -t 0 ]] && return 0
    { exec </dev/tty; } 2>/dev/null && return 0
    _error '交互菜单需要终端，无法打开 /dev/tty'
    return 1
}

sbd_update_script() {
    sbd_info '下载当前 main 的发布清单并成组更新管理器；不自动更新核心'
    sbd_policy_confirm || return $?
    bash "$SBD_APP/install.sh" --update --no-menu || return 1
    sbd_success '管理器已更新，请重新运行 sd'
    SBD_EXIT_MENU=true
}

sbd_status() {
    local version state runtime enabled count phase kind output backend rc=0
    local report line system init core='' service='' startup='' nodes='' config='' manager='' transaction=''
    if [[ "${1:-}" = brief ]]; then
        report=$(sbd_status) || rc=$?
        while IFS= read -r line; do
            case "$line" in
                '核心: '*) core="$line" ;;
                '磁盘核心版本: '*) core="核心: ${line#磁盘核心版本: }"; core="${core%%（*}" ;;
                '服务: '*) service="${line%%（*}" ;;
                '开机自启: '*) startup="${line%%（*}" ;;
                '托管节点: '*) nodes="$line" ;;
                '配置: '*) config="$line" ;;
                '管理器记录版本: '*) manager="管理器: ${line#管理器记录版本: }" ;;
                '事务: '*) transaction="$line" ;;
            esac
        done <<< "$report"
        if ! system=$(sbd_system_label); then system=未知; rc=1; fi
        if ! init=$(sbd_backend); then init=未知; rc=1; fi
        sbd_ui_status_table "系统: $system" "init: $init" '' \
            "$core" "$service" "$nodes" "$startup" "$config" "$manager" || return 1
        if [[ "$transaction" != '事务: 无待处理现场' ]]; then
            printf '  '; sbd_ui_tint '1;31' "$transaction"; printf '\n'
        fi
        [[ "$rc" = 0 ]]
        return $?
    fi
    if [[ -x "$SBD_BINARY" ]]; then
        if version=$(sbd_version); then printf '磁盘核心版本: %s（不等同于运行版本）\n' "$version"
        else printf '磁盘核心版本: 未知（读取失败）\n'; rc=1; fi
    else
        printf '核心: 未安装\n'
    fi
    if runtime=$(sbd_service_state); then
        case "$runtime" in running) printf '服务: 运行中（不代表网络连通）\n' ;; stopped) printf '服务: 已停止\n' ;; *) _error '服务状态返回值无效'; printf '服务: 未知\n'; rc=1 ;; esac
    else printf '服务: 未知（读取失败）\n'; rc=1; fi
    if enabled=$(sbd_service_enabled); then
        case "$enabled" in enabled) printf '开机自启: 已开启\n' ;; disabled) printf '开机自启: 已关闭\n' ;; *) _error '自启状态返回值无效'; printf '开机自启: 未知\n'; rc=1 ;; esac
    else printf '开机自启: 未知（读取失败）\n'; rc=1; fi
    if [[ -f "$SBD_CONFIG" ]]; then printf '配置: 已存在\n'; else printf '配置: 未创建\n'; fi
    if state=$(sbd_record_read "$SBD_STATE") && version=$(jq -er '.manager_version | select(type=="string" and length>0)' <<< "$state"); then
        printf '管理器记录版本: %s\n' "$version"
    else _error '无法取得管理器版本事实'; printf '管理器记录版本: 未知\n'; rc=1; fi
    if count=$(jq -er '.nodes|select(type=="array")|length' "$SBD_REGISTRY"); then printf '托管节点: %s 个\n' "$count"
    else _error '读取托管节点数量失败'; printf '托管节点: 未知\n'; rc=1; fi
    if [[ -e "$SBD_WORK/active" || -L "$SBD_WORK/active" ]]; then
        if phase=$(jq -er '.phase|select(.=="pending" or .=="accepted")' "$SBD_WORK/active/journal.json") && kind=$(jq -er '.kind|select(.=="config" or .=="engine" or .=="install")' "$SBD_WORK/active/journal.json"); then
            if [[ "$phase" = accepted ]]; then printf '事务: %s 已接受，待完成收尾\n' "$kind"; else printf '事务: %s 未完成，待恢复\n' "$kind"; fi
            printf '事务现场: %s\n' "$SBD_WORK/active"
        else _error '事务现场缺少可识别记录，请检查，不自动猜测'; printf '事务: 未知现场 %s\n' "$SBD_WORK/active"; rc=1; fi
    else printf '事务: 无待处理现场\n'; fi
    printf '配置文件: %s\n导出目录: %s\n' "$SBD_CONFIG" "$SBD_EXPORTS"
    output=''
    if [[ -f "$SBD_CONFIG" ]]; then
        if ! output=$(jq -r '.log.output // empty' "$SBD_CONFIG"); then _error '无法读取日志路径配置'; rc=1; fi
        if jq -e '.log.disabled==true' "$SBD_CONFIG" >/dev/null 2>&1; then printf '日志配置: 已禁用，以下位置仅可能有历史日志\n'; fi
    fi
    if [[ -n "$output" ]]; then
        [[ "$output" = /* ]] || output="$SBD_ROOT/$output"
        printf '日志文件: %s（log.output）\n' "$output"
    elif backend=$(sbd_backend); then
        case "$backend" in
            systemd) printf '日志命令: journalctl -u %s\n' "$SBD_SERVICE" ;;
            openrc) printf '日志文件: %s（服务输出）\n' "$SBD_LOG" ;;
            *) _error '日志服务后端无效'; printf '日志位置: 未知\n'; rc=1 ;;
        esac
    else printf '日志位置: 未知（服务后端读取失败）\n'; rc=1; fi
    [[ "$rc" = 0 ]]
}

sbd_dispatch() {
    case "$1" in
        1) sbd_entry_create_prompt ;;
        2) sbd_entries_list ;;
        3) sbd_entry_change_prompt edit ;;
        4) sbd_entry_change_prompt delete ;;
        5) sbd_export_menu ;;
        6) sbd_outbound_add_prompt ;;
        7) sbd_policy_sync_current || sbd_info '自动同步未完成；仍可查看配置，保存更改时会重新校验'; sbd_resolver_menu ;;
        8) sbd_policy_sync_current || sbd_info '自动同步未完成；仍可查看配置，保存更改时会重新校验'; sbd_rules_menu ;;
        9) sbd_tls_menu ;;
        10) sbd_policy_sync_current || sbd_info '自动同步未完成；仍可查看配置，保存更改时会重新校验'; sbd_peers_menu ;;
        11) sbd_engine_control restart ;;
        12) sbd_engine_control stop ;;
        13) sbd_status ;;
        14) sbd_observe_logs ;;
        15) sbd_engine_control enable ;;
        16) sbd_engine_control disable ;;
        17) sbd_check_config_tidy && sbd_success 'Schema 与核心检查通过；未验证网络连通' ;;
        18) sbd_observe_menu ;;
        19) sbd_update_script ;;
        20) sbd_engine_menu ;;
        21) sbd_uninstall_menu ;;
        *) _error '无效菜单编号'; return 1 ;;
    esac
}

sbd_console() {
    local choice page rc
    while true; do
        sbd_ui_begin 'sing-box 部署管理脚本 (singbox-deploy)' true || return 1
        sbd_status brief || _error '状态摘要读取不完整；仍可选择检查或维护，不将未知状态当作停止'
        sbd_ui_options --compact --zero-separate '@节点管理' '[1] 添加节点' '[2] 查看节点' '[3] 修改节点' '[4] 删除节点' '[5] 节点链接' '[6] 添加出口' \
            '@网络设置' '[7] DNS 设置' '[8] 分流设置' '[9] 证书管理' '[10] 隧道管理' \
            '@服务控制' '[11] 重启服务' '[12] 停止服务' '[13] 查看状态' '[14] 查看日志' '[15] 启用自启' '[16] 关闭自启' \
            '@配置与维护' '[17] 检查配置' '[18] 日志设置' '[19] 更新脚本' \
            '@核心管理' '[20] sing-box 核心' '[21] 卸载脚本' '[0] 退出'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 21 || return 0
        choice="$SBD_REPLY"
        [[ "$choice" != 0 ]] || return 0
        if sbd_dispatch "$choice"; then
            # 卸载/更新会替换或删除当前入口，返回菜单已无意义。
            if [[ "${SBD_EXIT_MENU:-false}" = true ]]; then sbd_ui_pause "$page" '按回车退出…'
            else sbd_ui_pause "$page"; fi
        else
            rc=$?
            [[ "$rc" = 2 ]] || sbd_ui_pause
        fi
        [[ "${SBD_EXIT_MENU:-false}" != true ]] || return 0
    done
}
