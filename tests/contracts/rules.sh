#!/usr/bin/env bash
# shellcheck disable=SC2016
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/policy.sh"

url_validation() {
    t_run 0 sbd_rule_url 'https://example.com/geosite-cn.srs'
    t_run 1 sbd_rule_url 'http://example.com/geosite-cn.srs'
    t_run 1 sbd_rule_url 'bad/path'
    export PYTHONOPTIMIZE=1
    t_run 1 sbd_rule_url 'https://example.com:0/geosite-cn.srs'
}
local_contract() {
    t_policy_seed
    t_policy_local
    local path
    path=$(jq -r '.route.rule_set[0].path' "$SBD_CONFIG") || exit 1
    # 官方 format 对 .srs 扩展名省略可推导的 format。
    t_assert '源文件编译为原生本地 SRS' jq -e '.route.rule_set[0]|.type=="local" and (.format // "binary")=="binary" and (.path|endswith(".srs"))' "$SBD_CONFIG"
    t_assert '源 JSON 保留原始版本' jq -e '.version==1' "${path%/*}/source.json"
    t_run 0 "$SBD_BINARY" rule-set decompile -o "$CASE_TMP/decoded.json" "$path"
    t_assert '实际规则集内容被核心解析' jq -e '.rules[0].domain_suffix|index("example.com")!=null' "$CASE_TMP/decoded.json"
    t_assert '外部源文件没有被改写' cmp -s "$ROOT/tests/fixtures/rule-set-domains.json" "${path%/*}/source.json"
    t_run 0 sbd_apply sbd_policy_begin
}
binary_contract() {
    t_policy_seed
    "$SBD_BINARY" rule-set compile -o "$CASE_TMP/input.srs" "$ROOT/tests/fixtures/rule-set-ips.json" || exit 1
    local value
    value=$(jq -n --arg path "$CASE_TMP/input.srs" '{type:"local",tag:"ips",format:"binary",path:$path}') || exit 1
    t_run 0 sbd_apply sbd_rule_set add ips "$value"
    t_assert '输入 SRS 通过真实解析后保留原字节' cmp -s "$CASE_TMP/input.srs" "$(jq -r '.route.rule_set[0].path' "$SBD_CONFIG")"
}
invalid_contract() {
    t_policy_seed
    cp "$SBD_CONFIG" "$CASE_TMP/old-config" || exit 1
    printf 'not a rule-set' > "$CASE_TMP/bad.srs" || exit 1
    local value
    value=$(jq -n --arg path "$CASE_TMP/bad.srs" '{type:"local",tag:"broken",format:"binary",path:$path}') || exit 1
    t_run 1 sbd_apply sbd_rule_set add broken "$value"
    t_assert '配置原字节保留' cmp -s "$SBD_CONFIG" "$CASE_TMP/old-config"
    t_assert '坏 SRS 候选材料已回收' test -z "$(find "$SBD_ASSET_DIR/rule-sets" -mindepth 1 -maxdepth 1 -type d)"
    value=$(jq -n --arg path "$CASE_TMP/bad.srs" '{type:"local",tag:"broken",format:"source",path:$path}') || exit 1
    t_run 1 sbd_apply sbd_rule_set add broken "$value"
    t_assert '源规则失败后配置原字节保留' cmp -s "$SBD_CONFIG" "$CASE_TMP/old-config"
}
route_contract() {
    t_policy_seed
    local rule id
    rule=$(cat "$ROOT/tests/fixtures/route-policy.json") || exit 1
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' "$rule" 0
    id=$(t_policy_id route_rules) || exit 1
    t_assert '管理 ID 不污染原生规则字段' jq -e '.route.rules[0]|(has("id") or has("managed") or has("tag"))|not' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_policy_rule route_rules replace "$id" '{"domain_suffix":["example.org"],"action":"reject"}'
    t_assert '替换后仍是同一管理 ID' test "$(t_policy_id route_rules)" = "$id"
    t_assert '动作写入实际配置' jq -e '.route.rules[0].action=="reject"' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_policy_rule route_rules delete "$id"
    t_assert '规则和关联一起删除' jq -e '(.route.rules // [])==[]' "$SBD_CONFIG"
}
inline_contract() {
    t_policy_seed
    t_run 0 sbd_apply sbd_rule_set add inline-domains '{"tag":"inline-domains","rules":[{"domain_suffix":"example.com"}]}'
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"rule_set":"inline-domains","action":"route","outbound":"direct"}'
    t_assert '官方可省略 type 的 inline 仍可管理' jq -e '.route.rule_set[0]|(.type // "inline")=="inline" and .rules[0].domain_suffix=="example.com"' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_policy_rule route_rules delete "$(t_policy_id route_rules)"
    t_run 0 sbd_apply sbd_rule_set delete inline-domains
    t_assert 'inline 不创建文件材料' test ! -e "$SBD_ASSET_DIR/rule-sets"
}
route_input_contract() {
    t_run 0 sbd_route_custom_parse 'Example.COM, 1.2.3.4, 2001:db8::/32, example.com'
    t_assert '域名归一化、裸 IP 补全前缀并去重' jq -e '
        .=={domain_suffix:["example.com"],ip_cidr:["1.2.3.4/32","2001:db8::/32"]}' "$CASE_TMP/output"
    t_run 1 sbd_route_custom_parse 'https://example.com/path'
    t_run 1 sbd_route_custom_parse '*.example.com'
    t_run 1 sbd_route_custom_parse '   '
}
menu_add_remote() {
    t_policy_seed
    t_run 0 sbd_rules_menu <<< $'6\n2\nhttps://example.com/geosite-cn.srs\n\ny\n0'
    t_contains "$CASE_TMP/output" '规则集 geosite-cn 已添加'
    t_assert '菜单添加远端规则集并写显式 HTTP client' jq -e '.route.rule_set[0] | .type=="remote" and .tag=="geosite-cn" and (.format // "binary")=="binary" and .url=="https://example.com/geosite-cn.srs" and .update_interval=="24h0m0s" and .http_client=={version:2}' "$SBD_CONFIG"
    t_assert '远端规则集启用核心缓存' jq -e '.experimental.cache_file.enabled==true and (.experimental.cache_file.path|endswith("/cache.db"))' "$SBD_CONFIG"
    t_assert '规则集归属登记到 registry' jq -e '.policy.rule_sets[0].id=="geosite-cn"' "$SBD_REGISTRY"
    t_run 0 sbd_rules_menu <<< $'5\n0'
    t_contains "$CASE_TMP/output" 'geosite-cn  remote binary'
}
menu_add_preset() {
    t_policy_seed
    t_run 0 sbd_rules_menu <<< $'6\n1\n4\ny\n0'
    t_contains "$CASE_TMP/output" '规则集 geosite-cn 已添加'
    t_assert '预设目录写入 MetaCubeX 规则集地址' jq -e '.route.rule_set[0] | .tag=="geosite-cn" and .url=="https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs" and (.format // "binary")=="binary" and .update_interval=="24h0m0s"' "$SBD_CONFIG"
    t_assert '目录中的规则统一来自 MetaCubeX' jq -e '
        all(.[]; .url | startswith("https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/"))' <<< "$(sbd_rule_catalog)"
}
menu_add_named_preset() {
    t_policy_seed
    t_run 0 sbd_rules_menu <<< $'6\n4\nGEOSITE:OpenAI, github, openai\ny\n0'
    t_contains "$CASE_TMP/output" '规则集 geosite-openai, geosite-github 已添加'
    t_assert '预设名称映射到 MetaCubeX 并去重' jq -e '
        [.route.rule_set[] | {tag,url,format:(.format // "binary"),update_interval,http_client}] == [
          {tag:"geosite-openai",url:"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/openai.srs",format:"binary",update_interval:"24h0m0s",http_client:{version:2}},
          {tag:"geosite-github",url:"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/github.srs",format:"binary",update_interval:"24h0m0s",http_client:{version:2}}
        ]' "$SBD_CONFIG"
    t_assert '预设名称逐条登记归属' jq -e '[.policy.rule_sets[].id]==["geosite-openai","geosite-github"]' "$SBD_REGISTRY"
    t_assert '预设名称共用核心缓存' jq -e '.experimental.cache_file.enabled==true and (.route.rule_set|length)==2' "$SBD_CONFIG"
}
menu_add_geoip_preset() {
    t_policy_seed
    t_run 0 sbd_rules_menu <<< $'6\n5\nGEOIP:CN, private, cn\ny\n0'
    t_contains "$CASE_TMP/output" '规则集 geoip-cn, geoip-private 已添加'
    t_assert 'GeoIP 预设映射到 MetaCubeX 并去重' jq -e '
        [.route.rule_set[] | {tag,url,format:(.format // "binary"),update_interval,http_client}] == [
          {tag:"geoip-cn",url:"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs",format:"binary",update_interval:"24h0m0s",http_client:{version:2}},
          {tag:"geoip-private",url:"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/private.srs",format:"binary",update_interval:"24h0m0s",http_client:{version:2}}
        ]' "$SBD_CONFIG"
    t_assert 'GeoIP 预设名称逐条登记归属' jq -e '[.policy.rule_sets[].id]==["geoip-cn","geoip-private"]' "$SBD_REGISTRY"
}
menu_delete_referenced() {
    t_policy_seed
    t_run 0 sbd_apply sbd_rule_set add inline-domains '{"tag":"inline-domains","rules":[{"domain_suffix":"example.com"}]}'
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"rule_set":"inline-domains","action":"reject"}'
    t_entry_save
    t_run 0 sbd_rules_menu <<< $'7\n1\n0'
    t_contains "$CASE_TMP/output" '仍有 1 条路由/DNS 规则引用 inline-domains'
    t_entry_unchanged
    t_run 0 sbd_apply sbd_policy_rule route_rules delete "$(t_policy_id route_rules)"
    t_run 0 sbd_rules_menu <<< $'7\n1\ny\n0'
    t_contains "$CASE_TMP/output" '规则集 inline-domains 已删除'
    t_assert '删除后不再保留原生规则集' jq -e '(.route.rule_set // [])==[]' "$SBD_CONFIG"
}
menu_add_route_rule_set() {
    t_policy_seed
    t_run 0 sbd_apply sbd_rule_set add inline-managed '{"tag":"inline-managed","rules":[{"domain_suffix":"managed.example"}]}'
    t_patch_config '.route.rule_set = ((.route.rule_set // []) + [{type:"inline",tag:"inline-manual",rules:[{domain_suffix:"manual.example"}]}])'
    t_run 0 sbd_rules_menu <<< $'2\n1\n1,2\n1\ny\n0'
    t_contains "$CASE_TMP/output" '[2] 添加路由规则'
    t_contains "$CASE_TMP/output" '路由规则已添加'
    t_assert '脚本与手工规则集都出现在选择列表并可多选引用' jq -e '
        .route.rules[-1] == {rule_set:["inline-managed","inline-manual"],outbound:"direct"}' "$SBD_CONFIG"
    t_assert '新路由规则登记为脚本托管' jq -e --slurpfile config "$SBD_CONFIG" '
        .policy.route_rules[-1].index == (($config[0].route.rules|length)-1)
        and .policy.route_rules[-1].expected.rule_set == ["inline-managed","inline-manual"]' "$SBD_REGISTRY"
}
menu_add_route_custom() {
    t_policy_seed
    t_run 0 sbd_rules_menu <<< $'2\n2\nExample.COM, 1.2.3.0/24\n2\ny\n0'
    t_contains "$CASE_TMP/output" '[3] 自定义出站'
    t_contains "$CASE_TMP/output" '路由规则已添加'
    t_assert '域名与 CIDR 用逻辑 OR，拒绝动作为 drop' jq -e '
        .route.rules[-1] == {
          type:"logical",mode:"or",
          rules:[
            {domain_suffix:"example.com"},
            {ip_cidr:"1.2.3.0/24"}
          ],
          action:"reject",method:"drop"
        }' "$SBD_CONFIG"
}
menu_add_route_inbound() {
    t_policy_seed
    t_patch_config '.inbounds=[
        {type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080},
        {type:"mixed",tag:"mixed-in-2",listen:"127.0.0.1",listen_port:2081}
      ]'
    t_run 0 sbd_rules_menu <<< $'2\n3\n1,2\n1\ny\n0'
    t_contains "$CASE_TMP/output" '[1] 规则集   [2] 自定义域名/IP   [3] inbound'
    t_contains "$CASE_TMP/output" '路由规则已添加'
    t_assert '匹配方式 [3] 只按 inbound 多选匹配' jq -e '
        .route.rules[-1] == {inbound:["mixed-in","mixed-in-2"],outbound:"direct"}' "$SBD_CONFIG"
}
menu_add_route_warp_and_custom() {
    t_policy_seed
    t_patch_config '.outbounds += [{type:"socks",tag:"socks-out",server:"127.0.0.1",server_port:1080}]'
    local key value
    key=$(python3 -c 'import base64; print(base64.b64encode(b"\0"*32).decode())') || exit 1
    value=$(jq -n --arg key "$key" '
        {type:"wireguard",tag:"warp",system:false,address:["172.16.0.2/32"],private_key:$key,mtu:1408,listen_port:0,
         peers:[{address:"162.159.192.1",port:2408,public_key:$key,allowed_ips:["0.0.0.0/0","::/0"],reserved:[0,0,0]}]}') || exit 1
    t_run 0 sbd_apply sbd_peer_change endpoints add warp "$value"
    t_run 0 sbd_rules_menu <<< $'2\n2\nexample.org\n3\ny\n0'
    t_contains "$CASE_TMP/output" '[3] WARP（warp）'
    t_contains "$CASE_TMP/output" '[4] 自定义出站'
    t_assert '已添加 WARP 时可选 WARP 作为路由出口' jq -e '
        .route.rules[-1] == {domain_suffix:"example.org",outbound:"warp"}' "$SBD_CONFIG"
    t_run 0 sbd_rules_menu <<< $'2\n2\nexample.net\n4\ny\n0'
    t_contains "$CASE_TMP/output" '使用唯一自定义出口: socks-out'
    t_assert 'WARP 存在时仍可选 outbounds 中的自定义出口' jq -e '
        .route.rules[-1] == {domain_suffix:"example.net",outbound:"socks-out"}' "$SBD_CONFIG"
}
menu_delete_route_rule() {
    t_policy_seed
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"domain":"a.example","action":"route","outbound":"direct"}'
    local first
    first=$(t_policy_id route_rules) || exit 1
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"domain":"b.example","action":"route","outbound":"direct"}'
    t_patch_config '.route.rules += [{domain:"manual.example",action:"route",outbound:"direct"}]'
    t_run 0 sbd_rules_menu <<< $'3\n1\ny\n0'
    t_contains "$CASE_TMP/output" '路由规则已删除'
    t_absent "$CASE_TMP/output" 'manual.example'
    t_assert '只删除托管规则并保留手工规则' jq -e '
        [.route.rules[].domain] == ["b.example","manual.example"]' "$SBD_CONFIG"
    t_assert '剩余托管登记索引同步下移' jq -e --arg first "$first" '
        (.policy.route_rules|length)==2
        and .policy.route_rules[0].id!=$first
        and .policy.route_rules[0].index==0
        and .policy.route_rules[0].expected.domain=="b.example"' "$SBD_REGISTRY"
}
defaults_restore() {
    t_policy_seed
    t_run 0 sbd_apply sbd_policy_rule route_rules add '' '{"domain":"custom.example","action":"route","outbound":"direct"}'
    local id
    id=$(t_policy_id route_rules) || exit 1
    t_run 0 sbd_rules_menu <<< $'8\ny\n0'
    t_contains "$CASE_TMP/output" '默认路由规则已补齐'
    t_assert '补齐默认规则且保留自定义规则' jq -e '.route.rules[0]=={action:"sniff"} and .route.rules[1]=={protocol:"dns",action:"hijack-dns"} and .route.rules[2]=={action:"resolve"} and .route.rules[3]=={ip_is_private:true,action:"reject"} and .route.rules[4].domain=="custom.example" and (.route.rules|length==5)' "$SBD_CONFIG"
    t_assert '补齐默认规则后保留托管登记并重算位置' jq -e --arg id "$id" '
        (.policy.route_rules|length)==1
        and .policy.route_rules[0].id==$id
        and .policy.route_rules[0].index==4
        and .policy.route_rules[0].expected.domain=="custom.example"' "$SBD_REGISTRY"
    t_run 0 sbd_rules_menu <<< $'8\ny\n0'
    t_assert '反复补齐不复制规则' jq -e '(.route.rules|length)==5' "$SBD_CONFIG"
    t_assert '反复补齐保留托管登记' jq -e --arg id "$id" '
        any(.policy.route_rules[]; .id==$id and .index==4 and .expected.domain=="custom.example")' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_policy_rule route_rules delete "$id"
    t_assert '补齐后仍可按登记删除自定义规则' jq -e '
        (.route.rules|length)==4 and ((.policy.route_rules // [])|length)==0' "$SBD_CONFIG"
}
t_case '规则集 URL 校验不依赖 assert' url_validation
t_case '本地源版本 1 经核心编译和原生配置校验' local_contract
t_case '版本 5 IP 规则编译后作为 SRS 导入' binary_contract
t_case '坏 JSON/SRS 真实失败与材料回收' invalid_contract
t_case '路由规则 CRUD、稳定关联和无私有配置字段' route_contract
t_case '省略 type 的原生 inline 规则集引用与删除' inline_contract
t_case '自定义域名/IP 输入归一化与拒绝协议路径通配符' route_input_contract
t_case '菜单添加远端规则集、缓存与归属登记' menu_add_remote
t_case '菜单按预设目录添加规则集' menu_add_preset
t_case '菜单按预设名称添加 MetaCubeX 规则集' menu_add_named_preset
t_case '菜单按 GeoIP 预设名称添加 MetaCubeX 规则集' menu_add_geoip_preset
t_case '被规则引用的规则集拒绝删除，解除后真实删除' menu_delete_referenced
t_case '菜单用脚本与手工规则集添加路由规则' menu_add_route_rule_set
t_case '菜单添加域名+CIDR 逻辑 OR 与 reject drop 规则' menu_add_route_custom
t_case '菜单按 inbound 匹配方式添加路由规则' menu_add_route_inbound
t_case '菜单添加 WARP 与自定义 outbound 出口规则' menu_add_route_warp_and_custom
t_case '菜单删除托管路由规则并保留手工规则' menu_delete_route_rule
t_case '补齐默认路由规则并保留自定义规则' defaults_restore
t_finish
