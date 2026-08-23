#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Host-side Z3 checks for fwlive regex / address sanitation (#120 / #121).

F1: alphabet gate for `is_resolvable_address` in rpcd/fwlive (pre-awk
`case *[ !0-9a-fA-F:.]*`). Not a full re-encoding of the awk IPv6 grammar.

Usage:
  ./scripts/z3-verify.py --fast
  ./scripts/z3-verify.py --full
"""
from __future__ import annotations

import argparse
import sys

try:
	from z3 import And, If, Or, Solver, String, StringVal, sat, unsat
	from z3 import Length, SubString
except ImportError:  # pragma: no cover
	print(
		"error: z3 python module missing (pip install 'z3-solver==5.0.0')",
		file=sys.stderr,
	)
	sys.exit(2)

# Matches the pre-awk case alphabet in is_resolvable_address (#190/#192).
ADDR_ALPHABET = "0123456789abcdefABCDEF:."
# Bound for quantifier-free char-at encoding. Proofs are valid up to this
# length (not length-independent). Real addresses are far shorter.
ADDR_MAX_LEN = 64


def _char_in(s, i, alphabet: str):
	"""Z3 OR: character at position i of s is one of alphabet."""
	return Or(*[SubString(s, i, 1) == StringVal(c) for c in alphabet])


def alphabet_ok(s):
	"""Z3 predicate: non-empty, length ≤ ADDR_MAX_LEN, only ADDR_ALPHABET chars.

	Domain: proven for Length(s) in [1, ADDR_MAX_LEN]. Strings longer than
	ADDR_MAX_LEN are outside this model (shell has no length cap on the case
	alphabet alone).
	"""
	n = Length(s)
	conds = [n >= 1, n <= ADDR_MAX_LEN]
	for i in range(ADDR_MAX_LEN):
		conds.append(If(n > i, _char_in(s, i, ADDR_ALPHABET), True))
	return And(*conds)


def check_unsat(name: str, formula) -> bool:
	"""Assert formula is unsatisfiable; print ok/FAIL and return success."""
	sol = Solver()
	sol.add(formula)
	r = sol.check()
	if r == unsat:
		print(f"ok: {name}")
		return True
	if r == sat:
		print(f"FAIL: {name} — unexpected model: {sol.model()}", file=sys.stderr)
		return False
	print(f"FAIL: {name} — solver {r}", file=sys.stderr)
	return False


def check_sat(name: str, formula) -> bool:
	"""Assert formula is satisfiable; print ok/FAIL and return success."""
	sol = Solver()
	sol.add(formula)
	r = sol.check()
	if r == sat:
		print(f"ok: {name}")
		return True
	print(f"FAIL: {name} — expected sat got {r}", file=sys.stderr)
	return False


def run_f1_fast() -> int:
	"""F1 --fast: alphabet-level rejection/acceptance; return failure count."""
	fail = 0
	a = String("a")

	# Empty rejected
	if not check_unsat("F1 empty rejected", And(a == StringVal(""), alphabet_ok(a))):
		fail += 1

	# Shell / whitespace metachars rejected at alphabet gate
	for label, bad in (
		("space", "not an ip"),
		("dollar-paren", "$(reboot)"),
		("backtick", "`id`"),
		("slash", "1.2.3.4/24"),
		("percent", "%s"),
		("newline-embed", "192.0.2.1\nevil"),
	):
		if not check_unsat(
			f"F1 reject {label}",
			And(a == StringVal(bad), alphabet_ok(a)),
		):
			fail += 1

	# Hostname with non-hex letters rejected (x,m,p,l not in hex alphabet)
	if not check_unsat(
		"F1 reject hostname example.com",
		And(a == StringVal("example.com"), alphabet_ok(a)),
	):
		fail += 1

	# Good literals are alphabet-admissible
	for label, good in (
		("ipv4", "192.0.2.1"),
		("ipv6", "2001:db8::1"),
		("ipv6-loopback", "::1"),
	):
		if not check_sat(
			f"F1 accept alphabet {label}",
			And(a == StringVal(good), alphabet_ok(a)),
		):
			fail += 1

	return fail


def run_f1_full() -> int:
	"""F1 --full: fast suite + dotted-hex / extra metachar corpus."""
	fail = run_f1_fast()
	a = String("a")

	# Dotted-hex hostname shapes: may still be alphabet-ok (only hex+dots).
	# Document domain: alphabet gate alone does NOT reject these; awk does.
	# Prove they are alphabet-admissible so we do not falsely claim alphabet rejects them.
	for label, hexish in (
		("dotted-hex-short", "ab.cd.ef.01"),
		("dotted-hex-long", "dead.beef.cafe.baad"),
	):
		if not check_sat(
			f"F1 alphabet admits {label} (awk rejects; not alphabet)",
			And(a == StringVal(hexish), alphabet_ok(a)),
		):
			fail += 1

	# Additional metachar corpus
	for label, bad in (
		("semicolon", "1;2"),
		("pipe", "1|2"),
		("ampersand", "1&2"),
		("quote", "1'2"),
		("dquote", '1"2'),
	):
		if not check_unsat(
			f"F1 reject {label}",
			And(a == StringVal(bad), alphabet_ok(a)),
		):
			fail += 1

	return fail


def run_fast() -> int:
	"""Pre-commit subset (#121); return failure count."""
	# F2–F4 stubs land in later PRs; F1 only for now.
	return run_f1_fast()


def run_full() -> int:
	"""CI / full suite (#121); return failure count."""
	return run_f1_full()


def main() -> int:
	"""Parse args and run the fast or full Z3 suite; return process exit code."""
	ap = argparse.ArgumentParser(description=__doc__)
	g = ap.add_mutually_exclusive_group()
	g.add_argument("--fast", action="store_true", help="pre-commit subset")
	g.add_argument("--full", action="store_true", help="CI / full suite (default)")
	args = ap.parse_args()
	mode_full = not args.fast
	fail = run_full() if mode_full else run_fast()
	if fail:
		print(f"z3-verify: {fail} failure(s)", file=sys.stderr)
		return 1
	print(f"z3-verify: all ok ({'full' if mode_full else 'fast'})")
	return 0


if __name__ == "__main__":
	sys.exit(main())
