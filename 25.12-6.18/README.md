# 25.12-6.18 — OpenWrt main（Linux 6.18）的 SBE1V1K 基线

本目录是 SBE1V1K（Askey RTQ7300T / Spectrum SBE1V1K，ipq9574）在 Linux 6.18
上的固件树。它与 `25.12-6.12/` 平级、各自独立装配，区别只在基线选择：

| | 25.12-6.12 | 25.12-6.18 |
|---|---|---|
| 上游 | `openwrt-25.12` 分支，6.12 | `main`，`KERNEL_PATCHVER:=6.18` |
| 设备定义 | 本项目的 `spectrum_sbe1v1k`（补丁） | 上游原生 `askey_sbe1v1k` |
| 数据通路 | QSDK NSS（qca-ssdk/dp/ppe/ecm） | QSDK NSS（补丁 0032 原地切换设备定义，单设备、无 `-nss` 后缀） |
| 无线固件 | 项目打包的厂商 blob（QCN92XX/hw1.0） | 上游 ath12k 固件 + `ipq-wifi-askey_sbe1v1k`，校准从 `0:ART` 提取 |
| 网口角色 | eth1（2.5G）=WAN，其余=LAN | 相同：port@5（2.5G）=WAN，port@3/4/6=LAN（补丁 0001） |
| 项目 overlay | `files/` + 多个补丁 | 分阶段移植（S2/S4） |

> 为什么用 `main` 而不是 `openwrt-25.12`：6.18 只存在于 `main`（25.12 分支的
> qualcommbe 是 6.12）。`main` 对本板是原生支持——设备定义、eMMC 升级
> （`0:HLOS`/`rootfs`/`rootfs_data`）、PWM 风扇/LED、RTL8261N、ath12k BDF 与
> 校准提取脚本都在上游树里。本树只加一个网口角色补丁（见下），其余保持上游。

## 当前状态（2026-11-24）

- 用户目标：**功能对齐 25.12-6.12**——包括 NSS 加速栈、tier/nss-load、项目
  overlay 与插件；同时复用 6.12 的全部踩坑结论
  （`docs/LESSONS-FROM-6.12.md`）。
- 分阶段推进（`docs/PLAN-2026-11-22.md`）：S1 上游基线构建 → S1b 真机启动 →
  S2 overlay → S3 NSS 移植 → S4 插件/档位 → S5 CI。
- 网口角色与 6.12 一致：**2.5G（QCA8081）= WAN**，10G 与两个 1G = LAN。
  上游 DTS 默认相反，本树用 `patches/0001-...swap-port5-port6-labels` 修正。
- Stage 1（上游基线）：2026-11-22 本机构建 world PASS，`verify-image.sh`
  12 项 PASS（含镜像 apk 数据库按 required 清单反查 107/0/0）。
- **S1b 真机（2026-11-22，B 机）PASS**：`sysupgrade -F -n` 刷入后 6.18.64
  正常启动（root=p27，overlay=独立 p29），网口角色与 6.12 一致（2.5G=WAN、
  10G/1G=LAN）、LAN→WAN NAT 通、LuCI 200、风扇/LED 正常；2.4G/5G AP 正常
  （6G 当时因固件 regdb 未启用信道不可用，S3d 起三频含 6G 已真机 PASS）。详见
  `docs/S1B-DEVICE-TEST-2026-11-22.md`；重启复验待批准。
- 插件栈（2026-11-22 按用户要求对齐 25.12-6.12）：18 个插件（2026-11-28
  增至 19，加入 `luci-app-fileassistant`）、官方 LuCI 页/WireGuard、工具与
  运行时全部写入种子与 `build/thirdparty-pins.conf`；`fetch-plugins.sh
  --dry-run` 当时 18 个仓库全部 same、`check-packages.sh seed` 107 项 PASS。与 6.12 的差异只在 `sbe-wifi-firmware`（6.18 用上游固件）；
  QSDK 组件从 S3d 起随镜像提供（见下条）。
- 首启默认（S2 先行移植，2026-11-22 按用户要求）：`files/etc/uci-defaults/`
  里的 `99-allow-luci-wan`（WAN tcp 80/443 ACCEPT）与 `99-allow-ssh-wan`
  （WAN tcp 22 ACCEPT），语义与 6.12 的 `sbe1v1k-defaults` 相同；脚本按 755
  安装（uci-defaults 只 source 不看权限位，断言 755 是为了让权限位丢失时
  静态检查直接失败）。`verify-image.sh` 断言两脚本在镜像中。**注意：root
  空密码时 `Allow-SSH-WAN` 等于把免密登录开给整个上游网段，必须配套设密码。**
  **真机 PASS（2026-11-22，B 机）**：`sysupgrade -n` 后首启生成两段规则，
  从上游网段 `nc`/`ssh`/`curl` 验证 22/80/443 可达、8080 仍拒绝、计数器增长；
  详见 `docs/S2-WAN-RULES-DEVICE-TEST-2026-11-22.md`。
- S2 第二批（2026-11-22，按用户要求对齐 6.12，**设备 NOT TESTED**）：
  - 自定义 banner：`files/etc/banner` 由 `scripts/render-overlay.sh` 在构建前
    替换 `%V/%R`（OpenWrt 的 files overlay 不经过 version.mk 的 sed），版本行
    形如 `Version: 25.12-SNAPSHOT (sbe1v1k-6.18-…)`；渲染失败即构建失败。
  - 无线默认值：`files/usr/lib/sbe1v1k/wireless-defaults` + 首启入口
    `99-wireless-defaults` + `/etc/init.d/wireless-defaults` 与
    `files/etc/rc.d/S95wireless-defaults`（符号链接随仓库提交；6.12 里这个
    链接只出现在旧的构建产物目录，属历史遗留）。默认 US、2.4G ch11 EHT20、
    5G ch40 EHT80、6G ch37 EHT320、SSID `WiFi_2.4G/5G/6G`、SAE 口令
    `12345678`；板名门控同时接受 `askey,sbe1v1k` 与 `spectrum,sbe1v1k`；
    基址 MAC 扫描同时覆盖 6.18 的 `lan*/wan` 与 6.12 的 `eth*`。
    6G 在固件 regdb 无可用信道时由 `repair_6g_availability` 保持禁用。
  - 时区默认：`files/etc/uci-defaults/99-system-timezone`（Asia/Taipei，
    仅当当前值为空或 UTC 时写入）。
  - 补丁 `0002-wifi-scripts-pin-radio-numbering-by-band.patch`：射频号按频段
    固定（2G=radio0、5G=radio1、6G=radio2），不再随 ath12k 探测顺序变化。
  - 补丁 `0003-qualcommbe-sbe1v1k-distinct-mac-per-port.patch`：上游 DTS 把
    lan2/lan3/wan 都设为 `&ethaddr 1`（`mac-base` 的 cell 索引即基址偏移，
    三口的 MAC 完全相撞），改为 lan2=`&ethaddr 2`、lan3=`&ethaddr 3`，
    wan 保持 `&ethaddr 1`、lan1 保持 `&ethaddr 0`。
  - `verify-image.sh` 新增上述 overlay、banner 版本行、无线默认值、自愈函数、
    板名门控、rc.d 链接、时区脚本断言；本机构建 PASS，**PASS=36 FAIL=0**。
    镜像哈希与内容级取证见 `docs/S2-BANNER-WIFI-2026-11-22.md`（设备
    **NOT TESTED**）。
- **S3d NSS 数据通路**（2026-11-24 起成为唯一数据通路）：补丁 0031 的 DTB
  `/delete-node/ &qcom_ppe;` 换 ess-switch/EDMA/dp，补丁 0032 把上游
  `Device/askey_sbe1v1k` 原地切到该 DTB 并加入 QSDK 包。原先并列的
  mainline PPE 兜底变体（设备名 `askey_sbe1v1k-nss`）已退役：一次 world
  只产一套镜像，文件名不带 `-nss` 后缀。**mainline 变体 2026-11-23 真机
  PASS**（启动、网口角色、三频 AP（含 6G）、LuCI、风扇时区；两项缺陷已修，
  见 `docs/S3D-DEVICE-TEST-2026-11-23.md`）。**S3e 有线数据面修复已真机
  PASS**（PCS 时钟、MDIO 复位、复位所有权，见
  `docs/WIRED-DATAPATH-DEVICE-TEST-2026-11-23.md` §1–§7），并移植了
  S95 eth0 AN 看门狗。
- **S4（2026-11-24，NSS 数据通路真机 PASS）**：`files/etc/nss.conf` 默认
  `tier=full`（保留 `fallback=wired`、`budget=3`），启动自动装载
  sdk/dp/ppe 全家/ecm；补丁 0041：蓝灯 `default-state="on"`
  常亮、NSS dp1–dp4 挂 ART `ethaddr` 0–3 使 MAC 跨启动固定（上游看到的
  WAN MAC 不再漂移）。热重启 3 轮 + 断电冷启动均 PASS，详见
  `docs/WIRED-DATAPATH-DEVICE-TEST-2026-11-23.md` §8。
  6.18 的板级 DTB 没有任何 `ethernetN` 别名，APPSBL 的
  `fdt_fixup_ethernet()` 因此不会注入 env MAC（24.10 / 25.12-6.12 曾因
  `ethernet1..3` 别名把同一个 env MAC 写进 dp2–dp4，见各自的 MAC 小节）；
  这里的 MAC 来源只有 nvmem `&ethaddr` 0–3，互不相同。
- CI（S5，2026-11-24 起含内核检测）：`.github/workflows/build-25.12-6.18.yml`
  与 `build-25.12-6.12.yml` 同结构——prepare 装配（含 19 插件）、
  `check-kernel.sh` 内核漂移报告（只报告，不改 pin）、configure 三道包反查、
  `build-images.sh world` 单次构建、`verify-image.sh` 单镜像静态校验、
  发布 3 个资产（sysupgrade / factory / initramfs）到本次运行专属 Release
  （notes 含插件实际提交表与内核检测结论）；`plugin_mode` 可选手动触发时
  用 `pinned` 复现旧镜像。运行结果以 Actions 页为准。
- 任何刷机、重启、连接路由器或远程验证都需要用户单独批准。

## 目录

```
25.12-6.18/
├── build/
│   ├── config-seed/ipq95xx-askey-sbe1v1k.seed   # 目标/设备/LuCI/插件选择
│   ├── required-packages.txt                    # 必装/可选/必禁唯一清单
│   ├── thirdparty-pins.conf                     # 19 个插件的仓库与 pin
│   └── sbe1v1k-build.sh                         # make 包装（定位装配树）
├── docs/
│   ├── PLAN-2026-11-22.md                       # 阶段计划与判据
│   └── LESSONS-FROM-6.12.md                     # 6.12 踩坑 → 6.18 检查项
├── files/                                       # 项目 overlay（渲染进镜像）
│   ├── etc/banner                               # %V/%R 由 render-overlay.sh 替换
│   ├── etc/init.d/wireless-defaults             # 开机无线策略
│   ├── etc/rc.d/S95wireless-defaults            # -> ../init.d/wireless-defaults
│   ├── etc/uci-defaults/                        # 首启：WAN 放行、ttyd、时区、无线
│   └── usr/lib/sbe1v1k/wireless-defaults        # 无线策略实现（与 6.12 同源）
├── patches/                                     # 装配时整链重放、可重复（0001–0042）
│   ├── 0001-qualcommbe-sbe1v1k-swap-port5-port6-labels.patch
│   ├── 0002-wifi-scripts-pin-radio-numbering-by-band.patch
│   ├── 0003-qualcommbe-sbe1v1k-distinct-mac-per-port.patch
│   ├── 0031-qualcommbe-add-sbe1v1k-nss-dts.patch     # NSS 板级 DTS（删 mainline PPE 节点）
│   ├── 0032-qualcommbe-sbe1v1k-use-nss-device.patch  # 原地切换设备定义（DTS + QSDK 包）
│   ├── 0033-qualcommbe-ipq95xx-nss-board-network.patch # 02_network 按设备树分支
│   ├── 0034-qualcommbe-qca808x-drop-qca8084-for-nss.patch # 6.18 内置 qca8084 抢名
│   ├── 0036..0040-*                                  # PCS 时钟、MDIO 复位、看门狗、reset 所有权
│   ├── 0041-qualcommbe-sbe1v1k-blue-led-and-dp-mac.patch # 蓝灯常亮 + dp 口 MAC 固定
│   └── 0042-luci-version-drop-detached-head.patch  # 概览版本串去掉 detached HEAD 伪分支
└── scripts/
    ├── ci/prepare-tree.sh                       # 克隆 main + 钉 feed + 插件装配
    ├── ci/fetch-plugins.sh                      # 19 插件按最新 tag 安装
    ├── ci/check-kernel.sh                       # 6.18 内核漂移报告（只读）
    ├── ci/check-packages.sh                     # seed/index/config/db 反查
    ├── ci/build-images.sh                       # 单设备一次 make（NSS 唯一通路）
    ├── ci/verify-image.sh                       # 单镜像静态校验 + 包反查
    ├── render-overlay.sh                        # files/ → 装配树 + banner 版本替换
    └── local/build-image.sh                     # 本地构建入口（走 build-images.sh）
```

## 插件与构建时跟新

插件源码不在 feed 里：`prepare-tree.sh` 的 `feeds install -a` 之后调用
`scripts/ci/fetch-plugins.sh`，按 `build/thirdparty-pins.conf` 解析各仓库
最新版本 tag（无版本 tag 取默认分支头）；只有新提交是 pin 的后代才采用，
分叉/回退/远端不可达保持 pin（不中断构建）。实际提交写进
`<装配树>/.sbe-plugins.tsv`，构建过程只读本文件；每周的 `refresh-pins.yml`
用 `fetch-plugins.sh --update-pins` 前移 pinned 列，经 PR 提交、不自动合并。

- 复现旧镜像：`SBE_PLUGIN_MODE=pinned`（全部按清单 pin）。
- 严格模式：`SBE_PLUGIN_STRICT=1` 时 stale/diverged/unknown 直接失败。
- 8 个第三方仓库统一 `LICENSE_REVIEW_REQUIRED`；不写 `luci-app-argon-config`
  （v3 起设置页并入主题包，空迁移包已由脚本删除）。
- `build/required-packages.txt` 是必装/可选/必禁的唯一来源，
  `check-packages.sh` 在 seed、defconfig 结果与镜像 apk 数据库三处反查；
  上游改名/删包会在 defconfig 后立刻指名失败，不会静默少包。

**MESH 助手的有线回程（eth0，design B，2026-11-28）。** 与 6.12 同实现：
`luci-app-meshassistant` ≥ 2.9.0 把 board.json 声明为 LAN、但不在 br-lan
`ports` 里的 eth0 收进「有线回程端口」下拉，选中后在 netifd 之外把它挂到
`bat0`（`batctl meshif bat0 interface -M add eth0`，取消时 `-M del` 并挂回
br-lan），不写 UCI 接口。固件侧：`eth0-lan-attach` 三个入口遇到
`master=bat0` 直接停手；`sbe-port-roles` 在 eth0 是 bat0 hardif 时拒绝
`set eth0`/`none`、`live` 与开机收敛，提示先在插件里取消回程（`status`
打印该状态）。6.18 用主线 rtl8261n，无 RTL8261N 假环回问题，该守卫只为
避免抢桥/切断回程。插件侧细节见 6.12 README 同名段。静态检查 PASS；
真机 NOT TESTED。

## 构建（本机）

```sh
cd /home/arthur/claude/sbe1v1k-build
SBE_CI=1 25.12-6.18/scripts/ci/prepare-tree.sh      # 一次性装配
25.12-6.18/scripts/local/build-image.sh world       # 编译 + 校验
```

本树只有一个设备（`askey_sbe1v1k`，数据通路固定为 NSS）；种子选中它之后
`local/build-image.sh` 调用 `scripts/ci/build-images.sh`，一次 world 出全套
镜像，defconfig 后断言设备选择真的生效、已退役的 `askey_sbe1v1k-nss` 符号
没有回归。

本机网络有两个已知坑（CI 不受影响）：`cdn.kernel.org`/`ftp.gnu.org` 等镜像
会挂死（`download.pl` 等的 curl 永不超时），`proxy.golang.org` 会被代理重置。
本地构建时带上：

```sh
DOWNLOAD_MIRROR=https://sources.openwrt.org \
GOPROXY='https://goproxy.cn,https://mirrors.aliyun.com/goproxy,direct' \
25.12-6.18/scripts/local/build-image.sh world
```

`DOWNLOAD_MIRROR` 让 `download.pl` 先试 sources.openwrt.org（唯一可达的源站
镜像）；Go 包（xray-core/sing-box/yq 等）的模块下载走 goproxy.cn。

装配树落在 `sources/buildroot-25.12-6.18/`，产物在
`bin/targets/qualcommbe/ipq95xx/`（文件名带上游版本前缀，均含
`askey_sbe1v1k`，不带 `-nss` 后缀）。

## 固定版本

- OpenWrt：`OPENWRT_SHA=0e66e1c7457a6a92d851c23cd47f7c6f69a7455a`（main，
  2026-11-22 时的设备定义/EmmcImage/平台脚本形态）
- feeds（tags/branch 均 override 自 `prepare-tree.sh` 的 `feed_sha()`）：
  packages `be0dbb6e`、luci `f7675c07`、routing `ea8633da`、telephony
  `06feffc2`、video `6a3b5fd6`

升级任何 pin 前先在本地完整构建 + 静态校验通过，再单独提交。

## 产物与验证

`verify-image.sh` 对**单一镜像**断言：sysupgrade tar 含 `kernel`/`root`；
FIT 里嵌着 `Spectrum SBE1V1K` / `askey,sbe1v1k` / `config@rtq7300t-rev0`；
数据通路为 NSS——FIT 不含 `qcom,ipq9574-ppe` 节点而含
`qcom,ess-switch-ipq95xx`/`qcom,nss-dp`；root 是 squashfs；`openwrt_release`
目标为 `qualcommbe/ipq95xx`；解包后的 apk 数据库按 `build/required-packages.txt`
逐包反查（插件、工具、NSS 模块、必禁项），并校验 NSS overlay（`nss-board`
判据、`nss.conf`、装载/角色脚本与 rc.d 链接、`nss-board || exit 0` 门控）。
设备侧：启动、网口角色、LAN→WAN 转发、LuCI、风扇/LED、2.4G/5G 已在 B 机
S1b 验证（`docs/S1B-DEVICE-TEST-2026-11-22.md`）；6G 信道未启用。NSS 数据面
有线：D1（LAN PHY 绑定）/D2（2.5G WAN）已真机 PASS，D3（10G 口
USXGMII AN）在补丁 0040 后回到概率性坏启动，由 S95 看门狗兜底，见
`docs/WIRED-DATAPATH-DEVICE-TEST-2026-11-23.md`。重启复验与 WiFi 客户端
关联未做。

### eth0 AN 看门狗（S95，移植自 6.12）

`files/etc/init.d/sbe-eth0-an-watchdog` + `files/usr/sbin/sbe-eth0-an-watchdog`
只作用于 NSS 数据通路（`nss-board` 门控；本树现在只有这一条）且 eth0 有
载波时：等 eth0 出载波后三次采样 uniphy2 `VR_MII_AN_INTR_STS`（0x1f8002），
usxg_an_sts 恒 0 即判 USXGMII AN 死锁，自动重启一次；
`/etc/sbe-eth0-an-watchdog.count` 防重启循环（默认 `max_reboots='1'`，正常
启动清零）。配置在 `/etc/config/sbe_eth0_watchdog`，设 `enabled '0'` 可关闭。
门控不满足（设备树没有 NSS 数据通路）时 worker 直接退出。

## 规则

沿用项目根 `CLAUDE.md`：不把密码写入任何文件/脚本/命令行；未经批准不连接、
不扫描、不刷写设备。固件源码与产物可以推 GitHub；厂商 blob 一律不入库。
