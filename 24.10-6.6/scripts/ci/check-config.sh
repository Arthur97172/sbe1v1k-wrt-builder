#!/usr/bin/env bash
# .config 等价门禁：装配树的 .config 经 `make defconfig` 归一化后，必须与
# build/config-frozen/.config 完全相同。
#
# 为什么需要：冻结的 .config 决定镜像里有哪些包，是源码树的一部分；但它是
# 由 make defconfig 反复求解出来的，行序与“依赖未满足时被丢弃的符号”都会随
# 树内容变化。门禁只比较有意义的行（CONFIG_x=y 与 # CONFIG_x is not set），
# 排序后逐行 diff；任何差异都说明装配出的树与审计树“包集合”不同，必须停下来
# 查明，而不是让构建默默产出一个不一样的镜像。
#
# 前置条件（与 CI 顺序一致）：源码树已解包、文件 overlay 已渲染
# （scripts/render-overlay.sh）、feeds 软链已就位；源码包内的 .config 必须与
# 冻结文件逐字节相同（装配时写入的就是这一份，不相等说明包与配方不同步）。
# 本地对装配 stage 跑时同样要先渲染 overlay，否则 files/ 里的配置片段缺失会
# 造成假差异。
#
# 用法：scripts/ci/check-config.sh [工作区根目录]
# 退出码：0 PASS、4 ASSERTION_FAILED。

set -Eeuo pipefail
LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)
ROOT=${1:-$(CDPATH= cd -- "$PROJ/.." && pwd)}
BR="$ROOT/sources/buildroot"
FROZEN="$PROJ/build/config-frozen/.config"

die() { printf 'FAIL  %s\n' "$*" >&2; exit 4; }
say() { printf '%s\n' "$*" >&2; }

[ -d "$BR" ] || die "缺少 $BR"
[ -f "$FROZEN" ] || die "缺少 $FROZEN"
[ -f "$BR/.config" ] || die "缺少 $BR/.config"

# ---------------------------------------------------------------- 行归一化
# 只保留两种有意义的行；排序抹掉 defconfig 的重排。其余（注释、空行、时间戳）
# 不参与比较。
norm() {
	grep -E '^(CONFIG_[A-Za-z0-9_]+=|# CONFIG_[A-Za-z0-9_]+ is not set)' "$1" \
		| LC_ALL=C sort
}

WANT=$(mktemp); GOT=$(mktemp); DIFF=$(mktemp); BAK=$(mktemp)
trap 'rm -f "$WANT" "$GOT" "$DIFF" "$BAK"' EXIT
cp -p "$BR/.config" "$BAK"
# 源码包里的 .config 必须逐字节等于冻结文件——装配时就是从后者写进去的。
# 不相等说明包与配方不同步（旧 sources-vN），此时归一化 diff 也有可能相等，
# 但后续构建用的就不是这一份配置了，所以要在跑 defconfig 之前就停下。
want_sha=$(sha256sum "$FROZEN" | cut -d' ' -f1)
have_sha=$(sha256sum "$BAK" | cut -d' ' -f1)
[ "$want_sha" = "$have_sha" ] \
	|| die "源码包内的 .config 与 build/config-frozen/.config 不一致（包与配方不同步，需重发 sources-vN）"
norm "$FROZEN" > "$WANT"

# ---------------------------------------------------------------- 冻结值断言
# 这几条与 build/config-frozen/.config 一一对应；改目标定义必须同步改这里。
grep -qx 'CONFIG_TARGET_BOARD="ipq95xx"' "$FROZEN" || die "冻结配置的目标板不是 ipq95xx"
grep -qx 'CONFIG_TARGET_SUBTARGET="generic"' "$FROZEN" || die "冻结配置的子目标不是 generic"
grep -qx 'CONFIG_TARGET_PROFILE="DEVICE_spectrum_sbe1v1k"' "$FROZEN" \
	|| die "冻结配置的 profile 不是 DEVICE_spectrum_sbe1v1k"
nfeed=$(grep -cE '^CONFIG_FEED_[A-Za-z0-9_]+=y$' "$FROZEN" || true)
[ "$nfeed" = 8 ] || die "冻结配置应有 8 个 CONFIG_FEED_*=y，实际 $nfeed"
if grep -qE '^CONFIG_PACKAGE_uboot-2025' "$FROZEN"; then
	die "冻结配置仍选中 uboot-2025（target.mk 已剪裁）"
fi

# ---------------------------------------------------------------- defconfig
say "[check-config] make defconfig（$BR）"
( cd "$BR" && make defconfig ) >"$ROOT/check-config.log" 2>&1 \
	|| { tail -n 40 "$ROOT/check-config.log" >&2; cp -p "$BAK" "$BR/.config"; die "make defconfig 失败"; }
norm "$BR/.config" > "$GOT"

if ! diff -u "$WANT" "$GOT" > "$DIFF"; then
	cp -p "$BAK" "$BR/.config"
	n=$(grep -cE '^[-+][^-+]' "$DIFF" || true)
	say "FAIL  .config 与冻结版本不等价（$n 行差异）"
	head -n 80 "$DIFF" >&2
	cp -f "$DIFF" "$ROOT/config-diff.txt"
	die "CONFIG_MISMATCH（完整 diff：$ROOT/config-diff.txt）"
fi

# defconfig 会重写 .config（行序、注释）；用冻结文件覆盖回去，保证后续构建
# 用的就是刚被门禁验证过的那一份（它与 BAK 逐字节相同，前面已经断言过）。
cp -p "$FROZEN" "$BR/.config"
got_sha=$(sha256sum "$BR/.config" | cut -d' ' -f1)
[ "$want_sha" = "$got_sha" ] || die "恢复 .config 失败：$BR/.config"

say "[check-config] PASS  lines=$(wc -l < "$WANT")  sha256=$want_sha  feeds=$nfeed"
