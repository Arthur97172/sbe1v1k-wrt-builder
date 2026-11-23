#!/usr/bin/env bash
# 本地构建 25.12-6.18 镜像的便利入口：两个设备（NSS 与 mainline）各跑一遍
# defconfig + 构建，最后跑静态校验并打印产物哈希。
#
# 用法：scripts/local/build-image.sh [make 目标，默认 world]
#
# 前置：先运行 scripts/ci/prepare-tree.sh（SBE_CI=1）装配构建树。
# 本脚本不联网（除 make 自己的下载）、不接触设备。
#
# 设备选择是 kconfig choice，一次构建只出一个设备的镜像，所以真正的两遍
# 流程在 scripts/ci/build-images.sh 里；这里只负责跑完后校验与出哈希。

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)          # <repo>/25.12-6.18
ROOT=$(CDPATH= cd -- "$PROJ/.." && pwd)
BR="$ROOT/sources/buildroot-25.12-6.18"
TARGET=${1:-world}

[ -d "$BR" ] || { echo "缺少装配树 $BR，先运行 scripts/ci/prepare-tree.sh" >&2; exit 1; }

echo "[build-image] 顺序构建两个设备（NSS、mainline）"
"$PROJ/scripts/ci/build-images.sh" "$TARGET"

echo "[build-image] 静态校验（两个镜像各自断言）"
"$PROJ/scripts/ci/verify-image.sh" "$ROOT"

OUT="$BR/bin/targets/qualcommbe/ipq95xx"
echo "[build-image] 产物："
( cd "$OUT" && sha256sum *askey_sbe1v1k* 2>/dev/null )
