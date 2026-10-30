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
ss_network() {
    t_seed
    local spec
    spec=$(jq '.network="tcp"' "$ROOT/tests/fixtures/entry-shadowsocks.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    local id
    id=$(jq -r '.nodes[0].id' "$SBD_REGISTRY") || exit 1
    spec=$(jq '.listen_port=19504' "$ROOT/tests/fixtures/entry-hysteria2.json") || exit 1
    t_run 0 sbd_apply sbd_entry_create "$spec"
    t_entry_save
    t_run 1 sbd_apply sbd_entry_change "$id" ss '{"method":"aes-256-gcm","password":"x","network":"both"}'
    t_entry_unchanged
    spec=$(jq '.listen_port=19504' "$ROOT/tests/fixtures/entry-shadowsocks.json") || exit 1
    t_run 1 sbd_apply sbd_entry_create "$spec"
    t_entry_unchanged
}
kernel_udp() {
    t_seed
    python3 - "$CASE_TMP/ready" <<'PY' &
import pathlib, socket, sys, time
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    s.bind(("127.0.0.1", 0))
    pathlib.Path(sys.argv[1]).write_text(str(s.getsockname()[1]))
    time.sleep(60)
PY
    local pid=$! n=0 port
    # shellcheck disable=SC2064
    trap "kill $pid 2>/dev/null; wait $pid 2>/dev/null || :" EXIT
    while [[ ! -s "$CASE_TMP/ready" && "$n" -lt 100 ]]; do sleep 0.01; n=$((n+1)); done
    t_assert '真实 UDP 进程就绪' test -s "$CASE_TMP/ready"
    port=$(cat "$CASE_TMP/ready") || exit 1
    t_run 0 sbd_entry_port "$SBD_CONFIG_DIR" 127.0.0.1 "$port" tcp
    t_run 1 sbd_entry_port "$SBD_CONFIG_DIR" 127.0.0.1 "$port" both
    t_contains "$CASE_TMP/output" '无法绑定 udp'
}
uuid_edits() {
    t_seed
    local profile id
    for profile in vmess_ws vless_ws vless_reality; do
        t_entry_add "$profile"; id="$NODE_ID"
        t_run 0 sbd_apply sbd_entry_change "$id" password 69e480fd-5918-468c-b730-7c7b8fa81b8b
        t_assert '认证修改服务端 UUID' jq -e --arg id "$id" 'any(.inbounds[]; .tag==$id and .users[0].uuid=="69e480fd-5918-468c-b730-7c7b8fa81b8b")' "$SBD_CONFIG"
        t_run 0 t_classic_uri
        t_entry_save
        t_run 1 sbd_apply sbd_entry_change "$id" password invalid
        t_entry_unchanged
    done
}
cdn_edits() {
    t_seed
    t_entry_add vmess_ws
    sbd_service_state() { printf 'running\n'; }
    sbd_service_restore() { printf '%s\n' "$1" >> "$CASE_TMP/actions"; }
    local value
    value=$(jq -c '.nodes[0] | .ingress + {server:"preferred.example.com",server_port:8443,origin_port:39505,path:.client.transport.path}' "$SBD_REGISTRY") || exit 1
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" cdn "$value"
    t_assert '只改前端/回源事实不重启' test ! -e "$CASE_TMP/actions"
    t_run 0 t_classic_uri
    value=$(jq '.host="new.example.com" | .path="/new path+中文"' <<< "$value") || exit 1
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" cdn "$value"
    t_contains "$CASE_TMP/actions" running
    t_assert '改路径不误改本地监听' jq -e '.inbounds[0].listen_port==19505 and .inbounds[0].transport.path=="/new path+中文"' "$SBD_CONFIG"
    t_run 0 t_classic_uri
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
        jq "$expression" <<< "$original" > "$SBD_CONFIG" || exit 1
        t_entry_save
        t_run 1 sbd_apply sbd_export_rebuild
        t_entry_unchanged
    done
}
ss_drift() {
    t_seed
    t_entry_add shadowsocks
    jq '.inbounds[0].method="aes-128-gcm"' "$SBD_CONFIG" > "$CASE_TMP/change" || exit 1
    cp "$CASE_TMP/change" "$SBD_CONFIG" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_export_rebuild
    t_entry_unchanged
}
vision_drift() {
    t_seed
    t_entry_add vless_reality
    jq '.nodes[0].client.tls.reality.public_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' "$SBD_REGISTRY" > "$CASE_TMP/change" || exit 1
    cp "$CASE_TMP/change" "$SBD_REGISTRY" || exit 1
    t_entry_save
    t_run 1 sbd_apply sbd_export_rebuild
    t_entry_unchanged
}
preserve_ws() {
    t_seed
    t_entry_add vless_ws
    jq '.inbounds[0].transport.headers={"X-Origin":"custom"} | .outbounds += [{type:"direct",tag:"custom"}]' "$SBD_CONFIG" > "$CASE_TMP/change" || exit 1
    cp "$CASE_TMP/change" "$SBD_CONFIG" || exit 1
    t_run 0 sbd_apply sbd_entry_change "$NODE_ID" password 69e480fd-5918-468c-b730-7c7b8fa81b8b
    t_assert '响应头和自定义出口不被覆盖' jq -e '.inbounds[0].transport.headers["X-Origin"]=="custom" and any(.outbounds[]; .tag=="custom")' "$SBD_CONFIG"
    t_run 0 t_classic_uri
}
unexpressible_ws() {
    t_seed
    t_entry_add vless_ws
    local expression original
    original=$(cat "$SBD_REGISTRY") || exit 1
    for expression in '.nodes[0].client.transport.headers["X-Required"]="must-keep"' '.nodes[0].client.transport.max_early_data=2048' 'del(.nodes[0].ingress.host)' 'del(.nodes[0].client.tls.server_name)'; do
        jq "$expression" <<< "$original" > "$SBD_REGISTRY" || exit 1
        t_entry_save
        t_run 1 sbd_apply sbd_export_rebuild
        t_entry_unchanged
    done
}
state_failure() {
    t_seed
    t_entry_add vless_ws
    t_entry_save
    mv() {
        if [[ "${!#}" = "$SBD_STATE" && ! -e "$CASE_TMP/failed" ]]; then : > "$CASE_TMP/failed"; return 1; fi
        command mv "$@"
    }
    t_run 1 sbd_apply sbd_entry_change "$NODE_ID" cdn '{"host":"new.example.com","origin_port":39506,"server":"new.example.com","server_port":8443,"path":"/new"}'
    t_assert '已走到真实 state 提交' test -f "$CASE_TMP/failed"
    t_entry_unchanged
}
semantic_failure() {
    t_seed
    invalid_short_id() {
        sbd_entry_create "$1" "$2" || return 1
        local content
        content=$(jq '.inbounds[0].tls.reality.short_id=["not-hex"]' "$1/config.json") || return 1
        sbd_record_write "$1/config.json" "$content"
    }
    t_run 1 sbd_apply invalid_short_id "$(cat "$ROOT/tests/fixtures/entry-vless_reality.json")"
    t_contains "$CASE_TMP/output" '核心语义检查失败'
    t_unchanged
}
ss_menu() {
    t_seed
    t_run 0 sbd_entry_create_prompt <<< $'4\n2\n2\n\n127.0.0.1\n19504\nexample.com\n29504\n菜单SS\ny'
    NODE_ID=$(jq -r '.nodes[0].id' "$SBD_REGISTRY") || exit 1
    t_run 0 t_classic_uri
    t_run 0 sbd_entry_change_prompt <<< $'1\n8\n3\n3\n\ny'
    t_assert 'SS 菜单真实换算法和网络' jq -e '.inbounds[0]|.method=="2022-blake3-chacha20-poly1305" and .network=="udp"' "$SBD_CONFIG"
    t_run 0 t_classic_uri
    t_run 0 sbd_entry_change_prompt <<< $'1\n2\n\ny'
    t_run 0 t_classic_uri
}
t_case 'SS 算法/网络/密钥/监听事务和错误保留' ss_edit
t_case 'SS 网络扩展检测已有 UDP 配置冲突' ss_network
t_case '双网络 SS 检测真实 UDP 进程占用' kernel_udp
t_case '三种 UUID 配置档真实认证更新' uuid_edits
t_case 'CDN 前端与回源独立、路径变动按需重启' cdn_edits
t_case 'VLESS Reality 重新生成密钥并保留 Vision' vision_rotate
t_case 'VMess UUID/路径/AEAD/early data 漂移拒绝' drift_contract
t_case 'SS 算法漂移保留全部旧文件' ss_drift
t_case 'VLESS Reality 公钥漂移保留旧导出' vision_drift
t_case '节点编辑保留合法 WS 响应头与自定义出口' preserve_ws
t_case 'WS URI 不丢额外请求参数或缺失事实' unexpressible_ws
t_case 'CDN 变更 state 提交失败整组回滚' state_failure
t_case '真实 Reality 语义失败不提交候选' semantic_failure
t_case 'SS 菜单三算法/网络和随机密钥编辑' ss_menu
t_finish
