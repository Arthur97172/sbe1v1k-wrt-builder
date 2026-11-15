# 全锥形 NAT（Full Cone NAT）评估与决定

日期：2026-11-15
对象：24.10-6.6（OpenWrt 24.10-SNAPSHOT + QSDK 14.0，IPQ9574，Linux 6.6）
性质：纯静态评估与生态核实，不涉及设备操作。

## 0. 决定

**不做。** 24.10-6.6 不引入全锥形 NAT：不新增内核模块、不补 firewall4、
不改 turboacc，镜像与配置保持现状。

理由摘要：真实受益面窄且大部分已被镜像内已有的 UPnP IGD 覆盖；实现必须外挂
两个上游已停更的组件（`nft_fullcone` 内核模块 + fw4 补丁），并承担与 NSS/ECM
硬件加速的未验证兼容性；默认开启还会主动削弱 NAT 的边界防护。若日后出现具体
需求，按 §5 的触发条件重新评估。

## 1. 平台事实（已核实）

### 1.1 数据面结构：全锥形只能在 netfilter 层做

NAT 由 Linux conntrack + nftables（fw4）完成。QSDK 的 NSS/ECM 只把 conntrack
中**已经存在**的会话下推到 PPE 硬件加速，任何新流量的首包都走软件栈。因此
"全锥形"的语义（入站映射对任意外部源可达）必须在 netfilter 实现，硬件加速
只影响已建立会话的吞吐。

### 1.2 firewall4 没有全锥形支持

- 本树 24.10 使用的 firewall4 版本为 `2024.12.18`（`package/network/config/firewall4`
  的 `PKG_SOURCE_DATE`）。构建产物
  `build_dir/target-aarch64_cortex-a73+neon-vfpv4_musl/firewall4-2024.12.18~18fc0ead/root/usr/share/ucode/fw4.uc`
  （3386 行）全文检索无 `cone`、无 `fullcone` 选项；`masq`/`snat`/`dnat`/`npt`
  之外没有任何 NAT 类型相关的开关。
- 同日核对了上游 `openwrt/firewall4` master 的同一文件：同样没有。
- 25.12 树使用的 firewall4（`PKG_SOURCE_DATE 2025-03-17`）也没有——这不是
  版本落后，而是上游从未合入。
- 社区唯一的 fw4 全锥形分支 `fullcone-nat-nftables/openwrt-firewall4-with-fullcone`
  已于 2024-03-07 归档为只读，不再维护。

### 1.3 内核与 feed 里没有现成模块

- `target/linux` 全树没有任何 fullcone/full_cone 相关补丁。
- 本构建使用的 QSDK packages feed（`buildroot/qca/feeds/packages`）的 `kernel/`
  目录只有 5 个包：`macremapper`、`mdio-netlink`、`mtd-rw`、`ovpn-dco`、
  `v4l2loopback`，没有 `kmod-nft-fullcone`。

### 1.4 QSDK 的"硬件全锥形"是纸面特性

SSDK 里确实存在硬件 NAPT 模式寄存器：

- `qca/src/nss/base/qca-ssdk/include/fal/fal_nat.h:125`：枚举
  `FAL_NAPT_FULL_CONE = 0`（另有 STRICT_CONE / PORT_STRICT / SYNMETRIC）；
- `qca/src/nss/base/qca-ssdk/src/hsl/isisc/isisc_nat.c:1258` 起：把模式写入
  `NAT_CTRL` 的 `NAPT_MODE` 字段，寄存器值 0 即映射为 full-cone（默认值）；
- `qca/src/nss/base/qca-ssdk/src/shell_lib/shell_config.c:517`：shell 提供
  `ssdk_sh nat naptmode set <fullcone|strictcone|portstrict|synmatric>`。

但是：该寄存器属于芯片内交换/NAT 硬件块，**本平台没有任何初始化路径打开这个
NAT 块（NAPT_EN）**，NSS/PPE/ECM 的数据面也不使用它。它不构成可用的全锥形实现，
不能作为"开个开关就行"的依据。

### 1.5 镜像里已有的替代手段

- `miniupnpd-nftables`：seed 已选（`build/config-seed/ipq95xx-spectrum-sbe1v1k.seed`
  第 200 行），支持 UPnP IGD / NAT-PMP / PCP，默认 `enabled=0`，可在 LuCI 打开。
- `luci-app-turboacc`：已在 `build/custom-packages.conf`（2026-11-13 加入）。
  `sources/apps/luci-app-turboacc/root/usr/share/ucode/turboacc/core.uc:105-106`
  会解析 `/usr/share/ucode/fw4.uc` 探测 `fullcone`/`fullcone6` 选项，
  `core.uc:221-224` 再探测 `nft_fullcone` 模块与 `nft -c` 干跑 `fullcone` 语句；
  系统不支持时界面不显示该开关，且会自动回落到可用引擎。**换句话说：将来系统侧
  补齐后，turboacc 前端零改动即可获得该选项。**
- 静态端口转发与 IPv6（ISP 有 v6 时无 NAT）。

### 1.6 当前 NAT 行为

Linux conntrack 的 masquerade 是 endpoint-dependent 映射（按目的端点区分），
对外表现为近似对称/端口受限 NAT：游戏机常报 NAT 类型 2/3，P2P 上报受限。
这正是全锥形想改变的行为。

## 2. 需求盘点

| 场景 | 全锥形是否有效 | 现有替代 |
|---|---|---|
| 主机游戏 "Open NAT"（PSN/Xbox/Switch） | 有效；多数游戏 UPnP 已能到"中等"以上 | UPnP IGD（已带） |
| BT/PT、PCDN 打洞 | 有限；对端也在 NAT 后时无效 | UPnP + 端口转发 |
| 远程游玩、WebRTC、部分 IM 直连 | 有效 | 端口转发 / IPv6 |
| 普通上网、流媒体 | 无效（无收益） | — |
| 上游是 CGNAT | **无效**（ISP 那层仍是严格 NAT） | 无 |

结论：收益集中在少数 P2P/游戏场景，其中大部分已有更安全、更标准的 UPnP；
IPv6 普及后该类需求继续下降。

## 3. 若实现的代价与风险

| 项 | 内容 |
|---|---|
| 内核模块 | `nft_fullcone`（Chion82/netfilter-full-cone-nat）为 out-of-tree 模块，需按 6.6.147 + QSDK 补丁集移植与验证 |
| fw4 补丁 | 上游无支持；参考实现已停更，fw4 每次升级都要处理冲突。替代做法是用 `/etc/nftables.d` + `config include` 注入规则，绕过选项表，但同样不在上游保障范围内 |
| 硬件加速 | 与 ECM/PPE offload 的相互作用未验证；最坏情况需关闭 WAN 侧加速，牺牲本平台的主要价值 |
| 安全 | 全锥形使内网主机在映射端口上对任意外部源可达，削弱 NAT 的边界作用；默认开启不合适 |
| 无效场景 | CGNAT 上游、IPv6 直连 |

不建议的路径：调 SSDK 的 `naptmode` 寄存器（见 §1.4，无证据影响数据面）；
回到 iptables/fw3 + `xt_FULLCONENAT`（与 24.10 的 fw4/nftables 架构冲突，
等于整体回退）。

## 4. 结论

在 24.10-6.6 上支持全锥形 NAT **没有必要**：

1. 需求面窄，且镜像内已有 UPnP IGD/NAT-PMP/PCP 与端口转发覆盖大部分场景；
2. 实现要外挂两个停更组件，并长期承担 fw4 补丁的维护成本；
3. 与 NSS/ECM 硬件加速的兼容性未验证，风险落在本平台最重要的能力上；
4. 默认开启有明确的安全代价。

## 5. 日后重新评估的触发条件与形态

- 触发：用户出现具体需求（PCDN、主机游戏、远程游玩），且 UPnP 实测无法满足。
- 形态：可选功能、默认关；复用 turboacc 现有的能力探测与回退框架（§1.5），
  先只支持软件加速路径；附真机测试矩阵（10G/2.5G/1G 口、IPv4/IPv6、
  ECM 开/关）。
- 在那之前不改任何代码。

## 6. 状态词

- §1 的静态事实：PASS（本地树核实，含一次上游 raw 文件核对）。
- 设备侧行为：NOT TESTED（本次不涉及设备操作）。
