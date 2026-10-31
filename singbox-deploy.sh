#!/usr/bin/env bash
set -u
umask 077

sbd_loader_lock_path() { printf '/run/lock/singbox-deploy.lock\n'; }

sbd_cli_require_root() {
    [[ "$EUID" = 0 ]] || { printf '[错误] 请以 root 运行 sd\n' >&2; return 1; }
}

sbd_bootstrap() {
    local self app rel root kind='' lock_file loader_fd='' load_rc=0
    self=$(readlink -f -- "${BASH_SOURCE[0]}") || { printf '[错误] 无法定位入口\n' >&2; return 1; }
    app=$(dirname -- "$self")
    [[ -s "$app/manifest.txt" ]] || { printf '[错误] 安装清单缺失\n' >&2; return 1; }
    # 与安装发布共用同一把锁，加载期间不能跨两个发布版本读取模块。
    if [[ "$#" = 0 && "${app##*/}" = app ]]; then
        sbd_cli_require_root || return 1
        lock_file=$(sbd_loader_lock_path) || return 1
        if ! mkdir -p -- "$(dirname -- "$lock_file")" || ! { exec {loader_fd}>"$lock_file"; }; then
            printf '[错误] 无法取得模块加载锁\n' >&2; return 1
        fi
        if ! flock -n "$loader_fd"; then
            exec {loader_fd}>&-
            printf '[错误] 安装发布或其他变更正在进行，无法加载菜单\n' >&2; return 1
        fi
    fi
    while IFS= read -r rel || [[ -n "$rel" ]]; do
        [[ "$rel" =~ ^[A-Za-z0-9_./-]+$ && "$rel" != /* && ! "$rel" =~ (^|/)\.\.(/|$) ]] || { printf '[错误] 安装清单路径无效\n' >&2; load_rc=1; break; }
        [[ -s "$app/$rel" ]] || { printf '[错误] 发布文件缺失: %s\n' "$rel" >&2; load_rc=1; break; }
        if [[ "$rel" = lib/*.sh ]]; then
            . "$app/$rel" || { printf '[错误] 模块加载失败: %s\n' "$rel" >&2; load_rc=1; break; }
        fi
    done < "$app/manifest.txt" || load_rc=1
    if [[ -n "$loader_fd" ]]; then exec {loader_fd}>&-; fi
    [[ "$load_rc" = 0 ]] || return 1
    [[ "$#" -le 1 ]] || { _error '一次只接受一个入口参数'; return 1; }
    case "${1:-}" in
        --help) printf '用法: sd [--help | --version]\n无参数进入菜单；提供节点、DNS、分流、证书、隧道与服务管理。\n'; return 0 ;;
        --version) cat -- "$app/VERSION"; return $? ;;
    esac
    [[ "$#" = 0 ]] || { _error "未知参数: $*"; return 1; }
    [[ "${app##*/}" = app ]] || { _error '源码目录不是部署目录，请先运行安装器'; return 1; }
    sbd_terminal || return 1
    root=$(dirname -- "$app")
    sbd_paths "$root" || return 1
    sbd_dependencies || return 1
    if [[ -f "$SBD_WORK/active/journal.json" ]]; then
        kind=$(jq -r '.kind' "$SBD_WORK/active/journal.json") || { _error '读取恢复类别失败'; return 1; }
    fi
    sbd_recover || return 1
    if [[ "$kind" = install ]]; then
        [[ -x "$SBD_APP/singbox-deploy.sh" ]] || { _error '安装已恢复为未安装状态，请重新运行安装器'; return 1; }
        exec "$SBD_APP/singbox-deploy.sh"
    fi
    sbd_console
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then sbd_bootstrap "$@"; fi
