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
preferred_routes() {
    t_policy_seed
    t_peer_add wireguard
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"preferred_by":"wg-fixture","action":"route","outbound":"direct"}'
    t_entry_save
    t_run 1 sbd_apply sbd_peer_change endpoints delete wg-fixture
    t_entry_unchanged
}
group_reference() {
    t_policy_seed
    t_peer_add wireguard
    jq '.outbounds += [{type:"selector",tag:"pick",outbounds:["wg-fixture","direct"],default:"wg-fixture"}]' "$SBD_CONFIG" > "$CASE_TMP/group" || exit 1
    cp "$CASE_TMP/group" "$SBD_CONFIG" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_peer_change endpoints delete wg-fixture
    t_entry_unchanged
}
connector_dial_refs() {
    t_policy_seed
    t_peer_add wireguard
    local value
    value=$(jq '.tunnel_dialer.detour="wg-fixture" | .control_dialer.detour="wg-fixture"' "$ROOT/tests/fixtures/inbound-cloudflared.json") || exit 1
    t_run 0 sbd_apply sbd_peer_change connectors add cf-fixture "$value"
    t_entry_save
    t_run 1 sbd_apply sbd_peer_change endpoints delete wg-fixture
    t_entry_unchanged
    t_run 0 sbd_apply sbd_peer_change connectors delete cf-fixture
    t_run 0 sbd_apply sbd_peer_change endpoints delete wg-fixture
}
connector_inbound_refs() {
    t_policy_seed
    t_peer_add cloudflared
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"inbound":"cf-fixture","action":"route","outbound":"direct"}'
    t_entry_save
    t_run 1 sbd_apply sbd_peer_change connectors delete cf-fixture
    t_entry_unchanged
    t_run 0 sbd_apply sbd_policy_rule route_rules delete "$(t_policy_id route_rules)"
    t_run 0 sbd_apply sbd_peer_change connectors delete cf-fixture
}
dns_dial_reference() {
    t_policy_seed
    t_peer_add wireguard
    t_run 0 sbd_apply sbd_resolver_server add via-wg '{"type":"udp","tag":"via-wg","server":"192.0.2.53","detour":"wg-fixture"}'
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
state_retained() {
    t_policy_seed
    t_peer_add tailscale
    local directory value
    directory=$(jq -r '.endpoints[0].state_directory' "$SBD_CONFIG") || exit 1
    mkdir -p "$directory/Taildrop" || exit 1
    printf 'existing native data fixture\n' > "$directory/auth.marker" || exit 1
    printf 'received data fixture\n' > "$directory/Taildrop/received.txt" || exit 1
    value=$(jq '.auth_key="tskey-auth-fixture-not-real"' "$ROOT/tests/fixtures/endpoint-tailscale.json") || exit 1
    t_run 0 sbd_apply sbd_peer_change endpoints replace ts-fixture "$value"
    t_assert '更新 auth_key 不变更状态目录' test "$(jq -r '.endpoints[0].state_directory' "$SBD_CONFIG")" = "$directory"
    t_run 0 sbd_apply sbd_peer_change endpoints delete ts-fixture
    t_contains "$directory/auth.marker" 'existing native'
    t_contains "$directory/Taildrop/received.txt" 'received data'
    t_assert '删除只移除配置/登记' jq -e '(.endpoints // [])==[]' "$SBD_CONFIG"
}
external_state_refused() {
    t_policy_seed
    mkdir "$CASE_TMP/external" || exit 1
    printf 'keep\n' > "$CASE_TMP/external/keep" || exit 1
    local value
    value=$(jq --arg dir "$CASE_TMP/external" '.state_directory=$dir' "$ROOT/tests/fixtures/endpoint-tailscale.json") || exit 1
    t_run 1 sbd_apply sbd_peer_change endpoints add ts-fixture "$value"
    t_unchanged
    t_contains "$CASE_TMP/external/keep" keep
}
magic_references() {
    t_policy_seed
    t_peer_add tailscale
    t_run 0 sbd_apply sbd_peer_magic add ts-fixture ts-dns 0
    t_entry_save
    t_run 1 sbd_apply sbd_peer_change endpoints delete ts-fixture
    t_entry_unchanged
    t_run 0 sbd_apply sbd_policy_rule dns_rules add '' '{"domain":"example.com","action":"route","server":"ts-dns"}'
    t_entry_save
    t_run 1 sbd_apply sbd_peer_magic delete '' ts-dns
    t_entry_unchanged
    t_run 0 sbd_apply sbd_policy_rule dns_rules delete "$(t_policy_id dns_rules)"
    t_run 0 sbd_apply sbd_peer_magic delete '' ts-dns
    t_run 0 sbd_apply sbd_peer_change endpoints delete ts-fixture
}
magic_race_separation() {
    t_policy_seed
    t_peer_add tailscale
    t_run 0 sbd_apply sbd_peer_magic add ts-fixture ts-dns 0
    t_policy_udp
    t_run 0 sbd_apply sbd_resolver_race '["system","upstream"]' '{"domain_suffix":"example.com"}'
    t_run 0 sbd_resolver_advanced_menu <<< $'8\n1\ny\n0'
    t_absent "$CASE_TMP/output" magic.ts-dns
    t_assert '竞速菜单不误删 MagicDNS 规则组' jq -e '.dns.rules|length==1 and .[0].preferred_by=="ts-dns"' "$SBD_CONFIG"
}
port_collisions() {
    t_policy_seed
    t_entry_add hysteria2
    local value
    value=$(jq '.listen_port=19502' "$ROOT/tests/fixtures/endpoint-wireguard.json") || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_peer_change endpoints add wg-fixture "$value"
    t_entry_unchanged
    value=$(jq '.listen_port=19690' "$ROOT/tests/fixtures/endpoint-wireguard.json") || exit 1
    t_run 0 sbd_apply sbd_peer_change endpoints add wg-fixture "$value"
    value=$(jq '.listen_port=19690' "$ROOT/tests/fixtures/entry-hysteria2.json") || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_entry_create "$value"
    t_entry_unchanged
}
drift_and_unmanaged() {
    t_policy_seed
    t_peer_add wireguard
    jq '.endpoints[0].mtu=1300' "$SBD_CONFIG" > "$CASE_TMP/drift" || exit 1
    cp "$CASE_TMP/drift" "$SBD_CONFIG" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_peer_change endpoints delete wg-fixture
    t_contains "$CASE_TMP/output" '漂移'
    t_entry_unchanged
    t_run 1 sbd_apply sbd_peer_change connectors delete user-connector
    t_entry_unchanged
}
state_write_failure() {
    t_policy_seed
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_apply sbd_peer_change endpoints add ts-fixture "$(cat "$ROOT/tests/fixtures/endpoint-tailscale.json")"
    t_assert '到达真实 state 提交边界' test -f "$CASE_TMP/failed"
    t_unchanged
}
kill_recovery() {
    t_policy_seed
    mv() { if [[ "${!#}" = "$SBD_STATE" ]]; then kill -KILL "$BASHPID"; fi; command mv "$@"; }
    t_run 137 sbd_apply sbd_peer_change connectors add cf-fixture "$(cat "$ROOT/tests/fixtures/inbound-cloudflared.json")"
    t_assert '强杀前原生 connector 已发布' jq -e '.inbounds[0].type=="cloudflared"' "$SBD_CONFIG"
    unset -f mv
    t_run 0 sbd_recover
    t_unchanged
}
activation_failure() {
    t_policy_seed
    sbd_service_state() { printf 'running\n'; }
    sbd_service_restore() { if [[ ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi; }
    t_run 1 sbd_apply sbd_peer_change endpoints add wg-fixture "$(cat "$ROOT/tests/fixtures/endpoint-wireguard.json")"
    t_assert '到达运行态激活边界' test -f "$CASE_TMP/failed"
    t_unchanged
    t_absent "$CASE_TMP/output" '[成功]'
}
ws_not_rebound() {
    t_policy_seed
    t_entry_add vless_ws
    jq '.nodes[0]' "$SBD_REGISTRY" > "$CASE_TMP/node" || exit 1
    cp "$SBD_EXPORTS/$NODE_ID.txt" "$CASE_TMP/uri" || exit 1
    t_peer_add cloudflared
    t_assert 'Q5A 不自动更改已有 WS 分享入口事实' jq -e --slurpfile old "$CASE_TMP/node" '.nodes[0]==$old[0]' "$SBD_REGISTRY"
    t_assert 'Q5A 不自动改 URI' cmp -s "$SBD_EXPORTS/$NODE_ID.txt" "$CASE_TMP/uri"
    t_assert '原生 WS 仍保留自身监听/无 TLS' jq -e '.inbounds[0]|.type=="vless" and .listen_port==19506 and (has("tls")|not)' "$SBD_CONFIG"
}
wireguard_menu() {
    t_fresh
    t_stopped
    local key input
    key=$(jq -r .private_key "$ROOT/tests/fixtures/endpoint-wireguard.json") || exit 1
    input=$(printf '2\nmenu-wg\n10.0.0.2/24\n%s\npeer.example.com\n51820\n%s\n\n0.0.0.0/0,::/0\ny\n0\n' "$key" "$key") || exit 1
    t_run 0 sbd_peers_menu <<< "$input"
    t_absent "$CASE_TMP/output" "$key"
    t_assert '首次无配置时可向导创建并选择原生默认 DNS' jq -e '.endpoints[0]|.tag=="menu-wg" and .address=="10.0.0.2/24" and .domain_resolver=="system"' "$SBD_CONFIG"
}
cloudflare_menu() {
    t_policy_seed
    local token input
    token=$(jq -r .token "$ROOT/tests/fixtures/inbound-cloudflared.json") || exit 1
    input=$(printf '4\nmenu-cf\n%s\n2\n1\n\n1\n\n1\ny\n0\n' "$token") || exit 1
    t_run 0 sbd_peers_menu <<< "$input"
    t_absent "$CASE_TMP/output" "$token"
    t_assert 'CF 菜单真实选择 HTTP2 与独立拨号配置' jq -e '.inbounds[0]|.tag=="menu-cf" and .protocol=="http2" and .control_dialer.domain_resolver=="system" and .tunnel_dialer.domain_resolver=="system"' "$SBD_CONFIG"
}
login_logging() {
    t_policy_seed
    sbd_backend() { printf 'openrc\n'; }
    t_run 0 sbd_peer_login_menu <<< $'1\n0'
    t_contains "$CASE_TMP/output" "$SBD_LOG"
    t_assert '查看登录说明不提高默认 warn' jq -e '.log.level=="warn"' "$SBD_CONFIG"
    t_run 0 sbd_peer_login_menu <<< $'2\ny\n0'
    t_assert '用户显式选择后才切换 info' jq -e '.log.level=="info"' "$SBD_CONFIG"
    t_run 0 sbd_peer_login_menu <<< $'3\ny\n0'
    t_assert 'warn 是显式选择，不伪称恢复旧值' jq -e '.log.level=="warn"' "$SBD_CONFIG"
}
control_dns_cycle() {
    t_policy_seed
    t_peer_add tailscale
    t_run 0 sbd_apply sbd_peer_magic add ts-fixture ts-dns 0
    local value
    value=$(jq '.domain_resolver="ts-dns"' "$ROOT/tests/fixtures/endpoint-tailscale.json") || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_peer_change endpoints replace ts-fixture "$value"
    t_contains "$CASE_TMP/output" '循环'
    t_entry_unchanged
}
magic_state_failure() {
    t_policy_seed
    t_peer_add tailscale
    t_entry_save
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_apply sbd_peer_magic add ts-fixture ts-dns 0
    t_assert 'MagicDNS 到达 state 提交边界' test -f "$CASE_TMP/failed"
    t_entry_unchanged
}
t_case 'endpoint 原生入口/出口关联和删除保护' endpoint_routes
t_case 'endpoint preferred_by 存活引用保护' preferred_routes
t_case 'selector 出站组引用 endpoint 不得悬空' group_reference
t_case 'Cloudflared 双拨号引用 endpoint 的删除保护' connector_dial_refs
t_case 'Cloudflared inbound 路由引用与显式删除' connector_inbound_refs
t_case 'DNS 经 endpoint 拨号的引用保护' dns_dial_reference
t_case 'WireGuard JSON 修改和无效密钥失败保留旧事实' wireguard_update
t_case 'Tailscale 修改/删除保留认证与 Taildrop 数据' state_retained
t_case '不静默迁移或接管外部 Tailscale 状态目录' external_state_refused
t_case 'MagicDNS 的 endpoint/server/规则引用原子管理' magic_references
t_case 'MagicDNS 与原生竞速组不混淆删除' magic_race_separation
t_case 'endpoint 与普通入站双向检查 UDP 端口冲突' port_collisions
t_case 'endpoint 漂移拒绝覆盖，自定义对象不自动接管' drift_and_unmanaged
t_case 'endpoint state 提交失败整组恢复' state_write_failure
t_case 'connector 发布后 SIGKILL 恢复旧事实' kill_recovery
t_case 'endpoint 服务激活失败不假报成功' activation_failure
t_case 'connector 管理不偷偷绑定 WS 或修改分享' ws_not_rebound
t_case '首次配置 WireGuard 完整向导与秘密不回显' wireguard_menu
t_case 'Cloudflared 完整向导与秘密不回显' cloudflare_menu
t_case 'Tailscale 登录日志位置与显式 info/warn 事务' login_logging
t_case 'Tailscale 控制面不能依赖自己的 MagicDNS bootstrap' control_dns_cycle
t_case 'MagicDNS server/规则/state 同组提交失败完整恢复' magic_state_failure
t_finish
