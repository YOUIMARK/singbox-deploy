#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/entries.sh"

menu_cancel() {
    t_fresh
    t_run 0 sbd_entries_menu <<< 0
    t_run 0 sbd_entries_menu < /dev/null
    t_run 2 sbd_entry_create_prompt <<< $'2\n\n19501\nexample.com'
    t_assert '创建字段 EOF 不创建配置' test ! -e "$SBD_CONFIG"
    t_assert '创建字段 EOF 不生成材料' test ! -e "$SBD_DATA/certificates"
}
field_contract() {
    t_fresh
    sbd_entry_number_prompt 端口 1 65535 443 > "$CASE_TMP/prompt" 2>&1 <<< $'bad\n00080' || exit 1
    t_assert '端口错误只重问当前字段' test "$SBD_REPLY" = 80
    sbd_entry_host_prompt 地址 > "$CASE_TMP/prompt" 2>&1 <<< $'bad/path\n2001:db8::1' || exit 1
    t_assert 'IPv6 地址保留' test "$SBD_REPLY" = 2001:db8::1
    sbd_entry_listen_prompt > "$CASE_TMP/prompt" 2>&1 <<< $'example.com\n127.0.0.1' || exit 1
    t_assert '监听字段只接受 IP' test "$SBD_REPLY" = 127.0.0.1
    sbd_entry_password_prompt 密码 > "$CASE_TMP/prompt" 2>&1 <<< 'fixture-secret' || exit 1
    t_assert '密码不丢字节' test "$SBD_REPLY" = fixture-secret
    t_absent "$CASE_TMP/prompt" fixture-secret
    sbd_entry_password_prompt 密码 > "$CASE_TMP/prompt" 2>&1 <<< '' || exit 1
    t_assert '显式空行生成随机密码' test "${#SBD_REPLY}" = 32
    t_run 2 sbd_entry_password_prompt 密码 < /dev/null
    sbd_entry_choose '[{"id":"node.first","name":"同名"},{"id":"node.second","name":"同名"}]' 选择 > "$CASE_TMP/prompt" 2>&1 <<< 2 || exit 1
    t_assert '同名节点按稳定 ID 选择' test "$SBD_REPLY" = node.second
    t_contains "$CASE_TMP/prompt" node.first
    t_contains "$CASE_TMP/prompt" node.second
}
anytls_contract() {
    t_seed
    t_entry_add anytls
    t_run 0 sbd_check_config
    t_assert '原生 AnyTLS 且未写 padding 优化模板' jq -e '.inbounds[0]|.type=="anytls" and (has("padding_scheme")|not)' "$SBD_CONFIG"
    t_assert 'ID 不依赖名称和端口' test "$NODE_ID" != anytls-19501
    t_run 0 t_entry_uri anytls
}
reality_contract() {
    t_seed
    t_entry_add anyreality
    t_assert 'AnyReality 仍为原生 AnyTLS' jq -e '.inbounds[0]|.type=="anytls" and .tls.reality.enabled and (.users[0]|has("uuid") or has("flow")|not)' "$SBD_CONFIG"
    t_assert 'uTLS 只在客户端' jq -e 'all(.inbounds[]; (.tls|has("utls")|not))' "$SBD_CONFIG"
    t_assert '客户端为显式 chrome，不含私钥' jq -e '.nodes[0].client | .tls.utls.fingerprint=="chrome" and (.tls.reality|has("private_key")|not) and (has("uuid")|not) and (has("flow")|not)' "$SBD_REGISTRY"
    t_run 0 t_entry_uri anyreality
}
hy2_default() {
    t_seed
    t_entry_add hysteria2
    t_assert '服务端默认不强制客户端策略' jq -e '.inbounds[0]|(has("up_mbps") or has("down_mbps") or has("ignore_client_bandwidth") or has("obfs"))|not' "$SBD_CONFIG"
    t_assert '客户端 BBR 不写带宽字段' jq -e '.nodes[0].client | (has("up_mbps") or has("down_mbps"))|not' "$SBD_REGISTRY"
    t_run 0 t_entry_uri hysteria2
}
hy2_custom() {
    t_seed
    local spec
    spec=$(jq '.server_options={up_mbps:25,down_mbps:5} | .client_options={up_mbps:3,down_mbps:12} | .obfs={type:"gecko",password:"obfs@:/?# &+",min_packet_size:600,max_packet_size:1300}' "$ROOT/tests/fixtures/entry-hysteria2.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    NODE_ID=$(jq -r '.nodes[0].id' "$SBD_REGISTRY")
    t_assert '服务端方向独立' jq -e '.inbounds[0]|.up_mbps==25 and .down_mbps==5' "$SBD_CONFIG"
    t_assert '客户端方向独立' jq -e '.nodes[0].client|.up_mbps==3 and .down_mbps==12 and .obfs.min_packet_size==600 and .obfs.max_packet_size==1300' "$SBD_REGISTRY"
    t_run 0 t_entry_uri hysteria2
}
hy2_salamander() {
    t_seed
    local spec
    spec=$(jq '.obfs={type:"salamander",password:"obfs@:/?# &+"}' "$ROOT/tests/fixtures/entry-hysteria2.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    NODE_ID=$(jq -r '.nodes[0].id' "$SBD_REGISTRY")
    t_run 0 t_entry_uri hysteria2
}
create_prompt_contract() {
    t_seed
    t_run 0 sbd_entry_create_prompt <<< $'2\n127.0.0.1\n019501\nexample.com\n菜单节点\nfixture-password\n3\nnode.example.com\n2\ny'
    t_contains "$CASE_TMP/output" "[成功] 节点与客户端资料已提交: $SBD_EXPORTS"
    t_contains "$CASE_TMP/output" '分享链接: anytls://'
    t_absent "$CASE_TMP/output" '当前节点链接'
    t_absent "$CASE_TMP/output" '未验证 NAT'
    t_absent "$CASE_TMP/output" '客户端映射端口'
    t_assert '菜单真实创建且客户端初始端口沿用监听端口' jq -e '.nodes[0]|.name=="菜单节点" and .client.server_port==19501' "$SBD_REGISTRY"
    t_run 0 sbd_entries_list
    t_absent "$CASE_TMP/output" fixture-password
}
action_contract() {
    t_fresh
    local profile
    for profile in shadowsocks vmess_ws vless_ws vless_reality hysteria2 anytls anyreality; do
        t_run 0 sbd_entry_actions "$profile"
        t_contains "$CASE_TMP/output" '[7] 删除节点'
        case "$profile" in
            shadowsocks) t_contains "$CASE_TMP/output" '[8] Shadowsocks'; t_absent "$CASE_TMP/output" '[5]'; t_absent "$CASE_TMP/output" '[6]'; t_absent "$CASE_TMP/output" '[9]' ;;
            vmess_ws|vless_ws) t_contains "$CASE_TMP/output" '[9] WS CDN'; t_absent "$CASE_TMP/output" '[5]'; t_absent "$CASE_TMP/output" '[6]'; t_absent "$CASE_TMP/output" '[8]' ;;
            hysteria2) t_contains "$CASE_TMP/output" '[5] Hysteria2'; t_contains "$CASE_TMP/output" '[6]'; t_absent "$CASE_TMP/output" '[8]'; t_absent "$CASE_TMP/output" '[9]' ;;
            anytls) t_contains "$CASE_TMP/output" '[6] 切换 TLS'; t_absent "$CASE_TMP/output" Reality; t_absent "$CASE_TMP/output" '[5]' ;;
            *) t_contains "$CASE_TMP/output" '[6] 重建 Reality'; t_absent "$CASE_TMP/output" '[5]'; t_absent "$CASE_TMP/output" '[8]'; t_absent "$CASE_TMP/output" '[9]' ;;
        esac
    done
    t_run 1 sbd_entry_actions unknown
    for profile in shadowsocks vmess_ws vless_ws vless_reality hysteria2 anytls anyreality; do
        t_run 0 sbd_entry_actions "$profile" edit
        t_absent "$CASE_TMP/output" '[7]'
        t_assert '修改菜单不接受隐藏删除编号' test "${SBD_ENTRY_ACTIONS/ 7 /}" = "$SBD_ENTRY_ACTIONS"
    done
    t_run 1 sbd_entry_change_prompt unknown
}
hidden_action_retry() {
    t_seed
    t_entry_add shadowsocks
    t_run 0 sbd_entry_change_prompt <<< $'1\n6\n1\n重问后新名称\ny'
    t_contains "$CASE_TMP/output" '选择显示的编号'
    t_absent "$CASE_TMP/output" '[6]'
    t_assert '无效隐藏编号只重问操作，不丢节点选择' jq -e '.nodes[0].name=="重问后新名称"' "$SBD_REGISTRY"
}
post_commit_contract() {
    t_seed
    t_run 0 sbd_entry_create_prompt <<< $'2\n127.0.0.1\n19501\nexample.com\n交付节点\nfixture-password\n3\nnode.example.com\n2\ny'
    t_contains "$CASE_TMP/output" "分享链接: $(cat "$SBD_EXPORTS/$SBD_NEW_ENTRY_ID.txt")"
    t_absent "$CASE_TMP/output" '当前节点链接'
    t_run 0 sbd_export_node "$SBD_NEW_ENTRY_ID" json
    t_contains "$CASE_TMP/output" "客户端 JSON: $SBD_EXPORTS/"
    t_absent "$CASE_TMP/output" fixture-password
    t_assert '已提交节点的准确 ID 贯穿资料交付' test "$SBD_NEW_ENTRY_ID" = "$(jq -r '.nodes[0].id' "$SBD_REGISTRY")"
    t_run 0 sbd_export_node_menu "$SBD_NEW_ENTRY_ID" < /dev/null
    t_contains "$CASE_TMP/output" '已提交的节点不受影响'
    t_assert '结束资料查看不会创建第二次修订' jq -e '.revision==1' "$SBD_STATE"
}
empty_list_contract() {
    t_fresh
    t_run 0 sbd_dispatch 2
    t_contains "$CASE_TMP/output" '暂无节点，请先添加节点'
    printf '{"format":1}\n' > "$SBD_REGISTRY" || exit 1
    t_run 1 sbd_dispatch 2
    t_contains "$CASE_TMP/output" '读取节点列表失败'
    t_absent "$CASE_TMP/output" '暂无节点'
    printf '{bad' > "$SBD_REGISTRY" || exit 1
    t_run 1 sbd_dispatch 2
    t_contains "$CASE_TMP/output" '读取节点列表失败'
    t_absent "$CASE_TMP/output" '[成功]'
}
t_case '节点菜单退出与必填 EOF 无副作用' menu_cancel
t_case '节点字段重问、十进制与秘密随机输入' field_contract
t_case 'AnyTLS 真实配置与 URI 编码' anytls_contract
t_case 'AnyReality 真实密钥与原生客户端/服务端' reality_contract
t_case 'Hysteria2 默认 BBR 和证书指纹 URI' hy2_default
t_case 'Hysteria2 两侧带宽与 Gecko 自定义 URI 扩展' hy2_custom
t_case 'Hysteria2 Salamander 特殊密码回读' hy2_salamander
t_case '精简向导真实创建、自动分享和列表隐藏凭据' create_prompt_contract
t_case '七档操作菜单只显示适用项且保持原有编号' action_contract
t_case '隐藏操作编号错误只重问操作字段' hidden_action_retry
t_case '创建后自动分享、可另查 JSON、稳定 ID 和 EOF 语义' post_commit_contract
t_case '首页空列表明确提示、坏登记不冒充没有节点' empty_list_contract
t_finish
