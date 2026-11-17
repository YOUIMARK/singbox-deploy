#!/usr/bin/env bash

sbd_resolver_server() {
    local stage="$1" action="$2" tag="$3" value="${4:-}" request
    sbd_tls_tag "$tag" || return 1
    [[ -n "$value" ]] || value='{}'
    request=$(jq -n --arg action "$action" --arg tag "$tag" --argjson value "$value" '{area:"dns_servers",action:$action,id:$tag,value:$value}') || { _error 'DNS 上游请求无效'; return 1; }
    sbd_policy_edit "$stage" "$request"
}

sbd_resolver_default() {
    local stage="$1" field="$2" value="$3" content
    sbd_policy_begin "$stage" || return 1
    case "$field" in
        final) content=$(jq --arg value "$value" '.dns.final=$value' "$stage/config.json") ;;
        resolver) content=$(jq --arg value "$value" '.route.default_domain_resolver=$value' "$stage/config.json") ;;
        strategy)
            case "$value" in auto|prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only) ;; *) _error '未知解析策略'; return 1 ;; esac
            content=$(jq --arg value "$value" 'if $value=="auto" then del(.dns.strategy) else .dns.strategy=$value end' "$stage/config.json") ;;
        outbound) content=$(jq --arg value "$value" '.route.final=$value' "$stage/config.json") ;;
        *) _error '未知默认项'; return 1 ;;
    esac || { _error '构造默认项失败'; return 1; }
    sbd_record_write "$stage/config.json" "$content" || return 1
    sbd_policy_finish "$stage"
}

sbd_resolver_switch() {
    local stage="$1" address="$2" content
    sbd_policy_begin "$stage" || return 1
    content=$(python3 -I "$SBD_APP/support/dns_settings.py" switch "$stage" "$address") || return 1
    sbd_record_write "$stage/dns-bundle.json" "$content" || return 1
    content=$(jq -c .config "$stage/dns-bundle.json") || return 1
    sbd_record_write "$stage/config.json" "$content" || return 1
    content=$(jq -c .registry "$stage/dns-bundle.json") || return 1
    sbd_record_write "$stage/registry.json" "$content" || return 1
    sbd_policy_finish "$stage"
}

sbd_resolver_unchanged() {
    local address="$1" report
    [[ -f "$SBD_CONFIG" && -f "$SBD_REGISTRY" ]] || return 1
    report=$(python3 -I "$SBD_APP/support/dns_settings.py" unchanged "$SBD_CONFIG" "$SBD_REGISTRY" "$address") || return 1
    jq -er '.unchanged' <<< "$report"
}

sbd_resolver_summary() {
    local config="$SBD_CONFIG" report address strategy race
    if [[ ! -f "$config" ]]; then
        printf '  '; sbd_ui_status_field '当前 DNS: 未创建配置'; printf '\n'
        printf '  '; sbd_ui_status_field '解析策略: 未设置'; printf '\n'
        return 0
    fi
    report=$(python3 -I "$SBD_APP/support/dns_settings.py" summary "$config") || return 1
    address=$(jq -er .address <<< "$report") && strategy=$(jq -er .strategy <<< "$report") && race=$(jq -er .race <<< "$report") || return 1
    printf '  '; sbd_ui_status_field "当前 DNS: $address"; printf '\n'
    printf '  '; sbd_ui_status_field "解析策略: $strategy"; printf '\n'
    printf '  '; sbd_ui_status_field "上游竞速: $race"; printf '\n'
}

sbd_resolver_menu() {
    local choice page address value rc config label
    while true; do
        sbd_ui_begin 'DNS 设置'
        sbd_resolver_summary || _error 'DNS 摘要读取失败，请检查完整配置'
        printf '\n'
        sbd_ui_options '[1] 系统 DNS' '[2] 阿里 DNS（DoH）' '[3] 腾讯 DNSPod（DoH）' '[4] Cloudflare（DoH）' \
            '[5] Google（DoH）' '[6] 自定义 DNS（多个自动竞速）' '[7] 修改解析策略' '[8] 查看完整配置' '[9] 恢复默认 DoH 竞速' '[0] 返回'
        sbd_config_hint
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 9 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) address=local ;;
            2) address=https://dns.alidns.com/dns-query ;;
            3) address=https://doh.pub/dns-query ;;
            4) address=https://cloudflare-dns.com/dns-query ;;
            5) address=https://dns.google/dns-query ;;
            6)
                sbd_info '支持 local、IP 或完整 DNS URL；多个地址用英文逗号分隔，自动竞速；留空取消'
                while true; do
                    sbd_read_optional 'DNS 地址（留空取消）' || return 0; address="$SBD_REPLY"
                    [[ -n "$address" ]] || break
                    if python3 -I "$SBD_APP/support/dns_settings.py" parse "$address" >/dev/null; then break; fi
                done
                [[ -n "$address" ]] || continue ;;
            7)
                sbd_ui_options '[1] 自动' '[2] IPv4 优先' '[3] IPv6 优先' '[4] 仅 IPv4' '[5] 仅 IPv6' '[0] 返回'
                sbd_read_integer '解析策略' 0 5 || return 0
                case "$SBD_REPLY" in 0) continue ;; 1) value=auto ;; 2) value=prefer_ipv4 ;; 3) value=prefer_ipv6 ;; 4) value=ipv4_only ;; 5) value=ipv6_only ;; esac
                rc=0; sbd_policy_confirm || rc=$?
                if [[ "$rc" = 2 ]]; then [[ "${SBD_UI_EOF:-false}" != true ]] || return 0; continue
                elif [[ "$rc" != 0 ]]; then return 1; fi
                sbd_apply sbd_resolver_default strategy "$value" || return 1
                sbd_success '解析策略已更新'; sbd_ui_pause "$page"; continue ;;
            8)
                config="$SBD_CONFIG"
                if [[ ! -f "$config" ]]; then sbd_info '尚未创建配置，以下为新配置默认值'; config="$SBD_APP/presets/base.json"; fi
                jq '{dns,default_domain_resolver:.route.default_domain_resolver}' "$config" || { _error '读取 DNS 配置失败'; return 1; }
                sbd_ui_pause "$page"; continue ;;
            9) address=default ;;
        esac
        if [[ "$address" = default ]]; then
            sbd_info '使用 Cloudflare、Quad9、Control D 三个直连 DoH，并开启原生竞速'
        else
            sbd_info "使用 DNS: $address；一个上游单独使用，多个上游自动竞速"
        fi
        sbd_info '未选中且未被引用的内置或已登记上游会清理；其他上游保留'
        if sbd_resolver_unchanged "$address" >/dev/null 2>&1 && sbd_check_config >/dev/null 2>&1; then
            case "$address" in
                local) label='系统 DNS' ;;
                default) label='默认 DoH 竞速' ;;
                *) label="$address" ;;
            esac
            sbd_info "当前已是 $label；config.json 无需修改"
            sbd_ui_pause "$page"
            [[ "${SBD_UI_EOF:-false}" != true ]] || return 0
            continue
        fi
        rc=0; sbd_policy_confirm || rc=$?
        if [[ "$rc" = 2 ]]; then [[ "${SBD_UI_EOF:-false}" != true ]] || return 0; continue
        elif [[ "$rc" != 0 ]]; then return 1; fi
        sbd_apply sbd_resolver_switch "$address" || return 1
        sbd_success 'DNS 设置已更新'
        sbd_ui_pause "$page"
        [[ "${SBD_UI_EOF:-false}" != true ]] || return 0
    done
}
