#!/usr/bin/env bash
set -u
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 1
FAIL=0 PASS=0 SKIPPED=0
if [[ -z "${SBD_TEST_BIN:-}" || ! -x "$SBD_TEST_BIN" ]]; then
    printf '失败: 请显式设置可执行的 SBD_TEST_BIN；不自动下载或跳过\nSUMMARY pass=0 fail=1\n' >&2
    exit 1
fi
SBD_TEST_BIN=$(readlink -f -- "$SBD_TEST_BIN") || exit 1
export SBD_TEST_BIN
for tool in jq python3 flock cmp mktemp openssl; do
    command -v "$tool" >/dev/null 2>&1 || { printf '失败: 缺少 %s\nSUMMARY pass=0 fail=1\n' "$tool" >&2; exit 1; }
done
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    printf '失败: 缺少 curl/wget，拒绝让安装测试触发真实包安装\nSUMMARY pass=0 fail=1\n' >&2
    exit 1
fi
python3 -c 'from jsonschema import Draft202012Validator' >/dev/null 2>&1 || { printf '失败: 缺少 Draft202012Validator\nSUMMARY pass=0 fail=1\n' >&2; exit 1; }
core_version=$("$SBD_TEST_BIN" version) || { printf '失败: 无法执行测试核心\nSUMMARY pass=0 fail=1\n' >&2; exit 1; }
[[ "${core_version%%$'\n'*}" = 'sing-box version 1.14.4' ]] || { printf '失败: 本阶段验收核心须为 1.14.4\nSUMMARY pass=0 fail=1\n' >&2; exit 1; }
printf '测试核心: %s\n' "${core_version%%$'\n'*}"
for file in "$ROOT"/install.sh "$ROOT"/singbox-deploy.sh "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh "$ROOT"/tests/*/*.sh; do
    bash -n "$file" || { printf '失败: Bash 语法 %s\nSUMMARY pass=0 fail=1\n' "$file" >&2; exit 1; }
done
# 重型套件：真实核心 Schema/check、真实服务操作或 DNS 竞速，单套件 40 秒以上（合计约 40 分钟）。
# 默认跳过，只跑轻量套件（约 4-5 分钟）；发版或改动核心事务时用 SBD_TEST_FULL=1 跑完整回归。
SLOW_SUITES=(
    contracts/apply.sh
    contracts/classic.sh
    contracts/dns-defaults.sh
    contracts/dns-settings.sh
    contracts/entries.sh
    contracts/export.sh
    contracts/peers.sh
    contracts/resolver.sh
    contracts/rules.sh
    contracts/simple-wizards.sh
    contracts/time.sh
    alignment/classic.sh
    alignment/engine.sh
    alignment/entries.sh
    alignment/maintenance.sh
    alignment/peers.sh
    alignment/policy.sh
    alignment/time.sh
    alignment/tls-export.sh
    alignment/uninstall.sh
    alignment/usability.sh
)
LOGS=$(mktemp -d "${TMPDIR:-/tmp}/singbox-runner.XXXXXX") || exit 1
trap 'case "$LOGS" in "${TMPDIR:-/tmp}"/singbox-runner.*) rm -rf -- "$LOGS" ;; esac' EXIT
for suite in "$ROOT"/tests/contracts/*.sh "$ROOT"/tests/alignment/*.sh "$ROOT"/tests/verify-configs.sh; do
    rel=${suite#"$ROOT"/tests/}
    if [[ "${SBD_TEST_FULL:-0}" != 1 ]]; then
        for slow in "${SLOW_SUITES[@]}"; do
            if [[ "$rel" = "$slow" ]]; then
                SKIPPED=$((SKIPPED + 1))
                printf '跳过重型套件: %s\n' "$rel"
                continue 2
            fi
        done
    fi
    rc=0
    bash "$suite" > "$LOGS/suite.log" 2>&1 || rc=$?
    cat "$LOGS/suite.log"
    summary=$(tail -n 1 "$LOGS/suite.log")
    if [[ "$summary" =~ ^SUMMARY\ pass=([0-9]+)\ fail=([0-9]+)$ ]]; then
        passed="${BASH_REMATCH[1]}" failed="${BASH_REMATCH[2]}"
        PASS=$((PASS + passed)) FAIL=$((FAIL + failed))
        if [[ "$rc" != 0 && "$failed" = 0 ]]; then FAIL=$((FAIL + 1)); fi
    else
        printf '失败: 套件异常结束: %s\n' "$suite"
        FAIL=$((FAIL + 1))
    fi
done
if [[ "$SKIPPED" != 0 ]]; then
    printf '提示: 跳过 %s 个重型套件；完整回归请设 SBD_TEST_FULL=1\n' "$SKIPPED"
fi
printf 'RESULT passed=%s failed=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" = 0 ]]
