# Security audit — 2026-10-01

Baseline: `20c6ef541cfec12bf95f32cd646c0a55178caaac` (v0.1.49). The audit used an isolated checkout of this commit; uncommitted workspace changes were excluded.

The orchestrator and three GPT-6-Luna/xhigh reviewers performed the user-requested from-scratch VVAH pass. Prior ledger outcomes supplied context and duplicate/accepted-risk checks, not fresh evidence. Static and deterministic checks preceded narrow mechanism/severity review. Candidate validation used another domain reviewer plus orchestrator source/runtime checks. No product fix, release, live feed publication, or advisory publication occurred. The same reviewers then performed a separate code-quality pass.

The inventory accounts for all 389 tracked paths: current product, build/release/lab/test sources and configuration; owner documentation; translation data; explicit historical evidence, screenshot, mockup and measurement exclusions. Generated shipped assets were reviewed and checked for freshness. Translation extraction/format was checked, not linguistic correctness. The detailed path inventory, 83-control reconciliation, domain reviews and command logs are retained in protected local evidence. This public report summarizes their results. “Full audit” describes source scope; it does not assert exhaustive behavior or platform certification.

## Findings and disposition

| Record | Classification | Result |
| --- | --- | --- |
| Private reporting | Low | One independently validated finding retained in a private draft advisory; details and identifier withheld pending review. |
| [#1095](https://github.com/lucas-albers-lz4/fwlive/issues/1095) | Medium host/lab operator ownership defect | Failed image preparation can clean up a mount it did not acquire. Independent PATH-stub failure reproduction; no real mount touched. |
| [#1096](https://github.com/lucas-albers-lz4/fwlive/issues/1096) | Low release-input hardening | Tag validation follows npm installation. Two independent disposable mechanics checks. Repository-write prerequisite; no additional privilege or signing-secret exposure demonstrated. |
| [Existing #1090](https://github.com/lucas-albers-lz4/fwlive/issues/1090) | Medium operator accidental-deletion guard defect | Independently confirmed double-slash home-path acceptance in a natural-root container. Comment added; no deletion executed. |
| Existing #1066 / #1068 | Low operational hardening/diagnosability | FIFO logging lock and silent adaptive lock-setup skip independently rechecked. Root-controlled filesystem prerequisites; no new privilege path. No duplicate filed. |

No additional DOM XSS, root command injection, unauthorized read/write ACL grant, direct session `log.read`, unsafe privileged temporary-file write, or signing-key staging leak was confirmed in the inspected source. This is an evidence-bounded result, not a guarantee of absence.

## Fresh verification

| Boundary | Evidence and limits |
| --- | --- |
| Host suite and source gates | `baseline.log`: full `validate-baseline.sh`, fresh POT extraction 227/227, zero runner-level gate skips. Per-suite skips and dependency stubs are separately disclosed. eslint/format/CSS, ShellCheck, AST gates, generated freshness, parser/codegen/RPC/logging/ACL/package/tooling tests passed. |
| Real jshn | `jshn-installer.log` and baseline compatibility gate: all three pinned OpenWrt 23.05/24.10/25.12 C binary + shell-library pairs, BusyBox ash. Plain host selftest skips its jshn subcase; the separate matched gate supplies that seam. |
| Build/package payload | Fresh x86 SDK builds and actual payload inspection on 23.05.5 IPK, 24.10.8 IPK and 25.12.5 APK. APK extraction uses native SDK apk; package metadata and executable modes checked. `build-23.05.log`, `build-24.10.log`, `build-25.12.log`. |
| Reproducibility | `reproducibility.log`: repeated clean package builds are bit-identical in each of the three pinned SDK cells. This proves repeatability within these inputs/runs, not independent supplier reproducibility. |
| Installed IPK/APK | Fresh artifacts installed on disposable 24.10.8 and 25.12.5 x86 guests. Helpers/ACL hashes match baseline. `guest-24.10-hashes.log`, `guest-25.12-hashes.log`. Real nft traffic/log/filter pipeline produced parsed rows on both. `guest-smoke-24.10.log`, `guest-smoke-25.12.log`. |
| Authenticated ACL | 24.10 grant all six methods; no-grant all six denied; read-only four reads allowed, both writes denied; `log.read` denied. 25.12 read-only/no-grant checks preserve those denials. `acl-all-methods-24.10.log`, `acl-read-only-24.10.log`; detailed 25.12 evidence retained privately. rpcd backups restored and hashes checked. |
| Native jsonfilter | Host filter/corpus fixtures used actual guest jsonfilter via bounded SSH wrapper. `native-jsonfilter.log`, `native-jsonfilter-busybox.log`, `native-corpus.log`. This is a hybrid dependency check; the installed nft smokes separately exercise the complete pipeline. |
| Browser | `browser.log`: real browser with mocked LuCI services. `browser-lab-24.10.log`: installed LuCI chip/protocol/recovery/hostname/pause/filter/leave/revisit checks passed. An initial bootstrap `uci.get` access-denied pageerror was logged; no globally pageerror-free claim is made. Relevant recovery assertions passed. |
| Lock/staging controls | Original security-gap helper rejects native util-linux denial status 66; #1098 tracks that quality defect. A scratch copy accepting precisely the native denied-open status passed 32 lookups, 0600 unprivileged denial, held-lock refusal in 5s, same-inode release, and foreign-staging preservation. `security-gaps-24.10.log`, `security-gaps-native-24.10.log`. Original script is not labeled green. |
| Lifecycle | Real IPK/APK uninstall restored the pre-enable WAN baseline; APK same-version reinstall preserved marker/config. `uninstall-24.10.log`, `uninstall-25.12.log`. Separate same-version IPK artifact installer probe revealed #1097; normal uninstall success does not conceal it. |
| Signing | Full validate-key rewrite/sign/verify and local signed feed staging used disposable dummy keys. Modes retained 0600. Both opkg signatures, actual native APK index signature, all manifest hashes and public-key-only staging independently checked. `signing.log`, `local-feed-signing.log`, `feed-signatures-recheck.log`, `apk-index-signature-recheck.log`. No live feed or real signing keys used. |
| Formal | `formal.log`: all seven pinned TLC configurations reached expected outcomes: four runs without invariant violations (one a counterfactual timed-safety configuration), and three named intentional counterexamples. `z3.log`: full bounded Z3/parity suite passed. Models do not prove code equivalence, all-length regex behavior, runtime deadlines or scheduling fairness. |
| Workflow analysis | All seven action pins resolve in their owning repositories; six annotated tag refs match and the dependency-review pin matches exact v4.9.0 (its v4 comment identifies the family). `action-pins-upstream.json`. actionlint passed. Normal zizmor output suppresses 17 findings; `zizmor-all.json` was reviewed independently. Workflow-wide PR-comment permission is needed by the sole dependency-review job; residual informational findings did not establish another vulnerability. Current `feed-publish` protection rules are empty; environment binding is not an approval guarantee. |

## Limits and accepted residuals

No fresh 23.05 installed guest, armsr/TCG or physical hardware pass was run. Source and real matched dependencies cover all three supported release lines; current installed seams cover two package managers on x86. No live publish, secret exposure, arbitrary blackhole helper cancellation, concurrent request saturation, forwarding SLO/load soak, or exhaustive theme/browser/version matrix was claimed.

Accepted root-equivalent admin, local-UID forged syslog, package-wide UCI commit race between privileged writers, and direct-helper lifetime/descendant-cleanup limitations were re-examined and retained. Native ubus's five-second reply wait starts after object lookup and does not cancel a remote operation. The fresh tests do not establish whole-call or descendant termination.

## Evidence retention and next step

Detailed domain reviews, inventories and command logs are access-restricted
and retained by the maintainers. Filenames above are local
evidence references, not links to files published with this report. Private
advisory evidence is excluded from this public document.

Findings await implementation review. Both owned QEMU guests were stopped, and
the installer-test fixture was recovered after its failure reproduction. This
report records the audited baseline; it does not implement fixes or close issues.
