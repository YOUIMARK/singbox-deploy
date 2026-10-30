#!/usr/bin/env bash
# 服务与下载窄桩由真实生命周期函数调用；所有文件和核心校验使用实际实现。
# shellcheck disable=SC2329,SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

e_fixture() {
    local backend="${1:-systemd}" installed="${2:-yes}"
    t_fresh
    SBD_BINARY="$SBD_ENGINE/sing-box"
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
        case "$1" in
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
        printf 'old-runtime-library' > "$SBD_ENGINE/libcronet.so" || exit 1
        cp "$ROOT/tests/fixtures/valid.json" "$SBD_CONFIG" || exit 1
        sbd_prepare_config "$SBD_CONFIG_DIR" || exit 1
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
    t_contains "$SBD_ENGINE/libcronet.so" old-runtime-library
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
missing_library() {
    e_fixture
    mkdir -p "$CASE_TMP/package/sing-box-test" || exit 1
    cp "$SBD_TEST_BIN" "$CASE_TMP/package/sing-box-test/sing-box" || exit 1
    tar -czf "$CASE_TMP/archive.tar.gz" -C "$CASE_TMP/package" sing-box-test || exit 1
    t_run 1 sbd_engine_unpack "$CASE_TMP/archive.tar.gz" "$CASE_TMP/unpacked/engine" 1.14.4 sing-box-1.14.4-linux-amd64.tar.gz
    t_contains "$CASE_TMP/output" libcronet.so
}
fetch_contract() {
    e_fixture
    sbd_os() { printf 'alpine\n'; }
    sbd_arch() { printf 'arm64\n'; }
    sbd_download() {
        printf '%s\n' "$1" >> "$CASE_TMP/downloads"
        if [[ "$1" = *api.github.com* ]]; then
            printf '{"tag_name":"v1.14.4","draft":false,"prerelease":false,"assets":[{"name":"sing-box-1.14.4-linux-arm64-musl.tar.gz"}]}' > "$2"
        else printf 'transport-boundary' > "$2"; fi
    }
    sbd_engine_unpack() { printf '%s\n' "$3 $4" > "$CASE_TMP/unpack-args"; }
    t_run 0 sbd_engine_fetch latest "$CASE_TMP"
    t_contains "$CASE_TMP/downloads" /releases/latest
    t_contains "$CASE_TMP/unpack-args" '1.14.4 sing-box-1.14.4-linux-arm64-musl.tar.gz'
    t_run 0 sbd_engine_fetch 1.14.4 "$CASE_TMP"
    t_contains "$CASE_TMP/downloads" /releases/tags/v1.14.4
}
bad_release() {
    e_fixture
    sbd_os() { printf 'debian\n'; }
    sbd_arch() { printf 'amd64\n'; }
    sbd_download() { printf '{"tag_name":"v1.14.4","draft":false,"prerelease":true,"assets":[]}' > "$2"; }
    t_run 1 sbd_engine_fetch latest "$CASE_TMP"
    t_contains "$CASE_TMP/output" '稳定版记录'
    e_old
}
fresh_install() {
    e_fixture systemd no
    t_run 0 sbd_engine_commit "$CASE_TMP/candidate"
    t_assert '首次安装默认自启' test "$(cat "$CASE_TMP/enabled")" = enabled
    t_assert '首次安装不意外启动' test "$(cat "$CASE_TMP/runtime")" = stopped
    t_assert 'state 记录实际包' jq -e '.core_version=="1.14.4" and .core_asset=="sing-box-1.14.4-linux-amd64.tar.gz" and .service_backend=="systemd" and .revision==1' "$SBD_STATE"
    t_run 0 sbd_check_config
    t_contains "$SBD_ENGINE/libcronet.so" new-runtime-library
    t_assert '基线无业务节点' jq -e '(.inbounds // [])==[]' "$SBD_CONFIG"
}
stopped_upgrade() {
    e_fixture
    t_run 0 sbd_engine_commit "$CASE_TMP/candidate"
    t_assert '保留关闭的自启' test "$(cat "$CASE_TMP/enabled")" = disabled
    t_assert '保留停止态' test "$(cat "$CASE_TMP/runtime")" = stopped
    t_absent "$CASE_TMP/actions" restart
    t_assert '新核心包完整提交' cmp -s "$SBD_BINARY" "$CASE_TMP/candidate/engine/sing-box"
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
openrc_install() {
    e_fixture openrc no
    t_run 0 sbd_engine_commit "$CASE_TMP/candidate"
    t_assert 'init 脚本有执行位' test -x "$CASE_TMP/etc/service"
    t_contains "$CASE_TMP/etc/service" supervise-daemon
    t_contains "$CASE_TMP/etc/logrotate" 'maxsize 1M'
    t_contains "$CASE_TMP/etc/logrotate" 'rotate 3'
    t_assert 'OpenRC 首次默认自启' test "$(cat "$CASE_TMP/enabled")" = enabled
    t_assert '不意外启动 OpenRC 核心' test "$(cat "$CASE_TMP/runtime")" = stopped
    t_run 0 sh -n "$CASE_TMP/etc/service"
}
foreign_service() {
    e_fixture
    printf 'ExecStart=/other/program\n' > "$CASE_TMP/etc/service" || exit 1
    t_run 1 sbd_engine_commit "$CASE_TMP/candidate"
    t_assert '未写配置' cmp -s "$SBD_CONFIG" "$CASE_TMP/old-config"
    t_contains "$CASE_TMP/etc/service" /other/program
}
schema_failure() {
    e_fixture
    printf '{"unknown":true}' > "$SBD_CONFIG" || exit 1
    cp "$SBD_CONFIG" "$CASE_TMP/old-config" || exit 1
    t_run 1 sbd_engine_commit "$CASE_TMP/candidate"
    e_old
    t_absent "$CASE_TMP/actions" stop
    t_absent "$CASE_TMP/actions" restart
}
service_write_failure() {
    e_fixture
    mv() {
        if [[ "${!#}" = "$CASE_TMP/etc/service" && ! -e "$CASE_TMP/fail" ]]; then : > "$CASE_TMP/fail"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_engine_commit "$CASE_TMP/candidate"
    t_assert '失败位于实际服务发布' test -e "$CASE_TMP/fail"
    e_old
}
state_write_failure() {
    e_fixture
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/fail" ]]; then : > "$CASE_TMP/fail"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_engine_commit "$CASE_TMP/candidate"
    t_assert '实际 state 提交失败' test -e "$CASE_TMP/fail"
    e_old
}
first_enable_failure() {
    e_fixture systemd no
    original=$(declare -f systemctl)
    eval "${original/systemctl ()/e_original_systemctl ()}"
    systemctl() { [[ "$1" != enable ]] || return 1; e_original_systemctl "$@"; }
    t_run 1 sbd_engine_commit "$CASE_TMP/candidate"
    t_assert '新服务移除' test ! -e "$CASE_TMP/etc/service"
    t_assert '新配置移除' test ! -e "$SBD_CONFIG"
    t_assert '新 Schema 移除' test ! -e "$SBD_SCHEMA"
    t_assert 'state 未假报新核心' cmp -s "$SBD_STATE" "$CASE_TMP/old-state"
    t_assert '仍为停止态' test "$(cat "$CASE_TMP/runtime")" = stopped
}
running_restart_failure() {
    e_fixture
    printf 'running\n' > "$CASE_TMP/runtime" || exit 1
    original=$(declare -f systemctl)
    eval "${original/systemctl ()/e_original_systemctl ()}"
    systemctl() {
        if [[ "$1" = restart && ! -e "$CASE_TMP/fail" ]]; then : > "$CASE_TMP/fail"; return 1; fi
        e_original_systemctl "$@"
    }
    t_run 1 sbd_engine_commit "$CASE_TMP/candidate"
    e_old
    t_assert '恢复旧运行态' test "$(cat "$CASE_TMP/runtime")" = running
}
kill_recover() {
    e_fixture
    mv() { if [[ "${!#}" = "$SBD_STATE" ]]; then kill -KILL "$BASHPID"; fi; command mv "$@"; }
    t_run 137 sbd_engine_commit "$CASE_TMP/candidate"
    t_contains "$SBD_ENGINE/libcronet.so" new-runtime-library
    unset -f mv
    t_run 0 sbd_recover
    e_old
}
failed_rollback() {
    e_fixture
    mv() { [[ "${!#}" != "$SBD_STATE" ]] || return 1; command mv "$@"; }
    t_run 1 sbd_engine_commit "$CASE_TMP/candidate"
    t_assert '回滚失败留核心完整快照' test -x "$SBD_WORK/active/before/engine/sing-box"
    t_assert '回滚失败留记录' test -s "$SBD_WORK/active/journal.json"
    unset -f mv
    t_run 0 sbd_recover
    e_old
}
accepted_recovery() {
    e_fixture
    mv() { [[ "${!#}" != "$SBD_WORK/previous" ]] || return 1; command mv "$@"; }
    t_run 1 sbd_engine_commit "$CASE_TMP/candidate"
    t_assert '已接受阶段' jq -e '.phase=="accepted"' "$SBD_WORK/active/journal.json"
    unset -f mv
    t_run 0 sbd_recover
    t_contains "$SBD_ENGINE/libcronet.so" new-runtime-library
    t_assert '已接受 state 不回退' jq -e '.revision==1' "$SBD_STATE"
}
partial_bundle() {
    e_fixture
    cp() {
        command cp "$@" || return 1
        if [[ "${!#}" = "$SBD_WORK/active/engine-next" && ! -e "$CASE_TMP/fail" ]]; then
            rm "$SBD_WORK/active/engine-next/libcronet.so" || return 1
            : > "$CASE_TMP/fail"
        fi
    }
    t_run 1 sbd_engine_commit "$CASE_TMP/candidate"
    e_old
}
menu_cancel_install() {
    e_fixture
    sbd_engine_fetch() {
        cp -a "$CASE_TMP/candidate/engine" "$2/engine" || return 1
        cp "$CASE_TMP/candidate/version" "$2/version" || return 1
        cp "$CASE_TMP/candidate/asset" "$2/asset"
    }
    t_run 2 sbd_engine_install latest < /dev/null
    e_old
    t_run 2 sbd_engine_install latest <<< n
    e_old
}
enable_unknown() {
    e_fixture
    original=$(declare -f systemctl)
    eval "${original/systemctl ()/e_original_systemctl ()}"
    systemctl() { if [[ "$1" = is-enabled ]]; then printf 'masked\n'; return 1; fi; e_original_systemctl "$@"; }
    t_run 1 sbd_engine_commit "$CASE_TMP/candidate"
    e_old
    t_assert '未知自启不进入提交' test ! -e "$SBD_WORK/active/journal.json"
}
reload_failure() {
    e_fixture
    original=$(declare -f systemctl)
    eval "${original/systemctl ()/e_original_systemctl ()}"
    systemctl() {
        if [[ "$1" = daemon-reload && ! -e "$CASE_TMP/fail" ]]; then : > "$CASE_TMP/fail"; return 1; fi
        e_original_systemctl "$@"
    }
    t_run 1 sbd_engine_commit "$CASE_TMP/candidate"
    e_old
}
openrc_log_failure() {
    e_fixture openrc
    cp "$CASE_TMP/etc/logrotate" "$CASE_TMP/old-logrotate" || exit 1
    mv() {
        if [[ "${!#}" = "$CASE_TMP/etc/logrotate" && ! -e "$CASE_TMP/fail" ]]; then : > "$CASE_TMP/fail"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_engine_commit "$CASE_TMP/candidate"
    e_old
    t_assert '轮换配置恢复旧字节' cmp -s "$CASE_TMP/etc/logrotate" "$CASE_TMP/old-logrotate"
    t_assert '恢复 init 脚本执行位' test -x "$CASE_TMP/etc/service"
}
start_stop_controls() {
    e_fixture
    t_run 0 sbd_write_lock sbd_engine_control_locked restart
    t_assert '手动启动持续运行' test "$(cat "$CASE_TMP/runtime")" = running
    t_run 0 sbd_write_lock sbd_engine_control_locked stop
    t_assert '手动停止终态' test "$(cat "$CASE_TMP/runtime")" = stopped
    t_run 0 sbd_write_lock sbd_engine_control_locked enable
    t_assert '自启切换可见' test "$(cat "$CASE_TMP/enabled")" = enabled
    t_run 0 sbd_write_lock sbd_engine_control_locked disable
    t_assert '自启关闭可见' test "$(cat "$CASE_TMP/enabled")" = disabled
}

t_case '稳定版与 amd64/arm64 默认-musl 映射' asset_contract
t_case '完整发行包解压与版本实测' unpack_contract
t_case '默认包缺运行库明确失败' missing_library
t_case 'latest 与指定稳定版下载实际参数' fetch_contract
t_case '预发布拒绝，不动旧包' bad_release
t_case '首次核心安装自启但保持停止' fresh_install
t_case '停止升级保留自启关闭与停止态' stopped_upgrade
t_case '运行升级停止后再启动验证' running_upgrade
t_case 'OpenRC 服务执行位和轮换参数' openrc_install
t_case '拒绝覆盖外来服务定义' foreign_service
t_case '候选真实 Schema 失败不碰旧包' schema_failure
t_case '服务文件提交失败恢复整组' service_write_failure
t_case '核心 state 写失败恢复完整旧包' state_write_failure
t_case '首次自启失败回到未安装事实' first_enable_failure
t_case '新核心启动失败回滚并恢复旧运行态' running_restart_failure
t_case '核心提交 SIGKILL 后自动恢复' kill_recover
t_case '核心回滚失败保留并可重试' failed_rollback
t_case '已接受核心收尾失败不逆转' accepted_recovery
t_case '随包库部分复制失败不能发布' partial_bundle
t_case '安装确认 EOF 与拒绝不变更' menu_cancel_install
t_case '未知自启状态不能猜测覆盖' enable_unknown
t_case 'daemon-reload 失败恢复旧版本' reload_failure
t_case 'OpenRC 轮换提交失败整组恢复' openrc_log_failure
t_case '手动重启停止与自启控制' start_stop_controls
t_finish
