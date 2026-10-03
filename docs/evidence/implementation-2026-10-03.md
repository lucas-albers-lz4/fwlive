# October 3 implementation evidence

Tracker: [#1158](https://github.com/lucas-albers-lz4/fwlive/issues/1158).
GPT-6-luna at xhigh implemented all four units in isolated worktrees. Codex
reviewed and integrated their changes, corrected a stale tooltip test assertion,
and ran the combined baseline, package build and installed UI checks. A separate
Luna reviewer inspected the final implementation diffs. This record describes
local implementation and acceptance evidence; PR, bot, human and merge gates
remain pending.

| Unit | Issues | Original implementation commit |
|---|---|---|
| U1: localized Action layout and message instructions | #1147, #1154 | `3b43700b3296a0ffd9f918ccfe4edf7b957c9c2f` |
| U2: remove link and Action select names | #1148, #1150 | `854e5d574a2126d39f55e28f0c88061d578062e6` |
| U3: stable chip nodes and deliberate focus fallback | #1149 | `c6a91852b1` |
| D1: nft mode and optional visibility-hook contracts | #1155, #1156 | `18e34ca3d6` |

#1151, #1152 and #1153 retain the owner's closed `wontfix` dispositions. The
October 3 Denver window was refreshed during execution and still contained
these ten qualifying bug/documentation issues. #1157 is outside implementation
scope. Open issues remain open until fixes are merged.

## Source and artifact identity

Base: `b475de1901c2708ea1087881a2f7213d4717e866`.
The integrated acceptance/build head is
`035d14075271cf7081aec3f8011a499652cac9b1` on `validate/oct03-combined`.
Its package subtree is `023ec8ed6211a40054868c15f71f769f53fa1b9a`.
The subsequent evidence-only commit does not change package inputs.

The cached pinned OpenWrt 24.10.8 x86_64 SDK was package-cleaned, then rebuilt
this candidate. The actual `luci-app-fwlive_0.1.50-r1_all.ipk` SHA-256 is
`9c27ab5ef824b5427e405c8c36e99aa4cbefcdfe01640df06190c378bcd04766`.
No release/version bump was made. The package was force-reinstalled
**artifact-only** into an owned disposable OpenWrt 24.10.8 x86_64 guest,
followed by `sync`. Installed view, table, chips and generated CSS hashes matched
the extracted IPK payload; installed JavaScript is LuCI-minified, so comparison
was against the package rather than raw source. The guest was stopped after
verification (owned PID 2528173).

## Host and browser acceptance

- `scripts/gen-all.sh` left the tracked tree unchanged. Source CSS and generated
  `css.js` are consistent.
- The full `scripts/validate-baseline.sh` passed at the integrated head with
  zero runner-level skips and no per-suite `SKIPPED` results. The matched
  OpenWrt 24.10 jshn library/binary were on the selftest path. Real scanner
  acceptance was required using `FWLIVE_I18N_REQUIRE_SCAN=1` and
  `FWLIVE_I18N_SCAN=/home/lalbers/gitroot/fwlive/openwrt/feeds/luci/build/i18n-scan.pl`.
  The cut's fresh scan matched 229/229 msgids and 248 references. The combined
  POT was regenerated from actual source to resolve its cherry-pick conflict;
  all three PO catalogs were msgmerged. New instructions have German, Russian
  and Simplified Chinese translations adapted from existing Help wording.
- `FWLIVE_HARNESS_PORT=8873 npm run test:view` passed. Its implementation inputs
  match the final package; the later delta only corrects the host tooltip
  expectation. Geometry checks use shipped `css.js` with English, German and
  Russian action labels, 13px/16px fonts, and 390px/1280px viewports. Action
  labels plus native buttons stay inside their cells, Time text remains
  separate, and narrow views retain the existing horizontal scroller.
- The same Chromium suite checks computed Action/remove roles and names,
  keyboard filtering/hash updates, repeated paints, inserted/reordered rows,
  unchanged chip identity, changed values/polarity, removal/Clear all fallbacks,
  outside-input focus, disposal, native table/button semantics and exactly-once
  expansion interactions. Host chip/hash and module suites also passed.

The first full baseline stopped at a stale assertion expecting the old Time
tooltip. Commit `035d140752` updates that expectation; its focused module suite
and the final full baseline passed. Preliminary unit upstream-cut attempts
stopped at the expected dirty-package guard; committed-tree reruns passed.
Failed attempts are not counted as acceptance.

## Installed LuCI acceptance and limits

The retained [installed probe](implementation-2026-10-03/installed-luci.mjs)
ran against `http://127.0.0.1:14080` with SSH port 14022 and the explicit final
IPK path. It preserves real LuCI assets and event handlers while replacing
HTTP `/ubus` poll replies with two deterministic rows. These rows are **not**
guest logd evidence. The probe passed:

- browser-computed Action/remove names and existing Include/Exclude Enter/Space
  activation;
- unchanged focused chip identity across four real Message layout-handler
  paints, changed polarity focus, last-remove/remaining-strip/Clear all
  fallbacks, and outside-input focus retention;
- installed Action button geometry (149.5px Action cell at stock font);
- existing native expansion, hostile message text as text nodes, keyed-rebuild
  focus, and Detail-mode regressions.

The probe was corrected before execution to open More filters before filling
the hidden Source input. Its assumptions and selectors received a separate
Luna review. It uses an English guest session; localized geometry is proved
by the mocked-browser locale/font matrix, not by installed translated
sessions. One known no-password-guest `uci/get` access-denied page error was
allowed; no other page error was accepted. No assistive-technology, physical
hardware, alternate architecture, fresh real-log or release-matrix proof is
claimed. D1 changes comments only; it adds no runtime mitigation or new tests.

Reviewed snapshots:
[Russian narrow/16px](implementation-2026-10-03/mobile-ru-16.png),
[German desktop/13px](implementation-2026-10-03/desktop-de-13.png), and
[installed Simple view](implementation-2026-10-03/installed-simple.png).
Local raw command logs and package artifacts are retained under
`/tmp/fwlive-oct03/evidence` and the combined worktree's `out` directory.

## Review and remaining workflow

Codex inspected native control semantics, safe text sinks, signature inputs,
callback refresh, disposal boundaries, generated assets and screenshots.
The independent GPT-6-luna/xhigh reviewer found no blocking implementation
issue. Its protocol fallback note was accepted as deliberate policy: removal
clears both protocol controls, and focus lands on the reachable protocol picker.
The supplemental tooltip assertion and installed-probe fixes were also reviewed.

Unreleased entries and scoped security-ledger deltas accompany the changed
behavior. This is a review of the touched delta, not a full security audit.
The original dirty workspace was preserved.

The repository's `docs/developer/pr-cycle.md` requires Bugbot and human branch
review before PR filing, then a completed CodeRabbit round and passing checks
at each actual PR head before merge. No callable Bugbot reviewer was available
in this session. At completion of the acceptance run, those gates were pending; no PR had
been filed and no issue was closed or self-attested as owner-reviewed.


## Owner authorization to file PRs

The owner subsequently instructed: “ok push all pr’s and I will do those
reviews”. This authorizes PR filing before the pending human/Bugbot reviews.
It does not attest that those reviews have passed or authorize merging.

The implementation is prepared as four stacked PR branches: `pr/oct03-u1`
against master, `pr/oct03-u2` against U1, `pr/oct03-u3` against U2, and
`pr/oct03-d1` against U3. U1 includes the stale-tooltip assertion correction;
D1 carries this integrated evidence packet. Before this documentation update,
the top stack's entire tree was identical to `c67ec6859a`. The package subtree
remains `023ec8ed6211a40054868c15f71f769f53fa1b9a`, preserving the tested and
installed payload. Per-PR CI, bot/human findings and merge status remain tracked
in #1158. Retarget and recheck each dependent PR before merging it to master.
