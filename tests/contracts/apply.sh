#!/usr/bin/env bash
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

commit_valid() {
    t_seed
    t_run 0 sbd_apply t_edit_debug
    t_assert '配置生效' jq -e '.log.level=="debug"' "$SBD_CONFIG"
    t_assert 'state 最后提交' jq -e '.revision==1 and .core_version=="1.14.4"' "$SBD_STATE"
    t_contains "$SBD_EXPORTS/node.txt" '新链接'
    t_assert '当前事务收尾' test ! -e "$SBD_WORK/active"
    t_assert '保留最近恢复版本' test -f "$SBD_WORK/previous/journal.json"
}
callback_failure() {
    t_seed
    producer() { printf '{broken' > "$1/config.json"; return 1; }
    t_run 1 sbd_apply producer
    t_unchanged
}
schema_failure() {
    t_seed
    producer() { cp "$ROOT/tests/fixtures/invalid-type.json" "$1/config.json"; }
    t_run 1 sbd_apply producer
    t_contains "$CASE_TMP/output" 'Schema'
    t_unchanged
}
semantic_failure() {
    t_seed
    producer() { cp "$ROOT/tests/fixtures/invalid-key.json" "$1/config.json"; }
    t_run 1 sbd_apply producer
    t_contains "$CASE_TMP/output" '核心语义检查失败'
    t_unchanged
}
format_failure() {
    t_seed
    # 变量由生成的窄包装器解释，其他动作仍调用真实核心。
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nif [[ "$1" = format ]]; then exit 1; fi\nexec "%s" "$@"\n' "$SBD_TEST_BIN" > "$CASE_TMP/core-wrapper" || exit 1
    chmod +x "$CASE_TMP/core-wrapper" || exit 1
    # shellcheck disable=SC2034
    SBD_BINARY="$CASE_TMP/core-wrapper"
    t_run 1 sbd_apply t_edit_debug
    t_contains "$CASE_TMP/output" '格式化失败'
    t_unchanged
}
state_failure() {
    t_seed
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then
            : > "$CASE_TMP/failed"
            return 1
        fi
        command mv "$@"
    }
    t_run 1 sbd_apply t_edit_debug
    t_assert '确实到达 state 提交阶段' test -f "$CASE_TMP/failed"
    t_unchanged
    t_assert '普通回滚已收尾' test ! -e "$SBD_WORK/active"
}
registry_failure() {
    t_seed
    mv() {
        if [[ "${!#}" = "$SBD_REGISTRY" && ! -e "$CASE_TMP/failed" ]]; then
            : > "$CASE_TMP/failed"; return 1
        fi
        command mv "$@"
    }
    t_run 1 sbd_apply t_edit_debug
    t_assert '确实到达 metadata 提交阶段' test -f "$CASE_TMP/failed"
    t_unchanged
}
runtime_failure() {
    t_seed
    sbd_service_state() { printf 'running\n'; }
    sbd_service_restore() {
        if [[ ! -f "$CASE_TMP/restarted" ]]; then
            : > "$CASE_TMP/restarted"; return 1
        fi
        cmp -s "$SBD_CONFIG" "$CASE_TMP/old-config"
    }
    t_run 1 sbd_apply t_edit_debug
    t_assert '启动确实失败一次' test -f "$CASE_TMP/restarted"
    t_unchanged
}
rollback_failure() {
    t_seed
    mv() { [[ "${!#}" != "$SBD_STATE" ]] || return 1; command mv "$@"; }
    t_run 1 sbd_apply t_edit_debug
    t_assert '恢复失败保留记录' test -f "$SBD_WORK/active/journal.json"
    t_assert '恢复失败保留源' test -f "$SBD_WORK/active/before/state"
    unset -f mv
    t_run 0 sbd_recover
    t_unchanged
}
kill_recovery() {
    t_seed
    mv() {
        if [[ "${!#}" = "$SBD_STATE" ]]; then kill -KILL "$BASHPID"; fi
        command mv "$@"
    }
    t_run 137 sbd_apply t_edit_debug
    t_assert '强杀发生在配置已替换之后' jq -e '.log.level=="debug"' "$SBD_CONFIG"
    t_assert '保留未完成记录' test -f "$SBD_WORK/active/journal.json"
    unset -f mv
    t_run 0 sbd_recover
    t_unchanged
}
accepted_cleanup() {
    t_seed
    mv() { [[ "${!#}" != "$SBD_WORK/previous" ]] || return 1; command mv "$@"; }
    t_run 1 sbd_apply t_edit_debug
    t_assert '完成事实不伪装成未提交' jq -e '.phase=="accepted"' "$SBD_WORK/active/journal.json"
    t_assert '新 state 已提交' jq -e '.revision==1' "$SBD_STATE"
    unset -f mv
    t_run 0 sbd_recover
    t_assert '恢复只收尾，不回滚完成版本' jq -e '.log.level=="debug"' "$SBD_CONFIG"
    t_assert 'state 修订号不回退' jq -e '.revision==1' "$SBD_STATE"
}
snapshot_bad_copy() {
    t_seed
    cp() {
        if [[ "${!#}" = "$SBD_WORK/active/before/config" ]]; then
            printf 'partial' > "${!#}"; return 0
        fi
        command cp "$@"
    }
    t_run 1 sbd_apply t_edit_debug
    t_contains "$CASE_TMP/output" '快照字节不一致'
    t_unchanged
}
lock_collision() {
    t_seed
    exec {held}>"$SBD_LOCK" || exit 1
    flock -n "$held" || exit 1
    t_run 1 sbd_apply t_edit_debug
    t_contains "$CASE_TMP/output" '另一个操作'
    t_unchanged
}
bad_journal() {
    t_seed
    mkdir -p "$SBD_WORK/active" || exit 1
    printf '{broken' > "$SBD_WORK/active/journal.json" || exit 1
    t_run 1 sbd_recover
    t_assert '损坏记录保留现场' test -f "$SBD_WORK/active/journal.json"
    t_unchanged
}
missing_backup() {
    t_seed
    mv() { [[ "${!#}" != "$SBD_STATE" ]] || return 1; command mv "$@"; }
    t_run 1 sbd_apply t_edit_debug
    unset -f mv
    rm "$SBD_WORK/active/before/config" || exit 1
    t_run 1 sbd_recover
    t_assert '缺恢复源不能清账' test -f "$SBD_WORK/active/journal.json"
}
preserve_unmanaged() {
    t_seed
    producer() {
        jq '.outbounds += [{type:"direct",tag:"unmanaged"}]' "$1/config.json" > "$1/next" || return 1
        mv "$1/next" "$1/config.json"
    }
    t_run 0 sbd_apply producer
    t_run 0 sbd_apply t_edit_debug
    t_assert '定点变更保留非本动作字段' jq -e 'any(.outbounds[]; .tag=="unmanaged")' "$SBD_CONFIG"
}
unchanged_config_running() {
    t_seed
    sbd_service_state() { printf 'running\n'; }
    sbd_service_restore() { printf '%s\n' "$1" >> "$CASE_TMP/service-actions"; }
    t_run 0 sbd_apply sbd_export_rebuild
    t_assert '仅重建导出不重启运行服务' test ! -e "$CASE_TMP/service-actions"
    t_assert '配置原字节未变' cmp -s "$SBD_CONFIG" "$CASE_TMP/old-config"
    t_assert '派生输出和状态正常提交' jq -e '.revision==1' "$SBD_STATE"
}
t_case '完整提交与修订号' commit_valid
t_case 'producer 失败活跃事实不变' callback_failure
t_case '真实 Schema 失败不落盘' schema_failure
t_case '真实 check 失败不落盘' semantic_failure
t_case 'format 失败不落盘' format_failure
t_case 'state 提交失败整组回滚' state_failure
t_case 'registry 提交失败回滚配置' registry_failure
t_case '启动失败恢复旧文件后再恢复服务' runtime_failure
t_case '回滚再失败保留恢复源并可重试' rollback_failure
t_case '真实 SIGKILL 后恢复' kill_recovery
t_case '已接受版本收尾失败不逆转' accepted_cleanup
t_case '快照 cmp 捕获部分副本' snapshot_bad_copy
t_case '真实写锁冲突拒绝变更' lock_collision
t_case '损坏记录不覆盖未知现场' bad_journal
t_case '恢复副本缺失明确失败' missing_backup
t_case '定点配置编辑保留其他有效字段' preserve_unmanaged
t_case '运行态下纯导出变更不重启服务' unchanged_config_running
t_finish
