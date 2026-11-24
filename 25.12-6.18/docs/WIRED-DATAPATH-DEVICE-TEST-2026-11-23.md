# 6.18 NSS 有线数据面：真机测试记录（2026-11-23，E1/E2 镜像）

项目文档：`WIRED-DATAPATH-PROJECT-2026-11-23.md`。本文件记录 E1
（补丁 0038 MDIO phy-reset 脉冲 + 0039 switch bmp）镜像的真机取证，
以及 §5 的 E2（补丁 0018）取证与 D2/D3 统一根因定案。

- 镜像：NSS 变体 sysupgrade，sha256 `38dd29fc6d7581461140640e459e89bc
  ca39deea7aeca0449cb0edf134238f2a`，`/etc/openwrt_version` =
  `sbe1v1k-6.18-bae017a5`（E1 为工作区未提交改动，版本串只反映 git HEAD）。
- 刷入方式：`sysupgrade -n`；设备 board_name `askey,sbe1v1k`。
- 管理面：WiFi（br-lan 192.168.1.1），取证全部只读；唯一主动动作是
  `ping -c 2 -I eth1 192.168.10.1`（增加出口流量，用于判读计数）。
- 接线（用户已接）：上游网关 → 2.5G WAN 口（eth1）；主机 USB 网卡 →
  10G 口（eth0）；eth2/eth3 空。

## 1. 验收判据逐条

| 缺陷 | 判据 | 结果 |
|---|---|---|
| D1 | 无 `MDIO device ... missing`、无 `-19`；0x12/0x13 绑定 | **PASS（驱动层）** |
| D1 | 插线后 eth2/eth3 收包 | NOT TESTED（两口未接线） |
| D2 | dropcode 119 停止增长 | **PASS**（`VP_TX_DROP_CNT_TBL` 现为空） |
| D2 | eth1 拿到 DHCP 租约、上游看到 WAN MAC 帧 | **FAIL** |
| D3 | eth0 AN 寄存器非 0、链路 up、eth0 rx 增长 | **FAIL** |

### 1.1 D1：PHY 绑定全部恢复

- dmesg 无一条 `MDIO device at address ... is missing`（0 条）。
- `/sys/bus/mdio_bus/devices/`：`90000.mdio-1:00`（RTL8261BE）、
  `:12`/`:13`（QCA8075）、`:1c`（QCA8081）四个全在。
- `nss-dp ... eth2/eth3: PHY [90000.mdio-1:12/13] driver [Qualcomm QCA8075]`
  —— 6.12 的 MDIO phy-reset 脉冲（0038 内层 0150）按设计生效。
- dmesg 无 `ssdk_port_phylink_setup ... ret -19`。
- LAN 口数据面未测（两口无接线，链路 DISABLE 属预期）。

### 1.2 D2：dropcode 119 消失，但帧仍不出系统侧（FAIL）

`ssdk_sh port linkstatus get 5`：**ENABLE / 2500 / Full / SGMII PLUS**；
netdev `carrier=1`。udhcpc 在 eth1 上运行（pid 28569），`wan` 一直
`pending`；`odhcp6c` 亦在跑。

| 计数器 | 读数 | 说明 |
|---|---|---|
| `PORT_TX_COUNTER` port5 | 672（queue 0208 同步） | 发帧确实到达 PPE 出口队列 |
| `VP_TX_DROP_CNT_TBL` | **空** | 与 S3E §6.5 的 dropcode 119 相比已消失 |
| `debug phycounter show 5` `RxGoodFrame` | 6 | 铜缆侧收到上游广播 |
| 同上 `SysRxGoodFrame`/`SysTxGoodFrame` | 0 / 0 | **无效读数，不作证据**（见下） |
| eth1 netdev rx/tx | 0 / 0 | nss-dp 计数不实现，仅参考 |

更正（2026-11-23 复核）：`SysRxGoodFrame`/`SysTxGoodFrame` 恒为 0 是接口
性质——`nss_phy_common_stats_get()` 从不填这两个字段，6.12 正常工作时
同样读 0。因此「系统侧双向零帧」不能作为判据；D2 的证据只有 udhcpc
一直拿不到租约、以及 PPE 出口计数增长而流量不出现。

判定：E1 消除了「PPE 出口按 TX MAC disable 丢弃」（dropcode 119 消失），
但 eth1 仍然没有上行。帧具体停在哪一侧（MAC↔PHY 的 SGMII+ 串行链路，
还是 PPE VP 内部），需要一次「使能 → 生成流量 → 读 phycounter
TxGoodFrame/RxGoodFrame 增量」的成对取证来定案。

### 1.3 D3：eth0 AN 死锁无变化（FAIL）

dmesg（本启）：

```
58.573284  uniphy autoneg time out!
59.351786  nss-dp 3a514000.dp1 eth0: Link is Up - 2.5Gbps/Full - flow control rx/tx
61.661520  RTL8261BE 10Gbps PHY 90000.mdio-1:00: SerDes link did not come up
```

uniphy2 寄存器与 S3E §6.2 记录的坏启动签名逐位相同（0x1f0000=0x1120、
0x1f8000=0x2000、0x1f8001=0x101、0x1f8002=0x0）。eth0 rx=0。

## 2. 本轮新增证据（用于定位 D2）

### 2.1 uniphy1 配置寄存器（`ssdk_sh debug uniphy get 1 <reg> 4`）

| 寄存器 | 值 | 判读 |
|---|---|---|
| 0x218 MISC2 | **0x50** | SGMII PLUS 模式（UNIPHY_MISC2_REG_SGMII_PLUS_MODE） |
| 0x46c MODE_CTRL | **0x820** | SGPLUS=1(b11)、ch0_mode_ctrl_25m=2=SGMII_MAC(b4-6)、autoneg=Atheros(b0=0) |
| 0x1e0 CALIB4 | 0xac1 | 与 uniphy0/2 相同，校准正常 |
| 0x1f0000/1f8000/1f8001/1f8002 | 0/0/0/0 | channel0 XPCS 块全零 |

最后一行**不是故障证据**：ssdk 的 SGMII/SGMII+ 路径故意「keep xpcs to
reset status」（`__adpt_hppe_uniphy_sgmiiplus_mode_set`），XPCS 寄存器
读零与该行为一致。

### 2.2 时钟树（假设已排除，2026-11-23 复核）

| 时钟 | parent | 速率 |
|---|---|---|
| uniphy1_gcc_tx/rx_clk | — | 312,500,000（已 enable） |
| `nss_cc_port5_tx_clk_src` | **`7a10000.ethernet-uniphy::tx_clk`（125 MHz，PCS 驱动提供）** | 125,000,000 |
| `nss_cc_port5_rx_clk_src` | 同上 | 125,000,000 |

每次 link-up（55.19 s）都有：

```
ssdk_uniphy_port5_clock_source_set[2110]:ERROR:set parent fail! (×2)
ssdk_uniphy_raw_clock_set[2080]:ERROR:set parent fail!
```

即 ssdk 想把 port5 TX/RX 时钟源切到 uniphy1 raw clock（2.5G 应为
312.5 MHz）失败，实际停在 PCS 提供的 125 MHz。

复核结论（2026-11-23，无需刷机）：6.12 正常工作的基线
`logs/relink-2026-11-21/baseline.txt` 在同一 2.5G 链路上
`nss_cc_port5_tx_clk_src` 同样是 125 MHz，并且同样打印两条
`ssdk_uniphy_port5_clock_source_set[2110]:ERROR:set parent fail!`。
125 MHz 与 `set parent fail!` 是 SGMII+ 子模式的正常形态，**时钟假设
排除**，原先计划的 6.12 v94 A/B 刷机对照不再需要。

### 2.3 复位噪声（已更正：这不是噪声，是 D2/D3 的根因）

本启 unresolved reset id：0/1/3/5/14/15/16（= uniphy0 的 soft、
uniphy0/1/2 的 xpcs 与 sys；`ssdk_ppe_reset_get` 返回 -EBUSY）。

初稿曾写「两棵树 DTS 均未提供这些 reset-names」——**对 6.18 是错的**：
6.18 BSP 的 `patches-6.18/0356` 在 uniphy0/1/2 节点上补了
`xpcs/sys/soft` 三条复位，重写后的 PCS 驱动 probe 时全部 exclusive
持有，ssdk 申请同名线得到 -EBUSY（`__reset_control_get_internal` 的
WARN 在 core.c:799）。6.12 的 uniphy 节点只有 `xpcs` 一条，所以至少
sys×3 与 uniphy0 soft 在 6.12 一直归 ssdk。详见 §5。

### 2.4 源码静态结论（本轮复核）

- `qca-ssdk` 两树差异仅：`ssdk_init.c`（`eee_cfg.eee_enabled`、phylink
  PCS `get_state` 签名与 `neg_mode` 字段删除）、`sfp_phy.c`、
  `ssdk_mht_pinctrl.c`、`ssdk_plat.c`——均为内核 API 适配，无行为差异。
- `qca-nss-dp` 两树差异仅 `hash_32()` 适配与 edma_v2 小改动。
- 内核 `qca808x.c`：6.18 多 `qcom_phy_counter_config()` 与
  `update_stats/get_phy_stats`；`read_status` 的 2500BASE-X 接口切换、
  `config_aneg`、`link_change_notify` 两树逐字相同。
- `mdio-ipq4019.c` 两树仅差 0038 的 phy-reset 脉冲；C45 读写在两树均
  完整实现（QCA8081 的 FIFO 释放走 C45 addr+1，排除总线缺 C45）。

## 3. 下一步（待用户批准设备操作）

原计划中的 6.12 v94 A/B 刷机（对照 port5 时钟）**取消**：§2.2 已用 6.12
基线日志排除时钟假设，唯一还想要 6.12 对照的就剩 D2 的 uniphy1
0x218/0x46c 与 phycounter 行为，可并入下一次 E2 镜像的取证（成对读
phycounter 增量），不必单独刷一版。

接下来应刷 E2 镜像（补丁 0018，D3 完整 uniphy 重新初始化）：
判据见 `WIRED-DATAPATH-PROJECT-2026-11-23.md` §5，D3 专项是
冷上电 + ≥3 次热重启下 eth0 AN 寄存器非 0、eth0 rx 增长，且 dmesg
出现 `uniphy autoneg time out!` 后跟
`uniphyN autoneg recovered after re-init`（或明确的 `still incomplete`）。

本轮尝试执行刷机时被本会话的权限分类器拦截（`sysupgrade` 属设备写操作），
已按规则停止，等待用户批准后继续。

## 4. 下一轮 D2 取证步骤（并入 E2 镜像的测试）

`SysRx/SysTx` 无效后，D2 的判定要靠 phycounter 的成对增量（只读）：

1. 停掉 udhcpc 让计数静止：`kill` 该进程或等它退避；
2. 读基线：`ssdk_sh debug phycounter show 5` 记 `TxGoodFrame`/`RxGoodFrame`；
3. 生成静止的出口流量：`ping -c 20 -i 0.2 -s 300 -I eth1 192.168.10.1`；
4. 立刻再读同一组计数器，记增量。

判读：

- `TxGoodFrame` 增加 → MAC→PHY 的 SGMII+ 出口在动，帧进入 PHY 后未发到
  线上（PHY 侧或上游），D2 移到 PHY/对端；
- `TxGoodFrame` 不增 → 帧停在 MAC/PPE 与 PHY 之间，重点查 phylink 在 6.18
  给 port5 下发的 SGMII 参数（`neg_mode`/`mac_select_pcs` 语义变化是首要
  嫌疑，6.18 的 phylink 比 6.12 新）。
- 同时采集 `ssdk_sh port linkstatus get 5` 与 `ssdk_sh debug phy show 5`
  作对照。

## 5. E2 镜像（补丁 0018）取证：D2/D3 统一根因定案（2026-11-23）

- 镜像：NSS 变体 sysupgrade，sha256 `4456b8cf01cd415b18d321d18b32732e
  f8b44d6868827506b8c44127561ecc52`，`/etc/openwrt_version` =
  `sbe1v1k-6.18-bae017a5`（同 E1，改动未提交）。刷入 `sysupgrade -n`，
  经用户批准；取证全部只读。
- 接线不变：上游网关 → eth1（2.5G WAN）；主机 USB 网卡 → eth0（10G）。

### 5.1 判据

| 缺陷 | 结果 |
|---|---|
| D1 | PASS（驱动层，无回退） |
| D2 | **FAIL**：eth1 carrier=1、2500/Full、SGMII PLUS；udhcpc 无租约 |
| D3 | **FAIL**：`uniphy autoneg time out!` 后 0018 的 re-init 跑完仍
  `uniphy2 autoneg still incomplete after re-init` |

补丁 0018 按设计执行了（re-init 确实被调用、日志串与预期一致），但
re-init 复用的 `__adpt_hppe_uniphy_usxgmii_mode_set()` 本体没能恢复 AN。

### 5.2 定案证据：7 条 reset-core WARN 与 DTB 数值一一对应

E2 启动日志 21 行 `__reset_control_get_internal`（每 3 行一条 WARN，
共 7 条），`ssdk_uniphy_reset` 报 `reset(N) not exist!` 的 id 恰为
0/1/3/5/14/15/16。按 `enum uniphy_rst_type` 与 E2 反编译 DTB 对照：

| ssdk 名（ess-switch 复位表） | 线 | PCS 节点同名条目 |
|---|---|---|
| `uniphy0_soft_rst` | nsscc 0x6d | uniphy0 的 `soft` = nsscc 0x6d → **EBUSY（id 0）** |
| `uniphy0_xpcs_rst` | gcc 0x87 | uniphy0 `xpcs` → **EBUSY（id 1）** |
| `uniphy1_xpcs_rst` | gcc 0x8a | uniphy1 `xpcs` → **EBUSY（id 3）** |
| `uniphy2_xpcs_rst` | gcc 0x8d | uniphy2 `xpcs` → **EBUSY（id 5）** |
| `uniphy0_sys_rst` | gcc 0x85 | uniphy0 `sys` → **EBUSY（id 14）** |
| `uniphy1_sys_rst` | gcc 0x88 | uniphy1 `sys` → **EBUSY（id 15）** |
| `uniphy2_sys_rst` | gcc 0x8b | uniphy2 `sys` → **EBUSY（id 16）** |
| `uniphy1_soft_rst` | nsscc 0x74（PORT5_ARES） | 与 PCS `soft` 0x6e 不同线 → 成功，不报错 |
| `uniphy2_soft_rst` | nsscc 0x75（PORT6_ARES） | 与 PCS `soft` 0x6f 不同线 → 成功，不报错 |

来源：6.18 BSP `patches-6.18/0356` 给 uniphy 节点加了
`xpcs/sys/soft` 三条复位并命名；重写后的 `pcs-qcom-ipq9574.c`
（BSP 0323）probe 时用 `devm_reset_control_get_optional_exclusive()`
取得 `sys`/`soft`、`get_optional(NULL)` 取得 `xpcs`，全部独占。

后果：`__adpt_ppe_gcc_uniphy_software_reset()`（assert sys → 1 ms →
deassert，每个接口模式切换后必做）对 sys 的两次操作都落在 IS_ERR 句柄
上，静默返回 0，serdes 不锁存刚写入的 SGMII+/USXGMII 模式：

- uniphy1 切 SGMII+（port 5）：`0x218=0x50`、`0x46c=0x820` 回读正确、
  PHY 铜缆侧有流量，但 MAC↔PHY 的串行侧零帧 → D2；
- uniphy2 切 USXGMII（port 6）：AN 配置不生效 → D3；0018 的 re-init
  走同一函数，同样失效。

### 5.3 与 6.12 的对照

6.12 的 uniphy 节点只有 `resets = <&gcc GCC_UNIPHYn_XPCS_RESET>`，
PCS 驱动只持有 xpcs×3。ssdk 的 sys×3 与 uniphy0 soft 在 6.12 上
**可用**，xpcs×3 才是 -EBUSY（6.12 启动日志同样有 3 条 WARN、同样
报 `reset(3)`）。所以同一份 ssdk 代码在 6.12 能工作、在 6.18 不能的
结构性差异就是这 4 条复位线的所有权（sys×3 + u0 soft）。

修复 = 在 NSS 变体 DTS 把三条 uniphy 节点的复位裁剪回 6.12 形态
（仅 xpcs），`patches/0040`。xpcs 保持 PCS 持有：6.12 曾把它交给 ssdk
独占导致 10G 口死亡（`25.12-6.12/patches/0037` v2），ssdk 对 -EBUSY
本来就跳过该 assert。

### 5.4 E4 修复镜像（已刷，见 §6）

`patches/0040` 已合入并本机构建 PASS（`verify-image` 130/0）。E4 镜像：
NSS sysupgrade sha256 `05eedd2196e4a0a82909cccb0181db74220b44a9a4c7420
1956b504f5858854b`（`/etc/openwrt_version` 仍为 `sbe1v1k-6.18-
bae017a5`，工作区改动未提交）。2026-11-24 经用户批准 `sysupgrade -n`
刷入，结果见 §6。

## 6. E4 真机结果（2026-11-24）：D2 PASS，D3 回到 6.12 概率基线

### 6.1 复位所有权修复生效（判据全部命中）

- `__reset_control_get_internal` WARN 从 7 条（21 行）降到 **3 条（9 行）**，
  三条的 `x21` 依次为 `0x87/0x8a/0x8d` —— 只剩 PCS 持有 xpcs×3，与 6.12
  完全一致。
- `reset(N) not exist!` 只剩 `(1)×1、(3)×2、(5)×2`（xpcs）；
  **`reset(0)/(14)/(15)/(16)` 全部消失**（u0 soft 与 sys×3 已归还 ssdk）。
- 反证：D2 的成功本身就证明 sys 复位脉冲真正到达硬件（同一
  `__adpt_ppe_gcc_uniphy_software_reset()` 路径服务全部 uniphy）。

### 6.2 D2：PASS（数据面全通）

- `ssdk_sh port linkstatus get 5` → ENABLE；eth1 carrier=1。
- udhcpc 拿到上游租约（首启 `192.168.10.154/24`，后续启动
  `.166`/`.242`，上游按 MAC 分配、地址可变属网关行为）。
- `ping -I eth1 192.168.10.1` 3/3（1.6–2.5 ms）；DNS 经上游解析成功；
  `curl http://www.baidu.com` → HTTP 200（33 ms）。
- `ssdk_sh port counter get 5`：`rx_pkt_cnt` 5278 且持续增长 ——
  系统侧双向有帧，dropcode 119 问题不再复现。

### 6.3 D3：确定性缺陷消除，残留概率性坏启动

三次启动采样（刷后首启 + 两次 hot reboot，判据同 §1.3）：

| 启动 | `0x1f8002` | dmesg | eth0 数据面 |
|---|---|---|---|
| 1（刷后） | `0x0` | `uniphy autoneg time out!` + `still incomplete after re-init` | 假链路，rx 仅零星 |
| 2（reboot） | `0x7000` | 无 AN 日志 | 主机经 10G 口 ping 4/4（0.4 ms），rx 计数增长 |
| 3（reboot） | `0x7000` | 无 AN 日志 | 同上；WAN 同步正常 |

对照组：0040 之前 6.18 为 **6/6 确定性失败**（E1/E2）再 +1（E4 首启）
= 7/7；修复后 3 启 1 坏。样本小，不能定分布，但性质已变：与 6.12 的
「XPCS AN 使能 vs RTL8261N 初始化时序竞争」（`25.12-6.12/docs/
ETH0_XPCS_AN_BOOT_2026-11-22.md`，26 次采样 13 坏）同一形态，属**既有的
独立缺陷**，不是 0040 引入。6.12 的 S95 看门狗（坏启动自动重启一次）
正是为它设计的；6.18 上是否移植待立项决定。

### 6.4 回归面

- D1 保持 PASS：4 个 MDIO 设备全在，`is missing` 0 条、`ret -19` 0 条。
- port3/4（qca8075 两个 LAN 口）DISABLE 属预期（未接线）；port5/6 ENABLE。
- 无线 3 radio（wl0.0/1/2-ap0）正常拉起；无新增 dmesg 噪声。
- 未测：冷上电重复性、D3 坏启动占比统计（需更多重启或看门狗策略）。
