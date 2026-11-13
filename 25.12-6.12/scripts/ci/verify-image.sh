#!/usr/bin/env bash
# 25.12-6.12 Stage 1 编译后的静态检查（不接触设备、不执行目标二进制）。
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
#      （板子从 eMMC 启动，控制器关闭时真机无法启动）；
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

SBE_ROOT="$ROOT" SBE_BUILDROOT="$BR" "$PROJ/scripts/render-overlay.sh"

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
				|| bad "DTB 中 mmc@7804000 未启用：内核拿不到 mmcblk0，根文件系统无法挂载" ;;
		*) bad "DTB 中找不到 mmc@7804000 节点" ;;
		esac
		# overlay 的位置：厂商 GPT 里有 rootfs_data 分区，fstools 默认会去用它；
		# 本项目的模型是 overlay 建在 rootfs 分区尾部（升级时只需写 HLOS/rootfs
		# 两个分区）。靠 chosen/bootargs-append 传 fstools_ignore_partname=1，
		# 这个选项是 920-device_tree_cmdline.patch 提供的，缺了它 fstools 会改去
		# 挂 rootfs_data，升级与恢复的语义都跟着变。
		CHOSEN=$(awk '/^[[:space:]]*chosen \{/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC")
		printf '%s\n' "$CHOSEN" | grep -q 'fstools_ignore_partname=1' \
			&& ok "DTB 的 chosen/bootargs-append 带 fstools_ignore_partname=1" \
			|| bad "DTB 的 chosen 没有 fstools_ignore_partname=1（fstools 会改用 rootfs_data 分区）"
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
for f in 99-allow-luci-wan 99-allow-ssh-wan; do
	if [ ! -f "$ROOTFS/etc/uci-defaults/$f" ]; then
		bad "镜像缺少 /etc/uci-defaults/$f（WAN 侧将无法访问 LuCI/SSH）"
	elif cmp -s "$DEFAULTS_FILES/$f" "$ROOTFS/etc/uci-defaults/$f"; then
		ok "/etc/uci-defaults/$f 与 sbe1v1k-defaults 源文件逐字节一致"
	else
		bad "/etc/uci-defaults/$f 与 sbe1v1k-defaults 源文件不一致"
	fi
done

# ---- 端口角色：board.json 必须声明四个网口 -------------------------------
# LuCI 的状态→概览→端口状态读 board.json 的 network 段。没有本板分支时
# 99-default_network 写 lan=eth0 / wan=eth1：少两个口且 LAN/WAN 角色反了。
# 补丁 0023 在 02_network 里声明 eth0=WAN、eth1/eth2/eth3=LAN。
BOARDD_NET="$ROOTFS/etc/board.d/02_network"
if [ ! -f "$BOARDD_NET" ]; then
	bad "镜像缺少 /etc/board.d/02_network（board.json 会落到默认端口表）"
elif grep -q '^[[:space:]]*spectrum,sbe1v1k)' "$BOARDD_NET" &&
     grep -qF 'ucidef_set_interfaces_lan_wan "eth1 eth2 eth3" "eth0"' "$BOARDD_NET"; then
	ok "/etc/board.d/02_network 声明 eth0=WAN、eth1-eth3=LAN（端口面板四个口）"
else
	bad "/etc/board.d/02_network 没有 spectrum,sbe1v1k 端口映射（端口面板只会显示 eth0/eth1 且角色相反）"
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
for f in usr/bin/xray usr/bin/sing-box usr/bin/bandix-plus etc/init.d/bandix-plus; do
	if [ -e "$ROOTFS/$f" ]; then ok "存在 /$f"; else bad "缺少 /$f"; fi
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
