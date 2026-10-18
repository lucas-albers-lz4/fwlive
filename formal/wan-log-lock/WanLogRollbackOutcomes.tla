---- MODULE WanLogRollbackOutcomes ----
(***************************************************************************)
(* Failure-aware finite abstraction of one WAN log reload-failure rollback. *)
(***************************************************************************)
EXTENDS Naturals, TLC

CONSTANT
  \* @type: Str;
  PrimaryIntent
CONSTANT
  \* @type: Str;
  GuardMode
CONSTANT
  \* @type: Str;
  RestoreBehavior
CONSTANT
  \* @type: Bool;
  AllowRefusals

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

\* @type: {present: Bool, rest: Str, logBit: Bool} => Bool;
Enabled(value) == value.present /\ value.logBit

\* @type: ({present: Bool, rest: Str, logBit: Bool}, Str) => {present: Bool, rest: Str, logBit: Bool};
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

\* @type: {present: Bool, rest: Str, logBit: Bool} => {present: Bool, rest: Str, logBit: Bool};
WrongRestoreValue(value) ==
  IF value.present THEN Unset
  ELSE [present |-> TRUE, rest |-> "zero", logBit |-> FALSE]

Phases == {"Fresh", "Reloading", "Waiting", "Holding", "Restoring", "Done"}
Outcomes ==
  {"none", "restored", "skip-newer-intent", "reacquire-unavailable",
   "restore-pending-refusal", "restore-generation-refusal",
   "restore-stage-failure", "restore-post-stage-refusal",
   "restore-commit-failure"}

(* Bound the finite TLC wrappers: primary + two later attempts + restore.
   The When(CanAdvance) operators below share the same transition bodies with
   the induction driver, which supplies a different explicit budget guard. *)
MaxLaterAttempts == 2
MaxGeneration == 4

VARIABLE
  \* @type: Str;
  phase
VARIABLE
  \* @type: {present: Bool, rest: Str, logBit: Bool};
  previous
VARIABLE
  \* @type: {present: Bool, rest: Str, logBit: Bool};
  current
VARIABLE
  \* @type: Int;
  generation
VARIABLE
  \* @type: Int;
  rollbackToken
VARIABLE
  \* @type: Int;
  laterAttempts
VARIABLE
  \* @type: Str;
  lastIntent
VARIABLE
  \* @type: Str;
  outcome
VARIABLE
  \* @type: Bool;
  restoreGenerationAdvanced
VARIABLE
  \* @type: Int;
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

InitAt(initialGeneration) ==
  /\ phase = "Fresh"
  /\ previous \in PreviousValues
  /\ current = previous
  /\ generation = initialGeneration
  /\ rollbackToken = initialGeneration
  /\ laterAttempts = 0
  /\ lastIntent = "none"
  /\ outcome = "none"
  /\ restoreGenerationAdvanced = FALSE
  /\ restoreBaseGeneration = initialGeneration

Init == InitAt(0)

PrimaryCommitAt(nextGeneration) ==
  /\ phase = "Fresh"
  /\ current' = TargetValue
  /\ generation' = nextGeneration
  /\ rollbackToken' = nextGeneration
  /\ phase' = "Reloading"
  /\ UNCHANGED <<previous, laterAttempts, lastIntent, outcome,
                  restoreGenerationAdvanced, restoreBaseGeneration>>

PrimaryCommit == PrimaryCommitAt(1)

ReloadFails ==
  /\ phase = "Reloading"
  /\ phase' = "Waiting"
  /\ UNCHANGED <<previous, current, generation, rollbackToken,
                  laterAttempts, lastIntent, outcome,
                  restoreGenerationAdvanced, restoreBaseGeneration>>

LaterCommitWhen(CanAdvance) ==
  \E intent \in ToggleIntents:
    /\ phase \in {"Reloading", "Waiting"}
    /\ CanAdvance
    /\ (IF intent = "enable" THEN ~Enabled(current) ELSE Enabled(current))
    /\ current' = SetIntent(current, intent)
    /\ generation' = generation + 1
    /\ laterAttempts' = laterAttempts + 1
    /\ lastIntent' = intent
    /\ UNCHANGED <<phase, previous, rollbackToken, outcome,
                    restoreGenerationAdvanced, restoreBaseGeneration>>

LaterCommit == LaterCommitWhen(
  laterAttempts < MaxLaterAttempts /\ generation < MaxGeneration)

(* Same-state requests are intent: they advance the shared generation even
   though committed UCI remains unchanged. *)
LaterNoOpWhen(CanAdvance) ==
  \E intent \in ToggleIntents:
    /\ phase \in {"Reloading", "Waiting"}
    /\ CanAdvance
    /\ (IF intent = "enable" THEN Enabled(current) ELSE ~Enabled(current))
    /\ generation' = generation + 1
    /\ laterAttempts' = laterAttempts + 1
    /\ lastIntent' = intent
    /\ UNCHANGED <<phase, previous, current, rollbackToken, outcome,
                    restoreGenerationAdvanced, restoreBaseGeneration>>

LaterNoOp == LaterNoOpWhen(
  laterAttempts < MaxLaterAttempts /\ generation < MaxGeneration)

(* A writer can fail after recording its intent generation but before UCI
   commits. The failed attempt still invalidates an older rollback token. *)
LaterFailedAttemptWhen(CanAdvance) ==
  \E intent \in ToggleIntents:
    /\ phase \in {"Reloading", "Waiting"}
    /\ CanAdvance
    /\ generation' = generation + 1
    /\ laterAttempts' = laterAttempts + 1
    /\ lastIntent' = intent
    /\ UNCHANGED <<phase, previous, current, rollbackToken, outcome,
                    restoreGenerationAdvanced, restoreBaseGeneration>>

LaterFailedAttempt == LaterFailedAttemptWhen(
  laterAttempts < MaxLaterAttempts /\ generation < MaxGeneration)

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
BeginRestoreWhen(CanAdvance) ==
  /\ phase = "Holding"
  /\ GuardMatches
  /\ CanAdvance
  /\ phase' = "Restoring"
  /\ generation' = generation + 1
  /\ restoreBaseGeneration' = generation
  /\ restoreGenerationAdvanced' = TRUE
  /\ UNCHANGED <<previous, current, rollbackToken, laterAttempts,
                  lastIntent, outcome>>

BeginRestore == BeginRestoreWhen(generation < MaxGeneration)

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
(* Restore refusals/failures that pass the outer guard must not publish a
   restored value. Skip/unavailable outcomes can already equal previous after
   later cooperating attempts, so they are deliberately excluded. *)
RestoreFailureKeepsTarget ==
  outcome \in {"restore-pending-refusal", "restore-generation-refusal",
               "restore-stage-failure", "restore-post-stage-refusal",
               "restore-commit-failure"} => current = TargetValue

(* Check both the bump amount and which paths are allowed to take the bump. *)
RestoreGenerationAdvancedExactly ==
  /\ (restoreGenerationAdvanced => generation = restoreBaseGeneration + 1)
  /\ generation = rollbackToken + laterAttempts +
       (IF restoreGenerationAdvanced THEN 1 ELSE 0)
  /\ (restoreGenerationAdvanced <=>
       (phase = "Restoring" \/
        outcome \in {"restored", "restore-stage-failure",
                     "restore-post-stage-refusal", "restore-commit-failure"}))

====
