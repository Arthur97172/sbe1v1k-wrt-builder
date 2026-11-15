# 25.12-6.12 v25-1（f0f9df7）在路由器 B 上起不来：静态审计结论

日期：2026-11-15
对象：`openwrt-ipq95xx-generic-spectrum_sbe1v1k-squashfs-sysupgrade.bin`
（v25-1-f0f9df7c-25.12-6.12，Linux 6.12.112）
现场症状（用户描述）：刷入后路由器 B 没有起来；风扇已不满速旋转；蓝色 LED 一直闪烁。

本文件只做**本地静态审计**：没有连接路由器、没有串口日志、没有真机测量。
所有设备侧结论都标 NOT TESTED。

---

## 1. 结论先行

1. **蓝灯闪烁在 25.12 上不能作为"系统没起来"的证据。** 25.12 的设备树里根本没有
   `blue:system` 这个 LED（24.10 是 `pwm-leds` 的 red/green/blue），25.12 只有一颗
   `gpio-leds` 的 `led-0`（GPIO 64，function wlan，trigger `phy0tx`）。蓝灯在 25.12
   是 bootloader 留下的 PWM 状态，Linux 全程不接管它，所以它会一直按 bootloader
   的节奏闪，与内核活没活无关。

2. **风扇"不满速"反而是"已经进到用户态"的强证据。** 25.12 的 `pwm-fan` 是
   **模块**（`/lib/modules/6.12.112/pwm-fan.ko` + `/etc/modules.d/60-hwmon-pwmfan`），
   只能由用户态的 `kmodloader` 加载；加载后温控把冷却档位绑到 0 档，占空比
   36/255（约 14 %），正好是"转着、但不满速"。`pwm-ipq` 驱动是内建的，但它的
   probe 只取时钟、不写 PWM 寄存器（0025 的驱动源码可查），不会自己改变占空比。
   → 结论：v25 很可能**已经挂载根文件系统、跑到了 userspace**，问题更可能出在
   **网络子系统**（没有可用的 LAN/DHCP），而不是"内核根本没起来"。

3. 和 v24（有 carrier、拿不到 DHCP）相比，**v25 只多了 0027 一个补丁**
   （CPU OPP 删表 / sleep_clk 去掉 32 kHz / NSS 32 MiB 保留区 + no-map）。
   这三项在 6.12 里都没有"让内核更早死"的机制：OPP 删表只会让 cpufreq-dt
   不注册；sleep_clk 的唯一消费者 qcom_wdt 停在 deferred probe（24.10 v55 已
   在真机验证同款处理可正常启动）；no-map 只影响内存分配器。

4. 因此，当前**最可能的叙事**是：v25 起来了，但 LAN 没有达到"插上就能 DHCP"
   的状态。需要区分三种具体原因（见 §5），其中第一种是纯配置错误、成本最低：
   **25.12 的 LAN/WAN 端口角色和 24.10 相反**——25.12 的 `02_network` 把
   `eth0`（RTL8261N 10G）划成 **WAN**，24.10 的 `01_network` 把 `eth0` 划在
   **LAN** 里。如果实测时插的是 10G 口，那"没有 DHCP / 起不来"可能根本就是
   插错了口。

   > **2026-11-15 补充（§9）**：对 24.10 工作机做过只读登录后，H1a 已被削弱——
   > 管理用的 1G 口是 `eth2`，两种版本都把它算在 LAN 里；同时发现了一个新的
   > 混淆因素 H1d（25.12 下 2.5G 口变成 LAN 桥成员、上游 DHCP 会被桥进来）。
   > 下一次 v25 测试应先按 §9.4 改网线接法。

---

## 2. 已核实的事实（可复现）

### 2.1 镜像结构（本地解包）

| 项 | v25（25.12-6.12） | v73（24.10-6.6，B 上已验证可用） |
|---|---|---|
| FIT 内核 | Linux **6.12.112**，gzip，5 765 194 B，解压约 14.6 MB | Linux 6.6.147，gzip，5 804 628 B，解压约 13.4 MB |
| FIT load/entry | **0x42200000**（0024） | 0x42000000 |
| FIT config | `default = "config@rdp433"`，`fdt-1` = `spectrum_sbe1v1k` DTB（名字是从 rdp433 继承来的，内容和板子对得上） | `default = "config-1"` |
| DTB 大小 | 45 369 B | 83 234 B |
| 根文件系统 | squashfs，含完整 `sbin/init`、`sbin/kmodloader`、`lib/preinit`、`etc/init.d/*` | 同左（另带 QSDK 用户态工具 `ssdk_sh` 等） |
| 模块 | 137 个 `.ko`（6.12.112），含 `qca-nss-dp/ppe/ssdk`、`pwm-fan`、`ath12k` | 149 个 `.ko`（6.6.147），同族 |
| sysupgrade CONTROL | `BOARD=spectrum_sbe1v1k` | 同 |

### 2.2 0027 的三处修改确实进了 v25 的 DTB

反编译 FIT 里的 `fdt-1` 逐条核对：

- `cpus` 下没有 `operating-points-v2`；
- `sleep-clk` 节点只有 `compatible = "fixed-clock"`，没有 `clock-frequency`；
- `reserved-memory` 里有 `nss@40000000 { no-map; reg = <0 0x40000000 0 0x2000000> }`；
- `mmc@7804000`（0021 打开）`status = "okay"`，带 hs200/hs400、8 bit、384 MHz；
- 0026 的 `pwm-fan`（ch3，40 µs，cooling-levels 36/72/128/255）和四档温控 trip 都在。

### 2.3 网络硬件描述与 24.10 逐节点一致

- `edma@3ab00000`：`interrupts` 48 项、`qcom,txdesc-*`/`rx-ring-queue-map` 等
  ring 映射、`qcom,vp-id`、`ppeds` 配置和 v73 **逐字相同**——24.10 v48 那次
  "edma 缺 interrupts/ring-map → nss-dp -EINVAL" 的故障模式在 v25 上**不成立**。
- `dp1..dp4`：`qcom,id`（6/5/3/4）、`qcom,mactype`、`reg` 与 v73 相同
  （`dp1` 的 `reg` 在 dtc 里显示成 `":Q@", ...` 是 dtc 把 `<0x3a514000 0x1000>`
  误判成字符串，v73 一模一样，不是损坏）；唯一差异是 v73 多了
  `local-mac-address = [00 00 00 00 00 00]`，驱动在无效 MAC 时会
  `eth_hw_addr_random()`，不致命。
- 三个关键 init 脚本 `qca-ssdk`、`qca-nss-dp`、`qca-nss-ppe-bridge-mgr`
  与 v73 **逐字相同**；`modules.d` 的加载顺序脚本也在。
- `hwmon.ko`、`pwm-ipq.ko`、`nsscc-ipq9574.ko` 在 v25 是**内建**（`modules.builtin`）。

### 2.4 端口角色：24.10 与 25.12 相反

| | LAN | WAN |
|---|---|---|
| 24.10（v73 `01_network`） | `eth2 eth3 eth0`（含 10G eth0） | `eth1` |
| 25.12（0023 `02_network`） | `eth1 eth2 eth3` | `eth0`（10G） |

24.10 的注释明确写了 `eth0 / PPE port 6 / RTL8261N 10G -> unmanaged LAN bridge`；
25.12 的 0023/0011 则按 S2 厂商 DTB 的位图（lan=0x38 ports 3/4/5, wan=0x40 port 6）
断言 10G 是 WAN。两者必有一边读错，静态无法裁决。
**这意味着：在 v25 上，10G 口是 WAN，插它拿不到 DHCP 是设计行为。**

另外，`nss-dp` 用 `alloc_etherdev_mqs()`（`eth%d`），netdev 名按注册顺序分配；
DT 节点顺序（dp1..dp4）与地址顺序（dp3→dp4→dp2→dp1）不同，实际命名只能靠真机
`ip link` 确认。24.10 的实际记忆中"2.5G 口是 eth2=LAN"提示命名**不是**简单的
dp1→eth0。

### 2.5 风扇与 LED 的判读依据

- 24.10 工作机：`pwm-leds` red/green/blue:system + `pwm-fan`，cooling-levels
  `<0 85 170 255>`。
- 25.12：**没有 system LED**；`pwm-fan` cooling-levels `<36 72 128 255>`。
- `pwm-fan` 是 kmod（用户态加载）；`pwm-ipq` 内建驱动 probe 不写 PWM 寄存器。
  → 风扇从 bootloader 的全速变成 14 %，只能由用户态加载 `pwm-fan` 后温控
  绑 0 档解释。

---

## 3. v21→v25 的时间线（便于对照症状）

| 版本 | 变更 | 现场 |
|---|---|---|
| v21 | 装载地址 0x41000000 落在 NSS 区 | 起不来，风扇满速 |
| v24 | 0024 装载地址 0x42200000 + 0025/0026 PWM 驱动/风扇/温控 | "有 carrier 但拿不到 DHCP" |
| v25 | +0027（CPU OPP / sleep_clk / NSS 保留区） | 起不来，风扇不满速，蓝灯闪 |

---

## 4. 静态审计**没有**发现的东西（重要）

- DTB 里没有畸形节点；`memory@40000000` size 为 0，由 bootloader 填，和 v73 一样。
- 内核 6.12 的 qualcommbe 配置里 `MMC_SDHCI_MSM=y`、`PINCTRL_MSM=y`、
  `QCOM_TSENS=y`、`THERMAL_OF=y`、`PWM`/`PWM_IPQ=y`、`QCOM_WDT=y`；没有明显
  缺失的启动关键驱动。
- v25 内核没有内嵌 IKCONFIG（v73 有），所以**无法**从镜像里直接取出 6.12 的
  完整 `.config` 做逐项比对——只能拿装配树的 config-6.12 片段。
- 两个版本都没有在 `/lib/firmware` 里带 QSDK NSS 固件（24.10 也没有），
  这项不能解释差异。
- FIT 的 kernel 是 gzip，bootm 解压到 0x42200000；NSS 保留区到 0x42000000，
  不重叠。

---

## 5. 假设与判别方法（按可能性排序）

### H1（最可能）系统已到用户态，但 LAN 没有按预期工作
子原因：
- **H1a 插错口**：10G 口在 25.12 是 WAN（§2.4）。成本最低的验证：换 2.5G 口
  再试 DHCP / 192.168.1.1。
- **H1b 命名/角色不符**：`02_network` 假设 eth0..eth3 的顺序，而 `nss-dp` 的
  `eth%d` 顺序依赖 probe 顺序；若与假设不符，`br-lan` 里全是不存在的接口，
  任何口都不会发 DHCP。
- **H1c ssdk/PHY 在 6.12 上没起来**：`qca-ssdk`/`nss-dp` 的代码是 QSDK 12 系，
  而 DTB 的 PHY/端口值取自 QSDK 14 的 S2 设备树（0011 的取舍）。PHY 初始化
  失败 → netdev 在、链路没有 → 与 v24 的"carrier 但无 DHCP"同族。

判别：串口日志里看 `qca-ssdk`/`nss-dp` 的 probe 行、`ip link`、`br-lan` 成员；
或者无串口时按 H1a→H1b 的顺序做端口实验。

### H2 内核在挂载根文件系统前就停了（与风扇证据矛盾，但不能完全排除）
可能是 MMC 的 6.12 初始化、某个 initcall 卡死或看门狗复位循环。
判别：串口日志开头有没有 `Booting Linux on physical CPU`、`mmc0: ...`、
`VFS: Mounted root`。

### H3 写盘/槽位问题（低概率）
如果 sysupgrade 把内核写进了 `0:HLOS_1`（p26）而 APPSBL 仍然从 p25 启动，
就会跑旧内核配新根（或反过来），表现为模块全不匹配、无网络。
判别：串口日志里的内核版本号；或在 RAM 系统里读 p25 起始扇区的 FIT 头核对。

---

## 6. 下一步需要的证据（等用户批准，未执行）

**A. 串口控制台（决定性，一次到位）**
ttyMSM0 / 115200 抓一次 v25 的完整启动日志。现有 `serial-capture.sh`，当前
没有 `/dev/ttyUSB*` 插入。日志里要确认三件事：内核版本（H3）、根文件系统挂载
（H2）、`qca-ssdk`/`nss-dp`/PHY 的 probe 结果与 `ip link`（H1）。

**B. 无串口时的端口实验（成本低）**
重新刷 v25 后依次尝试：2.5G 口 → 两个 1G 口 → 10G 口，每个口等 60 s，
记录：口灯是否亮、能否 ping 到 192.168.1.1、能否拿到 DHCP、蓝灯/风扇状态。
这一步能直接证伪/证实 H1a。

**C. 需要的话再考虑**：做一版 <32 MiB 的 25.12 initramfs 以便 RAM 启动实验
（APPSBL TFTP 上限 32 MiB，现成的 90.4 MB initramfs 拉不动），属于构建任务，
不是设备操作。

---

## 7. 停止条件

- 本报告只到"静态审计 + 判别方案"；不连接路由器、不刷机、不改固件。
- 上述任何设备侧动作都需要用户单独批准；串口只读也被视为设备操作，等批准。
- 真机行为在拿到串口/端口证据前一律记 NOT TESTED。

---

## 8. 附：本次审计附带的状态说明

- 2026-11-15 的恢复模式刷回 v73 操作已完成到 `sysupgrade -F -n -v`，
  但主机侧网卡（enx8c0e6067787f）此后一直是 DOWN/无 carrier，
  **无法从主机确认 B 是否回到 v73**，需要用户现场确认。
  → 当日晚些时候已通过 LAN 口只读登录确认：B 现跑 v78-1-627a88de，见 §9。

---

## 9. 2026-11-15 补充：真机基线（登录 v78 只读采集）

**恢复已确认成功。** 用户把 B 刷成了 v78-1-627a88de（24.10-6.6），USB 网卡接
在 LAN 口，主机 DHCP 拿到 192.168.1.244、网关 192.168.1.1；只读 SSH 登录
（root，空密码）确认：

- `DISTRIB_REVISION='sbe1v1k-g3.5c'`，内核 **6.6.147**，squashfs，启动 6 分钟；
- `opkg` 里有 `mosdns 5.3.4-r15`、`luci-app-mosdns`、`luci-i18n-mosdns-zh-cn`
  → 镜像确实包含 627a88d 的 mosdns 迁移；
- 无线 3 个 VAP（`phy00.0-0` WiFi_2.4G、`phy00.1-0` WiFi_5G、`phy00.2-0` 6G）
  都在 UP；
- `br-lan` = 192.168.1.1/24，正常发 DHCP。

### 9.1 接口 ↔ PHY ↔ 物理口（dmesg，设备实测）

```
[13.57] nss-dp 3a514000.dp1 eth0: PHY [90000.mdio-1:00] Realtek RTL8261N   (usxgmii, 10G)
[13.67] nss-dp 3a001800.dp2 eth1: PHY [90000.mdio-1:1c] Qualcomm QCA8081   (sgmii, 2.5G)
[13.89] nss-dp 3a001400.dp3 eth2: PHY [90000.mdio-1:12] Qualcomm QCA8075   (qsgmii, 1G)
[13.99] nss-dp 3a001600.dp4 eth3: PHY [90000.mdio-1:13] Qualcomm QCA8075   (qsgmii, 1G)
```

probe 顺序就是 DT 节点顺序 dp1→dp4，与 `eth0→eth3` 一一对应，**命名是确定性的**；
v25 的 DT 与 v73 逐节点一致（§2.3），因此 25.12 上编号不应改变。

当前插线状态（v78 实测）：

| 接口 | 物理口 | 载波 | 24.10 角色 | 25.12 角色（0023） |
|---|---|---|---|---|
| eth0 | RTL8261N 10G | 无 | LAN（unmanaged 桥口） | **WAN** |
| eth1 | QCA8081 2.5G | **1G 链路，DHCP 到 192.168.10.123** | **WAN** | **LAN** |
| eth2 | QCA8075 1G | 1G 链路（主机 USB 网卡） | LAN | LAN |
| eth3 | QCA8075 1G | 无 | LAN | LAN |

**补充实测（同日，网线换插 10G 口）**：主机网线移到 10G 口后，路由器侧
`eth0` 载波 UP（1 Gbps，受主机网卡限制），`dmesg` 出现
`dp1 eth0: Link is Up - 1Gbps/Full`，`eth2` 变为 NO-CARRIER；`br-lan` 仍照常
发 DHCP（主机重新拿到 192.168.1.244）。即 **24.10 的 10G 口是一个可用的 LAN
口**（`eth0-lan-attach` 的 unmanaged 桥口设计生效）。
反过来说，**25.12 把该口划成 WAN，在 10G 口上测 v25 永远拿不到
192.168.1.1**——如果之前的 v25 实测就是把管理线插在这颗 10G 口上，那么
"起不来"的表现本身就是端口角色翻转的直接结果（H1a 重新成立，且是对旧测试
最简洁的解释）。

### 9.2 对假设的影响

- **H1a（插错口）被削弱。** 管理用的口是 `eth2`（一颗 QCA8075 1G），
  24.10 和 25.12 的 LAN 列表**都包含 eth2**；只要 v25 测试时网线插的是
  同一个口，就不该因为角色翻转而拿不到地址。
- **新发现 H1d（本次接线下 25.12 的必然结果）**：当前 2.5G 口（eth1）上插着
  通往上游 192.168.10.x 的网线。25.12 把 **eth1 划进 LAN**，于是 br-lan 会把
  上游网络桥接进来，上游 DHCP 和板载 dnsmasq 会在同一个桥里打架；而 WAN 变成
  eth0（10G），目前**空着**——所以 25.12 在这种接线下"没有 WAN、LAN 地址混乱"
  是设计使然，表现就是"起不来"。这与 v24/v25 的现场症状完全吻合，值得优先排除。
- 24.10 有 `eth0-lan-attach` 把 10G 口作为 "unmanaged LAN bridge port" 挂进
  br-lan（`/etc/board.d/01_network` 注释可证，`uci` 的 ports 只有 `eth2 eth3`
  但 `brctl` 里能看到 eth0）；25.12 的 0023 没有对应的 attach 脚本，这是角色
  翻转的一部分，不是缺陷。

### 9.3 状态词

- 上表全部为 **24.10 v78 实测**（只读命令：`ip`、`brctl`、`uci show`、
  `dmesg`、`cat /sys/class/net/*/{carrier,speed}`、`opkg list-installed`、
  `iwinfo`）。没有做任何修改。
- 25.12 侧对应行为仍为 **NOT TESTED**。

### 9.4 下一次 v25 测试的建议接法

1. **拔掉 2.5G 口上的上游网线**，只保留主机接 1G LAN 口（eth2）这一根。
   这样 br-lan 里没有上游 DHCP，观察到的现象才是 v25 自己的行为。
   25.12 的角色表：`eth1`（2.5G）和 `eth2/eth3`（1G）是 LAN，`eth0`（10G）
   是 WAN。**管理线不要插 10G 口**——那是 WAN，一定拿不到 192.168.1.1。
2. 刷 v25 后等 60 s，看主机能否从 192.168.1.1 拿到 192.168.1.x、能否打开
   LuCI；同时记录 eth0..eth3 的载波灯（10G=eth0 此时是 WAN 且空着，
   不亮正常）。
3. 若 LAN 通了但没网，属预期（WAN 在 10G 口上，没插）。要验证 WAN，把上游
   线换插到 **10G 口**。
4. 若 eth2 同一根线依然拿不到地址，则 H1a 彻底排除，转向 H1b（命名/角色）
   与 H1c（ssdk/PHY 在 6.12 的 probe 结果）——这两者仍需要串口或系统内的
   `dmesg`/`logread` 才能定案。

