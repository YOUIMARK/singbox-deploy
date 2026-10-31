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
    t_assert 'check 未发起签发或写 ACME 缓存' test ! -e "$SBD_DATA/acme"
}
material_failure() {
    t_seed
    openssl() { [[ "$1" != req ]] || return 1; command openssl "$@"; }
    t_run 1 sbd_apply create_and_attach
    t_unchanged
    t_assert '生成失败回收独立材料' test -z "$(find "$SBD_DATA/certificates" -mindepth 1 -maxdepth 1 -type d)"
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
    t_assert 'state 失败不遗留证书/私钥' test -z "$(find "$SBD_DATA/certificates" -mindepth 1 -maxdepth 1 -type d)"
}
material_kill() {
    t_seed
    mv() {
        if [[ "${!#}" = "$SBD_STATE" ]]; then kill -KILL "$BASHPID"; fi
        command mv "$@"
    }
    t_run 137 sbd_apply create_and_attach
    t_assert '未完成事务已登记独立材料' jq -e '.created_materials|length==1' "$SBD_WORK/active/journal.json"
    unset -f mv
    t_run 0 sbd_recover
    t_unchanged
    t_assert '强杀恢复后无新材料' test -z "$(find "$SBD_DATA/certificates" -mindepth 1 -maxdepth 1 -type d)"
}
retirement_contract() {
    t_seed
    t_run 0 sbd_apply sbd_tls_material_add self_signed 192.0.2.1
    local id directory
    id=$(jq -r '.tls.certificates[0].id' "$SBD_REGISTRY")
    directory=$(jq -r '.tls.certificates[0].directory' "$SBD_REGISTRY")
    t_run 0 sbd_apply sbd_tls_remove certificate "$id"
    t_assert '最近恢复源仍可读旧证书' test -s "$directory/cert.pem"
    t_run 0 sbd_apply t_edit_debug
    t_assert '下一成功变更淘汰无引用旧材料' test ! -e "$directory"
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
certificate_references() {
    t_seed
    t_run 0 sbd_apply create_and_attach
    local id
    id=$(jq -r '.tls.certificates[0].id' "$SBD_REGISTRY")
    cp "$SBD_REGISTRY" "$CASE_TMP/registry-copy" || exit 1
    t_run 1 sbd_apply sbd_tls_remove certificate "$id"
    t_contains "$CASE_TMP/output" '仍被引用'
    t_assert '引用阻止删除元数据' cmp -s "$SBD_REGISTRY" "$CASE_TMP/registry-copy"
}
export_failure() {
    t_seed
    t_run 0 sbd_apply export_fixture
    cp -a "$SBD_EXPORTS" "$CASE_TMP/export-before" || exit 1
    cp "$SBD_STATE" "$CASE_TMP/state-before" || exit 1
    corrupt() {
        local content
        content=$(jq '.nodes[0].client.server=null' "$1/registry.json") || return 1
        sbd_record_write "$1/registry.json" "$content" || return 1
        sbd_export_rebuild "$1"
    }
    t_run 1 sbd_apply corrupt
    t_assert '缺值保留已提交客户端配置' cmp -s "$SBD_EXPORTS/fixture-node.json" "$CASE_TMP/export-before/fixture-node.json"
    t_assert '缺值保留旧分享清单' cmp -s "$SBD_EXPORTS/links.txt" "$CASE_TMP/export-before/links.txt"
    t_assert '失败不提交新 state' cmp -s "$SBD_STATE" "$CASE_TMP/state-before"
    missing_auth() {
        local content
        content=$(jq 'del(.nodes[0].client.password)' "$1/registry.json") || return 1
        sbd_record_write "$1/registry.json" "$content" || return 1
        sbd_export_rebuild "$1"
    }
    t_run 1 sbd_apply missing_auth
    t_assert '认证缺失保留旧清单' cmp -s "$SBD_EXPORTS/links.txt" "$CASE_TMP/export-before/links.txt"
    sbd_share_anytls() { _error 'fixture adapter failure'; return 1; }
    t_run 1 sbd_apply sbd_export_rebuild
    t_assert '适配器失败仍保留旧清单' cmp -s "$SBD_EXPORTS/links.txt" "$CASE_TMP/export-before/links.txt"
}
export_write_failure() {
    t_seed
    cp() {
        if [[ "${!#}" = */exports-next/fixture-node.json ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command cp "$@"
    }
    t_run 1 sbd_apply export_fixture
    t_assert '真实到达导出写入' test -f "$CASE_TMP/failed"
    t_unchanged
    t_assert '输出失败回收新证书' test -z "$(find "$SBD_DATA/certificates" -mindepth 1 -maxdepth 1 -type d)"
}
export_state_failure() {
    t_seed
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_apply export_fixture
    t_assert '导出发布后 state 确实失败' test -f "$CASE_TMP/failed"
    t_unchanged
    t_assert 'state 失败不留下新客户端资料' test ! -e "$SBD_EXPORTS/fixture-node.json"
    t_assert 'state 失败回收成对新材料' test -z "$(find "$SBD_DATA/certificates" -mindepth 1 -maxdepth 1 -type d)"
}
export_schema_failure() {
    t_seed
    invalid_client() {
        export_fixture "$1" || return 1
        local content
        content=$(jq '.nodes[0].client.tls.certificate_sha256=["not-1.14"]' "$1/registry.json") || return 1
        sbd_record_write "$1/registry.json" "$content" || return 1
        # 第一次重建的临时目录是同一次候选的一部分，不触及活跃导出。
        rm -rf -- "$1/export-work" || return 1
        sbd_export_rebuild "$1"
    }
    t_run 1 sbd_apply invalid_client
    t_contains "$CASE_TMP/output" Schema
    t_unchanged
}
busybox_readlink() {
    t_seed
    # BusyBox 的 readlink 只认 -f/-n/-v；-f 还要求路径已存在，材料登记时目录尚未创建。
    readlink() {
        case "$1" in
            -m) printf 'readlink: unrecognized option: m\n' >&2; return 1 ;;
            -f) [[ -e "${!#}" ]] || return 1; command readlink "$@" ;;
            *) command readlink "$@" ;;
        esac
    }
    t_run 0 sbd_apply create_and_attach
    t_assert '材料目录已登记' jq -e '.tls.certificates|length==1' "$SBD_REGISTRY"
    t_assert '证书材料已生成' test -f "$(jq -r '.tls.certificates[0].certificate_path' "$SBD_REGISTRY")"
}
material_negative_control() {
    t_seed
    local path="$CASE_TMP/outside"
    mkdir "$path" || exit 1
    t_run 1 sbd_material_note created_materials "$path"
    t_assert '不能登记或回收范围外目录' test -d "$path"
}
t_case '真实 TLS 文件路径与客户端 Schema/check、原子导出对齐' native_pair_and_export
t_case '共享 ACME provider 原生引用且禁止带引用删除' shared_provider
t_case 'OpenSSL 生成失败不遗留材料和元数据' material_failure
t_case 'state 失败同时回滚配置/元数据/证书私钥' material_state_failure
t_case 'SIGKILL 后恢复独立证书材料' material_kill
t_case '无引用材料随最近恢复源保留与淘汰' retirement_contract
t_case '材料回收失败明确失败并可重试收尾' retirement_failure
t_case '服务端证书活跃引用禁止删除' certificate_references
t_case '缺值和适配器失败保留旧客户端与链接' export_failure
t_case '输出文件写失败不提交节点事实或材料' export_write_failure
t_case '导出发布后 state 失败恢复整组旧事实' export_state_failure
t_case '导出真实 Schema 拒绝 1.15 证书字段' export_schema_failure
t_case 'BusyBox readlink 兼容' busybox_readlink
t_case '证书回收路径负向对照' material_negative_control
t_finish
