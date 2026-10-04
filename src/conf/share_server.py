#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
share_server.py — AWG-Panel 配置下发服务

GET  /share/<token>   -> 200: 该节点的 client.conf 文本 (原子消耗一次额度)
                         410: 用尽 / 禁用 / 过期
                         404: 未知 token
                         503: 内核未运行或配置不可用 (不消耗额度)
GET  /status          -> 文本健康

设计沿用 sing-box-core 的 share_server, 三处要点:
  1. flock 串行化 read-modify-write, 多个客户端同时拉不会把 used_count 算错
  2. **先原子预占额度, 再发响应体** —— 客户端拿到 200 就必然有完整 body,
     不会因为中途断连把额度吃掉
  3. 主服务不健康 / 文件缺失时返回 503 且**不**消耗额度
"""
import json, os, sys, time, fcntl, http.server, socketserver, subprocess, socket

SHARE_DIR = os.environ.get("SHARE_DIR", "/opt/awg-panel/amneziawg/share")
LOCK = os.path.join(SHARE_DIR, ".share.lock")
PORT = int(os.environ.get("SHARE_PORT", "9393"))
UNIT = os.environ.get("AWG_UNIT", "amneziawg")


def core_healthy():
    """AWG 服务健康: systemd is-active; 无 systemd 时视为健康"""
    if not os.path.isdir("/run/systemd/system"):
        return True
    try:
        return subprocess.run(["systemctl", "is-active", "--quiet", UNIT]).returncode == 0
    except Exception:
        return True


class Store:
    @staticmethod
    def _lock():
        f = open(LOCK, "a+")
        fcntl.flock(f, fcntl.LOCK_EX)
        return f

    @staticmethod
    def path(token):
        return os.path.join(SHARE_DIR, "shares", f"{token}.json")

    @staticmethod
    def load(token):
        try:
            with open(Store.path(token)) as fh:
                return json.load(fh)
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    @staticmethod
    def save(meta):
        p = Store.path(meta["share_token"])
        tmp = p + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(meta, fh, indent=1)
        os.replace(tmp, p)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/status":
            return self._send(200, "AWG-Panel Share Server OK\n")

        token = path[len("/share/"):] if path.startswith("/share/") else None
        if not token or not token.isalnum() or len(token) < 16:
            return self._send(404, "not found\n")

        lock = Store._lock()
        try:
            meta = Store.load(token)
            if meta is None:
                return self._send(404, "not found\n")
            now = int(time.time())
            if not meta.get("enabled", False):
                return self._send(410, "disabled\n")
            if meta.get("expires_at", 0) and now > int(meta["expires_at"]):
                return self._send(410, "expired\n")
            maxu = int(meta.get("max_uses", 0))
            used = int(meta.get("used_count", 0))
            if maxu and used >= maxu:
                return self._send(410, "used up\n")
            # 未提供成功就不消耗额度
            if not core_healthy():
                return self._send(503, "amneziawg service inactive\n")
            cpath = meta.get("client_file")
            if not cpath or not os.path.isfile(cpath):
                return self._send(503, "config unavailable\n")
            with open(cpath, "rb") as fh:
                body = fh.read()
            # 提交消费: 在发出响应前原子预占
            meta["used_count"] = used + 1
            meta["last_used_at"] = now
            Store.save(meta)
            return self._send(200, body)
        finally:
            try:
                fcntl.flock(lock, fcntl.LOCK_UN)
                lock.close()
            except Exception:
                pass


class Srv(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class Srv6(Srv):
    """双栈监听。

    只绑 0.0.0.0 的话, 纯 IPv6 或 IPv6 优先的机器拉不到配置 ——
    节点配置里就算写了 IPv6 endpoint, 拉取这一步照样失败。
    Linux 上 IPV6_V6ONLY 默认 0, 这里再显式设一次, 不依赖发行版默认值。
    """
    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        Srv.server_bind(self)


def start_server():
    """优先双栈, 退不回双栈时退回仅 IPv4。"""
    for srv_cls, addr, label in ((Srv6, "::", "双栈 IPv4+IPv6"), (Srv, "0.0.0.0", "仅 IPv4")):
        try:
            return srv_cls((addr, PORT), Handler), label
        except OSError as e:
            print(f"bind {addr} 失败: {e}", flush=True)
    raise SystemExit("无法绑定任何监听地址")


if __name__ == "__main__":
    os.makedirs(os.path.join(SHARE_DIR, "shares"), exist_ok=True)
    Store._lock()
    httpd, label = start_server()
    print(f"share server on :{PORT} ({label})", flush=True)
    httpd.serve_forever()