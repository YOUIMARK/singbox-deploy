#!/usr/bin/env bash

sbd_outbound_tag_exists() {
    local config="$1" tag="$2"
    jq -e --arg tag "$tag" '
        [.inbounds[]?, .outbounds[]?, .endpoints[]?, (.dns.servers? // [])[]]
        | any(if type == "object" then .tag == $tag else false end)
    ' "$config" >/dev/null
}

sbd_outbound_parse() {
    local link="$1" content
    content=$(printf '%s\n' "$link" | python3 "$SBD_APP/support/outbound_link.py") || return 1
    jq -e '
        (.tag == null or (.tag | type == "string")) and
        (.protocol | type == "string" and length > 0) and
        (.server | type == "string" and length > 0) and
        (.port | type == "number") and
        (.outbound | type == "object") and
        (.outbound.type | type == "string" and length > 0) and
        (.outbound | has("tag") | not)
    ' <<< "$content" >/dev/null || { _error '链接解析结果无效'; return 1; }
    SBD_OUTBOUND_DEFAULT_TAG=$(jq -r '.tag // empty' <<< "$content") || return 1
    SBD_OUTBOUND_PROTOCOL=$(jq -r '.protocol' <<< "$content") || return 1
    SBD_OUTBOUND_SERVER=$(jq -r '.server' <<< "$content") || return 1
    SBD_OUTBOUND_PORT=$(jq -r '.port' <<< "$content") || return 1
    SBD_OUTBOUND_VALUE=$(jq -c '.outbound' <<< "$content") || return 1
}

sbd_outbound_accept_tag() {
    local config="$1" tag="$2"
    sbd_tls_tag "$tag" || return 1
    [[ "$tag" != direct ]] || { _error 'direct 是保留出口 tag，请换一个'; return 1; }
    if sbd_outbound_tag_exists "$config" "$tag"; then
        _error "出口 tag 已存在: $tag，请换一个"
        return 1
    fi
}

sbd_outbound_add() {
    local stage="$1" outbound="$2" tag content
    sbd_record_write "$stage/outbound-request.json" "$outbound" || return 1
    tag=$(jq -er '.tag | select(type=="string" and length>0)' "$stage/outbound-request.json") || {
        _error '候选出口缺少 tag'
        return 1
    }
    sbd_tls_tag "$tag" || return 1
    [[ "$tag" != direct ]] || { _error 'direct 是保留出口 tag'; return 1; }
    jq -e '(.outbounds // []) | type == "array"' "$stage/config.json" >/dev/null || {
        _error '当前配置的 outbounds 不是数组，不能追加出口'
        return 1
    }
    if sbd_outbound_tag_exists "$stage/config.json" "$tag"; then
        _error "出口 tag 已存在: $tag"
        return 1
    fi
    content=$(jq --slurpfile outbound "$stage/outbound-request.json" \
        '.outbounds = ((.outbounds // []) + $outbound)' "$stage/config.json") || {
        _error '追加出口失败'
        return 1
    }
    sbd_record_write "$stage/config.json" "$content"
}

sbd_outbound_add_prompt() {
    local link tag config outbound
    sbd_ui_begin '添加出口'
    sbd_info '识别分享链接后只追加 outbounds，不修改 route.final 或现有分流规则'
    sbd_info '支持 Hysteria2/Hy2、AnyTLS、VLESS、VMess、Shadowsocks、SOCKS'
    sbd_version >/dev/null || return 1
    if [[ -f "$SBD_CONFIG" ]]; then
        sbd_check_config || return 1
        config="$SBD_CONFIG"
    else
        config="$SBD_APP/presets/base.json"
    fi
    sbd_read_secret '分享链接（含凭据）' || return $?
    link="$SBD_REPLY"
    sbd_outbound_parse "$link" || return 1
    sbd_info "已识别 $SBD_OUTBOUND_PROTOCOL: $SBD_OUTBOUND_SERVER:$SBD_OUTBOUND_PORT"

    if [[ -n "$SBD_OUTBOUND_DEFAULT_TAG" ]]; then
        while true; do
            sbd_entry_default '出口 tag' "$SBD_OUTBOUND_DEFAULT_TAG" || return $?
            sbd_outbound_accept_tag "$config" "$SBD_REPLY" && break
        done
    else
        while true; do
            sbd_read_required '出口 tag（链接没有可用 tag）' || return $?
            sbd_outbound_accept_tag "$config" "$SBD_REPLY" && break
        done
    fi
    tag="$SBD_REPLY"
    outbound=$(jq --arg tag "$tag" '. + {tag:$tag}' <<< "$SBD_OUTBOUND_VALUE") || {
        _error '构造出口失败'
        return 1
    }
    sbd_info "将添加出口: $tag；不会修改默认路由，可在 [8] 分流设置中选择"
    sbd_read_required '确认添加并按需重启？输入 y 确认，其他输入取消' || return $?
    [[ "$SBD_REPLY" = y ]] || return 2
    sbd_apply sbd_outbound_add "$outbound" || return 1
    sbd_success "出口已添加: $tag；route.final 未改变"
    sbd_service_after_change || sbd_info '出口已保存，但服务尚未运行；按上方提示处理后才会生效'
    sbd_ui_pause
}
