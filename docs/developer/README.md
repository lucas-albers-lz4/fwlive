# Developer guide

Documentation for **building, testing, and extending** `luci-app-fwlive` and the fwlive repository.

## Start here

| Step | Guide |
|------|-------|
| 1 | [Environment setup](environment.md) — Linux x86_64 host, Docker SDK, QEMU |
| 2 | [Architecture](architecture.md) — modules, data path, design choices |
| 3 | [Build & test](build-and-test.md) — SDK matrix, validation, smoke scripts |
| 4 | [Contributing](contributing.md) — parser sync, acceptance criteria, workflow |

## Repository map

| Path | Role |
|------|------|
| [`openwrt-feed/luci-app-fwlive/`](../../openwrt-feed/luci-app-fwlive/) | Shipped OpenWrt package |
| [`core/fwlive-log.js`](../../core/fwlive-log.js) | Parser source of truth (Node tests + CLI) |
| [`openwrt-feed/.../fwlive/log.js`](../../openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js) | LuCI copy — must stay in sync |
| [`tests/`](../../tests/) | Parser, schema, filter tests (no browser) |
| [`scripts/`](../../scripts/) | SDK driver, QEMU lab, install, smoke |
| [`lab/`](../../lab/) | QEMU images and console logs |

## Deep-dive references

| Topic | Document |
|-------|----------|
| UI design target & OPNsense parity | [`../fwlive-ui-design-target.md`](../fwlive-ui-design-target.md) |
| Staged development plan | [`../fwlive-development-plan.md`](../fwlive-development-plan.md) |
| Acceptance criteria | [`../fwlive-acceptance.md`](../fwlive-acceptance.md) |
| Event schema | [`../openwrt-fwlive-schema.md`](../openwrt-fwlive-schema.md) |
| SDK version matrix | [`../sdk-build-matrix.md`](../sdk-build-matrix.md) |
| Validation matrix | [`../validation-matrix.md`](../validation-matrix.md) |
| QEMU lab (x86 + armsr) | [qemu-lab.md](qemu-lab.md) |
| Roadmap | [`../ROADMAP.md`](../ROADMAP.md) |
| Publish checklist | [`../github-publish-checklist.md`](../github-publish-checklist.md) |

## User documentation

Installing on a router without building from source: **[User guide](../user/README.md)**.
