# Code-quality audit — 2026-10-01

Baseline: `20c6ef541cfec12bf95f32cd646c0a55178caaac` (v0.1.49). The orchestrator reused the same three GPT-6-Luna/xhigh domain reviewers after their security passes for a separate source-first quality review. Lenses were correctness, error/recovery paths, state/lifecycle, performance/resource cost, compatibility, package/build behavior, generated parity, model fidelity and test discrimination. Existing issue text was consulted for deduplication after source assessment rather than accepted as proof.

The inventory accounted for all 389 tracked paths, including current executable/product/tooling/test/configuration paths. The product has no native per-SoC binaries. Historical measurement data/screenshots and design mockups are outside production acceptance; the orchestrator also inspected prototype JavaScript and its static DOM wiring and found no additional consequential candidate. Translation extraction/format was verified, not linguistic correctness. Detailed source and test inventories are retained in protected local evidence.

No production or test fixes were implemented. Audit-only ledger/model evidence corrections and a safe audit record are local to the detached checkout; the original workspace is unchanged. No merge, release or deployment occurred during the audit.

## Newly filed quality findings

| Record | Finding / impact | Independent evidence |
| --- | --- | --- |
| [#1097](https://github.com/lucas-albers-lz4/fwlive/issues/1097) | Artifact-only same-version opkg installation can exit 0 with package files missing and RPC unavailable. Medium lab/developer availability and false-success impact. | Tooling + frontend traced preclear versus prerm; orchestrator reproduced with current 0.1.49-r1 on native 24.10. Files/RPC absent after restart; disposable fixture subsequently restored. |
| [#1098](https://github.com/lucas-albers-lz4/fwlive/issues/1098) | Low smoke portability defect: util-linux denied-open status 66 is rejected even though the lock control holds. | Native denied-open plus original false failure; backend provider-status review and tooling copied harness preserving negative controls. |
| [#1099](https://github.com/lucas-albers-lz4/fwlive/issues/1099) | Output-directory data-loss protection enhancement. Potential Medium operator impact; replacement of generated output is intentional, so destination policy needs review. | Tooling intercepted the exact deletion request for a synthetic sentinel directory; frontend and orchestrator independently reviewed argument/overwrite semantics. No real destructive target. |

Each issue contains source location, evidence and a next step; each received a separate independent recheck comment. Security hardening findings #1095 and #1096 are covered by the separate security audit. No duplicate issue was created for an already tracked mechanism.

## Existing issues independently reassessed

- **Confirmed behavior with policy/target-impact limits:** #1060 static classifier validation repeats per line and evaluator loses short-circuit; paired Node classifier cost increased roughly twofold, but router/user magnitude was not measured. #1069 returned rule-map errors bypass the retry branch; choose transient-error policy before changing retries. #1071 IPv6 uppercase substrings fail source/destination filters while Quick search folds case. #1073 can perform one additional startup poll when the first completes before startup enrichment; no data loss observed.
- **Confirmed operational behavior:** #1066 FIFO logging lock can block before flock but requires a root-controlled path. #1068 safe adaptive lock failure silently preserves stale state. #1090 privileged home-path deletion guard exception independently confirmed; comment added. #1084/#1088/#1089 QEMU PID/fallback/status behavior was rechecked by tooling. These remain their existing records.
- **Test-fidelity/diagnostic gaps:** #1058 resolver-name correlation and deliberate feed-index failure injection; #1061 unbounded child calls in part of the RPC suite; #1062 budget-probe argv mismatch; #1065 root-specific permission fixture; #1075 exact refresh count; #1076 native stalled-ubus behavior; #1077 timeout-absence marker does not reach the successful filter path; #1078 manual loader dependency parity; #1079 built dependency-metadata coverage; #1081 raw regex TypeError. Current runtime behavior and successful host tests do not close these gaps.
- **Contracts/non-findings needing review before a fix:** #1070 reservation survives a nonpainted epoch-drop by its explicit API/test contract and is consumed/canceled by its owning row-limit operation. Its isolated callback does not establish orphaned intent; independent comment added. #1072 dead expression has unchanged behavior. #1074 missing tbody also failed the former full-render path and depends on external DOM mutation. #1080 intentionally caps test child runtime; no current consumer needs more. #1083 has a test-only defensive fallback. #1085 manual TLC is an owner-documented release policy. #1086 mirrors accepted direct-helper limits; #1087 is manual-tool timeout/preflight ergonomics.
- **Fixed at audited baseline:** #1055 summary refresh, #1056 LuCI positional RPC argument mapping and #950 hostname generation/disposal gate. Issues were not closed by this audit.

These are dispositions for another implementation review, not blanket approval to implement every tracker proposal. The retained domain reviews distinguish mechanism confidence from severity/product expectation.

## Validation

The full baseline passed with fresh POT extraction 227/227 and zero runner-level
gate skips; per-suite skips and stubs remain distinct. Generated/parser parity,
mocked-services browser checks and matched real jshn on all three supported
release lines passed. Fresh x86 SDK artifacts for 23.05.5 IPK, 24.10.8 IPK and
25.12.5 APK had inspected payloads and repeated clean bit-identical builds.
Selected host fixtures used native guest jsonfilter (hybrid dependency proof);
installed 24.10/25.12 nft/log/filter, ACL and uninstall checks separately tested
native package seams. APK same-version reinstall preserved state. Local signing
used dummy keys, with no live publication. All seven TLC configurations reached
expected outcomes: four without invariant violations, including one counterfactual
timed-safety configuration, and three named counterexamples. The full bounded
Z3/parity suite passed. These are finite/model checks, not code-equivalence,
all-length regex or whole-call runtime proofs.

Frontend separately reran scheduler/coordinator/budget/cache/parser/keyed-table/hostname/error/RAF/codegen/CLI/E-harness/module/diagnostic tests; all exited 0. Backend separately reran adaptive/logging-lock/package-lifecycle/RPC suites under uid 1000; all exited 0. Tooling reran security-gap, upstream-cut, artifact-mode and QEMU lifecycle harnesses; all exited 0. Passing existing tests while the native installer and rc66 defects remain demonstrates the identified fixture gaps, not a clean bill of health. Broad additional ShellCheck warnings were reviewed without filing behavior-free lint findings.

No fresh 23.05 installed guest, armsr/hardware, target-device performance measurement, forwarding load soak, exhaustive browser/theme/accessibility matrix, concurrent-worker saturation, hung native logd test, or version-changing APK upgrade was performed. Host/source evidence and installed seams are distinct. The original native security-gap helper failed and remains tracked; the adapted proof is labeled as scratch-only. Installed 24.10 browser recovery/hostname/pause/filter/leave/revisit checks passed; an initial bootstrap uci.get access-denied pageerror was logged, so a globally error-free page is not claimed.

## Evidence retention and next step

Detailed frontend/core, backend and tooling reviews, the path inventory, paired
classifier benchmark, same-version native reinstall logs and other command
records remain in access-restricted audit evidence retained by the maintainers.
Private advisory evidence
is excluded from this public report.

Findings await review before implementation. This report records the audited
baseline and does not close any finding.
