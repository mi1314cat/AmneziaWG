<<<<<<< HEAD
# AWG-Panel — AmneziaWG Server / Client 面板

个人 AmneziaWG 核心管理面板：**服务端节点管理 + 客户端配置生成 + LAN 代理**。
内核为 [amnezia-vpn/amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go)（AWG v3.1）。

> **AmneziaWG 是独立的 VPN Core，不是 mihomo / Xray 的一个协议模块。**
> mihomo 侧只有 **出站** `adapter/outbound/wireguard.go`，`listener/parse.go` 里没有
> `case "wireguard"` —— 它没有任何监听实现，因此不可能作为服务端存在。

- **一个统一 systemd 服务**，所有客户端共享同一个接口；`server.conf` 是唯一事实来源，UAPI 只是运行时投影。
- 服务端内核**由面板自行交叉编译**（`CGO_ENABLED=0` 静态二进制，约 3.3 MB）：官方 release 只挂源码包，不含预编译产物。
- 客户端走**纯 amneziawg-go + 源地址策略路由**，不引入 mihomo 等第三方内核。

## 一键安装（从 GitHub 拉取）

```bash
bash <(curl -Ls https://github.com/mi1314cat/AmneziaWG/raw/refs/heads/main/install.sh)
```

执行后：取码 → 依赖自检 → 进入中文管理面板。也可显式：

```bash
install.sh server|client|update|status
```

## Server

```bash
bash src/awg.sh                      # 主面板
bash src/conf/core.sh   install|update|current|latest|uninstall
bash src/conf/server.sh init|show|reload|menu
bash src/conf/node.sh   add|list|show <name>|del|regen
bash src/conf/service.sh install|start|stop|restart|reload|status|logs [n]
```

每个节点自动产出三件套（`/opt/awg-panel/amneziawg/clients/`）：

| 产物 | 用途 |
|---|---|
| `<name>.conf` | 原生 AmneziaWG 配置，手机扫码 / 官方 App 导入 |
| `<name>.mihomo.yaml` | mihomo `proxies` 片段（已在 v1.19.30 上 `mihomo -t` 校验通过） |
| `<name>.png` | 二维码，内容为 `.conf` 全文 |

## Client

```bash
bash src/client/client.sh  menu|connect|disconnect|proxy|proxy-stop|status
```

把服务端生成的 `<name>.conf` 放到 `/opt/awg-panel/amneziawg/client/client.conf`，然后 `connect`。
`proxy` 会在同一端口提供 SOCKS5 与 HTTP，出站绑定隧道地址以命中策略路由。

### 掉 SSH 防护

客户端做策略路由最容易把自己锁在门外，本项目用「结构上不可能」替代「小心一点」：

1. 主路由表全程**只读**，新路由一律写入独立表 `100`；
2. 策略规则是**源地址匹配**（`from <隧道IP>/32 lookup 100`），SSH 源地址是 LAN 地址，永远不匹配；
3. 隧道端点固定走物理网卡，避免 `default dev awgc0` 把包送回隧道自身形成环路；
4. 防火墙只加不减，只加本项目端口，不动 INPUT 默认策略，不碰 SSH 端口；
5. `rp_filter` 只在隧道接口上关闭；
6. 应用后自动做连通性自检，**不通立即回滚**；
7. 全程不使用 `pkill -f`（其模式串会出现在 sshd 子进程命令行里）。

## 实测结论

```
CC (mihomo v1.19.30) ──AWG UDP/41871──> RN (amneziawg-go v3.1.20260828) ──> Internet
```

| 项目 | 结果 |
|---|---|
| 握手 / HTTPS / SOCKS5 / HTTP | PASS（出口 `107.173.154.178`） |
| 服务端内存占用 | RSS ≈ 13 MB |
| 重启自恢复 | PASS（`ExecStartPost` 自动重下 UAPI + 策略路由） |
| 对既有服务的影响 | 无（Docker / mihomo / sing-box / xray / nginx 全部不受影响） |

踩坑记录见 [`research/param-reference.md`](research/param-reference.md)，
架构设计见 [`design/architecture-design.md`](design/architecture-design.md)。
=======
# AmneziaWG
>>>>>>> 4564b233c3daad2c3059d0ef350aa24b89b225dd
