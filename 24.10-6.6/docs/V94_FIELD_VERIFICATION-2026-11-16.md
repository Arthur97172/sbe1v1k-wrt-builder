# v94 真机刷写与验证记录

日期：2026-11-16
设备：SBE1V1K（B 机，同型号参照机）
镜像：24.10-6.6，`v94-1-da7e20bd`（commit `da7e20bd`，源码包 `sources-v25`），
刷后 `DISTRIB_REVISION='sbe1v1k-g3.5c'`，Linux 6.6.147

## 结论

恢复模式 RAM 系统 → `sysupgrade -F -n` 的刷写流程 **PASS**，刷后启动、三频
无线、客户端关联、DHCPv4/v6 与 NAT 上网均为真机实测 **PASS**。这是本项目
第一次有完整记录的 sysupgrade 观察（v78 的升级流程当时未记录，见
[V78_FIELD_VERIFICATION-2026-11-15.md](V78_FIELD_VERIFICATION-2026-11-15.md)）。

## 镜像来源

该次构建（run 94）的 Release 作业因 GitHub token 被判只读
（`HTTP 403: Resource not accessible by integration`）而没有发布，GitHub 上
没有 `v94-*` Release；镜像由用户从该次运行的产物手动下载，存放在主机
`/tmp/sbe1v1k-firmware-94/`。刷写前在主机上核对：

- `openwrt-ipq95xx-generic-spectrum_sbe1v1k-squashfs-sysupgrade.bin`
- 82,576,166 B，与 run 94 构建日志里的 sysupgrade 字节数一致
- sha256 `20bfa3e07ebfe7df0aa228992beefa2cfc7d16b7d1c66206cf4a3595310e7290`
- 结构：`sysupgrade-spectrum_sbe1v1k/{CONTROL,kernel,root}`，
  `CONTROL` 为 `BOARD=spectrum_sbe1v1k`，kernel 内嵌
  `ARM64 OpenWrt Linux-6.6.147`

## 刷写流程

1. 刷前 B 已在恢复 RAM 系统（官方 SNAPSHOT `r38189-706052b20f` / 6.18.60，
   model `Askey SBE1V1K`），root 密钥直登。
2. 上传：恢复系统 dropbear 没有 `/usr/libexec/sftp-server`，`scp` 会以
   `Connection closed` 失败；改用管道
   `ssh root@192.168.1.1 'cat > /tmp/img-v94.bin' < 本地镜像`。
3. 设备内 `sha256sum /tmp/img-v94.bin`，与主机逐字节一致后再刷。
4. `sysupgrade -F -n /tmp/img-v94.bin`。输出里的
   `upgrade: Device askey,sbe1v1k not supported by this image`
   （`Supported devices: spectrum,sbe1v1k`）是 RAM 系统 model 名与镜像
   board 名不同导致的预期告警，`-F` 放行；随后
   `Commencing upgrade. Closing all shell sessions.` 与
   `Command failed: … (Connection failed)` 是会话被杀，均属预期。
5. 约 54 秒后 `192.168.1.1` 恢复响应、SSH 可登。管理网线始终插在原
   LAN 口，不需要拔插。

## 刷后验证（主机 USB 网卡直连，只读命令）

| 项 | 结果 |
|---|---|
| 版本 | `OpenWrt 24.10-SNAPSHOT sbe1v1k-g3.5c`，Linux 6.6.147 |
| 根设备 | `root=/dev/mmcblk0p27` |
| overlay | `/dev/loop0` ext4 已挂载 rw，`overlayfs:/overlay on /` |
| LuCI | HTTP 200（Argon 主题页） |
| 无线 | 2.4G `ch11` EHT20、5G `ch40` EHT80、6G `ch37` EHT320 三频均 UP 且广播；`iw reg get` 为 US（DFS-FCC）；hostapd 运行 |
| 客户端 | 一台终端（随机 MAC `6e:7f:b7:…`）关联 2.4G，WPA3/SAE + MFP，平均信号 -64 dBm，收发计数持续增长 |
| DHCP/RA | 该客户端拿到 IPv4 `192.168.1.224` 与 IPv6 `fdcf:eaab:91c5::b9d0`（dnsmasq + odhcpd） |
| 上网 | WAN eth1（2.5G）DHCP 拿到 `192.168.10.123`，默认路由 `192.168.10.1`；设备自身 ping 8.8.8.8 零丢包、HTTPS `generate_204` 返回 204（0.33 s）；客户端的 TCP 443 会话在 conntrack 里回复方向已是 `dst=192.168.10.123`，即 masquerade（`oifname "eth1" jump srcnat_wan`）生效 |

## 说明

- 本次使用 `-n` 不保留旧配置，B 机刷后为首启默认状态。
- 观察到的显示噪音，非故障：`iwinfo` 报 Tx-Power 0 dBm、5G 频率标签显示
  6.150 GHz（`iw dev` 与实际信道均为 5200 MHz）；B 机 DNS 解析出
  `198.18.x.x` 是上游主路由 fake-IP（透明代理）返回的地址。
- 本记录只覆盖 v94 这版镜像在 B 机上的行为；A 机（生产机）状态另计。
