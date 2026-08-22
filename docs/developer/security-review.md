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
| Frontend rendering sinks (`E()` string children) | 2026-08-13 | Sweep + harness | #177: #175/#176 UI delta on recording-`innerHTML` harness; no non-empty innerHTML writes |
| Untrusted-input trace (log fields, PTR, URL hash, UCI) | 2026-08-13 | Reproduced | #177: hostile log/PTR/UCI/hash through normalize + render + chips |
| rpcd plugin + ACL scope | 2026-08-13 | Diff + selftest | #177: no diff since `ce9df02`; read/write split; no `ubus log.*` |
| Shell helpers — injection and quoting | 2026-08-13 | Read | #177: no log data reaches a command string |
| Shell helpers — **file modes and lock ownership** | 2026-08-13 | Reproduced | #177: `fwlive-logging-lock.test.sh` 32-trial; lock 0600 |
| Shell helpers — **uninstall baseline restore (`prerm`)** | 2026-08-22 | Read + host test | `/etc/fwlive/wan-log-baseline`; restore only on `remove` |
| Shell helpers — **UCI commit scope and zone grammar** | 2026-08-13 | Host test | #177: pending-delta refuse; named/anonymous/non-zone lookups |
| Release pipeline — secrets and key handling | 2026-08-18 | Reproduced | #177 key-mode re-run; R7 pin-before-mount + `--network none` ([#179](https://github.com/lucas-albers-lz4/fwlive/issues/179)); 2026-08-18 hardening parity + R7 wrapper fix |
| Release pipeline — fetch pinning | 2026-08-18 | Read + host test | #177 fetch-pin gate; R7 digest pin-cache (`tests/sdk-matrix-digests.test.sh`); 2026-08-18 wrapper-export + exact-cache-key |
| Workflow inputs into `run:` bodies | 2026-08-18 | Read | Clean — inputs pass through `env:`; actions SHA-pinned including `FEED_DEPLOY_KEY`; 2026-08-18: dispatch tag validated (control chars, shape, real-tag + HEAD identity) before repo scripts |

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
| Actions SHA-pinned, including the step receiving `FEED_DEPLOY_KEY` | `manual` | `.github/workflows/publish-packages.yml` — `peaceiris/actions-gh-pages@84c30a85c…` = `v4.1.0` (verified 2026-08-13); CodeQL alert 7 closed as **fixed**; re-check before each `v*` tag ([#178](https://github.com/lucas-albers-lz4/fwlive/issues/178)) |
| SDK image digest-pinned at first **secret-touching** pull | `host` | `sdk_matrix_pull_and_pin` in `validate-feed-keys.sh`; `feed_publish_apply_sdk_pin` before opkg/apk sign; `tests/sdk-matrix-digests.test.sh` |
| Signing-secret containers have no network | `host` | `docker run --network none` on validate usign check and opkg/apk sign steps (Compose v2 has no `--network` on `compose run`); same test |
| `ipkg-make-index.sh` pinned to a commit SHA and sha256-verified | `manual` | `feed_publish_ipkg_index_script` |
| Only public keys reach `feed-staging/` | `manual` | `feed_publish_copy_keys` |
| Signing secrets are mode 0600 | `host` | `tests/feed-keys-mode.test.sh` — both storage formats under umask 022 |
| Fetched build helpers verified before execution | `host` | `tests/fetch-pin-gate.test.sh` — usign commit-pinned; `get-sdk.sh` sha256-verified |
| Publish job runs under Environment `feed-publish` | `manual` | `.github/workflows/publish-packages.yml` `environment:` — organizational gate (protection rules optional; none configured, matching usrmanage). Does NOT scope repo-level secrets — keys stay repository-scoped by design |
| Checkout never writes GITHUB_TOKEN into `.git/config` | `manual` | same workflow — `persist-credentials: false` (workspace is bind-mounted into SDK) |
| workflow_dispatch tag validated before `GITHUB_ENV` write | `manual` | same workflow — newline/control-char rejection + `^v[0-9]` shape |
| SDK feed cache key is exact (no `restore-keys` prefix fallback) | `manual` | same workflow — stale feed pins cannot be restored on cache miss |
| WAN toggle changes only the zone `log` bit | `host` | `tests/fwlive-logging.test.sh` — pending-delta refuse; named + anonymous zone lookup |
| Uninstall restores WAN `log` from pre-first-enable baseline | `host` | `tests/fwlive-logging.test.sh` — baseline snapshot/restore; `scripts/qemu-logging-uninstall-smoke.sh` (`lab`) |
| The WAN logging lock cannot be held by an unprivileged user | `host` | `tests/fwlive-logging-lock.test.sh` Part D — create+tighten to 0600 |

## Open findings

| ID | Severity | Issue | Summary |
|----|----------|-------|---------|
| — | Low | [#190](https://github.com/lucas-albers-lz4/fwlive/issues/190) | `is_resolvable_address` admitted hostname-shaped tokens (dotted-hex) → read-ACL `resolve` sessions could trigger arbitrary upstream DNS via `getent`; strict IPv4/IPv6 validation + selftest cases landed in the fix PR — open until merge |
| — | Low | [#191](https://github.com/lucas-albers-lz4/fwlive/issues/191) | Global `uci commit firewall` could sweep unrelated staged deltas from non-lock-cooperating writers; commit moved behind a last-moment pending re-check + post-commit verification in the fix PR — open until merge |


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
| `uci commit firewall` scope on a live device | prove-next | Lab: stage an unrelated `firewall` delta over SSH, toggle logging, check whether it committed — **host-level fix landed 2026-08-21 (#191)**: staging+commit moved inside `commit_wan_log_change` behind a last-moment `firewall_changes_pending` re-check (abort on foreign staging, never commit it, never revert foreign data — the commit-failure path also reverts ONLY when our option is the sole staged delta, otherwise warns and leaves foreign staging intact); post-commit read-back verification; the residual race window (a writer staging between the gate and `uci commit`) is narrowed to the minimum uci allows and detected by post-commit verification; lab confirmation still pending |
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

### 2026-08-13 — Frontend delta + S1–S4 verification (record of non-findings, with one miss)

**Scope.** Delta since 2026-08-12 (`ce9df02..4931026`, v0.1.33): #175/#176 UI work, plus execution of S1–S4 remediations. Filed as [#177](https://github.com/lucas-albers-lz4/fwlive/issues/177).

**Method.** Host tests (`./scripts/fwlive-test.sh`) plus the recording-`innerHTML` harness; `feed-keys-mode`, `fetch-pin-gate`, logging lock/UCI tests.

**Result recorded as no findings.** That was wrong for one class: `scripts/validate-feed-keys.sh` still resolved a mutable SDK tag and bind-mounted `OPKG_FEED_SECRET_KEY` without `--network none`. The pass treated validate-keys SDK ordering as usrmanage-only; it is the same R7 pattern. Closed by the 2026-08-15 entry.

**Non-findings that still hold:** frontend sinks (harness, hostile log/PTR/UCI/hash/chips); S1–S4 tests; rpcd/ACL (no diff); workflows SHA-pinned including `FEED_DEPLOY_KEY`; no `${{ }}` in `run:` bodies.

### 2026-08-15 — R7 pin-at-secret-mount and #178 pin checklist

**Scope.** Close [#177](https://github.com/lucas-albers-lz4/fwlive/issues/177) via ledger correction; remaining [#178](https://github.com/lucas-albers-lz4/fwlive/issues/178) process (peaceiris SHA re-check); R7 analog from [usrmanage#128](https://github.com/lucas-albers-lz4/usrmanage/pull/128). Playbook [#179](https://github.com/lucas-albers-lz4/fwlive/issues/179).

**Method.** Port `sdk_matrix_pull_and_pin` + always-pull; `--network none` on secret mounts; host greps and mocked-docker digest tests. No QEMU.

**Result.** Validate path pins `x86-64`/`23.05` before the usign secret mount. Opkg/apk **sign** steps export tools via compose (no secret), then `docker run --network none` with a digest-pinned image and no `/builder` mount (Compose v2 `run` has no `--network`; compose volume names are project-prefixed). Pre-release checklist requires re-checking `peaceiris/actions-gh-pages` tag↔SHA (alert 7 already **fixed**; Dependabot version PRs stay off). Open findings table empty. No L12 analog (no incomplete-marker path).

### 2026-08-18 — Release-pipeline hardening parity with usrmanage

**Scope.** Port four release-pipeline controls already in force in `usrmanage` (there R1/R5 + environment + cache hardening, filed from #63/#70/#117): publish job scoped to Environment `feed-publish`; checkout `persist-credentials: false` (no GITHUB_TOKEN in `.git/config` inside the SDK bind mount); `workflow_dispatch` tag validation (newline/control-char rejection + `^v[0-9]` shape) before `GITHUB_ENV` write; SDK feed cache keyed exactly on `feeds.lock` hash with no `restore-keys` prefix fallback (stale feed pins cannot be restored).

**Method.** Read-diff of `usrmanage`'s `.github/workflows/publish-packages.yml` (the hardened template from #117/#120) against fwlive's; ported the four deltas verbatim, adapted env var names (`FWLIVE_RELEASE_TAG`, `FWLIVE_GIT_TAG`).

**Result.** Controls added to the table above. No new findings; the existing S1–S4/R7 controls are unaffected. Environment `feed-publish` created 2026-08-18 with **no protection rules** (matches usrmanage; adding required reviewers later would gate tag-push publishes on human approval). The environment is an organizational/approval-capable gate, NOT a secret-scoping mechanism — the five feed secrets remain repository-scoped (identical to usrmanage's setup).

### 2026-08-18 — R7 sign-step wrapper regression fix (first publish after R7)

**Scope.** The v0.1.34 publish (first after the 2026-08-15 R7 rework) failed at `index+sign via SDK` with exit 127: `/feed/tools/mkhash: line 5: /feed/tools/../lib/ld-linux-x86-64.so.2: No such file or directory`.

**Root cause.** OpenWrt SDK `staging_dir/host/bin/{usign,mkhash,apk}` are **runas wrapper scripts**, not plain binaries: `bin/<tool>` execs `../lib/ld-linux-x86-64.so.2` with `LD_PRELOAD=../lib/runas.so` against the hidden real binary `bin/.<tool>.bin`. The R7 export (`feed_publish_export_*_tools`) copied only the bare wrapper into `/feed/tools`, so the relative `../lib` and `.bin` siblings were missing. Verified across 21.02.7 / 24.10.8 / 25.12.5 SDK tarballs — the pattern holds in every supported release.

**Fix.** Export the wrapper **and** the hidden `.bin` into `tools_dir` and the shared-lib tree (`*.so*` only) into a separate `lib_dir`, mounted as siblings at `/feed/tools` + `/feed/lib` so the wrapper's `../lib` resolution works while `/feed/pkgdir` stays a plain mount. Export runs in the dedicated `sdk-export` compose service (SDK volume only, **no workspace mount**) as the invoking uid — the workspace holds the signing keys, so the export container must never see them; only world-readable `.so*` libs are copied (the 0600 buildbot-owned `meson/` templates are not needed), so root is not required. Sign runs remain `docker run --network none`, no `/builder` mount, digest-pinned image, keys `:ro` — all preserved.

**Result.** `bash -n` clean; actionlint clean; fix verified by re-running the publish workflow (v0.1.34).
