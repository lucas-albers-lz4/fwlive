#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Host-side Z3 checks for fwlive regex / address sanitation (#120 / #121).

F1: alphabet gate for `is_resolvable_address` in rpcd/fwlive (pre-awk
`case *[ !0-9a-fA-F:.]*`). Not a full re-encoding of the awk IPv6 grammar.

F2: CLASSIFY_SPEC predicates encoded as Z3 string-ops (wordPattern
boundaries, prefix+boundary, flag-token/ws language, glue site). Not
ECMA-direct. NETFILTER_KV_GLUE lookahead is string-ops, not the lookahead
regex. Pinned for stock z3-solver==5.0.0 (default seq backend; no z3str3).

Usage:
  ./scripts/z3-verify.py --fast
  ./scripts/z3-verify.py --full
"""
from __future__ import annotations

import argparse
import sys

try:
	from z3 import And, If, Not, Or, Solver, String, StringVal, sat, unsat
	from z3 import Length, SubString, Contains, PrefixOf
	from z3 import Complement, Concat, InRe, Plus, Range, Re, Star, Union
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
# F2 enumerates upper+lower tokens (mixed-case is outside this model).
# Glue keys are exact-case in NETFILTER_KV_GLUE (not /i).
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
# Declared domain for unrolled whole-word / glue scans (not all-length).
WORD_SCAN_MAX = 24


def _alphabet_of(words) -> str:
	"""Sorted unique characters of a finite word list."""
	return "".join(sorted(set("".join(words))))


def _both_cases(words):
	"""Spec spelling plus lower/upper (JS /i; mixed-case not enumerated)."""
	out = []
	seen = set()
	for w in words:
		for v in (w, w.lower(), w.upper()):
			if v not in seen:
				seen.add(v)
				out.append(v)
	return tuple(out)


TCP_FLAG_ALPHABET = _alphabet_of(TCP_FLAG_TOKENS)
ACTION_ALPHABET = _alphabet_of(ACTION_WORDS)
GLUE_ALPHABET = _alphabet_of(GLUE_KEYS)
ACTION_WORDS_CASED = _both_cases(ACTION_WORDS)
DENY_WORDS_CASED = _both_cases(DENY_WORDS)
PREFIXES_CASED = _both_cases(NON_FIREWALL_PREFIXES)
FLAG_TOKENS_CASED = _both_cases(TCP_FLAG_TOKENS)
NON_FIREWALL_START_ALPHABET = "".join(
	sorted({p[0] for p in PREFIXES_CASED})
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


def _non_word_char_at(s, i: int):
	"""Length-1 Complement([A-Za-z0-9_]) at position i."""
	return InRe(SubString(s, i, 1), Complement(_alnum_us_re()))


def _whole_word_unrolled(s, token: str, max_len: int = WORD_SCAN_MAX):
	"""token occurs as wordPattern whole word at some index in [0, max_len).

	Domain: Length(s) ≤ max_len. Start/end of string count as boundaries;
	interior flanks are Complement([A-Za-z0-9_]) at length 1.
	"""
	tlen = len(token)
	hits = []
	for start in range(0, max_len - tlen + 1):
		end = start + tlen
		after = Or(
			Length(s) == end,
			And(Length(s) > end, _non_word_char_at(s, end)),
		)
		conds = [
			Length(s) >= end,
			Length(s) <= max_len,
			SubString(s, start, tlen) == StringVal(token),
			after,
		]
		if start > 0:
			conds.append(_non_word_char_at(s, start - 1))
		hits.append(And(*conds))
	return Or(*hits)


def matches_action_re(s):
	"""ACTION_RE: some action word is a whole word (upper+lower; scan ≤ WORD_SCAN_MAX)."""
	return Or(*[_whole_word_unrolled(s, w) for w in ACTION_WORDS_CASED])


def matches_deny(s):
	"""DENY_ACTION: some deny-class word is a whole word (upper+lower; scan ≤ WORD_SCAN_MAX)."""
	return Or(*[_whole_word_unrolled(s, w) for w in DENY_WORDS_CASED])


def matches_nf_prefix(s):
	"""NON_FIREWALL_PREFIX: start-anchored daemon name + boundary or end (upper+lower)."""
	alts = []
	for p in PREFIXES_CASED:
		plen = len(p)
		alts.append(
			And(
				PrefixOf(StringVal(p), s),
				Or(
					Length(s) == plen,
					And(Length(s) > plen, _non_word_char_at(s, plen)),
				),
			)
		)
	return Or(*alts)


def _flag_tail_re():
	"""token (ws+ token)* ws* — whole string; ws is space/tab, not full JS \\s."""
	tok = Union(*[Re(t) for t in FLAG_TOKENS_CASED])
	ws = Union(Re(" "), Re("\t"))
	return Concat(tok, Star(Concat(Plus(ws), tok)), Star(ws))


def matches_flag_tail(s):
	"""TCP_FLAG_TAIL fragment: whole string is flag tokens separated by space/tab.

	Domain: the tail *string* (not a suffix search inside a longer log line).
	Tokens upper+lower. Separators space/tab only (not JS \\s / \\b).
	"""
	return InRe(s, _flag_tail_re())


def _is_ws_at(s, i: int):
	"""Position i is space or tab (F2 model of JS \\s)."""
	return Or(
		SubString(s, i, 1) == StringVal(" "),
		SubString(s, i, 1) == StringVal("\t"),
	)


def matches_glue(s, max_len: int = WORD_SCAN_MAX):
	"""Glue site: non-space/tab char immediately before some glueKeys+'='.

	Domain: Length(s) ≤ max_len. String-ops unrolling — not ECMA lookahead.
	JS non-whitespace class is modeled as not space and not tab.
	"""
	hits = []
	for key in GLUE_KEYS:
		needle = key + "="
		nlen = len(needle)
		for i in range(0, max_len - nlen):
			hits.append(
				And(
					Length(s) >= i + 1 + nlen,
					Length(s) <= max_len,
					Not(_is_ws_at(s, i)),
					SubString(s, i + 1, nlen) == StringVal(needle),
				)
			)
	return Or(*hits)


def _lit(s, pred, literal: str):
	"""Bind s to a concrete literal and assert pred(s)."""
	return And(s == StringVal(literal), pred(s))


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
	"""F2 --fast: encoded CLASSIFY_SPEC predicates on concrete / tiny domain."""
	fail = 0
	c = String("c")
	t = String("t")
	s = String("s")

	# Alphabet lemmas (length-independent disjointness — not membership tautologies).
	if not check_unsat(
		"F2 TCP_FLAG_TAIL alphabet disjoint from =/digit",
		And(
			Length(c) == 1,
			_char_in(c, 0, TCP_FLAG_ALPHABET),
			Or(c == StringVal("="), _char_in(c, 0, "0123456789")),
		),
	):
		fail += 1
	if not check_unsat(
		"F2 ACTION_RE alphabet disjoint from =/digit",
		And(
			Length(c) == 1,
			_char_in(c, 0, ACTION_ALPHABET),
			Or(c == StringVal("="), _char_in(c, 0, "0123456789")),
		),
	):
		fail += 1
	if not check_unsat(
		"F2 glue alphabet disjoint from lowercase/digit",
		And(
			Length(c) == 1,
			_char_in(c, 0, GLUE_ALPHABET),
			Or(_char_in(c, 0, "abcdefghijklmnopqrstuvwxyz"), _char_in(c, 0, "0123456789")),
		),
	):
		fail += 1
	if not check_unsat(
		"F2 DENY pin subset of ACTION_RE pin",
		And(_in_finite_set(t, DENY_WORDS), Not(_in_finite_set(t, ACTION_WORDS))),
	):
		fail += 1

	# ACTION_RE / DENY_ACTION: whole-word Or of finite alternatives.
	for name, pred, lit, expect in (
		("F2 deny whole-word DROP", matches_deny, " DROP ", True),
		("F2 deny whole-word DROP at ends", matches_deny, "DROP", True),
		("F2 deny whole-word drop (lower)", matches_deny, " drop ", True),
		("F2 deny no-over-match XDROPY", matches_deny, "XDROPY", False),
		("F2 deny excludes ACCEPT", matches_deny, "ACCEPT", False),
		("F2 ACTION_RE whole-word ACCEPT", matches_action_re, " ACCEPT ", True),
		("F2 ACTION_RE whole-word accept (lower)", matches_action_re, " accept ", True),
		("F2 ACTION_RE no-over-match XACCEPTY", matches_action_re, "XACCEPTY", False),
	):
		formula = _lit(s, pred, lit)
		ok = check_sat(name, formula) if expect else check_unsat(name, formula)
		if not ok:
			fail += 1

	# NON_FIREWALL_PREFIX: start-anchored + boundary.
	for name, lit, expect in (
		("F2 prefix dnsmasq+boundary", "dnsmasq[", True),
		("F2 prefix dnsmasq at end", "dnsmasq", True),
		("F2 prefix DNSMASQ (upper)", "DNSMASQ ", True),
		("F2 prefix no-over-match dnsmasqfoo", "dnsmasqfoo", False),
		("F2 prefix reject dollar-paren", "$(reboot)", False),
	):
		formula = _lit(s, matches_nf_prefix, lit)
		ok = check_sat(name, formula) if expect else check_unsat(name, formula)
		if not ok:
			fail += 1
	if not check_unsat(
		"F2 prefix reject dollar-paren via start alphabet",
		And(s == StringVal("$(reboot)"), _char_in(s, 0, NON_FIREWALL_START_ALPHABET)),
	):
		fail += 1

	# TCP_FLAG_TAIL: sequence of allowed tokens with whitespace.
	for name, lit, expect in (
		("F2 flag tail SYN", "SYN", True),
		("F2 flag tail SYN ACK", "SYN ACK", True),
		("F2 flag tail syn ack (lower)", "syn ack", True),
		("F2 flag tail reject SYNACK", "SYNACK", False),
		("F2 flag tail reject SYN=", "SYN=", False),
	):
		formula = _lit(s, matches_flag_tail, lit)
		ok = check_sat(name, formula) if expect else check_unsat(name, formula)
		if not ok:
			fail += 1

	# Glue: non-ws char immediately before glueKeys+'='; space/tab is not a site.
	for name, lit, expect in (
		("F2 glue site pingIN=", "fwlive-pingIN=lo", True),
		("F2 glue site xOUT=", "xOUT=eth0", True),
		("F2 glue space-before IN= is not a site", "foo IN=lo", False),
		("F2 glue tab-before OUT= is not a site", "foo\tOUT=x", False),
	):
		formula = _lit(s, matches_glue, lit)
		ok = check_sat(name, formula) if expect else check_unsat(name, formula)
		if not ok:
			fail += 1

	return fail


def run_f2_full() -> int:
	"""F2 --full: fast + boundary class + mutation guards + symbolic lemmas."""
	fail = run_f2_fast()
	c = String("c")
	s = String("s")

	# Length==1 Complement([A-Za-z0-9_]) — not Star(Complement).
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

	# Mutation guards: weaken a boundary → sat flips to unsat.
	for name, pred, good, bad in (
		("deny trailing alnum", matches_deny, " DROP ", " DROPx"),
		("deny leading alnum", matches_deny, " DROP ", "xDROP "),
		("deny trailing underscore", matches_deny, " DROP ", " DROP_"),
		("deny lower embed", matches_deny, " drop ", "xdropy"),
		("action trailing alnum", matches_action_re, " ACCEPT ", "XACCEPTY"),
		("prefix continue alnum", matches_nf_prefix, "dnsmasq[", "dnsmasqfoo"),
		("prefix not start-anchored", matches_nf_prefix, "dnsmasq[", "xdnsmasq["),
		("flag missing ws", matches_flag_tail, "SYN ACK", "SYNACK"),
		("flag trailing alnum", matches_flag_tail, "SYN ACK", "SYN ACKX"),
		("glue insert space", matches_glue, "fwlive-pingIN=lo", "fwlive-ping IN=lo"),
		("glue DST space-before", matches_glue, "xDST=1", " DST=1"),
		("glue PROTO space-before", matches_glue, "aPROTO=tcp", " PROTO=tcp"),
	):
		if not check_sat(f"F2 mutate {name} (base sat)", _lit(s, pred, good)):
			fail += 1
		if not check_unsat(f"F2 mutate {name} (weakened unsat)", _lit(s, pred, bad)):
			fail += 1

	# Later whole-word still matches (unroll is not first-hit-only).
	if not check_sat(
		"F2 deny XDROPY DROP still whole-word",
		_lit(s, matches_deny, "XDROPY DROP"),
	):
		fail += 1

	# Symbolic no-over-match: 6-char alnum containing DROP but not equal DROP.
	if not check_unsat(
		"F2 deny no-over-match embedded DROP in alnum len 6",
		And(
			Length(s) == 6,
			Contains(s, StringVal("DROP")),
			s != StringVal("DROP"),
			*[_char_in(s, i, ALNUM_US) for i in range(6)],
			matches_deny(s),
		),
	):
		fail += 1

	# deny-class match implies ACTION_RE match (cased pins; scan ≤ 12).
	if not check_unsat(
		"F2 deny implies ACTION_RE (len ≤ 12)",
		And(Length(s) >= 1, Length(s) <= 12, matches_deny(s), Not(matches_action_re(s))),
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
