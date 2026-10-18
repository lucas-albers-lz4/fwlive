# Rollback induction route comparison — #1322

B freezes the failure-aware Outcomes contract at commit
49a9ef4c37154c389660e2f3de0bb97932bfa0f0; B does not modify its transition
relation. This refresh follows the review of the updated B/master history;
B's helper/model/capture/projector bytes match its original frozen contract.
The generation-limit host fixture exists and passes separately.

Before the feasibility spike, compare: exact reuse of Outcomes transitions,
unbounded later-attempt counters, explicit init/preservation/implication
obligations, a meaningful weakened-guard failure, pinned reproducible tooling,
and maintenance cost. Time box: 45 minutes for a first checked obligation.

Selected candidate: Apalache 0.62.1, already used by the polling toolchain.
Its integer SMT theory can check one-step induction from an invariant over Nat;
this is distinct from checking a bounded prefix from Init. TLAPS remains a valid
alternative, but would introduce a second proof runtime for this narrow arithmetic
invariant; defer it unless the selected route cannot express/check the obligations.
No second competing model or maintained proof backend is proposed.

Generalization must reuse the production-shaped Outcomes actions with explicit
budget parameters. Keep existing finite TLC wrappers unchanged. Unbounded-history
and deployed-generation-limit contracts are separate configurations. External
writers, resetting volatile state with callers in flight, and helper success /
scheduling are assumptions, not implied safety or liveness guarantees.

Result: **go**, with Apalache integer induction. The first base and preservation
obligations passed within the 45-minute time box. All six obligations then passed
for the two contracts; a seventh checks no generation advancement from any
invariant state already at the deployed cap. The value-only guard mutation
fails preservation at a named invariant, with exit 12, not a tool error.
The maintained runner is `scripts/formal-induction.sh`; detailed contract and
source mapping are in `formal/wan-log-lock/README-wan-log-lock.md`.

The primary agent owns this proof/refactor; Luna performed the independent
mathematical obligation review. Final runner/CI review is recorded on the PR.
No TLAPS runtime or competing induction model is maintained.
