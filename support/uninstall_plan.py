#!/usr/bin/env python3
"""列出已知自有文件；未知文件保留，不递归抹掉部署根。"""
import json
import os
from pathlib import Path
import shutil
import sys


def build(root, mode):
    root = Path(root).resolve()
    files, trees = set(), set()
    app = root / "app"
    for rel in (app / "manifest.txt").read_text().splitlines():
        p = app / rel
        if p.is_absolute() and p.resolve().is_relative_to(app.resolve()) and ".." not in Path(rel).parts:
            files.add(str(p))
        else:
            raise ValueError("发布清单越界")
    inventory = root / "engine/.sbd-files"
    members = inventory.read_text().splitlines() if inventory.is_file() else ["sing-box", "libcronet.so", "LICENSE"]
    for rel in members + [".sbd-files"]:
        p = root / "engine" / rel
        if p.resolve().is_relative_to((root / "engine").resolve()) and ".." not in Path(rel).parts:
            files.add(str(p))
        else:
            raise ValueError("核心文件清单越界")
    if mode == "purge":
        config = json.loads((root / "config/config.json").read_text()) if (root / "config/config.json").is_file() else {}
        registry = json.loads((root / "data/registry.json").read_text())
        for name in ("config/config.json", "config/schema.json", "data/cache.db", "data/sing-box.log"):
            files.add(str(root / name))
        for p in (root / "exports").iterdir():
            if p.name in ("links.txt", "schema.json") or any(p.name == n["id"] + suffix for n in registry.get("nodes", []) for suffix in (".json", ".txt")):
                files.add(str(p))
        for record in registry.get("tls", {}).get("certificates", []):
            path = record.get("directory")
            if path and Path(path).parent == root / "data/certificates":
                trees.add(path)
        for rec in registry.get("policy", {}).get("rule_sets", []):
            path = rec.get("directory")
            if path and Path(path).parent == root / "data/rule-sets":
                trees.add(path)
        managed_providers = set(registry.get("tls", {}).get("providers", []))
        for provider in config.get("certificate_providers", []):
            path = provider.get("data_directory", "")
            if provider.get("tag") in managed_providers and path and Path(path).parent == root / "data/acme":
                trees.add(path)
        for name in ("active", "previous"):
            directory = root / "work" / name
            if directory.is_dir():
                journal = json.loads((directory / "journal.json").read_text())
                if journal.get("phase") != "accepted":
                    raise ValueError("未收敛事务不能卸载")
                for key in ("created_materials", "retired_materials"):
                    for path in journal.get(key, []):
                        if Path(path).parent in (root / "data/certificates", root / "data/rule-sets"):
                            trees.add(path)
                trees.add(str(directory))
    elif mode != "keep":
        raise ValueError("未知卸载模式")
    return {"format": 1, "mode": mode, "root": str(root), "files": sorted(files), "trees": sorted(trees)}


def main():
    try:
        if sys.argv[1] == "plan":
            print(json.dumps(build(sys.argv[2], sys.argv[3]), ensure_ascii=False))
        else:
            plan = json.loads(Path(sys.argv[2]).read_text())
            root = Path(plan["root"]).resolve()
            for group in ("trees", "files"):
                for name in plan[group]:
                    p = Path(name)
                    if not p.resolve().is_relative_to(root) or p.resolve() == root or p.is_symlink():
                        raise ValueError("删除目标越界或是未知链接，保留现场")
                    if group == "trees":
                        if p.exists():
                            shutil.rmtree(p)
                    else:
                        p.unlink(missing_ok=True)
            # 只移除空目录，未知文件所在目录保留。
            for base, dirs, files in os.walk(root, topdown=False):
                if Path(base) != root:
                    try:
                        Path(base).rmdir()
                    except OSError:
                        pass
        return 0
    except Exception as error:
        print("[错误] 卸载清单处理未完成 (" + type(error).__name__ + ")", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
