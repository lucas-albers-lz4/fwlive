# Upstream `luci-app-fwlive` to `openwrt/luci`

Planning checklist for the first PR into [`openwrt/luci`](https://github.com/openwrt/luci) at `applications/luci-app-fwlive/`. This repo stays the development home. The first luci PR is a **copy**, not a move.

Related: [Feed layout decision](architecture.md#feed-layout-decision), [publish checklist § Upstream cut](../github-publish-checklist.md#upstream-cut-into-openwrtluci), [`scripts/upstream-cut.sh`](../../scripts/upstream-cut.sh), issue [#16](https://github.com/lucas-albers-lz4/fwlive/issues/16) (package must-fix — done), tracking issue [#209](https://github.com/lucas-albers-lz4/fwlive/issues/209).

**Do not open the luci PR until the prep checkboxes below are done and a CodeRabbit round on this plan has landed.**

## Settled (do not reopen)

- Target is **`openwrt/luci` `master`**, path `applications/luci-app-fwlive/`. Not `openwrt/packages`. Not a third-party feed repo.
- Release branches (`openwrt-24.10`, …) are for bug/security fixes **after** master merge.
- Keep the monorepo + `src-link` + signed binary feed. Do not split `openwrt-feed/` for upstream.
- License is Apache-2.0 (matches LuCI). No `PKG_LICENSE_FILES` (peer apps omit it). State Apache-2.0 in the luci PR body.
- First luci PR ships **`po/templates/luci-app-fwlive.pot` only**. Drop `po/de`, `po/ru`, `po/zh_Hans` in the cut (`rm -rf` the dirs). Keep those `.po` files in this repo for the binary feed. Weblate after merge.
- Keep `PKG_VERSION` / `PKG_RELEASE` in the cut so they stay locked to `APP_VERSION` in `constants.js`.
- Do not vendor `scripts/gen-all.sh`, `core/fwlive-log.js`, or Node CSS embed into luci. Rewrite GENERATED comments in the cut so they do not tell luci maintainers to run scripts that are not in that tree.
- Do not deprecate the signed binary feed after merge.

## Prep on this repo (before the luci PR)

- [ ] Fix rpcd `list` JSON: drop `"backend":"unknown"` from [`root/usr/libexec/rpcd/fwlive`](../../openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive) (phantom method; `backend` is a field on the `rules` reply).
- [ ] Extend [`scripts/upstream-cut.sh`](../../scripts/upstream-cut.sh):
  - `rm -rf` `po/de` `po/ru` `po/zh_Hans` (empty dirs still make `luci.mk` emit empty i18n packages).
  - File-count check: source minus those locale files minus `fwlive.css` if omitted.
  - Rewrite Makefile `include` to `../../luci.mk` (already done).
  - Rewrite package README (layout table: `proto.js`; `log.js` must not cite `core/`).
  - Rewrite GENERATED / generator comments in `fwlive-is-firewall-event.sh`, `css.js`, `log.js`.
  - Rewrite `constants.js` PKG_VERSION comment (no `openwrt-feed/` path).
  - Optional: drop `htdocs/.../fwlive/fwlive.css` (view loads `css.js`); subtract from file count.
  - Optional: strip `SOURCE_DATE_EPOCH` Makefile block.
- [ ] `./scripts/fwlive-test.sh` and `./scripts/validate-baseline.sh` (optional QEMU 24.10).
- [ ] Confirm LICENSE / ATTRIBUTION (Apache-2.0 + OPNsense BSD 2-Clause for the *idea*, not a port).

## POT regen (after luci-shaped copy, same commit)

There is no in-repo POT extractor. After copying the cut into a luci checkout:

```sh
./build/i18n-scan.pl applications/luci-app-fwlive \
  > applications/luci-app-fwlive/po/templates/luci-app-fwlive.pot
```

The POT must include JS `_()` strings **and** menu title `Firewall Live View` **and** ACL description `Grant access to firewall live log view`. Copy the `.pot` back here, `msgmerge` feed `.po` files, and include the new `.pot` in the **same** luci commit.

## Proposed luci PR-body answers (do not pre-fix)

These stay in **this** planning issue — not separate tickets. Confirm or amend here. Put the agreed text in the luci PR body. Do not change code unless a luci reviewer (or CodeRabbit on this plan) shows a nack.

| Topic | Position |
|-------|----------|
| WAN-log write path | Status-page app; session ACL does **not** grant `uci` or `log.read`; rpcd toggles as root; opt-in; `prerm` restores `/etc/fwlive/wan-log-baseline` on uninstall. |
| Custom rpcd vs `ubus log.read` | Intentional. Sessions must not get `log.read`. |
| Package size / `__selftest` | Parser + shell helpers. CLI-only `__selftest` / `run_logging_selftest` stay in the shipped scripts. |
| `prerm` | Undoes WAN `log=1`. Fail-open (`exit 0`) so uninstall cannot strand. |
| Translations | `.pot` only in the first luci PR. Weblate after merge. |
| `PKG_VERSION` 0.1.36 | Honest snapshot. Keep it in the cut. |
| Out-of-tree heuristic | This is a **new** in-tree app, not `luci-app-https-dns-proxy`. fwlive remains development home; binary feed stays for non-snapshot users. |
| Generated files | Snapshots from this repo. Do not run `./scripts/gen-all.sh` in luci. |

The rpcd `list` phantom `backend` key is **not** a PR-body excuse — fix it in this repo before the cut.

## Open the luci PR (after prep)

1. Fork `openwrt/luci`; **feature branch** (not `master`/`main`).
2. Run `./scripts/upstream-cut.sh`; copy `out/upstream/luci-app-fwlive/` → `applications/luci-app-fwlive/`.
3. Regen POT (section above).
4. Single commit that passes FormalityCheck ([`formalities.json`](https://github.com/openwrt/luci/blob/master/.github/formalities.json)):
   - Subject: `luci-app-fwlive: add firewall live view` (lowercase after colon, no trailing period, hard max 80).
   - Non-empty body, wrap to **100** characters.
   - Git author must equal `Signed-off-by: Lucas Albers <lucas.b.albers@gmail.com>` (same as `PKG_MAINTAINER`; no GitHub noreply).
5. PR **base** = `openwrt/luci` `master`. Optional forum / devel-list note.

## After merge (ongoing)

- Develop here; re-cut **deltas** into luci.
- Deltas must **not** clobber Weblate `po/<lang>/` — sync code + `.pot` only.
- Binary feed + Releases stay for routers not on a LuCI snapshot that includes the app.
- Cherry-pick bug/security fixes to `openwrt-xx.yy` only after master merge.

## Out of scope for the first luci PR

- Feed-only / `src-git` mirror
- Stage 6 rule overlay, digest/SSE
- Relicense / `PKG_LICENSE_FILES`
- Hand translations in the luci tree
- 25.12 validation-matrix as a merge gate
- Dropping `PKG_VERSION` in the luci copy
- SPDX on every JS file
- Vendoring Node generators into luci
- Deprecating the signed binary feed
