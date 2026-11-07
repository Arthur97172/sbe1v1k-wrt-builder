# sources/ 取源记录（PROVENANCE）

> 阶段：**G1　源码获取与锁定**（用户 2026-10-21 授权 **N-7**）
> 本文件为**取源审计锚点**。任何与本文件的偏差都必须记录，不得静默修改。

---

## 0. 授权与边界

| 项 | 内容 |
|---|---|
| 授权 | 用户 2026-10-21：**「授权 N-7」** |
| 授权范围 | 克隆 QSDK 14 基座树；另经 A3 确认的官方平台目标 |
| **未授权** | 编译、`feeds update`、安装宿主依赖、连接路由器、刷写 |
| 口令 | **未使用、未存储**。本阶段全部源为公开只读仓库 |

---

## 1. 已取得的仓库

### 1.1 `sources/qsdk14/` —— QSDK 14 基座（个人镜像）

| 项 | 值 |
|---|---|
| 远端 | `https://github.com/everything411/qsdk` |
| 分支 | `14.0` |
| **HEAD** | **`21a8d13393aa8c7d2abf806e62a8dac2ba7af52f`** |
| 提交时间 | 2026-10-18 10:24:09 +0800 |
| 提交标题 | `import QSDK build 14.0.1595.1670` |
| **tree 哈希** | **`b8ceb12b48f3f7bad6a458f2b1f3f1fc0070dee5`** |
| 工作树大小 | 2.7 GB（`.git` 359 MB） |
| 获取方式 | `git clone --depth 1 --branch 14.0 --single-branch`，随后 `git fetch --unshallow` |
| 获取时间 | 2026-10-21T04:48Z |
| 传输异常 | 首次全量 `git clone` 因 `GnuTLS handshake failed` 中断；重试改为浅克隆成功 |
| 作者 / 提交者 | **`everything411 <everything411@163.com>`** |
| **父提交** | **无 —— `parents` 为空** |

> ### ★ 重大发现：该镜像**没有任何历史**
>
> `git rev-list --count HEAD` = **1**。`--unshallow` 后仍只有 **1 个提交**，`parents` 为空。
>
> 即：`14.0` 分支是**一次性导入的整树快照**（`import QSDK build 14.0.1595.1670`），
> **不存在**逐版本演进、上游合并、补丁来源的任何历史。
>
> **后果（必须记录，不得淡化）**：
>
> | 影响 | 说明 |
> |---|---|
> | 无法验证来源 | 无父提交 → 无法追溯该快照由哪些官方提交组成 |
> | 无法验证未被篡改 | 个人可在任意时刻重建同样的一棵树并以相同 message 提交 |
> | **无法做差异归因** | 与官方 CodeLinaro 的差异**无法定位到具体改动**，只能逐文件比对 |
> | `--unshallow` 的意义 | **无** —— 该分支本就只有 1 个提交 |
>
> 这**实证了 R-9 的核心担忧**：个人镜像即使钉定 SHA，也**不提供任何来源证明**。
> 官方 CodeLinaro 仓库因此从"对照项"升级为**唯一可追溯的基线候选**。

**已核验事实**：

| 检查 | 结果 |
|---|---|
| `qca/src/linux-6.6/Makefile` → `SUBLEVEL` | **116**（= S2） |
| `feeds.conf.default` | 全部指向 **`openwrt-24.10`** |
| `target/linux/` 是否含 `ipq95xx` | **否**（需官方 target feed，见 §1.2） |
| `qca/src/linux-6.6` 内是否含 `ipq9574*.dts` | **否**（DTS 在 `linux-ipq-files`，见 §1.3） |
| 全树是否含 `sbe1v1k` | **否**（`.dts/.dtsi/.mk/.c/.h/.sh` 全量检索） |
| `qca/src/` 组件 | `nss/`、`qca-wifi/`、`mac80211/`、`u-boot/`、`u-boot-2025/`、`datarmnet/` 等 |
| `qca/feeds/` | `nss/`、`wlan-open/`、`wlan-hostapd/`、`wlan_utils/` 等 17 个 |

### 1.2 `sources/codelinaro/target-ipq/` —— **官方** ipq95xx 平台目标

| 项 | 值 |
|---|---|
| 远端 | `https://git.codelinaro.org/clo/qsdk/oss/system/feeds/target/ipq` |
| 分支 | `win.openwrt.24.10.r1` |
| **HEAD** | **`3c993a55c9a18902844691ae45ba839387ad5068`** |
| 提交时间 | 2025-04-06 10:15:54 -0700 |
| **tree 哈希** | **`5f2fae23e0905929ca941377e9273eee8fa74f67`** |
| 大小 | 2.5 MB（完整历史，非浅克隆） |
| 可见性 | **public**（无需账号） |

**已核验事实**：

| 检查 | 结果 |
|---|---|
| 顶层平台 | `ipq50xx ipq53xx ipq54xx ipq60xx ipq807x ipq95xx profiles` |
| `ipq95xx/` 内核配置 | `config-5.4` / `config-6.1` / **`config-6.6`** |
| `config-6.6` 关键项 | `CONFIG_IPQ_GCC_9574=y`、`CONFIG_IPQ_NSSCC_9574=y` |
| 设备 | `qcom_alxx`、`qcom_al01-c1`、`qcom_al02-c1/c2/c7`、`qcom_rdp433`，**全部 `SOC := ipq9574`** |
| 是否含 `sbe1v1k` | **否** |

**该目录在构建树中的正确位置**（来自官方 manifest 的 `path=` 属性）：

```
target/linux/feeds/          ← 即本 repo
```

---

## 2. 官方组件集（**已取得并校验**）

> **2026-10-21 完成**：用户授权「克隆剩下的官方仓库」后，已按官方 manifest
> `NHSS.QSDK.14.1.r2-00008-O`（`AU_LINUX_QSDK_NHSS.PRPL.14.1.R1_TARGET_ALL.14.101.634.007.xml`）
> 中钉定的**精确 SHA** 逐仓拉取并校验。
>
> ### 2.0 完整性对账
>
> | 项 | 数量 |
> |---|---|
> | manifest `<project>` 总数 | **77** |
> | 已取且 SHA 一致 | **66** |
> | 已取但 SHA 不符 | **0** |
> | 未取（有理由，见 2.3） | **11** |
>
> 体量：`sources/codelinaro/` 2.6 GB。
>
> ### 2.1 取源过程留痕（不掩盖失败）
>
> | 次序 | 事件 | 处置 |
> |---|---|---|
> | 1 | 拉取脚本列顺序写反（`name,path,rev,flat` 当作 `flat,name,path,rev`），远端 URL 拼错 | 中断；**删除误建的嵌套目录 `sources/codelinaro/clo/`** |
> | 2 | 在脚本运行中修改脚本，两个实例交叉写同一日志 | 终止全部实例、清理、改用新脚本文件 |
> | 3 | 余下 21 个仓库一次性全部 `OK` | 无异常 |
>
> 三批共记录：`/tmp/fetch_qsdk*.log`（临时文件，不作为审计锚点；以本文 SHA 表为准）。

| 仓库 | manifest 目标路径 | 钉定 SHA | 状态 |
|---|---|---|---|
| `clo/qsdk/oss/kernel/linux-ipq-6.6` | `qca/src/linux-6.6` | `a1f20340783f0a0fa44c6ca7876a78b59fde77f3` | ✅ 已校验 |
| `clo/qsdk/oss/kernel/linux-ipq-files` | `target/linux/feeds/files-6.6` | `cd453e73f58a2be6303a37b242e30d3fffb0bb6b` | ✅ 已校验 |
| `clo/qsdk/oss/kernel/linux-ipq-patches-6.6` | `target/linux/feeds/patches-6.6` | `21c5448e66cfaf63ce89e8a1e11dd986b40e99ff` | ✅ 已校验 |
| `clo/qsdk/oss/feeds/nss` | `qca/feeds/nss` | `dfa50d5c39fa2ea05f5b1f3022cfba065fbb6eb1` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-drv` | `qca/src/nss/base/qca-nss-drv` | `705629dab29e45e1fbfe57c4fcba73f3d58dee24` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-dp` | `qca/src/nss/base/qca-nss-dp` | `f16a9461ea81c8429f3a2e92539a571d81ff5d6c` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-ppe` | `qca/src/nss/base/qca-nss-ppe` | `c5b1d40ed040132490c40c5f29d935566f303fc3` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-eip` | `qca/src/nss/base/qca-nss-eip` | `102c381e511c2922241857dd816409c772c274e1` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-crypto` | `qca/src/nss/clients/qca-nss-crypto` | `1d5e0381254dcc4dc06ee823977f7f2d81fec981` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-nsm` | `qca/src/nss/clients/qca-nss-nsm` | `96cb0871acfa5ad52e9fbc7f3299be9b0938e18e` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/qca-nss-ecm` | `qca/src/nss/clients/qca-nss-ecm` | `c6648d494ca739077781156f54766822c732103d` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/qca-ssdk` | `qca/src/nss/base/qca-ssdk` | `40a86ab39dbdf213666413d641b0aa76b92649dd` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/qca-mcs` | `qca/src/nss/clients/qca-mcs` | `063a4679ed22b1610925d3809397ff82308d4d00` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/shortcut-fe` | `qca/src/nss/clients/qca-nss-sfe` | `ebcee831f69a8a69d5fea949ceeba8af8a42926a` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-macsec` | `qca/src/nss/base/qca-nss-macsec` | `504b9016b259829f21e41a62b42a0f3193fed557` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-cfi` | `qca/src/nss/clients/qca-nss-cfi` | `3211d1d4d44aa58e23503881eda1a99aade41403` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-ae-clients` | `qca/src/nss/clients/qca-nss-ae-clients` | `d301c82b99f5b4078dcd45d3936575ce6902692c` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-dscpstats` | `qca/src/nss/clients/qca-nss-dscpstats` | `4108235ef472b081b13bf7c4d16a689ca479676b` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-netfn` | `qca/src/nss/clients/qca-nss-netfn` | `0d5b4194454dc77d70e33b2d22f6b6acb16b01fb` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-plugins` | `qca/src/nss/clients/qca-nss-wifi-plugins` | `65a1a1b0666ed7dbf13221c5d3567966de411ed5` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-speedtest` | `qca/src/nss/clients/nss-speedtest` | `d47d31c158765a0ddf2a4deba961a3d0d3c0954d` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/nss-pon-plugin` | `qca/src/nss/clients/qca-nss-pon-plugin` | `cdc378458abd6de1b44591861179d5999fa56a3f` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/emesh-sp` | `qca/src/nss/clients/emesh-sp` | `df14b1c189ff3e4ca199083bdeaf02ebc21cd1df` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/net-standby` | `qca/src/nss/clients/qca-net-standby` | `a5ba192b78cdca12f1ff514d29cb811bc4e11cb7` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/qca-nss-phy` | `qca/src/nss/base/qca-nss-phy` | `c8663a3bde6431cc0694a5b9e31453be5fe76723` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/qca-mmap-telemetry` | `qca/src/nss/base/qca-mmap-telemetry` | `99819e695f2bda1540a96e8d1cfaf618d0e0c5ff` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/qca-ovsmgr` | `qca/src/nss/clients/qca-ovsmgr` | `6c1fafc4fbdc28474d2199fa2bef6e10c89d2118` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/qca-sxc` | `qca/src/nss/base/qca-sxc-drv` | `378263d2ca6af872ae64ef68812906fddf68b5b1` | ✅ 已校验 |
| `clo/qsdk/oss/lklm/qca-debug-uio` | `qca/src/qca-debug-uio` | `27811f87127f19fcb2354b383a290bd452f48fa2` | ✅ 已校验 |
| `clo/qsdk/oss/nss-userspace` | `qca/src/nss/apps-oss/nss-userspace-oss` | `3bdea3cecd37e32df57b7a85220eda133e9b8932` | ✅ 已校验 |
| `clo/qsdk/oss/ssdk-shell` | `qca/src/nss/apps-oss/qca-ssdk-shell` | `ee59e00d5d9e673c8f91dfe065b88a8e0b41c7cf` | ✅ 已校验 |
| `clo/qsdk/oss/qca-lacpd` | `qca/src/nss/apps-oss/qca-lacpd` | `69b9574a457cdeeadee7c081c3ce053a7c898d6a` | ✅ 已校验 |
| `clo/qsdk/wifi/qca-wifi-oss` | `qca/src/qca-wifi/component_dev` | `ee42324119f1d389bf125e8a36c3d9c9bc6299c2` | ✅ 已校验 |

> 磁盘上的目录名采用 `clo/qsdk/` 之后的路径以 `-` 连接（例如
> `oss-lklm-nss-drv`），与上表的映射关系由 `sources/codelinaro/<flat>/` 决定。

> **关键**：DTS 只在 `linux-ipq-files` 里 —— 已确认其中含
> `ipq9574-db-al01-c1/c2/c3.dts`、`ipq9574-db-al02-c1/c2/c3.dts`、`ipq9574-rdp417/418.dts`、
> `ipq9574-qcn9224-{default,512MB}-memory.dtsi`、`ipq9574-qcn9000-*`。
> **未发现 `sbe1v1k`** —— P-B 仍然成立。

### 2.2 补齐批次取得的**包定义类**仓库

上表 33 项只覆盖 `src` 与 `lklm`。**OpenWrt 包 Makefile 在另一批 `feeds/*` 仓库里**，
首次取源时遗漏，G2 检查中补取（共 32 项）：

| 仓库 | manifest 目标路径 |
|---|---|
| `clo/qsdk/oss/system/feeds/nss-base` | `qca/feeds/nss/base` |
| `clo/qsdk/oss/system/feeds/nss-clients` | `qca/feeds/nss/clients` |
| `clo/qsdk/oss/system/feeds/nss-apps` | `qca/feeds/nss/apps-oss` |
| `clo/qsdk/oss/system/feeds/wlan-open` | `qca/feeds/wlan-open/mac80211` |
| `clo/qsdk/oss/system/feeds/wlan-hostapd` | `qca/feeds/wlan-hostapd/hostapd` |
| `clo/qsdk/oss/system/feeds/wlan/utils` | `qca/feeds/wlan_utils` |
| `clo/qsdk/oss/system/feeds/networking` | `qca/feeds/networking` |
| `clo/qsdk/oss/system/feeds/platform/utils` | `qca/feeds/platform_utils` |
| `clo/qsdk/oss/system/feeds/platform/bootloader` | `qca/feeds/bootloader` |
| `clo/qsdk/oss/system/feeds/control-app` | `qca/feeds/control-app-open` |
| `clo/qsdk/oss/system/feeds/openwrt-tools` | `qca/feeds/openwrt-tools` |
| `clo/qsdk/oss/system/feeds/qca-debug-uio` | `qca/feeds/qca-debug-uio` |
| `clo/qsdk/oss/system/feeds/sigma-dut` | `qca/feeds/sigma-dut-open` |
| `clo/qsdk/oss/system/feeds/wlan-iw` | `prpl-patches/package/network/utils/iw` |
| `clo/qsdk/oss/src/mac80211/wlan-open` | `qca/src/mac80211/wlan-open` |
| `clo/qsdk/oss/src/network/services/hostapd` | `qca/src/network/services/hostapd` |
| `clo/qsdk/oss/releases/configs/qsdk` | `qca/configs/qsdk` |
| `clo/qsdk/oss/system/openwrt/ipq-scripts` | `ipq-scripts` |
| `clo/qsdk/oss/system/openwrt-ipq-patches` | `openwrt-ipq-patches` |
| `clo/qsdk/oss/system/tools_repo` | `qca/src/qca-ramparser` |
| `clo/qsdk/oss/qca/feeds/qca-rsrcmgr/driver` | `qca/feeds/qca-rsrcmgr/...` |
| `clo/qsdk/oss/qca/src/qca-rsrcmgr/driver` | `qca/src/qca-rsrcmgr/driver` |
| `clo/qsdk/oss/boot/u-boot` | `qca/src/u-boot` |
| `clo/qsdk/oss/boot/u-boot-2025` | `qca/src/u-boot-2025` |
| `clo/qsdk/oss/owrt/system/feeds/fastrpc` | `qca/feeds/fastrpc` |
| `clo/qsdk/oss/trex/{omciibc,sw-hook,swacl-if,tools/util-ubus}` | 对应 `qca/src/*` |
| `clo/qsdk/oss/fontana/middleware/onu-hal` | `qca/src/onu-hal` |
| `clo/qsdk/oss/prpl-foundation/prplos/feeds/{prplos-feeds,feed-prplmesh}` | — |

全部 SHA 与 manifest 一致。

### 2.3 未取的 12 项（有理由）

`prplos`、`prplos-patches`、`feed-prplmesh`、`tools/meta`、`qca-pkcs11`、
`wlan-app-extns`、`wlan-open-extns`、`qca-telemetry-agent-oss`、
`trex/apps`、`trex/drivers`、`uboot-ipq-files`、`uboot-ipq-patches`。

理由：PRPL-OS 框架 / 光模块 PON / 遥测 / 仅"改 U-Boot"才需要。**本项目不改 U-Boot。**

> **G3.4 复核（2026-10-21）**：`wlan-app-extns` 一项的理由已修正 ——
> QCN 扩展版 hostapd（`wpad-mesh-openssl`）**确实**需要它提供的
> `qca/src/qcn-app-extns/qacs/`。该仓库在 CodeLinaro 上无法公开取得
> （候选路径 `git ls-remote` 均要求认证），标为 **SOURCE_UNAVAILABLE**；
> 构建改用 feed 默认的 `-noextns` 变体。见
> `docs/STAGE3_INTEGRATION_PLAN.md` §3.3.5。其余各项的“未取”理由不变。

### 2.4 ★ 目标平台 feed 的两份副本

| 目录 | SHA | 来源 | 设备数 |
|---|---|---|---|
| `target-ipq/` | `3c993a55c9a18902844691ae45ba839387ad5068` | 分支 `win.openwrt.24.10.r1` | 6 |
| `oss-system-feeds-target-ipq/` | `5494b2acc0f9aea1d9a16d02bcb50a55d810f3ee` | **manifest pin** | 8 |

`ipq95xx` 部分差异：`config-6.6` 相差 141 行；pin 版多 `prpl_freedom`、`qcom_db-al01-c2`；
`02_ipq_board` pin 版少两条 `qce1204` compatible。

> **建议基线**：**manifest pin 版**（与内核、补丁同源）。24.10 分支版保留作对照。
> 两者**都没有 `sbe1v1k`**。

### 2.5 ★ `openwrt-patches`（构建系统要求，14.1 manifest 未列出）

QSDK 构建系统在 `config/Config-build.in:147,152` 无条件
`source "openwrt-patches/config/Config-build.in"`、`source "openwrt-patches/config/Config-kernel.in"`，
缺少该目录时 `make defconfig` 直接失败（`glob failed: No files found`）。
14.1 manifest（77 个 project）**没有**把它列为 project，因此按仓库自身的 14.1 tag 钉定：

| 项目 | 值 |
|---|---|
| 仓库 | `https://git.codelinaro.org/clo/qsdk/oss/system/openwrt-patches.git`（公开） |
| tag | `NHSS.QSDK.14.1.r2-00008-O`（tag 对象 `583b210fe0440d704295e88ba3623e2350155eb5`） |
| commit | `02264b9b6540bd650ac6dd943c460366a4efc73a`（2026-10-05） |
| 安装位置 | `sources/buildroot/openwrt-patches/`（201 个文件，无 `.git`） |
| 对照分支 | `win.openwrt.24.10` / `win.openwrt.24.10.r1` 同为 `0c9345e495cef5c077f8c008239cb222d8e9665d`（2025-02-06） |

选 14.1 tag 的理由：内核（6.6.147）、target feed、files/patches-6.6 都钉在 14.1
manifest 上，`openwrt-patches` 取同名 tag 保持同源。基座树是 14.0.1595.1670，
两者兼容性记为 **UNVERIFIED**，见 `docs/BUILD_TREE_ASSEMBLY.md` §3.1。


**实测（2026-10-21，G3）**：51 次 `openwrt-patches` 应用中有 1 处冲突——
`package/system/procd/patches/0002-procd-Enable-maximum-runqueue.patch` 的 hunk #2
上下文是 14.1 的 `const char *` 签名。已用
`build/openwrt-patches/package/system/procd/patches/0002-procd-Enable-maximum-runqueue.patch`
（`145f9128…`）**整文件替换该补丁**（只改上下文，代码不变），由
`build/assembly-map.conf` 的 `copy-file` 覆盖到同一个路径。因此
`sources/buildroot/openwrt-patches/` 与上游 tag 不再逐字节一致：200 个文件同 tag，
1 个为记录在案的替换件。补丁必须**替换**而不是另起一条放进
`package/system/procd/patches/`——`include/quilt.mk` 会先应用 `openwrt-patches` 下的
`0002`，再应用包的 `PATCH_DIR`，两处都放就会把同一段代码打两遍。

### 2.5.1 ★ `wlan-hostapd` feed 的 `files/`（导入树缺失，整包取自同 repo 的 pinned tag）

`sources/qsdk14` 导入树（QSDK build 14.0.1595.1670）中
`qca/feeds/wlan-hostapd/hostapd/` **没有 `files/`**，但该 feed 的
`Build/Configure`、`Build/Compile` 与 mac80211 的安装段都依赖它
（变体 `*.config`、`multicall.c`、`hostapd.uc`、`hostapd.sh`、
DPP 事件脚本等）。

| 项目 | 值 |
|---|---|
| 仓库 | `https://git.codelinaro.org/clo/qsdk/oss/system/feeds/wlan-hostapd`（公开） |
| 本地克隆 | `sources/codelinaro/oss-system-feeds-wlan-hostapd`（仅 1 个 commit，浅克隆） |
| tag | `NHSS.QSDK.14.1.r2-00008-O`（tag 对象 `b017efae43aa57101f277d79c95b4bcb4de36f5d`） |
| commit | `edfb83995868badac3a29da1a1a89738ba8003b0`（= manifest `AU_LINUX_QSDK_NHSS.PRPL.14.1.R1_TARGET_ALL.14.101.634.007` 所钉版本） |
| 内容 | `files/` 29 个文件；`Makefile` 比导入树多 3 行 `wpad-mesh-openssl-noextns` 安装段，其余逐字节相同 |
| 去向 | `build/upstream-pins.conf` 把 `qca/feeds/wlan-hostapd/hostapd` **整包替换**为该 commit（`replace` 行）。不再打补丁：补丁会与 pin 装进来的内容重复（`patch` 直接报 “already exists”），旧 `0007-wlan-hostapd-feed-shared-files.patch` 已删除 |

> 未采用基座 OpenWrt `package/network/services/hostapd/files/` 的同名文件：
> 实测 `hostapd.sh` 的基座版、厂商版、tag 版三者哈希互不相同，
> 只有 tag 版可追溯到 manifest 钉定版本。

### 2.6 ★ `sources/luci/` —— 官方 LuCI feed（G3.6，2026-10-21）

用户批准"加上 LuCI 基础界面"后新增的**唯一**外部源。

| 项目 | 值 |
|---|---|
| 官方远端 | `https://git.openwrt.org/project/luci.git` |
| 实际使用远端 | `https://github.com/openwrt/luci.git`（**官方 GitHub 镜像**） |
| 失败记录 | 首次从 `git.openwrt.org` 克隆在 63,853 B 处 `GnuTLS recv error (-9)` / `early EOF`，`CLONE_EXIT=128`（`logs/luci_clone.log`）；改镜像后成功 |
| 分支 | `openwrt-24.10`（`--single-branch`） |
| **HEAD** | **`d0400718c508ec4ad9bed8a89f69386f678645d3`** |
| 提交时间 | 2026-07-21T12:53:58Z（`%ct` = 1784638438） |
| 提交标题 | `luci-base: dispatcher.uc: escape URL path and username when logging` |
| 归属校验 | `git branch -r --contains HEAD` → `origin/openwrt-24.10` |
| SHA 依据 | 与 `sources/codelinaro/oss-system-openwrt-ipq-patches/0236-feeds.conf-update-luci-to-latest-openwrt-24.10-commi.patch` 记录的固定值一致 |
| 本地目录 | `sources/luci`（325 MB，**保留 `.git`**：`luci.mk` 用 `git log -1 --format="%ct %h"` 推导 `PKG_SRC_VERSION`，去掉 `.git` 会退化为 `unknown` 且不可复现） |
| 接入方式 | `feeds.conf` 追加 `src-link luci /home/arthur/claude/sbe1v1k-build/sources/luci`；`scripts/feeds update luci` + `install`（日志 `logs/feeds_update_luci.log`、`logs/feeds_install_luci.log`） |
| 许可证 | Apache-2.0（仓库 `LICENSE`） |

**该 feed 声明的下游源（构建时拉取）**：

| 组件 | URL | SHA | 备注 |
|---|---|---|---|
| `liblucihttp` | `https://github.com/jow-/lucihttp.git` | `9b5b683fbb2bb0010aa031d620d0ab8105516757`（2023-03-15，ISC） | **个人账号**；`git.openwrt.org/project/liblucihttp.git` 实测 `not found` → 表 A/B 记 `UNVERIFIED_SOURCE` |
| `ucode-mod-html` | 直接编译 `sources/luci/contrib/package/ucode-mod-html/src/html.c` | 随 luci pin | ISC |
| `uhttpd` | 树内 `package/network/services/uhttpd` | `7e64e8bad2415cec0a6d9770ec379db54273c7a7` | ISC；`dl/` 无缓存，首次构建需 git 拉取 |
| `rpcd` | 树内 `package/system/rpcd` | `bba95191ff2f22c9118a1ba1355b83afaa277ae3` | ISC；同上 |
| `cgi-io` | 树内 `qca/feeds/packages/net/cgi-io` | `901b0f0463c9d16a8cf5b9ed37118d8484bc9176` | GPL-2.0-or-later；同上 |

> **残留**：pin 与厂商固件 `luci-base 0.260827.50370`（2026-08-27）不是同一提交，
> 功能对齐未验证（`UNVERIFIED`）；`liblucihttp` 的托管属性保留为 `UNVERIFIED_SOURCE`。
>
> **构建结果（2026-10-21）**：以上来源均可从本地树完整编译，三轮
> `make clean` + 全量重建退出 0 且逐字节一致；产物 21,105,446 B，
> SHA-256 `089f36da…`，206 个已安装包（详见
> `docs/STAGE3_INTEGRATION_PLAN.md` §5.8）。

### 2.7 ★ `sources/apps/` —— 十个用户自编 LuCI 应用（G3.7 起，2026-10-21；2026-11-07 扩到十个）

用户在 2026-10-21 明确要求把以下应用装进固件，并说明这些应用由用户本人
编写/维护，因此**按用户授权作为 `docs/BUILD_DESIGN.md` §"第三方应用禁止"
条款的限定例外**引入（例外范围仅限下列十个仓库；`luci-app-store` 等第三方
应用源仍在禁止之列）。2026-11-07 用户要求再加五个（tasks、smartnetpilot、
xpu-status、oxidns、meshassistant），并把已有五个一并升到最新 release tag。

| 应用 | 远端（`https://github.com/Arthur97172/…`） | **固定 SHA** | 提交时间 | 提交标题 | 许可证 | 本地体积 |
|---|---|---|---|---|---|---|
| `luci-app-substore` | `luci-app-substore` | `af1649541acb63eba447bb0f5652eb990cf17c1f` | 2026-10-24T04:50:07Z | `docs(readme): 安装命令改用通配文件名，翻译包并入包管理器代码块（2.7.3-r3）` | GPL-3.0-or-later（`LICENSE`；Makefile 未设 `PKG_LICENSE`） | 3.3 MB |
| `luci-app-fcc` | `luci-app-fcc` | `d4ce1abd4de62cb19cada29d32ee2ce6d85be0f9` | 2026-11-07T00:25:26Z | `Release 1.2.0 as r2; r1 was claimed by the rolled-back …` | GPL-3.0（`LICENSE`） | 5.3 MB |
| `luci-app-online-upgrade` | `luci-app-online-upgrade` | `82e42330e63ca63cff238e9d82b160aa253c7990` | 2026-10-24T04:11:06Z | `docs: 调整构建章节位置并合并从源码编译说明` | GPL-2.0-only（`LICENSE`；上游原作为 gooyjq） | 3.1 MB |
| `luci-app-ledfancontrol` | `luci-app-ledfancontrol` | `540eefcf9dc8550f44a3a38afe84f20ec11f195f` | 2026-10-24T05:10:15Z | `README 安装章节前置，补充从源码编译说明` | GPL-3.0-only（`LICENSE`） | 724 KB |
| `luci-app-nssecm` | `luci-app-nssecm` | `af6f4abe6ccb4147addfd3975bd45451e13d03a6` | 2026-10-24T05:02:52Z | `README: reorder sections, merge backend-name note into …` | GPL-3.0-only（`LICENSE`） | 428 KB |
| `luci-app-tasks` | `luci-app-tasks` | `c1665942cda36b4f7668c6eb167968a03b26193f` | 2026-10-25T14:30:18Z | `Add interface screenshot to READMEs` | GPL-3.0-only（`LICENSE`；`PKG_LICENSE` 同） | 1.1 MB |
| `luci-app-smartnetpilot` | `luci-app-smartnetpilot` | `b80e836a0669c03fe6eb956e9e36205292e56f9f` | 2026-10-27T12:09:18Z | `feat: show the current LAN settings in the PPPoE and DH…` | GPL-3.0-only（`LICENSE`） | 1.6 MB |
| `luci-app-xpu-status` | `luci-app-xpu-status` | `14e7d81a75cf864396f308d1a8e83bcc1d5d53d6` | 2026-11-07T06:44:16Z | `luci-app-xpu-status 1.0.3-r1：README 增加截图并调整章节顺序` | GPL-3.0-only（`LICENSE`） | 920 KB |
| `luci-app-oxidns` | `luci-app-oxidns` | `6c432f6d6492cf6a8cbf63b8d5dbe8d67642853f` | 2026-11-07T08:44:21Z | `feat(config): clean up ad filtering card in normal mode`（tag `v1.3.5`，`PKG_VERSION 1.3.7`） | GPL-3.0-or-later（`LICENSE`） | 1.8 MB |
| `luci-app-meshassistant` | `luci-app-meshassistant` | `d51d2cf215b09ac49085605ba19cc981eb45555f` | 2026-11-07T03:37:47Z | `Move Load and Link Rate next to the Interface column` | GPL-3.0-only（`LICENSE`） | 1.1 MB |

十个目录的 `git status --porcelain` 均为空（工作区与 pin 一致）。五个新应用
都带 `po/zh_Hans`，`CONFIG_LUCI_LANG_zh_Hans=y` 让 `luci.mk` 生成对应的
`luci-i18n-*-zh-cn`。pin 的机器可读副本是 `build/upstream-pins.conf` 的
`apps/*` 行，由 `scripts/ci/refresh-pins.sh` 与每周 workflow 自动刷成
"最新 release tag"（只开 PR，不自动合并，也不回退）。

| 项目 | 值 |
|---|---|
| 拉取方式 | `git clone`（**完整历史**，非 shallow）+ `git checkout <SHA>`；日志 `logs/thirdparty_clone_g37.log` |
| 本地目录 | `sources/apps/<repo>`；**保留 `.git`**：`luci.mk` 的 `findrev` 在未显式固定 `PKG_PO_VERSION` 的包上从 `git log` 取翻译包版本，删掉 `.git` 会退化为文件 mtime、不可复现 |
| 接入方式 | `feeds.conf` 追加 `src-link sbe1v1k_apps /home/arthur/claude/sbe1v1k-build/sources/apps`；`scripts/feeds update sbe1v1k_apps` + `install -p sbe1v1k_apps -a`（日志 `logs/feeds_update_g37.log`、`logs/feeds_install_g37_apps.log`） |
| 构建期联网 | **无**。`Build/Prepare`/`Configure`/`Compile` 均为空或只调用本机 `po2lmo`/`jsmin`；不下载任何运行期组件 |
| 运行期联网（应用自身功能，非构建行为） | `luci-app-fcc` 在用户点击安装时从 `raw.githubusercontent.com`、`pypi.org`、`unofficial-builds.nodejs.org` 等下载 Python/Node/agent；`luci-app-online-upgrade` 从 GitHub Release 下载固件后调用 `sysupgrade`；`luci-app-substore` 访问用户配置的订阅 URL；`luci-app-oxidns`（2026-11-07 加入）在用户点击时用 `curl`/`uclient-fetch`/`wget` 下载插件与规则（URL 由用户配置）；`luci-app-meshassistant` 只操作本机 batman-adv/dawn；`luci-app-tasks`、`luci-app-smartnetpilot`、`luci-app-xpu-status` 无外部联网。均记录于 `docs/SECURITY_FINDINGS.md` §7.7/§7.11 与 `docs/RISKS_AND_BLOCKERS.md` R-21…R-24、R-39/R-40 |
| 依赖闭包新增 | luci feed：`luci-lua-runtime`、`luci-compat`、`luci-lib-httpclient`、`luci-lib-httpprotoutils`、`luci-lib-jsonc`、`luci-lib-ip`、`luci-lib-nixio`、`luci-lib-base`、`ucode-mod-lua`；树内：`lua`、`libubus-lua`、`liblucihttp-lua`、`jsonfilter`；`packages` feed 手工符号链接：`curl`（8.12.1, MIT）、`tmux`（3.5a, ISC）。curl 的 `Config.in` 默认 `LIBCURL_NGHTTP2=y`，会把 `libcurl4` 依赖到树内未接入的 `libnghttp2` 包；已在种子中显式 `# CONFIG_LIBCURL_NGHTTP2 is not set`（HTTP/1.1 足够这五个应用的发布页拉取，避免为一个无功能收益的依赖再引入一个上游源码；配置见 `build/config-seed/ipq95xx-spectrum-sbe1v1k.seed`，决定记录见 `docs/STAGE3_INTEGRATION_PLAN.md` §5.9） |
| 依赖闭包新增（2026-11-07） | `luci-app-meshassistant` 的 `LUCI_DEPENDS`：`+luci-base +kmod-cfg80211 +batctl-default +kmod-batman-adv +dawn +bash +luci-proto-batman-adv +socat +flock +iw`。为此新增 `routing` feed（`src-link routing qca/feeds/routing`，只链接 `batctl`、`batman-adv` 两个包），并在 `package/feeds/` 下补 `routing/{batctl,batman-adv}`、`packages/{dawn,socat}`、`luci/luci-proto-batman-adv` 五条软链；`flock` 由基座的 `util-linux` 提供，`iw` 由 `iw-full` 的 PROVIDES 满足。`kmod-batman-adv` 要针对 QSDK 6.6 内核编译，**编译结果本期未验证**（本地未跑内核模块编译；CI 构建后见 `verify-image.sh`） |
| 供应链结论 | 来源为公开 GitHub 仓库、逐提交固定、完整历史可复核；许可证全部为 GPL 系（与镜像内其他 GPL 组件并存，不构成链接冲突）。用户声明为自编代码，但**运行期行为仍未在设备上验证**（`NOT TESTED`） |

#### 2.7.1 `luci-app-online-upgrade` 更新到最新提交（2026-10-22）

用户 2026-10-22 多次指示"online-upgrade 在 GitHub 有更新，集成时请使用最新的代码"，
pin 由 `73b49b4f130e3b82105ad2eaaf5d55d1a96a2411`（1.1.3-r1）依次移到
`a332aad7…`（1.1.3-r2）、`c229eea325ea51694768229792b2ec3d4f199fb8`
（1.1.3-r3，2026-10-22T15:03:57Z），再移到
`d41b81a30d98e08de210aca424cdb4bf1c7eaf1f`（1.1.3-r4，2026-10-22T23:16:41Z）。

**第三次更新（当前 pin，1.1.3-r4）**

| 项 | 内容 |
|---|---|
| 远端 | `https://github.com/Arthur97172/luci-app-online-upgrade`（`git fetch origin`：`main` 由 `c229eea` 前进到 `d41b81a`；该提交尚无 tag，最新 tag 仍为 `1.1.3-r3`） |
| 变更范围 | 5 个文件、+172/−22：`Makefile` `PKG_RELEASE` 3→4；`root/usr/bin/online-upgrade.sh` 新增升级互斥锁与下载完整性校验；`online-upgrade.js` 统一隐藏四个升级入口、页面加载时探测进行中的升级；`po/templates` 与 `po/zh_Hans` 补新串 |
| 功能变化 | ① 升级互斥：`/tmp/online-upgrade.lock` 用 `mkdir` 原子创建并写入 `pid`；持锁进程已不存在时清理残留锁。`background` 模式由父进程抢锁后经 `ONLINE_UPGRADE_LOCK_HELD=1` 移交给 `setsid` 子进程，直接 `upgrade` 入口同样抢锁，被拒绝的重复调用不再覆盖正在运行那次的状态文件；② `curl -sL` → `curl -fsSL`，404/403 等错误页不会写成固件；③ 期望大小在 GitHub 模式取资产 `size`，直链模式回退到 HEAD 的 `Content-Length`；④ 下载缓存键由 `ASSET_UPDATED` 改为 `FILE_NAME\|DOWNLOAD_URL\|ASSET_SIZE\|ASSET_UPDATED`，避免同一 Release 内切换资产后复用旧镜像；⑤ `.gz` 资产追加 `gzip -t` 完整性检查；⑥ 前端在页面加载时用锁 `pid` + 状态文件判断升级是否进行中，`fs.exec` 非 0 退出时停止轮询 |
| 审计结论 | 安全态势继续**改善**：关闭了"校验通过 → 刷写之间镜像被并发 `curl -o` 截断"的 TOCTOU 窗口；下载错误页/截断包不会再落到 `sysupgrade`。新增的 `fs.exec('/bin/sh', ['-c', …])` 命令为静态字符串、无用户可控输入；无新增依赖（`gzip`、`kill` 均为 busybox 内建/自带）、无 ELF、无构建期下载。**残留**：`acquire_lock` 在"读到的 pid 为空 → `rm -rf` 重建"路径上存在极窄竞态（两进程同时启动且持锁方尚未写入 pid 时，双方都可能继续）；`gzip -t` 只覆盖 `.gz` 扩展名。运行期仍为 **NOT TESTED** |
| 复核命令 | `git diff --stat c229eea d41b81a`；`git log -1 --format='%H %cI %s'`；`git status --porcelain` 为空；`sh -n root/usr/bin/online-upgrade.sh` 与 `sh -n root/www/cgi-bin/online-upgrade-restore` 均通过 |
| 构建影响 | `luci-app-online-upgrade` 需重新编译；本轮的 banner / `99-wireless-defaults` 三轮构建在此 pin 上进行 |

**第二次更新（历史，1.1.3-r3）**

| 项 | 内容 |
|---|---|
| 远端 | `https://github.com/Arthur97172/luci-app-online-upgrade`（`git fetch origin`：`main` 由 `a332aad` 前进到 `c229eea`；该提交尚无 tag） |
| 变更范围 | 6 个文件、+309/−101：`Makefile` `PKG_RELEASE` 2→3；`root/usr/bin/online-upgrade.sh` 新增 `restore <file>` 模式；`root/www/cgi-bin/online-upgrade-restore` 重写；`online-upgrade.js` 改为统一走脚本恢复；`po/templates` 与 `po/zh_Hans` 补新串 |
| 功能变化 | ① 手动/自动恢复统一调用 `online-upgrade.sh restore`：先用 `sysupgrade -b` 给当前配置拍快照，目标归档恢复失败则用快照回滚（退出码 1/2/3/4 区分）；② 恢复前拒绝含绝对路径或 `..` 段的 tar 成员；③ CGI 由"任意 POST 直接 `tar xzf` 到 `/`"改为一次性令牌鉴权（令牌由已登录的 LuCI 页面经 `fs.exec` 以 root 写入 `/root/.online-upgrade-restore.token`，`umask 077`，校验后立即删除）、仅接受 POST、16 MiB 上限、临时文件 `mktemp`；④ legacy `/etc/config/sysupgrade.tgz` 路径也改为完整恢复并补确认框（旧实现无确认直接解包 `etc/config/`） |
| 审计结论 | 安全态势**改善**：修复了前一 pin 中 `/cgi-bin/online-upgrade-restore` 无鉴权即可触发 root 级配置恢复的问题。令牌生成命令无用户可控输入（`dd \| md5sum \| cut`），前端以 argv 形式调用 `fs.exec`，无 shell 拼接；tar 成员检查用 `(^\|/)\.\.(/$\|)\|^/`，不放行路径穿越。仍无新增第三方依赖、无 ELF、无网络下载。R-22（`sysupgrade` 镜像无签名校验）事实不变 |
| 复核命令 | `git diff --stat a332aad c229eea`；`git log -1 --format='%H %cI %s'`；`git status --porcelain` 为空 |
| 构建影响 | 编译探针 `package/luci-app-online-upgrade/compile` 退出 0，产出 `luci-app-online-upgrade_1.1.3-r3_all.ipk` 与 `luci-i18n-online-upgrade-zh-cn_26.295.54237~c229eea_all.ipk`（`logs/probe_online_upgrade_r3.log`）。G3.9 三轮构建在此 pin 上进行 |

**第一次更新（历史，1.1.3-r2）**

| 项 | 内容 |
|---|---|
| 变更范围 | 2 个文件、+32/−2：`PKG_RELEASE` 1→2；`online-upgrade.js` 把琥珀色提示框的内联配色改为 `.online-upgrade-note` 类，按 `prefers-color-scheme`、Argon `data-argon-mode`、Bootstrap `data-darkmode` 三种暗色信号切换 |
| 审计结论 | 纯前端 CSS/JS 与版本号改动；无新增端点、无新增依赖 |
| 复核命令 | `git diff --stat 73b49b4 a332aad` |

### 2.8 ★ UPnP 组件（G3.8，2026-10-22）

用户于 2026-10-22 要求把 UPnP 集成进固件，选择范围
`miniupnpd-nftables` + `luci-app-upnp`（与厂商同版本、同变体）。

| 组件 | 来源 | 版本 | 许可证 | 取证 |
|---|---|---|---|---|
| `miniupnpd` | `qca/feeds/packages/net/miniupnpd`（已固定在本项目的 QSDK 导入中） | **2.3.7-r1** | BSD-3-Clause | 上游 tarball `https://miniupnp.tuxfamily.org/files/miniupnpd-2.3.7.tar.gz`，SHA-256 `fbdd5501039730f04a8420ea2f8f54b7df63f9f04cde2dc67fa7371e80477bbe`，与 Makefile `PKG_HASH` 一致（`dl/` 内复核） |
| `libcap-ng` | `qca/feeds/packages/libs/libcap-ng` | 0.8.4-r1 | GPL-2.0-or-later / LGPL-2.1-or-later | `https://people.redhat.com/sgrubb/libcap-ng/libcap-ng-0.8.4.tar.gz`，SHA-256 `68581d3b38e7553cb6f6ddf7813b1fc99e52856f21421f7b477ce5abd2605a8a`，与 `PKG_HASH` 一致 |
| `luci-app-upnp` | `sources/luci/applications/luci-app-upnp`（luci pin `d0400718…`） | 26.201.69796~d75e0b9 | Apache-2.0 | 随既有 luci feed，无新增外部下载 |

| 项目 | 值 |
|---|---|
| 接入方式 | `package/feeds/packages/{miniupnpd,libcap-ng}` 手工符号链接（`packages` feed 无索引）；`scripts/feeds install -p luci luci-app-upnp`（日志 `logs/feeds_install_g38_upnp.log`） |
| 变体 | `miniupnpd-nftables`（包内 `DEFAULT_VARIANT`，与本镜像 firewall4/nftables 一致；`miniupnpd-iptables` 显式关闭） |
| 构建期联网 | 首次构建下载上述两个上游 tarball；此后 `dl/` 命中，离线可重建 |
| 运行期 | 守护进程按 `/etc/config/upnpd` 运行，默认 `enabled 0`（与厂商配置相同）；风险见 R-27 |

### 2.9 ★ G3.9 第三方应用与代理栈（2026-10-22）

用户于 2026-10-22 要求把 PassWall、Nikki、OpenClash、poweroff、
bandix-plus 集成进固件。**2026-10-24 用户把
poweroff 改用自己维护的仓库 `Arthur97172/luci-app-poweroff`，包名由
`luci-app-poweroffdevice` 变为 `luci-app-poweroff`**（旧 sirpdboy 版本
`8f53359c…` 不再参与构建；其 GPL-3.0 头声明且无 LICENSE 文件的记录保留在
git 历史与本表下方备注中）。**2026-11-07 用户要求移除 `luci-app-cpu-status`
与 `luci-app-wifihistory`**（连同 `OneNAS-space/luci-app-cpu-status` 仓库、
`openwrt/luci` 的 sparse 检出、43 文件断言与 wifihistory 专用补丁一并删除），
并把其余第三方组件升到最新 release tag。全部源码在
`sources/thirdparty/` 下按 40 位 commit 固定（日志 `logs/clone_g39.log`），
每个目录的 `rev-parse HEAD` 均与下表一致。

> 自 2026-10-24 起，pin 的**机器可读副本**是
> `24.10-6.6/build/thirdparty-feeds.conf`（文件 A），可用
> `24.10-6.6/scripts/thirdparty-feeds.sh check` 逐目录校验 HEAD、工作区与
> `thirdparty-feed` 软链。升级时两处必须同步：本表记许可证与提交信息，
> 文件 A 供脚本执行。

| 目录 | 远端 | **固定 commit** | 提交时间 | 提交标题 | 许可证 |
|---|---|---|---|---|---|
| `openwrt-passwall` | `Openwrt-Passwall/openwrt-passwall` | `0b969d5a49743a9725c8dc283b01753c5217dd0d` | 2026-11-03T23:26:50+08:00 | `luci: bump 26.11.3`（tag `26.11.3-1`） | GPL-3.0（`LICENSE`；Makefile 头声明 GPLv3） |
| `openwrt-passwall-packages` | `Openwrt-Passwall/openwrt-passwall-packages` | `da712cf06cf4e6fd39e147fb36e6ec936003fcc9` | 2026-10-31T22:21:39+08:00 | `xray-core: update to 26.10.31 (#770)`（仓库无版本 tag，取 `main` 分支头） | 逐包声明（见下表）；仓库无顶层 `LICENSE` |
| `OpenWrt-nikki` | `nikkinikki-org/OpenWrt-nikki` | `78e1a751d55ed0762811f054ee699049473da7b8` | 2026-10-14T17:11:28+08:00 | `fix: do not restart cron service after crontab changed` | GPL-3.0（`LICENSE`） |
| `OpenClash` | `vernesong/OpenClash` | `e553e82e01c697aefbe1555261a503f425e00ccd` | 2026-10-11T13:10:57+08:00 | `0.48.002` | **MIT**（`LICENSE`，Copyright 2019-2026 vernesong） |
| `luci-app-poweroff` | `Arthur97172/luci-app-poweroff` | `05f8ac3e8bfc6c176efe7648959cb816cf555b51` | 2026-10-25T13:34:55Z | `docs: reorder README sections and add screenshot` | GPL-3.0-only（`LICENSE` 与 `PKG_LICENSE` 一致） |
| `luci-app-bandix-plus` | `timsaya/luci-app-bandix-plus` | `c4f002f74f3a0f4aeb79fb5d35f5a7bbd3392a1f` | 2026-10-21T18:54:43+08:00 | `luci-app-bandix-plus: bump to 0.1.3-r2` | Apache-2.0（`LICENSE`；Makefile 头误写 GPLv2，以 `PKG_LICENSE` 与 `LICENSE` 为准） |
| `openwrt-bandix-plus` | `timsaya/openwrt-bandix-plus` | `fba9704300f2900451e00a1645e11b1f179204b8` | 2026-10-21T18:46:15+08:00 | `bandix-plus: bump to 0.1.3-r1` | Apache-2.0（`LICENSE`） |

`sources/passwall-selected/`（新目录，不带 `.git`）是从
`openwrt-passwall-packages` 上述 commit **复制**出的 7 个包目录。复制结果
用 `git ls-tree -r <sha> -- <dirs>` 与 `find` 逐文件比对，**809/809 文件一致**。
之所以不整棵 feed 引入：上游同一仓库还包含 `xray-core`、`sing-box` 等与
qca feed 同名的包，以及本项目明确不打包的 `shadowsocks-rust`、`haproxy`、
`smartdns`；只复制所需目录可避免包名冲突与误装。各包锚点：

| 包 | 版本 | 许可证 | 构建方式 |
|---|---|---|---|
| `chinadns-ng` | 2025.08.09 | **AGPL-3.0-only** | **预编译二进制**：GitHub Release `chinadns-ng+wolfssl_noasm@aarch64-linux-musl@generic+v8a@fast+lto`，aarch64 `PKG_HASH 42ddd494…`；无 `Build/Compile` |
| `dns2socks` | 2.1 | BSD-3-Clause | 仓库内 vendored `src/`，无下载 |
| `ipt2socks` | 1.1.4 | **AGPL-3.0** | 上游 tarball `v1.1.4`，`PKG_HASH 68dc76e6…` |
| `microsocks` | 1.0.5 | MIT | 上游 tarball |
| `tcping` | 0.3 | GPL-2.0-only | git `db910183…`，`PKG_MIRROR_HASH 36776bf6…` |
| `simple-obfs` | 0.0.5 | GPL-3.0-or-later | git `486bebd9…`，`PKG_MIRROR_HASH bc97eba5…` |
| `shadowsocksr-libev` | 2.5.6 | GPL-3.0 | 仓库内 vendored `src/`，无下载 |

代理核心**不使用**上游 PassWall 的最新版，而使用 qca feed 树内版本：

| 包 | 版本 | 许可证 | 来源与校验 |
|---|---|---|---|
| `xray-core` | **25.1.30** | MPL-2.0 | `qca/feeds/packages/net/xray-core`，`https://codeload.github.com/XTLS/Xray-core/tar.gz/v25.1.30`，`PKG_HASH 983ee395…` |
| `sing-box` | **1.12.12** | GPL-3.0-or-later | `qca/feeds/packages/net/sing-box`，`https://codeload.github.com/SagerNet/sing-box/tar.gz/v1.12.12`，`PKG_HASH f08add81…` |

原因（用户 2026-10-22 决策）：上游 `openwrt-passwall-packages` 的
xray-core 26.10.21 要求 Go 1.27、sing-box 1.14.3 要求 Go 1.25.5、
geoview 0.2.8 要求 Go 1.25.0、v2ray-plugin 5.49.0 要求 Go 1.25.5，而树内
`golang/host` 为 **1.23.12**（三级 bootstrap 固定）。因此改用树内兼容版本，
并**放弃 geoview 与 v2ray-plugin**（无 Go 1.23 兼容发行版）。PassWall 的
`INCLUDE_Geoview` / `INCLUDE_V2ray_Plugin` 显式关闭，界面相应缺少
geosite/geoip 管理与 v2ray-plugin 选项，属已知取舍。

其余锚点：`nikki` 2026.10.10（GPL-3.0+，脚本/ucode 包，无编译）、
`mihomo-meta` **1.19.32**（GPL-3.0+，git `v1.19.32`，
`PKG_MIRROR_HASH adeda246…`，Go 构建）、`luci-app-nikki` 1.26.2
（Makefile 未设 `PKG_LICENSE`，按仓库 `LICENSE` 记 GPL-3.0）、
`luci-app-openclash` **0.48.002**（`PKGARCH:=all`，内置
`Country.mmdb` 205,449 B、`GeoSite.dat` 10,407,328 B、
`oc-cn-domain.mrs` 556,732 B、`china_ip*_route.ipset` 与 zashboard/
metacubexd 前端产物；仓库 LICENSE 为 **MIT**）、
`luci-app-poweroff` **1.0.0-r1**（自维护仓库，`LUCI_DEPENDS:=+luci-base`，
`PKGARCH:=all`，无外部联网、无预编译二进制；i18n 包
`luci-i18n-poweroff-zh-cn` 由 `po/zh_Hans/poweroff.po` 经 `luci.mk` 生成）、
`luci-app-bandix-plus` 0.1.3-r2、`bandix-plus` 0.1.3-r1。

2026-11-07 升级后的第三方版本锚点：`openwrt-passwall` 26.11.3（tag `26.11.3-1`）、
`openwrt-passwall-packages` 取 `main` @ `da712cf0`、`luci-app-poweroff` 1.0.0-r1
（`05f8ac3e`）、`luci-app-nikki` 1.26.2、`luci-app-openclash` 0.48.002；
`passwall-selected` 的 7 个包版本不变（`dns2socks` 2.1-r3、`ipt2socks` 1.1.4-r3、
`microsocks` 1.0.5-r2、`shadowsocksr-libev` 2.5.6-r13、`simple-obfs` 0.0.5-r3、
`tcping` 0.3-r1、`chinadns-ng` 2025.08.09-r1），只随新的 packages pin 重新派生。

| 项目 | 值 |
|---|---|
| 接入方式 | `feeds.conf` 追加 `src-link thirdparty …/sources/thirdparty-feed` 与 `src-link passwall_selected …/sources/passwall-selected`；2026-11-07 又追加 `src-link routing qca/feeds/routing`（只为 meshassistant 的 batctl/kmod-batman-adv）。`thirdparty-feed` 只含 9 个指向固定 clone 的符号链接，避免把 `openwrt-passwall-packages` 的 60 多个包（含同名 `xray-core`/`sing-box`）索引进 feed |
| `feeds/packages` 路径 | 新建 `sources/buildroot/feeds/packages -> ../qca/feeds/packages` 软链，满足第三方包的 `include $(TOPDIR)/feeds/packages/lang/{golang,rust}/…` 与 luci 的 `findrev`；`packages` feed 仍未建立索引，包通过 `package/feeds/packages/` 手工符号链接可见 |
| 构建期联网 | 首次下载各包 `PKG_SOURCE`/`PKG_MIRROR_HASH` 对应的 tarball 或 git 镜像；其中 **`chinadns-ng` 与 `bandix-plus` 下载的是 GitHub Release 的 aarch64 预编译二进制**（`chinadns-ng+wolfssl_noasm@aarch64…`、`bandix-plus-0.1.3-aarch64.tar.gz`，`PKG_HASH 42ddd494…` / `46de71c3…`）；`mihomo-meta`、`xray-core`、`sing-box`、`yq` 首次需构建 `golang/host` |
| 运行期联网（应用自身功能） | PassWall/Nikki/OpenClash 会按用户配置连接代理服务器、订阅 URL，并（OpenClash）在 Web UI 运行时下载 mihomo 内核；`luci-app-oxidns` 在用户点击时用 `curl`/`uclient-fetch`/`wget` 下载插件与规则（URL 由用户配置、可走用户配置的代理）；meshassistant 只操作本机 batman-adv/dawn；poweroff、tasks、smartnetpilot、xpu-status 无外部联网。均记录于 `docs/SECURITY_FINDINGS.md` §7.9 与 R-28…R-34；五个新应用的逐行联网审计仍为 **NOT TESTED** |
| 本地修改 | 无。`wifihistory` 原先的一行 include 改写随该应用一起删除（2026-11-07）；其余 7 个 clone `git status --porcelain` 为空 |
| 供应链结论 | 全部公开 GitHub、逐 commit 固定；许可证以 GPL 系为主，`chinadns-ng`/`ipt2socks` 为 **AGPL**，`chinadns-ng` 与 `bandix-plus` 为预编译二进制（`LICENSE_REVIEW_REQUIRED`）；运行期一律 `NOT TESTED` |

下面是插件 pin 的机器可读快照：`scripts/ci/refresh-pins.sh` 每次运行都会在
两个标记之间整段重写，因此 pin 刷新 PR 的 diff 里直接能看到“哪个仓库换了哪个
commit”。标记行本身不要删改，否则脚本会报错退出。

<!-- pins:begin -->
| 仓库 | commit | 备注 |
| --- | --- | --- |
| `apps/luci-app-fcc` | `d4ce1abd4de62cb19cada29d32ee2ce6d85be0f9` | 1.2.0-r2（tag） |
| `apps/luci-app-ledfancontrol` | `540eefcf9dc8550f44a3a38afe84f20ec11f195f` | 1.1.0-r1（tag） |
| `apps/luci-app-meshassistant` | `d51d2cf215b09ac49085605ba19cc981eb45555f` | 2.6.3-r1（tag）；依赖 routing feed 的 batctl/kmod-batman-adv |
| `apps/luci-app-nssecm` | `af6f4abe6ccb4147addfd3975bd45451e13d03a6` | 1.0.0-r1（tag） |
| `apps/luci-app-online-upgrade` | `82e42330e63ca63cff238e9d82b160aa253c7990` | 1.1.3-r4（tag） |
| `apps/luci-app-oxidns` | `6c432f6d6492cf6a8cbf63b8d5dbe8d67642853f` | v1.3.5（tag） |
| `apps/luci-app-smartnetpilot` | `b80e836a0669c03fe6eb956e9e36205292e56f9f` | 1.1.8-r1（tag） |
| `apps/luci-app-substore` | `af1649541acb63eba447bb0f5652eb990cf17c1f` | 2.7.3-r3（tag） |
| `apps/luci-app-tasks` | `c1665942cda36b4f7668c6eb167968a03b26193f` | 1.1.1-r1（tag） |
| `apps/luci-app-xpu-status` | `14e7d81a75cf864396f308d1a8e83bcc1d5d53d6` | v1.0.3（tag） |
| `repo bandix-core` | `fba9704300f2900451e00a1645e11b1f179204b8` | thirdparty/openwrt-bandix-plus |
| `repo bandix-luci` | `c4f002f74f3a0f4aeb79fb5d35f5a7bbd3392a1f` | thirdparty/luci-app-bandix-plus |
| `repo nikki` | `78e1a751d55ed0762811f054ee699049473da7b8` | thirdparty/OpenWrt-nikki |
| `repo openclash` | `e553e82e01c697aefbe1555261a503f425e00ccd` | thirdparty/OpenClash |
| `repo passwall` | `0b969d5a49743a9725c8dc283b01753c5217dd0d` | thirdparty/openwrt-passwall |
| `repo passwall-packages` | `da712cf06cf4e6fd39e147fb36e6ec936003fcc9` | thirdparty/openwrt-passwall-packages |
| `repo poweroff` | `05f8ac3e8bfc6c176efe7648959cb816cf555b51` | thirdparty/luci-app-poweroff |
<!-- pins:end -->

#### 2.9.1 追加：DDNS / ttyd / Mount Points（2026-10-22，用户追加要求）

三项均取自**本仓库既有来源**，不新增外部 clone：

| 组件 | 来源 | 版本 | 许可 / 备注 |
|---|---|---|---|
| `ddns-scripts`（+ `ddns-scripts-services`、`-utils`、`-luadns`） | qca 树内 `net/ddns-scripts` | 2.8.2-64 | GPL-2.0；`PKGARCH:=all`，纯脚本，**无构建期下载** |
| `luci-app-ddns` | `feeds/luci` 树内 | 24.10 快照 | Apache-2.0；依赖仅 `+luci-base +ddns-scripts` |
| `ttyd` | qca 树内 `utils/ttyd` | 1.7.3-1 | MIT；`PKG_HASH c9cf5eece52d27c5d728000f11315d36cb400c6948d1964a34a7eae74b454099`，`PKG_SOURCE_URL` 为 codeload.github.com |
| `libwebsockets-full` | qca 树内 `libs/libwebsockets` | 4.3.3 | MIT；`PKG_HASH 6fd33527b410a37ebc91bb64ca51bdabab12b076bc99d153d7c5dd405e4bdf90`，ttyd 的强依赖 |
| `libuv` | qca 树内 `libs/libuv` | 见 feed Makefile | MIT；ttyd 依赖 |
| `block-mount` | 树内 `package/system/fstools`（与 `fstools`、`snapshot-tool`、`blockd` 同一 Makefile） | 2024.07.14~408c2cc4 | GPL-2.0；提供 `/sbin/block`、`/etc/init.d/fstab`、`/etc/config/fstab`，是 LuCI “挂载点”页面（`luci-mod-system` 的 `admin/system/mounts`，受 `"fs": {"/sbin/block": "executable"}` 门控）显示的前提 |
| `sbe1v1k-defaults`（**本项目自有**） | `build/local-packages/sbe1v1k-defaults/`，构建时复制进 `sources/buildroot/package/` | 1-r1 | MIT；只安装 `/etc/uci-defaults/99-ttyd-disable`，把 `ttyd.ttyd.enable` 置 0。原因：树内 `ttyd.init` 的校验规则是 `'enable:bool:1'`，配置缺省即视为启用，会在 `@lan` 上以 `/bin/login` 监听 7681 |

构建期联网：`ddns-scripts`/`luci-app-ddns`/`block-mount` 均无下载；`ttyd`、`libwebsockets`、`libuv` 首次构建时按 `PKG_SOURCE_URL` + `PKG_HASH` 下载源码 tarball（哈希已在树内固定）。

本地修改：本次追加不含对树内/feed 源码的改动（当时的 `luci-wifihistory` include 改写已在 2026-11-07 随该应用删除）；ttyd 的默认关闭通过独立的自有包实现，vendor feed 保持原样。

#### 2.10 用户提供的本地覆盖文件（2026-10-22）

两个文件由用户直接放在项目根目录 `sources/` 的上一级（仓库根），**无上游仓库、无版本号**，
本项目只做逐字节复制，不做内容修改：

| 文件 | 来源 | 大小 | SHA-256 | 装配位置 |
|---|---|---|---|---|
| `banner` | 用户提供 | 1,041 B | `d649da4e4a286b0b66c3558cb0b5c3f756d33f64e320051d93756ca56bbc4011` | `sources/buildroot/files/etc/banner`（覆盖 `base-files` 的 `/etc/banner`） |
| `99-wireless-defaults` | 用户提供的首次启动无线策略脚本；2026-10-22 按用户指示将 `is_supported_board()` 白名单改为**仅 `spectrum,sbe1v1k`**（原 Airoha/Gemtek/Nokia 板型全部移除），并同步修改文件头注释、失败提示语与幂等标记（`MARKER` 改为 `system.@system[0].spectrum_wireless_defaults`） | 10,455 B | `6b49b1b9675bc7d7b074b4478fbbd79fc5ab401de95a7e809a1df7271e4ec293` | `sources/buildroot/files/etc/uci-defaults/99-wireless-defaults`（模式 0755，首次启动执行后由 `/etc/init.d/boot` 删除） |

复核：`cmp <仓库根>/banner sources/buildroot/files/etc/banner`、
`cmp <仓库根>/99-wireless-defaults sources/buildroot/files/etc/uci-defaults/99-wireless-defaults` 均返回 0。
覆盖机制与已知限制（该脚本的板型白名单**仅含** `spectrum,sbe1v1k`，默认口令
`12345678`，属于已知弱口令，首次启动后必须由用户修改）见
`docs/BUILD_TREE_ASSEMBLY.md` §10.3。

---

## 3. 构建树装配图（官方 manifest 原文推导）

```
<buildroot>/
├── target/linux/                     ← QSDK 树自带（不含 ipq95xx）
│   └── feeds/
│       ├── <target/ipq 内容>          ← ipq95xx 平台目标
│       ├── files-6.6/                ← linux-ipq-files（DTS）
│       └── patches-6.6/              ← linux-ipq-patches-6.6
└── qca/
    ├── src/linux-6.6/                ← linux-ipq-6.6
    ├── src/qca-wifi/component_dev/   ← wifi/qca-wifi-oss（**只有源码，无 Makefile**）
    ├── src/mac80211/wlan-open/       ← oss/src/mac80211/wlan-open
    ├── src/network/services/hostapd/ ← oss/src/network/services/hostapd
    ├── feeds/nss/base/               ← oss/system/feeds/nss-base
    ├── feeds/nss/clients/            ← oss/system/feeds/nss-clients
    ├── feeds/nss/apps-oss/           ← oss/system/feeds/nss-apps
    ├── feeds/wlan-open/mac80211/     ← oss/system/feeds/wlan-open
    └── feeds/wlan-hostapd/hostapd/   ← oss/system/feeds/wlan-hostapd
```

> **注意**：`qca/src/qca-wifi/component_dev`（qcawifi 源码）**不含任何 `Makefile`/`Kbuild`**，
> 而 `qca/feeds/wlan-open/` 只提供 ath11k/ath12k/mac80211/cfg80211。
> 即：**公开组件集里没有 qcawifi 的 OpenWrt 包** —— 见 `docs/G2_STATIC_CHECKS.md` §6。

机制在源码中可验证：

| 位置 | 内容 |
|---|---|
| `include/scan.mk:13` | `QSDK_PACKAGE_DIR:=$(TOPDIR)/target/linux/feeds` |
| `include/target.mk:68` | `PLATFORM_DIR:=$(firstword $(wildcard $(TOPDIR)/target/linux/feeds/$(BOARD) $(TOPDIR)/target/linux/$(BOARD)))` |
| `target/linux/Makefile` | `-C $(firstword $(wildcard feeds/$(BOARD) $(BOARD)))` |

> 即：**QSDK 修改了上游 OpenWrt 的 `target/linux/Makefile`**，使 `target/linux/feeds/<board>` 优先于
> `target/linux/<board>`。这是平台目标"不在 `target/linux` 里"却仍能构建的原因。

---

## 4. 复核方法（任何人可重做）

```sh
# 1. QSDK 基座
git clone --depth 1 --branch 14.0 https://github.com/everything411/qsdk
cd qsdk && git rev-parse HEAD          # 应为 21a8d133…52f
git rev-parse HEAD^{tree}              # 应为 b8ceb12b…dee5

# 2. 官方平台目标
git clone --branch win.openwrt.24.10.r1 \
    https://git.codelinaro.org/clo/qsdk/oss/system/feeds/target/ipq
cd ipq && git rev-parse HEAD           # 应为 3c993a55…068
git rev-parse HEAD^{tree}              # 应为 5f2fae23…067
```

---

## 5. 安全声明

- 克隆所得的代码**未被执行**，仅以文本方式读取。
- 未在任何克隆目录内运行解释器。
- 原始固件（`firmware/`）**未被改动**，SHA-256 与本项目基线一致。

> **2026-10-21 补充（状态变化）**：用户批准「把 P-B 安装进 sources，准备首次构建」后，
> 已在**独立的装配树** `sources/buildroot/` 中执行 `scripts/feeds update -a`、
> `scripts/feeds install -a` 与 `make defconfig`。这些是本地配置步骤：feed 仅用
> `src-link` 指向本地目录，未联网下载工具链或软件包源码，也未编译任何代码。
> 原始克隆目录 `sources/qsdk14/`、`sources/codelinaro/*` 保持未改动。
> 未连接 `192.168.10.142`，未使用任何口令。详见 `docs/BUILD_TREE_ASSEMBLY.md`。

---

**状态**：G1 **完成**（66/77 仓库按 manifest SHA 锁定并校验；11 项未取且理由已记录）。
G2 静态检查见 `docs/G2_STATIC_CHECKS.md`。
