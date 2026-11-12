#!/usr/bin/env bash
# shellcheck disable=SC2016
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

REALITY_PBK=ys6cWdAtS7dUtjHnUoJCBJ130tl_Z0v0q2thrXW9k14
HY2_LINK='hysteria2://demo-secret@hy2.example.com:10010?sni=hy2.example.com&mport=10011-10080#NL-Hy2'

parse_link() {
    printf '%s\n' "$1" | python3 "$ROOT/support/outbound_link.py"
}

parse_links() {
    printf '%s\n' "$@" | python3 "$ROOT/support/outbound_link.py" --batch
}

add_outbound() {
    local link="$1" tag="$2" answer="${3:-n}"
    t_run 0 sbd_outbound_add_prompt <<< "$link"$'\n'"$tag"$'\ny\n'"$answer"$'\n'
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

    t_run 1 sbd_outbound_add_prompt <<< 'ss://YWVzLTI1Ni1nY206cGFzcw==@example.com:8388?plugin=v2ray-plugin%3Bmode%3Dwebsocket#SS-Plugin'$'\n'
    t_contains "$CASE_TMP/output" 'Shadowsocks 插件链接暂不支持'
    t_unchanged
}

vless_contract() {
    t_seed
    local link
    link="vless://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?encryption=none&security=reality&sni=www.example.com&fp=chrome&pbk=$REALITY_PBK&sid=ab12&flow=xtls-rprx-vision&type=tcp&spx=%2F&pqv=1#VLESS-R"
    t_run 0 parse_link "$link"
    t_assert 'VLESS Reality 映射' jq -e '
        (.tag=="VLESS-R") and (.outbound |
        .type=="vless" and .uuid=="899954a1-86c4-4db7-b7a3-8b6f196a890e" and
        .flow=="xtls-rprx-vision" and .tls.reality.public_key=="'"$REALITY_PBK"'" and
        .tls.reality.short_id=="ab12" and .tls.utls.fingerprint=="chrome" and
        (has("transport")|not) and
        (has("spx")|not) and (has("pqv")|not))
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

base64_batch_contract() {
    t_seed
    local links blob b1 b2 final
    final=$(jq -r '.route.final' "$SBD_CONFIG") || exit 1
    links=$(printf '%s\n' \
        "$HY2_LINK" \
        'anytls://anytls-secret@any.example.com:443?security=none&type=tcp&headerType=none#AnyTLS-v2rayN' \
        'socks://YWxpY2U6c2VjcmV0@example.com:1080#SOCKS-B64') || exit 1
    blob=$(printf '%s\n' "$links" | openssl base64 -A) || exit 1
    t_run 0 sbd_outbound_add_prompt <<< "$blob"$'\n\n\n\ny\n'
    t_contains "$CASE_TMP/output" '共识别 3 个出口'
    t_contains "$CASE_TMP/output" '已添加 3 个出口'
    t_assert 'Base64 批量出口全部写入' jq -e '
        ([.outbounds[].tag] | index("NL-Hy2") != null) and
        ([.outbounds[].tag] | index("AnyTLS-v2rayN") != null) and
        ([.outbounds[].tag] | index("SOCKS-B64") != null)
    ' "$SBD_CONFIG"
    t_assert '批量添加不改默认路由' test "$(jq -r '.route.final' "$SBD_CONFIG")" = "$final"

    b1=$(printf '%s' 'socks://example.com:1080#B64-First' | openssl base64 -A) || exit 1
    b2=$(printf '%s' 'socks://example.com:1081#B64-Second' | openssl base64 -A) || exit 1
    t_run 0 sbd_outbound_add_prompt <<< "$b1"$'\n'"$b2"$'\n\n\ny\n'
    t_contains "$CASE_TMP/output" '共识别 2 个出口'
    t_assert '两行纯 Base64 链接全部写入' jq -e '
        ([.outbounds[].tag] | index("B64-First") != null) and
        ([.outbounds[].tag] | index("B64-Second") != null)
    ' "$SBD_CONFIG"
    t_assert '多行 Base64 不改默认路由' test "$(jq -r '.route.final' "$SBD_CONFIG")" = "$final"
    t_run 0 sbd_check_config
}

plain_batch_contract() {
    t_seed
    local first second delayed_first delayed_second final
    local concat_first concat_second concat_third
    first='hysteria2://one@hy2.example.com:443?sni=hy2.example.com#First'
    second='anytls://two@any.example.com:443#Second'
    final=$(jq -r '.route.final' "$SBD_CONFIG") || exit 1
    t_run 0 sbd_outbound_add_prompt <<< "$first"$'\r\n'"$second"$'\r\n\r\n\r\ny\r\n'
    t_contains "$CASE_TMP/output" '共识别 2 个出口'
    t_contains "$CASE_TMP/output" '已添加 2 个出口'
    t_absent "$CASE_TMP/output" '继续粘贴分享链接'
    t_assert '普通多行链接全部写入' jq -e '
        ([.outbounds[].tag] | index("First") != null) and
        ([.outbounds[].tag] | index("Second") != null)
    ' "$SBD_CONFIG"
    t_assert '普通多行链接不改默认路由' test "$(jq -r '.route.final' "$SBD_CONFIG")" = "$final"

    delayed_first='hysteria2://one@hy2.example.com:443?sni=hy2.example.com#Delayed-First'
    delayed_second='anytls://two@any.example.com:443#Delayed-Second'
    t_run 0 sbd_outbound_add_prompt < <(
        printf '%s\n' "$delayed_first"
        sleep 0.4
        printf '%s\n' "$delayed_second"
        printf '\n\ny\n'
    )
    t_contains "$CASE_TMP/output" '共识别 2 个出口'
    t_contains "$CASE_TMP/output" '已添加 2 个出口'
    t_assert '延迟到达的多行链接全部写入' jq -e '
        ([.outbounds[].tag] | index("Delayed-First") != null) and
        ([.outbounds[].tag] | index("Delayed-Second") != null)
    ' "$SBD_CONFIG"
    t_assert '延迟批量添加不改默认路由' test "$(jq -r '.route.final' "$SBD_CONFIG")" = "$final"

    concat_first='hysteria2://one@hy2.example.com:443?sni=hy2.example.com#Concatenated-First'
    concat_second='vmess://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?type=ws&security=tls&sni=cdn.example.com&host=cdn.example.com&path=%2Fws&scy=auto#Concatenated-VMess'
    concat_third='vless://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?encryption=none&security=tls&sni=example.com#Concatenated-VLESS'
    t_run 0 sbd_outbound_add_prompt <<< "$concat_first$concat_second$concat_third"$'\n\n\n\ny\n'
    t_contains "$CASE_TMP/output" '共识别 3 个出口'
    t_contains "$CASE_TMP/output" '已添加 3 个出口'
    t_assert '协议头连续拼接时全部写入' jq -e '
        ([.outbounds[].tag] | index("Concatenated-First") != null) and
        ([.outbounds[].tag] | index("Concatenated-VMess") != null) and
        ([.outbounds[].tag] | index("Concatenated-VLESS") != null)
    ' "$SBD_CONFIG"
    t_assert '连续拼接不改默认路由' test "$(jq -r '.route.final' "$SBD_CONFIG")" = "$final"
    t_run 0 sbd_check_config
}

batch_skip_invalid_contract() {
    t_seed
    local first bad second malformed_first malformed_second final
    first='hysteria2://one@hy2.example.com:443?sni=hy2.example.com#Batch-First'
    bad='tuic://secret@example.com:443#Batch-Bad'
    second='anytls://two@any.example.com:443#Batch-Second'
    final=$(jq -r '.route.final' "$SBD_CONFIG") || exit 1
    t_run 0 sbd_outbound_add_prompt <<< "$first"$'\n'"$bad"$'\n'"$second"$'\n\n\ny\n'
    t_contains "$CASE_TMP/output" '已跳过第 2 条'
    t_contains "$CASE_TMP/output" '共识别 2 个出口'
    t_contains "$CASE_TMP/output" '已添加 2 个出口'
    t_assert '批量失败项被跳过，成功项全部写入' jq -e '
        ([.outbounds[].tag] | index("Batch-First") != null) and
        ([.outbounds[].tag] | index("Batch-Second") != null) and
        ([.outbounds[].tag] | index("Batch-Bad") == null)
    ' "$SBD_CONFIG"
    t_assert '跳过失败项不改默认路由' test "$(jq -r '.route.final' "$SBD_CONFIG")" = "$final"

    malformed_first='hysteria2://one@hy2.example.com:443?sni=hy2.example.com#Malformed-First'
    malformed_second='anytls://two@any.example.com:443#Malformed-Second'
    t_run 0 sbd_outbound_add_prompt <<< "$malformed_first"$'\n''vmess://W10='$'\n'"$malformed_second"$'\n\n\ny\n'
    t_contains "$CASE_TMP/output" '已跳过第 2 条'
    t_assert '坏 VMess 不阻断后续条目' jq -e '
        ([.outbounds[].tag] | index("Malformed-First") != null) and
        ([.outbounds[].tag] | index("Malformed-Second") != null)
    ' "$SBD_CONFIG"
    t_assert '坏 VMess 批量不改默认路由' test "$(jq -r '.route.final' "$SBD_CONFIG")" = "$final"
    t_run 0 sbd_check_config
}

control_character_contract() {
    t_seed
    t_run 1 sbd_outbound_add_prompt <<< 'ss://YmFkG1szMW06c2VjcmV0QGV4YW1wbGUuY29tOjgzODg=#x'$'\n'
    t_contains "$CASE_TMP/output" '\x1b'
    t_absent "$CASE_TMP/output" $'\x1b'
    t_unchanged
}

separator_batch_contract() {
    t_seed
    local hy2 anytls vless vmess socks ss hy2_second all
    hy2='hysteria2://one@hy2.example.com:443?sni=hy2.example.com#Sep-Hy2'
    anytls='anytls://two@any.example.com:443#Sep-AnyTLS'
    vless='vless://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?encryption=none&security=tls&sni=example.com#Sep-VLESS'
    vmess='vmess://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?type=ws&security=tls&sni=cdn.example.com&host=cdn.example.com&path=%2Fws&scy=auto#Sep-VMess'
    socks='socks://example.com:1080#Sep-SOCKS'
    ss='ss://YWVzLTI1Ni1nY206cGFzcw==@example.com:8388#Sep-SS'
    hy2_second='hysteria2://three@hy2.example.com:443?sni=hy2.example.com#Sep-Hy2-2'
    all="$hy2 $anytls"$'\n'"$vless,$vmess;$socks，$ss；$hy2_second"
    t_run 0 parse_links "$all"
    t_assert '空格/换行/中英文逗号分号均可分隔链接' jq -e '
        length == 7 and
        (map(.tag) == [
            "Sep-Hy2", "Sep-AnyTLS", "Sep-VLESS", "Sep-VMess",
            "Sep-SOCKS", "Sep-SS", "Sep-Hy2-2"
        ])
    ' "$CASE_TMP/output"
}

chinese_tag_contract() {
    t_seed
    local json payload link
    json=$(jq -cn '{
        v:"2",ps:"新加坡-优化2-GPT",add:"m.cnmjin.net",port:"16618",
        id:"899954a1-86c4-4db7-b7a3-8b6f196a890e",aid:"0",scy:"auto",
        net:"ws",type:"none",host:"x.mobgslb.tbcache.com",path:"/",
        tls:"",sni:"",alpn:"",fp:"",insecure:"0",vcn:"",pcs:""
    }') || exit 1
    payload=$(printf '%s' "$json" | openssl base64 -A) || exit 1
    link="vmess://$payload"
    t_run 0 parse_link "$link"
    t_assert 'VMess JSON ps 作为默认 tag' jq -e '.tag=="新加坡-优化2-GPT"' "$CASE_TMP/output"
    t_run 0 sbd_outbound_add_prompt <<< "$link"$'\n\ny\n'
    t_contains "$CASE_TMP/output" '默认 新加坡-优化2-GPT'
    t_assert '中文 tag 写入配置' jq -e '.outbounds[-1].tag=="新加坡-优化2-GPT"' "$SBD_CONFIG"
    t_run 0 sbd_check_config
}

base64_non_vmess_contract() {
    t_seed
    local blob
    blob=$(printf '%s\n' "$HY2_LINK" | openssl base64 -A) || exit 1
    t_run 0 parse_links "$blob"
    t_assert '非 VMess 整串 Base64 可解析' jq -e '
        .[0].tag=="NL-Hy2" and .[0].outbound.type=="hysteria2"
    ' "$CASE_TMP/output"

    blob=$(printf '%s\n' 'trojan://secret@example.com:443#Trojan' | openssl base64 -A) || exit 1
    t_run 1 sbd_outbound_add_prompt <<< "$blob"$'\n'
    t_contains "$CASE_TMP/output" '暂不支持 trojan://'
    t_unchanged
}

v2rayn_formats_contract() {
    t_seed
    local body vless_hu vmess_hu
    t_run 0 parse_link 'socks://YWxpY2U6c2VjcmV0@example.com:1080#SOCKS-B64'
    t_assert 'v2rayN SOCKS Base64 认证' jq -e '
        .outbound.type=="socks" and .outbound.username=="alice" and
        .outbound.password=="secret"
    ' "$CASE_TMP/output"

    body=$(printf '%s' 'bob:pass@example.com:1080' | openssl base64 -A) || exit 1
    t_run 0 parse_link "socks://$body#SOCKS-Legacy"
    t_assert '旧式 SOCKS 整串 Base64' jq -e '
        .outbound.username=="bob" and .outbound.password=="pass"
    ' "$CASE_TMP/output"

    t_run 0 parse_link 'anytls://anytls-secret@any.example.com:443?security=none&type=tcp&headerType=none#AnyTLS-v2rayN'
    t_assert 'v2rayN AnyTLS 默认参数兼容' jq -e '
        .outbound.type=="anytls" and .outbound.tls.enabled and
        .outbound.tls.server_name=="any.example.com"
    ' "$CASE_TMP/output"

    t_run 0 parse_link 'hysteria2://secret@hy2.example.com?sni=hy2.example.com#Hy2-NoPort'
    t_assert 'Hysteria2 缺省端口 443' jq -e '.outbound.server_port==443' "$CASE_TMP/output"

    vless_hu='vless://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?encryption=none&security=tls&sni=example.com&type=httpupgrade&host=cdn.example.com&path=%2Fup#VLESS-HU'
    t_run 0 parse_link "$vless_hu"
    t_assert 'VLESS HTTPUpgrade 映射' jq -e '
        .outbound.transport.type=="httpupgrade" and
        .outbound.transport.host=="cdn.example.com" and
        .outbound.transport.path=="/up"
    ' "$CASE_TMP/output"

    vmess_hu='vmess://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?type=httpupgrade&security=tls&sni=cdn.example.com&host=cdn.example.com&path=%2Fup&scy=auto#VMess-HU'
    t_run 0 parse_link "$vmess_hu"
    t_assert 'VMess HTTPUpgrade 映射' jq -e '
        .outbound.transport.type=="httpupgrade" and
        .outbound.tls.server_name=="cdn.example.com"
    ' "$CASE_TMP/output"
    t_run 0 sbd_apply sbd_outbound_add "$(jq -c '.outbound + {tag:.tag}' "$CASE_TMP/output")"
    t_run 0 sbd_check_config
    t_assert 'HTTPUpgrade 出口进入配置' jq -e '
        .outbounds[-1].tag=="VMess-HU" and
        .outbounds[-1].transport.type=="httpupgrade"
    ' "$SBD_CONFIG"

    t_run 0 parse_link 'vless://899954a1-86c4-4db7-b7a3-8b6f196a890e@example.com:443?encryption=none&security=tls&sni=example.com&type=h2&host=cdn.example.com&path=%2Fh2#VLESS-H2'
    t_assert 'VLESS HTTP/2 映射' jq -e '
        .outbound.transport.type=="http" and
        .outbound.transport.host=="cdn.example.com" and
        .outbound.transport.path=="/h2"
    ' "$CASE_TMP/output"
    t_run 0 sbd_apply sbd_outbound_add "$(jq -c '.outbound + {tag:.tag}' "$CASE_TMP/output")"
    t_run 0 sbd_check_config
    t_assert 'HTTP/2 出口进入配置' jq -e '
        .outbounds[-1].tag=="VLESS-H2" and
        .outbounds[-1].transport.type=="http"
    ' "$SBD_CONFIG"
}

batch_tag_conflict_contract() {
    t_seed
    local first second
    t_run 1 sbd_apply sbd_outbound_add_many '[
        {"type":"socks","tag":"Dup","server":"a.example.com","server_port":1},
        {"type":"socks","tag":"Dup","server":"b.example.com","server_port":2}
    ]'
    t_contains "$CASE_TMP/output" '候选出口请求无效或 tag 重复'
    t_unchanged

    t_run 1 sbd_apply sbd_outbound_add_many '[
        {"type":"socks","tag":"bad/tag","server":"a.example.com","server_port":1}
    ]'
    t_contains "$CASE_TMP/output" "出口 tag 不能包含 / 或 \\"
    t_unchanged

    first='hysteria2://one@hy2.example.com:443?sni=hy2.example.com#Same'
    second='anytls://two@any.example.com:443#Same'
    t_run 0 sbd_outbound_add_prompt <<< "$first"$'\n'"$second"$'\n\n\nSecond\ny\n'
    t_contains "$CASE_TMP/output" '本次添加的出口 tag 重复: Same'
    t_contains "$CASE_TMP/output" '已添加 2 个出口'
    t_assert '批量 tag 重复后可用自定义 tag 继续' jq -e '
        ([.outbounds[].tag] | index("Same") != null) and
        ([.outbounds[].tag] | index("Second") != null)
    ' "$SBD_CONFIG"
}

idn_contract() {
    t_seed
    t_run 0 parse_link 'vless://11111111-1111-1111-1111-111111111111@例え.测试:443?encryption=none&security=tls#IDN'
    t_assert '国际化域名按 punycode 落地' jq -e '.outbound.server=="xn--r8jz45g.xn--0zwm56d" and .outbound.tls.server_name=="xn--r8jz45g.xn--0zwm56d"' "$CASE_TMP/output"
    t_run 0 parse_link 'vless://11111111-1111-1111-1111-111111111111@Example.COM:443?encryption=none&security=tls'
    t_assert 'ASCII 主机保持原样' jq -e '.outbound.server=="example.com"' "$CASE_TMP/output"
    t_run 1 parse_link 'vless://11111111-1111-1111-1111-111111111111@faß.de:443?encryption=none&security=tls'
    t_contains "$CASE_TMP/output" 'punycode'
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
t_case '整串 Base64 批量添加且不改默认路由' base64_batch_contract
t_case '普通/延迟/连续拼接链接一次粘贴批量添加' plain_batch_contract
t_case '批量解析跳过失败项并添加成功项' batch_skip_invalid_contract
t_case '控制字符不回显到终端' control_character_contract
t_case '空格/换行/中英文逗号分号分隔批量解析' separator_batch_contract
t_case 'VMess ps 中文默认 tag' chinese_tag_contract
t_case '非 VMess 整串 Base64 与不支持协议拒绝' base64_non_vmess_contract
t_case 'v2rayN 导出格式兼容补充' v2rayn_formats_contract
t_case '批量内 tag 重复可重新命名，候选重复整批拒绝' batch_tag_conflict_contract
t_case '国际化域名 punycode 落地与不可无损转换的拒绝' idn_contract
t_finish
