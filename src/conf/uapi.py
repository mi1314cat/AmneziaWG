#!/usr/bin/env python3
"""
uapi.py — AmneziaWG UAPI 客户端 + server.conf 渲染器 (AWG-Panel 内部工具)

为什么需要它:
  amneziawg-go 不读取 ini/wireguard 配置文件, 只接受 unix socket 上的 UAPI 文本协议
  (/var/run/amneziawg/<iface>.sock)。awk/sed 处理 base64→hex 转换和"零值不写"很易错,
  故这一层用 Python 实现并单测。

三条实测得来的硬规则 (踩过坑, 不要改):
  1) set: 服务端用 io.MultiReader 读到 EOF 才处理 -> 客户端必须 shutdown(SHUT_WR) 半关闭,
     否则服务端永久阻塞, 表现为 socket 超时。
  2) get: 服务端读完 "get=1\\n" 后还要再读一个字节且必须是 '\\n', 否则直接 return (空输出)。
  3) v3 的密钥是 **hex**, 不是 base64 (loadExactHex)。传 base64 会得到 errno=-22。

子命令:
  render <server.conf>            把 server.conf 渲染成 UAPI payload (写 stdout)
  set <iface> <conf-file|->       下发 UAPI
  get <iface>                     读回当前状态
"""
import base64
import binascii
import configparser
import os
import socket
import tempfile
import re
import sys

SOCKDIR = "/var/run/amneziawg"

# 与 device/noise-types.go 的 HeaderCipherNonceSize 保持一致
HEADER_CIPHER_NONCE_SIZE = 12

# v3 中被移除的 v1.5 专属参数: 误传会直接 errno=-22, 这里提前拦掉
V15_ONLY = ("J1", "J2", "J3", "Itime")

# AWG 混淆参数 -> UAPI 键名 (小写)
PARAM_MAP = {
    "Jc": "jc", "Jmin": "jmin", "Jmax": "jmax",
    "S1": "s1", "S2": "s2", "S3": "s3", "S4": "s4",
    "H1": "h1", "H2": "h2", "H3": "h3", "H4": "h4",
    "I1": "i1", "I2": "i2", "I3": "i3", "I4": "i4", "I5": "i5",
    "ContentPaddingAddition": "content_padding_addition",
    "RekeyAfterTime": "rekey_after_time",
    "RekeyTimeout": "rekey_timeout",
    "RejectAfterTime": "reject_after_time",
    "KeepaliveTimeout": "keepalive_timeout",
    "MaxHandshakeAttempts": "max_handshake_attempts",
    "RandomTrailers": "random_trailers",
    "DisableCookies": "disable_cookies",
}

# 取值非 "0"/"false"/空 才写进 UAPI 的键
SKIP_IF_ZERO = {"jc", "jmin", "jmax", "s1", "s2", "s3", "s4",
                "i1", "i2", "i3", "i4", "i5",
                "content_padding_addition", "rekey_after_time",
                "rekey_timeout", "reject_after_time",
                "keepalive_timeout", "max_handshake_attempts"}

BOOL_KEYS = {"random_trailers", "disable_cookies"}


class CfgError(Exception):
    pass


def b64_to_hex(value: str, what: str) -> str:
    """wireguard/AWG 的 base64 密钥 -> UAPI 需要的 hex。"""
    try:
        raw = base64.b64decode(value.strip(), validate=True)
    except (binascii.Error, ValueError) as e:
        raise CfgError(f"{what} 不是合法 base64: {e}")
    if len(raw) != 32:
        raise CfgError(f"{what} 长度应为 32 字节, 实际 {len(raw)}")
    return raw.hex()


def parse_server_conf(path: str):
        # RawConfigParser: 关闭 % 插值, 否则任何含 % 的值都会在解析期炸掉
    cp = configparser.RawConfigParser(allow_no_value=True)
    cp.optionxform = str  # 保留键的大小写 (Jc/H1/...)
    try:
        with open(path, encoding="utf-8") as fh:
            cp.read_file(fh)
    except configparser.Error as e:
        raise CfgError(f"server.conf 解析失败: {e}")

    if not cp.has_section("Interface"):
        raise CfgError("server.conf 缺少 [Interface] 段")
    iface = cp["Interface"]
    own_pub = iface.get("PublicKey", "").strip()

    peers = []
    for sec in cp.sections():
        # 只收集 [Peer*] 段。以前这里写成 `sec != "Interface" and not startswith("Peer")`,
        # 结果 [Interface] 反而会被当成一个 peer 处理 —— 因为 server.conf 的 [Interface]
        # 里有 PublicKey(服务端自己的公钥), 于是产生一条"自己和自己握手"的 peer。
        if not sec.startswith("Peer"):
            continue
        # 防呆: AWG 混淆参数被误写到 [Peer] 段会**静默失效**(UAPI 不报错, 只是没生效),
        # 排查起来极难发现, 所以这里显式拦下。
        known = set(PARAM_MAP) | {"HeaderProtectionKey", "Itime"}
        misplaced = [k for k in cp.options(sec) if k in known]
        if misplaced:
            raise CfgError(
                f"{sec} 段出现只属于 [Interface] 的键: {', '.join(sorted(misplaced))}。"
                f"(常见原因: 把这些行追加到了文件末尾, 落在最后一个 [Peer] 之后)"
            )
        pk = cp.get(sec, "PublicKey", fallback="").strip()
        if not pk:
            continue
        # 自己和自己是握不了手的, 出现即说明配置串了
        if own_pub and pk == own_pub:
            raise CfgError(
                f"{sec} 的 PublicKey 与服务端自身公钥相同 —— "
                f"peer 必须是独立的客户端密钥对, 否则永远无法握手"
            )
        peers.append({
            "name": sec,
            "public_key": pk,
            "allowed_ips": cp.get(sec, "AllowedIPs", fallback="").strip(),
            "keepalive": cp.get(sec, "PersistentKeepalive", fallback="").strip(),
            "preshared": cp.get(sec, "PresharedKey", fallback="").strip(),
        })
    return iface, peers


def render(conf_path: str) -> str:
    iface, peers = parse_server_conf(conf_path)
    out = []

    sk = (iface.get("PrivateKey") or "").strip()
    if not sk:
        raise CfgError("[Interface] 缺少 PrivateKey")
    out.append(f"private_key={b64_to_hex(sk, '[Interface] PrivateKey')}")

    port = (iface.get("ListenPort") or "").strip()
    if not port.isdigit() or not (1 <= int(port) <= 65535):
        raise CfgError(f"ListenPort 非法: {port!r}")
    out.append(f"listen_port={port}")

    if (iface.get("FWMark") or "").strip():
        out.append(f"fwmark={iface['FWMark'].strip()}")

    # 旧版 v1.5 专属参数在 v3 会直接报错, 提前拦
    for k in V15_ONLY:
        if (iface.get(k) or "").strip():
            raise CfgError(f"{k} 是 AmneziaWG v1.5 专属参数, v3 已移除, 请删除")

    vals = {}
    for key, uapi_key in PARAM_MAP.items():
        raw = (iface.get(key) or "").strip()
        if not raw:
            continue
        if uapi_key in BOOL_KEYS:
            vals[uapi_key] = "true" if raw.lower() in ("1", "true", "yes", "on") else "false"
        else:
            vals[uapi_key] = raw

    # Header Protection 前置: S1..S4 必须全部 >= HeaderCipherNonceSize
    hp = (iface.get("HeaderProtectionKey") or "").strip()
    if hp:
        hx = b64_to_hex(hp, "[Interface] HeaderProtectionKey")
        vals["header_protection_key"] = hx
        for i in range(1, 5):
            key = f"s{i}"
            got = vals.get(key)
            if got is None or not got.lstrip("-").isdigit() or int(got) < HEADER_CIPHER_NONCE_SIZE:
                raise CfgError(
                    f"启用 HeaderProtectionKey 时 S1-S4 必须全部 >= {HEADER_CIPHER_NONCE_SIZE}"
                    f"(当前 {key}={got or '未设置'})；否则 amneziawg-go 会返回 errno=-22 且不提示原因"
                )

    for uapi_key in sorted(vals, key=lambda k: list(PARAM_MAP.values()).index(k)
                           if k in list(PARAM_MAP.values()) else 99):
        v = vals[uapi_key]
        if uapi_key in SKIP_IF_ZERO and v in ("0", "false", ""):
            continue
        out.append(f"{uapi_key}={v}")

    out.append("replace_peers=true")
    for p in peers:
        pkh = b64_to_hex(p["public_key"], p["name"] + " PublicKey")
        out.append(f"public_key={pkh}")
        out.append("replace_allowed_ips=true")
        aips = p["allowed_ips"] or "0.0.0.0/0"
        for a in aips.replace(",", " ").split():
            out.append(f"allowed_ip={a}")
        if p["preshared"]:
            psk = b64_to_hex(p["preshared"], p["name"] + " PresharedKey")
            out.append(f"preshared_key={psk}")
        if p["keepalive"]:
            out.append(f"persistent_keepalive_interval={p['keepalive']}")
        out.append("")

    return "\n".join(out).rstrip() + "\n"


def render_client(conf_path: str) -> str:
    """把客户端 .conf 渲染成 UAPI。

    与服务端的差异:
      - 不设 listen_port (客户端不监听)
      - 只有一个 peer(服务端), 且必须带 endpoint
      - 混淆参数(Jc/H1.../S1...)必须与服务端逐项一致, 否则握手包对不上
    """
    cp = configparser.RawConfigParser(allow_no_value=True)
    cp.optionxform = str
    try:
        with open(conf_path, encoding="utf-8") as fh:
            cp.read_file(fh)
    except configparser.Error as e:
        raise CfgError(f"客户端配置解析失败: {e}")
    if not cp.has_section("Interface"):
        raise CfgError("客户端配置缺少 [Interface] 段")
    iface = cp["Interface"]

    sk = (iface.get("PrivateKey") or "").strip()
    if not sk:
        raise CfgError("[Interface] 缺少 PrivateKey")
    out = [f"private_key={b64_to_hex(sk, '[Interface] PrivateKey')}"]

    for k in V15_ONLY:
        if (iface.get(k) or "").strip():
            raise CfgError(f"{k} 是 AmneziaWG v1.5 专属参数, v3 已移除, 请删除")

    vals = {}
    for key, uapi_key in PARAM_MAP.items():
        raw = (iface.get(key) or "").strip()
        if not raw:
            continue
        if uapi_key in BOOL_KEYS:
            vals[uapi_key] = "true" if raw.lower() in ("1", "true", "yes", "on") else "false"
        else:
            vals[uapi_key] = raw

    hp = (iface.get("HeaderProtectionKey") or "").strip()
    if hp:
        vals["header_protection_key"] = b64_to_hex(hp, "[Interface] HeaderProtectionKey")
        for i in range(1, 5):
            got = vals.get(f"s{i}")
            if got is None or not got.lstrip("-").isdigit() or int(got) < HEADER_CIPHER_NONCE_SIZE:
                raise CfgError(
                    f"启用 HeaderProtectionKey 时 S1-S4 必须全部 >= {HEADER_CIPHER_NONCE_MIN}"
                    f"(当前 s{i}={got or '未设置'})"
                )

    for uapi_key in sorted(vals, key=lambda k: list(PARAM_MAP.values()).index(k)
                           if k in list(PARAM_MAP.values()) else 99):
        v = vals[uapi_key]
        if uapi_key in SKIP_IF_ZERO and v in ("0", "false", ""):
            continue
        out.append(f"{uapi_key}={v}")

    if not cp.has_section("Peer"):
        raise CfgError("客户端配置缺少 [Peer] 段 (服务端信息)")
    peer = cp["Peer"]
    # 混淆参数写进 [Peer] 会**静默失效**: 客户端 UAPI 只从 [Interface] 取参数,
    # 症状是握手始终不完成, 且没有任何报错。必须拦下来。
    misplaced = [k for k in cp.options("Peer") if k in PARAM_MAP
                 or k in ("HeaderProtectionKey", "Itime")]
    if misplaced:
        raise CfgError(
            f"[Peer] 段出现只属于 [Interface] 的键: {', '.join(sorted(misplaced))}。"
            f"(AWG 混淆参数必须写在 [Interface] 段内, 否则会静默失效)"
        )
    pk = (peer.get("PublicKey") or "").strip()
    if not pk:
        raise CfgError("[Peer] 缺少 PublicKey (服务端公钥)")
    ep = (peer.get("Endpoint") or "").strip()
    if not ep or ":" not in ep:
        raise CfgError(f"[Peer] Endpoint 无效: {ep!r} (应为 host:port)")
    host, _, port = ep.rpartition(":")
    if not port.isdigit() or not (1 <= int(port) <= 65535):
        raise CfgError(f"Endpoint 端口非法: {port!r}")

    out.append(f"public_key={b64_to_hex(pk, '[Peer] PublicKey')}")
    out.append("replace_allowed_ips=true")
    for a in ((peer.get("AllowedIPs") or "").strip() or "0.0.0.0/0").replace(",", " ").split():
        out.append(f"allowed_ip={a}")
    out.append(f"endpoint={host}:{int(port)}")
    ka = (peer.get("PersistentKeepalive") or "").strip()
    if ka:
        out.append(f"persistent_keepalive_interval={ka}")
    return "\n".join(out) + "\n"


# ------------------------------- UAPI 传输 -------------------------------

def sock_path(iface: str) -> str:
    return os.path.join(SOCKDIR, f"{iface}.sock")


def uapi_call(iface: str, op: str, payload: str = "", timeout: int = 15) -> str:
    path = sock_path(iface)
    if not os.path.exists(path):
        raise CfgError(f"UAPI socket 不存在: {path} (服务是否在运行?)")

    body = f"{op}=1\n"
    if op == "get":
        body += "\n"          # 规则 2: get 之后必须多一个换行
    if payload:
        if not payload.endswith("\n"):
            payload += "\n"
        body += payload

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(path)
        s.sendall(body.encode())
        s.shutdown(socket.SHUT_WR)   # 规则 1: 半关闭, 否则服务端读到 EOF 前一直等
        chunks = []
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        s.close()
    return b"".join(chunks).decode(errors="replace")


def parse_errno(resp: str):
    for line in resp.splitlines():
        if line.startswith("errno="):
            parts = dict(p.split("=", 1) for p in line.split() if "=" in p)
            try:
                code = int(parts.get("errno", "0"))
            except ValueError:
                code = 0
            return code, parts.get("msg", "")
    return 0, ""


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd = argv[1]
    try:
        if cmd == "client" and len(argv) == 3:
            sys.stdout.write(render_client(argv[2]))
            return 0
        if cmd == "render" and len(argv) == 3:
            sys.stdout.write(render(argv[2]))
            return 0
        if cmd == "set" and len(argv) == 4:
            conf = sys.stdin.read() if argv[3] == "-" else open(argv[3], encoding="utf-8").read()
            # 直接传 .conf 是很自然的想法, 但 UAPI 只认 key=value,
            # 遇到 [Interface] 这类小节头会报 errno=-71 "failed to parse line"
            # 且不给原因。这里自动识别并转换, 省得用户对着裸 errno 发呆。
            if re.search(r"^\s*\[(Interface|Peer)\]", conf, re.M):
                sys.stderr.write("[Info] 检测到 INI 格式, 已自动渲染为 UAPI payload\n")
                # render() 收的是**路径**, 这里先落临时文件再转换
                tf = tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False,
                                                encoding="utf-8")
                try:
                    tf.write(conf)
                    tf.close()
                    conf = render(tf.name) if "[Interface]" in conf else render_client(tf.name)
                finally:
                    os.unlink(tf.name)
            code, msg = parse_errno(uapi_call(argv[2], "set", conf))
            if code != 0:
                hint = {
                    -22: "参数不被本版本接受(检查 J1/J2/J3/Itime 这类 v1.5 专属参数, "
                         "v3 会直接拒绝)",
                    -71: "UAPI 报文里有一行不是 key=value。确认传的是渲染后的 payload "
                         "而不是 .conf 原文",
                    -1:  "socket 层失败, 通常是服务没起或权限不足",
                    -4:  "内核返回了内存不足",
                    -13: "参数值超出内核允许的范围",
                }.get(code, "")
                sys.stderr.write(f"UAPI 下发失败 errno={code}: {msg or '(内核未给出原因)'}\n")
                if hint:
                    sys.stderr.write(f"  提示: {hint}\n")
                return 1
            print(f"UAPI 已应用 -> {argv[2]}")
            return 0
        if cmd == "get" and len(argv) == 3:
            sys.stdout.write(uapi_call(argv[2], "get"))
            return 0
    except CfgError as e:
        sys.stderr.write(f"错误: {e}\n")
        return 1
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))