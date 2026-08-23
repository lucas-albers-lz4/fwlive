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
inputs. Those require ECMA-direct backends in [regexproof](https://github.com/lucas-albers-lz4/regexproof)
(`re.from_ecma2020` / Noodler — see upstream issue filed from this epic).

## `/i` and mixed-case (F2)

Z3 predicates enumerate **original + lowercase + uppercase** per token via
`_both_cases` in `scripts/z3-verify.py`. **Arbitrary mixed spellings** (e.g.
`aCcEpT`, `DrOp`, `sYn`) are **outside the finite-token model**.

| Layer | Mixed-case coverage |
| ----- | ------------------- |
| F2 Z3 predicates | Upper + lower + spec spelling only |
| F3 differential parity | Fixed mixed-case corpus (PR #203) — JS vs shell under `sh` and `busybox sh` |
| Formal ECMA `/i` proof | regexproof upstream (`re.from_ecma2020`; link added when issue is filed) |

## F1 scope note

`is_resolvable_address` first rejects anything outside `[0-9a-fA-F:.]`, then
validates IPv4/IPv6 shape in awk. F1 models the **alphabet gate** in Z3 with a
quantifier-free char-at encoding **bounded to length ≤ 64** (declared domain —
not a claim of all-length coverage). Dotted-hex hostnames that use only hex
letters (e.g. `ab.cd.ef.01`) are alphabet-admissible and are rejected by awk —
the full suite documents that split so we do not over-claim the alphabet layer.

## F2 scope note

F2 encodes CLASSIFY_SPEC *predicates* in stock `z3-solver==5.0.0` (default
seq backend). It does **not** feed the ECMA regexes to a solver.

| Predicate | What is proven | Declared domain |
| --------- | -------------- | --------------- |
| `ACTION_RE` / `DENY_ACTION` | Whole-word match: finite Or of action/deny tokens with `Complement([A-Za-z0-9_])` flanks (length 1) or start/end. `--fast` sat/unsat pairs include ` DROP ` vs `XDROPY`. `--full` adds mutation guards (weaken a flank → unsat), `XDROPY DROP` still matches, and a symbolic lemma: no 6-char alnum string containing `DROP` except `DROP` itself is deny. | Scan length ≤ 24. Upper+lower tokens (JS is `/i`; mixed-case not enumerated). |
| `NON_FIREWALL_PREFIX` | Start-anchored daemon name + non-word boundary or end. `dnsmasq[` sat; `dnsmasqfoo` / `xdnsmasq[` unsat. | Upper+lower names. |
| `TCP_FLAG_TAIL` | The **tail fragment** is a sequence of flag tokens separated by space/tab (`token (ws+ token)* ws*`). `SYN ACK` sat; `SYNACK` / `SYN=` unsat. | Whole string is the tail — not a suffix search in a longer line. Not JS `\b` or full `\s`. Upper+lower tokens. |
| `NETFILTER_KV_GLUE` | A non-space/tab char immediately before some `glueKeys+'='` (unrolled string-ops). `fwlive-pingIN=lo` sat; space/tab before `IN=` / `OUT=` unsat. | Scan length ≤ 24. `[^\s]` modeled as not space and not tab. Lookahead `(?=KEY=)` is **not** encoded. Glue keys are exact-case (JS is not `/i`). |

Alphabet lemmas (`=` / digit disjoint from flag and action letters in the
case-expanded token domain; glue keys are A-Z) are length-independent supporting
facts, not the classify predicates. Tuples in `scripts/z3-verify.py` are pinned to
`core/fwlive-log.js` CLASSIFY_SPEC (update both if the spec changes).
Word-boundary uses `Complement([A-Za-z0-9_])` at **length 1 only** (not
`Star(Complement)`).

## F3 scope note

`--fast`: codegen drift guard (`gen-shell-classifier.js` output must match
committed `fwlive-is-firewall-event.sh`). `--full`: Z3 sat-models from F2
predicates plus fixed boundary lines are checked for JS (`core.isFirewallEvent`)
vs generated shell (`fwlive-is-firewall-event.sh`) parity under `sh` and
`busybox sh` (CI installs busybox).

## F4 scope note

`scripts/z3-robustness.js` exercises `normalizeNetfilterMessage`,
`parseKeyValueLog`, `detectAction`, and `isFirewallEvent` on a malformed corpus
(no throw). `--full` also runs `rpcd/fwlive __selftest` (sed prefix/comment
captures and address selftests).
