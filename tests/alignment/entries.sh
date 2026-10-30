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
edit_listen() {
    t_seed
    t_entry_add hysteria2
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" listen '{"listen":"127.0.0.1","listen_port":19602}'
    t_assert '监听变更不覆盖映射事实' jq -e '.nodes[0].client.server_port==29502' "$SBD_REGISTRY"
    t_assert '实际监听端口已改变' jq -e '.inbounds[0].listen_port==19602' "$SBD_CONFIG"
}
network_collision() {
    t_seed
    t_entry_add hysteria2
    local spec
    spec=$(jq '.listen_port=19502' "$ROOT/tests/fixtures/entry-anytls.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    t_assert 'TCP/UDP 可使用同数字端口' jq -e '.inbounds|length==2 and all(.[]; .listen_port==19502)' "$SBD_CONFIG"
    t_entry_save
    t_run 1 sbd_apply sbd_entry_create "$spec"
    t_contains "$CASE_TMP/output" '端口已被占用'
    t_entry_unchanged
}
kernel_collision() {
    t_seed
    python3 - "$CASE_TMP/ready" <<'PY' &
import pathlib,socket,sys,time
with socket.socket() as s:
    s.bind(("127.0.0.1",0))
    s.listen()
    pathlib.Path(sys.argv[1]).write_text(str(s.getsockname()[1]))
    time.sleep(60)
PY
    local pid=$! n=0 port
    # 捕获固定测试子进程 PID，避免函数返回后 local 变量失效。
    # shellcheck disable=SC2064
    trap "kill $pid 2>/dev/null; wait $pid 2>/dev/null || :" EXIT
    while [[ ! -s "$CASE_TMP/ready" && "$n" -lt 100 ]]; do sleep 0.01; n=$((n+1)); done
    t_assert '占用进程真实就绪' test -s "$CASE_TMP/ready"
    port=$(cat "$CASE_TMP/ready") || exit 1
    t_run 1 sbd_entry_port "$SBD_CONFIG_DIR" 127.0.0.1 "$port" tcp
    t_contains "$CASE_TMP/output" '无法绑定'
    t_run 0 sbd_entry_port "$SBD_CONFIG_DIR" 127.0.0.1 "$port" udp
}
drift_password() {
    t_seed
    t_entry_add anytls
    jq '.inbounds[0].users[0].password="external-change" | .inbounds[0].padding_scheme=["stop=8"]' "$SBD_CONFIG" > "$CASE_TMP/drift" || exit 1
    cp "$CASE_TMP/drift" "$SBD_CONFIG" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_entry_change "$NODE_ID" password replace
    t_contains "$CASE_TMP/output" '不一致'
    t_entry_unchanged
}
preserve_custom() {
    t_seed
    t_entry_add anytls
    jq '.inbounds[0].padding_scheme=["stop=8"] | .outbounds += [{type:"direct",tag:"custom-direct"}]' "$SBD_CONFIG" > "$CASE_TMP/custom" || exit 1
    cp "$CASE_TMP/custom" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" password replace
    # 官方 format 将单元素 Listable 数组压成字符串；内容和自定义出口必须仍保留。
    t_assert '定点改凭据不覆盖合法自定义' jq -e '.inbounds[0].padding_scheme=="stop=8" and any(.outbounds[]; .tag=="custom-direct")' "$SBD_CONFIG"
}
reality_drift() {
    t_seed
    t_entry_add anyreality
    jq '.nodes[0].client.tls.reality.public_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' "$SBD_REGISTRY" > "$CASE_TMP/drift" || exit 1
    cp "$CASE_TMP/drift" "$SBD_REGISTRY" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_export_rebuild
    t_contains "$CASE_TMP/output" 'Reality 密钥'
    t_entry_unchanged
}
obfs_drift() {
    t_seed
    local spec
    spec=$(jq '.obfs={type:"salamander",password:"obfs"}' "$ROOT/tests/fixtures/entry-hysteria2.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    jq '.inbounds[0].obfs.password="changed"' "$SBD_CONFIG" > "$CASE_TMP/drift" || exit 1
    cp "$CASE_TMP/drift" "$SBD_CONFIG" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_export_rebuild
    t_contains "$CASE_TMP/output" '混淆'
    t_entry_unchanged
}
edit_hy2() {
    t_seed
    t_entry_add hysteria2
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" hy2 '{"server_options":{"up_mbps":20,"down_mbps":7},"client_options":{"up_mbps":4,"down_mbps":15},"obfs":{"type":"gecko","password":"obfs","min_packet_size":700,"max_packet_size":1400}}'
    t_run 0 t_entry_uri hysteria2
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" hy2 '{}'
    t_assert '切回 BBR 和无混淆清除旧字段' jq -e '.inbounds[0]|(has("up_mbps") or has("down_mbps") or has("obfs"))|not' "$SBD_CONFIG"
}
rotate_tls() {
    t_seed
    t_entry_add anytls
    local old_cert
    old_cert=$(jq -r '.nodes[0].certificate_id' "$SBD_REGISTRY")
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" tls '{"kind":"self_signed","server_name":"new.example.com","trust":"certificate"}'
    # jq 参数不由 Bash 展开。
    # shellcheck disable=SC2016
    t_assert '新证书替换引用但不擅删旧资料' jq -e --arg id "$old_cert" '.nodes[0].certificate_id!=$id and any(.tls.certificates[];.id==$id)' "$SBD_REGISTRY"
    t_run 0 t_entry_uri anytls
}
rotate_reality() {
    t_seed
    t_entry_add anyreality
    local public
    public=$(jq -r '.nodes[0].client.tls.reality.public_key' "$SBD_REGISTRY")
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" tls '{"kind":"reality","server_name":"new.example.com","handshake":{"server":"new.example.com","server_port":443}}'
    # shellcheck disable=SC2016
    t_assert '显式重置生成新密钥' jq -e --arg public "$public" '.nodes[0].client.tls.reality.public_key!=$public' "$SBD_REGISTRY"
    t_run 0 t_entry_uri anyreality
}
explicit_tls_refresh() {
    t_seed
    t_entry_add anytls
    local cert key source expected
    cert=$(jq -r '.tls.certificates[0].certificate_path' "$SBD_REGISTRY")
    key=$(jq -r '.tls.certificates[0].key_path' "$SBD_REGISTRY")
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=node.example.com -addext subjectAltName=DNS:node.example.com -keyout "$key" -out "$cert" >/dev/null 2>&1 || exit 1
    source=$(jq -c '.nodes[0].tls_source' "$SBD_REGISTRY") || exit 1
    t_run 1 sbd_apply sbd_entry_change "$NODE_ID" password 'must-not-overwrite'
    t_contains "$CASE_TMP/output" '信任发生漂移'
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" tls "$source"
    expected=$(sbd_tls_pin "$cert") || exit 1
    # shellcheck disable=SC2016
    t_assert '显式刷新后记录实际公钥事实' jq -e --arg pin "$expected" '.tls.certificates[0].public_key_sha256==$pin' "$SBD_REGISTRY"
    t_assert 'TLS 更新不改认证身份' jq -e '.inbounds[0].users[0].password=="p@ss:/?# &+中文="' "$SBD_CONFIG"
    t_run 0 t_entry_uri anytls
}
delete_node() {
    t_seed
    t_entry_add anytls
    local cert directory
    cert=$(jq -r '.nodes[0].certificate_id' "$SBD_REGISTRY")
    directory=$(jq -r '.tls.certificates[0].directory' "$SBD_REGISTRY")
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" delete ''
    t_assert '节点、原生 inbound 和派生输出同时移除' jq -e '.nodes==[]' "$SBD_REGISTRY"
    t_assert '原生 inbound 已删除' jq -e '(.inbounds // [])==[]' "$SBD_CONFIG"
    t_assert '删除节点不残留旧链接' test ! -e "$SBD_EXPORTS/$NODE_ID.txt"
    t_assert '共享/自有证书资料不会被连带删除' test -s "$directory/cert.pem"
    t_run 0 sbd_apply sbd_tls_remove certificate "$cert"
}
delete_referenced() {
    t_seed
    t_entry_add anytls
    jq --arg tag "$NODE_ID" '.route.rules=[{inbound:[$tag],action:"route",outbound:"direct"}]' "$SBD_CONFIG" > "$CASE_TMP/ref" || exit 1
    cp "$CASE_TMP/ref" "$SBD_CONFIG" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_entry_change "$NODE_ID" delete ''
    t_contains "$CASE_TMP/output" '仍被路由'
    t_entry_unchanged
}
delete_broken_tls() {
    t_seed
    t_entry_add anytls
    local cert key
    cert=$(jq -r '.tls.certificates[0].certificate_path' "$SBD_REGISTRY")
    key=$(jq -r '.tls.certificates[0].key_path' "$SBD_REGISTRY")
    rm -- "$cert" || exit 1
    t_run 1 sbd_apply sbd_entry_change "$NODE_ID" name cannot-update
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" delete ''
    t_assert '损坏 TLS 不阻止身份明确的节点删除' jq -e '.nodes==[]' "$SBD_REGISTRY"
    t_assert '删除节点不额外删除材料' test -s "$key"
    t_assert '删除后没有旧派生链接' test ! -e "$SBD_EXPORTS/$NODE_ID.txt"
}
shared_acme() {
    t_seed
    t_run 0 sbd_apply sbd_tls_provider_add shared '*.example.com' admin@example.com '{"provider":"cloudflare","api_token":"fixture"}'
    local spec
    spec=$(jq '.tls_source={kind:"provider",id:"shared",server_name:"node.example.com"}' "$ROOT/tests/fixtures/entry-anytls.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    spec=$(jq '.tls_source={kind:"provider",id:"shared",server_name:"hy2.example.com"}' "$ROOT/tests/fixtures/entry-hysteria2.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    t_assert '多个协议复用 provider，无旧 ACME 字段' jq -e 'all(.inbounds[];.tls.certificate_provider=="shared" and (.tls|has("acme")|not))' "$SBD_CONFIG"
    t_assert '离线检查不签发' test ! -e "$SBD_DATA/acme"
    t_entry_save
    t_run 1 sbd_apply sbd_tls_remove provider shared
    t_entry_unchanged
}
ed25519_compatibility() {
    t_seed
    local cert="$CASE_TMP/ed.pem" key="$CASE_TMP/ed-key.pem" id spec
    openssl req -x509 -newkey ed25519 -nodes -days 2 -subj /CN=ed.example.com -addext subjectAltName=DNS:ed.example.com -keyout "$key" -out "$cert" >/dev/null 2>&1 || exit 1
    t_run 0 sbd_apply sbd_tls_material_add import ed.example.com "$cert" "$key"
    id=$(jq -r '.tls.certificates[0].id' "$SBD_REGISTRY") || exit 1
    t_entry_save
    spec=$(jq --arg id "$id" '.tls_source={kind:"certificate",id:$id,trust:"pin"}' "$ROOT/tests/fixtures/entry-hysteria2.json") || exit 1
    t_run 1 sbd_apply sbd_entry_create "$spec"
    t_contains "$CASE_TMP/output" Ed25519
    t_entry_unchanged
    spec=$(jq --arg id "$id" '.tls_source={kind:"certificate",id:$id,trust:"pin"}' "$ROOT/tests/fixtures/entry-anytls.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    NODE_ID=$(jq -r '.nodes[0].id' "$SBD_REGISTRY")
    t_run 0 t_entry_uri anytls
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
    t_assert '失败回收新证书' test -z "$(find "$SBD_DATA/certificates" -mindepth 1 -maxdepth 1 -type d)"
}
native_schema_failure() {
    t_seed
    local spec
    spec=$(jq '.server_options={not_a_native_field:true}' "$ROOT/tests/fixtures/entry-hysteria2.json") || exit 1
    t_run 1 sbd_apply sbd_entry_create "$spec"
    t_contains "$CASE_TMP/output" Schema
    t_unchanged
}
kill_recovery() {
    t_seed
    mv() { if [[ "${!#}" = "$SBD_STATE" ]]; then kill -KILL "$BASHPID"; fi; command mv "$@"; }
    t_run 137 sbd_apply sbd_entry_create "$(cat "$ROOT/tests/fixtures/entry-anytls.json")"
    t_assert '强杀发生于节点事实已发布后' jq -e '.nodes|length==1' "$SBD_REGISTRY"
    unset -f mv
    t_run 0 sbd_recover
    t_unchanged
}
running_change() {
    t_seed
    t_entry_add anytls
    sbd_service_state() { printf 'running\n'; }
    sbd_service_restore() { printf '%s\n' "$1" >> "$CASE_TMP/service-actions"; }
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" name '只改名字'
    t_assert '改名只重建客户端资料，不重启' test ! -e "$CASE_TMP/service-actions"
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" password changed
    t_contains "$CASE_TMP/service-actions" running
}
t_case '改名/认证/映射统一重建且稳定 ID 不变' edit_identity
t_case '监听事实与 NAT 映射保持独立' edit_listen
t_case 'TCP/UDP 分开判断配置端口冲突' network_collision
t_case '真实进程占用检测与 UDP 分离' kernel_collision
t_case '外部认证漂移拒绝覆盖且保留旧导出' drift_password
t_case '定点节点编辑保留合法自定义配置' preserve_custom
t_case '真实 X25519 公私钥对齐拒绝漂移' reality_drift
t_case 'Hysteria2 混淆两侧漂移拒绝重建' obfs_drift
t_case '原生 Hysteria2 带宽/混淆修改与清除' edit_hy2
t_case 'TLS 更换统一重建客户端信任' rotate_tls
t_case 'AnyReality 显式密钥与目标重置' rotate_reality
t_case '显式更换 TLS 可更新已轮换来源而不绕过认证核对' explicit_tls_refresh
t_case '节点删除不连带删除证书资料' delete_node
t_case '引用中的 inbound 不能删除' delete_referenced
t_case '身份明确的节点可删除，即使旧 TLS 来源已损坏' delete_broken_tls
t_case 'Hy2/AnyTLS 共享原生 ACME provider' shared_acme
t_case 'Hysteria2 Chrome QUIC 证书限制不误套到 AnyTLS' ed25519_compatibility
t_case '创建节点 state 失败整组回滚' state_failure
t_case '真实官方 Schema 拒绝未知服务器字段' native_schema_failure
t_case '创建节点 SIGKILL 后统一恢复' kill_recovery
t_case '运行节点按配置实际变化决定重启' running_change
t_finish
