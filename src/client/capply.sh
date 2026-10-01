#!/usr/bin/env bash
# ==============================================================
# capply.sh — 客户端运行期下发 (systemd ExecStartPost/ExecStopPost 调用)
#   up:   等 socket -> up 接口 -> 配地址 -> 下发 UAPI -> 装策略路由
#   down: 清策略路由 -> down 接口
#
# 为什么必须有这个:
#   amneziawg-go 是**无状态**守护进程, 不读配置文件, 重启后 device 是全新的空设备。
#   服务端靠 apply.sh 解决这件事; 客户端若只在"连接时"下发一次, 那么
#   systemd 的 Restart=always / 机器重启之后 peer 就没了, 而隧道看起来还"开着"。
# ==============================================================
set -uo pipefail

CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWG_SRC="$CLIENT_DIR/../conf"
# shellcheck source=lib.sh
[[ -f "$AWG_SRC/lib.sh" ]] && . "$AWG_SRC/lib.sh"

C_ROOT="${AWG_ROOT:-/opt/awg-panel/amneziawg}"
C_CONF="$C_ROOT/client/client.conf"
C_IFACE="${AWG_CLIENT_IFACE:-awgc0}"
C_TABLE="${AWG_RT_TABLE:-100}"
C_RULE_PRIO="${AWG_RULE_PRIO:-100}"
UAPI="$AWG_SRC/uapi.py"

cget() { grep -E "^$1\s*=" "$C_CONF" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
c_srv_ip()   { cget Address | cut -d/ -f1; }
c_endpoint() { cget Endpoint | cut -d: -f1; }
c_ep_port()  { cget Endpoint | cut -d: -f2; }

route_add() {
    local cip="$1" ep via
    ep=$(c_endpoint)
    # 端点必须固定走物理网卡, 否则 default dev awgc0 会把包再送回隧道自己(环路)
    via=$(ip route get "$ep" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    ip route flush table "$C_TABLE" 2>/dev/null
    if [[ -n "$via" && "$via" != "$C_IFACE" ]]; then
        ip route add "$ep/32" dev "$via" table "$C_TABLE"
    fi
    ip route add default dev "$C_IFACE" table "$C_TABLE"
    ip rule del from "$cip/32" lookup "$C_TABLE" priority "$C_RULE_PRIO" 2>/dev/null
    ip rule add from "$cip/32" lookup "$C_TABLE" priority "$C_RULE_PRIO"
}

route_del() {
    local cip; cip=$(c_srv_ip)
    [[ -n "$cip" ]] && ip rule del from "$cip/32" lookup "$C_TABLE" priority "$C_RULE_PRIO" 2>/dev/null
    ip route flush table "$C_TABLE" 2>/dev/null
}

case "${1:-up}" in
up)
    [[ -f "$C_CONF" ]] || { echo "capply: 缺少 $C_CONF" >&2; exit 1; }
    for _ in $(seq 1 50); do
        [[ -S "/var/run/amneziawg/$C_IFACE.sock" ]] && break
        sleep 0.2
    done
    [[ -S "/var/run/amneziawg/$C_IFACE.sock" ]] || { echo "capply: UAPI socket 未就绪" >&2; exit 1; }

    cip=$(c_srv_ip)
    sysctl -w "net.ipv4.conf.${C_IFACE}.rp_filter=0" >/dev/null 2>&1
    ip link set "$C_IFACE" up 2>/dev/null
    ip addr replace "$cip/32" dev "$C_IFACE"

    python3 "$UAPI" client "$C_CONF" | python3 "$UAPI" set "$C_IFACE" - || {
        echo "capply: UAPI 下发失败" >&2; exit 1; }
    route_add "$cip"
    echo "capply: 客户端隧道就绪 $C_IFACE ($cip) -> $(c_endpoint):$(c_ep_port)"
    ;;
down)
    route_del
    ip link set "$C_IFACE" down 2>/dev/null
    ;;
reload)
    python3 "$UAPI" client "$C_CONF" | python3 "$UAPI" set "$C_IFACE" -
    ;;
*) echo "用法: $0 {up|down|reload}"; exit 2 ;;
esac