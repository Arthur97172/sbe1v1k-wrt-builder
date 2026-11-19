# 下一步验证：NSS full 档常开（2026-11-18 立项）

> 状态：**NOT TESTED**。本文是验证计划与判据，设备行为等真机跑完再回填。
> 关联：`README.md` 的「档位」表、`docs/NSS_AUTOLOAD_OFF.md`（分层装载机制）、
> `docs/DIAG_RUN_2026-11-16.md` §27–29（register_sysctl 哨兵根因与 v22 修复）、
> 记忆条目 `nss-ecm-sfe-manual-load-order`（装载顺序约束）。

## 1. 目标

把生产默认档从 `tier=wired` 提升为 **`tier=full` 常开**：每次启动由 S15
`/etc/init.d/nss` → `nss-load boot` 自动装载完整加速栈（sdk + dp + ppe 全家 +
ecm），不需要任何人工 `nss-load`，并作为后续生产的默认形态。

`full` 常开之后，有线转发与无线桥接应走 QCA NSS 硬件加速（ECM 连接表有计数、
CPU 占用下降），而不是只在特例下手工挂。

## 2. 现状与已知约束

- 当前生产镜像默认 `tier=wired`：只装 `qca-ssdk` + `qca-nss-dp`（dp 连带
  `qca-nss-ppe`），`ecm` 与 `qca-nss-sfe` 不装。B 机现网即此形态。
- `full` 在 25.12 上曾因 6.11+ `register_sysctl()` 哨兵问题在
  `modprobe qca-nss-ppe` 的拆除路径 oops（`CONFIG_PANIC_ON_OOPS` 下一秒复位）。
  该根因已由 `nss/patches/qca-nss-ppe/0025-*`、`qca-nss-dp/0008-*` 修复，
  但**修复后 full 档没有做过真机验证**——wired 档 v22 起 PASS 只证明了修复
  让 wired 稳定，ECM/SFE 这一段仍是空白。
- 装载顺序约束：`qca-nss-ppe-rule` 必须先于 `qca-nss-sfe` / ECM 装载，否则
  `ppe_rfs` 符号缺失。`nss-load load full` 的 stage 顺序（sdk → dp → ppe →
  ecm）已满足 ppe 全家先于 ecm；若后续把 sfe 纳入 full，`stage_sfe` 必须排在
  `stage_ecm` 之后或保持显式手工顺序，并单独验证。
- `nss-load` 不做 `rmmod qca-nss-ppe/-dp/-ssdk`（QSDK 卸载路径出过 oops），
  回退一律 reboot。
- 防锁死机制已在：启动计数器 `budget=3`，连续 3 次没等到 `nss-load commit`
  自动降回 `fallback=wired`。full 档验证期间保持 `fallback=wired` 不变。

## 3. 验证步骤（真机，B 机 192.168.1.1）

按顺序做，前一步 FAIL 就停在原地取证，不带病推进：

1. **在线试装（不重启）**：wired 运行状态下执行 `nss-load load full`，
   观察 `events.log` 每个 stage、`dmesg` 有无 oops/WARN、`/sys/kernel/debug/ecm`
   是否出现、`nss-load status` 的模块表（ppe 全家 + ecm 应为 loaded）。
   此步只验证装载路径，不验证启动时序。
2. **切换档位重启**：`nss-load tier full`（保持 `fallback=wired`）→ reboot。
   启动后确认 S15 自动装载、300 秒后 `nss-load commit` 清零计数器（不等
   commit 就说明中途复位或崩溃）。
3. **功能判据**：
   - `nss-load status`：tier=full、ppe 全家与 ecm loaded、`/sys/kernel/debug/ecm`
     present；
   - 加速生效证据：ECM 连接表计数随流量增长（`/sys/kernel/debug/ecm/`），
     同流量下 CPU 占用低于 wired 基线；
   - 回归：WAN DHCP 与上网、br-lan（eth0/eth2/eth3 + 三 AP）桥接、三频 AP
     正常，`ping 8.8.8.8` 0% 丢包；
   - `dmesg` 无新增 oops/WARN（既有 `__reset_control_get_internal` 3 条
     WARNING 是已知项，不计入）。
4. **稳定性**：连续 3 次重启（至少一次断电冷启）每次都等到 commit；随后
   运行 24 h 复查 uptime 与 `nss-boots` 计数，确认没有后台复位循环。
5. **升为生产默认**（仅在 1–4 全 PASS 后）：把 `files/etc/nss.conf` 的
   `tier=wired` 改为 `tier=full`，重编镜像；`verify-image.sh`/README 档位表
   同步更新；真机结果回填本文与 `PROD_RUN_2026-11-18.md` 同期的生产记录。

## 3.1 真机取证：第 1 步（2026-11-19，B 机，镜像 25.12-6.12 run-56）

在 wired 档运行状态下执行 `nss-load load full`，stage 结果：

- sdk / dp：PASS（已在跑）；
- ppe：**FAIL**。`qca-nss-ppe-ds / -vp / -rule` 装载成功，
  `qca-nss-ppe-vlan` 与 `qca-nss-ppe-bridge-mgr` 拒绝装载，dmesg：

  ```
  sysctl table check failed: ppe/vlan_client/(null) procname is null
  sysctl table check failed: ppe/vlan_client/(null) No proc_handler
  ```

  根因与 ppe/0025 同源：6.11+ `register_sysctl()` 把表尾 `{}` 哨兵计入
  条目数，校验失败返回 NULL，而 vlan/bridge 管理器把注册失败当致命错误。
  新增 `nss/patches/qca-nss-ae-clients/0002-sysctl-register-sz-6.12.patch`。
- ecm：模块装载成功，但前端 sysctl 树同样因哨兵注册失败
  （`net/ecm/(null)`），`ecm_sfe_sysctl_tbl_init()` 被跳过。新增
  `nss/patches/qca-nss-ecm/0003-sysctl-register-sz-6.12.patch`。

热插补丁模块验证：把两处修复后编译的 `qca-nss-ppe-vlan.ko`、
`qca-nss-ppe-bridge-mgr.ko` 直接放到 `/lib/modules/6.12.112/` 再装载，
两个模块均 rc=0，`/proc/sys/ppe/{vlan_client,bridge_mgr}` 出现，无新增
oops → 补丁有效。

另一现象：ECM 在 uptime ≈444 s 才装载，此前 br-lan 与三张无线口早已
就绪，`ecm_db/iface_count` 始终为 0（ECM 没接到任何接口事件），
连接表不动。这属于「装载时机晚于接口创建」的测试态问题，判断真实行为
必须走第 2 步（开机时序装载）。

## 3.2 真机取证：第 2 步（2026-11-19，开机时序装载）

把两处修复后编译的模块放进设备 `/lib/modules/6.12.112/`（overlay 暂存，
原版备份在 `/overlay/ko-backup-*.ko`），`nss-load tier full` 后重启：

- S15 启动装载：sdk → dp → ppe 全家 → ecm，全部 PASS
  （`boot #1: tier full loaded`），无 sysctl 哨兵报错；
- `/proc/sys/net/ecm/` 全树出现（前端 sysctl 修复生效）；
- 300 s 后 `nss-load commit` 清零启动计数器（`nss-boots=0`），期间无复位；
- dmesg 只剩两类 WARN：3 条 `__reset_control_get_internal`（已知项）与
  1 条 `nf_conntrack_register_notifier`（`WARN_ON_ONCE` 后仍覆盖注册，
  ECM 后续能收到 conntrack 事件，见下）。

ECM 数据库：空闲时全 0；经 B 转发的 LAN→WAN 流量（netns 客户端走 B 路由）
之后 `connection_count` / `iface_count` / `host_count` / `mapping_count` /
`node_count` 均 > 0，证明 ECM 事件路径与数据库工作正常。

**加速生效**：打开 `net.ecm.udp_classification_enabled=1` 后，从 netns
发起的 UDP DNS 流经 B 转发时出现
`ecm_ppe_ipv4/accelerated_count=1`、`udp_accelerated_count=1`，
PPE `common_stats` 的 `v4_l3_flows` 同步 +2——ECM 的加速命令确实下发到了
PPE，硬件加速通路可用。

TCP 流没有触发加速（`tcp_accelerated_count=0`），原因未定论：本机到
公网的所有路径都被 ISP fake-IP 代理接管，无法构造持续的经 B 转发大流量，
短连接可能因为包数不够被 `ready_for_accel` 延迟掉。留待真实使用场景
观察（判据仍是 `tcp_accelerated_count` 随上网流量增长）。

`udp_classification_enabled` 默认 0（UCI 树里没有对应持久化项）。若要
常开 UDP 加速，需在 ECM init 里加一行 sysctl 或 UCI 选项，属后续小改动，
本轮不动。

## 4. 判据（PASS / FAIL）

- **PASS**：full 档自动装载成功；ECM 表有计数且 CPU 占用下降；有线/无线全部
  功能无回归；连续重启无复位、24 h 无 oops；镜像层断言（模块、nss.conf）一致。
- **FAIL**：任一 stage FAIL、启动复位、ECM 不出表、或功能/吞吐回归。
  FAIL 时保留 `fallback=wired`（默认已配），取证后按阶段提交（stage 日志 +
  dmesg 尾部）写回本文，再决定下一轮。

## 5. 与当前构建的关系

本项是**设备验证任务**，当前代码不需要为此改动：`nss-load`、`nss.conf`
的分层机制与 full 档定义（sdk/dp/ppe/ecm）已经在树里；只有第 5 步「升为
生产默认」才会改 `files/etc/nss.conf`。验证用的镜像可以用现有 CI 产物，
`nss-load load full` 也可以在现网镜像上直接跑（不重启即可回退）。
