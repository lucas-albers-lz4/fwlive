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
| F2 CLASSIFY_SPEC | [#198](https://github.com/lucas-albers-lz4/fwlive/issues/198) | planned |
| F3 adversarial parity | [#199](https://github.com/lucas-albers-lz4/fwlive/issues/199) | planned |
| F4 parser robustness | [#200](https://github.com/lucas-albers-lz4/fwlive/issues/200) | planned |

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

## F1 scope note

`is_resolvable_address` first rejects anything outside `[0-9a-fA-F:.]`, then
validates IPv4/IPv6 shape in awk. F1 models the **alphabet gate** in Z3 with a
quantifier-free char-at encoding **bounded to length ≤ 64** (declared domain —
not a claim of all-length coverage). Dotted-hex hostnames that use only hex
letters (e.g. `ab.cd.ef.01`) are alphabet-admissible and are rejected by awk —
the full suite documents that split so we do not over-claim the alphabet layer.
