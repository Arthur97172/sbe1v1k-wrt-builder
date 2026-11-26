# 25.12-6.18 固件审计与有线 NAT 压测（2026-11-25）

状态：审计 **PASS**；压测结果见 §4。

被测镜像：`OpenWrt SNAPSHOT sbe1v1k-6.18-fddb6d8a`（Linux 6.18.64，
QSDK NSS 构建 11/25 02:42），对应仓库 HEAD `fddb6d8`（含 11-24 角色切换
三场景 PASS、af55d59 board.json 修复、S95 eth0 AN 看门狗、S4 tier=full）。

现场拓扑：主机 USB 2.5G 网卡（enxc84d4424a1b5, 192.168.1.2）接路由器
eth0（10G 口，LAN）；路由器 eth1（2.5G）为 WAN，接上游 Spectrum 网关
（DHCP 192.168.10.237，网关 192.168.10.1，无 IPv6）；主机 WiFi
（192.168.1.230）经路由器 AP 作管理通路。

## 1. 核心状态（全部 PASS）

- 版本/内核：SNAPSHOT sbe1v1k-6.18-fddb6d8a / 6.18.64。
- 链路：eth0 2500 Mbps 真链路（carrier=1，对端同样 2500）；eth1 WAN
  2500 Mbps、DHCP 租约 192.168.10.237、默认路由经 192.168.10.1。
- 角色：`sbe-port-roles status` 报 wan_port=eth1、br-lan 含 eth0/eth2/eth3，
  `board.json 与角色一致`；ssdk port5 member=0x1、port6 member=0x19。
- MAC：eth0/eth1/eth2/eth3 = :81/:82/:83/:84，互不冲突；br-lan 取 :83。
- 无线：3 个 AP 接口 up；`WiFi_6G` 在 wl0.0-ap0，ch37（6.135 GHz）
  EHT320、Tx-Power 23 dBm；2.4G 接口有 1 个关联客户端（管理用主机）。
- 服务：dnsmasq / odhcpd / dawn / firewall(fw4, inet fw4 34 chains) 均在跑；
  本机 DNS 经 127.0.0.1 解析正常（上游返回 fake-IP 198.18.x，属现场环境）。
- NSS：tier=full（ecm + qca_nss_ppe* + qca_nss_sfe + qca_nss_dp 全载），
  `ECM init complete`（开机脚本一次 exit 后重新 init，属正常重载）。
- 资源/热：内存 2024 MB（可用 ~1.36 GB），负载 <0.2，SoC 温度 ~41–42 °C，
  风扇 pwm1=119（低转速），均正常。

## 2. 日志噪声分类（无新 bug，全部有既有结论）

| 现象 | 次数 | 性质 |
|---|---|---|
| `ssdk_uniphy_reset: reset(1/3/5) not exist!` | 4 | 6.12 好启动同样存在，0040 后剩 3 条 reset-core WARN 是设计内基线（WIRED-DATAPATH-DEVICE-TEST §4） |
| `ssdk_uniphy_raw_clock_set / port5_clock_source_set: set parent fail!` | 4+2 | SGMII+ 子模式正常形态，125 MHz 时钟假设已在 11-23 排除（S3E、WIRED-DATAPATH-PROJECT） |
| `__reset_control_get_internal` WARN | 3（9 行） | 同上是 0040 设计内 xpcs 复位所有权基线 |
| ath12k `qmi dma allocation failed (29360128 B)` ×3、`WMI MAC1 connect failed` | 3 | S1b/S3D 已记录：大池失败后小尺寸重试成功，三频 AP 最终全 up |
| `edma_cfg_rx_qid_to_rx_desc_ring_mapping: Failed to initialize VP to queue map (0)` | 1 | DTS 未声明 `qcom,rx-vp-rings`（CAPWAP/DTLS VP offload 不用），`edma_cfg_rx.c` 的 default 分支告警，功能无关 |
| `nf_conntrack_ecache.c:281 WARN_ON_ONCE` | 1 | 11-23 已记录为基线噪声 |
| `wan6: eth1: error connecting LLA socket` ×13 / `Failed to send SOLICIT` | 开机一次 | 上游网关无 IPv6（11-20 取证）；eth1 有 LLA、odhcp6c 保持 pending 后静默，属环境噪声 |

结论：**没有需要修复的新 bug**。另有一项与 24.10 的差异值得记录：
6.18 的 eth0 PHY 由主线 `RTL8261BE 10Gbps PHY` 驱动接管，开机打印
`PMA low-power suspend disabled`（90000.mdio-1:00）——24.10 假环回的根因
（suspend 断电后 resume 不重做 config_init）在 6.18 驱动模型下不存在，
11-24 的 live 角色切换三场景 PASS 与该结论一致。

## 3. 压测可行性与设计

拓扑完全支持 WAN 侧 NAT 压测：主机 → eth0（LAN）→ 路由器 → eth1（WAN）
→ 上游网关 → 互联网。早期用 `speed.cloudflare.com` 只测到 ~12 Mbps，
是现场 fake-IP 代理对该域名的限速，不是链路能力；改用
`proof.ovh.net/files/100Mb.dat` 单流实测 ~11.7 MB/s（≈94 Mbps）。

压测形状对齐 24.10 楔死的复现条件（eth0 入口持续 NAT 下载、双流、
9 分钟即可触发）：2 条并发流循环下载 100 MB 文件共 10 分钟，主机侧
`--speed-limit 20000 --speed-time 20` 作卡死检测；路由器侧每 30 s 采
eth0/eth1 载波、ECM `connection_count/accelerated_count`、网关 ping、
dmesg 错误计数。

## 4. 压测结果（2026-11-25 12:25–12:35 UTC，10 分钟，2 流 × 100 MB 循环）

**路由器侧 PASS；后期连接失败归因于上游 fake-IP 代理的 443 拦截，与固件无关。**

转发与加速：

- 成功下载 **27 个整包 + 若干部分包，合计 1.67 GB**（流 1 925 MB / 流 2
  742 MB），由 eth0 入口经 NAT 从 eth1 出，ECM 全程工作；
- 22 次 30 s 采样：eth0/eth1 均 2500 Mbps、carrier=1、oper=up 全程无跳变；
  网关 ping 每次 OK；ECM `connection_count` 2–28，`accelerated_count` 2–3
  （双流 NAT 全程在 PPE 上加速，tcp 加速计数同步）；
- dmesg 错误计数恒为 38（基线，无任何新增）。

连接失败（86 次/流：54+53 `Recv failure: Connection reset by peer`、
31+32 `TLS connect error: unexpected eof`、各 1 次 stall 超时）：

- 从开跑约 2.5 分钟后开始，成功与失败交错出现直到结束（非某个时刻整体断掉）；
- 压测结束后的即时探测显示：**路由器自身出网**（不过 NAT）到 443 同样
  100% 失败，ICMP 与 DNS 正常、`http://1.1.1.1`（80 端口）经 NAT 正常
  301；故障面是「一切 TCP/443 到 proxy」，主机与路由器表现完全一致；
- 域名解析（包括直询 1.1.1.1）都返回 198.18.x，说明现场所有外网流量经
  upstream 的 fake-IP 透明代理；代理在压测流量后开始 reset 443，很可能
  触及其限额，属环境侧，路由器数据面（80 端口同路径）始终可用。

与 24.10 TX 楔死的鉴别：楔死特征是「链路 up 但转发归零、只能重启」；
本次链路、网关可达性、NAT 转发（80 端口实测）在压测后均正常，未复现。

限制：受代理 443 拦截影响，本次有效吞吐只到平均 ~2.8 MB/s，未能在
9 分钟以上维持单流满速（上游单流实测上限约 94 Mbps）。代理恢复后建议
补一次「单流 9 分钟长跑」复核 24.10 楔死形状；当前 6.18 判断为 PASS
（无楔死、无丢链路、加速正常）。

## 5. 建议

- 现场上游 fake-IP 代理的 443 在压测后不可用（疑似限额），HTTP/80 与
  ICMP 正常；恢复前所有 HTTPS 都会失败，与固件无关。若久不恢复，需要
  检查上游网关/代理（不在本路由器范围）。
- 6.18 侧无需为本次审计出的日志项开补丁；
- 可选清理（不紧急）：`edma_cfg_rx.c` 的 VP 告警可在未来给 DTS 补
  `qcom,rx-vp-rings` 或加条件静默；wan6 噪声可在确认无 IPv6 上游时按需
  关闭 wan6 接口（当前保持标准默认）。
