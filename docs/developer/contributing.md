# Contributing

## Principles

- **Small steps** — one behavior per change; verify in CLI + QEMU LuCI when UI-related
- **Parser sync** — edit `CLASSIFY_SPEC` in `core/fwlive-log.js`, mirror the same object in `htdocs/.../fwlive/log.js`, run `./scripts/gen-all.sh` (regenerates shell; gates LuCI full-spec drift), keep preserve-region presentation in parity
- **Output encoding** — untrusted values must reach the DOM as text nodes, never through an HTML sink; applies to every renderer, including values that look constrained — see [Security model § Invariants](security-model.md#invariants)
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

`fwlive-test.sh` includes classify goldens, shell↔JS parity, and freshness checks:

| Script | Role |
|--------|------|
| `gen-shell-classifier.js` | **Codegen** — emits `fwlive-is-firewall-event.sh` from `CLASSIFY_SPEC` |
| `gen-luci-wrapper.js` | **Gate** — deep-equals full LuCI `CLASSIFY_SPEC` to core, checks preserve markers / 21.02 APIs; re-emits committed `log.js` bytes (does not transform shared logic) |

After editing classification: update **both** `core/fwlive-log.js` and the LuCI `CLASSIFY_SPEC` mirror, run `./scripts/gen-all.sh`, and commit the regenerated shell classifier. A drifted LuCI wrapper fails the gate — it is not auto-fixed by `gen-all.sh`. SDK package builds do not run Node.

## Feed / package changes

- `Makefile` — `LUCI_DEPENDS`, version, maintainer. `PKG_VERSION` and `APP_VERSION` in `fwlive/constants.js` must match
- `menu.d` — path `admin/status/fwlive`
- `rpcd/acl.d` — grant `fwlive.rules`, `fwlive.poll`, `fwlive.resolve`, `fwlive.logging_status` (read); `fwlive.enable_wan_logging`, `fwlive.disable_wan_logging` (write). Do **not** grant `ubus log.read` — poll performs filtered log reads inside the root rpcd plugin

## Security-relevant changes

Renderers, the rpcd plugin, shell helpers, and the release pipeline all sit on a
trust boundary. Read [Security model](security-model.md) before changing them,
and report vulnerabilities privately per [`../../SECURITY.md`](../../SECURITY.md)
rather than opening an issue.

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
