#!/usr/bin/env bash
# Regression pin for SPDX + .pot fail-closed gates (#444 / #445).
# Exercises scripts/lib/fwlive-spdx-pot-gates.sh against a temp copy of the
# package tree so CI still fails if the real tree stays valid but a branch
# (missing/empty .pot, missing header, htdocs non-js/css) is dropped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/fwlive-spdx-pot-gates.sh
source "$ROOT/scripts/lib/fwlive-spdx-pot-gates.sh"

PKG="$ROOT/openwrt-feed/luci-app-fwlive"
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

clone_pkg() {
	local dest="$1"
	rm -rf "$dest"
	cp -a "$PKG" "$dest"
}

# Real tree must still pass, and every current htdocs js/css file must be walked.
if fwlive_spdx_check_pkg "$PKG"; then
	ok "real tree SPDX"
else
	bad "unmodified package SPDX must pass"
fi
if fwlive_pot_check_pkg "$PKG"; then
	ok "real tree .pot"
else
	bad "unmodified package .pot must pass"
fi

list="$(fwlive_spdx_list_shipped "$PKG")"
js_css=0
while IFS= read -r -d '' f; do
	js_css=$((js_css + 1))
	if printf '%s\n' "$list" | grep -Fxq "$f"; then
		ok "htdocs walk includes ${f#"$PKG/"}"
	else
		bad "htdocs walk missed ${f#"$PKG/"}"
	fi
done < <(find "$PKG/htdocs" -type f \( -name '*.js' -o -name '*.css' \) -print0)
if [[ "$js_css" -lt 1 ]]; then
	bad "expected js/css under htdocs"
fi
if printf '%s\n' "$list" | grep -E '\.(md|json)$' >/dev/null; then
	bad "walk must skip *.md and *.json"
else
	ok "walk skips *.md and *.json"
fi

# missing .pot
clone_pkg "$TMP/missing-pot"
rm -f "$TMP/missing-pot/po/templates/luci-app-fwlive.pot"
err="$TMP/missing-pot.err"
if fwlive_pot_check_pkg "$TMP/missing-pot" >"$TMP/missing-pot.out" 2>"$err"; then
	bad "missing .pot must fail"
else
	ok "missing .pot fails closed"
fi
grep -q 'missing or unreadable .pot template' "$err" \
	&& ok "missing .pot: clear error" \
	|| bad "missing .pot: expected missing/unreadable error"

# empty .pot
clone_pkg "$TMP/empty-pot"
: >"$TMP/empty-pot/po/templates/luci-app-fwlive.pot"
err="$TMP/empty-pot.err"
if fwlive_pot_check_pkg "$TMP/empty-pot" >"$TMP/empty-pot.out" 2>"$err"; then
	bad "empty .pot must fail"
else
	ok "empty .pot fails closed"
fi
grep -q 'empty .pot template' "$err" \
	&& ok "empty .pot: clear error" \
	|| bad "empty .pot: expected empty error"

# absolute #: (keep existing grep behavior)
clone_pkg "$TMP/abs-pot"
printf '%s\n' '#: /tmp/fwlive-abs-probe.js:1' \
	>>"$TMP/abs-pot/po/templates/luci-app-fwlive.pot"
err="$TMP/abs-pot.err"
if fwlive_pot_check_pkg "$TMP/abs-pot" >"$TMP/abs-pot.out" 2>"$err"; then
	bad "absolute #: must fail"
else
	ok "absolute #: fails closed"
fi
grep -q 'absolute #:' "$err" \
	&& ok "absolute #: clear error" \
	|| bad "absolute #: expected error"

# new root/ file without SPDX
clone_pkg "$TMP/root-no-spdx"
printf '%s\n' '#!/bin/sh' 'echo planted' \
	>"$TMP/root-no-spdx/root/usr/libexec/fwlive-no-spdx-probe.sh"
err="$TMP/root-no-spdx.err"
if fwlive_spdx_check_pkg "$TMP/root-no-spdx" >"$TMP/root-no-spdx.out" 2>"$err"; then
	bad "root/ file without SPDX must fail"
else
	ok "root/ file without SPDX fails closed"
fi
grep -q 'fwlive-no-spdx-probe.sh' "$err" \
	&& ok "root/ missing header names the file" \
	|| bad "root/ missing header should name fwlive-no-spdx-probe.sh"

# htdocs css without SPDX
clone_pkg "$TMP/css-no-spdx"
css="$TMP/css-no-spdx/htdocs/luci-static/resources/fwlive/fwlive.css"
sed -i '1d' "$css"
err="$TMP/css-no-spdx.err"
if fwlive_spdx_check_pkg "$TMP/css-no-spdx" >"$TMP/css-no-spdx.out" 2>"$err"; then
	bad "fwlive.css without SPDX must fail"
else
	ok "fwlive.css without SPDX fails closed"
fi
grep -q 'fwlive.css' "$err" \
	&& ok "htdocs css missing header names fwlive.css" \
	|| bad "htdocs css missing header should name fwlive.css"

# new non-js/css/md/json under htdocs/ without SPDX (finding 1)
clone_pkg "$TMP/html-no-spdx"
html="$TMP/html-no-spdx/htdocs/luci-static/resources/fwlive/probe.html"
printf '%s\n' '<!doctype html>' '<title>spdx probe</title>' >"$html"
err="$TMP/html-no-spdx.err"
if fwlive_spdx_check_pkg "$TMP/html-no-spdx" >"$TMP/html-no-spdx.out" 2>"$err"; then
	bad "htdocs .html without SPDX must fail"
else
	ok "htdocs .html without SPDX fails closed"
fi
grep -q 'probe.html' "$err" \
	&& ok "htdocs html missing header names probe.html" \
	|| bad "htdocs html missing header should name probe.html"

# JSON under htdocs stays skipped (ACL/menu stay strict JSON)
clone_pkg "$TMP/json-skip"
printf '%s\n' '{"probe": true}' \
	>"$TMP/json-skip/htdocs/luci-static/resources/fwlive/probe.json"
if fwlive_spdx_check_pkg "$TMP/json-skip"; then
	ok "htdocs *.json without SPDX is skipped"
else
	bad "htdocs *.json must stay skipped like root/"
fi

if [[ "$fail" -ne 0 ]]; then
	echo "FAIL: SPDX/.pot fail-closed regression" >&2
	exit 1
fi
echo "ok: SPDX/.pot fail-closed gates"
