#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/peers.sh"

target_selection() {
    t_policy_seed
    t_run 0 sbd_policy_target dns auto < /dev/null
    t_assert '唯一 DNS 自动选用，无需读取输入' test "$SBD_REPLY" = system
    t_absent "$CASE_TMP/output" '选择目标标识'
    SBD_UI_EOF=true t_run 2 sbd_policy_target dns auto <<< 1
    t_policy_udp
    t_run 0 sbd_policy_target dns auto <<< 2
    t_assert '多目标仍由用户选择，不擅自改用第一项' test "$SBD_REPLY" = upstream
    t_contains "$CASE_TMP/output" '选择目标标识'
    t_run 2 sbd_policy_target dns auto < /dev/null
    t_run 0 sbd_policy_target dns <<< 1
    t_assert '旧显式选择器语义保持不变' test "$SBD_REPLY" = system
}
ntp_existing() {
    t_policy_seed
    jq '.ntp={enabled:false,server:"clock.example.com",server_port:8123,interval:"2h",domain_resolver:{server:"system",strategy:"ipv4_only"},connect_timeout:"4s"}' "$SBD_CONFIG" > "$CASE_TMP/custom" || exit 1
    cp "$CASE_TMP/custom" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_time_menu <<< $'2\n\ny\n0'
    t_assert '普通 NTP 只改启用状态，不用标准值覆盖已有自定义参数' jq -e '.ntp|.enabled and .server=="clock.example.com" and .server_port==8123 and .interval=="2h0m0s" and .domain_resolver=={server:"system",strategy:"ipv4_only"} and .connect_timeout=="4s"' "$SBD_CONFIG"
    t_absent "$CASE_TMP/output" 'NTP UDP 端口'
    t_absent "$CASE_TMP/output" '选择目标标识'
    t_run 0 sbd_time_menu <<< $'5\nnew-clock.example.com\n00123\n15m\n1\ny\n0'
    t_assert '高级入口仍能修改端口/间隔且不丢 resolver 对象的策略' jq -e '.ntp.server=="new-clock.example.com" and .ntp.server_port==123 and .ntp.interval=="15m0s" and .ntp.connect_timeout=="4s" and .ntp.domain_resolver=={server:"system",strategy:"ipv4_only"}' "$SBD_CONFIG"
}
ntp_missing_resolver() {
    t_policy_seed
    jq 'del(.ntp.domain_resolver)' "$SBD_CONFIG" > "$CASE_TMP/config" || exit 1
    cp "$CASE_TMP/config" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_time_prompt <<< $'\ny'
    t_assert '未登记 NTP resolver 时采用唯一现有 DNS' jq -e '.ntp.domain_resolver=="system"' "$SBD_CONFIG"
    t_absent "$CASE_TMP/output" '选择目标标识'
}
wireguard_simple() {
    t_policy_seed
    local key input
    key=$(jq -r .private_key "$ROOT/tests/fixtures/endpoint-wireguard.json") || exit 1
    input=$(printf '10.0.0.2/32\n%s\npeer.example.com\n51820\n%s\n\n0.0.0.0/0,::/0\n' "$key" "$key") || exit 1
    t_run 0 sbd_peer_wireguard_prompt simple-wg <<< "$input"
    t_assert '简单 WG 采用旧向导默认值，不丢必须的连接参数' jq -e '.mtu==1408 and .listen_port==0 and .domain_resolver=="system" and (.peers|length==1) and .peers[0].reserved==[0,0,0] and .peers[0].persistent_keepalive_interval==0 and (.peers[0]|has("pre_shared_key")|not)' <<< "$SBD_PEER_VALUE"
    local field
    for field in 'MTU' '本机 UDP 监听端口' 'peer 数量' 'peer reserved' 'persistent_keepalive_interval' '选择目标标识'; do t_absent "$CASE_TMP/output" "$field"; done
    t_absent "$CASE_TMP/output" "$key"
    t_run 0 sbd_apply sbd_peer_change endpoints add simple-wg "$SBD_PEER_VALUE"
    t_run 0 sbd_check_config
}
wireguard_advanced() {
    t_policy_seed
    local key key2 input
    key=$(jq -r .private_key "$ROOT/tests/fixtures/endpoint-wireguard.json") || exit 1
    key2=$(openssl rand -base64 32) || exit 1
    input=$(printf '10\n1\nadvanced-wg\n10.0.0.2/32\n%s\n1280\n51830\n2\n192.0.2.1\n51820\n%s\n\n10.1.0.0/16\n1,2,3\n25\n192.0.2.2\n51821\n%s\n\n10.2.0.0/16\n4,5,6\n30\ny\n0\n' "$key" "$key" "$key2") || exit 1
    t_run 0 sbd_peers_menu <<< "$input"
    t_assert '高级菜单真实创建多 peer 并保留自定义 MTU/监听端口' jq -e '.endpoints[0]|.tag=="advanced-wg" and .mtu==1280 and .listen_port==51830 and (.peers|length==2) and .peers[0].port==51820 and .peers[1].port==51821' "$SBD_CONFIG"
    t_contains "$CASE_TMP/output" 'peer 数量'
    t_absent "$CASE_TMP/output" "$key"
    t_assert '高级 reserved/keepalive 未退回零值' python3 - "$SBD_CONFIG" <<'PY'
import base64, json, sys
peers = json.load(open(sys.argv[1]))['endpoints'][0]['peers']
for peer, reserved, keepalive in zip(peers, ([1, 2, 3], [4, 5, 6]), (25, 30)):
    actual = peer['reserved']
    assert (list(base64.b64decode(actual)) if isinstance(actual, str) else actual) == reserved
    assert peer['persistent_keepalive_interval'] == keepalive, peer
PY
}
tailscale_advanced() {
    t_policy_seed
    t_run 0 sbd_peers_menu <<< $'10\n2\nheadscale-menu\ny\n\ncustom-host\nbad-url\nhttps://headscale.example.com\n1\ny\n0'
    t_assert '高级向导仍支持 Headscale URL 和自定义主机名' jq -e '.endpoints[0]|.type=="tailscale" and .hostname=="custom-host" and .control_url=="https://headscale.example.com" and .domain_resolver=="system" and (has("auth_key")|not)' "$SBD_CONFIG"
    t_contains "$CASE_TMP/output" '协调服务器 URL'
    t_assert '未修改原有 warn 日志级别' jq -e '.log.level=="warn"' "$SBD_CONFIG"
}
cancel_and_failure() {
    t_policy_seed
    t_entry_save
    t_run 0 sbd_peers_menu <<< $'10\n0\n0'
    t_run 0 sbd_peers_menu <<< 10
    t_run 2 sbd_peer_wireguard_prompt cancelled < /dev/null
    t_run 2 sbd_peer_tailscale_prompt cancelled <<< n
    t_run 2 sbd_time_prompt <<< ''
    t_run 2 sbd_time_prompt advanced < /dev/null
    t_entry_unchanged
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_time_prompt <<< $'\ny'
    t_assert '简单 NTP 仍到达 state 提交失败边界' test -e "$CASE_TMP/failed"
    t_entry_unchanged
    t_absent "$CASE_TMP/output" '[成功]'
}
multiple_dns() {
    t_policy_seed
    t_policy_udp
    local key input
    key=$(jq -r .private_key "$ROOT/tests/fixtures/endpoint-wireguard.json") || exit 1
    input=$(printf '10.0.0.3/32\n%s\npeer.example.com\n51820\n%s\n\n0.0.0.0/0\n2\n' "$key" "$key") || exit 1
    t_run 0 sbd_peer_wireguard_prompt multi-wg <<< "$input"
    t_assert 'WG 有多个 DNS 时由用户显式选择' jq -e '.domain_resolver=="upstream"' <<< "$SBD_PEER_VALUE"
    t_contains "$CASE_TMP/output" '选择目标标识'
    t_run 0 sbd_peer_tailscale_prompt multi-ts <<< $'y\n\n2'
    t_assert 'Tailscale 有多个 DNS 时由用户显式选择' jq -e '.domain_resolver=="upstream"' <<< "$SBD_PEER_VALUE"
    t_contains "$CASE_TMP/output" '选择目标标识'
    jq 'del(.ntp.domain_resolver)' "$SBD_CONFIG" > "$CASE_TMP/config" || exit 1
    cp "$CASE_TMP/config" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_time_prompt <<< $'\n2\ny'
    t_assert 'NTP 无旧 resolver 且有多 DNS 时仍显式选择' jq -e '.ntp.domain_resolver=="upstream"' "$SBD_CONFIG"
}
ntp_pty() {
    t_assert '真实终端简单 NTP 只问源与确认、结果停留一次' python3 "$ROOT/tests/support/menu_pty.py" "$ROOT" "$CASE_TMP" ntp_simple
}

t_case '可选自动选择器只省略唯一目标，不改变旧调用/多目标/EOF' target_selection
t_case '简单 NTP 沿用自定义参数、对象 resolver，高级入口可修改' ntp_existing
t_case 'NTP 无旧 resolver 时自动采用唯一 DNS' ntp_missing_resolver
t_case '简单 WireGuard 不问固定参数、秘密不回显并真实提交' wireguard_simple
t_case '高级 WireGuard 仍可实际创建双 peer 与自定义参数' wireguard_advanced
t_case '高级 Tailscale 保留 Headscale/hostname 和 URL 重问' tailscale_advanced
t_case '简单/高级取消无副作用、NTP 提交失败完整回滚' cancel_and_failure
t_case '三个常用向导有多 DNS 时仍保留有效选择' multiple_dns
t_case '真实终端 NTP 简单向导和层级返回不多暂停' ntp_pty
t_finish
