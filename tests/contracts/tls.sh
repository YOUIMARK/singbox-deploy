#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

identity_contract() {
    t_assert 'IPv4 SAN' test "$(sbd_tls_identity 192.0.2.1)" = IP:192.0.2.1
    t_assert 'IPv6 SAN' test "$(sbd_tls_identity 2001:db8::1)" = IP:2001:db8::1
    t_assert 'DNS SAN' test "$(sbd_tls_identity node.example.com)" = DNS:node.example.com
    t_run 1 sbd_tls_identity 'a/b'
    t_run 1 sbd_tls_identity 'a,b'
    t_run 1 sbd_tls_identity 'bad..example'
    t_run 1 sbd_tls_tag '../external'
}
provider_contract() {
    t_seed
    local tag challenge
    for tag in cloudflare alidns acmedns; do
        case "$tag" in
            cloudflare) challenge='{"provider":"cloudflare","api_token":"fixture-secret","zone_token":"fixture-zone"}' ;;
            alidns) challenge='{"provider":"alidns","access_key_id":"fixture-id","access_key_secret":"fixture-secret","region_id":"cn-hangzhou","security_token":"fixture-sts"}' ;;
            acmedns) challenge='{"provider":"acmedns","username":"fixture-user","password":"fixture-secret","subdomain":"fixture-sub","server_url":"https://acme-dns.example.com"}' ;;
        esac
        t_run 0 sbd_apply sbd_tls_provider_add "$tag" '*.example.com' admin@example.com "$challenge"
        t_absent "$CASE_TMP/output" fixture-secret
    done
    t_assert '三种真实 provider 进入官方结构' jq -e '.certificate_providers|length==3 and all(.[]; .type=="acme" and .key_type=="p256" and has("dns01_challenge") and (has("acme")|not))' "$SBD_CONFIG"
    t_assert '只登记标识不复制凭据' jq -e '.tls.providers==["cloudflare","alidns","acmedns"]' "$SBD_REGISTRY"
    t_run 0 sbd_tls_list
    t_absent "$CASE_TMP/output" fixture-secret
    t_assert '离线 check 没有签发或创建 ACME 存储' test ! -e "$SBD_DATA/acme"
    t_run 1 sbd_apply sbd_tls_provider_add cloudflare other.example.com admin@example.com '{"provider":"cloudflare","api_token":"secret"}'
    t_contains "$CASE_TMP/output" '已存在'
    t_run 1 sbd_apply sbd_tls_provider_add empty example.com admin@example.com '{"provider":"cloudflare"}'
}
self_signed_contract() {
    t_seed
    t_run 0 sbd_apply sbd_tls_material_add self_signed 2001:db8::1
    local cert key id
    cert=$(jq -r '.tls.certificates[0].certificate_path' "$SBD_REGISTRY")
    key=$(jq -r '.tls.certificates[0].key_path' "$SBD_REGISTRY")
    id=$(jq -r '.tls.certificates[0].id' "$SBD_REGISTRY")
    t_run 0 sbd_tls_pair "$cert" "$key" 2001:db8::1 "$CASE_TMP"
    t_run 1 sbd_tls_pair "$cert" "$key" 192.0.2.1 "$CASE_TMP"
    openssl pkey -in "$key" -text -noout > "$CASE_TMP/key-info" || exit 1
    t_contains "$CASE_TMP/key-info" prime256v1
    t_assert '私钥权限 600' test "$(stat -c %a "$key")" = 600
    sbd_tls_client "$SBD_DATA" "$id" pin > "$CASE_TMP/client-tls.json" || exit 1
    t_assert '使用 1.14 SPKI pin 且不默认 insecure' jq -e '.enabled and (.certificate_public_key_sha256|length==1) and (has("insecure")|not) and (has("certificate_sha256")|not)' "$CASE_TMP/client-tls.json"
    t_run 1 sbd_tls_client "$SBD_DATA" "$id" system
    sbd_tls_client "$SBD_DATA" "$id" certificate > "$CASE_TMP/trust.json" || exit 1
    t_contains "$CASE_TMP/trust.json" 'BEGIN CERTIFICATE'
}
external_contract() {
    t_seed
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=import.example.com -addext subjectAltName=DNS:import.example.com -keyout "$CASE_TMP/external-key.pem" -out "$CASE_TMP/external-cert.pem" >/dev/null 2>&1 || exit 1
    cp "$CASE_TMP/external-cert.pem" "$CASE_TMP/cert-before" || exit 1
    cp "$CASE_TMP/external-key.pem" "$CASE_TMP/key-before" || exit 1
    t_run 0 sbd_apply sbd_tls_material_add import import.example.com "$CASE_TMP/external-cert.pem" "$CASE_TMP/external-key.pem"
    local id
    id=$(jq -r '.tls.certificates[0].id' "$SBD_REGISTRY")
    t_run 0 sbd_apply sbd_tls_remove certificate "$id"
    t_run 0 sbd_apply t_edit_debug
    t_assert '导入证书原文件保留' cmp -s "$CASE_TMP/external-cert.pem" "$CASE_TMP/cert-before"
    t_assert '导入私钥原文件保留' cmp -s "$CASE_TMP/external-key.pem" "$CASE_TMP/key-before"
    t_run 1 sbd_apply sbd_tls_material_add import wrong.example.com "$CASE_TMP/external-cert.pem" "$CASE_TMP/external-key.pem"
    t_run 1 sbd_apply sbd_tls_material_add import import.example.com "$CASE_TMP/external-cert.pem" "$CASE_TMP/missing.pem"
}
import_retry() {
    t_seed
    local cert="$CASE_TMP/cert.pem" key="$CASE_TMP/key.pem" wrong="$CASE_TMP/wrong.pem"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=retry.example.com -addext subjectAltName=DNS:retry.example.com -keyout "$key" -out "$cert" >/dev/null 2>&1 || exit 1
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$wrong" >/dev/null 2>&1 || exit 1
    t_run 0 sbd_tls_material_prompt import <<< "$(printf 'retry.example.com\n%s\n%s\n%s\n%s\n' "$CASE_TMP/missing" "$cert" "$wrong" "$key")"
    t_contains "$CASE_TMP/output" '请仅重新填写私钥路径'
    # jq 参数保持字面值，不由 Bash 展开。
    # shellcheck disable=SC2016
    t_assert '证书字段成功后不被重问或丢失' jq -e --arg cert "$cert" --arg key "$key" '.tls.certificates[0] | .certificate_path==$cert and .key_path==$key and .server_name=="retry.example.com"' "$SBD_REGISTRY"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=retry.example.com -keyout "$CASE_TMP/old-key.pem" -out "$CASE_TMP/cn-only.pem" >/dev/null 2>&1 || exit 1
    t_run 1 sbd_apply sbd_tls_material_add import retry.example.com "$CASE_TMP/cn-only.pem" "$CASE_TMP/old-key.pem"
    t_contains "$CASE_TMP/output" subjectAltName
}
prompt_contract() {
    t_seed
    t_run 0 sbd_tls_menu <<< 0
    t_run 0 sbd_tls_menu < /dev/null
    t_run 2 sbd_tls_provider_prompt <<< $'tag\nexample.com\nadmin@example.com\n1'
    t_unchanged
    t_run 0 sbd_tls_provider_prompt <<< $'bad/name\nvalid\nbad/name\nexample.com\nnot-email\nadmin@example.com\n01\nfixture-secret\n'
    t_absent "$CASE_TMP/output" fixture-secret
    # 1.14.4 原生 format 将单元素 Listable 域名数组格式化为字符串。
    t_assert '错误只重问当前字段' jq -e '.certificate_providers[0] | .tag=="valid" and .domain=="example.com" and .email=="admin@example.com"' "$SBD_CONFIG"
}
# 本套件只调用真实菜单、OpenSSL、Schema 和核心；不向 CA 发起签发。
t_case 'TLS 名称和标识输入契约' identity_contract
t_case '三种 DNS-01 原生 provider 真实校验且凭据不回显' provider_contract
t_case 'P-256 IPv6 SAN 与证书/公钥信任' self_signed_contract
t_case '导入 PEM 校验并保留外部所有权' external_contract
t_case 'PEM 输入错误只重问当前字段且拒绝 CN-only 证书' import_retry
t_case 'TLS 菜单字段重问与必填 EOF 取消' prompt_contract
t_finish
