# assets 目录说明

本目录是恢复模式刷机所需的全部设备侧素材，均已随仓库提交，运行时不联网下载。

## initramfs.itb（18.4 MiB）

RAM 恢复系统：官方 OpenWrt SNAPSHOT 镜像，启动后整机运行在内存中，
不写 eMMC，联网地址 `192.168.1.1`，root 空密码。

- 来源：OpenWrt 官方 snapshots（ipq95xx/generic 的 spectrum,sbe1v1k 目标镜像中的 initramfs）
- 版本：SNAPSHOT `r38189-706052b20f`，内核 `6.18.60`
- sha256：`991f093096591a57f2f367dfce38c65aa5c8fd17fe15a706a71d08ed1f03aa3d`
- 许可：GPL-2.0

官方 snapshots 不保留历史构建，这个二进制一旦消失就无法再从上游取回，
因此必须随本仓库提交保存。它只用于把设备带进可刷写状态，不参与最终固件。

## rtq7300t_boot_auto_upgrade_fw.img（903 B）

APPSBL 恢复流程第一跳加载的 FIT 启动器。原厂 APPSBL 在恢复模式下会向
TFTP 服务器请求这个固定文件名，其中的脚本负责设置服务器地址、块大小，
把 `initramfs.itb` 拉到 `0x80000000` 并 `bootm`。

- 由 `recovery-src/auto.its` + `recovery-src/boot.cmd` 用 `mkimage` 重新生成
- sha256：`af85b6a1aaa708214f8fe058f9cf1bb6f2d11003acebd8f3aab8a641dc31cc8b`

重新生成：

```sh
cd recovery-src
mkimage -f auto.its ../assets/rtq7300t_boot_auto_upgrade_fw.img
```

## 校验

`SHA256SUMS` 由本目录下的文件生成，刷机脚本启动时会核对。

```sh
cd assets && sha256sum -c SHA256SUMS
```
