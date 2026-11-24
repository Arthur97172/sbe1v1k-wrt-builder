# 端口角色与 eth0 真机测试报告（2026-11-21）

覆盖两棵树同源功能：`sbe_ports.main.wan_port`（eth0 / eth1 / none）、
`/usr/sbin/sbe-port-roles`、`eth0-lan-attach`。测试设备为第三台 SBE1V1K
（base MAC `90:d3:cf:4b:eb:81`，eth1/2/3 出厂同 MAC `…:82`），当天在两棵
固件线之间来回刷机：先 25.12，再 24.10，最后回 25.12 复测。

镜像（均来自本仓库 CI Release，刷入前 sha256 在主机与设备各校验一次）：

| 固件线 | tag | sha256（前 8 位） | 刷入方式 |
| --- | --- | --- | --- |
| 24.10-6.6 | `24.10-6.6-v113-2-e0ee12cd`（CI #113，commit `e0ee12c`） | `4a012256` | `sysupgrade -n` |
| 25.12-6.12 | `25.12-6.12-v80-1-e0ee12cd`（CI #80，commit `e0ee12c`） | `a14a835f` | `sysupgrade -n` |

## 结论摘要

| 项目 | 24.10-6.6 v113-2 | 25.12-6.12 v80-1 |
| --- | --- | --- |
| 首启（默认 eth1 角色） | PASS | PASS（早前 §v80 已验，当日复刷再确认要点） |
| eth0 角色（改角色+重启） | PASS | PASS（2026-11-21 早前同一方法验证） |
| 运行期 live 切到 eth0 | **FAIL**：eth0 进入假 10G 环回 | **FAIL**：同 |
| live 回切 eth1 后 2.5G 口 | 恢复（链路/转发/DHCP 全通） | **不恢复**：link up 但收不到应答（功能判据，见补充分析） |
| 恢复手段 | 10G 口需重启；2.5G 口无需重启 | 只能重启 |

一句话：两棵树「改角色 + 重启」都可用；**live 切换在两棵树上都不可用**，
被 RTL8261N 假 10G 环回阻塞；25.12 更糟——回切时机上的 2.5G 口也会卡死。

## 测试环境与步骤

- 接线：主机 USB 网卡（RTL8156B，2.5G）接路由器 10G 口（eth0）；路由器
  2.5G 口（eth1）接上游网关。
- 管理：全程 WiFi（SSH + LuCI 200）作为保命通路；刷机后 USB 网卡走 DHCP。
- 模拟上游：测 eth0 作 WAN 时，主机 USB 网卡改为静态 `192.168.77.1/24` +
  `dnsmasq`（按 eth0 MAC 固定发 `192.168.77.169`）；测完恢复。
- 防假阳性：WAN→LAN 隔离测试必须用 `-I <接口名>` / `--interface <接口名>`
  绑定**接口**；只绑源地址不改变出口，包会走 WiFi 产生「WAN 能通 LAN」的假
  阳性（当天实际踩到并纠正）。

## 24.10 首启验证（v113-2，`sysupgrade -n`）

首启全项 PASS：`sbe1v1k-g3.5c` / 6.6.147；uci-defaults 全消费；`S19sbe-port-roles`
与 `S23eth0-lan-attach` 在 rc.d；`sbe_ports.wan_port=eth1`；成员表
`0x51/0x49/0x1/0x19`（S19 日志「已按 eth1 写入并回读校验通过」）；br-lan =
eth0/eth2/eth3 + 三频 AP；eth0 冷启动实链路 2500（无假环回）；WAN eth1 从
上游拿到 192.168.10.x；WiFi_2.4G/5G/6G 全起；LuCI 登录页正常（`/` 200，
`/cgi-bin/luci/admin` 403 + `x-luci-login-required`）；overlay `/dev/loop0`
40.8M；日志噪声 0；镜像内 `eth0-lan-attach` 的 up 在「已在桥内」早退之前。

## 24.10 eth0 角色（改角色 + 重启）

`sbe-port-roles set eth0` + 重启，约 50 s 恢复，全部 PASS：UCI 三处同步
（`sbe_ports=eth0`、wan/wan6 `device=eth0`、br-lan ports `eth1 eth2 eth3`）；
SSDK 表 `0x31/0x29/0x19/0x1`；br-lan = eth1/eth2/eth3 + AP；eth0 实链路
2.5G；WAN eth0 从模拟上游拿到 `192.168.77.169`、默认路由正确、路由器可 ping
上游；WAN→LAN 隔离（绑定 WAN 口）ICMP 100% 丢包、TCP80 超时、TCP22 无应答。
回切 eth1 + 重启后一切恢复（WAN 192.168.10.x、eth0 回桥、2.5G）。

第一次隔离测试用了 `ping -I 192.168.77.1`（源地址），结果误判为「通」——
实际走 WiFi。改用接口绑定后结果正确。此坑已记入本报告「测试环境与步骤」。

## 24.10 运行期 live 切换

`sbe-port-roles set eth0`（不重启，脚本 rc=0）后：UCI 与成员表全部就位，
但 eth0 摘桥即 `Link is Down`，3.1 s 后以 `Link is Up - 10Gbps/Full` 回来
——**RTL8261N 假 10G 环回**，对端 2.5G 网卡 NO-CARRIER，WAN DHCP pending。
运行期自救全部无效：路由器侧 down/up 后仍是 10G Up；主机侧 `ethtool -r`
后仍无载波。

live 回切 eth1（rc=0）后：UCI/表复原、helper 把 eth0 挂回 br-lan；eth0 仍
假 10G，但 **eth1（QCA8081）直接恢复**——2.5G 链路 up、WAN 重新 DHCP、
`ping 8.8.8.8` 通、WiFi 管理全程未断。即 24.10 上 live 切换后可以靠回切
把 WAN 救回来，10G 口仍需重启。

## 25.12 live 回切复测（重点对照）

为回答「24.10 回切后 2.5G 口恢复，25.12 是否同样恢复」，刷回 25.12
v80-1-e0ee12cd 重跑同一套步骤。

- live 切入 eth0：与 24.10 相同——eth0 摘桥 3.1 s 后 `10Gbps/Full`，对端
  NO-CARRIER；期间 eth1 作 LAN 口入桥，dmesg 出现 `uniphy autoneg time out!`。
- live 回切 eth1：eth1 先 Down 后 `Link is Up - 2.5Gbps/Full`，再次伴随
  `uniphy autoneg time out!`（后证实来自 eth0，与 eth1 无关）；当时看到
  eth1 的 netdev RX/TX 计数保持 0/0、WAN 一直 `up=false, pending=true`、
  `ping 8.8.8.8` FAIL。**「RX/TX 恒 0」后来作废**：该计数在健康态也全 0
  （NSS offload 不统计），当天晚些的受控复现改用 DHCP/ARP/ping 等功能判据
  重新取证，结论见「真机受控复现结果」。eth0 仍 10000（假环回）。
- 重启（用户批准）约 45 s 恢复：表复原、eth0 回桥 2500、WAN 192.168.10.x、
  外网通、噪声 0、LuCI 200。

对照表：

| 回切后 | 24.10 v113-2 | 25.12 v80-1 |
| --- | --- | --- |
| eth1 物理链路 | 2.5G up | 2.5G up |
| eth1 收发 | 正常 | 发送侧通、接收侧断（PHY 计数器取证，ARP 上铜线但收不到应答） |
| WAN DHCP | 拿到租约、外网通 | pending、外网 FAIL |
| uniphy autoneg | 无该报错 | 每次角色变更后 `autoneg time out!`（后经源码+取证确认来自 port6/eth0 的 USXGMII 重连，与 eth1 无关，见补充分析） |
| eth0 | 假 10G、需重启 | 假 10G、需重启 |

## 结论与影响

1. **「改角色 + 重启」是两棵树唯一可靠的切换方式**，软硬件三处（SSDK 表、
   UCI、board.json）收敛正确，WAN/LAN 隔离有效。
2. **运行期 live 切换不可用**：两棵树都会把 eth0（RTL8261N）打进假 10G
   环回，运行期无法恢复。根治只能在驱动（方案四：`rtl8261n` 的 teardown/
   复位路径），此结论作为方案四触发条件 2 的证据。
3. **回切保命能力有树级差异**：24.10 回切后 2.5G 口立即恢复转发；25.12
   回切后 2.5G 口「link up、发包上铜线、但收不到任何应答」，只能重启。
   受控复现证明断点在 PHY→SoC 接收侧，且所有可回读的 SoC 侧状态与健康态
   相同，见下节源码级定性。
4. LuCI/运维层面：在 25.12 上使用 `sbe-port-roles set` 前应提示「可能需重启
   恢复」。后续若做「不重启切换」功能，必须先完成方案四。

## 补充分析：25.12 回切不转发是软件缺陷（源码级，2026-11-21）

结论：**是软件 bug，不是硬件问题**，原理上可修；但建议暂不修——它只在 live
切换流程出现，而该流程本身已被 RTL8261N 假 10G 挡住；「改角色 + 重启」路径
完全不触发。

### 缺陷不在 qca-ssdk 版本

24.10 构建树、25.12 构建树、QSDK 14 厂商源码三份
`src/adpt/hppe/adpt_hppe_portctrl.c` 逐字节相同（diff 为 0）。因此不是
「25.12 换了一个 ssdk」，差异在 6.12 内核/DTS 集成层。

### `uniphy autoneg time out!` 与 eth1 无关（更正）

- 消息来自 `adpt_hppe_uniphy_usxgmii_autoneg_completed()`：轮询 XPCS 的
  CL37 自协商完成中断位（`VR_MII_AN_INTR_STS`，寄存器地址 `0x1f8002`），
  100 次 × 1 ms；超时打印该消息并返回 `SW_TIMEOUT`。
- 但调用链有硬门槛：只有 `adpt_hppe_uniphy_autoneg_status_check()` 在端口
  模式为 **USXGMII/UQXGMII** 时才调用它。port5（eth1）是 SGMII PLUS，
  **永远走不到**。唯一会打印它的重连口是 port6（eth0，USXGMII）——live
  切换期间 eth0 摘桥/重连（含假 10G 环回）时触发。
- 因此该消息只是 eth0 重连的指纹，与「2.5G 口回切不恢复」没有因果关系；
  早前版本把这条消息挂在 eth1 流程上是错的。（其返回值被 void 调用者
  丢弃一事属实，但同样与 25.12 故障无关。）
- 真正可疑的分支仍是：`adpt_hppe_port_phy_status_change()` 只在速率/双工/
  流控变化时返回 TRUE。回切时 eth1 先 down、再以同样的 2.5G up，速率没变
  → 返回 FALSE → 整个 `if (status == A_TRUE)` 块被跳过，其中包含
  `adpt_hppe_uniphy_speed_set()` 与 `adpt_hppe_uniphy_port_adapter_reset()`，
  最后只重新打开 txmac/rxmac/bridge_txmac。这条「同速率轻量重连」路径在
  6.6/QSDK 栈上能自愈（24.10 实测），在 6.12 上不能。

### 6.12 侧差异候选（含 2026-11-21 晚取证后的状态）

| 候选 | 依据 | 现状 |
| --- | --- | --- |
| 内核 `qca808x` 驱动跨内核版本大改 | 6.6.147 680 行 vs 6.12.112 1232 行（diff 710 行）；`read_status` 在 2.5G 链路时把 `phydev->interface` 固定改为 2500BASEX | **首要嫌疑**（6.12 的重连路径可能重配 PHY 主机侧，而 ssdk 看不到） |
| phylink 模式字符串 `phy/sgmii`（启动）→ `phy/2500base-x`（回切后） | qca808x `read_status` 改写 `phydev->interface`，phylink 随之重新 configure | 指纹，不是配置来源：ssdk 的 `ssdk_phylink_mac_config` 只打日志不碰硬件 |
| 0037 让 mainline PCS 驱动充当 nsscc 的 uniphy 时钟父 | 6.6 栈上无此依赖 | 与本故障无关：0037 明确 dp 端口没有 pcs-handle，PCS 只提供时钟；两态 port5 时钟同为 125 MHz |
| XPCS resets 由 ssdk 与 PCS 双持有 | 0037 v3 故意保留：v2 删 resets 会让所有 dp 口零帧 | 与本故障无关（未动过） |

### 真机受控复现结果（2026-11-21 18:00，25.12 v80-1）

流程：健康基线取证 → `sbe-port-roles set eth0` → `set eth1`（故障）→ 只读取证
→ 重启恢复（18:02 恢复后重采健康基线）。原始输出存
`logs/relink-2026-11-21/`（`SUMMARY-2026-11-21.md` 与各 .txt）。

| 项目 | 健康启动 | 回切后故障态 |
| --- | --- | --- |
| eth1 链路 | 2.5G up、AN complete | 同 |
| ssdk port5 speed / interfaceMode | 2500 / SGMII PLUS | 2500 / SGMII PLUS |
| 成员表 p3/p4/p5/p6 | 0x51/0x49/0x01/0x19 | 同（p5=0x01 是角色脚本对 eth1 角色的设计值，不是故障） |
| uniphy0 0x1f0000/0x1f8001/0x1f8002 | 0/0/0 | 同 |
| port5 RX/TX 时钟 | 125 MHz | 同 |
| QCA8081（PHY 0x1c）BMCR/BMSR | 0x1040/0x796d | 同 |
| ping 网关时的 PHY `TxGoodFrame` | +5（FCS 错 0） | +3~4（FCS 错 0）——ARP 确实上了铜线 |
| 铜线方向收帧 `RxGoodFrame` | 持续增长 | 持续增长 |
| 网关 ARP 应答 | 邻居 REACHABLE、ping 3/3 | 邻居停在 FAILED/INCOMPLETE、ping 0/3 |

计数器语义来自 `qca-nss-phy/nss_ext/nss_phy_common.c`：
`RxGoodFrame`=MMD7 ingress（铜线→PHY），`TxGoodFrame`=MMD7 egress（PHY→铜线），
`Sys*` 四个字段该实现不填（恒 0，不是证据）。计数器默认 DISABLE，需
`ssdk_sh debug phycounter set 5 enable`，且**读后清零**，只有差值有意义。

由此把故障收敛为：**发送方向（SoC→PHY→铜线）是通的，断点在 PHY→SoC 的
接收方向；而所有可回读的 SoC 侧状态（成员表、时钟、uniphy 寄存器、PHY 标准
寄存器）与健康态逐项相同**——故障没有落在任何 ssdk 能回读的配置上。
二次 `ip link down/up` 可稳定复现同一故障，与角色脚本无关。

#### 拔插实验（选项 A，18:19）：不恢复，PHY 链路事件路径排除

故障态下物理拔下 eth1 网线 9 秒再插回（carrier 1→0→1），驱动完整走了一遍
`Link is Down` → `Link is Up - 2.5Gbps/Full`。结果仍无 DHCP、网关 ARP
FAILED、ping 0/3；夹 ping 的计数器显示 TX +5（包上铜线）、RX 也在涨。

结论：真实的铜线链路掉线/重连（PHY 状态机、`link_change_notify`、SGMII
FIFO 门控都会跑）**不能**把接收救回来 → 不是「某次事件没通知到」，而是
重连后的组合状态被钉死。

#### 补充对照（故障态 18:20 / 重启后健康态 18:22，同脚本同项）

| 项目 | 健康 | 故障 |
| --- | --- | --- |
| `port linkstatus get 5` | ENABLE | ENABLE |
| `port txmacstatus/rxmacstatus get 5` | ENABLE/ENABLE | 同 |
| `port macLoopback get 5` | DISABLE | 同 |
| uniphy0 / uniphy1 0x1f0000 | 0x0 / 0x0 | 同 |
| uniphy2 0x1f0000 | 0x1120 | 0x3140（eth0 假环回差异，与本故障无关） |
| PHY 0x1d（QCA8081 接口设备）reg0/reg2 | 0xff / 0x84a2 | 同 |

**盲区**：uniphy0/1 在健康态也读 0x0，说明 ssdk_sh 对 port5 所属 PCS 的读取
路径无效——SoC 侧 PCS0 真实寄存器从未被验证过；PHY 主机侧（SGMII+ 内部
PCS 配置）同样不可读。剩余候选只在这两个盲区里。

#### PHY 软复位实验（选项 B，18:25）：不恢复，PHY 侧排除

故障态下写 BMCR=0x9040（`ssdk_sh debug phy set 28 0 0x9040`）。PHY 确实复位：
dmesg 出现 `Link is Down`，3 秒后重新 `Link is Up - 2.5Gbps/Full`，复位后
BMCR/BMSR 回到 0x1040/0x796d。结果仍无 DHCP、ARP FAILED、ping 0/3；
TX +7（包上铜线）、RX +0x31（铜线帧进 PHY）。

结论：PHY 内部主机侧状态不是根因（或软复位清不到）。结合拔插实验，**PHY
侧所有可达的复位/重连手段都已排除**；剩余唯一候选是 SoC 侧 uniphy0/PCS0 在
「同速率轻量重连」后的状态——正是 ssdk 在 `adpt_hppe_port_phy_status_change()`
返回 FALSE 时跳过 `uniphy_speed_set`/`uniphy_port_adapter_reset` 的分支，
也恰是 `ssdk_sh debug uniphy get` 读不到（恒 0）的盲区。

#### unbind/rebind 实验（选项 2，18:28）：不恢复，nss-dp/phylink/PHY 驱动层排除

故障态下把 dp2（`3a001800.dp2`，eth1 的 platform device）从 `nss-dp` 驱动
unbind 再 bind（rc 均为 0），强制一次完整的驱动级重新 probe。结果：

- unbind 不只拆了 dp2：dmesg 显示 `eth2`、`eth3`、`eth0` 三个 netdev 也级联
  unregister（dp1/dp3/dp4 共用同一驱动实例的注册路径）；
- rebind 后 dp2 注册成**新的 netdev，名字变成 `eth0`**（不再是 eth1），且被
  `eth0-lan-attach` 帮助脚本挂进了 br-lan（`entered allmulticast/promiscuous
  mode`）；UCI 的 `network.wan.device=eth1` 指向已不存在的口；
- 对这块全新 probe 出来的 netdev 做 ping/ARP 探测：**依旧 100% 丢包**、
  邻居 FAILED；夹探测的 PHY 计数器 TX +0xf、RX +0x30（同样发得出、收得到
  「线」，就是不交付给主机）；`port speed get 5`=2500、`interfaceMode`=SGMII
  PLUS，与故障态相同。

结论：**整条 nss-dp → phylink → PHY 驱动的重新初始化都不能把接收救回来**。
驱动层（含 phylib 的 link_change_notify/FIFO、phylink 重配）全部排除，嫌疑
推到驱动可达范围之外：交换机/NSS 侧每口状态，或 SoC uniphy0/PCS0 的硬件
状态。注意事项：本次探测时新 netdev 在 br-lan 里（级联副产物），不是干净的
「WAN 口」复测；但「全新 probe 的端口仍收不到应答」这一核心事实成立。

随后的只读交换机状态探测（同故障态）：`stp portState get 0 5` = FORWARD、
`fdb ptLearnCtrl get 5` = ENABLE/FORWARD、txmac/rxmac = ENABLE——STP/学习
阻断假设也不成立；`portVlan ingress/egress get`、`vlan lan_wan_cfg get` 在本
ssdk 构建里返回 `This request is not support`（编译裁剪），交换机侧可读面
到此为止。设备已重启恢复（四口齐全、eth1 WAN DHCP 192.168.10.236、网关
REACHABLE）。

**静态核对收尾**：6.6 与 6.12 的 qca808x 驱动核心路径（含 SGMII FIFO 的
`link_change_notify`）两树一致，6.12 多出的约 550 行是 QCA8084/LED/时钟/测温
等与本口无关的功能；phylib 的 `phy_start`/PHY_UP 处理也逐行相同。两树差异点
仍未定位。

### 修复路线与代价

1. **只读取证（已完成，2026-11-21 18:00）**：结果见上一节。早前设想的三选
   （「XPCS 自协商卡死 / 时钟没恢复 / MAC 未启用」）已全部与健康态对照排除，
   指向 PHY 主机侧在重连时被改坏、而 ssdk 的回读面看不到。
2. **拔插实验（已完成，18:19）**：负向，PHY 链路事件/FIFO 假设排除（见上）。
3. **PHY 软复位实验（已完成，18:25）**：负向，PHY 内部主机侧状态排除；
   剩余候选收敛到 SoC 侧 uniphy0/PCS0 盲区。
4. **unbind/rebind 实验（已完成，18:28）**：负向，nss-dp/phylink/PHY 驱动层
   整体重新 probe 都不能恢复接收；STP/学习阻断也已排除。
5. **小补丁（已写好，2026-11-21）**：`25.12-6.12/nss/patches/qca-ssdk/
   0014-sgmii-adapter-reinit-on-relink.patch`，设计见
   `25.12-6.12/docs/SGMII_RELINK_FIX-2026-11-21.md`。两个触发点：轮询
   任务的同速 down→up 分支补上 adapter reset；`ssdk_phylink_mac_link_up`
   对 PHY 口置一次性 re-init 标志（覆盖「netdev 被 phylink 重启、PHY
   链路没断」的角色切换场景）。真机 NOT TESTED。
6. **验证**：一次 CI 构建 + 一次刷机，用同一套 live 步骤复测；dmesg 里
   应有 `port 5: re-init SGMII adapter after same-speed re-link`。没有
   串口，每轮只能刷机加事后取证，这是主要成本。

不推荐先动 0037 的 resets 归属（v2 删 resets 导致 eth0 失联）。

### 处置建议

记录为方案四（RTL8261N teardown/复位）的前置依赖：修好这一条也不能单独
解锁 live 切换。在 25.12 上继续以「改角色 + 重启」为支持路径；脚本/UI 提示
运行期改角色可能致 2.5G 口失联、需重启。

## 取证方法备注

- 两棵树刷机后 dropbear 主机密钥会变：先 `ssh-keygen -R 192.168.1.1`。
  主机 USB 网卡的 DHCP 租约可用 `sudo networkctl reconfigure enxc84d4424a1b5`
  触发更新。
- 个别重启的 `logread` 最早记录晚于 S19/helper 运行时刻（logd 就绪才开始
  缓冲），S19/attach 日志行可能缺失；功能判据以 SSDK 表值与
  `/sys/class/net/br-lan/brif/` 成员为准。
- 假环回判据：路由器侧 `speed=10000` 且对端（2.5G 网卡）NO-CARRIER。
  24.10 的 Down→Up 间隔约 2–3 s、25.12 约 3 s，均不像 admin down/up 那样
  只有约 10 ms——不要只看间隔，以速率与对端载波为准。
- 本次受控复现的 ssdk 取证守则：`ssdk_sh` 无 `help`，且
  `port link status get <p>` 在健康态同样报 `invalid or incomplete command`
  （语法本身无效，不是故障信号）；可用的是 `port speed get <p>` 与
  `port interfaceMode status <p>`。所有 `ssdk_sh` 调用都要 `</dev/null`。
  PHY 计数器默认 DISABLE，需 `debug phycounter set <p> enable`，且读后清零，
  只看差值。`portVlan ingress/egress get`、`vlan lan_wan_cfg get` 的组名在
  shell_config.c 里存在，但本 ssdk 构建返回 `This request is not support`
  （编译裁剪），不是语法错。
- nss-dp 的 unbind 是「牵一发动全身」：拆 dp2 会级联注销 dp1/dp3/dp4 的
  netdev，rebind 后端口按 probe 顺序拿到新名字（dp2 变成了 eth0）。做同类
  实验前先记下 `readlink /sys/class/net/*` 的映射，别按旧名字找接口。
- 长命令经 WiFi SSH 偶尔输出通道僵死（远端其实已执行完）：改为设备端脚本
  落盘再开新会话读取。eth0 假环回的 `received packet on eth0 with own
  address` 刷屏约 10 条/秒，会迅速冲掉 logd 环形缓冲。
