# NSS Wi-Fi offload：现状、接入触发条件与执行清单

日期：2026-11-19
状态：**咨询结论已记档；等待 Qualcomm 发布对齐 6.12 的 wlan-open；未排期**

## 决策（2026-11-19，用户拍板）

**等 Qualcomm 未来发布对齐 6.12 的 wlan-open（新 QSDK 换代）后，25.12 接入
NSS Wi-Fi offload 与厂商 ath12k 私有参数。** 在那之前：

- 不立项，不手工前向移植厂商驱动；
- 25.12 保持 mainline ath12k（backports）+ 有线 NSS 卸载；
- 需要 Wi-Fi 卸载的场景继续用 24.10-6.6（其无线栈即为 Qualcomm 现役最新版）。

## 现状对照（2026-11-19 核实）

| | 25.12-6.12 | 24.10-6.6 |
|---|---|---|
| NSS Wi-Fi offload | **未接入**（设计上排除） | **已接入** |
| 厂商 ath12k 私有参数 | **没有**（mainline，仅 `debug_mask`/`ftm_mode`） | **有**（约 20 个厂商参数） |
| ath12k 来源 | OpenWrt mac80211 包，backports **6.18.55** | wlan-open feed，mac80211 **6.6.15** / backports-6.1-9a0dddfb3，ath12k 1139 个补丁 |
| hostapd / wifi-scripts | 上游 `wpad-mesh-mbedtls` + 标准 wifi-scripts | QSDK `wpad-mesh-openssl-noextns` + QSDK wifi-scripts（0018/0022/0024/0026/0027 已知差异） |

证据：

- 25.12 `build/config-seed/ipq95xx-spectrum-sbe1v1k.seed` W1 注释：「暂不含 Wi-Fi
  卸载……ppe-ath-clients 只是把 ath 客户端注册给 PPE 的通用模块（源码里没有
  ath12k 符号），真正的 Wi-Fi 卸载插件属于 W2/W3，本轮不接」；Stage 2.5 注释：
  这些包「need the QSDK wlan feeds and the vendor ath12k fork」。
- 25.12 构建 rootfs 模块集：有 qca-nss-dp/ppe/sfe 等数据面模块与
  `qca-nss-ppe-ath-clients.ko`，**没有** `qca-wifi-nss-plugins.ko` /
  `qca-nss-wifi-plugins.ko`。
- 25.12 ath12k 模块（backports-6.18.55）`core.c` 只有 `debug_mask`、`ftm_mode`。
- 24.10 `build/config-frozen/.config`：`CONFIG_PACKAGE_kmod-qca-nss-wifi-plugins=y`、
  `CONFIG_PACKAGE_kmod-qca-wifi-nss-plugins=y`；构建 rootfs 两模块均在，
  `ath12k.ko` 内含 `ppe_ds_enable`、`mlo_capable`、`pkt_pre_hdr_mode`、
  `fse_3_tuple_enabled`、`io_coherency`、`max_clients`、`en_fwlog` 等符号。
- 24.10 源 pin：`build/upstream-pins.conf` — qca-wifi-oss `ee42324…`（line 51）、
  nss-plugins（qca-nss-wifi-plugins）`65a1a1b…`（line 42）、wlan-hostapd
  `edfb8399…`（line 52）；wlan-open feed mac80211 PKG_VERSION 6.6.15。

## 为什么现在不能接

1. **卸载链路只在厂商 ath12k 里。** Wi-Fi 侧插件 `qca-wifi-nss-plugins.ko`
   直接链厂商 ath12k 内部接口（`ppe_ds_enable` 等参数即其开关），mainline
   ath12k 没有这些钩子。
2. **厂商栈只认 6.6 内核，且没有更新版本。** 本仓库最新的 Qualcomm 公开
   快照 `sources/qsdk14` = **QSDK 14.0.1595.1670**（分支 14.0），只有
   `qca/src/linux-6.6`；其 wlan-open mac80211 仍是 6.6.15 /
   backports-6.1-**9a0dddfb3**——与 24.10 构建所用 backports 哈希相同。
   codelinaro 远端 wlan-open 分支最高到 QSDK 13.0.x，同样无 6.12 版本。
3. **手工前向移植不可行。** 厂商 ath12k fork 在 mac80211 6.6.15 上叠了约
   1139 个补丁；搬进 25.12 等于把它们重落到 mainline ath12k 6.18.55 上，
   跨内核 6.6→6.12 与 mac80211 6.6→6.18 两轮 API 大改，属厂商团队工程量级。
4. 25.12 镜像里已有的一半（`qca-nss-ppe-ath-clients`、NSS 驱动/固件）只是
   NSS 侧登记件，缺 Wi-Fi 驱动侧的对应插件，单靠它无法形成卸载通路。

## 厂商 ath12k 私有参数分类（2026-11-19）

**结论先行：私有参数不能单独接入。** 参数是厂商 ath12k fork 的控制面开关，
大多数背后是 mainline 不存在的代码路径；它们随「6.12 版厂商无线栈」一起
进来，不需要（也无法）作为独立任务。好消息是厂家参数的**默认值对应的行为
mainline 基本都已等价具备**，当前 25.12 的无线行为与厂商默认配置一致。

依据：24.10 厂商树 `backports-6.1-9a0dddfb3/drivers/net/wireless/ath/ath12k`
的 `core.c` 共约 48 个 `module_param`，逐个按引用文件分类；对照 25.12 的
mainline 树 `backports-6.18.55`。

### A 类：与 Wi-Fi 卸载绑死（约 13 个，随卸载栈一起进来）

`ppe_ds_enable`、`ppe_ds_wifi8_enable`、`ppe2tcl_rings_max`、
`reo2ppe_rings_max`、`txrx_hw_auto_idx`、`hw_buff_mgmt`、
`ppe2wbm_ring_size`、`pkt_pre_hdr_mode`、`fse_3_tuple_enabled`、
`ppe_rfs_support`、`rfs_core_mask`、`congestion_ctrl`、`drop_algo`。

引用全在 `CPTCFG_ATH12K_PPE_DS_SUPPORT` 条件块及厂商 `ppeds.c`/`fse.c`/
`dp*.c` 扩展里，mainline 无此代码。注意：mainline 6.18.55 的 `hw.c` 里有
"PPE release ring address"，那只是上游对 PPE 硬件释放环的 HAL 描述，不是
卸载数据通路。

### B 类：厂商固件/调试接口的开关（约 15 个，开关小、背后特性大）

`en_fwlog`、`boot_time_qdss`、`waltest_mode`、`upload_q6dump_to_cloud`、
`rx_nwifi_err_dump`、`debug_level`、`debug_critical`、`cfr_enable_bmap`、
`ssr_failsafe_mode`、`skip_caldata`、`cold_boot_cal`、`fw_mem_seg`、
`wsi_bypass_bmap`、`erp_cumac_config`、`6ghz_sp_pwrmode_supp_enabled`，
以及 AFC 相关（`afc_disable_req_id_check`、`afc_disable_timer_check`、
`afc_reg_no_action` 等）。

「接入」等于把背后的厂商 WMI/QMI 命令、reg 逻辑、coredump 上传通道一起搬；
mainline 里没有 AFC 支持，fwlog 是另一套机制（见 C 类）。

### C 类：mainline 已有等价机制，不需要搬

| 厂商参数 | 厂商默认 | mainline 现状（backports 6.18.55） |
|---|---|---|
| `en_fwlog` | 开 | QMI 里硬编码 `enable_fwlog = 1`（`qmi.c:3371`） |
| `frame_mode` | ethernet | 固定走以太网帧交付（与默认一致） |
| `mlo_capable` | 开 | 按固件能力自动启用 MLO |
| `max_clients` | 512 | 无此参数，由固件/资源上限决定 |
| `io_coherency` | 开（编译开关） | 走标准 DMA API / dma-coherent 语义 |
| `probe_order` | — | 用 DT 顺序 + 本项目补丁 0038（射频命名）解决 |
| `debug_mask` / `ftm_mode` | — | 两个都有（仅有的两个 module_param） |

### D 类：厂商数据面调优（约 5 个，依附卸载通路）

`reorder_VI_timeout`、`mlo_3_link_tx`、`mcast_link_bmap_enable`、
`carrier_vow_optimization` 等，是给 PPE/卸载数据面用的微调，随 A 类一起
进来。

### 对决策的意义

- 触发条件满足后要做的只有一件事：**接入 6.12 版厂商无线栈**；参数随之
  到位，届时只需决定配置层面（哪些用默认值、哪些启用/关闭）。
- 在那之前「单独接入私有参数」没有收益也不可行：约一半参数对应功能不
  存在，另一半的默认行为 mainline 已等价实现。
- 若将来某个**具体行为**确有需求（而非「要有这些参数」），正确做法是给
  mainline ath12k 写定向小补丁，单独评估。

## 触发条件（全部满足才立项）

1. codelinaro 出现对齐 **kernel 6.12** 的 wlan-open：出现 `qca/src/linux-6.12`
   或 wlan-open 的 mac80211 包基线升级（`MAC80211_PKG_KERNEL_VERSION` /
   backports 指向 6.12 内核）；
2. 该分支可编在 25.12 所用 6.12.x 内核上（若官方支持的内核小版本不同，
   先评估跟内核的成本再定）；
3. 厂商 ath12k 的 hw 表覆盖 **QCN9274 hw2.0**（本机芯片），且 BDF/firmware
   结构兼容现有 6 个 blob（`board-2.bin` 的 qmi-board-id=1/2/4）。

### 监测方法（只读，建议与内核 pin 跟踪合并做，季度或内核换代时执行）

```sh
# 1) 远端 wlan-open 分支：找 QSDK 13/14/15 之后的新分支
GIT_TERMINAL_PROMPT=0 git ls-remote --heads \
  https://git.codelinaro.org/clo/qsdk/oss/system/feeds/wlan-open.git \
  | grep -E 'QSDK\.1[3-9]|14\.|15\.' | tail -20

# 2) 拿到新快照后看两处：
#    qca/src/ 下是否出现 linux-6.12
#    qca/feeds/wlan-open/mac80211/Makefile 的 PKG_VERSION / backports-*
#    mac80211_package.mk 的 MAC80211_PKG_KERNEL_VERSION
```

判据落地方式：任一条件出现即在本文「观测记录」加一行；三条全满足时改状态为
`READY`，提请立项。

## 观测记录

| 日期 | 观测 | 结论 |
|---|---|---|
| 2026-11-19 | QSDK 14.0.1595.1670：linux-6.6、mac80211 6.6.15/backports-9a0dddfb3；codelinaro wlan-open 最高 13.0.x | 不满足，继续等待 |

## 接入清单（触发 READY 后执行）

1. **版本对齐评估**：新 QSDK 的 OpenWrt 基线 vs 我们的 25.12（`OPENWRT_SHA`
   + 5 个 feed pin），确定替换面。
2. **mac80211 包替换**：按 24.10 的 feed 替换法接入 wlan-open 的 mac80211
   （含厂商 ath12k 补丁集），替换 `package/kernel/mac80211`。
3. **hostapd 替换**：QSDK `wlan-hostapd` fork（`wpad-mesh-openssl-noextns`
   一类变体）；确认 `-v11be` 探针（25.12 补丁 0021）在 fork 上是否已自带。
4. **wifi-scripts**：换 QSDK 版，重做 24.10 的 0018/0022/0024/0026/0027
   已知差异补丁。
5. **NSS Wi-Fi 插件包**：`kmod-qca-wifi-nss-plugins`（wlan-open，
   `.ko` 名 `qca-wifi-nss-plugins`）+ `kmod-qca-nss-wifi-plugins`
   （nss-plugins）；`qca-nss-ppe-ath-clients` 已在镜像。
6. **固件/BDF**：厂商 blob 已在 `sbe-wifi-firmware`；核对新版驱动 hw 表与
   `board-2.bin` 变体选择是否仍兼容，ART 校准提取流程不变。
7. **本项目无线补丁重审**：0033（`qcom,board_id` 回退，厂商栈若自带则删）、
   0038（射频命名）、0039（LuCI 排序）、无线默认值三项。
8. **栈内版本一致性**：NSS 组件（nss-drv / nss-plugins / ppe / ecm / sfe）
   必须同源同代——参见 24.10 的版本对齐教训（mac80211 与栈版本不同代
   不能混搬）。
9. **回归面**：Wi-Fi 功能（6G/MLO/11be）、有线 offload、dawn、
   ledfancontrol hwmon 阻塞、wifi_qos 空表；`make DUMP=1` 确认 ABI。
10. **真机验证**：按现行「先 RAM 变体、再 eMMC」流程，验证项含
    2.5G/10G、Wi-Fi 吞吐与 CPU 占用对比（卸载收益的量化基线要在接入前
    用 25.12 现行镜像采一次）。

## 风险与备注

- 新 QSDK 换代可能同时带走我们已做的板级适配（DP 设备树、eth1 QCA8081
  修复 0030、事件驱动挂桥等）；核对范围要覆盖 `patches/` 全部无线相关项。
- 厂商栈历史上有 noextns/杂项全局项问题（24.10 的 0024 一类），mesh/6G
  相关回归必须实测。
- 本文件的触发监测是**只读**任务，不得自动改任何 pin。
