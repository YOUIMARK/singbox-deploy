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
edit_menu_contract() {
    t_fresh
    sbd_entry_actions anytls edit > "$CASE_TMP/output" 2>&1 || exit 1
    t_contains "$CASE_TMP/output" '[3] 修改客户端连接地址'
    t_absent "$CASE_TMP/output" '映射端口'
    sbd_entry_hy2_actions > "$CASE_TMP/output" 2>&1 || exit 1
    t_contains "$CASE_TMP/output" '[4] 修改本地监听'
    t_absent "$CASE_TMP/output" '映射端口'
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
    t_assert 'direct 模式不创建辅助入站' jq -e '(.inbounds|length)==1' "$SBD_CONFIG"
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
hy2_prompt_contract() {
    t_fresh
    t_run 0 sbd_entry_hy2_prompt <<< $'2\n100\n50\n1\n'
    t_assert 'Brutal 一次填写双端方向镜像' jq -e '.server_options=={"up_mbps":100,"down_mbps":50} and .client_options=={"up_mbps":50,"down_mbps":100}' <<< "$SBD_HY2_REQUEST"
    t_run 0 sbd_entry_hy2_prompt <<< $'1\n3\n1\n'
    t_assert 'BBR 档位双端写入' jq -e '.server_options=={"bbr_profile":"aggressive"} and .client_options=={"bbr_profile":"aggressive"}' <<< "$SBD_HY2_REQUEST"
}
hy2_management() {
    t_seed
    t_entry_add vmess_ws
    t_entry_add hysteria2
    local id tag node
    id="$NODE_ID"
    tag=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.inbound_tag' "$SBD_REGISTRY")
    t_run 2 sbd_entry_change_prompt edit <<< $'2\n5\n1\n\n0\n'
    t_contains "$CASE_TMP/output" '当前端口范围: 未启用'
    t_run 2 sbd_entry_change_prompt edit <<< $'2\n5\n2\nabc\n20000-20100\ny\n0\n'
    t_absent "$CASE_TMP/output" '[5] Hysteria2 管理'
    t_contains "$CASE_TMP/output" 'Hysteria2 节点管理'
    t_contains "$CASE_TMP/output" '[5] 客户端端口跳跃'
    t_contains "$CASE_TMP/output" 'sing-box inbound 仍监听单端口'
    t_contains "$CASE_TMP/output" '端口范围格式'
    t_contains "$CASE_TMP/output" '端口范围须为 3050、20000-50000 或 11,13,15-17 这类组合'
    t_contains "$CASE_TMP/output" '[6] 上/下行带宽'
    t_contains "$CASE_TMP/output" '[7] Salamander/Gecko 混淆'
    t_contains "$CASE_TMP/output" '[8] 切换 TLS 来源'
    t_contains "$CASE_TMP/output" '[9] HTTP/3 伪装 masquerade'
    t_contains "$CASE_TMP/output" '[10] BBR 调优档'
    t_assert '编辑菜单配置客户端跳跃端口' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client|(.server_ports==["20000:20100"] and (has("hop_interval")|not))' "$SBD_REGISTRY"
    t_assert 'sing-box 原生客户端导出仅携带跳跃范围' jq -e '.outbounds[0]|(.server_ports=="20000:20100" and (has("hop_interval")|not))' "$SBD_EXPORTS/$id.json"
    t_run 0 t_entry_uri hysteria2
    t_run 0 t_classic_uri
    t_run 2 sbd_entry_change_prompt edit <<< $'2\n6\n2\n100\n25\ny\n0\n'
    t_contains "$CASE_TMP/output" '[6] 上/下行带宽'
    t_assert '服务端带宽写入 inbound' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.up_mbps==100 and .down_mbps==25' "$SBD_CONFIG"
    t_assert '客户端带宽按相反方向镜像' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client.up_mbps==25 and .client.down_mbps==100' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_bandwidth_sync '{}'
    t_assert '切回 BBR 双端清除带宽' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(has("up_mbps") or has("down_mbps") or has("ignore_client_bandwidth"))|not' "$SBD_CONFIG"
    t_assert '切回 BBR 清除客户端带宽' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client|(has("up_mbps") or has("down_mbps"))|not' "$SBD_REGISTRY"
    node=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SBD_REGISTRY") || exit 1
    sbd_entry_hy2_manage_prompt "$node" 5 > "$CASE_TMP/bbr-view" 2>&1 <<< $'2' || exit 1
    t_contains "$CASE_TMP/bbr-view" '当前 BBR 档位: standard'
    t_assert 'BBR 子菜单生成档位动作' test "$SBD_HY2_ACTION" = hy2_bbr_profile -a "$SBD_HY2_REQUEST" = conservative
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_bbr_profile aggressive
    t_assert 'BBR 档位写入 inbound' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.bbr_profile=="aggressive"' "$SBD_CONFIG"
    t_assert 'BBR 档位写入客户端' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client.bbr_profile=="aggressive"' "$SBD_REGISTRY"
    t_assert '客户端 JSON 携带 BBR 档位' jq -e '.outbounds[0].bbr_profile=="aggressive"' "$SBD_EXPORTS/$id.json"
    t_run 1 sbd_apply sbd_entry_change "$id" hy2_bbr_profile bogus
    t_contains "$CASE_TMP/output" 'BBR 档位无效'
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_bbr_profile standard
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_obfs '{"type":"salamander","password":"fixture-obfs"}'
    t_assert '服务端混淆已更新' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.obfs.type=="salamander"' "$SBD_CONFIG"
    t_assert '客户端混淆已同步更新' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client.obfs.password=="fixture-obfs"' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_obfs null
    t_assert '服务端混淆已清除' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|has("obfs")|not' "$SBD_CONFIG"
    t_assert '客户端混淆已清除' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client|has("obfs")|not' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_hops '{"server_ports":["20000:20100","3050:3050"]}'
    t_assert '多段混合跳跃范围按序保存' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.client|.server_ports==["20000:20100","3050:3050"]' "$SBD_REGISTRY"
    node=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SBD_REGISTRY") || exit 1
    SBD_HY2_VIEW=false
    sbd_entry_hy2_manage_prompt "$node" 1 > "$CASE_TMP/hops-view" 2>&1 <<< $'1' || exit 1
    t_contains "$CASE_TMP/hops-view" '当前端口范围: 20000-20100,3050'
    t_run 0 t_entry_uri hysteria2
    t_run 1 sbd_apply sbd_entry_change "$id" hy2_hops '{"server_ports":["20000:20100","bad"]}'
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_hops '{"server_ports":[]}'
    t_assert '关闭端口跳跃清除导出和 URI 参数' jq -e --arg id "$id" '(.nodes[]|select(.id==$id)|.client|has("server_ports") or has("hop_interval"))|not' "$SBD_REGISTRY"
    t_run 0 t_entry_uri hysteria2
    t_run 1 sbd_apply sbd_entry_change "$id" hy2_hops '{"server_ports":["20100:20000"]}'
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_masquerade '{"type":"proxy","url":"https://www.amd.com/","rewrite_host":true}'
    t_assert '反向代理伪装写入 inbound' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.masquerade=={type:"proxy",url:"https://www.amd.com/",rewrite_host:true}' "$SBD_CONFIG"
    node=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SBD_REGISTRY") || exit 1
    SBD_HY2_VIEW=false
    sbd_entry_hy2_manage_prompt "$node" 4 > "$CASE_TMP/masquerade-view" 2>&1 <<< $'1' || exit 1
    t_contains "$CASE_TMP/masquerade-view" '当前伪装: proxy → https://www.amd.com/（重写 Host）'
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_masquerade '{"type":"string","status_code":200,"content":"welcome"}'
    t_assert '字符串伪装写入 inbound' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.masquerade=={type:"string",status_code:200,content:"welcome"}' "$SBD_CONFIG"
    node=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SBD_REGISTRY") || exit 1
    SBD_HY2_VIEW=false
    sbd_entry_hy2_manage_prompt "$node" 4 > "$CASE_TMP/masquerade-view" 2>&1 <<< $'1' || exit 1
    t_contains "$CASE_TMP/masquerade-view" '当前伪装: string → HTTP 200：welcome'
    t_run 1 sbd_apply sbd_entry_change "$id" hy2_masquerade '{"type":"proxy","url":"ftp://www.amd.com/"}'
    t_run 1 sbd_apply sbd_entry_change "$id" hy2_masquerade '{"type":"string","content":""}'
    t_run 1 sbd_apply sbd_entry_change "$id" hy2_masquerade '{"type":"bogus","content":"welcome"}'
    t_run 0 sbd_apply sbd_entry_change "$id" hy2_masquerade null
    t_assert '关闭伪装清除 inbound' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|has("masquerade")|not' "$SBD_CONFIG"
    node=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SBD_REGISTRY") || exit 1
    SBD_HY2_VIEW=false
    sbd_entry_hy2_manage_prompt "$node" 4 > "$CASE_TMP/masquerade-view" 2>&1 <<< $'1' || exit 1
    t_contains "$CASE_TMP/masquerade-view" '当前伪装: 未启用'
    t_run 2 sbd_entry_change_prompt edit <<< $'2\n9\n1\n\n0\n'
    t_contains "$CASE_TMP/output" '当前伪装: 未启用'
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
    sbd_entry_hy2_manage_prompt "$node" 2 > "$CASE_TMP/prompt" 2>&1 <<< $'2\n100\n25' || exit 1
    t_assert '带宽菜单进入双端同步' test "$SBD_HY2_ACTION" = hy2_bandwidth_sync
    t_assert '一次录入服务器上下行' jq -e '.=={up_mbps:100,down_mbps:25}' <<< "$SBD_HY2_REQUEST"
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
    t_assert '导入证书直接引用外部路径且不登记受管目录' jq -e --arg cert "$CASE_TMP/custom-cert.pem" --arg key "$CASE_TMP/custom-key.pem" '.tls.certificates[0] | .certificate_path==$cert and .key_path==$key and .directory==""' "$SBD_REGISTRY"
    t_assert '导入证书不创建受管材料目录' test -z "$(find "$SBD_CERT_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)"
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
reality_mode_prompt_contract() {
    t_fresh
    t_run 0 sbd_entry_tls_prompt vless_reality 127.0.0.1 <<< $'example.com\n2'
    t_contains "$CASE_TMP/output" '[1] 直连伪装站（默认）'
    t_contains "$CASE_TMP/output" '[2] Tunnel（本机回环 + SNI 白名单）'
    t_assert '选择 Tunnel 写入 TLS 请求' jq -e '.kind=="reality" and .server_name=="example.com" and .mode=="tunnel"' <<< "$SBD_TLS_REQUEST"
}
t_reality_tunnel_seed() {
    t_seed
    t_patch_config --slurpfile base "$ROOT/presets/base.json" '
        .route.rules=$base[0].route.rules |
        .route.rule_set=$base[0].route.rule_set |
        .route.default_domain_resolver="system" |
        .dns={"servers":[{"type":"local","tag":"system"}],"final":"system"}
    '
}

reality_tunnel_contract() {
    t_reality_tunnel_seed
    local spec id tag tunnel_tag tunnel_port
    spec=$(jq '.tls_source.mode="tunnel"' "$ROOT/tests/fixtures/entry-vless_reality.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    id=$(jq -r '.nodes[0].id' "$SBD_REGISTRY") || exit 1
    tag=$(jq -r '.nodes[0].inbound_tag' "$SBD_REGISTRY") || exit 1
    tunnel_tag=$(jq -r '.nodes[0].tunnel_tag' "$SBD_REGISTRY") || exit 1
    tunnel_port=$(jq -r '.nodes[0].tunnel_port' "$SBD_REGISTRY") || exit 1
    t_assert 'Tunnel 模式元数据稳定' jq -e '.nodes[0]|.reality_mode=="tunnel" and .tunnel_tag==("reality-tunnel-" + .id) and (.tunnel_port|type=="number")' "$SBD_REGISTRY"
    t_assert '辅助 direct 入站固定回源' jq -e --arg tag "$tunnel_tag" --argjson port "$tunnel_port" \
        '.inbounds[]|select(.tag==$tag)|.type=="direct" and .listen=="127.0.0.1" and .listen_port==$port and .network=="tcp" and .override_address=="example.com" and .override_port==443' "$SBD_CONFIG"
    t_assert 'Reality handshake 指向回环' jq -e --arg tag "$tag" --argjson port "$tunnel_port" \
        '.inbounds[]|select(.tag==$tag)|.tls.reality.handshake.server=="127.0.0.1" and .tls.reality.handshake.server_port==$port' "$SBD_CONFIG"
    t_assert 'Tunnel 规则紧跟 sniff 且位于 resolve 之前' jq -e --arg tag "$tunnel_tag" --slurpfile base "$ROOT/presets/base.json" '
        ($base[0].route.rules) as $defaults |
        (.route.rules|length)==(($defaults|length)+2) and
        .route.rules[0]==$defaults[0] and
        .route.rules[1].inbound==$tag and
        .route.rules[2].inbound==$tag and
        .route.rules[3:]==$defaults[1:]
    ' "$SBD_CONFIG"
    t_assert 'Tunnel 白名单和兜底拒绝' jq -e --arg tag "$tunnel_tag" '
        def hit($tag): (.inbound // []) | if type=="array" then index($tag)!=null else .==$tag end;
        def domain_is($sni): (.domain // []) | if type=="array" then .==[$sni] else .==$sni end;
        [.route.rules[]|select(hit($tag))] as $rules |
        ($rules|length)==2 and
        any($rules[]; domain_is("example.com") and ((.action // "route")=="route") and .outbound=="direct") and
        any($rules[]; (.domain // null)==null and .action=="reject")
    ' "$SBD_CONFIG"
    t_assert 'Tunnel 规则组完整登记' jq -e --arg group "reality-tunnel.$id" \
        '[.policy.route_rules[]|select(.group==$group)]|length==2' "$SBD_REGISTRY"
    t_run 0 sbd_check_config
    t_run 0 sbd_export_node "$id" link inline
    t_contains "$CASE_TMP/output" '分享链接: vless://'
}

reality_tunnel_anyreality_contract() {
    t_reality_tunnel_seed
    local spec id tag tunnel_tag
    spec=$(jq '.tls_source.mode="tunnel"' "$ROOT/tests/fixtures/entry-anyreality.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    id=$(jq -r '.nodes[0].id' "$SBD_REGISTRY") || exit 1
    tag=$(jq -r '.nodes[0].inbound_tag' "$SBD_REGISTRY") || exit 1
    tunnel_tag=$(jq -r '.nodes[0].tunnel_tag' "$SBD_REGISTRY") || exit 1
    t_assert 'AnyReality Tunnel 元数据' jq -e '.nodes[0]|.reality_mode=="tunnel"' "$SBD_REGISTRY"
    t_assert 'AnyReality 辅助入站' jq -e --arg tag "$tunnel_tag" '.inbounds[]|select(.tag==$tag)|.override_address=="example.com"' "$SBD_CONFIG"
    t_assert 'AnyReality handshake 回环' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.handshake.server=="127.0.0.1"' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_entry_change "$id" delete ''
    t_assert '删除节点清理辅助入站' jq -e --arg tag "$tunnel_tag" 'all((.inbounds // [])[]; .tag!=$tag)' "$SBD_CONFIG"
    t_assert '删除节点清理规则' jq -e --arg tag "$tunnel_tag" 'all((.route.rules // [])[]; ((.inbound // [])|if type=="array" then index($tag) else .==$tag end)==null)' "$SBD_CONFIG"
    t_assert '删除节点清理规则登记' jq -e --arg group "reality-tunnel.$id" 'all(.policy.route_rules[]; .group!=$group)' "$SBD_REGISTRY"
}

reality_tunnel_change_contract() {
    t_reality_tunnel_seed
    local spec id tag tunnel_tag
    spec=$(jq '.tls_source.mode="tunnel"' "$ROOT/tests/fixtures/entry-vless_reality.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    id=$(jq -r '.nodes[0].id' "$SBD_REGISTRY") || exit 1
    tag=$(jq -r '.nodes[0].inbound_tag' "$SBD_REGISTRY") || exit 1
    tunnel_tag=$(jq -r '.nodes[0].tunnel_tag' "$SBD_REGISTRY") || exit 1
    t_run 0 sbd_apply sbd_entry_change "$id" tls '{"kind":"reality","server_name":"new.example.com","handshake":{"server":"new.example.com","server_port":443}}'
    t_assert '改 SNI 同步辅助入站' jq -e --arg tag "$tunnel_tag" '.inbounds[]|select(.tag==$tag)|.override_address=="new.example.com"' "$SBD_CONFIG"
    t_assert '改 SNI 同步白名单' jq -e --arg tag "$tunnel_tag" '
        def hit($tag): (.inbound // []) | if type=="array" then index($tag)!=null else .==$tag end;
        any(.route.rules[]; hit($tag) and
            ((.domain // []) | if type=="array" then .==["new.example.com"] else .=="new.example.com" end))
    ' "$SBD_CONFIG"
    t_assert '改 SNI 后 handshake 仍回环' jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.handshake.server=="127.0.0.1"' "$SBD_CONFIG"
    t_assert '客户端 SNI 已更新' jq -e '.nodes[0].client.tls.server_name=="new.example.com"' "$SBD_REGISTRY"
    t_run 1 sbd_apply sbd_entry_change "$id" tls '{"kind":"reality","server_name":"1.1.1.1","handshake":{"server":"1.1.1.1","server_port":443}}'
    t_contains "$CASE_TMP/output" '伪装域名必须是 DNS 名称'
    t_assert 'IP SNI 变更整组回滚' jq -e '.nodes[0].client.tls.server_name=="new.example.com"' "$SBD_REGISTRY"
    t_run 0 sbd_check_config
}

reality_tunnel_drift_contract() {
    t_reality_tunnel_seed
    local spec id tunnel_tag name
    spec=$(jq '.tls_source.mode="tunnel"' "$ROOT/tests/fixtures/entry-vless_reality.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    id=$(jq -r '.nodes[0].id' "$SBD_REGISTRY") || exit 1
    tunnel_tag=$(jq -r '.nodes[0].tunnel_tag' "$SBD_REGISTRY") || exit 1
    name=$(jq -r '.nodes[0].name' "$SBD_REGISTRY") || exit 1
    t_patch_config --arg tag "$tunnel_tag" '(.inbounds[]|select(.tag==$tag)|.override_address)="wrong.example.com"'
    t_run 1 sbd_apply sbd_entry_change "$id" name '漂移后的名字'
    t_contains "$CASE_TMP/output" 'Tunnel 辅助入站或回源目标发生漂移'
    t_assert '漂移时节点名未提交' jq -e --arg name "$name" '.nodes[0].name==$name' "$SBD_REGISTRY"
}

reality_tunnel_requires_defaults() {
    t_seed
    local spec
    spec=$(jq '.tls_source.mode="tunnel"' "$ROOT/tests/fixtures/entry-vless_reality.json") || exit 1
    t_run 1 sbd_apply sbd_entry_create "$spec"
    t_contains "$CASE_TMP/output" '需要默认 sniff 路由规则'
    t_assert '缺少默认规则时不写节点' jq -e '.nodes|length==0' "$SBD_REGISTRY"
    t_assert '缺少默认规则时不写入站' jq -e '(.inbounds // [])|length==0' "$SBD_CONFIG"
}
reality_tunnel_rejects_ip_contract() {
    t_reality_tunnel_seed
    local spec
    spec=$(jq '.tls_source.mode="tunnel" | .tls_source.server_name="1.1.1.1"' "$ROOT/tests/fixtures/entry-vless_reality.json") || exit 1
    t_run 1 sbd_apply sbd_entry_create "$spec"
    t_contains "$CASE_TMP/output" '伪装域名必须是 DNS 名称'
    t_assert 'IP 伪装目标不写节点' jq -e '.nodes|length==0' "$SBD_REGISTRY"
}
reality_tunnel_defaults_restore_contract() {
    t_reality_tunnel_seed
    local spec id tunnel_tag group
    spec=$(jq '.tls_source.mode="tunnel"' "$ROOT/tests/fixtures/entry-vless_reality.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    id=$(jq -r '.nodes[0].id' "$SBD_REGISTRY") || exit 1
    tunnel_tag=$(jq -r '.nodes[0].tunnel_tag' "$SBD_REGISTRY") || exit 1
    group="reality-tunnel.$id"
    t_run 0 sbd_apply sbd_route_defaults
    t_assert '恢复默认后 Tunnel 规则仍在 sniff 之后' jq -e --arg tag "$tunnel_tag" --slurpfile base "$ROOT/presets/base.json" '
        ($base[0].route.rules) as $defaults |
        .route.rules[0]==$defaults[0] and
        .route.rules[1].inbound==$tag and
        .route.rules[2].inbound==$tag and
        .route.rules[3:]==$defaults[1:]
    ' "$SBD_CONFIG"
    t_assert '恢复默认后保留 Tunnel 分组和位置登记' jq -e --arg group "$group" '
        ([.policy.route_rules[]?|select(.group==$group)] | sort_by(.index) | map(.index)) == [1,2]
    ' "$SBD_REGISTRY"
    t_run 1 sbd_apply sbd_policy_rule route_rules delete "$group.allow"
    t_contains "$CASE_TMP/output" 'Tunnel 托管规则不能单独修改或删除'
}
reality_tunnel_two_nodes_contract() {
    t_reality_tunnel_seed
    local spec
    spec=$(jq '.tls_source.mode="tunnel"' "$ROOT/tests/fixtures/entry-vless_reality.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    spec=$(jq '.tls_source.mode="tunnel" | .name="第二个 Tunnel" | .listen_port=19508' "$ROOT/tests/fixtures/entry-vless_reality.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    t_assert '两个 Tunnel 节点的规则都紧跟 sniff' jq -e --slurpfile base "$ROOT/presets/base.json" '
        def tunnel_hit: (.inbound // []) | if type=="array" then any(.[]; startswith("reality-tunnel-")) else startswith("reality-tunnel-") end;
        ($base[0].route.rules) as $defaults |
        ([.route.rules[] | select(tunnel_hit)] | length)==4 and
        .route.rules[0]==$defaults[0] and
        ([.route.rules[1:5][] | tunnel_hit] | all) and
        .route.rules[5:]==$defaults[1:]
    ' "$SBD_CONFIG"
    t_assert '两个 Tunnel 节点各保留两条分组登记' jq -e '
        ([.policy.route_rules[]? | select((.group // "")|startswith("reality-tunnel."))] | group_by(.group) | map(length) | all(.==2))
    ' "$SBD_REGISTRY"
}
t_case '节点字段重问、十进制与秘密随机输入' field_contract
t_case '节点编辑菜单不再询问映射端口' edit_menu_contract
t_case 'AnyTLS 真实配置与 URI 编码' anytls_contract
t_case 'AnyReality 真实密钥与原生客户端/服务端' reality_contract
t_case 'Hysteria2 默认 BBR 和证书指纹 URI' hy2_default
t_case 'Hysteria2 两侧带宽与 Gecko 自定义 URI 扩展' hy2_custom
t_case 'Hysteria2 创建向导一次带宽询问并镜像双端' hy2_prompt_contract
t_case 'Hysteria2 编辑管理：端口跳跃、两侧带宽与混淆' hy2_management
t_case 'ignore_client_bandwidth 下成对修改带宽并保留独立数值' hy2_paired_bandwidth
t_case '精简向导真实创建、自动分享、JSON 交付和 EOF 语义' create_prompt_contract
t_case 'Reality 创建时选择直连或 Tunnel 握手' reality_mode_prompt_contract
t_case '添加节点时导入自定义 PEM 证书并选择客户端信任' custom_certificate_prompt_contract
t_case 'VLESS Reality Tunnel 创建、规则与导出' reality_tunnel_contract
t_case 'AnyReality Tunnel 创建与删除清理' reality_tunnel_anyreality_contract
t_case 'Reality Tunnel 改 SNI 同步辅助入站和规则' reality_tunnel_change_contract
t_case 'Reality Tunnel 辅助入站漂移拒绝提交' reality_tunnel_drift_contract
t_case 'Reality Tunnel 缺少默认路由规则时拒绝创建' reality_tunnel_requires_defaults
t_case 'Reality Tunnel 拒绝 IP 伪装目标' reality_tunnel_rejects_ip_contract
t_case '恢复默认路由规则后 Tunnel 仍紧跟 sniff' reality_tunnel_defaults_restore_contract
t_case '两个 Tunnel 节点规则互不误判' reality_tunnel_two_nodes_contract
t_case '编辑自身时监听地址重叠不误判冲突，其他入口仍判冲突' listen_overlap_contract
t_case '首页空列表明确提示、坏登记不冒充没有节点' empty_list_contract
t_finish
