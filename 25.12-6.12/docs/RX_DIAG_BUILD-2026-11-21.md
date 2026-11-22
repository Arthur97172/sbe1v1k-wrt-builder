# 25.12 Rx 埋点诊断构建（SBE_DP_DIAG=1，2026-11-21）

诊断补丁：`nss/patches-diag/qca-nss-dp/0001-sbe-rx-diag-counters.patch`
构建开关：`SBE_DP_DIAG=1`（CI 为 `workflow_dispatch` 输入 `dp_diag`）
读取工具：`/usr/sbin/sbe-rx-diag` → `/proc/edma_ring_util_stats/edma_rx_diag`
状态：本地装配/补丁/编译验证见文末；真机 PASS（2026-11-22），判读结果见文末
「真机结果」。

**2026-11-22：该诊断构建已整体移除**（workflow 输入、`nss/patches-diag/`、
`files-rxdiag/` 与脚本分支均已删除，见 `ETH1_STP_INGRESS_DROP-2026-11-22.md`）。
本文保留为取证记录；新镜像里对应的检查改用生产镜像自带的
`/sys/ssdk/packet_counter`。下面命令中的开关已不再存在。

## 背景

25.12（6.12.112）live 改端口角色（`sbe-port-roles set eth0` → `set eth1`）后，
eth1（QCA8081，SGMII PLUS，ssdk 口 5）链路 up、发帧上铜线、PHY RxGoodFrame
持续增长，但 CPU 侧零交付；只有重启恢复。黑盒手段（拔插、PHY 软复位、
unbind/rebind、成员表重写、promisc）全部负向，0014（adapter re-init）在
v82-1 上真机 FAIL，见 `SGMII_RELINK_FIX-2026-11-21.md`。

黑盒判据只剩「主机发 300 个 UDP 广播 → 设备 `Ip: InReceives` 增量」，
无法区分帧停在 EDMA 之前、EDMA 之内还是交付之后的协议栈。这个诊断构建
在 qca-nss-dp 的 Rx 路径上计数，把三段分开。

## 构建

### CI（推荐）

1. Actions → `📦 Build 25.12-6.12` → Run workflow → **`dp_diag` 勾选**；
2. Release tag 带 `-dpdiag` 后缀，release notes 标注
   「已启用（SBE_DP_DIAG=1）：qca-nss-dp Rx 埋点，非生产用」；
3. 其余（种子、18 个插件、NSS 装配、0014）与生产构建完全相同，
   唯一变量就是埋点，便于与 v82-1 对照。

### 本地

```sh
SBE_CI=1 SBE_DP_DIAG=1 ./25.12-6.12/scripts/ci/prepare-tree.sh   # 装配（含 diag 补丁）
SBE_DP_DIAG=1 ./25.12-6.12/build/sbe1v1k-build.sh               # 编译（render-overlay 会叠 files-rxdiag）
```

（`prepare-tree.sh` 只认 CI 入口，本地要带 `SBE_CI=1`；`scripts/local/build-wifi-image.sh`
同样继承环境变量。）

`SBE_DP_DIAG` 与 `SBE_VARIANT` 正交：诊断镜像仍是 production 变体，
只是多一份 qca-nss-dp 补丁、一个 `/usr/sbin/sbe-rx-diag`，REVISION 变成
`sbe1v1k-25.12-dpdiag-<sha8>`（`dpdiag` 放在尾部 SHA 之前——apk 3.x 的
`~` 后缀要求十六进制，放在 SHA 之后就装不上基础包）。

装配期断言（接线错了会立刻失败，不会静默出生产镜像）：

- `prepare-tree.sh`：`SBE_DP_DIAG=1` 时要求 `patches-diag/qca-nss-dp/*.patch`
  存在、`files-rxdiag/usr/sbin/sbe-rx-diag` 可执行，并在 `nss/install.sh`
  之后 grep 装配树源码确认 `sbe_diag_reap_desc` 已落地；
- `verify-image.sh`：双向断言——诊断镜像必须带 `/usr/sbin/sbe-rx-diag`
  且版本行含 `sbe1v1k-25.12-dpdiag-`；生产镜像两者都不得出现。

## 埋点位置与字段

计数器按 **Rx 描述符环**（`rxdesc_rings[]`）存放，随 `rx_desc_stats` 走。
Rx 环是**各端口共享**的，所以另按描述符里的交换机源端口号分桶。

| 字段 | 递增位置 | 含义 |
|---|---|---|
| `irq` | `edma_rx_handle_irq` | 该环收到的中断次数 |
| `poll` | `edma_rx_napi_poll` 入口 | NAPI 轮询次数 |
| `reap` | `edma_rx_reap` | 累计回收的描述符数（硬件已置 done 并进环） |
| `src_valid` | `edma_rx_get_src_dev` PORTID 分支 | 描述符带合法 PORTID 源类型 |
| `src_port[0..7]` | 同上 | 按源端口号分桶的帧数 |
| `src_port_other` | 同上 | 源端口号 ≥ 8 的帧数 |
| `no_ndev` | `edma_rx_get_src_dev` 的 `done:` 返回点 | 源端口解析不到 netdev 而丢帧 |
| `linear_ok` | 线性路径 | 线性处理函数接受了该包（返回 true） |
| `linear_consumed` | 线性路径 | 线性处理函数返回 false，skb 在驱动内消费 |
| `scatter` | 主循环 scatter 分支 | 分散帧（descriptor 不连续） |
| `handoff_gro` | `napi_gro_receive` 之后 | 经 GRO 交给栈 |
| `handoff_skb` | `netif_receive_skb` / rx_list 冲刷之后 | 直接交给栈（也含 UDP 短超时回调路径） |

`ring` 行里的 `cons`/`prod`/`avail`/`leftover` 是环状态：`prod` 由 procfs
**现场读硬件寄存器** `EDMA_REG_RXDESC_PROD_IDX`，不依赖中断——即使帧到了
硬件而中断没来，`prod` 也会前进，这正是区分「帧没到 EDMA」与「中断没到
CPU」的关键。

## 输出格式

```
sbe_edma_rx_diag version=1 rings=4 rx_ring_sz=2048
netdev port=1 name=eth0
netdev port=2 name=eth1
...
ring id=20 cons=1234 prod=1402 avail=1664 leftover=0 irq=520 poll=801 reap=1402 src_valid=1398 no_ndev=0 linear_ok=1398 linear_consumed=0 scatter=0 handoff_gro=1390 handoff_skb=8 src_port_other=0
ring20 srcport 0:12 1:1390 2:0 3:0 4:0 5:0 6:0 7:0
```

`netdev port=N` 是 dp 端口索引与 netdev 名的对应；`srcport N` 的端口号是
描述符原始 PORTNUM，与 ssdk 端口号不一定同名。第一次用时先做一次标定：
让某个已知口收广播，看哪个桶在动（见下文步骤）。

## 设备侧步骤（刷机与操作均需另行批准）

前置：生产/诊断镜像刷新一律 `sysupgrade -n`（项目规则）；本机没有串口线，
取证全部经 SSH 回读。

1. 刷入 `-dpdiag` 镜像，确认 `cat /etc/banner` 版本行含
   `sbe1v1k-25.12-dpdiag-`，且 `sbe-rx-diag` 能打开 proc 文件。
2. **健康态基线**：`sbe-rx-diag reset`；主机发 300 个 UDP 广播（与
   v82-1 测试同一判据）；`sbe-rx-diag show > /tmp/rxdiag-healthy.txt`；
   同时回读 `Ip: InReceives` 增量，确认 +351 量级（判据自身有效）。
3. **标定**：从上述输出确认广播落在哪个 `srcport` 桶、哪个环。
4. **复现**：`sbe-port-roles set eth0` → `set eth1`；等 sign 固（DHCP 超时/
   同二层 ping 不通），`dmesg | grep "re-init SGMII adapter"` 应有 port 5。
5. **故障态**：`sbe-rx-diag reset`；同样 300 个广播；
   `sbe-rx-diag show > /tmp/rxdiag-fault.txt`；
   `ssdk_sh debug phycounter show 5` 确认 PHY RxGoodFrame 仍在涨（PHY 侧
   有帧的对照）。
6. **恢复对照**（可选）：`sbe-port-roles set eth0` 恢复后重做一次
   reset+广播+show，确认计数器与判据同步复活。
7. 三份输出拷回存档，随 `nstat -az`、`ip -s link`、`dmesg` 一起归档。

判据一律用「reset 后增量」，因为后台本身有 ~20/min 的背景帧。

## 判读决策树

先看健康态 vs 故障态的同字段差分，再按下面顺序定位：

1. **`reap`/`poll`/`prod` 都不动，但 PHY RxGoodFrame 在涨**
   → 帧没进 EDMA：问题在交换机/NSS 入口（CPU 端口映射、成员表到 CPU
   code、ring 选择）。下一轮埋点转 qca-ssdk / PPE。
2. **`prod` 在动、`poll` 不动**
   → 描述符到了 EDMA，但中断没送达主机（该环的 IRQ 映射/屏蔽问题）。
3. **`poll`、`reap` 在动，`src_valid` 不动**
   → 描述符源信息不是 PORTID 类型（源分类走了别的分支）。
4. **`src_valid` 在动、`no_ndev` 在涨、`handoff` 为 0**
   → 源端口→netdev 解析失败，帧在驱动内被丢（对照 `netdev port=` 行，
   看该端口号是否还在 `netdev_arr` 里）。
5. **`src_port` 桶命中、`linear_ok` 在涨、`handoff_*` 都为 0、
   `linear_consumed` 在涨**
   → 线性处理函数主动消费了 skb（驱动内丢弃，查它的返回 false 条件）。
6. **`handoff_*` 在涨、`Ip: InReceives` 仍不动**
   → 帧已交给栈，丢在交付之后：查 bridge/netfilter（`nstat -az` 的
   InDiscards/InHdrErrors、`iptables -t filter -L -v` 计数）。这一层
   与 24.10 的差异才是下一步的对比对象。
7. **两态埋点完全一致而判据不同**
   → 埋点粒度不够（丢点在 GRO 之后、bridge 之前），需要往子层加。

## 边界与风险

- 诊断镜像是**非生产**：多一个 procfs 节点与若干 atomic64 操作，性能与
  行为差异可忽略，但不得用于长期运行或作为交付件；
- procfs 读取只读；`reset` 只清零计数器，不碰硬件；
- 埋点不改变任何丢帧行为（纯计数），故障签名可对照 v82-1；
- 回退：直接刷回生产镜像即可，诊断开关默认关闭，生产构建不含上述
  补丁与工具（verify-image 双向断言保证）。

## 验证记录

| 检查点 | 状态 |
|---|---|
| 补丁对「pristine + qca-nss-dp 0001–0008」`patch -p1 --fuzz=0` 应用，结果与修改树逐字节一致 | PASS |
| `nss/install.sh` 在 `SBE_DP_DIAG=1` 下装配成功（0001–0008 后接 diag 补丁），产物与修改树 `diff -r` 逐字节相同 | PASS |
| 装配树内 `make package/qca-nss-dp/clean compile`（GCC 14.3，6.12.112）| PASS（rc=0；`.ko` 含 `edma_rx_diag` 与计数器格式串） |
| `bash -n` / `sh -n` 四个脚本与读取器、workflow YAML 解析 | PASS |
| 装配期断言（补丁标记 grep）与 verify-image 双向断言 | 已接入，CI 时生效 |
| CI 出 `-dpdiag` 产物 | PASS（run 85，Release `25.12-6.12-v85-1-29c8398e-dpdiag`，sha256 `fd9a96bf…5cabfb`） |
| 真机 | PASS（2026-11-22，见下节） |

## 真机结果（2026-11-22，v85 dpdiag 镜像）

刷机：`sysupgrade -n`，首启全新配置；管理走本机 AP → `192.168.1.1`。
取证存档：`logs/rxdiag-2026-11-21/`（gitignore），摘要
`SUMMARY-2026-11-22.md`。

三态矩阵（reset 后发 300 个 UDP 广播）：

| 状态 | PHY RxGoodFrame | EDMA prod/reap | handoff_gro | DHCP |
|---|---|---|---|---|
| 健康（eth1=WAN，切换前） | 增 | 350 | 350（srcport 5:350） | 有租约 |
| 故障（`set eth0`→`set eth1` 后） | 412 | 0（prod==cons 静止） | 0 | 无租约 |
| 恢复（`set eth0`，eth1 回 LAN） | 增 | 55（ping 6/6） | 55 | — |

**决策树第 1 支命中**：故障态帧进不了 EDMA——断点在交换机/NSS 入口，
qca-nss-dp 驱动与协议栈排除。dmesg 里 `re-init SGMII adapter` 共 3 条
（启动 1 + 回切 2），0014 的两条触发路径都执行但无效，与 v82-1 一致。

判据修正：诊断构建上 `Ip: InReceives` 对 300 广播只 +45（GRO 合并后
一次计数），精确判读用 `handoff_gro`；`ip -s link` 的 netdev 计数在
NSS offload 下恒 0，两态不可用。

下一步：在 qca-ssdk 加同层埋点（port 5 MAC 收包计数 / CPU code 路径），
区分「MAC 收到没送 CPU」与「MAC 没收到（SGMII RX FIFO）」。另记录一个新
独立问题：eth0（10G，RTL8261N）挂回 br-lan 后 RX 恒 0（已知假链路复发），
与本次缺陷无关，按方案四暂不修。

**2026-11-22 更新（已定案）**：同层埋点不需要新构建——现镜像的
`/sys/ssdk/packet_counter` 就是答案：故障态 port5 入口收到 426 帧、全部记
`STG ingress filtering drop`（dropcode 115），送 CPU 计数零增长。根因是
摘桥时的 STP DISABLED 属性把 pp5 的 `CST_STATE` 写成 0 且无人恢复；修复
补丁 `qca-nss-dp 0009` 与完整证据见 `ETH1_STP_INGRESS_DROP-2026-11-22.md`。
