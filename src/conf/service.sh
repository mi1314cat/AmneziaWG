#!/usr/bin/env bash
# ==============================================================
# service.sh — systemd 服务管理 (单一 unit, 所有客户端共享一个接口)
#   install | start | stop | restart | reload | enable | disable | status | logs | uninstall
# ==============================================================
set -uo pipefail

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SVC_DIR/lib.sh"

svc_install() {
    root_only
    [[ -x "$AWG_BIN" ]] || { print_error "未找到内核: $AWG_BIN (先执行 core.sh install)"; return 1; }
    have_svc || { print_error "本机无 systemd"; return 1; }

    mkdir -p "$AWG_LOGS_DIR"
    cat > "$AWG_UNIT_FILE" <<EOF
[Unit]
Description=AmneziaWG server (AWG-Panel)
Documentation=https://github.com/mi1314cat/AmneziaWG
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=LOG_LEVEL=verbose
ExecStart=$AWG_BIN -f $AWG_IFACE
ExecStartPost=$SVC_DIR/apply.sh up
ExecStopPost=$SVC_DIR/apply.sh down
Restart=always
RestartSec=3
LimitNOFILE=1048576
StandardOutput=append:$AWG_LOGS_DIR/service.log
StandardError=append:$AWG_LOGS_DIR/error.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$AWG_UNIT" >/dev/null 2>&1
    print_ok "服务已安装并设为开机启动: $AWG_UNIT"
    print_info "ExecStart     = $AWG_BIN -f $AWG_IFACE"
    print_info "ExecStartPost = $SVC_DIR/apply.sh up   (配地址/回程路由/下发 UAPI)"
}

svc_status() {
    if ! have_svc; then print_error "无 systemd"; return 1; fi
    systemctl status "$AWG_UNIT" --no-pager -l || true
    echo
    if [[ -S "/var/run/amneziawg/$AWG_IFACE.sock" ]]; then
        print_info "UAPI 状态:"
        uapi_get | grep -E 'listen_port|jc|jmin|jmax|^s[1-4]=|^h[1-4]=|public_key|endpoint|last_handshake_time_sec|tx_bytes|rx_bytes|allowed_ip' | sed 's/^/  /' >&2
    fi
}

svc_logs() { journalctl -u "$AWG_UNIT" -n "${1:-50}" --no-pager; }

case "${1:-status}" in
    install)   svc_install ;;
    start)     systemctl start "$AWG_UNIT" ;;
    stop)      systemctl stop "$AWG_UNIT" ;;
    restart)   systemctl restart "$AWG_UNIT" ;;
    reload)    systemctl reload "$AWG_UNIT" 2>/dev/null || systemctl restart "$AWG_UNIT" ;;
    enable)    systemctl enable "$AWG_UNIT" ;;
    disable)   systemctl disable "$AWG_UNIT" ;;
    status)    svc_status ;;
    logs)      svc_logs "${2:-50}" ;;
    uninstall)
        systemctl stop "$AWG_UNIT" 2>/dev/null
        systemctl disable "$AWG_UNIT" 2>/dev/null
        rm -f "$AWG_UNIT_FILE"
        systemctl daemon-reload 2>/dev/null
        print_ok "服务已移除 (配置与节点保留)"
        ;;
    *) echo "用法: $0 {install|start|stop|restart|reload|enable|disable|status|logs [n]|uninstall}"; exit 2 ;;
esac