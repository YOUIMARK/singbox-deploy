#!/usr/bin/env bash
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

commit_valid() {
    t_seed
    t_run 0 sbd_apply t_edit_debug
    t_assert '配置生效' jq -e '.log.level=="debug"' "$SBD_CONFIG"
    t_assert 'Schema 与配置同目录' test -s "$SBD_SCHEMA"
    t_assert '部署根不再放配置' test ! -e "$SBD_LEGACY_CONFIG" -a ! -e "$SBD_LEGACY_SCHEMA"
    t_assert 'state 最后提交' jq -e '.revision==1 and .core_version=="1.14.4"' "$SBD_STATE"
    t_contains "$SBD_EXPORTS/node.txt" '新链接'
    t_assert '当前事务收尾' test ! -e "$SBD_WORK/active"
    t_assert '保留最近恢复版本' test -f "$SBD_WORK/previous/journal.json"
}
manual_edit_source() {
    t_seed
    producer() { :; }
    jq '.log.level="debug"' "$SBD_CONFIG" > "$CASE_TMP/edited" || exit 1
    cp "$CASE_TMP/edited" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_check_config
    t_run 0 sbd_apply producer
    t_assert '手工编辑的单配置是下一次事务来源' jq -e '.log.level=="debug"' "$SBD_CONFIG"
}
format_only_manual() {
    t_seed
    jq --indent 4 . "$SBD_CONFIG" > "$CASE_TMP/pretty.json" || exit 1
    if cmp -s "$CASE_TMP/pretty.json" "$SBD_CONFIG"; then
        printf '测试未能制造纯排版差异\n' >&2
        exit 1
    fi
    cp "$CASE_TMP/pretty.json" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_check_config
    t_absent "$CASE_TMP/output" 'merged.json.raw'
    t_absent "$CASE_TMP/output" '/tmp/'
    t_assert '检查配置不重写单配置文件' cmp -s "$CASE_TMP/pretty.json" "$SBD_CONFIG"
}
check_tidy_formatting() {
    t_seed
    jq --indent 4 . "$SBD_CONFIG" > "$CASE_TMP/pretty.json" || exit 1
    cp "$CASE_TMP/pretty.json" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_check_config_tidy
    t_contains "$CASE_TMP/output" '配置缩进已整理'
    jq -S . "$SBD_CONFIG" > "$CASE_TMP/tidied-sorted.json" || exit 1
    jq -S . "$CASE_TMP/pretty.json" > "$CASE_TMP/pretty-sorted.json" || exit 1
    t_assert '整理只改排版' cmp -s "$CASE_TMP/tidied-sorted.json" "$CASE_TMP/pretty-sorted.json"
    cp "$SBD_CONFIG" "$CASE_TMP/tidied.json" || exit 1
    t_run 0 sbd_check_config_tidy
    t_contains "$CASE_TMP/output" '配置缩进已符合核心格式'
    t_assert '重复检查不再改写' cmp -s "$SBD_CONFIG" "$CASE_TMP/tidied.json"
}
check_tidy_invalid_untouched() {
    t_seed
    cp "$ROOT/tests/fixtures/invalid-key.json" "$SBD_CONFIG" || exit 1
    cp "$SBD_CONFIG" "$CASE_TMP/bad-config" || exit 1
    t_run 1 sbd_check_config_tidy
    t_assert '检查失败时不整理' cmp -s "$SBD_CONFIG" "$CASE_TMP/bad-config"
}
invalid_single_reported() {
    t_seed
    cp "$ROOT/tests/fixtures/invalid-key.json" "$SBD_CONFIG" || exit 1
    t_run 1 sbd_check_config
    t_contains "$CASE_TMP/output" '核心语义检查失败'
}
check_failure_reported() {
    t_seed
    # 变量由生成的窄包装器解释，其他动作仍调用真实核心。
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nif [[ "$1" = check ]]; then printf "mock check failure\\n" >&2; exit 1; fi\nexec "%s" "$@"\n' "$SBD_TEST_BIN" > "$CASE_TMP/core-wrapper" || exit 1
    chmod +x "$CASE_TMP/core-wrapper" || exit 1
    # shellcheck disable=SC2034
    SBD_BINARY="$CASE_TMP/core-wrapper"
    t_run 1 sbd_check_config
    t_contains "$CASE_TMP/output" '核心语义检查失败'
    t_contains "$CASE_TMP/output" 'mock check failure'
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
lock_collision() {
    t_seed
    exec {held}>"$SBD_LOCK" || exit 1
    flock -n "$held" || exit 1
    t_run 1 sbd_apply t_edit_debug
    t_contains "$CASE_TMP/output" '另一个操作'
    t_unchanged
}
t_case '完整提交与修订号' commit_valid
t_case '手工编辑单配置作为事务输入' manual_edit_source
t_case '单配置仅重新排版仍可检查' format_only_manual
t_case '检查配置成功时整理缩进且幂等' check_tidy_formatting
t_case '检查配置失败时不整理' check_tidy_invalid_untouched
t_case '单配置非法语义由真实 check 拒绝' invalid_single_reported
t_case '检查配置失败时显示核心 stderr' check_failure_reported
t_case 'format 失败不落盘' format_failure
t_case 'state 提交失败整组回滚' state_failure
t_case '启动失败恢复旧文件后再恢复服务' runtime_failure
t_case '回滚再失败保留恢复源并可重试' rollback_failure
t_case '真实 SIGKILL 后恢复' kill_recovery
t_case '真实写锁冲突拒绝变更' lock_collision
t_finish
