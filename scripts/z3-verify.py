#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Host-side Z3 checks for fwlive regex / address sanitation (#120 / #121).

F1: alphabet gate for `is_resolvable_address` in rpcd/fwlive (pre-awk
`case *[ !0-9a-fA-F:.]*`). Not a full re-encoding of the awk IPv6 grammar.

F2: CLASSIFY_SPEC core predicates from core/fwlive-log.js (action / deny /
non-firewall prefix / TCP_FLAG_TAIL / glue keys). Alphabet, finite
alternation, and word-boundary split — not ECMA-direct. NETFILTER_KV_GLUE
lookahead is string-ops (IndexOf / Contains), not the lookahead regex.
Pinned for stock z3-solver==5.0.0 (default seq backend; no z3str3).

Usage:
  ./scripts/z3-verify.py --fast
  ./scripts/z3-verify.py --full
"""
from __future__ import annotations

import argparse
import sys

try:
	from z3 import And, If, Not, Or, Solver, String, StringVal, sat, unsat
	from z3 import Length, SubString, Contains, IndexOf, PrefixOf
	from z3 import Complement, InRe, Range, Re, Union
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

# ---------------------------------------------------------------------------
# F2 pins from core/fwlive-log.js CLASSIFY_SPEC / derived regexes (#198).
# If the JS spec changes, update these tuples. z3-solver==5.0.0.
# JS ACTION_RE / DENY_ACTION / NON_FIREWALL_PREFIX / TCP_FLAG_TAIL are /i;
# F2 models the spelled case in the spec (pilot: exact-case tokens).
# ---------------------------------------------------------------------------
TCP_FLAG_TOKENS = ("SYN", "ACK", "FIN", "RST", "PSH", "URG")
ACTION_WORDS = ("ACCEPT", "ALLOW", "PASS", "DROP", "REJECT", "DENY", "BLOCK")
DENY_WORDS = ACTION_WORDS[3:]  # DROP|REJECT|DENY|BLOCK — CLASSIFY_SPEC slice(3)
NON_FIREWALL_PREFIXES = (
	"dnsmasq",
	"procd",
	"ubusd",
	"netifd",
	"odhcpd",
	"logd",
	"dropbear",
	"uhttpd",
	"hostapd",
	"wpad",
)
GLUE_KEYS = (
	"IN",
	"OUT",
	"SRC",
	"DST",
	"PROTO",
	"SPT",
	"DPT",
	"LEN",
	"MAC",
	"TYPE",
	"CODE",
	"TTL",
	"TOS",
	"PREC",
	"DF",
)
# wordPattern / NON_FIREWALL_PREFIX boundary class: [^A-Za-z0-9_]
ALNUM_US = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
ACTION_TOKEN_MAX = max(len(w) for w in ACTION_WORDS)


def _alphabet_of(words) -> str:
	"""Sorted unique characters of a finite word list."""
	return "".join(sorted(set("".join(words))))


TCP_FLAG_ALPHABET = _alphabet_of(TCP_FLAG_TOKENS)
ACTION_ALPHABET = _alphabet_of(ACTION_WORDS)
GLUE_ALPHABET = _alphabet_of(GLUE_KEYS)
# NON_FIREWALL_PREFIX is /i — first-char gate uses both cases.
NON_FIREWALL_START_ALPHABET = "".join(
	sorted({p[0] for p in NON_FIREWALL_PREFIXES} | {p[0].upper() for p in NON_FIREWALL_PREFIXES})
)


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


def _in_finite_set(s, words):
	"""Z3 OR: s equals one of the finite alternatives."""
	return Or(*[s == StringVal(w) for w in words])


def _alnum_us_re():
	"""Z3 regex for [A-Za-z0-9_]. Length-1 Complement only — not Star(Complement)."""
	return Union(Range("A", "Z"), Range("a", "z"), Range("0", "9"), Re("_"))


def _is_boundary_char(c):
	"""Single-char Complement([A-Za-z0-9_]) (wordPattern flanks)."""
	return And(Length(c) == 1, InRe(c, Complement(_alnum_us_re())))


def _whole_word_at(s, token: str):
	"""token is a whole word: start/end or Complement([A-Za-z0-9_]) flanks."""
	idx = IndexOf(s, StringVal(token), 0)
	n = Length(s)
	tlen = len(token)
	before_ok = Or(
		idx == 0,
		And(idx > 0, InRe(SubString(s, idx - 1, 1), Complement(_alnum_us_re()))),
	)
	after_ok = Or(
		idx + tlen == n,
		And(idx + tlen < n, InRe(SubString(s, idx + tlen, 1), Complement(_alnum_us_re()))),
	)
	return And(idx >= 0, before_ok, after_ok)


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


def run_f2_fast() -> int:
	"""F2 --fast: alphabet / finite-set CLASSIFY_SPEC props; return failure count.

	Domain: length-independent alphabet disjointness, or concrete / tiny-bound
	tokens (action words ≤ ACTION_TOKEN_MAX). Not a full ECMA re-encoding.
	"""
	fail = 0
	c = String("c")
	t = String("t")
	s = String("s")

	# --- TCP_FLAG_TAIL token alphabet (case as in pattern) ---
	# Single-char: flag letters ∩ {=, 0-9} is empty (complement-style).
	if not check_unsat(
		"F2 TCP_FLAG_TAIL alphabet disjoint from =/digit",
		And(
			Length(c) == 1,
			_char_in(c, 0, TCP_FLAG_ALPHABET),
			Or(c == StringVal("="), _char_in(c, 0, "0123456789")),
		),
	):
		fail += 1

	for tok in TCP_FLAG_TOKENS:
		if not check_sat(
			f"F2 TCP_FLAG_TAIL token {tok}",
			And(t == StringVal(tok), _in_finite_set(t, TCP_FLAG_TOKENS)),
		):
			fail += 1

	if not check_unsat(
		"F2 TCP_FLAG_TAIL reject SYNACK as single token",
		And(t == StringVal("SYNACK"), _in_finite_set(t, TCP_FLAG_TOKENS)),
	):
		fail += 1

	# --- ACTION_RE / DENY: finite sets from CLASSIFY_SPEC.actionWords ---
	if not check_unsat(
		"F2 ACTION_RE alphabet disjoint from =/digit",
		And(
			Length(c) == 1,
			_char_in(c, 0, ACTION_ALPHABET),
			Or(c == StringVal("="), _char_in(c, 0, "0123456789")),
		),
	):
		fail += 1

	for w in ACTION_WORDS:
		if not check_sat(
			f"F2 ACTION_RE member {w}",
			And(
				t == StringVal(w),
				Length(t) <= ACTION_TOKEN_MAX,
				_in_finite_set(t, ACTION_WORDS),
			),
		):
			fail += 1

	if not check_unsat(
		"F2 ACTION_RE reject FOOBAR (bounded token)",
		And(
			t == StringVal("FOOBAR"),
			Length(t) <= ACTION_TOKEN_MAX,
			_in_finite_set(t, ACTION_WORDS),
		),
	):
		fail += 1

	if not check_unsat(
		"F2 DENY subset of ACTION_RE",
		And(_in_finite_set(t, DENY_WORDS), Not(_in_finite_set(t, ACTION_WORDS))),
	):
		fail += 1

	if not check_unsat(
		"F2 DENY excludes ACCEPT",
		And(t == StringVal("ACCEPT"), _in_finite_set(t, DENY_WORDS)),
	):
		fail += 1

	for w in DENY_WORDS:
		if not check_sat(
			f"F2 DENY member {w}",
			And(t == StringVal(w), _in_finite_set(t, DENY_WORDS)),
		):
			fail += 1

	# --- NON_FIREWALL_PREFIX: finite daemon names ---
	for p in NON_FIREWALL_PREFIXES:
		if not check_sat(
			f"F2 NON_FIREWALL_PREFIX member {p}",
			And(t == StringVal(p), _in_finite_set(t, NON_FIREWALL_PREFIXES)),
		):
			fail += 1

	if not check_unsat(
		"F2 NON_FIREWALL_PREFIX reject sshd",
		And(t == StringVal("sshd"), _in_finite_set(t, NON_FIREWALL_PREFIXES)),
	):
		fail += 1

	# dnsmasq + non-alnum boundary is prefix-admissible (sat).
	if not check_sat(
		"F2 NON_FIREWALL_PREFIX dnsmasq+boundary admissible",
		And(
			s == StringVal("dnsmasq["),
			PrefixOf(StringVal("dnsmasq"), s),
			Length(s) == len("dnsmasq") + 1,
			Not(_char_in(s, len("dnsmasq"), ALNUM_US)),
		),
	):
		fail += 1

	# Shell metachar-only strings fail the first-char prefix alphabet.
	for label, bad in (
		("dollar-paren", "$(reboot)"),
		("backtick", "`id`"),
		("semicolon", ";rm"),
		("pipe", "|nc"),
		("ampersand", "&bg"),
	):
		if not check_unsat(
			f"F2 NON_FIREWALL_PREFIX reject {label} via start alphabet",
			And(s == StringVal(bad), _char_in(s, 0, NON_FIREWALL_START_ALPHABET)),
		):
			fail += 1

	# --- Glue keys: finite set equals CLASSIFY_SPEC.glueKeys ---
	if not check_unsat(
		"F2 glue alphabet disjoint from lowercase/digit",
		And(
			Length(c) == 1,
			_char_in(c, 0, GLUE_ALPHABET),
			Or(_char_in(c, 0, "abcdefghijklmnopqrstuvwxyz"), _char_in(c, 0, "0123456789")),
		),
	):
		fail += 1

	for k in GLUE_KEYS:
		if not check_sat(
			f"F2 glue key {k}",
			And(t == StringVal(k), _in_finite_set(t, GLUE_KEYS)),
		):
			fail += 1

	for label, bad in (("FOO", "FOO"), ("INX", "INX"), ("TCP", "TCP")):
		if not check_unsat(
			f"F2 glue key reject {label}",
			And(t == StringVal(bad), _in_finite_set(t, GLUE_KEYS)),
		):
			fail += 1

	return fail


def run_f2_full() -> int:
	"""F2 --full: fast suite + word-boundary Complement + glue string-ops."""
	fail = run_f2_fast()
	c = String("c")
	s = String("s")

	# Word-boundary: Length==1 Complement([A-Za-z0-9_]) — not Star(Complement).
	if not check_unsat(
		"F2 word-boundary Complement rejects A",
		And(c == StringVal("A"), _is_boundary_char(c)),
	):
		fail += 1
	if not check_unsat(
		"F2 word-boundary Complement rejects _",
		And(c == StringVal("_"), _is_boundary_char(c)),
	):
		fail += 1
	if not check_sat(
		"F2 word-boundary Complement admits .",
		And(c == StringVal("."), _is_boundary_char(c)),
	):
		fail += 1
	if not check_sat(
		"F2 word-boundary Complement admits space",
		And(c == StringVal(" "), _is_boundary_char(c)),
	):
		fail += 1

	# Concrete whole-word sat/unsat: ` DROP ` is deny-class; `XDROPY` is not.
	if not check_sat(
		"F2 word-boundary DROP flanked is deny-class",
		And(
			s == StringVal(" DROP "),
			_whole_word_at(s, "DROP"),
			_in_finite_set(StringVal("DROP"), DENY_WORDS),
		),
	):
		fail += 1
	if not check_unsat(
		"F2 word-boundary XDROPY is not whole-word DROP",
		And(s == StringVal("XDROPY"), _whole_word_at(s, "DROP")),
	):
		fail += 1

	# NETFILTER_KV_GLUE = /([^\s])(?=(IN|OUT|SRC|DST|PROTO|SPT|DPT|LEN|MAC|TYPE|CODE|TTL|TOS|PREC|DF)=)/g
	# Lookahead (?=...) has no stock-Z3 regex constructor (z3-solver==5.0.0).
	# Glue site = char immediately before KEY= via IndexOf / Contains, not ECMA lookahead.
	idx = IndexOf(s, StringVal("IN="), 0)
	if not check_sat(
		"F2 glue site char immediately before IN= (string-ops, not lookahead)",
		And(
			s == StringVal("fwlive-pingIN=lo"),
			Contains(s, StringVal("IN=")),
			idx == 11,
			SubString(s, idx - 1, 1) != StringVal(" "),
		),
	):
		fail += 1
	if not check_unsat(
		"F2 already-split IN= is not a glue site",
		And(
			s == StringVal("foo IN=lo"),
			Contains(s, StringVal("IN=")),
			SubString(s, idx - 1, 1) != StringVal(" "),
		),
	):
		fail += 1

	return fail


def run_fast() -> int:
	"""Pre-commit subset (#121); return failure count."""
	# F3–F4 stubs land in later PRs.
	return run_f1_fast() + run_f2_fast()


def run_full() -> int:
	"""CI / full suite (#121); return failure count."""
	return run_f1_full() + run_f2_full()


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
