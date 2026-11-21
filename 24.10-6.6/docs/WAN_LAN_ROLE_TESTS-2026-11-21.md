# 端口角色与 eth0 真机测试报告（2026-11-21）

覆盖两棵树同源功能：`sbe_ports.main.wan_port`（eth0 / eth1 / none）、
`/usr/sbin/sbe-port-roles`、`eth0-lan-attach`。测试设备为第三台 SBE1V1K
（base MAC `90:d3:cf:4b:eb:81`，eth1/2/3 出厂同 MAC `…:82`），当天在两棵
固件线之间来回刷机：先 25.12，再 24.10，最后回 25.12 复测。

镜像（均来自本仓库 CI Release，刷入前 sha256 在主机与设备各校验一次）：

| 固件线 | tag | sha256（前 8 位） | 刷入方式 |
| --- | --- | --- | --- |
| 24.10-6.6 | `24.10-6.6-v113-2-e0ee12cd`（CI #113，commit `e0ee12c`） | `4a012256` | `sysupgrade -n` |
| 25.12-6.12 | `25.12-6.12-v80-1-e0ee12cd`（CI #80，commit `e0ee12c`） | `a14a835f` | `sysupgrade -n` |

## 结论摘要

| 项目 | 24.10-6.6 v113-2 | 25.12-6.12 v80-1 |
| --- | --- | --- |
| 首启（默认 eth1 角色） | PASS | PASS（早前 §v80 已验，当日复刷再确认要点） |
| eth0 角色（改角色+重启） | PASS | PASS（2026-11-21 早前同一方法验证） |
| 运行期 live 切到 eth0 | **FAIL**：eth0 进入假 10G 环回 | **FAIL**：同 |
| live 回切 eth1 后 2.5G 口 | 恢复（链路/转发/DHCP 全通） | **不恢复**：link up 但 RX/TX 恒 0 |
| 恢复手段 | 10G 口需重启；2.5G 口无需重启 | 只能重启 |

一句话：两棵树「改角色 + 重启」都可用；**live 切换在两棵树上都不可用**，
被 RTL8261N 假 10G 环回阻塞；25.12 更糟——回切时机上的 2.5G 口也会卡死。

## 测试环境与步骤

- 接线：主机 USB 网卡（RTL8156B，2.5G）接路由器 10G 口（eth0）；路由器
  2.5G 口（eth1）接上游网关。
- 管理：全程 WiFi（SSH + LuCI 200）作为保命通路；刷机后 USB 网卡走 DHCP。
- 模拟上游：测 eth0 作 WAN 时，主机 USB 网卡改为静态 `192.168.77.1/24` +
  `dnsmasq`（按 eth0 MAC 固定发 `192.168.77.169`）；测完恢复。
- 防假阳性：WAN→LAN 隔离测试必须用 `-I <接口名>` / `--interface <接口名>`
  绑定**接口**；只绑源地址不改变出口，包会走 WiFi 产生「WAN 能通 LAN」的假
  阳性（当天实际踩到并纠正）。

## 24.10 首启验证（v113-2，`sysupgrade -n`）

首启全项 PASS：`sbe1v1k-g3.5c` / 6.6.147；uci-defaults 全消费；`S19sbe-port-roles`
与 `S23eth0-lan-attach` 在 rc.d；`sbe_ports.wan_port=eth1`；成员表
`0x51/0x49/0x1/0x19`（S19 日志「已按 eth1 写入并回读校验通过」）；br-lan =
eth0/eth2/eth3 + 三频 AP；eth0 冷启动实链路 2500（无假环回）；WAN eth1 从
上游拿到 192.168.10.x；WiFi_2.4G/5G/6G 全起；LuCI 登录页正常（`/` 200，
`/cgi-bin/luci/admin` 403 + `x-luci-login-required`）；overlay `/dev/loop0`
40.8M；日志噪声 0；镜像内 `eth0-lan-attach` 的 up 在「已在桥内」早退之前。

## 24.10 eth0 角色（改角色 + 重启）

`sbe-port-roles set eth0` + 重启，约 50 s 恢复，全部 PASS：UCI 三处同步
（`sbe_ports=eth0`、wan/wan6 `device=eth0`、br-lan ports `eth1 eth2 eth3`）；
SSDK 表 `0x31/0x29/0x19/0x1`；br-lan = eth1/eth2/eth3 + AP；eth0 实链路
2.5G；WAN eth0 从模拟上游拿到 `192.168.77.169`、默认路由正确、路由器可 ping
上游；WAN→LAN 隔离（绑定 WAN 口）ICMP 100% 丢包、TCP80 超时、TCP22 无应答。
回切 eth1 + 重启后一切恢复（WAN 192.168.10.x、eth0 回桥、2.5G）。

第一次隔离测试用了 `ping -I 192.168.77.1`（源地址），结果误判为「通」——
实际走 WiFi。改用接口绑定后结果正确。此坑已记入本报告「测试环境与步骤」。

## 24.10 运行期 live 切换

`sbe-port-roles set eth0`（不重启，脚本 rc=0）后：UCI 与成员表全部就位，
但 eth0 摘桥即 `Link is Down`，3.1 s 后以 `Link is Up - 10Gbps/Full` 回来
——**RTL8261N 假 10G 环回**，对端 2.5G 网卡 NO-CARRIER，WAN DHCP pending。
运行期自救全部无效：路由器侧 down/up 后仍是 10G Up；主机侧 `ethtool -r`
后仍无载波。

live 回切 eth1（rc=0）后：UCI/表复原、helper 把 eth0 挂回 br-lan；eth0 仍
假 10G，但 **eth1（QCA8081）直接恢复**——2.5G 链路 up、WAN 重新 DHCP、
`ping 8.8.8.8` 通、WiFi 管理全程未断。即 24.10 上 live 切换后可以靠回切
把 WAN 救回来，10G 口仍需重启。

## 25.12 live 回切复测（重点对照）

为回答「24.10 回切后 2.5G 口恢复，25.12 是否同样恢复」，刷回 25.12
v80-1-e0ee12cd 重跑同一套步骤。

- live 切入 eth0：与 24.10 相同——eth0 摘桥 3.1 s 后 `10Gbps/Full`，对端
  NO-CARRIER；期间 eth1 作 LAN 口入桥，dmesg 出现 `uniphy autoneg time out!`。
- live 回切 eth1：eth1 先 Down 后 `Link is Up - 2.5Gbps/Full`，再次伴随
  `uniphy autoneg time out!`；**但 eth1 RX/TX 计数保持 0/0（观察 90 s 以上）**。
  udhcpc 日志持续 `broadcasting discover` 而端口 tx 不动，WAN 一直
  `up=false, pending=true`，`ping 8.8.8.8` FAIL。eth0 仍 10000（假环回）。
- 重启（用户批准）约 45 s 恢复：表复原、eth0 回桥 2500、WAN 192.168.10.x、
  外网通、噪声 0、LuCI 200。

对照表：

| 回切后 | 24.10 v113-2 | 25.12 v80-1 |
| --- | --- | --- |
| eth1 物理链路 | 2.5G up | 2.5G up |
| eth1 收发 | 正常 | RX/TX 恒 0 |
| WAN DHCP | 拿到租约、外网通 | pending、外网 FAIL |
| uniphy autoneg | 无该报错 | 每次角色变更后 `autoneg time out!` |
| eth0 | 假 10G、需重启 | 假 10G、需重启 |

## 结论与影响

1. **「改角色 + 重启」是两棵树唯一可靠的切换方式**，软硬件三处（SSDK 表、
   UCI、board.json）收敛正确，WAN/LAN 隔离有效。
2. **运行期 live 切换不可用**：两棵树都会把 eth0（RTL8261N）打进假 10G
   环回，运行期无法恢复。根治只能在驱动（方案四：`rtl8261n` 的 teardown/
   复位路径），此结论作为方案四触发条件 2 的证据。
3. **回切保命能力有树级差异**：24.10 回切后 2.5G 口立即恢复转发；25.12
   回切后 2.5G 口「link up 但 RX/TX 恒 0、伴随 autoneg timeout」，只能重启。
   25.12 的 port5/uniphy PCS 在运行期重新配置路径上还有独立的缺陷，需另行
   排查（是否与 `nsscc port5 PCS 时钟父节点` 相关尚未验证）。
4. LuCI/运维层面：在 25.12 上使用 `sbe-port-roles set` 前应提示「可能需重启
   恢复」。后续若做「不重启切换」功能，必须先完成方案四。

## 取证方法备注

- 两棵树刷机后 dropbear 主机密钥会变：先 `ssh-keygen -R 192.168.1.1`。
  主机 USB 网卡的 DHCP 租约可用 `sudo networkctl reconfigure enxc84d4424a1b5`
  触发更新。
- 个别重启的 `logread` 最早记录晚于 S19/helper 运行时刻（logd 就绪才开始
  缓冲），S19/attach 日志行可能缺失；功能判据以 SSDK 表值与
  `/sys/class/net/br-lan/brif/` 成员为准。
- 假环回判据：路由器侧 `speed=10000` 且对端（2.5G 网卡）NO-CARRIER。
  24.10 的 Down→Up 间隔约 2–3 s、25.12 约 3 s，均不像 admin down/up 那样
  只有约 10 ms——不要只看间隔，以速率与对端载波为准。
