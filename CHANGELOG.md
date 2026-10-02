# Changelog

All notable changes to **fwlive** / **luci-app-fwlive** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed
- Unlink rules-map dump/TSV files before blocking helpers, preventing pathname residue after plugin-only SIGKILL during that work; surviving helpers can still retain anonymous tmpfs storage (#1133).
- Prepare nft rule prefixes, aliases and JSON string content in one bounded awk stage, removing per-prefix utility forks while retaining precedence, first-wins and reply caps (#1128).
- Preserve representable C0 control bytes and DEL in generated poll summaries using JSON escapes, matching the shell escaper (#1124).
- Preserve adaptive hot/shed state when either poll duration clock sample is unavailable, and accept case-insensitive adaptive-off overrides (#1125, #1127).
- Give filter-chip invert buttons translated Include/Exclude accessible names while retaining the existing tooltip and filter controls (#1129).
- Keep upstream-cut translation paths and references aligned with the exported LuCI tree, remove dangling source-only references, and use checked temporary storage for the CLI selftest (#1120; PR #1122).

### Changed
- Check formal rollback decision completion and conditional idealized restore effectiveness, retaining an unfair counterexample and rejecting ambiguous temporal-property attribution (PR #1123).

## [v0.1.50] — 2026-10-02

### Fixed
- Reject non-regular WAN logging lock files before opening them, while preserving first-use creation and the existing lock inode (#1066; PR #1106).
- Validate the static classifier once before processing logs, restore short-circuit evaluation, and reject invalid KV names before generating awk (#1060, #1067; PR #1107).
- Join the initial poll before startup metadata settles, avoiding a second startup read while preserving later refresh and resume requests (#1073; PR #1109).
- Match Source/Destination IP substrings case-insensitively, including uppercase IPv6 hex, while preserving exclusion filters (#1071; PR #1116).
- Canonicalize repeated leading separators before feed staging deletion guards compare protected paths (#1090; PR #1111).
- Prepare lab images at private mountpoints and clean up only acquired mounts with verified sources and owned loop devices (#1095; PR #1112).
- Route corrupt QEMU pidfiles through the explicit force-stop backstop and explain invalid pidfile removal on start (#1084, #1089; PR #1113).
- Preserve installed helpers through artifact reinstall, then verify package status, payload and RPC registration before reporting success (#1097; PR #1114).
- Match native ubus timeout arguments in the budget fixture, reject accidental real-log fallback, and require the pinned 2000-line poll input (#1062; PR #1115).
- Accept util-linux flock denied-open status 66 in the security-gap smoke only after verifying the provider, retaining setup, success and timeout failures (#1098; PR #1119).
- Check Java before TLC downloads and bound each curl transfer (#1087; PR #1108).

### Changed
- Remove the weekly scheduled 25.12 APK feed smoke while keeping release-tag and manual feed validation; strengthen exact resolver-argument and host feed-index failure coverage (PR #1059).
- Publish dated security/code-quality audit reports and refresh the security ledger with scoped proof and accepted residuals (PRs #1100, #1101, #1102).
- Bound identified host-test subprocesses, improve direct-filter and label/count regression oracles, test adaptive lock-create failures under root and non-root users, and check timeout absence across packaging inputs (#1061, #1065, #1075, #1077, #1079, #1081, #1083; PRs #1105, #1110, #1109, #1114).
- Clarify current helper lifetime, nft backend discovery, retained-row age and stylesheet-source guidance; correct the v0.1.48 changelog and require notable per-PR entries (#1082, #1091, #1092, #1093, #1103, #1063; PRs #1117, #1118).

Supported OpenWrt: **23.05**, **24.10** (opkg) · **25.12** (apk)

Feed install: [binary-feed.md](docs/binary-feed.md) · Menu: **Status → Firewall Live View**

Requires firewall rules with **`log`** — [enabling firewall logs](docs/user/enabling-firewall-logs.md)

Manual install: [installation.md](docs/user/installation.md)

## [v0.1.49] — 2026-10-01

### Fixed
- Refresh Summary data on successful polls, back off resolver errors, clear expired load-shed status, and avoid duplicate polling during load, visibility, and cadence changes (#1057)

Supported OpenWrt: **23.05**, **24.10** (opkg) · **25.12** (apk)

Feed install: [binary-feed.md](docs/binary-feed.md) · Menu: **Status → Firewall Live View**

Requires firewall rules with **`log`** — [enabling firewall logs](docs/user/enabling-firewall-logs.md)

Manual install: [installation.md](docs/user/installation.md)

## [v0.1.48] — 2026-09-30

### Fixed
- Report rules-map truncation independently of lookup failures, with concise rule-name warnings and expandable diagnostics that preserve retained-map state (#1038; PR #1039)
- Bound the Live View rules-map retry budget and skip retries while paused or after a failed poll (#993)
- Size hostname caches for the maximum visible row set and clear the visible refresh paint latch (#982, #995)
- Drop empty negated filters from shared URL hashes (#1019)
- Show the correct opkg and apk install commands for missing kernel log modules (#1017)
- Bound WAN logging lock waits to five one-second intervals, report persistent contention, and skip rollback if a later fwlive toggle intervenes (#1030)
- Refresh buffered rule labels once after a successful rules-map recovery (#1031)
- Keep received rows through empty successful polls and show their age; clarify the stale-row hint (#1033, #1041)

### Changed
- Remove the `coreutils-timeout` runtime dependency and invoke read helpers directly; the log.read invocation uses ubus's native five-second reply timeout after object lookup, while the resolver budget only stops new lookups (#980)
- Live View names each load condition the same way in the status line and banner, tells transport, router-read, and installation poll errors apart, labels both enable buttons **Enable logging**, and explains Summary mode in Help (#1042)
- Live View no longer rewrites the URL hash on every poll-driven repaint; frontend helpers for scoped-IPv6 hostname lookup, substring filter fields, and retry/cooldown constants are shared instead of duplicated (#1043)
- Share WAN logging toggle error replies and the enable/disable preamble (#1044)
- Reuse filtered-row results across status and render consumers when the buffer, filters, and display cap are unchanged (#1032)
- Reject malformed or sparse `CLASSIFY_SPEC` structures in code generation and JS classification; the runtime guard validates on each classification call (#1026)
- Explain already-on WAN-log baseline snapshots and uninstall restore skip conditions in the install guide (#1015, #1016; PR #1027)
- Simplify adaptive limit and reply assembly, skip state writes on an unusable lock path, and reject non-regular poll locks that could block on a FIFO (#1046, #1051)
- Share rpcd jshn loading and JSON append so resolve reports a missing library on its own and bounds each hostname at 253 octets (#1045)

Supported OpenWrt: **23.05**, **24.10** (opkg) · **25.12** (apk)

Feed install: [binary-feed.md](docs/binary-feed.md) · Menu: **Status → Firewall Live View**

Requires firewall rules with **`log`** — [enabling firewall logs](docs/user/enabling-firewall-logs.md)

Manual install: [installation.md](docs/user/installation.md)

## [v0.1.47] — 2026-09-28

### Fixed
- Bound rpcd rules-map traversal and peer-drain work, and reject malformed classifier specifications and rules (#969, #977, #978)
- Harden feed point-release pin coverage, SDK build-all argument handling, and QEMU guest readiness deadlines (#968, #970, #976)
- Strengthen view regression contracts and refresh BusyBox classifier/rpcd coverage (#941, #979)
- Clarify Summary-mode recovery, QEMU release guidance, and required lab tooling (#959, #926, #975)
- Name the published `kmod-nf-log` / `kmod-nf-log6` packages in the empty-state install command (#929)
- Color logging failure notices with `--fwlive-deny-color` instead of success green (#938)
- Skip a bare `!` filter chip so an empty negate does not look like a filter (#939)
- Check same-file markdown anchors in linkcheck, and document the fail-closed test opt-out (#942, #908)
- Run the classifier and rpcd selftest under BusyBox awk 1.37, and regenerate the 2000-line log fixture to 1250/750 (#880, #941)
- Keep a verified upstream-cut branch when --replace cannot move a checked-out canonical ref, and reject a second outdir (#890, #922)
- Require a Linux host for the x86 QEMU runner, tell port conflicts to use --stop --force, and accept only an IPv4 hostfwd bind (#918, #919, #920)
- Refuse publish-packages clears outside feed-staging* and out/, and reject unknown ipkg index labels and extra positionals (#917, #921, #922)
- Name the uninstall cases that skip WAN log restore, including a post-reload baseline mismatch, and say a Simple-view Time click expands the row (#936, #927)
- Size the hostname cache to the 2000-row limit so a stable table stops re-resolving (#933)
- Keep a successful poll's status when timeout recovery throws (#904)
- List `coreutils-timeout` next to the other runtime packages in install docs (#931)
- Describe the off-state watch strip as the Enable logging button (#940)
- Drop leftover checkout credentials from dependency-review and pin every workflow (#916)
- Accept QEMU runner `--stop`/`--force` in either order and reject extra args (#924)
- Clear a live non-QEMU pidfile on `--stop`, and verify `--force` until the guest is gone (#888)
- Label src/dst/q include chips as contains so they match substring filters (#928)
- Keep a hostname paint pending across a hidden-tab epoch bump so return still forces the frame (#934)
- Retry a thrown rules RPC without wiping a good map, and refresh buffered labels on a successful load (#905)
- Map UCI set/delete/commit failures and post-commit races to distinct logging notices (#937)
- Keep `/etc/fwlive` across sysupgrade and snapshot the WAN log baseline on already-on enable (#935)
- Encode nft dump TSV with an index/substr walk so BusyBox awk 1.37 keeps tab and backslash prefixes (#879)
- Treat jsonfilter empty-array extract as a healthy empty poll (#932)
- Raise the adaptive summary byte cap from 256 to the documented 1 KiB (#930)
- Document MODE=json as a comma-joined record fragment and pin a two-entry assertion (#780)
- Document the `npm test` vs CI delta and add `npm run test:ci` (#796)
- Pin `logread-2000.json` row and classify counts (#795)
- Fail `fwlive-logging.test.sh` on skips when `CI=true` or `FWLIVE_TEST_REQUIRE_ZERO_SKIPS=1` (#794)
- Await poll-call counts with `waitFor` instead of a fixed sleep (#792)
- Queue default harness `requestAnimationFrame` and flush it in tests (#790)
- Pin timestamp-strip and `fw4:` rule-hint vectors in the shell summary parity gate (#781)
- Give the view harness `classList`, `style`, and `querySelector` so tint-fallback runs (#770)
- Pin parser-sync filter outcomes for all 20 samples (#765)
- Run `fwlive-logging.test.sh` as its own labelled host-suite step (#764)
- Document skipped release numbers, owner test-policy links, and pin-site checklists (#845, #844, #843, #823, #820, #819, #818)
- Fail closed on missing lint tools, ruff, and busybox instead of implicit `npm ci` or a silent macOS skip (`FWLIVE_ALLOW_SKIP=1` is the loud opt-out) (#802)
- Pin shell-filter metachar classify results and the filtered JSON shape (#801)
- Render chips smoke through the real `E` harness (#800)
- Use unique symlink temp dirs and attribute `/tmp/fwlive-*` leak scans to this test's nft prefix (#799)
- Log whether shell-filter and corpus gates use host `jsonfilter` or the node stub (#798)
- Capture `uci show firewall` once per `rules` call (#774)
- Stop `map_prefix_with_label` after 512 lines so first-wins duplicates cannot walk an unbounded dump (#767)
- Refuse a symlinked or group/other-writable WAN-log baseline directory before `printf >` (#777)
- Refuse a group/other-writable adaptive state directory before the PID-predictable tmp+mv write (#776)
- Keep uninstall stdout free of rpcd JSON when baseline restore fails (#779)
- Dedup `map_add` keys before `json_escape` so repeated prefixes skip a fork (#825)
- Skip already-validated resolve repeats before they consume a lookup slot (#772, #828)
- Remove rules-map dump temps on normal exit and catchable EXIT/HUP/INT/TERM paths (#775); SIGKILL cannot run traps. The later #1133 mitigation removes pathnames before blocking work, while preserving the accepted helper/storage lifetime limit.
- Key row reuse on resolved hostnames so expand and resolve paints rebuild only changed rows (#784)
- Refresh the status line on scroll only when `followLive` flips (#782)
- Reset `lastBatchNewIdCount` on a failed poll so the next paint is not costed from the previous batch (#789)
- Accept IPv6 zone suffixes in `isLikelyIp` and resolve the bare address (#788)
- Keep a `forceNextRender` reservation when the queued frame is dropped for an epoch mismatch (#787)
- Keep existing live-mode rows when a poll batch normalizes to zero rows (#785)
- Declare `coreutils-timeout` as a runtime dependency so stock OpenWrt installs retain bounded rpcd operations; report an incomplete installation when the provider is unexpectedly absent (#761)
- Keep poll JSON valid when a killed classifier leaves a truncated filter body (#768)
- Keep unlabeled log-prefix hints whose names look like `echo` flags (`-n`, `-E`) (#771)
- Bound `fwlive.resolve` with `/proc/uptime` so a backward NTP step cannot stretch the lookup loop (#827)
- Restore unlisted `#action=` hash values by injecting the missing SELECT option (#831)
- Keep `constructor:` / `__proto__` log prefixes from painting Object builtins into the Rule cell (#783)
- Refuse `publish-packages.sh` staging clears of `/`, `$HOME`, the repo root, or paths outside the tree (#766)
- Reject off-pin SDK `--version` values instead of silently flooring them to the pinned patch (#804)
- Keep feed publish layout on the major.minor line so a point-release bump still writes `/24.10/` (#806)
- Fail classifier codegen on an unrecognised `CLASSIFY_SPEC` predicate instead of emitting a dead `if (0)` branch (#826)
- Restore only documented filter keys from the URL hash; `#fetch-mode` / `#row-tint` stay persisted (#830)
- Keep the status line and adaptive banner aligned when `adaptive: 0` still reports truncated or load-shed (#829)
- Refuse a bare `qemu-wait-guest.sh --cmd` and poll SSH in BatchMode so a password prompt cannot hang past `MAX_WAIT` (#839)
- Stop the QEMU guest if `validate-feed-smoke.sh` fails after start (#838)
- Pin Node 22 on `publish-packages` `build-publish` so the release lint gate matches `fwlive-test` (#842)
- Do not persist `GITHUB_TOKEN` on the remaining `fwlive-test.yml` checkouts (#817)
- Abort Packages index filtering on write/I/O errors instead of signing a partial file (#821)
- Refuse to stage a feed when either public key is missing (#803)
- Keep every `poll.add` callback in the Node view harness, matching the browser fixture (#837)
- Exercise extracted LuCI modules under `'use strict'` in the Node and browser harnesses (#836)
- Pin `id` / `log_id` in the parser corpus, including the id-less composite fallback (#835)
- Assert fetch-budget helpers by method body, not unbounded token-presence regexes (#834)
- Drive leading-zero WAN `log` values through the UCI stub so the status JSON path is actually exercised (#832)
- Name every 8080/2222 owner in QEMU host-port conflict errors (#816)
- Validate QEMU hostfwd ports and fail closed when `ss` cannot probe them (#809)
- Reject non-numeric or out-of-range `MAX_WAIT` / `INTERVAL` / SSH port in `qemu-wait-guest.sh` (#810)
- Pass feed URLs into the guest as `env` assignments instead of interpolating them into the remote shell (#815)
- Capture the QEMU child PID and fail fast if it dies or the SSH port is not listening before the long wait (#805)
- Stop QEMU from a pidfile; pattern `pkill` only with `--force` (#808)
- Probe mkhash in a subshell so `feed_publish_stage_opkg_host` cannot leave `SDK_MATRIX_*` on the last cell (#814)
- Honor `docker-sdk.sh build-all --target/--version` even when the value matches the default (#813)
- Save and restore caller RETURN/EXIT traps in feed-publish, feed-keys, and validate-matrix (#812)
- Bound `wait-feed-pages.sh` curls and report every pending URL each round (#811)
- Find `luci-app-fwlive_*.apk` in the reproducibility gate, matching copy-out and feed staging (#807)
- Rewrite the guest fwlive feed source instead of appending a second URL, and refuse unsafe feed URLs before they reach ssh (#840)
- Refuse an upstream cut on a dirty package tree, split onto a temporary branch unless `--replace`, and skip non-UTF-8 assets instead of crashing (#841)
- Expand a log row from the Time cell, not Action — Action is a filter link (#822)
- Enter Summary mode on the first slow poll; three fast samples still leave it (#786)

### Changed
- Record that a version-changing 25.12 APK upgrade keeps the WAN zone `log` bit (`post-upgrade` only) (#848)

Supported OpenWrt: **23.05**, **24.10** (opkg) · **25.12** (apk)

Feed install: [binary-feed.md](docs/binary-feed.md) · Menu: **Status → Firewall Live View**

Requires firewall rules with **`log`** — [enabling firewall logs](docs/user/enabling-firewall-logs.md)

Manual install: [installation.md](docs/user/installation.md)

## [v0.1.46] — 2026-09-26

### Changed
- Linux x86_64 is the only supported development host; macOS is editing-only (#736)
- Filter URL hashes use `history.replaceState` so a shared view does not stack Back entries (#708)
- Shareable-hash docs include Manual-mode `poll=manual` and `maxraw=` (#759)

### Fixed
- Keep nft log prefixes that contain a tab as one rules-map key (#757)
- Live View: treat initial `logging_status` rejection as unknown; map WAN-toggle errors and persist notices; keep Disable when logging is on with a blocker; keep Pause during hostname resolve; show the full expand-panel message; repaint summary Show-rows (#756, #706, #654, #656, #660, #661, #694, #679, #682)
- Parser: share CLASSIFY_SPEC trim including NBSP; keep ECE/CWR in the TCP flag tail; treat non-string log messages as noise; share rule-hint extraction with `top_rules` (#718, #697, #692, #723)
- rpcd/logging: read UCI zone sections without globbing; enforce `is_uci_style_name` on the whole string; fail closed when the adaptive lock cannot be opened; require `messages_received` for healthy samples; keep a structured rules reply on TSV failure; preserve WAN log baseline through reload and fail restore when staging never applied (#746, #739, #712, #655)

### Added
- Translate filter-chip field labels (#704)

Supported OpenWrt: **23.05**, **24.10** (opkg) · **25.12** (apk)

Feed install: [binary-feed.md](docs/binary-feed.md) · Menu: **Status → Firewall Live View**

Requires firewall rules with **`log`** — [enabling firewall logs](docs/user/enabling-firewall-logs.md)

Manual install: [installation.md](docs/user/installation.md)

## [v0.1.45] — 2026-09-20

### Security
- Pin the OpenWrt 23.05 `base` feed to peeled `v23.05.5` and require 40-hex `src-git` pins; refuse host-sign when materialized feed HEADs do not match (#411, #412)

### Changed
- Document the current support floor as OpenWrt **23.05+**; **21.02** and **22.03** remain historical lab notes only. The v0.1.44 footer below records that release's former matrix.
- Package `LUCI_DESCRIPTION` and remaining user-facing docs now match the ACL-only menu and firewall4/nft rules-map contract; iptables-tagged log lines still classify.

Supported OpenWrt: **23.05**, **24.10** (opkg) · **25.12** (apk)

Feed install: [binary-feed.md](docs/binary-feed.md) · Menu: **Status → Firewall Live View**

Requires firewall rules with **`log`** — [enabling firewall logs](docs/user/enabling-firewall-logs.md)

Manual install: [installation.md](docs/user/installation.md)

## [v0.1.44] — 2026-09-17

### Changed
- Luci-cut generated headers are labels only (no out-of-tree repo, no do-not-edit); wrap the sticky-dir lock comment
- Luci FormalityCheck / PR body: “This commit ships po/templates only” (not “First commit”)
- Reflow comments left ragged after tracker-id parentheticals were dropped
- Record the OpenWrt 25.12 process and memory load profile, including x86_64 and armsr results (#363, #364)

Supported at the v0.1.44 release: **21.02**, **22.03**, **23.05**, **24.10** (opkg) · **25.12** (apk)

Feed install: [binary-feed.md](docs/binary-feed.md) · Menu: **Status → Firewall Live View**

Requires firewall rules with **`log`** — [enabling firewall logs](docs/user/enabling-firewall-logs.md)

Manual install: [installation.md](docs/user/installation.md)

## [v0.1.43] — 2026-09-17

### Changed
- Isolate render scheduling ownership in a dedicated module while preserving epoch-safe frame coalescing, token-bucket throttling, forced paints, and disposal (#359, refs #340)

### Added
- Regression coverage for stale frames, force reservations, scheduler lifecycle, and browser animation-frame adapter binding (#359)

Supported OpenWrt: **21.02**, **22.03**, **23.05**, **24.10** (opkg) · **25.12** (apk)

Feed install: [binary-feed.md](docs/binary-feed.md) · Menu: **Status → Firewall Live View**

Requires firewall rules with **`log`** — [enabling firewall logs](docs/user/enabling-firewall-logs.md)

Manual install: [installation.md](docs/user/installation.md)

## [v0.1.42] — 2026-09-16

### Changed
- Add always-on adaptive poll shedding, client visibility pause/RTT backoff, and a weak-device display cap so the live view degrades predictably under sustained load (#306, #331, #339, #341, #343)
- Add Auto/Manual fetch-budget controls and restore preferences before the first poll; extract polling lifecycle and render-policy decisions into focused modules (#347, #348, #352, #353, #356, #357)
- Extract parser/filter responsibilities while preserving the core/LuCI mirror and generated-classifier contracts; add fail-closed source-to-POT drift checks (#323, #333, #334)

### Added
- Reusable QEMU routed-forwarding SLO, adaptive-flood, memory-census, and fetch-budget qualification harnesses with recorded x86 and armsr evidence (#306, #308, #319, #339, #344, #345, #349)
- Coverage for weak-device rendering, native visibility behavior, coordinator disposal, fetch budgets, and pure render-policy decisions (#339, #350, #351, #352, #356)

### Fixed
- Keep adaptive state updates fail-safe under lock, filesystem, and concurrent-update failures, with expanded shell and rpcd regression coverage (#306)

Supported OpenWrt: **21.02**, **22.03**, **23.05**, **24.10** (opkg) · **25.12** (apk)

Feed install: [binary-feed.md](docs/binary-feed.md) · Menu: **Status → Firewall Live View**

Requires firewall rules with **`log`** — [enabling firewall logs](docs/user/enabling-firewall-logs.md)

Manual install: [installation.md](docs/user/installation.md)

## [v0.1.41] — 2026-09-11

### Fixed
- Contain OpenWrt jshn parsing inside a `set +u` subshell so strict-mode callers no longer abort poll/resolve on 24.10.8; real-jshn host coverage across five pinned releases + dual-arch QEMU smoke matrix (#317, #315, #316)

### Changed
- GitHub Release bodies are generated from the matching CHANGELOG section instead of `--generate-notes` (which shipped near-empty bodies for direct-commit tag ranges); missing fold falls back loudly (#324)

### Performance
- Extract the generated firewall-event classifier to a standalone `.awk` asset (`awk -f`) and stream filter stdin directly into jsonfilter — filter hot path 5 → 3 execs per poll, document capture removed, missing asset fails closed with `classifier_missing` (#322, refs #321/#308)

### Added
- Fork/exec census harness and armsr device budget-split table as the #308 profiling baseline (#311, #320); measured z3 full-verification timings (#318)

## [v0.1.40] — 2026-09-09

### Fixed
- Prepare the SDK cache before validating its path and install release validation tooling (#44)

## [v0.1.39] — 2026-09-09

### Fixed
- Restore shell strict mode while isolating OpenWrt jshn parsing from nounset state variables (#312, #313)

## [v0.1.38] — 2026-09-05

### Fixed
- B-1 canonical WAN zone identity for `uci changes` — `@zone[N]` and `cfg…` ids for the same WAN stay distinct from duplicate `name=wan` sections (#267, #239)
- Keep feed signing keys out of workspace-mounted build containers (#270)
- Require opt-in for insecure SSH in `agent-build-and-deploy` (no default host-key bypass)
- luci#8992 review follow-ups after v0.1.37: `timeout_missing` as warning, non-sticky rules-error UI, warn-tint degraded backend span (#253, #255, round-2/5 hygiene)

### Added
- Test coverage wave: timeout / `run_with_timeout` pins, upstream-cut / `.pot` parity, `rules_truncated` smoke, F5 Z3 idempotency + colon-drop/P3, C1 parser corpus, C2 lab Playwright bundle (#277–#284, #272–#276)
- Multi-model VVAH security audit playbook and honest-gap QEMU smoke (#268)

### Changed
- Validation matrix: measured Tier-2 times, warm lab Playwright bundle notes, flake history (#281, #284)
- Docs: upstream-merge lessons from luci#8992 waves; AGENTS.md upstream link anchors

## [v0.1.37] — 2026-08-31

### Security
- Rules map temp files use mktemp-only on sticky `/tmp` with POSIX `[ -k ]` (no `stat -c` on BusyBox) (#227, #204 class)
- Poll line count clamp rejects over-long digit strings before numeric compare (#221, #227)
- Declare `+jsonfilter` in `LUCI_DEPENDS`; missing filter exits non-zero with `error` (#220, #228)
- `json_escape` lives in `fwlive-logging.sh` so prerm does not fail standalone (#222, #228)

### Fixed
- Rules map reaches the client (no pipeline-subshell discard); global first-wins dedup (#217, #227)
- `fwlive.resolve` uses BusyBox `nslookup` instead of absent `getent` (#218, #228)
- Classifier is one awk pass per poll (not O(entries) forks); JSON filter decodes libubox escapes (#219, #228)
- UCI rule names with whitespace are not word-split into junk keys (#226, #228)
- Empty poll success returns `{"log":[]}`; `json_escape` preserves blank lines (#228)

### Changed
- Poll fetch depth scales with row limit (`rowLimit*4`, full ring when paused) (#228)
- Upstream cut strips `SOURCE_DATE_EPOCH` block; `PKG_VERSION`/`APP_VERSION` gate in baseline (#224, #228)
- Dual-maintenance policy and dependency prose in README (#225, #228)

## [v0.1.36] — 2026-08-25

### Security
- WAN logging lock moved to root-only `/etc/fwlive/logging.lock` (created with umask 077); production path rejects non-root-owned or group/other-writable lock dirs (#204)
- Symlink guard on the WAN logging lock path before truncate/chmod (#204)
- Removed unpinned `@playwright/mcp` from repo MCP config (#205)
- Security-review ledger refreshed with the 2026-08-23 pass (#206)

### Fixed
- Uninstall restores WAN zone `log` to the value before the first **Enable logging** via Live View (`prerm` + `/etc/fwlive/wan-log-baseline`) (#195)

### Changed
- Removed **Chip style** from Display options; filter chips always use the labels presentation (#195)

### Added
- `scripts/qemu-reset-wan-logging.sh` and `scripts/qemu-logging-uninstall-smoke.sh` for lab verification (#195)

## [v0.1.35] — 2026-08-21

### Security
- Strict IPv4/IPv6 validation in `is_resolvable_address` — hostname-shaped tokens (dotted-hex) no longer reach getent; multi-line input rejected wholesale (#192)
- WAN log toggle: staging+commit moved behind a last-moment foreign-staging gate with post-commit verification — no sweeping unrelated staged deltas, no reverting foreign data (#193)

## [v0.1.34] — 2026-08-18

### Security
- Pin SDK digest before signing-secret mounts (R7 / #179, #181)

### Changed
- `AGENTS.md` compressed to a brownfield hazard list; rules stay in owner docs (#180)

## [v0.1.33] — 2026-08-12

### Security
- Feed signing keys stay mode 0600 through decode/normalize (S1 / #165, #170)
- Pin `usign` fetch and verify SDK tarball sha256 before extract (S2 / #166, #171)
- Create WAN-logging lock at mode 0600 (S3 / #167, #172)
- WAN-logging enable/disable: named/anonymous WAN zone lookup; refuse when firewall UCI changes are pending (S4 / #168, #173)

### Changed
- Simple view: hint line and Time tooltip mention row click to expand the full message (#118, #175)
- Watch strip G Hybrid: left-aligned clusters, merged WAN logging control, segmented Detail/Message toggles (#176)
- Flow column arrow uses bold weight for clearer src → dst scanning (#176)
- Protocol filter is a grouped select (Common / Also seen / Exclude) with an always-on custom field (typing wins) (#176)
- Lab/SDK pins: OpenWrt **24.10.8** and **25.12.5** (#130, #174)

### Added
- Security review ledger documenting control proof status (#169)
- Tests: Node coverage for proto menu/custom precedence; Playwright smoke for proto pair + segments (`scripts/qemu-proto-ui-smoke.sh`) (#176)

## [v0.1.32] — 2026-08-11

### Security
- Route all `E()` string children through text nodes (uniform array form); bump `PKG_VERSION` to 0.1.32 (#148, #158)
- LuCI-accurate `E()` harness with DOM-render discrimination so renderer regressions fail CI (#149, #155)
- Remove `/tmp` trust from feed signing paths (#142, #157)
- SHA-pin GitHub Actions and route workflow-dispatch inputs via env (#143, #146, #156)

### Fixed
- Capture log prefix/comment with escaped quotes (#124, #125)
- Bound `ubus fwlive.resolve` to a wall-clock budget (#147, #161)
- Serialize WAN logging toggles with `flock` (#151, #163)
- Verify sha256 of downloaded lab images + u-boot; record resolved SDK image digests in the release manifest (#144, #145, #159, #162)
- Resilient feed fetch and link-check retry on curl code 000 (#122, #127, #152, #160)

### Added
- `SECURITY.md` disclosure policy (#123)
- Security model doc: trust boundaries, untrusted-input inventory, and testable security invariants ([`docs/developer/security-model.md`](docs/developer/security-model.md)) (#139)
- `AGENTS.md` — router for coding agents; each rule links to its canonical document (#139)
- Repeatable `security-audit` skill under `.cursor/skills/` (#139)
- Automated git subtree re-cut script for upstream PRs (#116, #117)

### Documentation
- Architecture doc output-encoding rule corrected; security model is the single source (#137, #139)
- Binary-feed install fold; README Tests/License badges; renderer-test and link-checker notes (#113, #119, #139)

## [v0.1.31] — 2026-07-31

### Added
- First-run empty state, one-time logging consent panel, and WAN logging readiness text on the watch strip (#112)
- Single-source classification: `CLASSIFY_SPEC` in `core/fwlive-log.js`, generated shell classifier; LuCI classify parity via gate + preserve region (#84, #95, #97)
- CI shell↔JS parity under BusyBox ash (`SH=busybox sh`) (#103)
- Markdown link checker (internal + external) in the host test gate (#107, #110)

### Fixed
- First-run empty state showed Enable WAN logging twice (consent panel and empty-state CTA) (#112)
- LuCI wrapper gate deep-equals full `CLASSIFY_SPEC` (not only `actionWords`) (#99)
- Shell non-firewall prefixes use word-boundary globs matching JS (`dnsmasqfoo` class) (#100)
- More filters / Help disclosure arrows under custom themes (#105)

### Changed
- User guide First visit path with empty → after-Enable → daily-use screenshots (#112)
- Log table grows with the browser window (was capped at 800px) (#112)
- **Show Detail** widens the page past LuCI’s 940px column; Simple view keeps the normal width (#112)
- Parser sync gate uses classify goldens + shell codegen freshness / LuCI wrapper gate (drops `PARSER_SYNC_VERSION` counter) (#84)
- `normalizeAction` derives pass/deny-class words from `CLASSIFY_SPEC.actionWords` (#101)
- Behavior-preserving cleanup: parser, rpcd shell, logging.js, view extracts (#90, #91, #92)
- Extract fwlive CSS from escaped `css.js` into `fwlive.css` (#87, #96)
- Stream `@.log[*]` once in `fwlive-log-filter.sh` (#93)
- Shellcheck libexec/rpcd scripts in the host test gate (#94)
- Remove `archive/`; add `npm test` alias (#98)

### Documentation
- Document LuCI gate-not-generator design (banner, `gen-all.sh`, contributing) (#102)
- Fix broken links (`blob/main`→`master`, archive refs, iptables relative path); align Stage 6/7 status (#107, #108, #109)

---

## [v0.1.30] — 2026-07-31

### Changed
- Live View A2 chrome: watch strip (Pause/Resume, logging CTA, Show Detail) + grouped Display options drawer; remove Auto-refresh checkbox (#77)

### Fixed
- Accessible row-tint palette pinned to teal/orange (no Bootstrap `--warn-color-high` yellow) (#75, #76)

---

## [v0.1.29] — 2026-07-28

### Added
- Selectable filter chip styles (Labels / Symbols / Tone) with localStorage persistence (#18, #38)
- Row tint toggle (on/off) with Classic (green/red, default) and Accessible (teal/orange) palettes (#40, #47, #49)
- Theme tint fallback when LuCI theme CSS variables do not paint pass/deny row backgrounds
- Security-only Dependabot config for npm, Docker, and GitHub Actions (#42)
- gitleaks pre-commit hook for local secret scanning (#41)

### Fixed
- Pause → resume no longer drops live events; pause buffer is merged on resume (#43, #44)
- Parser version sync (v3), overlapping poll guard / `pagehide` cleanup, and filter input debounce (#43, #45)

### Changed
- CI workflows set explicit `GITHUB_TOKEN` permissions (#39)

---

## [v0.1.28] — 2026-07-27

### Documentation
- Consolidated planning/spec docs into ROADMAP.md
- Restructured over-long user docs (Quick Start first)
- Added CHANGELOG.md, FAQ.md, and upgrade guide
- Fixed cross-reference accuracy and review findings throughout

---

## [v0.1.27] — 2026-07-24

### Changed
- Refactored `fwlive.js` into modular files: `constants.js`, `css.js`, `tint.js`, `links.js`, `chips.js`, `logging.js`, `table.js`
- All modules now use `baseclass.extend` for proper LuCI lifecycle

### Fixed
- Firefox console errors from baseclass usage
- `qemu-install-fwlive.sh` syncs all module files

---

## [v0.1.26] — 2026-07-23

### Security
- Removed session ACL grant for direct `ubus log.read` — poll now reads logd inside the rpcd plugin only
- Hardened `resolve` reverse DNS: IPv4/IPv6 shape validation before lookup
- JSON escaping for rpcd responses
- MAC address redaction in UI display

### Fixed
- WAN zone logging disable: clear only filter-log bit 0, preserving other zone bits

### Added
- Po/i18n template (`luci-app-fwlive.pot`)
- SPDX headers on shell scripts
- Upstream publish checklist

---

## [v0.1.25] — 2026-07-21

### Changed
- Minor packaging fixes

---

## [v0.1.24] — 2026-07-18

### Added
- WAN zone enable/disable logging toolbar buttons on Live View page
- `ubus fwlive.logging_status`, `enable_wan_logging`, `disable_wan_logging`
- `fwlive-logging.sh` helper script
- ACL grants for write operations

---

## [v0.1.23] — 2026-07-11

### Changed
- Backend and matrix improvements

---

## [v0.1.22] — 2026-07-03

### Changed
- CI and build improvements

---

## [v0.1.21] — 2026-07-03

### Changed
- Backend improvements

<!-- v0.1.20 was never tagged or folded; compare v0.1.21 → v0.1.19. -->

---

## [v0.1.19] — 2026-06-27

### Added
- 22.03.7 lab sign-off

### Changed
- Build and smoke infrastructure

---

## [v0.1.18] — 2026-06-27

### Added
- fw4 rule name resolve via `ubus fwlive rules`
- **Show hostnames** checkbox (default off) with `ubus fwlive resolve`
- Server-side firewall-only read via `ubus fwlive poll`

---

## [v0.1.17] — 2026-06-20

### Added
- 21.02.7 (fw3/iptables) lab sign-off
- `fwlive-iptables-ping-log.sh`

### Fixed
- 21.02 LuCI compatibility (lua prefix dispatcher)
- Release asset publish and wrap bug from 21.02 support

---

## [v0.1.16] — 2026-06-20

### Added
- OpenWrt 21.02 fw3/iptables support in the SDK matrix and binary feed
- `docs/openwrt-21.02-compat.md` and related install/requirements notes

---

## [v0.1.15] — 2026-06-20

### Added
- 21.02.7 SDK build and x86 QEMU smoke sign-off

---

## [v0.1.14] — 2026-06-19

### Added
- Parameterized validation matrix (`validate-openwrt.sh`)
- Baseline validation gate (`validate-baseline.sh`)
- Full matrix validation (`validate-openwrt-all.sh`)

---

## [v0.1.13] — 2026-06-14

### Added
- Filter operators: `!` prefix for is-not / not-contains
- Action dropdown includes **not pass**, **not drop**, etc.
- Flood banner, token bucket render cap
- **Simple / Detailed** view toggle with `localStorage` persistence
- URL hash `view=detailed`
- Click-to-filter on action, protocol, interface, address cells
- Filter chip bar (show + clear active filters)
- `matchesFilter()` AND logic for multi-field filtering
- Row expand/collapse for raw message in Simple view
- `qemu-smoke-fwlive.sh` headless checks

---

## [v0.1.12] — 2026-06-14

### Changed
- Package version bump for feed republish

---

## [v0.1.11] — 2026-06-14

### Fixed
- GitHub Actions publish workflow write permissions

---

## [v0.1.10] — 2026-06-14

### Fixed
- Wrong CI sign path for package feed

---

## [v0.1.9] — 2026-06-14

### Added
- **Auto-refresh** checkbox (maps to `paused`)
- **Limit** dropdown (25…2000, default 100)
- `localStorage` persistence for view preferences
- Status line: `shown/limit` while paused/live

---

## [v0.1.8] — 2026-06-14

### Added
- Pause/resume toolbar button
- Buffer status line
- Row message wrap/one-line toggle

---

## [v0.1.7] — 2026-06-14

### Added
- **Rule** column with `rule_hint` from nft log prefix
- Deep link to firewall admin from Rule column
- `ubus fwlive poll` server-side filter

---

## [v0.1.6] — 2026-06-14

### Added
- Stage 2 schema hardening: `interface_in`/`out` split, normalized `action` enum, `flags`/`length` parsing
- Schema test fixtures and assertions

---

## [v0.1.5] — 2026-06-13

### Added
- Firewall-only feed (`isFirewallEvent` heuristic)
- Normalized table columns and client-side filters
- Live polling (~1s), URL hash filter persistence

---

## [v0.1.4] — 2026-06-13

### Added
- Initial working LuCI view (`view.extend`)
- Basic JSON-RPC to `ubus log.read`
- Quick search and field filters

---

## [v0.1.3] — 2026-06-13

### Fixed
- GitHub Actions artifact copy-out (uid mismatch)

---

## [v0.1.2] — 2026-06-13

### Added
- Reproducible build verification
- SDK build matrix

---

## [v0.1.1] — 2026-06-13

### Added
- Signed opkg/apk feed at GitHub Pages
- Initial GitHub Releases publishing
- Basic CI pipeline

---

[v0.1.46]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.45...v0.1.46
[v0.1.45]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.44...v0.1.45
[v0.1.44]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.43...v0.1.44
[v0.1.43]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.42...v0.1.43
[v0.1.42]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.41...v0.1.42
[v0.1.41]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.40...v0.1.41
[v0.1.40]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.39...v0.1.40
[v0.1.39]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.38...v0.1.39
[v0.1.38]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.37...v0.1.38
[v0.1.37]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.36...v0.1.37
[v0.1.36]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.35...v0.1.36
[v0.1.35]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.34...v0.1.35
[v0.1.34]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.33...v0.1.34
[v0.1.33]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.32...v0.1.33
[v0.1.32]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.31...v0.1.32
[v0.1.31]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.30...v0.1.31
[v0.1.30]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.29...v0.1.30
[v0.1.29]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.28...v0.1.29
[v0.1.28]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.27...v0.1.28
[v0.1.27]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.26...v0.1.27
[v0.1.26]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.25...v0.1.26
[v0.1.25]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.24...v0.1.25
[v0.1.24]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.23...v0.1.24
[v0.1.23]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.22...v0.1.23
[v0.1.22]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.21...v0.1.22
[v0.1.21]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.19...v0.1.21
[v0.1.19]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.18...v0.1.19
[v0.1.18]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.17...v0.1.18
[v0.1.17]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.16...v0.1.17
[v0.1.16]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.15...v0.1.16
[v0.1.15]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.14...v0.1.15
[v0.1.14]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.13...v0.1.14
[v0.1.13]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.12...v0.1.13
[v0.1.12]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.11...v0.1.12
[v0.1.11]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.10...v0.1.11
[v0.1.10]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.9...v0.1.10
[v0.1.9]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.8...v0.1.9
[v0.1.8]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.7...v0.1.8
[v0.1.7]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.6...v0.1.7
[v0.1.6]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.5...v0.1.6
[v0.1.5]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.4...v0.1.5
[v0.1.4]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.3...v0.1.4
[v0.1.3]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.2...v0.1.3
[v0.1.2]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.1...v0.1.2
[v0.1.1]: https://github.com/lucas-albers-lz4/fwlive/releases/tag/v0.1.1
[v0.1.49]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.48...v0.1.49
[v0.1.48]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.47...v0.1.48
[v0.1.47]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.46...v0.1.47
[v0.1.50]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.49...v0.1.50
