# RTL8261N 假环回修复移植到 25.12-6.12（2026-11-25）

状态：补丁 `0044-rtl8261n-reinit-on-resume.patch` 已写入本树，本地
`--fuzz=0` dry-run PASS；**构建与真机 NOT TESTED**。

## 背景

假环回的根因与修复设计见 24.10 文档
`24.10-6.6/docs/RTL8261N_FAKE_LOOPBACK_FIX-2026-11-25.md`（补丁
`build-fixes/0032`，提交 `11ad01e`）。简述：phylib 在 `phy_stop()` 时
调用驱动 `.suspend`（MMD1.0 bit11 断电），`phy_start()` 时
`__phy_resume` 只清断电位，不重跑 `rtkphy_config_init()`（MMD30 0x145
硬件复位 + 固件 patch）；RTL8261N 断电后不做完整初始化，铜缆 AN 引擎
起不来，路由器侧报假 10G link、对端 NO-CARRIER，只有重启能恢复。

## 6.12 树核对

- 本树驱动源码
  `target/linux/generic/files/drivers/net/phy/rtl8261n/rtk_phy.c`
  的 `rtkphy_c45_resume` 与 24.10 缺陷代码逐字相同（仅外层多了
  `#ifndef CONFIG_MACH_REALTEK_RTL` 守卫）；
- 设备 dmesg 确认 eth0 PHY 由该驱动接管：
  `Realtek RTL8261N 90000.mdio-1:00: rtkphy_config_init:80 ...`、
  `nss-dp ... eth0: PHY [90000.mdio-1:00] driver [Realtek RTL8261N]`；
- 6.12 的 phylib 时序已核对：`phy_device.c` 的 `phy_suspend()` 在驱动
  suspend 返回成功后才置 `phydev->suspended = true`，
  `__phy_resume()` 在调用驱动 resume 之后才清零，因此驱动 resume 内
  读到 `suspended == true` 恰好表示「本次是从 suspend 恢复」（开机首次
  `phy_start` 为 false，不受影响）；
- `rtkphy_config_init()` 在文件中定义于 resume 之前且不受
  `CONFIG_MACH_REALTEK_RTL` 整体门控，无需前置声明。

## 补丁 0044

与 24.10 `0032` 相同的修法：`.resume` 里先 `power_normal`，若
`phydev->suspended` 为 true 则打印
`RTL8261N: re-initializing after suspend` 并重跑
`rtkphy_config_init()`。差异仅两处：

1. 补丁路径：本树驱动位于 `target/linux/generic/files/...`（24.10 树
   在 `qca/src/linux-6.6/...`）；
2. 保留原有 `#ifndef CONFIG_MACH_REALTEK_RTL` 结构：断电逻辑与修复都在
   该守卫内，`#else`（未启用 phylib 断电的配置）走 `ret = 0`，
   resume 里不会重初始化。

本树没有 sources Release / 指纹门禁流程（与 24.10 不同），补丁随
`prepare-tree.sh` 第 3 步按文件名顺序应用，无需其他登记。

## 验证记录（本地）

- `patch -d sources/buildroot-25.12-6.12 -p1 --fuzz=0 --dry-run` PASS；
- 在纯净副本上实际应用后与目标文件 `diff` 逐字节一致（APPLY_MATCHES）。

## 待真机验证的判据

1. 刷入含 0044 的镜像，开机 eth0 2500 真链路（回归，不出现多余重初始化）；
2. live `sbe-port-roles set eth0` 后再 `set eth1` 往返：每次 eth0 应回到
   2500 真链路、对端恢复载波，dmesg 出现
   `RTL8261N: re-initializing after suspend`；
3. WAN 在新角色下拿到 DHCP，`sbe-port-roles status` 与 board.json 一致。

注：`files/usr/sbin/sbe-port-roles` 目前对涉及 eth0 的 live 切换打印
假环回警告并建议重启；判据 2 PASS 后可考虑去掉该警告，属单独决策。
