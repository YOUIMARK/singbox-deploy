#!/usr/bin/env bash

sbd_policy_begin() {
    python3 "$SBD_APP/support/policy_records.py" align "$1" || { _error '策略登记与配置不一致，取消变更'; return 1; }
}

sbd_policy_bundle() {
    local stage="$1" command="$2" request="${3:-}" content
    content=$(python3 "$SBD_APP/support/policy_records.py" "$command" "$stage" "$request") || return 1
    sbd_record_write "$stage/policy-bundle.json" "$content" || return 1
    content=$(jq -c '.config' "$stage/policy-bundle.json") || return 1
    sbd_record_write "$stage/config.json" "$content" || return 1
    content=$(jq -c '.registry' "$stage/policy-bundle.json") || return 1
    sbd_record_write "$stage/registry.json" "$content"
}

sbd_policy_finish() {
    sbd_prepare_config "$1" || return 1
    python3 "$SBD_APP/support/policy_records.py" refs "$1" || return 1
    sbd_policy_bundle "$1" sync
}

sbd_policy_edit() {
    local stage="$1" request="$2"
    sbd_policy_begin "$stage" || return 1
    sbd_policy_bundle "$stage" edit "$request" || return 1
    sbd_policy_finish "$stage"
}

sbd_policy_adopt() {
    local stage="$1" area="$2" id="$3" position="${4:--1}" request old=''
    case "$area" in route_rules|dns_rules|dns_servers|rule_sets|endpoints|connectors) ;; *) _error '未知接管区域'; return 1 ;; esac
    if [[ "$area" = *_rules && -z "$id" ]]; then id=$(openssl rand -hex 8) || return 1; id="rule.$id"; fi
    sbd_tls_tag "$id" || return 1
    if [[ "$area" = rule_sets ]]; then old=$(jq -r --arg id "$id" '.policy.rule_sets[]?|select(.id==$id)|.directory // empty' "$stage/registry.json") || return 1; fi
    request=$(jq -n --arg area "$area" --arg id "$id" --argjson position "$position" '{area:$area,id:$id,position:$position}') || return 1
    sbd_policy_bundle "$stage" adopt "$request" || return 1
    if [[ -n "$old" ]] && ! jq -e --arg old "$old" --arg id "$id" 'any(.policy.rule_sets[]?;.id==$id and .directory==$old)' "$stage/registry.json" >/dev/null; then
        sbd_material_note retired_materials "$old" || return 1
    fi
    sbd_policy_finish "$stage"
}

sbd_policy_rule() {
    local stage="$1" area="$2" action="$3" id="$4" value="${5:-}" position="${6:--1}" request
    [[ -n "$value" ]] || value='{}'
    case "$area" in route_rules|dns_rules) ;; *) _error '未知规则区域'; return 1 ;; esac
    if [[ "$action" = add ]]; then
        id=$(openssl rand -hex 8) || { _error '生成规则 ID 失败'; return 1; }; id="rule.$id"
    fi
    request=$(jq -n --arg area "$area" --arg action "$action" --arg id "$id" --argjson value "$value" --argjson position "$position" '
        {area:$area,action:$action,id:$id,value:$value} + (if $position>=0 then {position:$position} else {} end)') || { _error '规则请求不是有效 JSON'; return 1; }
    sbd_policy_edit "$stage" "$request"
}

sbd_rule_url() {
    python3 - "$1" <<'PY' || { _error '规则集 URL 须为有效的 HTTP/HTTPS 地址'; return 1; }
import sys
from urllib.parse import urlsplit
try:
    u = urlsplit(sys.argv[1])
    assert u.scheme in ("http", "https") and u.hostname and u.port != 0
except (ValueError, AssertionError):
    raise SystemExit(1)
PY
}

sbd_rule_extension() {
    local base="${1%%\?*}"
    base="${base%%#*}"
    case "${base##*/}" in
        *.srs) printf 'binary\n' ;;
        *.json) printf 'source\n' ;;
        *) return 1 ;;
    esac
}

sbd_rule_set_list() {
    local config="$1" count
    count=$(jq '(.route.rule_set // []) | length' "$config") || return 1
    if [[ "$count" = 0 ]]; then
        printf '  （暂无规则集；可用 [4] 添加）\n'
        return 0
    fi
    jq -r '(.route.rule_set // [])[] |
        ((.tag // "?") | if type=="array" then join(",") else . end) as $tag |
        (.type // "inline") as $type |
        if $type == "local" then "  \($tag)  local \(.format // "binary")  \(.path // "")"
        elif $type == "remote" then "  \($tag)  remote \(.format // "binary")  \(.url // "")  更新间隔 \(.update_interval // "1d")"
        else "  \($tag)  inline" end' "$config" || return 1
}

sbd_rule_material() {
    local stage="$1" origin="$2" kind input format directory id raw
    if ! kind=$(jq -er '.kind' <<< "$origin") || ! input=$(jq -er '.value' <<< "$origin") || ! format=$(jq -er '.format' <<< "$origin"); then
        _error '规则集来源事实不完整'; return 1
    fi
    case "$format" in source|binary) ;; *) _error '规则集格式只能是 source/binary'; return 1 ;; esac
    directory=$(mktemp -d "$stage/set.XXXXXXXX") || { _error '创建规则集候选失败'; return 1; }
    id="${directory##*/}"; directory="$SBD_DATA/rule-sets/$id"
    sbd_material_note created_materials "$directory" || return 1
    if ! mkdir -p -- "$SBD_DATA/rule-sets" || ! chmod 700 -- "$SBD_DATA/rule-sets" || ! mkdir -m 700 -- "$directory"; then
        _error '创建独立规则集路径失败'; return 1
    fi
    raw="$directory/source.json"; [[ "$format" != binary ]] || raw="$directory/rules.srs"
    case "$kind" in
        file)
            [[ "$input" = /* && -f "$input" && -r "$input" ]] || { _error '源规则集须为可读文件的绝对路径'; return 1; }
            cp -- "$input" "$raw" || { _error '复制源规则集失败'; return 1; } ;;
        url)
            sbd_rule_url "$input" || return 1
            sbd_download "$input" "$raw" || return 1 ;;
        *) _error '未知规则集来源'; return 1 ;;
    esac
    if [[ "$format" = source ]]; then
        "$SBD_BINARY" rule-set compile --output "$directory/rules.srs" "$directory/source.json" || { _error '核心编译规则集失败'; return 1; }
    else
        "$SBD_BINARY" rule-set decompile --output "$directory/source.json" "$directory/rules.srs" || { _error '核心解析二进制规则集失败'; return 1; }
    fi
    chmod 600 -- "$directory"/* || { _error '设置规则集文件权限失败'; return 1; }
    SBD_RULE_DIRECTORY="$directory"
}

# 构造单条规则集变更：校验来源、补显式 HTTP client 与核心缓存；结果放在 SBD_RULE_REQUEST/SBD_RULE_OLD。
sbd_rule_set_prepare() {
    local stage="$1" action="$2" tag="$3" value="${4:-}" origin="${5:-}" content directory='' old='' type format
    SBD_RULE_OLD=''
    if [[ "$action" != add ]]; then
        old=$(jq -er --arg tag "$tag" '.policy.rule_sets[]? | select(.id==$tag) | .directory // ""' "$stage/registry.json") || { _error '此规则集未托管'; return 1; }
    fi
    if [[ "$action" = update ]]; then
        origin=$(jq -ce --arg tag "$tag" '.policy.rule_sets[] | select(.id==$tag) | .origin' "$stage/registry.json") || { _error '没有可重新读取的本地来源'; return 1; }
        value=$(jq -ce --arg tag "$tag" '.route.rule_set[] | select(.tag==$tag and .type=="local")' "$stage/config.json") || { _error 'remote 更新交核心 update_interval，不模拟立即刷新'; return 1; }
        action=replace
    fi
    if [[ "$action" = add || "$action" = replace ]]; then
        jq -e --arg tag "$tag" '(.tag // $tag)==$tag' <<< "$value" >/dev/null || { _error '修改规则集时须保留原生 tag'; return 1; }
        type=$(jq -er '.type // "inline"' <<< "$value") || { _error '缺少规则集类型'; return 1; }
        case "$type" in
            local)
                if [[ -z "$origin" ]]; then
                    format=$(jq -r '.format // (if (.path|endswith(".srs")) then "binary" else "source" end)' <<< "$value") || return 1
                    origin=$(jq -c --arg format "$format" '{kind:"file",value:.path,format:$format}' <<< "$value") || return 1
                fi
                sbd_rule_material "$stage" "$origin" || return 1; directory="$SBD_RULE_DIRECTORY"
                value=$(jq --arg tag "$tag" --arg path "$directory/rules.srs" '. + {tag:$tag,format:"binary",path:$path}' <<< "$value") || return 1 ;;
            remote)
                sbd_rule_url "$(jq -r '.url' <<< "$value")" || return 1
                # 4B：不下载种子，不声明远端已验证。显式 HTTP client 避免隐式旧默认。
                value=$(jq --arg tag "$tag" '. + {tag:$tag} | .http_client //= {version:2}' <<< "$value") || return 1
                content=$(jq --arg path "$SBD_DATA/cache.db" 'if .experimental.cache_file==null then .experimental.cache_file={enabled:true,path:$path} else . end' "$stage/config.json") || return 1
                sbd_record_write "$stage/config.json" "$content" || return 1
                origin='{}' ;;
            inline) value=$(jq --arg tag "$tag" '. + {tag:$tag}' <<< "$value") || return 1; origin='{}' ;;
            *) _error '规则集类型只能是 local/remote/inline'; return 1 ;;
        esac
    elif [[ "$action" = delete ]]; then value='{}'; origin='{}'
    else _error '未知规则集操作'; return 1; fi
    [[ -n "$origin" ]] || origin='{}'
    SBD_RULE_REQUEST=$(jq -n --arg action "$action" --arg id "$tag" --argjson value "$value" --arg directory "$directory" --argjson origin "$origin" \
        '{area:"rule_sets",action:$action,id:$id,value:$value,directory:$directory,origin:$origin}') || return 1
    SBD_RULE_OLD="$old"
}

sbd_rule_set() {
    local stage="$1" action="$2" tag="$3" value="${4:-}" origin="${5:-}"
    sbd_tls_tag "$tag" || return 1
    sbd_policy_begin "$stage" || return 1
    sbd_rule_set_prepare "$stage" "$action" "$tag" "$value" "$origin" || return 1
    sbd_policy_bundle "$stage" edit "$SBD_RULE_REQUEST" || return 1
    [[ -z "$SBD_RULE_OLD" ]] || sbd_material_note retired_materials "$SBD_RULE_OLD" || return 1
    sbd_policy_finish "$stage"
}

# 一次事务添加多条规则集：每条仍走同一构造与登记路径，最后统一校验、格式化并只重启一次。
sbd_rule_sets_add() {
    local stage="$1" entries="$2" count i tag value origin
    count=$(jq -er 'length' <<< "$entries") || { _error '规则集请求不是数组'; return 1; }
    (( count > 0 )) || { _error '没有选择规则集'; return 1; }
    sbd_policy_begin "$stage" || return 1
    for ((i=0; i<count; i++)); do
        tag=$(jq -er --argjson i "$i" '.[$i].tag' <<< "$entries") || return 1
        sbd_tls_tag "$tag" || return 1
        value=$(jq -ce --argjson i "$i" '.[$i].value' <<< "$entries") || { _error '规则集定义不是 JSON'; return 1; }
        origin=$(jq -ce --argjson i "$i" '.[$i].origin // {}' <<< "$entries") || { _error '规则集来源不是 JSON'; return 1; }
        sbd_rule_set_prepare "$stage" add "$tag" "$value" "$origin" || return 1
        sbd_policy_bundle "$stage" edit "$SBD_RULE_REQUEST" || return 1
    done
    sbd_policy_finish "$stage"
}

sbd_rule_catalog() {
    cat <<'JSON'
[
  {"tag":"geosite-ads","title":"广告拦截 geosite-ads","url":"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/category-ads-all.srs"},
  {"tag":"geosite-private","title":"私有域名 geosite-private","url":"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/private.srs"},
  {"tag":"geoip-private","title":"私有 IP geoip-private","url":"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/private.srs"},
  {"tag":"geosite-cn","title":"中国域名 geosite-cn","url":"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs"},
  {"tag":"geoip-cn","title":"中国 IP geoip-cn","url":"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs"},
  {"tag":"geosite-google","title":"Google geosite-google","url":"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/google.srs"},
  {"tag":"geosite-youtube","title":"YouTube geosite-youtube","url":"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/youtube.srs"},
  {"tag":"geosite-telegram","title":"Telegram geosite-telegram","url":"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/telegram.srs"},
  {"tag":"geosite-netflix","title":"Netflix geosite-netflix","url":"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/netflix.srs"},
  {"tag":"geosite-ai","title":"AI 服务（非中国） geosite-ai","url":"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/category-ai-!cn.srs"},
  {"tag":"geosite-openai","title":"OpenAI geosite-openai","url":"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/openai.srs"}
]
JSON
}

# 解析多选编号：逗号/顿号/空白分隔，支持 3-5 区间；去重后按编号升序逐行输出。
sbd_rule_selection() {
    local raw="$1" count="$2" token low high n i out=''
    local -a tokens=()
    local -A chosen=()
    [[ "$count" =~ ^[0-9]{1,9}$ ]] || return 1
    raw="${raw//，/ }"; raw="${raw//、/ }"; raw="${raw//,/ }"; raw="${raw//；/ }"; raw="${raw//;/ }"
    read -ra tokens <<< "$raw" || true
    for token in "${tokens[@]}"; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            low=$(sbd_integer "${BASH_REMATCH[1]}" 1 "$count") || return 1
            high=$(sbd_integer "${BASH_REMATCH[2]}" 1 "$count") || return 1
            (( low <= high )) || return 1
            for ((n=low; n<=high; n++)); do chosen[$n]=1; done
        else
            n=$(sbd_integer "$token" 1 "$count") || return 1
            chosen[$n]=1
        fi
    done
    (( ${#chosen[@]} > 0 )) || return 1
    for ((i=1; i<=count; i++)); do
        [[ -z "${chosen[$i]:-}" ]] || out+="$i"$'\n'
    done
    printf '%s' "$out"
}

# 读取可多选的编号，非法输入重问；结果写入 SBD_REPLY（升序、去重、每行一个）。
sbd_read_selection() {
    local label="$1" count="$2" picked
    while true; do
        sbd_read_required "$label" || return $?
        if picked=$(sbd_rule_selection "$SBD_REPLY" "$count"); then
            SBD_REPLY="$picked"
            return 0
        fi
        _error "请输入 1 到 $count 的编号；可多选，用逗号或空格分隔，也支持 1-3 这样的范围"
    done
}

sbd_rule_set_prompt() {
    local pick source tag url path format base default origin value catalog count i
    sbd_ui_options '[1] 常用规则集（预设目录）' '[2] 自定义链接' '[3] 本地文件'
    sbd_read_integer '规则集来源' 1 3 || return $?
    pick="$SBD_REPLY"
    source=remote
    case "$pick" in
        1)
            catalog=$(sbd_rule_catalog) || return 1
            count=$(jq 'length' <<< "$catalog") || return 1
            for ((i=0; i<count; i++)); do
                sbd_ui_rows "[$((i+1))] $(jq -r --argjson i "$i" '.[$i].title' <<< "$catalog")" || return 1
            done
            sbd_read_selection '选择预设规则集（可多选：1,3 或 1-3）' "$count" || return $?
            # 编号已去重升序，按编号顺序展开为 entries，交给一次事务写入。
            SBD_SET_ENTRIES=$(jq -Rsc --argjson catalog "$catalog" '
                split("\n") | map(select(length>0) | tonumber - 1) |
                [ .[] as $i | $catalog[$i] | {tag:.tag,
                    value:{type:"remote",tag:.tag,format:"binary",url:.url,update_interval:"1d"},
                    origin:{}} ]' <<< "$SBD_REPLY") || { _error '构造预设规则集请求失败'; return 1; }
            return 0 ;;
        2)
            while true; do
                sbd_read_required '规则集链接（http/https）' || return $?
                url="$SBD_REPLY"
                sbd_rule_url "$url" && break
            done ;;
        3)
            source=local
            while true; do
                sbd_read_required '源文件绝对路径' || return $?
                path="$SBD_REPLY"
                [[ "$path" = /* && -f "$path" && -r "$path" ]] && break
                _error '请输入可读文件的绝对路径'
            done ;;
    esac
    if [[ "$source" = local ]]; then base="$path"; else base="$url"; fi
    if [[ -z "${format:-}" ]]; then
        if ! format=$(sbd_rule_extension "$base"); then
            sbd_ui_options '[1] source JSON' '[2] binary SRS'
            sbd_read_integer '文件格式' 1 2 || return $?
            format=source; [[ "$SBD_REPLY" != 2 ]] || format=binary
        fi
    fi
    if [[ "$pick" != 1 ]]; then
        default="${base%%\?*}"
        default="${default%%#*}"
        default="${default##*/}"
        default="${default%.*}"
        [[ "$default" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,63}$ ]] || default=''
        while true; do
            if [[ -n "$default" ]]; then sbd_entry_default '规则集名称' "$default" || return $?; else sbd_read_required '规则集名称' || return $?; fi
            tag="$SBD_REPLY"
            sbd_tls_tag "$tag" && break
        done
    fi
    if [[ "$source" = remote ]]; then
        value=$(jq -n --arg tag "$tag" --arg url "$url" --arg format "$format" \
            '{type:"remote",tag:$tag,format:$format,url:$url,update_interval:"1d"}') || return 1
        origin='{}'
        sbd_info "规则集 $tag 由核心按 1d 间隔下载并缓存；保存配置不代表远端已下载成功"
    else
        value=$(jq -n --arg tag "$tag" '{type:"local",tag:$tag}') || return 1
        origin=$(jq -n --arg path "$path" --arg format "$format" '{kind:"file",value:$path,format:$format}') || return 1
        sbd_info '导入时复制并编译为 SRS；源文件不会被修改'
    fi
    SBD_SET_ENTRIES=$(jq -c -n --arg tag "$tag" --argjson value "$value" --argjson origin "$origin" \
        '[{tag:$tag,value:$value,origin:$origin}]') || { _error '构造规则集请求失败'; return 1; }
}

sbd_rule_add_flow() {
    local rc tags
    rc=0; sbd_rule_set_prompt || rc=$?
    [[ "$rc" != 2 ]] || return 2
    [[ "$rc" = 0 ]] || return 1
    rc=0; sbd_policy_confirm || rc=$?
    [[ "$rc" != 2 ]] || return 2
    [[ "$rc" = 0 ]] || return 1
    tags=$(jq -er 'map(.tag) | join(", ")' <<< "$SBD_SET_ENTRIES") || return 1
    sbd_apply sbd_rule_sets_add "$SBD_SET_ENTRIES" || return 1
    sbd_success "规则集 $tags 已添加；在 route.rules 中引用对应 tag 后生效"
}

sbd_rule_set_remove() {
    local values tag count
    values=$(jq -c '[.policy.rule_sets[]? | {id, area:"rule_sets"}]' "$SBD_REGISTRY") || return 1
    [[ "$(jq length <<< "$values")" != 0 ]] || { _error '没有脚本管理的规则集；手工写入的请直接编辑 config.json'; return 1; }
    sbd_policy_pick "$values" '选择要删除的规则集' || return $?
    tag="$SBD_REPLY"
    count=$(jq --arg tag "$tag" '[(.route.rules // [])[], (.dns.rules // [])[]] |
        [.. | objects | .rule_set? | select(.!=null) | if type=="array" then .[] else . end |
         select(.==$tag)] | length' "$SBD_CONFIG") || { _error '读取规则集引用失败'; return 1; }
    if [[ "$count" != 0 ]]; then
        _error "仍有 $count 条路由/DNS 规则引用 $tag；请先在 config.json 删除这些规则"
        return 1
    fi
    sbd_policy_confirm || return $?
    sbd_apply sbd_rule_set delete "$tag" || return 1
    sbd_success "规则集 $tag 已删除"
}

sbd_route_defaults() {
    local stage="$1" defaults content
    defaults=$(jq -c '.route.rules // []' "$SBD_APP/presets/base.json") || { _error '读取默认路由规则失败'; return 1; }
    jq -e 'type=="array" and length>0' <<< "$defaults" >/dev/null || { _error '默认路由规则缺失'; return 1; }
    # 路由规则归用户所有：先放弃旧向导的位置登记，避免旧登记阻塞补齐。
    content=$(jq 'if .policy.route_rules then .policy.route_rules = [] else . end' "$stage/registry.json") || return 1
    sbd_record_write "$stage/registry.json" "$content" || return 1
    sbd_policy_begin "$stage" || return 1
    content=$(jq --argjson defaults "$defaults" '
        (.route.rules // []) as $current |
        .route.rules = ($defaults + [$current[] | select(. as $rule | ($defaults | index($rule)) == null)])' "$stage/config.json") || { _error '构造默认路由规则失败'; return 1; }
    sbd_record_write "$stage/config.json" "$content" || return 1
    sbd_policy_finish "$stage"
}

sbd_rule_defaults_prompt() {
    local rc
    sbd_info '默认规则：sniff 嗅探、DNS 流量交给内置 DNS、resolve 域名解析、拒绝私网地址'
    sbd_info '只补齐缺失的默认规则；已有自定义路由规则保留'
    rc=0; sbd_policy_confirm || rc=$?
    [[ "$rc" != 2 ]] || return 2
    [[ "$rc" = 0 ]] || return 1
    sbd_apply sbd_route_defaults || return 1
    sbd_success '默认路由规则已补齐'
}

sbd_policy_pick() {
    local values="$1" label="$2" count i text
    count=$(jq -er 'length' <<< "$values") || return 1
    (( count > 0 )) || { _error '暂无可选择对象'; return 1; }
    for ((i=0; i<count; i++)); do
        text=$(jq -r --argjson i "$i" '.[$i] | if type=="string" then . else (.id // .tag) end' <<< "$values") || return 1
        sbd_ui_rows "[$((i+1))] $text"
    done
    sbd_read_integer "$label" 1 "$count" || return $?
    SBD_REPLY=$(jq -r --argjson i "$((SBD_REPLY-1))" '.[$i] | if type=="string" then . else (.id // .tag) end' <<< "$values") || return 1
}

sbd_policy_choose() {
    local area="$1" values
    values=$(jq -c --arg area "$area" '.policy[$area] // []' "$SBD_REGISTRY") || return 1
    sbd_policy_pick "$values" '选择托管对象'
}

sbd_policy_target() {
    local kind="$1" mode="${2:-manual}" values config="$SBD_CONFIG"
    [[ -f "$config" ]] || config="$SBD_APP/presets/base.json"
    case "$kind" in
        dns) values=$(jq -c '[.dns.servers[]?.tag]' "$config") ;;
        outbound) values=$(jq -c '[(.outbounds[]?,.endpoints[]?)|.tag]' "$config") ;;
        rule_set) values=$(jq -c '[.route.rule_set[]?.tag|if type=="array" then .[] else . end]' "$config") ;;
        inbound) values=$(jq -c '[(.inbounds[]?,.endpoints[]?)|.tag]' "$config") ;;
        *) _error '未知目标类型'; return 1 ;;
    esac || { _error '读取原生目标失败'; return 1; }
    values=$(jq -c 'map(select(type=="string" and length>0))' <<< "$values") || return 1
    if [[ "$mode" = default && "$kind" = dns ]]; then
        SBD_REPLY=$(jq -er '(.route.default_domain_resolver | if type=="object" then .server else . end) // .dns.final // .dns.servers[0].tag | select(type=="string" and length>0)' "$config") || { _error '没有可用的默认 DNS'; return 1; }
        jq -e --arg tag "$SBD_REPLY" 'index($tag)!=null' <<< "$values" >/dev/null || { _error '默认 DNS 标识不存在'; return 1; }
        return 0
    fi
    if [[ "$mode" = auto ]] && [[ "$(jq length <<< "$values")" = 1 ]]; then
        [[ "${SBD_UI_EOF:-false}" != true ]] || return 2
        SBD_REPLY=$(jq -er '.[0]' <<< "$values") || return 1
        sbd_info "使用唯一目标: $SBD_REPLY"
        return 0
    fi
    sbd_policy_pick "$values" '选择目标标识'
}

sbd_policy_confirm() {
    sbd_read_required '确认提交并按需重启？输入 y 确认，其他输入取消' || return $?
    [[ "$SBD_REPLY" = y ]] || return 2
}

sbd_rules_menu() {
    local choice rc page config
    while true; do
        sbd_ui_menu '分流设置' '[1] 查看路由规则' '[2] 查看 DNS 规则' '[3] 查看规则集' \
            '[4] 添加规则集' '[5] 删除规则集' '[6] 恢复默认路由规则' '[0] 返回'
        sbd_config_hint
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 6 || return 0; choice="$SBD_REPLY"
        [[ "$choice" != 0 ]] || return 0
        config="$SBD_CONFIG"; [[ -f "$config" ]] || config="$SBD_APP/presets/base.json"
        case "$choice" in
            1) jq '.route.rules // []' "$config" || { _error '读取路由规则失败'; return 1; } ;;
            2) jq '.dns.rules // []' "$config" || { _error '读取 DNS 规则失败'; return 1; } ;;
            3) sbd_rule_set_list "$config" || return 1 ;;
            4)
                [[ -f "$SBD_CONFIG" ]] || { _error '请先创建配置'; continue; }
                rc=0; sbd_rule_add_flow || rc=$?
                [[ "$rc" = 2 ]] || sbd_ui_pause "$page"; continue ;;
            5)
                [[ -f "$SBD_CONFIG" ]] || { _error '请先创建配置'; continue; }
                rc=0; sbd_rule_set_remove || rc=$?
                [[ "$rc" = 2 ]] || sbd_ui_pause "$page"; continue ;;
            6)
                [[ -f "$SBD_CONFIG" ]] || { _error '请先创建配置'; continue; }
                rc=0; sbd_rule_defaults_prompt || rc=$?
                [[ "$rc" = 2 ]] || sbd_ui_pause "$page"; continue ;;
        esac
        sbd_ui_pause "$page"
    done
}
