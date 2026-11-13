#!/usr/bin/env bash
# 第一代布局回退读取、托管材料目录、迁移备份与当前布局优先；纯 Python，不执行真实核心。
# shellcheck disable=SC2016,SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

purge_plan_gen1() {
    t_fresh
    rm -f "$SBD_STATE" "$SBD_REGISTRY" || exit 1
    local plan
    mkdir -p "$SBD_LEGACY_CONF_DIR" "$SBD_LEGACY_DATA_DIR" \
        "$SBD_CERT_DIR/example.com" "$SBD_ASSET_DIR/rule-sets/geosite" "$SBD_CERT_DIR/acme/le" || exit 1
    printf 'cert\n' > "$SBD_CERT_DIR/example.com/fullchain.pem" || exit 1
    printf 'rules\n' > "$SBD_ASSET_DIR/rule-sets/geosite/geosite.srs" || exit 1
    printf 'acme\n' > "$SBD_CERT_DIR/acme/le/account.json" || exit 1
    jq -n --arg dir "$SBD_CERT_DIR/acme/le" '{certificate_providers:[{tag:"le",data_directory:$dir}]}' > "$SBD_LEGACY_CONF_DIR/config.json" || exit 1
    jq -n --arg cert "$SBD_CERT_DIR/example.com" --arg ruleset "$SBD_ASSET_DIR/rule-sets/geosite" \
        '{format:1,nodes:[{id:"n1",name:"a",inbound_tag:"t1"}],
          tls:{certificates:[{directory:$cert}],providers:["le"]},
          policy:{rule_sets:[{directory:$ruleset}]}}' > "$SBD_LEGACY_DATA_DIR/registry.json" || exit 1
    printf '{}\n' > "$SBD_EXPORTS/n1.json" || exit 1
    printf 'link\n' > "$SBD_EXPORTS/n1.txt" || exit 1
    plan=$(sbd_uninstall_plan purge) || exit 1
    t_assert '清单包含第一代配置' jq -e --arg f "$SBD_LEGACY_CONF_DIR/config.json" '.files|index($f)!=null' <<< "$plan"
    t_assert '清单包含第一代 Schema 与数据文件' jq -e --arg root "$SBD_ROOT" \
        '[(.files|index($root+"/config/schema.json"))!=null,
          (.files|index($root+"/data/state.json"))!=null,
          (.files|index($root+"/data/registry.json"))!=null,
          (.files|index($root+"/data/sing-box.log"))!=null] | all' <<< "$plan"
    t_assert '清单包含登记节点的导出文件' jq -e --arg json "$SBD_EXPORTS/n1.json" --arg txt "$SBD_EXPORTS/n1.txt" \
        '[(.files|index($json))!=null,(.files|index($txt))!=null] | all' <<< "$plan"
    t_assert '清单包含托管证书目录' jq -e --arg d "$SBD_CERT_DIR/example.com" '.trees|index($d)!=null' <<< "$plan"
    t_assert '清单包含规则集目录' jq -e --arg d "$SBD_ASSET_DIR/rule-sets/geosite" '.trees|index($d)!=null' <<< "$plan"
    t_assert '清单包含 provider 数据目录' jq -e --arg d "$SBD_CERT_DIR/acme/le" '.trees|index($d)!=null' <<< "$plan"
}

purge_plan_prefers_current() {
    t_fresh
    local plan
    mkdir "$SBD_LEGACY_CONF_DIR" "$SBD_LEGACY_DATA_DIR" || exit 1
    jq -n '{nodes:[{id:"new1"}]}' > "$SBD_REGISTRY" || exit 1
    jq -n '{nodes:[{id:"old1"}]}' > "$SBD_LEGACY_DATA_DIR/registry.json" || exit 1
    printf '{}\n' > "$SBD_EXPORTS/new1.txt" || exit 1
    printf '{}\n' > "$SBD_EXPORTS/old1.txt" || exit 1
    plan=$(sbd_uninstall_plan purge) || exit 1
    t_assert '当前布局 registry 仍优先' jq -e --arg txt "$SBD_EXPORTS/new1.txt" --arg old "$SBD_EXPORTS/old1.txt" \
        '[(.files|index($txt))!=null,(.files|index($old))==null] | all' <<< "$plan"
}

purge_plan_gen1_material_dirs() {
    t_fresh
    rm -f "$SBD_STATE" "$SBD_REGISTRY" || exit 1
    local plan
    mkdir -p "$SBD_LEGACY_CONF_DIR" "$SBD_LEGACY_DATA_DIR/certificates/example.com" \
        "$SBD_LEGACY_DATA_DIR/rule-sets/geosite" "$SBD_LEGACY_DATA_DIR/acme/le" || exit 1
    jq -n --arg dir "$SBD_LEGACY_DATA_DIR/acme/le" \
        '{certificate_providers:[{tag:"le",data_directory:$dir}]}' > "$SBD_LEGACY_CONF_DIR/config.json" || exit 1
    jq -n --arg cert "$SBD_LEGACY_DATA_DIR/certificates/example.com" \
        --arg ruleset "$SBD_LEGACY_DATA_DIR/rule-sets/geosite" \
        '{format:1,nodes:[],tls:{certificates:[{directory:$cert}],providers:["le"]},
          policy:{rule_sets:[{directory:$ruleset}]}}' > "$SBD_LEGACY_DATA_DIR/registry.json" || exit 1
    plan=$(sbd_uninstall_plan purge) || exit 1
    t_assert '清单包含第一代证书目录' jq -e --arg d "$SBD_LEGACY_DATA_DIR/certificates/example.com" '.trees|index($d)!=null' <<< "$plan"
    t_assert '清单包含第一代规则集目录' jq -e --arg d "$SBD_LEGACY_DATA_DIR/rule-sets/geosite" '.trees|index($d)!=null' <<< "$plan"
    t_assert '清单包含第一代 provider 数据目录' jq -e --arg d "$SBD_LEGACY_DATA_DIR/acme/le" '.trees|index($d)!=null' <<< "$plan"
    t_assert '清单包含第一代缓存文件' jq -e --arg f "$SBD_LEGACY_DATA_DIR/cache.db" '.files|index($f)!=null' <<< "$plan"
}

purge_plan_legacy_backup() {
    t_fresh
    local plan backup="$SBD_WORK/legacy-layout.ABC"
    mkdir -p "$backup/legacy/data" "$backup/legacy/config" || exit 1
    printf '{"format":1,"nodes":[{"id":"n1"}]}\n' > "$backup/legacy/data/registry.json" || exit 1
    printf '{}\n' > "$backup/legacy/config/config.json" || exit 1
    plan=$(sbd_uninstall_plan purge) || exit 1
    t_assert '清单包含旧布局迁移备份' jq -e --arg d "$backup" '.trees|index($d)!=null' <<< "$plan"
}

purge_plan_write_lock() {
    t_fresh
    local plan
    mkdir -p "$SBD_ROOT/run" || exit 1
    printf '' > "$SBD_ROOT/run/singbox-deploy.lock" || exit 1
    plan=$(sbd_uninstall_plan purge) || exit 1
    t_assert '清单包含部署私有写锁' jq -e --arg f "$SBD_ROOT/run/singbox-deploy.lock" '.files|index($f)!=null' <<< "$plan"
    t_assert '写锁排在清单末尾最后删除' jq -e --arg f "$SBD_ROOT/run/singbox-deploy.lock" '.files[-1]==$f' <<< "$plan"
}

t_case '第一代布局 purge 清单回退读取旧数据' purge_plan_gen1
t_case '第一代托管目录进入 purge 清单' purge_plan_gen1_material_dirs
t_case '旧布局迁移备份进入 purge 清单' purge_plan_legacy_backup
t_case 'purge 清单优先当前布局 registry' purge_plan_prefers_current
t_case 'purge 清单包含部署私有写锁且最后删除' purge_plan_write_lock
t_finish
