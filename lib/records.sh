#!/usr/bin/env bash

sbd_object() {
    jq -es 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null 2>&1
}

sbd_atomic_file() {
    local source="$1" target="$2" mode="${3:-600}" tmp
    [[ -f "$source" && ! -d "$target" ]] || { _error "文件提交源或目标无效: $target"; return 1; }
    tmp=$(mktemp "${target}.XXXXXX") || { _error "无法创建提交临时文件: $target"; return 1; }
    if ! cp -- "$source" "$tmp" || ! cmp -s -- "$source" "$tmp" || ! chmod "$mode" -- "$tmp" || ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        _error "文件提交失败: $target"
        return 1
    fi
}

sbd_record_write() {
    local target="$1" content="$2" tmp
    tmp=$(mktemp "${target}.record.XXXXXX") || { _error "无法暂存记录: $target"; return 1; }
    if ! printf '%s\n' "$content" > "$tmp" || ! sbd_object "$tmp"; then
        rm -f -- "$tmp"
        _error "记录必须是单个 JSON 对象: $target"
        return 1
    fi
    if ! sbd_atomic_file "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
    rm -f -- "$tmp" || { _error "记录临时文件清理失败: $tmp"; return 1; }
}

sbd_record_read() {
    local path="$1"
    [[ -e "$path" ]] || { _error "记录不存在: $path"; return 1; }
    sbd_object "$path" || { _error "记录不可读或损坏: $path"; return 1; }
    cat -- "$path" || { _error "读取记录失败: $path"; return 1; }
}

sbd_records_check() {
    if ! sbd_object "$1/state.json" || ! jq -e '.format == 1 and (.revision | type == "number") and .revision >= 0 and .revision == (.revision | floor)' "$1/state.json" >/dev/null 2>&1; then
        _error 'state 格式或修订号无效'; return 1
    fi
    if ! sbd_object "$1/registry.json" || ! jq -e '.format == 1 and (.nodes | type == "array")' "$1/registry.json" >/dev/null 2>&1; then
        _error 'registry 格式无效'; return 1
    fi
    jq -e 'if has("tls") then
        (.tls|type=="object") and ((.tls.providers // [])|type=="array" and all(.[];type=="string" and length>0) and length==(unique|length)) and
        ((.tls.certificates // [])|type=="array" and all(.[];
            (.id|type=="string" and length>0) and (.kind=="import" or .kind=="self_signed") and
            (.server_name|type=="string" and length>0) and (.certificate_path|type=="string" and startswith("/")) and
            (.key_path|type=="string" and startswith("/")) and (.directory|type=="string")) and
            ([.[].id]|length==(unique|length))) else true end' "$1/registry.json" >/dev/null 2>&1 || { _error 'TLS 元数据无效'; return 1; }
    jq -e 'if has("policy") then
        .policy|type=="object" and all(to_entries[]; .key as $key | .value|type=="array" and all(.[];
            (.id|type=="string" and length>0) and (.expected|type=="object") and
            (if $key=="route_rules" or $key=="dns_rules" then (.index|type=="number" and floor==. and .>=0) else true end)))
        else true end' "$1/registry.json" >/dev/null 2>&1 || { _error '策略登记元数据无效'; return 1; }
}
