# 24.10-6.6 源码装配（SOURCE ASSEMBLY）

本文回答一个问题：**`sources/` 里那棵能编译出固件的树，是怎么从公开上游和本仓库
那几百 KB 文本重建出来的**，以及凭什么说“重建出来的树就是当初审计过的那棵”。

- 装配入口：`scripts/ci/assemble-sources.sh`
- 打包入口：`scripts/ci/export-sources.sh`
- 验证入口：`scripts/ci/tree-fingerprint.sh` + `scripts/ci/check-config.sh`
- CI：`.github/workflows/sources-24.10-6.6.yml`（装配与发布）、
  `.github/workflows/build-24.10-6.6.yml`（消费 `sources-vN` 编译）

---

## 1. 一页流程

| # | 步骤 | 输入 | 断言 |
|---|---|---|---|
| 1 | 预检 | 工具、`upstream-pins.conf` 格式、磁盘 ≥ 25 GiB | pin 必须是 40 位 SHA、mode ∈ base/replace/overlay、恰好 1 个 base |
| 2 | 取上游 | 42 个 pin | `git init` + `fetch --depth 1 <commit>` + `checkout --detach`；`rev-parse HEAD` 必须等于 pin |
| 3 | 铺基座 | `everything411/qsdk@21a8d133` | `buildroot/Makefile` 存在；不带 `.git` |
| 4 | 剪裁 | `build/prune.conf` | 删除后路径确实不存在；**允许为空**，当前即为空（理由见 §3） |
| 5 | 替换组件 | pins 的 `replace`/`overlay` 行 | 按路径深度从浅到深 `rsync -a --delete`；files-6.6 = 504 文件、patches-6.6 = 1219 |
| 6 | P-B 板级补丁 | `build/p-b/SERIES` | 每条先 `--dry-run`，`--fuzz=0`，无 `.rej`；三条都只改已有文件，files-6.6 仍为 504 |
| 7 | 目标 feed 修正 | `build/target-feed-fixes/SERIES` | 同上 |
| 8 | 装配映射 | `build/assembly-map.conf` | 源存在；打完 files-6.6 仍为 525；DTS 含 `Spectrum SBE1V1K` 与 `sdhc_1`；`mmc.sh` 权限 744、SHA 固定 |
| 9 | Wi-Fi blob | `sbe-wifi-firmware/files/FILES-SHA256` | `sha256sum -c` 6/6；许可仍是 `LICENSE_REVIEW_REQUIRED` |
| 10 | 就地叠加 | `files-6.6/.` → `qca/src/linux-6.6/`；`bootloader/files/.` → `qca/src/u-boot-2025/` | 与两个包 Makefile 在解析期的 `cp` 一致；DTS 与 rtl8261n 落地；u-boot 叠加后恰好多出 381 个文件且无覆盖，`tools/sysupgrade.c` 在位 |
| 11 | 构建系统补丁 | `build/build-fixes/SERIES` + `build/openwrt-patches/` | 21 条：20 条 `tree` + 1 条 `package-patch`（`0023` 只把补丁拷进 dawn 包的 `patches/`，由 OpenWrt 在拉源码后应用；`package-patch` 的目标必须以 `/patches/` 结尾，且补丁文件与落点目录都必须已在 `known-delta.conf` 登记——这两条平台脚本都会断言，否则第 16 步必然 `FINGERPRINT_MISMATCH`）；procd 的 `0002` 由第 8 步整文件替换，不得再往包 `patches/` 追加 |
| 11b | LuCI 补丁 | `build/luci-patches/SERIES` | `tree` 模式，目标是 `sources/luci`（第 5 步整树替换之后）；`0018` 五条、`luci-patches/0001` 四条 grep 断言（其中一条断言 `rsn_override_key_mgmt` 的赋值行号早于 override 元素的发出行号）；`luci-patches/0002` 三条 grep 断言（频段表读 section `channels`、重建后恢复所选 band、空值不落盘） |
| 12 | 第三方树 | `thirdparty-feeds.conf` + `passwall-selected.conf` | passwall-selected 7 个包从新的 pin 重新派生；`thirdparty-feed` 10 个链接无悬空（2026-11-07 第二批加入 argon 主题）。2026-11-07 起装配不再打任何第三方补丁（wifihistory 专用补丁随应用删除） |
| 13 | feeds 接线 | `feeds.conf.in` + `feeds-links.conf` | 11 条 `src-link`、175 条 `package/feeds` 软链；无宿主绝对路径；每条目标有 Makefile |
| 14 | 冻结配置 | `build/config-frozen/` | `.config` 哈希；8 个 `CONFIG_FEED_*=y`；无 `uboot-2025`；`version.date=1792557977`；**选中包用到的 `qca/src` 本地树都在**（`MISSING_IMPLICIT`/`MISSING_EXPLICIT` 必须为 0） |
| 15 | 文档 | `docs/package/` | 拷成 `sources/README.md`、`sources/PROVENANCE.md` |
| 16 | 指纹 | `build/fingerprint-exclude.conf` | `--compare build/fingerprint/audited-24.10-6.6.tsv.zst`；未解释差异必须为 0 |

任何一步失败都会打印步骤名与最后 50 行日志。退出码：`2` SOURCE_UNAVAILABLE（pin
取不到）、`3` PIN_MISMATCH、`4` ASSERTION_FAILED、`5` FINGERPRINT_MISMATCH、
`6` SIZE_LIMIT（导出时）。`4` 有两处来源：脚本自己的 `die 4`，和 `trap on_err ERR`
的兜底（任何未预期的命令失败，打印 `FAIL step="…" rc=<真实 rc>` 后统一 `exit 4`）。
兜底**只应**接住真正意外的情况；预期内的非零返回必须写成 `cmd || rc=$?` 再判定，
不能用 `set +e`——`ERR` trap 的触发条件不看 `errexit`，`set +e` 挡不住它（2026-11-14
的 exit 5 就是这样被改写成 4 的）。

`SOURCE_UNAVAILABLE` 只在**重试之后**才判：每个 pin 最多取 3 次（间隔 5 秒，第三次
强制 `http.version=HTTP/1.1`，规避 TLS/HTTP2 framing 这类网络抖动）。重试仍失败就
停止，**绝不降级到分支头**——宁可这次装配失败，也不要产出无法归因的树。

三处顺序不能换，脚本里有注释：

1. **`target/linux/feeds` 整仓库替换要早于 `files-6.6`/`patches-6.6`**——它们
   `rsync --delete` 的目标是父目录，反过来会把刚铺好的子目录删掉。
2. **内核叠加层要在 files-6.6 装完之后**——叠加源就是装好的 files-6.6。
3. **第三方树要在 feeds 接线之前**——`feeds.conf` 的 `src-link thirdparty`、
   `passwall_selected` 与 17 条 `package/feeds` 链接的目标都在第三方位里。
4. **LuCI 补丁要在第 5 步整树替换之后**——`sources/luci` 由 pin 的 `replace`
   行整个覆盖，补丁打早了会被覆盖掉，且 `--dry-run` 不会报错（它打的是旧树）。

---

## 2. 输入清单

| 文件 | 作用 | 规模 |
|---|---|---|
| `build/upstream-pins.conf` | 42 个上游仓库的 dest/url/commit/mode | 每行一个 40 位 SHA，没有分支名、没有 latest、没有镜像回退 |
| `build/prune.conf` | 装配时整棵删除的路径 | 当前为空；曾删 `qca/src/u-boot-2025/`，2026-10-25 撤回（见 §3） |
| `build/assembly-map.conf` | 仓库内文件/目录 → 装配树位置 | rtl8261n、SBE DTS、base-files、本地包、6 个 blob、bandix-plus |
| `build/p-b/SERIES` | 板级补丁（镜像定义、DTS 注册、pwm） | 3 条，`tree` |
| `build/target-feed-fixes/SERIES` | `config-6.6`、`target.mk` 修正 | 2 条，`tree` |
| `build/build-fixes/SERIES` | 构建系统补丁 | 21 条：20 条 `tree` + 1 条 `package-patch`（`0023` → dawn 包的 `patches/`；0004、0007、0020 空号，见文件头） |
| `build/luci-patches/SERIES` | LuCI 树补丁（`sources/luci`） | 2 条，`tree`；`build-fixes` 的 `tree` 目标是 `buildroot`，够不到 luci |
| `build/openwrt-patches/package/system/procd/patches/0002-*.patch` | 替换上游同名补丁（rcS 上下文重排） | 1 个文件，由 `assembly-map.conf` 整文件覆盖 |
| `build/feeds.conf.in` | 11 条相对 `src-link` | 不含宿主路径 |
| `build/feeds-links.conf` | 175 条 `package/feeds/<feed>/<名字>` 软链 | 记**解析后**的目标，不记链接文本 |
| `build/passwall-selected.conf` | 从 passwall-packages 复制的 7 个包 | 纯拷贝，无 `.git` |
| `scripts/ci/refresh-pins.sh` | 把插件 pin 解析到最新 tag/分支头并只读检测内核；**不改内核 pin** | 每周由 `refresh-pins-24.10-6.6.yml` 运行，只开 PR 不合并 |
| `build/config-frozen/{.config,version,version.date}` | 冻结配置 | 4,874 行；`version.date=1792557977` |
| `build/local-packages/` | `sbe1v1k-defaults`、`sbe-wifi-firmware`（仅文本） | 6 个 blob 不提交 |
| `build/local-relayout/bandix-plus/` | 人工重排的 bandix-plus | 6 个文件 |
| `build/fingerprint-exclude.conf` | 指纹与导出共用的排除规则 | 133 条，逐条带注释 |
| `build/fingerprint/audited-24.10-6.6.tsv.zst` | 已审计树的逐文件指纹 | 194,808 条；压缩后 6.7 MB |

`build/known-delta.conf` 是允许保留的差异白名单。逐文件登记的有三条：`PROVENANCE.md`
（审计后对 §2.5/§2.5.1 的文档订正，差异只在文档行）、`README.md`（只是
`docs/package/README.md` 的装配副本，2026-11-07 把 apps/ 由五个订正为十个）与
`buildroot/openwrt-patches/package/utils/busybox/busybox.mk`（0017 注释掉 QSDK 的
busybox 配置覆盖，理由见 §3）。2026-11-07 另按 `any` 方向整树放宽了**插件树**
（`apps/*`、`thirdparty/*`、`thirdparty-feed/*`、`passwall-selected/*`、两条
`package/feeds` 软链前缀）：这些树不参与 QSDK/Wi-Fi/LuCI 的安全审计，完整性由
pin 文件里的 40 位 commit SHA 与 PR 评审保证，逐字节基线不再覆盖它们（理由与
补偿控制写在 `known-delta.conf` 的注释里）；QSDK 侧门禁一条没有放宽。
**任何未登记的差异都判失败**。
打包时写进包根的 `TREE-FINGERPRINT.json`/`.tsv` 不需要登记——指纹的默认子树清单
（`DEFAULT_SUBTREES`）本来就不含包根这两个文件名，它们由 `export-sources.sh` 的
tar 清单断言单独保证。

---

## 3. 为什么这样分层

- **补丁放三处，各有边界**：`p-b` 只放板级（镜像定义、DTS 注册、pwm）；
  `target-feed-fixes` 只放审计树里没有记录的两处差异（`config-6.6` 的 RTL8261N、
  `target.mk` 去掉 16 个 uboot 默认包）；`build-fixes` 只放构建系统与包 Makefile。
  同一改动不会在两处各写一遍。
- **内核 overlay 以整文件交付**，不对上游内核打补丁：上游 `files` 仓库里根本没有
  `drivers/net/phy/`，没有可 patch 的文件。`build/kernel-overlay/` 里放
  `Kconfig`、`Makefile` 与 `rtl8261n/` 18 个文件，装配时并入 files-6.6。
- **`qca/src/u-boot-2025` 必须保留，且要叠上 `bootloader/files`**：这棵树看着
  “不参与编译”（`.config` 里没有 `uboot-2025` 包），但
  `platform_utils/sysupgrade-helper` 的 `PKG_NAME` 就是 `u-boot-2025`，它经
  `include/local-development.mk` 把这棵树当源码编出镜像里的
  `/usr/bin/{mkimage,dumpimage}`。2026-10-25 曾按“不参与编译”把它剪裁并排除出指纹，
  结果 CI 构建在 1 小时后以 `sysupgrade-helper failed to build` 死掉，而指纹一声不响
  （run `40176273728`）。现在的做法：
  1. `prune.conf` 不删它；
  2. 装配第 10 步按 `bootloader/files/.` 叠加——审计树就是“基座 35,471 文件 +
     叠加新增 381 文件”，逐字节比对零内容差异、零覆盖、零删除；
  3. 它重新纳入指纹，任何出入都会被第 16 步看见；
  4. 第 14 步新增“源码依赖断言”：每个选中包若靠 `local-development.mk` 的
     `$(TOPDIR)/qca/src/$(PKG_NAME)`（或显式 `LOCAL_SRC`）取源码，那棵树必须在。
     目录缺失时该文件会静默退回 `PKG_SOURCE_PROTO:=git` + 空 `PKG_SOURCE_URL`，
     包在 1 秒内报 `No rule to make target …`，是一类极难从 CI 日志看出来的失败。
- **procd 的 `0002` 是整文件替换，不是追加**：上游 14.1 那份的 hunk #2 上下文是
  `const char *`，套到本版 14.0 的 procd 会失败。`build/openwrt-patches/…/0002-…patch`
  是重排上下文后的同一份补丁（代码不变），由 `assembly-map.conf` 覆盖上游同名文件——
  交付路径正是 `include/quilt.mk` 的 `FindPackage` 会扫描的 `openwrt-patches/**/patches/`。
  审计树当初是这么做的；**不能**再往 `package/system/procd/patches/` 放一份，否则同一段
  代码会被 `PATCH_DIR` 与 `openwrt-patches` 各打一遍。
- **QSDK 的 busybox 配置覆盖在审计树里从未生效，0017 如实复现这一点**：
  `openwrt-patches/package/utils/busybox/busybox.mk` 把
  `Package/busybox/overrideconfig` 指向它自带的 `Config.in`（进而
  `Config-defaults.in`：ARPING/TIMEOUT 默认 `y`、`FEATURE_EDITING_MAX_LEN=1024`）。
  但审计树的 `tmp/.packageinfo` 里没有这条 `Config:` 来源——`tmp/info/` 下
  `busybox` 的逐包扫描信息是在 overlay 落盘之前生成的缓存，之后没有失效——所以
  审计固件用的是 `CONFIG_BUSYBOX_CUSTOM=n` + OpenWrt 默认 applets
  （`build_dir/…/busybox-1.36.1/.config`：`EDITING_MAX_LEN=512`、无
  `CONFIG_TIMEOUT`），而 install 扩展（`inetd`/`inittab`/`rcS`）与 `patches/`
  当时都生效了（`ipkg-…/busybox/etc/init.d/inetd` 存在、`halt.c` 里有 edl 改动）。
  CI 每次都是全新扫描，会读到这条覆盖，把 39 个 `CONFIG_BUSYBOX_DEFAULT_*` 连同
  `TIMEOUT`/`EDITING_MAX_LEN` 一起翻成 QSDK 默认值——那就是另一个 busybox。
  0017 只注释掉 `overrideconfig` 一行，保留 install 扩展与补丁；两份
  `Config*.in` 仍在树里，只是不再被引用。`check-config.sh` 归一化 diff 为空
  就是这条结论的可执行证明。
- **不跑 `scripts/feeds update/install`**：它会生成带宿主绝对路径的 `.index`、
  `.targetindex` 与 `*.tmp/`。冻结配置里只有 8 个 `CONFIG_FEED_*=y`，与审计树一致。

---

## 4. 验证：三层证据

### 4.1 树指纹（强证据）

`tree-fingerprint.sh` 对每个路径输出一行：

```
path <TAB> mode <TAB> type <TAB> sha256 <TAB> - <TAB> 解析后的软链目标
```

按 `LC_ALL=C` 排序后整体取 SHA-256。三个归一化让审计树（本机 umask 002、绝对
软链、绝对 `feeds.conf`）与装配树（CI umask 022、相对软链、相对 `feeds.conf`）可比：

1. 权限抹掉组写位（`mode & ~022`）；
2. 软链只记**解析后的目标**，原始链接文本不参与哈希；
3. `buildroot/feeds.conf` 的 `src-link` 目标先规范成根内相对路径再哈希。

基线：`entries=194,808`、`aggregate=6273a00015badc0ccd35dde4138d6c4b35682779ebd00bfc96042cee40f6c224`
（171,955 个文件、22,495 个目录、358 个软链）。

装配树的 `aggregate` 与基线**必然**不同：整串行里只要有一行不一样，聚合值就变。2026-10-25 修好
`u-boot-2025` 之后本地装配得到 `aggregate=3b4a7c31…`，`--compare` 的 `deltas=2` 正是 `known-delta.conf`
里那两条；把基线 tsv 的这两行替换为装配版本重算，聚合值精确等于 `3b4a7c31…`——所以差异只有这两处，
没有第三处。**门禁看的是 `unexplained=0`，不是聚合值相等。**

> 2026-10-25 基线从 `156,058` / `2c8982d8…` 涨到 `194,808` / `6273a000…`：唯一原因是
> `qca/src/u-boot-2025/` 不再被排除（35,852 个文件 + 其目录）。撤掉排除的理由见 §3
> ——排除规则只能用来豁免“构建产物/宿主相关字节”，不能用来豁免一棵参与编译的源码树。

> 基线不含 11 个“审计时在树内就地编译/手工备份”的路径（luci-base 的
> `lemon`/`jsmin`/`po2lmo` 及其 `.o` 与 lemon 生成的 `plural_formula.c/.h`、
> `buildroot/.config.sbe-bak`、`qca-nss-ecm/Makefile.orig`）。它们不是源码，
> 装配树里不存在，已按逐条 `path` 规则排除，两侧对称。去掉这 11 条后，
> 新基线与旧基线（156,069 条）逐行相同。

排除清单不是“随便写几个 glob”：`tree-fingerprint.sh --check-exclusions` 会拿干净
上游（42 个 pin 中除基座外的 41 个，按各自 dest 前缀）跑一遍，**任何一条规则命中干净源码即
`EXCLUSION_TOO_BROAD`**。当前 133 条规则、`too_broad=0`。这条闸门保证 `*.pem`
（selftests 签名键）、`*.map`、`*.scr`、`lib/test_fortify/` 这类“看起来像产物、
其实是源码”的文件不会被误排。

`.git` 被排除：装配树里 checkout 出来的 pack 字节与审计树永远不同，而每棵树的
身份由 pin 的 40 位 commit、装配时的 `rev-parse HEAD` 断言与 `recipe_sha256`
共同钉住——比 `.git` 的字节更强。

### 4.2 配置等价（包集合证据）

`check-config.sh` 在源码树里跑 `make defconfig`，把结果与冻结 `.config` 都归一化成
“`CONFIG_x=y` / `# CONFIG_x is not set` 两种行、排序”，逐行 diff 必须为空。
它挡住的是“树能装出来，但镜像里少了一个包”这种最隐蔽的漂移。

跑 `defconfig` 之前还有一条更硬的前置断言：源码包里的 `.config` 必须与
`build/config-frozen/.config` **逐字节相同**（装配时写进去的就是这一份）。不相等
说明包是旧配方装的，此时归一化 diff 有可能仍然为空，但构建用的配置已经不是被
审计过的那份，所以当场停下、要求重发 `sources-vN`，而不是等到最后才发现。

### 4.3 配方哈希（来源证据）

`recipe-hash.sh` 把决定源码树长相的所有文本输入排序后整体取 SHA-256，写进
`TREE-FINGERPRINT.json` 的 `recipe_sha256`。同一份配方 + 同一批 pin 必须得到同一个
树指纹；不同配方得到同一个指纹，说明有输入没被登记。

### 4.4 导出断言（包与指纹对称的证据）

`export-sources.sh` 打出 tar 之后，先解出**一份**成员清单（`tar -tf` 一次，避免
194k 条目重复解压），然后做三类断言：

- 包根必须有 `TREE-FINGERPRINT.json` 与 `.tsv`，且与 `--stage` 的 `fingerprint.*`
  是同一份（`cp` 而来，构建端用它做 `--compare`）；
- **对称性**：`tar` 成员数必须等于指纹条目数 + 3（根目录 `./` 加两份包根副本）。
  两侧共用同一份排除清单，任何一条规则只在一边生效都会在这里不等；它同时说明
  包里没有夹带指纹之外的构建产物；
- 反向断言：`.git/`、`build_dir/`、`dl/`、`staging_dir/`、`tmp/`、`feeds/*.tmp/`
  不得出现在包内（拼错的排除规则会让包悄悄胖 1 GB）；资产恰好 3 个，tar < 1.9 GB。

---

## 5. 怎么复现

```bash
# 本地全量装配（不碰 sources/，输出到 /var/tmp）
./24.10-6.6/scripts/ci/assemble-sources.sh --stage /var/tmp/sbe-assemble
# 只打包
./24.10-6.6/scripts/ci/export-sources.sh --stage /var/tmp/sbe-assemble --out /var/tmp/dist
# 消费端验证（解包后）
./24.10-6.6/scripts/ci/tree-fingerprint.sh --root /var/tmp/x/sources \
  --exclude 24.10-6.6/build/fingerprint-exclude.conf \
  --out /tmp/fp.json --tsv /tmp/fp.tsv \
  --compare /var/tmp/x/sources/TREE-FINGERPRINT.tsv \
  --known-delta 24.10-6.6/build/known-delta.conf
```

CI 上的等价流程见 `docs/CI_BUILD.md` 与两个 workflow 文件。

---

## 6. 已知耦合与限制

| 项 | 说明 |
|---|---|
| **qsdk 基座不可信** | `everything411/qsdk` 是单提交的个人镜像。它只用于复现已审计字节；kernel、target feed、files、patches、NSS 组件都已换成 CodeLinaro 固定提交。`PROVENANCE.md` 如实标注，不声称“来自厂商”。 |
| **24.10 依赖 25.12 的 blob** | 6 个厂商 Wi-Fi blob（16 MB）只在 `25.12-6.12/build/local-packages/sbe-wifi-firmware/files/` 提交了一份，装配时按 `assembly-map.conf` 拷入。任一版改 blob 都要同步两边的 `FILES-SHA256`。 |
| **许可** | 6 个 blob 的状态是 `LICENSE_REVIEW_REQUIRED`，不因来源是本仓库而改变。 |
| **busybox 按审计行为构建** | QSDK 的 `Config-defaults.in`（ARPING/TIMEOUT 默认开启、编辑行长 1024）在审计固件里从未生效，0017 把那条覆盖注释掉了。要启用这些 applet，应在 `build/config-frozen/.config` 里显式打开对应 `CONFIG_BUSYBOX_DEFAULT_*` 并重走审计；只删 0017 等于悄悄换回 QSDK 默认值、改变固件行为，同样需要新的审计基线。 |
| **不打包 `dl/`** | 源码包不含第三方 tarball 缓存；构建端先跑 `make -k download`，失败清单进 `download-fail.txt`。 |
| **不承诺固件逐字节可复现** | 指纹只证明源码树与审计树一致。工具链版本、opkg 签名密钥（CI 每次生成新的）、时间戳都会让镜像字节不同。 |
| **zip/tar 资产上限** | Release 单资产 2 GB；导出断言 < 1.9 GB，超了直接 `SIZE_LIMIT`。 |

---

## 7. 改哪里（速查）

| 想做的事 | 改哪里 | 之后 |
|---|---|---|
| 调镜像分包/体积 | `build/p-b/patches/0001-*.patch` | 重跑装配，指纹会变 → 需要发布新的 `sources-vN` |
| 改 DTS | `build/p-b/files/arch/arm64/boot/dts/qcom/ipq9574-sbe1v1k.dts` | 同上 |
| 改升级/槽位脚本 | `build/p-b/files/base-files/lib/upgrade/` | 同上 |
| 改内核配置 | `build/target-feed-fixes/0001-config-6.6-enable-rtl8261n.patch` | 同上 |
| 加/去掉软件包 | `build/config-frozen/.config` + `scripts/custom-packages.sh` | `check-config.sh` 必须 PASS |
| 升上游组件 | `build/upstream-pins.conf` 的 commit 列 | 装配后与基线比对，差异必须能用已知原因解释 |
| 加第三方包 | `build/thirdparty-feeds.conf` + `build/feeds-links.conf`（+ `custom-packages.conf`、`config-frozen/.config`、`known-delta.conf`、装配步的软链条数断言；逐步操作见 `README.md`「新增第三方 LuCI 插件」） | `thirdparty-feeds.sh check` PASS、`FINGERPRINT_MATCH`、`check-config.sh` PASS |
| 调 passwall 选包 | `build/passwall-selected.conf` | 重跑装配 |
| 改指纹排除 | `build/fingerprint-exclude.conf` | 必须 `--check-exclusions` 无 `EXCLUSION_TOO_BROAD` |

改完装配输入后：本地装配一次 → 指纹与基线比对 → `check-config.sh` →
`workflow_dispatch` 跑 `sources-24.10-6.6.yml`（先 `publish=false` 验证）→
`publish=true` 发 `sources-vN` → 构建 workflow 的 `source_tag=auto` 会自动捡到它。
