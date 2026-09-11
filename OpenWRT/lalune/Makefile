include $(TOPDIR)/rules.mk

PKG_NAME:=lalune
PKG_VERSION:=0.5.0
PKG_RELEASE:=1

PKG_LICENSE:=PolyForm-Noncommercial-1.0.0
PKG_MAINTAINER:=Endlad7373 <vladut7373@gmail.com>

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_USE_MIPS16:=0

GO_PKG:=lalune-openwrt
GO_PKG_BUILD_PKG:=lalune-openwrt

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/lalune
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=LaLune VPN client (CSQTT)
  DEPENDS:=$(GO_ARCH_DEPENDS) +ip-full +kmod-tun
  URL:=https://github.com/Endlad2/LaLune
endef

define Package/lalune/description
  Демон LaLune для OpenWRT. Управляет ядром CSQTT, поднимает TUN-интерфейс,
  создаёт UDP-мост к ядру, предоставляет CLI и unix-сокет для LuCI.
endef

define Package/lalune/conffiles
/etc/lalune/
/etc/config/lalune
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(call GoPackage/Build/Compile)
endef

define Package/lalune/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/lalune-openwrt $(1)/usr/bin/lalune

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/lalune.init $(1)/etc/init.d/lalune

	$(INSTALL_DIR) $(1)/etc/lalune
	$(INSTALL_DIR) $(1)/etc/lalune/core

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/lalune.config $(1)/etc/config/lalune

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/lalune.defaults $(1)/etc/uci-defaults/90-lalune
endef

define Package/lalune/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
    /etc/init.d/lalune enable
    /etc/init.d/lalune start
}
exit 0
endef

$(eval $(call BuildPackage,lalune))
