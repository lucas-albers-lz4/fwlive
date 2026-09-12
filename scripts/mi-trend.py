#!/usr/bin/env python3
"""MI trend report (track 1, JS/Python) — trend-only, never gates.

Runs pinned ``lizard -Ehalstead`` over the shipped-only, generated-excluded
set, writes per-function metrics JSON, and diffs against the committed
baseline. Exit 0 on success even when MI drifts; exit nonzero only when
the measurement itself fails (lizard error, unparseable output).

Usage:
  python3 scripts/mi-trend.py [--update-baseline] [--out PATH]
"""
import csv
import json
import math
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "tests" / "fixtures" / "mi-baseline.json"
DEFAULT_OUT = ROOT / "out" / "mi-trend.json"

# Pinned per fwlive#323 measurement spec.
LIZARD_VERSION = "1.24.0"
SCAN_DIRS = ["core", "openwrt-feed", "scripts"]
EXCLUDES = ["*/css.js"]  # generated (scripts/embed-fwlive-css.js output)
MI_GOOD = 85
MI_LOW = 65
DRIFT_TOLERANCE = 5.0


def mi_vs(volume, ccn, loc):
    """Visual-Studio-normalized MI, 0-100, floored at 0."""
    v = max(float(volume), 1.0)
    n = max(int(loc), 1)
    return max(0.0, (171 - 5.2 * math.log(v) - 0.23 * int(ccn)
                     - 16.2 * math.log(n)) * 100 / 171)


def run_lizard():
    cmd = ["lizard", "-Ehalstead", "--csv"]
    for pat in EXCLUDES:
        cmd += ["-x", pat]
    cmd += SCAN_DIRS
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"lizard failed (exit {proc.returncode}):\n{proc.stderr[-2000:]}",
              file=sys.stderr)
        sys.exit(2)
    return proc.stdout


def parse_functions(csv_text):
    """CSV cols: NLOC,CCN,tokens,PARAM,length,location,file,func,long_name,
    start,end,halstead_volume,halstead_difficulty,halstead_effort."""
    funcs = []
    for row in csv.reader(csv_text.splitlines()):
        if len(row) < 13 or row[0] == "NLOC":
            continue
        try:
            nloc, ccn = int(row[0]), int(row[1])
            volume = float(row[11])
        except ValueError:
            continue
        funcs.append({
            "file": row[6].lstrip("./"),
            "func": row[7],
            "loc": row[5],
            "nloc": nloc,
            "ccn": ccn,
            "volume": round(volume, 2),
            "mi": round(mi_vs(volume, ccn, nloc), 1),
        })
    if not funcs:
        print("no functions parsed from lizard output", file=sys.stderr)
        sys.exit(2)
    funcs.sort(key=lambda f: (f["file"], f["func"]))
    return funcs


def key(f):
    return f"{f['file']} :: {f['func']} ({f['loc']})"


def diff_baseline(funcs):
    """Compare against committed baseline; returns drift lines (informational)."""
    if not BASELINE.exists():
        return ["no baseline at tests/fixtures/mi-baseline.json "
                "(run with --update-baseline once, then commit it)"]
    old = {key(f): f for f in json.loads(BASELINE.read_text())["functions"]}
    new = {key(f): f for f in funcs}
    lines = []
    for k, f in new.items():
        if k not in old:
            if f["mi"] < MI_LOW:
                lines.append(f"NEW low-MI: {k} MI={f['mi']}")
        elif old[k]["mi"] - f["mi"] > DRIFT_TOLERANCE:
            lines.append(f"REGRESSED: {k} MI {old[k]['mi']} -> {f['mi']}")
    for k in old:
        if k not in new:
            lines.append(f"REMOVED: {k}")
    return lines


def main(argv):
    update = "--update-baseline" in argv
    out = DEFAULT_OUT
    if "--out" in argv:
        out = Path(argv[argv.index("--out") + 1])

    try:
        out_v = subprocess.run(["lizard", "--version"], capture_output=True,
                               text=True, cwd=ROOT).stdout.strip()
    except FileNotFoundError:
        print("lizard not found; pip install lizard==1.24.0", file=sys.stderr)
        sys.exit(2)
    if LIZARD_VERSION not in out_v:
        print(f"warning: expected lizard {LIZARD_VERSION}, got: {out_v}",
              file=sys.stderr)

    funcs = parse_functions(run_lizard())
    low = sum(1 for f in funcs if f["mi"] < MI_LOW)
    import statistics
    report = {
        "tool": f"lizard {LIZARD_VERSION} -Ehalstead",
        "formula": "MI = (171 - 5.2*ln(V) - 0.23*G - 16.2*ln(LOC)) * 100/171, floor 0",
        "scope": SCAN_DIRS,
        "excludes": EXCLUDES,
        "bands": {"good": MI_GOOD, "low": MI_LOW},
        "summary": {
            "functions": len(funcs),
            "mean_mi": round(statistics.mean(f["mi"] for f in funcs), 1),
            "median_mi": round(statistics.median(f["mi"] for f in funcs), 1),
            "below_65": low,
        },
        "functions": funcs,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=1) + "\n")

    s = report["summary"]
    print(f"functions={s['functions']} mean={s['mean_mi']} "
          f"median={s['median_mi']} below65={s['below_65']}")
    if update:
        BASELINE.write_text(json.dumps(report, indent=1) + "\n")
        print(f"baseline written to {BASELINE}")
    else:
        for line in diff_baseline(funcs):
            print(line)
    print(f"report: {out} (trend-only, not a gate)")


if __name__ == "__main__":
    main(sys.argv[1:])
