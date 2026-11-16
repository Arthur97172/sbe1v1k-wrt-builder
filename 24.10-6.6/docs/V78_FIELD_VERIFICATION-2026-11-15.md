# v78-1-627a88de 真机验证记录

日期：2026-11-15
设备：SBE1V1K（B 机，同型号参照机）
镜像：v78-1-627a88de = 24.10-6.6，`DISTRIB_REVISION='sbe1v1k-g3.5c'`，Linux 6.6.147

## 结论

用户报告：刷入 v78-1-627a88de 后已做**全面测试**，目前为止没有发现问题。
本文件记录该结论及其旁证，不重复罗列用户测试的具体项目；用户未覆盖的项目
仍按 `NOT TESTED` 计。

## 只读旁证（2026-11-15，主机 USB 网卡直连，SSH 只读命令）

- **版本**：`/etc/openwrt_release` 为 `24.10-SNAPSHOT sbe1v1k-g3.5c`，
  `ubus call system board` 报告内核 6.6.147、`spectrum,sbe1v1k`、squashfs。
- **镜像内容**：`opkg list-installed` 里有 `mosdns 5.3.4-r15`、
  `luci-app-mosdns 1.7.15-r1`、`luci-i18n-mosdns-zh-cn`（即 627a88d 的
  mosdns 迁移确实在该镜像里）。
- **端口与角色**（dmesg + `ip` + `uci`）：
  - `eth0` = dp1 = RTL8261N **10G**，24.10 里作为 unmanaged LAN 桥口挂在
    br-lan 上；实测把主机网线插 10G 口后 `Link is Up - 1Gbps/Full`
    （受主机网卡限制），br-lan 照常发 DHCP。
  - `eth1` = dp2 = QCA8081 **2.5G** = WAN，DHCP 从上游拿到 192.168.10.123。
  - `eth2` = dp3 = QCA8075 1G = LAN（管理口），主机拿到 192.168.1.244。
  - `eth3` = dp4 = QCA8075 1G = LAN，空置。
  - probe 顺序 dp1→dp4 对应 eth0→eth3，命名确定。
- **无线**：三个 VAP `phy00.0-0`（WiFi_2.4G）、`phy00.1-0`（WiFi_5G）、
  `phy00.2-0`（6G）均为 UP。
- **系统健康**：启动后负载 <0.5，内存 1.7 GB 总量、可用约 1.3 GB。

## 说明

- 升级到 v78 所用的具体流程用户未说明。README「升级（sysupgrade）与 A/B 槽位」
  一节的 `真机升级状态` 当时因此保持 `NOT TESTED`；关闭该状态所需的一次完整
  sysupgrade 观察已于 2026-11-16 由 v94 补齐，见
  [V94_FIELD_VERIFICATION-2026-11-16.md](V94_FIELD_VERIFICATION-2026-11-16.md)。
- 本记录只覆盖 v78 这版镜像在 B 机上的行为，A 机（生产机）状态另计。
