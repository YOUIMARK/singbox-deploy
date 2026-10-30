#!/usr/bin/env python3
"""只使用目标核心生成的 JSON Schema，不维护另一套配置规则。"""

import json
import sys


def main():
    if len(sys.argv) != 3:
        print("用法: validate_schema.py schema.json config.json", file=sys.stderr)
        return 1
    try:
        from jsonschema import Draft202012Validator, FormatChecker

        with open(sys.argv[1], encoding="utf-8") as stream:
            schema = json.load(stream)
        with open(sys.argv[2], encoding="utf-8") as stream:
            instance = json.load(stream)
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            print("[错误] 核心 Schema 不是 Draft 2020-12", file=sys.stderr)
            return 1
        Draft202012Validator.check_schema(schema)
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        failed = False
        for error in validator.iter_errors(instance):
            failed = True
            pointer = "/" + "/".join(
                str(part).replace("~", "~0").replace("/", "~1")
                for part in error.absolute_path
            )
            # 原始 message 可能包含密码或私钥，只显示位置与失败关键字。
            print(f"[错误] Schema {pointer}: {error.validator}", file=sys.stderr)
        return 1 if failed else 0
    except Exception as error:
        print(f"[错误] Schema 校验无法完成 ({type(error).__name__})", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
