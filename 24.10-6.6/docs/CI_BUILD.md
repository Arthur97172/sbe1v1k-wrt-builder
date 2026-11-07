# CI 构建流水线（24.10-6.6）

本文件说明 GitHub Actions 上的三个 workflow 各自做什么、用什么证明“编译的就是已审计的源码”，
以及出问题时应先看哪一道门禁。装配配方本身见 [SOURCE_ASSEMBLY.md](SOURCE_ASSEMBLY.md)；
第三个 workflow（插件 pin 巡检）只开 PR，不参与产线。

> 状态：装配 workflow 已发布 `sources-v3`（run `40183767687`，PASS，恰好 3 个资产；
> 指纹文件与本地导出的逐字节相同）。上一轮 Build（run `40176273728`）在 `sysupgrade-helper`
> 上失败，根因是装配时剪掉了这个包的源码树 `qca/src/u-boot-2025`，修复与本地验证见 §6。
> 修好后的 Build（run `40185702727`，`source_tag=auto` 自动选中 `sources-v3`）已 PASS：
> 21 个构建步骤 + release job 全绿，`verify-image.sh` 静态校验通过，Release `v16-1-5dda9f3b`
> 恰好 3 个资产。**镜像产物在真机上的启动、升级与以太网行为仍为 `NOT TESTED`。**

## 1. 为什么是三个 workflow

单次编译约 3 小时、需要 25 GB 以上磁盘；装配同样要克隆 4.6 GB 上游、生成 2.2 GB 源码树。
拆成三段后（前两个负责产线，第三个负责插件版本巡检）：

| workflow | 文件 | 做什么 | 产物 |
|---|---|---|---|
| 🧱 Assemble | `.github/workflows/sources-24.10-6.6.yml` | 从 42 个固定提交装配源码树、比对指纹、打包 | Release `sources-vN`：**恰好 3 个**资产 |
| 📦 Build | `.github/workflows/build-24.10-6.6.yml` | 下载源码包、六道门禁、编译、发布固件 | Release `v<run>-<attempt>-<sha8>`：**恰好 3 个**镜像 |
| 🔄 Refresh pins | `.github/workflows/refresh-pins-24.10-6.6.yml` | 每周把插件 pin 解析到最新、只读检测内核，开/更新 PR | 分支 `auto/pin-refresh` + 一个 PR（**不自动合并**） |

改补丁/配置只需 push：装配 workflow 重新验证（可选发布新 `sources-vN`），构建 workflow 用
`source_tag=auto` 自动取最新可用的源码包。**不再需要人工上传任何文件。**

### 1.1 插件“跟最新”的闭环

`refresh-pins-24.10-6.6.yml`（每周一 04:23 UTC + 手动）跑 `scripts/ci/refresh-pins.sh`
`--apply`：按用户 2026-11-07 选定的口径把 10 个自维护插件与 7 个第三方仓库解析到
**最新 release tag**（无版本 tag 的退回默认分支头；最新 tag 相对当前 pin 是
behind/diverged 时保持不动，**绝不回退**），只改写 commit 字段与 `PROVENANCE.md`
的 pin 快照，然后 force-push 到固定分支 `auto/pin-refresh` 并创建一个 PR（已存在则
原地更新同一 PR）。PR 正文第一段是内核结论：

- 内核**只检测**：比对 CodeLinaro `linux-ipq-6.6` 的 `win_qsdk.common.*` 分支
  SUBLEVEL 与当前 pin，有更高版本只写“需人工评估”，脚本从不改写内核 pin；
  真要升级走 `scripts/check-kernel.sh`（会重做整轮审计）。
- **不自动合并**：pin 变化可能带进新依赖或坏版本，合并前必须让装配门禁在 PR 上
  跑一遍。合并后 push 命中 `24.10-6.6/build/**` 自动触发装配验证；发布
  `sources-vN` 仍需手动 `publish=true`。
- 权限只用仓库内置 `GITHUB_TOKEN`（`contents: write`、`pull-requests: write`），
  不需要 PAT，也不把任何令牌写进文件或 URL。
- 插件树在指纹里按 `known-delta.conf` 的 `any` 白名单整树放宽（理由与补偿控制写在
  该文件注释里），因此 pin 刷新 PR 不需要重建十万条审计基线。


## 2. 装配：`sources-24.10-6.6.yml`

触发：

- `workflow_dispatch`，输入 `publish`（默认 `false`）与 `tag`（留空 = 自动选号）；
- push 到 `main`，路径命中 `24.10-6.6/build/**`、`24.10-6.6/docs/**` 或四个装配脚本；
  另含 `25.12-6.12/build/local-packages/sbe-wifi-firmware/**`——24.10 的 6 个厂商 Wi-Fi blob
  取自 25.12 的已提交副本，这是明写的跨版本耦合。

固定环境：`SOURCE_DATE_EPOCH=1792557977`、`TZ=UTC`、`LC_ALL=C`、`SBE_MIN_FREE_GB=25`。

```bash
./24.10-6.6/scripts/ci/assemble-sources.sh \
  --stage "$RUNNER_TEMP/stage" \
  --compare 24.10-6.6/build/fingerprint/audited-24.10-6.6.tsv.zst
./24.10-6.6/scripts/ci/export-sources.sh \
  --stage "$RUNNER_TEMP/stage" --out "$RUNNER_TEMP/dist"
```

装配的 16 步与顺序依赖（target feed → kernel overlay → 第三方树 → feeds 接线）见
SOURCE_ASSEMBLY.md；任一步失败即非零退出，不会产出半成品包。

发布资产（`publish=true` 才建 Release，标签已存在则拒绝覆盖）：

| 资产 | 作用 |
|---|---|
| `sbe1v1k-sources-24.10-6.6.tar.zst` | 源码树（不含 `dl/`；体积断言 < 1.9 GB） |
| `SHA256SUMS` | 包本身的校验值，构建端第一步就验 |
| `TREE-FINGERPRINT.json` | 聚合指纹、`recipe_sha256`、逐子树摘要 |

`TREE-FINGERPRINT.json`/`.tsv` 同时也在 tar 里（打包前写入包根），所以构建端只需下载 tar 也能比对。

标签规则：`sources-v<已有最大数字 + 1>`。`sources-v1` 是 legacy（4 个资产、含 1.11 GB 的 `dl/`），
保留但不再更新；构建 workflow 的 `auto` 只接受 **N ≥ 2 且资产数恰好 3** 的标签。

装配第 14 步还有一条断言，专门拦“树装出来了、但少了一棵编译需要的源码树”：
逐个检查**被 `=y`/`=m` 选中的包**，凡是靠 `include/local-development.mk` 的
`$(TOPDIR)/qca/src/$(PKG_NAME)`（或自带显式 `LOCAL_SRC`）取源码的，那棵目录必须存在，
否则输出 `MISSING_IMPLICIT`/`MISSING_EXPLICIT` 并 `rc=4`。原因：该 include 只在目录
存在时才把 `PKG_UNPACK` 换成“拷本地树”，目录不在就静默退回 `PKG_SOURCE_PROTO:=git` +
空 `PKG_SOURCE_URL`，包会在 1 秒内以 `No rule to make target …` 失败——2026-10-25 的
`sysupgrade-helper` 就是这种死法（见 §6）。

## 3. 构建：`build-24.10-6.6.yml`

`source_tag` 输入默认 `auto`：从 `sources-vN` 里挑数字最大、且资产数恰好 3 的标签；旧标签资产数不对
就跳过并告警。也可以直接填 `sources-v3` 之类指定某一版。

### 门禁顺序（全部在编译前）

| # | 步骤 | 证明什么 | 失败含义 |
|---|---|---|---|
| 1 | 下载 3 个资产 + `sha256sum -c SHA256SUMS` | 包在传输中没有损坏 | 发布不完整或被改动 |
| 2 | `tree-fingerprint.sh --compare sources/TREE-FINGERPRINT.tsv --known-delta build/known-delta.conf` | **解包后的树**与发布时的树逐文件相同；未解释差异必须为 0 | 包内容与指纹不符（rc=5 → 立即停） |
| 3 | `recipe-hash.sh` 与 `TREE-FINGERPRINT.json` 的 `recipe_sha256` 比对 | 这个包是用**本仓库当前配方**装出来的，不是旧配方 | 配方与源码包不同步，需重发 `sources-vN` |
| 4 | `render-overlay.sh` + `check-config.sh` | overlay 渲染后 `make defconfig` 归一化结果与 `build/config-frozen/.config` 逐行相等 | 包集合变了 |
| 5 | `thirdparty-feeds.sh check`（`SBE_NO_GIT=1`） | 第三方目录与 pin/指纹一致、软链指向正确 | 第三方树装配错误 |
| 6 | `download-preflight.sh`（`make -k download`） | 第三方 tarball 全部可取 | 输出 `DOWNLOAD_FAIL` 清单并停 |

第 2 步用 `--compare <tsv>` 而不是 JSON：tsv 是逐文件清单，能给出具体路径；聚合值在日志里另行打印。
`known-delta.conf` 里登记两条：`PROVENANCE.md`（审计后只改了 §2.5/§2.5.1 的文档行）与
`buildroot/openwrt-patches/package/utils/busybox/busybox.mk`（0017 注释掉 QSDK 的 busybox
配置覆盖：该覆盖在审计树里从未生效，详见 SOURCE_ASSEMBLY.md §3）。
包根的 `TREE-FINGERPRINT.json`/`.tsv` 不在指纹的子树清单里，因此不出现在比对中。

第 4 步跑 `defconfig` 之前先断言源码包里的 `.config` 与 `build/config-frozen/.config`
逐字节相同：不相等说明包是旧配方装的，直接失败并要求重发 `sources-vN`。

第 6 步之后才 `sbe1v1k-build.sh defconfig` 并逐包反查——`defconfig` 对未知包是静默丢弃的，
反查失败就停，不进入数小时编译。

### 权限与并发

- `build` 任务 `contents: read`：跑 `make world` 的进程不该有写权限；
- `release` 任务单独 `contents: write`，只做 `gh release create` 与资产数断言（恰好 3 个）；
- 并发组 `build-firmware-${{ github.ref }}`，`cancel-in-progress: false`：不打断已跑了几小时的编译。

产物命名：

```
openwrt-ipq95xx-generic-spectrum_sbe1v1k-squashfs-sysupgrade.bin
openwrt-ipq95xx-generic-spectrum_sbe1v1k-fit-uImage.itb
openwrt-ipq95xx-generic-spectrum_sbe1v1k-initramfs-fit-uImage.itb
```

### 静态镜像校验

`verify-image.sh`（`SBE_EXPECT_WIFI_FIRMWARE=1`）从 sysupgrade 的 tar 里取出 squashfs 再解包，
核对的就是刷进设备的文件：三个镜像齐全、sysupgrade < 96 MiB、banner 哈希与占位符、无线默认值三件套、
6 个厂商 Wi-Fi blob 逐字节一致（许可状态仍是 `LICENSE_REVIEW_REQUIRED`）。

## 4. 已知限制

| 限制 | 说明 |
|---|---|
| 固件不是逐字节可复现 | 宿主工具链、CI 自动生成的 opkg 签名密钥、时间戳都不同。**只声称源码树一致**。 |
| 产物记为 `UNVERIFIED` | 未经真机验证；也不证明能启动。 |
| 不含 `dl/` | 构建端 `make download` 现场取；任一 URL 失效会让 workflow 在第 6 道门禁停下。 |
| 单资产 2 GB 上限 | 断言 < 1.9 GB；去掉 `dl/` 后实测约 1.3–1.5 GB。 |
| qsdk 基座不可信 | `everything411/qsdk` 是单提交个人镜像，只用于复现已审计字节；内核/target/files/patches 全部换成 CodeLinaro 固定提交。 |
| 24.10 依赖 25.12 的 blob | 6 个厂商 Wi-Fi 固件取自 25.12 的已提交副本，改任一侧都要重跑装配。 |

## 5. 常用操作

```bash
# 只验证、不发布（push 触发的默认行为）
gh workflow run sources-24.10-6.6.yml -f publish=false

# 发布新源码包（标签自动取下一个号）
gh workflow run sources-24.10-6.6.yml -f publish=true

# 用最新源码包编译
gh workflow run build-24.10-6.6.yml -f source_tag=auto

# 钉死某一版源码包
gh workflow run build-24.10-6.6.yml -f source_tag=sources-v3
```

本地复现装配（不发布）：直接跑 §2 的两条命令，`--stage` 指到任意空目录加 `--force`。
缓存可复用：`--cache <目录>` 默认在 `<stage>/cache`，重跑装配不必重新克隆上游。

## 6. 已验证 / 未验证

| 项 | 状态 |
|---|---|
| 指纹脚本在审计树上两次运行结果相同 | PASS |
| 装配 16 步的 pin / 文件数 / blob / 软链断言 | PASS |
| 装配重复两次聚合指纹相同 | PASS（`entries=156058`，`aggregate=a6a662dd…deb91`） |
| 装配树 vs 审计树指纹（`--compare` 基线） | PASS（`deltas=2`，均被 known-delta 解释，`unexplained=0`） |
| `check-config.sh` 对装配树 | PASS（`lines=2128`，`sha256=e9ee2f72…06ab`，`feeds=8`） |
| `export-sources.sh` 两次导出字节相同、< 1.9 GB、恰好 3 资产 | PASS（`sha256=d39a67a2…b4cc`，228,502,877 B） |
| 消费者侧：解包 → 指纹 `--compare` → recipe-hash → overlay+check-config → thirdparty check | PASS（`deltas=0`，`recipe=eb8c4f93…b2fc`） |
| `make download` 预检（`download-preflight.sh`） | NOT TESTED（本机 `github.com:443` 不可达，不能代表 runner） |
| 🧱 Assemble 在 Actions 上运行（push 触发） | PASS（run `40171593200`，21m24s，11 步全过，含 `mmc.sh` 权限 744 断言） |
| 🧱 Assemble 发布 `sources-v2`（dispatch，`publish=true`） | PASS（run `40174587694`；恰好 3 资产；`TREE-FINGERPRINT.json` 的 `entries=156058`、`aggregate=a6a662dd…deb91`、`recipe=b935371c…45f6` 与本地验证值一致） |
| 📦 Build 在 Actions 上运行（首次尝试 `40171593136`） | NOT TESTED（停在 `Resolve source tag`：当时还没有 `sources-v2`；后续运行见本表末尾） |
| 📦 Build 跑到编译阶段（run `40176273728`，`sources-v2`） | FAIL（`sysupgrade-helper` 0.4 s 失败：`No rule to make target 'tools-only'`；根因见下） |
| 本地复现该失败（把 `qca/src/u-boot-2025` 挪走） | FAIL（同样的 `tools-only` 报错，`compile#0.18#0.25#0.44`，与 CI 一致） |
| 本地修复后编译同一个包 | PASS（16 s，`mkimage`/`dumpimage` 落在 pkgdir） |
| 源码依赖断言（第 14 步）真阳性回归 | PASS（对剪裁后的旧装配树输出 1 条 `MISSING_IMPLICIT qca/src/u-boot-2025`；对修复后的树 `missing=0`） |
| 修复后全量装配（含 `u-boot-2025` 叠加层） | PASS（`entries=194808`，`SRC_DEPS_OK selected=364 checked=2`，`recipe_sha256=adb47539…`） |
| 修复后装配树 vs 审计树（`--compare`） | PASS（`deltas=2` 均 known-delta，`unexplained=0`；`aggregate=3b4a7c31…`） |
| 审计基线 `6273a000…` 与装配树 `3b4a7c31…` 的差别来源 | PASS（把基线 tsv 的那两行换成装配版本重算，聚合值精确等于 `3b4a7c31…`） |
| 修复后本地导出 `export-sources.sh`（新配方） | PASS（258,750,952 B ≈ 258 MB，远低于 1.9 GB 上限；`sha256=6956f8e7…`，`assets=3`，`entries=194808`，聚合值与装配一致） |
| 发布 `sources-v3`（新配方） | PASS（run `40183767687`：assemble 10:12→10:32 UTC，publish 10:33；`Assert exactly 3 assets`、`Verify published assets` 均 success） |
| CI 发布的指纹与本地导出是否一致 | PASS（`TREE-FINGERPRINT.json` 2,276 B 与本地产物 `cmp` 无差异；包 258,497,698 B vs 本地 258,750,952 B，字节差来自 zstd 版本，条目指纹相同） |
| 📦 Build 全量（run `40185702727`，`sources-v3`） | PASS（10:40:00→11:37:48 UTC，57m48s；21 个构建步骤 + release job 全绿，`Verify image (static)` success） |
| `source_tag=auto` 是否选中新配方 | PASS（`Resolve source tag` 解析到 `sources-v3`；`Verify tree fingerprint`、`Verify recipe hash`（`adb47539…`）、`Check frozen config`、`Verify thirdparty source pins` 全部 success） |
| 修复后的 `make download` 在 runner 上 | PASS（`Download third-party tarballs` success；此前只在本地跑过、`NOT TESTED` 的这条现已在 runner 上验证） |
| 修复后的 `sysupgrade-helper` | PASS（`Apply custom packages` + `Build` 均 success，不再出现 `tools-only`） |
| Release `v16-1-5dda9f3b` 资产数 | PASS（恰好 3 个：`fit-uImage.itb` 5,887,728 B、`initramfs-fit-uImage.itb` 92,900,880 B、`squashfs-sysupgrade.bin` 73,923,366 B；`published_at` 11:37:59Z） |
| 2026-11-07 插件批次：全量装配（本地，新 pin/新包集合，oxidns `v1.3.5`） | PASS（`FINGERPRINT_MATCH`，`deltas=512` 全部由 `known-delta.conf` 解释、`unexplained=0`；`entries=194923`，`aggregate=2db99e40…`，`recipe_sha256=d8837aa6…`） |
| 同批次的 `check-config.sh` | PASS（`lines=2139`，`sha256=e87b5969…133b`，`feeds=8`） |
| 同批次的 `refresh-pins.sh` 只读检查 | PASS（0 项可更新、1 项按“不回退”保持不动——nikki；内核 6.6.147 已是 `win_qsdk.common.*` 最高） |
| 同批次的 `thirdparty-feeds.sh check` | PASS（9 个链接；`passwall-selected` 7 个包） |
| 2026-11-07 第二批（uhttpd / wireguard / 系统工具 / argon）：`defconfig` 反查 | PASS（37 个包全部 `=y`；此前 6 个包因源码未接线被静默丢弃，补齐 5 条 `package/feeds` 链接后通过） |
| 同批次的 `check-config.sh` | PASS（`lines=2146`，`sha256=e53c9a9c…6755`，`feeds=8`）。本机 `install` 是 uutils 0.8.0，OpenWrt 的 host prereq 不认，需先 `touch staging_dir/host/.prereq-build` 跳过宿主机工具检查；这只影响本机，CI runner 是 GNU coreutils，且配置等价性（归一化 diff 为空）不受影响 |
| 同批次的全量装配（含 `--compare`） | PASS（`FINGERPRINT_MATCH`，`deltas=829` 全部解释、`unexplained=0`；`entries=195240`，`aggregate=9931c5dc…242`，`recipe_sha256=15dd7f24…6b5`；`FEEDS_OK src-link=11 package-links=170`） |
| 同批次的 `thirdparty-feeds.sh check` | PASS（10 个链接 + argon 仓库 HEAD `6bdb62e6` == pin，工作区干净） |
| 2026-11-07 第三批（无线默认值改 TW / 信道 11/40/61、oxidns 标注 `v1.3.8`）：全量装配（含 `--compare`） | PASS（`FINGERPRINT_MATCH`，`deltas=829` 全部解释、`unexplained=0`；`entries=195240`，`aggregate=a717a8e3…7df`，`recipe_sha256=a9a67b62…d51`；`FEEDS_OK src-link=11 package-links=170`）。`entries` 与上一批相同：本批改动的 `files/` 叠加层在 `fingerprint-exclude.conf` 里整体排除，装配树可见的变化只有 `PROVENANCE.md`/`README.md` 两份文档行与 `upstream-pins.conf` 的 oxidns 注释（后者只进 `recipe_sha256`） |
| 同批次的 `check-config.sh` 等价性 | PASS（冻结配置未变：`sha256=e53c9a9c…6755`，`lines=2146`；装配内 `CONFIG_OK` 同一哈希） |
| 同批次的 `refresh-pins.sh --apply` | PASS（1 项更新：`luci-app-oxidns` `6c432f6d` → `aac1983`，tag `v1.3.7`；1 项保持不动：nikki；内核 6.6.147 仍是 `win_qsdk.common.1.0.r*` 最高） |
| 新 pin 下的全量编译（含 `kmod-wireguard`、`luci-theme-argon`） | NOT TESTED |
| `refresh-pins-24.10-6.6.yml` 在 Actions 上的首次运行 | NOT TESTED（workflow 尚未 push） |
| 新 pin 下的全量编译（含 `kmod-batman-adv`） | NOT TESTED |
| 编译产物在真机启动/升级 | NOT TESTED |
| 6 个厂商 Wi-Fi blob 的许可 | LICENSE_REVIEW_REQUIRED |

发布包由 runner 产出，`sbe1v1k-sources-24.10-6.6.tar.zst` 为 228,711,892 B；本地两次导出的
是 228,502,877 B。两者**条目级指纹完全一致**（上面的 `entries`/`aggregate`/`recipe` 三项相同），
字节差来自打包时的 zstd 版本差异，不是内容差异——这也是为什么门禁比对的是指纹而不是包哈希。

上面这两个字节数是 `sources-v2`（剪裁 `u-boot-2025` 的旧配方）的。新配方把这棵树连同叠加层
一起装进包里，本地导出变成 258,750,952 B（`sha256=6956f8e7…`），仍在 1.9 GB 上限之内；
`recipe_sha256` 也从 `b935371c…` 变成 `adb47539…`，所以对外发布的是 `sources-v3`。

### 2026-10-25：`sysupgrade-helper` 失败（run `40176273728`）

失败形态：包在 0.4 s 内失败，`No rule to make target 'tools-only'`。这个包叫 `sysupgrade-helper`，
但 `PKG_NAME:=u-boot-2025`、`SRC_DIR:=$(TOPDIR)/qca/src/$(PKG_NAME)`，所以它编译的是 u-boot 的
`tools-only`（产出 `mkimage`/`dumpimage` 装进镜像），源码树是被 `prune.conf` 剪掉的
`qca/src/u-boot-2025`。`include/local-development.mk` 只在**目录存在**时把 `PKG_UNPACK` 换成
“拷本地树”；目录不在就静默退回 `PKG_SOURCE_PROTO:=git` + 空 `PKG_SOURCE_URL`，`Build/Configure`
只建出 `include/`，于是 make 找不到目标。剪裁依据（“`.config` 里没有 `uboot-2025` 包”）本身没算错，
错在只看了包名、没看 `PKG_NAME`。这条差异当时也看不到，因为 `fingerprint-exclude.conf` 同样排除了
这个目录——两个错误互相掩盖。

修复（四处，缺一不可）：`prune.conf` 规则清空；`fingerprint-exclude.conf` 把它纳入指纹；
装配第 10 步按 `bootloader/files` 叠加成审计树的样子（`OVERLAY_OK u-boot-2025 35852 files (+381)`，
与审计树逐文件相同、无重叠）；第 14 步加源码依赖断言，按选中包逐个检查
`local-development.mk` 需要的目录是否存在——同类问题以后在装配阶段就以 `rc=4` 停下，不会等到编译。

本地装配时 `github.com:443` 不可达，`luci` 的 `03c6023b` 是用 codeload 官方 tarball 重建的本地 Git
镜像提供的（重建树 `ea1ee2f1…` 与原 commit 相同，`hash-object` 复现出原 SHA）。这只是本机传输路径，
CI 上仍从 `github.com` 取同一 commit；内容是否一致由上面的指纹门禁证明。
