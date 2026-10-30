#!/usr/bin/env bash

sbd_peer_change() {
    local stage="$1" area="$2" action="$3" tag="$4" value="${5:-}" kind old request directory taildrop port exclude=''
    case "$area" in endpoints|connectors) ;; *) _error '未知连接对象区域'; return 1 ;; esac
    sbd_tls_tag "$tag" || return 1
    sbd_policy_begin "$stage" || return 1
    if [[ "$action" != add ]]; then
        old=$(jq -ce --arg area "$area" --arg tag "$tag" '.policy[$area][]? | select(.id==$tag) | .expected' "$stage/registry.json") || { _error '此连接对象未托管，不自动接管'; return 1; }
        exclude="$tag"
    fi
    if [[ "$action" = delete ]]; then value='{}'
    elif [[ "$action" = add || "$action" = replace ]]; then
        kind=$(jq -er '.type' <<< "$value") || { _error '缺少原生连接对象类型'; return 1; }
        case "$area:$kind" in endpoints:wireguard|endpoints:tailscale|connectors:cloudflared) ;; *) _error '本包只管理 WireGuard/Tailscale endpoint 与 Cloudflared inbound'; return 1 ;; esac
        jq -e --arg tag "$tag" '.tag==$tag' <<< "$value" >/dev/null || { _error '连接对象须使用选定的原生 tag'; return 1; }
        if [[ "$action" = replace && "$(jq -r '.type' <<< "$old")" != "$kind" ]]; then _error '更换类型请新建对象并迁移引用，不复用旧身份'; return 1; fi
        if [[ "$action" = add ]]; then
            jq -e --arg tag "$tag" 'all((.inbounds[]?,.outbounds[]?,.endpoints[]?);.tag!=$tag)' "$stage/config.json" >/dev/null || { _error '连接标识已被占用，不覆盖既有配置'; return 1; }
        fi
        if [[ "$kind" = tailscale ]]; then
            directory="$SBD_DATA/tailscale/$tag"; taildrop="$directory/Taildrop"
            jq -e --arg dir "$directory" --arg taildrop "$taildrop" '(.state_directory // $dir)==$dir and (.taildrop_directory // $taildrop)==$taildrop' <<< "$value" >/dev/null || { _error '托管 Tailscale 使用独立状态/Taildrop 目录，不自动迁移外部认证数据'; return 1; }
            value=$(jq --arg dir "$directory" --arg taildrop "$taildrop" '. + {state_directory:$dir,taildrop_directory:$taildrop}' <<< "$value") || return 1
        fi
        if [[ "$kind" = wireguard || "$kind" = tailscale ]]; then
            port=$(sbd_integer "$(jq -r '.listen_port // 0' <<< "$value")" 0 65535) || { _error 'UDP 监听端口无效'; return 1; }
            if [[ "$port" != 0 ]]; then sbd_entry_port "$stage" :: "$port" udp "$exclude" || return 1; fi
        fi
    else _error '未知连接对象操作'; return 1; fi
    request=$(jq -n --arg area "$area" --arg action "$action" --arg tag "$tag" --argjson value "$value" '{area:$area,action:$action,id:$tag,value:$value}') || { _error '连接对象请求不是有效 JSON'; return 1; }
    sbd_policy_bundle "$stage" edit "$request" || return 1
    sbd_policy_finish "$stage"
}

sbd_peer_magic() {
    local stage="$1" action="$2" endpoint="$3" tag="$4" position="${5:--1}" request value id group
    sbd_tls_tag "$tag" || return 1
    sbd_policy_begin "$stage" || return 1
    group="magic.$tag"
    if [[ "$action" = add ]]; then
        jq -e --arg tag "$endpoint" 'any(.endpoints[]?;.tag==$tag and .type=="tailscale")' "$stage/config.json" >/dev/null || { _error 'MagicDNS 必须关联已有 Tailscale endpoint'; return 1; }
        value=$(jq -n --arg tag "$tag" --arg endpoint "$endpoint" '{type:"tailscale",tag:$tag,endpoint:$endpoint}') || return 1
        request=$(jq -n --arg tag "$tag" --argjson value "$value" '{area:"dns_servers",action:"add",id:$tag,value:$value}') || return 1
        sbd_policy_bundle "$stage" edit "$request" || return 1
        value=$(jq -n --arg tag "$tag" '{preferred_by:$tag,action:"route",server:$tag}') || return 1
        id=$(openssl rand -hex 8) || { _error '生成 DNS 关联 ID 失败'; return 1; }; id="rule.$id"
        request=$(jq -n --arg id "$id" --arg group "$group" --argjson value "$value" --argjson position "$position" \
            '{area:"dns_rules",action:"add",id:$id,group:$group,value:$value} + (if $position>=0 then {position:$position} else {} end)') || return 1
        sbd_policy_bundle "$stage" edit "$request" || return 1
    elif [[ "$action" = delete ]]; then
        jq -e --arg tag "$tag" 'any(.policy.dns_servers[]?;.id==$tag and .expected.type=="tailscale")' "$stage/registry.json" >/dev/null || { _error '此 Tailscale DNS 上游未托管'; return 1; }
        if jq -e --arg group "$group" 'any(.policy.dns_rules[]?;.group==$group)' "$stage/registry.json" >/dev/null; then
            request=$(jq -n --arg group "$group" '{area:"dns_rules",action:"delete_group",id:$group}') || return 1
            sbd_policy_bundle "$stage" edit "$request" || return 1
        fi
        request=$(jq -n --arg tag "$tag" '{area:"dns_servers",action:"delete",id:$tag}') || return 1
        sbd_policy_bundle "$stage" edit "$request" || return 1
    else _error '未知 MagicDNS 操作'; return 1; fi
    sbd_policy_finish "$stage"
}

sbd_peer_key() {
    python3 - "$1" <<'PY' || { _error 'WireGuard 密钥须为标准 Base64 编码的 32 bytes'; return 1; }
import base64, binascii, sys
try:
    if len(base64.b64decode(sys.argv[1], validate=True)) != 32:
        raise ValueError()
except (ValueError, binascii.Error):
    raise SystemExit(1)
PY
}

sbd_peer_key_prompt() {
    local label="$1" optional="${2:-false}" value
    while true; do
        if [[ "$optional" = true ]]; then sbd_read_optional "$label（可不设置）" true || return $?
        else sbd_read_secret "$label" || return $?; fi
        value="$SBD_REPLY"
        if [[ "$optional" = true && -z "$value" ]]; then return 0; fi
        sbd_peer_key "$value" && return 0
    done
}

sbd_peer_prefix_prompt() {
    local field="$1" value
    while true; do
        sbd_read_required "$field（多个用逗号分隔）" || return $?
        if value=$(python3 - "$field" "$SBD_REPLY" <<'PY'
import ipaddress, json, sys
try:
    parse = ipaddress.ip_interface if sys.argv[1] == "address" else lambda v: ipaddress.ip_network(v, strict=False)
    print(json.dumps([str(parse(v.strip())) for v in sys.argv[2].split(",")]))
except ValueError:
    raise SystemExit(1)
PY
        ); then SBD_REPLY="$value"; return 0; fi
        _error '请输入有效的接口地址/前缀或允许的 IP/CIDR'
    done
}

sbd_peer_reserved_prompt() {
    local a b c
    while true; do
        sbd_entry_default 'peer reserved（三个字节，用逗号分隔）' 0,0,0 || return $?
        IFS=, read -r a b c <<< "$SBD_REPLY"
        if a=$(sbd_integer "$a" 0 255) && b=$(sbd_integer "$b" 0 255) && c=$(sbd_integer "$c" 0 255); then
            SBD_REPLY="[$a,$b,$c]"; return 0
        fi
        _error 'reserved 须为三个 0 到 255 的整数'
    done
}

sbd_peer_tag_prompt() {
    local area="${1:-connections}" config="$SBD_CONFIG" rc
    [[ -f "$config" ]] || config="$SBD_APP/presets/base.json"
    while true; do
        sbd_read_required '原生 tag' || return $?
        sbd_tls_tag "$SBD_REPLY" || continue
        if jq -e --arg tag "$SBD_REPLY" --arg area "$area" 'if $area=="dns" then any(.dns.servers[]?;.tag==$tag) else any((.inbounds[]?,.outbounds[]?,.endpoints[]?);.tag==$tag) end' "$config" >/dev/null; then
            _error '此 tag 已占用，请重新填写该字段'
        else
            rc=$?; [[ "$rc" = 1 ]] || { _error '无法核对现有 tag'; return 1; }
            return 0
        fi
    done
}

sbd_peer_wireguard_prompt() {
    local tag="$1" address private mtu listen peers='[]' count i host port public psk allowed reserved keepalive peer value resolver
    sbd_peer_prefix_prompt address || return $?; address="$SBD_REPLY"
    sbd_peer_key_prompt '已有 WireGuard 私钥' || return $?; private="$SBD_REPLY"
    sbd_entry_number_prompt 'MTU' 1 65535 1408 || return $?; mtu="$SBD_REPLY"
    sbd_entry_number_prompt '本机 UDP 监听端口（0 为自动）' 0 65535 0 || return $?; listen="$SBD_REPLY"
    sbd_entry_number_prompt 'peer 数量' 1 999999999 1 || return $?; count="$SBD_REPLY"
    resolver=''
    for ((i=0; i<count; i++)); do
        printf 'peer %s/%s\n' "$((i+1))" "$count"
        sbd_entry_host_prompt 'peer address（域名/IP，不带端口）' || return $?; host="$SBD_REPLY"
        sbd_entry_number_prompt 'peer port' 1 65535 || return $?; port="$SBD_REPLY"
        sbd_peer_key_prompt 'peer public_key' || return $?; public="$SBD_REPLY"
        sbd_peer_key_prompt 'peer pre_shared_key' true || return $?; psk="$SBD_REPLY"
        sbd_peer_prefix_prompt allowed_ips || return $?; allowed="$SBD_REPLY"
        sbd_peer_reserved_prompt || return $?; reserved="$SBD_REPLY"
        sbd_entry_number_prompt 'persistent_keepalive_interval（秒）' 0 65535 0 || return $?; keepalive="$SBD_REPLY"
        if [[ "$(sbd_tls_identity "$host")" = DNS:* && -z "$resolver" ]]; then sbd_policy_target dns || return $?; resolver="$SBD_REPLY"; fi
        peer=$(jq -n --arg address "$host" --argjson port "$port" --arg public "$public" --arg psk "$psk" --argjson allowed "$allowed" --argjson reserved "$reserved" --argjson keepalive "$keepalive" \
            '{address:$address,port:$port,public_key:$public,allowed_ips:$allowed,reserved:$reserved,persistent_keepalive_interval:$keepalive} + (if $psk!="" then {pre_shared_key:$psk} else {} end)') || return 1
        peers=$(jq --argjson peer "$peer" '. + [$peer]' <<< "$peers") || return 1
    done
    value=$(jq -n --arg tag "$tag" --argjson address "$address" --arg private "$private" --argjson mtu "$mtu" --argjson listen "$listen" --argjson peers "$peers" --arg resolver "$resolver" \
        '{type:"wireguard",tag:$tag,address:$address,private_key:$private,mtu:$mtu,listen_port:$listen,system:false,peers:$peers} + (if $resolver!="" then {domain_resolver:$resolver} else {} end)') || return 1
    SBD_PEER_VALUE="$value"
}

sbd_peer_tailscale_prompt() {
    local tag="$1" key hostname control resolver value
    sbd_info 'Tailscale 1.14 内置 Taildrop；状态与接收目录将独立保存，不提供虚假的关闭选项'
    sbd_read_required '接受该原生行为？输入 y 继续，其他输入取消' || return $?
    [[ "$SBD_REPLY" = y ]] || return 2
    sbd_read_optional 'auth_key（留空使用核心日志中的登录 URL）' true || return $?; key="$SBD_REPLY"
    sbd_read_optional 'hostname（留空使用系统名称）' || return $?; hostname="$SBD_REPLY"
    while true; do
        sbd_read_optional 'control_url（留空使用 Tailscale 官方默认）' || return $?; control="$SBD_REPLY"
        [[ -z "$control" ]] && break
        sbd_rule_url "$control" 2>/dev/null && break
        _error '协调服务器 URL 须为有效 HTTP/HTTPS 地址'
    done
    sbd_info '请选择控制面域名的 bootstrap resolver，不接管全局 DNS'
    sbd_policy_target dns || return $?; resolver="$SBD_REPLY"
    value=$(jq -n --arg tag "$tag" --arg key "$key" --arg hostname "$hostname" --arg control "$control" --arg resolver "$resolver" \
        '{type:"tailscale",tag:$tag,domain_resolver:$resolver,system_interface:false,ssh_server:false,accept_routes:false,advertise_exit_node:false} +
        (if $key!="" then {auth_key:$key} else {} end) + (if $hostname!="" then {hostname:$hostname} else {} end) + (if $control!="" then {control_url:$control} else {} end)') || return 1
    SBD_PEER_VALUE="$value"
}

sbd_peer_token_prompt() {
    local value config
    while true; do
        sbd_read_secret 'Cloudflare Tunnel token（只填 token，不填安装命令）' || return $?; value="$SBD_REPLY"
        config=$(jq -n --arg token "$value" '{inbounds:[{type:"cloudflared",tag:"token-probe",token:$token,protocol:"quic"}],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}') || return 1
        if "$SBD_BINARY" check -c /dev/stdin -D "$SBD_ROOT" <<< "$config" >/dev/null 2>&1; then SBD_REPLY="$value"; return 0; fi
        _error '核心拒绝此 token，请重新填写；未连接 Cloudflare 验证凭据'
    done
}

sbd_peer_dial_prompt() {
    local choice detour='' resolver
    sbd_ui_options '[1] 原生直接拨号（默认）' '[2] 指定现有 outbound/endpoint'
    sbd_entry_number_prompt '拨号方式' 1 2 1 || return $?; choice="$SBD_REPLY"
    if [[ "$choice" = 2 ]]; then sbd_policy_target outbound || return $?; detour="$SBD_REPLY"; fi
    sbd_policy_target dns || return $?; resolver="$SBD_REPLY"
    SBD_PEER_DIAL=$(jq -n --arg detour "$detour" --arg resolver "$resolver" '{domain_resolver:$resolver} + (if $detour!="" then {detour:$detour} else {} end)') || return 1
}

sbd_peer_cloudflare_prompt() {
    local tag="$1" token protocol version control tunnel
    sbd_peer_token_prompt || return $?; token="$SBD_REPLY"
    sbd_ui_options '[1] quic' '[2] http2'
    sbd_read_integer '边缘连接协议' 1 2 || return $?; protocol=quic; [[ "$SBD_REPLY" != 2 ]] || protocol=http2
    sbd_policy_pick '["0","4","6"]' 'edge_ip_version（0 为自动）' || return $?; version="$SBD_REPLY"
    sbd_info 'control_dialer（控制面）'; sbd_peer_dial_prompt || return $?; control="$SBD_PEER_DIAL"
    sbd_info 'tunnel_dialer（边缘数据面）'; sbd_peer_dial_prompt || return $?; tunnel="$SBD_PEER_DIAL"
    SBD_PEER_VALUE=$(jq -n --arg tag "$tag" --arg token "$token" --arg protocol "$protocol" --argjson version "$version" --argjson control "$control" --argjson tunnel "$tunnel" \
        '{type:"cloudflared",tag:$tag,token:$token,protocol:$protocol,edge_ip_version:$version,control_dialer:$control,tunnel_dialer:$tunnel}') || return 1
    sbd_info '这里只管理内嵌 connector；控制台回源、域名及 WS 分享须分别配置，不能据此宣称公网 UDP 或任意代理协议可用'
}

sbd_peer_list() {
    [[ -f "$SBD_CONFIG" ]] || { _error '配置尚未创建'; return 1; }
    jq '{endpoints:[.endpoints[]?|{type,tag,system,system_interface,state_directory,taildrop_directory}],cloudflared:[.inbounds[]?|select(.type=="cloudflared")|{type,tag,protocol,edge_ip_version}]}' "$SBD_CONFIG" || { _error '读取连接对象失败'; return 1; }
    jq '{endpoints:[.policy.endpoints[]?.id],connectors:[.policy.connectors[]?.id]}' "$SBD_REGISTRY" || return 1
    sbd_info '仅显示配置事实，不代表 WireGuard 握手、Tailscale 登录或 Tunnel 已连通；未显示密钥/token'
}

sbd_peer_logging() {
    local stage="$1" level="$2" content
    case "$level" in info|warn) ;; *) _error '此入口只提供 info/warn；其他设置留给原生日志管理'; return 1 ;; esac
    sbd_policy_begin "$stage" || return 1
    content=$(jq --arg level "$level" '.log.level=$level | .log.disabled=false' "$stage/config.json") || return 1
    sbd_record_write "$stage/config.json" "$content" || return 1
    sbd_policy_finish "$stage"
}

sbd_peer_login_menu() {
    local choice level backend page
    while true; do
        sbd_ui_menu 'Tailscale 登录说明与日志' '[1] 查看说明和日志位置' '[2] 显式设置 info（显示等待认证 URL）' '[3] 显式设置 warn' '[0] 返回'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 3 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1)
                sbd_info '核心在 info 级别输出 Waiting for authentication URL；默认 warn 下不可见。不会自动提高全局日志级别，也不打开浏览器或发送 auth_key'
                sbd_info '已有 state_directory 时 auth_key 不会重新注册节点；删除配置保留该目录，配置回滚不撤销登录等外部动作'
                backend=$(sbd_backend) || return 1
                if [[ "$backend" = systemd ]]; then printf '日志命令: journalctl -u %s\n' "$SBD_SERVICE"; else printf '日志文件: %s\n' "$SBD_LOG"; fi
                sbd_ui_pause "$page"
                continue ;;
            2) level=info ;; 3) level=warn ;;
        esac
        sbd_info "这会更改全局 log.level 为 $level；不是自动恢复此前自定义级别"
        sbd_policy_confirm || return $?
        sbd_apply sbd_peer_logging "$level" || return 1
        sbd_success '日志级别已提交；服务原先停止则仍停止，未声明已获取登录 URL'
        sbd_ui_pause "$page"
    done
}

sbd_peer_magic_prompt() {
    local choice endpoint tag count position values
    sbd_ui_menu 'MagicDNS 关联' '[1] 添加 MagicDNS server 与有限域名分流' '[2] 删除托管 Tailscale DNS 及本向导关联规则' '[0] 返回'
    sbd_read_integer '请选择' 0 2 || return $?; choice="$SBD_REPLY"
    [[ "$choice" != 0 ]] || return 2
    if [[ "$choice" = 1 ]]; then
        values=$(jq -c '[.endpoints[]?|select(.type=="tailscale")|.tag]' "$SBD_CONFIG") || return 1
        sbd_policy_pick "$values" '选择已有 Tailscale endpoint' || return $?; endpoint="$SBD_REPLY"
        sbd_peer_tag_prompt dns || return $?; tag="$SBD_REPLY"
        count=$(jq '.dns.rules // []|length' "$SBD_CONFIG") || return 1
        sbd_info '请放在会截获 Tailnet 名称的通用规则之前；不会修改全局 DNS 或默认出口'
        sbd_entry_number_prompt 'DNS 规则插入位置' 1 "$((count+1))" "$((count+1))" || return $?; position=$((SBD_REPLY-1))
        sbd_policy_confirm || return $?
        sbd_apply sbd_peer_magic add "$endpoint" "$tag" "$position" || return 1
    else
        values=$(jq -c '[.policy.dns_servers[]?|select(.expected.type=="tailscale")|.id]' "$SBD_REGISTRY") || return 1
        sbd_policy_pick "$values" '选择托管 Tailscale DNS' || return $?; tag="$SBD_REPLY"
        sbd_policy_confirm || return $?
        sbd_apply sbd_peer_magic delete '' "$tag" || return 1
    fi
    sbd_success 'MagicDNS 关联已提交；未验证 Tailnet 名称解析，不改默认 DNS/路由'
    sbd_ui_pause
}

sbd_peers_menu() {
    local choice area action tag value kind rc page
    while true; do
        sbd_ui_menu '隧道管理' '[1] 查看概要（不显示密钥）' '[2] 向导添加 WireGuard' '[3] 向导添加 Tailscale' '[4] 向导添加 Cloudflared' \
            '[5] 原生 JSON 添加' '[6] 原生 JSON 替换托管对象' '[7] 删除托管对象（保留认证/Taildrop 数据）' '[8] MagicDNS 关联' '[9] Tailscale 登录说明与日志设置' '[0] 返回'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 9 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) sbd_peer_list || return 1; sbd_ui_pause "$page"; continue ;;
            8) sbd_peer_magic_prompt; rc=$?; [[ "$rc" = 0 || "$rc" = 2 ]] || return 1; continue ;;
            9) sbd_peer_login_menu; rc=$?; [[ "$rc" = 0 || "$rc" = 2 ]] || return 1; continue ;;
        esac
        sbd_version >/dev/null || return 1
        action=add; area=endpoints
        case "$choice" in
            2|3|4)
                sbd_peer_tag_prompt || return $?; tag="$SBD_REPLY"
                case "$choice" in
                    2) sbd_peer_wireguard_prompt "$tag" ;; 3) sbd_peer_tailscale_prompt "$tag" ;; 4) area=connectors; sbd_peer_cloudflare_prompt "$tag" ;;
                esac
                rc=$?; [[ "$rc" = 0 ]] || return "$rc"; value="$SBD_PEER_VALUE" ;;
            5)
                sbd_policy_json_prompt || return $?; value="$SBD_REPLY"
                if ! kind=$(jq -er '.type' <<< "$value") || ! tag=$(jq -er '.tag' <<< "$value"); then _error '原生对象缺少 type/tag'; return 1; fi
                [[ "$kind" != cloudflared ]] || area=connectors
                if [[ "$kind" = tailscale ]]; then sbd_info '此原生 Tailscale 对象包含内置 Taildrop；使用独立状态/接收目录，数据不随删除配置清除'; fi ;;
            6|7)
                sbd_ui_options '[1] endpoints' '[2] Cloudflared connectors'
                sbd_read_integer '对象区域' 1 2 || return $?; [[ "$SBD_REPLY" != 2 ]] || area=connectors
                sbd_policy_choose "$area" || return $?; tag="$SBD_REPLY"
                if [[ "$choice" = 7 ]]; then action=delete; value='{}'
                else action=replace; sbd_policy_json_prompt || return $?; value="$SBD_REPLY"; fi ;;
        esac
        sbd_info '这里只提交本地配置；不注册 WARP，不操作远端 peer、控制面或 Cloudflare 控制台'
        sbd_policy_confirm || return $?
        sbd_apply sbd_peer_change "$area" "$action" "$tag" "$value" || return 1
        sbd_success '连接对象与管理事实已提交；未验证握手/登录/Tunnel；原先停止的服务仍停止'
        sbd_ui_pause "$page"
    done
}
