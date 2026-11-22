# 25.12 v90-1 真机验证：kmod-nft-netdev 内核侧 PASS；wifi_qos SCS 在 25.12 不存在（2026-11-22）

镜像：`25.12-6.12-v90-1-ca2a5d5d`（commit `ca2a5d5`，banner
`sbe1v1k-25.12-ca2a5d5d`，Linux 6.12.112），sysupgrade sha256
`0c754db93420f659823c28debc7b84d3156d46571b0facbb19bbedca70ab23d0`，
`sysupgrade -n` 刷入。本轮启动 eth0 健康（2.5G，ping 0.4 ms，无
`autoneg time out`）。证据：`logs/v90-1-kmod-nft-netdev/`（gitignore）。

## 结论

1. **kmod-nft-netdev 已在镜像并功能生效（内核侧 PASS）**：apk 数据库有
   `kmod-nft-netdev 6.12.112-r1`，`nft_fwd_netdev.ko / nft_dup_netdev.ko /
   nf_dup_netdev.ko` 齐全且已装载；临时 egress / ingress 链探针均 rc=0
   （与 24.10 v115-2 判据同口径）。`CONFIG_NETFILTER_EGRESS` 已由此包的
   KCONFIG 强制翻 y。
2. **但在 25.12 上不会出现 `netdev wifi_qos_table`——因为 25.12 的 hostapd
   根本没有 SCS/netdev egress 功能**。设备上的 hostapd 是官方 feed 的
   upstream `wpad-mesh-mbedtls 2025.08.26`（hostapd v2.12-devel），
   `nft list tables` 只有 `inet fw4`，hostapd 日志无任何 `NFT:` 行（也没有
   失败行）；25.12 装配树的 hostapd 源码里 `NETDEV_EGRESS|wifi_qos|scs`
   grep 全空。24.10 的 wifi_qos 链来自 **QSDK hostapd fork**
   （`sources/buildroot/qca/src/network/services/hostapd` +
   `qca/feeds/wlan-hostapd` 的 `r92-08-…hostapd-add-support-for-scs-…`
   补丁），25.12 装配树没有这部分代码。
3. 所以对 25.12 而言，「wifi_qos 空表」的准确口径是 **wifi_qos N/A**：
   内核包是必要但不充分条件；要等 QSDK 6.12 wlan-open / hostapd fork 接入
   25.12 后，SCS 链才会出现（届时内核侧已经就绪，无需再改）。该包保留：
   它是 egress hook 的唯一开关注入，并顺带把 `CONFIG_NETFILTER_INGRESS`
   打开，对其它 netdev 钩子（如 `kmod-nf-flow` 未选时）也是净收益。

## 验证记录

| 检查点 | 结果 |
|---|---|
| `apk list --installed \| grep nft` | `kmod-nft-netdev 6.12.112-r1 [installed]`（另有 core/fib/nat/offload/socket/tproxy） |
| 模块文件 | `/lib/modules/6.12.112/{nf_dup_netdev,nft_dup_netdev,nft_fwd_netdev}.ko` 齐全 |
| `lsmod` | `nf_dup_netdev` 被 `nft_fwd_netdev,nft_dup_netdev` 引用；`nf_tables` 引用它们 |
| `nft list tables` | 只有 `table inet fw4`（**无** `netdev wifi_qos_table`） |
| hostapd 日志 | 无 `NFT:` 行、无 `Failed to create chain` |
| egress 探针 | `add table netdev sbe_egress_probe` + egress 链 → rc=0，删除 rc=0 |
| ingress 探针 | `add table netdev sbe_ingress_probe` + ingress(eth2) 链 → rc=0，删除 rc=0 |
| hostapd 身份 | `/usr/sbin/hostapd -v` = v2.12-devel；包 `wpad-mesh-mbedtls-2025.08.26~ca266cc2-r6`（feeds/base upstream） |
| 25.12 hostapd 源码 | `build_dir/.../hostapd-2025.08.26~ca266cc2/src` 无 `scs`/`NETDEV_EGRESS`/`wifi_qos` |
| 24.10 对照 | SCS 代码在 `sources/buildroot/qca/src/network/services/hostapd` 与 `qca/feeds/wlan-hostapd` 的 r92-08 补丁里 |

说明：dmesg 里 67–68 s 的 `reset_control` WARNING 与 `ssdk_uniphy …
reset(1)/(3)/(5) not exist` / `set parent fail` 是已知噪声（好/坏启动都有，
见 `docs/ETH0_XPCS_AN_BOOT_2026-11-22.md`），与本轮无关。

## 后续

- 25.12 不再以「wifi_qos 空表」作为缺陷跟踪；转为在
  `docs/NSS_WIFI_OFFLOAD_QSDK_TRACKING.md` 的 QSDK 6.12 wlan-open 判据里
  附注「接入 hostapd fork 后复验 SCS 链」。
- 24.10 结论（v115-2 PASS）不变：QSDK hostapd 建链依赖的内核钩子已就绪。
