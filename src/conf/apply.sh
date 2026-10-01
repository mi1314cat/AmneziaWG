#!/usr/bin/env bash
# ==============================================================
# apply.sh — amneziawg-go 运行期接口/路由/UAPI 下发
#   由 systemd 的 ExecStartPost / ExecStopPost 调用:
#     ExecStartPost=... apply.sh up
#     ExecStopPost=... apply.sh down
#
# 关键点 (实测踩坑, 不要删):
#   amneziawg-go 只创建 TUN 设备, **不会**配 IP、不会 up、不会设回程路由。
#   只 ip addr add <srv>/32 的话, MASQUERADE 回包在内核里找不到下一跳 ->
#   握手成功、rx_bytes 增长, 但客户端 SYN 无响应(单向不通)。
#   所以这里既按 server.conf 配地址, 又为每个 peer 显式补一条 /32 路由。
# ==============================================================
set -uo pipefail

APPLY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$APPLY_DIR/lib.sh"

NAT_MARK="awg-panel"

_srv_addr()   { grep -E '^Address\s*='     "$AWG_SERVER_CONF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ' ; }
_srv_port()   { grep -E '^ListenPort\s*=' "$AWG_SERVER_CONF" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ' ; }
_masq_on()    { grep -qiE '^Masquerade\s*=\s*true' "$AWG_SERVER_CONF" 2>/dev/null; }
_peer_ips()   { awk -F'=' '/^AllowedIPs/{print $2}' "$AWG_SERVER_CONF" 2>/dev/null | tr ',' ' ' | tr -d ' ' | sed 's|/.*||'; }

# ---------- NAT (只针对 AWG 子网, 带注释标记便于精确清理) ----------
nat_add() {
    local subnet="$1" wan
    have iptables || return 0
    wan=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$wan" ]] && { print_warn "无默认路由, 跳过 NAT"; return 0; }
    iptables -t nat -C POSTROUTING -s "$subnet" -o "$wan" -m comment --comment "$NAT_MARK" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$subnet" -o "$wan" -m comment --comment "$NAT_MARK" -j MASQUERADE
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    print_info "NAT 已启用: $subnet -> $wan"
}

nat_del() {
    have iptables || return 0
    local line
    while read -r line; do
        [[ -z "$line" ]] && continue
        iptables -t nat -D POSTROUTING -s "${line%% *}" -o "${line#*-o }" \
            -m comment --comment "$NAT_MARK" -j MASQUERADE 2>/dev/null
        iptables -t nat -D POSTROUTING -s "${line%% *}" -m comment --comment "$NAT_MARK" -j MASQUERADE 2>/dev/null
    done < <(iptables -t nat -S POSTROUTING 2>/dev/null | grep -- "$NAT_MARK")
}

# ---------- up ----------
apply_up() {
    [[ -f "$AWG_SERVER_CONF" ]] || { print_error "缺少 $AWG_SERVER_CONF"; return 1; }

    # 等 UAPI socket (amneziawg-go 刚起, socket 可能还没建好)
    local i
    for i in $(seq 1 50); do
        [[ -S "/var/run/amneziawg/$AWG_IFACE.sock" ]] && break
        sleep 0.2
    done
    if [[ ! -S "/var/run/amneziawg/$AWG_IFACE.sock" ]]; then
        print_error "UAPI socket 未就绪: /var/run/amneziawg/$AWG_IFACE.sock"
        return 1
    fi

    local addr port subnet
    addr=$(_srv_addr); port=$(_srv_port)
    [[ -n "$addr" ]]   || { print_error "server.conf 缺少 Address"; return 1; }
    [[ -n "$port" ]]   || { print_error "server.conf 缺少 ListenPort"; return 1; }

    ip link set "$AWG_IFACE" up 2>/dev/null || { print_error "无法 up 接口 $AWG_IFACE"; return 1; }
    ip addr replace "$addr" dev "$AWG_IFACE"

    # 显式补 peer 回程路由 (/32 地址场景必需; /24 场景冗余但无害)
    local ip
    while read -r ip; do
        [[ -n "$ip" ]] && ip route replace "$ip/32" dev "$AWG_IFACE"
    done < <(_peer_ips)

    # 下发 UAPI (密钥/参数/peers); uapi.py 会先做参数前置校验
    if ! python3 "$AWG_UAPI_PY" render "$AWG_SERVER_CONF" | python3 "$AWG_UAPI_PY" set "$AWG_IFACE" -; then
        print_error "UAPI 下发失败"
        return 1
    fi

    if _masq_on; then
        # NAT 规则要匹配整个网段, 不能只匹配服务器自己那个 /32 地址。
        # 直接用 python 算网络地址, 避免 bash 里处理前缀长度的各种边界。
        local subnet
        subnet=$(python3 - "$addr" <<'PY'
import ipaddress, sys
try:
    print(ipaddress.ip_interface(sys.argv[1]).network)
except ValueError:
    pass
PY
)
        [[ -z "$subnet" ]] && subnet="10.66.66.0/24"
        nat_add "$subnet"
    fi

    print_ok "AWG 服务端就绪: $AWG_IFACE  addr=$addr  port=$port"
}

# ---------- down ----------
apply_down() {
    nat_del
    ip link set "$AWG_IFACE" down 2>/dev/null
    print_info "接口已 down"
}

case "${1:-up}" in
    up)   apply_up ;;
    down) apply_down ;;
    reload)
        # 热更新: 不动接口, 只重下 UAPI (改参数/加删 peer 用这个)
        python3 "$AWG_UAPI_PY" render "$AWG_SERVER_CONF" | python3 "$AWG_UAPI_PY" set "$AWG_IFACE" -
        ;;
    *) echo "用法: $0 {up|down|reload}"; exit 2 ;;
esac