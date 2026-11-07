#!/usr/bin/env bash
# 服务边界使用窄桩；配置生成、Schema/format/check 与文件归档走真实实现。
# shellcheck disable=SC2329
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"

m_migration_fixture() {
    t_fresh
    mkdir "$CASE_TMP/etc" || exit 1
    printf 'running\n' > "$CASE_TMP/runtime" || exit 1
    printf 'ExecStart=%s -D %s -c %s run\n' "$SBD_BINARY" "$SBD_ROOT" "$SBD_LEGACY_CONFIG" > "$CASE_TMP/etc/service" || exit 1
    sbd_go_memlimit_mb() { printf '40\n'; }
    sbd_backend() { printf 'systemd\n'; }
    sbd_service_file() { printf '%s/etc/service\n' "$CASE_TMP"; }
    sbd_service_state() { cat "$CASE_TMP/runtime"; }
    sbd_service_restore() {
        printf '%s\n' "$1" > "$CASE_TMP/runtime"
        printf 'restore %s\n' "$1" >> "$CASE_TMP/actions"
    }
    sbd_service_reload() { printf 'reload\n' >> "$CASE_TMP/actions"; }
}

migration_success() {
    m_migration_fixture
    cp "$ROOT/tests/fixtures/valid.json" "$SBD_LEGACY_CONFIG" || exit 1
    printf '{"log":{"level":"warn"}}\n' > "$SBD_CONF_DIR/01_log.json" || exit 1
    printf 'unknown config\n' > "$SBD_CONF_DIR/user-notes.txt" || exit 1
    t_run 0 sbd_migrate_legacy_layout
    t_assert '迁移后生成单配置' test -s "$SBD_CONFIG"
    t_assert '迁移后生成匹配 Schema' test -s "$SBD_SCHEMA"
    t_assert '旧根配置已归档' test ! -e "$SBD_LEGACY_CONFIG"
    t_assert '旧分片已归档' test ! -e "$SBD_CONF_DIR/01_log.json"
    t_contains "$SBD_CONF_DIR/user-notes.txt" 'unknown config'
    t_contains "$CASE_TMP/etc/service" "-c $SBD_CONFIG"
    t_assert '保持原运行态' test "$(cat "$CASE_TMP/runtime")" = running
    t_contains "$CASE_TMP/actions" 'restore running'
    t_assert '迁移后真实配置可检查' sbd_check_config
    local backup
    backup=$(find "$SBD_WORK" -maxdepth 1 -type d -name 'legacy-layout.*' -print -quit) || exit 1
    t_assert '旧配置和分片有独立备份' test -s "$backup/legacy/config.json" -a -s "$backup/legacy/01_log.json"
}

migration_already_single() {
    m_migration_fixture
    rm "$CASE_TMP/etc/service" || exit 1
    cp "$ROOT/tests/fixtures/valid.json" "$SBD_CONFIG" || exit 1
    t_prepare_live || exit 1
    cp "$SBD_CONFIG" "$CASE_TMP/before" || exit 1
    : > "$CASE_TMP/actions" || exit 1
    t_run 0 sbd_migrate_legacy_layout
    t_assert '已是单配置时不重写' cmp -s "$SBD_CONFIG" "$CASE_TMP/before"
    t_assert '已是单配置时不重启' test ! -s "$CASE_TMP/actions"
}

migration_cleanup_only() {
    m_migration_fixture
    rm "$CASE_TMP/etc/service" || exit 1
    cp "$ROOT/tests/fixtures/valid.json" "$SBD_CONFIG" || exit 1
    t_prepare_live || exit 1
    cp "$SBD_CONFIG" "$CASE_TMP/before" || exit 1
    cp "$ROOT/tests/fixtures/valid.json" "$SBD_LEGACY_CONFIG" || exit 1
    printf '{"log":{"level":"warn"}}\n' > "$SBD_CONF_DIR/01_log.json" || exit 1
    t_run 0 sbd_migrate_legacy_layout
    t_assert '已有单配置不被旧根配置覆盖' cmp -s "$SBD_CONFIG" "$CASE_TMP/before"
    t_assert '清理旧根配置' test ! -e "$SBD_LEGACY_CONFIG"
    t_assert '清理旧分片' test ! -e "$SBD_CONF_DIR/01_log.json"
}

migration_validation_failure() {
    m_migration_fixture
    cp "$ROOT/tests/fixtures/invalid-key.json" "$SBD_LEGACY_CONFIG" || exit 1
    cp "$CASE_TMP/etc/service" "$CASE_TMP/old-service" || exit 1
    t_run 1 sbd_migrate_legacy_layout
    t_assert '失败不发布新配置' test ! -e "$SBD_CONFIG"
    t_assert '失败保留旧根配置' test -s "$SBD_LEGACY_CONFIG"
    t_assert '失败不重写服务' cmp -s "$CASE_TMP/etc/service" "$CASE_TMP/old-service"
}

migration_schema_publish_failure() {
    m_migration_fixture
    cp "$ROOT/tests/fixtures/valid.json" "$SBD_LEGACY_CONFIG" || exit 1
    local definition
    definition=$(declare -f sbd_atomic_file) || exit 1
    eval "${definition/sbd_atomic_file/sbd_atomic_file_original}"
    sbd_atomic_file() {
        [[ "$2" != "$SBD_SCHEMA" ]] || return 1
        sbd_atomic_file_original "$@"
    }
    t_run 1 sbd_migrate_legacy_layout
    t_assert 'Schema 发布失败时不创建新布局标记' test ! -e "$SBD_CONFIG"
    t_assert 'Schema 发布失败时保留旧配置' test -s "$SBD_LEGACY_CONFIG"
}

migration_cleanup_broken_live() {
    m_migration_fixture
    rm "$CASE_TMP/etc/service" || exit 1
    cp "$ROOT/tests/fixtures/invalid-key.json" "$SBD_CONFIG" || exit 1
    cp "$SBD_CONFIG" "$CASE_TMP/before" || exit 1
    cp "$ROOT/tests/fixtures/valid.json" "$SBD_LEGACY_CONFIG" || exit 1
    printf '{"log":{"level":"warn"}}\n' > "$SBD_CONF_DIR/01_log.json" || exit 1
    t_run 0 sbd_migrate_legacy_layout
    t_assert '清理残留不覆盖当前配置' cmp -s "$SBD_CONFIG" "$CASE_TMP/before"
    t_assert '清理残留不要求当前配置通过校验' test ! -e "$SBD_LEGACY_CONFIG"
    t_assert '清理残留归档旧分片' test ! -e "$SBD_CONF_DIR/01_log.json"
}

migration_no_source() {
    m_migration_fixture
    rm "$CASE_TMP/etc/service" || exit 1
    printf '{"log":{"level":"warn"}}\n' > "$SBD_LEGACY_SCHEMA" || exit 1
    printf '{"log":{"level":"warn"}}\n' > "$SBD_CONF_DIR/01_log.json" || exit 1
    t_run 0 sbd_migrate_legacy_layout
    t_contains "$CASE_TMP/output" '找不到可迁移的配置源'
    t_assert '没有配置源时不生成配置' test ! -e "$SBD_CONFIG"
    t_assert '没有配置源时保留旧分片' test -s "$SBD_CONF_DIR/01_log.json"
    t_assert '没有配置源时保留旧根 Schema' test -s "$SBD_LEGACY_SCHEMA"
}

m_gen1_fixture() {
    m_migration_fixture
    rm -f "$SBD_STATE" "$SBD_REGISTRY" || exit 1
    printf 'ExecStart=%s/engine/sing-box -D %s -c %s/config/config.json run\n' "$SBD_ROOT" "$SBD_ROOT" "$SBD_ROOT" > "$CASE_TMP/etc/service" || exit 1
    mkdir "$SBD_LEGACY_CONF_DIR" "$SBD_LEGACY_DATA_DIR" || exit 1
    cp "$ROOT/tests/fixtures/valid.json" "$SBD_LEGACY_CONF_DIR/config.json" || exit 1
    printf '{"format":1,"manager_version":"0.1.0","revision":7}\n' > "$SBD_LEGACY_DATA_DIR/state.json" || exit 1
    printf '{"format":1,"nodes":[]}\n' > "$SBD_LEGACY_DATA_DIR/registry.json" || exit 1
}

migration_gen1_success() {
    m_gen1_fixture
    t_run 0 sbd_migrate_legacy_layout
    t_assert '第一代配置迁移为单配置' test -s "$SBD_CONFIG"
    t_assert '迁移后真实配置可检查' sbd_check_config
    t_assert 'state 随迁保留修订号' jq -e '.revision==7' "$SBD_STATE"
    t_assert 'registry 随迁' test -s "$SBD_REGISTRY"
    t_assert '旧目录已归档' test ! -e "$SBD_LEGACY_CONF_DIR" -a ! -e "$SBD_LEGACY_DATA_DIR"
    t_contains "$CASE_TMP/etc/service" "-c $SBD_CONFIG"
    t_contains "$CASE_TMP/actions" 'restore running'
    local backup
    backup=$(find "$SBD_WORK" -maxdepth 1 -type d -name 'legacy-layout.*' -print -quit) || exit 1
    t_assert '旧配置与旧数据有独立备份' test -s "$backup/legacy/config/config.json" -a -s "$backup/legacy/data/registry.json"
}

migration_gen1_interrupted() {
    m_gen1_fixture
    cp "$CASE_TMP/etc/service" "$CASE_TMP/old-service" || exit 1
    cp() {
        local arg
        for arg in "$@"; do
            [[ "$arg" != "$SBD_STATE_DIR/registry.json" ]] || return 1
        done
        command cp "$@"
    }
    t_run 1 sbd_migrate_legacy_layout
    t_assert '发布标记已生成' test -s "$SBD_CONFIG"
    t_assert '中断保留旧 registry' test -s "$SBD_LEGACY_DATA_DIR/registry.json"
    t_assert '中断未迁入 registry' test ! -e "$SBD_REGISTRY"
    t_assert '部分成功的 state 保留' test -s "$SBD_STATE"
    t_assert '中断不归档旧目录' test -d "$SBD_LEGACY_DATA_DIR"
    t_assert '中断不重写服务' cmp -s "$CASE_TMP/etc/service" "$CASE_TMP/old-service"
    unset -f cp
    t_run 0 sbd_migrate_legacy_layout
    t_assert '重试补迁 registry' jq -e '.format==1' "$SBD_REGISTRY"
    t_assert '重试保留已迁入的修订号' jq -e '.revision==7' "$SBD_STATE"
    t_assert '重试后旧目录归档' test ! -e "$SBD_LEGACY_CONF_DIR" -a ! -e "$SBD_LEGACY_DATA_DIR"
    local backup found=''
    for backup in "$SBD_WORK"/legacy-layout.*; do
        if [[ -s "$backup/legacy/data/registry.json" && -s "$backup/legacy/config/config.json" ]]; then
            found=$backup
            break
        fi
    done
    t_assert '备份包含旧 registry 与旧配置' test -n "$found"
}

t_case '旧根配置迁移为 confs 单配置并切换服务' migration_success
t_case '已是单配置时迁移为空操作' migration_already_single
t_case '已有单配置时只归档旧布局残留' migration_cleanup_only
t_case '旧配置校验失败时保持原布局' migration_validation_failure
t_case 'Schema 发布失败时不留下不完整的新布局' migration_schema_publish_failure
t_case '清理旧残留不依赖当前配置可校验' migration_cleanup_broken_live
t_case '只有旧残留没有配置源时保留原文件' migration_no_source
t_case '第一代 config/+data/ 布局整体迁移' migration_gen1_success
t_case '迁移中断后重试补迁并归档' migration_gen1_interrupted
t_finish
