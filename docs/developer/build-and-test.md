# Build and test

## SDK builds

```sh
./scripts/docker-sdk.sh list
./scripts/docker-sdk.sh build --target armsr-armv8 --version 24.10
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
./scripts/docker-sdk.sh build-all          # all version × target cells
```

Artifacts: `out/<arch>/<version-label>/fwlive/luci-app-fwlive*.{ipk,apk}`
(e.g. `out/x86_64/24.10.8/fwlive/…`; `--version 24.10` → `24.10.8`;
`snapshot` → `snapshot`). `build-all` writes every version × target cell
under those paths.

Matrix reference: [`../sdk-build-matrix.md`](../sdk-build-matrix.md)  
Native SDK (no Docker): [`../minimal-build-sdk.md`](../minimal-build-sdk.md)

## Parser tests (fast, no QEMU)

```sh
./scripts/fwlive-test.sh
# or: npm test
./scripts/validate-baseline.sh
./scripts/fwlive-linkcheck.sh    # markdown links + heading anchors + external URLs
```

`npm test` is the host suite only. CI also runs `tests/install-host-jshn.test.sh`
before that suite and `npm run test:view` (mocked-LuCI Playwright) as a
separate job. `npm run test:ci` is the documented combined local path; it
still needs the jshn installer prerequisites and Playwright browsers.

Covers parser sync (`core/` vs LuCI `log.js`), schema, filters, CLI pipeline,
shell codegen + LuCI wrapper gate (`./scripts/gen-all.sh`), and shellcheck on shipped
`root/usr/libexec` scripts (`./scripts/fwlive-shellcheck.sh`), and the invariant
rules for shipped JS (`./scripts/fwlive-ast-grep.sh`, ast-grep 0.45.3, rules in
`scripts/ast-grep-rules/`). The supported test host is Linux x86_64. The host
suite requires `busybox` and `ruff`; on Debian or Ubuntu install them with
`sudo apt install busybox` and `pipx install ruff`. Then run `pipx ensurepath`
and start a new shell (or update `PATH`) before running the suite. macOS is
documentation-only; see [`environment.md`](environment.md).

The BusyBox awk classifier lane needs outbound HTTPS plus `curl`, `sha256sum`,
`ar`, `tar`, and `xz` on a cold cache. It fetches the pinned Debian
`busybox-static` 1.37 package from snapshot.debian.org, verifies its SHA-256,
and stores the package and extracted files under `.cache/busybox-awk-1.37/`;
each run rechecks the package and recreates the extracted binary and wrapper.
CI caches that directory by the pinned artifact SHA-256. `FWLIVE_BUSYBOX_AWK_DIR`,
`FWLIVE_BUSYBOX_AWK_URL`, and `FWLIVE_BUSYBOX_AWK_SHA256` override the cache
directory, URL, and checksum. A non-x86_64 local run reports a counted skip
for this lane. On Linux x86_64, a failed fetch is fatal unless the local run
sets `FWLIVE_ALLOW_SKIP=1`; CI rejects that opt-out and requires the lane.
It runs shell-filter parity as `SH='busybox sh'`.

A missing eslint, prettier, stylelint, ruff, or busybox fails the run.
`FWLIVE_ALLOW_SKIP=1` is the loud opt-out: the runner prints the skip and
continues. CI rejects it. Do not use it to treat a skipped check as a pass.

Docs changes must pass the link checker — it checks relative paths **and**
heading anchors against a GitHub-style slugger.

The criteria for deciding what to test and which environment to use are in
[`test-approach.md`](test-approach.md).

## Fresh .pot source scan

`i18n-scan.pl` is provided by the OpenWrt LuCI source tree; it is not a file
tracked in this repository. In the local OpenWrt checkout at the repository
root, its path is `openwrt/feeds/luci/build/i18n-scan.pl`. Point the required
source-parity run at it explicitly:

```sh
FWLIVE_I18N_REQUIRE_SCAN=1 \
FWLIVE_I18N_SCAN="$PWD/openwrt/feeds/luci/build/i18n-scan.pl" \
./scripts/fwlive-test.sh
```

The scanner and its runtime prerequisites come from the matching LuCI/OpenWrt
checkout. In a separate Git worktree without `openwrt/`, use the absolute
scanner path from the local checkout instead of `$PWD/openwrt/…`. The upstream
cut procedure is in
[`upstream-openwrt.md`](upstream-openwrt.md).

## Formal models (TLA+/TLC)

The versioned models, TLC configs, and runner are under `formal/` and
`scripts/formal-tlc.sh`. Run the complete set, including the expected
counterexamples, with:

```sh
./scripts/formal-tlc.sh
```

The runner fetches the official TLA+ v1.7.4 tools jar and verifies its pinned
SHA-256 before execution. It needs Java, `curl`, and `sha256sum`; to use a
pre-fetched jar, set `TLA2TOOLS_JAR=/path/to/tla2tools.jar` (the checksum is
still verified). TLC state files go into a temporary directory and are removed
when the run finishes. The **formal TLC** Actions workflow is manual-only, so
ordinary push and pull-request CI do not install Java or run TLC.

### Renderer tests do not render

`tests/lib/load-fwlive-module.js` stubs LuCI's `E()` as a plain object
constructor (`fakeE`) that never builds DOM. Renderer tests therefore assert on
descriptive objects, which is fine for structure but means **a value reaching an
HTML sink instead of a text node is invisible to them**.

When changing a renderer, make sure that an `E()` reproduces upstream
`dom.append` semantics. Recipe: `.cursor/skills/security-audit/SKILL.md`.

`tests/lib/load-fwlive-view.js` (via `luci-e-harness.js`) now has a minimal
`classList`, `style.setProperty`/`removeProperty`, and `querySelector` so
map/tint branches such as `applyTintFallback` can run in the host suite.
`probeRowTintPaint` still needs a real `getComputedStyle` paint delta, so
that path stays Playwright / Tier-2.

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
./scripts/qemu-playwright-lab-smoke.sh   # C2: chip-invert + proto-ui + reliability, one browser
./scripts/qemu-proto-ui-smoke.sh   # protocol pair + Detail/Message segments (Playwright)
./scripts/qemu-logging-uninstall-smoke.sh   # uninstall restores WAN log baseline (guest required)
```

Checks: ubus, rpcd rules, LuCI HTTP, firewall log pipeline, uninstall baseline restore.

The Playwright lab bundle seeds synthetic pass and drop messages using guest
`logger`, alongside real ping traffic, and waits up to five attempts for both
messages to appear in `logread`. Mixed actions ensure its action-filter
assertion changes visible rows even when keyed rendering reuses unchanged rows.
The synthetic messages exercise parsing and UI filtering; the required
`qemu-smoke-fwlive.sh --require-log-pipeline` check proves real firewall logging.

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

### Real jshn compatibility (#316)

Install `busybox`, `cmake`, a C compiler and `libjson-c-dev`, then run
`./scripts/install-host-jshn.sh --all` before `./scripts/fwlive-test.sh`.
The installer uses matched libubox binaries and shell libraries in
`~/.cache/fwlive-jshn` (`FWLIVE_JSHN_PREFIX` overrides this directory).
No system library is replaced. All three pinned release pairs (23.05, 24.10,
25.12 in `scripts/jshn-pins.txt`) are mandatory in the compatibility gate,
even when their shell libraries have identical contents.
`bash tests/install-host-jshn.test.sh` checks repeat installs and pin mismatch
handling. Ordinary dash tests remain separate from these BusyBox ash tests.
`./scripts/fwlive-test.sh` runs `tests/fwlive-logging.test.sh` as its own
labelled step. `tests/fwlive-rpcd-security.test.js` still execs that file
when run standalone; the runner sets `FWLIVE_LOGGING_VIA_RUNNER=1` so the
suite is not executed twice. The rpcd selftest uses the matched BusyBox/jshn
pair (24.10 by default; select another supported pair with
`FWLIVE_JSHN_RELEASE`). A missing pair is a test failure, not a successful skip.
