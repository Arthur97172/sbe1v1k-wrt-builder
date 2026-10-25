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
# 顺序不是随便排的，两处有硬依赖：
#   - target/linux/feeds 整仓库替换要早于 files-6.6 / patches-6.6：rsync --delete
#     会删掉替换目标里“上游没有的子目录”，反过来会把刚铺好的 files-6.6 删掉。
#   - 内核叠加层（cp files-6.6/. → linux-6.6/）必须在 files-6.6 装完之后：
#     ipq95xx/Makefile:29 在解析期就是这么拷的，源码树里已经是叠加后的状态。
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
10 内核叠加层：cp -a files-6.6/. → qca/src/linux-6.6/
11 构建系统补丁：build/build-fixes/SERIES（全部 tree 模式；0004/0007 空号）
12 第三方树：passwall-selected 派生、wifihistory 稀疏检出 + 补丁、thirdparty-feeds.sh fetch
13 feeds 接线：feeds.conf + 10 条 feeds/<name> + 156 条 package/feeds 软链（依赖上一步）
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
# git_fetch_retry <仓库目录> <40 位 commit>：按 commit 浅取，最多 3 次，第三次
# 强制 HTTP/1.1。本机到 GitHub 偶发 TLS reset / HTTP2 framing，那不是“上游不可用”；
# 重试仍失败才由调用方判 SOURCE_UNAVAILABLE（绝不降级到分支头）。
git_fetch_retry() {
	local d=$1 c=$2 try=1
	while [ "$try" -le 3 ]; do
		if [ "$try" = 3 ]; then
			git -c http.version=HTTP/1.1 -C "$d" fetch --quiet --depth 1 origin "$c" \
				>>"$LOG" 2>&1 && return 0
		else
			git -C "$d" fetch --quiet --depth 1 origin "$c" >>"$LOG" 2>&1 && return 0
		fi
		[ "$try" -lt 3 ] && logmsg "  RETRY fetch 第 $((try + 1)) 次：${c:0:12} ($d)"
		try=$((try + 1))
		[ "$try" -le 3 ] && sleep 5
	done
	return 1
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
			mkdir -p "$SRC/$dest"
			cp -p "$patch" "$SRC/$dest/"
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
for f in build-fixes/SERIES p-b/SERIES target-feed-fixes/SERIES; do
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
[ "$pruned" -gt 0 ] || die 4 "prune.conf 没有可执行的行"

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
_mmc="$SRC/buildroot/target/linux/feeds/ipq95xx/base-files/lib/upgrade/mmc.sh"
[ -f "$_mmc" ] || die 4 "mmc.sh 缺失"
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
step "内核叠加层（files-6.6 → qca/src/linux-6.6）"
KERNEL="$SRC/buildroot/qca/src/linux-6.6"
[ -d "$KERNEL" ] || die 4 "内核树缺失：$KERNEL"
cp -a "$FEEDS6/." "$KERNEL/" >>"$LOG" 2>&1 || die 4 "内核叠加失败"
[ -f "$KERNEL/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts" ] || die 4 "叠加后内核树没有 SBE DTS"
[ -f "$KERNEL/drivers/net/phy/rtl8261n/Makefile" ] || die 4 "叠加后内核树没有 rtl8261n"
logmsg "  OVERLAY_OK $(count_files "$KERNEL") files"

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

# 12c. wifihistory：稀疏检出（cone 模式，保留仓库根文件）+ 一处 Makefile 补丁
IFS=$'\t' read -r _url _commit _vdir _mode <<< "$(tp_repo wifihistory)"
[ -n "${_url:-}" ] || die 4 "thirdparty-feeds.conf 缺少 repo wifihistory"
_wdir="$SRC/$_vdir"
if [ ! -d "$_wdir/.git" ]; then
	mkdir -p "$(dirname -- "$_wdir")"
	git init -q "$_wdir" >>"$LOG" 2>&1 || die 4 "wifihistory git init 失败"
	git -C "$_wdir" remote add origin "$_url" >>"$LOG" 2>&1 || die 4 "wifihistory remote add 失败"
fi
if ! git -C "$_wdir" cat-file -e "$_commit^{commit}" 2>/dev/null; then
	git_fetch_retry "$_wdir" "$_commit" \
		|| die 2 "SOURCE_UNAVAILABLE: wifihistory @ $_commit"
fi
git -C "$_wdir" sparse-checkout init --cone >>"$LOG" 2>&1 || die 4 "sparse-checkout init 失败"
git -C "$_wdir" sparse-checkout set applications/luci-app-wifihistory >>"$LOG" 2>&1 \
	|| die 4 "sparse-checkout set 失败"
git -C "$_wdir" -c advice.detachedHead=false checkout -q --detach "$_commit" >>"$LOG" 2>&1 \
	|| die 4 "wifihistory checkout 失败"
[ "$(git -C "$_wdir" rev-parse HEAD)" = "$_commit" ] || die 3 "wifihistory PIN_MISMATCH"
_wh="$BUILD/thirdparty-patches/luci-app-wifihistory.patch"
apply_patch "$_wh" "$_wdir"
[ "$(find "$_wdir" -path "$_wdir/.git" -prune -o -type f -print | wc -l | tr -d ' ')" = 43 ] \
	|| die 4 "wifihistory 稀疏检出文件数应为 43"

# 12d. 其余第三方仓库 + thirdparty-feed 软链
SBE_ROOT="$STAGE" sh "$PROJ/scripts/thirdparty-feeds.sh" fetch >>"$LOG" 2>&1 \
	|| { tail -n 30 "$LOG" >&2; die 4 "thirdparty-feeds.sh fetch 失败"; }
while read -r _name; do
	[ -e "$SRC/thirdparty-feed/$_name" ] || die 4 "thirdparty-feed 软链悬空：$_name"
done < <(awk '$1 == "link" || $1 == "local" {print $2}' "$TPCONF")
logmsg "  TP_OK thirdparty-feed=$(find "$SRC/thirdparty-feed" -maxdepth 1 -type l | wc -l | tr -d ' ') links"

# =============================================================== 13. feeds
# 必须排在第三方树之后：feeds.conf 的 src-link 与 156 条 package/feeds 链接里
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
[ "$nf" = 10 ] || die 4 "feeds.conf 应有 10 条 src-link，实际 $nf"
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
[ "$nl" = 156 ] || die 4 "package/feeds 软链应有 156 条，实际 $nl"
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
set +e
"$PROJ/scripts/ci/tree-fingerprint.sh" \
	--root "$SRC" --exclude "$BUILD/fingerprint-exclude.conf" \
	--profile fresh --recipe-sha "$_recipe" --epoch "$EPOCH" \
	--out "$FP_JSON" --tsv "$FP_TSV" >>"$LOG" 2>&1
rc=$?
set -e
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
		set +e
		"$PROJ/scripts/ci/tree-fingerprint.sh" \
			--root "$SRC" --exclude "$BUILD/fingerprint-exclude.conf" \
			--profile fresh --recipe-sha "$_recipe" --epoch "$EPOCH" \
			--out "$FP_JSON" --tsv "$FP_TSV" \
			--compare "$COMPARE" --known-delta "$BUILD/known-delta.conf" >>"$LOG" 2>&1
		rc=$?
		set -e
		if [ "$rc" = 5 ]; then
			grep -E '^(compare:|DELTA|ERROR)' "$LOG" | tail -n 80 >&2 || true
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
