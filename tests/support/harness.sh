#!/usr/bin/env bash
# 每个案例在子 shell 中运行；断言失败立即结束该案例，不依赖 set -e。
set -u
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/singbox-suite.XXXXXX") || exit 1
trap 'case "$SUITE_TMP" in "${TMPDIR:-/tmp}"/singbox-suite.*) rm -rf -- "$SUITE_TMP" ;; esac' EXIT
PASS=0 FAIL=0
while IFS= read -r rel; do
    if [[ "$rel" = lib/*.sh ]]; then . "$ROOT/$rel" || exit 1; fi
done < "$ROOT/manifest.txt"

t_assert() {
    local label="$1"; shift
    if "$@"; then return 0; fi
    printf '断言失败: %s\n' "$label" >&2
    exit 1
}

t_run() {
    local expected="$1" rc=0; shift
    "$@" > "$CASE_TMP/output" 2>&1 || rc=$?
    if [[ "$rc" != "$expected" ]]; then
        cat "$CASE_TMP/output" >&2
        printf '返回码: 期望 %s，实际 %s\n' "$expected" "$rc" >&2
        exit 1
    fi
}

t_case() {
    local label="$1"; shift
    CASE_TMP="$SUITE_TMP/case-$((PASS + FAIL + 1))"
    mkdir -- "$CASE_TMP" || exit 1
    if ( "$@" ) > "$CASE_TMP/case.log" 2>&1; then
        PASS=$((PASS + 1))
        printf '通过: %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf '失败: %s\n' "$label"
        tail -n 30 "$CASE_TMP/case.log"
    fi
}

t_contains() { t_assert "输出包含 $2" grep -Fq -- "$2" "$1"; }
t_absent() {
    local rc=0
    t_assert '被检查的日志必须存在' test -f "$1"
    grep -Fq -- "$2" "$1" || rc=$?
    t_assert "输出不含 $2" test "$rc" = 1
}
t_finish() { printf 'SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"; [[ "$FAIL" = 0 ]]; }

t_fresh() {
    local mode="${1:-warm}" rel
    mkdir -p -- "$CASE_TMP/root" "$CASE_TMP/bin" || exit 1
    sbd_paths "$CASE_TMP/root" "$CASE_TMP/write.lock" "$CASE_TMP/bin/sd" || exit 1
    sbd_directories || exit 1
    if [[ "$mode" = warm ]]; then
        while IFS= read -r rel; do
            mkdir -p -- "$(dirname -- "$SBD_APP/$rel")" || exit 1
            cp -- "$ROOT/$rel" "$SBD_APP/$rel" || exit 1
        done < "$ROOT/manifest.txt"
        sbd_record_write "$SBD_STATE" '{"format":1,"manager_version":"0.1.0","revision":0}' || exit 1
        sbd_record_write "$SBD_REGISTRY" '{"format":1,"nodes":[]}' || exit 1
    fi
    # 核心路径由 source 进来的生产函数消费。
    # shellcheck disable=SC2034
    SBD_BINARY="${SBD_TEST_BIN:?必须显式指定真实核心}"
}

t_stopped() {
    # 窄桩只替换服务边界，由真实事务函数调用。
    # shellcheck disable=SC2329
    sbd_service_state() { printf 'stopped\n'; }
    # shellcheck disable=SC2329
    sbd_service_restore() {
        [[ "$1" = stopped ]] || { printf '不应启动原来停止的服务\n' >&2; return 1; }
    }
}

t_seed() {
    t_fresh
    t_stopped
    cp -- "$ROOT/tests/fixtures/valid.json" "$SBD_CONFIG" || exit 1
    sbd_prepare_config "$SBD_CONFIG_DIR" || exit 1
    printf '旧链接\n' > "$SBD_EXPORTS/node.txt" || exit 1
    cp -- "$SBD_CONFIG" "$CASE_TMP/old-config" || exit 1
    cp -- "$SBD_SCHEMA" "$CASE_TMP/old-schema" || exit 1
    cp -- "$SBD_STATE" "$CASE_TMP/old-state" || exit 1
    cp -- "$SBD_REGISTRY" "$CASE_TMP/old-registry" || exit 1
}

t_unchanged() {
    t_assert '配置原字节保留' cmp -s "$SBD_CONFIG" "$CASE_TMP/old-config"
    t_assert 'Schema 原字节保留' cmp -s "$SBD_SCHEMA" "$CASE_TMP/old-schema"
    t_assert 'state 原字节保留' cmp -s "$SBD_STATE" "$CASE_TMP/old-state"
    t_assert 'registry 原字节保留' cmp -s "$SBD_REGISTRY" "$CASE_TMP/old-registry"
    t_contains "$SBD_EXPORTS/node.txt" '旧链接'
}

t_edit_debug() {
    jq '.log.level="debug"' "$1/config.json" > "$1/edit.json" || return 1
    mv -- "$1/edit.json" "$1/config.json" || return 1
    printf '新链接\n' > "$1/exports/node.txt" || return 1
}

t_gate() {
    local action="$1"
    t_fresh
    cp -- "$SBD_STATE" "$CASE_TMP/state-before" || exit 1
    t_run 1 "$action"
    t_contains "$CASE_TMP/output" '尚未实现'
    t_absent "$CASE_TMP/output" '[成功]'
    t_assert '未实现入口不改 state' cmp -s "$SBD_STATE" "$CASE_TMP/state-before"
    t_assert '未实现入口不创建配置' test ! -e "$SBD_CONFIG"
}
