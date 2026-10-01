#!/usr/bin/env bash
# ==============================================================
# install.sh — AWG-Panel 一键入口
#   bash <(curl -fsSL https://github.com/mi1314cat/AmneziaWG/raw/main/install.sh)
#
# 职责: 取码 -> 环境自检 -> 初始化 -> 进入面板
#       (所有交互都在面板里, 本脚本只做"取码 + 装依赖 + 交接")
#
# 可选参数:
#   install.sh server   安装为服务端 (默认)
#   install.sh client   安装为客户端
#   install.sh update   拉取最新代码
#   install.sh status   只看状态
# ==============================================================
set -u

REPO="https://github.com/mi1314cat/AmneziaWG"
BRANCH="${AWG_BRANCH:-main}"
SRV_ROOT="${SRV_ROOT:-/opt/awg-panel}"
GREEN='\033[32m'; BLUE='\033[36m'; YELLOW='\033[33m'; RED='\033[31m'; PLAIN='\033[0m'
info(){ printf "${BLUE}[INFO] %s${PLAIN}\n" "$*"; }
ok(){   printf "${GREEN}[OK]   %s${PLAIN}\n" "$*"; }
warn(){ printf "${YELLOW}[WARN] %s${PLAIN}\n" "$*"; }
err(){  printf "${RED}[ERROR] %s${PLAIN}\n" "$*" >&2; }
die(){  err "$*"; printf "${RED}请根据上面的原因检查后重试。安装没有完成。${PLAIN}\n" >&2; exit 1; }

[ "$(id -u)" = "0" ] || { err "请使用 root 运行"; exit 1; }

MODE="${1:-server}"
PROJECT_DIR="$SRV_ROOT/amneziawg"
PANEL="$PROJECT_DIR/src/awg.sh"

# ---------- 依赖 ----------
deps_check() {
    local miss=() b
    for b in curl tar python3 openssl; do
        command -v "$b" >/dev/null 2>&1 || miss+=("$b")
    done
    # ss 提供端口占用检测; 缺失时 lib.sh 会回退 /proc/net 解析
    command -v ss >/dev/null 2>&1 || warn "未找到 ss, 端口检测将回退 /proc/net (精度略低)"

    # amneziawg-go 需要 TUN
    [[ -c /dev/net/tun ]] || warn "未发现 /dev/net/tun, AmneziaWG 无法启动 (需内核 tun 模块)"

    ((${#miss[@]} == 0)) && return 0
    info "安装依赖: ${miss[*]}"
    if command -v apt-get >/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y --no-install-recommends "${miss[@]}" >/dev/null 2>&1
    elif command -v dnf >/dev/null; then
        dnf install -y "${miss[@]}" >/dev/null 2>&1
    elif command -v yum >/dev/null; then
        yum install -y "${miss[@]}" >/dev/null 2>&1
    elif command -v apk >/dev/null; then
        apk add --no-cache "${miss[@]}" >/dev/null 2>&1
    else
        die "未识别包管理器, 请手动安装: ${miss[*]}"
    fi
    ok "依赖就绪"
}

# ---------- 取码 ----------
# ---------- 下载通道代理 ----------
# 很多机器的代理只写在 /etc/profile.d/ 里, 而非登录 shell 不加载该文件
# (ssh host 'cmd'、面板内执行、定时任务) —— 结果本机明明开着代理,
# 内核/Go 依赖下载却走直连直到超时。CC 就是这种机器: xray 代理正常,
# 但不设环境变量时 curl 到 GitHub 直接超时。
#
# 处理原则 (与 sing-box-core 一致):
#   1. 用户显式设过 http_proxy/https_proxy -> 原样用, 不干预
#   2. 否则探测本机常见代理端口, 列出可用的让用户选
#   3. 默认直连; 一个都没探测到时不打扰用户
#   4. 非交互 (无 TTY) 不提问, 静默直连
# 本项目的差异: 除 127.0.0.1/localhost 外, 还探测**本机自己的 LAN IP**。
# CC 上的 xray 绑在 192.168.1.178 而不是回环, 只扫回环会漏掉这个可用代理。
AWG_PROXY_CANDS=()

_awg_lan_ips() {
    # 取默认路由所用网卡上的 IPv4; 拿不到就返回空
    local dev ip
    dev=$(ip route show default 2>/dev/null | awk '/ via /{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -z "$dev" ]] && return 0
    while read -r ip; do
        [[ -n "$ip" && "$ip" != 127.* ]] && echo "$ip"
    done < <(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
}

awg_proxy_scan() {   # 探测本机可用 HTTP 代理
    AWG_PROXY_CANDS=()
    [[ -n "${https_proxy:-}${http_proxy:-}" ]] && return 0
    local host port code hosts
    hosts="127.0.0.1 localhost"
    while read -r ip; do hosts+=" $ip"; done < <(_awg_lan_ips)
    for host in $hosts; do
        for port in 7890 7891 7897 10808 10809 1080 1081 8080 8118 20171 33211; do
            (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null || continue
            exec 3<&- 2>/dev/null; exec 3>&- 2>/dev/null
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
                   --proxy "http://$host:$port" https://github.com/ 2>/dev/null)
            # 1xx~4xx 都算可用 (GitHub 会 3xx 重定向); 000 才是不可用
            [[ "$code" =~ ^[1-4] ]] || continue
            AWG_PROXY_CANDS+=("http://$host:$port")
        done
    done
    return 0
}

awg_proxy_apply() {   # $1 = 代理地址; 空 = 直连
    if [[ -n "$1" ]]; then
        export http_proxy="$1" https_proxy="$1" all_proxy="$1"
        export no_proxy="127.0.0.1,localhost,::1${no_proxy:+,$no_proxy}"
    fi
}

awg_proxy_pick() {
    if [[ -n "${https_proxy:-}${http_proxy:-}" ]]; then
        info "下载通道: 环境变量 ${https_proxy:-$http_proxy}"
        awg_proxy_save "${https_proxy:-$http_proxy}"; return 0
    fi
    awg_proxy_scan
    (( ${#AWG_PROXY_CANDS[@]} == 0 )) && return 0     # 没代理 -> 静默直连
    [[ -t 0 ]] || return 0                            # 非交互 -> 静默直连
    warn "检测到本机可用代理 (内核与 Go 依赖将从 GitHub 下载):"
    local i c
    for i in "${!AWG_PROXY_CANDS[@]}"; do
        printf "  %d) 使用 %s\n" "$((i+1))" "${AWG_PROXY_CANDS[$i]}" >&2
    done
    printf "  0) 不使用代理, 直连 (默认)\n" >&2
    c=""
    read -r -p "请选择下载通道 [0-${#AWG_PROXY_CANDS[@]}, 默认 0]: " c || c=""
    c="${c// /}"
    if [[ "$c" =~ ^[1-9][0-9]*$ ]] && (( c >= 1 && c <= ${#AWG_PROXY_CANDS[@]} )); then
        awg_proxy_apply "${AWG_PROXY_CANDS[$((c-1))]}"
        awg_proxy_save "${AWG_PROXY_CANDS[$((c-1))]}"
        ok "下载通道: ${AWG_PROXY_CANDS[$((c-1))]}"
    else
        ok "下载通道: 直连"
    fi
    return 0
}

# 记到 state/proxy.env —— 之后从面板里跑 core.sh(编译内核)也走同一通道。
# 否则用户在 install.sh 选了代理, 进面板后编译内核仍然直连失败。
awg_proxy_save() {
    local f="$SRV_ROOT/amneziawg/state/proxy.env"
    mkdir -p "$(dirname "$f")" 2>/dev/null
    printf 'AWG_PROXY=%q\n' "$1" > "$f"
}

fetch_project() {
    local url="$PROJECT_DIR"
    if [[ -d "$url/.git" ]]; then
        info "更新已有项目..."
        git -C "$url" pull --ff-only >/dev/null 2>&1 || {
            warn "git pull 失败, 尝试重新拉取"
            rm -rf "$url"
        }
    fi
    if [[ ! -f "$PANEL" ]]; then
        info "下载 AWG-Panel..."
        mkdir -p "$SRV_ROOT"
        rm -rf "$url"
        # 两条路: git clone (可复用, 后续能增量更新) 优先, 失败再退回 tarball
        if git clone -q --depth 1 --branch "$BRANCH" \
             "https://github.com/mi1314cat/AmneziaWG.git" "$url" 2>/dev/null; then
            :
        else
            mkdir -p "$url"
            curl -fsSL --max-time 180 \
                "https://codeload.github.com/mi1314cat/AmneziaWG/tar.gz/refs/heads/$BRANCH" |
                tar xz -C "$url" --strip-components=1 || die "下载失败, 请检查网络, 或用 install.sh 时选择代理通道"
        fi
    fi
    [[ -f "$PANEL" ]] || die "项目文件不完整: 未找到 $PANEL"
    chmod +x "$PANEL" "$PROJECT_DIR/src/conf/"*.sh 2>/dev/null
    ok "项目就绪: $PROJECT_DIR"
}

case "$MODE" in
    update)
        fetch_project
        ok "已更新, 重新进入面板"
        exec bash "$PANEL"
        ;;
    status)
        [[ -f "$PANEL" ]] || die "尚未安装"
        exec bash "$PANEL" service status
        ;;
    server|client)
        deps_check
        awg_proxy_pick        # 必须在 fetch_project 之前, 否则下载就已经超时了
        fetch_project
        if [[ "$MODE" == "client" ]]; then
            if [[ -f "$PROJECT_DIR/src/client/client.sh" ]]; then
                # 客户端同样需要 amneziawg-go, 官方 release 只有源码, 必须编译
                if [[ ! -x "$PROJECT_DIR/bin/amneziawg-go" ]]; then
                    info "客户端需要 amneziawg-go 内核 (官方 release 仅源码包, 将本地编译)"
                    bash "$PROJECT_DIR/src/conf/core.sh" install || die "内核安装失败"
                fi
                ok "以客户端模式启动"
                exec bash "$PROJECT_DIR/src/client/client.sh" menu
            fi
            warn "客户端面板不存在, 本次按服务端启动"
        fi
        ok "安装完成, 进入面板"
        exec bash "$PANEL"
        ;;
    *)
        echo "用法: install.sh [server|client|update|status]"
        exit 2
        ;;
esac