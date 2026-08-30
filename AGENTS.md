# AGENTS.md

Shipped surface: `openwrt-feed/luci-app-fwlive/`. Rules live in the linked owner — edit that file, not this one. Ownership: [contributing.md § Single source of truth](docs/developer/contributing.md#single-source-of-truth).

- Untrusted values (logs, hostnames, URL-hash, UCI) MUST reach the DOM as text nodes, never an HTML sink. [security-model.md](docs/developer/security-model.md)
- `CLASSIFY_SPEC` MUST be edited in `core/` **and** the LuCI mirror, then `./scripts/gen-all.sh`. Do not hand-edit the shell classifier or `css.js`. `gen-luci-wrapper.js` is a gate: it reports drift and will not fix it.
- Sessions MUST NOT get `ubus log.read`. Keep read/write ACL scopes separate.
- `PKG_VERSION` MUST match `APP_VERSION` (bump both in lockstep; see [release.md](docs/release.md)).
- Renderer tests do not render — a green run is not XSS proof. [build-and-test.md](docs/developer/build-and-test.md)
- rpcd / ACL / shell helpers / release pipeline: update [security-review.md](docs/developer/security-review.md) in the same PR; audit via `.cursor/skills/security-audit`.
- Releases: bump `PKG_VERSION`/`APP_VERSION`, fold CHANGELOG, tag `v0.1.N` — CI builds the signed feed + release assets. [release.md](docs/release.md)
- Vulnerabilities go to a private advisory ([SECURITY.md](SECURITY.md)), not a public issue.
- Agent PRs: luna (or grok) + Bugbot on the branch, **human review**, then file vs master, then CodeRabbit — not CI-green alone. [pr-cycle.md](docs/developer/pr-cycle.md)
- CodeRabbit automatically reviews only Ready PRs (`auto_review.drafts: false`); manual `@coderabbitai review` can still trigger on drafts. Review limits are **plan-specific rolling allowances** (Free 1/hr, Pro 5/hr, Pro+ 10/hr — check quota with `@coderabbitai rate limit`), not a fixed ~3/hr cap. Marking Ready makes the PR *eligible* for automatic review. Wait for the round; batch fixes; don't declare green mid-round. [coderabbit.md](docs/developer/coderabbit.md)
- Upstream into `openwrt/luci`: cut with `./scripts/upstream-cut.sh`, FormalityCheck commit, `.pot` only first; CodeRabbit comments stay on fwlive — fold code only. [upstream-openwrt.md](docs/developer/upstream-openwrt.md)
- Tabs in shell and shipped JS. Workflow: [contributing.md](docs/developer/contributing.md). Commands: [build-and-test.md](docs/developer/build-and-test.md).
