#!/usr/bin/env bash
# 在 CI 工作区里装配 OpenWrt 25.12 构建树。
#
# 与 24.10-6.6 不同，25.12 Stage 1 不需要私有 QSDK 源码包：上游
# openwrt/openwrt 的 openwrt-25.12 分支已经包含 qualcommbe/ipq95xx
# （Linux 6.12 + PPE 以太网），本项目的改动只有设备定义和 pwm 特性，
# 以补丁形式保存在 25.12-6.12/patches/。
#
# 唯一的例外是 NSS 数据通路：qca-ssdk / qca-nss-phy / qca-nss-dp /
# qca-nss-ppe 的源码来自 QSDK 14.x。它们不再由人工上传的 Release 资产提供：
# 本脚本从 QSDK 基座（everything411/qsdk，固定提交 21a8d133）稀疏检出
# qca/src/nss，用 scripts/ci/export-nss-src.sh 现场重打 nss-src-v1.tar.gz，
# 并与提交进仓库的 25.12-6.12/nss/nss-src.tar.gz.sha256 逐字节比对——
# 不一致即说明上游不再是同一份源码，直接失败。
#
# 步骤：
#   1. 若 sources/buildroot-25.12-6.12 不存在，克隆 openwrt/openwrt 并
#      检出固定的提交（OPENWRT_SHA）；
#   2. 生成 feeds.conf（openwrt-25.12 分支），feeds update 后把每个 feed
#      检出到记录的提交，再 feeds install -a；
#   3. 按顺序应用 25.12-6.12/patches/*.patch；
#   4. 安装本地软件包与 18 个第三方插件（fetch-plugins.sh，默认每次解析
#      最新版本 tag；SBE_PLUGIN_MODE=pinned 复现旧镜像，SBE_PLUGIN_STRICT=1
#      时解析失败即中止），然后自产/复用/解包 NSS 源码并装配；
#   5. 写入 version（REVISION）与 version.date（固定 SOURCE_DATE_EPOCH）；
#   6. 重建 host-bin（Ubuntu runner 上没有 /usr/bin/gnu* 前缀）。
#
# 用法：scripts/ci/prepare-tree.sh [工作区根目录]
# 只允许在 CI 中运行（会改写 host-bin 指向）。

set -euo pipefail

if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "${SBE_CI:-}" != "1" ]; then
	echo "prepare-tree.sh 只用于 CI：请设置 GITHUB_ACTIONS=true 或 SBE_CI=1" >&2
	exit 1
fi

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)          # <repo>/25.12-6.12
ROOT=${1:-$(CDPATH= cd -- "$PROJ/.." && pwd)}       # 工作区根（含 sources/）
BR="$ROOT/sources/buildroot-25.12-6.12"
EPOCH=${SBE_SOURCE_DATE_EPOCH:-1792713600}          # 2026-10-23T00:00:00Z

OPENWRT_URL=${OPENWRT_URL:-https://github.com/openwrt/openwrt.git}
OPENWRT_BRANCH=${OPENWRT_BRANCH:-openwrt-25.12}
OPENWRT_SHA=${OPENWRT_SHA:-f3f5c2e54bf432b444e36b1a77077ff476361825}

# REVISION 必须以十六进制分段结尾：base-files 把版本拼成
# "<COMMITCOUNT>~<REVISION 最后一个 '-' 分段>"，而 apk 3.x 的 '~' 后缀
# 只接受十六进制（sbe1v1k-25.12-stage1 → "~stage1" 会被拒绝）。
REVISION=${SBE_REVISION:-sbe1v1k-25.12-stage1-${OPENWRT_SHA:0:8}}

# feed 提交固定为 2026-10-23 本地装配时 feeds update 的结果。
feed_sha() {
	case "$1" in
	luci)      echo 75a306df84a020c57a631ef5b4c02ace56d93387 ;;
	packages)  echo 4a3574914f881a817f0615f1e9765c589eb9bbe2 ;;
	routing)   echo 48c808034414a2112cf9d5261a20a320e8d0d170 ;;
	telephony) echo 2618106d5846a4a542fdf5809f0d3ed228ce439b ;;
	video)     echo 094bf58da6682f895255a35a84349a79dab4bf95 ;;
	*)         echo "" ;;
	esac
}

mkdir -p "$ROOT/sources"

if [ ! -d "$BR" ]; then
	echo "[prepare] 克隆 $OPENWRT_URL ($OPENWRT_BRANCH)"
	git clone --filter=blob:none --no-checkout "$OPENWRT_URL" "$BR"
	git -C "$BR" fetch --depth 1 origin "$OPENWRT_SHA"
	git -C "$BR" checkout -q --detach "$OPENWRT_SHA"
else
	echo "[prepare] 复用已有构建树 $BR"
fi

if [ ! -f "$BR/feeds.conf" ]; then
	cp "$BR/feeds.conf.default" "$BR/feeds.conf"
fi

echo "[prepare] feeds update"
( cd "$BR" && ./scripts/feeds update -a )

echo "[prepare] 检出固定 feed 提交"
for feed in luci packages routing telephony video; do
	sha=$(feed_sha "$feed")
	[ -n "$sha" ] || continue
	[ -d "$BR/feeds/$feed/.git" ] || {
		echo "[prepare] 缺少 feed $feed" >&2; exit 1; }
	# feeds update 用 --depth 1 克隆当前 tip；固定的提交是更早的历史，浅克隆里
	# 缺它的树对象，直接 checkout 会报 "fatal: unable to read tree"。先按 SHA
	# 浅取一次（已存在时是空操作）；不能只看 commit 对象在不在——树可能缺失。
	echo "[prepare]   $feed@${sha:0:8}"
	git -C "$BR/feeds/$feed" fetch -q --depth 1 origin "$sha"
	git -C "$BR/feeds/$feed" -c advice.detachedHead=false checkout -q "$sha"
done

echo "[prepare] feeds install -a"
( cd "$BR" && ./scripts/feeds install -a )

echo "[prepare] 应用项目补丁"
for p in "$PROJ"/patches/*.patch; do
	[ -e "$p" ] || continue
	echo "[prepare]   $(basename "$p")"
	patch -d "$BR" -p1 --forward --batch < "$p"
done
# patch(1) 只按 hunk 头声明的行数读取：头行写错时会静默截断补丁末尾（0001 曾
# 因此丢掉 endef 与 TARGET_DEVICES，后续补丁才报 context 不匹配）。用设备定义
# 的收尾行做断言，让这种损坏在第一处就失败。
grep -q '^TARGET_DEVICES += spectrum_sbe1v1k$' \
	"$BR/target/linux/qualcommbe/image/ipq95xx.mk" \
	|| { echo "补丁应用不完整：ipq95xx.mk 缺少 spectrum_sbe1v1k 设备" >&2; exit 1; }
# 同一类断言针对 eMMC：设备树没有 &sdhc_1 时，镜像装到真机上必然起不来
# （sdhc_1 在 ipq9574.dtsi 里是 disabled，U-Boot 注入的 root=PARTUUID=
# 解析不到 mmcblk0）。让它在编译前就失败，而不是等 3 小时后再看镜像。
grep -q '^&sdhc_1 {' \
	"$BR/target/linux/qualcommbe/files/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts" \
	|| { echo "补丁应用不完整：设备树没有启用 eMMC 的 &sdhc_1 块" >&2; exit 1; }

# 写入目标同样要在编译前断言。25.12 的 sysupgrade 镜像必须改成 tar 容器
# （emmc_upgrade_tar 只认它），升级脚本必须按当前槽位写 eMMC，设备树必须把
# fstools_ignore_partname=1 传给内核。缺任何一条，镜像要么什么都刷不进去
# （default_do_upgrade 写 mtd 分区 "image"），要么内核与根文件系统落进不同
# 槽位、overlay 跑到别的分区。宁可在这里失败，也不要等 3 小时后再验镜像。
UPG="$BR/target/linux/qualcommbe/ipq95xx/base-files/lib/upgrade/platform.sh"
[ -f "$UPG" ] || { echo "补丁应用不完整：缺少升级脚本 $UPG" >&2; exit 1; }
sh -n "$UPG" || { echo "升级脚本语法错误：$UPG" >&2; exit 1; }
grep -q '^sbe_detect_slot()' "$UPG" \
	|| { echo "补丁应用不完整：升级脚本缺少槽位探测 sbe_detect_slot" >&2; exit 1; }
grep -q 'spectrum,sbe1v1k' "$UPG" \
	|| { echo "补丁应用不完整：升级脚本没有 spectrum,sbe1v1k 分支" >&2; exit 1; }
grep -q 'IMAGE/sysupgrade.bin/squashfs := .*sysupgrade-tar' \
	"$BR/target/linux/qualcommbe/image/ipq95xx.mk" \
	|| { echo "补丁应用不完整：sysupgrade 镜像不是 tar 容器" >&2; exit 1; }
grep -q 'fstools_ignore_partname=1' \
	"$BR/target/linux/qualcommbe/files/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts" \
	|| { echo "补丁应用不完整：设备树没有 fstools_ignore_partname=1" >&2; exit 1; }

echo "[prepare] 安装项目自带软件包"
for d in "$PROJ"/build/local-packages/*/; do
	[ -d "$d" ] || continue
	name=$(basename "$d")
	rm -rf "$BR/package/$name"
	cp -a "$d" "$BR/package/$name"
	echo "[prepare]   package/$name"
done

# 18 个第三方插件（12 个自维护 + passwall/nikki/openclash/bandix/argon）。
# 默认在每次构建时解析各仓库最新版本 tag；只有新提交是 thirdparty-pins.conf
# 里 pin 的后代才采用，分叉/回退/远端不可达都保持 pin（不中断构建）。
# 实际提交记录在 <装配树>/.sbe-plugins.tsv，供 release notes 与日志引用；
# SBE_PLUGIN_MODE=pinned 可精确复现旧镜像。
echo "[prepare] 安装第三方插件（SBE_PLUGIN_MODE=${SBE_PLUGIN_MODE:-latest}）"
"$SELF/fetch-plugins.sh" "$ROOT"
[ -s "$BR/.sbe-plugins.tsv" ] \
	|| { echo "插件安装没有产出 $BR/.sbe-plugins.tsv" >&2; exit 1; }

# NSS 源码不在仓库里（QSDK 厂商树有数十 GB）。默认设备 spectrum_sbe1v1k
# 的 DEVICE_PACKAGES 依赖 kmod-qca-ssdk-nohnat / kmod-qca-nss-dp /
# kmod-qca-nss-ppe，而补丁 0009 又删掉了主线 PPE 节点；不装这几个包，
# 镜像就没有以太网。
#
# 源码来源按优先级：SBE_NSS_BASE（已有解包目录）→ 本地缓存 → 现场自产。
# 自产方式：对 QSDK 基座做 blob:none 部分克隆 + 只检出 qca/src/nss，
# 用 export-nss-src.sh 重打 tar.gz，再与 nss/nss-src.tar.gz.sha256 比对。
# 这样 CI 不再需要任何人工上传的 Release 资产，而校验强度不变（哈希相同）。
NSS_SHA_FILE=$PROJ/nss/nss-src.tar.gz.sha256
NSS_CACHE=$ROOT/.sbe-cache
NSS_QSDK_URL=${SBE_NSS_QSDK_URL:-https://github.com/everything411/qsdk}
NSS_QSDK_COMMIT=${SBE_NSS_QSDK_COMMIT:-21a8d13393aa8c7d2abf806e62a8dac2ba7af52f}

echo "[prepare] 接入 NSS 源码"
mkdir -p "$NSS_CACHE"
if [ -n "${SBE_NSS_BASE:-}" ]; then
	echo "[prepare]   使用 SBE_NSS_BASE=$SBE_NSS_BASE"
elif [ -d "$NSS_CACHE/nss-src-v1/qca-ssdk" ]; then
	echo "[prepare]   复用 $NSS_CACHE/nss-src-v1"
	SBE_NSS_BASE=$NSS_CACHE/nss-src-v1
else
	[ -f "$NSS_SHA_FILE" ] || { echo "缺少 $NSS_SHA_FILE" >&2; exit 1; }
	echo "[prepare]   从 qsdk 基座自产 NSS 源码包（稀疏检出 qca/src/nss @ ${NSS_QSDK_COMMIT:0:12}）"
	nss_work=$(mktemp -d "$NSS_CACHE/gen.XXXXXX")
	nss_clone=$nss_work/qsdk
	export GIT_TERMINAL_PROMPT=0
	git init -q "$nss_clone"
	git -C "$nss_clone" remote add origin "$NSS_QSDK_URL"
	git -C "$nss_clone" config core.sparseCheckout true
	git -C "$nss_clone" config core.sparseCheckoutCone true
	# cone 模式必须逐级写出父目录的“重新包含”行。只写 /qca/src/nss/ 时
	# git 会把整棵树都当成稀疏外（实测 checkout 出 0 个文件），而少写一行也
	# 不行——下面六行与 `git sparse-checkout set --cone qca/src/nss` 生成的
	# 内容逐字一致，只是提前到 checkout 之前写，避免先落 2.7 GB 全树再删。
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
		|| { echo "取不到 qsdk 基座 $NSS_QSDK_COMMIT（SOURCE_UNAVAILABLE）" >&2; rm -rf "$nss_work"; exit 1; }
	git -C "$nss_clone" checkout --quiet --detach FETCH_HEAD
	got=$(git -C "$nss_clone" rev-parse HEAD)
	[ "$got" = "$NSS_QSDK_COMMIT" ] \
		|| { echo "qsdk 基座 HEAD 不符：$got（PIN_MISMATCH）" >&2; rm -rf "$nss_work"; exit 1; }
	for d in base/qca-ssdk base/qca-nss-phy base/qca-nss-dp base/qca-nss-ppe \
	         clients/qca-nss-ecm clients/qca-nss-ae-clients clients/qca-nss-sfe; do
		[ -d "$nss_clone/qca/src/nss/$d" ] \
			|| { echo "稀疏检出缺少 qca/src/nss/$d" >&2; rm -rf "$nss_work"; exit 1; }
	done
	SBE_NSS_SRC_BASE="$nss_clone/qca/src/nss/base" \
	SBE_NSS_SRC_CLIENTS="$nss_clone/qca/src/nss/clients" \
		"$SELF/export-nss-src.sh" "$nss_work/out" \
		|| { echo "NSS 源码包自产失败" >&2; rm -rf "$nss_work"; exit 1; }
	cp "$NSS_SHA_FILE" "$nss_work/out/nss-src.tar.gz.sha256"
	( cd "$nss_work/out" && sha256sum -c nss-src.tar.gz.sha256 ) \
		|| { echo "NSS 源码包自产结果与 nss-src.tar.gz.sha256 不一致（源码已漂移）" >&2
		     rm -rf "$nss_work"; exit 1; }
	tar -C "$NSS_CACHE" -xzf "$nss_work/out/nss-src-v1.tar.gz"
	rm -rf "$nss_work"
	SBE_NSS_BASE=$NSS_CACHE/nss-src-v1
fi
SBE_NSS_BASE="$SBE_NSS_BASE" SBE_BUILDROOT="$BR" "$PROJ/nss/install.sh" "$ROOT"
for f in "$BR/package/feeds/nss/qca-ssdk/Makefile" \
         "$BR/qca/src/nss/base/qca-nss-dp/nss_dp_attach.c"; do
	[ -e "$f" ] || { echo "NSS 装配不完整，缺少 $f" >&2; exit 1; }
done

echo "[prepare] 写入 version / version.date"
printf '%s\n' "$REVISION" > "$BR/version"
printf '%s\n' "$EPOCH" > "$BR/version.date"

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

echo "[prepare] 完成"
