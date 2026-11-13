#!/usr/bin/env bash
# 把 build/thirdparty-pins.conf 里的 18 个插件装进 25.12 装配树的 package/。
#
# 用法：
#   scripts/ci/fetch-plugins.sh                 [工作区根]   默认 latest
#   SBE_PLUGIN_MODE=pinned scripts/ci/fetch-plugins.sh ...   按清单 pin 复现
#   scripts/ci/fetch-plugins.sh --dry-run       [工作区根]   只解析并打印
#
# 模式（环境变量 SBE_PLUGIN_MODE）：
#   latest   （默认）每次构建解析远端最新版本 tag（无版本 tag 取默认分支头），
#            仅当新提交是清单 pin 的后代时采用；分叉、回退（pin 已在候选之后）
#            或读不到远端时保留 pin 并告警，不中断构建。
#   pinned   全部使用清单里的 pinned-commit，用于精确复现旧镜像。
#
# 严格模式：SBE_PLUGIN_STRICT=1 时 stale/diverged/unknown 直接失败（CI 用）；
# 默认宽松：保留 pin 并在结果表里标注，构建继续。
#
# 结果写入 <装配树>/.sbe-plugins.tsv（key/url/tag/commit/pin/action），供
# release notes 与日志引用；本脚本不改写 thirdparty-pins.conf。
#
# 远端口径与 24.10-6.10 的 scripts/ci/refresh-pins.sh 一致：
#   - 版本 tag：形如 v?<数字>…，按版本序取最大；注解 tag 取 ^{} 指向的 commit；
#   - 合入判断用 git merge-base --is-ancestor，不看日期；
#   - 远端不可达 → SOURCE_UNAVAILABLE，按 pin 继续并标注 stale。
#
# 缓存：<工作区>/.sbe-cache/plugins/git/<key>（blob:none 全历史，增量 fetch；
# 包内容用 git archive 按需取 blob）。不接触设备、不写入口令。

set -euo pipefail
export GIT_TERMINAL_PROMPT=0
LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)          # <repo>/25.12-6.12

DRY=0
ROOT=""
for arg in "$@"; do
	case "$arg" in
	--dry-run) DRY=1 ;;
	--help|-h) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) echo "未知参数: $arg" >&2; exit 2 ;;
	*) [ -n "$ROOT" ] && { echo "只接受一个工作区根目录参数" >&2; exit 2; }; ROOT=$arg ;;
	esac
done
[ -n "$ROOT" ] || ROOT=$(CDPATH= cd -- "$PROJ/.." && pwd)

CONF=$PROJ/build/thirdparty-pins.conf
BR=$ROOT/sources/buildroot-25.12-6.12
CACHE=${SBE_PLUGIN_CACHE:-$ROOT/.sbe-cache/plugins/git}
PACK=${SBE_PLUGIN_PACK:-$ROOT/.sbe-cache/plugins/pack}
MODE=${SBE_PLUGIN_MODE:-latest}
# CI 用 SBE_PLUGIN_STRICT=1：stale（远端不可达）/diverged/unknown 直接失败，
# 避免"以为在跟新、其实一直用旧 pin"。本地默认宽松（保持 pin 并告警）。
STRICT=${SBE_PLUGIN_STRICT:-0}
OUT=$BR/.sbe-plugins.tsv

case "$MODE" in
latest|pinned) ;;
*) echo "SBE_PLUGIN_MODE 只能是 latest 或 pinned（当前：$MODE）" >&2; exit 2 ;;
esac

[ -f "$CONF" ] || { echo "缺少 $CONF" >&2; exit 2; }
command -v git >/dev/null || { echo "缺少 git" >&2; exit 2; }
if [ "$DRY" = 0 ] && [ ! -d "$BR/package" ]; then
	echo "找不到装配树 $BR（先跑 prepare-tree.sh，或 --dry-run）" >&2
	exit 2
fi

say()  { printf '[plugins] %s\n' "$*"; }
warn() { printf '[plugins] WARN   %s\n' "$*" >&2; }

# 网络操作的重试：GitHub/GnuTLS 偶发握手失败不应让整次构建失败。
retry() {
	local i
	for i in 1 2 3; do
		"$@" && return 0
		sleep $((i * 2))
	done
	return 1
}

# ------------------------------------------------------------------ 远端查询
# 版本 tag，一行 "<tag>\t<sha>"，按版本序升序。注解 tag 取 peeled commit。
remote_tags() {
	git ls-remote --tags "$1" 2>/dev/null | awk '
		{ sha=$1; ref=$2; peeled=(ref ~ /\^\{\}$/); sub(/\^\{\}$/,"",ref)
		  sub(/^refs\/tags\//,"",ref); seen[ref]=1
		  if (peeled) psha[ref]=sha; else if (!(ref in bsha)) bsha[ref]=sha }
		END { for (t in seen) { if (t !~ /^v?[0-9][0-9A-Za-z._-]*$/) continue
		        s = (t in psha) ? psha[t] : bsha[t]; print t"\t"s } }' \
		| awk -F'\t' '{v=$1; sub(/^v/,"",v); print v"\t"$0}' \
		| LC_ALL=C sort -V -k1,1 | cut -f2-
}

remote_head() {
	git ls-remote --symref "$1" HEAD 2>/dev/null \
		| awk '$2 == "HEAD" && $1 ~ /^[0-9a-f]+$/ {print $1; exit}'
}

# pick_latest <url>：输出 "<tag|HEAD>\t<sha>"，读不到则空
# ls-remote 偶发只返回部分 refs（实测有仓库因此从 tag 退回 HEAD），
# 因此 tag 列表为空时重试几次，再退到分支头。
pick_latest() {
	local url=$1 last="" head="" i
	for i in 1 2 3; do
		last=$(remote_tags "$url" | tail -n 1)
		[ -n "$last" ] && break
		sleep 2
	done
	if [ -n "$last" ]; then
		printf '%s\n' "$last"
		return 0
	fi
	for i in 1 2 3; do
		head=$(remote_head "$url")
		[ -n "$head" ] && break
		sleep 2
	done
	[ -n "$head" ] && printf 'HEAD\t%s\n' "$head"
}

# ------------------------------------------------------------------ 本地缓存
ensure_cache() { # <key> <url>
	local key=$1 url=$2 dir=$CACHE/$1
	if [ ! -d "$dir/.git" ]; then
		mkdir -p "$CACHE"
		git init -q "$dir"
		git -C "$dir" remote add origin "$url"
	else
		git -C "$dir" remote set-url origin "$url"
	fi
	# 全部分支与 tag 的提交/树历史；blob 按需取。已有缓存时是增量。
	retry git -C "$dir" fetch -q --filter=blob:none --no-tags origin \
		'+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'
}

# 安装用的完整源码：每个仓库一个 depth-1 浅仓库，只含选定提交的整棵树。
# 不用“blob 按需拉取”（git archive 里逐个 blob 走 promisor，链接抖动时
# 中途失败且不可重试）；浅仓库一次取全，失败可整体重试。
ensure_pack() { # <key> <url> <sha>
	local key=$1 url=$2 sha=$3 dir=$PACK/$1 marker
	marker=$dir/.sbe-packed
	mkdir -p "$PACK"
	if [ -f "$marker" ] && [ "$(cat "$marker")" = "$sha" ]; then
		return 0
	fi
	if [ ! -d "$dir/.git" ]; then
		git init -q "$dir"
		git -C "$dir" remote add origin "$url"
	else
		git -C "$dir" remote set-url origin "$url"
	fi
	rm -f "$marker"
	retry git -C "$dir" fetch -q --depth 1 --no-tags origin "$sha" \
		|| return 1
	git -C "$dir" update-ref refs/sbe/current "$sha" 2>/dev/null \
		|| git -C "$dir" update-ref refs/sbe/current FETCH_HEAD
	printf '%s\n' "$sha" > "$marker"
}

have_commit() { git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null; }

# classify <key> <pin> <sha>：same|ahead|behind|diverged|unknown
classify() {
	local key=$1 pin=$2 sha=$3 dir=$CACHE/$1
	if [ "$pin" = "$sha" ]; then echo same; return; fi
	if ! have_commit "$dir" "$pin"; then
		retry git -C "$dir" fetch -q --filter=blob:none origin "$pin" >/dev/null 2>&1 || true
	fi
	if ! have_commit "$dir" "$sha"; then
		retry git -C "$dir" fetch -q --filter=blob:none origin "$sha" >/dev/null 2>&1 || true
	fi
	if ! have_commit "$dir" "$pin" || ! have_commit "$dir" "$sha"; then
		echo unknown; return
	fi
	if git -C "$dir" merge-base --is-ancestor "$pin" "$sha" 2>/dev/null; then
		echo ahead
	elif git -C "$dir" merge-base --is-ancestor "$sha" "$pin" 2>/dev/null; then
		echo behind
	else
		echo diverged
	fi
}

# ------------------------------------------------------------------ 安装
# Makefile 里显式写出的包名（luci.mk 系列应用通常不写，此时目录名就是包名）。
makefile_pkg_name() {
	sed -n 's/^PKG_NAME[[:space:]]*:*=[[:space:]]*\([A-Za-z0-9._+-]*\).*/\1/p' \
		"$1/Makefile" 2>/dev/null | head -n 1
}

install_repo() { # <key> <url> <sha> <subdirs(csv)>
	local key=$1 url=$2 sha=$3 subdirs=$4 tmp sd name src pn dup rc=0
	local -a paths=()
	IFS=',' read -r -a paths <<< "$subdirs"
	if ! ensure_pack "$key" "$url" "$sha"; then
		echo "[plugins] FAIL   $key：取源码 ${sha:0:12} 失败" >&2
		return 1
	fi
	tmp=$(mktemp -d "$ROOT/.sbe-cache/plugins/extract.XXXXXX")
	if [ "$subdirs" = "." ]; then
		git -C "$PACK/$key" archive --format=tar "$sha" | tar -x -C "$tmp" || rc=1
	else
		git -C "$PACK/$key" archive --format=tar "$sha" -- "${paths[@]}" \
			| tar -x -C "$tmp" || rc=1
	fi
	if [ "$rc" != 0 ]; then
		echo "[plugins] FAIL   $key：git archive ${sha:0:12} 失败" >&2
		rm -rf "$tmp"
		return 1
	fi
	for sd in "${paths[@]}"; do
		if [ "$sd" = "." ]; then
			name=$key; src=$tmp
		else
			name=$(basename "$sd"); src=$tmp/$sd
		fi
		if [ ! -d "$src" ]; then
			echo "[plugins] FAIL   $key：归档里没有 $sd" >&2
			rm -rf "$tmp"; return 1
		fi
		pn=$(makefile_pkg_name "$src")
		[ -n "$pn" ] && name=$pn
		# 官方 feed 里已有同名包时，两份 Makefile 会在 package scan 阶段
		# 打架（或静默覆盖）。宁可在这里失败，也不要等 3 小时后才发现。
		for dup in "$BR"/package/feeds/*/"$name"; do
			if [ -e "$dup" ]; then
				echo "[plugins] FAIL   $key：$name 与官方 feed 的 $dup 重名" >&2
				rm -rf "$tmp"; return 1
			fi
		done
		rm -rf "$BR/package/$name"
		mkdir -p "$BR/package/$name"
		cp -a "$src"/. "$BR/package/$name"/
		if [ ! -f "$BR/package/$name/Makefile" ]; then
			echo "[plugins] FAIL   $key：package/$name 下没有 Makefile" >&2
			rm -rf "$tmp"; return 1
		fi
		# argon v3 把设置页并入主题包，但仓库里仍留着 compat/ 下的空迁移包。
		# 整目录安装会把它暴露给 package scan，必须删掉。
		if [ -f "$BR/package/$name/compat/luci-app-argon-config/Makefile" ]; then
			rm -rf "$BR/package/$name/compat"
			say "$key：已移除 compat/luci-app-argon-config（空迁移包）"
		fi
	done
	rm -rf "$tmp"
}

# ------------------------------------------------------------------ main
if [ "$DRY" = 0 ]; then
	mkdir -p "$CACHE"
	printf 'key\turl\ttag\tcommit\tpin\taction\n' > "$OUT"
fi

say "模式 $MODE，清单 $CONF"
n=0
while IFS=$'\t' read -r kw key url branch pin subdirs notes; do
	[ "${kw:-}" = repo ] || continue
	[ -n "${key:-}" ] && [ -n "${url:-}" ] && [ -n "${pin:-}" ] \
		&& [ -n "${subdirs:-}" ] \
		|| { echo "thirdparty-pins.conf 行不完整：$key" >&2; exit 2; }

	tag="(pinned)"; sha=$pin; action=pin
	if [ "$MODE" = latest ]; then
		pick=$(pick_latest "$url" || true)
		if [ -z "$pick" ]; then
			action=stale
			warn "$key：远端读不到（SOURCE_UNAVAILABLE），按 pin ${pin:0:12} 继续"
		else
			tag=${pick%%$'\t'*}
			sha=${pick##*$'\t'}
			if [ "$DRY" = 1 ]; then
				if [ "$sha" = "$pin" ]; then action=same
				elif [ "$tag" = HEAD ]; then action=head
				else action=tag
				fi
			else
				if ! ensure_cache "$key" "$url"; then
					action=stale; sha=$pin
					warn "$key：git fetch 失败（SOURCE_UNAVAILABLE），按 pin ${pin:0:12} 继续"
				else
					case "$(classify "$key" "$pin" "$sha")" in
					same) action=same ;;
					ahead) action=update ;;
					behind)
						action=behind; sha=$pin
						warn "$key：远端 tag $tag 早于/落后于 pin（不回退），保持 pin ${pin:0:12}" ;;
					diverged)
						action=diverged; sha=$pin
						warn "$key：远端 $tag 与 pin 分叉，需人工判断，保持 pin ${pin:0:12}" ;;
					*)
						action=unknown; sha=$pin
						warn "$key：无法判定 pin 与 $tag 的祖先关系，保持 pin ${pin:0:12}" ;;
					esac
				fi
			fi
		fi
	fi

	say "$(printf '%-24s %-16s %s %s' "$key" "$tag" "${sha:0:12}" "$action")"

	if [ "$DRY" = 0 ]; then
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$key" "$url" "$tag" "$sha" "$pin" "$action" >> "$OUT"
		install_repo "$key" "$url" "$sha" "$subdirs"
	fi
	n=$((n + 1))
done < "$CONF"

[ "$n" -gt 0 ] || { echo "清单里没有任何 repo 行" >&2; exit 2; }

if [ "$DRY" = 1 ]; then
	say "--dry-run：解析 $n 个仓库，未安装、未写文件（祖先关系在构建时判定）"
else
	say "安装 $n 个仓库 → $BR/package/，结果表 $OUT"
	if [ "$STRICT" = 1 ]; then
		bad=$(awk -F'\t' 'NR > 1 && ($6 == "stale" || $6 == "diverged" || $6 == "unknown") \
			{ printf "%s(%s) ", $1, $6 }' "$OUT")
		if [ -n "$bad" ]; then
			echo "[plugins] FAIL   严格模式：以下仓库没有解析到可用提交：$bad" >&2
			exit 1
		fi
	fi
fi
