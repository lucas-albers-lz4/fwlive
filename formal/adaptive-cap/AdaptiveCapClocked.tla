---- MODULE AdaptiveCapClocked ----
(* Counterfactual: the shipped cooldown windows measured against
   `_elapsed` (fwlive_adaptive_compute_limit before the sample-sequence
   rewrite). At a fixed poll cadence, elapsed IS the cadence, so the
   cool-band probe window is `Cadence < 300`. Cadence=100 must converge;
   Cadence=500 reproduces the 2000→250→500→1000→2000 flap. *)
EXTENDS Integers, TLC

CONSTANT Cadence

VARIABLES limit, prior, stableFor
vars == <<limit, prior, stableFor>>

Limits == {250, 500, 1000, 2000}
Max == 2000
CoolCap == 250
ProbeWindow == 300

ASSUME Cadence \in Nat

Bucket == IF limit = Max THEN "cool" ELSE "cold"

Double(l) == IF 2 * l > Max THEN Max ELSE 2 * l

TypeOK ==
  /\ limit \in Limits
  /\ prior \in BOOLEAN
  /\ stableFor \in 0..3

Bounds == limit \in Limits

Init ==
  /\ limit = Max
  /\ prior = FALSE
  /\ stableFor = 0

NextLimit ==
  IF Bucket = "cool"
  THEN IF prior /\ limit > CoolCap /\ Cadence < ProbeWindow
       THEN limit
       ELSE CoolCap
  ELSE Double(limit)

Next ==
  /\ limit' = NextLimit
  /\ prior' = TRUE
  /\ IF limit' = limit
     THEN stableFor' = IF stableFor < 3 THEN stableFor + 1 ELSE 3
     ELSE stableFor' = 0

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

Converges == <>[](stableFor = 3)
====
