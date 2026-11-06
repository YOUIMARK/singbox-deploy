#!/usr/bin/env python3
"""列出已知自有文件；未知文件保留，不递归抹掉部署根。"""
import json
import os
from pathlib import Path
import shutil
import sys


CONFIG_PART_NAMES = (
    # 当前布局：一个顶层字段一个分片，编号按 sing-box 官方顶层顺序。
    "00_empty.json",
    "01_log.json",
    "02_dns.json",
    "03_ntp.json",
    "04_certificate.json",
    "05_certificate_providers.json",
    "06_http_clients.json",
    "07_network_namespaces.json",
    "08_endpoints.json",
    "09_inbounds.json",
    "10_outbounds.json",
    "11_route.json",
    "12_services.json",
    "13_experimental.json",
    "99_extra.json",
    # 旧布局：升级后尚未重新分片的部署仍可能保留这些文件。
    "00_base.json",
    "10_dns.json",
    "20_endpoints.json",
    "30_inbounds.json",
    "40_outbounds.json",
    "50_route.json",
    "60_services.json",
    "70_experimental.json",
    "90_extra.json",
)


def build(root, mode):
    root = Path(root).resolve()
    files, trees = set(), set()
    app = root / "app"
    for rel in (app / "manifest.txt").read_text(encoding="utf-8").splitlines():
        p = app / rel
        if p.is_absolute() and p.resolve().is_relative_to(app.resolve()) and ".." not in Path(rel).parts:
            files.add(str(p))
        else:
            raise ValueError("发布清单越界")
    inventory = root / "bin/.sbd-files"
    members = inventory.read_text(encoding="utf-8").splitlines() if inventory.is_file() else ["sing-box", "libcronet.so", "LICENSE"]
    for rel in members + [".sbd-files"]:
        p = root / "bin" / rel
        if p.resolve().is_relative_to((root / "bin").resolve()) and ".." not in Path(rel).parts:
            files.add(str(p))
        else:
            raise ValueError("核心文件清单越界")
    if mode == "purge":
        config_path = root / "confs/config.json"
        if not config_path.is_file():
            config_path = root / "config.json"
        config = json.loads(config_path.read_text(encoding="utf-8")) if config_path.is_file() else {}
        registry = json.loads((root / "state/registry.json").read_text(encoding="utf-8"))
        for name in (
            "confs/config.json",
            "confs/schema.json",
            "confs/input.json",
            "confs/core-version",
            "config.json",
            "schema.json",
            "assets/cache.db",
            "logs/sing-box.log",
        ):
            files.add(str(root / name))
        parts = root / "confs"
        for name in CONFIG_PART_NAMES:
            path = parts / name
            if path.is_file():
                files.add(str(path))
        for p in (root / "exports").iterdir():
            if p.name in ("links.txt", "schema.json") or any(p.name == n["id"] + suffix for n in registry.get("nodes", []) for suffix in (".json", ".txt")):
                files.add(str(p))
        for record in registry.get("tls", {}).get("certificates", []):
            path = record.get("directory")
            if path and Path(path).parent == root / "certs":
                trees.add(path)
        for rec in registry.get("policy", {}).get("rule_sets", []):
            path = rec.get("directory")
            if path and Path(path).parent == root / "assets/rule-sets":
                trees.add(path)
        managed_providers = set(registry.get("tls", {}).get("providers", []))
        for provider in config.get("certificate_providers", []):
            path = provider.get("data_directory", "")
            if provider.get("tag") in managed_providers and path and Path(path).parent == root / "certs/acme":
                trees.add(path)
        for name in ("active", "previous"):
            directory = root / "work" / name
            if directory.is_dir():
                journal = json.loads((directory / "journal.json").read_text(encoding="utf-8"))
                if journal.get("phase") != "accepted":
                    raise ValueError("未收敛事务不能卸载")
                for key in ("created_materials", "retired_materials"):
                    for path in journal.get(key, []):
                        if Path(path).parent in (root / "certs", root / "assets/rule-sets"):
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
            plan = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
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
