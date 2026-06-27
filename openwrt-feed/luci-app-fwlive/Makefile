# SPDX-License-Identifier: Apache-2.0
#
# Wire feed first (see openwrt-feed/README.md and feeds.conf.example):
#   ./scripts/feeds update luci packages fwlive
#   ./scripts/feeds install luci-base luci-app-fwlive

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Firewall Live View
LUCI_DESCRIPTION:=Live firewall log table (nftables/fw4 and iptables LOG) with filters
LUCI_DEPENDS:=+luci-base +logd +rpcd
LUCI_PKGARCH:=all

PKG_VERSION:=0.1.18
PKG_RELEASE:=1

# Reproducible build: honor SOURCE_DATE_EPOCH from the build environment (set by docker-sdk.sh / CI).
ifdef SOURCE_DATE_EPOCH
export SOURCE_DATE_EPOCH
endif

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=fwlive contributors <https://github.com/lucas-albers-lz4/fwlive>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
