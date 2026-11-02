#!/usr/bin/env bash
# 成功路径使用真实协议适配器；只在失败场景注入可观测边界故障。
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

attach_tls() {
    local stage="$1" kind="$2" id="$3" tls content
    tls=$(sbd_tls_server "$stage" "$kind" "$id") || return 1
    content=$(jq --argjson tls "$tls" '.inbounds=[{type:"anytls",tag:"fixture-in",listen:"127.0.0.1",listen_port:18443,users:[{name:"fixture",password:"fixture-password"}],tls:$tls}]' "$stage/config.json") || return 1
    sbd_record_write "$stage/config.json" "$content"
}
create_and_attach() {
    local stage="$1" id
    sbd_tls_material_add "$stage" self_signed node.example.com || return 1
    id=$(jq -r '.tls.certificates[-1].id' "$stage/registry.json") || return 1
    attach_tls "$stage" certificate "$id"
}
export_fixture() {
    local stage="$1" id tls content cert sha
    create_and_attach "$stage" || return 1
    id=$(jq -r '.tls.certificates[-1].id' "$stage/registry.json") || return 1
    tls=$(sbd_tls_client "$stage" "$id" pin) || return 1
    cert=$(jq -r '.tls.certificates[-1].certificate_path' "$stage/registry.json") || return 1
    sha=$(sbd_entry_cert_sha "$cert") || return 1
    content=$(jq --arg id "$id" --argjson tls "$tls" --arg sha "$sha" '.nodes=[{id:"fixture-node",name:"导出 fixture",profile:"anytls",inbound_tag:"fixture-in",certificate_id:$id,
        tls_source:{kind:"certificate",id:$id,trust:"pin"},share:{certificate_sha256:$sha},
        client:{type:"anytls",server:"2001:db8::1",server_port:24443,password:"fixture-password",tls:$tls}}]' "$stage/registry.json") || return 1
    sbd_record_write "$stage/registry.json" "$content" || return 1
    sbd_export_rebuild "$stage"
}
native_pair_and_export() {
    t_seed
    t_run 0 sbd_apply export_fixture
    t_run 0 sbd_check_config
    t_run 0 sbd_validate_schema "$SBD_EXPORTS/schema.json" "$SBD_EXPORTS/fixture-node.json"
    t_run 0 "$SBD_BINARY" check -c "$SBD_EXPORTS/fixture-node.json" -D "$CASE_TMP"
    t_assert '客户端使用 NAT 对外端口而非监听端口' jq -e '.outbounds[0].server_port==24443 and .outbounds[0].server=="2001:db8::1"' "$SBD_EXPORTS/fixture-node.json"
    t_assert '客户端无私钥/服务端路径且带公钥信任' jq -e '.outbounds[0].tls | has("certificate_public_key_sha256") and (has("key_path")|not) and (has("certificate_path")|not) and (has("insecure")|not)' "$SBD_EXPORTS/fixture-node.json"
    t_assert '客户端不擅自创建监听或 TUN' jq -e '(.inbounds // [])==[]' "$SBD_EXPORTS/fixture-node.json"
    t_contains "$SBD_EXPORTS/links.txt" '24443'
    t_contains "$SBD_EXPORTS/fixture-node.txt" '[2001:db8::1]:24443?'
    t_contains "$SBD_EXPORTS/fixture-node.txt" 'sni=node.example.com'
    t_contains "$SBD_EXPORTS/fixture-node.txt" 'security=tls'
    t_contains "$SBD_EXPORTS/fixture-node.txt" '#%E5%AF%BC%E5%87%BA%20fixture'
    t_absent "$SBD_EXPORTS/fixture-node.txt" ':24443/?'
}
shared_provider() {
    t_seed
    make_shared() {
        local stage="$1" content
        sbd_tls_provider_add "$stage" shared example.com admin@example.com '{"provider":"cloudflare","api_token":"fixture-token"}' || return 1
        attach_tls "$stage" provider shared || return 1
        content=$(jq '.inbounds += [(.inbounds[0] | .tag="second" | .listen_port=18444)]' "$stage/config.json") || return 1
        sbd_record_write "$stage/config.json" "$content"
    }
    t_run 0 sbd_apply make_shared
    t_assert '两个原生 inbound 共用新式 provider' jq -e '.inbounds | length==2 and all(.[]; .tls.certificate_provider=="shared" and (.tls|has("acme")|not))' "$SBD_CONFIG"
    cp "$SBD_CONFIG" "$CASE_TMP/shared-config" || exit 1
    t_run 1 sbd_apply sbd_tls_remove provider shared
    t_contains "$CASE_TMP/output" '仍被引用'
    t_assert '不留下悬空 provider 引用' cmp -s "$SBD_CONFIG" "$CASE_TMP/shared-config"
    t_assert 'check 未发起签发或写 ACME 缓存' test ! -e "$SBD_CERT_DIR/acme"
}
material_state_failure() {
    t_seed
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_apply create_and_attach
    t_assert '真实到达提交后期' test -f "$CASE_TMP/failed"
    t_unchanged
    t_assert 'state 失败不遗留证书/私钥' test -z "$(find "$SBD_CERT_DIR" -mindepth 1 -maxdepth 1 -type d)"
}
retirement_failure() {
    t_seed
    t_run 0 sbd_apply sbd_tls_material_add self_signed 192.0.2.1
    local id directory
    id=$(jq -r '.tls.certificates[0].id' "$SBD_REGISTRY")
    directory=$(jq -r '.tls.certificates[0].directory' "$SBD_REGISTRY")
    t_run 0 sbd_apply sbd_tls_remove certificate "$id"
    rm() { [[ "${!#}" != "$directory" ]] || return 1; command rm "$@"; }
    t_run 1 sbd_apply t_edit_debug
    t_assert '回收失败已接受事实不逆转' jq -e '.phase=="accepted"' "$SBD_WORK/active/journal.json"
    t_assert '回收失败保留材料' test -s "$directory/key.pem"
    unset -f rm
    t_run 0 sbd_recover
    t_assert '恢复只重试收尾并清理无引用材料' test ! -e "$directory"
    t_assert '恢复不回退已接受配置' jq -e '.log.level=="debug"' "$SBD_CONFIG"
}
t_case '真实 TLS 文件路径与客户端 Schema/check、原子导出对齐' native_pair_and_export
t_case '共享 ACME provider 原生引用且禁止带引用删除' shared_provider
t_case 'state 失败同时回滚配置/元数据/证书私钥' material_state_failure
t_case '材料回收失败明确失败并可重试收尾' retirement_failure
t_finish
