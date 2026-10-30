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
    t_run 0 sbd_entry_create_prompt <<< $'2\n127.0.0.1\n019501\nexample.com\n029501\n菜单节点\nfixture-password\n3\nnode.example.com\n2\ny'
    t_absent "$CASE_TMP/output" fixture-password
    t_contains "$CASE_TMP/output" '未验证 NAT'
    t_assert '菜单真实创建并使用不同映射端口' jq -e '.nodes[0]|.name=="菜单节点" and .client.server_port==29501' "$SBD_REGISTRY"
    t_run 0 sbd_entries_list
    t_absent "$CASE_TMP/output" fixture-password
}
t_case '节点菜单退出与必填 EOF 无副作用' menu_cancel
t_case '节点字段重问、十进制与秘密随机输入' field_contract
t_case 'AnyTLS 真实配置与 URI 编码' anytls_contract
t_case 'AnyReality 真实密钥与原生客户端/服务端' reality_contract
t_case 'Hysteria2 默认 BBR 和证书指纹 URI' hy2_default
t_case 'Hysteria2 两侧带宽与 Gecko 自定义 URI 扩展' hy2_custom
t_case 'Hysteria2 Salamander 特殊密码回读' hy2_salamander
t_case '完整编号菜单真实创建和凭据不回显' create_prompt_contract
t_finish
