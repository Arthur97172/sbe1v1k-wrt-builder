# 25.12-6.12 — Spectrum SBE1V1K 固件构建输入

OpenWrt 25.12（`openwrt-25.12`）+ 主线 Linux 6.12，目标板 `spectrum_sbe1v1k`
（IPQ9574）。**Stage 1** 是可编译基线（上游 `qualcommbe/ipq95xx`、`ipq9574-rdp433`、
主线 PPE 以太网 + ath12k）。**Stage 2.1–2.4** 已在本地把 QSDK 14.x 的 NSS
内核栈（qca-ssdk / nss-phy / nss-dp / nss-ppe / nss-debug）编进镜像，把
`DEVICE_DTS` 切到 `ipq9574-sbe1v1k`，并按厂商 QSDK 14 设备树补齐板级以太网
（MDIO 总线、PHY 地址、端口 bitmap、MAC 模式）。**Stage 2.5** 接入 ath12k：
驱动用上游 backports 6.18.55，固件/板级数据来自厂商 QSDK 14 镜像
（`sbe-wifi-firmware` 本地包）；NSS Wi-Fi offload 仍未接入。**Stage 2.6**
补上每台设备各自的校准数据：镜像内 `sbe-wifi-cal` 在 ath12k 加载前从本机
eMMC `0:ART` 生成 `cal-pci-*.bin`。CI 产物与本机构建一样带厂商固件
（2026-10-24 决定，见下文“固件 blob 与公开仓库”）；全部真机行为仍为
`NOT TESTED` / `UNVERIFIED`。

与 `24.10-6.6/` 不同，本目录不需要源码包：上游源码 + 官方 feeds + 本项目补丁
即可装配出完整构建树，CI 全流程可复现（见 `scripts/ci/prepare-tree.sh` 里固定的提交）。

## 目录

```
25.12-6.12/
├── build/                    构建输入
│   ├── sbe1v1k-build.sh      构建入口（定位 sources/、渲染 overlay、固定时钟、调 make）
│   ├── host-shims.txt        宿主机工具清单（host-bin 软链按它重建）
│   ├── deterministic-bin/    date 垫片（固定 SOURCE_DATE_EPOCH）
│   ├── config-seed/          defconfig 种子
│   └── local-packages/       项目自带软件包
│       ├── sbe1v1k-defaults/ 首启默认值（ttyd 默认关闭）
│       └── sbe-wifi-firmware/ Stage 2.5：QCN92XX 固件 / board-2.bin / regdb / bdf41（专有 blob，LICENSE_REVIEW_REQUIRED）
├── files/                    固件 overlay（唯一来源，构建时渲染进装配树）
│   ├── etc/banner                /etc/banner，`%V`/`%R` 由渲染脚本替换
│   ├── etc/uci-defaults/99-wireless-defaults   首启入口（boot 以 source 执行）
│   ├── etc/init.d/wireless-defaults            每次开机执行（START=95）
│   └── usr/lib/sbe1v1k/wireless-defaults       实际逻辑（UCI marker 幂等）
├── patches/                  对上游 25.12 的补丁（0001 设备；0002-0007 Stage 2.1；0008-0009 Stage 2.2；0010 Stage 2.3；0011-0012 Stage 2.4）
│   ├── 0001-qualcommbe-add-spectrum-sbe1v1k.patch
│   ├── 0002-qualcommbe-add-swconfig-ext-for-qca-ssdk.patch
│   ├── 0003-qualcommbe-export-br-fdb-delete-by-netdev.patch
│   ├── 0004-qualcommbe-ipq95xx-enable-swconfig.patch
│   ├── 0005-qualcommbe-add-netstandby-uapi-header.patch
│   ├── 0006-qualcommbe-export-dmac-cache-helpers.patch
│   ├── 0007-qualcommbe-export-saved-command-line.patch
│   ├── 0008-nat46-install-module-headers.patch
│   ├── 0009-qualcommbe-add-sbe1v1k-nss-dts.patch
│   ├── 0010-qualcommbe-sbe1v1k-select-nss-dts.patch
│   ├── 0011-qualcommbe-sbe1v1k-board-ethernet-from-qsdk14.patch
│   └── 0012-qualcommbe-sbe1v1k-mainline-fallback-device.patch
├── nss/                      QSDK 14.x NSS 接入件（Stage 2.1–2.2，本地实验）
│   ├── install.sh            把 packages/、源码和 patches/ 装配进构建树
│   ├── packages/             qca-ssdk、qca-nss-phy、qca-nss-dp、qca-nss-ppe、qca-nss-debug 的包定义
│   ├── patches/              按包分开的 6.12 可移植性补丁
│   └── nss-src.tar.gz.sha256  CI 自产 NSS 源码包的校验值（见下）
└── scripts/
    ├── render-overlay.sh     把 files/ 整体复制进装配树并替换版本占位符
    ├── local/
    │   └── build-wifi-image.sh  本机一键出带厂商固件的镜像（CI 下拒绝运行）
    └── ci/
        ├── prepare-tree.sh   仅 CI：克隆上游、钉定 feeds、应用补丁、装本地包、装配 NSS
        ├── export-nss-src.sh 打包 NSS 源码（ISC，仅源码），CI 自产时由 prepare-tree.sh 调用
        └── verify-image.sh   从最终 sysupgrade 镜像解出 rootfs 做静态校验
```

## 与上游的差别

`patches/0001-qualcommbe-add-spectrum-sbe1v1k.patch` 只做两件事：

1. `target/linux/qualcommbe/Makefile` 增加 `pwm` 特性（`kmod-leds-pwm` 依赖 `PWM_SUPPORT`）；
2. `target/linux/qualcommbe/image/ipq95xx.mk` 增加 `Device/spectrum_sbe1v1k`：

   - `DEVICE_IMG_PREFIX := sbe1v1k` 与 `KERNEL_SUFFIX := -fit-uImage.itb`
     → 三个交付物分别是 `sbe1v1k-squashfs-sysupgrade.bin`、
     `sbe1v1k-fit-uImage.itb`、`sbe1v1k-initramfs-fit-uImage.itb`；
   - `DEVICE_DTS := ipq9574-rdp433`（Stage 1 复用上游 RDP433 设备树）；
   - 自带 `kmod-leds-pwm`、`kmod-hwmon-pwmfan`。

   `Device/Init` 在设备定义体之前执行，因此设备体内覆盖
   `DEVICE_IMG_PREFIX` / `KERNEL_SUFFIX` 才会生效，这也是文件名可控的原因。

## Stage 2.1–2.2：QSDK NSS 包接入（本地编译实验）

`nss/install.sh` 把下列内容装配进 `sources/buildroot-25.12-6.12`：`include/local-development.mk`、
`package/feeds/nss/<pkg>`、`qca/src/nss/base/<pkg>`（从 `sources/buildroot` 厂商树复制），
随后对源码应用 `nss/patches/<pkg>/*.patch`。因此在改动源码后必须
`package/<pkg>/clean` 再编译，否则 `PKG_BUILD_DIR` 里的旧副本不会更新。

包的 `DEPENDS` 必须用 25.12 的板型符号 `TARGET_qualcommbe_ipq95xx`。厂商写的是
自己的 `TARGET_ipq95xx`/`TARGET_ipq53xx`…（厂商 target 名），这些符号在本树里
不存在，条件恒假 → 包在 `defconfig`/menuconfig 里不可选，`DEVICE_PACKAGES`
也就拉不进来（`qca-nss-ppe`、`qca-nss-debug` 已改，`qca-nss-dp` 早已改）。
症状是镜像 manifest 里没有 `kmod-qca-nss-*`。

另外要注意构建步骤的粒度：`package/<目录>/compile` 只编 `.config` 里**选中**的
子包，所以它只跑出源码与 InstallDev，不产出 kmod apk；`target/install` 也不
负责往 rootfs 装包。正确的出镜像顺序是 `package/install`（按 `.config` 的
`package-y` 与依赖解析安装）→ `target/install`（打包镜像），即 `world` 的后半段。

`qca-nss-dp` 的 `DEPENDS` 里必须带 `+kmod-qca-nss-ppe`。本项目的 dp 开了
`dp-ppe-ds=y`，`nss_dp_attach.c` 直接 include `<ppe_drv_public.h>` 并引用
`ppe_drv_*` 符号，而这些头文件由 `qca-nss-ppe` 的 `Build/InstallDev` 装进
`staging_dir/usr/include/qca-nss-ppe`。厂商 Makefile 只依赖 `kmod-qca-ssdk`，
于是两者在同一个 `make -j package/compile` 里并行，dp 会抢在 ppe 装头文件之前
编译，报 `ppe_drv_public.h: No such file or directory`。加上这条依赖后
`package/compile` 退出码为 0，dp 的 `.ko` 里 `depends=qca-ssdk,qca-nss-ppe`
也能正确生成（内核态符号依赖在运行时同样成立）。

`nss/include/local-development.mk` 决定这些包的 `PKG_VERSION`。厂商原版把
`git describe` 的短 sha 拼成 `g<sha>`，在 25.12 上不可用：apk 3 要求版本串的
每个点分段都以数字开头，`6.12.112.g…-r1` 会被判为 `package version is invalid`；
而且 `sbe1v1k-build.sh` 导出的 `GIT_CEILING_DIRECTORIES=<工作区>/sources` 使
装配树里的 `git describe` 直接失败，值退化成孤立的 `g`。本项目版本因此**不写**
`PKG_VERSION`，kmod 版本与树内其他 kmod 一致，是 `6.12.112-r1`；
代价是 `PKG_BUILD_DIR` 没有 `-g<sha>` 后缀，从旧装配树升级时要先 `clean`。

| 包 | 6.12 补丁数 | 状态 |
|----|------------|------|
| `qca-ssdk`（nohnat） | 12 | `qca-ssdk.ko` 编译通过 |
| `qca-nss-phy` | 8 | `qca-nss-phy.ko`、`qcom-lnx-phy.ko` 编译通过 |
| `qca-nss-dp` | 7 | `qca-nss-dp.ko` 1,490,744 B，modpost 0 未定义 |
| `qca-nss-ppe` | 20 | `qca-nss-ppe.ko` 编译通过（4.4 MB），导出 242 个 `ppe_drv_*` |

`qca-nss-dp` 引用 30 个 `ppe_drv_*` 符号，由 `qca-nss-ppe` 提供。符号不经过
内核的 `Module.symvers`，而是走 `include/kernel.mk` 的
`KBUILD_EXTRA_SYMBOLS="$(wildcard $(KERNEL_BUILD_DIR)/symvers/*.symvers)"`
机制，因此：

- **`qca-nss-ppe` 必须先于 `qca-nss-dp` 编译**；
- `target/linux/compile`（内核重编）会清空 `build_dir/.../linux-<board>/`，
  连带删掉 `symvers/qca-nss-ppe.symvers`，重编内核之后 `qca-nss-dp` 会重新变成
  30 个未定义——必须先把 ppe 编回来。

`saved_command_line`（`patches/0007`，QSDK 内核导出、主线不导出）已在
2026-10-24 的内核重编中进入 `Module.symvers`，`qca-nss-dp` 链接通过。

### 板级 DTS

`patches/0009` 在 `target/linux/qualcommbe/files/arch/arm64/boot/dts/qcom/`
加入两个文件（由 quilt 的 kernel prepare 阶段拷进 `$(LINUX_DIR)`）：

- `ipq9574-nss.dtsi`：QSDK 14.x 的 SoC 级 NSS 节点（`ess-instance`/`ess-switch`、
  `edma@3ab00000`、`nss-ppe`），三个驱动分别按名字或 compatible 查找；
- `ipq9574-sbe1v1k.dts`：板级文件，主线 RDP433 的硬件基线 + QSDK RDP433 的
  交换机拓扑与 EDMA 环形配置，并 `/delete-node/ &qcom_ppe;`（同址冲突 +
  主线子节点也叫 `edma`，会让 `of_find_node_by_name(NULL, "edma")` 找错）。

Stage 2.2 结束时 `DEVICE_DTS` **仍指向** `ipq9574-rdp433`：新 DTS 删掉了主线 PPE
节点，镜像里若没有 NSS kmod 配套会完全没有以太网，所以 DTS 切换与
`DEVICE_PACKAGES` 打包必须同批完成。

### 板级 DTS 的 eMMC 控制器

`patches/0021` 给 `ipq9574-sbe1v1k.dts` 加 `&sdhc_1` 块（引用文件里已有但一直
没人用的 `sdc_default_state` 引脚配置，属性与 `ipq9574-rdp418.dts` 和厂商 DTB
相同）。上游 `ipq9574.dtsi` 里 `sdhc_1` 是 `disabled`，不启用时内核没有
`/dev/mmcblk0`，U-Boot 注入的 `root=PARTUUID=<uuid>` 无法解析，真机刷入后无法
启动。`scripts/ci/verify-image.sh` 会反编译编出的 DTB 断言 `mmc@7804000` 为
`okay`，并确认该 DTB 逐字节存在于两个交付 FIT 中。注意 eMMC 能起来不等于能
升级：写入目标见下一节（`patches/0022`），真机升级状态仍是 `NOT TESTED`。

### 升级（sysupgrade）与 A/B 槽位（`patches/0022`）

板子是 QSDK 的 eMMC A/B 布局：SBL 在 `0:BOOTCONFIG` / `0:BOOTCONFIG1` 之间选
一组，每组指向 `0:HLOS` + `rootfs` 或 `0:HLOS_1` + `rootfs_1`，U-Boot 再按选中的
那组注入 `root=PARTUUID=…`。本补丁之前，`spectrum_sbe1v1k` 落到
`default_do_upgrade` → `mtd write - image`，而板上没有名为 `image` 的 MTD 分区，
**升级什么也不会发生**（固件照样重启回旧系统）。

三处改动：

1. **镜像格式**（`target/linux/qualcommbe/image/ipq95xx.mk`）：

   ```make
   IMAGES := sysupgrade.bin
   IMAGE/sysupgrade.bin/squashfs := append-rootfs | pad-to 64k | \
       sysupgrade-tar rootfs=$$$$@ | append-metadata
   ```

   （`$$$$@` 是 `Device/Init` 里 `IMAGE_CMD` 的两级转义，与 `Device/EmmcImage`
   逐字相同。）

   与 `Device/EmmcImage` 相同的 tar 容器
   （`sysupgrade-spectrum_sbe1v1k/{CONTROL,kernel,root}`），但不产出
   `factory.bin`——发布资产固定三个。原布局（内核 + `pad-to 64k` + 根文件系统）
   只有厂商的 mtd/dumpimage 流程认得，`emmc_upgrade_tar` 读不了。`pad-rootfs`
   也去掉了：它调用 `padjffs2`，会往 squashfs 后面追加 JFFS2 EOF 标记。

2. **升级脚本**（`target/linux/qualcommbe/ipq95xx/base-files/lib/upgrade/platform.sh`
   的 `spectrum,sbe1v1k` 分支）：写回**当前正在运行的槽位**，不碰 bootconfig。
   - 槽位探测：`/rom`（squashfs 下层挂载点）→ `/proc/self/mountinfo` 第 5 字段
     `/rom` 对应的 `major:minor` → `/sys/dev/block/<maj>:<min>/uevent` 的
     `PARTNAME`；`rootfs`→`0:HLOS` + `rootfs`，`rootfs_1`→`0:HLOS_1` + `rootfs_1`，
     其他值一律拒绝写入（fail closed）。本内核没有
     `CONFIG_BOOTCONFIG_PARTITION`，没有 `/proc/boot_info`，`root=PARTUUID=…`
     也反查不到槽位，所以只能从正在运行的根文件系统本身判断。
   - stage2 在调 `platform_do_upgrade` 之前 pivot 到 ramfs，`/rom` 随即消失；
     因此 `platform_pre_upgrade`（pivot 之前）把结论写进
     `/tmp/.sbe_upgrade_slot`，pivot 时 `/tmp` 被整体移进新根，文件不会丢。
   - 写之前比大小：`kernel` 段不得大于 `0:HLOS`，`root` 段不得大于 `rootfs`
     且尾部至少留 8 MiB（overlay 就地建在 rootfs 分区尾部；1 MiB 也能格式化，
     但一写就满变只读，闸门故意设得比最小值高）。
   - 判断成立后设 `CI_KERNPART`/`CI_ROOTPART` 并调用 `emmc_do_upgrade` →
     `emmc_upgrade_tar`：先清零内核前 8 个扇区（写入期间不留下可启动的旧内核），
     写 root，再把块数按 64 KiB 对齐，最后写内核。配置备份由
     `platform_copy_config` → `emmc_copy_config` 写回新根文件系统尾部。
   - 其他板子的分支原样保留（`8devices,kiwi-dvk` 与 `default_do_upgrade`）。

3. **`rootfs_data` 模型**（`ipq9574-sbe1v1k.dts` 的 `chosen`）：加
   `bootargs-append = " fstools_ignore_partname=1"`，与厂商产品 DTB（S1）一致。
   不传这个选项时 fstools 会去挂 GPT 里那个 `rootfs_data` 分区，overlay 就跑到
   升级不写的分区里；传了以后 overlay 在 `rootfs` 分区尾部，跟着根文件系统一起
   被替换。`bootargs-append` 由 `target/linux/generic/hack-6.12/920-device_tree_cmdline.patch`
   提供：U-Boot 注入的 `bootargs`（含 `root=PARTUUID=…`）之后拼接这一段。

CI 断言：`prepare-tree.sh` 在编译前检查镜像配方是 tar、升级脚本有
`sbe_detect_slot` 与 `spectrum,sbe1v1k` 分支、设备树带
`fstools_ignore_partname=1`；`verify-image.sh` 再从最终镜像里取 tar 段、比对
`kernel` 段与发布的 FIT、反编译 DTB 查 `chosen`、并把镜像里的
`/lib/upgrade/platform.sh` 与装配树逐字节比对。

本地增量构建要注意：`package/base-files/Makefile:18` 的 `PKG_FILE_DEPENDS` 只登记
了 `$(GENERIC_PLATFORM_DIR)/base-files/`，**不含**本子目标的
`target/linux/qualcommbe/ipq95xx/base-files/`；而且 `target/install` 只重建内核
镜像，不会重新把包合并进 rootfs。改过这里的文件之后要跑

```sh
make package/base-files/clean
make package/base-files/compile
make package/install target/install
```

否则镜像里留的还是旧版本（`verify-image.sh` 第 9 项会以 FAIL 指出）。CI 每次
都是新树、走 `world`，不受影响。

**就地写当前槽位**是有意选择：不读也不写 bootconfig，下一次启动读到的一定是
同一对物理分区，行为确定；代价是写入期间断电会毁掉正在运行的这一槽（另一槽
仍在，但 bootconfig 不改就不会回退）。厂商固件写另一槽再切 bootconfig 的做法
需要改写 U-Boot 环境，而本内核没有 `/proc/boot_info` 可用，静态审计也无法确认
环境变量的存放位置，故不采用。

真机验证状态：**`NOT TESTED`**（第 3 阶段，需单独批准 + 现场密码）。

### Stage 2.3：设备定义切到 NSS 设备树

`patches/0010` 把 `Device/spectrum_sbe1v1k` 一并改成：

```make
DEVICE_DTS := ipq9574-sbe1v1k
DEVICE_DTS_CONFIG := config@rdp433
DEVICE_PACKAGES := kmod-leds-pwm kmod-hwmon-pwmfan \
		   kmod-qca-ssdk-nohnat kmod-qca-nss-dp kmod-qca-nss-ppe
```

- `DEVICE_DTS_CONFIG` 是 **FIT 配置节点名**，不是 DTS 文件名（`Device/FitImage`
  把它写成 `configurations/default = "<该值>"`），因此保持 `config@rdp433` 不变；
  改它只会改变 FIT 内部的节点名，与 DTS 文件无关。
- `DEVICE_PACKAGES` 只在镜像构建期生效，不写进 `.config`——`.config` 里查不到
  `CONFIG_PACKAGE_kmod-qca-nss-ppe` 属正常，要看 `tmp/.targetinfo` 的
  `Target-Profile-Packages`。
- `build/config-seed/ipq95xx-spectrum-sbe1v1k.seed` 同时显式关闭 `kmod-qcom-ppe`
  （qualcommbe 默认选中），把 `CONFIG_QCOM_PPE` 从内核配置里去掉：该驱动绑定
  的 `qcom,ipq9574-ppe` 节点已被新 DTS 删除。

本地出图顺序与结果（2026-10-24，`package/compile` → `package/install` →
`target/install` 均退出 0）：

- manifest 共 158 个包，含 `kmod-qca-ssdk-nohnat`、`kmod-qca-nss-{phy,dp,ppe,debug}`、
  `kmod-nat46`、`kmod-qca-{mdio,8084,8k-cc}`，且**不含** `kmod-qcom-ppe`；
- 从 `sbe1v1k-squashfs-sysupgrade.bin` 解出的 rootfs 里，
  `qca-nss-dp.ko` 的 `.modinfo` 是 `depends=qca-ssdk,qca-nss-ppe`，
  `qca-nss-ppe.ko` 是 `depends=qca-ssdk`，加载顺序由 kmodloader 按依赖解析；
- 从 `sbe1v1k-fit-uImage.itb` 解出的 DTB 与
  `build_dir/.../image-ipq9574-sbe1v1k.dtb` 字节一致（sha256 `63e72a4d…d7b42fd`），
  含 `ess-instance`/`ess-switch@3a000000`/`edma@3ab00000`/`nss-ppe`/`dp1`–`dp6`，
  不含 `ethernet@3a000000` 与 `qcom,ipq9574-ppe`；
- FIT 默认配置仍是 `config@rdp433`（节点名，与 DTS 文件无关）。

`prepare-tree.sh` 按文件名排序，把 `patches/*.patch` 用 `patch -p1` 应用到
**装配树根**。其中多数补丁并不直接改内核源码，而是把内核补丁投放到
`target/linux/qualcommbe/patches-6.12/`，再由 OpenWrt 的 kernel prepare 阶段应用
（项目编号 → 投放后的内核补丁编号）：

- `0002` swconfig `switch_ext` 支持（qca-ssdk 需要）→ `0139`；
- `0003` 导出 `br_fdb_delete_by_netdev`（qca-ssdk 需要）→ `0140`；
- `0005` 加入 QSDK 的 uapi `linux/netstandby.h` → `0142`；
- `0006` 导出 QSDK 的 `dmac_*` 缓存维护函数（qca-nss-dp 需要）→ `0143`；
- `0007` 导出 `saved_command_line`（qca-nss-dp 读取 `mem-profile=` 启动参数）→ `0144`。

另外几个直接改构建树中的文件：`0004` 在 `target/linux/qualcommbe/ipq95xx/config-default`
打开 `CONFIG_SWCONFIG`，`0001` 改 `qualcommbe/Makefile` 与 `image/ipq95xx.mk`，
`0008` 给 `package/kernel/nat46` 加 `Build/InstallDev`（qca-nss-ppe 的隧道路径
需要 `<nat46/nat46-*.h>`），`0009` 新增两个板级 DTS（见上一节）。
`0010` 改 `image/ipq95xx.mk` 的 `Device/spectrum_sbe1v1k`（见上一节）。
`0011` 重写 `ipq9574-sbe1v1k.dts` 的以太网部分（见下一节），`0012` 在
`image/ipq95xx.mk` 增加可选的 mainline 回退 profile。
`0141`（mdio-bitbang 原始访问钩子）是本地装配树里已有的内核补丁，不属于这套项目补丁。

### Stage 2.4：板级以太网（MDIO / PHY / 端口 / MAC 模式）

真值来源按代际取舍：

| 证据 | 文件 | 代际 | 用途 |
|------|------|------|------|
| S2（主） | `extracted/qsdk14/sbe1v1k-askey.dtb` | QSDK 14 / 6.6.116 | 与本树驱动同代，PHY、端口、MAC 模式全取自此 |
| S1（参照） | `extracted/kernel/sbe1v1k.dtb` | QSDK 13 / 6.6.47 | PHY 地址与 MAC 模式一致，`switch_*_bmp` 不同 |
| NET（裁决） | 厂商 rootfs `etc/board.d/01_network` | — | `eth1 eth2 eth3` = LAN、`eth0` = WAN，与 S2 一致 |

板级拓扑（`0011`）：QCA8075 四口封装（QSGMII）在 switch port 1–4，QCA8081 2.5G
在 port 5（SGMII），RTL8261N 10G 在 port 6（USXGMII/C45）。`switch_lan_bmp` 因而是
`0x38`（BIT(3..5)）、`switch_wan_bmp` 是 `0x40`（BIT(6)），S1 的 `0x58`/`0x20` 被否决。

`nss-dp` 按 DT 顺序 probe 并用 `alloc_etherdev_mqs()` 依次取 `eth%d`，所以 DTS 里
`dp1`–`dp4` 的顺序就是 `eth0`–`eth3`：`eth0` = port 6（WAN），`eth1`/`eth2`/`eth3`
= port 5/3/4（LAN），与 NET 完全对齐。`mactype` 1 是 Synopsys XGMAC（port 6 的
`0x3a514000`），0 是 1G GMAC。每个 dp 节点**不写** `phy-mode`：这样
`of_get_phy_mode()` 失败会打开 phylink 路径，由 `qcom,port_phyinfo` 提供
interface 与 `phy-handle`（S2/RDP 的做法；S1 的逐节点 `phy-mode` 属于旧驱动）。

三个关键接线：

1. **MDIO 总线用 phandle 显式接。** `ssdk_dt_parse_mdio_node()` 先看 port 的
   `mdiobus`、再看 switch 的 `mdio-bus`、最后才按 compatible 扫描
   `qcom,ipq40xx-mdio`/`qcom,qca-mdio`。主线上游节点是
   `qcom,ipq9574-mdio`,`qcom,ipq4019-mdio`，两个串都不匹配，所以写
   `mdio-bus = <&mdio>`；不能改 compatible，那会遮蔽 `mdio-ipq4019` 驱动自身的匹配。
   同理 `kmod-qca-mdio`（`mdio-ahb.ko`）只匹配 `qcom,mdio-ahb-ipq52xx`，在 IPQ9574
   上不提供总线，真正注册 `mii_bus` 的是内建的 `mdio-ipq4019`（`CONFIG_MDIO_IPQ4019=y`）。
2. **两个 reset 分开归属。** `ssdk_dt_parse_phy_info()` 读的是 `phy-reset-gpio`
   （单数）且只消费 index 0，所以 QCA8075 的 `tlmm 60` 排第一；RTL8261N 的
   `tlmm 52` 同时写进 `phy-reset-gpio`（保持 S1/S2 属性）并作为 `reset-gpios`
   挂到 `ethernet-phy@0`，由 phylib 持有。
3. **QCA8075 用 `qsgmii` 而不是 `psgmii`。** 主线 `qca807x.c` 要求
   `phydev->interface == package_mode` 才下发 package mode；S2 是 QSGMII，
   `switch_mac_mode = <0xb>` 与之对应（`enum ssdk_port_wrapper_cfg`，
   `qca-ssdk/include/init/ssdk_init.h:129`）：`0xb` QSGMII、`0xf` SGMII channel 0、
   `0xd` USXGMII。

`ess-uniphy@7a00000` 覆盖主线 `ethernet-pcs@7a00000/7a10000/7a20000` 的
寄存器窗口，因此 `ess-uniphy` 保留、三个 `pcs` 节点置 `disabled`
（`CONFIG_PCS_QCOM_IPQ9574` 未启用；将来若要启用会与 qca-ssdk 抢同一段寄存器）。

S2 里的 `port_ledinfo`、`port_mac_sel` 没有抄：本树 qca-ssdk 虽能解析，但厂商
这两个属性与 PHY 固件行为耦合，缺少硬件证据，留作 `UNVERIFIED`；板级 MAC 仍由
`eth_hw_addr_random()` 生成（DTS 无全零之外的 `local-mac-address`）。

**真机回退 profile**（`0012`）：`Device/spectrum_sbe1v1k_mainline` 用主线 RDP433
设备树 + `kmod-qcom-ppe`，产物前缀 `sbe1v1k-mainline`（不与三个交付名冲突），
默认**不选**、CI 也不构建：

```sh
echo 'CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_spectrum_sbe1v1k_mainline=y' >> .config
```

该 profile 目前只通过 profile 解析（`tmp/.targetinfo`、`defconfig`、
`target/install` 均可），**自身未编译、未上机 → `NOT TESTED`**。

以太网以外的板级描述（PCIe 槽、NOR/NAND 布局、LED/按键）仍沿用 RDP433，
状态 `UNVERIFIED`。

### Stage 2.5：ath12k 无线（厂商固件 / 板级 BDF）

真值来源：

| 证据 | 文件 | 用途 |
|------|------|------|
| V1 | `extracted/rootfs-qsdk14/lib/firmware/ath12k/QCN92XX/hw1.0/` | 厂商实际加载的 `firmware-2.bin`、`board-2.bin`、`regdb.bin` |
| V2 | `extracted/rootfs-qsdk14/usr/share/sbe-wifi/bdf41/` | board-id 1/2/4 的 BDF |
| V3 | `extracted/rootfs-qsdk14/etc/sbe-wifi-inputs.sha256` | 厂商完整性清单，与本项目 `FILES-SHA256` 逐条一致 |
| U1 | 25.12 的 mac80211 包 = backports **6.18.55** | `0x1109` → `qcn9274 hw2.0`，目录 `ath12k/QCN9274/hw2.0/` |
| U2 | 上游 `ath12k/{core,qmi}.c` | `board-2.bin` 变体选择、`cal-*`/`caldata.bin` 回退 |

驱动沿用上游 ath12k，不引入厂商分支；固件沿用厂商 blob，只把目录名从
`QCN92XX/hw1.0` 改成上游 hw 表要求的 `QCN9274/hw2.0`（字节不变）。六个文件
的 SHA-256 记录在 `build/local-packages/sbe-wifi-firmware/files/FILES-SHA256`，
并由包的 `Build/Prepare` 校验。

`board-2.bin` 内含三个变体，名称与数据分别是
`qmi-board-id=1/2/4`，其 data 与 `bdf41/b1.bin`、`b2.bin`、`b4.bin`
**逐字节相同**。上游通过 QMI 读取 board-id 后直接选中对应 BDF，
`/usr/share/sbe-wifi/bdf41/` 只是厂商 ART 校验脚本的输入，上游驱动不用。

**校准数据不在镜像内**：厂商 `cal-pci-*.bin` 是指向 `/tmp/sbe-caldata` 的
悬空链接，由 init 脚本在启动时从 eMMC `0:ART`（`mmcblk0p20`，start 37410、
2048 扇区）按 `dd bs=512 skip=708/1108/1508 count=360` 生成（每个 184,320 B，
并做 XOR16 = `0xFFFF` 校验）。上游 ath12k 只找
`cal-pci-<domain:bus:dev.fn>.bin` 或回退 `caldata.bin`，两者都没有时
probe 失败。因此本阶段镜像“有驱动、有固件、有 BDF”，但真机首启出无线
仍需一个 ART 提取步骤 → 该项 `BLOCKED`，硬件行为 `NOT TESTED`。

NSS Wi-Fi offload（`qca-nss-wifi-plugins` / `qca-wifi-nss-plugins`）以及厂商
ath12k 的私有模块参数（`mlo_capable`、`cold_boot_cal`、`ppe_ds_enable` 等）
本阶段 `NOT SUPPORTED`：装配树里没有这些包，也没有厂商 ath12k 分支。

本地编译与镜像静态校验 `PASS`（`world` rc=0；187 个包；两次出图 sha256
完全相同；`verify-image.sh` 全 PASS）。真机驱动加载/校准 `NOT TESTED`，
校准数据来源 `BLOCKED`，NSS Wi-Fi offload `NOT SUPPORTED`。

blob 授权状态仍为 `LICENSE_REVIEW_REQUIRED`（项目决策 N-3）：权利复核尚未
完成，但用户已于 2026-10-24 明确接受公开分发风险。详见
`docs/S25_WIFI_ATH12K_REPORT.md`。

### 固件 blob 与公开仓库（2026-10-24 决定）

本仓库是**公开**的，6 个 Wi-Fi 固件文件是厂商专有二进制
（`LICENSE_REVIEW_REQUIRED`）。2026-10-24 的决定是：**公开 CI 镜像也带
这些 blob**。因此：

- 6 个 blob **入库**：`.gitignore` 不再排除
  `build/local-packages/sbe-wifi-firmware/files/**/*.bin`；`Makefile`、
  `files/FILES-SHA256`、`LICENSE-STATUS` 与 blob 一起提交。
- **CI 构建的镜像带无线固件**：workflow 在 Configure 步骤断言种子里的
  `CONFIG_PACKAGE_sbe-wifi-firmware=y` 在 `defconfig` 之后仍然生效，并在
  构建前用 `sha256sum -c FILES-SHA256` 校验 blob；`verify-image.sh` 再断言
  镜像内 6 个文件与仓库逐字节一致、`sbe-wifi-firmware` 已安装。
- 权利状态没有因为分发而改变：仍是 `LICENSE_REVIEW_REQUIRED`。若将来要求
  撤回公开分发，恢复 `.gitignore` 里注释掉的那一行，并把 workflow 的
  Configure 步骤改回“关闭 + 双重断言”。

CI 镜像与本地镜像的差别只剩来源（CI 从提交内容构建），无线能力一致。

### 启用无线（Stage 2.6）

CI 与本机构建的镜像都带 ath12k 驱动、hostapd/wifi-scripts、6 个厂商固件
文件和校准生成器，刷机后无需手工投递。开机时 `S09sbe-wifi-cal` 会在
`S10boot` 调用 `/sbin/kmodloader` 之前从 ART 生成三份 `cal-pci-*.bin`，
ath12k 即可 probe。

如果用的是旧的无固件镜像，或只想临时补文件，可以手工投递：

```sh
ssh root@<router-ip> 'mkdir -p /lib/firmware/ath12k/QCN9274/hw2.0'
cd build/local-packages/sbe-wifi-firmware/files
scp lib/firmware/ath12k/QCN9274/hw2.0/{firmware-2,board-2,regdb}.bin \
    root@<router-ip>:/lib/firmware/ath12k/QCN9274/hw2.0/
ssh root@<router-ip> reboot
```

说明：

- `bdf41/{b1,b2,b4}.bin` 只有厂商脚本用它做 ART 校验；上游 ath12k 从
  `board-2.bin` 里按 QMI board-id 选 BDF（S2.5 已核实三个变体与 bdf41 逐字节
  相同），因此**不需要**放进固件目录。
- 校准是每台设备自己的数据，从本机 `mmcblk0p20`（`PARTNAME=0:ART`）读取；
  校验规则与厂商一致：读 360 个扇区、前 `bdf_size` 字节 XOR16 == 0xFFFF、
  其后填充只能是 `0x00`/`0xFF`。任何一张卡不通过就整体失败，不会写入坏数据。
- 首次开机时如果固件不在（例如旧镜像），S09 会直接跳过；放好文件后重启
  再生成即可。

## Stage 1 已知限制（未在真机验证，状态 `UNVERIFIED`）

- 设备树沿用 RDP433（NOR+NAND 布局）；真实板使用 eMMC。升级已改成 tar 容器 +
  按当前槽位写 `0:HLOS` / `rootfs`（`patches/0022`，见“升级与 A/B 槽位”），
  但分区名、分区大小与槽位映射都来自厂商镜像的静态审计，真机 `NOT TESTED`。
- 以太网已由 Stage 2.1–2.4 换成 QSDK NSS-dp（主线 PPE 节点被删除），但
  端口/PHY 行为尚无真机观测。
- 无线为 ath12k 上游驱动（Stage 2.5 起带厂商固件与板级 BDF），无 QSDK NSS
  Wi-Fi 插件；每台设备的校准数据来自 eMMC `0:ART`，镜像内没有，首次上机前
  仍需补一个 ART 提取脚本（见 Stage 2.5）。
- 板级细节中只有 LAN/WAN 端口映射在 Stage 2.4 补上（依据厂商 QSDK 14 DTB）；
  PWM LED/风扇、板级 MAC、LED/按键仍沿用 RDP433。

因此 Stage 1 产物只用于确认“25.12 + 6.12 能为本板编译出正确命名的镜像”，
**在 Stage 2/3 完成前不要刷入设备**。

## 本机构建

装配树位于 `<工作区>/sources/buildroot-25.12-6.12`。

```sh
cp 25.12-6.12/build/config-seed/ipq95xx-spectrum-sbe1v1k.seed \
   sources/buildroot-25.12-6.12/.config
./25.12-6.12/build/sbe1v1k-build.sh defconfig
./25.12-6.12/build/sbe1v1k-build.sh world -j"$(nproc)"
./25.12-6.12/scripts/ci/verify-image.sh
```

本地构建（与 CI 相同判据）用下面这条（固件已在种子里打开；脚本会先校验
6 个 blob，再构建并跑 verify，末尾打印三个产物的 sha256）：

```sh
./25.12-6.12/scripts/local/build-wifi-image.sh
```

镜像含专有固件（`LICENSE_REVIEW_REQUIRED`，项目决策 N-3）；按 2026-10-24
的决定随构建产物公开分发。

NSS 源码：本机若已有厂商树 `sources/buildroot/qca/src/nss/base`，`nss/install.sh`
直接用它；CI 没有厂商树，从钉定的 QSDK 基座稀疏检出同一目录、现场重打并校验
`nss-src-v1`（见下）。

产物在 `sources/buildroot-25.12-6.12/bin/targets/qualcommbe/ipq95xx/`，只交付三个文件：

- `sbe1v1k-squashfs-sysupgrade.bin`
- `sbe1v1k-fit-uImage.itb`
- `sbe1v1k-initramfs-fit-uImage.itb`

## CI

`.github/workflows/build-25.12-6.12.yml`（`name: 📦 Build 25.12-6.12`）在 `main` 分支上，
`.github/workflows/build-25.12-6.12.yml` 或 `25.12-6.12/**` 变更时触发（也可手动
`workflow_dispatch`）。

流程：`prepare-tree.sh`（克隆上游并钉定提交、`feeds update/install`、应用补丁、
装本地包、**自产并校验 NSS 源码包后装配**）→ 写 `.config` + `defconfig` →
`world` 编译 → `verify-image.sh` → 上传日志/产物 → **每次运行新建一个 Release**，
tag 为 `v<run>-<attempt>-<sha8>-25.12-6.12`，资产恰好三个固件文件。

### NSS 源码包（`nss-src-v1`）

CI 的装配树里没有厂商 QSDK 树，而默认设备的 `DEVICE_PACKAGES` 需要
`kmod-qca-ssdk-nohnat` / `kmod-qca-nss-dp` / `kmod-qca-nss-ppe`（补丁 0009 已删掉
主线 PPE 节点，缺了它们就没有以太网）。因此 CI 在装配时**自己产出**这份源码包：

- 内容：`qca-ssdk`、`qca-nss-phy`、`qca-nss-dp`、`qca-nss-ppe`、
  `qca-nss-ecm`、`qca-nss-ae-clients`、`qca-nss-sfe`，逐字取自 QSDK 14.x 树，
  **仅源码、无任何二进制固件**；
- 授权：文件头全部是 ISC（带 SPDX 行或完整 ISC 文本），版权归 The Linux Foundation
  与 Qualcomm；包内附 `NOTICE-ISC.txt`；
- 来源：对 `everything411/qsdk` @ `21a8d13393aa8c7d2abf806e62a8dac2ba7af52f`
  做 `--filter=blob:none` 部分克隆，只稀疏检出 `qca/src/nss`；`rev-parse HEAD`
  必须等于该提交，否则按 `PIN_MISMATCH` / `SOURCE_UNAVAILABLE` 失败，**不降级到分支头**；
- 生成：`prepare-tree.sh` 调 `scripts/ci/export-nss-src.sh`（固定排序/mtime/属主，
  输出可重复；打包前复核许可并拒绝任何 `*.bin`/`*.ko`/`*.o`）；
- 校验：仓库里提交 `nss/nss-src.tar.gz.sha256`（当前 `6cd707b7…`）。自产结果必须
  `sha256sum -c` 通过——不一致说明上游不再是同一份源码，直接失败。CI 端缓存到
  `<工作区>/.sbe-cache/nss-src-v1`，缓存命中时跳过重新自产。

**不再依赖任何人工上传的 Release 资产**：`nss-src-v1` 这个 tag 只是历史产物，
workflow 不引用它。`export-nss-src.sh --upload` 仍保留，仅用于手工重发/留档，
需要 `GH_TOKEN`。

本机已有厂商树时不需要自产；也可以用 `SBE_NSS_BASE=<已解包的 7 包目录>` 直接指定。

## 注意

- `files/` 由 `include/image.mk` 原样复制进 rootfs，**不经过** `VERSION_SED_SCRIPT`，
  所以 banner 里的 `%V`/`%R` 必须由 `render-overlay.sh` 在构建前替换。
- 构建树的 `version` 文件必须让**最后一个 `-` 分段是十六进制**（这里是上游提交短
  SHA，如 `sbe1v1k-25.12-stage1-f3f5c2e5`）：`base-files` 把包版本拼成
  `<COMMITCOUNT>~<该分段>`，而 apk 3.x 的 `~` 后缀只接受十六进制，非十六进制
  （如 `stage1`）会让 `package/base-files` 编译失败。
- 25.12 默认使用 apk（`CONFIG_USE_APK=y`），镜像内包数据库是
  `/lib/apk/db/installed`（25.12 的位置；脚本也兼容 `/usr/lib/apk/db/installed`
  与 opkg 的 `/usr/lib/opkg/status`）。
- `/etc/rc.d/S95wireless-defaults` 由 `include/rootfs.mk` 的 `prepare_rootfs`
  自动生成，条件是 `etc/init.d/wireless-defaults` 首行**精确**为
  `#!/bin/sh /etc/rc.common` 且权限 0755。
- 构建与校验过程不接触任何设备；产物未经真机验证前记为 `UNVERIFIED`。
