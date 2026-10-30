#!/usr/bin/env python3
"""按需读取原生 Clash API，不持久化样本，不使用环境代理。"""
import ipaddress
import json
import sys
import urllib.request
from urllib.parse import urlsplit


def main():
    try:
        with open(sys.argv[1], encoding="utf-8") as f:
            api = json.load(f).get("experimental", {}).get("clash_api", {})
        address = api.get("external_controller", "")
        parsed = urlsplit("http://" + address)
        if not ipaddress.ip_address(parsed.hostname).is_loopback or not parsed.port or not api.get("secret"):
            raise ValueError()
        request = urllib.request.Request("http://" + address + "/" + sys.argv[2], headers={"Authorization": "Bearer " + api["secret"]})
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=5) as response:
            data = json.loads(response.readline() if sys.argv[2] == "traffic" else response.read())
        if sys.argv[2] == "traffic":
            result = {"up": data["up"], "down": data["down"]}
        else:
            result = {"uploadTotal": data["uploadTotal"], "downloadTotal": data["downloadTotal"], "connections": [
                {**{k: c.get(k) for k in ("id", "upload", "download", "start")},
                 "metadata": {k: c.get("metadata", {}).get(k) for k in ("network", "type", "host", "sourceIP", "sourcePort", "destinationIP", "destinationPort")}}
                for c in data.get("connections", [])]}
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except Exception as error:
        print("[错误] 无法取得原生 API 样本 (" + type(error).__name__ + ")", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
