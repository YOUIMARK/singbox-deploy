#!/usr/bin/env python3
"""DNS 简易入口：地址解析、只读摘要和不覆盖存量对象的默认上游切换。"""

import hashlib
import ipaddress
import json
import re
import sys
from urllib.parse import urlsplit

import policy_records as policy


STRATEGIES = {
    "auto": "自动",
    "prefer_ipv4": "IPv4 优先",
    "prefer_ipv6": "IPv6 优先",
    "ipv4_only": "仅 IPv4",
    "ipv6_only": "仅 IPv6",
}
PORTS = {"udp": 53, "tcp": 53, "tls": 853, "https": 443, "quic": 853}


def host_name(value):
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        if len(value) > 253 or not all(
            re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", part)
            for part in value.split(".")
        ):
            raise ValueError("DNS 地址须为域名或 IP，URL 中 IPv6 请加方括号") from None
        return value.lower()


def parse_address(address):
    if not address or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in address):
        raise ValueError("DNS 地址不能为空或包含空白/控制字符")
    if address == "local":
        return {"type": "local"}
    if "://" not in address:
        server = host_name(address)
        return {"type": "udp", "server": server, "server_port": 53}
    url = urlsplit(address)
    if url.scheme not in PORTS or not url.hostname or url.username is not None or url.password is not None:
        raise ValueError("支持 local、IP、udp://、tcp://、tls://、quic://、https:// 地址")
    if "?" in address or "#" in address or url.netloc.endswith(":"):
        raise ValueError("地址不能带查询参数、片段或空端口；特殊配置请用高级设置")
    server = host_name(url.hostname)
    port = url.port if url.port is not None else PORTS[url.scheme]
    if not 1 <= port <= 65535:
        raise ValueError("DNS 端口须在 1 到 65535 之间")
    value = {"type": url.scheme, "server": server, "server_port": port}
    if url.scheme == "https":
        value["path"] = url.path or "/dns-query"
    elif url.path not in ("", "/"):
        raise ValueError("只有 HTTPS 地址可以带 path")
    if url.scheme in ("https", "tls", "quic"):
        value["tls"] = {"enabled": True, "server_name": server}
    return value


def ensure_server(config, registry, value):
    servers = policy.array(config, "dns_servers")
    # 同配置复用；不同配置即使占用生成的 tag 也不接管、不覆盖。
    for server in servers:
        if server.get("tag") and {k: v for k, v in server.items() if k != "tag"} == value:
            return server["tag"]
    digest = hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()[:12]
    base = "dns.quick." + digest
    occupied = {server.get("tag") for server in servers} | {
        rec["id"] for rec in policy.records(registry, "dns_servers")
    }
    tag, suffix = base, 1
    while tag in occupied:
        tag = f"{base}.{suffix}"
        suffix += 1
    policy.edit(config, registry, {
        "area": "dns_servers", "action": "add", "id": tag, "value": dict(value, tag=tag),
    })
    return tag


def switch(config, registry, address):
    policy.align(config, registry)
    value = parse_address(address)
    if value.get("server") and policy.is_domain(value["server"]):
        # 独立本地解析器不依赖正在切换的默认上游，避免 bootstrap 自引用。
        value["domain_resolver"] = ensure_server(config, registry, {"type": "local"})
    tag = ensure_server(config, registry, value)
    config.setdefault("dns", {})["final"] = tag
    route = config.setdefault("route", {})
    old = route.get("default_domain_resolver")
    route["default_domain_resolver"] = dict(old, server=tag) if isinstance(old, dict) else tag
    policy.references(config)


def server_address(server):
    kind = server.get("type")
    if kind == "local":
        return "系统 DNS"
    if kind not in PORTS or not server.get("server"):
        return "高级配置（" + str(kind or "未知类型") + "）"
    host = server["server"]
    if ":" in host:
        host = f"[{host}]"
    port = server.get("server_port", PORTS[kind])
    port_text = "" if port == PORTS[kind] else f":{port}"
    path = server.get("path", "/dns-query") if kind == "https" else ""
    return f"{kind}://{host}{port_text}{path}"


def summary(config):
    dns = config.get("dns", {})
    servers = dns.get("servers", [])
    tag = dns.get("final") or (servers[0].get("tag") if servers else None)
    found = [server for server in servers if server.get("tag") == tag] if tag else []
    address = server_address(found[0]) if len(found) == 1 else "未设置" if not tag else "未知（默认上游缺失或重复）"
    strategy = dns.get("strategy", "auto")
    result = {"address": address, "strategy": STRATEGIES.get(strategy, f"未知（{strategy}）")}
    # 输出到终端前去掉配置文本中的控制字符，不执行任何终端转义。
    return {key: "".join(c for c in text if c.isprintable()) for key, text in result.items()}


def main():
    try:
        command = sys.argv[1]
        if command == "parse":
            result = parse_address(sys.argv[2])
        elif command == "summary":
            with open(sys.argv[2], encoding="utf-8") as stream:
                result = summary(json.load(stream))
        elif command == "switch":
            stage, address = sys.argv[2:4]
            with open(stage + "/config.json", encoding="utf-8") as stream:
                config = json.load(stream)
            with open(stage + "/registry.json", encoding="utf-8") as stream:
                registry = json.load(stream)
            switch(config, registry, address)
            result = {"config": config, "registry": registry}
        else:
            raise ValueError("未知 DNS 操作")
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError) as error:
        message = str(error) if type(error) is ValueError else "DNS 配置无法读取或解析"
        print("[错误] " + message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
