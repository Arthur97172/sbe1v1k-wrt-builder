# S3d 真机验收 —— 25.12-6.18 mainline 变体（2026-11-23）

## 0. 结论

**mainline 变体真机 PASS**（有 2 项待修缺陷，均为界面/日志层面，不影响数据通路）：

- 启动、网口角色、WAN DHCP、LAN、2.4G/5G/6G 三频 AP、LuCI、风扇/LED、时区默认值全部符合预期；
- NSS 门控在 mainline 镜像上生效（`nss-board` rc=1、`/sys/ssdk` 不存在、`qca-ssdk` 未装载）；
- 缺陷 1：LuCI「最大传输功率」下拉对三个射频都只显示 `255 dBm (2147483647 mW)`
  —— 已定位根因（libiwinfo 的 6 GHz 兼容缺口 + 负值哨兵），修复方案见 §3.3；
  **修复后真机 PASS（§8）**；
- 缺陷 2：`/etc/firewall.d/qca-nss-ecm` 在 mainline 上执行并报 `iptables: not found`
  —— NSS 包未按 `nss-board` 门控，见 §4；**修复后真机 PASS（§8）**。

NSS 变体（S3e）尚未刷机验证，等用户单独批准。

## 1. 镜像与刷机

| 项 | 值 |
|---|---|
| 变体 | mainline：`openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin` |
| 版本 | `sbe1v1k-6.18-86a810fd`（S3d 双遍构建的 mainline 产物） |
| 内核 | 6.18.64 |
| 刷写方式 | `scripts/device/flash-sysupgrade.sh`（scp `-O` + 设备侧 sha256 比对 + `sysupgrade -n`） |
| 管理链路 | USB 网卡 → `192.168.1.1`（LAN）；取证时 uptime 1545 s |
| 取证方式 | `scripts/device/device-accept.sh`（只读），日志 `logs/accept-mainline-2026-11-23.log` |

## 2. 验收结果

| 检查项 | 证据 | 判定 |
|---|---|---|
| 型号/板卡 | `model: Spectrum SBE1V1K`、`board_name: askey,sbe1v1k`（补丁 0004 生效） | PASS |
| banner | ASCII ART + `Version: 25.12-SNAPSHOT (sbe1v1k-6.18-86a810fd)` | PASS |
| 数据通路门控 | `nss-board rc=1`；`/sys/ssdk 不存在`；未装载 `qca-ssdk`/`qca-nss-dp`/`qca-nss-ppe` | PASS |
| mainline PPE 绑定 | `qcom_ppe 3a000000.ethernet` 四个 PHY 全部绑定：lan2/lan3=QCA8075、wan=QCA8081、lan1=RTL8261BE | PASS |
| 网口角色 | `wan`（2.5G）拿到上游 DHCP `192.168.10.236/24`；`lan1`（10G）、`lan2`/`lan3`（1G）在 `br-lan` | PASS |
| 端口 MAC | wan `90:d3:cf:4b:eb:82`、lan1 `:81`、lan2 `:83`、lan3 `:84`（互不相同） | PASS |
| LAN | `br-lan 192.168.1.1/24`、LuCI HTTP 200 | PASS |
| 无线默认值 | country=US；radio0=2.4G/ch11/EHT20/`WiFi_2.4G`、radio1=5G/ch40/EHT80/`WiFi_5G`、radio2=6G/ch37/EHT320/`WiFi_6G` | PASS |
| 三频 AP | 三个 AP 全部 `up`：wl0.2-ap0(2.4G)、wl0.1-ap0(5G)、wl0.0-ap0(6G 6.135 GHz)；**6 GHz 本次可用**（S1b 时的 regdb 不可用问题已消失） | PASS |
| 时区 | `system.@system[0].timezone='CST-8'`、`zonename='Asia/Taipei'`，`date` 显示 CST | PASS |
| 风扇 | `fan1_input=3114`，`pwm1=112`，`pwm1_enable=1`；温度 39–58 °C | PASS |
| LED | `blue:status green:status mmc0:: red:status` | PASS |
| 服务 | nss/sbe-port-roles/sbe-lan-mac/eth0-lan-attach/wireless-defaults 均 enabled（NSS 服务运行期由 `nss-board` 把关） | PASS |
| 日志噪声 | 共 15 行：12 行 ath12k `qmi dma allocation failed` / `WMI MAC1 connect failed`（S1b 已记录为已知噪声）+ 3 行 §4 的 iptables 噪声 | 见 §4 |

## 3. 缺陷 1：LuCI「最大传输功率」只显示 255 dBm

用户报告：网络 → 无线 → WiFi_2.4G/5G/6G 的「编辑」页，「最大传输功率」下拉只有
`255 dBm (2147483647 mW)` 一项。

### 3.1 现象取证（设备侧）

| 调用 | 结果 |
|---|---|
| `ubus call iwinfo txpowerlist {"device":"radio0/radio1/radio2"}` | 各 1 项：`{dbm:255, mw:2147483647}` |
| `ubus call iwinfo txpowerlist {"device":"wl0"}` | 同上 1 项 |
| `ubus call iwinfo txpowerlist {"device":"wl0.0-ap0"}`（6G ch37） | 同上 1 项 |
| `ubus call iwinfo txpowerlist {"device":"wl0.1-ap0"}`（5G ch40） | 31 项 0–30 dBm |
| `ubus call iwinfo txpowerlist {"device":"wl0.2-ap0"}`（2.4G ch11） | 31 项 0–30 dBm |
| `iwinfo wl0.0-ap0 txpowerlist`（25.12 的 ucode 版 CLI） | 31 项 0–30 dBm（与 ubus 不同实现） |

LuCI 的 `CBIWifiTxPowerValue`（`wireless.js:624`）把 **wifi-device 段名**（radio0/1/2）
直接传给 rpc；libiwinfo 按其 UCI `phy='wl0'` 解析到物理 phy `wl0`，三个射频共用
同一个 phy（QSDK ath12k 一个 phy 带三个频段的 VIF）。

### 3.2 根因（已用源码闭环）

1. `rpcd` 插件走 C 版 libiwinfo：`nl80211_get_txpwrlist()` →
   `NL80211_CMD_GET_WIPHY` 请求**没有** `NL80211_ATTR_SPLIT_WIPHY_DUMP` 标志
   （`iwinfo_nl80211.c:2606`）。
2. 内核 cfg80211 对未申请 split dump 的调用**直接跳过 5 GHz 以上频段**：
   `net/wireless/nl80211.c:2880`「omit higher bands for ancient software」——
   6 GHz 频段根本不在回复里。
3. 该 phy 的第一个 VAP 是 6 GHz 的 `wl0.0-ap0`（ch37），`ch_cur=37` 在
   2.4/5 GHz 频段里找不到对应频率 → 回调保持 `*dbm_max = -1`（哨兵）。
4. `struct iwinfo_txpwrlist_entry.dbm` 是 **uint8_t**（`include/iwinfo.h:290`），
   -1 存入后变成 **255**；`iwinfo_dbm2mw(255)` 溢出饱和为 `INT_MAX`
   （2147483647）。于是列表只剩一条假的 255 dBm。
5. 同一文件里的 `nl80211_get_freqlist` / `get_hwmodelist` / `get_htmodelist`
   都正确带上了 split dump 标志（`iwinfo_nl80211.c:3295/3519/3654`）——
   `txpwrlist` 是漏网的那一个，属上游 libiwinfo 的 6 GHz 兼容缺口。
6. 25.12 的 `iwinfo` CLI 是 ucode 实现（`/usr/bin/iwinfo` 为 ucode 脚本），
   走的是带 split dump 的另一套解析，所以 CLI 显示正常，掩盖了问题。

### 3.3 修复（已实施，2026-11-23）

按用户指示修复并重新构建。改动以两层补丁落地（沿用 6.12 树给 libiwinfo
打补丁的先例）：

| 层 | 文件 | 内容 |
|---|---|---|
| 项目补丁 | `patches/0035-iwinfo-txpwrlist-split-wiphy-dump.patch` | 在装配树的 iwinfo 包里新增内层补丁（幂等，prepare 可重复执行） |
| 包补丁 | `package/network/utils/iwinfo/patches/101-txpwrlist-6ghz-split-dump.patch` | 紧随上游 `100-multi_radio.patch` 之后应用 |

内层补丁对 `nl80211_get_txpwrlist()`/`_cb()` 的改动：

1. 请求改走 `nl80211_msg(ifname, GET_WIPHY, flags)` +
   `NLA_PUT_FLAG(NL80211_ATTR_SPLIT_WIPHY_DUMP)`（与 `nl80211_get_freqlist`
   同型）。内核因此不再省略 6 GHz 频段，6 GHz VAP 的信道可以匹配到；
2. 回调参数改成 `struct nl80211_txpwrlist_data { ch_cur, band, dbm_max }`：
   split dump 每条消息只含一个 band/channel，命中后跨消息保留，不再被下一条
   消息重置为 -1；
3. 未命中时 `nl80211_get_txpwrlist()` 直接返回 -1（`*len = 0`），不再把 -1
   哨兵经 `uint8_t` 存成 255 dBm；
4. 三个射频共用一个 phy 的修正：当调用方是 wifi-device 段名（radio0/1/2）时，
   新助手 `nl80211_uci_radio_hint()` 读该段的 `band`/`channel`，按本频段频率
   匹配；auto 信道或非 wifi-device 调用（VAP 名、phy 名）保持原有行为
   （取运行信道，失败时按频段取首个频率）。

效果预期（待真机确认）：radio0 → 2.4 GHz 本频段上限列表（US 30 dBm 档），
radio1 → 5 GHz（ch40 为 23 dBm 档），radio2 → 6 GHz（ch37 为 12 dBm 档）；
下拉不再出现 255 dBm。

### 3.4 修复构建与静态校验（2026-11-23）

| 项 | 结果 |
|---|---|
| 构建 | `scripts/ci/build-images.sh world`（NSS + mainline 两遍），EXIT=0，日志 `logs/build-fix-2026-11-23.log` |
| `verify-image.sh` | **PASS=130 FAIL=0**（较 S3d 的 128 多 2 项，就是两个镜像的 `/etc/firewall.d/qca-nss-ecm` 门控断言）；两份 root 包 DB 反查各 119 PASS / 0 FAIL |
| mainline 镜像 | `openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin`，93,051,153 B，2026-11-23 11:51，sha256 `1f97dfb4a85a5b90be8dc29659a46dfd97df00c9151a907bd269e93fd2462728` |
| NSS 镜像 | `…-nss-squashfs-sysupgrade.bin`，93,061,401 B，sha256 `5659d21498b888aa066afdad26e3b7e8304be9a138d2d59c62d112ae541934c6` |
| 补丁确实入镜像 | 解包 mainline squashfs 后 `usr/lib/libiwinfo.so.20230701` 的 sha256 `b552e58eafa6f98ed2bc434e6773596d6b5a9bbec7ca83faf520fca8a136f261` 与本轮构建的打包副本（strip 后）一致 |
| 版本串 | 仍是 `sbe1v1k-6.18-86a810fd`（未重跑 prepare，版本串只随外层 commit 变）；**区分新旧镜像看 sha256**，不要看版本串/日志日期 |

## 4. 缺陷 2：mainline 上 qca-nss-ecm 的 firewall.d 钩子报错

`/etc/firewall.d/qca-nss-ecm`（qca-nss-ecm 包安装）每次防火墙启动执行三条
`iptables` 调用；本镜像 nftables-only、不带 iptables，于是产生 3 行日志：

```
daemon.notice procd: /etc/rc.d/S19firewall: sh: /etc/firewall.d/qca-nss-ecm: line 19: iptables: not found
```

NSS 服务都已有 `nss-board || exit 0` 门控，但这个 firewall.d 钩子漏掉了。

**修复（已实施，2026-11-23）**：`nss/packages/qca-nss-ecm/files/qca-nss-ecm.firewall`
在版权头之后加 `/usr/lib/sbe1v1k/nss-board || exit 0`（mainline 上整段安静
跳过，NSS 镜像行为不变）；`PKG_RELEASE` 1→2；`verify-image.sh` 的门控断言
循环加入 `etc/firewall.d/qca-nss-ecm`，两个镜像都必须带门控。

## 5. 已知噪声（不阻塞）

- ath12k 每个 phy 一次 `qmi dma allocation failed (29360128 B)` → 小尺寸重试成功，
  以及 `HTC Service WMI MAC1 connect request failed`——S1b 已记录，属预期行为；
- `check access for rdinit=/init failed: -2`——内核 cmdline 解析提示，S1b 同款。

## 6. 工具修正

`scripts/device/device-accept.sh` 原先把临时文件与输出文件混为同一个变量
（`OUT="$OUT.tmp"` 后 `mv "$OUT.tmp" "$OUT"` 自指），本次已改为独立的 `TMP`，
重跑后日志 239 行完整落盘。

## 7. 后续

1. ~~修 libiwinfo（§3.3）与 firewall.d 门控（§4），本机构建 + `verify-image`~~
   —— 已完成（2026-11-23，见 §3.3、§4；构建与校验结果记在表后「修复构建」一节）；
2. 再次刷 mainline 验证两项修复：**真机 PASS（2026-11-23 晚，见 §8）**；
3. mainline 全部 PASS 后，再申请 S3e：刷 NSS 变体做数据通路真机验证。

## 8. 修复真机验证（2026-11-23 19:55 刷入）

镜像为 §3.4 的 mainline 变体（sha256 `1f97dfb4…`）。`sysupgrade -n` 后
重新生成主机密钥（`known_hosts` 旧指纹已清），设备以 root 空密码登录时
`BatchMode` 可直接取证。取证日志 `logs/accept-mainline-fix-2026-11-23.log`。

| 检查项 | 证据 | 判定 |
|---|---|---|
| 跑的是新镜像 | 设备 `/usr/lib/libiwinfo.so.20230701` sha256 `b552e58e…` 与 §3.4 构建件一致；`/etc/firewall.d/qca-nss-ecm` 含 `nss-board` 门控行 | PASS |
| 缺陷 1：255 dBm | `ubus call iwinfo txpowerlist` radio0/1/2 均返回完整 `0–30 dBm` 列表（active=23 dBm）；`"dbm": 255` 计数三个射频全为 0；`wl0`/`wl0.0-ap0`/`wl0.1-ap0`/`wl0.2-ap0` 直查也全是 0–30 | PASS |
| 缺陷 1：按频段提示路径 | 三个射频都须同时满足「频段 + 信道」双条件才可能出列表（`--fuzz=0` 语义下不匹配会返回空），三者都出了列表 → UCI 频段提示在真机生效 | PASS |
| 缺陷 2：firewall.d 噪声 | 启动日志 `iptables: not found` 计数 **0**（修复前 3 行）；`sh /etc/firewall.d/qca-nss-ecm` 静默退出 `rc=0` | PASS |
| 回归面 | 启动、网口角色（wan 拿上游 DHCP 192.168.10.236、lan1/2/3 在 br-lan）、三频 AP 全 up、LuCI 200、风扇 3057 rpm / pwm 114、时区 CST、rc.d 链接齐全 | PASS |
| 日志噪声 | 13 行，全部是 S1b 已记录的 ath12k `qmi dma allocation failed` / `WMI MAC1 connect failed` 与 `rdinit=/init` 提示 | 符合预期 |

一处与开发预期不同、经查属驱动事实：`iw phy wl0 info` 对本 phy 的**所有**
频道（含 6 GHz ch37 6135 MHz）都报 `(30.0 dBm)`。所以 §3.3 预期的
「5G≈23 / 6G≈12」没有出现——regdb 的 12 dBm 限制没有体现为每信道的
`max_tx_power`，三个射频显示一致是 nl80211 的真实上报值，不是修复缺陷。
若日后要按法定功率收紧下拉选项，应走 reg 规则或驱动侧，而不是 iwinfo。

顺带记录：`/etc/firewall.d/qca-nss-ecm` 权限为 644，直接 `./` 执行会
`rc=126`；firewall4 与 rc 都是 `.`/`sh` 加载，不需要可执行位，`sh` 方式
执行 rc=0 即门控有效。
