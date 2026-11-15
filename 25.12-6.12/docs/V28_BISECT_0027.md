# v28：去掉 0027 的对照构建

日期：2026-11-15
目的：判定补丁 0027（CPU OPP 删表 / `sleep_clk` 去 32 kHz / NSS 32 MiB
no-map 保留区）是否为 v25/v26 到不了用户态的回归源。

## 1. 实验设计

| 版本 | 相对 v26 的代码差异 | 现场结果 |
|---|---|---|
| v24 | **没有 0027**（其余相同） | 起不来；LAN 无 DHCP（链路曾有 carrier） |
| v25 / v26 | 有 0027 | 起不来；现场取证：overlay 尾部 ext4 `s_mnt_count = 0`，从未到 preinit |

`git diff` 已确认 25.12 的代码从 v24 到 v26 只多了 0027 一个补丁（另一处差异是
文档）。因此 v28 = 把 0027 移到 `patches/disabled/` 后重新构建：**内核与设备树
回到 v24 的形态**，只用来做 A/B 对照。

注意一个容易误读的旧记录：v24 的"有 carrier"来自内核里 `nss-dp`/PHY 的链路
状态，**不代表用户态跑过**。所以 v24 的现象与"内核起来了但死在用户态之前"
并不矛盾，v28 预期与 v24 同类（很可能同样没有 DHCP）。

判据不靠串口（当前没有串口线），只靠刷机后从恢复系统只读取证：

- **尾部 ext4 挂载计数**：25.12 的 overlay 在 `mmcblk0p27` 尾部（偏移 =
  squashfs `bytes_used` 向上取整到 64 KiB）。ext4 只要被 rw 挂载就会改写
  超级块，所以 `s_mnt_count ≥ 1` / `s_last_mounted = "/"` 就证明**系统到达过
  preinit 的 25.12 用户态**；为 0 则没有。方法学已在 v78（24.10）上做过阳性
  对照（`mnt_count = 1`），见 `docs/V26_RECOVERY_DIAG_2026-11-15.md` §8。
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

## 3. 判读表

| v28 的尾部 `s_mnt_count` | 结论 | 下一步 |
|---|---|---|
| ≥ 1 | **0027 是回归源**（v26 有它到不了用户态，v28 没有能到） | 在 0027 内部逐项 bisect：先只保留 CPU OPP 删表，再单独加 sleep_clk / NSS 保留区；24.10 的先验是最可能由 CPU OPP 引起（v52–v54 静默死亡） |
| = 0 | 0027 不是（唯一）根因 | 排除法继续：检查 25.12 用户态入口（procd/preinit）与内核 6.12 的其它差异；考虑 LED heartbeat 诊断构建把"内核活到哪"可视化 |

两种结果都只影响 25.12 分支，不影响正在使用的 24.10 v78。

## 4. 刷机与取证步骤（需要用户批准后执行）

1. 从恢复系统刷入 v28（`sysupgrade -F -n`，先两端比对 SHA-256），流程同
   `recovery-mode` 记录；`-n` 不继承配置。
2. 通电 30 s 与 2 min 各记录一次：风扇档位、灯态、LAN 是否有 DHCP。
3. 若拿不到 192.168.1.1，再次进恢复模式，只读取 `mmcblk0p27` 尾部超级块：
   从发布镜像解析 squashfs `bytes_used` → 64 KiB 对齐得偏移 → 读
   `dd if=/dev/mmcblk0p27 bs=512 skip=<(offset+1024)/512> count=2` →
   看 `s_mnt_count`（偏移 0x34）、`s_last_mounted`（0x88）。
4. 若 v28 能到 192.168.1.1：直接 SSH 读 `mount`、`/proc/uptime`、dmesg，
   并记录 `s_mnt_count` 作为"到过用户态"的正向证据，然后按判读表行动。

## 5. 状态词

- 构建：待 CI 产出后按实际结果记。
- 设备行为：`NOT TESTED`（本文写于刷机之前）。
