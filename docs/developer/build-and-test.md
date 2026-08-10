# Build and test

## SDK builds

```sh
./scripts/docker-sdk.sh list
./scripts/docker-sdk.sh build --target armsr-armv8 --version 24.10
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
./scripts/docker-sdk.sh build-all          # all version × target cells
```

Artifacts: `out/<arch>/<version>/fwlive/luci-app-fwlive*.{ipk,apk}`

Matrix reference: [`../sdk-build-matrix.md`](../sdk-build-matrix.md)  
Native SDK (no Docker): [`../minimal-build-sdk.md`](../minimal-build-sdk.md)

## Parser tests (fast, no QEMU)

```sh
./scripts/fwlive-test.sh
# or: npm test
./scripts/validate-baseline.sh
./scripts/fwlive-linkcheck.sh    # markdown links + heading anchors + external URLs
```

Covers parser sync (`core/` vs LuCI `log.js`), schema, filters, CLI pipeline,
shell codegen + LuCI wrapper gate (`./scripts/gen-all.sh`), and shellcheck on shipped
`root/usr/libexec` scripts (`./scripts/fwlive-shellcheck.sh`). Optional: `SH='busybox sh' node tests/fwlive-shell-filter.test.js`.

Docs changes must pass the link checker — it validates relative paths **and**
heading anchors against a GitHub-style slugger.

### Renderer tests do not render

`tests/lib/load-fwlive-module.js` stubs LuCI's `E()` as a plain object
constructor (`fakeE`) that never builds DOM. Renderer tests therefore assert on
descriptive objects, which is fine for structure but means **a value reaching an
HTML sink instead of a text node is invisible to them**.

When changing a renderer, verify through an `E()` that reproduces upstream
`dom.append` semantics. Recipe: `.cursor/skills/security-audit/SKILL.md`.

## Live View CSS (`fwlive.css` → `css.js`)

Author styles in plain CSS, then embed into the LuCI module LuCI injects at runtime:

```sh
# edit: openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/fwlive.css
node scripts/embed-fwlive-css.js
```

That regenerates `…/fwlive/css.js` (`styleText` string). Do not edit `css.js` by hand;
`tests/fwlive-theme-css.test.js` fails if the committed file is stale.

## QEMU smoke (guest running)

```sh
./scripts/qemu-wait-guest.sh
./scripts/qemu-install-fwlive.sh
./scripts/qemu-smoke-fwlive.sh
```

Checks: ubus, rpcd rules, LuCI HTTP, firewall log pipeline.

## Version validation (full cell)

One version + architecture:

```sh
./scripts/validate-openwrt.sh --version 24.10
./scripts/validate-openwrt.sh --version 23.05 --qemu-target x86 --skip-build
```

All smokeable x86 versions:

```sh
./scripts/validate-openwrt-all.sh smoke-x86 --skip-build
```

Details: [`../validation-matrix.md`](../validation-matrix.md)

## Acceptance criteria

Functional, performance, and sign-off tables: [`../fwlive-acceptance.md`](../fwlive-acceptance.md).

## CI-friendly sequence

```sh
./scripts/validate-baseline.sh
./scripts/validate-openwrt-all.sh build
./scripts/validate-openwrt-all.sh smoke-x86 --skip-build
```

`smoke-x86` skips **snapshot** (minimal image, no LuCI).
