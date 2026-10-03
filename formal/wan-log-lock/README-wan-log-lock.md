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
| `Commit(p)` | Re-read, stage, commit, and release while holding fd 9. This step also abstracts revision bumping before the UCI write. |

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
and ABA preservation. Failed rollback reacquisition and later cooperating
failed writes during reload have model evidence only; no dedicated shell
fixtures check those paths. These are shell implementation fixtures, not
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
models as passing checks and asserts that six counterfactual configs still
report their violations: ungated hostname disposal (`NoLateWrite`),
whole-critical-section kill (`NoOrphanStaging`), value-only rollback ABA
(`NoOverwriteForeignIntent`), rollback effectiveness with the fairness
conjunct removed (`RestoreLandsWithoutForeignCommit`, which TLC reports as an
unnamed temporal-property violation), value-only rollback despite later intent
(`NoRestoreAfterNewerIntent`), and an incorrect restore value
(`RestoreValueIsPrevious`). No TLA+ tooling is included in the OpenWrt
package. The unnamed temporal-failure check intentionally requires a simple
counterexample configuration: one identifier per SPECIFICATION, INVARIANT or
PROPERTY line and exactly the expected PROPERTY. It rejects additional operands,
continuation lines and richer configuration syntax before invoking TLC, so a
second temporal failure cannot be credited to the intended property.
Run it locally with `./scripts/formal-tlc.sh`, or use the manual-only
**formal TLC** Actions workflow. The workflow does not run on ordinary pushes
or pull requests.

These checks validate the stated models and their counterexamples. They do not
prove the models match future code; the shell tests and QEMU smoke cover the
implementation boundary separately.
