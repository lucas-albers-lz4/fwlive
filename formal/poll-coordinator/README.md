# Poll coordinator — Quint / Node conformance pilot

Refs #1322. Host/CI only; the router does not install Quint or Java.

## Contract and evidence boundaries

The specification is `poll-coordinator.qnt`, executed against the unchanged
shipped `fwlive/poll-coordinator.js` by `tests/lib/poll-coordinator-mbt.js`.
One model transition is one API event followed by a complete microtask
checkpoint (`setImmediate`); there is no wall-clock scheduling assumption.

| Model event / operation | Implementation / observed seam |
| --- | --- |
| `request` / `catchUp` | Public methods; compare batch promise equality and settlement |
| `start` / `register` | `startPolling`, poll.add/remove; idle registration invokes the callback synchronously |
| `hide` / `show` | External visibility plus installed listener; compare epoch, notifications and registration |
| `resolve` / `reject` | Settle one outstanding deferred runner, then observe queue progression |
| `cadence` | `setCadence(1 or 5)`; add-before-remove retains the active loop |
| `dispose` | Listener/registration removal, invalidation, caller settlement, no new logical starts |

The driver uses the production module loader and a test-only poll/visibility
adapter based on `createLuciPoll()` in the existing coordinator tests. It checks
public state, registrations, runner start count/epoch, visible notifications,
returned promise identity, and settlement after every transition. Numeric
model batch IDs are abstract names; a bijection to observed promises checks
equality and distinctness, without assuming access to private production IDs.

A hidden-to-visible registration can queue a new batch behind a stale active
request. `catchUp()` joins a current active batch only when there is no pending
batch; otherwise it coalesces into the pending batch. The model represents both
steps of synchronous registration and catch-up in the same event.

Disposal detaches logical ownership and settles callers. It does not cancel an
RPC already running. The view, rather than this module, must reject stale
results: `tests/fwlive-view-layer2-backoff.test.js` separately checks stale-epoch
row discard, no overlap while catch-up is queued, stale completion releasing
the guard without double application, and stale resume/render behavior.

## Declared domain

- Initially visible, cadence 1; cadence choices are 1 and 5 seconds.
- One coordinator, with no unrelated LuCI poll entries. The adapter preserves
  synchronous idle add, identity deduplication and last-remove stop. Periodic
  timer ticks are excluded; explicit request/catch-up calls supply refreshes.
- API calls do not reenter from the injected runner, and runner completion is
  asynchronous. Existing coordinator tests separately exercise synchronous
  throws/reentry/disposal. No full LuCI timer or RPC transport claim is made.
- Seven directed sequences have eight events each. Generated samples use three
  fixed seeds (1322, 953, 306), 100 traces each, and 30 events per trace.
- TLC checks every reachable state through **five** events using `checkStep`.
  This checks a finite prefix, not all histories or eventual completion. The
  backend disables terminal deadlock checks; the finite event boundary is
  intentional. No fairness, runtime deadline, or implementation-refinement
  theorem is claimed.

The invariant checks live/pending batch separation, unsettled ownership,
disposal/registration consistency and the declared cadence domain. Implementation
conformance is additional evidence for the generated traces, not a universal
consequence of the model check.

## Run and reproduce

```sh
npm ci
npm run test:formal-quint
# Keep all traces, logs and source/tool provenance:
FWLIVE_QUINT_DIAGNOSTICS_DIR=/tmp/quint-evidence npm run test:formal-quint
# Optional already-downloaded archive; still checksum-verified:
FWLIVE_APALACHE_ARCHIVE=/path/to/apalache.tgz npm run test:formal-quint
```

Requires Linux host tools, Node >=18, Java 21, curl, tar, sha256sum, and GNU
timeout. `scripts/formal-quint.sh` pins Quint 0.33.0 (npm lock integrity),
Apalache 0.62.1 archive SHA-256, and its contained jar SHA-256. Quint's TLC
backend uses that jar, rather than the older standalone jar for existing TLA+
models. Backend downloads occur before execution, into fresh temporary state.
The npm override pins Quint's `adm-zip` to 0.6.1; it avoids the known vulnerable
transitive version without adding a third-party Connect adapter.

Generation explicitly uses the TypeScript simulator, avoiding an implicit Rust
binary download. Model checking has a 120-second timeout; each generator process
has a 30-second timeout. Retained artifacts contain the ITF traces, seed/domain
manifest, SHA-256s of relevant source/adapter/tool inputs, verification log,
summary and failure details. A failure reports its trace and event index; the
retained case is reproducible and is not claimed automatically minimized.

Mutation controls load disposable in-memory copies of the shipped module:
replace a coalesced queue, omit the visibility epoch bump, or omit active caller
settlement on disposal. Each must fail at its named observed contract. A stale
mutation site or unrelated execution error is not credited as detection.

## Follow-on decision

Defer scheduler, buffer and hostname expansion until the polling pilot has been
reviewed and its maintenance cost measured in CI. Their existing tests remain
the evidence. Hostname already has a separate TLC disposal contract; any future
MBT must identify an additional contract or connect to that existing model.

The always-reporting CI check is `formal Quint / formal-quint`. It reuses the
Phase A conservative path detector; relevant/unclassified/error diffs run the
pilot, positively unrelated diffs skip only its expensive steps. The workflow
also accepts merge-group events without assuming a merge queue is enabled.
Requiring this check in repository protection is a separate configuration step;
its YAML does not establish merge enforcement.
