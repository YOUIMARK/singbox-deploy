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

sbd_resolver_race() {
    local stage="$1" servers="$2" match="$3" position="${4:--1}" group index count server tag request value i
    sbd_policy_begin "$stage" || return 1
    jq -e 'type=="array" and length>=2 and length==(unique|length) and all(.[];type=="string" and length>0)' <<< "$servers" >/dev/null || { _error '竞速须选择至少两个不同的已存在上游'; return 1; }
    jq -e 'type=="object" and (has("action") or has("tag") or has("match_response") or has("race") or has("server")|not)' <<< "$match" >/dev/null || { _error '竞速匹配对象不得覆盖生成动作'; return 1; }
    count=$(jq 'length' <<< "$servers") || return 1
    if [[ "$position" = -1 ]]; then position=$(jq '.dns.rules // []|length' "$stage/config.json") || return 1; fi
    position=$(sbd_integer "$position" 0 "$(jq '.dns.rules // []|length' "$stage/config.json")") || { _error '竞速插入位置无效'; return 1; }
    group=$(openssl rand -hex 8) || { _error '生成竞速组 ID 失败'; return 1; }; group="race.$group"
    # 先发起各 evaluate，再用带标识的 respond/race 竞争，不映射 Xray 开关。
    for ((i=0; i<count*2; i++)); do
        index=$((i % count))
        server=$(jq -r --argjson i "$index" '.[$i]' <<< "$servers") || return 1
        tag="$group.$index"
        if (( i < count )); then value=$(jq --arg server "$server" --arg tag "$tag" '. + {action:"evaluate",server:$server,tag:$tag}' <<< "$match")
        else value=$(jq --arg tag "$tag" '. + {action:"respond",match_response:$tag,race:true}' <<< "$match"); fi || return 1
        request=$(jq -n --arg id "$group.rule.$i" --arg group "$group" --argjson value "$value" --argjson position "$((position+i))" \
            '{area:"dns_rules",action:"add",id:$id,group:$group,value:$value,position:$position}') || return 1
        sbd_policy_bundle "$stage" edit "$request" || return 1
    done
    sbd_policy_finish "$stage"
}

sbd_resolver_server_prompt() {
    local choice type tag="${1:-}" host port path resolver detour value identity
    sbd_ui_options '[1] local' '[2] UDP' '[3] TCP' '[4] TLS (DoT)' '[5] HTTPS (DoH)' '[6] QUIC (DoQ)' '[7] 原生 JSON 文件'
    sbd_read_integer 'DNS 上游类型' 1 7 || return $?; choice="$SBD_REPLY"
    if [[ "$choice" = 7 ]]; then sbd_policy_json_prompt || return $?; SBD_POLICY_VALUE="$SBD_REPLY"; return 0; fi
    if [[ -z "$tag" ]]; then
        while true; do sbd_read_required 'DNS 上游 tag' || return $?; tag="$SBD_REPLY"; sbd_tls_tag "$tag" && break; done
    else sbd_info "保留上游标识: $tag；向导重建对象，高级字段请用 JSON 替换"; fi
    case "$choice" in 1) type=local ;; 2) type=udp ;; 3) type=tcp ;; 4) type=tls ;; 5) type=https ;; 6) type=quic ;; esac
    value=$(jq -n --arg type "$type" --arg tag "$tag" '{type:$type,tag:$tag}') || return 1
    if [[ "$type" != local ]]; then
        sbd_entry_host_prompt 'DNS 服务器地址（域名/IP，不含 scheme）' || return $?; host="$SBD_REPLY"
        port=53; case "$type" in tls|quic) port=853 ;; https) port=443 ;; esac
        sbd_entry_number_prompt 'DNS 服务器端口' 1 65535 "$port" || return $?; port="$SBD_REPLY"
        value=$(jq --arg host "$host" --argjson port "$port" '. + {server:$host,server_port:$port}' <<< "$value") || return 1
        identity=$(sbd_tls_identity "$host") || return 1
        if [[ "$identity" = DNS:* ]]; then
            sbd_info '请选择解析该上游地址的 bootstrap resolver，不能形成自引用'
            sbd_policy_target dns || return $?; resolver="$SBD_REPLY"
            value=$(jq --arg resolver "$resolver" '. + {domain_resolver:$resolver}' <<< "$value") || return 1
        fi
        case "$type" in
            tls|https|quic)
                value=$(jq --arg sni "$host" '. + {tls:{enabled:true,server_name:$sni}}' <<< "$value") || return 1 ;;
        esac
        if [[ "$type" = https ]]; then
            while true; do
                sbd_entry_default 'DoH path' /dns-query || return $?; path="$SBD_REPLY"
                [[ "$path" = /* ]] && break
                _error 'DoH path 须以 / 开头'
            done
            value=$(jq --arg path "$path" '. + {path:$path}' <<< "$value") || return 1
        fi
        sbd_ui_options '[1] 原生直接拨号（默认，不等于经 route.final）' '[2] 指定 outbound/endpoint'
        sbd_entry_number_prompt '上游连接方式' 1 2 1 || return $?
        if [[ "$SBD_REPLY" = 2 ]]; then
            sbd_policy_target outbound || return $?; detour="$SBD_REPLY"
            value=$(jq --arg detour "$detour" '. + {detour:$detour}' <<< "$value") || return 1
        fi
    fi
    SBD_POLICY_VALUE="$value"
}

sbd_resolver_rule_prompt() {
    local value choice action server tag
    sbd_policy_match_prompt || return $?; value="$SBD_MATCH"
    sbd_ui_options '[1] route 到上游' '[2] reject' '[3] evaluate 响应供后续规则匹配' '[4] respond 返回已 evaluate 响应'
    sbd_read_integer '选择 DNS action' 1 4 || return $?; choice="$SBD_REPLY"
    case "$choice" in
        1|3)
            action=route; [[ "$choice" != 3 ]] || action=evaluate
            sbd_policy_target dns || return $?; server="$SBD_REPLY"
            value=$(jq --arg server "$server" '. + {server:$server}' <<< "$value") || return 1
            if [[ "$choice" = 3 ]]; then
                while true; do sbd_read_required 'evaluate tag（供后续 match_response 引用）' || return $?; tag="$SBD_REPLY"; sbd_tls_tag "$tag" && break; done
                value=$(jq --arg tag "$tag" '. + {tag:$tag}' <<< "$value") || return 1
            fi ;;
        2) action=reject ;;
        4)
            action=respond
            sbd_policy_pick "$(jq -c '[.dns.rules[]?|select(.action=="evaluate")|.tag // empty]' "$SBD_CONFIG")" '选择前置 evaluate tag' || return $?; tag="$SBD_REPLY"
            value=$(jq --arg tag "$tag" '. + {match_response:$tag}' <<< "$value") || return 1 ;;
    esac
    # 目标 IP/CIDR 属于响应匹配，不能退回已弃用的 Address Filter。
    if jq -e 'has("ip_cidr")' <<< "$value" >/dev/null; then
        if [[ "$action" = evaluate ]]; then _error 'evaluate 不使用目标响应 IP 条件；请先 evaluate，再添加响应规则'; return 1; fi
        if [[ "$action" != respond ]]; then
            sbd_policy_pick "$(jq -c '[.dns.rules[]?|select(.action=="evaluate")|.tag // empty]' "$SBD_CONFIG")" '选择前置 evaluate tag' || return $?; tag="$SBD_REPLY"
            value=$(jq --arg tag "$tag" '. + {match_response:$tag}' <<< "$value") || return 1
        fi
    elif jq -e 'has("rule_set")' <<< "$value" >/dev/null && [[ "$action" != evaluate && "$action" != respond ]]; then
        sbd_ui_options '[1] 查询匹配（域名类规则集，默认）' '[2] evaluate 响应匹配（IP 类规则集）'
        sbd_entry_number_prompt '规则集匹配来源' 1 2 1 || return $?
        if [[ "$SBD_REPLY" = 2 ]]; then
            sbd_policy_pick "$(jq -c '[.dns.rules[]?|select(.action=="evaluate")|.tag // empty]' "$SBD_CONFIG")" '选择前置 evaluate tag' || return $?; tag="$SBD_REPLY"
            value=$(jq --arg tag "$tag" '. + {match_response:$tag}' <<< "$value") || return 1
        fi
    fi
    SBD_POLICY_VALUE=$(jq --arg action "$action" '. + {action:$action}' <<< "$value") || return 1
}

sbd_resolver_race_prompt() {
    local value servers='[]' server count position
    sbd_policy_match_prompt || return $?; value="$SBD_MATCH"
    if jq -e 'has("ip_cidr")' <<< "$value" >/dev/null; then _error '竞速起始条件须匹配查询，响应 IP 条件请用高级规则'; return 1; fi
    count=$(jq '[.dns.servers[]?]|length' "$SBD_CONFIG") || return 1
    (( count >= 2 )) || { _error '请先添加至少两个 DNS 上游'; return 1; }
    sbd_entry_number_prompt '参与竞速的上游数量' 2 "$count" 2 || return $?; count="$SBD_REPLY"
    while (( $(jq length <<< "$servers") < count )); do
        sbd_policy_target dns || return $?; server="$SBD_REPLY"
        if jq -e --arg server "$server" 'index($server)!=null' <<< "$servers" >/dev/null; then _error '此上游已选择，请选另一个'; continue; fi
        servers=$(jq --arg server "$server" '. + [$server]' <<< "$servers") || return 1
    done
    count=$(jq '.dns.rules // []|length' "$SBD_CONFIG") || return 1
    sbd_entry_number_prompt '竞速组起始位置（默认末尾）' 1 "$((count+1))" "$((count+1))" || return $?; position=$((SBD_REPLY-1))
    sbd_info '竞速由原生规则顺序控制；首个匹配的响应胜出，不更改 dns.final'
    sbd_policy_confirm || return $?
    sbd_apply sbd_resolver_race "$servers" "$value" "$position" || return 1
    sbd_success 'DNS 竞速规则组已提交；未验证上游连通或实际竞速结果'
}

sbd_resolver_advanced_menu() {
    local choice action tag value field rc values request page
    while true; do
        sbd_ui_menu 'DNS 高级设置' '[1] 查看 DNS 与托管上游' '[2] 添加上游' '[3] JSON 替换托管上游' '[4] 删除托管上游' \
            '[5] 默认上游/域名解析器/解析策略' '[6] DNS 分流规则' '[7] 添加原生竞速组' '[8] 删除托管竞速组' '[9] 向导重建托管上游（高级字段请用 JSON）' '[0] 返回'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 9 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1)
                printf '当前 DNS 配置:\n'
                jq '.dns // {}' "$SBD_CONFIG" || { _error '读取 DNS 失败'; return 1; }
                printf '\n托管上游:\n'
                jq -r '(.policy.dns_servers // []) | if length==0 then "暂无托管上游" else .[] | .id end' "$SBD_REGISTRY" || return 1
                sbd_ui_pause "$page"; continue ;;
            6) sbd_policy_rules_menu dns_rules; rc=$?; [[ "$rc" = 0 || "$rc" = 2 ]] || return 1; continue ;;
            7) sbd_resolver_race_prompt; rc=$?; [[ "$rc" = 0 || "$rc" = 2 ]] || return 1; sbd_ui_pause "$page"; continue ;;
            2)
                action=add; sbd_resolver_server_prompt || return $?; value="$SBD_POLICY_VALUE"
                tag=$(jq -er '.tag|select(type=="string")' <<< "$value") || { _error '上游须有原生 tag'; return 1; } ;;
            3) action=replace; sbd_policy_choose dns_servers || return $?; tag="$SBD_REPLY"; sbd_policy_json_prompt || return $?; value="$SBD_REPLY" ;;
            4) action=delete; sbd_policy_choose dns_servers || return $?; tag="$SBD_REPLY"; value='{}' ;;
            9)
                action=replace; sbd_policy_choose dns_servers || return $?; tag="$SBD_REPLY"
                sbd_resolver_server_prompt "$tag" || return $?; value="$SBD_POLICY_VALUE" ;;
            5)
                sbd_ui_options '[1] dns.final（查询默认上游）' '[2] route.default_domain_resolver（拨号域名解析器）' '[3] dns.strategy（全局解析策略）'
                sbd_read_integer '选择默认项' 1 3 || return $?
                case "$SBD_REPLY" in
                    1) field=final; sbd_policy_target dns || return $?; value="$SBD_REPLY" ;;
                    2) field=resolver; sbd_policy_target dns || return $?; value="$SBD_REPLY" ;;
                    3)
                        field=strategy
                        sbd_policy_pick '["auto","prefer_ipv4","prefer_ipv6","ipv4_only","ipv6_only"]' '选择解析策略' || return $?; value="$SBD_REPLY" ;;
                esac
                sbd_policy_confirm || return $?
                sbd_apply sbd_resolver_default "$field" "$value" || return 1
                sbd_success '默认项已提交；未验证实际解析结果'; sbd_ui_pause "$page"; continue ;;
            8)
                values=$(jq -c '[.policy.dns_rules[]?.group // empty|select(startswith("race."))]|unique' "$SBD_REGISTRY") || return 1
                sbd_policy_pick "$values" '选择竞速组' || return $?; tag="$SBD_REPLY"
                request=$(jq -n --arg tag "$tag" '{area:"dns_rules",action:"delete_group",id:$tag}') || return 1
                sbd_policy_confirm || return $?
                sbd_apply sbd_policy_edit "$request" || return 1
                sbd_success '竞速组已删除；其他规则保持不变'; sbd_ui_pause "$page"; continue ;;
        esac
        sbd_policy_confirm || return $?
        sbd_apply sbd_resolver_server "$action" "$tag" "$value" || return 1
        sbd_success 'DNS 上游与管理事实已提交；未验证上游连通或解析结果'
        sbd_ui_pause "$page"
    done
}

sbd_resolver_switch() {
    local stage="$1" address="$2" content
    sbd_policy_begin "$stage" || return 1
    content=$(python3 "$SBD_APP/support/dns_settings.py" switch "$stage" "$address") || return 1
    sbd_record_write "$stage/dns-bundle.json" "$content" || return 1
    content=$(jq -c .config "$stage/dns-bundle.json") || return 1
    sbd_record_write "$stage/config.json" "$content" || return 1
    content=$(jq -c .registry "$stage/dns-bundle.json") || return 1
    sbd_record_write "$stage/registry.json" "$content" || return 1
    sbd_policy_finish "$stage"
}

sbd_resolver_summary() {
    local config="$SBD_CONFIG" report address strategy
    if [[ ! -f "$config" ]]; then
        printf '  当前 DNS: 未创建配置\n  解析策略: 未设置\n'
        return 0
    fi
    report=$(python3 "$SBD_APP/support/dns_settings.py" summary "$config") || return 1
    address=$(jq -er .address <<< "$report") && strategy=$(jq -er .strategy <<< "$report") || return 1
    printf '  '; sbd_ui_status_field "当前 DNS: $address"; printf '\n'
    printf '  '; sbd_ui_status_field "解析策略: $strategy"; printf '\n'
}

sbd_resolver_menu() {
    local choice page address value rc config
    while true; do
        sbd_ui_begin 'DNS 设置'
        sbd_resolver_summary || _error 'DNS 摘要读取失败，请检查完整配置'
        printf '\n'
        sbd_ui_options '[1] 系统 DNS' '[2] 阿里 DNS（DoH）' '[3] 腾讯 DNSPod（DoH）' '[4] Cloudflare（DoH）' \
            '[5] Google（DoH）' '[6] 自定义 DNS' '[7] 修改解析策略' '[8] 查看完整配置' '[9] 高级设置' '[0] 返回'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 9 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) address=local ;;
            2) address=https://dns.alidns.com/dns-query ;;
            3) address=https://doh.pub/dns-query ;;
            4) address=https://1.1.1.1/dns-query ;;
            5) address=https://dns.google/dns-query ;;
            6)
                sbd_info '支持 local、IP、udp://、tcp://、tls://、quic://、https:// 地址；端口/path 写在地址中，留空取消'
                while true; do
                    sbd_read_optional 'DNS 地址' || return 0; address="$SBD_REPLY"
                    [[ -n "$address" ]] || break
                    if python3 "$SBD_APP/support/dns_settings.py" parse "$address" >/dev/null; then break; fi
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
            9)
                sbd_resolver_advanced_menu || return $?
                continue ;;
        esac
        sbd_info "将默认 DNS 与拨号域名解析器设为 $address；保留已有上游、分流规则和解析策略"
        rc=0; sbd_policy_confirm || rc=$?
        if [[ "$rc" = 2 ]]; then [[ "${SBD_UI_EOF:-false}" != true ]] || return 0; continue
        elif [[ "$rc" != 0 ]]; then return 1; fi
        sbd_apply sbd_resolver_switch "$address" || return 1
        sbd_success 'DNS 设置已更新'
        sbd_ui_pause "$page"
        [[ "${SBD_UI_EOF:-false}" != true ]] || return 0
    done
}
