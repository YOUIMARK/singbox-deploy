#!/usr/bin/env bash

_error() { printf '[错误] %s\n' "$*" >&2; }
sbd_info() { printf '[信息] %s\n' "$*" >&2; }
sbd_success() { printf '[成功] %s\n' "$*" >&2; }

sbd_integer() {
    local value="${1:-}" low="${2:-0}" high="${3:-999999999}" zeros
    [[ "$value" =~ ^[0-9]+$ && "$low" =~ ^[0-9]{1,9}$ && "$high" =~ ^[0-9]{1,9}$ ]] || return 1
    zeros="${value%%[!0]*}"
    value="${value#"$zeros"}"
    value="${value:-0}"
    [[ ${#value} -le 9 ]] || return 1
    (( 10#$low <= 10#$high && 10#$value >= 10#$low && 10#$value <= 10#$high )) || return 1
    printf '%s\n' "$((10#$value))"
}

sbd_read_required() {
    local label="$1"
    SBD_REPLY=''
    while true; do
        printf '%s: ' "$label" >&2
        if ! IFS= read -r SBD_REPLY; then
            sbd_info '输入结束，已取消'
            return 2
        fi
        [[ -n "$SBD_REPLY" ]] && return 0
        _error '此字段不能为空，请重新输入'
    done
}

sbd_read_secret() {
    local label="$1"
    SBD_REPLY=''
    while true; do
        printf '%s（不回显）: ' "$label" >&2
        if ! IFS= read -rs SBD_REPLY; then
            printf '\n' >&2
            sbd_info '输入结束，已取消'
            return 2
        fi
        printf '\n' >&2
        [[ -n "$SBD_REPLY" ]] && return 0
        _error '此字段不能为空，请重新输入'
    done
}

sbd_read_optional() {
    local secret="${2:-false}" rc=0
    printf '%s（可留空）: ' "$1" >&2
    SBD_REPLY=''
    if [[ "$secret" = true ]]; then
        IFS= read -rs SBD_REPLY || rc=$?
        printf '\n' >&2
    else
        IFS= read -r SBD_REPLY || rc=$?
    fi
    [[ "$rc" = 0 ]] || { sbd_info '输入结束，已取消'; return 2; }
}

sbd_read_integer() {
    local label="$1" low="$2" high="$3" value
    while true; do
        sbd_read_required "$label" || return $?
        if value=$(sbd_integer "$SBD_REPLY" "$low" "$high"); then
            SBD_REPLY="$value"
            return 0
        fi
        _error "请输入 $low 到 $high 的十进制整数"
    done
}

sbd_unavailable() {
    _error "$1 尚未实现（等待对应模块交付）"
    return 1
}
