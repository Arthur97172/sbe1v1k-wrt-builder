# WAN TX 楔死同工况 A/B：25.12-6.18 vs 24.10-6.6（2026-11-26）

状态：**PASS（6.18 零楔死）**。同一设备、同一压测形状、同一上游，24.10 在
1–3.5 分钟内必楔死（历史 7/7）；6.18 跑满 25 分钟、约 23 GB、1100 万
WAN TX 包，零楔死、零丢包、零链路抖动。结论：楔死是 24.10 栈级缺陷
（内核/nss-dp/ecm 组合或其集成），不是硬件/PHY/端口模式问题，6.18 栈
可以作为后续根因 diff 的参照。

## 1. 被测镜像与刷入

- 镜像：GitHub Release `25.12-6.18-v15-1-fddb6d8a` 的 sysupgrade 资产
  （92,999,972 B，sha256 `b9af71ce…8672`，容器 `BOARD=askey_sbe1v1k`），
  与 11-25 审计（`docs/FIRMWARE-AUDIT-2026-11-25.md`）同一构建。
- 设备：第三台（USB 2.5G 网卡 enxc84d4424a1b5 → eth0 10G LAN，LAN
  192.168.1.1；eth1 2.5G WAN → 上游 Spectrum 网关）。
- 起始系统为 24.10（`sbe1v1k-g3.5c`，board `spectrum,sbe1v1k`），按 S1b
  先例 `sysupgrade -F -n`（镜像 board 为上游原生 `askey_sbe1v1k`；分区
  按 GPT 标签 p25/p26 `0:HLOS`、p27/p28 `rootfs` 写入，跨树安全）。
- 启动：`OpenWrt SNAPSHOT sbe1v1k-6.18-fddb6d8a`、6.18.64、
  `root=/dev/mmcblk0p27`、tier=full（11 个 qca_nss 模块在载）、eth1
  2500M + DHCP 192.168.10.237、默认路由与出网正常。

## 2. 判据改造（6.18 特有）

6.18 的 NSS offload 不更新 eth1 netdev 计数（整轮压测 eth1
`tx_packets/rx_packets` 恒为 0，而 eth0 rx 字节随流量增长），24.10 的
「tx_packets 冻结」判据不可用。改用三层判据（`/tmp/sbe-flash/wedge-loop8.sh`）：

1. 主机侧下载文件不再增长（3 次 2 s 轮询 ≈ 6 s 停滞）；
2. 主机经路由器 ping 223.5.5.5 连续 100% 丢包；
3. 路由器侧 `/sys/ssdk/packet_counter` 快照（允许在楔死态读）：
   `port=0005`（WAN TX）与 `queue=0208` 计数冻结。

机上 1 Hz 日志器 `box-mon618.sh`（SSDK 快照，不读 netdev）落盘 p5/p6/q208/
eth0rx/carrier/carrier_changes。2 分钟自检无楔死、无误报后才开正式轮。

注：24.10 用的 `ssdk_sh debug reg get` 寄存器偏移（0x84ed00、0x476050 等）
在 6.18 SSDK 读不到对应值（读回 0/异常），取证以 `/sys/ssdk/packet_counter`
文本为准。

## 3. 压测结果

形状与 24.10 楔死复现条件一致：主机 `curl --interface` 绑定 USB 网卡，
单流 TUNA ISO 下载（约 9–15 MB/s），每轮 max-time 420 s，循环到时限。

| 项 | 结果 |
| --- | --- |
| 时长 | 04:13:09 → 04:38:11（25 min，569 次轮询） |
| 轮次 | 4 轮 4.08 GB 全量 + 1 轮 3.98 GB（max-time 截断）+ 第 5 轮 2.74 GB |
| 总流量 | ≈ 23.1 GB |
| port5 TX（WAN） | 704k → 11,117k 包，单调增长 |
| q208 | 与 port5 TX 同步增长（704k → 11,117k） |
| 主机 ping 经路由器 | 全程 0% 丢包（0 次 100% 丢包行） |
| 链路 | carrier=1、2500、carrier_changes=2（开机后未抖动） |
| dmesg | 仅 11-25 审计已归档的基线噪声，无新 error/timeout |
| 资源 | MemAvailable 1.30 GB、load 0.03 |

证据：`/tmp/sbe-flash/wedge8-041309.log`（主机轮询）与其
`.boxlog`（机上 1498 行 1 Hz 采样）。

## 4. 对照 24.10 基线

| | 24.10-6.6 | 25.12-6.18 |
| --- | --- | --- |
| 触发 | 7/7 轮次楔死 | 0/25 min 楔死 |
| 时间 | 66 s – 16 min，近期 1–3.5 min | — |
| 流量阈值 | 0.88–2.5M 包（1–2 GB 级） | 11.1M WAN TX 包（≈23 GB）无异常 |
| 端口模式 | SGMII_CHANNEL0 0x0f（USXGMII 实验同样楔死） | SGMII_CHANNEL0 0x0f |
| netdev 计数 | eth1 tx_packets 可读、楔死时冻结 | offload 流量不计入 eth1 netdev |

## 5. 结论与下一步

1. **端口模式/PHY/硬件排除**：6.18 用与 24.10 相同的 0x0f 配法却零楔死，
   与 USXGMII 实验结论（§WAN-TX-WEDGE-2026-11-25 §6.5）互相印证。
2. **缺陷在 24.10 栈**：差异域 = 内核（6.6 vs 6.18）、qca-nss-dp、ECM
   集成/装载方式（24.10 走 /etc/init.d 全量自动装载，6.18 走 nss-load
   tier 分层）。qca-ssdk/qca-nss-ppe 两边源码逐字节相同（11-25 结论）。
3. 下一步建议（按优先级）：
   - 在 24.10 树上做 nss-dp/ECM 与 6.18 的定向 diff（装载顺序、EDMA
     ring 配置、ecm 直接引擎注册），寻找可回移的差异——**已完成
     （2026-11-26）：无可回移补丁，全栈差异只是内核兼容层，差异域收敛
     到内核。结果见 `24.10-6.6/docs/WAN-TX-WEDGE-2026-11-25.md` §8**；
   - 如需更强证据，可在 6.18 上重复一轮 ≥ 60 min 的 soak（当前单轮 25 min
     已 7–10 倍于 24.10 的触发阈值）；
   - 看门狗仅 24.10 需要；6.18 不需要移植（本测试支持该判断，但长跑统计
     仍缺）。
