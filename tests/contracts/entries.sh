#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/entries.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/classic.sh"

field_contract() {
    local generated
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
    sbd_entry_uuid_prompt > "$CASE_TMP/prompt" 2>&1 <<< '' || exit 1
    generated="$SBD_REPLY"
    t_assert '显式空行生成合法 UUID' test "$generated" = "$(sbd_entry_uuid <<< "$generated")"
    t_contains "$CASE_TMP/prompt" '随机 UUID:'
    sbd_entry_choose '[{"id":"node.first","name":"同名"},{"id":"node.second","name":"同名"}]' 选择 > "$CASE_TMP/prompt" 2>&1 <<< 2 || exit 1
    t_assert '同名节点按稳定 ID 选择' test "$SBD_REPLY" = node.second
    t_contains "$CASE_TMP/prompt" node.first
    t_contains "$CASE_TMP/prompt" node.second
    ports_json=$(sbd_entry_hy2_ports '11，13、15-17；3050' | jq -c .) || exit 1
    t_assert '端口范围兼容中文逗号/顿号/分号' test "$ports_json" = '["11:11","13:13","15:17","3050:3050"]'
    ports_json=$(sbd_entry_hy2_ports '3050, 3051' | jq -c .) || exit 1
    t_assert '端口范围容忍逗号后空格' test "$ports_json" = '["3050:3050","3051:3051"]'
    t_run 1 sbd_entry_hy2_ports '11 13'
    t_run 1 sbd_entry_hy2_ports '20000-20100-30000'
    t_run 1 sbd_entry_hy2_ports '0-65536'
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
hy2_management() {
    t_seed
    t_entry_add vmess_ws
    t_entry_add hysteria2
    local id tag
    id="$NODE_ID"
    tag=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.inbound_tag' "$SBD_REGISTRY")
    t_run 2 sbd_entry_change_prompt edit <<< $'2\n5\n1\nabc\n20000-20100\n30\ny\n0\n'
    t_absent "$CASE_TMP/output" '[5] Hysteria2 管理'
    t_contains "$CASE_TMP/output" 'Hysteria2 节点管理'
    t_contains "$CASE_TMP/output" '[5] 客户端端口跳跃'
    t_contains "$CASE_TMP/output" 'sing-box inbound 仍监听单端口'
    t_contains "$CASE_TMP/output" '端口范围格式'
    t_contains "$CASE_TMP/output" '端口范围须为 3050、20000-50000 或 11,13,15-17 这类组合'
    t_contains "$CASE_TMP/output" '[6] 客户端上/下行带宽'
    t_contains "$CASE_TMP/output" '[7] 服务端上/下行带宽'
    t_contains "$CASE_TMP/output" '[8] Salamander/Gecko 混淆'
    t_assert '编辑菜单配置客户端跳跃端口和间隔' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client|.server_ports==["20000:20100"] and .hop_interval=="30s"' "$SBD_REGISTRY"
    t_assert 'sing-box 原生客户端导出携带跳跃配置' jq -e '.outbounds[0]|.server_ports=="20000:20100" and .hop_interval=="30s"' "$SBD_EXPORTS/$id.json"
    t_run 0 t_entry_uri hysteria2
    t_run 0 t_classic_uri
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_client_bandwidth '{"up_mbps":8,"down_mbps":40}'
    t_assert '客户端带宽独立保存' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client|.up_mbps==8 and .down_mbps==40' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_client_bandwidth '{}'
    t_assert '切回 BBR 清除客户端带宽限制' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client|(has("up_mbps") or has("down_mbps"))|not' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_server_bandwidth '{"up_mbps":100,"down_mbps":25}'
    t_assert '服务端带宽写入 inbound' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.up_mbps==100 and .down_mbps==25' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_obfs '{"type":"salamander","password":"fixture-obfs"}'
    t_assert '服务端混淆已更新' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.obfs.type=="salamander"' "$SBD_CONFIG"
    t_assert '客户端混淆已同步更新' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client.obfs.password=="fixture-obfs"' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_obfs null
    t_assert '服务端混淆已清除' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|has("obfs")|not' "$SBD_CONFIG"
    t_assert '客户端混淆已清除' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client|has("obfs")|not' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_hops '{"server_ports":["20000:20100","3050:3050"],"hop_interval":"30s"}'
    t_assert '多段混合跳跃范围按序保存' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client|.server_ports==["20000:20100","3050:3050"]' "$SBD_REGISTRY"
    t_run 0 t_entry_uri hysteria2
    t_run 1 sbd_apply sbd_entry_change "$id" hy2_hops '{"server_ports":["20000:20100","bad"],"hop_interval":"30s"}'
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_hops '{"server_ports":[],"hop_interval":""}'
    t_assert '关闭端口跳跃清除导出和 URI 参数' jq -e --arg id "$id" '(.nodes[]|select(.id==$id)|.client|has("server_ports") or has("hop_interval"))|not' "$SBD_REGISTRY"
    t_run 0 t_entry_uri hysteria2
    t_run 1 sbd_apply sbd_entry_change "$id" hy2_hops '{"server_ports":["20100:20000"],"hop_interval":"30s"}'
    t_run 0 sbd_check_config
}
hy2_paired_bandwidth() {
    t_seed
    t_entry_add hysteria2
    local id tag node
    id="$NODE_ID"
    tag=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.inbound_tag' "$SBD_REGISTRY") || exit 1
    t_patch_config --arg tag "$tag" '(.inbounds[]|select(.tag==$tag)).ignore_client_bandwidth=true'
    node=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SBD_REGISTRY") || exit 1
    sbd_entry_hy2_manage_prompt "$node" 2 > "$CASE_TMP/prompt" 2>&1 <<< $'2\n8\n40\n100\n25' || exit 1
    t_assert '任一带宽菜单均进入成对管理' test "$SBD_HY2_ACTION" = hy2_bandwidth
    t_assert '分别录入两侧带宽值' jq -e '.client_options=={up_mbps:8,down_mbps:40} and .server_options=={up_mbps:100,down_mbps:25}' <<< "$SBD_HY2_REQUEST"
    t_entry_save
    t_run 1 sbd_apply sbd_entry_change "$id" hy2_server_bandwidth '{"up_mbps":100,"down_mbps":25}'
    t_contains "$CASE_TMP/output" '节点认证、TLS、混淆或带宽策略与元数据不一致'
    t_entry_unchanged
    t_run 1 sbd_apply sbd_entry_change "$id" hy2_bandwidth '{"client_options":{"up_mbps":8,"down_mbps":40},"server_options":{}}'
    t_contains "$CASE_TMP/output" '客户端与服务端带宽策略无效或不匹配'
    t_entry_unchanged
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_bandwidth '{"client_options":{"up_mbps":8,"down_mbps":40},"server_options":{"up_mbps":100,"down_mbps":25}}'
    t_assert '客户端带宽值独立保存' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client|.up_mbps==8 and .down_mbps==40' "$SBD_REGISTRY"
    t_assert '服务端带宽值独立保存' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.up_mbps==100 and .down_mbps==25' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_bandwidth '{"client_options":{},"server_options":{}}'
    t_assert 'BBR 模式清除客户端带宽' jq -e --arg id "$id" '[.nodes[]|select(.id==$id)|.client|(has("up_mbps") or has("down_mbps"))]|any|not' "$SBD_REGISTRY"
    t_assert '服务端带宽同步清除' jq -e --arg tag "$tag" '[.inbounds[]|select(.tag==$tag)|has("up_mbps") or has("down_mbps")]|any|not' "$SBD_CONFIG"
}
create_prompt_contract() {
    t_seed
    t_run 0 sbd_entry_create_prompt <<< $'2\n127.0.0.1\n019501\nexample.com\n菜单节点\nfixture-password\n3\nnode.example.com\n2\ny'
    t_contains "$CASE_TMP/output" '[1] Hysteria2'
    t_contains "$CASE_TMP/output" '[3] AnyReality'
    t_absent "$CASE_TMP/output" '（UDP）'
    t_absent "$CASE_TMP/output" '（TCP）'
    t_absent "$CASE_TMP/output" '（AnyTLS + Reality'
    t_contains "$CASE_TMP/output" "[成功] 节点与客户端资料已提交: $SBD_EXPORTS"
    t_contains "$CASE_TMP/output" '分享链接: anytls://'
    t_contains "$CASE_TMP/output" "分享链接: $(cat "$SBD_EXPORTS/$SBD_NEW_ENTRY_ID.txt")"
    t_absent "$CASE_TMP/output" '当前节点链接'
    t_absent "$CASE_TMP/output" '未验证 NAT'
    t_absent "$CASE_TMP/output" '客户端映射端口'
    t_assert '菜单真实创建且客户端初始端口沿用监听端口' jq -e '.nodes[0]|.name=="菜单节点" and .client.server_port==19501' "$SBD_REGISTRY"
    t_run 0 sbd_export_node "$SBD_NEW_ENTRY_ID" json
    t_contains "$CASE_TMP/output" "客户端 JSON: $SBD_EXPORTS/"
    t_absent "$CASE_TMP/output" fixture-password
    t_assert '已提交节点的准确 ID 贯穿资料交付' test "$SBD_NEW_ENTRY_ID" = "$(jq -r '.nodes[0].id' "$SBD_REGISTRY")"
    t_run 0 sbd_export_node_menu "$SBD_NEW_ENTRY_ID" < /dev/null
    t_contains "$CASE_TMP/output" '已提交的节点不受影响'
    t_assert '结束资料查看不会创建第二次修订' jq -e '.revision==1' "$SBD_STATE"
    t_run 0 sbd_entries_list
    t_absent "$CASE_TMP/output" fixture-password
}
custom_certificate_prompt_contract() {
    t_seed
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=custom.example.com \
        -addext subjectAltName=DNS:custom.example.com -keyout "$CASE_TMP/custom-key.pem" -out "$CASE_TMP/custom-cert.pem" >/dev/null 2>&1 || exit 1
    t_run 0 sbd_entry_create_prompt <<< $'2\n127.0.0.1\n019502\ncustom.example.com\n自定义证书节点\nfixture-password\n4\ncustom.example.com\n'"$CASE_TMP/custom-cert.pem"$'\n'"$CASE_TMP/custom-key.pem"$'\n1\ny'
    t_contains "$CASE_TMP/output" '[4] 自定义证书'
    t_assert '向导导入自定义证书并登记来源' jq -e '.tls.certificates|length==1 and .[0].kind=="import" and .[0].server_name=="custom.example.com"' "$SBD_REGISTRY"
    t_assert '导入证书与私钥位于受管副本' jq -e --arg root "$SBD_CERT_DIR" '.tls.certificates[0] as $cert | ($cert.certificate_path|startswith($root)) and ($cert.key_path|startswith($root))' "$SBD_REGISTRY"
    t_assert '客户端选择系统 CA 信任且节点来源已关联' jq -e '.nodes[0]|.tls_source.kind=="certificate" and .tls_source.trust=="system" and .certificate_id==.tls_source.id' "$SBD_REGISTRY"
    t_assert '手动申请的源文件保持不变' test -f "$CASE_TMP/custom-cert.pem" -a -f "$CASE_TMP/custom-key.pem"
    t_absent "$CASE_TMP/output" 'BEGIN PRIVATE KEY'
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
listen_overlap_contract() {
    t_seed
    t_entry_add vless_reality
    local id
    id="$NODE_ID"
    t_assert '初始监听 127.0.0.1:19507' jq -e '.inbounds[0].listen=="127.0.0.1" and .inbounds[0].listen_port==19507' "$SBD_CONFIG"
    # 绑定探测桩恒失败：只有「编辑自身 + 地址重叠」这一条路径允许跳过探测。
    sbd_entry_socket_available() { return 1; }
    t_run 0 sbd_apply sbd_entry_change "$id" listen '{"listen":"0.0.0.0","listen_port":19507}'
    t_assert '自身重叠地址不算端口冲突' jq -e '.inbounds[0].listen=="0.0.0.0" and .inbounds[0].listen_port==19507' "$SBD_CONFIG"
    t_run 1 sbd_apply sbd_entry_change "$id" listen '{"listen":"127.0.0.1","listen_port":19620}'
    t_contains "$CASE_TMP/output" '无法绑定'
    t_patch_config '.inbounds += [{type:"direct",tag:"other",listen:"127.0.0.1",listen_port:19507}]'
    t_run 1 sbd_apply sbd_entry_change "$id" listen '{"listen":"127.0.0.1","listen_port":19507}'
    t_contains "$CASE_TMP/output" '已被占用'
}
t_case '节点字段重问、十进制与秘密随机输入' field_contract
t_case 'AnyTLS 真实配置与 URI 编码' anytls_contract
t_case 'AnyReality 真实密钥与原生客户端/服务端' reality_contract
t_case 'Hysteria2 默认 BBR 和证书指纹 URI' hy2_default
t_case 'Hysteria2 两侧带宽与 Gecko 自定义 URI 扩展' hy2_custom
t_case 'Hysteria2 编辑管理：端口跳跃、两侧带宽与混淆' hy2_management
t_case 'ignore_client_bandwidth 下成对修改带宽并保留独立数值' hy2_paired_bandwidth
t_case '精简向导真实创建、自动分享、JSON 交付和 EOF 语义' create_prompt_contract
t_case '添加节点时导入自定义 PEM 证书并选择客户端信任' custom_certificate_prompt_contract
t_case '编辑自身时监听地址重叠不误判冲突，其他入口仍判冲突' listen_overlap_contract
t_case '首页空列表明确提示、坏登记不冒充没有节点' empty_list_contract
t_finish
