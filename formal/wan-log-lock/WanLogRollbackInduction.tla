---- MODULE WanLogRollbackInduction ----
(***************************************************************************
 * Safety induction over the SAME Outcomes action bodies, with no later-
 * attempt cap. Limit=0 denotes idealized Nat history; positive Limit models
 * refusal before the next generation increment would exceed that limit.
 *************************************************************************** *)
EXTENDS WanLogRollbackOutcomes
CONSTANT
  \* @type: Int;
  Limit
CONSTANT
  \* @type: Int;
  InitialGeneration
ASSUME Limit \in Nat

ConstInitWith(bound, guard) ==
  /\ Limit = bound
  /\ InitialGeneration \in Nat
  /\ IF bound = 0 THEN TRUE ELSE InitialGeneration < bound
  /\ PrimaryIntent \in ToggleIntents
  /\ GuardMode = guard
  /\ RestoreBehavior = "exact"
  /\ AllowRefusals = TRUE

UnboundedConstants == ConstInitWith(0, "revision")
DeployedConstants == ConstInitWith(2147483646, "revision")
BrokenConstants == ConstInitWith(0, "valueOnly")

HistoryInit == InitAt(InitialGeneration)

CanAdvanceHistory == Limit = 0 \/ generation < Limit

HistoryNext ==
  \/ (CanAdvanceHistory /\ PrimaryCommitAt(generation + 1))
  \/ ReloadFails
  \/ LaterCommitWhen(CanAdvanceHistory)
  \/ LaterNoOpWhen(CanAdvanceHistory)
  \/ LaterFailedAttemptWhen(CanAdvanceHistory)
  \/ ReacquireSuccess
  \/ ReacquireUnavailable
  \/ SkipNewerIntent
  \/ RestorePendingRefusal
  \/ RestoreGenerationRefusal
  \/ BeginRestoreWhen(CanAdvanceHistory)
  \/ RestoreStageFailure
  \/ RestorePostStageRefusal
  \/ RestoreCommitFailure
  \/ RestoreCommitSuccess
  \/ UNCHANGED vars

HistoryTypeOK ==
  /\ phase \in Phases
  /\ previous \in UciValues
  /\ current \in UciValues
  /\ generation \in Nat
  /\ rollbackToken \in Nat
  /\ laterAttempts \in Nat
  /\ lastIntent \in {"none"} \cup ToggleIntents
  /\ outcome \in Outcomes
  /\ restoreGenerationAdvanced \in BOOLEAN
  /\ restoreBaseGeneration \in Nat

IndInv ==
  /\ HistoryTypeOK
  /\ (phase = "Fresh" =>
       /\ generation = InitialGeneration /\ rollbackToken = InitialGeneration /\ laterAttempts = 0
       /\ current = previous /\ ~restoreGenerationAdvanced)
  /\ (phase # "Fresh" => rollbackToken = InitialGeneration + 1)
  /\ generation = rollbackToken + laterAttempts +
       (IF restoreGenerationAdvanced THEN 1 ELSE 0)
  /\ (restoreGenerationAdvanced => laterAttempts = 0)
  /\ (restoreGenerationAdvanced => generation = restoreBaseGeneration + 1)
  /\ (restoreGenerationAdvanced <=>
       (phase = "Restoring" \/
        outcome \in {"restored", "restore-stage-failure",
                     "restore-post-stage-refusal", "restore-commit-failure"}))
  /\ (phase = "Done" <=> outcome # "none")
  /\ (Limit = 0 \/ generation <= Limit)

Safety == NoRestoreAfterNewerIntent

(* Separate deployed-limit obligation, starting in any invariant state at cap.
   Refusals/stuttering and completion after a prior restore bump remain legal. *)
AtLimit == IndInv /\ generation = Limit
StillAtLimit == generation = Limit

====
