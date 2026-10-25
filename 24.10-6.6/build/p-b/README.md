# build/p-b/ —— P-B 设备定义暂存区

> 阶段：**首次构建准备**（已装配、已 `make defconfig`；未编译、未连接设备）
> 状态：**已安装进 `sources/buildroot/`**（用户批准「批准把 P-B 安装进 sources，
> 准备首次构建」，2026-10-21）；完整编译仍需单独批准
> 关联文档：`docs/PB_DEVICE_DEFINITION.md`（逐值证据表与 UNVERIFIED 清单）、
> `docs/BUILD_TREE_ASSEMBLY.md`（装配与安装记录、安装后 SHA-256）

本目录保留 P-B 的**原始评审材料**；构建树中的副本与这里的文件逐字节一致
（SHA-256 已核对，见 `docs/BUILD_TREE_ASSEMBLY.md` §5）。

---

## 1. 目录内容

| 路径 | 性质 | 状态 |
|---|---|---|
| `files/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts` | 新设备树（801 行，2026-10-25 加入 eMMC：`sdc_default_state` + `&sdhc_1`） | 已用 `cpp` + `dtc` 离线校验：**0 error**（2026-10-25 复验，反编译 DTB 确认 `mmc@7804000` 为 `okay`） |
| `files/base-files/etc/board.d/01_network` | target feed 文件 + `spectrum,sbe1v1k` 分支 | 以 feed 版本为基线 |
| `files/base-files/etc/board.d/02_ipq_board` | target feed 文件 + `spectrum,sbe1v1k` | 以 feed 版本为基线 |
| `files/base-files/etc/init.d/eth0-lan-attach` | 厂商脚本，逐字照抄 | LICENSE_REVIEW_REQUIRED |
| `files/base-files/usr/sbin/eth0-lan-attach` | 厂商脚本，逐字照抄 | LICENSE_REVIEW_REQUIRED |
| `files/base-files/etc/uci-defaults/99-spectrum-eth0-unmanaged-lan` | 由厂商版本裁剪 | 删去 vendor-only 服务 |
| `patches/0001-ipq95xx-image-add-spectrum-sbe1v1k.patch` | 新增 `Device/spectrum_sbe1v1k` | `git apply --check` 通过 |
| `patches/0002-arm64-dts-qcom-add-ipq9574-sbe1v1k.patch` | 内核 DTB 列表登记 | `git apply --check` 通过 |
| `patches/0003-ipq95xx-add-pwm-feature.patch` | 目标 FEATURES 增加 `pwm` | `git apply --check` 通过 |

**没有 config 片段**。LED/风扇消费者驱动通过设备定义的 `DEVICE_PACKAGES`
（`kmod-leds-pwm`、`kmod-hwmon-pwmfan`）引入；`CONFIG_PWM`、`CONFIG_PWM_IPQ`
在 `ipq95xx/config-6.6` 中已经是 `=y`。`kmod-leds-pwm` 的 `@PWM_SUPPORT`
依赖由 patch 0003 满足。按键由 `kmod-gpio-button-hotplug`（已在
`DEFAULT_PACKAGES`）接管，其 `KCONFIG:=` 为空并显式替代 `KEYBOARD_GPIO` /
`KEYBOARD_GPIO_POLLED`，因此**不需要**开启 `CONFIG_KEYBOARD_GPIO`。

---

## 2. 安装位置（2026-10-21 已执行）

构建树中的落点。基座为 `sources/qsdk14` 的复制树 `sources/buildroot/`；target feed
与内核文件树按 `docs/QSDK_ROUTE_B_PLAN.md` 的 α′ 装配方式进入 `target/linux/feeds/`。

| 暂存文件 | 目标路径（构建树内） | 来源仓库 |
|---|---|---|
| `files/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts` | `target/linux/feeds/files-6.6/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts` | `oss-kernel-linux-ipq-files` |
| `files/base-files/**` | `target/linux/feeds/ipq95xx/base-files/**` | `oss-system-feeds-target-ipq/ipq95xx` |
| `patches/0001-*.patch` | 从 `target/linux/feeds/` 用 `patch -p1` 应用（补丁路径是 `a/ipq95xx/…`） | 同上 |
| `patches/0003-*.patch` | 从 `target/linux/feeds/` 用 `patch -p1` 应用（同上） | 同上 |
| `patches/0002-*.patch` | 从 `target/linux/feeds/files-6.6/` 用 `patch -p1` 应用（补丁路径是 `a/arch/arm64/…`） | `oss-kernel-linux-ipq-files` |

CI 使用的是固定 Release 资产 `sources-v1`，其中的 DTS 不会随仓库更新；因此
`24.10-6.6/scripts/ci/prepare-tree.sh` 自 2026-10-25 起每次构建都用本目录的
`files/arch/.../ipq9574-sbe1v1k.dts` 覆盖装配树里的副本（并断言 `&sdhc_1` 存在）。

依据：`target/linux/feeds/ipq95xx/Makefile`（`LINUX_IS_FLATTENED_TREE` 分支）在解析时执行
`cp -fpR -u $(TOPDIR)/target/linux/feeds/files-$(LINUX_SRC_VERSION)/* $(CONFIG_EXTERNAL_KERNEL_TREE)`，
即 `files-6.6` 会覆盖到 `qca/src/linux-6.6`；因此 DTS 和 DTB 注册都必须
落在 `files-6.6` 内，而不是直接改内核源码树。

**基线 SHA**（安装前 `sha256sum` 记录，安装后差异均可归因于本目录的操作）：
`01_network e856e01f…`、`02_ipq_board e443e73b…`、DTS Makefile `3d2c6475…`、
`generic.mk 88dcf3ef…`、`ipq95xx/Makefile c6588f33…`；安装后的当前值见
`docs/BUILD_TREE_ASSEMBLY.md` §5。

补丁 0002 在装配时重新生成过一次 hunk：原 hunk 基于另一分支的 DTS Makefile，
在 manifest-pin 版本上以 fuzz 2 应用；重生成后 `patch` 干净命中 `@@ -108,6 +108,7 @@`，
不再依赖模糊匹配。

---

## 3. 已验证 / 未验证

| 项目 | 方法 | 结果 |
|---|---|---|
| DTS 语法与节点引用 | `cpp` + `dtc -I dts -O dtb`（离线） | **PASS**（0 error） |
| DTS 解析值 | `fdtdump` 抽查保留内存、dp 节点、port_phyinfo、wifi 覆盖、aliases、pwm | **PASS** |
| 补丁可应用性 | `git apply --check` 于目标文件副本 | **PASS**（3/3） |
| 安装后选择 | `make defconfig` + `.config` 检查 | **PASS**：`CONFIG_TARGET_PROFILE="DEVICE_spectrum_sbe1v1k"`，`kmod-leds-pwm`/`kmod-hwmon-pwmfan` 均为 `y` |
| 安装后 DTS 覆盖 | 触发 target feed 解析后检查 `qca/src/linux-6.6` | **PASS**：DTS 已复制，`Makefile:111` 已登记 DTB |
| 首次编译 | —— | **NOT TESTED**（G3 需单独批准） |
| 启动、网络、Wi-Fi、风扇 | —— | **NOT TESTED**（G5 需单独批准 + 现场密码） |
| `IMAGE_SIZE := 96m` | 仅由厂商 rootfs 大小推断 | **UNVERIFIED** |
| PWM 通道 ↔ GPIO 颜色对应 | 厂商 DTB 只给出 44/45/56 与通道 0/1/2/3 的**并存**，未给出映射 | **UNVERIFIED** |

完整逐值证据与未决项见 `docs/PB_DEVICE_DEFINITION.md`。

---

## 4. 硬性规则（沿用项目约束）

- 安装已获批准并完成；**完整编译、刷机、连接设备仍需逐项批准**；
- 已执行的 `scripts/feeds` 与 `make defconfig` 属于本地配置步骤，不产生固件、
  不下载工具链源码、不接触设备；
- 不得把路由器密码写入本目录任何文件；
- 原始固件 `firmware/` 保持字节不变。
