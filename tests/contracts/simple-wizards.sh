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
    t_run 0 sbd_peer_wireguard_prompt <<< "$input"
    SBD_PEER_VALUE=$(jq --arg tag simple-wg '. + {tag:$tag}' <<< "$SBD_PEER_VALUE") || exit 1
    t_assert '简单 WG 采用旧向导默认值，不丢必须的连接参数' jq -e '.mtu==1408 and .listen_port==0 and .domain_resolver=="system" and (.peers|length==1) and .peers[0].reserved==[0,0,0] and .peers[0].persistent_keepalive_interval==0 and (.peers[0]|has("pre_shared_key")|not)' <<< "$SBD_PEER_VALUE"
    local field
    for field in 'MTU' '本机 UDP 监听端口' 'peer 数量' 'peer reserved' 'persistent_keepalive_interval' '选择目标标识'; do t_absent "$CASE_TMP/output" "$field"; done
    t_absent "$CASE_TMP/output" "$key"
    t_run 0 sbd_apply sbd_peer_change endpoints add simple-wg "$SBD_PEER_VALUE"
    t_run 0 sbd_check_config
}
cancel_and_failure() {
    t_policy_seed
    t_entry_save
    t_run 0 sbd_peers_menu <<< 0
    t_run 0 sbd_peers_menu < /dev/null
    t_run 2 sbd_peer_wireguard_prompt < /dev/null
    t_run 2 sbd_time_prompt <<< ''
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
    input=$(printf '10.0.0.3/32\n%s\npeer.example.com\n51820\n%s\n\n0.0.0.0/0\n' "$key" "$key") || exit 1
    t_run 0 sbd_peer_wireguard_prompt <<< "$input"
    SBD_PEER_VALUE=$(jq --arg tag multi-wg '. + {tag:$tag}' <<< "$SBD_PEER_VALUE") || exit 1
    t_assert 'WG 自动沿用默认 DNS' jq -e '.domain_resolver=="system"' <<< "$SBD_PEER_VALUE"
    t_absent "$CASE_TMP/output" '选择目标标识'
    jq 'del(.ntp.domain_resolver)' "$SBD_CONFIG" > "$CASE_TMP/config" || exit 1
    cp "$CASE_TMP/config" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_time_prompt <<< $'\ny'
    t_assert 'NTP 无旧 resolver 时自动沿用默认 DNS' jq -e '.ntp.domain_resolver=="system"' "$SBD_CONFIG"
}
ntp_pty() {
    t_assert '真实终端简单 NTP 只问源与确认、结果停留一次' python3 "$ROOT/tests/support/menu_pty.py" "$ROOT" "$CASE_TMP" ntp_simple
}

t_case '可选自动选择器只省略唯一目标，不改变旧调用/多目标/EOF' target_selection
t_case '简单 NTP 沿用自定义参数、对象 resolver' ntp_existing
t_case 'NTP 无旧 resolver 时自动采用唯一 DNS' ntp_missing_resolver
t_case '简单 WireGuard 不问固定参数、秘密不回显并真实提交' wireguard_simple
t_case '普通向导取消无副作用、NTP 提交失败完整回滚' cancel_and_failure
t_case 'WG/NTP 沿用默认 DNS，不再询问内部解析器' multiple_dns
t_case '真实终端 NTP 简单向导和层级返回不多暂停' ntp_pty
t_finish
