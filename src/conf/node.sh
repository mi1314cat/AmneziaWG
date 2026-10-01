#!/usr/bin/env bash
# ==============================================================
# node.sh — 客户端节点管理 (创建 / 列出 / 删除 / 重新生成)
#
# 每个节点自动产出三件套:
#   clients/<name>.conf          原生 AmneziaWG 配置 (手机扫码 / 官方 App 导入)
#   clients/<name>.mihomo.yaml   mihomo proxies 片段
#   clients/<name>.png           二维码 (内容 = .conf 全文)
# 以及 keys/<name>/ 下的密钥对 (0600)。
#
# mihomo 片段的字段不是抄文档, 而是按 MetaCubeX/mihomo 源码
# adapter/outbound/wireguard.go 的 WireGuardOption / AmneziaWGOption 结构生成,
# 并在 CC 上用 mihomo v1.19.30 实跑 `mihomo -t` 校验通过。
# ==============================================================
set -uo pipefail

NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$NODE_DIR/lib.sh"

# ---------- 读服务端配置 ----------
sv() { grep -E "^$1\s*=" "$AWG_SERVER_CONF" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

server_ip_detect() {    # 服务端对外地址: 优先用户填的, 否则自动探测
    local v; v=$(sv EndpointHost)
    [[ -n "$v" ]] && { echo "$v"; return 0; }
    ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

# ---------- 客户端 IP 分配 ----------
alloc_ip() {
    local base used last=1 third cand ip
    base=$(sv Address | cut -d/ -f1)
    third=$(echo "$base" | cut -d. -f1-3)
    used=$(awk -F'=' '/^AllowedIPs/{print $2}' "$AWG_SERVER_CONF" 2>/dev/null |
           tr ',' ' ' | tr -d ' ' | sed 's|/.*||')
    for cand in $(seq 2 254); do
        ip="$third.$cand"
        echo "$used" | grep -qx "$ip" || { echo "$ip"; return 0; }
    done
    return 1
}

# ==============================================================
# 产物生成
# ==============================================================
gen_native_conf() {   # $1=name  $2=客户端私钥  $3=客户端IP
    local name="$1" priv="$2" cip="$3"
    local host port mtu dns keepalive
    host=$(server_ip_detect)
    port=$(sv ListenPort)
    mtu=$(sv MTU);    mtu="${mtu:-$AWG_DEFAULT_MTU}"
    dns=$(sv DNS);    dns="${dns:-1.1.1.1, 9.9.9.9}"
    keepalive=${AWG_KEEPALIVE:-25}

    # [Peer] 段的 PublicKey 必须是**服务端**公钥。
    # 之前这里误用了客户端自己的公钥, 结果 amneziawg-go 的 handlePublicKeyLine 命中
    #   if device.staticIdentity.publicKey.Equals(publicKey) { peer.dummy = true }
    # 把这个 peer 当成"自己"直接丢弃 —— UAPI 返回 errno=0, 但 peer 根本没建立,
    # 表现就是握手永远不完成且没有任何报错。
    local srv_pub; srv_pub=$(sv PublicKey)
    if [[ -z "$srv_pub" ]]; then
        print_error "服务端配置缺少 PublicKey, 无法生成客户端配置"
        return 1
    fi

    {
        printf '[Interface]\n'
        printf 'PrivateKey = %s\n' "$priv"
        printf 'Address    = %s/32\n' "$cip"
        printf 'DNS        = %s\n' "$dns"
        printf 'MTU        = %s\n' "$mtu"
        # ---- AWG 混淆参数: 必须落在 [Interface] 段内 ----
        # 写在 [Peer] 之后会被 configparser 归到 peer 段, 客户端 UAPI 读的是
        # [Interface], 于是参数**静默丢失**, 握手包与服务端对不上且不报任何错。
        printf '\n# ---- AmneziaWG 混淆参数 (必须与服务端逐项一致) ----\n'
        local kv k v
        for kv in Jc:Jc Jmin:Jmin Jmax:Jmax S1:S1 S2:S2 S3:S3 S4:S4 H1:H1 H2:H2 H3:H3 H4:H4; do
            k="${kv%%:*}"; v=$(sv "${kv#*:}")
            [[ -n "$v" ]] && printf '%-4s = %s\n' "$k" "$v"
        done
        local cpa hp rt rv
        cpa=$(sv ContentPaddingAddition); hp=$(sv HeaderProtectionKey)
        rt=$(sv RandomTrailers);       rv=$(sv DisableCookies)
        if [[ -n "$cpa" || -n "$hp" || "$rt" == "true" || "$rv" == "true" ]]; then
            printf '\n# ---- AWG v3 高级参数 ----\n'
            [[ -n "$cpa" ]] && printf 'ContentPaddingAddition = %s\n' "$cpa"
            [[ -n "$hp"  ]] && printf 'HeaderProtectionKey    = %s\n' "$hp"
            [[ "$rt" == "true" ]] && printf 'RandomTrailers         = true\n'
            [[ "$rv" == "true" ]] && printf 'DisableCookies         = true\n'
        fi
        printf '\n[Peer]\n'
        printf 'PublicKey  = %s\n' "$srv_pub"
        printf 'AllowedIPs = 0.0.0.0/0, ::/0\n'
        printf 'Endpoint   = %s:%s\n' "$host" "$port"
        printf 'PersistentKeepalive = %s\n' "$keepalive"
    } > "$AWG_CLIENTS_DIR/.${name}.conf.tmp"
    chmod 600 "$AWG_CLIENTS_DIR/.${name}.conf.tmp"
    mv -f "$AWG_CLIENTS_DIR/.${name}.conf.tmp" "$AWG_CLIENTS_DIR/$name.conf"
}

gen_mihomo_yaml() {   # $1=name $2=priv $3=client_ip
    local name="$1" priv="$2" cip="$3"
    local host port pub mtu
    host=$(server_ip_detect); port=$(sv ListenPort); pub=$(sv PublicKey)
    mtu=$(sv MTU)

    {
        printf 'proxies:\n'
        printf '  - name: AWG-%s\n' "$name"
        printf '    type: wireguard\n'
        printf '    server: %s\n' "$host"
        printf '    port: %s\n' "$port"
        printf '    ip: %s/32\n' "$cip"
        printf '    private-key: %s\n' "$priv"
        printf '    public-key: %s\n' "$pub"
        printf '    allowed-ips:\n'
        printf '      - 0.0.0.0/0\n'
        printf '      - ::/0\n'
        printf '    udp: true\n'
        printf '    mtu: %s\n' "$mtu"
        printf '    persistent-keepalive: %s\n' "${AWG_KEEPALIVE:-25}"
        printf '    amnezia-wg-option:\n'
        printf '      version: 3\n'
        local k v
        for kv in "jc:Jc" "jmin:Jmin" "jmax:Jmax" "s1:S1" "s2:S2" "s3:S3" "s4:S4" \
                  "h1:H1" "h2:H2" "h3:H3" "h4:H4" \
                  "content-padding-addition:ContentPaddingAddition"; do
            k="${kv%%:*}"; v="${kv#*:}"
            local val; val=$(sv "$v")
            [[ -n "$val" ]] && printf '      %s: %s\n' "$k" "$val"
        done
        local hp; hp=$(sv HeaderProtectionKey)
        [[ -n "$hp" ]] && printf '      header-protection-key: %s\n' "$hp"
        [[ "$(sv RandomTrailers)" == "true" ]] && printf '      random-trailers: true\n'
        [[ "$(sv DisableCookies)" == "true" ]] && printf '      disable-cookies: true\n'
    } > "$AWG_CLIENTS_DIR/.${name}.yaml.tmp"
    mv -f "$AWG_CLIENTS_DIR/.${name}.yaml.tmp" "$AWG_CLIENTS_DIR/$name.mihomo.yaml"
}

gen_qr() {   # $1=name
    # 注意: bash 里 `local a="$1" b="...$a"` 中 b 会拿到**空值** ——
    # local 会先把所有变量置空再逐个赋值, 所以必须拆成两行。
    local name="$1"
    local f="$AWG_CLIENTS_DIR/$name.conf"
    if have qrencode; then
        qrencode -l L -o "$AWG_CLIENTS_DIR/$name.png" < "$f" 2>/dev/null &&
            print_ok "二维码: $AWG_CLIENTS_DIR/$name.png"
        qrencode -t ANSIUTF8 < "$f" 2>/dev/null >&2
        return 0
    fi
    print_warn "未安装 qrencode, 无法生成二维码 (apt install qrencode)"
    return 1
}

gen_all() {   # $1=name
    local name="$1"
    local kd="$AWG_KEYS_DIR/$name"
    # 守卫: 空名字/不存在的目录会让 `cat $kd/priv.key` 静默返回空,
    # 然后把**空 PrivateKey 写进已有的客户端配置**, 直接废掉一个本来能用的节点。
    if [[ -z "$name" || ! -f "$kd/priv.key" || ! -f "$kd/ip" ]]; then
        print_error "gen_all: 节点名无效或密钥缺失 (name='$name'), 已跳过, 现有配置未被覆盖"
        return 1
    fi
    local priv pub cip
    priv=$(cat "$kd/priv.key"); pub=$(cat "$kd/pub.key"); cip=$(cat "$kd/ip")
    if [[ -z "$priv" || -z "$cip" ]]; then
        print_error "gen_all: $name 的密钥/地址为空, 已跳过"
        return 1
    fi
    gen_native_conf "$name" "$priv" "$cip" || return 1
    gen_mihomo_yaml "$name" "$priv" "$cip"
    gen_qr "$name" || true
}

# ==============================================================
# CRUD
# ==============================================================
# 节点枚举: 列出 keys/ 下所有节点目录。
# 早期实现只匹配 client-*, 于是自定义名字(比如 cc-test)的节点在列表里
# 完全看不见, regen/del 也都找不到。
node_names() {
    [[ -d "$AWG_KEYS_DIR" ]] || return 0
    local d
    for d in "$AWG_KEYS_DIR"/*/; do
        [[ -d "$d" ]] || continue
        [[ -f "$d/pub.key" ]] || continue
        basename "$d"
    done
}

node_add() {
    print_title "创建客户端节点"
    [[ -f "$AWG_SERVER_CONF" ]] || { print_error "服务端未初始化, 先执行 server.sh init"; return 1; }

    local name cip priv pub
    name=$(safe_read "节点名称" "$(next_client_name)")
    [[ -d "$AWG_KEYS_DIR/$name" ]] && { print_error "节点 $name 已存在"; return 1; }

    cip=$(alloc_ip) || { print_error "地址池已满"; return 1; }
    print_info "分配地址: $cip/32"

    read -r priv pub < <(gen_keypair)

    mkdir -p "$AWG_KEYS_DIR/$name"
    printf '%s' "$priv" > "$AWG_KEYS_DIR/$name/priv.key"
    printf '%s' "$pub"  > "$AWG_KEYS_DIR/$name/pub.key"
    printf '%s' "$cip"  > "$AWG_KEYS_DIR/$name/ip"
    printf '%s\n' "$(date '+%F %T')" > "$AWG_KEYS_DIR/$name/created"
    chmod 700 "$AWG_KEYS_DIR/$name"
    chmod 600 "$AWG_KEYS_DIR/$name"/*.key

    # 追加 peer 到 server.conf ([Peer] 段必须在最后追加, 不要动 [Interface])
    {
        printf '\n[Peer]                          # %s\n' "$name"
        printf 'PublicKey  = %s\n' "$pub"
        printf 'AllowedIPs = %s/32\n' "$cip"
        printf 'PersistentKeepalive = %s\n' "${AWG_KEEPALIVE:-25}"
    } >> "$AWG_SERVER_CONF"

    gen_all "$name"

    print_ok "节点 $name 已创建"
    if have_svc && systemctl is-active --quiet "$AWG_UNIT"; then
        if bash "$NODE_DIR/server.sh" reload >/dev/null 2>&1; then
            print_ok "peer 已热加载到运行中的服务"
        else
            print_error "热加载失败, 已写入 server.conf 但未生效; 请检查后执行 server.sh reload"
        fi
    else
        print_info "服务未运行, 启动后生效"
    fi
}

node_list() {
    print_title "客户端节点"
    local any=0
    for _n in $(node_names); do any=1; break; done
    ((any)) || { print_info "还没有任何节点"; return 0; }
    printf "  %-14s %-15s %-20s %s\n" "名称" "地址" "创建时间" "产物" >&2
    local n d
    for n in $(node_names); do
        d="$AWG_KEYS_DIR/$n"
        local art=""
        [[ -f "$AWG_CLIENTS_DIR/$n.conf" ]]          && art+="conf "
        [[ -f "$AWG_CLIENTS_DIR/$n.mihomo.yaml" ]]   && art+="mihomo "
        [[ -f "$AWG_CLIENTS_DIR/$n.png" ]]          && art+="qr "
        printf "  %-14s %-15s %-20s %s\n" \
            "$n" "$(cat "$d/ip" 2>/dev/null)" \
            "$(cat "$d/created" 2>/dev/null | cut -d. -f1)" "$art" >&2
    done
}

node_show() {
    local name="${1:-}"
    [[ -n "$name" ]] || { print_error "用法: node.sh show <name>"; return 1; }
    [[ -f "$AWG_CLIENTS_DIR/$name.conf" ]] || { print_error "无此节点: $name"; return 1; }
    cat "$AWG_CLIENTS_DIR/$name.conf"
}

node_del() {
    print_title "删除客户端节点"
    node_list
    local name; name=$(safe_read "要删除的节点名" "")
    [[ -z "$name" ]] && { print_info "已取消"; return 0; }
    [[ -d "$AWG_KEYS_DIR/$name" ]] || { print_error "无此节点: $name"; return 1; }
    yes_no "确认删除 $name (含密钥与全部产物)" n || { print_info "已取消"; return 0; }

    local pub; pub=$(cat "$AWG_KEYS_DIR/$name/pub.key" 2>/dev/null)
    # 从 server.conf 移除该 peer 段
    if [[ -n "$pub" ]]; then
        python3 - "$AWG_SERVER_CONF" "$pub" "$name" <<'PY'
import sys, re
path, pub, name = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding='utf-8').read()
blocks = re.split(r'(?m)^\[Peer\]', src)
head, peers = blocks[0], blocks[1:]
keep = []
for b in peers:
    if pub in b or name in b.splitlines()[0]:
        continue
    keep.append('[Peer]' + b)
open(path, 'w', encoding='utf-8').write(head + ''.join(keep))
PY
    fi
    rm -rf "$AWG_KEYS_DIR/$name"
    rm -f "$AWG_CLIENTS_DIR/$name.conf" "$AWG_CLIENTS_DIR/$name.mihomo.yaml" \
          "$AWG_CLIENTS_DIR/$name.png" "$AWG_CLIENTS_DIR/$name.qr.txt"
    print_ok "节点 $name 已删除"
    have_svc && systemctl is-active --quiet "$AWG_UNIT" && bash "$NODE_DIR/server.sh" reload
}

node_regen() {
    print_title "重新生成产物"
    node_list
    local name; name=$(safe_read "节点名 (留空=全部)" "")
    if [[ -z "$name" ]]; then
        local n
        for n in $(node_names); do
            gen_all "$n" && print_ok "$n 已重新生成"
        done
    else
        gen_all "$name" && print_ok "$name 已重新生成"
    fi
}

node_menu() {
    while true; do
        print_title "客户端节点"
        echo "1) 创建节点"
        echo "2) 查看列表"
        echo "3) 查看配置"
        echo "4) 重新生成产物"
        echo "5) 删除节点"
        echo "0) 返回"
        printf "选择: " >&2
        read -r c || exit 0
        c=$(clean_input "$c")
        case "$c" in
            1) node_add ;;
            2) node_list ;;
            3) node_show "$(safe_read '节点名' '')" ;;
            4) node_regen ;;
            5) node_del ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
        printf "回车继续..." >&2; read -r || exit 0
    done
}

case "${1:-menu}" in
    add)   node_add ;;
    list)  node_list ;;
    show)  node_show "${2:-}" ;;
    del)   node_del ;;
    regen) node_regen ;;
    menu)  node_menu ;;
    *) echo "用法: $0 {add|list|show <name>|del|regen|menu}"; exit 2 ;;
esac