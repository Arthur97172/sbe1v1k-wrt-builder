#!/usr/bin/env bash
# 在 CI 工作区里把解包后的装配树调整成可编译的状态。
#
# 源码包（sources-vN）由 scripts/ci/assemble-sources.sh 在 CI 里现场装配，
# 其中的 feeds.conf、feeds/ 软链与 package/feeds 软链**全部是根内相对路径**，
# 所以这里不再需要把宿主绝对路径改写成工作区路径——旧版脚本做的那一类改写
# 已经没有对象了。
#
# 本脚本只做两件事，其余交给装配与指纹两道门禁：
#   1. 重建 build/host-bin：仓库不提交这些软链（本机指向 /usr/bin/gnu*，
#      Ubuntu runner 上没有这些名字），这里按 host-shims.txt 指向 /usr/bin/<name>；
#   2. 写入 version.date，把 SOURCE_DATE_EPOCH 固定为 1792557977
#      （2026-10-21T04:46:17Z），否则 scripts/get_source_date_epoch.sh 会退回
#      “脚本 mtime”，每次检出都不同。
#
# 另外做几条便宜的残留检查：树里不该有 /home/ 绝对引用，设备树与升级脚本
# 必须是本仓库维护的版本（它们已由 assembly-map 装进树里，指纹门禁也覆盖了，
# 这里再断一次是为了在编译前就给出可读的失败原因）。
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
EPOCH=${SBE_SOURCE_DATE_EPOCH:-1792557977}

[ -d "$BR" ] || { echo "缺少装配树：$BR" >&2; exit 1; }
[ -f "$PROJ/build/host-shims.txt" ] || { echo "缺少 $PROJ/build/host-shims.txt" >&2; exit 1; }
[ -f "$BR/.config" ] || { echo "缺少 $BR/.config（源码包里应已带冻结配置）" >&2; exit 1; }

echo "[prepare] 残留绝对路径检查"
if grep -rq '/home/' "$BR/feeds.conf" "$BR/feeds" 2>/dev/null; then
	echo "[prepare] FAIL：feeds.conf 或 feeds/ 下仍有 /home/ 绝对引用" >&2
	exit 1
fi

echo "[prepare] 设备树与升级脚本检查"
DTS="$BR/target/linux/feeds/files-6.6/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts"
[ -f "$DTS" ] || { echo "[prepare] 缺少设备树 $DTS" >&2; exit 1; }
grep -q '&sdhc_1 {' "$DTS" \
	|| { echo "[prepare] 设备树没有启用 eMMC 的 &sdhc_1 块" >&2; exit 1; }
UPG="$BR/target/linux/feeds/ipq95xx/base-files/lib/upgrade/platform.sh"
[ -f "$UPG" ] || { echo "[prepare] 缺少升级脚本 $UPG" >&2; exit 1; }
sh -n "$UPG" || { echo "[prepare] 升级脚本语法错误：$UPG" >&2; exit 1; }
grep -q '^sbe_detect_slot()' "$UPG" \
	|| { echo "[prepare] 升级脚本缺少槽位探测函数 sbe_detect_slot" >&2; exit 1; }

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

# scripts/getver.sh 优先读树根的 version 文件；它是构建生成物，源码包里不带
# （指纹与导出都排除），缺了 REVISION 会退化成 "unknown"，banner 变成
# (unknown)。审计树里这份文件的内容就是 .config 的 CONFIG_VERSION_CODE，
# 这里按同一条规则重建，保证 banner 仍是 "Version: <NUMBER> (<CODE>)"。
echo "[prepare] 重建 version（取自 CONFIG_VERSION_CODE）"
VCODE=$(sed -n 's/^CONFIG_VERSION_CODE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$BR/.config" | head -n1)
[ -n "$VCODE" ] || { echo "[prepare] .config 里没有 CONFIG_VERSION_CODE，无法重建 version" >&2; exit 1; }
printf '%s\n' "$VCODE" > "$BR/version"
echo "[prepare] version=$VCODE"

echo "[prepare] 完成"
