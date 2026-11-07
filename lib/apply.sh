#!/usr/bin/env bash

sbd_resource_path() {
    case "$1" in
        config) printf '%s\n' "$SBD_CONFIG" ;;
        schema) printf '%s\n' "$SBD_SCHEMA" ;;
        state) printf '%s\n' "$SBD_STATE" ;;
        registry) printf '%s\n' "$SBD_REGISTRY" ;;
        exports) printf '%s\n' "$SBD_EXPORTS" ;;
        app) printf '%s\n' "$SBD_APP" ;;
        command) printf '%s\n' "$SBD_COMMAND" ;;
        engine) printf '%s\n' "$SBD_BIN_DIR" ;;
        service) sbd_service_file "$(sbd_backend)" ;;
        logrotate) sbd_logrotate_file ;;
        *) _error '未知事务资源'; return 1 ;;
    esac
}

sbd_resources() {
    case "$1" in
        config) printf '%s\n' schema config registry exports state ;;
        install) printf '%s\n' app registry state command ;;
        engine)
            printf '%s\n' engine schema config service
            local backend
            backend=$(sbd_backend) || return 1
            [[ "$backend" != openrc ]] || printf 'logrotate\n'
            printf 'state\n'
            ;;
        *) _error '未知事务类别'; return 1 ;;
    esac
}

# BusyBox 的 readlink 不支持 GNU 的 -m；材料登记时目标目录尚未创建，逐级解析已存在的祖先。
sbd_material_resolve() {
    local path="$1" dir="$1" rest='' resolved
    if resolved=$(readlink -f -- "$path" 2>/dev/null) && [[ -n "$resolved" ]]; then
        printf '%s\n' "$resolved"; return 0
    fi
    while [[ ! -e "$dir" && ! -L "$dir" ]]; do
        rest="/${dir##*/}$rest"
        dir=${dir%/*}
        [[ -n "$dir" ]] || { dir=/; break; }
    done
    resolved=$(cd -- "$dir" 2>/dev/null && pwd -P) || return 1
    if [[ "$resolved" = / ]]; then
        printf '/%s\n' "${rest#/}"
    else
        printf '%s%s\n' "$resolved" "$rest"
    fi
}

sbd_material_path() {
    local path="$1" name="${1##*/}" resolved
    if [[ "$name" =~ ^cert\.[A-Za-z0-9]{8}$ && "$path" = "$SBD_CERT_DIR/$name" ]]; then :
    elif [[ "$name" =~ ^set\.[A-Za-z0-9]{8}$ && "$path" = "$SBD_ASSET_DIR/rule-sets/$name" ]]; then :
    else _error '材料路径不属于本部署'; return 1; fi
    resolved=$(sbd_material_resolve "$path") || { _error '无法解析材料路径'; return 1; }
    [[ "$resolved" = "$path" ]] || { _error '材料路径包含外部链接'; return 1; }
}

sbd_material_journal_valid() {
    local journal="$1" paths path
    jq -e 'all([(.created_materials // []), (.retired_materials // [])][];
        type=="array" and all(.[]; type=="string"))' "$journal" >/dev/null || { _error '材料记录损坏'; return 1; }
    paths=$(jq -r '[(.created_materials // [])[],(.retired_materials // [])[]][]' "$journal") || return 1
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        sbd_material_path "$path" || return 1
    done <<< "$paths"
}

sbd_material_note() {
    local key="$1" path="$2" journal="$SBD_WORK/active/journal.json" content
    case "$key" in created_materials|retired_materials) ;; *) _error '未知材料记录类型'; return 1 ;; esac
    sbd_material_path "$path" || return 1
    content=$(jq --arg key "$key" --arg path "$path" '.[$key] = ((.[$key] // []) + [$path] | unique)' "$journal") || { _error '生成材料记录失败'; return 1; }
    sbd_record_write "$journal" "$content"
}

sbd_material_cleanup() {
    local journal="$1" key="$2" paths path file referenced
    sbd_material_journal_valid "$journal" || return 1
    paths=$(jq -r --arg key "$key" '(.[$key] // [])[]' "$journal") || return 1
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        sbd_material_path "$path" || return 1
        referenced=false
        for file in "$SBD_CONFIG" "$SBD_REGISTRY"; do
            [[ -e "$file" ]] || continue
            sbd_object "$file" || { _error '无法确认活跃材料引用，保留材料'; return 1; }
            if jq -e --arg path "$path" 'any(.. | strings; .==$path or startswith($path+"/"))' "$file" >/dev/null; then referenced=true; fi
        done
        if [[ "$referenced" = true ]]; then
            [[ "$key" = retired_materials ]] && continue
            _error '待回收候选仍被活跃事实引用，保留现场'; return 1
        fi
        rm -rf -- "$path" || { _error '材料回收失败'; return 1; }
    done <<< "$paths"
}

sbd_work_remove() {
    local path="$1" resolved
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
    [[ ! -L "$path" ]] || { _error "恢复目录不能是符号链接: $path"; return 1; }
    resolved=$(cd -- "$path" && pwd -P) || { _error "无法确认恢复目录: $path"; return 1; }
    case "$resolved" in "$SBD_WORK/active"|"$SBD_WORK/previous") ;; *) _error '拒绝清理范围外的目录'; return 1 ;; esac
    rm -rf -- "$resolved" || { _error "恢复目录清理失败: $resolved"; return 1; }
}

sbd_journal_valid() {
    local dir="$1" key had kind keys
    if ! sbd_object "$dir/journal.json" || ! jq -e '
        .format == 1 and (.phase == "pending" or .phase == "accepted")
        and (((.kind == "config" or .kind == "engine") and (.runtime == "running" or .runtime == "stopped"))
            or (.kind == "install" and .runtime == "unchanged"))
    ' "$dir/journal.json" >/dev/null 2>&1; then
        _error '事务记录损坏，已保留现场'; return 1
    fi
    kind=$(jq -r '.kind' "$dir/journal.json") || return 1
    sbd_material_journal_valid "$dir/journal.json" || return 1
    keys=$(sbd_resources "$kind") || return 1
    if [[ "$kind" = engine ]]; then
        jq -e '(.backend=="systemd" or .backend=="openrc") and (.enabled=="enabled" or .enabled=="disabled")' "$dir/journal.json" >/dev/null || { _error '核心事务后端或自启事实无效'; return 1; }
    fi
    for key in $keys; do
        jq -e --arg key "$key" '(.present[$key] | type) == "boolean"' "$dir/journal.json" >/dev/null || { _error '事务存在性记录无效'; return 1; }
        had=$(jq -r --arg key "$key" '.present[$key]' "$dir/journal.json") || return 1
        if [[ "$had" = true ]]; then
            if [[ "$key" = exports || "$key" = app || "$key" = engine ]]; then
                [[ -d "$dir/before/$key" && ! -L "$dir/before/$key" ]] || { _error "目录恢复副本缺失: $key"; return 1; }
            elif [[ "$key" = command ]]; then
                [[ -L "$dir/before/$key" ]] || { _error '命令链接恢复副本缺失'; return 1; }
            elif [[ "$key" = service || "$key" = logrotate ]]; then
                [[ -s "$dir/before/$key" && ! -L "$dir/before/$key" ]] || { _error "服务恢复副本缺失: $key"; return 1; }
            else
                sbd_object "$dir/before/$key" || { _error "恢复副本缺失或损坏: $key"; return 1; }
            fi
        fi
    done
}

sbd_snapshot() {
    local dir="$1" runtime="$2" kind="${3:-config}" key path present='{}' had keys content backend enabled
    mkdir -p -- "$dir/before" || { _error '无法创建快照目录'; return 1; }
    keys=$(sbd_resources "$kind") || return 1
    for key in $keys; do
        path=$(sbd_resource_path "$key") || return 1
        had=false
        if [[ -e "$path" || -L "$path" ]]; then
            [[ ! -L "$path" || "$key" = command ]] || { _error "受管资源不能是外部链接: $path"; return 1; }
            cp -a -- "$path" "$dir/before/$key" || { _error "快照失败: $key"; return 1; }
            if [[ "$key" = engine ]]; then
                sbd_tree_compare "$path" "$dir/before/$key" || { _error "目录快照不完整: $key"; return 1; }
            elif [[ "$key" != exports && "$key" != app && "$key" != command ]]; then
                cmp -s -- "$path" "$dir/before/$key" || { _error "快照字节不一致: $key"; return 1; }
            fi
            had=true
        fi
        present=$(jq --arg key "$key" --argjson had "$had" '. + {($key): $had}' <<< "$present") || return 1
    done
    content=$(jq -n --arg runtime "$runtime" --arg kind "$kind" --argjson present "$present" '{format:1,kind:$kind,phase:"pending",runtime:$runtime,present:$present}') || { _error '生成事务记录失败'; return 1; }
    if [[ "$kind" = engine ]]; then
        if ! backend=$(sbd_backend) || ! enabled=$(sbd_service_enabled); then _error '无法记录旧服务事实'; return 1; fi
        content=$(jq --arg backend "$backend" --arg enabled "$enabled" '. + {backend:$backend,enabled:$enabled}' <<< "$content") || return 1
    fi
    sbd_record_write "$dir/journal.json" "$content" || return 1
    sbd_journal_valid "$dir"
}

sbd_directory_replace() {
    local source="$1" key="$2" target dir
    case "$key" in app|exports|engine) ;; *) _error '未知目录资源'; return 1 ;; esac
    target=$(sbd_resource_path "$key") || return 1
    dir="$SBD_WORK/active/$key-next"
    [[ -d "$source" && ! -L "$source" && ! -L "$target" ]] || { _error '发布目录无效'; return 1; }
    [[ ! -e "$dir" ]] || { _error '目录暂存位置被占用'; return 1; }
    cp -a -- "$source" "$dir" || { _error '目录暂存失败'; return 1; }
    if [[ "$key" = engine ]]; then
        sbd_tree_compare "$source" "$dir" || { _error "目录复制不完整: $key"; return 1; }
    fi
    rm -rf -- "$target" || { _error "旧目录替换失败: $key"; return 1; }
    mv -- "$dir" "$target" || { _error "目录发布失败: $key"; return 1; }
}

sbd_exports_replace() { sbd_directory_replace "$1" exports; }

sbd_restore_snapshot() {
    local dir="$1" key path had runtime kind keys tmp backend enabled mode
    sbd_journal_valid "$dir" || return 1
    kind=$(jq -r '.kind' "$dir/journal.json") || return 1
    keys=$(sbd_resources "$kind") || return 1
    if [[ "$kind" = engine ]]; then
        backend=$(jq -r '.backend' "$dir/journal.json") || return 1
        [[ "$backend" = "$(sbd_backend)" ]] || { _error '服务后端变化，不能自动恢复'; return 1; }
        sbd_engine_stopped || { _error '未确认核心退出，保留旧包，不执行替换'; return 1; }
        enabled=$(jq -r '.enabled' "$dir/journal.json") || return 1
        sbd_service_set_enabled disabled || return 1
    fi
    for key in $keys; do
        path=$(sbd_resource_path "$key") || return 1
        had=$(jq -r --arg key "$key" '.present[$key]' "$dir/journal.json") || return 1
        if [[ "$had" = true ]]; then
            if [[ "$key" = exports || "$key" = app || "$key" = engine ]]; then
                # 上次发布失败留下的候选可删除，恢复副本本身始终保留。
                if [[ -e "$SBD_WORK/active/$key-next" ]]; then
                    rm -rf -- "$SBD_WORK/active/$key-next" || { _error '无法清理失败目录候选'; return 1; }
                fi
                sbd_directory_replace "$dir/before/$key" "$key" || return 1
            elif [[ "$key" = command ]]; then
                tmp="${path}.restore.$$"
                if ! cp -a -- "$dir/before/$key" "$tmp" || ! mv -f -- "$tmp" "$path"; then
                    _error '命令链接恢复失败'; return 1
                fi
            elif [[ "$key" = service || "$key" = logrotate ]]; then
                mode=644
                [[ "$key" != service || "$backend" != openrc ]] || mode=755
                sbd_atomic_file "$dir/before/$key" "$path" "$mode" || return 1
            else
                sbd_atomic_file "$dir/before/$key" "$path" || return 1
            fi
        else
            case "$key" in
                app|exports|engine) rm -rf -- "$path" || { _error "移除本次新增目录失败: $key"; return 1; } ;;
                *) rm -f -- "$path" || { _error "移除本次新增资源失败: $key"; return 1; } ;;
            esac
        fi
    done
    runtime=$(jq -r '.runtime' "$dir/journal.json") || return 1
    if [[ "$kind" = engine ]]; then
        sbd_service_reload || return 1
        sbd_service_set_enabled "$enabled" || return 1
        sbd_service_restore "$runtime" || { _error '旧核心包已恢复，但运行态恢复失败'; return 1; }
    elif [[ "$kind" = config ]]; then
        sbd_service_restore "$runtime" || { _error '旧文件已恢复，但运行态恢复失败'; return 1; }
    fi
}

sbd_finish_accepted() {
    local active="$SBD_WORK/active" previous="$SBD_WORK/previous"
    # 手动恢复使用的目标副本不归档为递归嵌套历史；已接受后仅重试收尾。
    if [[ -e "$active/target" ]]; then
        rm -rf -- "$active/target" || { _error '恢复已接受，但目标临时副本清理失败'; return 1; }
    fi
    if [[ -e "$previous" ]]; then
        sbd_journal_valid "$previous" || return 1
        sbd_material_cleanup "$previous/journal.json" retired_materials || return 1
        sbd_work_remove "$previous" || return 1
    fi
    mv -- "$active" "$previous" || { _error '新事实已接受，但快照归档失败；下次启动仅重试收尾'; return 1; }
}

sbd_recover_locked() {
    local dir="$SBD_WORK/active" phase
    [[ -e "$dir" || -L "$dir" ]] || return 0
    [[ -d "$dir" && ! -L "$dir" ]] || { _error '事务目录类型无效'; return 1; }
    if [[ ! -e "$dir/journal.json" ]]; then
        sbd_work_remove "$dir"
        return $?
    fi
    sbd_journal_valid "$dir" || return 1
    phase=$(jq -r '.phase' "$dir/journal.json") || return 1
    if [[ "$phase" = accepted ]]; then
        sbd_finish_accepted
    else
        sbd_restore_snapshot "$dir" || return 1
        sbd_material_cleanup "$dir/journal.json" created_materials || return 1
        sbd_work_remove "$dir"
    fi
}

sbd_recover() { sbd_write_lock sbd_recover_locked; }

sbd_apply_abort() {
    if [[ -f "$SBD_WORK/active/journal.json" ]] && jq -e '.phase=="accepted"' "$SBD_WORK/active/journal.json" >/dev/null 2>&1; then
        _error '新事实已接受，但收尾失败；正在重试收尾，不回退完成版本'
    else
        _error '变更失败，正在恢复旧文件与原运行态'
    fi
    sbd_recover_locked || { _error "恢复未完成，已保留: $SBD_WORK/active"; return 1; }
    return 1
}

sbd_apply_signal() {
    trap - INT TERM HUP
    _error '操作被中断'
    sbd_recover_locked || _error "恢复未完成，已保留: $SBD_WORK/active"
    exit 1
}

sbd_apply_locked() {
    local callback="$1"; shift
    local dir="$SBD_WORK/active" stage="$SBD_WORK/active/after" runtime key revision version core content
    local config_changed=true compared=0
    sbd_directories || return 1
    sbd_recover_locked || return 1
    runtime=$(sbd_service_state) || return 1
    mkdir -p -- "$stage" || { _error '无法创建暂存目录'; return 1; }
    trap sbd_apply_signal INT TERM HUP
    sbd_config_stage_current "$stage/config.json" || { _error '暂存配置失败'; sbd_work_remove "$dir"; return 1; }
    if [[ -e "$SBD_STATE" ]]; then
        cp -- "$SBD_STATE" "$stage/state.json" || { _error '暂存 state 失败'; sbd_work_remove "$dir"; return 1; }
    else
        printf '{"format":1,"revision":0}\n' > "$stage/state.json" || { _error '暂存 state 失败'; sbd_work_remove "$dir"; return 1; }
    fi
    if [[ -e "$SBD_REGISTRY" ]]; then
        cp -- "$SBD_REGISTRY" "$stage/registry.json" || { _error '暂存 registry 失败'; sbd_work_remove "$dir"; return 1; }
    else
        printf '{"format":1,"nodes":[]}\n' > "$stage/registry.json" || { _error '暂存 registry 失败'; sbd_work_remove "$dir"; return 1; }
    fi
    cp -a -- "$SBD_EXPORTS" "$stage/exports" || { _error '暂存导出失败'; sbd_work_remove "$dir"; return 1; }
    sbd_records_check "$stage" || { sbd_work_remove "$dir"; return 1; }
    revision=$(jq -r '.revision' "$stage/state.json") || { _error '读取旧修订号失败'; sbd_work_remove "$dir"; return 1; }
    revision=$(sbd_integer "$revision" 0 999999998) || { _error '旧修订号无效'; sbd_work_remove "$dir"; return 1; }
    # 提前登记恢复源，使候选使用的独立材料也能在中断后回收；活跃配置尚未改变。
    sbd_snapshot "$dir" "$runtime" || { _error '快照失败，未替换活跃事实；保留现场'; return 1; }
    if ! ( "$callback" "$stage" "$@" ) || ! sbd_records_check "$stage" || ! sbd_prepare_config "$stage"; then
        _error '候选生成或校验失败，活跃事实未变更'
        sbd_material_cleanup "$dir/journal.json" created_materials || return 1
        sbd_work_remove "$dir"
        return 1
    fi
    if [[ -f "$dir/before/config" ]]; then
        cmp -s -- "$stage/config.json" "$dir/before/config" || compared=$?
        case "$compared" in
            0) config_changed=false ;;
            1) ;;
            *)
                _error '无法比较新旧配置，取消提交'
                sbd_material_cleanup "$dir/journal.json" created_materials || return 1
                sbd_work_remove "$dir"
                return 1
                ;;
        esac
    fi
    for key in schema config registry; do
        sbd_atomic_file "$stage/$key.json" "$(sbd_resource_path "$key")" || { sbd_apply_abort; return 1; }
    done
    sbd_exports_replace "$stage/exports" || { sbd_apply_abort; return 1; }
    if [[ "$runtime" = running && "$config_changed" = true ]]; then
        sbd_service_restore running || { sbd_apply_abort; return 1; }
    fi
    if ! version=$(cat "$SBD_APP/VERSION") || ! core=$(cat "$stage/core-version"); then
        _error '读取提交版本失败'; sbd_apply_abort; return 1
    fi
    content=$(jq --arg version "$version" --arg core "$core" --argjson revision "$((revision + 1))" \
        '. + {manager_version:$version,core_version:$core,revision:$revision}' "$stage/state.json") || { _error '生成提交 state 失败'; sbd_apply_abort; return 1; }
    if ! sbd_record_write "$stage/state.json" "$content" || ! sbd_atomic_file "$stage/state.json" "$SBD_STATE"; then
        sbd_apply_abort; return 1
    fi
    content=$(jq '.phase="accepted"' "$dir/journal.json") || { _error '生成完成记录失败'; sbd_apply_abort; return 1; }
    sbd_record_write "$dir/journal.json" "$content" || { sbd_apply_abort; return 1; }
    sbd_finish_accepted || return 1
    trap - INT TERM HUP
}

sbd_apply() { sbd_write_lock sbd_apply_locked "$@"; }

sbd_legacy_config_parts() {
    local name
    local -a names=(
        00_empty.json 01_log.json 02_dns.json 03_ntp.json 04_certificate.json
        05_certificate_providers.json 06_http_clients.json 07_network_namespaces.json
        08_endpoints.json 09_inbounds.json 10_outbounds.json 11_route.json
        12_services.json 13_experimental.json 99_extra.json
        00_base.json 10_dns.json 20_endpoints.json 30_inbounds.json
        40_outbounds.json 50_route.json 60_services.json 70_experimental.json
        90_extra.json
    )
    for name in "${names[@]}"; do
        [[ ! -f "$SBD_CONF_DIR/$name" ]] || printf '%s\n' "$name"
    done
}

sbd_legacy_layout_present() {
    [[ ! -f "$SBD_LEGACY_CONFIG" && ! -f "$SBD_LEGACY_SCHEMA" ]] || return 0
    [[ -z "$(sbd_legacy_config_parts)" ]] || return 0
    [[ ! -f "$SBD_LEGACY_CONF_DIR/config.json" && ! -f "$SBD_LEGACY_DATA_DIR/registry.json" &&
        ! -f "$SBD_LEGACY_DATA_DIR/state.json" ]] || return 0
    return 1
}

sbd_layout_stage_remove() {
    local path="$1"
    case "$path" in "$SBD_WORK"/migration.*) rm -rf -- "$path" ;; *) return 1 ;; esac
}

sbd_legacy_archive() {
    local backup="$1" name failed=false
    mkdir -p -- "$backup/legacy" || { _error "旧布局备份目录创建失败: $backup"; return 1; }
    if [[ -f "$SBD_LEGACY_CONFIG" ]] && ! mv -- "$SBD_LEGACY_CONFIG" "$backup/legacy/config.json"; then
        failed=true
    fi
    if [[ -f "$SBD_LEGACY_SCHEMA" ]] && ! mv -- "$SBD_LEGACY_SCHEMA" "$backup/legacy/schema.json"; then
        failed=true
    fi
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        [[ -f "$SBD_CONF_DIR/$name" ]] || continue
        mv -- "$SBD_CONF_DIR/$name" "$backup/legacy/$name" || failed=true
    done < <(sbd_legacy_config_parts)
    for name in "$SBD_LEGACY_CONF_DIR" "$SBD_LEGACY_DATA_DIR"; do
        [[ ! -d "$name" ]] || mv -- "$name" "$backup/legacy/$(basename -- "$name")" || failed=true
    done
    [[ "$failed" = false ]] || { _error "旧布局未完全归档，原文件仍在部署根或 confs: $backup"; return 1; }
}

sbd_migrate_legacy_layout_locked() {
    local migrate_config=false rewrite_service=false cleanup_legacy=false
    local backend='' service='' runtime='' mode stage backup backup_service=false migrated=false
    sbd_directories || return 1
    if [[ -e "$SBD_CONFIG" ]]; then
        if sbd_legacy_layout_present; then cleanup_legacy=true; fi
    elif [[ -f "$SBD_LEGACY_CONFIG" || -f "$SBD_LEGACY_CONF_DIR/config.json" ]]; then
        migrate_config=true
    elif sbd_legacy_layout_present; then
        _error '检测到旧布局残留，但找不到可迁移的配置源（confs/config.json、部署根 config.json 或 config/config.json）；已保留原文件，请恢复配置后重新启动'
        return 0
    fi
    if ! backend=$(sbd_backend 2>/dev/null); then
        if [[ "$migrate_config" = true || "$cleanup_legacy" = true ]]; then
            _error '检测到旧配置布局，但未检测到支持的 systemd/OpenRC 服务后端'
            return 1
        fi
        return 0
    fi
    service=$(sbd_service_file "$backend") || return 1
    if [[ -e "$service" || -L "$service" ]]; then
        sbd_service_claim "$backend" || return 1
        if grep -Fq -- "$SBD_LEGACY_CONFIG" "$service" || grep -Fq -- "$SBD_LEGACY_CONF_DIR/" "$service"; then rewrite_service=true; fi
    fi
    [[ "$migrate_config" = true || "$rewrite_service" = true || "$cleanup_legacy" = true ]] || return 0
    if [[ ! -x "$SBD_BINARY" ]]; then
        _error '检测到旧配置布局，但当前核心不可用；请先安装核心，候选校验通过后再迁移'
        return 0
    fi
    stage=$(mktemp -d "$SBD_WORK/migration.XXXXXX") || { _error '无法创建配置迁移暂存目录'; return 1; }
    if [[ "$migrate_config" = true ]]; then
        if ! sbd_config_stage_current "$stage/config.json" || ! sbd_prepare_config "$stage"; then
            sbd_layout_stage_remove "$stage"
            _error '旧配置未能通过 Schema/format/check，未迁移'
            return 1
        fi
    fi
    if [[ "$rewrite_service" = true ]]; then
        if ! runtime=$(sbd_service_state); then
            sbd_layout_stage_remove "$stage"
            return 1
        fi
        if ! sbd_service_render "$backend" "$stage/service"; then
            sbd_layout_stage_remove "$stage"
            return 1
        fi
    fi
    backup=$(mktemp -d "$SBD_WORK/legacy-layout.XXXXXX") || { sbd_layout_stage_remove "$stage"; return 1; }
    if [[ "$migrate_config" = true ]]; then
        # config.json is the marker for the new layout; publish it only after its Schema.
        if ! sbd_atomic_file "$stage/schema.json" "$SBD_SCHEMA" ||
            ! sbd_atomic_file "$stage/config.json" "$SBD_CONFIG"; then
            sbd_layout_stage_remove "$stage"
            return 1
        fi
        migrated=true
    fi
    if [[ "$migrate_config" = true ]]; then
        for name in state.json registry.json; do
            if [[ -f "$SBD_LEGACY_DATA_DIR/$name" && ! -e "$SBD_STATE_DIR/$name" ]]; then
                cp -- "$SBD_LEGACY_DATA_DIR/$name" "$SBD_STATE_DIR/$name" || { sbd_layout_stage_remove "$stage"; return 1; }
            fi
        done
    fi
    if [[ "$rewrite_service" = true ]]; then
        mode=644; [[ "$backend" != openrc ]] || mode=755
        if ! cp -- "$service" "$backup/service" || ! sbd_atomic_file "$stage/service" "$service" "$mode"; then
            sbd_layout_stage_remove "$stage"
            return 1
        fi
        backup_service=true
        if ! sbd_service_reload || { [[ "$runtime" = running ]] && ! sbd_service_restore running; }; then
            _error '服务定义切换失败，正在恢复旧布局服务定义'
            sbd_atomic_file "$backup/service" "$service" "$mode" || _error '旧服务定义恢复失败'
            sbd_service_reload || _error '旧服务后端重新加载失败'
            sbd_service_restore "$runtime" || _error '旧服务运行态恢复失败'
            sbd_layout_stage_remove "$stage"
            return 1
        fi
        migrated=true
    fi
    if [[ "$migrate_config" = true || "$rewrite_service" = true || "$cleanup_legacy" = true ]]; then
        sbd_legacy_archive "$backup" || _error "旧布局备份未完成，新配置继续生效: $backup"
    fi
    sbd_layout_stage_remove "$stage" || _error "迁移暂存清理失败: $stage"
    if [[ "$migrated" = true || "$cleanup_legacy" = true ]]; then
        [[ "$migrated" = false ]] || sbd_info "配置已收敛到单文件: $SBD_CONFIG"
        [[ "$backup_service" = false ]] || sbd_info '服务定义已切换到新路径，并按原运行态重新加载'
        sbd_info "旧布局原文件已备份到: $backup"
    fi
}

sbd_migrate_legacy_layout() { sbd_write_lock sbd_migrate_legacy_layout_locked; }

sbd_history_restore_locked() {
    local previous="$SBD_WORK/previous" active="$SBD_WORK/active" destination="$SBD_WORK/active/target" kind runtime content revision binary
    sbd_recover_locked || return 1
    [[ -d "$previous" ]] || { _error '没有最近恢复源'; return 1; }
    sbd_journal_valid "$previous" || return 1
    kind=$(jq -r .kind "$previous/journal.json") || return 1
    runtime=unchanged; [[ "$kind" = install ]] || runtime=$(sbd_service_state) || return 1
    mkdir -p "$active" || { _error '创建恢复候选失败'; return 1; }
    cp -a "$previous" "$destination" || { _error '保存完整恢复目标失败'; sbd_work_remove "$active"; return 1; }
    # 目标仍是完整快照；恢复失败时 active/before 是本次操作前的现场。
    if [[ -f "$destination/before/config" ]]; then
        mkdir "$active/check" || return 1
        cp "$destination/before/config" "$active/check/config.json" || return 1
        binary="$SBD_BINARY"
        if [[ "$kind" = engine && -x "$destination/before/engine/sing-box" ]]; then binary="$destination/before/engine/sing-box"; fi
        SBD_BINARY="$binary" sbd_prepare_config "$active/check" || { sbd_work_remove "$active"; return 1; }
    fi
    if [[ "$kind" = install && -d "$destination/before/app" ]]; then
        ( . "$SBD_APP/install.sh"; sbd_install_validate "$destination/before/app" ) || { sbd_work_remove "$active"; return 1; }
    fi
    revision=$(sbd_integer "$(jq -r .revision "$SBD_STATE")" 0 999999998) || { _error '当前修订号无效'; return 1; }
    sbd_snapshot "$active" "$runtime" "$kind" || return 1
    trap sbd_apply_signal INT TERM HUP
    if ! sbd_restore_snapshot "$destination"; then sbd_apply_abort; return 1; fi
    if [[ -f "$SBD_STATE" ]]; then
        content=$(jq --argjson revision "$((revision+1))" '.revision=$revision' "$SBD_STATE") || { sbd_apply_abort; return 1; }
        sbd_record_write "$SBD_STATE" "$content" || { sbd_apply_abort; return 1; }
    fi
    # 被撤销操作新建的材料，作为本次退休材料随最近恢复源保留。
    content=$(jq --slurpfile target "$destination/journal.json" '.phase="accepted" | .retired_materials=($target[0].created_materials // [])' "$active/journal.json") || { sbd_apply_abort; return 1; }
    sbd_record_write "$active/journal.json" "$content" || { sbd_apply_abort; return 1; }
    sbd_finish_accepted || return 1
    trap - INT TERM HUP
}

sbd_history_restore() { sbd_write_lock sbd_history_restore_locked; }
