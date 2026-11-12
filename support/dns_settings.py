#!/usr/bin/env python3
"""DNS 简易入口：地址解析、只读摘要和按 tag 切换上游。"""

import copy
import hashlib
import ipaddress
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import policy_records as policy


STRATEGIES = {
    "auto": "自动",
    "prefer_ipv4": "IPv4 优先",
    "prefer_ipv6": "IPv6 优先",
    "ipv4_only": "仅 IPv4",
    "ipv6_only": "仅 IPv6",
}
PORTS = {"udp": 53, "tcp": 53, "tls": 853, "https": 443, "quic": 853}
PRESET_TAGS = {
    "local": "system",
    "https://dns.alidns.com/dns-query": "alidns",
    "https://doh.pub/dns-query": "dnspod",
    "https://1.1.1.1/dns-query": "cloudflare",
    "https://cloudflare-dns.com/dns-query": "cloudflare",
    "https://dns.quad9.net/dns-query": "quad9",
    "https://freedns.controld.com/p0": "controld",
    "https://dns.google/dns-query": "google",
}
RACE_GROUP = "dns.default.race"


def default_config():
    with (Path(__file__).resolve().parent.parent / "presets/base.json").open(encoding="utf-8") as stream:
        return json.load(stream)


# evaluate 先并发发起查询，respond 按 NOERROR/NXDOMAIN 竞争；两种 rcode 都要覆盖，
# 否则负响应无法参与竞速。
def race_rules(tags):
    return [
        {"action": "evaluate", "server": tag, "tag": "sd.dns." + tag}
        for tag in tags
    ] + [
        {"action": "respond", "match_response": "sd.dns." + tag,
         "response_rcode": rcode, "race": True}
        for rcode in ("NOERROR", "NXDOMAIN") for tag in tags
    ]


# 优先识别连续规则块；被其他规则插入时退化为按顺序的唯一子序列匹配，有歧义则不认领。
def race_indexes(rules, expected):
    starts = [
        i for i in range(len(rules) - len(expected) + 1)
        if rules[i:i + len(expected)] == expected
    ]
    if len(starts) == 1:
        return list(range(starts[0], starts[0] + len(expected)))
    if starts:
        return None
    matches = []
    for start, rule in enumerate(rules):
        if rule != expected[0]:
            continue
        indexes = [start]
        cursor = start + 1
        for wanted in expected[1:]:
            while cursor < len(rules) and rules[cursor] != wanted:
                cursor += 1
            if cursor == len(rules):
                break
            indexes.append(cursor)
            cursor += 1
        else:
            matches.append(indexes)
    return matches[0] if len(matches) == 1 else None


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
        raise ValueError("地址不能带查询参数、片段或空端口；特殊配置请直接编辑 config.json")
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


def ensure_server(config, registry, value, fixed_tag=None):
    servers = policy.array(config, "dns_servers")
    if fixed_tag:
        found = [server for server in servers if server.get("tag") == fixed_tag]
        if found:
            if len(found) == 1 and {k: v for k, v in found[0].items() if k != "tag"} == value:
                return fixed_tag
            # Cloudflare 的 IP 与域名两种预设形态是同一提供商，不改写已有对象或引用。
            if fixed_tag == "cloudflare" and len(found) == 1:
                forms = (
                    dict(parse_address("https://1.1.1.1/dns-query")),
                    dict(parse_address("https://cloudflare-dns.com/dns-query"), domain_resolver="system"),
                )
                existing = {k: v for k, v in found[0].items() if k != "tag"}
                if existing in forms and value in forms:
                    return fixed_tag
            raise ValueError(f"预设 tag {fixed_tag} 已被不同配置占用；请先在 config.json 中处理，不会覆盖")
        policy.edit(config, registry, {
            "area": "dns_servers", "action": "add", "id": fixed_tag, "value": dict(value, tag=fixed_tag),
        })
        return fixed_tag
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


def addresses(value):
    values = [item.strip() for item in value.split(",")]
    if not all(values) or len(set(values)) != len(values):
        raise ValueError("DNS 地址不能为空或重复；多个地址请用英文逗号分隔")
    for item in values:
        parse_address(item)
    return values


def remove_default_race(config, registry):
    owned = policy.records(registry, "dns_rules")
    if not any(rec.get("group") == RACE_GROUP for rec in owned):
        # 核心首次安装仅发布配置；首次切换时识别本包原样生成的默认组。
        expected = default_config()["dns"]["rules"]
        rules = config.get("dns", {}).get("rules", [])
        indexes = race_indexes(rules, expected)
        if indexes is not None:
            occupied = {rec["index"]: rec for rec in owned}
            grouped, extra = [], []
            for offset, (index, rule) in enumerate(zip(indexes, expected)):
                rec = occupied.get(index)
                if rec is None:
                    extra.append({"id": f"{RACE_GROUP}.{offset}", "index": index,
                                  "group": RACE_GROUP, "expected": rule})
                elif rec.get("expected") == rule:
                    grouped.append(rec)
                else:
                    grouped = None
                    break
            if grouped is not None:
                owned.extend(extra)
                for rec in grouped:
                    rec["group"] = RACE_GROUP
    if any(rec.get("group") == RACE_GROUP for rec in owned):
        policy.edit(config, registry, {"area": "dns_rules", "action": "delete_group", "id": RACE_GROUP})


def server_referenced(config, tag):
    candidate = copy.deepcopy(config)
    dns = candidate.setdefault("dns", {})
    dns["servers"] = [server for server in dns.get("servers", []) if server.get("tag") != tag]
    try:
        policy.references(candidate)
    except ValueError:
        return True
    return False


def remove_unused_servers(config, registry, selected):
    removed = []
    default_servers = default_config()["dns"]["servers"]
    while True:
        managed = {rec["id"] for rec in policy.records(registry, "dns_servers")}
        candidates = [
            server for server in policy.array(config, "dns_servers")
            if server.get("tag") and server["tag"] != "system" and server["tag"] not in selected
            and not server_referenced(config, server["tag"])
            and (server in default_servers or server["tag"] in managed)
        ]
        if not candidates:
            break
        for server in candidates:
            tag = server["tag"]
            if any(rec["id"] == tag for rec in policy.records(registry, "dns_servers")):
                policy.edit(config, registry, {"area": "dns_servers", "action": "delete", "id": tag})
            else:
                policy.array(config, "dns_servers").remove(server)
            if tag not in removed:
                removed.append(tag)
    return removed


# resolve 动作自身的参数；Rule 的其余字段都是匹配条件（sing-box 1.14 Schema 共 45 个），
# 带任何匹配条件的 resolve 只覆盖部分流量，不能当作覆盖全部流量的全局规则。
RESOLVE_ACTION_FIELDS = {
    "action",
    "server",
    "strategy",
    "client_subnet",
    "disable_cache",
    "disable_optimistic_cache",
    "rewrite_ttl",
    "timeout",
}


# 非最终动作不会终止规则遍历（官方文档：hijack-dns 为非最终动作，route/reject 才是
# 最终动作）；缺省动作是最终动作 route。
NON_FINAL_ACTIONS = {"sniff", "resolve", "hijack-dns", "route-options"}

# Rule 中表示匹配条件或逻辑结构的字段；带任意一个就不是“无条件覆盖全部流量”。
ROUTE_MATCH_FIELDS = {
    "type", "mode", "rules", "invert",
    "inbound", "ip_version", "network", "auth_user", "protocol", "client",
    "domain", "domain_suffix", "domain_keyword", "domain_regex",
    "source_ip_cidr", "source_ip_is_private",
    "source_port", "source_port_range", "source_hostname", "source_mac_address",
    "port", "port_range", "process_name", "process_path", "process_path_regex",
    "package_name", "package_name_regex", "user", "user_id", "clash_mode",
    "ip_cidr", "ip_is_private", "rule_set", "rule_set_ip_cidr_match_source",
    "wifi_ssid", "wifi_bssid", "network_type", "network_is_expensive",
    "network_is_constrained", "network_interface_address", "interface_address",
    "default_interface_address", "preferred_by", "dns_search_domain",
    "dns_server_address",
}


def has_global_resolve_rule(rules):
    """全局 resolve 必须无匹配条件，且排在所有无条件的最终动作之前。"""
    for rule in rules:
        if not isinstance(rule, dict):
            continue
        if rule.get("action") == "resolve" and set(rule) <= RESOLVE_ACTION_FIELDS:
            return True
        if rule.get("action", "route") not in NON_FINAL_ACTIONS and not (
            set(rule) & ROUTE_MATCH_FIELDS
        ):
            return False
    return False


def switch(config, registry, address):
    policy.align(config, registry)
    selected = addresses(address) if address != "default" else [
        server_address(server) for server in default_config()["dns"]["servers"] if server["type"] == "https"
    ]
    tags = []
    for item in selected:
        value = parse_address(item)
        if value.get("server") and policy.is_domain(value["server"]):
            # 独立本地解析器不依赖正在切换的默认上游，避免 bootstrap 自引用。
            value["domain_resolver"] = ensure_server(config, registry, {"type": "local"})
        tags.append(ensure_server(config, registry, value, PRESET_TAGS.get(item)))
    if len(set(tags)) != len(tags):
        raise ValueError("竞速上游不能重复")
    remove_default_race(config, registry)
    config.setdefault("dns", {})["final"] = tags[0]
    route = config.setdefault("route", {})
    old = route.get("default_domain_resolver")
    route["default_domain_resolver"] = dict(old, server=tags[0]) if isinstance(old, dict) else tags[0]
    if len(tags) > 1:
        for index, rule in enumerate(race_rules(tags)):
            policy.edit(config, registry, {"area": "dns_rules", "action": "add", "id": f"{RACE_GROUP}.{index}",
                                          "group": RACE_GROUP, "value": rule})
        # 显式拨号解析器会绕过 DNS 路由；代理目标先通过原生 resolve 动作解析。
        if not has_global_resolve_rule(route.get("rules", [])):
            policy.edit(config, registry, {"area": "route_rules", "action": "add", "id": "dns.default.resolve",
                                          "value": {"action": "resolve"}, "position": 0})
    removed = remove_unused_servers(config, registry, set(tags))
    policy.references(config)
    return removed


def unchanged(config, registry, address):
    candidate = copy.deepcopy(config)
    switch(candidate, copy.deepcopy(registry), address)
    return candidate == config


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
    rules = dns.get("rules", [])
    tags = [rule["server"] for rule in rules if rule.get("action") == "evaluate" and rule.get("tag") == "sd.dns." + rule.get("server", "")]
    expected = race_rules(tags)
    if len(tags) > 1 and race_indexes(rules, expected) is not None:
        mapped = {server.get("tag"): server for server in servers}
        result["address"] = ", ".join(server_address(mapped.get(tag, {})) for tag in tags)
        result["race"] = "开启" if has_global_resolve_rule(config.get("route", {}).get("rules", [])) else "仅 DNS 查询（代理目标未接入）"
    else:
        result["race"] = "自定义规则" if any(rule.get("race") for rule in policy.objects(rules)) else "关闭"
    # 输出到终端前去掉配置文本中的控制字符，不执行任何终端转义。
    return {key: "".join(c for c in text if c.isprintable()) for key, text in result.items()}


def main():
    try:
        command = sys.argv[1]
        if command == "parse":
            parsed = [parse_address(item) for item in addresses(sys.argv[2])]
            result = parsed[0] if len(parsed) == 1 else parsed
        elif command == "summary":
            with open(sys.argv[2], encoding="utf-8") as stream:
                result = summary(json.load(stream))
        elif command == "switch":
            stage, address = sys.argv[2:4]
            with open(stage + "/config.json", encoding="utf-8") as stream:
                config = json.load(stream)
            with open(stage + "/registry.json", encoding="utf-8") as stream:
                registry = json.load(stream)
            removed = switch(config, registry, address)
            result = {"config": config, "registry": registry, "removed": removed}
        elif command == "unchanged":
            config_path, registry_path, address = sys.argv[2:5]
            with open(config_path, encoding="utf-8") as stream:
                config = json.load(stream)
            with open(registry_path, encoding="utf-8") as stream:
                registry = json.load(stream)
            result = {"unchanged": unchanged(config, registry, address)}
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
