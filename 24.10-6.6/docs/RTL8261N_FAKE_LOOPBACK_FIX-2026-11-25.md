# RTL8261N 假 10G 环回：根因定位与修复（2026-11-25）

状态：**根因已定位；0032 已写好并在 v128-2 真机验证——重初始化路径确实
执行、旧假 10G 幻影未再复现，但 live 角色切换后 eth0 仍拿不回链路（判据 #2
FAIL），只有重启恢复；开机路径正常。**

## 结论摘要

假环回的触发点是 phylib 在 `phy_stop()` 时对 PHY 的自动断电：
`nss_dp_close → phylink_stop → phy_stop → PHY_HALTED → phy_suspend →
rtkphy_c45_suspend → rtk_phylib_c45_power_low`（MMD1.0 bit11 断电）。
再开时 `phy_start → __phy_resume → rtkphy_c45_resume` 只清断电位，**不重跑
`rtkphy_config_init()` 的 MMD30 0x145 硬件复位与固件 patch**。RTL8261N 在被
断电再上电后如果不重做完整初始化，铜缆 autoneg 引擎就再也起不来：路由器
侧 PMA 报 10G Up（假环回），对端 2.5G 网卡 NO-CARRIER，只有重启（开机走
一遍完整 `config_init`）能恢复。

修复：`.resume` 检测到本次确实从 suspend 恢复（`phydev->suspended` 仍为
true）时，先 `power_normal` 再重跑 `rtkphy_config_init()`，与开机路径一致；
无 suspend 的 resume（开机首次 `phy_start`）保持原逻辑。见
`build-fixes/0032-rtl8261n-reinit-on-resume.patch`。

## 2026-11-25 设备诊断实验（第三台，24.10 v117-2）

管理通路：主机 WiFi（192.168.1.230）→ br-lan AP；对端 USB 2.5G 网卡
（enxc84d4424a1b5，192.168.1.2）接路由器 eth0（10G 口）。

1. **基线**：两端 2500 载波、eth0 在 br-lan、WAN 走 eth1。
2. **诱发**：`sbe-port-roles set eth0`（live，rc=0，SSH 这次未挂）。
   eth0 变 `speed=10000 carrier=1`，对端 NO-CARRIER；dmesg
   `Link is Down` → `configuring for phy/usxgmii` → `Link is Up -
   10Gbps/Full`。假环回复现。
3. **强制 AN 重启实验（全部阴性）**：
   - `/tmp/ethtool -s eth0 autoneg on speed 2500 duplex full`（rc=0，经
     phylink → `rtkphy_c45_config_aneg` changed=true → 真写 AN restart）：
     假 10G link 掉了（`Link is Down`），但对端仍 NO-CARRIER，30 s 内双方
     均无链路；
   - `ssdk_sh port autoNeg restart 6`（eth0=port6/USXGMII）：
     `operation done`，无变化；
   - PHY 读回：BMCR=0x1140（AN 使能、restart 位已自清），BMSR=0x7989
     （link=0、AN-complete=0）——铜缆 AN 在跑但协商不完成；
   - `ip link set eth0 down/up`：假 10G 也没回来，链路保持 down；
   - 直写 BMCR=0x1340（AN restart 位）：写入生效（位自清），BMSR 不变，
     对端仍 NO-CARRIER。
   **结论：任何"只重启 AN"的手段都救不回来；PHY 处于必须硬复位+固件
   重载（即 config_init）才能恢复的状态。**
4. **恢复**：`sbe-port-roles set eth1` + `sync; reboot`；复核 eth0 2500
   真链路、对端载波、WAN DHCP `192.168.10.237`、
   `reset_reason : System reset or reboot [0x10]`，全部 PASS。

## 对照证据（此前会话，转录可查）

- `ip link set dev eth0 nomaster` 单独执行（不 down/up）**不触发**：eth0
  保持 2500 健康，桥接 helper 自动挂回 br-lan；
- 管理员手动 `ip link set eth0 down/up`（无 netifd 参与）**稳定触发**。
  即触发点就是 phylib 的 stop/start（suspend/resume），与 netifd 无关。
- 6.12 开机 AN 死锁（`../25.12-6.12/docs/ETH0_XPCS_AN_BOOT_2026-11-22.md`）
  同属 USXGMII AN 家族但机制不同：那次是 XPCS 侧死锁，重跑 PHY
  config_init（mdio 设备 unbind/bind）无效；本次是 PHY 侧被断电后缺初始化，
  重跑 config_init 正是开机恢复所走的路径。

## 修复补丁（0032）

`24.10-6.6/build/build-fixes/0032-rtl8261n-reinit-on-resume.patch`（tree
模式，`patch -p1` 到 buildroot），SERIES 已登记；`build/known-delta.conf` 已把
`rtk_phy.c` 登记为有意改动，装配脚本第 11 步新增 `RTL8261N_RESUME_REINIT_OK`
断言（首次装配 run 45610628174 因漏登记被指纹门禁拦下：UNEXPLAINED
changed，exit 5）。内容：`rtkphy_c45_resume`
在 `phydev->suspended` 为 true 时先 `rtk_phylib_c45_power_normal` 再调
`rtkphy_config_init()`，并打一行 `phydev_info("RTL8261N: re-initializing
after suspend")` 便于真机确认路径。本地装配树 dry-run 应用通过
（`--fuzz=0`）；vendor-files 与装配树中的 rtk_phy.c 逐字节一致，CI 装配
的补丁上下文必然匹配。本地树不完整（缺 include/asm-generic 多个头），
未做单文件编译；编译验证交给 CI。

2026-11-25 12:38Z：补登记后 sources 装配 run 45612492056 **PASS**，
发布 `sources-v38`（tar.zst + SHA256SUMS + TREE-FINGERPRINT.json），
`RTL8261N_RESUME_REINIT_OK` 断言与 `FINGERPRINT_MATCH` 均通过；同次提交
的 24.10 构建 workflow 随本次 push 启动（source_tag=auto → sources-v38），
约 3 小时。

2026-11-25 13:06Z：该构建 run 45615850648 在排队约 27 分钟后被 GitHub
侧**取消**（conclusion=cancelled，未创建任何 job；与同时段的 6.12 构建
无并发组冲突，原因未明）。本次补记 push 重新触发装配与构建。

## 2026-11-25 真机验证（24.10 v128-2-0ea26d29，含 0032）

接线：本机 USB 2.5G 网卡（192.168.1.2）↔ 路由器 eth0（10G 口，LAN，
192.168.1.1）；eth1（2.5G）= WAN ↔ 上游。重启相关操作已获用户批准。

- **版本确认**：刷入 GitHub Release v128-2 的 sysupgrade 镜像（82,576,182
  字节，sha256 `912fb16c…a918` 与 release 记录一致），`sysupgrade -n`。
  设备版本串是冻的 `sbe1v1k-g3.5c` 不能区分构建，**以 dmesg 指纹为准**。
- **开机路径（判据 #1 方向）**：每次重启后 dmesg 都有
  `rtkphy_config_init:69 ... phy_id: 0x1CCAF3`，eth0 在开机约 30.6 s 处
  `Link is Up - 2.5Gbps/Full`，对端 USB 网卡载波恢复。多轮重启已见
  6 次以上，均正常（10 次系统化热重启回归进行中）。
- **resume 指纹（判据 #2 前半）**：干净启动后做一次规范往返
  `sbe-port-roles set eth0`（live）→ 84.667 s `Link is Down` →
  84.687 s `configuring for phy/usxgmii` → **84.694 s
  `RTL8261N: re-initializing after suspend`**，随后完整 config_init
  （MDD30 复位+固件 patch）执行；`set eth1` 返回时（126.990 s）再次重初始化。
  即 0032 的 resume 重初始化路径**确实执行**。
- **旧幻影消失**：往返全程未再出现「路由器侧 10G Up、对端
  NO-CARRIER」的假环回状态。
- **但判据 #2 后半 FAIL**：两次 live 切换后 eth0 都**没有任何链路**——
  路由器 `carrier=0`、`speed` 不可读，对端 USB 网卡 NO-CARRIER，ping
  100% 丢包；对端 `ip link set … down/up` 重 AN、`ssdk_sh port
  autoNeg restart 6` 均无效。只有重启（完整开机 config_init）能恢复
  2500 真链路。
- **判据 #3 未测**：链路都起不来，新角色 WAN DHCP 无从谈起。
- **限制**：该镜像无 ethtool、QSDK mdio 不支持 SIOCGMIIREG、ssdk_sh 无
  PHY 寄存器命令，故无寄存器级证据（自建静态 mdio-read 工具报
  `SIOCGMIIREG: Not supported`）。为遵守设备操作约束，未安装任何软件。

**解读与下一候选**：0032 把危险态（假 10G 误报）变成了安全态（无链路），
但 live 切换后 eth0 仍不可用，开机路径完全正常。时序假设：开机时
config_init（13.4 s）与 AN config/restart（~30 s）之间有十余秒间隔，
而 resume 路径里硬复位+固件 patch 之后几毫秒 AN config 就落地，PHY 可能
需要复位后静置。候选修法：resume 重初始化后延迟（例如 1-2 s 的工作队列）
补一次 `genphy_c45_restart_aneg`；或接受「eth0 不支持 live 切换」的边界。

## 待真机验证的判据

1. 刷入带 0032 的新镜像，热启动 10 次 eth0 开机链路正常（回归）；
   **→ v128-2 PASS：10/10 次开机 eth0 均在 30.4–31.1 s 以真 2500 建链
   （每轮 dmesg 的 `Link is Up - 2.5Gbps/Full` 时间戳独立，carrier=1
   speed=2500）。回归脚本早期版本因 host RTL8156B sysfs carrier 假死读数
   和 SSH known_hosts 密钥冲突产生过假 FAIL，已作废重跑；v2 中 3 轮
   `fresh=0` 是 uptime 判据在短命启动下的记账误判，链路证据本身全部正常。**
2. `sbe-port-roles set eth0`（live）后再 `set eth1`（live）往返：每次
   eth0 都应回到 2500 真链路，对端恢复载波，dmesg 出现
   `RTL8261N: re-initializing after suspend`；
   **→ v128-2 FAIL（指纹出现、幻影消失，但 eth0 往返后无链路，仅重启可救）**；
3. WAN 在新角色下拿到 DHCP，`sbe-port-roles status` 与 board.json 一致。
   **→ 未测（eth0 无链路）**。

## 证据

设备侧证据在 `/tmp/sbe-flash/probe-evidence/`（临时目录）：
`an-restart-experiment-dmesg.txt`、`an-restart-experiment-final.txt`。
