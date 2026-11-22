# 25.12-6.12 踩坑清单 → 25.12-6.18 检查项

本文件把 6.12 树里已经付过代价的结论，逐条转成 6.18 的检查动作。每条都注明
适用阶段：S1=上游基线、S1b=首次真机、S2=overlay、S3=NSS、S4=功能对齐。

## 内核/启动

| # | 6.12 的坑 | 结论 | 6.18 动作 | 阶段 |
|---|---|---|---|---|
| 1 | CPU OPP/cpufreq 一上线就挂死（v52–v55） | 板级 DTS 的 `operating-points-v2` 必须删；上游 sbe1v1k DTS 目前**没有** OPP 节点 | 引入任何厂商 DTS 片段前先 grep `operating-points` | S2/S3 |
| 2 | `register_sysctl` 在 6.11+ 把 `{}` 哨兵算进表头，PPE 拆除路径 oops | 必须用新签名的补丁（6.12 的 0025/0008） | 6.18 同样 ≥6.11，NSS 的 ppe 代码必须同修；编译期就能看到签名告警 | S3 |
| 3 | qca8084-phy 与内置 `QCA808X_PHY` 抢名 `-16`，ssdk/ppe/dp 全挂 | 6.12 用 0030 只保留 8081、丢弃 8084 的注册 | 6.18 上游 `CONFIG_QCA83XX_PHY` 在；搬 ssdk 时先查重名注册 | S3 |
| 4 | eMMC：6.6 系 QSDK 内核在原厂 APPSBL 槽路径全挂 | 6.12 靠 0021/0022/0028 与上游平台脚本解决 | 6.18 上游 `platform.sh` 已有 `askey,sbe1v1k` 分支，S1b 只验证、不重造 | S1b |
| 5 | initramfs 未压缩嵌入触发 APPSBL 64 MiB 上限 | 6.12 用 XZ + 128 MiB 字典（0019/0031） | 6.18 的 initramfs 由上游生成，S1b 记录实际大小 | S1b |

## 数据通路/网络

| # | 6.12 的坑 | 结论 | 6.18 动作 | 阶段 |
|---|---|---|---|---|
| 6 | 无 DSA，LAN/WAN 角色靠 ssdk 成员表 | 切角色必须同步成员表+UCI+attach helper | NSS 阶段复用 6.12 的 `sbe-port-roles` 逻辑 | S3 |
| 7 | eth1（2.5G）在 2500 静默、1000F 正常 | 根因是 25.12 树里 QCA8084 驱动抢绑（0030 修） | 6.18 用上游 QCA8081 PHY 驱动；S1b 必须专门测 2.5G 链路速率 | S1b |
| 8 | 摘桥后 STP 状态留 `CST_STATE=0`，PPE 入口 STG 过滤整口丢帧（dropcode 115） | 6.12 的 0009 修在 qca-nss-dp | 搬 nss-dp 时把此修一起带过来，判据 `/sys/ssdk/packet_counter` | S3 |
| 9 | 删 uniphy XPCS `resets` 消 WARN 会让所有 dp 端口零帧 | `resets` 一律保留 | 6.18 DTS 同样保留；NSS DTS 生成时不要“顺手清理” | S3 |
| 10 | nsscc port5 时钟父节点必须是 PCS，否则 WAN RX=0 | 6.12 的 0037 开 PCS 驱动并补 pcs0/1/2 | 搬 NSS DTS 时核对时钟父节点 | S3 |
| 11 | MDIO 复位 GPIO：60=qca8075、52=QCA8081、41=RTL8261N；数组脉冲写法 | 上游 6.18 DTS 已带 41/52（且是 reset-gpios） | S1b 只读核对，不改 | S1b |
| 12 | eth0（10G）USXGMII AN 约一半启动假链路、只有重启能恢复 | 6.12 用 S95 看门狗（采样 `VR_MII_AN_INTR_STS`，0x7000=健康） | S2 把看门狗移植到 6.18（设备节点名可能不同，先只读比对） | S2 |
| 13 | RTL8261N 运行期 down/up 出现 10G 假环回 | 6.12 用 `eth0-lan-attach` 让 eth0 不被 netifd 摘桥 | 6.18 是 qcom_ppe/netdev 模型，先 S1b 观察是否复现 | S1b/S2 |

## 用户态/overlay

| # | 6.12 的坑 | 结论 | 6.18 动作 | 阶段 |
|---|---|---|---|---|
| 14 | 最小 initramfs 用 busybox 的 `insmod` 不存在 | 必须带 `/sbin/kmodloader` | 6.18 若做 diag/initramfs，照此检查 | S2 |
| 15 | `USE_PROCD=0` 的 `-n` 把 0 当“开”，服务被覆盖成空 | rc.common 脚本不要用 `USE_PROCD=0`；后台 worker 脚本整行省略 | 移植 6.12 的 init 脚本时逐行核对 | S2 |
| 16 | tar 选了但漏 `xz-utils`，三者被 defconfig 静默丢弃 | 相关包一组一起选，`check-packages` 反查 | S4 插件清单沿用 6.12 的 `required-packages.txt` 口径 | S4 |
| 17 | feed 索引 0 字节会静默丢整片 feed | prepare 必须断言 `.packageinfo` 非空 | 本树 `prepare-tree.sh` 已断言 | S1 |
| 18 | uci-defaults 的 runner 只预载 `system.sh`；不 source `functions.sh` 会静默 exit 0 | 默认值脚本先 source functions | S2 移植 `sbe1v1k-defaults` 时核对 | S2 |
| 19 | 风扇控制权：`pwm1_enable` 不是“交权”开关 | 用户态曲线驱动，别误判 cooling map | S2 移植风扇插件时保留结论 | S2 |
| 20 | `ledfancontrol` 读 ath12k 死链路 hwmon 会阻塞 10–17 s，拖死 iwinfo | 启动探测 + 白名单修复 | S2/S4 移植该包时带上源码修复 | S2/S4 |
| 21 | dawn core 崩溃循环（neighbor_report 溢出、iwinfo NULL） | 两处修复已真机 PASS | S4 接入 dawn 时带同名修复 | S4 |
| 22 | 无线 mesh 的 supplicant 全局项（noextns 等）来自 QSDK fork | 上游 wpad 不受影响，但 mesh 配置仍要真机验 | S1b 验 mesh，若失败再查配置 | S1b |
| 23 | TW 6GHz 依赖带 6GHz 规则的 regdb | 6.12 用 B 机提取的 v1.5 regdb | 6.18 先确认上游 ath12k 固件包带的 regdb；需要时再替换 | S1b |
| 24 | radio 编号随探测顺序变；LuCI 排序失效 | 6.12 用 0038/0039 钉死 radio0/1/2 与页面顺序 | S4 若复现，移植同名补丁 | S4 |
| 25 | `nss-boots` 预算会被快速重启测试累积到 fallback | 生产设计自愈；测试时手工清零 | S3 移植 nss-load 时保留该语义与文档 | S3 |
| 26 | 24.10 的 NSS 离线装载顺序：先 ppe-rule 再 sfe/ecm | 顺序错会缺 `ppe_rfs` 符号 | S3 移植时核对 kmodloader 顺序 | S3 |
| 27 | 构建时间戳固定、`GIT_CEILING_DIRECTORIES` 防版本串漂移 | 本树 build 脚本已沿用 | S5 CI 一并核对 | S1/S5 |

## 交付纪律（沿用）

- 本机编 → 静态校验 → 用户批准 → 真机测 → PASS 才推；
- 刷机 `sysupgrade -n`；不保留配置；
- 不把口令写进任何文件/脚本/命令；不连接未批准的目标路由器；
- 代码改动升 PKG_VERSION，纯文档不升；提交带
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。
