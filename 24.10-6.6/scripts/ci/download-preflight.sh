#!/usr/bin/env bash
# 下载预检：源码包里不带 dl/，构建前先 `make -k download` 把所有第三方 tarball
# 取到本地缓存。任何一个包取不到都**在这里**失败，并给出可复制的 DOWNLOAD_FAIL
# 清单，而不是让 `make world` 跑到一半才炸。
#
# 为什么不用 `make download`（不带 -k）：-k 让它把所有失败都走完，一次拿到完整
# 清单；失败仍然以非零退出，不会掩盖问题。
#
# 前置条件：与 check-config.sh 相同（源码树已解包、overlay 已渲染、feeds 就位）。
#
# 用法：scripts/ci/download-preflight.sh [工作区根目录]
# 环境变量：
#   SBE_DL_DIR  下载缓存目录（默认 <buildroot>/dl；CI 里可以指到持久卷）
#   SBE_JOBS    并发数（默认 nproc，最少 2）
#
# 退出码：0 PASS、4 ASSERTION_FAILED（含 DOWNLOAD_FAIL）。

set -Eeuo pipefail
LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)
ROOT=${1:-$(CDPATH= cd -- "$PROJ/.." && pwd)}
BR="$ROOT/sources/buildroot"
LOG="$ROOT/download.log"
FAILS="$ROOT/download-fail.txt"

die() { printf 'FAIL  %s\n' "$*" >&2; exit 4; }
say() { printf '%s\n' "$*" >&2; }

[ -d "$BR" ] || die "缺少 $BR"
[ -f "$BR/.config" ] || die "缺少 $BR/.config（先跑 check-config.sh）"
command -v make >/dev/null || die "缺少 make"

JOBS=${SBE_JOBS:-$(nproc 2>/dev/null || echo 2)}
[ "$JOBS" -ge 2 ] 2>/dev/null || JOBS=2

MAKE_ARGS=(-k -j"$JOBS")
if [ -n "${SBE_DL_DIR:-}" ]; then
	mkdir -p "$SBE_DL_DIR"
	MAKE_ARGS+=("DL_DIR=$SBE_DL_DIR")
fi

say "[download] make -k -j$JOBS download（$BR）"
set +e
( cd "$BR" && make "${MAKE_ARGS[@]}" download ) >"$LOG" 2>&1
rc=$?
set -e

if [ "$rc" != 0 ]; then
	# 失败行形如：make[3]: *** [package/.../Makefile:123: /…/build_dir/…/download] Error 1
	grep -E '^make(\[[0-9]+\])?: \*\*\* ' "$LOG" \
		| sed -e 's/^make\(\[[0-9]*\]\)\?: \*\*\* \[//' -e 's/\].*$//' \
		| LC_ALL=C sort -u > "$FAILS" || true
	say "FAIL  make download 退出码 $rc；失败条目 $(wc -l < "$FAILS") 个"
	if [ -s "$FAILS" ]; then
		say "DOWNLOAD_FAIL 清单（$FAILS）："
		sed 's/^/  /' "$FAILS" >&2
	else
		say "未解析出具体条目，见日志：$LOG"
		tail -n 40 "$LOG" >&2
		: > "$FAILS"
	fi
	exit 4
fi

rm -f "$FAILS"
n=$(find "${SBE_DL_DIR:-$BR/dl}" -type f 2>/dev/null | wc -l | tr -d ' ')
size=$(du -sh "${SBE_DL_DIR:-$BR/dl}" 2>/dev/null | cut -f1)
say "[download] PASS  dl 文件数=$n 体积=$size  日志=$LOG"
