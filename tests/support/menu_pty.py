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

root, case_tmp, scenario = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM='xterm-256color', COLUMNS='80', CASE_TMP=case_tmp)
    os.environ.pop('NO_COLOR', None)
    if scenario == 'no_color':
        os.environ['NO_COLOR'] = '1'
    if scenario == 'dumb':
        os.environ['TERM'] = 'dumb'
    os.execvp('bash', ['bash', root + '/tests/support/menu_driver.sh', scenario])

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 80, 0, 0))
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
                assert '\x1b[1;36m终端菜单' in text()
                assert '\x1b[31m[2]' in text()
                assert '\x1b[32m[1]' in text()
            else:
                assert not re.search(r'\x1b\[[0-9;]*m', text())
            send('\n')
        else:
            drain(0.3)
            assert '\x1b' not in text() and '按回车' not in text()
    elif scenario == 'navigation':
        wait_for('请选择')
        assert '配置路径:' not in text() and '日志文件:' not in text()
        assert '核心: 未安装' in text()
        for number in range(12):
            assert f'[{number}]' in text(), number
        start = len(text())
        send('10\n')
        wait_for('按回车返回菜单', start)
        assert '配置路径:' in text()[start:] and '日志文件:' in text()[start:]
        stable_page()
        start = len(text())
        send('\n')
        wait_for('请选择', start)
        start = len(text())
        send('1\n')
        wait_for('请选择', start)
        assert text()[start:].count('核心管理') == 1
        assert '安装与更新' in text()[start:] and '服务控制' in text()[start:]
        start = len(text())
        send('0\n')
        wait_for('singbox-deploy', start)
        wait_for('请选择', start)
        assert '按回车' not in text()[start:], '返回上一级不应额外暂停'
        send('0\n')
    elif scenario == 'failure':
        wait_for('请选择')
        start = len(text())
        send('9\n')
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
