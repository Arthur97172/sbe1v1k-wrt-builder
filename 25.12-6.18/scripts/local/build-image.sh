#!/usr/bin/env bash
# 本地构建 25.12-6.18 镜像的便利入口：先 defconfig（种子可覆盖），再 world，
# 最后跑静态校验并打印产物哈希。
#
# 用法：scripts/local/build-image.sh [make 目标，默认 world]
#
# 前置：先运行 scripts/ci/prepare-tree.sh（SBE_CI=1）装配构建树。
# 本脚本不联网（除 make 自己的下载）、不接触设备。

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)          # <repo>/25.12-6.18
ROOT=$(CDPATH= cd -- "$PROJ/.." && pwd)
BR="$ROOT/sources/buildroot-25.12-6.18"
SEED="$PROJ/build/config-seed/ipq95xx-askey-sbe1v1k.seed"
TARGET=${1:-world}
JOBS=${SBE_JOBS:-$(nproc)}

[ -d "$BR" ] || { echo "缺少装配树 $BR，先运行 scripts/ci/prepare-tree.sh" >&2; exit 1; }

echo "[build-image] 应用种子并 defconfig"
cp "$SEED" "$BR/.config"
"$PROJ/build/sbe1v1k-build.sh" defconfig

# 包集合反查：seed（=y 是否写全）与 defconfig 结果（依赖是否满足、
# 上游是否改名删包）。清单唯一来源 build/required-packages.txt。
echo "[build-image] 反查必装/必禁包"
"$PROJ/scripts/ci/check-packages.sh" seed "$SEED"
"$PROJ/scripts/ci/check-packages.sh" config "$BR/.config"

echo "[build-image] 构建 $TARGET"
"$PROJ/build/sbe1v1k-build.sh" "$TARGET" -j"$JOBS"

echo "[build-image] 静态校验"
"$PROJ/scripts/ci/verify-image.sh" "$ROOT"

OUT="$BR/bin/targets/qualcommbe/ipq95xx"
echo "[build-image] 产物："
( cd "$OUT" && sha256sum *askey_sbe1v1k* 2>/dev/null )
