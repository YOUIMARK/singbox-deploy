#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

prepare_valid() {
    t_fresh
    mkdir "$CASE_TMP/stage" || exit 1
    cp "$ROOT/presets/base.json" "$CASE_TMP/stage/config.json" || exit 1
    t_run 0 sbd_prepare_config "$CASE_TMP/stage"
    t_absent "$CASE_TMP/output" 'merged.json.raw'
    t_absent "$CASE_TMP/output" '/tmp/'
    # $schema 是 JSON 属性名，不是 shell 变量。
    # shellcheck disable=SC2016
    t_assert '本地 schema 引用保留' jq -e '."$schema"=="./schema.json"' "$CASE_TMP/stage/config.json"
    t_run 0 sbd_validate_schema "$CASE_TMP/stage/schema.json" "$CASE_TMP/stage/config.json"
    t_assert '单配置文件保留官方 format 结果' jq -e 'has("log") and has("dns") and has("outbounds") and has("route")' "$CASE_TMP/stage/config.json"
    t_assert '不再生成配置分片目录' test ! -e "$CASE_TMP/stage/config"
}
certificate_paths_only() {
    t_fresh
    mkdir "$CASE_TMP/stage" || exit 1
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
        -subj /CN=node.example.com -addext subjectAltName=DNS:node.example.com \
        -keyout "$CASE_TMP/key.pem" -out "$CASE_TMP/cert.pem" >/dev/null 2>&1 || exit 1
    jq -n --arg cert "$CASE_TMP/cert.pem" --arg key "$CASE_TMP/key.pem" '{
        "$schema":"./schema.json",
        inbounds:[{type:"anytls",tag:"tls-path",listen:"127.0.0.1",listen_port:18443,
            users:[{name:"fixture",password:"fixture"}],
            tls:{enabled:true,certificate_path:$cert,key_path:$key}}],
        outbounds:[{type:"direct",tag:"direct"}],
        route:{final:"direct"}
    }' > "$CASE_TMP/stage/config.json" || exit 1
    t_run 0 sbd_prepare_config "$CASE_TMP/stage"
    t_assert '格式化后仍使用证书文件路径' jq -e '.inbounds[0].tls|has("certificate_path") and has("key_path")' "$CASE_TMP/stage/config.json"
    t_assert '格式化后不新增内嵌证书' jq -e '.inbounds[0].tls|(has("certificate") or has("key"))|not' "$CASE_TMP/stage/config.json"
}
wrong_type() {
    t_fresh
    "$SBD_BINARY" schema -o "$CASE_TMP/schema.json" || exit 1
    t_run 1 sbd_validate_schema "$CASE_TMP/schema.json" "$ROOT/tests/fixtures/invalid-type.json"
    t_contains "$CASE_TMP/output" 'Schema'
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
t_case '格式化后仍保留证书路径事实' certificate_paths_only
t_case '真实 Schema 拒绝非法枚举值' wrong_type
t_case '真实 check 拒绝非法 SS2022 密钥' semantic_failure
t_case '如实记录 check 对路由引用的边界' check_boundary
t_case '旧核心与缺核心明确拒绝' version_gate
t_finish
