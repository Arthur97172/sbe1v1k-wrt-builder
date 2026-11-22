# 25.12-6.18 — OpenWrt main（Linux 6.18）的 SBE1V1K 基线

本目录是 SBE1V1K（Askey RTQ7300T / Spectrum SBE1V1K，ipq9574）在 Linux 6.18
上的固件树。它与 `25.12-6.12/` 平级、各自独立装配，区别只在基线选择：

| | 25.12-6.12 | 25.12-6.18 |
|---|---|---|
| 上游 | `openwrt-25.12` 分支，6.12 | `main`，`KERNEL_PATCHVER:=6.18` |
| 设备定义 | 本项目的 `spectrum_sbe1v1k`（补丁） | 上游原生 `askey_sbe1v1k` |
| 数据通路 | QSDK NSS（qca-ssdk/dp/ppe/ecm） | S1 用上游 mainline PPE；**S3 移植 NSS，目标对齐** |
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
  107 项 PASS。与 6.12 的差异只在不存在的 QSDK 组件（qca-ssdk-shell、
  sbe-wifi-firmware、NSS 包）。
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
├── files/etc/uci-defaults/95-ttyd-disable       # 首启关闭 ttyd（同 6.12 默认）
├── patches/                                     # 装配时按序应用、可重复
│   └── 0001-qualcommbe-sbe1v1k-swap-port5-port6-labels.patch
└── scripts/
    ├── ci/prepare-tree.sh                       # 克隆 main + 钉 feed + 插件装配
    ├── ci/fetch-plugins.sh                      # 18 插件按最新 tag 安装
    ├── ci/check-packages.sh                     # seed/index/config/db 反查
    ├── ci/verify-image.sh                       # 产物静态校验 + 包反查
    └── local/build-image.sh                     # 本地构建入口
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
25.12-6.18/scripts/local/build-image.sh world       # 编译 + 校验
```

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
`askey_sbe1v1k`）。

## 固定版本

- OpenWrt：`OPENWRT_SHA=0e66e1c7457a6a92d851c23cd47f7c6f69a7455a`（main，
  2026-11-22 时的设备定义/EmmcImage/平台脚本形态）
- feeds（tags/branch 均 override 自 `prepare-tree.sh` 的 `feed_sha()`）：
  packages `be0dbb6e`、luci `f7675c07`、routing `ea8633da`、telephony
  `06feffc2`、video `6a3b5fd6`

升级任何 pin 前先在本地完整构建 + 静态校验通过，再单独提交。

## 产物与验证

`verify-image.sh` 断言：sysupgrade tar 含 `kernel`/`root`；FIT 里嵌着
`Askey SBE1V1K` / `askey,sbe1v1k` / `config@rtq7300t-rev0`；root 是
squashfs；`openwrt_release` 目标为 `qualcommbe/ipq95xx`；解包后的 apk
数据库按 `build/required-packages.txt` 逐包反查（插件、工具、必禁项）。
设备侧：启动、网口角色、LAN→WAN 转发、LuCI、风扇/LED、2.4G/5G 已在 B 机
S1b 验证（`docs/S1B-DEVICE-TEST-2026-11-22.md`）；6G 信道未启用、NSS 加速
尚未移植，均不得据静态校验声称可用。重启复验与 WiFi 客户端关联未做。

## 规则

沿用项目根 `CLAUDE.md`：不把密码写入任何文件/脚本/命令行；未经批准不连接、
不扫描、不刷写设备。固件源码与产物可以推 GitHub；厂商 blob 一律不入库。
