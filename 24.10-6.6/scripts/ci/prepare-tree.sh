#!/usr/bin/env bash
# 在 CI 工作区里把装配树调整成可编译的状态。
#
# 装配树是在 /home/arthur/claude/sbe1v1k-build 下生成的，里面留下了该绝对
# 路径（feeds.conf、feeds/*.tmp/location、feeds 下的 10 个软链）。工作区路径
# 不同，必须重写；否则 feeds 解析会指向不存在的目录。
#
# 同时：
#   - 重建 build/host-bin：仓库不提交这些软链（本机指向 /usr/bin/gnu*，
#     Ubuntu runner 上没有这些名字），这里按 host-shims.txt 指向 /usr/bin/<name>；
#   - 写入 version.date，把 SOURCE_DATE_EPOCH 固定为本地三轮构建使用的
#     1792557977（2026-10-21T04:46:17Z），否则 scripts/get_source_date_epoch.sh
#     会退回“脚本 mtime”，每次检出都不同。
#
# 目录约定：本脚本位于 <repo>/24.10-6.6/scripts/ci/，装配树位于 <repo>/sources。
#
# 用法：scripts/ci/prepare-tree.sh [工作区根目录]
#
# 注意：本脚本会把 host-bin 指向 /usr/bin/<name>，在开发机上执行会破坏
# 指向 /usr/bin/gnu* 的本机垫片，因此只允许在 CI 中运行。

set -euo pipefail

if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "${SBE_CI:-}" != "1" ]; then
	echo "prepare-tree.sh 只用于 CI：请设置 GITHUB_ACTIONS=true 或 SBE_CI=1" >&2
	exit 1
fi

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)          # <repo>/24.10-6.6
ROOT=${1:-$(CDPATH= cd -- "$PROJ/.." && pwd)}       # 工作区根（含 sources/）
BR="$ROOT/sources/buildroot"
OLD=/home/arthur/claude/sbe1v1k-build
EPOCH=${SBE_SOURCE_DATE_EPOCH:-1792557977}

[ -d "$BR" ] || { echo "缺少装配树：$BR" >&2; exit 1; }
[ -f "$PROJ/build/host-shims.txt" ] || { echo "缺少 $PROJ/build/host-shims.txt" >&2; exit 1; }

echo "[prepare] 重写 feeds.conf 绝对路径"
sed -i "s|$OLD|$ROOT|g" "$BR/feeds.conf"

echo "[prepare] 重定向 feeds/ 下的绝对软链"
while IFS= read -r link; do
	target=$(readlink "$link")
	ln -sfn "$ROOT${target#"$OLD"}" "$link"
done < <(find "$BR/feeds" -maxdepth 1 -type l -lname "$OLD/*")

echo "[prepare] 重写 feeds/*.tmp/location"
while IFS= read -r f; do
	sed -i "s|$OLD|$ROOT|g" "$f"
done < <(grep -rl "$OLD" "$BR/feeds" 2>/dev/null || true)

# 源码包 sources-v1 是固定 Release 资产，里面的 DTS 是 2026-10-21 的版本。
# 设备树属于本仓库维护的输入（build/p-b/files 是暂存区，这里是它的 CI 副本），
# 每次构建都用仓库里的版本覆盖装配树里的旧副本；否则改了 DTS 也不会进镜像。
# 落点与 docs/PB_DEVICE_DEFINITION.md 一致：target/linux/feeds/files-6.6 会在
# target feed 解析时被拷进内核树。
echo "[prepare] 用仓库版本覆盖设备树"
DTS=arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts
SRC_DTS="$PROJ/build/p-b/files/$DTS"
DST_DTS="$BR/target/linux/feeds/files-6.6/$DTS"
[ -f "$SRC_DTS" ] || { echo "[prepare] 缺少 $SRC_DTS" >&2; exit 1; }
[ -f "$DST_DTS" ] || { echo "[prepare] 装配树缺少 $DST_DTS" >&2; exit 1; }
cp -f "$SRC_DTS" "$DST_DTS"
cmp -s "$SRC_DTS" "$DST_DTS" || { echo "[prepare] 设备树覆盖失败" >&2; exit 1; }
grep -q '&sdhc_1 {' "$DST_DTS" \
	|| { echo "[prepare] 设备树没有启用 eMMC 的 &sdhc_1 块" >&2; exit 1; }

echo "[prepare] 重建 host-bin（Ubuntu runner 无 gnu* 前缀）"
rm -rf "$PROJ/build/host-bin"
mkdir -p "$PROJ/build/host-bin"
while IFS= read -r name; do
	[ -n "$name" ] || continue
	if [ -x "/usr/bin/$name" ]; then
		ln -sfn "/usr/bin/$name" "$PROJ/build/host-bin/$name"
	else
		echo "[prepare] 缺少宿主机工具：/usr/bin/$name" >&2
		exit 1
	fi
done < "$PROJ/build/host-shims.txt"

echo "[prepare] 固定 SOURCE_DATE_EPOCH=$EPOCH"
printf '%s\n' "$EPOCH" > "$BR/version.date"

echo "[prepare] 残留绝对路径检查"
if grep -rl "$OLD" "$BR/feeds.conf" "$BR/feeds" 2>/dev/null | grep -q .; then
	echo "[prepare] FAIL：仍存在指向 $OLD 的引用" >&2
	exit 1
fi

echo "[prepare] 完成"
