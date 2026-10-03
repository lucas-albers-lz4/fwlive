---- MODULE WanLogRollbackReplay ----
(***************************************************************************
 * Test-only bounded replay adapter. `ActionFor` names actions from the
 * failure-aware model; it does not reimplement their transition relation.
 * Observation arrays contain only projected committed value and generation.
 *************************************************************************** *)
EXTENDS WanLogRollbackOutcomes

CONSTANTS
  TraceLength, InitialValue, InitialGeneration,
  Step1, Step2, Step3, Step4, Step5, Step6, Step7, Step8,
  Value1, Value2, Value3, Value4, Value5, Value6, Value7, Value8,
  Generation1, Generation2, Generation3, Generation4,
  Generation5, Generation6, Generation7, Generation8,
  Intent1, Intent2, Intent3, Intent4, Intent5, Intent6, Intent7, Intent8

VARIABLES replayIndex, replayError
replayVars == <<vars, replayIndex, replayError>>

StepAt(i) ==
  CASE i = 1 -> Step1
    [] i = 2 -> Step2
    [] i = 3 -> Step3
    [] i = 4 -> Step4
    [] i = 5 -> Step5
    [] i = 6 -> Step6
    [] i = 7 -> Step7
    [] i = 8 -> Step8

ObservedValueAt(i) ==
  CASE i = 1 -> Value1
    [] i = 2 -> Value2
    [] i = 3 -> Value3
    [] i = 4 -> Value4
    [] i = 5 -> Value5
    [] i = 6 -> Value6
    [] i = 7 -> Value7
    [] i = 8 -> Value8

ObservedGenerationAt(i) ==
  CASE i = 1 -> Generation1
    [] i = 2 -> Generation2
    [] i = 3 -> Generation3
    [] i = 4 -> Generation4
    [] i = 5 -> Generation5
    [] i = 6 -> Generation6
    [] i = 7 -> Generation7
    [] i = 8 -> Generation8

ObservedIntentAt(i) ==
  CASE i = 1 -> Intent1
    [] i = 2 -> Intent2
    [] i = 3 -> Intent3
    [] i = 4 -> Intent4
    [] i = 5 -> Intent5
    [] i = 6 -> Intent6
    [] i = 7 -> Intent7
    [] i = 8 -> Intent8

ModelValue(value) ==
  CASE value = "unset" -> Unset
    [] value = "off" -> [present |-> TRUE, rest |-> "zero", logBit |-> FALSE]
    [] value = "on" -> [present |-> TRUE, rest |-> "zero", logBit |-> TRUE]

ActionFor(step) ==
  CASE step = "PrimaryCommit" -> PrimaryCommit
    [] step = "LaterCommit" -> LaterCommit
    [] step = "LaterNoOp" -> LaterNoOp
    [] step = "LaterFailedAttempt" -> LaterFailedAttempt
    [] step = "ReloadFails" -> ReloadFails
    [] step = "ReacquireSuccess" -> ReacquireSuccess
    [] step = "ReacquireUnavailable" -> ReacquireUnavailable
    [] step = "SkipNewerIntent" -> SkipNewerIntent
    [] step = "RestorePendingRefusal" -> RestorePendingRefusal
    [] step = "RestoreGenerationRefusal" -> RestoreGenerationRefusal
    [] step = "BeginRestore" -> BeginRestore
    [] step = "RestoreStageFailure" -> RestoreStageFailure
    [] step = "RestorePostStageRefusal" -> RestorePostStageRefusal
    [] step = "RestoreCommitFailure" -> RestoreCommitFailure
    [] step = "RestoreCommitSuccess" -> RestoreCommitSuccess
    [] OTHER -> FALSE

InitReplay ==
  /\ Init
  /\ replayIndex = 1
  /\ replayError = FALSE
  /\ current = ModelValue(InitialValue)
  /\ generation = InitialGeneration

ReplayCandidate ==
  /\ ~replayError
  /\ replayIndex \in 1..TraceLength
  /\ ActionFor(StepAt(replayIndex))
  /\ current' = ModelValue(ObservedValueAt(replayIndex))
  /\ generation' = ObservedGenerationAt(replayIndex)
  /\ lastIntent' =
       IF StepAt(replayIndex) \in {"LaterCommit", "LaterNoOp", "LaterFailedAttempt"}
       THEN ObservedIntentAt(replayIndex)
       ELSE lastIntent
  /\ replayIndex' = replayIndex + 1
  /\ replayError' = FALSE

RejectInvalidObservation ==
  /\ ~replayError
  /\ replayIndex \in 1..TraceLength
  /\ ~ENABLED ReplayCandidate
  /\ UNCHANGED vars
  /\ UNCHANGED replayIndex
  /\ replayError' = TRUE

ReplayTerminal ==
  /\ replayError \/ replayIndex = TraceLength + 1
  /\ UNCHANGED replayVars

NextReplay == ReplayCandidate \/ RejectInvalidObservation \/ ReplayTerminal
SpecReplay ==
  /\ InitReplay
  /\ [][NextReplay]_replayVars
  /\ WF_replayVars(ReplayCandidate \/ RejectInvalidObservation)

ReplayTypeOK ==
  /\ TraceLength \in 1..8
  /\ InitialValue \in {"unset", "off", "on"}
  /\ InitialGeneration \in 0..MaxGeneration
  /\ \A i \in 1..8: ObservedIntentAt(i) \in {"none", "enable", "disable"}
  /\ replayIndex \in 1..(TraceLength + 1)
  /\ replayError \in BOOLEAN

NoInvalidObservation == replayError = FALSE
ReplayCompletes == <> (replayIndex = TraceLength + 1)

====
