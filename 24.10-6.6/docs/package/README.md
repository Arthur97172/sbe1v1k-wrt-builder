# sources/ —— 源码目录

> **状态：已启用**（用户 2026-10-21 授权 **N-7**，进入 G1 取源阶段）

## 已取得的仓库

| 路径 | 内容 | 规模 |
|---|---|---|
| `qsdk14/` | QSDK 14 基座（**个人镜像**，仅 1 个提交） | 2.7 GB |
| `codelinaro/` | **官方** CodeLinaro 组件集，**66/77** 项按 manifest SHA 校验一致 | 2.6 GB |
| `luci/` | 官方 LuCI feed（`openwrt-24.10`，pin `d0400718…`，G3.6） | 325 MB |
| `apps/` | 十个用户自编 LuCI 应用（G3.7 五个 + 2026-11-07 追加五个，逐仓库固定 SHA，见 `PROVENANCE.md` §2.7） | 20 MB |

`codelinaro/` 的关键子集：

| 路径 | 内容 |
|---|---|
| `target-ipq/` | 官方 ipq95xx 平台目标（分支 `win.openwrt.24.10.r1`） |
| `oss-system-feeds-target-ipq/` | 同上的 **manifest pin** 版（建议基线） |
| `oss-kernel-linux-ipq-6.6/` | 内核 **6.6.147** |
| `oss-kernel-linux-ipq-files/` | DTS（121 个 `.dts`，**无 sbe1v1k**） |
| `oss-kernel-linux-ipq-patches-6.6/` | 1219 个内核补丁 |
| `oss-system-feeds-nss-{base,clients,apps}/` | **NSS 包定义**（OpenWrt Makefile 在这里） |
| `oss-system-feeds-wlan-open/` | ath11k / ath12k / mac80211 |
| `wifi-qca-wifi-oss/` | qcawifi 源码 —— **无 Makefile，不能作为包构建** |

**完整取源记录（SHA、tree 哈希、复核命令）见 [`PROVENANCE.md`](PROVENANCE.md)。**

## 重要结论

`everything411/qsdk` 的 `14.0` 分支**只有 1 个提交**（`parents` 为空），
是**一次性整树导入**，**不提供任何来源历史**。
因此它**不能作为可信基线**，仅作**对照快照**。

β 路线的可追溯基线为**官方 CodeLinaro 组件集**，现已全部取得：

```
target/linux/feeds/            ← oss/system/feeds/target/ipq          ✅
target/linux/feeds/files-6.6   ← oss/kernel/linux-ipq-files           ✅
target/linux/feeds/patches-6.6 ← oss/kernel/linux-ipq-patches-6.6     ✅
qca/src/linux-6.6/             ← oss/kernel/linux-ipq-6.6             ✅
qca/feeds/nss/{base,clients,apps-oss}
                               ← oss/system/feeds/nss-{base,clients,apps} ✅
qca/feeds/wlan-open/mac80211   ← oss/system/feeds/wlan-open           ✅（仅 ath11k/ath12k）
qca/src/qca-wifi/component_dev ← wifi/qca-wifi-oss                    ⚠ 只有源码，无 Makefile
```

> ⚠ **qcawifi 无法由公开源构建**：`kmod-qca-wifi-unified-profile` 在任何提交里都没有定义。
> 详见 `docs/G2_STATIC_CHECKS.md` §6。

## 硬性规则

- **不得执行**本目录内的任何代码（`make`、脚本、`feeds update` 一律禁止）。
- 提取的固件文件系统不得与本目录混合。
- 所有取源必须记录：来源 URL、分支、SHA、tree 哈希、时间。
- 任何改动 `PROVENANCE.md` 记录的操作都必须留痕，不得静默覆盖。
