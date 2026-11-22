#!/usr/bin/env bash
# 装配 OpenWrt main（qualcommbe/ipq95xx，Linux 6.18）构建树，作为 25.12-6.18
# 固件的基线。
#
# 为什么是 main 而不是 openwrt-25.12：25.12 发布分支的 qualcommbe 是
# KERNEL_PATCHVER:=6.12；6.18 只存在于 main。main 在本板上的支持已经原生：
#   - 设备定义 askey_sbe1v1k（FitImage + EmmcImage，KERNEL_LOADADDR 0x42200000）
#   - eMMC 升级：platform.sh 的 askey,sbe1v1k 分支写 "0:HLOS" / "rootfs"
#   - PWM 风扇 / PWM LED、RTL8261N（C45）与 QCA8075、ath12k 固件与
#     ipq-wifi-askey_sbe1v1k BDF
# 因此本树第一版不需要任何 openwrt 补丁，也不需要 QSDK blob 包；项目自己的
# 叠加件（默认值、看门狗等）在后续阶段用 files/ overlay 加入。
#
# 步骤：
#   1. 克隆并检出固定的 OPENWRT_SHA（main）；
#   2. feeds update -a，按 feed_sha 检出固定提交，重建索引后 install -a；
#   3. 安装 18 个第三方插件（fetch-plugins.sh，默认每次解析最新版本 tag；
#      SBE_PLUGIN_MODE=pinned 复现旧镜像，SBE_PLUGIN_STRICT=1 时解析失败即
#      中止），结果表写 <装配树>/.sbe-plugins.tsv；
#   4. 把本目录的 files/ overlay 拷进装配树；
#   5. 写 version / version.date。
#
# 用法：scripts/ci/prepare-tree.sh [工作区根目录]
set -euo pipefail

if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "${SBE_CI:-}" != "1" ]; then
	echo "prepare-tree.sh 只用于 CI/本地装配：请设置 GITHUB_ACTIONS=true 或 SBE_CI=1" >&2
	exit 1
fi

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)          # <repo>/25.12-6.18
ROOT=${1:-$(CDPATH= cd -- "$PROJ/.." && pwd)}       # 工作区根（含 sources/）
BR="$ROOT/sources/buildroot-25.12-6.18"
EPOCH=${SBE_SOURCE_DATE_EPOCH:-1792713600}          # 2026-10-23T00:00:00Z

OPENWRT_URL=${OPENWRT_URL:-https://github.com/openwrt/openwrt.git}
OPENWRT_SHA=${OPENWRT_SHA:-0e66e1c7457a6a92d851c23cd47f7c6f69a7455a}

# REVISION 结尾必须是十六进制短 SHA（base-files 的 apk '~' 后缀规则）。
SBE_COMMIT=$(git -C "$PROJ/.." rev-parse --short=8 HEAD 2>/dev/null || true)
[ -n "$SBE_COMMIT" ] || SBE_COMMIT=${OPENWRT_SHA:0:8}
REVISION=${SBE_REVISION:-sbe1v1k-6.18-$SBE_COMMIT}

# 2026-11-22 装配时各 feed 默认分支（master）的 tip。video feed 在 main 上
# 已不在默认集合里（feeds.conf.default 里它的镜像 clone 会失败），本树不需要。
feed_sha() {
	case "$1" in
	luci)      echo f7675c07caf6b129cb8fedb5b683550422978e31 ;;
	packages)  echo be0dbb6e6b09a1729b34f400a712c8d1aea2f321 ;;
	routing)   echo ea8633da9c461a9bdc62a0323439d31180762e03 ;;
	telephony) echo 06feffc2c154993f555b43756ef7db6dd7e58225 ;;
	*)         echo "" ;;
	esac
}

mkdir -p "$ROOT/sources"

if [ ! -d "$BR" ]; then
	echo "[prepare] 克隆 $OPENWRT_URL (main @ $OPENWRT_SHA)"
	git clone --filter=blob:none --no-checkout "$OPENWRT_URL" "$BR"
	git -C "$BR" fetch --depth 1 origin "$OPENWRT_SHA"
	git -C "$BR" checkout -q --detach "$OPENWRT_SHA"
else
	echo "[prepare] 复用已有构建树 $BR"
fi
[ "$(git -C "$BR" rev-parse HEAD)" = "$OPENWRT_SHA" ] \
	|| { echo "[prepare] 构建树 HEAD 不是钉住的 $OPENWRT_SHA" >&2; exit 1; }

if [ ! -f "$BR/feeds.conf" ]; then
	cp "$BR/feeds.conf.default" "$BR/feeds.conf"
	# video feed 的镜像在装配环境里拉不下来，且本树不需要；从配置里去掉，
	# 避免 feeds update -a 每次都失败。
	sed -i '/^src-git video /d' "$BR/feeds.conf"
fi

echo "[prepare] feeds update"
( cd "$BR" && ./scripts/feeds update -a )

echo "[prepare] 检出固定 feed 提交"
for feed in luci packages routing telephony; do
	sha=$(feed_sha "$feed")
	[ -n "$sha" ] || continue
	[ -d "$BR/feeds/$feed/.git" ] || { echo "[prepare] 缺少 feed $feed" >&2; exit 1; }
	echo "[prepare]   $feed@${sha:0:8}"
	git -C "$BR/feeds/$feed" fetch -q --depth 1 origin "$sha"
	git -C "$BR/feeds/$feed" -c advice.detachedHead=false checkout -q "$sha"
done

echo "[prepare] 重建 feed 索引（按固定提交）"
( cd "$BR" && ./scripts/feeds update -i -a )
for feed in luci packages routing telephony; do
	idx="$BR/feeds/$feed.tmp/.packageinfo"
	[ -s "$idx" ] || { echo "[prepare] feed $feed 的索引为空：$idx" >&2; exit 1; }
done

echo "[prepare] feeds install -a"
( cd "$BR" && ./scripts/feeds install -a )

# 18 个第三方插件（12 个自维护 + passwall/nikki/openclash/mosdns/argon）。
# 默认在每次构建时解析各仓库最新版本 tag；只有新提交是 thirdparty-pins.conf
# 里 pin 的后代才采用，分叉/回退/远端不可达都保持 pin（不中断构建）。
# 必须在 feeds install 之后：脚本按 package/feeds/* 检查同名冲突。
echo "[prepare] 安装第三方插件（SBE_PLUGIN_MODE=${SBE_PLUGIN_MODE:-latest}）"
"$SELF/fetch-plugins.sh" "$ROOT"
[ -s "$BR/.sbe-plugins.tsv" ] \
	|| { echo "[prepare] 插件安装没有产出 $BR/.sbe-plugins.tsv" >&2; exit 1; }

echo "[prepare] 应用本树补丁"
if compgen -G "$PROJ/patches/*.patch" >/dev/null; then
	for p in "$PROJ"/patches/*.patch; do
		if ( cd "$BR" && patch -p1 --fuzz=0 -s -R --dry-run < "$p" ) >/dev/null 2>&1; then
			echo "[prepare]   已应用：$(basename "$p")"
		elif ( cd "$BR" && patch -p1 --fuzz=0 -s --dry-run < "$p" ) >/dev/null 2>&1; then
			( cd "$BR" && patch -p1 --fuzz=0 -s < "$p" ) \
				|| { echo "[prepare] 补丁应用失败：$(basename "$p")" >&2; exit 1; }
			echo "[prepare]   应用：$(basename "$p")"
		else
			echo "[prepare] 补丁与树不匹配：$(basename "$p")" >&2
			exit 1
		fi
	done
else
	echo "[prepare]   无补丁"
fi

# overlay 只在本阶段存在时才拷贝；Stage 1 基线保持上游原样。
if [ -d "$PROJ/files" ] && [ -n "$(ls -A "$PROJ/files" 2>/dev/null)" ]; then
	echo "[prepare] 拷贝 files/ overlay"
	cp -a "$PROJ/files/." "$BR/files/"
fi

echo "[prepare] 断言上游支持面"
grep -qx 'KERNEL_PATCHVER:=6.18' "$BR/target/linux/qualcommbe/Makefile" \
	|| { echo "[prepare] qualcommbe 不是 6.18 内核" >&2; exit 1; }
grep -q '^define Device/askey_sbe1v1k$' "$BR/target/linux/qualcommbe/image/ipq95xx.mk" \
	|| { echo "[prepare] 上游没有 askey_sbe1v1k 设备定义" >&2; exit 1; }
grep -qE '^[[:space:]]*askey,sbe1v1k\)$' "$BR/target/linux/qualcommbe/ipq95xx/base-files/lib/upgrade/platform.sh" \
	|| { echo "[prepare] 上游平台脚本没有 askey,sbe1v1k 升级分支" >&2; exit 1; }
grep -q 'ipq-wifi-askey_sbe1v1k' "$BR/target/linux/qualcommbe/image/ipq95xx.mk" \
	|| { echo "[prepare] 设备定义缺少 ipq-wifi-askey_sbe1v1k（无线 BDF）" >&2; exit 1; }
[ -f "$BR/target/linux/qualcommbe/dts/ipq9570-sbe1v1k.dts" ] \
	|| { echo "[prepare] 缺少上游设备树 ipq9570-sbe1v1k.dts" >&2; exit 1; }

# 网口角色（用户 2026-11-22 要求）：2.5G（port@5）= wan，10G（port@6）= lan1。
PL=$(mktemp)
awk '
	/port@5 \{/ { p = 5 }
	/port@6 \{/ { p = 6 }
	/port@[0-9]+ \{/ && !/port@5 \{/ && !/port@6 \{/ { p = 0 }
	/^[[:space:]]*label = / { if (p) print p, $3; p = 0 }
' "$BR/target/linux/qualcommbe/dts/ipq9570-sbe1v1k.dts" > "$PL"
if ! grep -qx '5 "wan";' "$PL" || ! grep -qx '6 "lan1";' "$PL"; then
	rm -f "$PL"
	echo "[prepare] 端口标签不符合要求（2.5G=wan、10G=lan1），补丁 0001 未生效" >&2
	exit 1
fi
rm -f "$PL"

echo "[prepare] 写入 version / version.date"
printf '%s\n' "$REVISION" > "$BR/version"
printf '%s\n' "$EPOCH" > "$BR/version.date"

echo "[prepare] 完成（$REVISION）"
