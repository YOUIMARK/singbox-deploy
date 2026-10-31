#!/usr/bin/env bash
# 日志读取的服务后端仅用窄桩，不启动校时或修改系统时间。
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/policy.sh"

cancel_contract() {
    t_fresh
    t_run 0 sbd_time_menu <<< 0
    t_run 0 sbd_time_menu < /dev/null
    t_run 0 sbd_observe_menu <<< $'5\n0\n0'
    t_run 2 sbd_time_prompt <<< ''
    t_run 2 sbd_time_prompt <<< $'\nn'
    t_assert 'EOF/拒绝不初始化配置' test ! -e "$SBD_CONFIG"
    t_assert 'EOF/拒绝不增加修订' jq -e '.revision==0' "$SBD_STATE"
}
default_contract() {
    t_policy_seed
    t_run 0 sbd_time_prompt <<< $'\ny'
    t_absent "$CASE_TMP/output" 'NTP UDP 端口'
    t_absent "$CASE_TMP/output" '原生 NTP 同步间隔'
    t_absent "$CASE_TMP/output" '选择目标标识'
    t_assert '采用确认的 Cloudflare 源和原生默认间隔' jq -e '.ntp|.enabled==true and .server=="time.cloudflare.com" and .server_port==123 and .interval=="30m0s" and .domain_resolver=="system" and (.write_to_system // false)==false' "$SBD_CONFIG"
    t_contains "$CASE_TMP/output" '未验证校时结果'
    t_assert '启用通过真实配置事务提交' jq -e '.revision==1' "$SBD_STATE"
    t_run 0 sbd_check_config
}
field_contract() {
    t_policy_seed
    t_run 1 sbd_time_interval bad
    t_run 1 sbd_time_interval 0s
    t_run 0 sbd_time_interval 10m
    t_run 0 sbd_time_prompt <<< $'bad/path\n127.0.0.1\ny'
    t_assert 'IP 源不新增 bootstrap，已有 resolver 原样保留' jq -e '.ntp.server=="127.0.0.1" and .ntp.server_port==123 and .ntp.interval=="30m0s" and .ntp.domain_resolver=="system" and (.dns.servers|length==1)' "$SBD_CONFIG"
}
disabled_contract() {
    t_policy_seed
    t_run 0 sbd_apply sbd_time_change enable '{"server":"127.0.0.1","server_port":123,"interval":"30m"}'
    t_run 0 sbd_apply sbd_time_change disable
    t_assert '禁用保留源、间隔且禁止系统写时' jq -e '.ntp|(.enabled // false)==false and .server=="127.0.0.1" and .interval=="30m0s" and (.write_to_system // false)==false' "$SBD_CONFIG"
    t_run 0 sbd_time_diagnose
    t_contains "$CASE_TMP/output" '未查询远端时间源'
    t_absent "$CASE_TMP/output" '[成功]'
}
diagnostic_contract() {
    t_fresh
    t_run 0 sbd_time_diagnose
    t_contains "$CASE_TMP/output" '系统 UTC:'
    t_contains "$CASE_TMP/output" '配置尚未创建'
    t_contains "$CASE_TMP/output" '无法据此计算时差'
    t_assert '诊断不创建配置' test ! -e "$SBD_CONFIG"
    t_assert '诊断不写 state' jq -e '.revision==0' "$SBD_STATE"
    printf '{bad' > "$SBD_CONFIG" || exit 1
    t_run 1 sbd_time_diagnose
    t_absent "$CASE_TMP/output" '[成功]'
}
protocol_count() {
    t_policy_seed
    t_run 0 sbd_apply sbd_entry_create "$(jq '.method="2022-blake3-aes-256-gcm"|.password="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' "$ROOT/tests/fixtures/entry-shadowsocks.json")"
    t_run 0 sbd_apply sbd_entry_create "$(cat "$ROOT/tests/fixtures/entry-vmess_ws.json")"
    t_run 0 sbd_time_diagnose
    t_contains "$CASE_TMP/output" 'SS2022/VMess 对象: 2 个'
    t_contains "$CASE_TMP/output" '不校准客户端或其他进程'
    t_absent "$CASE_TMP/output" AAAAAAAAAAAAAAAAA
}
logs_contract() {
    t_policy_seed
    sbd_backend() { printf 'openrc\n'; }
    t_run 1 sbd_time_logs
    printf 'ordinary log\n' > "$SBD_LOG" || exit 1
    t_run 1 sbd_time_logs
    t_contains "$CASE_TMP/output" '没有 NTP/bad timestamp'
    printf 'ntp: updated time fixture\nbad timestamp fixture\nother unrelated fixture\n' > "$SBD_LOG" || exit 1
    t_run 0 sbd_time_logs
    t_contains "$CASE_TMP/output" 'ntp: updated time fixture'
    t_contains "$CASE_TMP/output" 'bad timestamp fixture'
    t_absent "$CASE_TMP/output" 'other unrelated fixture'
    t_contains "$CASE_TMP/output" '历史记录仅供排障'
    t_assert '日志只读不改修订号' jq -e '.revision==0' "$SBD_STATE"
}
t_case '时间菜单取消/EOF、不创建配置或访问公网' cancel_contract
t_case '确认 A 默认源、原生字段和 Schema/check 真实提交' default_contract
t_case '时间源/端口/duration 错误只重问当前字段' field_contract
t_case '禁用保留配置，诊断不冒充当前校时成功' disabled_contract
t_case '无配置本地诊断无副作用，坏配置明确失败' diagnostic_contract
t_case '实际 SS2022/VMess 计数和客户端时间边界' protocol_count
t_case '日志读取失败、无记录和历史 NTP 记录明确区分' logs_contract
t_finish
