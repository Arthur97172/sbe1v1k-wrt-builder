# 24.10-6.6 — Spectrum SBE1V1K 固件构建输入

OpenWrt 24.10-SNAPSHOT + QSDK 14.0，目标板 `spectrum_sbe1v1k`（IPQ9574，Linux 6.6）。

本目录只放**编译必需的输入**；装配好的源码树（约 2.4 GB）不在这里。CI 由
`.github/workflows/sources-24.10-6.6.yml` 从公开上游 + 本目录的引脚/补丁/配置现场装配，
发布成 Release 资产 `sources-vN`，再由构建 workflow 下载、校验、解包到 `sources/`。
需要人工上传的文件已经没有了。装配配方见 [docs/SOURCE_ASSEMBLY.md](docs/SOURCE_ASSEMBLY.md)，
流水线说明见 [docs/CI_BUILD.md](docs/CI_BUILD.md)。

## 目录

```
24.10-6.6/
├── build/                    构建输入
│   ├── sbe1v1k-build.sh      构建入口（定位 sources/、渲染 overlay、固定时钟、调 make）
│   ├── host-shims.txt        宿主机工具清单（host-bin 软链按它重建）
│   ├── deterministic-bin/    date 垫片（固定 SOURCE_DATE_EPOCH）
│   ├── config-seed/          defconfig 种子
│   ├── custom-packages.conf          文件 B：应用开关清单（改这个）
│   ├── custom-packages-options.conf  技术性固定选项（每轮重放，勿随意删）
│   ├── thirdparty-feeds.conf         文件 A：第三方源地址与固定提交
│   ├── feeds-links.conf              package/feeds/<feed>/<名字> 软链清单（增删插件要同步）
│   ├── config-frozen/.config         冻结配置：镜像里有哪些包（增删插件要重新生成）
│   ├── known-delta.conf              与审计基线的允许差异（新增源码路径要登记）
│   ├── build-fixes/  luci-patches/  openwrt-patches/  local-packages/  p-b/   装配期改动与本地软件包
│   │                       └─ luci-patches：LuCI 树补丁（`tree` 目标是 sources/luci，装不进 build-fixes）
│   │                       └─ p-b/files/base-files：板级 overlay（board.d/01_network、uci-defaults、eth0-lan-attach、sbe-port-roles）
├── files/                    固件 overlay（唯一来源，构建时渲染进装配树）
│   ├── etc/banner                /etc/banner，`%V`/`%R` 由渲染脚本替换
│   ├── etc/uci-defaults/99-wireless-defaults   首启入口（boot 以 source 执行）
│   ├── etc/init.d/wireless-defaults            每次开机执行（START=95）
│   ├── usr/lib/sbe1v1k/wireless-defaults       实际逻辑（UCI marker 幂等）
│   ├── etc/init.d/ethernet-macs                每次开机固定 eth1–eth3 的 MAC（START=15，先于 network）
│   ├── usr/lib/sbe1v1k/ethernet-macs           实际逻辑（eth0 base MAC +1..+3，见 §以太网端口 MAC）
│   ├── etc/init.d/sbe-wan-tx-watchdog          WAN TX 冻结看门狗入口（START=96）
│   ├── usr/sbin/sbe-wan-tx-watchdog            实际逻辑（见 §WAN TX 冻结看门狗）
│   └── etc/config/sbe_wan_tx_watchdog          看门狗配置（enabled/max_reboots/stall_seconds）
└── scripts/
    ├── render-overlay.sh     把 files/ 整体复制进 sources/buildroot/files 并替换版本占位符
    ├── custom-packages.sh    应用文件 B + defconfig + 逐包反查
    ├── thirdparty-feeds.sh   check / fetch 文件 A 登记的第三方源码
    ├── check-kernel.sh       查 CodeLinaro 厂商内核是否有更新；可确认后升级
    └── ci/
        ├── assemble-sources.sh  装配入口（Actions 用它生成 sources-vN）
        ├── tree-fingerprint.sh  树指纹与审计基线比对
        ├── check-config.sh      冻结 .config 等价门禁
        ├── download-preflight.sh  make -k download 预检
        ├── recipe-hash.sh       装配输入哈希
        ├── refresh-pins.sh      插件 pin 解析到最新 tag/分支头 + 只读内核检测（只开 PR）
        ├── prepare-tree.sh      仅 CI：重建 host-bin、固定时间戳、残留断言
        ├── verify-image.sh      从最终 sysupgrade 镜像解出 rootfs 做静态校验
        └── export-sources.sh    把装配 stage 打成源码包（tar.zst + SHA256SUMS + 指纹）
```

## LuCI（Web 管理界面）

镜像内置 LuCI（`luci-light` 组合 + `luci-mod-admin-full`），由 `uhttpd` + `rpcd` 提供服务，
默认监听 `0.0.0.0:80` 与 `0.0.0.0:443`（`redirect_https` 关闭）。刷机后浏览器打开
`http://<设备地址>/` 即可；`/etc/config/luci` 的 `option lang` 为 `auto`，能拿到 `po/zh_Hans`
的模块都装了对应的 `luci-i18n-*-zh-cn`（上游 `luci-proto-wireguard` 本身没有 po 目录，
没有独立中文包），浏览器语言为中文时自动切换。

首启会在 `/etc/config/firewall` 里追加两条 wan 入站放行规则，均写在项目自有包
`sbe1v1k-defaults` 的 `/etc/uci-defaults/` 下，section 已存在则不覆盖：

- `Allow-LuCI-WAN`（`99-allow-luci-wan`，section `allow_luci_wan`）：`src=wan`、
  `proto=tcp`、`dest_port='80 443'`、`target=ACCEPT`，刷机后可直接从 WAN 侧打开 LuCI；
- `Allow-SSH-WAN`（`99-allow-ssh-wan`，section `allow_ssh_wan`）：`src=wan`、
  `proto=tcp`、`dest_port='22'`、`target=ACCEPT`，WAN 侧可直接 ssh 登录。

时区默认值（`99-system-timezone`）：zonename 仍为 UTC（或空）时写入
`Asia/Taipei` + `CST-8`，并把 `clock_hourcycle` 置为 `h23`。24.10 锁定的 luci
（d0400718c5）没有「时间格式」选项、本来就固定 24 小时制显示；25.12 锁定的
luci（75a306df）有该选项、同样由这个键控制。操作员自己改过时区的，keep-config
升级后不会被覆盖。

其余 wan 入站仍按 zone 默认策略 REJECT（fw4 把用户规则排在 zone 默认拒绝之前）。首启
成功后脚本被删除，同一次安装内不再重跑；但 sysupgrade 只保留 `/etc/config` 等配置，
刷入新镜像后首启脚本会再跑一遍——如果之前把某条 section 删了，它会被重新加回，要彻底
去掉得在升级后再删一次。**代价是管理界面与 SSH 默认暴露在上行链路**：若上行不是运营商
NAT 之内的私网，请先在 LuCI 里设好 root 密码，再按需收紧这两条规则（加 `src_ip`、改
`dest_port` 或删除）；root 密码为空时，`Allow-SSH-WAN` 等于把免密 root 登录开给整个
上行网段。

`Allow-LuCI-WAN` 已在 A 机实测 PASS（2026-11-13，镜像 sha `8920ecd3…`）：`sysupgrade
-F -n` 后首启自动建立，nft `input_wan` 链中位于 reject 之前、LAN/WAN 双侧 HTTP+HTTPS
均 200；重启一次后规则来自持久配置（`/etc/config/firewall` 哈希不变、
`/etc/uci-defaults` 为空），仍然生效。`Allow-SSH-WAN` 是同一时期手工建过并验证过登录的
规则的脚本化（字段逐项一致），但 8920ecd3 镜像不含该脚本，它的首启行为记为
NOT TESTED。

### opkg 源

构建带 `CONFIG_OPKG_NO_DISTFEEDS=y`（`build-fixes/0011`、`0012`），所以镜像出厂的
`/etc/opkg/distfeeds.conf` 是空的——本构建的包都来自本地 `src-link`，官方 24.10 也没有
ipq95xx 目标。空文件会让 LuCI「OPKG 配置」页看起来是坏的、`opkg update` 无事可做，
因此首启脚本 `99-opkg-distfeeds` 写入官方 24.10-SNAPSHOT 的五条源：

```
src/gz openwrt_base      https://downloads.openwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/base
src/gz openwrt_luci      https://downloads.openwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/luci
src/gz openwrt_packages  https://downloads.openwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/packages
src/gz openwrt_routing   https://downloads.openwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/routing
src/gz openwrt_telephony https://downloads.openwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/telephony
```

注意 `aarch64_cortex-a53` **没有**加进 `/etc/opkg.conf` 的 arch 列表（本机是
`aarch64_cortex-a73_neon-vfpv4`），所以只有架构无关（`all`）的包可装——LuCI JS 应用
与中文语言包可以，a53/a73 二进制与 kmod 仍会被拒为 "no valid architecture"，固定包集
不受影响。`distfeeds.conf` 已有 `src/gz` 行时脚本不再覆盖，手工改过的源列表在升级后
保留。该脚本的首启效果记为 NOT TESTED：A 机当前镜像（8920ecd3）仍出厂空源，
也就是用户报告的「OPKG 配置页为空」现象本身；下一次刷机后再验证 `opkg update`
五条源与 arch-all 包安装。

### 端口状态（四个网口）

板级 `board.d/01_network` 的 SBE 分支把 eth0 也写进 LAN 端口表
（`ucidef_set_interfaces_lan_wan "eth2 eth3 eth0" "eth1"`），这样生成的
`/etc/board.json` 里有四个口，LuCI「状态 → 概况 → 端口状态」会全部列出：

| 口 | PPE 端口 | PHY | 角色（默认） |
| --- | --- | --- | --- |
| `eth0` | 6 | RTL8261N 10G | LAN（unmanaged，由 `eth0-lan-attach` 挂进 br-lan） |
| `eth1` | 5 | QCA8081 2.5G | WAN |
| `eth2` | 3 | qca8075 1G | LAN |
| `eth3` | 4 | qca8075 1G | LAN |

**端口角色可配（2026-11-21，阶段 A；真机验证见段末）。** `sbe_ports.main.wan_port`
决定 eth0/eth1 谁是 WAN，`none` 表示四个口全在 LAN；未设置或非法值保持上表的
eth1=WAN。切换由 `/usr/sbin/sbe-port-roles` 完成，它按下表同时收敛三处：

| 场景 | `wan_port` | SSDK 成员表（port3/4/5/6） | br-lan `ports` |
| --- | --- | --- | --- |
| 1 | `eth0` | `0x31 0x29 0x19 0x01` | eth1 eth2 eth3 |
| 2 | `none` | `0x71 0x69 0x59 0x39` | eth1 eth2 eth3（eth0 另由 helper 挂回） |
| 3（默认） | `eth1` | `0x51 0x49 0x01 0x19` | eth2 eth3（eth0 由 helper 挂） |

无 DSA，芯片级 LAN/WAN 隔离只有 SSDK 端口成员表（`ssdk_sh portVlan member
update`），所以只改 UCI 会让防火墙在芯片层被绕过。注意本芯片走 APPE：
开机 `qca_hppe_fdb_hw_init()` 把每口写成全 1 平面表，DTS 的
`switch_lan_bmp/wan_bmp` 不会落到硬件（25.12 树真机 v76 取证），必须由本
脚本显式写入。脚本的顺序是硬性的：先写 SSDK 表并逐口读回校验，失败即放弃、
UCI 一概不动；通过后才改 `network.<br-lan>.ports` 与 WAN 接口的 `device`
（`none` 时给 wan/wan6 置 `auto=0`），再按新角色重建 `/etc/board.json` 的
网络段（删文件后跑 `board_detect`，失败则还原备份），最后清一次 FDB。
`/etc/init.d/sbe-port-roles`（START=19）在开机时执行同一套收敛（network
S20 之前）；启动路径先读回四个物理口，只有成员表已是目标值才跳过写入。
运行期切换用：

```sh
sbe-port-roles set eth0|eth1|none   # 写 UCI 并立即收敛（含 network/firewall reload）
sbe-port-roles apply                # 只按现有 UCI 收敛一次
sbe-port-roles status               # 打印角色与三处现状
```

`eth0-lan-attach` 在 `wan_port=eth0` 时直接返回，不再把 eth0 挂回 br-lan。
`verify-image.sh` 断言脚本、S19 链接、helper 角色判断与 uci-defaults 默认值。

真机验证（2026-11-21，第三台）：早期在 25.12 树上用本树同文脚本验证了
`ssdk_sh` 写入与回读链路（eth1 角色四口收敛到 `0x51/0x49/0x1/0x19`，连通性
无损），同批修复两个共有缺陷——回读按字符串比较（`0x1` vs `0x01` 误判失败）、
`uci set` 对不存在的 `sbe_ports` 配置报 `Entry not found`（现在先 `touch`）。
**2026-11-21 晚间 24.10 线首次上真机**（v113-2-e0ee12cd，`sysupgrade -n`）：
首启全项 PASS；`set eth0` + 重启后 UCI/成员表/桥成员/WAN DHCP/隔离全 PASS；
运行期 live 切换会触发 RTL8261N 假 10G 环回、10G 口需重启，但**回切 eth1
后 2.5G 口直接恢复转发**（25.12 不会，见对照）。`none` 角色仍 `NOT TESTED`。
全过程取证：`docs/WAN_LAN_ROLE_TESTS-2026-11-21.md`。

2026-11-24 起脚本在 live 切换涉及 eth0 时打印显式警告：`set` 的目标或原角色
是 eth0、或 `live` 的当前角色是 eth0 时，stderr 输出「RTL8261N 假 10G 环回，
重启前该口不可用」并建议重启，应用后再补一行提示。只加提示，不改变切换
行为（`set` 仍立即 live 收敛）。桩测试覆盖 10 个场景 PASS；真机 `NOT TESTED`。
「运行期脉冲 GPIO 41 硬复位 PHY」这一未验证的可选缓解已登记为探针计划
（未启动，含触发条件与风险边界）：`docs/RTL8261N_GPIO41_PROBE_PLAN-2026-11-24.md`。

eth0 不能交给 netifd：LAN 地址变更触发的 teardown 会把 RTL8261N/dp1 打进 10G
假环回。所以 board.json 只负责“显示”，首启脚本 `99-spectrum-eth0-unmanaged-lan`
会在 `config_generate` 之后把它从生成的 `network.<br-lan>.ports` 里再删掉，
桥接由 `/usr/sbin/eth0-lan-attach` 在 netifd 之外完成。

挂接是事件驱动的，不再每秒轮询：

| 触发点 | 覆盖的场景 |
| --- | --- |
| `/etc/hotplug.d/iface/30-eth0-lan-attach`（`ifup`/`ifupdate` + `lan`） | 主路径：netifd 应用完 lan 配置后立刻补挂 |
| `/etc/hotplug.d/net/20-eth0-lan-attach`（`add`/`change` + `br-lan`/`eth0`） | 桥新建/重建、eth0 重新出现，包括 netifd 重启 |
| `/etc/init.d/eth0-lan-attach`（START=23，procd 常驻） | 兜底：`ip monitor link` netlink 监听，只看 `br-lan`/`eth0` 事件 |

三个入口都调用同一个 `eth0-lan-attach attach`：先读
`/sys/class/net/eth0/master`，已经挂在 `br-lan` 上就什么都不做；否则
`ip link set eth0 up` + `ip link set eth0 master br-lan`，最多重试 5 次（每次
1 秒）后放弃并写 syslog（`logger -t eth0-lan-attach`）。hotplug 钩子把 helper
放到后台执行，不阻塞 `hotplug-call` 里的其它脚本。需要手工接管桥成员时
`touch /var/run/eth0-lan-attach.disabled` 即可让 attach 停手（tmpfs，重启失效）。

这套机制是绕开驱动的临时措施：根治办法是修 RTL8261N/dp1 在 teardown 后进入
假 10G 环回的驱动问题（`build/kernel-overlay/drivers/net/phy/rtl8261n`），修好后
连同 helper、两个 hotplug 钩子和 init 服务一起删除。

注意 sysupgrade 路径：`/etc/config/network` 会被保留，而 `01_network` 早先以
`[ -e /etc/config/network ] && exit 0` 开头，升级后 SBE 分支整段被跳过，
board.json 网络段改由 `99-default_network` 写成 `"lan": "eth0"`，端口面板
反而只剩 eth0/eth1。现在守卫只挡 `touch`（`[ -e ... ] || touch ...`），
board.json 网络段在升级路径下照常写入；`verify-image.sh` 对该守卫形式有断言。
A 机升级刷入后删除 board.json 重跑 `board_detect`，已确认
`lan.ports = [eth2, eth3, eth0]`（真机 PASS，2026-11-13）。
`verify-image.sh` 同时断言事件驱动结构：helper 含 `ip monitor link` 且没有
`while sleep 1` 轮询、两个 hotplug 钩子存在并调用 `attach`、init 服务以
`monitor` 模式启动。事件驱动版本真机行为 `NOT TESTED`。

### 网口指示灯

**2.5G 口（eth1，QCA8081）指示灯常亮（2026-11-18 修，真机 NOT TESTED）**：
现象是拔不拔网线都亮着，25.12-6.12 同一块板子正常。根因在 PHY 驱动而不是
交换机：本版 `CONFIG_QCA808X_PHY=y`，内建 `qca808x` 驱动绑定 mdio 0x1c 的
QCA8081，`qca808x_config_init()` 无条件把 MMD7 `0x901a` 的 BIT(6) 置上
（LED 极性 active-high）；这块板子的 2.5G LED 是 active-low——厂商 S1 的
`qcom,port_ledinfo` 给 port 5 两颗 LED 都写 `active = "low"`。极性反了之后
“灭”（无链路）反而点亮、“亮”（链路 up / 活动闪烁）反而变暗。25.12 因为
0030 关掉了这个内建驱动（避开与 QSDK qca8084-phy 的重名 -16），这个 PHY
没有任何 phylib 驱动绑定、寄存器保持复位默认值，所以行为正确。
`build-fixes/0031` 把无条件写改成只在显式要求 active-high
（`led_polarity_mode == 0`，来自 netdev 触发器的极性请求）时才写，
运行期 `led_polarity_set()` 覆盖不受影响。

同时 p-b 设备树删掉了厂商的 `qcom,port_ledinfo` 节点：本版 ssdk 的
`ssdk_dt_parse_led_source()` 把 `source = <0xf>`/`<0x10>` 写进
`led_ctrl_pattern_t[SSDK_MAX_PORT_NUM=8][PORT_LED_SOURCE_MAX=3]` 之外
（越界写 `ssdk_dt_cfg` 内存），而 `ssdk_led_init()` 只读 source 0..2，
节点从来没有配到过灯。S2 与 25.12 都没有这个节点。

**蓝灯开机常亮**：pwm-leds 的 `led-blue` 改成 `default-state = "on"`
（red/green 仍为 off）。`default-state` 只在 probe 时把亮度写成最大、
不装触发器，`ledfancontrol` 的 off 动作（trigger=none + brightness=0）
运行期照样能关掉（2026-11-18 在 25.12 真机验证：用 ledfancontrol 关掉后蓝灯
熄灭；24.10 同一机制，尚未单独复验）。

三个 pwm-led 节点都必须写 `max-brightness = <255>`。6.6/6.12 的
`leds-pwm.c` 在 `default-state = "on"` 时执行的是
`cdev.brightness = led->max_brightness`，而 `led->max_brightness` 取自
可选的 `max-brightness` 属性、缺省为 0；`led_classdev_register_ext()`
事后会把 `max_brightness` 补成 255，但 `brightness` 已经停在 0，灯不亮。
2026-11-18 的 25.12 首刷就是靠这个现象（DT 属性 `"on"`、
`max_brightness=255`、`brightness=0`）定位到驱动行为的。
真机 NOT TESTED：24.10 本轮未重编、未刷机，结论来自同一份驱动代码。

### 风扇测速（pwm-fan，2026-11-18，真机 NOT TESTED）

p-b 设备树的 `pwm-fan` 节点补上了测速接线：

```dts
interrupts-extended = <&tlmm 40 IRQ_TYPE_EDGE_FALLING>;
pulses-per-revolution = <2>;
```

GPIO 40 原本就由 `pwm_pins/mux_5` 配成上拉 GPIO，缺的只是把风扇的转速输出
挂到中断上。6.6.147 的 `pwm-fan.c` 只在 `platform_irq_count(pdev) > 0` 时才
创建风扇通道；没有中断时 hwmon 只暴露 `pwm1`/`pwm1_enable`，LuCI 的“风扇设备”
列表显示 `pwmfan`，也不会有转速。补上之后多出 `fan1_input`（RPM），页面显示
`pwmfan — 带测速`，与 25.12-6.12 一致。该写法与 25.12 板级 DTS 相同，DTB 用
6.6.147 的构建树编译通过（`interrupts-extended = <&tlmm 40 2>`、
`pulses-per-revolution = <2>` 已在反编译结果中确认）；设备行为尚未复验——
24.10 本轮未重编、未刷机。不接测速也不影响风扇调速：占空比控制走
`pwm1`，与中断无关。

### 以太网端口 MAC 固定化

引导器（APPSBL）只把板级 base MAC 写进 `dp1` 的 DT `local-mac-address`
（= `eth0`，`addr_assign_type=0`）；`dp2`–`dp4`（`eth1`–`eth3`）的该属性全零，
`nss-dp` 因此**每次开机**给它们分配随机 MAC（`addr_assign_type=1`）。`eth1` 是
WAN、`eth2`/`eth3` 组 `br-lan`，随机地址会让 WAN 的 IP、DHCP 租约和桥 MAC 每次
重启都变（2026-11-14 的 #70 镜像真机现象）。

修复在 overlay：`/etc/init.d/ethernet-macs`（`START=15`，早于 `network` 的 20，
由 `include/rootfs.mk` 自动 enable）调用 `/usr/lib/sbe1v1k/ethernet-macs`，从
`eth0` 读 base MAC（全零/组播/本地管理的地址视为不可用），按 **+1/+2/+3** 逐口
`ip link set address` 固定 `eth1`–`eth3`。偏移低于 `wireless-defaults` 的
+16/+17/+18（Wi-Fi MAC 派生）且高于 `eth0`，不影响“最低以太网 MAC 作 Wi-Fi
base”的规则。只处理 `addr_assign_type=1` 的端口，引导器已给定的地址不动；
base 不可用时只记日志、不改任何端口。`verify-image.sh` 断言两个文件进镜像、
`S15ethernet-macs` 软链存在且脚本按 `addr_assign_type` 判断。真机行为
`NOT TESTED`（需重启验证 MAC 与 IP 是否稳定）。

版本（取自镜像内 `/usr/lib/opkg/status`，随 feeds 更新会变化）：

| 组件 | 版本 |
| --- | --- |
| `luci-base` | 26.202.46438~d040071 |
| `luci-light` | 23.024.33244~34dee82 |
| `luci-mod-admin-full` | 19.253.48496~3f93650 |

共 68 个 `luci-*` 包，分三类：

- **核心**：`luci-base`、`luci-light`、`luci-compat`、`luci-mod-admin-full`、
  `luci-mod-network`、`luci-mod-status`、`luci-mod-system`、`luci-lib-*`、
  `luci-proto-ipv6`、`luci-proto-ppp`、`luci-app-package-manager`；
  主题：`luci-theme-bootstrap` + 第三方 `luci-theme-argon`（v3 起设置页并入主题包，不需要 `luci-app-argon-config`）。
- **上游应用**（feeds `luci`）：`luci-app-firewall`、`luci-app-ddns`、`luci-app-upnp`、
  `luci-app-ttyd`、`luci-app-uhttpd`、`luci-proto-wireguard`。
- **项目与三方应用**：
  - 本项目 feeds（`sources/apps`，11 个）：`luci-app-corestatus`、`luci-app-fcc`、
    `luci-app-ledfancontrol`、`luci-app-meshassistant`、`luci-app-nssecm`、
    `luci-app-online-upgrade`、`luci-app-oxidns`、`luci-app-smartnetpilot`、
    `luci-app-substore`、`luci-app-tasks`、`luci-app-turboacc`
  - 三方 feeds（`sources/thirdparty-feed`）：`luci-app-mosdns`（含 `geo2txt`）、
    `luci-app-nikki`、`luci-app-openclash`、`luci-app-passwall`、`luci-app-poweroff`、
    `luci-theme-argon`；mosdns 后端是 `local-relayout/mosdns` 的预编译二进制包装包
    （2026-11-15 取代 bandix；bandix 前后端当天都已移除）
  - meshassistant 的运行依赖（上游 feed）：`batctl` / `kmod-batman-adv`（`routing`）、
    `luci-proto-batman-adv`（`luci`）、`dawn` / `socat`（`packages`）、`flock`（util-linux）
  - 代理后端（`sources/passwall-selected`）：`chinadns-ng`、`dns2socks`、`ipt2socks`、
    `microsocks`、`shadowsocksr-libev`、`simple-obfs`、`tcping`；另有 `xray`、`sing-box`、
    `mihomo`、`ruby` 等运行依赖，均不带 LuCI 界面包之外的额外前端。

系统工具与内核模块（文件 B 显式列出，`verify-image.sh` 逐条断言）：`openssh-client-utils`、
`tmux`、`curl`、`tar`、`wget-ssl`、`ca-bundle`、`ca-certificates`、`kmod-br-netfilter`、
`kmod-nft-socket`、`kmod-nft-tproxy`、`wireguard-tools`、`kmod-wireguard`。无线侧仍是
`wpad-mesh-openssl-noextns`（见下节）。


### WAN TX 冻结看门狗（2026-11-25，真机 NOT TESTED）

持续 NAT 下载后 `eth1`（WAN，QCA8081 2.5G，SSDK port 5）的 **TX 方向会静默
冻结**：载波在、速率 2500、RX 仍走，但 eth1 一个包都发不出去，上游和互联网
全部不可达，只有重启能恢复。已取证的全部 in-band 手段（txmac 翻转、MAC
流控位改写、PHY 关/开、`eth1` down/up 整口重建、QM flush、TM DEQ_DIS、QM
时钟门控解除、PSCH TDM slot / L0/L1 flow map 同值重写）均无效；wedge 现场
在 PPE 端口 TX 数据通路内部，软件不可达。完整证据见
`docs/WAN-TX-WEDGE-2026-11-25.md`。

兜底在 overlay：`/etc/init.d/sbe-wan-tx-watchdog`（`START=96`，自动 enable）
拉起 `/usr/sbin/sbe-wan-tx-watchdog`。每 15 s 采样 `eth1` 的
`carrier`/`tx_packets`/`rx_packets`；「载波在、有 IPv4 地址、RX 前进而 TX
不动」连续累计 ≥ `stall_seconds`（默认 90 s）后，用 169.254.255.254 假邻居
发 ARP 探针确认（探针只走链路层，不依赖上游）：tx 仍不动即确认冻结，取证
到 `/etc/sbe-wan-tx-watchdog-evidence.log` 后 `reboot` 自愈。配置
`/etc/config/sbe_wan_tx_watchdog`：

- `enabled`（默认 1）：0 关闭；
- `max_reboots`（默认 3）：30 分钟窗口内最多自动重启次数，超限只告警；
- `stall_seconds`（默认 90，下限 60）：TX 冻结累计阈值。

安全边界（楔死态实测，务必遵守）：楔死时只可读 sysfs 计数器、
`/sys/ssdk/packet_counter` 和 `ssdk_sh debug reg`；读
`/sys/kernel/debug/qca-nss-ppe/*`、`qca-nss-netfn/flowmgr/stats`、
`ecm/ecm_db/*` 会把整机锁死到只能物理断电，看门狗不触碰这些路径。


## 无线加密模式

AP（`wpad-mesh-openssl-noextns` = hostapd 2025.11.11，带 SAE / 802.11w / OWE / FILS / DPP；
`wpad-mesh-openssl` 变体依赖的 `qcn-app-extns` 不在导入的 QSDK 树里，属 `SOURCE_UNAVAILABLE`）支持：

| LuCI 中的模式 | `encryption` 前缀 | 说明 |
| --- | --- | --- |
| WPA2-PSK | `psk2` | |
| WPA-PSK/WPA2-PSK Mixed | `psk-mixed` | |
| WPA2-EAP | `wpa2` | 需 RADIUS（`auth_server`）或内置 `eap_server` |
| WPA-EAP | `wpa` | 同上，WPA1 企业级 |
| WPA3-SAE | `sae` | 6 GHz 上强制 PMF |
| WPA2-PSK/WPA3-SAE Mixed | `sae-mixed` | 主 RSNE 同时通告 WPA2-PSK 与 SAE |
| WPA2-PSK/WPA3-SAE Compatibility | `sae-compat` | 见下 |

**Compatibility Mode**（WPA3 规范 v3.5 §13）由 `build/build-fixes/0018` 与
`build/luci-patches/0001` 补进 24.10：主 RSNE 只通告 WPA2-PSK（老客户端照常关联），
SAE 走单独的 RSN Override 元素（`rsn_override_key_mgmt=SAE`、`rsn_override_mfp=2`、
`rsn_override_omit_rsnxe=1`）；6 GHz 上 WPA2-PSK 不允许，自动退回主 RSNE 发 SAE
+ PMF 强制。缺的从来不是编译能力——`wpad` 二进制本来就实现了 `rsn_override_*`，
缺的是 netifd/LuCI 的入口，所以只改脚本与前端，不动任何包和 hostapd 源码。

该模式仅 AP 侧可选（客户端不支持以 Compatibility Mode 关联，会走 Mixed 或纯 SAE）。
`assemble-sources.sh` 与 `verify-image.sh` 会对补丁的关键行和
“`rsn_override_key_mgmt` 赋值早于 override 元素发出”这条顺序各做断言。

**802.11be（Wi-Fi 7）模式下拉**由 `build/build-fixes/0021` 补进：LuCI 只在
`hostapd -v11be` 退出 0 时显示 EHT 模式，而 QSDK hostapd fork 虽然编进了 EHT
（`hostapd-full.config` 的 `CONFIG_IEEE80211BE=y`、驱动侧 iwinfo 已上报 `be`），
`src/utils/build_features.h` 的编译期表里却没有 `"11be"` 分支，探针恒为 exit 1。
补丁只加 4 行 `#ifdef CONFIG_IEEE80211BE` 分支，不引入新的编译能力；装配脚本断言
该分支存在且确实受 `#ifdef` 约束。

### 三频射频与 LuCI 无线对话框（QSDK band-split）

QSDK 的 `/sbin/wifi config` 把一颗 wiphy（`phy00`，PCI `0001:01:00.0`）按硬件频段
拆成三个 `wifi-device` section：`radio0_band0/1/2`（`band` = `2g`/`5g`/`6g`，各自
带 `channels` 范围）。由此有两个与上游 OpenWrt 不同的行为，镜像里都做了处理：

- **射频默认禁用**：生成器给每个射频写 `disabled='1'`（原厂默认由操作者到 LuCI 里
  开启）。`/usr/lib/sbe1v1k/wireless-defaults` 首启应用策略时连同射频级 `disabled`
  一起清除，并 `wifi reload` 让射频真正起来；否则三个网络在 LuCI 概览里都显示
  “已禁用”，手动点“启用”之前射频一直不起。
- **LuCI 射频对话框会删 `band`**：频段下拉的数据源是 `iwinfo freqlist <section>`，
  iwinfo 不认识 `radio0_band2` 这类 section 名（只认 phy/ifname），对每个 section
  都返回 wiphy 的**第一个** band；再加上 `setValues()` 重建选项会丢掉当前选择，保存
  对话框时下拉值为空，而 `uci.set(..., '')` 的语义是**删除**选项，于是 `option band`
  （以及 `option channel`）被删掉，射频随即起不来、日志里是
  `Wireless device 'radio0_band2' setup failed` 与 hostapd
  `Invalid interface name/radio identifier/link id 'phy00.2'`。

修复分两层：`build/luci-patches/0002` 让 band-split section 直接按自身
`band`/`channels` 构建频段表、重建后恢复所选 band、空值不落盘；`wireless-defaults`
另在**每次开机**（marker 检查之前）自愈——仅当 section 缺 `band` 时按 `channels`
范围推断（≤14 → `2g`、≤196 → `5g`、其余 → `6g`）补回并补默认信道，已有 `band` 的
section 不会被改写。装配脚本对 0002 的三处改动与无线自愈函数分别断言，
`verify-image.sh` 也在镜像内复查。

- **“最大传输功率”下拉里只有 255 dBm / “当前功率: 未知”**：同一个 iwinfo 限制
  的两个表现。对 phy 级查询（三个 `radio0_bandN` section 都解析到同一颗
  `phy00`）libiwinfo 匹配不到频道条目，把内部表示“未知”的 `-1` 直接塞进列表
  末项的 `uint8_t dbm`，于是变成 255，rpcd 再用它算 `dBm→mW` 时整数溢出得到
  2147483647 mW；而已配置的 `option txpower`（23）不在列表里，浏览器打开
  对话框时预选第一个选项，原样保存就会把 txpower 换成 255 或删掉。
  `build/luci-patches/0003` 先按 **本射频的 VAP 接口名**探测：txpower 选项挂在
  wifi-device 下，`wifiNetwork` 是射频网络，它自己的 `getIfname()` 只给出
  `radio0_band0` 这类 netid，所以补丁从 `wifiNetwork.getWifiNetworks()` 枚举
  该射频的每个 VAP，取各 iface 的 `getIfname()`（`phy00.0-0` 等）：真机实测
  2.4G/5G 的 VAP 返回完整 `0..30 dBm` 列表，phy 级与 6 GHz VAP（libiwinfo
  没有 6 GHz band）都只有哨兵；VAP 无列表时回退到射频设备名与 section 自身，
  再回退到 `iwinfo devices` 报告的其它 VAP。这样每个频段用自己那份列表，
  不会三个频段共用第一个可用列表。列表过滤 0..63 dBm 之外的条目，并把
  section 自身的 `option txpower` 补进下拉、保持选中——保存不再丢配置。
  “当前功率 0 dBm”是 QSDK ath12k 不回报当前发射功率时 nl80211 的 0，补丁改为
  显示已配置的 `option txpower`。`0004` 在 `luci-mod-network` 的 rpcd ACL 里
  放行只读的 `iwinfo devices`（否则 6 GHz 回退被拒）。限制都在
  libiwinfo/rpcd 侧，只在 LuCI 前端做防御，不碰 C 代码。

- **hostapd 拒载配置（所有 Wi-Fi 显示“已禁用”的真根因）**：QCA 的
  `wifi-scripts` 生成 `hostapd-phy00.X.conf` 时无条件追加
  `disable_iface_during_cac=0` 与 `athnewind=0`，而这两项只有
  `qcn-app-extns` 解析。本镜像按导入范围只编 `wpad-mesh-openssl-noextns`，
  hostapd 于是报 `unknown configuration item`、`2 errors found`、
  `add_iface failed`，三个 radio 的 BSS 全都不起——`ip link` 里只剩一条
  DOWN 的 `phy00.1-0`，LuCI 无线页整页“已禁用”，而编辑对话框读的是 uci，
  仍显示“无线网络已启用”。这不是 LuCI 的显示 bug，也不能靠
  `wireless-defaults` 修掉。`build-fixes/0022` 删掉这两行 append：扩展
  默认值本就是 0，行为不变；装配脚本断言两行都消失，`verify-image.sh`
  在镜像里复查。真机验证：A 机 2026-11-13 PASS（配置拒载错误消失；2.4G
  BSS 起来、SSID 广播、客户端 SAE 关联成功）。同机复测还发现两个与 0022
  无关的独立问题，见下面两段。

- **三频 MAC 相同（5G 起不来的根因）**：ath12k 固件给 wiphy 的
  `macaddress`、`address_mask`（全零）与 `addresses` 三个条目都是同一个
  占位 MAC `00:03:7f:12:34:56`；QCA wifi-scripts 的 `macaddr_generate()`
  在 mask 全零时按 `addresses[radio]` 给三个 band vif 分配地址，于是三个
  vif 拿到同一个 MAC。第二个 vif 起链路时被驱动判重（dmesg
  `DUP MAC addr 00:03:7f:12:34:56 -> phy00.0-0, vif types: 3/3`），
  `ip link set up` 返回 “No error information”，hostapd 侧表现为
  `Failed to create interface phy00.1-0: -23`（mac80211 的
  `dev_alloc_name` 对重名返回 `-ENFILE`，打印成
  “Too many open files in system”），use_existing 分支随后仍失败在 `UP`，
  最终 `hostapd.add_iface failed`。修复在 `wireless-defaults`：每次开机
  给 `macaddr` 缺失或仍为占位值的 band iface 写入派生地址（板级最低以太网
  MAC +0x10/+0x11/+0x12，本机 `90:d3:cf:3c:34:b6/b7/b8`），已有配置的 MAC
  不覆盖。真机验证：A 机 2026-11-13 PASS（2.4G `b6` ch11、5G `b7` ch40
  两个 BSS 起来并广播）。
- **6 GHz 取决于固件 `regdb.bin`（打包件里 TW 不可用，可替换恢复）**：
  2026-11-13 起默认国家码为 **US**、默认 6G 信道为 **37**（用户提供的默认值；
  同日 2.4G htmode 改为 `EHT20`），因此新装默认按 US regdomain 配置；下面
  这段 TW 限制适用于把国家码设回 TW 的场景。ath12k 的 self-managed 规则
  来自固件：国家码经 hostapd/`iw reg set` 实时下发固件（2026-11-15 B 机
  实测 US↔TW 即时切换、无需重启），各频段可用信道由固件侧的 `regdb.bin`
  决定，完全不看 wireless-regdb。镜像打包的 `regdb.bin`（`09bf84…`，
  WLAN.WBE.1.6 时代）里 TW 没有 6 GHz 信道（`iw phy` 中 6 GHz 全部
  `(disabled)`，dmesg `pdev is not supported for this country`，即 QSDK
  补丁 `0104-wifi-ath12k-disable-pdev-for-non-supported-country` 的
  `-EOPNOTSUPP` 分支）。把 country 换成 US 后 6 GHz 立即可用，证明硬件与
  驱动链路正常，打包件的固件规则是唯一阻塞。`wireless-defaults` 因此每次
  开机探测：没有任何可用 6 GHz 信道时把 `radio0_band2` 置 `disabled='1'`
  并记 `spectrum_6g_fw_blocked='1'`（避免 hostapd 反复失败），信道恢复
  可见时自动解除。另测得 `channel 61` + `EHT320` 会被驱动拒绝
  （`Failed to set beacon parameters (ret=-22)`），US 下 `channel 37` +
  `EHT320` 可正常广播，故 2026-11-13 起默认信道改为 37。
  **TW 6 GHz 可用替换 `regdb.bin` 恢复（2026-11-15 B 机真机验证）**：把
  `extracted/rootfs/lib/firmware/qcn9224/regdb.bin`（厂 rootfs 提取件，
  `3b064e…`，WLAN.WBE.1.5 时代，236 国）覆盖到
  `/overlay/upper/lib/firmware/ath12k/QCN92XX/hw1.0/regdb.bin` 后重启（不改
  squashfs），TW 下 6 GHz 出现 24 个可用信道 5955–6415 MHz（6435 起
  `(disabled)`，符合 TW 5945–6425 规则），6G 在 ch37 EHT320 广播
  （23 dBm），三频全部起站、无 `pdev` 报错；同一台机换回打包件即复现
  "TW 下 0 个可用 6G 信道"。回滚：删掉该 overlay 文件并重启。该提取件
  来源与许可证待评审（`LICENSE_REVIEW_REQUIRED`），与 firmware-2.bin 1.6
  只做过短时兼容验证，因此**当前未打包，默认仍为 US**。真机验证：A 机
  2026-11-13 PASS（TW：6G 射频自动禁用、2.4G/5G 正常；US 临时测试：三频
  BSS 全部起来，6G 在 ch37 EHT320 广播）；B 机 2026-11-15 PASS（打包件 +
  TW：0 个可用 6G 信道；提取件 + TW：三频起站、6G ch37 EHT320 广播）。
  固件将来提供 TW 6 GHz 规则时，开机探测会自动重新启用该射频。

## 本机构建

装配树位于 `<工作区>/sources/buildroot`（本目录的上一级目录里）。

```sh
./24.10-6.6/build/sbe1v1k-build.sh defconfig            # 生成 .config
./24.10-6.6/build/sbe1v1k-build.sh -j"$(nproc)"         # 完整编译
./24.10-6.6/build/sbe1v1k-build.sh -j"$(nproc)" target/install   # 只重打镜像（不重装软件包）
./24.10-6.6/scripts/ci/verify-image.sh                  # 静态校验
```

> `target/install` 只重打包镜像，**不会重装软件包**：改了文件 B（增删包）之后必须
> 跑一次完整 `make`（`sbe1v1k-build.sh -j$(nproc)`），否则镜像仍带旧的包集合。

产物在 `sources/buildroot/bin/targets/ipq95xx/generic/`，只交付三个文件：

- `openwrt-ipq95xx-generic-spectrum_sbe1v1k-squashfs-sysupgrade.bin`
- `openwrt-ipq95xx-generic-spectrum_sbe1v1k-fit-uImage.itb`
- `openwrt-ipq95xx-generic-spectrum_sbe1v1k-initramfs-fit-uImage.itb`

## 第三方组件：文件 A / 文件 B

第三方应用由两个文件管理，默认内容与当前固件完全一致（已用逐字节 `diff` 验证）。

### 文件 B：`build/custom-packages.conf`（选哪些包）

```sh
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-passwall"      # 启用
# CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-samba4"      # 关闭
```

- **注释掉 = 关闭**；想彻底不管某个包，删掉整行即可，但那样它就会回到
  config-seed / Kconfig 默认值，不建议。
- 只放**应用层**开关。依赖库（`xray-core`、`sing-box`、`mihomo-meta`、`ruby`…）
  由 defconfig 解析；关闭应用**不会**自动清掉依赖库。
- 构建入口每次 `make` 前都会自动应用文件 B（本地与 CI 同一路径）。因此
  **menuconfig 里手改的配置会在下一次构建被覆盖**；临时跳过用
  `SBE_SKIP_CUSTOM_PACKAGES=1`。
- defconfig 对未知包/依赖不满足的包是**静默丢弃**的，所以脚本在 defconfig
  之后逐条反查：启用的包不是 `=y` 就非零退出并指名。

### 文件 B2：`build/custom-packages-options.conf`（技术性固定选项）

存放不随应用开关变化的 Kconfig 行（passwall 的 `INCLUDE_*`、`iw-full` 等）。
这些符号在父应用关闭时是“不可见”的，defconfig 会把它们从 `.config` 里删掉，
重新打开父应用时回到默认值（其中多个默认是 `y`，会带进 Geoview 等本项目
明确不打包的东西）。脚本每轮都原样重放本文件，挡住这种跨轮次漂移。

### 文件 A：`build/thirdparty-feeds.conf`（源码从哪来、钉在哪个提交）

```
repo <key> <url> <branch> <commit> <vendor-dir> <mode>
link <feed-name> <repo-key> <subdir>
local <feed-name> <path>
```

- `mode=git`：干净单仓库，可 `fetch` 自动对齐固定提交；
  `mode=manual`：人工剪裁/带补丁，只校验 HEAD、不改写（本项目当前没有 manual 仓库）。
- `sources/thirdparty-feed/*` 全是**相对软链**，脚本只维护这些软链和
  `thirdparty/<repo>` 目录，**不改** `buildroot/feeds.conf`，也**不跑**
  `scripts/feeds update`（它会产生绝对路径，CI 的 `prepare-tree.sh` 规则不允许）。

```sh
./24.10-6.6/scripts/thirdparty-feeds.sh check   # 只读校验 HEAD、工作区、软链
./24.10-6.6/scripts/thirdparty-feeds.sh fetch   # 本地已在 pin 时不联网
```

### 升级第三方组件

1. 改文件 A 的 `commit`（必要时改 `url`）；
2. `scripts/thirdparty-feeds.sh fetch` 拉取；
3. `build/sbe1v1k-build.sh defconfig`，确认 `.config` 没有意外变化；
4. 更新 `24.10-6.6/docs/package/PROVENANCE.md` §2.9 的 pin 与许可证记录；
5. 提交并 push；等 `sources-24.10-6.6.yml` 验证通过后手动 `publish=true` 发新的
   `sources-vN`，构建 workflow 的 `source_tag=auto` 会自动用最新的一版。

**升级同样要过指纹门禁**：上游内容变了，装配第 16 步会以 `changed`/`fresh-only`/
`audited-only` 差异把与审计基线的偏离全部列出来。少量、可解释的改动按
`known-delta.conf` 的规矩逐条登记（reason 写清原因，并在装配脚本里有对应断言）；
差异成规模时（等于换了上游版本）就不该用白名单糊过去，而应重新审计、出新基线——
那是审计动作，需要单独批准。**插件树**（`apps/*`、`thirdparty/*` 等）自 2026-11-07
起整树按 `any` 放宽，不参与这条逐文件基线。

日常的“跟最新”不用手改：`refresh-pins-24.10-6.6.yml` 每周跑
`scripts/ci/refresh-pins.sh --apply`，把最新 tag/分支头写进两个 pin 文件并开 PR；
本地也可以先看一眼它会改成什么（只读、不改文件）：

```sh
./24.10-6.6/scripts/ci/refresh-pins.sh                  # old→new 表 + 内核结论
./24.10-6.6/scripts/ci/refresh-pins.sh --no-kernel      # 跳过 GitLab 内核查询
```

口径：有版本 tag 取版本序最大者，**不回退**（比当前 pin 旧/分叉就保持不动）；
无版本 tag 退回默认分支头。内核只报告不改，升级仍走 `scripts/check-kernel.sh`。

第 5 步不能省：**CI 编译用的是源码包，不是本地 `sources/`**，只改文件 A
不会影响 CI。装配输入（`build/**`、四个装配脚本、25.12 的 Wi-Fi blob）一有 push，
装配 workflow 就会重新验证并比对新指纹。

### 新增第三方 LuCI 插件

分三种来源，要改的输入不同：

| 来源 | 要改的地方 |
|---|---|
| 新仓库（别人的插件） | 文件 A 加 `repo` + `link`；`feeds-links.conf`；文件 B；冻结配置；`known-delta.conf` |
| 已钉定仓库里的另一个包（同一 repo 下的第二个 `luci-app-*`） | 文件 A 只加 `link`；`feeds-links.conf`；文件 B；冻结配置 |
| 自己维护的目录（不在任何仓库里） | 文件 A 用 `local`，或源码放 `build/local-relayout/` 后由 `feeds-links.conf` 指向它 |

**源码进 feed、开关打开、冻结配置跟上，三件事都要做。** 少做任何一件的后果是确定的，
不会"碰巧还能用"：

| 少做了 | 结果 |
|---|---|
| 没有 `thirdparty-feed/<名字>` 软链 | 包不在 feed 里，`feeds-links.conf` 的目标悬空 → 装配第 13 步 `die 4` |
| 有软链但没加 `feeds-links.conf` 行 | OpenWrt 看不到这个包，`.config` 里的 `=y` 被 defconfig **静默丢弃** |
| 文件 B 加了、冻结配置没加 | `check-config.sh` 看不出来（它在文件 B 生效之前跑），但镜像会比门禁验证过的多一个包 |
| 冻结配置加了、文件 B 没加 | 镜像里有，但 `verify-image.sh` 不会检查它（它只核对文件 B 启用的包） |
| 忘了改装配脚本里的软链条数 | 装配直接失败在 feeds 接线步（安全失败，不会产出半成品包） |

#### 1. 先确认插件信息

```sh
git ls-remote <url> refs/heads/main          # 取 40 位 commit；禁止用分支/标签/漂移
```

要确认四件事：**包目录名**（= feeds 里的名字 = `.config` 里的 `CONFIG_PACKAGE_<名字>`）、
目录里有 `Makefile`、许可证（记进 `PROVENANCE.md` §2.9）、以及它是否依赖同仓库的其它包
（例如 `luci-app-mosdns` 要配后端 `mosdns`，两个都要接）。

#### 2. 文件 A：`build/thirdparty-feeds.conf`

```
repo <key> <url> <branch> <commit> <vendor-dir> <mode>
link <feed-name> <repo-key> <subdir>
```

以仓库根目录即包目录的 `luci-app-foo` 为例：

```
repo foo               https://github.com/someone/luci-app-foo.git  -  <40 位 commit>  thirdparty/luci-app-foo  git
link luci-app-foo      foo        .
```

- `vendor-dir` 相对 `sources/`，惯例是 `thirdparty/<仓库名>`；
- `mode=git`：要求工作区干净，`fetch` 可自动对齐 pin；人工剪裁或带补丁的用 `manual`
  （脚本只校验 HEAD、不改写）。装配脚本对 manual 仓库**不施加任何补丁**：需要在
  装配时改写的仓库必须在 `build/build-fixes/SERIES` 里登记补丁（tree 模式）；
- `<feed-name>` 必须等于包目录名；`<subdir>` 是包在仓库里的相对路径，在仓库根就写 `.`；
- 同一仓库的第二个包只加 `link`，不要再写一条 `repo`。

#### 3. `build/feeds-links.conf`：让 OpenWrt 看见它

一条 `link` 对应这里一行（`package/feeds/<feed>/<名字>` 软链）：

```
buildroot/package/feeds/thirdparty/luci-app-foo	thirdparty/luci-app-foo
```

- 两列都相对 `sources/`；第二列写**解析后的目标**（文件 A 的 `vendor-dir` + `subdir`），
  不要照抄软链文本；
- 按链接路径排序插入 `thirdparty/` 段；
- 同仓库带出来的依赖包（如 `luci-app-mosdns` 对应的 `geo2txt`、预编译的 `mosdns`）各自一行。

#### 4. 改装配脚本里的条数断言

`scripts/ci/assemble-sources.sh` 的 feeds 接线步：

```sh
[ "$nl" = 177 ] || die 4 "package/feeds 软链应有 177 条，实际 $nl"
```

加一行就改成 178，并同步改该步上方的注释与 `docs/SOURCE_ASSEMBLY.md` 里出现的条数
（`grep -rn '177' 24.10-6.6/docs` 可列全）。如果新增了新的 `src-link` 源，还要改
`feeds.conf.in` 和同一步的 `[ "$nf" = 11 ]`。

#### 5. 文件 B：`build/custom-packages.conf`

```sh
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-foo"
# 中文界面：包目录里必须有 po/zh_Hans，否则不存在这个 i18n 包
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-foo-zh-cn"
```

- 只写**应用层**开关，依赖库交给 defconfig 解析；
- 关闭某个包不要删行，注释掉整行，保留上下文：

  ```sh
  # CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-samba4"      # 关闭
  ```

- 文件 B 是"进不进镜像"的唯一开关源：`verify-image.sh` 会逐条断言这里启用的包真的
  出现在 rootfs 的 `/usr/lib/opkg/status` 里；
- 技术性固定选项（父应用关闭时会被 defconfig 丢掉的那些）放
  `build/custom-packages-options.conf`。

#### 6. 冻结配置：`build/config-frozen/.config`

不要手写符号值，必须由 defconfig 求解后落盘，否则依赖链和行序会和真实求解结果不一致：

```sh
./24.10-6.6/build/sbe1v1k-build.sh defconfig      # 应用文件 B → make defconfig → 逐包反查
cp sources/buildroot/.config 24.10-6.6/build/config-frozen/.config
./24.10-6.6/scripts/ci/check-config.sh            # 必须 PASS；失败看 config-diff.txt
```

- defconfig 会连带写入这个包的依赖（`kmod-*`、`lib*` 等），**保留它们**；
- `check-config.sh` 跑之前要先 `./24.10-6.6/scripts/render-overlay.sh`，否则 overlay 里的
  配置片段缺失会造成假差异（CI 顺序就是 render-overlay → check-config）；
- 冻结文件一改，就必须重发 `sources-vN`：`check-config.sh` 的前置断言要求源码包里的
  `.config` 与冻结文件**逐字节相同**，旧包会被点名"包与配方不同步"。

#### 7. 指纹白名单：`build/known-delta.conf`

装配第 16 步拿结果与审计基线 `build/fingerprint/audited-24.10-6.6.tsv.zst` 逐文件比对，
**新增路径一律算 `fresh-only` 差异，没登记就是 `FINGERPRINT_MISMATCH`（rc=5）**。
一个插件通常产生三类新路径：

```
thirdparty/luci-app-foo/*	fresh-only	新增第三方仓库 <url> @ <commit>（<许可证>）；pin 由文件 A 与 recipe_sha256 钉住
thirdparty-feed/luci-app-foo	fresh-only	相对软链，由 thirdparty-feeds.sh check 校验
buildroot/package/feeds/thirdparty/luci-app-foo	fresh-only	目标存在且含 Makefile，装配第 13 步断言
```

`known-delta.conf` 头部写明了两条规矩，必须遵守：reason 写清"为什么这不是问题"，
并且**装配脚本里要有对应的可执行断言**——不能只靠白名单把差异盖掉。上面三条对应的
断言分别是文件 A 的 pin 校验、`thirdparty-feeds.sh check`、feeds-links 的目标/Makefile 校验。

> 另一条路是重新生成审计基线。那会更换"重建的树 == 已审计的树"这条证据的基准，
> 属于审计动作，**需要单独批准**；不要为了让门禁变绿顺手做。

#### 8. 本地验证（顺序不要换）

```sh
./24.10-6.6/scripts/thirdparty-feeds.sh fetch     # 新 repo 按 pin 浅克隆；已在 pin 时不联网
./24.10-6.6/scripts/thirdparty-feeds.sh check     # HEAD / 工作区 / 软链
./24.10-6.6/scripts/ci/recipe-hash.sh             # 记新值：feeds-links.conf 变了，哈希必然变
./24.10-6.6/scripts/ci/assemble-sources.sh --stage /var/tmp/stage-foo --force
./24.10-6.6/scripts/ci/check-config.sh
```

日志里要看到：第 12 步 `TP_OK`、第 13 步 `package-links=<新总数>`、第 16 步
`FINGERPRINT_MATCH`。任何一步不过就停下来查，不要改判据。

> `recipe_sha256` 的输入清单里**没有** `thirdparty-feeds.conf` 和 `custom-packages.conf`
> （见 `scripts/ci/recipe-hash.sh`）。只改文件 A 的 pin 时配方哈希不变，这个改动由树指纹
> 以 `changed` 差异负责暴露；改 `feeds-links.conf` 或 `config-frozen/` 才会改配方哈希。

#### 9. 提交、发布、构建

```sh
git add 24.10-6.6/build/thirdparty-feeds.conf \
        24.10-6.6/build/feeds-links.conf \
        24.10-6.6/build/custom-packages.conf \
        24.10-6.6/build/config-frozen/.config \
        24.10-6.6/build/known-delta.conf \
        24.10-6.6/scripts/ci/assemble-sources.sh \
        24.10-6.6/docs/package/PROVENANCE.md \
        24.10-6.6/docs/SOURCE_ASSEMBLY.md
```

push 后 `sources-24.10-6.6.yml` 自动以 `publish=false` 验证；通过后手动
`publish=true` 发新的 `sources-vN`；`build-24.10-6.6.yml` 用 `source_tag=auto` 编译。
**只改文件不发布，CI 看不到**——它编译的是源码包。

### 删除第三方 LuCI 插件

反向操作，顺序不能反（先关开关，再拆接线）：

1. **文件 B**：注释掉那一行（连同 `luci-i18n-*`），保留原文便于回滚；
2. **冻结配置**：按上一节第 6 步重新生成并 `check-config.sh` PASS。确认
   `CONFIG_PACKAGE_<名字>=y` 消失；依赖库不一定跟着消失（仍被其它包引用时会保留），
   要清掉得单独处理；
3. **文件 A**：删对应 `link` 行；确认该仓库已不被任何 `link`/`local` 引用，再删 `repo` 行；
4. **`feeds-links.conf`**：删对应行（含同仓库带出来的依赖包行），并把装配脚本里的
   条数断言改回去；
5. **`known-delta.conf`**：删掉当初为它登记的白名单条目。删掉后这些路径根本不存在，
   比对不会报错，但留着条目会让同名路径在将来被无声放过；
6. **手工清理本地源码树**（脚本只建不删）：

   ```sh
   rm -f  sources/thirdparty-feed/<名字>
   rm -rf sources/thirdparty/<vendor-dir>      # 仅当整个仓库不再使用
   ```

7. 重跑第 8 节的本地验证，然后按第 9 节发布新 `sources-vN`。

**顺序为什么不能反**：先拆源码（文件 A / `feeds-links.conf`）、后改文件 B 的话，
包已经不在 feed 里，而文件 B 仍要求它 `=y`；构建走到「Apply custom packages」时
逐包反查会失败并指名——是安全失败，不会产出缺包镜像，但白费一次待验证的装配。
按上面 1→2 先把开关和冻结配置清干净（此时包还在树里，一切自洽），再拆接线，
每一步都能单独验证通过。

### 增删插件：改动文件速查

| 文件 | 新增 | 删除 |
|---|---|---|
| `build/thirdparty-feeds.conf` | 新仓库加 `repo`+`link`；旧仓库只加 `link` | 删 `link`；仓库不再被引用时删 `repo` |
| `build/feeds-links.conf` | 加 `package/feeds/thirdparty/<名字>` 行（含依赖包） | 删对应行 |
| `scripts/ci/assemble-sources.sh` | `[ "$nl" = 177 ]` 改成新总数 | 改回去 |
| `build/custom-packages.conf` | 加 `CUSTOM_PACKAGES="$CUSTOM_PACKAGES <名字>"` | 注释掉整行 |
| `build/config-frozen/.config` | `make defconfig` 后整体替换 | 同左 |
| `build/known-delta.conf` | 加 `fresh-only` 条目（新路径） | 删掉对应条目 |
| `docs/package/PROVENANCE.md` §2.9 | 记 pin、许可证、文件数 | 删除对应记录 |

### 检查与升级内核

内核**不会自动升级**：源码是扁平外部树 `sources/buildroot/qca/src/linux-6.6`
（无 `.git`，构建时不联网），上报版本由 `sources/buildroot/include/kernel-6.6`
决定，两者必须一致。升级只能靠 `scripts/check-kernel.sh` 显式触发。

```sh
./24.10-6.6/scripts/check-kernel.sh              # 只看 win_qsdk.common.* 家族
./24.10-6.6/scripts/check-kernel.sh --all        # 加 win.linux.6.6.* 与 NHSS.*
./24.10-6.6/scripts/check-kernel.sh --upstream   # 附带上游 6.6.y 的 SUBLEVEL（仅参考）
./24.10-6.6/scripts/check-kernel.sh upgrade win_qsdk.common.1.0.r50   # 升级（可加 --dry-run）
./24.10-6.6/scripts/check-kernel.sh rollback     # 整体还原最近一次升级
```

- **检查**：发现更新版本时，在交互终端里会询问“是否升级到 …”；回答 `y` 就走升级流程。
  非交互环境（CI、管道）**只报告不动手**，退出码 `2` 并打印 upgrade 命令。
- **升级**：浅克隆该分支（数 GB、10–40 分钟）→ 换 `qca/src/linux-6.6` →
  同步 `include/kernel-6.6` 的 `LINUX_VERSION-6.6` → 改名并更新
  `build-fixes/0002-kernel-6.6-report-*.patch`。**不编译**。
- **构建前预检**：`build/sbe1v1k-build.sh` 在交互终端里（stdin 与 stdout 都是终端）
  会先跑一次 `check-kernel.sh`，有更新就询问，答 `y` 则自动升级并在编译前执行
  `make target/linux/clean`。CI、管道、脚本调用**一律跳过**（构建脚本只在预检这一处联网）；
  `SBE_KERNEL_CHECK=0` 关掉预检，`=1` 在非交互环境里只检查、不提示。
- **备份**：旧树在 `sources/.kernel-backup/linux-6.6.<旧版本>-<时间戳>/`，
  含 `tree`、`0002.patch`、`state`。不能放进 `qca/src/` —— 那里的 `linux-*.*`
  会被 `ipq95xx/Makefile:13` 的 glob 一起匹配。中途失败会自动回滚。
  确认新内核可用后可删掉该目录（每个约 4 GB）。

退出码：`0`=已最新或升级完成，`1`=本地两处版本不一致/参数错误，`2`=有更新但未升级，
`3`=读不到远端（限流）。分支名**不含**内核版本（`win_qsdk.common.1.10.r2` 实为
6.6.47，比现用的 `win_qsdk.common.1.0.r48`=6.6.147 更老），所以逐条读 `Makefile`
的 `SUBLEVEL` 比较。

升级后必须重编，且 CI 不跟随：

```sh
make -C sources/buildroot target/linux/clean
./24.10-6.6/build/sbe1v1k-build.sh defconfig       # 留意 config-6.6 缺符号告警
./24.10-6.6/build/sbe1v1k-build.sh -j"$(nproc)"
```

`target/linux/feeds/ipq95xx/config-6.6` 可能需要补新符号；`files-6.6` 里的
sbe1v1k DTS 由 make 每次拷进新树，无需手工处理。CI 用的内核由装配 workflow 按
`build/upstream-pins.conf` 的 CodeLinaro 提交现场取；换内核要先改那个 pin、
重跑装配并发布新的 `sources-vN`。新内核在编译与真机验证前一律记为
`UNVERIFIED` / `NOT TESTED`。

## 升级（sysupgrade）与 A/B 槽位

镜像格式是 `pad-rootfs-64k | sysupgrade-tar | append-metadata`，即
`sysupgrade-spectrum_sbe1v1k/{CONTROL,kernel,root}` 的 tar 包：`mmc.sh` 把
`kernel` 写进 HLOS 分区、`root` 写进 rootfs 分区，再在 rootfs 尾部就地建 ext4
overlay。

板子的 eMMC 是 QSDK 的 A/B 布局：`0:HLOS` + `rootfs` 与 `0:HLOS_1` + `rootfs_1`，
SBL 按 `0:BOOTCONFIG` / `0:BOOTCONFIG1` 选一组，U-Boot 再按选中的那组注入
`root=PARTUUID=…`。本内核没有启用 `CONFIG_BOOTCONFIG_PARTITION`（没有
`/proc/boot_info`），所以 `lib/upgrade/platform.sh` 从**正在运行的根文件系统**
反推槽位：`/rom` 的 major:minor → `/sys/dev/block/<maj>:<min>/uevent` 的
`PARTNAME`；`rootfs` 对应 `0:HLOS`，`rootfs_1` 对应 `0:HLOS_1`。stage2 会先
切到 ramfs（那时 `/rom` 已不在），所以结论在 `platform_pre_upgrade`（切换之前）
写进 `/tmp`。

- **认不出槽位就拒绝写入**（`PARTNAME` 既不是 `rootfs` 也不是 `rootfs_1`）：
  宁可升级失败，也不把内核和根文件系统写进不同槽位。
- 写入前核对 tar 里 `kernel` / `root` 段的字节数与目标分区大小，rootfs 尾部
  还要至少留 8 MiB 给 overlay（ext4 在 1 MiB 上也能格式化，但 overlay 一写就满、
  变成只读，症状比拒绝刷机难查得多，所以闸门设得比最小值高），放不下就失败
  （否则会写一半、留下坏根文件系统）。
- `rootfs_data`：bootargs 带 `fstools_ignore_partname=1`，fstools 不会使用板上
  名为 `rootfs_data` 的 GPT 分区，overlay 建在 rootfs 分区尾部。厂商出厂固件
  也是这个模型（真机上 `/overlay` 是 `/dev/loop0`，挂在 rootfs 分区 offset
  处），我们与之保持一致。
- 该文件由 `prepare-tree.sh` 每次构建用 `build/p-b/files/base-files/` 的副本
  覆盖（`sources-v1` 里的版本是导出时的旧版），`verify-image.sh` 再核对镜像里
  的那一份与装配树逐字节一致。
- 本地增量构建时注意：`package/base-files/Makefile` 的 `PKG_FILE_DEPENDS` 不含
  子目标的 `target/linux/feeds/ipq95xx/base-files/`，而且 `target/install` 不会
  重新把包合并进 rootfs。改过之后要跑 `make package/base-files/clean` →
  `make package/base-files/compile` → `make package/install target/install`，
  否则镜像里留的是旧脚本（`verify-image.sh` 第 9 项会以 FAIL 指出）。CI 每次
  都是新树，不受影响。

真机升级状态：**PASS（2026-11-16，v94-1-da7e20bd）**。B 机从恢复模式 RAM
系统执行 `sysupgrade -F -n`，约 54 秒回到 24.10，刷后启动、三频无线、客户端
关联与 NAT 上网实测通过；完整过程见
[docs/V94_FIELD_VERIFICATION-2026-11-16.md](docs/V94_FIELD_VERIFICATION-2026-11-16.md)。
更早的 v78 升级没记录流程，只作旁证
（[docs/V78_FIELD_VERIFICATION-2026-11-15.md](docs/V78_FIELD_VERIFICATION-2026-11-15.md)）。

## CI

三个 workflow，避免把几小时的编译和装配挤在一次运行里：

| workflow | 触发 | 产物 |
|---|---|---|
| `sources-24.10-6.6.yml` 🧱 | `build/**`、`docs/**`、四个装配脚本变更 / 手动 | Release `sources-vN`：源码包 + `SHA256SUMS` + 指纹（恰好 3 个） |
| `build-24.10-6.6.yml` 📦 | `24.10-6.6/**` 变更 / 手动（可指定 `source_tag`） | Release `24.10-6.6-v<run>-<attempt>-<sha8>`：三个固件（恰好 3 个） |
| `refresh-pins-24.10-6.6.yml` 🔄 | 每周一 04:23 UTC / 手动 | 分支 `auto/pin-refresh` + 一个 PR：插件 pin 的 old→new 表与内核检测结论；**从不自动合并** |

插件怎么“跟最新”：`refresh-pins.sh` 把 11 个自维护插件与 7 个第三方仓库解析到
最新 release tag（无版本 tag 的退回默认分支头，比当前 pin 旧/分叉则保持不动），
改写 `upstream-pins.conf` / `thirdparty-feeds.conf` 的 commit 字段与
`PROVENANCE.md` 的 pin 快照，再开 PR。合并后 push 自动触发装配验证；发
`sources-vN` 仍为手动 `publish=true`。内核**只检测不改**——要升级仍走
`scripts/check-kernel.sh`（见上文）。

构建流程：`source_tag=auto` 挑最新的 `sources-vN`（N≥2、资产数恰好 3；`sources-v1` 是含
`dl/` 的 legacy，跳过）→ `sha256sum -c` → 解包 → 树指纹比对（未解释差异必须为 0）→
配方哈希比对 → `prepare-tree.sh` → `render-overlay.sh` → `check-config.sh` →
`thirdparty-feeds.sh check` → `make -k download` 预检 → 应用文件 B 并逐包反查 →
编译 → `verify-image.sh` → 发 Release。

细节（每道门禁证明什么、失败怎么处理）见 [docs/CI_BUILD.md](docs/CI_BUILD.md)。
截至 2026-10-25，两个 workflow 都已跑通：装配 run `40183767687` 发布 `sources-v3`（恰好
3 个资产），构建 run `40185702727` 用 `source_tag=auto` 选中它并全量 PASS，发布
`v16-1-5dda9f3b`（恰好 3 个固件资产）。**这只证明编译、静态镜像校验与打包通过；镜像在
真机上的启动、升级与以太网行为仍为 `NOT TESTED`。**（2026-11-16 更新：v94 已补齐真机
刷写与验证记录，见上文「升级」一节与
[docs/V94_FIELD_VERIFICATION-2026-11-16.md](docs/V94_FIELD_VERIFICATION-2026-11-16.md)。）

## 注意

- `files/` 由 `include/image.mk` 原样复制进 rootfs，**不经过** `VERSION_SED_SCRIPT`，
  所以 banner 里的 `%V`/`%R` 必须由 `render-overlay.sh` 在构建前替换。
- `/etc/rc.d/S95wireless-defaults`、`/etc/rc.d/S15ethernet-macs`、
  `/etc/rc.d/S23eth0-lan-attach` 等开机链接由
  `include/rootfs.mk` 的 `prepare_rootfs` 自动生成，条件是 `etc/init.d/<名>`
  首行**精确**为 `#!/bin/sh /etc/rc.common` 且权限 0755。
- `build/p-b/files/` 下的任何增删改（包括只是几个脚本）都会同时改变
  `recipe_sha256` 和目标 base-files 树的指纹：新文件要对 `known-delta.conf`
  登记（并在装配脚本里断言），然后必须重发 `sources-vN`，否则构建会停在
  `Verify recipe hash` 门禁。`build/p-b/files/base-files` 不在“改 overlay
  不用重装源码”的豁免范围内——那个豁免只覆盖 `24.10-6.6/files/`。
- `/etc/uci-defaults/*` 由 `/etc/init.d/boot` 以 `( . file )`（子 shell 内 source）
  加载，成功才删除、失败保留到下次开机重试。本仓库的约定仍是不用 `set -e`，退出
  一律显式写：overlay 里的入口用调用脚本的返回码，包内脚本（如
  `sbe1v1k-defaults`）用 `exit 0` / `exit 1` 表达“已应用”/“保留重试”。
- 构建与校验过程不接触任何设备；产物未经真机验证前记为 `UNVERIFIED`。
- 全锥形 NAT：2026-11-15 评估结论为**不做**（fw4 无支持、内核模块与 fw4 补丁
  都要外挂且参考实现已停更、与 NSS/ECM 加速的兼容性未验证；UPnP IGD 已覆盖
  大部分场景），详见
  [docs/FULLCONE_NAT_EVAL-2026-11-15.md](docs/FULLCONE_NAT_EVAL-2026-11-15.md)。
