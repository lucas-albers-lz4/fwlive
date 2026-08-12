# Security model

What fwlive trusts, what it must never trust, and the invariants that keep the
two apart. Read this before changing renderers, the rpcd plugin, or the release
pipeline.

Reporting a vulnerability: [`SECURITY.md`](../../SECURITY.md) — private
disclosure, never a public issue.

Whether a control below is actually *proven*, and what is currently open against
it: [security-review.md](security-review.md). This document says what must be
true; that one says what has been checked and how hard.

## Threat model in one line

fwlive renders attacker-influenced text inside a **root-equivalent** browser
session. A LuCI admin session can invoke arbitrary ubus methods, so script
execution on the fwlive page is equivalent to root on the router.

## Untrusted input inventory

Every value below reaches the browser. None of it is trustworthy.

| Input | Who controls it | Notes |
|-------|-----------------|-------|
| Firewall log message and every field parsed from it | **Any local process, any UID** | `logd` chmods its socket `0666` (ubox `log/syslog.c`), so any process can write arbitrary syslog lines. A line containing `SRC=`/`DST=` passes the firewall classifier |
| `IN` / `OUT` / `SPT` / `DPT` / `PROTO` / `TCPFLAGS` | Same as above | Captured as `[^\s]+`, so any whitespace-free content survives parsing intact |
| Reverse-DNS hostnames (`fwlive.resolve`) | Remote party owning the PTR record | libc restricts the character set in practice; do not rely on it |
| URL hash filter values | Anyone who can get an admin to open a link | `applyHash()` copies `#src=…` into the filter inputs, which feed the chip renderer |
| UCI values (`log_limit`, rule names, nft log prefixes) | Router admin, or any package writing UCI | Lower privilege distance, still not literals |

The log **prefix** is admin-configured, but the rest of a log line is not — do
not treat "the admin wrote the rule" as making a log line trustworthy.

## Invariants

Each one is testable. Breaking one is a security regression, not a style nit.

### 1. Every `E()` string child is wrapped in an array

Upstream LuCI `dom.append` branches on child type — array children become text
nodes, bare string children are assigned to `innerHTML`:

```js
if (Array.isArray(children)) {
    ...node.appendChild(document.createTextNode(`${children[i]}`));   // text
}
...
else if (children !== null && children !== undefined) {
    node.innerHTML = `${children}`;                                   // HTML
}
```

So `E('td', attrs, value)` renders HTML and `E('td', attrs, [ value ])` renders
text. **Always use the array form**, including for values that look constrained
today — the uniform rule survives future parser changes, per-field reasoning
does not.

Source: `modules/luci-base/htdocs/luci-static/resources/luci.js` in
[openwrt/luci](https://github.com/openwrt/luci) (`dom.append` / `dom.create`).

The shipped renderers are in full compliance. Every `E()` string child is
the array form. The sweep found 60 array-form calls and no bare-string
sinks. The rendering regression harness
([#138](https://github.com/lucas-albers-lz4/fwlive/issues/138), merged as
`tests/` coverage) keeps it that way. The compliance sweep landed with
[#137](https://github.com/lucas-albers-lz4/fwlive/issues/137).

### 2. Log data is never interpolated into a shell command string

`fwlive-log-filter.sh` passes messages as data through `jsonfilter`/`grep`
stdin. Keep it that way — no `eval`, no unquoted expansion into a command.

### 3. Addresses are shape-validated before reaching a subprocess

`is_resolvable_address` accepts only IPv4/IPv6-shaped tokens and rejects shell
metacharacters before `getent` runs. Its selftest asserts rejection of a literal
`$(reboot)` token.

### 4. Caller-supplied numbers are validated and clamped

`poll_lines_from_input` rejects non-numeric input and clamps to
`POLL_LINES_MAX`. Never interpolate a caller value into the `ubus call log read`
JSON without both steps.

### 5. All JSON string content passes through `json_escape`

Escapes `\`, `"`, tab, CR, LF, and remaining C0 controls per RFC 8259.

### 6. The ACL never grants `ubus log.read`

Sessions get `fwlive.*` only; the rpcd plugin performs the privileged log read
as root and returns filtered output. Enforced by
`tests/fwlive-rpcd-security.test.js`.

### 7. Read and write methods stay in separate ACL scopes

`rules` / `poll` / `resolve` / `logging_status` are read. Only
`enable_wan_logging` / `disable_wan_logging` are write.

## Privileged surface

The rpcd plugin runs as **root**. Its entire input surface is:

| Method | Input | Scope |
|--------|-------|-------|
| `rules` | none | read |
| `poll` | line count in `addresses[0]` | read |
| `resolve` | address array (max `RESOLVE_MAX`) | read |
| `logging_status` | none | read |
| `enable_wan_logging` / `disable_wan_logging` | none | write |

`__selftest` and `__rulesmap_iptables` are CLI-only and must never become ubus
methods. `__rulesmap_iptables` reads a fixed path and rejects argv-supplied
files.

The `uci set` touches only bit 0 of the WAN zone `log` value, and UCI is rolled
back if the firewall reload fails. The **commit** is wider than the set:
`uci commit firewall` publishes any delta already staged in `/tmp/.uci/firewall`
by another CLI actor ([#168](https://github.com/lucas-albers-lz4/fwlive/issues/168)).
An unprivileged user cannot stage such a delta — `/tmp/.uci` is `0700` (libuci
`UCI_DIRMODE`) — which is what keeps that finding Low.

Serialization of the toggle depends on a lock file that is currently created
world-readable, so any local UID can hold it and, with no BusyBox `flock -w`,
block both toggles until reboot
([#167](https://github.com/lucas-albers-lz4/fwlive/issues/167)).

## Supply-chain surface

Release artifacts are signed and served from a binary feed, so build inputs are
part of the security boundary.

| Surface | Control |
|---------|---------|
| Feed signing keys | CI secrets, written under `umask 077` then `chmod 600` **after** normalize/decode; only public keys are staged for publish. Host-asserted by `tests/feed-keys-mode.test.sh` |
| Package contents | `verify-reproducible-build.sh` — determinism of our inputs within a run |
| OpenWrt feeds | Pinned in `scripts/feeds.lock/` |
| SDK base images | Digests resolved per cell and recorded in the release manifest (no mutable-tag reliance) |
| GitHub Actions | SHA-pinned, including the step receiving `FEED_DEPLOY_KEY` |
| Fetched build helpers and lab images | sha256-verified or commit-pinned before execution — **except `usign`**, see below; `/tmp` trust removed (fresh `mktemp` per invocation) |

Never stage a secret key into `feed-staging/` — `feed_publish_copy_keys` copies
public keys only, and all four key filenames plus `*.tmp` are gitignored.

One row above is aspirational rather than in force, reproduced on
2026-08-12:

- `feed_publish_ensure_usign` clones `openwrt/usign` at an unpinned `master`,
  builds it, and puts it on `PATH` to **sign the feed** — no SHA, no checksum,
  twenty lines from the commit-pinned `ipkg-make-index.sh`
  ([#166](https://github.com/lucas-albers-lz4/fwlive/issues/166)).

Signing-secret mode (previously #165) is restored: normalize/decode use
`mktemp` under `umask 077`, and `chmod 600` runs again after those rewrites.
## Running an audit

Repeatable procedure, verified upstream facts, and the rendering-harness recipe:
`.cursor/skills/security-audit/SKILL.md`. Start there rather than re-deriving
the trust boundaries.
