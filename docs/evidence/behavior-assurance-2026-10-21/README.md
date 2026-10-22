# Important behavior and the credibility of its evidence

Research baseline: `9fd99d69652c8ff951a54832cd9421eba8bb192e`, current
`master` when this investigation began. Tracker snapshot collected
2026-10-22 UTC (2026-10-21 in America/Denver). This continues the learning
objective discussed in [#1360](https://github.com/lucas-albers-lz4/fwlive/issues/1360).
The maintainer authorized a broader, methodical investigation after that
issue's bounded implementation work.

The question is: **Which consequential current behavior lacks credible
evidence, and what would efficiently resolve the uncertainty?**

Two concrete regression-oracle gaps survived source review and directed
experiments:

1. **Successful slow polls must activate load shedding and recover.** The
   existing RPC suite accepts a fault that discards slow successful samples.
   Strengthen that integration assertion before adding another helper/model.
2. **The SDK signing path must stop after a partial index-filter failure.**
   The existing host test and SDK source-spelling guard accept an SDK-only
   fault. Exercise that specific staging boundary.

Current code passes both research probes. These are demonstrated weaknesses
in regression protection, not demonstrated production failures. A third,
conditional need is current-artifact load qualification before attaching old
numerical forwarding results to changed code. Details and rejected candidates
follow; the full current disposition map is in [contracts.md](contracts.md).

## Method

1. Freeze current code independently of the older, dirty development checkout.
2. Export every tracker issue and all its issue comments. Screen all issues,
   because labels omit early defects and security and test reports.
3. Read every bug-labeled report and included defect candidate with its
   discussion. Separate a report's allegation, later triage, accepted design
   limitations, and current implementation. A closed report does not prove a fix.
4. Classify the artifact and mechanism. Treat a broad failure family as a
   family, not as one deduplicated root cause. A duplicate closure can also
   mean that complementary work was folded into another owner.
5. Work forward from consequential contracts, including quiet areas: source,
   actual assertion, tested artifact, preserved dependency semantics, gate,
   skip paths, executed revision, and existing disposition.
6. Challenge selected evidence with a small representative fault. Retain
   positive controls and rejected hypotheses. This is directed falsification,
   not a mutation score or a claim of exhaustive coverage.
7. Rank by consequence, the specific evidence weakness, exposure, and the cost
   of resolving it. Historical issue frequency informs attention; it is not a
   failure probability or a mandate to add tests.

The vocabulary and policy owner remains
[`test-approach.md`](../../developer/test-approach.md). This is a dated research
record, not a second policy. Security controls were examined following the
repository security-audit skill's gaps-first procedure. GPT-6-Luna assisted
with domain inventories and the historical census; the primary investigator
checked candidate claims and ran independent probes. Classification is an
analyst judgment and must remain distinct from verified code behavior.

## What the tracker can establish

The complete snapshot contains **788 issues**, **404 with the current `bug`
label**, and **1,418 issue comments** (644 on bug-labeled issues). All 404
bug-labeled issues are closed: 346 completed, 52 not planned, and six duplicate.
These are current tracker states, not resolution-at-discovery or reopen history.
The first issue is dated 2026-06-18; the first bug-labeled issue 2026-07-29.

Five UTC creation dates account for **231/404 (57.2%)** bug-labeled reports:
September 26 (77), September 27 (56), September 24 (39), October 1 (31), and
September 29 (28). This concentration is consistent with the named audit
bursts in those reports. Auditor hours, production exposure, and a stable
sampling protocol are unavailable. Rates over calendar time, a reliability
trend, and capture-recapture estimates of undiscovered defects are therefore
not supported. Shared auditors, shared code and repeated verification also
violate an independent-discovery assumption.

Issue labels are not artifact classes. At least **83** bug-labeled titles
explicitly start with test/CI-related prefixes under the recorded extraction
rule. Important unlabelled and security-labelled reports include #6, #15,
#129, #137, #138, #165, #168, #190, #191, #204, #239, and #663–#676.
Those observations justify screening the entire tracker rather than treating
404 as the population of product defects.

All 404 bug-labeled reports received full-body/discussion review. Screening
the other 384 issues added 62 included historical defect/evidence candidates
outside that label. Obvious documentation/planning items could be title-screened;
the per-row material reviewed is recorded in [history.json](history.json).
The retained classification assigned the 404 bug-labeled reports as follows:

| Report's primary subject, after discussion review | Rows |
| --- | ---: |
| Product behavior | 172 |
| Test, formal or verification credibility | 99 |
| Developer/release tooling | 69 |
| Documentation/contract clarification | 6 |
| Planning or umbrella | 5 |
| Unconfirmed, refuted or accepted policy | 53 |

These are analyst interpretations of historical reports, not independently
reproduced unique defects. A fixed report remains historical; an accepted
behavior can retain a product-behavior classification. The classifier's
`include_in_defect_history` decision is separate. Reassigning uncertain rows
would change those descriptive counts, but would not change the directly
observed failure of the two existing oracles.

Do not compute a unique-defect count by subtracting every duplicate closure:
#675 is folded into #662 despite explicitly describing a complementary
checker mechanism; #1010 is a diagnostic correction folded into the #986
force-stop fix. Conversely, #992/#997/#998 explicitly share #987's fetch
mechanism. Relationships need their own evidence.

Four recurring mechanisms guide the current investigation:

- **A fixture omits the production dependency:** absent `getent` (#218),
  jshn unset-state behavior (#312), BusyBox-awk version skew (#763/#879),
  and LuCI RPC unwrapping (#233/#243/#289/#1056). Preserve the dependency
  that can cause the failure; more host calls to a simplified fake add little.
- **A check cannot discriminate:** fake rendering (#138), a gate matching
  its own declaration (#443), sample-only mirror parity (#605/#765/#1246),
  lock/fairness model scope (#1245/#1265), and an unasserted default replay
  count (#1358). Trace the actual oracle and use a counterexample.
- **Individually covered transitions fail in combination:** pause/resolve
  (#602), rollback and later writes (#502/#618/#1245), cadence and cap
  policy (#428/#1241), or persistence and uninstall (#1165/#1240/#1278).
  Exercise the composed sequence at its observable boundary.
- **A result belongs to another artifact:** source overlays (#418),
  stale installation (#1197/#1311), and stale release/index selection
  (#495/#592/#1242). Preserve artifact identity and execution provenance.

These are mechanism families with multiple causes. They are deliberately not
counted as four root causes or pooled into a production risk score.

## Verified candidate: SDK index-filter failure detection

**Behavior:** A failed Packages-index filter must stop before compression or
signing, including when it already emitted nonempty partial output.

Current source has two implementations:
`scripts/lib/feed-publish.sh:477` (host) and `:587` (SDK). The ready-SDK
release branch selects the latter at `:675–677`. The CI-invoked host-suite test
`tests/feed-publish-copy-keys.test.sh:106–119` injects partial output/exit 2
into the host path. Its SDK coverage at `:15–20` checks source spelling and
the number of filters. The existing security ledger already names the SDK
branch as unproved (`docs/developer/security-review.md:1229`).

Directed experiment:

| Variant | Existing test/source checks | Relocated SDK shell, partial output + exit 2 | Compression/signing sentinel |
| --- | --- | --- | --- |
| Current source | Pass | Exit 2 | Neither reached |
| Deliberately accept SDK grep exit 2 | Pass | Exit 0 | Both reached |
| Current or faulty source, valid index | Pass | Exit 0 | Both reached |

The fault changes only the SDK filter to accept exit 2. It preserves the two
filter lines and passes the existing source guard. This establishes a
**specific current test discrimination gap**. It does not establish a current
product or signing defect: the unmodified source aborts correctly in the probe.

Probe fidelity: the exact SDK inline shell body is extracted from current
source, its fixed `/feed/` paths are relocated to temporary storage, and it
runs under host `/bin/sh`. Index/signing tools are harmless stubs; the sign
result is a sentinel. No Docker daemon, SDK binary, real key, real signature,
or publication is exercised. A final boundary check should invoke the actual
SDK staging function through its Docker boundary, inject the failed filter,
and assert no signing invocation or publishable index. The host-only probe
cannot prove container isolation or cryptographic validity.

## Verified candidate: slow successful polls must induce protection

**Behavior:** A successful slow poll must record overload, reduce the next
request, retain protection while slow processing continues, and recover with
healthy samples independently of poll spacing.

The helper has substantial existing evidence: the expected-value matrix in
`tests/fwlive-adaptive-cap.test.sh`, repeated T1–T3 helper trajectories, and
the formal policy model. The actual RPC suite checks failed reads/filters,
missing counts, and healthy/unavailable clock cases. However, its seeded-hot
failure checks do not establish induction from a successful slow request.
The healthy clock examples at `tests/fwlive-rpcd-security.test.js:1057–1087`
use zero or 10 ms duration. Their assertions cannot detect dropping slow
successful measurements before the helper sees them.

The research probe runs the shipped rpcd entry, filter, classifier, adaptive
helper, real matched 24.10 jshn, and host BusyBox ash. It controls the clock,
stubs logd with one valid packet and substitutes only jsonfilter's array
enumeration. Four 900 ms samples followed by five 20 ms samples produce:

| Variant | Existing RPC suite | Observed request caps at both 1 s and 5 s cadence |
| --- | --- | --- |
| Current source | Pass | `2000,250,250,250,250,500,1000,2000,2000` |
| Drop successful samples ≥800 ms before recording | Pass | `2000,2000,2000,2000,2000,2000,2000,2000,2000` |

The fault is confined to rpcd orchestration; existing helper tests continue
to exercise an unchanged helper. The current source writes a hot state after
the first slow poll; the fault writes no state. This is a concrete missing
integration oracle. The supplied experiment does **not** claim that the
entire repository suite passes the mutant; the exercised existing suite is
the complete RPC security suite with its separately invoked logging suite
omitted using the normal runner environment variable.

The unmodified implementation passes this new research check. It supplies
fresh finite host evidence during this investigation; the missing part is
durable CI regression protection at the integration boundary. Extend an
existing RPC test with one slow-success induction and recovery sequence.
Keep the shipped helper/filter/classifier, explicit expected caps, state and
reply fields, a failed-sample control, and both cadence values. Another
standalone helper test would not exercise this fault.

This is controlled service-time input, not a performance measurement: one
real packet is classified, while the clock supplies 900/20 ms. It does not
prove native jsonfilter, logd, elapsed runtime, router scheduling, or packet
forwarding. The first scratch attempt also demonstrated a fixture problem:
its group-writable nested state directory was correctly refused by the real
writer. The corrected probe uses a private `0700` directory and requires the
baseline expected sequence before interpreting the fault.

## Current-source load qualification is a separate uncertainty

The seven retained #1134 five-pair virtual 10 Gb/s cohorts are credible for
their exact `8cafd441696449293b75cff1d71d22598fa83983` artifacts. The adaptive
policy subsequently changed in #1275, and the generated classifier/summary
and view also changed. No post-#1275 installed forwarding/pressure run was
found in the supplied checkout, 788-issue discussion snapshot, or 574 PR
metadata/body snapshot. External or unrecorded work was not inventoried.

Recomputation from all seven compressed paired reports reproduces their
published medians. All median gates pass. In the 25.12 cohort, one of five
pairs has a ping-standard-deviation ratio **7.3696**, although its cohort
median is **0.9286**. These are descriptive results from a shared, controlled
virtual setup. Five short pairs are not independent production samples or
adequate tail-latency qualification; pooling all 35 pairs across different
configurations would obscure that boundary.

The active LuCI viewer requested 400 raw lines; the separate direct backend
pressure experiment requested 2,000. Pressure recovery followed an explicit
logd drain. Do not describe either result as complete log capture, general
recovery when traffic stops, physical 80 Gb/s capacity, or current-source
numerical performance. The owner's 80 Gb/s/64-core deferral remains valid.

If a current numerical forwarding claim is needed, run one representative
current-artifact paired-viewer configuration plus the existing pressure and
explicit-drain recovery probe. Retain source/package hashes, achieved rate,
raw per-pair tails, poll/response parsing drain, and actual requested/served
work. No broad platform or hardware matrix follows from this investigation.

## Rejected or narrowed candidates

| Candidate | What checking the evidence showed | Disposition |
| --- | --- | --- |
| IPv6 resolver has only helper-level parsing tests | `tests/fwlive-jshn-compat.test.py:88–103` drives the shipped resolver with distinct IPv4 and two IPv6 reply styles and asserts exact maps and lookup arguments, for three real matched jshn pairs | Existing focused evidence is credible. Current test passes all three pairs; deleting IPv6 addresses only in the lookup loop fails at the exact correlation assertion |
| Late hostname reply after disposal can pass existing checks | Removing only the post-await generation fence is rejected by the existing `testPagehideDuringHostnameResolution` cache oracle | Retain existing regression; no additional test justified by this fault |
| #1351 proves ordinary Clear/repeated-nonempty-window staleness at current master | A current-source sequence with old row A, Clear, newer row B, then repeated `[A,B]` keeps one row, refreshes receipt time and shows no empty hint. A true empty reply shows the hint. An artificial later `[A]` window can manufacture it, but its reachability after B is unestablished | Do not promote the stale/dirty-tree report to a current defect |
| #1359 D4 refresh-failure notice is unasserted | Current logging-toggle and Layer 2 tests assert the last-known-state message; the final issue comment refutes the opening allegation | Reject |
| No version-changing APK lifecycle evidence exists | #848 and `docs/evidence/issue-848-2026-09-27.md` record a real 25.12.5 `0.1.43-r1 → 0.1.44-r1` transition preserving baseline/log state | Reject blanket claim. A current-source combined upgrade-then-uninstall fault sequence would be a narrower, separate fidelity question |
| Green formal jobs might only be skipped at this pin | Exact-SHA Actions job records show TLC, concrete rollback replay, induction, and Quint/model-implementation checks actually executed successfully | Do not reuse the older #1360 pin's skipped-job observation |

## Interpretation limits

Credibility is contract-specific. Implemented assertions, executed assertions,
workflow invocation, merge enforcement, historical installed artifacts and
universal proof are distinct. In the exact-SHA host log, fresh POT extraction
is explicitly skipped; the matched-jshn suite separately executes three real
release pairs. A generic selftest's missing-jshn message does not erase that
separate execution. Current branch protection has no required checks/reviews;
that known process question remains owned by #1190.

Accepted helper lifetime, privileged UCI commit/revert races, and hostname
first-attempt starvation are not automatically test gaps. Some stronger
guarantees are deliberately absent or known false. A new assertion cannot
supply a product guarantee that has not been chosen.

## Reproduction and retained inputs

- [Compressed complete issue/discussion snapshot](tracker-snapshot.json.gz),
  [analyst history ledger](history.json), [computed accounting](summary.json),
  and [file/hash manifest](manifest.json).
- [Exact-pin CI execution metadata](execution.json), with compressed
  [host](baseline-host.log.gz), [TLC/replay/induction](baseline-tlc.log.gz),
  and [Quint](baseline-quint.log.gz) logs. Package-build execution remains
  conditional on the packaging path decision; a successful job alone does
  not establish every build or downstream installed seam.
- [Slow-poll probe](experiments/probe-poll-induction.py) and
  [results](experiments/poll-induction-result.json), including actual ubus
  line arguments, state, reply fields and existing-suite stdout/stderr.
- [SDK-shell probe](experiments/probe-index-filter.py) and
  [results](experiments/index-filter-result.json).
- [Clear/resolver-fence probe](experiments/probe-clear-resolver.js) and
  [results](experiments/clear-resolver-result.json); IPv6 resolver-loop
  [probe](experiments/probe-resolver-ipv6.py) and
  [baseline/fault result](experiments/resolver-ipv6-result.json).
- [Paired-data recomputation](experiments/recompute-load.py) and
  [results](experiments/load-recomputed.json); original raw load data remains
  owned by `lab/forwarding-slo/2026-10-02-highrate/`.
- [Independent reviews and limitations](independent-review.md). One reviewer
  reproduced the slow-poll experiment independently, and revised its initial
  lower-priority assessment after seeing the surviving fault.

The record's code and test baseline is `9fd99d69652c8ff951a54832cd9421eba8bb192e`.
The commands below are intended to run against that source tree. After the
repository advances, create a detached worktree at that pin and copy this
evidence directory from the archival commit into it before running the probes:

```sh
git worktree add --detach /tmp/fwlive-behavior-source 9fd99d69652c8ff951a54832cd9421eba8bb192e
git archive c9ae965a30fd5c9ebf2491e715371b4efe738552 docs/evidence/behavior-assurance-2026-10-21 | tar -x -C /tmp/fwlive-behavior-source
cd /tmp/fwlive-behavior-source
```

From that repository root, accounting can be reproduced without network access:

```sh
python3 docs/evidence/behavior-assurance-2026-10-21/analyze.py
```

The probes run on the pinned checkout and use temporary source copies:

```sh
python3 docs/evidence/behavior-assurance-2026-10-21/experiments/probe-index-filter.py
python3 docs/evidence/behavior-assurance-2026-10-21/experiments/probe-poll-induction.py
node docs/evidence/behavior-assurance-2026-10-21/experiments/probe-clear-resolver.js
python3 docs/evidence/behavior-assurance-2026-10-21/experiments/probe-resolver-ipv6.py
python3 docs/evidence/behavior-assurance-2026-10-21/experiments/recompute-load.py
```

The slow-poll experiment requires the already-installed matched 24.10 jshn
pair under the maintainer's cache, host BusyBox and Node. The IPv6 regression
probe requires matched 23.05, 24.10 and 25.12 jshn pairs plus host BusyBox.
Neither probe installs prerequisites. A missing-awk diagnostic is retained
from the RPC suite's isolated tool-path case; both existing-suite invocations
exit 0. The separate logging shell suite is not rerun by that RPC probe.

Captured temporary workspace names are normalized in the result files; test
outcomes and useful assertion/diagnostic text are retained. Paired-data
recomputation keeps source hashes, source revisions and workload metadata,
omitting only the original temporary console-log path from its derived JSON.
The tracker archive contains the public repository's issue and comment records
available through its public tracker API. A separate search covered 574 PR
metadata/body records; those PR records are not included in the archive.
Private advisories are outside the supplied census. No credentials or private
advisory material are part of this record.

## Scope and stopping decision

This pass accounts for all tracker issues and comments in the snapshot, full
review of every bug-labeled report, current high-impact contract dispositions,
actual CI execution, and independent challenges of the strongest candidates.
PR metadata/body records were searched for later load evidence. Inline-only
PR findings, private advisories, undocumented lab work and unreported user
failures are outside the historical census. No exposure denominator exists.

The next implementation investment is the two existing-test extensions above.
Reassess their detection value after they land. A current-source numerical
load claim or a package-hook change can justify the named focused installed
checks; the history does not justify blanket formal expansion or a platform
matrix. Accepted residuals keep their existing owners and reconsideration
triggers. This research supplies finite evidence and test priorities, not
release approval or a complete census of undiscovered defects.
