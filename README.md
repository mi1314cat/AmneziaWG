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

执行后：取码 → 依赖自检 → 下载通道选择 → 进入中文管理面板。也可显式：

```bash
install.sh server|client|update|status
```

### 本机代理已开、但 curl 到 GitHub 超时

很多机器把代理只写在 `/etc/profile.d/` 里，而非登录 shell 不加载该文件
（`ssh host 'cmd'`、面板内执行、定时任务），于是**本机明明开着代理，下载却走直连直到超时**。

`install.sh` 会探测本机常见代理端口并列出可用的通道让你选（直接回车 = 直连）。
探测范围除 `127.0.0.1` / `localhost` 外，**还包括本机自己的 LAN IP**——
不少服务（如 Xray）默认绑在网卡地址上而不是回环，只扫回环会漏掉。

选中的通道会写入 `state/proxy.env`，之后从面板里跑 `core.sh`（编译内核要下
Go 工具链与模块）也走同一条通道。

> **注意先有鸡先有蛋**：上面那条一键命令本身就要先 curl 到 GitHub 才拿得到 `install.sh`。
> 如果本机直连不了 GitHub，先设好代理再执行：
>
> ```bash
> export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
> bash <(curl -Ls https://github.com/mi1314cat/AmneziaWG/raw/refs/heads/main/install.sh)
> ```
>
> 代理地址按你自己的实际端口替换（`curl --proxy http://<地址>:<端口> https://github.com` 可自测）。

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

## 端口回避

本机服务多时端口冲突是常态，所以面板**不写死端口**：

- 客户端 LAN 代理优先用 `AWG_PROXY_PORT` → 上次记住的 (`state/proxy.port`)，
  两者都没有才从 20000-60000 里挑一个空闲的；选中的端口会落盘，
  下次启动不变，不会天天跳
- 端口被别人占住时自动换一个空闲的，并打印占用方，不会直接失败
- 服务端 `server.sh init` 的监听端口同样默认取空闲端口

## 配置下发（服务端 → 客户端）

客户端原本只能手动把 `.conf` 放过去。现在服务端可生成一次性下发链接，
客户端一条命令拉回并落盘：

```bash
# 服务端: 主面板 8) 配置下发  →  1) 生成下发链接
#   默认限次 1 次、24 小时有效
# 客户端:
bash src/client/client.sh pull http://<服务端IP>:9393/share/<token>
```

服务端跑 `share_server.py`（双栈监听，IPv4/IPv6 客户端都能连），token 为
128-bit 随机数，支持限次 / 有效期 / 手动禁用，多客户端同时拉用 `flock` 串行化计数。
主服务未运行或配置不可用时返回 503 且**不**消耗额度。

> ⚠️ **该 `.conf` 内含节点私钥**，会在网络上走一遍。默认「限次 1 + 24 小时」，
> 拉一次即作废，用来把暴露窗口压到最小；请勿公开转发。
> 私钥绝不出机器的做法是客户端本地生成密钥、只把公钥注册到服务端，本项目未实现。

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