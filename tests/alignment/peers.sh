#!/usr/bin/env bash
# 文件事务、原生配置和引用均执行真实函数；只替换指定服务/写失败边界。
# shellcheck disable=SC2329,SC2016
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/peers.sh"

endpoint_routes() {
    t_policy_seed
    t_peer_add wireguard
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"inbound":"wg-fixture","action":"route","outbound":"direct"}'
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"domain":"example.com","action":"route","outbound":"wg-fixture"}'
    t_entry_save
    t_run 1 sbd_apply sbd_peer_change endpoints delete wg-fixture
    t_entry_unchanged
    t_assert 'endpoint 可以同时作为原生入口匹配和出口' jq -e '.route.rules[0].inbound=="wg-fixture" and .route.rules[1].outbound=="wg-fixture"' "$SBD_CONFIG"
}
group_reference() {
    t_policy_seed
    t_peer_add wireguard
    t_patch_config '.outbounds += [{type:"selector",tag:"pick",outbounds:["wg-fixture","direct"],default:"wg-fixture"}]'
    t_entry_save
    t_run 1 sbd_apply sbd_peer_change endpoints delete wg-fixture
    t_entry_unchanged
}
wireguard_update() {
    t_policy_seed
    t_peer_add wireguard
    local value
    value=$(jq '.mtu=1280 | .peers[0].reserved=[4,5,6] | .peers[0].address="peer.example.com" | .domain_resolver="system"' "$ROOT/tests/fixtures/endpoint-wireguard.json") || exit 1
    t_run 0 sbd_apply sbd_peer_change endpoints replace wg-fixture "$value"
    t_assert '保留原生 peer 地址和明确 bootstrap' jq -e '.endpoints[0]|.mtu==1280 and .peers[0].address=="peer.example.com" and .domain_resolver=="system"' "$SBD_CONFIG"
    t_run 0 t_peer_reserved '[4,5,6]'
    t_entry_save
    value=$(jq '.private_key="invalid-key"' <<< "$value") || exit 1
    t_run 1 sbd_apply sbd_peer_change endpoints replace wg-fixture "$value"
    t_entry_unchanged
}
drift_and_unmanaged() {
    t_policy_seed
    t_peer_add wireguard
    t_patch_config '.endpoints[0].mtu=1300'
    t_run 0 sbd_check_config_tidy
    t_assert '自动采用手工 endpoint 参数' jq -e '.policy.endpoints[0].expected.mtu==1300' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_peer_change endpoints delete wg-fixture
    t_assert '手工改动同步后可正常删除' jq -e '(.endpoints // [])==[]' "$SBD_CONFIG"
    t_entry_save
    t_run 1 sbd_apply sbd_peer_change connectors delete user-connector
    t_entry_unchanged
}
activation_failure() {
    t_policy_seed
    sbd_service_state() { printf 'running\n'; }
    sbd_service_restore() { if [[ ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi; }
    cp "$SBD_CONFIG" "$CASE_TMP/old-config" || exit 1
    t_run 1 sbd_apply sbd_peer_change endpoints add wg-fixture "$(cat "$ROOT/tests/fixtures/endpoint-wireguard.json")"
    t_assert '到达运行态激活边界' test -f "$CASE_TMP/failed"
    t_assert '配置原字节保留' cmp -s "$SBD_CONFIG" "$CASE_TMP/old-config"
    t_absent "$CASE_TMP/output" '[成功]'
}
warp_menu() {
    t_fresh
    t_stopped
    local key
    key=$(jq -r '.endpoints[0].private_key' "$ROOT/tests/fixtures/warp-api.json") || exit 1
    sbd_peer_warp_download() { cp "$ROOT/tests/fixtures/warp-api.json" "$1"; }
    t_run 0 sbd_peers_menu <<< $'2\n0'
    t_absent "$CASE_TMP/output" "$key"
    t_contains "$CASE_TMP/output" '[2] 添加 WARP'
    t_absent "$CASE_TMP/output" '[2] 添加 WARP（自动获取）'
    t_assert 'WARP 菜单自动获取、自动 tag 并选择原生默认 DNS' jq -e '
        .endpoints[0]|.tag=="warp" and .type=="wireguard"
        and .address==["172.16.0.2/32","2606:4700:110:8a36::2/128"]
        and .domain_resolver=="cloudflare"' "$SBD_CONFIG"
}
t_case 'endpoint 原生入口/出口关联和删除保护' endpoint_routes
t_case 'selector 出站组引用 endpoint 不得悬空' group_reference
t_case 'WireGuard JSON 修改和无效密钥失败保留旧事实' wireguard_update
t_case 'endpoint 手动修改自动同步，缺失对象拒绝操作' drift_and_unmanaged
t_case 'endpoint 服务激活失败不假报成功' activation_failure
t_case '首次配置自动获取 WARP、固定参数与秘密不回显' warp_menu
t_finish
