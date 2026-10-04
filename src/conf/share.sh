#!/usr/bin/env bash
# ==============================================================
# share.sh — 服务端 → 客户端 的配置下发
#
# 解决的问题: 客户端只能手动把 client.conf 放过去, 没有拉取入口。
#
# 机制 (沿用 sing-box-core 的 share 方案, 适配 AmneziaWG):
#   share_server.py 在 9292 之外独立端口监听, 客户端凭 token 拉取 .conf
#   token 128-bit 随机, 支持限次 / 有效期 / 手动禁用, 用 flock 串行化计数
#
# 安全性说明 —— 必须讲清楚的一点:
#   客户端 .conf 里是**该节点自己的私钥**。本方案由服务端生成密钥,
#   再经网络下发, 因此私钥会在网络上走一遍。
#   默认 max_uses=1 + 24 小时有效, 拉一次即作废, 尽量缩小暴露窗口。
#   这是"方便"与"私钥不出机器"之间的取舍; 若不接受, 唯一办法是
#   客户端本地生成密钥、只把公钥注册到服务端。
# ==============================================================
set -uo pipefail

SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SH_DIR/lib.sh"

SHARE_DIR="$AWG_ROOT/share"
SHARED="$SHARE_DIR/shares"
SHARE_PORT="${AWG_SHARE_PORT:-9393}"
SHARE_UNIT="awg-share"
SV() {
    grep -E "^$1\s*=" "$AWG_SERVER_CONF" 2>/dev/null | head -1 |
        cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# IPv6 必须包方括号, 否则 http://2001:db8::1:9393/... 里的端口会被并进地址
_url_host() {
    case "$1" in
        *:*) echo "[$1]" ;;
        *)   echo "$1" ;;
    esac
}

share_host() {
    local h; h=$(SV EndpointHost)
    [[ -n "$h" ]] && { echo "$h"; return 0; }
    ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

share_url_for() {
    local host tok
    host=$(share_host)
    tok=$(meta_field "$1" share_token)
    echo "http://$(_url_host "$host"):$SHARE_PORT/share/$tok"
}

meta_field() {   # $1=meta文件 $2=字段
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null
}

# ---------- 创建 ----------
share_create() {   # $1=节点名 $2=max_uses $3=ttl_hours
    local name="${1:-}" maxu="${2:-1}" ttl="${3:-24}"
    [[ -n "$name" ]] || { print_error "用法: share.sh create <节点名> [限次] [有效期小时]"; return 1; }
    local cf="$AWG_CLIENTS_DIR/$name.conf"
    [[ -f "$cf" ]] || { print_error "找不到 $name 的客户端配置 ($cf)"; print_info "先执行: node.sh add $name"; return 1; }
    [[ "$maxu" =~ ^[0-9]+$ ]] || { print_error "限次必须是非负整数 (0=不限)"; return 1; }
    [[ "$ttl"  =~ ^[0-9]+$ ]] || { print_error "有效期必须是小时数 (0=永久)"; return 1; }

    mkdir -p "$SHARED"
    # 同名旧 token 一并作废 —— 设计如此(一个节点只留一个有效链接),
    # 但必须告诉用户哪些链接会失效, 否则用户手上的旧链接毫无征兆变 404。
    local f revoked=0
    for f in "$SHARED"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(meta_field "$f" name)" == "$name" ]] || continue
        (( revoked == 0 )) && print_warn "$name 已存在旧链接, 重建会让它们立即失效:"
        print_info "    - $(basename "$f" .json)"
        rm -f "$f"; revoked=$((revoked + 1))
    done
    (( revoked > 0 )) && print_warn "已作废 $revoked 个旧链接"

    local token; token=$(openssl rand -hex 16)      # 128-bit 密码学随机
    local now expires=0
    now=$(date +%s)
    (( ttl > 0 )) && expires=$((now + ttl * 3600))
    python3 - "$SHARED" "$token" "$name" "$cf" "$maxu" "$expires" <<'PY'
import json, sys, time
d, token, name, cf, maxu, exp = sys.argv[1:7]   # argv[0] 是 "-", 所以是 1:7
meta = {"share_token": token, "name": name, "client_file": cf,
        "created_at": int(time.time()), "expires_at": int(exp),
        "max_uses": int(maxu), "used_count": 0,
        "enabled": True, "last_used_at": 0}
open(f"{d}/{token}.json", "w").write(json.dumps(meta, indent=1))
PY
    # 上面那段 python 失败时不会中断脚本, 会继续往下打印一个**没有 token 的
    # 死链接**(http://ip:9393/share/)。这里显式检查, 宁可报错也不能给用户
    # 一个看起来正常、点开 404 的链接。
    local meta="$SHARED/$token.json"
    [[ -f "$meta" ]] || { print_error "生成下发链接失败 (meta 未写入), 请重试"; return 1; }

    local url; url=$(share_url_for "$meta")
    echo "$url" | tee "$AWG_CLIENTS_DIR/share-$name.txt" >/dev/null
    print_ok "节点 $name 的下发链接:"
    echo -e "    ${CYAN}$url${RESET}" >&2
    if (( ttl > 0 )); then
        print_ok "限次 $maxu, 有效期 ${ttl} 小时 (至 $(date -d @$expires '+%F %T' 2>/dev/null))"
    else
        print_ok "限次 $maxu, 有效期: 永久"
    fi
    print_warn "该 .conf 内含节点私钥, 请勿公开转发"
}

share_list() {
    print_title "配置下发链接"
    shopt -s nullglob
    local f n=0
    for f in "$SHARED"/*.json; do
        n=1
        python3 - "$f" <<'PY' >&2
import json, sys, time
m = json.load(open(sys.argv[1]))
t = m.get("share_token", "?")[:12]
used = m.get("used_count", 0); mx = m.get("max_uses", 0)
state = "禁用" if not m.get("enabled") else "有效"
exp = m.get("expires_at", 0)
if state == "有效" and exp and time.time() > exp:
    state = "过期"
print("  %-14s %-14s %-6s %-10s %s" % (
    m.get("name", "?"), t,
    f"{used}/{mx if mx else '∞'}",
    state,
    (time.strftime("%F %T", time.localtime(exp)) if exp else "永久")))
PY
    done
    (( n )) || print_info "还没有下发链接"
}

share_del() {
    local f; f=$(ls "$SHARED"/"$1".json 2>/dev/null | head -1)
    [[ -f "$f" ]] || { print_error "token 不存在: $1"; return 1; }
    rm -f "$f" && print_ok "已删除"
}

share_toggle() {
    local f; f=$(ls "$SHARED"/"$1".json 2>/dev/null | head -1)
    [[ -f "$f" ]] || { print_error "token 不存在: $1"; return 1; }
    python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p))
m["enabled"] = not m.get("enabled", True)
open(p, "w").write(json.dumps(m, indent=1))
print("  已" + ("启用" if m["enabled"] else "禁用"))
PY
}

share_create_interactive() {
    local names name m t
    names=$(ls "$AWG_KEYS_DIR" 2>/dev/null | tr '\n' ' ')
    name=$(safe_read "节点名 [${names}]" "")
    [[ -z "$name" ]] && { print_info "已取消"; return 0; }
    m=$(safe_read "限次 (0=不限)" "1")
    t=$(safe_read "有效期小时 (0=永久)" "24")
    share_create "$name" "$m" "$t"
}

# ---------- systemd ----------
share_service_install() {
    local f="/etc/systemd/system/$SHARE_UNIT.service"
    cat > "$f" <<EOF
[Unit]
Description=AWG-Panel share server (config delivery)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=SHARE_DIR=$SHARE_DIR
Environment=SHARE_PORT=$SHARE_PORT
ExecStart=/usr/bin/python3 $SH_DIR/share_server.py
Restart=always
RestartSec=3
StandardOutput=append:$AWG_ROOT/logs/share.log
StandardError=append:$AWG_ROOT/logs/share.err

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p "$AWG_ROOT/logs"
    systemctl daemon-reload
    systemctl enable "$SHARE_UNIT" >/dev/null 2>&1
    print_ok "下发服务已安装: $SHARE_UNIT"
}

share_service_start() {
    systemctl restart "$SHARE_UNIT"
    sleep 1
    systemctl is-active --quiet "$SHARE_UNIT" \
        && print_ok "下发服务运行中 (:$SHARE_PORT)" \
        || { print_error "启动失败"; journalctl -u "$SHARE_UNIT" -n 10 --no-pager; } }

share_service_stop() {
    systemctl stop "$SHARE_UNIT" 2>/dev/null
    print_ok "已停止"
}

share_service_status() {
    local st; st=$(systemctl is-active "$SHARE_UNIT" 2>/dev/null || echo inactive)
    print_info "下发服务: $st  端口: $SHARE_PORT  目录: $SHARED"
}

# ---------- 菜单 ----------
share_menu() {
    while true; do
        print_title "配置下发 (服务端 → 客户端)"
        print_info "客户端执行: client.sh pull <链接>"
        echo
        echo -e "${CYAN}1)${RESET} 生成下发链接 (选节点)"
        echo -e "${CYAN}2)${RESET} 列出全部链接"
        echo -e "${CYAN}3)${RESET} 删除链接"
        echo -e "${CYAN}4)${RESET} 启用 / 禁用"
        echo -e "${CYAN}5)${RESET} 下发服务 启动/停止/状态"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " c || return 0
        case "$(clean_input "$c")" in
            1) share_create_interactive ;;
            2) share_list ;;
            3) share_del "$(safe_read 'token (可只写前 12 位)' '')" ;;
            4) share_toggle "$(safe_read 'token' '')" ;;
            5) share_svc_menu ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        read -r -p "按回车继续..." _ || return 0
    done
}

share_svc_menu() {
    while true; do
        share_service_status
        echo
        echo -e "${CYAN}1)${RESET} 安装"
        echo -e "${CYAN}2)${RESET} 启动 / 重启"
        echo -e "${CYAN}3)${RESET} 停止"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " c || return 0
        case "$c" in
            1) share_service_install ;;
            2) share_service_start ;;
            3) share_service_stop ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        read -r -p "按回车继续..." _ || return 0
    done
}

case "${1:-menu}" in
    create) shift; share_create "$@" ;;
    list)   share_list ;;
    del)    share_del "${1:-}" ;;
    toggle) share_toggle "${1:-}" ;;
    install) share_service_install ;;
    start)  share_service_start ;;
    stop)   share_service_stop ;;
    status) share_service_status ;;
    menu)   share_menu ;;
    *) echo "用法: $0 {create <节点> [限次] [小时]|list|del <token>|toggle <token>|install|start|stop|status|menu}"; exit 2 ;;
esac