#!/usr/bin/env python3
"""
proxy.py — AWG-Panel 客户端 LAN 代理 (SOCKS5 + HTTP CONNECT 同端口)

为什么不装 mihomo / sing-box:
  客户端这一侧的需求只是"把 TCP 流量丢进隧道", 不需要分流/规则/DNS 劫持。
  引入一个完整内核 = 多几百 MB 依赖 + 多一套配置语法, 与本项目"AmneziaWG
  是独立 VPN core, 不挂在别的 core 上"的定位冲突。这里零依赖, 只依赖 python3。

关键点 — 源地址绑定:
  出站 socket 显式 bind 到隧道地址(如 10.66.66.2), 配合
      ip rule add from 10.66.66.2/32 lookup 100
      ip route add default dev awg0 table 100
  代理进程发出的连接才会命中策略路由走隧道; 而本机其它流量
  (SSH 等, 源地址是 LAN 地址) 完全不受影响 —— 这是"不掉 SSH"的结构性保证。

用法:
  proxy.py --port 7891 [--src-ip 10.66.66.2] [--host 0.0.0.0]
"""
import argparse
import ipaddress
import select
import socket
import sys
import threading

BUF = 65536


def log(msg: str) -> None:
    print(f"[proxy] {msg}", file=sys.stderr, flush=True)


# ---------------- SOCKS5 ----------------
def recv_exact(sock: socket.socket, n: int) -> bytes:
    """TCP 是流, recv(n) 可能只返回一部分, 必须循环读满。"""
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return buf
        buf += chunk
    return buf


def socks5_handshake(sock: socket.socket):
    """返回 (host, port); 不支持/出错返回 None"""
    hdr = recv_exact(sock, 2)
    if len(hdr) < 2 or hdr[0] != 0x05:
        return None
    nmethods = hdr[1]                      # 方法数量就在 hdr[1], 不是再 recv 一个字节
    if nmethods == 0:
        sock.sendall(b"\x05\xff")
        return None
    methods = recv_exact(sock, nmethods)
    if len(methods) < nmethods or 0x00 not in methods:
        sock.sendall(b"\x05\xff")
        return None
    sock.sendall(b"\x05\x00")

    req = recv_exact(sock, 4)
    if len(req) < 4 or req[1] != 0x01:      # 只支持 CONNECT
        socks5_reply(sock, False)
        return None
    atyp = req[3]
    if atyp == 0x01:
        host = socket.inet_ntoa(recv_exact(sock, 4))
    elif atyp == 0x03:
        ln_raw = recv_exact(sock, 1)
        if not ln_raw:
            return None
        # SOCKS5 域名是 ASCII; idna codec 不支持 "ignore" 错误处理, 会直接抛异常
        host = recv_exact(sock, ln_raw[0]).decode("utf-8", "replace")
    elif atyp == 0x04:
        host = socket.inet_ntop(socket.AF_INET6, recv_exact(sock, 16))
    else:
        socks5_reply(sock, False)
        return None
    port_raw = recv_exact(sock, 2)
    if len(port_raw) < 2:
        return None
    return host, int.from_bytes(port_raw, "big")


def socks5_reply(sock: socket.socket, ok: bool) -> None:
    if ok:
        sock.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
    else:
        sock.sendall(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")


# ---------------- HTTP ----------------
def http_head(sock: socket.socket) -> tuple[str, int] | None:
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(BUF)
        if not chunk:
            return None
        buf += chunk
        if len(buf) > 65536:
            return None
    # 请求头之后可能已经带着隧道数据, 一并返回给调用方处理
    line = buf.split(b"\r\n", 1)[0].decode("latin1", "ignore").split()
    if len(line) < 2 or line[0].upper() != "CONNECT":
        return None
    hostport = line[1]
    if ":" in hostport:
        host, port = hostport.rsplit(":", 1)
        return host, int(port)
    return hostport, 443


def pump(a: socket.socket, b: socket.socket) -> None:
    """双向转发, 任一方向 EOF 即收工"""
    socks = [a, b]
    try:
        while True:
            r, _, x = select.select(socks, [], socks, 60)
            if x or not r:
                break
            for s in r:
                data = s.recv(BUF)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except OSError:
        pass


def handle(client: socket.socket, src_ip: str | None, verbose: bool) -> None:
    remote = client.getpeername()
    try:
        first = client.recv(1, socket.MSG_PEEK)
        if first == b"\x05":
            target = socks5_handshake(client)
            if target is None:
                return
            host, port = target
        else:
            target = http_head(client)
            if target is None:
                client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
                return
            host, port = target

        upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        upstream.settimeout(20)
        if src_ip:
            try:
                # 关键: 绑定隧道源地址, 才能命中 client.sh 装的 ip rule
                upstream.bind((src_ip, 0))
            except OSError as e:
                log(f"bind({src_ip}) 失败: {e}")
                return
        try:
            upstream.connect((host, port))
        except OSError as e:
            if first == b"\x05":
                socks5_reply(client, False)
            else:
                client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            log(f"{host}:{port} 连接失败: {e}")
            return
        upstream.settimeout(None)
        client.settimeout(None)

        if first == b"\x05":
            socks5_reply(client, True)
        else:
            client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")

        if verbose:
            log(f"{remote[0]}:{remote[1]} -> {host}:{port}")
        pump(client, upstream)
    except Exception as e:                                   # 单连接失败不影响服务
        log(f"连接处理异常: {e}")
    finally:
        try:
            client.close()
        except OSError:
            pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--src-ip", default=None,
                    help="出站绑定的源地址(隧道地址), 决定是否走隧道")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    try:                                                     # 提前校验 src-ip
        if a.src_ip:
            ipaddress.IPv4Address(a.src_ip)
    except ValueError as e:
        log(f"--src-ip 非法: {e}")
        return 2

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind((a.host, a.port))
    except OSError as e:
        log(f"无法绑定 {a.host}:{a.port} —— {e}")
        return 1
    srv.listen(256)
    log(f"已启动 SOCKS5/HTTP  {a.host}:{a.port}  源地址={a.src_ip or '不绑定(直连)'}")

    while True:
        try:
            conn, _ = srv.accept()
        except KeyboardInterrupt:
            break
        except OSError:
            continue
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=handle, args=(conn, a.src_ip, a.verbose),
                         daemon=True).start()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)