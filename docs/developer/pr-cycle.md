# Agent review and merge gate

This document owns the review policy for issues and pull requests. It applies
across development hosts and agent harnesses; companion summaries must link
here rather than require a particular model or bot. CodeRabbit operation details
are in [coderabbit.md](coderabbit.md). OpenWrt LuCI publication is covered by
[upstream-openwrt.md](upstream-openwrt.md).

## Goal

Every issue receives scope triage, and every PR receives an independent review
of the final diff before merge. Review depth follows risk. A reviewer or bot
being unavailable never counts as a completed review; use the fallback for that
risk tier and record the substitution. Do not merge on CI-green alone.

## Issue review

Before implementation, have the issue owner or a delegate triage each issue
for current state, scope, acceptance criteria, ownership, and risk. Record the
disposition on the issue. The issue author cannot be the sole approver of their
own scope. For an issue proposing elevated-risk work, have an independent
reviewer examine the proposed approach and acceptance criteria before
implementation begins. A review can happen in the issue, a linked plan, or a
design PR, as long as its scope and outcome are recorded.

## Pull request review tiers

Every PR needs an independent review of its final head SHA before merge. The
reviewer must not be the author. Review can be done by a capable human or an
independent code-review agent available on the current host. Luna, Grok, and
Bugbot are preferred options when available; they are not individually
required. A PR review from the platform's required reviewer also counts when it
examines the diff and findings are triaged.

| Tier | When to use it | Required review |
| --- | --- | --- |
| Routine | Narrow, low-risk change with no runtime, security, release, or process effect; examples include typo, link, metadata, or formatting fixes | One lightweight independent review of the final diff |
| Standard | All other changes | One independent technical review of the final diff |
| Elevated | Security boundaries or ACLs; rpcd or shell privilege paths; untrusted-data rendering; state, concurrency, or lifecycle behavior; build, release, deployment, or supply-chain controls; broad cross-cutting behavior | Two reviews by distinct independent reviewers. Request CodeRabbit as one of the two when configured and available; otherwise use a second independent reviewer and record why CodeRabbit was unavailable |

Use the highest applicable tier. File count alone does not determine the tier:
a multi-file documentation correction can be routine, while a one-line ACL or
release change can be elevated. If risk is unclear, use the higher tier.

CodeRabbit is available for a PR only when it can complete a review of that
PR's current head. A disabled integration, failed trigger, rate limit, or
review stuck on an older head makes it unavailable for this gate. A queued or
incomplete round is not a completed review. If the PR is otherwise ready to
merge and CodeRabbit has not completed a current-head review, treat it as
unavailable, finish the fallback review, and record the reason; do not wait
indefinitely or repeatedly trigger the bot. If a completed review arrives,
triage its findings before merge.

Reviews may be performed on the feature branch or a draft PR. A draft can be
filed before reviews finish; it cannot merge until its required reviews and
checks pass. CodeRabbit runs only after a PR exists; see
[coderabbit.md](coderabbit.md) for triggering and tracking a review round.

## Required review record

For each required review, record the reviewer, reviewed head SHA, scope, and
outcome in the PR. Triage findings as follows:

| Label | Meaning |
| --- | --- |
| `CONFIRMED` | Real issue — fix it or record an explicit owner-approved acceptance with rationale |
| `DISMISS` | False positive — record the evidence |
| `FOLD` | Already addressed or duplicate — identify where it was addressed |

Before merge:

- All required reviews must cover the current PR head. A substantive change
  after review requires review of the changed diff; a new head cannot inherit a
  stale approval without reviewer confirmation.
- Resolve or explicitly accept every actionable `CONFIRMED` finding. Unresolved
  human change requests or substantive comments block merge.
- Required CI and repository checks must be present and passing.
- If a required reviewer or service is unavailable, obtain the tier's fallback
  review and record the unavailability and substitute. Do not waive the tier.

Do not apply a bot suggestion without checking it against the code, tests, or
real API behavior. Plan-mode execution and author self-review do not replace an
independent review.

## CodeRabbit and upstream OpenWrt

For elevated-risk PRs, CodeRabbit is one of the two required reviewers when
configured and available. For routine and standard PRs, use it when useful; it
is not a universal merge gate. When unavailable on an elevated PR, use another
independent reviewer and record the substitution. CodeRabbit's quota, trigger,
and round completion procedure is in [coderabbit.md](coderabbit.md).

CodeRabbit comments on the **fwlive** PR never go into an `openwrt/luci` PR.
Apply confirmed code findings in fwlive, re-run `./scripts/upstream-cut.sh` if
shipped package files changed, and refresh the luci branch from the cut. The
upstream PR must meet its host's required review and CI rules. Where CodeRabbit
is not configured upstream, use the elevated-tier fallback reviewers; do not
copy fwlive bot comments into the upstream discussion. See
[upstream-openwrt.md](upstream-openwrt.md).
