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

The package's existing `+coreutils-timeout` dependency is unchanged. It bounds
read-path commands in rpcd and is not used by WAN lock acquisition. The new
retry loop needs no package or production dependency.

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
the lock and restores only if both the visible value and generation still
match A's commit. `WanLogRollbackRevision.tla` models that guard; its config
checks that a later enable survives the ABA. If revision tracking cannot be
safely updated, the primary toggle fails before staging. A failed UCI write
may leave a revision gap, which can suppress a rollback but cannot overwrite a
later fwlive intent. The `/var/run` state is volatile, so reboot clears it only
after all in-flight callers have ended.

This history marker covers fwlive writers that use this lock and helper. A
separate privileged writer that edits UCI directly does not advance it; the
existing current-value check still detects a different final value, but a
direct writer's own off/on ABA is outside the model and coordination contract.

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
models as passing checks and asserts that three counterfactual configs still
report their named violations: ungated hostname disposal (`NoLateWrite`),
whole-critical-section kill (`NoOrphanStaging`), and value-only rollback ABA
(`NoOverwriteForeignIntent`). No TLA+ tooling is included in the OpenWrt
package. Run it locally with `./scripts/formal-tlc.sh`, or use the manual-only
**formal TLC** Actions workflow. The workflow does not run on ordinary pushes
or pull requests.

These checks validate the stated models and their counterexamples. They do not
prove the models match future code; the shell tests and QEMU smoke cover the
implementation boundary separately.
