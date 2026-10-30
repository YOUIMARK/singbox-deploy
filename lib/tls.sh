#!/usr/bin/env bash

sbd_tls_identity() {
    python3 - "$1" <<'PY'
import ipaddress
import re
import sys
value = sys.argv[1]
try:
    print("IP:" + str(ipaddress.ip_address(value)))
except ValueError:
    if len(value) > 253 or not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", x) for x in value.split(".")):
        raise SystemExit(1)
    print("DNS:" + value)
PY
}

sbd_tls_tag() {
    [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,63}$ ]] || { _error '标识须以字母开头，只含字母、数字、点、横线或下划线，最长 64 字符'; return 1; }
}

sbd_tls_pair() {
    local cert="$1" key="$2" name="$3" dir="$4" identity
    identity=$(sbd_tls_identity "$name") || { _error '证书名称须为 DNS 名称或 IP 地址'; return 1; }
    if ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then _error '证书不可读、无效或已过期'; return 1; fi
    if ! openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -q 'Subject Alternative Name'; then
        _error '证书缺少 subjectAltName，不能仅依靠旧式 CN'; return 1
    fi
    if [[ "$identity" = IP:* ]]; then
        openssl x509 -in "$cert" -noout -checkip "$name" >/dev/null 2>&1 || { _error '证书不匹配 IP 地址'; return 1; }
    else
        openssl x509 -in "$cert" -noout -checkhost "$name" >/dev/null 2>&1 || { _error '证书不匹配 DNS 名称'; return 1; }
    fi
    if ! openssl x509 -in "$cert" -pubkey -noout > "$dir/cert-public.pem" 2>/dev/null ||
        ! openssl pkey -in "$key" -passin pass: -pubout > "$dir/key-public.pem" 2>/dev/null ||
        ! cmp -s "$dir/cert-public.pem" "$dir/key-public.pem"; then
        _error '私钥不可读、需要口令或与证书不匹配'; return 1
    fi
}

sbd_tls_pin() (
    set -o pipefail
    openssl x509 -in "$1" -pubkey -noout | openssl pkey -pubin -outform DER |
        openssl dgst -sha256 -binary | openssl base64 -A || { _error '证书公钥 pin 生成失败'; return 1; }
)

sbd_tls_provider_add() {
    local stage="$1" tag="$2" domain="$3" email="$4" challenge="$5" content identity
    sbd_tls_tag "$tag" || return 1
    identity=$(sbd_tls_identity "${domain#\*.}") || { _error 'ACME 域名无效'; return 1; }
    [[ "$identity" = DNS:* && "$email" = ?*@?* ]] || { _error 'DNS-01 需要域名和联系邮箱'; return 1; }
    # 这里只校验菜单承诺的必填凭据；配置类型和字段仍交官方 Schema/check。
    jq -e 'def nonempty: type=="string" and length>0;
        if .provider=="cloudflare" then (.api_token|nonempty)
        elif .provider=="alidns" then (.access_key_id|nonempty) and (.access_key_secret|nonempty)
        elif .provider=="acmedns" then (.username|nonempty) and (.password|nonempty) and (.subdomain|nonempty) and (.server_url|nonempty)
        else false end' <<< "$challenge" >/dev/null 2>&1 || { _error 'DNS-01 provider 或必填凭据无效'; return 1; }
    jq -e --arg tag "$tag" 'all((.certificate_providers // [])[]; .tag!=$tag)' "$stage/config.json" >/dev/null || { _error '此 provider 标识已存在，不覆盖自定义或正在使用的配置'; return 1; }
    content=$(jq --arg tag "$tag" --arg domain "$domain" --arg email "$email" --arg dir "$SBD_DATA/acme/$tag" --argjson challenge "$challenge" '
        .certificate_providers = ((.certificate_providers // []) + [{type:"acme",tag:$tag,domain:[$domain],email:$email,
        data_directory:$dir,key_type:"p256",dns01_challenge:$challenge}])' "$stage/config.json") || { _error '构造 ACME provider 失败'; return 1; }
    sbd_record_write "$stage/config.json" "$content" || return 1
    content=$(jq --arg tag "$tag" '.tls.providers = ((.tls.providers // []) + [$tag])' "$stage/registry.json") || return 1
    sbd_record_write "$stage/registry.json" "$content"
}

sbd_tls_material_add() {
    local stage="$1" kind="$2" name="$3" cert="${4:-}" key="${5:-}" directory id identity pin content
    identity=$(sbd_tls_identity "$name") || { _error '证书名称须为 DNS 名称或 IP 地址'; return 1; }
    case "$kind" in
        self_signed)
            # 先登记最终的独立路径，再生成材料；从不覆盖核心正在监视的旧证书。
            directory=$(mktemp -d "$stage/cert.XXXXXXXX") || { _error '创建证书候选位置失败'; return 1; }
            id="${directory##*/}"; directory="$SBD_DATA/certificates/$id"
            sbd_material_note created_materials "$directory" || return 1
            if ! mkdir -p -- "$SBD_DATA/certificates" || ! chmod 700 -- "$SBD_DATA/certificates" || ! mkdir -m 700 -- "$directory"; then
                _error '创建证书材料目录失败'; return 1
            fi
            cert="$directory/cert.pem" key="$directory/key.pem"
            if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -sha256 -days 3650 \
                -subj "/CN=$name" -addext "subjectAltName=$identity" -addext 'basicConstraints=critical,CA:FALSE' \
                -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=serverAuth' \
                -keyout "$key" -out "$cert" > "$stage/openssl.log" 2>&1; then
                _error 'P-256 自签证书生成失败'; return 1
            fi
            chmod 600 -- "$cert" "$key" || { _error '设置证书权限失败'; return 1; }
            ;;
        import)
            [[ "$cert" = /* && "$key" = /* ]] || { _error '导入证书和私钥必须使用绝对路径'; return 1; }
            id=$(openssl rand -hex 8) || { _error '生成证书标识失败'; return 1; }
            id="pem.$id"; directory=''
            ;;
        *) _error '未知证书来源'; return 1 ;;
    esac
    sbd_tls_pair "$cert" "$key" "$name" "$stage" || return 1
    pin=$(sbd_tls_pin "$cert") || return 1
    content=$(jq --arg id "$id" --arg kind "$kind" --arg name "$name" --arg cert "$cert" --arg key "$key" --arg directory "$directory" --arg pin "$pin" '
        .tls.certificates = ((.tls.certificates // []) + [{id:$id,kind:$kind,server_name:$name,
        certificate_path:$cert,key_path:$key,directory:$directory,public_key_sha256:$pin}])' "$stage/registry.json") || { _error '生成证书元数据失败'; return 1; }
    sbd_record_write "$stage/registry.json" "$content"
}

sbd_tls_server() {
    local stage="$1" kind="$2" id="$3" value cert key name
    case "$kind" in
        provider)
            value=$(jq -ce --arg id "$id" '[.certificate_providers[]? | select(.tag==$id)] | select(length==1) | .[0]' "$stage/config.json") || { _error 'provider 缺失或重复'; return 1; }
            jq -n --arg id "$id" '{enabled:true,certificate_provider:$id}' || return 1
            ;;
        certificate)
            value=$(jq -ce --arg id "$id" '[.tls.certificates[]? | select(.id==$id)] | select(length==1) | .[0]' "$stage/registry.json") || { _error '证书元数据缺失或重复'; return 1; }
            if ! cert=$(jq -er '.certificate_path | select(type=="string" and length>0)' <<< "$value") ||
                ! key=$(jq -er '.key_path | select(type=="string" and length>0)' <<< "$value") ||
                ! name=$(jq -er '.server_name | select(type=="string" and length>0)' <<< "$value"); then _error '证书元数据不完整'; return 1; fi
            sbd_tls_pair "$cert" "$key" "$name" "$stage" || return 1
            jq -n --arg cert "$cert" --arg key "$key" '{enabled:true,certificate_path:$cert,key_path:$key}' || return 1
            ;;
        *) _error '未知 TLS 来源'; return 1 ;;
    esac
}

sbd_tls_client() {
    local stage="$1" id="$2" trust="$3" value name cert pin
    value=$(jq -ce --arg id "$id" '[.tls.certificates[]? | select(.id==$id)] | select(length==1) | .[0]' "$stage/registry.json") || { _error '客户端证书资料缺失'; return 1; }
    if ! name=$(jq -er '.server_name | select(type=="string" and length>0)' <<< "$value") ||
        ! cert=$(jq -er '.certificate_path | select(type=="string" and length>0)' <<< "$value"); then _error '客户端证书资料不完整'; return 1; fi
    case "$trust" in
        pin)
            pin=$(sbd_tls_pin "$cert") || return 1
            jq -n --arg name "$name" --arg pin "$pin" '{enabled:true,server_name:$name,certificate_public_key_sha256:[$pin]}' ;;
        certificate)
            openssl x509 -in "$cert" -noout >/dev/null 2>&1 || { _error '客户端信任证书无效'; return 1; }
            jq -n --arg name "$name" --rawfile cert "$cert" '{enabled:true,server_name:$name,certificate:[$cert]}' ;;
        system)
            [[ "$(jq -r '.kind' <<< "$value")" != self_signed ]] || { _error '自签证书不能使用系统信任，须携带证书或公钥 pin'; return 1; }
            jq -n --arg name "$name" '{enabled:true,server_name:$name}' ;;
        *) _error '未知证书信任方式'; return 1 ;;
    esac || { _error '构造客户端 TLS 失败'; return 1; }
}

sbd_tls_remove() {
    local stage="$1" kind="$2" id="$3" content value cert key directory
    case "$kind" in
        provider)
            jq -e --arg id "$id" '(.tls.providers // []) | index($id)!=null' "$stage/registry.json" >/dev/null || { _error '不删除未登记的 provider'; return 1; }
            jq -e --arg id "$id" 'any(.. | objects; .certificate_provider?==$id)' "$stage/config.json" >/dev/null && { _error 'provider 仍被引用，请先迁移使用它的配置'; return 1; }
            content=$(jq --arg id "$id" '.certificate_providers |= map(select(.tag!=$id))' "$stage/config.json") || return 1
            sbd_record_write "$stage/config.json" "$content" || return 1
            content=$(jq --arg id "$id" '.tls.providers |= map(select(.!=$id))' "$stage/registry.json") || return 1
            ;;
        certificate)
            value=$(jq -ce --arg id "$id" '[.tls.certificates[]? | select(.id==$id)] | select(length==1) | .[0]' "$stage/registry.json") || { _error '未找到唯一的证书记录'; return 1; }
            if ! cert=$(jq -er '.certificate_path' <<< "$value") || ! key=$(jq -er '.key_path' <<< "$value") || ! directory=$(jq -er '.directory' <<< "$value"); then _error '证书记录不完整'; return 1; fi
            if jq -e --arg cert "$cert" --arg key "$key" 'any(.. | strings; .==$cert or .==$key)' "$stage/config.json" >/dev/null ||
                jq -e --arg id "$id" 'any(.nodes[]; .certificate_id?==$id)' "$stage/registry.json" >/dev/null; then
                _error '证书仍被引用，请先迁移使用它的配置'; return 1
            fi
            if [[ -n "$directory" ]]; then sbd_material_note retired_materials "$directory" || return 1; fi
            content=$(jq --arg id "$id" '.tls.certificates |= map(select(.id!=$id))' "$stage/registry.json") || return 1
            ;;
        *) _error '未知 TLS 来源'; return 1 ;;
    esac
    # 不操作原生 ACME 的账户/续期目录；外部 PEM 不取得删除权。
    sbd_record_write "$stage/registry.json" "$content"
}

sbd_tls_list() {
    [[ -f "$SBD_REGISTRY" ]] || { _error '节点登记文件不存在'; return 1; }
    jq -r '(.tls.providers // [])[] | "ACME provider: \(.)（保存配置不等于签发成功）"' "$SBD_REGISTRY" || return 1
    jq -r '(.tls.certificates // [])[] | "证书: \(.id)  \(.kind)  \(.server_name)"' "$SBD_REGISTRY" || return 1
}

sbd_tls_read_identity() {
    local label="$1" wildcard="${2:-false}"
    while true; do
        sbd_read_required "$label" || return $?
        if [[ "$wildcard" = true ]]; then
            [[ "$(sbd_tls_identity "${SBD_REPLY#\*.}" 2>/dev/null)" = DNS:* ]] && return 0
        else
            sbd_tls_identity "$SBD_REPLY" >/dev/null 2>&1 && return 0
        fi
        _error '请输入有效的 DNS 名称或 IP（ACME 只接受域名）'
    done
}

sbd_tls_provider_prompt() {
    local tag domain email choice token key username password subdomain url challenge optional region
    while true; do
        sbd_read_required '共享 provider 标识' || return $?
        if sbd_tls_tag "$SBD_REPLY"; then
            if [[ ! -f "$SBD_CONFIG" ]] || jq -e --arg tag "$SBD_REPLY" 'all(.certificate_providers[]?; .tag!=$tag)' "$SBD_CONFIG" >/dev/null; then break; fi
            _error '此标识已存在，请仅重新填写标识'
        fi
    done
    tag="$SBD_REPLY"
    sbd_tls_read_identity '签发域名（可用 *.example.com）' true || return $?; domain="$SBD_REPLY"
    while true; do
        sbd_read_required 'ACME 联系邮箱' || return $?
        [[ "$SBD_REPLY" = ?*@?* ]] && break
        _error '邮箱格式无效'
    done
    email="$SBD_REPLY"
    sbd_ui_options '[1] Cloudflare' '[2] AliDNS' '[3] ACME-DNS'
    sbd_read_integer 'DNS-01 provider' 1 3 || return $?; choice="$SBD_REPLY"
    case "$choice" in
        1)
            sbd_read_secret 'Cloudflare API token' || return $?; token="$SBD_REPLY"
            sbd_read_optional 'Cloudflare zone_token（需要独立 Zone token 时填写，不回显）' true || return $?; optional="$SBD_REPLY"
            challenge=$(jq -n --arg token "$token" --arg optional "$optional" '{provider:"cloudflare",api_token:$token} + (if $optional!="" then {zone_token:$optional} else {} end)') || return 1 ;;
        2)
            sbd_read_required 'AliDNS access_key_id' || return $?; token="$SBD_REPLY"
            sbd_read_secret 'AliDNS access_key_secret' || return $?; key="$SBD_REPLY"
            sbd_read_optional 'AliDNS region_id' || return $?; region="$SBD_REPLY"
            sbd_read_optional 'AliDNS security_token（使用 STS 时填写，不回显）' true || return $?; optional="$SBD_REPLY"
            challenge=$(jq -n --arg id "$token" --arg key "$key" --arg region "$region" --arg optional "$optional" '{provider:"alidns",access_key_id:$id,access_key_secret:$key} + (if $region!="" then {region_id:$region} else {} end) + (if $optional!="" then {security_token:$optional} else {} end)') || return 1 ;;
        3)
            sbd_read_required 'ACME-DNS username' || return $?; username="$SBD_REPLY"
            sbd_read_secret 'ACME-DNS password' || return $?; password="$SBD_REPLY"
            sbd_read_required 'ACME-DNS subdomain' || return $?; subdomain="$SBD_REPLY"
            while true; do
                sbd_read_required 'ACME-DNS server_url' || return $?; url="$SBD_REPLY"
                if python3 - "$url" <<'PY'
import sys
from urllib.parse import urlsplit
try:
    u = urlsplit(sys.argv[1])
    valid = u.scheme in ("https", "http") and bool(u.hostname) and not any(c.isspace() for c in sys.argv[1])
except ValueError:
    valid = False
raise SystemExit(0 if valid else 1)
PY
                then break; fi
                _error 'server_url 须为完整 HTTP/HTTPS 地址，请仅重新填写此字段'
            done
            challenge=$(jq -n --arg user "$username" --arg password "$password" --arg sub "$subdomain" --arg url "$url" '{provider:"acmedns",username:$user,password:$password,subdomain:$sub,server_url:$url}') || return 1 ;;
    esac
    sbd_apply sbd_tls_provider_add "$tag" "$domain" "$email" "$challenge" || return 1
    sbd_success 'ACME provider 配置已提交；未验证签发，首次使用时由核心申请和续期'
}

sbd_tls_material_prompt() {
    local kind="$1" name cert='' key='' scratch public key_public
    sbd_tls_read_identity '证书 DNS 名称或 IP（无域名可使用 IP）' || return $?; name="$SBD_REPLY"
    if [[ "$kind" = import ]]; then
        if [[ "$(sbd_tls_identity "$name")" = IP:* ]]; then scratch=-checkip; else scratch=-checkhost; fi
        while true; do
            sbd_read_required '证书 PEM 绝对路径（保留外部所有权）' || return $?; cert="$SBD_REPLY"
            if [[ "$cert" = /* ]] && openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 &&
                openssl x509 -in "$cert" -noout "$scratch" "$name" >/dev/null 2>&1 &&
                openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -q 'Subject Alternative Name'; then break; fi
            _error '证书须有效、含匹配名称的 SAN 且使用绝对路径，请重新填写证书路径'
        done
        public=$(openssl x509 -in "$cert" -pubkey -noout) || { _error '无法读取证书公钥'; return 1; }
        while true; do
            sbd_read_required '私钥 PEM 绝对路径（无口令）' || return $?; key="$SBD_REPLY"
            if [[ "$key" = /* ]] && key_public=$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null) && [[ "$key_public" = "$public" ]]; then break; fi
            _error '私钥须可无口令读取并匹配证书，请仅重新填写私钥路径'
        done
    fi
    sbd_apply sbd_tls_material_add "$kind" "$name" "$cert" "$key" || return 1
    sbd_success '证书资料已提交；未绑定节点、未验证外网 TLS 握手'
}

sbd_tls_remove_prompt() {
    local values id choice kind
    sbd_ui_options '[1] 共享 provider' '[2] PEM 证书资料'
    sbd_read_integer '删除类型' 1 2 || return $?; choice="$SBD_REPLY"
    if [[ "$choice" = 1 ]]; then
        kind=provider; values=$(jq -r '(.tls.providers // [])[]' "$SBD_REGISTRY") || return 1
    else
        kind=certificate; values=$(jq -r '(.tls.certificates // [])[] | .id' "$SBD_REGISTRY") || return 1
    fi
    [[ -n "$values" ]] || { sbd_info '暂无可删除的资料'; return 0; }
    local -a ids=()
    mapfile -t ids <<< "$values"
    for id in "${!ids[@]}"; do sbd_ui_rows "[$((id+1))] ${ids[id]}"; done
    sbd_read_integer '选择资料' 1 "${#ids[@]}" || return $?; id="${ids[SBD_REPLY-1]}"
    sbd_read_required '确认删除登记？输入 y 确认，其他输入取消' || return $?
    [[ "$SBD_REPLY" = y ]] || return 2
    sbd_apply sbd_tls_remove "$kind" "$id" || return 1
    sbd_success '登记已移除；保留外部 PEM 和原生 ACME 缓存，自有旧材料随最近快照保留至下一次成功变更'
}

sbd_tls_menu() {
    local choice rc page
    while true; do
        sbd_ui_menu 'TLS 与证书' '[1] 列出资料（不显示凭据）' '[2] 新建 DNS-01 ACME provider' \
            '[3] 导入外部 PEM' '[4] 生成 P-256 自签证书' '[5] 删除未引用资料' '[0] 返回'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 5 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) sbd_tls_list ;;
            2) sbd_tls_provider_prompt ;;
            3) sbd_tls_material_prompt import ;;
            4) sbd_tls_material_prompt self_signed ;;
            5) sbd_tls_remove_prompt ;;
        esac
        rc=$?
        [[ "$rc" = 0 || "$rc" = 2 ]] || return 1
        sbd_ui_pause "$page"
    done
}
