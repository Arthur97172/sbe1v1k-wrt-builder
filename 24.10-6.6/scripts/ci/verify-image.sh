#!/usr/bin/env bash
# 编译后的静态检查（不接触设备、不执行目标二进制）。
#
# 检查对象是**最终交付物本身**：从 sysupgrade 镜像的 tar 包里取出 squashfs
# 根文件系统，再解出来核对。因此这里看到的就是刷进设备的文件，而不是构建
# 中间目录（build_dir/.../root-ipq95xx）。
#
# 检查项：
#   1. 三个交付镜像齐全、非空，打印尺寸与 SHA-256；
#   2. spectrum_sbe1v1k 的 sysupgrade 镜像小于 96 MiB（ipq95xx 的 IMAGE_SIZE）；
#   3. /etc/banner 与 $PROJ/files 渲染后的文件哈希一致，且不含
#      %V/%R/VERXXXX/WRTVERSIONINFO 占位符、含真实版本行；
#   4. 无线默认值三件套（uci-defaults / init.d / 实现脚本）哈希一致、权限 0755，
#      且 /etc/rc.d/S95wireless-defaults 开机链接存在并指向正确目标；
#   5. 关键二进制/配置存在；本次明确不打包的 geoview、v2ray-plugin 缺席；
#      /etc/config/passwall 由上游 uci-defaults 在首启时从 0_default_config 生成，
#      故检查来源文件而非该运行期文件；
#   6. opkg 状态文件里的包数量；
#   7. 设置了 SBE_EXPECT_WIFI_FIRMWARE=1 时（CI 使用）：sbe-wifi-firmware
#      已安装，且 6 个厂商固件/BDF 与装配树里的包逐字节一致；
#   8. 设备树里 mmc@7804000（eMMC）为 okay，且该 DTB 逐字节存在于两个 FIT 中
#      （板子从 eMMC 启动，控制器关闭时真机无法启动）；
#   9. 镜像里的升级脚本带 A/B 槽位探测（写死槽位会让升级写进没人读的分区）。
#
# 任何一项失败即以非零退出，CI 记为失败，不做静默降级。
#
# 用法：scripts/ci/verify-image.sh [工作区根目录]
#   SBE_ROOT / SBE_BUILDROOT 可显式指定装配树位置。

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)      # <repo>/24.10-6.6

if [ -n "${SBE_ROOT:-}" ]; then
	ROOT=$SBE_ROOT
else
	ROOT=${1:-}
	if [ -z "$ROOT" ]; then
		d=$PROJ
		while [ "$d" != / ]; do
			if [ -d "$d/sources/buildroot" ]; then ROOT=$d; break; fi
			d=$(dirname "$d")
		done
	fi
fi
[ -n "$ROOT" ] || { echo "找不到工作区根（含 sources/buildroot），可用 SBE_ROOT 指定" >&2; exit 1; }

BR=${SBE_BUILDROOT:-$ROOT/sources/buildroot}
OUT="$BR/bin/targets/ipq95xx/generic"
OVERLAY="$PROJ/files"
fail=0

say()  { printf '%s\n' "$*"; }
ok()   { printf 'PASS   %s\n' "$*"; }
bad()  { printf 'FAIL   %s\n' "$*"; fail=1; }

# 先渲染 overlay（幂等），保证下面比对的是本次构建实际会写进镜像的文件。
SBE_ROOT="$ROOT" SBE_BUILDROOT="$BR" "$PROJ/scripts/render-overlay.sh"

IMG="$OUT/openwrt-ipq95xx-generic-spectrum_sbe1v1k-squashfs-sysupgrade.bin"
FIT="$OUT/openwrt-ipq95xx-generic-spectrum_sbe1v1k-fit-uImage.itb"
INITRAMFS="$OUT/openwrt-ipq95xx-generic-spectrum_sbe1v1k-initramfs-fit-uImage.itb"

for f in "$IMG" "$FIT" "$INITRAMFS"; do
	if [ -s "$f" ]; then
		ok "存在 $(basename "$f") ($(stat -c %s "$f") 字节)"
		sha256sum "$f"
	else
		bad "缺少或为空：$f"
	fi
done
[ -s "$IMG" ] || exit 1

SIZE=$(stat -c %s "$IMG")
if [ "$SIZE" -lt $((96 * 1024 * 1024)) ]; then
	ok "sysupgrade 镜像小于 96 MiB"
else
	bad "sysupgrade 镜像超过 96 MiB"
fi

TMPBASE=${SBE_TMPDIR:-/var/tmp}
TMP=$(mktemp -d "$TMPBASE/sbe-verify.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ---- 设备树：eMMC 控制器必须启用 --------------------------------------------
# 本机从 eMMC 启动：U-Boot 按 bootconfig 选槽后注入 root=PARTUUID=<uuid>，
# 内核必须先有 mmcblk0 才能挂根。ipq9574.dtsi 把 sdhc_1 设成 disabled，必须由
# 设备 DTS 显式启用；不启用时的表现是真机一抹黑（已复现“刷入后无法启动”）。
# 这里检查编进 FIT 的 DTB 本身：DTS 写对了却没编进去，同样算失败。
DTB=$(ls "$BR"/build_dir/target-*/linux-ipq95xx_generic/linux-*/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dtb \
         "$BR"/bin/targets/ipq95xx/generic/dtbs/ipq9574-sbe1v1k.dtb 2>/dev/null | head -n1 || true)
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
	else
		bad "无法反编译 DTB：$DTB"
	fi
	# 两个交付 FIT 都是 MultiDTBFIT，fdt 不压缩，可直接按字节子串判断。
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
	bad "找不到编译出的 DTB（build_dir/target-*/linux-ipq95xx_generic/linux-*/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dtb）"
fi

# ---- 从最终镜像里解出 squashfs 根文件系统 ----------------------------------

say "[verify] 从 sysupgrade 镜像提取 squashfs"
tar -xf "$IMG" -C "$TMP" sysupgrade-spectrum_sbe1v1k/root

UNSQ="$BR/staging_dir/host/bin/unsquashfs4"
[ -x "$UNSQ" ] || { bad "缺少 $UNSQ"; exit 1; }

set +e
"$UNSQ" -no-progress -d "$TMP/rootfs" "$TMP/sysupgrade-spectrum_sbe1v1k/root" >"$TMP/unsquashfs.log" 2>&1
rc=$?
set -e
# 非 root 用户解不出 /dev/console 等设备节点时返回 2，其余文件正常解出。
case "$rc" in
	0) ok "squashfs 解包完成" ;;
	2) ok "squashfs 解包完成（rc=2：设备节点权限，非 root 预期）" ;;
	*) bad "squashfs 解包失败 rc=$rc"; sed -n '1,20p' "$TMP/unsquashfs.log"; exit 1 ;;
esac

ROOTFS="$TMP/rootfs"
[ -d "$ROOTFS/etc" ] || { bad "解包结果缺少 /etc"; exit 1; }

# ---- banner 与 wireless 文件：哈希 / 权限 / 开机链接 ------------------------
# 比对基准是**渲染后**的 overlay（$BR/files）：banner 的 %V/%R 已在渲染时替换，
# 与镜像内文件必须逐字节一致。
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

if grep -Eq '%[VCRD]|VERXXXX|WRTVERSIONINFO' "$ROOTFS/etc/banner"; then
	bad "镜像内 /etc/banner 仍含未替换的占位符"
	grep -nE '%[VCRD]|VERXXXX|WRTVERSIONINFO' "$ROOTFS/etc/banner" || true
else
	ok "镜像内 /etc/banner 无占位符"
fi

VLINE=$(grep -m1 '^ Version:' "$ROOTFS/etc/banner" || true)
say "版本行:${VLINE:- <缺失>}"
case "$VLINE" in
	" Version: "*) ok "版本行存在" ;;
	*) bad "缺少版本行" ;;
esac
if printf '%s' "$VLINE" | grep -Eq '^ Version: 24\.10-SNAPSHOT \(sbe1v1k-'; then
	ok "版本行为本项目实际版本串"
else
	bad "版本行不是 24.10-SNAPSHOT (sbe1v1k-…) 形式"
fi

# prepare_rootfs 只对首行精确为 '#!/bin/sh /etc/rc.common' 的脚本自动 enable。
head -n1 "$ROOTFS/etc/init.d/wireless-defaults" | grep -Fxq '#!/bin/sh /etc/rc.common' \
	&& ok "/etc/init.d/wireless-defaults 首行为 rc.common" \
	|| bad "/etc/init.d/wireless-defaults 首行不是 '#!/bin/sh /etc/rc.common'"

RCD="$ROOTFS/etc/rc.d/S95wireless-defaults"
if [ -L "$RCD" ]; then
	tgt=$(readlink "$RCD")
	if [ "$tgt" = "../init.d/wireless-defaults" ]; then
		ok "/etc/rc.d/S95wireless-defaults -> $tgt"
	else
		bad "/etc/rc.d/S95wireless-defaults 指向 $tgt"
	fi
elif [ -e "$RCD" ]; then
	bad "/etc/rc.d/S95wireless-defaults 存在但不是软链"
else
	bad "缺少 /etc/rc.d/S95wireless-defaults（开机不执行）"
fi

# 首启入口：uci-defaults 只在首启运行，文件在首启成功后才被删除，
# 因此镜像里必须存在（它就是首启那一份）。
[ -f "$ROOTFS/etc/uci-defaults/99-wireless-defaults" ] \
	&& ok "首启入口 /etc/uci-defaults/99-wireless-defaults 在镜像中" \
	|| bad "镜像缺少首启入口 /etc/uci-defaults/99-wireless-defaults"

# ---- 升级脚本：sysupgrade 必须写回当前槽位 ----------------------------------
# 板子是 A/B 布局（0:HLOS|rootfs 与 0:HLOS_1|rootfs_1）。写死槽位会让升级
# 悄悄失效，或者把内核与根文件系统写进不同槽位导致无法启动。镜像里的脚本
# 必须带槽位探测，且与装配树（= 仓库 build/p-b/files）逐字节一致。
UPG_SRC="$BR/target/linux/feeds/ipq95xx/base-files/lib/upgrade/platform.sh"
UPG_IMG="$ROOTFS/lib/upgrade/platform.sh"
if [ ! -f "$UPG_IMG" ]; then
	bad "镜像缺少 /lib/upgrade/platform.sh"
elif ! grep -q '^sbe_detect_slot()' "$UPG_IMG"; then
	bad "镜像里的升级脚本没有 sbe_detect_slot：sysupgrade 会写死 0:HLOS/rootfs"
elif ! grep -q '0:HLOS_1 rootfs_1' "$UPG_IMG" || ! grep -q '0:HLOS rootfs' "$UPG_IMG"; then
	bad "镜像里的升级脚本缺少 rootfs / rootfs_1 两种槽位映射"
elif [ -f "$UPG_SRC" ] && ! cmp -s "$UPG_SRC" "$UPG_IMG"; then
	bad "镜像里的 /lib/upgrade/platform.sh 与装配树不一致"
else
	ok "升级脚本含槽位探测（rootfs / rootfs_1）且与装配树一致"
fi

# ---- 关键文件存在 / 明确排除 ------------------------------------------------
for f in \
	usr/bin/xray usr/bin/sing-box usr/bin/chinadns-ng usr/bin/dns2socks \
	usr/bin/ipt2socks usr/bin/microsocks usr/bin/tcping usr/bin/obfs-local \
	usr/bin/ssr-local usr/bin/ssr-redir usr/libexec/mihomo usr/bin/bandix-plus \
	usr/sbin/wifihistory usr/bin/ruby usr/bin/ttyd \
	etc/init.d/passwall etc/init.d/nikki etc/init.d/openclash \
	etc/config/nikki etc/config/openclash \
	usr/share/passwall/0_default_config \
	etc/uci-defaults/luci-app-passwall \
	etc/uci-defaults/99-ttyd-disable
do
	[ -e "$ROOTFS/$f" ] && ok "存在 /$f" || bad "缺少 /$f"
done

for f in usr/bin/geoview usr/bin/v2ray-plugin usr/bin/v2ray; do
	[ -e "$ROOTFS/$f" ] && bad "不应存在 /$f" || ok "缺席 /$f"
done

if [ -f "$ROOTFS/usr/lib/opkg/status" ]; then
	n=$(grep -c '^Package:' "$ROOTFS/usr/lib/opkg/status")
	ok "包数量 $n"

	# 文件 B 里启用的每个包都必须真的装进镜像（defconfig 静默丢弃的兜底判据）。
	# 只断言“启用 → 必须存在”；未启用的包可能被依赖拉回来，不做缺席断言。
	MISSING=""
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		if grep -qx "Package: $p" "$ROOTFS/usr/lib/opkg/status"; then
			ok "文件 B 启用的包已安装: $p"
		else
			bad "文件 B 启用的包未安装: $p"
			MISSING="$MISSING $p"
		fi
	done <<EOF
$("$PROJ/scripts/custom-packages.sh" --list-enabled)
EOF
else
	bad "缺少 opkg status"
fi

# ---- 无线固件（CI 断言）------------------------------------------------------
# 2026-10-24 决定：公开 CI 镜像也带厂商 Wi-Fi 固件（LICENSE_REVIEW_REQUIRED）。
# 设 SBE_EXPECT_WIFI_FIRMWARE=1 时，镜像必须装 sbe-wifi-firmware，且 6 个文件
# 与装配树里的固件包逐字节一致；不设时跳过这项检查（本机自由构建）。
if [ "${SBE_EXPECT_WIFI_FIRMWARE:-0}" = 1 ]; then
	FW="$BR/package/sbe-wifi-firmware/files"
	if grep -qx 'Package: sbe-wifi-firmware' "$ROOTFS/usr/lib/opkg/status" 2>/dev/null; then
		ok "包 sbe-wifi-firmware 已安装"
	else
		bad "包 sbe-wifi-firmware 未安装（CI 镜像必须带无线固件）"
	fi
	for f in lib/firmware/ath12k/QCN92XX/hw1.0/firmware-2.bin \
	         lib/firmware/ath12k/QCN92XX/hw1.0/board-2.bin \
	         lib/firmware/ath12k/QCN92XX/hw1.0/regdb.bin \
	         usr/share/sbe-wifi/bdf41/b1.bin \
	         usr/share/sbe-wifi/bdf41/b2.bin \
	         usr/share/sbe-wifi/bdf41/b4.bin; do
		if [ ! -f "$ROOTFS/$f" ]; then
			bad "镜像缺少 /$f"
		elif [ ! -f "$FW/$f" ]; then
			bad "固件包缺少 $f（无法比对）"
		elif cmp -s "$FW/$f" "$ROOTFS/$f"; then
			ok "/$f 与固件包一致"
		else
			bad "/$f 哈希不一致"
		fi
	done
fi

exit "$fail"
