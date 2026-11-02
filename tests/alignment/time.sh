#!/usr/bin/env bash
# 仅服务和指定失败边界用窄桩；真实 NTP 配置、Schema/format/check 和事务回归。
# shellcheck disable=SC2329,SC2016
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/peers.sh"

preserve_custom() {
    t_policy_seed
    jq '.ntp={enabled:false,server:"old.example",server_port:123,interval:"1h",detour:"direct",connect_timeout:"4s",write_to_system:true} | .log.level="error" | .route.rules=[{domain:"user.example",action:"route",outbound:"direct"}]' "$SBD_CONFIG" > "$CASE_TMP/custom" || exit 1
    cp "$CASE_TMP/custom" "$SBD_CONFIG" || exit 1
    t_sync_config
    t_run 0 sbd_time_prompt <<< $'new.example\ny'
    t_assert '显式修改时间源，保留原端口/间隔/高级拨号和其他配置' jq -e '.ntp.server=="new.example" and .ntp.server_port==123 and .ntp.interval=="1h0m0s" and .ntp.detour=="direct" and .ntp.connect_timeout=="4s" and (.ntp.write_to_system // false)==false and .log.level=="error" and .route.rules[0].domain=="user.example"' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_time_change disable
    t_assert '禁用不丢失自定义 detour' jq -e '.ntp.detour=="direct" and (.ntp.enabled // false)==false' "$SBD_CONFIG"
}
references_contract() {
    t_policy_seed
    t_policy_udp upstream
    t_peer_add wireguard
    t_run 0 sbd_apply sbd_time_change enable '{"server":"time.example.com","server_port":123,"interval":"30m","domain_resolver":"upstream","detour":"wg-fixture"}'
    t_entry_save
    t_run 1 sbd_apply sbd_resolver_server delete upstream
    t_entry_unchanged
    t_run 1 sbd_apply sbd_peer_change endpoints delete wg-fixture
    t_entry_unchanged
    t_run 1 sbd_apply sbd_time_change enable '{"server":"time.example.com","server_port":123,"interval":"30m","domain_resolver":"missing"}'
    t_entry_unchanged
}
state_failure() {
    t_policy_seed
    cp "$SBD_CONFIG" "$CASE_TMP/old-config" || exit 1
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_apply sbd_time_change enable '{"server":"127.0.0.1","server_port":123,"interval":"30m"}'
    t_assert '到达真实 state 提交边界' test -f "$CASE_TMP/failed"
    t_assert '配置原字节保留' cmp -s "$SBD_CONFIG" "$CASE_TMP/old-config"
}
fresh_default() {
    t_fresh
    t_stopped
    t_run 0 sbd_apply sbd_entry_create "$(cat "$ROOT/tests/fixtures/entry-vmess_ws.json")"
    t_assert '首次创建直接继承原生 NTP 默认配置' jq -e '.ntp.enabled==true and .ntp.server=="time.cloudflare.com" and .ntp.server_port==123 and .ntp.interval=="30m0s" and .ntp.domain_resolver=="system" and (.ntp.write_to_system // false)==false' "$SBD_CONFIG"
    t_run 0 sbd_check_config
    t_assert '首次配置只提交一次修订' jq -e '.revision==1' "$SBD_STATE"
}
existing_config_preserved() {
    t_seed
    t_entry_add vmess_ws
    t_assert '旧配置没有 NTP 时不会在节点创建时自动迁移' jq -e 'has("ntp")|not' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_time_change enable '{"server":"127.0.0.1","server_port":123,"interval":"1h"}'
    t_run 0 sbd_apply sbd_time_change disable
    t_entry_add shadowsocks
    t_assert '旧配置显式关闭及自定义源不被默认覆盖' jq -e '(.ntp.enabled // false)==false and .ntp.server=="127.0.0.1" and .ntp.interval=="1h0m0s"' "$SBD_CONFIG"
}
t_case '原生 NTP 保留高级字段、禁止系统写时和不改其他配置' preserve_custom
t_case 'NTP resolver/detour 存活引用不能悬空删除' references_contract
t_case 'NTP state 写失败整组回滚' state_failure
t_case '首次创建配置默认启用 NTP，但保持系统写时关闭' fresh_default
t_case '已有无 NTP/显式禁用配置不被新默认值迁移覆盖' existing_config_preserved
t_finish
