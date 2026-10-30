#!/usr/bin/env bash
# 路径上下文由其他生产模块和隔离测试消费。
# shellcheck disable=SC2034

sbd_paths() {
    local root="$1"
    SBD_ROOT=$(cd -- "$root" && pwd -P) || { _error "部署目录不存在: $root"; return 1; }
    [[ "$SBD_ROOT" != / ]] || { _error '不能使用文件系统根作为部署目录'; return 1; }
    SBD_APP="$SBD_ROOT/app"
    SBD_ENGINE="$SBD_ROOT/engine"
    SBD_BINARY="$SBD_ENGINE/sing-box"
    SBD_CONFIG_DIR="$SBD_ROOT/config"
    SBD_CONFIG="$SBD_CONFIG_DIR/config.json"
    SBD_SCHEMA="$SBD_CONFIG_DIR/schema.json"
    SBD_DATA="$SBD_ROOT/data"
    SBD_STATE="$SBD_DATA/state.json"
    SBD_REGISTRY="$SBD_DATA/registry.json"
    SBD_EXPORTS="$SBD_ROOT/exports"
    SBD_WORK="$SBD_ROOT/work"
    SBD_LOCK="${2:-/run/lock/singbox-deploy.lock}"
    SBD_COMMAND="${3:-/usr/local/bin/sd}"
    SBD_SERVICE=singbox-deploy
    SBD_LOG="$SBD_DATA/sing-box.log"
    [[ "$SBD_LOCK" = /* ]] || { _error '写锁必须使用绝对路径'; return 1; }
}

sbd_directories() {
    local path
    for path in "$SBD_ROOT/engine" "$SBD_CONFIG_DIR" "$SBD_DATA" "$SBD_EXPORTS" "$SBD_WORK"; do
        if ! mkdir -p -- "$path" || ! chmod 700 -- "$path"; then
            _error "无法准备目录: $path"; return 1
        fi
    done
}

sbd_os() (
    local file="${1:-/etc/os-release}"
    [[ -r "$file" ]] || { _error '无法读取 os-release'; return 1; }
    unset ID
    . "$file" || { _error '无法解析 os-release'; return 1; }
    case "${ID:-}" in
        debian|ubuntu) printf 'debian\n' ;;
        alpine) printf 'alpine\n' ;;
        *) _error "不支持的系统: ${ID:-未知}"; return 1 ;;
    esac
)

sbd_system_label() (
    local file="${1:-/etc/os-release}"
    [[ -r "$file" ]] || { _error '无法读取系统名称'; return 1; }
    unset PRETTY_NAME
    . "$file" || { _error '无法解析系统名称'; return 1; }
    [[ -n "${PRETTY_NAME:-}" ]] || { _error 'os-release 缺少 PRETTY_NAME'; return 1; }
    printf '%s\n' "$PRETTY_NAME"
)

sbd_arch() {
    case "${1:-$(uname -m)}" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) _error '仅支持 amd64/arm64'; return 1 ;;
    esac
}

sbd_dependencies() {
    local tool
    (( BASH_VERSINFO[0] >= 5 )) || { _error '需要 Bash 5 或更新版本'; return 1; }
    for tool in jq python3 flock tar cmp mktemp readlink openssl; do
        command -v "$tool" >/dev/null 2>&1 || { _error "缺少依赖: $tool"; return 1; }
    done
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        _error '缺少 curl/wget 下载客户端'; return 1
    fi
    if ! python3 -c 'from jsonschema import Draft202012Validator' >/dev/null 2>&1; then
        _error 'Python jsonschema 必须提供 Draft202012Validator，不能降级为仅运行 check'
        return 1
    fi
}

sbd_packages() {
    local family
    family=$(sbd_os) || return 1
    case "$family" in
        debian)
            apt-get update || { _error 'apt 索引更新失败'; return 1; }
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                bash curl jq python3 python3-jsonschema util-linux tar openssl || { _error '依赖安装失败'; return 1; }
            ;;
        alpine)
            apk add --no-cache bash curl jq python3 py3-jsonschema util-linux tar openssl || { _error '依赖安装失败'; return 1; }
            ;;
    esac
    sbd_dependencies
}

sbd_public_ip() {
    local url ip family
    for family in 4 6; do
        url=https://api.ipify.org
        [[ "$family" != 6 ]] || url=https://api64.ipify.org
        if command -v curl >/dev/null 2>&1; then
            ip=$(curl -fsS "-$family" --connect-timeout 2 --max-time 4 "$url" 2>/dev/null) || continue
        elif command -v wget >/dev/null 2>&1; then
            ip=$(wget -q -T 4 -O - "$url" 2>/dev/null) || continue
        else return 1; fi
        # 外部响应必须是公网 IP 字面量，不能将错误页、域名或内网地址用作默认值。
        if ip=$(python3 -c 'import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1].strip()); sys.exit(1) if not ip.is_global or ip.is_multicast else print(ip)' "$ip" 2>/dev/null); then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}

sbd_download() {
    local url="$1" target="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --connect-timeout 15 --max-time 120 "$url" -o "$target" || { _error "下载失败: $url"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 120 -O "$target" "$url" || { _error "下载失败: $url"; return 1; }
    else
        _error '需要 curl 或 wget'
        return 1
    fi
    [[ -s "$target" ]] || { _error "下载结果为空: $url"; return 1; }
}

sbd_write_lock() (
    mkdir -p -- "$(dirname -- "$SBD_LOCK")" || { _error '无法创建锁目录'; return 1; }
    { exec {SBD_WRITE_FD}>"$SBD_LOCK"; } || { _error '无法打开写锁'; return 1; }
    flock -n "$SBD_WRITE_FD" || { _error '另一个操作正在修改部署，请稍后重试'; return 1; }
    "$@"
)
