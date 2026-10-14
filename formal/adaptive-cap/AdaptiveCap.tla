---- MODULE AdaptiveCap ----
(* Clock-free adaptive line-cap policy of fwlive-adaptive-cap.sh,
   fwlive_adaptive_compute_limit in record mode, for the modelled
   workload: 2000 lines is cool, any smaller cap is a full-sized cold
   sample. No time variable — cadence independence is structural.
   completed_cs > 0 is `prior`. Cool retain vs the 250-line fresh cap
   is the `_prev_c > 0` / `_prev_l > COOL_CAP` branch. Cold doubling is
   the full-sized probe. *)
EXTENDS Integers, TLC

VARIABLES limit, prior, stableFor
vars == <<limit, prior, stableFor>>

Limits == {250, 500, 1000, 2000}
Max == 2000
CoolCap == 250

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
  THEN IF prior /\ limit > CoolCap THEN limit ELSE CoolCap
  ELSE Double(limit)

Next ==
  /\ limit' = NextLimit
  /\ prior' = TRUE
  /\ IF limit' = limit
     THEN stableFor' = IF stableFor < 3 THEN stableFor + 1 ELSE 3
     ELSE stableFor' = 0

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)
SpecNoFairness == Init /\ [][Next]_vars

Converges == <>[](stableFor = 3)
====
