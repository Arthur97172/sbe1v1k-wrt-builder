# WAN eth1 TX 冻结（wedge）取证与兜底方案 — 2026-11-25

状态：**触发因素锁定 ECM/PPE flow offload；端口 MAC 模式/时钟已排除
（2026-11-26 USXGMII 单变量实验 FAIL，§6.5），卡点收窄到 QM/PPE 端口 TX
取包侧；in-band 复位有效（自协商 2500→1000→2500），看门狗 v2 已实现
「先原地复位、失败才重启」并真机 PASS，USXGMII 下同样有效**。本文件记录
2026-11-25/26 真机取证（含 Stage 1 寄存器取证，§6.4），供后续追查与厂商
上报使用。

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

**截至 2026-11-25 只有整机重启能恢复；2026-11-26 起 AN 双翻转可原地
复位（§6.2），是按次自愈，根因未消除。**

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

楔死态不再只能靠重启恢复。早先的解释是「速率变化触发
`adpt_hppe_port_speed_change_port_clock_reset()` →
`ssdk_port_clock_reset`：XGMAC + 端口 TX/RX 硬复位」，2026-11-26 源码复核
否定了该机制（见下方机制段）。用自协商广告位图制造两次确定的速率变化：

```
ssdk_sh port autoAdv set 5 0x230   # 1000T_FD|PAUSE|ASY_PAUSE
ssdk_sh port autoNeg restart 5     # 2500 -> 1000（第一次端口时钟复位）
ssdk_sh port autoAdv set 5 0x123f  # QCA8081 出场广告（实测值）
ssdk_sh port autoNeg restart 5     # 1000 -> 2500
```

机制（2026-11-26 源码复核修正）：port5 是 QGMAC + uniphy1 SGMII_CHANNEL0
（`switch_mac_mode1=0x0f`、phy-mode `sgmii`、`port_mac_sel QGMAC_PORT`），
不是 USXGMII，所以 `adpt_hppe_port_speed_change_port_clock_reset()`
（adpt_hppe_portctrl.c:4716）里的 `ssdk_port_clock_reset` 在 SGMII 分支是
空操作。真正生效的是速率变化本身：2500→1000 触发
`adpt_hppe_sgmii_speed_clock_set` → `ssdk_port_speed_clock_set`（NSSCC
port5 RX/TX 时钟 clk_set_rate 125 MHz）+ `ssdk_uniphy1_clock_source_set`
（uniphy1 TX/RX 时钟源 mux 切到原生时钟）；TX 恰在「降到 1G」这一步恢复。
卡点因此改为 **GMAC TX FIFO 与 uniphy1 SGMII+ 速率适配之间的 TX 方向**
（时钟由 NSSCC port5 TX clock 提供），而不是 PPE port wrapper 内部。另一个
关键事实：`adpt_hppe_sgmii_speed_clock_set` 没有 `FAL_SPEED_2500` 分支
（走 default 空），2.5G SGMII+ 在 SSDK 时钟表里本就不完整；QCA 参考板
（rdp475 等）把 2.5G QCA8081 口配成 USXGMII（`switch_mac_mode1=0x0d`），
该分支对 2500 有完整时钟编程（`adpt_hppe_usxgmii_speed_clock_set`，含
GMAC 4bit 宽度路径）。注意我们的 6.18 树沿用 0x0f、同样没做这个验证。

> 后续修正：上述「卡点在 GMAC TX FIFO ↔ uniphy1 速率适配」的判读已被
> 2026-11-26 USXGMII 实验推翻（§6.5）——改成 rdp475 的 0x0d 完整时钟
> 编程后楔死原样复现。复位序列本身仍有效（见下），但生效机制应理解为
> 速率变化导致端口 TX 通路整体重设，而非 SGMII 时钟表缺 2500。卡点现
> 收窄为 QM/PPE 端口 TX 取包侧。

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

- 看门狗验收已在 §6.1 与本轮 Stage 1 真机测试中完成（约 2 分钟内确认、
  落盘、复位或重启、WAN 恢复）。

### 6.4 Stage 1 寄存器取证（2026-11-26，v131-stage1 真机）

看门狗取证扩展（`macdbg_sweep=1`）在 HEALTHY-BOOT / STALL-START / SUSPECT
/ CONFIRMED / HEALED 各时点落盘 port5 GMAC、q208、PSCH COMP 寄存器，并在
HEALTHY-BOOT / CONFIRMED / HEALED 三态各扫一遍 MAC 内部调试空间 0..255 字
（写 MAC_DBG_ADDR 0x1820 选索引、读 MAC_DBG_DATA 0x1824；这是快照里唯一
的写操作，只动调试索引，不碰 MAC 配置寄存器）。

三态对比（同一轮楔死，mode-1 指纹，单流 NAT 下载第 3 轮触发）：

| 寄存器 | HEALTHY-BOOT | 楔死（CONFIRMED） | HEALED |
| --- | --- | --- | --- |
| q208 AC_UNI_CNT（0x84ed00） | 0x0 | 0x44 → 0x7c → 0x81（随探针增长） | 0x0 |
| PSCH[5] COMP（0x476050） | 0x18 | 0x0 | 0x18 |
| MAC_CTRL2（0x1818） | 0xc300008 | 0xc300000（bit3 掉） | 0xc300008 |
| MAC_ENABLE / SPEED | 0x73 / 0x2 | 不变 | 不变 |
| flush / drop / enq / deq | — | 全不变 | — |

- **MAC_CTRL2 bit3 = MAC_LPI_TX_IDLE**（hppe_portctrl_reg.h）：健康 1 →
  楔死 0 → 复位后回 1，即 GMAC TX 引擎闩在「非空闲」，与 §6.2 修正后的
  卡点（GMAC TX FIFO ↔ uniphy1 SGMII+ TX）一致。
- **EEE/LPI 路径已排除**：`ssdk_port_eee_init()` 只在 `phydev->eee_enabled`
  时开 LPI，qca808x 驱动（eth1 PHY）完全没有 EEE 代码 → LPI 实际关闭，
  bit3 是 TX 空闲状态位，不是 EEE 卡死。
- **bit3 写实验已否决**：楔死态 `ssdk_sh debug reg set 0x1818 0xc300008`
  执行成功但读回仍是 0xc300000（bit3 硬件驱动、软件锁存不进去），TX 无
  恢复 → bit3 只是症状，不是自愈旋钮。
- **MAC_DBG 256 字扫描**：楔死稳定差异 idx 177（bit22 掉，0x4001c0 →
  0x1c0/0x1c6）、179、180、181（mode-1 掉 bit13 / mode-2 掉 bit6）、196、
  198；易变项 1、161、162、163、178、197 两次健康扫描互异，勿当指纹；
  mode-1 与 mode-2 的扫描差异集中在 192–195（q208 有无流量所致）。

两模式对比（2026-11-25/26 多次真机）：

| | mode-1 | mode-2 |
| --- | --- | --- |
| q208 AC | 0x44+ 积压且随探测增长 | 0x0 恒空 |
| PSCH COMP[5] | 0x18 → 0x0 | 保持 0x18 |
| MAC_CTRL2 bit3 | 0 | 1 |
| 卡点判读 | PPE 不再取队列 | PPE 取包、端口 TX 吞包（卡点更靠上游） |
| idx177 bit22 | 掉 | 掉（共同标记） |
| AN 双翻转 | 可复活 | 可复活 |

mode-2 经 AN 双翻转同样复活（§6.2 表只覆盖了 mode-1）。翻转会拆掉 eth1
的 DHCP 租约，上游重新分配要等 20–65 s；这段窗口 ping 不通是「没有地址」
而不是「没修好」，勿误判为自愈失败。

取证日志：本机 `/tmp/sbe-flash/evidence-stage1.log`，mode-2 扫描
`/tmp/sbe-flash/macdbg-mode2-wedged.txt`。

### 6.5 USXGMII 单变量实验（2026-11-26，FAIL）

配置级预防实验（用户批准）：24.10 树上只改两行，把 port5 从
SGMII_CHANNEL0 改成 QCA 参考板 rdp475 的 USXGMII 配法——

- `switch_mac_mode1`：`0x0f` → `0x0d`；
- port@4 `phy-mode`：`"sgmii"` → `"usxgmii"`。

其余一切不变（QGMAC 选口、看门狗、ECM/PPE full 均不动）。镜像 78.8M，
sha256 `7718291f…5d52`，DTB 反编译确认 0x0d；`sysupgrade -n` 刷入后
`configured for phy/usxgmii`、2500 链路、DHCP 192.168.10.237、上游 ping
通、tier=full 装载正常。

结果：**第 1 轮压测约 3.5 分钟即楔死，mode-1 指纹与 SGMII 基线完全同构**：

| 证据 | SGMII 基线 | USXGMII 实验 |
| --- | --- | --- |
| 楔死时间 | 1–3 min | ~3.5 min（03:45:14 UTC+8 计 280 s uptime） |
| q208 AC | 0x44+ 积压 | 0x0 → 0x42 → 0x56 积压 |
| PSCH COMP[5] | 0x18 → 0x0 | 0x18 → 0x0 |
| MAC_CTRL2 | 0xc300008 → 0xc300000 | 0xc300008 → 0xc300000 |
| AN 双翻转 | 复活 | 复活（SUSPECT 374 s → HEALED 399 s，19 s） |

判定：**端口 MAC 工作模式 / 端口时钟编程不是根因**。USXGMII 分支在 SSDK
里对 2500 有完整时钟编程，但仍以同样方式楔死，卡点收窄到
**QM/PPE 端口 TX 取包侧**（PPE 停止从 q208 取包，队列积压、COMP 停摆），
与 GMAC/uniphy 的速率适配无关。同时确认看门狗 AN 双翻转自愈在 USXGMII
下同样有效，兜底方案不受 mac mode 影响。

实验配置已回滚（DTS 回到 0x0f/"sgmii"，附注释记录结论）。设备当前仍跑
实验镜像；两者功能等价（链路 2500、看门狗生效），下次正式构建自然恢复
基线 DTS。

日志：本机 `/tmp/sbe-flash/wedge7-034153.log`；设备
`/etc/sbe-wan-tx-watchdog-evidence.log`（STALL-START 11:45:28 uptime=299）。

## 7. 未决与下一步

1. 看门狗 v2（先原地复位、失败才重启）随下一版 24.10 发布；release notes
   写成"TX 冻结时原地端口复位自愈，复位失败才自动重启"。
2. 根因仍未消除：触发因素已锁定 ECM/PPE flow offload（A/B/A）。USXGMII
   单变量实验已 FAIL（§6.5），mac mode / 端口时钟被排除；卡点收窄为
   **PPE 端口 TX 取包侧**（PPE 停止从 q208 取包，mode-1 队列积压、COMP 停
   摆；mode-2 更靠上游）。6.18 同工况 A/B 已完成：同一压测形状下 6.18
   跑 25 min / ≈23 GB / 1100 万 WAN TX 包零楔死（24.10 为 1–3.5 min
   必楔），见 `25.12-6.18/docs/WAN-TX-WEDGE-AB-2026-11-26.md`。下一步
   转向 24.10 与 6.18 的 nss-dp/ECM 装载集成定向 diff，找可回移差异。
3. 高负载下楔死数分钟内可复发：看门狗按次复位（`max_heals` 限流），
   单次中断 8–16 s；持续大流量场景下用户会感知周期性短暂断流，需在
   release notes 说明。
4. 25.12-6.12 与 24.10 的 qca-ssdk/qca-nss-ppe 源码逐字节相同，楔死风险
   按同构对待；6.18 尚未观察到楔死，但样本短（10 分钟 NAT 压测、1.67 GB，
   而楔死历史上 66 s–16 min 均出现过），且 6.18 的内核、nss-dp、PHY 驱动
   均不同，不能单独归因于 mac mode。暂不移植看门狗到 25.12；一旦现场复现
   再移植（复位序列与看门狗 v2 可直接复用）。
