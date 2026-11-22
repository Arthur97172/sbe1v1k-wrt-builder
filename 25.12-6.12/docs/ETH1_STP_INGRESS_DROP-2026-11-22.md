# 25.12 回切 eth1 不转发：根因=交换机入口 STP 过滤，nss-dp 修复 0009（2026-11-22）

状态：根因已定性并经真机因果验证（手工置回 forwarding 即恢复）；
修复补丁 `nss/patches/qca-nss-dp/0009-nss-dp-stp-forward-on-bridge-detach.patch`
本地装配/编译 PASS；CI run 88 PASS；**真机复测 PASS（2026-11-22，v88-1）**。

相关文档：`RX_DIAG_BUILD-2026-11-21.md`（EDMA 埋点，确认帧到不了 EDMA）、
`SGMII_RELINK_FIX-2026-11-21.md`（0014 adapter re-init，已证伪）。

## 结论

故障态下帧**已经进入交换机 MAC/PPE**，但在 PPE 入口被 **STG ingress
filtering**（drop code 115）整口丢弃，根本没送到 CPU 端口。原因是端口离开
br-lan 时桥核心先发 STP 状态 DISABLED（nss-dp 把 pp5 的 `CST_STATE` 写成 0），
此后该口成为独立 WAN 接口、不会再收到任何 STP 状态迁移，入口过滤就一直
生效。手工 `ssdk_sh stp portState set 0 5 forward` 后立即恢复。

原计划的 `SBE_SSDK_DIAG` 诊断构建**不再需要**：现镜像里的
`/sys/ssdk/packet_counter` 已经能读出端口级收包/丢弃计数（见下节）。

## 判据：/sys/ssdk/packet_counter

qca-ssdk 初始化时无条件创建 `/sys/ssdk/packet_counter`（源码
`src/init/ssdk_plat.c` 的 `ssdk_sysfs_init()`，实现在
`src/adpt/hppe/adpt_hppe_misc.c` 的 `adpt_hppe_debug_counter_get`）。
`cat` 读全表，`echo 1 >` 清零。关键行：

- `CPU_CODE_CNT_TBL` / `DROP_CPU_CNT_TBL`：按（端口, code）命名，
  `drop_code_idx=(i-256)/8`、`port=(i-256)%8`。**送 CPU 的帧**记在
  `port=N:None,dropcode:0`；
- `PORT_RX_COUNTER_TBL`：各物理口入口收包数（VP/policer 块
  `PHY_PORT_RX_CNT_TBL`，按口索引）；`PORT_RX_DROP_CNT_TBL` 为入口丢弃；
- 入口丢弃按 drop code 命名，**`STG ingress filtering drop` 的 dropcode
  是 115**（`dropcode[]` 数组第 115 项）。

标定（健康态，eth1=WAN）：主机发 300 个 UDP 广播后，port5 的
`PORT_RX` 与 `DROP_CPU[5][dropcode 0]` 同步 +395（含背景帧）——计数是活的，
且「入口收到」与「送 CPU」一一对应。

注意：`PORT_RX_COUNTER_TBL` 在故障态也照常增长，因为它计的是**入口收到**，
不是送 CPU；判读必须看 `DROP_CPU` 命名行。

## 三态证据（2026-11-22 凌晨，dpdiag 镜像 sbe1v1k-25.12-dpdiag-29c8398e）

每次操作前 `echo 1 > /sys/ssdk/packet_counter` 清零，然后发 300 个广播。

| 状态 | port5 PORT_RX 增量 | DROP_CPU[5][0] 增量 | STG(115) 增量 | 结论 |
|---|---|---|---|---|
| 健康（eth1=WAN） | +395 | +395 | 0 | 全部送 CPU |
| 故障（`set eth0`→`set eth1`） | +426 | **0** | **+426** | 全部在入口被 STG 丢弃 |
| 手工置 forward 后 | +303 | **+303** | **0** | 恢复，且逐帧对账 |

故障快照的绝对值（`logs/ssdkdiag-2026-11-22/`，gitignore）：
发广播前 port5 `PORT_RX=14872 / DROP_CPU[5][0]=14788 / STG=84`，
发广播后 `15298 / 14788 / 510` —— 增量全部落在 STG 桶里。
恢复后的紧密对照（tight-a → tight-b）：`PORT_RX 18179→18482`、
`DROP_CPU[5][0] 17105→17408`、`STG 1074→1074`。

## 源码链路（25.12 = 6.12.112）

1. `set eth1` 触发 netifd 把 eth1 从 br-lan 摘除 → `net/bridge/br_if.c`
   `del_nbp()`；
2. `br_stp_disable_port()` → `br_set_state(BR_STATE_DISABLED)`，带
   `SWITCHDEV_F_DEFER` 的 `SWITCHDEV_ATTR_ID_PORT_STP_STATE` 属性；
3. `del_nbp()` 内 `switchdev_deferred_process()` 在**摘链之前**执行该属性
   → nss-dp 阻塞 notifier → `nss_dp_stp_state_set(BR_STATE_DISABLED)` →
   `fal_stp_port_state_set(0, 0, macid, FAL_STP_DISABLED)` → IPE_L2 的
   `CST_STATE` 表（base 0x060000 + 0x100 + 4×port）写成 0
   （1=blocking、2=learning、3=forwarding，复位默认 3）；
4. 之后 `netdev_upper_dev_unlink()`、清 `IFF_BRIDGE_PORT`；eth1 成为独立
   WAN 口，**再没有任何代码把它设回 forwarding**；
5. PPE 入口对 STP 非 forwarding 的端口做 STG 过滤，全部帧记
   `STG ingress filtering drop`（115）后丢弃。

为什么启动/健康态没事：CST_STATE 复位默认 3，桥接管端口后
`br_stp_enable_port()` 会再发 FORWARDING。只有「从桥里摘出来单独用」这一
动作会把它留在 0。24.10 用同样的内核逻辑（6.6 的 `del_nbp()`/
`br_stp_disable_port()` 与 6.12 逐行相同），但 24.10 实测回切后立即恢复——
差异尚未定案（可能 24.10 live 切换时端口未被真正 disable），不阻塞本修复。

## 手工验证（已做，2026-11-22）

```
ssdk_sh stp portState set 0 5 forward </dev/null
ssdk_sh debug reg get 0x60114 4        # 回读 [Data]:0x3（forwarding）
```

立即：STG 丢弃停止、`DROP_CPU[5][0]` 恢复随收包增长；eth1 拿到 DHCP
`192.168.10.242`、默认路由经 192.168.10.1、网关 ping 2/2；dpdiag 判据
`sbe-rx-diag` ring20 `reap=1188 / srcport 5:1188 / handoff_gro=1188`。
因果链闭合。

注：手工设置不持久；重启后 CST 回到默认 3、wan_port=eth1 照样工作。
修复前设备维持「改角色 + 重启」的临时回退。

## 修复补丁（qca-nss-dp 0009）

`nss/patches/qca-nss-dp/0009-nss-dp-stp-forward-on-bridge-detach.patch`
（只碰 `nss_dp_switchdev.c`，位于 6.1+ 分支的 setup/cleanup 区）：

- 新增 netdevice notifier：`NETDEV_CHANGEUPPER` 且 `linking==false` 且被摘
  的 upper 是桥 master（`netif_is_bridge_master`）且 dev 是 dp 物理口
  （`nss_dp_is_phy_dev`）时，调 `nss_dp_stp_state_set(dp_priv,
  BR_STATE_FORWARDING)`——同一函数顺带撤掉 slow-protocol 过滤；
- 用事件参数里的 upper 判断而不是 `netif_is_bridge_port()`：回调发生在
  `netdev_upper_dev_unlink()` 内部，此时 `IFF_BRIDGE_PORT` 尚未清除；
- notifier 随 switchdev notifier 一起在 `nss_dp_switchdev_setup/cleanup`
  注册/注销（`switch_init_done` 门控）；
- 顺序保证：`del_nbp()` 中 deferred STP DISABLED 先执行，CHANGEUPPER
  后到，所以 restoring forward 一定覆盖在 disable 之后。

## 验证记录

| 检查点 | 状态 |
|---|---|
| 0009 对「pristine + 0001–0008」`patch -p1 --fuzz=0` 应用通过，结果与修改树 `diff -r` 逐字节一致 | PASS |
| 装配树 `make package/qca-nss-dp/clean compile`（GCC 14.3，6.12.112） | PASS（rc=0，无 warning/error；`nss_dp_switchdev.o` 含 `nss_dp_netdev_event`/`nss_dp_netdev_notifier` 符号） |
| CI 构建（run 88，Release `25.12-6.12-v88-1-17884656`） | PASS（产物 3 个，sysupgrade sha256 `b5a2c361d6ae78e90bf19fd97efc88c29d992fd7b5fe509c9c08ec301ea17f78`） |
| 真机复测（v88-1，`sysupgrade -n`） | PASS（详见下节） |

### 真机复测结果（2026-11-22，v88-1 = sbe1v1k-25.12-17884656）

刷机后首启 `wan_port=eth1`，eth1 获 DHCP `192.168.10.238`、网关
192.168.10.1 ping 2/2。每次操作前 `echo 1 > /sys/ssdk/packet_counter`，
主机 eno0 发 300 个 UDP 广播到 192.168.10.255。

| 步骤 | port5 PORT_RX | DROP_CPU[5][0] | STG(115) | 结论 |
|---|---|---|---|---|
| 健康基线（首启） | +342 | +342 | 0 | 对账一致 |
| `set eth0` → `set eth1`（原故障路径） | +320 | +320 | **0** | **修复生效** |
| `set eth0` 回归（eth1 回 LAN） | — | — | — | 主机经 eno0 ping br-lan 6/6，L2 转发正常 |

原故障路径的其它判据全部 PASS：

- `ssdk_sh debug reg get 0x60114 4` 回读 `0x3`（forwarding，不用再手工设置）；
- eth1 立即恢复地址与默认路由，网关 192.168.10.1 ping 2/2（udhcpc 4 秒
  内拿到原租约；角色切换瞬间 `ip -br addr` 短暂显示 DOWN 属 live reload
  的过渡态）；
- 全程 `STG ingress filtering drop` 为 0，`DROP_CPU[5][0]` 与 `PORT_RX`
  逐帧对账。

对照修复前（dpdiag 镜像 29c8398e）同一步骤为 `PORT_RX +426 / DROP_CPU +0 /
STG +426`，本镜像三态判据已全部翻转。证据存档
`logs/v88-2026-11-22/`（gitignore：healthy/fault 前后快照与 fw88.bin）。
测试结束已 `set eth1` 恢复默认角色（WAN=eth1，地址 .238），设备运行生产
镜像 v88-1。

真机复测步骤（下一版镜像）：

1. 刷 `sysupgrade -n` 后确认健康基线：`echo 1 > /sys/ssdk/packet_counter`，
   发 300 广播，`PORT_RX`≈`DROP_CPU[5][dropcode 0]`；
2. `sbe-port-roles set eth0` → `set eth1` 复现；eth1 应直接拿到 DHCP；
3. 判据：`DROP_CPU` 的 `port=5:None,dropcode:0` 随广播增长，且不再出现
   `STG ingress filtering drop`（清零后为 0）；`ssdk_sh debug reg get
   0x60114 4` 回读为 0x3；
4. 顺带回归：把 eth1 重新加回 br-lan（`set eth0`）后二层转发正常——桥对
   成员口照旧发 FORWARDING，不应有副作用。

## 后续

- 0009 真机已 PASS（v88-1），建议移除 0014（adapter re-init）：它已被
  证伪、每次角色切换/重链多一次约 20 ms 端口停顿。按独立小改动处理，
  尚未执行；移除后需再验证一次角色切换。
- 原 `SBE_SSDK_DIAG` 构建计划取消（本问已被 `/sys/ssdk/packet_counter`
  回答）；已实现的 `SBE_DP_DIAG` 诊断构建（workflow `dp_diag` 输入、
  `patches-diag/`、`files-rxdiag/`）同日整体移除，`docs/RX_DIAG_BUILD-2026-
  11-21.md` 保留为历史取证记录。
- 24.10 为何不受影响可另立项；6.6 内核源码与 6.12 相同，差异应在桥/端口
  状态路径，不在 nss-dp。
