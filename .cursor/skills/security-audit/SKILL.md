---
name: security-audit
description: Audit the fwlive repository for security issues — LuCI frontend injection sinks, the root rpcd plugin, shell helpers, and the signing/release pipeline. Use when the user asks for a security audit, security review, threat model, or hardening pass on this repo, or asks whether log data is safely rendered.
---

# fwlive security audit

Repeatable audit procedure. Read
[`docs/developer/security-model.md`](../../../docs/developer/security-model.md)
for the trust boundaries and invariants; this file is the *how*.

## Order of work

Highest yield first. The frontend is where the exploitable bugs live; the
backend has held up under audit.

```
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
`normalizeEntry`, the hostname cache, or the filter state. Also check direct
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

Confirm key files stay ignored:

```sh
git check-ignore -v opkg-secret.key apk-secret.rsa public.key fwlive-feed.rsa.pub
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

## Known-good — do not re-litigate without new evidence

Invariants 2–7 in [`security-model.md`](../../../docs/developer/security-model.md)
were each audited and found correctly implemented, as were the
`__rulesmap_iptables` fixed-path guard, the WAN-log bit-0-only manipulation with
UCI rollback, and secret-key file permissions plus gitignore coverage.

Re-examine them only with new evidence — a code change in the area, or a concrete
bypass. Spending the pass re-reading known-good shell is the main way an audit
runs out of time before reaching the frontend.

Open items are tracked as issues — check them before re-reporting:

```sh
gh issue list --label security --label supply-chain --state open
```
