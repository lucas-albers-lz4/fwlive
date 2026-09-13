# Test approach

## Purpose

This project uses defect-driven, risk-based testing. The goal is credible
evidence for important behavior, not a target percentage of lines or tests.
This approach records the criteria for deciding what to test, where to test it,
and how often to run it. It is intended for a single developer maintaining a
package that must remain suitable for upstream OpenWrt review.

The approach is based on the two-week bug reviews and the coverage plan in
[#240](https://github.com/lucas-albers-lz4/fwlive/issues/240). The issue remains
the historical decision record; this document is the durable policy. The
implementation waves tracked by
[#271](https://github.com/lucas-albers-lz4/fwlive/issues/271) are historical
results, not a list of current gaps.

## Core rule

Add or strengthen a test when it protects a specific, consequential behavior
against a plausible failure and provides detection beyond the existing checks.
Choose the least costly environment that preserves the production semantics
needed to expose that failure. A behavior counts as covered only when the
relevant assertion executes against the intended artifact and boundary.

This rule has four consequences:

1. Every confirmed defect gets a regression check at the lowest level that can
   reproduce it, unless the coverage ledger records why that is not useful.
2. A higher-level test is warranted only when it exercises a boundary that a
   lower-level test cannot preserve or observe.
3. A test is not evidence merely because it exists: skipped prerequisites,
   stale generated inputs, unexecuted local-only checks, and assertions against
   a non-representative fixture must be visible in the record.
4. A test may be deferred when its incremental detection value does not justify
   its runtime, flake risk, fixture upkeep, or diagnosis cost. The deferral
   needs a reason and a trigger for reconsideration.

## What “covered” means

Review test evidence using these separate states:

| State | Meaning |
| --- | --- |
| Implemented | The check exists in the repository. |
| Executed | The check ran for the reviewed revision and its assertions were reached. |
| Enforced | CI or a documented release/sign-off procedure requires it, and missing prerequisites fail that check rather than silently skipping it. |
| Manually verified | A person performed a defined check that is not currently automated, with the date and artifact recorded. |

Only the states supported by evidence should be claimed. An optional local
check can be useful without being an enforced gate, but those are different
claims. For generated or packaged artifacts, verify the artifact that users
receive, not only its source counterpart.

The security review uses a separate `host` / `lab` / `manual` proof-class
vocabulary. For cross-reference, `host` normally means executed and enforced
host evidence, `lab` means executed QEMU evidence, and `manual` means a person
or inspection supplied the evidence. The security-review proof class remains
the owner of security-review status; it must not be inferred from a test's
existence alone.

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

- existing coverage is sufficient;
- strengthen an existing test;
- add a focused test; or
- defer with a reason and a revisit trigger.

Prioritize security boundaries, destructive configuration behavior, and
resource-exhaustion behavior even when the bug history is quiet. A low defect
count may mean that existing tests work, that exposure is low, or that failures
are not being detected.

## Fidelity levels and frequency

Test fidelity and execution frequency are separate decisions. A costly test
does not automatically belong in every pull request, and a cheap test is not
automatically sufficient for every boundary.

| Level | Use it for | Current policy |
| --- | --- | --- |
| Host unit/CLI | Parser, filter, classifier, shell helper, UCI-shape, error, timeout, and state-machine contracts that can be reproduced with deterministic fixtures or faithful dependency stubs. | Required in the normal host suite when the behavior is part of the per-PR contract. |
| Browser with mocked services | A real browser DOM/rendering run, plus the harness's LuCI-style `E()` behavior, poll and event wiring, visibility transitions, and theme behavior. The harness must state which LuCI services are mocked and which production semantics it preserves. This is not an installed-LuCI/rpcd lifecycle test. | Use for UI contracts that host objects cannot observe; the required mocked-view job runs per PR. |
| QEMU/OpenWrt | Installed-package seams: real LuCI dispatch, rpcd/ubus/UCI behavior, BusyBox ash and utilities, firewall/log pipeline, reload/uninstall behavior, and representative end-to-end recovery. | Run the focused smoke in the publish/release CI job (tag push; the same workflow can be dispatched). Do not add a scheduled QEMU job, and do not make QEMU a routine per-PR gate. Local QEMU remains available to reproduce an installed-system failure. |

Move a check upward only when the lower level cannot reproduce the failure,
cannot observe the relevant boundary, or has provided false confidence. Move a
check downward when a higher-level test duplicates a distinct contract without
needing its environment. A new installed-system failure or a repeated escape
is a reason to add one focused higher-level smoke, with the reason recorded.

Do not silently quarantine a flaky test. If a check must be temporarily
non-blocking, record an owner, an issue, the failure mode, and an expiry or
revisit condition.

## Project priorities

The bug history in #240 makes these the highest-return areas for targeted
review:

| Area | Evidence to favor |
| --- | --- |
| Shell, BusyBox, jshn, jsonfilter, and UCI boundaries | Real production helpers with faithful shell/dependency semantics; include portability, quoting, limits, locking, rollback, and unrelated-state preservation. |
| rpcd, logging, and ACL behavior | Contract tests for input limits, filtering, permissions, and read/write separation; installed-system checks when service wiring is the risk. |
| View polling, rendering, and asynchronous state | Host tests for state transitions and stale-result guards; browser tests for real DOM/event behavior; include failure-to-recovery and bounded-work paths. |
| Resource pressure and graceful degradation | Assertions for caps, cadence/backoff, visible status, cancellation, recovery, and no stale update after hide/show or pause/resume. |
| Parser and generated artifacts | Keep specification, mirror, generated shell, wrapper, schema, and parity checks synchronized; revisit when the grammar or supported inputs change. |
| Build, publish, and release controls | Keep feed-key, pin/digest, package, and release-asset checks; add coverage when the release path or trust boundary changes. |

This prioritization is a queue, not a permanent exemption. Reconsider a quiet
area when its contract, dependency, supported platform, threat model, or
failure evidence changes.

## Current execution tiers

The normal per-PR path is the host suite, real-jshn compatibility and BusyBox
shell checks, link checking, the required mocked-LuCI view job, Z3 verification,
and workflow static analysis (`zizmor` and `actionlint`), as defined in
[`fwlive-test.yml`](../../.github/workflows/fwlive-test.yml). It should remain
fast enough for routine development. The project does not use a percentage
threshold, a broad browser matrix, or routine per-PR QEMU.

The QEMU lane remains valuable for the narrow path that host and mocked tests
cannot prove: installed LuCI/rpcd dispatch, real `ubus log.read` to filtering
and classification, UCI commit/reload behavior, BusyBox execution, and
firewall/log integration. It runs as part of CI on the publish/release path,
not on a calendar. Keep that lane representative and small; record measured
runtime and flakes before changing its frequency or scope. The contributor
workflow's `qemu-install-fwlive.sh` plus manual LuCI check is a
`Manually verified` step when a LuCI or rpcd change warrants it; it is not a
missing per-PR CI job. See [`contributing.md`](contributing.md).

Renderer tests that construct descriptive objects do not render. They cannot
prove that a value reaches the DOM as text rather than an HTML sink. Rendering
or security changes need a harness with LuCI-accurate `E()`/DOM semantics, and
installed behavior may still require QEMU. See
[`build-and-test.md`](build-and-test.md) and
[`security-model.md`](security-model.md).

## Targeted coverage review

Do not begin by counting tests. Begin with evidence and risk:

1. Record the reviewed commit and reconcile the inventory with actual scripts,
   CI jobs, nested invocations, skip paths, and generated/package artifacts.
2. Map security, ACL, logging, configuration, locking, and rollback invariants
   to assertions and identify any proof that is only manual or local.
3. Inspect dependency seams: BusyBox, ash, jshn, UCI, jsonfilter, firewall
   helpers, LuCI DOM, and rpcd. Preserve the dependency whose semantics caused
   the risk; stub unrelated services deterministically.
4. Trace stateful and resource-sensitive behavior through failure and recovery:
   poll failure/recovery, hide/show with requests outstanding, pause/resume,
   cancellation, adaptive degradation, and return to normal operation.
5. Cross-check escaped defects since the last recorded baseline: the previous
   coverage-review commit, or the last release tag (`v*`), whichever the
   ledger names. Deduplicate by root cause. History informs priority but does
   not waive severe risks. If that interval is too small to be informative,
   a longer lookback is optional context, not a second required window.
6. Produce a small ranked backlog and choose only the highest-value additions.
   Reassess after those changes rather than expanding the matrix all at once.

For a project-wide review, keep the ledger in the review issue or pull request
as a comment using the template below. A committed ledger is optional and
should be added only if repeated reviews show that issue/PR comments are losing
the necessary history.

The review ledger should have at least:

```text
risk or contract | consequence | production surface | existing assertion
artifact and fidelity | execution/enforcement state | proposed outcome
maintenance cost | revisit trigger
```

Stop an audit pass when high-impact contracts have credible evidence or an
explicit disposition, and the remaining candidates have low incremental value.
“More tests” is not itself a completion criterion.

## Calibration examples

Before using the criteria for a project-wide audit, apply them to these
representative cases. The rows below are the intended starting dispositions;
the reviewed revision and any changed evidence must still be recorded in the
audit ledger.

| Risk / contract | Existing evidence and fidelity | State | Outcome and revisit trigger |
| --- | --- | --- | --- |
| POT/source freshness | Catalog-to-POT consistency is checked, but source extraction is a separate concern when `xgettext`/the scanner is unavailable. | Structural check can be executed/enforced; source-freshness proof may be implemented without being executed or enforced. | Strengthen the existing upstream-cut/release sign-off path to fail closed when the extractor is required; revisit when the scanner is available in CI or the upstream/release path changes. |
| Real jshn JSON semantics | `tests/fwlive-jshn-compat.test.py` runs matched real jshn release pairs under BusyBox `sh`. | Executed and enforced host evidence. | Existing coverage is sufficient unless that gate starts skipping or the supported jshn/libubox set changes. |
| BusyBox applet differences | Host tests and shell stubs cover selected portability contracts; they cannot prove every installed applet or service boundary. | Mixed host evidence; the exact applet contract must be named. | Add a focused QEMU check only for an applet, `ubus`, UCI, or installed-service behavior the host cannot preserve; revisit after a relevant escape or supported-platform change. |
| Existing poll guard and adaptive-cap behavior | Host contracts cover in-flight guarding, cap/degradation, and bounded work without a browser. | Executed and enforced host evidence where the named tests are in the required suite. | Existing coverage is sufficient for those contracts; strengthen if a failure escapes or the state machine changes. |
| Client visibility/backoff races in [#306](https://github.com/lucas-albers-lz4/fwlive/issues/306) | This is a feature-specific contract, distinct from the existing poll guard/adaptive-cap tests; stub DOM, browser smoke, and QEMU prove different seams. | Defer as a feature/coverage decision until the behavior is in the shipped surface. | When shipped, add host tests for epoch/backoff and recovery; add browser coverage only for real DOM/LuCI event wiring, and QEMU only for an installed transport/service boundary. |

The host renderer/document shim is not the mocked Playwright job. A fake
`document` can prove a text-content or state contract; it does not prove
LuCI-accurate `E()` behavior or real browser event wiring. Likewise, the
mocked browser job does not prove the installed OpenWrt lifecycle. If reviewers
reach different outcomes for these rows, clarify the policy before starting
the wider audit.

## Definition of done for a coverage review

A review is complete when:

- shipped surfaces and their actual gates are inventoried;
- escaped bugs since the last recorded baseline, and high-impact invariants,
  have been considered;
- each important contract has a credible test or an explicit disposition;
- known gaps have an owner or revisit trigger when appropriate;
- selected additions have a stated fidelity level, frequency, and runtime/
  flake expectation; and
- the relevant suites and sign-off checks have been run on the reviewed
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
