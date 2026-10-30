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

sbd_rule_set() {
    local stage="$1" action="$2" tag="$3" value="${4:-}" origin="${5:-}" request content directory='' old='' type format
    sbd_tls_tag "$tag" || return 1
    sbd_policy_begin "$stage" || return 1
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
    request=$(jq -n --arg action "$action" --arg id "$tag" --argjson value "$value" --arg directory "$directory" --argjson origin "$origin" \
        '{area:"rule_sets",action:$action,id:$id,value:$value,directory:$directory,origin:$origin}') || return 1
    sbd_policy_bundle "$stage" edit "$request" || return 1
    [[ -z "$old" ]] || sbd_material_note retired_materials "$old" || return 1
    sbd_policy_finish "$stage"
}

sbd_policy_json_prompt() {
    local value
    while true; do
        sbd_read_required '原生 JSON 文件绝对路径' || return $?
        if [[ "$SBD_REPLY" = /* ]] && sbd_object "$SBD_REPLY" && value=$(jq -c . "$SBD_REPLY" 2>/dev/null); then
            SBD_REPLY="$value"; return 0
        fi
        _error '文件须可读且只含一个 JSON 对象，请重新填写路径'
    done
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
    local kind="$1" values config="$SBD_CONFIG"
    [[ -f "$config" ]] || config="$SBD_APP/presets/base.json"
    case "$kind" in
        dns) values=$(jq -c '[.dns.servers[]?.tag]' "$config") ;;
        outbound) values=$(jq -c '[(.outbounds[]?,.endpoints[]?)|.tag]' "$config") ;;
        rule_set) values=$(jq -c '[.route.rule_set[]?.tag|if type=="array" then .[] else . end]' "$config") ;;
        inbound) values=$(jq -c '[(.inbounds[]?,.endpoints[]?)|.tag]' "$config") ;;
        *) _error '未知目标类型'; return 1 ;;
    esac || { _error '读取原生目标失败'; return 1; }
    values=$(jq -c 'map(select(type=="string" and length>0))' <<< "$values") || return 1
    sbd_policy_pick "$values" '选择目标标识'
}

sbd_policy_confirm() {
    sbd_read_required '确认提交并按需重启？输入 y 确认，其他输入取消' || return $?
    [[ "$SBD_REPLY" = y ]] || return 2
}

sbd_policy_duration_prompt() {
    local value probe
    while true; do
        sbd_entry_default '核心更新间隔（原生 duration）' 1d || return $?; value="$SBD_REPLY"
        probe=$(jq -n --arg duration "$value" '{route:{rule_set:[{type:"remote",tag:"duration-probe",format:"binary",url:"http://127.0.0.1/rules.srs",http_client:{version:2},update_interval:$duration}]}}') || return 1
        if "$SBD_BINARY" format -c /dev/stdin <<< "$probe" >/dev/null 2>&1; then SBD_REPLY="$value"; return 0; fi
        _error '核心无法解析更新间隔，请重新填写 duration'
    done
}

sbd_policy_match_prompt() {
    local choice field value
    sbd_ui_options '[1] 完整域名' '[2] 域名后缀' '[3] 域名关键词' '[4] 目标 IP/CIDR' '[5] rule_set' '[6] inbound' '[7] 目标端口' '[8] 无条件匹配'
    sbd_read_integer '选择匹配条件' 1 8 || return $?; choice="$SBD_REPLY"
    case "$choice" in
        1|2|3)
            case "$choice" in 1) field=domain ;; 2) field=domain_suffix ;; 3) field=domain_keyword ;; esac
            sbd_read_required '匹配值' || return $?; value="$SBD_REPLY" ;;
        4)
            field=ip_cidr
            while true; do
                sbd_read_required 'IP 或 CIDR' || return $?
                if value=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1],strict=False))' "$SBD_REPLY" 2>/dev/null); then break; fi
                _error '请输入有效 IP/CIDR'
            done ;;
        5|6)
            field=rule_set; [[ "$choice" != 6 ]] || field=inbound
            sbd_policy_target "$field" || return $?; value="$SBD_REPLY" ;;
        7) field=port; sbd_entry_number_prompt '目标端口' 1 65535 || return $?; value="$SBD_REPLY" ;;
        8) SBD_MATCH='{}'; return 0 ;;
    esac
    if [[ "$field" = port ]]; then SBD_MATCH=$(jq -n --arg key "$field" --argjson value "$value" '{($key):[$value]}')
    else SBD_MATCH=$(jq -n --arg key "$field" --arg value "$value" '{($key):[$value]}'); fi || return 1
}

sbd_route_rule_prompt() {
    local action value server choice
    sbd_policy_match_prompt || return $?; value="$SBD_MATCH"
    sbd_ui_options '[1] route' '[2] reject' '[3] sniff' '[4] resolve' '[5] hijack-dns'
    sbd_read_integer '选择原生 action' 1 5 || return $?; choice="$SBD_REPLY"
    case "$choice" in
        1) action=route; sbd_policy_target outbound || return $?; server="$SBD_REPLY"; value=$(jq --arg server "$server" '. + {outbound:$server}' <<< "$value") || return 1 ;;
        2) action=reject ;;
        3) action=sniff ;;
        4) action=resolve; sbd_policy_target dns || return $?; server="$SBD_REPLY"; value=$(jq --arg server "$server" '. + {server:$server}' <<< "$value") || return 1 ;;
        5) action=hijack-dns ;;
    esac
    SBD_POLICY_VALUE=$(jq --arg action "$action" '. + {action:$action}' <<< "$value") || return 1
}

sbd_policy_rules_menu() {
    local area="$1" choice action id value position count rc page title
    title='路由规则'; [[ "$area" != dns_rules ]] || title='DNS 分流规则'
    while true; do
        sbd_ui_menu "$title" '[1] 查看原生规则与托管位置' '[2] 向导添加' '[3] JSON 添加' '[4] JSON 替换托管规则' '[5] 删除托管规则' '[6] 调整托管规则顺序' '[7] 向导重建托管规则（高级字段请用 JSON）' '[0] 返回'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 7 || return 0; choice="$SBD_REPLY"
        [[ "$choice" != 0 ]] || return 0
        if [[ "$choice" = 1 ]]; then
            if [[ "$area" = route_rules ]]; then jq '.route.rules // []' "$SBD_CONFIG"; else jq '.dns.rules // []' "$SBD_CONFIG"; fi || { _error '读取规则失败'; return 1; }
            jq --arg area "$area" '.policy[$area] // [] | map({id,position:(.index+1),group})' "$SBD_REGISTRY" || return 1
            sbd_ui_pause "$page"
            continue
        fi
        [[ -f "$SBD_CONFIG" ]] || { _error '请先创建配置'; return 1; }
        id=''; value='{}'; position=-1
        case "$choice" in
            2)
                action=add
                if [[ "$area" = route_rules ]]; then sbd_route_rule_prompt; else sbd_resolver_rule_prompt; fi
                rc=$?; [[ "$rc" = 0 ]] || return "$rc"; value="$SBD_POLICY_VALUE" ;;
            3) action=add; sbd_policy_json_prompt || return $?; value="$SBD_REPLY" ;;
            4) action=replace; sbd_policy_choose "$area" || return $?; id="$SBD_REPLY"; sbd_policy_json_prompt || return $?; value="$SBD_REPLY" ;;
            5) action=delete; sbd_policy_choose "$area" || return $?; id="$SBD_REPLY" ;;
            6) action=move; sbd_policy_choose "$area" || return $?; id="$SBD_REPLY" ;;
            7)
                action=replace; sbd_policy_choose "$area" || return $?; id="$SBD_REPLY"
                sbd_info '向导将重建此规则；如需保留高级字段，请取消并使用 JSON 替换'
                if [[ "$area" = route_rules ]]; then sbd_route_rule_prompt; else sbd_resolver_rule_prompt; fi
                rc=$?; [[ "$rc" = 0 ]] || return "$rc"; value="$SBD_POLICY_VALUE" ;;
        esac
        if [[ "$action" = add || "$action" = move ]]; then
            if [[ "$area" = route_rules ]]; then count=$(jq '.route.rules // []|length' "$SBD_CONFIG"); else count=$(jq '.dns.rules // []|length' "$SBD_CONFIG"); fi || return 1
            if [[ "$action" = add ]]; then count=$((count+1)); fi
            sbd_entry_number_prompt '目标位置（1 为最前；新增默认末尾）' 1 "$count" "$count" || return $?; position=$((SBD_REPLY-1))
        fi
        sbd_policy_confirm || return $?
        sbd_apply sbd_policy_rule "$area" "$action" "$id" "$value" "$position" || return 1
        sbd_success '规则及管理事实已提交；未验证实际分流命中'
        sbd_ui_pause "$page"
    done
}

sbd_rule_set_prompt() {
    local choice tag url format origin value path interval client resolver target
    sbd_ui_options '[1] 导入本地文件（JSON 编译或 SRS 解析）' '[2] 下载为 local（人工更新）' '[3] remote（核心首次运行下载及后续更新）' '[4] 原生 JSON 文件'
    sbd_read_integer '规则集来源' 1 4 || return $?; choice="$SBD_REPLY"
    if [[ "$choice" = 4 ]]; then
        sbd_policy_json_prompt || return $?; SBD_SET_VALUE="$SBD_REPLY"
        SBD_SET_TAG=$(jq -er '.tag|select(type=="string")' <<< "$SBD_REPLY") || { _error '托管规则集须使用单个原生 tag'; return 1; }
        SBD_SET_ORIGIN=''; return 0
    fi
    while true; do sbd_read_required '规则集 tag' || return $?; tag="$SBD_REPLY"; sbd_tls_tag "$tag" && break; done
    sbd_ui_options '[1] source JSON' '[2] binary SRS'
    sbd_read_integer '文件格式' 1 2 || return $?; format=source; [[ "$SBD_REPLY" != 2 ]] || format=binary
    if [[ "$choice" = 1 ]]; then
        while true; do
            sbd_read_required '源文件绝对路径' || return $?; path="$SBD_REPLY"
            [[ "$path" = /* && -r "$path" && -f "$path" ]] && break
            _error '请输入可读源文件的绝对路径'
        done
        origin=$(jq -n --arg path "$path" --arg format "$format" '{kind:"file",value:$path,format:$format}') || return 1
    else
        while true; do sbd_read_required '规则集 URL' || return $?; url="$SBD_REPLY"; sbd_rule_url "$url" && break; done
        origin=$(jq -n --arg url "$url" --arg format "$format" '{kind:"url",value:$url,format:$format}') || return 1
    fi
    if [[ "$choice" = 3 ]]; then
        sbd_policy_duration_prompt || return $?; interval="$SBD_REPLY"
        sbd_ui_options '[1] 原生 HTTP client 直连（默认）' '[2] 指定现有 outbound/endpoint'
        sbd_entry_number_prompt '下载拨号方式' 1 2 1 || return $?; target=''
        if [[ "$SBD_REPLY" = 2 ]]; then sbd_policy_target outbound || return $?; target="$SBD_REPLY"; fi
        sbd_policy_target dns || return $?; resolver="$SBD_REPLY"
        client=$(jq -n --arg resolver "$resolver" --arg detour "$target" '{version:2,domain_resolver:$resolver} + (if $detour!="" then {detour:$detour} else {} end)') || return 1
        value=$(jq -n --arg tag "$tag" --arg url "$url" --arg format "$format" --arg interval "$interval" --argjson client "$client" \
            '{type:"remote",tag:$tag,url:$url,format:$format,update_interval:$interval,http_client:$client}') || return 1
        origin='{}'
        sbd_info 'remote 首次不预下载；保存配置不代表远端有效，首次运行下载可能失败'
    else value=$(jq -n --arg tag "$tag" '{type:"local",tag:$tag}') || return 1; fi
    SBD_SET_TAG="$tag" SBD_SET_VALUE="$value" SBD_SET_ORIGIN="$origin"
}

sbd_rules_menu() {
    local choice action tag value origin rc page
    while true; do
        sbd_ui_menu '分流设置' '[1] 查看规则集' '[2] 添加规则集' '[3] JSON 替换托管规则集' '[4] 人工更新 local' '[5] 删除托管规则集' '[6] 路由规则' '[7] 选择 route.final 默认出口' '[0] 返回'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 7 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) jq '.route.rule_set // []' "$SBD_CONFIG" || { _error '读取规则集失败'; return 1; }; sbd_ui_pause "$page"; continue ;;
            6) sbd_policy_rules_menu route_rules; rc=$?; [[ "$rc" = 0 || "$rc" = 2 ]] || return 1; continue ;;
            7)
                sbd_policy_target outbound || return $?; value="$SBD_REPLY"
                sbd_policy_confirm || return $?
                sbd_apply sbd_resolver_default outbound "$value" || return 1
                sbd_success 'route.final 已提交；未验证出口连接'; sbd_ui_pause "$page"; continue ;;
            2) action=add; sbd_rule_set_prompt || return $?; tag="$SBD_SET_TAG" value="$SBD_SET_VALUE" origin="$SBD_SET_ORIGIN" ;;
            3) action=replace; sbd_policy_choose rule_sets || return $?; tag="$SBD_REPLY"; sbd_policy_json_prompt || return $?; value="$SBD_REPLY" origin='' ;;
            4|5)
                action=update; [[ "$choice" != 5 ]] || action=delete
                sbd_policy_choose rule_sets || return $?; tag="$SBD_REPLY"; value='' origin='' ;;
        esac
        sbd_policy_confirm || return $?
        sbd_apply sbd_rule_set "$action" "$tag" "$value" "$origin" || return 1
        sbd_success '规则集配置及管理事实已提交；remote 不代表首次下载成功，未验证实际分流命中'
        sbd_ui_pause "$page"
    done
}
