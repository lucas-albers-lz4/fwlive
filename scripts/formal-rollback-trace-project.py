#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Project raw #1121 shell observations to the existing TLA+ replay adapter."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


class TraceError(Exception):
    pass


def read_facts(path: Path) -> tuple[str, str, list[dict[str, str]]]:
    scenario = ""
    initial_value = ""
    initial_generation = ""
    facts: list[dict[str, str]] = []
    for line_no, raw in enumerate(path.read_text().splitlines(), 1):
        fields = raw.split("|")
        kind = fields[0]
        expected = {"INITIAL": 5, "SNAP": 8, "UCI": 11, "CHANGES": 9,
                    "FLOCK": 9, "RELOAD": 8, "LOG": 8, "JSON": 6, "GENERATION_TEMP": 8}.get(kind)
        if expected is None or len(fields) != expected:
            raise TraceError(f"{path}:{line_no}: malformed {kind!r} observation")
        if kind == "INITIAL":
            if scenario:
                raise TraceError(f"{path}:{line_no}: duplicate INITIAL observation")
            scenario, _pid, initial_value, initial_generation = fields[1:]
            continue
        if fields[1] != scenario:
            raise TraceError(f"{path}:{line_no}: scenario does not match INITIAL")
        if kind == "SNAP":
            _, _, role, pid, point, intent, value, generation = fields
            fact = dict(kind=kind, role=role, pid=pid, point=point, intent=intent,
                        value=value, generation=generation)
        elif kind == "UCI":
            _, _, role, pid, intent, operation, rc, before_value, after_value, before_generation, after_generation = fields
            fact = dict(kind=kind, role=role, pid=pid, intent=intent, operation=operation, rc=rc,
                        before_value=before_value, after_value=after_value,
                        before_generation=before_generation, after_generation=after_generation)
        elif kind == "CHANGES":
            _, _, role, pid, intent, rc, value, generation, contents = fields
            fact = dict(kind=kind, role=role, pid=pid, intent=intent, rc=rc,
                        value=value, generation=generation, contents=contents)
        elif kind == "FLOCK":
            _, _, role, pid, intent, args, rc, value, generation = fields
            fact = dict(kind=kind, role=role, pid=pid, intent=intent, args=args, rc=rc,
                        value=value, generation=generation)
        elif kind == "RELOAD":
            _, _, role, pid, intent, rc, value, generation = fields
            fact = dict(kind=kind, role=role, pid=pid, intent=intent, rc=rc,
                        value=value, generation=generation)
        elif kind == "GENERATION_TEMP":
            _, _, role, pid, intent, rc, value, generation = fields
            fact = dict(kind=kind, role=role, pid=pid, intent=intent, rc=rc,
                        value=value, generation=generation)
        elif kind == "LOG":
            _, _, role, pid, intent, value, generation, message = fields
            fact = dict(kind=kind, role=role, pid=pid, intent=intent, value=value,
                        generation=generation, message=message)
        else:
            _, _, role, pid, intent, response = fields
            fact = dict(kind=kind, role=role, pid=pid, intent=intent, response=response)
        if fact.get("role") not in {"primary", "secondary"} or fact.get("intent") not in {"enable", "disable"}:
            raise TraceError(f"{path}:{line_no}: invalid caller role/intent")
        if not fact.get("pid", "").isdigit():
            raise TraceError(f"{path}:{line_no}: invalid caller process")
        if kind == "SNAP" and fact["point"] != "begin" and not fact["point"].startswith("return:"):
            raise TraceError(f"{path}:{line_no}: unexpected snapshot boundary")
        fact["line"] = str(line_no)
        facts.append(fact)
    if not scenario or not initial_value or initial_generation != "0":
        raise TraceError(f"{path}: expected one initial generation-0 snapshot")
    if initial_value not in {"unset", "0", "1"}:
        raise TraceError(f"{path}: initial value outside unset/0/1 domain")
    return scenario, initial_value, facts


def normalized_value(value: str, where: str) -> str:
    if value == "unset":
        return "unset"
    if value == "1":
        return "on"
    if value == "0":
        return "off"
    raise TraceError(f"{where}: projection only supports unset/0/1, got {value!r}")


def number(fact: dict[str, str], key: str) -> int:
    try:
        return int(fact[key])
    except (KeyError, ValueError) as exc:
        raise TraceError(f"line {fact.get('line', '?')}: invalid {key} observation") from exc


def make_steps(scenario: str, facts: list[dict[str, str]]) -> tuple[str, list[tuple[str, str, int, str]]]:
    """Infer abstract transitions from provider results; LOG is diagnostic only."""
    steps: list[tuple[str, str, int, str]] = []
    begins = [f for f in facts if f["kind"] == "SNAP" and f["role"] == "primary" and f["point"] == "begin"]
    if len(begins) != 1:
        raise TraceError("expected one primary toggle begin")
    begin = begins[0]
    primary_pid, primary_intent = begin["pid"], begin["intent"]
    if primary_intent not in {"enable", "disable"}:
        raise TraceError("invalid primary intent")
    target = "1" if primary_intent == "enable" else "unset"
    primary_committed = reload_failed = reacquired = restore_started = False
    terminal = False
    committed_generation = 0
    reacquire_fact = None
    failed_lock = None
    fatal_lock_error = False
    generation_failure = None
    pending_before_restore = None
    post_stage_changes = None
    final = None
    response = None
    secondary_commits = {f["pid"] for f in facts if f["kind"] == "UCI" and f["role"] == "secondary" and f["operation"] in {"commit firewall", "-q commit firewall"}}

    # Every later call must have its own complete request/return/JSON evidence,
    # including callers with a commit observation. Never drop their terminals.
    secondary_pids = {f["pid"] for f in facts if f["role"] == "secondary"}
    for pid in secondary_pids:
        call = [f for f in facts if f["role"] == "secondary" and f["pid"] == pid]
        starts = [f for f in call if f["kind"] == "SNAP" and f["point"] == "begin"]
        returns = [f for f in call if f["kind"] == "SNAP" and f["point"].startswith("return:")]
        replies = [f for f in call if f["kind"] == "JSON"]
        if len(starts) != 1 or len(returns) != 1 or len(replies) != 1:
            raise TraceError("secondary call lacks unique begin/return/JSON")
        if returns[0]["point"] != "return:0" or len({f["intent"] for f in call}) != 1:
            raise TraceError("secondary call has contradictory terminal result/intent")
        if not int(starts[0]["line"]) < int(returns[0]["line"]) < int(replies[0]["line"]):
            raise TraceError("secondary call terminal order is invalid")
        if any(f["kind"] == "RELOAD" and f["rc"] != "0" for f in call):
            raise TraceError("secondary reload failure outside declared domain")
        reply = json.loads(replies[0]["response"])
        commits = [f for f in call if f["kind"] == "UCI" and f["operation"] in {"commit firewall", "-q commit firewall"}]
        if len(commits) > 1:
            raise TraceError("multiple commits in secondary call")
        if commits:
            commit = commits[0]
            if commit["rc"] == "0":
                if reply.get("ok") is not True or reply.get("changed") is not True or reply.get("error") is not None:
                    raise TraceError("secondary successful commit/JSON mismatch")
            elif reply.get("error") != "uci_commit_failed" or reply.get("ok") is not False or reply.get("changed") is not False:
                raise TraceError("secondary failed commit/JSON mismatch")
            if (commit["after_value"], commit["after_generation"]) != (returns[0]["value"], returns[0]["generation"]):
                raise TraceError("secondary final state differs from commit checkpoint")

    def add(action: str, fact: dict[str, str], value_key="value", generation_key="generation", intent="none") -> None:
        nonlocal terminal
        if terminal:
            raise TraceError("semantic observation after terminal model action")
        steps.append((action, normalized_value(fact[value_key], action), number(fact, generation_key), intent))
        if action in {"RestoreCommitSuccess", "RestoreCommitFailure", "RestoreStageFailure"}:
            terminal = True

    for fact in facts:
        kind, role = fact["kind"], fact.get("role", "")
        if role == "primary" and (fact["pid"] != primary_pid or fact["intent"] != primary_intent):
            raise TraceError("primary process identity/intent changed")
        if kind == "UCI" and role == "primary" and fact["operation"] in {"commit firewall", "-q commit firewall"}:
            if not primary_committed:
                if fact["rc"] != "0" or fact["after_value"] != target or fact["after_generation"] != "1":
                    raise TraceError("primary commit has unexpected result/value/generation")
                add("PrimaryCommit", fact, "after_value", "after_generation")
                committed_generation = number(fact, "after_generation")
                primary_committed = True
            elif restore_started:
                expected = "-firewall.@zone[0].log" if begin["value"] == "unset" else f"firewall.@zone[0].log='{begin['value']}'"
                if post_stage_changes is None or post_stage_changes["contents"] != expected:
                    raise TraceError("restore commit lacks a valid observed post-stage guard")
                add("RestoreCommitSuccess" if fact["rc"] == "0" else "RestoreCommitFailure", fact, "after_value", "after_generation")
            else:
                raise TraceError("unexpected primary commit before restore")
        elif kind == "UCI" and role == "secondary" and fact["operation"] in {"commit firewall", "-q commit firewall"}:
            add("LaterCommit" if fact["rc"] == "0" else "LaterFailedAttempt", fact,
                "after_value", "after_generation", fact["intent"])
        elif kind == "SNAP" and role == "secondary" and fact["point"].startswith("return:"):
            if fact["pid"] in secondary_commits:
                continue
            start = next((f for f in facts if f["kind"] == "SNAP" and f["pid"] == fact["pid"] and f["point"] == "begin"), None)
            reply = next((f for f in facts if f["kind"] == "JSON" and f["pid"] == fact["pid"]), None)
            if start is None or reply is None or start["intent"] != fact["intent"]:
                raise TraceError("secondary call lacks matching request/response")
            reply_json = json.loads(reply["response"])
            failed_write = any(f["kind"] == "UCI" and f["pid"] == fact["pid"] and f["rc"] != "0" and f["operation"].startswith(("set ", "delete ", "-q set ", "-q delete ")) for f in facts)
            writes = [f for f in facts if f["kind"] == "UCI" and f["pid"] == fact["pid"] and f["operation"].startswith(("set ", "delete ", "-q set ", "-q delete "))]
            if reply_json.get("error") in {"uci_set_failed", "uci_delete_failed"} and reply_json.get("ok") is False and reply_json.get("changed") is False and failed_write:
                action = "LaterFailedAttempt"
            elif reply_json.get("error") is None and reply_json.get("ok") is True and reply_json.get("changed") is False and not writes:
                action = "LaterNoOp"
            else:
                raise TraceError("unclassified secondary no-commit result")
            add(action, fact, intent=fact["intent"])
        elif kind == "RELOAD" and role == "primary":
            if not primary_committed or reload_failed or fact["rc"] != "1":
                raise TraceError("unexpected primary reload result")
            reload_failed = True
            add("ReloadFails", fact)
        elif kind == "FLOCK" and role == "primary" and reload_failed and fact["args"] == "-n 9":
            if fatal_lock_error:
                raise TraceError("reacquisition attempt after fatal lock error")
            if fact["rc"] == "0":
                if reacquired:
                    raise TraceError("duplicate rollback lock acquisition")
                if failed_lock is not None and failed_lock["rc"] != "1":
                    raise TraceError("successful reacquisition after fatal lock error")
                reacquired = True
                reacquire_fact = fact
                add("ReacquireSuccess", fact)
            else:
                failed_lock = fact
                fatal_lock_error = fact["rc"] != "1"
        elif kind == "GENERATION_TEMP" and role == "primary" and reload_failed and reacquired:
            if fact["rc"] != "0":
                generation_failure = fact
        elif kind == "CHANGES" and role == "primary" and reload_failed and reacquired:
            if not restore_started and fact["contents"] != "empty":
                pending_before_restore = fact
            elif restore_started and post_stage_changes is None:
                post_stage_changes = fact
        elif kind == "UCI" and role == "primary" and reload_failed and reacquired and fact["operation"].startswith(("set ", "delete ", "-q set ", "-q delete ")):
            if restore_started:
                raise TraceError("duplicate restore write")
            if pending_before_restore is not None or generation_failure is not None:
                raise TraceError("restore write after observed pre-stage refusal")
            restore_started = True
            add("BeginRestore", fact, "before_value", "before_generation")
            if fact["rc"] != "0":
                add("RestoreStageFailure", fact, "after_value", "after_generation")
        elif kind == "SNAP" and role == "primary" and fact["point"].startswith("return:"):
            if final is not None:
                raise TraceError("duplicate primary return")
            final = fact
        elif kind == "JSON" and role == "primary":
            if response is not None:
                raise TraceError("duplicate primary JSON result")
            response = json.loads(fact["response"])

    if not primary_committed or not reload_failed or final is None or response is None:
        raise TraceError("incomplete primary execution observations")
    if response.get("error") != "firewall_reload_failed" or response.get("ok") is not False or response.get("changed") is not False or final["point"] != "return:0":
        raise TraceError("terminal primary return/JSON is not reload failure")
    if not terminal:
        if not reacquired and failed_lock is not None:
            add("ReacquireUnavailable", failed_lock)
        elif not reacquired:
            raise TraceError("no observed rollback reacquisition result")
        elif not restore_started:
            if reacquire_fact["value"] != target or number(reacquire_fact, "generation") != committed_generation:
                add("SkipNewerIntent", final)
            elif pending_before_restore is not None:
                add("RestorePendingRefusal", pending_before_restore)
            elif generation_failure is not None:
                add("RestoreGenerationRefusal", generation_failure)
            else:
                raise TraceError("no observed reason for restore refusal")
        elif post_stage_changes is not None:
            expected = "-firewall.@zone[0].log" if begin["value"] == "unset" else f"firewall.@zone[0].log='{begin['value']}'"
            if post_stage_changes["contents"] == expected:
                raise TraceError("restore stopped after a valid stage without failure evidence")
            add("RestorePostStageRefusal", post_stage_changes)
        else:
            raise TraceError("unclassified restore termination")
    if sum(step[0] in {"LaterCommit", "LaterNoOp", "LaterFailedAttempt"} for step in steps) > 2:
        raise TraceError("trace exceeds two later-attempt bound")
    if len(steps) > 8:
        raise TraceError("trace exceeds the replay adapter's eight-step cap")
    if any(not 0 <= step[2] <= 4 for step in steps):
        raise TraceError("trace exceeds generation domain 0..4")
    if steps[-1][1:3] != (normalized_value(final["value"], "final return"), number(final, "generation")):
        raise TraceError("final observed state differs from terminal checkpoint")
    return primary_intent, steps


def write_cfg(path: Path, initial: str, primary_intent: str, steps: list[tuple[str, str, int, str]], guard_mode: str) -> None:
    allow_refusals = any(step[0] in {"ReacquireUnavailable", "RestorePendingRefusal", "RestoreGenerationRefusal", "RestoreStageFailure", "RestorePostStageRefusal", "RestoreCommitFailure"} for step in steps)
    lines = ["CONSTANTS", f'  PrimaryIntent = "{primary_intent}"', f'  GuardMode = "{guard_mode}"',
             '  RestoreBehavior = "exact"', f'  AllowRefusals = {"TRUE" if allow_refusals else "FALSE"}',
             f'  TraceLength = {len(steps)}', f'  InitialValue = "{initial}"',
             '  InitialGeneration = 0']
    for index in range(1, 9):
        step, value, generation, intent = steps[index - 1] if index <= len(steps) else ("unused", "unset", 0, "none")
        lines.extend((f'  Step{index} = "{step}"', f'  Value{index} = "{value}"',
                      f'  Generation{index} = {generation}', f'  Intent{index} = "{intent}"'))
    lines.extend(('SPECIFICATION SpecReplay', 'INVARIANT TypeOK', 'INVARIANT ReplayTypeOK',
                  'INVARIANT NoInvalidObservation', 'PROPERTY ReplayCompletes'))
    if any(step[0] == "RestoreCommitSuccess" for step in steps):
        lines.append('PROPERTY RestoreLandsWhenEligible')
    lines.append('')
    path.write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("observations", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--guard-mode", choices=("revision", "valueOnly"), default="revision")
    args = parser.parse_args()
    try:
        scenario, initial, facts = read_facts(args.observations)
        primary_begin = next((f for f in facts if f["kind"] == "SNAP" and f["role"] == "primary" and f["point"] == "begin"), None)
        if primary_begin is None or primary_begin["value"] != initial or primary_begin["generation"] != "0":
            raise TraceError("primary begin does not match initial snapshot")
        primary_intent, steps = make_steps(scenario, facts)
        write_cfg(args.output, normalized_value(initial, "initial"), primary_intent, steps, args.guard_mode)
    except (OSError, TraceError, ValueError) as exc:
        print(f"rollback trace projection FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"rollback trace projected: {scenario}: " + " -> ".join(step[0] for step in steps))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
