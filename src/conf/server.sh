#!/usr/bin/env bash
# ==============================================================
# server.sh — 服务端实例管理 (server.conf 的唯一写入者)
#
#   server.conf = 唯一事实来源
#   UAPI        = 运行时投影
#   所以每次改动都是: 改 server.conf -> 渲染 -> 校验 -> 下发 -> 失败回滚
#
# 子命令:
#   init      交互式创建服务端配置 (首次)
#   show      显示当前配置摘要 + 运行状态
#   reload    重新下发 (改完 server.conf 后用)
#   menu      交互菜单
# ==============================================================
set -uo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SERVER_DIR/lib.sh"

# ---------- 读值 ----------
sv_get() { grep -E "^$1\s*=" "$AWG_SERVER_CONF" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# ---------- init ----------
server_init() {
    print_title "创建 AmneziaWG 服务端配置"

    local addr port priv pub hs
    addr=$(safe_read "服务端地址 (IP/掩码)" "$AWG_DEFAULT_SUBNET")
    [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] ||
        { print_error "地址格式应为 IP/掩码, 例如 10.66.66.1/24"; return 1; }

    # 端口冲突检测: AmneziaWG 只用 UDP, 但 TCP 同号占用也应提示
    port=$(safe_read_port "$AWG_DEFAULT_PORT" "udp")
    port_state "$port" && print_ok "端口 $port 可用 (UDP)"
    open_port "$port" "udp"

    read -r priv pub < <(gen_keypair)

    local h1 h2 h3 h4
    read -r h1 h2 h3 h4 < <(random_h_set)

    local dns mtu masq
    dns=$(safe_read "客户端下发 DNS" "1.1.1.1, 9.9.9.9")
    mtu=$(safe_read "MTU" "$AWG_DEFAULT_MTU")
    yes_no "启用 NAT (客户端经本机出网)" y && masq=true || masq=false

    # 先写临时文件, 通过 uapi.py 校验后才落盘
    local tmp; tmp=$(mktemp)
    cat > "$tmp" <<EOF
# AmneziaWG 服务端配置 (AWG-Panel)
# 本文件是唯一事实来源; 修改后执行 server.sh reload 生效
[Interface]
Address     = $addr
ListenPort  = $port
PrivateKey  = $priv
PublicKey   = $pub
DNS         = $dns
MTU         = $mtu
Masquerade  = $masq

# ---- AWG 混淆参数 (基础档, 实测与 mihomo v1.19.30 互通) ----
Jc  = $AWG_DEFAULT_JC
Jmin = $AWG_DEFAULT_JMIN
Jmax = $AWG_DEFAULT_JMAX
S1  = $AWG_DEFAULT_S1
S2  = $AWG_DEFAULT_S2
S3  = $AWG_DEFAULT_S3
S4  = $AWG_DEFAULT_S4
H1  = $h1
H2  = $h2
H3  = $h3
H4  = $h4

# ---- AWG v3 高级参数 (默认关闭, 见 params.sh) ----
# ContentPaddingAddition =
# HeaderProtectionKey    =     # 启用时 S1-S4 必须全部 >= $AWG_HEADER_NONCE_MIN
# RandomTrailers         = false
# DisableCookies         = false
EOF

    if ! validate_awg "$tmp" >/dev/null; then
        print_error "配置校验未通过, 已放弃写入"
        rm -f "$tmp"; return 1
    fi

    cp -f "$tmp" "$AWG_SERVER_CONF"
    chmod 600 "$AWG_SERVER_CONF"
    rm -f "$tmp"

    print_ok "服务端配置已创建: $AWG_SERVER_CONF"
    print_info "监听端口 $port (UDP), 地址 $addr"
    print_info "客户端请用 server.sh 生成 (下一阶段 node.sh)"

    if have_svc && systemctl is-active --quiet "$AWG_UNIT" 2>/dev/null; then
        server_reload && print_ok "已热加载到运行中的服务"
    fi
}

# ---------- show ----------
server_show() {
    print_title "服务端配置"
    if [[ ! -f "$AWG_SERVER_CONF" ]]; then
        print_warn "尚未初始化, 执行 server.sh init"
        return 0
    fi
    printf "  %-14s %s\n" "地址"        "$(sv_get Address)"
    printf "  %-14s %s\n" "监听端口"    "$(sv_get ListenPort)"
    printf "  %-14s %s\n" "服务端公钥"  "$(sv_get PublicKey)"
    printf "  %-14s %s\n" "DNS"         "$(sv_get DNS)"
    printf "  %-14s %s\n" "MTU"         "$(sv_get MTU)"
    printf "  %-14s %s\n" "NAT"         "$(sv_get Masquerade)"
    printf "  %-14s %s\n" "混淆参数"    "Jc=$(sv_get Jc) Jmin=$(sv_get Jmin) Jmax=$(sv_get Jmax) S1=$(sv_get S1) S2=$(sv_get S2) S3=$(sv_get S3) S4=$(sv_get S4)"
    printf "  %-14s %s\n" "魔数"        "H1=$(sv_get H1) H2=$(sv_get H2) H3=$(sv_get H3) H4=$(sv_get H4)"

    local hp; hp=$(sv_get HeaderProtectionKey)
    [[ -n "$hp" ]] && printf "  %-14s %s\n" "HeaderProtect" "已启用"
    local peers; peers=$(grep -c '^\[Peer' "$AWG_SERVER_CONF" 2>/dev/null || echo 0)
    printf "  %-14s %s\n" "客户端数"    "$peers"

    echo
    print_info "运行状态:"
    if ! have_svc; then print_warn "无 systemd"; return 0; fi
    systemctl is-active --quiet "$AWG_UNIT" && print_ok "服务: running" || print_warn "服务: 未运行"
    if [[ -S "/var/run/amneziawg/$AWG_IFACE.sock" ]]; then
        local hs; hs=$(uapi_get | grep -E 'last_handshake_time_sec|tx_bytes|rx_bytes' | tr '\n' ' ')
        printf "  %s\n" "${hs:- (无统计)}"
    fi
}

# ---------- reload ----------
server_reload() {
    [[ -f "$AWG_SERVER_CONF" ]] || { print_error "缺少 $AWG_SERVER_CONF"; return 1; }
    print_info "重新下发配置..."
    if ! validate_awg "$AWG_SERVER_CONF" >/dev/null; then
        print_error "配置校验失败, 未下发"
        return 1
    fi
    if ! have_svc || ! systemctl is-active --quiet "$AWG_UNIT"; then
        print_warn "服务未运行, 请先启动: systemctl start $AWG_UNIT"
        return 1
    fi
    python3 "$AWG_UAPI_PY" render "$AWG_SERVER_CONF" | python3 "$AWG_UAPI_PY" set "$AWG_IFACE" - &&
        print_ok "已生效"
}

# ---------- menu ----------
server_menu() {
    while true; do
        print_title "AmneziaWG 服务端"
        echo "1) 查看配置"
        echo "2) 初始化配置"
        echo "3) 重载配置"
        echo "0) 返回"
        printf "选择: " >&2
        read -r c || exit 0
        c=$(clean_input "$c")
        case "$c" in
            1) server_show ;;
            2) server_init ;;
            3) server_reload ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        printf "回车继续..." >&2; read -r || exit 0
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-menu}" in
        init)   server_init ;;
        show)   server_show ;;
        reload) server_reload ;;
        menu)   server_menu ;;
        *) echo "用法: $0 {init|show|reload|menu}"; exit 2 ;;
    esac
fi