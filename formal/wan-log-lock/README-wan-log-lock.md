# WAN-log lock and rollback — TLA+ fidelity map

Models for the WAN logging controls in
`openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh`.

## Production behavior

`acquire_wan_log_lock` uses BusyBox `flock -n 9` and retries with the existing
`sleep` applet across five one-second intervals. On continued contention it
closes fd 9 and the RPC returns `lock_failed` (plus command/scheduling
overhead). It does not block on a single `flock` call.
The critical section remains the short read/stage/commit path; firewall reload
stays outside the lock.

The rpcd read helpers are invoked directly and have no GNU `timeout` package
dependency. The rules and poll paths retain their existing size/count limits;
the resolver elapsed budget only stops additional lookups. A helper already in
progress is not interrupted by fwlive. Stock rpcd applies its configured
execution timeout (30 seconds) to the plugin process, without descendant
cleanup; a helper can outlive the request. That
accepted maintenance tradeoff is outside this lock model; revisit it if users
report reliability problems. WAN lock acquisition itself has no added package
or production dependency.

## `WanLogLock.tla`

| TLA+ action | Shell behavior abstracted |
|---|---|
| `FailSetup(p)` | Lock path, open, or `flock` setup fails; caller reports `lock_failed`. |
| `RequestLock(p)` | File setup succeeds and the first `flock -n 9` attempt begins. |
| `WaitTick(p)` | Nonblocking attempt finds contention, then one `sleep 1` interval elapses. `remaining` models the finite retry budget. |
| `Timeout(p)` | Contention remains after the retry budget; caller closes fd 9 and reports `lock_failed`. |
| `AcquireLock(p)` | `flock -n 9` succeeds while no caller owns the lock. |
| `Commit(p)` | Stage, write `Target[p]`, and release while holding fd 9. This step also abstracts revision bumping before the UCI write. It models mutex-serialized mutation, not a re-read of `log`; read-modify-write lost-update properties are out of scope (#1265). |

TLC 2.19 checks the model with three callers and a five-interval budget.
`TypeOK`, `MutualExclusion`, `LockOwnership`, `ConfigWhole`, and
`NoEndlessWait` hold. Liveness uses weak fairness for retry/acquire/fail and
commit actions. The model includes a permanently stuck external fd-9 holder;
waiters still exhaust their retry budget and return `lock_failed`. It assumes
the caller loop keeps getting scheduled, so it does not prove a wall-clock
upper bound under a stalled CPU or process scheduler.

## Rollback ABA finding and fix (#953 F1)

`WanLogRollbackAba.tla` is the counterexample model for the original value-only
guard. A enables logging, B disables it while A reloads, C enables it again,
and A's failed reload then sees `log=1` and incorrectly restores `log=0`.
`WanLogRollbackAba.cfg` intentionally violates `NoOverwriteForeignIntent`.

Production now advances a root-only volatile generation file under the same
lock for each toggle that reaches its locked state check, including requests
that find the requested state already set. After reload fails, A re-acquires
the lock and may attempt restoration only if both the visible value and
generation still match A's commit; the restore helper can still refuse or fail.
`WanLogRollbackRevision.tla` models that guard and a single primary enable.
Its config checks that a later enable survives the ABA. It also checks that the
rollback decision reaches either restore or skip after lock reacquisition
(`RollbackCompletes`), and that the positive-guard case reaches the original
value under the model's idealized successful restore
(`RestoreLandsWithoutForeignCommit`). Decision completion is not successful
restoration: this smaller model represents restore as one atomic, successful
action. The failure-aware follow-up below models refusal/failure outcomes and
the restore's own generation bump; neither model claims shell conformance.

`WF_vars(NoStutter)` is weak fairness of the whole finite action disjunction,
not separate fairness for each named action or caller. Here it is a scheduling
assumption for the single modeled caller; it does not establish command success,
progress under recurring unmodeled environment actions, or a wall-clock
runtime bound. `WanLogRollbackRevisionUnfair.cfg` removes that conjunct and
checks only `RestoreLandsWithoutForeignCommit`; it does not check
`RollbackCompletes`. If generation tracking cannot be updated for the primary
toggle, production fails before staging. A failed UCI write may leave a
revision gap, which can suppress a rollback but cannot overwrite a later
fwlive intent. The `/var/run` state is volatile, so reboot clears it only after
all in-flight callers have ended.

This history marker covers fwlive writers that use this lock and helper. A
separate privileged writer that edits UCI directly does not advance it; the
existing current-value check still detects a different final value, but a
direct writer's own off/on ABA is outside the model and coordination contract.

## Failure-aware rollback outcomes (#1126)

`WanLogRollbackOutcomes.tla` keeps decision completion separate from
successful restoration. It runs the primary operation as either enable or
disable, with an initial unset/explicit-off value for enable or an enabled
value for disable. A `present` bit distinguishes unset from explicit-off, and
`rest` preserves one of two representative non-log settings. These are finite
abstract values, not a UCI parser.

While the primary reload is pending, up to two cooperating later attempts may
occur: a commit changes the log bit, a no-op leaves it unchanged, and a failed
write after its generation bump leaves committed UCI unchanged. All three
advance the shared generation; the latter two are still intents that must
prevent an older rollback. Each records its requested direction in `lastIntent`
(`AttemptRecordsIntent`). The revision guard checks both generation and value.
The positive `NoRestoreAfterNewerIntent` checks cover every later-attempt kind.
`valueOnly` counterexample deliberately removes the generation check and
violates that invariant.

After reacquisition, the model can skip for a newer intent, finish with
reacquisition unavailable, refuse before restoration for pending changes or
unavailable generation tracking, or begin restoration. `BeginRestore` advances
generation before staging. Subsequent terminal outcomes distinguish stage
failure, a post-stage foreign-change refusal, commit failure, and successful
restore. The exact-restore configs check that success restores the original
value; the `wrong` mutation deliberately violates that check.

The enable/disable configs with refusals disabled check
`RollbackDecisionCompletes`, exact restoration when eligible, and the safety
invariants. The two failure-enabled configs check decision completion and
invariants while TLC explores all optional refusal/failure branches. A terminal
decision (including a skip or failure) is not proof restoration succeeded.
The value-only and incorrect-restore mutations each have enable and disable
counterexamples, so both primary directions exercise those negative checks.
`restoreBaseGeneration` records the live generation immediately before the
restore bump; `RestoreGenerationAdvancedExactly` checks the bump amount and
requires it on successful restore and failures after staging begins, while
excluding it on refusals before the bump. `RestoreFailureKeepsTarget` checks
that restore refusals/failures keep the primary target value. It excludes skip
and unavailable-reacquisition outcomes: later attempts can already have made
`current = previous` without a restore.

`WF_vars(DecisionProgress)` is weak fairness of the whole local post-reload
decision disjunction. After `ReloadFails` reaches `Waiting`, at most two later
attempts are allowed in total, and fair behaviors eventually take the local
reacquire/skip/restore-outcome steps to reach `Done`. Fairness does not require
leaving `Reloading`; infinite stuttering there is permitted. It is not fairness
per action or per caller, does not force restoration over a
permitted refusal, and does not prove command success or a wall-clock bound.
The two-later-attempt cap and generation ceiling of 4 bound the TLC state
space; they are not production limits. The model is deliberately finite and is
not a shell/model conformance proof: it does not execute UCI, force any
particular failure, model arbitrary UCI values or direct non-cooperating
writers, or establish how provider commands behave. Separately,
`tests/fwlive-logging.test.sh` checks no-op and failed-write generation advances,
plus restore-stage refusal/failure and restore commit failure after their own
bump; its failed-write checks exercise primary writes, not later cooperating
failed writes during another caller's reload.
`tests/fwlive-logging-lock.test.sh` checks successful restore, newer-value skip,
and ABA preservation, plus a rollback reacquisition that fails at lock-path
setup and a later cooperating failed write during another caller's reload.
The latter invokes `commit_wan_log_change` under the real flock helper and
observes the failed response, retained committed value, generation bump, and
earlier rollback skip. These are shell implementation fixtures, not
model/code conformance. This extends the decision/effectiveness split in #1123;
any test-only trace/conformance pilot belongs in #1121 and should use this
abstraction. Refs #953, #1121, #1123.

## Why F2 stays a counterexample, not a QEMU experiment

`WanLogLockTimed.tla` asks what would happen if a timeout wrapper could send
SIGKILL while the process owns the lock. Its
`WanLogLockTimedStranding.cfg` deliberately violates `NoOrphanStaging`: a kill
after `uci set` but before `uci commit` leaves a staged firewall delta, and
later toggles refuse at `firewall_changes_pending`. The committed file remains
whole because UCI commits by temporary-file rename.

F2's proposed QEMU kill experiment was deferred because it targets that
whole-critical-section timeout design. Production now times out only while
trying to acquire the lock, before any UCI staging; a QEMU kill at the F2
location would test a different implementation. The model remains an explicit
guard against expanding timeout scope over the critical section. The QEMU
security smoke instead checks the production behavior: a held lock returns
`lock_failed` within the RPC's host-side safety bound.

## Repeatable TLC run

`scripts/formal-tlc.sh` downloads the official TLA+ v1.7.4 tools jar and checks
its pinned SHA-256 before running TLC with one worker. It runs the production
models as passing checks and asserts that ten counterfactual configs still
report their violations: ungated hostname disposal (`NoLateWrite`),
whole-critical-section kill (`NoOrphanStaging`), value-only rollback ABA
(`NoOverwriteForeignIntent`), rollback effectiveness with the fairness
conjunct removed (`RestoreLandsWithoutForeignCommit`, which TLC reports as an
unnamed temporal-property violation), value-only rollback despite later intent
(`NoRestoreAfterNewerIntent`) and incorrect restore values
(`RestoreValueIsPrevious`) for both enable and disable primary directions,
adaptive-cap unfair liveness (`Converges`), and the 500 cs clocked adaptive-cap
arm (`Converges`, the #1241 flap). The ten configurations comprise seven
invariant counterexamples and three temporal-property counterexamples. No
TLA+ tooling is included in the OpenWrt package. The unnamed temporal-failure
check intentionally requires a simple
counterexample configuration: one identifier per SPECIFICATION, INVARIANT or
PROPERTY line and exactly the expected PROPERTY. It rejects additional operands,
continuation lines and richer configuration syntax before invoking TLC, so a
second temporal failure cannot be credited to the intended property.
Run it locally with `./scripts/formal-tlc.sh`, followed by the separate
`./scripts/formal-rollback-trace-replay.sh` observation replay. The always-
reporting **formal TLC** Actions job runs on pushes and pull requests, skips
only all-known-unrelated path diffs, and retains `workflow_dispatch` for manual
runs. GitHub check execution alone does not make the status required; see
[`build-and-test.md`](../../docs/developer/build-and-test.md#formal-models-tlatlc)
for the configured check context and repository-setting state.

The normal host suite's `tests/formal-tlc-tooling.test.sh` also derives module
and configuration paths from each `run_*` call in `scripts/formal-tlc.sh` and
fails if a referenced `.tla` or `.cfg` is missing. Its disposable missing-file
probes need no JRE and do not download TLC. This is configuration integrity
only: it does not parse fidelity-map claims or establish source-level or
semantic conformance. The maps intentionally name shell functions and
expressions rather than line numbers; source-to-model conformance remains a
review obligation, with the shell fixtures and QEMU smoke as separate
implementation evidence.

### Bounded observation conformance (#1121, expanded in #1322)

Run `./scripts/formal-rollback-trace-replay.sh`. The command sources the
unchanged shipped helper and observes file-backed UCI, real flock, reload and
generation-temp allocation seams. Facts include caller PID/role/intent, command
results, committed value/generation, and complete helper return/JSON results.
English logger messages are diagnostic only and cannot choose model actions.

The deterministic matrix has 33 traces: primary enable with unset or explicit
zero baseline, or primary disable with an enabled baseline, each exercising
successful restore; opposite/on-off ABA; a no-op; a later failed commit or stage;
pending-change refusal; unavailable reacquisition; unavailable generation temp;
restore stage failure; post-stage foreign change; and restore commit failure.
Another 24 schedules are generated from seed 1322, each with zero to two later
requests. A requested commit failure may produce an actual no-op if the request
is already satisfied: the observations, rather than the input label, determine
the abstract action. `FWLIVE_ROLLBACK_TRACE_SEED` changes the recorded seed.

`formal-rollback-trace-project.py` projects provider facts to checkpoints and
names of actions already defined by `WanLogRollbackOutcomes`. The replay adapter
dispatches those actions directly; it is not a second transition relation.
Primary intent and unset/explicit-off/on values are observed, not hardcoded.
Every later call requires matching begin, return and JSON facts, including calls
with a commit. The first post-stage validation read is kept separately from
cleanup reads. An observed pending/generation refusal cannot be followed by a
restore write, and a fatal lock error cannot be erased by another attempt.
Final committed value/generation must match the terminal checkpoint. Contradictory
JSON, missing terminals and unclassified termination fail projection.

Subcommands inside one later toggle are folded into that toggle's model action.
A restore's generation advance is checkpointed before its stage operation;
lock reacquisition, reload and terminal failure outcomes are separate boundaries.
The replay permits terminal stuttering only, with no unobserved semantic model
steps between captured checkpoints. Its declared bounds remain eight abstract
steps, two later attempts, and generation 0..4. Over-bound observations are
rejected without truncation. These bounds suffice for the selected matrix;
changing them requires changing the projector and adapter together.

All 57 positive traces must complete through TLC. Three negative controls must
violate `NoInvalidObservation`: a value-only ABA guard, a disposable helper with
its no-op generation bump removed, and a restore-commit-failure checkpoint
falsely claiming that restoration landed. Mutation-site drift fails the check.
The host suite separately runs original and expanded capture/projection tests,
including rewritten log messages and malformed final/secondary/lock histories;
these host checks do not themselves run TLC.

The runner prints and retains HEAD plus Git blob IDs of the actual working
source/model/adapter/fixture/projector/generator/mutator/runner files. The seed
and SHA-256 of generated input cases are retained with the raw facts, configs,
projection output and TLC logs when `FWLIVE_ROLLBACK_TRACE_DIAGNOSTICS_DIR` is
set. HEAD alone does not identify dirty inputs; source hashes identify only the
named inputs, not every installed provider binary or environmental condition.

The generation-limit test is separate from this finite replay:
`tests/fwlive-generation-limit.test.sh` holds the real lock and checks
2147483645 -> 2147483646 followed by exact-byte-preserving refusal, plus a
weakened-guard mutation. It runs under dash and BusyBox ash and reports host
arithmetic width. A 64-bit host run does not emulate a 32-bit OpenWrt shell.

This is conformance evidence for fixture executions only. Providers are stubs;
UCI values are unset, 0 and 1; later calls happen during one primary reload.
It does not prove arbitrary UCI parsing/bit masks, non-cooperating writers,
crash recovery, deadlines, or universal shell/model equivalence. The existing
host shell tests and installed smoke checks retain their separate evidence
boundaries; the fidelity map and source review remain maintenance obligations.
