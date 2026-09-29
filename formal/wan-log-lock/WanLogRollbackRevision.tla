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

Spec == Init /\ [][Next]_vars

NoOverwriteForeignIntent ==
  ~(phase = "Done" /\ lastIntent = "enable" /\ log # 1)

THEOREM Spec => []TypeOK /\ []NoOverwriteForeignIntent
====
