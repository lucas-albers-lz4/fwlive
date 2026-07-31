# Contributing

## Principles

- **Small steps** — one behavior per change; verify in CLI + QEMU LuCI when UI-related
- **Parser sync** — edit `core/fwlive-log.js`, run `./scripts/gen-all.sh`, keep LuCI classify helpers + preserve-region presentation in parity (`fwlive-test.sh` enforces freshness)
- **No scope creep** — MVP is done; backlog items are in [`../ROADMAP.md`](../ROADMAP.md)

## Change workflow

1. Edit code (`core/` and/or LuCI package)
2. Run `./scripts/fwlive-test.sh`
3. Run `./scripts/validate-baseline.sh`
4. If LuCI or rpcd changed:
   ```sh
   ./scripts/qemu-install-fwlive.sh    # sync to running guest
   # manual check: http://localhost:8080/cgi-bin/luci/admin/status/fwlive
   ```
5. For release-level confidence:
   ```sh
   ./scripts/validate-openwrt.sh --version 24.10 --skip-build
   ```

## Parser sync / codegen

`fwlive-test.sh` includes classify goldens, shell↔JS parity, and codegen freshness (`gen-shell-classifier.js` / `gen-luci-wrapper.js`). After editing the parser, run `./scripts/gen-all.sh` and commit generated artifacts. SDK package builds do not run Node codegen.

## Feed / package changes

- `Makefile` — `LUCI_DEPENDS`, version, maintainer
- `menu.d` — path `admin/status/fwlive`
- `rpcd/acl.d` — grant `fwlive.rules`, `fwlive.poll`, `fwlive.resolve`, `fwlive.logging_status` (read); `fwlive.enable_wan_logging`, `fwlive.disable_wan_logging` (write). Do **not** grant `ubus log.read` — poll performs filtered log reads inside the root rpcd plugin

Package README: [`../../openwrt-feed/luci-app-fwlive/README.md`](../../openwrt-feed/luci-app-fwlive/README.md)

## Documentation

| Audience | Update |
|----------|--------|
| End user | [`../user/`](../user/README.md) |
| Developer | [`../developer/`](../developer/README.md) + deep refs in `docs/` |
| Both | Root [`README.md`](../../README.md) |
| Screenshots | `node scripts/capture-fwlive-screenshots.mjs` — see [`../user/assets/capture-screenshots.md`](../user/assets/capture-screenshots.md) |

Keep user docs free of QEMU/SDK detail; keep developer docs free of marketing language.

## Before publishing

[`../github-publish-checklist.md`](../github-publish-checklist.md)

## Backlog (not MVP)

Stages 6–7: DNS hover, digest/SSE — see [ROADMAP.md](../ROADMAP.md).
