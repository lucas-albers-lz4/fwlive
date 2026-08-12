# Security review state

What has been reviewed, when, with what strength of proof, and what is still
open. This document is the **record**; it owns no rules.

| Read this for | Go here |
|---------------|---------|
| What we trust, invariants, ACL scope, supply-chain surface | [security-model.md](security-model.md) |
| How to run a pass, re-verification commands | [`.cursor/skills/security-audit/SKILL.md`](../../.cursor/skills/security-audit/SKILL.md) |
| Whether a surface was checked, and whether a control is *proven* | this file |

Start here before a pass. Do not re-derive the trust boundaries, and do not
reopen an accepted residual without new evidence.

## Why a ledger and not just a model

`security-model.md` states what must be true. It cannot tell you whether anyone
checked, or how hard they checked. That gap is not theoretical: two entries on
the Known-good list were falsified in the 2026-08-12 pass, both because the
original conclusion came from reading a line of code rather than executing it.
A claim with no proof class attached is a belief.

## Proof classes

Every control carries one. The class is the *weakest* evidence the control
currently rests on.

| Class | Means | Example |
|-------|-------|---------|
| `host` | Asserted by a test in `tests/`, run by `./scripts/fwlive-test.sh` in PR CI | ACL does not grant `ubus log.*` |
| `lab` | Demonstrated against a running QEMU guest | Live ACL enforcement on a real rpcd |
| `manual` | Confirmed by inspection or a one-off run, not re-checked automatically | Anything with no test behind it |

`manual` is not a failure — some things cannot be cheaply automated — but a
`manual` control on a security boundary is a standing invitation to drift, and
should carry a note saying what would raise it.

## Surface coverage map

| Surface | Last reviewed | Depth | Notes |
|---------|---------------|-------|-------|
| Frontend rendering sinks (`E()` string children) | 2026-08-12 | Sweep + harness | Re-swept; no bare-string sinks. Regression harness from [#138](https://github.com/lucas-albers-lz4/fwlive/issues/138) |
| Untrusted-input trace (log fields, PTR, URL hash, UCI) | 2026-08-12 | Read | No change since the inventory in security-model.md |
| rpcd plugin + ACL scope | 2026-08-12 | Read + selftest | `__`-prefixed methods absent from `list`; read/write split intact |
| Shell helpers — injection and quoting | 2026-08-12 | Read | No log data reaches a command string |
| Shell helpers — **file modes and lock ownership** | 2026-08-12 | Reproduced | New: [#167](https://github.com/lucas-albers-lz4/fwlive/issues/167) |
| Shell helpers — **UCI commit scope and zone grammar** | 2026-08-12 | Read + upstream check | New: [#168](https://github.com/lucas-albers-lz4/fwlive/issues/168) |
| Release pipeline — secrets and key handling | 2026-08-12 | Reproduced | New: [#165](https://github.com/lucas-albers-lz4/fwlive/issues/165) |
| Release pipeline — fetch pinning | 2026-08-12 | Read | New: [#166](https://github.com/lucas-albers-lz4/fwlive/issues/166) |
| Workflow inputs into `run:` bodies | 2026-08-12 | Read | Clean — inputs pass through `env:`, actions SHA-pinned |

## Controls in force

| Control | Proof class | Where |
|---------|-------------|-------|
| Sessions never receive `ubus log.*` | `host` | `tests/fwlive-rpcd-security.test.js` |
| Read and write ACL scopes stay separate | `host` | same |
| Caller line count validated and clamped | `host` | rpcd `__selftest` |
| Addresses shape-validated before `getent` | `host` | rpcd `__selftest`, incl. a literal `$(reboot)` token |
| JSON string content escaped per RFC 8259 | `host` | rpcd `__selftest` |
| WAN log toggle serialized against concurrent callers | `host` | `tests/fwlive-logging-lock.test.sh` (32-trial race) |
| Reload failure rolls back the UCI write | `host` | same |
| `resolve` bounded by a wall-clock budget | `manual` | `RESOLVE_BUDGET`; no test asserts the bound |
| `poll` bounded by `POLL_LINES_MAX` | `host` | rpcd `__selftest` |
| Every `E()` string child is array-wrapped | `host` | rendering harness ([#138](https://github.com/lucas-albers-lz4/fwlive/issues/138)) |
| Actions SHA-pinned, including the step receiving `FEED_DEPLOY_KEY` | `manual` | `.github/workflows/publish-packages.yml` |
| `ipkg-make-index.sh` pinned to a commit SHA and sha256-verified | `manual` | `feed_publish_ipkg_index_script` |
| Only public keys reach `feed-staging/` | `manual` | `feed_publish_copy_keys` |
| Signing secrets are mode 0600 | **not in force** | [#165](https://github.com/lucas-albers-lz4/fwlive/issues/165) — reproduced at 0644 |
| Fetched build helpers verified before execution | **partial** | [#166](https://github.com/lucas-albers-lz4/fwlive/issues/166) — `usign` is cloned unpinned and executed |
| WAN toggle changes only the zone `log` bit | **partial** | [#168](https://github.com/lucas-albers-lz4/fwlive/issues/168) — the `uci commit` is package-wide |
| The WAN logging lock cannot be held by an unprivileged user | **not in force** | [#167](https://github.com/lucas-albers-lz4/fwlive/issues/167) — lock file is 0644 |

## Open findings

| ID | Severity | Issue | Summary |
|----|----------|-------|---------|
| S1 | Medium | [#165](https://github.com/lucas-albers-lz4/fwlive/issues/165) | `feed-keys.sh` tmp+`mv` discards `chmod 600`; signing secrets land 0644 in both documented storage formats. Partial secret left in `${f}.tmp`, and `*.tmp` is not gitignored |
| S2 | Medium | [#166](https://github.com/lucas-albers-lz4/fwlive/issues/166) | `feed_publish_ensure_usign` clones `openwrt/usign` at an unpinned `master`, builds it, and uses it to sign the feed. Class sibling: `get-sdk.sh` fetches an SDK tarball with no checksum |
| S3 | Low-Medium | [#167](https://github.com/lucas-albers-lz4/fwlive/issues/167) | `/var/lock/fwlive-logging.lock` is created 0644; any local UID can take `LOCK_EX` on a read-only fd and, with no BusyBox `flock -w`, wedge both toggles until reboot |
| S4 | Low | [#168](https://github.com/lucas-albers-lz4/fwlive/issues/168) | `uci commit firewall` publishes any delta staged in `/tmp/.uci/firewall`, not just our bit; and a named `config zone 'wan'` is invisible to `find_wan_zone_section` |

Recommended order: S1 → S2 → S3 → S4. S1 and S2 are release-path and land
before the next tag; S3 is a mode fix with a host test; S4 is the largest
behavior change and benefits from going last.

## Accepted residuals

Known, judged acceptable. Reopen only with new evidence.

| Residual | Why accepted |
|----------|--------------|
| Any local UID can inject syslog lines that pass the firewall classifier | `logd` chmods its socket 0666 upstream (ubox `log/syslog.c`). Not fixable from this package; the consequence is forged rows in the view, and every field is already rendered as text |
| `date +%s` can jump under NTP sync, over- or under-running `RESOLVE_BUDGET` | Worker starvation is still prevented, which is the property the budget exists for |
| A LuCI admin session is root-equivalent | Structural to LuCI. It is the reason script execution on this page is treated as a root compromise, not a lesser bug |
| `feed_publish_ensure_usign` leaves its build dir for the process lifetime | `PATH` points into it and `usign` is called later; the name is unpredictable per invocation, and `/tmp` is reaped on reboot |

## What this pass could not prove

Honest gaps, so the next pass starts here rather than rediscovering them.

| Property | Status | What would prove it |
|----------|--------|---------------------|
| `resolve` really returns within its budget on a loaded router | cannot-prove on host | Lab: flood `fwlive.resolve` with unresolvable addresses, measure wall time |
| The rpcd script timeout actually bounds a blocked `flock` waiter | cannot-prove on host | Lab: hold the lock from an unprivileged shell, call the toggle, observe rpcd |
| `uci commit firewall` scope on a live device | prove-next | Lab: stage an unrelated `firewall` delta over SSH, toggle logging, check whether it committed |
| Signing keys stay 0600 through a full publish | prove-next | The host test in [#165](https://github.com/lucas-albers-lz4/fwlive/issues/165) covers the library; a real run also passes through `validate-feed-keys.sh` |

## Review procedure

The *how* lives in
[`.cursor/skills/security-audit/SKILL.md`](../../.cursor/skills/security-audit/SKILL.md).
This section covers only what a pass owes this file.

A pass is not finished until it has:

1. Updated the coverage map dates for every surface it actually looked at — and
   left the others alone. A date that means "someone glanced at it" is worse
   than a stale one.
2. Given every new control a proof class, and downgraded any existing control
   whose proof it could not locate.
3. Filed each finding as its own issue at implementable quality — mechanism,
   location, blast radius, fix sketch, re-verification — and linked it here.
4. Recorded its non-findings. A surface examined and found clean is a result;
   without it the next pass pays for the same reading twice.
5. Corrected any claim it falsified, in the document that **owns** the claim,
   in the same PR. A ledger that contradicts `security-model.md` is worse than
   either one alone.

A feature PR touching the rpcd plugin, the ACL, the shell helpers, or the
release pipeline updates this file in the same PR.

## Rules this repo adopted after being bitten

Each earned by a real finding. They are cheap to apply and they generalize past
the specific bug.

### 1. A control that names a file mode needs a `stat` assertion

Reading `chmod 600` proves the call exists, not that the mode survives to the
end of the function. S1 sat behind a literal `chmod 600` that a later `mv`
undid, and it was on the Known-good list. If a control says "0600", a test says
`stat -c %a`.

### 2. Fix the class, not the site

S2 exists because [#131](https://github.com/lucas-albers-lz4/fwlive/issues/131)
pinned one fetched helper and left its neighbour — twenty lines apart in the
same file — unpinned. When a finding is an instance of a pattern, grep for the
pattern before closing it, and record the sweep in the issue.

### 3. Ask the platform; never re-implement its grammar

S4's zone lookup and the parser divergence in the sibling repo
([usrmanage#108](https://github.com/lucas-albers-lz4/usrmanage/issues/108)) are
the same bug: an ad-hoc regex over a platform format, narrower than the real
parser, deciding something that matters. Call `uci`/`getent`/`fw4`, or fail
closed on input the pattern cannot fully model.

### 4. Verify against upstream source, not against our own documentation

Every 2026-08-12 finding came from checking OpenWrt sources — `rpcd/uci.c` for
per-session save directories, `uci.h` for `UCI_DIRMODE`, `flock(2)` for locking
on read-only descriptors. Two of them also *reduced* a severity we would
otherwise have overstated. Our docs are a summary of a past reading; upstream is
the fact.

## Audit history

### 2026-08-12 — Supply chain, file modes, and UCI scope

**Scope.** Release pipeline key handling and fetch pinning; on-device file modes
and lock ownership; UCI commit scope and zone lookup. Frontend sinks and the ACL
were re-swept but not the focus — the audit skill correctly calls the frontend
highest-yield, and it was found clean again.

**Method.** Read-only, plus host reproductions and upstream source checks
(`rpcd/uci.c`, `uci.h`, `flock(2)`, `libuci` file modes). Prompted by an audit of
the sibling repo `usrmanage`, whose findings suggested three classes to look for
here: temp-file mode loss, unswept fix classes, and hand-parsed platform formats.
All three were present.

**Result.** Four findings: S1–S4 above. Two of them falsify entries previously
recorded as settled — the Known-good list asserted "secret-key file permissions"
and "WAN-log bit-0-only manipulation", and both were derived by reading rather
than running. The Known-good list and the supply-chain table are corrected in
the same PR as this file.

**Non-findings**, so the next pass can skip them:

- Frontend sinks: the Step 1 sweep returns four `E()` calls with bare-identifier
  children (`table.js:99`, `chips.js:94`, `logging.js:202`, `fwlive.js:1578`);
  all four pass arrays or element nodes. No `innerHTML` write has a non-empty
  right-hand side.
- ACL: read/write split intact; no `ubus log.*` grant; `__selftest` and
  `__rulesmap_iptables` remain unreachable through `list`/`call`.
- Workflows: no `${{ }}` interpolation into `run:` bodies — inputs are routed
  through `env:`. All three actions are SHA-pinned, including the one receiving
  `FEED_DEPLOY_KEY`.
- `is_resolvable_address`, `poll_lines_from_input`, and `json_escape` hold under
  their selftests; the escaped-quote capture in the nft prefix regex is correct.
- `/tmp/.uci` is `0700` (libuci `UCI_DIRMODE`), so an unprivileged user cannot
  stage a firewall delta for S4 to commit. This is what keeps S4 at Low.

**Cross-repo.** S3 also exists in `usrmanage`
([usrmanage#111](https://github.com/lucas-albers-lz4/usrmanage/issues/111)),
where the blast radius is larger because the same lock guards every user-management
mutator.
