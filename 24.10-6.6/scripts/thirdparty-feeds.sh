#!/bin/sh
# 校验/补齐文件 A（build/thirdparty-feeds.conf）登记的第三方源码。
#
#   scripts/thirdparty-feeds.sh check         只读校验，不改动任何文件
#   scripts/thirdparty-feeds.sh fetch [--force]
#                                             按固定提交补齐 mode=git 的仓库，
#                                             并重建 thirdparty-feed 相对软链
#   scripts/thirdparty-feeds.sh update <key> <commit>
#                                             先校验新提交可获取，再写回文件 A
#                                             并检出（仅 mode=git；会联网）
#
# 设计约束（来自 sources/README.md 与 ci/prepare-tree.sh）：
#   - 绝不改写 buildroot/feeds.conf，绝不生成绝对路径；
#   - 绝不运行 scripts/feeds update（它会重建 feeds/ 与 .tmp）；
#   - mode=manual 的仓库只校验 HEAD，不改写（人工剪裁/带补丁）。
#
# 状态词：PASS / FAIL / SKIP / UNVERIFIED。
# 本脚本不联网（fetch 在本地已符合 pin 时不访问网络）、不接触任何设备。

set -eu
LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/.." && pwd)
CONF="$PROJ/build/thirdparty-feeds.conf"

CMD=
FORCE=0
POS=""
for arg in "$@"; do
	case "$arg" in
	check|fetch|update) CMD=$arg ;;
	--force)            FORCE=1 ;;
	-h|--help)          sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*)                 echo "未知参数: $arg" >&2; exit 2 ;;
	*)                  POS="$POS $arg" ;;
	esac
done
[ -n "$CMD" ] || { echo "用法: $0 check|fetch [--force] | update <key> <commit>" >&2; exit 2; }

if [ -n "${SBE_ROOT:-}" ]; then
	ROOT=$SBE_ROOT
else
	ROOT=
	d=$PROJ
	while [ "$d" != / ]; do
		if [ -d "$d/sources/buildroot" ]; then ROOT=$d; break; fi
		d=$(dirname "$d")
	done
fi
[ -n "$ROOT" ] || { echo "找不到装配树 sources/buildroot（可用 SBE_ROOT 指定）" >&2; exit 1; }
SOURCES="$ROOT/sources"
FEEDDIR="$SOURCES/thirdparty-feed"
[ -f "$CONF" ] || { echo "缺少源清单: $CONF" >&2; exit 1; }

FAILS=0
pass() { printf 'PASS  %s\n' "$*"; }
skip() { printf 'SKIP  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

short() { printf '%s' "$1" | cut -c1-8; }

# 在 thirdparty-feed 下建立相对软链：<name> -> ../<vendor>/<subdir>
relink() {
	name=$1 target=$2
	want="../$target"
	[ -d "$FEEDDIR" ] || mkdir -p "$FEEDDIR"
	if [ -L "$FEEDDIR/$name" ] && [ "$(readlink "$FEEDDIR/$name")" = "$want" ]; then
		return 0
	fi
	ln -sfn "$want" "$FEEDDIR/$name"
	printf 'LINK  %s -> %s\n' "$name" "$want"
}

check_link() {
	name=$1 target=$2
	path="$FEEDDIR/$name"
	want="../$target"
	if [ ! -L "$path" ]; then
		fail "link $name 缺失或不是软链（应为 $want）"
	elif [ "$(readlink "$path")" != "$want" ]; then
		fail "link $name 指向 $(readlink "$path")，应为 $want"
	elif [ ! -e "$path" ]; then
		fail "link $name 悬空（$want 不存在）"
	else
		pass "link $name -> $want"
	fi
}

# ---------------------------------------------------------------------------
# update：校验新提交可获取 → 写回文件 A → 落到 fetch 流程检出
# ---------------------------------------------------------------------------
if [ "$CMD" = update ]; then
	set -f
	# shellcheck disable=SC2086
	set -- $POS
	set +f
	[ "$#" -eq 2 ] || { echo "用法: $0 update <key> <commit>" >&2; exit 2; }
	key=$1; new=$2
	case "$new" in
	*[!0-9a-f]*|'') echo "commit 必须是 40 位小写十六进制: $new" >&2; exit 2 ;;
	esac
	[ "${#new}" -eq 40 ] || { echo "commit 必须是 40 位: $new" >&2; exit 2; }

	meta=$(awk -v k="$key" '$1=="repo" && $2==k {print $6, $7}' "$CONF")
	[ -n "$meta" ] || { echo "文件 A 中没有 repo: $key" >&2; exit 2; }
	# shellcheck disable=SC2086
	set -- $meta
	vdir=$1; mode=$2
	[ "$mode" = git ] || { echo "FAIL  $key mode=$mode，拒绝自动改 pin" >&2; exit 1; }

	dir="$SOURCES/$vdir"
	[ -d "$dir/.git" ] || { echo "FAIL  $key 缺少 .git（$vdir）" >&2; exit 1; }
	printf 'VERIFY %s 可获取 %s ...\n' "$key" "$(short "$new")"
	if ! git -C "$dir" fetch -q --depth 1 origin "$new"; then
		echo "FAIL  $key 无法获取 $new（网络或仓库策略）；文件 A 未改动" >&2
		exit 1
	fi
	got=$(git -C "$dir" rev-parse FETCH_HEAD)
	if [ "$got" != "$new" ]; then
		echo "FAIL  $key FETCH_HEAD=$got != $new；文件 A 未改动" >&2
		exit 1
	fi

	# 只替换该行的 commit 字段，保留原有对齐/空白。
	tmpf=$(mktemp)
	sed -E "s|^(repo[[:space:]]+$key[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)[0-9a-f]{40}|\1$new|" \
		"$CONF" > "$tmpf"
	if ! grep -q "repo[[:space:]]*$key[[:space:]].*[[:space:]]$new[[:space:]]" "$tmpf"; then
		rm -f "$tmpf"
		echo "FAIL  $key 写回文件 A 失败；文件未改动" >&2
		exit 1
	fi
	cat "$tmpf" > "$CONF"
	rm -f "$tmpf"
	pass "文件 A: $key -> $new"
	echo "提醒：同步更新 build/upstream-pins.conf 与 docs/package/PROVENANCE.md §2.9；" \
	     "push 后由 sources-24.10-6.6.yml 重新装配、发布新的 sources-vN 才对 CI 生效。"
	CMD=fetch
fi

# ---------------------------------------------------------------------------
# 解析并逐行处理
# ---------------------------------------------------------------------------
while IFS= read -r raw; do
	case "$raw" in
	''|\#*) continue ;;
	esac
	# 关闭通配展开后再按空白切分，避免注释/路径里的 * 被 shell 展开。
	set -f
	# shellcheck disable=SC2086
	set -- $raw
	set +f
	kind=$1; shift
	case "$kind" in
	repo)
		[ "$#" -eq 6 ] || { fail "repo 行字段数不对: $raw"; continue; }
		key=$1; url=$2; branch=$3; commit=$4; vdir=$5; mode=$6
		dir="$SOURCES/$vdir"
		case "$mode" in git|manual) ;; *) fail "$key 未知 mode: $mode"; continue ;; esac

		if [ ! -d "$dir" ]; then
			if [ "$CMD" != fetch ] || [ "$mode" != git ]; then
				fail "$key 目录不存在: $vdir"
				continue
			fi
			printf 'CLONE %s -> %s\n' "$key" "$vdir"
			tmp="$dir.clone.$$"
			rm -rf "$tmp"
			# 按 40 位 commit 浅取，不拉整段历史：CI 上一个仓库的完整历史可能
			# 上百 MB，而这里只要一个快照。取不到就失败，不降级到分支头。
			if [ "${#commit}" -ne 40 ]; then
				fail "$key 的 commit 必须是 40 位十六进制: $commit"
				continue
			fi
			ok=0
			if git init -q "$tmp" && git -C "$tmp" remote add origin "$url"; then
				for try in 1 2 3; do
					if [ "$try" = 3 ]; then
						git -c http.version=HTTP/1.1 -C "$tmp" fetch -q --depth 1 \
							origin "$commit" && ok=1
					else
						git -C "$tmp" fetch -q --depth 1 origin "$commit" && ok=1
					fi
					[ "$ok" = 1 ] && break
					[ "$try" -lt 3 ] && { printf 'RETRY %s 第 %d 次\n' "$key" "$((try + 1))"; sleep 5; }
				done
			fi
			if [ "$ok" = 1 ] \
				&& git -C "$tmp" checkout -q --detach FETCH_HEAD \
				&& [ "$(git -C "$tmp" rev-parse HEAD)" = "$commit" ]; then
				mkdir -p "$(dirname "$dir")"
				rm -rf "$dir"
				mv "$tmp" "$dir"
				pass "$key 已克隆到 $(short "$commit")"
			else
				rm -rf "$tmp"
				fail "$key 克隆失败: $url @ $(short "$commit")"
			fi
			continue
		fi

		if [ ! -d "$dir/.git" ]; then
			# 从 sources-vN 源码包解出来的树不带 .git：包只装源码，VCS 元数据
			# 由装配时的 pin 断言与 tree-fingerprint 承担。CI 用 SBE_NO_GIT=1
			# 声明这一点；本地审计树仍要求 .git，避免“以为在校验 pin”。
			if [ "${SBE_NO_GIT:-0}" = 1 ]; then
				skip "$key 无 .git（源码包不带 VCS 元数据；pin 已由指纹与 recipe_sha256 钉住）"
				continue
			fi
			fail "$key 没有 .git，无法校验 pin（$vdir；如需重建请手工移除该目录后 fetch）"
			continue
		fi

		head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
		dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
		match=0
		case "$head" in "$commit"*) match=1 ;; esac

		if [ "$CMD" = check ]; then
			if [ "$match" != 1 ]; then
				fail "$key HEAD $(short "$head") != pin $(short "$commit")"
			elif [ "$mode" = git ] && [ "$dirty" != 0 ]; then
				fail "$key 工作区有 $dirty 处本地改动（mode=git 要求干净）"
			elif [ "$mode" = manual ]; then
				pass "$key HEAD $(short "$head") == pin（manual，本地改动 $dirty 处，符合预期）"
			else
				pass "$key HEAD $(short "$head") == pin，工作区干净"
			fi
			continue
		fi

		# ---- fetch ----
		if [ "$mode" = manual ]; then
			if [ "$match" = 1 ]; then
				skip "$key mode=manual，不自动改写（HEAD 已符合 pin，本地改动 $dirty 处）"
			else
				fail "$key mode=manual 且 HEAD $(short "$head") != pin $(short "$commit")，需人工处理"
			fi
			continue
		fi

		if [ "$dirty" != 0 ]; then
			if [ "$FORCE" != 1 ]; then
				fail "$key 工作区有 $dirty 处本地改动，拒绝覆盖（确认后可加 --force）"
				continue
			fi
			echo "WARN  $key 丢弃 $dirty 处本地改动（--force）"
			git -C "$dir" reset -q --hard
		fi

		if [ "$match" = 1 ]; then
			pass "$key 已是 $(short "$commit")，无需联网"
			continue
		fi

		printf 'FETCH %s %s -> %s\n' "$key" "$(short "$head")" "$(short "$commit")"
		if git -C "$dir" fetch -q --depth 1 origin "$commit" \
			&& git -C "$dir" checkout -q --detach FETCH_HEAD; then
			head=$(git -C "$dir" rev-parse HEAD)
			case "$head" in
			"$commit"*) pass "$key 已更新到 $(short "$head")" ;;
			*) fail "$key 更新后 HEAD $(short "$head") 仍不等于 pin" ;;
			esac
		else
			fail "$key 无法获取提交 $commit（网络或仓库策略）"
		fi

	;;
	link)
		[ "$#" -eq 3 ] || { fail "link 行字段数不对: $raw"; continue; }
		name=$1; key=$2; sub=$3

		# 找到 key 对应的 vendor-dir（只允许引用前面出现过的 repo）
		vdir=$(awk -v k="$key" '$1=="repo" && $2==k {print $6}' "$CONF")
		[ -n "$vdir" ] || { fail "link $name 引用了未定义的 repo: $key"; continue; }
		if [ "$sub" = . ]; then target="$vdir"; else target="$vdir/$sub"; fi

		if [ "$CMD" = check ]; then
			check_link "$name" "$target"
		else
			relink "$name" "$target"
			pass "link $name -> ../$target"
		fi
	;;
	local)
		[ "$#" -eq 2 ] || { fail "local 行字段数不对: $raw"; continue; }
		name=$1; path=$2
		if [ -e "$SOURCES/$path" ]; then
			if [ "$CMD" = check ]; then
				check_link "$name" "$path"
			else
				relink "$name" "$path"
				pass "link $name -> ../$path（local）"
			fi
		else
			fail "$name 的本地目录不存在: $path"
		fi
	;;
	*)
		fail "无法识别的行: $raw"
	;;
	esac
done < "$CONF"

# passwall-selected 是 feeds.conf 里的独立 src-link（不在 thirdparty-feed 下），
# 人工剪裁、无 .git，只能做存在性检查。
if [ -d "$SOURCES/passwall-selected" ] && [ -n "$(ls -A "$SOURCES/passwall-selected" 2>/dev/null)" ]; then
	pass "passwall-selected 目录存在且非空（人工剪裁，UNVERIFIED 内容）"
else
	fail "passwall-selected 目录缺失或为空"
fi

echo
if [ "$FAILS" -ne 0 ]; then
	echo "结果: FAIL（$FAILS 项）"
	exit 1
fi
echo "结果: PASS"
if [ "$CMD" = fetch ]; then
	echo "提示: 源码内容已按 pin 就位；如需让 buildroot 重新扫描，运行"
	echo "      ./24.10-6.6/build/sbe1v1k-build.sh defconfig"
	echo "      注意 CI 使用 sources-v1 Release 的源码包，本地改动需重新导出上传。"
fi
