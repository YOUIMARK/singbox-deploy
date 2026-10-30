#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/peers.sh"

cancel_contract() {
    t_fresh
    t_run 0 sbd_peers_menu <<< 0
    t_run 0 sbd_peers_menu < /dev/null
    t_run 2 sbd_peers_menu <<< $'2\nwg-fixture'
    t_run 2 sbd_peer_tailscale_prompt ts-fixture <<< n
    t_assert 'EOF/拒绝不创建配置' test ! -e "$SBD_CONFIG"
    t_assert 'EOF/拒绝不创建原生认证目录' test ! -e "$SBD_DATA/tailscale"
}
wireguard_contract() {
    t_policy_seed
    t_peer_add wireguard
    t_assert 'WireGuard 在 endpoints，不是旧 outbound' jq -e '.endpoints[0].type=="wireguard" and all(.outbounds[];.type!="wireguard") and (.endpoints[0].system // false)==false' "$SBD_CONFIG"
    t_run 0 t_peer_reserved '[1,2,255]'
    t_run 0 sbd_peer_list
    t_absent "$CASE_TMP/output" AAECAwQF
    t_run 0 sbd_check_config
}
tailscale_contract() {
    t_policy_seed
    t_peer_add tailscale
    t_assert 'Tailscale 默认不创建系统接口、不广播或开 SSH' jq -e '.endpoints[0]|(.system_interface // false)==false and (.accept_routes // false)==false and (.advertise_exit_node // false)==false and (.ssh_server // false)==false and ((.advertise_routes // [])|length==0)' "$SBD_CONFIG"
    t_assert '未强制 auth_key，独立保存原生状态与 Taildrop' jq -e '.endpoints[0]|(has("auth_key")|not) and (.state_directory|endswith("/data/tailscale/ts-fixture")) and (.taildrop_directory|endswith("/data/tailscale/ts-fixture/Taildrop"))' "$SBD_CONFIG"
    t_assert 'check 不伪造登录或创建原生数据' test ! -e "$SBD_DATA/tailscale"
    t_run 0 sbd_peer_list
    t_contains "$CASE_TMP/output" '不代表'
}
cloudflare_contract() {
    t_policy_seed
    local protocol value
    for protocol in quic http2; do
        value=$(jq --arg protocol "$protocol" '.protocol=$protocol' "$ROOT/tests/fixtures/inbound-cloudflared.json") || exit 1
        t_run 0 sbd_apply sbd_peer_change connectors add cf-fixture "$value"
        t_assert '原生内嵌 Cloudflared 不写本地监听参数' jq -e '.inbounds[0]|.type=="cloudflared" and (has("listen") or has("listen_port")|not)' "$SBD_CONFIG"
        t_run 0 sbd_peer_list
        t_absent "$CASE_TMP/output" eyJhIjoi
        t_run 0 sbd_apply sbd_peer_change connectors delete cf-fixture
    done
}
magic_contract() {
    t_policy_seed
    t_peer_add tailscale
    t_run 0 sbd_apply sbd_peer_magic add ts-fixture ts-dns 0
    t_assert 'MagicDNS 是原生 typed server 和有限 preferred_by' jq -e '.dns.servers[1].type=="tailscale" and .dns.servers[1].endpoint=="ts-fixture" and .dns.rules[0].preferred_by=="ts-dns" and .dns.rules[0].server=="ts-dns" and .dns.final=="system" and .route.final=="direct" and .route.default_domain_resolver=="system"' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_peer_magic delete '' ts-dns
    t_assert '删除 DNS 关联不删除 endpoint' jq -e '(.endpoints|length==1) and (.dns.servers|length==1) and ((.dns.rules // [])|length==0)' "$SBD_CONFIG"
}
field_contract() {
    t_fresh
    local key token
    key=$(jq -r .private_key "$ROOT/tests/fixtures/endpoint-wireguard.json") || exit 1
    token=$(jq -r .token "$ROOT/tests/fixtures/inbound-cloudflared.json") || exit 1
    sbd_peer_key_prompt 私钥 > "$CASE_TMP/prompt" 2>&1 <<< "$(printf 'bad\n%s\n' "$key")" || exit 1
    t_assert '密钥错误只重问当前字段' test "$SBD_REPLY" = "$key"
    t_absent "$CASE_TMP/prompt" "$key"
    sbd_peer_prefix_prompt address > "$CASE_TMP/prompt" 2>&1 <<< $'bad\n10.0.0.2/24, fd00::2/64' || exit 1
    t_assert '接口地址不能归一成网络地址丢掉 host bits' jq -e '.==["10.0.0.2/24","fd00::2/64"]' <<< "$SBD_REPLY"
    sbd_peer_reserved_prompt > "$CASE_TMP/prompt" 2>&1 <<< $'0,0,999\n001,002,0255' || exit 1
    t_assert 'reserved 统一十进制规范化' test "$SBD_REPLY" = '[1,2,255]'
    sbd_peer_token_prompt > "$CASE_TMP/prompt" 2>&1 <<< "$(printf 'bad-token\n%s\n' "$token")" || exit 1
    t_assert 'token 用核心真实解析后保留原字节' test "$SBD_REPLY" = "$token"
    t_absent "$CASE_TMP/prompt" "$token"
    t_run 2 sbd_peer_key_prompt 密钥 < /dev/null
    t_run 2 sbd_peer_token_prompt < /dev/null
}
tailscale_prompt_contract() {
    t_policy_seed
    sbd_peer_tailscale_prompt ts-menu > "$CASE_TMP/prompt" 2>&1 <<< $'y\n\n\n\n1' || exit 1
    t_assert '默认 URL 登录，不自动提高日志级别' jq -e '(.log.level=="warn")' "$SBD_CONFIG"
    t_assert '向导明确接受 Taildrop 且可不填 auth_key' jq -e '.type=="tailscale" and (has("auth_key")|not) and .domain_resolver=="system"' <<< "$SBD_PEER_VALUE"
    t_contains "$CASE_TMP/prompt" Taildrop
    t_run 0 sbd_apply sbd_peer_change endpoints add ts-menu "$SBD_PEER_VALUE"
}
newer_field_contract() {
    t_policy_seed
    local value
    value=$(jq '.on_demand=true' "$ROOT/tests/fixtures/endpoint-wireguard.json") || exit 1
    t_run 1 sbd_apply sbd_peer_change endpoints add wg-fixture "$value"
    t_contains "$CASE_TMP/output" Schema
    t_unchanged
}
tagless_target_contract() {
    t_policy_seed
    sbd_peer_tag_prompt > "$CASE_TMP/prompt" 2>&1 <<< $'direct\nfree-tag' || exit 1
    t_assert '已有 tag 冲突只重问原生标识字段' test "$SBD_REPLY" = free-tag
    jq '.dns.servers += [{type:"udp",server:"192.0.2.53"}]' "$SBD_CONFIG" > "$CASE_TMP/dns" || exit 1
    cp "$CASE_TMP/dns" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_check_config
    t_run 0 sbd_policy_target dns <<< 1
    t_assert '原生无 tag 对象保留但不伪造可引用标识' test "$SBD_REPLY" = system
    t_absent "$CASE_TMP/output" null
    t_run 2 sbd_policy_target dns <<< 2
}
t_case '连接对象菜单取消、必填 EOF 和 Taildrop 明确同意' cancel_contract
t_case 'WireGuard 原生 endpoints 与 peer reserved 真实检查' wireguard_contract
t_case 'Tailscale 独立状态、Taildrop 和非系统默认' tailscale_contract
t_case 'Cloudflared QUIC/HTTP2 原生入站和秘密不回显' cloudflare_contract
t_case '原生 MagicDNS 有限分流不接管全局 DNS' magic_contract
t_case '密钥/token/CIDR/reserved 字段重问与核心 token 解析' field_contract
t_case 'Tailscale 日志 URL 登录向导不静默改变 warn' tailscale_prompt_contract
t_case '1.15 on_demand 不进入 1.14 模板' newer_field_contract
t_case '原生无 tag 的 DNS 不显示为伪造 null 目标' tagless_target_contract
t_finish
