# Phase 1 架构设计 — AWG-Panel 独立 AmneziaWG 管理项目

> **一个内核 + 一个 systemd service + 一个接口 + 多个 peer（客户端节点）。**
> 技术基线：`amneziawg-go` **v3.1.20260828**（用户态，零内核依赖）。
> 风格对齐 `sing-box-core`（`install.sh` + `src/sing-box.sh` 面板 + `src/conf/*.sh` 模块 + `src/client/client.sh` 客户端面板）。

**本项目不是 mihomo/xray 的一个协议模块。** 它是独立 VPN Core：
独立安装、独立服务、独立生成客户端，但**输出 Mihomo 客户端配置**（mihomo 是消费方，不是宿主）。

---

## 0. 设计前置：已实测确认的技术事实（非抄文档）

以下每条都来自本机 / RN / CC 的源码阅读与实测，构成本项目的设计约束。

### 0.1 Mihomo 只能做 AmneziaWG **客户端**，不能做服务端

| 证据 | 结论 |
|---|---|
| `MetaCubeX/mihomo` `listener/parse.go` 的 `case` 列表中**没有** `"wireguard"` | mihomo **无 WireGuard/AmneziaWG listener** |
| 全仓库 `grep -ril amnezia` 只命中 `adapter/outbound/wireguard.go` | AWG 仅存在于 **outbound** |
| `constant/adapters.go` 有 `WireGuard` 常量，但仅用于出站适配器注册 | 服务端侧无对应实现 |

**推论（决定整个架构）**：服务端**不能**用 mihomo。必须独立部署 `amneziawg-go` 或 AmneziaWG 内核模块。
Mihomo 在本项目中的角色降级为**一种客户端输出的目标格式**。

### 0.2 amneziawg-go 的 UAPI 契约（踩坑点，必须固化进 `lib.sh`）

`amneziawg-go` 不读 ini 文件，只接受 **UAPI over unix socket**：
`/var/run/amneziawg/<iface>.sock`

| 事实 | 说明 |
|---|---|
| **密钥是 hex，不是 base64** | `private_key` / `public_key` / `preshared_key` / `header_protection_key` 全部 `loadExactHex`；传 base64 直接 `errno=-22` |
| `set` 操作**必须客户端半关闭** | 服务端 `io.MultiReader` 读到 EOF 才处理；不 `shutdown(SHUT_WR)` 会永久阻塞 |
| `get` 操作**必须多发一个 `\n`** | 处理器读完 `get=1\n` 后还要再读一个字节且必须是 `\n`，否则直接 return |
| **`h1`-`h4` 是 uint32 或 `N-M` 区间** | AWG v3 起不再是 base64 magic header；传 base64 → `errno=-22` |
| `protocol_version` 恒为 `1` | v3.x 不再用它区分大版本 |
| **v1.5 专属参数在 v3 中不存在** | `j1` / `j2` / `j3` / `itime` 在 v3 的 UAPI 中不存在，传了报 `errno=-22` |
| **Header Protection 有硬前置** | `HeaderCipherNonceSize = 12`，启用 `header_protection_key` 时 **S1/S2/S3/S4 必须全部 ≥ 12**，否则 `errno=-22`（错误信息不友好，必须在脚本层提前拦） |

### 0.3 服务端网络的两个必做项（否则握手成功但单向不通）

```
ip addr add 10.66.66.1/32 dev awgt0     # 只加地址
```
**不会**自动生成到客户端的回程路由。缺 `ip route add 10.66.66.2/32 dev awgt0` 时：
握手成功、`rx_bytes` 增长，但 MASQUERADE 回包在内核找不到下一跳 → **客户端 SYN 无响应**。
这是本次实测踩到的最大坑，已在实测中确认（补路由后立刻出网）。

### 0.4 E2E 实测结论（RN + CC）

```
CC (Armbian 24.5, arm64, mihomo v1.19.30)
  └─ mihomo wireguard outbound + amnezia-wg-option{version:3}
       └─ AWG tunnel (UDP/41871)
            └─ RN (Debian 13, amd64, amneziawg-go v3.1.20260828)
                 └─ Internet
```

| 项目 | 结果 |
|---|---|
| 握手 | PASS（`last_handshake_time_sec` 持续刷新） |
| HTTPS + 出口 IP | PASS（出口 = RN `107.173.154.178`） |
| SOCKS5 | PASS |
| DoH / DNS | PASS |
| IPv4 出口 | PASS |
| 吞吐（1MB 下载） | PASS（~734 KB/s，链路上行受限） |
| 服务端内存占用 | **~13 MB RSS**（1 vCPU / 967 MB 内存的 RN 上实测） |
| 客户端依赖内核模块 | **不需要**（`/dev/net/tun` + `CAP_NET_ADMIN` 即可） |

### 0.5 服务端实现选型结论

| 方案 | 结论 | 依据 |
|---|---|---|
| **`amneziawg-go`（用户态）** | ✅ **默认方案** | RN 无 `6.12.107+deb13-amd64` 内核头文件，DKMS 编译不可行；用户态零内核依赖，RSS ~13 MB，跨发行版 |
| AmneziaWG 内核模块（DKMS） | ⚠️ 备选 | 性能更好，但需要匹配内核头 + gcc，Debian 13 定制内核上易失败；保留为 `core.sh` 的可选通道 |

官方 release 无预编译二进制（`amneziawg-go` releases 仅源码包），因此 **`core.sh` 需要内置交叉编译流程**：
用 `golang:1.27` 容器或本机 Go 做 `CGO_ENABLED=0 GOOS=linux GOARCH=<arch>` 静态编译，产出 ~3.4 MB 单文件二进制。
本次已验证该流程可行（amd64 产物 3.4 MB，静态链接）。

---

## 1. 项目定位与边界

| | 本项目负责 | 不负责 |
|---|---|---|
| **Server** | VPS 上安装/管理 AmneziaWG 服务端、生成 peer、监听端口、NAT | 不做协议伪装之外的加速 |
| **Client 产物** | 生成 `client-NNN.conf`（原生）、`client-NNN.mihomo.yaml`、`client-NNN.png` | 不托管、不分发 |
| **Client 运行** | 客户端面板：装 AWG 客户端、开 VPN 或开 LAN 代理 | 不改 mihomo 现有生产配置 |
| **明确不做** | 不生成 mihomo `listeners:`（AWG 无 listener）；不与 mihomo-core 互相依赖 | |

---

## 2. 目录结构

### 2.1 仓库（对齐 sing-box-core）

```
AmneziaWG/
├── install.sh                  # 一键入口: 取码 → 初始化 → 进入面板
├── uninstall.sh                # 独立卸载入口
├── update.sh                   # 拉取新版本 (core.sh 亦可交互更新)
├── status.sh                   # 独立状态查看
├── README.md
├── design/
│   └── architecture-design.md  # 本文件
├── research/
│   ├── mihomo-awg-support.md   # §0.1/§0.2 全部证据与复现方法
│   ├── server-impl-choice.md   # §0.5 选型对比与实测数据
│   └── param-reference.md      # AWG 参数逐项实测表 (RN 上逐个 UAPI 试出来的)
├── src/
│   ├── awg.sh                  # 主入口面板 (菜单 + 子命令)
│   ├── conf/
│   │   ├── lib.sh              # 公共库
│   │   ├── core.sh             # 内核安装/更新/卸载/版本
│   │   ├── server.sh           # 服务端实例管理 (参数/子网/端口/peer 热更新)
│   │   ├── node.sh             # 客户端节点 CRUD + 三种产物生成
│   │   ├── params.sh           # 混淆参数选配 + 前置校验 (S>=12 等)
│   │   ├── qr.sh               # 二维码 (PNG + 终端)
│   │   ├── batch.sh            # 批量生成
│   │   ├── to_mihomo.py        # 产物转换/规范化
│   │   └── fw.sh               # 端口放行 (ufw/firewalld/iptables)
│   └── client/
│       └── client.sh           # 客户端面板 (VPN 模式 / LAN 代理模式)
├── test/                       # e2e / 回归脚本
└── test-results/
```

### 2.2 服务端运行时（对齐 xary-core 根在 `/opt`）

```
/opt/awg-panel/amneziawg/
├── bin/
│   ├── amneziawg-go            # 内核二进制 (静态)
│   └── version                 # 版本锚点 (单一 state 来源)
├── server/
│   └── server.conf             # ★ 唯一事实来源: 参数 + 端口 + 子网 + peer 列表
├── clients/
│   ├── client-001.conf         # 原生 AmneziaWG 配置 (手机扫码导入)
│   ├── client-001.mihomo.yaml  # mihomo proxies 片段
│   ├── client-001.png          # 二维码 (client-001.conf 的 QR)
│   └── client-001.qr.txt       # 终端二维码文本缓存
├── keys/
│   └── client-001/             # priv/pub 分开存, 0600
├── logs/
├── state/
│   └── .fw-ports               # 放行端口清单 (卸载按清单清理)
└── backup/
```

> **`server.conf` 是状态，`UAPI` 是运行时。**
> `amneziawg-go` 不读 ini，所以必须自己维护 ini 并渲染成 UAPI。
> `server.sh` 的所有写操作 = 改 `server.conf` → 渲染 UAPI → 校验 → 应用 → 落盘。

---

## 3. 服务模型（单 service）

```
/etc/systemd/system/amneziawg.service
[Unit]
Description=AmneziaWG server (awg-panel)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
Environment=LOG_LEVEL=verbose
ExecStart=/opt/awg-panel/amneziawg/bin/amneziawg-go -f awg0
ExecStartPost=/opt/awg-panel/amneziawg/src/conf/apply.sh up      # 建路由/地址 + UAPI 下发
ExecStopPost=/opt/awg-panel/amneziawg/src/conf/apply.sh down
Restart=always
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
```

- **绝不每个协议/节点开一个 service**：所有客户端 = 同一个 `awg0` 上的多个 peer。
- 用户要求的 `systemctl status amneziawg` 直接可用；`awg.sh service <start|stop|restart|status|log|enable>` 为脚本侧同义入口。

---

## 4. `conf/lib.sh` 公共库（收敛 sing-box-core 的同类函数）

- **UI**：`print_title / print_info / print_ok / print_warn / print_error`（全部 stderr，可被 source）
- **输入**：`clean_input / safe_read / safe_read_port`
- **端口冲突**（需求 §10 强制）：`port_state <port>` 返回 `free|tcp|udp|both` + 占用进程名；
  `pick_free_port <范围>` 自动避让；**任何情况下不覆盖已有服务**
- **LAN IP**：`lan_ip()`（`ip route get 1.1.1.1` 取 src）
- **密钥**：`gen_wg_keypair` → base64（给 `.conf` / mihomo）+ hex（给 UAPI），**成对产出，禁止混用**
- **AWG 参数**：`random_uint32`、`random_h_set`（生成互不相同的 h1..h4）、`validate_awg_params`
  （含 **S≥12 才能开 Header Protection** 这条前置）
- **UAPI 客户端**：`awg_uapi_set <iface> <payload>` / `awg_uapi_get <iface>`
  —— 已实现并实测（含半关闭、get 多余换行、hex 密钥三条硬规则）
- **通用落盘流程**：`write_state()` → 渲染 UAPI → 应用 → 失败回滚 `server.conf` → 校验 service active

---

## 5. `conf/core.sh` 内核与版本管理

- **安装**：检测架构（amd64/arm64）→ 交叉编译 `amneziawg-go`（`CGO_ENABLED=0` 静态）
  → 优先本地 `go`，否则用 `golang` 容器编译 → 产物 ~3.4 MB → 原子替换 → 记录 `bin/version`
- **版本**：`current` / `latest`（releases.atom 取最新 tag）/ `install <tag>`
- **更新（事务化）**：备份 `server.conf` + `clients/` + 二进制 → 编译新版 → 用新二进制做一次
  UAPI 干跑校验 → 失败不动现网 → 成功原子替换 + restart
- **卸载**：停 service → 删接口 → 按 `state/.fw-ports` 清端口 → 删目录（`clients/` 按 `--purge` 决定是否保留）

---

## 6. `conf/server.sh` 服务端实例管理

菜单/子命令：`add | list | del | modify | regen | show`

### 6.1 `server.conf` 格式（ini，对齐 WireGuard 习惯 + AWG 扩展）

```ini
[Interface]
Address    = 10.66.66.1/24
ListenPort = 41871
PrivateKey = <hex>            # 内部 hex；对外展示用 base64
DNS        = 1.1.1.1, 9.9.9.9
MTU        = 1280

# ---- AWG 混淆参数 ----
Jc = 5
Jmin = 40
Jmax = 70
S1 = 0
S2 = 15
S3 = 0
S4 = 0
H1 = 523
H2 = 880
H3 = 460
H4 = 342

# ---- v3 高级 (默认全部关闭, 见 §9) ----
ContentPaddingAddition =
HeaderProtectionKey    =
RandomTrailers         = false
DisableCookies         = false

[Peer]                        # 每个客户端一段, 名字即 client-NNN
PublicKey = <hex>
AllowedIPs = 10.66.66.2/32
```

### 6.2 参数选配策略（需求 §15 的"不要一次开满"）

新增节点/新建实例时**默认只开基础混淆**：
`Jc + Jmin/Jmax + S1..S4 + H1..H4`。
v3 高级参数全部留空，由用户在 `params.sh` 里**显式开启**，且开启 Header Protection 时脚本**强制提示**
必须先把 S1–S4 提到 ≥ 12（否则运行时报 `errno=-22`）。

---

## 7. `conf/node.sh` 客户端节点管理（产物生成 = 本项目核心）

子命令：`add | list | del | modify | regen | show`

每创建一个客户端，**自动产出三件套 + 一个 QR**：

### 7.1 原生 AmneziaWG 配置 `client-001.conf`

```ini
[Interface]
PrivateKey = <base64>        # 官方客户端读 base64
Address    = 10.66.66.2/32
DNS        = 1.1.1.1, 9.9.9.9
MTU        = 1280

[Peer]
PublicKey  = <base64>        # 服务端公钥
PresharedKey =
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint   = 203.0.113.10:41871
PersistentKeepalive = 25

# ---- AWG 参数 (官方客户端同名) ----
Jc = 5
Jmin = 40
Jmax = 70
S1 = 0
S2 = 15
S3 = 0
S4 = 0
H1 = 523
H2 = 880
H3 = 460
H4 = 342
```
> **待实测确认**：AWG 官方 App 的 QR 载荷是"整份 ini 文本"还是某个 URI scheme。
> 本次未拉到 App 源码，Phase 2 必须在真机扫码验证后再定 `qr.sh` 的载荷格式。

### 7.2 Mihomo 配置 `client-001.mihomo.yaml`

严格按 §0.1/§0.2 实测出的字段：

```yaml
proxies:
  - name: AWG-client-001
    type: wireguard
    server: 203.0.113.10
    port: 41871
    ip: 10.66.66.2/32            # 必填, 缺则 "missing local address"
    private-key: <base64>
    public-key: <base64>        # 服务端公钥 (peer)
    allowed-ips: [0.0.0.0/0, ::/0]
    udp: true
    mtu: 1280
    persistent-keepalive: 25
    amnezia-wg-option:
      version: 3                # 3 → v3 实现; 其它值 → v1 实现
      jc: 5
      jmin: 40
      jmax: 70
      s1: 0
      s2: 15
      s3: 0
      s4: 0
      h1: 523                   # 字符串, 数字或 "lo-hi"
      h2: 880
      h3: 460
      h4: 342
      # v3 高级 (可选, 与服务端一一对应)
      # content-padding-addition: 10-100
      # random-trailers: true
      # disable-cookies: true
      # header-protection-key: <base64>
```

**生成后必须过 `mihomo -t -f` 校验**（本项目在客户端面板调用）。

### 7.3 二维码 `client-001.png`

- 依赖 `qrencode`；`apt install qrencode`
- 终端直接显示：`qrencode -t ANSIUTF8 < client-001.conf`
- 存图：`qrencode -o clients/client-001.png -l L < client-001.conf`
- 载荷格式待 Phase 2 真机验证（§7.1 注）

---

## 8. 客户端面板 `src/client/client.sh`

对齐 `sing-box-core/src/client/client.sh` 的结构（`ui_*` 宽度自适应、`port_state` 占用检测、
`do_service_install` 常驻 unit、`apply_change` 事务化改配置）。

### 8.1 两种运行模式（需求 §11）

| 模式 | 链路 | 组成 | 额外依赖 |
|---|---|---|---|
| **A. 纯 VPN** | `设备 → awg0(TUN) → Internet` | `amneziawg-go` + TUN + 默认路由/策略路由 | 无 |
| **B. 局域网代理** | `LAN 设备 → SOCKS/HTTP → mihomo(AWG) → RN` | `amneziawg-go`(可选) + **mihomo** | mihomo |

**模式 B 复用 mihomo 的理由**：mihomo 原生支持 AWG（§0.1 已实测），一次给出
SOCKS5 + HTTP + 分流 + Web UI；且用户 CC 上本来就有 mihomo。
面板**不接管**用户已有的 mihomo 实例——AWG-Panel 自建独立 instance（独立 `-d` 目录、独立端口、独立 unit），
彻底避免碰 `ALS.yaml` 这类生产配置。

> 备选（若要彻底去 mihomo 化）：`amneziawg-go` + 按 UID 的策略路由 + 轻量 SOCKS5/HTTP 转发。
> 列入 Phase 5 可选项，Phase 1–4 不做。

### 8.2 面板功能（需求 §7）

`安装客户端 / 启动 / 停止 / 重启 / 状态 / 设置代理端口 / 开启LAN / 生成配置 / 显示二维码 / 节点管理`

### 8.3 端口与 LAN（需求 §8 §9 §10）

| 用途 | 默认 | 说明 |
|---|---|---|
| SOCKS5 | `7891` | 独立监听 |
| HTTP | `7892` | 独立监听 |
| 控制面板(Web UI) | `9091` | 避开 mihomo 常用 9090 |

- `allow-lan` 开关 → 控制 `BIND_LAN` = `127.0.0.1` / `0.0.0.0` / 指定 LAN IP
- 启动前**三个端口全部检测**；冲突时给"自动换端口 / 手动指定"二选一，**绝不覆盖已有服务**
- 面板首页打印 LAN 访问地址：`http://<lan_ip>:9091`，并给出手机/电视可直接填的 `192.168.x.x:7891`

---

## 9. `conf/params.sh` 参数选配与前置校验

| 参数组 | 默认 | 开启条件 |
|---|---|---|
| `Jc / Jmin / Jmax / S1..S4 / H1..H4` | **开**（基础混淆） | 无条件 |
| `ContentPaddingAddition` | 关 | 显式开启 |
| `HeaderProtectionKey` | 关 | **必须 S1–S4 ≥ 12**，脚本提前拦截并提示 |
| `RandomTrailers` / `DisableCookies` | 关 | AWG **v3.1+**，需服务端与 mihomo 同为 v3.1 |
| `RekeyAfterTime / RekeyTimeout / RejectAfterTime / KeepaliveTimeout / MaxHandshakeAttempts` | 关 | 显式开启 |
| `i1..i5 / j1..j3 / itime` | **不提供** | j1–j3/itime 是 v1.5 专属，v3 已移除；i 系列仅在需要时才暴露 |

---

## 10. 验证与安全网（贯穿所有写路径）

1. `server.conf` 结构校验（`awk`/python ini 解析，段与键齐全）
2. **UAPI 干跑**：新配置先下发到临时接口名验证 `errno=0`，再切到生产接口
3. 应用后校验：`awg_uapi_get` 回读，确认 `listen_port` / `jc` / 各 peer 存在
4. 失败：`server.conf` 回滚 + service restart 旧配置 + 明确报错（不透传裸 `errno=-22`）
5. mihomo 产物：`mihomo -t` 校验后才写 `clients/`

---

## 11. 开发阶段计划

| Phase | 内容 | 出口标准 |
|---|---|---|
| **Phase 1** | 本架构 + `research/` 三份证据文档 | ✅ 完成 |
| **Phase 2** | `install.sh` + `core.sh`(交叉编译) + `lib.sh`(UAPI 客户端) + 单 service + `server.sh` | RN 上 `systemctl status amneziawg` active，`awg_uapi_get` 参数正确 |
| **Phase 3** | `node.sh` 三件套产物 + `params.sh` 校验 | RN 生成 client-001，**原生客户端**扫码/导入成功连通 |
| **Phase 4** | `client.sh` 模式 A（VPN）+ 模式 B（LAN 代理）+ 端口冲突处理 | CC 上 SOCKS5/HTTP 出网，出口 IP = RN |
| **Phase 5** | `qr.sh` + `batch.sh` + `to_mihomo.py` + 高级参数逐项回归 | 批量 10 客户端全通；v3.1 参数逐项 PASS/FAIL 记录进 `test-results/` |
| **Phase 6** | README + 发布 | `bash <(curl -fsSL .../install.sh)` 一键可用 |

---

## 12. 待实测确认清单（不猜，进 Phase 2/3 逐条落地）

1. AWG 官方 App 的 **QR 载荷格式**（整份 ini？还是有 URI scheme？）
2. `client-NNN.conf` 中 `Jc/Jmin/Jmax/S1..S4/H1..H4` 的**官方拼写**与 v1.5/v3 差异
3. mihomo `version` 取 `3` 时，**v3.1** 特性（random-trailers/disable-cookies）与官方 v3.1 服务端的互通性
4. `amneziawg-go` 官方是否有预编译二进制通道（目前 releases 仅源码包）
5. 内核模块方案在**标准 Debian/Ubuntu** 上的可行性（RN 因缺头文件已排除）

---

## 附：与 mihomo-core 的关系

```
mihomo--core (现有, 不再改动 AWG 相关)
  └── 继续只做 mihomo 作为 Server 的那 6 个协议

AmneziaWG (本项目, 独立)
  ├── Server: amneziawg-go (独立 systemd service)
  ├── Client 产物: client-NNN.conf / client-NNN.mihomo.yaml / client-NNN.png
  └── Client 运行: 独立 mihomo instance (仅复用格式, 不复用服务)
```