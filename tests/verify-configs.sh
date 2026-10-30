#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/support/harness.sh"

base_contract() {
    t_fresh
    cp "$ROOT/presets/base.json" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_prepare_config "$SBD_CONFIG_DIR"
    t_run 0 sbd_validate_schema "$SBD_SCHEMA" "$SBD_CONFIG"
    t_run 0 "$SBD_BINARY" check -c "$SBD_CONFIG" -D "$SBD_ROOT"
    t_assert '未创建实际协议节点' jq -e '(.inbounds // [])==[]' "$SBD_CONFIG"
    t_assert '基础配置默认开启核心 NTP，不写系统时钟' jq -e '.ntp.enabled==true and .ntp.server=="time.cloudflare.com" and .ntp.domain_resolver=="system" and (.ntp.write_to_system // false)==false' "$SBD_CONFIG"
}
formatter_order() {
    t_fresh
    cp "$ROOT/presets/base.json" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_prepare_config "$SBD_CONFIG_DIR"
    # 官方键名 $schema 在 Python 字符串中保持字面值。
    # shellcheck disable=SC2016
    t_run 0 python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); order=["$schema","log","dns","ntp","certificate","certificate_providers","http_clients","network_namespaces","endpoints","inbounds","outbounds","route","services","experimental"]; sys.exit(0 if list(d)==[k for k in order if k in d] else 1)' "$SBD_CONFIG"
    "$SBD_BINARY" format -c "$SBD_CONFIG" -D "$SBD_ROOT" > "$CASE_TMP/twice" || exit 1
    t_assert '官方 format 二次结果稳定' cmp -s "$SBD_CONFIG" "$CASE_TMP/twice"
}
required_field() {
    t_fresh
    "$SBD_BINARY" schema -o "$CASE_TMP/schema.json" || exit 1
    printf '{"inbounds":[{"type":"not-a-real-inbound"}]}' > "$CASE_TMP/unknown.json" || exit 1
    t_run 1 sbd_validate_schema "$CASE_TMP/schema.json" "$CASE_TMP/unknown.json"
    t_contains "$CASE_TMP/output" 'Schema'
}
missing_type() {
    t_fresh
    "$SBD_BINARY" schema -o "$CASE_TMP/schema.json" || exit 1
    printf '{"inbounds":[{"listen":"127.0.0.1","listen_port":18443}]}' > "$CASE_TMP/missing.json" || exit 1
    t_run 1 sbd_validate_schema "$CASE_TMP/schema.json" "$CASE_TMP/missing.json"
    t_contains "$CASE_TMP/output" 'Schema'
}
t_case '真实基础配置通过 Schema 与 check' base_contract
t_case '官方顶层键序与 format 稳定性' formatter_order
t_case '真实 Schema 拒绝不存在的协议类型' required_field
t_case '真实 Schema 拒绝缺少协议类型' missing_type
t_finish
