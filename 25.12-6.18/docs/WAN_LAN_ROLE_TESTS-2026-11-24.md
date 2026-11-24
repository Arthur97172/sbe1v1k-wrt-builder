# 6.18 端口角色切换真机测试（2026-11-24）

固件 `sbe1v1k-6.18-f83501a9`（OpenWrt SNAPSHOT，内核 6.18.64，tier=full，NSS 变体）。
设备为 ipq9574 / Spectrum SBE1V1K，端口映射：eth0=dp1=10G（RTL8261N）、
eth1=dp2=2.5G（QCA8081）、eth2/eth3=qca8075。

6.18 的角色实现与 6.12 相同：`sbe_ports.main.wan_port` 取 `eth1`/`eth0`/`none`
（场景 3/1/2），S19 启动脚本写 SSDK 成员表并回读校验，eth0 作为 LAN 时由
`eth0-lan-attach` 桥外挂载（不交给 netifd，规避 RTL8261N 假环回）。

## 测试环境

- 主机 USB 2.5G 网卡（`enxc84d4424a1b5`）接路由器 10G 口（eth0）。
- 路由器 2.5G WAN 口（eth1）原接上游；场景 1/2 测试期间上游线拔出（eth1 carrier=0）。
- 场景 1 用主机侧模拟上游：USB 网卡静态 `192.168.77.1/24` + `fd77::1/64`，
  dnsmasq（DHCPv4 固定租约 `90:d3:cf:4b:eb:81 → 192.168.77.169`，
  DHCPv6 池 `fd77::100-1ff`，`enable-ra`）+ `python3 -m http.server 8080`。
- 管理通路：主机 WiFi（`wlp0s20f3`，192.168.1.230）SSH 到 192.168.1.1；
  USB 网卡作 LAN 侧数据面验证。

## 结果总表

| 场景 | wan_port | 成员表 p3/p4/p5/p6 | 重启后 boot 应用 | 数据面 | 结论 |
|---|---|---|---|---|---|
| 3（默认） | eth1 | 0x51/0x49/0x01/0x19 | PASS（11-24 多次重启） | LAN 经 USB 网卡 DHCP/SSH PASS | **PASS** |
| 2 | none | 0x71/0x69/0x59/0x39 | PASS | 四口全入 br-lan；WAN 无地址无默认路由；LAN 经 USB 网卡 ping/SSH PASS | **PASS** |
| 1 | eth0 | 0x31/0x29/0x19/0x01 | PASS（含冷启动复测） | eth0 作 WAN：DHCPv4/DHCPv6/静态 IPv4/WAN→LAN 隔离/LuCI 全 PASS | **PASS** |
| 回滚 → 场景 3 | eth1 | 0x51/0x49/0x01/0x19 | PASS | eth0 回 br-lan（attach 日志），USB 网卡拿回 LAN 租约 | **PASS** |

成员表规律与 6.12 文档一致：把「非 LAN 口」从 br-lan 成员里摘掉。
场景 3 时 eth1/eth2/eth3 入桥、eth0 桥外挂载；场景 2 时四口全入桥；
场景 1 时 eth1/eth2/eth3 入桥、eth0 作 WAN。

## 场景 1（eth0 作 WAN）细节

- S19 日志：`端口角色：eth0`，`SSDK 成员表已按 eth0 写入并回读校验通过`。
- eth0 出桥后 link 2500 Mbit/s，未观察到 RTL8261N 假环回。
- DHCPv4：`udhcpc: lease of 192.168.77.169 obtained from 192.168.77.1`，
  默认路由 `via 192.168.77.1`，ping 上游 3/3，DNS 经 192.168.77.1 解析 PASS。
- 静态 IPv4：`wan` 改 `proto=static 192.168.77.169/24 gw 192.168.77.1`
  后 ping 上游 PASS，随后恢复 `proto=dhcp`。
- DHCPv6 + RA：eth0 拿到 `fd77::176/128`（`/128` 是 ISP 路由型分配的正常形态），
  `default from fd77::176 via fe80::ca4d:44ff:fe24:a1b5`（RA 下发），
  wan6 `up=true, pending=false`，ping6 fd77::1 3/3 PASS。
- WAN 面 LuCI：从 WAN 侧访问 80/443 返回 200（`allow-luci-wan` 生效）。
- WAN→LAN 隔离：绑定 USB 网卡发包（`curl --interface`，不用 `-s` 源地址法，
  旧 nc 会忽略 `-s` 造成假阳性）——ping 100% 丢包、HTTP `000`、
  SSH 无 banner；同时 LAN 侧（WiFi）SSH 返回 `SSH-2.0-dropbear`，证明是隔离
  而非链路不通。
- 冷启动复测：重启后 S19 自动应用角色，DHCPv4/DHCPv6 均自动完成。

## 场景 2（none）细节

- 四口全部入 br-lan，`wan`/`wan6` `auto=0`，无默认路由（routes 只剩
  `192.168.1.0/24 dev br-lan`）。
- eth0 作为 LAN 口经 USB 网卡 DHCP（.235/.240）+ ping + SSH 全 PASS。

## 发现与注意点

1. **board.json 在非默认角色下重建失败（根因已定位，已修复）**：场景 1/2 的 S19 日志出现
   `board.json 重建失败，已还原上一份` 与 `board.json 网络段未同步`，
   `sbe-port-roles status` 报「与角色不一致」；场景 3 下正常且一致。
   影响仅为 LuCI 端口面板显示旧角色，数据面不受影响。

   根因：6.18 树（上游 main）的 `/bin/board_detect` 改成了「缓存」模型——
   `/etc/board-base.json` 在**首次启动** preinit 时由 board.d 生成一次，
   `/etc/board.json` 只是指向 `/tmp/sysinfo/board.json` 的符号链接，
   普通 `board_detect` 仅把 base 复制到运行时文件，**不再执行 board.d**。
   `sbe-port-roles` 的 `board_sync()` 却按旧行为「删 board.json 再跑
   board_detect」，于是复制回同一份首启时生成的默认映射（eth1 WAN），
   永远与角色不一致。真机验证（仅改 UCI 值、不动物理角色）：
   - `board_detect`（普通）在 `wan_port=none/eth0` 下仍输出默认映射；
   - `board_detect -f` 会重跑 board.d 并正确读取 `sbe_ports.main.wan_port`：
     `none` → `lan = eth1 eth2 eth3 eth0`（无 wan 段），
     `eth0` → `lan = eth1 eth2 eth3`、`wan.device = eth0`。

   修复：6.18 的 `board_sync()` 在存在 `/etc/board-base.json` 时改用
   `board_detect -f`，并把 base 与 board.json 一起备份；重建失败时两者一起
   还原。注意 6.12 树的 `board_detect` 是旧逻辑（每次运行 board.d），
   没有 `-f` 参数，不能照搬，该树不改。

   修复真机验证（同一设备刷入含修复的 NSS 镜像后）：
   - 默认角色 eth1：boot 后 `status` 报「board.json 与角色一致」，
     WAN 拿回 `192.168.10.237`，上游网关 ping PASS。
   - live `sbe-port-roles set eth0`：日志出现
     `board.json 网络段已按角色 eth0 重建`，`status` 由「不一致」变为
     「一致」，`board.json` 的 `wan.device=eth0`——旧版在此必报重建失败。
   - **boot 路径（eth0/none 角色下重启后由 S19 重建）NOT TESTED**：
     修复后的镜像未在非默认角色下重启过（验证中途设备被改接线路、
     管理通路中断），live 路径与 S19 走同一个 `board_sync()`，但 boot
     场景的日志与回滚分支仍待补测。
2. **br-lan MAC 随成员变化**：eth1 不入桥时 br-lan MAC 是 `:83`（eth2 派生），
   eth1 入桥后变 `:82`（eth1 派生）。桥 MAC 派生规则使然，非缺陷；
   6.18 没有 24.10 的桥 MAC 钉死机制（S19），如需恒定需另行处理。
3. **live `set` 只验证了控制面**：`sbe-port-roles set` 立即写成员表并同步 UCI
   （status 回读正确），但本轮每次都在 set 后立即重启，**角色切换的数据面
   live 路径在 6.18 上 NOT TESTED**。6.12 的切换回退丢帧修复（nss-dp 0009，
   STP/dropcode 115）在 6.18 中逐字节相同，预期无差异。
4. **IPv6 测试环境坑（非固件问题）**：模拟上游网卡最初
   `LinkLocalAddressing=no`，主机无 `fe80::` 地址，内核拒绝向链路本地目的
   发包（tcpdump 0 包），导致 DHCPv6 ADVERTISE 实际未发出、wan6 报
   `error connecting LLA socket`/`Address not available`。改为 `yes` 后
   DHCPv6 一次通过。主机→路由器 LLA ping 失败同为此因，修复后 PASS。
5. 场景 2 首次自动化脚本因「重启竞态」（sleep 后 SSH 命中的仍是旧系统）
   误判，已改进为「等旧 SSH 消失 + 新系统 uptime <300 s」再断言；
   相关中间证据见 `/tmp/role-618/`（临时目录，不入库）。

## 协议覆盖

| 项 | 结果 |
|---|---|
| DHCPv4（boot + 手工 ifup） | PASS |
| DHCPv6 + RA（boot） | PASS |
| 静态 IPv4 | PASS（场景 1，已恢复 dhcp） |
| PPPoE | NOT TESTED |
| LuCI over WAN / SSH from WAN | PASS（80/443 放行，22 被拒） |
| 角色数据面 live 切换 | NOT TESTED（见上第 3 点） |

## 环境还原

上游线回插 2.5G 口（eth1）后复核 PASS：link 2500 Mbit/s，WAN 拿回
`192.168.10.237`，默认路由 `via 192.168.10.1`；ping 网关 2/2，
外网 baidu 200、hicloud `generate_204` 204、ping 223.5.5.5 3/3（38 ms）。
上游本网环境会拦截部分目标（如 gstatic `generate_204` 返回 000，
DNS 对 openwrt.org 返回 198.18.x 代理地址），与本固件无关。
wan6 依上游现状无 IPv6，保持 pending（预期）。
（模拟上游已拆除，主机 USB 网卡已回 LAN DHCP 192.168.1.235。）

## 遗留

- board.json 非默认角色重建：已修复（`board_detect -f`），live 路径真机
  PASS；非默认角色下的 boot 路径未重启验证（见「发现与注意点」第 1 点）。
- 角色数据面 live 切换未验证（见「发现与注意点」第 3 点）。
- 2026-11-24 起 `sbe-port-roles` 在 live 切换涉及 eth0 时打印警告并提示重启
  （24.10/6.12 已实证的 RTL8261N 假 10G 环回；6.18 的 live 数据面路径仍未
  验证）。只加提示，不改变切换行为；该改动真机 `NOT TESTED`。
