# Working with CodeRabbit

This repo runs CodeRabbit as an automated PR reviewer. The protocol below keeps
review cycles efficient — one coherent review round over a stable diff, no
fragmented re-reviews, no findings landing after the gate was declared green.

**Ordering:** CodeRabbit runs **after** luna/Bugbot and human review, and
**after** the GitHub PR is filed — see [pr-cycle.md](pr-cycle.md). Do not
`@coderabbitai review` on a branch that has not passed that gate.

**Upstream scope:** **fwlive** CodeRabbit comments never go into an
`openwrt/luci` PR; apply code only
([upstream-openwrt.md](upstream-openwrt.md)). If luci itself is configured for
CodeRabbit, that is separate — do not paste this repo’s review threads.

## How the repo is configured

`.coderabbit.yaml` sets `auto_review.drafts: false`. Consequences:

- **Draft PRs are never automatically reviewed.** Marking the PR **Ready for
  review** makes it *eligible* for automatic review — it does not guarantee a
  run when auto-review is paused or the shared review allowance is exhausted.
- `auto_incremental_review` stays on: every eligible push to a reviewed PR
  starts a new incremental round covering the commits since the last review
  (skipped while auto-review is paused or when the plan/rate limit is hit).
- Manual commands can be used as manual triggers, even on drafts and
  regardless of auto-review configuration, but they consume the same plan/rate-limit
  allowance as automatic reviews and are subject to availability:
  - `@coderabbitai review` — incremental review on demand
  - `@coderabbitai full review` — full re-review from scratch
  - `@coderabbitai pause` / `@coderabbitai resume` — stop / restart auto-reviews
    (auto-pause kicks in after many reviewed commits)

## The 4 rules

1. **Keep the PR in draft until the work is final.** Push everything, run the
   done gate, then mark Ready. A single review over a stable diff is better
   than three incremental rounds over a moving one — cross-file consistency
   findings only surface on a complete PR.

2. **After any trigger (marking ready, pushing a fix, `@coderabbitai review`),
   wait for the round to complete before touching the branch.** CodeRabbit
   takes ~5–10 min to write a round. The completion signal: record the trigger
   head SHA and the last CodeRabbit review ID, then poll `pulls/<n>/reviews`
   until a NEW `COMMENTED` submission from `coderabbitai[bot]` appears with
   `submitted_at` after your trigger and `commit_id` matching the trigger head
   — all inline comments of that round land atomically with it, and the
   walkthrough comment's `updated_at` catches up moments later. Do not accept
   a human review or an older/stale submission as the completion signal.
   **Rate limit is a terminal state, not a wait state:** if the bot posts a
   rate-limit comment and the `Review rate limited` check passes, the trigger
   head was NOT reviewed — mark it unreviewed and retry `@coderabbitai review`
   when quota is available instead of polling for a `COMMENTED` submission.

3. **Batch all fixes into ONE push, then wait again.** Each eligible push can
   spawn a new incremental round (skipped while auto-review is paused or the
   plan/rate limit is hit). Pushing mid-round fragments the review and can
   trip auto-pause. Fix → push → wait for the next round → repeat until a
   round returns no actionable comments. If auto-review is paused, use
   `@coderabbitai review` (or `@coderabbitai full review` after many rounds)
   to trigger the round manually.

4. **Declare the gate green only after the last round has fully landed.**
   Check that every finding from the latest round carries a resolution marker
   (`✅ Addressed in commit <sha>` / `✅ Confirmed as addressed` /
   `✅ Review thread resolved` / withdrawal) and that no newer review
   submission exists for your head. Marking the gate green while a round is
   still writing is how findings end up landing *after* "all addressed".

## Working from agent tooling (Hermes / Cursor)

When an agent drives the fix loop:

- Trigger the review, then **poll** — do not time-box with a guess. Check
  `pulls/<n>/reviews` for a new submission before starting any fix.
- Do not auto-push per-finding as the bot posts comments. Collect the full
  round, fix in one batch, push once.
- After the push, re-fetch `pulls/<n>/reviews` + `pulls/<n>/comments` and diff
  the finding set against the previous round — the bot can open a NEW round
  with refined findings, not just `Addressed` markers on old ones.
- Rate limits are plan-specific rolling allowances (e.g. Free 1/hr, Pro 5/hr,
  Pro+ 10/hr — check the plan's limits). They apply to automatic and manual
  triggers alike; check remaining quota with `@coderabbitai rate limit` and
  prefer batching over `@coderabbitai review` spam.
