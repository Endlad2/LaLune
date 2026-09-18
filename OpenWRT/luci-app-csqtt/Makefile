#
# Copyright (C) 2026 LaLune / CSQTT OpenWRT LuCI app
#
# This is free software, licensed under the PolyForm Noncommercial License 1.0.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-csqtt
PKG_VERSION:=0.5.0
PKG_RELEASE:=1
PKG_LICENSE:=PolyForm-Noncommercial-1.0.0
PKG_MAINTAINER:=Endlad7373 <vladut7373@gmail.com>

LUCI_TITLE:=LuCI app for CSQTT VPN (LaLune OpenWRT)
LUCI_DESCRIPTION:=Web UI для подключения к CSQTT: \
	ввод csqtt:// ссылки, VK-токена, количества хешей и воркеров, \
	кнопка «Подключить», запускающая официальный установочный скрипт \
	csqtt-openwrt, а также вкладка «Поддержать» и просмотр логов.
LUCI_DEPENDS:=+curl +unzip +ca-bundle +kmod-tun +luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# $(eval $(call BuildPackage,luci-app-csqtt))
