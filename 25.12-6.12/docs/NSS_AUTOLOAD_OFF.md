# NSS 禁自动加载与分层装载（25.12-6.12，2026-11-16）

本文记录 25.12 上 QSDK NSS 栈从「随启动自动装载」改成「按档位显式装载」的
机制、改动面、设备上的定位流程与判据。设备行为一律 `NOT TESTED`，本批只做到
本地构建输入与镜像断言。

## 1. 为什么改

25.12 镜像（v34/v39 起）在真机上启动约 55–75 秒后复位一次。已知事实：

- 复位机制是 `CONFIG_PANIC_ON_OOPS=y` + `CONFIG_PANIC_TIMEOUT=1`：一次内核
  oops 在 1 秒内变成整机复位，不是看门狗（qcom_wdt 在 25.12 板级 DTS 里是
  disabled，24.10 侧一直停在 deferred probe）；
- 风扇在 15–18 秒由满速变慢，证明 kmodloader、pwm-fan、thermal 都已完成，
  崩溃发生在 rcS 中段；
- 24.10 上同一套 QSDK 包可以工作，差异集中在 25.12 的内核（6.12.112）与
  上游化后的 NSS 时钟/PPE 路径上：
  `patches-6.12/0021`（NSSCC 驱动）、`0358`（NSSNOC 时钟挂 PM domain，
  "cause the kernel to stall if NSS is enabled and reboot with the watchdog"）、
  `0360`（NSSCC port5 时钟配置）都是为此出现的修补；
- 参照项目（ImmortalWrt SBE1V1K NSS）在同类板子上也放弃了 NSS 自动装载，
  其记录的头号故障是 `ssdk_uniphy_raw_clock_set()` 找不到 port5 时钟配置
  （`nss_cc_port5_rx_clk_src: can't find a configuration for rate ...` /
  `__clk_rcg2_select_conf`）后直接复位。我们的树已带 0360，但故障未必只在
  这一处——所以需要「逐层装载」来定位，而不是继续猜。

目标有两个，缺一不可：

1. 一个**不碰 NSS 的 25.12 启动基线**（证明 25.12 本体可启动）；
2. 一个**可远程切换、可自恢复的分层装载平台**（定位到具体一层）。

## 2. 改了什么

### 2.1 禁自动装载（Makefile）

9 个数据通路包的 `AUTOLOAD:` 全部注释掉（原来生成 `/etc/modules.d/<order>-<mod>`，
由 S10 `/etc/init.d/boot` 里的 `/sbin/kmodloader` 装载）：

| 包 | 原自动装载 |
|----|-----------|
| `qca-ssdk` | 30 `qca-ssdk`（`qca-ssdk-nohnat` 包名） |
| `qca-nss-dp` | 31 `qca-nss-dp` |
| `qca-nss-ppe` | 31 `qca-nss-ppe` |
| `qca-nss-sfe` | 09 `qca-nss-sfe` |
| `qca-nss-debug` | 30 `qca-nss-debug` |
| `qca-nss-ppe-ds` | 51 `qca-nss-ppe-ds` |
| `qca-nss-ppe-rule` | 52 `qca-nss-ppe-rule` |
| `qca-nss-ppe-vp` | 52 `qca-nss-ppe-vp` |
| `qca-nss-ae-clients` | 52 ×6：`ppe-bridge-mgr` / `ppe-vlan` / `ppe-pppoe-mgr` / `ppe-lag` / `ppe-dsa-mgr` / `ppe-ath-clients` |

`qca-nss-phy` 的 7 条 AUTOLOAD（`qca-nss-phy`、`qca8084-phy`、`qcom-lnx-phy`、
`qca8xxx-phc`、`qca8k-cc`、`mdio-ipq4019`、macsec）**保留**：PHY 驱动属于硬件
基础设施，与 NSS 加速栈无关，去掉它连 PHY 都不会初始化。

### 2.2 禁自动启动（init 脚本）

五个脚本的 `START=` 移除（`rc.common` 的 `enable` 只在 START 存在时建 S 链接，
所以移除即等于「装进镜像但不随启动运行」）：

| 脚本 | 原 START |
|------|---------|
| `/etc/init.d/qca-ssdk` | 16 |
| `/etc/init.d/qca-nss-dp` | 18 |
| `/etc/init.d/qca-nss-ppe-bridge-mgr` | 19 |
| `/etc/init.d/qca-nss-ecm` | 26 |
| `/etc/init.d/shortcut-fe` | 72 |

脚本自带的等待循环与取证（`WAIT_TIMEOUT`、`events.log`）原样保留，只是不再在
启动时被调用。

顺带修了 `qca-nss-dp.init` 的一个既有缺陷：`start()` 调用的 `uci_get` 只在
source 过 `/lib/functions.sh` 的进程里存在，init 脚本没有 source 它，原实现
每次启动都会打 `uci_get: not found` 与 `[ ... -eq 1 ]: out of range` 两条
错误。现改为 `uci -q get qca_nss_dp.@general[0].enable_rps`，缺省仍按 1
（与包里安装的 `/etc/config/qca_nss_dp` 一致）。

### 2.3 档位控制器（overlay）

| 文件 | 作用 |
|------|------|
| `/etc/nss.conf` | `tier=` 档位、`fallback=` 回退档、`budget=` 连续失败预算 |
| `/usr/sbin/nss-load` | 分层装载器：`status` / `load` / `boot` / `commit` / `tier` / `stop` |
| `/etc/init.d/nss` | S15 启动控制器，`start()` 调 `nss-load boot` |
| `/etc/rc.d/S15nss` | → `../init.d/nss`（overlay 直接带符号链接；镜像装配时
  `prepare_rootfs` 也会对带 START 的脚本再 `enable` 一次，两条路都指向同一链接） |

S15 的位置：在 `/etc/init.d/boot`（S10，加载 PHY 等基础模块）之后、netifd
（S20）之前，与原来 ssdk(16)/dp(18) 的窗口一致。有线接口必须在此之前由
`qca-nss-dp` 注册，netifd 才能在 S20 认领。

## 3. 档位与装载顺序

| 档位 | 装载 | 说明 |
|------|------|------|
| `off` | 无 | 纯基线。没有以太网口，改回只能恢复模式/离线挂 overlay |
| `wired` | `sdk` + `dp` | 默认。恢复有线管理与 SSH |
| `full` | `wired` + `ppe` + `ecm` | 完整加速栈 |

单层命令：`load sdk|dp|ppe|ecm|sfe`。

每一层做什么：

- `sdk`：`modprobe qca-ssdk`，然后最多等 10 秒 `/sys/ssdk` 出现（SSDK 初始化
  完成的标志）。不调用 `/etc/init.d/qca-ssdk`：它的 WAR 代码全被注释，读
  chip id 用的 `ssdk_sh` 本镜像也没装，调它只有噪声；脚本仍留在镜像里可手工
  执行；
- `dp`：先显式 `modprobe qca-nss-ppe`，再 `modprobe qca-nss-dp` —— 本镜像里
  `qca-nss-dp` 的 modinfo 是 `depends=qca-ssdk,qca-nss-ppe`（dp 引用
  `ppe_drv_*`，见 README 的 `DEPENDS` 说明），所以 **`wired` 档实际也会拉起
  `qca-nss-ppe.ko` 本体**；显式分两步只是为了让事件日志能区分 ppe probe 与
  dp probe。之后 `/etc/init.d/qca-nss-dp start` 按
  `/etc/config/qca_nss_dp` 的 `enable_rps`（默认 1）配置 EDMA RPS；
- `ppe`：依次 `modprobe qca-nss-ppe`、`-ds`、`-vp`、`-rule`、`-vlan`、
  `-bridge-mgr`、`-ath-clients`（镜像里不存在的直接 SKIP），然后
  `qca-nss-ppe-bridge-mgr start` 与 `qca-nss-ppe-ds start`（后者只做 PPEDS
  的 IRQ affinity，历史上从未随启动跑过）；
- `ecm`：`/etc/init.d/qca-nss-ecm start`（它自己会补 `modprobe qca-nss-ppe`、
  按 `/etc/config/ecm` 的 `acceleration_engine` 选前端；`qca-nss-sfe.ko`
  存在时也会被它 `insmod`，这是 QSDK 原行为）；
- `sfe`：`modprobe qca-nss-sfe` + `/etc/init.d/shortcut-fe start`
  （shortcut-fe-cm 只在没有 ECM 时装载）。

每次装载都向 `/sbe-boot-trace/events.log` 写：

```
nss-load: stage ppe: begin (uptime 31.24)
nss-load:   modprobe qca-nss-ppe
nss-load:   qca-nss-ppe loaded
...
nss-load: stage ppe: done
```

崩溃时 overlay 里 events.log 的最后一个 `stage ...: begin` 就是嫌疑层。
这个文件在 24.10 的多次排障中已被证明能在复位后保留（`/sbe-boot-trace` 在
overlay 根上）。

## 4. 启动计数器与自恢复

- `/sbe-boot-trace/nss-boots`：每次启动 +1（`/sbe-boot-trace` 不可写时退到
  `/tmp`，重启即失效，防呆不生效）；
- 启动成功后控制器挂一个 `sleep 300; nss-load commit` 的子进程；300 秒没
  崩溃 → 计数器清零并写 `commit: tier=... survived`；
- 连续 `budget`（默认 3）次启动都没等到 commit → 本次启动改用
  `fallback` 档（默认 `wired`），并写 `boot #N exceeds budget`。

注意这只能防「上层档位（ppe/ecm/full）出问题」；如果 `wired` 本身崩，设备
仍然复位循环，只能恢复模式（Reset + TFTP + RAM 系统 `sysupgrade -F -n`）。

## 5. 设备上的定位流程（需用户批准后执行）

前提：已用 `nconfig`/恢复模式把镜像刷进 eMMC（24.10 的
`guide/README.md` TFTP + do_boot + sysupgrade 流程同样适用于 25.12 镜像）。

1. 默认 `wired` 启动一次。能起 → 问题在 `ppe`/`ecm`；起不来 → 看
   `/sbe-boot-trace/events.log` 最后的 stage（sdk 或 dp）。
2. 起得来时（SSH 可用）：

   ```sh
   nss-load status
   nss-load load ppe     # 如果 20 秒内复位，ppe 层就是嫌疑
   nss-load load ecm     # 再试 ECM
   nss-load tier full    # 改档位长期测试；fallback=wired 会兜底
   ```

3. 崩溃后重新起来，第一步先读证据再继续：

   ```sh
   cat /sbe-boot-trace/events.log | tail -80
   dmesg | tail -60
   ```

重点 grep 的判据（来自参照项目与我们的内核补丁）：

| 线索 | 含义 |
|------|------|
| `ssdk_uniphy_raw_clock_set` | ssdk 配置 uniphy/port5 时钟 |
| `can't find a configuration for rate` | NSSCC 找不到对应速率配置（0360 覆盖的路径） |
| `__clk_rcg2_select_conf` / WARNING 调用栈 | 同上，时钟框架告警 |
| `ppe_drv_remove` | PPE 卸载路径 oops（我们不做 rmmod，正常不会出现） |
| `qca_nss_dp` 相关 `-EINVAL` | dp/EDMA 注册失败（24.10 的 DTS edma 缺 ring-map 曾如此） |
| `nss@40000000` / 保留区相关 | NSS 固件窗口被当普通内存（0027 已处理） |

## 6. 断言与回归防线

- `scripts/ci/prepare-tree.sh`：9 个包不得有生效的 `AUTOLOAD:`、
  五个脚本不得有 `START=`、`qca-nss-phy` 的 AUTOLOAD 必须在、控制器三件套
  必须存在；
- `scripts/ci/verify-image.sh`：镜像内 `/usr/sbin/nss-load` 可执行、
  `/etc/nss.conf` 带 `tier=`、`/etc/rc.d/S15nss` 指向正确、数据通路模块没有
  `modules.d` 条目与 rc.d 启动链接、PHY 自动装载仍在。

## 7. 风险与不做的事

- **不做 rmmod**：`nss-load stop` 只停 ECM/SFE。QSDK 的 `ppe_drv_remove()`
  卸载路径在参照项目上出过 oops，回退一律 reboot。
- **`tier=off` 会把设备变成无网设备**（只剩恢复模式），改之前先想好退路；
  保留 `fallback=wired` 且不要把它也改成 `off`。
- **ECM 默认 `acceleration_engine 'auto'`**：走 QSDK 的自动前端选择。要强制
  NSS 前端需改 `/etc/config/ecm`，本批不动。
- 真机行为全部 `NOT TESTED`；本文的判据是下一次刷机的观察清单，不是结论。
