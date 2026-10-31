#!/usr/bin/env bash

sbd_observe_change() {
    local stage="$1" action="$2" value="${3:-}" content
    case "$action" in
        level)
            case "$value" in trace|debug|info|warn|error|fatal|panic) ;; *) _error '未知原生日志级别'; return 1 ;; esac
            content=$(jq --arg level "$value" '.log.level=$level | .log.disabled=false' "$stage/config.json") ;;
        log_off) content=$(jq '.log.disabled=true' "$stage/config.json") ;;
        log_service) content=$(jq 'del(.log.output) | .log.disabled=false' "$stage/config.json") ;;
        *) _error '未知观测设置操作'; return 1 ;;
    esac || { _error '构造观测设置失败'; return 1; }
    sbd_record_write "$stage/config.json" "$content"
}

sbd_observe_logs() {
    local output backend
    [[ -f "$SBD_CONFIG" ]] || { _error '配置不存在'; return 1; }
    if jq -e '.log.disabled==true' "$SBD_CONFIG" >/dev/null; then sbd_info '配置已禁用核心日志；以下只可能是历史日志'; fi
    output=$(jq -r '.log.output // empty' "$SBD_CONFIG") || return 1
    if [[ -n "$output" ]]; then
        [[ "$output" = /* ]] || output="$SBD_ROOT/$output"
    else
        backend=$(sbd_backend) || return 1
        if [[ "$backend" = systemd ]]; then
            sbd_info "日志来源: journalctl -u $SBD_SERVICE"
            journalctl -u "$SBD_SERVICE" -n 100 --no-pager || { _error '读取 journal 失败'; return 1; }
            return 0
        fi
        output="$SBD_LOG"
    fi
    sbd_info "日志文件: $output"
    [[ -f "$output" ]] || { _error '日志文件尚不存在，不代表服务已运行'; return 1; }
    tail -n 100 -- "$output" || { _error '读取日志失败'; return 1; }
}

sbd_time_interval() {
    local probe formatted interval
    probe=$(jq -n --arg interval "$1" '{ntp:{enabled:true,server:"127.0.0.1",interval:$interval}}') || return 1
    formatted=$("$SBD_BINARY" format -c /dev/stdin <<< "$probe" 2>/dev/null) || { _error '核心无法解析 NTP duration'; return 1; }
    interval=$(jq -r '.ntp.interval // "0s"' <<< "$formatted") || return 1
    [[ "$interval" != 0s && "$interval" != -* ]] || { _error 'NTP interval 必须大于 0'; return 1; }
    printf '%s\n' "$interval"
}

sbd_time_change() {
    local stage="$1" action="$2" value="${3:-}" content server port interval
    case "$action" in
        enable)
            server=$(jq -er '.server|select(type=="string" and length>0)' <<< "$value") || { _error '缺少时间源地址'; return 1; }
            sbd_entry_host "$server" || return 1
            port=$(sbd_integer "$(jq -r '.server_port' <<< "$value")" 1 65535) || { _error 'NTP 端口无效'; return 1; }
            interval=$(sbd_time_interval "$(jq -er '.interval|select(type=="string")' <<< "$value")") || return 1
            value=$(jq --arg interval "$interval" '.interval=$interval' <<< "$value") || return 1
            # 保留已有绑定/拨号选项，明确禁止写系统时钟。
            content=$(jq --argjson value "$value" --arg server "$server" --argjson port "$port" '.ntp=((.ntp // {}) + $value + {enabled:true,server:$server,server_port:$port,write_to_system:false})' "$stage/config.json") || return 1 ;;
        disable) content=$(jq '.ntp=((.ntp // {}) + {enabled:false,write_to_system:false})' "$stage/config.json") || return 1 ;;
        *) _error '未知 NTP 操作'; return 1 ;;
    esac
    sbd_policy_begin "$stage" || return 1
    sbd_record_write "$stage/config.json" "$content" || return 1
    sbd_policy_finish "$stage"
}

sbd_time_prompt() {
    local config="$SBD_CONFIG" defaults server port interval resolver value
    [[ -f "$config" ]] || config="$SBD_APP/presets/base.json"
    defaults=$(jq -c '.ntp // {}' "$config") || { _error '读取已有 NTP 设置失败'; return 1; }
    sbd_entry_host_prompt 'NTP 时间源（不含 scheme/端口）' "$(jq -r '.server // "time.cloudflare.com"' <<< "$defaults")" || return $?; server="$SBD_REPLY"
    port=$(jq -r '.server_port // 123' <<< "$defaults") && interval=$(jq -r '.interval // "30m"' <<< "$defaults") || return 1
    value=$(jq -n --arg server "$server" --argjson port "$port" --arg interval "$interval" '{server:$server,server_port:$port,interval:$interval}') || return 1
    if [[ "$(sbd_tls_identity "$server")" = DNS:* ]] && ! jq -e '(.detour // "")!=""' <<< "$defaults" >/dev/null; then
        resolver=$(jq -c '.domain_resolver // null' <<< "$defaults") || return 1
        if [[ "$resolver" = null ]]; then
            sbd_info '时间源域名解析器'
            sbd_policy_target dns default || return $?
            resolver=$(jq -c --arg server "$SBD_REPLY" '.domain_resolver | if type=="object" then .server=$server else $server end' <<< "$defaults") || return 1
        fi
        value=$(jq --argjson resolver "$resolver" '.domain_resolver=$resolver' <<< "$value") || return 1
    fi
    sbd_info "时间源: $server:$port；同步间隔: $interval"
    sbd_info '将启用核心内部时间补偿；不修改系统/宿主机时钟。原有 detour/绑定等高级字段保留，保存不证明时间源可达'
    sbd_policy_confirm || return $?
    sbd_apply sbd_time_change enable "$value" || return 1
    sbd_success '原生 NTP 配置已提交；原停止服务仍停止，未验证校时结果'
}

sbd_time_diagnose() {
    local count
    date -u '+系统 UTC: %Y-%m-%d %H:%M:%S' || { _error '读取系统时间失败'; return 1; }
    if [[ -e /.dockerenv || -e /run/.containerenv || -s /run/systemd/container ]]; then sbd_info '检测到容器标记；本工具不修改宿主机时间'; fi
    if [[ -f "$SBD_CONFIG" ]]; then
        jq '{ntp:((.ntp // {})|{enabled:(.enabled // false),server,server_port:(.server_port // 123),interval:(.interval // "30m"),write_to_system:(.write_to_system // false),detour,domain_resolver})}' "$SBD_CONFIG" || { _error '读取 NTP 配置失败'; return 1; }
        count=$(jq '[.inbounds[]?,.outbounds[]?]|map(select(.type=="vmess" or (.type=="shadowsocks" and ((.method // "")|startswith("2022-")))))|length' "$SBD_CONFIG") || return 1
        printf '配置中 SS2022/VMess 对象: %s 个\n' "$count"
        if jq -e '.ntp.write_to_system==true' "$SBD_CONFIG" >/dev/null; then sbd_info '当前自定义配置允许核心写系统时间；本工具没有执行校时，使用本菜单启用/禁用将关闭该行为'; fi
    else sbd_info '配置尚未创建，未启用本工具的原生 NTP 设置'; fi
    sbd_info '这是本地只读诊断，未查询远端时间源，无法据此计算时差或确认时间准确'
    sbd_info '核心内部补偿不校准客户端或其他进程；配置已启用、服务运行、历史校时日志均不等于当前校时成功'
}

sbd_time_logs() {
    local logs line found=false
    logs=$(sbd_observe_logs) || return 1
    while IFS= read -r line; do
        if [[ "$line" = *ntp:* || "$line" = *'bad timestamp'* ]]; then printf '%s\n' "$line"; found=true; fi
    done <<< "$logs"
    sbd_info '历史记录仅供排障，不代表当前时间源仍可达；默认 warn 可能看不到 info 级别校时信息'
    if [[ "$found" = false ]]; then _error '最近 100 行没有 NTP/bad timestamp 记录；不代表时间准确或协议可用'; return 1; fi
}

sbd_time_menu() {
    local choice page
    while true; do
        sbd_ui_menu '时间诊断与原生 NTP' '[1] 本地只读诊断（不查询网络）' '[2] 启用/修改核心内部 NTP' '[3] 禁用核心 NTP' '[4] 最近 NTP/时间戳日志' '[0] 返回'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 4 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) sbd_time_diagnose || return 1 ;;
            2) sbd_time_prompt; case "$?" in 0|2) ;; *) return 1 ;; esac ;;
            3)
                sbd_info '只禁用核心补偿，不修改系统时间；保留已有源与拨号字段'
                sbd_policy_confirm || return $?
                sbd_apply sbd_time_change disable || return 1
                sbd_success '核心 NTP 已禁用；不代表系统时间准确' ;;
            4) sbd_time_logs || return 1 ;;
        esac
        sbd_ui_pause "$page"
    done
}

sbd_observe_menu() {
    local choice value action page
    while true; do
        sbd_ui_menu '日志设置' '[1] 查看日志' '[2] 修改日志级别' '[3] 关闭日志' '[4] 恢复服务日志' '[5] 时间设置' '[0] 返回'
        sbd_config_hint
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 5 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) sbd_observe_logs || return 1; sbd_ui_pause "$page"; continue ;;
            2)
                sbd_ui_options '[1] 警告（默认）' '[2] 信息' '[3] 调试' '[4] 错误' '[0] 返回'
                sbd_read_integer '日志级别' 0 4 || return 0
                case "$SBD_REPLY" in 0) continue ;; 1) value=warn ;; 2) value=info ;; 3) value=debug ;; 4) value=error ;; esac
                action=level ;;
            3) action=log_off; value='' ;;
            4) action=log_service; value='' ;;
            5) sbd_time_menu; case "$?" in 0|2) ;; *) return 1 ;; esac; continue ;;
        esac
        sbd_policy_confirm || return $?
        sbd_apply sbd_observe_change "$action" "$value" || return 1
        sbd_success '日志设置已保存'; sbd_ui_pause "$page"
    done
}
