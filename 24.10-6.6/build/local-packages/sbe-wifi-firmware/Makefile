#
# SBE1V1K local firmware package
#
# Carries the QCN92XX Wi-Fi firmware and board data taken from the vendor
# QSDK14 image (package sbe-full-candidate, version 23).  The blobs are
# proprietary: LICENSE_REVIEW_REQUIRED (project decision N-3).
#
# Provenance and per-file SHA-256 are recorded in files/FILES-SHA256 and in
# docs/STAGE3_INTEGRATION_PLAN.md §6.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-wifi-firmware
PKG_VERSION:=23
PKG_RELEASE:=1

PKG_LICENSE:=Proprietary
PKG_LICENSE_FILES:=LICENSE-STATUS

PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/sbe-wifi-firmware
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Spectrum SBE1V1K QCN92XX firmware and board data
  DEPENDS:=+kmod-ath12k
  PKGARCH:=all
endef

define Package/sbe-wifi-firmware/description
 QCN92XX firmware (firmware-2.bin), board data (board-2.bin), regulatory
 database (regdb.bin) and the vendor BDF41 variants (b1/b2/b4) for the
 Spectrum SBE1V1K.  Extracted verbatim from the vendor QSDK14 image; the
 files are proprietary and their redistribution terms have not been
 reviewed: LICENSE_REVIEW_REQUIRED.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./files/. $(PKG_BUILD_DIR)/
	(cd $(PKG_BUILD_DIR) && sha256sum -c FILES-SHA256)
endef

define Build/Compile
endef

define Package/sbe-wifi-firmware/install
	$(INSTALL_DIR) $(1)/lib/firmware/ath12k/QCN92XX/hw1.0
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/lib/firmware/ath12k/QCN92XX/hw1.0/*.bin \
		$(1)/lib/firmware/ath12k/QCN92XX/hw1.0/
	$(INSTALL_DIR) $(1)/usr/share/sbe-wifi/bdf41
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/usr/share/sbe-wifi/bdf41/*.bin \
		$(1)/usr/share/sbe-wifi/bdf41/
	$(INSTALL_DIR) $(1)/usr/share/sbe-wifi-firmware
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/FILES-SHA256 \
		$(1)/usr/share/sbe-wifi-firmware/FILES-SHA256
endef

$(eval $(call BuildPackage,sbe-wifi-firmware))
