#!/usr/bin/env bash
# 外部动作窄桩由真实生产函数间接调用。
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

os_contract() {
    local id expected
    for id in debian ubuntu alpine; do
        printf 'ID=%s\n' "$id" > "$CASE_TMP/os"
        expected=debian; [[ "$id" != alpine ]] || expected=alpine
        t_assert '平台正确归类' test "$(sbd_os "$CASE_TMP/os")" = "$expected"
    done
    printf 'ID=other\n' > "$CASE_TMP/os"
    t_run 1 sbd_os "$CASE_TMP/os"
    t_run 1 sbd_os "$CASE_TMP/missing"
}
arch_contract() {
    t_assert 'amd64 映射' test "$(sbd_arch x86_64)" = amd64
    t_assert 'arm64 映射' test "$(sbd_arch aarch64)" = arm64
    t_run 1 sbd_arch i686
}
system_label() {
    printf 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\n' > "$CASE_TMP/os"
    t_run 0 sbd_system_label "$CASE_TMP/os"
    t_contains "$CASE_TMP/output" 'Debian GNU/Linux 13 (trixie)'
    printf 'PRETTY_NAME="Alpine Linux v3.21"\n' > "$CASE_TMP/os"
    t_run 0 sbd_system_label "$CASE_TMP/os"
    t_contains "$CASE_TMP/output" 'Alpine Linux v3.21'
    printf 'ID=alpine\n' > "$CASE_TMP/os"
    t_run 1 sbd_system_label "$CASE_TMP/os"
    t_contains "$CASE_TMP/output" '缺少 PRETTY_NAME'
    t_run 1 sbd_system_label "$CASE_TMP/missing"
    printf 'PRETTY_NAME="unterminated\n' > "$CASE_TMP/os"
    t_run 1 sbd_system_label "$CASE_TMP/os"
    t_contains "$CASE_TMP/output" '无法解析系统名称'
}
context_contract() {
    t_fresh
    t_assert '单配置路径' test "$SBD_CONFIG" = "$CASE_TMP/root/config/config.json"
    t_assert '命令为 sd' test "$SBD_COMMAND" = "$CASE_TMP/bin/sd"
    t_run 1 sbd_paths /
}
draft_required() {
    t_run 0 sbd_dependencies
    python3() { return 1; }
    t_run 1 sbd_dependencies
    t_contains "$CASE_TMP/output" 'Draft202012Validator'
}
package_failure() {
    sbd_os() { printf 'debian\n'; }
    apt-get() { printf '%s\n' "$*" >> "$CASE_TMP/packages"; return 1; }
    t_run 1 sbd_packages
    t_contains "$CASE_TMP/packages" update
    t_absent "$CASE_TMP/packages" install
}
download_failure() {
    curl() { printf '错误页' > "$CASE_TMP/download"; return 22; }
    t_run 1 sbd_download https://example.invalid/file "$CASE_TMP/download"
    t_contains "$CASE_TMP/output" '下载失败'
}
t_case '发行版契约' os_contract
t_case '架构契约' arch_contract
t_case '系统展示读取真实 os-release 格式、缺失与损坏显式失败' system_label
t_case '路径上下文与根目录拒绝' context_contract
t_case '真实 Draft202012 依赖不可降级' draft_required
t_case '包索引失败不报安装成功' package_failure
t_case 'HTTP 下载失败显形' download_failure
t_finish
