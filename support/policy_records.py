#!/usr/bin/env python3
"""维护无原生 ID 的规则关联及存活引用；字段格式仍交官方 Schema/check。"""

import copy
import ipaddress
import json
import sys
from urllib.parse import urlsplit


AREAS = {
    "route_rules": ("route", "rules"),
    "dns_rules": ("dns", "rules"),
    "dns_servers": ("dns", "servers"),
    "rule_sets": ("route", "rule_set"),
    "endpoints": ("", "endpoints"),
    "connectors": ("", "inbounds"),
}
POSITIONAL = {"route_rules", "dns_rules"}


def array(config, area):
    section, key = AREAS[area]
    parent = config.setdefault(section, {}) if section else config
    return parent.setdefault(key, [])


def records(registry, area):
    return registry.setdefault("policy", {}).setdefault(area, [])


def locate(config, area, record):
    values = array(config, area)
    if area in POSITIONAL:
        index = record["index"]
        if not isinstance(index, int) or index < 0 or index >= len(values):
            raise ValueError("托管规则位置已变化，请先显式协调")
        return values[index]
    found = [v for v in values if v.get("tag") == record["id"]]
    if len(found) != 1:
        raise ValueError("托管标识缺失或重复，请先显式协调")
    return found[0]


def align(config, registry):
    for area in AREAS:
        ids, indexes = set(), set()
        for rec in records(registry, area):
            if rec["id"] in ids:
                raise ValueError("托管登记 ID 重复")
            ids.add(rec["id"])
            if area in POSITIONAL:
                if rec["index"] in indexes:
                    raise ValueError("托管规则位置登记重复")
                indexes.add(rec["index"])
            if locate(config, area, rec) != rec["expected"]:
                raise ValueError("托管规则、上游或规则集发生漂移，请先显式协调")


def edit(config, registry, request):
    area, action = request["area"], request["action"]
    values, owned = array(config, area), records(registry, area)
    ident = request.get("id")
    matches = [r for r in owned if r["id"] == ident]
    rec = matches[0] if len(matches) == 1 else None
    if action == "add":
        if matches:
            raise ValueError("托管 ID 已存在")
        rec = {"id": ident}
        if area in POSITIONAL:
            index = request.get("position", len(values))
            if not isinstance(index, int) or index < 0 or index > len(values):
                raise ValueError("插入位置无效")
            for r in owned:
                if r["index"] >= index:
                    r["index"] += 1
            values.insert(index, request["value"])
            rec["index"] = index
        else:
            if any(v.get("tag") == ident or ident in tags(v.get("tag")) for v in values):
                raise ValueError("标识已被配置占用；不会自动接管")
            values.append(request["value"])
        owned.append(rec)
    elif action == "delete_group":
        if area not in POSITIONAL:
            raise ValueError("此对象没有规则组")
        selected = [r for r in owned if r.get("group") == ident]
        if not selected:
            raise ValueError("不存在托管规则组")
        for r in sorted(selected, key=lambda r: r["index"], reverse=True):
            delete_at(values, owned, r)
        return
    else:
        if rec is None:
            raise ValueError("未找到唯一托管对象；自定义配置须先显式接管")
        if area in POSITIONAL:
            index = rec["index"]
        else:
            index = values.index(locate(config, area, rec))
        if action == "delete":
            if area in POSITIONAL:
                delete_at(values, owned, rec)
            else:
                values.pop(index)
                owned.remove(rec)
            return
        if action == "move":
            if area not in POSITIONAL:
                raise ValueError("此对象不能调整规则顺序")
            dest = request["position"]
            if not isinstance(dest, int) or dest < 0 or dest >= len(values):
                raise ValueError("移动位置无效")
            value = values.pop(index)
            values.insert(dest, value)
            for r in owned:
                p = r["index"]
                if r is rec:
                    r["index"] = dest
                elif index < p <= dest:
                    r["index"] -= 1
                elif dest <= p < index:
                    r["index"] += 1
            return
        if action != "replace":
            raise ValueError("未知策略操作")
        values[index] = request["value"]
    if area not in POSITIONAL and request["value"].get("tag") != ident:
        raise ValueError("修改时保留原生 tag；变更标识须先迁移引用")
    for field in ("directory", "origin", "group"):
        if field in request:
            rec[field] = request[field]
    # 本次变更暂记输入，native format 后才同步最终 expected。
    rec["expected"] = copy.deepcopy(request["value"])


def adopt(config, registry, request):
    area, ident = request["area"], request["id"]
    owned = records(registry, area)
    found = [r for r in owned if r["id"] == ident]
    if len(found) > 1:
        raise ValueError("登记重复，不能选择一条覆盖")
    if area in POSITIONAL:
        index = request["position"]
        if not isinstance(index, int) or index < 0 or index >= len(array(config, area)):
            raise ValueError("实际规则位置无效")
        if any(r["id"] != ident and r["index"] == index for r in owned):
            raise ValueError("此位置已经关联另一个管理 ID")
        actual = array(config, area)[index]
    else:
        matches = [v for v in array(config, area) if v.get("tag") == ident]
        if len(matches) != 1:
            raise ValueError("配置对象缺失、重复或没有单个 tag")
        actual = matches[0]
        if area == "endpoints" and actual.get("type") not in ("wireguard", "tailscale"):
            raise ValueError("此 endpoint 不在托管范围")
        if area == "connectors" and actual.get("type") != "cloudflared":
            raise ValueError("此 inbound 不是 Cloudflared")
    rec = found[0] if found else {"id": ident}
    rec["expected"] = copy.deepcopy(actual)
    if area in POSITIONAL:
        rec["index"] = index
    if area == "rule_sets":
        # 采用现有路径不授予目录删除权；外部来源可再显式导入为自有版本。
        directory = rec.get("directory", "")
        if not directory or not actual.get("path", "").startswith(directory + "/"):
            rec["directory"] = ""
            rec["origin"] = {"kind": "file", "value": actual["path"], "format": actual.get("format", "binary" if actual["path"].endswith(".srs") else "source")} if actual.get("type") == "local" else {}
    if not found:
        owned.append(rec)
    align(config, registry)


def reset(config, registry, category):
    align(config, registry)
    if category == "nodes":
        owned = {n["inbound_tag"] for n in registry["nodes"]}
        config["inbounds"] = [v for v in config.get("inbounds", []) if v.get("tag") not in owned]
        registry["nodes"] = []
        return
    areas = {"rules_dns": ["route_rules", "dns_rules", "dns_servers", "rule_sets"], "peers": ["endpoints", "connectors"]}[category]
    for area in areas:
        values, owned = array(config, area), records(registry, area)
        if area in POSITIONAL:
            for rec in sorted(list(owned), key=lambda r: r["index"], reverse=True):
                delete_at(values, owned, rec)
        else:
            ids = {r["id"] for r in owned}
            values[:] = [v for v in values if v.get("tag") not in ids]
            owned[:] = []


def delete_at(values, owned, rec):
    index = rec["index"]
    values.pop(index)
    owned.remove(rec)
    for r in owned:
        if r["index"] > index:
            r["index"] -= 1


def tags(value):
    return [value] if isinstance(value, str) else value if isinstance(value, list) else []


def objects(rules):
    for rule in rules:
        yield rule
        if rule.get("type") == "logical":
            yield from objects(rule.get("rules", []))


def resolver_tag(value):
    return value.get("server", "") if isinstance(value, dict) else value or ""


def is_domain(value):
    if not value:
        return False
    try:
        ipaddress.ip_address(value)
        return False
    except ValueError:
        return True


def references(config):
    dns = config.get("dns", {})
    route = config.get("route", {})
    servers = {s.get("tag"): s for s in dns.get("servers", []) if s.get("tag")}
    targets = {v.get("tag"): v for v in config.get("outbounds", []) + config.get("endpoints", []) if v.get("tag")}
    endpoints = {v.get("tag"): v for v in config.get("endpoints", []) if v.get("tag")}
    inbound = {v.get("tag") for v in config.get("inbounds", [])} | set(endpoints)
    sets = {t for v in route.get("rule_set", []) for t in tags(v.get("tag"))}
    clients = {v.get("tag") for v in config.get("http_clients", [])}

    def require(value, available, label):
        for tag in tags(value):
            if tag and tag not in available:
                raise ValueError(f"{label} 仍引用不存在的标识: {tag}")

    require(dns.get("final"), servers, "dns.final")
    require(route.get("final"), targets, "route.final")
    default_resolver = resolver_tag(route.get("default_domain_resolver"))
    require(default_resolver, servers, "默认 domain_resolver")
    require(route.get("default_http_client"), clients, "默认 HTTP client")
    ntp = config.get("ntp", {})
    require(ntp.get("detour"), targets, "NTP detour")
    require(resolver_tag(ntp.get("domain_resolver")), servers, "NTP domain_resolver")
    for section in (route, dns):
        for rule in objects(section.get("rules", [])):
            require(rule.get("inbound"), inbound, "规则 inbound")
            require(rule.get("rule_set"), sets, "规则 rule_set")
            if section is route:
                require(rule.get("preferred_by"), targets, "路由 preferred_by")
                require(rule.get("outbound"), targets, "路由 outbound")
                if rule.get("action") == "resolve":
                    require(rule.get("server"), servers, "路由 resolve server")
            elif rule.get("action", "route") in ("route", "evaluate"):
                require(rule.get("server"), servers, "DNS 规则 server")
            if section is dns:
                require(rule.get("preferred_by"), servers, "DNS preferred_by")

    for value in servers.values():
        if value.get("type") == "tailscale":
            endpoint = value.get("endpoint")
            if endpoint not in endpoints or endpoints[endpoint].get("type") != "tailscale":
                raise ValueError("Tailscale DNS 仍引用不存在或类型错误的 endpoint")

    # 检查向导及导入所使用的原生拨号引用，避免上游域名 bootstrap 自引用。
    graph = {}
    for kind, values in (("dns", servers), ("out", targets)):
        for tag, value in values.items():
            node = kind + ":" + tag
            edges = graph.setdefault(node, set())
            detour = value.get("detour")
            require(detour, targets, "detour")
            if detour:
                edges.add("out:" + detour)
            if kind == "out":
                require(value.get("outbounds"), targets, "出站组成员")
                require(value.get("default"), targets, "出站组默认成员")
                edges.update("out:" + member for member in tags(value.get("outbounds")))
            if kind == "dns" and value.get("type") == "tailscale":
                edges.add("out:" + value["endpoint"])
            resolve = resolver_tag(value.get("domain_resolver"))
            require(resolve, servers, "domain_resolver")
            addresses = [value.get("server")]
            if value.get("type") == "wireguard":
                addresses.extend(peer.get("address") for peer in value.get("peers", []))
            if value.get("type") == "tailscale":
                addresses.append(urlsplit(value.get("control_url") or "https://controlplane.tailscale.com").hostname)
            if any(is_domain(address) for address in addresses) and not detour:
                resolve = resolve or default_resolver or dns.get("final")
                if kind == "dns" and not resolve:
                    raise ValueError("域名 DNS 上游缺少 bootstrap domain_resolver")
                if resolve:
                    edges.add("dns:" + resolve)
    for value in config.get("http_clients", []) + route.get("rule_set", []) + config.get("certificate_providers", []):
        client = value.get("http_client", value)
        if isinstance(client, str):
            require(client, clients, "rule-set HTTP client")
        elif isinstance(client, dict):
            require(client.get("detour"), targets, "HTTP client detour")
            require(resolver_tag(client.get("domain_resolver")), servers, "HTTP client domain_resolver")
    for value in config.get("inbounds", []):
        require(value.get("detour"), inbound, "inbound detour")
        handshake = value.get("tls", {}).get("reality", {}).get("handshake", {})
        require(resolver_tag(handshake.get("domain_resolver")), servers, "Reality handshake domain_resolver")
        require(handshake.get("detour"), targets, "Reality handshake detour")
        for field in ("control_dialer", "tunnel_dialer"):
            dialer = value.get(field, {})
            require(dialer.get("detour"), targets, "Cloudflared " + field)
            require(resolver_tag(dialer.get("domain_resolver")), servers, "Cloudflared " + field)
    visiting, done = set(), set()

    def visit(node):
        if node in visiting:
            raise ValueError("DNS bootstrap 或 detour 存在循环引用")
        if node in done:
            return
        visiting.add(node)
        for child in graph.get(node, ()):
            visit(child)
        visiting.remove(node)
        done.add(node)

    for node in graph:
        visit(node)
    dns_order(dns.get("rules", []))


def dns_order(rules):
    available, untagged, any_evaluated = set(), False, False
    for rule in rules:
        for item in objects([rule]):
            match = item.get("match_response")
            if match is True and not untagged or isinstance(match, str) and match not in available:
                raise ValueError("match_response 缺少前置 evaluate；拒绝破坏规则顺序")
            if item.get("action") == "respond" and not any_evaluated:
                raise ValueError("respond 缺少前置 evaluate")
        if rule.get("action") == "evaluate":
            any_evaluated = True
            if rule.get("tag"):
                if rule["tag"] in available:
                    raise ValueError("evaluate tag 重复")
                available.add(rule["tag"])
            else:
                untagged = True


def main():
    try:
        command, stage = sys.argv[1:3]
        with open(stage + "/config.json", encoding="utf-8") as f:
            config = json.load(f)
        with open(stage + "/registry.json", encoding="utf-8") as f:
            registry = json.load(f)
        if command == "align":
            align(config, registry)
            return 0
        if command == "refs":
            references(config)
            return 0
        if command == "edit":
            edit(config, registry, json.loads(sys.argv[3]))
        elif command == "adopt":
            adopt(config, registry, json.loads(sys.argv[3]))
        elif command == "reset":
            reset(config, registry, sys.argv[3])
        elif command == "sync":
            for area in AREAS:
                for rec in records(registry, area):
                    rec["expected"] = copy.deepcopy(locate(config, area, rec))
        else:
            raise ValueError("未知策略记录操作")
        print(json.dumps({"config": config, "registry": registry}, ensure_ascii=False))
        return 0
    except (OSError, KeyError, TypeError, ValueError, IndexError, AttributeError) as error:
        message = str(error) if type(error) is ValueError and not isinstance(error, json.JSONDecodeError) else type(error).__name__
        print("[错误] 策略关联处理失败: " + message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
