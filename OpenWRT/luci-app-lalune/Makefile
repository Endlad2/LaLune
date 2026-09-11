include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-lalune
PKG_VERSION:=0.5.0
PKG_RELEASE:=1

PKG_LICENSE:=PolyForm-Noncommercial-1.0.0
PKG_MAINTAINER:=Endlad7373 <vladut7373@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-lalune
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LaLune VPN client
  DEPENDS:=+luci-base +lalune
  PKGARCH:=all
endef

define Package/luci-app-lalune/description
  LuCI-интерфейс для клиента LaLune (CSQTT VPN).
  Настройки, конфиги, статус подключения, обновление ядра.
endef

define Build/Compile
endef

define Package/luci-app-lalune/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/lalune
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/lalune
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d

	$(INSTALL_DATA) ./luasrc/controller/lalune.lua $(1)/usr/lib/lua/luci/controller/lalune.lua
	$(INSTALL_DATA) ./luasrc/model/cbi/lalune/settings.lua $(1)/usr/lib/lua/luci/model/cbi/lalune/settings.lua
	$(INSTALL_DATA) ./luasrc/model/cbi/lalune/configs.lua $(1)/usr/lib/lua/luci/model/cbi/lalune/configs.lua
	$(INSTALL_DATA) ./luasrc/view/lalune/status.htm $(1)/usr/lib/lua/luci/view/lalune/status.htm
	$(INSTALL_DATA) ./luasrc/view/lalune/logs.htm $(1)/usr/lib/lua/luci/view/lalune/logs.htm
	$(INSTALL_DATA) ./luasrc/view/lalune/info.htm $(1)/usr/lib/lua/luci/view/lalune/info.htm
endef

$(eval $(call BuildPackage,luci-app-lalune))
