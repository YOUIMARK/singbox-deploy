#!/usr/bin/env bash
# ROOT 由共享 harness 初始化。
# shellcheck disable=SC2153
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$ROOT/install.sh"

manifest_contract() {
    t_run 0 sbd_install_validate "$ROOT"
    local module count=0
    for module in "$ROOT"/lib/*.sh; do
        t_assert '每 lib 出现在唯一发布清单' grep -Fxq "lib/${module##*/}" "$ROOT/manifest.txt"
        t_assert '每 lib 有对应契约' test -s "$ROOT/tests/contracts/${module##*/}"
        count=$((count + 1))
    done
    t_assert '本阶段为已选 14 个领域模块' test "$count" = 14
}
negative_control() {
    local rc=0
    ( t_assert '阴性对照必须失败' false; printf '不应到达\n' ) > "$CASE_TMP/negative" 2>&1 || rc=$?
    t_assert '断言失败真的结束案例' test "$rc" = 1
    t_absent "$CASE_TMP/negative" '不应到达'
}
source_isolation() {
    t_fresh
    t_assert 'source 不创建生产配置' test ! -e "$SBD_CONFIG"
    t_assert 'source 不启动服务' test ! -e "$CASE_TMP/actions"
}
mutation_control() {
    local clone="$CASE_TMP/mutated-repo" rel
    mkdir "$clone" || exit 1
    while IFS= read -r rel; do
        mkdir -p "$(dirname -- "$clone/$rel")" || exit 1
        cp "$ROOT/$rel" "$clone/$rel" || exit 1
    done < "$ROOT/manifest.txt"
    cp -a "$ROOT/tests" "$clone/tests" || exit 1
    # 只在独立副本引入“写失败仍成功”，直接复跑原有记录契约，不更改断言。
    python3 - "$clone/lib/records.sh" <<'PY' || exit 1
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = '_error "文件提交失败: $target"\n        return 1'
if text.count(old) != 1:
    raise SystemExit("阴性对照锚点不唯一，不能猜测修改位置")
path.write_text(text.replace(old, old.replace("return 1", "return 0")))
PY
    t_run 1 bash "$clone/tests/contracts/records.sh"
    t_contains "$CASE_TMP/output" '失败: mv 失败保留旧记录'
    t_assert '原套件确实报告失败数' grep -Eq 'SUMMARY pass=[0-9]+ fail=[1-9][0-9]*' "$CASE_TMP/output"
}
t_case '单份清单与每模块契约对齐' manifest_contract
t_case '测试断言隔离阴性对照' negative_control
t_case '模块 source 不初始化业务配置' source_isolation
t_case '真实旧契约抓住临时副本的假成功退化' mutation_control
t_finish
