#!/usr/bin/env bash

sbd_release_version() {
    local version="${1#v}" major minor patch
    [[ "$version" =~ ^([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})$ ]] || { _error '仅接受明确的稳定版三段版本号'; return 1; }
    major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
    major=$(sbd_integer "$major" 1 999999999) || return 1
    minor=$(sbd_integer "$minor" 0 999999999) || return 1
    patch=$(sbd_integer "$patch" 0 999999999) || return 1
    (( major > 1 || minor >= 14 )) || { _error '核心版本必须至少为 1.14.0'; return 1; }
    printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

sbd_binary_version() {
    local binary="$1"
    local output version
    [[ -x "$binary" ]] || { _error "核心未安装或不可执行: $binary"; return 1; }
    output=$("$binary" version) || { _error '读取核心版本失败'; return 1; }
    version="${output%%$'\n'*}"
    [[ "$version" = 'sing-box version '* ]] || { _error '无法识别核心版本输出'; return 1; }
    version="${version#sing-box version }"
    [[ "$version" != v* ]] || { _error '核心版本输出无效'; return 1; }
    sbd_release_version "$version"
}

sbd_version() { sbd_binary_version "$SBD_BINARY"; }

sbd_validate_schema() {
    python3 "$SBD_APP/support/validate_schema.py" "$1" "$2" || { _error '官方 JSON Schema 校验未通过'; return 1; }
}

sbd_config_parts_present() {
    local path
    local -a files
    [[ -d "$SBD_CONF_PARTS" && ! -L "$SBD_CONF_PARTS" ]] || return 1
    files=("$SBD_CONF_PARTS"/*.json)
    for path in "${files[@]}"; do
        [[ -e "$path" ]] || continue
        return 0
    done
    return 1
}

sbd_config_split() {
    local source="$1" dir="$2" known name keys entry
    local -a files
    [[ -f "$source" ]] || { _error "配置不存在: $source"; return 1; }
    [[ ! -L "$dir" ]] || { _error "配置分片目录不能是符号链接: $dir"; return 1; }
    rm -rf -- "$dir" || { _error "配置分片目录清理失败: $dir"; return 1; }
    mkdir -p -- "$dir" || { _error "配置分片目录创建失败: $dir"; return 1; }

    known='["log","dns","ntp","certificate","certificate_providers","http_clients","network_namespaces","endpoints","inbounds","outbounds","route","services","experimental"]'
    while IFS='|' read -r name keys; do
        [[ -n "$name" ]] || continue
        entry="$dir/$name"
        jq -S --argjson keys "$keys" \
            'del(."$schema") | with_entries(.key as $key | select($keys | index($key)))' \
            "$source" > "$entry.tmp" || { _error "配置分片生成失败: $name"; return 1; }
        if jq -e 'length > 0' "$entry.tmp" >/dev/null; then
            mv -f -- "$entry.tmp" "$entry" || { _error "配置分片写入失败: $name"; return 1; }
            chmod 600 -- "$entry" || { _error "配置分片权限设置失败: $name"; return 1; }
        else
            rm -f -- "$entry.tmp" || { _error "空配置分片清理失败: $name"; return 1; }
        fi
    done <<'EOF'
00_base.json|["log","ntp","certificate","certificate_providers","http_clients","network_namespaces"]
10_dns.json|["dns"]
20_endpoints.json|["endpoints"]
30_inbounds.json|["inbounds"]
40_outbounds.json|["outbounds"]
50_route.json|["route"]
60_services.json|["services"]
70_experimental.json|["experimental"]
EOF

    jq -S --argjson known "$known" \
        'del(."$schema") | with_entries(.key as $key | select(($known | index($key)) | not))' \
        "$source" > "$dir/90_extra.json.tmp" || { _error '扩展配置分片生成失败'; return 1; }
    if jq -e 'length > 0' "$dir/90_extra.json.tmp" >/dev/null; then
        mv -f -- "$dir/90_extra.json.tmp" "$dir/90_extra.json" || { _error '扩展配置分片写入失败'; return 1; }
        chmod 600 -- "$dir/90_extra.json" || { _error '扩展配置分片权限设置失败'; return 1; }
    else
        rm -f -- "$dir/90_extra.json.tmp" || { _error '空扩展配置分片清理失败'; return 1; }
    fi

    files=("$dir"/*.json)
    if [[ ! -e "${files[0]}" ]]; then
        printf '{}\n' > "$dir/00_base.json" || { _error '空配置分片写入失败'; return 1; }
        chmod 600 -- "$dir/00_base.json" || { _error '空配置分片权限设置失败'; return 1; }
    fi
}

# sing-box merge 会把证书文件展开成内嵌 PEM；两者同时存在时核心优先使用内嵌值，
# 会让续期后的文件失效。路径字段存在时必须删掉合并产物里的内嵌副本。
sbd_config_merge() {
    local binary="$1" parts="$2" output="$3" raw="$3.raw"
    local -a source_files
    [[ -x "$binary" ]] || { _error "合并配置需要可用核心: $binary"; return 1; }
    [[ -d "$parts" && ! -L "$parts" ]] || { _error "配置分片目录不存在: $parts"; return 1; }
    source_files=("$parts"/*.json)
    [[ -e "${source_files[0]}" ]] || { _error "配置分片目录为空: $parts"; return 1; }
    "$binary" merge "$raw" -C "$parts" -D "$SBD_ROOT" >/dev/null || { _error 'sing-box merge 失败'; return 1; }
    jq 'walk(if type == "object" then
            (if ((.certificate_path? // "") | type == "string" and length > 0) then del(.certificate) else . end)
            | (if ((.key_path? // "") | type == "string" and length > 0) then del(.key) else . end)
        else . end)' "$raw" > "$output" || {
        _error '合并配置后处理失败'; return 1
    }
    rm -f -- "$raw" || { _error '配置文件合并临时结果清理失败'; return 1; }
}

sbd_config_stage_current() {
    local target="$1" binary="${2:-$SBD_BINARY}" raw="$1.merge"
    mkdir -p -- "$(dirname -- "$target")" || { _error '暂存配置目录创建失败'; return 1; }
    if sbd_config_parts_present; then
        sbd_config_merge "$binary" "$SBD_CONF_PARTS" "$raw" || return 1
        jq '. + {"$schema":"./schema.json"}' "$raw" > "$target" || { _error '分片合并结果写入暂存失败'; return 1; }
        rm -f -- "$raw" || { _error '分片合并临时文件清理失败'; return 1; }
        return 0
    fi
    if [[ -f "$SBD_CONFIG" ]]; then
        cp -- "$SBD_CONFIG" "$target" || { _error '暂存配置失败'; return 1; }
    else
        cp -- "$SBD_APP/presets/base.json" "$target" || { _error '暂存基础配置失败'; return 1; }
    fi
}

sbd_prepare_config() {
    local stage="$1" version
    version=$(sbd_version) || return 1
    "$SBD_BINARY" schema -o "$stage/schema.json" || { _error '核心生成 Schema 失败'; return 1; }
    [[ -s "$stage/schema.json" ]] || { _error '核心生成了空 Schema'; return 1; }
    sbd_config_split "$stage/config.json" "$stage/config" || return 1
    sbd_config_merge "$SBD_BINARY" "$stage/config" "$stage/merged.json" || return 1
    jq '. + {"$schema":"./schema.json"}' "$stage/merged.json" > "$stage/input.json" || { _error '候选配置构造失败'; return 1; }
    sbd_validate_schema "$stage/schema.json" "$stage/input.json" || return 1
    "$SBD_BINARY" format -c "$stage/input.json" -D "$SBD_ROOT" > "$stage/formatted.json" || { _error '核心格式化失败'; return 1; }
    [[ -s "$stage/formatted.json" ]] || { _error '核心格式化输出为空'; return 1; }
    "$SBD_BINARY" check -c "$stage/formatted.json" -D "$SBD_ROOT" || { _error '核心语义检查失败'; return 1; }
    mv -f -- "$stage/formatted.json" "$stage/config.json" || { _error '暂存格式化配置失败'; return 1; }
    sbd_config_split "$stage/config.json" "$stage/config" || return 1
    rm -f -- "$stage/merged.json" "$stage/input.json" || { _error '配置合并临时文件清理失败'; return 1; }
    printf '%s\n' "$version" > "$stage/core-version" || { _error '暂存核心版本失败'; return 1; }
}

sbd_check_config_parts() {
    local temp formatted rc=0
    sbd_config_parts_present || return 0
    temp=$(mktemp -d "${TMPDIR:-/tmp}/singbox-config-check.XXXXXX") || { _error '无法创建配置分片检查目录'; return 1; }
    if ! sbd_config_merge "$SBD_BINARY" "$SBD_CONF_PARTS" "$temp/merged.json" ||
        ! jq '. + {"$schema":"./schema.json"}' "$temp/merged.json" > "$temp/input.json" ||
        ! "$SBD_BINARY" format -c "$temp/input.json" -D "$SBD_ROOT" > "$temp/formatted.json"; then
        rc=1
    else
        formatted="$temp/formatted.json"
        cmp -s -- "$formatted" "$SBD_CONFIG" || {
            _error '配置分片与运行配置不一致；请重新提交一次配置变更以重新合并'
            rc=1
        }
    fi
    rm -rf -- "$temp" || { _error "配置分片检查目录清理失败: $temp"; return 1; }
    return "$rc"
}

sbd_check_config() {
    [[ -f "$SBD_CONFIG" && -f "$SBD_SCHEMA" ]] || { _error '配置或本地 Schema 不存在'; return 1; }
    sbd_version >/dev/null || return 1
    sbd_validate_schema "$SBD_SCHEMA" "$SBD_CONFIG" || return 1
    "$SBD_BINARY" check -c "$SBD_CONFIG" -D "$SBD_ROOT" || { _error '核心语义检查失败'; return 1; }
    sbd_check_config_parts || return 1
}
