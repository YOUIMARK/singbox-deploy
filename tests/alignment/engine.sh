#!/usr/bin/env bash
# 服务与下载窄桩由真实生命周期函数调用；所有文件和核心校验使用实际实现。
# shellcheck disable=SC2329,SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

e_fixture() {
    local backend="${1:-systemd}" installed="${2:-yes}"
    t_fresh
    sbd_go_memlimit_mb() { printf '40\n'; }
    SBD_BINARY="$SBD_BIN_DIR/sing-box"
    mkdir -p "$CASE_TMP/etc" "$CASE_TMP/candidate/engine" || exit 1
    cp "$SBD_TEST_BIN" "$CASE_TMP/candidate/engine/sing-box" || exit 1
    # 随包文件必须参与整组替换，不能只测可执行文件。
    printf 'new-runtime-library' > "$CASE_TMP/candidate/engine/libcronet.so" || exit 1
    printf '1.14.4\n' > "$CASE_TMP/candidate/version" || exit 1
    printf 'sing-box-1.14.4-linux-amd64.tar.gz\n' > "$CASE_TMP/candidate/asset" || exit 1
    printf '%s\n' "$backend" > "$CASE_TMP/backend" || exit 1
    printf 'stopped\n' > "$CASE_TMP/runtime" || exit 1
    printf 'disabled\n' > "$CASE_TMP/enabled" || exit 1
    sbd_backend() { cat "$CASE_TMP/backend"; }
    sbd_service_file() { printf '%s/etc/service\n' "$CASE_TMP"; }
    sbd_logrotate_file() { printf '%s/etc/logrotate\n' "$CASE_TMP"; }
    sbd_openrc_service_file() { printf '%s/etc/%s\n' "$CASE_TMP" "$1"; }
    systemctl() {
        printf '%s\n' "$*" >> "$CASE_TMP/actions"
        case "$1" in
            show)
                if [[ "$(cat "$CASE_TMP/runtime")" = running ]]; then
                    printf 'ActiveState=active\nSubState=running\nMainPID=123\n'
                else
                    printf 'ActiveState=inactive\nSubState=dead\nMainPID=0\n'
                fi
                ;;
            is-enabled)
                cat "$CASE_TMP/enabled"
                [[ "$(cat "$CASE_TMP/enabled")" = enabled ]]
                ;;
            enable) printf 'enabled\n' > "$CASE_TMP/enabled" ;;
            disable) printf 'disabled\n' > "$CASE_TMP/enabled" ;;
            restart|start) printf 'running\n' > "$CASE_TMP/runtime" ;;
            stop) printf 'stopped\n' > "$CASE_TMP/runtime" ;;
            daemon-reload) return 0 ;;
            *) return 1 ;;
        esac
    }
    rc-service() {
        printf '%s\n' "$*" >> "$CASE_TMP/actions"
        case "$2" in
            status)
                printf ' * status: %s\n' "$(cat "$CASE_TMP/runtime" | sed 's/running/started/')"
                [[ "$(cat "$CASE_TMP/runtime")" = running ]] || return 3
                ;;
            restart|start) printf 'running\n' > "$CASE_TMP/runtime" ;;
            stop) printf 'stopped\n' > "$CASE_TMP/runtime" ;;
            *) return 1 ;;
        esac
    }
    rc-update() {
        printf '%s\n' "$*" >> "$CASE_TMP/actions"
        local action="$1"
        [[ "$action" != -q ]] || action="$2"
        case "$action" in
            show) if [[ "$(cat "$CASE_TMP/enabled")" = enabled ]]; then printf '%s | default\n' "$SBD_SERVICE"; fi ;;
            add) printf 'enabled\n' > "$CASE_TMP/enabled" ;;
            del) printf 'disabled\n' > "$CASE_TMP/enabled" ;;
            *) return 1 ;;
        esac
    }
    logrotate() { [[ "$1" = -d && -s "$2" ]]; }
    sleep() { :; }
    if [[ "$installed" = yes ]]; then
        cp "$SBD_TEST_BIN" "$SBD_BINARY" || exit 1
        printf 'old-runtime-library' > "$SBD_BIN_DIR/libcronet.so" || exit 1
        cp "$ROOT/tests/fixtures/valid.json" "$SBD_CONFIG" || exit 1
        t_prepare_live || exit 1
        sbd_service_render "$backend" "$CASE_TMP/etc/service" || exit 1
        if [[ "$backend" = openrc ]]; then sbd_logrotate_render "$CASE_TMP/etc/logrotate" || exit 1; fi
        cp "$SBD_CONFIG" "$CASE_TMP/old-config" || exit 1
        cp "$SBD_SCHEMA" "$CASE_TMP/old-schema" || exit 1
        cp "$CASE_TMP/etc/service" "$CASE_TMP/old-service" || exit 1
    fi
    cp "$SBD_STATE" "$CASE_TMP/old-state" || exit 1
}

e_old() {
    t_assert '核心恢复为真实旧文件' cmp -s "$SBD_BINARY" "$SBD_TEST_BIN"
    t_contains "$SBD_BIN_DIR/libcronet.so" old-runtime-library
    t_assert '配置还原原字节' cmp -s "$SBD_CONFIG" "$CASE_TMP/old-config"
    t_assert 'Schema 还原原字节' cmp -s "$SBD_SCHEMA" "$CASE_TMP/old-schema"
    t_assert '服务定义还原' cmp -s "$CASE_TMP/etc/service" "$CASE_TMP/old-service"
    t_assert 'state 还原' cmp -s "$SBD_STATE" "$CASE_TMP/old-state"
}

asset_contract() {
    t_assert '默认 amd64 包' test "$(sbd_engine_asset 1.14.4 amd64 debian)" = sing-box-1.14.4-linux-amd64.tar.gz
    t_assert 'Alpine musl 包' test "$(sbd_engine_asset v1.14.4 arm64 alpine)" = sing-box-1.14.4-linux-arm64-musl.tar.gz
    t_run 1 sbd_engine_asset 1.14.4 386 alpine
    t_run 1 sbd_engine_asset 1.14.4-beta.1 amd64 debian
    t_run 1 sbd_engine_asset 1.13.9 amd64 debian
    t_assert '规范化完整三段版本' test "$(sbd_release_version 01.014.004)" = 1.14.4
}
unpack_contract() {
    e_fixture
    mkdir -p "$CASE_TMP/package/sing-box-1.14.4-linux-amd64" || exit 1
    cp -a "$CASE_TMP/candidate/engine/." "$CASE_TMP/package/sing-box-1.14.4-linux-amd64/" || exit 1
    tar -czf "$CASE_TMP/archive.tar.gz" -C "$CASE_TMP/package" sing-box-1.14.4-linux-amd64 || exit 1
    t_run 0 sbd_engine_unpack "$CASE_TMP/archive.tar.gz" "$CASE_TMP/unpacked/engine" 1.14.4 sing-box-1.14.4-linux-amd64.tar.gz
    t_contains "$CASE_TMP/unpacked/engine/libcronet.so" new-runtime-library
    t_contains "$CASE_TMP/unpacked/engine/.sbd-files" sing-box
    t_contains "$CASE_TMP/unpacked/engine/.sbd-files" libcronet.so
    t_run 1 sbd_engine_unpack "$CASE_TMP/archive.tar.gz" "$CASE_TMP/wrong/engine" 1.14.3 sing-box-1.14.3-linux-amd64.tar.gz
    printf 'broken archive' > "$CASE_TMP/broken.tar.gz" || exit 1
    t_run 1 sbd_engine_unpack "$CASE_TMP/broken.tar.gz" "$CASE_TMP/broken/engine" 1.14.4 x.tar.gz
}
fetch_contract() {
    e_fixture
    sbd_os() { printf 'alpine\n'; }
    sbd_arch() { printf 'arm64\n'; }
    sbd_download() {
        printf '%s\n' "$1" >> "$CASE_TMP/downloads"
        if [[ "$1" = *api.github.com* ]]; then
            printf '{"tag_name":"v1.14.4","draft":false,"prerelease":false,"assets":[{"name":"sing-box-1.14.4-linux-arm64-musl.tar.gz","digest":"sha256:4bc37329ae8e38e8085fc102535e20204bc6fb3ff32b1f1b19b4a4828c048f9b"}]}' > "$2"
        else printf 'transport-boundary' > "$2"; fi
    }
    sbd_engine_unpack() { printf '%s\n' "$3 $4" > "$CASE_TMP/unpack-args"; }
    t_run 0 sbd_engine_fetch latest "$CASE_TMP"
    t_contains "$CASE_TMP/downloads" /releases/latest
    t_contains "$CASE_TMP/unpack-args" '1.14.4 sing-box-1.14.4-linux-arm64-musl.tar.gz'
    t_run 0 sbd_engine_fetch 1.14.4 "$CASE_TMP"
    t_contains "$CASE_TMP/downloads" /releases/tags/v1.14.4
}
fresh_install() {
    e_fixture systemd no
    t_run 0 sbd_engine_commit "$CASE_TMP/candidate"
    t_assert '首次安装默认自启' test "$(cat "$CASE_TMP/enabled")" = enabled
    t_assert '首次安装不意外启动' test "$(cat "$CASE_TMP/runtime")" = stopped
    t_contains "$CASE_TMP/etc/service" 'Environment="GOMEMLIMIT='
    t_assert 'state 记录实际包' jq -e '.core_version=="1.14.4" and .core_asset=="sing-box-1.14.4-linux-amd64.tar.gz" and .service_backend=="systemd" and .revision==1' "$SBD_STATE"
    t_run 0 sbd_check_config
    t_contains "$SBD_BIN_DIR/libcronet.so" new-runtime-library
    t_assert '基线无业务节点' jq -e '(.inbounds // [])==[]' "$SBD_CONFIG"
    t_assert '首次安装生成单配置' test -s "$SBD_CONFIG"
    t_assert '首次安装生成匹配 Schema' test -s "$SBD_SCHEMA"
    t_assert '首次安装不在部署根留下配置' test ! -e "$SBD_LEGACY_CONFIG" -a ! -e "$SBD_LEGACY_SCHEMA"
}
keep_reinstall() {
    e_fixture systemd yes
    rm "$SBD_BINARY" || exit 1
    t_run 0 sbd_engine_commit "$CASE_TMP/candidate"
    t_assert '重装后核心已恢复' test -x "$SBD_BINARY"
    t_assert '重装使用候选核心保留单配置' jq -e '.log.level=="warn"' "$SBD_CONFIG"
}
running_upgrade() {
    e_fixture
    printf 'running\n' > "$CASE_TMP/runtime" || exit 1
    printf 'enabled\n' > "$CASE_TMP/enabled" || exit 1
    t_run 0 sbd_engine_commit "$CASE_TMP/candidate"
    t_assert '运行态恢复' test "$(cat "$CASE_TMP/runtime")" = running
    t_assert '原有自启保留' test "$(cat "$CASE_TMP/enabled")" = enabled
    t_contains "$CASE_TMP/actions" stop
    t_contains "$CASE_TMP/actions" restart
}
kill_recover() {
    e_fixture
    mv() { if [[ "${!#}" = "$SBD_STATE" ]]; then kill -KILL "$BASHPID"; fi; command mv "$@"; }
    t_run 137 sbd_engine_commit "$CASE_TMP/candidate"
    t_contains "$SBD_BIN_DIR/libcronet.so" new-runtime-library
    unset -f mv
    t_run 0 sbd_recover
    e_old
}
logrotate_ready_contract() {
    e_fixture
    mkdir -p "$CASE_TMP/bin" "$CASE_TMP/etc" || exit 1
    printf '#!/bin/sh\nexit 0\n' > "$CASE_TMP/bin/logrotate" || exit 1
    chmod +x "$CASE_TMP/bin/logrotate" || exit 1
    PATH="$CASE_TMP/bin:$PATH"
    apk() {
        printf '%s\n' "$*" >> "$CASE_TMP/actions"
        case "$*" in
            'add --no-cache busybox-openrc') : > "$CASE_TMP/etc/crond"; : > "$CASE_TMP/etc/syslog" ;;
            'fix openrc busybox-openrc') : > "$CASE_TMP/etc/hostname"; : > "$CASE_TMP/etc/devfs"; : > "$CASE_TMP/etc/syslog"; : > "$CASE_TMP/etc/crond" ;;
        esac
    }
    sbd_os() { printf 'alpine\n'; }
    rc-service() {
        printf '%s\n' "$*" >> "$CASE_TMP/actions"
        case "$2" in
            status) [[ "$(cat "$CASE_TMP/$1.state" 2>/dev/null)" = running ]] ;;
            start) printf 'running\n' > "$CASE_TMP/$1.state" ;;
            stop) printf 'stopped\n' > "$CASE_TMP/$1.state" ;;
            *) return 1 ;;
        esac
    }
    t_run 0 sbd_engine_logrotate_ready
    t_contains "$CASE_TMP/actions" 'add --no-cache busybox-openrc'
    t_contains "$CASE_TMP/actions" 'fix openrc busybox-openrc'
    t_contains "$CASE_TMP/actions" 'syslog start'
    t_contains "$CASE_TMP/actions" 'crond start'
    t_contains "$CASE_TMP/actions" 'add crond default'
    t_assert 'syslog 已启动' test "$(cat "$CASE_TMP/syslog.state")" = running
    t_assert 'crond 已启动' test "$(cat "$CASE_TMP/crond.state")" = running
    t_assert 'crond 已自启' test "$(cat "$CASE_TMP/enabled")" = enabled
    : > "$CASE_TMP/actions"
    t_run 0 sbd_engine_logrotate_ready
    t_absent "$CASE_TMP/actions" 'add --no-cache busybox-openrc'
    t_absent "$CASE_TMP/actions" 'fix openrc busybox-openrc'
    t_absent "$CASE_TMP/actions" 'syslog start'
    t_absent "$CASE_TMP/actions" 'crond start'
}
t_case '稳定版与 amd64/arm64 默认-musl 映射' asset_contract
t_case '完整发行包解压与版本实测' unpack_contract
t_case 'latest 与指定稳定版下载实际参数' fetch_contract
t_case '首次核心安装自启但保持停止' fresh_install
t_case '核心文件缺失时使用候选核心保留单配置重装' keep_reinstall
t_case '运行升级停止后再启动验证' running_upgrade
t_case '核心提交 SIGKILL 后自动恢复' kill_recover
t_case 'OpenRC 基础服务缺失时修复包文件并启动日志依赖' logrotate_ready_contract
t_finish
