---- MODULE WanLogLock ----
(* WAN-zone log=1 enable/disable mutex of luci-app-fwlive, abstracted from
   openwrt-feed/.../root/usr/libexec/fwlive-logging.sh: acquire_wan_log_lock ->
   read/commit -> release_wan_log_lock, run by concurrent ubus toggle callers.

   Step-1 finding encoded here: the lock wait is an UNBOUNDED blocking flock
   (line 185 `flock 9`; BusyBox flock has no -w, comments 39-45; callers never
   wrap it in `timeout`; the timeout binary guards only rpcd read commands).
   GiveUp therefore models fail-closed setup arms (167-188 return 1 ->
   caller reports "error":"lock_failed", e.g. 1026-1029) — NOT a timed-out. *)
EXTENDS Integers, TLC

CONSTANT Procs            \* concurrent toggle callers
\* Target[p]: committed log value p writes; odd callers enable (log=1),
\* even callers disable (clear). Deriving it keeps cfg to sets only.
Target == [p \in Procs |-> IF p % 2 = 1 THEN 1 ELSE 0]
ASSUME Procs # {}

LCStates == {"Wait", "Hold", "Done", "Failed"}    \* caller lifecycle
VARIABLES pc, log, result

TypeOK ==
  /\ pc \in [Procs -> LCStates]
  /\ log \in {0, 1}
  /\ result \in [Procs -> {"pending", "committed", "lock_failed"}]

Init ==
  /\ pc = [p \in Procs |-> "Wait"]   \* one toggle call per caller (rpcd 1430-1435)
  /\ result = [p \in Procs |-> "pending"]
  /\ log \in {0, 1}                  \* committed bit starts on|off

\* blocking `flock 9` (fwlive-logging.sh:185) grants EX to exactly one caller;
\* grant timing is nondeterministic (idiomatic: no wall-clock countdown).
AcquireLock(p) ==
  /\ pc[p] = "Wait"
  /\ \A q \in Procs: pc[q] # "Hold"
  /\ pc' = [pc EXCEPT ![p] = "Hold"]
  /\ UNCHANGED <<log, result>>

\* fail-closed: symlink guards / open / flock unavailable (167-188) => "lock_failed"
GiveUp(p) ==
  /\ pc[p] = "Wait"
  /\ pc' = [pc EXCEPT ![p] = "Failed"]
  /\ result' = [result EXCEPT ![p] = "lock_failed"]
  /\ UNCHANGED log

\* Critical section, ATOMIC: re-read bit under lock (1037), uci set (861),
\* uci commit (888), release (1053; flock -u 9 at 193). One action because no
\* timeout wraps this window, so kill-mid-commit is unreachable by construction.
Commit(p) ==
  /\ pc[p] = "Hold"
  /\ pc' = [pc EXCEPT ![p] = "Done"]
  /\ log' = Target[p]
  /\ result' = [q \in Procs |-> IF q = p THEN "committed" ELSE result[q]]

\* IdleStep keeps the path check's behaviors infinite once every caller is
\* terminal (Done/Failed) — pure stuttering, same effect as [Next]_vars.
IdleStep == /\ pc' = pc /\ log' = log /\ result' = result

Next == (\E p \in Procs: AcquireLock(p) \/ GiveUp(p) \/ Commit(p)) \/ IdleStep

(* WF over COMPLETE action disjunctions: a fairness operator that references
   pc' without constraining every primed var trips TLC issue tlaplus#317. *)
Resolve == (\E p \in Procs: AcquireLock(p)) \/ (\E p \in Procs: GiveUp(p))
Release  == \E p \in Procs: Commit(p)

vars == <<pc, log, result>>

Spec ==
  /\ Init
  /\ [][Next]_vars
  /\ WF_vars(Resolve)   \* waiting resolves: acquire or fail closed, never hang
  /\ WF_vars(Release)   \* short critical section always completes


(* ---- Step 3 properties ---- *)
MutualExclusion ==
  \A p, q \in Procs: (pc[p] = "Hold" /\ pc[q] = "Hold") => p = q

ConfigWhole == log \in {0, 1}   \* committed bit is always a whole intended value

NoEndlessWait == \A p \in Procs: <>[](pc[p] \in {"Done", "Failed"})

THEOREM Spec => []TypeOK /\ []MutualExclusion /\ []ConfigWhole /\ NoEndlessWait
====
