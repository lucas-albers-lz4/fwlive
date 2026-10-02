---- MODULE WanLogRollbackRevision ----
(*
  Fixed abstraction of reload-failure rollback in fwlive-logging.sh.

  Focused single-primary-enable abstraction for reload-failure rollback.
  Each modeled cooperating toggle attempt advances revision; changed operations
  do so before their UCI write. A can decide to restore only when revision and
  the visible value still match A's commit. Restore itself is an idealized
  atomic successful action; shell refusals/failures and its generation bump are
  omitted here and tracked by #1126. B's disable and C's re-enable advance the
  revision even though the visible value returns to A's committed value; an
  already-on enable also advances revision.
*)
EXTENDS Naturals, TLC

Phases == {"Fresh", "Reloading", "Waiting", "Holding", "Done"}
Intents == {"none", "disable", "enable"}

VARIABLES phase, log, revision, lastIntent
vars == <<phase, log, revision, lastIntent>>

TypeOK ==
  /\ phase \in Phases
  /\ log \in {0, 1}
  /\ revision \in 0..3
  /\ lastIntent \in Intents

Init ==
  /\ phase = "Fresh"
  /\ log = 0
  /\ revision = 0
  /\ lastIntent = "none"

PrimaryCommit ==
  /\ phase = "Fresh"
  /\ log' = 1
  /\ revision' = 1
  /\ phase' = "Reloading"
  /\ UNCHANGED lastIntent

ReloadFails ==
  /\ phase = "Reloading"
  /\ phase' = "Waiting"
  /\ UNCHANGED <<log, revision, lastIntent>>

ForeignDisable ==
  /\ phase \in {"Reloading", "Waiting"}
  /\ revision = 1
  /\ log = 1
  /\ log' = 0
  /\ revision' = 2
  /\ lastIntent' = "disable"
  /\ UNCHANGED phase

ForeignEnable ==
  /\ phase \in {"Reloading", "Waiting"}
  /\ revision = 2
  /\ log = 0
  /\ log' = 1
  /\ revision' = 3
  /\ lastIntent' = "enable"
  /\ UNCHANGED phase

ForeignEnableAlreadyOn ==
  /\ phase \in {"Reloading", "Waiting"}
  /\ revision = 1
  /\ log = 1
  /\ revision' = 2
  /\ lastIntent' = "enable"
  /\ UNCHANGED <<phase, log>>

ReacquireRollback ==
  /\ phase = "Waiting"
  /\ phase' = "Holding"
  /\ UNCHANGED <<log, revision, lastIntent>>

(* Idealized successful restore: one atomic model transition. This omits shell
   refusal/failure paths and the restore's own generation bump; #1126 expands
   those outcomes. The effectiveness property below is conditional on this
   abstract successful primitive being available. *)
RestoreByRevision ==
  /\ phase = "Holding"
  /\ revision = 1
  /\ log = 1
  /\ log' = 0
  /\ phase' = "Done"
  /\ UNCHANGED <<revision, lastIntent>>

SkipRestore ==
  /\ phase = "Holding"
  /\ (revision # 1 \/ log # 1)
  /\ phase' = "Done"
  /\ UNCHANGED <<log, revision, lastIntent>>

(* The rollback decision is sequential after reacquiring the lock in this
   finite abstraction. This does not model command success, command stalls, or
   a wall-clock bound. Weak fairness below applies to this whole disjunction,
   not separately to each named action or caller. *)
NoStutter ==
  \/ PrimaryCommit
  \/ ReloadFails
  \/ ForeignDisable
  \/ ForeignEnable
  \/ ForeignEnableAlreadyOn
  \/ ReacquireRollback
  \/ RestoreByRevision
  \/ SkipRestore

Next == NoStutter \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars /\ WF_vars(NoStutter)

(* Identical behavior set without the fairness conjunct. Only the single
   property named in WanLogRollbackRevisionUnfair.cfg is checked against it;
   TLC does not print which temporal property failed in its generic error. *)
SpecNoFairness == Init /\ [][Next]_vars

NoOverwriteForeignIntent ==
  ~(phase = "Done" /\ lastIntent = "enable" /\ log # 1)

(* Decision completion: once this single modeled caller holds the lock again,
   it eventually reaches either restore or skip. This is a finite-state
   scheduling claim under WF_vars(NoStutter), not per-action fairness or proof
   that shell commands succeed or return by a deadline. *)
RollbackCompletes == (phase = "Holding") ~> (phase = "Done")

(* Conditional idealized effectiveness: if the guard's positive case holds,
   this abstraction's atomic successful restore reaches the original value.
   Production can refuse/fail restore; those paths are outside this model. *)
RestoreLandsWithoutForeignCommit ==
  (phase = "Holding" /\ revision = 1 /\ log = 1) ~> (phase = "Done" /\ log = 0)

THEOREM Spec => []TypeOK /\ []NoOverwriteForeignIntent
====
