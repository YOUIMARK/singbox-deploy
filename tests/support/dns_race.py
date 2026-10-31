import json
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
preset = Path(sys.argv[2])


def serve(sock, delay, hits, stop, ip, rcode):
    # 每个上游返回不同的 loopback IP，验证胜出的是较快响应而非配置中的第一项。
    sock.settimeout(0.1)
    while not stop.is_set():
        try:
            data, peer = sock.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            return
        hits.append(time.monotonic())
        if delay is None:
            continue
        end = 12
        while data[end]:
            end += data[end] + 1
        end += 5
        question = data[12:end]
        qtype = struct.unpack('!H', question[-4:-2])[0]
        response = data[:2] + struct.pack('!HHHHH', 0x8180 | rcode, 1, qtype == 1 and rcode == 0, 0, 0) + question
        if qtype == 1 and rcode == 0:
            response += b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 0, 4) + socket.inet_aton(ip)
        time.sleep(delay)
        sock.sendto(response, peer)


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def run(resolve, drop_fast=False, fail_fast=False):
    stop = threading.Event()
    sockets, threads, queries = [], [], [[], [], []]
    servers = []
    for index, delay in enumerate((0.6, 0.2, None if drop_fast else 0.02)):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(('127.0.0.1', 0))
        sockets.append(sock)
        servers.append({'type': 'udp', 'tag': ('cloudflare', 'quad9', 'controld')[index], 'server': '127.0.0.1', 'server_port': sock.getsockname()[1]})
        thread = threading.Thread(target=serve, args=(sock, delay, queries[index], stop, f'127.0.0.{index+1}', 2 if fail_fast and index == 2 else 0), daemon=True)
        thread.start()
        threads.append(thread)
    proxy_port = free_port()
    with socket.socket() as destination, tempfile.TemporaryDirectory() as directory:
        destination.bind(('127.0.0.2' if drop_fast or fail_fast else '127.0.0.3' if resolve else '127.0.0.1', 0))
        destination.listen()
        destination.settimeout(3)
        config = json.loads(preset.read_text())
        config.pop('$schema', None)
        config['ntp']['enabled'] = False
        config['log'] = {'level': 'debug'}
        config['dns']['servers'] = servers
        config['dns']['strategy'] = 'ipv4_only'
        config['dns']['disable_cache'] = True
        config['inbounds'] = [{'type': 'socks', 'tag': 'test', 'listen': '127.0.0.1', 'listen_port': proxy_port}]
        # 目标固定绑定回环地址，默认私网拒绝规则与本用例无关，先剔除以免误拦
        config['route']['rules'] = [] if not resolve else [
            rule for rule in config.get('route', {}).get('rules', []) if not rule.get('ip_is_private')]
        path = Path(directory) / 'config.json'
        path.write_text(json.dumps(config))
        subprocess.run([binary, 'check', '-c', str(path)], check=True)
        with (Path(directory) / 'core.log').open('w+') as log:
            proc = subprocess.Popen([binary, 'run', '-c', str(path)], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 4
                while True:
                    try:
                        client = socket.create_connection(('127.0.0.1', proxy_port), timeout=0.1)
                        break
                    except OSError:
                        if time.monotonic() > deadline or proc.poll() is not None:
                            raise RuntimeError('test core failed to listen')
                        time.sleep(0.02)
                with client:
                    client.settimeout(3)
                    client.sendall(b'\x05\x01\x00')
                    assert client.recv(2) == b'\x05\x00'
                    domain = b'probe.example'
                    request = b'\x05\x01\x00\x03' + bytes([len(domain)]) + domain + struct.pack('!H', destination.getsockname()[1])
                    started = time.monotonic()
                    client.sendall(request)
                    response = client.recv(128)
                    elapsed = time.monotonic() - started
                    assert response[1] == 0, response
                    accepted, _ = destination.accept()
                    accepted.close()
                    counts = list(map(len, queries))
                    print(json.dumps({'route_resolve': resolve, 'drop_fast': drop_fast, 'fail_fast': fail_fast, 'queries': counts, 'elapsed_ms': round(elapsed * 1000)}), flush=True)
                    assert counts == ([1, 1, 1] if resolve else [1, 0, 0]), counts
            except Exception:
                log.flush()
                log.seek(0)
                print(log.read(), file=sys.stderr)
                raise
            finally:
                proc.terminate()
                proc.wait(timeout=3)
    stop.set()
    for thread in threads:
        thread.join(timeout=1)
    for sock in sockets:
        sock.close()


run(False)
run(True)
run(True, drop_fast=True)
run(True, fail_fast=True)
