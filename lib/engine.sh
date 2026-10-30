#!/usr/bin/env bash

sbd_backend() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        printf 'systemd\n'
    elif command -v rc-service >/dev/null 2>&1 && [[ -d /run/openrc ]]; then
        printf 'openrc\n'
    else
        _error '未检测到支持的 systemd/OpenRC，不提供 direct 后端'
        return 1
    fi
}

sbd_service_file() {
    case "$1" in
        systemd) printf '/etc/systemd/system/%s.service\n' "$SBD_SERVICE" ;;
        openrc) printf '/etc/init.d/%s\n' "$SBD_SERVICE" ;;
        *) return 1 ;;
    esac
}

sbd_service_owned() {
    local backend="$1" file
    file=$(sbd_service_file "$backend") || return 1
    case "$backend" in
        systemd) grep -Fxq "ExecStart=$SBD_BINARY run -c $SBD_CONFIG -D $SBD_ROOT" "$file" 2>/dev/null ;;
        openrc) grep -Fxq "command=\"$SBD_BINARY\"" "$file" 2>/dev/null &&
            grep -Fxq "command_args=\"run -c $SBD_CONFIG -D $SBD_ROOT\"" "$file" 2>/dev/null ;;
    esac
}

sbd_service_state() {
    local backend file output rc=0 active='' sub='' pid='' line
    backend=$(sbd_backend) || return 1
    file=$(sbd_service_file "$backend") || return 1
    [[ -e "$file" ]] || { printf 'stopped\n'; return 0; }
    sbd_service_owned "$backend" || { _error '同名服务不属于本部署，拒绝操作'; return 1; }
    case "$backend" in
        systemd)
            output=$(systemctl show "$SBD_SERVICE" -p ActiveState -p SubState -p MainPID) || { _error '读取服务状态失败'; return 1; }
            while IFS= read -r line; do
                case "$line" in
                    ActiveState=*) active="${line#*=}" ;;
                    SubState=*) sub="${line#*=}" ;;
                    MainPID=*) pid="${line#*=}" ;;
                esac
            done <<< "$output"
            if [[ "$active" = active && "$sub" = running ]] && sbd_integer "$pid" 1 999999999 >/dev/null; then
                printf 'running\n'
            elif [[ "$active" = inactive || "$active" = failed ]] && [[ "$pid" = 0 ]]; then
                printf 'stopped\n'
            else
                _error '服务处于过渡或未知状态'
                return 1
            fi
            ;;
        openrc)
            output=$(rc-service "$SBD_SERVICE" status 2>&1) || rc=$?
            if [[ "$rc" = 0 && "$output" =~ status:[[:space:]]+started([[:space:]]|$) ]]; then
                printf 'running\n'
            elif [[ "$rc" = 3 && "$output" =~ status:[[:space:]]+stopped([[:space:]]|$) ]]; then
                printf 'stopped\n'
            else
                _error '无法确认 OpenRC 服务状态'
                return 1
            fi
            ;;
    esac
}

sbd_service_action() (
    local action="$1" backend
    case "$action" in restart|start|stop) ;; *) _error '不支持的服务动作'; return 1 ;; esac
    backend=$(sbd_backend) || return 1
    sbd_service_owned "$backend" || { _error '服务归属未确认，拒绝修改'; return 1; }
    # OpenRC 启动的守护进程不能继承管理器写锁。
    if [[ -n "${SBD_WRITE_FD:-}" ]]; then exec {SBD_WRITE_FD}>&-; fi
    case "$backend" in
        systemd) systemctl "$action" "$SBD_SERVICE" || { _error "服务 $action 失败"; return 1; } ;;
        openrc) rc-service "$SBD_SERVICE" "$action" || { _error "服务 $action 失败"; return 1; } ;;
    esac
)

sbd_service_restore() {
    local expected="$1" state i
    state=$(sbd_service_state) || return 1
    case "$expected" in
        running)
            sbd_service_action restart || return 1
            for ((i = 0; i < 3; i++)); do
                sleep 1
                state=$(sbd_service_state) || return 1
                [[ "$state" = running ]] || { _error '服务未持续运行'; return 1; }
            done
            ;;
        stopped)
            if [[ "$state" != stopped ]]; then sbd_service_action stop || return 1; fi
            state=$(sbd_service_state) || return 1
            [[ "$state" = stopped ]] || { _error '服务未停止'; return 1; }
            ;;
        *) _error '旧运行态无效'; return 1 ;;
    esac
}

sbd_logrotate_file() { printf '/etc/logrotate.d/singbox-deploy\n'; }

sbd_tree_compare() (
    local source="$1" copy="$2" path rel
    local -a files
    shopt -s nullglob dotglob
    files=("$source"/*)
    for path in "${files[@]}"; do
        rel="${path##*/}"
        if [[ -d "$path" && ! -L "$path" ]]; then
            if [[ ! -d "$copy/$rel" ]] || ! sbd_tree_compare "$path" "$copy/$rel"; then _error "目录副本不完整: $rel"; return 1; fi
        elif [[ -L "$path" ]]; then
            [[ -L "$copy/$rel" && "$(readlink "$path")" = "$(readlink "$copy/$rel")" ]] || { _error "链接副本不一致: $rel"; return 1; }
        else
            cmp -s -- "$path" "$copy/$rel" || { _error "包文件副本不一致: $rel"; return 1; }
        fi
    done
)

sbd_engine_stopped() {
    local path target
    sbd_service_restore stopped || return 1
    for path in /proc/[0-9]*/exe; do
        target=$(readlink "$path" 2>/dev/null) || continue
        if [[ "$target" = "$SBD_BINARY" || "$target" = "$SBD_BINARY (deleted)" ]]; then
            _error '服务报告停止但自有核心仍存在，拒绝替换核心包'
            return 1
        fi
    done
}

sbd_service_reload() {
    local backend
    backend=$(sbd_backend) || return 1
    if [[ "$backend" = systemd ]]; then
        systemctl daemon-reload || { _error 'systemd daemon-reload 失败'; return 1; }
    fi
}

sbd_service_enabled() {
    local backend path output rc=0
    if ! backend=$(sbd_backend) || ! path=$(sbd_service_file "$backend"); then _error '无法确定服务后端'; return 1; fi
    if [[ ! -e "$path" && ! -L "$path" ]]; then printf 'disabled\n'; return 0; fi
    sbd_service_owned "$backend" || { _error '同名服务不属于本部署'; return 1; }
    if [[ "$backend" = systemd ]]; then
        output=$(systemctl is-enabled "$SBD_SERVICE" 2>/dev/null) || rc=$?
        case "$output:$rc" in
            enabled:0) printf 'enabled\n' ;;
            disabled:1) printf 'disabled\n' ;;
            *) _error '自启状态未知或非可管理状态'; return 1 ;;
        esac
    else
        output=$(rc-update show default) || { _error '读取 OpenRC runlevel 失败'; return 1; }
        if awk -v name="$SBD_SERVICE" '$1==name {found=1} END {exit !found}' <<< "$output"; then
            printf 'enabled\n'
        else
            printf 'disabled\n'
        fi
    fi
}

sbd_service_set_enabled() {
    local expected="$1" backend path current action
    case "$expected" in enabled|disabled) ;; *) _error '自启目标无效'; return 1 ;; esac
    if ! backend=$(sbd_backend) || ! path=$(sbd_service_file "$backend"); then return 1; fi
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        [[ "$expected" = disabled ]] || { _error '服务尚未创建，无法启用自启'; return 1; }
        return 0
    fi
    sbd_service_owned "$backend" || { _error '不修改外来服务自启'; return 1; }
    current=$(sbd_service_enabled) || return 1
    [[ "$current" != "$expected" ]] || return 0
    if [[ "$backend" = systemd ]]; then
        action=disable; [[ "$expected" != enabled ]] || action=enable
        systemctl "$action" "$SBD_SERVICE" || { _error '修改 systemd 自启失败'; return 1; }
    else
        action=del; [[ "$expected" != enabled ]] || action=add
        rc-update "$action" "$SBD_SERVICE" default || { _error '修改 OpenRC 自启失败'; return 1; }
    fi
    current=$(sbd_service_enabled) || return 1
    [[ "$current" = "$expected" ]] || { _error '自启状态复验失败'; return 1; }
}

sbd_service_render() {
    local backend="$1" target="$2"
    case "$backend" in
        systemd)
            cat > "$target" <<EOF
[Unit]
Description=sing-box (singbox-deploy)
Wants=network-online.target
After=network-online.target nss-lookup.target
StartLimitIntervalSec=600
StartLimitBurst=20

[Service]
Type=simple
UMask=0077
ExecStart=$SBD_BINARY run -c $SBD_CONFIG -D $SBD_ROOT
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
            ;;
        openrc)
            cat > "$target" <<EOF
#!/sbin/openrc-run
name="sing-box (singbox-deploy)"
description="个人 NAT VPS sing-box 服务"
supervisor=supervise-daemon
respawn_delay=5
respawn_max=20
respawn_period=600
pidfile="/run/\${RC_SVCNAME}.pid"
command="$SBD_BINARY"
command_args="run -c $SBD_CONFIG -D $SBD_ROOT"
directory="$SBD_ROOT"
output_log="$SBD_LOG"
error_log="$SBD_LOG"
required_files="$SBD_CONFIG"
depend() {
    after net dns
}
start_pre() {
    umask 077
    checkpath -f -m 0600 "$SBD_LOG" || return 1
    "\$command" check -c "$SBD_CONFIG" -D "$SBD_ROOT"
}
EOF
            ;;
        *) _error '服务后端无效'; return 1 ;;
    esac || { _error '生成服务定义失败'; return 1; }
}

sbd_logrotate_render() {
    cat > "$1" <<EOF
"$SBD_LOG" {
    daily
    maxsize 1M
    rotate 3
    missingok
    notifempty
    compress
    copytruncate
    su root root
}
EOF
}

sbd_engine_asset() {
    local version="$1" arch="$2" family="$3" suffix=''
    version=$(sbd_release_version "$version") || return 1
    case "$arch" in amd64|arm64) ;; *) _error '发行包架构不支持'; return 1 ;; esac
    case "$family" in debian) ;; alpine) suffix=-musl ;; *) _error '发行包系统不支持'; return 1 ;; esac
    printf 'sing-box-%s-linux-%s%s.tar.gz\n' "$version" "$arch" "$suffix"
}

sbd_engine_fetch() {
    local requested="$1" stage="$2" arch family version asset endpoint tag
    if ! arch=$(sbd_arch) || ! family=$(sbd_os); then return 1; fi
    if [[ "$requested" = latest ]]; then
        endpoint='https://api.github.com/repos/SagerNet/sing-box/releases/latest'
    else
        version=$(sbd_release_version "$requested") || return 1
        endpoint="https://api.github.com/repos/SagerNet/sing-box/releases/tags/v$version"
    fi
    sbd_download "$endpoint" "$stage/release.json" || return 1
    tag=$(jq -er 'select(.prerelease==false and .draft==false) | .tag_name | select(type=="string")' "$stage/release.json") || { _error '远端没有明确稳定版记录'; return 1; }
    version=$(sbd_release_version "$tag") || return 1
    if [[ "$requested" != latest && "$version" != "$(sbd_release_version "$requested")" ]]; then _error '返回的 release 与指定版本不符'; return 1; fi
    asset=$(sbd_engine_asset "$version" "$arch" "$family") || return 1
    jq -e --arg name "$asset" '[.assets[]? | select(.name==$name)] | length==1' "$stage/release.json" >/dev/null || { _error "官方发行包不存在: $asset"; return 1; }
    sbd_download "https://github.com/SagerNet/sing-box/releases/download/v$version/$asset" "$stage/release.tar.gz" || return 1
    sbd_engine_unpack "$stage/release.tar.gz" "$stage/engine" "$version" "$asset"
}

sbd_engine_unpack() {
    local archive="$1" target="$2" version="$3" asset="$4" path actual
    mkdir -p -- "$target" || { _error '无法创建解压目录'; return 1; }
    tar -tzf "$archive" > "$target/../members.txt" || { _error '发行包不能读取'; return 1; }
    while IFS= read -r path; do
        [[ "$path" != /* && ! "$path" =~ (^|/)\.\.(/|$) && "$path" = */* ]] || { _error '发行包目录结构无效'; return 1; }
    done < "$target/../members.txt"
    tar -xzf "$archive" --strip-components=1 -C "$target" || { _error '发行包解压失败'; return 1; }
    actual=$(sbd_binary_version "$target/sing-box") || return 1
    [[ "$actual" = "$version" ]] || { _error '包内二进制版本与 release 不一致'; return 1; }
    if [[ "$asset" != *-musl.tar.gz && "$asset" != *-glibc.tar.gz ]]; then
        [[ -s "$target/libcronet.so" ]] || { _error '官方默认包缺少随包运行库 libcronet.so'; return 1; }
    fi
    python3 - "$target" <<'PY' || { _error '记录自有核心包文件清单失败'; return 1; }
from pathlib import Path
import sys
root=Path(sys.argv[1])
paths=sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file() and not p.is_symlink() and p.name!=".sbd-files")
(root/".sbd-files").write_text("\n".join(paths)+"\n")
PY
    if ! printf '%s\n' "$version" > "$target/../version" || ! printf '%s\n' "$asset" > "$target/../asset"; then _error '记录候选发行包失败'; return 1; fi
}

sbd_engine_logrotate_ready() {
    local family
    if ! command -v logrotate >/dev/null 2>&1; then
        family=$(sbd_os) || return 1
        [[ "$family" = alpine ]] || { _error 'OpenRC 日志轮换依赖 logrotate'; return 1; }
        apk add --no-cache logrotate || { _error '安装 logrotate 失败'; return 1; }
        command -v logrotate >/dev/null 2>&1 || { _error '安装后仍缺 logrotate'; return 1; }
    fi
    if ! rc-service crond status >/dev/null 2>&1; then
        rc-service crond start || { _error '日志日常轮换所需 crond 启动失败'; return 1; }
    fi
    rc-update add crond default || { _error 'crond 自启设置失败'; return 1; }
    rc-service crond status >/dev/null 2>&1 || { _error '无法确认 crond 运行'; return 1; }
}

sbd_engine_commit_locked() {
    local candidate="$1" dir="$SBD_WORK/active" stage="$SBD_WORK/active/after"
    local backend runtime enabled service logrotate version asset old_revision content mode expected installed_version
    sbd_directories && sbd_recover_locked || return 1
    if ! backend=$(sbd_backend) || ! runtime=$(sbd_service_state) || ! enabled=$(sbd_service_enabled); then return 1; fi
    if ! service=$(sbd_service_file "$backend") || ! logrotate=$(sbd_logrotate_file); then return 1; fi
    expected="$enabled"
    [[ -e "$service" || -L "$service" ]] || expected=enabled
    if [[ -L "$service" ]] || { [[ "$backend" = openrc ]] && [[ -L "$logrotate" ]]; }; then _error '服务或日志轮换路径是外部链接，拒绝覆盖'; return 1; fi
    if [[ "$backend" = openrc && -e "$logrotate" ]] && ! grep -Fq "\"$SBD_LOG\" {" "$logrotate"; then _error '同名日志轮换不属于本部署'; return 1; fi
    mkdir -p -- "$stage" || { _error '创建核心事务候选失败'; return 1; }
    trap sbd_apply_signal INT TERM HUP
    if [[ -f "$SBD_CONFIG" ]]; then cp "$SBD_CONFIG" "$stage/config.json"; else cp "$SBD_APP/presets/base.json" "$stage/config.json"; fi || { _error '暂存旧配置失败'; sbd_work_remove "$dir"; return 1; }
    if ! version=$(cat "$candidate/version") || ! asset=$(cat "$candidate/asset") ||
        ! old_revision=$(jq -er '.revision' "$SBD_STATE") || ! old_revision=$(sbd_integer "$old_revision" 0 999999998); then
        _error '候选版本或管理器状态不可读'; sbd_work_remove "$dir"; return 1
    fi
    if ! SBD_BINARY="$candidate/engine/sing-box" sbd_prepare_config "$stage" ||
        [[ "$(cat "$stage/core-version")" != "$version" ]] || ! sbd_service_render "$backend" "$stage/service"; then
        _error '候选核心、配置或服务定义验证失败'; sbd_work_remove "$dir"; return 1
    fi
    if [[ "$backend" = openrc ]]; then
        if ! sbd_logrotate_render "$stage/logrotate" || ! logrotate -d "$stage/logrotate" > "$stage/logrotate-check.log" 2>&1; then
            _error '日志轮换配置检查失败'; sbd_work_remove "$dir"; return 1
        fi
    fi
    content=$(jq --arg version "$version" --arg asset "$asset" --arg backend "$backend" --argjson revision "$((old_revision + 1))" \
        '. + {core_version:$version,core_asset:$asset,service_backend:$backend,revision:$revision}' "$SBD_STATE") || { _error '生成核心提交 state 失败'; sbd_work_remove "$dir"; return 1; }
    sbd_record_write "$stage/state.json" "$content" || { sbd_work_remove "$dir"; return 1; }
    sbd_snapshot "$dir" "$runtime" engine || { _error '核心快照失败，未替换生产文件'; return 1; }
    sbd_engine_stopped || { sbd_apply_abort; return 1; }
    mode=644; [[ "$backend" != openrc ]] || mode=755
    if ! sbd_directory_replace "$candidate/engine" engine ||
        ! sbd_atomic_file "$stage/schema.json" "$SBD_SCHEMA" ||
        ! sbd_atomic_file "$stage/config.json" "$SBD_CONFIG" ||
        ! sbd_atomic_file "$stage/service" "$service" "$mode"; then
        sbd_apply_abort; return 1
    fi
    if [[ "$backend" = openrc ]] && ! sbd_atomic_file "$stage/logrotate" "$logrotate" 644; then sbd_apply_abort; return 1; fi
    # 候选已做 Schema/format/check，发布过程逐文件比对，不再重复加载一遍核心配置。
    if ! installed_version=$(sbd_version) || [[ "$installed_version" != "$version" ]] ||
        ! sbd_service_reload || ! sbd_service_set_enabled "$expected" || ! sbd_service_restore "$runtime" ||
        ! sbd_atomic_file "$stage/state.json" "$SBD_STATE"; then
        _error '核心落地版本、服务应用或 state 提交失败'
        sbd_apply_abort; return 1
    fi
    content=$(jq '.phase="accepted"' "$dir/journal.json") || { _error '生成核心完成记录失败'; sbd_apply_abort; return 1; }
    sbd_record_write "$dir/journal.json" "$content" || { sbd_apply_abort; return 1; }
    sbd_finish_accepted || return 1
    trap - INT TERM HUP
}

sbd_engine_commit() { sbd_write_lock sbd_engine_commit_locked "$1"; }

sbd_engine_stage_remove() {
    local path="$1" resolved
    [[ -d "$path" && ! -L "$path" ]] || { _error '下载暂存目录无效'; return 1; }
    resolved=$(cd "$path" && pwd -P) || return 1
    case "$resolved" in "$SBD_WORK"/download.*) ;; *) _error '下载暂存路径范围无效'; return 1 ;; esac
    rm -rf -- "$resolved" || { _error '下载暂存清理失败'; return 1; }
}

sbd_engine_install() (
    local requested="$1" stage version backend rc=0
    sbd_directories || return 1
    stage=$(mktemp -d "$SBD_WORK/download.XXXXXX") || { _error '创建下载暂存目录失败'; return 1; }
    trap 'sbd_engine_stage_remove "$stage" || exit 1' EXIT
    sbd_engine_fetch "$requested" "$stage" || return 1
    version=$(cat "$stage/version") || { _error '读取候选版本失败'; return 1; }
    printf '将安装 sing-box %s；运行中升级会重启，原停止仍保持停止。\n' "$version"
    if [[ "$version" != 1.14.* ]]; then sbd_info '跨 1.14 基线：请先核对官方 changelog；不自动迁移弃用配置，候选校验失败将取消'; fi
    sbd_read_required '确认安装此稳定版本？输入 y 确认，其他输入取消' || return $?
    [[ "$SBD_REPLY" = y ]] || { sbd_info '已取消核心安装'; return 2; }
    backend=$(sbd_backend) || return 1
    if [[ "$backend" = openrc ]]; then sbd_engine_logrotate_ready || return 1; fi
    sbd_engine_commit "$stage" || rc=$?
    [[ "$rc" = 0 ]] || return 1
    sbd_success "核心 $version、匹配 Schema 与服务定义已提交；未验证外网连通"
)

sbd_engine_control_locked() {
    local action="$1" before after
    sbd_recover_locked || return 1
    before=$(sbd_service_state) || return 1
    case "$action" in
        start|restart)
            sbd_check_config || return 1
            if ! sbd_service_restore running; then
                sbd_service_restore "$before" || _error '服务原运行态恢复失败'
                return 1
            fi
            ;;
        stop) sbd_service_restore stopped || return 1 ;;
        enable|disable)
            before=$(sbd_service_enabled) || return 1
            after=disabled; [[ "$action" != enable ]] || after=enabled
            if ! sbd_service_set_enabled "$after"; then
                sbd_service_set_enabled "$before" || _error '原自启状态恢复失败'
                return 1
            fi
            ;;
        *) _error '核心控制动作无效'; return 1 ;;
    esac
}

sbd_uninstall_plan() {
    python3 "$SBD_APP/support/uninstall_plan.py" plan "$SBD_ROOT" "$1" || { _error '不能生成已知自有资源清单'; return 1; }
}

sbd_uninstall_locked() {
    local mode="$1" expected="$2" plan backend service rotate content helper="$SBD_WORK/uninstall-helper.py" path
    sbd_recover_locked || return 1
    backend=$(sbd_backend) && service=$(sbd_service_file "$backend") && rotate=$(sbd_logrotate_file) || return 1
    [[ ! -e "$service" ]] || sbd_service_owned "$backend" || { _error '不卸载外来服务'; return 1; }
    if [[ -e "$SBD_COMMAND" || -L "$SBD_COMMAND" ]]; then
        [[ -L "$SBD_COMMAND" && "$(readlink "$SBD_COMMAND")" = "$SBD_APP/singbox-deploy.sh" ]] || { _error '不删除非本部署的 sd'; return 1; }
    fi
    if [[ -e "$rotate" ]]; then grep -Fq "\"$SBD_LOG\" {" "$rotate" || { _error '不删除外来 logrotate 文件'; return 1; }; fi
    plan=$(sbd_uninstall_plan "$mode") || return 1
    [[ "$plan" = "$expected" ]] || { _error '卸载清单在确认后变化，请重新预览确认'; return 1; }
    sbd_record_write "$SBD_DATA/uninstall.json" "$plan" || return 1
    cp "$SBD_APP/support/uninstall_plan.py" "$helper" || { _error '保留可重试卸载 helper 失败'; return 1; }
    sbd_engine_stopped || return 1
    sbd_service_set_enabled disabled || return 1
    if [[ -e "$service" ]] && ! rm -- "$service"; then _error '服务文件删除失败，卸载未完成'; return 1; fi
    if [[ -e "$rotate" ]] && ! rm -- "$rotate"; then _error '轮换文件删除失败，卸载未完成'; return 1; fi
    sbd_service_reload || return 1
    # helper 与清单保留在部署树内，部分失败时可按准确路径重试，不假报完整卸载。
    python3 "$helper" apply "$SBD_DATA/uninstall.json" || { _error "文件卸载未完成；清单: $SBD_DATA/uninstall.json；重试: python3 $helper apply $SBD_DATA/uninstall.json"; return 1; }
    if [[ "$mode" = keep ]]; then
        content=$(jq '. + {installed:false}' "$SBD_STATE") || return 1
        sbd_record_write "$SBD_STATE" "$content" || return 1
    else
        for path in "$SBD_STATE" "$SBD_REGISTRY"; do rm -f -- "$path" || { _error '自有状态文件清理失败'; return 1; }; done
    fi
    rm -f -- "$SBD_COMMAND" || { _error '快捷命令清理失败'; return 1; }
    rm -f -- "$helper" "$SBD_DATA/uninstall.json" || { _error '卸载收尾未完成'; return 1; }
    sbd_info "未确认归属的残留及所选保留数据仍在 $SBD_ROOT；不删除部署根或其他服务"
}

sbd_uninstall_menu() {
    local mode plan
    sbd_policy_pick '["keep","purge"]' '卸载模式（keep 保留数据，purge 清除可确认自有数据）' || return $?
    mode="$SBD_REPLY"
    plan=$(sbd_uninstall_plan "$mode") || return 1
    jq '{mode,files,trees}' <<< "$plan" || return 1
    sbd_info "另将移除本部署服务、日志轮换和 $SBD_COMMAND；未知文件与外部文件保留。不可撤销清除的原生认证数据/文件接收不属于配置回滚"
    sbd_read_required "输入 uninstall-$mode 确认，其他输入取消" || return $?
    [[ "$SBD_REPLY" = "uninstall-$mode" ]] || return 2
    sbd_write_lock sbd_uninstall_locked "$mode" "$plan" || return 1
    # 由外层 console 消费，卸载后不再加载已删除的资源。
    # shellcheck disable=SC2034
    SBD_EXIT_MENU=true
    sbd_success '所选卸载步骤已完成；保留数据/未知残留范围已说明'
}

sbd_engine_menu() {
    local choice version page rc
    while true; do
        sbd_ui_menu '核心管理' '@安装与更新' '[1] 安装/更新最新稳定版' '[2] 指定稳定版' '@服务控制' '[3] 启动/重启' '[4] 停止' '[5] 启用自启' '[6] 关闭自启' '[0] 返回'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 6 || return 0
        choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) sbd_engine_install latest ;;
            2)
                while true; do
                    sbd_read_required '稳定版本（如 1.14.4）' || return 0
                    if version=$(sbd_release_version "$SBD_REPLY"); then break; fi
                done
                sbd_engine_install "$version"
                ;;
            3) sbd_write_lock sbd_engine_control_locked restart && sbd_success '服务已持续运行；未验证外网连通' ;;
            4) sbd_write_lock sbd_engine_control_locked stop && sbd_success '已确认服务停止' ;;
            5) sbd_write_lock sbd_engine_control_locked enable && sbd_success '已启用开机自启' ;;
            6) sbd_write_lock sbd_engine_control_locked disable && sbd_success '已关闭开机自启' ;;
        esac
        rc=$?
        if [[ "$rc" != 0 && "$rc" != 2 ]]; then _error '核心操作未完成，请检查上方错误'; fi
        sbd_ui_pause "$page"
    done
}
