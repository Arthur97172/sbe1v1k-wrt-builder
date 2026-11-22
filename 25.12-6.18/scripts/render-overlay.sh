#!/usr/bin/env bash
# 把项目里的 files/ overlay 渲染进装配树，并替换横幅里的版本占位符。
#
# 为什么需要：OpenWrt 的 files/ overlay 由 include/image.mk 的 prepare_rootfs
# 原样复制进 rootfs（$(TOPDIR)/files），**不经过** include/version.mk 的
# VERSION_SED_SCRIPT，所以 %V / %R 这类占位符不会由 make 替换，必须在构建前
# 自己渲染一次。否则固件里的 /etc/banner 会保留占位文本。
#
# 同时用整体替换的方式同步 overlay：先删掉装配树里的 files/，再从本项目复制，
# 这样源码包里残留的旧 banner 不可能泄漏进镜像，也保证 rc.d 符号链接等
# 「不是普通文件」的条目按仓库状态原样到位。
#
# 用法：
#   scripts/render-overlay.sh            # 自动定位 <root>/sources/buildroot-25.12-6.18
#   SBE_ROOT=/path SBE_BUILDROOT=/path scripts/render-overlay.sh

set -euo pipefail

LC_ALL=C
export LC_ALL

TREE_NAME=buildroot-25.12-6.18

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=${SBE_PROJECT:-$(CDPATH= cd -- "$SELF/.." && pwd)}

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
	echo "render-overlay: 在 $PROJ 之上找不到 sources/$TREE_NAME（可用 SBE_ROOT 指定）" >&2
	exit 1
}

BR=${SBE_BUILDROOT:-$ROOT/sources/$TREE_NAME}
SRC=$PROJ/files

[ -d "$BR" ] || { echo "render-overlay: 缺少装配树 $BR" >&2; exit 1; }
[ -d "$SRC" ] || { echo "render-overlay: 缺少 overlay $SRC" >&2; exit 1; }

# overlay 的根就是固件的 /，因此 banner 必须放在 files/etc/banner。
if [ -e "$SRC/banner" ]; then
	echo "render-overlay: $SRC/banner 放错位置了，应为 $SRC/etc/banner（overlay 根即 /）" >&2
	exit 1
fi

# 与 include/version.mk 相同的取值规则（这里只需要其中三项）：
cfg() {
	local v
	v=$(sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$BR/.config" 2>/dev/null | head -n1)
	printf '%s' "$v"
}

VN=$(cfg CONFIG_VERSION_NUMBER)
VD=$(cfg CONFIG_VERSION_DIST)
VC=$(cfg CONFIG_VERSION_CODE)

[ -n "$VN" ] || VN=25.12-SNAPSHOT
[ -n "$VD" ] || VD=OpenWrt

# 必须封顶，保证 getver 不会向上找到外层仓库的 git 状态。
RV=$(cd "$BR" && TOPDIR="$BR" \
	GIT_CEILING_DIRECTORIES="$ROOT/sources${GIT_CEILING_DIRECTORIES:+:$GIT_CEILING_DIRECTORIES}" \
	./scripts/getver.sh)
[ -n "$RV" ] || { echo "render-overlay: 无法确定 REVISION" >&2; exit 1; }
[ -n "$VC" ] || VC=$RV

echo "[render] VERSION_NUMBER=$VN"
echo "[render] VERSION_DIST=$VD"
echo "[render] REVISION=$RV"
echo "[render] VERSION_CODE=$VC"

echo "[render] overlay: $SRC -> $BR/files"
rm -rf "$BR/files"
mkdir -p "$BR/files"
cp -a "$SRC/." "$BR/files/"

BANNER=$BR/files/etc/banner
[ -f "$BANNER" ] || { echo "render-overlay: 缺少 $BANNER" >&2; exit 1; }

# sed 替换串转义（\ & 与分隔符）
esc() {
	printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

sed -i \
	-e "s|%V|$(esc "$VN")|g" \
	-e "s|%D|$(esc "$VD")|g" \
	-e "s|%C|$(esc "$VC")|g" \
	-e "s|%R|$(esc "$RV")|g" \
	"$BANNER"

echo "[render] banner 版本行: $(grep '^ Version:' "$BANNER" | tr -d '\r')"

# 失败要显式失败，不做静默降级
if grep -Eq '%[VCRD]|VERXXXX|WRTVERSIONINFO' "$BANNER"; then
	echo "render-overlay: banner 仍含未替换的占位符：" >&2
	grep -nE '%[VCRD]|VERXXXX|WRTVERSIONINFO' "$BANNER" >&2
	exit 1
fi
if ! grep -Fxq " Version: $VN ($RV)" "$BANNER"; then
	echo "render-overlay: banner 缺少期望的版本行： Version: $VN ($RV)" >&2
	exit 1
fi

echo "[render] 完成"
