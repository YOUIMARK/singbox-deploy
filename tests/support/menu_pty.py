#!/usr/bin/env python3
"""用真实终端驱动真实菜单；分阶段检查回车前的输出与重绘。"""
import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time
import unicodedata

root, case_tmp, scenario = sys.argv[1:]
columns = 40 if scenario == 'navigation_narrow' else 80
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM='xterm-256color', COLUMNS=str(columns), CASE_TMP=case_tmp)
    os.environ.pop('NO_COLOR', None)
    if scenario in ('no_color', 'status_no_color'):
        os.environ['NO_COLOR'] = '1'
    if scenario == 'dumb':
        os.environ['TERM'] = 'dumb'
    os.execvp('bash', ['bash', root + '/tests/support/menu_driver.sh', scenario])

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 30, columns, 0, 0))
output = bytearray()
finished = False


def drain(seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], max(0, deadline - time.monotonic()))
        if not ready:
            break
        try:
            data = os.read(fd, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                return
            raise
        if not data:
            return
        output.extend(data)


def text():
    return output.decode('utf-8', errors='replace')


def wait_for(value, start=0):
    deadline = time.monotonic() + 30
    while value not in text()[start:]:
        if time.monotonic() >= deadline:
            raise AssertionError('等待输出超时: ' + value)
        drain(0.1)


def send(value):
    os.write(fd, value.encode())


def clears():
    return text().count('\x1b[H\x1b[2J')


def stable_page():
    before = clears()
    drain(0.3)
    assert clears() == before, '未按回车便重绘'


try:
    if scenario in ('colors', 'no_color', 'dumb'):
        wait_for('[0]')
        if scenario != 'dumb':
            wait_for('按回车返回菜单')
            stable_page()
            assert clears() == 1
            if scenario == 'colors':
                assert '\x1b[36m终端菜单' in text()
                assert '\x1b[32m[2]' in text()
                assert '\x1b[32m[1]' in text()
                assert '\x1b[1;' not in text()
            else:
                assert not re.search(r'\x1b\[[0-9;]*m', text())
            send('\n')
        else:
            drain(0.3)
            assert '\x1b' not in text() and '按回车' not in text()
    elif scenario in ('status_colors', 'status_no_color'):
        wait_for('结束预览:')
        plain = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text()).replace('\r\n', '\n')
        assert plain.startswith('      sing-box 部署管理脚本 (singbox-deploy)\n\n'), plain
        lines = [line for line in plain.splitlines() if '  |  ' in line][:3]
        def width(value):
            return sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in value)
        bars = [[width(line[:i]) for i, c in enumerate(line) if c == '|'] for line in lines]
        assert bars[0][0] == bars[1][0] == bars[2][0], bars
        assert bars[1][1] == bars[2][1], bars
        if scenario == 'status_colors':
            for value in ('Debian GNU/Linux 13 (trixie)', 'systemd', '10 个', '0.1.0', '1.14.4'):
                assert f'\x1b[36m{value}\x1b[0m' in text(), value
            for value in ('未安装', '已停止', '已关闭', '未创建'):
                assert f'\x1b[31m{value}\x1b[0m' in text(), value
            for value in ('运行中', '已开启', '已存在'):
                assert f'\x1b[32m{value}\x1b[0m' in text(), value
            assert '\x1b[33m未知\x1b[0m' in text()
            assert '\x1b[1;' not in text()
        else:
            assert not re.search(r'\x1b\[[0-9;]*m', text())
        send('0\n')
    elif scenario in ('navigation', 'navigation_narrow'):
        wait_for('请选择')
        assert '配置路径:' not in text() and '日志文件:' not in text()
        plain = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text())
        assert '核心: 未安装' in plain
        for number in range(21):
            assert f'[{number}]' in text(), number
        lines = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text()).splitlines()
        assert [int(n) for n in re.findall(r'\[(\d+)\]', '\n'.join(lines))] == list(range(1, 21)) + [0]
        assert '【节点管理】' in text() and '【服务控制】' in text()
        assert 'init: openrc' in plain and '  |  服务:' in plain
        assert '--------' not in text()
        for item in ('[2]', '[4]', '[7]', '[9]', '[11]', '[13]', '[15]', '[17]', '[20]'):
            line = next(line for line in lines if item in line)
            prefix = line[:line.index(item)]
            width = sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in prefix)
            assert width == (2 if columns == 40 else 26), (item, width, line)
        start = len(text())
        send('12\n')
        wait_for('按回车返回菜单', start)
        assert '配置路径:' in text()[start:] and '日志文件:' in text()[start:]
        stable_page()
        start = len(text())
        send('\n')
        wait_for('请选择', start)
        start = len(text())
        send('19\n')
        wait_for('请选择', start)
        assert text()[start:].count('核心管理') == 1
        assert '安装与更新' in text()[start:] and '服务控制' in text()[start:]
        page = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text()[start:]).replace('\r\n', '\n')
        assert '  核心管理\n\n  【安装与更新】\n' in page, page
        start = len(text())
        send('0\n')
        wait_for('singbox-deploy', start)
        wait_for('请选择', start)
        assert '按回车' not in text()[start:], '返回上一级不应额外暂停'
        send('0\n')
    elif scenario == 'dns_layout':
        wait_for('请选择')
        start = len(text())
        send('6\n')
        wait_for('请选择', start)
        page = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text()[start:]).replace('\r\n', '\n')
        lines = [line for line in page.splitlines() if re.search(r'\[\d+\]', line)]
        assert [int(n) for n in re.findall(r'\[(\d+)\]', page)] == list(range(1, 10)) + [0], page
        assert all(re.match(r'^  \[\d+\] ', line) and len(re.findall(r'\[\d+\]', line)) == 1 for line in lines), lines
        assert '[9] 高级设置' in page and '当前 DNS:' in page, page
        assert 'JSON 替换托管上游' not in page and 'TLS SNI' not in page, page
        start = len(text())
        send('0\n')
        wait_for('请选择', start)
        page = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text()[start:])
        assert any('[1]' in line and '[2]' in line for line in page.splitlines()), page
        assert '按回车' not in page
        send('0\n')
    elif scenario == 'ntp_simple':
        wait_for('请选择')
        start = len(text())
        send('17\n')
        wait_for('请选择', start)
        start = len(text())
        send('10\n')
        wait_for('请选择', start)
        start = len(text())
        send('2\n')
        wait_for('NTP 时间源', start)
        send('\ny\n')
        wait_for('原生 NTP 配置已提交', start)
        wait_for('按回车返回菜单', start)
        page = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text()[start:])
        assert 'NTP UDP 端口' not in page and '原生 NTP 同步间隔' not in page, page
        assert '选择目标标识' not in page, page
        stable_page()
        start = len(text())
        send('\n')
        wait_for('请选择', start)
        assert '高级 NTP 设置' in text()[start:]
        start = len(text())
        send('0\n')
        wait_for('请选择', start)
        assert '日志与监控' in text()[start:] and '按回车' not in text()[start:]
        start = len(text())
        send('0\n')
        wait_for('请选择', start)
        assert 'singbox-deploy' in text()[start:]
        send('0\n')
    elif scenario == 'dns_preset':
        wait_for('请选择')
        send('6\n')
        start = len(text())
        wait_for('请选择', start)
        start = len(text())
        before = clears()
        send('4\ny\n')
        wait_for('DNS 设置已更新', start)
        wait_for('按回车返回菜单', start)
        assert clears() == before, '成功前不能清屏重绘'
        stable_page()
        start = len(text())
        send('\n')
        wait_for('请选择', start)
        page = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text()[start:])
        assert '当前 DNS: https://1.1.1.1/dns-query' in page, page
        assert 'TLS SNI' not in page and 'JSON 替换' not in page, page
        start = len(text())
        send('9\n')
        wait_for('请选择', start)
        assert 'DNS 高级设置' in text()[start:] and 'JSON 替换' in text()[start:]
        start = len(text())
        send('0\n')
        wait_for('请选择', start)
        assert '高级设置' in text()[start:] and '按回车' not in text()[start:]
        start = len(text())
        send('0\n')
        wait_for('请选择', start)
        assert 'singbox-deploy' in text()[start:]
        send('0\n')
    elif scenario == 'create_link':
        wait_for('请选择')
        send('1\n')
        wait_for('选择配置档')
        before = clears()
        start = len(text())
        send('6\n127.0.0.1\n19506\n\n自动分享Vision\n\nwww.asus.com\ny\n')
        wait_for('分享链接:', start)
        wait_for('按回车返回菜单', start)
        page = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text()[start:])
        assert re.search(r'分享链接: vless://[^\r\n]+@8\.8\.8\.8:19506/?\?', page), page
        assert '当前节点链接' not in page and '客户端映射端口' not in page, page
        assert 'Reality 握手目标' not in page and '握手目标端口' not in page, page
        assert '未验证 NAT' not in page and '[成功]' in page, page
        assert clears() == before, '显示链接前不能清屏进入其他菜单'
        stable_page()
        start = len(text())
        send('\n')
        wait_for('请选择', start)
        page = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text()[start:])
        assert 'singbox-deploy' in page and '按回车' not in page, page
        send('0\n')
    elif scenario == 'failure':
        wait_for('请选择')
        start = len(text())
        send('16\n')
        wait_for('按回车返回菜单', start)
        assert '错误' in text()[start:] and '[成功]' not in text()[start:]
        stable_page()
        start = len(text())
        send('\n')
        wait_for('请选择', start)
        send('0\n')
    elif scenario == 'eof':
        wait_for('按回车返回菜单')
        send('\x04')
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        drain(0.1)
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            finished = True
            assert os.waitstatus_to_exitcode(status) == 0, status
            break
    assert finished, '终端子进程未退出'
    if scenario == 'eof':
        assert clears() == 1 and '不应再次读取' not in text()
finally:
    if not finished:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(fd)
    with open(case_tmp + '/terminal.log', 'w', encoding='utf-8') as log:
        log.write(text())
    if sys.exc_info()[0] is not None:
        print(text(), file=sys.stderr)
