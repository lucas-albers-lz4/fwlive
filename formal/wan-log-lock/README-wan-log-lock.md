# WAN-log lock — TLA+ fidelity map

Model: `WanLogLock.tla` (+ `.cfg`) — the enable/disable mutex of
`openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh`
(file paths below relative to that script unless noted).

## Step-1 finding (cited)

The prompt asserts the implementation enforces a **bounded** lock wait via an
additional package. Reading the code says otherwise — the answer is **neither
(a) nor (b)**:

- Makefile `LUCI_DEPENDS` (openwrt-feed/luci-app-fwlive/Makefile:11) does add
  an additional package: `+coreutils-timeout`.
- But `coreutils-timeout` (`/usr/bin/timeout`) is consumed **only** by rpcd's
  `run_with_timeout` (root/usr/libexec/rpcd/fwlive:182–241), which wraps read-
  path commands only: `nft list ruleset` (:418), `ubus call log read` (:643),
  the filter script (:668), `nslookup` (:764). It never touches the lock.
- The toggle path dispatches **without** any timeout wrapper:
  `rpcd/fwlive:1430–1435` calls `enable_wan_logging` / `disable_wan_logging`
  directly.
- `acquire_wan_log_lock` (:162–189) ends in plain blocking
  `exec 9>>"$WAN_LOG_LOCK_FILE"` + `flock 9` (:184–185) — BusyBox flock, no
  `-w`, no `timeout` prefix. util-linux `flock` is NOT swapped in
  (`flock -n` guest probe in scripts/qemu-security-gaps-smoke.sh:161 assumes
  BusyBox applet semantics).
- Comments confirm: :39 "BusyBox flock constraint: it has NO -w timeout";
  tests/fwlive-logging-lock.test.sh:15 "the production flock helper has no -w
  timeout"; scripts/qemu-security-gaps-smoke.sh:139–141 records "rpcd worker
  still blocked on flock (accepted residual: BusyBox flock has no -w)".

So the architecture doc is right about the **lock**; what is bounded is the
**RPC replies** around it. Kill-mid-commit is unreachable because nothing
kills the worker mid-commit. `WanLogLockTimed.tla` is a hypothetical appendix
showing what a future `timeout N flock` refactor would expose.

## Action → shell mapping

| TLA+ action | Shell statement(s) abstracted |
|---|---|
| `Init` (all `Wait`) | `ubus call fwlive enable_wan_logging` → `rpcd/fwlive:1430–1435` → function reaches `acquire_wan_log_lock` (caller gate :1026 / :1079) |
| `AcquireLock(p)` | `exec 9>>lockfile` + `flock 9` (:184–185); kernel grants `LOCK_EX` to exactly one waiter → guard `\A q: pc[q] # "Hold"` |
| `GiveUp(p)` | fail-closed arms of `acquire_wan_log_lock` returning 1 (:167–188: symlink guards, mkdir/open fail, `flock 9` fail); caller prints `"error":"lock_failed"` and returns (:1026–1029, :1079–1082) |
| `Commit(p)` (one atomic action) | critical section under the lock: re-read `wan_zone_log_value` (:1037) → `uci set firewall.$zone.log=$target` (:861) or `uci delete` (:866) → `uci commit firewall` (:888) → `release_wan_log_lock` (:1053; `flock -u 9` + `exec 9>&-` :193–194) |
| `[Next]_vars` stutter | firewall reload runs OUTSIDE the lock (:960–968) — inter-step gaps of a caller are invisible |

`Target` derived in-module (odd p enables → `log=1` :1050/861; even p clears →
`log=` unset, :1101/866) to keep the cfg a one-line set binding.

## TLC results (TLC 2026.09.25, 3 callers)

- `TypeOK`, `MutualExclusion`, `ConfigWhole`: **hold** (81 states, <1s).
- `NoEndlessWait` under `WF(Resolve)`+`WF(Release)`: **holds** — i.e. every
  toggle call eventually lands Done/Failed. Caveat: this assumes the holder
  completes; the real script's worst case is a *stuck* holder + fd-9-
  inheriting child (:40–43) blocking waiters until reboot — see divergences.

## Timed appendix (hypothetical (b))

`WanLogLockTimed.tla` splits the CS into `WriteConfig1` (`uci set` = staging
:861) / `WriteConfig2` (`uci commit` :888) + `Kill`. Results:
- `CommittedWhole` holds even under Kill: uci's commit is temp-file+rename
  (upstream openwrt/uci file.c:754–822 writes `.{name}.uci-XXXXXX`, fsyncs,
  renames) — the committed file is never torn; only whole values appear.
- `NoOrphanStaging` is **violated** (trace: AcquireLock(1)→WriteConfig1(1)→
  Kill(1)): a kill between set and commit strands the staged delta; the next
  toggle then aborts at `firewall_changes_pending` (:850–854) — availability
  loss until `uci revert`, not corruption. This is the (b) tax, paid only if
  anyone ever wraps the CS in `timeout`.

## Known divergences (safe for this property set)

1. **No wall-clock at all.** `flock 9` blocking/grant duration, reload
   seconds, `timeout` guards on read RPCs — none modeled. Timeout is
   represented (where applicable) by the nondeterministic choice of `GiveUp`
   / `Kill`, the idiomatic encoding.
2. **GiveUp ≠ timeout.** As established, the wait is unbounded; GiveUp
   abstracts the fail-closed setup arms. Liveness therefore rests on WF
   ("holders finish, waiters eventually get an answer") — exactly the
   assumption the accepted-residual smoke test flags as unguaranteed in
   practice (stuck holder / inherited fd 9). The model would not catch a
   permanently stuck holder; nothing short of `-w` can.
3. **Atomic CS.** Read→set→commit→release is one step. Sound because no
   killer targets this window; if (b) ever lands, use WanLogLockTimed.
4. **Commit-success is assumed.** `uci commit` failure/revert (:888–905) and
   post-commit verify race handling (:910–945) are error-reporting paths; the
   committed value is always 0/1 either way → `ConfigWhole` unaffected.
5. **One toggle per caller, no rollback re-acquire.** Reload-failure rollback
   (:968–993) re-acquires the same lock; modeled callers do one CS. Rollback
   composes two `Commit(p)`-shaped steps under the same mutex — ME and
   ConfigWhole proofs carry over unchanged.
6. **fd-9 inheritance leak.** :40–43 notes a live child can keep the lock
   after the holder dies; the model assumes the lock tracks its holder. Only
   affects liveness under a stuck holder, which (2) already disclaims.
7. **Lock acquisition failure modes collapsed.** TOCTOU symlink re-checks,
   0600 tightening, dir safety (:166–178) are all one `GiveUp` — they are
   security hardening, not mutex behavior; ME/ConfigWhole don't depend on
   which arm fired.
