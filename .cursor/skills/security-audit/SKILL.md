---
name: security-audit
description: Audit the fwlive repository for security issues — LuCI frontend injection sinks, the root rpcd plugin, shell helpers, and the signing/release pipeline. Use when the user asks for a security audit, security review, threat model, or hardening pass on this repo, or asks whether log data is safely rendered.
---

# fwlive security audit

Repeatable audit procedure. Read
[`docs/developer/security-model.md`](../../../docs/developer/security-model.md)
for the trust boundaries and invariants, and
[`docs/developer/security-review.md`](../../../docs/developer/security-review.md)
for what has already been checked, with what proof, and what is open. This file
is the *how*.

After a pass, update the coverage map in the ledger. Record a proof class for
every control the pass touches. Record the non-findings — see
[security-review.md § Review procedure](../../../docs/developer/security-review.md#review-procedure).

## Multi-model pass (VVAH-style)

Sibling OpenWrt packages (for example usrmanage) share this loop. Do cheap,
deterministic work first. Reserve a **frontier reasoner** for narrow judgment
only. Do not invent a new procedure in chat — follow this section.

### Phase order

1. **Close open issues / prove honest gaps** (ledger `Next:` / cannot-prove /
   prove-next) before a broad re-read.
2. **Delta** since the last coverage-map dates (touched surfaces only).
3. **Full-pass gate** — run it only if one of the criteria below is true.
   Otherwise record the deferral.

### Frontier reasoner profiles

Pick **one** Stage-2 reasoner for the pass. Do not mix both in the same packet
round.

| Profile | Stage 2 (reason) | Stage 1 helpers | Validation panel | Notes |
|---------|------------------|-----------------|------------------|-------|
| **Fable** (default when available) | Claude Fable 5.1 — medium effort; high only for root/XSS chains | Grok (map) + Luna (polish) | Luna + Grok (severity) | Strong on multi-step OpenWrt/LuCI chains |
| **GLM** (alternate review process) | GLM-5.3 at **max thinking** | Luna + GLM-5.3 Flash **or** DeepSeek V4 Flash | Luna + the same flash helper (pairwise) | Use when the orchestrator runs GLM instead of Fable. Use max thinking. Medium or low thinking does not reason enough about ACL and commit scope. |

Composer remains Stage 3 (patches) under both profiles. Doc-only PRs do not
need a frontier reasoner — Luna (+ optional Grok for cross-repo wording) is
enough.

### Stages and models

| Stage | Job | Model (see profile above) | Token rule |
|-------|-----|---------------------------|------------|
| 0 Static seed | Repo greps (below), shellcheck/smoke, key `git check-ignore`, action SHA pin spot-check | Deterministic | Zero LLM |
| 1 Prep & triage | Job packets from ledger + diff | Profile helpers | Cheap |
| 2 Audit & reason | Multi-step chains; Engineer Mode; fix sketch beside each finding | Profile frontier reasoner | Premium, narrow |
| 3 Execute & fix | Patches, tests, ledger | Composer | Bulk output |
| Validation panel | Mechanism real? severity calibrated? duplicate of accepted residual? | Profile validation pair | Cheap gate before filing |

**Keep review and patching separate:** The Stage-2 reasoner must not write
patches in bulk. Composer must not invent new trust boundaries. Edit the model
doc only when a finding falsifies it. Validation-panel models score candidates
before `gh` advisory/issue.

**Engineer Mode (Stage-2 stub):** You are reviewing production code for
structural security flaws. For each finding: mechanism, location, blast radius,
severity per the calibration table, and a concrete fix sketch. Do not role-play
an attacker sandbox or request exploit payloads. Scope is exactly the attached
job packet checklist — not "find any security issue."

**Static cache block (identical on every Stage-2 call):** one-line threat model +
invariants from
[`security-model.md`](../../../docs/developer/security-model.md) + ACL method
table + severity calibration below.

### Job-packet template

Ephemeral (chat or scratch dir — do not commit these files):

- Files / short diff summary
- Cached threat-model block (above)
- Checklist (surface-specific)
- Prior non-findings for that surface from the ledger
- Expected proof class on exit (`host` / `lab` / `manual`)

### Full-pass gate

Run a full surface re-pass only if one of:

- A gap failed and suggests a **class** bug (fix-the-class sweep)
- The Stage-2 reasoner finds a high or medium issue whose blast radius goes
  beyond the touched files
- A root-reachable control is still only `manual` with no raise path
- You are about to cut a `v*` tag, and the pin checklist is stale

Otherwise update coverage-map dates for surfaces examined. Record non-findings.
Set ledger `Next:` to the deferral reason.

### Cross-repo class memory (Stage 0 checklist)

Make sure that each item below is true. Use grep. Do not send this list to
Stage 2:

- Temp mode loss after `mv` / normalize rewrite
- Unswept pin neighbors (one helper pinned, sibling not)
- Hand-parsed platform formats narrower than `uci`/`fw4`/`nslookup`
- R7: digest-pin before secret mount + `--network none` on signing containers
- Workflow `${{ }}` interpolated into `run:` bodies

### fwlive bindings

| Binding | Value |
|---------|-------|
| Threat model | [`docs/developer/security-model.md`](../../../docs/developer/security-model.md) |
| Ledger | [`docs/developer/security-review.md`](../../../docs/developer/security-review.md) |
| Host gate | `./scripts/fwlive-test.sh`, `./scripts/fwlive-shellcheck.sh` |
| Lab / honest-gap smokes | `./scripts/qemu-smoke-fwlive.sh`, `./scripts/qemu-security-gaps-smoke.sh` |
| Highest-yield surface | Frontend `E()` / log XSS (Steps 1–2 below) |
| Honest gaps | Ledger § What this pass could not prove |

## Order of work

Highest yield first when running a **full** surface pass. Use the multi-model
phase order above for routine audits.

```
- [ ] 0. Multi-model: open issues / honest gaps → delta → gate
- [ ] 1. Frontend rendering sinks (E() string children)
- [ ] 2. Untrusted-input trace (log fields, PTR, URL hash, UCI)
- [ ] 3. rpcd plugin + ACL scope
- [ ] 4. Shell helpers (injection, quoting)
- [ ] 5. Release pipeline (secrets, pinning, temp paths)
```
## Verified facts — do not re-derive

The facts themselves live in the security model; this section only records **how
to re-confirm them** if upstream changed. Read
[`security-model.md`](../../../docs/developer/security-model.md) first — do not
re-reason about trust boundaries from source.

| Fact | Re-verification |
|------|-----------------|
| LuCI `E()` assigns bare string children to `innerHTML`; only array children become text nodes | `curl -sS https://raw.githubusercontent.com/openwrt/luci/openwrt-24.10/modules/luci-base/htdocs/luci-static/resources/luci.js \| rg -n "innerHTML" -B 20` |
| `logd` chmods its socket `0666`, so any local UID can inject syslog lines | `curl -sS https://raw.githubusercontent.com/openwrt/ubox/master/log/syslog.c \| rg -n "chmod"` |
| Netfilter values parse as `[^\s]+`, so whitespace-free content survives intact | `rg -n "A-Z\]\+\)=" openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js` |

Time-savers learned the hard way:

- `dom.js` does **not** exist on the `openwrt-24.10` branch — `dom` lives inside
  `luci.js`. Fetching `dom.js` returns 404 and wastes a round trip.
- Renderer tests do not render, so a green suite proves nothing about encoding —
  [build-and-test.md § Renderer tests do not render](../../../docs/developer/build-and-test.md#renderer-tests-do-not-render).

## Step 1 — frontend rendering sinks

Find `E()` calls whose third argument is a bare identifier or expression rather
than an array:

```sh
rg -n "E\('[a-z]+',\s*(\{[^}]*\}|null),\s*[A-Za-z_$][A-Za-z0-9_.$]*(\(|\)|,|\s*\|\||$)" \
  openwrt-feed/luci-app-fwlive/htdocs
```

Then confirm which of those carry untrusted data by tracing the argument back to
`normalizeEntry`, the hostname cache, or the filter state. The regex matches
bare identifiers. This includes **array-typed variables**, which are safe.
For example, `E(..., parts)` where `parts = []` creates text nodes. Trace the
identifier declaration first. Only string-typed or function-call third
arguments are candidates. Also check direct
sinks:

```sh
rg -n "innerHTML|insertAdjacentHTML|outerHTML|document\.write|eval\(|new Function" \
  openwrt-feed/luci-app-fwlive/htdocs
```

`host.innerHTML = ''` to clear a container is fine. Anything with a non-empty
right-hand side is not.

Confirm there is still no escaping helper:

```sh
rg -n "escapeHtml|sanitiz|textContent" openwrt-feed/luci-app-fwlive/htdocs
```

## Step 2 — prove it with a rendering harness

Do not assert an XSS finding from reading code. Build a harness that loads the
real modules against an `E()` that is a **verbatim port** of LuCI
`dom.create`/`dom.append`, with a `Node` class whose `innerHTML` **setter
records every write**. Then render a crafted row and assert no recorded write
contains `<`.

Essentials:

- Reuse `loadFwliveModule` from `tests/lib/load-fwlive-module.js`, passing the
  real `E` via `deps` so `log`, `links`, `table`, and `chips` all share it.
- Use a **whitespace-free** payload such as `<svg/onload=PWNED>`; anything with
  spaces gets split by the `[^\s]+` field parser and truncated mid-payload.
- Cover the default Simple view columns (`constants.js` `COLUMN_SETS.simple`),
  not just Detailed — a finding that needs a view toggle is weaker.
- Exercise all three input paths: a crafted log message, a `!`-prefixed filter
  value (URL hash), and a populated hostname cache.

This is the same harness [#138](https://github.com/lucas-albers-lz4/fwlive/issues/138)
turns into a permanent regression test — check whether it already exists in
`tests/` before writing a throwaway.

## Step 3 — rpcd plugin and ACL

Read `root/usr/libexec/rpcd/fwlive` end to end; it is short. Walk the invariants
in [`security-model.md`](../../../docs/developer/security-model.md) and confirm
each still holds, plus that CLI-only `__` methods stay absent from `list`.

```sh
node tests/fwlive-rpcd-security.test.js
sh openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive __selftest
```

## Step 4 — shell helpers

```sh
./scripts/fwlive-shellcheck.sh
rg -n "eval|\\\$\(.*\\\$[A-Za-z_]|>\s*/tmp/|mktemp" openwrt-feed/luci-app-fwlive/root scripts
```

Look for log content reaching a command string, and for fixed `/tmp` paths that
are read or executed rather than created with `mktemp`.

## Step 5 — release pipeline

```sh
rg -n "uses:|\\\$\{\{" .github/workflows
rg -n "curl|chmod \+x|PATH=" scripts/lib/feed-publish.sh
```

Check for: workflow inputs interpolated into `run:` blocks, actions pinned by
mutable tag (especially any step receiving a secret), fetched-and-executed
helpers without a checksum, predictable temp paths in the signing path, and
whether any secret can reach `feed-staging/`.

Confirm key files stay ignored — and their temp siblings too, which is how
[#165](https://github.com/lucas-albers-lz4/fwlive/issues/165) got past this
check:

```sh
git check-ignore -v opkg-secret.key apk-secret.rsa public.key fwlive-feed.rsa.pub
git check-ignore -v opkg-secret.key.tmp apk-secret.rsa.tmp
```

**Run the key path; do not read it.** A `chmod 600` in the source proves the
call exists, not that the mode survives the rest of the function:

```sh
( umask 022                     # GitHub runner default, not your shell's
  source scripts/lib/feed-keys.sh
  OPKG_SECRET=… APK_SECRET=… OPKG_PUB=… APK_PUB=… feed_keys_write_from_env "$d"
  stat -c '%n %a' "$d"/opkg-secret.key "$d"/apk-secret.rsa
  find "$d" -name '*.tmp' )
```

Do this for **both** documented secret formats — one-line paste and base64 —
because they take different code paths through `feed-keys.sh`.

Every `> "$f.tmp"` followed by `mv "$f.tmp" "$f"` is a mode-loss candidate,
anywhere in the repo:

```sh
rg -n '>\s*"\$\{?\w+\}?\.tmp"' scripts openwrt-feed
```

## Severity calibration

Judge by who can reach it, not by sink class alone.

| Severity | Bar |
|----------|-----|
| High | Unauthenticated or unprivileged-local attacker reaches an admin session or root |
| Medium | Requires a shared host, a maintainer mistake, or a narrow race |
| Low | Requires an authenticated session already holding the relevant ACL, or write access to the repo |

Anything reachable in the **default** Simple view with no interaction ranks
above something needing a view toggle or a settings change.

## Reporting

`SECURITY.md` prohibits public issues for vulnerabilities. Split the output:

- **Exploitable vulnerability** → private draft advisory:
  `gh api --method POST /repos/{owner}/{repo}/security-advisories --input advisory.json`
  (needs `summary`, `description`, and `severity` or `cvss_vector_string`).
  Optionally add a public tracking issue describing the *invariant* and files to
  sweep, with no payloads or injection path.
- **Hardening** → public issue, one atomic issue per fix, labels `security`
  and/or `supply-chain`.

Verify the advisory landed as `state=draft` before reporting success, and check
for duplicates — the create call returns compact JSON, so a filter expecting
spaces after colons will match nothing and look like a failure:

```sh
gh api /repos/{owner}/{repo}/security-advisories --jq '.[] | "\(.ghsa_id) \(.state)"'
```

## Accepted items — do not reopen without new evidence

Invariants 2–7 in [`security-model.md`](../../../docs/developer/security-model.md)
were each audited and found correctly implemented, as was the
`__rulesmap_iptables` fixed-path guard.

Re-examine them only with new evidence — a code change in the area, or a concrete
bypass. Spending the pass re-reading accepted shell is the main way an audit
runs out of time before reaching the frontend.

**Two entries were removed from this list on 2026-08-12**, and the reason
matters more than the bugs:

| Was listed as known-good | What running it showed |
|--------------------------|------------------------|
| Secret-key file permissions plus gitignore coverage | Secrets land 0644 in both documented formats, and `*.tmp` is not ignored ([#165](https://github.com/lucas-albers-lz4/fwlive/issues/165)) |
| WAN-log bit-0-only manipulation with UCI rollback | The `set` is bit-0-only; the `uci commit firewall` is package-wide ([#168](https://github.com/lucas-albers-lz4/fwlive/issues/168)) |

Both were cleared by reading the code and finding the right-looking line. That
is the failure mode this list creates: it converts one reader's impression into
a standing instruction not to look. Before adding an entry here, state what was
*executed* to clear it, and prefer a test in `tests/` — an entry with a test
behind it never needs this list.

Open items are tracked as issues, and the current state with severities and
recommended order is in
[`security-review.md` § Open findings](../../../docs/developer/security-review.md#open-findings):

```sh
gh issue list --label security --label supply-chain --state open
```
