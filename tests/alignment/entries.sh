#!/usr/bin/env bash
# 仅服务生命周期用窄桩，其余操作执行真实节点函数、OpenSSL、Schema、format/check。
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/entries.sh"

edit_identity() {
    t_seed
    t_entry_add anytls
    local id="$NODE_ID"
    t_run 0 sbd_apply sbd_entry_change "$id" name '新名字 /#'
    t_run 0 sbd_apply sbd_entry_change "$id" password 'new@:/?# &+密码'
    t_run 0 sbd_apply sbd_entry_change "$id" external '{"server":"198.51.100.10"}'
    t_assert '改名/密码/对外地址不改变稳定 ID' test "$(jq -r '.nodes[0].id' "$SBD_REGISTRY")" = "$id"
    t_assert '对外地址与分享端口分开维护' jq -e '.nodes[0].client.server=="198.51.100.10" and .nodes[0].client.server_port==29501' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_entry_change "$id" listen '{"listen":"127.0.0.1","listen_port":19607}'
    t_assert '改本地监听同步分享端口' jq -e '.nodes[0].client.server_port==19607' "$SBD_REGISTRY"
    t_assert '密码同步原生用户' jq -e '.inbounds[0].users[0].password=="new@:/?# &+密码" and .inbounds[0].listen_port==19607' "$SBD_CONFIG"
    t_run 0 t_entry_uri anytls
}
drift_password() {
    t_seed
    t_entry_add anytls
    t_patch_config '.inbounds[0].users[0].password="external-change" | .inbounds[0].padding_scheme=["stop=8"]'
    t_entry_save
    t_run 1 sbd_apply sbd_entry_change "$NODE_ID" password replace
    t_contains "$CASE_TMP/output" '不一致'
    t_entry_unchanged
}
preserve_custom() {
    t_seed
    t_entry_add anytls
    t_patch_config '.inbounds[0].padding_scheme=["stop=8"] | .outbounds += [{type:"direct",tag:"custom-direct"}]'
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" password replace
    # 官方 format 将单元素 Listable 数组压成字符串；内容和自定义出口必须仍保留。
    t_assert '定点改凭据不覆盖合法自定义' jq -e '.inbounds[0].padding_scheme=="stop=8" and any(.outbounds[]; .tag=="custom-direct")' "$SBD_CONFIG"
}
delete_referenced() {
    t_seed
    t_entry_add anytls
    local tag
    tag=$(jq -r '.nodes[0].inbound_tag' "$SBD_REGISTRY") || exit 1
    t_patch_config --arg tag "$tag" '.route.rules=[{inbound:[$tag],action:"route",outbound:"direct"}]'
    t_entry_save
    t_run 1 sbd_apply sbd_entry_change "$NODE_ID" delete ''
    t_contains "$CASE_TMP/output" '仍被路由'
    t_entry_unchanged
}
delete_vmess_ws() {
    t_seed
    t_entry_add vmess_ws
    local id="$NODE_ID" tag
    tag=$(jq -r '.nodes[0].inbound_tag' "$SBD_REGISTRY") || exit 1
    t_entry_save
    t_run 0 sbd_apply sbd_entry_change "$id" delete ''
    t_assert '节点登记已移除' jq -e '.nodes|length==0' "$SBD_REGISTRY"
    t_assert 'CDN WS inbound 已移除' jq -e --arg tag "$tag" '([(.inbounds // [])[]|select(.tag==$tag)]|length)==0' "$SBD_CONFIG"
}
delete_with_unrelated_drift() {
    t_seed
    t_entry_add vmess_ws
    local delete_id="$NODE_ID" drift_id drift_tag
    t_entry_add anytls
    drift_id="$NODE_ID"
    drift_tag=$(jq -r --arg id "$drift_id" '.nodes[]|select(.id==$id)|.inbound_tag' "$SBD_REGISTRY") || exit 1
    # 模拟手工编辑：改掉无关 AnyTLS 的凭据，使其登记事实与服务端 inbound 漂移。
    t_patch_config '.inbounds |= map(if .tag==$tag then .users[0].password="manual-change" else . end)' --arg tag "$drift_tag"
    t_run 0 sbd_apply sbd_entry_change "$delete_id" delete ''
    t_assert '被删节点已移除' jq -e --arg id "$delete_id" 'all(.nodes[];.id!=$id)' "$SBD_REGISTRY"
    t_assert '漂移节点保留登记并标记待协调' jq -e --arg id "$drift_id" '.nodes[]|select(.id==$id)|.stale==true' "$SBD_REGISTRY"
    t_assert '漂移节点旧导出仍保留' test -f "$SBD_EXPORTS/$drift_id.txt"
    t_assert '漂移节点不进入当前分享清单' test ! -s "$SBD_EXPORTS/links.txt"
}
reconcile_drift() {
    t_seed
    t_entry_add anytls
    local id="$NODE_ID" tag
    tag=$(jq -r '.nodes[0].inbound_tag' "$SBD_REGISTRY") || exit 1
    t_patch_config --arg tag "$tag" '.inbounds |= map(if .tag==$tag then .users[0].password="manual-change" else . end)'
    t_entry_save
    # 先让重建把漂移节点标成待协调；随后协调应以当前配置为准回灌。
    t_run 0 sbd_apply sbd_export_rebuild
    t_assert '漂移节点被标记待协调' jq -e '.nodes[0].stale==true' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_entry_reconcile_all
    t_assert '协调后清除待协调标记' jq -e '.nodes[0].stale!=true' "$SBD_REGISTRY"
    t_assert '协调后登记跟随当前配置' jq -e '.nodes[0].client.password=="manual-change"' "$SBD_REGISTRY"
    t_assert '协调后导出可读' test -s "$SBD_EXPORTS/$id.txt"
}
edit_with_own_drift() {
    t_seed
    t_entry_add anytls
    local tag
    tag=$(jq -r '.nodes[0].inbound_tag' "$SBD_REGISTRY") || exit 1
    t_patch_config --arg tag "$tag" '.inbounds |= map(if .tag==$tag then .users[0].password="manual-change" else . end)'
    t_entry_save
    # 本次节点自身与配置不一致时不得被“待协调”掩盖，整次编辑必须回滚。
    t_run 1 sbd_apply sbd_entry_change "$NODE_ID" password replace
    t_contains "$CASE_TMP/output" '不一致'
    t_entry_unchanged
}
cert_path_drift() {
    t_seed
    t_entry_add anytls
    local id="$NODE_ID" tag cert key alt
    tag=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.inbound_tag' "$SBD_REGISTRY") || exit 1
    cert=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.certificate_id' "$SBD_REGISTRY") || exit 1
    key=$(jq -r --arg id "$cert" '.tls.certificates[]|select(.id==$id)|.key_path' "$SBD_REGISTRY") || exit 1
    alt="$CASE_TMP/alt"
    mkdir -p "$alt" || exit 1
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -sha256 -days 30 \
        -subj '/CN=node.example.com' -addext 'subjectAltName=DNS:node.example.com' \
        -keyout "$alt/key.pem" -out "$alt/cert.pem" >/dev/null 2>&1 || exit 1
    # 模拟手工改证书路径：只改 config.json，登记仍指向旧证书。
    t_patch_config --arg tag "$tag" --arg cert "$alt/cert.pem" --arg key "$alt/key.pem" \
        '.inbounds |= map(if .tag==$tag then .tls.certificate_path=$cert | .tls.key_path=$key else . end)'
    t_entry_save
    t_run 0 sbd_apply sbd_export_rebuild
    t_assert '证书路径漂移被标记待协调' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.stale==true' "$SBD_REGISTRY"
    t_run 0 sbd_apply sbd_entry_reconcile_all
    t_assert '协调后节点可用新证书路径生成资料' test -s "$SBD_EXPORTS/$id.txt"
    t_assert '协调后不重复登记同一对证书路径' jq -e --arg cert "$alt/cert.pem" --arg key "$alt/key.pem" '[.tls.certificates[]|select(.certificate_path==$cert and .key_path==$key)]|length==1' "$SBD_REGISTRY"
}
stamp_reuse() {
    t_seed
    t_entry_add anytls
    t_entry_add vmess_ws
    local id="$NODE_ID" stamp
    stamp=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.facts_stamp' "$SBD_REGISTRY") || exit 1
    [[ -n "$stamp" && "$stamp" != null ]] || { echo '缺少 facts_stamp'; exit 1; }
    t_entry_save
    # 配置未变时应直接复用导出，不能再把节点判成漂移。
    t_run 0 sbd_apply sbd_export_rebuild
    t_assert '未改配置时复用导出且不标记漂移' jq -e --arg id "$id" '.nodes[]|select(.id==$id)|.stale!=true and .facts_stamp!=null' "$SBD_REGISTRY"
    t_assert '未改配置时导出逐字节保留' sbd_tree_compare "$ENTRY_SAVED/exports" "$SBD_EXPORTS"
}
state_failure() {
    t_seed
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_apply sbd_entry_create "$(cat "$ROOT/tests/fixtures/entry-anytls.json")"
    t_assert '到达真实提交末尾' test -f "$CASE_TMP/failed"
    t_unchanged
    t_assert '失败回收新证书' test -z "$(find "$SBD_CERT_DIR" -mindepth 1 -maxdepth 1 -type d)"
}
t_case '改名/认证/对外地址统一重建且稳定 ID 不变' edit_identity
t_case '外部认证漂移拒绝覆盖且保留旧导出' drift_password
t_case '定点节点编辑保留合法自定义配置' preserve_custom
t_case '引用中的 inbound 不能删除' delete_referenced
t_case '删除不带源站 TLS 的 CDN WS 节点' delete_vmess_ws
t_case '无关节点漂移不阻塞删除并保留旧导出' delete_with_unrelated_drift
t_case '按当前配置重新协调漂移节点' reconcile_drift
t_case '本次节点自身漂移仍拒绝编辑' edit_with_own_drift
t_case '证书路径漂移可由协调修复且不重复登记' cert_path_drift
t_case '配置未变时复用校验摘要' stamp_reuse
t_case '创建节点 state 失败整组回滚' state_failure
t_finish
