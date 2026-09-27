# Hostname-lookup vs disposeView — TLA+ fidelity map

Model: `HostnameDispose.tla` (+ `.cfg`, `HostnameDisposeUngated.cfg`).
Source: `openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive.js`
(all line numbers below are that file unless noted).

## Direct answer

**No — a post-disposal hostname lookup cannot mutate view state.** The gate is
fwlive.js:1837, `if (gen !== this.resolveGeneration) return;`, re-checked
after `await callFwliveResolve(...)` (:1836) and before every cache write
(:1859 lruSet, :1860 delete, :1865 failMark). `disposeView()` bumps the very
same counter (:1317) and clears `resolveInFlight` (:1318). Critically, between
:1837 and the last write (:1865) the continuation contains **no `await`** —
JS run-to-completion makes gate+writes one uninterruptible region, so there is
no interleaving where the gate passes and the write still lands post-disposal.
This is a cancellation *token checked before the write*, not a merely-ignored
promise.

## Action → code mapping

| TLA+ action | Code abstracted |
|---|---|
| `IssueLookup` | `resolveHostnamesForEntries` body up to the call: need-list built (:1815–1829), `gen` captured (:1831–1832), `await callFwliveResolve` (:1836) |
| `ResolveLookup` | ubus reply settling the promise at `:1836` — nondeterministic vs `Dispose` (this race is the model) |
| `ApplyResolution` | continuation PASSES the gate: :1837 false branch → `lruSet(cache, ip, name)` :1859 / `failMark(failed, ip)` :1865 — one atomic action (no await between) |
| `IgnoreResolution` | `:1837` true branch: `return` — reply lands post-dispose, no mutation (`lateWrite` stays false) |
| `Dispose` | `disposeView()`: `viewDisposed = true` :1314; `resolveGeneration++` :1317 (the actual gate mechanism — scheduler/coordinator disposals :1315–1316 are out of scope) |
| `LateApplyResolution` | **counterfactual only** (`Gate=FALSE`): an unguarded post-await continuation |

Cache abstraction: `cache[a]` ∈ none/name/failed = "has this address's verdict
been written" — exactly the `hostname.js` LRU Map (`lruSet`, hostname.js:16) +
failure Map (`failMark`, :47) collapsed to per-address flags.

## TLC results (TLC 2026.09.25, 3 lookups)

- Gated (production shape): `TypeOK`, `NoLateWrite` hold; `Liveness`
  (`<>[]` all settled) holds — 189 states, <1s. The race window (Resolve then
  Dispose then gate) IS reachable — it resolves to `IgnoreResolution`.
- Ungated counterfactual (`Gate=FALSE`): `NoLateWrite` **violated**, trace
  `Init → IssueLookup(1) → ResolveLookup(1) → Dispose → LateApplyResolution(1)`
  with `disposed = TRUE`, `lateWrite = TRUE`. The safety check is non-vacuous.

## Why the late write (if it existed) would ALSO be harmless — apply-site reading

Even ungated, :1859–1865 only mutates the two Map caches on the view instance.
Painting is separately disposed: `scheduleResolvePaint` (:1499) →
`scheduleRenderRows` → render scheduler whose `schedule()` returns when
`disposed` (render-scheduler.js:26–27) and whose rAF callback re-checks
disposed+epoch (:47–51), and `render()` itself bails on `viewDisposed`
(:2393). The Maps are per-view-instance (view-prototype fields, fresh object
per LuCI view) — no global side effect, no row re-addition. The race is
containment-grade by the render gate; correctness-grade by the 1837 gate.

## Known divergences (safe for this property set)

1. **One batch.** `resolveInFlight` (:163/1810/1874) serializes batches in JS;
   2–3 lookups model one batch's addresses. Successive batches just reuse the
   same per-lookup lifecycle.
2. **`disposed` ⊇ generation inequality.** The gate compares captured `gen` to
   the live counter; disposal bumps it (:1317), and the toggle handler bumps
   it too (:1639). Modeling `disposed=TRUE` as the single bumping event is
   sound for dispose-race questions; other bumps are the same invalidation
   mechanism.
3. **LRU/TTL arithmetic not modeled** (scope): `CACHE_MAX` eviction
   (hostname.js:16–25), `FAIL_TTL_MS` expiry (:35–45) are sequential cache
   correctness — unit tests (tests/fwlive-hostname*.test.js already cover).
4. **`truncated` reply nuance** (:1853/1862) only chooses which per-address
   verdict lands; the write/no-write question is identical.
5. **BFCache pagehide persist path** (load :2215–2220 returns before
   disposal when `ev.persisted`) — out of scope: disposal is the event under
   study, not its trigger set.
