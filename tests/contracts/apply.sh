#!/usr/bin/env bash
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

commit_valid() {
    t_seed
    t_run 0 sbd_apply t_edit_debug
    t_assert '配置生效' jq -e '.log.level=="debug"' "$SBD_CONFIG"
    t_assert '分片同步生效' jq -e '.log.level=="debug"' "$SBD_CONF_PARTS/00_base.json"
    t_assert '分片不写本地 schema 引用' jq -e 'has("$schema")|not' "$SBD_CONF_PARTS/00_base.json"
    t_assert 'Schema 与运行配置同目录' test -s "$SBD_ROOT/schema.json"
    t_assert 'confs 只保留配置分片' test ! -e "$SBD_CONF_PARTS/schema.json"
    t_assert 'state 最后提交' jq -e '.revision==1 and .core_version=="1.14.4"' "$SBD_STATE"
    t_contains "$SBD_EXPORTS/node.txt" '新链接'
    t_assert '当前事务收尾' test ! -e "$SBD_WORK/active"
    t_assert '保留最近恢复版本' test -f "$SBD_WORK/previous/journal.json"
}
fragment_source() {
    t_seed
    producer() { :; }
    jq '.log.level="debug"' "$SBD_CONF_PARTS/00_base.json" > "$CASE_TMP/part" || exit 1
    cp "$CASE_TMP/part" "$SBD_CONF_PARTS/00_base.json" || exit 1
    t_run 1 sbd_check_config
    t_contains "$CASE_TMP/output" '配置分片与运行配置不一致'
    t_run 0 sbd_apply producer
    t_assert '分片是下一次事务的配置来源' jq -e '.log.level=="debug"' "$SBD_CONFIG"
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
t_case '分片编辑作为事务输入并重新合并' fragment_source
t_case 'format 失败不落盘' format_failure
t_case 'state 提交失败整组回滚' state_failure
t_case '启动失败恢复旧文件后再恢复服务' runtime_failure
t_case '回滚再失败保留恢复源并可重试' rollback_failure
t_case '真实 SIGKILL 后恢复' kill_recovery
t_case '真实写锁冲突拒绝变更' lock_collision
t_finish
