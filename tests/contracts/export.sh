#!/usr/bin/env bash
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/entries.sh"

uri_contract() {
    local auth
    auth=$(sbd_uri_escape 'p@ss:/?# &+中文=') || exit 1
    sbd_uri_build anytls "$auth" 2001:db8::1 00443 '{"sni":"cdn.example.com","security":"reality","pbk":"a+b/c=","sid":"00"}' '中文 节点/#' > "$CASE_TMP/uri" || exit 1
    t_run 0 python3 - "$CASE_TMP/uri" <<'PY'
import sys
from urllib.parse import urlsplit, unquote, parse_qs
u = urlsplit(open(sys.argv[1]).read().strip())
assert u.scheme == "anytls" and u.hostname == "2001:db8::1" and u.port == 443
assert u.path == "/"
assert unquote(u.username) == "p@ss:/?# &+中文="
assert unquote(u.fragment) == "中文 节点/#"
assert parse_qs(u.query) == {"sni":["cdn.example.com"],"security":["reality"],"pbk":["a+b/c="],"sid":["00"]}
PY
    t_run 1 sbd_uri_build anytls '' host 443 '{}' name
    t_run 1 sbd_uri_build anytls password host 0 '{}' name
    t_run 1 sbd_uri_build anytls password host 443 '{"sni":null}' name
    t_run 1 sbd_uri_build anytls password '[2001:db8::1]' 443 '{}' name
    t_run 1 sbd_uri_build anytls 'raw@password' host 443 '{}' name
    t_run 1 sbd_uri_build anytls 'bad%escape' host 443 '{}' name
}
metadata_contract() {
    printf '{"format":1,"nodes":[{"id":"node1","name":"fixture","profile":"anytls","inbound_tag":"in1","client":{"type":"anytls","server":"example.com","server_port":443,"password":"fixture-password"}}]}' > "$CASE_TMP/registry" || exit 1
    t_run 0 sbd_export_metadata_check "$CASE_TMP/registry"
    local expression
    for expression in 'del(.nodes[0].name)' 'del(.nodes[0].client.password)' '.nodes[0].client.server=null' '.nodes[0].id="../outside"' '.nodes[0].id="schema"' '.nodes[0].id="links"' '.nodes += .nodes' '.nodes[0].client.server_port=443.5'; do
        jq "$expression" "$CASE_TMP/registry" > "$CASE_TMP/bad" || exit 1
        t_run 1 sbd_export_metadata_check "$CASE_TMP/bad"
    done
}
empty_contract() {
    t_seed
    t_run 0 sbd_apply sbd_export_rebuild
    t_assert '空节点重建清除旧派生文件' test ! -e "$SBD_EXPORTS/node.txt"
    t_assert '空分享清单存在' test -f "$SBD_EXPORTS/links.txt"
    t_assert '空节点不伪造链接' test ! -s "$SBD_EXPORTS/links.txt"
    t_assert '重建参与状态提交' jq -e '.revision==1' "$SBD_STATE"
}
unsupported_contract() {
    printf '{"profile":"unknown"}' > "$CASE_TMP/node.json" || exit 1
    t_run 1 sbd_share_build "$CASE_TMP/node.json"
    t_contains "$CASE_TMP/output" '未知分享配置档'
    t_absent "$CASE_TMP/output" '://'
}
menu_contract() {
    t_seed
    t_run 0 sbd_export_menu <<< 0
    t_run 0 sbd_export_menu < /dev/null
    t_run 0 sbd_export_menu <<< $'1\nn\n0'
    t_unchanged
    t_run 1 sbd_export_menu <<< 2
}
reality_required_metadata() {
    t_seed
    t_entry_add anyreality
    jq '.nodes[0]' "$SBD_REGISTRY" > "$CASE_TMP/node.json" || exit 1
    local expression
    for expression in 'del(.client.password)' 'del(.client.tls.server_name)' 'del(.client.tls.reality.public_key)' 'del(.client.tls.reality.short_id)' '.client.tls.utls.enabled=false'; do
        jq "$expression" "$CASE_TMP/node.json" > "$CASE_TMP/bad.json" || exit 1
        t_run 1 sbd_share_build "$CASE_TMP/bad.json"
        t_absent "$CASE_TMP/output" 'anytls://'
        t_contains "$CASE_TMP/output" '[错误]'
    done
}
certificate_and_obfs_metadata() {
    t_seed
    t_entry_add hysteria2
    jq '.nodes[0]' "$SBD_REGISTRY" > "$CASE_TMP/node.json" || exit 1
    local expression
    for expression in 'del(.share.certificate_sha256)' '.share.certificate_sha256="a-public-key-pin"' '.client.obfs={type:"unknown",password:"x"}' '.client.obfs={type:"gecko",password:"x",min_packet_size:1300,max_packet_size:600}'; do
        jq "$expression" "$CASE_TMP/node.json" > "$CASE_TMP/bad.json" || exit 1
        t_run 1 sbd_share_build "$CASE_TMP/bad.json"
        t_absent "$CASE_TMP/output" 'hysteria2://'
    done
}
t_case '统一 URI 编码、IPv6、端口规范化和扩展参数回读' uri_contract
t_case '节点元数据缺值与重复明确失败' metadata_contract
t_case '空登记经过真实事务清空派生输出' empty_contract
t_case '未知配置档明确失败而非伪造链接' unsupported_contract
t_case '导出菜单取消不改原文件' menu_contract
t_case 'AnyReality 必需元数据缺失不输出死链接' reality_required_metadata
t_case '证书指纹和混淆缺值不伪造 Hysteria2 URI' certificate_and_obfs_metadata
t_finish
