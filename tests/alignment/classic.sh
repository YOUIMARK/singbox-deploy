#!/usr/bin/env bash
# 服务边界和指定写失败用窄桩，其余执行真实生产函数与核心。
# shellcheck disable=SC2329,SC2016
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/entries.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/classic.sh"

ss_edit() {
    t_seed
    t_entry_add shadowsocks
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" ss '{"method":"2022-blake3-aes-256-gcm","network":"udp","password":"+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/s="}'
    t_assert 'SS 算法和 UDP 两侧更新' jq -e '.inbounds[0]|.method=="2022-blake3-aes-256-gcm" and .network=="udp"' "$SBD_CONFIG"
    t_run 0 t_classic_uri
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" password 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" listen '{"listen":"127.0.0.1","listen_port":19604}'
    t_assert '监听变更不误改客户端映射' jq -e '.nodes[0].client.server_port==29504' "$SBD_REGISTRY"
    t_run 0 t_classic_uri
    t_entry_save
    t_run 1 sbd_apply sbd_entry_change "$NODE_ID" password bad
    t_entry_unchanged
}
listen_tag_follows() {
    t_seed
    t_entry_add vless_reality
    local old
    old=$(jq -r '.nodes[0].inbound_tag' "$SBD_REGISTRY") || exit 1
    t_assert '创建时 tag 为协议-端口' test "$old" = vless-reality-19507
    t_patch_config --arg old "$old" '
        .inbounds += [{type:"direct",tag:"other",listen:"127.0.0.1",listen_port:19605}] |
        .route.rules = [
            {inbound:$old,action:"route",outbound:"direct"},
            {inbound:[$old,"other"],action:"route",outbound:"direct"},
            {type:"logical",mode:"or",rules:[{inbound:$old}],action:"route",outbound:"direct"}
        ] |
        .dns = {servers:[{type:"local",tag:"local"}],rules:[{inbound:$old,action:"reject"}]}
    '
    t_prepare_live || exit 1
    jq --slurpfile config "$SBD_CONFIG" '.policy={route_rules:[{id:"rule.route",index:0,expected:$config[0].route.rules[0]}],dns_rules:[{id:"rule.dns",index:0,expected:$config[0].dns.rules[0]}]}' "$SBD_REGISTRY" > "$CASE_TMP/registry-policy" || exit 1
    mv -- "$CASE_TMP/registry-policy" "$SBD_REGISTRY" || exit 1
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" listen '{"listen":"127.0.0.1","listen_port":19604}'
    t_assert 'inbound tag 跟随监听端口' jq -e '.inbounds[0].tag=="vless-reality-19604"' "$SBD_CONFIG"
    t_assert 'registry inbound_tag 跟随监听端口' jq -e '.nodes[0].inbound_tag=="vless-reality-19604"' "$SBD_REGISTRY"
    t_assert 'route 字符串引用同步' jq -e '.route.rules[0].inbound=="vless-reality-19604"' "$SBD_CONFIG"
    t_assert 'route 数组引用同步' jq -e '.route.rules[1].inbound==["vless-reality-19604","other"]' "$SBD_CONFIG"
    t_assert '逻辑规则引用同步' jq -e '.route.rules[2].rules[0].inbound=="vless-reality-19604"' "$SBD_CONFIG"
    t_assert 'dns 引用同步' jq -e '.dns.rules[0].inbound=="vless-reality-19604"' "$SBD_CONFIG"
    t_assert 'route 策略快照引用同步' jq -e '.policy.route_rules[0].expected.inbound=="vless-reality-19604"' "$SBD_REGISTRY"
    t_assert 'dns 策略快照引用同步' jq -e '.policy.dns_rules[0].expected.inbound=="vless-reality-19604"' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_policy_rule route_rules replace rule.route '{"inbound":"vless-reality-19604","action":"route","outbound":"direct"}'
    t_run 0 t_classic_uri
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" listen '{"listen":"0.0.0.0","listen_port":19604}'
    t_assert '同端口改监听地址不重复加后缀' jq -e '.nodes[0].inbound_tag=="vless-reality-19604"' "$SBD_REGISTRY"
}
listen_tag_collision() {
    t_seed
    t_entry_add vless_reality
    t_patch_config '.outbounds += [{type:"direct",tag:"vless-reality-19604"}]'
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" listen '{"listen":"127.0.0.1","listen_port":19604}'
    t_assert '新 tag 冲突时追加序号' jq -e '.nodes[0].inbound_tag=="vless-reality-19604-2"' "$SBD_REGISTRY"
    t_assert '冲突序号写入原生 tag' jq -e 'any(.inbounds[];.tag=="vless-reality-19604-2")' "$SBD_CONFIG"
}
uuid_edits() {
    t_seed
    local profile id
    for profile in vmess_ws vless_ws vless_reality; do
        t_entry_add "$profile"; id="$NODE_ID"
        t_run 0 sbd_apply sbd_entry_change "$id" password 69e480fd-5918-468c-b730-7c7b8fa81b8b
        t_assert '认证修改服务端 UUID' jq -e --arg tag "$(jq -r '.nodes[-1].inbound_tag' "$SBD_REGISTRY")" 'any(.inbounds[]; .tag==$tag and .users[0].uuid=="69e480fd-5918-468c-b730-7c7b8fa81b8b")' "$SBD_CONFIG"
        t_run 0 t_classic_uri
        t_entry_save
        t_run 1 sbd_apply sbd_entry_change "$id" password invalid
        t_entry_unchanged
    done
}
vision_rotate() {
    t_seed
    t_entry_add vless_reality
    local old
    old=$(jq -r '.nodes[0].client.tls.reality.public_key' "$SBD_REGISTRY") || exit 1
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" tls '{"kind":"reality","server_name":"new.example.com","handshake":{"server":"new.example.com","server_port":443}}'
    t_assert '密钥重建但保留 Vision' jq -e --arg old "$old" '.nodes[0].client|.tls.reality.public_key!=$old and .flow=="xtls-rprx-vision"' "$SBD_REGISTRY"
    t_run 0 t_classic_uri
}
drift_contract() {
    t_seed
    t_entry_add vmess_ws
    local original expression
    original=$(cat "$SBD_CONFIG") || exit 1
    for expression in '.inbounds[0].users[0].uuid="69e480fd-5918-468c-b730-7c7b8fa81b8b"' '.inbounds[0].transport.path="/changed"' '.inbounds[0].users[0].alterId=1' '.inbounds[0].transport.max_early_data=2048'; do
        jq "$expression" <<< "$original" > "$CASE_TMP/drift" || exit 1
        cp "$CASE_TMP/drift" "$SBD_CONFIG" || exit 1
        t_sync_config
        t_entry_save
        t_run 1 sbd_apply sbd_export_rebuild
        t_entry_unchanged
    done
}
preserve_ws() {
    t_seed
    t_entry_add vless_ws
    t_patch_config '.inbounds[0].transport.headers={"X-Origin":"custom"} | .outbounds += [{type:"direct",tag:"custom"}]'
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" password 69e480fd-5918-468c-b730-7c7b8fa81b8b
    t_assert '响应头和自定义出口不被覆盖' jq -e '.inbounds[0].transport.headers["X-Origin"]=="custom" and any(.outbounds[]; .tag=="custom")' "$SBD_CONFIG"
    t_run 0 t_classic_uri
}
t_case 'SS 算法/网络/密钥/监听事务和错误保留' ss_edit
t_case '监听端口变更同步 inbound tag 与存活引用' listen_tag_follows
t_case '监听端口新 tag 冲突追加序号' listen_tag_collision
t_case '三种 UUID 配置档真实认证更新' uuid_edits
t_case 'VLESS Reality 重新生成密钥并保留 Vision' vision_rotate
t_case 'VMess UUID/路径/AEAD/early data 漂移拒绝' drift_contract
t_case '节点编辑保留合法 WS 响应头与自定义出口' preserve_ws
t_finish
