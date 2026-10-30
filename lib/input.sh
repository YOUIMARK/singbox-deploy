#!/usr/bin/env bash

sbd_ui_terminal() { [[ -t 0 && -t 1 && "${TERM:-dumb}" != dumb ]]; }

sbd_ui_tint() {
    local color="$1" text="$2"
    if sbd_ui_terminal && [[ -z "${NO_COLOR:-}" ]]; then printf '\033[%sm%s\033[0m' "$color" "$text"
    else printf '%s' "$text"; fi
}

sbd_ui_message() {
    sbd_ui_tint "$1" "[$2]"
    printf ' %s\n' "$3"
}

_error() { sbd_ui_message 31 错误 "$*" >&2; }
sbd_info() { sbd_ui_message 36 信息 "$*" >&2; }
sbd_success() { sbd_ui_message 32 成功 "$*" >&2; }

sbd_ui_columns() {
    local cols="${COLUMNS:-}" size
    if [[ -z "$cols" ]] && sbd_ui_terminal; then
        if size=$(stty size 2>/dev/null); then cols="${size##* }"; fi
    fi
    sbd_integer "${cols:-80}" 20 9999 || printf '80\n'
}

sbd_ui_width() {
    # 直接读取 UTF-8 字节，避开 musl 下 printf 将单个高位字节解释成字符的问题。
    local octets byte width=0
    octets=$(printf '%s' "$1" | LC_ALL=C od -An -tu1 -v) || { _error '读取菜单显示宽度失败'; return 1; }
    for byte in $octets; do
        if (( byte < 128 )); then width=$((width+1))
        elif (( byte >= 224 )); then width=$((width+2))
        elif (( byte >= 192 )); then width=$((width+1)); fi
    done
    printf '%s\n' "$width"
}

sbd_ui_begin() {
    local cols width inner pad=2
    if sbd_ui_terminal; then printf '\033[H\033[2J'; fi
    SBD_UI_PAGE=$(( ${SBD_UI_PAGE:-0} + 1 ))
    if [[ "${2:-false}" = true ]]; then
        cols=$(sbd_ui_columns)
        width=$(sbd_ui_width "$1") || return 1
        inner=$((width+8)); (( inner >= 40 )) || inner=40
        (( inner <= cols-4 )) || inner=$((cols-4))
        if (( inner > width )); then pad=$((2+(inner-width)/2)); fi
    fi
    printf '\n%*s' "$pad" ''; sbd_ui_tint '1;36' "$1"; printf '\n\n'
}

sbd_ui_pause() {
    sbd_ui_terminal || return 0
    [[ -z "${1:-}" || "$1" = "${SBD_UI_PAGE:-0}" ]] || return 0
    printf '\n  '; sbd_ui_tint 90 '按回车返回菜单…'; printf ' '
    if ! IFS= read -r; then SBD_UI_EOF=true; fi
}

sbd_ui_item() {
    local text="$1" number label color=32
    if [[ "$text" =~ ^(\[[0-9]+\])[[:space:]](.*)$ ]]; then
        number="${BASH_REMATCH[1]}" label="${BASH_REMATCH[2]}"
        case "$label" in *卸载*|*删除*|*reset*) color=31 ;; esac
        sbd_ui_tint "$color" "$number"; printf ' %s' "$label"
    else printf '%s' "$text"; fi
}

sbd_ui_rows() {
    local cols left right width right_width pad span=32
    cols=$(sbd_ui_columns)
    (( cols <= 100 )) || cols=100
    while (( $# > 0 )); do
        left="$1"; shift
        right="${1:-}"
        (( $# == 0 )) || shift
        width=$(sbd_ui_width "$left") || return 1
        right_width=$(sbd_ui_width "$right") || return 1
        # 所有页面共用固定右列起点；长项单列显示，但不打乱后续项目的配对。
        if [[ -n "$right" ]] && (( cols >= 76 && width <= span-2 && right_width <= cols-span-4 )); then
            printf '  '; sbd_ui_item "$left"
            pad=$(( span-width )); printf '%*s' "$pad" ''
            sbd_ui_item "$right"; printf '\n'
        else
            printf '  '; sbd_ui_item "$left"; printf '\n'
            if [[ -n "$right" ]]; then printf '  '; sbd_ui_item "$right"; printf '\n'; fi
        fi
    done
}

sbd_ui_section() { printf '\n  '; sbd_ui_tint 36 "【$1】"; printf '\n'; }

sbd_ui_status_row() {
    local cols field line='' candidate width
    cols=$(sbd_ui_columns)
    for field in "$@"; do
        candidate="$field"
        [[ -z "$line" ]] || candidate="$line  |  $field"
        width=$(sbd_ui_width "$candidate") || return 1
        if [[ -n "$line" ]] && (( width > cols-4 )); then
            printf '  %s\n' "$line"
            line="$field"
        else line="$candidate"; fi
    done
    [[ -z "$line" ]] || printf '  %s\n' "$line"
}

sbd_ui_options() {
    local item
    local -a rows=()
    for item in "$@"; do
        if [[ "$item" = @* || "$item" = '[0] '* ]]; then
            (( ${#rows[@]} == 0 )) || sbd_ui_rows "${rows[@]}"
            rows=()
            if [[ "$item" = @* ]]; then sbd_ui_section "${item#@}"
            else printf '\n'; sbd_ui_rows "$item"; fi
        else rows+=("$item"); fi
    done
    (( ${#rows[@]} == 0 )) || sbd_ui_rows "${rows[@]}"
}

sbd_ui_menu() {
    local title="$1"; shift
    sbd_ui_begin "$title"
    sbd_ui_options "$@"
}

sbd_ui_prompt() { printf '\n  ' >&2; sbd_ui_tint '1;36' "$1" >&2; printf ': ' >&2; }

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
    [[ "${SBD_UI_EOF:-false}" != true ]] || return 2
    SBD_REPLY=''
    while true; do
        sbd_ui_prompt "$label"
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
    [[ "${SBD_UI_EOF:-false}" != true ]] || return 2
    SBD_REPLY=''
    while true; do
        sbd_ui_prompt "$label（不回显）"
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
    [[ "${SBD_UI_EOF:-false}" != true ]] || return 2
    sbd_ui_prompt "$1（可留空）"
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
