---- MODULE WanLogLock ----
(* WAN-zone log=1 enable/disable mutex of luci-app-fwlive, abstracted from
   openwrt-feed/.../root/usr/libexec/fwlive-logging.sh: acquire_wan_log_lock ->
   read/commit -> release_wan_log_lock, run by concurrent ubus toggle callers.

   Current acquisition is bounded by `flock -n 9` retries with a five-second
   budget (BusyBox flock has no -w; the implementation uses the existing
   sleep applet). WaitTick abstracts each retry interval; Timeout models the
   caller returning lock_failed if contention remains at the budget. *)
EXTENDS Integers, TLC

CONSTANTS Procs, WaitBudget \* callers and retry intervals
\* A/C enable (log=1), B disables (clear). Deriving this keeps cfg simple.
Target == [p \in Procs |-> IF p \in {"A", "C"} THEN 1 ELSE 0]
ASSUME Procs # {}
ASSUME WaitBudget \in Nat

LCStates == {"Setup", "Wait", "Hold", "Done", "Failed"} \* caller lifecycle
VARIABLES pc, log, remaining, result, owner
vars == <<pc, log, remaining, result, owner>>

TypeOK ==
  /\ pc \in [Procs -> LCStates]
  /\ log \in {0, 1}
  /\ remaining \in [Procs -> 0..WaitBudget]
  /\ result \in [Procs -> {"pending", "committed", "lock_failed"}]
  /\ owner \in Procs \cup {"none", "external"}

Init ==
  /\ pc = [p \in Procs |-> "Setup"]  \* one toggle call per caller (rpcd dispatch)
  /\ remaining = [p \in Procs |-> 0]
  /\ result = [p \in Procs |-> "pending"]
  /\ owner \in {"none", "external"} \* external models a stuck fd-9 holder
  /\ log \in {0, 1}                  \* committed bit starts on|off

\* File/path/open/flock setup can fail before a caller begins polling
\* (fwlive-logging.sh acquire_wan_log_lock); caller returns lock_failed.
FailSetup(p) ==
  /\ pc[p] = "Setup"
  /\ pc' = [pc EXCEPT ![p] = "Failed"]
  /\ result' = [result EXCEPT ![p] = "lock_failed"]
  /\ UNCHANGED <<log, remaining, owner>>

\* Successful setup reaches the first non-blocking `flock -n 9` attempt.
RequestLock(p) ==
  /\ pc[p] = "Setup"
  /\ pc' = [pc EXCEPT ![p] = "Wait"]
  /\ remaining' = [remaining EXCEPT ![p] = WaitBudget]
  /\ UNCHANGED <<log, result, owner>>

\* A failed non-blocking attempt followed by one sleep interval.
WaitTick(p) ==
  /\ pc[p] = "Wait"
  /\ remaining[p] > 0
  /\ owner # "none"
  /\ remaining' = [remaining EXCEPT ![p] = @ - 1]
  /\ UNCHANGED <<pc, log, result, owner>>

\* Contention remains after the finite retry budget; close the fd and fail.
Timeout(p) ==
  /\ pc[p] = "Wait"
  /\ remaining[p] = 0
  /\ owner # "none"
  /\ pc' = [pc EXCEPT ![p] = "Failed"]
  /\ result' = [result EXCEPT ![p] = "lock_failed"]
  /\ UNCHANGED <<log, remaining, owner>>

\* The kernel grants EX to exactly one caller when the lock is free.
AcquireLock(p) ==
  /\ pc[p] = "Wait"
  /\ owner = "none"
  /\ pc' = [pc EXCEPT ![p] = "Hold"]
  /\ owner' = p
  /\ UNCHANGED <<log, remaining, result>>

\* Critical section, ATOMIC: re-read bit under lock, stage/commit the chosen
\* value, then release fd 9. One action because the timeout budget applies
\* only before acquisition; it never wraps this critical section.
Commit(p) ==
  /\ pc[p] = "Hold"
  /\ owner = p
  /\ pc' = [pc EXCEPT ![p] = "Done"]
  /\ owner' = "none"
  /\ log' = Target[p]
  /\ result' = [q \in Procs |-> IF q = p THEN "committed" ELSE result[q]]
  /\ UNCHANGED remaining

\* IdleStep keeps the path check's behaviors infinite once every caller is
\* terminal (Done/Failed) — pure stuttering, same effect as [Next]_vars.
IdleStep ==
  /\ pc' = pc
  /\ log' = log
  /\ remaining' = remaining
  /\ result' = result
  /\ owner' = owner

Next ==
  (\E p \in Procs: FailSetup(p) \/ RequestLock(p) \/ WaitTick(p) \/ Timeout(p) \/ AcquireLock(p) \/ Commit(p))
  \/ IdleStep

(* WF over COMPLETE action disjunctions: a fairness operator that references
   pc' without constraining every primed var trips TLC issue tlaplus#317. *)
Resolve ==
  (\E p \in Procs: FailSetup(p) \/ RequestLock(p) \/ WaitTick(p) \/ Timeout(p))
  \/ (\E p \in Procs: AcquireLock(p))
Release  == \E p \in Procs: Commit(p)

Spec ==
  /\ Init
  /\ [][Next]_vars
  /\ WF_vars(Resolve)   \* retries resolve: acquire or fail closed, never hang
  /\ WF_vars(Release)   \* short critical section always completes


(* ---- Step 3 properties ---- *)
MutualExclusion ==
  \A p, q \in Procs: (pc[p] = "Hold" /\ pc[q] = "Hold") => p = q

ConfigWhole == log \in {0, 1}   \* committed bit is always a whole intended value

LockOwnership ==
  \A p \in Procs: (pc[p] = "Hold") <=> (owner = p)

NoEndlessWait == \A p \in Procs: <>[](pc[p] \in {"Done", "Failed"})

THEOREM Spec => []TypeOK /\ []MutualExclusion /\ []LockOwnership /\ []ConfigWhole /\ NoEndlessWait
====
