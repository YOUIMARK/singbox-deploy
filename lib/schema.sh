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

sbd_prepare_config() {
    local stage="$1" version
    version=$(sbd_version) || return 1
    "$SBD_BINARY" schema -o "$stage/schema.json" || { _error '核心生成 Schema 失败'; return 1; }
    [[ -s "$stage/schema.json" ]] || { _error '核心生成了空 Schema'; return 1; }
    jq '. + {"$schema":"./schema.json"}' "$stage/config.json" > "$stage/input.json" || { _error '候选配置构造失败'; return 1; }
    sbd_validate_schema "$stage/schema.json" "$stage/input.json" || return 1
    "$SBD_BINARY" format -c "$stage/input.json" -D "$SBD_ROOT" > "$stage/formatted.json" || { _error '核心格式化失败'; return 1; }
    [[ -s "$stage/formatted.json" ]] || { _error '核心格式化输出为空'; return 1; }
    "$SBD_BINARY" check -c "$stage/formatted.json" -D "$SBD_ROOT" || { _error '核心语义检查失败'; return 1; }
    mv -f -- "$stage/formatted.json" "$stage/config.json" || { _error '暂存格式化配置失败'; return 1; }
    printf '%s\n' "$version" > "$stage/core-version" || { _error '暂存核心版本失败'; return 1; }
}

sbd_check_config() {
    [[ -f "$SBD_CONFIG" && -f "$SBD_SCHEMA" ]] || { _error '配置或本地 Schema 不存在'; return 1; }
    sbd_version >/dev/null || return 1
    sbd_validate_schema "$SBD_SCHEMA" "$SBD_CONFIG" || return 1
    "$SBD_BINARY" check -c "$SBD_CONFIG" -D "$SBD_ROOT" || { _error '核心语义检查失败'; return 1; }
}
