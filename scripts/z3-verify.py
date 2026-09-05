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

F5: normalize_log_prefix idempotency (P1) + fixpoint (P2) over a bounded
domain, with a quantifier-weaken guard replaying the 2026-08 regression.
P3 (client parity) lives in #254, not here.

Usage:
  ./scripts/z3-verify.py --fast
  ./scripts/z3-verify.py --full
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IS_FW = ROOT / (
	"openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.sh"
)
GEN_SHELL = ROOT / "scripts/gen-shell-classifier.js"
RPCD = ROOT / "openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive"
ROBUSTNESS_JS = ROOT / "scripts/z3-robustness.js"

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
# Printable corpus alphabet for Z3 sat-models (argv/env safe; reproducible).
SAMPLE_ALPHABET = (
	"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	"_-.:=[] \t"
)
# Fixed `/i` mixed-case lines — outside Z3 finite-token model; F3 differential parity.
MIXED_CASE_PARITY_CORPUS = (
	"aCcEpT IN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP",
	"DrOp IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP DPT=22",
	"sYn ACK",
	"dnsMasq[1]: query noise",
	"fw4: aCcEpT without key values",
)


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


GLUE_ALPHABET = _alphabet_of(GLUE_KEYS)
ACTION_WORDS_CASED = _both_cases(ACTION_WORDS)
DENY_WORDS_CASED = _both_cases(DENY_WORDS)
PREFIXES_CASED = _both_cases(NON_FIREWALL_PREFIXES)
FLAG_TOKENS_CASED = _both_cases(TCP_FLAG_TOKENS)
TCP_FLAG_ALPHABET_CASED = _alphabet_of(FLAG_TOKENS_CASED)
ACTION_ALPHABET_CASED = _alphabet_of(ACTION_WORDS_CASED)
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
	# Unsat must come from the predicate, not from the scan bound.
	assert len(literal) <= WORD_SCAN_MAX, (
		f"literal {literal!r} exceeds WORD_SCAN_MAX={WORD_SCAN_MAX}; "
		"unsat would be vacuous"
	)
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
			_char_in(c, 0, TCP_FLAG_ALPHABET_CASED),
			Or(c == StringVal("="), _char_in(c, 0, "0123456789")),
		),
	):
		fail += 1
	if not check_unsat(
		"F2 ACTION_RE alphabet disjoint from =/digit",
		And(
			Length(c) == 1,
			_char_in(c, 0, ACTION_ALPHABET_CASED),
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
		And(
			_in_finite_set(t, DENY_WORDS_CASED),
			Not(_in_finite_set(t, ACTION_WORDS_CASED)),
		),
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


def _run_node(args: list[str], label: str) -> bool:
	"""Run node with args; print ok/FAIL."""
	try:
		out = subprocess.run(["node", *args], cwd=ROOT, capture_output=True, text=True)
	except FileNotFoundError:
		print(f"FAIL: {label} — node not found in PATH", file=sys.stderr)
		return False
	if out.returncode == 0:
		print(f"ok: {label}")
		return True
	print(f"FAIL: {label} — {out.stderr or out.stdout}", file=sys.stderr)
	return False


def _js_is_firewall(msg: str) -> bool:
	"""Node core.isFirewallEvent for a raw message string."""
	code = (
		"const c=require('./core/fwlive-log.js');"
		"const m=process.argv[1];"
		"process.stdout.write(c.isFirewallEvent({msg:m})?'yes':'no');"
	)
	out = subprocess.run(
		["node", "-e", code, msg],
		cwd=ROOT,
		capture_output=True,
		text=True,
	)
	if out.returncode != 0:
		raise RuntimeError(out.stderr or out.stdout)
	return out.stdout.strip() == "yes"


def _shell_is_firewall(msg: str, sh: str = "sh") -> bool:
	"""Generated shell classifier parity for msg."""
	parts = sh.split()
	cmd = parts[0]
	prefix = parts[1:]
	script = (
		'. "$IS_FW" || exit 3; '
		'command -v is_firewall_event_msg >/dev/null 2>&1 || exit 4; '
		'if is_firewall_event_msg "$FW_MSG"; then echo yes; else echo no; fi'
	)
	out = subprocess.run(
		[cmd, *prefix, "-c", script],
		cwd=ROOT,
		capture_output=True,
		text=True,
		env={**os.environ, "FW_MSG": msg, "IS_FW": str(IS_FW)},
	)
	if out.returncode != 0:
		raise RuntimeError(out.stderr or out.stdout)
	return out.stdout.strip() == "yes"


def _z3_model_string(sol, var) -> str:
	"""Extract a concrete string from a Z3 String model variable."""
	val = sol.model().eval(var, model_completion=True)
	raw = val.as_string()
	if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
		return raw[1:-1]
	return raw


def _z3_sat_samples(pred, max_len: int = WORD_SCAN_MAX, n: int = 3) -> list[str]:
	"""Collect up to n distinct sat models for pred(String s)."""
	s = String("s")
	samples: list[str] = []
	for _ in range(n):
		sol = Solver()
		sol.add(pred(s))
		sol.add(Length(s) >= 1, Length(s) <= max_len)
		# Keep models printable: argv/env cannot carry NUL; unconstrained flanks
		# admit arbitrary control characters and make the corpus nondeterministic.
		for i in range(max_len):
			sol.add(If(Length(s) > i, _char_in(s, i, SAMPLE_ALPHABET), True))
		for prev in samples:
			sol.add(s != StringVal(prev))
		r = sol.check()
		if r != sat:
			break
		samples.append(_z3_model_string(sol, s))
	return samples


def _z3_adversarial_corpus() -> list[str]:
	"""Z3-generated strings around F2 predicates for parity fuzz (#199)."""
	corpus: list[str] = []

	# Predicate-shaped samples from sat models.
	corpus.extend(_z3_sat_samples(matches_deny, n=4))
	corpus.extend(_z3_sat_samples(matches_action_re, n=4))
	corpus.extend(_z3_sat_samples(matches_nf_prefix, n=3))
	corpus.extend(_z3_sat_samples(matches_glue, n=3))
	corpus.extend(_z3_sat_samples(matches_flag_tail, n=3))

	# Fixed boundary / glue / metachar lines (parity stress).
	corpus.extend(
		[
			" DROP ",
			"XDROPY DROP",
			"fwlive-pingIN=lo OUT= SRC=127.0.0.1 DST=127.0.0.1 PROTO=ICMP",
			"dnsmasq[123]: query",
			"dnsmasqfoo: IN=wan OUT= SRC=1.2.3.4",
			"$(reboot); IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP",
			"IN=wan OUT= SRC= DST=2001:db8::2 PROTO=TCP",
			"fw4rejectIN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP",
			"x DST= DROP",
			"SYN ACK",
			"not-a-firewall-line at all",
		]
	)
	corpus.extend(MIXED_CASE_PARITY_CORPUS)

	# Dedupe preserving order.
	seen: set[str] = set()
	out: list[str] = []
	for item in corpus:
		if item not in seen:
			seen.add(item)
			out.append(item)
	return out


def run_f3_fast() -> int:
	"""F3 --fast: codegen drift guard (byte identity vs gen-shell-classifier)."""
	fail = 0
	if not GEN_SHELL.is_file() or not IS_FW.is_file():
		print("FAIL: F3 missing codegen paths", file=sys.stderr)
		return 1
	out = None
	try:
		out = subprocess.run(
			["node", str(GEN_SHELL)],
			cwd=ROOT,
			capture_output=True,
			text=True,
		)
	except FileNotFoundError:
		print("FAIL: F3 codegen generator — node not found in PATH", file=sys.stderr)
		return 1
	if out.returncode != 0:
		print(f"FAIL: F3 codegen generator — {out.stderr or out.stdout}", file=sys.stderr)
		fail += 1
	elif out.stdout != IS_FW.read_text(encoding="utf-8"):
		print(
			"FAIL: F3 codegen drift — fwlive-is-firewall-event.sh stale (run ./scripts/gen-all.sh)",
			file=sys.stderr,
		)
		fail += 1
	else:
		print("ok: F3 codegen drift guard")
	return fail


def run_f3_full() -> int:
	"""F3 --full: Z3 corpus through JS↔shell parity (sh + busybox sh)."""
	fail = run_f3_fast()
	try:
		corpus = _z3_adversarial_corpus()
		print(f"ok: F3 mixed-case parity block queued ({len(MIXED_CASE_PARITY_CORPUS)} lines)")
	except Exception as exc:  # pragma: no cover
		print(f"FAIL: F3 corpus generation — {exc}", file=sys.stderr)
		return fail + 1

	shells = ["sh"]
	if subprocess.run(["sh", "-c", "command -v busybox"], capture_output=True).returncode == 0:
		shells.append("busybox sh")
	else:
		print("F3: busybox not found — sh-only parity (install busybox for full ash)", file=sys.stderr)

	for msg in corpus:
		try:
			js = _js_is_firewall(msg)
		except Exception as exc:
			print(f"FAIL: F3 JS classify — {exc!r} for {msg!r}", file=sys.stderr)
			fail += 1
			continue
		for sh in shells:
			try:
				shell = _shell_is_firewall(msg, sh)
			except Exception as exc:
				print(f"FAIL: F3 shell classify ({sh}) — {exc!r} for {msg!r}", file=sys.stderr)
				fail += 1
				continue
			if js != shell:
				print(
					f"FAIL: F3 parity mismatch ({sh}) js={js} shell={shell} msg={msg!r}",
					file=sys.stderr,
				)
				fail += 1
			else:
				print(f"ok: F3 parity ({sh}) {msg[:48]!r}{'…' if len(msg) > 48 else ''}")

	if fail == 0:
		print(f"ok: F3 parity corpus ({len(corpus)} msgs, shells={shells})")
	return fail


# ---------------------------------------------------------------------------
# F5: normalize_log_prefix idempotency (#275).
# The shipped shell (rpcd/fwlive) strips trailing spaces/tabs/colons with
# sed 's/[[:space:]:]*$//'. P1 proves idempotency, P2 proves the fixpoint;
# the quantifier-weaken guard replays the exact 2026-08 regression
# (commit ed4486829c: '*' -> '?' strips one char per pass, so 'zz::'
# drifts across passes) and must flip P1/P2 to SAT. P3 (client-parity
# data-flow into parseRuleHint) is out of scope here — see #254.
# Domain: strings up to F5_MAX_LEN over content + strip chars. Proofs are
# valid up to this length (not length-independent); real prefixes are short.
# ---------------------------------------------------------------------------
F5_SHIPPED_SED = "sed 's/[[:space:]:]*$//'"
F5_STRIP_CHARS = (" ", "	", ":")
F5_CONTENT_CHARS = "abZ019_.-"
F5_MAX_LEN = 8
F5_GROUND_CORPUS = (
	"zz::",
	"zz:",
	"zz",
	"a: :",
	"a ",
	"tab	here:",
	":::",
	":",
	"",
	"a:b",
	"a b",
	"mix :	 :",
	"fwlive-ssh ",
)


def _f5_alphabet() -> str:
	return F5_CONTENT_CHARS + "".join(F5_STRIP_CHARS)


def _f5_is_strip_char(c):
	"""Z3 predicate: single character c is a trailing-strip character."""
	return Or(*[c == StringVal(x) for x in F5_STRIP_CHARS])


def _f5_strip_star(s, depth: int = F5_MAX_LEN):
	"""Z3 model of the shipped '*' form: strip ALL trailing strip-chars."""
	cur = s
	for _ in range(depth):
		last = SubString(cur, Length(cur) - 1, 1)
		cur = If(
			And(Length(cur) > 0, _f5_is_strip_char(last)),
			SubString(cur, 0, Length(cur) - 1),
			cur,
		)
	return cur


def _f5_strip_once(s):
	"""Z3 model of the weakened '?' form: strip at most ONE trailing char."""
	last = SubString(s, Length(s) - 1, 1)
	return If(
		And(Length(s) > 0, _f5_is_strip_char(last)),
		SubString(s, 0, Length(s) - 1),
		s,
	)


def _f5_domain(s):
	"""Z3 predicate: s is in the bounded proof domain."""
	n = Length(s)
	conds = [n >= 0, n <= F5_MAX_LEN]
	for i in range(F5_MAX_LEN):
		conds.append(If(n > i, _char_in(s, i, _f5_alphabet()), True))
	return And(*conds)


def _f5_extract_normalize_log_prefix(body: str):
	"""Return the normalize_log_prefix() body via brace-depth, or None."""
	lines = body.splitlines()
	start = next(
		(i for i, ln in enumerate(lines) if ln == "normalize_log_prefix() {"),
		None,
	)
	if start is None:
		return None
	depth = 0
	end = None
	for i in range(start, len(lines)):
		depth += lines[i].count("{") - lines[i].count("}")
		if i > start and depth == 0:
			end = i
			break
	if end is None:
		return None
	return "\n".join(lines[start : end + 1])


def _f5_shipped_text_ok() -> bool:
	"""The proof means nothing if the shell no longer carries the '*' form."""
	if not RPCD.is_file():
		print("FAIL: F5 missing rpcd path", file=sys.stderr)
		return False
	body = RPCD.read_text(encoding="utf-8", errors="replace")
	func = _f5_extract_normalize_log_prefix(body)
	if func is None:
		print("FAIL: F5 normalize_log_prefix not found", file=sys.stderr)
		return False
	# Pin the sed form inside the extracted body so a leftover comment or a
	# later nested `}` elsewhere cannot keep Z3 on `*` while shell replay
	# runs different text.
	if F5_SHIPPED_SED not in func:
		print(
			"FAIL: F5 shipped sed form changed — re-verify P1/P2",
			file=sys.stderr,
		)
		return False
	print("ok: F5 shipped sed form present")
	return True


def _f5_shell_ground_truth() -> bool:
	"""Run the shipped function twice over a tricky corpus: f(f(x)) == f(x)."""
	if not RPCD.is_file():
		print("FAIL: F5 missing rpcd path", file=sys.stderr)
		return False
	body = RPCD.read_text(encoding="utf-8", errors="replace")
	func = _f5_extract_normalize_log_prefix(body)
	if func is None:
		print("FAIL: F5 normalize_log_prefix not found or unterminated", file=sys.stderr)
		return False
	prog = (
		func
		+ '\nfor x in "$@"; do\n'
		+ '  one=$(normalize_log_prefix "$x");\n'
		+ '  two=$(normalize_log_prefix "$one");\n'
		+ '  printf "%s\\n" "$one";\n'
		+ '  printf "%s\\n" "$two";\n'
		+ "done\n"
	)
	out = subprocess.run(
		["sh", "-c", prog, "f5", *F5_GROUND_CORPUS],
		cwd=ROOT,
		capture_output=True,
		text=True,
	)
	if out.returncode != 0:
		print(f"FAIL: F5 shell replay — {out.stderr.strip()}", file=sys.stderr)
		return False
	outs = out.stdout.split("\n")
	outs = outs[: len(F5_GROUND_CORPUS) * 2]
	for i, x in enumerate(F5_GROUND_CORPUS):
		one, two = outs[2 * i], outs[2 * i + 1]
		if one != two:
			print(
				f"FAIL: F5 not idempotent on {x!r}: {one!r} -> {two!r}",
				file=sys.stderr,
			)
			return False
		if one != "" and one[-1] in (" ", "	", ":"):
			print(
				f"FAIL: F5 fixpoint violated on {x!r}: {one!r}",
				file=sys.stderr,
			)
			return False
	print(f"ok: F5 shell ground truth ({len(F5_GROUND_CORPUS)} inputs)")
	return True


def run_f5_fast() -> int:
	"""F5 --fast: shipped-text pin + P1/P2 proofs + weaken guard."""
	fail = 0
	if not _f5_shipped_text_ok():
		return 1
	s = String("f5s")
	if not check_unsat(
		"F5 P1 idempotency",
		And(_f5_domain(s), _f5_strip_star(_f5_strip_star(s)) != _f5_strip_star(s)),
	):
		fail += 1
	t = _f5_strip_star(s)
	last = SubString(t, Length(t) - 1, 1)
	if not check_unsat(
		"F5 P2 fixpoint",
		And(_f5_domain(s), Length(t) > 0, _f5_is_strip_char(last)),
	):
		fail += 1
	# Negative control: the '?' form must violate both (2026-08 replay).
	w = String("f5w")
	if not check_sat(
		"F5 guard quantifier-weaken flips P1",
		And(_f5_domain(w), _f5_strip_once(_f5_strip_once(w)) != _f5_strip_once(w)),
	):
		fail += 1
	u = _f5_strip_once(w)
	ulast = SubString(u, Length(u) - 1, 1)
	if not check_sat(
		"F5 guard quantifier-weaken flips P2",
		And(_f5_domain(w), Length(u) > 0, _f5_is_strip_char(ulast)),
	):
		fail += 1
	return fail


def run_f5_full() -> int:
	"""F5 --full: fast suite + shell ground-truth replay."""
	fail = run_f5_fast()
	if not _f5_shell_ground_truth():
		fail += 1
	return fail


def run_f4_fast() -> int:
	"""F4 --fast: malformed-input no-crash (normalize/classify corpus)."""
	fail = 0
	if not _run_node([str(ROBUSTNESS_JS), "--fast"], "F4 robustness --fast"):
		fail += 1
	return fail


def run_f4_full() -> int:
	"""F4 --full: expanded corpus + rpcd __selftest (sed extractions)."""
	fail = run_f4_fast()
	if not _run_node([str(ROBUSTNESS_JS), "--full"], "F4 robustness --full"):
		fail += 1
	if RPCD.is_file():
		out = subprocess.run(["sh", str(RPCD), "__selftest"], cwd=ROOT, capture_output=True, text=True)
		if out.returncode != 0:
			print(f"FAIL: F4 rpcd __selftest — {out.stderr or out.stdout}", file=sys.stderr)
			fail += 1
		else:
			print("ok: F4 rpcd __selftest")
	else:
		print("FAIL: F4 missing rpcd path", file=sys.stderr)
		fail += 1
	return fail


def run_fast() -> int:
	"""Pre-commit subset (#121); return failure count."""
	return run_f1_fast() + run_f2_fast() + run_f3_fast() + run_f4_fast() + run_f5_fast()


def run_full() -> int:
	"""CI / full suite (#121); return failure count."""
	return run_f1_full() + run_f2_full() + run_f3_full() + run_f4_full() + run_f5_full()


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
