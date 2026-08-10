# AGENTS.md

Orientation for coding agents working in this repository. Humans should start at
[`README.md`](README.md) and the [developer guide](docs/developer/README.md).

## What this is

`luci-app-fwlive` — a LuCI JavaScript app that renders a live table of firewall
LOG events on OpenWrt. Pure client-side JS plus a small root rpcd plugin and
shell helpers. No Lua, no custom daemon, no build step for the shipped JS.

The shipped surface is small: everything under
`openwrt-feed/luci-app-fwlive/`. The rest of the repo is docs, tests, and lab
tooling.

## Hard invariants

Violating any of these breaks CI or ships a security regression.

**Parser sync.** `core/fwlive-log.js` is the source of truth for
`CLASSIFY_SPEC`. The LuCI copy in
`openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js` must
mirror it exactly. After changing classification, edit **both**, then run
`./scripts/gen-all.sh` and commit the regenerated shell classifier.
`gen-luci-wrapper.js` is a gate, not a generator — it will not fix drift for you.

**Generated files.** `root/usr/libexec/fwlive-is-firewall-event.sh` is generated.
Never hand-edit it. SDK package builds do not run Node, which is why it is
committed.

**Output encoding.** LuCI's `E(tag, attrs, str)` assigns bare string children to
`innerHTML`; only array children become text nodes. Always write
`E(tag, attrs, [ value ])`. Log data, reverse-DNS hostnames, URL-hash filter
values, and UCI values are all untrusted — see
[security model](docs/developer/security-model.md).

**ACL scope.** Never grant `ubus log.read` to sessions. The rpcd plugin performs
privileged log reads as root and returns filtered output. Read methods and
state-changing methods stay in separate ACL scopes.

**Version sync.** `PKG_VERSION` in the package `Makefile` and `APP_VERSION` in
`fwlive/constants.js` must match.

## Commands

```sh
npm test                          # ./scripts/fwlive-test.sh — parser, shell parity, codegen freshness, rpcd security
./scripts/fwlive-linkcheck.sh     # markdown links + heading anchors + external URLs
./scripts/validate-baseline.sh    # pre-release gate
./scripts/gen-all.sh              # regenerate shell classifier, verify LuCI wrapper
```

Tests are host-only and need no router. UI changes still need a QEMU check —
see [qemu-lab.md](docs/developer/qemu-lab.md).

Docs changes must pass the link checker: it validates relative paths **and**
heading anchors against a GitHub-style slugger.

## Testing gotcha

`tests/lib/load-fwlive-module.js` stubs `E()` as a plain object that never
renders. Renderer tests assert on descriptive objects, so **no existing test can
observe a DOM injection bug**. When touching renderers, verify through a
LuCI-accurate `E()` harness — recipe in
`.cursor/skills/security-audit/SKILL.md`.

## Security work

Read [`docs/developer/security-model.md`](docs/developer/security-model.md) for
trust boundaries and invariants. For an audit, use the `security-audit` skill in
`.cursor/skills/` — it carries verified upstream facts, the grep patterns, and
severity/disclosure rules, so it avoids re-deriving known-good ground.

Vulnerabilities go to a **private advisory**, never a public issue
([`SECURITY.md`](SECURITY.md)). Hardening items are normal public issues.

## Conventions

- Small changes, one behavior each; see
  [contributing.md](docs/developer/contributing.md)
- Tabs for indentation in shell and the shipped JS (match surrounding code)
- Comments explain constraints the code cannot show — not what the next line does
- Keep user docs free of QEMU/SDK detail; keep developer docs free of marketing
