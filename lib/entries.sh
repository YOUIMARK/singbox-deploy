#!/usr/bin/env bash

sbd_entry_text() {
    jq -er "($2) | select(type==\"string\" and length>0)" "$1" || { _error "节点资料缺少 $3"; return 1; }
}

sbd_entry_new_id() {
    local stage="$1" id
    id=$(jq -r '.id // empty' "$stage/request.json") || { _error '读取待创建节点 ID 失败'; return 1; }
    if [[ -z "$id" ]]; then
        id=$(openssl rand -hex 8) || { _error '生成稳定节点 ID 失败'; return 1; }; id="node.$id"
    fi
    [[ "$id" =~ ^node\.[0-9a-f]{16}$ ]] || { _error '待创建节点 ID 无效'; return 1; }
    jq -e --arg id "$id" 'all(.nodes[];.id!=$id and .inbound_tag!=$id)' "$stage/registry.json" >/dev/null || { _error '节点 ID 已存在'; return 1; }
    printf '%s\n' "$id"
}

sbd_entry_submit() {
    local request="$1" id
    id=$(openssl rand -hex 8) || { _error '生成稳定节点 ID 失败'; return 1; }; id="node.$id"
    request=$(jq --arg id "$id" '.id=$id' <<< "$request") || { _error '构造创建请求失败'; return 1; }
    sbd_apply sbd_entry_create "$request" || return 1
    # 提前固定 ID，提交后只查看本次节点，不按“最后一条”猜测归属。
    SBD_NEW_ENTRY_ID="$id"
}

sbd_entry_host() { sbd_tls_identity "$1" >/dev/null 2>&1 || { _error '地址须为 DNS 名称或不带方括号的 IP'; return 1; }; }

sbd_entry_deliver() {
    sbd_success "节点与客户端资料已提交: $SBD_EXPORTS"
    sbd_export_node "$SBD_NEW_ENTRY_ID" link inline || { _error '节点已提交，但资料查看失败；未回滚已提交节点'; return 1; }
    sbd_ui_pause
}

sbd_entry_socket_available() {
    python3 - "$1" "$2" "$3" <<'PY'
import socket, sys
host, port, network = sys.argv[1], int(sys.argv[2]), sys.argv[3]
family = socket.AF_INET6 if ":" in host else socket.AF_INET
try:
    with socket.socket(family, socket.SOCK_DGRAM if network == "udp" else socket.SOCK_STREAM) as s:
        if network == "tcp":
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if family == socket.AF_INET6:
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        s.bind((host, port))
except OSError:
    raise SystemExit(1)
PY
}

sbd_entry_port() {
    local stage="$1" listen="$2" port="$3" network="$4" exclude="${5:-}" config="${6:-$1/config.json}" skip
    if [[ "$network" = both ]]; then
        sbd_entry_port "$stage" "$listen" "$port" tcp "$exclude" "$config" &&
            sbd_entry_port "$stage" "$listen" "$port" udp "$exclude" "$config"
        return $?
    fi
    skip=$(python3 - "$config" "$listen" "$port" "$network" "$exclude" <<'PY'
import ipaddress, json, sys
path, host, port, network, exclude = sys.argv[1:]
try:
    ipaddress.ip_address(host)
    config = json.load(open(path))
    bindings = config.get("inbounds", []) + config.get("endpoints", [])
    same = False
    for inbound in bindings:
        kind = inbound.get("type")
        nets = ["udp"] if kind in ("hysteria2", "hysteria", "tuic", "wireguard", "tailscale") else ["tcp", "udp"] if kind == "shadowsocks" else ["tcp"]
        if "network" in inbound:
            nets = inbound["network"] if isinstance(inbound["network"], list) else inbound["network"].split(",")
        address = inbound.get("listen", "::")
        if inbound.get("listen_port") != int(port) or network not in nets:
            continue
        if exclude and inbound.get("tag") == exclude:
            same = ipaddress.ip_address(address) == ipaddress.ip_address(host)
            continue
        a, b = ipaddress.ip_address(address), ipaddress.ip_address(host)
        overlaps = a == b or str(a) == "::" or str(b) == "::" or (a.version == b.version and (a.is_unspecified or b.is_unspecified))
        if overlaps:
            raise ValueError("binding conflict")
    print("same" if same else "probe")
except (ValueError, KeyError, TypeError):
    raise SystemExit(1)
PY
    ) || { _error '监听地址无效或同网络的配置端口已被占用'; return 1; }
    if [[ "$skip" != same ]] && ! sbd_entry_socket_available "$listen" "$port" "$network"; then
        _error "无法绑定 $network $listen:$port，请检查进程占用或本机地址"; return 1
    fi
}

sbd_entry_cert_sha() (
    set -o pipefail
    openssl x509 -in "$1" -outform DER | openssl dgst -sha256 -r | awk '{print $1}' || { _error '证书 SHA-256 生成失败'; return 1; }
)

sbd_entry_public_key() {
    local key="$1" stage="$2"
    python3 - "$key" "$stage/reality-private.der" <<'PY' || { _error 'Reality 私钥格式无效'; return 1; }
import base64, pathlib, sys
try:
    key = base64.urlsafe_b64decode(sys.argv[1] + "=" * (-len(sys.argv[1]) % 4))
    if len(key) != 32:
        raise ValueError()
    pathlib.Path(sys.argv[2]).write_bytes(bytes.fromhex("302e020100300506032b656e04220420") + key)
except ValueError:
    raise SystemExit(1)
PY
    if ! openssl pkey -inform DER -in "$stage/reality-private.der" -pubout -outform DER > "$stage/reality-public.der" 2>/dev/null; then
        _error 'Reality 私钥无法导出公钥'; return 1
    fi
    python3 - "$stage/reality-public.der" <<'PY' || { _error 'Reality 公钥编码无法识别'; return 1; }
import base64, pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
if not data.startswith(bytes.fromhex("302a300506032b656e032100")) or len(data) != 44:
    raise SystemExit(1)
print(base64.urlsafe_b64encode(data[-32:]).decode().rstrip("="))
PY
}

sbd_entry_provider_name() {
    python3 - "$1" "$2" <<'PY' || { _error 'SNI 不在 provider 的签发域名内'; return 1; }
import json, sys
domains = json.loads(sys.argv[1]).get("domain", [])
if isinstance(domains, str):
    domains = [domains]
name = sys.argv[2].lower()
valid = any(name == d.lower() or (d.startswith("*.") and name.endswith(d[1:].lower()) and name.count(".") == d.count(".")) for d in domains)
raise SystemExit(0 if valid else 1)
PY
}

sbd_entry_tls() {
    local stage="$1" source="$2" kind id name trust cert sha private public short content provider pin
    sbd_record_write "$stage/tls-source.json" "$source" || return 1
    kind=$(sbd_entry_text "$stage/tls-source.json" .kind TLS来源) || return 1
    case "$kind" in
        self_signed)
            name=$(sbd_entry_text "$stage/tls-source.json" .server_name 证书名称) || return 1
            sbd_tls_material_add "$stage" self_signed "$name" || return 1
            id=$(jq -er '.tls.certificates[-1].id' "$stage/registry.json") || return 1
            trust=$(jq -r '.trust // "pin"' "$stage/tls-source.json") || return 1
            source=$(jq -n --arg id "$id" --arg trust "$trust" '{kind:"certificate",id:$id,trust:$trust}') || return 1
            ;;
        certificate|provider) ;;
        reality)
            name=$(sbd_entry_text "$stage/tls-source.json" .server_name SNI) || return 1
            sbd_entry_host "$name" || return 1
            # 握手目标属于 config；registry 只保留 TLS 来源种类和客户端事实。
            sbd_record_write "$stage/source-facts.json" '{"kind":"reality"}' || return 1
            "$SBD_BINARY" generate reality-keypair > "$stage/reality-keys" || { _error '核心生成 Reality 密钥失败'; return 1; }
            private=$(awk -F': ' 'tolower($1) ~ /^private/ {print $2}' "$stage/reality-keys")
            public=$(awk -F': ' 'tolower($1) ~ /^public/ {print $2}' "$stage/reality-keys")
            short=$("$SBD_BINARY" generate rand --hex 8) || { _error '核心生成 short_id 失败'; return 1; }
            [[ -n "$private" && -n "$public" && "$short" =~ ^[0-9a-f]{16}$ ]] || { _error '核心密钥输出不完整'; return 1; }
            content=$(jq -n --arg name "$name" --arg key "$private" --arg short "$short" --argjson source "$source" \
                '{enabled:true,server_name:$name,reality:{enabled:true,handshake:$source.handshake,private_key:$key,short_id:[$short]}}') || return 1
            sbd_record_write "$stage/source-server.json" "$content" || return 1
            content=$(jq -n --arg name "$name" --arg key "$public" --arg short "$short" \
                '{enabled:true,server_name:$name,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$key,short_id:$short}}') || return 1
            sbd_record_write "$stage/source-client.json" "$content" || return 1
            sbd_record_write "$stage/source-share.json" '{}'
            return $?
            ;;
        *) _error '未知 TLS 来源'; return 1 ;;
    esac
    sbd_record_write "$stage/source-facts.json" "$source" || return 1
    id=$(sbd_entry_text "$stage/source-facts.json" .id TLS标识) || return 1
    sbd_tls_server "$stage" "$(jq -r '.kind' "$stage/source-facts.json")" "$id" > "$stage/source-server.json" || return 1
    if [[ "$(jq -r '.kind' "$stage/source-facts.json")" = certificate ]]; then
        trust=$(sbd_entry_text "$stage/source-facts.json" .trust 信任方式) || return 1
        sbd_tls_client "$stage" "$id" "$trust" > "$stage/source-client.json" || return 1
        cert=$(jq -er --arg id "$id" '.tls.certificates[]|select(.id==$id)|.certificate_path' "$stage/registry.json") || return 1
        pin=$(sbd_tls_pin "$cert") || return 1
        content=$(jq --arg id "$id" --arg pin "$pin" '(.tls.certificates[]|select(.id==$id)|.public_key_sha256)=$pin' "$stage/registry.json") || return 1
        sbd_record_write "$stage/registry.json" "$content" || return 1
        if [[ "$trust" = pin || "$trust" = certificate ]]; then
            sha=$(sbd_entry_cert_sha "$cert") || return 1
            content=$(jq -n --arg sha "$sha" '{certificate_sha256:$sha}') || return 1
        else content='{}'; fi
    else
        name=$(sbd_entry_text "$stage/source-facts.json" .server_name SNI) || return 1
        sbd_entry_host "$name" || return 1
        provider=$(jq -c --arg id "$id" '.certificate_providers[] | select(.tag==$id)' "$stage/config.json") || return 1
        sbd_entry_provider_name "$provider" "$name" || return 1
        content=$(jq -n --arg name "$name" '{enabled:true,server_name:$name}') || return 1
        sbd_record_write "$stage/source-client.json" "$content" || return 1
        content='{}'
    fi
    sbd_record_write "$stage/source-share.json" "$content"
}

sbd_entry_lookup() {
    local stage="$1" id="$2"
    jq -ce --arg id "$id" '[.nodes[] | select(.id==$id)] | select(length==1) | .[0]' "$stage/registry.json" > "$stage/entry-node.json" || { _error '未找到唯一节点元数据'; return 1; }
}

sbd_entry_align() {
    local stage="$1" node="$2" scope="${3:-all}" profile kind id expected value key public sha cert provider
    profile=$(sbd_entry_text "$node" .profile 配置档) || return 1
    case "$profile" in
        hysteria2|anytls|anyreality) ;;
        shadowsocks|vmess_ws|vless_ws|vless_reality) sbd_entry_align_classic "$stage" "$node" "$scope"; return $? ;;
        *) _error '未知托管配置档'; return 1 ;;
    esac
    jq -ce --slurpfile node "$node" '[.inbounds[]? | select(.tag==$node[0].inbound_tag)] | select(length==1) | .[0]' "$stage/config.json" > "$stage/entry-inbound.json" || { _error '节点 inbound 缺失或重复'; return 1; }
    if ! jq -e --arg scope "$scope" --slurpfile node "$node" '
        .type==$node[0].client.type and (.users|length==1) and .users[0].password==$node[0].client.password and
        (if $scope=="delete" then true else .tls.enabled==true and $node[0].client.tls.enabled==true and
        (if .type=="hysteria2" then (.obfs // null)==($node[0].client.obfs // null) and
            (if .ignore_client_bandwidth==true then
                (((.up_mbps // 0)>0 or (.down_mbps // 0)>0)==(($node[0].client.up_mbps // 0)>0 and ($node[0].client.down_mbps // 0)>0))
             else true end) else true end) end)
    ' "$stage/entry-inbound.json" >/dev/null; then _error '节点认证、TLS、混淆或带宽策略与元数据不一致，请先显式协调'; return 1; fi
    # 删除核对身份和存活引用，不要求即将移除的过期/损坏证书仍能加载。
    [[ "$scope" != delete ]] || return 0
    jq -e '(.tls.client_authentication // "no")=="no" and ((.tls.ech.enabled // false)|not)' "$stage/entry-inbound.json" >/dev/null || { _error '此节点附带未登记的 TLS 客户端认证或 ECH，无法完整重建客户端资料'; return 1; }
    # 明确更换 TLS 时允许替换已过期/轮换的旧来源，但不绕过节点身份与认证核对。
    [[ "$scope" != replace_tls ]] || return 0
    kind=$(sbd_entry_text "$node" .tls_source.kind TLS来源) || return 1
    case "$kind" in
        reality)
            key=$(sbd_entry_text "$stage/entry-inbound.json" .tls.reality.private_key Reality私钥) || return 1
            public=$(sbd_entry_public_key "$key" "$stage") || return 1
            jq -e --arg public "$public" --slurpfile node "$node" '
                .tls.reality.enabled==true and .tls.server_name==$node[0].client.tls.server_name and
                ($node[0].client.tls.reality.public_key==$public) and $node[0].client.tls.reality.enabled==true and
                ((.tls.reality.short_id|if type=="array" then . else [.] end)|index($node[0].client.tls.reality.short_id)!=null)
            ' "$stage/entry-inbound.json" >/dev/null || { _error 'Reality 密钥、SNI 或 short_id 与元数据不一致'; return 1; }
            ;;
        certificate|provider)
            id=$(sbd_entry_text "$node" .tls_source.id TLS标识) || return 1
            expected=$(sbd_tls_server "$stage" "$kind" "$id") || return 1
            jq -e --argjson expected "$expected" '.tls | contains($expected) and ((.reality.enabled // false)|not)' "$stage/entry-inbound.json" >/dev/null || { _error '服务端 TLS 来源发生漂移'; return 1; }
            if [[ "$kind" = certificate ]]; then
                jq -e '(.tls|has("certificate_provider") or has("certificate") or has("key"))|not' "$stage/entry-inbound.json" >/dev/null || { _error '证书来源与其他 TLS 凭据混用，请先协调'; return 1; }
                expected=$(sbd_tls_client "$stage" "$id" "$(jq -r '.tls_source.trust' "$node")") || return 1
                jq -e --argjson expected "$expected" '.client.tls | contains($expected)' "$node" >/dev/null || { _error '客户端证书信任发生漂移'; return 1; }
                cert=$(jq -er --arg id "$id" '.tls.certificates[]|select(.id==$id)|.certificate_path' "$stage/registry.json") || return 1
                if [[ "$profile" = hysteria2 ]]; then
                    openssl x509 -in "$cert" -noout -text > "$stage/certificate-info" || { _error '证书算法读取失败'; return 1; }
                    if grep -q 'Public Key Algorithm: ED25519' "$stage/certificate-info"; then
                        _error '当前 Hysteria2 模板使用 Chrome QUIC，不能搭配 Ed25519 证书，请选择 RSA/ECDSA 证书'; return 1
                    fi
                fi
                if jq -e '.tls_source.trust=="pin" or .tls_source.trust=="certificate"' "$node" >/dev/null; then
                    sha=$(sbd_entry_cert_sha "$cert") || return 1
                    [[ "$(jq -r '.share.certificate_sha256' "$node")" = "$sha" ]] || { _error '分享证书指纹缺失或与当前证书不一致'; return 1; }
                fi
            else
                jq -e '(.tls|has("certificate_path") or has("key_path") or has("certificate") or has("key"))|not' "$stage/entry-inbound.json" >/dev/null || { _error 'provider 与其他 TLS 凭据混用，请先协调'; return 1; }
                value=$(sbd_entry_text "$node" .tls_source.server_name SNI) || return 1
                [[ "$(jq -r '.client.tls.server_name' "$node")" = "$value" ]] || { _error 'provider SNI 与客户端资料不一致'; return 1; }
                provider=$(jq -c --arg id "$id" '.certificate_providers[]|select(.tag==$id)' "$stage/config.json") || return 1
                sbd_entry_provider_name "$provider" "$value" || return 1
                if [[ "$profile" = hysteria2 && "$(jq -r '.key_type // "p256"' <<< "$provider")" = ed25519 ]]; then
                    _error '当前 Hysteria2 模板不能搭配 Ed25519 ACME provider，请选择 P-256/RSA 来源'; return 1
                fi
            fi
            ;;
        *) _error '未知节点 TLS 来源'; return 1 ;;
    esac
}

sbd_entry_uuid() {
    python3 - "$1" <<'PY' || { _error '请输入合法 UUID'; return 1; }
import sys, uuid
try:
    print(uuid.UUID(sys.argv[1]))
except ValueError:
    raise SystemExit(1)
PY
}

sbd_entry_ss_key() {
    local method="$1" password="$2"
    case "$method" in
        aes-256-gcm) [[ -n "$password" ]] || { _error 'Shadowsocks 密码不能为空'; return 1; } ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            python3 - "$password" <<'PY' || { _error 'SS2022 需要标准 Base64 编码的 32-byte 密钥'; return 1; }
import base64, binascii, sys
try:
    key = base64.b64decode(sys.argv[1], validate=True)
    if len(key) != 32:
        raise ValueError()
except (ValueError, binascii.Error):
    raise SystemExit(1)
PY
            ;;
        *) _error '仅支持已选的三个 Shadowsocks 算法'; return 1 ;;
    esac
}

sbd_entry_ws_path() {
    [[ "$1" = /* && "$1" != *$'\r'* && "$1" != *$'\n'* && "$1" != *'?'* && "$1" != *'#'* ]] || {
        _error 'WS path 须以 / 开头，填写路径而非含查询或片段的完整 URL'; return 1;
    }
}

sbd_entry_cdn() {
    local value="$1" host port path
    host=$(jq -er '.host | select(type=="string" and length>0)' <<< "$value") || { _error '缺少 CDN 域名'; return 1; }
    [[ "$(sbd_tls_identity "$host" 2>/dev/null)" = DNS:* ]] || { _error 'CDN Host 必须是域名'; return 1; }
    if ! port=$(jq -er '.origin_port' <<< "$value") || ! port=$(sbd_integer "$port" 1 65535); then
        _error '缺少有效的回源映射端口'; return 1
    fi
    path=$(jq -er '.path | select(type=="string" and length>0)' <<< "$value") || { _error '缺少 WS path'; return 1; }
    sbd_entry_ws_path "$path"
}

sbd_entry_create_classic() {
    local stage="$1" profile="$2" type network name listen port server external credential method='' uuid='' cdn='{}' source id content
    name=$(sbd_entry_text "$stage/request.json" .name 名称) && listen=$(sbd_entry_text "$stage/request.json" .listen 监听地址) &&
        server=$(sbd_entry_text "$stage/request.json" .server 对外地址) || return 1
    if ! port=$(jq -er '.listen_port' "$stage/request.json") || ! port=$(sbd_integer "$port" 1 65535) ||
        ! external=$(jq -er '.server_port' "$stage/request.json") || ! external=$(sbd_integer "$external" 1 65535); then _error '节点端口无效'; return 1; fi
    sbd_entry_host "$server" || return 1
    case "$profile" in
        shadowsocks)
            type=shadowsocks
            method=$(sbd_entry_text "$stage/request.json" .method 算法) && credential=$(sbd_entry_text "$stage/request.json" .password 密码) || return 1
            sbd_entry_ss_key "$method" "$credential" || return 1
            network=$(jq -r '.network // "both"' "$stage/request.json") || return 1
            case "$network" in both|tcp|udp) ;; *) _error 'Shadowsocks 监听网络无效'; return 1 ;; esac
            ;;
        vmess_ws|vless_ws|vless_reality)
            type=vless; [[ "$profile" != vmess_ws ]] || type=vmess
            network=tcp
            uuid=$(sbd_entry_text "$stage/request.json" .uuid UUID) && uuid=$(sbd_entry_uuid "$uuid") || return 1
            credential="$uuid"
            ;;
    esac
    sbd_entry_port "$stage" "$listen" "$port" "$network" || return 1
    if [[ "$profile" = vless_reality ]]; then
        source=$(jq -ce '.tls_source | select(.kind=="reality")' "$stage/request.json") || { _error 'VLESS+Reality 必须使用 Reality'; return 1; }
        sbd_entry_tls "$stage" "$source" || return 1
    else
        source='{"kind":"none"}'
        if [[ "$profile" = *_ws ]]; then
            cdn=$(jq -ce '.cdn' "$stage/request.json") || { _error '缺少 CDN 事实'; return 1; }
            sbd_entry_cdn "$cdn" || return 1
            cdn=$(jq --argjson port "$(sbd_integer "$(jq -r '.origin_port' <<< "$cdn")" 1 65535)" '.origin_port=$port' <<< "$cdn") || return 1
            source='{"kind":"cdn"}'
        fi
        sbd_record_write "$stage/source-server.json" '{}' && sbd_record_write "$stage/source-client.json" '{}' &&
            sbd_record_write "$stage/source-share.json" '{}' && sbd_record_write "$stage/source-facts.json" "$source" || return 1
    fi
    id=$(sbd_entry_new_id "$stage") || return 1
    content=$(jq -n --arg profile "$profile" --arg type "$type" --arg id "$id" --arg listen "$listen" --argjson port "$port" \
        --arg credential "$credential" --arg method "$method" --arg network "$network" --argjson cdn "$cdn" --slurpfile tls "$stage/source-server.json" '
        {type:$type,tag:$id,listen:$listen,listen_port:$port} +
        (if $profile=="shadowsocks" then {method:$method,password:$credential} + (if $network!="both" then {network:$network} else {} end)
         else {users:[{name:$id,uuid:$credential}]} + (if $profile=="vmess_ws" then {users:[{name:$id,uuid:$credential,alterId:0}]} else {} end) +
          (if $profile=="vless_reality" then {users:[{name:$id,uuid:$credential,flow:"xtls-rprx-vision"}],tls:$tls[0]}
           else {transport:{type:"ws",path:$cdn.path}} end) end)') || return 1
    sbd_record_write "$stage/new-inbound.json" "$content" || return 1
    content=$(jq --slurpfile inbound "$stage/new-inbound.json" '.inbounds=((.inbounds // [])+$inbound)' "$stage/config.json") || return 1
    sbd_record_write "$stage/config.json" "$content" || return 1
    content=$(jq -n --arg profile "$profile" --arg type "$type" --arg id "$id" --arg name "$name" --arg server "$server" --argjson port "$external" \
        --arg credential "$credential" --arg method "$method" --arg network "$network" --argjson cdn "$cdn" \
        --slurpfile tls "$stage/source-client.json" --slurpfile source "$stage/source-facts.json" '
        {id:$id,name:$name,profile:$profile,inbound_tag:$id,tls_source:$source[0],share:{},client:
          ({type:$type,server:$server,server_port:$port} +
           (if $profile=="shadowsocks" then {method:$method,password:$credential} + (if $network!="both" then {network:$network} else {} end)
            else {uuid:$credential} +
             (if $profile=="vless_reality" then {flow:"xtls-rprx-vision",tls:$tls[0]}
              else {tls:{enabled:true,server_name:$cdn.host},transport:{type:"ws",path:$cdn.path,headers:{Host:$cdn.host}}} +
                (if $profile=="vmess_ws" then {security:"auto",alter_id:0} else {} end) end) end))} +
        (if $profile=="vmess_ws" or $profile=="vless_ws" then {ingress:{type:"cdn",host:$cdn.host,origin_port:$cdn.origin_port}} else {} end)') || return 1
    sbd_record_write "$stage/entry-node.json" "$content" || return 1
    content=$(jq --slurpfile node "$stage/entry-node.json" '.nodes += $node' "$stage/registry.json") || return 1
    sbd_record_write "$stage/registry.json" "$content" || return 1
    sbd_export_rebuild "$stage"
}

sbd_entry_align_classic() {
    local stage="$1" node="$2" scope="$3" profile public key method password
    profile=$(sbd_entry_text "$node" .profile 配置档) || return 1
    jq -ce --slurpfile node "$node" '[.inbounds[]? | select(.tag==$node[0].inbound_tag)] | select(length==1) | .[0]' "$stage/config.json" > "$stage/entry-inbound.json" || { _error '节点 inbound 缺失或重复'; return 1; }
    if [[ "$profile" = shadowsocks ]]; then
        jq -e --slurpfile node "$node" '.type=="shadowsocks" and .password==$node[0].client.password and ((.users // [])|length==0) and ((.destinations // [])|length==0)' "$stage/entry-inbound.json" >/dev/null || { _error 'Shadowsocks 身份或单用户结构不一致'; return 1; }
        [[ "$scope" != delete ]] || return 0
        method=$(sbd_entry_text "$node" .client.method 算法) && password=$(sbd_entry_text "$node" .client.password 密码) || return 1
        sbd_entry_ss_key "$method" "$password" || return 1
        jq -e --slurpfile node "$node" '.method==$node[0].client.method and (.network // "both")==($node[0].client.network // "both")' "$stage/entry-inbound.json" >/dev/null || { _error 'Shadowsocks 算法或监听网络发生漂移'; return 1; }
        return 0
    fi
    jq -e --slurpfile node "$node" '.type==$node[0].client.type and (.users|length==1) and .users[0].uuid==$node[0].client.uuid' "$stage/entry-inbound.json" >/dev/null || { _error 'UUID 或原生协议与元数据不一致'; return 1; }
    [[ "$scope" != delete ]] || return 0
    if [[ "$profile" = *_ws ]]; then
        sbd_entry_cdn "$(jq -c '.ingress + {path:.client.transport.path}' "$node")" || return 1
        jq -e --slurpfile node "$node" '
            (has("tls")|not) and .transport.type=="ws" and .transport.path==$node[0].client.transport.path and
            $node[0].client.transport.type=="ws" and $node[0].client.tls.enabled==true and
            $node[0].client.tls.server_name==$node[0].ingress.host and $node[0].client.transport.headers.Host==$node[0].ingress.host and
            ((.transport.headers.Host // .transport.headers.host // "")=="") and
            (.transport.max_early_data // 0)==0 and (.transport.early_data_header_name // "")=="" and
            (if .type=="vmess" then (.users[0].alterId // 0)==0 and ($node[0].client.alter_id // 0)==0 and $node[0].client.security=="auto"
             else (.users[0].flow // "")=="" and ($node[0].client.flow // "")=="" end)
        ' "$stage/entry-inbound.json" >/dev/null || { _error 'CDN WS 回源、Host/SNI、路径或 AEAD/flow 发生漂移'; return 1; }
    else
        jq -e '(.tls.client_authentication // "no")=="no" and ((.tls.ech.enabled // false)|not)' "$stage/entry-inbound.json" >/dev/null || { _error '此节点附带未登记的客户端认证或 ECH'; return 1; }
        jq -e --slurpfile node "$node" '.users[0].flow=="xtls-rprx-vision" and $node[0].client.flow=="xtls-rprx-vision" and
            (has("transport")|not) and ($node[0].client|has("transport")|not)' "$stage/entry-inbound.json" >/dev/null || { _error 'VLESS Reality Vision 或原生 TCP 配置发生漂移'; return 1; }
        [[ "$scope" != replace_tls ]] || return 0
        key=$(sbd_entry_text "$stage/entry-inbound.json" .tls.reality.private_key Reality私钥) || return 1
        public=$(sbd_entry_public_key "$key" "$stage") || return 1
        jq -e --arg public "$public" --slurpfile node "$node" '.tls.enabled==true and .tls.reality.enabled==true and
            .tls.server_name==$node[0].client.tls.server_name and $node[0].client.tls.reality.public_key==$public and
            ((.tls.reality.short_id|if type=="array" then . else [.] end)|index($node[0].client.tls.reality.short_id)!=null)' "$stage/entry-inbound.json" >/dev/null || { _error 'VLESS Reality 密钥、SNI 或 short_id 发生漂移'; return 1; }
    fi
}

sbd_entry_create() {
    local stage="$1" spec="$2" profile type network name listen port server external password source id content
    sbd_record_write "$stage/request.json" "$spec" || return 1
    profile=$(sbd_entry_text "$stage/request.json" .profile 配置档) || return 1
    case "$profile" in
        shadowsocks|vmess_ws|vless_ws|vless_reality) sbd_entry_create_classic "$stage" "$profile"; return $? ;;
        hysteria2) type=hysteria2; network=udp ;;
        anytls|anyreality) type=anytls; network=tcp ;;
        *) _error '此协议尚未实现'; return 1 ;;
    esac
    name=$(sbd_entry_text "$stage/request.json" .name 名称) && listen=$(sbd_entry_text "$stage/request.json" .listen 监听地址) &&
        server=$(sbd_entry_text "$stage/request.json" .server 对外地址) && password=$(sbd_entry_text "$stage/request.json" .password 密码) || return 1
    if ! port=$(jq -er '.listen_port' "$stage/request.json") || ! port=$(sbd_integer "$port" 1 65535) ||
        ! external=$(jq -er '.server_port' "$stage/request.json") || ! external=$(sbd_integer "$external" 1 65535); then _error '节点端口无效'; return 1; fi
    sbd_entry_host "$server" && sbd_entry_port "$stage" "$listen" "$port" "$network" || return 1
    source=$(jq -ce '.tls_source' "$stage/request.json") || { _error '缺少 TLS 来源'; return 1; }
    if [[ "$profile" = anyreality ]]; then
        [[ "$(jq -r '.kind' <<< "$source")" = reality ]] || { _error 'AnyReality 必须使用 Reality'; return 1; }
    else
        [[ "$(jq -r '.kind' <<< "$source")" != reality ]] || { _error '普通 TLS 配置档不能混入 Reality'; return 1; }
    fi
    sbd_entry_tls "$stage" "$source" || return 1
    id=$(sbd_entry_new_id "$stage") || return 1
    content=$(jq -n --arg id "$id" --arg type "$type" --arg listen "$listen" --argjson port "$port" --arg password "$password" \
        --slurpfile tls "$stage/source-server.json" --slurpfile request "$stage/request.json" '
        (if $type=="hysteria2" then ($request[0].server_options // {}) else {} end) +
        {type:$type,tag:$id,listen:$listen,listen_port:$port,users:[{name:$id,password:$password}],tls:$tls[0]} +
        (if $type=="hysteria2" and $request[0].obfs!=null then {obfs:$request[0].obfs} else {} end)') || return 1
    sbd_record_write "$stage/new-inbound.json" "$content" || return 1
    content=$(jq --slurpfile inbound "$stage/new-inbound.json" '.inbounds=((.inbounds // []) + $inbound)' "$stage/config.json") || return 1
    sbd_record_write "$stage/config.json" "$content" || return 1
    content=$(jq -n --arg id "$id" --arg profile "$profile" --arg name "$name" --arg type "$type" --arg server "$server" --argjson port "$external" --arg password "$password" \
        --slurpfile tls "$stage/source-client.json" --slurpfile source "$stage/source-facts.json" --slurpfile share "$stage/source-share.json" --slurpfile request "$stage/request.json" '
        {id:$id,name:$name,profile:$profile,inbound_tag:$id,tls_source:$source[0],share:$share[0],client:
        ((if $type=="hysteria2" then ($request[0].client_options // {}) else {} end) +
         {type:$type,server:$server,server_port:$port,password:$password,tls:$tls[0]} +
         (if $type=="hysteria2" and $request[0].obfs!=null then {obfs:$request[0].obfs} else {} end))} +
        (if $source[0].kind=="certificate" then {certificate_id:$source[0].id} else {} end)') || return 1
    sbd_record_write "$stage/entry-node.json" "$content" || return 1
    content=$(jq --slurpfile node "$stage/entry-node.json" '.nodes += $node' "$stage/registry.json") || return 1
    sbd_record_write "$stage/registry.json" "$content" || return 1
    sbd_export_rebuild "$stage"
}

sbd_entry_change() {
    local stage="$1" id="$2" action="$3" value="$4" content tag source tls scope=all profile
    case "$action" in tls) scope=replace_tls ;; delete) scope=delete ;; esac
    sbd_entry_lookup "$stage" "$id" || return 1
    profile=$(sbd_entry_text "$stage/entry-node.json" .profile 配置档) || return 1
    case "$profile" in hysteria2|anytls|anyreality|shadowsocks|vmess_ws|vless_ws|vless_reality) ;; *) _error '此协议的节点操作尚未实现'; return 1 ;; esac
    sbd_entry_align "$stage" "$stage/entry-node.json" "$scope" || return 1
    tag=$(sbd_entry_text "$stage/entry-node.json" .inbound_tag inbound标识) || return 1
    case "$action" in
        name) [[ -n "$value" ]] || { _error '名称不能为空'; return 1; }; content=$(jq --arg value "$value" '.name=$value' "$stage/entry-node.json") || return 1 ;;
        password)
            [[ -n "$value" ]] || { _error '密码不能为空'; return 1; }
            case "$profile" in
                shadowsocks)
                    sbd_entry_ss_key "$(jq -r '.client.method' "$stage/entry-node.json")" "$value" || return 1
                    source=password; tls=password ;;
                vmess_ws|vless_ws|vless_reality) value=$(sbd_entry_uuid "$value") || return 1; source=uuid; tls=uuid ;;
                *) source=password; tls=password ;;
            esac
            content=$(jq --arg value "$value" --arg tag "$tag" --arg profile "$profile" --arg key "$source" '
                (.inbounds[] | select(.tag==$tag)) |= (if $profile=="shadowsocks" then .password=$value else .users[0][$key]=$value end)' "$stage/config.json") || return 1
            sbd_record_write "$stage/config.json" "$content" || return 1
            content=$(jq --arg value "$value" --arg key "$tls" '.client[$key]=$value' "$stage/entry-node.json") || return 1 ;;
        external)
            sbd_entry_host "$(jq -r '.server' <<< "$value")" || return 1
            source=$(sbd_integer "$(jq -r '.server_port' <<< "$value")" 1 65535) || { _error '映射端口无效'; return 1; }
            content=$(jq --argjson value "$value" --argjson port "$source" '.client.server=$value.server | .client.server_port=$port' "$stage/entry-node.json") || return 1 ;;
        listen)
            source=$(sbd_integer "$(jq -r '.listen_port' <<< "$value")" 1 65535) || { _error '监听端口无效'; return 1; }
            tls=tcp; [[ "$(jq -r '.profile' "$stage/entry-node.json")" != hysteria2 ]] || tls=udp
            [[ "$profile" != shadowsocks ]] || tls=$(jq -r '.client.network // "both"' "$stage/entry-node.json")
            sbd_entry_port "$stage" "$(jq -r '.listen' <<< "$value")" "$source" "$tls" "$tag" || return 1
            content=$(jq --argjson value "$value" --argjson port "$source" --arg tag "$tag" '(.inbounds[]|select(.tag==$tag)) |= (.listen=$value.listen | .listen_port=$port)' "$stage/config.json") || return 1
            sbd_record_write "$stage/config.json" "$content" || return 1
            content=$(cat "$stage/entry-node.json") || return 1 ;;
        hy2)
            [[ "$(jq -r '.profile' "$stage/entry-node.json")" = hysteria2 ]] || { _error '此节点不是 Hysteria2'; return 1; }
            content=$(jq --arg tag "$tag" --argjson value "$value" '(.inbounds[]|select(.tag==$tag)) |=
                (del(.obfs,.up_mbps,.down_mbps,.ignore_client_bandwidth) + ($value.server_options // {}) +
                (if $value.obfs!=null then {obfs:$value.obfs} else {} end))' "$stage/config.json") || return 1
            sbd_record_write "$stage/config.json" "$content" || return 1
            content=$(jq --argjson value "$value" '.client |= (del(.obfs,.up_mbps,.down_mbps) + ($value.client_options // {}) +
                (if $value.obfs!=null then {obfs:$value.obfs} else {} end))' "$stage/entry-node.json") || return 1 ;;
        tls)
            case "$profile" in shadowsocks|vmess_ws|vless_ws) _error '此配置档不使用源站 TLS，不能添加证书或 Reality'; return 1 ;; esac
            if [[ "$profile" = anyreality || "$profile" = vless_reality ]]; then
                [[ "$(jq -r '.kind' <<< "$value")" = reality ]] || { _error 'Reality 配置档必须使用 Reality'; return 1; }
            else
                [[ "$(jq -r '.kind' <<< "$value")" != reality ]] || { _error '普通 TLS 不能切换为 Reality 配置档'; return 1; }
            fi
            sbd_entry_tls "$stage" "$value" || return 1
            content=$(jq --arg tag "$tag" --slurpfile tls "$stage/source-server.json" '(.inbounds[]|select(.tag==$tag)|.tls) |=
                (del(.enabled,.certificate,.key,.certificate_path,.key_path,.certificate_provider,.reality,.server_name) + $tls[0])' "$stage/config.json") || return 1
            sbd_record_write "$stage/config.json" "$content" || return 1
            content=$(jq --slurpfile tls "$stage/source-client.json" --slurpfile source "$stage/source-facts.json" --slurpfile share "$stage/source-share.json" '
                .client.tls |= (del(.enabled,.server_name,.certificate,.certificate_path,.certificate_public_key_sha256,.reality,.utls,.insecure) + $tls[0]) |
                .tls_source=$source[0] | .share=$share[0] | del(.certificate_id) |
                if $source[0].kind=="certificate" then .certificate_id=$source[0].id else . end' "$stage/entry-node.json") || return 1 ;;
        ss)
            [[ "$profile" = shadowsocks ]] || { _error '此节点不是 Shadowsocks'; return 1; }
            sbd_entry_ss_key "$(jq -r '.method' <<< "$value")" "$(jq -r '.password' <<< "$value")" || return 1
            source=$(jq -r '.network // "both"' <<< "$value") || return 1
            case "$source" in tcp|udp|both) ;; *) _error 'Shadowsocks 监听网络无效'; return 1 ;; esac
            sbd_entry_port "$stage" "$(jq -r '.listen' "$stage/entry-inbound.json")" "$(jq -r '.listen_port' "$stage/entry-inbound.json")" "$source" "$tag" || return 1
            content=$(jq --arg tag "$tag" --argjson value "$value" --arg network "$source" '(.inbounds[]|select(.tag==$tag)) |=
                (.method=$value.method | .password=$value.password | del(.network) | if $network!="both" then .network=$network else . end)' "$stage/config.json") || return 1
            sbd_record_write "$stage/config.json" "$content" || return 1
            content=$(jq --argjson value "$value" --arg network "$source" '.client |=
                (.method=$value.method | .password=$value.password | del(.network) | if $network!="both" then .network=$network else . end)' "$stage/entry-node.json") || return 1 ;;
        cdn)
            case "$profile" in vmess_ws|vless_ws) ;; *) _error '此节点不是 CDN WS 配置档'; return 1 ;; esac
            sbd_entry_cdn "$value" && sbd_entry_host "$(jq -r '.server' <<< "$value")" || return 1
            value=$(jq --argjson port "$(sbd_integer "$(jq -r '.origin_port' <<< "$value")" 1 65535)" '.origin_port=$port' <<< "$value") || return 1
            source=$(sbd_integer "$(jq -r '.server_port' <<< "$value")" 1 65535) || { _error 'CDN 前端端口无效'; return 1; }
            content=$(jq --arg tag "$tag" --argjson value "$value" '(.inbounds[]|select(.tag==$tag)|.transport.path)=$value.path' "$stage/config.json") || return 1
            sbd_record_write "$stage/config.json" "$content" || return 1
            content=$(jq --argjson value "$value" --argjson port "$source" '.ingress={type:"cdn",host:$value.host,origin_port:$value.origin_port} |
                .client.server=$value.server | .client.server_port=$port | .client.tls.server_name=$value.host |
                .client.transport.path=$value.path | .client.transport.headers.Host=$value.host' "$stage/entry-node.json") || return 1 ;;
        delete)
            if jq -e --arg tag "$tag" '
                any(.inbounds[]?; .tag!=$tag and .detour?==$tag) or
                any([(.route.rules? // []),(.dns.rules? // [])] | .. | objects | .inbound? // empty;
                    if type=="array" then index($tag)!=null else .==$tag end)
            ' "$stage/config.json" >/dev/null; then _error '此 inbound 仍被路由或其他入口引用，不能删除'; return 1; fi
            content=$(jq --arg tag "$tag" '.inbounds |= map(select(.tag!=$tag))' "$stage/config.json") || return 1
            sbd_record_write "$stage/config.json" "$content" || return 1
            content=$(jq --arg id "$id" '.nodes |= map(select(.id!=$id))' "$stage/registry.json") || return 1
            sbd_record_write "$stage/registry.json" "$content" || return 1
            sbd_export_rebuild "$stage"
            return $?
            ;;
        *) _error '未知节点操作'; return 1 ;;
    esac
    sbd_record_write "$stage/entry-node.json" "$content" || return 1
    content=$(jq --slurpfile node "$stage/entry-node.json" --arg id "$id" '.nodes |= map(if .id==$id then $node[0] else . end)' "$stage/registry.json") || return 1
    sbd_record_write "$stage/registry.json" "$content" || return 1
    sbd_export_rebuild "$stage"
}

sbd_entry_default() {
    local label="$1" default="$2" secret="${3:-false}"
    sbd_read_optional "$label（默认 $default）" "$secret" || return $?
    SBD_REPLY="${SBD_REPLY:-$default}"
}

sbd_entry_number_prompt() {
    local label="$1" low="$2" high="$3" default="${4:-}" value
    while true; do
        if [[ -n "$default" ]]; then sbd_entry_default "$label" "$default" || return $?; else sbd_read_required "$label" || return $?; fi
        if value=$(sbd_integer "$SBD_REPLY" "$low" "$high"); then SBD_REPLY="$value"; return 0; fi
        _error "请输入 $low 到 $high 的十进制整数"
    done
}

sbd_entry_host_prompt() {
    local label="$1" default="${2:-}"
    while true; do
        if [[ -n "$default" ]]; then sbd_entry_default "$label" "$default" || return $?; else sbd_read_required "$label" || return $?; fi
        sbd_entry_host "$SBD_REPLY" && return 0
    done
}

sbd_entry_listen_prompt() {
    local value
    while true; do
        sbd_entry_default '监听 IP' '::' || return $?
        if value=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_address(sys.argv[1]))' "$SBD_REPLY" 2>/dev/null) &&
            sbd_entry_socket_available "$value" 0 tcp; then SBD_REPLY="$value"; return 0; fi
        _error '监听地址须为可绑定的本机 IP，可用 :: 或 0.0.0.0'
    done
}

sbd_entry_server_prompt() {
    local default="${1:-}"
    [[ "${SBD_UI_EOF:-false}" != true ]] || return 2
    if [[ -n "$default" ]]; then
        sbd_entry_host_prompt '客户端连接地址' "$default"
        return $?
    fi
    if default=$(sbd_public_ip); then
        sbd_info '检测到的是出口 IP；若提供商指定其他入站域名/IP，请手动填写'
        while true; do
            sbd_ui_prompt "客户端连接地址（回车用公网 IP $default）"
            if ! sbd_ui_read_line; then sbd_info '输入结束，已取消'; return 2; fi
            SBD_REPLY="${SBD_REPLY:-$default}"
            sbd_entry_host "$SBD_REPLY" && return 0
        done
    fi
    sbd_info '未能自动获取公网 IP，请手动填写提供商的公网域名/IP'
    sbd_entry_host_prompt '客户端连接地址（提供商公网域名/IP）'
}

sbd_entry_port_prompt() {
    local listen="$1" network="$2" exclude="${3:-}" config="$SBD_CONFIG" random value generated
    [[ -f "$config" ]] || config="$SBD_APP/presets/base.json"
    while true; do
        [[ "${SBD_UI_EOF:-false}" != true ]] || return 2
        sbd_ui_prompt '监听端口（回车随机生成）'
        if ! sbd_ui_read_line; then sbd_info '输入结束，已取消'; return 2; fi
        generated=false
        if [[ -z "$SBD_REPLY" ]]; then
            random=$(openssl rand -hex 2) && [[ "$random" =~ ^[0-9a-fA-F]{4}$ ]] || { _error '随机端口生成失败'; return 1; }
            SBD_REPLY=$((10000+16#$random%55536)); generated=true
        fi
        if ! value=$(sbd_integer "$SBD_REPLY" 1 65535); then _error '请输入 1 到 65535 的十进制整数，或回车随机生成'; continue; fi
        SBD_REPLY="$value"
        if sbd_entry_port "$SBD_CONFIG_DIR" "$listen" "$SBD_REPLY" "$network" "$exclude" "$config"; then
            [[ "$generated" != true ]] || sbd_info "随机监听端口: $SBD_REPLY"
            return 0
        fi
    done
}

sbd_entry_password_prompt() {
    local label="$1" generated
    # 不把随机密码印在默认值提示中；只有明确留空时才生成。
    sbd_read_optional "$label（留空随机，不回显）" true || return $?
    if [[ -z "$SBD_REPLY" ]]; then
        generated=$("$SBD_BINARY" generate rand --hex 16) || { _error '随机密码生成失败'; return 1; }
        [[ -n "$generated" ]] || { _error '随机密码为空'; return 1; }
        SBD_REPLY="$generated"
    fi
}

sbd_entry_choose() {
    local values="$1" label="$2" back="${3:-false}" count index name low=1
    count=$(jq -er 'length' <<< "$values") || { _error '读取选择列表失败'; return 1; }
    (( count > 0 )) || { _error '暂无可选择资料，请先创建或导入'; return 1; }
    index=0
    while (( index < count )); do
        name=$(jq -r --argjson index "$index" '.[$index] | (.id // .tag) as $id | (.name // .server_name // $id) as $name |
            if $name==$id then $name else "\($name) (\($id))" end' <<< "$values") || return 1
        sbd_ui_rows "[$((index+1))] $name"
        index=$((index+1))
    done
    if [[ "$back" = true ]]; then sbd_ui_options '[0] 返回上一级'; low=0; fi
    sbd_read_integer "$label" "$low" "$count" || return $?
    [[ "$SBD_REPLY" != 0 ]] || return 2
    SBD_REPLY=$(jq -er --argjson index "$((SBD_REPLY-1))" '.[$index].id // .[$index].tag' <<< "$values") || { _error '所选资料缺少标识'; return 1; }
}

sbd_entry_tls_prompt() {
    local profile="$1" server="$2" choice id name trust values kind default
    if [[ "$profile" = anyreality || "$profile" = vless_reality ]]; then
        sbd_entry_host_prompt '伪装域名' www.amd.com || return $?; name="$SBD_REPLY"
        SBD_TLS_REQUEST=$(jq -n --arg name "$name" '{kind:"reality",server_name:$name,handshake:{server:$name,server_port:443}}') || return 1
        return 0
    fi
    sbd_ui_options '[1] 已有共享 ACME provider' '[2] 已登记 PEM 证书' '[3] 新建 P-256 自签证书'
    sbd_read_integer 'TLS 来源' 1 3 || return $?; choice="$SBD_REPLY"
    case "$choice" in
        1)
            [[ -f "$SBD_CONFIG" ]] || { _error '请先在 TLS 菜单创建 provider'; return 1; }
            values=$(jq -c '[.certificate_providers[]? | select(.type=="acme")]' "$SBD_CONFIG") || return 1
            sbd_entry_choose "$values" '选择 provider' || return $?; id="$SBD_REPLY"
            while true; do
                sbd_entry_host_prompt '客户端 SNI（须被签发域名覆盖）' || return $?; name="$SBD_REPLY"
                sbd_entry_provider_name "$(jq -c --arg id "$id" '.certificate_providers[]|select(.tag==$id)' "$SBD_CONFIG")" "$name" && break
            done
            SBD_TLS_REQUEST=$(jq -n --arg id "$id" --arg name "$name" '{kind:"provider",id:$id,server_name:$name}') || return 1
            return 0 ;;
        2)
            values=$(jq -c '.tls.certificates // []' "$SBD_REGISTRY") || return 1
            sbd_entry_choose "$values" '选择证书' || return $?; id="$SBD_REPLY"
            kind=$(jq -r --arg id "$id" '.tls.certificates[]|select(.id==$id)|.kind' "$SBD_REGISTRY") || return 1
            ;;
        3)
            sbd_entry_host_prompt '自签 SAN 名称或 IP' "$server" || return $?; name="$SBD_REPLY"
            kind=self_signed ;;
    esac
    default=1; [[ "$kind" != self_signed ]] || default=2
    sbd_ui_options '[1] 系统 CA（自签不可用）' '[2] 公钥 pin' '[3] 携带证书信任'
    while true; do
        sbd_entry_number_prompt '客户端信任方式' 1 3 "$default" || return $?
        [[ "$kind" != self_signed || "$SBD_REPLY" != 1 ]] && break
        _error '自签证书须选择 pin 或证书信任'
    done
    case "$SBD_REPLY" in 1) trust=system ;; 2) trust=pin ;; 3) trust=certificate ;; esac
    if [[ "$choice" = 3 ]]; then
        SBD_TLS_REQUEST=$(jq -n --arg name "$name" --arg trust "$trust" '{kind:"self_signed",server_name:$name,trust:$trust}') || return 1
    else
        SBD_TLS_REQUEST=$(jq -n --arg id "$id" --arg trust "$trust" '{kind:"certificate",id:$id,trust:$trust}') || return 1
    fi
}

sbd_entry_uuid_prompt() {
    local value
    while true; do
        sbd_read_optional 'UUID（留空由核心随机生成，不回显）' true || return $?
        value="$SBD_REPLY"
        if [[ -z "$value" ]]; then value=$("$SBD_BINARY" generate uuid) || { _error '核心生成 UUID 失败'; return 1; }; fi
        if value=$(sbd_entry_uuid "$value"); then SBD_REPLY="$value"; return 0; fi
    done
}

sbd_entry_ss_prompt() {
    local network method password choice
    sbd_ui_options '[1] TCP+UDP（默认）' '[2] 仅 TCP' '[3] 仅 UDP'
    sbd_entry_number_prompt 'Shadowsocks 监听网络' 1 3 1 || return $?
    case "$SBD_REPLY" in 1) network=both ;; 2) network=tcp ;; 3) network=udp ;; esac
    sbd_ui_options '[1] aes-256-gcm' '[2] 2022-blake3-aes-256-gcm' '[3] 2022-blake3-chacha20-poly1305'
    sbd_read_integer '选择算法' 1 3 || return $?; choice="$SBD_REPLY"
    case "$choice" in 1) method=aes-256-gcm ;; 2) method=2022-blake3-aes-256-gcm ;; 3) method=2022-blake3-chacha20-poly1305 ;; esac
    sbd_entry_ss_password_prompt "$method" || return $?; password="$SBD_REPLY"
    SBD_SS_REQUEST=$(jq -n --arg method "$method" --arg network "$network" --arg password "$password" '{method:$method,network:$network,password:$password}') || return 1
}

sbd_entry_ss_password_prompt() {
    local method="$1" value
    while true; do
        sbd_read_optional 'Shadowsocks 密码/密钥（留空随机，不回显）' true || return $?
        value="$SBD_REPLY"
        if [[ -z "$value" ]]; then
            if [[ "$method" = aes-256-gcm ]]; then value=$("$SBD_BINARY" generate rand --hex 16)
            else value=$("$SBD_BINARY" generate rand --base64 32); fi || { _error '核心生成 Shadowsocks 密钥失败'; return 1; }
        fi
        if sbd_entry_ss_key "$method" "$value"; then SBD_REPLY="$value"; return 0; fi
    done
}

sbd_entry_cdn_prompt() {
    local listen_port="$1" defaults="${2:-}" host origin server port path default_path
    [[ -n "$defaults" ]] || defaults='{}'
    while true; do
        sbd_entry_host_prompt 'CDN 域名/Host' "$(jq -r '.host // empty' <<< "$defaults")" || return $?; host="$SBD_REPLY"
        [[ "$(sbd_tls_identity "$host")" = DNS:* ]] && break
        _error 'CDN Host 必须填写域名，不能用 IP'
    done
    sbd_entry_number_prompt '提供商回源 TCP 映射端口（仅记录，不自动改转发）' 1 65535 "$(jq -r --argjson port "$listen_port" '.origin_port // $port' <<< "$defaults")" || return $?; origin="$SBD_REPLY"
    sbd_entry_host_prompt 'CDN 优选域名/IP' "$(jq -r --arg host "$host" '.server // $host' <<< "$defaults")" || return $?; server="$SBD_REPLY"
    sbd_entry_number_prompt 'CDN 前端端口' 1 65535 "$(jq -r '.server_port // 443' <<< "$defaults")" || return $?; port="$SBD_REPLY"
    default_path=$(jq -r '.path // empty' <<< "$defaults") || return 1
    if [[ -z "$default_path" ]]; then
        default_path=$("$SBD_BINARY" generate rand --hex 8) || { _error '随机 WS 路径生成失败'; return 1; }
        default_path="/$default_path"
    fi
    while true; do
        sbd_entry_default 'WS path（不追加 early data 查询参数）' "$default_path" || return $?; path="$SBD_REPLY"
        sbd_entry_ws_path "$path" && break
    done
    SBD_CDN_REQUEST=$(jq -n --arg host "$host" --argjson origin "$origin" --arg server "$server" --argjson port "$port" --arg path "$path" \
        '{host:$host,origin_port:$origin,server:$server,server_port:$port,path:$path}') || return 1
}

sbd_entry_create_classic_prompt() {
    local profile="$1" network=tcp options='{}' listen port server external name uuid source cdn request
    if [[ "$profile" = shadowsocks ]]; then
        sbd_entry_ss_prompt || return $?; options="$SBD_SS_REQUEST"
        network=$(jq -r '.network' <<< "$options") || return 1
    fi
    sbd_entry_listen_prompt || return $?; listen="$SBD_REPLY"
    sbd_entry_port_prompt "$listen" "$network" || return $?; port="$SBD_REPLY"
    if [[ "$profile" = *_ws ]]; then
        sbd_entry_cdn_prompt "$port" || return $?; cdn="$SBD_CDN_REQUEST"
        server=$(jq -r '.server' <<< "$cdn") && external=$(jq -r '.server_port' <<< "$cdn") || return 1
        options=$(jq --argjson cdn "$cdn" '. + {cdn:$cdn}' <<< "$options") || return 1
    else
        sbd_entry_server_prompt || return $?; server="$SBD_REPLY"
        external="$port"
    fi
    sbd_entry_default '节点显示名' "$profile-$port" || return $?; name="$SBD_REPLY"
    if [[ "$profile" != shadowsocks ]]; then
        sbd_entry_uuid_prompt || return $?; uuid="$SBD_REPLY"
        options=$(jq --arg uuid "$uuid" '. + {uuid:$uuid}' <<< "$options") || return 1
    fi
    if [[ "$profile" = vless_reality ]]; then
        sbd_entry_tls_prompt "$profile" "$server" || return $?; source="$SBD_TLS_REQUEST"
        options=$(jq --argjson source "$source" '. + {tls_source:$source}' <<< "$options") || return 1
    fi
    request=$(jq --arg profile "$profile" --arg name "$name" --arg listen "$listen" --argjson port "$port" --arg server "$server" --argjson external "$external" \
        '. + {profile:$profile,name:$name,listen:$listen,listen_port:$port,server:$server,server_port:$external}' <<< "$options") || return 1
    sbd_read_required '确认创建并按需重启？输入 y 确认，其他输入取消' || return $?
    [[ "$SBD_REPLY" = y ]] || return 2
    sbd_entry_submit "$request" || return 1
    sbd_entry_deliver
}

sbd_entry_hy2_prompt() {
    local choice up down obfs='null' server='{}' client='{}' password low high maximum
    sbd_ui_options '[1] 客户端 BBR（默认）' '[2] 客户端 Hysteria CC，分别填写上/下行 Mbps'
    sbd_entry_number_prompt '客户端拥塞策略' 1 2 1 || return $?; choice="$SBD_REPLY"
    if [[ "$choice" = 2 ]]; then
        sbd_entry_number_prompt '客户端上传 Mbps（客户端→服务器）' 1 999999999 || return $?; up="$SBD_REPLY"
        sbd_entry_number_prompt '客户端下载 Mbps（服务器→客户端）' 1 999999999 || return $?; down="$SBD_REPLY"
        client=$(jq -n --argjson up "$up" --argjson down "$down" '{up_mbps:$up,down_mbps:$down}') || return 1
    fi
    sbd_ui_options '[1] 不设置服务端带宽上限（默认）' '[2] 分别填写服务端上/下行上限'
    sbd_entry_number_prompt '服务端带宽设置' 1 2 1 || return $?; choice="$SBD_REPLY"
    if [[ "$choice" = 2 ]]; then
        sbd_entry_number_prompt '服务端上传 Mbps（服务器→客户端）' 1 999999999 || return $?; up="$SBD_REPLY"
        sbd_entry_number_prompt '服务端下载 Mbps（客户端→服务器）' 1 999999999 || return $?; down="$SBD_REPLY"
        server=$(jq -n --argjson up "$up" --argjson down "$down" '{up_mbps:$up,down_mbps:$down}') || return 1
    fi
    sbd_ui_options '[1] 不启用混淆（默认）' '[2] Salamander' '[3] Gecko（自定义尺寸采用 URI 扩展）'
    sbd_entry_number_prompt '混淆方式' 1 3 1 || return $?; choice="$SBD_REPLY"
    if [[ "$choice" != 1 ]]; then
        sbd_entry_password_prompt '混淆密码' || return $?; password="$SBD_REPLY"
        if [[ "$choice" = 2 ]]; then obfs=$(jq -n --arg password "$password" '{type:"salamander",password:$password}') || return 1
        else
            sbd_entry_number_prompt 'Gecko 最小包长（bytes）' 1 65535 512 || return $?; low="$SBD_REPLY"
            maximum=1200; (( low <= maximum )) || maximum="$low"
            sbd_entry_number_prompt 'Gecko 最大包长（bytes）' "$low" 65535 "$maximum" || return $?; high="$SBD_REPLY"
            obfs=$(jq -n --arg password "$password" --argjson low "$low" --argjson high "$high" '{type:"gecko",password:$password,min_packet_size:$low,max_packet_size:$high}') || return 1
        fi
    fi
    SBD_HY2_REQUEST=$(jq -n --argjson server "$server" --argjson client "$client" --argjson obfs "$obfs" '{server_options:$server,client_options:$client,obfs:$obfs}') || return 1
}

sbd_entry_create_prompt() {
    local choice profile listen port server password name source options='{}' request network
    sbd_ui_begin '添加节点'
    sbd_ui_options '[1] Hysteria2（UDP）' '[2] AnyTLS（TCP）' '[3] AnyReality（AnyTLS + Reality，TCP）' \
        '[4] Shadowsocks（三算法）' '[5] VMess+WS CDN' '[6] VLESS+Reality Vision' '[7] VLESS+WS CDN' '[0] 返回上一级'
    sbd_read_integer '选择配置档' 0 7 || return $?; choice="$SBD_REPLY"
    [[ "$choice" != 0 ]] || return 2
    sbd_version >/dev/null || return 1
    if [[ -f "$SBD_CONFIG" ]]; then sbd_check_config || return 1; fi
    case "$choice" in
        1) profile=hysteria2 ;; 2) profile=anytls ;; 3) profile=anyreality ;;
        4) profile=shadowsocks ;; 5) profile=vmess_ws ;; 6) profile=vless_reality ;; 7) profile=vless_ws ;;
    esac
    case "$profile" in shadowsocks|vmess_ws|vless_reality|vless_ws) sbd_entry_create_classic_prompt "$profile"; return $? ;; esac
    network=tcp; [[ "$profile" != hysteria2 ]] || network=udp
    sbd_entry_listen_prompt || return $?; listen="$SBD_REPLY"
    sbd_entry_port_prompt "$listen" "$network" || return $?; port="$SBD_REPLY"
    sbd_entry_server_prompt || return $?; server="$SBD_REPLY"
    sbd_entry_default '节点显示名' "$profile-$port" || return $?; name="$SBD_REPLY"
    sbd_entry_password_prompt '认证密码' || return $?; password="$SBD_REPLY"
    sbd_entry_tls_prompt "$profile" "$server" || return $?; source="$SBD_TLS_REQUEST"
    if [[ "$profile" = hysteria2 ]]; then sbd_entry_hy2_prompt || return $?; options="$SBD_HY2_REQUEST"; fi
    request=$(jq -n --arg profile "$profile" --arg name "$name" --arg listen "$listen" --argjson port "$port" --arg server "$server" --arg password "$password" --argjson source "$source" --argjson options "$options" \
        '$options + {profile:$profile,name:$name,listen:$listen,listen_port:$port,server:$server,server_port:$port,password:$password,tls_source:$source}') || return 1
    sbd_read_required '确认创建并按需重启？输入 y 确认，其他输入取消' || return $?
    [[ "$SBD_REPLY" = y ]] || return 2
    sbd_entry_submit "$request" || return 1
    sbd_entry_deliver
}

sbd_entry_actions() {
    local profile="$1" mode="${2:-all}"
    sbd_ui_options '[1] 修改显示名' '[2] 更换认证密码/UUID' '[3] 修改客户端连接地址/映射端口' '[4] 修改本地监听'
    SBD_ENTRY_ACTIONS=' 0 1 2 3 4 '
    case "$profile" in
        hysteria2)
            sbd_ui_options '[5] Hysteria2 带宽/混淆' '[6] 切换 TLS 来源'
            SBD_ENTRY_ACTIONS+='5 6 ' ;;
        anytls) sbd_ui_options '[6] 切换 TLS 来源'; SBD_ENTRY_ACTIONS+='6 ' ;;
        anyreality|vless_reality) sbd_ui_options '[6] 重建 Reality 密钥及握手配置'; SBD_ENTRY_ACTIONS+='6 ' ;;
        shadowsocks|vmess_ws|vless_ws) ;;
        *) _error '未知托管配置档'; return 1 ;;
    esac
    if [[ "$mode" != edit ]]; then
        sbd_ui_options '[7] 删除节点（保留证书/provider 资料）'
        SBD_ENTRY_ACTIONS+='7 '
    fi
    case "$profile" in
        shadowsocks) sbd_ui_options '[8] Shadowsocks 算法/网络/密钥'; SBD_ENTRY_ACTIONS+='8 ' ;;
        vmess_ws|vless_ws) sbd_ui_options '[9] WS CDN 域名/回源/路径'; SBD_ENTRY_ACTIONS+='9 ' ;;
    esac
    sbd_ui_options '[0] 取消'
}

sbd_entry_change_prompt() {
    local mode="${1:-all}" title values id node name choice action value profile server network tag defaults port
    case "$mode" in
        all) title='修改或删除节点' ;;
        edit) title='修改节点' ;;
        delete) title='删除节点' ;;
        *) _error '未知节点菜单操作'; return 1 ;;
    esac
    sbd_ui_begin "$title"
    values=$(jq -c '.nodes' "$SBD_REGISTRY") || return 1
    sbd_entry_choose "$values" '选择节点' true || return $?; id="$SBD_REPLY"
    node=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SBD_REGISTRY") || return 1
    profile=$(jq -r '.profile' <<< "$node") || return 1
    if [[ "$mode" = delete ]]; then
        name=$(jq -r '.name' <<< "$node") || { _error '读取节点名称失败'; return 1; }
        sbd_info "将删除节点: $name ($id)；保留证书资料"
        choice=7
    else
        sbd_entry_actions "$profile" "$mode" || return 1
        while true; do
            sbd_read_integer '选择操作' 0 9 || return $?; choice="$SBD_REPLY"
            [[ "$SBD_ENTRY_ACTIONS" = *" $choice "* ]] && break
            _error '此操作不适用于当前配置档，请选择显示的编号'
        done
    fi
    case "$choice" in
        0) return 2 ;;
        1) action=name; sbd_read_required '新显示名' || return $?; value="$SBD_REPLY" ;;
        2)
            action=password
            case "$profile" in
                vmess_ws|vless_ws|vless_reality) sbd_entry_uuid_prompt || return $? ;;
                shadowsocks) sbd_entry_ss_password_prompt "$(jq -r '.client.method' <<< "$node")" || return $? ;;
                *) sbd_entry_password_prompt '新密码' || return $? ;;
            esac
            value="$SBD_REPLY" ;;
        3)
            action=external
            sbd_entry_server_prompt "$(jq -r '.client.server' <<< "$node")" || return $?; server="$SBD_REPLY"
            sbd_entry_number_prompt '客户端映射端口' 1 65535 "$(jq -r '.client.server_port' <<< "$node")" || return $?
            value=$(jq -n --arg server "$server" --argjson port "$SBD_REPLY" '{server:$server,server_port:$port}') || return 1 ;;
        4)
            action=listen
            sbd_entry_listen_prompt || return $?; server="$SBD_REPLY"
            network=tcp; [[ "$profile" != hysteria2 ]] || network=udp
            if [[ "$profile" = shadowsocks ]]; then network=$(jq -r '.client.network // "both"' <<< "$node") || return 1; fi
            tag=$(jq -r '.inbound_tag' <<< "$node") || return 1
            sbd_entry_port_prompt "$server" "$network" "$tag" || return $?
            value=$(jq -n --arg listen "$server" --argjson port "$SBD_REPLY" '{listen:$listen,listen_port:$port}') || return 1 ;;
        5)
            [[ "$profile" = hysteria2 ]] || { _error '此节点不是 Hysteria2'; return 1; }
            action=hy2; sbd_entry_hy2_prompt || return $?; value="$SBD_HY2_REQUEST" ;;
        6)
            case "$profile" in shadowsocks|*_ws) _error '此配置档不在源站使用 TLS；WS 请修改 CDN 参数'; return 1 ;; esac
            action=tls; sbd_entry_tls_prompt "$profile" "$(jq -r '.client.server' <<< "$node")" || return $?; value="$SBD_TLS_REQUEST" ;;
        7) action=delete; value='' ;;
        8)
            [[ "$profile" = shadowsocks ]] || { _error '此节点不是 Shadowsocks'; return 1; }
            action=ss; sbd_entry_ss_prompt || return $?; value="$SBD_SS_REQUEST" ;;
        9)
            [[ "$profile" = *_ws ]] || { _error '此节点不是 WS CDN 配置档'; return 1; }
            action=cdn
            tag=$(jq -r '.inbound_tag' <<< "$node") || return 1
            port=$(jq -er --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$SBD_CONFIG") || return 1
            defaults=$(jq -c '.ingress + {server:.client.server,server_port:.client.server_port,path:.client.transport.path}' <<< "$node") || return 1
            sbd_entry_cdn_prompt "$port" "$defaults" || return $?; value="$SBD_CDN_REQUEST" ;;
    esac
    sbd_read_required '确认此操作并按需重启？输入 y 确认，其他输入取消' || return $?
    [[ "$SBD_REPLY" = y ]] || return 2
    sbd_apply sbd_entry_change "$id" "$action" "$value" || return 1
    sbd_success '节点变更与分享资料已提交；未验证外网连通'
    sbd_ui_pause
}

sbd_entries_list() {
    jq -r 'if .nodes==[] then "暂无节点，请先添加节点" else .nodes[] | "\(.id)  \(.name)  \(.profile)  \(.client.server):\(.client.server_port)" end' "$SBD_REGISTRY" || { _error '读取节点列表失败'; return 1; }
}

sbd_entries_menu() {
    local choice rc page
    while true; do
        sbd_ui_menu '节点管理' '[1] 列出节点（不显示凭据）' '[2] 创建节点' '[3] 修改或删除节点' '[0] 返回'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 3 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) sbd_entries_list ;;
            2) sbd_entry_create_prompt ;;
            3) sbd_entry_change_prompt ;;
        esac
        rc=$?
        [[ "$rc" = 0 || "$rc" = 2 ]] || return 1
        sbd_ui_pause "$page"
    done
}

sbd_entry_adopt() {
    local stage="$1" tag="$2" facts="$3" id="${4:-}" content profile inbound client source share='{}' name server port cert key public short trust cid actual_type transport
    sbd_record_write "$stage/adopt-facts.json" "$facts" || return 1
    jq -ce --arg tag "$tag" '[.inbounds[]?|select(.tag==$tag)]|select(length==1)|.[0]' "$stage/config.json" > "$stage/adopt-inbound.json" || { _error '配置中没有唯一的 inbound'; return 1; }
    inbound=$(cat "$stage/adopt-inbound.json") || return 1
    actual_type=$(jq -r .type <<< "$inbound") && transport=$(jq -r '.transport.type // "tcp"' <<< "$inbound") || return 1
    case "$actual_type:$transport:$(jq -r '.tls.reality.enabled // false' <<< "$inbound")" in
        shadowsocks:tcp:false) profile=shadowsocks ;;
        vmess:ws:false) profile=vmess_ws ;;
        vless:ws:false) profile=vless_ws ;;
        vless:tcp:true) profile=vless_reality ;;
        anytls:tcp:true) profile=anyreality ;;
        anytls:tcp:false) profile=anytls ;;
        hysteria2:tcp:false) profile=hysteria2 ;;
        *) _error '此原生组合不在七档可完整导出的托管范围'; return 1 ;;
    esac
    if [[ -n "$id" ]]; then
        jq -e --arg id "$id" --arg tag "$tag" '[.nodes[]|select(.id==$id and .inbound_tag==$tag)]|length==1' "$stage/registry.json" >/dev/null || { _error '协调须保持节点 ID 和 inbound 关联'; return 1; }
    else
        jq -e --arg tag "$tag" 'all(.nodes[];.inbound_tag!=$tag)' "$stage/registry.json" >/dev/null || { _error '此 inbound 已托管，请选择协调'; return 1; }
        id=$(openssl rand -hex 8) || return 1; id="node.$id"
    fi
    name=$(sbd_entry_text "$stage/adopt-facts.json" .name 显示名) && server=$(sbd_entry_text "$stage/adopt-facts.json" .server 客户端地址) || return 1
    port=$(sbd_integer "$(jq -r .server_port "$stage/adopt-facts.json")" 1 65535) || { _error '客户端端口无效'; return 1; }
    sbd_entry_host "$server" || return 1
    client=$(jq -n --arg type "$actual_type" --arg server "$server" --argjson port "$port" '{type:$type,server:$server,server_port:$port}') || return 1
    if [[ "$profile" = shadowsocks ]]; then
        client=$(jq --argjson inbound "$inbound" '. + ($inbound|{method,password} + (if has("network") then {network} else {} end))' <<< "$client") || return 1
        source='{"kind":"none"}'
    else
        jq -e '.users|length==1' <<< "$inbound" >/dev/null || { _error '仅接管可唯一对应一个客户端的单用户节点'; return 1; }
        client=$(jq --argjson inbound "$inbound" '. + ($inbound.users[0]|{uuid,password,flow}|with_entries(select(.value!=null)))' <<< "$client") || return 1
        if [[ "$profile" = vmess_ws ]]; then client=$(jq '. + {security:"auto",alter_id:0}' <<< "$client") || return 1; fi
        if [[ "$profile" = *_ws ]]; then
            content=$(jq -c --argjson inbound "$inbound" '.cdn + {path:$inbound.transport.path}' "$stage/adopt-facts.json") || return 1
            sbd_entry_cdn "$content" || return 1
            client=$(jq --argjson cdn "$content" '. + {tls:{enabled:true,server_name:$cdn.host},transport:{type:"ws",path:$cdn.path,headers:{Host:$cdn.host}}}' <<< "$client") || return 1
            source='{"kind":"cdn"}'
        elif [[ "$profile" = anyreality || "$profile" = vless_reality ]]; then
            key=$(jq -er '.tls.reality.private_key' <<< "$inbound") || return 1
            public=$(sbd_entry_public_key "$key" "$stage") || return 1
            short=$(jq -er '.short_id|select(type=="string")' "$stage/adopt-facts.json") || { _error '须明确填写一个已配置的 short_id'; return 1; }
            content=$(jq -n --arg name "$(jq -r '.tls.server_name' <<< "$inbound")" --arg key "$public" --arg short "$short" '{enabled:true,server_name:$name,reality:{enabled:true,public_key:$key,short_id:$short},utls:{enabled:true,fingerprint:"chrome"}}') || return 1
            client=$(jq --argjson tls "$content" '.tls=$tls' <<< "$client") || return 1
            source='{"kind":"reality"}'
        else
            cid=$(jq -r '.tls.certificate_provider // empty' <<< "$inbound") || return 1
            if [[ -n "$cid" ]]; then
                jq -e --arg cid "$cid" 'any(.certificate_providers[]?;.tag==$cid and .type=="acme")' "$stage/config.json" >/dev/null || { _error '只能登记可理解的原生 ACME 来源'; return 1; }
                content=$(jq --arg id "$cid" '.tls.providers=((.tls.providers // [])+[$id]|unique)' "$stage/registry.json") || return 1
                sbd_record_write "$stage/registry.json" "$content" || return 1
                name=$(sbd_entry_text "$stage/adopt-facts.json" .server_name SNI) || return 1
                source=$(jq -n --arg id "$cid" --arg name "$name" '{kind:"provider",id:$id,server_name:$name}') || return 1
                client=$(jq --arg name "$name" '.tls={enabled:true,server_name:$name}' <<< "$client") || return 1
            else
                if ! cert=$(jq -er '.tls.certificate_path|if type=="array" then select(length==1)|.[0] else . end|select(type=="string")' <<< "$inbound") || ! key=$(jq -er '.tls.key_path|if type=="array" then select(length==1)|.[0] else . end|select(type=="string")' <<< "$inbound"); then _error '接管仅支持已登记 provider 或单文件 PEM，不猜测内联证书来源'; return 1; fi
                name=$(sbd_entry_text "$stage/adopt-facts.json" .server_name SNI) && trust=$(sbd_entry_text "$stage/adopt-facts.json" .trust 信任方式) || return 1
                sbd_tls_material_add "$stage" import "$name" "$cert" "$key" || return 1
                cid=$(jq -r '.tls.certificates[-1].id' "$stage/registry.json") || return 1
                source=$(jq -n --arg id "$cid" --arg trust "$trust" '{kind:"certificate",id:$id,trust:$trust}') || return 1
                content=$(sbd_tls_client "$stage" "$cid" "$trust") || return 1
                client=$(jq --argjson tls "$content" '.tls=$tls' <<< "$client") || return 1
                if [[ "$trust" != system ]]; then share=$(jq -n --arg sha "$(sbd_entry_cert_sha "$cert")" '{certificate_sha256:$sha}') || return 1; fi
            fi
            if [[ "$profile" = hysteria2 ]]; then
                content=$(jq -c '.client_options // {}' "$stage/adopt-facts.json") || return 1
                client=$(jq --argjson options "$content" --argjson inbound "$inbound" '. + $options + (if $inbound.obfs!=null then {obfs:$inbound.obfs} else {} end)' <<< "$client") || return 1
            fi
        fi
    fi
    if jq -e '.tls.alpn!=null' <<< "$inbound" >/dev/null && [[ "$profile" != *_ws && "$profile" != shadowsocks ]]; then
        client=$(jq --argjson inbound "$inbound" '.tls.alpn=$inbound.tls.alpn' <<< "$client") || return 1
    fi
    name=$(jq -r .name "$stage/adopt-facts.json") || return 1
    content=$(jq -n --arg id "$id" --arg tag "$tag" --arg profile "$profile" --arg name "$name" --argjson client "$client" --argjson source "$source" --argjson share "$share" --argjson facts "$facts" '
        {id:$id,inbound_tag:$tag,profile:$profile,name:$name,client:$client,tls_source:$source,share:$share} +
        (if $source.kind=="certificate" then {certificate_id:$source.id} else {} end) +
        (if $source.kind=="cdn" then {ingress:{type:"cdn",host:$facts.cdn.host,origin_port:$facts.cdn.origin_port}} else {} end)') || return 1
    sbd_record_write "$stage/adopt-node.json" "$content" || return 1
    sbd_entry_align "$stage" "$stage/adopt-node.json" || return 1
    content=$(jq --arg id "$id" --slurpfile node "$stage/adopt-node.json" '.nodes=([.nodes[]|select(.id!=$id)]+$node)' "$stage/registry.json") || return 1
    sbd_record_write "$stage/registry.json" "$content" || return 1
    sbd_export_rebuild "$stage"
}
