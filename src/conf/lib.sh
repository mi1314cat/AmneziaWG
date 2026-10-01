#!/usr/bin/env bash
# ==============================================================
# lib.sh — AWG-Panel 公共库
#   被 src/awg.sh 与 src/conf/*.sh source, 不单独执行。
#   所有 UI 输出走 stderr, 保证 source 时不污染调用方的 stdout 管道。
# ==============================================================

# ---------- 路径常量 (根在 /opt, 对齐 xary-core / sb-panel 习惯) ----------
AWG_ROOT="${AWG_ROOT:-/opt/awg-panel/amneziawg}"
AWG_BIN="$AWG_ROOT/bin/amneziawg-go"
AWG_VERSION_FILE="$AWG_ROOT/bin/version"
AWG_SERVER_DIR="$AWG_ROOT/server"
AWG_SERVER_CONF="$AWG_SERVER_DIR/server.conf"
AWG_CLIENTS_DIR="$AWG_ROOT/clients"
AWG_KEYS_DIR="$AWG_ROOT/keys"
AWG_LOGS_DIR="$AWG_ROOT/logs"
AWG_STATE_DIR="$AWG_ROOT/state"
AWG_NAT_MARK="awg-panel"      # NAT/防火墙规则统一标记, 清理时只认这个

awg_proxy_apply() {   # lib.sh 自带一份: core.sh 等模块不经过 install.sh
    [[ -n "${1:-}" ]] || return 0
    export http_proxy="$1" https_proxy="$1" all_proxy="$1"
    export no_proxy="127.0.0.1,localhost,::1${no_proxy:+,$no_proxy}"
}

# 下载通道: install.sh 选好的代理落在这里, 之后从面板里跑 core.sh
# (编译内核要下 Go 工具链与模块) 也走同一条通道。
# 不在这里读的话, 用户在安装时选了代理, 进面板后编译仍然直连失败。
if [[ -z "${https_proxy:-}${http_proxy:-}" && -f "$AWG_STATE_DIR/proxy.env" ]]; then
    # shellcheck disable=SC1091
    . "$AWG_STATE_DIR/proxy.env"
    [[ -n "${AWG_PROXY:-}" ]] && awg_proxy_apply "$AWG_PROXY"
fi
AWG_BACKUP_DIR="$AWG_ROOT/backup"

AWG_IFACE="${AWG_IFACE:-awg0}"
AWG_UNIT="${AWG_UNIT:-amneziawg}"
AWG_UNIT_FILE="/etc/systemd/system/$AWG_UNIT.service"

AWG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWG_UAPI_PY="$AWG_LIB_DIR/uapi.py"
AWG_KEYGEN_PY="$AWG_LIB_DIR/keygen.py"

# AWG 默认基线 (实测可用: RN 上与 mihomo v1.19.30 互通)
AWG_DEFAULT_TAG="v3.1.20260828"
AWG_DEFAULT_JC=5
AWG_DEFAULT_JMIN=40
AWG_DEFAULT_JMAX=70
AWG_DEFAULT_S1=0
AWG_DEFAULT_S2=15
AWG_DEFAULT_S3=0
AWG_DEFAULT_S4=0
AWG_DEFAULT_SUBNET="10.66.66.1/24"
AWG_DEFAULT_PORT=41871
AWG_DEFAULT_MTU=1280
AWG_HEADER_NONCE_MIN=12      # device/noise-types.go: HeaderCipherNonceSize

# ---------- UI ----------
# ---------- 颜色 / UI (与 xary-core / sing-box-core 的取值保持一致) ----------
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; MAGENTA="\e[95m"; CYAN="\e[96m"; BOLD="\e[1m"; RESET="\e[0m"

print_info()  { printf "${CYAN}[Info]${RESET} %s\n" "$1" >&2; }
print_ok()    { printf "${GREEN}[OK]${RESET} %s\n" "$1" >&2; }
print_warn()  { printf "${YELLOW}[Warn]${RESET} %s\n" "$1" >&2; }
print_error() { printf "${RED}[Error]${RESET} %s\n" "$1" >&2; }

print_title() {
    printf "${MAGENTA}${BOLD}" >&2
    printf "╔══════════════════════════════════════════════╗\n" >&2
    printf "║ %-44s ║\n" "$1" >&2
    printf "╚══════════════════════════════════════════════╝\n" >&2
    printf "${RESET}" >&2
}

# ---------- 通用 ----------
have()      { command -v "$1" >/dev/null 2>&1; }
have_svc()  { [[ -d /run/systemd/system ]]; }
root_only() {
    [[ "$(id -u)" == "0" ]] || { print_error "请使用 root 运行"; exit 1; }
}
clean_input() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

safe_read() {   # $1=提示 $2=默认值; 结果写 stdout
    local prompt="$1" def="${2:-}" input
    if [[ -n "$def" ]]; then
        printf "%s (默认: %s): " "$prompt" "$def" >&2
    else
        printf "%s: " "$prompt" >&2
    fi
    if ! read -r input; then echo >&2; exit 0; fi    # EOF 退出, 防止非交互下刷屏
    input=$(clean_input "$input")
    printf '%s' "${input:-$def}"
}
yes_no() {      # $1=提示 $2=默认 y|n ; 返回 0 = yes
    local prompt="$1" def="${2:-y}" c
    printf "%s [%s]: " "$prompt" "$([[ $def == y ]] && echo Y/n || echo y/N)" >&2
    read -r c || { echo >&2; exit 0; }
    c=$(clean_input "$c"); c="${c:-$def}"
    [[ "$c" =~ ^[Yy] ]]
}

lan_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) print_error "不支持的架构: $(uname -m)"; return 1 ;;
    esac
}

# ==============================================================
# 端口占用检测 (需求: 端口冲突禁止直接覆盖已有服务)
# ==============================================================
PORT_KIND=""
PORT_WHO=""
_SS_OK=-1        # 惰性探测: ss 能否用 netlink

_ss_usable() {
    [[ "$_SS_OK" == "1" ]] && return 0
    [[ "$_SS_OK" == "0" ]] && return 1
    if ss -Hlnp >/dev/null 2>&1; then _SS_OK=1; else _SS_OK=0; fi
    [[ "$_SS_OK" == "1" ]]
}

# netlink 不可用时的回退: 直接读 /proc/net/* (容器/受限环境常见)
_proc_net_ports() {   # $1=tcp|udp ; 输出 "端口 proto"
    local proto="$1" p
    local -a files
    if [[ "$proto" == "tcp" ]]; then files=(/proc/net/tcp /proc/net/tcp6)
    else files=(/proc/net/udp /proc/net/udp6); fi
    for p in "${files[@]}"; do
        [[ -r "$p" ]] || continue
        # tcp: 只取 LISTEN(0A); udp: 所有条目都是已绑定
        awk -v proto="$proto" '
            NR > 1 {
                if (proto == "tcp" && $4 != "0A") next
                split($2, a, ":")
                print strtonum("0x" a[2])
            }' "$p" 2>/dev/null
    done
}

_proc_port_who() {   # $1=端口 -> 占用进程名 (通过 inode 反查 /proc/*/fd)
    local port="$1" ino f pid
    for f in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do
        [[ -r "$f" ]] || continue
        ino=$(awk -v p="$(printf '%04X' "$port")" '
            NR > 1 {
                split($2, a, ":")
                if (a[2] == p) { print $10; exit }
            }' "$f" 2>/dev/null)
        [[ -n "$ino" ]] && break
    done
    [[ -z "$ino" ]] && return 0
    for fd in /proc/[0-9]*/fd/*; do
        pid=$(echo "$fd" | cut -d/ -f3)
        [[ "$(readlink "$fd" 2>/dev/null)" == "socket:[$ino]" ]] || continue
        echo "$(cat "/proc/$pid/comm" 2>/dev/null)($pid)"
        return 0
    done
}

port_state() {   # $1=端口; 设置 PORT_KIND(free|tcp|udp|both) 与 PORT_WHO(占用进程)
    local p="$1"
    PORT_KIND="free"; PORT_WHO=""
    local tcp udp
    if _ss_usable; then
        tcp=$(ss -Htlpn "sport = :$p" 2>/dev/null)
        udp=$(ss -Hulpn "sport = :$p" 2>/dev/null)
    else
        tcp=$(_proc_net_ports tcp | grep -qx "$p" && echo x)
        udp=$(_proc_net_ports udp | grep -qx "$p" && echo x)
    fi
    [[ -n "$tcp" && -n "$udp" ]] && PORT_KIND="both"
    [[ -n "$tcp" && -z "$udp" ]] && PORT_KIND="tcp"
    [[ -z "$tcp" && -n "$udp" ]] && PORT_KIND="udp"
    PORT_WHO=$(printf '%s\n%s\n' "$tcp" "$udp" |
        grep -oE 'users:\(\("[^"]+"' | sed 's/users:(("//; s/"$//' | sort -u | paste -sd, -)
    [[ -z "$PORT_WHO" && "$PORT_KIND" != "free" ]] && PORT_WHO=$(_proc_port_who "$p")
    [[ "$PORT_KIND" == "free" ]]
}

port_desc() {
    case "$PORT_KIND" in
        free) printf "空闲" ;;
        tcp)  printf "TCP 已被占用 (%s)" "${PORT_WHO:-未知进程}" ;;
        udp)  printf "UDP 已被占用 (%s)" "${PORT_WHO:-未知进程}" ;;
        both) printf "TCP+UDP 均被占用 (%s)" "${PORT_WHO:-未知进程}" ;;
    esac
}

want_proto() {    # $1=want(tcp|udp|both) ; 0 = 满足
    case "$1" in
        both) [[ "$PORT_KIND" == "free" || "$PORT_KIND" == "both" ]] ;;
        tcp)  [[ "$PORT_KIND" == "free" || "$PORT_KIND" == "tcp"  ]] ;;
        udp)  [[ "$PORT_KIND" == "free" || "$PORT_KIND" == "udp"  ]] ;;
    esac
}

random_free_port() {  # $1=lo $2=hi $3=proto(tcp|udp|both)
    local lo="$1" hi="$2" proto="$3" p
    for _ in $(seq 1 200); do
        p=$(shuf -i "$lo-$hi" -n 1)
        port_state "$p" && want_proto "$proto" && { echo "$p"; return 0; }
    done
    return 1
}

# 交互式端口: 冲突时给"自动换 / 手输"二选一, 绝不覆盖已有服务
safe_read_port() {   # $1=默认 $2=proto
    local def="$1" proto="${2:-both}" input
    while true; do
        input=$(safe_read "监听端口 ($proto)" "$def")
        [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )) ||
            { print_error "端口必须是 1-65535 的数字"; def="$(random_free_port 10000 60000 "$proto")"; continue; }
        if port_state "$input" && want_proto "$proto"; then
            echo "$input"; return 0
        fi
        print_warn "端口 $input 不可用: $(port_desc)"
        print_info "占用方: ${PORT_WHO:-未知}"
        if yes_no "自动换一个空闲端口" y; then
            def=$(random_free_port 10000 60000 "$proto") || { print_error "未找到空闲端口"; return 1; }
            print_info "新端口候选: $def"
        fi
    done
}

# ==============================================================
# 防火墙 (ufw / firewalld / iptables 回退)
# 放行的端口登记到 state/.fw-ports, 卸载时按清单精确清理
# ==============================================================
fw_register() { echo "$1" >> "$AWG_STATE_DIR/.fw-ports" 2>/dev/null; }

open_port() {      # $1=端口 $2=proto(udp|tcp|both)
    local port="$1" proto="${2:-udp}" mgr
    mkdir -p "$AWG_STATE_DIR" 2>/dev/null
    grep -qxF "$port/proto" "$AWG_STATE_DIR/.fw-ports" 2>/dev/null || fw_register "$port/$proto"
    if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        [[ "$proto" == both ]] && { ufw allow "$port/udp" >/dev/null 2>&1; ufw allow "$port/tcp" >/dev/null 2>&1; }
        [[ "$proto" == udp  ]] && ufw allow "$port/udp" >/dev/null 2>&1
        [[ "$proto" == tcp  ]] && ufw allow "$port/tcp" >/dev/null 2>&1
        return 0
    fi
    if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --zone=public --add-port="$port/$proto" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1; return 0
    fi
    if have iptables; then
        [[ "$proto" == both || "$proto" == udp ]] && \
            { iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$port" -j ACCEPT; }
        [[ "$proto" == both || "$proto" == tcp ]] && \
            { iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT; }
        return 0
    fi
    print_warn "无防火墙工具, 端口 $port 可能需要你自行放行"
    return 0
}

# ==============================================================
# ---------- NAT 清理 (唯一实现) ----------
# 早期 apply.sh 的 nat_del 用 `${line%% *}` 取源地址, 实际取到的是 "-A";
# 拼出来的删除命令是 `-D POSTROUTING -s -A ...`, 内核直接不认, 于是
# 每次 `systemctl stop` 都留下一条 MASQUERADE 残留。uninstall.sh 当时用的是
# 另一套正确写法 —— 两处各判各的, 这正是必须收敛成一份实现的原因。
nat_cleanup() {   # 幂等; 无匹配则什么都不做
    have iptables || return 0
    local n=0 line
    while read -r line; do
        [[ -z "$line" ]] && continue
        # `iptables -S` 的行形如: -A POSTROUTING -s 10.66.66.0/24 -o eth0 -m comment ...
        # 去掉 "-A POSTROUTING " 前缀后整体回传给 -D, 规则必须逐字一致才能匹配
        if iptables -t nat -D POSTROUTING ${line#-A POSTROUTING } 2>/dev/null; then
            n=$((n + 1))
        fi
    done < <(iptables -t nat -S POSTROUTING 2>/dev/null | grep -F -- "comment $AWG_NAT_MARK")
    [[ $n -gt 0 ]] && print_info "已清理 $n 条 NAT 规则"
    return 0
}

# sysctl 原值记账: 开了 ip_forward 却不记原值, 卸载后机器上就留着一处改动
sysctl_remember() {   # $1=key
    local f="$AWG_STATE_DIR/sysctl.saved"
    [[ -f "$f" ]] && return 0
    sysctl -n "$1" 2>/dev/null | head -1 > "$f" || rm -f "$f"
}

sysctl_restore() {   # $1=key
    local f="$AWG_STATE_DIR/sysctl.saved"
    [[ -f "$f" ]] || return 0
    local v; v=$(head -1 "$f" 2>/dev/null)
    [[ -n "$v" ]] && sysctl -w "$1=$v" >/dev/null 2>&1
    rm -f "$f"
}

# ---------- server.conf 定点修改 ----------
# 只改 [Interface] 段内的键。server.conf 里 [Peer] 段同样有 PublicKey/AllowedIPs,
# 分段写错会直接毁掉已建好的节点, 所以这里严格按段边界处理。
conf_set() {   # $1=Key $2=Value
    local key="$1" val="$2" f="$AWG_SERVER_CONF"
    [[ -f "$f" ]] || { print_error "缺少 $f"; return 1; }
    local tmp; tmp=$(mktemp)
    awk -v k="$key" -v v="$val" '
        /^\[/ { inif = ($0 ~ /^\[Interface\]/); print; next }
        inif && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print k " = " v; hit=1; next }
        { print }
    ' "$f" > "$tmp"
    # 该键原本不存在 -> 插到第一个 [Peer] 之前(即 [Interface] 末尾)
    if ! grep -qE "^[[:space:]]*$key[[:space:]]*=" "$tmp"; then
        awk -v k="$key" -v v="$val" '
            /^\[Peer/ && !done { print k " = " v; done=1 }
            { print }' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
    fi
    mv "$tmp" "$f"
}

conf_del() { sed -i "/^[[:space:]]*$1[[:space:]]*=/d" "$AWG_SERVER_CONF"; }

# 密钥 (base64 面向 .conf / mihomo; UAPI 内部由 uapi.py 转 hex)
# ==============================================================
gen_keypair() {    # stdout: "<priv_b64> <pub_b64>"
    python3 "$AWG_KEYGEN_PY" gen | tr '\n' ' ' | sed 's/ $//'
    echo
}

pubkey_from_priv() { python3 "$AWG_KEYGEN_PY" pub "$1"; }

# ==============================================================
# AWG 混淆参数生成 (需求: 不要默认开满, 基础档已实测可用)
# ==============================================================
random_h_set() {   # 生成 4 个互不相同、且不等于常见值的 h1..h4
    local -a hs=()
    while ((${#hs[@]} < 4)); do
        local v=$(( (RANDOM * RANDOM) % 1000 + 100 ))
        [[ " ${hs[*]-} " == *" $v "* ]] && continue
        hs+=("$v")
    done
    printf '%s %s %s %s\n' "${hs[0]}" "${hs[1]}" "${hs[2]}" "${hs[3]}"
}

random_hkey() { head -c 32 /dev/urandom | base64 -w0; }

validate_awg() {   # $1=server.conf; 交给 uapi.py 统一校验并输出渲染结果
    python3 "$AWG_UAPI_PY" render "$1"
}

# ==============================================================
# UAPI 下发 / 回读
# ==============================================================
uapi_apply() {     # $1=server.conf
    local rendered
    rendered=$(validate_awg "$1") || return 1
    printf '%s\n' "$rendered" | python3 "$AWG_UAPI_PY" set "$AWG_IFACE" -
}

uapi_get() {
    python3 "$AWG_UAPI_PY" get "$AWG_IFACE" 2>/dev/null
}

# ==============================================================
# 事务化落盘: 改配置 -> 渲染 -> 应用 -> 失败回滚
# ==============================================================
state_backup() {   # $1=说明; 备份 server.conf + clients/
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    local d="$AWG_BACKUP_DIR/$ts"
    mkdir -p "$d"
    [[ -f "$AWG_SERVER_CONF" ]] && cp -f "$AWG_SERVER_CONF" "$d/server.conf"
    [[ -d "$AWG_CLIENTS_DIR" ]] && cp -rf "$AWG_CLIENTS_DIR" "$d/" 2>/dev/null
    printf '%s' "$d"
}

state_rollback() { # $1=备份目录
    local d="$1"
    [[ -f "$d/server.conf" ]] && cp -f "$d/server.conf" "$AWG_SERVER_CONF"
    [[ -d "$d/clients" ]] && { rm -rf "$AWG_CLIENTS_DIR"; cp -rf "$d/clients" "$AWG_CLIENTS_DIR"; }
    print_warn "已回滚到: $d"
}

# 下发 server.conf 并确保生效; 失败自动回滚
apply_server_conf() {   # $1=server.conf
    local bak; bak=$(state_backup "apply")
    if uapi_apply "$1"; then
        print_ok "配置已生效"
        return 0
    fi
    print_error "配置下发失败, 正在回滚"
    [[ -f "$bak/server.conf" ]] && cp -f "$bak/server.conf" "$AWG_SERVER_CONF"
    systemctl restart "$AWG_UNIT" >/dev/null 2>&1
    sleep 2
    [[ -f "$AWG_SERVER_CONF" ]] && uapi_apply "$AWG_SERVER_CONF" >/dev/null 2>&1
    print_warn "已回滚到上一个可用配置"
    return 1
}

# ==============================================================
# 子网 / 客户端 IP 分配
# ==============================================================
subnet_base() { grep -E '^Address\s*=' "$AWG_SERVER_CONF" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ' | cut -d/ -f1; }
subnet_cidr() { grep -E '^Address\s*=' "$AWG_SERVER_CONF" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ' | cut -d/ -f2; }

used_client_ips() {
    [[ -f "$AWG_SERVER_CONF" ]] || return 0
    awk -F'=' '/^AllowedIPs/{print $2}' "$AWG_SERVER_CONF" | tr ',' ' ' | tr -d ' ' | sed 's|/.*||'
}

next_client_ip() {   # 输出下一个未使用的 .N
    local base used last=1 cand
    base=$(subnet_base); [[ -n "$base" ]] || return 1
    local -A u=()
    while read -r ip; do [[ -n "$ip" ]] && u["$ip"]=1; done < <(used_client_ips)
    local third; third=$(echo "$base" | cut -d. -f1-3)
    for cand in $(seq 2 254); do
        [[ -n "${u["$third.$cand"]-}" ]] || { echo "$third.$cand"; return 0; }
    done
    return 1
}

# 客户端编号: client-001, client-002 ...
next_client_name() {
    local n=1 f
    while true; do
        f=$(printf "client-%03d" "$n")
        [[ -d "$AWG_KEYS_DIR/$f" ]] || { echo "$f"; return 0; }
        ((n++))
        ((n > 999)) && { print_error "客户端数量已达上限"; return 1; }
    done
}