# SPDX-License-Identifier: Apache-2.0
#
# Install the LuCI feed first so luci.mk exists:
#   ./scripts/feeds update luci && ./scripts/feeds install -a -p luci-base
#
# Then add this feed (see openwrt-feed/README.md).

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Firewall Live View (nftables)
LUCI_DEPENDS:=+luci-base +logd +rpcd +firewall4

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=fwview contributors

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
