# 25.12-6.12 v26 在 B 机上无法启动：恢复模式诊断结论

日期：2026-11-15
对象：B 机刷入的 `v26-1-1b3bb2fc-25.12-6.12`
（`openwrt-ipq95xx-generic-spectrum_sbe1v1k-squashfs-sysupgrade.bin`，Linux 6.12.112）
性质：RAM 恢复系统上的**只读**取证 + 本机（qemu-aarch64）仿真。
**本次没有向闪存写入任何字节，也没有修改设备状态**；所有设备侧读数都是读命令。

前置背景：`V25_BOOT_ANALYSIS_2026-11-15.md`（v25 静态审计）。本文补上 v26 的现场
取证，并用本地仿真把"用户态是否健康"这一问题从假设变成结论。

---

## 0. 结论先行

1. **v26 与 v25 是同一份 25.12 代码。** `git diff f0f9df7 1b3bb2f -- 25.12-6.12`
   只多出 v25 审计文档本身；其它差异全在 24.10 目录。两条 CI 产物理论上应同
   行为。
2. **镜像本身完好**：FIT、gzip 内核（UTS 6.12.112，与 `/lib/modules/6.12.112`
   逐字匹配）、板级 DTB（含 `bootargs-append = " fstools_ignore_partname=1"`）、
   模块树（ext4/jbd2/mbcache 均在）全部核对通过。
3. **决定性现场证据（本次首次拿到）：p27 尾部 ext4 自刷机时刻起从未被读写挂载。**
   - 尾部 ext4 的位置 = squashfs `bytes_used` 向上取整到 64 KiB =
     **72 810 496**（字节），用 fstools 自己的算法核算一致；
   - 其超级块 `s_mtime == s_wtime == s_lastcheck = 2026-11-15 06:01:38 UTC`
     （即这次刷机时的 mkfs 时刻），`s_last_mounted` 为空，`s_mnt_count = 0`；
   - ext4 源码里 rw 挂载本身就会写超级块（`ext4_fill_super()` 递增
     `s_mnt_count`、更新 `s_mtime` 后 `ext4_commit_super()`），所以"挂过"必然
     留痕。
   - 另一条旁证：GPT 的 `p29 rootfs_data` 分区前 2 MiB 全零——说明**也没有**
     任何一次启动走到"按分区名格式化 rootfs_data"的路径。
   - ⇒ **每一次 v26 启动都没有完成 preinit 里的 overlay 建立。**
4. **本地仿真证明 25.12 用户态的这条链路是健康的。** 用真机 dump 的 p27 前段 +
   镜像自带的 `/sbin/mount_root`（fstools 2026.05.23）在 qemu-aarch64 里复现：
   - `mount_root start ""`（PREINIT=1）**exit 0**，尾部 ext4 被正确找到并 rw
     挂载（`mnt_count` 0→1，`Last mounted on: /`）；
   - 完整跑 `/etc/preinit` 全链（含 80_mount_root、82_config_generate），输出
     `- generating board file -`，overlay 里实际写入了约 5.3 MiB 数据。
5. 两条结论合起来：**故障在内核在 init 之前**（或 init 本身没被启动），
   而不是"起来了但网口/配置有问题"。§4 逐条对照了旧假设（H1/H3 被否定）。
6. 唯一与"内核没起来"冲突的间接证据是 v25 的"风扇不满速"（本文 §4.3）。
   v26 的风扇行为**从未被直接观察记录**。下一步的首要动作是零成本观察实验，
   其次是串口（§5）。

---

## 1. 本次恢复模式检查做了什么（全部只读）

B 机以官方 OpenWrt 快照 RAM 系统启动（192.168.1.1，root 空密码），全程只用
读命令：`cat`/`ls`/`dd if=/dev/mmcblk0p25`、`dd if=/dev/mmcblk0p27`（前 70 MiB）、
读 `/sys/block/mmcblk0/*/uevent`、读 `/mnt/rom`（p27 squashfs，内核已 ro 挂载）、
读 `/proc/cmdline`。没有挂载任何分区为可写，没有 `sysupgrade`，没有写 eMMC。

恢复系统自身信息：内核 6.18.60，rootfs 为 tmpfs（966 MB），`/mnt/rom` 挂着
p27（squashfs，ro）。断电重启即可离开恢复模式，不需要任何写操作。

---

## 2. 取证与静态核对明细

### 2.1 尾部 overlay 的取证（决定性）

| 项 | 值 | 判读 |
|---|---|---|
| p27 squashfs `s_magic` | `hsqs`，compression=XZ | 有效 |
| squashfs `bytes_used` | 72 803 387 | fstools 算法 `align64k` → 72 810 496 |
| 72 810 496 处 ext4 超级块 | `0xEF53` 有效 | 位置与 fstools 预测逐字节一致 |
| `s_mtime`/`s_wtime`/`s_lastcheck` | 均为 2026-11-15 06:01:38 UTC | = 刷机时刻（mkfs 时间），此后无任何写 |
| `s_last_mounted` | 空串 | 从未挂载 |
| `s_mnt_count` | 0 | 从未挂载 |
| 目录内容 | 只有 `lost+found` | 从未使用 |
| p29 `rootfs_data` 分区 | 前 2 MiB 全零（未格式化） | 未走过 partname 路径 |

刷机脚本在写盘时按对齐尺寸 mkfs 尾部 ext4（`-L rootfs_data`），所以 mkfs 时间戳
是刷机时间，不是启动证据；而挂载计数/最后挂载点则是干净的启动证据。

### 2.2 启动链参数（复核）

- APPSBL env：`bootargs=console=ttyMSM0,115200n8 rootwait root=/dev/mmcblk0p27`，
  `bootcmd → run do_boot`；HLOS 当前槽 p25（GPT `0:HLOS`），p26 为 `0:HLOS_1`。
- p25 FIT：magic `d00dfeed`，totalsize 5 811 688；kernel-1 = gzip 6.12.112
  （解压 14 600 200 B，arm64 Image，gcc 14.3.0），fdt-1 = sbe1v1k DTB
  （45 369 B），config@rdp433。
- DTB `chosen`：`stdout-path = "serial0:115200n8"`；
  `bootargs-append = " fstools_ignore_partname=1"`。
- 25.12 内核源码 `drivers/of/fdt.c`（装配树内实际编译的 6.12.112）**包含
  `bootargs-append` 处理段**（generic hack-6.12/920 补丁已在），所以真实 cmdline
  会带上 `fstools_ignore_partname=1`，fstools 的 partname 驱动被正确抑制、
  走 rootdisk（尾部）路径。
- 结论：v26 的启动参数与 24.10 已验证可用的机制一致。

### 2.3 内核配置（6.12.112 装配树 `.config`）

| 项 | 6.12（25.12） | 6.6（24.10） | 影响 |
|---|---|---|---|
| `MMC`, `MMC_BLOCK`, `MMC_SDHCI_MSM` | =y | =y | 根设备可用 |
| `SQUASHFS`, `SQUASHFS_XZ` | =y | =y | 根文件系统可挂（镜像用 XZ） |
| `BLK_DEV_LOOP` / `MIN_COUNT` | =y / 8 | =y | fstools 建 loop 可用 |
| `OVERLAY_FS` | =y | =y | — |
| `EXT4_FS`, `JBD2` | **=m** | =y | 需用户态 kmodloader；模块、`modules-boot.d/30-fs-ext4` 都在，依赖链 `ext4→jbd2,mbcache` 完整 |
| `DEVTMPFS` | **未开** | **未开**（相同） | `/dev` 由 procd `early()` 挂 tmpfs 后 `mkdev("*")` 从 `/sys/dev/{block,char}` 造节点（mkdev.c 源码核对）；`loop0..7`、`mmcblk0p27` 节点必然存在。此前"缺 devtmpfs 导致 loop 建不出来"的猜想**不成立**，且两代相同、非差异项 |
| `F2FS_FS` | =y | — | 无关 |
| `SENSORS_PWM_FAN` | =m | =m | 风扇由用户态加载——见 §4.3 |

### 2.4 fstools（2024.07.14 → 2026.05.23）差异审阅

逐文件 diff `mount_root.c`、`libfstools/{volume,rootdisk,partname,overlay,common}.c`：

- 尾部偏移算法未变（squashfs `bytes_used` → 64 KiB 对齐）；
- ext4 挂载参数未变（`MS_NOATIME`、无 option）；
- 新增：EROFS 支持、`fstools_overlay_name/fstype/compression` cmdline 覆盖、
  f2fs 压缩挂载（失败回退无压缩）、`get_var_from_file` 移入 common.c。
- 没有改变既有 squashfs+tail 路径行为的修改。

### 2.5 25.12 首启对 overlay 的硬依赖

镜像 `/etc` 里**没有** `board.json`、`config/network`、`config/wireless`；这些由
`82_config_generate`、`/etc/init.d/boot` 在首启生成。overlay 没挂上 ⇒ `/etc`
只读 ⇒ 没有 board.json 和网络配置 ⇒ `br-lan` 不会建立、dnsmasq 不会启动 ⇒
**任何口都拿不到 192.168.1.1 的 DHCP**。这与"系统没起来"的用户观感完全一致，
但它是 §0.3 的结果而不是原因。

---

## 3. 本地仿真：25.12 的 mount_root / preinit 在这套布局上能跑通

目的：把"用户态会不会挂 overlay"从静态推理变成实验。方法（可复现）：

```
# 1) 从恢复系统只读 dump p27 前 70 MiB
ssh root@192.168.1.1 'dd if=/dev/mmcblk0p27 bs=1M count=70' > p27-head.bin
# 2) 组一块与真机同构的盘：squashfs @0，裁剪到 72 810 496，
#    再用 mkfs.ext4 -E offset=72810496 造 16 MiB 的 rootfs_data 尾部
# 3) 宿主 loop 挂 squashfs → 作为 chroot 根（stat("/") 即该 block device）
# 4) unshare -mn + chroot + qemu-aarch64（静态链接），
#    /proc/cmdline 用 bind-mount 的假文件：
#    "console=ttyMSM0,115200n8 rootwait root=/dev/mmcblk0p27 fstools_ignore_partname=1"
```

结果：

| 实验 | 结果 |
|---|---|
| `PREINIT=1 /sbin/mount_root start ""` | 退出码 0；尾部 ext4 `mnt_count` 0→1、`s_mtime` 更新、`Last mounted on: /` |
| 完整 `/etc/preinit`（PREINIT=1） | 跑完 02→82 全部钩子，打印 `- generating board file -`；尾部写入约 5.3 MiB（upper/work 与生成文件） |

局限（如实记录）：仿真是**用户态**验证，`/sys` 与 netdev 是宿主/空环境，
`board_detect` 输出 `Unsupported hardware. Network interfaces not initialized`
属环境噪声；`fopivot`/`pivot_root` 在 chroot 下的行为与真机不同，仿真只证明
"找到尾部→rw 挂载→继续生成配置"这条主链路无缺陷。仿真里的 ext4 在进程被
杀掉时留下孤儿文件（`Orphan file ... not clean`），这是沙箱收尾产物，不代表
真机问题。

---

## 4. 与既有假设的对照

### 4.1 H1（"系统已到用户态，LAN 不工作"）——**被否定**

到达用户态 ⇒ preinit 先于一切 init.d 逻辑执行 ⇒ 80_mount_root 必挂尾部 ext4
⇒ 必留 `mnt_count`/`s_mtime` 痕迹。尾部干净，H1 及其子项（插错口、命名不符、
ssdk/PHY probe 失败）都不能解释。

### 4.2 H3（写盘/槽位问题）——**否定**

p25 FIT 内核实为 6.12.112 且与镜像 `/lib/modules/6.12.112` 匹配；DTB 是
v26 的内容（0027 三项都在）；不存在"旧内核配新根"。

### 4.3 H2（内核在 init 前停住）——**唯一自洽解释**

若内核在 `start_kernel` 之后的任何一点 panic/卡死（或 init 从未 exec），
用户态不会运行、尾部不会被动、p29 不会被格式化——与全部现场证据一致。

**冲突点**：v25 记录过"风扇不满速"，而 `pwm-fan` 是模块、由用户态
kmodloader 加载（`modules-boot.d` 里没有它，说明还要更晚的 init.d 阶段）。
若风扇确实变慢，等于用户态跑过——与本报告的尾部取证矛盾。可能的解释：
(a) v25 当时的风扇观察不准确（或来自不同砖态）；(b) v25/v26 行为不同
（代码相同，只能归结为 CI 重建或观察差异）；(c) 内核在更晚的 initcalls
（驱动模块）阶段卡死时，PWM 占空比也可能被某个 probe 改写——目前没有证据支持。

v26 的风扇行为没有直接记录。这个矛盾不需要更多静态分析，只需要一次带观察的
启动（§5 第 0 步）。

### 4.4 与 v24 的差异

v24 = v26 去掉 0027（CPU OPP 删表 / `sleep-clk` 去掉 32 kHz / NSS 32 MiB
保留区 no-map）。v24 现场记录是"有 carrier、拿不到 DHCP"，carrier 意味着
netdev 已注册——即**到过用户态**。加入 0027 之后（v25、v26）不再有用户态
迹象。静态看三项都"温和"（v25 文档 §1.3），但它是目前唯一的代码变量，
应作为第一个 bisect 对象。

---

## 5. 下一步（全部需要你批准；本报告没有执行其中任何一项）

按成本排序：

0. **零成本观察（下次尝试 v26 时）**：记录风扇档位（满速/低转）在通电后
   30 秒、2 分钟两个时间点的状态，以及蓝灯节奏是否变化。风扇始终满速 ⇒
   内核连用户态都没到（支持 H2）。风扇变低转 ⇒ 用户态跑过（推翻 §0.3 的解读，
   需要重新取证）。
1. **串口（决定性）**：ttyMSM0 / 115200。注意先说清楚板子上调试 UART 的电压
   （IPQ9574 平台常见 1.8 V，接 3.3 V 适配器前必须核实丝印/原理图）。日志里
   要看三件事：`Booting Linux` / `mmc0` 探测 / `VFS: Mounted root` /
   `Run /sbin/init`。
2. **v27 诊断构建（不依赖串口的内核可视化）**：把 25.12 DTS 的 `led-0`
   （GPIO 64）加 `linux,default-trigger = "heartbeat"`（或先用 24.10 DTS 里
   红/绿灯的 pwm-leds 节点移植过来）。LED 呼吸 = 内核活到 LED 子系统注册。
   若需要更细的分段，可在 DTS `chosen/bootargs-append` 加
   `initcall_debug` 等，但无串口时意义有限。
3. **v28 对照构建**：以 v26 代码去掉 0027 重建。若 v28 到达用户态 ⇒ 0027 是
   回归源，再按 OPP / sleep_clk / no-map 三项逐项 bisect。
4. （可选）**PSTORE_BLK 写 p33**：GPT 里有一个 128 MiB 的 `log` 分区，
   可用来在 panic 时落盘 dmesg。但"卡死"不产生 panic，价值有限；需要确认
   该分区没有其他用途后再考虑。

以上 2/3/4 都涉及刷机；1 涉及接线。每一项执行前我都会单独向你确认，
包括刷写方式与回滚方案（恢复模式 + 24.10 v78 回滚流程均已验证可用）。

---

## 6. 现场状态

- B 机此刻仍在 RAM 恢复模式（192.168.1.1，root 空密码，`/mnt/rom` ro 挂着），
  主机侧 dnsmasq/TFTP 仍在运行（`/tmp/sbe-tftp.log`）。
- 磁盘内容未被本次检查改变；断电重启即可回到正常启动链（会再次尝试 eMMC
  上的 25.12）。
- 24.10 v78 回滚镜像随时可刷；恢复流程见 `recovery-mode` 记录。

## 7. 状态词

- 静态核对（§2）：PASS。
- 现场取证（§2.1）：PASS（只读取证，结论"尾部从未挂载"）。
- 用户态仿真（§3）：PASS（主链路）。
- 故障根因定位：未定稿——锁定在内核/init 边界之前（H2），待 §5 第 0/1 步
  的证据。
- 设备行为：v26 启动失败，NOT RESOLVED。
