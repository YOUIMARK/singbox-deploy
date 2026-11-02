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
    t_run 0 sbd_apply sbd_entry_change "$id" external '{"server":"198.51.100.10","server_port":30443}'
    t_assert '改名/密码/外网映射不改变稳定 ID' test "$(jq -r '.nodes[0].id' "$SBD_REGISTRY")" = "$id"
    t_assert '密码同步原生用户' jq -e '.inbounds[0].users[0].password=="new@:/?# &+密码" and .inbounds[0].listen_port==19501' "$SBD_CONFIG"
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
t_case '改名/认证/映射统一重建且稳定 ID 不变' edit_identity
t_case '外部认证漂移拒绝覆盖且保留旧导出' drift_password
t_case '定点节点编辑保留合法自定义配置' preserve_custom
t_case '引用中的 inbound 不能删除' delete_referenced
t_case '创建节点 state 失败整组回滚' state_failure
t_finish
