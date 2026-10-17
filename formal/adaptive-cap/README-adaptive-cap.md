# Adaptive poll line cap — TLA+ fidelity map

Models for `fwlive_adaptive_compute_limit` in
`openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-adaptive-cap.sh`.

The clock-free policy is the production shape after #1241: the limit
sequence is a function of the observed samples, not of poll spacing.
`AdaptiveCapClocked.tla` is the counterfactual that still measures the
cool-band probe window against `_elapsed`.

## Production behavior

`fwlive_adaptive_plan` applies the previous poll's duration; a successful
`fwlive_adaptive_record` stores the new limit and writes `completed_cs=1`.
`completed_cs > 0` is the prior-decision marker (`prior`
in the model). A fresh state (`completed_cs = 0`) still applies the 250-line
cool cap. Hot/warm samples hold the previous limit while they stay hot and
probe one doubling on the first healthy sample. Cool samples retain a raised
limit once a prior decision exists.

## `AdaptiveCap.tla`

The module has no time variable. Cadence independence is structural.

| TLA+ action / symbol | Shell behavior abstracted |
|---|---|
| `Init` | Fresh state: default limit `POLL_LINES_MAX` (2000), `completed_cs = 0`. |
| `prior` | `completed_cs > 0` after the first successful `fwlive_adaptive_record`. |
| `Bucket = "cool"` | Modelled workload: a 2000-line sample is cool; a smaller cap is a full-sized cold sample (`fwlive_adaptive_bucket_for_ms`). |
| `NextLimit` cool retain | Cool band: `_prev_l > FWLIVE_ADAPTIVE_COOL_CAP` and `_prev_c > 0` keep `_prev_l`. |
| `NextLimit` cool cap | Fresh cool (`_prev_c = 0`) applies `FWLIVE_ADAPTIVE_COOL_CAP` (250). |
| `NextLimit` `Double` | Cold full-sized record: `fwlive_adaptive_double` from the retained limit. |
| `Next` | One record-mode `fwlive_adaptive_compute_limit` step, then `completed_cs` becomes non-zero. |
| `stableFor` | Consecutive polls at the same limit; `Converges` is `<>[] (stableFor = 3)`. |

`AdaptiveCap.cfg` checks `TypeOK`, `Bounds`, and `Converges` under
`WF_vars(Next)`. `AdaptiveCapUnfair.cfg` uses `SpecNoFairness` and must
violate `Converges`: without that fairness conjunct the spec may stutter
forever at `Init`.

## `AdaptiveCapClocked.tla`

Same workload and state, but the cool retain also requires
`Cadence < 300` (`FWLIVE_ADAPTIVE_COOLDOWN_PROBE_CS` in the pre-#1241
helper). At a fixed cadence, `_elapsed` is the cadence.

- `AdaptiveCapClockedShort.cfg` (`Cadence = 100`) must pass `Converges`.
- `AdaptiveCapClockedLong.cfg` (`Cadence = 500`) must violate `Converges`
  with the cycle `2000 → 250 → 500 → 1000 → 2000 → 250 …` — the 5 s row
  of #1241.

## Known divergences

1. **Plan/record collapsed.** One `Next` is record-mode
   `fwlive_adaptive_compute_limit`. Planning uses the previous duration on
   the next poll; the model does not split those two calls.
2. **Clamp-to-request dropped.** `fwlive_adaptive_clamp` against the caller's
   requested line count is not modelled; every step uses the full modelled
   request.
3. **`POLL_LINES_MAX` overrides not modelled.** `Max` is the default 2000.
4. **Flock not modelled.** `fwlive_adaptive_with_lock`, fail-open/fail-closed
   lock paths, and the state-file write are out of scope.

## Environment assumption

`WF_vars(Next)` — "polls keep arriving". It is weak fairness of the whole
`Next` action, not per-bucket fairness. It does not prove a wall-clock bound
or that rpcd is scheduled. `AdaptiveCapUnfair.cfg` removes the conjunct so
the assumption is load-bearing.

The modelled workload class is the #1241 75 µs/line cool-at-max case.
Hot/warm hold-and-probe, `warm_halved`, and client request sizes other than
`Max` are outside this state space; `tests/fwlive-adaptive-cap.test.sh` and
`tests/fwlive-adaptive-trajectory.test.sh` cover those at the helper.

TLC 1.7.4: the fair clock-free arm has 8 distinct states, a complete graph,
depth 8. The trajectory test supplies separate shell evidence: T1 checks that
the tested scenarios produce equal limit sequences at 100 cs and 500 cs, and
T2 checks that each steady scenario reaches and retains some plateau within
eight polls. Neither assertion compares a shell trace with a TLA+ trace or
requires a particular plateau value.

Refs #1241.
