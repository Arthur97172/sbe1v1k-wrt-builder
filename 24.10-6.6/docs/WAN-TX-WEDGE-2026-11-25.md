# WAN eth1 TX 冻结（wedge）取证与兜底方案 — 2026-11-25

状态：**根因定位到 PPE 端口 TX 数据通路；2026-11-26 找到有效 in-band 复位
（自协商速率变化触发 `ssdk_port_clock_reset`），看门狗 v2 已实现「先原地
复位、失败才重启」并真机 PASS**。本文件记录 2026-11-25 全部真机取证与
2026-11-26 复位实验，供后续追查与厂商上报使用。

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

## 6. 兜底：WAN TX 冻结看门狗（v131 起先原地复位，失败才重启）

- 入口：`/etc/init.d/sbe-wan-tx-watchdog`（START=96，`include/rootfs.mk`
  自动 enable）；worker：`/usr/sbin/sbe-wan-tx-watchdog`；
  配置：`/etc/config/sbe_wan_tx_watchdog`。
- 判定：15 s 采样；carrier=1 且有 IPv4 地址时，RX 前进而 TX 冻结累计
  ≥90 s → 169.254.255.254 假邻居 ARP 探针（只走链路层）确认；探针发不
  出去即确认冻结。
- 动作：取证写 `/etc/sbe-wan-tx-watchdog-evidence.log`（sysfs 计数 +
  q208/COMP/mac_en/flush_cfg + packet_counter TX/DROP 行），然后按 §6.2
  原地做一次端口时钟复位；复位成功记 `HEALED` 继续监控，失败记
  `HEAL-FAILED` 并 `reboot`。
- 防止自愈风暴：30 分钟窗口内最多 `max_heals`（默认 3）次原地复位、
  `max_reboots`（默认 3）次重启；超限仅 CRITICAL 日志等待人工。
  `heal=0` 关闭原地复位（退回纯重启），`enabled=0` 整体关闭。

### 6.1 真机验收（2026-11-26，v130-1-d7c112b0，PASS）

测试机刷 v130-1 镜像（`sysupgrade -n`）后，默认 ECM/SFE 全开，跑单流 NAT
下载触发真实楔死（mode-2 指纹），看门狗全链路闭环：

| 时间 | 事件 |
| --- | --- |
| 07:17:04 | 楔死：eth1 tx 冻结在 1,227,387，RX 仍缓慢前进 |
| 07:18:41 | `SUSPECT`（uptime 445 s，TX 冻结累计 ≥90 s） |
| 07:18:46 | `CONFIRMED`：ARP 探针前后 tx 不变 → 自动重启 |
| 07:19:09 | 设备回网；WAN 下载 5 MB 正常（206） |

`/etc/sbe-wan-tx-watchdog-evidence.log` 内容（原样）：

```
2026-11-26 07:18:41 [SUSPECT] uptime=445s tx=1227387 rx=6360806 carrier=1
2026-11-26 07:18:46 [CONFIRMED] uptime=450s tx=1227387 rx=6360890 carrier=1
speed=2500 carrier_changes=2 tx_errors=0 tx_dropped=0
q208_ac=0x0 comp5=0x18 mac_en=0x73 flush_cfg=0x80000
PORT_TX_COUNTER_TBL TX: ... 1227581(port=0005) ...
```

（顺手修掉本次验收暴露的计数 off-by-one：首次重启曾记成 2 次。）

### 6.2 原地复位自愈（v131 起，2026-11-26 真机验证）

楔死态不再只能靠重启恢复。SSDK 在「链路 up 且协商速率与旧速率不同」时会
执行 `adpt_hppe_port_speed_change_port_clock_reset()`（adpt_hppe_portctrl.c:4716），
即 `ssdk_port_clock_reset`：XGMAC + 端口 TX/RX 硬复位。此前所有失败的
in-band 手段都不包含这个复位。用自协商广告位图制造两次确定的速率变化：

```
ssdk_sh port autoAdv set 5 0x230   # 1000T_FD|PAUSE|ASY_PAUSE
ssdk_sh port autoNeg restart 5     # 2500 -> 1000（第一次端口时钟复位）
ssdk_sh port autoAdv set 5 0x123f  # QCA8081 出场广告（实测值）
ssdk_sh port autoNeg restart 5     # 1000 -> 2500（第二次端口时钟复位）
```

真机结果（设备 3，v130-1，ECM engine=auto，看门狗停用）：

| 轮次 | 楔死 | 收窄到 1G 后 | 恢复 2.5G 后 | 主机 NAT |
| --- | --- | --- | --- | --- |
| 1 | 07:47 tx=6038500 冻结，ping 网关 FAIL | speed=1000，tx 复活，ping OK | speed=2500，tx 前进 | HTTP 206 / 5 MB |
| 2 | 07:52 tx=7344592 冻结，ping 网关 FAIL | speed=1000，tx 复活，ping OK | speed=2500，tx 前进 | HTTP 206 / 5 MB |

每次复位链路中断约 8–10 s，无需重启。看门狗 v2 已内置该序列
（`option heal '1'`）：CONFIRMED 后先原地复位并用 ARP 探针再确认，
成功记 `HEALED` 继续监控；复位失败（或 30 分钟内超过 `max_heals`）
才回退到重启。注意楔死在高负载下数分钟内可复发，复位是按次自愈而非
杜绝根因。

看门狗 v2 自动路径真机验收（同一台设备，脚本 `/tmp/wd2` = 本次提交）：

| 时间 | 事件 |
| --- | --- |
| 07:55:10 | v2 启动（阈值 90 s，复位上限 3，重启上限 3） |
| 07:59:43 | 单流 NAT 下载触发楔死 |
| 08:01:10 | `SUSPECT`（uptime 2521 s，tx=9331432 冻结） |
| 08:01:15 | `CONFIRMED`（ARP 探针发不出去） |
| 08:01:31 | `HEALED`（speed=2500，tx 已推进；复位耗时 16 s） |

复位后主机经 NAT 下载 HTTP 206 / 5 MB 正常；`/etc/sbe-wan-tx-watchdog.heal`
记录首次复位，evidence 日志含 SUSPECT/CONFIRMED/HEALED 三行。

第二次自动复位后紧接着做持续负载 soak：3 轮单流下载各 4 GB（共 12 GB、
约 10 分钟，13–40 MB/s），**全程零楔死**，看门狗未再触发。此前楔死在持续
负载下 1–3 分钟即复发，说明端口时钟复位不只是逐次救活，复位后的端口状态
在相当长时间内是健康的（单次观测，未做长跑统计）。

### 6.3 判定条件说明

判定要求「RX 前进而 TX 冻结」，是为了避免在 WAN 完全空闲时误报。本轮
楔死后的 RX 增量来自上游对丢失 ACK 的 TCP 重传，因此条件成立；如果现场
一侧完全静默（无任何入向流量），stall 不会累计、看门狗保持沉默，等下一次
有入向流量再判。这是预期行为。

- 验收（待真机，设备恢复后）：人为触发楔死 → 看门狗应在 ~2 分钟内确认、
  落盘并重启；恢复后 WAN 正常；evidence 日志含 CONFIRMED 行。

## 7. 未决与下一步

1. 看门狗 v2（先原地复位、失败才重启）随下一版 24.10 发布；release notes
   写成"TX 冻结时原地端口复位自愈，复位失败才自动重启"。
2. 根因仍在 PPE 端口 TX 数据通路内部；触发因素已锁定 ECM/PPE flow
   offload（A/B/A），但尚无预防手段。后续若想杜绝复发，方向是 QM/PPE
   队列与端口 TX 通路的更深层配置（需 SSDK/PPE 寄存器级证据，楔死态只
   可读安全路径，见 §5）。
3. 高负载下楔死数分钟内可复发：看门狗按次复位（`max_heals` 限流），
   单次中断 8–16 s；持续大流量场景下用户会感知周期性短暂断流，需在
   release notes 说明。
4. 25.12-6.12 / 6.18 尚未观察到同类楔死（6.18 10 分钟 NAT 压测 PASS），
   暂不移植看门狗；一旦现场复现再移植（复位序列与看门狗 v2 可直接复用）。
