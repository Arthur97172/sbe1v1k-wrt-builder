# CI 构建流水线（24.10-6.6）

本文件说明 GitHub Actions 上的两个 workflow 各自做什么、用什么证明“编译的就是已审计的源码”，
以及出问题时应先看哪一道门禁。装配配方本身见 [SOURCE_ASSEMBLY.md](SOURCE_ASSEMBLY.md)。

> 状态：装配 workflow 已在 Actions 上跑通并发布 `sources-v2`（PASS）；构建 workflow **尚未**
> 完整跑过（`NOT TESTED`）。本地已完成的验证见文末“已验证 / 未验证”。

## 1. 为什么是两个 workflow

单次编译约 3 小时、需要 25 GB 以上磁盘；装配同样要克隆 4.6 GB 上游、生成 2.2 GB 源码树。
拆成两段后：

| workflow | 文件 | 做什么 | 产物 |
|---|---|---|---|
| 🧱 Assemble | `.github/workflows/sources-24.10-6.6.yml` | 从 37 个固定提交装配源码树、比对指纹、打包 | Release `sources-vN`：**恰好 3 个**资产 |
| 📦 Build | `.github/workflows/build-24.10-6.6.yml` | 下载源码包、六道门禁、编译、发布固件 | Release `v<run>-<attempt>-<sha8>`：**恰好 3 个**镜像 |

改补丁/配置只需 push：装配 workflow 重新验证（可选发布新 `sources-vN`），构建 workflow 用
`source_tag=auto` 自动取最新可用的源码包。**不再需要人工上传任何文件。**

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
| 📦 Build 在 Actions 上运行 | NOT TESTED（最近一次 `40171593136` 停在 `Resolve source tag`：当时还没有 `sources-v2`） |
| 编译产物在真机启动/升级 | NOT TESTED |
| 6 个厂商 Wi-Fi blob 的许可 | LICENSE_REVIEW_REQUIRED |

发布包由 runner 产出，`sbe1v1k-sources-24.10-6.6.tar.zst` 为 228,711,892 B；本地两次导出的
是 228,502,877 B。两者**条目级指纹完全一致**（上面的 `entries`/`aggregate`/`recipe` 三项相同），
字节差来自打包时的 zstd 版本差异，不是内容差异——这也是为什么门禁比对的是指纹而不是包哈希。

本地装配时 `github.com:443` 不可达，`luci` 的 `03c6023b` 是用 codeload 官方 tarball 重建的本地 Git
镜像提供的（重建树 `ea1ee2f1…` 与原 commit 相同，`hash-object` 复现出原 SHA）。这只是本机传输路径，
CI 上仍从 `github.com` 取同一 commit；内容是否一致由上面的指纹门禁证明。
