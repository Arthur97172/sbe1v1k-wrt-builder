#
# sbe1v1k-defaults — local (project-owned) first-boot overrides.
# Not part of the vendor source tree; see docs/BUILD_TREE_ASSEMBLY.md §6.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=sbe1v1k-defaults
PKG_VERSION:=1
PKG_RELEASE:=3
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/sbe1v1k-defaults
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=SBE1V1K local default overrides
  DEPENDS:=+ttyd
  PKGARCH:=all
endef

define Package/sbe1v1k-defaults/description
 Local uci-defaults overrides applied on first boot.  Sets ttyd's enable
 option to 0 so the web terminal stays off until the operator turns it on
 in LuCI, adds the Allow-LuCI-WAN and Allow-SSH-WAN firewall rules (tcp
 80/443 and 22 ACCEPT on the wan zone) so the box stays reachable over the
 provider uplink, and fills in /etc/opkg/distfeeds.conf so `opkg update`
 works on the otherwise empty feed list.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/sbe1v1k-defaults/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/99-ttyd-disable $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/99-allow-luci-wan $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/99-allow-ssh-wan $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/99-opkg-distfeeds $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,sbe1v1k-defaults))
