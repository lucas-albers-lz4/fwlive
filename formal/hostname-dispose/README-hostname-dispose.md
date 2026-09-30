# Hostname-lookup vs disposeView — TLA+ fidelity map

Model: `HostnameDispose.tla` (+ `.cfg`, `HostnameDisposeUngated.cfg`).
Source: `openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive.js`
Code references use function and expression names so the mapping survives line shifts.

## Direct answer

**No — a post-disposal hostname lookup cannot mutate view state.** The gate is
`if (gen !== this.resolveGeneration) return;` in `resolveHostnamesForEntries()`,
re-checked after `await callFwliveResolve(...)` and before every cache write
(`hostname.lruSet`, `hostnameFailed.delete`, `hostname.failMark`).
`disposeView()` bumps the same counter and clears `resolveInFlight`.
Between that guard and the final cache write, the continuation contains **no `await`** —
JS run-to-completion makes gate+writes one uninterruptible region, so there is
no interleaving where the gate passes and the write still lands post-disposal.
This is a cancellation *token checked before the write*, not a merely-ignored
promise.

## Action → code mapping

| TLA+ action | Code abstracted |
|---|---|
| `IssueLookup` | `resolveHostnamesForEntries()`: need-list built, `gen` captured from `resolveGeneration`, then `await callFwliveResolve(...)` |
| `ResolveLookup` | ubus reply settling `callFwliveResolve(...)` — nondeterministic vs `Dispose` (this race is the model) |
| `ApplyResolution` | continuation passes the generation guard → `hostname.lruSet(...)` / `hostname.failMark(...)` — one atomic action (no await between) |
| `IgnoreResolution` | generation guard true branch: `return` — reply lands post-dispose, no mutation (`lateWrite` stays false) |
| `Dispose` | `disposeView()`: `viewDisposed = true`; increment `resolveGeneration` (the gate mechanism — poll coordinator and render scheduler disposals are out of scope) |
| `LateApplyResolution` | **counterfactual only** (`Gate=FALSE`): an unguarded post-await continuation |

Cache abstraction: `cache[a]` ∈ none/name/failed = "has this address's verdict
been written" — exactly the `hostname.js` LRU Map (`lruSet`) +
failure Map (`failMark`) collapsed to per-address flags.

## TLC results (TLA+ release v1.7.4 / TLC 2.19, 3 lookups)

- Gated (production shape): `TypeOK`, `NoLateWrite` hold; `Liveness`
  (`<>[]` all settled) holds — 189 distinct states, under 1 s. The race window (Resolve then
  Dispose then gate) IS reachable — it resolves to `IgnoreResolution`.
- Ungated counterfactual (`Gate=FALSE`): `NoLateWrite` **violated** (34
  distinct states), trace
  `Init → IssueLookup(1) → ResolveLookup(1) → Dispose → LateApplyResolution(1)`
  with `disposed = TRUE`, `lateWrite = TRUE`. The safety check is non-vacuous.

The modeled liveness result assumes a pending ubus lookup eventually replies:
`Spec` gives weak fairness to `Arrive` and `Settle`. It does not show that a
runtime helper finishes within a wall-clock bound. rpcd invokes helpers
directly without GNU `timeout`; the resolver elapsed budget stops starting
additional lookups but cannot interrupt one already running, which can hold
its rpcd worker indefinitely. This is an accepted maintenance tradeoff.

## Why the late write (if it existed) would ALSO be harmless — apply-site reading

Even ungated, the cache-write loop in `resolveHostnamesForEntries()` only
mutates the two Map caches on the view instance. Painting is separately disposed:
`scheduleResolvePaint()` → `scheduleRenderRows()` → render scheduler whose
`schedule()` returns when `disposed` and whose rAF callback re-checks
`disposed` and epoch in `render-scheduler.js`; `render()` itself bails on
`viewDisposed`. The Maps are per-view-instance (view-prototype fields, fresh object
per LuCI view) — no global side effect, no row re-addition. The race is
containment-grade by the render gate; correctness-grade by the generation guard.

## Known divergences (safe for this property set)

1. **One batch.** `resolveInFlight` in `resolveHostnamesForEntries()` serializes batches in JS;
   2–3 lookups model one batch's addresses. Successive batches just reuse the
   same per-lookup lifecycle.
2. **`disposed` ⊇ generation inequality.** The gate compares captured `gen` to
   the live counter; `disposeView()` bumps it, and `onShowHostnamesChange()`
   bumps it too. Modeling `disposed=TRUE` as the single bumping event is
   sound for dispose-race questions; other bumps are the same invalidation
   mechanism.
3. **LRU/TTL arithmetic not modeled** (scope): `CACHE_MAX` eviction
   in `hostname.lruSet()`, `FAIL_TTL_MS` expiry in `hostname.failIsHot()` are sequential cache
   correctness — unit tests (tests/fwlive-hostname*.test.js already cover).
4. **`truncated` reply nuance** in `resolveHostnamesForEntries()` only chooses which per-address
   verdict lands; the write/no-write question is identical.
5. **BFCache pagehide persist path** (`load()` installs a handler that returns
   before disposal when `ev.persisted`) — out of scope: disposal is the event under
   study, not its trigger set.
