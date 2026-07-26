# Documentation

Two audiences, two entry points:

## [User guide](user/README.md)

Install and use **Firewall Live View** on an OpenWrt router.

- [What it does](user/overview.md)
- [Install](user/installation.md)
- [Using the UI](user/using-the-ui.md) — includes screenshots
- [Enable firewall logs](user/enabling-firewall-logs.md)

## [Developer guide](developer/README.md)

Build, test, and extend the package from this repository.

- [Environment](developer/environment.md)
- [Architecture](developer/architecture.md)
- [Build & test](developer/build-and-test.md)
- [QEMU lab](developer/qemu-lab.md)
- [Contributing](developer/contributing.md)

---

## Reference (deep dives)

| Document | Topic |
|----------|-------|
| [binary-feed.md](binary-feed.md) | Signed opkg/apk feed install |
| [openwrt-21.02-compat.md](openwrt-21.02-compat.md) | Legacy fw3 / 21.02.x |
| [openwrt-22.03-compat.md](openwrt-22.03-compat.md) | EOL fw4 / 22.03.x |
| [openwrt-23.05-compat.md](openwrt-23.05-compat.md) | 23.05.x lab notes |
| [fwlive-acceptance.md](fwlive-acceptance.md) | Sign-off criteria |
| [fwlive-ui-design-target.md](fwlive-ui-design-target.md) | UI module map |
| [ROADMAP.md](ROADMAP.md) | Roadmap, milestones & backlog |
| [openwrt-fwlive-schema.md](openwrt-fwlive-schema.md) | Normalized log schema |
| [fwlive-nft-logging.md](fwlive-nft-logging.md) | nft/fw4 logging reference |
| [sdk-build-matrix.md](sdk-build-matrix.md) | SDK versions & targets |
| [validation-matrix.md](validation-matrix.md) | QEMU validation scripts |
| [opnsense-liveview-parity.md](opnsense-liveview-parity.md) | Parity matrix |
| [github-publish-checklist.md](github-publish-checklist.md) | Pre-publish checks |
| [CHANGELOG.md](../CHANGELOG.md) | Release history |
| [FAQ.md](FAQ.md) | Common questions |

`docs/dev-environment.md` is a stub note — see the [Developer guide → Environment](developer/environment.md) instead.
