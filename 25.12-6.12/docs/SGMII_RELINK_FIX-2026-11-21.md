# 同速 re-link 后 2.5G 口收不到包：qca-ssdk 修复补丁（2026-11-21）

补丁：`nss/patches/qca-ssdk/0014-sgmii-adapter-reinit-on-relink.patch`
状态：本地编译 PASS（见文末「验证」）；CI 已触发；**真机 NOT TESTED**。

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
| CI `build-25.12-6.12.yml` 全流程 + verify-image | 见本次提交触发的 run（结果以 CI 为准） |
| 真机 | NOT TESTED |

真机复测步骤（需单独批准）：刷机后按同一套 live 步骤复测：

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
