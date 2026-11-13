#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2016
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/peers.sh"

warp_contract() {
    t_fresh
    local value
    t_assert 'WARP 注册接口请求 sing-box 原生格式' test "$SBD_PEER_WARP_API" = 'https://warp.cloudflare.now.cc/?run=register&format=sing-box'
    sbd_peer_warp_download() { cp "$ROOT/tests/fixtures/warp-api.json" "$1"; }
    t_run 0 sbd_peer_warp_obtain
    value="$SBD_PEER_VALUE"
    t_assert 'WARP API sing-box endpoint 映射与保留' jq -e '
        .type=="wireguard" and .tag=="warp" and .system==false and .listen_port==0
        and .address==["172.16.0.2/32","2606:4700:110:8a36::2/128"]
        and .mtu==1280 and .peers[0].address=="engage.cloudflareclient.com"
        and .peers[0].port==2408 and .peers[0].reserved==[1,2,3]
        and .peers[0].allowed_ips==["0.0.0.0/0","::/0"]' <<< "$value"
    t_run 0 python3 "$ROOT/support/warp.py" normalize "$ROOT/tests/fixtures/warp-api-defaults.json"
    value=$(cat "$CASE_TMP/output")
    t_assert '缺省字段与裸 IPv6 endpoint 归一正确' jq -e '
        .address==["172.16.0.3/32"] and .mtu==1280
        and .peers[0].address=="2606:4700:110:8a36::3" and .peers[0].port==2408
        and .peers[0].reserved==[0,0,0]
        and .peers[0].allowed_ips==["0.0.0.0/0","::/0"]' <<< "$value"
}
warp_failures() {
    t_fresh
    local key
    key=$(jq -r '.endpoints[0].private_key' "$ROOT/tests/fixtures/warp-api.json") || exit 1
    cp "$ROOT/tests/fixtures/warp-api.json" "$CASE_TMP/raw" || exit 1
    sbd_peer_warp_download() { cp "$CASE_TMP/raw" "$1"; }
    t_run 0 sbd_peer_warp_obtain
    t_absent "$CASE_TMP/output" "$key"
    sbd_peer_warp_download() { return 1; }
    t_run 1 sbd_peer_warp_obtain
    sbd_peer_warp_download() { cp "$CASE_TMP/raw" "$1"; }
    printf '{"outbounds":[' > "$CASE_TMP/raw" || exit 1
    t_run 1 sbd_peer_warp_obtain
    jq 'del(.endpoints[0].private_key)' "$ROOT/tests/fixtures/warp-api.json" > "$CASE_TMP/raw" || exit 1
    t_run 1 sbd_peer_warp_obtain
    jq '.endpoints[0].peers[0].reserved=[1,2]' "$ROOT/tests/fixtures/warp-api.json" > "$CASE_TMP/raw" || exit 1
    t_run 1 sbd_peer_warp_obtain
    t_contains "$CASE_TMP/output" '配置未修改'
}
wireguard_contract() {
    t_policy_seed
    t_peer_add wireguard
    t_assert 'WireGuard 在 endpoints，不是旧 outbound' jq -e '.endpoints[0].type=="wireguard" and all(.outbounds[];.type!="wireguard") and (.endpoints[0].system // false)==false' "$SBD_CONFIG"
    t_run 0 t_peer_reserved '[1,2,255]'
    t_run 0 sbd_peer_list
    t_absent "$CASE_TMP/output" AAECAwQF
    t_run 0 sbd_check_config
}
cloudflare_contract() {
    local protocol value
    for protocol in quic http2; do
        t_policy_seed
        t_patch_config '.route.rules += [{ip_is_private:true,action:"reject"}]'
        t_prepare_live
        value=$(jq --arg protocol "$protocol" '.protocol=$protocol' "$ROOT/tests/fixtures/inbound-cloudflared.json") || exit 1
        t_run 0 sbd_apply sbd_peer_change connectors add cf-fixture "$value"
        t_run 0 sbd_apply sbd_route_defaults
        t_run 0 sbd_apply sbd_peer_change connectors replace cf-fixture "$value"
        t_assert '原生内嵌 Cloudflared 不写本地监听参数' jq -e '.inbounds[0]|.type=="cloudflared" and (has("listen") or has("listen_port")|not)' "$SBD_CONFIG"
        t_assert 'Tunnel direct 例外位于私网拒绝规则之前' jq -e '
            ([.route.rules[]|select(.ip_is_private==true and .action=="reject")][0]) as $reject
            | (.route.rules|index($reject)) as $index
            | $index>0 and .route.rules[$index-1]=={inbound:"cf-fixture",outbound:"direct"}' "$SBD_CONFIG"
        t_assert '规范化默认 action 后更新不重复添加路由例外' jq -e '[.route.rules[]|select(.inbound=="cf-fixture" and .outbound=="direct")]|length==1' "$SBD_CONFIG"
        t_assert 'Tunnel direct 例外由策略登记器托管' jq -e '
            any(.policy.route_rules[]?; .id=="cloudflared.cf-fixture" and .expected.inbound=="cf-fixture")' "$SBD_REGISTRY"
        t_run 0 sbd_peer_list
        t_absent "$CASE_TMP/output" eyJhIjoi
        t_run 0 sbd_apply sbd_peer_change connectors delete cf-fixture
        t_assert '删除 Tunnel 同步删除自动登记的路由例外' jq -e 'all(.route.rules[]?; .inbound!="cf-fixture")' "$SBD_CONFIG"
        t_assert '删除 Tunnel 同步删除策略记录' jq -e 'all(.policy.route_rules[]?; .id!="cloudflared.cf-fixture")' "$SBD_REGISTRY"
    done
}
cloudflare_defaults_contract() {
    t_policy_seed
    t_peer_add cloudflared
    t_assert '没有私网拒绝规则时保留现有路由行为' jq -e '(.route.rules//[]|length)==0' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_route_defaults
    t_run 0 sbd_apply sbd_route_defaults
    t_assert '已有 Tunnel 补齐默认规则时自动放行且不复制' jq -e '
        .route.rules[3]=={inbound:"cf-fixture",outbound:"direct"}
        and .route.rules[4]=={ip_is_private:true,action:"reject"}
        and (.route.rules|length)==5' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_peer_change connectors delete cf-fixture
    t_assert '删除隧道同步清理默认规则中的自动例外' jq -e '
        (.inbounds|length)==0 and (.route.rules|length)==4
        and all(.route.rules[]; .inbound!="cf-fixture")' "$SBD_CONFIG"
}
cloudflare_manual_route_contract() {
    t_policy_seed
    t_peer_add cloudflared
    t_patch_config '.route.rules=[{inbound:["cf-fixture"],outbound:"direct"},{ip_is_private:true,action:"reject"}]'
    t_prepare_live
    local value
    value=$(cat "$ROOT/tests/fixtures/inbound-cloudflared.json") || exit 1
    t_run 0 sbd_apply sbd_peer_change connectors replace cf-fixture "$value"
    t_assert '复用无额外条件的用户例外' jq -e '(.route.rules|length)==2' "$SBD_CONFIG"
    t_assert '用户例外不登记为 Tunnel 自动规则' jq -e 'all(.policy.route_rules[]?; .id!="cloudflared.cf-fixture")' "$SBD_REGISTRY"
    t_patch_config '.route.rules[0].domain="example.com"'
    t_prepare_live
    t_run 0 sbd_apply sbd_peer_change connectors replace cf-fixture "$value"
    t_assert '带额外域名条件的规则不能代替完整 Tunnel 例外' jq -e '
        (.route.rules|length)==3 and .route.rules[0].domain=="example.com"
        and .route.rules[1]=={inbound:"cf-fixture",outbound:"direct"}' "$SBD_CONFIG"
    t_run 1 sbd_apply sbd_peer_change connectors delete cf-fixture
    t_assert '用户规则仍引用 Tunnel 时删除失败保留原配置' jq -e '(.inbounds|length)==1 and (.route.rules|length)==3' "$SBD_CONFIG"
}
field_contract() {
    t_fresh
    local key token
    key=$(jq -r .private_key "$ROOT/tests/fixtures/endpoint-wireguard.json") || exit 1
    token=$(jq -r .token "$ROOT/tests/fixtures/inbound-cloudflared.json") || exit 1
    sbd_peer_key_prompt 私钥 > "$CASE_TMP/prompt" 2>&1 <<< "$(printf 'bad\n%s\n' "$key")" || exit 1
    t_assert '密钥错误只重问当前字段' test "$SBD_REPLY" = "$key"
    t_absent "$CASE_TMP/prompt" "$key"
    sbd_peer_prefix_prompt address > "$CASE_TMP/prompt" 2>&1 <<< $'bad\n10.0.0.2/24, fd00::2/64' || exit 1
    t_assert '接口地址不能归一成网络地址丢掉 host bits' jq -e '.==["10.0.0.2/24","fd00::2/64"]' <<< "$SBD_REPLY"
    sbd_peer_prefix_prompt address > "$CASE_TMP/prompt" 2>&1 <<< $'10.0.0.2/24，fd00::2/64、10.0.0.3/32' || exit 1
    t_assert '接口地址兼容中文逗号/顿号/分号' jq -e '.==["10.0.0.2/24","fd00::2/64","10.0.0.3/32"]' <<< "$SBD_REPLY"
    sbd_peer_token_prompt > "$CASE_TMP/prompt" 2>&1 <<< "$(printf 'bad-token\n%s\n' "$token")" || exit 1
    t_assert 'token 用核心真实解析后保留原字节' test "$SBD_REPLY" = "$token"
    t_absent "$CASE_TMP/prompt" "$token"
    t_run 2 sbd_peer_key_prompt 密钥 < /dev/null
    t_run 2 sbd_peer_token_prompt < /dev/null
}
token_input_contract() {
    t_fresh
    local token input
    token=$(jq -r .token "$ROOT/tests/fixtures/inbound-cloudflared.json") || exit 1
    for input in \
        "$token" \
        "cloudflared.exe service install $token" \
        "sudo cloudflared service install $token" \
        "cloudflared tunnel run --token $token" \
        "brew install cloudflared && sudo cloudflared service install $token" \
        "docker run cloudflare/cloudflared:latest tunnel --no-autoupdate run --token $token" \
        "cloudflared tunnel run --token=$token"; do
        sbd_peer_token_prompt > "$CASE_TMP/prompt" 2>&1 <<< "$input" || exit 1
        t_assert '裸 token 和 cloudflared 命令均提取原 token' test "$SBD_REPLY" = "$token"
        t_absent "$CASE_TMP/prompt" "$token"
    done
}
tagless_target_contract() {
    t_policy_seed
    sbd_peer_tag_prompt > "$CASE_TMP/prompt" 2>&1 <<< $'direct\nfree-tag' || exit 1
    t_assert '已有 tag 冲突只重问原生标识字段' test "$SBD_REPLY" = free-tag
    jq '.dns.servers += [{type:"udp",server:"192.0.2.53"}]' "$SBD_CONFIG" > "$CASE_TMP/dns" || exit 1
    cp "$CASE_TMP/dns" "$SBD_CONFIG" || exit 1
    t_prepare_live
    t_run 0 sbd_check_config
    t_run 0 sbd_policy_target dns <<< 1
    t_assert '原生无 tag 对象保留但不伪造可引用标识' test "$SBD_REPLY" = system
    t_absent "$CASE_TMP/output" null
    t_run 2 sbd_policy_target dns <<< 2
}
t_case 'WARP 注册 API sing-box 字段映射与缺省归一' warp_contract
t_case 'WARP 下载/JSON/密钥/reserved 失败均不写入' warp_failures
t_case 'WireGuard 原生 endpoints 与 peer reserved 真实检查' wireguard_contract
t_case 'Cloudflared QUIC/HTTP2 原生入站和秘密不回显' cloudflare_contract
t_case '已有 Tunnel 恢复默认规则与删除清理' cloudflare_defaults_contract
t_case 'Cloudflared 用户路由例外复用与额外条件识别' cloudflare_manual_route_contract
t_case '密钥/token/CIDR 字段重问与核心 token 解析' field_contract
t_case 'Cloudflare Tunnel 裸 token 与安装/运行命令输入' token_input_contract
t_case '原生无 tag 的 DNS 不显示为伪造 null 目标' tagless_target_contract
t_finish
