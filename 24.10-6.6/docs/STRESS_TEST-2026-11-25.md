# 24.10 v117-2 压测与验证报告（2026-11-25）

设备：Spectrum SBE1V1K（ipq9574，第三台），OpenWrt 24.10-SNAPSHOT
`sbe1v1k-g3.5c`（6.6.147），镜像 `24.10-6.6-v117-2-86a810fd`
（sysupgrade sha256 `898dc321ca8082a67a12df41a0326045dfa2baae07197fcfd62e7e894db4f6db`，
`sysupgrade -n` 刷入，镜像与设备侧 sha256 双验一致）。

拓扑：主机 USB 2.5G 网卡（`enxc84d4424a1b5`，192.168.1.2/235）接路由器 10G 口
（eth0，实链路 2500 Mbit/s）；路由器 2.5G WAN（eth1）接上游 Spectrum 网关
（192.168.10.1，DHCP 粘性 MAC，租约 192.168.10.237）；主机另经 eno0 直连同一
上游网段（192.168.10.100），用作对照组；主机 WiFi（wlp0s20f3，
192.168.1.230）接路由器，作第二条 LAN 入口。

约束：全程未改动 eth0 管理状态/端口角色/接线（规避 RTL8261N 假 10G 环回）；
未在设备上安装任何软件包（iperf3 为 `/tmp` 静态二进制，重启即消失）。

## 刷机首启结果

| 项 | 结果 |
|---|---|
| 版本/内核 | `sbe1v1k-g3.5c` / 6.6.147，BUILD_ID 一致 |
| 首启拓扑 | LAN 192.168.1.1；br-lan = eth0/eth2/eth3 + phy00.x；WAN eth1 DHCP 192.168.10.237 |
| `sbe_ports.main.wan_port` | eth1（uci-defaults 生效） |
| eth0 | 2500 Mbit/s、carrier 1、无假 10G 环回 |
| MAC | eth0 `:81`；eth1/eth2/eth3 均 `:82`（与刷机前一致，第三台重复 MAC 怪癖未变；S15 只处理 aat=1） |
| DTS `phy-reset-gpio` | **三组 0e/60/1、0e/52/1、0e/41/1**（`/proc/device-tree/soc@0/mdio@90000/phy-reset-gpio`）——GPIO 41 预检 **PASS**，`RTL8261N_GPIO41_PROBE_PLAN` 的前置条件满足 |
| 温度/内存 | 13 路 tsens 43–45 °C；MemTotal 1788288 KB |
| distfeeds | `downloads.openwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53`（正常） |
| 首启日志噪声 | 仅既有 ath12k `qmi failed to load rxgainlut/caldata` 类噪声（与旧镜像同） |

## 吞吐结果

| 测试 | 通道 | 结果 |
|---|---|---|
| WAN 直连基准（对照组） | 主机 eno0 → 上游 | 单流 41.4 MB/s；4 流聚合 43.7 MB/s（≈366 Mbps，上游/镜像站上限） |
| NAT 单流 | 主机 USB → eth0 → NAT → eth1 | 33.5 MB/s（首次）；13.7 MB/s（复测，服务器端波动） |
| NAT 2 并发流 | 同上 | 6.8+7.5 MB/s ≈ 31 MB/s 聚合（≈250 Mbps），0% 丢包，持续 30 s 稳定 |
| NAT 3 并发流（WiFi 入口） | 主机 wlp → 路由器 WiFi → NAT → eth1 | 3.3–3.6 MB/s×3，0% 丢包，稳定 |
| LAN 吞吐 | 主机 USB ↔ 路由器 eth0（iperf3 /tmp 静态） | 单流 2.31–2.33 Gb/s；4 流 2.35 Gb/s；反向同值——2.5G 口满速 |
| 设备本机上传 | 设备 /tmp → eth1 直发主机 eno0（HTTP sink，无 NAT） | 单流 110.5 MB/s；3 并发聚合 ~134 MB/s，0% 丢包，累计 ~400 MB |
| NAT 上传 | 主机 USB → eth0 → NAT → eth1 → Cloudflare | 单流 ~1.4 MB/s（远端限速）、60 s 发出 ~86 MB 超时；3 并发 30 MB 全部完成；全程 WAN 健康 |
| CPU/热压 | 设备 4 核满转 120 s + 持续 WAN ping | 温度 45.9→49.8 °C；ping 100/100 0% 丢包；loadavg 3.90 时转发正常 |

## 关键缺陷：eth1（WAN，QCA8081/dp2）TX 楔死

**现象**：NAT 转发突发时 eth1 的 TX 整体冻结，内核计数与 SSDK 端口计数均不再
增长（RX 只剩上游广播），路由器自身收不到上游网关的 ARP 应答（`ip neigh`
INCOMPLETE/FAILED），WAN 彻底不可用；**`ip link set eth1 down/up` 不能自愈**
（链路重新 AN 到 2500 Mbit/s Up，TX 仍冻结），**只能重启**。同一时刻 eth0/LAN
一切正常（可 SSH、ping 本机）。dmesg 无任何 NETDEV WATCHDOG、nss-dp、PPE、
ECM 报错；SSDK `PORT_TX_DROP_CNT_TBL` 为空（无丢包计数可查）。

**复现矩阵**（同一会话内）：

| # | 条件 | 结果 |
|---|---|---|
| 1 | 4 并发 NAT 流（USB 入口）+ ping | **楔死**（2 s 内，聚合仅 ~12 MB/s 时就挂） |
| 2 | 单流 45 s | 稳定，0% 丢包 |
| 3 | 2 并发流 30 s | 稳定，0% 丢包 |
| 4 | 3 并发流 + ping（USB 入口） | **楔死**（2 s 内） |
| 5 | 设备本机 3 并发下载（不 NAT） | 稳定 |
| 6 | 3 并发流（WiFi 入口） | 稳定 |
| 7 | 3 并发流（USB 入口，复跑） | 稳定（12.7 MB/s） |
| 8 | 3 并发流 + ping 原样复跑 | 稳定（12.6 MB/s，0% 丢包） |
| 9 | **2 并发流持续 30 min soak**（18 s 突发 / 35 s 间隔，USB+WiFi 各一流） | **第 11 轮（≈9 min）楔死**——两条流同时归零、100% 丢包、TX 冻结 |
| 10 | **单流持续 NAT 下载**（10 min 上限，USB 入口，无突发间隔） | **第 9 轮（≈4.3 min）楔死**——单流也触发 |
| 11 | 满速单流 NAT 下载（15 s 采样，快速鉴别） | **第 6 轮（≈84 s、eth1 rx 1.28 GB）楔死**——速率越高挂得越快 |
| 12 | 满速单流 NAT 下载，**eth1 TSO 关闭**（同上 probe） | **第 11 轮（≈2.75 min、eth1 rx 2.93 GB）仍楔死**——TSO 路径排除 |

判定修正：**并发数不是决定性因素**。30 min soak 前 10 轮（10 次突发、约
3.6 GB）全部稳定，第 11 轮仅 2 条流也中招；随后**单流**持续下载 4.3 分钟
同样楔死。触发面 = **经 eth0 进入、下载方向 NAT 转发的持续流量**，累计到
一定量后间歇性楔死；短促 3–4 流突发只是提高了瞬时概率。2 流及以下短测
通过、WiFi 入口 3 流、设备本机流量（含 3 并发 400 MB 上传）与 NAT 上传
方向均未触发。上游网关无责（主机直连同网关全程正常，WiFi 入口同 3 流
不挂）。

三次楔死的共同量纲：累计转发约 1.3–3.6 GB、启动后约 2–13 min（soak 楔死
时 eth1 `rx_bytes`=3.61 GB、uptime 12 min；单流楔死 4.3 min；满速鉴别
楔死仅 84 s、eth1 rx=1.28 GB、uptime 2 min）。**没有固定阈值**：速率越高
越早挂（满速 ~14 MB/s 时 1.28 GB，较慢时 3–3.6 GB），行为更像「每处理
若干 GB 转发流量即有一次挂死概率」，速率扩大单位时间内的触发次数。三次
楔死均发生在经 eth0 入口的下载转发期间，楔死前计数器与 ping 全正常。

遏制手段鉴别（2026-11-25 已实测，用户批准）：**关掉 eth1 的 TSO 不能阻止
楔死**。`/tmp/ethtool -K eth1 tso off` 生效确认（`tx-tcp-segmentation: off`、
软件 GSO 接手，之后网卡只收 MSS 小包，>32 段 TSO 路径整体消失），同一满速
单流 probe 仍在 ≈2.75 min、eth1 rx 2.93 GB 时楔死（复现矩阵 #12）。楔死时
补查：`ethtool -a eth1` 显示对端协商了 pause（RX/TX negotiated on）但
`rx_pause`/`tx_pause`/`rx_overflow` 计数全 0，PHY 流控假设也不成立。
**结论：TSO/EDMA 大包路径不是根因**；问题在这条转发链更底层的位置。

下一个鉴别（不涉及换线）：纯 WiFi 入口持续下载 ≥4 GB——若同样楔死，
说明问题在出口侧（PPE/端口 5 送包路径）；若干净，则锁定 eth0 入口
（RTL8261N RX/GRO）一段。

**证据目录**：`/tmp/sbe-flash/evidence-wan-dead/`（device-dump.txt 为首次楔死
全量 dump：links/wan/routes/neigh/ssdk/dmesg/logread；wedge-3flow.txt 为第二次
楔死现场；wedge-soak.txt 为 30 min soak 楔死时的 SSDK/内核计数）。临时目录，
不入库；关键结论已抄录于本文。

### 源码层面的机理解读（假设，未验证）

三棵树（24.10-6.6 / 25.12-6.12 / 25.12-6.18）的 qca-nss-dp 源码逐字节相同，
关键点：

- `nss_dp_main.c`：`netdev->gso_max_segs = NSS_DP_GSO_MAX_SEGS`，而
  `hal/soc_ops/ipq95xx/nss_ipq95xx.h` 把它定义为 `GSO_MAX_SEGS`（=65535）。
  设备上 `ip -d link show eth1` 实测 `gso_max_segs 65535`，与源码一致。
- `hal/dp_ops/edma_dp/edma_v3/edma_tx.c` 顶部注释明说：
  「HW does not support TSO for packets with more than 32 segments.
  **HW hangs up** if it sees more than 32 segments. Kernel Perform GSO for
  such packets with netdev gso_max_segs set to 32」，但 ipq95xx 的
  `gso_max_segs` 实际是 65535——**内核不会替它分段**。
- 同文件的兜底检查 `edma_tx_ring_xmit()` 用 `edma_tx_num_descs_for_sg()`
  数的是**描述符/frag 数**，不是 TSO 段数（`gso_segs`）。一个 64 KB
  GSO skb（MSS 1448 → 约 45 段）通常只有 ~17 个 frag，能通过 ≤32 的
  检查，然后带着 45 个 TSO 段下发给硬件。
- `tx_requeue_stop` 默认 1（`nss_dp_main.c`），驱动选择「缺描述符时静默
  丢包、不停队列」，所以一旦 TX 完成环不再回收，内核不会报
  NETDEV WATCHDOG、计数器也不会动——与观察到的「静默冻结」完全一致。

这条链与「必须重启才恢复（HW 挂死而非软件状态）」吻合，曾作为主假设；
但 **2026-11-25 关 TSO 实验（复现矩阵 #12）否定了它作为触发条件**：TSO
关闭后硬件根本收不到 >32 段大包，楔死照旧。该源码分析保留作背景——它
解释了厂商注释里「HW hangs up」确实存在，但本缺陷的触发点在别处。

补充鉴别（2026-11-25 同场会话）：

- 设备本机 3 并发 400 MB 上传（直发 eth1、不经 NAT）**未触发**；NAT 上传
  方向（USB 入口、~90 MB）也未触发。说明触发面在**下载方向转发**这条
  特定链路上，而非泛化的 TX 负载。
- TSO 关闭仍楔死、pause 计数全 0 → 排除 TSO/EDMA 大包路径与 PHY 流控。
- 楔死与累计转发量相关但没有固定阈值（满速 84 s/1.28 GB 至慢速 9 min/3.6 GB
  都会发生），不像单包形态问题，更像某种状态/计数耗尽或队列粘连。剩余
  嫌疑集中在两处：① 出口侧——PPE 端口 5 出口队列（SOAK 楔死 dump 中
  QUEUE_TX_COUNTER queue=0208 与 PORT_TX_COUNTER port=0005、内核
  tx_packets 同值冻结，即 PPE 停摆而非 CPU 不发）；② 入口侧——eth0
  （RTL8261N/EDMA RX/GRO）在持续下载下的运行期退化。WiFi 入口长跑
  与 eth0 入口长跑对比可区分二者。

## 长稳（30 min soak）

方案：每轮 2 条并发 NAT 下载（一条经 USB/eth0 入口，一条经 WiFi 入口，
各 18 s）+ 每轮经 USB ping 223.5.5.5 + 设备侧采样（loadavg、eth1 TX/RX、
conntrack、温度）；轮间 35 s。

结果：**第 11 轮（≈9 min，累计下载约 3.6 GB）楔死**，未跑满 30 min。
前 10 轮全部 0% 丢包，USB 入口流 6.5–8.2 MB/s、WiFi 入口流 5.3–7.2 MB/s，
温度 44.9–46.3 °C。第 11 轮两条流同时归零，ping 100% 丢包。楔死现场
（soak 日志 `/tmp/sbe-flash/soak-000335.log`，dump 另存
`evidence-wan-dead/wedge-soak.txt`）：

- 内核 eth1 `tx_packets` 冻结在 1,859,104（与上一轮相同）；SSDK
  `PORT_TX_COUNTER` port=0005 = 1,859,106，`QUEUE_TX_COUNTER`
  queue=0208 = 1,859,106，同值冻结；
- eth1 链路 2500 Mbit/s、carrier 1，operstate up；`ip neigh` 对
  192.168.10.1 INCOMPLETE；conntrack 85 条；
- dmesg/logread 无 NETDEV WATCHDOG、nss-dp、netifd、DHCP 相关报错；
- `ip link set eth1 down/up` 在本次会话早前已验证不能自愈，重启恢复。

结论：长稳不通过。此缺陷使 24.10 镜像在「持续 NAT 下载」（单流即可）场景下
不可用（任意时刻都可能静默断网），优先级升为发布阻断项。

## 待办与建议

1. **定性（发布阻断）**：该缺陷使 24.10 镜像在持续 NAT 下载下不可用，且
   24.10 是当前三台设备的主力固件。需要先回答两个问题：
   - 是 v113→v117 回归还是 NSS/nss-dp 长期问题？→ 刷 v113-2 同条件
     10 min soak 对照（需要用户批准刷回旧镜像）。
   - 只有 eth0 入口（USB 2.5G）触发，还是 eth2/eth3（qca8075）入口
     也会？→ 换线到 LAN 口做同条件对照（需要用户批准换线）。
2. **TSO 鉴别（已完成，阴性）**：关 eth1 TSO 后楔死照旧（#12），排除
   TSO/EDMA 大包路径。下一步鉴别：纯 WiFi 入口持续下载 ≥4 GB（区分
   出口侧 PPE ↔ 入口侧 eth0）；之后视结果再做 eth2/eth3 入口对照
   （需要用户批准换线）。
3. **驱动层定位（不改固件）**：出口侧优先查 PPE 端口 5 出口队列停摆
   （queue=0208 与 port=0005 同值冻结）；入口侧查 eth0 RX（EDMA RX 环/
   GRO/RTL8261N 运行期退化）。EDMA 驱动 `tx_requeue_stop=1` 的静默丢包
   是次生因素，可考虑改成默认 0 让队列停住以暴露 NETDEV WATCHDOG。
4. GPIO 41 探针计划的前置预检已在 v117-2 上通过，可按原计划择机执行
   （与本缺陷无关，独立推进）。
