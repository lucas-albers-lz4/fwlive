# October 2 implementation evidence

Tracker: [#1135](https://github.com/lucas-albers-lz4/fwlive/issues/1135). Codex
implemented and integrated the work with GPT-6-luna at xhigh design and final
diff reviews. The owner’s additional reviews approved all nine units, and
findings were triaged before merging. Final heads, CI and merge dispositions
are tracked in #1135.

| Unit | Issues | PR |
|---|---|---|
| Upstream cut and CLI selftest | #1120 | #1122 |
| Formal rollback review/remediation | Additional owner request | #1123 |
| Adaptive timing and off override | #1125, #1127 | #1136 |
| Summary control-byte encoding | #1124 | #1137 |
| Single-pass nft preparation | #1128 | #1138 |
| Anonymous rules-map files | #1133 partial mitigation | #1139 |
| Chip accessible name | #1129 | #1140 |
| Simple-view keyboard expansion | #1130 | #1141 |
| KV pattern reuse | #1131 | #1142 |

## Revision and artifact boundary

The isolated combined candidate `8351a6cab201e4ae31c72893bde7734530cb5bb7`
contains both existing PRs and all seven new units. Its required-scan host
baseline ran at `23bef8c682d9a104a4954a7bf97b73123eb8debd` and passed with
zero runner-level skips and no per-suite SKIPPED results. The later delta
contains only the Z3 verifier and its documentation; full pinned Z3 and Ruff
passed at `8351a6cab2`. The product/package inputs are identical between
those revisions. A fresh LuCI scan matches 229 msgids and 246
references; the cited package files match line-for-line. The mocked Chromium view smoke passed.

The cached pinned OpenWrt 24.10.8 x86_64 SDK built the combined candidate's
actual `luci-app-fwlive_0.1.50-r1_all.ipk`, SHA-256
`c1db476f1b4a9541cc87946def45993647a841257be89f4ce2c7a4a4933dae22`.
It was force-reinstalled artifact-only into an owned disposable 24.10.8
x86_64 guest. Extracted payload hashes, package version/dependencies and all
six registered RPC methods were verified. LuCI's build transformation
minifies JS, so installed JS identity was compared with the IPK payload.
An immediate guest restart initially lost unsynced installation writes; a
fresh artifact reinstall followed by explicit `sync` passed identity checks.
The failed setup attempts are not counted as validation.

## Fresh installed results

- Actual IPv4 nft/logd/rpcd pipeline smoke passed with three parsed rows.
  The guest lacked an `icmpv6` match, so the IPv6 ping-rule lane was skipped.
- A private unhooked nft table with 400 labeled prefixes passed installed
  `rules` RPC normalization, aliases, comment-only labels, precedence and
  first-wins checks (15,291-byte reply, 23 centiseconds). Raising that private
  fixture to 520 prefixes reported truncation within 512 keys (18,412-byte
  reply, 27 centiseconds). The fixture table's deletion was confirmed.
- Installed poll/filter checks passed default enabled summary and mixed-case
  adaptive-off behavior. Native poll calls also passed `False`, `Off`, `No`
  and mixed variants with adaptive=0 and summary/shed fields omitted.
- Installed wrapper plus native jsonfilter/awk round-tripped 0x01, 0x1f and
  DEL as distinct escaped summary values. Clock-read failure is proved by the
  host production-poll clock seam; guest `/proc/uptime` was left intact.
- Native guest ash reopened an unlinked descriptor twice at offset zero,
  yielding `alpha|alpha`. Host dash/BusyBox fixtures cover concurrent calls,
  setup failures and plugin-only SIGTERM/SIGKILL during dump/TSV work.
- The installed minified view/log modules, loaded on the same Node v26.10.0
  host, produced identical 2,000-row normalized output before and after C1.
  Seven runs showed 4,000 RegExp constructions per pre-C1 batch and zero per
  installed C1 batch (13 at initialization); median 10.876 versus 9.844 ms.
  These timings describe a host execution of installed assets, not router JS
  runtime speed or a CI threshold. The separate 400-prefix host benchmark
  reduced instrumented awk/cat/sed/tr calls from 2,802 to two, with identical
  8,225-byte JSON replies.
- Installed Chromium role/name and Enter/Space checks passed for chip inversion
  and Simple expansion, including exactly-once activation, filter-link guards,
  native table semantics, expanded/control association, full hostile text as
  text nodes, Detail mode and focus restoration after a same-row keyed rebuild
  through the installed `renderRows(true)` path. Browser HTTP poll replies
  were explicitly replaced with two deterministic rows. Duplicate-ID polls
  correctly kept the existing immutable log record. This verifies installed
  assets/event wiring; the separate real-log smoke supplies logd proof. The
  no-password disposable guest emitted one `uci/get` access-denied page error;
  the verifier allowed only that known error. No global error-free or
  assistive-technology claim is made. Desktop installed screenshots were
  inspected; the mocked 390px layout retains existing fixed-column overflow.

## Formal and remaining limits

On #1123 head `21415172ef10d4c3e6f3f6b94473c8ddac2367f8`, the pinned TLC
1.7.4 jar (SHA-256
`936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`)
ran four positive configurations and four expected counterexamples. The
strict scalar counterexample cfg grammar rejects extra same-line,
continuation and plural properties before running TLC. Tooling negative
controls and an isolated incorrect restore-effect mutation passed their
expected-failure checks. This proves model/tooling properties under stated
fairness assumptions; #1121/#1126 and runtime shell conformance remain
separate follow-ups.

#1133 removes dump/TSV pathnames before blocking work and corrects #775's
absolute cleanup wording. Host SIGKILL tests also prove a surviving helper
can retain deleted-file tmpfs storage until the inheriting processes close
their descriptors. The short mktemp/open/unlink setup
window, helper lifetime and immediate resource reclamation limits remain.
No deadline, process-group supervisor or stale-file sweep was added. The issue
stays open for those residuals after owner approval of the partial mitigation. QEMU timings do not establish
A7 hardware latency, and no fresh APK/23.05/physical-device cell is claimed.

The original dirty working tree was preserved. Current PR heads, CI status,
owner-required reviews and merge dispositions are tracked in #1135; an older
review label does not attest to a changed head. No OpenWrt/LuCI upstream
publication or release/version bump was performed.


## Review and integration follow-up

The owner approved each prepared head on October 2. Codex and
GPT-6-luna/xhigh checked every note against the actual code. The only test
addition, `25ec5e2772`, pairs accepted `Rule_1` and rejected `Rule.1` labels
through both real UCI and nft-comment paths; the rules-map suite passed.
All seven inline notes received evidence-backed replies and were resolved.

After #1122/#1123 landed, master `38fa3f203a` was merged through the stack.
Each unit’s code/test patch identity stayed unchanged, including the paired
charset cases. The final package subtree is exactly
`ccf98886ee3fa2a4c76f4663300624a2dc019e0c`, identical to the validated combined
candidate; this follow-up requires no rebuilt installed artifact. Documentation
entry ordering and review status were reconciled, and CI ran on the final heads.

CodeRabbit completed the original adaptive unit at `6b1f20d7de` with no
actionable findings. Later triggers were rate-limited; those rounds are
unreviewed, not green reviews. Execution uses the completed owner reviews as
the required review gate under the owner’s instruction to complete and merge
#1135. Exact-head CI and unresolved-finding checks remain separate gates.
