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
        t_run 1 sbd_entry_ss_key "$method" not-base64
        t_run 1 sbd_entry_ss_key "$method" YWJjZA==
        t_run 1 sbd_entry_ss_key "$method" '__________________________________________8='
    done
    t_run 1 sbd_entry_ss_key aes-128-gcm abc
    t_run 1 sbd_entry_ss_key aes-256-gcm ''
}
ws_contract() {
    t_seed
    local profile
    for profile in vmess_ws vless_ws; do
        t_entry_add "$profile"
        t_run 0 t_classic_uri
        t_assert 'CDN 源站没有 TLS 和请求 Host 匹配伪字段' jq -e '.inbounds[0]|(has("tls")|not) and .transport.type=="ws" and (.transport|has("headers")|not)' "$SBD_CONFIG"
        t_assert '不生成无用证书材料' test ! -e "$SBD_DATA/certificates"
        t_assert '优选地址、前端和回源事实独立' jq -e '.nodes[0]|.client.server=="2001:db8::10" and .client.server_port==443 and .ingress.origin_port!=443 and .ingress.host=="cdn.example.com"' "$SBD_REGISTRY"
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
field_contract() {
    t_fresh
    sbd_entry_uuid_prompt > "$CASE_TMP/prompt" 2>&1 <<< $'bad\n899954A1-86C4-4DB7-B7A3-8B6F196A890E' || exit 1
    t_assert 'UUID 错误只重问且规范化' test "$SBD_REPLY" = 899954a1-86c4-4db7-b7a3-8b6f196a890e
    t_absent "$CASE_TMP/prompt" 899954A1
    sbd_entry_uuid_prompt > "$CASE_TMP/prompt" 2>&1 <<< '' || exit 1
    t_run 0 sbd_entry_uuid "$SBD_REPLY"
    sbd_entry_ss_password_prompt 2022-blake3-aes-256-gcm > "$CASE_TMP/prompt" 2>&1 <<< $'bad\n' || exit 1
    t_run 0 sbd_entry_ss_key 2022-blake3-aes-256-gcm "$SBD_REPLY"
    t_run 2 sbd_entry_uuid_prompt < /dev/null
    t_run 2 sbd_entry_ss_prompt <<< $'1\n2'
    t_run 1 sbd_entry_ws_path /ws?ed=2560
    t_run 1 sbd_entry_ws_path /ws#fragment
    sbd_entry_cdn_prompt 19505 > "$CASE_TMP/prompt" 2>&1 <<< $'127.0.0.1\ncdn.example.com\n\n\n\n' || exit 1
    t_assert 'CDN 字段重问和默认前端 443' jq -e '.host=="cdn.example.com" and .server=="cdn.example.com" and .origin_port==19505 and .server_port==443 and (.path|startswith("/"))' <<< "$SBD_CDN_REQUEST"
}
menu_contract() {
    t_seed
    t_run 0 sbd_entry_create_prompt <<< $'5\n127.0.0.1\n19505\ncdn.example.com\n29505\n\n\n/ws\n菜单CDN\n\ny'
    NODE_ID=$(jq -r '.nodes[0].id' "$SBD_REGISTRY") || exit 1
    t_contains "$CASE_TMP/output" "分享链接: $(cat "$SBD_EXPORTS/$NODE_ID.txt")"
    t_absent "$CASE_TMP/output" '未验证 NAT'
    t_absent "$CASE_TMP/output" '当前节点链接'
    t_run 0 t_classic_uri
    t_run 0 sbd_entry_change_prompt <<< $'1\n2\n\ny'
    t_run 0 t_classic_uri
    t_run 0 sbd_entry_change_prompt <<< $'1\n9\nnew.example.com\n39505\n\n\n/new\ny'
    t_assert '菜单修改真实 CDN 和源站路径' jq -e '.inbounds[0].transport.path=="/new"' "$SBD_CONFIG"
    t_run 0 t_classic_uri
    t_run 2 sbd_entry_change_prompt <<< $'1\n6'
    t_contains "$CASE_TMP/output" '选择显示的编号'
}
required_contract() {
    t_seed
    local profile expression
    for profile in shadowsocks vmess_ws vless_reality vless_ws; do
        t_entry_add "$profile"
        jq '.nodes[-1]' "$SBD_REGISTRY" > "$CASE_TMP/node.json" || exit 1
        for expression in 'del(.client.server)' 'del(.client.server_port)' 'del(.name)' 'del(.client.password,.client.uuid)'; do
            jq "$expression" "$CASE_TMP/node.json" > "$CASE_TMP/bad.json" || exit 1
            t_run 1 sbd_share_build "$CASE_TMP/bad.json"
            t_absent "$CASE_TMP/output" '://'
        done
        case "$profile" in
            shadowsocks) expression='.client.plugin="obfs-local"' ;;
            vmess_ws|vless_ws) expression='del(.client.transport.path)' ;;
            vless_reality) expression='del(.client.tls.reality.public_key)' ;;
        esac
        jq "$expression" "$CASE_TMP/node.json" > "$CASE_TMP/bad.json" || exit 1
        t_run 1 sbd_share_build "$CASE_TMP/bad.json"
        t_absent "$CASE_TMP/output" '://'
    done
}
t_case 'SS 三算法真实 Schema/check 与 SIP002 回读' ss_contract
t_case 'SS2022 密钥长度和编码、算法边界' ss_key_contract
t_case '双 WS CDN 原生配置、URI 和三个端口事实' ws_contract
t_case 'VLESS Reality Vision 公私钥与 URI' vision_contract
t_case 'UUID/密钥/域名字段重问、默认与 EOF' field_contract
t_case '真实菜单创建 WS、编辑 UUID/CDN 和拒绝源站 TLS' menu_contract
t_case '四档分享缺少必需字段明确失败' required_contract
t_finish
