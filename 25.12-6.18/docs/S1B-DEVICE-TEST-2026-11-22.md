# S1b 真机验证记录（2026-11-22）

- 目标机：B（测试机），经 USB 网卡接 lan1（10G 口），LAN 192.168.1.1。
- 刷入件：`openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin`
  （91,597,073 B，sha256 `d0722aef577ad06752f2a680e2a634c5708bb1eaf972263ae92407cfc879cc67`），
  由 S1 本机构建产出。
- 方式：在旧系统（`sbe1v1k-25.12-c361f288`，board `spectrum,sbe1v1k`）上
  `sysupgrade -F -n`。`-F` 因镜像 BOARD 为上游原生 `askey_sbe1v1k`；
  `-n` 按项目规则不保留配置。设备侧升级脚本按槽位写入 rootfs（p27），
  尺寸校验通过（root 85,655,552 B，分区 121.5 MiB，尾部剩余约 42 MB）。
- 结论：**PASS**（6 GHz 有一项已知限制，见 §4）。

## 1. 启动与系统

- `OpenWrt SNAPSHOT sbe1v1k-6.18-86a810fd`，board `askey,sbe1v1k`，
  内核 6.18.64，`root=/dev/mmcblk0p27 cma=256M`。
- 分区：p25 `0:HLOS`、p26 `0:HLOS_1`、p27 `rootfs`、p28 `rootfs_1`、
  p29 `rootfs_data`（512 MiB）。**与 6.12 树不同**：上游用独立
  `rootfs_data` 分区做 overlay（487 MiB 可用），不再是 rootfs 尾部 ext4。
- 内存：MemTotal 2,024,008 kB，MemAvailable 1,466,256 kB（cma=256M 在）。
- LuCI `http://192.168.1.1/` HTTP 200。
- 刷后 SSH：`-n` 清掉配置后无内置公钥，root 空密码可登录（与恢复 RAM
  系统一致），验证后应设置密码。

## 2. 网口角色（PLAN §2 判据）

| 接口 | DTS 端口 | PHY | 状态 | 证据 |
|---|---|---|---|---|
| `wan` | port@5 | QCA8081（MDIO 0x1c） | up 2500/full，DHCP 192.168.10.236，默认路由 | `qcom_ppe … wan … driver [Qualcomm QCA8081]` |
| `lan1` | port@6 | RTL8261BE 10G（MDIO 0x00） | up 2500/full（USB 网卡） | `… lan1 … driver [RTL8261BE 10Gbps PHY]` |
| `lan2` | port@3 | QCA8075（MDIO 0x12） | down（未插线） | `… lan2 … driver [Qualcomm QCA8075]` |
| `lan3` | port@4 | QCA8075（MDIO 0x13） | down（未插线） | `… lan3 … driver [Qualcomm QCA8075]` |

br-lan = lan1 + lan2 + lan3；wan 独立。与 6.12 的「2.5G=WAN、10G/1G=LAN」
一致（补丁 0001 生效）。

## 3. 数据面与外围

- LAN 客户端（主机 192.168.1.240）经 B NAT 出网：ping 8.8.8.8 3/3、
  157 ms（与直连同量级），mainline PPE（`qcom_ppe`/`pcs_qcom_ipq9574`）在。
- dnsmasq 工作：`/tmp/dhcp.leases` 有主机租约 192.168.1.235。
- 风扇：`hwmon14 pwmfan` pwm=137、3782 RPM；温度传感器 13 路正常（44–47 °C）。
- LED：`green/blue/red:status`、`lan` PHY LED、`mmc0::` 均注册。

## 4. 无线

- ath12k（`ath12k_wifi7`）三频都探测成功，`wifi reload` 后：
  - `wl0.2-ap0`（2.4G）ch1、EHT20、30 dBm，hostapd AP-ENABLED；
  - `wl0.1-ap0`（5G）ch40、EHT80、28 dBm，hostapd AP-ENABLED；
  - `wl0.0-ap0`（6G）**失败**：`hostapd.add_iface failed`，
    `iw phy wl0 info` 里 6G 频点全部 `(disabled)`。
- 6G 根因：固件 regdb 未启用 6GHz（phy self-managed；dmesg 有
  `failed to extract regulatory info from received event` 三连 WARNING）。
  与 6.12 树已知结论一致——6 GHz 可用性取决于固件 `regdb.bin`；6.12 上
  是换用厂商提取的 regdb（TW v1.5）后才可用。S1 用上游 ath12k 固件，
  6G 不可用属预期限制，留到 S2/S3 评估。
- dmesg 已知噪声（不阻塞）：每个 phy 一次 `qmi dma allocation failed
  (29360128 B)` → 小尺寸重试后成功；`HTC Service WMI MAC1 connect
  request failed` 一次后恢复；3 条 reg 提取 WARNING。

## 5. 发现项（不阻塞 S1b）

1. **6 GHz 无可用信道**（见 §4）。
2. **MAC 重复**：`wan`、`lan2`、`lan3` 都是 `90:d3:cf:4b:eb:82`，`lan1`
   为 `:81`。6.12 树用 S19 固定 br-lan/派生 MAC 解决过同类问题；上游
   基线未处理，两 1G 口同时插线时需注意 ARP/桥表。S2 overlay 移植时一并修。
3. overlay 从 6.12 的「p27 尾部 38.8M」变为独立 p29（487M），
   `fstools_ignore_partname=1` 不在 cmdline——6.12 依赖它的脚本移植时要注意。

## 6. 未做与待批准

- 重启复验（重复启动可靠性）未做——按下一次批准再执行。
- WiFi 客户端关联/吞吐测试未做（主机无 iw/wpa_supplicant 工具）；
  目前证据为路由器侧 AP-ENABLED + 信道 + 功率。
- 6G 修复、MAC 派生、overlay 移植属 S2/S3 工作。
