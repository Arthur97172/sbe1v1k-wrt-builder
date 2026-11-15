# mosdns 5.3.4-r15（sbwml 的补丁版）预编译二进制包装包。
#
# 为什么不从源码构建：上游 mosdns v5.3.4 的 go.mod 已要求 go 1.24.9，
# sbwml 的依赖补丁（mosdns/patches/100-mosdns-update-dependencies.patch）又把它
# 升到 1.26.0；本树（24.10 + QSDK 12.1）的 golang/host 固定为 1.23.12，且
# golang-package.mk 强制 GOTOOLCHAIN=local，单个包无法自行换工具链。把
# feeds/packages/lang/golang 整体换成 26.x 会同时改变 mihomo-meta、xray-core、
# sing-box、yq 等所有 Go 包的编译环境（理由与 PROVENANCE §2.9 中放弃上游
# xray/sing-box 新版的取舍相同）。
#
# 二进制来源：https://github.com/sbwml/luci-app-mosdns 的 Release 资产
#   v5.3.4-r15/aarch64_cortex-a53-openwrt-24.10.tar.gz
# 上游 CI（openwrt-gh-action-sdk@go1.27，24.10 SDK、aarch64_cortex-a53）产出，
# 内含 mosdns / geo2txt / luci-app-mosdns / v2ray-geoip / v2ray-geosite 的 ipk。
# 本包只取其中静态链接的 mosdns 可执行文件；luci-app-mosdns 与 geo2txt 仍从
# 源码构建（见 build/thirdparty-feeds.conf 的 repo mosdns-luci）。
# 供应链：LICENSE_REVIEW_REQUIRED（预编译二进制，GPL-3.0；tarball 的 sha256 钉死，
# 版本与 pin 记录在 PROVENANCE.md §2.9）。

include $(TOPDIR)/rules.mk

PKG_NAME:=mosdns
PKG_VERSION:=5.3.4
PKG_RELEASE:=15

PKG_LICENSE:=GPL-3.0
PKG_LICENSE_FILE:=LICENSE
PKG_MAINTAINER:=sbwml <admin@cooluc.com>

include $(INCLUDE_DIR)/package.mk

# Release 资产名固定带目标架构与 SDK 版本；本固件只有 ipq95xx（aarch64_cortex-a53）
# 一个目标，直接写死并在 Build/Prepare 里核对 ipk 名。
MOSDNS_ASSET:=aarch64_cortex-a53-openwrt-24.10.tar.gz
MOSDNS_IPK:=mosdns_$(PKG_VERSION)-r$(PKG_RELEASE)_aarch64_cortex-a53.ipk

PKG_SOURCE:=$(MOSDNS_ASSET)
PKG_SOURCE_URL:=https://github.com/sbwml/luci-app-mosdns/releases/download/v$(PKG_VERSION)-r$(PKG_RELEASE)
PKG_HASH:=4f1031ce2a8b44246b3e6efe0d92013dfb329226e8e62821dd18852bbcdf3b14

define Package/$(PKG_NAME)
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=IP Addresses and Names
  TITLE:=A plug-in DNS forwarder/splitter
  URL:=https://github.com/IrineSistiana/mosdns
  DEPENDS:=+ca-bundle
endef

define Package/$(PKG_NAME)/description
  mosdns 5.3.4 with sbwml's stats_api / adblock_set / query-log patches,
  shipped as the statically linked aarch64 binary from the luci-app-mosdns
  release asset. No init script or config: luci-app-mosdns owns
  /etc/init.d/mosdns and /etc/config/mosdns.
endef

# 上游 CI 产出的 .ipk 是 tar.gz（内含 ./debian-binary、./control.tar.gz、
# ./data.tar.gz），不是 opkg 传统的 ar 归档；旧版本的文件才用 ar p 取。
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	tar -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR) packages_ci/$(MOSDNS_IPK)
	tar -xzf $(PKG_BUILD_DIR)/packages_ci/$(MOSDNS_IPK) \
		-C $(PKG_BUILD_DIR) ./data.tar.gz
	tar -xzf $(PKG_BUILD_DIR)/data.tar.gz -C $(PKG_BUILD_DIR) ./usr/bin/mosdns
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/mosdns $(1)/usr/bin/mosdns
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
