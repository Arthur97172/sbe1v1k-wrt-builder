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

> 2026-11-26 更新：根因判别已完成（§11）——触发点是 ath12k 的 FSE/PPE
> 回调注册（`fse=Y`），`options ath12k fse=0` 在 Wi-Fi 全功能 up 的
> 同形状下 30 min 零楔且保留有线 ECM；产品化与根因修复路线见 §11.6。

1. 看门狗 v2（先原地复位、失败才重启）随下一版 24.10 发布；release notes
   写成"TX 冻结时原地端口复位自愈，复位失败才自动重启"。
2. 根因仍未消除：触发因素已锁定 ECM/PPE flow offload（A/B/A）。USXGMII
   单变量实验已 FAIL（§6.5），mac mode / 端口时钟被排除；卡点收窄为
   **PPE 端口 TX 取包侧**（PPE 停止从 q208 取包，mode-1 队列积压、COMP 停
   摆；mode-2 更靠上游）。6.18 同工况 A/B 已完成：同一压测形状下 6.18
   跑 25 min / ≈23 GB / 1100 万 WAN TX 包零楔死（24.10 为 1–3.5 min
   必楔），见 `25.12-6.18/docs/WAN-TX-WEDGE-AB-2026-11-26.md`。nss-dp/ECM
   定向 diff 已完成（§8）：两层软件栈功能等价、无可回移补丁，差异域彻底
   收敛到内核。
3. 高负载下楔死数分钟内可复发：看门狗按次复位（`max_heals` 限流），
   单次中断 8–16 s；持续大流量场景下用户会感知周期性短暂断流，需在
   release notes 说明。
4. 25.12-6.12 与 24.10 的 qca-ssdk/qca-nss-ppe 源码逐字节相同，楔死风险
   按同构对待；6.18 尚未观察到楔死，但样本短（10 分钟 NAT 压测、1.67 GB，
   而楔死历史上 66 s–16 min 均出现过），且 6.18 的内核、nss-dp、PHY 驱动
   均不同，不能单独归因于 mac mode。暂不移植看门狗到 25.12；一旦现场复现
   再移植（复位序列与看门狗 v2 可直接复用）。

## 8. nss-dp/ECM 定向 diff（24.10-6.6 vs 25.12-6.18，2026-11-26）

结论先行：**不存在可回移的修复**。两层软件栈（qca-nss-dp、qca-nss-ppe、
qca-ssdk、qca-nss-ecm、qca-nss-sfe、qca-nss-drv）在 24.10 与 6.18 之间
功能等价，全部源码差异都是内核 API 对齐或编译告警修正；装载方式、ECM
引擎选择、EDMA ring 配置实测/逐字段一致。**差异域彻底收敛到内核**
（6.6 厂商树 vs 6.18 mainline + 移植层），"新栈里有修复可以搬"的设想被否定。

对照物：24.10 厂商源码经 feed 编译，源在装配树
`/var/tmp/sbe-2410/sources/buildroot/qca/src/nss/`（24.10 仓库内无 `nss/`
目录），包装与 init/config 在 `qca/feeds/nss/`；6.18 源在
`sources/buildroot-25.12-6.18/qca/src/nss/`，包装在 `25.12-6.18/nss/packages/`。

### 8.1 源码层差异

| 组件 | 差异量 | 性质 |
| --- | --- | --- |
| qca-nss-drv | 0 行 | 逐字节相同 |
| qca-nss-dp | 386 行 | 内核 API 兼容（register_sysctl_sz 哨兵、ctl_table const、timer_container_of、net_hotdata.rps_*、alloc_netdev_dummy、-Wmissing-prototypes）+ **删减** vendor 专属路径 |
| qca-nss-ppe | 631 行 | 上述兼容项 + dsa_user_dev_check 改名 + DSA tag 映射（无 DSA 用不到）+ MAP-T 关闭（无 MAP-T 设备） |
| qca-ssdk | 552 行 | 上述兼容项 + 我们自己的 6.18 补丁（USXGMII AN 恢复；SGMII 口用不到）+ sfp/mdio-i2c 编译桩 |
| qca-nss-ecm | 363 行 | 文件集相同（6.18 多 2 个 compat 头）；全部是 priv_flags_ext/int_pri shim、unaligned.h、nf_udp_pernet 等适配 |
| qca-nss-sfe | 575 行 | 同上是 `sfe_compat.h` 兼容层 |

6.18 唯一的行为性差异是**删掉**了厂商内核的加速设施：`dev_fast_xmit()` /
`dev_fast_xmit_qdisc()` 改走 `dev_queue_xmit()`、SKB recycler 完成路径改为
`dev_kfree_skb()`、Rx 缓存失效总是执行、`skb->int_pri` 不传递（结构体无
对应字段，恒 0）。这些是主线内核缺字段被迫的简化（源码注释里也写明
"behaviour gap of the mainline port"），不是针对楔死的修复。

### 8.2 装载与引擎注册

- 24.10：kmodloader 按 `/etc/modules.d` 自动装载（`09-qca-nss-sfe`、
  `31-qca-nss-dp/ppe`、`50-qca-nss-flowmgr`、`51/52-qca-nss-ppe-*`），rcS
  依次起 `qca-ssdk` START=16、`qca-nss-dp` START=18、`qca-nss-ecm` START=26。
- 6.18：tier=full 由 `/usr/sbin/nss-load` 串行装载
  ssdk → ppe → dp → ppe-{ds,vp,rule,vlan,bridge-mgr,ath-clients} → ecm，
  sfe 由 ecm init 按需装，不装 flowmgr。设备实测模块集合两边几乎相同
  （仅差 flowmgr）。
- 参数与配置：`/etc/config/ecm`（acceleration_engine auto）、
  `/etc/config/qca_nss_dp`（enable_rps 1）、`qca-nss-ecm.sysctl`、
  `qca-nss-ecm.defaults`、`qca-ssdk` 与 nss-dp 的编译开关（ipq95xx：
  PPE+SFE 前端、NSS 前端关、ECM standard 版）两边逐字节/逐项相同。
- 实测引擎选择：**两边都是 `selected_front_end=5`（ppe-sfe）**。24.10
  证据日志 37.7 s / 64.9 s 两次初始化；6.18 设备 dmesg 52.2 s / 66.1 s。
  此前测过的 engine=ppe(3) / engine=sfe(2) 都是人工覆盖，基线行为一致。

### 8.3 EDMA ring 与端口 DTS

24.10 `ipq9574-sbe1v1k.dts` 与 6.18 `ipq9570-sbe1v1k-nss.dts` 的 edma
节点逐字段相同：28 个 TX/TXCMP ring（4 起）、4 rxfill/rxdesc（20 起）、
ppeds 3 组（队列基 32/40/48 各 8）、txdesc-map、txdesc-fc-grp-map、
rx-ring-queue-map、vp-id 8 全部一致；6.18 多 4 项 loopback ring
（`dp-loopback=y`，24.10 同 Makefile 也会编译但 DTS 未给）。port5 两边都是
`switch_mac_mode1=0x0f` + `phy-mode "sgmii"` + `port_mac_sel QGMAC_PORT`。
6.18 的 PCS 节点与时钟补丁（6.18 补丁 0036/0040）是 6.18 内核自身需要，
24.10 厂商内核不经该路径。

### 8.4 判读与下一步

1. nss-dp/ECM 层没有"6.18 已修"的补丁可搬回 24.10；楔死的区别只能来自
   内核：24.10 是厂商 6.6（网络核心带 skb recycler、fast_xmit、QSDK 钩子），
   6.18 是 mainline + 兼容移植。ECM 触发、PPE 卡点、GMAC TX 不空闲这些
   现象在两栈里由同一份 ppe/ssdk/ecm 代码产生，差异只可能在内核这层。
2. 候选内核侧实验（均需用户批准后另行立项，本轮不做）：
   - 24.10 厂商内核上关闭/对照 SKB recycler、fast_xmit 等 vendor 设施
     （内核配置级，不动 ECM 功能，符合"保留 ECM"约束）；
   - 对照两内核在 nsscc/uniphy 时钟、DMA 描述符映射（dmac cache 操作）
     上的最后差异，逐一排除。
3. 产品侧选择仍是 25.12-6.18 生产 + 24.10 看门狗兜底（见 §7）。

## 9. 内核 vendor 设施对照实验：SKB recycler 与 fast_xmit（2026-11-26，第三台真机）

状态：**两项机制均已排除**。Phase A（recycler）与 Phase B（fast_xmit）
在 24.10-6.6 上都实测过，楔死照常复现；Phase B 还证明靶点不在热路径
（补丁行为惰性）。实验内核已从构建树回滚（06:13，dev.c 与备份逐字节
一致）；设备仍运行实验内核（与基线行为等价），下次刷机替换。

### 9.1 Phase A：关闭 SKB recycler 不阻止楔死

手法：运行时 `echo 0 > /proc/net/skb_recycler/skb_recycler_enable`，回读
为 0、pool `total` 冻结在 35 后才开跑；control 轮用同镜像默认（开启）。

| 轮次 | 楔死时刻 | 轮/时长/流量 | tx 冻结值 | 指纹 | 看门狗 |
| --- | --- | --- | --- | --- | --- |
| control | 05:13:18 | 第 4 轮 / ~11.5 min / ~12.7 GB | 4,247,288 | mode-2 | ~24 s HEALED |
| recycler=0 | 05:34:41 | 第 4 轮 / ~17.9 min / ~14.6 GB | 11,509,940 | mode-1 | HEALED；后一次 false SUSPECT 由 PROBE-OK 清除 |

结论：SKB recycler 排除。证据：`/tmp/sbe-flash/exp-rc-control-050145.log`
（+.boxlog/.rounds）、`exp-rc-off-051646.log`（+.boxlog/.rounds）。

### 9.2 Phase B：fast_xmit 旁路替换（6.18 兼容层等价物）——仍楔死且该路径从未执行

补丁：厂商 `net/core/dev.c` 三个函数入口改为 6.18 `sfe_compat` 等价写法
（`skb->dev = …; dev_queue_xmit(skb); return true;`），vendor 函数体留作死码，
各带 `pr_info_once("SBE-EXP: …")`：`dev_fast_xmit`(~4721)、
`dev_fast_xmit_qdisc`(~4799)、`dev_fast_xmit_vp`(~4875)。

镜像与设备运行验证（两层）：
- Image 05:53 构建（71,434,248 B，`strings` 三个标记），FIT/sysupgrade 重
  打包，`sysupgrade -n` 刷入。bin sha256 `c8c5988b…`。
- p25（0:HLOS FIT，14,336 扇区）前 5,889,932 B（FIT 总长）sha256
  `e0f6c8d6…` 与本地 bin 的 FIT 区间一致；FIT `kernel-1` 载荷（gzip）解压
  13,434,888 B、含全部 3 个标记 → **打补丁内核确实在运行**。
- 注意：sysupgrade bin 里 FIT 内核是压缩的，直接对 bin `strings` 验证无效；
  build_dir Image 与 FIT 载荷因打包 strip 哈希不同，属正常。

soak（06:00:28 起）：06:05:14 楔死，第 1 轮、4.7 min、2.6 GB，tx 冻结
1,481,621；q208 全程 0x0、COMP5 0x18（06:04:57 瞬时 0x30），mode-2。
对照：6.18 栈在同形状下 25 min / 23 GB 零楔死（WAN-TX-WEDGE-AB-2026-11-26）。

**SBE-EXP 标记零触发**：整轮 >148 万 WAN TX 包，`dmesg | grep SBE-EXP` = 0；
另做 45 s 与 90 s 单流探针（后者结束时也楔死：tx 冻结 424,193，14:13:28
看门狗 HEALED），全程 0。

零触发的原因（源码 + 运行期实测）：
- 三个函数的调用点只有 SFE 前端（`sfe_ipv4_tcp/udp/esp`、`sfe_ipv6_*` 的
  `sfe_fast_xmit_check` 分支）、`ppe_vp_rx.c`（VP 交付 `dev_fast_xmit_vp`/
  `dev_fast_xmit_qdisc`）和 nss-dp `edma_v2/edma_rx.c:965`（EDMA RX 快速转发）。
- 下载流量的 ECM 运行期采样：`ecm_ppe_ipv4/accelerated_count=1`、
  `tcp_accelerated_count=1`，`ecm_sfe_ipv4/accelerated_count=0`；ECM init
  两次 `selected_front_end=5`。即流量由 **PPE 硬件前端**加速，数据面不经
  Linux fast-xmit 路径——这些函数对该流量结构性不可达。

结论：fast_xmit 旁路不是 6.18 与 24.10 差异的来源；Phase B 的设计无法表达
该假设，「打补丁后仍楔死」只证明靶点不在热路径，不构成对任何机制的证伪。
证据：`/tmp/sbe-flash/exp-rc-control-060028.log`（+.boxlog）、
`/tmp/sbe-flash/accel-check.sh` 的四点采样（ppe_acc=1 / sfe_acc=0）。

### 9.3 同批新增观察

1. 开机即楔死：刷机后 ~40 s、仅 708 包（无 ECM 流量）TX 冻结（mode-2），
   看门狗 127 s 自愈（设备时间 13:59:28）。此前楔死只在高负载出现；这是
   新现象，且与补丁无关（标记为零）——说明触发阈值比历史记录低得多，
   甚至不需要 ECM 大流量。
2. 同一启动内第二次楔死（14:05:14，soak）：楔死期间 rx 仍以 ~7 包/s 缓慢
   推进（boxlog 1902356→1902470），看门狗判据满足。设备在 ~14:06:40 失联、
   ~14:07:33 重新开机——与「heal 失败 → reboot」路径吻合；重启抹掉了当时
   日志，无法进一步归因。
3. 下一启动（14:07:33）首次楔死（90 s 探针末尾）由看门狗原地复位成功
   （14:13:28 HEALED，tx 424193→424205）。即手术刀式自愈仍有效，但同一
   启动内反复楔死时可能走到 reboot 升级路径。

### 9.4 下一步（均未执行，需用户批准）

1. **25.12-6.12 同工况 soak**：同为我方树/非 QSDK。若仍楔死 → 差异收窄到
   内核 6.6 vs 6.12（修复发生在 6.12→6.18 之间，可 bisect）；若干净 →
   差异在 25.12 集成层（模块集合、装载顺序、tier 默认）。
2. **模块装载集 A/B**：历史 24.10 镜像运行时载 11 个 qca_nss 模块（9 个
   公共 + 插件对）；25.12/6.18 tier=full 11 个（9 个公共 + phy/debug）。
   phy/debug/flowmgr 的 kmod 包在历史 24.10 镜像里的 modules.d 条目是
   0 字节、**从不自载**（2026-11-26 复核更正；此前的「17 个」是把 lsmod
   的 used-by 列一并计数、又混入 nat46/ppp_generic 等非 NSS 行的误计）。
   标准构建（v132 起）条目非空：phy/debug 上载、flowmgr 仍不上载，
   运行时 13 个（见 §11.1 补记）；判别期 B–F 各臂仍在旧 11 个状态。
   运行时差异只有插件对，见 §11。
3. 内核侧 dmac cache/DMA API、nsscc/uniphy 时钟的最后差异（§8.4.2 第二项）。
4. 产品兜底维持看门狗 v2；补记其升级行为：原地复位失败会 reboot（真机
   已观察到一次，配合 §9.3.2 的失联窗口判读）。

## 10. 25.12-6.12 同工况 soak（2026-11-26，第三台，v105-1-fe0a8896）——不复现楔死

### 10.1 条件

- 镜像：CI release `25.12-6.12 v105-1-fe0a8896`（OpenWrt SNAPSHOT，内核
  6.12.112），`sysupgrade -n` 刷入；发行资产 sha256
  `4f94ced1…2427`，上传后设备端 md5 `e1fe83a00834a9d826d8c1114842dbca`
  与本地一致。刷机后 ~90 s 回网，eth1 2500 Mbps、DHCP 192.168.10.237、
  默认路由通网关。
- ECM 条件对等（本节判读的前提）：`/etc/nss.conf` 默认 `tier=full`，
  启动装载 qca-ssdk/dp/ppe 全家 + ecm + sfe；dmesg
  `ECM init: selected_front_end=5`（与 24.10 相同）；soak 期间机上采样
  `ecm_ppe_ipv4/accelerated_count=1`、`ecm_sfe_ipv4=0`——流量确实由 PPE
  硬件前端加速，与 24.10 楔死时的加速路径完全同构。
- 形状相同：单流 TUNA `ubuntu-24.04.5-live-server-amd64.iso`，绑 USB 网卡，
  每轮 420 s 到点续拉。判据（主机侧）：下载冻结 + 连续 3 次 ~2 s 100%
  丢包。机上 1 Hz 记录 tx/rx/错误计数、q208/COMP5、port5 与 q0208 计数、
  ECM 加速计数。本镜像没有 sbe-wan-tx-watchdog，楔死只能手工 AN 双翻转，
  脚本内置该自愈路径（本轮未触发）。

### 10.2 结果

- 运行窗口 06:24:13–06:53:53（≈29.5 min；用户判定 ping 全通后再追加 10
  分钟后收尾）。
- 4 轮满 420 s 完成 + 第 5 轮进行中：完成下载合计 5.77 GB，进行中 ≈0.1 GB；
  port5 TX **3,543,618 包**。
- 丢包：624 次采样，623 次 0%，1 次 50%（单次瞬态，不构成楔死判据）。
- 全程 `carrier_changes=2` 恒定（无翻链）；q208=0x0 全程无积压；COMP5
  96.7% 采到 0x18、3.3% 采到 0x30 瞬态（散点、非连续，**从未到 0x0**，
  不是 mode-1 指纹）。
- `WEDGE` 事件 0 次；ECM ppe=1 覆盖整个下载期（首、尾 ppe=0 分别出现在
  下载启动前与停拉之后）。
- 口径备注：offload 流量下 eth1 netdev TX 计数恒 0（与 6.18 相同），
  25.12 两栈共有的特征；压测/看门狗须用 port5 计数
  （`/sys/ssdk/packet_counter`）。

### 10.3 判读

25.12-6.12 在同形状、ECM 可比条件下 29.5 min / 354 万包零楔死；24.10 基线
同形状 1–3.5 min 必楔（7/7，0.88–2.5M 包）。两者 qca-ssdk/qca-nss-ppe
源码逐字节相同，NSS 模块为同一源码对不同内核的编译产物。因此 §9.4.1 的两
个分支里，落点是「干净 → 差异在 25.12 集成层」，可进一步收窄为：

1. **装载集成**（当前最高优先级）：历史 24.10 镜像由 kmodloader 自载
   11 个 qca_nss 模块（9 个公共 + 插件对
   qca_nss_wifi_plugins/qca_wifi_nss_plugins）；
   25.12-6.12 与 6.18 由 nss-load tier=full 装载 11 个（9 个公共 +
   phy/debug）。运行时差异只有插件对（旧「17/14 个」计数已按
   `/proc/modules` 复核更正，见 §9.4.2 与 §11.1）。模块装载集 A/B 的
   判别器由 §11 的 ARM C 完成：去掉插件对后同工况零楔。
2. **内核 6.6 vendor vs 6.12**（次优先级）：模块源码相同但编译目标内核不同；
   若模块集对齐后 24.10 仍楔死，则差异只剩内核侧（dmac cache/DMA API、
   nsscc/uniphy 时钟，§8.4.2 第二项），bisect 轴从 6.12→6.18 改为 6.6→6.12。

与 6.18 的对照（25 min/23 GB 零楔）合并后，三个栈的结论矩阵：

| 栈 | 内核 | 模块装载 | 同工况结果 |
|---|---|---|---|
| 24.10-6.6 | 6.6 vendor | kmodloader 11（9+插件对） | 1–3.5 min 必楔（7/7） |
| 25.12-6.12 | 6.12 | nss-load 11 | 29.5 min / 3.5M 包零楔 |
| 25.12-6.18 | 6.18 | nss-load 11 | 25 min / 23 GB 零楔 |

### 10.4 证据

- `/tmp/sbe-flash/soak-2512-062413.log`（+`.boxlog` 1718 行、`.rounds`），
  脚本 `/tmp/sbe-flash/soak-2512.sh`、`box-mon-2512.sh`；副本已存
  `downloads/wedge-evidence-2026-11-26-2512/`。
- 收尾插曲：pkill 模式串与自己命令行子串匹配，收尾脚本自杀一次（退出码
  144）；数据未受影响，清理与统计改为手工执行后补记。

## 11. 模块装载集运行时判别：ARM B/C/D（2026-11-26，第三台）

§10.3 把「24.10 装载集成」列为最高优先判别器。为免重编整树再逐项 bisect，
改用两步：先出一版剔模块镜像（ARM B），再在本镜像上**纯运行时**增删模块
复刻 25.12 的装载集（ARM C/D）——全程只在 ARM B 刷机一次（刷机已单独获批）。

### 11.1 ARM B：标准 24.10 镜像——37 s 楔死；「三模块裁剪」实为空操作

- 计划是剔 flowmgr/phy/debug 三模块再 soak。事后复核（2026-11-26 09:5x）
  发现该裁剪对运行时是**空操作**：B 臂镜像（及此前刷过的各 24.10 镜像）
  里三者的装载条目 `/etc/modules.d/{08-qca-nss-phy,30-qca-nss-debug,
  50-qca-nss-flowmgr}` 是 0 字节文件，`/lib/modules` 里的 `.ko` 都在但
  `kmodloader` 不加载。即判别期 24.10 运行时模块集一直是「9 个公共 NSS
  模块 + 插件对」= 11 个，与 25.12 的 11 个（9 个公共 + phy/debug）只差
  **插件对**；flowmgr 只存在于 24.10 的镜像文件层面。
- **补记（v132 标准构建）**：同一条目在标准构建里非空
  （`08-qca-nss-phy`=`qca-nss-phy\nsfp`、`30-qca-nss-debug`、
  `50-qca-nss-flowmgr` 均 14–16 B）。v132 真机上 phy/debug 实载、
  flowmgr 仍不上载（无 dmesg 报错），运行时因而是 13 个：与 25.12 的
  11 个相比多**插件对**、无 flowmgr（phy/debug 两边都有）。B–F 各臂的
  判读不受影响——phy/debug 同在 25.12 装载集里，且 §11.2/§11.3 已证明
  模块存在本身不触发楔死；旧镜像为何是 0 字节条目未追（对运行时等价）。
- 镜像：`/tmp/sbe-flash/24.10-armb-sysupgrade.bin`（82,576,182 B，
  sha256 `a9ebca49…`），`sysupgrade -n` 07:14 刷入。
- 结果：同形状压测 07:18:28 起，**37 s**／164 MB 后楔死，mode-2 指纹
  （q208=0x0、COMP5=0x18 健康、netdev TX 冻在 94,520、100% 丢包）；
  当时三频 AP 已起且有一个客户端关联（dmesg STA 04:cf:… 插入）。
  日志 `exp-rc-control-071828.log`（复用 §9 的对照脚本，故沿用文件名）。
- 判读：本臂实质=基线复现（与 7/7 必楔一致）；flowmgr/phy/debug 在
  24.10 上从未参与，不是触发因素。运行时差异彻底收敛为**插件对**
  （`qca_nss_wifi_plugins` + `qca_wifi_nss_plugins`）及其依赖的 ath12k。

### 11.2 ARM C：复刻 25.12 集合（无插件对、Wi-Fi 全停）——50 min 零楔

- 操作（纯运行时）：停 hostapd/`wpad` 后按依赖逆序
  `rmmod qca_wifi_nss_plugins → ath12k_wifi7 → ath12k →
  qca_nss_wifi_plugins`，得到与 25.12 等价的「无插件对」状态；
  phy/debug 在 B 镜像里本就缺席（尝试补载找不到 .ko，但其缺席已被
  11.1 证明无害）。
- 结果：07:26:32–08:16 共 50 min，7 整轮完成 + 第 8 轮进行中；完成下载
  **10.14 GB**，port5 TX **约 419 万包**（收尾采样 4,193,494）；1068 次
  丢包采样仅 4 次 50% 瞬态；`carrier_changes` 恒 6；q208 全程 0x0；
  COMP5 机上采样主体 0x18（189/214），偶见 0x48/0x30 瞬态与 1 次单点
  0x0（均不连续，非 mode-1 指纹）；ECM `ecm_ppe=1` 覆盖下载期
  （2877/2890 采样）；WEDGE 0 次。
- 收尾插曲：收官脚本 pkill 模式自匹配自杀（rc=144），第 8 轮 curl
  存活又跑满 420 s（+1.05 GB）后自然结束；主窗口数据不受影响。
- 证据：`soak-2512-072632.log`（+`.boxlog` 330.9K、`.rounds`），副本存
  `downloads/wedge-evidence-2026-11-26-25set/`。
- 判读：内核 6.6、同源 NSS 模块、ECM 同构，仅去掉插件对（Wi-Fi 不起），
  楔死**完全消失** → 触发条件驻留在插件对/ath12k 这条链上，不是「装载
  集成」泛泛的模块数量差异。

### 11.3 ARM D：插件对 + ath12k 载入、Wi-Fi 数据面空闲——40 min 零楔

- 操作（纯运行时）：`modprobe ath12k` + `modprobe qca_wifi_nss_plugins`
  恢复插件对（依赖链自动带起 `qca_nss_wifi_plugins`）；**不启 hostapd**、
  不建 AP 接口 → Wi-Fi 数据面不工作。
- 结果：08:17–08:57 共 40 min，5 整轮完成；完成下载 2.84 GB；856 次
  丢包采样**全部 0%**；cc=6 恒定；WEDGE 0 次。口径备注：前 ~5.5 min 与
  C 臂第 8 轮残留 curl 重叠（双流），其后 34.5 min 为单流，不影响判读。
- 证据：`soak-2512-081724.log`（+`.boxlog` 267.2K、`.rounds`），副本存
  `downloads/wedge-evidence-2026-11-26-25set/`。
- 判读：插件对模块**存在**不触发楔死——需要 Wi-Fi 数据面真实工作
  （AP up + 客户端关联/流量）才触发（对照 11.1：AP+客户端齐备时 37 s
  即楔）。剩余差异收敛到「插件对 + 活跃 Wi-Fi 数据面」的交互点，最大
  嫌疑是 ath12k 以 `fse=Y` 向插件注册 FSE/PPE 回调，Wi-Fi 流量经此编程
  PPE 流表时污染有线端口 TX 通路——由 ARM F 单变量验证（§11.4）。

### 11.4 ARM F：ath12k `fse=0` + Wi-Fi 正常 up（相对 ARM B 单变量）——30 min 零楔

- 操作：不改镜像、不刷机。发现两个工具性障碍并绕开：`/sbin/modprobe` 是
  kmodloader 的符号链接、**静默忽略命令行模块参数**；`/etc/modules.d/ath12k`
  被 QSDK 厂商启动脚本（START 01/02/04/05）**每次开机重写**。持久注入点改用
  kmodloader 支持的 `/etc/modules.conf`（`options ath12k fse=0`，源码依据
  ubox `load_options()`），重启后回读 `fse=N` 生效。前置条件与 ARM B 对齐：
  ath12k/ath12k_wifi7/插件对全部加载、三频 AP 起来、phy00.0-0 有一个客户端
  关联（FSE 流表具备编程条件）、eth1 2500/DHCP 正常、无二次看门狗重启。
- 源码语义：`ath12k_fse_init()` 在 `ath12k_fse_enable` 为假时直接返回，
  不调用 `ath_fse_ops_callback_register()`——ath12k 与插件之间的 FSE/PPE
  回调注册及后续按流钩子整体关闭；其余 Wi-Fi 数据面路径不变。
- 结果（用户按 0% 丢包口径定 30 min）：09:10:22–09:40:22，**WEDGE 0 次**；
  4 整轮完成 3.05 GB，port5 TX 1,792,057 包；`carrier_changes` 恒 2
  （全程无翻链、无自愈动作）；622 次丢包采样仅 5 次单点 50% 瞬态、
  无任何 100% 段；机上 1 Hz 日志 q208 分布（0x0 1711/1733，余为≤0x6
  的单点瞬时占用）与 c5 分布（0x18/0x30/0x48/0x60 轮转 + 33 次 0x0
  瞬点）与 C/D 两个干净臂同构；ECM `ecm_ppe=1` 覆盖所有下载期
  （1721/1733）。
- 证据：`soak-2512-091022.log`（+`.boxlog`、`.rounds`、`fse0-setup.txt`），
  副本存 `downloads/wedge-evidence-2026-11-26-fse0/`。

### 11.5 判读（ARM B/C/D/F 合并）

| 臂 | 插件对 | Wi-Fi 数据面 | ath12k fse | 结果 |
|---|---|---|---|---|
| 基线 24.10 | 是 | AP up（有客户端） | Y | 1–3.5 min 必楔（7/7） |
| B（标准 24.10 镜像） | 是 | AP up + 1 客户端 | Y | **37 s 楔**（mode-2） |
| C | 否（rmmod） | down | — | 50 min / 10.14 GB 零楔 |
| D | 是 | 模块在、无 AP/无流量 | Y | 40 min / 2.84 GB 零楔 |
| F | 是 | AP up + 1 客户端 | **N** | **30 min / 3.05 GB 零楔** |

链式判读：flowmgr 排除（B）→ 模块存在本身不楔（D）→ 需要「插件对 + 活跃
Wi-Fi 数据面」（C/D vs B）→ 在后者全部就位的条件下，仅 `fse=0` 即消除
楔死（F vs B，单变量）。**触发点收敛为 ath12k 经插件向 PPE 注册的
FSE/PPE 回调：Wi-Fi 侧编程 PPE 流表时污染有线端口（port5）TX 取包通路。**
这与 mode-2 指纹（PPE 端口吞包、q208 空、COMP5 健康）以及 ECM 为唯一
触发器的既有结论自洽——有线路由流量本身只用 PPE 既有流表，只有 Wi-Fi
侧的 FSE 编程会碰同一 PPE 的流表/TX 取包状态机。

**修复候选**：`options ath12k fse=0`（`/etc/modules.conf`）——30 min 同
形状零楔、有线 ECM 加速保持（ppe=1 全程）、Wi-Fi 三频/客户端关联全正常；
代价是 Wi-Fi 客户端流量不走 PPE FSE 加速（回普通转发路径），吞吐影响
未测。这是配置级规避，不是代码根因修复（PPE/EDMA 交互缺陷仍在 QCA 栈内）。

### 11.6 下一步

1. ~~**产品化 F 修复**~~（2026-11-26 已完成并真机验证，见 §11.7）：
   `options ath12k fse=0` 已作为 `24.10-6.6/files/etc/modules.conf`
   打进 v132 镜像；~~Wi-Fi 吞吐粗测~~已完成（见 §11.8，代价≈0）。
2. **根因修复路线**（保留 FSE 的前提下）：沿 FSE 流表编程路径找 QCA 缺陷
   （插件 `ppe_fse_cb_register` → PPE FSE ops → 端口 TX 队列交互），
   对照 25.12/6.18 干净栈中同一路径的行为差异。源码级调查报告已完成
   （2026-11-26，只读静态审计，见 §11.9）：5 个排序假设、file:line 锚点、
   单变量验证方案；待批准的设备侧取证/开关实验列出在 §11.9 末。
3. 看门狗 v2 保留为兜底（与 fse=0 不冲突，双保险）。

### 11.7 v132 真机验证：fse=0 从镜像生效——30 min 同形状零楔（2026-11-26）

- 镜像：v132 标准构建，82,576,182 B，sha256 `31b8863c…a52341b`。
  `options ath12k fse=0` 烘焙在 `files/etc/modules.conf`（构建 overlay
  注入，见 ubox `load_options()` 语义，§11.4）；`scp -O` 上传哈希一致，
  `sysupgrade -n` 刷入（用户批准），重启后回读 `fse=N`——**来自镜像
  而非手改**，即出厂状态即生效。
- 首启核对：三频 AP + 1 客户端关联（phy00.0-0）、eth1 2500/DHCP `.237`、
  网关 ping 通、sbe-wan-tx-watchdog 运行中；模块集 13 个 qca_nss
  模块（9 公共 + phy + debug + 插件对；flowmgr 有条目不上载，见 §11.1
  补记），与 §11.4 F 臂的条件对齐。
- 结果（09:59:14–10:29:16，30 min）：**WEDGE 0 次、HEAL 0 次**；4 轮满
  420 s + 第 5 轮进行中；完成下载 1.80 GB（694+804+262+41 MB），port5
  TX 累计 929,720 包；634 次丢包采样 11 次单点非零、**无任何 100% 段**；
  `carrier_changes` 恒 2（1737/1738 采样）；q208=0x0 1736/1738（2 次
  单点 0x1）；COMP5 0x18 1687 / 0x30 51，与 C/D/F 干净臂同构；
  ECM `ecm_ppe=1` 覆盖下载全程（1721/1738，余为起拉前/停拉后）。
- 口径备注：第 3/4 轮速率骤降（623 / 97 KB/s），同窗口完成量累计
  ~1.5 GB——与本机上游 443 代理限额（~1.7 GB）的既有现象吻合；TX 计数
  持续增长、ping 0%、q208 空，**不是楔死**（未单独归因，不影响判读）。
- 证据：`soak-2512-095914.log`（+`.boxlog` 1738 行、`.rounds`），副本存
  `downloads/wedge-evidence-2026-11-26-v132/`。
- 判读：修复候选完成**端到端产品化验证**——镜像级 `fse=0` 与手改配置
  行为等价，30 min 同形状零楔，有线 ECM 加速保持。Wi-Fi 客户端流量
  不走 PPE FSE 的吞吐代价由 §11.8 补测，结论≈0。

### 11.8 Wi-Fi 吞吐代价 A/B：fse=0 无可测代价（2026-11-26，第三台）

背景：§11.7 之后唯一未测项——fse=0 让 Wi-Fi 客户端流量不走 PPE FSE，
其吞吐代价未知。上游（443/80 代理限额）当日上午处于限速态，因此改用
**本地路由台架**测量，不依赖上游。

- 台架（全部主机侧，可复现）：主机 wlp0s20f3 关联路由器 WiFi_2.4G
  （2462，HE-MCS11-NSS2 286.7 Mbps，-28 dBm）；虚拟地址
  `192.168.10.88/32` 挂 lo + main 表 via 路由指向 wlp，客户端用
  `curl --interface wlp0s20f3`（SO_BINDTODEVICE 使路由带设备约束，绕开
  local 表短接）；路由器 `ip neigh … nud permanent` 静态 ARP 指向主机
  eno0；主机 `accept_local=1`（否则 SYN-ACK 的 src 属本机地址被丢）。
  服务器 `python3 -m http.server --bind 192.168.10.88`，载荷 100 MB
  随机文件。流量形状：Wi-Fi 客户端 → 路由器 NAT → eth1(port5) → 主机
  eno0，PPE 加速流（ecm_ppe=1）。
- **A 臂 fse=0**（v132 热重载后状态）：3×30 s，18 次下载全通，均值
  23.8 MB/s（187–194 Mbps），零停顿；ecm_ppe=1 占 79–93%；q208 恒
  0x0；cc 恒 2。
- **B 臂 fse=1**（rmmod 后 `insmod ath12k.ko` 默认 fse=Y + 插件，
  `fse=Y` 回读）：先 3×30 s 18 次全通（均值 23.9 MB/s），再 5 min 加长
  68 次（≈6.8 GB）全通，均值 24.1 MB/s、min 22.7 MB/s；**零楔死**、
  q208 300/300 为 0x0、cc 恒 2、ecm_ppe=1 285/300；p5tx +216,504 包。
- FSE 实证（关键取证口径）：`fst_dump_table`/`fst_dp_stats`
  （`/sys/kernel/debug/ath12k/pci-0001:01:00.0/fst_config/`）**只在活动
  流中非空**——流结束规则即删，空闲读必为 0 条目（曾据此误判"假臂"）。
  B 臂活动流样例：`use_ppe=1 service_code=0xc reo_indication=1`，五元组
  = Wi-Fi 客户端 :47302 → .88:8098；fse=0 活动流：inserted=0、
  addition failure=0（不尝试编程）。
- 判读：在该 2.4G 286 Mbps 链路上，FSE 收益不可测（瓶颈在 PHY），
  **fse=0 的 Wi-Fi 吞吐代价≈0**；且楔死在 Wi-Fi 流量类别下 5 min
  6.8 GB 也未复现——楔死仍只见于有线 soak 形状，触发需要有线类流。
- 口径与遗留：
  - B 臂为**热重载态**（出现 `failed to destroy soc agent`、QRTR -95、
    `HTC WMI MAC1 connect failed` 告警；PPEDS 仍 attach、行为可比但非
    冷启动等价位）。真 fse=Y 冷启动臂未能做：改 modules.conf 后重启的
    操作被权限拦下，未获用户批准。
  - 热重载后 hostapd AP 实例不自动重建：`ubus call network.wireless
    up`/`wifi reload` 均空操作，必须 `wifi down; sleep 4; wifi up`。
  - 测后已恢复：`rmmod` 三模块 → `modprobe ath12k`（modules.conf 的
    `fse=0` 生效）→ `fse=N`；三频 AP 重建、主机重连、100 MB 下载
    sanity 通过（18.3 MB/s）。设备处热重载态，建议冷重启归位。
  - 台架已清理（主机服务器/虚拟地址/路由/accept_local、设备静态
    ARP/big.bin/socat）。证据：`downloads/wifi-ab-2026-11-26/`。

### 11.9 根因代码调查报告（2026-11-26，只读静态审计，未动设备）

对 24.10 源码树（qca-wifi/ath12k backports、qca-nss-ppe、qca-nss-ecm、
插件、qca-nss-dp、qca-ssdk）做整链审计，结论：

- **否定证据**：EDMA ppeds ops 只写 DS ring prod/cons idx、SERVICE_STOP
  位，不碰 port5 QM/PSCH/GMAC/TX ring——"FSE 直接改 port5 寄存器"不成立。
  FSE 影响 port5 的唯一通道是「决定哪些报文以什么元数据进入 PPE 快速
  路径，然后被 PPE 送往 port5 出口」。fse=0 与 fse=1 的差异即 FST 条目
  存在性。
- 命中路径：FST 命中且 use_ppe=1 → REO2PPE → PPE → SPF_BYPASS(12) →
  port5 q208；DS 分支只装一个方向（下载场景=客户端→WAN 上行元组），
  metadata 携带 egress macid=5 + Wi-Fi DS VP。
- 排序假设（均改变进入 port5 的报文元数据，与两型指纹机制自洽）：
  1. **H1（最可疑）metadata 位段冲突 + `|=` 累加**：PPE 路径
     `metadata=VP|macid<<8`（ppe.c:1140-1145），SFE 路径魔数 0xAA00
     的 bits11:8=0xA 正落在 EGRESS_MACID；HAL 写表用
     `metadata |= flow->fse_metadata`（wifi7/hal_rx.c:1595），info2 却
     整体赋值——同元组被两路径先后编程时 macid 被污染成 0xA；重复
     检测把 SERVICE_CODE 读进 use_ppe 变量比较（wifi7/dp_rx.c:2593-
     2610），PPE 条目永远判"需更新"。触发时机=PPE↔SFE 回退/重试、
     删除被 CRASH_FLUSH/RECOVERY 跳过（ppe.c:1316-1319）。
  2. **H2 reo_indication 与 radio 解耦**：`fst_core_mask=0x7` 硬编码
     （dp_rx.c:1832），core_map 轮转 1/2/3 与本流 radio/DS 节点无关。
  3. **H3 全组共享 FST + delete 侧 ab/标志不对称**：delete 用
     `radio[0].ab`、`is_ds=false`；recovery 窗口 invalidate 被跳过，
     可留脏条目。
  4. **H4 双编码+字节序异构**：SFE 不做 ntohl、PPE 做 ntohl，同元组
     可能两 hash 槽/双条目。
  5. H5（低）FSE 编程在 ppe_drv 大自旋锁内完成并同步发 HTT。
- 待批准的单变量验证（设备侧，均未执行）：楔死态抓 `fst_dump_table`
  查 metadata 高字节 0xAA 图案；`/proc/sys/net/ecm/sfe_fse_enable=0`
  与 `ppe_fse_enable=0` 分别压测；local 补丁 metadata 改 `=` 做 A/B；
  H2 用 `fst_core_mask` 单行补丁。
- 不确定性：reo_indication 的硬件语义无文档；EGRESS_MACID=0xA 时 PPE
  的具体行为无法静态判定（H1 链最后一环空白）；SPF_BYPASS 回 CPU 的
  时序无寄存器手册核对。
