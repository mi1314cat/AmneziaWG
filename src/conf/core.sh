#!/usr/bin/env bash
# ==============================================================
# core.sh — amneziawg-go 内核的安装 / 更新 / 版本 / 卸载
#
# 为什么必须自己编译:
#   amnezia-vpn/amneziawg-go 的 GitHub release 只挂源码包, **没有预编译二进制**
#   (实测: v3.1.20260828 / v3.1.20260812 / v3.0.20260805 的 assets 均为空,
#    只有 archive/refs/tags/*.tar.gz)。
#   amneziawg-tools 倒是带预编译包, 但那是给**内核模块**用的 awg/awg-quick,
#   不含用户态 amneziawg-go 守护进程。
#
#   所以: 源码 -> CGO_ENABLED=0 静态编译 -> ~3.4 MB 单文件二进制, 零运行时依赖。
# ==============================================================
set -uo pipefail

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$CORE_DIR/lib.sh"

GO_VERSION_FALLBACK="1.25.0"

# ---------- 版本解析 ----------
core_latest_tag() {
    # GitHub REST API 匿名调用很容易 403, 用 releases.atom 更稳
    # title 形如 "v3.1.20260828: fix: ...", 只取 tag 段
    curl -fsSL --max-time 25 "https://github.com/amnezia-vpn/amneziawg-go/releases.atom" 2>/dev/null |
        grep -oE '<title>v?[0-9][^<]*</title>' | head -1 |
        sed -E 's|</?title>||g; s|:.*$||; s/[[:space:]]+$//'
}

core_current() {
    [[ -f "$AWG_VERSION_FILE" ]] && cat "$AWG_VERSION_FILE" || echo "未安装"
}

# ---------- 源码获取 ----------
_fetch_source() {   # $1=tag $2=目标目录
    local tag="$1" dst="$2" url
    url="https://codeload.github.com/amnezia-vpn/amneziawg-go/tar.gz/refs/tags/$tag"
    mkdir -p "$dst"
    print_info "下载源码: $tag"
    if ! curl -fsSL --max-time 180 "$url" | tar xz -C "$dst" 2>/dev/null; then
        print_error "源码下载失败: $url"
        print_info "请检查网络, 或设置 http_proxy/https_proxy 后重试"
        return 1
    fi
    find "$dst" -maxdepth 1 -mindepth 1 -type d -name 'amneziawg-go-*' | head -1
}

# ---------- 编译 ----------
# 依赖镜像链: 官方 proxy.golang.org 在部分网络(如国内线路、部分路由/小主机)根本
# 连不上, 表现是一堆 i/o timeout, 用户只能看到"所有编译方式均失败"。
# 逐个尝试, 并允许用 AWG_GOPROXY 覆盖。
_try_goproxy() {
    local cands
    if [[ -n "${AWG_GOPROXY:-}" ]]; then
        cands="$AWG_GOPROXY"
    else
        cands="https://goproxy.cn,direct https://goproxy.io,direct https://proxy.golang.org,direct"
    fi
    local d="${1:-.}"
    for g in $cands; do
        print_info "  尝试依赖镜像: ${g%%,*}"
        if ( cd "$d" && CGO_ENABLED=0 GOOS=linux GOARCH="${BUILD_ARCH:-amd64}" \
             GOPROXY="$g" GOFLAGS=-mod=mod go mod download all ) >/dev/null 2>&1; then
            echo "$g"; return 0
        fi
    done
    return 1
}

_build_local() {   # $1=src $2=dest
    local src="$1" dest="$2"
    # 依赖单独预取: 把"拉不到依赖"和"编译不过"分成两种可读的错误,
    # 否则用户只会看到满屏 i/o timeout 再一句"所有编译方式均失败"。
    local gp
    gp=$(_try_goproxy "$src") || gp="direct"
    print_info "  GOPROXY=$gp"
    ( cd "$src" && \
      CGO_ENABLED=0 GOOS=linux GOARCH="$BUILD_ARCH" GOMAXPROCS="$BUILD_PROCS" \
      GOPROXY="$gp" GOFLAGS=-mod=mod \
      go build -trimpath -p "$BUILD_PROCS" -ldflags "-s -w" -o "$dest" . ) 2>"$src/build.err"
}

_build_docker() {  # $1=src $2=dest
    local src="$1" dest="$2"
    docker run --rm -v "$src":/src -v "$(dirname "$dest")":/out \
        -e CGO_ENABLED=0 -e GOOS=linux -e "GOARCH=$BUILD_ARCH" \
        -w /src "golang:1.25" \
        go build -trimpath -ldflags "-s -w" -o "/out/$(basename "$dest")" . >/dev/null
}

_install_go_toolchain() {   # $1=目标 arch; 输出 go 路径到 stdout, 失败返回 1
    local arch="${1:-amd64}" d ver
    d=$(mktemp -d)
    ver=$(curl -fsSL --max-time 20 "https://go.dev/VERSION?m=text" 2>/dev/null | head -1)
    [[ -z "$ver" ]] && ver="go$GO_VERSION_FALLBACK"
    print_info "下载 Go 工具链 $ver (linux/$arch, 约 70MB)"
    if ! curl -fsSL --max-time 600 -o "$d/go.tgz" "https://go.dev/dl/${ver}.linux-${arch}.tar.gz" 2>/dev/null; then
        rm -rf "$d"; return 1
    fi
    mkdir -p "$d/go" && tar xzf "$d/go.tgz" -C "$d/go" --strip-components=1 || { rm -rf "$d"; return 1; }
    printf '%s' "$d/go/bin/go"
}

core_build() {     # $1=tag  $2=输出路径
    local tag="${1:-$AWG_DEFAULT_TAG}" dest="$2"
    local arch procs
    arch=$(detect_arch) || return 1
    # 小内存机器上并行编译容易被 OOM 杀掉, 按核数收敛
    procs=$(nproc 2>/dev/null || echo 1)
    ((procs > 4)) && procs=4

    local work; work=$(mktemp -d)
    local src
    src=$(_fetch_source "$tag" "$work/src")
    if [[ -z "$src" ]]; then
        rm -rf "$work"; print_error "源码获取失败"; return 1
    fi

    local ok=1
    if have go; then
        print_info "使用本机 go 编译 (arch=$arch, procs=$procs)"
        BUILD_ARCH="$arch" BUILD_PROCS="$procs" _build_local "$src" "$dest" && ok=0
        ((ok)) && print_warn "本机 go 编译失败, 尝试其它方式"
    fi

    if ((ok)); then
        local gobin
        if gobin=$(_install_go_toolchain "$arch"); then
            print_info "使用临时下载的 Go 编译 (首次较慢)"
            # PATH 必须一起带上: _build_local 里调的是裸 `go`
            if PATH="$(dirname "$gobin"):$PATH" GOROOT="$(dirname "$gobin")/.." \
               GOCACHE="$work/gocache" GOMODCACHE="$work/gomodcache" \
               BUILD_ARCH="$arch" BUILD_PROCS="$procs" _build_local "$src" "$dest"; then
                ok=0
            fi
        fi
    fi

    if ((ok)) && have docker && docker info >/dev/null 2>&1; then
        print_info "使用 docker golang:1.25 编译"
        BUILD_ARCH="$arch" _build_docker "$src" "$dest" && ok=0
        ((ok)) && print_warn "docker 编译失败"
    fi

    rm -rf "$work"
    # ok 是失败标志(0=成功)。注意用 `((ok)) &&` 而非 `||`:
    # `((0))` 的退出码是 1(假), 写成 `||` 会在成功时反而报错。
    if ((ok)); then
        print_error "所有编译方式均失败"
        local be; be=$(find "$work" -name build.err 2>/dev/null | head -1)
        if [[ -n "$be" && -s "$be" ]]; then
            print_info "最后一次编译错误 (末尾 8 行):"
            tail -8 "$be" | sed 's/^/    /' >&2
        fi
        print_info "若是依赖下载超时: export AWG_GOPROXY=https://goproxy.cn,direct"
        print_info "或设置 http_proxy/https_proxy 后重试; 也可手动编译后覆盖 $dest"
    fi
    return $((ok))
}

# ---------- 安装 ----------
core_install() {   # $1=tag(可选)
    local tag="${1:-$AWG_DEFAULT_TAG}"
    root_only
    mkdir -p "$AWG_ROOT/bin" "$AWG_SERVER_DIR" "$AWG_CLIENTS_DIR" \
             "$AWG_KEYS_DIR" "$AWG_LOGS_DIR" "$AWG_STATE_DIR" "$AWG_BACKUP_DIR"

    if [[ -f "$AWG_BIN" && -z "${1:-}" ]]; then
        print_warn "已安装 $(core_current), 如需重装请显式指定版本"
    fi

    local tmp="$AWG_ROOT/bin/.new.$$"
    core_build "$tag" "$tmp" || { rm -f "$tmp"; return 1; }

    if [[ ! -s "$tmp" ]]; then
        print_error "编译产物为空"; rm -f "$tmp"; return 1
    fi
    chmod +x "$tmp"
    printf '%s\n' "$tag" > "$AWG_VERSION_FILE"
    mv -f "$tmp" "$AWG_BIN"

    print_ok "amneziawg-go 安装完成: $tag"
    print_info "二进制: $AWG_BIN ($(du -h "$AWG_BIN" | cut -f1))"
    "$AWG_BIN" --version 2>&1 | head -1 | sed 's/^/[版本] /' >&2
}

core_update() {
    local cur latest
    cur=$(core_current)
    latest=$(core_latest_tag)
    [[ -z "$latest" ]] && { print_error "无法获取最新版本"; return 1; }
    print_info "当前: $cur  最新: $latest"
    [[ "$cur" == "$latest" ]] && { print_ok "已是最新"; return 0; }
    local bak="$AWG_BACKUP_DIR/core-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bak"
    cp -f "$AWG_BIN" "$bak/" 2>/dev/null
    print_info "已备份旧内核到 $bak"
    core_install "$latest"
}

core_uninstall() {
    print_title "卸载 amneziawg-go"
    have_svc && { systemctl stop "$AWG_UNIT" 2>/dev/null; systemctl disable "$AWG_UNIT" 2>/dev/null; }
    rm -f "$AWG_UNIT_FILE"
    have_svc && systemctl daemon-reload 2>/dev/null
    ip link del "$AWG_IFACE" 2>/dev/null
    rm -f "/var/run/amneziawg/$AWG_IFACE.sock"
    if yes_no "同时删除全部节点配置与密钥 ($AWG_CLIENTS_DIR)" n; then
        rm -rf "$AWG_CLIENTS_DIR" "$AWG_KEYS_DIR"
    fi
    rm -rf "$AWG_ROOT"
    rmdir /var/run/amneziawg 2>/dev/null
    print_ok "已卸载"
}

# ---------- 独立入口 ----------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        install)   core_install "${2:-}" ;;
        update)    core_update ;;
        current)   echo "$(core_current)" ;;
        latest)    core_latest_tag ;;
        build)     core_build "${2:-$AWG_DEFAULT_TAG}" ;;
        uninstall) root_only; core_uninstall ;;
        *) echo "用法: $0 {install [tag]|update|current|latest|build [tag]|uninstall}"; exit 2 ;;
    esac
fi