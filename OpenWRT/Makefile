include $(TOPDIR)/rules.mk

PKG_NAME:=owrt-client
PKG_VERSION:=0.5.0
PKG_RELEASE:=1

PKG_LICENSE:=PolyForm-Noncommercial-1.0.0
PKG_MAINTAINER:=Endlad7373 <vladut7373@gmail.com>

PKG_BUILD_DEPENDS:=rust/host
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

define Package/owrt-client
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=LaLune OpenWRT client (CSQTT)
  DEPENDS:=+kmod-tun
  URL:=https://github.com/Endlad2/LaLune
endef

define Package/owrt-client/description
  LaLune клиент для OpenWRT. Скачивает ядро CSQTT в /tmp, парсит config
  рядом с бинарником, запускает ядро в фоне. CLI: logs/stop/status.
endef

define Package/owrt-client/conffiles
/etc/owrt-client/
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
	$(CP) ./Cargo.toml $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(call Build/Compile/Cargo)
endef

define Package/owrt-client/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/target/$(RUSTC_TARGET_ARCH)/release/owrt-client $(1)/usr/bin/owrt-client

	$(INSTALL_DIR) $(1)/etc/owrt-client
	$(INSTALL_DIR) $(1)/etc/init.d
endef

$(eval $(call BuildPackage,owrt-client))
