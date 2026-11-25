# RTL8261N 假 10G 环回：GPIO 41 硬复位探针计划（可选，未启动）

状态：**已执行（2026-11-25，v117-2）**：预检、诱发、3a 完成；3b
（mdio unbind/rebind，用户批准后执行）触发**内核 panic 整机复位**
（`reset_reason : HLOS Panic [0x47]`），「硬复位能否清除假环回」
未取得可判读结果，且 mdio unbind 路径本身判定为运行期不可用。
设备已恢复已知状态。执行记录见文末「2026-11-25 执行记录」。

2026-11-24 与用户确认：不列为本期必修，作为「下一次 24.10 现场会话的
可选 10 分钟探针」登记；只有触发条件（见文末）成立时才启动。任何涉及
路由器的连接与运行期操作都须单独批准，密码不落盘。

## 背景

24.10 与 25.12-6.12 已真机实证：eth0（RTL8261N，10G）在运行期被摘桥/重连
后进入「假 10G 环回」——路由器侧驱动报 `Link is Up - 10Gbps/Full`，对端
2.5G 网卡 NO-CARRIER，`down/up` 与对端 `ethtool -r` 均无法恢复，只能重启
（25.12-6.12 的 live 回切丢帧是另一问题，已由 nss-dp 0009 修复；假环回不受
该补丁影响）。6.18 的 live 数据面路径尚未验证。

现行缓解（2026-11-24，`fddb6d8`）：`sbe-port-roles` 在 live 切换涉及 eth0
时打印警告并提示重启（只提示，不改行为）。推荐使用路径仍是「改角色 + 重启」，
live 切换属回避场景（见 `README.md` 端口角色一节与
`docs/WAN_LAN_ROLE_TESTS-2026-11-21.md`）。

## 已就绪的部分（无需改固件）

- 24.10 DTS 的 `phy-reset-gpio` 数组已含 tlmm 41（`f3272ca`，2026-11-21；
  复位线定案：60=qca8075 包级、52=QCA8081、41=RTL8261N）。24.10 走
  sources-vN 装配，该改动从 **sources-v33**（2026-11-21 10:14 UTC 发布）
  起进入镜像；此后构建的 24.10 镜像（v115-2 及更新）都带 41 号线。
- **镜像是否带 41 以设备预检为准，不靠构建日期推断**：v113-2 构建于
  2026-11-21 07:06 UTC，早于 sources-v33，虽其仓库提交含 `f3272ca`，但
  装配基线无法从外部确认。预检（只读）：
  `find /proc/device-tree -name phy-reset-gpio` 找到节点后用
  `od -An -tu4 <节点>`，应为三组同值对（60/52/41 各带 flags 1，大端）。
  不足三组就先刷 v115-2 或更新的 24.10 镜像再做探针。
  **2026-11-25 v117-2 真机预检 PASS**：节点
  `/proc/device-tree/soc@0/mdio@90000/phy-reset-gpio`，hexdump 内容
  `0e/60/1`、`0e/52/1`、`0e/41/1`（三组齐全）。设备无 `od` applet，
  用 `hexdump -C` 读。即 v117-2 起（含）的镜像满足探针前置条件。
- QSDK 的 mdio-ipq4019 驱动开机整组脉冲三条线；25.12 两棵树对应补丁：
  6.12 = 0036（mdio 驱动改回脉冲整组数组），6.18 = 0038。均无需额外改动。
- 因此探针不需要为它单独重编镜像；若预检不通过，用现有 v115-2+ 镜像即可。

## 探针步骤（须用户批准后执行）

1. 前置取证：确认运行 v115-2 或更新，并做「已就绪」一节的设备预检确认
   DTS 带三条复位线（不足三组就先刷镜像）；WiFi 管理通路在位（保命通道）；
   对端测试网卡接 eth0。
2. 诱发：`sbe-port-roles set eth0`（live，不重启）。取证两端状态：路由器
   `ip -br link show eth0`、dmesg 链路行；对端 `ip -br link`/`ethtool`。
   预期复现假环回（路由器 10G Up、对端 NO-CARRIER）。
3. 逐级尝试（每步之间观察 eth0 对端载波与 WAN DHCP，失败不叠加下一步）：
   - 路由器侧 `ethtool -r eth0`（记录是否 no-op / 是否有任何链路变化）；
   - mdio 总线 unbind/rebind（重新执行整组复位脉冲；**会同时脉冲
     60/52/41，四个有线口全部 bounce**），之后再读两端链路与 DHCP。
4. 恢复：无论成败，最后重启设备回到已知状态；取证（`logread`、两端
   `ip -br link`、`sbe-port-roles status`）存档到 `docs/` 或临时证据目录。

## 判读标准

- 成功：eth0 对端出现载波，链路按实际速率可用，WAN DHCP 拿到地址——
  「运行期脉冲 41 号 GPIO 硬复位 PHY」可清除假环回。
- 失败：维持假环回或出现新异常，记录到哪一步、哪一侧仍异常。

## 风险与边界

- mdio unbind/rebind 拉全部三条复位线，有线 LAN 瞬断（WiFi 仍在 br-lan，
  管理不断）；每步前先做好取证，失败即重启回滚。
- **不在本计划内**：用 devmem 直捅 TLMM 寄存器单独脉冲 41（GPIO 已被
  mdio 驱动占用，sysfs 导出 EBUSY，devmem 属实验级手段，风险不成比例）。
- 不修改驱动、不做 live 行为变更；本探针只产出"硬复位能否清除"的证据。

## 与根治方向的关系

已知的 UNIPHY XPCS 开机 AN 死锁实验（`../25.12-6.12/docs/ETH0_XPCS_AN_BOOT_2026-11-22.md`）
显示：PHY 复位+补丁重载、单独重启 AN、XPCS 软复位、固定速率都不能恢复
boot 期的 USXGMII AN 死锁。假环回与它同属 USXGMII AN 家族，先验期望不高，
但机制未必相同：

- 若硬复位可清 → 支持「驱动 `.resume` 重做 MMD30 0x145 复位 + phy_patch」
  这一根治候选（24.10 假环回的既有结论）；
- 若不可清 → 说明卡点在 SoC XPCS/uniphy 侧，将来的驱动修复必须同时复位
  uniphy（与上述开机死锁的负结果一致）。

## 触发条件（满足其一才启动）

1. 用户明确要求 24.10 支持运行期角色切换（live 切换）且不愿重启；
2. 6.18（或后续树）上需要诊断假环回，且要以「PHY 硬复位能否清除」作为
   驱动修复的设计输入；
3. 上游/厂商对 RTL8261N 或 mdio/uniphy 驱动有改动、需要回归定位时顺带。

## 2026-11-25 执行记录（v117-2，部分完成）

设备：第三台 24.10 `v117-2`；管理通路 = 主机 WiFi（USB/eth0 即探针对象）。
证据目录：`/tmp/sbe-flash/probe-evidence/`（临时，baseline / post-induction /
step3a-ethx-r / recovery 四份）。

1. **预检 PASS（复核）**：`mdio@90000/phy-reset-gpio` = `0e/3c/1`、
   `0e/34/1`、`0e/29/1`（14/60、14/52、14/41，三组齐全）；初始态
   eth0 2500 真链路在 br-lan、wan_port=eth1。
2. **诱发 PASS（假环回复现）**：`sbe-port-roles set eth0` 写入成功；
   SSH 通道随 network/firewall reload 挂死（已知现象），改由主机侧
   独立确认：
   - 路由器 eth0：`UP LOWER_UP`，`speed=10000 carrier=1`，
     dmesg 记 `Link is Down`（118.5 s）→ `configuring for phy/usxgmii`
     → `Link is Up - 10Gbps/Full`（121.7 s）；
   - 对端 USB 2.5G 网卡：`DOWN <NO-CARRIER>`，carrier=0。
   即「路由器 10G Up / 对端无载波」的假环回判据成立。
   注：role=eth0 时 br-lan 成员为 eth1/eth2/eth3 + WiFi AP，主机到
   `192.168.1.1` 的路由仍钉在已 NO-CARRIER 的 USB 网卡上（metric 更低），
   `ssh -b` 只改源地址不改出口 → `No route to host`；在主机侧加
   `ip route replace 192.168.1.1/32 dev wlp0s20f3 src 192.168.1.230`
   后 WiFi 管理恢复。下轮探针先做这一步，省去排查。
3. **3a `ethtool -r eth0`：阴性（不支持）**。`Cannot restart
   autonegotiation: Not supported`（rc=255）——eth0 由 nss-dp 呈现，
   无 `restart_an` 实现；执行前后两端链路状态零变化（路由器保持
   10000/1，对端保持 NO-CARRIER），dmesg 无新行。
4. **3b mdio unbind/rebind：执行后内核 panic，整机复位**。命令
   `echo 90000.mdio > /sys/bus/platform/drivers/ipq4019-mdio/unbind`
   （总线驱动 `ipq4019-mdio`，设备 `90000.mdio`）第一次尝试被 Claude
   Code 权限分类器以 Remote Shell Writes 拒绝两次、未绕行；用户批准后
   重试，诱发（假环回再次复现：路由器 10000/1、对端 NO-CARRIER）后
   执行：**unbind 写入在返回前挂死**（`unbind_rc` 从未打印），约 20 s
   内 WiFi 管理全面失联（ping 100% 丢失、AP 不可见），约 20–40 s 后
   设备自行复位；重启后 `reset_reason : HLOS Panic [0x47]`，结合
   `kernel.panic=3` 判定为 mdio unbind 路径触发内核 panic（无 pstore，
   无 live watchdog 设备，排除看门狗复位）。复位后 role 仍为 eth0
   （UCI 已持久化），eth0 开机 AN 正常回到真 2500 链路。
   **结论：`ipq4019-mdio` 总线 unbind 在 nss-dp 挂有 PHY 的平台上直接
   panic，不能用它做运行期整组复位脉冲；「GPIO 硬复位能否清除假环回」
   的原始问题本轮未取得可判读结果**（系统复位掩盖了 PHY 级行为）。
   若还要验证，只能走驱动内定向复位（phydev 级复位、非总线 unbind）
   或 devmem 直捅 41（已在本计划「不做」之列）。
5. **恢复 PASS**：`sbe-port-roles set eth1`（rc=0）+ `sync; reboot`；
   重启后复核：wan_port=eth1、eth0 回 br-lan 且 2500 真链路、对端
   USB 网卡恢复载波、eth1 拿上游 DHCP `192.168.10.237`、dmesg 正常
   2.5G/2.5G Link Up、`reset_reason : System reset or reboot [0x10]`，
   无假环回残留。

结论（最终）：运行期假环回可用一次 live 角色切换稳定复现；`ethtool -r`
在 nss-dp 上不支持；mdio 总线 unbind 会内核 panic——三个候选手段里已有
两个被排除，剩余唯一未测的运行期硬复位是驱动内的 PHY 级复位。对「根治
方向」的输入：不支持「驱动 `.resume` 重做 MMD30 0x145 复位 + phy_patch」
这一候选的任何 PHY 级证据（本轮没测到），但明确排除了外场「mdio unbind
冲一下」这种运维手段。
