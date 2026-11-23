#!/usr/bin/env bash
# 25.12-6.18 产物静态校验（只看文件，不接触设备）。
#
# S3d 起产出两个设备镜像（mainline PPE 与 QSDK NSS），两者共用同一套包选择
# 与 overlay（seed + files/），但 OpenWrt 的设备选择是 kconfig choice，每个
# 镜像来自各自的一次构建（scripts/ci/build-images.sh 跑两遍）。因此这里对
# 每份镜像独立校验：
#   1. 产物齐全：两套 squashfs sysupgrade 与 initramfs FIT，各一份；
#   2. sysupgrade 是 tar，成员 kernel/root 存在；
#   3. kernel 成员是 FIT，里面嵌着本板 DTB（model/compatible/config 节点）；
#      mainline FIT 含 qcom,ipq9574-ppe，NSS FIT 含 qcom,ess-switch-ipq95xx
#      且不含 qcom,ipq9574-ppe（补丁 0031 的 /delete-node/）；
#   4. 两份 root 都是 squashfs，且各自都带 NSS 包与 overlay/NSS 服务文件
#      （共用包选择的并集模型：mainline 上靠 nss-board 门控静默让路）；
#   5. root 里 /etc/openwrt_release 的 DISTRIB_TARGET 指向
#      qualcommbe/ipq95xx（解包工具可用时）；
#   6. 项目 overlay（banner/无线默认值/时区/NSS 服务/rc.d）与 required 包
#      清单在 rootfs 里逐项断言（唯一来源与 seed/defconfig 检查共用）。
#
# 用法：scripts/ci/verify-image.sh [工作区根目录]
# 退出码：全部 PASS 为 0，否则 1。

set -uo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)
ROOT=${1:-$(CDPATH= cd -- "$PROJ/.." && pwd)}
OUT="$ROOT/sources/buildroot-25.12-6.18/bin/targets/qualcommbe/ipq95xx"

pass=0 fail=0
ok()   { echo "PASS  $*"; pass=$((pass+1)); }
bad()  { echo "FAIL  $*"; fail=$((fail+1)); }

[ -d "$OUT" ] || { echo "FAIL  产物目录不存在：$OUT" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- 1. 产物齐全：mainline 与 NSS 各一套 --------------------------------
mapfile -t SYSUPS < <(find "$OUT" -maxdepth 1 -name '*askey_sbe1v1k*squashfs-sysupgrade.bin' | sort)
mapfile -t INITS < <(find "$OUT" -maxdepth 1 -name '*askey_sbe1v1k*initramfs*itb' | sort)
MAIN_SYS=(); NSS_SYS=(); MAIN_INIT=(); NSS_INIT=()
for f in "${SYSUPS[@]}"; do
	case "$(basename "$f")" in
	*askey_sbe1v1k-nss*) NSS_SYS+=("$f") ;;
	*) MAIN_SYS+=("$f") ;;
	esac
done
for f in "${INITS[@]}"; do
	case "$(basename "$f")" in
	*askey_sbe1v1k-nss*) NSS_INIT+=("$f") ;;
	*) MAIN_INIT+=("$f") ;;
	esac
done
[ "${#MAIN_SYS[@]}" -eq 1 ] && ok "mainline sysupgrade 唯一：$(basename "${MAIN_SYS[0]}")" \
	|| bad "mainline sysupgrade 数量 = ${#MAIN_SYS[@]}（期望 1）"
[ "${#NSS_SYS[@]}" -eq 1 ] && ok "NSS sysupgrade 唯一：$(basename "${NSS_SYS[0]}")" \
	|| bad "NSS sysupgrade 数量 = ${#NSS_SYS[@]}（期望 1）"
[ "${#MAIN_INIT[@]}" -eq 1 ] && ok "mainline initramfs 唯一：$(basename "${MAIN_INIT[0]}")" \
	|| bad "mainline initramfs 数量 = ${#MAIN_INIT[@]}（期望 1）"
[ "${#NSS_INIT[@]}" -eq 1 ] && ok "NSS initramfs 唯一：$(basename "${NSS_INIT[0]}")" \
	|| bad "NSS initramfs 数量 = ${#NSS_INIT[@]}（期望 1）"
[ "$fail" -eq 0 ] || exit 1

# --- 2/3. 每个 sysupgrade：tar 成员、FIT 内容、squashfs -------------------
# 25.12 起 sysupgrade 的成员放在 sysupgrade-<profile>/ 子目录里；早期布局是
# 平铺的 kernel/root。两种都接受，先找出实际前缀。
check_sysupgrade() {
	local sys=$1 tag=$2 dir="$TMP/$2"
	mkdir -p "$dir"

	tar -tf "$sys" > "$dir/members" 2>/dev/null \
		&& ok "[$tag] sysupgrade 是合法 tar" || { bad "[$tag] sysupgrade 不是合法 tar"; return; }
	local prefix
	prefix=$(awk -F/ 'NF==2 && $2=="kernel" {print $1; exit}' "$dir/members")
	[ -n "$prefix" ] && [ "$prefix" = "$(awk -F/ 'NF==2 && $2=="root" {print $1; exit}' "$dir/members")" ] \
		|| prefix=""
	local m
	for m in kernel root; do
		grep -qx "${prefix:+$prefix/}$m" "$dir/members" \
			&& ok "[$tag] tar 成员存在：${prefix:+$prefix/}$m" \
			|| bad "[$tag] tar 成员缺失：${prefix:+$prefix/}$m"
	done
	tar -xf "$sys" -C "$dir" "${prefix:+$prefix/}kernel" "${prefix:+$prefix/}root" 2>/dev/null \
		|| { bad "[$tag] 无法解出 kernel/root"; return; }
	if [ -n "$prefix" ]; then
		mv "$dir/$prefix/kernel" "$dir/kernel" && mv "$dir/$prefix/root" "$dir/root" \
			|| { bad "[$tag] 无法整理 kernel/root 路径"; return; }
	fi

	local pat
	for pat in 'Spectrum SBE1V1K' 'askey,sbe1v1k' 'config@rtq7300t-rev0' 'ARM64 OpenWrt'; do
		grep -aqF "$pat" "$dir/kernel" \
			&& ok "[$tag] FIT 含 '$pat'" || bad "[$tag] FIT 缺少 '$pat'"
	done

	if [ "$(dd if="$dir/root" bs=4 count=1 2>/dev/null)" = "hsqs" ]; then
		ok "[$tag] root 成员是 squashfs（hsqs）"
	else
		bad "[$tag] root 成员不是 squashfs"
	fi
}

check_sysupgrade "${MAIN_SYS[0]}" main
check_sysupgrade "${NSS_SYS[0]}" nss

# 数据通路的区分只看 DTB：mainline 有 PPE 节点，NSS 在补丁 0031 里删掉了它
# 并换成 ess-switch/dp。rootfs 内容两边相同（同一份 seed 包选择）。
grep -aqF 'qcom,ipq9574-ppe' "$TMP/main/kernel" \
	&& ok "mainline FIT 含 mainline PPE 节点（qcom,ipq9574-ppe）" \
	|| bad "mainline FIT 缺少 qcom,ipq9574-ppe（mainline 数据通路不成立）"
if grep -aqF 'qcom,ipq9574-ppe' "$TMP/nss/kernel"; then
	bad "NSS FIT 仍含 qcom,ipq9574-ppe（/delete-node/ 未生效）"
else
	ok "NSS FIT 不含 qcom,ipq9574-ppe（节点已删除）"
fi
grep -aqF 'qcom,ess-switch-ipq95xx' "$TMP/nss/kernel" \
	&& ok "NSS FIT 含 ess-switch 节点（qcom,ess-switch-ipq95xx）" \
	|| bad "NSS FIT 缺少 qcom,ess-switch-ipq95xx"
grep -aqF 'qcom,nss-dp' "$TMP/nss/kernel" \
	&& ok "NSS FIT 含 nss-dp 端口节点（qcom,nss-dp）" \
	|| bad "NSS FIT 缺少 qcom,nss-dp"

# --- 4/5/6. rootfs：两个镜像各查一遍 --------------------------------------
# 两个设备共用一套 seed 包选择与 files/ overlay（rootfs 内容等价），但每次
# 构建各自产出一份 squashfs；这里对两份都断言，防止某个设备缺包。
check_rootfs() {
	local tag=$1 squash=$2 R="$TMP/rootfs-$1"

	if [ "$(dd if="$squash" bs=4 count=1 2>/dev/null)" != "hsqs" ]; then
		bad "[$tag] root 不是 squashfs，跳过 rootfs 检查"
		return
	fi
	if ! command -v unsquashfs >/dev/null 2>&1; then
		echo "SKIP  [$tag] 无 unsquashfs，跳过 rootfs 检查"
		return
	fi
	# unsquashfs 以非 root 跑时无法 mknod /dev/console，会以非零退出但内容
	# 已解出，用 -no-exit-code 忽略；真正的问题由下面的断言抓。
	if ! unsquashfs -no-exit-code -q -d "$R" "$squash" >/dev/null 2>&1; then
		bad "[$tag] unsquashfs 解包失败"
		return
	fi

	grep -q 'DISTRIB_TARGET=.qualcommbe/ipq95xx' "$R/etc/openwrt_release" \
		&& ok "[$tag] openwrt_release 目标 = qualcommbe/ipq95xx" \
		|| bad "[$tag] openwrt_release 目标不是 qualcommbe/ipq95xx"

	# --- WAN 放行首启脚本（S2 首批移植，与 6.12 同源）------------------
	# uci-defaults 由 /etc/init.d/boot 用 sh source 执行，权限位不影响运行；
	# 这里仍要求 755：6.12 同源脚本是 755，模式位丢失会把「没生效」伪装成
	# 「文件在」，而 664 恰好就是首次移植时踩到的样子。
	for pair in '99-allow-luci-wan:firewall.allow_luci_wan' \
	            '99-allow-ssh-wan:firewall.allow_ssh_wan'; do
		f=${pair%%:*}; sec=${pair#*:}
		[ -x "$R/etc/uci-defaults/$f" ] \
			&& grep -q "set $sec=rule" "$R/etc/uci-defaults/$f" \
			&& ok "[$tag] 首启脚本 $f（$sec）在镜像中" \
			|| bad "[$tag] 首启脚本 $f 缺失或内容不对"
	done

	# --- 项目 overlay（S2/ S3d）----------------------------------------
	# overlay 根即固件的 /。源文件在 $PROJ/files；banner 等含 %V/%R 的文件
	# 由 render-overlay.sh 渲染进 $BR/files，镜像必须与渲染后的版本一致。
	BR="$ROOT/sources/buildroot-25.12-6.18"
	check_overlay() {
		local rel=$1 src="$BR/files/$1"
		if [ ! -f "$PROJ/files/$rel" ]; then bad "[$tag] overlay 源缺少 $rel"; return; fi
		if [ ! -f "$src" ]; then bad "[$tag] 渲染后的 overlay 缺少 $rel（先跑 render-overlay.sh）"; return; fi
		if [ ! -f "$R/$rel" ]; then bad "[$tag] 镜像缺少 /$rel"; return; fi
		local a b
		a=$(sha256sum "$src" | cut -d' ' -f1)
		b=$(sha256sum "$R/$rel" | cut -d' ' -f1)
		if [ "$a" = "$b" ]; then ok "[$tag] /$rel 与渲染后 overlay 一致 ($a)"; else bad "[$tag] /$rel 哈希不一致"; fi
		local ma mb
		ma=$(stat -c %a "$src")
		mb=$(stat -c %a "$R/$rel")
		if [ "$ma" = "$mb" ]; then ok "[$tag] /$rel 权限 $mb"; else bad "[$tag] /$rel 权限 $mb，期望 $ma"; fi
	}

	check_overlay etc/banner
	check_overlay etc/uci-defaults/99-wireless-defaults
	check_overlay etc/uci-defaults/99-system-timezone
	check_overlay etc/init.d/wireless-defaults
	check_overlay usr/lib/sbe1v1k/wireless-defaults

	if grep -Eq '%[VCRD]|VERXXXX|WRTVERSIONINFO' "$R/etc/banner"; then
		bad "[$tag] 镜像内 /etc/banner 仍含未替换的占位符"
	else
		ok "[$tag] 镜像内 /etc/banner 无占位符"
	fi
	VLINE=$(grep -m1 '^ Version:' "$R/etc/banner" || true)
	printf '%s' "$VLINE" | grep -Eq '^ Version: .*\(sbe1v1k-6\.18-[0-9a-f]+\)' \
		&& ok "[$tag] banner 版本行：$VLINE" \
		|| bad "[$tag] banner 版本行不是 25.12-SNAPSHOT (sbe1v1k-6.18-…) 形式：${VLINE:-<缺失>}"

	# 无线默认值三项（与 6.12 同源）：首启射频行为的唯一来源。
	for kv in \
		'WIFI_COUNTRY="${WIFI_COUNTRY:-US}"' \
		'WIFI_2G_HTMODE="${WIFI_2G_HTMODE:-EHT20}"' \
		'WIFI_6G_CHANNEL="${WIFI_6G_CHANNEL:-37}"'
	do
		grep -qF "$kv" "$R/usr/lib/sbe1v1k/wireless-defaults" \
			&& ok "[$tag] 无线默认值 $kv" || bad "[$tag] 无线默认值缺失：$kv"
	done

	# 每次开机的自愈逻辑与板名门控：6.18 的板名是 askey,sbe1v1k，
	# 门控漏掉它会让整套策略静默不执行。
	for fn in repair_band_macaddrs repair_6g_availability heal_generated_ifaces; do
		grep -q "^$fn()" "$R/usr/lib/sbe1v1k/wireless-defaults" \
			&& ok "[$tag] wireless-defaults 含 $fn（开机自愈）" \
			|| bad "[$tag] wireless-defaults 缺少 $fn（自愈逻辑缺失）"
	done
	grep -q 'askey,sbe1v1k|spectrum,sbe1v1k' "$R/usr/lib/sbe1v1k/wireless-defaults" \
		&& ok "[$tag] 无线策略板名门控含 askey,sbe1v1k" \
		|| bad "[$tag] 无线策略板名门控不含 askey,sbe1v1k（策略不会执行）"

	head -n1 "$R/etc/init.d/wireless-defaults" | grep -Fxq '#!/bin/sh /etc/rc.common' \
		&& ok "[$tag] /etc/init.d/wireless-defaults 首行为 rc.common" \
		|| bad "[$tag] /etc/init.d/wireless-defaults 首行不是 '#!/bin/sh /etc/rc.common'"

	check_rc_link() {
		local link=$1 want=$2 got
		if [ -L "$R$link" ]; then
			got=$(readlink "$R$link")
			[ "$got" = "$want" ] && ok "[$tag] $link -> $got" || bad "[$tag] $link 指向 $got（期望 $want）"
		else
			bad "[$tag] 缺少 $link（开机不执行）"
		fi
	}
	check_rc_link /etc/rc.d/S95wireless-defaults ../init.d/wireless-defaults

	grep -q "Asia/Taipei" "$R/etc/uci-defaults/99-system-timezone" \
		&& ok "[$tag] 首启时区脚本含 Asia/Taipei" \
		|| bad "[$tag] 首启时区脚本不含 Asia/Taipei"

	# --- NSS 服务 overlay（S3d）----------------------------------------
	# 两个镜像共用包选择，NSS 服务必须在 mainline 上按设备树自动让路：
	# nss-board 是唯一的判据，缺了它 NSS 模块会对 mainline 的 PPE 抢寄存器。
	[ -x "$R/usr/lib/sbe1v1k/nss-board" ] \
		&& ok "[$tag] /usr/lib/sbe1v1k/nss-board 在镜像中（数据通路判据）" \
		|| bad "[$tag] 缺少 /usr/lib/sbe1v1k/nss-board"
	grep -q 'ethernet@3a000000' "$R/usr/lib/sbe1v1k/nss-board" 2>/dev/null \
		&& ok "[$tag] nss-board 按 mainline PPE 节点判别" \
		|| bad "[$tag] nss-board 未按 mainline PPE 节点判别"
	for rel in etc/nss.conf etc/init.d/nss usr/sbin/nss-load \
	           etc/init.d/sbe-port-roles usr/sbin/sbe-port-roles \
	           etc/init.d/eth0-lan-attach usr/sbin/eth0-lan-attach \
	           etc/init.d/sbe-lan-mac \
	           etc/hotplug.d/iface/30-eth0-lan-attach \
	           etc/hotplug.d/net/20-eth0-lan-attach \
	           etc/uci-defaults/99-spectrum-eth0-unmanaged-lan; do
		[ -f "$R/$rel" ] && ok "[$tag] /$rel 在镜像中" || bad "[$tag] 镜像缺少 /$rel"
	done
	grep -q '^tier=wired' "$R/etc/nss.conf" \
		&& ok "[$tag] nss.conf 首个 NSS 镜像档位 = wired" \
		|| bad "[$tag] nss.conf tier 不是 wired（首个 NSS 镜像应先用有线档）"
	for svc in 'S15nss:../init.d/nss' 'S19sbe-lan-mac:../init.d/sbe-lan-mac' \
	           'S19sbe-port-roles:../init.d/sbe-port-roles'; do
		check_rc_link "/etc/rc.d/${svc%%:*}" "${svc#*:}"
	done
	grep -q 'askey,sbe1v1k | spectrum,sbe1v1k' \
		"$R/etc/uci-defaults/99-spectrum-eth0-unmanaged-lan" \
		&& ok "[$tag] eth0 首启脚本板名门控含 askey,sbe1v1k" \
		|| bad "[$tag] eth0 首启脚本板名门控不含 askey,sbe1v1k（脚本不会执行）"
	grep -q 'nss-board || exit 0' \
		"$R/etc/uci-defaults/99-spectrum-eth0-unmanaged-lan" \
		&& ok "[$tag] eth0 首启脚本按数据通路门控" \
		|| bad "[$tag] eth0 首启脚本未按数据通路门控（mainline 会被改写）"
	for f in etc/init.d/nss usr/sbin/nss-load etc/init.d/sbe-port-roles \
	         usr/sbin/sbe-port-roles etc/init.d/eth0-lan-attach \
	         usr/sbin/eth0-lan-attach etc/init.d/sbe-lan-mac \
	         etc/firewall.d/qca-nss-ecm; do
		grep -q 'nss-board' "$R/$f" 2>/dev/null \
			&& ok "[$tag] /$f 按数据通路门控" || bad "[$tag] /$f 缺 nss-board 门控"
	done

	# --- 包集合反查（与 seed/defconfig 检查同一份清单）------------------
	"$SELF/check-packages.sh" db "$R"
	case $? in
	0) ok "[$tag] required-packages.txt 反查通过（镜像包数据库）" ;;
	2) bad "[$tag] check-packages.sh 无法读取镜像包数据库" ;;
	*) bad "[$tag] required-packages.txt 反查未通过（见上面的 FAIL 行）" ;;
	esac
}

check_rootfs main "$TMP/main/root"
check_rootfs nss "$TMP/nss/root"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
