# Security review state

> **2026-09-27 delta review (master `73a7a6a2f5`, after #869):**
> PR #854 (issue #841) and PRs #857/#862/#863 harden lab feed-source replacement,
> URL transport, host-port checks and QEMU process ownership; these are host/lab
> scripts, not shipped rpcd methods. PR #864 (issues #811–#814) isolates SDK
> probe state, retains caller traps, honors explicit build-all filters, and bounds Pages checks; #865 accepts both APK
> artifact spellings in the reproducibility check. Host tests cover these
> contracts; no real feed publish or QEMU boot was run in this review.
> #866/#867 alter buffering, scoped-IP display, frame reservations, keyed row
> paints and scroll status. Untrusted log/PTR/hash values still reach the examined
> render paths through text nodes; the recording `E()` harness and view tests
> passed. #870–#874 tighten the test runner, JSON-filter stub disclosure,
> classifier/corpus assertions and view harness; the checked-in generated shell
> differs only in comments. The host suite used a JSON-filter stub, not real
> OpenWrt jsonfilter; matched BusyBox/jshn release tests ran separately.
> Static workflow/shell checks found no new ACL grant, non-empty HTML write,
> workflow expression in a `run:` body, unpinned action, or secret staging path.
> No new security finding was confirmed by this delta pass.

> **2026-09-26 #774 / #767 / #777 / #776 / #779 delta:** `uci_rule_names`
> captures `uci show firewall` once. `map_prefix_with_label` increments
> `_map_lines` and trips `rules_truncated` at `RULES_MAP_MAX_LINES=512`
> so first-wins duplicates cannot walk an unbounded dump.
> `maybe_snapshot_wan_log_baseline` refuses a symlink target or dir and
> applies `wan_log_lock_dir_safe` on the production `/etc/fwlive` path.
> `fwlive_adaptive_state_dir_ok` refuses group/other-writable dirs (same
> `find -prune -perm` as the logging lock). prerm redirects restore
> stdout so a failed commit cannot print rpcd JSON to opkg/apk.
> Host coverage: `tests/fwlive-rules-map.test.js` `testUciShowOnce`,
> `testRulesMapLineBound`; `tests/fwlive-logging.test.sh` symlink
> baseline; `tests/fwlive-adaptive-cap.test.sh` world-writable state dir.
> No ACL, DOM sink, or read/write-scope change.

> **2026-09-26 #828 / #825 / #772 / #775 delta:** `map_add` skips a
> `json_escape` fork when the raw key cannot contain escapes or glob
> metacharacters and is already present in `$OUT`. `resolve` skips
> producer-validated repeats before they increment `lookups` or start a
> `nslookup`. Rules-map dump temps (`_rules_dump`, `_nft_tsv`) are
> removed on EXIT/HUP/INT/QUIT/TERM as well as after parse. The nft
> dump is waited in the background so a trapped SIGTERM is not deferred
> behind `setsid`. Host coverage:
> `tests/fwlive-rules-map.test.js` `testResolveDedupesBeforeLookup`,
> `testRulesTempsCleanedOnKill`; `tests/fwlive-jshn-compat.test.py`
> 33-duplicate resolve. No ACL, DOM sink, or read/write-scope change.

> **2026-09-26 #821 / #803 delta:** Packages index filtering no longer
> swallows grep I/O errors (`|| true` removed on host and in-container
> paths). `feed_publish_copy_keys` requires both public keys and fails
> closed if either path is unset or missing. Host coverage:
> `tests/feed-publish-copy-keys.test.sh`. No ACL, DOM sink, or
> read/write-scope change.

> **2026-09-26 #842 / #817 delta:** `publish-packages.yml` `build-publish`
> pins Node 22 with the same digest-pinned `actions/setup-node` as
> `fwlive-test.yml` before `validate-baseline.sh` (`npm ci` + lint),
> with `package-manager-cache: false` so the publish job cannot restore
> a poisoned npm cache.
> Every checkout in `fwlive-test.yml` and `publish-packages.yml` sets
> `persist-credentials: false`. Host coverage:
> `tests/ci-workflow-pins.test.sh`. No ACL, DOM sink, or read/write-scope
> change.

> **2026-09-26 #766 delta:** `publish-packages.sh` canonicalizes the
> staging path (`pwd -P`) before `rm -rf` and refuses `/`, `$HOME`, the
> repository root, and any path outside `$ROOT` or `$RUNNER_TEMP` unless
> `--allow-outside` is set. `--allow-outside` still refuses `/`, `$HOME`,
> and the repo root. Host coverage includes a symlink-to-`/` spelling.
> No ACL, DOM sink, or read/write-scope change.

> **2026-09-26 #761 delta:** `luci-app-fwlive` declares
> `+coreutils-timeout`; package lifecycle tests inspect built IPK control
> metadata and APK ADB `info.depends`. The rpcd helper stays fail-closed when
> the provider is absent. Poll/rules/resolve return typed `timeout_missing`
> errors before invoking their providers, and the resolver fault is not
> recorded as a negative PTR cache entry. An inner GNU `timeout --foreground`
> sends TERM at the configured budget; the outer GNU timeout runs a BusyBox
> `setsid` supervisor and KILLs its dedicated process group after the one-second
> grace. Its pipe reader stays alive until stdout closes, and the supervisor
> waits for all other live session members even if a descendant closes stdout.
> Host fault-injection covers TERM-resistant commands, early parent exit with
> stdout both open and closed, filter descendants, nft, single and looped DNS
> time bounds.
> `timeout_missing` remains a non-gating warning; a failed poll plus that
> warning shows an incomplete-installation repair message. The view keeps the
> known backend, rules error, and unrelated warnings visible when a status
> snapshot is stale; typed poll errors identify provider loss immediately,
> and a successful poll refreshes status and rules to clear stale diagnostics.
> A per-read generation prevents an older recovery status response from
> overwriting a later logging-toggle refresh in the same poll epoch.
> Timeout containment is process-group scoped: the fixed synchronous
> `ubus`, `nft`, `nslookup`, and filter-pipeline targets are covered, but a
> descendant that creates a new session or process group is outside the
> guarantee and is not claimed by host or guest tests.
> Healthy installs show no missing-provider warning. Host view tests and live
> Playwright cover stale-state handling, repair, and in-session recovery.
> QEMU 24.10.8 verified an opkg upgrade
> from released 0.1.46 to test candidate 0.1.47, automatic provider
> installation, and the missing-binary diagnosis through ubus and the live
> browser. No ACL, DOM sink, or read/write-scope change.

> **2026-09-24 #606 delta:** `wan_filter_log_decimal` rejects digit runs
> longer than 10 before `$ (( ))`, so a 20-digit UCI `log` value cannot
> kill dash or wrap on BusyBox. Enable/disable/status keep the existing
> non-numeric fallbacks. Selftest pins oversized and malformed inputs
> without asserting a wrap integer. No ACL, DOM sink, or read/write-scope
> change.

> **2026-09-24 #663 delta:** `restore_wan_log_baseline` keeps the recovery
> marker until the post-restore firewall reload succeeds (including the
> already-at-baseline retry path) and returns nonzero on reload failure.
> Reload still runs without the flock; the helper re-acquires before
> unlinking so a concurrent enable cannot drop the marker while UCI no
> longer matches. Host coverage stubs failing reload and a post-reload
> UCI race. No ACL, DOM sink, or read/write-scope change.

> **2026-09-24 #665 delta:** poll treats a zero-exit filter body without a
> numeric `messages_received` as unhealthy (`_filter_ok=0`), so the
> adaptive merge fallback of 0 cannot clear hot/shed. A valid empty ring
> still includes the count. Host coverage pins missing-count vs
> `messages_received:0`. No ACL, DOM sink, or read/write-scope change.

> **2026-09-24 #664 delta:** `enrich_rules_dump` treats a failing
> `nft_dump_fields` awk pass as `_enrich_error=tsv_failed` and continues
> with UCI-only rules instead of exiting under `set -eu` before JSON.
> Host coverage stubs `awk` exit 7 on `call rules`. No ACL, DOM sink, or
> read/write-scope change.

> **2026-09-24 #637 delta:** `sdk_matrix_validate_version` now rejects
> unknown `--version` values and non-numeric patch suffixes; it accepts
> `SDK_MATRIX_VERSIONS` plus `latest`/`SNAPSHOT` and
> `^(23\\.05|24\\.10|25\\.12)\\.[0-9]+$`. No ACL, DOM sink, or read/write-scope
> change.

> **2026-09-24 #590 delta:** The publish workflow fetches the live Pages
> `manifest.json` (cache-bust `?cb=${GITHUB_RUN_ID}`, no-cache headers) and
> runs `guard-feed-deploy.sh` before deploy. HTTP 404 (no live manifest yet)
> still validates the staged manifest `git_tag` against the release tag and
> skips only the live-version comparison (bootstrap / wiped `gh-pages`).
> Other non-200 or curl failures fail the job. Tags must be
> `vMAJOR.MINOR.PATCH` (1–9 digits per component) at Resolve release tag,
> not only in the guard. `allow_rollback` defaults false. A rejected or
> failed downgrade guard aborts the `build-publish` job, so GitHub Release
> assets are also not uploaded for that run. No ACL, DOM sink, or
> read/write-scope change.

> **2026-09-23 #592 delta:** `feed_publish_find_artifact` requires the
> expected `PKG_VERSION` and fail-closes when no filename matches that
> version. Mtime ordering applies only among matches; equal-mtime
> lexicographic `ls -1t` order is a secondary pick, not a version
> substitute. Host coverage includes equal-mtime and version-mismatch
> cases. No ACL, DOM sink, or read/write-scope change.


> **2026-09-23 #421 slice 2:** Feed install smoke compares the guest
> `opkg info` / `apk query` version to the published `Packages.gz` /
> `packages.adb` index for that cell. No ACL, DOM sink, or read/write-scope
> change.

> **2026-09-23 #421 delta:** The publish workflow gains a periodic 25.12 feed
> smoke and the pages wait includes the APK key (`fwlive-feed.rsa.pub`). No
> ACL, DOM sink, or read/write-scope change.

> **2026-09-23 #458 delta:** The shipped `fwlive-logging.sh` helper comment now
> matches fd-inheritance (`exec 9>>` + `flock 9`; recovery is until the last
> fd-9 inheritor exits, not merely the holder) and the reload-failure rollback
> re-acquire (read-compare-restore is atomic). No ACL, DOM sink, or
> read/write-scope change.

> **2026-09-23 #490/#451/#519/#520/#521 delta:** CI pins `ruff==0.16.8` in both
> workflows; `publish-packages.yml` uses a `publish-packages` concurrency
> group with `cancel-in-progress: false` and `queue: max` so a third pending
> tag is not dropped; SDK cache patch dirs come from
> `sdk_matrix_release_version_labels` instead of a hardcoded list; symlink
> guards run before `mkdir`; inspect-step digest diagnostics print via
> assignment `|| { echo; exit 1 }` under `set -e`; long jobs set
> `timeout-minutes` (test 30, test-ipk-payload 45, build-publish 180;
> smoke stays 45). No ACL, DOM sink, or read/write-scope change.

> **2026-09-23 #434 delta:** `scripts/agent-build-and-deploy.sh` is ipk-only
> (23.05/24.10 `opkg`). A non-`.ipk` `--ipk` path (including a missing
> `.apk`) dies with a pointer to `qemu-install-fwlive.sh` before the file
> existence check. SSH host-key default and `--lab-only` opt-in are
> unchanged. No ACL, DOM sink, or read/write-scope change.

> **2026-09-22 #494 delta:** `verify-reproducible-build.sh` preserves
> `artifact_sha`'s exit status (no `read <<< "$(...)"` mask) and rejects an
> empty hash on both passes, so a missing artifact cannot compare equal and
> print `OK`. Host coverage drives `verify_one` with empty `out/` and a
> pass-2 disappearance. No ACL, DOM sink, or read/write-scope change.

> **2026-09-22 #518 delta:** `verify-reproducible-build.sh` locates artifacts
> under the resolved `SDK_MATRIX_PACKAGE_ARCH` directory and honors
> `--target` / `OWRT_VERIFY_TARGET`. A missing arch dir fails `artifact_sha`.
> Host coverage checks armsr vs an x86_64 decoy. No ACL, DOM sink, or
> read/write-scope change.

> **2026-09-22 #435 delta:** `sdk_matrix_copy_out` now removes matching
> luci-app-fwlive ipk/apk files from the destination (`$dest/fwlive` and
> dest-root globs) before copying, then fail-closes if no matching artifact
> exists after copy. A leftover package from an earlier build cannot satisfy
> the existence check when this invocation copies nothing. Host coverage
> plants a stale matching IPK, stubs docker copy as a no-op, and requires
> copy_out to fail. No ACL, DOM sink, or read/write-scope change.

> **2026-09-22 #495 delta:** `feed_publish_find_artifact` now selects the
> newest-mtime luci-app-fwlive ipk/apk under a reused `out/` tree (`ls -1t`)
> instead of the alphabetically first name (`ls -1`). A leftover
> `luci-app-fwlive_0.1.44_all.ipk` therefore cannot win over a later-built
> 0.1.45/0.1.46. Host coverage plants a later-named newer file that
> alphabetical `ls -1` would not pick. No ACL, DOM sink, or read/write-scope
> change.

> **2026-09-22 #504 delta:** nft dump parse is one awk pass (`nft_dump_fields`)
> writing TSV to a second tempfile, then `map_from_nft_stream` stops at the
> map byte/key cap. The dump is not buffered in a shell variable. Host
> coverage includes overflow and one-pass cases. No ACL, DOM sink, or
> read/write-scope change.

> **2026-09-22 #492 delta:** `rules` performs one `nft list ruleset` dump
> for detect and parse. A missing or failed dump is `unknown`/`no_backend`
> (`nft_failed` is no longer produced). Host coverage asserts a single dump.
> No ACL, DOM sink, or read/write-scope change.

> **2026-09-22 #491 delta:** poll ubus log-read and the firewall filter each
> run under `POLL_TIMEOUT` (5s) via `run_with_timeout`. Timeout or a missing
> `timeout` binary fails closed (`log_read_failed` / `filter_failed`) instead
> of hanging the rpcd worker. Host coverage uses a hung ubus stub. No ACL,
> DOM sink, or read/write-scope change.

> **2026-09-22 #441 delta:** `FWLIVE_JSHN_SH` defaults to
> `/usr/share/libubox/jshn.sh`; it is a host-test override, not a
> LuCI/session-controlled env (rpcd worker env is root-owned, not set by
> unprivileged ubus callers). Named jshn poll-cap failures go to logger,
> not poll JSON `error`. Leading-zero strip in `poll_clamp_lines` is
> in-shell so a default-50 poll does not add a `sed` exec. No ACL/DOM
> change.

> **2026-09-22 #502 delta:** post-commit WAN-log verify mismatch now returns
> rc 2 from `commit_wan_log_change`, still reloads fw4, and reports
> `firewall_commit_raced` with `ok:false`/`changed:false` instead of rolling
> back a foreign writer's committed UCI. Host coverage pins the JSON and the
> reload. No ACL, DOM sink, or read/write-scope change.

> **2026-09-22 #506 delta:** `parse_nslookup_name` treats `name =` as a whole
> token and rejects the phrase `domain name =` even when `domain` and `name`
> are separated by repeated whitespace. Host coverage includes
> `domain  name =` and tab-space variants. No ACL, DOM sink, or
> read/write-scope change.

> **2026-09-22 #503 delta:** WAN-log reload rollback (`restore_wan_zone_log`)
> now returns non-zero when `uci commit firewall` fails, and reverts its own
> orphaned staging when the remaining `uci changes` list is only that log
> option. Callers therefore report failure instead of a false rollback
> success, and a later toggle is not stuck on `firewall_changes_pending`.
> Host coverage drives a commit-failure stub and requires the revert. No ACL,
> DOM sink, or read/write-scope change.

> **2026-09-22 #507 delta:** the JSON summary decoder keeps the BusyBox-awk
> Latin-1 `%c` path for `\uXXXX` in 1..255 and collapses code points outside
> that range (no UTF-8 materialization). The generator documents this limit;
> host tests pin `euro\u20acrule` → `eurorule`, Latin-1 `\u00e9`, and NUL
> drop. No classifier, ACL, DOM sink, or read/write-scope change.

> **2026-09-22 #543 delta:** `resolve` skips non-string `addresses` elements
> instead of ending enumeration, so later valid IPs still resolve. Skipped
> types do not set `truncated` (`truncated` remains `RESOLVE_MAX` /
> `RESOLVE_BUDGET` only). Host coverage:
> `tests/fwlive-rpcd-security.test.js` and
> `tests/fwlive-jshn-compat.test.py`; no ACL, DOM sink, or
> read/write-scope change.

> **2026-09-22 #500 delta:** WAN log baseline remains enable-only. Disable of
> a pre-existing/foreign log bit is not snapshotted, so uninstall restore
> will not put that bit back. Package README and the helper comment record
> that hole as the product contract. Host coverage asserts disable without a
> prior enable neither writes a baseline nor restores the foreign bit; no
> ACL, DOM sink, or read/write-scope change.

> **2026-09-22 #498 delta:** `fwlive-log-filter.sh` now removes its temporary
> JSON file and exits with the signal status for HUP/INT/QUIT/TERM instead of
> continuing after a trapped signal. Host coverage interrupts a live
> `jsonfilter`, requires the TERM status, and verifies tempfile cleanup; no
> ACL, DOM sink, or read/write-scope change.

> **2026-09-22 #505 delta:** the adaptive state writer now scopes its 077
> umask to the temporary-file write, so fail-open callers do not change the
> surrounding rpcd shell's umask. Host coverage checks both unchanged caller
> umask and 0600 state-file creation; no UCI, ACL, DOM sink, or
> read/write-scope change.

> **2026-09-27 #894 delta:** anonymous and named firewall rule names now come
> from the same `uci -q show firewall` output, with a 512-name processing cap
> and explicit `rules_truncated` status. The rules-map path no longer invokes
> `uci get` once per named section. Host coverage checks the cap with 600
> duplicate names and verifies the first result is retained; no ACL, DOM
> sink, or read/write-scope change.

> **2026-09-21 #416 delta:** The rules map now performs a second `uci -q show firewall` pass for named `config rule` sections and attempts one filtered `uci -q get firewall.<section>.name` per section; missing UCI or name remains non-fatal. The branch tests cover a named section lookup and retain first-wins and whitespace-filtering coverage.

> **#389 lifecycle follow-up:** the packaged hook now understands the generated opkg wrapper (`<wrapper> remove`), APK 3.0's version-valued `pre-deinstall`, and skips upgrade/empty/unknown actions, `PKG_UPGRADE=1`, and non-version `1a2`. Host tests execute extracted `prerm-pkg` (so an always-restore body fails) and model the opkg `default_prerm` `$1-pkg` hop; installed uninstall restoration is in [the dated #389 evidence](../evidence/issue-389-2026-09-20.md). Same-version reinstall cells are no-op preservation checks only and do not exercise the hook.
> **2026-09-27 #848 evidence:** a version-changing 25.12.5 APK upgrade
> 0.1.43-r1 → 0.1.44-r1 ran the new package's `post-upgrade`, not the old
> package's `pre-deinstall`; the WAN `log` bit and baseline marker survived.
> apk-tools 3.0.5 runs `pre-deinstall` only on uninstall (`apk del` /
> `newpkg == NULL`). The dated QEMU trace is in
> [issue-848-2026-09-27.md](../evidence/issue-848-2026-09-27.md). This does
> not prove every future apk-tools release or turn the old-version argument
> guard into a required upgrade path.

> **Status:** 81 listed controls in force (counted in the table below); 0 open security findings in this ledger. This delta found no new vulnerability; proof limits remain explicit below. Housekeeping GHAS sub-features N/A on personal account (#293 H2 closed).
> **2026-09-22 #443 delta:** the fetch-pin regression gate now identifies the executable `verify_downloaded_sha256` call site rather than the function definition, and its negative fixture proves extract-before-verify fails the gate. This strengthens supply-chain test coverage only; no shipped runtime, ACL, DOM sink, or command-surface change.
> **2026-09-22 #457 delta:** the reload-failure rollback now captures the committed log value and performs a post-stage foreign-delta check before its `uci commit firewall`; a race aborts and removes only the rollback staging. Host coverage exercises the rollback race; no ACL, DOM sink, or read/write-scope change.
> **#392 base:** added a reusable QEMU smoke that authenticates two temporary LuCI/uhttpd `/ubus` sessions, exercises all six declared fwlive methods for the granted session, proves that the same session cannot call `log.read`, asserts a `luci-base`-only session can call `file.list` then is denied sampled fwlive methods with JSON-RPC `-32002`, and restores `/etc/config/rpcd` on exit. The host harness checks syntax and the evidence boundary only; it does not claim live ACL enforcement. The stacked follow-up records the live result.
> **#392 R4b:** the installed LuCI/uhttpd session smoke passed on OpenWrt 24.10.8 x86_64. A temporary account with the `luci-app-fwlive` ACL called all six declared fwlive methods and was denied `log.read` with JSON-RPC code `-32002`. An authenticated `luci-base`-only account first succeeded at `file.list`, then was denied sampled `logging_status` (read) and `enable_wan_logging` (write) with the same code; the remaining four fwlive methods were not called on the deny session. The artifact records the package/source and in-tree plugin/ACL SHA-256 values and quotes the helper stdout, including `guest rpcd backup restored and hash verified`.
> **Current delta:** 2026-09-21 #418: the installed-matrix `validate_matrix_install_ipk` path invokes `qemu-install-fwlive.sh --artifact-only`; that mode removes the known source-synced files and force-reinstalls the selected package artifact before the matrix smoke, preventing the matrix path from being overlaid by the source tree. This records the branch's validation-path behavior; no new live matrix result is claimed here. Prior: 2026-09-20 #389: the package `prerm` is defined before LuCI's `BuildPackage` call so the restore hook is included in both IPK/APK artifacts; host coverage models generated opkg wrapper arguments, APK 3.0 version-valued uninstall arguments, upgrade/empty/unknown fail-closed paths, `PKG_UPGRADE=1`, a literal-dot version glob, the opkg `default_prerm` `$1-pkg` hop, and non-root staging installs, and it executes extracted `prerm-pkg` so an always-restore body fails. QEMU uninstall restoration is in [the dated evidence](../evidence/issue-389-2026-09-20.md): 24.10.8 armsr IPK (`qemu-logging-uninstall-smoke.sh` uninstall only; root-SSH `ubus` observations for `poll`/`resolve`/`rules`/enable/disable are recorded separately and are not session proof), 24.10.8 x86 IPK uninstall, and 25.12.5 APK uninstall; same-version reinstall is a no-op preservation check, not hook proof. No ACL, DOM sink, or read/write-scope change. Prior: 2026-09-20 #378 Phase 2 rpcd/LuCI and #388: the rules map is nft-only (`iptables-save` dump path and `__rulesmap_iptables` CLI hook removed; detect failure is `unknown`/`no_backend`; nft dump failure keeps `nft_failed`), `legacy_iptables_detected` is shown as a non-gating `#fwlive-backend` `textContent` clause, and rule links always use `admin/network/firewall/rules`. Prior: 2026-09-20 #394 host coverage for exact rpcd/ACL method ownership, hostile chip/hash/table values, and fail-closed shell/toggle paths; the `q` chip fix keys behavior from `spec.key` while preserving display labels. Prior: #384 live `/proc/net/if_inet6` check on the current 24.10.8 and 25.12.5 QEMU pins (stock stack present including `lo`; `ipv6.disable=1` missing file; IPv4-only enable allowed), #371 nf_log backend normalization and independent IPv6 family readiness, plus #383 follow-up to #373: no-zone candidates now travel through `logging_status` and render as text nodes in the LuCI empty state and toolbar; no ACL grant, DOM sink, read/write-scope, or HTML sink change.
> **2026-09-22 #455 delta:** logging bit helpers now canonicalize digit-only UCI values before arithmetic, so leading-zero values such as `08` and `010` remain valid decimal input and cannot abort the logging RPC; invalid values retain the existing fail-closed behavior. Host coverage exercises the helper and complete `logging_status` JSON path; no ACL, DOM sink, or read/write-scope change.
> **2026-09-22 #428 delta:** adaptive-cap planning now probes upward by doubling a retained cold full-sized cap (250 → 500 → 1000 → 2000) instead of oscillating directly between the weak-device floor and the maximum; deterministic shell coverage exercises the sequence. No UCI, ACL, DOM sink, or command-surface change.
> **2026-09-21 #419 delta:** the required log-pipeline path is now used by the validation-matrix smoke, feed-install smoke, and multi-architecture smoke callers via `--require-log-pipeline`. It fails on firewall-rule setup, traffic generation, log read failure, invalid/non-array row JSON, or zero parsed rows; zero-row reads are retried up to five total attempts with a one-second delay between attempts, and the successful message reports the parsed row count. This records branch/tested validation behavior only; it claims no new live result or security finding.
> **2026-09-22 #453 delta:** `resolve` now reports `"truncated":true` when its lookup-count or wall-clock budget stops before all valid addresses are processed. Completed lookups with no PTR are present as empty-string `names` values so the view can fail-mark them; addresses omitted from `names` stay retryable. Existing no-resolver, load-shed, malformed-input, and per-address lookup contracts are unchanged; no ACL, DOM sink, or read/write-scope change.
> **2026-09-22 #456 delta:** the adaptive reply merger now treats `{}` as an object with an empty member prefix, producing valid JSON when adaptive fields are appended. Existing non-object passthrough and reply-shape behavior is unchanged; no ACL, DOM sink, or read/write-scope change.
> **Last review:** 2026-09-18 delta on #365/#366 behavior-preserving view/rpcd refactors (rules-map dump paths, selftest comparisons, and logging-toggle handler sequencing; host gates green; no ACL, DOM sink, or command-input change); prior 2026-09-16 delta on #347 frozen Auto/Manual fetch-budget contract (validated browser-local discrete values, success-only `effective_limit`, error-path omission, and status text via `textContent`; no ACL change); prior 2026-09-15 delta on #339 weak-device 250-row display cap (server boolean gate, status text via `textContent`, no ACL or HTML-sink change) and candidate browser matrix; prior 2026-09-15 delta on #306 request serialization, filter-failure health gating (structured error-key match and secure sticky-/tmp tempfile), conservative UTF-8 summary bound, and cooldown-expiry probing (no ACL or DOM-sink change); prior 2026-09-15 delta on #306 bounded server summary aggregation (same classifier pass, escaped JSON byte cap, adaptive-off omission) and summary UI (`textContent` only); prior 2026-09-14 delta on accurate `messages_received` counting (filter-side `jsonfilter` enumeration, one awk pass, no duplicate reply key) and Layer 3 weak-device procfs detection (read-only `MemTotal`/processor count, fail-closed boolean, no ACL change); prior 2026-09-13 delta on #306 Layer 2 client backoff (visibility pause, RTT cadence, adaptive/shed banners via `textContent` only; resolve `disabled:load` without treating as DNS fail); prior 2026-09-12 delta on #306 Layer 1 adaptive poll cap (always-on; test/triage override via env/sentinel; state file flock; no UCI); prior 2026-09-11 delta on release-notes pipeline (#322 follow-up); shell-helpers delta same day (#321/#308); full-surface housekeeping review 2026-09-08 (H1 stale branch deleted; H2 Validity checks + Non-provider patterns plan-gated — not available on personal GitHub accounts; tracked upstream in [housekeeping#24](https://github.com/lucas-albers-lz4/housekeeping/issues/24)).
> **Open:** None from #293. Housekeeping may still emit `secret_validity_checks_off` / `secret_nonprovider_patterns_off` as false positives until [housekeeping#24](https://github.com/lucas-albers-lz4/housekeeping/issues/24) lands plan-aware scanning.
> **Next:** On the next `v*` tag, re-check pins and run full docker usign (gap 4). The full surface re-pass is deferred — the gate criteria are not met (skill § Multi-model pass / full-pass gate). Lab gaps 1–3 ran as smoke tests on 2026-09-04 (`./scripts/qemu-security-gaps-smoke.sh` green). The gap 2 flock residual is unchanged.
> **How to verify:** `./scripts/fwlive-test.sh` runs automated host checks. Multi-model pass: [`.cursor/skills/security-audit/SKILL.md`](../../.cursor/skills/security-audit/SKILL.md) § Multi-model pass. Values current as of this PR.

What has been reviewed, when, with what strength of proof, and what is still
open. This document is the **record**; it owns no rules.

| Read this for | Go here |
|---------------|---------|
| What we trust, invariants, ACL scope, supply-chain surface | [security-model.md](security-model.md) |
| How to run a pass (multi-model stages + surface steps) | [`.cursor/skills/security-audit/SKILL.md`](../../.cursor/skills/security-audit/SKILL.md) |
| Whether a surface was checked, and whether a control is *proven* | this file |

Start here before a pass. Do not re-derive the trust boundaries, and do not
reopen an accepted residual without new evidence.

## Review goals

| Goal | Examples in this repo |
|------|------------------------|
| Exploit | Injection, ACL bypass, XSS from log data, privilege escalation |
| Data corruption / availability | Log pipeline failure, lock issues, UCI sweep |
| Supply chain | Unpinned tooling, signing keys, feed trust |

> **2026-09-19 #370 delta:** Host coverage now pins exact rpcd/ACL method parity and read/write isolation, representative reply-shape fixtures, hostile table text under the recording LuCI E harness, fail-closed shell cases, IPv6 PTR parsing, fuzzy PO rejection, and ipk/apk payload layout/modes. The filter accepts an explicit dump directory for host fidelity, while the production rpcd caller passes /tmp; no ACL grant or DOM sink changed.

> **2026-09-21 #370 payload follow-up:** The required per-PR payload job builds and inspects current-version 23.05 IPK, 24.10 IPK, and 25.12 APK artifacts with `FWLIVE_REQUIRE_PACKAGE=1`. The format-aware payload inspector checks shipped modules, ACL/menu files, libexec layout, and executable modes; the lifecycle test executes extracted IPK `prerm-pkg` cases and checks the APK pre-deinstall contract when present, while APK data-only extraction does not execute the APK hook.
>
> **2026-09-23 #557:** The `test-ipk-payload` check still always reports (job id stays required). The three-cell SDK build and `FWLIVE_REQUIRE_PACKAGE=1` inspect run only when packaging-relevant paths change, or when path detection fail-closes (missing/all-zero/unusable base SHA, fetch failure, or diff failure). Host `test` still runs the source-shaped payload/lifecycle inspectors on every PR.
>
> **2026-09-19 #378 Phase 2 delta:** `rules` is nft-only. The `iptables-save` dump path, `IPTABLES_TIMEOUT`, and `__rulesmap_iptables` CLI hook are gone. Detect failure is `unknown`/`no_backend`; a selected nft dump still uses `nft_failed`. Sticky `/tmp`, mktemp fail-closed, timeout, size/key caps, and first-wins dedup are unchanged. No ACL, DOM sink, or LuCI change.

> **2026-09-19 #373 delta:** WAN-zone selection now considers the exact zone name `wan` or effective `network` membership in `wan`/`wan6`, where an omitted network option falls back to the zone name. The first matching zone in firewall config order wins; no-zone replies JSON-escape the discovered zone names. The repository's 25.12-era firewall/network fixtures and lab preparation scripts were also checked for device- or subnet-scoped firewall zones; none appeared, so no device tokens were added to the match set. No ACL, command-input, or DOM-sink change.

> **2026-09-19 #383 delta:** `logging_status` now carries the JSON-escaped no-zone candidate list, and the LuCI empty state and toolbar render candidate names through array-wrapped `E()` text children. Section ids are used as the effective name when UCI omits both `name` and `network`, covered by a host fixture; screenshot fallbacks reject an empty zone id. Lock and finder fixtures now exercise the real zone declarations and no-zone status shape. No ACL or HTML sink change.

> **2026-09-20 #394 delta:** Host tests now pin the exact rpcd read/write method arrays, recursive LuCI sink behavior, hash restoration, deterministic dependency failures, and table formatting. The `q` chip uses its field key for behavior while retaining its display label; no ACL grant or shipped HTML sink change.

> **2026-09-20 #388 delta:** `legacy_iptables_detected` is no longer ubus-only. The view appends one allowlisted `_()` clause to `#fwlive-backend` via `textContent` and warn-tint. Enable CTA, `ready`, and `blockers` are unchanged. Rule links always go to `admin/network/firewall/rules`; the iptables/nftables status-page branches and `using iptables` label are removed. No ACL or HTML sink change.

## Why a ledger and not just a model

`security-model.md` states what must be true. It cannot tell you whether anyone
checked, or how hard they checked. That gap is not theoretical: two entries on
the Known-good list were falsified in the 2026-08-12 pass, both because the
original conclusion came from reading a line of code rather than executing it.
A claim with no proof class attached is a belief.

## Proof classes

Every control carries one. The class is the *weakest* evidence the control
currently rests on.

| Class | Means | Example |
|-------|-------|---------|
| `host` | Asserted by a test in `tests/`, run by `./scripts/fwlive-test.sh` in PR CI | ACL does not grant `ubus log.*` |
| `lab` | Demonstrated against a running QEMU guest | Live ACL enforcement on a real rpcd |
| `manual` | Confirmed by inspection or a one-off run, not re-checked automatically | Anything with no test behind it |

`manual` is not a failure — some things cannot be cheaply automated — but a
`manual` control on a security boundary is a standing invitation to drift, and
should carry a note saying what would raise it.

## Surface coverage map

| Surface | Last reviewed | Depth | Notes |
|---------|---------------|-------|-------|
| Frontend rendering sinks (`E()` string children) | 2026-09-27 | Delta + recording harness | #866/#867 changed table paint/key paths; reviewed dynamic `E()` children and empty-only `innerHTML` clears; `fwlive-e-harness`, `fwlive-table-keyed`, view smoke passed. #907 passes the already computed render key into rebuilt rows; dynamic `E()` children and text-node behavior are unchanged. Last broader hostile-input sweep remains 2026-08-13 (#177) |
| Untrusted-input trace (log fields, PTR, URL hash, UCI) | 2026-09-27 | Delta + host harness | #866/#867 scoped-IP hostname/cache and keyed paints reviewed; hostile log/PTR/hash/chip paths exercised in `fwlive-e-harness`, `fwlive-chips-hash`, and mocked view smoke. Earlier broad UCI trace: #177 (2026-08-13); this was not a new full-source sweep |
| rpcd plugin + ACL scope | 2026-09-27 | Delta + host test + lab | #894 parses anonymous/named UCI rule names from one `uci show` result, caps processing at 512 names, and removes per-section `uci get`; duplicate-name flood test asserts truncation and retained first name. #761 timeout provider unchanged. #768: non-zero filter stdout is kept only when it is a complete shipped `{"log":[],"error":…}` object; truncated bodies become `filter_failed`. #771: `slug_key` / cosmetic prefixes use `printf '%s\\n'`. #827: `resolve` budget uses `fwlive_adaptive_clock_cs` (`/proc/uptime`) against `RESOLVE_BUDGET * 100`; `RESOLVE_MAX` still bounds work if uptime is unreadable. ACL method parity/read-write split and no `ubus log.*` unchanged. #898 peer-drain fractional-sleep fallback and #896 selftest counter reset were checked against the root call path; #900 error-body parity is host-asserted. #416 retains anonymous/named UCI names; #378 remains nft-only. Installed-session enforcement in [#392 evidence](../evidence/issue-392-2026-09-20.md) |
| Shell helpers — injection and quoting | 2026-09-27 | Delta + host test | #898 changes only the peer-drain sleep fallback; positional timeout arguments and filtered stdin remain intact.  #768: `fwlive_adaptive_merge_reply` does not splice adaptive keys into an unclosed JSON array. #771: untrusted prefix/name strings no longer pass through `echo`. #761 GNU timeout arguments remain positional. #365/#366 retain quoted temp paths and `check_eq` behavior |
| Shell helpers — **file modes and lock ownership** | 2026-09-26 | Delta + host test | #869: baseline snapshot rejects symlink/unsafe `/etc/fwlive` dir and adaptive state refuses group/other-writable dirs (`tests/fwlive-logging.test.sh`, `tests/fwlive-adaptive-cap.test.sh`). Earlier lock 0600 and symlink checks: #204/#232 (`tests/fwlive-logging-lock.test.sh` Parts D–F); no new device-mode check in this delta |
| Shell helpers — **uninstall baseline restore (`prerm`)** | 2026-09-27 | Host + dated lab | `/etc/fwlive/wan-log-baseline`; packaged opkg `remove` and APK version-valued `pre-deinstall` restore, while `upgrade`/empty/unknown/`PKG_UPGRADE=1`/`1a2` and non-root staging roots skip (host matrix). Uninstall restoration: [#389 evidence](../evidence/issue-389-2026-09-20.md). A 25.12.5 version-changing APK upgrade preserved the bit/marker and invoked `post-upgrade`, not this `pre-deinstall` hook ([#848 evidence](../evidence/issue-848-2026-09-27.md)) |
| Shell helpers — **UCI commit scope and zone grammar** | 2026-09-26 | Delta + host test | #606 rejects oversized `log`; #663 keeps baseline on failed reload; #869 snapshot checks unsafe directory paths. `tests/fwlive-logging.test.sh` passed on master. Earlier canonical `uci -X` cfg identity/B-1 and installed proof remain separately dated; package-wide commit residual still accepted |
| Release pipeline — secrets and key handling | 2026-08-18 | Reproduced | #177 key-mode re-run; R7 pin-before-mount + `--network none` ([#179](https://github.com/lucas-albers-lz4/fwlive/issues/179)); 2026-08-18 hardening parity + R7 wrapper fix |
| Release pipeline — version pins, fetch pinning and artifact selection | 2026-09-28 | Delta + targeted host tests | #804 via PR #852: SDK validation rejects off-pin versions; #806 maps numeric point-release labels to their major.minor feed line (`tests/sdk-matrix-release-labels.test.sh`, `tests/feed-publish-release-assets.test.sh`); #766 staging deletion guard remains in its 2026-09-26 delta. Issues #811–#814 via PR #864 cover Pages timeouts, SDK probe isolation, trap preservation and explicit build-all filters (`tests/wait-feed-pages.test.sh`, `tests/feed-sdk-wave15.test.sh`). #891 adds exact-label checks for the per-patch index-script pin and installer fallback (`tests/pin-sites.test.sh`). PR #854 (issue #841) and the R7 digest pin-before-secret-mount are recorded above; no live signing/publish or QEMU was run in this pass |
| Workflow inputs into `run:` bodies | 2026-09-27 | Delta + source read | Actions remain SHA-pinned (including `FEED_DEPLOY_KEY`), no expression inserted directly into a `run:` body; dispatch tag still passes via `env:`. This is a source check, not a new tag/publish run |
| LuCI view (templates / shipped JS) | 2026-09-27 | Delta + host / mocked view | #866/#867: scoped-IP display and hostname-keyed row reuse; text-child boundary rechecked in `tests/fwlive-e-harness.test.js` and `tests/fwlive-chips-hash.test.js`. #870–#873 harness assertions improved; `npm run test:view` passed with mocked services. No installed LuCI or new XSS proof is inferred from that smoke |
| Package/install surface (Makefiles, prerm, feed layout) | 2026-09-26 | Delta + built artifacts + lab | #761: unconditional `+coreutils-timeout`; actual 23.05/24.10 IPK and 25.12 APK metadata checked; 24.10.8 opkg upgrade from 0.1.46 to test candidate 0.1.47 auto-installed provider. Existing lifecycle hooks unchanged |
| #370 package payload | 2026-09-23 | Delta + host test | Required `test-ipk-payload` check always reports. Full 23.05 IPK / 24.10 IPK / 25.12 APK SDK build+inspect with `FWLIVE_REQUIRE_PACKAGE=1` runs on packaging-path diffs (and fail-closed detection); host `test` still runs the source-shaped payload/lifecycle inspectors every PR (#557). Inspectors check JS modules, ACL/menu files, libexec layout, executable modes, and packaged lifecycle contracts. IPK `prerm-pkg` cases are executed; APK data-only extraction does not execute the APK hook. |
| #370 installed matrix | 2026-09-21 | Delta + host + lab | #418: `validate_matrix_install_ipk` invokes `qemu-install-fwlive.sh --artifact-only`; the installer removes known source-synced files and force-reinstalls the selected package artifact before the matrix smoke, so this path is intended to exercise installed package files rather than a source-tree overlay. No new live matrix result is claimed in this delta. R8 lifecycle: 24.10.8 armsr IPK uninstall restoration (plus root-SSH `ubus` observations, not session proof), 24.10.8 x86 IPK uninstall, and 25.12.5 APK uninstall in [#389 evidence](../evidence/issue-389-2026-09-20.md); x86/APK same-version reinstall is no-op preservation (#406), not hook proof. R8 is not session-complete: session identity is R4b on 24.10 x86 ([#392 evidence](../evidence/issue-392-2026-09-20.md)); repeating ACL smoke on armsr/apk is not required because the shipped ACL/rpcd object is architecture-independent. R9b is APK control inspection with no retained payload dump. |
| Build inputs (`feeds.lock`, `package-lock.json`) | 2026-09-20 | Read + host test | #411: every `src-git` lock line is a 40-hex commit (`tests/feeds-lock-pins.test.sh`); 23.05 `base` is peeled `v23.05.5`; cache reuse checks HEAD and a clean work tree (including untracked files) |
| Dev tooling (`.cursor/mcp.json`) | 2026-08-23 | Read + fix | #205: unpinned `@playwright/mcp@latest` removed; UI tests use pinned `playwright` devDep |
| Lab deploy helper (`scripts/agent-build-and-deploy.sh`) | 2026-09-03 | Read + fix | #261: SSH host-key verification ON by default; `ALLOW_INSECURE_SSH=1` / `--lab-only` opt-in with warning |
| Lab feed/QEMU lifecycle helpers | 2026-09-28 | Delta + host/stub tests | #957: documents the `iproute2`/`ss` host prerequisite; both port-check helpers report an install hint when `ss` is missing and fail closed on errors. QEMU validation entry points preflight `ss` before baseline checks, SDK builds, image downloads, or preparation. #925: readiness uses a read-only SSH probe, caps connect timeout and sleep to remaining `MAX_WAIT`, and wraps the full SSH process in a wall-clock timeout; optional `--cmd` runs once with a separately recomputed connection timeout/status marker. `tests/qemu-wait-guest-feed-smoke.test.sh` covers hung probes and SSH/sleep stubs; no guest-side QEMU result or SSH trust change is claimed. #854/#857/#862/#863: URL validation/remote env quoting, source replacement, PID-owned stop, port/liveness checks and teardown; host lifecycle tests passed |
| Lab honest-gap smokes | 2026-09-04 | Lab smoke | `scripts/qemu-security-gaps-smoke.sh` gaps 1–3 green 2026-09-04; gap-2 BusyBox `flock` (no `-w`) accepted residual; `tests/validate-feed-keys-mode.test.sh` (gap 4 validate-prefix → `host`) |

## Controls in force

| Control | Proof class | Where |
|---------|-------------|-------|
| Sessions never receive `ubus log.*` | `host` | `tests/fwlive-rpcd-security.test.js` |
| Authenticated LuCI/uhttpd grant session can call all six fwlive methods and cannot call `log.read`; deny session (`luci-base` only) is allowed `file.list` then sampled on `logging_status` and `enable_wan_logging` | `lab` | `scripts/qemu-acl-session-smoke.sh`; [#392 installed-session artifact](../evidence/issue-392-2026-09-20.md) |
| Lab `.ipk` deploy keeps SSH host-key verification unless explicitly opted in | `manual` | `scripts/agent-build-and-deploy.sh` — default empty `SSH_OPTS`; `ALLOW_INSECURE_SSH=1` or `--lab-only` required for `StrictHostKeyChecking=no` (#261) |
| Read and write ACL scopes stay separate | `host` | `tests/fwlive-rpcd-security.test.js` `testAclMethodParity` |
| Caller line count validated and clamped | `host` | rpcd `__selftest` |
| Poll line-count clamp rejects over-long digit strings before numeric compare (no silenced `test` overflow) and maps `0`→50 | `host` | rpcd `poll_clamp_lines` helper + `__selftest` (over-long, zero, 2001, 500) — defence-in-depth for read-ACL reachable `poll` |
| Addresses shape-validated before `nslookup` | `host` | rpcd `__selftest`, incl. a literal `$(reboot)` token |
| Missing `nslookup` surfaces `error:no_resolver` (not silent empty names) | `host` | `tests/fwlive-rules-map.test.js` `testResolveNslookup` |
| `json_escape` is defined in `fwlive-logging.sh` (prerm standalone) | `host` | `tests/fwlive-logging.test.sh` type check; rpcd `__selftest` |
| Anonymous and named UCI rule names are mapped without word-splitting; missing UCI/name is non-fatal | `host` | `tests/fwlive-rules-map.test.js` `testUciStreamMergeAndCollision` covers named-section lookup and first-wins merge; `testUciWhitespaceNames` covers whitespace filtering |
| `jsonfilter` declared; missing filter exits non-zero with `error` | `host` | Makefile `LUCI_DEPENDS`; `tests/fwlive-shell-filter.test.js` `runMissingJsonfilter` |
| Generated classifier asset is required; missing asset exits non-zero with `classifier_missing` instead of silently filtering everything out | `host` | `tests/fwlive-shell-filter.test.js` `runMissingClassifier`; codegen freshness covers the `.awk` asset |
| GitHub Release normal-path body is the CHANGELOG section; missing-section fallback is `--generate-notes` with a loud warning (body may be sparse — fold before tagging) | `host` | `feed_publish_release_notes_file` in `scripts/lib/feed-publish.sh`; `tests/feed-publish-release-assets.test.sh` notes assertions; `publish_new` warn on fallback |
| JSON filter unescapes libubox string escapes (`\b` `\f` `\n` `\r` `\t` `\u00XX`) before classify | `host` | `tests/fwlive-shell-filter.test.js` `runJsonGetMsgEscapes` / `runJsonParity` |
| JSON string content escaped per RFC 8259 | `host` | rpcd `__selftest` |
| WAN log toggle serialized against concurrent callers | `host` | `tests/fwlive-logging-lock.test.sh` (32-trial race) |
| Reload failure rolls back the UCI write; restore returns non-zero if `uci set`/`uci delete` never staged | `host` | `tests/fwlive-logging.test.sh` |
| `resolve` stops starting lookups at its wall-clock budget and allows only the in-flight lookup plus TERM/KILL grace | `host` | `tests/fwlive-rpcd-security.test.js` `testResolveLoopBudgetIncludesFinalKillGrace`; host uses GNU timeout and matched 24.10 jshn/BusyBox shell |
| `poll` bounded by `POLL_LINES_MAX` | `host` | rpcd `__selftest` (clamp helper tested without jshn) |
| Rules map temp file created only via `mktemp` (`_fwlive_mktemp`, fixed `/tmp` after a sticky-dir check, `TMPDIR` NOT honoured, no `rm`+reuse) with graceful degradation; accumulation via redirect keeps global first-wins dedup | `host` | `tests/fwlive-rules-map.test.js` production-path stubs under `dash` (and `busybox sh` when BusyBox honours PATH); `testNoMktempGracefulDegradation`; `testTmpDirSticky` |
| Rules map has no predictable-path write (no `$$` fallback); `>` follows a symlink if one is there, so safety is the unpredictable mktemp name plus a verified sticky `/tmp` | `host` | `tests/fwlive-rules-map.test.js` `testNoMktempGracefulDegradation` (mktemp shadowed, a unique fixture prefix asserts no new test-scoped temp file of any content; would catch a predictable `$$` fallback); `testTmpDirSticky` |
| Rules map emits each key at most once (global first-wins in `map_add`, plus slug==raw skip) | `host` | same test — raw JSON duplicate-key assertion |
| `/tmp` used for ruleset dumps is a real directory with the sticky bit (fail closed; POSIX `[ -k ]`, no `stat`) | `host` | `_fwlive_tmp_dir_ok`; `tests/fwlive-rules-map.test.js` `testTmpDirSticky` |
| Every `E()` string child is array-wrapped | `host` | rendering harness ([#138](https://github.com/lucas-albers-lz4/fwlive/issues/138)) |
| Actions SHA-pinned, including the step receiving `FEED_DEPLOY_KEY` | `manual` | `.github/workflows/publish-packages.yml` — `peaceiris/actions-gh-pages@84c30a85c…` = `v4.1.0` (verified 2026-08-13); CodeQL alert 7 closed as **fixed**; re-check before each `v*` tag ([#178](https://github.com/lucas-albers-lz4/fwlive/issues/178)) |
| SDK image digest-pinned at first **secret-touching** pull | `host` | `sdk_matrix_pull_and_pin` in `validate-feed-keys.sh`; `feed_publish_apply_sdk_pin` before opkg/apk sign; `tests/sdk-matrix-digests.test.sh` |
| Signing-secret containers have no network | `host` | `docker run --network none` on validate usign check and opkg/apk sign steps (Compose v2 has no `--network` on `compose run`); same test |
| Signing secrets stay 0600 through validate-feed-keys rewrite prefix (decode/normalize/chmod) | `host` | `tests/validate-feed-keys-mode.test.sh` — calls shared `feed_keys_validate_*_rewrite_prefix` (same helpers as `validate-feed-keys.sh`) including a base64 decode rewrite; full docker usign sign on next `v*` still prove-next |
| `ipkg-make-index.sh` pinned to a commit SHA and sha256-verified | `manual` | `feed_publish_ipkg_index_script` |
| Only public keys reach `feed-staging/`; both opkg and apk public keys are required | `host` | `feed_publish_copy_keys`; `tests/feed-publish-copy-keys.test.sh` |
| Packages index filtering has no `|| true` on either host or SDK path | `host` | `tests/feed-publish-copy-keys.test.sh` source-shape assertions count two filters and reject a swallowed status. The stronger claim that injected grep I/O failure aborts both publishing paths is only `manual` (source inspection); no behavioral fault-injection or live signing proof was found. |
| Publish staging `rm -rf` refuses `/`, `$HOME`, repo root, and paths outside `$ROOT`/`$RUNNER_TEMP` unless `--allow-outside` (which still refuses `/`/`$HOME`/root); path is `pwd -P` so a symlink to `/` cannot bypass | `host` | `feed_publish_assert_staging_clearable` in `scripts/lib/feed-publish.sh`; `tests/feed-publish-staging-guard.test.sh` |
| Signing secrets are mode 0600 | `host` | `tests/feed-keys-mode.test.sh` — both storage formats under umask 022 |
| Fetched build helpers verified before execution | `host` | `tests/fetch-pin-gate.test.sh` — usign commit-pinned; `get-sdk.sh` sha256-verified |
| Publish job runs under Environment `feed-publish` | `manual` | `.github/workflows/publish-packages.yml` `environment:` — organizational gate (protection rules optional; none configured, matching usrmanage). Does NOT scope repo-level secrets — keys stay repository-scoped by design |
| Checkout never writes GITHUB_TOKEN into `.git/config` | `host` | `persist-credentials: false` on every checkout in `publish-packages.yml` (workspace is bind-mounted into SDK) and `fwlive-test.yml`; `tests/ci-workflow-pins.test.sh` |
| Publish `build-publish` lint gate runs under Node 22 | `host` | digest-pinned `actions/setup-node` before `validate-baseline.sh`; `tests/ci-workflow-pins.test.sh` |
| workflow_dispatch tag validated before `GITHUB_ENV` write | `manual` | same workflow — newline/control-char rejection + `^v[0-9]` shape |
| SDK feed cache key is exact (no `restore-keys` prefix fallback) | `manual` | same workflow — stale feed pins cannot be restored on cache miss |
| SDK cache dirs owned by buildbot (1000:1000), owner-write + group/other read-traverse; enforced fail-closed pre-build (skipped only when CI pre-chowned both trees, roots AND nested entries; scan errors fail closed) | `host` | `tests/sdk-matrix-cache-owner.test.sh` — #208 (v0.1.36 chown regression) |
| WAN toggle changes only the zone `log` bit | `host` | `tests/fwlive-logging.test.sh` — pending-delta refuse; named + anonymous zone lookup |
| WAN-zone lookup accepts exact `name=wan` or effective `network=wan`/`wan6`, preserves config order, and reports discovered zone names when no supported zone matches | `host` | `tests/fwlive-logging.test.sh` #373 scalar/list/renamed/duplicate/wan6/omitted-name/no-match fixtures; `logging_status.wan_zone_candidates`; LuCI empty-state and toolbar candidate text-node harness; qemu helpers consume `logging_status.wan_zone` |
| WAN zone identity for staged `uci changes` uses canonical cfg ids (`uci -X`), not class-match on `name=wan` | `host` | `uci_canonical_firewall_section` + `wan_firewall_zone_same`; B-1 duplicate-wan foreign `.log` stays foreign (`tests/fwlive-logging.test.sh`) |
| Uninstall restores WAN `log` from pre-first-enable baseline | `host` | `tests/fwlive-logging.test.sh` — baseline snapshot/restore; `scripts/qemu-logging-uninstall-smoke.sh` (`lab`) |
| The WAN logging lock cannot be held by an unprivileged user | `host` | `tests/fwlive-logging-lock.test.sh` Part D — create+tighten to 0600 |
| Lock path rejects symlinks before truncate/chmod/chown | `host` | `tests/fwlive-logging-lock.test.sh` Part E — #204 |
| Production lock dir check works without `stat -c` (BusyBox `STAT=n`) | `host` | `wan_log_lock_dir_safe`: `[ -O ]` + `find -prune -perm`; Part F shadows `stat` |
| Rules map prefers `!fw4:` labels over earlier cosmetics for the same prefix (UCI still first-wins) | `host` | labeled-then-unlabeled passes; `tests/fwlive-rules-map.test.js` `testFw4LabeledBeatsCosmetic` |
| `nft list ruleset` bounded by `NFT_TIMEOUT`; rules map key/byte capped | `host` | `testRulesMapKeyBound`, `testRulesMapByteBound` |
| mktemp-skip on rules map surfaces `error:mktemp_failed` | `host` | `testNoMktempGracefulDegradation` |
| `rules` dump failure surfaces `error:no_backend`, never a silent empty map | `host` | `tests/fwlive-rpcd-security.test.js` `testRulesNftDumpFailure` |
| `rules` is nft-only: missing nft or a failed detect dump is `unknown`/`no_backend`; `iptables-save` on PATH is not invoked | `host` | same file `testRulesNoBackend` / `testRulesNoIptablesFallback` |
| Dead `logd` on `poll` returns `error:log_read_failed`, not an empty table | `host` | same file `testPollUbusFailure` |
| Adaptive poll cap always on; no UCI; disable only via `FWLIVE_ADAPTIVE=0` or sentinel next to state under `/var/run` (not world-writable `/tmp`) | `host` | `tests/fwlive-adaptive-cap.test.sh`; reply carries `adaptive` |
| Adaptive poll replies add `effective_limit` only for successful adaptive responses; all six filter/read error paths omit it and preserve accurate `messages_received` without duplicate keys | `host` | `fwlive_adaptive_merge_reply` success flag; `tests/fwlive-adaptive-cap.test.sh`; `tests/fwlive-rpcd-security.test.js` |
| Non-zero filter stdout is kept only as a complete shipped error object; truncated bodies become `error:filter_failed` valid JSON | `host` | `fetch_firewall_logs` allow-list; `tests/fwlive-rpcd-security.test.js` `testPollTruncatedFilterBodyIsFilterFailed`; `tests/fwlive-adaptive-cap.test.sh` truncated merge_reply vectors |
| Untrusted rules-map prefix/name strings use `printf '%s\\n'`; `-n`/`-E` unlabeled prefixes stay hints | `host` | `slug_key` / `map_prefix_with_label`; `tests/fwlive-rules-map.test.js` `testDashFlagUnlabeledPrefix`; rpcd selftest |
| `resolve` wall-clock budget uses `/proc/uptime` centiseconds; a backward `date` step cannot stretch the loop | `host` | `fwlive_adaptive_clock_cs`; `tests/fwlive-rpcd-security.test.js` `testResolveBudgetIgnoresDateJump` |
| Adaptive state at `/var/run/fwlive-state.json` — owner/dir checks, atomic rename, non-blocking `flock -n` on sibling `.lock` (fail-open; release by closing fd; busy ⇒ last-writer-wins; lock created 0600), never `source`/`eval` | `host` | same; lock only around short update, never across ubus/filter |
| Hot shed surfaces `shed` + `truncated`; `resolve` returns `disabled:load` when previous poll was hot; failed `log.read` or filter/classifier output does not clear prior bucket; expired hot/warm cooldown probes upward and retains only healthy recovery | `host` | `tests/fwlive-rpcd-security.test.js` `testAdaptiveHotSurvivesFailedPoll` / `testAdaptiveHotSurvivesFilterFailures`; `tests/fwlive-adaptive-cap.test.sh` deterministic cooldown vectors |
| Forwarding-SLO lab topology owns only `fwlive-slo-*` network namespaces, bridges, TAPs, and veths; teardown validates the prefix before removing them; setup rollback is prefix-scoped; no shipped surface or runtime ACL is changed | `host + manual` | `scripts/qemu-forwarding-slo-net.sh` / `scripts/lib/qemu-forwarding-slo-net.sh`; static shell checks cover names/MAC/model and manual lab verification covers setup/rollback/teardown in #344 |
| Forwarding-SLO guest helper resolves a unique interface by caller-supplied MAC, snapshots/restores test-link and IPv4-forwarding state, uses fixed temporary forwarding/logging rule comments, validates all four rules, validates rule handles as digits during cleanup, and changes no shipped package or ACL | `host + manual` | `scripts/qemu-forwarding-slo-guest.sh`; shell syntax/ShellCheck plus manual armsr/x86 verification in #344 |
| Forwarding-SLO traffic probe requires root-owned named namespaces, validates positive bounded duration/count inputs and a safe label, uses an absolute `iperf3` path, verifies protected temporary-parent ownership, and emits measurements without changing runtime state | `host + manual` | `scripts/qemu-forwarding-slo-traffic.sh`; shell syntax/ShellCheck plus routed `iperf3`/ping probe in #344 |
| Forwarding-SLO paired runner scopes and restores the adaptive sentinel, uses a separate local Playwright worker with traffic-bound marker-file IPC, tracks requests through completion, requires successful drained viewer requests, and atomically publishes caller-selected reports | `host + manual` | `scripts/qemu-forwarding-slo-run.sh`, `tests/fwlive-forwarding-slo-viewer.mjs`, `tests/lib/fwlive-forwarding-slo-report.mjs`; shell syntax/ShellCheck/Node behavioral checks plus manual paired runs in #344 |
| Adaptive poll reply carries accurate `messages_received` (all entries enumerated by `jsonfilter`, before firewall classification); failed reads fall back to `0` | `host` | `tests/fwlive-shell-filter.test.js`, `tests/fwlive-rpcd-security.test.js`, and adaptive merge test |
| Adaptive summary is same-pass, top-of-shown-sample data; values are JSON-escaped and bounded to ≤1 KiB, and adaptive-off omits it | `host` | `tests/fwlive-shell-filter.test.js` `runSummaryContract`; generated classifier + rpcd gate |
| Layer 2 client backoff: visibility pause, RTT cadence, adaptive/shed banners; resolve honors `disabled:load` with a 60s retry cooldown | `host` | `tests/fwlive-view-layer2-backoff.test.js`; banners via `textContent` only (`#fwlive-adaptive`) |
| Weak-device row rendering is capped at 250 rows while stronger devices retain the selected Limit; cap notice is text-only and uses the server's strict boolean | `host` | `tests/fwlive-view-layer2-backoff.test.js` `testWeakDeviceDisplayCap`; browser matrix in #339 |
| Auto/Manual fetch-budget values are validated against a bounded client option set, URL/localStorage state is cosmetic and does not widen ACLs, and budget/effective-limit status is rendered with text nodes | `host` | `tests/fwlive-view-fetch-budget.test.js`; source-to-POT/i18n gates; `view/status/fwlive.js` |
| Empty filter output on `poll` returns `error:filter_empty` | `manual` | Source inspection of the guard in `fetch_firewall_logs`; the shipped filter normally prints `{"log":[…]}`. No fault-injection test drives a zero-exit empty filter through the production rpcd entry point, so this is not `host` proof. Promote only with a focused test of that path. |
| `resolve` without `jshn` / with malformed input returns `error:jshn_missing` / `error:invalid_input` | `host` | same file `testResolveJshnMissing`; `invalid_input` runs only where `jshn` exists (skips on stock hosts). UI keeps the full resolve reply (no `expect` unwrap) so `disabled:load` / `error` siblings reach the view (#306 Layer 2). |
| `logging_status` always returns the full 10-key shape; failures travel as `blockers`/`warnings` with `ready:false`, never a silent empty object | `host` | same file `testLoggingStatusNeverSilent`; #378 `legacy_iptables_detected` warning uses fixtureable procfs table-name probes and remains diagnostic-only |
| `nf_log` readiness is backend-aware and family-aware: empty/`NONE` selectors block a present family, while an independently unavailable IPv6 family is effective-ready | `host` | `tests/fwlive-logging.test.sh` #371 backend matrix through status/enable, `/proc/net/if_inet6` fixtures, dual-ready and IPv4-`NONE` gates; enable asserts `ok:true` on a stubbed lock. #384 QEMU device check on 24.10.8 / 25.12.5 (lab note below); proof class stays `host` for the fixtures |
| `logging_status.weak_device` is a read-only procfs-derived boolean (`MemTotal < 256 MiB` or one processor); unavailable/malformed procfs fails closed to `false` | `host` | `tests/fwlive-logging.test.sh` fixture threshold cases + `tests/fwlive-rpcd-security.test.js` shape/type assertion |
| `enable/disable_wan_logging` with no WAN zone return `error:no_wan_zone` before touching the lock | `host` | same file `testToggleNoWanZone` (asserts lock file untouched) |
| Unknown rpcd method returns `error` with a non-zero exit | `host` | same file `testUnknownMethod` |
| Missing `timeout` stays non-gating for WAN logging, while poll/rules/resolve identify the incomplete runtime and skip provider commands | `host + package + qemu` | `tests/fwlive-logging.test.sh`, `tests/fwlive-rpcd-security.test.js` `testTimeoutMissingIsDistinctAndSkipsCommands`, view poll-error tests; package metadata tests; 24.10.8 provider removal/restore lab. Resolve error does not populate hostname negative cache |
| Rules-map degradation (`rules_truncated`/`mktemp_failed`/`rules_unavailable`) surfaces in `#fwlive-backend` span, not the live counter / paused class | `host` | `view/status/fwlive.js` `updateBackendUi` (backend label + ` · ` + error via `_()`), `updateStatus` always reaches counter branch; `lastPollError` precedence unchanged |
| `resolveRuleLabel` reads only own string `rulesMap` keys; prototype names fall back to `formatRuleLabel` | `host` | `tests/fwlive-view-poll-error.test.js` `testConstructorHintDoesNotPaintObjectSource` |
| URL-hash filter restore uses `setFilterFieldValue` so unlisted SELECT values stay selected | `host` | `tests/fwlive-chips-hash.test.js` `testApplyHashUnlistedActionStaysSelected` |

| Filter temp directory | host | Real, non-symlink, sticky dump directory is required before root writes; tests exercise non-sticky fixtures under dash and BusyBox ash, while production passes /tmp |

## Open findings

| ID | Severity | Issue | Summary |
|----|----------|-------|---------|

## Verified findings (closed in this ledger)

| ID | Severity | Issue | Summary | Verified |
|----|----------|-------|---------|----------|
| B-1 | Low | `wan_firewall_zone_same` class-matched any `name=wan` zone | Canonical `uci -X` cfg id compare; duplicate wan `.log` stays foreign | 2026-09-03 — multi-model audit |
| [#204](https://github.com/lucas-albers-lz4/fwlive/issues/204) | Low | Predictable lock path opened O_TRUNC without symlink check | Lock under `/etc/fwlive/`; `acquire_wan_log_lock` rejects `-L` before create/tighten/open; Part E | 2026-08-23 — security-audit PR |
| [#205](https://github.com/lucas-albers-lz4/fwlive/issues/205) | Low | Unpinned `@playwright/mcp@latest` in `.cursor/mcp.json` | MCP entry removed; tests use pinned `playwright@1.60.0` | 2026-08-23 — security-audit PR |
| [#190](https://github.com/lucas-albers-lz4/fwlive/issues/190) | Low | `is_resolvable_address` hostname-shaped tokens | Strict IPv4/IPv6 validation + selftest cases | merged 2026-08-21 |
| [#191](https://github.com/lucas-albers-lz4/fwlive/issues/191) | Low | `uci commit firewall` foreign-delta sweep | Pre/post-stage gates + post-commit verification; residual window documented | merged 2026-08-23 |


## Accepted residuals

Known, judged acceptable. Reopen only with new evidence.

| Residual | Why accepted |
|----------|--------------|
| Any local UID can inject syslog lines that pass the firewall classifier | `logd` chmods its socket 0666 upstream (ubox `log/syslog.c`). Not fixable from this package; the consequence is forged rows in the view, and every field is already rendered as text |
| `/proc/uptime` unreadable during `resolve` prints 0 elapsed, so the budget check never trips | `RESOLVE_MAX` still bounds the number of lookups; the call cannot run to `RESOLVE_MAX × RESOLVE_TIMEOUT` only if uptime is missing for the whole call |
| A LuCI admin session is root-equivalent | Structural to LuCI. It is the reason script execution on this page is treated as a root compromise, not a lesser bug |
| `uci commit firewall` is package-wide ([#191](https://github.com/lucas-albers-lz4/fwlive/issues/191) residual) | OpenWrt has no option-scoped commit. Pre/post-stage gates refuse when foreign staging is visible. A second privileged writer can still stage in the short interval before commit and publish those changes in the same `uci commit` — two root processes publishing each other's already-staged work. Unprivileged staging is blocked by libuci dir modes. Reopen only with an unprivileged or cross-session path. |
| `feed_publish_ensure_usign` leaves its build dir for the process lifetime | `PATH` points into it and `usign` is called later; the name is unpredictable per invocation, and `/tmp` is reaped on reboot |

## What this pass could not prove

Honest gaps, so the next pass starts here rather than rediscovering them.
Lab runner: `./scripts/qemu-security-gaps-smoke.sh` (gaps 1–3). Host validate
path: `tests/validate-feed-keys-mode.test.sh` (gap 4 prefix; wired into
`./scripts/fwlive-test.sh`).

| Property | Status | What would prove it |
|----------|--------|---------------------|
| `resolve` budget under loaded-router scheduling / blackhole DNS | host fault injection proves `budget + one in-flight lookup + TERM/KILL grace + integer-second clock slack`; lab smoke 2026-09-04 proves responsiveness only, not loaded-router scheduling | Run blackhole-DNS timing under a loaded QEMU/router if that latency envelope needs stronger evidence |
| The rpcd script timeout actually bounds a blocked `flock` waiter | lab smoke 2026-09-04; BusyBox has no `flock -w` (**accepted residual** — client timed out, residual holds) | Host-side timeout fired; does not promote residual to cleared |
| Pre-stage `firewall_changes_pending` refuse on a live device | lab smoke 2026-09-04 (**accepted residual** for package-commit publish of foreign staging — see above) | Foreign staging refused; foreign delta neither committed nor dropped |
| Signing keys stay 0600 through validate rewrite path | `host` (validate-prefix) | `tests/validate-feed-keys-mode.test.sh` — write + shared `feed_keys_validate_*_rewrite_prefix` (decode/normalize/chmod; base64 branch). **Full usign docker sign + real publish** still prove-next on next `v*` tag |
| Current master (`73a7a6a2f5`) on an installed router | This pass ran host tests and mocked LuCI view only; `__selftest` on the plain host explicitly skipped the jshn subcase (the separate matched BusyBox/jshn gate passed for 23.05/24.10/25.12) | Run a focused package-installed QEMU smoke if the new #854/#863 lab paths or #866/#867 browser paint behavior need installed-boundary evidence; do not relabel host stubs as lab |
| Real OpenWrt `jsonfilter` on the current classifier fixture set | `fwlive-shell-filter` and corpus tests reported a restricted Node jsonfilter stub for this host; matched jshn tests are a different dependency seam | Run the filter parity/corpus tests with actual OpenWrt jsonfilter or on an installed guest before claiming that dependency's parity |
| Grep I/O failure in both opkg index paths | Source-shape host test proves `|| true` is absent but does not inject grep failure or execute the SDK signing container | Add a fault-injection test that makes grep exit >1 or its output fail and asserts publishing aborts before signing; exercise the SDK path if that is the claimed boundary |

## Review procedure

The *how* lives in
[`.cursor/skills/security-audit/SKILL.md`](../../.cursor/skills/security-audit/SKILL.md)
(including § Multi-model pass for gaps → delta → gated full pass).
This section covers only what a pass owes this file.

A pass is not finished until it has:

1. Updated the coverage map dates for every surface it actually looked at — and
   left the others alone. A date that means "someone glanced at it" is worse
   than a stale one.
2. Given every new control a proof class, and downgraded any existing control
   whose proof it could not locate.
3. Filed each finding as its own issue at implementable quality — mechanism,
   location, blast radius, fix sketch, re-verification — and linked it here.
4. Recorded its non-findings. A surface examined and found clean is a result;
   without it the next pass pays for the same reading twice.
5. Corrected any claim it falsified, in the document that **owns** the claim,
   in the same PR. A ledger that contradicts `security-model.md` is worse than
   either one alone.

A feature PR touching the rpcd plugin, the ACL, the shell helpers, or the
release pipeline updates this file in the same PR.

## Rules this repo adopted after being bitten

Each earned by a real finding. They are cheap to apply and they generalize past
the specific bug.

### 1. A control that names a file mode needs a `stat` assertion

Reading `chmod 600` proves the call exists, not that the mode survives to the
end of the function. S1 sat behind a literal `chmod 600` that a later `mv`
undid, and it was on the Known-good list. If a control says "0600", a test says
`stat -c %a`.

### 2. Fix the class, not the site

S2 exists because [#131](https://github.com/lucas-albers-lz4/fwlive/issues/131)
pinned one fetched helper and left its neighbour — twenty lines apart in the
same file — unpinned. When a finding is an instance of a pattern, grep for the
pattern before closing it, and record the sweep in the issue.

### 3. Ask the platform; never re-implement its grammar

S4's zone lookup and the parser divergence in the sibling repo
([usrmanage#108](https://github.com/lucas-albers-lz4/usrmanage/issues/108)) are
the same bug: an ad-hoc regex over a platform format, narrower than the real
parser, deciding something that matters. Call `uci`/`nslookup`/`fw4`, or fail
closed on input the pattern cannot fully model.

### 4. Verify against upstream source, not against our own documentation

Every 2026-08-12 finding came from checking OpenWrt sources — `rpcd/uci.c` for
per-session save directories, `uci.h` for `UCI_DIRMODE`, `flock(2)` for locking
on read-only descriptors. Two of them also *reduced* a severity we would
otherwise have overstated. Our docs are a summary of a past reading; upstream is
the fact.

## Audit history

### 2026-09-28 — #891/#923/#893 release/feed consistency

**Scope.** The point-release checklist and its per-patch helper/fallback sites;
the unused `release_patch` assignment in `validate_matrix_run_cell`; and the
release-pipeline ledger trail for #852. #804/#806 were fixed by #852 but had
not been named in the ledger; #766's staging deletion guard already has its
own dated entry. The 2026-09-27 note already recorded PR #854 (issue #841)
and PR #864; this pass adds the explicit #811–#814 issue references and fills
the #804/#806 gap.

**Method.** Read `sdk_matrix_validate_version`, `feed_publish_line_key`, the
per-patch `ipkg-make-index.sh` case, the QEMU installer fallback, and their
focused tests. `tests/sdk-matrix-release-labels.test.sh`,
`tests/feed-publish-release-assets.test.sh`,
`tests/feed-publish-staging-guard.test.sh`, `tests/feed-sdk-wave15.test.sh`,
`tests/wait-feed-pages.test.sh`, `tests/feed-keys-mode.test.sh`, and the new
`tests/pin-sites.test.sh` provide host validation. Checked key-file ignore
rules, found no fixed `.tmp` secret writes, and reviewed release helper/workflow
neighbors for secret staging and SHA-pinned actions; no live publish or QEMU
run was performed.

**Non-findings.** `sdk_matrix_validate_version` rejects off-pin versions before
SDK selection, while `feed_publish_line_key` intentionally maps numeric
off-pin labels such as `24.10.9` to the `24.10` feed line; malformed feed
labels fail closed. Removing the unused `release_patch` local does not alter
cell behavior. The new parity test covers only the per-patch index helper and
installer fallback; the other checklist entries remain manual checks. No
signing-key, ACL, DOM-sink, or read/write-scope change is introduced.

**Result.** The #852 release-label controls and #891 omitted call sites are
now traceable in the ledger and point-release checklist. Proof remains `host`
for tests and `manual` for the remaining pin-site review; no release or lab
result is claimed.

### 2026-09-28 — #957 QEMU lab `iproute2` prerequisite

**Scope.** Host port checks in `scripts/lib/qemu-lab-net.sh`, QEMU validation
preflights in `scripts/lib/validate-matrix.sh` and the validation entry points,
plus the two lab documentation entry points. The checks now explain that `ss`
comes from `iproute2` and give the Mint/Ubuntu install command.

**Method.** Read both port-check call paths and the matrix callers. ShellCheck
and the host port-check CI job provide the validation gates for this change;
no live QEMU host was used in this delta.

**Non-findings.** Invalid ports, missing `ss`, `ss` errors, and occupied ports
still stop the operation. The patch does not change which ports are checked,
the bind address, or QEMU startup behavior when checks succeed. No new command
input, network binding, or trust boundary is introduced.

**Result.** The port checks remain fail-closed, with an actionable prerequisite
message for unsupported hosts. Proof class remains `host`; no live lab result
is claimed.

### 2026-09-27 — #925 bounded QEMU guest readiness wait

**Scope.** `scripts/qemu-wait-guest.sh` readiness and optional `--cmd`
execution. The retry loop now uses the fixed read-only `echo READY` probe,
limits each SSH `ConnectTimeout` and post-failure sleep to the remaining
`MAX_WAIT`, and wraps the full SSH probe process in a wall-clock timeout. It
runs a caller-provided command only once after readiness, recomputing that
connection's timeout from the remaining budget. The remote command runs
through a quoted `sh -c` argument and returns its status through a
per-invocation marker; SSH failures after readiness report that the command
may have run and are not retried.

**Method.** `tests/qemu-wait-guest-feed-smoke.test.sh` covers bounded timeout
and sleep, a probe that connects but hangs, recomputed command connection
timeout after probe delay, nonzero remote command results including exit 255,
a post-probe transport failure, and missing status-marker handling. Shell
syntax and ShellCheck pass. No live QEMU guest was used. Documented `--cmd`
usage is read-only (`uname -r`); the matrix caller supplies no command.

**Non-findings.** The fixed readiness probe does not interpolate caller input.
The optional command remains explicit operator input, quoted as one `sh -c`
argument, and is not retried after transport loss. This change adds no SSH
credential source, ACL grant, rpcd method, or frontend sink. Existing disabled
host-key checking is unchanged and was not revalidated as a trust control.

**Result.** The SSH readiness probe and retry sleeps stay within the configured
wait budget to shell-second precision. The optional command starts only after
readiness succeeds, runs once, and may take as long as the remote command
itself; command execution is outside the readiness wait budget. Failed
commands are reported as command failures and are not replayed. No new trust
boundary, SSH credential, or privileged command source is introduced; the
optional command remains explicit operator input. No QEMU behavior or host-key
verification result is inferred from the stubs.

### 2026-09-27 — #894 bounded UCI rule-name map

**Scope.** The rpcd rules map's UCI name enumeration. `uci_rule_names()` now
parses named and anonymous names from one `uci -q show firewall` result,
emits at most `RULES_MAP_MAX_LINES` names, and returns an explicit status when
that line cap is reached. `map_uci_rule_names()` retains the emitted names,
sets the existing truncation signal, and stops map processing at the output
cap. Per-section `uci get` subprocesses are removed.

**Method.** `tests/fwlive-rules-map.test.js` passed across available POSIX
shells, including a 600-section duplicate-name flood that verifies
`rules_truncated`, retention of the first name, and exactly one UCI show
call. `tests/fwlive-rpcd-security.test.js` and `./scripts/fwlive-shellcheck.sh`
passed. `__selftest` exited successfully but skipped its `jshn`-dependent poll
cap check because `jshn` is unavailable in this host environment.
`./scripts/validate-baseline.sh` passed from the clean feature commit; the
upstream-cut subtest explicitly skipped fresh msgid parity because
`i18n-scan.pl` is unavailable. Its three-version jshn compatibility harness
passed.

**Result.** This bounds duplicate-name work in the map and removes the
per-section process multiplier. The named and anonymous rule mapping behavior
is retained. No ACL or read/write-scope change; sessions still do not receive
`ubus log.read`. This is a resource-bounding fix, not a newly identified
security finding. No QEMU result is claimed.

### 2026-09-27 — Post-#869 security delta, master `73a7a6a2f5`
Tracking: [#877](https://github.com/lucas-albers-lz4/fwlive/issues/877).

**Scope.** Changes after the last ledger commit (`ce59e04a19`): #870–#874 are tests, runner, docs and generated comments. Also checked the still-unmapped #854/#857/#862–#867 lab/release/view deltas against the already-recorded #850–#869 controls. No new method/ACL scope or root command-input surface was introduced by the post-#869 commits.

**Method.** `./scripts/fwlive-test.sh`, `./scripts/fwlive-shellcheck.sh`, `npm run test:view`, `node tests/fwlive-e-harness.test.js`, `node tests/fwlive-rpcd-security.test.js`, and rpcd `__selftest` passed on this revision. Reviewed changed renderer/data-flow paths and the recording `E()` harness; inspected shell/ACL and release-workflow greps, key ignore rules, and pin/secret-mount neighbours. The host selftest skipped its unconfigured jshn case; the required matched BusyBox/jshn compatibility tests passed separately. The normal filter tests used a restricted jsonfilter stub. There was no QEMU, real feed signing, or fresh upstream-source pin check; this session has no multi-model/subagent tools, so no independent validation panel was run.

**Non-findings.** No dynamic non-empty `innerHTML` writes in the changed view paths; bare `E()` identifiers in the grep are an array, DOM node, or node list. The hostile hash/chip/table tests and view smoke passed. The rpcd ACL read/write arrays and no-`log.read` invariant remain host-pinned; no workflow expression entered a `run:` body, and secret files plus `.tmp` siblings remain ignored. The #864 tool-probe and #865 artifact-format changes do not mount secrets or bypass the existing SDK digest/signing boundary. No confirmed new security finding.

**Proof boundary / next.** All newly reviewed controls are `host` (where behavioral tests execute) or `manual` (source-only); earlier #392 session enforcement and #761 installed timeout dependency retain their dated `lab` evidence, not a new 2026-09-27 lab pass. The #821 Packages grep-failure assertion is source-shape only; a behavioral I/O failure remains prove-next. Revisit with QEMU/live publish only when those seams change or at the next release sign-off. Full surface re-pass deferred: no new high/medium cross-surface finding or failing class gate; the next tag still requires the pin/full-usign checklist in the existing `Next:` entry.

### 2026-08-12 — Supply chain, file modes, and UCI scope

**Scope.** Release pipeline key handling and fetch pinning; on-device file modes
and lock ownership; UCI commit scope and zone lookup. Frontend sinks and the ACL
were re-swept but not the focus — the audit skill correctly calls the frontend
highest-yield, and it was found clean again.

**Method.** Read-only, plus host reproductions and upstream source checks
(`rpcd/uci.c`, `uci.h`, `flock(2)`, `libuci` file modes). Prompted by an audit of
the sibling repo `usrmanage`, whose findings suggested three classes to look for
here: temp-file mode loss, unswept fix classes, and hand-parsed platform formats.
All three were present.

**Result.** Four findings: S1–S4 above. Two of them falsify entries previously
recorded as settled — the Known-good list asserted "secret-key file permissions"
and "WAN-log bit-0-only manipulation", and both were derived by reading rather
than running. The Known-good list and the supply-chain table are corrected in
the same PR as this file.

**Non-findings**, so the next pass can skip them:

- Frontend sinks: the Step 1 sweep returns four `E()` calls with bare-identifier
  children (`table.js:99`, `chips.js:96`, `logging.js:202`, `fwlive.js:1578`);
  all four pass arrays or element nodes. No `innerHTML` write has a non-empty
  right-hand side.
- ACL: read/write split intact; no `ubus log.*` grant; `__selftest` and
  `__rulesmap_iptables` remain unreachable through `list`/`call`.
- Workflows: no `${{ }}` interpolation into `run:` bodies — inputs are routed
  through `env:`. All three actions are SHA-pinned, including the one receiving
  `FEED_DEPLOY_KEY`.
- `is_resolvable_address`, `poll_lines_from_input`, and `json_escape` hold under
  their selftests; `nft_dump_fields` captures escaped quotes in nft prefixes.
- `/tmp/.uci` is `0700` (libuci `UCI_DIRMODE`), so an unprivileged user cannot
  stage a firewall delta for S4 to commit. This is what keeps S4 at Low.

**Cross-repo.** S3 also exists in `usrmanage`
([usrmanage#111](https://github.com/lucas-albers-lz4/usrmanage/issues/111)),
where the blast radius is larger because the same lock guards every user-management
mutator.

### 2026-08-13 — Frontend delta + S1–S4 verification (record of non-findings, with one miss)

**Scope.** Delta since 2026-08-12 (`ce9df02..4931026`, v0.1.33): #175/#176 UI work, plus execution of S1–S4 remediations. Filed as [#177](https://github.com/lucas-albers-lz4/fwlive/issues/177).

**Method.** Host tests (`./scripts/fwlive-test.sh`) plus the recording-`innerHTML` harness; `feed-keys-mode`, `fetch-pin-gate`, logging lock/UCI tests.

**Result recorded as no findings.** That was wrong for one class: `scripts/validate-feed-keys.sh` still resolved a mutable SDK tag and bind-mounted `OPKG_FEED_SECRET_KEY` without `--network none`. The pass treated validate-keys SDK ordering as usrmanage-only; it is the same R7 pattern. Closed by the 2026-08-15 entry.

**Non-findings that still hold:** frontend sinks (harness, hostile log/PTR/UCI/hash/chips); S1–S4 tests; rpcd/ACL (no diff); workflows SHA-pinned including `FEED_DEPLOY_KEY`; no `${{ }}` in `run:` bodies.

### 2026-08-15 — R7 pin-at-secret-mount and #178 pin checklist

**Scope.** Close [#177](https://github.com/lucas-albers-lz4/fwlive/issues/177) via ledger correction; remaining [#178](https://github.com/lucas-albers-lz4/fwlive/issues/178) process (peaceiris SHA re-check); R7 analog from [usrmanage#128](https://github.com/lucas-albers-lz4/usrmanage/pull/128). Playbook [#179](https://github.com/lucas-albers-lz4/fwlive/issues/179).

**Method.** Port `sdk_matrix_pull_and_pin` + always-pull; `--network none` on secret mounts; host greps and mocked-docker digest tests. No QEMU.

**Result.** Validate path pins `x86-64`/`23.05` before the usign secret mount. Opkg/apk **sign** steps export tools via compose (no secret), then `docker run --network none` with a digest-pinned image and no `/builder` mount (Compose v2 `run` has no `--network`; compose volume names are project-prefixed). Pre-release checklist requires re-checking `peaceiris/actions-gh-pages` tag↔SHA (alert 7 already **fixed**; Dependabot version PRs stay off). Open findings table empty. No L12 analog (no incomplete-marker path).

### 2026-08-18 — Release-pipeline hardening parity with usrmanage

**Scope.** Port four release-pipeline controls already in force in `usrmanage` (there R1/R5 + environment + cache hardening, filed from #63/#70/#117): publish job scoped to Environment `feed-publish`; checkout `persist-credentials: false` (no GITHUB_TOKEN in `.git/config` inside the SDK bind mount); `workflow_dispatch` tag validation (newline/control-char rejection + `^v[0-9]` shape) before `GITHUB_ENV` write; SDK feed cache keyed exactly on `feeds.lock` hash with no `restore-keys` prefix fallback (stale feed pins cannot be restored).

**Method.** Read-diff of `usrmanage`'s `.github/workflows/publish-packages.yml` (the hardened template from #117/#120) against fwlive's; ported the four deltas verbatim, adapted env var names (`FWLIVE_RELEASE_TAG`, `FWLIVE_GIT_TAG`).

**Result.** Controls added to the table above. No new findings; the existing S1–S4/R7 controls are unaffected. Environment `feed-publish` created 2026-08-18 with **no protection rules** (matches usrmanage; adding required reviewers later would gate tag-push publishes on human approval). The environment is an organizational/approval-capable gate, NOT a secret-scoping mechanism — the five feed secrets remain repository-scoped (identical to usrmanage's setup).

### 2026-08-18 — R7 sign-step wrapper regression fix (first publish after R7)

**Scope.** The v0.1.34 publish (first after the 2026-08-15 R7 rework) failed at `index+sign via SDK` with exit 127: `/feed/tools/mkhash: line 5: /feed/tools/../lib/ld-linux-x86-64.so.2: No such file or directory`.

**Root cause.** OpenWrt SDK `staging_dir/host/bin/{usign,mkhash,apk}` are **runas wrapper scripts**, not plain binaries: `bin/<tool>` execs `../lib/ld-linux-x86-64.so.2` with `LD_PRELOAD=../lib/runas.so` against the hidden real binary `bin/.<tool>.bin`. The R7 export (`feed_publish_export_*_tools`) copied only the bare wrapper into `/feed/tools`, so the relative `../lib` and `.bin` siblings were missing. Verified across 21.02.7 / 24.10.8 / 25.12.5 SDK tarballs — the pattern holds in every supported release.

**Fix.** Export the wrapper **and** the hidden `.bin` into `tools_dir` and the shared-lib tree (`*.so*` only) into a separate `lib_dir`, mounted as siblings at `/feed/tools` + `/feed/lib` so the wrapper's `../lib` resolution works while `/feed/pkgdir` stays a plain mount. Export runs in the dedicated `sdk-export` compose service (SDK volume only, **no workspace mount**) as the invoking uid — the workspace holds the signing keys, so the export container must never see them; only world-readable `.so*` libs are copied (the 0600 buildbot-owned `meson/` templates are not needed), so root is not required. Sign runs remain `docker run --network none`, no `/builder` mount, digest-pinned image, keys `:ro` — all preserved.

**Result.** `bash -n` clean; actionlint clean; fix verified by re-running the publish workflow (v0.1.34).

### 2026-08-23 — Read-only audit + remediations (#204, #205, #206)

**Scope.** Full-surface read-only pass (log parsing/logging script, rpcd plugin + ACL,
LuCI view, package/install surface, CI workflows, release + signing, build inputs,
dev tooling). Filed [#204](https://github.com/lucas-albers-lz4/fwlive/issues/204),
[#205](https://github.com/lucas-albers-lz4/fwlive/issues/205), [#206](https://github.com/lucas-albers-lz4/fwlive/issues/206).

**Method.** Read-only inspection against `master`; upstream source checks where
relevant. Two findings remediated in the same PR: symlink guard on the WAN logging
lock (#204), removal of unpinned `@playwright/mcp@latest` (#205). Ledger refresh
(#206) records verified state.

**Findings fixed in PR.**

- **#204** — WAN logging lock moved to `/etc/fwlive/logging.lock` (root-only dir);
  `acquire_wan_log_lock` fails closed on `-L` before create, chmod/chown, and
  `exec 9>`; Part E in `fwlive-logging-lock.test.sh`.
- **#205** — `.cursor/mcp.json` playwright MCP removed; UI smoke tests use pinned
  `playwright@1.60.0` from `package.json`.

**Non-findings** (surfaces examined, clean):

- rpcd plugin + ACL: read/write split; no `ubus log.*`; selftests intact.
- LuCI view: no new HTML sinks; untrusted values remain text nodes.
- CI workflows: no `${{ }}` in `run:` bodies; actions SHA-pinned.
- Release + signing: R7 controls unchanged; no new unpinned fetches.
- Build inputs: `feeds.lock` / `package-lock.json` pins intact.

**Result.** Open findings table empty. #204/#205 in Verified findings. `SECURITY.md`
links to this ledger for review state.

### 2026-08-31 — B1 rpcd fixes (Task 1–3)

**Scope.** `build_rules_map` pipeline subshell (rules map empty in production), duplicate JSON keys when slug==raw, `poll_lines_from_input` overflow/zero clamp bypass. File: `openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive`.

**Method.** Host reproduction under `dash` and `busybox sh`; stub-based `rules` method tests (nft + iptables-save on PATH); `__selftest` with `poll_clamp_lines` helper; `shellcheck -s sh`.

**Fixes (minimal, POSIX sh).**

- **Task 1 (pipeline):** The first cut captured fragments via `frag=$(nft_list_ruleset | { OUT=''; map_from_nft_stream; printf '%s' "$OUT"; })` so the map escaped the pipeline subshell. That left no global first-wins `OUT` across backends. R4 (below) replaced it with `_fwlive_mktemp` + redirect so accumulation stays in the main shell. `run_with_timeout $NFT_TIMEOUT` and the `ip6tables-save` presence check are unchanged. `rulesmap_from_iptables_file` (redirect path) was already on the non-pipeline path. Verified both shells; test fails before fix (empty map) and passes after.
- **Task 2 (duplicate keys):** Two layers. `map_prefix_with_label` / `map_uci_rule_names` skip a second `map_add` when `slug==raw` (fw4 lower-hyphen identity). `map_add` itself is global first-wins against `$OUT` (`case "$OUT" in *"\"$esc_key\":"*)`), so the same key from UCI + nft + iptables is emitted once. The slug==raw skip is not a substitute for that global state.
- **Task 3 (poll clamp):** Added `poll_clamp_lines` helper: strip leading zeros, if empty →50, if `${#tmp} > ${#POLL_LINES_MAX}` →2000 before any `test -gt`, else safe numeric clamp. `poll_lines_from_input` delegates to helper. `0` now →50, over-long (`99999999999999999999`, `18446744073709551616`) →2000, `2001` →2000, `500` passes. Helper tested without `jshn` (direct `poll_clamp_lines` calls) and with `jshn` via `poll_lines_from_input`; read-ACL reachable `poll` is now defence-in-depth clamped without relying on silenced `test` error.

**Result.** Three new host controls (see table). Accumulation via redirect (no pipeline subshell) enables global dedup. `shellcheck` and `./scripts/fwlive-test.sh` pass.

### 2026-08-31 — R4 temp-file hardening (round 4)

**Scope.** Predictable temp path `printf '/tmp/fwlive-nft-%s' "$$"` fallback in `build_rules_map` (3 sites) gave a root-level arbitrary-write primitive via symlink at `/tmp/fwlive-*` (PIDs brute-forceable). `mktemp` present on OpenWrt (BusyBox) so fallback unlikely but must not exist in root-context code. Same class as #204 (lock symlink).

**Method.** Grep for `$$` / `printf.*fwlive`; host reproduction under `dash` + `busybox sh` with `mktemp` shadowed (absent).

**Fix (minimal, POSIX sh).**

- **Delete fallback:** removed `|| printf '/tmp/fwlive-nft-%s' "$$"` from all 3 sites (no predictable-path code path remains).
- **Single helper:** `_fwlive_mktemp <prefix>` — `_fwlive_tmp_dir_ok` then `mktemp "/tmp/<prefix>.XXXXXX" 2>/dev/null` only. `TMPDIR` is **deliberately not honoured** and there is **no bare-`mktemp` fallback**: bare `mktemp` consults `TMPDIR`, and an attacker-writable non-sticky `TMPDIR` would restore the create-then-reopen (TOCTOU) symlink-write primitive, since `build_rules_map` reopens the path with `>` while running as root. Stickiness of `/tmp` is **checked** with POSIX `[ -k ]` (not `stat -c`, which default OpenWrt BusyBox may omit). Fail closed → skip enrichment. Never `rm`+reuse, never `touch`/`chmod`. If `mktemp` fails, the backend enrichment is skipped and a well-formed map is still returned. BusyBox `mktemp` sane.
- **Graceful degradation:** ``_tmp=$(_fwlive_mktemp fwlive-nft) || _tmp=''`` then `if [ -n "$_tmp" ]; then nft_list_ruleset >"$_tmp" ...; rm -f "$_tmp"; fi` — if `mktemp` absent/failing, backend enrichment skipped, still returns well-formed `{"backend":...,"rules":{...}}` with UCI names. No fixed-path write.
- **Cleanup guaranteed:** `rm -f "$_tmp"` is unconditional inside the `if [ -n "$_tmp" ]` block, immediately after use, with no early `return`/`exit` between creation and removal. nft, iptables, and ip6tables each get a fresh `_fwlive_mktemp` into the same `_tmp` after the previous file is removed. Failure path (`mktemp` empty) never creates a file, so no cleanup needed. The `map_from_*` helpers do not `exit` the shell.
- **tmpfs/RAM:** `/tmp` on OpenWrt is `tmpfs` (RAM). `NFT_TIMEOUT=5` bounds the nft dump's **duration, not its size**, and `iptables-save`/`ip6tables-save` run with **no timeout at all**; size is not bounded by code. Typical firewall dumps are <100KB and the file is removed immediately after parsing, so RAM impact is negligible in practice. No pipeline subshell reintroduced (global `OUT` dedup preserved). **Superseded 2026-09-19 #378 Phase 2:** the iptables-save dump path is gone; only nft is invoked and timed.
- **Cleanup:** inline `rm -f` immediately after parsing, plus EXIT/HUP/INT/TERM traps on `_rules_dump` / `_nft_tsv` so a killed `rules` call does not leak `/tmp/fwlive-nft*` (#775). `testRulesTempsCleanedOnKill` sends SIGTERM while `nft` is blocked.

**Test.** `testNoMktempGracefulDegradation` in `tests/fwlive-rules-map.test.js` — shadows `mktemp` (exit 127) at front of `PATH`, calls `rules` under `dash` (and `busybox sh` only when BusyBox honours PATH; Ubuntu standalone applets skip). Asserts: (1) well-formed JSON + `backend==nft` + UCI names still present (catches missing degradation / malformed JSON), (2) no `/tmp/fwlive-{nft,ipt,ip6t}*` file created (catches predictable-path symlink write), (3) nft-derived key `should-not-appear` absent (catches fixed-path dump still being parsed). `testTmpDirSticky` pins reject of a non-sticky dir and of a symlink. Verified `grep -n '\$\$' rpcd/fwlive` empty and `grep -n 'mktemp'` shows only helper + call sites.

### 2026-08-31 — R5 remaining luci#8992 folds (#228)

**Scope.** Second wave of [openwrt/luci#8992](https://github.com/openwrt/luci/pull/8992) review fixes after B1/R4: hostname resolve without `getent`, declared `jsonfilter` dependency, one-pass awk classifier (poll fork storm), `json_escape` owned by `fwlive-logging.sh` for standalone `prerm`, JSON unescape before classify, UCI whitespace rule-name skip, luci-copy `SOURCE_DATE_EPOCH` / dual-maintenance docs. Sticky `/tmp` via POSIX `[ -k ]` is recorded under R4; this entry covers the #228 surface.

**Method.** Host `./scripts/fwlive-test.sh` (dash + BusyBox ash stubs); `validate-baseline.sh` for `+jsonfilter` in `LUCI_DEPENDS`; shell-filter / rules-map / logging suites.

**Fixes recorded.**

- **Resolve:** BusyBox `nslookup` replaces `getent`; missing resolver → `error:no_resolver` (not empty `names`).
- **Poll filter:** `+jsonfilter` hard depends; missing binary → non-zero + `error:jsonfilter_missing`; classifier is one awk pass; filter is one `jsonfilter` + one awk; libubox string escapes unescaped before classify.
- **prerm / escape:** `json_escape` lives in `fwlive-logging.sh` so `prerm` can source it standalone (#222).
- **Rules map:** UCI names with whitespace are not word-split into junk keys (#226).
- **Docs / cut:** dual-maintenance policy and Dependencies prose for the luci snapshot (#224/#225).

**Result.** Controls for nslookup, `json_escape` ownership, whitespace UCI names, `jsonfilter` depends, and JSON unescape added to the table. Open findings none from this wave; post-merge follow-ups filed separately (#229–#235).

### 2026-08-31 — #232 BusyBox-safe WAN lock dir check

**Scope.** `wan_log_lock_dir_safe` used `stat -c '%u'/'%a'`, which default OpenWrt BusyBox omits (`STAT=n` / `FEATURE_STAT_FORMAT=n`). Fail-closed then made Enable/Disable WAN logging dead on a stock image.

**Fix.** `[ -O ]` for euid ownership; `find -prune \( -perm -020 -o -perm -002 \)` for group/other write. No `stat`. Part F in `fwlive-logging-lock.test.sh` shadows `stat` on `PATH`.

### 2026-09-03 — Multi-model VVAH pass (playbook + delta + B-1)

**Scope.** Document portable multi-model audit (fwlive skill + usrmanage twin); Stage 0 seed; Stage 1 delta packets (warnings UI, zone grammar, Wave B harness, Stage-0 class memory); Fable Stage 2 on flagged packets; validation panel; Composer fix for B-1. Honest-gap lab scripts landed (QEMU not available this pass).

**Method.** Deterministic greps + `./scripts/fwlive-test.sh` / shellcheck; Grok+Luna job packets; Fable 5.1 Engineer Mode on UCI grammar + Wave B proof boundary; Luna validation panel on B-1.

**Finding fixed in-tree (no public issue — Low, fixed same pass).**

- **B-1** — `wan_firewall_zone_same` treated any `name=wan` zone as identical. Duplicate wan `.log` deltas were able to publish with a commit. Now compares canonical cfg ids via `uci -X show`. Host test covers duplicate-wan foreign line.

**Non-findings**

- `#fwlive-backend` / `timeout_missing`: `textContent` + allowlisted `_()` strings only.
- `#fwlive-backend` / `legacy_iptables_detected`: same `textContent` + `_()` pattern; diagnostic, non-gating.
- Wave B Playwright: UX contract only; XSS SoT remains recording-`innerHTML` harness (Fable NON-FINDING).
- Stage-0 class memory: no new `${{ }}` in `run:`, no new temp-mode/pin regressions in delta.
- UCI `.log_*` near-miss grammar (#257) holds under Fable checklist.

**Full-pass gate.** Deferred — no class bug beyond B-1 (fixed), no high/medium blast radius. The pin checklist is not due until the next `v*` tag. Next: QEMU `qemu-security-gaps-smoke.sh` for gaps 1–3.

### 2026-09-06 — Housekeeping hygiene (#293)

**Scope.** Carryover from upstream-readiness review (#288 M10, M12) and live housekeeping scan: stale merged branch + GHAS secret-scanning sub-features (User-account UI toggles; no REST path).

**Actions.**

- **H1:** Deleted remote `fix/rpcd-hardening` (merged via PR #68 on 2026-07-29; predated `delete_branch_on_merge`). Verified `GET .../git/refs/heads/fix/rpcd-hardening` → 404.
- **H2:** **N/A — plan-gated.** Validity checks and non-provider patterns require GitHub Team/Enterprise with Secret Protection; they are not available on personal User accounts (no UI toggle path). Documented upstream in [housekeeping#24](https://github.com/lucas-albers-lz4/housekeeping/issues/24). Base secret scanning + push protection already `enabled` (API-confirmed 2026-09-06). Housekeeping may still report `secret_validity_checks_off` / `secret_nonprovider_patterns_off` as false positives until plan-aware scanning lands.
- **H3:** This ledger entry records H1 complete and H2 N/A.

**Result.** H1 done (no package code change). H2 closed as not actionable on this account; #293 closed 2026-09-08.

### 2026-09-06 — Lint / actionlint / shellcheck baseline (#290)

**Scope.** Upstream-readiness Tier-1 tooling: actionlint CI job (L6) and curated shellcheck `--severity=warning` baseline (L7).

**Artifacts.**

- **actionlint:** job `actionlint` in `.github/workflows/fwlive-test.yml` runs `docker run` (not job-level `container:`) with digest-pinned `rhysd/actionlint@sha256:887a259a5a534f3c4f36cb02dca341673c6089431057242cdc931e9f133147e9` (v1.7.7), same EACCES-safe pattern as zizmor / usrmanage.
- **shellcheck baseline:** `scripts/shellcheck-baseline.txt` (zero suppressions as of this date — shipped libexec/rpcd clean at warning+style) + `scripts/fwlive-shellcheck.sh` uses `--severity=warning` and applies `--exclude` only for justified baseline ids.

**Result.** New SC warnings and Actions config mistakes fail the PR gate. Baseline grows only with an annotated reason per SC id.



### 2026-09-18 — #365/#366 behavior-preserving refactor delta

**Scope.** `view/status/fwlive.js` logging-toggle sequencing and pure render/resolve/poll-tail helpers; `root/usr/libexec/rpcd/fwlive` rules-map dump and selftest comparison helpers. No ACL, ubus method, DOM sink, or untrusted-input contract changed.

**Method.** Read the threat model and prior ledger, then ran the deterministic delta checks: `node --check`, `./scripts/fwlive-shellcheck.sh`, `fwlive-rpcd-security.test.js`, `fwlive-rules-map.test.js`, the LuCI-accurate E() harness, view poll/layer-2 tests, and the new logging-toggle harness. The B1 production `call rules` paths remain covered by `fwlive-rules-map.test.js`; B2 uses quoted `check_eq ... || return 1` and keeps each prior stderr suffix at its call site.

**Non-findings.** The rules-map helper still uses `_fwlive_mktemp`, redirects into the unpredictable sticky-`/tmp` file, keeps the IPv6 command-availability gate, and preserves the IPv6 empty-error precedence. The view changes do not add HTML sinks; the new render helpers retain array-wrapped string children. No new command interpolation, ACL scope, or read/write mixing was introduced.

**Result.** Host proof class remains `host`; open findings table stays empty. A full surface re-pass is deferred because this delta found no class bug or high/medium blast-radius issue and no tag pin checklist is due.

### 2026-09-19 — #383 WAN-zone diagnostics follow-up

**Scope.** The #373 no-zone candidate list is now part of `logging_status` and is
rendered by the LuCI empty state and toolbar as text-node content. The finder
also treats a zone section id as the effective name when both UCI `name` and
`network` are omitted. Screenshot fallbacks reject an empty zone id before
issuing `uci set`. No ACL or command-input scope changed.

**Method.** Added status-shape and `wan6` defaulting fixtures, corrected the
concurrency-test UCI stub to declare a real zone and reject `no_wan_zone` as a
successful toggle, and added a hostile candidate name to the LuCI-accurate E()
harness. The candidate is passed only as an array child, so it reaches the DOM
as a text node and never an HTML sink. Shell syntax, ShellCheck, focused
logging/lock/RPC/view tests, and the full host suite pass.

**Result.** No security finding is known from the follow-up; the existing host
proof class remains `host`.

### #316 — real jshn RPC coverage

Host coverage uses matched, commit-pinned libubox binaries and shell helpers for
21.02, 22.03, 23.05, 24.10 and 25.12. The production RPC copy changes only the
host location of the device library; stdin input, parser, validation and output
paths remain production code. Malformed resolve JSON must return `invalid_input`;
missing fields remain empty names, and poll retains its bounded default.
Nounset/errexit flags are checked after successful return on every tested branch.
JSON element boundaries are preserved before newline transport. The parser's
exit is checked before evaluating its generated assignments (one parse only).
ACLs, DNS timeouts and literal-address validation are unchanged. Lab proof: full smoke on armsr/armv8 OpenWrt 24.10.8 passed for this delta;
installed RPC SHA-256 `8c82a2909d81fa6921fa72bbfc5d864d229f628c3b0f2fe0c8de654663c5d284`
matched the local file. Device malformed resolve returned `invalid_input` and
`__selftest` exited zero. Host tests reject old master on every variant.
Luna delta review found no blockers; Bugbot is unavailable in this environment.
Full surface re-audit is deferred: changes are confined to the parser and its
host harness; no ACL, DOM or logging mutation paths changed.

### 2026-09-19 — #371 nf_log readiness

**Scope.** `fwlive-logging.sh` now normalizes backend selectors
case-insensitively, treats empty/missing/`NONE` as unavailable, and separates
IPv6 family availability from the `/proc/sys/net/netfilter/nf_log/10`
selector. IPv4 remains required by the supported WAN path; an absent or empty
`/proc/net/if_inet6` probe makes IPv6 effective-ready. Status blockers and the
enable gate consume the same computed state. No ACL, DOM sink, or
read/write-scope change was made.

**Method.** The #371 shell matrix covers both nf_log paths for missing, empty,
uppercase/lowercase `NONE`, and real backends. IPv4 backend values also drive
status/blockers/ready and the enable gate (IPv6 stack absent). Family fixtures
cover missing, empty, and populated `if_inet6` (including loopback `::1` as
stack-present). Status and enable tests cover IPv4-only `ok:true` on a stubbed
lock, present-IPv6 `NONE` failure, both-families-ready, and present-IPv4 `NONE`.
Documentation records the IPv4-required product path and that `if_inet6` is an
IPv6-stack probe, not a WAN-address probe.

**Result.** Focused logging tests, shellcheck, and the full host suite pass; no
security finding is known from the code delta.

### 2026-09-19 — #384 if_inet6 device check

**Scope.** Confirm on supported OpenWrt images that `/proc/net/if_inet6` is an
IPv6-stack probe, not a WAN-address probe. Host fixtures stay the #371 proof
class. This note records the live-device check #371 asked for. No probe-design
change.

**Method.** x86_64 KVM guests from [`qemu-lab.md`](qemu-lab.md), package
`0.1.44-r1` plus the `lab/384-if-inet6-probe` libexec overlay at `7d1bcf8`.
Each guest captured `if_inet6`, `nf_log/2`, `nf_log/10`, and
`ubus call fwlive logging_status`. Stock `nf_log/10=NONE` was induced by
writing the sysctl and then restored. The no-stack case used a one-shot
`ipv6.disable=1` GRUB append on 24.10.8; GRUB was reverted after the capture.

**Result.** Both pins match the #371 table. The probe design stays closed.

| Guest | `if_inet6` | `nf_log/10` | `logging_status` |
|-------|------------|-------------|------------------|
| 24.10.8 `r29233-443ec4032a` stock | populated, includes `lo` `::1` plus `br-lan` ULA/link-local | `nf_log_ipv6` | `nf_log_ipv6: true`, no IPv6 blocker |
| 24.10.8 stock, `nf_log/10` written `NONE` | unchanged (stack still present) | `NONE` | `nf_log_ipv6: false`, blocker `nf_log_ipv6_missing` |
| 25.12.5 `r33051-f5dae5ece4` stock | populated, includes `lo` `::1` plus `br-lan` ULA/link-local | `nf_log_ipv6` | `nf_log_ipv6: true`, no IPv6 blocker |
| 25.12.5 stock, `nf_log/10` written `NONE` | unchanged (stack still present) | `NONE` | `nf_log_ipv6: false`, blocker `nf_log_ipv6_missing` |
| 24.10.8 boot `ipv6.disable=1` | **missing** | still `nf_log_ipv6` | `nf_log_ipv6: true` (family not required); `enable_wan_logging` → `ok: true` |

Lab guests have no live `wan` / `wan6` interface (slirp LAN DHCP only). The
stock firewall `wan` zone remains, so `enable_wan_logging` can still return
`ok: true`. IPv6 remains present through `lo` and `br-lan`, so an IPv4-only
WAN does not make the stack absent. `nf_log/10` staying populated under
`ipv6.disable=1` confirms that selector is not an IPv6 availability probe.

No tested supported image contradicted the table (in particular,
`ipv6.disable=1` did not leave a populated `if_inet6`).

### 2026-09-19 — #378 legacy iptables diagnostic warning

**Scope.** `fwlive-logging.sh` reads the network namespace's IPv4 and IPv6
legacy table-name procfs files and appends `legacy_iptables_detected` to
`logging_status.warnings` when either contains a table name. The warning is
diagnostic-only: it does not affect `ready`, `blockers`, or the enable gate.
LuCI now shows the warning in `#fwlive-backend` via `textContent` and one
allowlisted `_()` string (#388). It still does not block logging enablement.

**Method.** Host fixtures cover missing, empty, whitespace-only,
IPv4-populated, blank-first-line/populated-second-line, IPv6-populated, and
both-populated table-name files through `FWLIVE_IP_TABLES_NAMES_PATH` and
`FWLIVE_IP6_TABLES_NAMES_PATH`. Empty fixture files remain exported so later
`logging_status` tests do not read host procfs; no host kernel state or
privilege is required.

**Result.** Focused logging tests pass. The warning intentionally reports any
registered table-name entry, not active rules; a loaded legacy module with an
empty built-in table can therefore produce a diagnostic false positive. That
boundary is documented and does not affect readiness or enablement. No ACL,
DOM-sink, or read/write-scope change was made.

### 2026-09-19 — #378 Phase 2 nft-only rules map

**Scope.** `root/usr/libexec/rpcd/fwlive` `rules` no longer dumps
`iptables-save`/`ip6tables-save`. Detection is nft-only: missing nft or a
failed detect dump returns `backend: "unknown"` with `error: "no_backend"`.
A later nft dump failure keeps `error: "nft_failed"`. The CLI-only
`__rulesmap_iptables` hook and `/tmp/rulesmap` fixture path are removed.
Sticky-directory, mktemp, `NFT_TIMEOUT`, size/key caps, first-wins dedup,
and the nft JSON shape are unchanged. LuCI, classifier, and log
normalization are out of scope.

**Method.** Host tests under dash (and busybox sh when PATH honours stubs):
`tests/fwlive-rpcd-security.test.js` (nft dump failure, no-backend, no
iptables fallback) and `tests/fwlive-rules-map.test.js` (nft success,
mktemp skip, key/byte truncation). #394 ACL exact-array and toggle
lock/baseline failure coverage is retained.

**Result.** No ACL, DOM-sink, or read/write-scope change. The deleted CLI
hook is no longer a privileged surface.

### 2026-09-21 — #416 named UCI rules-map lookup

**Scope.** `root/usr/libexec/rpcd/fwlive` retains the existing anonymous-rule
name extraction and adds a second `uci -q show firewall` reader for named
`config rule` sections. It attempts one filtered
`uci -q get firewall.<section>.name` for each discovered section. Failed or
empty UCI/name lookups remain non-fatal; existing first-wins deduplication and
whitespace filtering are unchanged.

**Method.** `tests/fwlive-rules-map.test.js` runs the rules-map harness across
the available POSIX shells. `testUciStreamMergeAndCollision` supplies a named
section and verifies its returned name plus first-wins behavior;
`testUciWhitespaceNames` retains the no-word-splitting and whitespace-filtering
checks.

**Result.** The tested rules map includes the named UCI rule without changing
the existing collision or whitespace behavior. This is a ledger update for the
implemented behavior, not a new security finding.

### 2026-09-27 — filter error and timeout follow-up

**Scope.** The rpcd timeout peer-drain loop now falls back to a whole-second
BusyBox sleep when fractional sleep is unavailable. Its filter error-body
allowlist is checked against every complete error body emitted by the shipped
filter. The output shape and ACL are unchanged.

**Proof class.** `host` for the error-body gate and timeout fallback; `manual` for the unchanged ACL and command-string paths. The touched rpcd and adaptive-helper delta showed no new input-to-shell interpolation or session method. Full surface re-pass deferred: no high/medium cross-surface finding or failed class gate.

**Method.** The filter/source parity assertion in
`tests/fwlive-rpcd-security.test.js` covers the error-body coupling. Existing
timeout descendant cases cover a child that retains or closes stdout after
the parent exits. The fractional-sleep fallback preserves the hard outer
deadline while preventing a tight `/proc` scan on reduced BusyBox builds.

**Result.** No new RPC or session permission is introduced. The timeout
wrapper still returns a failure when the hard deadline kills its process
group; the fallback only changes peer-scan cadence on reduced BusyBox builds.
