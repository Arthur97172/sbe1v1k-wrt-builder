#!/usr/bin/env bash
# 构建 25.12-6.18 的两个设备镜像。
#
# 背景：S3d 起同一块板有两个设备定义——askey_sbe1v1k（mainline PPE，兜底）
# 与 askey_sbe1v1k-nss（QSDK NSS 数据通路）。OpenWrt 的“Target Profile”是
# kconfig choice，一次 world 构建只能选中一个设备（两个 =y 时后者覆盖前者，
# 前者根本不进镜像图），所以这里按“先 NSS、后 mainline”顺序跑两遍。
# 两遍共用 seed 里的包选择与 files/ overlay，第二遍基本是增量的：包都编过了，
# 只重出 rootfs/内核 FIT 与该设备的镜像。
#
# 用法：
#   scripts/ci/build-images.sh [make 目标，默认 world]
#
# 环境：SBE_JOBS（并行数，默认 nproc）与 build/sbe1v1k-build.sh 相同，
# DOWNLOAD_MIRROR / GOPROXY 等 make 变量原样透传。

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)          # <repo>/25.12-6.18
ROOT=$(CDPATH= cd -- "$PROJ/.." && pwd)
BR="$ROOT/sources/buildroot-25.12-6.18"
SEED="$PROJ/build/config-seed/ipq95xx-askey-sbe1v1k.seed"
TARGET=${1:-world}
JOBS=${SBE_JOBS:-$(nproc)}

DEV_NSS=askey_sbe1v1k-nss
DEV_MAIN=askey_sbe1v1k
SYM_NSS="CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_$DEV_NSS"
SYM_MAIN="CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_$DEV_MAIN"

[ -d "$BR" ] || { echo "缺少装配树 $BR，先运行 scripts/ci/prepare-tree.sh" >&2; exit 1; }
[ -f "$SEED" ] || { echo "缺少种子 $SEED" >&2; exit 1; }

# 以 seed 为基线，把两个设备符号调整成“只选 $1”。seed 默认选中 NSS。
config_for() {
	case "$1" in
	"$DEV_NSS")
		sed -e "s|^$SYM_NSS=.*|$SYM_NSS=y|" "$SEED"
		;;
	"$DEV_MAIN")
		sed -e "s|^$SYM_NSS=.*|# $SYM_NSS is not set|" \
		    -e "s|^# $SYM_MAIN is not set|$SYM_MAIN=y|" \
		    "$SEED"
		;;
	*) echo "未知设备 $1" >&2; exit 1 ;;
	esac
}

first=1
tmpconf=$(mktemp)
saved=$(mktemp)
trap 'rm -f "$tmpconf" "$saved"' EXIT
for dev in "$DEV_NSS" "$DEV_MAIN"; do
	echo "[build-images] ==== $dev（$TARGET）===="
	# 每个包的配置戳都依赖 .config 的 mtime：内容没变就别动文件，否则整棵树
	# 会重新 configure+install 一遍（几十分钟）。种子是手写的，和 defconfig
	# 展开后的 .config 文本不同，所以先写种子、defconfig 之后再比对内容，
	# 结果与原来一致时把 mtime 恢复回去。
	had_config=0
	if [ -f "$BR/.config" ]; then
		cp -p "$BR/.config" "$saved"
		had_config=1
	fi
	config_for "$dev" > "$tmpconf"
	if ! cmp -s "$tmpconf" "$BR/.config" 2>/dev/null; then
		cp "$tmpconf" "$BR/.config"
	fi
	# defconfig 会解析依赖闭包；被 choice 拒绝的行会以 warning 出现，
	# 这里把选中状态再核一遍，避免第二个设备名静默没生效。
	"$PROJ/build/sbe1v1k-build.sh" defconfig
	if [ "$had_config" -eq 1 ] && cmp -s "$saved" "$BR/.config"; then
		touch -r "$saved" "$BR/.config"
	fi
	active=$(sed -n "s/^\(CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_askey_sbe1v1k[^=]*\)=y/\1/p" "$BR/.config")
	if [ "$active" != "CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_$dev" ]; then
		echo "[build-images] 设备选择没有生效：期望 $dev，实际 ${active:-<空>}" >&2
		exit 1
	fi

	if [ "$first" -eq 1 ]; then
		# seed 与 defconfig 结果的包反查只做一次（两个设备的包选择相同）。
		echo "[build-images] 反查必装/必禁包"
		"$PROJ/scripts/ci/check-packages.sh" seed "$SEED"
		"$PROJ/scripts/ci/check-packages.sh" config "$BR/.config"
		first=0
	fi

	"$PROJ/build/sbe1v1k-build.sh" "$TARGET" -j"$JOBS"
done

echo "[build-images] 完成。产物："
ls -1 "$BR/bin/targets/qualcommbe/ipq95xx/" | grep 'askey_sbe1v1k' | sed 's/^/  /'
