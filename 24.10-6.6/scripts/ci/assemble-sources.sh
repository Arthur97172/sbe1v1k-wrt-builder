#!/usr/bin/env bash
# 从钉定上游 + 仓库补丁装配 sources/（24.10-6.6）。
#
# 用法：
#   scripts/ci/assemble-sources.sh --stage <目录> [--cache <目录>] [--force]
#                                  [--compare <基准.tsv>] [--no-compare]
#                                  [--print-plan]
#
#   --stage      产出目录。源码树落在 <stage>/sources/，日志 <stage>/assemble.log，
#                指纹 <stage>/fingerprint.{json,tsv}。目录已有 sources/ 时必须 --force。
#   --cache      上游 clone 的缓存（默认 <stage>/cache）。复用它可重复装配而不
#                重新下载；缓存只按 (url, commit) 命名，跨版本不会串用。
#   --compare    与基准 tsv 比对（差异须被 build/known-delta.conf 解释）。
#                默认用仓库里的 build/fingerprint/audited-24.10-6.6.tsv.zst。
#                支持 .zst（先解压）。
#   --no-compare 不比对（只生成指纹）。
#   --print-plan 只打印步骤顺序，不执行。
#
# 顺序不是随便排的，三处有硬依赖：
#   - target/linux/feeds 整仓库替换要早于 files-6.6 / patches-6.6：rsync --delete
#     会删掉替换目标里“上游没有的子目录”，反过来会把刚铺好的 files-6.6 删掉。
#   - 内核叠加层（cp files-6.6/. → linux-6.6/）必须在 files-6.6 装完之后：
#     ipq95xx/Makefile:29 在解析期就是这么拷的，源码树里已经是叠加后的状态。
#   - u-boot-2025 叠加层（bootloader/files/. → qca/src/u-boot-2025/）依赖基座先铺好，
#     且这棵树不能被剪裁：platform_utils/sysupgrade-helper 以它为源码编 mkimage。
#
# 不做：不跑 scripts/feeds update/install（会生成带宿主绝对路径的 .index/.tmp，
# 审计树也没有）；不编译；只访问 upstream-pins.conf 与 thirdparty-feeds.conf
# 里登记的 https 地址；不接触任何设备。
#
# 退出码：
#   0 PASS
#   2 SOURCE_UNAVAILABLE   某个 pin 取不到（绝不降级到分支头）
#   3 PIN_MISMATCH         checkout 后 HEAD != pin
#   4 ASSERTION_FAILED     工具/磁盘/pin 表/补丁/断言失败
#   5 FINGERPRINT_MISMATCH 与基准有未解释差异
#   6 SIZE_LIMIT           （保留给 export-sources.sh，本脚本不用）

set -Eeuo pipefail
LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)      # <repo>/24.10-6.6
REPO=$(CDPATH= cd -- "$PROJ/.." && pwd)         # 仓库根
BUILD="$PROJ/build"
PINS="$BUILD/upstream-pins.conf"
TPCONF="$BUILD/thirdparty-feeds.conf"
EPOCH=1792557977
MIN_FREE_GB=${SBE_MIN_FREE_GB:-25}

STAGE=""; CACHE=""; FORCE=0; COMPARE=""; NO_COMPARE=0; PRINT_PLAN=0

while [ $# -gt 0 ]; do
	case "$1" in
	--stage)      STAGE=${2:?--stage 需要目录}; shift 2 ;;
	--cache)      CACHE=${2:?--cache 需要目录}; shift 2 ;;
	--force)      FORCE=1; shift ;;
	--compare)    COMPARE=${2:?--compare 需要 tsv}; shift 2 ;;
	--no-compare) NO_COMPARE=1; shift ;;
	--print-plan) PRINT_PLAN=1; shift ;;
	-h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)            echo "未知参数: $1" >&2; exit 4 ;;
	esac
done

PLAN='1  预检：工具、pin 表格式、磁盘余量
2  取上游 pin：git init + fetch --depth 1 <commit> + checkout --detach，断言 HEAD
3  铺基座：rsync qsdk 镜像 → sources/buildroot（不含 .git）
4  剪裁：按 build/prune.conf 删除
5  替换钉定组件：replace/overlay 行，按路径深度从浅到深 rsync --delete
6  P-B 板级补丁：build/p-b/SERIES（镜像定义、DTS 注册、pwm）
7  目标 feed 修正：build/target-feed-fixes/SERIES（config-6.6、target.mk）
8  装配映射：build/assembly-map.conf（rtl8261n、DTS、base-files、本地包、blob、procd 0002 替换件）
9  校验 Wi-Fi blob：sha256sum -c files/FILES-SHA256
10 就地叠加层：files-6.6/. → qca/src/linux-6.6/；bootloader/files/. → qca/src/u-boot-2025/
11 构建系统补丁：build/build-fixes/SERIES（全部 tree 模式；0004/0007 空号）
12 第三方树：passwall-selected 派生、thirdparty-feeds.sh fetch
13 feeds 接线：feeds.conf + 11 条 feeds/<name> + 175 条 package/feeds 软链（依赖上一步）
14 冻结配置：.config / version / version.date + 断言
15 文档：README.md、PROVENANCE.md
16 树指纹：tree-fingerprint.sh（+ 与基准比对）'

if [ "$PRINT_PLAN" = 1 ]; then
	printf '%s\n' "$PLAN"
	exit 0
fi

[ -n "$STAGE" ] || { echo "需要 --stage <目录>（--print-plan 可看步骤）" >&2; exit 4; }
case "$STAGE" in /|"$REPO"|"$REPO"/) echo "拒绝把 stage 指向 $STAGE" >&2; exit 4 ;; esac
mkdir -p "$STAGE"
STAGE=$(CDPATH= cd -- "$STAGE" && pwd)
SRC="$STAGE/sources"
CACHE=${CACHE:-$STAGE/cache}
mkdir -p "$CACHE"
LOG="$STAGE/assemble.log"
: > "$LOG"

if [ -e "$SRC" ]; then
	if [ "$FORCE" != 1 ]; then
		echo "目标已存在：$SRC（加 --force 覆盖；缓存 $CACHE 会保留）" >&2
		exit 4
	fi
	rm -rf "$SRC"
fi

STEP_NO=0
STEP_NAME="(init)"
die() { local code=$1; shift; printf 'FAIL  %s\n' "$*" | tee -a "$LOG" >&2; exit "$code"; }
logmsg() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }
step() { STEP_NO=$((STEP_NO + 1)); STEP_NAME=$1; logmsg ""; logmsg "=== [$STEP_NO] $1"; }
on_err() {
	local rc=$?
	printf 'FAIL  step="%s" rc=%s\n' "$STEP_NAME" "$rc" | tee -a "$LOG" >&2
	printf '%s\n' '--- 最后 50 行日志 ---' >&2
	tail -n 50 "$LOG" 2>/dev/null | sed 's/^/  /' >&2 || true
	exit 4
}
trap on_err ERR

need() { command -v "$1" >/dev/null 2>&1 || die 4 "缺少工具：$1"; }
count_files() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }
relpath() {
	python3 -I -c 'import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[1]))' "$1" "$2"
}
# ---------------------------------------------------------------- pin 存取
pin_cache() {
	printf '%s/pins/%s' "$CACHE" \
		"$(printf '%s\n%s\n' "$1" "$2" | sha256sum | cut -c1-20)"
}

# fetch_pin <url> <commit> <dir>：把 dir 变成该 commit 的检出，HEAD 已断言。
fetch_pin() {
	local url=$1 commit=$2 dir=$3 head try=1 ok=0
	if [ ! -d "$dir/.git" ]; then
		mkdir -p "$(dirname -- "$dir")"
		git init -q "$dir" >>"$LOG" 2>&1 || die 4 "git init 失败：$dir"
		git -C "$dir" remote add origin "$url" >>"$LOG" 2>&1 \
			|| die 4 "git remote add 失败：$dir"
	fi
	if ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
		logmsg "  FETCH $url @ ${commit:0:12}"
		# 网络抖动（TLS/HTTP2 framing）不算“上游不可用”。重试 3 次，最后一次
		# 强制 HTTP/1.1；仍然失败才判 SOURCE_UNAVAILABLE，绝不降级到分支头。
		while [ "$try" -le 3 ]; do
			if [ "$try" = 3 ]; then
				git -c http.version=HTTP/1.1 -C "$dir" fetch --quiet --depth 1 \
					origin "$commit" >>"$LOG" 2>&1 && ok=1
			else
				git -C "$dir" fetch --quiet --depth 1 origin "$commit" \
					>>"$LOG" 2>&1 && ok=1
			fi
			[ "$ok" = 1 ] && break
			[ "$try" -lt 3 ] && logmsg "  RETRY fetch 第 $((try + 1)) 次：$url"
			try=$((try + 1))
			[ "$try" -le 3 ] && sleep 5
		done
		[ "$ok" = 1 ] || die 2 "SOURCE_UNAVAILABLE: $url @ $commit 取不到（不降级到分支头）"
	fi
	git -C "$dir" -c advice.detachedHead=false checkout -q --detach "$commit" \
		>>"$LOG" 2>&1 || die 4 "checkout 失败：$dir @ $commit"
	head=$(git -C "$dir" rev-parse HEAD)
	[ "$head" = "$commit" ] || die 3 "PIN_MISMATCH: $url 期望 $commit 实得 $head"
}

# apply_patch <patch> <dest-abs>
apply_patch() {
	local patch=$1 dest=$2
	[ -f "$patch" ] || die 4 "补丁不存在：$patch"
	patch -p1 -d "$dest" --fuzz=0 --dry-run -i "$patch" >>"$LOG" 2>&1 \
		|| die 4 "补丁 dry-run 失败：$(basename "$patch")（上下文不符，禁止 fuzz）"
	patch -p1 -d "$dest" --fuzz=0 --no-backup-if-mismatch -i "$patch" >>"$LOG" 2>&1 \
		|| die 4 "补丁应用失败：$(basename "$patch")"
	if find "$dest" -name '*.rej' -print -quit | grep -q .; then
		die 4 "发现 .rej：$(basename "$patch")"
	fi
	logmsg "  PATCH $(basename "$patch") → ${dest#"$STAGE"/sources/}"
}

# apply_series <SERIES 文件>：四列 <patch><TAB><mode><TAB><目标目录><TAB><说明>，
# 三个 SERIES 统一这一语法。目标目录一律相对 sources/。
#   tree           patch -p1 -d <目标目录>，先 dry-run
#   package-patch  补丁文件原样拷进 <目标目录>，由构建系统在拉取源码后应用
apply_series() {
	local series=$1 p mode dest rest patch
	[ -f "$series" ] || die 4 "SERIES 不存在：$series"
	while IFS=$'\t' read -r p mode dest rest; do
		[ -n "${p:-}" ] || continue
		case "$p" in \#*) continue ;; esac
		[ -n "${mode:-}" ] && [ -n "${dest:-}" ] || die 4 "SERIES 行缺列：$p"
		patch="$BUILD/$p"
		[ -f "$patch" ] || patch="$(dirname -- "$series")/$p"
		[ -f "$patch" ] || patch="$(dirname -- "$series")/patches/$p"
		[ -f "$patch" ] || die 4 "找不到补丁：$p（来自 $series）"
		case "$mode" in
		tree)
			[ -d "$SRC/$dest" ] || die 4 "补丁目标目录不存在：$dest"
			apply_patch "$patch" "$SRC/$dest"
			;;
		package-patch)
			# OpenWrt 只从 <包目录>/patches/ 取补丁；落错一级就是静默
			# 不生效（0023 首次登记时目标写成了包根）。
			case "$dest" in
			*/patches/) ;;
			*) die 4 "package-patch 目标必须是 <包目录>/patches/：$dest（$p）" ;;
			esac
			mkdir -p "$SRC/$dest"
			cp -p "$patch" "$SRC/$dest/"
			# 补丁文件与它落进的目录都是审计基线里没有的新路径，第 16 步
			# 指纹比对逐条要对上 known-delta 的规则；漏登记一条就是
			# FINGERPRINT_MISMATCH，而且以前只报“1 条未解释差异”不报路径。
			# 在这里先拦，错在哪一行一眼可见。
			for _np in "${dest%/}/$(basename "$patch")" "${dest%/}"; do
				# 按第一列精确比对：规则既可写 glob 也可写绝对路径，新路径的
				# 登记必须原文出现，否则指纹比对时对不上（fnmatch 语义另算）。
				cut -f1 "$BUILD/known-delta.conf" | grep -qxF -- "$_np" \
					|| die 4 "package-patch 新路径未在 known-delta.conf 登记：$_np（第 16 步指纹比对必然失败）"
			done
			logmsg "  PACKAGE-PATCH $(basename "$patch") → $dest/"
			;;
		*)
			die 4 "未知补丁模式：$mode（$p）"
			;;
		esac
	done < <(grep -v '^[[:space:]]*$' "$series")
}

# =============================================================== 1. 预检
step "预检：工具、pin 表、磁盘"
for t in git rsync patch python3 sha256sum tar awk sort find zstd; do need "$t"; done
[ -f "$PINS" ] || die 4 "缺少 $PINS"
[ -f "$BUILD/prune.conf" ] || die 4 "缺少 build/prune.conf"
[ -f "$BUILD/assembly-map.conf" ] || die 4 "缺少 build/assembly-map.conf"
[ -f "$BUILD/feeds.conf.in" ] || die 4 "缺少 build/feeds.conf.in"
[ -f "$BUILD/feeds-links.conf" ] || die 4 "缺少 build/feeds-links.conf"
[ -f "$BUILD/fingerprint-exclude.conf" ] || die 4 "缺少 build/fingerprint-exclude.conf"
for f in build-fixes/SERIES p-b/SERIES target-feed-fixes/SERIES luci-patches/SERIES; do
	[ -f "$BUILD/$f" ] || die 4 "缺少 $BUILD/$f"
done
[ -f "$BUILD/config-frozen/.config" ] || die 4 "缺少 config-frozen/.config"

avail_kb=$(df -Pk "$CACHE" | awk 'NR==2 {print $4}')
[ -n "$avail_kb" ] || die 4 "无法读取 $CACHE 的磁盘余量"
[ "$avail_kb" -ge $((MIN_FREE_GB * 1024 * 1024)) ] \
	|| die 4 "磁盘余量不足：需要 ${MIN_FREE_GB} GiB，实际 $((avail_kb / 1024 / 1024)) GiB"

PIN_ROWS=()
base_rows=0
while IFS=$'\t' read -r d u c m n; do
	[ -n "${d:-}" ] || continue
	case "$d" in \#*) continue ;; esac
	[[ "$c" =~ ^[0-9a-f]{40}$ ]] || die 4 "pin 的 commit 不是 40 位 SHA：$d $c"
	case "$m" in base|replace|overlay) ;; *) die 4 "pin 的 mode 非法：$d $m" ;; esac
	case "$d" in /*|*..*|*' '*) die 4 "pin 的 dest 非法：$d" ;; esac
	[ "$m" = base ] && base_rows=$((base_rows + 1))
	[[ "$u" =~ ^https:// ]] || die 4 "pin 的 url 必须是 https：$d $u"
	PIN_ROWS+=("$d|$u|$c|$m")
done < "$PINS"
[ "${#PIN_ROWS[@]}" -gt 0 ] || die 4 "pin 表为空"
[ "$base_rows" = 1 ] || die 4 "pin 表必须恰好有一个 mode=base 行（实际 $base_rows）"
logmsg "  pins=${#PIN_ROWS[@]} base=1 磁盘余量=$((avail_kb / 1024 / 1024)) GiB"

# =============================================================== 2. 取 pin
step "取上游 pin（${#PIN_ROWS[@]} 个）"
for row in "${PIN_ROWS[@]}"; do
	IFS='|' read -r d u c m <<< "$row"
	fetch_pin "$u" "$c" "$(pin_cache "$u" "$c")"
done
logmsg "  PIN_OK ${#PIN_ROWS[@]}/${#PIN_ROWS[@]}"

# =============================================================== 3. 基座
step "铺基座 → sources/buildroot"
mkdir -p "$SRC"
for row in "${PIN_ROWS[@]}"; do
	IFS='|' read -r d u c m <<< "$row"
	[ "$m" = base ] || continue
	[ "$d" = buildroot ] || die 4 "mode=base 的 dest 必须是 buildroot（现在是 $d）"
	rsync -a --exclude='/.git/' "$(pin_cache "$u" "$c")/" "$SRC/buildroot/" >>"$LOG" 2>&1
done
[ -f "$SRC/buildroot/Makefile" ] || die 4 "基座不完整：缺少 buildroot/Makefile"
logmsg "  BASE_OK entries=$(find "$SRC/buildroot" -mindepth 1 | wc -l | tr -d ' ')"

# =============================================================== 4. 剪裁
step "剪裁（build/prune.conf）"
pruned=0
while IFS=$'\t' read -r p reason; do
	[ -n "${p:-}" ] || continue
	case "$p" in \#*) continue ;; esac
	[ -e "$SRC/buildroot/$p" ] || die 4 "剪裁目标不存在：$p"
	rm -rf "${SRC:?}/buildroot/$p"
	[ ! -e "$SRC/buildroot/$p" ] || die 4 "剪裁失败：$p"
	pruned=$((pruned + 1))
	logmsg "  PRUNE $p  （$reason）"
done < "$BUILD/prune.conf"
# prune.conf 允许为空（只有注释）：默认不剪裁任何东西，见该文件的理由说明。
[ "$pruned" -gt 0 ] || logmsg "  PRUNE 无（prune.conf 只有注释）"

# =============================================================== 5. 替换
step "替换钉定组件（replace/overlay，按深度从浅到深）"
while IFS='|' read -r _ d u c m; do
	mkdir -p "$SRC/$d"
	rsync -a --delete --exclude='/.git/' "$(pin_cache "$u" "$c")/" "$SRC/$d/" >>"$LOG" 2>&1
	logmsg "  REPLACE $d  ($(count_files "$SRC/$d") files)  ${c:0:12}"
done < <(
	for row in "${PIN_ROWS[@]}"; do
		IFS='|' read -r d u c m <<< "$row"
		case "$m" in replace|overlay) ;; *) continue ;; esac
		printf '%s|%s|%s|%s|%s\n' "$(awk -v s="$d" 'BEGIN{n=gsub(/\//,"/",s); print n}')" "$d" "$u" "$c" "$m"
	done | sort -t'|' -k1,1n
)

FEEDS6="$SRC/buildroot/target/linux/feeds/files-6.6"
PATCH6="$SRC/buildroot/target/linux/feeds/patches-6.6"
[ "$(count_files "$FEEDS6")" = 504 ] || die 4 "files-6.6 上游文件数应为 504，实际 $(count_files "$FEEDS6")"
[ "$(count_files "$PATCH6")" = 1219 ] || die 4 "patches-6.6 文件数应为 1219，实际 $(count_files "$PATCH6")"

# =============================================================== 6. P-B
step "P-B 板级补丁（build/p-b/SERIES）"
apply_series "$BUILD/p-b/SERIES"
# P-B 的三条补丁都只改已有文件（镜像定义、dts Makefile、target 特性），不新增文件：
# 525 = 504 + kernel-overlay 20 + SBE DTS 1，那个数要等第 8 步映射完再断言。
[ "$(count_files "$FEEDS6")" = 504 ] || die 4 "打完 P-B 后 files-6.6 应仍为 504 个文件，实际 $(count_files "$FEEDS6")"

# =============================================================== 7. 目标 feed
step "目标 feed 修正（build/target-feed-fixes/SERIES）"
apply_series "$BUILD/target-feed-fixes/SERIES"

# =============================================================== 8. 映射
step "装配映射（build/assembly-map.conf）"
copied=0
while IFS=$'\t' read -r op src dest note; do
	[ -n "${op:-}" ] || continue
	case "$op" in \#*) continue ;; esac
	case "$op" in
	copy-tree)
		[ -d "$REPO/$src" ] || die 4 "映射源目录不存在：$src"
		mkdir -p "$SRC/$dest"
		rsync -a --exclude='/.git/' "$REPO/$src/" "$SRC/$dest/" >>"$LOG" 2>&1
		;;
	copy-file)
		[ -f "$REPO/$src" ] || die 4 "映射源文件不存在：$src"
		mkdir -p "$(dirname -- "$SRC/$dest")"
		cp -p "$REPO/$src" "$SRC/$dest"
		;;
	*)
		die 4 "未知映射操作：$op"
		;;
	esac
	copied=$((copied + 1))
done < "$BUILD/assembly-map.conf"
[ "$copied" -gt 0 ] || die 4 "assembly-map.conf 没有可执行的行"
[ "$(count_files "$FEEDS6")" = 525 ] || die 4 "映射后 files-6.6 应为 525 个文件，实际 $(count_files "$FEEDS6")"
_dts="$FEEDS6/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts"
[ -f "$_dts" ] || die 4 "DTS 缺失"
grep -q 'model = "Spectrum SBE1V1K"' "$_dts" || die 4 "DTS 的 model 不符"
grep -q 'sdhc_1' "$_dts" || die 4 "DTS 缺少 sdhc_1（eMMC）"
# DTS 的单一来源是 build/p-b/files 里那一份（1e06ae4 起带 edma ring-map/中断、
# xo 频率、删 cpu OPP；已在 v55 真机上 PASS）。known-delta 对装配树里两处副本
# 登记 changed，这里的逐字节断言就是那条白名单的可执行证明：任何一处副本与
# 源文件不一致都算装配漏项，而不是“可以接受的差异”。
_dts_src="$REPO/24.10-6.6/build/p-b/files/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts"
cmp -s "$_dts_src" "$_dts" || die 4 "files-6.6 的 SBE DTS 与 build/p-b/files 源文件不一致"
# 首启默认值包：每个 uci-defaults 都必须装配进来，且 Makefile 都要安装
# （少装一个不会报错，只会在设备上悄悄缺一项默认值，所以在这里挡）。
_dfl="$SRC/buildroot/package/sbe1v1k-defaults"
for _f in 99-ttyd-disable 99-allow-luci-wan 99-allow-ssh-wan 99-opkg-distfeeds; do
	[ -f "$_dfl/files/$_f" ] || die 4 "sbe1v1k-defaults 缺少 $_f"
	grep -q "files/$_f" "$_dfl/Makefile" || die 4 "sbe1v1k-defaults/Makefile 未安装 $_f"
done
logmsg "  SBE_DEFAULTS_OK ttyd-disable + allow-luci-wan + allow-ssh-wan + opkg-distfeeds"
logmsg "  SBE_DTS_OK 与 build/p-b/files 源文件逐字节一致"
_mmc="$SRC/buildroot/target/linux/feeds/ipq95xx/base-files/lib/upgrade/mmc.sh"
[ -f "$_mmc" ] || die 4 "mmc.sh 缺失"
# 审计树里 mmc.sh 是 744（组可执行），但 git 只记录 644/755，检出后再经
# rsync -a 复制就变成 755。指纹逐位比较权限，所以在这里按审计值恢复。
chmod 0744 "$_mmc"
[ "$(stat -c '%a' "$_mmc")" = 744 ] || die 4 "mmc.sh 权限应为 744，实际 $(stat -c '%a' "$_mmc")"
[ "$(sha256sum "$_mmc" | cut -d' ' -f1)" = \
  "44e461792b8969d655970a4cc054e4ad3a6d083828eed5578906be38139c7898" ] \
	|| die 4 "mmc.sh 内容与审计树不符"

# =============================================================== 9. blob
step "校验 Wi-Fi blob（FILES-SHA256）"
_pkg="$SRC/buildroot/package/sbe-wifi-firmware"
[ -f "$_pkg/files/FILES-SHA256" ] || die 4 "缺少 sbe-wifi-firmware/files/FILES-SHA256"
( cd "$_pkg/files" && sha256sum -c --quiet FILES-SHA256 ) >>"$LOG" 2>&1 \
	|| die 4 "Wi-Fi blob 校验失败（见日志 FILES-SHA256 行）"
logmsg "  BLOB_OK 6/6  LICENSE_REVIEW_REQUIRED（许可状态未改变）"

# =============================================================== 10. 内核叠加
step "就地叠加层（files-6.6 → linux-6.6，bootloader/files → u-boot-2025）"
KERNEL="$SRC/buildroot/qca/src/linux-6.6"
[ -d "$KERNEL" ] || die 4 "内核树缺失：$KERNEL"
cp -a "$FEEDS6/." "$KERNEL/" >>"$LOG" 2>&1 || die 4 "内核叠加失败"
[ -f "$KERNEL/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts" ] || die 4 "叠加后内核树没有 SBE DTS"
cmp -s "$_dts_src" "$KERNEL/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts" \
	|| die 4 "内核树里的 SBE DTS 与 build/p-b/files 源文件不一致"
[ -f "$KERNEL/drivers/net/phy/rtl8261n/Makefile" ] || die 4 "叠加后内核树没有 rtl8261n"
logmsg "  OVERLAY_OK $(count_files "$KERNEL") files"

# u-boot-2025 同理：qca/feeds/bootloader/u-boot-2025/Makefile 在解析期执行
#   $(shell cp -fpR -u $(TOPDIR)/qca/feeds/bootloader/files/* $(SRC_DIR))
# 把 bootloader/files 叠进 qca/src/u-boot-2025。审计树里这棵树就是叠加后的状态
# （基座 35,471 文件 + 叠加新增 381，逐字节比对：零内容差异、零覆盖、零删除），
# 而 platform_utils/sysupgrade-helper 直接拿它当源码编 mkimage/dumpimage。
# 装配时不叠，这棵树就与审计树不一致；叠的路径与基座有重合时下面会失败，
# 那意味着需要重新审计（叠加语义变了），不能默默放过。
UBOOT25="$SRC/buildroot/qca/src/u-boot-2025"
BOOTFILES="$SRC/buildroot/qca/feeds/bootloader/files"
[ -d "$UBOOT25" ] || die 4 "缺 qca/src/u-boot-2025：prune.conf 不能删它（sysupgrade-helper 的源码树）"
[ -d "$BOOTFILES" ] || die 4 "缺 qca/feeds/bootloader/files 叠加层"
_ub_before=$(count_files "$UBOOT25")
_ub_ov=$(count_files "$BOOTFILES")
cp -a "$BOOTFILES/." "$UBOOT25/" >>"$LOG" 2>&1 || die 4 "u-boot-2025 叠加失败"
_ub_after=$(count_files "$UBOOT25")
[ "$_ub_after" = "$((_ub_before + _ub_ov))" ] \
	|| die 4 "u-boot-2025 叠加后应 $_ub_before+$_ub_ov=$((_ub_before + _ub_ov)) 个文件，实际 $_ub_after（叠加层覆盖了基座里的同名文件，需重新审计）"
[ -f "$UBOOT25/tools/sysupgrade.c" ] || die 4 "叠加后 u-boot-2025 缺 tools/sysupgrade.c"
logmsg "  OVERLAY_OK u-boot-2025 $_ub_after files (+$_ub_ov)"

# =============================================================== 11. build-fixes
step "构建系统补丁（build/build-fixes/SERIES）"
apply_series "$BUILD/build-fixes/SERIES"
# procd 的并发启动补丁靠 assembly-map 整文件替换上游 0002（追加会重复打同一段）。
# 这里只确认替换确实发生了：上游原件的说明行不应再出现，重排后的内容应在。
_procd="$SRC/buildroot/openwrt-patches/package/system/procd/patches/0002-procd-Enable-maximum-runqueue.patch"
grep -q 'get_max_running_tasks' "$_procd" || die 4 "openwrt-patches 的 procd 0002 未被替换成重排版本"
grep -q '^diff --git a/rcS.c' "$_procd" || die 4 "procd 0002 不是针对 rcS.c 的补丁"
[ ! -d "$SRC/buildroot/package/system/procd/patches" ] \
	|| die 4 "package/system/procd/patches/ 不应存在（会与 openwrt-patches 的 0002 重复应用）"

# 0018 补上 sae-compat（Compatibility Mode）。补丁应用成功不等于内容正确，
# 这里逐个文件断言关键改动，并单独断言 override 赋值的先后顺序，失败即停
# ——不靠 known-delta 白名单盖差异。
_ws="$SRC/buildroot/qca/feeds/wlan-open/mac80211/wifi-scripts/files"
grep -q 'auth_type=psk-sae-compat' "$_ws/lib/netifd/netifd-wireless.sh" \
	|| die 4 "0018 未生效：netifd-wireless.sh 缺 sae-compat → auth_type 映射"
grep -q '^		psk-sae-compat)$' "$_ws/lib/netifd/hostapd.sh" \
	|| die 4 "0018 未生效：hostapd.sh 缺 psk-sae-compat 的 key_mgmt 分支"
grep -q 'rsn_override_key_mgmt\$rsn_override_key_mgmt_2' "$_ws/lib/netifd/hostapd.sh" \
	|| die 4 "0018 未生效：hostapd.sh 的 rsn_override_omit_rsnxe 未与主 override 共用"
# rsn_override_key_mgmt 必须在 override 元素发出前就赋值：hostapd_set_bss_options
# 里 case 默认值（先）与 rsn_override 块（后）顺序固定，赋值若落在后面的
# hostapd_append_wpa_key_mgmt 里就永远不会被发出。这里连同顺序一起断言。
_n1=$(grep -n 'rsn_override_key_mgmt="SAE"$' "$_ws/lib/netifd/hostapd.sh" | head -n1 | cut -d: -f1 || true)
_n2=$(grep -n 'append bss_conf "rsn_override_key_mgmt=' "$_ws/lib/netifd/hostapd.sh" | head -n1 | cut -d: -f1 || true)
[ -n "$_n1" ] && [ -n "$_n2" ] && [ "$_n1" -lt "$_n2" ] \
	|| die 4 "0018 顺序错误：psk-sae-compat 的 rsn_override_key_mgmt 赋值（行 ${_n1:-无}）必须早于 override 元素发出（行 ${_n2:-无}）"
grep -q '^	if (match(enc_lower, /\^sae-compat/, "s"))$' "$_ws/lib/wifi/mac80211.uc" \
	|| die 4 "0018 未生效：mac80211.uc 会把 sae-compat 改写成 sae"
logmsg "  SAE_COMPAT_OK wifi-scripts（netifd + hostapd + uci 迁移）"

# 0021 让 has_feature() 认识 "11be"。LuCI 的模式下拉只认 `hostapd -v11be`
# 的退出码，而这个分支必须包在 CONFIG_IEEE80211BE 里——无条件返回 1 会在
# 没开 EHT 的构建里谎报支持。分支存在且确实受 #ifdef 约束，缺一即停。
_bf="$SRC/buildroot/qca/src/network/services/hostapd/src/utils/build_features.h"
grep -A2 '^#ifdef CONFIG_IEEE80211BE$' "$_bf" | grep -q 'strcmp(feat, "11be")' \
	|| die 4 "0021 未生效：build_features.h 缺 CONFIG_IEEE80211BE 下的 11be 分支"
logmsg "  BUILD_FEATURES_11BE_OK hostapd（has_feature 报 11be）"

# 0022 去掉 mac80211.sh 里两行无条件 append：disable_iface_during_cac 与
# athnewind 只有 qcn-app-extns 解析，而镜像用 noextns 变体，hostapd 会把它们
# 当 unknown configuration item，整份配置 2 errors 后 add_iface 失败，三个
# radio 的 BSS 全部起不来（LuCI 无线页整页“已禁用”）。两行必须一条都不剩；
# 其余 QCA 专有项本来就是空值不发出，不受影响。
_ws22="$SRC/buildroot/qca/feeds/wlan-open/mac80211/wifi-scripts/files/lib/netifd/wireless/mac80211.sh"
if grep -q 'append base_cfg "disable_iface_during_cac=' "$_ws22"; then
	die 4 "0022 未生效：mac80211.sh 仍向 hostapd 配置发 disable_iface_during_cac"
fi
if grep -q 'append base_cfg "athnewind=' "$_ws22"; then
	die 4 "0022 未生效：mac80211.sh 仍向 hostapd 配置发 athnewind"
fi
logmsg "  HOSTAPD_EXTN_OPTS_OK wifi-scripts（配置不再带 noextns 不认识的扩展项）"

# 0023 把 dawn 的 neighbor_report 拷贝改成有界。补丁由构建期应用，装配阶段
# 只能验证两件事：它确实落在 dawn 包的 patches/ 目录（放错一级 OpenWrt 会
# 静默不应用），以及内容里确实是 1024 上限 + 有界拷贝，不是原补丁的残次版。
_dawn_patch="$SRC/buildroot/qca/feeds/packages/net/dawn/patches/0023-dawn-bounded-neighbor-report.patch"
[ -f "$_dawn_patch" ] || die 4 "0023 未生效：dawn/patches/ 下没有有界化补丁"
grep -q '^+#define NEIGHBOR_REPORT_LEN 1024$' "$_dawn_patch" \
	|| die 4 "0023 内容不符：NEIGHBOR_REPORT_LEN 不是 1024"
grep -q 'strncpy(entry->neighbor_report, neighborreport, NEIGHBOR_REPORT_LEN)' "$_dawn_patch" \
	|| die 4 "0023 内容不符：neighbor_report 仍是无界拷贝"
logmsg "  DAWN_NR_BOUNDED_OK dawn（NEIGHBOR_REPORT_LEN=1024，有界拷贝）"

# 0025 让 dawn 跳过 hostapd 控制目录里不是 netdev 的 socket。同样是构建期补丁，
# 装配阶段验证落点（patches/，放错一级会被静默忽略）与内容：iwinfo 侧必须只剩
# 一处 iwinfo_backend()（在守卫函数里）、ubus 侧必须按 if_nametoindex 过滤。
_dawn_patch25="$SRC/buildroot/qca/feeds/packages/net/dawn/patches/0025-dawn-skip-non-netdev-sockets.patch"
[ -f "$_dawn_patch25" ] || die 4 "0025 未生效：dawn/patches/ 下没有非 netdev 过滤补丁"
grep -q '^+static const struct iwinfo_ops \*iwinfo_ops_for(const char \*ifname) {' "$_dawn_patch25" \
	|| die 4 "0025 内容不符：dawn_iwinfo.c 没有统一的 iwinfo_backend 守卫"
grep -q '^+            if (if_nametoindex(entry->d_name) == 0)$' "$_dawn_patch25" \
	|| die 4 "0025 内容不符：ubus.c 的订阅循环没有按 netdev 过滤"
grep -q '^-            iw = iwinfo_backend(entry->d_name);$' "$_dawn_patch25" \
	|| die 4 "0025 内容不符：仍有调用点直接调用 iwinfo_backend()"
logmsg "  DAWN_NON_NETDEV_OK dawn（iwinfo_backend 统一判空，订阅只收 netdev）"

# 0024 去掉 wpa_supplicant 配置里五个只有 qcn-app-extns 认识的全局项。noextns
# 变体遇到任一未知全局项就整份拒收（Failed to read or parse configuration），
# mesh vif 永远 NO-CARRIER；五条 heredoc 行必须一条都不剩。
_ws24="$SRC/buildroot/qca/feeds/wlan-open/mac80211/wifi-scripts/files/lib/netifd/hostapd.sh"
for _k in CSwOpts athnewind rptr_mgr_mode channel uplink_csa; do
	if grep -qxF "${_k}=\$${_k}" "$_ws24"; then
		die 4 "0024 未生效：hostapd.sh 仍向 wpa_supplicant 配置写 $_k"
	fi
done
logmsg "  SUPPLICANT_EXTN_OPTS_OK wifi-scripts（supplicant 配置不再带扩展全局项）"

# =============================================================== 11b. luci
step "LuCI 补丁（build/luci-patches/SERIES）"
apply_series "$BUILD/luci-patches/SERIES"
_ljs="$SRC/luci/modules/luci-mod-network/htdocs/luci-static/resources/view/network/wireless.js"
grep -q "crypto_modes.push(\['sae-compat', 'WPA2-PSK/WPA3-SAE Compatibility Mode', 30\])" "$_ljs" \
	|| die 4 "LuCI 补丁未生效：wireless.js 缺 sae-compat 加密选项"
grep -q "'sae-compat': has_ap_sae" "$_ljs" \
	|| die 4 "LuCI 补丁未生效：wireless.js 的 crypto_support 缺 sae-compat"
grep -q "o.depends('encryption', 'sae-compat')" "$_ljs" \
	|| die 4 "LuCI 补丁未生效：wireless.js 的 Key 字段未随 sae-compat 显示"
grep -q "'sae-mixed', 'sae-compat'\] });" "$_ljs" \
	|| die 4 "LuCI 补丁未生效：802.11r 快速漫游开关未覆盖 sae-compat"
logmsg "  SAE_COMPAT_OK luci wireless.js"

# 0002 让无线射频对话框正确处理 QSDK 的 band-split section（radioX_bandN）：
# iwinfo 对这类 section 只会返回 wiphy 的首个 band，旧表单因此拿不到正确频段，
# setValues() 重建选项后又丢选择，保存时把 band/channel 写成空值——uci.set 的
# '' 语义是删除选项，射频随即起不来。三处改动缺一即停：频段表改读 section 自身
# channels、重建后恢复所选 band、空值不落盘。
grep -qF 'const qsdk_split_channels =' "$_ljs" \
	|| die 4 "0002 未生效：LuCI 未按 radioX_bandN section 的 channels 构建频段表"
grep -qF 'setValues() rebuilt the Band options and dropped the selection' "$_ljs" \
	|| die 4 "0002 未生效：band 选择在 setValues() 重建后未被恢复"
grep -qF 'configured option instead of deleting it' "$_ljs" \
	|| die 4 "0002 未生效：空 band/channel 仍会删除配置选项"
logmsg "  QSDK_BAND_SPLIT_OK luci wireless.js"

# 0003 修「最大传输功率」下拉：iwinfo 对 phy/band-split section 的查询拿不到
# 频率条目，把 -1（未知）哨兵塞进 uint8_t 的 dbm 字段变成 255 dBm，rpcd 再算
# 出 2147483647 mW；同时列表里没有已配置的 txpower，保存表单会把 23 换成
# 255 或直接删掉。四处缺一即停：过滤 0..63 之外的条目、把 section 的
# option txpower 补进列表、已列值不重复、当前功率 0 按未知显示。
grep -qF 'if (p.dbm < 0 || p.dbm > 63)' "$_ljs" \
	|| die 4 "0003 未生效：txpower 列表仍保留 255 dBm 哨兵条目"
grep -qF "uci.get('wireless', section_id, 'txpower')" "$_ljs" \
	|| die 4 "0003 未生效：已配置的 txpower 未读入表单"
grep -qF 'listed.has(String(cfgval))' "$_ljs" \
	|| die 4 "0003 未生效：已配置的 txpower 未补进下拉列表"
grep -qF 'this.powerval > 0' "$_ljs" \
	|| die 4 "0003 未生效：当前功率 0 仍显示为 0 dBm"
logmsg "  TXPOWER_LIST_OK luci wireless.js"

# =============================================================== 12. 第三方
step "第三方树"
tp_repo() {
	awk -v k="$1" '$1 == "repo" && $2 == k {print $3 "\t" $5 "\t" $6 "\t" $7}' "$TPCONF"
}
[ -f "$TPCONF" ] || die 4 "缺少 $TPCONF"

# 12a. passwall-packages：passwall-selected 的来源，必须先于派生
IFS=$'\t' read -r _url _commit _vdir _mode <<< "$(tp_repo passwall-packages)"
[ -n "${_url:-}" ] || die 4 "thirdparty-feeds.conf 缺少 repo passwall-packages"
# 走 pin 缓存：重跑装配（--force）不必重新克隆；缓存里带 .git，12d 的
# thirdparty-feeds.sh check 才有 HEAD 可核对。
fetch_pin "$_url" "$_commit" "$(pin_cache "$_url" "$_commit")"
mkdir -p "$SRC/$_vdir"
rsync -a "$(pin_cache "$_url" "$_commit")/" "$SRC/$_vdir/" >>"$LOG" 2>&1 \
	|| die 4 "rsync passwall-packages 失败"
logmsg "  TP passwall-packages ${_commit:0:8} → $_vdir"

# 12b. passwall-selected：7 个目录拷贝（无 .git）
[ -f "$BUILD/passwall-selected.conf" ] || die 4 "缺少 build/passwall-selected.conf"
nps=0
while IFS=$'\t' read -r pkg desc; do
	[ -n "${pkg:-}" ] || continue
	case "$pkg" in \#*) continue ;; esac
	_psrc="$SRC/$_vdir/$pkg"
	[ -f "$_psrc/Makefile" ] || die 4 "passwall 包不存在：$pkg"
	mkdir -p "$SRC/passwall-selected"
	rsync -a --exclude='/.git/' "$_psrc/" "$SRC/passwall-selected/$pkg/" >>"$LOG" 2>&1
	nps=$((nps + 1))
done < "$BUILD/passwall-selected.conf"
[ "$nps" = 7 ] || die 4 "passwall-selected 应为 7 个包，实际 $nps"

# 12c. 其余第三方仓库 + thirdparty-feed 软链
SBE_ROOT="$STAGE" sh "$PROJ/scripts/thirdparty-feeds.sh" fetch >>"$LOG" 2>&1 \
	|| { tail -n 30 "$LOG" >&2; die 4 "thirdparty-feeds.sh fetch 失败"; }
while read -r _name; do
	[ -e "$SRC/thirdparty-feed/$_name" ] || die 4 "thirdparty-feed 软链悬空：$_name"
done < <(awk '$1 == "link" || $1 == "local" {print $2}' "$TPCONF")
logmsg "  TP_OK thirdparty-feed=$(find "$SRC/thirdparty-feed" -maxdepth 1 -type l | wc -l | tr -d ' ') links"

# =============================================================== 13. feeds
# 必须排在第三方树之后：feeds.conf 的 src-link 与 175 条 package/feeds 链接里
# 有 thirdparty/、passwall-selected/ 的目标，它们都由上一步产出。
step "feeds 接线"
install -m 0644 "$BUILD/feeds.conf.in" "$SRC/buildroot/feeds.conf"
if grep -q '/home/' "$SRC/buildroot/feeds.conf"; then
	die 4 "feeds.conf 含宿主绝对路径"
fi
mkdir -p "$SRC/buildroot/feeds"
nf=0
while read -r kw name target; do
	[ "$kw" = src-link ] || continue
	# feeds.conf 由 buildroot 解析，所以 src-link 目标（含 ../luci 这类）要相对
	# buildroot 换算。直接用 "$SRC/$target" 会把 ../luci 解到 stage 上层，得到
	# 指向源码根外的 ../../../luci（悬空软链）。这里只做词法归一（与 relpath
	# 一致），不解析目标自身的软链。
	tgt=$(python3 -I -c 'import os,sys; print(os.path.normpath(sys.argv[1]))' \
		"$SRC/buildroot/$target")
	case "$tgt" in
	"$SRC"/*) ;;
	*) die 4 "src-link 目标落在源码根外：$name -> $target" ;;
	esac
	[ -d "$tgt" ] || die 4 "feeds.conf src-link 目标不存在：$name -> buildroot/$target"
	ln -sfn "$(relpath "$SRC/buildroot/feeds" "$tgt")" "$SRC/buildroot/feeds/$name"
	nf=$((nf + 1))
done < <(grep -E '^[[:space:]]*src-link[[:space:]]' "$BUILD/feeds.conf.in")
[ "$nf" = 11 ] || die 4 "feeds.conf 应有 11 条 src-link，实际 $nf"
ln -sfn ../package "$SRC/buildroot/feeds/base"

mkdir -p "$SRC/buildroot/package/feeds"
nl=0
while IFS=$'\t' read -r link target rest; do
	[ -n "${link:-}" ] || continue
	case "$link" in \#*) continue ;; esac
	ldir=$(dirname -- "$SRC/$link")
	mkdir -p "$ldir"
	ln -sfn "$(relpath "$ldir" "$SRC/$target")" "$SRC/$link"
	[ -e "$SRC/$link" ] || die 4 "软件包软链悬空：$link -> $target"
	[ -f "$SRC/$target/Makefile" ] || die 4 "软件包目标没有 Makefile：$target"
	nl=$((nl + 1))
done < "$BUILD/feeds-links.conf"
[ "$nl" = 175 ] || die 4 "package/feeds 软链应有 175 条，实际 $nl"
logmsg "  FEEDS_OK src-link=$nf package-links=$nl base->package"

# =============================================================== 14. 配置
step "冻结配置（config-frozen）"
install -m 0644 "$BUILD/config-frozen/.config" "$SRC/buildroot/.config"
install -m 0644 "$BUILD/config-frozen/version" "$SRC/buildroot/version"
install -m 0644 "$BUILD/config-frozen/version.date" "$SRC/buildroot/version.date"
_want=$(sha256sum "$BUILD/config-frozen/.config" | cut -d' ' -f1)
_got=$(sha256sum "$SRC/buildroot/.config" | cut -d' ' -f1)
[ "$_want" = "$_got" ] || die 4 ".config 复制后哈希不符"
_feedcfg=$(grep -cE '^CONFIG_FEED_[A-Za-z0-9_]+=y$' "$SRC/buildroot/.config" || true)
[ "$_feedcfg" = 8 ] || die 4 ".config 里应有 8 个 CONFIG_FEED_*=y，实际 $_feedcfg"
if grep -qE '^CONFIG_PACKAGE_uboot-2025' "$SRC/buildroot/.config"; then
	die 4 ".config 仍选中 uboot-2025 包（与 target.mk 剪裁矛盾）"
fi
[ "$(cat "$SRC/buildroot/version.date")" = "$EPOCH" ] || die 4 "version.date != $EPOCH"
logmsg "  CONFIG_OK sha256=$_got"

# 源码依赖断言：被选中的包若要拿 qca/src 里的本地树当源码，那棵树必须存在。
# 机制在 include/local-development.mk：
#   LOCAL_SRC ?= $(TOPDIR)/qca/src/$(PKG_NAME)
#   ifeq (exists, $(shell [ -d $(LOCAL_SRC) ] && echo exists))
#   PKG_UNPACK = mkdir -p $(PKG_BUILD_DIR); $(CP) $(LOCAL_SRC)/* $(PKG_BUILD_DIR)/
#   endif
# 目录不在时 ifeq 不成立，PKG_UNPACK 静默退回 PKG_SOURCE_PROTO:=git + 空
# PKG_SOURCE_URL：构建目录从未被填充，包在 1 秒内以 "No rule to make target ..."
# 失败，日志里只有一行 ERROR（run 40176273728 的 sysupgrade-helper 就是这样）。
# 这类失败不该等到编译才出现——剪裁/替换后在这里一次性核对（仍属第 14 步）。
_sel="$STAGE/selected-packages.txt"
sed -n 's/^CONFIG_PACKAGE_\([A-Za-z0-9_.+-]*\)=[ym]$/\1/p' "$SRC/buildroot/.config" | sort -u > "$_sel"
_srcbad=0
_srcchecked=0
while IFS= read -r _mk; do
	_defined=$(sed -n 's/.*BuildPackage,\([A-Za-z0-9_.+-]*\).*/\1/p' "$_mk")
	[ -n "$_defined" ] || continue
	_is_sel=0
	for _p in $_defined; do
		if grep -qxF "$_p" "$_sel"; then _is_sel=1; break; fi
	done
	[ "$_is_sel" = 1 ] || continue
	_relmk=${_mk#"$SRC/"}
	# 1) 显式 LOCAL_SRC（qca-ssdk-shell、各 qca-nss-* 都这么写）
	_explicit=$(sed -n 's/^[[:space:]]*LOCAL_SRC[[:space:]]*:*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$_mk" | head -n1)
	if [ -n "${_explicit:-}" ]; then
		_p=${_explicit#'$(TOPDIR)/'}
		_srcchecked=$((_srcchecked + 1))
		case "$_p" in
		/*)
			if [ ! -e "$_p" ]; then
				logmsg "  MISSING_EXPLICIT $_p  ← $_relmk"
				_srcbad=$((_srcbad + 1))
			fi
			;;
		*)
			if [ ! -e "$SRC/buildroot/$_p" ] && [ ! -e "$(dirname "$_mk")/$_p" ]; then
				logmsg "  MISSING_EXPLICIT $_p  ← $_relmk"
				_srcbad=$((_srcbad + 1))
			fi
			;;
		esac
		continue
	fi
	# 2) 隐式默认值 qca/src/$(PKG_NAME)
	if ! grep -q 'local-development.mk' "$_mk"; then continue; fi
	_pkgn=$(sed -n 's/^[[:space:]]*PKG_NAME[[:space:]]*:*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$_mk" | head -n1)
	[ -n "${_pkgn:-}" ] || continue
	_srcchecked=$((_srcchecked + 1))
	if [ -d "$SRC/buildroot/qca/src/$_pkgn" ]; then continue; fi
	# 有真实下载地址的包不依赖本地树
	if grep -qE '^[[:space:]]*PKG_SOURCE_URL[[:space:]]*:*=[[:space:]]*[^[:space:]]' "$_mk"; then continue; fi
	logmsg "  MISSING_IMPLICIT qca/src/$_pkgn  ← $_relmk（树不存在，且没有 PKG_SOURCE_URL 可退回）"
	_srcbad=$((_srcbad + 1))
done < <(find "$SRC/buildroot/package" "$SRC/buildroot/qca/feeds" -name Makefile -type f 2>/dev/null)
[ "$_srcbad" = 0 ] || die 4 "有 $_srcbad 个选中包缺源码树（见上 MISSING_IMPLICIT / MISSING_EXPLICIT）：装配不许产出这种树"
logmsg "  SRC_DEPS_OK selected=$(wc -l < "$_sel") checked=$_srcchecked"

# =============================================================== 15. 文档
step "文档"
install -m 0644 "$PROJ/docs/package/README.md" "$SRC/README.md"
install -m 0644 "$PROJ/docs/package/PROVENANCE.md" "$SRC/PROVENANCE.md"

# 结构断言：装配树里不允许出现指向根外的绝对软链
_abs=$(find "$SRC" -type l -lname '/*' -print -quit)
[ -z "$_abs" ] || die 4 "存在绝对软链：${_abs#"$STAGE"/}"

# =============================================================== 16. 指纹
step "树指纹"
_recipe=$("$PROJ/scripts/ci/recipe-hash.sh")
FP_JSON="$STAGE/fingerprint.json"
FP_TSV="$STAGE/fingerprint.tsv"
# 用 `|| rc=$?` 而不是 `set +e`：trap ERR 的触发条件不看 errexit，set +e
# 挡不住 on_err（rc=5 的指纹不一致曾被它改写成 rc=4，日志里只剩一句通用的
# step 失败）。`||` 列表里的命令按 bash 规则不进 ERR trap。
rc=0
"$PROJ/scripts/ci/tree-fingerprint.sh" \
	--root "$SRC" --exclude "$BUILD/fingerprint-exclude.conf" \
	--profile fresh --recipe-sha "$_recipe" --epoch "$EPOCH" \
	--out "$FP_JSON" --tsv "$FP_TSV" >>"$LOG" 2>&1 || rc=$?
[ "$rc" = 0 ] || { tail -n 60 "$LOG" >&2; die 4 "tree-fingerprint.sh 失败（rc=$rc）"; }
_agg=$(sed -n 's/.*"aggregate_sha256": "\([0-9a-f]*\)".*/\1/p' "$FP_JSON")
_entries=$(sed -n 's/.*"entry_count": \([0-9]*\).*/\1/p' "$FP_JSON")
[ -n "$_agg" ] || die 4 "无法从 $FP_JSON 读出聚合值"
logmsg "  FINGERPRINT entries=$_entries aggregate=$_agg"

if [ "$NO_COMPARE" != 1 ]; then
	if [ -z "$COMPARE" ] && [ -f "$BUILD/fingerprint/audited-24.10-6.6.tsv.zst" ]; then
		COMPARE="$BUILD/fingerprint/audited-24.10-6.6.tsv.zst"
	fi
	if [ -n "$COMPARE" ]; then
		# 基准以 zst 入库（20 MB 的 tsv 压到 5.6 MB）；比对前先解开。
		if [ "${COMPARE##*.}" = zst ]; then
			zstd -dc -- "$COMPARE" > "$STAGE/compare-baseline.tsv" \
				|| die 4 "无法解压基准：$COMPARE"
			COMPARE="$STAGE/compare-baseline.tsv"
		fi
		rc=0
		"$PROJ/scripts/ci/tree-fingerprint.sh" \
			--root "$SRC" --exclude "$BUILD/fingerprint-exclude.conf" \
			--profile fresh --recipe-sha "$_recipe" --epoch "$EPOCH" \
			--out "$FP_JSON" --tsv "$FP_TSV" \
			--compare "$COMPARE" --known-delta "$BUILD/known-delta.conf" >>"$LOG" 2>&1 || rc=$?
		if [ "$rc" = 5 ]; then
			# UNEXPLAINED 行优先打全：它们才是判定依据，DELTA 只是背景。
			grep -E '^UNEXPLAINED' "$LOG" >&2 || true
			grep -E '^(compare:|UNEXPLAINED|DELTA|ERROR)' "$LOG" | tail -n 40 >&2 || true
			die 5 "FINGERPRINT_MISMATCH：与基准 $COMPARE 有未解释差异"
		fi
		[ "$rc" = 0 ] || { tail -n 60 "$LOG" >&2; die 4 "指纹比对失败（rc=$rc）"; }
		logmsg "  FINGERPRINT_MATCH 基准=$COMPARE"
	else
		logmsg "  NOTE 未提供 --compare：只生成本次指纹（与审计基线的比对见 V2）"
	fi
fi

logmsg ""
logmsg "PASS  sources=$SRC"
logmsg "      recipe_sha256=$_recipe"
logmsg "      fingerprint entries=$_entries aggregate=$_agg"
logmsg "      日志 $LOG"
