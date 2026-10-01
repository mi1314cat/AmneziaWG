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
        rm -rf "$url"; mkdir -p "$url"
        curl -fsSL --max-time 180 \
            "https://codeload.github.com/mi1314cat/AmneziaWG/tar.gz/refs/heads/$BRANCH" |
            tar xz -C "$url" --strip-components=1 || die "下载失败, 请检查网络"
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