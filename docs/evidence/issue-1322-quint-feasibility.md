# Quint polling pilot feasibility — #1322

## Comparison criteria (before spike)

Choose one maintained route: pinned official Quint CLI, language-independent
ITF traces, and a local Node driver. A third-party Connect driver is deferred:
this pilot needs a small explicit adapter and does not need another dependency.
Time box: 45 minutes for initial tool/trace/step feasibility; revisit the scope
if an essential criterion cannot be met in that interval.

Go requires: an integrity-locked host-only install; a generated ITF trace with
usable action/nondeterministic metadata; one real shipped coordinator step
replayed and compared; reproducible seeds; and an available supported route to
check the model's invariants. A failed criterion is a reviewed no-go, not MBT
completion. No router runtime dependency is introduced.

## Result

Go proposed, pending independent review. Base:
`8927e9911defa1f3584c661ab905a91cd8650b59`.

- Official npm Quint 0.33.0 installed with lock integrity; Node v26.11.1 used.
- Seed 1322 produced a two-event ITF trace. A Node adapter loaded the shipped
  coordinator and matched request/completion with the trace.
- Apalache 0.62.1 release archive matches the official GitHub asset digest
  `38202a8c4ebeb3ab73e0fe5a7e4bb948442d46ad5de8a7fb45c9e5cac2beb2a6`.
  Its jar is also pinned; Java 21 runs the backend.
- The supported Quint TLC backend passed the five-event polling model check:
  18,811 states generated; 2,243 distinct states; complete graph depth 6
  (initial state plus five events). This is finite-prefix evidence.
- The extended pilot replays seven directed and 300 seeded traces: 9,056
  events. Queue, epoch and disposal mutations fail at their named contracts.
- Existing coordinator and view Layer 2 tests passed separately; these preserve
  synchronous/reentrant runner and view result-fencing evidence.

The local Node driver is selected. A third-party Connect alternative adds no
needed capability for this small contract and is deferred without installation.
The model and adapter are not yet independently final-head reviewed. See the
fidelity map in `formal/poll-coordinator/README.md` for domain and exclusions.
No universal implementation proof or new installed-system evidence is claimed.
