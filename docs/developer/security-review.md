# Security review state

> **Status:** 43 controls in force; 0 open findings.
> **Last review:** 2026-09-03 (multi-model VVAH pass: playbook + B-1 zone identity; #261/#257 closed).
> **Open:** none.
> **Next:** On the next `v*` tag, re-check pins and run full docker usign (gap 4). The full surface re-pass is deferred — the gate criteria are not met (skill § Multi-model pass / full-pass gate). Lab gaps 1–3 ran as smoke tests on 2026-09-04 (`./scripts/qemu-security-gaps-smoke.sh` green). The gap 2 flock residual is unchanged.
> **How to verify:** `./scripts/fwlive-test.sh` runs automated host checks. Multi-model pass: [`.cursor/skills/security-audit/SKILL.md`](../../.cursor/skills/security-audit/SKILL.md) § Multi-model pass. Values current as of this PR.

What has been reviewed, when, with what strength of proof, and what is still
open. This document is the **record**; it owns no rules.

| Read this for | Go here |
|---------------|---------|
| What we trust, invariants, ACL scope, supply-chain surface | [security-model.md](security-model.md) |
| How to run a pass (multi-model stages + surface steps) | [`.cursor/skills/security-audit/SKILL.md`](../../.cursor/skills/security-audit/SKILL.md) |
| Whether a surface was checked, and whether a control is *proven* | this file |

Start here before a pass. Do not re-derive the trust boundaries, and do not
reopen an accepted residual without new evidence.

## Review goals

| Goal | Examples in this repo |
|------|------------------------|
| Exploit | Injection, ACL bypass, XSS from log data, privilege escalation |
| Data corruption / availability | Log pipeline failure, lock issues, UCI sweep |
| Supply chain | Unpinned tooling, signing keys, feed trust |

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
| rpcd plugin + ACL scope | 2026-08-31 | Diff + selftest | B1 fixes: redirect via mktemp-only helper (`_fwlive_mktemp`, fixed `/tmp`, `TMPDIR` deliberately ignored), duplicate-key skip, poll clamp length check; read/write split; no `ubus log.*`; predictable-path and bare-`mktemp` fallbacks removed, graceful degradation when mktemp absent |
| Shell helpers — injection and quoting | 2026-08-13 | Read | #177: no log data reaches a command string |
| Shell helpers — **file modes and lock ownership** | 2026-08-31 | Reproduced | #204 symlink reject + #232 BusyBox-safe dir check (`[ -O ]` + `find -perm`, no `stat -c`); Parts E/F in `fwlive-logging-lock.test.sh`; lock 0600 (Part D) |
| Shell helpers — **uninstall baseline restore (`prerm`)** | 2026-08-22 | Read + host test | `/etc/fwlive/wan-log-baseline`; restore only on `remove` |
| Shell helpers — **UCI commit scope and zone grammar** | 2026-09-03 | Host test + Fable | #177 pending-delta; #241 cfg↔@zone; **B-1** canonical `uci -X` identity (duplicate wan no longer under-matches); `tests/fwlive-logging.test.sh` |
| Release pipeline — secrets and key handling | 2026-08-18 | Reproduced | #177 key-mode re-run; R7 pin-before-mount + `--network none` ([#179](https://github.com/lucas-albers-lz4/fwlive/issues/179)); 2026-08-18 hardening parity + R7 wrapper fix |
| Release pipeline — fetch pinning | 2026-08-18 | Read + host test | #177 fetch-pin gate; R7 digest pin-cache (`tests/sdk-matrix-digests.test.sh`); 2026-08-18 wrapper-export + exact-cache-key |
| Workflow inputs into `run:` bodies | 2026-08-23 | Read | Clean — inputs pass through `env:`; actions SHA-pinned including `FEED_DEPLOY_KEY`; 2026-08-18: dispatch tag validated (control chars, shape, real-tag + HEAD identity) before repo scripts |
| LuCI view (templates / shipped JS) | 2026-09-03 | Delta + Fable | `#fwlive-backend` via `textContent` only; `timeout_missing` warnings; Wave B Playwright = UX contract — XSS SoT remains recording-`innerHTML` harness (NON-FINDING) |
| Package/install surface (Makefiles, prerm, feed layout) | 2026-08-23 | Read | No ACL or path regressions |
| Build inputs (`feeds.lock`, `package-lock.json`) | 2026-08-23 | Read | Pins intact |
| Dev tooling (`.cursor/mcp.json`) | 2026-08-23 | Read + fix | #205: unpinned `@playwright/mcp@latest` removed; UI tests use pinned `playwright` devDep |
| Lab deploy helper (`scripts/agent-build-and-deploy.sh`) | 2026-09-03 | Read + fix | #261: SSH host-key verification ON by default; `ALLOW_INSECURE_SSH=1` / `--lab-only` opt-in with warning |
| Lab honest-gap smokes | 2026-09-04 | Lab smoke | `scripts/qemu-security-gaps-smoke.sh` gaps 1–3 green 2026-09-04; gap-2 BusyBox `flock` (no `-w`) accepted residual; `tests/validate-feed-keys-mode.test.sh` (gap 4 validate-prefix → `host`) |

## Controls in force

| Control | Proof class | Where |
|---------|-------------|-------|
| Sessions never receive `ubus log.*` | `host` | `tests/fwlive-rpcd-security.test.js` |
| Lab `.ipk` deploy keeps SSH host-key verification unless explicitly opted in | `manual` | `scripts/agent-build-and-deploy.sh` — default empty `SSH_OPTS`; `ALLOW_INSECURE_SSH=1` or `--lab-only` required for `StrictHostKeyChecking=no` (#261) |
| Read and write ACL scopes stay separate | `host` | same |
| Caller line count validated and clamped | `host` | rpcd `__selftest` |
| Poll line-count clamp rejects over-long digit strings before numeric compare (no silenced `test` overflow) and maps `0`→50 | `host` | rpcd `poll_clamp_lines` helper + `__selftest` (over-long, zero, 2001, 500) — defence-in-depth for read-ACL reachable `poll` |
| Addresses shape-validated before `nslookup` | `host` | rpcd `__selftest`, incl. a literal `$(reboot)` token |
| Missing `nslookup` surfaces `error:no_resolver` (not silent empty names) | `host` | `tests/fwlive-rules-map.test.js` `testResolveNslookup` |
| `json_escape` is defined in `fwlive-logging.sh` (prerm standalone) | `host` | `tests/fwlive-logging.test.sh` type check; rpcd `__selftest` |
| UCI rule names with whitespace are not word-split into junk keys | `host` | `tests/fwlive-rules-map.test.js` `testUciWhitespaceNames` |
| `jsonfilter` declared; missing filter exits non-zero with `error` | `host` | Makefile `LUCI_DEPENDS`; `tests/fwlive-shell-filter.test.js` `runMissingJsonfilter` |
| JSON filter unescapes libubox string escapes (`\b` `\f` `\n` `\r` `\t` `\u00XX`) before classify | `host` | `tests/fwlive-shell-filter.test.js` `runJsonGetMsgEscapes` / `runJsonParity` |
| JSON string content escaped per RFC 8259 | `host` | rpcd `__selftest` |
| WAN log toggle serialized against concurrent callers | `host` | `tests/fwlive-logging-lock.test.sh` (32-trial race) |
| Reload failure rolls back the UCI write | `host` | same |
| `resolve` bounded by a wall-clock budget | `manual` | `RESOLVE_BUDGET`; no test asserts the bound |
| `poll` bounded by `POLL_LINES_MAX` | `host` | rpcd `__selftest` (clamp helper tested without jshn) |
| Rules map temp file created only via `mktemp` (`_fwlive_mktemp`, fixed `/tmp` after a sticky-dir check, `TMPDIR` NOT honoured, no `rm`+reuse) with graceful degradation; accumulation via redirect keeps global first-wins dedup | `host` | `tests/fwlive-rules-map.test.js` production-path stubs under `dash` (and `busybox sh` when BusyBox honours PATH); `testNoMktempGracefulDegradation`; `testTmpDirSticky` |
| Rules map has no predictable-path write (no `$$` fallback); `>` follows a symlink if one is there, so safety is the unpredictable mktemp name plus a verified sticky `/tmp` | `host` | `tests/fwlive-rules-map.test.js` `testNoMktempGracefulDegradation` (mktemp shadowed, asserts no `/tmp/fwlive-{nft,ipt,ip6t}*` created; would catch `printf '/tmp/...-$$'` primitive); `testTmpDirSticky` |
| Rules map emits each key at most once (global first-wins in `map_add`, plus slug==raw skip) | `host` | same test — raw JSON duplicate-key assertion |
| `/tmp` used for ruleset dumps is a real directory with the sticky bit (fail closed; POSIX `[ -k ]`, no `stat`) | `host` | `_fwlive_tmp_dir_ok`; `tests/fwlive-rules-map.test.js` `testTmpDirSticky` |
| Every `E()` string child is array-wrapped | `host` | rendering harness ([#138](https://github.com/lucas-albers-lz4/fwlive/issues/138)) |
| Actions SHA-pinned, including the step receiving `FEED_DEPLOY_KEY` | `manual` | `.github/workflows/publish-packages.yml` — `peaceiris/actions-gh-pages@84c30a85c…` = `v4.1.0` (verified 2026-08-13); CodeQL alert 7 closed as **fixed**; re-check before each `v*` tag ([#178](https://github.com/lucas-albers-lz4/fwlive/issues/178)) |
| SDK image digest-pinned at first **secret-touching** pull | `host` | `sdk_matrix_pull_and_pin` in `validate-feed-keys.sh`; `feed_publish_apply_sdk_pin` before opkg/apk sign; `tests/sdk-matrix-digests.test.sh` |
| Signing-secret containers have no network | `host` | `docker run --network none` on validate usign check and opkg/apk sign steps (Compose v2 has no `--network` on `compose run`); same test |
| Signing secrets stay 0600 through validate-feed-keys rewrite prefix (decode/normalize/chmod) | `host` | `tests/validate-feed-keys-mode.test.sh` — calls shared `feed_keys_validate_*_rewrite_prefix` (same helpers as `validate-feed-keys.sh`) including a base64 decode rewrite; full docker usign sign on next `v*` still prove-next |
| `ipkg-make-index.sh` pinned to a commit SHA and sha256-verified | `manual` | `feed_publish_ipkg_index_script` |
| Only public keys reach `feed-staging/` | `manual` | `feed_publish_copy_keys` |
| Signing secrets are mode 0600 | `host` | `tests/feed-keys-mode.test.sh` — both storage formats under umask 022 |
| Fetched build helpers verified before execution | `host` | `tests/fetch-pin-gate.test.sh` — usign commit-pinned; `get-sdk.sh` sha256-verified |
| Publish job runs under Environment `feed-publish` | `manual` | `.github/workflows/publish-packages.yml` `environment:` — organizational gate (protection rules optional; none configured, matching usrmanage). Does NOT scope repo-level secrets — keys stay repository-scoped by design |
| Checkout never writes GITHUB_TOKEN into `.git/config` | `manual` | same workflow — `persist-credentials: false` (workspace is bind-mounted into SDK) |
| workflow_dispatch tag validated before `GITHUB_ENV` write | `manual` | same workflow — newline/control-char rejection + `^v[0-9]` shape |
| SDK feed cache key is exact (no `restore-keys` prefix fallback) | `manual` | same workflow — stale feed pins cannot be restored on cache miss |
| SDK cache dirs owned by buildbot (1000:1000), owner-write + group/other read-traverse; enforced fail-closed pre-build (skipped only when CI pre-chowned both trees, roots AND nested entries; scan errors fail closed) | `host` | `tests/sdk-matrix-cache-owner.test.sh` — #208 (v0.1.36 chown regression) |
| WAN toggle changes only the zone `log` bit | `host` | `tests/fwlive-logging.test.sh` — pending-delta refuse; named + anonymous zone lookup |
| WAN zone identity for staged `uci changes` uses canonical cfg ids (`uci -X`), not class-match on `name=wan` | `host` | `uci_canonical_firewall_section` + `wan_firewall_zone_same`; B-1 duplicate-wan foreign `.log` stays foreign (`tests/fwlive-logging.test.sh`) |
| Uninstall restores WAN `log` from pre-first-enable baseline | `host` | `tests/fwlive-logging.test.sh` — baseline snapshot/restore; `scripts/qemu-logging-uninstall-smoke.sh` (`lab`) |
| The WAN logging lock cannot be held by an unprivileged user | `host` | `tests/fwlive-logging-lock.test.sh` Part D — create+tighten to 0600 |
| Lock path rejects symlinks before truncate/chmod/chown | `host` | `tests/fwlive-logging-lock.test.sh` Part E — #204 |
| Production lock dir check works without `stat -c` (BusyBox `STAT=n`) | `host` | `wan_log_lock_dir_safe`: `[ -O ]` + `find -prune -perm`; Part F shadows `stat` |
| Rules map prefers `!fw4:` labels over earlier cosmetics for the same prefix (UCI still first-wins) | `host` | labeled-then-unlabeled passes; `tests/fwlive-rules-map.test.js` `testFw4LabeledBeatsCosmetic` |
| `iptables-save` / `ip6tables-save` bounded by `IPTABLES_TIMEOUT`; rules map key/byte capped | `host` | `testIptablesSaveTimeout`, `testRulesMapKeyBound` |
| mktemp-skip on rules map surfaces `error:mktemp_failed` | `host` | `testNoMktempGracefulDegradation` |
| `timeout` absent surfaces `timeout_missing` warning (fail-closed `run_with_timeout` diagnosability; non-gating) | `host` | `fwlive-logging.sh` `collect_logging_warnings` → `logging_status` `warnings`; `#fwlive-backend` span in `view/status/fwlive.js` (`command -v timeout` probe, POSIX) |
| Rules-map degradation (`rules_truncated`/`mktemp_failed`/`rules_unavailable`) surfaces in `#fwlive-backend` span, not the live counter / paused class | `host` | `view/status/fwlive.js` `updateBackendUi` (backend label + ` · ` + error via `_()`), `updateStatus` always reaches counter branch; `lastPollError` precedence unchanged |

## Open findings

| ID | Severity | Issue | Summary |
|----|----------|-------|---------|

## Verified findings (closed in this ledger)

| ID | Severity | Issue | Summary | Verified |
|----|----------|-------|---------|----------|
| B-1 | Low | `wan_firewall_zone_same` class-matched any `name=wan` zone | Canonical `uci -X` cfg id compare; duplicate wan `.log` stays foreign | 2026-09-03 — multi-model audit |
| [#204](https://github.com/lucas-albers-lz4/fwlive/issues/204) | Low | Predictable lock path opened O_TRUNC without symlink check | Lock under `/etc/fwlive/`; `acquire_wan_log_lock` rejects `-L` before create/tighten/open; Part E | 2026-08-23 — security-audit PR |
| [#205](https://github.com/lucas-albers-lz4/fwlive/issues/205) | Low | Unpinned `@playwright/mcp@latest` in `.cursor/mcp.json` | MCP entry removed; tests use pinned `playwright@1.60.0` | 2026-08-23 — security-audit PR |
| [#190](https://github.com/lucas-albers-lz4/fwlive/issues/190) | Low | `is_resolvable_address` hostname-shaped tokens | Strict IPv4/IPv6 validation + selftest cases | merged 2026-08-21 |
| [#191](https://github.com/lucas-albers-lz4/fwlive/issues/191) | Low | `uci commit firewall` foreign-delta sweep | Pre/post-stage gates + post-commit verification; residual window documented | merged 2026-08-23 |


## Accepted residuals

Known, judged acceptable. Reopen only with new evidence.

| Residual | Why accepted |
|----------|--------------|
| Any local UID can inject syslog lines that pass the firewall classifier | `logd` chmods its socket 0666 upstream (ubox `log/syslog.c`). Not fixable from this package; the consequence is forged rows in the view, and every field is already rendered as text |
| `date +%s` can jump under NTP sync, over- or under-running `RESOLVE_BUDGET` | Worker starvation is still prevented, which is the property the budget exists for |
| A LuCI admin session is root-equivalent | Structural to LuCI. It is the reason script execution on this page is treated as a root compromise, not a lesser bug |
| `uci commit firewall` is package-wide ([#191](https://github.com/lucas-albers-lz4/fwlive/issues/191) residual) | OpenWrt has no option-scoped commit. Pre/post-stage gates refuse when foreign staging is visible. A second privileged writer can still stage in the short interval before commit and publish those changes in the same `uci commit` — two root processes publishing each other's already-staged work. Unprivileged staging is blocked by libuci dir modes. Reopen only with an unprivileged or cross-session path. |
| `feed_publish_ensure_usign` leaves its build dir for the process lifetime | `PATH` points into it and `usign` is called later; the name is unpredictable per invocation, and `/tmp` is reaped on reboot |

## What this pass could not prove

Honest gaps, so the next pass starts here rather than rediscovering them.
Lab runner: `./scripts/qemu-security-gaps-smoke.sh` (gaps 1–3). Host validate
path: `tests/validate-feed-keys-mode.test.sh` (gap 4 prefix; wired into
`./scripts/fwlive-test.sh`).

| Property | Status | What would prove it |
|----------|--------|---------------------|
| `resolve` really returns within its budget on a loaded router | lab smoke 2026-09-04 (responsiveness only; not blackhole-DNS budget proof) | Flood returned in 1s under `RESOLVE_SLACK_SEC=8` |
| The rpcd script timeout actually bounds a blocked `flock` waiter | lab smoke 2026-09-04; BusyBox has no `flock -w` (**accepted residual** — client timed out, residual holds) | Host-side timeout fired; does not promote residual to cleared |
| Pre-stage `firewall_changes_pending` refuse on a live device | lab smoke 2026-09-04 (**accepted residual** for package-commit publish of foreign staging — see above) | Foreign staging refused; foreign delta neither committed nor dropped |
| Signing keys stay 0600 through validate rewrite path | `host` (validate-prefix) | `tests/validate-feed-keys-mode.test.sh` — write + shared `feed_keys_validate_*_rewrite_prefix` (decode/normalize/chmod; base64 branch). **Full usign docker sign + real publish** still prove-next on next `v*` tag |

## Review procedure

The *how* lives in
[`.cursor/skills/security-audit/SKILL.md`](../../.cursor/skills/security-audit/SKILL.md)
(including § Multi-model pass for gaps → delta → gated full pass).
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
parser, deciding something that matters. Call `uci`/`nslookup`/`fw4`, or fail
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

### 2026-08-23 — Read-only audit + remediations (#204, #205, #206)

**Scope.** Full-surface read-only pass (log parsing/logging script, rpcd plugin + ACL,
LuCI view, package/install surface, CI workflows, release + signing, build inputs,
dev tooling). Filed [#204](https://github.com/lucas-albers-lz4/fwlive/issues/204),
[#205](https://github.com/lucas-albers-lz4/fwlive/issues/205), [#206](https://github.com/lucas-albers-lz4/fwlive/issues/206).

**Method.** Read-only inspection against `master`; upstream source checks where
relevant. Two findings remediated in the same PR: symlink guard on the WAN logging
lock (#204), removal of unpinned `@playwright/mcp@latest` (#205). Ledger refresh
(#206) records verified state.

**Findings fixed in PR.**

- **#204** — WAN logging lock moved to `/etc/fwlive/logging.lock` (root-only dir);
  `acquire_wan_log_lock` fails closed on `-L` before create, chmod/chown, and
  `exec 9>`; Part E in `fwlive-logging-lock.test.sh`.
- **#205** — `.cursor/mcp.json` playwright MCP removed; UI smoke tests use pinned
  `playwright@1.60.0` from `package.json`.

**Non-findings** (surfaces examined, clean):

- rpcd plugin + ACL: read/write split; no `ubus log.*`; selftests intact.
- LuCI view: no new HTML sinks; untrusted values remain text nodes.
- CI workflows: no `${{ }}` in `run:` bodies; actions SHA-pinned.
- Release + signing: R7 controls unchanged; no new unpinned fetches.
- Build inputs: `feeds.lock` / `package-lock.json` pins intact.

**Result.** Open findings table empty. #204/#205 in Verified findings. `SECURITY.md`
links to this ledger for review state.

### 2026-08-31 — B1 rpcd fixes (Task 1–3)

**Scope.** `build_rules_map` pipeline subshell (rules map empty in production), duplicate JSON keys when slug==raw, `poll_lines_from_input` overflow/zero clamp bypass. File: `openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive`.

**Method.** Host reproduction under `dash` and `busybox sh`; stub-based `rules` method tests (nft + iptables-save on PATH); `__selftest` with `poll_clamp_lines` helper; `shellcheck -s sh`.

**Fixes (minimal, POSIX sh).**

- **Task 1 (pipeline):** The first cut captured fragments via `frag=$(nft_list_ruleset | { OUT=''; map_from_nft_stream; printf '%s' "$OUT"; })` so the map escaped the pipeline subshell. That left no global first-wins `OUT` across backends. R4 (below) replaced it with `_fwlive_mktemp` + redirect so accumulation stays in the main shell. `run_with_timeout $NFT_TIMEOUT` and the `ip6tables-save` presence check are unchanged. `rulesmap_from_iptables_file` (redirect path) was already on the non-pipeline path. Verified both shells; test fails before fix (empty map) and passes after.
- **Task 2 (duplicate keys):** Two layers. `map_prefix_with_label` / `map_uci_rule_names` skip a second `map_add` when `slug==raw` (fw4 lower-hyphen identity). `map_add` itself is global first-wins against `$OUT` (`case "$OUT" in *"\"$esc_key\":"*)`), so the same key from UCI + nft + iptables is emitted once. The slug==raw skip is not a substitute for that global state.
- **Task 3 (poll clamp):** Added `poll_clamp_lines` helper: strip leading zeros, if empty →50, if `${#tmp} > ${#POLL_LINES_MAX}` →2000 before any `test -gt`, else safe numeric clamp. `poll_lines_from_input` delegates to helper. `0` now →50, over-long (`99999999999999999999`, `18446744073709551616`) →2000, `2001` →2000, `500` passes. Helper tested without `jshn` (direct `poll_clamp_lines` calls) and with `jshn` via `poll_lines_from_input`; read-ACL reachable `poll` is now defence-in-depth clamped without relying on silenced `test` error.

**Result.** Three new host controls (see table). Accumulation via redirect (no pipeline subshell) enables global dedup. `shellcheck` and `./scripts/fwlive-test.sh` pass.

### 2026-08-31 — R4 temp-file hardening (round 4)

**Scope.** Predictable temp path `printf '/tmp/fwlive-nft-%s' "$$"` fallback in `build_rules_map` (3 sites) gave a root-level arbitrary-write primitive via symlink at `/tmp/fwlive-*` (PIDs brute-forceable). `mktemp` present on OpenWrt (BusyBox) so fallback unlikely but must not exist in root-context code. Same class as #204 (lock symlink).

**Method.** Grep for `$$` / `printf.*fwlive`; host reproduction under `dash` + `busybox sh` with `mktemp` shadowed (absent).

**Fix (minimal, POSIX sh).**

- **Delete fallback:** removed `|| printf '/tmp/fwlive-nft-%s' "$$"` from all 3 sites (no predictable-path code path remains).
- **Single helper:** `_fwlive_mktemp <prefix>` — `_fwlive_tmp_dir_ok` then `mktemp "/tmp/<prefix>.XXXXXX" 2>/dev/null` only. `TMPDIR` is **deliberately not honoured** and there is **no bare-`mktemp` fallback**: bare `mktemp` consults `TMPDIR`, and an attacker-writable non-sticky `TMPDIR` would restore the create-then-reopen (TOCTOU) symlink-write primitive, since `build_rules_map` reopens the path with `>` while running as root. Stickiness of `/tmp` is **checked** with POSIX `[ -k ]` (not `stat -c`, which default OpenWrt BusyBox may omit). Fail closed → skip enrichment. Never `rm`+reuse, never `touch`/`chmod`. If `mktemp` fails, the backend enrichment is skipped and a well-formed map is still returned. BusyBox `mktemp` sane.
- **Graceful degradation:** ``_tmp=$(_fwlive_mktemp fwlive-nft) || _tmp=''`` then `if [ -n "$_tmp" ]; then nft_list_ruleset >"$_tmp" ...; rm -f "$_tmp"; fi` — if `mktemp` absent/failing, backend enrichment skipped, still returns well-formed `{"backend":...,"rules":{...}}` with UCI names. No fixed-path write.
- **Cleanup guaranteed:** `rm -f "$_tmp"` is unconditional inside the `if [ -n "$_tmp" ]` block, immediately after use, with no early `return`/`exit` between creation and removal. nft, iptables, and ip6tables each get a fresh `_fwlive_mktemp` into the same `_tmp` after the previous file is removed. Failure path (`mktemp` empty) never creates a file, so no cleanup needed. The `map_from_*` helpers do not `exit` the shell.
- **tmpfs/RAM:** `/tmp` on OpenWrt is `tmpfs` (RAM). `NFT_TIMEOUT=5` bounds the nft dump's **duration, not its size**, and `iptables-save`/`ip6tables-save` run with **no timeout at all**; size is not bounded by code. Typical firewall dumps are <100KB and the file is removed immediately after parsing, so RAM impact is negligible in practice. No pipeline subshell reintroduced (global `OUT` dedup preserved).
- **Cleanup:** inline `rm -f` immediately after parsing, with no `return`/`exit` between creation and removal. No `trap` — a signal can leak one root-owned 0600 file in sticky `/tmp`, which tmpfs clears on reboot; portable `trap` save/restore across `dash`/BusyBox `ash` (no `trap -p`) was judged to add more failure surface than it removes. Reviewed and accepted at the gate.

**Test.** `testNoMktempGracefulDegradation` in `tests/fwlive-rules-map.test.js` — shadows `mktemp` (exit 127) at front of `PATH`, calls `rules` under `dash` (and `busybox sh` only when BusyBox honours PATH; Ubuntu standalone applets skip). Asserts: (1) well-formed JSON + `backend==nft` + UCI names still present (catches missing degradation / malformed JSON), (2) no `/tmp/fwlive-{nft,ipt,ip6t}*` file created (catches predictable-path symlink write), (3) nft-derived key `should-not-appear` absent (catches fixed-path dump still being parsed). `testTmpDirSticky` pins reject of a non-sticky dir and of a symlink. Verified `grep -n '\$\$' rpcd/fwlive` empty and `grep -n 'mktemp'` shows only helper + call sites.

### 2026-08-31 — R5 remaining luci#8992 folds (#228)

**Scope.** Second wave of [openwrt/luci#8992](https://github.com/openwrt/luci/pull/8992) review fixes after B1/R4: hostname resolve without `getent`, declared `jsonfilter` dependency, one-pass awk classifier (poll fork storm), `json_escape` owned by `fwlive-logging.sh` for standalone `prerm`, JSON unescape before classify, UCI whitespace rule-name skip, luci-copy `SOURCE_DATE_EPOCH` / dual-maintenance docs. Sticky `/tmp` via POSIX `[ -k ]` is recorded under R4; this entry covers the #228 surface.

**Method.** Host `./scripts/fwlive-test.sh` (dash + BusyBox ash stubs); `validate-baseline.sh` for `+jsonfilter` in `LUCI_DEPENDS`; shell-filter / rules-map / logging suites.

**Fixes recorded.**

- **Resolve:** BusyBox `nslookup` replaces `getent`; missing resolver → `error:no_resolver` (not empty `names`).
- **Poll filter:** `+jsonfilter` hard depends; missing binary → non-zero + `error:jsonfilter_missing`; classifier is one awk pass; filter is one `jsonfilter` + one awk; libubox string escapes unescaped before classify.
- **prerm / escape:** `json_escape` lives in `fwlive-logging.sh` so `prerm` can source it standalone (#222).
- **Rules map:** UCI names with whitespace are not word-split into junk keys (#226).
- **Docs / cut:** dual-maintenance policy and Dependencies prose for the luci snapshot (#224/#225).

**Result.** Controls for nslookup, `json_escape` ownership, whitespace UCI names, `jsonfilter` depends, and JSON unescape added to the table. Open findings none from this wave; post-merge follow-ups filed separately (#229–#235).

### 2026-08-31 — #232 BusyBox-safe WAN lock dir check

**Scope.** `wan_log_lock_dir_safe` used `stat -c '%u'/'%a'`, which default OpenWrt BusyBox omits (`STAT=n` / `FEATURE_STAT_FORMAT=n`). Fail-closed then made Enable/Disable WAN logging dead on a stock image.

**Fix.** `[ -O ]` for euid ownership; `find -prune \( -perm -020 -o -perm -002 \)` for group/other write. No `stat`. Part F in `fwlive-logging-lock.test.sh` shadows `stat` on `PATH`.

### 2026-09-03 — Multi-model VVAH pass (playbook + delta + B-1)

**Scope.** Document portable multi-model audit (fwlive skill + usrmanage twin); Stage 0 seed; Stage 1 delta packets (warnings UI, zone grammar, Wave B harness, Stage-0 class memory); Fable Stage 2 on flagged packets; validation panel; Composer fix for B-1. Honest-gap lab scripts landed (QEMU not available this pass).

**Method.** Deterministic greps + `./scripts/fwlive-test.sh` / shellcheck; Grok+Luna job packets; Fable 5.1 Engineer Mode on UCI grammar + Wave B proof boundary; Luna validation panel on B-1.

**Finding fixed in-tree (no public issue — Low, fixed same pass).**

- **B-1** — `wan_firewall_zone_same` treated any `name=wan` zone as identical. Duplicate wan `.log` deltas were able to publish with a commit. Now compares canonical cfg ids via `uci -X show`. Host test covers duplicate-wan foreign line.

**Non-findings**

- `#fwlive-backend` / `timeout_missing`: `textContent` + allowlisted `_()` strings only.
- Wave B Playwright: UX contract only; XSS SoT remains recording-`innerHTML` harness (Fable NON-FINDING).
- Stage-0 class memory: no new `${{ }}` in `run:`, no new temp-mode/pin regressions in delta.
- UCI `.log_*` near-miss grammar (#257) holds under Fable checklist.

**Full-pass gate.** Deferred — no class bug beyond B-1 (fixed), no high/medium blast radius. The pin checklist is not due until the next `v*` tag. Next: QEMU `qemu-security-gaps-smoke.sh` for gaps 1–3.