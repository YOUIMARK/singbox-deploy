#!/usr/bin/env bash

sbd_peer_change() {
    local stage="$1" area="$2" action="$3" tag="$4" value="${5:-}" kind old request port exclude=''
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
        case "$area:$kind" in endpoints:wireguard|connectors:cloudflared) ;; *) _error '此面板只管理 WireGuard 与 Cloudflare Tunnel'; return 1 ;; esac
        jq -e --arg tag "$tag" '.tag==$tag' <<< "$value" >/dev/null || { _error '连接对象须使用选定的原生 tag'; return 1; }
        if [[ "$action" = replace && "$(jq -r '.type' <<< "$old")" != "$kind" ]]; then _error '更换类型请新建对象并迁移引用，不复用旧身份'; return 1; fi
        if [[ "$action" = add ]]; then
            jq -e --arg tag "$tag" 'all((.inbounds[]?,.outbounds[]?,.endpoints[]?);.tag!=$tag)' "$stage/config.json" >/dev/null || { _error '连接标识已被占用，不覆盖既有配置'; return 1; }
        fi
        if [[ "$kind" = wireguard ]]; then
            port=$(sbd_integer "$(jq -r '.listen_port // 0' <<< "$value")" 0 65535) || { _error 'UDP 监听端口无效'; return 1; }
            if [[ "$port" != 0 ]]; then sbd_entry_port "$stage" :: "$port" udp "$exclude" || return 1; fi
        fi
    else _error '未知连接对象操作'; return 1; fi
    request=$(jq -n --arg area "$area" --arg action "$action" --arg tag "$tag" --argjson value "$value" '{area:$area,action:$action,id:$tag,value:$value}') || { _error '连接对象请求不是有效 JSON'; return 1; }
    sbd_policy_bundle "$stage" edit "$request" || return 1
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

sbd_peer_tag_free() {
    local base="$1" config="$SBD_CONFIG" candidate index=2
    [[ -f "$config" ]] || config="$SBD_APP/presets/base.json"
    candidate="$base"
    while jq -e --arg tag "$candidate" 'any((.inbounds[]?,.outbounds[]?,.endpoints[]?);.tag==$tag)' "$config" >/dev/null 2>&1; do
        candidate="$base-$index"
        index=$((index+1))
        (( index <= 99 )) || break
    done
    printf '%s\n' "$candidate"
}

sbd_peer_tag_prompt() {
    local default="${1:-}" area="${2:-connections}" config="$SBD_CONFIG" rc
    [[ -f "$config" ]] || config="$SBD_APP/presets/base.json"
    while true; do
        # 默认值只给一次：重问时不再提供，避免回车反复选中已被占用的 tag。
        if [[ -n "$default" ]]; then sbd_entry_default '原生 tag' "$default" || return $?; default=''
        else sbd_read_required '原生 tag' || return $?; fi
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
    local address private mtu=1408 listen=0 peers='[]' count=1 i host port public psk allowed reserved keepalive peer value resolver
    sbd_peer_prefix_prompt address || return $?; address="$SBD_REPLY"
    sbd_peer_key_prompt '已有 WireGuard 私钥' || return $?; private="$SBD_REPLY"
    resolver=''
    for ((i=0; i<count; i++)); do
        printf 'peer %s/%s\n' "$((i+1))" "$count"
        sbd_entry_host_prompt 'peer address（域名/IP，不带端口）' || return $?; host="$SBD_REPLY"
        sbd_entry_number_prompt 'peer port' 1 65535 || return $?; port="$SBD_REPLY"
        sbd_peer_key_prompt 'peer public_key' || return $?; public="$SBD_REPLY"
        sbd_peer_key_prompt 'peer pre_shared_key' true || return $?; psk="$SBD_REPLY"
        sbd_peer_prefix_prompt allowed_ips || return $?; allowed="$SBD_REPLY"
        reserved='[0,0,0]'; keepalive=0
        if [[ "$(sbd_tls_identity "$host")" = DNS:* && -z "$resolver" ]]; then
            sbd_policy_target dns default || return $?
            resolver="$SBD_REPLY"
        fi
        peer=$(jq -n --arg address "$host" --argjson port "$port" --arg public "$public" --arg psk "$psk" --argjson allowed "$allowed" --argjson reserved "$reserved" --argjson keepalive "$keepalive" \
            '{address:$address,port:$port,public_key:$public,allowed_ips:$allowed,reserved:$reserved,persistent_keepalive_interval:$keepalive} + (if $psk!="" then {pre_shared_key:$psk} else {} end)') || return 1
        peers=$(jq --argjson peer "$peer" '. + [$peer]' <<< "$peers") || return 1
    done
    value=$(jq -n --argjson address "$address" --arg private "$private" --argjson mtu "$mtu" --argjson listen "$listen" --argjson peers "$peers" --arg resolver "$resolver" \
        '{type:"wireguard",address:$address,private_key:$private,mtu:$mtu,listen_port:$listen,system:false,peers:$peers} + (if $resolver!="" then {domain_resolver:$resolver} else {} end)') || return 1
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

sbd_peer_cloudflare_prompt() {
    local token protocol edge=0
    sbd_peer_token_prompt || return $?; token="$SBD_REPLY"
    sbd_ui_options '[1] QUIC（默认）' '[2] HTTP/2（仅 TCP）'
    sbd_entry_number_prompt '连接协议' 1 2 1 || return $?; protocol=quic; [[ "$SBD_REPLY" != 2 ]] || protocol=http2
    sbd_ui_options '[1] 自动（默认）' '[2] 仅 IPv4' '[3] 仅 IPv6'
    sbd_entry_number_prompt 'Cloudflare 边缘 IP 协议栈' 1 3 1 || return $?
    if [[ "$SBD_REPLY" = 2 ]]; then edge=4; elif [[ "$SBD_REPLY" = 3 ]]; then edge=6; fi
    SBD_PEER_VALUE=$(jq -n --arg token "$token" --arg protocol "$protocol" --argjson edge "$edge" \
        '{type:"cloudflared",token:$token,protocol:$protocol} + (if $edge!=0 then {edge_ip_version:$edge} else {} end)') || return 1
    sbd_info '域名与回源目标请在 Cloudflare 控制台设置'
}

sbd_peer_cloudflare_edit() {
    local tag="$1" token value
    sbd_peer_token_prompt || return $?
    token="$SBD_REPLY"
    value=$(jq -c --arg tag "$tag" --arg token "$token" \
        '.inbounds[]? | select(.tag==$tag and .type=="cloudflared") | .token=$token' "$SBD_CONFIG") || { _error '读取现有隧道失败'; return 1; }
    [[ -n "$value" ]] || { _error '未找到该 Cloudflare Tunnel'; return 1; }
    sbd_policy_confirm || return $?
    sbd_apply sbd_peer_change connectors replace "$tag" "$value" || return 1
    sbd_success 'Cloudflare Tunnel token 已更新'
}

sbd_peer_list() {
    local wireguard cloudflared
    [[ -f "$SBD_CONFIG" ]] || { _error '配置尚未创建'; return 1; }
    wireguard=$(jq -r '.endpoints[]? | select(.type=="wireguard") |
        "  \(.tag)\n    address: \(.address|join(","))\n    mtu: \(.mtu // 1408)\n    peers: \(.peers|length)\n    listen_port: \(.listen_port // 0)"' "$SBD_CONFIG") || { _error '读取连接对象失败'; return 1; }
    cloudflared=$(jq -r '.inbounds[]? | select(.type=="cloudflared") |
        "  \(.tag)\n    protocol: \(.protocol // "quic")\n    edge_ip_version: \(if (.edge_ip_version // 0)==0 then "auto" else (.edge_ip_version|tostring) end)\n    grace_period: \(.grace_period // "默认")\n    control_dialer.detour: \(.control_dialer.detour // "无")\n    tunnel_dialer.detour: \(.tunnel_dialer.detour // "无")\n    token: \(if (.token|length)>12 then (.token[0:6]+"…"+.token[-4:]) else "…" end)"' "$SBD_CONFIG") || { _error '读取连接对象失败'; return 1; }
    printf 'WireGuard endpoints:\n%s\n' "${wireguard:-  （无）}"
    printf 'Cloudflare Tunnel:\n%s\n' "${cloudflared:-  （无）}"
    sbd_info '仅显示 WireGuard 与 Cloudflare Tunnel 配置，不显示密钥或完整 token'
}

sbd_peers_menu() {
    local choice area base tag value rc page values
    while true; do
        sbd_ui_menu '隧道管理' '[1] 查看隧道' '[2] 添加 WireGuard' '[3] 添加 Cloudflare Tunnel' \
            '[4] 修改 Cloudflare Tunnel（切换 token）' '[5] 删除隧道' '[0] 返回'
        sbd_config_hint
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 5 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) sbd_peer_list || return 1; sbd_ui_pause "$page"; continue ;;
            2|3)
                sbd_version >/dev/null || return 1
                area=endpoints
                if [[ "$choice" = 2 ]]; then base=wireguard; sbd_peer_wireguard_prompt
                else base=cloudflared; area=connectors; sbd_peer_cloudflare_prompt; fi
                rc=$?; [[ "$rc" = 0 ]] || return "$rc"; value="$SBD_PEER_VALUE"
                # 连接参数填完后再定 tag：默认取类型名，已占用时自动加序号。
                sbd_peer_tag_prompt "$(sbd_peer_tag_free "$base")" || return $?
                tag="$SBD_REPLY"
                value=$(jq --arg tag "$tag" '. + {tag:$tag}' <<< "$value") || return 1 ;;
            4)
                values=$(jq -c '[.policy.connectors[]?|select(.expected.type=="cloudflared")|{id,area:"connectors"}]' "$SBD_REGISTRY") || return 1
                sbd_policy_pick "$values" '选择 Cloudflare Tunnel' || return $?; tag="$SBD_REPLY"
                sbd_peer_cloudflare_edit "$tag" || return 1
                sbd_ui_pause "$page"; continue ;;
            5)
                values=$(jq -c '[.policy.endpoints[]?|select(.expected.type=="wireguard")|{id,area:"endpoints"}] + [.policy.connectors[]?|select(.expected.type=="cloudflared")|{id,area:"connectors"}]' "$SBD_REGISTRY") || return 1
                sbd_policy_pick "$values" '选择隧道' || return $?; tag="$SBD_REPLY"
                area=$(jq -er --arg tag "$tag" '.[]|select(.id==$tag)|.area' <<< "$values") || return 1
                sbd_policy_confirm || return $?
                sbd_apply sbd_peer_change "$area" delete "$tag" || return 1
                sbd_success '隧道已删除'; sbd_ui_pause "$page"; continue ;;
        esac
        sbd_policy_confirm || return $?
        sbd_apply sbd_peer_change "$area" add "$tag" "$value" || return 1
        sbd_success '隧道配置已保存'
        sbd_ui_pause "$page"
    done
}
