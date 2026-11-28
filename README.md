<h2>Spectrum SBE1V1K（ipq9574 / Askey）OpenWrt 固件构建仓库</h2>

本仓库为 SBE1V1K 维护三个独立固件线、一个离线刷机工具，各自在对应目录下构建、发布与维护：

<h3>24.10-6.6</h3>
基于 OpenWrt 24.10、内核 6.6 的稳定固件线，功能最全（含第三方插件、NSS 加速、无线 offload 等），日常使用与真机验证均以这条线为主。CI 产物发布到 GitHub Releases。

<h3>25.12-6.12</h3>
基于 OpenWrt 25.12、内核 6.12 的固件线，用于向上游新版本迁移；端口角色、NSS、无线等机制与 24.10 对齐。

<h3>25.12-6.18</h3>
基于 OpenWrt 25.12、内核 6.18 的固件线，跟随更新内核与主线驱动（如 rtl8261n），用于评估新内核在真机上的兼容性。

<h3>openwrt-flash</h3>
离线恢复模式刷机工具：断电按住 Reset 进入原厂恢复模式，脚本自动完成 DHCP/TFTP 送入恢复系统、上传校验与 <code>sysupgrade -F -n</code>，全程离线。提供 Linux 与 Windows 入口，以 zip 形式发布到 GitHub Releases。

<h3>其他说明</h3>
各固件线的构建流程、补丁、已知问题与真机验证状态见对应子目录的 README 与文档。
