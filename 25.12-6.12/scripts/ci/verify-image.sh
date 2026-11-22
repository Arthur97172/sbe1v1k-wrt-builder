#!/usr/bin/env bash
# 25.12-6.12 编译后的静态检查（不接触设备、不执行目标二进制）。
#
# 检查对象是最终交付物本身：本目标的 sysupgrade 镜像是 tar 容器
#   sysupgrade-spectrum_sbe1v1k/{CONTROL,kernel,root}
# （upgrade 脚本里的 emmc_upgrade_tar 就按这个格式读），所以先把 root 段取
# 出来解成 squashfs 再核对，并确认 kernel 段就是发布的那个 FIT。
#
# 检查项：
#   1. 三个交付镜像齐全、非空，打印尺寸与 SHA-256；
#   2. /etc/banner 与渲染后 overlay 逐字节一致、无占位符、版本行是 25.12；
#   3. 无线默认值三件套哈希/权限一致，/etc/rc.d/S95wireless-defaults 存在；
#   4. LuCI 基础文件存在（与 24.10-6.6 镜像保持一致的选择）；
#   5. Stage 2.5：ath12k.ko 与 kmod-ath12k / wifi-scripts / wpad-mesh-mbedtls 存在；
#      厂商固件/BDF 落在 QCN9274/hw2.0 与 /usr/share/sbe-wifi/bdf41，
#      内容与 build/local-packages 逐字节一致，且 sbe-wifi-firmware 已安装。
#      （本机与 CI 用同一判据：2026-10-24 决定 CI 镜像也带 blob。）
#   6. apk/opkg 包数据库存在并打印包数量；
#   7. 设备树里 mmc@7804000（eMMC）为 okay，且该 DTB 逐字节存在于两个 FIT 中
#      （板子从 eMMC 启动，控制器关闭时真机无法启动）；QPIC NAND
#      （spi@79b0000）为 disabled（开着会抢走 eMMC 的引脚复用）；
#      设备树里 pwm@1941010 为 okay、pwm-fan 挂在通道 3 且有 cooling map，
#      镜像含 pwm-fan.ko；FIT 内核 load/entry 为 0x42200000（v21 用
#      0x41000000，落在 NSS 保留区里，真机不启动）；
#   8. sysupgrade 镜像的 tar 段齐全（CONTROL/kernel/root），kernel 段与发布的
#      FIT 逐字节一致；
#   9. 镜像里的升级脚本按当前槽位写 eMMC（写死槽位会让升级写进没人读的分区，
#      而 default_do_upgrade 在这块板上只会去写 mtd 分区 "image"）。
#
# 用法：scripts/ci/verify-image.sh [工作区根目录]

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)      # <repo>/25.12-6.12

if [ -n "${SBE_ROOT:-}" ]; then
	ROOT=$SBE_ROOT
else
	ROOT=${1:-}
	if [ -z "$ROOT" ]; then
		d=$PROJ
		while [ "$d" != / ]; do
			if [ -d "$d/sources/buildroot-25.12-6.12" ]; then ROOT=$d; break; fi
			d=$(dirname "$d")
		done
	fi
fi
[ -n "$ROOT" ] || { echo "找不到工作区根（含 sources/buildroot-25.12-6.12），可用 SBE_ROOT 指定" >&2; exit 1; }

BR=${SBE_BUILDROOT:-$ROOT/sources/buildroot-25.12-6.12}
OUT="$BR/bin/targets/qualcommbe/ipq95xx"
OVERLAY="$PROJ/files"
fail=0

say()  { printf '%s\n' "$*"; }
ok()   { printf 'PASS   %s\n' "$*"; }
bad()  { printf 'FAIL   %s\n' "$*"; fail=1; }

# 这一步失败时脚本在 set -e 下直接退出；若不显式打印，CI 日志里只剩
# "Process completed with exit code 1"，看不出是 overlay 渲染失败。
SBE_ROOT="$ROOT" SBE_BUILDROOT="$BR" "$PROJ/scripts/render-overlay.sh" \
	|| { bad "render-overlay.sh 失败：overlay 未渲染，后续逐字节比对全部不可信"; exit 1; }

IMG="$OUT/sbe1v1k-squashfs-sysupgrade.bin"
FIT="$OUT/sbe1v1k-fit-uImage.itb"
INITRAMFS="$OUT/sbe1v1k-initramfs-fit-uImage.itb"

for f in "$IMG" "$FIT" "$INITRAMFS"; do
	if [ -s "$f" ]; then
		ok "存在 $(basename "$f") ($(stat -c %s "$f") 字节)"
		sha256sum "$f"
	else
		bad "缺少或为空：$f"
	fi
done
[ -s "$IMG" ] || exit 1

TMPBASE=${SBE_TMPDIR:-/var/tmp}
TMP=$(mktemp -d "$TMPBASE/sbe-verify.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ---- 设备树：eMMC 控制器必须启用 --------------------------------------------
# 本机从 eMMC 启动：U-Boot 按 bootconfig 选槽后注入 root=PARTUUID=<uuid>，
# 内核必须先有 mmcblk0 才能挂根。ipq9574.dtsi 把 sdhc_1 设成 disabled，必须由
# 设备 DTS 显式启用；不启用时的表现是真机一抹黑（已复现“刷入后无法启动”）。
# 这里检查编进 FIT 的 DTB 本身：DTS 写对了却没编进去，同样算失败。
DTB=$(ls "$BR"/build_dir/target-*/linux-qualcommbe_ipq95xx/image-ipq9574-sbe1v1k.dtb \
         "$BR"/build_dir/target-*/linux-qualcommbe_ipq95xx/linux-*/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dtb \
         2>/dev/null | head -n1 || true)
if [ -n "$DTB" ] && [ -f "$DTB" ]; then
	ok "编译出的 DTB：${DTB#$BR/}"
	DTBDEC="$TMP/dtb.dts"
	if dtc -I dtb -O dts -o "$DTBDEC" "$DTB" 2>/dev/null; then
		NODE=$(awk '/mmc@7804000/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC")
		case "$NODE" in
		*'mmc@7804000 {'*)
			printf '%s\n' "$NODE" | grep -q 'status = "okay"' \
				&& ok "DTB 中 mmc@7804000（eMMC）status = okay" \
				|| bad "DTB 中 mmc@7804000 未启用：内核拿不到 mmcblk0，根文件系统无法挂载"
			# v29：SDCC 核心复位（0028）。sdhci_msm_gcc_reset() 的复位是可选
			# 的，DTB 里没有就静默跳过；上游 6.18 的 DTB 带这一条。
			printf '%s\n' "$NODE" | grep -q 'resets = <' \
				&& ok "DTB 的 mmc@7804000 带 SDCC 核心复位" \
				|| bad "DTB 的 mmc@7804000 没有 resets：核心复位被静默跳过（v29 要修的就是这条）" ;;
		*) bad "DTB 中找不到 mmc@7804000 节点" ;;
		esac
		# v33：RDP433 基线的 QPIC NAND 必须关掉（0029）。目标补丁 0104 在
		# ipq9574-rdp-common.dtsi 里启用它并把 gpio0-5 复用成 qspi，与 eMMC 的
		# sdc_default_state 是同一组焊球；开着时 eMMC 完全不枚举（v32 真机）。
		QPIC=$(awk '/spi@79b0000/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC")
		printf '%s\n' "$QPIC" | grep -q 'status = "disabled"' \
			&& ok "DTB 中 QPIC NAND（spi@79b0000）已关闭" \
			|| bad "DTB 中 QPIC NAND 未关闭：qspi 引脚复用会抢走 eMMC 的 sdc 引脚（v32 起不来的根因）"
		# overlay 的位置：厂商 GPT 里有 rootfs_data 分区，fstools 默认会去用它；
		# 本项目的模型是 overlay 建在 rootfs 分区尾部（升级时只需写 HLOS/rootfs
		# 两个分区）。靠 chosen/bootargs-append 传 fstools_ignore_partname=1，
		# 这个选项是 920-device_tree_cmdline.patch 提供的，缺了它 fstools 会改去
		# 挂 rootfs_data，升级与恢复的语义都跟着变。
		CHOSEN=$(awk '/^[[:space:]]*chosen \{/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC")
		printf '%s\n' "$CHOSEN" | grep -q 'fstools_ignore_partname=1' \
			&& ok "DTB 的 chosen/bootargs-append 带 fstools_ignore_partname=1" \
			|| bad "DTB 的 chosen 没有 fstools_ignore_partname=1（fstools 会改用 rootfs_data 分区）"
		# PWM 风扇（0025/0026）：控制器必须启用，pwm-fan 必须存在并挂上温控区。
		# 缺任何一条，风扇都会停在 probe 时的 MAX_PWM（满速）。
		PWMNODE=$(awk '/pwm@1941010/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC")
		printf '%s\n' "$PWMNODE" | grep -q 'status = "okay"' \
			&& ok "DTB 中 pwm@1941010 已启用" \
			|| bad "DTB 中 pwm@1941010 未启用：风扇没有 PWM 控制器"
		FANNODE=$(awk '/pwm-fan \{/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC")
		if printf '%s\n' "$FANNODE" | grep -Eq 'pwms = <0x[0-9a-f]+ +0x0?3 ' &&
		   printf '%s\n' "$FANNODE" | grep -q 'cooling-levels = <'; then
			ok "DTB 含 pwm-fan 节点（PWM 通道 3 + cooling-levels）"
		else
			bad "DTB 缺少 pwm-fan 节点，或没有挂在 PWM 通道 3 / cooling-levels"
		fi
		if grep -q 'map-fan-0' "$DTBDEC"; then
			ok "DTB 的 top-glue-thermal 有风扇 cooling map"
		else
			bad "DTB 没有风扇 cooling map：pwm-fan 不会降速"
		fi
		# 启动阻塞（0027）：v24 刷入后起不来。24.10 在同一颗芯片上的真机
		# 结论是三条硬条件——cpus 不能残留 operating-points-v2（否则
		# cpufreq-dt 注册、重写 A73 PLL，静默死在用户态之前）、sleep-clk
		# 不能带 clock-frequency、必须保留 nss@40000000。反编译编出的 DTB
		# 检查，防止源文件写对了却没进镜像。0027 在 patches/disabled/ 时
		# （v28 对照构建）断言方向相反：镜像必须是"三条都不做"的形态。
		if ls "$PROJ"/patches/0027-*.patch >/dev/null 2>&1; then
			if grep -q 'operating-points-v2 = <' "$DTBDEC"; then
				bad "DTB 的 CPU 仍带 operating-points-v2：cpufreq-dt 会注册并重写 A73 PLL，真机静默死亡"
			else
				ok "DTB 的 CPU 没有 operating-points-v2（cpufreq-dt 不会注册）"
			fi
			SLP=$(awk '/sleep-clk \{/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC")
			if printf '%s\n' "$SLP" | grep -q 'clock-frequency'; then
				bad "DTB 的 sleep-clk 带 clock-frequency（24.10：每个起不来的 DTB 都有它）"
			else
				ok "DTB 的 sleep-clk 没有 clock-frequency"
			fi
			NSSRM=$(awk '/nss@40000000 \{/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC")
			if printf '%s\n' "$NSSRM" | grep -q 'reg = <0x0*0 0x40000000 0x0*0 0x2000000>' &&
			   printf '%s\n' "$NSSRM" | grep -q 'no-map'; then
				ok "DTB 保留 nss@40000000（0x40000000..0x42000000，32 MiB，no-map）"
			else
				bad "DTB 没有 nss@40000000 保留区（内核会把 NSS 固件窗口当普通内存分配）"
			fi
		else
			if grep -q 'operating-points-v2 = <' "$DTBDEC"; then
				ok "对照构建：DTB 的 CPU 仍带 operating-points-v2（0027 未启用）"
			else
				bad "对照构建不一致：DTB 的 CPU 没有 operating-points-v2，镜像不是去掉 0027 的形态"
			fi
			SLP=$(awk '/sleep-clk \{/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC")
			if printf '%s\n' "$SLP" | grep -q 'clock-frequency'; then
				ok "对照构建：DTB 的 sleep-clk 仍带 clock-frequency（0027 未启用）"
			else
				bad "对照构建不一致：DTB 的 sleep-clk 没有 clock-frequency，镜像不是去掉 0027 的形态"
			fi
			NSSRM=$(awk '/nss@40000000 \{/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC")
			if printf '%s\n' "$NSSRM" | grep -q 'reg = <0x0*0 0x40000000 0x0*0 0x2000000>'; then
				bad "对照构建不一致：DTB 仍有 nss@40000000 保留区，镜像不是去掉 0027 的形态"
			else
				ok "对照构建：DTB 没有 nss@40000000 保留区（0027 未启用）"
			fi
		fi
	else
		bad "无法反编译 DTB：$DTB"
	fi
	# 交付的两个 FIT 都必须真的含这个 DTB（kernel 为 gzip、fdt 为 none，
	# 所以可以直接按字节子串判断，不需要解析 FIT 结构）。
	for f in "$FIT" "$INITRAMFS"; do
		[ -s "$f" ] || continue
		if python3 -c 'import sys
a = open(sys.argv[1], "rb").read(); b = open(sys.argv[2], "rb").read()
sys.exit(0 if b in a else 1)' "$f" "$DTB"; then
			ok "$(basename "$f") 内含这个 DTB"
		else
			bad "$(basename "$f") 里找不到编出的 DTB（FIT 与 DTB 不同源）"
		fi
	done
else
	bad "找不到编译出的 DTB（build_dir/target-*/linux-qualcommbe_ipq95xx/{image-*,linux-*/arch/arm64/boot/dts/qcom/}ipq9574-sbe1v1k.dtb）"
fi

# ---- FIT 装载地址（0024）-----------------------------------------------------
# v21 的 FIT 把内核装到 0x41000000，落在厂商给 NSS 固件保留的
# 0x40000000..0x42000000 里，真机不启动。生成 FIT 用的 .its 是明文，
# 直接读它比逆 FIT 结构简单；本板两个设备都必须落在 0x42200000。
ITS=$(ls "$BR"/build_dir/target-*/linux-qualcommbe_ipq95xx/*sbe1v1k-fit-uImage.itb.its \
        2>/dev/null | head -n1 || true)
if [ -n "$ITS" ]; then
	if grep -q 'load = <0x42200000>' "$ITS" &&
	   grep -q 'entry = <0x42200000>' "$ITS"; then
		ok "FIT 内核 load/entry = 0x42200000（不落在 NSS 保留区）"
	else
		bad "FIT 装载地址不是 0x42200000（0x41000000 落在 NSS 保留区，真机起不来）"
	fi
else
	bad "找不到 FIT 的 .its（无法校验装载地址）"
fi

# ---- 从最终镜像里解出 squashfs 根文件系统 ----------------------------------
# 镜像格式：tar 容器，目录名是 sysupgrade-<BOARD_NAME>。emmc_upgrade_tar 用
# 同样的方式读它；这里也按 tar 读，才能断言“写进设备的就是校验过的这些字节”。

UNSQ="$BR/staging_dir/host/bin/unsquashfs4"
[ -x "$UNSQ" ] || UNSQ=$(command -v unsquashfs || true)
[ -n "$UNSQ" ] && [ -x "$UNSQ" ] || { bad "缺少 unsquashfs4"; exit 1; }

say "[verify] 从 sysupgrade 镜像（tar）提取 root 段"
BOARDDIR=$(tar tf "$IMG" 2>/dev/null | grep -m1 '^sysupgrade-.*/$' | sed 's:/$::' || true)
[ -n "$BOARDDIR" ] || { bad "sysupgrade 镜像里没有 sysupgrade-<board>/ 目录（不是 tar 容器）"; exit 1; }
say "[verify] tar 目录 ${BOARDDIR}"
for seg in CONTROL kernel root; do
	if tar tf "$IMG" | grep -qx "${BOARDDIR}/${seg}"; then
		ok "tar 含 ${BOARDDIR}/${seg}"
	else
		bad "tar 缺少 ${BOARDDIR}/${seg}"
	fi
done
tar xf "$IMG" -C "$TMP" "${BOARDDIR}/root" \
	|| { bad "无法从 tar 取出 ${BOARDDIR}/root"; exit 1; }
if [ -s "$FIT" ]; then
	if tar xOf "$IMG" "${BOARDDIR}/kernel" | cmp -s - "$FIT"; then
		ok "kernel 段与 $(basename "$FIT") 逐字节一致"
	else
		bad "kernel 段与 $(basename "$FIT") 不一致：发布的内核不是升级会写入的那个"
	fi
fi

set +e
"$UNSQ" -no-progress -d "$TMP/rootfs" "$TMP/${BOARDDIR}/root" >"$TMP/unsquashfs.log" 2>&1
rc=$?
set -e
case "$rc" in
	0) ok "squashfs 解包完成" ;;
	2) ok "squashfs 解包完成（rc=2：设备节点权限，非 root 预期）" ;;
	*) bad "squashfs 解包失败 rc=$rc"; sed -n '1,20p' "$TMP/unsquashfs.log"; exit 1 ;;
esac

ROOTFS="$TMP/rootfs"
[ -d "$ROOTFS/etc" ] || { bad "解包结果缺少 /etc"; exit 1; }

# ---- overlay 文件 -----------------------------------------------------------
check_overlay() {
	local rel=$1 src="$BR/files/$1"
	if [ ! -f "$OVERLAY/$1" ]; then bad "overlay 缺少 $rel"; return; fi
	if [ ! -f "$src" ]; then bad "渲染后的 overlay 缺少 $rel"; return; fi
	if [ ! -f "$ROOTFS/$rel" ]; then bad "镜像缺少 /$rel"; return; fi
	local a b
	a=$(sha256sum "$src" | cut -d' ' -f1)
	b=$(sha256sum "$ROOTFS/$rel" | cut -d' ' -f1)
	if [ "$a" = "$b" ]; then ok "/$rel 与渲染后 overlay 一致 ($a)"; else bad "/$rel 哈希不一致"; fi
	local ma mb
	ma=$(stat -c %a "$src")
	mb=$(stat -c %a "$ROOTFS/$rel")
	if [ "$ma" = "$mb" ]; then ok "/$rel 权限 $mb"; else bad "/$rel 权限 $mb，期望 $ma"; fi
}

check_overlay etc/banner
check_overlay etc/uci-defaults/99-wireless-defaults
check_overlay etc/init.d/wireless-defaults
check_overlay usr/lib/sbe1v1k/wireless-defaults

# 无线默认值三项（2026-11-13 与 24.10 对齐）。这是策略默认值，改了它
# 首启的射频行为就跟着变，所以在镜像里逐字断言。
for kv in \
	'WIFI_COUNTRY="${WIFI_COUNTRY:-US}"' \
	'WIFI_2G_HTMODE="${WIFI_2G_HTMODE:-EHT20}"' \
	'WIFI_6G_CHANNEL="${WIFI_6G_CHANNEL:-37}"'
do
	if grep -qF "$kv" "$ROOTFS/usr/lib/sbe1v1k/wireless-defaults"; then
		ok "无线默认值 $kv"
	else
		bad "无线默认值缺失：$kv"
	fi
done

# 每次开机的自愈逻辑（2026-11-13 从 24.10-6.6 移植）：缺了它们，射频被
# 生成器写成 disabled=1 或固件没有 6 GHz 信道时，“全部已禁用”会复发。
for fn in repair_band_macaddrs repair_6g_availability heal_generated_ifaces; do
	grep -q "^$fn()" "$ROOTFS/usr/lib/sbe1v1k/wireless-defaults" \
		&& ok "wireless-defaults 含 $fn（开机自愈）" \
		|| bad "wireless-defaults 缺少 $fn（自愈逻辑缺失）"
done

if grep -Eq '%[VCRD]|VERXXXX|WRTVERSIONINFO' "$ROOTFS/etc/banner"; then
	bad "镜像内 /etc/banner 仍含未替换的占位符"
else
	ok "镜像内 /etc/banner 无占位符"
fi

VLINE=$(grep -m1 '^ Version:' "$ROOTFS/etc/banner" || true)
say "版本行:${VLINE:- <缺失>}"
printf '%s' "$VLINE" | grep -Eq '^ Version: 25\.12-SNAPSHOT \(sbe1v1k-' \
	&& ok "版本行为本项目实际版本串" \
	|| bad "版本行不是 25.12-SNAPSHOT (sbe1v1k-…) 形式"

head -n1 "$ROOTFS/etc/init.d/wireless-defaults" | grep -Fxq '#!/bin/sh /etc/rc.common' \
	&& ok "/etc/init.d/wireless-defaults 首行为 rc.common" \
	|| bad "/etc/init.d/wireless-defaults 首行不是 '#!/bin/sh /etc/rc.common'"

RCD="$ROOTFS/etc/rc.d/S95wireless-defaults"
if [ -L "$RCD" ]; then
	tgt=$(readlink "$RCD")
	[ "$tgt" = "../init.d/wireless-defaults" ] \
		&& ok "/etc/rc.d/S95wireless-defaults -> $tgt" \
		|| bad "/etc/rc.d/S95wireless-defaults 指向 $tgt"
else
	bad "缺少 /etc/rc.d/S95wireless-defaults（开机不执行）"
fi

[ -f "$ROOTFS/etc/uci-defaults/99-wireless-defaults" ] \
	&& ok "首启入口 /etc/uci-defaults/99-wireless-defaults 在镜像中" \
	|| bad "镜像缺少首启入口 /etc/uci-defaults/99-wireless-defaults"

[ -f "$ROOTFS/etc/uci-defaults/99-ttyd-disable" ] \
	&& ok "首启入口 /etc/uci-defaults/99-ttyd-disable 在镜像中（ttyd 默认关闭）" \
	|| bad "镜像缺少 /etc/uci-defaults/99-ttyd-disable（ttyd 会默认开启）"

# WAN 侧放行规则（2026-11-13 从 24.10-6.6 移植）：fw4 的 wan zone 默认
# input REJECT，没有这两条规则时运营商上行链路上无法再进 LuCI/SSH。
# 逐字节比对本仓库的脚本，防止包内文件被替换而包名仍对。
DEFAULTS_FILES="$PROJ/build/local-packages/sbe1v1k-defaults/files"
for f in 99-allow-luci-wan 99-allow-ssh-wan 99-system-timezone; do
	if [ ! -f "$ROOTFS/etc/uci-defaults/$f" ]; then
		bad "镜像缺少 /etc/uci-defaults/$f（WAN 侧访问或时区默认值缺失）"
	elif cmp -s "$DEFAULTS_FILES/$f" "$ROOTFS/etc/uci-defaults/$f"; then
		ok "/etc/uci-defaults/$f 与 sbe1v1k-defaults 源文件逐字节一致"
	else
		bad "/etc/uci-defaults/$f 与 sbe1v1k-defaults 源文件不一致"
	fi
done

# ---- 端口角色：board.json 必须声明四个网口 -------------------------------
# LuCI 的状态→概览→端口状态读 board.json 的 network 段。没有本板分支时
# 99-default_network 写 lan=eth0 / wan=eth1：少两个口，2.5G 口（eth1）被划进
# LAN 后上游直接断网。补丁 0023 按 24.10 的真机结论声明 eth1=WAN、
# eth0/eth2/eth3=LAN；eth0（10G）由 overlay 的 99-spectrum-eth0-unmanaged-lan
# 从 netifd 的端口列表里摘出，交给 eth0-lan-attach 在 netifd 之外挂桥。
BOARDD_NET="$ROOTFS/etc/board.d/02_network"
if [ ! -f "$BOARDD_NET" ]; then
	bad "镜像缺少 /etc/board.d/02_network（board.json 会落到默认端口表）"
elif grep -q '^[[:space:]]*spectrum,sbe1v1k)' "$BOARDD_NET" &&
     grep -qF 'ucidef_set_interfaces_lan_wan "eth2 eth3 eth0" "eth1"' "$BOARDD_NET"; then
	ok "/etc/board.d/02_network 声明 eth1=WAN、eth0/eth2/eth3=LAN（端口面板四个口）"
else
	bad "/etc/board.d/02_network 没有 spectrum,sbe1v1k 端口映射（WAN 应为 2.5G 的 eth1）"
fi

# eth0（10G）的桥成员在 netifd 之外维护（与 24.10 相同）：uci-defaults 摘除、
# 常驻 monitor、两个 hotplug 触发点，四件缺一件 RTL8261N 就可能回到假 10G 环回。
for f in etc/uci-defaults/99-spectrum-eth0-unmanaged-lan \
         etc/init.d/eth0-lan-attach \
         etc/hotplug.d/iface/30-eth0-lan-attach \
         etc/hotplug.d/net/20-eth0-lan-attach \
         usr/sbin/eth0-lan-attach; do
	check_overlay "$f"
	[ -x "$ROOTFS/$f" ] && ok "可执行 /$f" || bad "缺少或不可执行 /$f（eth0 将交回 netifd）"
done

# 端口角色（2026-11-21 阶段 A，与 24.10 同一脚本）：sbe_ports.main.wan_port
# 决定 eth0/eth1 谁是 WAN。脚本对缺工具的场景必须**硬失败**：读不到/写不了
# SSDK 成员表时不许改 UCI（软硬不一致会让 WAN/LAN 在芯片里直通）。阶段 B 起
# 镜像自带 ssdk_sh，下一节另做镜像级断言；这里仍核对 fail-closed 代码路径。
for f in usr/sbin/sbe-port-roles etc/init.d/sbe-port-roles; do
	check_overlay "$f"
	[ -x "$ROOTFS/$f" ] && ok "可执行 /$f" || bad "缺少或不可执行 /$f（端口角色不生效）"
done
ROLEH="$ROOTFS/usr/sbin/sbe-port-roles"
if grep -q 'START=19' "$ROOTFS/etc/init.d/sbe-port-roles" 2>/dev/null; then
	ok "init.d/sbe-port-roles 为 START=19（晚于 nss S15、早于 network S20）"
else
	bad "init.d/sbe-port-roles 缺失或不是 START=19"
fi
RCT="$ROOTFS/etc/rc.d/S19sbe-port-roles"
if [ -L "$RCT" ] && [ "$(readlink "$RCT")" = "../init.d/sbe-port-roles" ]; then
	ok "/etc/rc.d/S19sbe-port-roles -> ../init.d/sbe-port-roles"
else
	bad "缺少 /etc/rc.d/S19sbe-port-roles（角色不会随开机收敛）"
fi
for pat in 'portVlan member update' 'sbe_ports.main.wan_port' 'board_detect'; do
	if grep -qF "$pat" "$ROLEH" 2>/dev/null; then
		ok "sbe-port-roles 含 $pat"
	else
		bad "sbe-port-roles 缺少 $pat"
	fi
done
if grep -q 'command -v ssdk_sh' "$ROLEH" 2>/dev/null; then
	ok "sbe-port-roles 在缺 ssdk_sh 时按角色失败关闭（不改 UCI）"
else
	bad "sbe-port-roles 没有 ssdk_sh 可用性判断（缺工具时可能软硬不一致）"
fi
if grep -q 'sbe_ports.main.wan_port' "$ROOTFS/usr/sbin/eth0-lan-attach" 2>/dev/null; then
	ok "eth0-lan-attach 按 sbe_ports 角色停手（eth0 作 WAN 时不挂桥）"
else
	bad "eth0-lan-attach 没有角色判断：eth0 作 WAN 时会被挂回 br-lan"
fi
if grep -q "wan_port='eth1'" "$ROOTFS/etc/uci-defaults/99-spectrum-eth0-unmanaged-lan" &&
   grep -q 'sbe-port-roles enable' "$ROOTFS/etc/uci-defaults/99-spectrum-eth0-unmanaged-lan"; then
	ok "uci-defaults 写 sbe_ports 默认值（eth1）并启用角色服务"
else
	bad "uci-defaults 缺少 sbe_ports 默认值或没有启用 sbe-port-roles"
fi
if grep -q 'sbe_ports.main.wan_port' "$BOARDD_NET"; then
	ok "/etc/board.d/02_network 按 sbe_ports 角色生成 board.json 网络段"
else
	bad "/etc/board.d/02_network 没有角色分支（首启/重建 board.json 会写死 eth1）"
fi

# LAN 侧 MAC 固定（S19）：GMAC3/GMAC4 没有 bootloader 注入的 MAC，nss-dp 退化为
# eth_hw_addr_random()，br-lan 继承端口里最小的随机 MAC，每次重启都变。S19 在
# netifd(S20) 建桥之前把 eth2/eth3 派生为 eth0 基址 +2/+3，桥 MAC 才恒定。
check_overlay etc/init.d/sbe-lan-mac
[ -x "$ROOTFS/etc/init.d/sbe-lan-mac" ] && ok "可执行 /etc/init.d/sbe-lan-mac" \
	|| bad "缺少或不可执行 /etc/init.d/sbe-lan-mac（br-lan MAC 会每次重启都变）"
RCT="$ROOTFS/etc/rc.d/S19sbe-lan-mac"
if [ -L "$RCT" ] && [ "$(readlink "$RCT")" = "../init.d/sbe-lan-mac" ]; then
	ok "/etc/rc.d/S19sbe-lan-mac -> ../init.d/sbe-lan-mac"
else
	bad "缺少 /etc/rc.d/S19sbe-lan-mac（S19 不会执行，br-lan MAC 随机）"
fi

# eth0 开机 USXGMII AN 死锁看门狗（2026-11-22）：约一半的重启里 XPCS 与
# RTL8261N 的 AN 不完成，eth0 挂着假链路（VR_MII_AN_INTR_STS=0x0）。
# S95 后台检测并最多自动重启一次，详见 docs/ETH0_XPCS_AN_BOOT_2026-11-22.md。
for f in usr/sbin/sbe-eth0-an-watchdog \
         etc/init.d/sbe-eth0-an-watchdog \
         etc/config/sbe_eth0_watchdog; do
	check_overlay "$f"
done
[ -x "$ROOTFS/usr/sbin/sbe-eth0-an-watchdog" ] \
	&& ok "可执行 /usr/sbin/sbe-eth0-an-watchdog" \
	|| bad "缺少或不可执行 /usr/sbin/sbe-eth0-an-watchdog"
RCT="$ROOTFS/etc/rc.d/S95sbe-eth0-an-watchdog"
if [ -L "$RCT" ] && [ "$(readlink "$RCT")" = "../init.d/sbe-eth0-an-watchdog" ]; then
	ok "/etc/rc.d/S95sbe-eth0-an-watchdog -> ../init.d/sbe-eth0-an-watchdog"
else
	bad "缺少 /etc/rc.d/S95sbe-eth0-an-watchdog（看门狗不会随开机运行）"
fi
WD="$ROOTFS/usr/sbin/sbe-eth0-an-watchdog"
for pat in '0x1f8002' '0x7f00' 'max_reboots' 'reboot'; do
	if grep -qF "$pat" "$WD" 2>/dev/null; then
		ok "sbe-eth0-an-watchdog 含 $pat"
	else
		bad "sbe-eth0-an-watchdog 缺少 $pat"
	fi
done
# 后台 worker 式 init 脚本必须整行省略 USE_PROCD。rc.common 用
# [ -n "$USE_PROCD" ] 判分支，"USE_PROCD=0" 非空，会进入 procd 路径并把
# start() 覆盖成空的 start_service——v92-1 真机上两个脚本因此开机从未运行。
for s in sbe-eth0-an-watchdog sbe-boot-trace; do
	I="$ROOTFS/etc/init.d/$s"
	if grep -q '^[[:space:]]*USE_PROCD=' "$I" 2>/dev/null; then
		bad "/etc/init.d/$s 定义了 USE_PROCD（rc.common 会吞掉 start()，开机不运行）"
	elif grep -q '^start()' "$I" 2>/dev/null; then
		ok "/etc/init.d/$s 不定义 USE_PROCD 且有 start()"
	else
		bad "/etc/init.d/$s 缺少 start()"
	fi
done

# ---- 启动取证（v35 起）：S01 采样器 + 两个 QSDK 等待循环的超时 --------------
# v34 在 S10boot 之后卡死时拿不到任何日志；采样器从 S01 起把启动现场写进
# overlay（/sbe-boot-trace/），断电重启后仍可读，所以它必须真的进镜像并在
# S01 执行。qca-ssdk / qca-nss-dp 的等待循环若丢了超时（它们原先在 S16/S18
# 自动启动，现在由 nss-load 在 S15 调用），模块装载失败时 rcS 会永久卡死、
# netifd/dnsmasq 不启动。
for f in etc/init.d/sbe-boot-trace usr/sbin/sbe-boot-trace; do
	check_overlay "$f"
	[ -x "$ROOTFS/$f" ] && ok "可执行 /$f" || bad "缺少或不可执行 /$f（启动取证不生效）"
done
RCT="$ROOTFS/etc/rc.d/S01sbe-boot-trace"
if [ -L "$RCT" ] && [ "$(readlink "$RCT")" = "../init.d/sbe-boot-trace" ]; then
	ok "/etc/rc.d/S01sbe-boot-trace -> ../init.d/sbe-boot-trace"
else
	bad "缺少 /etc/rc.d/S01sbe-boot-trace（采样器不会随启动运行）"
fi
for s in etc/init.d/qca-ssdk etc/init.d/qca-nss-dp; do
	if grep -q 'WAIT_TIMEOUT' "$ROOTFS/$s" 2>/dev/null; then
		ok "/$s 等待循环带超时"
	else
		bad "/$s 等待循环没有超时（模块装载失败会卡死 rcS）"
	fi
done

# ---- NSS 档位控制（25.12 起禁自动装载，docs/NSS_AUTOLOAD_OFF.md）-----------
# 数据通路层只允许由 nss-load 装载：镜像里不得再有这些模块的 modules.d 自动
# 装载条目，也不得有对应 init 脚本的 rc.d 启动链接；PHY 驱动的自动装载必须
# 还在（qca-nss-phy/qca8084 等由 kmodloader 在 S10 加载）。
for f in usr/sbin/nss-load etc/init.d/nss etc/nss.conf; do
	[ -e "$ROOTFS/$f" ] && ok "存在 /$f" || bad "缺少 /$f"
done
[ -x "$ROOTFS/usr/sbin/nss-load" ] && ok "可执行 /usr/sbin/nss-load" \
	|| bad "缺少或不可执行 /usr/sbin/nss-load（NSS 无法分层装载）"
if [ -f "$ROOTFS/etc/nss.conf" ] && grep -q '^tier=' "$ROOTFS/etc/nss.conf"; then
	TIER_LINE=$(grep '^tier=' "$ROOTFS/etc/nss.conf")
	ok "/etc/nss.conf 带 tier 档位: $TIER_LINE"
	if [ -f "$ROOTFS/etc/sbe-variant" ]; then
		# mainline 变体不装载 QSDK NSS，档位必须是 off
		case $TIER_LINE in
			tier=off) ok "mainline 变体 tier=off" ;;
			*) bad "mainline 变体 tier 不是 off（S15 会刷 INCOMPLETE 噪声）: $TIER_LINE" ;;
		esac
	else
		case $TIER_LINE in
			tier=full) ok "生产镜像出厂默认 tier=full（2026-11-22 起，docs/NEXT_NSS_FULL.md）" ;;
			*) bad "生产镜像 tier 不是 full: $TIER_LINE" ;;
		esac
	fi
else
	bad "/etc/nss.conf 缺少 tier= 档位（nss-load boot 会退回 wired）"
fi
RCN="$ROOTFS/etc/rc.d/S15nss"
if [ -L "$RCN" ] && [ "$(readlink "$RCN")" = "../init.d/nss" ]; then
	ok "/etc/rc.d/S15nss -> ../init.d/nss"
else
	bad "缺少 /etc/rc.d/S15nss（NSS 档位控制器不会随启动运行）"
fi
BAD_RC=$(ls "$ROOTFS/etc/rc.d" 2>/dev/null \
	| grep -E '^S[0-9]+(qca-ssdk|qca-nss-dp|qca-nss-ppe-bridge-mgr|qca-nss-ecm|shortcut-fe)$' || true)
if [ -z "$BAD_RC" ]; then
	ok "NSS 数据通路 init 脚本没有 rc.d 启动链接（不自动启动）"
else
	bad "NSS 数据通路仍有自动启动链接: $(echo $BAD_RC)"
fi
BAD_MD=$(ls "$ROOTFS/etc/modules.d" 2>/dev/null \
	| grep -E '(^|[-_])(qca-ssdk|qca-nss-dp|qca-nss-ppe|qca-nss-sfe|qca-nss-debug)([._-]|$)' || true)
if [ -z "$BAD_MD" ]; then
	ok "NSS 数据通路模块没有 modules.d 自动装载条目"
else
	bad "NSS 数据通路仍有自动装载条目: $(echo $BAD_MD)"
fi
if ls "$ROOTFS/etc/modules.d" 2>/dev/null | grep -qE 'qca-nss-phy|qca8084'; then
	ok "PHY 驱动仍随 kmodloader 自动装载（qca-nss-phy/qca8084）"
else
	bad "PHY 驱动的自动装载条目不见了（以太网 PHY 不会初始化）"
fi

# ---- SSDK 用户态工具（阶段 B，端口角色运行期改表）--------------------------
# sbe-port-roles 靠它写芯片级成员表；镜像里缺任何一个文件，eth0/none 角色
# 就只能 fail closed（默认 role=eth1 仍可启动）。db 反查另由 check-packages.sh
# 按 required-packages.txt 做，这里只看文件落点与依赖。
SSDKSH="$ROOTFS/usr/sbin/ssdk_sh"
[ -f "$SSDKSH" ] && ok "存在 /usr/sbin/ssdk_sh" \
	|| bad "缺少 /usr/sbin/ssdk_sh（端口角色无法运行期改表）"
[ -x "$SSDKSH" ] && ok "可执行 /usr/sbin/ssdk_sh" \
	|| bad "/usr/sbin/ssdk_sh 不可执行"
if [ -f "$ROOTFS/usr/lib/libssdk_us.so" ]; then
	ok "存在 /usr/lib/libssdk_us.so"
else
	bad "缺少 /usr/lib/libssdk_us.so（ssdk_sh 无法启动）"
fi

# ---- LuCI 基础栈 ------------------------------------------------------------
for f in etc/config/uhttpd etc/init.d/uhttpd www/cgi-bin/luci; do
	[ -e "$ROOTFS/$f" ] && ok "存在 /$f" || bad "缺少 /$f"
done
# 25.12 把 rpcd 装在 /sbin，24.10 在 /usr/sbin；两处都接受。
if [ -e "$ROOTFS/sbin/rpcd" ] || [ -e "$ROOTFS/usr/sbin/rpcd" ]; then
	ok "存在 rpcd（/sbin/rpcd 或 /usr/sbin/rpcd）"
else
	bad "缺少 rpcd"
fi

# ---- Stage 2.5：ath12k 固件与板级 BDF ---------------------------------------
# 本机与 CI 使用同一判据（2026-10-24 决定）：镜像必须带厂商固件/BDF，且与
# 仓库内 build/local-packages/sbe-wifi-firmware/files/ 逐字节相同。这些文件是
# 专有固件，授权状态 LICENSE_REVIEW_REQUIRED（N-3），随镜像公开分发是用户的
# 明确决定；这里不再区分“公开/本机”两种模式。
# 只有目录名从厂商的 QCN92XX/hw1.0 换成上游 hw 表的 QCN9274/hw2.0。
WIFIPKG="$PROJ/build/local-packages/sbe-wifi-firmware/files"
check_fw() {
	local rel=$1 src="$WIFIPKG/$1"
	if [ ! -f "$ROOTFS/$rel" ]; then bad "镜像缺少 /$rel"; return; fi
	if [ ! -f "$src" ]; then bad "本地固件包缺少 $rel（无法比对）"; return; fi
	local a b
	a=$(sha256sum "$src" | cut -d' ' -f1)
	b=$(sha256sum "$ROOTFS/$rel" | cut -d' ' -f1)
	if [ "$a" = "$b" ]; then ok "/$rel 与本地固件包一致 ($a)"; else bad "/$rel 哈希不一致"; fi
}

for f in firmware-2.bin board-2.bin regdb.bin; do
	check_fw "lib/firmware/ath12k/QCN9274/hw2.0/$f"
done
for f in b1.bin b2.bin b4.bin; do
	check_fw "usr/share/sbe-wifi/bdf41/$f"
done
# 包内附带的校验清单来自 files/FILES-SHA256（安装成 /usr/share/sbe-wifi-firmware/）。
if [ -f "$ROOTFS/usr/share/sbe-wifi-firmware/FILES-SHA256" ] \
   && cmp -s "$WIFIPKG/FILES-SHA256" "$ROOTFS/usr/share/sbe-wifi-firmware/FILES-SHA256"; then
	ok "/usr/share/sbe-wifi-firmware/FILES-SHA256 与本地固件包一致"
else
	bad "/usr/share/sbe-wifi-firmware/FILES-SHA256 缺失或与本地固件包不一致"
fi

# 厂商镜像里的 cal-*.bin 是进 /tmp/sbe-caldata 的悬空链接，由 init 从 eMMC ART
# 生成；上游 ath12k 找不到 cal-pci-*.bin 时会回退 caldata.bin。镜像里两者都不应
# 出现（运行期数据），这里只记录，不作为失败项。
if [ -e "$ROOTFS/lib/firmware/ath12k/QCN9274/hw2.0/caldata.bin" ]; then
	say "[verify] 注意：镜像内含 caldata.bin（应来自 ART，不应打包）"
fi

# ath12k.ko 由 kmod-ath12k 安装，可能在 lib/modules/<ver>/ 或 kernel/ 子目录。
if find "$ROOTFS/lib/modules" -name 'ath12k.ko*' | grep -q .; then
	ok "镜像含 ath12k.ko"
else
	bad "镜像缺少 ath12k.ko"
fi

# 风扇：kmod-hwmon-pwmfan 装的是 pwm-fan.ko（PWM 控制器 CONFIG_PWM_IPQ 是内建
# 的，没有单独 .ko）。v21 里这个 kmod 因 CONFIG_PWM 未开被静默丢弃，风扇满速。
if find "$ROOTFS/lib/modules" -name 'pwm-fan.ko*' | grep -q .; then
	ok "镜像含 pwm-fan.ko（kmod-hwmon-pwmfan）"
else
	bad "镜像缺少 pwm-fan.ko：CONFIG_PWM/SENSORS_PWM_FAN 未生效，风扇会停在满速"
fi

# Stage 2.6：校准生成器必须在镜像里，且在 kmodloader 之前执行
# （/etc/init.d/boot START=10 调用 kmodloader，kmod-ath12k 在 modules.d 里）。
for f in usr/lib/sbe1v1k/wifi-cal etc/init.d/sbe-wifi-cal; do
	if [ -x "$ROOTFS/$f" ]; then ok "/$f 可执行"; else bad "/$f 缺失或不可执行"; fi
done
if [ -L "$ROOTFS/etc/rc.d/S09sbe-wifi-cal" ]; then
	tgt=$(readlink "$ROOTFS/etc/rc.d/S09sbe-wifi-cal")
	[ "$tgt" = "../init.d/sbe-wifi-cal" ] \
		&& ok "/etc/rc.d/S09sbe-wifi-cal -> $tgt" \
		|| bad "/etc/rc.d/S09sbe-wifi-cal 指向 $tgt"
else
	bad "缺少 /etc/rc.d/S09sbe-wifi-cal（校准不会在 ath12k 加载前生成）"
fi

# ---- 升级脚本：sysupgrade 必须按当前槽位写 eMMC ------------------------------
# 本板是 A/B 布局（0:HLOS|rootfs 与 0:HLOS_1|rootfs_1）。没有 spectrum,sbe1v1k
# 分支就会落到 default_do_upgrade（mtd write - image），在这块板上等于什么都没
# 刷；槽位写死则会把内核与根文件系统写进不同的槽，重启后起不来。
UPG_SRC="$BR/target/linux/qualcommbe/ipq95xx/base-files/lib/upgrade/platform.sh"
UPG_IMG="$ROOTFS/lib/upgrade/platform.sh"
if [ ! -f "$UPG_IMG" ]; then
	bad "镜像缺少 /lib/upgrade/platform.sh"
elif ! grep -q '^sbe_detect_slot()' "$UPG_IMG"; then
	bad "镜像里的升级脚本没有 sbe_detect_slot：槽位是写死的"
elif ! grep -q 'spectrum,sbe1v1k' "$UPG_IMG"; then
	bad "升级脚本没有 spectrum,sbe1v1k 分支（会落到 default_do_upgrade 写 mtd）"
elif ! grep -q 'emmc_do_upgrade' "$UPG_IMG"; then
	bad "升级脚本没有调用 emmc_do_upgrade"
elif [ -f "$UPG_SRC" ] && ! cmp -s "$UPG_SRC" "$UPG_IMG"; then
	bad "镜像里的 /lib/upgrade/platform.sh 与装配树不一致"
else
	ok "升级脚本按槽位写 eMMC（sbe_detect_slot + emmc_do_upgrade）且与装配树一致"
fi

# ---- 包数据库 ---------------------------------------------------------------
# apk 数据库在 25.12 是 /lib/apk/db/installed（老版本/opkg 为 /usr/lib/...）。
APKDB=""
for c in lib/apk/db/installed usr/lib/apk/db/installed; do
	[ -f "$ROOTFS/$c" ] && { APKDB=$ROOTFS/$c; break; }
done
if [ -n "$APKDB" ]; then
	n=$(grep -c '^P:' "$APKDB" || true)
	ok "apk 包数量 $n（/${APKDB#$ROOTFS/}）"
elif [ -f "$ROOTFS/usr/lib/opkg/status" ]; then
	n=$(grep -c '^Package:' "$ROOTFS/usr/lib/opkg/status" || true)
	ok "opkg 包数量 $n"
else
	bad "缺少 apk/opkg 包数据库"
fi

# ---- Stage 2.5：无线软件包 ---------------------------------------------------
if [ -n "$APKDB" ]; then
	has_pkg() { grep -qx "P:$1" "$APKDB"; }
elif [ -f "$ROOTFS/usr/lib/opkg/status" ]; then
	has_pkg() { grep -qx "Package: $1" "$ROOTFS/usr/lib/opkg/status"; }
else
	has_pkg() { return 1; }
fi

for p in kmod-mac80211 kmod-ath12k wifi-scripts wpad-mesh-mbedtls; do
	has_pkg "$p" && ok "包 $p 已安装" || bad "包 $p 未安装"
done
has_pkg sbe-wifi-firmware && ok "包 sbe-wifi-firmware 已安装" \
	|| bad "包 sbe-wifi-firmware 未安装"
# NSS Wi-Fi offload 不在本阶段范围内；出现即说明装配树被污染。
for p in qca-nss-wifi-plugins qca-wifi-nss-plugins; do
	if has_pkg "$p"; then bad "包 $p 不应出现在 S2.5 镜像中"; else ok "包 $p 未安装（S2.5 预期）"; fi
done

# ---- 用户请求的包集合反查 ---------------------------------------------------
# 唯一来源 build/required-packages.txt（必装 / 可选 / 必禁三档）。
# 与 seed 检查、defconfig 检查共用同一份清单，避免三处各写一遍。
set +e
"$SELF/check-packages.sh" db "$ROOTFS"
rc=$?
set -e
case "$rc" in
0) ok "required-packages.txt 反查通过（包数据库）" ;;
2) bad "check-packages.sh 无法读取包数据库" ;;
*) bad "required-packages.txt 反查未通过（见上面的 FAIL 行）" ;;
esac

# ---- 代理内核与插件后端：包数据库之外再确认可执行文件确实落地 ---------------
# （包名对但安装路径变了，同样是一次交付事故。）
for f in usr/bin/xray usr/bin/sing-box usr/bin/mosdns etc/init.d/mosdns etc/config/mosdns; do
	if [ -e "$ROOTFS/$f" ]; then ok "存在 /$f"; else bad "缺少 /$f"; fi
done
# bandix 已于 2026-11-15 前后端整体移除（先前端换 mosdns，随后后端也删）；
# 包数据库之外再按文件兜一层底，防止旧装配树残留。
for f in usr/bin/bandix-plus etc/init.d/bandix-plus etc/config/bandix_plus \
	www/luci-static/resources/view/bandix; do
	if [ -e "$ROOTFS/$f" ]; then bad "bandix 已移除，镜像里不应有 /$f"; else ok "无 /$f（bandix 已移除）"; fi
done
if [ -e "$ROOTFS/usr/libexec/mihomo" ] || [ -e "$ROOTFS/usr/bin/mihomo" ]; then
	ok "存在 mihomo 二进制（usr/libexec/mihomo 或 usr/bin/mihomo）"
else
	bad "缺少 mihomo 二进制（nikki 无法拉起）"
fi
if [ -e "$ROOTFS/usr/bin/ruby" ]; then ok "存在 /usr/bin/ruby"; else bad "缺少 /usr/bin/ruby（OpenClash 无法工作）"; fi
if [ -d "$ROOTFS/www/luci-static/argon" ]; then
	ok "存在 Argon 主题资源 /www/luci-static/argon"
else
	bad "缺少 Argon 主题资源 /www/luci-static/argon"
fi

exit "$fail"
