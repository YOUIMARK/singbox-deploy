#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/entries.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/classic.sh"

ss_contract() {
    t_seed
    local method spec
    for method in aes-256-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305; do
        spec=$(jq --arg method "$method" '.method=$method | if $method|startswith("2022-") then .password="+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/s=" else . end' "$ROOT/tests/fixtures/entry-shadowsocks.json") || exit 1
        t_run 0 sbd_apply sbd_entry_create "$spec"
        NODE_ID=$(jq -r '.nodes[-1].id' "$SBD_REGISTRY") || exit 1
        t_run 0 t_classic_uri
        t_assert 'SS 不引入 TLS/多用户结构' jq -e '.inbounds[0]|(has("tls") or has("users") or has("network"))|not' "$SBD_CONFIG"
        t_run 0 sbd_apply sbd_entry_change "$NODE_ID" delete ''
    done
}
ss_key_contract() {
    local method
    for method in 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305; do
        t_run 1 sbd_entry_ss_key "$method" <<< 'not-base64'
        t_run 1 sbd_entry_ss_key "$method" <<< 'YWJjZA=='
        t_run 1 sbd_entry_ss_key "$method" <<< '__________________________________________8='
    done
    t_run 1 sbd_entry_ss_key aes-128-gcm <<< 'abc'
    t_run 1 sbd_entry_ss_key aes-256-gcm <<< ''
}
ws_contract() {
    t_seed
    local profile
    for profile in vmess_ws vless_ws; do
        t_entry_add "$profile"
        t_run 0 t_classic_uri
        t_assert 'CDN 源站使用早期数据头且没有 TLS、max_early_data 和 Host 伪字段' jq -e '.inbounds[0]|(has("tls")|not) and .transport.type=="ws" and .transport.early_data_header_name=="Sec-WebSocket-Protocol" and (.transport|has("max_early_data")|not) and (.transport|has("headers")|not)' "$SBD_CONFIG"
        t_assert '不生成无用证书材料' test -z "$(find "$SBD_CERT_DIR" -mindepth 1 -maxdepth 1 -print -quit)"
        t_assert '优选地址、前端和回源事实独立' jq -e '.nodes[0]|.client.server=="2001:db8::10" and .client.server_port==443 and .ingress.origin_port!=443 and .ingress.host=="cdn.example.com"' "$SBD_REGISTRY"
        t_assert 'WS 客户端显式启用 uTLS chrome' jq -e '.nodes[0].client.tls.utls | .enabled==true and .fingerprint=="chrome"' "$SBD_REGISTRY"
        t_assert 'VMess AEAD 或 VLESS 无 flow 均为原生字段' jq -e '.inbounds[0]|if .type=="vmess" then (.users[0].alterId // 0)==0 else (.users[0]|has("flow")|not) end' "$SBD_CONFIG"
        t_assert 'native JSON 不混入 URI encryption 字段' jq -e '.outbounds[0]|has("encryption")|not' "$SBD_EXPORTS/$NODE_ID.json"
        t_run 0 sbd_apply sbd_entry_change "$NODE_ID" delete ''
    done
}
vision_contract() {
    t_seed
    t_entry_add vless_reality
    t_run 0 t_classic_uri
    t_assert 'Vision 服务端 flow，TCP 不伪装成 transport' jq -e '.inbounds[0]|.users[0].flow=="xtls-rprx-vision" and (has("transport")|not) and (.tls|has("utls")|not)' "$SBD_CONFIG"
    t_absent "$SBD_EXPORTS/$NODE_ID.json" private_key
}
cdn_origin_contract() {
    t_seed
    t_run 0 sbd_entry_create_prompt <<< $'5\n127.0.0.1\n19505\ncdn.example.com\n\n\n/ws\n回源同步\n\ny'
    t_assert '创建时回源端口等于监听端口' jq -e '.nodes[0].ingress.origin_port==19505' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_entry_change "$(jq -r '.nodes[0].id' "$SBD_REGISTRY")" listen '{"listen":"127.0.0.1","listen_port":19610}'
    t_assert '改监听端口后回源端口跟随' jq -e '.nodes[0].ingress.origin_port==19610' "$SBD_REGISTRY"
    t_assert '监听端口已更新' jq -e '.inbounds[0].listen_port==19610' "$SBD_CONFIG"
}
t_case 'SS 三算法真实 Schema/check 与 SIP002 回读' ss_contract
t_case 'SS2022 密钥长度和编码、算法边界' ss_key_contract
t_case '双 WS CDN 原生配置、URI 和三个端口事实' ws_contract
t_case 'VLESS Reality Vision 公私钥与 URI' vision_contract
t_case '改本地监听端口后 CDN 回源端口跟随' cdn_origin_contract
t_finish
