#!/usr/bin/env bash
# 装配配方的哈希：把所有“决定源码树长什么样”的输入按路径排序后整体取
# SHA-256。它回答的问题是“这份 sources 包是用哪套配方装出来的”，而不是
# “源码树内容是什么”（后者由 tree-fingerprint.sh 负责）。
#
# 范围刻意排除了两类东西：
#   - 24.10-6.6/files/**（overlay 内容）：由 render-overlay.sh 在构建期渲染，
#     改它不需要重装源码；
#   - 校验/构建脚本（verify-image.sh、sbe1v1k-build.sh 等）：不参与装配。
#
# 用法：scripts/ci/recipe-hash.sh [输出文件]
# 无输出文件时把 sha256 打到 stdout。

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)      # <repo>/24.10-6.6
OUT=${1:-}

cd "$PROJ"
LIST=$(
	{
		printf '%s\n' build/upstream-pins.conf
		printf '%s\n' build/assembly-map.conf
		printf '%s\n' build/prune.conf
		printf '%s\n' build/passwall-selected.conf
		printf '%s\n' build/feeds.conf.in
		printf '%s\n' build/feeds-links.conf
		printf '%s\n' build/fingerprint-exclude.conf
		printf '%s\n' build/known-delta.conf
		find build/build-fixes build/luci-patches build/openwrt-patches build/target-feed-fixes \
			build/thirdparty-patches \
			build/config-frozen build/local-packages build/local-relayout build/p-b \
			-type f
		find scripts/ci -maxdepth 1 -type f \
			\( -name 'assemble-sources.sh' -o -name 'tree-fingerprint.sh' \
			   -o -name 'export-sources.sh' \)
	} | LC_ALL=C sort
)

missing=0
while IFS= read -r f; do
	if [ ! -f "$f" ]; then
		echo "[recipe-hash] 缺少装配输入：$f" >&2
		missing=1
	fi
done <<< "$LIST"
[ "$missing" = 0 ] || exit 4

HASH=$(xargs -d '\n' sha256sum <<< "$LIST" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)

echo "[recipe-hash] 输入文件数：$(wc -l <<< "$LIST")" >&2
if [ -n "$OUT" ]; then
	printf '%s\n' "$HASH" > "$OUT"
	echo "[recipe-hash] $HASH -> $OUT" >&2
else
	printf '%s\n' "$HASH"
fi
