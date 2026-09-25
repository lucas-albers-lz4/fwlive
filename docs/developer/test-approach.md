# Test approach

## Purpose

This project uses defect-driven, risk-based testing. The goal is credible
evidence for important behavior, not a target percentage of lines or tests.
This approach records the criteria for deciding what to test, where to test it,
and how often to run it. It is intended for a single developer maintaining a
package that must remain suitable for upstream OpenWrt review.

The approach is based on the two-week bug reviews and the coverage plan in
[#240](https://github.com/lucas-albers-lz4/fwlive/issues/240). The issue remains
the historical decision record. This document is the durable policy. The
implementation waves tracked by
[#271](https://github.com/lucas-albers-lz4/fwlive/issues/271) are historical
results, not a list of current gaps.

## Core rule

When a plausible failure can harm a specific, consequential behavior, add or
strengthen a test for that behavior. Add the test only when it detects failures
that the existing checks cannot detect.
Choose the least costly environment that preserves the production semantics
needed to expose that failure. A behavior counts as covered only when the
relevant assertion executes against the intended artifact and boundary.

This rule has four consequences:

1. Give every confirmed defect a regression check at the lowest level that can
   reproduce it. If such a check is not useful, record the reason in the
   coverage ledger.
2. A higher-level test is warranted only when it exercises a boundary that a
   lower-level test cannot preserve or observe.
3. A test is not evidence because it exists alone. The record must show
   skipped prerequisites, stale generated inputs, unexecuted local-only
   checks, and assertions against a non-representative fixture.
4. You can defer a test when its additional detection value does not justify
   its runtime, flake risk, fixture upkeep, or diagnosis cost. The deferral
   needs a reason and a trigger for reconsideration.

## What “covered” means

Review test evidence using these separate states:

| State | Meaning |
| --- | --- |
| Implemented | The check exists in the repository. |
| Executed | The check ran for the reviewed revision and reached its assertions. |
| Enforced | CI or a documented release/sign-off procedure requires it. Missing prerequisites fail that check rather than silently skip it. |
| Manually verified | A person performed a defined check that is not currently automated. The record includes the date and the artifact. |

Claim only the states supported by evidence. An optional local
check can be useful and not be an enforced gate. Those are different
claims. For generated or packaged artifacts, verify the artifact that users
receive, not only its source counterpart.

The security review uses a separate `host` / `lab` / `manual` proof-class
vocabulary. For cross-reference, `host` normally means executed and enforced
host evidence, `lab` means executed QEMU evidence, and `manual` means a person
or inspection supplied the evidence. The security-review proof class remains
the owner of security-review status. Do not infer it from the existence of a
test alone.

## Choosing a test

For each candidate behavior, answer these questions in a coverage ledger or
issue comment:

| Question | Decision criterion |
| --- | --- |
| What can fail? | Name the observable failure and consequence: security exposure, configuration loss, misleading output, unavailable functionality, or excessive resource use. |
| Why consider it now? | Cite an escaped bug, changed behavior or dependency, supported-environment difference, or important invariant with weak evidence. |
| What already detects it? | Name the assertion, artifact, environment, gate, and any skipped or mocked prerequisite. |
| What is the smallest effective check? | Prefer extending an existing behavioral test. Preserve the real dependency semantics that matter to the risk. |
| Does the assertion discriminate? | Show that the known defect or a small representative fault fails for the intended reason. Avoid assertions derived only from the implementation’s answer. |
| Is the ongoing cost justified? | Consider runtime, setup, flake, fixture maintenance, diagnosis, and unique detection value. |

Use one of four outcomes:

- existing coverage is sufficient.
- strengthen an existing test.
- add a focused test.
- defer with a reason and a revisit trigger.

Prioritize security boundaries, destructive configuration behavior, and
resource-exhaustion behavior even when the bug history is quiet. A low defect
count can mean that existing tests work, that exposure is low, or that failures
go undetected.

## Fidelity levels and frequency

Test fidelity and execution frequency are separate decisions. A costly test
does not automatically belong in every pull request, and a cheap test is not
automatically sufficient for every boundary.

| Level | Use it for | Current policy |
| --- | --- | --- |
| Host unit/CLI | Parser, filter, classifier, shell helper, UCI-shape, error, timeout, and state-machine contracts that can be reproduced with deterministic fixtures or faithful dependency stubs. | Required in the normal host suite when the behavior is part of the per-PR contract. |
| Browser with mocked services | A real browser DOM/rendering run, plus the harness's LuCI-style `E()` behavior, poll and event wiring, visibility transitions, and theme behavior. The harness must state which LuCI services are mocked and which production semantics it preserves. This is not an installed-LuCI/rpcd lifecycle test. | Use for UI contracts that host objects cannot observe. The required mocked-view job runs per PR. |
| QEMU/OpenWrt | Installed-package seams: real LuCI dispatch, rpcd/ubus/UCI behavior, BusyBox ash and utilities, firewall/log pipeline, reload/uninstall behavior, and representative end-to-end recovery. | Run the focused smoke in the publish/release CI job (tag push). The same workflow supports a manual dispatch. Do not add a scheduled QEMU job, and do not make QEMU a routine per-PR gate. Local QEMU remains available to reproduce an installed-system failure. |

Move a check upward only when the lower level cannot reproduce the failure,
cannot observe the relevant boundary, or gave false confidence. Move a
check downward when a higher-level test duplicates a distinct contract without
needing its environment. When a new installed-system failure occurs or an
escape repeats, add one focused higher-level smoke and record the reason.

Do not silently quarantine a flaky test. If a check must stay temporarily
non-blocking, record an owner, an issue, the failure mode, and an expiry or
revisit condition.

## Project priorities

The bug history in #240 makes these the highest-return areas for targeted
review:

| Area | Evidence to favor |
| --- | --- |
| Shell, BusyBox, jshn, jsonfilter, and UCI boundaries | Real production helpers with faithful shell/dependency semantics. Include portability, quoting, limits, locking, rollback, and unrelated-state preservation. |
| rpcd, logging, and ACL behavior | Contract tests for input limits, filtering, permissions, and read/write separation. Add installed-system checks when service wiring is the risk. |
| View polling, rendering, and asynchronous state | Host tests for state transitions and stale-result guards. Use browser tests for real DOM/event behavior. Include failure-to-recovery and bounded-work paths. |
| Resource pressure and graceful degradation | Assertions for caps, cadence/backoff, visible status, cancellation, recovery, and no stale update after hide/show or pause/resume. |
| Parser and generated artifacts | Keep specification, mirror, generated shell, wrapper, schema, and parity checks synchronized. Revisit when the grammar or supported inputs change. |
| Build, publish, and release controls | Keep feed-key, pin/digest, package, and release-asset checks. Add coverage when the release path or trust boundary changes. |

This prioritization is a queue, not a permanent exemption. When the contract,
dependency, supported platform, threat model, or failure evidence of a quiet
area changes, reconsider that area.

## Current execution tiers

The normal per-PR path is the host suite, real-jshn compatibility and BusyBox
shell checks, link checking, the required mocked-LuCI view job, Z3 verification,
and workflow static analysis (`zizmor` and `actionlint`), as defined in
[`fwlive-test.yml`](../../.github/workflows/fwlive-test.yml). Keep that path
fast enough for routine development. The required `test-ipk-payload` check
always reports; the three-cell SDK build runs only when packaging-relevant
paths change, or when path detection fail-closes (#557). The project does not
use a percentage threshold, a broad browser matrix, or routine per-PR QEMU.

The QEMU lane remains valuable for the narrow path that host and mocked tests
cannot prove: installed LuCI/rpcd dispatch, real `ubus log.read` to filtering
and classification, UCI commit/reload behavior, BusyBox execution, and
firewall/log integration. It runs as part of CI on the publish/release path,
not on a calendar. Keep that lane representative and small. Record measured
runtime and flakes before you change its frequency or scope. When a LuCI or
rpcd change warrants it, the contributor
workflow's `qemu-install-fwlive.sh` plus manual LuCI check is a
`Manually verified` step. That step is not a
missing per-PR CI job. See [`contributing.md`](contributing.md).

Renderer tests that construct descriptive objects do not render. They cannot
prove that a value reaches the DOM as text rather than an HTML sink. Rendering
or security changes need a harness with LuCI-accurate `E()`/DOM semantics, and
installed behavior can still require QEMU. See
[`build-and-test.md`](build-and-test.md) and
[`security-model.md`](security-model.md).

## Feed-index version oracles (#421)

After `qemu-install-from-feed.sh` installs `luci-app-fwlive`, the feed smoke
compares the guest installed version to the published index for that cell.
The canonical source is the index the guest will use, including `-r1`. It is
not `${tag#v}` and not the Makefile. Do not invent a third selected-manifest
file.

| Cell | Index oracle | Guest query |
| --- | --- | --- |
| 23.05 / 24.10 | `Version:` on `luci-app-fwlive` in `Packages.gz` (`feed_index_opkg_version`) | `opkg info luci-app-fwlive` — `Version:` field (`feed_index_guest_opkg_version`; `opkg status` uses the same field) |
| 25.12 | `pkgver` from that cell's `packages.adb` via pinned SDK `apk adbdump` (`feed_index_apk_pkgver`) | `apk query --installed --format json --fields name,version luci-app-fwlive` (`feed_index_guest_apk_query_pkgver`) |

Compare index vs guest **per cell**. Opkg may spell `0.1.45-1` while APK spells
`0.1.45-r1`; those forms are not interchangeable.

Host tests cover the guest-query parsers with matching and stale fixtures, and
drive `qemu-install-from-feed.sh` against a local `file://` index with ssh
stubs. The 25.12 guest query is pinned in that host test before CI uses it.
The QEMU feed smoke calls `feed_index_versions_match` after install so a
stale Pages cell cannot pass.

## Targeted coverage review

Do not begin by counting tests. Begin with evidence and risk:

1. Record the reviewed commit and reconcile the inventory with actual scripts,
   CI jobs, nested invocations, skip paths, and generated/package artifacts.
2. Map security, ACL, logging, configuration, locking, and rollback invariants
   to assertions and identify any proof that is only manual or local.
3. Inspect dependency seams: BusyBox, ash, jshn, UCI, jsonfilter, firewall
   helpers, LuCI DOM, and rpcd. Preserve the dependency whose semantics caused
   the risk. Stub unrelated services deterministically.
4. Trace stateful and resource-sensitive behavior through failure and recovery:
   poll failure/recovery, hide/show with requests outstanding, pause/resume,
   cancellation, adaptive degradation, and return to normal operation.
5. Cross-check escaped defects since the last recorded baseline: the previous
   coverage-review commit, or the last release tag (`v*`), whichever the
   ledger names. Deduplicate by root cause. History informs priority but does
   not waive severe risks. If that interval is too small to be informative,
   a longer lookback is optional context, not a second required window.
6. Produce a small ranked backlog and choose only the highest-value additions.
   Reassess after those changes rather than expand the matrix all at once.

For a project-wide review, keep the ledger in the review issue or pull request
as a comment using the template below. A committed ledger is optional. Add one
only if repeated reviews show that issue/PR comments lose the
necessary history.

The review ledger has at least:

```text
risk or contract | owner | consequence | production surface | existing assertion
artifact and fidelity | fault injection | oracle | execution/enforcement state
proposed outcome | acceptance artifact | maintenance cost | revisit trigger
```

Before you stop an audit pass, give every high-impact contract credible
evidence or an explicit disposition. When the remaining candidates add low
value, stop the pass.
“More tests” is not itself a completion criterion.

### 2026-09-20 #370/#378 closeout snapshot

This is ledger/disposition for later close of #389, #392, #378, and
#370. It does not add production coverage.

**#392.** R4a host exact ACL read/write arrays are merged (#394): read =
`rules`, `poll`, `resolve`, `logging_status`; write =
`enable_wan_logging`, `disable_wan_logging`. Sessions do not get
`ubus log.read` (`testAclMethodParity` plus the ACL `log.*` guard; CI).
R4b installed authenticated-session evidence is the dated artifact from
the manual `qemu-acl-session-smoke.sh` run (#401 smoke, #402 artifact
[issue-392-2026-09-20.md](../evidence/issue-392-2026-09-20.md)) on
OpenWrt 24.10.8 x86_64; the per-PR harness only static-checks that
script. On that guest: the grant session was allowed all six fwlive
methods and denied `log.read` with JSON-RPC `-32002`; the
`luci-base`-only deny session was allowed `file.list`, then denied
sampled `logging_status` (read) and `enable_wan_logging` (write). The
remaining four deny-session methods were not called. Host tests stay
separate from that artifact. Session identity is R4b, not R8.

**#389 / R8 lifecycle.** Uninstall restoration is in
[issue-389-2026-09-20.md](../evidence/issue-389-2026-09-20.md): 24.10.8
armsr IPK (`opkg remove` via `qemu-logging-uninstall-smoke.sh`, port
2224 parallel lab), 24.10.8 x86 IPK, and 25.12.5 APK (`apk del`). The
reusable smoke now branches `opkg remove` vs `apk del` and, on 25.12,
adds a same-version `--force-reinstall` preservation cell (expected:
`post-upgrade`, no `pre-deinstall`) using `--artifact-only` installs.
That 25.12 cell has not yet run on QEMU; the host tests model
`PKG_UPGRADE=1`. Host packaged-hook matrix (#405) shows remove
restores, while upgrade / `PKG_UPGRADE=1` / empty/unknown do not.
Same-version reinstall cells are no-op preservation, not skip-upgrade
hook proof (#406). Version-changing APK upgrades stay a residual
until a two-version QEMU experiment exists.
The 23.05 IPK is represented by the architecture-independent `_all`
24.10 IPK; there is no separate 23.05 rebuild. Armsr
`poll`/`resolve`/`rules`/enable/disable notes are root-SSH `ubus`
observations, **not** session proof.

R8 required two package-lifecycle cells (24.10 armsr + 25.12 apk), not a
second session-ACL matrix. R8 is **not** session-complete. Do not claim
session-authenticated proof on armsr or 25.12 apk.

**#378.** Phases 1–3 are merged (nft-only rules, UI warning, drop
21.02/22.03 from the matrix). The compatibility gate is retained as a
checked shipped-artifact constraint: `gen-luci-wrapper.js` rejects
`Array.includes` and `Object.values` in `log.js`. That is an ES5 check
for 23.05+ LuCI/browser, recorded in [contributing.md](contributing.md);
it is not a 21.02 support claim.
G1 is resolved by pruning, not by adding tests for deleted iptables
backend branches; `iptables` log-tag classification remains covered.
`snapshot` stays SDK-internal, not a published feed.
`legacy_iptables_detected` is diagnostic UI `textContent`; it reports
registered table names, not active rules (false-positive if `kmod-ipt-*`
loads empty tables) — already in [security-review.md](security-review.md).
Historical 21.02/22.03 references remain only in the documented
historical allowlist and dated review evidence. Remaining #378 work is
this ledger, not more production pruning.

**#370.** Sub-issues #390, #391, and #393 are already closed. #389 and
#392 are the remaining children. R1 is owned by closed #371.
R2/R3/R5/R6/R7/R9a have host/e-harness coverage. R4a/R4b are covered by
#392. G4 (`RESOLVE_MAX=32`) is covered by jshn-compat. G3/G5 were
covered by host tests. G6 IPv6 PTR parse is covered by rpcd
`__selftest` (see residual below). R9a is the format-aware host IPK
payload inspector.

**Residuals**

- **R8 session identity:** ACL session smoke was 24.10 x86 (R4b).
  Repeating it on armsr or 25.12 apk is not required because the shipped
  ACL/rpcd object is architecture-independent. Armsr read/write notes
  remain root-SSH `ubus`, not session proof.
- **R9b:** 25.12 APK **control** inspection is the host lifecycle test
  against pinned SDK `apk adbdump --format json` (`pre-deinstall` hook
  plus `post-upgrade` `PKG_UPGRADE=1`). Payload `apk extract` remains
  data files only. Version-changing upgrades are still not a QEMU cell.
- **G2:** per-PR `qemu-forwarding-slo-harness` / `-net` tests are
  harness/static (`bash -n`, ShellCheck, helper unit checks). The routed
  guest run (`qemu-forwarding-slo-run.sh` plus traffic) stays manual/lab.
  Revisit on an SLO escape.
- **G6:** rpcd `__selftest` includes bind-style and BusyBox `ip6.arpa`
  PTR fixtures, and the required host suite executes that selftest
  (`fwlive-rpcd-security.test.js`). The
  dedicated `testResolveNslookup` driver is IPv4 `in-addr.arpa` only.
  Residual: no direct end-to-end IPv6 resolve (stubbed `nslookup`
  through `resolve`, or installed QEMU). Revisit on a resolver change
  or IPv6 resolve escape.

## Implementation follow-up from #370

Issue [#370](https://github.com/lucas-albers-lz4/fwlive/issues/370) is a useful
coverage inventory, but its ranked list is not by itself an executable design
plan. Use the following refinements when closing that review or repeating the
same audit:

1. Freeze the evidence boundary. Record the reviewed commit, escaped-defect
   baseline, current HEAD if different, host/runtime versions, exact commands,
   and every skipped prerequisite. Run the relevant gates against the reviewed
   revision; do not mix a result from a follow-up branch into its evidence
   record. A passing suite with a skipped branch is still useful, but the
   skipped branch is not Executed or Enforced.
2. Give each selected gap a complete design tuple: contract and consequence,
   production artifact and boundary, smallest representative fault, oracle
   independent of the implementation, fidelity and frequency, owner, expected
   cost, acceptance artifact, and revisit trigger. The ledger's existing
   `maintenance cost` and `revisit trigger` fields are not a substitute for an
   owner or an acceptance condition.
3. Resolve behavior decisions before writing assertions. The renamed-WAN case
   (R7, formerly L3) is fixed as the membership union rule: the named `wan`
   zone is supported, and a zone whose network list contains `wan` or `wan6`
   is also supported. Keep an explicit `no_wan_zone` disposition for devices
   matching neither form. Do not let a test silently choose a product
   contract. R1 (formerly L2) is implemented and reviewed separately in
   #371. For the release/architecture list (R8, formerly L6), select cells by
   distinct seams—install format, firewall backend, architecture, and
   installed LuCI/rpcd path—instead of promising the full Cartesian matrix.
4. Design every new check to fail for a small, known fault. Host and e-harness
   tests should invoke the shipped entry point or module and inject dependency
   failures through PATH, fixture, or seam controls; they must not reimplement
   the branch under test with an extracted function or a stubbed copy of the
   production filter. Assertions must name the externally visible result and
   preserve unrelated state where rollback or configuration is involved.
5. Treat installed-session and DOM claims as boundary tests. R4a (formerly L1)
   has per-PR host proof for exact rpcd/ACL method parity; R4b has installed
   LuCI/uhttpd `/ubus` evidence for a grant role (all six fwlive methods plus
   `log.read` denial) and a `luci-base`-only deny role whose grant is first
   exercised via `file.list`, then sampled on `logging_status` and
   `enable_wan_logging` in [the #392 artifact](../evidence/issue-392-2026-09-20.md).
   A root `ubus call` is not ACL evidence. The renderer
   item (R2, formerly L4) should use the LuCI-accurate `E()` harness with hostile message
   content, allow only intentional empty-container clearing, and assert that
   the hostile value never appears in an `innerHTML` write while appearing as
   text. The browser fixture item (R6, formerly L5) needs assertions for the changed
   backend, adaptive/degradation metadata, IPv6 row, and hostile row—not only
   fields copied into a mock reply.

Apply the #370 candidates in three bounded stages. R1 is tracked in #371;
R6 combines the former L5 and L9 fixture work; and R3 and R9 are part of the
minimum-ready host evidence rather than optional follow-up items:

| Stage | Scope | Exit condition |
| --- | --- | --- |
| Contract and host evidence | R2 DOM sink proof, R3 hash restoration, R5 fail-closed cases, R6 reply-shape/fixture alignment, R7 union-rule contract, plus the normal empty-ring cases | Each item has a fault, oracle, shipped-artifact boundary, and a passing required-host assertion, or an explicit deferred disposition. |
| Installed seams | R4b session ACL (24.10 x86) and the selected R8 lifecycle cells | R4b owns session identity and the grant/deny method table ([#392](../evidence/issue-392-2026-09-20.md)). R8 owns install format, architecture, backend, and package-lifecycle commands ([#389](../evidence/issue-389-2026-09-20.md)); direct root calls are not session proof, and R8 does not require repeating the ACL smoke on armsr or 25.12 apk. |
| Follow-up state coverage | Remaining R5 rollback injections and R6 backend/IPv6/degradation/storage/resolve cases, plus R9 package formats | Each case is split into an independent assertion with an owner and revisit trigger; grouping is allowed for implementation, not for hiding an unverified branch. |

The upstream-cut readiness decision should be made from those exit conditions,
not from the count of R1–R9 tests. At minimum, R2, R3, R4a, R5, R6, R7, and
R9a need executed evidence or an explicit residual; R1 is owned by #371.
R4b session identity is the 24.10 x86 LuCI/uhttpd smoke
([#392](../evidence/issue-392-2026-09-20.md)); it is not an R8 cell.
R8's selected cells are package-lifecycle evidence in
[#389](../evidence/issue-389-2026-09-20.md) (24.10 armsr IPK and 25.12
apk, plus the extra 24.10 x86 IPK uninstall). R8 is not
session-complete: armsr read/write notes are root-SSH `ubus`, and the
ACL smoke is not repeated on armsr/apk because the shipped ACL/rpcd
object is architecture-independent. R9b remains a described APK control
inspection without a retained payload dump. A manual result becomes
`Manually verified` only when its artifact is retained with the review
record.

Evidence snapshot for the follow-up branch used while refining #370
(`17b9c5de774c`): `./scripts/fwlive-test.sh` passed, `npm run test:view`
passed, and the three-release `fwlive-jshn-compat` checks passed. The rpcd
self-test also reported its expected `jshn not available` skip, so that branch
is not counted as executed there; the separate compatibility gate is the
evidence for real-jshn semantics. This is the evidence distinction the review
record must preserve when the reviewed revision and the current branch differ.

## Calibration examples

Before using the criteria for a project-wide audit, apply them to these
representative cases. The rows below are the intended starting dispositions.
Record the reviewed revision and any changed evidence in the
audit ledger.

| Risk / contract | Existing evidence and fidelity | State | Outcome and revisit trigger |
| --- | --- | --- | --- |
| POT/source freshness | `tests/fwlive-i18n-source.test.js` checks every static `_()` string literal in shipped JavaScript against the checked-in POT, verifies each `#:` reference's cited line contains the msgid as a quoted string, requires JS `#:` refs to occupy extracted `_()` occurrences rather than merely resolving on a containing line, and mutates temporary POT copies to prove the gate catches missing entries, nearby stale references, and duplicated or collapsed `#:` refs. `tests/fwlive-upstream-cut.test.sh` verifies that the cut contains the checked-in `.pot` and rejects absolute repository paths in its `#:` references. When `i18n-scan.pl` and its required runtime tools are available, it generates a fresh POT and compares its msgid set with the checked-in POT. Otherwise that parity assertion is explicitly skipped. | The scanner-free source-to-POT gate and cut-structure checks are Implemented, Executed, and Enforced in the required host suite. Fresh parity is Executed and Enforced only when `i18n-scan.pl` and its required runtime tools are available. If any prerequisite is unavailable, the suite records `SKIP` and the parity assertion is not Executed or Enforced. | Keep the scanner-free gate and use `FWLIVE_I18N_REQUIRE_SCAN=1` for upstream/release sign-off when fresh extraction is required. The static gate intentionally misses dynamic or concatenated `_()` arguments. Revisit when such patterns appear or the upstream/release path changes. |
| Real jshn JSON semantics | `tests/fwlive-jshn-compat.test.py` runs matched real jshn release pairs under BusyBox `sh`. | Executed and enforced host evidence. | Existing coverage is sufficient unless that gate starts to skip silently or the supported jshn/libubox set changes. |
| BusyBox applet differences | Host tests and shell stubs cover selected portability contracts. They cannot prove every installed applet or service boundary. | Implemented and Executed for selected host portability contracts. | Name the exact applet or service contract before escalating. Add a focused QEMU check only for an applet, `ubus`, UCI, or installed-service behavior the host cannot preserve. Revisit after a relevant escape or supported-platform change. |
| UCI zone identity and staged changes | `tests/fwlive-logging.test.sh` covers named and anonymous WAN-zone lookup, `@zone[N]` versus `cfgXXXX` identity through `uci -X`, duplicate names, and filtering unrelated staged changes. Its host stubs preserve those UCI output shapes but do not prove an installed UCI/rpcd boundary. | Executed and enforced host evidence for the modeled identifier and commit-scope contracts; installed-system behavior remains unproven. | Existing host coverage is sufficient for those contracts. Add a focused QEMU check if an installed UCI/rpcd seam escapes or supported UCI behavior changes. |
| Existing poll guard and adaptive-cap behavior | Host contracts cover in-flight guarding, cap/degradation, and bounded work without a browser. | Executed and enforced host evidence where the named tests are in the required suite. | Existing coverage is sufficient for those contracts. When a failure escapes or the state machine changes, strengthen the tests. |
| Client visibility/backoff races in [#306](https://github.com/lucas-albers-lz4/fwlive/issues/306) | Shipped in v0.1.42. `tests/fwlive-view-layer2-backoff.test.js` covers visibility pause, poll-epoch discard, RTT cadence hysteresis, adaptive shedding, and recovery using the host view/module loaders; `./scripts/fwlive-test.sh` runs it in the required suite. This contract is distinct from the existing poll guard/adaptive-cap tests. Stub DOM, browser smoke, and QEMU prove different seams. | Implemented, Executed, and Enforced for the shipped host contracts in the required suite. | Existing host coverage is sufficient for epoch/backoff and recovery. Add browser coverage only for real DOM/LuCI event wiring, and QEMU coverage only for an installed transport/service boundary. Revisit if an escape crosses those seams or the Layer 2 state machine changes. |
| Feed smoke installed version ([#421](https://github.com/lucas-albers-lz4/fwlive/issues/421)) | After feed install, guest `opkg info` `Version:` (23.05/24.10) or `apk query --installed --format json --fields name,version luci-app-fwlive` (25.12) is compared to that cell's `Packages.gz` / `packages.adb` form, including `-r1`. Host tests cover match vs stale parsers and stubbed `qemu-install-from-feed.sh`. | Host parsers Implemented/Executed/Enforced in the required suite. Live QEMU remains the install boundary; this check fails the smoke on mismatch. | Keep per-cell exact compare. Revisit if OpenWrt changes the `apk query` JSON shape or opkg `Version:` field. |

The host renderer/document shim is not the mocked Playwright job. A fake
`document` can prove a text-content or state contract. It does not prove
LuCI-accurate `E()` behavior or real browser event wiring. Likewise, the
mocked browser job does not prove the installed OpenWrt lifecycle. If reviewers
reach different outcomes for these rows, clarify the policy before you start
the wider audit.

## Definition of done for a coverage review

A review is complete when:

- the inventory lists the shipped surfaces and their actual gates.
- the review considered escaped bugs since the last recorded baseline and the
  high-impact invariants.
- each important contract has a credible test or an explicit disposition.
- known gaps have an owner or revisit trigger when appropriate.
- selected additions have a stated fidelity level, frequency, and runtime/
  flake expectation.
- the relevant suites and sign-off checks ran on the reviewed
  revision.

There is no required coverage percentage. The deliverable is a small set of
well-justified tests and a clear record of what remains unproven.

## References

- [#240 — Test plan: practical coverage after upstream](https://github.com/lucas-albers-lz4/fwlive/issues/240)
- [#271 — Coverage-wave implementation history](https://github.com/lucas-albers-lz4/fwlive/issues/271)
- [Build and test](build-and-test.md)
- [Contributing](contributing.md)
- [Security model](security-model.md)
- [Validation matrix](../validation-matrix.md)
