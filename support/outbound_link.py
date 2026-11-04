#!/usr/bin/env python3
"""把第三方分享链接解析成 sing-box 出站对象。"""

import base64
import binascii
import ipaddress
import json
import re
import sys
import uuid as uuidlib
from urllib.parse import unquote_to_bytes, urlsplit


SUPPORTED_TEXT = "Hysteria2/Hy2、AnyTLS、VLESS、VMess、Shadowsocks、SOCKS"
TAG_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}$")
UUID_RE = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
SS_METHODS = {
    "none",
    "aes-128-gcm",
    "aes-192-gcm",
    "aes-256-gcm",
    "chacha20-ietf-poly1305",
    "xchacha20-ietf-poly1305",
    "2022-blake3-aes-128-gcm",
    "2022-blake3-aes-256-gcm",
    "2022-blake3-chacha20-poly1305",
}
VMESS_SECURITY = {
    "auto": "auto",
    "none": "none",
    "zero": "zero",
    "aes-128-cfb": "aes-128-cfb",
    "aes-128-gcm": "aes-128-gcm",
    "chacha20-poly1305": "chacha20-poly1305",
    "chacha20-ietf-poly1305": "chacha20-poly1305",
}
UTLS_FINGERPRINTS = {
    "chrome_psk",
    "chrome_psk_shuffle",
    "chrome_padding_psk_shuffle",
    "chrome_pq",
    "chrome_pq_psk",
    "chrome",
    "firefox",
    "edge",
    "safari",
    "360",
    "qq",
    "ios",
    "android",
    "random",
    "randomized",
}


class LinkError(Exception):
    pass


def fail(message):
    raise LinkError(message)


def empty_value(value):
    return value is None or value == "" or value == [] or value == {}


def decode_component(raw, label, plus=False):
    if raw is None:
        return ""
    if plus:
        raw = raw.replace("+", " ")
    if re.search(r"%(?![0-9A-Fa-f]{2})", raw):
        fail("%s包含无效的百分号编码" % label)
    try:
        text = unquote_to_bytes(raw).decode("utf-8")
    except UnicodeDecodeError:
        fail("%s不是有效 UTF-8" % label)
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in text):
        fail("%s包含控制字符" % label)
    return text


def decode_base64_text(raw, label):
    if not raw:
        fail("%s为空" % label)
    if re.search(r"\s", raw):
        fail("%s包含空白字符" % label)
    normalized = raw.replace("-", "+").replace("_", "/")
    if re.search(r"[^A-Za-z0-9+/=]", normalized):
        fail("%s不是有效 Base64" % label)
    normalized = normalized.rstrip("=")
    if len(normalized) % 4 == 1:
        fail("%s不是有效 Base64" % label)
    normalized += "=" * (-len(normalized) % 4)
    try:
        data = base64.b64decode(normalized, validate=True)
    except (ValueError, binascii.Error):
        fail("%s不是有效 Base64" % label)
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        fail("%s不是有效 UTF-8" % label)


def parse_query(query):
    params = {}
    seen = set()
    if not query:
        return params
    for part in query.split("&"):
        if not part:
            fail("查询字符串包含空参数")
        raw_key, separator, raw_value = part.partition("=")
        if not separator:
            raw_value = ""
        key = decode_component(raw_key, "查询参数名", plus=True).lower()
        if not re.fullmatch(r"[a-z0-9_.-]+", key):
            fail("查询参数名无效")
        if key in seen:
            fail("查询参数重复: %s" % key)
        seen.add(key)
        value = decode_component(raw_value, "查询参数 %s" % key, plus=True)
        if not empty_value(value):
            params[key] = value
    return params


def reject_unknown(params, allowed):
    unknown = sorted(
        name for name in set(params) - set(allowed) if not empty_value(params[name])
    )
    if unknown:
        fail("链接包含暂不支持的查询参数: %s" % ", ".join(unknown))


def split_url(link):
    try:
        return urlsplit(link)
    except ValueError:
        fail("分享链接 URL 格式无效")


def validate_host(value, label="服务器地址"):
    if not value:
        fail("%s不能为空" % label)
    if any(char in value for char in "\t\r\n /?#@[]"):
        fail("%s格式无效" % label)
    try:
        ipaddress.ip_address(value)
        return value
    except ValueError:
        pass
    if re.fullmatch(r"[0-9.]+", value):
        fail("%s不是有效 IP 地址" % label)
    name = value[:-1] if value.endswith(".") else value
    if not name or len(name) > 253:
        fail("%s格式无效" % label)
    for part in name.split("."):
        if not part or len(part) > 63:
            fail("%s格式无效" % label)
        try:
            encoded = part.encode("idna").decode("ascii")
        except UnicodeError:
            fail("%s格式无效" % label)
        if not re.fullmatch(
            r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", encoded
        ):
            fail("%s格式无效" % label)
    return value


def endpoint(url):
    host = url.hostname
    if not host:
        fail("链接缺少服务器地址")
    validate_host(host)
    try:
        port = url.port
    except ValueError:
        fail("链接端口无效")
    if port is None:
        fail("链接缺少服务器端口")
    if not 1 <= port <= 65535:
        fail("链接端口须在 1-65535")
    return host, port


def userinfo_password(url, label):
    if url.username is None:
        fail("%s链接缺少认证密码" % label)
    password = decode_component(url.username, "%s认证信息" % label)
    if url.password is not None:
        password += ":" + decode_component(url.password, "%s认证信息" % label)
    if not password:
        fail("%s链接认证密码不能为空" % label)
    return password


def uuid_value(value):
    if not UUID_RE.fullmatch(value or ""):
        fail("UUID 格式无效")
    return str(uuidlib.UUID(value))


def bool_param(params, names, label, default=None):
    present = [(name, params[name]) for name in names if name in params]
    if not present:
        return default
    values = {value.strip().lower() for _, value in present}
    if len(values) > 1:
        fail("%s参数冲突" % label)
    value = values.pop()
    if value in ("", "1", "true", "yes", "on"):
        return True
    if value in ("0", "false", "no", "off"):
        return False
    fail("%s只能为 0/1/true/false" % label)


def int_param(params, names, label, minimum=1, maximum=999999999):
    present = [(name, params[name].strip()) for name in names if name in params]
    if not present:
        return None
    values = {value for _, value in present}
    if len(values) > 1:
        fail("%s参数冲突" % label)
    value = values.pop()
    if not re.fullmatch(r"[0-9]{1,9}", value):
        fail("%s必须是十进制整数" % label)
    number = int(value, 10)
    if not minimum <= number <= maximum:
        fail("%s须在 %s-%s" % (label, minimum, maximum))
    return number


def choose_sni(params, host, required=False):
    present = [
        params[name]
        for name in ("sni", "peer", "servername")
        if name in params and params[name]
    ]
    if present:
        if len(set(present)) > 1:
            fail("sni/peer/servername 不一致")
        value = present[0]
        validate_host(value, "SNI")
        return value
    if required:
        fail("链接缺少 SNI")
    return host


def alpn_value(params):
    if "alpn" not in params:
        return None
    values = [value.strip() for value in params["alpn"].split(",") if value.strip()]
    if not values:
        fail("alpn 不能为空")
    for value in values:
        if "," in value or any(ord(char) < 0x21 or ord(char) > 0x7E for char in value):
            fail("alpn 格式无效")
    return values


def utls_value(params, default=None):
    if "fp" not in params:
        if default is None:
            return None
        fingerprint = default
    else:
        fingerprint = params["fp"].strip().lower()
        if not fingerprint:
            fail("fp 不能为空")
    if fingerprint not in UTLS_FINGERPRINTS:
        fail("不支持的 uTLS 指纹: %s" % fingerprint)
    return {"enabled": True, "fingerprint": fingerprint}


def reality_value(params):
    public_key = params.get("pbk", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", public_key):
        fail("Reality 公钥 pbk 格式无效")
    short_id = params.get("sid", "")
    if not re.fullmatch(r"[0-9A-Fa-f]{0,16}", short_id) or len(short_id) % 2:
        fail("Reality short_id sid 必须是不超过 16 位的偶数长度十六进制")
    return {
        "enabled": True,
        "public_key": public_key,
        "short_id": short_id,
    }


def port_ranges(value):
    if not value:
        fail("mport 不能为空")
    result = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            fail("mport 包含空范围")
        if item.count("-") == 1:
            left, right = item.split("-", 1)
        elif item.count(":") == 1:
            left, right = item.split(":", 1)
        elif "-" not in item and ":" not in item:
            left = right = item
        else:
            fail("mport 范围格式无效")
        left = left.strip()
        right = right.strip()
        if not re.fullmatch(r"[0-9]{1,5}", left) or not re.fullmatch(
            r"[0-9]{1,5}", right
        ):
            fail("mport 端口必须是十进制整数")
        start, end = int(left, 10), int(right, 10)
        if not 1 <= start <= 65535 or not 1 <= end <= 65535:
            fail("mport 端口须在 1-65535")
        if start > end:
            start, end = end, start
        result.append("%d:%d" % (start, end))
    return result


def tag_value(fragment=None, fallback=None):
    value = fragment if fragment not in (None, "") else fallback
    if value in (None, ""):
        return None
    value = decode_component(value, "tag")
    if value == "direct" or not TAG_RE.fullmatch(value):
        return None
    return value


def transport_value(kind, params, server, sni):
    if kind == "tcp":
        if any(name in params for name in ("host", "path", "servicename")):
            fail("TCP 传输未启用 WebSocket，却包含 host/path/serviceName")
        return None
    if kind == "ws":
        if "servicename" in params:
            fail("WebSocket 传输不支持 serviceName")
        path = params.get("path", "/")
        if not path:
            path = "/"
        if not path.startswith("/"):
            path = "/" + path
        host = params.get("host") or sni or server
        validate_host(host, "WebSocket Host")
        return {"type": "ws", "path": path, "headers": {"Host": host}}
    if kind == "grpc":
        fail("暂不支持 gRPC 传输")
    fail("不支持的传输类型: %s" % kind)


def packet_encoding_value(params):
    if "packetencoding" not in params:
        return None
    value = params["packetencoding"].strip().lower()
    if value not in ("packetaddr", "xudp"):
        fail("packetEncoding 只能是 packetaddr 或 xudp")
    return value


def parse_hysteria2(link):
    url = split_url(link)
    host, port = endpoint(url)
    password = userinfo_password(url, "Hysteria2 ")
    params = parse_query(url.query)
    reject_unknown(
        params,
        {
            "sni",
            "peer",
            "servername",
            "insecure",
            "allowinsecure",
            "obfs",
            "obfs-password",
            "minpacketsize",
            "maxpacketsize",
            "mport",
            "alpn",
            "up",
            "down",
            "upmbps",
            "downmbps",
            "pinsha256",
            "ech",
            "fp",
        },
    )
    if params.get("pinsha256"):
        fail(
            "链接包含 pinSHA256（整证书 SHA-256）；sing-box 1.14.4 "
            "只支持公钥 pin，不能无损导入"
        )
    if "ech" in params:
        fail("链接包含 ECH 参数；当前模板没有完整 ECH 配置，不能无损导入")
    if "fp" in params:
        fail("Hysteria2 是 QUIC 出站，不能把 fp 当作 uTLS 指纹无损导入")

    sni = choose_sni(params, host)
    tls = {"enabled": True, "server_name": sni}
    if bool_param(params, ("insecure", "allowinsecure"), "insecure", False):
        tls["insecure"] = True
    alpn = alpn_value(params)
    if alpn:
        tls["alpn"] = alpn

    outbound = {
        "type": "hysteria2",
        "server": host,
        "server_port": port,
        "password": password,
        "tls": tls,
    }
    if "mport" in params:
        outbound["server_ports"] = port_ranges(params["mport"])

    if "obfs" in params:
        kind = params["obfs"].strip().lower()
        if kind not in ("salamander", "gecko"):
            fail("Hysteria2 混淆只支持 salamander 或 gecko")
        obfs_password = params.get("obfs-password", "")
        if not obfs_password:
            fail("Hysteria2 启用混淆时必须提供 obfs-password")
        obfs = {"type": kind, "password": obfs_password}
        low = int_param(
            params, ("minpacketsize",), "Gecko 最小包长", 1, 65535
        )
        high = int_param(
            params, ("maxpacketsize",), "Gecko 最大包长", 1, 65535
        )
        if kind == "gecko":
            if low is not None or high is not None:
                low = 512 if low is None else low
                high = 1200 if high is None else high
                if low > high:
                    fail("Gecko 最小包长不能大于最大包长")
                obfs["min_packet_size"] = low
                obfs["max_packet_size"] = high
        elif low is not None or high is not None:
            fail("minPacketSize/maxPacketSize 只适用于 Gecko 混淆")
        outbound["obfs"] = obfs
    elif any(
        name in params for name in ("obfs-password", "minpacketsize", "maxpacketsize")
    ):
        fail("链接包含混淆参数，但没有提供 obfs 类型")

    up = int_param(params, ("up", "upmbps"), "上行带宽")
    down = int_param(params, ("down", "downmbps"), "下行带宽")
    if (up is None) != (down is None):
        fail("Hysteria2 的 up/down 必须同时提供")
    if up is not None:
        outbound["up_mbps"] = up
        outbound["down_mbps"] = down

    return (
        tag_value(url.fragment),
        outbound,
        {"protocol": "hysteria2", "server": host, "port": port},
    )


def parse_anytls(link):
    url = split_url(link)
    host, port = endpoint(url)
    password = userinfo_password(url, "AnyTLS ")
    params = parse_query(url.query)
    reject_unknown(
        params,
        {
            "sni",
            "peer",
            "servername",
            "insecure",
            "allowinsecure",
            "security",
            "pbk",
            "sid",
            "fp",
            "alpn",
            "pcs",
        },
    )
    if params.get("pcs"):
        fail(
            "链接包含 pcs（整证书 SHA-256）；sing-box 1.14.4 "
            "只支持公钥 pin，不能无损导入"
        )
    security = params.get("security", "tls").strip().lower()
    if security not in ("", "tls", "reality"):
        fail("AnyTLS security 只支持 tls 或 reality")
    reality = security == "reality"
    sni = choose_sni(params, host, required=reality)
    tls = {"enabled": True, "server_name": sni}
    if reality:
        if bool_param(
            params, ("insecure", "allowinsecure"), "insecure", False
        ):
            fail("Reality 不能同时启用 insecure")
        if "pbk" not in params:
            fail("Reality 链接缺少公钥 pbk")
        tls["reality"] = reality_value(params)
        tls["utls"] = utls_value(params, default="chrome")
    else:
        if "pbk" in params or "sid" in params:
            fail("未使用 Reality 却包含 pbk/sid")
        if bool_param(
            params, ("insecure", "allowinsecure"), "insecure", False
        ):
            tls["insecure"] = True
        utls = utls_value(params)
        if utls:
            tls["utls"] = utls
    alpn = alpn_value(params)
    if alpn:
        tls["alpn"] = alpn
    outbound = {
        "type": "anytls",
        "server": host,
        "server_port": port,
        "password": password,
        "tls": tls,
    }
    return (
        tag_value(url.fragment),
        outbound,
        {"protocol": "anytls", "server": host, "port": port},
    )


def parse_vless(link):
    url = split_url(link)
    host, port = endpoint(url)
    if url.username is None:
        fail("VLESS 链接缺少 UUID")
    if url.password is not None:
        fail("VLESS 链接的 UUID 后不能带密码")
    uuid = uuid_value(decode_component(url.username, "VLESS UUID"))
    params = parse_query(url.query)
    if "servicename" in params or "mode" in params:
        fail("VLESS 链接包含 gRPC 传输参数；暂不支持 gRPC")
    reject_unknown(
        params,
        {
            "encryption",
            "flow",
            "security",
            "sni",
            "peer",
            "servername",
            "pbk",
            "sid",
            "fp",
            "type",
            "headertype",
            "host",
            "path",
            "alpn",
            "insecure",
            "allowinsecure",
            "packetencoding",
            "ed",
            "earlydataheadername",
        },
    )
    encryption = params.get("encryption", "").strip().lower()
    if encryption not in ("", "none"):
        fail("VLESS encryption 必须为空或 none")
    security = params.get("security", "").strip().lower()
    if security not in ("", "none", "tls", "reality"):
        fail("VLESS security 只支持 none、tls 或 reality")
    if security == "":
        security = "none"
    kind = params.get("type", "").strip().lower()
    if kind in ("", "tcp", "raw"):
        kind = "tcp"
    elif kind == "grpc":
        fail("暂不支持 gRPC 传输")
    elif kind != "ws":
        fail("VLESS 只支持 TCP 或 WebSocket 传输")
    header_type = params.get("headertype", "").strip().lower()
    if header_type not in ("", "none"):
        fail("VLESS 不支持 headerType 伪装")
    if "ed" in params or "earlydataheadername" in params:
        fail("VLESS 链接包含暂不支持的 early data 参数")

    tls_params = {
        name
        for name in (
            "sni",
            "peer",
            "servername",
            "pbk",
            "sid",
            "fp",
            "alpn",
            "insecure",
            "allowinsecure",
        )
        if name in params
    }
    if security == "none" and tls_params:
        fail("VLESS 未启用 TLS/Reality，却包含 TLS 参数")
    flow = params.get("flow", "").strip()
    if flow:
        if security != "reality":
            fail("VLESS flow 只在 Reality 配置档中支持")
        if flow != "xtls-rprx-vision":
            fail("VLESS Reality flow 必须是 xtls-rprx-vision")
        if kind != "tcp":
            fail("VLESS flow 只支持原生 TCP 传输")

    outbound = {
        "type": "vless",
        "server": host,
        "server_port": port,
        "uuid": uuid,
    }
    sni = host
    tls = None
    if security == "reality":
        sni = choose_sni(params, host, required=True)
        if "pbk" not in params:
            fail("VLESS Reality 链接缺少公钥 pbk")
        if bool_param(params, ("insecure", "allowinsecure"), "insecure", False):
            fail("VLESS Reality 不能同时启用 insecure")
        tls = {
            "enabled": True,
            "server_name": sni,
            "reality": reality_value(params),
            "utls": utls_value(params, default="chrome"),
        }
    elif security == "tls":
        sni = choose_sni(params, host)
        tls = {"enabled": True, "server_name": sni}
        if bool_param(params, ("insecure", "allowinsecure"), "insecure", False):
            tls["insecure"] = True
        utls = utls_value(params)
        if utls:
            tls["utls"] = utls
    if tls is not None:
        alpn = alpn_value(params)
        if alpn:
            tls["alpn"] = alpn
        outbound["tls"] = tls
    transport = transport_value(kind, params, host, sni)
    if transport:
        outbound["transport"] = transport
    if flow:
        outbound["flow"] = flow
    packet_encoding = packet_encoding_value(params)
    if packet_encoding:
        outbound["packet_encoding"] = packet_encoding
    return (
        tag_value(url.fragment),
        outbound,
        {"protocol": "vless", "server": host, "port": port},
    )


def vmess_security_value(params, value, label="VMess security"):
    value = (value or "").strip().lower()
    if not value:
        return "auto"
    if value not in VMESS_SECURITY:
        fail("%s只能是 auto/none/zero/aes-128-gcm 等受支持值" % label)
    return VMESS_SECURITY[value]


def vmess_build(
    host,
    port,
    uuid,
    security,
    tls_mode,
    kind,
    params,
    header_type,
):
    if header_type not in ("", "none"):
        fail("VMess 不支持 headerType 伪装")
    if kind == "tcp" and header_type not in ("", "none"):
        fail("VMess TCP 不支持额外头部伪装")
    outbound = {
        "type": "vmess",
        "server": host,
        "server_port": port,
        "uuid": uuid,
        "security": security,
        "alter_id": 0,
    }
    sni = host
    if tls_mode == "tls":
        sni = choose_sni(params, host)
        tls = {"enabled": True, "server_name": sni}
        if bool_param(params, ("insecure", "allowinsecure"), "insecure", False):
            tls["insecure"] = True
        alpn = alpn_value(params)
        if alpn:
            tls["alpn"] = alpn
        utls = utls_value(params)
        if utls:
            tls["utls"] = utls
        outbound["tls"] = tls
    elif tls_mode not in ("", "none"):
        fail("VMess 只支持 TLS 或明文传输")
    transport = transport_value(kind, params, host, sni)
    if transport:
        outbound["transport"] = transport
    packet_encoding = packet_encoding_value(params)
    if packet_encoding:
        outbound["packet_encoding"] = packet_encoding
    return outbound


def parse_vmess_legacy(raw, fragment):
    text = decode_base64_text(raw, "VMess 链接")
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        fail("VMess Base64 内容不是有效 JSON")
    if not isinstance(data, dict):
        fail("VMess Base64 内容必须是 JSON 对象")
    if (
        str(data.get("net", "")).strip().lower() == "grpc"
        or str(data.get("type", "")).strip().lower() == "gun"
        or not empty_value(data.get("mode"))
    ):
        fail("VMess 暂不支持 gRPC 传输")
    allowed = {
        "v",
        "ps",
        "add",
        "port",
        "id",
        "aid",
        "scy",
        "net",
        "type",
        "host",
        "path",
        "tls",
        "sni",
        "alpn",
        "fp",
        "insecure",
        "allowinsecure",
        "skip-cert-verify",
        "packetencoding",
    }
    unknown = sorted(
        name for name in set(data) - allowed if not empty_value(data[name])
    )
    if unknown:
        fail("VMess JSON 包含暂不支持的字段: %s" % ", ".join(unknown))
    host = data.get("add")
    if not isinstance(host, str):
        fail("VMess JSON 缺少服务器地址 add")
    validate_host(host)
    port = int_param(
        {"port": str(data.get("port", ""))}, ("port",), "VMess 端口", 1, 65535
    )
    if port is None:
        fail("VMess JSON 缺少端口 port")
    uuid = uuid_value(str(data.get("id", "")))
    aid = int_param(
        {"aid": str(data.get("aid", 0) or 0)}, ("aid",), "VMess alterId", 0, 999999
    )
    if aid not in (0, None):
        fail("VMess 只支持 AEAD，alterId 必须为 0")
    security = vmess_security_value({}, data.get("scy", "auto"))
    tls_raw = data.get("tls", "")
    if isinstance(tls_raw, bool):
        tls_mode = "tls" if tls_raw else "none"
    else:
        tls_mode = str(tls_raw or "").strip().lower()
    if tls_mode in ("", "none"):
        tls_mode = "none"
    elif tls_mode != "tls":
        fail("VMess JSON 只支持 tls 或明文")
    kind = str(data.get("net", "tcp") or "tcp").strip().lower()
    if kind in ("", "tcp", "raw"):
        kind = "tcp"
    elif kind == "grpc":
        fail("VMess 暂不支持 gRPC 传输")
    elif kind != "ws":
        fail("VMess 只支持 TCP 或 WebSocket 传输")
    header_type = str(data.get("type", "none") or "none").strip().lower()
    params = {}
    for key in ("host", "path", "sni", "alpn", "fp"):
        value = data.get(key)
        if value not in (None, ""):
            params[key] = str(value)
    insecure = None
    for name in ("insecure", "allowinsecure", "skip-cert-verify"):
        if name in data and not empty_value(data[name]):
            insecure = data[name]
            break
    if insecure is not None:
        params["insecure"] = "1" if insecure in (True, 1, "1", "true") else "0"
    if data.get("packetencoding"):
        params["packetencoding"] = str(data["packetencoding"])
    outbound = vmess_build(
        host,
        port,
        uuid,
        security,
        tls_mode,
        kind,
        params,
        header_type,
    )
    return (
        tag_value(fragment, data.get("ps")),
        outbound,
        {"protocol": "vmess", "server": host, "port": port},
    )


def parse_vmess(link):
    raw = link[len("vmess://") :]
    if "@" not in raw.split("#", 1)[0].split("?", 1)[0]:
        body, _, fragment = raw.partition("#")
        if "?" in body:
            fail("VMess Base64 链接不能包含查询字符串")
        return parse_vmess_legacy(body, fragment)

    url = split_url(link)
    host, port = endpoint(url)
    if url.username is None:
        fail("VMess 链接缺少 UUID")
    if url.password is not None:
        fail("VMess 链接的 UUID 后不能带密码")
    uuid = uuid_value(decode_component(url.username, "VMess UUID"))
    params = parse_query(url.query)
    if "servicename" in params or "mode" in params:
        fail("VMess 链接包含 gRPC 传输参数；暂不支持 gRPC")
    reject_unknown(
        params,
        {
            "type",
            "security",
            "scy",
            "encryption",
            "host",
            "path",
            "sni",
            "peer",
            "servername",
            "fp",
            "alpn",
            "insecure",
            "allowinsecure",
            "aid",
            "alterid",
            "packetencoding",
            "headertype",
            "flow",
        },
    )
    if "flow" in params:
        fail("VMess 链接包含暂不支持的 flow 参数")
    kind = params.get("type", "").strip().lower()
    if kind in ("", "tcp", "raw"):
        kind = "tcp"
    elif kind == "grpc":
        fail("暂不支持 gRPC 传输")
    elif kind != "ws":
        fail("VMess 只支持 TCP 或 WebSocket 传输")
    header_type = params.get("headertype", "").strip().lower()
    if header_type not in ("", "none"):
        fail("VMess 不支持 headerType 伪装")
    aid_value = int_param(
        params, ("aid", "alterid"), "VMess alterId", 0, 999999
    )
    if aid_value not in (0, None):
        fail("VMess 只支持 AEAD，alterId 必须为 0")
    security_raw = params.get("security", "").strip().lower()
    tls_mode = "none"
    security_input = ""
    if security_raw in ("tls", "reality"):
        if security_raw == "reality":
            fail("VMess 不支持 Reality")
        tls_mode = "tls"
    elif security_raw in ("", "none"):
        tls_mode = "none"
    else:
        security_input = security_raw
    if "scy" in params:
        if security_input:
            fail("VMess security 与 scy 重复")
        security_input = params["scy"]
    if "encryption" in params:
        if security_input:
            fail("VMess encryption 与 scy 重复")
        security_input = params["encryption"]
    security = vmess_security_value(params, security_input)
    outbound = vmess_build(
        host,
        port,
        uuid,
        security,
        tls_mode,
        kind,
        params,
        header_type,
    )
    return (
        tag_value(url.fragment),
        outbound,
        {"protocol": "vmess", "server": host, "port": port},
    )


def ss_password_value(method, password):
    if not password:
        fail("Shadowsocks 密码不能为空")
    if method not in ("2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"):
        return password
    expected = 16 if method == "2022-blake3-aes-128-gcm" else 32
    parts = password.split(":")
    if len(parts) > 2:
        fail("Shadowsocks 2022 密钥只能包含一个服务端:用户分隔冒号")
    for part in parts:
        if len(part) != ((22 if expected == 16 else 43) + (2 if expected == 16 else 1)):
            fail("Shadowsocks 2022 密钥长度与算法不匹配")
        try:
            decoded = base64.b64decode(part, validate=True)
        except (ValueError, binascii.Error):
            fail("Shadowsocks 2022 密钥必须是标准 Base64")
        if len(decoded) != expected:
            fail("Shadowsocks 2022 密钥长度与算法不匹配")
    return password


def parse_ss(link):
    raw = link[len("ss://") :]
    body, separator, fragment = raw.partition("#")
    if not separator:
        fragment = ""
    body, separator, query = body.partition("?")
    if query:
        params = parse_query(query)
        reject_unknown(params, set())
    if not body:
        fail("Shadowsocks 链接为空")

    if "@" in body:
        userinfo, endpoint_text = body.rsplit("@", 1)
        userinfo = decode_component(userinfo, "Shadowsocks 凭据")
        if ":" in userinfo:
            method_password = userinfo
        else:
            method_password = decode_base64_text(
                userinfo, "Shadowsocks 凭据"
            )
    else:
        decoded = decode_base64_text(body, "Shadowsocks 链接")
        if "@" not in decoded:
            fail("Shadowsocks 整串 Base64 内容缺少服务器地址")
        method_password, endpoint_text = decoded.rsplit("@", 1)
    if ":" not in method_password:
        fail("Shadowsocks 链接缺少加密方法或密码")
    method, password = method_password.split(":", 1)
    method = method.strip().lower()
    if method not in SS_METHODS:
        fail("Shadowsocks 加密方法不在 sing-box 1.14.4 支持范围内: %s" % method)
    password = ss_password_value(method, password)

    endpoint_text = endpoint_text.strip()
    if not endpoint_text or "/" in endpoint_text:
        fail("Shadowsocks 服务器地址格式无效")
    url = split_url("//" + endpoint_text)
    if url.path or url.query or url.fragment:
        fail("Shadowsocks 服务器地址格式无效")
    host, port = endpoint(url)
    outbound = {
        "type": "shadowsocks",
        "server": host,
        "server_port": port,
        "method": method,
        "password": password,
    }
    return (
        tag_value(fragment),
        outbound,
        {"protocol": "shadowsocks", "server": host, "port": port},
    )


def parse_socks(link):
    url = split_url(link)
    host, port = endpoint(url)
    params = parse_query(url.query)
    reject_unknown(params, set())
    if url.path not in ("", "/"):
        fail("SOCKS 链接不能包含路径")
    outbound = {
        "type": "socks",
        "server": host,
        "server_port": port,
        "version": "5",
    }
    if url.username is not None:
        username = decode_component(url.username, "SOCKS 用户名")
        if not username:
            fail("SOCKS 用户名不能为空")
        if url.password is None:
            fail("SOCKS 认证缺少密码")
        password = decode_component(url.password, "SOCKS 密码")
        if not password:
            fail("SOCKS 密码不能为空")
        outbound["username"] = username
        outbound["password"] = password
    return (
        tag_value(url.fragment),
        outbound,
        {"protocol": "socks", "server": host, "port": port},
    )


def parse(link):
    if not link:
        fail("分享链接不能为空")
    if link.startswith("\ufeff"):
        link = link[1:]
    if "\r" in link or "\n" in link:
        fail("分享链接不能包含换行符")
    if link.startswith("hysteria2://") or link.startswith("hy2://"):
        return parse_hysteria2(link)
    if link.startswith("anytls://"):
        return parse_anytls(link)
    if link.startswith("vless://"):
        return parse_vless(link)
    if link.startswith("vmess://"):
        return parse_vmess(link)
    if link.startswith("ss://"):
        return parse_ss(link)
    if link.startswith("socks://") or link.startswith("socks5://"):
        return parse_socks(link)
    scheme = link.split("://", 1)[0].lower() if "://" in link else ""
    if scheme in {
        "tuic",
        "hysteria",
        "trojan",
        "http",
        "https",
        "shadowtls",
        "naive+https",
    }:
        fail("暂不支持 %s:// 链接；当前支持 %s" % (scheme, SUPPORTED_TEXT))
    fail("无法识别分享链接协议；当前支持 %s" % SUPPORTED_TEXT)


def main():
    try:
        data = sys.stdin.read()
        if data.endswith("\n"):
            data = data[:-1]
        if "\n" in data or "\r" in data:
            fail("一次只能输入一条分享链接")
        tag, outbound, summary = parse(data)
        result = {
            "tag": tag,
            "protocol": summary["protocol"],
            "server": summary["server"],
            "port": summary["port"],
            "outbound": outbound,
        }
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0
    except LinkError as exc:
        print("链接解析失败: %s" % exc, file=sys.stderr)
        return 1
    except Exception:
        print("链接解析失败: 解析器内部错误", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
