# Rollback observation oracle — #1322

Before expanding the matrix, choose a single oracle shape. Criteria: unchanged
shipped helper, observations of actual provider calls/results and committed
state, no dependence on English logger messages, refusal/failure separation,
and a visible mismatch for an incorrect commit or missing generation bump.
Time box for selection: 30 minutes.

Selected: infer transitions from observed UCI/flock/JSON facts plus a structured
mktemp provider observation for generation-allocation failure. Provider records
contain arguments, result codes and state snapshots, never TLA action names.
An explicit helper-terminal event would require wrapping/instrumenting private
helper decisions and risks reporting the fixture's intended result as evidence;
that alternative is rejected. LOG records remain diagnostics only.

Semantic projection checkpoints remain committed value, generation and intent.
A complete trace additionally requires a terminal helper return and matching
JSON failure response. Extra semantic events and over-bound traces are rejected.

## Evidence and review disposition

The expanded capture matrix uses three valid primary/baseline combinations and
11 scenarios, plus 24 seeded schedules. The eight-step/two-later-attempt/0..4
generation domain is explicit; no finite bound was silently raised.

Independent preliminary review identified and corrected: cleanup reads could
replace the first post-stage guard read; committed later calls could omit their
terminal observations; contradictory JSON tuples could be credited; fatal
flock history could be overwritten. Regression controls now reject these
observation corruptions. Final-head review and full replay evidence are recorded
in the implementation PR rather than treating this design record as approval.

The standalone generation-limit fixture sources the actual helper and holds its
real lock. Host dash and BusyBox ash runs are 64-bit and explicitly do not claim
32-bit runtime emulation. The Outcomes model remains unchanged by this work;
formal generation limits and deployment arithmetic are different obligations.
