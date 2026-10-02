---- MODULE WanLogRollbackOutcomes ----
(***************************************************************************)
(* Failure-aware finite abstraction of one WAN log reload-failure rollback. *)
(***************************************************************************)
EXTENDS Naturals, TLC

CONSTANTS PrimaryIntent, GuardMode, RestoreBehavior, AllowRefusals

ToggleIntents == {"enable", "disable"}
GuardModes == {"revision", "valueOnly"}
RestoreBehaviors == {"exact", "wrong"}
ASSUME
  /\ PrimaryIntent \in ToggleIntents
  /\ GuardMode \in GuardModes
  /\ RestoreBehavior \in RestoreBehaviors
  /\ AllowRefusals \in BOOLEAN

(* `rest` abstracts the other logging bits as opaque data. `present=FALSE`
   distinguishes an unset option from an explicit option with logBit=FALSE.
   These are finite representative UCI values, not an exhaustive parser for
   arbitrary strings. *)
OtherBits == {"zero", "opaque"}
Unset == [present |-> FALSE, rest |-> "zero", logBit |-> FALSE]
UciValues == {Unset} \cup
  { [present |-> TRUE, rest |-> r, logBit |-> bit]
      : r \in OtherBits, bit \in BOOLEAN }

Enabled(value) == value.present /\ value.logBit

SetIntent(value, intent) ==
  IF intent = "enable" THEN
    [ present |-> TRUE,
      rest |-> IF value.present THEN value.rest ELSE "zero",
      logBit |-> TRUE ]
  ELSE IF ~value.present THEN Unset
  ELSE IF value.rest = "zero" THEN Unset
  ELSE [present |-> TRUE, rest |-> value.rest, logBit |-> FALSE]

PreviousEnableValues == {Unset} \cup
  { [present |-> TRUE, rest |-> r, logBit |-> FALSE] : r \in OtherBits }
PreviousDisableValues ==
  { [present |-> TRUE, rest |-> r, logBit |-> TRUE] : r \in OtherBits }
PreviousValues ==
  IF PrimaryIntent = "enable"
  THEN PreviousEnableValues
  ELSE PreviousDisableValues

WrongRestoreValue(value) ==
  IF value.present THEN Unset
  ELSE [present |-> TRUE, rest |-> "zero", logBit |-> FALSE]

Phases == {"Fresh", "Reloading", "Waiting", "Holding", "Restoring", "Done"}
Outcomes ==
  {"none", "restored", "skip-newer-intent", "reacquire-unavailable",
   "restore-pending-refusal", "restore-generation-refusal",
   "restore-stage-failure", "restore-post-stage-refusal",
   "restore-commit-failure"}

(* Bound the state space: primary bump + two later attempts + restore bump. *)
MaxLaterAttempts == 2
MaxGeneration == 4

VARIABLES phase, previous, current, generation, rollbackToken,
          laterAttempts, lastIntent, outcome, restoreGenerationAdvanced,
          restoreBaseGeneration
vars == <<phase, previous, current, generation, rollbackToken,
          laterAttempts, lastIntent, outcome, restoreGenerationAdvanced,
          restoreBaseGeneration>>

TargetValue == SetIntent(previous, PrimaryIntent)
GuardMatches ==
  /\ current = TargetValue
  /\ (GuardMode = "valueOnly" \/ generation = rollbackToken)

TypeOK ==
  /\ phase \in Phases
  /\ previous \in UciValues
  /\ current \in UciValues
  /\ generation \in 0..MaxGeneration
  /\ rollbackToken \in 0..1
  /\ laterAttempts \in 0..MaxLaterAttempts
  /\ lastIntent \in {"none"} \cup ToggleIntents
  /\ outcome \in Outcomes
  /\ restoreGenerationAdvanced \in BOOLEAN
  /\ restoreBaseGeneration \in 0..MaxGeneration

Init ==
  /\ phase = "Fresh"
  /\ previous \in PreviousValues
  /\ current = previous
  /\ generation = 0
  /\ rollbackToken = 0
  /\ laterAttempts = 0
  /\ lastIntent = "none"
  /\ outcome = "none"
  /\ restoreGenerationAdvanced = FALSE
  /\ restoreBaseGeneration = 0

PrimaryCommit ==
  /\ phase = "Fresh"
  /\ current' = TargetValue
  /\ generation' = 1
  /\ rollbackToken' = 1
  /\ phase' = "Reloading"
  /\ UNCHANGED <<previous, laterAttempts, lastIntent, outcome,
                  restoreGenerationAdvanced, restoreBaseGeneration>>

ReloadFails ==
  /\ phase = "Reloading"
  /\ phase' = "Waiting"
  /\ UNCHANGED <<previous, current, generation, rollbackToken,
                  laterAttempts, lastIntent, outcome,
                  restoreGenerationAdvanced, restoreBaseGeneration>>

LaterCommit ==
  \E intent \in ToggleIntents:
    /\ phase \in {"Reloading", "Waiting"}
    /\ laterAttempts < MaxLaterAttempts
    /\ generation < MaxGeneration
    /\ (IF intent = "enable" THEN ~Enabled(current) ELSE Enabled(current))
    /\ current' = SetIntent(current, intent)
    /\ generation' = generation + 1
    /\ laterAttempts' = laterAttempts + 1
    /\ lastIntent' = intent
    /\ UNCHANGED <<phase, previous, rollbackToken, outcome,
                    restoreGenerationAdvanced, restoreBaseGeneration>>

(* Same-state requests are intent: they advance the shared generation even
   though committed UCI remains unchanged. *)
LaterNoOp ==
  \E intent \in ToggleIntents:
    /\ phase \in {"Reloading", "Waiting"}
    /\ laterAttempts < MaxLaterAttempts
    /\ generation < MaxGeneration
    /\ (IF intent = "enable" THEN Enabled(current) ELSE ~Enabled(current))
    /\ generation' = generation + 1
    /\ laterAttempts' = laterAttempts + 1
    /\ lastIntent' = intent
    /\ UNCHANGED <<phase, previous, current, rollbackToken, outcome,
                    restoreGenerationAdvanced, restoreBaseGeneration>>

(* A writer can fail after recording its intent generation but before UCI
   commits. The failed attempt still invalidates an older rollback token. *)
LaterFailedAttempt ==
  \E intent \in ToggleIntents:
    /\ phase \in {"Reloading", "Waiting"}
    /\ laterAttempts < MaxLaterAttempts
    /\ generation < MaxGeneration
    /\ generation' = generation + 1
    /\ laterAttempts' = laterAttempts + 1
    /\ lastIntent' = intent
    /\ UNCHANGED <<phase, previous, current, rollbackToken, outcome,
                    restoreGenerationAdvanced, restoreBaseGeneration>>

ReacquireSuccess ==
  /\ phase = "Waiting"
  /\ phase' = "Holding"
  /\ UNCHANGED <<previous, current, generation, rollbackToken,
                  laterAttempts, lastIntent, outcome,
                  restoreGenerationAdvanced, restoreBaseGeneration>>

ReacquireUnavailable ==
  /\ AllowRefusals
  /\ phase = "Waiting"
  /\ phase' = "Done"
  /\ outcome' = "reacquire-unavailable"
  /\ UNCHANGED <<previous, current, generation, rollbackToken,
                  laterAttempts, lastIntent, restoreGenerationAdvanced,
                  restoreBaseGeneration>>

SkipNewerIntent ==
  /\ phase = "Holding"
  /\ ~GuardMatches
  /\ phase' = "Done"
  /\ outcome' = "skip-newer-intent"
  /\ UNCHANGED <<previous, current, generation, rollbackToken,
                  laterAttempts, lastIntent, restoreGenerationAdvanced,
                  restoreBaseGeneration>>

(* These refusals occur before restore's own generation bump. *)
RestorePendingRefusal ==
  /\ AllowRefusals
  /\ phase = "Holding"
  /\ GuardMatches
  /\ phase' = "Done"
  /\ outcome' = "restore-pending-refusal"
  /\ UNCHANGED <<previous, current, generation, rollbackToken,
                  laterAttempts, lastIntent, restoreGenerationAdvanced,
                  restoreBaseGeneration>>

RestoreGenerationRefusal ==
  /\ AllowRefusals
  /\ phase = "Holding"
  /\ GuardMatches
  /\ phase' = "Done"
  /\ outcome' = "restore-generation-refusal"
  /\ UNCHANGED <<previous, current, generation, rollbackToken,
                  laterAttempts, lastIntent, restoreGenerationAdvanced,
                  restoreBaseGeneration>>

(* Production advances generation inside restore_wan_zone_log before staging.
   Save the pre-bump live generation separately from the rollback token. *)
BeginRestore ==
  /\ phase = "Holding"
  /\ GuardMatches
  /\ generation < MaxGeneration
  /\ phase' = "Restoring"
  /\ generation' = generation + 1
  /\ restoreBaseGeneration' = generation
  /\ restoreGenerationAdvanced' = TRUE
  /\ UNCHANGED <<previous, current, rollbackToken, laterAttempts,
                  lastIntent, outcome>>

RestoreStageFailure ==
  /\ AllowRefusals
  /\ phase = "Restoring"
  /\ phase' = "Done"
  /\ outcome' = "restore-stage-failure"
  /\ UNCHANGED <<previous, current, generation, rollbackToken,
                  laterAttempts, lastIntent, restoreGenerationAdvanced,
                  restoreBaseGeneration>>

RestorePostStageRefusal ==
  /\ AllowRefusals
  /\ phase = "Restoring"
  /\ phase' = "Done"
  /\ outcome' = "restore-post-stage-refusal"
  /\ UNCHANGED <<previous, current, generation, rollbackToken,
                  laterAttempts, lastIntent, restoreGenerationAdvanced,
                  restoreBaseGeneration>>

RestoreCommitFailure ==
  /\ AllowRefusals
  /\ phase = "Restoring"
  /\ phase' = "Done"
  /\ outcome' = "restore-commit-failure"
  /\ UNCHANGED <<previous, current, generation, rollbackToken,
                  laterAttempts, lastIntent, restoreGenerationAdvanced,
                  restoreBaseGeneration>>

RestoreCommitSuccess ==
  /\ phase = "Restoring"
  /\ phase' = "Done"
  /\ outcome' = "restored"
  /\ current' = IF RestoreBehavior = "exact"
                THEN previous
                ELSE WrongRestoreValue(previous)
  /\ UNCHANGED <<previous, generation, rollbackToken, laterAttempts,
                  lastIntent, restoreGenerationAdvanced, restoreBaseGeneration>>

(* Fairness is deliberately scoped to local post-reload decision steps. It is
   not a progress claim for provider commands or for the shell as a whole. *)
DecisionProgress ==
  \/ ReacquireSuccess
  \/ ReacquireUnavailable
  \/ SkipNewerIntent
  \/ RestorePendingRefusal
  \/ RestoreGenerationRefusal
  \/ BeginRestore
  \/ RestoreStageFailure
  \/ RestorePostStageRefusal
  \/ RestoreCommitFailure
  \/ RestoreCommitSuccess

NoStutter ==
  \/ PrimaryCommit
  \/ ReloadFails
  \/ LaterCommit
  \/ LaterNoOp
  \/ LaterFailedAttempt
  \/ ReacquireSuccess
  \/ ReacquireUnavailable
  \/ SkipNewerIntent
  \/ RestorePendingRefusal
  \/ RestoreGenerationRefusal
  \/ BeginRestore
  \/ RestoreStageFailure
  \/ RestorePostStageRefusal
  \/ RestoreCommitFailure
  \/ RestoreCommitSuccess

Next == NoStutter \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars /\ WF_vars(DecisionProgress)

RollbackDecisionCompletes ==
  (phase \in {"Waiting", "Holding", "Restoring"}) ~> (phase = "Done")

RestoreLandsWhenEligible ==
  (phase = "Holding" /\ GuardMatches) ~>
    (phase = "Done" /\ outcome = "restored" /\ current = previous)

TerminalOutcomeClassified == phase = "Done" => outcome # "none"
AttemptRecordsIntent ==
  /\ (laterAttempts = 0 => lastIntent = "none")
  /\ (laterAttempts > 0 => lastIntent \in ToggleIntents)
RestoreValueIsPrevious == outcome = "restored" => current = previous
NoRestoreAfterNewerIntent == outcome = "restored" => laterAttempts = 0
RestoreGenerationAdvancedExactly ==
  restoreGenerationAdvanced => generation = restoreBaseGeneration + 1

====
