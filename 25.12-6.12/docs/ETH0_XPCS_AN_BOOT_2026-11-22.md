# eth0（RTL8261N 10G）开机 XPCS AN 未完成导致数据面死锁 — 取证报告（2026-11-22）

镜像：`25.12-6.12 v89-1`（banner `sbe1v1k-25.12-ca795749`，Linux 6.12.112，
commit `ca795749` 系列）。设备：唯一在线 SBE1V1K（192.168.1.1），管理走主机
WiFi；eth0 接主机 USB 2.5G 网卡 `enxc84d4424a1b5`（静态 192.168.1.240/24）。
全部测试为只读寄存器读取 + 可回退寄存器写（实验后均已重启清除）。

## 结论

**是真 bug，不是误报。** 对 eth0（uniphy2 / port6，USXGMII + RTL8261N C45 PHY）
做 26 次顺序重启采样，**13 次失败（50%）**（各批 3/5、1/1、1/2、2/6、4/6、2/6，
无聚集趋势），失败与 dmesg 里的 `uniphy autoneg time out!` **一一对应**：

- 失败时 eth0 在软件层一切"正常"：`Link is Up - 2.5Gbps/Full`、
  carrier=1、speed=2500、br-lan 成员、XPCS 配置寄存器
  `SR_MII_CTRL=0x1120`（2.5G/全双工/AN 使能）、`VR_MII_AN_CTRL=0x101`
  与成功启动**逐位相同**；
- 唯一差异在 `VR_MII_AN_INTR_STS`（0x1f8002）：成功启动 `0x7000`
  （`usxg_an_sts=0x70`，AN 已完成），失败启动 `0x0`（AN 从未完成，
  连状态位都没有）；
- 失败时主机侧对 192.168.1.1 的 ping 100% 丢包，路由器 eth0 TX 计数增长、
  RX 恒 0（NSS offload 下 netdev 计数不足为凭，以 ping/ARP 为准）；
  ARP 层即不通 —— 说明是 SoC XPCS ↔ RTL8261N 之间的 USXGMII 系统侧
  握手失败，不是铜缆侧或主机网卡问题（两侧均报 2.5G 链路 UP）。

## 采样记录

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1–5 | `reboot-cycles.txt` 连续 5 次 reboot | F,F,P,F,P | 3 次失败均 100% 丢包 + `autoneg time out`（28.6–29.6 s） |
| 6 | `failboot-probe.txt` 第 1 次 | F | 抓到完整失败现场（见下） |
| 7–8 | `goodboot-dump.txt` 2 次 | F,P | `0x1f8002=0x0` / `0x7000`（对照组） |
| 9–14 | `xpcs-reinit-probe.txt` 6 次 | P,P,F,P,P,F | 2 次失败用于 XPCS 软复位实验 |
| 15–20 | `phy-reinit-probe.txt` 6 次 | F,P,P,F,F,F | 4 次失败用于 PHY 侧重初始化实验 |
| 21–26 | `fixedmode-probe.txt` 6 次 | P,P,P,P,F,F | 2 次失败用于固定速率实验 |

累计 **13/26 失败（50%）**。失败批次在时间上分散（06:36–07:25 之间六批），
与设备温度或主机侧状态无可见关联；唯一一致的预测因子是
`uniphy autoneg time out!` 这行日志本身。

## 寄存器对照（失败 vs 成功，均为 eth0 链路上报后约 20 s 读取）

| 寄存器 | 失败启动 | 成功启动 | 含义 |
|---|---|---|---|
| `0x1f8000` | `0x2000` | `0x2000` | 相同 |
| `0x1f8001` VR_MII_AN_CTRL | `0x101` | `0x101` | INTR_EN=1、MII_CTRL=1，相同 |
| `0x1f8002` VR_MII_AN_INTR_STS | **`0x0`** | **`0x7000`** | 唯一差异：`usxg_an_sts` 0 vs 0x70 |
| `0x1f0000` SR_MII_CTRL | `0x1120` | `0x1120` | 2.5G/全双工/AN 使能，相同 |
| `0x1f0001` | `0x0` | `0x0` | 相同 |

`ssdk_uniphy` 的 `reset(N) not exist!`、`set parent fail!` 报错在**成功与失败
启动中都同样出现**（成功启动 dmesg：18.1–27.6 s 各有若干条），与本次故障无关，
不要作为判据。

## 代码路径（已核对源码，两棵树 qca-ssdk 同版本同代码）

`qca-ssdk src/adpt/hppe/adpt_hppe_portctrl.c`：

- `adpt_hppe_uniphy_usxgmii_autoneg_completed()`（4140 行）：在 link up 沿
  轮询 `VR_MII_AN_INTR_STS.cl37_ancmplt_intr`，**只等 100 ms**，超时打印
  `uniphy autoneg time out!` 并返回 `SW_TIMEOUT`；
- `adpt_hppe_uniphy_autoneg_status_check()`（4203 行）：**丢弃返回值**；
- `qca_hppe_mac_sw_sync_task()`（4586 行，1000 ms 周期轮询）：up 沿无论
  AN 是否完成，都照常配置 MAC 速率并**无条件**重新打开 txmac/rxmac/
  bridge_txmac（4812–4814 行），然后把 `port_old_link=UP` 封存 ——
  于是这个"边沿"此后不会被重试。

所以打印本身只是"AN 没完成"的报警，真正的缺陷是：**AN 未完成时驱动仍把端口
标记为 UP 并按 2.5G 打通 MAC**，把一次可重试的握手失败固化成一整次的死链路。

另：`rtk8261n` PHY 驱动的 `config_init` 会先对 PHY 做 MMD30 0x145 bit0
软复位、再加载固件补丁（rtk_phy.c:73-110）。XPCS 侧 AN 在更早的 switch
初始化时就被使能（`SR_MII_CTRL` bit12），与 PHY 复位/补丁加载存在时序竞争——
这是目前最可疑的机制，但尚未最终取证。

## 恢复手段实测（失败启动上逐一尝试，全部在 4 个不同失败启动上复现）

| 手段 | 结果 |
|---|---|
| 主机侧换速重协商（真实 copper link down/up） | 无效 |
| `ssdk_sh port autoNeg restart 6`（PHY AN 重启） | 无效 |
| XPCS `SR_MII_CTRL` bit9 置位重启 AN | 无效 |
| XPCS 整块软复位（bit15）+ 重写 AN 使能 | **无效且更糟**：复位后 uniphy2 整块寄存器读回全 0（含 SR_MII_CTRL），后续写入不生效，直到重启才恢复 —— 裸寄存器 poke 不是可行修复路径，必须走 ssdk 内部带时钟/复位的初始化序列 |
| `ip link set eth0 down/up` | 无效；且 up 沿会把 XPCS 重配成 **10G**（`SR_MII_CTRL=0x3140`）、dp 报 `Link is Up - 10Gbps/Full`，仍然零流量——失败启动上 PHY 的速率回报本身不可信 |
| mdio 设备 unbind/bind（重跑 rtk8261n `config_init`：MMD30 软复位+固件补丁重载） | unbind/bind 均成功（rc=0）、dmesg 无异常，但 **AN 仍不完成、链路仍死** |
| XPCS 固定速率（`SR_MII_CTRL=0x120`：2.5G/全双工/AN 关） | 写入成功（回读 0x120）但 **链路仍 100% 丢包**；`ssdk_sh port autoNeg disable` 子命令不存在 |
| 重启 | 唯一能恢复（每次约 50%） |

结论：XPCS 侧或 PHY 侧**单独**重启 AN/复位、改固定速率都解不开这个死锁；
只有两侧在同一次上电路径里重新配对（即重启）才有概率成功。单侧"再握手"
不是修复方向。

## 修复：boot 后看门狗（方案一，2026-11-22 实施）

用户批准的方案一已落地（v92-1 刷机后修复了启动入口 bug，见下）：

- `files/usr/sbin/sbe-eth0-an-watchdog`：等 eth0 出载波（没插线不判死）后读
  uniphy2 `VR_MII_AN_INTR_STS`（0x1f8002），`usxg_an_sts`（bit8-14）两次
  采样（间隔 8 s）都为 0 即判死；按 `/etc/sbe-eth0-an-watchdog.count` 计数，
  最多自动重启 `max_reboots`（默认 1）次，防止重启循环；正常启动清零计数。
- `files/etc/init.d/sbe-eth0-an-watchdog` + `etc/rc.d/S95…`：S95 后台运行，
  不阻塞 rcS。
- `files/etc/config/sbe_eth0_watchdog`：`enabled`/`max_reboots` 两个开关。
- ssdk_sh 不可用（diag/mainline 变体）或读不到寄存器时不判死。

### 启动入口 bug：`USE_PROCD=0` 反而吞掉 start()（v92-1 真机取证）

v92-1（d444559）首次刷机恰逢坏启动，看门狗却毫无反应。排查确认 worker
在开机时根本没有被拉起，根因在 `/etc/rc.common` 的分支判定：

```sh
[ -n "$USE_PROCD" ] && {
	...
	start() { rc_procd start_service "$@"; }
}
```

`-n` 只判非空，`USE_PROCD=0` 也是非空字符串，于是进入 procd 分支，把脚本
自己定义的 `start()` **覆盖**成空的默认 `start_service()`——不报错、什么都不跑。
正确写法是后台 worker 式脚本**整行省略 `USE_PROCD`**。受影响的还有
`files/etc/init.d/sbe-boot-trace`（S01 启动取证，自 v35 上线以来同样从未
运行过，此前"启动取证没数据"的部分现象可由此解释）。

修复：两个 init 脚本删除该行并加注释说明；`scripts/ci/verify-image.sh`
新增断言——这两个脚本不得出现 `^[[:space:]]*USE_PROCD=` 且必须有 `start()`，
防止回归。真机验证：手动 `boot` 动作能拉起 worker（好启动写 count=0 后退出），
受控坏启动（`max_reboots=0`）下 S95 在开机后作出判定并记日志。

预期效果：坏启动在开机 ~30–45 s 被识别、再重启一次，绝大概率落在好启动；
代价是约一半的启动多花一次重启时间。根因修复（把 XPCS AN 启动与 RTL8261N
复位/补丁加载的时序竞争消除，或做带完整时钟序列的联合重初始化）单独立项。

### 真机验证（2026-11-22，状态：PASS）

设备：v92-1 镜像（`sbe1v1k-25.12-3fdd9fb2`）+ overlay 中修复了 USE_PROCD 的
两个 init 脚本（待下一版镜像固化）。主机侧 watcher 每 10 s 记录
`count`/SSH/eth0 ping 时间线（`logs/watchdog-verify/watcher.log`，gitignore）。

1. **受控坏启动**（`max_reboots=0`，日志不被重启冲掉）：第 2 次重启即抓到坏
   启动，日志留下「eth0 USXGMII AN 未完成，已自动重启 0 次，放弃本轮（端口
   保持假链路）」——S95 在开机时确实运行并正确判定。
2. **自动重启恢复**（`max_reboots=1`，12 轮 + 8 轮循环）：watcher 时间线共记录
   9 次坏启动，其中 8 次为 `count` 0→1 → SSH 断开（自动重启）→ 回来后
   `count=0`、`an=0x7000`、eth0 ping 通的健康启动；签名稳定：坏启动 SSH
   ~40 s 就绪，eth0 ping 要到 ~120–130 s（第二次启动）才通，健康启动 ~67 s
   全程就绪。
3. **放弃路径**：一次连续两次坏启动（上一轮自动重启后的启动仍是坏启动），
   第二次判定时 `count=1` 已达上限，日志「已自动重启 1 次，放弃本轮」，设备
   保持在线、无重启循环；下一轮手动重启即恢复。与设计一致。
4. 健康启动下 worker 写 `count=0` 后自行退出，无日志噪声。

已知局限：计数只防「同一次上电内」的循环；若设备被反复手动重启，每次坏启动
仍会各自动重启一次（设计如此）。

### 固化镜像验证（v93，本地构建，2026-11-22）

以上 PASS 是在 v92-1 镜像 + overlay 手工修脚本的条件下得到的。commit `11744a9`
把修复固化进镜像（`sbe1v1k-25.12-11744a97`，本地 `build-wifi-image.sh` 构建，
`sysupgrade -n` 刷入，镜像 sha256 `780dcdb0…` 在设备上预校验一致）后复测：

1. 刷后第一次启动即坏启动：dmesg `uniphy autoneg time out!`（78.9 s），S95
   在 ~90 s 判定 `VR_MII_AN_INTR_STS=0x0`、`自动重启 1/1`，`count` 写 1；
2. 自动重启后的第二次启动**仍是坏启动**（本次概率事件，0.5²）：S95 读到
   `count=1` 已达上限，走放弃路径 `已自动重启 1 次，放弃本轮`，设备保持
   在线（SSH/WiFi 正常，eth0 假链路 100% 丢包）；
3. 手动重启一次即健康启动：`count=0`（worker 写回并退出）、`an=0x7000`、
   eth0 经 USB 网卡 ping 3/3、WAN 取址 `192.168.10.239`、LuCI 200、
   `logread` 无看门狗日志。

随后 3 轮复查（每轮 `reboot` 等待归来）：第 1 轮坏启动 → 自动重启后第二次
**仍是坏启动** → 放弃路径；第 2、3 轮均为健康启动（`count=0`、`an=0x7000`、
ping 0% 丢包）。合计 v93 上 7 次启动 4 次坏（57%，与 50% 基线一致），但**两次
坏启动都成对出现**（第 1、2 次连续，第 4、5 次连续）。样本太小不能下结论，
但与此前 v92-1 的 9 坏 8 愈（仅 1 对连续）不同，后续多轮统计时留意是否真有
「重启后短窗口内 AN 更易失败」的相关性——若有，看门狗 `max_reboots=1` 的
代价（放弃路径概率）会比独立假设高。


## 证据文件

`logs/eth0rx-2026-11-22/`：`reboot-cycles.txt`、`failboot-probe.txt`、
`goodboot-dump.txt`、`goodboot-dmesg.txt`、`xpcs-reinit-probe.txt`、
`phy-reinit-probe.txt`、`fixedmode-probe.txt`（gitignore）。

时序参照（成功启动 dmesg，Linux 启动秒）：

- 19.19–19.36 s：ssdk uniphy 复位序列（报 `reset(1)/(3)/(5) not exist`，两态都有）；
- 19.85 s：`nss-dp ... PHY [90000.mdio-1:00] driver [Realtek RTL8261N]`（attach，
  随后 `config_init` 做 MMD30 复位 + 补丁加载）；
- 23.33 s：`eth0: configuring for phy/usxgmii link mode`；
- 28.5–29.4 s：`eth0: Link is Up - 2.5Gbps/Full`（dp 收到 PHY 链路通知）；
- 28.7–29.6 s：失败启动在此刻打印 `uniphy autoneg time out!`（100 ms 等待上限）。

即 XPCS AN 使能（~19 s）早于 PHY 复位+补丁加载完成（~23 s），竞争窗口约 4 s。

## 固定模式实验（2026-11-22，`fixedmode-probe.txt`）

在 2 个死锁启动上：`ssdk_sh port autoNeg disable 6` 报
`invalid or incomplete command`（该子命令不存在）；直接写
`SR_MII_CTRL=0x120`（2.5G、全双工、AN 关）写入成功（回读 0x120）但
ping 仍 100% 丢包、`0x1f8002` 仍为 0。说明死锁锁在串行器/PHY 侧状态，
不是"AN 没被启动"这么简单；固定速率不作为修复路径。
