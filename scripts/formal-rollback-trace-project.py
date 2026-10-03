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
                    "FLOCK": 9, "RELOAD": 8, "LOG": 8, "JSON": 6}.get(kind)
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
        elif kind == "LOG":
            _, _, role, pid, intent, value, generation, message = fields
            fact = dict(kind=kind, role=role, pid=pid, intent=intent, value=value,
                        generation=generation, message=message)
        else:
            _, _, role, pid, intent, response = fields
            fact = dict(kind=kind, role=role, pid=pid, intent=intent, response=response)
        fact["line"] = str(line_no)
        facts.append(fact)
    if not scenario or not initial_value or initial_generation != "0":
        raise TraceError(f"{path}: expected one initial unset/generation-0 snapshot")
    if initial_value != "unset":
        raise TraceError(f"{path}: this capped pilot supports only an unset initial option")
    return scenario, initial_value, facts


def normalized_value(value: str, where: str) -> str:
    if value == "unset":
        return "unset"
    if value == "1":
        return "on"
    raise TraceError(f"{where}: pilot projection only supports unset and log=1, got {value!r}")


def number(fact: dict[str, str], key: str) -> int:
    try:
        return int(fact[key])
    except (KeyError, ValueError) as exc:
        raise TraceError(f"line {fact.get('line', '?')}: invalid {key} observation") from exc


def make_steps(scenario: str, facts: list[dict[str, str]]) -> list[tuple[str, str, int, str]]:
    steps: list[tuple[str, str, int, str]] = []
    primary_begin = next((fact for fact in facts if fact["kind"] == "SNAP"
                          and fact["role"] == "primary" and fact["point"] == "begin"), None)
    if primary_begin is None:
        raise TraceError("missing primary toggle boundary observation")
    primary_pid = primary_begin["pid"]
    secondary_commits = {fact["pid"] for fact in facts if fact["kind"] == "UCI"
                         and fact["role"] == "secondary" and fact["operation"] == "commit firewall"}
    reload_failed = False
    reacquired = False
    restore_started = False
    primary_committed = False

    for fact in facts:
        kind, role = fact["kind"], fact.get("role", "")
        if kind == "UCI" and role == "primary" and fact["operation"] == "commit firewall" and fact["rc"] == "0":
            if not primary_committed:
                if fact["pid"] != primary_pid or fact["after_value"] != "1" \
                        or fact["after_generation"] != "1":
                    raise TraceError("primary commit observation has unexpected value/generation")
                steps.append(("PrimaryCommit", normalized_value(fact["after_value"], "primary commit"),
                              number(fact, "after_generation"), "none"))
                primary_committed = True
            elif restore_started:
                steps.append(("RestoreCommitSuccess", normalized_value(fact["after_value"], "restore commit"),
                              number(fact, "after_generation"), "none"))
        elif kind == "UCI" and role == "secondary" and fact["operation"] == "commit firewall":
            if fact["rc"] == "0":
                steps.append(("LaterCommit", normalized_value(fact["after_value"], "later commit"),
                              number(fact, "after_generation"), fact["intent"]))
            else:
                steps.append(("LaterFailedAttempt", normalized_value(fact["after_value"], "failed later commit"),
                              number(fact, "after_generation"), fact["intent"]))
        elif kind == "SNAP" and role == "secondary" and fact["point"].startswith("return:"):
            if fact["pid"] in secondary_commits:
                continue
            begin = next((item for item in facts if item["kind"] == "SNAP" and item["pid"] == fact["pid"]
                          and item["point"] == "begin"), None)
            response = next((item for item in facts if item["kind"] == "JSON" and item["pid"] == fact["pid"]), None)
            if begin is None or response is None:
                raise TraceError("secondary no-commit call lacks request/response observations")
            try:
                response_json = json.loads(response["response"])
            except json.JSONDecodeError as exc:
                raise TraceError("secondary response is not JSON") from exc
            if begin["intent"] != fact["intent"]:
                raise TraceError("secondary request/response intent mismatch")
            failed_write = next((item for item in facts if item["kind"] == "UCI"
                                 and item["role"] == "secondary" and item["pid"] == fact["pid"]
                                 and item["rc"] != "0" and item["operation"].startswith(("set ", "delete ", "-q set ", "-q delete "))), None)
            if response_json.get("error") is not None:
                if failed_write is None:
                    raise TraceError("secondary failed response lacks an observed failed UCI write")
                steps.append(("LaterFailedAttempt", normalized_value(fact["value"], "failed later write"),
                              number(fact, "generation"), fact["intent"]))
            elif response_json.get("changed") is False:
                steps.append(("LaterNoOp", normalized_value(fact["value"], "later no-op"),
                              number(fact, "generation"), fact["intent"]))
            else:
                raise TraceError("secondary no-commit call is neither a no-op nor an observed failure")
        elif kind == "RELOAD" and role == "primary" and fact["rc"] == "1":
            reload_failed = True
            steps.append(("ReloadFails", normalized_value(fact["value"], "primary reload"),
                          number(fact, "generation"), "none"))
        elif kind == "FLOCK" and role == "primary" and reload_failed \
                and fact["args"] == "-n 9" and fact["rc"] == "0":
            reacquired = True
            if fact["pid"] != primary_pid:
                raise TraceError("rollback reacquisition was not by the primary process")
            steps.append(("ReacquireSuccess", normalized_value(fact["value"], "rollback reacquisition"),
                          number(fact, "generation"), "none"))
        elif kind == "UCI" and role == "primary" and reload_failed and reacquired \
                and fact["operation"] == "-q delete firewall.@zone[0].log" and not restore_started:
            restore_started = True
            steps.append(("BeginRestore", normalized_value(fact["before_value"], "restore start"),
                          number(fact, "before_generation"), "none"))
        elif kind == "LOG" and role == "primary" \
                and "rollback skipped: firewall changes pending" in fact["message"]:
            steps.append(("RestorePendingRefusal", normalized_value(fact["value"], "pending refusal"),
                          number(fact, "generation"), "none"))
        elif kind == "LOG" and role == "primary" \
                and "changed concurrently or revision unavailable" in fact["message"]:
            steps.append(("SkipNewerIntent", normalized_value(fact["value"], "rollback skip"),
                          number(fact, "generation"), "none"))

    if not primary_committed or not reload_failed or not reacquired:
        raise TraceError("observations lack primary commit, failed reload, or successful rollback reacquisition")
    if not steps or steps[-1][0] not in {"RestoreCommitSuccess", "SkipNewerIntent", "RestorePendingRefusal"}:
        raise TraceError(f"unclassified terminal observations for {scenario}: {steps!r}")
    if len(steps) > 8:
        raise TraceError("trace exceeds the replay adapter's eight-step cap")
    return steps


def write_cfg(path: Path, initial: str, steps: list[tuple[str, str, int, str]], guard_mode: str) -> None:
    allow_refusals = any(step[0] == "RestorePendingRefusal" for step in steps)
    lines = ["CONSTANTS", '  PrimaryIntent = "enable"', f'  GuardMode = "{guard_mode}"',
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
        steps = make_steps(scenario, facts)
        write_cfg(args.output, initial, steps, args.guard_mode)
    except (OSError, TraceError, ValueError) as exc:
        print(f"rollback trace projection FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"rollback trace projected: {scenario}: " + " -> ".join(step[0] for step in steps))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
