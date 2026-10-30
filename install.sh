#!/usr/bin/env bash
set -u
umask 077

_error() { printf '[错误] %s\n' "$*" >&2; }

sbd_install_manifest() {
    local source="$1" rel
    local -A seen=()
    SBD_INSTALL_FILES=()
    [[ -s "$source/manifest.txt" ]] || { _error '发布清单缺失'; return 1; }
    while IFS= read -r rel || [[ -n "$rel" ]]; do
        [[ "$rel" =~ ^[A-Za-z0-9_./-]+$ && "$rel" != /* && ! "$rel" =~ (^|/)\.\.(/|$) ]] || { _error '发布清单路径无效'; return 1; }
        [[ -z "${seen[$rel]:-}" ]] || { _error "发布清单重复: $rel"; return 1; }
        seen["$rel"]=1
        SBD_INSTALL_FILES+=("$rel")
    done < "$source/manifest.txt"
    for rel in install.sh singbox-deploy.sh VERSION manifest.txt lib/input.sh lib/host.sh lib/records.sh lib/apply.sh lib/console.sh support/validate_schema.py support/policy_records.py support/observe_api.py support/uninstall_plan.py presets/base.json; do
        [[ -n "${seen[$rel]:-}" ]] || { _error "发布清单缺少入口依赖: $rel"; return 1; }
    done
}

sbd_install_validate() {
    local source="$1" rel version
    sbd_install_manifest "$source" || return 1
    for rel in "${SBD_INSTALL_FILES[@]}"; do
        [[ -f "$source/$rel" && -s "$source/$rel" ]] || { _error "发布文件缺失或为空: $rel"; return 1; }
        if [[ "$rel" = *.sh ]]; then
            bash -n "$source/$rel" || { _error "发布脚本语法错误: $rel"; return 1; }
        fi
    done
    version=$(cat "$source/VERSION") || { _error '读取发布版本失败'; return 1; }
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { _error '管理器 VERSION 必须是稳定版三段数字'; return 1; }
}

sbd_install_fetch() {
    local url="$1" target="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --connect-timeout 15 --max-time 120 "$url" -o "$target" || { _error "下载失败: $url"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 120 -O "$target" "$url" || { _error "下载失败: $url"; return 1; }
    else
        _error '需要 curl 或 wget，当前未下载任何发布文件'
        return 1
    fi
    [[ -s "$target" ]] || { _error "下载为空: $url"; return 1; }
}

sbd_install_download() {
    local stage="$1" rel base='https://raw.githubusercontent.com/YOUIMARK/singbox-deploy/main'
    sbd_install_fetch "$base/manifest.txt" "$stage/manifest.txt" || return 1
    sbd_install_manifest "$stage" || return 1
    for rel in "${SBD_INSTALL_FILES[@]}"; do
        [[ "$rel" != manifest.txt ]] || continue
        mkdir -p -- "$(dirname -- "$stage/$rel")" || { _error '创建下载目录失败'; return 1; }
        sbd_install_fetch "$base/$rel" "$stage/$rel" || return 1
    done
    sbd_install_validate "$stage"
}

sbd_install_command() {
    mkdir -p -- "$(dirname -- "$SBD_COMMAND")" || { _error '创建命令目录失败'; return 1; }
    if [[ -e "$SBD_COMMAND" || -L "$SBD_COMMAND" ]]; then
        [[ -L "$SBD_COMMAND" && "$(readlink -- "$SBD_COMMAND")" = "$SBD_APP/singbox-deploy.sh" ]] || {
            _error "命令 sd 已被其他文件占用: $SBD_COMMAND"; return 1;
        }
    fi
    ln -sfn -- "$SBD_APP/singbox-deploy.sh" "$SBD_COMMAND" || { _error '发布 sd 命令失败'; return 1; }
}

sbd_install_publish_locked() {
    local source="$1" dir="$SBD_WORK/active" stage="$SBD_WORK/active/after" rel state version content
    sbd_directories || return 1
    sbd_recover_locked || return 1
    if [[ -e "$SBD_COMMAND" || -L "$SBD_COMMAND" ]]; then
        [[ -L "$SBD_COMMAND" && "$(readlink -- "$SBD_COMMAND")" = "$SBD_APP/singbox-deploy.sh" ]] || { _error '已有 sd 命令不属于本部署'; return 1; }
    fi
    mkdir -p -- "$stage/app" || { _error '无法创建安装候选目录'; return 1; }
    trap sbd_apply_signal INT TERM HUP
    for rel in "${SBD_INSTALL_FILES[@]}"; do
        if ! mkdir -p -- "$(dirname -- "$stage/app/$rel")" || ! cp -- "$source/$rel" "$stage/app/$rel"; then
            _error "暂存发布文件失败: $rel"; sbd_work_remove "$dir"; return 1
        fi
    done
    chmod 700 -- "$stage/app/singbox-deploy.sh" "$stage/app/install.sh" || { _error '设置入口执行权限失败'; sbd_work_remove "$dir"; return 1; }
    sbd_install_validate "$stage/app" || { sbd_work_remove "$dir"; return 1; }
    version=$(cat "$stage/app/VERSION") || { _error '读取管理器版本失败'; sbd_work_remove "$dir"; return 1; }
    if [[ -e "$SBD_STATE" ]]; then
        state=$(sbd_record_read "$SBD_STATE") || { sbd_work_remove "$dir"; return 1; }
    else
        state='{"format":1,"revision":0}'
    fi
    content=$(jq --arg version "$version" '. + {manager_version:$version,installed:true}' <<< "$state") || { _error '生成管理器 state 失败'; sbd_work_remove "$dir"; return 1; }
    sbd_record_write "$stage/state.json" "$content" || { sbd_work_remove "$dir"; return 1; }
    if [[ -e "$SBD_REGISTRY" ]]; then
        cp -- "$SBD_REGISTRY" "$stage/registry.json" || { _error '暂存 registry 失败'; sbd_work_remove "$dir"; return 1; }
    else
        sbd_record_write "$stage/registry.json" '{"format":1,"nodes":[]}' || { sbd_work_remove "$dir"; return 1; }
    fi
    sbd_records_check "$stage" || { sbd_work_remove "$dir"; return 1; }
    sbd_snapshot "$dir" unchanged install || { _error '安装快照失败，未发布新版本'; return 1; }
    if ! sbd_directory_replace "$stage/app" app ||
        ! sbd_install_validate "$SBD_APP" ||
        ! sbd_atomic_file "$stage/registry.json" "$SBD_REGISTRY" ||
        ! sbd_atomic_file "$stage/state.json" "$SBD_STATE" ||
        ! sbd_install_command; then
        sbd_apply_abort; return 1
    fi
    content=$(jq '.phase="accepted"' "$dir/journal.json") || { _error '生成安装完成记录失败'; sbd_apply_abort; return 1; }
    sbd_record_write "$dir/journal.json" "$content" || { sbd_apply_abort; return 1; }
    sbd_finish_accepted || return 1
    trap - INT TERM HUP
}

sbd_install_publish() {
    local source="$1" root="$2" command_path="$3" lock="$4"
    sbd_install_validate "$source" || return 1
    sbd_paths "$root" "$lock" "$command_path" || return 1
    sbd_write_lock sbd_install_publish_locked "$source"
}

sbd_install_cleanup() {
    local stage="$1"
    case "$stage" in "${TMPDIR:-/tmp}"/singbox-install.*) ;; *) _error '安装暂存目录范围无效'; return 1 ;; esac
    [[ -d "$stage" && ! -L "$stage" ]] || { _error '安装暂存目录无效'; return 1; }
    rm -rf -- "$stage" || { _error "清理安装暂存失败: $stage"; return 1; }
}

sbd_install_target() {
    case "$1" in
        root) printf '/opt/singbox-deploy\n' ;;
        command) printf '/usr/local/bin/sd\n' ;;
        lock) printf '/run/lock/singbox-deploy.lock\n' ;;
        *) _error '未知安装路径类别'; return 1 ;;
    esac
}

sbd_install_require_root() {
    [[ "$EUID" = 0 ]] || { _error '请以 root 运行安装器'; return 1; }
}

sbd_install_main() (
    local_mode=0 update=0 no_menu=0
    for arg in "$@"; do
        case "$arg" in
            --local) local_mode=1 ;;
            --update) update=1 ;;
            --no-menu) no_menu=1 ;;
            --help) printf '用法: bash install.sh [--local | --update] [--no-menu]\n'; return 0 ;;
            *) _error "未知安装参数: $arg"; return 1 ;;
        esac
    done
    [[ "$local_mode" != 1 || "$update" != 1 ]] || { _error '--local 与 --update 不能同时使用'; return 1; }
    sbd_install_require_root || return 1
    (( BASH_VERSINFO[0] >= 5 )) || { _error '需要 Bash 5 或更新版本'; return 1; }
    SBD_INSTALL_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/singbox-install.XXXXXX") || { _error '无法创建安装暂存目录'; return 1; }
    trap 'sbd_install_cleanup "$SBD_INSTALL_STAGE" || exit 1' EXIT
    if [[ "$local_mode" = 1 ]]; then
        source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || { _error '无法定位本地源码'; return 1; }
        sbd_install_validate "$source_dir" || return 1
        for rel in "${SBD_INSTALL_FILES[@]}"; do
            if ! mkdir -p -- "$(dirname -- "$SBD_INSTALL_STAGE/$rel")" || ! cp -- "$source_dir/$rel" "$SBD_INSTALL_STAGE/$rel"; then
                _error "本地源暂存失败: $rel"; return 1
            fi
        done
    else
        sbd_install_download "$SBD_INSTALL_STAGE" || return 1
    fi
    for rel in "${SBD_INSTALL_FILES[@]}"; do
        if [[ "$rel" = lib/*.sh ]]; then
            . "$SBD_INSTALL_STAGE/$rel" || { _error "加载安装模块失败: $rel"; return 1; }
        fi
    done
    sbd_os >/dev/null && sbd_arch >/dev/null || return 1
    if ! sbd_dependencies; then sbd_packages || return 1; fi
    if ! target_root=$(sbd_install_target root) || ! target_command=$(sbd_install_target command) || ! target_lock=$(sbd_install_target lock); then
        _error '无法解析安装路径'; return 1
    fi
    mkdir -p -- "$target_root" || { _error '无法创建部署根'; return 1; }
    sbd_install_publish "$SBD_INSTALL_STAGE" "$target_root" "$target_command" "$target_lock" || return 1
    sbd_install_cleanup "$SBD_INSTALL_STAGE" || return 1
    trap - EXIT
    sbd_success '管理器已安装；本次未安装或启动核心服务，请在核心管理菜单中安装核心'
    [[ "$no_menu" = 0 ]] || return 0
    exec "$target_command"
)

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then sbd_install_main "$@"; fi
