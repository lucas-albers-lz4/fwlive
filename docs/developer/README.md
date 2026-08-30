# Developer guide

Documentation for **building, testing, and extending** `luci-app-fwlive` and the fwlive repository.

## Start here

| Step | Guide |
|------|-------|
| 1 | [Environment setup](environment.md) — Linux x86_64 host, Docker SDK, QEMU |
| 2 | [Architecture](architecture.md) — modules, data path, design choices |
| 3 | [Build & test](build-and-test.md) — SDK matrix, validation, smoke scripts |
| 4 | [Contributing](contributing.md) — parser sync, acceptance criteria, workflow |
| 5 | [Security model](security-model.md) — trust boundaries, invariants, audit procedure |

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

### Plan

| Topic | Document |
|-------|----------|
| UI design target & OPNsense parity | [`../fwlive-ui-design-target.md`](../fwlive-ui-design-target.md) |
| Roadmap & development plan | [`../ROADMAP.md`](../ROADMAP.md) |
| Acceptance criteria | [`../fwlive-acceptance.md`](../fwlive-acceptance.md) |
| Agent orientation (invariants, commands) | [`../../AGENTS.md`](../../AGENTS.md) |

### Build

| Topic | Document |
|-------|----------|
| Event schema | [`../openwrt-fwlive-schema.md`](../openwrt-fwlive-schema.md) |
| SDK version matrix | [`../sdk-build-matrix.md`](../sdk-build-matrix.md) |
| Feed layout (no submodule split) | [architecture.md § Feed layout decision](architecture.md#feed-layout-decision) |

### Validate

| Topic | Document |
|-------|----------|
| Validation matrix | [`../validation-matrix.md`](../validation-matrix.md) |
| QEMU lab (x86 + armsr) | [qemu-lab.md](qemu-lab.md) |
<<<<<<< HEAD
| Roadmap | [`../ROADMAP.md`](../ROADMAP.md) |
| Publish checklist | [`../github-publish-checklist.md`](../github-publish-checklist.md) |
| Agent PR cycle (luna → Bugbot → human → file → CodeRabbit) | [pr-cycle.md](pr-cycle.md) |
| Upstream to `openwrt/luci` | [upstream-openwrt.md](upstream-openwrt.md) |
| CodeRabbit protocol | [coderabbit.md](coderabbit.md) |
| Feed layout (no submodule split) | [architecture.md § Feed layout decision](architecture.md#feed-layout-decision) |
=======

### Secure

| Topic | Document |
|-------|----------|
>>>>>>> 8397bc8 (docs(hygiene): wave ignore, remove stub, group indexes, add security-review header)
| Trust boundaries & security invariants | [security-model.md](security-model.md) |
| Z3 verification (host/CI; #120/#121) | [z3-verification.md](z3-verification.md) |
| Security review state (coverage, proofs, open findings) | [security-review.md](security-review.md) |

### Publish

| Topic | Document |
|-------|----------|
| Publish checklist | [`../github-publish-checklist.md`](../github-publish-checklist.md) |

## User documentation

Installing on a router without building from source: **[User guide](../user/README.md)**.
