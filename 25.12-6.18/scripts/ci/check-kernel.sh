#!/usr/bin/env bash
# 6.18 内核漂移检测——只报告，不修改任何 pin。
#
# 用法：scripts/ci/check-kernel.sh [工作区]
#
# 对比三个数字：
#   1. 本次构建实际使用的内核（装配树 target/linux/generic/kernel-6.18）；
#   2. kernel.org 上 6.18 系列的最新版本（longterm 或 stable）；
#   3. openwrt/openwrt main 分支头自带的 6.18 内核（要拿到它必须改
#      prepare-tree.sh 的 OPENWRT_SHA，属于人工决策）。
#
# 输出同时写入 stdout（workflow tee 到 kernel-report.txt）；网络不可用时
# 记 SOURCE_UNAVAILABLE，仍然 exit 0——检测失败不应让整次构建失败。
# 唯一非零退出：本地内核文件读不到（构建树本身不完整）。

set -euo pipefail
LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)
ROOT=$(CDPATH= cd -- "${1:-$PROJ/..}" && pwd)
BR=$ROOT/sources/buildroot-25.12-6.18
KFILE=$BR/target/linux/generic/kernel-6.18

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN   %s\n' "$*" >&2; }

if [ ! -f "$KFILE" ]; then
	say "FAIL   找不到 $KFILE（构建树不完整）"
	exit 1
fi

cur_line=$(grep -m1 '^LINUX_VERSION-6.18' "$KFILE" || true)
cur=${cur_line##*=}
cur=${cur//[[:space:]]/}
cur=${cur#.}
cur=6.18.$cur
# 只有装配树自己是 git 仓库（CI 里 prepare-tree.sh 克隆出来的）才可信；
# 本机复用的树可能挂在别的仓库下面。
if [ "$(git -C "$BR" rev-parse --show-toplevel 2>/dev/null || true)" = \
     "$(CDPATH= cd -- "$BR" && pwd -P)" ]; then
	ow_sha=$(git -C "$BR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
else
	ow_sha=unknown
fi
# 6.18 是 main 分支上的 KERNEL_PATCHVER，若上游把 main 切走，本次检测
# 的对比对象就变了，报告里要写出来。
patchver=$(sed -n 's/^KERNEL_PATCHVER[[:space:]]*:=[[:space:]]*//p' \
	"$BR/target/linux/qualcommbe/Makefile" 2>/dev/null | head -n1)

say "## 6.18 内核检测（report-only，不修改任何 pin）"
say ""
say "| 项目 | 版本 | 说明 |"
say "|---|---|---|"
say "| 本次构建 | $cur | 装配树 HEAD $ow_sha（KERNEL_PATCHVER=$patchver） |"

net_ok=1
# kernel.org 最新的 6.18 系列（longterm 或 stable，取最大者）
korg=$(
	curl -fsS --max-time 20 https://www.kernel.org/releases.json 2>/dev/null \
		| python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = [r.get("version", "") for r in d.get("releases", [])
     if r.get("moniker") in ("longterm", "stable")
     and r.get("version", "").startswith("6.18.")]
print(max(v, key=lambda s: [int(x) for x in s.split(".") if x.isdigit()]) if v else "")
' 2>/dev/null || true
)

# openwrt/openwrt main 分支头及其 6.18 内核行
ow_tip=$(git ls-remote https://github.com/openwrt/openwrt.git refs/heads/main 2>/dev/null \
	| awk '{print $1; exit}')
tip_kern=""
if [ -n "$ow_tip" ]; then
	tip_line=$(curl -fsS --max-time 20 \
		"https://raw.githubusercontent.com/openwrt/openwrt/$ow_tip/target/linux/generic/kernel-6.18" \
		2>/dev/null | grep -m1 '^LINUX_VERSION-6.18' || true)
	tip_kern=${tip_line##*=}
	tip_kern=${tip_kern//[[:space:]]/}
	[ -n "$tip_kern" ] && tip_kern=6.18.${tip_kern#.}
fi

if [ -n "$korg" ]; then
	say "| kernel.org 6.18 | $korg | 最新 6.18 发布 |"
else
	net_ok=0
	say "| kernel.org 6.18 | — | SOURCE_UNAVAILABLE |"
fi
if [ -n "$ow_tip" ]; then
	say "| openwrt main 分支头 | ${ow_tip:0:12} | 分支头内核 ${tip_kern:-UNVERIFIED} |"
else
	net_ok=0
	say "| openwrt main 分支头 | — | SOURCE_UNAVAILABLE |"
fi
say ""

n_patch=$(find "$PROJ/patches" -name '*.patch' 2>/dev/null | wc -l)
# 没有命中时 grep 退出 1，set -e + pipefail 会直接退出，这里显式吞掉。
n_gen=$( { grep -l 'target/linux/generic' "$PROJ"/patches/*.patch 2>/dev/null || true; } | wc -l)
say "项目补丁：$n_patch 个，其中 $n_gen 个触及 target/linux/generic（升级内核需要重基的规模）。"
say ""

ver_lt() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ] && [ "$1" != "$2" ]; }

if [ "$net_ok" = 0 ]; then
	say "结论：BLOCKED / SOURCE_UNAVAILABLE —— 网络读不到上游版本，本次不做判断。"
elif [ -z "$korg" ]; then
	say "结论：UNVERIFIED —— kernel.org 没有可解析的 6.18 条目（main 可能已切到更新内核）。"
elif [ "$cur" = "$korg" ]; then
	say "结论：PASS —— 本次构建已是 kernel.org 最新的 6.18（$cur）。"
elif ver_lt "$cur" "$korg"; then
	if [ -n "$tip_kern" ] && [ "$tip_kern" = "$cur" ]; then
		say "结论：UNVERIFIED —— kernel.org 已到 $korg，但 openwrt main 分支头仍停在 $cur；"
		say "        跟进需要等上游先升，或人工评估直接换内核 pin（不自动执行）。"
	else
		say "结论：UNVERIFIED —— 本次构建 $cur，kernel.org 最新 $korg"
		[ -n "$tip_kern" ] && say "        openwrt main 分支头自带 $tip_kern；升级 OPENWRT_SHA 需人工重基 $n_gen 个补丁。"
		say "        action=report-only；auto_bump=disabled。"
	fi
else
	say "结论：UNVERIFIED —— 本次构建 $cur 比 kernel.org 6.18 $korg 还新（pin 超前或格式异常）。"
fi

exit 0
