# 同速 re-link 后 2.5G 口收不到包：qca-ssdk 修复补丁（2026-11-21）

补丁：`nss/patches/qca-ssdk/0014-sgmii-adapter-reinit-on-relink.patch`
状态：本地编译 PASS；CI PASS；**真机复测 FAIL（未修复，2026-11-21 晚）**。
埋点证明两条触发路径都生效，但故障签名不变——见文末「真机结果」。

**2026-11-22 定案与移除**：真正的根因是摘桥时桥核心下发的 STP DISABLED 把
pp5 的 `CST_STATE` 留在 0，PPE 入口做 STG 过滤整口丢帧——与本补丁的 SGMII
adapter 无关。修复为 qca-nss-dp 0009（已真机 PASS，v88-1），见
`ETH1_STP_INGRESS_DROP-2026-11-22.md`。0014 **已于 2026-11-22 移除**
（`nss/install.sh` 按 glob 应用补丁，删除文件即完成移除；装配树回到
pristine + 0001–0013，`make package/qca-ssdk/clean compile` PASS）。
本文保留为历史记录，文中的补丁内容与复测步骤只适用于 v82-1。

## 问题回顾

25.12（6.12.112）上 live 改端口角色（`sbe-port-roles set eth0` →
`set eth1`）后，eth1（QCA8081，SGMII PLUS，ssdk 口 5）链路正常 up、
发包上铜线，但收不到任何应答。受控实验结论（见
`logs/relink-2026-11-21/SUMMARY-2026-11-21.md`）：

- 拔插网线（真实链路掉/重连）：不恢复；
- PHY 软复位（BMCR=0x9040）：不恢复；
- nss-dp unbind/rebind（整条驱动重新 probe）：不恢复。

可回读的 ssdk 面（速度/接口模式/成员表/txmac/rxmac/STP/学习）两态全同，
剩余盲区是 SoC 侧 uniphy0/PCS0。24.10（6.6）同流程正常。

## 源码定位

ssdk 轮询任务 `qca_hppe_mac_sw_sync_task()`（`adpt_hppe_portctrl.c`，
间隔 1 s）在链路 down→up 时，用 `adpt_hppe_port_phy_status_change()`
比较速度/双工/流控；**全部不变时返回 A_FALSE**，整块重配被跳过——包括
`adpt_hppe_uniphy_port_adapter_reset()`（SGMII PLUS 走
`adpt_hppe_uniphy_psgmii_port_reset()` 的 ch0 adapter 软复位）。

而 live 角色切换时，PHY 的物理链路从未中断（网线一直插着），phylib 的
`phy_read_status()` 始终报 link up，ssdk 轮询**看不到 down→up 过渡**，
adapter reset 也不会发生。netdev 由 netifd 停/起（phylink_stop/start）
这一事件只在 `ssdk_phylink_mac_link_up/down` 里有入口，但该回调对
`PHY_F_FORCE` 端口之外直接 return，port5 被忽略。

## 补丁内容（0014）

两个互补触发点，主逻辑集中在新增函数
`adpt_hppe_port_sgmii_adapter_reinit()`（仅对 SGMII/QSGMII/PSGMII 家族
生效，USXGMII/UQXGMII 保持原 speed-change 路径）：

1. 轮询任务的 down→up 分支：当 `adpt_hppe_port_phy_status_change()`
   返回 A_FALSE（同速 re-link）时也执行 adapter re-init。此前这条分支
   只重开 txmac/rxmac/bridge_txmac。
2. `ssdk_phylink_mac_link_up()` 对 PHY 连接端口置
   `port_relink_reinit`（`struct ssdk_port_priv` 新字段），并唤醒轮询
   任务；轮询在本轮 PHY 链路 up 时执行一次 re-init 并清标志。覆盖
   「netdev 被 phylink 重启但 PHY 链路没断」这一角色切换场景。

re-init 序列：关 bridge_txmac/txmac/rxmac → 10 ms →
`adpt_hppe_uniphy_port_adapter_reset()` → 10 ms → 重开三个 MAC 门控。
每次执行打印 `SSDK_INFO("port %d: re-init SGMII adapter after
same-speed re-link")`，便于真机 dmesg 取证。

汇编事实：re-init 在现装配树源码上 `diff -u` 生成，`patch -p1
--fuzz=0` 对「pristine + 0001–0013」应用通过，结果与修改树逐字节一致。

## 验证

| 检查点 | 状态 |
|---|---|
| 补丁对「pristine + 0001–0013」`patch -p1 --fuzz=0` 应用、结果与修改树 `diff -r` 逐字节相同 | PASS |
| 本地 `make package/feeds/nss/qca-ssdk/clean` 后重编（装配树，GCC 14.3） | PASS（rc=0，0 warning/0 error；`ssdk_init.o`、`adpt_hppe_portctrl.o` 均重新编译；`strings adpt_hppe_portctrl.o` 含 `port %d: re-init SGMII adapter after same-speed re-link`；产出 `kmod-qca-ssdk-nohnat-6.12.112-r1.apk` 649,156 B） |
| CI `build-25.12-6.12.yml` 全流程 + verify-image | PASS（run `82`，`44896263334`，commit `cf26e07`；Release `25.12-6.12-v82-1-cf26e075`） |
| 真机复测（v82-1 刷机，2026-11-21 20:05） | **FAIL——补丁未修复缺陷**，详见下节 |

## 真机结果（2026-11-21 20:05，v82-1）

复测记录：`logs/relink-2026-11-21/relink-test-0014-summary-2026-11-21.md`。

- 基线正常（eth1 DHCP 192.168.10.239、ping 网关 2/2）；
- `set eth0` → `set eth1` 后，dmesg 出现 3 条
  `port 5: re-init SGMII adapter after same-speed re-link`——轮询同速分支与
  mac_link_up 标志两条触发路径都执行了；
- 故障签名与补丁前完全一致：DHCP 超时、静态 IP 下网关与本机（同二层直连）
  ping 全丢、PHY RxGoodFrame 持续增长但零交付。

结论：`adpt_hppe_uniphy_port_adapter_reset()` 不是缺失的那一步。

## 后续实验（2026-11-21 晚，均负向）

在同一设备上继续做的实验与判据（证据：`logs/relink-2026-11-21/step-test-2026-11-21.md`，
该目录被 gitignore，仅本机保存）：

- **分步定位**：只做 `set eth0`（eth1 降为 LAN）时收包正常（主机 ARP 应答来自
  eth1 的 MAC、ping br-lan 6/6）；再 `set eth1` 立刻死；再 `set eth0` 又复活
  → 触发点是「eth1 切为独立 WAN」这一步。
- **成员表不是触发器**：故障态同值重写、`0x19→0x1` 翻转写均无效；eth1 仍是
  桥成员时强写 p5=0x1 照样收包；保持表已正确再执行 `set eth1`（脚本跳过写表、
  只做 netifd 重载）照样死。
- **promisc 无效**：`ip link set eth1 promisc on` 后广播判据仍无增量（MAC 过滤 /
  收包类型假设排除）。
- 判据说明：交换机成员表、uniphy 寄存器回读、`/proc/interrupts` 都不能区分
  两态（中断有 NAPI 合并）；可靠判据是「主机发 300 个 UDP 广播后设备
  `Ip: InReceives` 的增量」——健康态 +351，故障态仅背景 +20 左右。

至此黑盒可达的复位/重连/写表/标志全部负向；剩余方向是带埋点的 25.12 构建
（在 qca-nss-dp 收包/异常路径或 ssdk 端口分类上计数）或与 24.10 同步骤的
驱动行为对比。带埋点的构建已刷机取证（2026-11-22）：故障态 PHY 收帧 412、
EDMA 环 prod/reap 全 0 —— 帧进不了 EDMA，断点在交换机/NSS 入口，
驱动与协议栈排除（详见 `RX_DIAG_BUILD-2026-11-21.md`「真机结果」）。

真机复测步骤（v82-1 当时用；0014 已移除，`re-init SGMII adapter` 日志
在新镜像中不会再出现）：

- `sbe-port-roles set eth0` → `set eth1`；
- `dmesg | grep "re-init SGMII adapter"` 应出现 port 5（如角色切换
  走的是 mac_link_up 路径；拔插路径走轮询分支）；
- eth1 DHCP 租约、网关 ping、`ssdk_sh debug phycounter show 5` 的
  RxGoodFrame 与 ping 应答同时增长。

## 风险

- 每个 PHY 口的 netdev 起或真实 re-link 都会多一次 adapter 软复位
  （约 20 ms 端口停顿）；角色切换本身伴随网络重配，影响可接受。
- 若真机上 dmesg 不出现 port 5 的 re-init 行，说明两个触发点都没覆盖
  到实际路径，需要按现场证据再加触发（例如从 portVlan member update
  挂钩）。
- 该补丁只针对 25.12 树；24.10 无此问题，不移植。
