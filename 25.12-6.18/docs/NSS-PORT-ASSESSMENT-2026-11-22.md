# NSS 移植到 6.18 的可行性评估（S3，2026-11-22）

用户要求「25.12-6.12 带 NSS，25.12-6.18 需要加入」。本文是动工前的实测评估：
只做**只读**的补丁试应用与源码清点，不改动任何构建输入，不接触设备。

## 1. 结论（TL;DR）

- **可行，但不是搬目录**：6.12 的 NSS 是「QSDK14 厂商源码（基于 6.6）+ 40 个
  内核补丁 + 1 份 NSS DTS」组合。厂商源码在 `sources/buildroot/qca/src/nss/`
  （约 22 GB 树中的一部分），CI 用 `nss-src.tar.gz` 打包件。
- **内核导出面基本能过**：6.12 的 40 个补丁里有 17 个（0002–0008、0013–0020）
  在 6.18 树上 `patch -p1 --fuzz=0 --dry-run` **全部干净通过**，这些正是
  qca-ssdk/dp/ppe/ecm 编译所必需的导出面（swconfig 扩展、br_fdb 删除、
  nat46、route notifier、bridge offload、netdev hw_offload 等）。
- **冲突集中在板级与设备层**（0001、0010–0012、0021–0029、0033–0040）：
  它们改的是 6.12 的 `spectrum_sbe1v1k` 设备定义、eMMC、PWM/风扇/LED、
  OPP/NSS 保留区等。6.18 用的是上游原生 `askey_sbe1v1k` 设备定义，
  这些功能上游已具备或用不同写法实现，需要**重写**而不是移植。
- 主要风险不在内核，而在 **QSDK 源码对新内核 API 的适配**（6.6 → 6.18 跨
  12 个版本）：`register_sysctl` 哨兵（6.11+，6.12 已踩过）、`netdev_ops`、
  `phylink`、`dev_addr`、时钟/复位框架、`ethtool` 接口、`ndo_*` 签名等。

## 2. 6.12 的 NSS 构成（清点）

| 组成 | 位置 | 说明 |
|---|---|---|
| 内核导出补丁 | `25.12-6.12/patches/0002–0008`、`0013–0020` | 让 QSDK 模块能拿到内核内部符号 |
| NSS DTS | `patches/0009`（新增）、`0010`（选择） | 6.12 板级 DTS 里的 dp/ppe 节点 |
| 板级网络 | `patches/0011`、`0012`、`0023` | 从 QSDK14 抄 Ethernet 节点、mainline 兜底 |
| 包 | `25.12-6.12/nss/packages/*` | qca-ssdk、qca-ssdk-shell、qca-nss-dp、qca-nss-ppe(-ds/-vp/-rule)、qca-nss-sfe、qca-nss-ecm、qca-nss-phy、qca-nss-ae-clients、qca-nss-debug |
| 源码接入 | `nss/install.sh` + `nss/include/local-development.mk` | 把厂商源码目录接进装配树，补丁在装配树内直接打 |
| 用户态 | `files/etc/init.d/nss`、`files/usr/sbin/nss-load`、`files/etc/nss.conf` | 档位（wired/full）、手动装载顺序（先 ppe-rule 再 sfe/ecm） |
| 源码包校验 | `nss/nss-src.tar.gz.sha256` + `scripts/ci/export-nss-src.sh` | CI 复现厂商源码包 |

## 3. 补丁试应用结果（6.18 树，2026-11-22，dry-run）

**干净通过（17）**：0002 0003 0004 0005 0006 0007 0008 0009 0013 0014 0015
0016 0017 0018 0019 0020、0023。

**冲突（21）**：0001（设备定义）、0010（DTS 选择）、0011（QSDK Ethernet 节点）、
0012（mainline 兜底）、0021/0022（eMMC）、0024（装载地址）、0025/0026/0040
（PWM 风扇/LED）、0027（启动阻塞项）、0028（eMMC 复位）、0029（NAND）、
0033/0035（ath12k DT 属性/DMA 池）、0036（MDIO 复位）、0037（PCS 时钟）、
0038/0039（射频排序，6.18 已用本项目补丁/上游实现替代）。

冲突项的处理原则：**功能照做、补丁重写**。6.18 的上游设备定义已经把
eMMC、PWM 风扇/LED、RTL8261N、ath12k BDF 做好（S1b 真机 PASS 已证），
不需要把 6.12 的板级补丁搬过来；只需为 NSS 数据通路补 dp/ppe 节点。

## 4. 分阶段落地（S3a–S3e）

| 阶段 | 内容 | 判据 |
|---|---|---|
| S3a | 把 0002–0008、0013–0020 装入 `25.12-6.18/patches/`，QSDK 包与
`local-development.mk` 接入 `prepare-tree.sh`；只求 `qca-ssdk` 编译通过 | 本机构建 `package/feeds/nss/qca-ssdk` 出 .ko；不选入镜像 |
| S3b | `qca-nss-dp` + `qca-nss-ppe`（含 ds/vp/rule）+ `qca-nss-sfe` 编译 | 全部 .ko 产出；逐个记录 6.18 API 修复 |
| S3c | `qca-nss-ecm`、`qca-nss-ae-clients`、`qca-nss-debug`、`ssdk_sh` | 同上 |
| S3d | NSS DTS 节点 + 设备配置切换（ssdk 成员表、端口角色重建） | 静态断言 + 首启 `nss-load` 日志 |
| S3e | 真机验证（**需用户单独批准**）：`/sys/ssdk`、加速计数、8 h 长跑 | 对齐 6.12 v94 的判据 |

S3a 开始前保持 mainline PPE 路径为默认（`kmod-qcom-ppe` 已在镜像里），
NSS 包**只编译不安装**，任何一步失败都不影响现有可启动镜像。

### 4.1 S3a 已落地（2026-11-22）

- `25.12-6.18/patches/` 新增 17 个补丁（外层编号沿用 6.12 原号，0010–0016、
  0021–0029）。其中 14 个生成内核补丁 `patches-6.18/0500–0513`；内层重新
  连续编号（6.12 的补丁号在 6.18 目录里不连续），三个不生成内核补丁的是
  `config-default`（0012）与 nat46 Makefile（0016）的直接编辑：

| 6.18 外层 | 内层 | 6.12 | 内容 | 6.18 适配 |
|---|---|---|---|---|
| 0010 | 0500 | 0002 | swconfig 扩展（qca-ssdk 用） | 原样 |
| 0011 | 0501 | 0003 | br_fdb 按 netdev 删除导出 | `br_fdb_delete()` 新增 `bool *notified` 出参，调用点传本地变量（6.18 会无条件写该指针，传 NULL 会崩） |
| 0012 | — | 0004 | ipq95xx `config-default` 打开 swconfig | 直接改配置 |
| 0013 | 0502 | 0005 | netstandby uapi 头 | 原样 |
| 0014 | 0503 | 0006 | dmac cache helpers 导出 | 原样 |
| 0015 | 0504 | 0007 | saved_command_line 导出 | 原样 |
| 0016 | — | 0008 | nat46 模块头安装 | 直接改 Makefile |
| 0021 | 0505 | 0013 | qcom fast NAT hook | 原样 |
| 0022 | 0506 | 0014 | route change notify 链 | 按 6.18 fib 内部结构重做 |
| 0023 | 0507 | 0015 | qcom bridge offload helpers | 原样 |
| 0024 | 0508 | 0016 | ndisc send NS 导出 | 原样 |
| 0025 | 0509 | 0017 | qcom bridge query helpers | 按 6.18 重做 |
| 0026 | 0510 | 0018 | TCP no-window-check 恢复 | 原样 |
| 0027 | 0511 | 0019 | bridge FDB notify | 按 6.18 重做 |
| 0028 | 0512 | 0020 | netdev hw_offload ops | 原样 |
| 0029 | 0513 | — | 新增：为树外 PHY 驱动发布 phy_package 原型与 `phy_package_get_base_addr()` | 6.18 把 `struct phy_package_shared` 私有化，qca-nss-phy 一个头都拿不到 |

- 全部 0500–0513 在真实 `target/linux/prepare` 路径下 `--fuzz=0` 应用通过
  （本机构建日志 `logs/build-6.18-kernel-0513*.log`）。
- 厂商侧新增 6.18 可移植性补丁（`nss/patches/qca-nss-phy/0009–0012`）：
  - 0009：`eee_enabled`/`eee_broken_modes` → `eee_cfg`/`eee_disabled_modes`
    （wrapper、qca8084、qca81xx）；
  - 0010：`phydev->shared` 成员访问 → `phy_package_get_*()` 访问器
    （7 文件；`qce1204_count_package_ports()` 引入 `np`/`base_addr` 局部变量）；
  - 0011：`nss_phy_linux.c` 的 EEE 状态初始化改位图判定 +
    `phy_drivers_register/unregister()` 数组形式；
  - 0012：`PIN_CONFIG_OUTPUT` → `PIN_CONFIG_LEVEL`（6.18 删除了前者）。
- `qca-ssdk` 的 6.18 可移植性补丁（`nss/patches/qca-ssdk/`，接在 6.12 的
  0001–0013 之后）：
  - 0014：`phy_driver_register/unregister()` → `phy_drivers_register/unregister()`
    数组形式（`sfp_phy.c`；6.18 只导出后者）；
  - 0015：`ssdk_init.c` 三处 —— `phydev->eee_enabled` → `phydev->eee_cfg.eee_enabled`、
    `ssdk_pcs_get_state()` 增加 `unsigned int neg_mode` 形参、删除
    `phylink_pcs.neg_mode` 赋值（6.18 把 neg_mode 从成员改成调用参数）；
  - 0016：`ssdk_plat.c` 四个 sysfs `bin_attribute` 回调加 `const`（6.14+ 签名变化，
    packet_counter/byte_counter 的 read/write）；
  - 0017：`ssdk_mht_pinctrl.c` 的 `PIN_CONFIG_OUTPUT` → `PIN_CONFIG_LEVEL`
    （与 qca-nss-phy 0012 同一处 6.18 枚举删除）。
- **S3a 判据达成（2026-11-23 本机）**：`package/qca-ssdk/compile` EXIT=0，
  产出 `build_dir/.../qca-ssdk-nohnat/qca-ssdk/build/bin/qca-ssdk.ko`
  （ARM aarch64 ELF，nohnat 变体，编 191 s）。未选入镜像，mainline PPE 不变。
- 厂商补丁的刷新顺序（踩坑记录）：`$BR/qca/src/nss/base` 是 install.sh 从
  `sources/buildroot` 复制并打补丁的产物。手工改这份副本后，必须重跑
  `nss/install.sh`（把改动沉淀成 `nss/patches/`）**并** `package/<pkg>/clean`，
  否则 `.prepared` 戳不校验源码内容，build_dir 会继续用旧副本。
- `qca-nss-phy` 的全部 C 源在 6.18 上编译通过；第一次 modpost 只报
  `phy_package_get_base_addr` 未定义——内核尚未带 0513 重编。
- 6.18 树的内核补丁还暴露了一处真实 API 断裂：`br_fdb_delete()` 的
  7 参签名（见 0501 行），已修并重编内核。
- `25.12-6.18/nss/` 已从 6.12 同源复制：`install.sh`（只改树名）、
  `include/local-development.mk`、12 个包定义、各包内 6.12 可移植性补丁。
- `prepare-tree.sh` 在应用项目补丁、拷贝 overlay 之后调用 `nss/install.sh`；
  找不到厂商源码（CI 未配 nss-src 资产）时打印跳过，不中断构建。
- `seed` 未选任何 NSS 包：mainline PPE 仍是镜像默认数据通路。

### 4.2 S3b 构建环境的两处 6.18 断裂（2026-11-23）

两处都不是厂商源码的 API 问题，而是「6.12 能过、6.18 静默变坏」的构建链差异：

1. **kbuild 删除了 `EXTRA_CFLAGS`**（6.15 起 `scripts/Makefile.lib` 不再引用；
   6.18 里 `EXTRA_CFLAGS=` 被无声忽略）。NSS 九个包用它传
   `-I$(STAGING_DIR)/usr/include/qca-ssdk{,/fal,/init}`，于是 qca-nss-ppe 报
   `fal/fal_rss_hash.h: No such file or directory`。修法：各包 `Build/Compile`
   同时传 `KCFLAGS="$(OPENWRT_KCFLAGS) $(EXTRA_CFLAGS)"`；`OPENWRT_KCFLAGS`
   在 `nss/include/local-development.mk` 里按 `include/kernel.mk` 的
   `KERNEL_MAKE_FLAGS` 原样重算（iremap + `CONFIG_EXTRA_OPTIMIZATION` +
   `CONFIG_KERNEL_CFLAGS`），避免命令行上后一个 `KCFLAGS=` 覆盖掉 OpenWrt 的。
   若上游改了 kernel.mk 那一行，此变量要同步。
2. **qca-ssdk 的 symvers 发布在 6.18 变成 0 字节**：厂商 mk/ 构建把
   `Module.symvers` 写在 `qca-ssdk/mk/`，`KernelPackage/hooks` 的
   `collect_module_symvers` 找 `$(PKG_BUILD_DIR)/./Module.symvers`；6.12 的 kbuild
   会在 PKG_BUILD_DIR 根再写一份（模块列是完整路径），6.18 只写在 mk/ 且模块列
   改为模块名，两种 grep 都落空 → `symvers/qca-ssdk.symvers` 为 0 字节，
   qca-nss-ppe modpost 报 196 个 `fal_*` 未定义。修法：qca-ssdk 的
   `Build/Compile` 在厂商 make 之后把 `mk/Module.symvers` 复制为
   `$(PKG_SYMVERS_DIR)/qca-ssdk-fal.symvers`（换名字，避免被 collect 的空文件
   覆盖；`KBUILD_EXTRA_SYMBOLS` 按 `*.symvers` 通配，名字无关）。
3. 厂商源码另有一处编译器告警升级：`ppe_drv_tun_prgm_prsr_gre.h` 的 header guard
   拼写不一致，GCC 15 默认 `-Wheader-guard` + 6.18 的 `-Werror` 直接报错，
   见 qca-nss-ppe 补丁 0026。

### 4.3 S3b/S3c 结果与新增补丁（2026-11-23 本机）

全部编译 EXIT=0，产物为 aarch64 `.ko`（dp/ppe/sfe/ecm）与对应 `.apk`；
均未选入镜像、未上机。

| 包 | 结果 | 产物 |
|---|---|---|
| qca-nss-dp | PASS | `qca-nss-dp.ko` |
| qca-nss-ppe（drv/ds/vp/rule） | PASS | `qca-nss-ppe.ko`、`qca-nss-ppe-ds.ko`、`qca-nss-ppe-vp.ko`、`qca-nss-ppe-rule.ko` |
| qca-nss-sfe | PASS | `qca-nss-sfe.ko` 2.3 MB，`kmod-qca-nss-sfe` apk 85.9K |
| qca-nss-ecm-standard | PASS | `ecm.ko` 5.8 MB，apk 262.6K（63 个对象，modpost 无 undefined） |
| qca-nss-ae-clients / debug / ssdk-shell | PASS（早前） | — |

6.18 删改的内核 API 与对应厂商补丁（`nss/patches/<pkg>/`，均由 install.sh
按序可重现）：

| 补丁 | 文件 | 问题 → 修法 |
|---|---|---|
| dp 0012 | `edma_ppeds.c/.h` | `init_dummy_netdev()` 变 static（只导出 `alloc_netdev_dummy(int sizeof_priv)`）→ 内嵌 `struct net_device` 改指针，`alloc_netdev_dummy(0)` + `free_netdev()` 收尾 |
| ppe 0024（重生成） | `ppe_ds.c` | `hrtimer_init()` 删除 → `hrtimer_setup(timer, cb, clock_id, mode)`；shim 增加回调形参，删除手工 `.function=` 赋值 |
| ppe 0028 | `ppe_vp_base.c`、`ppe_qdisc_stats.c` | `del_timer_sync()` 改名 → `timer_delete_sync()`（6.18 无旧名别名） |
| ppe 0029 | `ppe_ds.c/.h` | wlan 节点 `init_dummy_netdev()` → `alloc_netdev_dummy(0)`/`free_netdev()`（同 dp 0012） |
| sfe 0002 | `sfe_ipv6_frag.c` | `del_timer()` → `timer_delete()` |
| sfe 0003 | `sfe_ipv6_frag.c` | `from_timer()` 删除 → `timer_container_of()` |

内核侧新增导出（外层 `patches/0030-qualcommbe-export-udp-table.patch`，
内层 `patches-6.18/0514-net-ipv4-export-udp-table.patch`）：6.18 删掉了
`EXPORT_SYMBOL(udp_table)`（表本身仍在 `net/ipv4/udp.c:125`），sfe 的
`__udp4_lib_lookup()/__udp6_lib_lookup()` 调用使 modpost 报
`"udp_table" undefined`；补丁只加一行导出。注意：内核补丁改动会改变
`.prepared_<hash>` 戳名，构建系统会重建整棵内核树并重生成 `Module.symvers`，
之后 sfe/ecm 才能链接。

新增构建陷阱（第 3 条）：`KCONFIG:=` 非空的 kmod 包在 `CONFIG_PACKAGE_*`
未选时，`KernelPackage/<name>/compile` 会被替换成 `-disabled` 空目标——
表现为 `compile#0.0x` 秒、日志无任何 `CC [M]`（dp/ppe 无 KCONFIG，所以早前
未暴露；sfe/ecm 有）。复现编译时需临时把 `CONFIG_PACKAGE_kmod-qca-nss-*`
写进 `.config` **并跑 `make defconfig`** 解析依赖闭包（直接手写依赖符号会被
defconfig 丢弃），验证后恢复原 `.config`。本阶段验证即按此法（备份
`/tmp/config.before-s3c`），完成后已恢复。

## 5. S3d 方案：NSS DTS 与设备配置（未实施，下一步）

6.18 上游的板级 DTS（`target/linux/qualcommbe/dts/ipq9570-sbe1v1k.dts`，
含 mainline PPE 节点 `qcom_ppe`、真实 PHY/MDIO 接线，S1b 真机 PASS）是硬件
事实的基线；6.12 的 NSS DTS（`patches/0009/0011`，自带一套 RDP433 基线板文件）
只取其 QSDK 数据通路部分，不整份搬运。分三步：

1. **SoC 级 NSS 节点**（新文件 `dts/ipq9574-nss.dtsi`，从 6.12 的 572 行
   `ipq9574-nss.dtsi` 裁剪）：`ess-instance`/`ess-switch`（含端口调度表）、
   `edma@3ab00000`、`nss-ppe`。三者分别是 qca-ssdk（按名字
   `ess-instance`）、qca-nss-dp（`edma`）、qca-nss-ppe（`qcom,nss-ppe`
   兼容串）的运行期锚点，缺任何一节点驱动 init 直接 -EINVAL。
2. **NSS 板级变体**：在 6.18 已验证的板文件基础上 `#include "ipq9574-nss.dtsi"`、
   `/delete-node/ &qcom_ppe`（mainline PPE 的 `edma` 子节点会与
   `of_find_node_by_name(NULL,"edma")` 抢名，6.12 已踩过）、把 MDIO 从
   `reset-gpios` 补 `phy-reset-gpio`（ssdk 读后者的单数形式），并加入 QSDK
   交换机拓扑与 EDMA ring 布局（端口→PHY：2.5G QCA8081=WAN、10G RTL8261N
   + 2×1G QCA8075=LAN，与补丁 0001 的角色一致）。
3. **设备配置**：新增 NSS 设备变体（`DEVICE_PACKAGES` 选 `kmod-qca-ssdk-nohnat`、
   `kmod-qca-nss-dp/ppe/ppe-ds/ppe-vp/ppe-rule/phy/sfe/ecm-standard`、
   `qca-ssdk-shell`；`kmod-qcom-ppe` 不选）；移植 6.12 的运行期件：
   `files/etc/nss.conf`（tier=full 默认）、`/etc/init.d/nss`（S15）、
   `/usr/sbin/nss-load`（分档装载 + budget 回退）、
   `/usr/sbin/sbe-port-roles`（ssdk 成员表等价物；25.12 没有 `ssdk_sh`，
   `qca-ssdk-shell` 提供它，见 [[no-dsa-ssdk-portvlan-roles]]）；
   seed 与 `verify-image.sh` 同步 NSS 断言。

判据：本机 world 构建 + `verify-image.sh` 全 PASS，NSS 包入镜像但
mainline PPE 节点已删；设备侧（nss-load 日志、`/sys/ssdk`、加速计数）
留 S3e，需用户单独批准。风险：EDMA ring 布局与真实硬件不符会导致
首启网络不启动——diag/fallback 档（tier=wired/off）与 6.12 的
budget 回退机制原样移植，作为刷机兜底。

## 6. 已知难点（按 6.12 踩坑记录预判）

1. **`register_sysctl` 哨兵**（6.11+ 宏计入 `{}` 尾部哨兵）：6.12 用
   0025/0008 修过，6.18 需要同源修复，否则 ppe 拆除路径 oops。
2. **`dev_addr` / `eth_hw_addr_set`**：6.8+ 起 `dev->dev_addr` 只读，
   QSDK 6.6 源码里的直接赋值要改。
3. **`phylink` 与 `netif_carrier`**：6.18 的 phylink API 更严格，dp 的
   `ndo_open` 路径要审。
4. **时钟/复位**：6.18 的 `clk_parent_data`/`devm_clk_hw_get_clk` 用法；
   6.12 的 PCS 时钟父节点经验（[[nsscc-port5-pcs-clock-parents]]）。
5. **`netdev_ops` 签名**：`ndo_start_xmit` 返回 `netdev_tx_t` 不变，但
   `ndo_change_mtu`、`ndo_ioctl` 等在新版本有变化。
6. **qca8084 重名**（6.12 的 0030）：6.18 上游已无 qca8084 内置驱动冲突，
   但要复核 ssdk 是否还会注册同名 PHY。
7. **DMA 池对齐**：QSDK 的 NSS 缓冲池与 6.18 的 `dma_alloc_coherent`
   行为差异（[[ath12k-reserved-dma-pool-order-alignment]] 是 WiFi 侧同类问题）。

## 7. 不做的事

- 不在本阶段改动 6.18 的启动配置、不把 NSS 包选入镜像、不刷机。
- 不搬 6.12 的板级补丁（eMMC/PWM/OPP 等）——上游 6.18 已覆盖。
- 不删除 mainline PPE 兜底路径，NSS 验证通过前两者并存。
