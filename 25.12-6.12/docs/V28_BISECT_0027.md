# v28：去掉 0027 的对照构建

日期：2026-11-15
目的：判定补丁 0027（CPU OPP 删表 / `sleep_clk` 去 32 kHz / NSS 32 MiB
no-map 保留区）是否为 v25/v26 到不了用户态的回归源。

## 1. 实验设计

| 版本 | 相对 v26 的代码差异 | 现场结果 |
|---|---|---|
| v24 | **没有 0027**（其余相同） | 起不来；LAN 无 DHCP（链路曾有 carrier） |
| v25 / v26 | 有 0027 | 起不来；现场取证：overlay 尾部 ext4 只有刷机脚本那一次挂载，从未被启动使用（见 `V26_RECOVERY_DIAG_2026-11-15.md` §2.1，2026-11-15 修订） |

`git diff` 已确认 25.12 的代码从 v24 到 v26 只多了 0027 一个补丁（另一处差异是
文档）。因此 v28 = 把 0027 移到 `patches/disabled/` 后重新构建：**内核与设备树
回到 v24 的形态**，只用来做 A/B 对照。

注意一个容易误读的旧记录：v24 的"有 carrier"来自内核里 `nss-dp`/PHY 的链路
状态，**不代表用户态跑过**。所以 v24 的现象与"内核起来了但死在用户态之前"
并不矛盾，v28 预期与 v24 同类（很可能同样没有 DHCP）。

判据不靠串口（当前没有串口线），只靠刷机后从恢复系统只读取证：

- **尾部 ext4 的使用痕迹**：25.12 的 overlay 在 `mmcblk0p27` 尾部（偏移 =
  squashfs `bytes_used` 向上取整到 64 KiB，超级块再 +1024）。读三样东西，
  单看 `s_mnt_count` 会误判——它的基线由"谁刷的机"决定：本板 `mmc.sh` 在
  刷写时就 mkfs 并 rw 挂载一次 `/tmp/new_root`，所以从 v78 刷入的镜像
  **刷完基线就是 1**。
  1. `s_mnt_count` 是否超过基线（刷机基线 1 → 启动再挂一次应为 2）；
  2. `s_last_mounted` 是否非空（它只在该文件系统第一次打开文件时写）；
  3. `e2fsck -fn` 的 inode 用量：刚 mkfs 完是 12/13440，被启动写过必然更多。

  三项都"没有增量"才说明**系统没到过 preinit 的 mount_root**。方法学在 v78
  （24.10，从恢复系统 `-n` 刷入，基线 0）上做过阳性对照：`s_mnt_count = 1`、
  `s_last_mounted = "/"`，见 `docs/V26_RECOVERY_DIAG_2026-11-15.md` §8。
- 风扇档位与灯态（辅助，主观）：`pwm-fan` 是模块，由用户态加载，风扇降速
  意味着用户态跑到了 init.d 阶段。
- LAN 是否发 DHCP（最直观，但取决于是否已经到用户态）。

## 2. 镜像形态断言（本次已改为自动切换）

`patches/disabled/README.md` 说明了停用机制。停用 0027 时：

- `scripts/ci/prepare-tree.sh`：断言板级 DTS **保留** CPU
  `operating-points-v2`、`sleep-clk` **带** `clock-frequency`、**没有**
  `nss@40000000`；不满足即编译前失败（防止镜像悄悄不是对照形态）。
- `scripts/ci/verify-image.sh`：反编译交付镜像里的 DTB 做同样三项反向断言。
- 恢复 0027 只需把补丁文件移回 `patches/`，两处断言会自动切回"修复形态"。

## 3. 判读表与实测结果

### 3.1 判据（2026-11-15 修订）

最初写的判据是"`s_mnt_count ≥ 1` ⇒ 到过用户态"，这是错的：v28 是从 v78 里刷
的，板级 `mmc.sh` 在刷写时就 mkfs 并 rw 挂载一次 `/tmp/new_root`，所以**刷完
基线就是 1**。正确判据是 §1 的三项组合：

| 尾部 ext4 读数 | 结论 | 下一步 |
|---|---|---|
| 计数超过基线，或 `s_last_mounted` 非空，或 inode 用量多于 mkfs 缺省 | v28 到过用户态 ⇒ **0027 是回归源** | 在 0027 内部逐项 bisect：先只保留 CPU OPP 删表，再单独加 sleep_clk / NSS 保留区；24.10 的先验是最可能由 CPU OPP 引起（v52–v54 静默死亡） |
| 三项都无增量 | 0027 不是（唯一）根因 | 排除法继续：检查 25.12 用户态入口（procd/preinit）与内核 6.12 的其它差异；考虑把"内核活到哪"可视化（LED heartbeat / RAM-boot 对照） |

两种结果都只影响 25.12 分支，不影响正在使用的 24.10 v78。

### 3.2 实测（2026-11-15 09:22 UTC，如实记录）

v28 由用户在 v78 里刷入，刷机时刻 2026-11-15 08:49:42 UTC（= 尾部 ext4 的
mkfs 时间）。从恢复系统（官方快照 RAM 系统，6.18.60）只读取证：

| 项 | 读数 | 判读 |
|---|---|---|
| 尾部 ext4 超级块（偏移 = squashfs `bytes_used` 64 KiB 对齐 + 1024） | `0xEF53`，卷标 `rootfs_data` | 位置正确 |
| `s_mtime`/`s_wtime`/`s_lastcheck` | 均为 2026-11-15 08:49:42 UTC | = 刷机时刻 |
| `s_mnt_count` | 1 | = **刷机脚本自己那一次**，无启动增量（到过用户态应为 2） |
| `s_last_mounted` | 空串 | 该文件系统上从未打开过任何文件 |
| `e2fsck -fn` | `rootfs_data: 12/13440 files (0.0% non-contiguous), 8549/53824 blocks`，状态 clean | 与刚 mkfs 的空文件系统逐项相同 |
| 对照：同几何下刚 `mkfs.ext4` 的空 fs | 12 个 inode 已用 | 基线确认 |

结论：**v28 与 v26 的现场形态完全相同——内核/init 在 preinit 建立 overlay
之前就停住了。补丁 0027 不是回归源，排除。**

这意味着 v24/v25/v26/v28 四版的行为在"到不了用户态"这一点上没有区别；差异
只在更早的内核阶段，且与 0027 无关。（v24"有 carrier"只是内核 netdev/PHY 的
链路状态，不代表用户态。）下一步应转向 6.12 内核与板级 DTB 本身，与官方
快照（6.18.60 + 上游风格 DTB）在本机可启动形成对照，见 §6。

## 4. 刷机与取证步骤（2026-11-15 已执行，保留作记录）

走的是"在 v78 内直接刷"的路径（不是从恢复系统）：用户用 LuCI/sysupgrade 刷入
发布产物，机器重启后起不来；随后断电 + 按住 Reset 进官方快照 RAM 恢复系统，
在 192.168.1.1 上只读取证。取证前先把闪存内容与发布产物逐字节核对：

| 核对项 | 结果 |
|---|---|
| p25 前 5 811 720 B SHA-256 | `9952d3e2…` = 发布 tar 的 `kernel` 成员 |
| p27 前 72 810 496 B SHA-256 | `3cd7070c…` = 发布 tar 的 `root` 成员 |
| p25 FIT | Linux 6.12.112 gzip，load/entry 0x42200000，fdt-1 45 401 B，config@rdp433 |
| 对照 24.10 FIT | 6.6.147 gzip，load/entry 0x42000000，fdt 81 209 B，config-1 |

⇒ 闪存是发布产物的逐字节副本，故障在镜像/内核本身，不在写盘。

## 5. 状态词

- 构建：PASS（CI run 43688616764，`v31-1-dd425103-25.12-6.12`）。
- 刷机：PASS（p25/p27 与发布产物逐字节一致，见 §4）。
- 设备行为：v28 启动失败，FAIL。
- 回归源判定：补丁 0027 已排除（§3.2）。

## 6. 下一步候选（均需你单独批准；本报告没有执行其中任何一项）

按"能回答什么问题"排序，而不是按成本：

1. **让 APPSBL 直接引导我们自己的内核（最便宜，不用新建镜像）**：恢复模式的
   APPSBL 固定从 TFTP 拉两个文件名——`rtq7300t_boot_auto_upgrade_fw.img` 和
   `initramfs.itb`。把 v28 发布 tar 里的 `kernel` 成员（就是 p25 那个 FIT，
   6.12.112 + 板级 DTB，load 0x42200000）原样改名为 `initramfs.itb` 放上
   TFTP，按住 Reset 上电即可。APPSBL 的 bootargs 仍是
   `root=/dev/mmcblk0p27`，所以这相当于**绕过 QSDK 二阶段 chainloader、直接
   用 APPSBL 的 bootm 起我们的内核 + 我们的根文件系统**。
   - 若能在 192.168.1.1 起来 ⇒ 内核/DTB/根文件系统都健康，问题在 chainloader
     这条路径上（它此前只用 24.10 的 FIT 验证过，从没喂过 25.12 的 FIT）；
   - 若同样起不来 ⇒ 故障在内核/DTB 本身，与 chainloader、与 rootfs 无关。
   - 全程只读 TFTP、不写 eMMC；失败后断电重启即回到当前状态。
2. **RAM 引导 25.12 自己的真 initramfs（更彻底，需要构建侧改动）**：把
   `sbe1v1k-initramfs-fit-uImage.itb`（现约 22 MB，低于 APPSBL TFTP 的
   32 MiB 上限）产出并作为第 4 个发布资产（现有"恰好 3 个资产"的断言要同步
   改）。它能给出"没有 eMMC 也能到用户态"的基线。
   - 若 6.12 内核 + 我们 DTB + 真 initramfs 能起来，而 eMMC 路径不起来 ⇒
     故障在 rootfs/preinit 一侧；
   - 若起不来 ⇒ 故障在内核/DTB，回头对照官方 6.18.60 快照的 DTB 逐节点查
     （串口、spi、usb、leds、rng 的 status/compatible 差异已在静态比对里列出）。
3. **LED heartbeat 诊断构建**：给 `led-0`（GPIO 64）加
   `linux,default-trigger = "heartbeat"`，用灯态把"内核活到驱动注册"可视化。
   仍要刷 eMMC。
4. **内核早期可见化**：DTB `chosen/bootargs-append` 加 `earlycon`/`initcall_debug`
   无串口时价值有限，除非同时上 PSTORE_BLK（GPT 里有 128 MiB `log` 分区可用）。
5. **对照官方快照 DTB**：把官方 6.18.60 快照 DTB 里的 ethernet/uniphy 节点
   与我们的 NSS 栈（dp1–dp4/edma/ess-instance/nss-ppe）在 6.12 下的兼容性
   重新审一遍——静态比对已完成，结论是"结构差异大但都在 probe 阶段才生效"，
   若 §6.1 指向内核，这条才值得动。

## 7. v29：按官方 6.18 DTB 补齐 eMMC 核心复位（2026-11-15）

§3.2 把 0027 排除之后，最有信息的线索来自官方快照本身：它的 FIT 描述是
`ARM64 OpenWrt askey_sbe1v1k device tree blob`、DTB 里 `model = "Askey SBE1V1K"`，
即**上游 trunk 的构建**，并且在本机完整运行（恢复通道就是它）。把它的 DTB 与
v28 的 DTB 在 `mmc@7804000` 节点上逐属性对齐，**只差一条
`resets = <&gcc 0x25>`**（6.12 的 `reset/qcom,ipq9574-gcc.h`：
`GCC_SDCC_BCR = 37`）。

6.12 的 `sdhci_msm_gcc_reset()` 用 `reset_control_get_optional_exclusive()` 取
这条复位，DTB 里没有就静默跳过，控制器沿用引导器留下的状态；24.10 的 6.6 树
同样没有 resets，但它有 `assigned-clocks = <&gcc GCC_SDCC1_ICE_CORE_CLK>` /
300 MHz。两个实测能跑的配置各带一种时钟/复位初始化，25.12 到这里为止两样都
没有；探针的现场表现（内核到用户态，碰 eMMC 后死锁、写从未落盘）与之相符。

v29 = v26 形态（0027 启用）+ `patches/0028` 这一条，相对 v26 只多这一个变量。
`prepare-tree.sh` 与 `verify-image.sh` 各加一条断言，补丁被静默丢弃时编译前
就失败。判据仍是 §1 的尾部 ext4 三项。

**状态：构建与断言本地 PASS；真机 NOT TESTED。**
