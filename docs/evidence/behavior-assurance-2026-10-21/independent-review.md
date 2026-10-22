# Independent research reviews

# Independent synthesis challenge: index-filter probe and draft report

Reviewed `experiments/probe-index-filter.py`,
`experiments/index-filter-result.json`, and `README.md`. This was a
read-only review; I did not edit or rerun the probe/report and did not invoke
Docker, SDK tools, or the full suite.

## CONFIRMED

- **The filter-oracle discrimination result is technically valid.** The probe
  mutates only the SDK's double-quoted `grep` command by appending an `||`
  clause that accepts exit 2 (`experiments/probe-index-filter.py`).
  That append is on the same physical line; its source-copy control passes the
  existing two-filter/source-spelling checks both before and after mutation
  (the retained probe and `experiments/index-filter-result.json`). The inspected
  test counts two filter lines (`tests/feed-publish-copy-keys.test.sh:15-20`)
  and actually injects partial-output/exit-2 failure only through the host
  helper (`:54-119`). Thus the mutation is not caught by that suite.
- **The extracted shell experiment exercises meaningful failure ordering and
  has a positive control.** It extracts the inline SDK body, relocates `/feed`
  mounts into a temporary directory, and executes under host `/bin/sh -ec`
  (`experiments/probe-index-filter.py`). With a valid index both
  variants compress and reach the usign sentinel (`experiments/index-filter-result.json`).
  With partial output and grep status 2, baseline exits 2 before either
  sentinel, while the mutant exits 0 and creates both (`:28-37,49-59`). This
  proves this exact source-level mutation bypasses current test coverage; it
  does not prove a production failure.
- **The draft states the important fidelity limits accurately.** It says the
  shell ran on host `/bin/sh`, used stub tools, did not invoke Docker or real
  signing, and recommends a Docker-boundary proof (`README.md:101-108`). The
  result supports the narrow conclusion “current test discrimination gap,”
  not a current product/signature defect (`:96-108`).
- **The relevant historical issue does not disprove the current candidate.**
  #821's body/comments concern the old host and in-container `|| true` behavior
  and record the `#859` change; the present SDK staging inline shell at
  `scripts/lib/feed-publish.sh:615-638` is a distinct current path. The
  security ledger expressly leaves that path unproved
  (`docs/developer/security-review.md:1227-1229`).
- **Snapshot headline counts checked directly against the supplied files.**
  `tracker-snapshot.json.gz` has 788 issues and 404 `bug` labels; all 404 are
  closed with 346 `completed`, 52 `not_planned`, and six `duplicate` state
  reasons. The same retained snapshot has 1,418 comments overall and 644 on
  those bug-labeled issues. This confirms the draft's corresponding figures
  (`README.md:47-51`).

## FOLD

These findings describe the in-flight draft reviewed at the time. The durable
probe links and evidence-scoped wording were added before publication.

- **Clarify “required test” at `README.md:82-84`.** The test is included in
  `scripts/fwlive-test.sh:293`, which `.github/workflows/fwlive-test.yml:49`
  invokes. However the report later says there are no branch-protection
  required checks (`README.md:128-129`). Say “host-suite test” or “CI-invoked
  host-suite test” so readers do not infer merge enforcement.
- **Link the probe artifacts from the evidence section before calling the
  report final.** The specific result is currently only exposed as a
  `.analysis` scratch script/JSON, while the draft's remaining-artifacts
  placeholder says they will be linked later (`README.md:136-138`). A final
  retained record should identify the exact script and result, or copy the
  minimal result into a retained evidence artifact. The in-flight status makes
  this a completion item, not a defect in the current working draft.
- **Keep the title/heading scoped as evidence assurance.** “Verified
  candidate” at `README.md:75` is defensible because `:96-99` explicitly
  limits it to a verified test gap. Consider “Confirmed evidence gap” to avoid
  an at-a-glance reading that this is a verified signing/product defect.

## DISMISS

- **“The mutation changes only the SDK filter and preserves the two filter
  lines” is supported.** The exact needle occurs once in the source, only in
  the SDK double-quoted command; host filtering uses different single-quoted
  text (`scripts/lib/feed-publish.sh:500,628`). The mutation adds no newline,
  and the unchanged source guard passes its count of two (`tests/feed-publish-copy-keys.test.sh:15-20`; result JSON lines 9-14).
- **No claim of actual cryptographic, Docker, or publication validation is
  made.** The signature file is a stub-generated control artifact, explicitly
  called a sentinel (`README.md:90,101-108`), not an authentic signature.
- **The remaining rejected-candidate dispositions do not contradict the
  reviewed evidence.** The Clear probe distinguishes ordinary repeated
  `[A,B]` from empty and synthetic old-only windows as described at
  `README.md:116`; the current `#1359` final comment refutes D4 and the cited
  last-known-state assertions exist at this pin (see the linked current test
  references in `README.md`, “Rejected or narrowed candidates”).

## Conclusion

The SDK index-filter item is a concrete, narrowly scoped assurance gap with a
discriminating fault, valid-index positive control, and honest fidelity
boundary. It should not be represented as a current product/signing failure.
Before publication, remove the “required” ambiguity and replace the final
artifact placeholder with durable links.


# Independent review: current load evidence and APK upgrade/uninstall

Checkout reviewed: `9fd99d69652c8ff951a54832cd9421eba8bb192e`. This is a read-only audit. I did not run tests, start QEMU, install tools, or modify product/test sources.

## Conclusion

The narrow absence claim is supported: the retained installed forwarding/pressure evidence is from the pre-#1275 product revision, and I found no post-#1275 installed load run in this checkout, the 574-PR metadata snapshot, or the 788-issue/all-comments snapshot. State this as a bounded search result, not as proof that no run or external artifact exists anywhere. The PR snapshot is issue-style metadata/body data and does not inventory every Actions artifact or every external lab attachment.

That absence does **not** mean the current adaptive policy has no behavioral oracle. The production adaptive helper has table-driven per-step characterization and repeated cadence trajectories; the production rpcd poll entry has focused one-call success/error/clock integration checks under dash and BusyBox. Together with the formal model, these are meaningful compositional host evidence for the policy contract. A multi-step rpcd trace would strengthen cross-layer confidence, but current evidence does not support calling it a high-priority missing product oracle.

A current installed 10-Gb/s forwarding/pressure run is needed only if the intended claim is that the old numerical forwarding result describes current HEAD. It is not a necessary release gate merely because #1275 changed the policy. Keep #1134's measurements attached to their exact old artifacts and workload; do not restate their performance numbers as current-source results. The owner explicitly closed #1134 for the bounded tested workload and deferred 80-Gb/s/64-core work; no new performance regression report or deployment requirement was found in the supplied history.

The current APK version-changing upgrade-then-uninstall sequence is a real but smaller evidence gap. It would combine two already-tested lifecycle transitions on the current package. It is useful as a targeted release smoke, but I find insufficient evidence to rank it high priority absent a package-hook change or a failure report. Existing proofs make its expected behavior reasonably compositional.

## Load evidence: what is and is not established

- `lab/forwarding-slo/2026-10-02-highrate/provenance.json:2-15` identifies product source `8cafd441696449293b75cff1d71d22598fa83983`, development build `0.1.50-r1`, and artifact hashes. `README.md:8-24` says those exact rebuilt packages were artifact-only installed and helper hashes checked; it explicitly says they are not published release artifacts.
- The five-pair 10-Gb/s results and pressure/recovery details are scoped in `lab/forwarding-slo/2026-10-02-highrate/README.md:38-52,54-89,99-127`. They passed recorded median gates under one shared virtual test host. The same README retains the 7.37x ping-SD tail (`:85-89`) and says pressure recovery followed explicit logd drain (`:122-127`). This is valid historical evidence for that package/configuration, not a current-source or physical-capacity claim.
- PR #1145 describes the lab-only evidence as product source `8cafd441` and 10-Gb/s virtual cohorts. PRs #1143–#1145 change harness/evidence, not the product used for these runs. Issue #1134's owner decision closes the bounded work and defers larger 80-Gb/s/64-core qualification; the retained report is not invalidated by later source changes, but its scope does not expand.
- PR #1275 in the retained tracker snapshot changes the adaptive policy to a sample-sequence state machine, deletes elapsed-time cooldown/probe windows, and adds TLA arms, trajectory tests, and per-step characterization. Issue #1241 records the old 1-second-vs-5-second poll oscillation and says the correction landed in #1275. This is a material policy delta after the load baseline.
- The product source diff from the 8cafd run to this checkout changes `fwlive-adaptive-cap.sh`, `rpcd/fwlive`, generated `fwlive-is-firewall-event.awk`, `fwlive-logging.sh`, classifier JS/core, and renderer/view assets. `fwlive-log-filter.sh` itself is unchanged. In addition to #1275, summary normalization/classification work changes measured per-poll processing cost; therefore old exact poll durations/cap/recovery points and forwarding medians do not numerically qualify current HEAD. This is no evidence of regression.

## Current host proof is compositional, not absent

- `tests/fwlive-adaptive-cap.test.sh:107-152` checks the sample-sequence hot hold and first healthy probe; `:561-650` begins the table-driven `fwlive_adaptive_compute_limit` expected-value matrix.
- `tests/fwlive-adaptive-trajectory.test.sh:16-42` sources the shipped helper, controls the clock, and repeatedly calls production `plan`/`record`; `:71-123` compares sustained and overload/recovery traces at 100cs and 500cs; `:125-157` checks plateaus; `:159-205` checks monotonicity. T1 is cadence equality, while the per-step matrix supplies expected values. The fidelity note was corrected in #1307 to avoid claiming the trajectory test equals the formal model or pins a particular plateau.
- `tests/fwlive-rpcd-security.test.js:893-935` runs shipped rpcd `poll` and `resolve` paths with seeded hot state and checks failed-poll preservation; `:938-1022` runs shipped poll/filter failure paths; `:1024-1094` copies the shipped plugin/helper/filter/classifier, substitutes clock and jsonfilter dependencies, and exercises the real poll entry under dash and BusyBox. `:1096-1173` checks missing `messages_received` is unhealthy and a valid empty reply can record. These are integration checks, but they do not run a repeated 100cs-vs-500cs state trajectory through rpcd.
- `docs/developer/security-review.md:193-199` explicitly calls #1275 proof host per-step and cadence-equal trajectory coverage. Its guarantee table at `:1150-1164` lists the adaptive helper, successful reply/error contracts, hot-shed and resolve behavior as host proof. The later security-review entries at `:2233-2249` separately say installed clock/read behavior is not established by those host fixtures.

**Assessment of the proposed additional host trace.** The current-load note correctly identifies what a repeated rpcd trajectory would add: it would prove that production poll orchestration composes `plan`, measured duration, `record`, state persistence, and reply fields over multiple requests. But it overstates the evidence gap if described as “the highest-value changed contract” with no existing integration coverage. Helper-level test is repeated and exact; rpcd tests establish its current entrypoint, reply fields, measured clock seam, success-only recording, and error preservation. The smaller gap is *repeated cross-layer cadence parity*, not missing adaptive behavior coverage generally.

If an explicit acceptance is desired, the smallest useful addition is one current-shipped-rpcd test harness running the same deterministic hot-then-healthy sequence at two inter-poll cadences. Stub the logd/clock boundary, keep the shipped filter/classifier and adaptive helper, and assert per-step `(requested_lines, effective_limit, shed/truncated, messages_received, controller state)` against an independently written expected trace. Include a successful healthy post-drain path and one failed read/filter that must not advance state. This test is a modest confidence improvement, not evidence of real OpenWrt scheduling or forwarding impact. Do not duplicate the complete helper matrix.

If a **current numerical forwarding/load** statement is required, host policy tests cannot supply it. A single current-artifact 24.10.8 x86 KVM 10-Gb/s paired viewer run plus a 2,000-line induced-pressure/recovery sequence is a defensible targeted lab check. Keep the ordinary UI Auto request (currently 400 raw lines for the 100-row budget) separate from the explicit 2,000-line backend pressure request, as current-load-evidence.md already cautions. Retain per-pair tails and raw artifact identity. This should be conditional on a need to reuse current performance numbers; it should not grow into all seven cohorts, physical 80 Gb/s, or a platform matrix.

## Bounded search for later installed evidence

I reviewed the retained report/provenance, current package/test/security-review paths, all 574 supplied PR metadata/body records (including relevant #1134/#1275/#1241 entries), and issue bodies/discussions for the load/adaptive topics. The exact highrate artifacts remain pinned to `8cafd441`; #1275 adds host/formal proof, and no later PR/issue discussion in these snapshots reports an installed forwarding/pressure run against a post-#1275 package. Later installed proofs in the ledger are about other seams/source revisions. This supports “not found in the supplied record,” not an absolute claim about external attachments or undocumented work.

## Current APK upgrade → uninstall idea

There is a straightforward compositional proof chain, plus an acknowledged residual:

- The current package hook is in `openwrt-feed/luci-app-fwlive/Makefile:25-61`. It skips restoration when `PKG_UPGRADE=1` (`:41`), treats version-changing APK upgrade as post-upgrade-only (`:37-40`), and invokes baseline restore on uninstall (`:56-60`). Current package version is 0.1.55 (`:14-15`).
- Real version-changing APK behavior was observed on 25.12.5/APK 3.0.5 in `docs/evidence/issue-848-2026-09-27.md:10-44`: 0.1.43-r1 → 0.1.44-r1 ran only new `post-upgrade`, preserved `log=1` and the baseline marker, and did not run `pre-deinstall`. The document says explicitly this is not a defect (`:46-58`). This is an older package pair and did not continue through uninstall.
- Real 25.12.5 APK uninstall restoration and same-version `--force-reinstall` preservation were separately observed in `docs/evidence/issue-389-2026-09-20.md:45-74`. The current `scripts/qemu-logging-uninstall-smoke.sh:130-149` performs the same-version APK reinstall then `apk del` with baseline assertions; its current artifact is explicitly pinned through `:66-84`. The host lifecycle matrix tests the current hook's uninstall/versioned arguments and `PKG_UPGRADE=1` path in `tests/fwlive-package-lifecycle.test.sh:191-257,404-430`.
- The exact current-source limitation is recorded in `docs/developer/security-review.md:1071-1072,1140`: “New APK transition proof remains unexecuted”; APK runtime verification was not repeated for the later 24.10 disable-retirement delta, while the fresh installed follow-up was IPK.

A current-artifact old-version→new-version→uninstall QEMU sequence would close the package-version composition gap and make a good focused release/lifecycle check: start with previous supported APK, enable logging and verify marker; upgrade to current 0.1.55 APK and assert the bit/marker persist plus post-upgrade ran; `apk del` and assert saved baseline is restored and marker is gone. However, the two hooks involved are already separately exercised: the real package manager transition is proven on 25.12, current artifact uninstall/reinstall is covered by the current smoke when run, and the current generated package hook/metadata matrix is covered on host. No issue or PR reports a failed version-changing transition. I would rank this as useful medium/low lifecycle evidence, not a high-priority defect or a prerequisite to the adaptive-load assessment. Raise it if APK hook/package metadata changes again or an actual upgrade/uninstall report appears.

## Corrections to carry into the ranked recommendations

1. Keep the no-post-#1275-installed-run conclusion, bounded to supplied evidence; do not phrase it as an unqualified universal absence.
2. Say helper + RPC test layers provide substantial compositional host proof. A repeated RPC cadence trace is optional/incremental, not the lone oracle for current policy.
3. Separate code-behavior confidence from performance qualification: current-source pressure/forwarding evidence is required only to transfer #1134's measured numbers to current HEAD. Retain #1134 as historical proof and honor the owner's deferral of broad/physical qualification.
4. Treat current APK upgrade→uninstall as a small, concrete integration follow-up because the ledger openly records it unexecuted, but rank below a demonstrated defect and below a demand to substantiate current numerical performance.

## Addendum: successful slow-poll induction is a demonstrated test blind spot

I inspected `experiments/probe-poll-induction.py` and its retained result, then independently reran a temporary copy that redirected output away from that result file. The rerun exited 0 and reproduced all six RPC-suite outcomes: the existing suite passed on both baseline and mutant, while the controlled poll probe matched its baseline trace and distinguished the mutant at both 100cs and 500cs. I removed the temporary script/result afterward; no product or test source was changed. The suite emitted a non-failing `awk: not found` stderr warning from the plugin's CLI self-test in both variants. `FWLIVE_LOGGING_VIA_RUNNER=1` omits the separate shell logging suite, so this is not a claim that every repository test passed under mutation.

The probe isolates one plausible orchestration regression: production `rpcd/fwlive` calls `fwlive_adaptive_record` only after a successful filter and valid nonzero ordered clock readings. The mutant skips that call when the measured successful poll is at least 800ms. The fixture runs the actual poll entry, adaptive helper, filter, generated classifier and 24.10 jshn; it stubs `ubus`, `jsonfilter`, and only the clock seam. Its one-entry DROP payload is enumerated by a strict jsonfilter fixture, and the injected start/end centiseconds make each poll's measured duration deterministic (`experiments/probe-poll-induction.py`). Four 900ms successful polls induce hot state, then five 20ms successful polls recover. Both 100cs and 500cs schedules produce `[2000,250,250,250,250,500,1000,2000,2000]` at baseline; the mutation stays at 2000 for every call. The output confirms the first slow poll writes hot/250 state and the following reply reflects 250; subsequent healthy calls progress the state to 500, 1000, and 2000 (`experiments/poll-induction-result.json`).

This changes the ranking from my earlier “modest optional composition improvement.” The missing assertion is narrower and more consequential than general repeated cadence parity: a successful slow poll must induce protective state for the next actual poll, and subsequent successful healthy polls must permit recovery. The helper trajectory test exercises the sequence by calling `plan`/`record` directly (`tests/fwlive-adaptive-trajectory.test.sh:16-42,71-123`), while the current RPC fixture tests valid clock recording but only for equal/forward values against seeded cold state (`tests/fwlive-rpcd-security.test.js:1024-1094`). It does not establish hot state from a successful slow poll. Existing RPC tests specifically protect hot state across failed poll/filter/clock paths (`:893-1022`) and validate missing-message health (`:1096-1173`), but none asserts this successful-slow path. The mutation passes that unchanged RPC suite (`probe-poll-induction.py:97-118`), directly demonstrating the gap.

I therefore recommend treating a focused slow-success induction/recovery RPC assertion as a high-value current host-test gap, with no claim that production currently has the defect. The counterfactual is a meaningful orchestration fault, not an artificial helper mutation: it bypasses an existing production record call while preserving the successful reply. The probe is an evidence experiment, not itself a tracked test yet. A small durable acceptance would put a repeated trace into the RPC test: use the shipped poll/helper/filter/classifier, inject a valid slow sequence then healthy sequence through the existing clock seam, and assert next-call `effective_limit`, `shed`/`truncated`, state bucket/limit, and recovery under both 100cs and 500cs cadence. Include a failed read or filter between valid samples if inexpensive, to retain the already established rule that failures do not advance the controller.

Scope limits: this controlled clock does not wait or measure service time; one fixed log entry means it validates policy plumbing and state transitions, not overload throughput, installed scheduling, 10-Gb/s behavior, or numerical performance. **Superseded observation from this initial review:** the first probe revision logged ubus arguments without comparing requested `lines` to `effective_limit`. The retained final script now asserts that relationship for each reply (`experiments/probe-poll-induction.py`), and its result records actual request lengths. The test should pin the exact success-reply semantics, not infer a real backlog from its fixed one-entry payload. The bounded absence of post-#1275 installed load qualification remains a separate issue: this host oracle improves confidence that the changed policy reaches the actual poll path but cannot transfer historical forwarding numbers to current HEAD.



# Final synthesis review

# Initial final research-tree review before resolutions

This subsection records the first review state, before the corrections below.
Its manifest and scope findings are historical and are resolved in the
following sections.

Baseline reviewed: `9fd99d69652c8ff951a54832cd9421eba8bb192e`.

## Findings

- **BLOCKER — stale manifest:** `docs/evidence/behavior-assurance-2026-10-21/manifest.json` lists `README.md` as 13,998 bytes with SHA-256 `5dfa5d08c82d486349993efb490b6c6a626687f0ef1dcbdcaf828a408ff5fb96`. The current README is 20,490 bytes with SHA-256 `f55ed4ff6b7b7eaf47c25bc22f2ef4a4042685d439c81e1f801fba9acf9fbfa1`. This makes the advertised file/hash manifest stale. I did not alter the research tree; regenerate the manifest after the README is final.

- **CONFIRMED — census arithmetic and review-material accounting:** `summary.json` agrees with the compressed snapshot and `history.json`: 788 issue rows, 1,418 comments, 404 current bug labels, 644 comments on those bugs, 392 included report rows and 62 included rows outside the bug label. Bug-label classes sum to 404 (172 product, 99 assurance, 69 tooling/release, 6 documentation, 5 planning, 53 unconfirmed). All 404 bug rows have `reviewed_material` metadata stating full body and all comments; none is marked partial/screened/excerpt/missing. The report correctly presents these as analyst historical classifications rather than unique/current defects.

- **CONFIRMED — slow-poll claim and prioritization:** README lines 181–213 and contracts.md line 25 match `probe-poll-induction.py` and its retained results. The current source reaches `2000,250,250,250,250,500,1000,2000,2000` at both cadences; the controlled mutant remains at 2000, while the tested RPC suite exits 0 on both variants. The probe checks actual logged ubus line arguments against reply caps (script lines 84–93), state, and response fields. It uses actual shipped rpcd/filter/classifier/adaptive assets, matched 24.10 jshn and host BusyBox ash, with controlled clock and stubbed logd/jsonfilter seams. It does not claim elapsed-time performance or a full repository-suite run. The dedicated existing RPC security suite is invoked with the documented logging-suite guard at `probe-poll-induction.py:120`; the separate logging suite is omitted and the README discloses this at lines 194–197 and 310–314. The retained `awk: not found` diagnostic is surfaced; the suite still prints its final OK and exits 0. The proposed integration assertion is the highest-value direct oracle improvement in this review.

- **CONFIRMED — SDK claim and boundary:** README lines 131–164 and contracts.md line 35 match `probe-index-filter.py` and results. The host/source guard passes the SDK-only mutation; the relocated shell probe distinguishes current source from the mutation under partial output plus exit 2 and records compression/signing sentinels. Its documentation correctly limits the result to host `/bin/sh`, relocated paths and dummy tools: it proves neither Docker behavior nor a real signature/publication. The suggested follow-up enters through the SDK staging boundary.

- **CONFIRMED — accepted limits and candidate rejections:** README lines 244–268 reject the specific #1351 ordinary repeated-window allegation using the current probe, while retaining the artificial old-only reachability caveat; it checks #1359's final refutation against current assertions; it rejects the IPv6 hypothesis based on the matched-jshn correlation test; and it preserves hostname fairness and helper bounds as accepted limits. Contracts.md lines 27 and 33 keep those limits distinct from missing tests. Load results remain attached to their exact old artifact and are not presented as current performance.

- **FOLD — manifest scope:** The manifest also omits `contracts.md` and `summary.json`, although README lines 272–274 presents it as a file/hash manifest for the retained record. At minimum the README hash mismatch must be fixed; decide whether those documents are intentionally outside its scope or should be included.

## Overall verdict

The claims and prioritization are substantively well bounded: no mutant result is described as a current defect, no host SDK stub is described as signing proof, and the slow-poll suite result is not inflated into a full-suite result. The stale README hash is the only factual artifact-integrity blocker found. Regenerate the manifest on final bytes, then rerun its hash check before treating the record as complete.


## Resolution of artifact-integrity finding

The manifest was regenerated after final report, contract-map, analysis summary, portable probes and review updates. It now lists every retained file except itself with current byte sizes and SHA-256. A full file-set/hash check passed. The portable probes were replayed successfully; explicit outcome assertions and actual ubus line-argument checks were added without changing the reported result.

## Resolution of initial wording and link findings

The report now distinguishes the CI-invoked host test from branch-protection
enforcement, links the retained probes/results, and keeps the heading scoped to
behavioral evidence. The temporary `.analysis` citations were replaced by
retained repository artifacts or bounded source references. The archive note
now says that issue/comment records are included and PR metadata/body records
were searched separately but are not part of the archive.
