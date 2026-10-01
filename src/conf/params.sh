#!/usr/bin/env bash
# ==============================================================
# params.sh — AmneziaWG 混淆参数档位与高级参数
#
# 为什么要单独一个模块:
#   Jc/Jmin/Jmax/S1-S4/H1-H4 这些参数**两端必须逐项一致**, 差一个都会导致
#   握手包结构对不上。而且它们不是"填了就生效"的东西, 有硬性前置条件:
#     * HeaderProtectionKey 启用时 S1-S4 必须**全部** >= 12
#       (device/noise-types.go: HeaderCipherNonceSize = 12)
#     * J1/J2/J3/Itime 是 v1.5 专属, v3 已移除, 下发直接 errno=-22
#   这些约束由 uapi.py 在下发前拦截, 本模块负责提供**档位**并把值写进 server.conf。
#
# 档位说明:
#   basic    —— 已与 mihomo v1.19.30 实测互通(RN + CC 全链路验证通过)
#   enhanced —— 更强的填充扰动; mihomo 侧字段齐全, 支持该语法, 但未做交叉验证
#   strict   —— 额外启用 HeaderProtection; S1-S4 全部 >= 12
# ==============================================================
set -uo pipefail

PARAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$PARAM_DIR/lib.sh"

sv() { grep -E "^$1\s*=" "$AWG_SERVER_CONF" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# HeaderProtectionKey 一旦下发就无法再用 UAPI 清除:
#   * ipcSetDevice 先用 fromDevice() 把设备当前值预填一遍, 所以**不写这行 = 保持原值**
#   * 写 64 个 0 会被 loadExactHex 拒掉 (errno=-22)
# 唯一可靠办法是重启服务(amneziawg-go 无状态, 重启即空设备, 再由 ExecStartPost 重新下发)。
_hp_active() {
    python3 "$AWG_UAPI_PY" get "$AWG_IFACE" 2>/dev/null | grep -q '^header_protection_key='
}

# 关闭 HeaderProtection 后把内核真正清干净
_ensure_hp_cleared() {
    _hp_active || return 0
    print_warn "UAPI 无法清除已下发的 HeaderProtectionKey (内核把'不写该行'当作保持原值), 需重启服务"
    yes_no "现在重启 amneziawg 服务? 会短暂断流" y || { print_warn "未重启, 内核仍在使用旧的 HeaderProtectionKey"; return 1; }
    systemctl restart "$AWG_UNIT" && sleep 2
    if _hp_active; then
        print_error "重启后 HeaderProtectionKey 仍存在, 请手动检查"
        return 1
    fi
    print_ok "已清除, 内核不再使用 HeaderProtectionKey"
    return 0
}

# 改完 server.conf 必须热加载, 否则运行中的内核还停在旧参数上:
# 面板显示新值、UAPI 读回旧值, 用户会以为面板在骗人。
_reload_if_running() {
    local u="${AWG_UNIT:-amneziawg}"
    if systemctl is-active --quiet "$u" 2>/dev/null; then
        print_info "热加载内核配置 ..."
        if bash "$PARAM_DIR/server.sh" reload >/dev/null 2>&1; then
            print_ok "内核已应用新参数"
        else
            print_error "热加载失败, 运行中的参数未改变"
            return 1
        fi
    else
        print_info "服务未运行, 参数将在下次启动时生效"
    fi
}

# ---------- 档位 ----------
apply_preset() {   # $1=basic|enhanced|strict|random
    local preset="$1"
    local jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4
    local hp=""
    case "$preset" in
        basic)
            jc=5; jmin=40; jmax=70
            s1=0; s2=15; s3=0; s4=0
            print_info "基础档: 已与 mihomo v1.19.30 实测互通"
            ;;
        enhanced)
            jc=8; jmin=50; jmax=1000
            s1=12; s2=18; s3=12; s4=18
            print_info "增强档: 填充更强, 兼容性未做交叉验证"
            ;;
        strict)
            # HeaderProtection 要求 S1-S4 全部 >= HeaderCipherNonceSize(12)
            jc=10; jmin=80; jmax=1200
            s1=12; s2=24; s3=12; s4=24
            hp=$(head -c 32 /dev/urandom | base64 -w0)
            print_info "严格档: 启用 HeaderProtectionKey (要求 S1-S4 全部 >= $AWG_HEADER_NONCE_MIN)"
            ;;
        random)
            jc=5; jmin=40; jmax=70
            s1=0; s2=15; s3=0; s4=0
            local hs; read -r h1 h2 h3 h4 < <(random_h_set)
            print_info "随机档: 仅重新随机化 H1-H4, 保持与客户端已验证的基线一致"
            ;;
        *)
            print_error "未知档位: $preset (可选 basic/enhanced/strict/random)"; return 1 ;;
    esac

    [[ -z "${h1:-}" ]] && read -r h1 h2 h3 h4 < <(random_h_set)

    local k v
    for kv in "Jc:$jc" "Jmin:$jmin" "Jmax:$jmax" "S1:$s1" "S2:$s2" "S3:$s3" "S4:$s4" \
              "H1:$h1" "H2:$h2" "H3:$h3" "H4:$h4"; do
        k="${kv%%:*}"; v="${kv#*:}"
        conf_set "$k" "$v"
    done

    if [[ -n "$hp" ]]; then
        conf_set "HeaderProtectionKey" "$hp"
    elif [[ "$preset" == "basic" || "$preset" == "enhanced" ]]; then
        conf_del "HeaderProtectionKey"
    fi

    # 落盘前统一校验
    if ! validate_awg "$AWG_SERVER_CONF" >/dev/null; then
        print_error "档位 $preset 校验未通过, 已回滚"
        return 1
    fi
    print_ok "已写入档位: $preset"
    _reload_if_running || return 1
    _ensure_hp_cleared || true
    params_show
    return 0
}

# ---------- 高级参数 ----------
advanced_menu() {
    while true; do
        print_title "AWG v3 高级参数"
        params_show_advanced
        echo
        echo -e "${CYAN}1)${RESET} RandomTrailers   (v3.1+ 随机填充包尾)"
        echo -e "${CYAN}2)${RESET} DisableCookies   (v3.1+ 禁用 Cookie 降级)"
        echo -e "${CYAN}3)${RESET} ContentPaddingAddition  (单值或 区间)"
        echo -e "${CYAN}4)${RESET} HeaderProtectionKey     (开启需 S1-S4 全部 >= $AWG_HEADER_NONCE_MIN)"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " c || return 0
        case "$c" in
            1) toggle_bool RandomTrailers ;;
            2) toggle_bool DisableCookies ;;
            3) set_cpa ;;
            4) set_hpk ;;
            0) return ;;
            *) echo -e "${RED}无效选项 $c${RESET}" ;;
        esac
        read -r -p "按回车继续..." _ || return 0
    done
}

toggle_bool() {   # $1=Key
    local k="$1" cur
    cur=$(sv "$k")
    if [[ "$cur" == "true" ]]; then
        conf_del "$k"; print_ok "$k 已关闭 (已删除该行)"
    else
        conf_set "$k" "true"; print_ok "$k 已开启"
    fi
    validate_awg "$AWG_SERVER_CONF" >/dev/null || print_warn "当前参数组合未通过校验, 请检查"
    _reload_if_running
}

set_cpa() {
    local v; v=$(safe_read "ContentPaddingAddition (留空=关闭, 支持 100 或 100-200)" "$(sv ContentPaddingAddition)")
    [[ -z "$v" ]] && { conf_del ContentPaddingAddition; print_ok "已关闭"; return; }
    conf_set ContentPaddingAddition "$v"
    if validate_awg "$AWG_SERVER_CONF" >/dev/null; then print_ok "已写入"; _reload_if_running; else print_error "校验失败"; fi
}

set_hpk() {
    local cur; cur=$(sv HeaderProtectionKey)
    if [[ -n "$cur" ]]; then
        yes_no "已启用, 确认关闭?" n || return
        conf_del HeaderProtectionKey
        print_ok "HeaderProtectionKey 已从配置移除"
        _reload_if_running
        _ensure_hp_cleared
        return
    fi
    print_warn "启用后 S1-S4 必须全部 >= $AWG_HEADER_NONCE_MIN, 否则内核返回 errno=-22 且不提示原因"
    yes_no "确认启用" y || return
    conf_set HeaderProtectionKey "$(head -c 32 /dev/urandom | base64 -w0)"
    if validate_awg "$AWG_SERVER_CONF" >/dev/null; then
        print_ok "HeaderProtectionKey 已启用"
        _reload_if_running
    else
        print_error "校验未通过 (S1-S4 有小于 $AWG_HEADER_NONCE_MIN 的值), 请先调整"
    fi
}

params_show_advanced() {
    printf "  %-26s %s\n" "RandomTrailers"          "$(sv RandomTrailers || echo 'false (默认)')"
    printf "  %-26s %s\n" "DisableCookies"          "$(sv DisableCookies || echo 'false (默认)')"
    printf "  %-26s %s\n" "ContentPaddingAddition"  "$(sv ContentPaddingAddition || echo '未设置')"
    local hp; hp=$(sv HeaderProtectionKey)
    if [[ -n "$hp" ]]; then
        printf "  %-26s %s\n" "HeaderProtectionKey" "已启用 (${#hp} 字符, 首 8: ${hp:0:8}...)"
    else
        printf "  %-26s %s\n" "HeaderProtectionKey" "未设置"
    fi
}

# printf 的 %-Ns 是按**字节**算宽度的, 中文字段名会让列错位,
# 而且参数个数一旦超过格式槽位数就会换行继续打, 所以统一走 _row4。
# 所以这里统一用纯 ASCII 键名 + 四列固定布局。
_row4() { printf "  %-5s %-7s  %-5s %-7s  %-5s %-7s  %-5s %s\n" "$@"; }

params_show() {
    print_title "当前 AWG 混淆参数"
    # 参数个数必须与格式槽位严格一致, 否则多出来的会换行继续打印
    _row4 "Jc" "$(sv Jc)" "Jmin" "$(sv Jmin)" "Jmax" "$(sv Jmax)" "MTU" "$(sv MTU)"
    _row4 "S1" "$(sv S1)" "S2" "$(sv S2)" "S3" "$(sv S3)" "S4" "$(sv S4)"
    _row4 "H1" "$(sv H1)" "H2" "$(sv H2)" "H3" "$(sv H3)" "H4" "$(sv H4)"
    echo
    params_show_advanced
    echo
    local peers; peers=$(grep -c '^\[Peer' "$AWG_SERVER_CONF" 2>/dev/null || echo 0)
    if ((peers > 0)); then
        print_warn "当前有 $peers 个节点, 改参数后必须执行 node.sh regen 让客户端配置同步"
    fi
}

case "${1:-menu}" in
    show) params_show ;;
    basic|enhanced|strict|random) apply_preset "$1" ;;
    advanced) advanced_menu ;;
    menu)
        print_title "AWG 混淆参数"
        params_show
        echo
        echo -e "${CYAN}1)${RESET} 基础档 basic    (已实测与 mihomo 互通)"
        echo -e "${CYAN}2)${RESET} 增强档 enhanced (填充更强)"
        echo -e "${CYAN}3)${RESET} 严格档 strict   (启用 HeaderProtection)"
        echo -e "${CYAN}4)${RESET} 随机档 random   (只重随机 H1-H4)"
        echo -e "${CYAN}5)${RESET} 高级参数"
        echo -e "${CYAN}0)${RESET} 返回"
        read -r -p "请选择: " c || exit 0
        case "$c" in
            1) apply_preset basic ;;
            2) apply_preset enhanced ;;
            3) apply_preset strict ;;
            4) apply_preset random ;;
            5) advanced_menu ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项 $c${RESET}" ;;
        esac
        ;;
    *) echo "用法: $0 {menu|show|basic|enhanced|strict|random|advanced}"; exit 2 ;;
esac