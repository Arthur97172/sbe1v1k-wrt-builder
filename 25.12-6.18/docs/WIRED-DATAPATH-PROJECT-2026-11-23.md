# 6.18 NSS 有线数据面修复项目（2026-11-23 立项，用户已批准）

本文件是 `S3E-ETH0-WAN-CLOCK-DIAG-2026-11-23.md` §6.5–§6.6 的后续：用户
2026-11-23 批准「立项修 6.18 NSS 有线数据面」，并同意让 6.18 镜像的
`SUPPORTED_DEVICES` 同时声明 `askey,sbe1v1k` 与 `spectrum,sbe1v1k`。

刷机、重启、远程操作仍须用户逐次批准（项目 CLAUDE.md 门禁）；本文件只记录
本地源码改动与构建状态。

## 1. 缺陷清单（同一镜像 sha256 `2e452ced…4d69` 的全部取证）

| # | 缺陷 | 现象 | 关键证据 | 取证位置 |
|---|---|---|---|---|
| D1 | eth2/eth3（qca8075，SSDK port 3/4）不通 | netdev 无流量，PHY 未绑定 | dmesg `mdio_bus 90000.mdio-1: MDIO device at address 18 is missing.`（19 同）；`ssdk_port_phylink_setup: PPE port 3/4 failed to connect PHY, ret -19`；`/sys/bus/mdio_bus` 只有 0x00、0x1c | S3E §6.5 |
| D2 | eth1（WAN，QCA8081，port 5）出口全丢 | 链路 2500/SGMII PLUS/ENABLE，但 DHCP/NAT 全不通 | `/sys/ssdk/packet_counter`：PORT_TX_COUNTER port5 持续增长、VP_TX_DROP 同量级增长，**dropcode 119 "TX MAC disable drop"**；XGMAC `MAC_TX_CONFIGURATION`=0x40010001 (TE=1)、`appe_port_mux_ctrl`=0x3010 指 XGMAC、`PORT_BRIDGE_CTRL`(0x60314)=0x30139 txmac_en=1 全为开；phycounter Sys 侧双向 0（该计数读后清零，见下） | S3E §6.5 |
| D3 | eth0（RTL8261N，port 6，USXGMII）AN 死锁 | 6/6 确定性（5 热重启 + 1 冷上电），AN=0x0、零帧 | ssdk 在 ~16.0 s 配置 uniphy 并使能 USXGMII AN；PHY 建链/固件加载在 16.5 s 左右；`qca_hppe_mac_sw_sync_task` 的 AN 检查只等 100 ms，超时打 `uniphy autoneg time out!` 后**无条件**封存 `port_old_link = UP`，AN 不再重试 | S3E §6.2–§6.3 |

## 2. 统一根因假设（H1）：6.18 树缺 6.12 的 MDIO phy-reset 脉冲

6.12 树在 2026-11-18 真机上踩过完全相同的 D1：`0036-qualcommbe-mdio-phy-reset-and-port-bmp.patch`
的叙述写明「MDIO device at address 16/17/18/19/28 is missing」「-19 for PPE
ports 3/4/5」「WAN dead」。修复是两层：MDIO 总线驱动在扫描前脉冲
`phy-reset-gpio` 整组 GPIO（内层 `patches-6.12/0150`），并把 QCA8081 与
RTL8261N 的复位从各自 PHY 节点收回到这组数组里。

6.18 树没有移植这两层，后果按时间轴看：

1. qca8075 包（tlmm 60）在 MDIO 扫描前没有被硬复位 → 地址 18/19 无应答
   → D1（`-19`）。
2. QCA8081（tlmm 52）与 RTL8261N（tlmm 41）的复位只剩 phylib 按节点
   probe 时的那一次（~16.5 s、16.59 s），晚于 qca-ssdk ~16.0 s 的
   uniphy 配置与 USXGMII AN 使能；AN 是一次性的、超时不重试
   （`qca_hppe_mac_sw_sync_task` 封存逻辑）→ D3 在 6.18 上确定性失败，
   而 6.12 因为数组里有 tlmm 41、早期硬复位过，只剩 ~50% 概率。
3. D2 是否同一根因尚未闭环：dropcode 119 与「链路/使能位全开」的矛盾
   更像 PHY↔MAC 的 SGMII 参数没有真正对齐（PHY 侧系统口双向零帧）。
   若 QCA8081 在 ssdk 配置 SGMII/SGMII PLUS 之后被 phylib 复位（16.5 s），
   其 SGMII 侧协商状态会被清掉，与 MAC 侧参数失配——这正是把复位提前
   可以消除的窗口。因此 H1 同时覆盖 D1/D3，并对 D2 有可证伪的预测。

反证检查：6.12 与 6.18 的 `adpt_hppe_portctrl.c` 逐字相同、DTS 的端口/
PHY 参数相同，唯一结构性差异就是这套复位补丁与 phylink/PCS 环境；D2 的
dropcode 119 在 6.12 上从未出现。

## 2bis. E1 判决与假设修正（2026-11-23 真机，镜像 `38dd29fc…`）

E1 只兑现了 H1 的第一条：

- D1：驱动层 PASS（四 PHY 全部绑定，无 `missing` / `-19`）。
- D3：AN 死锁**无变化**，6/6 依然失败。MDIO 侧的 tlmm 41 早期复位没有改变
  RTL8261N 与 XPCS 的握手结果。
- D2：dropcode 119 消失，但帧仍停在系统侧。注意
  `SysRxGoodFrame/SysTxGoodFrame` 读数恒为 0 是接口性质而不是证据：
  `nss_phy_common_stats_get()` 从不填这两个字段，6.12 正常工作时同样读 0。
  D2 的判据只剩 DHCP 失败与 PPE 口计数。

因此 H1 对 D3/D2 的解释被削弱：D3 是 6.12 上就已存在的、与 MDIO 复位
无关的握手死锁（见下），D2 需要一个独立于 H1 的根因。

### 2bis.1 D3 与 6.12 同一缺陷

`25.12-6.12/docs/ETH0_XPCS_AN_BOOT_2026-11-22.md` 记录的 6.12 缺陷
（约 50% 启动失败）与 6.18 E1 的失败签名逐位相同：XPCS `0x1f0000=0x1120`、
`0x1f8001=0x101`、`0x1f8002=0x0`，PHY 报 `SerDes link did not come up`。
6.12 侧的结论：单侧重启 AN（`ssdk_sh port autoNeg restart`、SR_MII_CTRL
bit9）、XPCS 块软复位（bit15）、PHY unbind/bind、固定速率、`ip link` 翻转
全部无效（其中 bit15 会让 XPCS 寄存器永久读 0 直到重启），只有重启能恢复；
当时留待验证的方向是「两侧在同一次上电路径里重新配对，必须走 ssdk 内部
带时钟/复位的初始化序列」，从未实测。

另外本节曾判「ssdk 的 `reset(N) not exist!` 与 reset-core WARN 与 6.12
同类，非 D3 原因」——**该判断在 E2 取证后被推翻**：6.18 的 uniphy 节点
比 6.12 多出 `sys`/`soft` 两条复位（BSP `patches-6.18/0356`），PCS 驱动
独占后 ssdk 丢掉 sys×3 与 uniphy0 soft，厂商软件复位失效。详见 §2ter。

### 2bis.2 时钟假设（原 §2.2，已排除）

6.12 正常工作的基线（`logs/relink-2026-11-21/baseline.txt`）在同一 2.5G
链路上 `nss_cc_port5_tx_clk_src` 同样是 125 MHz，并且同样打印
`ssdk_uniphy_port5_clock_source_set:ERROR:set parent fail!`。因此
6.18 的时钟读数与 `set parent fail!` 不是异常，原先计划的 A/B 刷机
（对照 6.12 v94 的时钟）不再需要。

## 2ter. E2 判决与统一根因（2026-11-23 真机，镜像 `4456b8cf…`）

E2（ssdk 0018，USXGMII AN 超时后完整 re-init）真机：D3 仍 FAIL
（re-init 跑完、`uniphy2 autoneg still incomplete after re-init`），
D2 仍 FAIL。但 E2 的 7 条 reset-core WARN 与 `reset(N) not exist!`
给出了 D2/D3 的**统一根因**：

- 6.18 BSP 在 uniphy0/1/2 节点补了 `resets = xpcs, sys, soft`
  （`patches-6.18/0356`）；重写后的 PCS 驱动（0323）probe 时三条全
  exclusive 持有。
- qca-ssdk 经 ess-switch 复位表申请同名线 → -EBUSY。7 条失败
  （id 0/1/3/5/14/15/16）与 DTB 数值逐一对应：uniphy0 soft（nsscc
  0x6d）、xpcs×3（gcc 0x87/0x8a/0x8d）、sys×3（gcc 0x85/0x88/0x8b）。
- ssdk 每次接口模式切换后必做的
  `__adpt_ppe_gcc_uniphy_software_reset()`（assert sys → 1 ms →
  deassert）因此静默失效，serdes 不锁存新模式：SGMII+（port 5，
  D2）与 USXGMII（port 6，D3）同源；0018 的 re-init 复用同一函数，
  所以救不回来。
- 6.12 的 uniphy 节点只有 xpcs，sys×3 与 u0 soft 一直归 ssdk，
  所以 6.12 正常。

**E4（修复，`patches/0040`）**：NSS 变体 DTS 把 &pcs0/1/2 的复位裁剪
回 6.12 形态（仅 xpcs），sys/soft 交还 ssdk；xpcs 保持 PCS 持有（6.12
把 xpcs 交给 ssdk 独占曾弄死 10G 口，见 25.12-6.12/patches/0037 v2）。
复位 WARN 应从 7 条降回 6.12 的 3 条。判据：D2/D3 按 §5 表格；附带
观测 dmesg 只剩 3 条 WARN、`reset(0/14/15/16)` 不再出现。

## 3. E1（第一号实验，已落地源码，设备已测）

补丁 `patches/0038-qualcommbe-mdio-ipq4019-phy-reset-and-rtl-reset.patch`：

- 内层新文件 `patches-6.18/0150-net-mdio-ipq4019-phy-reset-gpios.patch`
  （6.12 `0150` 的 6.18 移植）：`ipq_mdio_reset()` 里对 `phy-reset-gpio`
  整组做 100 ms 保持 + 释放，再沉降 1 s（我们比 QSDK 早约十秒扫总线）；
  驱动 probe 用 `devm_gpiod_get_array_optional(..., "phy-reset", GPIOD_OUT_LOW)`。
- NSS DTS：`&mdio` 的数组补上 tlmm 41，`rtl8261be_0` 与 `qca8081_28`
  节点去掉 `reset-gpios`（复位所有权全部交给 MDIO 驱动，phylib 不再在
  16.5 s 二次拉线）；注释同步。
- 特意不移植 QSDK 的 `ipq_cmn_clk_reset()`（0x9b000 已被 ipq-cmn-pll
  独占映射，二次 ioremap 必 -EBUSY）——与 6.12 结论一致。

同一个交付里的非实验改动（不构成变量）：

- `patches/0037-qualcommbe-sbe1v1k-supported-devices.patch`（重写）：
  两个变体都声明 `SUPPORTED_DEVICES := askey,sbe1v1k spectrum,sbe1v1k`，
  跨树（25.12-6.12 / 24.10 的 compatible 是 `spectrum,sbe1v1k`）
  升级免 `-F`。反方向（6.12/24.10 镜像回到 6.18 固件）仍需 `-F`，
  那些树尚未做对称声明。
- `patches/0039-qualcommbe-sbe1v1k-nss-switch-bmp.patch`：NSS DTS 的
  `switch_lan_bmp/switch_wan_bmp` 从 0x38/0x40 改为 6.12 已验证的
  0x58/0x20（eth1 WAN、其余 LAN）。运行期角色由 S19 `sbe-port-roles`
  写 SSDK 成员表，DTS 这两个值不到硬件（脚本头注释有同样结论），
  因此这是消除文献与 6.12 树不一致的整理项，不当作实验变量。

E1 的预测（若 H1 成立）：dmesg 无 "MDIO device ... missing"、port 3/4
不再 `-19`、LAN 有线口可用；eth0 AN 在冷上电与热重启下建立；D2 若同根因，
plot5 的 dropcode 119 停止增长、eth1 拿到 DHCP 租约。

## 4. 后续实验（E1 未达判据时，按顺序单变量进行）

- **E2（D3 直接修法，已落地为 `nss/patches/qca-ssdk/0018`）**：
  `qca_hppe_mac_sw_sync_task` 的 link-up 边沿在
  `adpt_hppe_uniphy_autoneg_status_check()` 里等 100 ms AN 完成位，失败
  依旧封存 `port_old_link = UP`。0018 把等待拆成
  `adpt_hppe_uniphy_usxgmii_an_wait(retries)`，并在 USXGMII 模式下失败时
  调用新增的 `adpt_hppe_uniphy_usxgmii_mode_reinit()`（`__...mode_set()`
  本体 + 与 `adpt_hppe_uniphy_mode_set()` 相同的 raw clock 恢复）最多两次，
  每次再等 2 s，日志区分「recovered after re-init」与「still incomplete」。
  这就是 6.12 文档留下未测的「完整初始化序列」方向。UQXGMII 保持原行为。
  不动 `qca_hppe_mac_sw_sync_task` 的封存逻辑：AN 若能重新完成，后续
  MAC 速度/双工配置路径按既有分支执行。
- **E3（D2 判别）**：以只读方式对比 6.12 与 6.18 同一端口在同一阶段
  （ssdk 配置后、PHY probe 前后）的 SGMII/USXGMII 参数寄存器与
  `ssdk_sh port linkstatus` 结果，判定是参数失配还是 PPE 侧 VP 的
  TX MAC 位；若 119 指向 PPE VP，则继续查 `ppe_vp_port` 系列寄存器与
  VP 的 txmac 使能路径（`adpt_hppe_port_txmac_status_set` 在 APPE 下的
  真实落点）。
- **E4（PCS/phylink 适配审计）**：审计 nss-dp 在 6.18 的 phylink 集成
  （`phylink_create/connect_phy`、PCS ops、`mac_select_pcs`）；6.12 的
  nss-dp 与 6.18 的 phylink 语义差异（尤其 AN 完成后 phylink 是否回写
  MAC）是 D2/D3 的备选根源。
- **E5（时钟侧复核）**：0036 已让 PCS 驱动注册、port5/6 时钟到
  125 MHz/31.25 MHz（真机 PASS）；若 E1–E4 均失败，再复核 uniphy 父
  时钟名与 `set parent` 失败日志（S3E §6.5 记录过一次 `set parent`
  失败，当时判为无关噪声）。

## 5. 验收判据（刷机后按缺陷逐条判定）

| 缺陷 | 判据 |
|---|---|
| D1 | dmesg 无 `MDIO device at address 18/19 is missing`、无 `ret -19`；`/sys/bus/mdio_bus` 出现 0x12/0x13（18/19 十进制记法：0x12=18、0x13=19）；插线后 eth2/eth3 rx 增长 |
| D2 | `/sys/ssdk/packet_counter` 的 VP_TX_DROP dropcode 119 在 DHCP 期间停止增长；eth1 拿到上游租约；上游侧看到 WAN MAC 的帧 |
| D3 | 冷上电与 ≥3 次热重启，`eth0` AN 寄存器非 0、usxgmii 链路 up、eth0 rx 增长（USB 网卡接到 10G 口） |
| 打包 | 6.18 两变体镜像在跑 6.12 固件的设备上 `sysupgrade -n` 不报 not supported |

任意一条 PASS/FAIL 都如实记录到本文件 §7，截图式证据（dmesg 片段、
寄存器值、计数前后）写进测试记录。

## 6. 回退与风险

- 回退：撤销 0038/0039、恢复 0037 旧文本即可重建上一版镜像；设备侧回退
  走既有流程（Reset+TFTP+RAM 系统 `sysupgrade -F -n`，见
  `recovery-mode-v65-rollback` 经验）。
- 风险 1：tlmm 41 早期复位若与 RTL8261N 的固件加载时序冲突，可能让 eth0
  链路更差——判据 D3 能直接暴露；届时先把 41 从数组撤掉、保留 60/52。
- 风险 2：1 s 沉降让 MDIO 扫描整体后移约 1 s，可能压到其它驱动的
  probe 顺序（无硬依赖，ssdk 在 16 s 之后才动作）。
- 风险 3：去掉节点 `reset-gpios` 后，若 MDIO 驱动没拿到数组（DT 拼写
  错误），所有 PHY 都没有复位——prepare 的 DTS 断言与真机 dmesg 均可
  发现；`phy-reset-gpio` 属性 qca-ssdk 仍按 index 0 读取，tlmm 60 保持
  第一位不变。

## 7. 状态跟踪

| 项 | 状态 | 记录 |
|---|---|---|
| H1/E1 补丁 0038 | 已合入源码；内层 0150 对 6.18.64 内核 `--fuzz=0` DRYRUN-OK | 2026-11-23 |
| 0037 双设备名 | 已重写；正向/反向 dry-run 均 OK | 2026-11-23 |
| 0039 switch bmp 对齐 | 已合入源码（整理项） | 2026-11-23 |
| 本地构建 | **PASS**（2026-11-23 14:32/14:35，world EXIT=0；内核已含 `ipq_phy_reset_pulse`，NSS DTB 数组 60/52/41、bmp 0x58/0x20、PHY 节点无 reset-gpios） | 双镜像重建后 `verify-image` PASS=130 FAIL=0 |
| verify-image | **PASS 130 / FAIL 0**（两镜像元数据均含 `askey,sbe1v1k`、`spectrum,sbe1v1k`） | 2026-11-23 |
| NSS 镜像 sha256 | `38dd29fc6d7581461140640e459e89bcca39deea7aeca0449cb0edf134238f2a`（sysupgrade） | 确定性重建两次一致 |
| 真机测试 | **第一轮完成（E1 镜像，sha `38dd29fc…`）**：D1 驱动层 PASS（四 PHY 全绑定、无 missing/-19）；D2 dropcode 119 消失但系统侧仍零帧 → **FAIL**；D3 AN 死锁不变 → **FAIL** | `WIRED-DATAPATH-DEVICE-TEST-2026-11-23.md` |
| D3 根因比较 | 6.18 E1 与 6.12 的 AN 死锁签名逐位相同；`SysRx/SysTxGoodFrame` 恒 0 是接口不填值，不算证据；`set parent fail!`/125 MHz 与 6.12 基线一致 → 时钟假设排除 | 2026-11-23 |
| E2 补丁 0018 | 已合入源码；`patch --fuzz=0` 干净应用；`package/qca-ssdk/clean` 后单独编译 PASS，`qca-ssdk.ko` 含新日志串 | 2026-11-23 |
| E2 镜像 | **构建 PASS**：双镜像 `build-images.sh` EXIT=0；`verify-image` PASS=130/FAIL=0；NSS sysupgrade sha256 `4456b8cf01cd415b18d321d18b32732ef8b44d6868827506b8c44127561ecc52`（版本串仍是 `sbe1v1k-6.18-bae017a5`，改动未提交）；rootfs 内 `qca-ssdk.ko` 已含 re-init 日志串 | 2026-11-23 |
| E2 真机测试 | **完成（经用户批准刷入）**：D3 FAIL（re-init 执行、`still incomplete`）、D2 FAIL；7 条 reset WARN 定案统一根因（uniphy sys/soft 被 PCS 驱动独占） | `WIRED-DATAPATH-DEVICE-TEST-2026-11-23.md` §5 |
| E4 补丁 0040（复位所有权回到 6.12） | 已生成 `patches/0040-qualcommbe-sbe1v1k-nss-pcs-reset-parity.patch`；`patch --fuzz=0` 对装配树原文件 dry-run 与实应用均 OK、结果逐字节一致 | 2026-11-23 |
| 重置根因证据 | E2 dmesg 7 条 WARN / 7 条 `reset(N) not exist!` ↔ E2 DTB：nsscc 0x6d、gcc 0x87/0x8a/0x8d（xpcs）、gcc 0x85/0x88/0x8b（sys）全部与 PCS 节点同名；u1/u2 的 `soft` 在 ess-switch 表里实为 PORT5/6_ARES，不冲突（与「只有 u0 soft 报错」一致） | 2026-11-23 |
| E3（驱动替换）可行性 | 已静态验证：vendored `rtl8261n` 驱动对 6.18.64 + GCC 15.3 编译通过；确定接入方式=从 DEVICE_PACKAGES 去掉 `kmod-phy-realtek`、加 `CONFIG_RTL8261N_PHY=y`、补 generic/files 与 hack-6.18/735 等价补丁。暂不实施，留作 E4 失败后的备选 | 2026-11-23 |
| E4 镜像 | **构建 PASS**（2026-11-23 深夜）：`build-images.sh world` EXIT=0，`verify-image` PASS=130/FAIL=0；NSS sysupgrade sha256 `05eedd2196e4a0a82909cccb0181db74220b44a9a4c74201956b504f5858854b`；内嵌 DTB 已确认三 uniphy 节点只剩 `xpcs`（旧 `xpcs/sys/soft` 三元组 0 次），ess-switch 25 条复位表完整 | 2026-11-23 |
| E4 真机测试 | **完成（2026-11-24，经批准刷入）**：复位所有权判据全中——WARN 7→3（只剩 xpcs 0x87/0x8a/0x8d），`reset(0/14/15/16)` 消失；**D2 PASS**（DHCP 租约、`ping -I eth1` 3/3、DNS、HTTP 200、port5 rx 计数增长）；**D3 确定性缺陷消除**：3 启 1 坏 2 好，坏启动 0x1f8002=0x0 与 6.12 签名逐位一致、好启动 0x7000 且主机经 10G 口 ping 4/4；D1 保持 PASS | `WIRED-DATAPATH-DEVICE-TEST-2026-11-23.md` §6 |
| 下一步 | ① 决定残留 D3 概率性坏启动的对策（6.12 的 S95 看门狗在有线口上是否移植到 6.18，坏启动占比约 1/3 但样本小）；② 更多次热重启/冷上电统计坏启动率；③ 提交 0040 及整批 S3 改动需用户明确指示（结论已 PASS 但 D3 残留未清零） | 2026-11-24 |
