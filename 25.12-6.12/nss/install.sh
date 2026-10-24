#!/usr/bin/env bash
# 把 25.12-6.12/nss/ 下的 QSDK NSS 接入件装进 25.12 装配树。
#
# 安装内容（全部是复制，不改动 sources/buildroot 厂商树）：
#   1. include/local-development.mk —— 厂商私有 include，允许包用本地源码目录；
#   2. package/feeds/nss/<pkg>      —— 本阶段需要的 NSS 包（feed 目录形态）；
#   3. qca/src/nss/{base,clients}/<pkg> —— 包 Makefile 里 LOCAL_SRC 指向的源码目录。
#
# 用法：nss/install.sh [工作区根]
#   环境变量：
#     SBE_ROOT       工作区根
#     SBE_BUILDROOT  25.12 装配树
#     SBE_NSS_SRC    厂商源码树根（默认 <工作区>/sources/buildroot）
#     SBE_NSS_BASE   直接指定含 qca-ssdk/、qca-nss-dp/ … 的目录；
#                    优先于 SBE_NSS_SRC。CI 用它指向从 Release 资产
#                    nss-src-v1 解出来的目录。

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NSS=$SELF

if [ -n "${SBE_ROOT:-}" ]; then
	ROOT=$SBE_ROOT
else
	ROOT=${1:-}
	if [ -z "$ROOT" ]; then
		d=$NSS
		while [ "$d" != / ]; do
			if [ -d "$d/sources/buildroot-25.12-6.12" ]; then ROOT=$d; break; fi
			d=$(dirname "$d")
		done
	fi
fi
[ -n "$ROOT" ] || { echo "找不到工作区根（含 sources/buildroot-25.12-6.12）" >&2; exit 1; }

BR=${SBE_BUILDROOT:-$ROOT/sources/buildroot-25.12-6.12}
SRC=${SBE_NSS_SRC:-$ROOT/sources/buildroot}
BASE=${SBE_NSS_BASE:-$SRC/qca/src/nss/base}
# 本地构建时 base/ 与 clients/ 是两棵独立目录；CI 用的是打平的 nss-src 包，
# 只有一个目录，此时 BASE2 指向不存在的路径即可。
BASE2=${SBE_NSS_BASE2:-$SRC/qca/src/nss/clients}
[ -d "$BR" ] || { echo "缺少装配树：$BR" >&2; exit 1; }
[ -d "$BASE" ] || { echo "缺少 NSS 源码目录：$BASE" >&2; exit 1; }

say() { printf '[nss] %s\n' "$*"; }

say "安装 include/local-development.mk"
cp -a "$NSS/include/local-development.mk" "$BR/include/local-development.mk"

say "安装 NSS 包到 package/feeds/nss/"
mkdir -p "$BR/package/feeds/nss"
for d in "$NSS"/packages/*/; do
	name=$(basename "$d")
	rm -rf "$BR/package/feeds/nss/$name"
	cp -a "$d" "$BR/package/feeds/nss/$name"
	say "  package/feeds/nss/$name"
done

say "接入 NSS 源码目录"
# 目标路径不再写死 base/：每个包的 Makefile 用 LOCAL_SRC 指明源码目录，
# 这里照抄它的相对路径（base/ 或 clients/），多个包共用同一源码目录时只复制
# 一次（ppe-vp/-ds/-rule 都指向 base/qca-nss-ppe）。
# 复制而不是软链：patches/ 下是 6.12 可移植性补丁，需要在装配树内直接改源码。
# OpenWrt 25.12 的 Build/Patch 在 local-development.mk 覆盖 Build/Prepare 后
# 不再生效，所以补丁在这里应用，结果对后续编译是可复现的。
seen=" "
for d in "$NSS"/packages/*/; do
	pkg=$(basename "$d")
	rel=$(sed -n 's/^LOCAL_SRC:=\$(TOPDIR)\/\(.*\)$/\1/p' "$d/Makefile" | head -n 1)
	if [ -z "$rel" ]; then
		say "  $pkg 没有 LOCAL_SRC，跳过源码"
		continue
	fi
	name=$(basename "$rel")
	case "$seen" in *" $name "*) continue ;; esac
	seen="$seen$name "
	src=$BASE/$name
	[ -d "$src" ] || src=$BASE2/$name
	dst=$BR/$rel
	if [ ! -d "$src" ]; then
		# qca-nss-debug 的 LOCAL_SRC 指向 qca-nss-ppe/nss_debug，
		# 没有同名源码目录，随 qca-nss-ppe 一起复制即可。
		say "  $rel (无独立源码目录，跳过)"
		continue
	fi
	mkdir -p "$(dirname "$dst")"
	rm -rf "$dst"
	cp -a "$src" "$dst"
	say "  $rel"
	for p in "$NSS"/patches/"$name"/*.patch; do
		[ -f "$p" ] || continue
		patch -d "$dst" -p1 --forward --batch < "$p" >/dev/null \
			|| { echo "补丁应用失败：$p" >&2; exit 1; }
		say "    patch $(basename "$p")"
	done
done

say "完成。编译示例：build/sbe1v1k-build.sh package/qca-ssdk/compile V=s -j1"
