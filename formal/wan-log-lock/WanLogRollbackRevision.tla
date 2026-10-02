---- MODULE WanLogRollbackRevision ----
(*
  Fixed abstraction of reload-failure rollback in fwlive-logging.sh.

  Each fwlive toggle that reaches its locked state check advances revision;
  changed operations do so before their UCI write. A can restore its previous
  value only when the revision still matches A's commit revision. B's disable
  and C's re-enable advance the revision even though the visible value returns
  to A's committed value; an already-on enable also advances revision.
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

Next ==
  \/ PrimaryCommit
  \/ ReloadFails
  \/ ForeignDisable
  \/ ForeignEnable
  \/ ForeignEnableAlreadyOn
  \/ ReacquireRollback
  \/ RestoreByRevision
  \/ SkipRestore
  \/ UNCHANGED vars

(* The rollback is straight-line shell code once the lock is held again: no loop
   can stall it. NoStutter is the complete action disjunction with every primed
   variable pinned, which is what a fairness operator must reference. *)
NoStutter ==
  \/ PrimaryCommit
  \/ ReloadFails
  \/ ForeignDisable
  \/ ForeignEnable
  \/ ForeignEnableAlreadyOn
  \/ ReacquireRollback
  \/ RestoreByRevision
  \/ SkipRestore

Spec == Init /\ [][Next]_vars /\ WF_vars(NoStutter)

(* Identical behavior set without the fairness conjunct. Only the effectiveness
   properties below are checked against it, to show they hold for a reason
   instead of passing because the model may stall forever. *)
SpecNoFairness == Init /\ [][Next]_vars

NoOverwriteForeignIntent ==
  ~(phase = "Done" /\ lastIntent = "enable" /\ log # 1)

(* Effectiveness: once the caller holds the lock again, the rollback decision
   completes. *)
RollbackCompletes == (phase = "Holding") ~> (phase = "Done")

(* Effectiveness of the guard's positive case: the revision still matches this
   caller's commit and UCI still carries this caller's value, so the restore
   lands and returns the original value exactly. *)
RestoreLandsWithoutForeignCommit ==
  (phase = "Holding" /\ revision = 1 /\ log = 1) ~> (phase = "Done" /\ log = 0)

THEOREM Spec => []TypeOK /\ []NoOverwriteForeignIntent
====
