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
│   ├── build-fixes/  openwrt-patches/  local-packages/  p-b/   装配期改动与本地软件包
├── files/                    固件 overlay（唯一来源，构建时渲染进装配树）
│   ├── etc/banner                /etc/banner，`%V`/`%R` 由渲染脚本替换
│   ├── etc/uci-defaults/99-wireless-defaults   首启入口（boot 以 source 执行）
│   ├── etc/init.d/wireless-defaults            每次开机执行（START=95）
│   └── usr/lib/sbe1v1k/wireless-defaults       实际逻辑（UCI marker 幂等）
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
        ├── prepare-tree.sh      仅 CI：重建 host-bin、固定时间戳、残留断言
        ├── verify-image.sh      从最终 sysupgrade 镜像解出 rootfs 做静态校验
        └── export-sources.sh    把装配 stage 打成源码包（tar.zst + SHA256SUMS + 指纹）
```

## LuCI（Web 管理界面）

镜像内置 LuCI（`luci-light` 组合 + `luci-mod-admin-full`），由 `uhttpd` + `rpcd` 提供服务，
默认监听 `0.0.0.0:80` 与 `0.0.0.0:443`（`redirect_https` 关闭）。刷机后浏览器打开
`http://<设备地址>/` 即可；`/etc/config/luci` 的 `option lang` 为 `auto`，所有模块都装了
`luci-i18n-*-zh-cn`，浏览器语言为中文时自动切换。

版本（取自镜像内 `/usr/lib/opkg/status`，随 feeds 更新会变化）：

| 组件 | 版本 |
| --- | --- |
| `luci-base` | 26.202.46438~d040071 |
| `luci-light` | 23.024.33244~34dee82 |
| `luci-mod-admin-full` | 19.253.48496~3f93650 |

共 51 个 `luci-*` 包，分三类：

- **核心**：`luci-base`、`luci-light`、`luci-compat`、`luci-mod-admin-full`、
  `luci-mod-network`、`luci-mod-status`、`luci-mod-system`、`luci-lib-*`、
  `luci-proto-ipv6`、`luci-proto-ppp`、`luci-app-package-manager`；
  主题只有 `luci-theme-bootstrap`（未装 argon 等第三方主题）。
- **上游应用**（feeds `luci`）：`luci-app-firewall`、`luci-app-ddns`、`luci-app-upnp`、
  `luci-app-ttyd`。
- **项目与三方应用**：
  - 本项目 feeds（`sources/apps`）：`luci-app-fcc`、`luci-app-ledfancontrol`、
    `luci-app-nssecm`、`luci-app-online-upgrade`、`luci-app-substore`
  - 三方 feeds（`sources/thirdparty-feed`）：`luci-app-bandix-plus`、`luci-app-cpu-status`、
    `luci-app-nikki`、`luci-app-openclash`、`luci-app-passwall`、`luci-app-poweroff`、
    `luci-app-wifihistory`
  - 代理后端（`sources/passwall-selected`）：`chinadns-ng`、`dns2socks`、`ipt2socks`、
    `microsocks`、`shadowsocksr-libev`、`simple-obfs`、`tcping`；另有 `xray`、`sing-box`、
    `mihomo`、`ruby` 等运行依赖，均不带 LuCI 界面包之外的额外前端。

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
  `mode=manual`：人工剪裁/带补丁（如 wifihistory），只校验不改写。
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
4. 更新 `sources/PROVENANCE.md` §2.9 的 pin 与许可证记录；
5. 提交并 push；等 `sources-24.10-6.6.yml` 验证通过后手动 `publish=true` 发新的
   `sources-vN`，构建 workflow 的 `source_tag=auto` 会自动用最新的一版。

第 5 步不能省：**CI 编译用的是源码包，不是本地 `sources/`**，只改文件 A
不会影响 CI。装配输入（`build/**`、四个装配脚本、25.12 的 Wi-Fi blob）一有 push，
装配 workflow 就会重新验证并比对新指纹。

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

真机升级状态：`NOT TESTED`。

## CI

两个 workflow，避免把几小时的编译和装配挤在一次运行里：

| workflow | 触发 | 产物 |
|---|---|---|
| `sources-24.10-6.6.yml` 🧱 | `build/**`、`docs/**`、四个装配脚本变更 / 手动 | Release `sources-vN`：源码包 + `SHA256SUMS` + 指纹（恰好 3 个） |
| `build-24.10-6.6.yml` 📦 | `24.10-6.6/**` 变更 / 手动（可指定 `source_tag`） | Release `v<run>-<attempt>-<sha8>`：三个固件（恰好 3 个） |

构建流程：`source_tag=auto` 挑最新的 `sources-vN`（N≥2、资产数恰好 3；`sources-v1` 是含
`dl/` 的 legacy，跳过）→ `sha256sum -c` → 解包 → 树指纹比对（未解释差异必须为 0）→
配方哈希比对 → `prepare-tree.sh` → `render-overlay.sh` → `check-config.sh` →
`thirdparty-feeds.sh check` → `make -k download` 预检 → 应用文件 B 并逐包反查 →
编译 → `verify-image.sh` → 发 Release。

细节（每道门禁证明什么、失败怎么处理）见 [docs/CI_BUILD.md](docs/CI_BUILD.md)。
两个 workflow 都尚未在 Actions 上实际运行过，记为 `NOT TESTED`。

## 注意

- `files/` 由 `include/image.mk` 原样复制进 rootfs，**不经过** `VERSION_SED_SCRIPT`，
  所以 banner 里的 `%V`/`%R` 必须由 `render-overlay.sh` 在构建前替换。
- `/etc/rc.d/S95wireless-defaults` 由 `include/rootfs.mk` 的 `prepare_rootfs`
  自动生成，条件是 `etc/init.d/wireless-defaults` 首行**精确**为
  `#!/bin/sh /etc/rc.common` 且权限 0755。
- `/etc/uci-defaults/*` 由 `/etc/init.d/boot` 以 `.` 方式加载，成功后删除，
  因此那里的包装脚本不能 `exec`、`exit` 或 `set -e`。
- 构建与校验过程不接触任何设备；产物未经真机验证前记为 `UNVERIFIED`。
