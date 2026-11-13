#!/usr/bin/env bash
# 6.12 内核漂移检测——只报告，不修改任何 pin。
#
# 用法：scripts/ci/check-kernel.sh [装配树]
#
# 对比三个数字：
#   1. 本次构建实际使用的内核（装配树 target/linux/generic/kernel-6.12）；
#   2. kernel.org 上 6.12 系列的最新 longterm；
#   3. openwrt-25.12 分支头自带的 6.12 内核（要拿到它必须改 prepare-tree.sh
#      的 OPENWRT_SHA，属于人工决策）。
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
BR=$ROOT/sources/buildroot-25.12-6.12
KFILE=$BR/target/linux/generic/kernel-6.12

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN   %s\n' "$*" >&2; }

if [ ! -f "$KFILE" ]; then
	say "FAIL   找不到 $KFILE（构建树不完整）"
	exit 1
fi

cur_line=$(grep -m1 '^LINUX_VERSION-6.12' "$KFILE" || true)
cur=${cur_line##*=}
cur=${cur//[[:space:]]/}
cur=${cur#.}
cur=6.12.$cur
# 只有装配树自己是 git 仓库（CI 里 prepare-tree.sh 克隆出来的）才可信；
# 本机复用的树可能挂在别的仓库下面。
if [ "$(git -C "$BR" rev-parse --show-toplevel 2>/dev/null || true)" = \
     "$(CDPATH= cd -- "$BR" && pwd -P)" ]; then
	ow_sha=$(git -C "$BR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
else
	ow_sha=unknown
fi

say "## 6.12 内核检测（report-only，不修改任何 pin）"
say ""
say "| 项目 | 版本 | 说明 |"
say "|---|---|---|"
say "| 本次构建 | $cur | 装配树 HEAD $ow_sha |"

net_ok=1
# kernel.org 最新 longterm 6.12
korg=$(
	curl -fsS --max-time 20 https://www.kernel.org/releases.json 2>/dev/null \
		| python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = [r.get("version", "") for r in d.get("releases", [])
     if r.get("moniker") == "longterm" and r.get("version", "").startswith("6.12.")]
print(max(v, key=lambda s: [int(x) for x in s.split(".") if x.isdigit()]) if v else "")
' 2>/dev/null || true
)

# openwrt-25.12 分支头及其内核行
ow_tip=$(git ls-remote https://github.com/openwrt/openwrt.git refs/heads/openwrt-25.12 2>/dev/null \
	| awk '{print $1; exit}')
tip_kern=""
if [ -n "$ow_tip" ]; then
	tip_line=$(curl -fsS --max-time 20 \
		"https://raw.githubusercontent.com/openwrt/openwrt/$ow_tip/target/linux/generic/kernel-6.12" \
		2>/dev/null | grep -m1 '^LINUX_VERSION-6.12' || true)
	tip_kern=${tip_line##*=}
	tip_kern=${tip_kern//[[:space:]]/}
	[ -n "$tip_kern" ] && tip_kern=6.12.${tip_kern#.}
fi

if [ -n "$korg" ]; then
	say "| kernel.org longterm | $korg | 最新 6.12 稳定版 |"
else
	net_ok=0
	say "| kernel.org longterm | — | SOURCE_UNAVAILABLE |"
fi
if [ -n "$ow_tip" ]; then
	say "| openwrt-25.12 分支头 | ${ow_tip:0:12} | 分支头内核 ${tip_kern:-UNVERIFIED} |"
else
	net_ok=0
	say "| openwrt-25.12 分支头 | — | SOURCE_UNAVAILABLE |"
fi
say ""

n_patch=$(find "$PROJ/patches" -name '*.patch' 2>/dev/null | wc -l)
n_gen=$(grep -l 'target/linux/generic' "$PROJ"/patches/*.patch 2>/dev/null | wc -l)
say "项目补丁：$n_patch 个，其中 $n_gen 个触及 target/linux/generic（升级内核需要重基的规模）。"
say ""

ver_lt() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ] && [ "$1" != "$2" ]; }

if [ "$net_ok" = 0 ]; then
	say "结论：BLOCKED / SOURCE_UNAVAILABLE —— 网络读不到上游版本，本次不做判断。"
elif [ -z "$korg" ]; then
	say "结论：UNVERIFIED —— kernel.org 没有可解析的 6.12 longterm 条目。"
elif [ "$cur" = "$korg" ]; then
	say "结论：PASS —— 本次构建已是 kernel.org 最新的 6.12（$cur）。"
elif ver_lt "$cur" "$korg"; then
	if [ -n "$tip_kern" ] && [ "$tip_kern" = "$cur" ]; then
		say "结论：UNVERIFIED —— kernel.org 已到 $korg，但 openwrt-25.12 分支头仍停在 $cur；"
		say "        跟进需要等上游先升，或人工评估直接换内核 pin（不自动执行）。"
	else
		say "结论：UNVERIFIED —— 本次构建 $cur，kernel.org 最新 $korg"
		[ -n "$tip_kern" ] && say "        openwrt-25.12 分支头自带 $tip_kern；升级 OPENWRT_SHA 需人工重基 $n_gen 个补丁。"
		say "        action=report-only；auto_bump=disabled。"
	fi
else
	say "结论：UNVERIFIED —— 本次构建 $cur 比 kernel.org longterm $korg 还新（pin 超前或格式异常）。"
fi

exit 0
