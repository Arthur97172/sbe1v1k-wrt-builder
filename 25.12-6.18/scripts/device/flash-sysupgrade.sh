#!/usr/bin/env bash
# 刷机：把本地 sysupgrade 镜像经 USB 管理链路（默认 192.168.1.1）传给
# 路由器并执行 `sysupgrade -n`（不保留配置）。
#
# 用法：
#   scripts/device/flash-sysupgrade.sh [镜像路径]
#
# 镜像默认取本地构建产物
# （openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin；
# 2026-11-24 起唯一设备即 NSS 数据通路）。
#
# 安全约定（项目 CLAUDE.md）：
#   - 密码不写进脚本、不放进命令行参数、不落盘；本脚本用 SSH ControlMaster
#     复用一条连接，密码只在终端提示处输入一次；
#   - 先取证当前运行版本，再传镜像，传完在设备上比对 sha256，一致才刷；
#   - 只接受 sysupgrade；不做 factory 刷写、不改 bootloader。
#
# 本脚本不含任何凭据；执行时由操作者在提示处输入密码。

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)
ROOT=$(CDPATH= cd -- "$PROJ/.." && pwd)
OUT="$ROOT/sources/buildroot-25.12-6.18/bin/targets/qualcommbe/ipq95xx"

HOST=root@192.168.1.1
IMG=${1:-$OUT/openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin}

[ -s "$IMG" ] || { echo "镜像不存在或为空：$IMG" >&2; exit 1; }
name=$(basename "$IMG")
local_sha=$(sha256sum "$IMG" | cut -d' ' -f1)

SOCK=$(mktemp -u /tmp/sbe-ssh-XXXXXX)
CTL=(-o ControlMaster=auto -o "ControlPath=$SOCK" -o ControlPersist=600)
SSH=(ssh -o StrictHostKeyChecking=accept-new "${CTL[@]}")
# dropbear 没有 sftp-server：OpenSSH 9+ 的 scp 默认走 SFTP 会报
# "/usr/libexec/sftp-server: not found"，必须加 -O 回到传统 scp 协议。
SCP=(scp -O -o StrictHostKeyChecking=accept-new "${CTL[@]}")
trap 'ssh -o "ControlPath=$SOCK" -O exit "$HOST" >/dev/null 2>&1 || true; rm -f "$SOCK"' EXIT

echo "== 建立连接（提示处输入 root 密码，仅本次会话）"
"${SSH[@]}" "$HOST" true

echo "== 刷机前取证：当前运行版本"
"${SSH[@]}" "$HOST" 'cat /etc/openwrt_release 2>/dev/null | head -8; echo ---; ubus call system board 2>/dev/null | head -12'

echo "== 传输镜像：$name（$local_sha）"
"${SCP[@]}" "$IMG" "$HOST:/tmp/$name"

echo "== 设备侧 sha256 校验"
remote_sha=$("${SSH[@]}" "$HOST" "sha256sum /tmp/$name" | cut -d' ' -f1)
if [ "$remote_sha" != "$local_sha" ]; then
	echo "sha256 不一致：本地 $local_sha / 设备 $remote_sha" >&2
	exit 1
fi
echo "sha256 一致"

echo "== 执行 sysupgrade -n（不保留配置；设备随后重启）"
"${SSH[@]}" "$HOST" "sysupgrade -n /tmp/$name" || true
echo
echo "已下发刷机命令。等待设备重启后运行："
echo "  scripts/device/device-accept.sh"
