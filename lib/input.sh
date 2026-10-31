#!/usr/bin/env bash

# 最近一次输出是否为字段提示：连续字段紧排，其余输出之后才空一行（对齐 xray-deploy 的紧凑向导）。
SBD_UI_AFTER_PROMPT=false

sbd_ui_terminal() { [[ -t 0 && -t 1 && "${TERM:-dumb}" != dumb ]]; }

sbd_ui_tint() {
    local color="$1" text="$2"
    if sbd_ui_terminal && [[ -z "${NO_COLOR:-}" ]]; then printf '\033[%sm%s\033[0m' "$color" "$text"
    else printf '%s' "$text"; fi
}

sbd_ui_message() {
    SBD_UI_AFTER_PROMPT=false
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
    local cols width inner pad=2 title="$1"
    SBD_UI_AFTER_PROMPT=false
    if sbd_ui_terminal; then printf '\033[H\033[2J'; fi
    SBD_UI_PAGE=$(( ${SBD_UI_PAGE:-0} + 1 ))
    if [[ "${2:-false}" = true ]]; then
        cols=$(sbd_ui_columns)
        width=$(sbd_ui_width "$title") || return 1
        inner=$((width+8)); (( inner >= 40 )) || inner=40
        (( inner <= cols-4 )) || inner=$((cols-4))
        if (( inner > width )); then pad=$((2+(inner-width)/2)); fi
    else
        # 子菜单标题与分组标题同为【】标记，对齐 xray-deploy 的层级写法。
        printf '\n'
        title="【${title}】"
    fi
    printf '%*s' "$pad" ''; sbd_ui_tint 36 "$title"; printf '\n\n'
}

sbd_ui_pause() {
    sbd_ui_terminal || return 0
    [[ -z "${1:-}" || "$1" = "${SBD_UI_PAGE:-0}" ]] || return 0
    SBD_UI_AFTER_PROMPT=false
    printf '\n  '; sbd_ui_tint 33 '按回车返回菜单…'; printf ' '
    if ! IFS= read -r; then SBD_UI_EOF=true; fi
}

sbd_ui_item() {
    local text="$1" number label
    if [[ "$text" =~ ^(\[[0-9]+\])[[:space:]](.*)$ ]]; then
        number="${BASH_REMATCH[1]}" label="${BASH_REMATCH[2]}"
        sbd_ui_tint 32 "$number"; printf ' %s' "$label"
    else printf '%s' "$text"; fi
}

sbd_ui_rows() {
    local cols left right width right_width pad span=24 gap="${SBD_UI_COLUMN_GAP:-6}"
    SBD_UI_AFTER_PROMPT=false
    cols=$(sbd_ui_columns)
    (( cols <= 100 )) || cols=100
    while (( $# > 0 )); do
        left="$1"; shift
        right="${1:-}"
        (( $# == 0 )) || shift
        width=$(sbd_ui_width "$left") || return 1
        right_width=$(sbd_ui_width "$right") || return 1
        # 短项共用右列起点；长菜单整组单列，直接渲染的长项也不强挤双列。
        if [[ "${SBD_UI_SINGLE_COLUMN:-false}" != true && -n "$right" ]] && (( cols >= 76 && width <= span-gap && right_width <= cols-span-4 )); then
            printf '  '; sbd_ui_item "$left"
            pad=$(( span-width )); printf '%*s' "$pad" ''
            sbd_ui_item "$right"; printf '\n'
        else
            printf '  '; sbd_ui_item "$left"; printf '\n'
            if [[ -n "$right" ]]; then printf '  '; sbd_ui_item "$right"; printf '\n'; fi
        fi
    done
}

sbd_ui_section() {
    SBD_UI_AFTER_PROMPT=false
    [[ "${2:-true}" != true ]] || printf '\n'
    printf '  '; sbd_ui_tint 36 "【$1】"; printf '\n'
}

sbd_ui_status_field() {
    local field="$1" label value color=36
    SBD_UI_AFTER_PROMPT=false
    if [[ "$field" != *': '* ]]; then printf '%s' "$field"; return 0; fi
    label="${field%%: *}" value="${field#*: }"
    case "$value" in
        *未知*) color=33 ;;
        *未安装*|*已停止*|*已关闭*|*未创建*|*未设置*) color=31 ;;
        *运行中*|*已开启*|*已存在*) color=32 ;;
    esac
    printf '%s: ' "$label"; sbd_ui_tint "$color" "$value"
}

sbd_ui_status_row() {
    local cols field width index=0 used=0 previous=0 pad gap
    local -a widths=()
    cols=$(sbd_ui_columns)
    for field in "$@"; do
        width=$(sbd_ui_width "$field") || return 1
        widths+=("$width")
    done
    for field in "$@"; do
        width="${widths[index]}"
        if [[ -n "$field" ]]; then
            if (( used > 0 )); then
                pad=$(( ${SBD_UI_STATUS_WIDTHS[index-1]:-0} - previous ))
                (( pad >= 0 )) || pad=0
                # 放不下对齐间距时先退为紧凑分隔，再按完整字段换行。
                (( used+pad+5+width <= cols-4 )) || pad=0
                gap=$((pad+5))
                if (( used+gap+width > cols-4 )); then
                    printf '\n'; used=0
                else
                    printf '%*s  |  ' "$pad" ''; used=$((used+gap))
                fi
            fi
            (( used > 0 )) || printf '  '
            sbd_ui_status_field "$field"
            used=$((used+width)); previous="$width"
        fi
        index=$((index+1))
    done
    (( used == 0 )) || printf '\n'
    return 0
}

sbd_ui_status_table() {
    local field width column index=0
    # 动态作用域只在本次表格内共享列宽，ANSI 着色不参与计宽。
    local -a SBD_UI_STATUS_WIDTHS=(0 0 0)
    for field in "$@"; do
        column=$((index%3))
        width=$(sbd_ui_width "$field") || return 1
        if (( width > SBD_UI_STATUS_WIDTHS[column] )); then SBD_UI_STATUS_WIDTHS[column]="$width"; fi
        index=$((index+1))
    done
    while (( $# > 0 )); do
        sbd_ui_status_row "$1" "${2:-}" "${3:-}" || return 1
        if (( $# <= 3 )); then break; fi
        shift 3
    done
}

sbd_ui_options() {
    local item width
    local SBD_UI_COLUMN_GAP=6 SBD_UI_SINGLE_COLUMN=false
    local -a rows=()
    SBD_UI_AFTER_PROMPT=false
    if [[ "${1:-}" = --compact ]]; then SBD_UI_COLUMN_GAP=2; shift; fi
    # 长说明不参与双列拼接；整组采用同一布局，避免长短项交替错落。
    for item in "$@"; do
        [[ "$item" != @* && "$item" != '[0] '* ]] || continue
        width=$(sbd_ui_width "$item") || return 1
        if (( width > 24-SBD_UI_COLUMN_GAP )); then SBD_UI_SINGLE_COLUMN=true; break; fi
    done
    for item in "$@"; do
        if [[ "$item" = @* || "$item" = '[0] '* ]]; then
            if (( ${#rows[@]} > 0 )); then sbd_ui_rows "${rows[@]}" || return 1; fi
            rows=()
            if [[ "$item" = @* ]]; then sbd_ui_section "${item#@}"
            else printf '\n'; sbd_ui_rows "$item" || return 1; fi
        else rows+=("$item"); fi
    done
    if (( ${#rows[@]} > 0 )); then sbd_ui_rows "${rows[@]}" || return 1; fi
}

sbd_ui_menu() {
    local title="$1"; shift
    sbd_ui_begin "$title"
    if [[ "${1:-}" = @* ]]; then
        sbd_ui_section "${1#@}" false
        shift
    fi
    sbd_ui_options "$@"
}

sbd_ui_prompt() {
    # 首个字段与上文隔一行，连续字段紧排；对齐 xray-deploy 的紧凑向导。
    [[ "${SBD_UI_AFTER_PROMPT:-false}" = true ]] || printf '\n' >&2
    printf '  %s: ' "$1" >&2
    SBD_UI_AFTER_PROMPT=true
}

# 读取一行到 SBD_REPLY：字段提示紧排后行尾换行由终端回显提供，重定向输入没有回显，需补一个换行。
sbd_ui_read_line() {
    local rc=0
    IFS= read -r SBD_REPLY || rc=$?
    [[ -t 0 ]] || printf '\n' >&2
    return "$rc"
}

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
        if ! sbd_ui_read_line; then
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
        sbd_ui_read_line || rc=$?
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

sbd_config_hint() {
    printf '\n  高级设置请直接编辑: %s\n' "$SBD_CONFIG"
}
