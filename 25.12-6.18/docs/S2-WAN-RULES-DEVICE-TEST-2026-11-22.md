# S2 首批：WAN 放行规则真机验证（2026-11-22）

- 目标机：B（测试机），USB 网卡接 `lan1`（10G 口），LAN 192.168.1.1，
  WAN 经上游 Spectrum 网段 DHCP 得 192.168.10.236。
- 刷入件：`openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin`
  （91,597,073 B，sha256 `95a4415887efabd5eb6c8fb4e3b7e0ebe7226b1e35e06f99f7e7874960726f92`），
  本机构建（`sbe1v1k-6.18-86a810fd` + `files/etc/uci-defaults/99-allow-{luci,ssh}-wan`）。
- 方式：B 当时已跑同板 6.18 S1（`askey,sbe1v1k`），故直接
  `sysupgrade -n /tmp/fw.bin`（不再需要 `-F`）；设备侧校验和与宿主一致。
- 结论：**PASS**。

## 1. 基线（刷写前，S1 无规则）

宿主 192.168.10.100 对 B 的 WAN 192.168.10.236 探测：

```
WAN:22 closed/blocked (pre-flash)
WAN:80 closed/blocked (pre-flash)
WAN:443 closed/blocked (pre-flash)
```

## 2. 首次启动后的规则状态

`sysupgrade -n` 清空配置后重启，`/etc/init.d/boot` 执行 uci-defaults：

- `uci show firewall` 出现两段，字段与脚本逐项一致：
  - `firewall.allow_luci_wan`：`src='wan' proto='tcp' dest_port='80 443' target='ACCEPT'`
  - `firewall.allow_ssh_wan`：`src='wan' proto='tcp' dest_port='22' target='ACCEPT'`
- `/etc/uci-defaults/` 里两个脚本已被删除（成功执行的标志，失败会保留重试）。
- fw4 生成的 `input_wan` 链里两条规则就位（在 zone 默认 REJECT 之前）：

```
tcp dport { 80, 443 } counter packets 0 bytes 0 accept comment "!fw4: Allow-LuCI-WAN"
tcp dport 22 counter packets 0 bytes 0 accept comment "!fw4: Allow-SSH-WAN"
```

## 3. 数据面（刷写后，从上游网段）

宿主 192.168.10.100 → B 192.168.10.236：

| 探测 | 结果 |
|---|---|
| `nc` 22 | 成功 |
| `nc` 80 | 成功 |
| `nc` 443 | 成功 |
| `nc` 8080（未放行对照） | 拒绝 |
| `ssh root@192.168.10.236`（空密码） | 登录成功，读到 `wan UP 192.168.10.236/24` |
| `curl http://192.168.10.236/` | HTTP 200 |

规则计数器随流量增长（`Allow-LuCI-WAN` 3 包、`Allow-SSH-WAN` 2 包），
证明命中的是这两条规则而不是另有通路；8080 仍被拒绝说明没有放开整片。

## 4. 未受影响项

- LAN 侧 SSH/LuCI 正常（刷写与取证均经 192.168.1.1 完成）。
- `dropbear`、`uhttpd` 均 enabled；`fw4` active。
- 板识别 `askey,sbe1v1k`，版本串 `sbe1v1k-6.18-86a810fd`，与刷入件一致。

## 5. 安全提醒（需要人工处理）

root 仍为空密码。`Allow-SSH-WAN` 因此在**整个上游网段**上等于免密 root
登录（本次就是从 192.168.10.100 直接登录成功的）。刷机后应立即：

- 设置 root 密码（`passwd`），或
- 删除 `firewall.allow_ssh_wan`（`uci delete firewall.allow_ssh_wan;
  uci commit firewall; /etc/init.d/firewall reload`）。

脚本只在首启写入一次，之后的人工修改/删除不会被回滚。
