#!/usr/bin/env bash
# 25.12-6.12 Stage 1 编译后的静态检查（不接触设备、不执行目标二进制）。
#
# 检查对象是最终交付物本身：本目标的 sysupgrade 镜像是
#   <fit kernel> | pad-to 64k | <squashfs rootfs> | pad-rootfs
# （与上游 qualcommbe/qcom_rdp433 相同的布局），所以先按 64 KiB 对齐定位
# squashfs 偏移，再从镜像里解出根文件系统核对。
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
#   6. apk/opkg 包数据库存在并打印包数量。
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

# ---- 定位 squashfs 并解包 ---------------------------------------------------
TMPBASE=${SBE_TMPDIR:-/var/tmp}
TMP=$(mktemp -d "$TMPBASE/sbe-verify.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

UNSQ="$BR/staging_dir/host/bin/unsquashfs4"
[ -x "$UNSQ" ] || UNSQ=$(command -v unsquashfs || true)
[ -n "$UNSQ" ] && [ -x "$UNSQ" ] || { bad "缺少 unsquashfs4"; exit 1; }

# kernel 是 FIT（sbe1v1k-fit-uImage.itb），pad-to 64k 之后紧跟 squashfs。
KSIZE=$(stat -c %s "$FIT")
OFF=$(( (KSIZE + 65535) / 65536 * 65536 ))
magic=$(dd if="$IMG" bs=1 skip="$OFF" count=4 status=none | od -An -tx1 | tr -d ' \n')
if [ "$magic" != "68737173" ] && [ "$magic" != "73717368" ]; then
	# 回退：在镜像里搜索 squashfs 魔数并逐个尝试。
	OFF=""
	while IFS=: read -r pos _; do
		[ -n "$pos" ] || continue
		if "$UNSQ" -o "$pos" -s "$IMG" >/dev/null 2>&1; then OFF=$pos; break; fi
	done < <(grep -abo -a 'hsqs' "$IMG" | head -n 20)
	[ -n "$OFF" ] || { bad "在镜像中找不到 squashfs 超级块"; exit 1; }
fi
say "[verify] squashfs 偏移 $OFF"

set +e
"$UNSQ" -no-progress -o "$OFF" -d "$TMP/rootfs" "$IMG" >"$TMP/unsquashfs.log" 2>&1
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

exit "$fail"
