#!/bin/sh
# SBE1V1K 25.12-6.18 构建入口
#
# 装配树位于 <repo>/sources/buildroot-25.12-6.18（本地与 CI 相同）。ROOT 通过
# 向上查找该目录自动确定，也可用 SBE_ROOT 显式指定。
#
# 与 25.12-6.12 的 build/sbe1v1k-build.sh 的差别：没有确定性垫片
# （deterministic-bin/host-bin）。files/ overlay 的渲染与 6.12 相同——先跑
# scripts/render-overlay.sh（替换 banner 的 %V/%R 并整体同步 overlay），再透传
# make。可复现性目前只保证 SOURCE_DATE_EPOCH 固定。
#
# 用法：
#   ./25.12-6.18/build/sbe1v1k-build.sh defconfig    # 生成 .config
#   ./25.12-6.18/build/sbe1v1k-build.sh menuconfig   # 交互式配置
#   ./25.12-6.18/build/sbe1v1k-build.sh -j8          # 完整编译
#
# 本脚本不联网、不接触任何设备、不写入口令。

set -e

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/.." && pwd)

if [ "$#" -eq 0 ]; then
	cat >&2 <<EOF
usage: $0 <make-target> [make-args...]

examples:
  $0 defconfig
  $0 menuconfig
  $0 -j\$(nproc)            # full build
EOF
	exit 2
fi

# 定位装配树：优先 SBE_ROOT，否则从本目录向上找 sources/buildroot-25.12-6.18。
TREE_NAME=buildroot-25.12-6.18
if [ -n "${SBE_ROOT:-}" ]; then
	ROOT=$SBE_ROOT
else
	ROOT=
	d=$PROJ
	while [ "$d" != / ]; do
		if [ -d "$d/sources/$TREE_NAME" ]; then
			ROOT=$d
			break
		fi
		d=$(dirname "$d")
	done
fi
[ -n "$ROOT" ] || {
	echo "missing build tree: no sources/$TREE_NAME above $PROJ (set SBE_ROOT)" >&2
	exit 1
}
BUILDROOT="$ROOT/sources/$TREE_NAME"
[ -d "$BUILDROOT" ] || { echo "missing build tree: $BUILDROOT" >&2; exit 1; }

# 版本推导必须与“外层 git 仓库是否存在/是否有提交”无关：sources/buildroot
# 自身没有 .git，不封顶时 git 会向上找到工作区仓库。天花板设在 sources/。
export GIT_CEILING_DIRECTORIES="$ROOT/sources${GIT_CEILING_DIRECTORIES:+:$GIT_CEILING_DIRECTORIES}"

# Pin the build clock（与 25.12-6.12 相同：脚本读 version.date）。
SOURCE_DATE_EPOCH=$(cd "$BUILDROOT" && ./scripts/get_source_date_epoch.sh)
case "$SOURCE_DATE_EPOCH" in
''|*[!0-9]*) echo "cannot determine SOURCE_DATE_EPOCH" >&2; exit 1 ;;
esac
export SOURCE_DATE_EPOCH

# OpenWrt 的 files/ overlay 不经过 include/version.mk 的 VERSION_SED_SCRIPT，
# banner 的 %V/%R 必须在这里先渲染；同时整体同步 overlay（含 rc.d 符号链接）。
SBE_ROOT="$ROOT" SBE_BUILDROOT="$BUILDROOT" \
	"$PROJ/scripts/render-overlay.sh"

cd "$BUILDROOT"
exec make "$@"
