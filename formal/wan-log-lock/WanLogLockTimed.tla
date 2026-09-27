---- MODULE WanLogLockTimed ----
(* HYPOTHETICAL regression model for Step-1 option (b) — IF the wait were
   bounded by `timeout N flock ...` wrapping the whole critical section.
   Production does NOT do this (see WanLogLock.tla); this appendix models the
   hazard (b) would open: SIGKILL landing mid "compute -> commit".

   uci semantics kept honest: `uci commit firewall` rewrites the whole file
   atomically (temp+rename), so the COMMITTED bit never tears. The reachable
   damage under (b) is a stranded STAGED delta from the killed caller's
   `uci set`; the next toggle then aborts at firewall_changes_pending
   (fwlive-logging.sh:850-854) — availability loss until manual `uci revert`,
   not config corruption. Production never strands its own staging because
   nothing kills it mid-commit. *)
EXTENDS Integers, TLC

CONSTANT Procs
Target == [p \in Procs |-> IF p % 2 = 1 THEN 1 ELSE 0]
ASSUME Procs # {}

States == {"Wait", "Hold", "Staged", "Done", "Failed"}
VARIABLES pc, staged, committed, result

TypeOK ==
  /\ pc \in [Procs -> States]
  /\ committed \in {0, 1}
  /\ staged \in {0, 1}
  /\ result \in [Procs -> {"pending", "committed", "killed", "timed_out"}]

Init ==
  /\ pc = [p \in Procs |-> "Wait"]
  /\ result = [p \in Procs |-> "pending"]
  /\ committed \in {0, 1}
  /\ staged = committed            \* staging == committed at rest

GiveUp(p) ==   \* timeout expired while blocked on flock — clean fail
  /\ pc[p] = "Wait"
  /\ pc' = [pc EXCEPT ![p] = "Failed"]
  /\ result' = [result EXCEPT ![p] = "timed_out"]
  /\ UNCHANGED <<staged, committed>>

AcquireLock(p) ==
  /\ pc[p] = "Wait"
  /\ \A q \in Procs: pc[q] \notin {"Hold", "Staged"}
  /\ pc' = [pc EXCEPT ![p] = "Hold"]
  /\ UNCHANGED <<staged, committed, result>>

WriteConfig1(p) ==  \* `uci set firewall.<wan>.log=target` (861): stages only
  /\ pc[p] = "Hold"
  /\ staged' = Target[p]
  /\ pc' = [pc EXCEPT ![p] = "Staged"]
  /\ UNCHANGED <<committed, result>>

WriteConfig2(p) ==  \* `uci commit firewall` (888): atomic rename, then
  /\ pc[p] = "Staged"   \* release_wan_log_lock (1053; flock -u 9, 193-194)
  /\ committed' = staged
  /\ pc' = [pc EXCEPT ![p] = "Done"]
  /\ result' = [result EXCEPT ![p] = "committed"]
  /\ UNCHANGED staged

Kill(p) ==  \* SIGKILL between set and commit; flock fd closes -> lock freed
  /\ pc[p] \in {"Hold", "Staged"}
  /\ pc' = [pc EXCEPT ![p] = "Failed"]
  /\ result' = [result EXCEPT ![p] = "killed"]
  /\ UNCHANGED <<staged, committed>>

Next == (\/ UNCHANGED <<pc, staged, committed, result>>)
        \/ \E p \in Procs:
  AcquireLock(p) \/ GiveUp(p) \/ WriteConfig1(p) \/ WriteConfig2(p) \/ Kill(p)

vars == <<pc, staged, committed, result>>

(* WF over complete action disjunctions (tlaplus/tlaplus#317). *)
Resolve  == (\E p \in Procs: AcquireLock(p)) \/ (\E p \in Procs: GiveUp(p))
Progress == (\E p \in Procs: WriteConfig1(p)) \/ (\E p \in Procs: WriteConfig2(p))

Spec ==
  /\ Init
  /\ [][Next]_vars
  /\ WF_vars(Resolve)
  /\ WF_vars(Progress)

(* (b)'s torn-state safety: the committed bit is ALWAYS a whole 0/1 (temp-file
   rename commits), never a half-written value. Holds even with Kill. *)
CommittedWhole == committed \in {0, 1}

(* The (b) hazard, expected FALSE: Kill mid-Staged strands the delta. *)
NoOrphanStaging ==
  \A p \in Procs: pc[p] = "Failed" /\ result[p] = "killed" => staged = committed

MutualExclusionTimed ==
  \A p, q \in Procs: (pc[p] \in {"Hold", "Staged"} /\ pc[q] \in {"Hold", "Staged"}) => p = q

\* under (b)+WF, waits still resolve (acquire/GiveUp/kill all enabled)
LivenessTimed == []<>(\A p \in Procs: pc[p] \in {"Done", "Failed"})

THEOREM Spec => []TypeOK /\ []CommittedWhole /\ []MutualExclusionTimed
====
