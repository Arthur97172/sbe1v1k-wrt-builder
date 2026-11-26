#!/usr/bin/env bash
# SBE1V1K 恢复模式刷机脚本（Linux）
#
# 全程只与本机直连的路由器交换 DHCP / TFTP / SSH 流量，不访问互联网。
# 用户只需要：确认有线网卡、确认要刷的固件；其余地址配置与流程自动化。
#
#   sudo ./flash-sbe1v1k.sh
#
# 可选参数见 --help。

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$SCRIPT_DIR/bin/sbe-flash-tool_linux_amd64"
ASSETS="$SCRIPT_DIR/assets"

RECOVERY_HOST_IP="172.16.252.252"
RECOVERY_PREFIX=16
DEVICE_IP="192.168.1.1"
LAN_HOST_IP="192.168.1.2"
LAN_PREFIX=24

FIRMWARE_DIRS="24.10-6.6 25.12-6.12 25.12-6.18"

DRY_RUN=0
OPT_IFACE=""
OPT_IFACE2=""
OPT_FIRMWARE=""

# ---------------------------------------------------------------- 输出与交互

if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_CYN=$'\033[36m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_BLD=""; C_RST=""
fi

info()  { printf '%s[信息]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()    { printf '%s[完成]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[注意]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
err()   { printf '%s[错误]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
step()  { printf '\n%s==> %s%s\n' "$C_BLD" "$*" "$C_RST"; }

die() {
    err "$*"
    exit 2
}

tty_read() {
    # 优先从终端读，避免脚本被管道调用时读不到输入
    local __var="$1" __prompt="$2"
    if { : < /dev/tty; } 2>/dev/null; then
        read -r -p "$__prompt" "$__var" < /dev/tty || true
    else
        read -r -p "$__prompt" "$__var" || true
    fi
}

ask_yes() {
    # ask_yes "问题" -> 只有输入 y/yes 才返回 0
    local ans=""
    tty_read ans "$1 [y/N]: "
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<EOF
SBE1V1K 恢复模式刷机脚本（Linux）

用法:
  sudo $0 [选项]

选项:
  --iface <网卡>        直接指定刷机用的有线网卡（跳过选择菜单）
  --second-iface <网卡> 第二条网卡。用它连路由器的 10G/LAN 口，
                        刷写后自动从这里继续，不需要手工换线
  --firmware <路径>     直接指定 sysupgrade 固件（跳过固件选择）
  --dry-run             只打印将要执行的步骤，不修改网络、不启动工具
  -h, --help            显示本帮助

流程:
  1. 核对 assets / bin 的 sha256
  2. 选择有线网卡
  3. 选择固件（放在 24.10-6.6 / 25.12-6.12 / 25.12-6.18 文件夹里）
  4. 本机临时配置 $RECOVERY_HOST_IP/$RECOVERY_PREFIX，提供 DHCP+TFTP
     路由器：断电 → 按住 Reset → 上电 → 约 12 秒后松手
  5. 等待恢复系统上线，上传固件并做双端 sha256 校验
  6. 确认后执行 sysupgrade -F -n（不保留配置）
  7. 等待新固件启动并核对指纹
  8. 恢复本机网络配置

退出后如需保留本机地址（排查用）: KEEP_NET=1 sudo $0
EOF
}

# ---------------------------------------------------------------- 参数

while [ $# -gt 0 ]; do
    case "$1" in
        --iface)        OPT_IFACE="${2:-}"; shift 2 || die "--iface 缺少参数" ;;
        --second-iface) OPT_IFACE2="${2:-}"; shift 2 || die "--second-iface 缺少参数" ;;
        --firmware)     OPT_FIRMWARE="${2:-}"; shift 2 || die "--firmware 缺少参数" ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "未知参数：$1" ;;
    esac
done

# ---------------------------------------------------------------- 权限

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        info "需要管理员权限来配置网络、监听 67/69 端口，正在提权…"
        exec sudo -- "$0" "$@"
    fi
    die "请用 root 运行（或用 sudo）"
fi

# ---------------------------------------------------------------- 环境检查

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

step "环境检查"

[ "$(uname -s)" = "Linux" ] || die "这个脚本只用于 Linux；Windows 请用 flash-sbe1v1k.cmd"

for c in ip sha256sum; do need_cmd "$c"; done

[ -x "$TOOL" ] || die "缺少工具二进制：$TOOL（见 bin/SHA256SUMS 与 src/build.sh）"
[ -f "$ASSETS/initramfs.itb" ] || die "缺少 $ASSETS/initramfs.itb"
[ -f "$ASSETS/rtq7300t_boot_auto_upgrade_fw.img" ] || die "缺少启动器 $ASSETS/rtq7300t_boot_auto_upgrade_fw.img"

if [ -f "$ASSETS/SHA256SUMS" ]; then
    ( cd "$ASSETS" && sha256sum -c --status SHA256SUMS ) \
        || die "assets 校验失败，文件可能损坏，请重新下载整个 openwrt-flash 目录"
    ok "assets 校验通过"
else
    warn "缺少 $ASSETS/SHA256SUMS，跳过素材校验"
fi

if [ -f "$SCRIPT_DIR/bin/SHA256SUMS" ]; then
    ( cd "$SCRIPT_DIR/bin" && sha256sum -c --status SHA256SUMS ) \
        || die "辅助工具校验失败，请重新下载整个 openwrt-flash 目录"
    ok "辅助工具校验通过"
fi

info "工具版本：$("$TOOL" version 2>/dev/null || echo 未知)"

# ---------------------------------------------------------------- 网卡枚举

iface_carrier() {
    local c
    c=$(cat "/sys/class/net/$1/carrier" 2>/dev/null) && [ "$c" = "1" ]
}

iface_speed() {
    local s
    s=$(cat "/sys/class/net/$1/speed" 2>/dev/null)
    if [ -n "${s:-}" ] && [ "$s" -gt 0 ] 2>/dev/null; then
        if [ "$s" -ge 1000 ]; then
            awk -v s="$s" 'BEGIN { printf "%gG\n", s / 1000 }'
        else
            echo "${s}M"
        fi
    else
        echo "-"
    fi
}

iface_mac() {
    cat "/sys/class/net/$1/address" 2>/dev/null || echo "-"
}

# 物理网卡：设备节点存在，排除 lo / 桥 / 虚拟 / 容器
list_physical_ifaces() {
    local n
    for n in /sys/class/net/*; do
        n=$(basename "$n")
        [ "$n" = "lo" ] && continue
        [ -e "/sys/class/net/$n/device" ] || continue
        # 无线网卡不能用来刷机
        [ -e "/sys/class/net/$n/wireless" ] || [ -e "/sys/class/net/$n/phy80211" ] && continue
        case "$n" in
            docker*|veth*|virbr*|br-*|tun*|tap*|wg*|zt*) continue ;;
        esac
        echo "$n"
    done
}

print_iface_row() {
    local idx="$1" name="$2"
    local state speed mac link
    state=$(cat "/sys/class/net/$name/operstate" 2>/dev/null || echo unknown)
    speed=$(iface_speed "$name")
    mac=$(iface_mac "$name")
    if iface_carrier "$name"; then link="${C_GRN}已连接${C_RST}"; else link="${C_YEL}未连接${C_RST}"; fi
    printf '  %2d) %-14s %-9s %-6s %s  %s\n' "$idx" "$name" "$state" "$speed" "$mac" "$link"
}

pick_iface() {
    local purpose="$1" opt="$2"
    local -a cands=()
    local n

    # 如果参数给了网卡名，先验证
    if [ -n "$opt" ]; then
        [ -e "/sys/class/net/$opt" ] || die "网卡 $opt 不存在"
        echo "$opt"
        return 0
    fi

    while IFS= read -r n; do
        [ -n "$n" ] && cands+=("$n")
    done < <(list_physical_ifaces)

    if [ ${#cands[@]} -eq 0 ]; then
        die "没有找到可用的物理网卡（请确认 USB 网卡已插好）"
    fi

    # 恰好一张已连接时作为默认
    local -a up=()
    for n in "${cands[@]}"; do iface_carrier "$n" && up+=("$n"); done

    echo "" >&2
    printf '%s可用的物理网卡（%s用）：%s\n' "$C_BLD" "$purpose" "$C_RST" >&2
    local i=0
    for n in "${cands[@]}"; do
        i=$((i + 1))
        print_iface_row "$i" "$n" >&2
    done
    echo "" >&2

    local default_idx=0
    if [ ${#up[@]} -eq 1 ]; then
        i=0
        for n in "${cands[@]}"; do
            i=$((i + 1))
            [ "$n" = "${up[0]}" ] && default_idx=$i
        done
        info "只有一张网卡已连接（${up[0]}），默认使用它" >&2
    fi

    local ans="" idx=
    if [ "$default_idx" -ne 0 ]; then
        tty_read ans "选择网卡序号 [回车=${default_idx}]: "
        [ -z "$ans" ] && ans="$default_idx"
    else
        tty_read ans "选择网卡序号: "
    fi

    case "$ans" in
        ''|*[!0-9]*) die "无效的序号：$ans" ;;
    esac
    idx="$ans"
    [ "$idx" -ge 1 ] && [ "$idx" -le ${#cands[@]} ] || die "序号超出范围：$idx"

    echo "${cands[$((idx - 1))]}"
}

# ---------------------------------------------------------------- 固件选择

find_firmwares() {
    local base dir f
    for base in "$SCRIPT_DIR" "$SCRIPT_DIR/.." "$PWD"; do
        [ -d "$base" ] || continue
        for dir in $FIRMWARE_DIRS; do
            [ -d "$base/$dir" ] || continue
            for f in "$base/$dir"/*.bin; do
                [ -f "$f" ] || continue
                printf '%s\n' "$f"
            done
        done
    done | awk '!seen[$0]++'
}

pick_firmware() {
    local opt="$1"
    local -a cands=()
    local f

    if [ -n "$opt" ]; then
        [ -f "$opt" ] || die "固件不存在：$opt"
        printf '%s\n' "$opt"
        return 0
    fi

    while IFS= read -r f; do
        [ -n "$f" ] && cands+=("$f")
    done < <(find_firmwares)

    if [ ${#cands[@]} -eq 0 ]; then
        cat >&2 <<EOF
${C_RED}没有找到固件。${C_RST}

请把 sysupgrade 固件（.bin）放进下列任一文件夹（与脚本同目录或上一级）：
  $(echo $FIRMWARE_DIRS | sed "s/ /  /g")

例如：
  openwrt-flash/24.10-6.6/openwrt-...-sysupgrade.bin
EOF
        exit 2
    fi

    echo "" >&2
    printf '%s找到以下固件：%s\n' "$C_BLD" "$C_RST" >&2
    local i=0
    for f in "${cands[@]}"; do
        i=$((i + 1))
        printf '  %2d) %s\n      大小 %.1f MiB  sha256 %s…\n' \
            "$i" "${f#$SCRIPT_DIR/}" \
            "$(stat -c %s "$f" 2>/dev/null | awk '{print $1/1048576}')" \
            "$(sha256sum "$f" 2>/dev/null | cut -c1-16)" >&2
    done
    echo "" >&2

    local ans="" idx=
    if [ ${#cands[@]} -eq 1 ]; then
        tty_read ans "选择固件序号 [回车=1]: "
        [ -z "$ans" ] && ans="1"
    else
        tty_read ans "选择固件序号: "
    fi
    case "$ans" in
        ''|*[!0-9]*) die "无效的序号：$ans" ;;
    esac
    idx="$ans"
    [ "$idx" -ge 1 ] && [ "$idx" -le ${#cands[@]} ] || die "序号超出范围：$idx"

    printf '%s\n' "${cands[$((idx - 1))]}"
}

# ---------------------------------------------------------------- 网络配置

NM_IFACES_UNMANAGED=()
ADDED_ADDRS=()
ADDED_ROUTES=()

net_setup_addr() {
    local ifc="$1" addr="$2" prefix="$3"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[演练] ip link set $ifc up"
        info "[演练] ip addr add $addr/$prefix dev $ifc"
        return 0
    fi
    # 若上次中断留下同名地址，先清掉（只清我们自己用的地址）
    ip -4 addr show dev "$ifc" | grep -q "inet $addr/$prefix " && ip addr del "$addr/$prefix" dev "$ifc"
    ip link set "$ifc" up || die "启用网卡 $ifc 失败"
    ip addr add "$addr/$prefix" dev "$ifc" || die "给 $ifc 配置 $addr/$prefix 失败"
    ADDED_ADDRS+=("$addr/$prefix|$ifc")
}

net_remove_addrs() {
    local entry a i
    for entry in "${ADDED_ADDRS[@]:-}"; do
        [ -n "$entry" ] || continue
        a="${entry%%|*}"; i="${entry##*|}"
        ip addr del "$a" dev "$i" 2>/dev/null || true
    done
    ADDED_ADDRS=()
}

net_add_route() {
    local dst="$1" ifc="$2" src="$3"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[演练] ip route replace $dst/32 dev $ifc src $src"
        return 0
    fi
    ip route replace "$dst/32" dev "$ifc" src "$src" || die "添加 $dst 的 /32 路由失败"
    ADDED_ROUTES+=("$dst|$ifc")
}

net_remove_routes() {
    local entry d i
    for entry in "${ADDED_ROUTES[@]:-}"; do
        [ -n "$entry" ] || continue
        d="${entry%%|*}"; i="${entry##*|}"
        ip route del "$d/32" dev "$i" 2>/dev/null || true
    done
    ADDED_ROUTES=()
}

nm_has() {
    command -v nmcli >/dev/null 2>&1 || return 1
    systemctl is-active -q NetworkManager 2>/dev/null
}

nm_release() {
    local ifc="$1"
    [ "$DRY_RUN" -eq 1 ] && return 0
    nm_has || return 0
    local managed
    managed=$(nmcli -t -f GENERAL.STATE device show "$ifc" 2>/dev/null || true)
    case "$managed" in
        *unmanaged*) return 0 ;;
    esac
    nmcli device set "$ifc" managed no 2>/dev/null && NM_IFACES_UNMANAGED+=("$ifc")
}

nm_restore() {
    local ifc
    for ifc in "${NM_IFACES_UNMANAGED[@]:-}"; do
        [ -n "$ifc" ] || continue
        nmcli device set "$ifc" managed yes 2>/dev/null || true
        nmcli device connect "$ifc" >/dev/null 2>&1 || true
    done
    NM_IFACES_UNMANAGED=()
}

cleanup() {
    local rc=$?
    if [ "$DRY_RUN" -eq 0 ]; then
        if [ ${#ADDED_ADDRS[@]} -gt 0 ] || [ ${#ADDED_ROUTES[@]} -gt 0 ] \
                || [ ${#NM_IFACES_UNMANAGED[@]} -gt 0 ]; then
            printf '\n'
            info "清理本机临时网络配置…"
            net_remove_routes
            net_remove_addrs
            nm_restore
            if [ "${KEEP_NET:-0}" = "1" ]; then
                warn "KEEP_NET=1：本机地址保留未清理"
            fi
        fi
    fi
    exit "$rc"
}

trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- 主流程

banner() {
    cat <<EOF

${C_BLD}========================================================${C_RST}
  SBE1V1K 恢复模式刷机工具（Linux）
  离线运行：只与本机直连的路由器通信
${C_BLD}========================================================${C_RST}

将要做的事：
  1. 本机临时地址 $RECOVERY_HOST_IP/$RECOVERY_PREFIX，提供 DHCP + TFTP
  2. 引导路由器进入恢复模式（RAM 系统，不写 eMMC）
  3. 通过 SSH 上传你选的固件并核对 sha256
  4. 执行 sysupgrade -F -n（${C_YEL}不保留旧配置${C_RST}）

${C_YEL}请先确认：${C_RST}
  - 路由器的 2.5G LAN1 口用网线直连本机所选网卡
  - 本机没有其他网卡占用 $RECOVERY_HOST_IP/$RECOVERY_PREFIX 或 192.168.1.x 网段
  - 刷写期间不要断电

EOF
    if [ "$DRY_RUN" -eq 1 ]; then
        warn "演练模式：不会修改网络，也不会启动刷机工具"
    elif ! ask_yes "确认继续？"; then
        info "已取消"
        exit 0
    fi
}

check_firmware_file() {
    local f="$1" size magic
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    if [ "$size" -lt $((8 * 1024 * 1024)) ]; then
        warn "固件只有 $((size / 1024 / 1024)) MiB，偏小，请确认选对了文件"
    fi
    magic=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')
    if [ "$magic" != "d00dfeed" ]; then
        warn "固件头部不是 FIT 格式（实际：${magic:-读取失败}），可能不是 SBE1V1K 的 sysupgrade 镜像"
        ask_yes "仍要继续？" || exit 0
    fi
    if [ -f "$f.sha256" ]; then
        info "发现随附的 $f.sha256，正在核对…"
        local want got
        want=$(awk '{print $1}' "$f.sha256" | head -n1)
        got=$(sha256sum "$f" | awk '{print $1}')
        if [ "$want" = "$got" ]; then
            ok "固件 sha256 与随附文件一致"
        else
            die "固件 sha256 与随附文件不一致！请重新拷贝固件"
        fi
    fi
}

main() {
    banner

    step "选择刷机网卡（连路由器 2.5G LAN1 口的那张）"
    local IFACE
    IFACE=$(pick_iface "刷机网卡" "$OPT_IFACE") || exit 2
    [ -e "/sys/class/net/$IFACE" ] || die "网卡 $IFACE 不存在"
    ok "刷机网卡：$IFACE（$(iface_mac "$IFACE")）"
    if ! iface_carrier "$IFACE"; then
        warn "这张网卡当前没有检测到连接（网线没插或对端没上电）"
        ask_yes "仍然继续？" || exit 0
    fi

    local IFACE2=""
    if [ -n "$OPT_IFACE2" ]; then
        [ -e "/sys/class/net/$OPT_IFACE2" ] || die "网卡 $OPT_IFACE2 不存在"
        IFACE2="$OPT_IFACE2"
        ok "刷写后继续使用的网卡：$IFACE2"
        if [ "$IFACE" = "$IFACE2" ]; then
            die "--second-iface 不能与 --iface 相同"
        fi
        info "请把第二根网线连到路由器的 10G 口或 1G LAN 口，刷写后从这里继续"
    fi

    step "选择固件"
    local FW
    FW=$(pick_firmware "$OPT_FIRMWARE") || exit 2
    ok "固件：$FW"
    printf '  sha256 %s\n' "$(sha256sum "$FW" | awk '{print $1}')"
    check_firmware_file "$FW"
    if [ "$DRY_RUN" -eq 0 ] && ! ask_yes "使用这个固件刷写？"; then
        info "已取消"
        exit 0
    fi

    # ---------------- 阶段 A：恢复模式
    step "阶段 A：进入恢复模式"
    nm_release "$IFACE"
    net_setup_addr "$IFACE" "$RECOVERY_HOST_IP" "$RECOVERY_PREFIX"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[演练] $TOOL serve --iface $IFACE --ip $RECOVERY_HOST_IP --root $ASSETS --expect initramfs.itb --timeout 900s"
    else
        printf '\n%s──────────────── 请按下面操作 ────────────────%s\n' "$C_BLD" "$C_RST"
        printf '  1. 把路由器%s断电%s（拔电源）\n' "$C_YEL" "$C_RST"
        printf '  2. %s按住 Reset 键不放%s\n' "$C_BLD" "$C_RST"
        printf '  3. 插上电源，继续保持按住\n'
        printf '  4. 大约 %s12 秒%s 后松开 Reset\n' "$C_BLD" "$C_RST"
        printf '%s──────────────────────────────────────────────%s\n\n' "$C_BLD" "$C_RST"

        "$TOOL" serve --iface "$IFACE" --ip "$RECOVERY_HOST_IP" \
            --root "$ASSETS" --expect initramfs.itb --timeout 900s
        serve_rc=$?
        case "$serve_rc" in
            0) ok "恢复系统已通过 TFTP 载入，正在启动" ;;
            4) die "15 分钟内没有等到路由器请求启动文件。请确认：网线插在 2.5G LAN1 口；Reset 按住够 12 秒；然后重新运行本脚本" ;;
            130) info "已取消"; exit 0 ;;
            *) die "DHCP/TFTP 服务异常退出（$serve_rc）" ;;
        esac
    fi

    # ---------------- 阶段 B：主机侧切到 192.168.1.x
    step "阶段 B：登录恢复系统"
    local B_IFACE="$IFACE"
    local local_ip="$LAN_HOST_IP"
    if [ -n "$IFACE2" ]; then
        B_IFACE="$IFACE2"
        nm_release "$B_IFACE"
    else
        # 恢复阶段用的 172.16 地址已经没用了，撤掉避免干扰后续判定
        if [ "$DRY_RUN" -eq 0 ]; then
            ip addr del "$RECOVERY_HOST_IP/$RECOVERY_PREFIX" dev "$IFACE" 2>/dev/null || true
        fi
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        net_setup_addr "$B_IFACE" "$local_ip" "$LAN_PREFIX"
        net_add_route "$DEVICE_IP" "$B_IFACE" "$local_ip"
    else
        info "[演练] 在 ${B_IFACE} 上配置 $local_ip/$LAN_PREFIX 并加 $DEVICE_IP/32 路由"
    fi
    info "等待恢复系统 SSH 就绪（约 5–30 秒）…"
    local pre_rev=""
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[演练] $TOOL wait --local $local_ip --timeout 300s"
    else
        "$TOOL" wait --local "$local_ip" --timeout 300s || die "恢复系统没有在预期时间内上线"
        check_out=$("$TOOL" check --expect ram) || {
            rc=$?
            printf '%s\n' "$check_out"
            [ "$rc" -eq 3 ] && die "设备指纹不符，为安全起见停止。请确认刷的是 SBE1V1K"
            die "读取设备信息失败"
        }
        printf '%s\n' "$check_out"
        pre_rev=$(printf '%s\n' "$check_out" | sed -n 's/^  REV=//p' | head -n1)
    fi

    # ---------------- 上传与刷写
    step "上传固件"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[演练] $TOOL push --local $local_ip --src $FW"
        info "[演练] $TOOL sysupgrade --local $local_ip"
    else
        "$TOOL" push --local "$local_ip" --src "$FW" || die "上传或校验失败，未做任何写入"

        printf '\n'
        warn "下一步将执行 sysupgrade，写入 eMMC 并重启路由器"
        warn "使用 -n：${C_BLD}设备上的旧配置会全部丢失${C_RST}（Wi-Fi、密码、插件设置）"
        if ! ask_yes "确认开始刷写？"; then
            info "已取消（设备仍处于恢复模式，断电重启即可恢复原固件）"
            exit 0
        fi

        step "刷写中"
        "$TOOL" sysupgrade --local "$local_ip" || die "sysupgrade 启动失败（设备可能未重启）"

        step "等待新固件启动"
        if [ -n "$IFACE2" ]; then
            info "等待 10G/LAN 口（$IFACE2）上的新系统…"
        else
            printf '\n%s════════════ 现在请换线 ════════════%s\n' "$C_BLD" "$C_RST"
            printf '  路由器 2.5G 口刷机后变成 WAN 口，不再有 %s。\n' "$DEVICE_IP"
            printf '  请把网线从 %s2.5G LAN1%s 移到路由器上的 %s10G 口或 1G LAN 口%s，\n' "$C_YEL" "$C_RST" "$C_BLD" "$C_RST"
            printf '  保持插在本机网卡 %s 上。\n' "$IFACE"
            printf '%s════════════════════════════════════%s\n\n' "$C_BLD" "$C_RST"
            ask_yes "已经换好线了吗？（确认后继续等待）" || info "继续等待…"
        fi

        local ans=""
        while ! "$TOOL" wait --local "$local_ip" --timeout 420s; do
            warn "4 分钟内没有连上新系统"
            info "如果还没换线，请换好线后按回车重试；输入 q 结束（设备已经刷写了，稍后可以自己访问 $DEVICE_IP）"
            tty_read ans "回车重试 / q 结束: " || ans="q"
            [ "$ans" = "q" ] && die "已放弃等待（固件可能已经刷写成功，可手动访问 $DEVICE_IP 检查）"
        done

        check_out=$("$TOOL" check --expect firmware) || {
            rc=$?
            printf '%s\n' "$check_out"
            if [ "$rc" -eq 3 ]; then
                err "设备能登录，但指纹显示不是从 eMMC 启动的新固件"
                info "可能进入了原厂系统。请记录以上信息并回报"
                exit 3
            fi
            die "核对新固件失败"
        }
        printf '%s\n' "$check_out"
        post_rev=$(printf '%s\n' "$check_out" | sed -n 's/^  REV=//p' | head -n1)
        if [ -n "$pre_rev" ] && [ "$pre_rev" = "$post_rev" ]; then
            warn "版本指纹与刷写前的恢复系统完全相同（$post_rev），可能没有真正写入新固件"
            warn "历史上出现过 sysupgrade 静默不生效的情况，请核对版本后再使用"
        fi
        ok "刷写完成：新固件已从 eMMC 启动"
    fi

    # ---------------- 收尾
    step "收尾"
    if [ "$DRY_RUN" -eq 0 ]; then
        net_remove_routes
        net_remove_addrs
        nm_restore
        printf '\n'
        ok "全部完成"
        info "本机网络配置已恢复"
        info "设备地址：${C_BLD}http://$DEVICE_IP${C_RST}（root 无密码，未保留旧配置）"
        info "如果设备改了 LAN 网段或密码，请按新配置访问"
    else
        ok "演练结束：以上为将要执行的步骤"
    fi
}

main
