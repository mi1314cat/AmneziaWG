# AmneziaWG 参数实测表

> 数据来源: 在 RN (Debian 13, amd64) 上用 `amneziawg-go v3.1.20260828` 逐项下发 UAPI，
> 观察 `errno` 结果；协议格式差异对照 `amnezia-vpn/amneziawg-go` 与
> `MetaCubeX/mihomo` 依赖的 `metacubex/amneziawg-go` 源码。
> **不是抄文档** —— 表中"支持"一栏都对应一次真实下发结果或一段源码引用。

## 1. 两端版本基线

| 角色 | 版本 | 说明 |
|---|---|---|
| 服务端 | `amneziawg-go v3.1.20260828` | 官方 release，仅源码包，需自行编译 |
| mihomo 内嵌 | `metacubex/amneziawg-go v0.0.0-20260908071407` | fork，与上游逐文件 diff 后**协议格式完全一致**（差异仅为 Go 1.22 `for range N` 语法与 import 路径） |
| mihomo 本体 | v1.19.30 / v1.19.31 实测 | `amnezia-wg-option` 字段见 `adapter/outbound/wireguard.go` |

## 2. 端到端互通结论

```
CC mihomo v1.19.30 --AWG--> RN amneziawg-go v3.1.20260828 --> Internet
```
| 项目 | 结果 |
|---|---|
| 握手 | PASS |
| HTTPS / SOCKS5 / DoH / IPv4 | PASS |
| 出口 IP | RN (`107.173.154.178`) |

## 3. `amnezia-wg-option` 支持情况（mihomo 侧）

| 参数 | mihomo 支持 | 服务端 UAPI 支持 | 备注 |
|---|---|---|---|
| `version` | ✅ | — | `3` 选 v3 实现；其它值走 v1 实现 |
| `jc` / `jmin` / `jmax` | ✅ | ✅ | 混淆包数量与大小区间 |
| `s1` / `s2` / `s3` / `s4` | ✅ | ✅ | init / response / cookie / transport 四类包的前置填充 |
| `h1` / `h2` / `h3` / `h4` | ✅ | ✅ | **字符串**：可为 `"523"` 或区间 `"100-200"`；v3 中是 uint32，**不是 base64** |
| `i1`–`i5` | ✅ | ✅ | 特殊干扰包语法链 |
| `j1` / `j2` / `j3` / `itime` | ✅（字段存在） | ❌ **v3 已移除** | v1.5 专属；误下发直接 `errno=-22` |
| `header-protection-key` | ✅ (base64) | ✅ (**hex**) | **前置：S1–S4 必须全部 ≥ 12** |
| `content-padding-addition` | ✅ | ✅ | 可为单值或区间 |
| `rekey-after-time` / `rekey-timeout` / `reject-after-time` | ✅ | ✅ | 区间值 |
| `keepalive-timeout` / `max-handshake-attempts` | ✅ | ✅ | 区间值 |
| `random-trailers` | ✅ | ✅ | **AWG v3.1+** |
| `disable-cookies` | ✅ | ✅ | **AWG v3.1+** |

## 4. UAPI 传输层三条硬规则（踩坑）

| 规则 | 不遵守的后果 |
|---|---|
| `set` 后客户端必须 `shutdown(SHUT_WR)` | 服务端 `io.MultiReader` 读到 EOF 才处理 → **永久阻塞** |
| `get` 后必须再发一个 `\n` | 处理器读 `get=1\n` 后还要读一字节且必须是 `\n`，否则直接 return（**输出为空**） |
| 密钥用 **hex**（`private_key` / `public_key` / `preshared_key` / `header_protection_key`） | 传 base64 → `errno=-22`，错误信息为空 |

`protocol_version` 在 v3 中恒为 `1`，**不再用于区分大版本**。

## 4.1 UAPI 回读的私钥是 **clamp 之后**的（不是 bug，别追）

把 `server.conf` 的 `PrivateKey`（base64）转 hex，和 `UAPI get` 回读的 `private_key` 对比，
**永远不会相等**：

```
配置中的私钥  : 9da15713...dd38
UAPI 回读     : 98a15713...dd78
```

原因是 Curve25519 私钥在载入时被 clamp：

```go
k[0]  &= 248    // 0x9d -> 0x98
k[31] &= 127    // 0x38 -> 0x38
k[31] |= 64     // 0x38 -> 0x78
```

clamp 只丢弃不影响结果的比特位，**公钥完全相同**，隧道行为一致。
排查时不要因为这两个值对不上就判定配置错误。

同理，`keygen.py` 的 `x25519()` 内部也做 clamp，所以
`pubkey_from_priv()` 对同一把私钥算出的公钥与服务端一致。

## 4.2 服务端 `server.conf` 的 `[Interface]` 里不要放 `PublicKey`

`[Interface]` 里的 `PublicKey` 只是**给人看的**（排查用），内核不读它。
但 `uapi.py` 解析时会拿它和每个 peer 比对，用来拦截"peer 公钥 == 服务端公钥"的自握手配置。

> 实现上踩过的坑：peer 收集循环原先写成
> `if sec != "Interface" and not sec.startswith("Peer"): continue`，
> 条件为假反而不 `continue`，于是 `[Interface]` 被当成一个 peer 渲染出去，
> 产生一条"服务端和自己握手"的 peer，且 `allowed_ip` 落到默认值 `0.0.0.0/0`。
> 现在只在 `[Peer*]` 段内收集。

## 5. 服务端网络：只加地址不够

```bash
ip addr add 10.66.66.1/32 dev awgt0     # ← 仅此不够
```

握手会成功、`rx_bytes` 会增长，但 MASQUERADE 回来的包在内核找不到下一跳，
表现为**客户端 SYN 无响应**（单向不通）。

必须补：

```bash
ip route add 10.66.66.2/32 dev awgt0    # 每个 peer 一条
```

`apply.sh` 已同时做两件事：按 `Address` 配地址 **且** 为每个 peer 显式补 `/32` 路由。

## 6. Header Protection 的隐藏前置

源码 `device/uapi.go`：

```go
if !d.headerProtectionKey.IsZero() {
    for i, padding := range []uint32{d.paddings.init, d.paddings.response,
                                     d.paddings.cookie, d.paddings.transport} {
        if padding < HeaderCipherNonceSize {
            return fmt.Errorf("S%d must be more then %d to use headerProtection", i, ...)
        }
    }
}
```

`HeaderCipherNonceSize = 12`（`device/noise-types.go`）。

**含义**：启用 `header_protection_key` 时 **S1/S2/S3/S4 四个都必须 ≥ 12**。
内核侧报错信息经 UAPI 传到脚本只剩 `errno=-22` 且 **msg 为空**，用户无从判断原因。
→ `uapi.py` 在下发前拦截并给出可读原因。

## 7. 服务端实现选型

| 方案 | 结论 |
|---|---|
| `amneziawg-go`（用户态） | ✅ 默认。零内核依赖，只需 `/dev/net/tun` + `CAP_NET_ADMIN`；RN 实测 RSS ≈ 13 MB |
| 内核模块 DKMS | ❌ RN 不可行：无 `6.12.107+deb13-amd64` 内核头文件 |

## 8. 待验证

- [ ] AWG 官方 App 的 **QR 载荷格式**（整份 ini？还是某个 URI scheme？）
- [ ] `client-NNN.conf` 中 AWG 参数的官方拼写
- [ ] mihomo `version: 3` 与官方 v3.1 服务端在 `random-trailers` / `disable-cookies` 上的互通
- [ ] 内核模块方案在标准 Debian / Ubuntu 上的可行性
---

## 4.3 UAPI「不写 = 保持」语义（实测，容易想当然）

`device/uapi.go` 的处理流程是：

```go
ipcDev := new(ipcSetDevice)
ipcDev.fromDevice(device)   // ← 先把设备当前值预填进请求结构
```

所以 **payload 里不写某个键 = 保持当前值**，不是「清空」。

对 `HeaderProtectionKey` 这类"关掉就等于没有"的参数，后果是：
面板已经把 `HeaderProtectionKey` 从 `server.conf` 删掉了、`render` 出来的 payload
也确认没有这一行、内核返回成功，但 `get` 读回来**还在**。

试过 `header_protection_key=`（空串）与 64 个 `0`，都被 `loadExactHex` 拒掉：

```
UAPI 下发失败 errno=-22
```

**结论：已下发的 HeaderProtectionKey 无法通过 UAPI 清除，唯一可靠办法是重启服务。**
`amneziawg-go` 无状态，重启即空设备，再由 `ExecStartPost` 重新下发 `server.conf`。
`params.sh` 的 `_ensure_hp_cleared()` 会在检测到残留时提示并询问是否重启。

> 顺带说明 `mergeWithDevice` 里那句
> `device.headerProtection.key = d.headerProtectionKey`
> 看似"无条件赋值=会清零"，但因为 `fromDevice` 已经预填过，
> 省略该行时 `d.headerProtectionKey` 装的是**旧值**，所以清不掉。

## 4.4 常见 errno 与可操作提示

| errno | 含义 | 面板提示 |
|---|---|---|
| `-22` EINVAL | 参数不被本版本接受 | 检查 J1/J2/J3/Itime 等 v1.5 专属参数（v3 已移除） |
| `-71` EPROTO | 报文里有一行不是 `key=value` | 多半是把 `.conf` 原文当 payload 下发了；`uapi.py set` 现已自动识别并转换 |
| `-1` | socket 层失败 | 服务没起或权限不足 |
| `-13` | 数值超出内核允许范围 | |

`uapi.py set` 现在会检测 INI 格式并自动 `render`，同时对上述 errno 给出可操作提示。

## 4.5 依赖镜像（客户端编译的实际障碍）

客户端装内核同样要 `go mod download`。`proxy.golang.org` 在部分网络根本连不上，
表现是满屏 `i/o timeout` 加一句"所有编译方式均失败"，用户无从判断是网络还是代码问题。

`core.sh` 现在：
- 预取依赖，镜像链 `goproxy.cn → goproxy.io → proxy.golang.org → direct`
- `AWG_GOPROXY` 可覆盖
- 失败时打印最后 8 行真实编译错误，而不是只给一句结论

## 4.6 NAT 清理：解析 `iptables -S` 输出不能靠字符串切

`apply.sh` 原来的 `nat_del`：

```bash
iptables -t nat -D POSTROUTING -s "${line%% *}" -o "${line#*-o }" ...
```

`iptables -t nat -S POSTROUTING` 的行长这样：

```
-A POSTROUTING -s 10.66.66.0/24 -o eth0 -m comment --comment awg-panel -j MASQUERADE
```

- `${line%% *}` 截到第一个空格，得到的是 **`-A`**，不是源地址；
- `${line#*-o }` 把 `-o ` 后面**全部**内容都吃进去了（含 comment 和 `-j MASQUERADE`）。

拼出来的是 `iptables -t nat -D POSTROUTING -s -A -o eth0 -m comment ...`，
内核不认，**每次 `systemctl stop amneziawg` 都会留下一条 MASQUERADE 残留**。
实测：连续 stop 多次后规则始终还在。

正确做法是去掉 `-A POSTROUTING ` 前缀后整体回传给 `-D`（规则必须逐字一致才能匹配）：

```bash
iptables -t nat -D POSTROUTING ${line#-A POSTROUTING }
```

这条已经收敛到 `lib.sh` 的 `nat_cleanup()`，`apply.sh` 与 `uninstall.sh` 共用。
**两处各写一套、各判各的，是最难查的一类问题**——当时 `uninstall.sh` 恰好写对了，
所以"卸载能清干净、停止服务清不干净"这个不一致现象反而掩盖了 `nat_del` 的失效。

## 4.7 改 sysctl 要记原值

`nat_add` 里 `sysctl -w net.ipv4.ip_forward=1` 没有记账，卸载后机器上会留一处
没人认领的改动。现已在开之前写入 `state/sysctl.saved`，`apply_down` 还原。

> 顺带记一条同源教训（来自 CC 上 xray-browser-dialer 的实测记录）：
> `net.ipv6.conf.all.forwarding=1` 与 `net.ipv6.conf.<if>.accept_ra=0` 同时存在时，
> **一旦去改 forwarding，内核会删掉 RA 学来的默认路由**。
> 本项目只碰 `net.ipv4.ip_forward`，全程不碰 IPv6 转发，故不受影响；
> 但若将来加 IPv6 出网，这条必须先设 `accept_ra=2`。
