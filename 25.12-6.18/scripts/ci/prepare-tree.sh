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
#   3. 安装 19 个第三方插件（fetch-plugins.sh，默认每次解析最新版本 tag；
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

# 19 个第三方插件（13 个自维护 + passwall/nikki/openclash/mosdns/argon）。
# 默认在每次构建时解析各仓库最新版本 tag；只有新提交是 thirdparty-pins.conf
# 里 pin 的后代才采用，分叉/回退/远端不可达都保持 pin（不中断构建）。
# 必须在 feeds install 之后：脚本按 package/feeds/* 检查同名冲突。
echo "[prepare] 安装第三方插件（SBE_PLUGIN_MODE=${SBE_PLUGIN_MODE:-latest}）"
"$SELF/fetch-plugins.sh" "$ROOT"
[ -s "$BR/.sbe-plugins.tsv" ] \
	|| { echo "[prepare] 插件安装没有产出 $BR/.sbe-plugins.tsv" >&2; exit 1; }

echo "[prepare] 应用本树补丁"
if compgen -G "$PROJ/patches/*.patch" >/dev/null; then
	# 幂等重放：先按逆序把已应用的项目补丁撤掉，再正序统一应用。
	# 单个补丁的 reverse dry-run 不可靠——后序补丁（如 0036/0039/0040）
	# 会改在 0031 创建的文件上，此时 0031 的反向试运行已经匹配不上，
	# 但整条链的反向重放（逆序）是精确的。对未应用的补丁，patch 检测到
	# 「Unreversed patch」会跳过且不改文件。撤不动的直接留给正序阶段报错。
	mapfile -t _patches < <(ls "$PROJ"/patches/*.patch | sort)
	for ((i = ${#_patches[@]} - 1; i >= 0; i--)); do
		( cd "$BR" && patch -p1 --fuzz=0 -s -R < "${_patches[i]}" ) >/dev/null 2>&1 || true
	done
	for p in "${_patches[@]}"; do
		( cd "$BR" && patch -p1 --fuzz=0 -s --dry-run < "$p" ) >/dev/null 2>&1 \
			|| { echo "[prepare] 补丁与树不匹配：$(basename "$p")" >&2; exit 1; }
		( cd "$BR" && patch -p1 --fuzz=0 -s < "$p" ) \
			|| { echo "[prepare] 补丁应用失败：$(basename "$p")" >&2; exit 1; }
		echo "[prepare]   应用：$(basename "$p")"
	done
else
	echo "[prepare]   无补丁"
fi
# patch 反向应用时会在被撤文件旁留 .orig 备份；撤+放成对执行后它是陈旧
# 产物（如 dts 目录里的 ipq9570-sbe1v1k-nss.dts.orig），清掉避免混进源码树。
find "$BR" -name '*.orig' -type f -delete 2>/dev/null || true

# overlay 只在本阶段存在时才拷贝；Stage 1 基线保持上游原样。
if [ -d "$PROJ/files" ] && [ -n "$(ls -A "$PROJ/files" 2>/dev/null)" ]; then
	echo "[prepare] 拷贝 files/ overlay"
	cp -a "$PROJ/files/." "$BR/files/"
fi

# NSS（S3a–S3d）：QSDK 包定义 + 厂商源码装进装配树。本树唯一的设备镜像
# 带这 12 个包（运行期仍由 /usr/lib/sbe1v1k/nss-board 按设备树把关），
# 所以 CI 必须装配，不能像 S3a 时那样“缺源码就跳过”。
#
# 厂商源码不在仓库里（QSDK 厂商树数十 GB 不入库）。来源优先级：
#   SBE_NSS_BASE（打平的已解包目录）→ 本地 sources/buildroot 厂商树 →
#   本地缓存 → 现场自产。
# 自产方式与 6.12 相同：对 QSDK 基座做 blob:none 稀疏克隆，只检出
# qca/src/nss，用 scripts/ci/export-nss-src.sh 重打 tar.gz，并与提交进
# 仓库的 nss/nss-src.tar.gz.sha256 逐字节比对。CI 不需要人工上传的
# Release 资产，校验强度不变（哈希相同）。
NSS_SHA_FILE=$PROJ/nss/nss-src.tar.gz.sha256
NSS_CACHE=$ROOT/.sbe-cache
NSS_QSDK_URL=${SBE_NSS_QSDK_URL:-https://github.com/everything411/qsdk}
NSS_QSDK_COMMIT=${SBE_NSS_QSDK_COMMIT:-21a8d13393aa8c7d2abf806e62a8dac2ba7af52f}

echo "[prepare] 接入 NSS 源码"
nss_flat=
if [ -n "${SBE_NSS_BASE:-}" ]; then
	echo "[prepare]   使用 SBE_NSS_BASE=$SBE_NSS_BASE"
	nss_flat=$SBE_NSS_BASE
elif [ -d "$ROOT/sources/buildroot/qca/src/nss/base" ]; then
	echo "[prepare]   使用本地厂商树 $ROOT/sources/buildroot/qca/src/nss"
elif [ -d "$NSS_CACHE/nss-src-v1/qca-ssdk" ] && \
     [ -d "$NSS_CACHE/nss-src-v1/qca-ssdk-shell" ]; then
	# 缓存必须是含 qca-ssdk-shell 的版本：旧缓存没有 apps-oss，
	# install.sh 会跳过源码，qca-ssdk-shell 编译必失败。
	echo "[prepare]   复用 $NSS_CACHE/nss-src-v1"
	nss_flat=$NSS_CACHE/nss-src-v1
else
	[ -f "$NSS_SHA_FILE" ] || { echo "[prepare] 缺少 $NSS_SHA_FILE" >&2; exit 1; }
	echo "[prepare]   从 qsdk 基座自产 NSS 源码包（稀疏检出 qca/src/nss @ ${NSS_QSDK_COMMIT:0:12}）"
	mkdir -p "$NSS_CACHE"
	nss_work=$(mktemp -d "$NSS_CACHE/gen.XXXXXX")
	nss_clone=$nss_work/qsdk
	export GIT_TERMINAL_PROMPT=0
	git init -q "$nss_clone"
	git -C "$nss_clone" remote add origin "$NSS_QSDK_URL"
	git -C "$nss_clone" config core.sparseCheckout true
	git -C "$nss_clone" config core.sparseCheckoutCone true
	# cone 模式必须逐级写出父目录的“重新包含”行。只写 /qca/src/nss/ 时
	# git 会把整棵树都当成稀疏外（实测 checkout 出 0 个文件）；下面六行与
	# `git sparse-checkout set --cone qca/src/nss` 生成的内容逐字一致，只是
	# 提前到 fetch 之前写，避免先落全树再删。
	mkdir -p "$nss_clone/.git/info"
	cat > "$nss_clone/.git/info/sparse-checkout" <<'EOF'
/*
!/*/
/qca/
!/qca/*/
/qca/src/
!/qca/src/*/
/qca/src/nss/
EOF
	git -c protocol.version=2 -C "$nss_clone" fetch --quiet --depth 1 \
		--filter=blob:none origin "$NSS_QSDK_COMMIT" \
		|| { echo "[prepare] 取不到 qsdk 基座 $NSS_QSDK_COMMIT（SOURCE_UNAVAILABLE）" >&2; rm -rf "$nss_work"; exit 1; }
	git -C "$nss_clone" checkout --quiet --detach FETCH_HEAD
	got=$(git -C "$nss_clone" rev-parse HEAD)
	[ "$got" = "$NSS_QSDK_COMMIT" ] \
		|| { echo "[prepare] qsdk 基座 HEAD 不符：$got（PIN_MISMATCH）" >&2; rm -rf "$nss_work"; exit 1; }
	for d in base/qca-ssdk base/qca-nss-phy base/qca-nss-dp base/qca-nss-ppe \
	         clients/qca-nss-ecm clients/qca-nss-ae-clients clients/qca-nss-sfe \
	         apps-oss/qca-ssdk-shell; do
		[ -d "$nss_clone/qca/src/nss/$d" ] \
			|| { echo "[prepare] 稀疏检出缺少 qca/src/nss/$d" >&2; rm -rf "$nss_work"; exit 1; }
	done
	SBE_NSS_SRC_BASE="$nss_clone/qca/src/nss/base" \
	SBE_NSS_SRC_CLIENTS="$nss_clone/qca/src/nss/clients" \
	SBE_NSS_SRC_APPS="$nss_clone/qca/src/nss/apps-oss" \
		"$SELF/export-nss-src.sh" "$nss_work/out" \
		|| { echo "[prepare] NSS 源码包自产失败" >&2; rm -rf "$nss_work"; exit 1; }
	cp "$NSS_SHA_FILE" "$nss_work/out/nss-src.tar.gz.sha256"
	( cd "$nss_work/out" && sha256sum -c nss-src.tar.gz.sha256 ) \
		|| { echo "[prepare] NSS 源码包自产结果与 nss-src.tar.gz.sha256 不一致（源码已漂移）" >&2
		     rm -rf "$nss_work"; exit 1; }
	tar -C "$NSS_CACHE" -xzf "$nss_work/out/nss-src-v1.tar.gz"
	rm -rf "$nss_work"
	nss_flat=$NSS_CACHE/nss-src-v1
fi
if [ -n "$nss_flat" ]; then
	SBE_NSS_BASE=$nss_flat SBE_BUILDROOT=$BR "$PROJ/nss/install.sh" "$ROOT"
else
	SBE_BUILDROOT=$BR "$PROJ/nss/install.sh" "$ROOT"
fi
# 装配完整性断言：包目录与关键源码都必须进树。缺任何一件，
# check-packages.sh index 会把对应的 NSS 包报成“索引里没有”，但到那时
# 已经浪费了一次 prepare；这里提前失败并指名。
for d in "$PROJ"/nss/packages/*/; do
	_p=$(basename "$d")
	[ -f "$BR/package/feeds/nss/$_p/Makefile" ] \
		|| { echo "[prepare] NSS 装配不完整：缺少 package/feeds/nss/$_p/Makefile" >&2; exit 1; }
done
for f in "$BR/qca/src/nss/base/qca-ssdk/src/init/ssdk_clk.c" \
         "$BR/qca/src/nss/base/qca-nss-dp/nss_dp_main.c" \
         "$BR/qca/src/nss/base/qca-nss-ppe/Makefile" \
         "$BR/qca/src/nss/clients/qca-nss-ecm/Makefile" \
         "$BR/qca/src/nss/apps-oss/qca-ssdk-shell/Makefile"; do
	[ -e "$f" ] || { echo "[prepare] NSS 装配不完整：缺少 $f" >&2; exit 1; }
done

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
