#!/usr/bin/env bash
# 本地构建 25.12-6.18 镜像的便利入口：单设备（askey_sbe1v1k，NSS 数据通路）
# defconfig + 构建，最后跑静态校验并打印产物哈希。
#
# 用法：scripts/local/build-image.sh [make 目标，默认 world]
#
# 前置：先运行 scripts/ci/prepare-tree.sh（SBE_CI=1）装配构建树。
# 本脚本不联网（除 make 自己的下载）、不接触设备。
#
# 2026-11-24 起本树只发布 NSS 镜像（mainline PPE 变体退役），设备选择与
# 断言在 scripts/ci/build-images.sh 里；这里只负责跑完后校验与出哈希。

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)          # <repo>/25.12-6.18
ROOT=$(CDPATH= cd -- "$PROJ/.." && pwd)
BR="$ROOT/sources/buildroot-25.12-6.18"
TARGET=${1:-world}

[ -d "$BR" ] || { echo "缺少装配树 $BR，先运行 scripts/ci/prepare-tree.sh" >&2; exit 1; }

echo "[build-image] 构建 askey_sbe1v1k（NSS 数据通路）"
"$PROJ/scripts/ci/build-images.sh" "$TARGET"

echo "[build-image] 静态校验（单镜像断言）"
"$PROJ/scripts/ci/verify-image.sh" "$ROOT"

OUT="$BR/bin/targets/qualcommbe/ipq95xx"
echo "[build-image] 产物："
( cd "$OUT" && sha256sum *askey_sbe1v1k* 2>/dev/null )
