---- MODULE WanLogRollbackAba ----
(* Focused model of reload-failure rollback in fwlive-logging.sh.

   A commits log=1, releases the flock, and reloads. While A is reloading,
   B can disable (log=0) and C can re-enable (log=1). A's value-only compare
   then sees its own committed value and restores its previous value (0),
   overwriting C's later enable. The lock serializes A's final comparison and
   restore, but it cannot reveal the intervening off->on history.

   This model abstracts successful foreign UCI commits and a failed A reload.
   It checks that a later foreign enable remains effective after A's rollback.
*)
EXTENDS Naturals, TLC

Phases == {"Fresh", "Reloading", "Waiting", "Holding", "Done"}
Intents == {"none", "disable", "enable"}

VARIABLES phase, log, foreignWrites, lastIntent
vars == <<phase, log, foreignWrites, lastIntent>>

TypeOK ==
  /\ phase \in Phases
  /\ log \in {0, 1}
  /\ foreignWrites \in 0..2
  /\ lastIntent \in Intents

Init ==
  /\ phase = "Fresh"
  /\ log = 0
  /\ foreignWrites = 0
  /\ lastIntent = "none"

PrimaryCommit ==
  /\ phase = "Fresh"
  /\ log' = 1
  /\ phase' = "Reloading"
  /\ UNCHANGED <<foreignWrites, lastIntent>>

ReloadFails ==
  /\ phase = "Reloading"
  /\ phase' = "Waiting"
  /\ UNCHANGED <<log, foreignWrites, lastIntent>>

ForeignDisable ==
  /\ phase \in {"Reloading", "Waiting"}
  /\ foreignWrites = 0
  /\ log = 1
  /\ lastIntent \in {"none", "enable"}
  /\ log' = 0
  /\ foreignWrites' = foreignWrites + 1
  /\ lastIntent' = "disable"
  /\ UNCHANGED phase

ForeignEnable ==
  /\ phase \in {"Reloading", "Waiting"}
  /\ foreignWrites = 1
  /\ log = 0
  /\ lastIntent = "disable"
  /\ log' = 1
  /\ foreignWrites' = foreignWrites + 1
  /\ lastIntent' = "enable"
  /\ UNCHANGED phase

ReacquireRollback ==
  /\ phase = "Waiting"
  /\ phase' = "Holding"
  /\ UNCHANGED <<log, foreignWrites, lastIntent>>

RestoreByValue ==
  /\ phase = "Holding"
  /\ log = 1  \* value-only guard: current still equals A's committed value
  /\ log' = 0 \* restore A's previous value
  /\ phase' = "Done"
  /\ UNCHANGED <<foreignWrites, lastIntent>>

SkipRestore ==
  /\ phase = "Holding"
  /\ log # 1
  /\ phase' = "Done"
  /\ UNCHANGED <<log, foreignWrites, lastIntent>>

Next ==
  \/ PrimaryCommit
  \/ ReloadFails
  \/ ForeignDisable
  \/ ForeignEnable
  \/ ReacquireRollback
  \/ RestoreByValue
  \/ SkipRestore
  \/ UNCHANGED vars

Spec == Init /\ [][Next]_vars

(* A completed later foreign enable must not be undone by A's rollback. *)
NoOverwriteForeignIntent ==
  ~(phase = "Done" /\ lastIntent = "enable" /\ log # 1)

THEOREM Spec => []TypeOK /\ []NoOverwriteForeignIntent
====
