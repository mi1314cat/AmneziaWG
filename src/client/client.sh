#!/usr/bin/env bash
# ==============================================================
# client.sh — AWG-Panel 客户端 (VPN 模式 + LAN 代理模式)
#
# ============ 掉 SSH 防护: 这是本文件的第一设计约束 ============
# 客户端做策略路由时最容易把自己锁在门外。本面板用"结构上不可能掉"来替代"小心一点":
#
#  1) 主路由表 (main) 全程只读。新路由一律写进独立表 RT_TABLE(默认 100)。
#     -> 不存在"改错 default 把 SSH 吞掉"的可能。
#  2) 策略路由用 **源地址匹配**: ip rule from <隧道IP>/32 lookup 100
#     只有源地址是隧道 IP 的包才会走隧道。本机 SSH 的源地址是 LAN 地址, 永远不匹配。
#  3) 代理出站显式 bind() 到隧道 IP —— 即"你选择走隧道"才走隧道。
#     默认 --src-ip 为空 = 直连, 不会误接管系统流量。
#  4) 防火墙只做"加", 且只加本项目自己的端口; 绝不改 INPUT 默认策略, 绝不碰 SSH 端口。
#  5) rp_filter 只在隧道接口上关 (默认 mode 1 的反向路径校验会丢弃策略路由的非对称包),
#     不动 all/default。
#  6) 应用后跑一次连通性自检; 不通立即自动回滚并提示。
#  7) 全程不 pkill -f —— 只 pkill -x 或按 systemd unit 操作。
#     (pkill -f 的模式串会出现在 sshd 的子进程命令行里, 历史上就是这么把自己踢下线的)
# ==============================================================
set -uo pipefail

CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWG_SRC="$CLIENT_DIR/../conf"
[[ -f "$AWG_SRC/lib.sh" ]] && . "$AWG_SRC/lib.sh"
RED="${RED:-\e[31m}"; GREEN="${GREEN:-\e[32m}"; YELLOW="${YELLOW:-\e[33m}"
CYAN="${CYAN:-\e[96m}"; MAGENTA="${MAGENTA:-\e[95m}"; RESET="${RESET:-\e[0m}"

C_ROOT="${AWG_ROOT:-/opt/awg-panel/amneziawg}"
C_BIN="$C_ROOT/bin/amneziawg-go"
C_CLIENT_DIR="$C_ROOT/client"
C_IFACE="${AWG_CLIENT_IFACE:-awgc0}"     # 客户端接口名, 与服务端 awg0 区分
C_UNIT="${AWG_CLIENT_UNIT:-amneziawg-client}"
C_UNIT_FILE="/etc/systemd/system/$C_UNIT.service"
C_TABLE="${AWG_RT_TABLE:-100}"          # 专用路由表, 与 main 隔离
C_RULE_PRIO="${AWG_RULE_PRIO:-100}"
C_CONF="$C_CLIENT_DIR/client.conf"
C_PROXY_PY="$CLIENT_DIR/proxy.py"

C_PROXY_PORT="${AWG_PROXY_PORT:-7891}"
C_PROXY_HOST="127.0.0.1"
C_PROXY_ENABLED=false
C_PROXY_SRC=""                           # 空 = 直连; 填隧道 IP = 走隧道

# ---------- 解析 client.conf ----------
cget() { grep -E "^$1\s*=" "$C_CONF" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
c_srv_ip()   { cget Address | cut -d/ -f1; }
c_endpoint() { cget Endpoint | cut -d: -f1; }
c_ep_port()  { cget Endpoint | cut -d: -f2; }

# ==============================================================
# 连通性自检 (回滚看门狗)
# ==============================================================
default_gw() {
    # "default via 192.168.1.1 dev eth0 ..." 里 $3 是网关、$5 是**设备名**。
    # 之前按位置取 $5, 拿 eth0 去 ping, 必然失败 -> 自检恒为不通 -> 每次都误回滚。
    ip route show default 2>/dev/null |
        awk '/^default/ {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
}

net_alive() {
    # 任一探针通过即认为连通。刻意**不**只依赖 ping 公网:
    # 直连公网常被上游策略挡掉(实测 CC 上 TCP 1.1.1.1:443 不通),
    # 拿它当唯一判据会造成"明明好好的却判定失联"的假回滚。
    local gw; gw=$(default_gw)
    if [[ -n "$gw" ]] && ping -c1 -W2 "$gw" >/dev/null 2>&1; then return 0; fi

    local ep port; ep=$(c_endpoint); port=$(c_ep_port)
    if [[ -n "$ep" ]] && [[ "$port" =~ ^[0-9]+$ ]]; then
        timeout 5 bash -c "cat < /dev/null > /dev/tcp/$ep/$port" 2>/dev/null && return 0
    fi
    timeout 5 bash -c 'cat < /dev/null > /dev/tcp/1.1.1.1/443' 2>/dev/null && return 0
    getent hosts example.com >/dev/null 2>&1 && return 0
    return 1
}

guard_rollback() {   # $1=回滚函数名; 应用完成后调用
    local undo="$1"
    sleep 2
    if net_alive; then
        print_ok "连通性自检通过"
        return 0
    fi
    print_error "连通性自检失败, 正在自动回滚以避免失联"
    "$undo"
    sleep 1
    if net_alive; then
        print_ok "已回滚, 网络恢复正常"
    else
        print_error "回滚后仍不通 —— 请用本地控制台检查, 不要继续操作"
    fi
    return 1
}

# ==============================================================
# 策略路由 (只写专用表, 主表只读)
# ==============================================================
route_apply() {
    local cip="$1"
    # 清掉可能残留的同名规则/路由(精确匹配本项目自己的, 不动别人的)
    ip rule del from "$cip/32" lookup "$C_TABLE" priority "$C_RULE_PRIO" 2>/dev/null
    ip route flush table "$C_TABLE" 2>/dev/null

    # 隧道出口: 端点走物理网卡(否则会自己给自己发包形成环路)
    local ep; ep=$(c_endpoint)
    local via
    via=$(ip route get "$ep" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')

    if [[ -n "$via" && "$via" != "$C_IFACE" ]]; then
        # 端点必须用物理网卡出去 —— 这一条同时保住了 SSH
        ip route add "$ep/32" dev "$via" table "$C_TABLE"
        print_info "隧道端点 $ep 固定经 $via 物理网卡 (防环路/防自锁)"
    fi
    ip route add default dev "$C_IFACE" table "$C_TABLE"
    ip rule add from "$cip/32" lookup "$C_TABLE" priority "$C_RULE_PRIO"
    print_info "策略路由: from $cip/32 lookup $C_TABLE (主路由表未改动)"
}

route_remove() {
    local cip; cip=$(c_srv_ip)
    [[ -n "$cip" ]] && ip rule del from "$cip/32" lookup "$C_TABLE" priority "$C_RULE_PRIO" 2>/dev/null
    ip route flush table "$C_TABLE" 2>/dev/null
    print_info "策略路由已清除"
}

rollback_all() {
    route_remove
    ip link set "$C_IFACE" down 2>/dev/null
    systemctl stop "$C_UNIT" 2>/dev/null
    [[ "$C_PROXY_ENABLED" == "true" ]] && systemctl stop "${C_UNIT}-proxy" 2>/dev/null
    return 0
}

# ==============================================================
# 客户端 systemd 单元
# ==============================================================
unit_install() {
    root_only
    [[ -x "$C_BIN" ]] || { print_error "内核缺失: $C_BIN"; return 1; }
    cat > "$C_UNIT_FILE" <<EOF
[Unit]
Description=AWG-Panel client tunnel (AmneziaWG)
Documentation=https://github.com/mi1314cat/AmneziaWG
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=LOG_LEVEL=verbose
ExecStart=$C_BIN -f $C_IFACE
ExecStartPost=$CLIENT_DIR/capply.sh up
ExecStopPost=$CLIENT_DIR/capply.sh down
Restart=always
RestartSec=3
LimitNOFILE=1048576
StandardOutput=append:/var/log/${C_UNIT}.log
StandardError=append:/var/log/${C_UNIT}.err

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$C_UNIT" >/dev/null 2>&1
    print_ok "客户端服务已安装: $C_UNIT"
}

# ==============================================================
# 接口
# ==============================================================
iface_up() {
    [[ -f "$C_CONF" ]] || { print_error "缺少客户端配置: $C_CONF"; return 1; }
    [[ -x "$C_BIN" ]]  || { print_error "未安装内核: $C_BIN"; return 1; }
    local cip; cip=$(c_srv_ip)
    [[ -n "$cip" ]] || { print_error "client.conf 的 Address 无效"; return 1; }
    systemctl start "$C_UNIT" || return 1
    bash "$CLIENT_DIR/capply.sh" up
}

iface_down() {
    systemctl stop "$C_UNIT" 2>/dev/null     # ExecStopPost 会清策略路由
    bash "$CLIENT_DIR/capply.sh" down 2>/dev/null
    print_ok "隧道已断开"
}

# ==============================================================
# LAN 代理
# ==============================================================
proxy_service_file() {
    cat > "/etc/systemd/system/${C_UNIT}-proxy.service" <<EOF
[Unit]
Description=AWG-Panel client LAN proxy (SOCKS5/HTTP)
After=network.target ${C_UNIT}.service
Wants=${C_UNIT}.service

[Service]
Type=simple
ExecStart=$(command -v python3) $C_PROXY_PY --port $C_PROXY_PORT --host $C_PROXY_HOST --src-ip $C_PROXY_SRC
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

proxy_start() {
    # port_state 返回 0 == "端口空闲"。所以"被占用"是取反, 不能写成
    # `port_state X && 报错` —— 那会在端口空闲时报错(实测 7891 空闲却报"已被占用")。
    if ! port_state "$C_PROXY_PORT"; then
        print_error "端口 $C_PROXY_PORT 已被占用: $(port_desc)"
        print_info "占用方: ${PORT_WHO:-未知}"
        print_info "可换端口后重试, 或用 client.sh 菜单 5) 重新设置"
        return 1
    fi
    C_PROXY_SRC=$(c_srv_ip)
    proxy_service_file
    systemctl daemon-reload
    systemctl enable "${C_UNIT}-proxy" >/dev/null 2>&1
    systemctl start "${C_UNIT}-proxy"
    sleep 2
    systemctl is-active --quiet "${C_UNIT}-proxy" ||
        { print_error "代理启动失败"; journalctl -u "${C_UNIT}-proxy" -n 10 --no-pager >&2; return 1; }
    C_PROXY_ENABLED=true
    print_ok "LAN 代理已启动"
    print_info "  SOCKS5 / HTTP : ${C_PROXY_HOST}:${C_PROXY_PORT}"
    print_info "  出口源地址   : ${C_PROXY_SRC} (命中策略路由走隧道)"
}

proxy_stop() {
    systemctl stop "${C_UNIT}-proxy" 2>/dev/null
    systemctl disable "${C_UNIT}-proxy" 2>/dev/null
    rm -f "/etc/systemd/system/${C_UNIT}-proxy.service"
    systemctl daemon-reload 2>/dev/null
    C_PROXY_ENABLED=false
    print_ok "LAN 代理已停止"
}

proxy_lan() {   # allow-lan: 监听所有网卡
    local p; p=$(safe_read_port "$C_PROXY_PORT" "both")
    C_PROXY_PORT="$p"
    C_PROXY_HOST="0.0.0.0"
    if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$p/tcp" >/dev/null 2>&1
    elif have iptables; then
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$p" -m comment --comment awg-panel -j ACCEPT
    fi
    print_warn "已允许 LAN 访问 ${p}/tcp —— 请确认所在网络可信"
}

# ==============================================================
# 菜单
# ==============================================================
# 客户端与服务端的本质区别: 客户端没有服务端配置/节点, 它消费的是别人给的 client.conf
conn_status() {
    local up="已断开"
    [[ -S "/var/run/amneziawg/$C_IFACE.sock" ]] && up="已连接"
    echo -e "${CYAN}隧道:${RESET}   $up"
    if [[ -f "$C_CONF" ]]; then
        echo -e "${CYAN}本机地址:${RESET} $(c_srv_ip)"
        echo -e "${CYAN}服务端:${RESET}   $(c_endpoint):$(c_ep_port)"
    fi
    echo -e "${CYAN}代理:${RESET}   $(systemctl is-active "${C_UNIT}-proxy" 2>/dev/null || echo 未运行) ${C_PROXY_HOST}:${C_PROXY_PORT}"
    echo -e "${CYAN}策略路由:${RESET}"
    ip rule show 2>/dev/null | grep "lookup $C_TABLE" | sed 's/^/  /' || echo "  (未安装)"
}

connect_flow() {
    print_title "建立隧道"
    [[ -f "$C_CONF" ]] || { print_error "请先把服务端生成的 .conf 放到 $C_CONF"; return 1; }
    print_info "以下改动不会触碰主路由表与 SSH 连通性, 但仍会做自检与自动回滚"
    yes_no "继续" y || return 0
    # 每次连接都重写 unit: 面板升级后(比如新增 ExecStartPost)能立刻生效,
    # 否则旧 unit 会一直留在磁盘上, 表现为"重启后配置丢失却查不出原因"。
    unit_install >/dev/null
    iface_up && guard_rollback rollback_all
}

core_ensure() {
    if [[ -x "$C_BIN" ]]; then
        print_ok "内核已就绪: $(cat "$C_ROOT/bin/version" 2>/dev/null || echo 未知)"
        return 0
    fi
    print_warn "未找到内核, 连接会失败。amneziawg-go 需要交叉编译(官方 release 仅源码)"
    yes_no "现在编译安装?" y || { print_error "没有内核无法连接"; return 1; }
    bash "$CLIENT_DIR/../conf/core.sh" install
}

# 角色标识: 与服务端标题栏保持一致的写法, 避免在 CC 上分不清
# 到底装的是服务端还是客户端面板 (两端的 conf/node.sh 之类的模块同名)。
client_banner() {
    echo -e "${GREEN}AWG-Panel — AmneziaWG 管理脚本${RESET}   ${GREEN}[ 客户端 · CLIENT ]${RESET}" >&2
    echo "----------------------" >&2
}

# ---------- 从服务端拉取配置 ----------
# 服务端跑 share_server.py, 客户端凭一次性 token 取回 client.conf。
# 拉之前先验 URL 形态再落盘: 直接 curl | tee 到目标路径的话,
# 服务端返回 404/410 时会把 "not found" 之类的正文写进 client.conf,
# 之后连接时报的是看不懂的解析错误。
client_pull() {   # $1=下发链接; $2=节点名(用于文件名, 可选)
    local url="${1:-}"
    [[ -n "$url" ]] || { print_error "用法: client.sh pull <下发链接>"; return 1; }
    [[ "$url" =~ ^https?:// ]] || { print_error "链接格式不对, 应以 http:// 或 https:// 开头"; return 1; }

    mkdir -p "$C_CLIENT_DIR"
    local tmp="$C_CLIENT_DIR/.pull.tmp"
    # 不能用 curl -f: 它在 HTTP >= 400 时退出码非 0, 于是 410(额度用尽) 和
    # 连不上网络会走进同一个分支, 用户只能看到"连不上", 永远不知道链接其实
    # 已经作废了。这里不加 -f, 拿状态码自己分流。
    local code
    code=$(curl -sS --max-time 30 -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)
    case "$code" in
        2*) ;;
        000) rm -f "$tmp"; print_error "连不上 $url (超时或无路由)"; return 1 ;;
        404) rm -f "$tmp"; print_error "链接不存在 (404): token 被删除了或写错了"; return 1 ;;
        410) rm -f "$tmp"; print_error "链接已失效 (410): 限次已用尽 / 已过期 / 已被禁用"; return 1 ;;
        503) rm -f "$tmp"; print_error "服务端暂不可用 (503): amneziawg 服务未运行, 稍后再试"; return 1 ;;
        *)   rm -f "$tmp"; print_error "拉取失败: HTTP $code"; return 1 ;;
    esac

    # 内容校验: 必须是像样的 AmneziaWG 配置, 否则不覆盖已有配置
    if ! grep -q '^\[Interface\]' "$tmp" 2>/dev/null || ! grep -qiE '^\s*PrivateKey\s*=' "$tmp"; then
        rm -f "$tmp"
        print_error "取回的内容不是有效的 AmneziaWG 配置, 现有配置未被覆盖"
        return 1
    fi

    # AWG 混淆参数必须与服务端一致, 缺了就拒收 —— 缺参数能连上但握手永远失败
    local miss=""
    for k in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4; do
        grep -qiE "^\s*$k\s*=" "$tmp" || miss="$miss $k"
    done
    if [[ -n "$miss" ]]; then
        rm -f "$tmp"
        print_error "配置缺少 AWG 混淆参数:$miss"
        print_info "客户端必须与服务端逐项一致, 否则握手不成功"
        return 1
    fi

    chmod 600 "$tmp"
    mv -f "$tmp" "$C_CONF"

    # 顺手留一份节点名, 方便状态栏显示
    local nm="${2:-}"
    [[ -n "$nm" ]] && echo "$nm" > "$C_CLIENT_DIR/.node-name"

    print_ok "已拉取配置 -> $C_CONF"
    printf "  %-14s %s\n" "本机地址"   "$(cget Address)"
    printf "  %-14s %s\n" "服务端"     "$(cget Endpoint)"
    printf "  %-14s %s\n" "混淆"       "Jc=$(cget Jc) S2=$(cget S2)"
    return 0
}

client_menu() {
    while true; do
        client_banner
        conn_status
        echo
        echo -e "${CYAN}1)${RESET} 安装 / 检查内核"
        echo -e "${CYAN}2)${RESET} 连接隧道"
        echo -e "${CYAN}3)${RESET} 断开隧道"
        echo -e "${CYAN}4)${RESET} 启动 LAN 代理 (SOCKS5/HTTP)"
        echo -e "${CYAN}5)${RESET} 停止 LAN 代理"
        echo -e "${CYAN}6)${RESET} 允许 LAN 访问 (0.0.0.0)"
        echo -e "${CYAN}7)${RESET} 查看连通性自检"
        echo -e "${CYAN}8)${RESET} 从服务端拉取配置"
        echo -e "${CYAN}9)${RESET} 卸载面板"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " c || return 0
        case "$c" in
            1) core_ensure ;;
            2) connect_flow ;;
            3) iface_down ;;
            4) proxy_start ;;
            5) proxy_stop ;;
            6) proxy_lan ;;
            7) net_alive && print_ok "网络正常" || print_error "网络异常" ;;
            8) client_pull "$(safe_read "下发链接" "")" ;;
            9) bash "$CLIENT_DIR/../conf/uninstall.sh" && exit 0 ;;
            0) return ;;
            *) echo -e "${RED}无效选项 $c${RESET}" ;;
        esac
        read -r -p "按回车键返回..." _ || return 0
    done
}

case "${1:-menu}" in
    unit)     unit_install ;;
    connect) connect_flow ;;
    disconnect) iface_down ;;
    proxy) proxy_start ;;
    proxy-stop) proxy_stop ;;
    status) conn_status ;;
    pull)  shift; client_pull "$@" ;;
    menu)  client_menu ;;
    *) echo "用法: $0 {menu|pull <链接>|connect|disconnect|proxy|proxy-stop|status}"; exit 2 ;;
esac