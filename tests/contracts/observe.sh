#!/usr/bin/env bash
# 日志后端使用窄桩，不操作宿主服务。
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/policy.sh"

cancel_contract() {
    t_fresh
    t_run 0 sbd_observe_menu <<< 0
    t_run 0 sbd_observe_menu < /dev/null
    t_run 0 sbd_observe_menu <<< $'2\n0\n0'
    t_assert '取消不创建配置' test ! -e "$SBD_CONFIG"
}
log_settings() {
    t_policy_seed
    t_run 0 sbd_observe_menu <<< $'2\n3\ny\n0'
    t_assert '中文编号菜单真实保存 debug' jq -e '.log.level=="debug" and (.log.disabled // false)==false' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_observe_change log_off
    t_assert '关闭用 disabled，不造 none level' jq -e '.log.disabled and .log.level=="debug"' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_observe_change log_service
    t_assert '恢复服务日志不留下 output' jq -e '(.log.disabled // false)==false and (.log|has("output")|not)' "$SBD_CONFIG"
    t_entry_save
    t_run 1 sbd_apply sbd_observe_change api '{"port":9090,"secret":"retired"}'
    t_entry_unchanged
}
log_contract() {
    t_policy_seed
    sbd_backend() { printf 'openrc\n'; }
    t_run 1 sbd_observe_logs
    printf 'native-log-fixture\n' > "$SBD_LOG" || exit 1
    t_run 0 sbd_observe_logs
    t_contains "$CASE_TMP/output" "$SBD_LOG"
    t_contains "$CASE_TMP/output" native-log-fixture
}
retired_settings_preserved() {
    t_policy_seed
    jq '.experimental={clash_api:{external_controller:"127.0.0.1:19090",secret:"fixture-secret"},cache_file:{enabled:false,store_dns:true}}' "$SBD_CONFIG" > "$CASE_TMP/custom" || exit 1
    cp "$CASE_TMP/custom" "$SBD_CONFIG" || exit 1
    printf 'native cache fixture\n' > "$SBD_DATA/cache.db" || exit 1
    t_run 0 sbd_apply sbd_observe_change level info
    t_assert '移除面板不清除用户原生 API 与缓存配置' jq -e '.experimental.clash_api.secret=="fixture-secret" and .experimental.cache_file.store_dns' "$SBD_CONFIG"
    t_contains "$SBD_DATA/cache.db" 'native cache fixture'
    t_run 0 sbd_observe_menu <<< 0
    t_absent "$CASE_TMP/output" 'fixture-secret'
    t_absent "$CASE_TMP/output" 'Clash API'
    t_assert 'API 查询与管理函数均已移除' test "$(type -t sbd_observe_query)" = ''
    t_assert 'API 客户端不再发布' test ! -e "$SBD_APP/support/observe_api.py"
}
t_case '日志菜单取消/EOF 无副作用' cancel_contract
t_case '日志开关和中文级别菜单，拒绝已移除 API 操作' log_settings
t_case '日志路径事实与缺失失败' log_contract
t_case '旧 API/缓存留在用户配置与磁盘，脚本不再提供管理功能' retired_settings_preserved
t_finish
