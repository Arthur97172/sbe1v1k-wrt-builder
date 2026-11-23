include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=qca-nss-dp
PKG_LICENSE:=ISC
PKG_SOURCE_PROTO:=git
PKG_BRANCH:=master
PKG_RELEASE:=1
MAKE_OPTS:=

LOCAL_SRC:=$(TOPDIR)/qca/src/nss/base/qca-nss-dp

include $(INCLUDE_DIR)/local-development.mk
ifeq ($(DUMP)$(PKG_VERSION),)
  PKG_VERSION:=$(shell git ls-remote $(PKG_SOURCE_URL) $(PKG_BRANCH) | cut -b -7)
endif

include $(INCLUDE_DIR)/package.mk

# 25.12 的板型符号：qualcommbe 目标 + ipq95xx 子目标。
# 厂商版本写的是 TARGET_ipq95xx（厂商自己的 target 名），这里换成本项目的。
define KernelPackage/qca-nss-dp
  SECTION:=kernel
  CATEGORY:=Kernel modules
  SUBMENU:=Network Devices
  # dp-ppe-ds=y 让 nss_dp_attach.c 直接引用 ppe_drv_* 符号和
  # <ppe_drv_public.h>；头文件由 qca-nss-ppe 的 Build/InstallDev 装进
  # staging_dir/usr/include/qca-nss-ppe。没有这条依赖，两者会在同一个
  # `make -j` 里并行，dp 抢在 ppe 之前编译 → "ppe_drv_public.h: No such
  # file or directory"。运行时也依赖 qca-nss-ppe.ko 提供符号，所以写进
  # DEPENDS 而不是 PKG_BUILD_DEPENDS。
  DEPENDS:=@TARGET_qualcommbe_ipq95xx \
		+kmod-qca-ssdk-nohnat +kmod-qca-nss-ppe
  TITLE:=Kernel driver for NSS data plane
  FILES:=$(PKG_BUILD_DIR)/qca-nss-dp.ko
  # AUTOLOAD disabled for 25.12 NSS bring-up; loaded on demand by /usr/sbin/nss-load (see docs/NSS_AUTOLOAD_OFF.md).
  #  AUTOLOAD:=$(call AutoLoad,31,qca-nss-dp)
endef

define KernelPackage/qca-nss-dp/Description
This package contains a NSS data plane driver for QCA chipset
endef

define Build/InstallDev
	mkdir -p $(1)/usr/include/qca-nss-dp
	$(CP) $(PKG_BUILD_DIR)/exports/* $(1)/usr/include/qca-nss-dp/
endef

EXTRA_CFLAGS+= \
	-I$(STAGING_DIR)/usr/include/qca-ssdk \
	-I$(STAGING_DIR)/usr/include/qca-nss-ppe

subtarget:=$(SUBTARGET)

ifeq ($(CONFIG_KERNEL_IPQ_MEM_PROFILE),256)
EXTRA_CFLAGS+= -DNSS_DP_MEM_PROFILE_LOW
else ifeq ($(CONFIG_LOWMEM_FLASH),y)
EXTRA_CFLAGS+= -DNSS_DP_MEM_PROFILE_LOW
else ifeq ($(CONFIG_KERNEL_IPQ_MEM_PROFILE),512)
EXTRA_CFLAGS+= -DNSS_DP_MEM_PROFILE_MEDIUM
endif

ifeq ($(CONFIG_TARGET_qualcommbe_ipq95xx_generic_QSDK_MinEnt)$(CONFIG_TARGET_qualcommbe_ipq95xx_generic_QSDK_MinEntOpen), y)
EXTRA_CFLAGS+= -DNSS_DP_POINT_OFFLOAD
endif

ifeq ($(CONFIG_TARGET_ipq53xx_generic_QSDK_MinEnt)$(CONFIG_TARGET_ipq53xx_generic_QSDK_MinEntOpen), y)
EXTRA_CFLAGS+= -DNSS_DP_VP_RINGS
endif

ifneq ($(CONFIG_DEFAULT_kmod-netstandby-eawtp-drv),)
MAKE_OPTS+=CONFIG_QCA_NSS_DP_EAWTP=y
endif

ifneq ($(CONFIG_TARGET_qualcommbe_ipq95xx)$(CONFIG_TARGET_ipq53xx)$(CONFIG_TARGET_ipq54xx)$(CONFIG_TARGET_ipq52xx)$(CONFIG_TARGET_ipq96xx),)
EXTRA_CFLAGS+= -DNSS_DP_NETSTANDBY
MAKE_OPTS+=dp-net-standby=y
ifneq ($(CONFIG_TARGET_qualcommbe_ipq95xx_generic_QSDK_MinEnt)$(CONFIG_TARGET_qualcommbe_ipq95xx_generic_QSDK_MinEntOpen)$(CONFIG_TARGET_ipq52xx)$(CONFIG_TARGET_ipq96xx), y)
MAKE_OPTS+=dp-loopback=y
endif
endif

MAKE_OPTS+=dp-ppe-ds=y
ifneq ($(CONFIG_TARGET_ipq96xx)$(CONFIG_TARGET_ipq52xx),)
MAKE_OPTS+=dp-ddrq=y
MAKE_OPTS+=dp-udp-st=y
endif

ifeq ($(CONFIG_TARGET_ipq52xx_ipq52xx_32_QSDK_Sfu), y)
MAKE_OPTS+=dp-sfu=y
endif

NSS_DP_HAL_DIR:=$(PKG_BUILD_DIR)/hal
ifneq (, $(findstring _64, $(subtarget)))
hal_arch:=$(subst _64,,$(subtarget))
else ifneq (, $(findstring _32, $(subtarget)))
hal_arch:=$(subst _32,,$(subtarget))
else
hal_arch:=$(subtarget)
endif

ifneq (, $(findstring $(hal_arch),"ipq95xx" "ipq53xx" "ipq54xx" "ipq96xx" "ipq52xx"))
define KernelPackage/qca-nss-dp/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/qca-nss-dp.init $(1)/etc/init.d/qca-nss-dp
	$(INSTALL_BIN) ./files/qca-nss-dp.conf $(1)/etc/config/qca_nss_dp
	$(INSTALL_BIN) ./files/edma_dump $(1)/usr/bin/edma_dump
	$(INSTALL_BIN) ./files/edma_recover.sh $(1)/usr/bin/
	$(INSTALL_BIN) ./files/edma_hang_inj.sh $(1)/usr/bin/
	$(INSTALL_BIN) ./files/nss_cfg_$(hal_arch).ini $(1)/etc/config/nss_cfg.ini
endef
endif

define Build/Configure
	$(LN) $(NSS_DP_HAL_DIR)/soc_ops/$(hal_arch)/nss_$(hal_arch).h \
		$(PKG_BUILD_DIR)/exports/nss_dp_arch.h
endef

define Build/Compile
	$(KERNEL_MAKE) $(strip $(MAKE_OPTS)) \
		M="$(PKG_BUILD_DIR)" \
		EXTRA_CFLAGS="$(EXTRA_CFLAGS)" KCFLAGS="$(OPENWRT_KCFLAGS) $(EXTRA_CFLAGS)" SoC="$(hal_arch)" \
		modules
endef

$(eval $(call KernelPackage,qca-nss-dp))
