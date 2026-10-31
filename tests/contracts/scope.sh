#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/policy.sh"

removed_features() {
    t_policy_seed
    local function
    for function in sbd_peer_tailscale_prompt sbd_peer_magic sbd_peer_login_menu sbd_observe_query sbd_resolver_advanced_menu sbd_policy_rules_menu sbd_policy_json_prompt; do
        t_assert '已移除功能不是仅隐藏菜单' test "$(type -t "$function")" = ''
    done
    t_run 0 sbd_peers_menu <<< 0
    t_absent "$CASE_TMP/output" Tailscale
    t_absent "$CASE_TMP/output" MagicDNS
    t_absent "$CASE_TMP/output" Taildrop
    t_absent "$CASE_TMP/output" JSON
    t_run 0 sbd_resolver_menu <<< 0
    t_absent "$CASE_TMP/output" evaluate
    t_absent "$CASE_TMP/output" '[9] 高级设置'
    t_contains "$CASE_TMP/output" "$SBD_CONFIG"
    t_run 0 sbd_observe_menu <<< 0
    t_absent "$CASE_TMP/output" API
    t_absent "$CASE_TMP/output" '流量采样'
}
custom_config_preserved() {
    t_policy_seed
    local directory="$SBD_DATA/tailscale/legacy" value
    mkdir -p "$directory/Taildrop" || exit 1
    printf 'legacy authentication fixture\n' > "$directory/auth.marker" || exit 1
    printf 'received file fixture\n' > "$directory/Taildrop/received.txt" || exit 1
    value=$(jq --arg directory "$directory" '.state_directory=$directory | .taildrop_directory=($directory+"/Taildrop")' "$ROOT/tests/fixtures/endpoint-tailscale.json") || exit 1
    jq --argjson value "$value" '.endpoints=[$value] | .experimental.clash_api={external_controller:"127.0.0.1:19090",secret:"legacy-fixture"}' "$SBD_CONFIG" > "$CASE_TMP/legacy" || exit 1
    cp "$CASE_TMP/legacy" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_apply sbd_observe_change level info
    t_run 0 sbd_apply sbd_resolver_switch default
    t_assert '其他操作不删除已停管的原生配置' jq -e --arg directory "$directory" '.endpoints[0].type=="tailscale" and .endpoints[0].state_directory==$directory and .experimental.clash_api.secret=="legacy-fixture"' "$SBD_CONFIG"
    t_contains "$directory/auth.marker" 'legacy authentication fixture'
    t_contains "$directory/Taildrop/received.txt" 'received file fixture'
    t_entry_save
    t_run 1 sbd_apply sbd_peer_change endpoints add new-ts "$value"
    t_entry_unchanged
}
rules_scope() {
    t_policy_seed
    t_entry_save
    t_run 0 sbd_rules_menu <<< $'1\n2\n3\n0'
    t_contains "$CASE_TMP/output" "$SBD_CONFIG"
    t_contains "$CASE_TMP/output" '[4] 添加规则集'
    t_contains "$CASE_TMP/output" '[6] 恢复默认路由规则'
    t_absent "$CASE_TMP/output" 'JSON 替换'
    t_absent "$CASE_TMP/output" '向导添加'
    t_entry_unchanged
}
t_case '停管模块和高级编辑函数真正移除、菜单不再暴露内部字段' removed_features
t_case '旧原生 Tailscale/API 配置、认证和已接收文件不被其他操作清理' custom_config_preserved
t_case '分流菜单允许规则集增删，路由规则只做查看与恢复默认' rules_scope
t_finish
