# 25.12-6.12 对照实验构建方案（草案）

日期：2026-11-16
状态：草案，仅供评审；未改任何构建输入，未上机。

## 0. 目标与边界

**目标：让 25.12-6.12 在 SBE1V1K 上稳定运行 QSDK NSS/SSDK 数据通路**
（最终 `nss.conf` 回到 `tier=full`）。对照实验只用来定位「哪一层、在哪一步
把设备带进复位循环」，**不是**要放弃 NSS、也不是要换掉 25.12。

硬性边界（与 CLAUDE.md 一致，本方案不改变）：

- 只做本地构建输入与静态分析；任何上机动作（TFTP RAM 启动也算）须单独批准；
- 所有实验镜像**只经 APPSBL TFTP 在 RAM 中启动**，不写 eMMC、不 `saveenv`、
  不改 U-Boot 环境；掉电重启即回到 eMMC 上的 24.10 v94；
- 对照镜像不作为发布资产、不进 GitHub Release，文件名带 `diag`/`control`
  前缀，避免与三件套混淆；
- 目标路由器 `192.168.10.142` 不连接、不登录、不扫描；只使用 B 机
  （192.168.1.1，用户现场操作）；
- 口令不写入任何文件、参数或日志。diag 镜像的 SSH 认证用主机公钥
  （公钥不是秘密），不设密码。

## 1. 先修正一个判断

`V41_BOOT_LOOP_2026-11-16.md` 里写的是「崩溃发生在用户态网络初始化之前」。
11-15 的 stage 0 系列实验（`~/tftp-stage0c-tinyinit/`、`tftp-stage0e-offdtb/`、
`tftp-stage0f-nonand/`）给出了相反的证据：

| 阶段 | 组合 | 结果 |
|---|---|---|
| 0c | v32 的 6.12 内核 + v32 DTB + 67 KB 探针 initramfs | 白闪（到达 /init）+ 红灯（eMMC 没枚举） |
| 0e | v32 的 6.12 内核 + 官方 6.18 DTB + 同一探针 | 绿灯，`mmcblk0` 与 `p27` 都在 |
| 0f | 0c 的 DTB 只禁用 QPIC NAND，其余不变 | 绿灯（PASS），仓库修复为 `patches/0029` |

结论：**6.12 内核在这块板子上能走到用户态**；v32 起不来是 DTB 的 QPIC NAND
引脚复用问题，已由 0029 修掉。这也与 v41 刷机时用户看到「WiFi SSID 反复出现
消失」的现象吻合——hostapd 已经在跑，只是以太网侧一帧都没有。

所以「PHY 亮 70 秒、零帧、3–4 分钟复位」不能再当作「内核早期挂死」。更可能
是：**有线 NSS 通路（ssdk/dp/ppe）没起来；系统继续跑，随后被某个超时/复位
源整机重启**。这是本方案要分清的两件事。

## 2. 参考项目的取舍（luckkyboy/SBE1V1K）

参考仓库 `https://github.com/luckkyboy/SBE1V1K`（已克隆到 `/tmp/ref-luckkyboy`，
只读，未执行其脚本）：

- 它是 **OpenWrt main（6.18 内核）+ 上游 PR #21586 的 askey_sbe1v1k 设备支持**，
  数据通路走主线 `qcom,ppe`，**明确不带 QSDK NSS/SSDK**（guide 原文：
  「目前没有 IPQ9574 PPE/NSS 硬件路由加速支持」）。
- 对我们要的 QSDK NSS/SSDK **没有直接价值**；把底座换到 6.18 还会破坏
  QSDK 14 的 Wi-Fi/NSS 版本对齐（见项目记忆 `wifi-offload-version-alignment`），
  所以不采用它的系统基线。
- 有价值、可以借鉴的有三处：
  1. 它的 `target/linux/qualcommbe/dts/ipq9570-sbe1v1k.dts`（708 行）是**本板**
     的主线以太网描述：`ethernet-ports` 里 qca8075 包、QCA8081、RTL8261N 的
     phy-handle、nvmem MAC、MDIO 地址都齐，可作为「主线 PPE 对照变体」的
     现成 DTS 蓝本；
  2. 板载事实：PWM 通道 0/1/2=红/绿/蓝、3=风扇（与 stage 0c 的探针一致）；
     `tzapp` 保留内存在 `0x49B00000`（加 ramoops 时必须避开）；
  3. U-Boot 侧的启动/回退操作（`do_boot`、TFTP 兜底地址）与我们已经验证过的
     恢复套件同型；它的 `saveenv` 写法我们不采用（本板 dualimg 回滚风险已定案）。
- 它的 guide 写明**板子没有 USB 口**，所以「USB 存储写日志」这条取证路不可行，
  本方案不再考虑。

## 3. 实验矩阵

所有变体都从当前仓库树（`openwrt-25.12 @ f3f5c2e5`、6.12.112、QSDK NSS 包
齐全）派生，**生产镜像（三件套）保持现状不动**。

| 变体 | 内容 | 目的 | 是否必须 |
|---|---|---|---|
| **P**（production） | 现状：NSS DTS + `tier=wired` | 保持发布 | 不改 |
| **D（diag）** | NSS DTS/包全保留，`nss.conf tier=off`；WiFi 管理面 + LED/风扇信标；精简 initramfs | 拿到「不碰 NSS 的 25.12 基线」并逐层手工装载 | 必须 |
| **M（mainline 对照）** | 主线 `qcom_ppe` 设备（参考仓库 DTS 移植到 6.12），无 NSS 包 | 证明 6.12 主线 PPE 在本板可用，作为有线兜底/对照 | 可选，D 失败时上 |
| probe（已有） | stage 0c/0e/0f 的 67 KB 探针 | 已有，不重建 | 备用 |

### 3.1 D 变体（主实验）

- 设备定义仍是 `spectrum_sbe1v1k`（`patches/0009/0010` 不动），NSS 包全在
  镜像里，`/usr/sbin/nss-load` 与 `/etc/init.d/nss` 也在；
- 唯一行为差异：`/etc/nss.conf` 的 `tier=off`、`fallback=off`（**镜像内**，
  不改生产默认值），因此启动不装载任何 NSS 模块；
- 管理面：WiFi。仓库默认首启会生成 SSID `WiFi_2.4G/5G/6G`、密钥
  `12345678`（`files/usr/lib/sbe1v1k/wireless-defaults`），D 变体在 overlay
  里直接固化这组值，避免依赖 uci-defaults 的执行时机；SSH 用主机公钥
  `~/.ssh/id_ed25519_sbe1v1k.pub` 写入 `/etc/dropbear/authorized_keys`；
- 信标：`/usr/sbin/sbe-diag-beacon`，沿用 stage 0c 已验证的 PWM 通道映射
  （0=红 1=绿 2=蓝 3=风扇），用颜色/节奏编码阶段（见 §5.3）；
- 精简：seed 去掉 LuCI 与第三方插件，保留 base、netifd、dropbear、wpad、
  ath12k、sbe-wifi-firmware、NSS kmods、`ip-full` 与 nss-load 依赖；
- 产物名前缀 `sbe1v1k-diag-`，不进 Release。

### 3.2 M 变体（可选对照）

- 以参考仓库 `ipq9570-sbe1v1k.dts` 的 `ethernet-ports`/`mdio` 段落为蓝本，
  做一份「本板 + 主线 PPE」的 DTS（保留我们的 eMMC/风扇/PWM 节点，保持
  `qcom_ppe` 不删除），设备包用 `kmod-qcom-ppe`；
- 目的不是日常使用，而是回答「6.12 的主线以太网驱动在本板能不能出帧」，
  以及给 D 变体提供有线兜底。若 D 的 WiFi 管理面不可用，M 可以直接用网线；
- 6.12 的 PPE 绑定与 6.18 可能有差异，先做编译验证，不保证能启动；编不过就
  退回参考仓库 DTS 原样 + 官方 6.18 内核（stage 0d 已证明可用），不再深挖。

## 4. 构建方式

### 4.1 变体开关

在 `scripts/ci/prepare-tree.sh` 增加一个环境变量 `SBE_VARIANT`
（默认 `production`）：

- `production`：行为与现在完全一致；
- `diag`：
  - seed 用新增的 `build/config-seed/ipq95xx-spectrum-sbe1v1k-diag.seed`
    （精简包集 + `tier=off` 相关文件）；
  - 覆盖 overlay：`files/etc/nss.conf`（tier=off）、`files/etc/dropbear/authorized_keys`、
    `files/usr/sbin/sbe-diag-beacon`、`files/etc/init.d/sbe-diag-beacon`；
  - 设备 `DEVICE_IMG_PREFIX := sbe1v1k-diag`（只改设备定义的一份补丁或
    `SBE_IMG_PREFIX` 注入，确保不与生产文件重名）；
  - 断言：`/etc/nss.conf` 里的 tier=off、镜像里没有 `S99` 自动装载、initramfs
    < 31 MiB；
- `mainline`：seed 选 `spectrum_sbe1v1k_mainline`（`patches/0012` 已带这个
  设备，从未编译过，先补一次编译验证）、`kmod-qcom-ppe=y`、不选 NSS 包，
  前缀 `sbe1v1k-mainline`。

### 4.2 initramfs 体积

现状：10-25 的 stage 1 initramfs 是 23.4 MB（`COMPRESSION_NONE`，内核里嵌
未压缩 cpio，外层 gzip）；v32 的同类产物是 94.7 MB（stage 0c README 实测，
run 41 同型、本地无留存），超过 APPSBL TFTP 上限（32 MiB，1468 B 块时约
91.75 MiB），也接近 `bootm` 的解压上限（约 64 MiB）。D 变体必须重新压：

- seed 里把 `CONFIG_TARGET_INITRAMFS_COMPRESSION_NONE=y` 换成
  `CONFIG_TARGET_INITRAMFS_COMPRESSION_XZ=y`；
- 移植 24.10 的 `build/build-fixes/0019-kernel-initramfs-xz-dict.patch`
  （把内核 `scripts/Makefile.lib` 的 `xzmisc` 从 `dict=1MiB` 改成
  `-9e --lzma2=dict=128MiB`）到 6.12；按 25.12 的目录形态放进
  `25.12-6.12/patches/` 由 `prepare-tree.sh` 应用到内核树的
  `scripts/Makefile.lib`（24.10 已真机验证过这个办法）；
- 断言内核配置里 `CONFIG_INITRAMFS_COMPRESSION_XZ=y` 且 `CONFIG_RD_XZ=y`
  （否则内核解不开 xz cpio，表现是 bootm 后无输出）；
- 精简包集本身就能把 cpio 从 ~90 MB 降到 30 MB 量级，xz 后再减半；
- CI 里加硬门禁：`sbe1v1k-diag-initramfs.itb` < 31 MiB，否则构建失败。

### 4.3 CI 工作流

新增 `.github/workflows/build-25.12-diag.yml`（仅 `workflow_dispatch`）：

1. 复用 `prepare-tree.sh` + `SBE_VARIANT=diag`，跑完整构建（kernel 必须重编，
   约 3 小时）；
2. 产物只上传 Actions artifact：`sbe1v1k-diag-initramfs-fit-uImage.itb`、
   `.config`、manifest、`nss-load`/`nss.conf` 哈希；
3. 不做 Release、不带插件自动跟新（`SBE_PLUGIN_MODE=pinned` 且种子已去插件）。

M 变体用同一工作流 `SBE_VARIANT=mainline` 再跑一次；D 通过后 M 可以先不跑。

### 4.4 静态检查（构建前，全部本地）

1. 0019 移植后 `make -C … scripts` 不报错，`Makefile.lib` 里 grep 到
   `dict=128MiB`；
2. 与 24.10 的 NSS 组件逐项 diff：模块清单、`modinfo` 依赖、
   `/lib/firmware` 内容（24.10 能跑，25.12 缺什么一目了然）；
3. `nss-load` 的 `boot`/`load` 路径在 diag 下确实不会被 S15 调用
   （`/etc/rc.d` 无 S15nss 或脚本读到 tier=off 直接返回）；
4. seed 反查：`kmod-qca-ssdk-nohnat`、`kmod-qca-nss-dp`、`kmod-qca-nss-ppe`
   都在 `.config` 里 `=y`（D 变体必须能手工装载）；
5. `render-overlay.sh` 输出里 tier=off、authorized_keys、beacon 三件齐全。

## 5. 上机流程（每次单独批准）

### 5.1 准备（主机，只读设备）

1. 备份 `~/sbe1v1k-ramtest/tftp-root/initramfs.itb`（官方 RAM 系统，恢复用）；
2. 把 diag ITB 放进 `tftp-root/initramfs.itb`；
3. `sudo ~/sbe1v1k-ramtest/start-dhcp-tftp.sh enxc84d4424a1b5`（日志
   `/tmp/recovery-dnsmasq.log`）。

### 5.2 启动

1. 路由器断电 → 按住 Reset → 上电 → 约 12 秒松手；
2. dnsmasq 日志出现 `rtq7300t_boot_auto_upgrade_fw.img` → `initramfs.itb`
   → 无 `bootm 返回` 标记即为内核接管；
3. 主机搜索 WiFi `WiFi_2.4G`（或 5G）并加入（密钥 12345678），
   `ssh -i ~/.ssh/id_ed25519_sbe1v1k root@192.168.1.1`；
4. 若 WiFi 没出现：改用 §5.3 的信标判读，并准备 M 变体走有线。

### 5.3 信标（无 SSH 时的唯一通道）

沿用 stage 0c 已验证的映射：PWM 0/1/2=红/绿/蓝，PWM 3=风扇。diag 镜像里
`/usr/sbin/sbe-diag-beacon` 在 rcS 末尾接管 LED：

| 现象 | 含义 |
|---|---|
| 白闪 3 次（0.6 s 亮/灭） | 内核已到用户态（/init 在跑） |
| 白闪后无任何颜色 | beacon 没跑起来（overlay/包问题） |
| 绿色慢闪 | WiFi AP 已起来（可尝试 SSH） |
| 蓝色慢闪 | `nss-load load sdk` 成功（`/sys/ssdk` 出现） |
| 蓝色快闪 | sdk 失败（无 `/sys/ssdk`，模块已返回错误） |
| 黄色（红+绿） | dp 装载成功（出现 eth 网口） |
| 紫色（红+蓝） | ppe/ecm 装载成功 |
| 红色常亮 + 10 s 后复位 | 当前层把系统带死；复位前的颜色就是最后成功层 |
| 风扇 5 秒一次心跳 | 循环还活着（与颜色无关） |

### 5.4 逐层装载（有 SSH 时）

1. 先让系统静置 **10 分钟**，确认 tier=off 不自行复位（这是 H3/H4 与
   H1/H2 的分界）；
2. 主机开 `ssh root@192.168.1.1 'dmesg -w' | tee /tmp/diag-dmesg.log`，
   另开一路 `logread -f`；
3. 依次执行，每步间隔 30 s 并记录：

   ```
   nss-load status
   nss-load load sdk     # 等 /sys/ssdk，最多 10 s
   nss-load load dp      # 观察 eth0..eth3 是否出现、PHY 是否 up
   nss-load load ppe
   nss-load load ecm
   nss-load commit
   ```

4. 每步后抓：`dmesg | tail -80`、`lsmod | grep -E 'qca|nss'`、
   `ip -br link`、`cat /sbe-boot-trace/events.log`；
5. 若某一步把设备带死：主机侧的 `dmesg -w` 流会停在最后的打印上，把该文件
   收进 `docs/`；板子复位后回 eMMC 24.10，不需要额外恢复动作。

### 5.5 结束

断电重启（不按 Reset）回到 24.10 v94；确认 LuCI 200、三频 WiFi、WAN 正常，
把当次观察写进 `docs/`。

## 6. 判读与下一步

| 观察 | 结论 | 动作 |
|---|---|---|
| tier=off 静置 10 分钟不复位 | 复位由 NSS 层触发（H1/H2） | 继续 5.4，锁定具体层 |
| tier=off 也在 3–4 分钟复位 | 复位与 NSS 无关（H3/H4：看门狗/热/PMIC/保留区） | 转 §7 的复位源调查；M 变体对照 |
| sdk 装载即死 | ssdk 初始化（时钟/uniphy） | 对照 0021/0358/0360 与参考项目记录的 `ssdk_uniphy_raw_clock_set`/port5 |
| dp 装载即死 | dp/ppe probe（地址、保留区、固件） | 比对 24.10 的 6.6 驱动与 DTB 数值 |
| 四层全过、`tier=full` 重启也正常 | RAM 正常、eMMC 循环另有原因 | 比对 overlay/rootfs 与 S15 时序；再谈刷机 |
| WiFi/SSH 完全拿不到 | 管理面不可用 | 用信标判读 + M 变体有线 |

## 7. 复位源调查（只在 tier=off 也复位时启动）

1. **pstore/ramoops**：当前 6.12 内核配置 `CONFIG_PSTORE*` 全关，需要
   `CONFIG_PSTORE=y`、`PSTORE_RAM`、`PSTORE_CONSOLE`，DTS 加 `ramoops` 保留区
   （避开 `0x40000000..0x42000000` 的 NSS 区和参考仓库的 `tzapp@0x49B00000`）；
   先用 `echo c > /proc/sysrq-trigger` 自测「热复位后能读回上次日志」，不通过
   就不依赖它；
2. **netconsole**：`CONFIG_NETCONSOLE`，目标主机 192.168.1.2:6666；只有 dp 已
   注册 netdev 时才有用，作为「dp 之后挂死」的补充；
3. **看门狗/panic 参数**：核对 `panic_on_oops`、`panic=1`、qcom_wdt 状态与
   PMIC 复位原因寄存器（如有 ubus/ATF 接口），把 3–4 分钟周期对齐到具体源。

## 8. 可交付物

1. 本方案评审通过后：`SBE_VARIANT` 开关、diag seed、beacon、0019 移植、
   `build-25.12-diag.yml` —— 全部本地提交，构建产物只进 Actions artifact；
2. 每次上机的观察记录：`25.12-6.12/docs/DIAG_RUN_<日期>.md`（含 dmesg 流
   最后一屏、灯色、层结论）；
3. 定位到层后的修复补丁 + RAM 复测记录；只有 RAM 复测 PASS 且用户再次批准，
   才讨论 eMMC 刷入。

## 9. 明确不做

- 不换 6.18 底座、不删 QSDK NSS/SSDK、不把 D/M 变体当发布镜像；
- 不写 eMMC、不改 U-Boot 环境、不 `saveenv`；
- 不连接 `192.168.10.142`；
- 不在任何文件/日志/参数里写路由器口令；
- 不在没有针对性修复的情况下再刷 25.12 到 eMMC。

## 10. 实施状态（2026-11-16，本地完成，未提交）

按 §8 第 1 条已落地（全部本地，未 commit、未 push、未接触设备）：

| 落点 | 文件 |
|---|---|
| 变体开关 | `scripts/render-overlay.sh`（叠 `files-<variant>/`）、`scripts/ci/prepare-tree.sh`（`SBE_VARIANT` 门控插件/NSS 装配 + 变体断言）、`scripts/ci/check-packages.sh`（`SBE_REQUIRED_LIST`） |
| diag | `build/config-seed/ipq95xx-spectrum-sbe1v1k-diag.seed`、`build/required-packages-diag.txt`、`files-diag/`（nss.conf tier=off、beacon、S99、dropbear 公钥、变体标记） |
| mainline | `build/config-seed/ipq95xx-spectrum-sbe1v1k-mainline.seed`、`build/required-packages-mainline.txt`、`files-mainline/`（tier=off、取证公钥、变体标记） |
| XZ 字典 | `patches/0031-qualcommbe-kernel-initramfs-xz-dict.patch`（两层 dry-run `--fuzz=0` PASS） |
| 校验 | `scripts/ci/verify-diag.sh`（尺寸/装载地址/XZ/overlay/NSS 组件/清单反查） |
| CI | `.github/workflows/build-25.12-diag.yml`（仅 workflow_dispatch，`contents: read`，产物只进 artifact） |

本地已验：全部脚本 `bash -n`/`sh -n` PASS；两变体种子 `check-packages seed`
PASS（diag 30 项、mainline 31 项）；`render-overlay.sh` 在假装配树上实测
production 不叠变体、diag 正确叠加（tier=off、公钥 600、S99 相对链接）。
未验：整树编译、defconfig（本地装配树是旧的，见 memory
`stale-2512-buildtree-context`）、真机行为（`NOT TESTED`）。
下一步：用户批准后首次跑 `build-25.12-diag.yml`（需仓库 token 或手动触发）。
