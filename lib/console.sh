#!/usr/bin/env bash

sbd_terminal() {
    [[ -t 0 ]] && return 0
    { exec </dev/tty; } 2>/dev/null && return 0
    _error '交互菜单需要终端，无法打开 /dev/tty'
    return 1
}

sbd_reset() {
    local stage="$1" category="$2" node content ids id directory
    sbd_policy_begin "$stage" || return 1
    case "$category" in
        nodes)
            ids=$(jq -r '.nodes[].id' "$stage/registry.json") || return 1
            while IFS= read -r id; do
                [[ -n "$id" ]] || continue
                node=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$stage/registry.json") || return 1
                sbd_record_write "$stage/reset-node.json" "$node" || return 1
                sbd_entry_align "$stage" "$stage/reset-node.json" delete || return 1
            done <<< "$ids" ;;
        rules_dns)
            ids=$(jq -r '.policy.rule_sets[]?.directory // empty|select(length>0)' "$stage/registry.json") || return 1
            while IFS= read -r directory; do [[ -z "$directory" ]] || sbd_material_note retired_materials "$directory" || return 1; done <<< "$ids" ;;
        peers) ;;
        tls)
            ids=$(jq -r '.tls.providers[]?' "$stage/registry.json") || return 1
            while IFS= read -r id; do [[ -z "$id" ]] || sbd_tls_remove "$stage" provider "$id" || return 1; done <<< "$ids"
            ids=$(jq -r '.tls.certificates[]?.id' "$stage/registry.json") || return 1
            while IFS= read -r id; do [[ -z "$id" ]] || sbd_tls_remove "$stage" certificate "$id" || return 1; done <<< "$ids"
            return 0 ;;
        *) _error '未知 reset 类别'; return 1 ;;
    esac
    content=$(python3 "$SBD_APP/support/policy_records.py" reset "$stage" "$category") || return 1
    sbd_record_write "$stage/reset-bundle.json" "$content" || return 1
    content=$(jq -c .config "$stage/reset-bundle.json") || return 1
    sbd_record_write "$stage/config.json" "$content" || return 1
    content=$(jq -c .registry "$stage/reset-bundle.json") || return 1
    sbd_record_write "$stage/registry.json" "$content" || return 1
    sbd_policy_finish "$stage" || return 1
    if [[ "$category" = nodes ]]; then sbd_export_rebuild "$stage" || return 1; fi
}

sbd_adopt_menu() {
    local choice area id position count tag facts node defaults name server port profile tls name_sni short trust host origin up down
    sbd_ui_menu '接管与漂移协调' '[1] 接管/协调配置中的策略对象' '[2] 接管单用户协议节点' '[3] 协调已登记节点（采用当前 inbound）' '[0] 返回'
    sbd_read_integer '请选择' 0 3 || return $?; choice="$SBD_REPLY"
    [[ "$choice" != 0 ]] || return 2
    [[ -f "$SBD_CONFIG" ]] || { _error '没有当前配置可接管'; return 1; }
    if [[ "$choice" = 1 ]]; then
        sbd_policy_pick '["route_rules","dns_rules","dns_servers","rule_sets","endpoints","connectors"]' '区域' || return $?; area="$SBD_REPLY"
        if [[ "$area" = *_rules ]]; then
            if [[ "$area" = route_rules ]]; then jq '.route.rules // []' "$SBD_CONFIG"; count=$(jq '.route.rules // []|length' "$SBD_CONFIG")
            else jq '.dns.rules // []' "$SBD_CONFIG"; count=$(jq '.dns.rules // []|length' "$SBD_CONFIG"); fi || return 1
            sbd_entry_number_prompt '当前配置中的规则位置（1 起）' 1 "$count" || return $?; position=$((SBD_REPLY-1))
            jq --arg area "$area" '.policy[$area] // [] | map({id,position:(.index+1)})' "$SBD_REGISTRY" || return 1
            sbd_read_optional '协调时填已有管理 ID；新接管留空' || return $?; id="$SBD_REPLY"
        else
            sbd_read_required '当前配置中已有的原生 tag（不生成/改名）' || return $?; id="$SBD_REPLY"; position=-1
        fi
        sbd_info '只采用选定的当前配置，不用登记反向覆盖；其他已登记对象仍须通过对齐'
        sbd_policy_confirm || return $?
        sbd_apply sbd_policy_adopt "$area" "$id" "$position" || return 1
    else
        id=''; defaults='{}'
        if [[ "$choice" = 3 ]]; then
            sbd_entry_choose "$(jq -c .nodes "$SBD_REGISTRY")" '选择已登记节点' || return $?; id="$SBD_REPLY"
            defaults=$(jq -c --arg id "$id" '.nodes[]|select(.id==$id)' "$SBD_REGISTRY") || return 1
            tag=$(jq -r .inbound_tag <<< "$defaults") || return 1
        else sbd_read_required '当前 inbound tag' || return $?; tag="$SBD_REPLY"; fi
        node=$(jq -ce --arg tag "$tag" '[.inbounds[]?|select(.tag==$tag)]|select(length==1)|.[0]' "$SBD_CONFIG") || { _error '实际 inbound 缺失或重复'; return 1; }
        sbd_entry_default '显示名' "$(jq -r --arg tag "$tag" '.name // $tag' <<< "$defaults")" || return $?; name="$SBD_REPLY"
        sbd_entry_host_prompt '客户端公网/优选地址' "$(jq -r '.client.server // empty' <<< "$defaults")" || return $?; server="$SBD_REPLY"
        sbd_entry_number_prompt '客户端对外端口' 1 65535 "$(jq -r '.client.server_port // empty' <<< "$defaults")" || return $?; port="$SBD_REPLY"
        facts=$(jq -n --arg name "$name" --arg server "$server" --argjson port "$port" '{name:$name,server:$server,server_port:$port}') || return 1
        profile=$(jq -r .type <<< "$node") || return 1
        if [[ "$(jq -r '.transport.type // empty' <<< "$node")" = ws ]]; then
            while true; do sbd_entry_host_prompt 'CDN Host/SNI' || return $?; host="$SBD_REPLY"; [[ "$(sbd_tls_identity "$host")" = DNS:* ]] && break; _error '须填域名'; done
            sbd_entry_number_prompt '提供商回源映射端口（仅登记）' 1 65535 || return $?; origin="$SBD_REPLY"
            facts=$(jq --arg host "$host" --argjson origin "$origin" '.cdn={host:$host,origin_port:$origin}' <<< "$facts") || return 1
        elif [[ "$(jq -r '.tls.reality.enabled // false' <<< "$node")" = true ]]; then
            jq '.tls.reality.short_id' <<< "$node" || return 1
            sbd_read_required '采用的 short_id' || return $?; short="$SBD_REPLY"
            facts=$(jq --arg short "$short" '.short_id=$short' <<< "$facts") || return 1
        elif [[ "$profile" != shadowsocks ]]; then
            sbd_entry_host_prompt '客户端 SNI' "$(jq -r '.tls.server_name // empty' <<< "$node")" || return $?; name_sni="$SBD_REPLY"
            sbd_policy_pick '["system","pin","certificate"]' '文件证书信任方式（provider 使用系统 CA）' || return $?; trust="$SBD_REPLY"
            facts=$(jq --arg name "$name_sni" --arg trust "$trust" '.server_name=$name|.trust=$trust' <<< "$facts") || return 1
            if [[ "$profile" = hysteria2 ]]; then
                sbd_ui_options '[1] 客户端 BBR（默认）' '[2] 客户端 Hysteria CC'
                sbd_entry_number_prompt '只补填客户端拥塞策略，不改变服务端' 1 2 1 || return $?
                tls='{}'
                if [[ "$SBD_REPLY" = 2 ]]; then
                    sbd_entry_number_prompt '客户端上传 Mbps' 1 999999999 || return $?; up="$SBD_REPLY"
                    sbd_entry_number_prompt '客户端下载 Mbps' 1 999999999 || return $?; down="$SBD_REPLY"
                    tls=$(jq -n --argjson up "$up" --argjson down "$down" '{up_mbps:$up,down_mbps:$down}') || return 1
                fi
                facts=$(jq --argjson options "$tls" '.client_options=$options' <<< "$facts") || return 1
                sbd_info '这里只采用向导的客户端带宽选项；服务端带宽/混淆采用当前 config，不修改服务端'
            fi
        fi
        sbd_policy_confirm || return $?
        sbd_apply sbd_entry_adopt "$tag" "$facts" "$id" || return 1
    fi
    sbd_success '已显式采用当前配置并提交管理事实/所需导出；未验证网络连通'
    sbd_ui_pause
}

sbd_maintenance_menu() {
    local choice category kind page
    while true; do
        sbd_ui_menu '维护与显式协调' '[1] 检查配置' '[2] 接管/漂移协调' '[3] 按托管类别 reset' '[4] 恢复最近事务' '[5] 更新管理器' '[6] 卸载' '[0] 返回'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 6 || return 0; choice="$SBD_REPLY"
        case "$choice" in
            0) return 0 ;;
            1) sbd_check_config || return 1; sbd_success 'Schema/check 通过，不代表联网验证' ;;
            2) sbd_adopt_menu; case "$?" in 0|2) ;; *) return 1 ;; esac ;;
            3)
                sbd_policy_pick '["nodes","rules_dns","peers","tls"]' '选择 reset 类别' || return $?; category="$SBD_REPLY"
                sbd_info '只删除所选类别的托管配置/登记；存活引用导致整次失败，不自动连带删，不清认证数据'
                case "$category" in
                    nodes) jq '.nodes|map({id,name,inbound_tag})' "$SBD_REGISTRY" ;;
                    rules_dns) jq '.policy // {}|{route_rules,dns_rules,dns_servers,rule_sets}|map_values(. // [] | map({id,index}))' "$SBD_REGISTRY" ;;
                    peers) jq '.policy // {}|{endpoints,connectors}|map_values(. // []|map({id}))' "$SBD_REGISTRY" ;;
                    tls) sbd_tls_list ;;
                esac || return 1
                sbd_policy_confirm || return $?
                sbd_apply sbd_reset "$category" || return 1
                sbd_success '所选托管类别 reset 已提交，未清除外部/原生认证数据' ;;
            4)
                kind=$(jq -er .kind "$SBD_WORK/previous/journal.json") || { _error '没有可识别的最近恢复源'; return 1; }
                sbd_info "将恢复最近 $kind 事务对应的完整资源组及快照记录的运行态；外部动作不会撤销"
                sbd_policy_confirm || return $?
                sbd_history_restore || return 1
                sbd_success '最近资源组恢复已提交；管理器可能已更换，请重新运行 sd'
                SBD_EXIT_MENU=true
                return 0 ;;
            5)
                sbd_info '下载当前 main 的发布清单并成组更新管理器；不自动更新核心'
                sbd_policy_confirm || return $?
                bash "$SBD_APP/install.sh" --update --no-menu || return 1
                sbd_success '管理器已更新，请重新运行 sd'; SBD_EXIT_MENU=true; return 0 ;;
            6) sbd_uninstall_menu; return $? ;;
        esac
        sbd_ui_pause "$page"
    done
}

sbd_status() {
    local version state runtime enabled count phase kind output backend rc=0
    local report line core='' service='' startup='' nodes='' config='' manager='' transaction=''
    if [[ "${1:-}" = brief ]]; then
        report=$(sbd_status) || rc=$?
        while IFS= read -r line; do
            case "$line" in
                '核心: '*) core="$line" ;;
                '磁盘核心版本: '*) core="核心: ${line#磁盘核心版本: }"; core="${core%%（*}" ;;
                '服务: '*) service="${line%%（*}" ;;
                '开机自启: '*) startup="${line%%（*}" ;;
                '托管节点: '*) nodes="$line" ;;
                '配置: '*) config="$line" ;;
                '管理器记录版本: '*) manager="管理器: ${line#管理器记录版本: }" ;;
                '事务: '*) transaction="$line" ;;
            esac
        done <<< "$report"
        sbd_ui_rows "$core" "$service" "$startup" "$nodes" "$config" "$manager"
        if [[ "$transaction" != '事务: 无待处理现场' ]]; then
            printf '  '; sbd_ui_tint '1;31' "$transaction"; printf '\n'
        fi
        [[ "$rc" = 0 ]]
        return $?
    fi
    if [[ -x "$SBD_BINARY" ]]; then
        if version=$(sbd_version); then printf '磁盘核心版本: %s（不等同于运行版本）\n' "$version"
        else printf '磁盘核心版本: 未知（读取失败）\n'; rc=1; fi
    else
        printf '核心: 未安装\n'
    fi
    if runtime=$(sbd_service_state); then
        case "$runtime" in running) printf '服务: 运行中（不代表网络连通）\n' ;; stopped) printf '服务: 已停止\n' ;; *) _error '服务状态返回值无效'; printf '服务: 未知\n'; rc=1 ;; esac
    else printf '服务: 未知（读取失败）\n'; rc=1; fi
    if enabled=$(sbd_service_enabled); then
        case "$enabled" in enabled) printf '开机自启: 已开启\n' ;; disabled) printf '开机自启: 已关闭\n' ;; *) _error '自启状态返回值无效'; printf '开机自启: 未知\n'; rc=1 ;; esac
    else printf '开机自启: 未知（读取失败）\n'; rc=1; fi
    if [[ -f "$SBD_CONFIG" ]]; then printf '配置: 已存在\n'; else printf '配置: 未创建\n'; fi
    if state=$(sbd_record_read "$SBD_STATE") && version=$(jq -er '.manager_version | select(type=="string" and length>0)' <<< "$state"); then
        printf '管理器记录版本: %s\n' "$version"
    else _error '无法取得管理器版本事实'; printf '管理器记录版本: 未知\n'; rc=1; fi
    if count=$(jq -er '.nodes|select(type=="array")|length' "$SBD_REGISTRY"); then printf '托管节点: %s 个\n' "$count"
    else _error '读取托管节点数量失败'; printf '托管节点: 未知\n'; rc=1; fi
    if [[ -e "$SBD_WORK/active" || -L "$SBD_WORK/active" ]]; then
        if phase=$(jq -er '.phase|select(.=="pending" or .=="accepted")' "$SBD_WORK/active/journal.json") && kind=$(jq -er '.kind|select(.=="config" or .=="engine" or .=="install")' "$SBD_WORK/active/journal.json"); then
            if [[ "$phase" = accepted ]]; then printf '事务: %s 已接受，待完成收尾\n' "$kind"; else printf '事务: %s 未完成，待恢复\n' "$kind"; fi
            printf '事务现场: %s\n' "$SBD_WORK/active"
        else _error '事务现场缺少可识别记录，请检查，不自动猜测'; printf '事务: 未知现场 %s\n' "$SBD_WORK/active"; rc=1; fi
    else printf '事务: 无待处理现场\n'; fi
    printf '配置路径: %s\n导出目录: %s\n' "$SBD_CONFIG" "$SBD_EXPORTS"
    output=''
    if [[ -f "$SBD_CONFIG" ]]; then
        if ! output=$(jq -r '.log.output // empty' "$SBD_CONFIG"); then _error '无法读取日志路径配置'; rc=1; fi
        if jq -e '.log.disabled==true' "$SBD_CONFIG" >/dev/null 2>&1; then printf '日志配置: 已禁用，以下位置仅可能有历史日志\n'; fi
    fi
    if [[ -n "$output" ]]; then
        [[ "$output" = /* ]] || output="$SBD_ROOT/$output"
        printf '日志文件: %s（log.output）\n' "$output"
    elif backend=$(sbd_backend); then
        case "$backend" in
            systemd) printf '日志命令: journalctl -u %s\n' "$SBD_SERVICE" ;;
            openrc) printf '日志文件: %s（服务输出）\n' "$SBD_LOG" ;;
            *) _error '日志服务后端无效'; printf '日志位置: 未知\n'; rc=1 ;;
        esac
    else printf '日志位置: 未知（服务后端读取失败）\n'; rc=1; fi
    [[ "$rc" = 0 ]]
}

sbd_dispatch() {
    case "$1" in
        1) sbd_engine_menu ;;
        2) sbd_entries_menu ;;
        3) sbd_export_menu ;;
        4) sbd_rules_menu ;;
        5) sbd_resolver_menu ;;
        6) sbd_peers_menu ;;
        7) sbd_tls_menu ;;
        8) sbd_observe_menu ;;
        9) sbd_check_config && sbd_success 'Schema 与核心检查通过；未验证网络连通' ;;
        10) sbd_status ;;
        11) sbd_maintenance_menu ;;
        *) _error '无效菜单编号'; return 1 ;;
    esac
}

sbd_console() {
    local choice page rc
    while true; do
        sbd_ui_begin 'singbox-deploy · sd'
        sbd_status brief || _error '状态摘要读取不完整；仍可选择检查或维护，不将未知状态当作停止'
        sbd_ui_options '@节点与网络' '[2] 节点管理' '[3] 分享与客户端资料' '[4] 规则集与路由' '[5] 独立 DNS' '[6] Endpoints 与 Cloudflared' \
            '@服务与维护' '[1] 核心管理' '[7] TLS 与证书' '[8] 观测、日志与缓存' '[9] 检查现有配置' '[10] 部署状态' '[11] 维护与显式协调' '[0] 退出'
        page="$SBD_UI_PAGE"
        sbd_read_integer '请选择' 0 11 || return 0
        choice="$SBD_REPLY"
        [[ "$choice" != 0 ]] || return 0
        if sbd_dispatch "$choice"; then
            sbd_ui_pause "$page"
        else
            rc=$?
            [[ "$rc" = 2 ]] || sbd_ui_pause
        fi
        [[ "${SBD_EXIT_MENU:-false}" != true ]] || return 0
    done
}
