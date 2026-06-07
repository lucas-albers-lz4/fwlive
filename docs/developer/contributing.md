# Contributing

## Principles

- **Small steps** — one behavior per change; verify in CLI + QEMU LuCI when UI-related
- **Parser sync** — any change to log parsing or filters must update **both** `core/fwlive-log.js` and `openwrt-feed/.../fwlive/log.js`
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

## Parser sync test

`validate-baseline.sh` includes a structural sync check between `core/fwlive-log.js` and the LuCI mirror. Do not bypass — drift causes “works in tests, broken in browser” failures.

## Feed / package changes

- `Makefile` — `LUCI_DEPENDS`, version, maintainer
- `menu.d` — path `admin/status/fwlive`
- `rpcd/acl.d` — grant `log.read` and `fwlive.rules`

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

Stages 6–7: DNS hover, digest/SSE — see [`../fwlive-development-plan.md`](../fwlive-development-plan.md).
