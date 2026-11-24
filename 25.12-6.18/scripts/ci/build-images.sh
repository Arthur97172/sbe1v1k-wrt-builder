#!/usr/bin/env bash
# 构建 25.12-6.18 的镜像。
#
# 2026-11-24 起本树只保留一个设备：上游的 askey_sbe1v1k，其数据通路由
# 补丁 0032 原地固定为 QSDK NSS（DEVICE_DTS ipq9570-sbe1v1k-nss）。原先
# 并列的 askey_sbe1v1k-nss 兜底/对照变体已退役，所以不再需要“按设备跑
# 两遍”，一次 world 即可；镜像名同样不带 -nss 后缀。
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

DEV=askey_sbe1v1k
SYM="CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_$DEV"

[ -d "$BR" ] || { echo "缺少装配树 $BR，先运行 scripts/ci/prepare-tree.sh" >&2; exit 1; }
[ -f "$SEED" ] || { echo "缺少种子 $SEED" >&2; exit 1; }

echo "[build-images] ==== $DEV（$TARGET）===="

# 每个包的配置戳都依赖 .config 的 mtime：内容没变就别动文件，否则整棵树
# 会重新 configure+install 一遍（几十分钟）。种子是手写的，和 defconfig
# 展开后的 .config 文本不同，所以先写种子、defconfig 之后再比对内容，
# 结果与原来一致时把 mtime 恢复回去。
had_config=0
tmpconf=$(mktemp)
saved=$(mktemp)
trap 'rm -f "$tmpconf" "$saved"' EXIT
if [ -f "$BR/.config" ]; then
	cp -p "$BR/.config" "$saved"
	had_config=1
fi
cp "$SEED" "$tmpconf"
if ! cmp -s "$tmpconf" "$BR/.config" 2>/dev/null; then
	cp "$tmpconf" "$BR/.config"
fi
"$PROJ/build/sbe1v1k-build.sh" defconfig
if [ "$had_config" -eq 1 ] && cmp -s "$saved" "$BR/.config"; then
	touch -r "$saved" "$BR/.config"
fi

# defconfig 会解析依赖闭包；被 choice 拒绝的行会以 warning 出现，这里把
# 选中状态核一遍，避免设备名静默没生效。
active=$(sed -n 's/^\(CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_[^=]*\)=y/\1/p' "$BR/.config")
if [ "$active" != "$SYM" ]; then
	echo "[build-images] 设备选择没有生效：期望 $SYM，实际 ${active:-<空>}" >&2
	exit 1
fi
# 已退役的变体若因补丁回归再次出现，发布资产就会多出一套，直接判失败。
if grep -q '^CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_askey_sbe1v1k-nss=y' "$BR/.config"; then
	echo "[build-images] 已退役的 askey_sbe1v1k-nss 设备仍被选中（单设备构建被破坏）" >&2
	exit 1
fi

echo "[build-images] 反查必装/必禁包"
"$PROJ/scripts/ci/check-packages.sh" seed "$SEED"
"$PROJ/scripts/ci/check-packages.sh" config "$BR/.config"

"$PROJ/build/sbe1v1k-build.sh" "$TARGET" -j"$JOBS"

echo "[build-images] 完成。产物："
ls -1 "$BR/bin/targets/qualcommbe/ipq95xx/" | grep 'askey_sbe1v1k' | sed 's/^/  /'
