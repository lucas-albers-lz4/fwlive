---- MODULE HostnameDispose ----
(* Race: outstanding fwlive.resolve lookup vs disposeView() (fwlive.js). Per
   address: Idle->Flight->Resolved->Applied/Ignored; cache = per-address
   verdict (LRU/TTL arithmetic out of scope = unit-test territory). REAL GATE:
   post-await gen re-check at 1837 (`gen !== this.resolveGeneration`;
   disposeView bumps 1317). 1837->last write 1865 contains NO await, so
   gate+writes are atomic in JS = ONE action guarded ~disposed. Gate := FALSE
   = counterfactual proving NoLateWrite is not vacuous. *)
EXTENDS Integers, TLC

CONSTANT Lookups      \* addresses of one in-flight batch (odd=hit, even=NXDOMAIN)
CONSTANT Gate         \* TRUE = production (1837); FALSE = counterfactual

VARIABLES pc, cache, disposed, lateWrite

Init ==
  /\ pc = [a \in Lookups |-> "Idle"]
  /\ cache = [a \in Lookups |-> "none"]
  /\ disposed = FALSE /\ lateWrite = FALSE

IssueLookup(a) ==   \* batch sent while view alive (poll cb disposed-gated, 1684)
  /\ pc[a] = "Idle"  /\ disposed = FALSE
  /\ pc' = [pc EXCEPT ![a] = "Flight"]
  /\ UNCHANGED <<cache, disposed, lateWrite>>

ResolveLookup(a) ==   \* ubus reply lands — timing vs Dispose nondeterministic
  /\ pc[a] = "Flight"
  /\ pc' = [pc EXCEPT ![a] = "Resolved"]
  /\ UNCHANGED <<cache, disposed, lateWrite>>

ApplyResolution(a) ==   \* gate passes (1837); lruSet/failMark (1859/1865) atomic
  /\ pc[a] = "Resolved"  /\ disposed = FALSE
  /\ pc' = [pc EXCEPT ![a] = "Applied"]
  /\ cache' = [cache EXCEPT ![a] = IF a % 2 = 1 THEN "name" ELSE "failed"]
  /\ UNCHANGED <<disposed, lateWrite>>

IgnoreResolution(a) ==   \* post-dispose reply: gate returns, NO write (production)
  /\ pc[a] = "Resolved"  /\ disposed = TRUE  /\ Gate
  /\ pc' = [pc EXCEPT ![a] = "Ignored"]
  /\ UNCHANGED <<cache, disposed, lateWrite>>

LateApplyResolution(a) ==   \* counterfactual (Gate=FALSE): write lands post-dispose
  /\ pc[a] = "Resolved"  /\ disposed = TRUE  /\ Gate = FALSE
  /\ pc' = [pc EXCEPT ![a] = "Applied"]
  /\ cache' = [cache EXCEPT ![a] = IF a % 2 = 1 THEN "name" ELSE "failed"]
  /\ lateWrite' = TRUE  /\ UNCHANGED disposed

Dispose ==   \* disposeView(): viewDisposed=true (1314), resolveGeneration++ (1317)
  /\ disposed = FALSE
  /\ disposed' = TRUE
  /\ UNCHANGED <<pc, cache, lateWrite>>

Next == \/ UNCHANGED <<pc, cache, disposed, lateWrite>>
        \/ \E a \in Lookups:
             IssueLookup(a) \/ ResolveLookup(a) \/ ApplyResolution(a)
               \/ IgnoreResolution(a) \/ LateApplyResolution(a) \/ Dispose

Arrive  == \E a \in Lookups: ResolveLookup(a)
Settle  == (\E a \in Lookups: ApplyResolution(a)) \/ (\E a \in Lookups: IgnoreResolution(a))

Spec ==
  /\ Init
  /\ [][Next]_<<pc, cache, disposed, lateWrite>>
  /\ WF_<<pc, cache, disposed, lateWrite>>(Arrive)
  /\ WF_<<pc, cache, disposed, lateWrite>>(Settle)

NoLateWrite == lateWrite = FALSE   \* THE property: no cache mutation after Dispose

\* liveness: every batch member settles; never-issued stay Idle (1684).
Liveness == []<>(\A a \in Lookups: pc[a] \in {"Idle", "Applied", "Ignored"})

TypeOK == /\ pc \in [Lookups -> {"Idle","Flight","Resolved","Applied","Ignored"}]
           /\ cache \in [Lookups -> {"none","name","failed"}] /\ disposed \in BOOLEAN
====
