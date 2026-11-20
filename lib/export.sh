#!/usr/bin/env bash

sbd_uri_escape() {
    printf '%s' "$1" | python3 -I -c '
import sys
from urllib.parse import quote
print(quote(sys.stdin.read(), safe=""))
'
}

# userinfo 由协议适配器逐字段编码；不能把 SS2022 的 method:password 整段 Base64。
sbd_uri_build() {
    local scheme="$1" userinfo="$2" host="$3" port="$4" query="$5" name="$6" authority fragment parameters
    [[ "$scheme" =~ ^[a-z][a-z0-9+.-]*$ && -n "$userinfo" && -n "$host" && -n "$name" ]] || { _error '分享链接必填字段缺失'; return 1; }
    port=$(sbd_integer "$port" 1 65535) || { _error '分享端口无效'; return 1; }
    authority=$(python3 -I - "$host" <(printf '%s' "$userinfo") <<'PY'
import ipaddress
import re
import sys
from urllib.parse import quote
host = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as f:
    userinfo = f.read()
if not re.fullmatch(r"(?:[A-Za-z0-9._~!$&'()*+,;=:-]|%[0-9A-Fa-f]{2})+", userinfo):
    raise SystemExit(1)
try:
    ip = ipaddress.ip_address(host)
    print("[" + str(ip) + "]" if ip.version == 6 else str(ip))
except ValueError:
    if any(c in host for c in ":/[]@?# \t\r\n"):
        raise SystemExit(1)
    print(quote(host, safe=".-"))
PY
    ) || { _error '分享地址或 userinfo 编码无效（IPv6 请勿自行添加方括号）'; return 1; }
    parameters=$(python3 -I - <(printf '%s' "$query") <<'PY'
import json
import sys
from urllib.parse import urlencode, quote
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in data.items()):
    raise SystemExit(1)
print(urlencode(data, quote_via=quote, safe=""))
PY
    ) || { _error '分享查询参数须为字符串对象，不能包含 null'; return 1; }
    fragment=$(sbd_uri_escape "$name") || { _error '分享名称编码失败'; return 1; }
    # 查询串直接跟在 authority 后（参照 Xray-core #716 的链接结构），不写空路径斜杠。
    printf '%s://%s@%s:%s' "$scheme" "$userinfo" "$authority" "$port"
    [[ -z "$parameters" ]] || printf '?%s' "$parameters"
    printf '#%s\n' "$fragment"
}

sbd_share_build() {
    local node="$1" profile adapter
    profile=$(jq -er '.profile | select(type=="string" and length>0)' "$node") || { _error '缺少分享配置档'; return 1; }
    case "$profile" in
        shadowsocks) adapter=sbd_share_shadowsocks ;;
        vmess_ws) adapter=sbd_share_vmess_ws ;;
        hysteria2) adapter=sbd_share_hysteria2 ;;
        vless_reality) adapter=sbd_share_vless_reality ;;
        vless_ws) adapter=sbd_share_vless_ws ;;
        anytls) adapter=sbd_share_anytls ;;
        anyreality) adapter=sbd_share_anyreality ;;
        *) _error '未知分享配置档'; return 1 ;;
    esac
    declare -F "$adapter" >/dev/null || { _error '此协议分享适配器尚未交付，保留旧输出'; return 1; }
    "$adapter" "$node" || { _error '协议分享构造失败，保留旧输出'; return 1; }
}

sbd_share_tls_query() {
    local node="$1" protocol="$2" query sha
    jq -e '.client.tls.enabled==true and (.client.tls.server_name|type=="string" and length>0)' "$node" >/dev/null || { _error '分享资料缺少 TLS 或 SNI'; return 1; }
    # 这是 URI 的可表达性检查，不替代官方配置 Schema。
    jq -e '.client.tls | (keys-["enabled","server_name","insecure","alpn","certificate_public_key_sha256","certificate","utls","reality"]|length)==0' "$node" >/dev/null || { _error 'URI 尚不能表达此 TLS 扩展，保留旧导出'; return 1; }
    query=$(jq -c '.client.tls as $tls | {sni:$tls.server_name} +
        (if $tls.insecure==true then {insecure:"1"} else {} end) +
        (if ($tls.alpn // [] | length)>0 then {alpn:($tls.alpn|if type=="array" then join(",") else . end)} else {} end) +
        (if $tls.utls.enabled==true then {fp:($tls.utls.fingerprint // "chrome")} else {} end)' "$node") || return 1
    if jq -e '(.client.tls.certificate_public_key_sha256 // [] | length)>0 or (.client.tls.certificate // [] | length)>0' "$node" >/dev/null; then
        sha=$(sbd_entry_text "$node" .share.certificate_sha256 完整证书指纹) || return 1
        [[ "$sha" =~ ^[0-9A-Fa-f]{64}$ ]] || { _error '完整证书 SHA-256 无效，不能用 SPKI 公钥 pin 代替'; return 1; }
        if [[ "$protocol" = hysteria2 ]]; then
            query=$(jq --arg sha "$sha" '. + {insecure:"1",pinSHA256:$sha}' <<< "$query") || return 1
        else
            query=$(jq --arg sha "$sha" '. + {pcs:$sha}' <<< "$query") || return 1
        fi
    fi
    printf '%s\n' "$query"
}

sbd_share_emit() {
    local node="$1" scheme="$2" query="$3" password auth server port name
    password=$(sbd_entry_text "$node" .client.password 密码) && server=$(sbd_entry_text "$node" .client.server 对外地址) &&
        name=$(sbd_entry_text "$node" .name 名称) || return 1
    port=$(jq -er '.client.server_port' "$node") || { _error '分享缺少客户端端口'; return 1; }
    auth=$(sbd_uri_escape "$password") || { _error '密码编码失败'; return 1; }
    sbd_uri_build "$scheme" "$auth" "$server" "$port" "$query" "$name"
}

sbd_share_shadowsocks() {
    local node="$1" method password userinfo server port name
    jq -e '.profile=="shadowsocks" and .client.type=="shadowsocks" and ((.client.plugin // "")=="")' "$node" >/dev/null || { _error 'Shadowsocks 分享配置档或插件不在本包范围'; return 1; }
    method=$(sbd_entry_text "$node" .client.method 算法) && password=$(sbd_entry_text "$node" .client.password 密码) || return 1
    sbd_entry_ss_key "$method" <<< "$password" || return 1
    userinfo=$(python3 -I - "$node" <<'PY'
import base64, json, sys
from urllib.parse import quote
c = json.load(open(sys.argv[1]))["client"]
if c["method"].startswith("2022-"):
    print(quote(c["method"], safe="") + ":" + quote(c["password"], safe=""))
else:
    print(base64.urlsafe_b64encode((c["method"] + ":" + c["password"]).encode()).decode().rstrip("="))
PY
    ) || { _error 'SIP002 userinfo 编码失败'; return 1; }
    server=$(sbd_entry_text "$node" .client.server 对外地址) && name=$(sbd_entry_text "$node" .name 名称) || return 1
    port=$(jq -er '.client.server_port' "$node") || { _error '缺少分享端口'; return 1; }
    sbd_uri_build ss "$userinfo" "$server" "$port" '{}' "$name"
}

sbd_share_uuid_emit() {
    local node="$1" scheme="$2" query="$3" uuid auth server port name
    uuid=$(sbd_entry_text "$node" .client.uuid UUID) && uuid=$(sbd_entry_uuid <<< "$uuid") || return 1
    auth=$(sbd_uri_escape "$uuid") || return 1
    server=$(sbd_entry_text "$node" .client.server 对外地址) && name=$(sbd_entry_text "$node" .name 名称) || return 1
    port=$(jq -er '.client.server_port' "$node") || { _error '缺少分享端口'; return 1; }
    sbd_uri_build "$scheme" "$auth" "$server" "$port" "$query" "$name"
}

sbd_share_ws() {
    local node="$1" type="$2" query cdn
    jq -e --arg type "$type" '.client.type==$type and .client.transport.type=="ws" and .client.tls.enabled==true and
        .ingress.type=="cdn" and .client.tls.server_name==.ingress.host and .client.transport.headers.Host==.ingress.host and
        (if $type=="vmess" then .profile=="vmess_ws" and (.client.alter_id // 0)==0 and .client.security=="auto"
         else .profile=="vless_ws" and (.client.flow // "")=="" end) and ((.client.tls.reality.enabled // false)|not)' "$node" >/dev/null || { _error 'CDN WS 分享身份、Host/SNI、AEAD 或 flow 不完整'; return 1; }
    cdn=$(jq -c '.ingress + {path:.client.transport.path}' "$node") || return 1
    sbd_entry_cdn "$cdn" || return 1
    jq -e '(.client.transport|keys-["type","path","headers"]|length)==0 and
        (.client.transport.headers|keys-["Host"]|length)==0' "$node" >/dev/null || { _error 'URI 不能完整表达额外 WS 参数或请求头，保留旧输出'; return 1; }
    query=$(sbd_share_tls_query "$node" "$type") || return 1
    # URI 用 path 的 ?ed= 表达早期数据；原生客户端 JSON 的 path 不含查询串。
    query=$(jq --slurpfile node "$node" --arg type "$type" --arg ed "$SBD_WS_EARLY_DATA" '. + {type:"ws",security:"tls",host:$node[0].ingress.host,
        path:($node[0].client.transport.path + "?ed=" + $ed),
        encryption:(if $type=="vmess" then "auto" else "none" end)}' <<< "$query") || return 1
    sbd_share_uuid_emit "$node" "$type" "$query"
}

sbd_share_vmess_ws() { sbd_share_ws "$1" vmess; }
sbd_share_vless_ws() { sbd_share_ws "$1" vless; }

sbd_share_vless_reality() {
    local node="$1" query
    jq -e '.profile=="vless_reality" and .client.type=="vless" and .client.flow=="xtls-rprx-vision" and
        .client.tls.reality.enabled==true and .client.tls.utls.enabled==true and
        (.client.tls.utls.fingerprint|type=="string" and length>0) and
        (.client.tls.reality.public_key|type=="string" and length>0) and (.client.tls.reality.short_id|type=="string") and
        (.client|has("transport")|not)' "$node" >/dev/null || { _error 'VLESS Reality 缺少 Vision、公钥、short_id 或 uTLS 参数'; return 1; }
    query=$(sbd_share_tls_query "$node" vless) || return 1
    query=$(jq --slurpfile node "$node" '. + {type:"tcp",security:"reality",encryption:"none",flow:"xtls-rprx-vision",
        pbk:$node[0].client.tls.reality.public_key,sid:$node[0].client.tls.reality.short_id}' <<< "$query") || return 1
    sbd_share_uuid_emit "$node" vless "$query"
}

sbd_share_anytls() {
    local node="$1" query
    jq -e '.profile=="anytls" and .client.type=="anytls" and ((.client.tls.reality.enabled // false)|not)' "$node" >/dev/null || { _error 'AnyTLS 分享配置档不一致'; return 1; }
    query=$(sbd_share_tls_query "$node" anytls) || return 1
    query=$(jq '. + {security:"tls"}' <<< "$query") || return 1
    sbd_share_emit "$node" anytls "$query"
}

sbd_share_anyreality() {
    local node="$1" query
    jq -e '.profile=="anyreality" and .client.type=="anytls" and .client.tls.reality.enabled==true and
        .client.tls.utls.enabled==true and (.client.tls.utls.fingerprint|type=="string" and length>0) and
        (.client.tls.reality.public_key|type=="string" and length>0) and (.client.tls.reality.short_id|type=="string")' "$node" >/dev/null || { _error 'AnyReality 缺少 Reality 公钥、short_id 或 uTLS 参数'; return 1; }
    query=$(sbd_share_tls_query "$node" anytls) || return 1
    query=$(jq --slurpfile node "$node" '. + {security:"reality",pbk:$node[0].client.tls.reality.public_key,sid:$node[0].client.tls.reality.short_id}' <<< "$query") || return 1
    sbd_share_emit "$node" anytls "$query"
}

sbd_share_hysteria2() {
    local node="$1" query kind password low high
    jq -e '.profile=="hysteria2" and .client.type=="hysteria2" and ((.client.tls.reality.enabled // false)|not)' "$node" >/dev/null || { _error 'Hysteria2 分享配置档不一致'; return 1; }
    query=$(sbd_share_tls_query "$node" hysteria2) || return 1
    kind=$(jq -r '.client.obfs.type // "none"' "$node") || return 1
    case "$kind" in
        none) ;;
        salamander|gecko)
            password=$(sbd_entry_text "$node" .client.obfs.password 混淆密码) || return 1
            query=$(jq --arg kind "$kind" --rawfile password <(printf '%s' "$password") '. + {obfs:$kind,"obfs-password":$password}' <<< "$query") || return 1
            if [[ "$kind" = gecko ]]; then
                if ! low=$(jq -r '.client.obfs.min_packet_size // 512' "$node") || ! low=$(sbd_integer "$low" 1 65535) ||
                    ! high=$(jq -r '.client.obfs.max_packet_size // 1200' "$node") || ! high=$(sbd_integer "$high" "$low" 65535); then _error 'Gecko 尺寸无效'; return 1; fi
                query=$(jq --arg low "$low" --arg high "$high" '. + {minPacketSize:$low,maxPacketSize:$high}' <<< "$query") || return 1
            fi
            ;;
        *) _error '未知 Hysteria2 混淆'; return 1 ;;
    esac
    if jq -e '(.client.server_ports // [] | length)>0' "$node" >/dev/null; then
        query=$(jq --slurpfile node "$node" '. + {mport:($node[0].client.server_ports|map(gsub(":";"-"))|join(","))}' <<< "$query") || return 1
    fi
    # 客户端带宽必须随链接交付，否则导入端会回落到 BBR，服务端带宽上限也随之失效。
    if jq -e '((.client.up_mbps // 0) > 0) and ((.client.down_mbps // 0) > 0)' "$node" >/dev/null; then
        query=$(jq --slurpfile node "$node" '. + {upmbps:($node[0].client.up_mbps|tostring),downmbps:($node[0].client.down_mbps|tostring)}' <<< "$query") || return 1
    fi
    sbd_share_emit "$node" hysteria2 "$query"
}

sbd_export_metadata_check() {
    jq -e '
        def text: type=="string" and length>0;
        .format==1 and (.nodes|type=="array") and
        all(.nodes[];
            (.id|text and test("^[A-Za-z][A-Za-z0-9_.-]{0,63}$") and .!="schema" and .!="links") and (.name|text) and
            (.profile|text) and (.inbound_tag|text) and (.client|type=="object") and
            (.client.type|text) and (.client.server|text) and
            (if .client.type=="anytls" or .client.type=="hysteria2" or .client.type=="shadowsocks" then (.client.password|text)
             elif .client.type=="vmess" or .client.type=="vless" then (.client.uuid|text) else false end) and
            (if .client.type=="shadowsocks" then (.client.method|text) else true end) and
            (.client.server_port|type=="number" and floor==. and .>=1 and .<=65535)) and
        ([.nodes[].id]|length== (unique|length)) and
        ([.nodes[].inbound_tag]|length== (unique|length))
    ' "$1" >/dev/null 2>&1 || { _error '节点元数据缺失、重复或无效，保留旧输出'; return 1; }
}

# 从 registry 全量重建 exports：逐节点校验并生成客户端 JSON/分享链接。
# 对齐失败的节点保留旧导出并标为待协调，不让无关节点的历史漂移阻塞本次删除或编辑。
sbd_export_rebuild() {
    local stage="$1" isolate="${2:-}" mode="${3:-isolate}" next="$1/exports-next" work="$1/export-work"
    local count index id name outbound uri content stale='' old is_target targets stamp fresh
    targets=",$isolate,"
    sbd_export_metadata_check "$stage/registry.json" || return 1
    [[ ! -e "$next" && ! -e "$work" ]] || { _error '导出候选位置被占用'; return 1; }
    mkdir -m 700 -- "$next" "$work" || { _error '创建导出候选失败'; return 1; }
    old="$stage/exports"
    [[ ! -d "$old" ]] || cp -a -- "$old/." "$next/" || { _error '复制旧导出失败'; return 1; }
    # 重建分享清单时排除旧文件；失败节点仍沿用 next 中复制过来的旧资料。
    printf '' > "$next/links.txt" || { _error '创建分享清单失败'; return 1; }
    count=$(jq -r '.nodes|length' "$stage/registry.json") || return 1
    index=0
    while (( index < count )); do
        jq --argjson index "$index" '.nodes[$index]' "$stage/registry.json" > "$work/node.json" || { _error '读取节点资料失败'; return 1; }
        id=$(jq -er '.id' "$work/node.json") && name=$(jq -er '.name' "$work/node.json") || return 1
        # 本次操作的节点必须通过严格校验；其余节点的历史漂移才允许隔离。
        is_target=false
        [[ "$targets" != *",$id,"* ]] || is_target=true
        # 登记中的事实指纹记录上次通过校验的 inbound 形态：配置未变就直接复用，
        # 手动改过 config.json 才重新校验，避免每次操作都对全部节点重跑 TLS 检查。
        stamp=$(sbd_export_stamp "$stage" "$work/node.json") || { _error '计算节点配置摘要失败'; return 1; }
        fresh=false
        if [[ -s "$next/$id.txt" && -s "$next/$id.json" ]] &&
            jq -e --arg stamp "$stamp" '.facts_stamp == $stamp' "$work/node.json" >/dev/null; then
            fresh=true
        fi
        # 漂移节点保留旧导出，但不得进入当前分享清单冒充最新资料。
        if [[ "$fresh" != true ]] && jq -e '(.stale // false)==true' "$work/node.json" >/dev/null; then
            if [[ "$mode" = strict && "$is_target" = true ]]; then
                _error "本次操作的节点登记仍待协调，拒绝提交: $name"
                return 1
            fi
            stale="$stale $name($id)"
            index=$((index+1))
            continue
        fi
        if [[ "$fresh" != true ]] && ! jq -e --slurpfile node "$work/node.json" '[.inbounds[]? | select(.tag==$node[0].inbound_tag)] | length==1 and .[0].type==$node[0].client.type' "$stage/config.json" >/dev/null; then
            [[ "$mode" != strict || "$is_target" != true ]] || { _error "本次操作的节点关联 inbound 已缺失、重复或协议不一致: $name"; return 1; }
            sbd_export_stale_mark "$stage" "$id" '节点关联的 inbound 缺失、重复或协议不一致' || return 1
            stale="$stale $name($id)"
            index=$((index+1))
            continue
        fi
        if [[ "$fresh" != true ]] && ! sbd_entry_align "$stage" "$work/node.json"; then
            if [[ "$mode" = strict && "$is_target" = true ]]; then
                _error "本次操作的节点仍与已提交配置不一致，拒绝提交: $name"
                return 1
            fi
            sbd_export_stale_mark "$stage" "$id" '服务端事实与登记不一致' || return 1
            stale="$stale $name($id)"
            index=$((index+1))
            continue
        fi
        outbound=$(jq '.client + {tag:.id}' "$work/node.json") || return 1
        content=$(jq -n --slurpfile outbound <(printf '%s' "$outbound") --arg id "$id" '{log:{level:"warn"},dns:{servers:[{type:"local",tag:"system"}],final:"system"},outbounds:$outbound,route:{final:$id,default_domain_resolver:"system"}}') || return 1
        sbd_record_write "$work/config.json" "$content" || return 1
        sbd_prepare_config "$work" || { _error "客户端配置检查失败: $id"; return 1; }
        uri=$(sbd_share_build "$work/node.json") || return 1
        [[ -n "$uri" && "$uri" != *$'\n'* && "$uri" = *://* ]] || { _error '分享适配器没有生成单行 URI，保留旧输出'; return 1; }
        if ! cp -- "$work/config.json" "$next/$id.json" || ! cp -- "$work/schema.json" "$next/schema.json" ||
            ! printf '%s\n' "$uri" > "$next/$id.txt" || ! printf '%s\n' "$uri" >> "$next/links.txt"; then
            _error "写入节点导出失败: $name"; return 1
        fi
        sbd_export_stamp_save "$stage" "$id" "$stamp" || return 1
        index=$((index+1))
    done
    sbd_export_prune "$stage" "$next" || return 1
    [[ -z "$stale" ]] || printf '[信息] 以下节点与当前配置不一致，已保留旧导出:%s\n' "$stale" >&2
    rm -rf -- "$stage/exports" || { _error '替换暂存导出失败'; return 1; }
    mv -- "$next" "$stage/exports" || { _error '发布暂存导出失败'; return 1; }
}

# 删除节点只清理该节点的派生输出并刷新分享清单，不重验其余节点的服务端事实。
sbd_export_delete_cleanup() {
    local stage="$1" next id
    sbd_export_metadata_check "$stage/registry.json" || return 1
    next=$(mktemp -d "$stage/exports.XXXXXXXX") || { _error '创建暂存导出目录失败'; return 1; }
    if [[ -d "$stage/exports" ]]; then
        cp -a -- "$stage/exports/." "$next/" || { _error '复制现有导出失败'; return 1; }
    fi
    sbd_export_prune "$stage" "$next" || return 1
    : > "$next/links.txt" || { _error '清空分享清单失败'; return 1; }
    while IFS= read -r id; do
        [[ -n "$id" && -s "$next/$id.txt" ]] || continue
        jq -e --arg id "$id" '.nodes[]|select(.id==$id)|(.stale // false)==false' "$stage/registry.json" >/dev/null || continue
        cat -- "$next/$id.txt" >> "$next/links.txt" || { _error '重建分享清单失败'; return 1; }
    done < <(jq -r '.nodes[].id' "$stage/registry.json") || return 1
    rm -rf -- "$stage/exports" || { _error '替换暂存导出失败'; return 1; }
    mv -- "$next" "$stage/exports" || { _error '发布暂存导出失败'; return 1; }
}

sbd_export_stale_mark() {
    local stage="$1" id="$2" reason="$3" content
    content=$(jq --arg id "$id" --arg reason "$reason" '(.nodes[]|select(.id==$id)) |= (. + {stale:true,stale_reason:$reason})' "$stage/registry.json") || return 1
    sbd_record_write "$stage/registry.json" "$content"
}

# 节点事实指纹：覆盖 inbound_tag、config.json 中的该 inbound 及引用证书内容，不使用 mtime。
sbd_export_stamp() {
    local stage="$1" node="$2" tag inbound kind id cert cert_sha=''
    tag=$(jq -er '.inbound_tag' "$node") || return 1
    inbound=$(jq -cS --arg tag "$tag" '[.inbounds[]? | select(.tag==$tag)] | if length==1 then .[0] else null end' "$stage/config.json") || return 1
    kind=$(jq -r '.tls_source.kind // empty' "$node") || return 1
    if [[ "$kind" = certificate ]]; then
        id=$(jq -r '.tls_source.id // empty' "$node") || return 1
        cert=$(jq -r --arg id "$id" '[.tls.certificates[]? | select(.id==$id) | .certificate_path][0] // empty' "$stage/registry.json") || return 1
        if [[ -n "$cert" && -f "$cert" ]]; then
            cert_sha=$(sbd_entry_cert_sha "$cert" 2>/dev/null) || cert_sha='unreadable'
        else
            cert_sha='missing'
        fi
    fi
    jq -cn --argjson inbound "$inbound" --arg cert_sha "$cert_sha" \
        '{inbound:$inbound,certificate_sha256:(if $cert_sha=="" then null else $cert_sha end)}' |
        sha256sum | cut -d' ' -f1 || return 1
}

sbd_export_clear_stale() {
    local stage="$1" id="$2" content
    jq -e --arg id "$id" '.nodes[]|select(.id==$id)|has("stale")' "$stage/registry.json" >/dev/null 2>&1 || return 0
    content=$(jq --arg id "$id" '(.nodes[]|select(.id==$id)) |= del(.stale,.stale_reason)' "$stage/registry.json") || return 1
    sbd_record_write "$stage/registry.json" "$content"
}

sbd_export_stamp_save() {
    local stage="$1" id="$2" stamp="$3" content
    content=$(jq --arg id "$id" --arg stamp "$stamp" '(.nodes[]|select(.id==$id)) |= (. + {facts_stamp:$stamp} + {stale:false} | del(.stale_reason))' "$stage/registry.json") || return 1
    sbd_record_write "$stage/registry.json" "$content"
}

# exports 只保留当前登记节点的派生文件；删除节点的旧链接不能继续残留。
sbd_export_prune() {
    local stage="$1" next="$2" path name id
    while IFS= read -r -d '' path; do
        name=$(basename -- "$path") || return 1
        case "$name" in
            links.txt|schema.json) ;;
            *.json|*.txt)
                id="${name%.*}"
                [[ "$name" = "$id.json" || "$name" = "$id.txt" ]] || { rm -f -- "$path"; continue; }
                jq -e --arg id "$id" '.nodes[]|select(.id==$id)' "$stage/registry.json" >/dev/null 2>&1 || rm -f -- "$path" ;;
            *) rm -f -- "$path" ;;
        esac
    done < <(find "$next" -maxdepth 1 -type f -print0)
}

sbd_export_node() {
    local id="$1" kind="$2" display="${3:-normal}" node path metadata
    [[ "$id" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,63}$ && "$id" != schema && "$id" != links ]] || { _error '无效的节点资料 ID'; return 1; }
    node=$(jq -ce --arg id "$id" '[.nodes[]?|select(.id==$id)]|select(length==1)|.[0]' "$SBD_REGISTRY") || { _error '该节点登记已不存在或重复，不显示其他节点资料'; return 1; }
    metadata=$(jq -n --slurpfile node <(printf '%s' "$node") '{format:1,nodes:$node}') || return 1
    sbd_export_metadata_check /dev/stdin <<< "$metadata" || return 1
    case "$kind" in link) path="$SBD_EXPORTS/$id.txt" ;; json) path="$SBD_EXPORTS/$id.json" ;; *) _error '未知节点资料类型'; return 1 ;; esac
    [[ -s "$path" ]] || { _error "该节点尚无可读取的已提交导出: $path"; return 1; }
    if [[ "$display" != inline ]]; then printf '节点: %s (%s)\n' "$(jq -r .name <<< "$node")" "$id"; fi
    if [[ "$kind" = link ]]; then
        if [[ "$display" = inline ]]; then
            printf '  '; sbd_ui_tint 36 '分享链接: '
        else sbd_info '以下是已提交的分享链接，含凭据；未实时重建，也不代表连通已验证'; fi
        cat -- "$path" || { _error '读取该节点分享链接失败'; return 1; }
    else
        if [[ "$display" = inline ]]; then printf '  客户端 JSON: %s\n' "$path"
        else printf '客户端 JSON: %s\n' "$path"; fi
    fi
}
