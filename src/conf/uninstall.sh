#!/usr/bin/env bash
# ==============================================================
# uninstall.sh — AWG-Panel 完整卸载
#   原则: 只删本项目自己的东西, 不碰机器上任何其它服务。
#   所有要删的对象都带 awg-panel 标记或位于本项目专属路径。
# ==============================================================
set -uo pipefail

U_ROOT="${AWG_ROOT:-/opt/awg-panel/amneziawg}"
U_IFACE="${AWG_IFACE:-awg0}"
U_UNIT="${AWG_UNIT:-amneziawg}"
C_IFACE="${AWG_CLIENT_IFACE:-awgc0}"
C_UNIT="${AWG_CLIENT_UNIT:-amneziawg-client}"
TABLE="${AWG_RT_TABLE:-100}"
PRI="${AWG_RULE_PRIO:-100}"

[ "$(id -u)" = "0" ] || { echo "请使用 root 运行"; exit 1; }

echo "=== 将要删除 ==="
echo "  目录      : $U_ROOT"
echo "  systemd   : $U_UNIT / ${C_UNIT} / ${C_UNIT}-proxy"
echo "  接口      : $U_IFACE / $C_IFACE"
echo "  路由规则  : table $TABLE, priority $PRI"
echo "  NAT 规则  : 所有带 --comment awg-panel 的 MASQUERADE"
echo
read -r -p "确认卸载? [y/N]: " a || exit 1
[[ "$a" =~ ^[Yy] ]] || { echo "已取消"; exit 0; }

echo "--- 停止并移除服务 ---"
for u in "$C_UNIT-proxy" "$C_UNIT" "$U_UNIT"; do
    systemctl stop "$u" 2>/dev/null
    systemctl disable "$u" 2>/dev/null
done
rm -f "/etc/systemd/system/$U_UNIT.service" \
      "/etc/systemd/system/$C_UNIT.service" \
      "/etc/systemd/system/${C_UNIT}-proxy.service"
systemctl daemon-reload 2>/dev/null

echo "--- 清理客户端策略路由 ---"
ip rule del from 10.66.66.2/32 lookup "$TABLE" priority "$PRI" 2>/dev/null
# 更稳妥: 把指向本表、且源地址不属于本机常规地址的规则删掉
while read -r pri rest; do
    [[ "$rest" == *"lookup $TABLE"* ]] || continue
    case "$rest" in
        *"from all"*) continue ;;          # 不动默认规则
        *) ip rule del priority "$pri" 2>/dev/null ;;
    esac
done < <(ip rule show | sed 's/^\([0-9]\+\):\s*/\1 /')
ip route flush table "$TABLE" 2>/dev/null

echo "--- 清理接口 ---"
ip link del "$C_IFACE" 2>/dev/null
ip link del "$U_IFACE" 2>/dev/null
rm -f "/var/run/amneziawg/$U_IFACE.sock" "/var/run/amneziawg/$C_IFACE.sock"
rmdir /var/run/amneziawg 2>/dev/null

echo "--- 清理 NAT 规则 (仅 awg-panel 标记) ---"
if command -v iptables >/dev/null 2>&1; then
    while read -r line; do
        [[ "$line" == *awg-panel* ]] || continue
        iptables -t nat -D POSTROUTING ${line#-A POSTROUTING } 2>/dev/null && \
            echo "  removed: ${line:0:70}"
    done < <(iptables -t nat -S POSTROUTING 2>/dev/null)
fi

echo "--- 清理防火墙放行记录 ---"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    while read -r line; do
        [[ -n "$line" ]] && ufw delete allow "$line" >/dev/null 2>&1 && echo "  ufw delete $line"
    done < <(awk -F/ '{print $1" "$2}' "$U_ROOT/state/.fw-ports" 2>/dev/null | awk '{print $1"/"$2}')
fi
if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep -v '^$' | while read -r p; do
        firewall-cmd --zone=public --remove-port="$p" --permanent >/dev/null 2>&1
    done
    firewall-cmd --reload >/dev/null 2>&1
fi

echo "--- 清理 ufw 的 iptables 放行 (带 awg-panel 注释) ---"
if command -v iptables >/dev/null 2>&1; then
    while read -r line; do
        [[ "$line" == *awg-panel* ]] || continue
        iptables -D INPUT ${line#-A INPUT } 2>/dev/null && echo "  removed INPUT rule"
    done < <(iptables -S INPUT 2>/dev/null)
fi

echo "--- 清理 rp_filter (仅本项目接口) ---"
sysctl -w "net.ipv4.conf.$C_IFACE.rp_filter=1" >/dev/null 2>&1

echo "--- 清理日志 ---"
rm -f /var/log/amneziawg-client.log /var/log/amneziawg-client.err

if [[ "${1:-}" == "--purge" ]]; then
    echo "--- 彻底删除数据 (含全部节点与私钥) ---"
    rm -rf "$U_ROOT" /opt/awg-panel
else
    echo "--- 保留数据目录 (加 --purge 可连节点密钥一并删除) ---"
    rm -rf "$U_ROOT/bin" "$U_ROOT/logs" "$U_ROOT/state"
fi

echo
echo "=== 卸载完成 ==="
echo "如需彻底清理: bash uninstall.sh --purge"