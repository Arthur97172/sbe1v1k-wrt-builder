#!/usr/bin/env bash
# 25.12-6.18 产物静态校验（只看文件，不接触设备）。
#
# Stage 1 的判据刻意保持最小——上游设备定义自己负责镜像形状：
#   1. 产物齐全：squashfs sysupgrade 与 initramfs FIT 各一份；
#   2. sysupgrade 是 tar，成员 kernel/root 存在；
#   3. kernel 成员是 FIT，里面嵌着本板 DTB（model/compatible/config 节点）；
#   4. root 成员是 squashfs（magic "hsqs"）；
#   5. 提取出的 root 里 /etc/openwrt_release 的 DISTRIB_TARGET 指向
#      qualcommbe/ipq95xx（解包工具可用时）；
#   6. 项目 overlay（banner/无线默认值/时区/rc.d）与 required 包清单
#      在 rootfs 里逐项断言（唯一来源与 seed/defconfig 检查共用）。
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

# --- 1. 产物齐全 -----------------------------------------------------------
mapfile -t SYSUPS < <(find "$OUT" -maxdepth 1 -name '*askey_sbe1v1k*squashfs-sysupgrade.bin' | sort)
mapfile -t INITS < <(find "$OUT" -maxdepth 1 -name '*askey_sbe1v1k*initramfs*itb' | sort)
[ "${#SYSUPS[@]}" -eq 1 ] && ok "sysupgrade 产物唯一：$(basename "${SYSUPS[0]}")" \
	|| bad "sysupgrade 产物数量 = ${#SYSUPS[@]}（期望 1）"
[ "${#INITS[@]}" -eq 1 ] && ok "initramfs 产物唯一：$(basename "${INITS[0]}")" \
	|| bad "initramfs 产物数量 = ${#INITS[@]}（期望 1）"
[ "$fail" -eq 0 ] || exit 1
SYS="${SYSUPS[0]}"

# --- 2. sysupgrade tar 成员 ----------------------------------------------
# 25.12 起 sysupgrade 的成员放在 sysupgrade-<profile>/ 子目录里；早期布局是
# 平铺的 kernel/root。两种都接受，先找出实际前缀。
tar -tf "$SYS" > "$TMP/members" 2>/dev/null \
	&& ok "sysupgrade 是合法 tar" || { bad "sysupgrade 不是合法 tar"; exit 1; }
PREFIX=$(awk -F/ 'NF==2 && $2=="kernel" {print $1; exit}' "$TMP/members")
[ -n "$PREFIX" ] && [ "$PREFIX" = "$(awk -F/ 'NF==2 && $2=="root" {print $1; exit}' "$TMP/members")" ] \
	|| PREFIX=""
for m in kernel root; do
	grep -qx "${PREFIX:+$PREFIX/}$m" "$TMP/members" \
		&& ok "tar 成员存在：${PREFIX:+$PREFIX/}$m" \
		|| bad "tar 成员缺失：${PREFIX:+$PREFIX/}$m"
done

tar -xf "$SYS" -C "$TMP" "${PREFIX:+$PREFIX/}kernel" "${PREFIX:+$PREFIX/}root" 2>/dev/null \
	|| { bad "无法解出 kernel/root"; exit 1; }
if [ -n "$PREFIX" ]; then
	mv "$TMP/$PREFIX/kernel" "$TMP/kernel" && mv "$TMP/$PREFIX/root" "$TMP/root" \
		|| { bad "无法整理 kernel/root 路径"; exit 1; }
fi

# --- 3. FIT 里的本板 DTB ---------------------------------------------------
for pat in 'Askey SBE1V1K' 'askey,sbe1v1k' 'config@rtq7300t-rev0'; do
	grep -aqF "$pat" "$TMP/kernel" \
		&& ok "FIT 含 '$pat'" || bad "FIT 缺少 '$pat'"
done
grep -aqF 'ARM64 OpenWrt' "$TMP/kernel" \
	&& ok "FIT 描述含 'ARM64 OpenWrt'" || bad "FIT 描述不含 'ARM64 OpenWrt'"

# --- 4. root 是 squashfs ---------------------------------------------------
if [ "$(dd if="$TMP/root" bs=4 count=1 2>/dev/null)" = "hsqs" ]; then
	ok "root 成员是 squashfs（hsqs）"
else
	bad "root 成员不是 squashfs"
fi

# --- 5. rootfs 目标与包集合（解包工具可用时；缺失不算失败）---------------
# unsquashfs 以非 root 跑时无法 mknod /dev/console，会以非零退出但内容已解出，
# 用 -no-exit-code 忽略；真正的缺失由下面 openwrt_release 与包反查抓。
if command -v unsquashfs >/dev/null 2>&1; then
	if unsquashfs -no-exit-code -q -d "$TMP/rootfs" "$TMP/root" >/dev/null 2>&1; then
		grep -q 'DISTRIB_TARGET=.qualcommbe/ipq95xx' "$TMP/rootfs/etc/openwrt_release" \
			&& ok "openwrt_release 目标 = qualcommbe/ipq95xx" \
			|| bad "openwrt_release 目标不是 qualcommbe/ipq95xx"

		# --- 5b. WAN 放行首启脚本（S2 首批移植，与 6.12 同源）--------------
		# uci-defaults 由 /etc/init.d/boot 用 sh source 执行，权限位不影响运行；
		# 这里仍要求 755：6.12 同源脚本是 755，模式位丢失会把「没生效」伪装成
		# 「文件在」，而 664 恰好就是首次移植时踩到的样子。
		for pair in '99-allow-luci-wan:firewall.allow_luci_wan' \
		            '99-allow-ssh-wan:firewall.allow_ssh_wan'; do
			f=${pair%%:*}; sec=${pair#*:}
			[ -x "$TMP/rootfs/etc/uci-defaults/$f" ] \
				&& grep -q "set $sec=rule" "$TMP/rootfs/etc/uci-defaults/$f" \
				&& ok "首启脚本 $f（$sec）在镜像中" \
				|| bad "首启脚本 $f 缺失或内容不对"
		done

		# --- 5c. 项目 overlay（S2，2026-11-22 按用户要求对齐 6.12）----------
		# overlay 根即固件的 /。源文件在 $PROJ/files；banner 等含 %V/%R 的文件
		# 由 render-overlay.sh 渲染进 $BR/files，镜像必须与渲染后的版本一致。
		BR="$ROOT/sources/buildroot-25.12-6.18"
		check_overlay() {
			local rel=$1 src="$BR/files/$1"
			if [ ! -f "$PROJ/files/$rel" ]; then bad "overlay 源缺少 $rel"; return; fi
			if [ ! -f "$src" ]; then bad "渲染后的 overlay 缺少 $rel（先跑 render-overlay.sh）"; return; fi
			if [ ! -f "$TMP/rootfs/$rel" ]; then bad "镜像缺少 /$rel"; return; fi
			local a b
			a=$(sha256sum "$src" | cut -d' ' -f1)
			b=$(sha256sum "$TMP/rootfs/$rel" | cut -d' ' -f1)
			if [ "$a" = "$b" ]; then ok "/$rel 与渲染后 overlay 一致 ($a)"; else bad "/$rel 哈希不一致"; fi
			local ma mb
			ma=$(stat -c %a "$src")
			mb=$(stat -c %a "$TMP/rootfs/$rel")
			if [ "$ma" = "$mb" ]; then ok "/$rel 权限 $mb"; else bad "/$rel 权限 $mb，期望 $ma"; fi
		}

		check_overlay etc/banner
		check_overlay etc/uci-defaults/99-wireless-defaults
		check_overlay etc/uci-defaults/99-system-timezone
		check_overlay etc/init.d/wireless-defaults
		check_overlay usr/lib/sbe1v1k/wireless-defaults

		if grep -Eq '%[VCRD]|VERXXXX|WRTVERSIONINFO' "$TMP/rootfs/etc/banner"; then
			bad "镜像内 /etc/banner 仍含未替换的占位符"
		else
			ok "镜像内 /etc/banner 无占位符"
		fi
		VLINE=$(grep -m1 '^ Version:' "$TMP/rootfs/etc/banner" || true)
		printf '%s' "$VLINE" | grep -Eq '^ Version: .*\(sbe1v1k-6\.18-[0-9a-f]+\)' \
			&& ok "banner 版本行：$VLINE" \
			|| bad "banner 版本行不是 25.12-SNAPSHOT (sbe1v1k-6.18-…) 形式：${VLINE:-<缺失>}"

		# 无线默认值三项（与 6.12 同源）：首启射频行为的唯一来源。
		for kv in \
			'WIFI_COUNTRY="${WIFI_COUNTRY:-US}"' \
			'WIFI_2G_HTMODE="${WIFI_2G_HTMODE:-EHT20}"' \
			'WIFI_6G_CHANNEL="${WIFI_6G_CHANNEL:-37}"'
		do
			grep -qF "$kv" "$TMP/rootfs/usr/lib/sbe1v1k/wireless-defaults" \
				&& ok "无线默认值 $kv" || bad "无线默认值缺失：$kv"
		done

		# 每次开机的自愈逻辑与板名门控：6.18 的板名是 askey,sbe1v1k，
		# 门控漏掉它会让整套策略静默不执行。
		for fn in repair_band_macaddrs repair_6g_availability heal_generated_ifaces; do
			grep -q "^$fn()" "$TMP/rootfs/usr/lib/sbe1v1k/wireless-defaults" \
				&& ok "wireless-defaults 含 $fn（开机自愈）" \
				|| bad "wireless-defaults 缺少 $fn（自愈逻辑缺失）"
		done
		grep -q 'askey,sbe1v1k|spectrum,sbe1v1k' "$TMP/rootfs/usr/lib/sbe1v1k/wireless-defaults" \
			&& ok "无线策略板名门控含 askey,sbe1v1k" \
			|| bad "无线策略板名门控不含 askey,sbe1v1k（策略不会执行）"

		head -n1 "$TMP/rootfs/etc/init.d/wireless-defaults" | grep -Fxq '#!/bin/sh /etc/rc.common' \
			&& ok "/etc/init.d/wireless-defaults 首行为 rc.common" \
			|| bad "/etc/init.d/wireless-defaults 首行不是 '#!/bin/sh /etc/rc.common'"

		RCD="$TMP/rootfs/etc/rc.d/S95wireless-defaults"
		if [ -L "$RCD" ]; then
			tgt=$(readlink "$RCD")
			[ "$tgt" = "../init.d/wireless-defaults" ] \
				&& ok "/etc/rc.d/S95wireless-defaults -> $tgt" \
				|| bad "/etc/rc.d/S95wireless-defaults 指向 $tgt"
		else
			bad "缺少 /etc/rc.d/S95wireless-defaults（开机不执行）"
		fi

		grep -q "Asia/Taipei" "$TMP/rootfs/etc/uci-defaults/99-system-timezone" \
			&& ok "首启时区脚本含 Asia/Taipei" \
			|| bad "首启时区脚本不含 Asia/Taipei"

		# --- 6. 包集合反查（与 seed/defconfig 检查同一份清单）--------------
		"$SELF/check-packages.sh" db "$TMP/rootfs"
		case $? in
		0) ok "required-packages.txt 反查通过（镜像包数据库）" ;;
		2) bad "check-packages.sh 无法读取镜像包数据库" ;;
		*) bad "required-packages.txt 反查未通过（见上面的 FAIL 行）" ;;
		esac
	else
		echo "SKIP  unsquashfs 解包失败，跳过 rootfs 目标与包集合检查"
	fi
else
	echo "SKIP  无 unsquashfs，跳过 rootfs 目标与包集合检查"
fi

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
