# Upstream to `openwrt/luci`

Owner for cutting `luci-app-fwlive` into the official LuCI tree and filing the
upstream PR. Publish checklist pointer:
[`../github-publish-checklist.md`](../github-publish-checklist.md).
Agent review order before filing: [pr-cycle.md](pr-cycle.md).

This monorepo is the development home.
The luci PR is a **copy**, not a move.
The signed binary feed and `src-link` stay for users who do not use snapshots.

## Maintenance model

This section answers questions from LuCI maintainers.
The package README has a link to this section.

### Which tree wins

| Tree | Role |
|------|------|
| **[lucas-albers-lz4/fwlive](https://github.com/lucas-albers-lz4/fwlive)** | Primary source. Develop, test, release, and cut from this tree. |
| **`openwrt/luci` `applications/luci-app-fwlive/`** | Snapshot for OpenWrt snapshot images and the luci feed. |
| **Signed binary feed** | Second install path for users who do not use snapshots. Not a second source of truth. |

If the two trees disagree, **this monorepo wins**.
The next run of `./scripts/upstream-cut.sh` replaces the luci copy (code and `.pot`).
Do not use the luci tree as a second place to develop the app.

### Generated / snapshot files

Some shipped files are **snapshots**. They are not hand-edited LuCI sources.
After the cut, their headers say this (for example `fwlive-is-firewall-event.sh` and `css.js`).
Keep `APP_VERSION` in `constants.js` equal to `PKG_VERSION`.
To change the classifier, edit `CLASSIFY_SPEC` in this monorepo, run `./scripts/gen-all.sh`, then cut again.
If you edit those files only in luci, the next snapshot will overwrite your change.

### Keeping luci current

When we ship a fix or a release, we cut the change into `openwrt/luci` again.
Use the same FormalityCheck path as the first PR.
After Weblate owns `po/<lang>/`, a re-cut must **not** replace those locale files.
Re-cut only code and `.pot` ([After merge](#after-merge-upstream)).

We keep two trees on purpose, with one winner.
We do not use two equal homes (see `luci-app-https-dns-proxy` as a bad example).
Send fixes to fwlive. Do not leave long-lived patches only in luci.

### Why not `PKG_SOURCE`

We looked at a `PKG_SOURCE` / tarball package. We **do not** use that design:

- LuCI apps usually live **in the tree** under `applications/`
- After merge, **Weblate** owns `po/<lang>/` in luci. A GitHub download still needs version bumps and still has two places to update
- Snapshot and image builders expect a plain tree. They must not fetch from the network when they build the package

An in-tree snapshot with a clear “fwlive wins” rule fits LuCI practice better than an out-of-tree tarball.

## Where it lands

| Place | Role | First PR? |
|-------|------|-----------|
| [`openwrt/luci`](https://github.com/openwrt/luci) `applications/luci-app-fwlive/` on **master** | Official LuCI apps; snapshot images pull this as the luci feed | **Yes** |
| `openwrt/luci` `openwrt-24.10` (etc.) | Stable luci branch | Later cherry-pick after master |
| [`openwrt/packages`](https://github.com/openwrt/packages) | Community packages feed | No |
| [`openwrt/openwrt`](https://github.com/openwrt/openwrt) `package/` | Core firmware; consumes the luci feed | No |
| This repo’s signed feed | Out-of-tree install | Parallel track; not a substitute |

“Filing to master” means **`openwrt/luci` `master`**. That still arrives as a
**feed** from OpenWrt’s point of view.

## Prep in this repo

1. Keep rpcd `list` keys = methods only (values = args objects). Do not
   advertise reply fields (e.g. `backend` belongs on `rules`, not `list`).
2. Run [`../../scripts/upstream-cut.sh`](../../scripts/upstream-cut.sh)
   (output: `out/upstream/luci-app-fwlive/`). The script:
   - `git subtree split` of `openwrt-feed/luci-app-fwlive/`
   - Rewrites `include ../../luci.mk`, drops feed-wiring Makefile header
   - Drops `po/{de,ru,zh_Hans}` (first luci PR is `.pot` only; keep those
     `.po` files here for the binary feed)
   - Drops `fwlive.css` (view loads `css.js`)
   - Rewrites README / GENERATED / `constants.js` so they do not cite
     monorepo-only paths (`core/`, `openwrt-feed/`, `./scripts/gen-all.sh`)
   - Keeps `PKG_VERSION` / `PKG_RELEASE` (lockstep with `APP_VERSION`)
   - Verifies file counts and absence of monorepo-only comment paths
3. Run `./scripts/fwlive-test.sh`.
4. Run `./scripts/validate-baseline.sh`.
5. If you need guest proof, run the QEMU 24.10 lab
   ([qemu-lab.md](qemu-lab.md)).

## Luci-shaped copy + POT

Paths below assume the fwlive monorepo and an `openwrt/luci` checkout as
siblings (adjust if yours differ):

```sh
FWLIVE=/path/to/fwlive
LUCI=/path/to/luci

"$FWLIVE/scripts/upstream-cut.sh"
rm -rf "$LUCI/applications/luci-app-fwlive"
mkdir -p "$LUCI/applications/luci-app-fwlive"
cp -a "$FWLIVE/out/upstream/luci-app-fwlive/." \
  "$LUCI/applications/luci-app-fwlive/"

cd "$LUCI"
./build/i18n-scan.pl applications/luci-app-fwlive \
  > applications/luci-app-fwlive/po/templates/luci-app-fwlive.pot
```

The POT must include JS `_()` strings **and** the menu title
`Firewall Live View` **and** the ACL description
`Grant access to firewall live log view`.

Copy the `.pot` back into this monorepo.
Then `msgmerge` the feed `.po` files.
The header shape
`msgstr "Content-Type: text/plain; charset=UTF-8"` (no embedded `\n`) is what
luci’s scanner emits for every app — do not “fix” it to a multi-line header;
the next scan will wipe that.

Same commit in luci: package tree + refreshed `.pot`.

## FormalityCheck (luci commit)

Feature branch (not `master`). Subject example:
`luci-app-fwlive: add firewall live view`.

[`formalities.json`](https://github.com/openwrt/luci/blob/master/.github/formalities.json):

- Non-empty body, wrap to 100 characters (not trailers-only)
- Author == `Signed-off-by: Lucas Albers <lucas.b.albers@gmail.com>`
  (no GitHub noreply)
- Verify that the commit author’s email is linked to a verified GitHub account
  (`require_linked_github_account`)
- GPG/SSH signing is **not** required; `check_signature` only validates a
  signature if present

## Filing sequence (prep → luci)

1. **fwlive prep branch** — full [pr-cycle.md](pr-cycle.md) gate (luna → Bugbot →
   human → file vs master → CodeRabbit → triage → merge).
2. **Re-cut** with `./scripts/upstream-cut.sh` from merged master (or from the
   final prep tip if filing luci before the prep merge).
3. **Copy + i18n-scan** into the luci feature branch (commands above).
4. **FormalityCheck commit** on that luci branch.
5. **Same pr-cycle gate on the luci branch** (luna → Bugbot → human). Skip
   CodeRabbit unless `openwrt/luci` (or your fork) is configured for it.
6. File against `openwrt/luci` `master` with product/FormalityCheck prose only —
   no bot quotes.

CodeRabbit comments stay on the **fwlive** PR. Apply code into the cut; do not
paste review threads upstream.

## PR-body answers (do not pre-fix)

| Topic | Position |
|-------|----------|
| WAN-log write | Session ACL has no `uci` / `log.read`; rpcd toggles as root; opt-in; `prerm` restores baseline |
| Custom rpcd | Intentional; sessions must not get `log.read` |
| Size / `__selftest` | Leave CLI-only selftests in shipped scripts |
| `prerm` | Undo WAN `log=1`; fail-open |
| Translations | `.pot` only first PR; Weblate after merge |
| `PKG_VERSION` | Keep in the cut (lockstep with `APP_VERSION`) |
| License | State Apache-2.0 in the PR body. `PKG_LICENSE` is already set; do not add `PKG_LICENSE_FILES` (peer LuCI apps) |
| Out-of-tree | New in-tree app, not an LLM redirect heuristic; feed stays |
| Generated files | Snapshots from this repo. See [Maintenance model](#maintenance-model). |
| Dual tree / `PKG_SOURCE` | fwlive wins. Keep the in-tree snapshot. Do not use `PKG_SOURCE`. See [Maintenance model](#maintenance-model). |

## After merge (upstream)

- Re-cut **deltas** (code + `.pot` only). Never clobber Weblate `po/<lang>/`.
- Binary feed stays for non-snapshot users.
- Cherry-pick to `openwrt-xx.yy` only after luci master.

## Out of scope (first luci PR)

Feed split, Stage 6 overlay, relicense, hand `.po` in luci, 25.12 as a merge
gate, SPDX on every JS file, vendoring Node into luci, killing the feed.
