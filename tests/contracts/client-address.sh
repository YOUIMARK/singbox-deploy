#!/usr/bin/env bash
# 只替换公网 HTTP 边界；地址解析、提示、节点创建与事务均使用真实函数。
# shellcheck disable=SC2329,SC2016
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/harness.sh"
. "$(dirname -- "${BASH_SOURCE[0]}")/../support/entries.sh"

http_fixture() {
    : > "$CASE_TMP/http-calls"
    curl() {
        printf '%s\n' "$*" >> "$CASE_TMP/http-calls"
        if [[ "$*" = *' -4 '* ]]; then
            [[ "${IP4_FAIL:-false}" != true ]] || return 1
            printf '%s' "${IP4_BODY:-8.8.8.8}"
        else
            [[ "${IP6_FAIL:-false}" != true ]] || return 1
            printf '%s' "${IP6_BODY:-2606:4700:4700::1111}"
        fi
    }
}
public_ipv4() {
    http_fixture
    IP4_BODY=$' 8.8.8.8\n'
    t_run 0 sbd_public_ip
    t_assert 'IPv4 去除响应首尾空白' test "$(cat "$CASE_TMP/output")" = 8.8.8.8
    t_assert 'IPv4 成功不额外探测 IPv6' test "$(wc -l < "$CASE_TMP/http-calls")" = 1
    t_contains "$CASE_TMP/http-calls" '-4 --connect-timeout 2 --max-time 4 https://api.ipify.org'
}
public_ipv6() {
    http_fixture
    IP4_FAIL=true
    IP6_BODY='2606:4700:4700:0:0:0:0:1111'
    t_run 0 sbd_public_ip
    t_assert 'IPv4 失败后采用规范化 IPv6' test "$(cat "$CASE_TMP/output")" = 2606:4700:4700::1111
    t_contains "$CASE_TMP/http-calls" '-6 --connect-timeout 2 --max-time 4 https://api64.ipify.org'
}
invalid_responses() {
    http_fixture
    local response
    IP6_FAIL=true
    for response in '<html>error</html>' example.com 192.168.1.1 127.0.0.1 100.64.0.1 0.0.0.0 224.0.0.1 2001:db8::1 ::1 '8.8.8.8 extra' $'8.8.8.8\n1.1.1.1'; do
        IP4_BODY="$response"
        t_run 1 sbd_public_ip
        t_assert '无效/非公网响应不能变成默认值' test ! -s "$CASE_TMP/output"
    done
    IP4_BODY=bad IP6_FAIL=false
    t_run 0 sbd_public_ip
    t_assert '无效 IPv4 响应也尝试 IPv6' test "$(cat "$CASE_TMP/output")" = 2606:4700:4700::1111
}
wget_fallback() {
    command() {
        if [[ "$*" = '-v curl' ]]; then return 1; fi
        builtin command "$@"
    }
    wget() { printf '%s\n' "$*" >> "$CASE_TMP/http-calls"; printf '1.1.1.1\n'; }
    : > "$CASE_TMP/http-calls"
    t_run 0 sbd_public_ip
    t_assert '无 curl 时用 wget 获取地址' test "$(cat "$CASE_TMP/output")" = 1.1.1.1
    t_contains "$CASE_TMP/http-calls" '-q -T 4 -O - https://api.ipify.org'
}
default_and_override() {
    http_fixture
    sbd_entry_server_prompt > "$CASE_TMP/output" 2>&1 <<< '' || exit 1
    t_assert '显式回车采用公网 IPv4' test "$SBD_REPLY" = 8.8.8.8
    t_contains "$CASE_TMP/output" '客户端连接地址（回车用公网 IP 8.8.8.8）'
    t_contains "$CASE_TMP/output" '出口 IP'
    sbd_entry_server_prompt > "$CASE_TMP/output" 2>&1 <<< 'nat.example.com' || exit 1
    t_assert '可覆盖为提供商入站域名' test "$SBD_REPLY" = nat.example.com
    IP4_FAIL=true
    sbd_entry_server_prompt > "$CASE_TMP/output" 2>&1 <<< '' || exit 1
    t_assert 'IPv6 默认值不带方括号' test "$SBD_REPLY" = 2606:4700:4700::1111
}
retry_and_existing() {
    http_fixture
    sbd_entry_server_prompt > "$CASE_TMP/output" 2>&1 <<< $'bad/path\n' || exit 1
    t_assert '格式错误后仍可回车采用默认值' test "$SBD_REPLY" = 8.8.8.8
    t_assert '重问不重复联网' test "$(wc -l < "$CASE_TMP/http-calls")" = 1
    : > "$CASE_TMP/http-calls"
    sbd_entry_server_prompt old.example.com > "$CASE_TMP/output" 2>&1 <<< '' || exit 1
    t_assert '修改地址默认保留旧地址' test "$SBD_REPLY" = old.example.com
    t_assert '有旧地址时不探测公网 IP' test ! -s "$CASE_TMP/http-calls"
}
failure_and_eof() {
    http_fixture
    IP4_FAIL=true IP6_FAIL=true
    sbd_entry_server_prompt > "$CASE_TMP/output" 2>&1 <<< $'\nprovider.example.com' || exit 1
    t_assert '探测失败须手填地址' test "$SBD_REPLY" = provider.example.com
    t_contains "$CASE_TMP/output" '未能自动获取公网 IP'
    t_contains "$CASE_TMP/output" '此字段不能为空'
    t_run 2 sbd_entry_server_prompt < /dev/null
    IP4_FAIL=false
    t_run 2 sbd_entry_server_prompt < /dev/null
    t_contains "$CASE_TMP/output" '已取消'
    t_assert 'EOF 不自动采用默认值' test "$SBD_REPLY" != 8.8.8.8
    : > "$CASE_TMP/http-calls"
    SBD_UI_EOF=true t_run 2 sbd_entry_server_prompt <<< ''
    t_assert '已结束的会话不探测公网 IP' test ! -s "$CASE_TMP/http-calls"
}
vision_create() {
    t_seed
    http_fixture
    t_run 0 sbd_entry_create_prompt <<< $'6\n127.0.0.1\n\n\n公网默认Vision\n\n\ny'
    local port
    port=$(jq -r '.inbounds[0].listen_port' "$SBD_CONFIG") || exit 1
    t_assert '随机端口范围正确' test "$port" -ge 10000
    t_assert 'Reality 真实创建使用默认公网地址且初始端口与监听一致' jq -e --argjson port "$port" '.nodes[0]|.client.server=="8.8.8.8" and .client.server_port==$port and .profile=="vless_reality"' "$SBD_REGISTRY"
    t_assert 'Reality 握手自动沿用 SNI 和 443' jq -e '.inbounds[0].tls | .server_name=="www.amd.com" and .reality.handshake=={server:"www.amd.com",server_port:443}' "$SBD_CONFIG"
    t_absent "$CASE_TMP/output" '客户端映射端口'
    t_absent "$CASE_TMP/output" 'Reality 握手目标'
    t_absent "$CASE_TMP/output" '握手目标端口'
    t_absent "$CASE_TMP/output" '未验证 NAT'
    t_contains "$CASE_TMP/output" "分享链接: $(cat "$SBD_EXPORTS/$SBD_NEW_ENTRY_ID.txt")"
    t_absent "$CASE_TMP/output" '当前节点链接'
    t_contains "$SBD_EXPORTS/$SBD_NEW_ENTRY_ID.txt" "@8.8.8.8:$port"
    t_run 0 sbd_check_config
}
anytls_create() {
    t_seed
    http_fixture
    t_run 0 sbd_entry_create_prompt <<< $'2\n127.0.0.1\n19502\n\n公网默认AnyTLS\nfixture-password\n3\nnode.example.com\n2\ny'
    t_assert '另一创建路径使用默认公网地址且初始端口与监听一致' jq -e '.nodes[0]|.client.server=="8.8.8.8" and .client.server_port==19502' "$SBD_REGISTRY"
    t_absent "$CASE_TMP/output" '客户端映射端口'
    t_absent "$CASE_TMP/output" '未验证 NAT'
    t_contains "$CASE_TMP/output" "分享链接: $(cat "$SBD_EXPORTS/$SBD_NEW_ENTRY_ID.txt")"
    t_absent "$CASE_TMP/output" '当前节点链接'
    t_run 0 sbd_check_config
}
reality_prompt() {
    local profile
    for profile in anyreality vless_reality; do
        t_run 0 sbd_entry_tls_prompt "$profile" example.com <<< $'bad/path\nwww.asus.com'
        t_assert '两种 Reality 向导只填写 SNI、目标自动同域名 443' jq -e '.server_name=="www.asus.com" and .handshake=={server:"www.asus.com",server_port:443}' <<< "$SBD_TLS_REQUEST"
        t_absent "$CASE_TMP/output" 'Reality 握手目标'
        t_absent "$CASE_TMP/output" '握手目标端口'
        t_run 0 sbd_entry_tls_prompt "$profile" example.com <<< ''
        t_contains "$CASE_TMP/output" '伪装域名（默认 www.amd.com）'
        t_assert '回车使用默认伪装域名与 443' jq -e '.server_name=="www.amd.com" and .handshake=={server:"www.amd.com",server_port:443}' <<< "$SBD_TLS_REQUEST"
        t_run 2 sbd_entry_tls_prompt "$profile" example.com < /dev/null
    done
}
port_prompt() {
    t_fresh
    t_run 0 sbd_entry_port_prompt 127.0.0.1 tcp <<< $'bad\n00019506'
    t_assert '手填端口错误后只重问该字段并规范化前导零' test "$SBD_REPLY" = 19506
    t_contains "$CASE_TMP/output" '监听端口（回车随机生成）'
    t_run 0 sbd_entry_port_prompt 127.0.0.1 both <<< ''
    t_assert '随机端口不小于 10000' test "$SBD_REPLY" -ge 10000
    t_assert '随机端口不大于 65535' test "$SBD_REPLY" -le 65535
    t_run 0 sbd_entry_port "$SBD_CONFIG_DIR" 127.0.0.1 "$SBD_REPLY" both '' "$SBD_APP/presets/base.json"
    t_run 2 sbd_entry_port_prompt 127.0.0.1 tcp < /dev/null
    openssl() { return 1; }
    t_run 1 sbd_entry_port_prompt 127.0.0.1 tcp <<< ''
    t_contains "$CASE_TMP/output" '随机端口生成失败'
}
automatic_link_pty() {
    t_assert '真实终端创建后自动显示链接、回车仅返回一次' python3 "$ROOT/tests/support/menu_pty.py" "$ROOT" "$CASE_TMP" create_link
}

t_case 'IPv4 响应校验、短超时且优先返回' public_ipv4
t_case 'IPv4 请求失败后回退 IPv6' public_ipv6
t_case '错误页/域名/内网/多行响应不能作为公网默认值' invalid_responses
t_case '无 curl 环境使用兼容 wget 参数' wget_fallback
t_case '回车使用 IPv4/IPv6，手动域名覆盖且提示 NAT 区别' default_and_override
t_case '错误只重问地址、已有地址优先且不联网' retry_and_existing
t_case '探测失败仍必填，EOF 取消而不提交默认值' failure_and_eof
t_case 'VLESS Reality 真实创建、默认地址分享及原生检查' vision_create
t_case 'AnyTLS 真实创建、默认公网地址与监听端口' anytls_create
t_case 'Reality SNI 校验/EOF 保留，目标与端口不再重复询问' reality_prompt
t_case '监听端口可手填或随机、双网络可用性和 EOF/生成失败' port_prompt
t_case '真实终端自动分享后停留、回车返回首页无额外菜单' automatic_link_pty
t_finish
