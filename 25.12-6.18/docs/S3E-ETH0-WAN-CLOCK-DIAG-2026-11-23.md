# S3e 诊断：NSS 变体 10G/WAN 双端口零帧——NSS MAC 时钟树缺 PCS 父时钟

日期 2026-11-23；设备为 NSS 变体（`askey,sbe1v1k-nss`，6.18.64）；
取证只读，未改设备、未重启、未动代码。10G 口与 USB 管理口同口取数（用户已换回 10G 口）。

## 1. 结论

1. **不是 6.12 文档里 netifd teardown / RTL8261N 假环回那个问题。** 6.18 的
   `99-spectrum-eth0-unmanaged-lan` + `eth0-lan-attach` 机制已移植且工作正常
   （见 §3），本次插线后链路干净地 up → 桥转发，无任何 teardown。
2. **根因：板级 DTS 把 `pcs0`/`pcs2` 留在 `status = "disabled"`**，mainline
   PCS 时钟提供者不注册；nsscc 的 port5/port6 时钟源表需要这些父时钟
   （DTS 索引 4..9 的 uniphyN rx/tx），`__clk_rcg2_select_conf()` 选不出配置，
   ssdk 的 `clk_set_rate` 永远失败 → port5/port6 的 TX/RX 分频器停在 512 上限
   → 时钟卡在 24 MHz / 512 = **46,875 Hz** → 2.5G/10G USXGMII 的 MAC 无法收帧。
   qsgmii 1G 口（port1–4）时钟直通 24 MHz 不受影响，所以只有 10G 口（eth0）
   和 2.5G WAN（eth1）坏。
3. 这与 6.12 在 2026-11-18 修的**同一条故障**（`25.12-6.12/patches/0037-*.patch`），
   6.18 树漏移植了该修复。

## 2. 排除项：netifd 假环回触发条件不成立

- netifd 的 br-lan 成员只有 `eth2 eth3`；eth0 由 out-of-band 的
  `eth0-lan-attach` 挂桥，netifd 不拥有 eth0。
- 本次插线后 dmesg：`[1725.03] nss-dp 3a514000.dp1 eth0: Link is Up -
  2.5Gbps/Full`，桥端口 2 blocking→forwarding（state=3），`eth0 master br-lan`，
  `LOWER_UP`。无 teardown、无 flap、无 netifd 地址变更事件。
- 6.12 文档描述的假环回是 netifd 主动 tear down 触发；这里 netifd 从未碰过 eth0。

## 3. 关键证据

### 3.1 数据面（链路 "up" 但双向零帧）

| 项 | 取值 | 说明 |
|---|---|---|
| eth0 rx_packets | **0** | 主机每秒 ARP，路由器一帧没收到 |
| eth0 tx_packets | 51 | 只是驱动入队计数，主机侧抓不到任何帧 |
| eth0 carrier / speed | 1 / 2500 | phylink 层认为链路正常 |
| eth1（WAN，QCA8081 2.5G）rx/tx | 0 / 0 | `wan` 接口 `pending=true`，DHCP 无租约 |
| 主机侧（绑定 USB 网卡 ping/ARP） | 100% 丢 | 服务器只看到自己的 ARP 请求 |

### 3.2 时钟树（决定性证据）

同一颗芯片上随端口速率不同的分频链：

| 时钟 | parent | 速率 | 端口状态 |
|---|---|---|---|
| `nss_cc_port1_tx_clk_src` | xo-board-clk | 24,000,000 | 1G 口正常 |
| `nss_cc_port3_tx_clk_src` | xo-board-clk | 24,000,000 | 1G 口正常 |
| `nss_cc_port5_tx_clk_src`（div） | xo-board-clk | **46,875** | WAN 2.5G，零帧 |
| `nss_cc_port5_rx_clk_src`（div） | xo-board-clk | **46,875** | 同上 |
| `nss_cc_port6_tx_clk_src`（div） | xo-board-clk | **46,875** | 10G 口，零帧 |
| `nss_cc_port6_rx_clk_src`（div） | xo-board-clk | **46,875** | 同上 |

46,875 = 24 MHz / 512（`nss_cc_port5_tx_div_clk_src` 位宽 9，512 是上限）。
dmesg 每 ~0.37 s 刷一条：

```
nss_cc_port5_tx_clk_src: can't find a configuration for rate 150937500000
（= 312.5 MHz × 483，divider 候选搜索的中间值；div_clk_ops 的 bestdiv 循环）
```

调用链（qca-ssdk 内置源码）：`qca_hppe_mac_sw_sync_task`（1 s 周期 delayed
work）→ `ssdk_port_speed_clock_set` → `ssdk_uniphy_clock_rate_set` →
`clk_set_rate` → `clk_rcg2_fm_determine_rate` → `__clk_rcg2_select_conf` 失败。

### 3.3 根因定位：PCS 提供者未注册

- 设备 `/proc/device-tree/soc@0/ethernet-pcs@7a00000`、`ethernet-pcs@7a20000`
  均 `status = "disabled"`；DTS 源码同样（6.18 dtsi 为 upstream 默认 disabled）。
- `/sys/bus/platform/drivers/ipq9574_pcs/` 只有 `module` 符号链接，
  **零个绑定设备** → `ipq_pcs_clk_register()` 从未运行 → nsscc 的
  `clk_hw_get_parent_by_index()` 对 UNIPHY 父项返回 NULL。
- 内核配置 `CONFIG_PCS_QCOM_IPQ9574=m`（.config 与真机 lsmod 一致），驱动存在，
  只是没节点可绑。
- 全 DTS 无 `pcs-handle` 挂接，所以启用节点只会注册时钟提供者，不会把 PCS ops
  接到任何 dp 端口（与 6.12 0037 的前提一致）。

## 4. 与 6.12 修复（0037）的对应

`25.12-6.12/patches/0037-qualcommbe-sbe1v1k-enable-pcs-clocks.patch` 记录的
故障签名与本例逐字相同（同一条 WARN 每 0.37 s、WAN eth1 载波在但 RX=0、
DHCP 无人应答），结论与修法：

- 根因：nsscc port5/6 时钟表的 UNIPHY 父时钟由 mainline PCS 驱动注册，
  板级 DTS disabled + 内核配置未开 → 父项永不为 NULL 解析；
- 修法：`&pcs0/&pcs1/&pcs2 { status = "okay"; }` + `CONFIG_PCS_QCOM_IPQ9574=y`；
- 注意：**XPCS resets 不能删**（6.12 2026-11-18 试验：删了镜像能进用户态但
  10G 口永不起来；qca-ssdk 不能成为 XPCS resets 的唯一持有者）。

6.12 上该修复真机 PASS（WAN 2.5G 与 10G 口均可用，v68-1 及后续镜像）。
6.18 的配置已是 `=m`，缺的只是 DTS 三个节点的 enable。

## 5. 修复方案（用户 2026-11-23 已批准，按 0036 实施）

1. 新增 6.18 补丁（如 `0036`，或并入 0031 的 NSS DTS）：在
   `ipq9570-sbe1v1k.dts` 里把 `&pcs0/&pcs1/&pcs2` 置 `okay`，保留 resets。
2. 内核配置把 `CONFIG_PCS_QCOM_IPQ9574` 从 `=m` 提为 `=y`（与 6.12 一致，
   免去模块装载顺序问题；模块当前是被人为装载的，auto-load 在 OpenWrt 上不可依赖）。
3. 本地构建 + `verify-image.sh` 后刷机复验。判据：
   - dmesg 不再出现 `can't find a configuration for rate`；
   - debugfs 中 port5/6 tx/rx 时钟离开 46,875 Hz，随速率到 125M/312.5M 档；
   - `eth1` DHCP 拿到租约，`eth0` rx_packets 递增。
4. 顺带核对 6.18 pcs 节点形状：6.18 dtsi 里 `pcs1` 是 `ethernet-uniphy@7a10000`
   形态（6.12 为 pcs 同位不同写法），启动后确认它注册的时钟名
   （`%s::rx_clk`/`%s::tx_clk`）与 nsscc 的 `uniphyN rx/tx` 父项对得上。

### 风险与回退

- PCS 驱动与 qca-ssdk 的 `ess-uniphy` 裸 ioremap 共存：6.12 已实测无冲突
  （PCS probe 不写 UNIPHY 寄存器，ops 无消费者）。
- XPCS reset 共享/独占 WARN（`-EBUSY`，无害噪声）：保留 resets，别删。
- 若启用后 10G 仍不通，回退路径是去掉 DTS 三行本补丁重建，回到当前状态
  （WAN 也仍不通——当前状态本身已是坏的，无退化风险）。

## 6. 真机复验（2026-11-23，补丁 0036 已刷）

镜像：NSS 变体，sha256 `2e452ced…4d69`（含 0036、0037），`sysupgrade -n` 刷入。

### 6.1 0036（PCS 时钟）——修复按设计生效

| 项 | 刷前 | 刷后 |
|---|---|---|
| `ipq9574_pcs` 驱动绑定 | 0 个设备 | `7a00000.ethernet-pcs`、`7a10000.ethernet-uniphy`、`7a20000.ethernet-pcs` |
| dmesg `can't find a configuration` | 每 ~0.37 s 一条（取样时 24 条） | **0** |
| `nss_cc_port5_tx/rx_clk_src` | 46,875 Hz | **125 MHz**（2.5G 档正确） |
| `nss_cc_port6_tx/rx_clk_src` | 46,875 Hz | **31.25 MHz**（对端 2.5G 档正确） |

### 6.2 新的阻塞项：eth0 USXGMII AN 死锁（6.18 上必现，累计 6/6）

时钟与 WARN 都好了，但 eth0 仍零帧，且证据指向 6.12 文档
（`25.12-6.12/docs/ETH0_XPCS_AN_BOOT_2026-11-22.md`）记录的**另一个**缺陷：

- `VR_MII_AN_INTR_STS`（uniphy2 0x1f8002）= **0x0**，dmesg 有
  `uniphy autoneg time out!` 与 `RTL8261BE …: SerDes link did not come up`；
- 其余寄存器与 6.12 坏启动签名**逐位相同**（0x1f0000=0x1120、
  0x1f8001=0x101、0x1f8000=0x2000）；
- 连续 5 次启动（1 次刷机后 + 4 次 reboot）全部死锁，外加 1 次冷上电
  （见 §6.3）。6.12 上该缺陷
  采样为 50%（13/26），重启约一半能好；6.18 目前 0/5，**疑似 6.18
  上该竞态变成确定性失败**（可能是 XPCS AN 使能、ssdk 初始化与
  RTL8261N 固件加载时序与 6.12 不同）；
- 主机侧 RTL8156B 复位重协商无效（与 6.12 实验矩阵一致）；
- uniphy1（eth1，QCA8081 2.5G）载波 2.5G 但 rx=0，对端不明；
  WAN 数据面验证需先把上游线接到 WAN 口（已接线，结果见 §6.5：FAIL）。

### 6.3 冷上电对照：确定性失败坐实（用户批准，2026-11-23 13:24）

断电冷启动后 AN 仍为 0x0、eth0 零帧，累计 **6/6 全坏**（5 热重启 + 1 冷上电）。
冷启动时间线（dmesg）：

```
16.0 s  qca-ssdk init succeeded        (AN 使能发生在这一阶段)
16.5 s  dp1 绑定 RTL8261BE PHY          (config_init：MMD30 复位+固件补丁)
22.3 s  eth0 Link is Up - 2.5Gbps/Full  (铜缆侧/phylink 报链路)
22.6 s  uniphy autoneg time out!        (ssdk 只等 100 ms 判 AN 未完成)
24.6 s  RTL8261BE: SerDes link did not come up
```

对照 6.12：好启动 AN 在 ~27 s 完成、link-up 边沿 ~28.5 s（先完成、后边沿）；
6.18 的 link-up 边沿提前了约 6 s，AN 从未完成即被判超时，随后
`qca_hppe_mac_sw_sync_task` 照常打开 txmac/rxmac 把死链路封存（6.12 文档
已定位的机制）。**方向假设：ssdk AN 使能（16 s）与 PHY 固件加载/复位
（16.5 s）的先后顺序在 6.18 上令 AN 握手必然失败**（6.12 上这一竞态约
50% 失败）。

修复候选（均需立项评估，未实施）：

1. 厂商代码补丁：AN 超时时不封存端口，循环重启 AN（重写 SR_MII_CTRL
   bit9 或 ssdk 内部带时钟序列的 AN 重初始化）并限时重试，成功后再打通
   MAC——6.12 的失败后单次手写寄存器重试无效，但"开机路径内、封存前
   重试"未测过；
2. 调整时序：把 ssdk 的 AN 使能挪到 PHY 就绪之后（需要 qca-ssdk 代码
   或装载顺序改动）；
3. S95 看门狗移植价值下降：6/6 必现时重启自愈不成立，只能兜底。

### 6.4 打包缺陷 0037（顺带发现并修复）

NSS 镜像的 `SUPPORTED_DEVICES` 缺省取设备名 `askey,sbe1v1k-nss`，而板上
compatible/board_name 是 `askey,sbe1v1k`（两变体共用），导致裸
`sysupgrade -n` 被拒（"Device askey,sbe1v1k not supported by this image"），
只能 `-F`。补丁 0037 显式声明 `SUPPORTED_DEVICES := askey,sbe1v1k`，
新镜像内嵌元数据已验证为 `["askey,sbe1v1k"]`，真机裸 `-n` 刷入 PASS。

注意：24.10/6.12 两棵自建树的 compatible 是 `spectrum,sbe1v1k`，与 6.18
不同；跨树互刷（6.12 设备→6.18 镜像）仍需 `-F`。是否在 6.18 镜像里
同时声明两个名字待定。

### 6.5 WAN 数据面复测：链路成立，但 PPE 出口按 dropcode 119 全丢（2026-11-23）

用户换线后（上游网关 → 2.5G WAN 口 eth1；本机 USB 网卡 → 10G 口），
对 eth1（port5，QCA8081）做只读取证。**结论先行：链路层完全正常，
但路由器发出的每一帧都在 PPE 出口被丢弃，DHCP 拿不到租约，NAT 无从验证。**

1. 链路层正常：`ssdk_sh port linkstatus get 5` → 2500 / Full /
   SGMII PLUS / ENABLE；netdev `carrier=1 operstate=up`。
2. 双向零帧：eth1 `rx_packets=0 tx_packets=0`，errors/dropped 全 0；
   udhcpc 在跑、`network.interface.wan` 一直 `pending`；主机侧在上游
   LAN 抓包，看不到 WAN MAC `26:33:da:2b:ae:8e` 的任何帧。
3. PPE 计数（`/sys/ssdk/packet_counter`，两次取样间隔数分钟）：

   | 计数器 | 取样 | 说明 |
   |---|---|---|
   | `PORT_TX_COUNTER` port5 | 439 → 465 | 持续增长：DISCOVER 确实走到了 PPE 出口队列（`QUEUE_TX_COUNTER` queue=0208 同步） |
   | `VP_TX_DROP` dropcode 119 | 613 → 647 | **"TX MAC disable drop"**，与 port5 增速同量级 |
   | `PORT_RX_COUNTER` | 1309（port 0=CPU） | 管理面流量正常，PPE 计数本身工作 |

4. 逐层寄存器读（`ssdk_sh debug reg get`）——所有可点名的"TX MAC 使能"
   门**都是开**：
   - XGMAC `MAC_TX_CONFIGURATION` @0x510000 = 0x40010001，TE=1；
   - `appe_port_mux_ctrl` @0x10 = 0x3010，port5 mac_sel 指向 XGMAC
     （与 GMAC `MAC_ENABLE` @0x1800=0x10、TXMAC_EN=0 吻合：mux 已切走）；
   - `PORT_BRIDGE_CTRL` port5 @0x60314 = 0x30139，txmac_en(bit16)=1；
     port6 @0x60318 = 0x31939 亦为 1；port3/4 bit16=0（与其 PHY 未连一致）。
5. QCA8081 计数（`ssdk_sh debug phycounter show 5`）：铜缆侧 RxGoodFrame
   两次读数 **4 → 1**，说明该组计数是读后清零（单次 0 不能当"收不到"的
   死证；上游广播确实到了 PHY）；而 `SysRxGoodFrame`/`SysTxGoodFrame`
   两次都是 0 —— **PHY 系统侧（SGMII）双向都不见帧**。
6. 时钟链：0036 后 port5 tx/rx 为 125 MHz，但切 SGMII PLUS 时 dmesg 仍有
   `ssdk_uniphy_port5_clock_source_set[2110]:ERROR:set parent fail!` ×2
   （20.2 s，每次 link-up 都出现）。

判定与排序：

- 不是"链路没起来"，也不是"上游不理 DHCP"，而是**帧在 PPE 出口被硬件按
  "TX MAC 未使能"丢弃**，且丢弃判定所依据的状态与所有可读使能位矛盾；
  同时 PHY 系统侧双向零帧。两条证据指向 PPE 出口准入判定依赖的
  "MAC/端口就绪"状态没有真正建立（而不是我们漏开某个位）。
- 6.12 同 DTS 值、几乎同源码（`adpt_hppe_portctrl.c` 两树逐字相同；
  ssdk 差异仅 `ssdk_init.c` 的 phylink PCS API 适配、`sfp_phy.c`、
  `ssdk_plat.c` 属性类型）**WAN PASS** → 环境差异（6.18 phylink/PCS
  适配层）是首要嫌疑，其次是 uniphy1 SGMII+ 系统侧（`set parent fail`
  家族）。
- 与 §6.2 的 eth0 AN 死锁可能同源（都表现为"链路 up、MAC 层不出帧"），
  也可能独立；现有证据不足以二选一。
- 无关/噪声（6.12 好启动同样存在，不动）：`reset(N) not exist!`、
  XPCS 共享 reset 的 -EBUSY WARN；resets 不能删。
- 顺带发现：本镜像 `PPE port 3/4 failed to connect PHY, ret -19`
  （qca8075，eth2/eth3），MAC 未使能 —— **LAN 有线口在本镜像上也不通**，
  需在根因项目里一并核对（6.12 NSS 变体是否有同样 -19 待查）。

### 6.6 下一步（待批准）

- eth0 AN：6/6 确定性失败已坐实（含冷上电），根因（ssdk AN 超时即封存 +
  6.18 时序竞态）单独立项修复；单独移植 S95 看门狗在必现场景下只会
  空转到放弃，先不动。
- WAN：数据面复测结果为 **FAIL**（§6.5）——eth1 链路成立但出口全丢，
  DHCP/NAT 无法验证；与 eth0 AN 死锁候选同一根因项目。
- LAN 有线口（port3/4 PHY connect -19）：并入同一根因项目核对。
- 跨树互刷：用户 2026-11-23 已批准，0037 重写为两个设备变体都声明
  `SUPPORTED_DEVICES := askey,sbe1v1k spectrum,sbe1v1k`（见 §7）。
- 以上三条已**立项**：`docs/WIRED-DATAPATH-PROJECT-2026-11-23.md`
  （统一根因假设 H1 = 6.18 缺 6.12 的 MDIO phy-reset 脉冲；第一号实验
  E1 = 补丁 0038）。

## 7. 状态

- 取证完成；`patches/0036-qualcommbe-sbe1v1k-enable-pcs-clocks.patch`
  （NSS DTS 三个 PCS 节点 `okay` + `CONFIG_PCS_QCOM_IPQ9574=y`）与
  `patches/0037-qualcommbe-sbe1v1k-nss-supported-devices.patch`
  （`SUPPORTED_DEVICES := askey,sbe1v1k`；2026-11-23 已重写为
  `0037-qualcommbe-sbe1v1k-supported-devices.patch`，两个变体各自声明
  `askey,sbe1v1k spectrum,sbe1v1k`，免 -F 跨树，设备 NOT TESTED）
  均已构建并**真机验证 PASS**：
  时钟 46,875 Hz → 125 MHz / 31.25 MHz、`can't find a configuration` 归零、
  PCS 驱动绑定 3 个设备、裸 `sysupgrade -n` 通过。
- 设备当前运行 NSS 镜像 sha256 `2e452ced…4d69`（含 0036+0037）。
- **新阻塞项**：6.18 上 eth0 USXGMII AN 死锁 6/6 确定性失败（§6.2–6.3），
  独立于本次时钟修复，需单独立项。
- **新阻塞项**：WAN 数据面 FAIL（§6.5）——eth1 链路 2.5G/SGMII PLUS 成立，
  但 PPE 出口按 dropcode 119 丢弃全部帧（所有可读使能位均为开）；同时
  LAN 有线口 port3/4 PHY connect -19。eth0 AN 与 WAN 出口两条缺陷候选
  同一根因项目（6.18 phylink/PCS 适配环境差异为首要嫌疑）。
- **已立项**（2026-11-23，用户批准）：`docs/WIRED-DATAPATH-PROJECT-2026-11-23.md`
  覆盖 D1（LAN -19）/D2（WAN dropcode 119）/D3（eth0 AN）。E1 已落地源码：
  补丁 0038（MDIO phy-reset 脉冲，6.12 0036/0150 的 6.18 移植）+ 0039
  （switch bmp 对齐 0x58/0x20），本地构建与真机测试待做（NOT TESTED）。
- 本条不涉及 6.12 的 S95 AN 看门狗（那是 eth0 AN 硬件死锁的另一问题，
  6.18 树尚未移植，另行评估）。
