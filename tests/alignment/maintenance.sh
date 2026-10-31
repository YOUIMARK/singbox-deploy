#!/usr/bin/env bash
# 原生配置/文件事务真实执行；只替换服务和指定失败边界，不操作宿主服务。
# shellcheck disable=SC2329,SC2016
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/peers.sh"

policy_adoption() {
    t_policy_seed
    jq '.route.rules=[{domain:"custom.example",action:"route",outbound:"direct"}]' "$SBD_CONFIG" > "$CASE_TMP/custom" || exit 1
    cp "$CASE_TMP/custom" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_apply sbd_policy_adopt route_rules '' 0
    local id
    id=$(t_policy_id route_rules) || exit 1
    jq '.route.rules[0].domain="edited.example"' "$SBD_CONFIG" > "$CASE_TMP/drift" || exit 1
    cp "$CASE_TMP/drift" "$SBD_CONFIG" || exit 1
    t_run 1 sbd_apply sbd_policy_rule route_rules delete "$id"
    t_run 0 sbd_apply sbd_policy_adopt route_rules "$id" 0
    t_assert '协调采用当前配置而不是登记反向覆盖' jq -e '.route.rules[0].domain=="edited.example"' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_policy_rule route_rules delete "$id"
}
node_adoption() {
    t_policy_seed
    local profile tag id facts
    for profile in shadowsocks vmess_ws vless_ws anyreality vless_reality anytls hysteria2; do
        t_entry_add "$profile"
        id="$NODE_ID"; tag=$(jq -r '.nodes[-1].inbound_tag' "$SBD_REGISTRY") || exit 1
        facts=$(jq -c '.nodes[-1] | {name,server:.client.server,server_port:.client.server_port,cdn:.ingress,short_id:.client.tls.reality.short_id,server_name:.client.tls.server_name,trust:"pin",client_options:{}}' "$SBD_REGISTRY") || exit 1
        jq --arg id "$id" '.nodes|=map(select(.id!=$id))' "$SBD_REGISTRY" > "$CASE_TMP/unmanaged" || exit 1
        cp "$CASE_TMP/unmanaged" "$SBD_REGISTRY" || exit 1
        t_run 0 sbd_apply sbd_entry_adopt "$tag" "$facts"
        id=$(jq -r '.nodes[-1].id' "$SBD_REGISTRY") || exit 1
        t_assert '接管不改原生 inbound 关联' test "$(jq -r '.nodes[-1].inbound_tag' "$SBD_REGISTRY")" = "$tag"
        t_assert '接管统一生成真实 URI' test -s "$SBD_EXPORTS/$id.txt"
        t_run 0 sbd_apply sbd_entry_change "$id" delete ''
    done
}
node_coordinate() {
    t_policy_seed
    t_entry_add vless_ws
    jq '.inbounds[0].users[0].uuid="69e480fd-5918-468c-b730-7c7b8fa81b8b"' "$SBD_CONFIG" > "$CASE_TMP/drift" || exit 1
    cp "$CASE_TMP/drift" "$SBD_CONFIG" || exit 1
    local facts
    facts=$(jq -c '.nodes[0]|{name,server:.client.server,server_port:.client.server_port,cdn:.ingress}' "$SBD_REGISTRY") || exit 1
    t_run 0 sbd_apply sbd_entry_adopt "$NODE_ID" "$facts" "$NODE_ID"
    t_assert '协调保留 ID 并采用当前 UUID' jq -e --arg id "$NODE_ID" '.nodes[0]|.id==$id and .client.uuid=="69e480fd-5918-468c-b730-7c7b8fa81b8b"' "$SBD_REGISTRY"
    t_entry_save
    t_run 1 sbd_apply sbd_entry_adopt "$NODE_ID" '{}'
    t_entry_unchanged
}
reset_nodes() {
    t_policy_seed
    t_entry_add vless_ws
    jq '.inbounds += [{type:"mixed",tag:"user-mixed",listen:"127.0.0.1",listen_port:19889}]' "$SBD_CONFIG" > "$CASE_TMP/custom" || exit 1
    cp "$CASE_TMP/custom" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_apply sbd_reset nodes
    t_assert 'reset 只删除托管节点，保留自定义入口' jq -e '.inbounds|length==1 and .[0].tag=="user-mixed"' "$SBD_CONFIG"
    t_assert '清空节点派生链接' test ! -s "$SBD_EXPORTS/links.txt"
}
reset_references() {
    t_policy_seed
    t_policy_udp
    t_run 0 sbd_apply sbd_resolver_default final upstream
    t_entry_save
    t_run 1 sbd_apply sbd_reset rules_dns
    t_entry_unchanged
    t_run 0 sbd_apply sbd_resolver_default final system
    t_run 0 sbd_apply sbd_reset rules_dns
    t_assert '默认未托管 system 上游保留' jq -e '.dns.servers|length==1 and .[0].tag=="system"' "$SBD_CONFIG"
}
history_config() {
    t_policy_seed
    t_run 0 sbd_apply sbd_observe_change level debug
    t_run 0 sbd_history_restore
    t_assert '最近配置完整恢复但修订号前进' jq -e '.log.level=="warn"' "$SBD_CONFIG"
    t_assert '恢复也提交 state' jq -e '.revision==2' "$SBD_STATE"
    t_run 0 sbd_history_restore
    t_assert '最近版本可以恢复到撤销前版本' jq -e '.log.level=="debug"' "$SBD_CONFIG"
    t_assert '恢复源不累积递归嵌套目标副本' test ! -e "$SBD_WORK/previous/target"
}
history_materials() {
    t_policy_seed
    t_policy_local
    local path
    path=$(jq -r '.route.rule_set[0].path' "$SBD_CONFIG") || exit 1
    t_run 0 sbd_apply sbd_rule_set delete domains
    t_run 0 sbd_history_restore
    t_assert '恢复规则集配置的同时保留其材料' test -s "$path"
    t_run 0 sbd_check_config
}
history_failure() {
    t_policy_seed
    t_run 0 sbd_apply sbd_observe_change level debug
    t_entry_save
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_history_restore
    t_assert '恢复到达 state 故障边界' test -f "$CASE_TMP/failed"
    t_entry_unchanged
}
maintenance_cancel() {
    t_fresh
    t_run 0 sbd_maintenance_menu <<< 0
    t_run 0 sbd_maintenance_menu < /dev/null
    t_run 2 sbd_maintenance_menu <<< $'3\n1'
    t_assert '取消 reset 不创建配置' test ! -e "$SBD_CONFIG"
}
policy_peers_adoption() {
    t_policy_seed
    jq --slurpfile ep "$ROOT/tests/fixtures/endpoint-wireguard.json" '.endpoints=$ep' "$SBD_CONFIG" > "$CASE_TMP/custom" || exit 1
    cp "$CASE_TMP/custom" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_apply sbd_policy_adopt endpoints wg-fixture
    t_run 0 sbd_apply sbd_peer_change endpoints delete wg-fixture
    t_assert '显式接管 endpoint 后可走正常删除' jq -e '(.endpoints // [])==[]' "$SBD_CONFIG"
}
reset_peers_tls() {
    t_policy_seed
    t_peer_add wireguard
    t_peer_add cloudflared
    t_run 0 sbd_apply sbd_reset peers
    t_assert '批量 peers reset 不留内嵌 connector 或 endpoint' jq -e '((.endpoints // [])|length==0) and ((.inbounds // [])|length==0)' "$SBD_CONFIG"
    t_run 0 sbd_apply sbd_tls_material_add self_signed node.example.com
    t_run 0 sbd_apply sbd_reset tls
    t_assert '无引用 TLS 登记可批量清空' jq -e '.tls.certificates==[]' "$SBD_REGISTRY"
}
maintenance_menus() {
    t_policy_seed
    jq '.route.rules=[{domain:"custom.example",action:"reject"}]' "$SBD_CONFIG" > "$CASE_TMP/custom" || exit 1
    cp "$CASE_TMP/custom" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_adopt_menu <<< $'1\n1\n1\n\ny'
    t_assert '编号接管向导确实登记规则' jq -e '.policy.route_rules|length==1' "$SBD_REGISTRY"
    t_run 0 sbd_maintenance_menu <<< $'3\n2\ny\n0'
    t_assert '编号 reset 向导提交真实规则删除' jq -e '(.route.rules // [])==[]' "$SBD_CONFIG"
}
adopt_state_failure() {
    t_policy_seed
    t_entry_add shadowsocks
    local tag facts
    tag="$NODE_ID"
    facts=$(jq -c '.nodes[0]|{name,server:.client.server,server_port:.client.server_port}' "$SBD_REGISTRY") || exit 1
    jq '.nodes=[]' "$SBD_REGISTRY" > "$CASE_TMP/unmanaged" || exit 1
    cp "$CASE_TMP/unmanaged" "$SBD_REGISTRY" || exit 1
    t_entry_save
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_apply sbd_entry_adopt "$tag" "$facts"
    t_assert '接管到达真实 state 提交边界' test -f "$CASE_TMP/failed"
    t_entry_unchanged
}
adopt_rule_material() {
    t_policy_seed
    t_policy_local
    local old origin
    old=$(jq -r '.policy.rule_sets[0].directory' "$SBD_REGISTRY") || exit 1
    origin=$(jq -c '.policy.rule_sets[0].origin' "$SBD_REGISTRY") || exit 1
    t_run 0 sbd_apply sbd_policy_adopt rule_sets domains
    t_assert '协调同一路径保留自有材料归属' jq -e --arg old "$old" --argjson origin "$origin" '.policy.rule_sets[0]|.directory==$old and .origin==$origin' "$SBD_REGISTRY"
    cp "$ROOT/tests/fixtures/rule-set-domains.json" "$CASE_TMP/external-source.json" || exit 1
    jq --arg path "$CASE_TMP/external-source.json" '.route.rule_set[0].path=$path | .route.rule_set[0].format="source"' "$SBD_CONFIG" > "$CASE_TMP/drift" || exit 1
    cp "$CASE_TMP/drift" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_apply sbd_policy_adopt rule_sets domains
    t_assert '接管外部路径不取得文件删除权' jq -e '.policy.rule_sets[0].directory==""' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_rule_set delete domains
    t_assert '删除外部接管配置不删除原文件' test -s "$CASE_TMP/external-source.json"
}
t_case '规则接管和漂移协调只采用当前配置' policy_adoption
t_case '七档节点实际接管、导出及删除' node_adoption
t_case '节点协调保留稳定 ID，缺事实失败保留旧导出' node_coordinate
t_case '按类别 reset 节点保留未托管配置' reset_nodes
t_case 'reset 存活引用失败整组回滚' reset_references
t_case '最近配置资源组恢复与单份恢复源' history_config
t_case '最近恢复与退休规则材料一致' history_materials
t_case '最近恢复 state 失败还原操作前现场' history_failure
t_case '维护菜单 EOF/取消无副作用' maintenance_cancel
t_case '未托管 endpoint 显式接管后纳入正常生命周期' policy_peers_adoption
t_case 'peers/TLS 两种托管类别 reset 真实执行' reset_peers_tls
t_case '策略接管和类别 reset 完整编号菜单' maintenance_menus
t_case '节点接管导出后 state 失败保留旧登记和链接' adopt_state_failure
t_case '规则集协调保留材料来源，接管外部文件不授予删除权' adopt_rule_material
t_finish
