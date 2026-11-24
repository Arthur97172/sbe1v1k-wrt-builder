# 内核侧修复评估：qcom-ice 后端注册与 sdhci 异步探测的竞速（修复方向 b）

- 日期：2026-11-11
- 范围：QSDK 14.0 r48（linux-6.6.147，`sources/buildroot/qca/src/linux-6.6`）中 `qcom_ice_scm` 后端注册与 `sdhci_msm` 异步 probe 的竞速；评估"内核侧修复"的可行性、风险、落点与验证方案。
- 状态词：PASS / FAIL / BLOCKED / NOT TESTED / NOT SUPPORTED / UNVERIFIED / SOURCE_UNAVAILABLE / LICENSE_REVIEW_REQUIRED。
- 本文件是工作文档，**不提交**（与 `AUDIT_REPORT-2026-10-25.md` 同）。

## 0. 阶段边界

- 未连接路由器（含 A 与 B）、未登录、未扫描、未执行任何远程命令。
- 未改动任何源码、未生成任何补丁文件、未构建、未生成镜像、未触碰设备与 p27。
- 本报告只是源码静态分析 + 对既有 v26/v27 设备日志的复核；所有设备行为结论保持原状态。

## 1. 结论摘要

| 选项 | 内容 | 结论 |
|---|---|---|
| **B1** | 把 `qcom_ice_scm_init` 的 `module_init` 改为 `subsys_initcall_sync`（保留 SCM 可用性判断） | **源码层可行（PASS）**；风险低；设备验证 **NOT TESTED**；建议先做对照实验再决定是否实施 |
| B1' | 在 B1 基础上再删掉 init 里的 ICE 能力查询（只注册，能力由首个消费者探测时打印） | 可作 B1 的备选，改动稍多，无额外收益 |
| B2 | 改 `qcom_ice_create()`：后端未注册按"ICE 不可用"处理（warn + NULL），不再 `-EPROBE_DEFER` | **NOT SUPPORTED**：全局语义退化，ICE 变成随探测时序开关，安全特性相关，不建议 |
| B3 | 只改 `sdhci_msm_ice_init()`：把 `-EPROBE_DEFER` 当作可忽略 | **NOT SUPPORTED**：与 B2 同类问题，且只修一个消费者 |
| B4 | 调 `drivers/Makefile` 链接顺序（firmware 放 mmc 前） | **NOT SUPPORTED**：sdhci 走异步 probe，链接顺序不构成确定性顺序 |
| C | 设备树删掉 eMMC 节点的 `ice` reg/clock，绕开 ICE 路径 | **NOT SUPPORTED**：生产引导以厂商 DTB 为准（v23 已实证），我们的 DTS 改不到；且属隐瞒硬件 |
| E | 关掉 `CONFIG_MMC_CRYPTO` | 可绕开竞速，但永久放弃内联加密能力，**不建议**（记录备查） |
| A | 已实施的 `/init` 限时等待 | 诊断镜像继续保留（已 **PASS**，见 `v27/REPORT-v27-2026-11-11.md`） |

**核心判断（2026-11-11 更新，对照实验已完成）**：内核侧修复本身在源码层是干净、确定性的；但"慢周期 20.4 s"是**诊断镜像的 initramfs 解压窗口**放大后的结果，生产 FIT 里没有 initramfs（实测 5.6 MB，仅 kernel+fdt）。第 0 步对照实验（v28，小 initramfs）已实测判定 **H1 成立**：同一内核、同一厂商 DTB 下，`/init` 从 ~20.3 s 前移到 **3.29 s**，`late_initcall` 类消息在 ~3.2 s。也就是说竞速在精简环境下最多只造成约 1.5 s 的枚举推迟（deferred 重试落在 late_initcall 时刻），且被现有 `/init` 的 `wait_mmc 6` 完全覆盖。**按预定标准：不实施 B1**，保留修复 (a)，把本报告的 B1 草案作为备查记录。实验细节见第 5.1 节与 `sbe1v1k-ramtest/v28/REPORT-v28-2026-11-11.md`。

## 2. 竞速的证据（复核既有日志）

`sdhci_msm` 带 `.probe_type = PROBE_PREFER_ASYNCHRONOUS`（`drivers/mmc/host/sdhci-msm.c:2931`），probe 在异步线程上与串行 initcall 流并发。probe 尾部经 `devm_of_qcom_ice_get()`（`:1921`）→ `qcom_ice_create()` 检查 ICE 后端；后端未注册时返回 `-EPROBE_DEFER`，整个 probe 被推迟到 `late_initcall`。

设备日志（`/home/arthur/sbe1v1k-ramtest/v17/inbox/`）：

| 周期 | 后端注册 `ICE: Registered backend` | sdhci ICE 检查 | mmc0 枚举 | 结果 |
|---|---|---|---|---|
| 快（13:16:43） | 1.666910 | 1.684952（probe 内联） | 1.897 | 不 defer |
| 慢（12:54:55） | 1.674124 | 20.269538（deferred 重试） | 20.449 | 首次尝试输掉竞速 |
| 慢（12:57:40） | 1.673468 | 20.259687 | 20.471 | 同上 |

- 快周期里两者只差 **约 18 ms**；慢周期的首次 probe 在 1.674 s 之前到达检查点（静默返回 defer，无日志），重试在 `late_initcall`。
- 22 轮统计：16 快 / 6 慢（约 27%），且慢周期成串出现（12:54–12:59 连续 4 轮），说明竞速受跨重启状态影响，不是独立随机。

## 3. 源码事实（r48 树）

### 3.1 注册与检查链

| 位置 | 事实 |
|---|---|
| `drivers/firmware/qcom_ice_scm.c:289` | `static int __init qcom_ice_scm_init(void)`，`:305` 为 `module_init(...)` → **device_initcall 级** |
| 同文件 `:291` | `if (!qcom_scm_is_available()) return -EPROBE_DEFER;` |
| 同文件 `:296` | `qcom_ice_ops_register(&qcom_ice_ops_scm)`；随后 `:298–301` 查询 ICE/HW key 能力并打印日志 |
| `drivers/firmware/qcom_ice_core.c:13/:30` | `qcom_ice_ops_available()` 读全局 `ops_ptr`；`qcom_ice_ops_register()` 只接受**第一个**后端 |
| `drivers/soc/qcom/ice.c:163` | `if (!qcom_ice_ops_available()) return ERR_PTR(-EPROBE_DEFER);` |
| 同文件 `:167–169` | 后端已注册但能力不可用 → `dev_info(...); return NULL;`（不阻塞 probe） |
| `drivers/mmc/host/sdhci-msm.c:1921–1932` | `devm_of_qcom_ice_get()`；只把 `-EOPNOTSUPP` 降级为"禁用内联加密"，其余错误（含 `-EPROBE_DEFER`）原样返回，导致 probe 失败并 defer |

### 3.2 顺序事实

| 位置 | 事实 |
|---|---|
| `drivers/Makefile:136` / `:141` | `mmc/` 先于 `firmware/` 链接 |
| `drivers/firmware/Makefile:25–27` | `qcom_ice_core.o` → `qcom_ice_scm.o` → `qcom_ice_tee.o` |
| `include/linux/init.h:307/:308/:312` | subsys=4，subsys_sync=4s，device=6；4s 在 4 之后、6 之前 |
| `include/asm-generic/vmlinux.lds.h` `INIT_CALLS` | 实际顺序：… 5 → 5s → rootfs → 6 → 6s → 7 → 7s |
| `drivers/base/dd.c:156/:177` | `driver_deferred_probe_enable` 为 false 时 `driver_deferred_probe_trigger()` 直接返回 |
| `drivers/base/dd.c:374` | `late_initcall(deferred_probe_initcall)` 才把它置 true（本镜像 ~20.27 s） |

结论：在 `late_initcall` 之前，任何 probe 返回 `-EPROBE_DEFER` 后都**不会被重试**。这解释了为什么慢周期整段 device_initcall 阶段都看不到 eMMC。

### 3.3 SCM 的时序（B1 成立的关键论证）

- `qcom_scm_init` 是 `subsys_initcall`（`drivers/firmware/qcom_scm.c:3680`），它注册 platform driver；SCM 平台设备由 DT 在更早的层级创建，因此 `driver_register()` 内**同步**执行 probe，probe 末尾 `smp_store_release(&__scm, scm)`（`:3581`）。
- 所有周期的后端注册都成功（`qcom_scm_is_available()` 为真，见第 2 节），说明 `__scm` 在 device_initcall 阶段（1.66 s）之前已经就绪。
- 而在这段时间里，延迟探测是被禁用的（3.2），SCM 不可能"稍后重试"才就绪；`qcom_scm_init` 也不可能晚于 subsys 级。因此到 `subsys_initcall_sync` 时 `__scm` 必然已就绪——B1 的时序前提在**本目标配置下成立**。
- 例外：若某块板子上 SCM probe 本身失败/被 defer，今天是 `module_init` 返回 `-EPROBE_DEFER`（initcall 不会重试，后端永不注册），B1 后是同一结果——失败模式不变，不是新增回归。另：若 `CONFIG_QCOM_SCM=m`，initcall 顺序故事不再适用；本配置 `=y`。

### 3.4 与主线的差异

主线的 `drivers/soc/qcom/ice.c` **没有** ops 后端层：`qcom_ice_create()` 直接检查 `qcom_scm_is_available()` / `qcom_scm_ice_available()`（`/home/arthur/linux-6.18.y/drivers/soc/qcom/ice.c:517–527`），不存在"后端注册晚于消费者"的竞速。也就是说，这个竞速是 QSDK 14 的 ops 拆分引入的**下游问题**，修复也应当落在下游，不指望上游同步。

### 3.5 本目标配置

`qca/src/linux-6.6/.config`：`CONFIG_QCOM_SCM=y`、`CONFIG_QCOM_ICE_CORE=y`、`CONFIG_QCOM_ICE_SCM=y`、`CONFIG_MMC_CRYPTO=y`；**没有** `CONFIG_QCOM_ICE_TEE`/`CONFIG_TEE`。因此：

- 只有一个 ICE 后端，B1 不会改变"谁先注册谁生效"的归属；
- `qcom_ice_tee.c` 的同类竞速在本配置不存在（若将来启用 TEE 需要同样处理）。

## 4. 候选修复逐项评估

### B1（推荐的技术方案）：`subsys_initcall_sync(qcom_ice_scm_init)`

补丁草案（对应 `build/build-fixes/0020-*.patch`，`tree` 模式、目标 `buildroot`）：

```diff
--- a/qca/src/linux-6.6/drivers/firmware/qcom_ice_scm.c
+++ b/qca/src/linux-6.6/drivers/firmware/qcom_ice_scm.c
@@ -301,5 +301,12 @@ static int __init qcom_ice_scm_init(void)
 
 	return 0;
 }
-module_init(qcom_ice_scm_init);
+
+/*
+ * sdhci_msm probes asynchronously and asks for the ICE backend from its
+ * probe.  Registering from device_initcall (same phase as the mmc driver,
+ * which is linked earlier) raced that probe: losing the race deferred the
+ * whole eMMC probe to late_initcall, when deferred probing is re-enabled.
+ * qcom_scm is a subsys_initcall and probes synchronously, so by the _sync
+ * stage __scm is already set; register here, before device_initcall.
+ */
+subsys_initcall_sync(qcom_ice_scm_init);
 
 MODULE_DESCRIPTION("Qualcomm ICE SCM Backend");
 MODULE_LICENSE("GPL");
```

- **效果**：后端在 device_initcall 阶段开始前注册；`sdhci_msm` 的异步 probe 无论何时运行，`qcom_ice_ops_available()` 都为真，不再有 defer。慢周期消失，行为确定。
- **不改**：`ice.c`、`sdhci-msm.c`、消费者语义、`-EPROBE_DEFER` 机制、日志格式（`ICE: Registered backend` 仍在，只是提前到 4s 级）。
- **风险**：init 里的两次 SCM 能力查询（`qcom_scm_ice_available()` / `qcom_scm_ice_hwkey_available()`）会提前到 subsys_sync 执行。SCM 已就绪，预期无问题，但这属于需要设备验证的点；若不放心，用 B1'（只注册、不查询）。**失败模式**：若某板 SCM 未就绪，initcall 返回 `-EPROBE_DEFER` 且永不重试，后端不注册——与今天相同，不是新增。
- **结论**：源码层 **PASS**；设备 **NOT TESTED**。

### B1'（B1 的保守变体）

```c
static int __init qcom_ice_scm_init(void)
{
	if (!qcom_scm_is_available())
		return -EPROBE_DEFER;

	qcom_ice_ops_scm.dev = NULL;
	qcom_ice_ops_register(&qcom_ice_ops_scm);
	/* 能力与"ICE 不可用"提示由首个消费者的 qcom_ice_create() 打印 */
	return 0;
}
subsys_initcall_sync(qcom_ice_scm_init);
```

- 少两次早期 SCM 调用，少一条日志；`sdhci_msm ... ICE functionality not available` 仍在 probe 时打印。
- 适合作为 B1 验证出问题时的一行回退。

### B2（不推荐）：`qcom_ice_create()` 把"后端未注册"当"ICE 不可用"

```c
if (!qcom_ice_ops_available()) {
	dev_warn(dev, "ICE backend not registered, skipping ICE initialization\n");
	return NULL;
}
```

- 效果：任何早于后端注册的消费者都会**永久**跳过 ICE（probe 不再 defer）。
- 问题：ICE 是否启用变成探测时序的抽奖；对内联加密这种安全特性，静默失效不可接受；也违背延迟探测的设计意图。即便本板 ICE 本来就不可用，代码语义仍是错的。
- **NOT SUPPORTED**。

### B3（不推荐）：只改 `sdhci_msm_ice_init()`

- 把 `-EPROBE_DEFER` 也降级为"禁用内联加密"，效果等同 B2 且只影响 eMMC。
- 同样把安全特性变成时序抽奖；且 `ufs-qcom` 消费者仍是旧行为，语义不一致。
- **NOT SUPPORTED**。

### B4（不成立）：调链接顺序

- 把 `firmware/` 移到 `mmc/` 前，只保证模块初始化函数的调用顺序；`sdhci_msm` 的 probe 在异步线程上，仍可能与后端 init 并发。不能消除竞速。
- 若同时把 sdhci 改成同步 probe，它反而**总是**输（mmc 在链接序上先注册 driver，probe 立即执行，早于 firmware 的 init）。
- **NOT SUPPORTED**。

### C（不成立）：DTS 去掉 ice reg

- `ipq9574.dtsi` 的 `sdhc_1` 带 `reg-names = "hc","cqhci","ice"` 与 `ice` 时钟；删掉后 `of_qcom_ice_get()` 直接返回 NULL，probe 不再碰 ICE。理论上可行。
- 但生产引导**以厂商 DTB 为准**（v23 实证；v27 也是厂商 DTB），我们的 DTS 改不到这条路径；且这是"隐瞒硬件"，将来 ICE 可用时还要还原。
- **NOT SUPPORTED**（对当前引导方式）。

### E（不推荐，备查）：关闭 `CONFIG_MMC_CRYPTO`

- `sdhci_msm_ice_init()` 整段不编译，竞速从根上消失；是纯配置改动、不碰内核源码。
- 代价：永久放弃 MMC 内联加密能力（虽然本板 SCM 报不可用），且改冻结配置同样要重跑审计/构建。
- 语义上不如 B1：B1 是"修顺序"，E 是"删功能"。
- **NOT SUPPORTED**。

## 5. 关键：20.4 s 不能直接当作生产代价

慢周期 eMMC 到 20.45 s 才枚举，看起来损失 18.6 s。但这是**诊断镜像**的数字：

- v15/v27 的 Image 内嵌 52,839,112 B 的 XZ initramfs（解压后 251 MB cpio），`populate_rootfs` 在 rootfs 级用 `async_schedule_domain()` 异步解压（`init/initramfs.c:580/:761`），`kernel_init` 在 `do_basic_setup()` 之后 `wait_for_initramfs()`（`init/main.c:1593`）。
- 设备日志在 1.93 s 到 18.88 s 之间有约 17 s 的静默窗口，紧接 18.88–19.44 s 的 CPR/PCIe 探测消息，然后是 20.25 s 的 `late_initcall`（SecCrypt）与 20.33 s 的 `/init`。窗口长度与 251 MB cpio 的 XZ 解压时间量级吻合。
- 生产镜像的 FIT **只含 kernel(5.54 MiB)+fdt(79 KiB)**，没有 initramfs（`mkimage -l` 实测）；恢复镜像才有 88.6 MB 的 initramfs 版本。

因此：

| 假设 | 生产慢周期的代价 | 内核修复价值 |
|---|---|---|
| H1：20 s 的 `late_initcall` 是诊断 initramfs 造成的（`do_basic_setup` 被解压窗口拖住） | 约 0.2–0.5 s（eMMC 1.9 s vs ~2.2 s） | 低，不值得内核源码增量 |
| H2：即使没有大 initramfs，device_initcall 阶段本来就 ~19 s | 约 18 s | 高，值得修 |

**2026-11-11 判定：H1 成立（PASS）**。此前日志只能证明"17 s 窗口与解压窗口重合"，因此先做了对照实验；结果见 5.1 节。生产慢周期的真实代价因此约为 1.5 s（推理值，见 5.1 节末尾的诚实边界），不是 18 s。

### 5.1 对照实验（v28）结果

镜像 `v28/openwrt-v48-v28vdtb.itb`（sha256 `bf8cdad8…`）与 v27 的唯一差别是内嵌 initramfs：251 MB cpio 换成 5.5 MB 最小 cpio（busybox + musl + 20 个网络模块）。内核、厂商 DTB、`/init` 逻辑不变。设备回读（p27 槽 229376 与 raw p40 双通道一致）：

| 证据 | v27（251 MB initramfs） | v28（5.5 MB initramfs） |
|---|---|---|
| `/init` MAGIC uptime | 20.28–20.31 s（22 轮） | **3.29 s** |
| `ICE: Registered backend` | 1.667–1.674 s | 1.667576 s |
| `sdhci_msm` ICE 检查（快周期） | 1.685–1.684 s | 1.679115 s |
| late_initcall 阶段消息（ALSA device list 等） | ~20.25 s | ~3.15–3.28 s |
| `WAITMMC` / `MMCLEVEL` | W=0/1 / 5 | W=0 / 5 |

结论：`/init` 启动时刻与 late_initcall 位置随 initramfs 大小移动 ~17 s，而 ICE 竞速双方的时刻不动（1.67 s）——20.4 s 是诊断环境造成的，H1 成立，H2 被否定。

诚实边界：

- 本轮 v28 只采到**快周期**（sdhci 赢得竞速，1.679 s 绑定）。慢周期在精简环境下的 deferred 重试时刻未直接实测，按 late_initcall 出现在 ~3.2 s 推断约为 ~3.2 s（即损失 ~1.5 s），此推断标 `UNVERIFIED`。
- 生产 FIT 无 initramfs，late_initcall 只会更早，故上述 ~1.5 s 是偏保守的上界。
- v28 的网络回传通道因 rootfs 打包缺陷（`insmod` 指向无该 applet 的 busybox，OpenWrt 实际用 `/sbin/kmodloader`）未打通，设备进入 beacon/reboot 循环；槽位转储通道按设计工作，不影响本判定。

## 6. 如果实施 B1：落点与门禁

| 项 | 改动 |
|---|---|
| 补丁 | `24.10-6.6/build/build-fixes/0020-qcom-ice-scm-register-earlier.patch`（第 4 节草案；`tree` 模式，目标 `buildroot`，应用在装配第 11 步——第 10 步内核叠加之后，故只改 `qca/src/linux-6.6/` 这一份） |
| 序列 | `build/build-fixes/SERIES` 追加一行：`0020-qcom-ice-scm-register-earlier.patch	tree	buildroot	ICE 后端在 device_initcall 前注册，消除与 sdhci 异步 probe 的竞速` |
| 审计差异 | `build/known-delta.conf` 增加：`buildroot/qca/src/linux-6.6/drivers/firmware/qcom_ice_scm.c	changed	0020：module_init 改 subsys_initcall_sync，...`；同时把 0019 条目里"内核源码树里唯一的改动"改为"0019/0020 两处" |
| 指纹 | 审计基线里 `qca/src/linux-6.6/.../qcom_ice_scm.c` 与 `target/linux/feeds/files-6.6/.../qcom_ice_scm.c` 同为 `ec0630…`；只在第 11 步改内核树后，前者 `changed`、后者不变，差异范围明确为 1 个文件 |
| 配方哈希 | `scripts/ci/recipe-hash.sh` 覆盖 `build/build-fixes` 与 `known-delta.conf`，新增补丁会改变配方哈希 → 必须重新装配、重新发布 sources、CI 重建；旧 sources 包不含此修复 |
| 审计 | 该文件从未被我们改过；改动仅一行 initcall 宏 + 注释，属于可单独复核的增量；不涉及许可变化（GPL-2.0） |

## 7. 验证方案（建议顺序）

### 第 0 步：对照实验（先做，不改内核）——已完成，判定 H1

- 已执行：v28（镜像 `v28/openwrt-v48-v28vdtb.itb`，sha256 `bf8cdad8…`），同一内核、同一厂商 DTB，仅把 251 MB cpio 换成 5.5 MB 最小 cpio。
- 结果：`MAGIC v28-small uptime=3.29`；`ICE: Registered backend` 1.667576 s；`sdhci_msm` ICE 检查 1.679115 s；late_initcall 阶段消息 ~3.15–3.28 s。对照 v27 的 ~20.3 s，**H1 成立（PASS）**，H2 被否定。
- 未直接观测到 v28 的慢周期（本轮为快周期）；慢周期在精简环境下的重试时刻按 late_initcall ~3.2 s 推断，属推理值（`UNVERIFIED`）。生产 FIT 无 initramfs，故这是保守上界。
- 副产物：v28 的 `/init` 网络回传因 rootfs 缺 `/sbin/kmodloader`（`insmod` 误指向无该 applet 的 busybox）未通，设备进入 ~70 s 一轮的 beacon/reboot 循环；不影响本判定。详见 `sbe1v1k-ramtest/v28/REPORT-v28-2026-11-11.md`。

### 第 1 步（按第 0 步结果：不执行）：实施 B1 的条件

第 0 步已判定 H1，因此第 1 步**不执行**；以下保留为 H2 情形下的备查流程。若未来出现与本次不同的证据（例如生产镜像实测 `sdhci_msm` 重试落在数秒之后），再按此执行：

- 打 0020 → 重新装配 sources（校验 fingerprint/known-delta）→ 构建内核与镜像。
- 用**未加 (a) 等待**的 v26 `/init` 做 v29，跑 ≥20 轮：成功标准 = 每轮 `sdhci_msm`/`mmc0` 都在 ~1.7 s/1.9 s（不出现 20.2 s 的重试消息），`MMCLEVEL 5`，netpush 全 OK。
- 回归检查：eMMC 分区表、p27 写入、ICE 日志（应每轮在 1.7 s 打印 `ICE functionality not available`，这是 SCM 能力判定，不是故障）。
- 生产镜像（无 initramfs，rootfs 在 eMMC）的启动时延：**NOT TESTED**，需要另一次带 rootfs 的引导。

## 8. 成本、收益与建议

- **成本**：1 个内核源文件增量（1 行 initcall + 注释）+ 审计差异登记 + 配方/sources 重发 + 完整构建与 ≥20 轮设备验证。相比 (a)，多出的是"审计过的内核源码变更"这一管理成本。
- **收益**：
  - H1 成立时约 0.2–0.5 s 启动时延（约 27% 的启动），换不来上述成本；
  - H2 成立时约 18 s，值得立刻做。
  - 另有非量化收益：消除一个"启动路径依赖异步调度时序"的隐患，行为确定。
- **结论（2026-11-11，第 0 步已执行）**：H1 成立，走第一分支——**不实施**内核补丁 B1（不新增 build-fixes/0020）。保留修复 (a)（v27 `/init` 的 `wait_mmc`）作为诊断镜像的兜底，本报告作为已知缺陷记录；B1 的补丁草案留在第 4、6 节备查。
  - 补充说明：小 initramfs 下竞速仍可能丢，代价是 `sdhci_msm` 的枚举推迟到 late_initcall（~3.2 s，损失约 1.5 s）。现有 `/init` 的 `wait_mmc 6` 已完全覆盖此窗口，日志里 `WAITMMC W=0` 表示从未真正等待过。
  - 若将来有小尺寸 initramfs 的生产用途且要求启动时延最小化，可重新评估 B1；目前无此需求。
- 无论选哪条，(a) 都不冲突；若未来启用 `CONFIG_QCOM_ICE_TEE`，需要把 `qcom_ice_tee.c` 一并评估。

## 9. 状态表

| 事项 | 状态 |
|---|---|
| 竞速根因（ops 后端注册晚于 sdhci 异步 probe） | **PASS**（源码 + 快/慢周期日志一致） |
| B1 时序前提（SCM 在 subsys_sync 前就绪，本配置） | **PASS**（源码推演 + 后端注册成功的日志旁证） |
| B1 补丁可行性（编译/语义/审计落点） | **PASS**（静态分析；未编译） |
| B1 设备效果 | **NOT TESTED**（第 0 步判定 H1 后决定不实施） |
| B2 / B3 / B4 / C / E | **NOT SUPPORTED**（理由见第 4 节） |
| H1 vs H2（小 initramfs 对照实验，v28） | **PASS**（H1 成立：`/init` 3.29 s 对 20.3 s；H2 被否定） |
| 精简环境下慢周期的竞速代价 | **UNVERIFIED**（v28 只采到快周期；按 late_initcall ~3.2 s 推断 ~1.5 s，为保守上界） |
| 生产启动时延实测 | **NOT TESTED** |
| 修复 (a) | **PASS**（v27，22 轮含 6 慢周期） |
| 上游（r50/主线）是否已修 | **UNVERIFIED**（本轮未取 r50；主线 6.18 无 ops 层，不存在同一问题） |

## 10. 依据

- 源码：`sources/buildroot/qca/src/linux-6.6` 下 `drivers/firmware/qcom_ice_scm.c`（`:289/:291/:296/:305`）、`drivers/firmware/qcom_ice_core.c`（`:13/:30`）、`drivers/soc/qcom/ice.c`（`:163/:167`）、`drivers/mmc/host/sdhci-msm.c`（`:1921/:1932/:2931`）、`drivers/base/dd.c`（`:156/:177/:374`）、`include/linux/init.h`（`:307/:308/:312`）、`include/asm-generic/vmlinux.lds.h`（`INIT_CALLS`）、`drivers/Makefile`（`:136/:141`）、`drivers/firmware/qcom_scm.c`（`:1460/:2196/:3581/:3680`）、`init/initramfs.c`（`:580/:745/:761`）、`init/main.c`（`:1593`）。
- 主线对照：`/home/arthur/linux-6.18.y/drivers/soc/qcom/ice.c:517–527`（无 ops 层）。
- 配置：`sources/buildroot/qca/src/linux-6.6/.config`（QCOM_ICE_CORE/SCM=y，无 TEE）。
- 设备日志：`sbe1v1k-ramtest/v17/inbox/131643-…bin`（快）、`125455-…bin`、`125740-…bin`（慢）。
- 生产镜像：`sources/buildroot/bin/targets/ipq95xx/generic/openwrt-ipq95xx-generic-spectrum_sbe1v1k-fit-uImage.itb`（`mkimage -l`：仅 kernel+fdt）。
- 装配/门禁：`24.10-6.6/scripts/ci/assemble-sources.sh`（步骤 10/11）、`build/build-fixes/SERIES`、`build/known-delta.conf`、`scripts/ci/recipe-hash.sh`、`build/fingerprint/audited-24.10-6.6.tsv.zst`。
- 前序报告：`sbe1v1k-ramtest/v27/REPORT-v27-2026-11-11.md`。
- 对照实验：`sbe1v1k-ramtest/v28/REPORT-v28-2026-11-11.md`、`v28/EXPERIMENT.md`（预注册标准）、`v28/p27-229376.bin`（含 `MAGIC v28-small uptime=3.29` 与 dmesg-ice 段）。
- 离线 XZ 解码复核：`sbe1v1k-ramtest/xztest/`（用内核自身 `lib/xz` 编译的 userspace 驱动，v15/v28 两版流均 PASS）。
