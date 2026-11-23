# qca-ssdk-shell：厂商 SSDK 用户态工具 ssdk_sh + libssdk_us.so（ISC）。
#
# 阶段 B（docs/WAN_LAN_ROLE_SWITCH 4.6）：WAN/LAN 端口角色在运行期要用
# `ssdk_sh portVlan member update` 改 SSDK 成员表（无 DSA，芯片级隔离只有
# 这张表），所以必须随镜像提供。24.10-6.6 一直带它；25.12 此前没打包，
# /usr/sbin/sbe-port-roles 遇到 eth0/none 角色只能 fail closed。
#
# 源码来自 NSS 源码包（nss-src-v1 的 apps-oss/qca-ssdk-shell），由
# nss/install.sh 复制到 qca/src/nss/apps-oss/ 下；local-development.mk 让
# 包直接编译这棵目录，不再另取 tarball。
#
# 构建参数与厂商 feeds/nss/apps-oss/qca-ssdk-shell/Makefile 相同：工具只
# 需要内核 uapi（SYS_PATH=$(LINUX_DIR)）与交叉工具链前缀，不链接 qca-ssdk
# 内核模块。DEPENDS 里有 kmod-qca-ssdk-nohnat（/dev/switch_ssdk 的提供者）
# 和 libgcc：两个二进制都链了 libgcc_s.so.1，apk 不会自动补这条。模块是否
# 装载仍由 nss-load 按档位决定，tier=off 时 ssdk_sh 会报设备不存在，
# sbe-port-roles 据此保持 UCI 不动。

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=qca-ssdk-shell
PKG_LICENSE:=ISC
PKG_SOURCE_PROTO:=git
PKG_BRANCH:=master
PKG_RELEASE:=1

LOCAL_SRC:=$(TOPDIR)/qca/src/nss/apps-oss/qca-ssdk-shell

include $(INCLUDE_DIR)/local-development.mk
# local-development.mk 把 PKG_SOURCE_URL 置空（源码取自 LOCAL_SRC），此时不能
# 再 git ls-remote，否则每次求值都打 "fatal: bad repository ''"。版本号留空，
# apk 记作 1；源码由 NSS 源码包的 sha256 门禁保证可复现。
ifeq ($(DUMP)$(PKG_VERSION),)
  ifneq ($(PKG_SOURCE_URL),)
    PKG_VERSION:=$(shell git ls-remote $(PKG_SOURCE_URL) $(PKG_BRANCH) | cut -b -7)
  endif
endif

include $(INCLUDE_DIR)/package.mk

define Package/qca-ssdk-shell
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=QCA SSDK shell application (ssdk_sh)
  DEPENDS:=+kmod-qca-ssdk-nohnat +libgcc
endef

define Package/qca-ssdk-shell/Description
 Shell application for the QCA SSDK. Maintains switch-level tables that
 have no netdev representation on this board (port-based VLAN member
 maps, FDB flush). Used by /usr/sbin/sbe-port-roles to change the
 WAN/LAN port role at runtime.
endef

ifndef CONFIG_TOOLCHAIN_BIN_PATH
CONFIG_TOOLCHAIN_BIN_PATH=$(TOOLCHAIN_DIR)/bin
endif

# 厂商 shell 代码是 2010 年代的 C：函数指针表全部写成 `sw_error_t (*f)();`
# 再按多参调用。GCC 15 默认 -std=gnu23，`()` 变成“零参数”原型，这些调用
# 全部报 too many arguments（6.12 树用 gcc-14，不受影响）。工具的用途只是
# 写 SSDK 表，按 gnu17 语义编译即可，不改厂商源码。
QCASSDK_CONFIG_OPTS+= TOOL_PATH=$(CONFIG_TOOLCHAIN_BIN_PATH) \
                SYS_PATH=$(LINUX_DIR) \
                TOOLPREFIX=$(TARGET_CROSS) \
                KVER=$(LINUX_VERSION) \
                CFLAGS="$(TARGET_CFLAGS) -std=gnu17" \
                LDFLAGS="$(TARGET_LDFLAGS)" \
                ARCH=$(LINUX_KARCH)

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) $(strip $(QCASSDK_CONFIG_OPTS))
endef

define Package/qca-ssdk-shell/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/build/bin/ssdk_sh $(1)/usr/sbin/
	$(INSTALL_DIR) $(1)/usr/lib
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/build/bin/libssdk_us.so $(1)/usr/lib/
endef

$(eval $(call BuildPackage,qca-ssdk-shell))
