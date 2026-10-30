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

sbd_observe_menu() {
    local choice action value port secret
    while true; do
        printf '\n%s\n' '原生观测、日志与缓存' '[1] 查看设置（隐藏 secret）' '[2] 启用/修改 loopback Clash API' '[3] 禁用 API' \
            '[4] 当前连接' '[5] 一次流量采样' '[6] 最近 100 行日志' '[7] 日志级别/关闭/回到服务日志' '[8] 启用/禁用 cache_file' '[9] DNS 缓存持久化开关' '[0] 返回'
        sbd_read_integer '请选择' 0 9 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) jq '{log,experimental:{clash_api:(.experimental.clash_api // {}|del(.secret)),cache_file:.experimental.cache_file}}' "$SBD_CONFIG" || { _error '读取观测配置失败'; return 1; }; continue ;;
            4|5) action=connections; [[ "$choice" != 5 ]] || action=traffic; sbd_observe_query "$action" || return 1; continue ;;
            6) sbd_observe_logs || return 1; continue ;;
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
