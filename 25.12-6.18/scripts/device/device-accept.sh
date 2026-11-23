#!/usr/bin/env bash
# 刷机后取证：经 USB 管理链路（默认 192.168.1.1）只读采集 S3d mainline
# 镜像的验收事实，输出供人工/模型判读。不改设备任何状态。
#
# 用法：
#   scripts/device/device-accept.sh [输出文件]
#
# 覆盖：版本与板卡、banner、数据通路门控（nss-board/S15nss//sys/ssdk）、
# 无线默认值（国家/SSID/信道/射频号）、时区、端口 MAC 与角色、LuCI、
# 风扇/LED、日志噪声。
#
# 本脚本不含凭据；执行时在提示处输入 root 密码一次（ControlMaster 复用）。

set -euo pipefail

HOST=root@192.168.1.1
OUT=${1:-/dev/stdout}
TMP="$OUT.tmp"

SOCK=$(mktemp -u /tmp/sbe-ssh-XXXXXX)
SSH=(ssh -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o "ControlPath=$SOCK" -o ControlPersist=600 "$HOST")
trap 'ssh -o "ControlPath=$SOCK" -O exit "$HOST" >/dev/null 2>&1 || true; rm -f "$SOCK"' EXIT

run() {
	local title=$1
	shift
	{
		echo "===== $title"
		"${SSH[@]}" "$*" 2>&1 | head -n 60
		echo
	} >> "$TMP"
}

: > "$TMP"

run "版本" 'cat /etc/openwrt_release; echo ---; uname -a; echo ---; cat /proc/uptime'
run "banner" 'sed -n "1,20p" /etc/banner'
run "板卡" 'ubus call system board 2>/dev/null | head -40'
run "数据通路门控" '
	ls -l /usr/lib/sbe1v1k/nss-board 2>&1
	/usr/lib/sbe1v1k/nss-board; echo "nss-board rc=$?"
	(test -d /sys/ssdk && echo "/sys/ssdk 存在" || echo "/sys/ssdk 不存在")
	pgrep -af nss-load || echo "nss-load 未运行"
	lsmod | grep -E "qca_nss|qca_ssdk" | head -3 || echo "无 NSS 模块装载"
	logread | grep -ic "ssdk\|nss" | sed "s/^/logread 中 ssdk\/nss 行数: /"
'
run "无线：国家与射频" 'iw reg get 2>/dev/null | head -12; for p in /sys/class/ieee80211/*; do echo "--- $p"; iw phy $(basename $p) info 2>/dev/null | grep -E "Band|Frequencies" | head -4; done'
run "无线：UCI 默认值" 'uci show wireless 2>/dev/null | grep -E "ssid=|channel=|htmode=|country=|disabled=" | head -40'
run "无线：AP 状态" 'ubus call network.wireless status 2>/dev/null | head -60'
run "无线：发射功率列表（S3d 缺陷 1 修复验证）" '
	for d in radio0 radio1 radio2; do
		echo "--- $d"
		ubus call iwinfo txpowerlist "{\"device\":\"$d\"}" 2>&1 | tr -d "\n\t" | head -c 1200; echo
	done
	echo "--- 255 dBm 残留计数"
	for d in radio0 radio1 radio2; do
		printf "%s: " "$d"
		ubus call iwinfo txpowerlist "{\"device\":\"$d\"}" 2>&1 | grep -c "\"dbm\": 255" || true
	done
'
run "firewall.d 门控（S3d 缺陷 2 修复验证）" '
	ls -l /etc/firewall.d/qca-nss-ecm
	grep -n "nss-board" /etc/firewall.d/qca-nss-ecm
	/etc/firewall.d/qca-nss-ecm; echo "firewall.d rc=$?"
	logread | grep -c "iptables: not found" | sed "s/^/启动日志 iptables-not-found 行数: /"
	logread | grep "firewall.d/qca-nss-ecm" | head -3
'
run "时区与时间" 'uci get system.@system[0].timezone; uci get system.@system[0].zonename; date'
run "端口与 MAC" 'ip -br link | grep -Ev "lo|wlan|phy|wlan[0-9]"; echo ---; ls /sys/class/net | tr "\n" " "'
run "网桥与角色" 'ip -br addr | grep -E "br-lan|wan|lan[0-9]"; echo ---; bridge link 2>/dev/null | head -20'
run "LuCI" 'wget -q -O /dev/null -o /dev/null http://127.0.0.1/ && echo "LuCI HTTP 200/30x" || echo "LuCI 不可达（含重定向缺省）"; wget -S -O /dev/null http://127.0.0.1/ 2>&1 | head -3'
run "风扇与 LED" 'for h in /sys/class/hwmon/hwmon*/; do f=$(ls $h | grep -E "^(pwm1|fan1_input|temp1_input)" | head -3); [ -n "$f" ] && { echo "$h"; for x in $f; do printf "%s=" "$x"; cat "$h$x"; done; }; done; ls /sys/class/leds | tr "\n" " "'
run "服务状态" 'for s in nss sbe-port-roles sbe-lan-mac eth0-lan-attach wireless-defaults; do printf "%s: " "$s"; /etc/init.d/$s enabled 2>/dev/null || echo "-"; done'
run "日志噪声" 'logread | grep -Eic "error|failed|EINVAL|out of range|usage:" | sed "s/^/logread 噪声行数: /"; logread | grep -Ei "error|failed|EINVAL|out of range" | head -10'
run "dmesg 噪声" 'dmesg | grep -Ei "error|fail|panic|oops" | head -15 || true'

mv "$TMP" "$OUT"
echo "已写入 $OUT"
