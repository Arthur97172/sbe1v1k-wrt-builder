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

## 5. 已知难点（按 6.12 踩坑记录预判）

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

## 6. 不做的事

- 不在本阶段改动 6.18 的启动配置、不把 NSS 包选入镜像、不刷机。
- 不搬 6.12 的板级补丁（eMMC/PWM/OPP 等）——上游 6.18 已覆盖。
- 不删除 mainline PPE 兜底路径，NSS 验证通过前两者并存。
