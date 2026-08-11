# AGENTS.md

Router for coding agents. Every rule below is stated once, in the document
linked beside it — **read the link before acting on the rule**, and edit that
document rather than this file when a rule evolves.

Which document owns which rule, and the narrow cases where restating one is
allowed: [contributing.md § Single source of truth](docs/developer/contributing.md#single-source-of-truth).

Humans should start at [`README.md`](README.md) and the
[developer guide](docs/developer/README.md).

## What this is

`luci-app-fwlive` — a LuCI JavaScript app rendering a live table of firewall LOG
events on OpenWrt. Client-side JS plus a small root rpcd plugin and shell
helpers. No Lua, no daemon, no build step for the shipped JS.

The shipped surface is everything under `openwrt-feed/luci-app-fwlive/`; the rest
is docs, tests, and lab tooling. Layout:
[developer guide § Repository map](docs/developer/README.md#repository-map).

## Hard invariants

Breaking any of these fails CI or ships a security regression.

| Rule | Canonical source |
|------|------------------|
| Untrusted values reach the DOM as text nodes, never an HTML sink | [security-model.md § Invariants](docs/developer/security-model.md#invariants) |
| Log content, hostnames, URL-hash values, and UCI values are all untrusted | [security-model.md § Untrusted input inventory](docs/developer/security-model.md#untrusted-input-inventory) |
| `CLASSIFY_SPEC` edits go in `core/` **and** the LuCI mirror, then `gen-all.sh` | [contributing.md § Parser sync / codegen](docs/developer/contributing.md#parser-sync--codegen) |
| Never hand-edit generated files (shell classifier, `css.js`) | [contributing.md § Parser sync / codegen](docs/developer/contributing.md#parser-sync--codegen), [build-and-test.md](docs/developer/build-and-test.md) |
| Sessions never get `ubus log.read`; read and write ACL scopes stay separate | [security-model.md § Invariants](docs/developer/security-model.md#invariants) |
| `PKG_VERSION` and `APP_VERSION` must match | [contributing.md § Feed / package changes](docs/developer/contributing.md#feed--package-changes) |

## Before you start

| Task | Read first |
|------|------------|
| Any change | [contributing.md](docs/developer/contributing.md) |
| Renderers, rpcd plugin, shell helpers, release pipeline | [security-model.md](docs/developer/security-model.md) |
| Classification or parsing | [architecture.md](docs/developer/architecture.md) |
| A security audit | `security-audit` skill in `.cursor/skills/` |

## Commands and testing

Commands, what each gate covers, and the QEMU flow:
[build-and-test.md](docs/developer/build-and-test.md).

Two traps worth knowing before you trust a green run:

- Renderer tests **do not render** — see
  [build-and-test.md § Renderer tests do not render](docs/developer/build-and-test.md#renderer-tests-do-not-render).
- `gen-luci-wrapper.js` is a gate, not a generator. It reports drift; it will not
  fix it for you.

## Reporting security issues

Vulnerabilities go to a private advisory, never a public issue
([`SECURITY.md`](SECURITY.md)). Hardening items are normal public issues.

## Conventions

- Small changes, one behavior each
- Tabs for indentation in shell and the shipped JS; match surrounding code
- Comments explain constraints the code cannot show — not what the next line does
- Documentation conventions, including rule ownership:
  [contributing.md § Documentation](docs/developer/contributing.md#documentation)
