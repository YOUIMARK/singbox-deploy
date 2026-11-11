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
context_contract() {
    t_fresh
    t_assert '单配置位于 confs' test "$SBD_CONFIG" = "$CASE_TMP/root/confs/config.json"
    t_assert 'Schema 与配置同目录' test "$SBD_SCHEMA" = "$CASE_TMP/root/confs/schema.json"
    t_assert '命令为 sd' test "$SBD_COMMAND" = "$CASE_TMP/bin/sd"
    t_run 1 sbd_paths /
}
draft_required() {
    t_run 0 sbd_dependencies
    python3() { return 1; }
    t_run 1 sbd_dependencies
    t_contains "$CASE_TMP/output" 'Draft202012Validator'
}
curl_required() {
    command() {
        if [[ "$*" = '-v curl' ]]; then return 1; fi
        builtin command "$@"
    }
    t_run 1 sbd_dependencies
    t_contains "$CASE_TMP/output" '缺少依赖: curl'
}
go_memlimit_contract() {
    local mem="$CASE_TMP/meminfo" cg="$CASE_TMP/cgroup"
    mkdir -p "$cg/memory" || exit 1

    printf 'MemTotal: 131072 kB\n' > "$mem" || exit 1
    t_assert '128 MB 保留 40 MiB' test "$(sbd_go_memlimit_mb "$mem" "$cg")" = 40
    printf 'MemTotal: 1048576 kB\n' > "$mem" || exit 1
    t_assert '1 GB 按 80% 计算' test "$(sbd_go_memlimit_mb "$mem" "$cg")" = 819

    printf '536870912\n' > "$cg/memory.max" || exit 1
    printf '268435456\n' > "$cg/memory.high" || exit 1
    t_assert 'cgroup v2 取较低上限' test "$(sbd_go_memlimit_mb "$mem" "$cg")" = 128

    printf 'max\n' > "$cg/memory.max" || exit 1
    rm -f "$cg/memory.high" || exit 1
    printf '134217728\n' > "$cg/memory/memory.limit_in_bytes" || exit 1
    t_assert 'max 文本不参与且兼容 cgroup v1' test "$(sbd_go_memlimit_mb "$mem" "$cg")" = 40

    rm -f "$cg/memory/memory.limit_in_bytes" || exit 1
    printf 'MemTotal: 65536 kB\n' > "$mem" || exit 1
    t_assert '低于 128 MB 保留 32 MiB 下限' test "$(sbd_go_memlimit_mb "$mem" "$cg")" = 32

    printf '134217728\n' > "$cg/memory.max" || exit 1
    t_assert 'MemTotal 不可读时仍采用 cgroup 限制' test "$(sbd_go_memlimit_mb "$CASE_TMP/missing-meminfo" "$cg")" = 40
}
public_ip_fixture() {
    : > "$CASE_TMP/http-calls"
    curl() {
        printf '%s\n' "$*" >> "$CASE_TMP/http-calls"
        if [[ "$*" = *' -4 '* ]]; then
            [[ "${IP4_FAIL:-false}" != true ]] || return 1
            printf '%s' "${IP4_BODY:-8.8.8.8}"
        else
            [[ "${IP6_FAIL:-false}" != true ]] || return 1
            printf '%s' "${IP6_BODY:-2606:4700:4700::1111}"
        fi
    }
}
public_ip_ipv4() {
    public_ip_fixture
    IP4_BODY=$' 8.8.8.8\n'
    t_run 0 sbd_public_ip
    t_assert 'IPv4 响应去除首尾空白' test "$(cat "$CASE_TMP/output")" = 8.8.8.8
    t_assert 'IPv4 成功后不请求 IPv6' test "$(wc -l < "$CASE_TMP/http-calls")" = 1
    t_contains "$CASE_TMP/http-calls" '-4 --connect-timeout 2 --max-time 4 https://api.ipify.org'
}
public_ip_ipv6_fallback() {
    public_ip_fixture
    IP4_FAIL=true
    IP6_BODY='2606:4700:4700:0:0:0:0:1111'
    t_run 0 sbd_public_ip
    t_assert 'IPv4 失败后返回规范化 IPv6' test "$(cat "$CASE_TMP/output")" = 2606:4700:4700::1111
    t_contains "$CASE_TMP/http-calls" '-6 --connect-timeout 2 --max-time 4 https://api64.ipify.org'
}
public_ip_rejects_invalid() {
    public_ip_fixture
    IP6_FAIL=true
    local response
    for response in '<html>error</html>' example.com 192.168.1.1 127.0.0.1 100.64.0.1 224.0.0.1 2001:db8::1 '8.8.8.8 extra'; do
        IP4_BODY="$response"
        t_run 1 sbd_public_ip
        t_assert '无效或非公网响应不输出默认地址' test ! -s "$CASE_TMP/output"
    done
}
download_https_only() {
    local target="$CASE_TMP/download"
    t_run 1 sbd_download http://example.com/pkg "$target"
    t_contains "$CASE_TMP/output" '下载地址必须使用 HTTPS'
    command() {
        if [[ "$*" = '-v curl' ]]; then return 1; fi
        builtin command "$@"
    }
    t_run 1 sbd_download https://example.com/pkg "$target"
    t_contains "$CASE_TMP/output" '需要 curl 才能安全下载'
    t_assert '拒绝时不留下下载文件' test ! -e "$target"
    unset -f command
    # 桩 curl 记录参数：初始请求与全部重定向都必须限制在 HTTPS，防止 302 降级为明文。
    curl() {
        printf '%s\n' "$*" >> "$CASE_TMP/http-calls"
        while [[ "$#" -gt 0 ]]; do
            if [[ "$1" = -o ]]; then printf 'payload\n' > "$2"; fi
            shift
        done
    }
    : > "$CASE_TMP/http-calls"
    t_run 0 sbd_download https://example.com/pkg "$target"
    t_assert '下载文件已写入' test -s "$target"
    t_contains "$CASE_TMP/http-calls" '--proto =https'
    t_contains "$CASE_TMP/http-calls" '--proto-redir =https'
}
public_ip_wget_fallback() {
    command() {
        if [[ "$*" = '-v curl' ]]; then return 1; fi
        builtin command "$@"
    }
    wget() {
        printf '%s\n' "$*" >> "$CASE_TMP/http-calls"
        printf '1.1.1.1\n'
    }
    : > "$CASE_TMP/http-calls"
    t_run 0 sbd_public_ip
    t_assert '没有 curl 时用 wget 获取地址' test "$(cat "$CASE_TMP/output")" = 1.1.1.1
    t_contains "$CASE_TMP/http-calls" '-q -T 4 -O - https://api.ipify.org'
}
t_case '发行版契约' os_contract
t_case '架构契约' arch_contract
t_case '路径上下文与根目录拒绝' context_contract
t_case '真实 Draft202012 依赖不可降级' draft_required
t_case '安全下载要求 curl' curl_required
t_case '安全下载限制初始与重定向协议' download_https_only
t_case 'Go 软内存限制按物理内存与 cgroup 最小值计算' go_memlimit_contract
t_case '公网 IPv4 响应规范化并优先返回' public_ip_ipv4
t_case '公网 IPv4 失败后回退 IPv6' public_ip_ipv6_fallback
t_case '公网地址检测拒绝无效和非公网响应' public_ip_rejects_invalid
t_case '缺少 curl 时公网地址检测回退 wget' public_ip_wget_fallback
t_finish
