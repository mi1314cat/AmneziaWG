#!/usr/bin/env bash
# ==============================================================
# awg.sh — AWG-Panel 主入口
#   bash <(curl -fsSL https://github.com/mi1314cat/AmneziaWG/raw/main/install.sh)
#   或: bash src/awg.sh
# 架构与 xary-core (xray-panel.sh) / sing-box-core (sing-box.sh) 对齐:
#   单内核 + 单 systemd service + 唯一事实来源配置 + 模块化 conf/*.sh
# ==============================================================
export TERM=xterm
AWG_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWG_SRC="$AWG_HOME/conf"
# shellcheck source=conf/lib.sh
[[ -f "$AWG_SRC/lib.sh" ]] && source "$AWG_SRC/lib.sh"
# 兜底 UI (防 lib 缺失)
RED="${RED:-\e[31m}"; GREEN="${GREEN:-\e[32m}"; YELLOW="${YELLOW:-\e[33m}"
CYAN="${CYAN:-\e[96m}"; MAGENTA="${MAGENTA:-\e[95m}"; RESET="${RESET:-\e[0m}"

# 模块执行: 本地优先, 缺失时从 GitHub 拉单个模块 (与 sing-box-core 同思路)
run_module() {   # run_module <module.sh> [args...]
    local mod="$1"; shift || true
    mkdir -p "$AWG_SRC"
    if [[ ! -f "$AWG_SRC/$mod" ]]; then
        bash <(curl -fsSL "https://github.com/mi1314cat/AmneziaWG/raw/refs/heads/main/src/conf/$mod") "$@"
        return $?
    fi
    bash "$AWG_SRC/$mod" "$@"
}

# ---------- 首页状态 ----------
status_line() {
    local svc ver peers
    svc=$([[ "$AWG_UNIT_ACTIVE" == "active" ]] && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}未运行${RESET}")
    ver=$([[ -f "$AWG_VERSION_FILE" ]] && cat "$AWG_VERSION_FILE" || echo "未安装")
    peers=$(grep -c '^\[Peer' "$AWG_SERVER_CONF" 2>/dev/null || echo 0)
    echo "服务状态: $svc"
    echo -e "内核版本: ${GREEN}$ver${RESET}"
    echo -e "节点数:   ${GREEN}$peers${RESET}"
}

main_menu() {
    local status_text
    have_svc && status_text=$(systemctl is-active "$AWG_UNIT" 2>/dev/null) || status_text="inactive"
    AWG_UNIT_ACTIVE="$status_text"

    clear
    cat <<'CATART'
                       |\__/,|   (\
                     _.|o o  |_   ) )
   -------------(((---(((-------------------
                   catmi.awg
   -----------------------------------------
CATART
    echo -e "
${GREEN}AWG-Panel — AmneziaWG 管理脚本${RESET}   ${GREEN}[ 服务端 · SERVER ]${RESET}
----------------------
${GREEN}1.${RESET} 安装 / 内核 (初始化/安装/更新/版本/卸载)
${GREEN}2.${RESET} 服务端配置 (参数/子网/端口/混淆档位)
${GREEN}3.${RESET} 客户端节点 (创建/列表/删除/重新生成)
${GREEN}4.${RESET} 客户端产物 (原生 conf · mihomo YAML · 二维码)
${GREEN}5.${RESET} 服务管理 (安装/启动/停止/重启/重载/日志)
${GREEN}6.${RESET} 查看状态 (配置摘要 + UAPI 实时统计)
${GREEN}7.${RESET} 防火墙 (查看已放行端口)
${GREEN}0.${RESET} 退出
----------------------"
    status_line
    echo "----------------------"
    read -r -p "请输入选项 [0-9]: " choice || { clear; exit 0; }
    case "$choice" in
        1) core_menu ;;
        2) run_module server.sh menu ;;
        3) run_module node.sh menu ;;
        4) artifact_menu ;;
        5) service_menu ;;
        6) run_module server.sh show ;;
        7) fw_menu ;;
        0) clear; exit 0 ;;
        *)  echo -e "${RED}无效选项 $choice${RESET}" ;;
    esac
    echo && read -r -p "按回车键返回主菜单..." _ || true
}

# ---------- 子菜单 ----------
core_menu() {
    while true; do
        print_title "安装 / 内核管理"
        echo -e "${CYAN}1)${RESET} 初始化服务端配置"
        echo -e "${CYAN}2)${RESET} 安装内核 (交叉编译静态二进制)"
        echo -e "${CYAN}3)${RESET} 更新内核 (已是最新则跳过)"
        echo -e "${CYAN}4)${RESET} 版本管理 (当前/最新/指定)"
        echo -e "${CYAN}5)${RESET} 卸载内核"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " c || return 0
        case "$c" in
            1) run_module server.sh init; read -r -p "按回车继续..." ;;
            2) run_module core.sh install; read -r -p "按回车继续..." ;;
            3) run_module core.sh update; read -r -p "按回车继续..." ;;
            4) version_menu ;;
            5) run_module core.sh uninstall ;;
            0) return ;;
            *) echo -e "${RED}无效选项 $c${RESET}" ;;
        esac
    done
}

version_menu() {
    while true; do
        print_title "内核版本管理"
        echo -e "${CYAN}当前版本:${RESET} $([[ -f "$AWG_VERSION_FILE" ]] && cat "$AWG_VERSION_FILE" || echo 未安装)"
        echo -e "${CYAN}1)${RESET} 查询上游最新"
        echo -e "${CYAN}2)${RESET} 安装指定版本"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " vc
        case "$vc" in
            1) echo "上游最新: $(bash "$AWG_SRC/core.sh" latest)"; read -r -p "按回车继续..." ;;
            2) read -r -p "版本号 (如 v3.1.20260828): " vv
                run_module core.sh install "${vv#v}"; read -r -p "按回车继续..." ;;
            0) return ;;
            *) ;;
        esac
    done
}

artifact_menu() {
    print_title "客户端产物"
    if ! compgen -G "$AWG_KEYS_DIR/client-*" >/dev/null 2>&1; then
        print_warn "还没有任何节点, 请先在主菜单 3) 创建"
        return
    fi
    local d n f
    for d in "$AWG_KEYS_DIR"/client-*; do
        [[ -d "$d" ]] || continue
        n=$(basename "$d")
        echo -e "${CYAN}${n}${RESET}  ${GREEN}$(cat "$d/ip" 2>/dev/null)${RESET}  ${YELLOW}$(cat "$d/created" 2>/dev/null | cut -d. -f1)${RESET}"
    done
    echo
    echo -e "${CYAN}产物目录:${RESET} $AWG_CLIENTS_DIR"
    for f in "$AWG_CLIENTS_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        echo -e "  ${GREEN}conf   ${RESET} $f"
        [[ -f "${f%.conf}.mihomo.yaml" ]] && echo -e "  ${GREEN}mihomo ${RESET} ${f%.conf}.mihomo.yaml"
        [[ -f "${f%.conf}.png" ]]         && echo -e "  ${GREEN}二维码 ${RESET} ${f%.conf}.png"
    done
    echo
    echo -e "${CYAN}1)${RESET} 全部重新生成   ${CYAN}2)${RESET} 查看某个节点配置   ${CYAN}0)${RESET} 返回"
    read -r -p "请选择: " ac
    case "$ac" in
        1) run_module node.sh regen ;;
        2) read -r -p "节点名: " nn; run_module node.sh show "$nn" ;;
        0) return ;;
        *) ;;
    esac
}

fw_menu() {
    print_title "防火墙 — 已放行端口"
    local f="$AWG_STATE_DIR/.fw-ports"
    if [[ -f "$f" ]]; then cat "$f"; else print_warn "尚未记录任何放行端口"; fi
    echo
    if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "${CYAN}ufw:${RESET} active"
    elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        echo -e "${CYAN}firewalld:${RESET} running"
    else
        echo -e "${CYAN}iptables:${RESET} 直接管理"
    fi
}

service_menu() {
    while true; do
        print_title "服务管理"
        echo -e "${CYAN}1)${RESET} 安装服务 (systemd unit)"
        echo -e "${CYAN}2)${RESET} 启动服务"
        echo -e "${CYAN}3)${RESET} 停止服务"
        echo -e "${CYAN}4)${RESET} 重启服务"
        echo -e "${CYAN}5)${RESET} 软重载配置 (零断流)"
        echo -e "${CYAN}6)${RESET} 查看状态"
        echo -e "${CYAN}7)${RESET} 查看日志"
        echo -e "${CYAN}8)${RESET} 开机自启 / 取消"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " c || return 0
        case "$c" in
            1) run_module service.sh install ;;
            2) run_module service.sh start;   sleep 1 ;;
            3) run_module service.sh stop ;;
            4) run_module service.sh restart; sleep 1 ;;
            5) run_module service.sh reload ;;
            6) run_module service.sh status ;;
            7) journalctl -u "$AWG_UNIT" -n 60 --no-pager ;;
            8) if systemctl is-enabled --quiet "$AWG_UNIT" 2>/dev/null
               then run_module service.sh disable; else run_module service.sh enable; fi ;;
            0) return ;;
            *) echo -e "${RED}无效选项 $c${RESET}" ;;
        esac
        read -r -p "按回车键返回..." _ || return 0
    done
}

case "${1:-menu}" in
    menu)    main_menu ;;
    core)    core_menu ;;
    init)    run_module server.sh init ;;
    server)  run_module server.sh "${2:-menu}" ;;
    node)    run_module node.sh "${2:-menu}" ;;
    service) run_module service.sh "${2:-status}" ;;
    *) echo "用法: $0 {menu|core|init|server|node|service}"; exit 2 ;;
esac