# Working gracefully with CodeRabbit

This repo runs CodeRabbit as an automated PR reviewer. The protocol below keeps
review cycles efficient — one coherent review round over a stable diff, no
fragmented re-reviews, no findings landing after the gate was declared green.

## How the repo is configured

`.coderabbit.yaml` sets `auto_review.drafts: false`. Consequences:

- **Draft PRs are never reviewed.** CodeRabbit only starts when the PR is
  marked **Ready for review**.
- `auto_incremental_review` stays on: every push to a reviewed PR starts a new
  incremental round covering the commits since the last review.
- Manual commands always work as an override:
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
   takes ~5–10 min to write a round. The completion signal is a new submission
   in `pulls/<n>/reviews` (`COMMENTED` state, `submitted_at` after your
   trigger) — all inline comments of that round land atomically with it, and
   the walkthrough comment's `updated_at` catches up moments later.

3. **Batch all fixes into ONE push, then wait again.** Each push spawns a new
   incremental round. Pushing mid-round fragments the review and can trip
   auto-pause. Fix → push → wait for the next round → repeat until a round
   returns no actionable comments.

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
- Rate limits (~3 reviews/hr/developer) apply to manual triggers too; prefer
  batching over `@coderabbitai review` spam.
