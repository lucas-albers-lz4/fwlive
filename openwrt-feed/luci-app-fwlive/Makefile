# SPDX-License-Identifier: Apache-2.0
#
# Wire feed first (see openwrt-feed/README.md and feeds.conf.example):
#   ./scripts/feeds update luci packages fwview
#   ./scripts/feeds install luci-base luci-app-fwlive

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Firewall Live View
LUCI_DESCRIPTION:=Live nftables firewall log table with filters (OPNsense-style)
LUCI_DEPENDS:=+luci-base +logd +rpcd +firewall4
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=fwview contributors <https://github.com/YOUR_ORG/fwview>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
