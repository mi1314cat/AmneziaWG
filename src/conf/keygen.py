#!/usr/bin/env python3
"""
keygen.py — AmneziaWG 密钥生成 (零依赖)

为什么不直接用 `wg genkey`:
  wireguard-tools 在精简发行版上不一定存在, 而 AmneziaWG 项目要求"curl 一条命令就能装上"。
  同样不依赖 python cryptography —— 纯 Python 实现 RFC 7748 X25519, 32 字节私钥/公钥。

AWG 沿用标准 Curve25519 密钥格式, 所以和 wg 生成的密钥完全互通。

输出格式说明 (项目内部到处都要用, 记牢):
  base64 — 写进 .conf / mihomo YAML / 给 AmneziaWG 官方 App
  hex    — 写进 UAPI (v3 的 UAPI 只收 hex, 见 uapi.py 注释)
"""
import base64
import os
import sys

P = 2 ** 255 - 19
A24 = 121665


def clamp(k: bytes) -> int:
    k = bytearray(k)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    return int.from_bytes(k, "little")


def x25519(k: bytes, u: bytes) -> bytes:
    """RFC 7748 X25519。k 会被 clamp, u 会被 mask 到 255 位。"""
    k_int = clamp(k)
    u_int = int.from_bytes(u, "little") & ((1 << 255) - 1)

    x1, x2, z2, x3, z3, swap = u_int, 1, 0, u_int, 1, 0
    for t in range(254, -1, -1):
        kt = (k_int >> t) & 1
        swap ^= kt
        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        swap = kt

        a = (x2 + z2) % P
        aa = a * a % P
        b = (x2 - z2) % P
        bb = b * b % P
        e = (aa - bb) % P
        c = (x3 + z3) % P
        d = (x3 - z3) % P
        da = d * a % P
        cb = c * b % P
        x3 = pow(da + cb, 2, P)
        z3 = x1 * pow(da - cb, 2, P) % P
        x2 = aa * bb % P
        z2 = e * (aa + A24 * e) % P

    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")


BASE_POINT = (9).to_bytes(32, "little")


def generate() -> tuple[str, str]:
    priv = os.urandom(32)
    pub = x25519(priv, BASE_POINT)
    return base64.b64encode(priv).decode(), base64.b64encode(pub).decode()


def public_from_private(priv_b64: str) -> str:
    try:
        priv = base64.b64decode(priv_b64.strip(), validate=True)
    except Exception as e:
        raise SystemExit(f"错误: 私钥不是合法 base64: {e}")
    if len(priv) != 32:
        raise SystemExit(f"错误: 私钥长度应为 32 字节, 实际 {len(priv)}")
    return base64.b64encode(x25519(priv, BASE_POINT)).decode()


def main(argv):
    if len(argv) == 2 and argv[1] == "gen":
        priv, pub = generate()
        print(priv)
        print(pub)
        return 0
    if len(argv) == 3 and argv[1] == "pub":
        print(public_from_private(argv[2]))
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))