# 25.12-6.12 第三方插件清单与来源

本文件是 `build/thirdparty-pins.conf` 的人读版本：19 个插件、19 个仓库的
来源、布局、中文包、运行时依赖与风险。机器可读的唯一来源仍是
`thirdparty-pins.conf`；包是否真的进了镜像由 `build/required-packages.txt`
与 `scripts/ci/check-packages.sh` 反查（见 README「必装包反查」）。

- 版本号一列是 2026-11-13 本地装配树（`tmp/.packageinfo`）的实测值，
  仅作记录；默认 `SBE_PLUGIN_MODE=latest` 每次构建会解析各仓库最新版本
  tag，实际提交见构建日志附件与 release notes 里的 `.sbe-plugins.tsv`。
- 2026-11-22 用户要求再核一轮（远端解析 + 与 24.10 同口径）：只有
  SmartNetPilot 前进（1.1.9-r1 → 1.2.7-r1），`passwall-packages` 分支头
  前进到 65ae3f5e（只动 smartdns、v2ray-geodata 两个本项目未启用的包），
  其余 16 个仓库已是最新。中文包无新增项。
- 2026-11-28 用户要求再核一轮（远端解析 + 与 24.10 同口径）：`oxidns`
  （v1.5.5 → v1.5.8）、`tasks`（1.1.2-r1 → 1.1.8-r1）、`passwall`
  （26.11.11-1 → 26.11.23-1）、`argon`（v3.1.4 → v3.2.0）四个前进，
  `passwall-packages` 分支头前进到 f941f174（只动 sing-box、v2ray-geodata
  两个本项目未启用的包，6 个入选包内容未变），其余仓库已是最新。
  清单 pin 已同步到 `thirdparty-pins.conf`；镜像未重编、未上机验证。
- 2026-11-28 第二轮：新增自维护插件 `luci-app-fileassistant`（2.1.0-r1，
  ucode 后端，中文包 `luci-i18n-fileassistant-zh-cn`），`substore`
  2.7.3-r3 → 2.7.4-r1、`meshassistant` 2.9.0-r1 → 2.9.1-r1、
  `passwall-packages` 分支头前进到 1ad22706（6 个入选包内容未变），
  其余仓库已是最新。清单 pin 已同步；镜像未重编、未上机验证。
- 2026-11-28 第三轮（用户要求）：`substore` 2.7.4-r1 → 2.9.0-r1。
  该版本跨度包含 2.8.0 的**后端从 Lua 迁到 ucode**（控制器/模板/模块改为
  `.uc`/`.ut`，Lua 实现删除），依赖由 `luci-lua-runtime`+`luci-compat`
  改为 `+luci-base +ucode-mod-fs +ucode-mod-math`（`luci-base` 已带解释器
  与这两个模块，seed 无需新增行）；仓库要求最低 OpenWrt 24.10，三条线均满足。
  其余 18 个仓库无变化。镜像未重编、未上机验证。
- 第三方插件授权状态统一记 `LICENSE_REVIEW_REQUIRED`：即使 Makefile 里写了
  `PKG_LICENSE`，也尚未做过随镜像公开分发的法务确认。自维护包按各自
  `PKG_LICENSE` 记录。
- 设备行为一律 `NOT TESTED`：本清单只保证「能编译、能进镜像」，不保证
  新版本插件在 SBE1V1K 上的运行时表现。

## 一、19 个插件总表

| # | 插件 | 包名 | 仓库（owner/repo） | 版本实测 | 中文包 | 授权 |
|---|---|---|---|---|---|---|
| 1 | FCC 加速 | luci-app-fcc | Arthur97172/luci-app-fcc | 1.2.4-r1 | luci-i18n-fcc-zh-cn | GPL-3.0 |
| 2 | LED 风扇控制 | luci-app-ledfancontrol | Arthur97172/luci-app-ledfancontrol | 1.1.3-r1 | luci-i18n-ledfancontrol-zh-cn | GPL-3.0-only |
| 3 | NS-SECM | luci-app-nssecm | Arthur97172/luci-app-nssecm | 1.0.1-r1 | luci-i18n-nssecm-zh-cn | GPL-3.0-only |
| 4 | 在线升级 | luci-app-online-upgrade | Arthur97172/luci-app-online-upgrade | 1.1.3-r4 | luci-i18n-online-upgrade-zh-cn | GPL-2.0-only |
| 5 | 订阅存储 | luci-app-substore | Arthur97172/luci-app-substore | 2.9.0-r1 | luci-i18n-substore-zh-cn | 未声明 |
| 6 | 任务计划 | luci-app-tasks | Arthur97172/luci-app-tasks | 1.1.8-r1 | luci-i18n-tasks-zh-cn | GPL-3.0-only |
| 7 | SmartNetPilot | luci-app-smartnetpilot | Arthur97172/luci-app-smartnetpilot | 1.2.7-r1 | luci-i18n-smartnetpilot-zh-cn | GPL-3.0-only |
| 8 | 核心状态 | luci-app-corestatus | Arthur97172/luci-app-corestatus | 1.0.4-r1 | luci-i18n-corestatus-zh-cn | GPL-3.0-only |
| 9 | OxiDNS | luci-app-oxidns | Arthur97172/luci-app-oxidns | 1.5.8-r1 | luci-i18n-oxidns-zh-cn | GPL-3.0-or-later |
| 10 | 关机 | luci-app-poweroff | Arthur97172/luci-app-poweroff | 1.0.0-r1 | luci-i18n-poweroff-zh-cn | GPL-3.0-only |
| 11 | Mesh 助手 | luci-app-meshassistant | Arthur97172/luci-app-meshassistant | 2.9.1-r1 | luci-i18n-meshassistant-zh-cn | GPL-3.0-only |
| 12 | TurboACC | luci-app-turboacc | Arthur97172/luci-app-turboacc | 1.3.2-r1 | luci-i18n-turboacc-zh-cn | GPL-3.0-only |
| 13 | 文件助手 | luci-app-fileassistant | Arthur97172/luci-app-fileassistant | 2.1.0-r1 | luci-i18n-fileassistant-zh-cn | GPL-3.0-only |
| 14 | PassWall | luci-app-passwall | Openwrt-Passwall/openwrt-passwall | 26.11.23-r1 | luci-i18n-passwall-zh-cn | LICENSE_REVIEW_REQUIRED |
| 15 | Nikki | luci-app-nikki | nikkinikki-org/OpenWrt-nikki | 1.26.2-r1 | luci-i18n-nikki-zh-cn | LICENSE_REVIEW_REQUIRED |
| 16 | OpenClash | luci-app-openclash | vernesong/OpenClash | 0.48.002 | 无独立包（自带 .lmo） | LICENSE_REVIEW_REQUIRED |
| 17 | Argon 主题 | luci-theme-argon | jerrykuku/luci-theme-argon | 3.2.0-r20261124 | luci-i18n-argon-config-zh-cn | LICENSE_REVIEW_REQUIRED |
| 18 | Argon 设置 | （并入 luci-theme-argon） | 同上 | — | 同上 | 同上 |
| 19 | mosdns | luci-app-mosdns + mosdns（+ geo2txt） | sbwml/luci-app-mosdns | 1.7.15-r1 / 5.3.4-r15 | luci-i18n-mosdns-zh-cn | LICENSE_REVIEW_REQUIRED |

合计：13 个自维护应用 + 6 组第三方仓库。带出的后端/内核包
（xray-core、sing-box、mihomo-meta、mosdns、geo2txt 等）见第四节。

## 二、布局与安装方式

`fetch-plugins.sh` 按 `thirdparty-pins.conf` 的 `subdir` 字段逐个
`rm -rf <装配树>/package/<name>` 再整目录拷入，因此：

| 仓库 | 包目录 | 说明 |
|---|---|---|
| 13 个自维护 | 仓库根（`.`） | 根目录就是包目录，`po/zh_Hans` 齐全 |
| openwrt-passwall | `luci-app-passwall/` | 根下只有这一个包 |
| openwrt-passwall-packages | `chinadns-ng`、`dns2socks`、`ipt2socks`、`shadowsocksr-libev`、`simple-obfs`、`tcping` | 6 个子目录子集，不整仓安装 |
| OpenWrt-nikki | `nikki/`、`luci-app-nikki/`、`mihomo-meta/` | mihomo-meta 从源码用树内 golang 编译 |
| OpenClash | `luci-app-openclash/` | 中文 `.lmo` 由包内 po2lmo 直接编译进 i18n 目录 |
| luci-app-mosdns | `mosdns/`、`luci-app-mosdns/`、`geo2txt/` | 一条清单行三个包目录；mosdns 从源码用树内 golang 编译 |
| luci-theme-argon | 仓库根（`.`） | 主题包；设置页已并入 |

安装脚本额外做两件事：

1. **重名检查**：安装前在 `<装配树>/package/feeds/*/` 里查同名包。官方
   feed 已有的（microsocks、xray-core、sing-box、ruby……）一律用官方版，
   第三方仓库不得再提供同名包，否则包索引里会出现两份定义。命中即
   `[plugins] FAIL` 并中止构建。
2. **删除 argon 迁移包**：`luci-theme-argon` 仓库里还留着
   `compat/luci-app-argon-config/`（v3 的空迁移包，与主题包文件冲突）。
   安装时删掉该 `compat/` 目录。清单与 seed **都不得**选择
   `luci-app-argon-config`。

## 三、中文包命名规则（来自 luci.mk）

`luci-i18n-<basename>-<alias>`，其中 `<basename>` 是包名去掉
`luci-app-`/`luci-theme-` 前缀，`<alias>` 把 `zh_Hans` 映射为 `zh-cn`。
由此推出：

- po 目录名决定有没有包：只有 `po/zh_cn`（而非 `zh_Hans`）目录的仓库
  不会生成 `luci-i18n-*-zh-cn` 包，例如 OpenClash（它自己编译 `.lmo`）。
- po 文件名无关紧要（如 mosdns 的 `mosdns.po`），目录名才是关键。
- `luci-proto-wireguard` 没有 `po/`，25.12 不存在
  `luci-i18n-wireguard-zh-cn`，字符串回落到 luci-base 的中文包。
- `luci-theme-argon` 的消息域是 `argon-config`，所以中文包叫
  `luci-i18n-argon-config-zh-cn`（挂在主题包上）。

## 四、按插件的依赖与风险

### 13 个自维护应用

Makefile 的 `LUCI_DEPENDS` 决定运行时依赖，defconfig 自动带入；seed 里
显式写出的只是其中「不写就可能被静默丢弃」的部分（lua 运行时、ucode、
mesh 的 batman 组件等），便于反查。

| 插件 | 关键依赖 | 实现 | 风险 |
|---|---|---|---|
| fcc | luci-base、luci-compat、luci-lib-httpclient、curl、ca-bundle、tmux | Lua | 无 |
| ledfancontrol | luci-base | ucode/Lua | 无 |
| nssecm | luci-base | ucode/Lua | 无 |
| online-upgrade | curl、jsonfilter | ucode | 无 |
| substore | luci-base、ucode-mod-fs、ucode-mod-math | ucode | 2.8.0 起后端整体迁到 ucode，不再依赖 Lua 栈；`luci-base` 已带 ucode 解释器与这两个模块 |
| tasks | luci-base | ucode | 无 |
| smartnetpilot | luci-base | ucode | 无 |
| corestatus | ucode、ucode-mod-fs | ucode | 无 |
| oxidns | luci-base、rpcd、jsonfilter、uclient-fetch、ca-bundle | ucode | 无 |
| poweroff | luci-base | ucode | 与已移除的 `poweroffdevice` 无关 |
| meshassistant | kmod-cfg80211、batctl-default、kmod-batman-adv、dawn、bash、luci-proto-batman-adv、socat、flock、iw | ucode | `+iw` 由 `iw-full` 的 PROVIDES 满足；`iw` 与 `iw-full` 只能装一个，seed 显式关 `iw` |
| turboacc | firewall4、ucode、ucode-mod-fs、ucode-mod-uci、ucode-mod-ubus | ucode | 无 |
| fileassistant | luci-base、ucode、ucode-mod-fs | ucode | 无 |

### PassWall 家族（第 14 项）

- `luci-app-passwall` 只取 UI 包；`INCLUDE_Xray`、`INCLUDE_SingBox`、
  `INCLUDE_Simple_Obfs`、`INCLUDE_ShadowsocksR_Libev_Client` 打开，其余
  INCLUDE 显式关闭（geoview/v2ray-plugin/shadowsocks-rust/hysteria/
  naiveproxy 等在 25.12 没有对应源码）。
- 透明代理选 nftables 变体（`luci-app-passwall_Nftables_Transparent_Proxy`），
  iptables 变体关闭。
- `openwrt-passwall-packages` 只提供 6 个官方 feed 没有的包：
  chinadns-ng、dns2socks、ipt2socks、shadowsocksr-libev、simple-obfs、tcping。
  该仓库没有版本 tag，只能取 main 头（`.sbe-plugins.tsv` 里显示 `HEAD`）。
- **xray-core、sing-box、microsocks 用官方 packages feed 的版本**，不要写进
  第三方清单（同名包会互相覆盖）。
- 风险：上游改 `INCLUDE_*` 符号名时，`check-packages.sh config` 会在
  defconfig 后指名失败；修 seed 即可，不影响其他插件。

### Nikki / mihomo（第 15 项）

- 三个包：`nikki`（后端）、`luci-app-nikki`（UI）、`mihomo-meta`
  （mihomo 内核，`PROVIDES mihomo`，是 DEFAULT_VARIANT）。
- `mihomo-meta` 从源码编译，用树内 golang，不下载预编译二进制。
- `mihomo-alpha` 明确关闭（seed 与 required 表都有 `!mihomo-alpha`）。
- 风险：新版 mihomo 可能要求比 25.12 自带更新的 Go。失败时的回退是禁用
  nikki 三项，passwall 的 xray/sing-box 覆盖同类功能。

### OpenClash（第 16 项）

- 只有 `luci-app-openclash` 一个包；不捆绑内核，运行时由 Web UI 下载。
- 依赖 `ruby` + `ruby-yaml`（配置解析脚本）。`CONFIG_RUBY_ENABLE_YJIT` 明确
  关闭：aarch64 默认开 YJIT 会引入 rust/host 构建依赖，本项目不需要。
- 中文没有独立包：`.lmo` 由包内工具直接编译安装。
- 风险：ruby 3.4 在 25.12 的构建问题；失败时回退为禁用 openclash + ruby。

### Argon 主题（第 17/18 项）

- `luci-theme-argon` v3 起把设置页并入主题包，仓库里的
  `compat/luci-app-argon-config/` 只是空迁移包，与主题包文件冲突。
  安装脚本已删除该目录，seed 也显式 `# CONFIG_PACKAGE_luci-app-argon-config
  is not set`。
- 中文包 `luci-i18n-argon-config-zh-cn` 随主题包安装。
- 风险：上游若把 compat 目录改回实体包，重名检查/seed 断言会先失败。

### mosdns（第 19 项，2026-11-15 取代 bandix）

- 一个仓库三个包：`mosdns`（后端，Go 源码）、`luci-app-mosdns`（UI，含
  `po/zh_Hans`，生成 `luci-i18n-mosdns-zh-cn`）、`geo2txt`（geosite/geoip
  解包工具，C）。一条清单行写三个 subdir，一次装齐。
- 与 24.10 不同，25.12 树内 golang 为 1.26/1.27，`mosdns` 直接源码编译
  （仓库的 `100-mosdns-update-dependencies.patch` 把 go.mod 升到 1.26.0），
  不再需要预编译二进制包装包。
- 前端依赖 `v2ray-geoip`、`v2ray-geosite`（官方 packages feed）、
  `uclient-fetch`、`ucode`，seed 显式选择便于反查。
- 风险：mosdns 新版的 go.mod 若超过树内 Go 版本，构建会失败；回退为保持
  pin（或临时禁用 mosdns 一组），不影响其他插件。

## 五、构建时自动跟新与复现

`fetch-plugins.sh` 在 `prepare-tree.sh` 内部调用，本地与 CI 行为一致：

- **默认（latest）**：对每个仓库增量 `git fetch`，解析默认分支上的版本 tag
  （`git tag` + `sort -V`，注解 tag 取 `^{}` 的提交）；没有版本 tag 的仓库
  取默认分支头。新提交必须是清单 pin 的后代才采用；回退或分叉
  （`diverged`）保留原 pin 并在 `.sbe-plugins.tsv` 标注；远端不可达记
  `SOURCE_UNAVAILABLE` 并回退到 pin（构建继续）。
- **复现（`SBE_PLUGIN_MODE=pinned`）**：全部按清单里的 pinned-commit 安装，
  与本文件记录的版本一致。workflow_dispatch 的 `plugin_mode` 输入同名参数。
- **严格（`SBE_PLUGIN_STRICT=1`，CI 默认）**：只要有仓库解析结果不是
  `same`（即没跟上最新、分叉或未知），构建直接失败——避免「以为在跟新」。
- 结果写入 `<装配树>/.sbe-plugins.tsv`（key、url、tag、commit、pin、动作），
  进入 release notes 与构建日志附件。构建过程只读清单，不改写任何 pin 文件。
- **复现基线刷新（`--update-pins`）**：每周的 `refresh-pins.yml`（三线共用）
  用它把清单的 pinned 列前移到最新版本 tag——只前移、不回退，behind/diverged/
  远端不可达保持原 pin 并在报告里标注；不安装、不碰装配树。结果经
  `auto/pin-refresh` 分支走 PR，从不自动合并（注记列里的版本号不自动改写，
  合并前按报告中的「最新 tag」人工更新）。命令：
  `./25.12-6.12/scripts/ci/fetch-plugins.sh --update-pins [--report r.md]`。
- 本机缓存在仓库根 `.sbe-cache/plugins/`（已 gitignore）：blobless 元数据
  克隆 + depth-1 打包树，CI 每次从零建。

## 六、已移除的插件（不得回来）

| 包 | 处理 | 说明 |
|---|---|---|
| luci-app-cpu-status | 25.12 从未集成，seed 显式关闭 | 2026-11-07 从 24.10 移除 |
| luci-app-wifihistory | 源码在官方 luci feed，未选，seed 显式关闭 | 同上 |
| luci-app-poweroffdevice | 无符号；`luci-app-poweroff` 是另一个包 | 同上 |
| luci-app-argon-config | 与主题包冲突，显式关闭 | 见上节 |
| luci-app-bandix-plus | 2026-11-15 前后端整体移除（同 24.10，先前端换 mosdns） | seed 显式关闭，`!` 反查 |
| bandix-plus | 同上；后端服务与专属依赖（conntrack/libtirpc/libnetfilter-*）一并移除 | 同上 |
| mihomo-alpha | 只要 mihomo-meta | — |
| wget-nossl | wget 只能选一个 TLS 变体 | 取 wget-ssl |

`required-packages.txt` 里以 `!` 前缀记录，`check-packages.sh` 在 seed、
defconfig 结果和镜像 apk 数据库三处反查。

## 七、验证与状态

- 静态：`scripts/ci/check-packages.sh` 的 `seed` / `index` / `config` /
  `db` 四种模式，2026-11-13 本地装配树实测
  `seed PASS / index PASS 92 / config PASS 98 / FAIL 0`。状态词 `PASS`
  只覆盖「包存在且被选中」，不覆盖编译与运行。
- 2026-11-15 bandix 前后端换成 mosdns 后只重跑了 `seed` 模式：
  `PASS 101 / FAIL 0`；`index` / `config` / `db` 依赖装配树与镜像，
  以 CI 下一次构建为准。
- 编译：只能由 CI 的 `Build` 步骤验证（约 3 小时）。
- 设备：全部 `NOT TESTED`。
- 授权：第三方插件 `LICENSE_REVIEW_REQUIRED`；随镜像公开分发前须逐仓库
  确认 LICENSE 与再分发条款。
