# v42 全尺寸 initramfs 的 RAM 启动方法（本地准备，未上机）

日期：2026-11-08
状态：本地静态验证 **PASS**；设备行为 **NOT TESTED**；未连接、未登录、未扫描路由器。

本文记录一种让原厂恢复模式启动**完整 264 MiB v42 initramfs FIT** 的本地方法。它不刷机、
不写 eMMC，断电即还原；但除结构、哈希与源码路径外，没有任何一步在真实设备上验证过。

---

## 1. 结论

把 v42 initramfs 里的内核 Image（未压缩、内含未压缩 initramfs）重新封装成一个
**compression = none、`load == 数据地址`** 的 FIT，经原厂恢复模式用 TFTP 载入
`0x80000000` 后执行 `bootm 0x80000000`，内核原地启动，从而绕开原厂 U-Boot 的
**64 MiB 解压上限**。

原方法（直接喂 v42 的 92 MB ITB）必然失败，与本 FIT 是否"太大"无关：
v42 的 kernel-1 是 gzip，解压后 271,187,976 B（258.6 MiB），原厂 `bootm` 在解压阶段
就因超过 `CONFIG_SYS_BOOTM_LEN = 0x4000000`（64 MiB）而报错。指南里"initramfs.itb
必须 < 31 MiB"的经验限制，与这个 64 MiB **解压后**上限一致（官方 19 MB 的镜像解压约
46.8 MiB，仍在上限内）。

> 一句话：**限制在解压路径上，不在文件大小上。** 新方法根本不走解压。

## 2. 原厂 U-Boot 的行为证据

QSDK13 树 `qca/src/u-boot`（U-Boot 2023.04，最接近原厂固件的可得源码）：

| 配置 | 值 | 影响 |
|---|---|---|
| `CONFIG_SYS_BOOTM_LEN` | `0x4000000` (64 MiB) | gzip 内核解压的目标缓冲区上限 |
| `# CONFIG_CMD_BOOTI` | 未启用 | 无法用 `booti` 绕开 `bootm` |
| `CONFIG_SYS_LOAD_ADDR` | `0x50000000` | 与本方法无关（tftpboot 显式给地址） |
| `CONFIG_TFTP_BLOCKSIZE` | `1280` | 默认块大小；`tftpblocksize` 环境变量可覆盖 |
| `CONFIG_TFTP_WINDOWSIZE` | 未设置（默认 1） | 默认 stop-and-wait |
| `CONFIG_NET_TFTP_VARS` | Kconfig 默认 **y** | `tftpblocksize`/`tftpwindowsize` 环境变量生效 |

解压路径：`bootm_load_os()` → `image_decomp(IH_COMP_GZIP, …, CONFIG_SYS_BOOTM_LEN, …)`
→ `gunzip(load_buf, unc_len = 64 MiB, …)` → 271 MB 放不下 → `ENOSPC`
（串口会打印 "Image too large: increase CONFIG_SYS_BOOTM_LEN"）。

## 3. 绕过原理（逐条源码路径）

1. `boot_get_kernel()` 对 FIT 内核传入 `FIT_LOAD_IGNORED`（`boot/bootm.c:951`）。
   在 `fit_image_load()` 里，`load_op == FIT_LOAD_IGNORED` 时 `load = data`，
   **不搬移、不解压**（`boot/image-fit.c:2228-2231`）。
2. `bootm_find_os()` 从 FIT 属性里另取 `images.os.load`（`boot/bootm.c:174-179`）
   和 `entry`（`:216-217`）。我们的内核类型是 `kernel`（`IH_TYPE_KERNEL`），
   不进入 `IH_TYPE_KERNEL_NOLOAD` 的 `booti_setup()` 分支（`:228-246`，该分支只在
   `CONFIG_CMD_BOOTI` 下生效）。
3. `bootm_load_os()` 调 `image_decomp(os.comp = IH_COMP_NONE, load, image_start, …,
   CONFIG_SYS_BOOTM_LEN, …)`（`boot/bootm.c:416-418`）。`image_decomp()` 的
   `IH_COMP_NONE` 分支是：

   ```c
   case IH_COMP_NONE:
       ret = 0;
       if (load == image_start)
           break;                 /* 不拷贝、不做 unc_len 检查 */
       ...
   ```

   随后 `*load_end = load + image_len`。**这就是 64 MiB 检查被跳过的位置。**
4. 同一个 `load` 落在 FIT 自身 blob 内，本来会触发 "new format image overwritten"。
   `bootm_load_os()` 的 `no_overlap = (os.comp == IH_COMP_NONE && load == image_start)`
   （`boot/bootm.c:433`）为真，恰好跳过这项检查（`:435-452`）。
5. 内核数据在 FIT 内的定位公式（`fit_image_get_data_and_size`）：

   ```
   data = fit + ((fdt_totalsize + 3) & ~3) + data-offset
   ```

   `mkimage -E -B 0x200000` 把 FIT 结构固定为 0x200000 字节、内核 `data-offset = 0`，
   所以 FIT 载入 `0x80000000` 时内核数据正好在 `0x80200000`，与 `load` 相等。
6. ARM64 `Image` 头校验（从产物里读回）：`text_offset = 0x0`、
   `image_size = 0x10320000`、`flags = 0xa`（bit3 可重定位置位）、
   magic `0x644d5241`。`0x80200000` 是 2 MiB 对齐地址，满足 `text_offset = 0` 的要求。
7. FDT 单独设 `load = 0x94000000`，U-Boot 在 boot 前把 81,209 B 拷过去。
   `/memory` 不写死：原厂固件的 DTB（`sysupgrade` 内 kernel FIT 解出）同样是
   `/memory@40000000 reg = <0 0x40000000 0 0>`（size 为 0）且 `/chosen` 无 bootargs，
   证明原厂 U-Boot 靠 `CONFIG_ARCH_FIXUP_FDT_MEMORY`（`boot/Kconfig:743`，默认 **y**）
   填充内存大小；我们的 DTB 与之同构，路径成立。
8. v42 内核的 initramfs 是**未压缩** newc cpio：审计配置为
   `CONFIG_INITRAMFS_COMPRESSION_NONE=y`、`CONFIG_RD_*` 全关。从 Image 里实测：
   4,425 个条目、244,564,452 B，偏移 `0x184525C..0x10181440`。原地启动不需要外部
   initrd，也不需要内核支持任何 initrd 解压格式。

## 4. 产物

| 路径 | 大小 | SHA-256 |
|---|---|---|
| `~/sbe1v1k-ramtest/tftp-root/initramfs.itb` | 276,824,064 B (0x10800000 = 264.0 MiB) | `8999f2b94fa3348d1910d067dad1ddf5e353828f6b6e4b7fe2e10092c9fb3abf` |
| `~/sbe1v1k-ramtest/tftp-root/rtq7300t_boot_auto_upgrade_fw.img` | 883 B | `5f0e5f3c7d9e5c751667d88c648a954fe019d484111858010fe267107db63c11` |
| `~/sbe1v1k-ramtest/tftp-root/initramfs-official-snapshot-6.18.60.itb` | 19,267,016 B（官方快照，保留作对照/回退） | `991f093096591a57f2c367dfce38c65aa5c8fd17fe15a706a71d08ed1f03aa3d` |

主 FIT 内部（`dumpimage -l` 与 `fdtget` 读回）：

| 镜像 | 类型 | 压缩 | data-offset | data-size | load / entry | 声明 SHA-256 |
|---|---|---|---|---|---|---|
| kernel-1 | kernel, arm64 | none | 0x0 | 0x102A0008 (271,187,976 B) | 0x80200000 / 0x80200000 | `8286b09b…8472e5` |
| fdt-1 | flat_dt, arm64 | none | 0x10400000 | 0x13D39 (81,209 B) | 0x94000000 / — | `155534eb…ced064` |

启动器脚本（`launcher/boot.cmd`，类型 `script`，108 B）：

```
setenv serverip 172.16.252.252
setenv tftpblocksize 1468
tftpboot 0x80000000 initramfs.itb
bootm 0x80000000
```

`RTQ7300T` 型号标记原样保留；脚本与 its 里不含 `saveenv`、`mmc write`、`nand`、
`flash` 等任何写存储命令。

## 5. 本地校验结果（全部 PASS）

- FIT 结构：`fdt_totalsize = 0x200000`；文件 `0x10800000` 字节。
- 字节偏移：内核数据在文件 `0x200000`，FDT 数据在 `0x10600000`，与公式一致；
  `cmp` 抽样通过。
- 全文哈希：从文件里截取 `0x200000` 起的 271,187,976 B 与 FDT 的 81,209 B，
  SHA-256 分别等于 FIT 内声明的 `8286b09b…`、`155534eb…`。
- 载入 `0x80000000` 后的 RAM 占用：
  - 内核代码/数据 `0x80200000..0x904A0008`
  - Image 头声明的 BSS 余量 `0x904A0008..0x90520000`（落在 FIT 补零区）
  - FDT 源数据 `0x90600000..0x90613D39`（随后拷到 `0x94000000`）
  - FIT 末尾 `0x90800000`
  - 设备 2 GB RAM（`0x40000000..0xBFFFFFFF`），全部在界内，且与 FDT 拷贝目标不重叠。

## 6. TFTP 传输可行性

- 服务端 dnsmasq 2.92：支持 `blksize`/`timeout`/`windowsize`，并且显式处理 16 位
  block 回绕（`src/tftp.c` 的 `block_hi` 逻辑）；U-Boot 2023.04 客户端同样有回绕支持
  （`net/tftp.c` 的 `update_block_number()`，`tftp_block_wrap_offset`）。
- 264.0 MiB 在 1468 B 块下约 188,573 块，跨越 65,535 的回绕周期两次（每 65,536 块一次）；
  若回落 1280 B 则约 216,269 块。
- 默认 stop-and-wait，直连链路上估计数十秒到数分钟（**未实测**）。若太慢，可再试
  `setenv tftpwindowsize 8`：两端代码都支持，但本设备未验证，属可选实验项。

## 7. 上机步骤（待批准；当前未执行）

严格沿用指南的原厂恢复流程：

1. 主机插入 USB 网卡，运行 `sudo ./start-dhcp-tftp.sh <网卡名>`（配置 172.16.252.252/16，
   dnsmasq 提供 DHCP option 43 = `askey` + TFTP 根目录）。
2. 路由器断电，按住 Reset 上电，约 12 秒后松手。
3. 观察两次 TFTP：先 `rtq7300t_boot_auto_upgrade_fw.img`（883 B），再
   `initramfs.itb`（264 MiB）；后者出现 `sent initramfs.itb` 即传输成功。
4. launcher 脚本执行 `tftpboot` + `bootm`；串口 115200 可看 U-Boot 与内核日志。
5. **登录注意**：v42 默认拓扑把 2.5G 口（eth1/dp2，即恢复模式用的 LAN1）分给 WAN，
   `eth2/eth3`（1G 口）才是 LAN（192.168.1.1/24）。WAN 区默认拒绝输入，所以 RAM 系统
   起来后要**把网线换到 1G LAN 口**再 `ssh root@192.168.1.1`（initramfs 默认空密码，
   未实测），或直接走串口。不能指望在 2.5G 口上直接 SSH 192.168.1.1。
6. 全程只写 RAM；断电即回到原厂固件。

## 8. 风险与未验证项

- 设备行为一律 **NOT TESTED**；本文只证明"在 QSDK13 U-Boot 2023.04 源码里这条路径成立"。
- 原厂 U-Boot 的具体构建与配置是**推断**（`ipq9574_mmc_defconfig` 是最强证据）。若实际
  固件的 U-Boot 不支持 FIT 外部数据（`-E`/`data-offset`），`bootm` 会报错，最坏情况是
  断电重来，不写 eMMC。
- 264 MiB 的实际传输时延、回绕与丢包表现未在设备上验证。
- 端口映射、串口输出、内存填充、bootargs 均未实测。
- 不连接、不登录、不扫描；任何上机、修改、安装、重启或刷写都须另行批准。

## 9. 复现命令

```sh
cd ~/sbe1v1k-ramtest/repack
mkimage -f ramtest.its -E -B 0x200000 initramfs.itb
# 启动器
cd ~/sbe1v1k-ramtest/launcher
mkimage -f auto.its ~/sbe1v1k-ramtest/tftp-root/rtq7300t_boot_auto_upgrade_fw.img
```

`ramtest.its` 的 kernel-1 为 `compression = "none"`、`load = entry = <0x80200000>`；
fdt-1 为 `load = <0x94000000>`。
