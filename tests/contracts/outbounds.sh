#!/usr/bin/env bash
# shellcheck disable=SC2016
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

REALITY_PBK=ys6cWdAtS7dUtjHnUoJCBJ130tl_Z0v0q2thrXW9k14
HY2_LINK='hysteria2://demo-secret@hy2.example.com:10010?sni=hy2.example.com&mport=10011-10080#NL-Hy2'

parse_link() {
    printf '%s\n' "$1" | python3 "$ROOT/support/outbound_link.py"
}

add_outbound() {
    local link="$1" tag="$2" answer="${3:-n}"
    if [[ -n "$tag" ]]; then
        t_run 0 sbd_outbound_add_prompt <<< "$link"$'\n'"$tag"$'\ny\n'"$answer"$'\n'
    else
        t_run 0 sbd_outbound_add_prompt <<< "$link"$'\n\ny\n'"$answer"$'\n'
    fi
}

hy2_example_contract() {
    t_seed
    local final
    t_run 0 parse_link "$HY2_LINK"
    t_assert '默认 tag 来自链接 fragment' jq -e '.tag=="NL-Hy2"' "$CASE_TMP/output"
    t_assert 'Hysteria2 字段完整' jq -e '
        .outbound | .type=="hysteria2" and
        .server=="hy2.example.com" and .server_port==10010 and
        .password=="demo-secret" and .tls.enabled==true and
        .tls.server_name=="hy2.example.com" and
        .server_ports==["10011:10080"]
    ' "$CASE_TMP/output"
    final=$(jq -r '.route.final' "$SBD_CONFIG") || exit 1
    t_run 0 sbd_apply sbd_outbound_add "$(jq -c '.outbound + {tag:.tag}' "$CASE_TMP/output")"
    t_run 0 sbd_check_config
    t_assert '出口已追加且保留 direct' jq -e '
        .outbounds[0].tag=="direct" and
        .outbounds[-1].tag=="NL-Hy2" and
        (.outbounds[-1].server_ports==["10011:10080"] or
         .outbounds[-1].server_ports=="10011:10080")
    ' "$SBD_CONFIG"
    t_assert '默认路由不变' test "$(jq -r '.route.final' "$SBD_CONFIG")" = "$final"

    t_run 0 parse_link 'hysteria2://demo-secret@hy2.example.com:10010?sni=hy2.example.com&insecure=1&pinSHA256=&vcn=&unknown-empty=#Hy2-Insecure'
    t_assert 'Hysteria2 insecure 映射且空字段忽略' jq -e '.outbound.tls.insecure==true' "$CASE_TMP/output"
}

tag_prompt_contract() {
    t_seed
    add_outbound "$HY2_LINK" ''
    t_contains "$CASE_TMP/output" '出口已添加: NL-Hy2'
    t_assert '回车采用链接 tag' jq -e '.outbounds[-1].tag=="NL-Hy2"' "$SBD_CONFIG"

    add_outbound "$HY2_LINK" 'Custom-Hy2'
    t_contains "$CASE_TMP/output" '出口已添加: Custom-Hy2'
    t_assert '自定义 tag 覆盖链接 tag' jq -e '.outbounds[-1].tag=="Custom-Hy2"' "$SBD_CONFIG"

    cp "$SBD_CONFIG" "$CASE_TMP/config-before" || exit 1
    cp "$SBD_STATE" "$CASE_TMP/state-before" || exit 1
    t_run 2 sbd_outbound_add_prompt <<< "$HY2_LINK"$'\n\n'
    t_contains "$CASE_TMP/output" '出口 tag 已存在: NL-Hy2'
    t_assert '重复 tag 不改配置' cmp -s "$SBD_CONFIG" "$CASE_TMP/config-before"
    t_assert '重复 tag 不改修订' cmp -s "$SBD_STATE" "$CASE_TMP/state-before"
}

tag_scan_contract() {
    t_seed
    local probe="$CASE_TMP/probe.json"
    jq '.dns = {servers:["local",{"tag":"dns-x"}]}' "$SBD_CONFIG" > "$probe" || exit 1
    t_run 0 sbd_outbound_tag_exists "$probe" direct
    t_run 0 sbd_outbound_tag_exists "$probe" dns-x
    t_run 1 sbd_outbound_tag_exists "$probe" missing
}

reject_contract() {
    t_seed
    local secret='Hy2Secret-import-test'
    t_run 1 sbd_outbound_add_prompt <<< "hysteria2://$secret@example.com:443?sni=example.com&pinSHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#Bad"$'\n'
    t_contains "$CASE_TMP/output" 'pinSHA256'
    t_absent "$CASE_TMP/output" "$secret"
    t_unchanged

    t_run 1 sbd_outbound_add_prompt <<< 'tuic://secret@example.com:443#TUIC'$'\n'
    t_contains "$CASE_TMP/output" '暂不支持 tuic://'
    t_unchanged

    t_run 1 sbd_outbound_add_prompt <<< 'hysteria2://secret@example.com:443?sni=example.com&unknown=1#Bad'$'\n'
    t_contains "$CASE_TMP/output" 'unknown'
    t_unchanged

    t_run 1 sbd_outbound_add_prompt <<< 'trojan://secret@example.com:443?sni=example.com#Trojan'$'\n'
    t_contains "$CASE_TMP/output" '暂不支持 trojan://'
    t_unchanged

    t_run 1 sbd_outbound_add_prompt <<< 'vless://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?encryption=none&security=tls&sni=example.com&type=grpc&serviceName=grpc-svc#gRPC'$'\n'
    t_contains "$CASE_TMP/output" '暂不支持 gRPC'
    t_unchanged

    t_run 1 sbd_outbound_add_prompt <<< 'vmess://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?encryption=auto&security=tls&sni=example.com&type=grpc#gRPC'$'\n'
    t_contains "$CASE_TMP/output" '暂不支持 gRPC'
    t_unchanged
}

vless_contract() {
    t_seed
    local link
    link="vless://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?encryption=none&security=reality&sni=www.example.com&fp=chrome&pbk=$REALITY_PBK&sid=ab12&flow=xtls-rprx-vision&type=tcp#VLESS-R"
    t_run 0 parse_link "$link"
    t_assert 'VLESS Reality 映射' jq -e '
        (.tag=="VLESS-R") and (.outbound |
        .type=="vless" and .uuid=="899954a1-86c4-4db7-b7a3-8b6f196a890e" and
        .flow=="xtls-rprx-vision" and .tls.reality.public_key=="'"$REALITY_PBK"'" and
        .tls.reality.short_id=="ab12" and .tls.utls.fingerprint=="chrome" and
        (has("transport")|not))
    ' "$CASE_TMP/output"
    t_run 0 sbd_apply sbd_outbound_add "$(jq -c '.outbound + {tag:.tag}' "$CASE_TMP/output")"
    t_run 0 sbd_check_config
    t_assert 'VLESS Reality 进入配置' jq -e '.outbounds[-1].tag=="VLESS-R" and .outbounds[-1].tls.reality.enabled' "$SBD_CONFIG"

    t_run 0 parse_link 'vless://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?encryption=none&security=tls&sni=example.com&insecure=1&pcs=&vcn=#VLESS-TLS'
    t_assert 'VLESS insecure 映射且空字段忽略' jq -e '.outbound.tls.insecure==true' "$CASE_TMP/output"
}

vmess_contract() {
    t_seed
    local json payload link
    json=$(jq -cn '{
        v:"2",ps:"VMess Legacy",add:"example.com",port:"443",
        id:"899954a1-86c4-4db7-b7a3-8b6f196a890e",aid:"0",scy:"auto",
        net:"ws",type:"none",host:"cdn.example.com",path:"/ws",tls:"tls",
        sni:"cdn.example.com",alpn:"h2,http/1.1",fp:"chrome",
        insecure:true,pcs:"",vcn:"",unknown_empty:""
    }') || exit 1
    payload=$(printf '%s' "$json" | openssl base64 -A | tr '+/' '-_' | tr -d '=') || exit 1
    link="vmess://$payload#VMess-Test"
    t_run 0 parse_link "$link"
    t_assert 'VMess Base64 映射' jq -e '
        (.tag=="VMess-Test") and (.outbound |
        .type=="vmess" and .security=="auto" and .alter_id==0 and
        .tls.server_name=="cdn.example.com" and .tls.insecure==true and
        .transport.type=="ws" and .transport.path=="/ws" and
        .transport.headers.Host=="cdn.example.com")
    ' "$CASE_TMP/output"
    t_run 0 sbd_apply sbd_outbound_add "$(jq -c '.outbound + {tag:.tag}' "$CASE_TMP/output")"
    t_run 0 sbd_check_config
    t_assert 'VMess 进入配置' jq -e '.outbounds[-1].tag=="VMess-Test"' "$SBD_CONFIG"

    t_run 0 parse_link "vmess://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?type=ws&security=tls&sni=cdn.example.com&host=cdn.example.com&path=%2Fws&scy=auto&insecure=1&pcs=&vcn=#VMess-URL"
    t_assert 'VMess URL 形式映射' jq -e '.outbound.type=="vmess" and .outbound.transport.type=="ws" and .outbound.tls.insecure==true' "$CASE_TMP/output"

    json=$(jq -cn '{
        v:"2",ps:"VMess Bad Pin",add:"example.com",port:"443",
        id:"899954a1-86c4-4db7-b7a3-8b6f196a890e",aid:"0",scy:"auto",
        net:"ws",type:"none",pcs:"cert-pin",vcn:"example.org"
    }') || exit 1
    payload=$(printf '%s' "$json" | openssl base64 -A | tr '+/' '-_' | tr -d '=') || exit 1
    t_run 1 parse_link "vmess://$payload"
    t_contains "$CASE_TMP/output" 'pcs'
    t_contains "$CASE_TMP/output" 'vcn'
}

gecko_contract() {
    t_seed
    local link='hysteria2://gecko-secret@example.com:443?sni=example.com&obfs=gecko&obfs-password=gecko-pass&minPacketSize=600&maxPacketSize=1300#Gecko-Hy2'
    t_run 0 parse_link "$link"
    t_assert 'Gecko 自定义包长映射' jq -e '
        .outbound.obfs.type=="gecko" and
        .outbound.obfs.min_packet_size==600 and
        .outbound.obfs.max_packet_size==1300
    ' "$CASE_TMP/output"
    t_run 0 sbd_apply sbd_outbound_add "$(jq -c '.outbound + {tag:.tag}' "$CASE_TMP/output")"
    t_run 0 sbd_check_config
    t_run 1 parse_link 'hysteria2://gecko-secret@example.com:443?sni=example.com&obfs=gecko&obfs-password=gecko-pass&minPacketSize=1400&maxPacketSize=1300#Bad'
    t_contains "$CASE_TMP/output" '最小包长不能大于最大包长'
}

ss_anytls_contract() {
    t_seed
    local ss ss2022 key

    ss="ss://$(printf '%s' 'aes-256-gcm:ss-secret@example.com:8388' | openssl base64 -A)#SS"
    t_run 0 parse_link "$ss"
    t_assert 'Shadowsocks 旧式 Base64 映射' jq -e '
        .outbound | .type=="shadowsocks" and .method=="aes-256-gcm" and
        .password=="ss-secret" and .server=="example.com" and .server_port==8388
    ' "$CASE_TMP/output"
    t_run 0 sbd_apply sbd_outbound_add "$(jq -c '.outbound + {tag:.tag}' "$CASE_TMP/output")"
    t_run 0 sbd_check_config

    key=$(openssl rand -base64 32) || exit 1
    ss2022="ss://2022-blake3-aes-256-gcm:$key@example.com:8388#SS2022"
    t_run 0 parse_link "$ss2022"
    t_assert 'SS2022 密钥保留' jq -e --arg key "$key" '.outbound.password==$key and .outbound.method=="2022-blake3-aes-256-gcm"' "$CASE_TMP/output"

    t_run 0 parse_link 'anytls://anytls-secret@example.com:443?sni=example.com&insecure=1&pcs=&vcn=&unknown-empty=#AnyTLS'
    t_assert 'AnyTLS TLS 映射且空字段忽略' jq -e '.outbound.type=="anytls" and .outbound.tls.enabled and .outbound.tls.insecure' "$CASE_TMP/output"
    t_run 0 sbd_apply sbd_outbound_add "$(jq -c '.outbound + {tag:.tag}' "$CASE_TMP/output")"
    t_run 0 sbd_check_config

    t_run 0 parse_link "anytls://anytls-secret@example.com:443?security=reality&sni=www.example.com&fp=chrome&pbk=$REALITY_PBK&sid=ab12#AnyReality"
    t_assert 'AnyTLS Reality 映射' jq -e '.outbound.type=="anytls" and .outbound.tls.reality.enabled and .outbound.tls.utls.fingerprint=="chrome"' "$CASE_TMP/output"
    t_run 0 sbd_apply sbd_outbound_add "$(jq -c '.outbound + {tag:.tag}' "$CASE_TMP/output")"
    t_run 0 sbd_check_config
    t_assert 'Shadowsocks/AnyTLS 出口均进入配置' jq -e '
        ([.outbounds[].tag] | index("SS") != null) and
        ([.outbounds[].tag] | index("AnyTLS") != null) and
        ([.outbounds[].tag] | index("AnyReality") != null)
    ' "$SBD_CONFIG"
}

socks_contract() {
    t_seed
    t_run 0 parse_link 'socks5://alice%40corp:p%40ss%3Aword@example.com:1080#SOCKS-Auth'
    t_assert 'SOCKS5 认证映射' jq -e '
        .outbound | .type=="socks" and .version=="5" and
        .server=="example.com" and .server_port==1080 and
        .username=="alice@corp" and .password=="p@ss:word"
    ' "$CASE_TMP/output"
    t_run 0 sbd_apply sbd_outbound_add "$(jq -c '.outbound + {tag:.tag}' "$CASE_TMP/output")"
    t_run 0 sbd_check_config

    t_run 0 parse_link 'socks://example.com:1080#SOCKS-NoAuth'
    t_assert 'SOCKS 无认证映射' jq -e '
        .outbound | .type=="socks" and .version=="5" and
        (has("username") | not) and
        (has("password") | not)
    ' "$CASE_TMP/output"
    t_run 0 sbd_apply sbd_outbound_add "$(jq -c '.outbound + {tag:.tag}' "$CASE_TMP/output")"
    t_run 0 sbd_check_config
    t_assert 'SOCKS 出口进入配置' jq -e '
        ([.outbounds[].tag] | index("SOCKS-Auth") != null) and
        ([.outbounds[].tag] | index("SOCKS-NoAuth") != null)
    ' "$SBD_CONFIG"
}

dispatch_contract() {
    t_fresh
    t_run 2 sbd_dispatch 6 < /dev/null
    t_contains "$CASE_TMP/output" '分享链接:'
}

t_case 'Hysteria2 示例解析、默认 tag 与真实配置检查' hy2_example_contract
t_case '默认/自定义 tag、重复 tag 不改配置' tag_prompt_contract
t_case 'tag 扫描兼容字符串 DNS 条目' tag_scan_contract
t_case '不支持参数和协议显式拒绝且不落盘' reject_contract
t_case 'VLESS Reality 映射与真实配置检查' vless_contract
t_case 'VMess Base64 与 URL 形式映射' vmess_contract
t_case 'Hysteria2 Gecko 自定义包长导入' gecko_contract
t_case 'Shadowsocks/AnyTLS 映射与真实配置检查' ss_anytls_contract
t_case 'SOCKS/SOCKS5 映射与真实配置检查' socks_contract
t_case '主菜单 [6] 直达添加出口' dispatch_contract
t_finish
