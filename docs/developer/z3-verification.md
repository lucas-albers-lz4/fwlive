# Z3 verification (host / CI)

Umbrella: [#120](https://github.com/lucas-albers-lz4/fwlive/issues/120).  
Deployment: [#121](https://github.com/lucas-albers-lz4/fwlive/issues/121).

Verification is **host and CI only** — never on the OpenWrt device. The epic
*verifies* regex / address gates; it does not change runtime classifier or
rpcd behavior (file separate issues for behavior fixes).

## Children

| Child | Issue | Status in harness |
| ----- | ----- | ----------------- |
| F1 `is_resolvable_address` alphabet | [#197](https://github.com/lucas-albers-lz4/fwlive/issues/197) | `scripts/z3-verify.py` |
| F2 CLASSIFY_SPEC | [#198](https://github.com/lucas-albers-lz4/fwlive/issues/198) | `scripts/z3-verify.py` |
| F3 adversarial parity | [#199](https://github.com/lucas-albers-lz4/fwlive/issues/199) | `scripts/z3-verify.py` |
| F4 parser robustness | [#200](https://github.com/lucas-albers-lz4/fwlive/issues/200) | `scripts/z3-verify.py`, `scripts/z3-robustness.js` |
| F5 prepared nft prefix normalization | [#275](https://github.com/lucas-albers-lz4/fwlive/issues/275) | `scripts/z3-verify.py` |

## Commands

```sh
# Pre-commit subset (hook skips if z3 not installed — CI is authoritative)
pre-commit run z3-verify-fast
# Or, with z3 installed:
python3 scripts/z3-verify.py --fast

# Full suite (CI; requires z3)
pip install 'z3-solver==5.0.0'
python3 scripts/z3-verify.py --full
```

## Tiers (#121)

| Tier | Flag | Where |
| ---- | ---- | ----- |
| Convenience | `--fast` | `.pre-commit-config.yaml` local hook (skip if no z3) |
| Enforcement | `--full` | `fwlive-test` workflow job `z3-verify` |

## `--fast` vs `--full` (F2)

| Tier | F2 coverage | Length bound |
| ---- | ----------- | -------------- |
| `--fast` | Alphabet lemmas (length-independent where noted) plus **concrete** whole-word sat/unsat pairs for each predicate | Unrolled whole-word and glue scans bounded by `WORD_SCAN_MAX ≤ 24`; prefix and flag-tail predicates are not length-bounded in the harness |
| `--full` | Everything in `--fast`, plus mutation guards (weaken a flank → unsat), symbolic no-over-match lemmas, and deny-class ⊆ action-class implication | Same bounds as `--fast` per predicate |

**Not claimed:** length-independent symbolic word-boundary proofs for arbitrary-length
inputs. The original-source/flags goal remains unresolved in
[regexproof#571](https://github.com/lucas-albers-lz4/regexproof/issues/571);
the reviewed [feasibility disposition](#phase-d-disposition-1322) rejects the
current Noodler route. A direct converter alone does not establish JavaScript
semantic correspondence.

## `/i` and mixed-case (F2)

Z3 predicates enumerate **original + lowercase + uppercase** per token via
`_both_cases` in `scripts/z3-verify.py`. **Arbitrary mixed spellings** (e.g.
`aCcEpT`, `DrOp`, `sYn`) are **outside the finite-token model**.

| Layer | Mixed-case coverage |
| ----- | ------------------- |
| F2 Z3 predicates | Upper + lower + spec spelling only |
| F3 differential parity | Fixed mixed-case corpus (PR #203) — JS vs shell under `sh` and `busybox sh` |
| Formal ECMA `/i` proof | Unresolved: [regexproof#571](https://github.com/lucas-albers-lz4/regexproof/issues/571); current Noodler route is no-go |

## F1 scope note

`is_resolvable_address` first rejects anything outside `[0-9a-fA-F:.]`, then
validates IPv4/IPv6 shape in awk. F1 models the **alphabet gate** in Z3 with a
quantifier-free char-at encoding **bounded to length ≤ 64** (declared domain —
not a claim of all-length coverage). F1 asks SAT/UNSAT questions for concrete
examples within that encoding; it does not establish a universal source-to-model
theorem or automatically pin the source alphabet gate. Dotted-hex hostnames that use only hex
letters (e.g. `ab.cd.ef.01`) are alphabet-admissible and are rejected by awk —
the full suite documents that split so we do not over-claim the alphabet layer.

## F2 scope note

F2 encodes CLASSIFY_SPEC *predicates* in stock `z3-solver==5.0.0` (default
seq backend). It does **not** feed the ECMA regexes to a solver.

| Predicate | What is proven | Declared domain |
| --------- | -------------- | --------------- |
| `ACTION_RE` / `DENY_ACTION` | Whole-word match: finite Or of action/deny tokens with `Complement([A-Za-z0-9_])` flanks (length 1) or start/end. `--fast` sat/unsat pairs include ` DROP ` vs `XDROPY`. `--full` adds mutation guards (weaken a flank → unsat), `XDROPY DROP` still matches, and a symbolic lemma: no 6-char alnum string containing `DROP` except `DROP` itself is deny. | Scan length ≤ 24. Upper+lower tokens (JS is `/i`; mixed-case not enumerated). |
| Prefix mirror (`matches_nf_prefix`) | Start-anchored daemon name + `[^A-Za-z0-9_]` or end. `dnsmasq[` sat; `dnsmasqfoo` / `xdnsmasq[` unsat. | Upper+lower names. **Boundary differs from current source:** the mirror admits hyphen after a daemon name; current `NON_FIREWALL_PREFIX` excludes it. No source-equivalence claim. |
| `TCP_FLAG_TAIL` | The **tail fragment** is a sequence of flag tokens (CWR ECE URG ACK PSH RST SYN FIN, matching JS `TCP_FLAG_TAIL`) separated by space/tab (`token (ws+ token)* ws*`). `SYN ACK` sat; `SYNACK` / `SYN=` unsat. Token-vs-glued shape is the proof; vocabulary is pinned in `scripts/z3-verify.py` `TCP_FLAG_TOKENS`. | Whole string is the tail — not a suffix search in a longer line. Not JS `\b` or full `\s`. Upper+lower tokens. |
| `NETFILTER_KV_GLUE` | A non-space/tab char immediately before some `glueKeys+'='` (unrolled string-ops). `fwlive-pingIN=lo` sat; space/tab before `IN=` / `OUT=` unsat. | Scan length ≤ 24. `[^\s]` modeled as not space and not tab. The current source searches the first `KEY=` then checks its predecessor; this mirror expresses existence of a glue site, not first-match selection. Glue keys are exact-case (JS is not `/i`). |

Alphabet lemmas (`=` / digit disjoint from flag and action letters in the
case-expanded token domain; glue keys are A-Z) are length-independent supporting
facts, not the classify predicates. Tuples in `scripts/z3-verify.py` are manually maintained from
`core/fwlive-log.js` CLASSIFY_SPEC and the separate TCP flag vocabulary; this
is not a full source-to-model equivalence check. The prefix boundary drift
above is an outstanding modeling gap.
Word-boundary uses `Complement([A-Za-z0-9_])` at **length 1 only** (not
`Star(Complement)`).

## F3 scope note

`--fast`: codegen drift guard (`gen-shell-classifier.js` output must match
committed `fwlive-is-firewall-event.sh`). `--full`: Z3 sat-models from F2
predicates plus fixed boundary lines and `MIXED_CASE_PARITY_CORPUS` are checked
for JS (`core.isFirewallEvent`) vs generated shell
(`fwlive-is-firewall-event.sh`) parity under `sh` and `busybox sh` (CI installs
busybox). Z3 sat-models remain upper/lower/original only; arbitrary `/i`
mixed-case examples are checked by the fixed corpus, not predicate enumeration.
F3 compares the final boolean classifier result, not individual regex captures,
first-match positions, or flag-parser outputs. Formal ECMA `/i` proofs remain
unresolved: [regexproof#571](https://github.com/lucas-albers-lz4/regexproof/issues/571).

## F4 scope note

`scripts/z3-robustness.js` exercises `normalizeNetfilterMessage`,
`parseKeyValueLog`, `detectAction`, and `isFirewallEvent` on a malformed
**string** corpus (no throw). Non-string `entry.msg` values are out of scope —
rpcd/JSON paths always pass strings. `--full` also runs `rpcd/fwlive __selftest` (sed prefix/comment
captures and address selftests).

## F5 scope note

F5 pins the trailing space/tab/colon strip and prepared-mode dispatch inside
the shipped `nft_dump_fields()` function. Its Z3 idempotency and fixpoint
proofs cover strings of length ≤ 8 over the declared content and strip
alphabet; they are bounded proofs, not length-independent claims. `--full`
also runs the actual prepared AWK stage twice on 13 synthetic nft rows,
checks the expected normalized prefixes, and checks core/LuCI
`parseRuleHint` parity for the resulting keys (#254). The weakened-quantifier
and colon-drop controls must produce counterexamples.


## Phase D disposition (#1322)

The maintainer-approved [regexproof #652](https://github.com/lucas-albers-lz4/regexproof/pull/652)
merged as `ed9ede48afd1ca8ee869b31d7ab6422651e86b8a`. Its
[research report](https://github.com/lucas-albers-lz4/regexproof/blob/ed9ede48afd1ca8ee869b31d7ab6422651e86b8a/docs/issue-571-feasibility-2026-10-18.md)
records a **no-go for activating the investigated as-written Noodler route**.
Both tested versions fail to represent original `/i` behavior; version-specific
errors, unknowns, timeouts and crashes are diagnostic failures, never proof
success. This is not a universal impossibility result.

The original source/flags proof goal in regexproof #571 remains open. U9,
production pins and F1–F5 are unchanged; no ASCII mirror or differential-only
replacement was approved. No new solver result or solver-generated application
witness from that research is consumed here. Its fixed native strings and
28-row diagnostic are finite observations, separate from F3's existing
stock-seq-generated samples and fixed parity corpus.

### Current source and call-site inventory

Snapshot: clean fwlive base `629dd4a892194c5ab823f0722496f05060869c07`,
2026-10-18. The core SHA-256 still matches the frozen source investigated in
regexproof #652. These hashes identify the listed files, not every dependency
or an installed device. A later change requires refreshing the affected map.

| File | SHA-256 |
| --- | --- |
| `core/fwlive-log.js` | `52983d7c0a629de4ee23a13873e5ac54cf7d08dfaf03383614fceb59a4d1da12` |
| `openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js` | `efddb7eab758c5c86038248274fddf4ce1b2d7b6003e5d81cb423f1c151cc336` |
| `scripts/z3-verify.py` | `643c452e943db8be2b44729b404da333f0062934cd2cb94c9683584d6d132d1a` |
| `scripts/gen-shell-classifier.js` | `bd2a64c9b862475ef12a50a40620e44012357106af33bff3777c0faf9ae3daf3` |
| `openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.sh` | `f002065b1bbbc224d5a75cb51d375d985ed50ee47f714f32c2132e75fb228a9f` |
| `openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive` | `761f4abd99a24290a5a25833837ee4b045d76e303a1563f89a52497ab6e523ea` |

The map covers the #571 targets and their immediate preprocessing dependencies,
not every regular expression in the application. Inputs are log-message
strings, including untrusted content. The runtime imposes no ASCII-only or
24-character restriction on these regex consumers. The #571 targets
(`ACTION_RE`, `DENY_ACTION`, `NON_FIREWALL_PREFIX`, `TCP_FLAG_TAIL` and optional
`FIREWALL_HINT`) use `i` without `u`, `m`, `s`, `g` or `y`; the preprocessing
dependencies have their separately listed flags. JavaScript strings need their actual
non-Unicode-mode UTF-16 behavior, including NUL and isolated surrogates, in any
future correspondence claim.

| Source symbol (core; LuCI mirror) | Actual consumer contract | Existing evidence and unresolved bridge |
| --- | --- | --- |
| `ACTION_RE` / `wordPattern` (`:123`, `:143`; mirror `:173`) | Boolean search is insufficient for `detectAction`: after `messageForDetectAction` then `stripKvSpans`, `.match()` selects a first match and group 2, uppercased or `UNKNOWN`. Explicit ASCII flank class `[^A-Za-z0-9_]`, not JS `\b`. | F2 bounded existential token mirror; F3 final classifier parity on a finite corpus. Original `/i`, earliest match/capture and preprocessing correspondence remain unproved. |
| `DENY_ACTION` (`:146`; mirror `:174`) | Exported whole-word regex over the deny slice, with the same explicit flanks. No direct use by the current core classifier; `inferActionRaw` returns the supplied known action or `UNKNOWN`. | F2 deny mirror and deny-subset implication concern predicates. Do not infer a full deny-classifier theorem. `DENY_ACTION_UNDERSCORE` is a separate exported boundary variant, not modeled by that implication. |
| `NON_FIREWALL_PREFIX` (`:137`; mirror `:164`) | Start-anchored daemon rejection in `isFirewallEvent`, after normalization and `classifyTrim`. Current `nonFirewallPrefixHyphenContinuation: true` selects `[^A-Za-z0-9_-]` or end. | F2 prefix mirror has the hyphen mismatch described above. F3 remains finite final-output parity, not proof that this mirror equals the guard. |
| `TCP_FLAG_TAIL` (`:159`; mirror `:185`) | `parseFlags` first returns truthy `TCPFLAGS` or `FLAGS` KV values. Otherwise strip KV spans, search the original tail regex, take group 1, trim/uppercase and replace whitespace runs with commas. Optional `OPT (...)`, JS `\s` and `$` behavior matter. | F2 checks only a whole-tail token/space-tab language. Neither F3 classifier parity nor fixed `sYn ACK` proves this parser's capture, suffix search or KV precedence. |
| `FIREWALL_HINT` (`:142`; mirror `:172`) | Boolean search in normalized messages during `evaluateClassifySpec`, using the same explicit word flanks; optional #571 stretch. | No dedicated F2 hint predicate. F3 checks selected final classifier outcomes. |
| `NETFILTER_KV_GLUE`, `KV_SPAN` (`:161–162`; mirror `:180`, `:188`) | Exact-case first-key search plus predecessor whitespace check for normalization; global `\b[A-Z][A-Z0-9_]*=[^\s]+` replacement for KV removal. | F2 glue existence uses space/tab only and a bounded scan; it does not prove first-key selection, full JS whitespace or the KV-removal transformation. |

`classifyTrim` recognizes exactly the spec's space/tab/LF/CR/NBSP set;
`messageForDetectAction` also performs JS `.trim()`, timestamp/fw4 and rule-tag
removal. These are different operations. A proof of a raw token language does
not discharge either transformation. Exact source bytes and flags, search vs
membership, first-match captures, boundaries, whitespace, UTF-16 and any chosen
length restriction must be stated by a future consumer contract.

### Enforcement and next work

The existing `fwlive-test` job `z3-verify` invokes `--full` for F1–F5 with pinned
stock Z3 and installs BusyBox for host replay. This is workflow execution;
repository required-check enforcement is a separate setting. The suite mixes
bounded symbolic predicates (F1/F2/F5), finite real-engine parity/replay (F3/F5),
and malformed-input robustness/selftests (F4). None establishes whole-parser,
whole-repository, installed-router or full UTF-16 regex correctness.

Phase D's current disposition is inventory complete / backend consumption
blocked by the reviewed no-go. No additional F3 witness replay is warranted
without a faithful result and real-engine validation. The prefix-mirror drift
needs its own scoped model-alignment change, independently of the larger proof
route. A separate one-consumer proof pilot can evaluate the source-to-AST and
concrete character-semantics bridge; neither an unbuilt alternative nor manual
pattern translation is an accepted proof gate.
