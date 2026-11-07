#!/usr/bin/env bash
# 把插件 pin 解析到“最新版本”，并只读检测 CodeLinaro 6.6 内核。
#
# 用法：
#   scripts/ci/refresh-pins.sh                 只检查，打印 old→new 与内核结论
#   scripts/ci/refresh-pins.sh --apply         就地改写 pin 文件（原行、原顺序、原注释）
#   scripts/ci/refresh-pins.sh --report FILE   同时把变更表与内核结论写成 markdown
#   scripts/ci/refresh-pins.sh --no-kernel     跳过内核检测（离线/省时间）
#   scripts/ci/refresh-pins.sh --kernel-only   只做内核检测
#
# 范围：build/upstream-pins.conf 的 apps/* 行 + build/thirdparty-feeds.conf 的
# repo 行。内核行（buildroot/qca/src/linux-6.6）**永不改写**——它属于审计对象，
# 升级等于重做一次静态审计，只能人工批准后走 scripts/check-kernel.sh。
#
# 口径（用户 2026-11-07 选定）：
#   - 有 semver 形态 release tag 的仓库：取版本序最大的 tag；**不回退**——
#     该 tag 相对当前 pin 是 behind/identical/diverged 时保持不动（tag 比分支头
#     旧，例如 nikki / OpenClash / bandix；或干脆分叉）；
#   - 没有版本 tag 的仓库：取默认分支头（例如 passwall-packages）；
#   - 远端读不到（无网、限流、仓库改名）→ 该行保持不动并告警，绝不猜。
#
# 退出码：0 没有可应用的 pin 变化；2 有变化（--apply 写完也返回 0）；
#         3 BLOCKED（内核检测读不到远端）；4 参数/输入文件错误。
# 不联网上传、不接触设备、不写入口令。令牌只经 curl -K - 从 stdin 传入，
# 不出现在命令行参数里。
#
# 背景：为什么“只开 PR、不自动合并”：pin 变了就可能带上新的构建依赖或坏版本，
# 装配门禁（指纹/冻结配置/逐包反查）必须在 PR 上跑一遍，人看过再合。

set -Eeuo pipefail
LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)     # <repo>/24.10-6.6
PINS="$PROJ/build/upstream-pins.conf"
TPCONF="$PROJ/build/thirdparty-feeds.conf"
PROV="$PROJ/docs/package/PROVENANCE.md"
KAPI=${SBE_KERNEL_API:-https://git.codelinaro.org/api/v4/projects/clo%2Fqsdk%2Foss%2Fkernel%2Flinux-ipq-6.6}
KSLEEP=${SBE_KERNEL_SLEEP:-0.4}

APPLY=0; REPORT=""; DO_KERNEL=1; ONLY_KERNEL=0
while [ $# -gt 0 ]; do
	case "$1" in
	--apply)       APPLY=1; shift ;;
	--report)      REPORT=${2:?--report 需要文件}; shift 2 ;;
	--no-kernel)   DO_KERNEL=0; shift ;;
	--kernel-only) ONLY_KERNEL=1; shift ;;
	-h|--help)     sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)             echo "未知参数: $1" >&2; exit 4 ;;
	esac
done

for f in "$PINS" "$TPCONF"; do
	[ -f "$f" ] || { echo "缺少 $f" >&2; exit 4; }
done
command -v git >/dev/null || { echo "缺少 git" >&2; exit 4; }
command -v python3 >/dev/null || { echo "缺少 python3" >&2; exit 4; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sbe-refresh.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

CHANGES="$WORK/changes.tsv"     # file <TAB> old <TAB> new <TAB> name
SKIPS="$WORK/skips.tsv"         # name <TAB> 原因
: > "$CHANGES"; : > "$SKIPS"

say()  { printf '%s\n' "$*" >&2; }
warn() { printf 'WARN  %s\n' "$*" >&2; }

# ------------------------------------------------------------------ 远端查询
# remote_tags <url>：版本形态的 tag，一行 "<tag>\t<sha>"，按版本序升序。
# 注解 tag 在 ls-remote 里是一个 tag 对象，必须取 peeled 的 ^{} 才是 commit，
# 否则和 pin 比对时永远不相等（会被误判成“无法判定”而永远不更新）。
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

# remote_head <url>：默认分支头 sha（读不到则空）
remote_head() {
	git ls-remote --symref "$1" HEAD 2>/dev/null \
		| awk '$2 == "HEAD" && $1 ~ /^[0-9a-f]{40}$/ {print $1; exit}'
}

# github_compare <url> <pin> <sha>：ahead|behind|identical|diverged|unknown
# 只对 github.com 生效。走 compare API 而不是日期或克隆：win 在分支头、
# tag 在历史里这类情况，只有祖先关系能给出确定答案。
github_compare() {
	local url=$1 base=$2 head=$3 repo o r cfg out
	case "$url" in
	https://github.com/*) ;;
	*) echo unknown; return 0 ;;
	esac
	repo=${url#https://github.com/}; repo=${repo%.git}
	o=${repo%%/*}; r=${repo#*/}
	cfg="url = \"https://api.github.com/repos/$o/$r/compare/$base...$head\""
	cfg="$cfg"$'\n'"header = \"Accept: application/vnd.github+json\""
	cfg="$cfg"$'\n'"header = \"X-GitHub-Api-Version: 2022-11-28\""
	# 令牌从 stdin 传进 curl 配置，避免出现在 argv / 进程列表 / 日志里。
	local tok=${GH_TOKEN:-${GITHUB_TOKEN:-}}
	if [ -n "$tok" ]; then
		printf '%s\nheader = "Authorization: Bearer %s"\n' "$cfg" "$tok" \
			| curl -fsS -K - -o "$WORK/cmp.json" 2>/dev/null || { echo unknown; return 0; }
	else
		printf '%s\n' "$cfg" \
			| curl -fsS -K - -o "$WORK/cmp.json" 2>/dev/null || { echo unknown; return 0; }
	fi
	python3 -I - "$WORK/cmp.json" <<'PY' 2>/dev/null || echo unknown
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    print(d.get("status", "unknown"))
except Exception:
    print("unknown")
PY
}

# pick_latest <url>：输出 "tag<TAB>sha" 或 "HEAD<TAB>sha" 或空
pick_latest() {
	local url=$1 last head
	last=$(remote_tags "$url" | tail -n 1)
	if [ -n "$last" ]; then
		printf '%s\n' "$last"
		return 0
	fi
	head=$(remote_head "$url")
	[ -n "$head" ] && printf 'HEAD\t%s\n' "$head"
}

# decide <name> <url> <pin>：输出 "newsha" 表示要改；否则空，并把原因记进 SKIPS
decide() {
	local name=$1 url=$2 pin=$3 pick tag sha st
	pick=$(pick_latest "$url")
	if [ -z "$pick" ]; then
		printf '%s\t远端读不到（ls-remote 失败或仓库不存在）\n' "$name" >> "$SKIPS"
		return 0
	fi
	tag=${pick%%$'\t'*}; sha=${pick##*$'\t'}
	if [ "$sha" = "$pin" ]; then
		return 0
	fi
	if [ "$tag" = HEAD ]; then
		printf '%s\n' "$sha"    # 无版本 tag 的仓库：跟默认分支头
		return 0
	fi
	st=$(github_compare "$url" "$pin" "$sha")
	case "$st" in
	ahead)     printf '%s\n' "$sha" ;;
	behind)    printf '%s\t不回退：pin 已在 tag %s 之后（分支头更新）\n' "$name" "$tag" >> "$SKIPS" ;;
	identical) : ;;
	diverged)  printf '%s\t分叉：pin 与 tag %s 无祖先关系，需人工判断\n' "$name" "$tag" >> "$SKIPS" ;;
	*)         printf '%s\t无法判定 pin 与 tag %s 的祖先关系（API 不可用），保持不动\n' "$name" "$tag" >> "$SKIPS" ;;
	esac
}

# ------------------------------------------------------------------ pin 文件
# 改 apps/* 行：制表符分列，只换第 3 列。
apply_pin_line() { # <dest> <old> <new>
	python3 -I - "$PINS" "$1" "$2" "$3" <<'PY'
import sys
path, dest, old, new = sys.argv[1:5]
with open(path, encoding="utf-8") as f:
    lines = f.read().split("\n")
out, hit = [], 0
for line in lines:
    if line.startswith(dest + "\t") and not line.startswith("#"):
        parts = line.split("\t")
        if len(parts) >= 5 and parts[2] == old:
            parts[2] = new
            line = "\t".join(parts)
            hit += 1
    out.append(line)
if hit != 1:
    sys.exit("pin 行匹配失败：%s（命中 %d 次）" % (dest, hit))
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(out))
PY
}

# 改文件 A 的 repo 行：列间用空格对齐，只换那个 40 位 commit 记号。
apply_tp_line() { # <old> <new>
	python3 -I - "$TPCONF" "$1" "$2" <<'PY'
import re, sys
path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    lines = f.read().split("\n")
out, hit = [], 0
for line in lines:
    if not line.lstrip().startswith("#") and re.match(r"^\s*repo\s", line):
        if old in line.split():
            line, n = re.subn(r"(?<!\S)" + old + r"(?!\S)", new, line, count=1)
            hit += n
    out.append(line)
if hit != 1:
    sys.exit("文件 A 的 repo 行匹配失败：%s（命中 %d 次）" % (old, hit))
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(out))
PY
}

record() { # <file> <old> <new> <name>
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$CHANGES"
	say "  UPDATE $4  ${2:0:12} → ${3:0:12}"
}

scan_apps() {
	local d u c m n new
	while IFS=$'\t' read -r d u c m n; do
		[ -n "${d:-}" ] || continue
		case "$d" in \#*) continue ;; esac
		case "$d" in apps/*) ;; *) continue ;; esac
		new=$(decide "$d" "$u" "$c")
		[ -n "$new" ] || continue
		record pins "$c" "$new" "$d"
		[ "$APPLY" = 1 ] && apply_pin_line "$d" "$c" "$new"
	done < "$PINS"
}

scan_tp() {
	local kw key u br c vdir mode new
	while read -r kw key u br c vdir mode; do
		[ "${kw:-}" = repo ] || continue
		new=$(decide "$key" "$u" "$c")
		[ -n "$new" ] || continue
		record tp "$c" "$new" "$key"
		[ "$APPLY" = 1 ] && apply_tp_line "$c" "$new"
	done < "$TPCONF"
}

# ------------------------------------------------------------------ 内核检测
# 当前 6.6.<N> 从 build-fixes 的 0002 补丁名读取（CI 的 checkout 里没有源码树）；
# 有源码树时以 include/kernel-6.6 为准（check-kernel.sh 的同一条规则）。
current_kernel() {
	local inc=$PROJ/../sources/buildroot/include/kernel-6.6 sub
	if [ -f "$inc" ]; then
		sub=$(sed -n 's/^LINUX_VERSION-6\.6 = \.\([0-9]*\).*/\1/p' "$inc" | head -n 1)
		[ -n "$sub" ] && { printf '%s\n' "$sub"; return 0; }
	fi
	local p
	p=$(ls "$PROJ"/build/build-fixes/0002-kernel-6.6-report-6.6.*.patch 2>/dev/null | head -n 1)
	[ -n "$p" ] || return 0
	printf '%s\n' "$p" | sed -n 's/.*report-6\.6\.\([0-9]*\)\.patch$/\1/p'
}

kernel_get() { # <path> <out>
	local cfg="url = \"$KAPI$1\""
	printf '%s\n' "$cfg" | curl -fsS -K - -o "$2" 2>/dev/null
}

# 输出 markdown 行到 stdout：结论 + 候选版本
kernel_check() {
	local cur sub max=0 maxref="" refs name subf
	cur=$(current_kernel)
	if ! kernel_get "/repository/branches?per_page=100" "$WORK/branches.json"; then
		say "BLOCKED 读不到 $KAPI/repository/branches"
		return 3
	fi
	python3 -I - "$WORK/branches.json" <<'PY' > "$WORK/refs" 2>/dev/null || true
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for b in d:
    n = b.get("name", "")
    if n.startswith("win_qsdk.common.1.0.r"):
        print(n)
PY
	refs=$(wc -l < "$WORK/refs")
	if [ "$refs" = 0 ]; then
		say "BLOCKED 分支列表里没有 win_qsdk.common.1.0.r* 候选"
		return 3
	fi
	while IFS= read -r name; do
		kernel_get "/repository/files/Makefile/raw?ref=$(python3 -I -c \
			'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$name")" \
			"$WORK/Makefile" || { sleep "$KSLEEP"; continue; }
		sub=$(sed -n 's/^SUBLEVEL = \([0-9]*\)$/\1/p' "$WORK/Makefile" | head -n 1)
		if [ -n "$sub" ] && [ "$sub" -gt "$max" ]; then max=$sub; maxref=$name; fi
		sleep "$KSLEEP"
	done < "$WORK/refs"
	if [ -z "$cur" ]; then
		printf 'UNVERIFIED 读不到当前内核版本（include/kernel-6.6 与 0002 补丁都不在），候选最高 6.6.%s（%s）\n' "$max" "$maxref"
		return 0
	fi
	if [ "$max" -gt "$cur" ]; then
		printf 'UNVERIFIED 检测到 6.6.%s（%s），当前 pin 是 6.6.%s：需人工评估（内核与 files-6.6/patches-6.6/QSDK 14.0 耦合，升级等于重新审计）。本脚本不会改内核 pin。\n' \
			"$max" "$maxref" "$cur"
	else
		printf 'PASS 内核 6.6.%s 已是 win_qsdk.common.1.0.r* 家族最高（扫描 %s 个分支，最高 6.6.%s @ %s）\n' \
			"$cur" "$refs" "$max" "$maxref"
	fi
	return 0
}

# ------------------------------------------------------------------ PROVENANCE
# 在 <!-- pins:begin -->…<!-- pins:end --> 之间重写机器可读的 pin 快照，
# 让 PR diff 里直接看得到“哪些提交变了”。
sync_provenance() {
	[ -f "$PROV" ] || return 0
	python3 -I - "$PROV" "$PINS" "$TPCONF" <<'PY'
import sys
prov, pins, tp = sys.argv[1:4]
def rows_pins():
    out = []
    with open(pins, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            p = line.split("\t")
            if len(p) >= 5 and p[0].startswith("apps/"):
                out.append((p[0], p[2], p[4]))
    return out
def rows_tp():
    out = []
    with open(tp, encoding="utf-8") as f:
        for line in f:
            w = line.split()
            if len(w) >= 7 and w[0] == "repo":
                out.append(("repo " + w[1], w[4], w[5]))
    return out
body = ["| 仓库 | commit | 备注 |", "| --- | --- | --- |"]
for name, sha, note in sorted(rows_pins() + rows_tp()):
    body.append("| `%s` | `%s` | %s |" % (name, sha, note))
text = open(prov, encoding="utf-8").read()
b, e = "<!-- pins:begin -->", "<!-- pins:end -->"
i, j = text.find(b), text.find(e)
if i < 0 or j < 0 or j < i:
    sys.exit("PROVENANCE.md 缺少 pins:begin/pins:end 标记")
new = text[:i] + b + "\n" + "\n".join(body) + "\n" + text[j:]
if new != text:
    open(prov, "w", encoding="utf-8").write(new)
    print("PROVENANCE pin 块已更新")
PY
}

# ================================================================== main
say "== 扫描 pin（apps/* 与文件 A 的 repo 行）"
if [ "$ONLY_KERNEL" != 1 ]; then
	scan_apps
	scan_tp
	[ "$APPLY" = 1 ] && sync_provenance >&2 || true
fi

KRC=0
KLINE=""
if [ "$DO_KERNEL" = 1 ]; then
	say "== 内核检测（只读）"
	KLINE=$(kernel_check) || KRC=$?
	[ -n "$KLINE" ] && say "  $KLINE"
fi

NCH=$(wc -l < "$CHANGES")
NSK=$(wc -l < "$SKIPS")
say "== 结果：可更新 $NCH 项，保持不动 $NSK 项，内核 $([ "$KRC" = 0 ] && echo '已检查' || echo 'BLOCKED')"

if [ -n "$REPORT" ]; then
	{
		printf '## 内核\n\n%s\n' "${KLINE:-（未检测）}"
		printf '\n## pin 刷新\n\n'
		if [ "$NCH" = 0 ]; then
			printf '没有插件需要更新（所有 pin 已是最新）。\n'
		else
			printf '| 仓库 | 原 commit | 新 commit |\n| --- | --- | --- |\n'
			while IFS=$'\t' read -r _f old new name; do
				printf '| `%s` | `%s` | `%s` |\n' "$name" "$old" "$new"
			done < "$CHANGES"
		fi
		if [ "$NSK" -gt 0 ]; then
			printf '\n保持不动的项：\n\n'
			while IFS=$'\t' read -r name why; do
				printf -- '- `%s`：%s\n' "$name" "$why"
			done < "$SKIPS"
		fi
		printf '\n合并本 PR 后：push 会触发 `sources-24.10-6.6.yml` 装配验证；'
		printf '通过后需手动以 `publish=true` 重发 `sources-vN`，`build-24.10-6.6.yml`'
		printf '的 `source_tag=auto` 才会用到新 pin。**本 PR 不会被自动合并。**\n'
	} > "$REPORT"
	say "  报告写入 $REPORT"
fi

if [ "$KRC" != 0 ] && [ "$NCH" = 0 ]; then
	exit 3
fi
[ "$NCH" -gt 0 ] && [ "$APPLY" != 1 ] && exit 2
exit 0
