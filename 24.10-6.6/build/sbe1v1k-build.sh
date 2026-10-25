#!/bin/sh
# SBE1V1K 构建入口
#
# 目录约定：本脚本位于 <repo>/24.10-6.6/build/，装配树位于 <repo>/sources/buildroot
# （本地与 CI 相同）。ROOT 通过向上查找 sources/buildroot 自动确定，也可用
# SBE_ROOT 显式指定。
#
# 作用：统一构建期环境事项，避免每次手工输入：
#   1. 把 build/deterministic-bin（可复现的 date 垫片）与
#      build/host-bin（GNU coreutils 符号链接）依次前置到 PATH；
#      host-bin 缺失时按 build/host-shims.txt 自动重建；
#   2. 把 files/ overlay 渲染进装配树（替换 banner 版本占位符）；
#   3. 按装配树计算并导出固定的 SOURCE_DATE_EPOCH；
#   4. 切换到装配树并透传参数给 make。
#
# 用法：
#   ./24.10-6.6/build/sbe1v1k-build.sh defconfig     # 重新生成 .config
#   ./24.10-6.6/build/sbe1v1k-build.sh menuconfig    # 交互式配置
#   ./24.10-6.6/build/sbe1v1k-build.sh -j8           # 完整编译
#
# 联网仅发生在「内核预检」这一处，且只在交互终端（stdin 与 stdout 都是终端）
# 里进行：编译前调用 scripts/check-kernel.sh，发现 CodeLinaro 有新内核时询问
# 是否升级，回答 y 则自动同步版本串并在编译前清理内核产物。CI、管道、脚本调用
# 一律跳过，SBE_KERNEL_CHECK=0 可显式关闭、=1 可强制在非交互环境里只做检查。
#
# 本脚本不接触任何设备、不写入口令。

set -e

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/.." && pwd)
HOSTBIN="$PROJ/build/host-bin"
DETBIN="$PROJ/build/deterministic-bin"
SHIMS="$PROJ/build/host-shims.txt"

if [ "$#" -eq 0 ]; then
	cat >&2 <<EOF
usage: $0 <make-target> [make-args...]

examples:
  $0 defconfig
  $0 menuconfig
  $0 -j\$(nproc)            # full build

Note: a full build (G3) must not be started without explicit approval.
EOF
	exit 2
fi

# 定位装配树：优先 SBE_ROOT，否则从本目录向上找 sources/buildroot。
if [ -n "${SBE_ROOT:-}" ]; then
	ROOT=$SBE_ROOT
else
	ROOT=
	d=$PROJ
	while [ "$d" != / ]; do
		if [ -d "$d/sources/buildroot" ]; then
			ROOT=$d
			break
		fi
		d=$(dirname "$d")
	done
fi
[ -n "$ROOT" ] || {
	echo "missing build tree: no sources/buildroot above $PROJ (set SBE_ROOT)" >&2
	exit 1
}
BUILDROOT="$ROOT/sources/buildroot"

[ -d "$BUILDROOT" ] || { echo "missing build tree: $BUILDROOT" >&2; exit 1; }
[ -d "$DETBIN" ]    || { echo "missing deterministic shim: $DETBIN" >&2; exit 1; }
[ -f "$SHIMS" ]     || { echo "missing host shim list: $SHIMS" >&2; exit 1; }

# 版本推导必须与“外层 git 仓库是否存在/是否有提交”无关。
# sources/buildroot 自身没有 .git；不封顶时 git 会向上找到工作区仓库，
# rules.mk 的 COMMITCOUNT 与内核的 git describe 就会改用提交计数（本地与 CI
# 拓扑不同，产物版本串随之不同）。天花板设在 sources/ 才生效（必须是父目录）。
export GIT_CEILING_DIRECTORIES="$ROOT/sources${GIT_CEILING_DIRECTORIES:+:$GIT_CEILING_DIRECTORIES}"

# host-bin：仓库不提交符号链接（本机指向 /usr/bin/gnu*，runner 上没有这个名字）。
# 缺失时按清单重建：优先 gnu 前缀，其次同名，都不存在则失败。
if [ ! -d "$HOSTBIN" ]; then
	echo "[build] 重建 host-bin: $HOSTBIN"
	mkdir -p "$HOSTBIN"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		if [ -x "/usr/bin/gnu$name" ]; then
			ln -sfn "/usr/bin/gnu$name" "$HOSTBIN/$name"
		elif [ -x "/usr/bin/$name" ]; then
			ln -sfn "/usr/bin/$name" "$HOSTBIN/$name"
		else
			echo "[build] 缺少宿主机工具: $name" >&2
			exit 1
		fi
	done < "$SHIMS"
fi

PATH="$DETBIN:$HOSTBIN:$PATH"
export PATH

# 渲染 files/ overlay（banner 的 %V/%R 等占位符必须在这里替换；
# OpenWrt 复制 overlay 时不经过 VERSION_SED_SCRIPT）。
"$PROJ/scripts/render-overlay.sh"

# Pin the build clock.  include/toplevel.mk recomputes the same value
# (scripts/get_source_date_epoch.sh); exporting it here additionally makes
# it visible to $(shell date) calls evaluated before that assignment and
# to every sub-make.
SOURCE_DATE_EPOCH=$(cd "$BUILDROOT" && ./scripts/get_source_date_epoch.sh)
case "$SOURCE_DATE_EPOCH" in
''|*[!0-9]*) echo "cannot determine SOURCE_DATE_EPOCH" >&2; exit 1 ;;
esac
export SOURCE_DATE_EPOCH

# 应用文件 B（第三方应用开关）。文件 B 是应用层的唯一开关源：menuconfig 里的
# 手工改动会在下一次构建被它覆盖；临时跳过用 SBE_SKIP_CUSTOM_PACKAGES=1。
# clean 类目标不需要配置，跳过以免触发整棵树的 metadata 扫描。
if [ "${SBE_SKIP_CUSTOM_PACKAGES:-0}" != 1 ]; then
	case "${1:-}" in
	clean|dirclean|distclean|config-clean|help) ;;
	*)
		if [ ! -f "$BUILDROOT/.config" ]; then
			echo "[build] 缺少 $BUILDROOT/.config；请先从 config-seed 生成再构建" >&2
			exit 1
		fi
		"$PROJ/scripts/custom-packages.sh"
		echo "[build] .config sha256: $(sha256sum "$BUILDROOT/.config" | cut -d' ' -f1)"
		if [ "${1:-}" = menuconfig ]; then
			echo "[build] 注意: menuconfig 的改动不会写回文件 B，下次构建会被重新覆盖" >&2
		fi
		;;
	esac
fi

# 内核预检：只在交互式本地构建里联网。check-kernel.sh 自己判断终端，
# 有更新时询问，答 y 则完成三处同步（树 / include/kernel-6.6 / build-fixes）。
# 退出码语义：0=最新或已升级 2=有更新但未升级 3=读不到远端（都继续构建）；
# 1=本地两处版本不一致，继续编译只会产出与真实代码错位的版本串，必须停。
if [ "${SBE_KERNEL_CHECK:-auto}" != 0 ]; then
	case "${1:-}" in
	clean|dirclean|distclean|config-clean|help|defconfig|menuconfig) ;;
	*)
		if [ "${SBE_KERNEL_CHECK:-auto}" = 1 ] || { [ -t 0 ] && [ -t 1 ]; }; then
			kver_of() {
				sed -n 's/^LINUX_VERSION-6\.6 = \.//p' \
					"$BUILDROOT/include/kernel-6.6" 2>/dev/null | head -n 1
			}
			kver_before=$(kver_of)
			krc=0
			"$PROJ/scripts/check-kernel.sh" || krc=$?
			kver_after=$(kver_of)
			case $krc in
			0|2|3) ;;
			*) echo "[build] 内核预检异常 (exit $krc)，停止构建" >&2; exit "$krc" ;;
			esac
			if [ "$kver_before" != "$kver_after" ]; then
				echo "[build] 内核 6.6.${kver_before:-?} -> 6.6.${kver_after:-?}，清理内核构建产物"
				make -C "$BUILDROOT" target/linux/clean
			fi
		fi
		;;
	esac
fi

cd "$BUILDROOT"
exec make "$@"
