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
t_case '发行版契约' os_contract
t_case '架构契约' arch_contract
t_case '路径上下文与根目录拒绝' context_contract
t_case '真实 Draft202012 依赖不可降级' draft_required
t_case 'Go 软内存限制按物理内存与 cgroup 最小值计算' go_memlimit_contract
t_finish
