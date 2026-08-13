# Changelog

All notable changes to **fwlive** / **luci-app-fwlive** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Changed
- Simple view: hint line and Time tooltip mention row click to expand the full message (#118)
- Watch strip G Hybrid: left-aligned clusters, merged WAN logging control, segmented Detail/Message toggles
- Flow column arrow uses bold weight for clearer src → dst scanning
- Protocol filter is a grouped select (Common / Also seen / Exclude) with an always-on custom field (typing wins)

## [v0.1.32] — 2026-08-11

### Security
- Route all `E()` string children through text nodes (uniform array form); bump `PKG_VERSION` to 0.1.32 (#148, #158)
- LuCI-accurate `E()` harness with DOM-render discrimination so renderer regressions fail CI (#149, #155)
- Remove `/tmp` trust from feed signing paths (#142, #157)
- SHA-pin GitHub Actions and route workflow-dispatch inputs via env (#143, #146, #156)

### Fixed
- Capture log prefix/comment with escaped quotes (#124, #125)
- Bound `ubus fwlive.resolve` to a wall-clock budget (#147, #161)
- Serialize WAN logging toggles with `flock` (#151, #163)
- Verify sha256 of downloaded lab images + u-boot; record resolved SDK image digests in the release manifest (#144, #145, #159, #162)
- Resilient feed fetch and link-check retry on curl code 000 (#122, #127, #152, #160)

### Added
- `SECURITY.md` disclosure policy (#123)
- Security model doc: trust boundaries, untrusted-input inventory, and testable security invariants ([`docs/developer/security-model.md`](docs/developer/security-model.md)) (#139)
- `AGENTS.md` — router for coding agents; each rule links to its canonical document (#139)
- Repeatable `security-audit` skill under `.cursor/skills/` (#139)
- Automated git subtree re-cut script for upstream PRs (#116, #117)

### Documentation
- Architecture doc output-encoding rule corrected; security model is the single source (#137, #139)
- Binary-feed install fold; README Tests/License badges; renderer-test and link-checker notes (#113, #119, #139)

## [v0.1.31] — 2026-07-31

### Added
- First-run empty state, one-time logging consent panel, and WAN logging readiness text on the watch strip (#112)
- Single-source classification: `CLASSIFY_SPEC` in `core/fwlive-log.js`, generated shell classifier; LuCI classify parity via gate + preserve region (#84, #95, #97)
- CI shell↔JS parity under BusyBox ash (`SH=busybox sh`) (#103)
- Markdown link checker (internal + external) in the host test gate (#107, #110)

### Fixed
- First-run empty state showed Enable WAN logging twice (consent panel and empty-state CTA) (#112)
- LuCI wrapper gate deep-equals full `CLASSIFY_SPEC` (not only `actionWords`) (#99)
- Shell non-firewall prefixes use word-boundary globs matching JS (`dnsmasqfoo` class) (#100)
- More filters / Help disclosure arrows under custom themes (#105)

### Changed
- User guide First visit path with empty → after-Enable → daily-use screenshots (#112)
- Log table grows with the browser window (was capped at 800px) (#112)
- **Show Detail** widens the page past LuCI’s 940px column; Simple view keeps the normal width (#112)
- Parser sync gate uses classify goldens + shell codegen freshness / LuCI wrapper gate (drops `PARSER_SYNC_VERSION` counter) (#84)
- `normalizeAction` derives pass/deny-class words from `CLASSIFY_SPEC.actionWords` (#101)
- Behavior-preserving cleanup: parser, rpcd shell, logging.js, view extracts (#90, #91, #92)
- Extract fwlive CSS from escaped `css.js` into `fwlive.css` (#87, #96)
- Stream `@.log[*]` once in `fwlive-log-filter.sh` (#93)
- Shellcheck libexec/rpcd scripts in the host test gate (#94)
- Remove `archive/`; add `npm test` alias (#98)

### Documentation
- Document LuCI gate-not-generator design (banner, `gen-all.sh`, contributing) (#102)
- Fix broken links (`blob/main`→`master`, archive refs, iptables relative path); align Stage 6/7 status (#107, #108, #109)

---

## [v0.1.30] — 2026-07-31

### Changed
- Live View A2 chrome: watch strip (Pause/Resume, logging CTA, Show Detail) + grouped Display options drawer; remove Auto-refresh checkbox (#77)

### Fixed
- Accessible row-tint palette pinned to teal/orange (no Bootstrap `--warn-color-high` yellow) (#75, #76)

---

## [v0.1.29] — 2026-07-28

### Added
- Selectable filter chip styles (Labels / Symbols / Tone) with localStorage persistence (#18, #38)
- Row tint toggle (on/off) with Classic (green/red, default) and Accessible (teal/orange) palettes (#40, #47, #49)
- Theme tint fallback when LuCI theme CSS variables do not paint pass/deny row backgrounds
- Security-only Dependabot config for npm, Docker, and GitHub Actions (#42)
- gitleaks pre-commit hook for local secret scanning (#41)

### Fixed
- Pause → resume no longer drops live events; pause buffer is merged on resume (#43, #44)
- Parser version sync (v3), overlapping poll guard / `pagehide` cleanup, and filter input debounce (#43, #45)

### Changed
- CI workflows set explicit `GITHUB_TOKEN` permissions (#39)

---

## [v0.1.28] — 2026-07-27

### Documentation
- Consolidated planning/spec docs into ROADMAP.md
- Restructured over-long user docs (Quick Start first)
- Added CHANGELOG.md, FAQ.md, and upgrade guide
- Fixed cross-reference accuracy and review findings throughout

---

## [v0.1.27] — 2026-07-24

### Changed
- Refactored `fwlive.js` into modular files: `constants.js`, `css.js`, `tint.js`, `links.js`, `chips.js`, `logging.js`, `table.js`
- All modules now use `baseclass.extend` for proper LuCI lifecycle

### Fixed
- Firefox console errors from baseclass usage
- `qemu-install-fwlive.sh` syncs all module files

---

## [v0.1.26] — 2026-07-23

### Security
- Removed session ACL grant for direct `ubus log.read` — poll now reads logd inside the rpcd plugin only
- Hardened `resolve` reverse DNS: IPv4/IPv6 shape validation before lookup
- JSON escaping for rpcd responses
- MAC address redaction in UI display

### Fixed
- WAN zone logging disable: clear only filter-log bit 0, preserving other zone bits

### Added
- Po/i18n template (`luci-app-fwlive.pot`)
- SPDX headers on shell scripts
- Upstream publish checklist

---

## [v0.1.25] — 2026-07-21

### Changed
- Minor packaging fixes

---

## [v0.1.24] — 2026-07-18

### Added
- WAN zone enable/disable logging toolbar buttons on Live View page
- `ubus fwlive.logging_status`, `enable_wan_logging`, `disable_wan_logging`
- `fwlive-logging.sh` helper script
- ACL grants for write operations

---

## [v0.1.23] — 2026-07-11

### Changed
- Backend and matrix improvements

---

## [v0.1.22] — 2026-07-03

### Changed
- CI and build improvements

---

## [v0.1.21] — 2026-07-03

### Changed
- Backend improvements

---

## [v0.1.19] — 2026-06-27

### Added
- 22.03.7 lab sign-off

### Changed
- Build and smoke infrastructure

---

## [v0.1.18] — 2026-06-27

### Added
- fw4 rule name resolve via `ubus fwlive rules`
- **Show hostnames** checkbox (default off) with `ubus fwlive resolve`
- Server-side firewall-only read via `ubus fwlive poll`

---

## [v0.1.17] — 2026-06-20

### Added
- 21.02.7 (fw3/iptables) lab sign-off
- `fwlive-iptables-ping-log.sh`

### Fixed
- 21.02 LuCI compatibility (lua prefix dispatcher)
- Release asset publish and wrap bug from 21.02 support

---

## [v0.1.16] — 2026-06-20

### Added
- OpenWrt 21.02 fw3/iptables support in the SDK matrix and binary feed
- `docs/openwrt-21.02-compat.md` and related install/requirements notes

---

## [v0.1.15] — 2026-06-20

### Added
- 21.02.7 SDK build and x86 QEMU smoke sign-off

---

## [v0.1.14] — 2026-06-19

### Added
- Parameterized validation matrix (`validate-openwrt.sh`)
- Baseline validation gate (`validate-baseline.sh`)
- Full matrix validation (`validate-openwrt-all.sh`)

---

## [v0.1.13] — 2026-06-14

### Added
- Filter operators: `!` prefix for is-not / not-contains
- Action dropdown includes **not pass**, **not drop**, etc.
- Flood banner, token bucket render cap
- **Simple / Detailed** view toggle with `localStorage` persistence
- URL hash `view=detailed`
- Click-to-filter on action, protocol, interface, address cells
- Filter chip bar (show + clear active filters)
- `matchesFilter()` AND logic for multi-field filtering
- Row expand/collapse for raw message in Simple view
- `qemu-smoke-fwlive.sh` headless checks

---

## [v0.1.12] — 2026-06-14

### Changed
- Package version bump for feed republish

---

## [v0.1.11] — 2026-06-14

### Fixed
- GitHub Actions publish workflow write permissions

---

## [v0.1.10] — 2026-06-14

### Fixed
- Wrong CI sign path for package feed

---

## [v0.1.9] — 2026-06-14

### Added
- **Auto-refresh** checkbox (maps to `paused`)
- **Limit** dropdown (25…2000, default 100)
- `localStorage` persistence for view preferences
- Status line: `shown/limit` while paused/live

---

## [v0.1.8] — 2026-06-14

### Added
- Pause/resume toolbar button
- Buffer status line
- Row message wrap/one-line toggle

---

## [v0.1.7] — 2026-06-14

### Added
- **Rule** column with `rule_hint` from nft log prefix
- Deep link to firewall admin from Rule column
- `ubus fwlive poll` server-side filter

---

## [v0.1.6] — 2026-06-14

### Added
- Stage 2 schema hardening: `interface_in`/`out` split, normalized `action` enum, `flags`/`length` parsing
- Schema test fixtures and assertions

---

## [v0.1.5] — 2026-06-13

### Added
- Firewall-only feed (`isFirewallEvent` heuristic)
- Normalized table columns and client-side filters
- Live polling (~1s), URL hash filter persistence

---

## [v0.1.4] — 2026-06-13

### Added
- Initial working LuCI view (`view.extend`)
- Basic JSON-RPC to `ubus log.read`
- Quick search and field filters

---

## [v0.1.3] — 2026-06-13

### Fixed
- GitHub Actions artifact copy-out (uid mismatch)

---

## [v0.1.2] — 2026-06-13

### Added
- Reproducible build verification
- SDK build matrix

---

## [v0.1.1] — 2026-06-13

### Added
- Signed opkg/apk feed at GitHub Pages
- Initial GitHub Releases publishing
- Basic CI pipeline

---

[v0.1.32]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.31...v0.1.32
[v0.1.31]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.30...v0.1.31
[v0.1.30]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.29...v0.1.30
[v0.1.29]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.28...v0.1.29
[v0.1.28]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.27...v0.1.28
[v0.1.27]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.26...v0.1.27
[v0.1.26]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.25...v0.1.26
[v0.1.25]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.24...v0.1.25
[v0.1.24]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.23...v0.1.24
[v0.1.23]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.22...v0.1.23
[v0.1.22]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.21...v0.1.22
[v0.1.21]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.19...v0.1.21
[v0.1.19]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.18...v0.1.19
[v0.1.18]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.17...v0.1.18
[v0.1.17]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.16...v0.1.17
[v0.1.16]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.15...v0.1.16
[v0.1.15]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.14...v0.1.15
[v0.1.14]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.13...v0.1.14
[v0.1.13]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.12...v0.1.13
[v0.1.12]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.11...v0.1.12
[v0.1.11]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.10...v0.1.11
[v0.1.10]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.9...v0.1.10
[v0.1.9]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.8...v0.1.9
[v0.1.8]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.7...v0.1.8
[v0.1.7]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.6...v0.1.7
[v0.1.6]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.5...v0.1.6
[v0.1.5]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.4...v0.1.5
[v0.1.4]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.3...v0.1.4
[v0.1.3]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.2...v0.1.3
[v0.1.2]: https://github.com/lucas-albers-lz4/fwlive/compare/v0.1.1...v0.1.2
[v0.1.1]: https://github.com/lucas-albers-lz4/fwlive/releases/tag/v0.1.1
