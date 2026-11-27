# SBE1V1K 恢复模式刷机工具（离线傻瓜版）

给 Spectrum SBE1V1K（ipq9574 / Askey）用的恢复模式刷机工具。
按住 Reset 上电进入原厂恢复模式，工具自动把官方恢复系统（RAM 系统）送进去，
再把你选的固件写进 eMMC。

**全程离线**：只需要电脑、一根网线、一套本目录。运行时不下载任何东西，
只和直连的路由器交换 DHCP / TFTP / SSH 流量。

> 已知状态：Linux 全链路（DHCP/TFTP 送入恢复系统 → 上传校验 → `sysupgrade -F -n`
> → 新固件从 eMMC 启动）已于 2026-11-27 在 SBE1V1K 真机验收 PASS
> （固件：24.10-6.6 v142-2，CI 构建）。
> **Windows 脚本尚未做设备验收（NOT TESTED）**。
> 首次使用请预留时间，并阅读本文末尾的「失败排查」。
>
> v1.0.3 起辅助工具版本号与套件版本对齐（此前停在 1.0.1）。修复 Windows
> 侧三处问题：24.10 式 tar 固件的头部检查误报、netsh 设置地址后未等其在网卡上
> 生效就绑定（"The requested address is not valid in its context"）、TFTP 绑定
> 失败不再立即放弃而是等待地址生效（最多 30 秒）。
> v1.0.4 修复 Windows 阶段 B 两处 `check` 调用漏传 `--local`（报“必须提供
> --local”），工具版本同步为 1.0.4。
> v1.0.5 把阶段 A 的提示改为「请在15秒内执行下面的操作」（两个平台一致），
> 工具版本同步为 1.0.5。

---

## 一、准备

### 1. 网线

路由器上的 **2.5G 口（通常标 LAN1）** 用网线直连电脑的有线网卡。
刷写开始前不要插别的线到这台路由器。

### 2. 准备本目录（推荐：从 GitHub Releases 下载 zip）

本工具整个打成一个 zip 放在 GitHub Releases 里。下载解压后的目录结构：

```
sbe1v1k-flash-kit/
  flash-sbe1v1k.cmd / .ps1    Windows 入口
  flash-sbe1v1k.sh            Linux 入口
  bin/                        DHCP/TFTP/SSH 辅助工具
  assets/                     恢复系统 initramfs 与第一跳启动器
  firmware/                   ← 固件放这里（zip 里预置了这个空文件夹）
```

也可以用 git clone 整个仓库的 `openwrt-flash/` 目录，效果一样。

### 3. 放固件

把 **sysupgrade 固件（`*.bin`）** 放进 `firmware/` 文件夹：

```
sbe1v1k-flash-kit/
  firmware/
    openwrt-ipq95xx-...-squashfs-sysupgrade.bin
```

- 自己编译的（24.10-6.6 / 25.12-6.12 / 25.12-6.18）和别人编译的固件都可以，
  只要是本机的 sysupgrade `*.bin`，**文件名不限**；
- 两种镜像格式都支持，脚本自动识别：裸 FIT（文件头 `d00dfeed`，25.12-6.18 系
  常见）与 24.10 式 tar 包（以 `sysupgrade-` 开头的目录结构，FIT 在 2048 偏移处）；
- 运行时先检查这个文件夹：没有任何 `.bin` 会直接提示你去放；
- 放了多个 `.bin` 时，脚本会列出来让你选一个。

刷写固定用 `sysupgrade -F -n`：`-F` 放行板名差异（`askey` 与 `spectrum`
两种板名都接受），`-n` **不保留旧配置**——Wi-Fi、密码、插件设置全部丢失，
需要保留配置请先手工备份。

> 固件就位前不确认版本差异也没关系：脚本会先读设备当前固件版本，刷完再读一次，
> 两次相同会告警「可能没有真正写入新固件」（对应历史上的静默失败案例）。

> 刷写会使用 `sysupgrade -F -n`：**不保留旧配置**，Wi-Fi、密码、插件设置全部丢失。
> 需要保留配置请手工备份。
>
> 已知行为（2026-11-27 真机实测）：24.10 系的 overlay 位于 p27 分区尾部
> （squashfs 之后的 ext4 段），恢复系统的 `-n` 清不到它——刷完新内核与根文件系统
> 是新的，但旧 overlay 里的 `/etc/config`、`/etc/modules.conf` 等仍会继续生效。
> 要得到完全干净的状态，刷完后在设备上执行一次 `firstboot -y && reboot`
> ——2026-11-27 已在真机验证：尾部 overlay 会被正常清空，重启后内核、根文件系统
> 与配置全部来自镜像，ath12k 以镜像默认 `fse=Y` 运行。
> **注意**：`firstboot -y` 会连 dropbear 主机密钥一起清掉，执行后新的 SSH 连接
> 会在握手阶段被重置（看起来像设备失联）；此时设备本身是好的，重启一次即可，
> 若 SSH 已断可改用 LuCI/ubus 触发重启。
> 官方 SNAPSHOT 恢复系统对这类尾部 overlay 不感知，这是路径本身的限制，不是脚本错误。

---

## 二、Windows 用法

1. 确认本目录完整（含 `bin\sbe-flash-tool_windows_amd64.exe`、`assets\`）。
2. 双击 **`flash-sbe1v1k.cmd`**，出现 UAC 提示时选「是」。
3. 按提示：
   - （多网卡时）选一张有线网卡；
   - 选固件序号；
   - 按屏幕提示断电 → 按住 Reset → 上电 → 约 12 秒后松手；
   - 等待恢复系统上线、上传校验；
   - 确认刷写；
   - **刷写完把网线从 2.5G 口换到 10G 口或 1G LAN 口**（见第五节）；
   - 等待新系统上线，确认成功后脚本自动恢复你的网络设置。

没有管理员权限时脚本会自己申请提权；请勿在刷写中途关闭窗口。

Windows 下 DHCP 应答靠客户端指纹过滤（U-Boot / 带 option 43 请求的设备），
如果恢复时一直等不到地址，通常是有其他网卡（Wi-Fi、VPN 虚拟网卡）抢走了
广播，**临时禁用这些网卡**再重试即可。

---

## 三、Linux 用法

```sh
sudo ./flash-sbe1v1k.sh
```

常用参数：

```sh
sudo ./flash-sbe1v1k.sh --iface enp3s0            # 直接指定网卡
sudo ./flash-sbe1v1k.sh --second-iface enx1234    # 第二网卡接 10G 口，免换线
sudo ./flash-sbe1v1k.sh --firmware /path/x.bin    # 直接指定固件
./flash-sbe1v1k.sh --dry-run                      # 只演练，不改配置
```

脚本会自动：

- 校验 `assets/` 与 `bin/` 的 sha256；
- 列出物理有线网卡（无线网卡不会出现在列表里），只有一张在线时默认选它；
- 临时给网卡加 `172.16.252.252/16` 并启动 DHCP+TFTP；
- 恢复系统起来后换成 `192.168.1.2/24` 并加 `/32` 路由，确保多网卡时
  流量一定走这张网卡；
- 退出时（包括失败、Ctrl+C）把网卡配置恢复原样。

如果你用 NetworkManager，脚本会临时把这张网卡设为 unmanaged，结束再还回去。

---

## 四、双网卡 / 免换线（可选）

刷写完成后路由器的 2.5G 口会变成 WAN 口，原来的 `192.168.1.1` 就不在这个口上了。
如果不想换线，可以准备**第二根网线**，一头接电脑的第二张网卡，另一头接路由器的
**10G 口或 1G LAN 口**，然后：

- Windows：`.\flash-sbe1v1k.ps1 -SecondIface "以太网 2"`
- Linux：`sudo ./flash-sbe1v1k.sh --second-iface eth1`

刷写阶段仍从 2.5G 口进行，重新启动后脚本自动切到第二张网卡等待新系统。

---

## 五、刷写后必须换线（单网卡时）

| 阶段 | 网线插在 | 电脑地址 |
|---|---|---|
| 恢复/刷写 | 路由器 2.5G 口（LAN1） | 172.16.252.252 → 192.168.1.2 |
| 刷写完成重启后 | 路由器 **10G 口** 或 **1G LAN 口** | 192.168.1.2 |

新固件起来后 2.5G 口是 WAN 口，**原来插的口不再提供 `192.168.1.1`**。
脚本会在 sysupgrade 之后提示换线；不换线就一直等不到新系统（固件其实已经刷好了，
换好线后重新运行脚本并选择「已经换好线」即可完成确认，或直接浏览器访问）。

---

## 六、失败排查

| 现象 | 大概率原因 / 处理 |
|---|---|
| 一直停在「等待设备请求」 | 网线不在 2.5G LAN1 口；Reset 没按够 12 秒；其他网卡抢了广播（Windows）；重新跑一次，先断电再按步骤来 |
| 恢复系统起来后 SSH 连不上 | 电脑上 192.168.1.2 被别的网卡用了；关掉其他网卡的 192.168.1.x 配置 |
| `sha256 不一致` | 传输被干扰或磁盘读写出错，脚本会拒绝刷写；重跑即可 |
| `sysupgrade 以非零状态退出` | 固件不适合本机（板名/格式不对）；换正确的 sysupgrade 固件 |
| 刷完等不到新系统 | 还没换线（见第五节）；或固件起不来——**重新进入恢复模式重刷** |
| 刷完发现旧配置/旧文件还在 | `-n` 清不到 24.10 的尾部 overlay（见第一节末尾说明）；SSH 上去 `firstboot -y && reboot` |
| 执行 `firstboot -y` 后 SSH 握手被重置 | 正常现象：dropbear 主机密钥被清，重启后自动重新生成 |
| Windows 启动 TFTP 报 "The requested address is not valid in its context" | 旧版（≤1.0.2）在地址尚未于网卡生效时就绑定；v1.0.3 起会自动等待并重试，请使用最新 zip |
| 恢复模式进不去 | 断电，按住 Reset 再上电，保持 12 秒以上再松手 |
| Windows 提示端口被占用 | 关掉本机 DHCP 服务、VMware/VirtualBox 的桥接 DHCP 等 |

刷写中途路由器掉电：重新进恢复模式从头刷一遍即可，恢复系统本身跑在内存里，
不会污染 eMMC。

---

## 七、目录说明

```
flash-sbe1v1k.cmd / .ps1   Windows 入口（双击 .cmd）
flash-sbe1v1k.sh           Linux 入口
firmware/                  sysupgrade 固件放这里（*.bin，可多个）
bin/
  sbe-flash-tool_windows_amd64.exe   自包含辅助工具（DHCP/TFTP/SSH，静态编译）
  sbe-flash-tool_linux_amd64         同上，Linux 版
  SHA256SUMS
assets/
  initramfs.itb                     官方 RAM 恢复系统（18.4 MiB，随仓库保存）
  rtq7300t_boot_auto_upgrade_fw.img APPSBL 第一跳启动器
  SHA256SUMS
  README.md                         素材出处与重新生成方法
src/                                Go 源码（可选，改了才需要重新编译）
  build.sh                          重新生成两个二进制
recovery-src/                       启动器源码（auto.its / boot.cmd）
```

## 八、校验与出处

```sh
cd bin    && sha256sum -c SHA256SUMS
cd assets && sha256sum -c SHA256SUMS
```

- `initramfs.itb`：OpenWrt 官方 SNAPSHOT `r38189-706052b20f`（内核 6.18.60），
  GPL-2.0，sha256 `991f0930…aa3d`；官方 snapshots 不保留旧构建，故随仓库保存。
- 辅助工具为 Go 静态编译，无外部依赖；源码在 `src/`，`src/build.sh` 可复现
  （需要 Go 1.26+）。

## 九、适用范围

- 只支持 Spectrum SBE1V1K（ipq9574）。脚本会核对设备型号，不匹配直接停止。
- 需要原厂 APPSBL 的恢复流程（Reset 12 秒进入），第三方 bootloader 不适用。
- 刷写的固件必须是本机可用的 sysupgrade `*.bin`（自己编译或别人编译的都可以）；
  `-F` 用于放行板名差异，`-n` 不保留配置。
