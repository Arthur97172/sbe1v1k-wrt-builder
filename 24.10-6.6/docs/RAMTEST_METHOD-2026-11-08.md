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

## 10. 上机实测记录（2026-11-08，网络侧观测，无串口）

所有结论只来自 dnsmasq 日志里的 TFTP 文件名序列 + 主机 ping + 原厂 Web 指纹
（`Server: lighttpd/1.4.59`，308 → https），未接入串口。

标记通道：launcher 脚本在每个分支执行 `tftpboot 0x50000000 <标记>.bin`，
主机只要看到 `sent <标记>.bin to 172.16.252.15` 就知道执行到了哪一步；
标记一律加载到 0x50000000，不会覆盖 0x80000000 起的 FIT。

| 轮次 | 脚本关键动作 | 观测 | 结论 |
|---|---|---|---|
| #3–#5 | 内存节点 0 / 1.5 GiB / 2 GiB；`setenv bootargs` 覆盖 | 均到 `d04-before-bootm`，之后无 `d05`，设备回原厂 | **内存大小与 bootargs 均不是原因**（`d06-bootargs-set` 证明 setenv 生效） |
| #6 | `bootm start 0x80000000` 分步 | `d01-img-ok` 后**连 `d07` 都没有** | 该 U-Boot 不支持 `bootm start` 子命令 |
| #7 | `fdt addr 0x90600000` + `booti 0x80200000 - 0x90600000` | `d10-fdt-ok`，`d12-booti-returned` | 内嵌 DTB 能被 U-Boot 解析；`booti` 直接返回（可能是裁剪命令或拒绝执行） |
| #8 | 对照：对 `0x50000000`（垃圾数据）执行 `bootm` | `d20-garbage-ready` 后**无 `d21`**，板子 172.16.252.15 立即掉线，约 2 分钟后原厂恢复 | **`bootm` 对非法输入不会返回**——板子复位或挂死 |

**#8 的推论（重要）**：既然 `bootm` 连垃圾数据都不返回，那么 #3–#5 里
"没有 `d05` ⇒ 内核已接管" 的推断**不成立**。那些静默同样可能是 `bootm`
读镜像失败后自行复位。也就是说，到目前为止**没有任何一轮证明内核真的被执行过**。

同时说明这台原厂 U-Boot 的 `bootm` 出错路径是"整个会话结束"，不是"打印错误后
回到提示符"。因此用标记通道观察 `bootm` 之后的状态是无效的，必须先解决
"这个 U-Boot 究竟怎么引导内核"（命令集与认证策略）这一层。

`iminfo`（#2）、`booti`（#7）、`bootm start`（#6）都不可用或直接返回，
说明 U-Boot 被裁剪或定制过；`bootm` 则是致命路径。

### 10.1 新增：只读下发 + 可写回传的双 TFTP 通道

dnsmasq 2.92 的 TFTP 编译时即**只读**（`strings` 可见
"Enable integrated read-only TFTP server"），`WRQ` 一律回
`unsupported write request`。为了把 U-Boot 环境变量等文本带回来，主机侧加了
一条与下发互不干扰的回传通道：

- `dnsmasq` 继续在 `172.16.252.252:69` 负责 DHCP(option 43=askey) 与下发；
- `tftp-wr.py` 绑 `172.16.252.253:69`（同一 USB 网卡上的第二个地址），只接受 WRQ，
  文件名白名单 `^[A-Za-z0-9._-]{1,64}$`，支持 OACK 与 `blksize`；
- launcher 脚本里临时 `setenv serverip 172.16.252.253` 执行 `tftpput`，然后切回。

启动命令：

```sh
sudo ip addr add 172.16.252.253/16 dev <USB网卡>
sudo python3 -I ~/sbe1v1k-ramtest/tftp-wr.py 172.16.252.253 ~/sbe1v1k-ramtest/tftp-root
```

### 10.2 下一轮（run #9）设计

1. `env export -t 0x50000000` 把 U-Boot 环境导出到内存，再用 `tftpput` 上传
   `uboot-env.txt`（64 KiB），看能否直接读到 `bootcmd`、`bootargs`、恢复流程变量；
2. 随后下发 `initramfs.itb` 并执行 `bootipq 0x80000000`（QTI 原生引导命令，
   #8 里因对照测试中断而**从未真正执行**）。

若 `tftpput` 或 `env export` 也被裁剪，则只剩 `d30-env-returned` 标记，
下一步改为"用一段死循环的 ARM64 载荷做 bootm 可达性对照"：
`bootm` 若成功移交控制，板子将永久停住（原厂不再恢复）；若失败，则 2 分钟内回原厂。
这是在无串口条件下唯一能把"内核真的跑了"和"bootm 崩了"区分开的方法。

## 11. run #9–#12 实测（全部为网络侧观测）

| 轮次 | 脚本关键动作 | 观测 | 结论 |
|---|---|---|---|
| #9 | `env export -t` + `tftpput` 回收环境；随后 `bootipq 0x80000000` | `uboot-env.txt` 64 KiB 完整回传；无 `d23`；约 2 分钟后原厂恢复 | 回传通道可用；`bootipq` 忽略地址参数、只从闪存引导 |
| #10 | 合法 FIT（`kernel` 为 4 字节 `b .`，DTB 在 `fdt_high` 之下） | 无 `d32`，板子 09:51:18 掉线，09:52:13 原厂恢复 | `b .` 不会异常，载荷从未被执行 |
| #11 | 48 B standalone uImage（写 `SBE1V1K-PROBE!!` 到 `0x4FF00000` 后返回） | `d50`/`d52` 到达，`probe-before.bin` 回传；无 `d53` | 同样是 `bootm` 之前/之中就断了 |
| #12 | 先故意失败一次 `tftpboot`；`if`/`then`/`else`；`if bootm` | `d61`（失败后脚本继续）、`d62`（`if` 可用）；`d64` 后无 `d65`/`d66`，09:58:52 掉线，`probe-after2.bin` 未回传 | "脚本遇错中止"假设被否定；`bootm` 在 `if` 里也**不返回**，`reset_cpu()` 发生在任何移交之前 |

## 12. 安全启动假设（当前首要解释）

调用链：`do_bootm` → `boot_selected_os()`（`boot/bootm_os.c:591`，先调
`arch_preboot_os()` 再调 `boot_fn`）→ `board/qti/common/common.c:132`：

```c
if (!image_auth_check()) return;
if (board_type & KERNEL_AUTH_SUCCESS) { ... } else { reset_cpu(); }
```

- `image_auth_check()`（`board/qti/ipq9574/ipq9574.c:630`）=
  `(SECURE_BOARD) && !(ATF_ENABLED)`，只有 `SZ_128M` 例外；
- `SECURE_BOARD`=BIT(8)、`ATF_ENABLED`=BIT(9)、`KERNEL_AUTH_SUCCESS`=BIT(10)
  （`board/qti/common/ipq_board.h:974`）；
- **`KERNEL_AUTH_SUCCESS` 只在 `do_bootipq` 的认证流程里设置**
  （`cmd_bootipq.c:1111`）——也就是说：在安全板上，`bootm` 引导任何镜像
  （哪怕是原厂签名镜像）都会走 `reset_cpu()`，因为该位只由 `bootipq` 置位。

因此在没有串口的条件下，"安全启动熔丝是否已烧"是决定整条 RAM 启动路线是否
还有意义的关键未知量。网络侧无法直接看到 `printf`：`is_sec_boot_enabled` 只打印，
且恒返回 0；`secure_authenticate` 在 SCM 调用失败或结果 ≤0 时同样返回
`CMD_RET_SUCCESS`（`cmd_ipq.c:344`），不能用于分支判断。

## 13. run #13 设计：回传 RAM 找 `gd->board_type` + `go` 对照

`gd->board_type` 就在 RAM 里，`tftpput` 可以把它原样拉回来。地址推导：
`CONFIG_TEXT_BASE=0x4A240000`、`CONFIG_SYS_MALLOC_LEN=0x1F0000`、
`CONFIG_ENV_SIZE=0x10000`，`CONFIG_CUSTOM_SYS_INIT_SP_ADDR` 减去
`SYS_MALLOC_F_LEN(0x1000)` 与 `sizeof(struct global_data)`，
重定位前的 gd 落在 `0x4A03Exxx` 附近；重定位后的 gd 在 DRAM 顶端
（`ram_top - 预留`，2 GiB DDR 时约 `0xBFFxxxxx`）。两处都取。

| 动作 | 目的 |
|---|---|
| `tftpput 0x4A038000 0x8000` | 重定位前的 gd 副本 |
| `tftpput 0x4A240000 0x40000` | U-Boot 映像头部（确认基址） |
| `tftpput 0x4A500000 0x40000` | `fdtcontroladdr=0x4a504004` 所在数据区 |
| `tftpput 0xBFD00000/0xBFF00000 0x10000` | 重定位后 gd 候选区（顶端 2 MiB） |
| `go 0x80200000`（裸 `probe.bin`） | **绕过** `arch_preboot_os`，验证载荷本身能否执行并把 magic 写到 `0x4FF00000` |
| `tftpput 0x4FF00000 0x40` | 回传 magic，判定载荷是否真的跑过 |
| `if bootm <垃圾>` | 解决 #8 的矛盾：非法镜像的 `bootm` 到底返回不返回 |

判读：若 dump 里 `board_type` 的 BIT(8) 置位、BIT(9) 清零，则安全启动已烧，
`bootm` 路线作废；若 `go` 能跑通而 `bootm` 不能，则复位点被精确锁定在
`arch_preboot_os()`。

本轮 launcher FIT：1,704 B，sha256 `b59cdbda…9a9bd0`。

## 14. 对照上游指南（2026-11-08 补记）：失败的直接原因是镜像体积

上游中文指南 `hhaa12321/SBE1V1K-OpenWrt-Flash-Guide`（README.md，934 行）写死了
三条与本设备恢复模式有关的前提：

| 指南位置 | 内容 |
|---|---|
| README.md:52-55 | 恢复模式固定下载两个文件：`rtq7300t_boot_auto_upgrade_fw.img`（859 B 启动器）与 `initramfs.itb` |
| README.md:163-164 | 两个文件名必须一致；**`initramfs.itb` 必须小于 31 MiB**（原厂 U-Boot 的限制） |
| README.md:450（踩坑 ⑤） | 现象"传完不启动"→ 原因"initramfs 大于 31 MiB"→ 做法"换小于 31 MiB 的镜像" |
| README.md:451（踩坑 ⑥） | `KERNEL_LOADADDR` 只能是 `0x42200000`；`0x42080000` 非对齐、`0x41000000` 会重启 |
| README.md:868-874 | 启动器脚本原文 3 行：`setenv serverip` / `tftpboot 0x80000000 initramfs.itb` / `bootm 0x80000000` |

我们实际下发的产物与指南不一致：

| 项 | 指南 | 我们（run #3–#13） |
|---|---|---|
| 启动器 | 859 B（`guide-launcher-859B.img.bak`，脚本 82 B） | 1,704 B（`auto.its` 与指南逐字节相同，仅 `boot.cmd` 换成 913 B 标记脚本） |
| `tftp-root/initramfs.itb` | 官方镜像，< 31 MiB（附录 B 实测 19,085,504 B） | v42 FIT 92,927,628 B（官方快照另存为 `initramfs-official-snapshot-6.18.60.itb`，19,267,016 B） |

体积实测（本地 `dumpimage` + gunzip，PASS）：

| 项 | v42 FIT | 官方快照 |
|---|---|---|
| kernel gzip 数据 | 92,824,530 B | 19,225,986 B |
| **解压后 kernel Image** | **261,685,256 B（249.6 MiB）** | **49,078,280 B（46.8 MiB）** |
| 其中 initramfs 之前的内核本体 | 12,215,428 B（11.6 MiB） | 14,026,308 B（13.4 MiB） |
| 内嵌 cpio | 236.2 MiB / 4,110 项 | 31.8 MiB / 1,047 项 |
| `bootm` 解压缓冲上限 | 64 MiB（QSDK13 树，§2）或 200 MiB（QSDK14 `include/configs/ipq9574.h:125-126` 强制覆盖） | 两者均满足 |

v42 的 236.2 MiB cpio 主要来自 `usr/libexec/mihomo` 55.3 MiB、`usr/bin/sing-box` 38.7 MiB、
`usr/bin/xray` 26.3 MiB、`etc/openclash/GeoSite.dat` 9.9 MiB、`usr/bin/yq` 9.5 MiB、
`usr/bin/bandix-plus` 4.9 MiB。

结论修正：

1. run #3–#5 的"无标记 + 掉线 + 原厂恢复"已经被指南踩坑⑤直接解释：
   **解压后 249.6 MiB 超过 `CONFIG_SYS_BOOTM_LEN`**，`gunzip` 失败 → `handle_decomp_error()`
   → `BOOTM_ERR_RESET` → `do_reset()`（§2、§3 的源码路径不变，但**不再需要**§12 的安全启动假设）。
2. §12 的安全启动假设降级为 UNVERIFIED：它没有被证伪，但对 #3–#5 不再是必要解释。
3. #8、#10–#12 用的是我们自建的非指南产物（垃圾数据、4 B `b .` FIT、48 B standalone），
   这些结果**不能外推**到"官方 19 MB 镜像也起不来"。
4. 我们自己的固件里，**sysupgrade 内核不受影响**：`-fit-uImage.itb` 为 5,887,728 B，
   解压 13,434,888 B；从 `0x42000000` 起 `load_end = 0x42CD0008`，既不触任何解压上限，
   也不与 `0x44000000`（指南 `do_boot` 的载入点）重叠。不能走 RAM 启动的只有 initramfs。
5. 因此装我们固件的正确路线是指南第四章：用官方 19 MB initramfs 起内存系统 →
   `fw_printenv` 备份 → 按 4.2 三条 `fw_setenv` → `sysupgrade -F -n`（非官方镜像无 metadata，
   踩坑⑬）或手工 `dd` p25/p27。该路线**尚未执行**，设备行为 NOT TESTED。

## 15. 官方 19 MB 镜像对照轮（2026-11-08 12:34–12:36）—— PASS

这是**第一次**把官方快照放进 `tftp-root/initramfs.itb` 跑的对照实验。启动器仍未改动
（`rtq7300t_boot_auto_upgrade_fw.img`，859 B，sha256 `498bc402…`）。下发的镜像：
`tftp-root/initramfs.itb` = `official/official-initramfs.itb`，19,267,016 B，
sha256 `991f093096591a57f2c367dfce38c65aa5c8fd17fe15a706a71d08ed1f03aa3d`。

### 15.1 时间线（主机侧）

| 时刻 | 事件 |
|---|---|
| 12:34:53 | 链路掉（断电） |
| 12:35:14 | 链路起（U-Boot） |
| 12:35:18–12:35:24 | 恢复模式 DHCP（MAC `90:d3:cf:3c:34:a6`，172.16.252.15）→ TFTP 取启动器 |
| ~12:35:24–12:35:45 | TFTP 下发完整 19 MB `initramfs.itb` |
| 12:35:40 | 链路掉（`bootm` 切换） |
| 12:35:42 | 链路起（Linux） |
| 12:35:53 | 主机拿到 DHCPv4 `192.168.1.231/24`，网关 `192.168.1.1` |
| 12:35:55 | DHCPv6 `fdc4:16ed:b294::a05/128` + 委派前缀 `fdc4:16ed:b294:4::/62`（odhcpd） |

### 15.2 设备侧取证（只读 SSH，空口令登录，OpenWrt 默认策略）

```
Linux OpenWrt 6.18.60 #0 SMP Sat Nov  7 21:20:51 2026 aarch64 GNU/Linux
DISTRIB_DESCRIPTION='OpenWrt SNAPSHOT r38189-706052b20f'
DISTRIB_TARGET='qualcommbe/ipq95xx'
Machine model: Askey SBE1V1K        compatible: askey,sbe1v1k qcom,ipq9574
Memory: 1942408K/2097152K available  (纯 RAM 运行)
Kernel command line: console=ttyMSM0,115200n8
[ 2.336338] Run /init as init process … procd: - init -
```

接口命名（`/etc/board.json`）：`lan1 lan2 lan3` 属 br-lan（static），`wan` 走 dhcp。
插着的那个物理口在官方系统里是 **lan1**，1 Gbps。LED：`blue:status green:status red:status`
外加 `90000.mdio-1:1c:{green,yellow}:lan`。无 MTD 分区（存储是 eMMC `mmcblk0`，7.6 GB、
7 个分区）。

服务指纹：22 端口 `SSH-2.0-dropbear`（含 `sntrup761x25519-sha512`）、53 端口 dnsmasq、
80/443 **关闭**（该快照不含 uhttpd/LuCI）。原厂固件是 22 关、80 端口 lighttpd，二者不会混淆。

已知缺陷：该快照的 Wi-Fi 不可用——三路 ath12k 均报
`qmi dma allocation failed (29360128 B type 1)` / `WMI MAC1 connect request failed: 0x1` /
`connect to WMI CONTROL service status: -71`。有线不受影响。

### 15.3 结论

1. **恢复链路本身是好的**：原装启动器 + `tftpboot 0x80000000` + `bootm 0x80000000` 能把一个
   未由厂商签名的 19 MB FIT 完整送进 Linux 用户态。§12 的"安全启动导致 `bootm` 复位"假设
   至此**被反向证据削弱到 UNVERIFIED 以下**——不是当前故障的解释。
2. **故障边界收敛到我们自己的 FIT**：同样的启动器、同样的 TFTP、同样的 `initramfs.itb` 槽位，
   换成官方镜像就 PASS，换成 v42/slim 就 FAIL。
3. 官方 FIT 与我们的 FIT 的结构差异（供下一轮排查）：

| 项 | 官方 | 我们（slim/beacon） |
|---|---|---|
| kernel 数据 | 19,225,986 B gzip | 30,387,700 B gzip（beacon）/ 86.5 MB 未压缩 |
| 解压后 Image | 49,078,280 B（46.8 MiB） | ~84 MiB / 249.6 MiB（v42） |
| 哈希 | crc32 + sha1 | sha256 |
| DTB | 39,613 B（`askey,sbe1v1k`，38.7 KiB） | 81,209 B（`spectrum,sbe1v1k`，78.3 KiB） |
| `/chosen/bootargs` | 无 | 无 |

4. 该官方系统已随断电消失；取证快照保存在
   `/home/arthur/sbe1v1k-ramtest/official-forensics/session-12-35.txt`（604 行，含完整 dmesg）。

### 15.4 下一轮的落点

把 `initramfs.itb` 换回我们自己的镜像重跑，并且**优先解释 3 条差异**（体积 / DTB 兼容串 /
哈希校验），而不是继续在"连接方式"上找原因。设备上的 `fw_setenv`/`sysupgrade`/`dd` 仍未执行，
保持 NOT TESTED。

## 16. 自编译镜像 + 哈希/体积对照（2026-11-08 12:48–13:01）—— 全部 FAIL

启动器始终未改（859 B，sha256 `498bc402…`）。本段三轮全部回到原厂固件，
判据一律是应用层指纹：`192.168.1.1` 返回 `Server: lighttpd/1.4.59`、22 端口 closed、
MAC `90:d3:cf:3c:34:a7`（原厂 Linux 侧）。

### 16.1 run A：自编译 slim/beacon 镜像（12:48）—— FAIL

下发 `slim/beacon-initramfs.itb`（30,387,740 B，sha256 `134d6a5a…`，kernel gzip
30,305,306 B、解压 86,441,992 B/82.44 MiB，DTB 81,291 B `spectrum,sbe1v1k`）。
12:48:06 TFTP 传送完成，**约 3 秒后**（12:48:09）链路复位并落回原厂固件。
3 秒不足以进入 Linux 用户态，失败点在 `bootm` 的校验/解压/装载阶段。

### 16.2 run B：哈希对齐（12:52）—— FAIL

kernel/DTB 与 run A 完全相同，仅把哈希从 `sha256` 改为官方式的 `crc32 + sha1`
（`/tmp/repack/hash-test.itb`，30,388,048 B）。结果同样是快速复位 + 原厂固件。
**哈希算法被排除。**

### 16.3 run C：官方内容 + 82.5 MiB 解压体积（12:57–13:01）—— FAIL

用官方 kernel（Linux 6.18.60）与官方 DTB，把解压后的 Image 尾部补零到 86,500,000 B
（82.49 MiB）再 gzip -9（20,000,799 B），FIT 共 20,041,852 B，sha256 `1324db6f…`，
load/entry `0x42200000`，哈希 `crc32 + sha1`。文件本身只有 19.1 MiB，远小于 31 MiB 上限。

时间线：12:57:33 U-Boot DHCP（`:a6`）→ 12:57:37 取启动器与 `initramfs.itb` →
12:59:52 链路掉 → 13:00:17 链路起 → 13:00:25 原厂 DHCP 上线（`:a7`，`192.168.1.1`）→
13:01:16 指纹 = `Server: lighttpd/1.4.59`、22 closed。**FAIL。**

### 16.4 结论

1. **传输体积不是原因**：run C 文件 19.1 MiB，与 PASS 的官方镜像同量级。
2. **哈希算法不是原因**：run B 已对齐 crc32+sha1。
3. **内容是唯一变化、结果唯一变化**：官方 kernel/DTB + 补零到 82.5 MiB 解压体积 = FAIL，
   官方原样（46.8 MiB 解压）= PASS。故障边界落在**解压后体积 46.8–82.5 MiB 之间**，
   与引脚 U-Boot 的解压/装载上限一致（厂商 U-Boot 的 `CONFIG_SYS_BOOTM_LEN` 未知，
   我们树里的 200 MiB 定义不能作为设备证据）。**状态：UNVERIFIED（范围已知，具体阈值未定）。**

## 17. run D（下一轮）：二分解压上限

为把 46.8–82.5 MiB 的边界收敛，准备官方 kernel 补零到 **64 MiB**（67,108,864 B）后
gzip -9 的镜像：`/tmp/pad64/pad64.itb`，20,016,108 B，
sha256 `a0f4cfa2f41ab2b7e563cf8e36e5610544c4f4450207b772c34288ab7e014b31`，
已放入 `tftp-root/initramfs.itb`。启动器未改动。

判定：PASS（dropbear/dnsmasq 指纹）→ 边界 64–82.5 MiB；FAIL（原厂 lighttpd 指纹）→
边界 46.8–64 MiB。得到阈值后再决定自编译镜像要压到多少（当前 slim 解压 82.44 MiB，
且内核本体就占了大部分，可能不只要砍 initramfs）。

### 17.1 run D 结果（2026-11-08 13:04–13:06）—— **PASS**

与 §16.3 唯一的差别是补零目标从 86,500,000 B（82.49 MiB）改成 67,108,864 B（64 MiB）。
下发 `tftp-root/initramfs.itb` = `/tmp/pad64/pad64.itb`，20,016,108 B，
sha256 `a0f4cfa2f41ab2b7e563cf8e36e5610544c4f4450207b772c34288ab7e014b31`；启动器未改动。

| 时刻 | 事件 |
|---|---|
| 13:03:48 | 链路掉（断电） |
| 13:04:01 | 链路起（U-Boot） |
| 13:04:04–13:04:08 | 恢复模式 DHCP（`:a6`）→ RRQ 启动器 → RRQ `initramfs.itb` |
| ~13:04:20 | 链路切换（`bootm`） |
| 13:04:35 | `192.168.1.1` DHCP 上线 |
| 13:05:29 | 22 端口 OPEN（dropbear `SSH-2.0-dropbear`，含 `sntrup761x25519`），80 无 `Server:` 头 |
| 13:06 | SSH：`Linux OpenWrt 6.18.60`、`SNAPSHOT r38189-706052b20f`、`Askey SBE1V1K`、`Mem: 1979616 total`（纯 RAM） |

**边界收敛：64 MiB PASS < 上限 < 82.5 MiB FAIL（UNVERIFIED：未继续二分）。**
本轮与 §16.3 同内容、同哈希风格、同 DTB、同启动器，只差解压体积——解压后体积是
唯一变量，也是唯一解释。

### 17.2 对自编译镜像的意义（2026-11-08 晚订正）

- 自编译 slim/beacon 解压体积 82.44 MiB，落在失败区，与实测 FAIL 一致；
- **压缩根因已定**（§16 末尾补记）：原配置 `CONFIG_INITRAMFS_COMPRESSION_NONE=y`，
  initramfs 未压缩嵌入；裸内核 `Image` 只有 13,388,296 B（12.8 MiB），
  `Image-initramfs` 249.6 MB，其中未压缩 cpio 251,013,512 B。
- **早先"改 gzip 就够"的估计被实测推翻**。用真实 cpio 实测（同一份 251,013,512 B）：

| 压缩方式 | cpio 压缩后 | 推算 `Image-initramfs` | 结论 |
|---|---|---|---|
| gzip -9（内核 `cmd_gzip`） | 87.7 MB | ≈96.5 MiB | 落在 FAIL 区，不可用 |
| zstd -19（内核 `cmd_zstd`） | 67.4 MB | ≈77 MiB | 超 64 MiB，不可用 |
| xz，内核默认 `--lzma2=dict=1MiB` | 65.04 MB | ≈74.8 MiB | 超 64 MiB，不可用 |
| xz -9e，dict=64MiB（单线程） | 54,402,216 B | ≈64.7 MiB | 仍比 64 MiB 高 728,240 B，不够 |
| **xz -9e，dict=128MiB（单线程）** | **52,126,680 B** | **65,514,976 B = 62.5 MiB** | **落在已知 PASS 的 64 MiB 以内，采用** |

- 结论：选 **XZ + 128 MiB 字典**。必须同时改内核的压缩命令——内核
  `scripts/Makefile.lib` 的 `cmd_xzmisc` 只给 1 MiB 字典，压不到目标；
  `build/build-fixes/0019-kernel-initramfs-xz-dict.patch` 把它改成
  `-9e --check=crc32 --lzma2=dict=128MiB`。内核解码端
  `lib/xz/xz_dec_lzma2.c` 接受 dict ≤ 3 GiB，128 MiB 字典在 2 GB 内存的 RAM 启动里
  只是多一次 128 MiB vmalloc，没有压力。
- 写 xz 命令行时的一个坑：`--lzma2=dict=X,preset=9e` 里的 preset 会**覆盖** dict
  （preset 9 自带的 dict 是 64 MiB），实测 128/256 MiB 参数这样写出来仍是 64 MiB；
  正确写法是 `-9e --lzma2=dict=128MiB`（preset 先、dict 后）。
- 本轮构建改动（用户 2026-11-08 批准"改吧，改完推 CI 重编译"）只有两处：
  1. `build/config-frozen/.config`：`CONFIG_TARGET_INITRAMFS_COMPRESSION_XZ=y`
     （`NONE` 与其余算法全部 not set），`build/config-seed/…seed` 同步；
  2. `build/build-fixes/0019-kernel-initramfs-xz-dict.patch`：只改内核源码树
     里的 `scripts/Makefile.lib` 一行。
- **影响面**：`TARGET_INITRAMFS_COMPRESSION_*` 只作用于 initramfs 内核变体，
  因此只有 `*-initramfs-fit-uImage.itb` 会变；`sysupgrade.bin` 用正常内核
  （`Kernel/SetNoInitramfs` 会把所有 `INITRAMFS*` 行剥掉），不受影响。副作用仅是
  recipe_sha256 和 `buildroot/.config`、`scripts/Makefile.lib` 两条指纹，均已登记
  `build/known-delta.conf`。

## 18. run E（可选）：66 MiB 探针——已不再阻塞构建

改用 dict=128MiB 后，推算的 `Image-initramfs` 是 65,514,976 B（62.5 MiB），
**已落在已知 PASS 的 64 MiB 以内**，所以运行边界探针不再是出镜像的前置条件。
§17 里 64 MiB PASS / 82.49 MiB FAIL 之间的精确上限仍是 UNVERIFIED，只影响以后
还能把镜像放多大，不影响本轮。

探针仍留在 `tftp-root/initramfs.itb`：官方 kernel 补零到 **66 MiB**（69,206,016 B）
后 gzip -9，`/tmp/pad66/pad66.itb`，20,018,140 B，
sha256 `b2f5de99ad697ffcfb7f568f334dbac98b3b42f77a7da11a31c037ac4f563cbd`；
启动器保持原始 859 B（sha256 `498bc402…`），未改动。状态：**NOT TESTED**。

| 结果 | 判据 | 结论 |
|---|---|---|
| PASS | 22 OPEN dropbear、53 dnsmasq，SSH 报 `Linux OpenWrt 6.18.60` | 上限 > 66 MiB，余量比预想的大 |
| FAIL | 22 关、80 端口 `Server: lighttpd/1.4.59`（回原厂固件） | 上限 ≤ 66 MiB，与指南记载的 64 MiB 一致；本轮镜像不受影响 |

### 18.1 实测压缩对照（2026-11-08 晚）

同一份 251,013,512 B 的 cpio，单线程 xz：

| 参数 | 输出字节 | 说明 |
|---|---|---|
| `-9e --lzma2=dict=64MiB` | 54,402,216 | Image ≈64.7 MiB，超 64 MiB |
| `-9e --lzma2=dict=128MiB` | 52,126,680 | Image ≈62.5 MiB，采用 |
| `-9e --lzma2=dict=128MiB,preset=9e`（错误写法） | 54,402,216 | preset 覆盖 dict，等于 64MiB |
| `-9e --lzma2=dict=256MiB`（错误写法） | 54,402,216 | 同上，未生效 |

编码器峰值内存：dict=128MiB 时约 1.38 GB（CI runner 足够）。
如果以后还需要更小：dict=256MiB 按正确写法可以再试，或改走 FIT 独立 ramdisk 节点
（`CONFIG_TARGET_ROOTFS_INITRAMFS_SEPARATE`，内核节点只有 12.8 MiB，ramdisk 不经过
`bootm` 的解压上限；但要验证厂商 U-Boot 的 `boot_get_ramdisk` 路径）。
