#!/usr/bin/env python3
"""把 WARP 注册响应转换为原生 sing-box endpoint。"""

import base64
import binascii
import ipaddress
import json
import re
import sys


DEFAULT_PORT = 2408
DEFAULT_MTU = 1280
DEFAULT_ALLOWED_IPS = ["0.0.0.0/0", "::/0"]


class InvalidResponse(ValueError):
    pass


def _wireguard_endpoint(data):
    if not isinstance(data, dict):
        return None
    # 注册接口可能把 endpoints 放在顶层、config 或 data 下，逐个容器查找。
    containers = [data]
    for key in ("config", "data"):
        child = data.get(key)
        if isinstance(child, dict):
            containers.append(child)
    for container in containers:
        endpoints = container.get("endpoints")
        if not isinstance(endpoints, list):
            continue
        for endpoint in endpoints:
            if (
                isinstance(endpoint, dict)
                and endpoint.get("type") == "wireguard"
                and isinstance(endpoint.get("private_key"), str)
            ):
                return endpoint
    return None


def _key(value, field):
    if not isinstance(value, str) or not value:
        raise InvalidResponse(field + " is missing")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise InvalidResponse(field + " is not valid Base64")
    if len(decoded) != 32:
        raise InvalidResponse(field + " must decode to 32 bytes")
    return value


def _string_list(value, field):
    if isinstance(value, str):
        values = [value]
    elif isinstance(value, list):
        values = value
    else:
        raise InvalidResponse(field + " must be a string or array")
    if not values or any(not isinstance(item, str) or not item for item in values):
        raise InvalidResponse(field + " contains an invalid value")
    return values


def _addresses(value):
    addresses = []
    for item in _string_list(value, "address"):
        try:
            addresses.append(str(ipaddress.ip_interface(item)))
        except ValueError:
            raise InvalidResponse("address contains an invalid interface")
    return addresses


def _allowed_ips(value):
    if value is None:
        return list(DEFAULT_ALLOWED_IPS)
    if isinstance(value, list) and not value:
        return list(DEFAULT_ALLOWED_IPS)
    networks = []
    for item in _string_list(value, "allowedIPs"):
        try:
            networks.append(str(ipaddress.ip_network(item, strict=False)))
        except ValueError:
            raise InvalidResponse("allowedIPs contains an invalid network")
    return networks


def _reserved(value):
    if value is None:
        return [0, 0, 0]
    if not isinstance(value, list) or len(value) != 3:
        raise InvalidResponse("reserved must contain three bytes")
    if any(type(item) is not int or item < 0 or item > 255 for item in value):
        raise InvalidResponse("reserved contains an invalid byte")
    return value


def _mtu(value):
    if value is None:
        return DEFAULT_MTU
    if type(value) is not int or value < 1 or value > 65535:
        raise InvalidResponse("mtu is invalid")
    return value


def _port(value):
    if value is None or value == "":
        return DEFAULT_PORT
    if isinstance(value, str) and value.isdigit():
        value = int(value)
    if type(value) is not int or value < 0 or value > 65535:
        raise InvalidResponse("endpoint port is invalid")
    return value or DEFAULT_PORT


def _valid_host(host):
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        pass
    if len(host) > 253:
        return False
    labels = host.split(".")
    return all(
        re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
        for label in labels
    )


def _endpoint(value, explicit_port=None):
    if not isinstance(value, str) or not value.strip():
        raise InvalidResponse("endpoint is missing")
    endpoint = value.strip()
    host = ""
    port = None

    if endpoint.startswith("["):
        match = re.fullmatch(r"\[([^\]]+)\](?::([^:]+))?", endpoint)
        if not match:
            raise InvalidResponse("endpoint is invalid")
        host, port = match.group(1), match.group(2)
    elif endpoint.count(":") == 1:
        candidate, suffix = endpoint.rsplit(":", 1)
        if suffix.isdigit() or suffix == "":
            host, port = candidate, suffix
        else:
            host = endpoint
    else:
        host = endpoint

    if not host or not _valid_host(host):
        raise InvalidResponse("endpoint host is invalid")
    return host, _port(explicit_port if explicit_port is not None else port)


def normalize(data):
    endpoint = _wireguard_endpoint(data)
    if endpoint is None:
        raise InvalidResponse("WireGuard endpoint is missing")

    peers = endpoint.get("peers")
    if not isinstance(peers, list) or not peers or not isinstance(peers[0], dict):
        raise InvalidResponse("WireGuard peer is missing")
    peer = peers[0]
    host, port = _endpoint(peer.get("address"), peer.get("port"))

    return {
        "type": "wireguard",
        "tag": "warp",
        "system": False,
        "address": _addresses(endpoint.get("address")),
        "private_key": _key(endpoint.get("private_key"), "private_key"),
        "mtu": _mtu(endpoint.get("mtu")),
        "listen_port": 0,
        "peers": [
            {
                "address": host,
                "port": port,
                "public_key": _key(peer.get("public_key"), "public_key"),
                "allowed_ips": _allowed_ips(peer.get("allowed_ips")),
                "reserved": _reserved(peer.get("reserved")),
            }
        ],
    }


def main():
    if len(sys.argv) != 3 or sys.argv[1] != "normalize":
        raise SystemExit(2)
    try:
        with open(sys.argv[2], encoding="utf-8") as source:
            data = json.load(source)
        endpoint = normalize(data)
    except (OSError, json.JSONDecodeError, InvalidResponse):
        print("invalid WARP registration response", file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps(endpoint, ensure_ascii=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
