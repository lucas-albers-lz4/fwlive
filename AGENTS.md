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
- CodeRabbit automatically reviews only Ready PRs (`auto_review.drafts: false`); manual `@coderabbitai review` can still trigger on drafts, subject to the plan review allowance. Marking Ready makes the PR *eligible* for automatic review. Wait for a round to complete before pushing fixes (a rate-limit comment means the head was NOT reviewed), batch fixes into one push, don't declare the gate green mid-round. [coderabbit.md](docs/developer/coderabbit.md)
- Tabs in shell and shipped JS. Workflow: [contributing.md](docs/developer/contributing.md). Commands: [build-and-test.md](docs/developer/build-and-test.md).
