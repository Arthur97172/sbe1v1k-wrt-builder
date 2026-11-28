#!/usr/bin/env bash
# 在 CI 工作区里装配 OpenWrt 25.12 构建树。
#
# 与 24.10-6.6 不同，25.12 不需要私有 QSDK 源码包：上游
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
#   4. 安装本地软件包与 19 个第三方插件（fetch-plugins.sh，默认每次解析
#      最新版本 tag；SBE_PLUGIN_MODE=pinned 复现旧镜像，SBE_PLUGIN_STRICT=1
#      时解析失败即中止），然后自产/复用/解包 NSS 源码并装配；
#   5. 写入 version（REVISION）与 version.date（固定 SOURCE_DATE_EPOCH）；
#   6. 重建 host-bin（Ubuntu runner 上没有 /usr/bin/gnu* 前缀）。
#
# 构建变体（SBE_VARIANT，默认 production）：
#   production  正式固件。上述全部步骤。
#   diag        25.12 启动失败的 RAM 诊断镜像（见
#               docs/CONTROL_EXPERIMENT_PLAN-2026-11-16.md）。装配方式相同
#               （QSDK NSS/SSDK 必须保留），但不装第三方插件：diag seed 只用
#               官方 feed 与本地包，构建可离线复现。overlay 叠加 files-diag/。
#   mainline    对照实验 M 变体：不装配 QSDK NSS，走主线 PPE 数据通路。
#               overlay 叠加 files-mainline/。
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

VARIANT=${SBE_VARIANT:-production}
case "$VARIANT" in
production|diag|mainline) ;;
*)
	echo "未知 SBE_VARIANT=$VARIANT（可选 production|diag|mainline）" >&2
	exit 1
	;;
esac
echo "[prepare] 构建变体 SBE_VARIANT=$VARIANT"

OPENWRT_URL=${OPENWRT_URL:-https://github.com/openwrt/openwrt.git}
OPENWRT_BRANCH=${OPENWRT_BRANCH:-openwrt-25.12}
OPENWRT_SHA=${OPENWRT_SHA:-f3f5c2e54bf432b444e36b1a77077ff476361825}

# REVISION 以本项目（构建仓库）当前提交的短 SHA 结尾，随每次提交自动变化，
# 不再写死里程碑名（原 "stage1" 是 2026-10-23 首次装配时的残留，之后
# Stage 2.x 全部落地后一直没人改）。无 git 元数据（导出的源码包等）时
# 回退到钉住的上游 OpenWrt 提交短 SHA。
# 必须以十六进制分段结尾：base-files 把版本拼成
# "<COMMITCOUNT>~<REVISION 最后一个 '-' 分段>"，apk 3.x 的 '~' 后缀
# 只接受十六进制（非十六进制的 "stage1" 会让 package/base-files 编译失败），
# 而提交短 SHA 天然满足。
SBE_COMMIT=$(git -C "$PROJ/.." rev-parse --short=8 HEAD 2>/dev/null || true)
[ -n "$SBE_COMMIT" ] || SBE_COMMIT=${OPENWRT_SHA:0:8}
REVISION=${SBE_REVISION:-sbe1v1k-25.12-$SBE_COMMIT}

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

# feeds update 在默认分支 tip 上生成索引；上面已检出固定提交，索引必须按固定
# 的树重建，否则装进来的包集合和 pin 对不上。本地曾因一次失败的克隆留下 0 字节
# 的 packages.index，feeds install 不报错却整片跳过 packages feed（ttyd 等依赖
# 在 package/install 阶段才炸）；所以重建后再逐 feed 断言索引非空。
echo "[prepare] 重建 feed 索引（按固定提交）"
( cd "$BR" && ./scripts/feeds update -i -a )
for feed in luci packages routing telephony video; do
	idx="$BR/feeds/$feed.tmp/.packageinfo"
	[ -s "$idx" ] || {
		echo "[prepare] feed $feed 的索引为空（$idx）：feeds install 会静默丢掉整个 feed" >&2
		exit 1
	}
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
# v29 起 eMMC 节点还要带 SDCC 核心复位（0028）。上游 6.18 的 askey_sbe1v1k DTB
# 有这一条；6.12 的 sdhci_msm_gcc_reset() 取的是可选复位，缺了不报错，真机上
# 表现为读能返回、写卡死（stage-probe4..8）。补丁被静默丢弃时在这里失败。
grep -q 'resets = <&gcc GCC_SDCC_BCR>;' \
	"$BR/target/linux/qualcommbe/files/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts" \
	|| { echo "补丁应用不完整：&sdhc_1 没有 SDCC 核心复位（0028）" >&2; exit 1; }
# 0029：板级 dts 必须关掉 RDP433 基线的 QPIC NAND。目标补丁 0104 在
# ipq9574-rdp-common.dtsi 里启用 &qpic_nand 并把它挂到 gpio0-5 的 qspi 复用上，
# 与 eMMC 的 sdc_default_state 是同一组焊球（gpio5 clk、gpio4 cmd、
# gpio0-3/6-9 data）。开着时 eMMC 完全不枚举：2026-11-15 的 RAM 探针里，
# 开 = 红灯无 mmcblk*，关 = 绿灯 mmcblk0 + mmcblk0p27。补丁丢了就在这里失败。
grep -q '^&qpic_nand { status = "disabled"; };$' \
	"$BR/target/linux/qualcommbe/files/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts" \
	|| { echo "补丁应用不完整：设备树没有禁用 QPIC NAND（0029）" >&2; exit 1; }
# 0030：内置 QCA808x 驱动必须保留、但 QCA8084 那一条注册必须去掉。6.12 的
# qca808x.c 注册的 libphy 名字与 QSDK 的 qca8084-phy.ko 相同，两者同在时后者
# 加载报 EEXIST（-16），kmodloader 依赖链 qca8084-phy → qca-ssdk →
# qca-nss-ppe → qca-nss-dp/sfe/ecm 全线断掉，开机后没有任何以太网口。反过来
# 把整个驱动关掉也不行：QCA8081 落到 genphy 后不会把 MAC/PCS 切到
# PHY_INTERFACE_MODE_2500BASEX，eth1 在 2.5G 下链路 up 但零帧（2026-11-19
# 真机对照：24.10 厂商驱动 2500 全通，25.12 genphy 2500 静默、1000 全通）。
# 所以同时断言配置开着、且内核补丁 0801（只删 QCA8084 注册）确实落地。
grep -q '^CONFIG_QCA808X_PHY=y$' \
	"$BR/target/linux/qualcommbe/config-6.12" \
	|| { echo "补丁应用不完整：目标配置没有打开内置 QCA808x PHY（0030）" >&2; exit 1; }
ls "$BR"/target/linux/qualcommbe/patches-6.12/0801-*.patch >/dev/null 2>&1 \
	|| { echo "补丁应用不完整：缺少内核补丁 0801（保留 QCA8081、去掉 QCA8084 注册，0030）" >&2; exit 1; }

# 0045：板级 DTS 的 /aliases 只能有 ethernet0。APPSBL 的 fdt_fixup_ethernet()
# 会把 env eth<N>addr 写进每个 ethernetN 别名指向的节点；eth1addr..eth3addr
# 相同的机器上 dp2–dp4 会带着同一个全局 MAC、addr_assign_type=0 起来（2026-11-27
# 实机取证），sbe-lan-mac 按“只改随机地址”的规则一次都不会执行。
if grep -qE '^[[:space:]]*ethernet[1-9][[:space:]]*=' \
	"$BR/target/linux/qualcommbe/files/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts"; then
	echo "补丁应用异常：板级 DTS 又出现 ethernet1+ 别名（0045 被回退/丢弃）" >&2
	exit 1
fi

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
# 端口角色只在 board.json 里声明：02_network 没有本板分支时 99-default_network
# 会写 lan=eth0 / wan=eth1（少两个口，eth1 WAN 被划进 LAN 后上游断网）。
# 与 24.10 一致：eth1（dp2，QCA8081 2.5G）= WAN，eth0/eth2/eth3 = LAN，
# eth0 由 overlay 里的 99-spectrum-eth0-unmanaged-lan 从 netifd 的 br-lan
# 端口列表里摘出、再由 eth0-lan-attach 从外部补挂。LuCI 概览的端口面板只按
# board.json 的 ports 显示，检查必须在编译前失败。
grep -q 'ucidef_set_interfaces_lan_wan "eth2 eth3 eth0" "eth1"' \
	"$BR/target/linux/qualcommbe/ipq95xx/base-files/etc/board.d/02_network" \
	|| { echo "补丁应用不完整：02_network 没有 spectrum,sbe1v1k 的 LAN/WAN 端口映射" >&2; exit 1; }
# 端口角色（2026-11-21 阶段 A）：同一分支还要能按 sbe_ports.main.wan_port
# 选择 eth0/eth1 作 WAN。默认行保留在上面那条断言里；这里只确认角色分支存在，
# 免得补丁被回退成写死 eth1 而没人发现。
grep -q 'sbe_ports.main.wan_port' \
	"$BR/target/linux/qualcommbe/ipq95xx/base-files/etc/board.d/02_network" \
	|| { echo "补丁应用不完整：02_network 没有 sbe_ports 角色分支" >&2; exit 1; }
for f in usr/sbin/sbe-port-roles etc/init.d/sbe-port-roles; do
	[ -x "$PROJ/files/$f" ] || { echo "files overlay 缺少或不可执行 $f（端口角色不生效）" >&2; exit 1; }
done
grep -q 'START=19' "$PROJ/files/etc/init.d/sbe-port-roles" \
	|| { echo "sbe-port-roles 不是 START=19（须晚于 nss S15、早于 network S20）" >&2; exit 1; }
grep -q 'sbe_ports.main.wan_port' "$PROJ/files/usr/sbin/eth0-lan-attach" \
	|| { echo "eth0-lan-attach 没有角色判断：eth0 作 WAN 时会被挂回 br-lan" >&2; exit 1; }
# v21 的 FIT 把内核装到 0x41000000（Device/Default），落在厂商给 NSS 固件保留的
# 0x40000000..0x42000000 里，设备起不来；PWM 驱动缺失时风扇恒为满速。两个都
# 断在编译前，不要等真机刷入才发现。
[ "$(grep -c '^	KERNEL_LOADADDR := 0x42200000$' \
	"$BR/target/linux/qualcommbe/image/ipq95xx.mk")" = 2 ] \
	|| { echo "补丁应用不完整：两个 SBE1V1K 设备没有 KERNEL_LOADADDR 0x42200000" >&2; exit 1; }
grep -q '^CONFIG_PWM=y$' "$BR/target/linux/qualcommbe/config-6.12" \
	|| { echo "补丁应用不完整：config-6.12 没有打开 CONFIG_PWM" >&2; exit 1; }
for p in 0400 0401 0402 0403; do
	ls "$BR"/target/linux/qualcommbe/patches-6.12/${p}-*.patch >/dev/null 2>&1 \
		|| { echo "补丁应用不完整：缺少内核 PWM 补丁 $p" >&2; exit 1; }
done
SBE_DTS="$BR/target/linux/qualcommbe/files/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts"
grep -q '^	fan: pwm-fan {' "$SBE_DTS" \
	|| { echo "补丁应用不完整：设备树没有 pwm-fan 节点" >&2; exit 1; }
grep -q '^&pwm {' "$SBE_DTS" \
	|| { echo "补丁应用不完整：设备树没有启用 &pwm" >&2; exit 1; }
# 启动阻塞（0027）：24.10 在同一颗芯片上用真机证明了三条——CPU 的
# operating-points-v2 让 cpufreq-dt 注册并重写 A73 PLL（v52–v54 静默死亡）、
# sleep_clk 带速率、缺 nss@40000000（0x40000000..0x42000000）保留区。25.12 的
# v24 三条都缺，刷入后起不来。补丁顺序一变就可能静默失效，编译前先断言。
# 0027 可能被移到 patches/disabled/ 做对照构建（v28，见那里的 README）：此时
# 断言方向反过来，保证镜像确实是"去掉 0027"的形态，而不是补丁悄悄没生效。
if ls "$PROJ"/patches/0027-*.patch >/dev/null 2>&1; then
	for n in 0 1 2 3; do
		grep -q "^&CPU$n { /delete-property/ operating-points-v2; };" "$SBE_DTS" \
			|| { echo "补丁应用不完整：设备树没有删除 CPU$n 的 operating-points-v2" >&2; exit 1; }
	done
	grep -q '^&sleep_clk { /delete-property/ clock-frequency; };' "$SBE_DTS" \
		|| { echo "补丁应用不完整：设备树没有删除 sleep_clk 的速率" >&2; exit 1; }
	grep -q 'nss@40000000' "$SBE_DTS" \
		|| { echo "补丁应用不完整：设备树没有 nss@40000000 保留区" >&2; exit 1; }
else
	echo "[prepare] 注意：0027 未启用（对照构建：保留 CPU OPP、sleep_clk 速率、无 NSS 保留区）"
	for n in 0 1 2 3; do
		! grep -q "^&CPU$n { /delete-property/ operating-points-v2; };" "$SBE_DTS" \
			|| { echo "对照构建不一致：设备树仍删除了 CPU$n 的 operating-points-v2" >&2; exit 1; }
	done
	! grep -q '^&sleep_clk { /delete-property/ clock-frequency; };' "$SBE_DTS" \
		|| { echo "对照构建不一致：设备树仍删除了 sleep_clk 的速率" >&2; exit 1; }
	! grep -q 'nss@40000000' "$SBE_DTS" \
		|| { echo "对照构建不一致：设备树仍有 nss@40000000 保留区" >&2; exit 1; }
fi

echo "[prepare] 安装项目自带软件包"
for d in "$PROJ"/build/local-packages/*/; do
	[ -d "$d" ] || continue
	name=$(basename "$d")
	rm -rf "$BR/package/$name"
	cp -a "$d" "$BR/package/$name"
	echo "[prepare]   package/$name"
done

# 19 个第三方插件（13 个自维护 + passwall/nikki/openclash/mosdns/argon）。
# 默认在每次构建时解析各仓库最新版本 tag；只有新提交是 thirdparty-pins.conf
# 里 pin 的后代才采用，分叉/回退/远端不可达都保持 pin（不中断构建）。
# 实际提交记录在 <装配树>/.sbe-plugins.tsv，供 release notes 与日志引用；
# SBE_PLUGIN_MODE=pinned 可精确复现旧镜像。
echo "[prepare] 安装第三方插件（SBE_PLUGIN_MODE=${SBE_PLUGIN_MODE:-latest}）"
if [ "$VARIANT" = production ]; then
	"$SELF/fetch-plugins.sh" "$ROOT"
	[ -s "$BR/.sbe-plugins.tsv" ] \
		|| { echo "插件安装没有产出 $BR/.sbe-plugins.tsv" >&2; exit 1; }
else
	# diag/mainline 的 seed 不引用任何第三方插件：不联网解析 tag，构建
	# 保持可复现，也不会因为某个插件仓库不可达而拖垮诊断构建。
	echo "[prepare] $VARIANT 变体：跳过第三方插件装配"
fi

# NSS 源码不在仓库里（QSDK 厂商树有数十 GB）。默认设备 spectrum_sbe1v1k
# 的 DEVICE_PACKAGES 依赖 kmod-qca-ssdk-nohnat / kmod-qca-nss-dp /
# kmod-qca-nss-ppe，而补丁 0009 又删掉了主线 PPE 节点；不装这几个包，
# 镜像就没有以太网。
#
# 源码来源按优先级：SBE_NSS_BASE（已有解包目录）→ 本地缓存 → 现场自产。
# 自产方式：对 QSDK 基座做 blob:none 部分克隆 + 只检出 qca/src/nss，
# 用 export-nss-src.sh 重打 tar.gz，再与 nss/nss-src.tar.gz.sha256 比对。
# 这样 CI 不再需要任何人工上传的 Release 资产，而校验强度不变（哈希相同）。
if [ "$VARIANT" = mainline ]; then
	# M 变体（对照实验）：设备定义 spectrum_sbe1v1k_mainline 走主线 PPE，
	# 不消费 qca-ssdk / qca-nss-*，因此完全不装配 QSDK NSS 源码包。
	echo "[prepare] mainline 变体：不装配 QSDK NSS（主线 PPE 数据通路）"
else
NSS_SHA_FILE=$PROJ/nss/nss-src.tar.gz.sha256
NSS_CACHE=$ROOT/.sbe-cache
NSS_QSDK_URL=${SBE_NSS_QSDK_URL:-https://github.com/everything411/qsdk}
NSS_QSDK_COMMIT=${SBE_NSS_QSDK_COMMIT:-21a8d13393aa8c7d2abf806e62a8dac2ba7af52f}

echo "[prepare] 接入 NSS 源码"
mkdir -p "$NSS_CACHE"
if [ -n "${SBE_NSS_BASE:-}" ]; then
	echo "[prepare]   使用 SBE_NSS_BASE=$SBE_NSS_BASE"
elif [ -d "$NSS_CACHE/nss-src-v1/qca-ssdk" ] && \
     [ -d "$NSS_CACHE/nss-src-v1/qca-ssdk-shell" ]; then
	# 缓存必须是含 qca-ssdk-shell 的版本（阶段 B 起）：旧缓存解出来没有
	# apps-oss，install.sh 会跳过源码，qca-ssdk-shell 编译必失败。
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
	         clients/qca-nss-ecm clients/qca-nss-ae-clients clients/qca-nss-sfe \
	         apps-oss/qca-ssdk-shell; do
		[ -d "$nss_clone/qca/src/nss/$d" ] \
			|| { echo "稀疏检出缺少 qca/src/nss/$d" >&2; rm -rf "$nss_work"; exit 1; }
	done
	SBE_NSS_SRC_BASE="$nss_clone/qca/src/nss/base" \
	SBE_NSS_SRC_CLIENTS="$nss_clone/qca/src/nss/clients" \
	SBE_NSS_SRC_APPS="$nss_clone/qca/src/nss/apps-oss" \
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
SBE_NSS_BASE="$SBE_NSS_BASE" SBE_BUILDROOT="$BR" \
	"$PROJ/nss/install.sh" "$ROOT"
for f in "$BR/package/feeds/nss/qca-ssdk/Makefile" \
         "$BR/package/feeds/nss/qca-ssdk-shell/Makefile" \
         "$BR/qca/src/nss/base/qca-nss-dp/nss_dp_attach.c" \
         "$BR/qca/src/nss/apps-oss/qca-ssdk-shell/Makefile"; do
	[ -e "$f" ] || { echo "NSS 装配不完整，缺少 $f" >&2; exit 1; }
done
# 端口角色运行期改表（阶段 B）：工具包必须声明对 qca-ssdk 内核模块的依赖，
# 否则 tier=wired/full 下 /dev/switch_ssdk 不一定在；安装清单必须含
# ssdk_sh 与 libssdk_us.so，缺一件 sbe-port-roles 就只能 fail closed。
grep -q 'DEPENDS:=.*kmod-qca-ssdk-nohnat' "$BR/package/feeds/nss/qca-ssdk-shell/Makefile" \
	|| { echo "qca-ssdk-shell 未依赖 kmod-qca-ssdk-nohnat" >&2; exit 1; }
for _bin in ssdk_sh libssdk_us.so; do
	grep -q "$_bin" "$BR/package/feeds/nss/qca-ssdk-shell/Makefile" \
		|| { echo "qca-ssdk-shell 的安装清单缺少 $_bin" >&2; exit 1; }
done
# 两个 QSDK 等待循环的超时必须随包进树：丢了它，模块装载失败时 rcS 会停在
# S16/S18 永久卡死（v34 的形态）。verify-image.sh 在镜像里还会再断言一次。
grep -q 'WAIT_TIMEOUT' "$BR/package/feeds/nss/qca-nss-dp/files/qca-nss-dp.init" \
	|| { echo "qca-nss-dp.init 丢掉了等待超时（模块装载失败会卡死 rcS）" >&2; exit 1; }
grep -q 'WAIT_TIMEOUT' "$BR/package/feeds/nss/qca-ssdk/files/qca-ssdk" \
	|| { echo "qca-ssdk 丢掉了等待超时（模块装载失败会卡死 rcS）" >&2; exit 1; }
# 25.12 起 NSS 数据通路改为 nss-load 按档位装载（docs/NSS_AUTOLOAD_OFF.md）：
# 9 个数据通路包不得再带生效的 AUTOLOAD，五个启停脚本不得再带 START。
# qca-nss-phy 的 AUTOLOAD 必须保留——PHY 驱动仍由 kmodloader 在 S10 加载。
for p in qca-ssdk qca-nss-ppe qca-nss-dp qca-nss-sfe qca-nss-debug \
         qca-nss-ppe-ds qca-nss-ppe-rule qca-nss-ppe-vp qca-nss-ae-clients; do
	grep -qE '^[^#]*AUTOLOAD:=' "$BR/package/feeds/nss/$p/Makefile" \
		&& { echo "$p 仍有生效的 AUTOLOAD（25.12 应改由 nss-load 分层装载）" >&2; exit 1; }
done
grep -qE '^[^#]*AUTOLOAD:=' "$BR/package/feeds/nss/qca-nss-phy/Makefile" \
	|| { echo "qca-nss-phy 的 AUTOLOAD 被误删（PHY 驱动必须随 kmodloader 加载）" >&2; exit 1; }
for s in qca-ssdk/files/qca-ssdk qca-nss-dp/files/qca-nss-dp.init \
         qca-nss-ae-clients/files/qca-nss-ppe-bridge-mgr.init \
         qca-nss-ecm/files/qca-nss-ecm.init qca-nss-sfe/files/etc/init.d/shortcut-fe; do
	grep -qE '^START=' "$BR/package/feeds/nss/$s" \
		&& { echo "$s 仍有 START（25.12 应改由 nss-load 启动）" >&2; exit 1; }
done
for f in "$PROJ/files/etc/nss.conf" "$PROJ/files/usr/sbin/nss-load" \
         "$PROJ/files/etc/init.d/nss"; do
	[ -e "$f" ] || { echo "缺少 NSS 档位控制器文件 $f" >&2; exit 1; }
done
fi

if [ "$VARIANT" = diag ]; then
	# D 变体（RAM 诊断镜像）：NSS 包全部保留（用户要求 QSDK NSS/SSDK），但
	# 启动档位必须是 off —— 先区分“NSS 触发复位”与“其他复位源”，再逐层
	# nss-load。overlay 与 seed 缺一项，这次构建就不是对照实验的形态。
	[ -f "$PROJ/files-diag/etc/nss.conf" ] \
		|| { echo "diag 变体缺少 files-diag/etc/nss.conf" >&2; exit 1; }
	grep -qx 'tier=off' "$PROJ/files-diag/etc/nss.conf" \
		|| { echo "files-diag/etc/nss.conf 的 tier 不是 off" >&2; exit 1; }
	grep -qx 'fallback=off' "$PROJ/files-diag/etc/nss.conf" \
		|| { echo "files-diag/etc/nss.conf 的 fallback 不是 off（会绕过诊断档位）" >&2; exit 1; }
	[ -f "$PROJ/files-diag/usr/sbin/sbe-diag-beacon" ] \
		|| { echo "diag 变体缺少 files-diag/usr/sbin/sbe-diag-beacon" >&2; exit 1; }
	[ -f "$PROJ/files-diag/etc/dropbear/authorized_keys" ] \
		|| { echo "diag 变体缺少 dropbear authorized_keys（SSH 进不去就取不到证据）" >&2; exit 1; }
	[ -f "$PROJ/build/config-seed/ipq95xx-spectrum-sbe1v1k-diag.seed" ] \
		|| { echo "diag 变体缺少 build/config-seed/ipq95xx-spectrum-sbe1v1k-diag.seed" >&2; exit 1; }
	[ -f "$PROJ/build/required-packages-diag.txt" ] \
		|| { echo "diag 变体缺少 build/required-packages-diag.txt" >&2; exit 1; }
fi
if [ "$VARIANT" = mainline ]; then
	[ -d "$PROJ/files-mainline" ] \
		|| { echo "mainline 变体缺少 files-mainline/" >&2; exit 1; }
	grep -qx 'tier=off' "$PROJ/files-mainline/etc/nss.conf" 2>/dev/null \
		|| { echo "files-mainline/etc/nss.conf 的 tier 不是 off（S15 会刷 INCOMPLETE 噪声）" >&2; exit 1; }
	[ -f "$PROJ/files-mainline/etc/dropbear/authorized_keys" ] \
		|| { echo "mainline 变体缺少 dropbear authorized_keys（能启动时取证据用）" >&2; exit 1; }
	[ -f "$PROJ/build/config-seed/ipq95xx-spectrum-sbe1v1k-mainline.seed" ] \
		|| { echo "mainline 变体缺少 build/config-seed/ipq95xx-spectrum-sbe1v1k-mainline.seed" >&2; exit 1; }
	[ -f "$PROJ/build/required-packages-mainline.txt" ] \
		|| { echo "mainline 变体缺少 build/required-packages-mainline.txt" >&2; exit 1; }
fi

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
