# 25.12-6.18 — OpenWrt main（Linux 6.18）的 SBE1V1K 基线

本目录是 SBE1V1K（Askey RTQ7300T / Spectrum SBE1V1K，ipq9574）在 Linux 6.18
上的固件树。它与 `25.12-6.12/` 平级、各自独立装配，区别只在基线选择：

| | 25.12-6.12 | 25.12-6.18 |
|---|---|---|
| 上游 | `openwrt-25.12` 分支，6.12 | `main`，`KERNEL_PATCHVER:=6.18` |
| 设备定义 | 本项目的 `spectrum_sbe1v1k`（补丁） | 上游原生 `askey_sbe1v1k` |
| 数据通路 | QSDK NSS（qca-ssdk/dp/ppe/ecm） | 两个设备变体：mainline PPE（兜底）+ QSDK NSS（`-nss`，S3d） |
| 无线固件 | 项目打包的厂商 blob（QCN92XX/hw1.0） | 上游 ath12k 固件 + `ipq-wifi-askey_sbe1v1k`，校准从 `0:ART` 提取 |
| 网口角色 | eth1（2.5G）=WAN，其余=LAN | 相同：port@5（2.5G）=WAN，port@3/4/6=LAN（补丁 0001） |
| 项目 overlay | `files/` + 多个补丁 | 分阶段移植（S2/S4） |

> 为什么用 `main` 而不是 `openwrt-25.12`：6.18 只存在于 `main`（25.12 分支的
> qualcommbe 是 6.12）。`main` 对本板是原生支持——设备定义、eMMC 升级
> （`0:HLOS`/`rootfs`/`rootfs_data`）、PWM 风扇/LED、RTL8261N、ath12k BDF 与
> 校准提取脚本都在上游树里。本树只加一个网口角色补丁（见下），其余保持上游。

## 当前状态（2026-11-22）

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
  10G/1G=LAN）、LAN→WAN NAT 通、LuCI 200、风扇/LED 正常；2.4G/5G AP 正常，
  **6G 因固件 regdb 未启用信道暂不可用**（S2/S3 处理）。详见
  `docs/S1B-DEVICE-TEST-2026-11-22.md`；重启复验待批准。
- 插件栈（2026-11-22 按用户要求对齐 25.12-6.12）：18 个插件、官方 LuCI
  页/WireGuard、工具与运行时全部写入种子与 `build/thirdparty-pins.conf`；
  `fetch-plugins.sh --dry-run` 18 个仓库全部 same、`check-packages.sh seed`
  107 项 PASS。与 6.12 的差异只在 `sbe-wifi-firmware`（6.18 用上游固件）；
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
- **S3d NSS 数据通路（2026-11-23 本机构建 PASS，设备 NOT TESTED）**：
  两个设备变体——mainline PPE（无后缀，兜底）与 QSDK NSS（`-nss`，补丁
  0031 的 DTB `/delete-node/ &qcom_ppe;` 换 ess-switch/EDMA/dp）。kconfig
  choice 一次只能选一个设备，`scripts/ci/build-images.sh` 顺序跑两遍；
  `verify-image.sh` 对两镜像各自断言，**PASS=128 FAIL=0**（包反查各
  119/0/0）。详见 `docs/NSS-PORT-ASSESSMENT-2026-11-22.md` §5；设备侧
  （nss-load、`/sys/ssdk`、加速计数）留 S3e，需单独批准。
- CI（S5，2026-11-22）：`.github/workflows/build-25.12-6.18.yml` 与
  `build-25.12-6.12.yml` 同结构——prepare 装配（含 18 插件）、configure
  三道包反查、`build-images.sh world` 两遍构建、`verify-image.sh` 双镜像
  静态校验、发布 6 个资产（两变体各 3 个）到本次运行专属 Release；
  `plugin_mode` 可选手动触发时用 `pinned` 复现旧镜像。
  首次运行结果以 Actions 页为准。
- 任何刷机、重启、连接路由器或远程验证都需要用户单独批准。

## 目录

```
25.12-6.18/
├── build/
│   ├── config-seed/ipq95xx-askey-sbe1v1k.seed   # 目标/设备/LuCI/插件选择
│   ├── required-packages.txt                    # 必装/可选/必禁唯一清单
│   ├── thirdparty-pins.conf                     # 18 个插件的仓库与 pin
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
├── patches/                                     # 装配时按序应用、可重复
│   ├── 0001-qualcommbe-sbe1v1k-swap-port5-port6-labels.patch
│   ├── 0002-wifi-scripts-pin-radio-numbering-by-band.patch
│   ├── 0003-qualcommbe-sbe1v1k-distinct-mac-per-port.patch
│   ├── 0031-qualcommbe-add-sbe1v1k-nss-dts.patch     # NSS 板级 DTS（删 mainline PPE 节点）
│   ├── 0032-qualcommbe-add-sbe1v1k-nss-device.patch  # NSS 设备定义与 DEVICE_PACKAGES
│   ├── 0033-qualcommbe-ipq95xx-nss-board-network.patch # 02_network 按设备树分支
│   └── 0034-qualcommbe-qca808x-drop-qca8084-for-nss.patch # 6.18 内置 qca8084 抢名
└── scripts/
    ├── ci/prepare-tree.sh                       # 克隆 main + 钉 feed + 插件装配
    ├── ci/fetch-plugins.sh                      # 18 插件按最新 tag 安装
    ├── ci/check-packages.sh                     # seed/index/config/db 反查
    ├── ci/build-images.sh                       # 两个设备顺序各跑一遍 make
    ├── ci/verify-image.sh                       # 两镜像各自静态校验 + 包反查
    ├── render-overlay.sh                        # files/ → 装配树 + banner 版本替换
    └── local/build-image.sh                     # 本地构建入口（走 build-images.sh）
```

## 插件与构建时跟新

插件源码不在 feed 里：`prepare-tree.sh` 的 `feeds install -a` 之后调用
`scripts/ci/fetch-plugins.sh`，按 `build/thirdparty-pins.conf` 解析各仓库
最新版本 tag（无版本 tag 取默认分支头）；只有新提交是 pin 的后代才采用，
分叉/回退/远端不可达保持 pin（不中断构建）。实际提交写进
`<装配树>/.sbe-plugins.tsv`，本文件从不被构建改写。

- 复现旧镜像：`SBE_PLUGIN_MODE=pinned`（全部按清单 pin）。
- 严格模式：`SBE_PLUGIN_STRICT=1` 时 stale/diverged/unknown 直接失败。
- 8 个第三方仓库统一 `LICENSE_REVIEW_REQUIRED`；不写 `luci-app-argon-config`
  （v3 起设置页并入主题包，空迁移包已由脚本删除）。
- `build/required-packages.txt` 是必装/可选/必禁的唯一来源，
  `check-packages.sh` 在 seed、defconfig 结果与镜像 apk 数据库三处反查；
  上游改名/删包会在 defconfig 后立刻指名失败，不会静默少包。

## 构建（本机）

```sh
cd /home/arthur/claude/sbe1v1k-build
SBE_CI=1 25.12-6.18/scripts/ci/prepare-tree.sh      # 一次性装配
25.12-6.18/scripts/local/build-image.sh world       # 两个设备各编一遍 + 校验
```

设备变体是 kconfig choice：一次 world 只出一个设备，两个都写 `=y` 时后者
静默覆盖前者。`local/build-image.sh` 因此调用 `scripts/ci/build-images.sh`，
**先 NSS、后 mainline 顺序跑两遍**，每遍 defconfig 后断言设备选择真的生效；
第二遍基本增量（包都已编过，只重出 DTB/FIT 与镜像）。种子默认选中 NSS，
单独跑 make 时也以 NSS 为准。

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
`askey_sbe1v1k`；NSS 变体带 `-nss` 后缀）。

## 固定版本

- OpenWrt：`OPENWRT_SHA=0e66e1c7457a6a92d851c23cd47f7c6f69a7455a`（main，
  2026-11-22 时的设备定义/EmmcImage/平台脚本形态）
- feeds（tags/branch 均 override 自 `prepare-tree.sh` 的 `feed_sha()`）：
  packages `be0dbb6e`、luci `f7675c07`、routing `ea8633da`、telephony
  `06feffc2`、video `6a3b5fd6`

升级任何 pin 前先在本地完整构建 + 静态校验通过，再单独提交。

## 产物与验证

`verify-image.sh` 对**两个镜像各自断言**：sysupgrade tar 含 `kernel`/`root`；
FIT 里嵌着 `Spectrum SBE1V1K` / `askey,sbe1v1k` / `config@rtq7300t-rev0`；
数据通路按 FIT 判别——mainline 含 `qcom,ipq9574-ppe`，NSS 不含该节点而含
`qcom,ess-switch-ipq95xx`/`qcom,nss-dp`；root 是 squashfs；`openwrt_release`
目标为 `qualcommbe/ipq95xx`；解包后的 apk 数据库按 `build/required-packages.txt`
逐包反查（插件、工具、NSS 模块、必禁项），并校验 NSS overlay（`nss-board`
判据、`nss.conf`、装载/角色脚本与 rc.d 链接、`nss-board || exit 0` 门控）。
设备侧：启动、网口角色、LAN→WAN 转发、LuCI、风扇/LED、2.4G/5G 已在 B 机
S1b 验证（`docs/S1B-DEVICE-TEST-2026-11-22.md`）；6G 信道未启用、NSS 变体
设备行为未验证（S3e，需单独批准），均不得据静态校验声称可用。重启复验与
WiFi 客户端关联未做。

## 规则

沿用项目根 `CLAUDE.md`：不把密码写入任何文件/脚本/命令行；未经批准不连接、
不扫描、不刷写设备。固件源码与产物可以推 GitHub；厂商 blob 一律不入库。
