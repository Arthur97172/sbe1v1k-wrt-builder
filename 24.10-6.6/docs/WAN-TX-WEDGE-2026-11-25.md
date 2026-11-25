# WAN eth1 TX 冻结（wedge）取证与兜底方案 — 2026-11-25

状态：**根因定位到 PPE 端口 TX 数据通路（软件不可达层）；兜底看门狗已进
overlay，真机 NOT TESTED**。本文件记录 2026-11-25 全部真机取证，供后续
追查、厂商上报与看门狗验收使用。

## 1. 现象

持续 NAT 下载（测试机从内网经 eth0 入口下载，出 eth1 上互联网）后，
`eth1`（WAN，QCA8081 2.5G，SSDK port 5，QCOM GMAC @0x1800）的 TX 方向静默
冻结：

- `carrier=1`、`speed=2500`、`carrier_changes=2`（无链路抖动）；
- RX 仍在推进（楔死后仍缓慢增长），TX 一个包都不动；
- 上游与互联网全部不可达（本机 ping 100% 丢包），SSH 管理走 eth0 不受影响；
- 无 dmesg 告警、无 tx_errors/tx_dropped/tx_fifo_errors 增长；
- 出现时间 66 s ~ 16 min 不等，与累计流量/时长弱相关，可复现。

## 2. 可复现方法（2026-11-25 定稿）

`/tmp/sbe-flash/wedge-loop7.sh [分钟]`：单流 TUNA ISO 下载（~13 MB/s），
2 s 轮询 ping + tx/rx，冻结 3 次即判楔死；机上 1 Hz 寄存器记录器
`box-mon.sh` 可选（`NOLOG=1` 跳过）。注意：脚本运行中不可编辑（bash 按
字节偏移读取）。

## 3. 现场指纹（两种，交替出现）

| | mode-1（早期多次） | mode-2（2026-11-25 16:46） |
| --- | --- | --- |
| q208 积压（0x84ed00） | 0x3c+ 且随探测增长 | 0x0，恒空 |
| PSCH COMP p5（0x476050） | 0x18 → **0x0**（与冻结同秒） | 保持 0x18（健康） |
| QUEUE_TX queue0208 | 冻结 | 比 netdev tx 多 ~90 包后冻结 |
| EDMA TX ring 占用率 | — | 全部 ring 0%（无主机侧积压） |
| 结论 | PPE 不再取包 | PPE 取包但端口 TX 吞包 |

两种状态下 GMAC MIB（netdev tx_packets）、PORT_TX_COUNTER port5 均冻结，
且无任何 drop 计数增长。mode-2 中 QM 已排空、调度器健康、主机 TX 环健康，
说明卡点在 PPE 端口 5 的 TX 数据通路（QM/TM 之下、GMAC 擦写之上）。

## 4. 已排除的机制（全部真机验证）

- 暂停帧/流控：RXPAUSE 计数为 0；清 MAC TX 流控位（0x1800 bit6，0x73→0x33）
  后**仍楔死**（V2 实验：多活了 441k→2.5M 包，属波动），恢复 0x73 无效果。
- MAC/PHY：txmac 翻转、PHY poweroff/poweron（含 carrier 掉/起）、
  `ip link set eth1 down/up`（nss-dp 整口重建）均不能恢复。
- QM：flush 引擎自身挂死（`queue 208 flush busily`，FLUSH_CFG 锁存）；
  enqueue 使能、DQ 丢弃、LL 链、AC 表、drop 计数全部正常。
- TM/调度器：L0/L1 表、ENS/DRR/SP、PSCH TDM 表在健康与楔死态一致；
  DEQ_DIS、QM 时钟门控解除无效；wedge-heal2（port5 TDM slot + L0/L1 flow
  map 同值重写）无效。
- 主机侧：EDMA tx_ring_stats 无积压、misc Tx SRAM full/timeout 计数 0。
- 触发条件：清流控位不阻断；加 1 Hz 寄存器读取可能加速（66 s vs 9 min 的
  差异，未定）。

**只有整机重启能恢复。**

## 5. 楔死态取证安全边界（重要）

楔死后**只能**读：sysfs netdev stats、`/sys/ssdk/packet_counter`、
`ssdk_sh debug reg get`、`/sys/kernel/debug/qca-nss-dp/stats/*`。

**禁止**读：`/sys/kernel/debug/qca-nss-ppe/*`、
`/sys/kernel/debug/qca-nss-netfn/flowmgr/stats`、`/sys/kernel/debug/ecm/ecm_db/*`
——2026-11-25 实测读这些路径后整机失联（管理口无 ARP 响应），只能物理断电。
uniphy/L1_SHP（0x45c000/0x45e000）寄存器读取同样会挂死 SSDK，禁止。

## 6. 兜底：WAN TX 冻结看门狗（本版新增）

- 入口：`/etc/init.d/sbe-wan-tx-watchdog`（START=96，`include/rootfs.mk`
  自动 enable）；worker：`/usr/sbin/sbe-wan-tx-watchdog`；
  配置：`/etc/config/sbe_wan_tx_watchdog`。
- 判定：15 s 采样；carrier=1 且有 IPv4 地址时，RX 前进而 TX 冻结累计
  ≥90 s → 169.254.255.254 假邻居 ARP 探针（只走链路层）确认；探针发不
  出去即确认冻结。
- 动作：取证写 `/etc/sbe-wan-tx-watchdog-evidence.log`（sysfs 计数 +
  q208/COMP/mac_en/flush_cfg + packet_counter TX/DROP 行），然后 `reboot`。
- 防止重启风暴：30 分钟窗口内最多 `max_reboots`（默认 3）次；超限仅
  CRITICAL 日志等待人工。`enabled=0` 可整体关闭。
- 验收（待真机，设备恢复后）：人为触发楔死 → 看门狗应在 ~2 分钟内确认、
  落盘并重启；恢复后 WAN 正常；evidence 日志含 CONFIRMED 行。

## 7. 未决与下一步

1. 测试机于 16:49 因 debugfs 读挂死，需人工断电重启（设备号 3，
   192.168.1.1）。
2. 设备恢复后：控制实验（默认 0x73、NOLOG=1）确认基线楔死时间分布；
   ECM/SFE `tier=wired` 对比实验（判断 flow offload 是否相关）。
3. 若定位到可规避配置，优先发布配置修复；否则看门狗随下一版 24.10 发布，
   并在 release notes 中如实写明"自动重启兜底"。
4. 25.12-6.12 / 6.18 尚未观察到同类楔死（6.18 10 分钟 NAT 压测 PASS），
   暂不移植看门狗；一旦现场复现再移植。
