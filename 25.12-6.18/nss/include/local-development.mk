# allow for local directory containing source to be used

LOCAL_SRC ?= $(TOPDIR)/qca/src/$(PKG_NAME)

ifeq (exists, $(shell [ -d $(LOCAL_SRC) ] && echo exists))
# No git revision in PKG_VERSION.
#
# 25.12 builds with apk, whose version grammar requires every dot-separated
# component to start with a digit.  The vendor's "g<sha>" form yields e.g.
# "6.12.112.g57ab21c-r1", which apk rejects ("package version is invalid").
# The revision is not reachable either way: build/sbe1v1k-build.sh exports
# GIT_CEILING_DIRECTORIES=<workspace>/sources, so `git describe` inside the
# assembly tree fails and the string degenerates to a bare "g" - the exact
# value that broke kmod-qca-mdio.  Leaving PKG_VERSION unset gives these
# kernel modules the same version shape as every in-tree kmod.
#
# Cost: PKG_BUILD_DIR drops the "-g<sha>" suffix, so packages built from an
# older assembly tree need `package/<pkg>/clean` after installing this file.
PKG_SOURCE_URL:=
PKG_UNPACK=mkdir -p $(PKG_BUILD_DIR); $(CP) $(LOCAL_SRC)/* $(PKG_BUILD_DIR)/
endif

# 6.15 起 kbuild 删除了 EXTRA_CFLAGS 支持（scripts/Makefile.lib 不再引用）：
# NSS 各包过去用它传 -I$(STAGING_DIR)/usr/include/qca-ssdk 等路径，6.18 上
# 这些参数会被静默丢弃（fal/fal_rss_hash.h 找不到）。等效通道只剩 KCFLAGS
# （KBUILD_CFLAGS += $(KCFLAGS)），而 OpenWrt 的 KERNEL_MAKE_FLAGS 自己也在
# 传 KCFLAGS；命令行上重复赋值时后者覆盖前者，所以这里把 kernel.mk 的取值
# 原样重算一份，各包编译时再用 KCFLAGS="$(OPENWRT_KCFLAGS) $(EXTRA_CFLAGS)"。
# 若上游改了 kernel.mk 的这一行，本变量需同步（比较：include/kernel.mk
# KERNEL_MAKE_FLAGS 里的 KCFLAGS=）。
OPENWRT_KCFLAGS = $(call iremap,$(BUILD_DIR),$(notdir $(BUILD_DIR))) \
	$(IREMAP_STAGING_DIR) $(IREMAP_TOOLCHAIN_DIR) \
	$(filter-out -fno-plt,$(call qstrip,$(CONFIG_EXTRA_OPTIMIZATION))) \
	$(call qstrip,$(CONFIG_KERNEL_CFLAGS))
