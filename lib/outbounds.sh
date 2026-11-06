#!/usr/bin/env bash

SBD_OUTBOUND_ACCEPTED=()
SBD_OUTBOUND_PREFETCH=''
SBD_OUTBOUND_PREFETCH_SET=false
SBD_OUTBOUND_INPUTS=()

sbd_outbound_tag() {
    local tag="$1"
    [[ -n "$tag" ]] || { _error '出口 tag 不能为空'; return 1; }
    ((${#tag} <= 128)) || { _error '出口 tag 最长 128 个字符'; return 1; }
    case "$tag" in
        *[\\/]*) _error "出口 tag 不能包含 / 或 \\"; return 1 ;;
        [[:space:]]*|*[[:space:]]) _error '出口 tag 首尾不能有空白'; return 1 ;;
    esac
    if printf '%s' "$tag" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        _error '出口 tag 不能包含控制字符'
        return 1
    fi
}

sbd_outbound_tag_exists() {
    local config="$1" tag="$2"
    jq -e --arg tag "$tag" '
        [.inbounds[]?, .outbounds[]?, .endpoints[]?, (.dns.servers? // [])[]]
        | any(if type == "object" then .tag == $tag else false end)
    ' "$config" >/dev/null
}

sbd_outbound_parse_batch() {
    local content
    if (($# == 0)); then
        _error '分享链接不能为空'
        return 1
    fi
    content=$(printf '%s\n' "$@" | python3 "$SBD_APP/support/outbound_link.py" --batch) || return 1
    jq -e '
        type == "array" and length > 0 and
        all(.[];
            (.tag == null or (.tag | type == "string")) and
            (.protocol | type == "string" and length > 0) and
            (.server | type == "string" and length > 0) and
            (.port | type == "number") and
            (.outbound | type == "object") and
            (.outbound.type | type == "string" and length > 0) and
            (.outbound | has("tag") | not)
        )
    ' <<< "$content" >/dev/null || { _error '链接解析结果无效'; return 1; }
    SBD_OUTBOUND_BATCH="$content"
    SBD_OUTBOUND_COUNT=$(jq 'length' <<< "$content") || return 1
    mapfile -t SBD_OUTBOUND_DEFAULT_TAGS < <(jq -r '.[].tag // ""' <<< "$content")
    mapfile -t SBD_OUTBOUND_PROTOCOLS < <(jq -r '.[].protocol' <<< "$content")
    mapfile -t SBD_OUTBOUND_SERVERS < <(jq -r '.[].server' <<< "$content")
    mapfile -t SBD_OUTBOUND_PORTS < <(jq -r '.[].port' <<< "$content")
}

sbd_outbound_accept_tag() {
    local config="$1" tag="$2" seen
    sbd_outbound_tag "$tag" || return 1
    [[ "$tag" != direct ]] || { _error 'direct 是保留出口 tag，请换一个'; return 1; }
    if sbd_outbound_tag_exists "$config" "$tag"; then
        _error "出口 tag 已存在: $tag，请换一个"
        return 1
    fi
    if ((${#SBD_OUTBOUND_ACCEPTED[@]})); then
        for seen in "${SBD_OUTBOUND_ACCEPTED[@]}"; do
            if [[ "$seen" = "$tag" ]]; then
                _error "本次添加的出口 tag 重复: $tag，请换一个"
                return 1
            fi
        done
    fi
}

sbd_outbound_add_many() {
    local stage="$1" request="$2" tag content record
    record=$(jq -c '{outbounds: .}' <<< "$request") || { _error '候选出口请求无效'; return 1; }
    sbd_record_write "$stage/outbound-request.json" "$record" || return 1
    jq -e '
        (.outbounds | type == "array" and length > 0 and all(.[];
            (.tag | type == "string" and length > 0) and
            (.type | type == "string" and length > 0) and
            (.server | type == "string" and length > 0) and
            (.server_port | type == "number")
        )) and
        (([.outbounds[].tag] | length) == ([.outbounds[].tag] | unique | length))
    ' "$stage/outbound-request.json" >/dev/null || {
        _error '候选出口请求无效或 tag 重复'
        return 1
    }
    jq -e '(.outbounds // []) | type == "array"' "$stage/config.json" >/dev/null || {
        _error '当前配置的 outbounds 不是数组，不能追加出口'
        return 1
    }
    while IFS= read -r tag; do
        sbd_outbound_tag "$tag" || return 1
        [[ "$tag" != direct ]] || { _error 'direct 是保留出口 tag'; return 1; }
        if sbd_outbound_tag_exists "$stage/config.json" "$tag"; then
            _error "出口 tag 已存在: $tag"
            return 1
        fi
    done < <(jq -r '.outbounds[].tag' "$stage/outbound-request.json")
    content=$(jq --slurpfile request "$stage/outbound-request.json" \
        '.outbounds = ((.outbounds // []) + $request[0].outbounds)' "$stage/config.json") || {
        _error '追加出口失败'
        return 1
    }
    sbd_record_write "$stage/config.json" "$content"
}

sbd_outbound_add() {
    local stage="$1" outbound="$2" request
    request=$(jq -c '[.]' <<< "$outbound") || { _error '候选出口无效'; return 1; }
    sbd_outbound_add_many "$stage" "$request"
}

sbd_outbound_read_tag() {
    local label="$1" default="$2" prompt
    if [[ -n "$default" ]]; then
        prompt="$label（默认 $default）"
    else
        prompt="$label（链接没有可用 tag）"
    fi
    if [[ "$SBD_OUTBOUND_PREFETCH_SET" = true ]]; then
        sbd_ui_prompt "$prompt"
        printf '%s' "${SBD_UI_PROMPT:-}" >&2
        printf '\n' >&2
        SBD_REPLY="${SBD_OUTBOUND_PREFETCH%$'\r'}"
        SBD_OUTBOUND_PREFETCH=''
        SBD_OUTBOUND_PREFETCH_SET=false
        if [[ -z "$SBD_REPLY" && -n "$default" ]]; then
            SBD_REPLY="$default"
        fi
        return 0
    fi
    if [[ -n "$default" ]]; then
        sbd_read_optional "$prompt" || return $?
        SBD_REPLY="${SBD_REPLY%$'\r'}"
        SBD_REPLY="${SBD_REPLY:-$default}"
    else
        sbd_read_required "$prompt" || return $?
        SBD_REPLY="${SBD_REPLY%$'\r'}"
    fi
}

sbd_outbound_read_links() {
    local line='' rc=0
    SBD_OUTBOUND_INPUTS=("${SBD_REPLY%$'\r'}")
    while true; do
        line=''
        IFS= read -r -t "${SBD_OUTBOUND_DRAIN_TIMEOUT:-1.0}" line
        rc=$?
        line="${line%$'\r'}"
        if [[ -n "$line" ]]; then
            if [[ "$line" == *"://"* ]]; then
                SBD_OUTBOUND_INPUTS+=("$line")
            else
                SBD_OUTBOUND_PREFETCH="$line"
                SBD_OUTBOUND_PREFETCH_SET=true
                return 0
            fi
        elif ((rc == 0)); then
            SBD_OUTBOUND_PREFETCH=''
            SBD_OUTBOUND_PREFETCH_SET=true
            return 0
        fi
        ((rc == 0)) || return 0
    done
}

sbd_outbound_add_prompt() {
    local config tag i count joined request tags_json
    local -a tags
    sbd_ui_begin '添加出口'
    sbd_info '识别分享链接后只追加 outbounds，不修改 route.final 或现有分流规则'
    sbd_info '支持 Hysteria2/Hy2、AnyTLS、VLESS、VMess、Shadowsocks、SOCKS'
    sbd_info '一次可粘贴一条或多条链接；多条会自动识别，也支持 v2rayN 的 Base64 整段'
    sbd_version >/dev/null || return 1
    if [[ -f "$SBD_CONFIG" ]]; then
        sbd_check_config || return 1
        config="$SBD_CONFIG"
    else
        config="$SBD_APP/presets/base.json"
    fi
    SBD_OUTBOUND_PREFETCH=''
    SBD_OUTBOUND_PREFETCH_SET=false
    sbd_read_required '分享链接' || return $?
    sbd_outbound_read_links
    sbd_outbound_parse_batch "${SBD_OUTBOUND_INPUTS[@]}" || {
        SBD_OUTBOUND_PREFETCH=''
        SBD_OUTBOUND_PREFETCH_SET=false
        return 1
    }
    count=$SBD_OUTBOUND_COUNT
    if ((count == 1)); then
        sbd_info "已识别 ${SBD_OUTBOUND_PROTOCOLS[0]}: ${SBD_OUTBOUND_SERVERS[0]}:${SBD_OUTBOUND_PORTS[0]}"
    else
        sbd_info "共识别 $count 个出口"
        for ((i = 0; i < count; i++)); do
            sbd_info "[$((i + 1))/$count] ${SBD_OUTBOUND_PROTOCOLS[$i]}: ${SBD_OUTBOUND_SERVERS[$i]}:${SBD_OUTBOUND_PORTS[$i]}"
        done
    fi

    tags=()
    SBD_OUTBOUND_ACCEPTED=()
    for ((i = 0; i < count; i++)); do
        local default="${SBD_OUTBOUND_DEFAULT_TAGS[$i]}" label='出口 tag'
        ((count == 1)) || label="出口 tag [$((i + 1))/$count]"
        while true; do
            sbd_outbound_read_tag "$label" "$default" || return $?
            sbd_outbound_accept_tag "$config" "$SBD_REPLY" && break
        done
        tag="$SBD_REPLY"
        tags+=("$tag")
        SBD_OUTBOUND_ACCEPTED+=("$tag")
    done

    tags_json=$(jq -n --args '$ARGS.positional' -- "${tags[@]}") || {
        _error '构造出口 tag 列表失败'
        return 1
    }
    request=$(jq -cn --argjson batch "$SBD_OUTBOUND_BATCH" --argjson tags "$tags_json" '
        [range(0; ($batch | length)) as $i | $batch[$i].outbound + {tag: $tags[$i]}]
    ') || { _error '构造出口失败'; return 1; }
    joined=$(printf '%s, ' "${tags[@]}") || return 1
    joined=${joined%, }
    if ((count == 1)); then
        sbd_info "将添加出口: $joined；不会修改默认路由，可在 [8] 分流设置中选择"
    else
        sbd_info "将添加 $count 个出口: $joined；不会修改默认路由，可在 [8] 分流设置中选择"
    fi
    sbd_read_required '确认添加并按需重启？输入 y 确认，其他输入取消' || return $?
    SBD_REPLY="${SBD_REPLY%$'\r'}"
    [[ "$SBD_REPLY" = y ]] || return 2
    sbd_apply sbd_outbound_add_many "$request" || return 1
    if ((count == 1)); then
        sbd_success "出口已添加: $joined；route.final 未改变"
    else
        sbd_success "已添加 $count 个出口: $joined；route.final 未改变"
    fi
    sbd_service_after_change || sbd_info '出口已保存，但服务尚未运行；按上方提示处理后才会生效'
    sbd_ui_pause
}
