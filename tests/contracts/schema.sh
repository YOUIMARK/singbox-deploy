#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

prepare_valid() {
    t_fresh
    mkdir "$CASE_TMP/stage" || exit 1
    cp "$ROOT/presets/base.json" "$CASE_TMP/stage/config.json" || exit 1
    t_run 0 sbd_prepare_config "$CASE_TMP/stage"
    # $schema 是 JSON 属性名，不是 shell 变量。
    # shellcheck disable=SC2016
    t_assert '本地 schema 引用保留' jq -e '."$schema"=="./schema.json"' "$CASE_TMP/stage/config.json"
    t_run 0 sbd_validate_schema "$CASE_TMP/stage/schema.json" "$CASE_TMP/stage/config.json"
}
wrong_type() {
    t_fresh
    "$SBD_BINARY" schema -o "$CASE_TMP/schema.json" || exit 1
    t_run 1 sbd_validate_schema "$CASE_TMP/schema.json" "$ROOT/tests/fixtures/invalid-type.json"
    t_contains "$CASE_TMP/output" 'Schema'
}
unknown_field() {
    t_fresh
    "$SBD_BINARY" schema -o "$CASE_TMP/schema.json" || exit 1
    printf '{"unknown_field":true}' > "$CASE_TMP/invalid.json" || exit 1
    t_run 1 sbd_validate_schema "$CASE_TMP/schema.json" "$CASE_TMP/invalid.json"
    t_contains "$CASE_TMP/output" additionalProperties
}
no_secret_leak() {
    t_fresh
    "$SBD_BINARY" schema -o "$CASE_TMP/schema.json" || exit 1
    printf '{"log":{"level":"SECRET_MUST_NOT_APPEAR"}}' > "$CASE_TMP/invalid.json" || exit 1
    t_run 1 sbd_validate_schema "$CASE_TMP/schema.json" "$CASE_TMP/invalid.json"
    t_absent "$CASE_TMP/output" SECRET_MUST_NOT_APPEAR
}
semantic_failure() {
    t_fresh
    mkdir "$CASE_TMP/stage" || exit 1
    cp "$ROOT/tests/fixtures/invalid-key.json" "$CASE_TMP/stage/config.json" || exit 1
    t_run 1 sbd_prepare_config "$CASE_TMP/stage"
    t_contains "$CASE_TMP/output" '核心语义检查失败'
}
check_boundary() {
    t_fresh
    mkdir "$CASE_TMP/stage" || exit 1
    cp "$ROOT/tests/fixtures/invalid-reference.json" "$CASE_TMP/stage/config.json" || exit 1
    # 1.14.4 的 check 不在这里验证 route.final 的存活引用，不能伪造其覆盖范围。
    t_run 0 sbd_prepare_config "$CASE_TMP/stage"
    t_assert '坏引用未被手工改写' jq -e '.route.final=="missing-outbound"' "$CASE_TMP/stage/config.json"
}
version_gate() {
    t_fresh
    printf '#!/usr/bin/env bash\nprintf "sing-box version 1.13.9\\n"\n' > "$CASE_TMP/old-core" || exit 1
    chmod +x "$CASE_TMP/old-core" || exit 1
    SBD_BINARY="$CASE_TMP/old-core"
    t_run 1 sbd_version
    t_contains "$CASE_TMP/output" '至少为 1.14.0'
    printf '#!/usr/bin/env bash\nprintf "1.14.4\\n"\n' > "$CASE_TMP/old-core" || exit 1
    t_run 1 sbd_version
    t_contains "$CASE_TMP/output" '无法识别'
    SBD_BINARY="$CASE_TMP/missing"
    t_run 1 sbd_version
}
t_case '目标核心生成、校验和 format/check' prepare_valid
t_case '真实 Schema 拒绝类型错误' wrong_type
t_case '真实 Schema 拒绝未知字段' unknown_field
t_case '错误信息不输出实例凭据' no_secret_leak
t_case '真实 check 拒绝非法 SS2022 密钥' semantic_failure
t_case '如实记录 check 对路由引用的边界' check_boundary
t_case '旧核心与缺核心明确拒绝' version_gate
t_finish
