#!/usr/bin/env bash

sbd_observe_change() {
    local stage="$1" action="$2" value="${3:-}" content secret port
    case "$action" in
        api)
            port=$(sbd_integer "$(jq -r '.port' <<< "$value")" 1 65535) || { _error 'API 端口无效'; return 1; }
            secret=$(jq -er '.secret|select(type=="string" and length>0)' <<< "$value") || { _error 'API 必须设置 secret'; return 1; }
            content=$(jq --arg addr "127.0.0.1:$port" --arg secret "$secret" '.experimental.clash_api=((.experimental.clash_api // {}) + {external_controller:$addr,secret:$secret})' "$stage/config.json") ;;
        api_off) content=$(jq 'if .experimental.clash_api!=null then .experimental.clash_api.external_controller="" else . end' "$stage/config.json") ;;
        cache_on|cache_off)
            content=$(jq --arg path "$SBD_DATA/cache.db" --arg action "$action" '.experimental.cache_file=((.experimental.cache_file // {path:$path}) + {enabled:($action=="cache_on")})' "$stage/config.json") ;;
        dns_cache)
            case "$value" in true|false) ;; *) _error 'DNS 缓存持久化选项无效'; return 1 ;; esac
            content=$(jq --arg path "$SBD_DATA/cache.db" --argjson enabled "$value" '.experimental.cache_file=((.experimental.cache_file // {path:$path}) + {store_dns:$enabled})' "$stage/config.json") ;;
        level)
            case "$value" in trace|debug|info|warn|error|fatal|panic) ;; *) _error '未知原生日志级别'; return 1 ;; esac
            content=$(jq --arg level "$value" '.log.level=$level | .log.disabled=false' "$stage/config.json") ;;
        log_off) content=$(jq '.log.disabled=true' "$stage/config.json") ;;
        log_service) content=$(jq 'del(.log.output) | .log.disabled=false' "$stage/config.json") ;;
        *) _error '未知观测设置操作'; return 1 ;;
    esac || { _error '构造观测设置失败'; return 1; }
    sbd_record_write "$stage/config.json" "$content"
}

sbd_observe_query() {
    case "$1" in connections|traffic) ;; *) _error '仅提供原生连接/流量查询'; return 1 ;; esac
    python3 "$SBD_APP/support/observe_api.py" "$SBD_CONFIG" "$1" || { _error '原生 API 查询失败；不以磁盘配置冒充运行事实'; return 1; }
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

sbd_time_interval_prompt() {
    local default="$1" value
    while true; do
        sbd_entry_default '原生 NTP 同步间隔' "$default" || return $?; value="$SBD_REPLY"
        if value=$(sbd_time_interval "$value"); then SBD_REPLY="$value"; return 0; fi
        _error '请输入核心能解析的大于 0 的 duration'
    done
}

sbd_time_prompt() {
    local config="$SBD_CONFIG" defaults server port interval resolver value
    [[ -f "$config" ]] || config="$SBD_APP/presets/base.json"
    defaults=$(jq -c '.ntp // {}' "$config") || { _error '读取已有 NTP 设置失败'; return 1; }
    sbd_entry_host_prompt 'NTP 时间源（不含 scheme/端口）' "$(jq -r '.server // "time.cloudflare.com"' <<< "$defaults")" || return $?; server="$SBD_REPLY"
    sbd_entry_number_prompt 'NTP UDP 端口' 1 65535 "$(jq -r '.server_port // 123' <<< "$defaults")" || return $?; port="$SBD_REPLY"
    sbd_time_interval_prompt "$(jq -r '.interval // "30m"' <<< "$defaults")" || return $?; interval="$SBD_REPLY"
    value=$(jq -n --arg server "$server" --argjson port "$port" --arg interval "$interval" '{server:$server,server_port:$port,interval:$interval}') || return 1
    if [[ "$(sbd_tls_identity "$server")" = DNS:* ]] && ! jq -e '(.detour // "")!=""' <<< "$defaults" >/dev/null; then
        sbd_info '请选择解析时间源域名的现有 DNS resolver'
        sbd_policy_target dns || return $?; resolver="$SBD_REPLY"
        value=$(jq --arg resolver "$resolver" '.domain_resolver=$resolver' <<< "$value") || return 1
    fi
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
    local choice
    while true; do
        printf '\n%s\n' '时间诊断与原生 NTP' '[1] 本地只读诊断（不查询网络）' '[2] 启用/修改核心内部 NTP' '[3] 禁用核心 NTP' '[4] 最近 NTP/时间戳日志' '[0] 返回'
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
    done
}

sbd_observe_menu() {
    local choice action value port secret
    while true; do
        printf '\n%s\n' '原生观测、日志与缓存' '[1] 查看设置（隐藏 secret）' '[2] 启用/修改 loopback Clash API' '[3] 禁用 API' \
            '[4] 当前连接' '[5] 一次流量采样' '[6] 最近 100 行日志' '[7] 日志级别/关闭/回到服务日志' '[8] 启用/禁用 cache_file' '[9] DNS 缓存持久化开关' '[10] 时间诊断与原生 NTP' '[0] 返回'
        sbd_read_integer '请选择' 0 10 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) jq '{log,experimental:{clash_api:(.experimental.clash_api // {}|del(.secret)),cache_file:.experimental.cache_file}}' "$SBD_CONFIG" || { _error '读取观测配置失败'; return 1; }; continue ;;
            4|5) action=connections; [[ "$choice" != 5 ]] || action=traffic; sbd_observe_query "$action" || return 1; continue ;;
            6) sbd_observe_logs || return 1; continue ;;
            10) sbd_time_menu; case "$?" in 0|2) ;; *) return 1 ;; esac; continue ;;
            2)
                action=api
                sbd_entry_number_prompt 'API loopback 端口' 1 65535 9090 || return $?; port="$SBD_REPLY"
                sbd_entry_password_prompt 'API secret' || return $?; secret="$SBD_REPLY"
                value=$(jq -n --argjson port "$port" --arg secret "$secret" '{port:$port,secret:$secret}') || return 1 ;;
            3) action=api_off; value='' ;;
            7)
                sbd_policy_pick '["warn","info","debug","trace","error","fatal","panic","disabled","service"]' '日志设置（service 移除 log.output）' || return $?; value="$SBD_REPLY"
                action=level; case "$value" in disabled) action=log_off ;; service) action=log_service ;; esac ;;
            8)
                sbd_policy_pick '["cache_on","cache_off"]' '缓存开关（不删除 DB）' || return $?; action="$SBD_REPLY"; value='' ;;
            9) action=dns_cache; sbd_policy_pick '["true","false"]' 'store_dns（不自动启用 cache_file）' || return $?; value="$SBD_REPLY" ;;
        esac
        sbd_policy_confirm || return $?
        sbd_apply sbd_observe_change "$action" "$value" || return 1
        sbd_success '观测配置已提交；未声称 API 可访问或缓存已写入，不删除 DB'
    done
}
