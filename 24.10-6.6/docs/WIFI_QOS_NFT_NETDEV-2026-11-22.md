# v115-2 真机验证：kmod-nft-netdev 修复 wifi_qos 空表（2026-11-22）

镜像：`24.10-6.6-v115-2-bf3a1945`（commit `bf3a19453b35`，sources-v33，
banner `24.10-SNAPSHOT (sbe1v1k-g3.5c)`，Linux 6.6.147）
sysupgrade：82,576,166 B，sha256
`8cd19e72a5fa64b1cffe73b09f9172faf1b96bd76a03b92ce93ec1686c579529`

## 结论

`kmod-nft-netdev` 已在镜像中并**功能生效**：QSDK hostapd 的 SCS 对三个 BSS
各建出一条 `netdev` egress 链，`nft list tables` 里出现
`netdev wifi_qos_table` 且非空；临时 egress / ingress 链创建均 rc=0。
此前 v83 的真机现象（表存在但为空、hostapd 报 Failed to create chain）
**PASS 闭环**。WiFi/DHCP/NAT/LuCI 回归无异常。

## 设备与流程

- 设备：唯一在线 SBE1V1K，`192.168.1.1`（br-lan MAC `90:d3:cf:4b:eb:83`），
  管理走主机 WiFi `wlp0s20f3` 192.168.1.230；刷前运行 25.12 v89-1。
- 上传：`ssh 'cat > /tmp/fw115.bin'`（无 sftp-server），设备 sha256 与
  Release 记录逐字节一致；`sysupgrade -n`，约 1 分 40 秒后 SSH 可登。
- 测试结束后刷回 25.12 v89-1（`/tmp/fw89.bin`，sha256 `612d4423…ef5d9f`），
  banner 恢复 `sbe1v1k-25.12-ca795749`，eth1 拿到 DHCP `192.168.10.243`。

## 验证结果（只读命令 + 两次可回退的 nft 探针）

| 检查点 | 结果 |
|---|---|
| `opkg list-installed \| grep nft` | `kmod-nft-core 6.6.147-r1`、`kmod-nft-netdev 6.6.147-r1` 均 `install ok installed` |
| 模块文件 | `/lib/modules/6.6.147/{nf_dup_netdev,nft_dup_netdev,nft_fwd_netdev}.ko` 齐全 |
| `lsmod` | `nf_dup_netdev` 被 `nft_fwd_netdev,nft_dup_netdev` 引用；`nft_fwd_netdev` 已装载；`nf_tables` 引用表含 `nft_dup_netdev`/`nft_fwd_netdev` |
| `nft list tables` | `table inet fw4`、**`table netdev wifi_qos_table`** |
| `nft -a list table netdev wifi_qos_table` | 三条链：`wifi_qos_chain_phy00.0-0`、`phy00.2-0`、`phy00.1-0`，均为 `type filter hook egress device "<iface>" priority filter; policy accept;`（handle 1/2/3） |
| 启动日志 | hostapd 六条 `NFT: ... created successfully`（表 1 + 每 BSS 链 3，成对打印）；**无 `Failed to create chain`**；MSCS 回调 register/unregister 正常 |
| egress 功能探针 | `nft add table netdev sbe_egress_probe` + `add chain … { type filter hook egress priority 0; }` → rc=0，回读成功，随后删除 rc=0 |
| ingress 功能探针 | `add chain … { type filter hook ingress device "eth2" priority 0; }` → rc=0，随后删除 rc=0 |
| 内核/dmesg | 无 `nf_tables_netdev` 或 nft 相关 error/fail 行 |
| 网络回归 | eth1 DHCP `192.168.10.241`，默认路由 192.168.10.1，设备 ping 网关 2/2；主机经路由器 ping 上游网关 2/2（NAT 数据面正常） |
| LuCI | `http://192.168.1.1/` 200；`/cgi-bin/luci/` 未登录 403（预期） |
| 无线 | 三 BSS `phy00.0-0/1-0/2-0`（WiFi_2.4G/5G/6G）UP；主机经 WiFi 关联，ping br-lan 2/2（约 4 ms） |

说明：

- SCS 链当前为空是设计行为——只有发起 MSCS/SCS 请求的 QoS 客户端才会被
  添加规则；本次验证的是链能建出来（即内核 egress 钩子可用）。
- 两个探针表用完即删，设备上未留配置；刷回 25.12 后 24.10 现场全部消失。
- 证据与刷机脚本：`logs/v115-2-verify/`（gitignore：`fw115.bin`、
  `device-evidence.txt`、`verify24*.sh`、`restore89.sh`）。

## 后续

25.12-6.12 同因缺 `CONFIG_NETFILTER_EGRESS`（generic `config-6.12:3986`
显式 `# CONFIG_NETFILTER_EGRESS is not set`），本日已按同一结论在
`build/config-seed/ipq95xx-spectrum-sbe1v1k.seed` 加
`CONFIG_PACKAGE_kmod-nft-netdev=y`（并列入 `required-packages.txt`），
待 CI 构建后按本页判据复验。顺带受益：该包的 KCONFIG 同时把
`CONFIG_NETFILTER_INGRESS` 翻成 y（25.12 未选 `kmod-nf-flow`，此前
ingress 也未开），两个探针口径同样适用。
