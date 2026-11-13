#!/usr/bin/env bash
# 按 build/required-packages.txt 反查包选择：seed、包索引、defconfig 结果、镜像。
#
# 用法：
#   scripts/ci/check-packages.sh seed   <seed 文件>
#   scripts/ci/check-packages.sh index  <装配树>        （读 tmp/.packageinfo）
#   scripts/ci/check-packages.sh config <.config 文件>
#   scripts/ci/check-packages.sh db     <rootfs 目录>   （apk 或 opkg 数据库）
#
# required-packages.txt 语法：name 必装、?name 可选（缺失只告警）、!name 必禁。
# 无法识别的包名（上游改名或删包）一律以 FAIL 指名，绝不静默跳过。
# 状态词：PASS / FAIL / WARN / UNVERIFIED；任一 FAIL → exit 1。

set -euo pipefail
LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)
LIST=$PROJ/build/required-packages.txt
[ -f "$LIST" ] || { echo "缺少 $LIST" >&2; exit 2; }

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

MODE=${1:-}
ARG=${2:-}
case "$MODE" in
seed|index|config|db) ;;
-h|--help|"") usage; exit 0 ;;
*) echo "未知模式：$MODE" >&2; usage >&2; exit 2 ;;
esac
[ -n "$ARG" ] || { echo "缺少参数" >&2; exit 2; }

req=() opt=() forb=()
while IFS= read -r line; do
	line=${line%%#*}
	line=${line//[[:space:]]/}
	[ -n "$line" ] || continue
	case "$line" in
	'!'*)			forb+=("${line#!}") ;;
	'?'*)			opt+=("${line#?}") ;;
	*)			req+=("$line") ;;
	esac
done < "$LIST"

fail=0
pass=0
warn=0

ok()   { printf 'PASS   %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf 'FAIL   %s\n' "$*"; fail=$((fail + 1)); }
note() { printf 'WARN   %s\n' "$*"; warn=$((warn + 1)); }

# has_y <file> <pkg>：.config / seed 里是否为 =y
has_y()    { grep -qxF "CONFIG_PACKAGE_$2=y" "$1"; }
has_unset(){ grep -qxF "# CONFIG_PACKAGE_$2 is not set" "$1"; }

case "$MODE" in
seed)
	[ -f "$ARG" ] || { echo "找不到 seed：$ARG" >&2; exit 2; }
	for p in "${req[@]}"; do
		if has_y "$ARG" "$p"; then ok "seed $p=y"; else bad "seed 缺少 CONFIG_PACKAGE_$p=y"; fi
	done
	for p in "${opt[@]}"; do
		has_y "$ARG" "$p" || note "seed 未显式选择可选包 $p"
	done
	for p in "${forb[@]}"; do
		if has_y "$ARG" "$p"; then bad "seed 选择了禁用包 $p"; else ok "seed 未选择 $p"; fi
	done
	;;
index)
	BR=$ARG
	IDX=$BR/tmp/.packageinfo
	[ -f "$IDX" ] || { echo "找不到 $IDX：先跑 make prepare-tmpinfo" >&2; exit 2; }
	# 有些自维护应用既手写 Package/<name>，又 include luci.mk（后者无条件再
	# define 一次），于是同一个包在 .packageinfo 里出现两次、内容完全相同。
	# 按 Version/Depends/Provides 去重后计数，只有内容不同的重名才算冲突。
	count() {
		awk -v p="$1" '
			/^Package: / { if (name == p && key != "") print key
			               name=$2; key=""; next }
			name == p && /^(Version|Depends|Provides):/ { key = key $0 "|" }
			END { if (name == p && key != "") print key }' "$IDX" \
			| sort -u | wc -l
	}
	for p in "${req[@]}"; do
		n=$(count "$p")
		case "$n" in
		1) ok "索引 $p" ;;
		0) bad "索引里没有 $p（上游改名/删包，或插件没装进来）" ;;
		*) bad "索引里 $p 有 $n 份不同的定义（重复包，扫描会互相覆盖）" ;;
		esac
	done
	for p in "${opt[@]}"; do
		[ "$(count "$p")" -ge 1 ] || note "索引里没有可选包 $p（上游可能删了中文包）"
	done
	# 禁用包只要求“不被选中/不进镜像”，它们在官方 feed 里有源码是正常的。
	;;
config)
	[ -f "$ARG" ] || { echo "找不到 .config：$ARG" >&2; exit 2; }
	for p in "${req[@]}"; do
		if has_y "$ARG" "$p"; then
			ok "config $p=y"
		elif has_unset "$ARG" "$p"; then
			bad "config $p 被 defconfig 关掉（is not set）"
		elif grep -q "^CONFIG_PACKAGE_$p=" "$ARG"; then
			bad "config $p 不是 =y（$(grep -m1 "^CONFIG_PACKAGE_$p=" "$ARG")）"
		else
			bad "config 里没有 $p 的符号（上游改名/删包，或依赖未满足被丢弃）"
		fi
	done
	for p in "${opt[@]}"; do
		has_y "$ARG" "$p" || note "config 未选择可选包 $p"
	done
	for p in "${forb[@]}"; do
		if has_y "$ARG" "$p"; then bad "config 选择了禁用包 $p"; else ok "config 未选择 $p"; fi
	done
	;;
db)
	ROOTFS=${ARG%/}
	DB=""
	if [ -f "$ROOTFS/lib/apk/db/installed" ]; then
		DB=$ROOTFS/lib/apk/db/installed
		dblist() { sed -n 's/^P://p' "$DB"; }
		dbcase=apk
	elif [ -f "$ROOTFS/usr/lib/opkg/status" ]; then
		DB=$ROOTFS/usr/lib/opkg/status
		dblist() { sed -n 's/^Package: //p' "$DB"; }
		dbcase=opkg
	else
		echo "UNVERIFIED  找不到 apk/opkg 数据库：$ROOTFS" >&2
		exit 2
	fi
	names=$(dblist)
	has_pkg() { printf '%s\n' "$names" | grep -qxF "$1"; }
	echo "INFO   数据库 $dbcase：$DB"
	for p in "${req[@]}"; do
		if has_pkg "$p"; then ok "镜像 $p"; else bad "镜像缺少 $p"; fi
	done
	for p in "${opt[@]}"; do
		has_pkg "$p" || note "镜像缺少可选包 $p"
	done
	for p in "${forb[@]}"; do
		if has_pkg "$p"; then bad "镜像出现了禁用包 $p"; else ok "镜像没有 $p"; fi
	done
	;;
esac

printf 'SUMMARY  %s：PASS %d / WARN %d / FAIL %d\n' "$MODE" "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ]
