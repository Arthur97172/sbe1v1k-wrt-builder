# 本地审计与装配验证报告（24.10-6.6）

日期：2026-10-25　范围：24.10-6.6 的源码装配、指纹门禁、导出与消费者侧校验。
本文件是工作文档，**不提交**。

## 0. 阶段边界（合规声明）

- 未连接路由器 `192.168.10.142`，未尝试登录，未扫描端口，未执行任何远程命令。
- 未把任何密码写入文件、日志、命令参数或 git。
- 本报告**不**声称固件可启动或可刷写；所有镜像相关结论仍是 `UNVERIFIED` / `NOT TESTED`。
- 25.12-6.12 的 NSS 自产改造（计划 P7）本轮**未开始**。

## 1. 结论摘要

| 事项 | 状态 |
|---|---|
| 装配配方可重复（同一配方装配两次） | PASS |
| 装配树与审计树逐文件一致（除 2 条已解释差异） | PASS |
| 冻结 `.config` 等价门禁 | PASS |
| 导出可重复（同一 stage 导出两次字节相同） | PASS |
| 消费者侧（解包）五道门禁 | PASS |
| GitHub Actions 实际运行 | NOT TESTED |
| 干净编译与镜像静态校验 | NOT TESTED |
| 真机启动/升级 | NOT TESTED |
| 6 个厂商 Wi-Fi blob 许可 | LICENSE_REVIEW_REQUIRED |

## 2. 关键数值

| 项 | 值 |
|---|---|
| 指纹条目 | `entries=156058`（files 136103 / dirs 19654 / links 301） |
| 装配树聚合指纹 | `a6a662ddb887f5c9cd768bdefdd138d5eda3ad6e09f40f50ee6c1feaad9deb91` |
| 审计基线聚合指纹 | `2c8982d8…b5250e`（差 2 条 known-delta，见 §3） |
| 与基线比对 | `deltas=2 explained=2 unexplained=0` |
| 配方哈希 | `eb8c4f93b9712b0f3a3fba67dd001dad86327ed0ba216b7dfe4758642eaeb2fc`（59 个输入） |
| 源码包 | `d39a67a2aa758ec9a71fe3716e21d27a09c478d4d9d8aea1e2d1c8626b6eb4cc`，228,502,877 B（= 228 MB） |
| 包内资产数 | 恰好 3（tar.zst、SHA256SUMS、TREE-FINGERPRINT.json） |
| tar 成员数 | 156061 = 指纹条目 156058 + 3（根 `./` + 两份指纹副本） |
| 冻结配置 | `lines=2128`，`sha256=e9ee2f72df4e97a1a4e05aa785c2b533456bf3f6e0734bcf186edb79651506ab`，`feeds=8` |

两条已解释差异：

1. `PROVENANCE.md` — 审计后只改文档行（§2.5 / §2.5.1）。
2. `buildroot/openwrt-patches/package/utils/busybox/busybox.mk` — 新补丁 0017（见 §3）。

## 3. 本轮源码变更：0017 去掉 QSDK 的 busybox 配置覆盖

**根因**：QSDK 的 `openwrt-patches/package/utils/busybox/busybox.mk` 里有
`Package/busybox/overrideconfig`，它会被并进 busybox 包元数据里的 `Config:` 块。审计构建时
`tmp/info/.packageinfo-busybox` 是在该 overlay 加入之前生成的、之后没有再失效，所以这条覆盖
**从未在审计固件里生效**：审计镜像的 busybox 是 `CONFIG_BUSYBOX_CUSTOM=n` + OpenWrt 默认
（`EDITING_MAX_LEN=512`、无 `CONFIG_TIMEOUT`、261 个 `=y`）。

**后果**：CI 里是全新扫描，会读到这条覆盖，把 39 个 `CONFIG_BUSYBOX_DEFAULT_*` 连同
`TIMEOUT` / `EDITING_MAX_LEN` 一起翻成 QSDK 默认值 —— 那是另一个 busybox。

**修复**：0017 只注释掉 `Package/busybox/overrideconfig` 这一行；同一文件里的
`Package/busybox/install` 扩展（inetd / inittab / rcS，审计构建里确实生效过）与
`patches/` 原样保留。

**证据**：
- 补丁见 `build/build-fixes/0017-openwrt-patches-busybox-drop-config-override.patch`；
- 已在 `build/build-fixes/SERIES` 与 `build/known-delta.conf` 登记；
- 装配后 `check-config.sh` 归一化 diff 为空（PASS），即装配出的包集合与冻结配置一致；
- `docs/SOURCE_ASSEMBLY.md` §3/§4.2、`docs/CI_BUILD.md` 已同步说明。

同时 `check-config.sh` 加了一条前置断言：源码包里的 `.config` 必须与
`build/config-frozen/.config` 逐字节相同，否则在跑 `defconfig` 之前就失败并提示重发
`sources-vN`；结束时用冻结文件覆盖回 `.config` 并复核哈希。

## 4. 验证记录

### 4.1 装配（V1 / V2）

- 同一配方装配两次，聚合指纹相同（`a6a662dd…`），说明装配本身确定；
- 16 步断言全 PASS：pin 校验、内核叠加 82324 文件、15 条 build-fixes、6/6 Wi-Fi blob、
  10 条 src-link、156 条 package links、11 条 thirdparty 软链、wifihistory 稀疏检出 43 文件；
- 与审计基线 `--compare`：`FINGERPRINT_MATCH`，未解释差异 0。

### 4.2 配置门禁（V3）

- 装配树：先 `render-overlay.sh`，再 `check-config.sh` → PASS；
- 解包后的消费者树同样 PASS（见 4.4）。

### 4.3 导出（V5 本地部分）

- `export-sources.sh` 对同一 stage 导出两次到 `/var/tmp/dist3a`、`/var/tmp/dist3b`；
- 两次产物逐字节相同：`d39a67a2…`，228,502,877 B，`TREE-FINGERPRINT.json` 也逐字节相同；
- 体积 228 MB，远低于 1.9 GB 断言；
- `sha256sum -c SHA256SUMS` → OK；资产恰好 3 个。

### 4.4 消费者侧（用导出的包在全新目录解包）

| 门禁 | 结果 |
|---|---|
| 1 校验和 | PASS |
| 2 指纹 `--compare sources/TREE-FINGERPRINT.tsv` | PASS，`deltas=0` |
| 3 `recipe-hash.sh` 与包内 `recipe_sha256` | PASS（`eb8c4f93…`） |
| 4 `render-overlay` + `check-config.sh` | PASS（`lines=2128`，`feeds=8`） |
| 5 `thirdparty-feeds.sh check`（`SBE_NO_GIT=1`） | PASS（13 条软链；11 个第三方目录在） |
| 6 `download-preflight.sh`（`make -k download`） | NOT TESTED |

第 6 道门禁没跑：本机 `github.com:443` 不可达，跑出来的失败不能代表 GitHub runner，
记为 `NOT TESTED`，留给 V6。

## 5. 环境限制与本机变通（不影响 CI）

- 本机 `github.com:443` 超时（`github.com:22` 开放但无密钥）；`git.codelinaro.org`、
  `codeload.github.com` 可达。
- 为完成本机装配，第三方仓库用 `GIT_CONFIG_*` 的 `url.<本地路径>.insteadOf` 重定向到
  `sources/thirdparty/` 下的本地克隆（仅本机进程环境，不写入任何 git 配置或文件）。
- `luci` 的 `03c6023b` 在该克隆里是 **blob:none 部分克隆**，无法作为服务端提供完整对象
  （`bad pack header`）。改用 codeload 的官方 tarball 重建本地镜像：
  - 重建出的树 `ea1ee2f1c4840ad2e5ba10383f57eaa90913a142` 与原 commit 的 tree **相同**；
  - 用原 commit 对象原文写入，`git hash-object` 复现出 `03c6023b…`（COMMIT_MATCH）；
  - 镜像仅放在 `/var/tmp/wh-mirror`，不进入仓库、不进入源码包。
- CI 上这些仓库仍然从 `github.com` 取同一固定 commit；本机取的字节是否相同，由
  §4.4 的指纹门禁（`deltas=0`）和 pin 断言证明。

## 6. 未完成 / 需要批准

| 项 | 状态 | 说明 |
|---|---|---|
| 工作区改动 push 到 GitHub | BLOCKED（需要用户现场提供 PAT） | PAT 只作 `GH_TOKEN=…` 环境变量前缀 |
| 运行 `sources-24.10-6.6.yml`（`publish=false`，再 `publish=true` 发 `sources-v2`） | NOT TESTED | 需先 push |
| 运行 `build-24.10-6.6.yml`（`source_tag=auto`） | NOT TESTED | 约 3 小时，含第 6 道下载门禁与编译 |
| 镜像静态校验 `verify-image.sh` | NOT TESTED | 在 CI 编译产物上跑 |
| 25.12 NSS 自产（P7） | NOT TESTED | 本轮未开始 |
| 路由器侧任何操作 | 未做 | 本阶段禁止，需另行批准 |

## 7. 建议的下一步（等确认后执行）

1. 你批准后，用现场提供的 PAT push 当前工作区改动（含 0017、`SERIES`、`known-delta.conf`、
   `check-config.sh`、两份文档）；
2. 先跑 `sources-24.10-6.6.yml` `publish=false` 看装配与指纹是否在 runner 上复现；
3. 通过后再 `publish=true` 发布 `sources-v2`；
4. 最后跑 `build-24.10-6.6.yml` `source_tag=auto`，验证第 6 道门禁、编译与 `verify-image.sh`；
5. 以上任一步失败，回到本地修复，不放宽判据。
