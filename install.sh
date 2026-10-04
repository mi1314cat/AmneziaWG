#!/usr/bin/env bash
# ==============================================================
# install.sh — AWG-Panel 一键入口
#   bash <(curl -fsSL https://github.com/mi1314cat/AmneziaWG/raw/main/install.sh)
#
# 职责: 取码 -> 环境自检 -> 初始化 -> 进入面板
#       (所有交互都在面板里, 本脚本只做"取码 + 装依赖 + 交接")
#
# 可选参数:
#   install.sh                沿用上次安装的角色进入面板 (推荐)
#   install.sh server         安装为服务端
#   install.sh client         安装为客户端
#   install.sh role           查看当前角色 (role server|client 可切换)
#   install.sh update         拉取最新代码后进入原角色面板
#   install.sh status         只看状态
#
# 服务端与客户端是**两套分开的面板**, 装在同一目录下, 一台机器只能选一个。
# 首次安装时选定的角色会记在 state/role, 之后裸跑这条命令总是进同一个面板。
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

PROJECT_DIR="$SRV_ROOT/amneziawg"
PANEL="$PROJECT_DIR/src/awg.sh"
ROLE_FILE="$PROJECT_DIR/state/role"

# 这两个角色是**分开的两套面板**, 装在同一个目录下, 但只能选一个。
# 安装时选的哪个角色必须记下来 —— 否则下次再敲同一条命令会进错面板,
# 用户根本不知道自己在哪台机器上装的什么。
ROLE=""
detect_role() {
    local rf="$PROJECT_DIR/state/role"
    [[ -f "$rf" ]] && { ROLE=$(head -1 "$rf" 2>/dev/null | tr -d '[:space:]'); return 0; }
    # 没有标记的旧安装: 按实际留下的配置反推
    if   [[ -f "$PROJECT_DIR/server/server.conf" ]]; then ROLE="server"
    elif [[ -f "$PROJECT_DIR/client/client.conf"  || -d "$PROJECT_DIR/keys" ]]; then ROLE="client"
    else ROLE="server"; fi
}
save_role() { mkdir -p "$PROJECT_DIR/state"; echo "$1" > "$ROLE_FILE"; }
panel_for() { [[ "$1" == "client" ]] \
                && echo "$PROJECT_DIR/src/client/client.sh" \
                || echo "$PANEL"; }

# 裸跑 (无参数) 时, 沿用上次装的角色
if [[ $# -eq 0 ]]; then
    if [[ -d "$PROJECT_DIR" ]]; then detect_role; else ROLE="server"; fi
    MODE="$ROLE"
else
    MODE="${1:-server}"
fi

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
AWG_PROXY_CHOSEN=""

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
        AWG_PROXY_CHOSEN="${https_proxy:-$http_proxy}"; return 0
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
        AWG_PROXY_CHOSEN="${AWG_PROXY_CANDS[$((c-1))]}"
        ok "下载通道: ${AWG_PROXY_CANDS[$((c-1))]}"
    else
        AWG_PROXY_CHOSEN=""
        ok "下载通道: 直连"
    fi
    return 0
}

# 记到 state/proxy.env —— 之后从面板里跑 core.sh(编译内核)也走同一通道。
# 否则用户在 install.sh 选了代理, 进面板后编译内核仍然直连失败。
#
# 注意调用时机: 必须在 fetch_project **之后**。fetch_project 在首次安装时
# 会 `rm -rf "$PROJECT_DIR"`, 提前写进去的文件会被它连目录一起删掉。
awg_proxy_persist() {
    [[ -z "$AWG_PROXY_CHOSEN" ]] && return 0
    local f="$SRV_ROOT/amneziawg/state/proxy.env"
    mkdir -p "$(dirname "$f")" 2>/dev/null
    printf 'AWG_PROXY=%q\n' "$AWG_PROXY_CHOSEN" > "$f"
    return 0
}

fetch_project() {
    local url="$PROJECT_DIR"
    # 注意: keys/ clients/ client/ server/ share/ logs/ bin/ 全部落在
    # $url 这一棵树下面。**任何 rm -rf "$url" 都会连用户的密钥和配置一起删掉。**
    # 之前 git pull 失败就 rm -rf, 已经实测造成过一次配置全丢。
    if [[ -d "$url/.git" ]]; then
        info "更新已有项目..."
        if ! git -C "$url" pull --ff-only >/dev/null 2>&1; then
            # 头号原因是工作区有本地改动 (含直接 scp 进树的补丁), 丢弃即可
            warn "git pull 失败, 尝试丢弃本地改动后重试"
            git -C "$url" checkout -- . >/dev/null 2>&1
            git -C "$url" clean -fdq -- src install.sh >/dev/null 2>&1
            if ! git -C "$url" pull --ff-only >/dev/null 2>&1; then
                warn "git pull 仍失败, 只覆盖源码文件 (配置与密钥原样保留)"
                local tmp; tmp=$(mktemp -d)
                if git clone -q --depth 1 --branch "$BRANCH" "$REPO" "$tmp" 2>/dev/null; then
                    # 只换代码, 绝不碰数据目录
                    rm -rf "$url/src"
                    cp -a "$tmp/src" "$url/src"
                    [[ -f "$tmp/install.sh" ]] && cp -a "$tmp/install.sh" "$url/install.sh"
                    [[ -f "$tmp/README.md" ]] && cp -a "$tmp/README.md" "$url/README.md"
                else
                    rm -rf "$tmp"
                    die "更新失败, 且无法下载新代码。请检查网络后重试 (现有配置未改动)"
                fi
            fi
        fi
    fi
    if [[ ! -f "$PANEL" ]]; then
        info "下载 AWG-Panel..."
        mkdir -p "$SRV_ROOT"
        [[ -e "$url" && ! -d "$url" ]] && rm -f "$url"
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
        detect_role
        fetch_project
        ok "已更新, 重新进入$([[ $ROLE == client ]] && echo 客户端 || echo 服务端)面板"
        exec bash "$(panel_for "$ROLE")"
        ;;
    role)
        [[ -d "$PROJECT_DIR" ]] || die "尚未安装"
        detect_role
        if [[ -n "${2:-}" ]]; then
            [[ "$2" == "server" || "$2" == "client" ]] || die "用法: install.sh role {server|client}"
            save_role "$2"
            ok "已切换为 $([[ $2 == client ]] && echo 客户端 || echo 服务端)"
        fi
        printf "\n  当前角色: "
        if   [[ "$ROLE" == "client" ]]; then printf "${GREEN}客户端 · CLIENT${PLAIN}  (面板: $PROJECT_DIR/src/client/client.sh)\n"
        else printf "${GREEN}服务端 · SERVER${PLAIN}  (面板: $PANEL)\n"; fi
        printf "  切换: install.sh role {server|client}\n\n"
        exit 0
        ;;
    status)
        [[ -f "$PANEL" ]] || die "尚未安装"
        exec bash "$PANEL" service status
        ;;
    server|client)
        detect_role
        save_role "$MODE"                     # 先记下来, 后面任何一步失败都不至于失忆
        deps_check
        awg_proxy_pick          # apply 必须在 fetch 之前, 否则下载就已经超时了
        fetch_project
        awg_proxy_persist       # 落盘必须在 fetch 之后, 避免被更新过程冲掉
        if [[ "$MODE" == "client" ]]; then
            [[ -f "$PROJECT_DIR/src/client/client.sh" ]] \
                || die "客户端面板不存在: $PROJECT_DIR/src/client/client.sh"
            # 客户端同样需要 amneziawg-go, 官方 release 只有源码, 必须编译
            if [[ ! -x "$PROJECT_DIR/bin/amneziawg-go" ]]; then
                info "客户端需要 amneziawg-go 内核 (官方 release 仅源码包, 将本地编译)"
                bash "$PROJECT_DIR/src/conf/core.sh" install || die "内核安装失败"
            fi
            ok "以客户端模式启动"
            exec bash "$PROJECT_DIR/src/client/client.sh" menu
        fi
        ok "安装完成, 进入服务端面板"
        exec bash "$PANEL"
        ;;
    *)
        echo "用法: install.sh [server|client|update|status]"
        exit 2
        ;;
esac