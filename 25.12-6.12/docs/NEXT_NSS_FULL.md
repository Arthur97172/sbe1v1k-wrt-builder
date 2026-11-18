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
