# Agent PR cycle (Cursor)

Owner for how agents open and merge non-trivial PRs in this repo.
Cursor always-on rule: [`.cursor/rules/pr-bugbot-before-merge.mdc`](../../.cursor/rules/pr-bugbot-before-merge.mdc)
(imperative summary; this file is the procedure). CodeRabbit mechanics:
[coderabbit.md](coderabbit.md). Upstream luci filing:
[upstream-openwrt.md](upstream-openwrt.md).

## Goal

One coherent review pass over a stable diff. Do not burn CodeRabbit quota on
a half-ready branch. Do not merge on CI-green alone.

## Non-trivial vs trivial

**Trivial** (CI green + light self-review is enough) — **single-file** only:

- Docs-only typos, badge/link/metadata, single-line comment, pure formatting
  with no logic change
- Housekeeping (license badge, topics, changelog date bumps)

**Non-trivial** (full sequence below) — multi-file **overrides** trivial:

- Any new/changed logic, scripts, tests, CI workflows, schemas, OpenWrt
  feed/package files, or configuration
- Multi-file changes (including multi-file documentation)
- New owner docs / process docs

If unsure, treat as non-trivial.

## Required sequence (non-trivial)

```text
implement on feature branch
  → luna (preferred) or grok on branch changes
  → Bugbot on branch changes
  → fix CONFIRMED findings (re-run once if the diff changed substantively)
  → STOP for human review of the branch
  → only then: gh pr create vs master (draft until work is final)
  → CodeRabbit (Ready, or @coderabbitai review on a draft)
  → triage bot/human comments; fold fixes; wait for the round
  → merge
```

1. **Implement on a feature branch.** Do not open a GitHub PR yet.
2. **Luna** (preferred) or **grok** on **branch changes** (merge-base vs the
   default base).
3. **Bugbot** on the same diff (`review-bugbot` skill / `bugbot` subagent).
4. Fix `CONFIRMED` findings (or document `DISMISS` with evidence). One more
   luna/Bugbot pass if the diff changed substantively.
5. **Stop for human review.** Do not file the PR until the human says so.
6. **File** the PR against `master` (`gh pr create`). Keep the PR as a draft
   until the work is final ([coderabbit.md](coderabbit.md)). Then mark Ready,
   or run `@coderabbitai review` on that draft.
7. **Then** CodeRabbit. Wait for the round to complete; batch fixes into one
   push; do not declare the gate green mid-round.
8. Triage the PR thread before merge (below).
9. Wait until required checks are present and passing.
10. Merge with the repo’s usual strategy (`gh pr merge`, typically squash).

Plan-mode execution does **not** substitute for luna, Bugbot, or the human
pass.

## Triage labels

Pull comments with `gh api` (`pulls/<n>/comments`, `pulls/<n>/reviews`, issue
comments) and classify each:

| Label | Meaning |
|-------|---------|
| `CONFIRMED` | Real issue — fix it (or explicitly accept with rationale) |
| `DISMISS` | False positive — reply on the thread with evidence |
| `FOLD` | Already addressed / duplicate |

Rules:

- Do **not** auto-apply a CodeRabbit-suggested fix without ground-truthing it
  against the code / real API — a suggested fix can be wrong.
- Human `REQUEST_CHANGES` / substantive inline comments **outrank** bot
  comments.
- Unresolved human `REQUEST_CHANGES` or substantive human review comments
  **block merge**, same as unresolved `CONFIRMED` bot findings.
- A bare bot comment does not block merge by itself; unresolved `CONFIRMED`
  bot findings block merge.

## CodeRabbit vs upstream (openwrt/luci)

CodeRabbit comments live only on the **fwlive** GitHub PR. They never ship in
the luci tree or the FormalityCheck commit.

- Apply `CONFIRMED` fixes in this repo (and re-run `./scripts/upstream-cut.sh`
  if shipped package files changed).
- Refresh the luci fork branch from the cut.
- Before filing against `openwrt/luci`, run **this same sequence** on the luci
  feature branch (luna + Bugbot + human). Skip CodeRabbit there unless that
  repo is configured for it.
- File the luci PR with product/FormalityCheck prose only — no fwlive bot
  quotes, no “per CodeRabbit” trailers.

See [upstream-openwrt.md](upstream-openwrt.md).

## Do not

- File a master-targeted PR before luna + Bugbot + human review
- Ping CodeRabbit during steps 1–5
- Merge when required checks are missing or failing
- Merge non-trivial work on CI-green alone
- Treat plan mode as a substitute for the gates above
- Merge with unresolved human `REQUEST_CHANGES` / substantive human comments,
  unresolved `CONFIRMED` findings, or an un-triaged review thread
