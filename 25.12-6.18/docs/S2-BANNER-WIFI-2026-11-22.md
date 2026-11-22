# S2 第二批：banner、无线默认值、时区、射频编号与端口 MAC（2026-11-22）

用户要求把 25.12-6.12 的功能差异逐项补进 25.12-6.18。本批完成四项，另附
NSS 的可行性评估（`NSS-PORT-ASSESSMENT-2026-11-22.md`，动工按 S3a–S3e 分期）。

## 1. 本批改动

| 项 | 6.12 原状 | 6.18 落地 |
|---|---|---|
| 自定义 banner | `files/etc/banner` + `scripts/render-overlay.sh` 替换 `%V/%R` | 同源移植：`files/etc/banner`、`scripts/render-overlay.sh`、`build/sbe1v1k-build.sh` 在 `make` 前调用渲染器 |
| 无线名称/国家 | `wireless-defaults` 三件套 + `rc.d/S95` 链接 | 同源移植，板名门控加 `askey,sbe1v1k`，基址 MAC 扫描加 `lan*/wan`；`rc.d/S95wireless-defaults` 随仓库提交 |
| 时区 | `99-system-timezone`（Asia/Taipei、24 小时制） | 同源移植到 `files/etc/uci-defaults/` |
| 射频编号 | 补丁 0038 把 2G/5G/6G 固定为 radio0/1/2 | 新补丁 `0002-wifi-scripts-pin-radio-numbering-by-band.patch`（对 6.18 的 `mac80211.uc` 重生成） |
| 端口 MAC | S19sbe-lan-mac 在运行时给 eth2/eth3 钉 MAC | 上游 6.18 DTS 三口共用 `&ethaddr 1`（`mac-base` cell 即基址偏移）→ 补丁 `0003` 改为 lan2=`&ethaddr 2`、lan3=`&ethaddr 3` |

### 1.1 未随本批移植的 6.12 overlay

以下文件都依赖 6.12 的 eth0/NSS 数据通路，6.18 没有对应实体，归入 S3：

- `etc/init.d/{nss,sbe-port-roles,sbe-lan-mac,sbe-wifi-cal,sbe-eth0-an-watchdog,sbe-boot-trace}`
- `etc/uci-defaults/99-spectrum-eth0-unmanaged-lan`、`etc/config/sbe_eth0_watchdog`
- `usr/sbin/{nss-load,sbe-port-roles,sbe-eth0-an-watchdog,sbe-boot-trace}`、`etc/nss.conf`

`sbe-wifi-cal` 属厂商 BDF 打包（`sbe-wifi-firmware`），6.18 用上游
`ipq-wifi-askey_sbe1v1k` + ath12k 固件，不需要。

## 2. 静态验证

- `bash -n` / `sh -n` 全部新脚本通过。
- 补丁 `0002`/`0003` 在原始副本上 `patch -p1 --fuzz=0 --dry-run` 通过
  （`0001` 在装配树里已应用，反向检测属预期）。
- `render-overlay.sh` 单独运行输出
  `Version: 25.12-SNAPSHOT (sbe1v1k-6.18-86a810fd)`，overlay 与 rc.d 链接到位。
- 本机构建 + `verify-image.sh`：结果见 §3。

## 3. 构建与镜像校验

本机构建 `25.12-6.18/scripts/local/build-image.sh world` 退出码 0，
`verify-image.sh` **PASS=36 FAIL=0**（含新增 overlay/banner/无线/时区断言、
required 包 107 项反查）。产物：

| 镜像 | 大小 | sha256 |
|---|---|---|
| squashfs-sysupgrade | 91,597,073 B | `56822b89a4b45b5e9aa518187c2447aef5c01e88e23efd54071c6b09ca9fa8a1` |
| squashfs-factory | 85,786,624 B | `074e4a312ac19b7233a6ad0a963c185094d0899f84931daf430a72b6b4405d89` |

额外的内容级确认（从构建树取证，不依赖文件哈希）：

- `build_dir/.../image-ipq9570-sbe1v1k.dtb`（本次构建 23:13 生成）反编译后
  lan2=`<0x26 0x02>`、lan3=`<0x26 0x03>`、wan=`<0x26 0x01>`、
  lan1=`<0x26 0x00>`——端口 MAC 已两两不同；
- 构建 rootfs 的 `/lib/wifi/mac80211.uc` 含 `band_slots` 与槽位逻辑；
- 镜像 `/etc/banner` 版本行 `Version: 25.12-SNAPSHOT (sbe1v1k-6.18-86a810fd)`。

首次跑校验时 `/etc/banner` 一项 FAIL：断言拿仓库源文件（含 `%V` 占位符）
比对镜像。已改为比对 `render-overlay.sh` 渲染进装配树的版本，重跑全 PASS。

## 4. 设备验证

**NOT TESTED**。刷入 B 机需要用户单独批准；届时验证项：

1. SSH 登录横幅显示 `Version: 25.12-SNAPSHOT (sbe1v1k-6.18-…)`；
2. 首启后 `uci show wireless`：radio0=2g/radio1=5g/radio2=6g，
   country=US，SSID `WiFi_2.4G/5G/6G`，口令 `12345678`；
3. `ip -br link` 中 lan1/lan2/lan3/wan 的 MAC 两两不同；
4. `date` 显示 Asia/Taipei；`uci get system.@system[0].clock_hourcycle` = h23；
5. 6G 在 regdb 无信道时 radio2 disabled（预期，与 6.12 的 TW 现象同源）。
