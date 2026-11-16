#!/usr/bin/env bash
# 25.12-6.12 诊断变体（diag / mainline）编译后的静态检查。
#
# 与 verify-image.sh 的区别：诊断镜像只产出 initramfs FIT（RAM 启动，不写
# eMMC），所以这里校验的是「能不能被恢复启动器安全拉起」：
#   1. initramfs FIT 存在、尺寸 < 31 MiB（APPSBL tftpboot 512 B 块上限
#      ≈ 32 MiB，留 1 MiB 余量）；
#   2. FIT 装载地址 0x42200000（0x41000000 落在 NSS 保留区）；
#   3. 内核确实按 XZ 压缩 initramfs（.config 的 CONFIG_INITRAMFS_COMPRESSION_XZ /
#      CONFIG_RD_XZ，以及 scripts/Makefile.lib 的 128 MiB 字典补丁）；
#   4. FIT 内含编译出的 DTB，且 DTB 的 eMMC 已启用、QPIC NAND 已关闭；
#   5. 装配树 rootfs（TARGET_DIR，就是内核嵌进去的那份）里：
#      - /etc/sbe-variant 与变体一致；
#      - /etc/nss.conf tier=off（diag）；mainline 不检查这一项；
#      - dropbear authorized_keys 存在且权限 600；
#      - 板面信标脚本与 S99 链接存在（diag）；
#      - apk 数据库里有 QSDK NSS/SSDK 组件（diag），mainline 则必须没有；
#   6. 用 build/required-packages-<variant>.txt 做一次 db 反查（与生产同一
#      套 check-packages.sh）。
#
# 用法：SBE_VARIANT=diag scripts/ci/verify-diag.sh [工作区根目录]
# 状态词：PASS / FAIL / WARN。

set -euo pipefail
LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)

VARIANT=${SBE_VARIANT:-diag}
case "$VARIANT" in
diag|mainline) ;;
*) echo "verify-diag.sh 只支持 SBE_VARIANT=diag|mainline（当前 $VARIANT）" >&2; exit 2 ;;
esac

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
fail=0

ok()   { printf 'PASS   %s\n' "$*"; }
bad()  { printf 'FAIL   %s\n' "$*"; fail=1; }
note() { printf 'WARN   %s\n' "$*"; }

case "$VARIANT" in
diag)     PFX=sbe1v1k ;;
mainline) PFX=sbe1v1k-mainline ;;
esac
FIT="$OUT/$PFX-initramfs-fit-uImage.itb"

say() { printf '%s\n' "$*"; }
say "[verify] 变体 $VARIANT，装配树 $BR"

# ---- 1. FIT 存在与尺寸 -----------------------------------------------------
if [ -s "$FIT" ]; then
	sz=$(stat -c %s "$FIT")
	ok "存在 $(basename "$FIT") ($sz 字节)"
	sha256sum "$FIT"
	# 32 MiB = 33554432 B：恢复启动器 tftpboot 的 512 B 块数上限。
	if [ "$sz" -ge 33554432 ]; then
		bad "initramfs FIT $sz B ≥ 32 MiB：APPSBL tftpboot 拉不动，不要拿去上机"
	elif [ "$sz" -ge 32505856 ]; then
		note "initramfs FIT $sz B 已接近 31 MiB 上限，上机前再核对一次 TFTP 块设置"
	else
		ok "initramfs FIT 在 31 MiB 预算内"
	fi
else
	bad "缺少或为空：$FIT"
	exit 1
fi

TMPBASE=${SBE_TMPDIR:-/var/tmp}
TMP=$(mktemp -d "$TMPBASE/sbe-verify-diag.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ---- 2. overlay 渲染（带变体）---------------------------------------------
SBE_VARIANT="$VARIANT" SBE_ROOT="$ROOT" SBE_BUILDROOT="$BR" \
	"$PROJ/scripts/render-overlay.sh" \
	|| { bad "render-overlay.sh 失败（变体 $VARIANT）"; exit 1; }
OKFILE="$BR/files/etc/nss.conf"
[ -f "$OKFILE" ] || bad "渲染后的 overlay 缺少 /etc/nss.conf"

# ---- 3. 内核 initramfs 压缩与字典补丁 --------------------------------------
KCONF=$(ls "$BR"/build_dir/target-*/linux-qualcommbe_ipq95xx/linux-*/.config 2>/dev/null | head -n1 || true)
if [ -n "$KCONF" ] && [ -f "$KCONF" ]; then
	for sym in CONFIG_BLK_DEV_INITRD CONFIG_INITRAMFS_COMPRESSION_XZ CONFIG_RD_XZ; do
		grep -qx "$sym=y" "$KCONF" \
			&& ok "内核 .config 有 $sym=y" \
			|| bad "内核 .config 缺少 $sym=y（initramfs 不会被 XZ 压缩）"
	done
	grep -qx '# CONFIG_INITRAMFS_COMPRESSION_NONE is not set' "$KCONF" \
		&& ok "内核 .config 没有退回未压缩 initramfs（NONE）" \
		|| bad "内核 .config 仍启用 CONFIG_INITRAMFS_COMPRESSION_NONE"
	LIBN="$BR"/build_dir/target-*/linux-qualcommbe_ipq95xx/linux-*/scripts/Makefile.lib
	# shellcheck disable=SC2086
	if grep -q -- '--lzma2=dict=128MiB' $LIBN 2>/dev/null; then
		ok "内核 Makefile.lib 的 cmd_xzmisc 带 128 MiB 字典（补丁 0031 生效）"
	else
		bad "内核 Makefile.lib 没有 128 MiB 字典（补丁 0031 未生效，压缩率会不够）"
	fi
else
	bad "找不到内核 .config（$BR/build_dir/target-*/linux-qualcommbe_ipq95xx/linux-*/.config）"
fi

# ---- 4. FIT 装载地址 -------------------------------------------------------
# Build/fit-its 把 .its 写在镜像旁边：<KDIR>/tmp/<name>.itb.its（KDIR 即
# build_dir/.../linux-qualcommbe_ipq95xx）。kernel 目录下的同名 glob 只是
# 兜底，正常构建不需要。
ITS=$(ls "$BR"/build_dir/target-*/linux-qualcommbe_ipq95xx/tmp/*"$PFX"-initramfs*.its \
         "$BR"/build_dir/target-*/linux-qualcommbe_ipq95xx/tmp/*initramfs*.its \
         "$BR"/build_dir/target-*/linux-qualcommbe_ipq95xx/*initramfs*.its \
         2>/dev/null | head -n1 || true)
if [ -n "$ITS" ] && [ -f "$ITS" ]; then
	if grep -q 'load = <0x42200000>' "$ITS" && grep -q 'entry = <0x42200000>' "$ITS"; then
		ok "FIT 内核 load/entry = 0x42200000（不落在 NSS 保留区）"
	else
		bad "FIT 装载地址不是 0x42200000（0x41000000 落在 NSS 保留区，真机起不来）"
	fi
else
	bad "找不到 initramfs FIT 的 .its（无法校验装载地址）"
fi

# ---- 5. DTB：eMMC 启用、QPIC NAND 关闭、FIT 内确实带它 ----------------------
DTB=$(ls "$BR"/build_dir/target-*/linux-qualcommbe_ipq95xx/image-ipq9574-*.dtb \
         2>/dev/null | head -n1 || true)
case "$VARIANT" in
diag)     DTBNAME=ipq9574-sbe1v1k.dtb ;;
mainline) DTBNAME=ipq9574-rdp433.dtb ;;
esac
DTB2=$(ls "$BR"/build_dir/target-*/linux-qualcommbe_ipq95xx/linux-*/arch/arm64/boot/dts/qcom/"$DTBNAME" \
          2>/dev/null | head -n1 || true)
[ -n "$DTB2" ] && DTB=$DTB2
if [ -n "$DTB" ] && [ -f "$DTB" ]; then
	ok "编译出的 DTB：${DTB#$BR/}"
	if command -v dtc >/dev/null 2>&1; then
		DTBDEC=$TMP/dtb.dts
		if dtc -I dtb -O dts -o "$DTBDEC" "$DTB" 2>/dev/null; then
			if [ "$VARIANT" = diag ]; then
				MMC=$(awk '/mmc@7804000/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC")
				printf '%s\n' "$MMC" | grep -q 'status = "okay"' \
					&& ok "DTB 中 mmc@7804000（eMMC）status = okay" \
					|| bad "DTB 中 mmc@7804000 未启用（WiFi cal 要从 eMMC ART 取数据）"
				QPIC=$(awk '/spi@79b0000/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC")
				printf '%s\n' "$QPIC" | grep -q 'status = "disabled"' \
					&& ok "DTB 中 QPIC NAND 已关闭" \
					|| bad "DTB 中 QPIC NAND 未关闭（会抢 eMMC 引脚）"
				if grep -q 'operating-points-v2 = <' "$DTBDEC"; then
					bad "DTB 的 CPU 仍带 operating-points-v2（cpufreq-dt 会重写 A73 PLL）"
				else
					ok "DTB 的 CPU 没有 operating-points-v2"
				fi
				if awk '/sleep-clk \{/{on=1} on{print} on && /^[[:space:]]*\};/{exit}' "$DTBDEC" | grep -q 'clock-frequency'; then
					bad "DTB 的 sleep-clk 带 clock-frequency"
				else
					ok "DTB 的 sleep-clk 没有 clock-frequency"
				fi
			else
				# mainline 变体用上游 rdp433 设备树：不做事先断言，只记录。
				note "mainline 变体使用上游 rdp433 设备树，不做板级断言"
			fi
		else
			note "dtc 无法反编译 DTB，跳过 DTB 内容检查"
		fi
	else
		note "宿主机没有 dtc，跳过 DTB 内容检查"
	fi
	if python3 -c 'import sys
a = open(sys.argv[1], "rb").read(); b = open(sys.argv[2], "rb").read()
sys.exit(0 if b in a else 1)' "$FIT" "$DTB"; then
		ok "$(basename "$FIT") 内含这个 DTB"
	else
		bad "$(basename "$FIT") 里找不到编出的 DTB（FIT 与 DTB 不同源）"
	fi
else
	bad "找不到编译出的 DTB（期望 $DTBNAME）"
fi

# ---- 6. TARGET_DIR（内核嵌入的 rootfs）------------------------------------
TARGET_DIR=$(ls -d "$BR"/build_dir/target-*/root-qualcommbe 2>/dev/null | head -n1 || true)
if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
	bad "找不到 TARGET_DIR（$BR/build_dir/target-*/root-qualcommbe）"
	exit 1
fi
say "[verify] TARGET_DIR=${TARGET_DIR#$BR/}"

VFILE="$TARGET_DIR/etc/sbe-variant"
if [ -f "$VFILE" ]; then
	grep -qx "variant=$VARIANT" "$VFILE" \
		&& ok "rootfs 的 /etc/sbe-variant 标着 variant=$VARIANT" \
		|| bad "rootfs 的 /etc/sbe-variant 不是 variant=$VARIANT（overlay 变体没叠上）"
else
	bad "rootfs 缺少 /etc/sbe-variant（变体 overlay 没进镜像）"
fi

if [ -f "$TARGET_DIR/etc/nss.conf" ]; then
	grep -qx 'tier=off' "$TARGET_DIR/etc/nss.conf" \
		&& ok "rootfs 的 /etc/nss.conf tier=off" \
		|| bad "rootfs 的 /etc/nss.conf 不是 tier=off（NSS 会在启动时被装载/刷噪声）"
	grep -qx 'fallback=off' "$TARGET_DIR/etc/nss.conf" \
		&& ok "rootfs 的 /etc/nss.conf fallback=off" \
		|| bad "rootfs 的 /etc/nss.conf 不是 fallback=off"
else
	bad "rootfs 缺少 /etc/nss.conf"
fi

if [ "$VARIANT" = diag ]; then
	if [ -x "$TARGET_DIR/usr/sbin/sbe-diag-beacon" ]; then
		ok "rootfs 有可执行的信标 /usr/sbin/sbe-diag-beacon"
	else
		bad "rootfs 缺少可执行的 /usr/sbin/sbe-diag-beacon"
	fi
	if [ -L "$TARGET_DIR/etc/rc.d/S99sbe-diag-beacon" ]; then
		ok "rootfs 有 rc.d/S99sbe-diag-beacon 链接"
	else
		bad "rootfs 缺少 rc.d/S99sbe-diag-beacon（信标不会启动）"
	fi
fi

AK="$TARGET_DIR/etc/dropbear/authorized_keys"
if [ -f "$AK" ]; then
	perm=$(stat -c %a "$AK")
	[ "$perm" = 600 ] && ok "dropbear authorized_keys 存在，权限 600" \
		|| bad "dropbear authorized_keys 权限 $perm（期望 600）"
	grep -q '^ssh-ed25519 ' "$AK" \
		&& ok "authorized_keys 含 ed25519 公钥" \
		|| bad "authorized_keys 没有 ssh-ed25519 条目（SSH 进不去）"
	if grep -qi 'BEGIN .*PRIVATE KEY' "$AK"; then
		bad "authorized_keys 里出现私钥标记：立即移除"
	fi
else
	bad "rootfs 缺少 /etc/dropbear/authorized_keys"
fi

BANNER="$TARGET_DIR/etc/banner"
if [ -f "$BANNER" ]; then
	if grep -Eq '%[VCRD]|VERXXXX|WRTVERSIONINFO' "$BANNER"; then
		bad "rootfs /etc/banner 仍含未替换的占位符"
	else
		ok "rootfs /etc/banner 无占位符：$(grep -m1 '^ Version:' "$BANNER" | sed 's/^ *//')"
	fi
else
	bad "rootfs 缺少 /etc/banner"
fi

# ---- 7. QSDK NSS/SSDK 组件：diag 必须有，mainline 必须没有 ------------------
NSS_KMODS='kmod-qca-ssdk-nohnat kmod-qca-nss-dp kmod-qca-nss-ppe'
DB=""
if [ -f "$TARGET_DIR/lib/apk/db/installed" ]; then
	DB=$TARGET_DIR/lib/apk/db/installed
	dblist() { sed -n 's/^P://p' "$DB"; }
elif [ -f "$TARGET_DIR/usr/lib/opkg/status" ]; then
	DB=$TARGET_DIR/usr/lib/opkg/status
	dblist() { sed -n 's/^Package: //p' "$DB"; }
fi
if [ -n "$DB" ]; then
	names=$(dblist)
	has_pkg() { printf '%s\n' "$names" | grep -qxF "$1"; }
	for p in $NSS_KMODS; do
		if [ "$VARIANT" = diag ]; then
			has_pkg "$p" && ok "rootfs 已装 $p（QSDK NSS/SSDK 保留）" \
				|| bad "rootfs 缺少 $p：D 变体必须保留 QSDK NSS/SSDK"
		else
			has_pkg "$p" && bad "rootfs 出现 $p：M 变体不应装 QSDK NSS" \
				|| ok "rootfs 没有 $p（M 变体符合预期）"
		fi
	done
else
	bad "TARGET_DIR 里没有 apk/opkg 数据库，无法核对 NSS 组件"
fi

# ---- 8. required-packages 反查 ---------------------------------------------
LIST=$PROJ/build/required-packages-$VARIANT.txt
if [ -f "$LIST" ]; then
	say "[verify] check-packages db（$LIST）"
	if SBE_REQUIRED_LIST="$LIST" "$PROJ/scripts/ci/check-packages.sh" db "$TARGET_DIR"; then
		ok "required-packages-$VARIANT.txt db 反查通过"
	else
		bad "required-packages-$VARIANT.txt db 反查失败（见上方 FAIL 行）"
	fi
else
	bad "缺少 $LIST"
fi

say ""
if [ "$fail" -eq 0 ]; then
	echo "SUMMARY diag 校验：PASS（$VARIANT）"
else
	echo "SUMMARY diag 校验：FAIL（$VARIANT）" >&2
fi
[ "$fail" -eq 0 ]
