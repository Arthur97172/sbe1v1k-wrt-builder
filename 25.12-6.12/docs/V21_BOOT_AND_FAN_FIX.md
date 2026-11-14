# v21 起不来 + 风扇满速：静态定案（2026-11-14）

对 `v21-1-291e35e0-25.12-6.12` 的刷机反馈（风扇一直满速、系统起不来）做的
本地静态审计。结论与修复都只基于仓库内的源码、构建产物配置与已知可用的
参照镜像；**没有连接路由器、没有刷机、没有真机日志**，因此所有设备行为仍记
`NOT TESTED`。

## 1. 风扇满速

`DEVICE_PACKAGES` 里本来就有 `kmod-hwmon-pwmfan` 与 `kmod-leds-pwm`，但两个包
都没有进镜像：它们的 KCONFIG 符号依赖 `CONFIG_PWM`，而
`target/linux/qualcommbe/config-6.12` 从未打开它，构建出的内核 `.config` 是
`# CONFIG_PWM is not set`，`CONFIG_SENSORS_PWM_FAN` / `CONFIG_LEDS_PWM` 两个
符号在合并时被静默丢弃（kmod 包不会报错）。

同时 6.12 内核里没有 `drivers/pwm/pwm-ipq.c`：IPQ9574 的 PWM 控制器
（TCSR `0x1941010`，`GCC_ADSS_PWM_CLK`）在这棵树上根本没有驱动，通道 3
（GPIO 53，风扇）只能停在硬件默认电平，即满速。

另外即便驱动存在，`drivers/hwmon/pwm-fan.c` 的 probe 也直接
`set_pwm(ctx, MAX_PWM)`，必须配一个 cooling device 才会降速——只加节点不配
温控区同样恒为 100%。

修复：

- `patches/0025`：原样收进上游 OpenWrt qualcommbe 的 0400（DT 绑定）、0401
  （驱动 + Kconfig/Makefile）、0402（`pwm@1941010` 节点，默认 disabled）、
  0403（周期计算修复，25 kHz 短周期否则塌成约 0% 高电平）；`config-6.12`
  打开 `CONFIG_PWM=y`、`CONFIG_PWM_IPQ=y`，并把打开 PWM 后才可见的
  `CONFIG_LEDS_QCOM_LPG` 钉成 `n`。后者不是可选项：OpenWrt 给内核构建
  导出 `FAIL_ON_UNCONFIGURED=1`，`conf --syncconfig` 遇到没有取值的新符号
  立即 `exit 1`，CI #23（1d9b13f）因此在 `target/linux` 里 13 秒失败，
  日志只剩一行 `ERROR: target/linux failed to build`。
- `patches/0026`：板级 DTS 增加通道 3 的 `pwm-fan`（40 µs 周期）、
  `pwm_pins`（GPIO 44/45/53/56 复用到 PWM）、`fan_tach_pins`（GPIO 40 上拉，
  两脉冲/转）、四个 active trip（40/50/65/80 °C，2 °C 回差）与 cooling maps，
  合并进 `ipq9574.dtsi` 已有的 `top-glue-thermal`（tsens 15）。数值取自官方
  OpenWrt 的 SBE1V1K 设备树。

## 2. 起不来

v21 的 FIT（`Build/fit-its`）把 `KERNEL_LOADADDR` 写进了 kernel 节点的
load/entry：`Device/Default` 的值是 **`0x41000000`**。这个地址落在厂商内存图
给 NSS 固件保留的 32 MiB 窗口 `0x40000000..0x42000000` 内——24.10 板级 DTS
把同一个保留区写作 `nss@40000000`，注释里明确记着“这是 24.10 必须用
`0x42000000` 的原因”。

本板两个已知可用值：

| 来源 | 装载地址 |
|---|---|
| 官方 OpenWrt 镜像（askey,sbe1v1k） / 上游 SBE1V1K 刷机指引（注明 `0x41000000` 会重启） | `0x42200000` |
| 本项目 24.10-6.6 镜像（真机 v65） | `0x42000000`（正好在保留区边界） |

修复：`patches/0024` 给 `spectrum_sbe1v1k` 与 `spectrum_sbe1v1k_mainline` 两个
设备加 `KERNEL_LOADADDR := 0x42200000`。`KERNEL_LOADADDR` 在
`DEFAULT_DEVICE_VARS` 里，按设备覆盖不会影响其他 ipq95xx 板子。

## 3. 已验证 / 未验证

静态验证（本地，全部通过）：

- `0024`–`0026` 按文件名顺序对装配树 `patch -p1 --dry-run --forward --batch`
  全部干净应用；
- 0400–0403 四个内核补丁对 `linux-6.12.112` 干净应用；
- `pwm-ipq.c` 用项目 aarch64 工具链交叉编译通过（仅 `STAGING_DIR` 告警）；
- 板级 DTS 用 cpp + dtc 编译通过，反编译断言：`pwm@1941010` 为 `okay`、
  `pwm-fan` 的 `pwms = <&pwm 3 40000 0>`、`cooling-levels <36 72 128 255>`、
  `top-glue-thermal` 合并出四个 active trip 与 fan cooling maps；
- `CONFIG_PWM` 依赖链核对：`ARCH_QCOM=y`、`HAVE_CLK=y`、`HAS_IOMEM=y`、
  `THERMAL=y`、`LEDS_CLASS=y`；6.12 已没有 `CONFIG_PWM_SYSFS`（6.11 起移除），
  所以补丁里不写它。

未验证（需要真机 / 串口日志，属后续单独批准的动作）：

- 装载地址修复后 eMMC 能否启动到用户态；
- 风扇是否在 40 °C 以下按 36/255 档运行并在升温后逐级提高；
- `CONFIG_PWM_IPQ` 与 `nss`/`ath12k` 的运行时共存（时钟 `GCC_ADSS_PWM_CLK`
  与 `assigned-clock-rates <100000000>` 的行为）。

## 4. 顺带发现，未修改

25.12 的板级 DTS 没有 24.10 里那条 `nss@40000000` 的 `no-map` 保留区。
如果厂商引导器把 NSS 固件放在 `0x40000000..0x42000000`，Linux 会把这段当普通
内存分配。这影响的是以太网数据面而不是本次的启动/风扇症状，且需要 S2 的
`/proc/iomem` 或串口日志才能确认，故只记录，不在本批修改。
