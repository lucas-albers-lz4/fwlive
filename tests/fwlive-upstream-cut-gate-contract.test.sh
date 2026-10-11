#!/usr/bin/env bash
# Contract characterisation for the upstream-cut artifact gates.
#
# scripts/upstream-cut.sh refuses to export an artifact that leaks monorepo
# references, internal tracker ids, dangling README rows, non-luci .pot refs or
# symlinks. That gate has been reworked three times (#1180, #1185-#1187, #1192).
# This test pins the contract as a fixture matrix, so a later rework cannot
# silently weaken it.
#
# Two directions carry equal weight:
#   * a legitimate shipped input PASSES  (a gate that rejects valid input breaks the release)
#   * a leak class FAILS                 (a gate that accepts a leak defeats its purpose)
#
# Every fixture is built from the real shipped files: the base tree carries the
# actual css.js and tint.js, so the colour-context rule is exercised against the
# files it was written for. Mutations are appended, never applied to a palette
# literal, so a legitimate recolour cannot turn this test red.
#
# Known remaining exception tracked for follow-up and NOT asserted here:
#   * any --custom-property fallback is exempted, not only --fwlive-* (#1208)
#
# Scope: the gate functions, driven against a minimal clean artifact tree. The
# end-to-end run (real subtree split, real rewrites, real git refs) stays in
# tests/fwlive-upstream-cut.test.sh. This test is hermetic: no network, no
# node_modules, no git refs.
#
# Run:  bash tests/fwlive-upstream-cut-gate-contract.test.sh
#       bash tests/fwlive-upstream-cut-gate-contract.test.sh --capture   (print observed rc only)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/scripts/upstream-cut.sh"
PKG="$ROOT/openwrt-feed/luci-app-fwlive"
JS=htdocs/luci-static/resources/fwlive
CAPTURE=0
[ "${1:-}" = "--capture" ] && CAPTURE=1

WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# ---- extract the gate implementations from the live script (survives line drift) ----
# Each fragment must carry a signature unique to that gate, so a truncated or
# wrong extraction fails closed instead of quietly passing every case.
extract_py() { # $1 = function name
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\)" { inb=1 }
    inb && /<<.PY./ { py=1; next }
    py && /^PY$/ { exit }
    py { print }
  ' "$SRC" > "$WORK/bin/$1.py"
  [ -s "$WORK/bin/$1.py" ] || { echo "FATAL: cannot extract $1 from $SRC" >&2; exit 2; }
  local want
  case "$1" in
    upstream_cut_verify_readme_rows) want='path_row_cells' ;;
    upstream_cut_verify_artifacts)   want='color_spans' ;;
    upstream_cut_verify_pot_refs)    want='luci-shaped' ;;
  esac
  grep -q "$want" "$WORK/bin/$1.py" || { echo "FATAL: $1 extraction is not the expected body (missing $want)" >&2; exit 2; }
}
extract_py upstream_cut_verify_readme_rows
extract_py upstream_cut_verify_artifacts
extract_py upstream_cut_verify_pot_refs
awk '/^upstream_cut_verify_no_symlinks\(\)/,/^}/' "$SRC" > "$WORK/bin/no_symlinks.sh"
[ -s "$WORK/bin/no_symlinks.sh" ] || { echo "FATAL: cannot extract no_symlinks" >&2; exit 2; }

# A gate that is never invoked passes every fixture. Assert the wiring, so a
# dead-gate edit fails here instead of silently disarming the export.
for fn in upstream_cut_verify_readme_rows upstream_cut_verify_artifacts upstream_cut_verify_pot_refs; do
  grep -qE "^if ! ${fn} \"\\\$OUT\"" "$SRC" || { echo "FATAL: $fn is not wired into the cut" >&2; exit 2; }
done
grep -qE 'upstream_cut_verify_no_symlinks "\$OUT"' "$SRC" || { echo "FATAL: no_symlinks is not wired into the cut" >&2; exit 2; }

# Execute the live fail branches and final guard with gates forced to fail.
# This protects both invocation wiring and the production accumulator/exit path,
# not merely the gate functions' direct return codes above.
extract_failure_block() {
  local fn="$1"
  awk -v fn="$fn" '
    {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      if (!inside && index(line, "if ! " fn " ") == 1) {
        inside=1
        found=1
      }
      if (inside) {
        print
        if (line == "fi") {
          closed=1
          exit
        }
      }
    }
    END { if (!found || !closed) exit 1 }
  ' "$SRC" >"$WORK/bin/$fn.failure.sh" \
    || { echo "FATAL: cannot extract active failure block for $fn" >&2; exit 2; }
}
awk '
  {
    line=$0
    sub(/^[[:space:]]*/, "", line)
    if (!inside && line ~ /^if \[ "\$fail" -ne 0 \]; then$/) {
      inside=1
      found=1
    }
    if (inside) {
      print
      if (line == "fi") {
        closed=1
        exit
      }
    }
  }
  END { if (!found || !closed) exit 1 }
' "$SRC" >"$WORK/bin/final-failure-guard.sh" \
  || { echo "FATAL: cannot extract final failure guard" >&2; exit 2; }

for fn in upstream_cut_verify_readme_rows upstream_cut_verify_artifacts upstream_cut_verify_pot_refs; do
  extract_failure_block "$fn"
  marker="$WORK/$fn.failure-survived"
  rm -f "$marker"
  (
    set -euo pipefail
    # These values are consumed by source fragments extracted from the live script.
    # shellcheck disable=SC2034
    fail=0
    # shellcheck disable=SC2034
    OUT="$WORK/out"
    # shellcheck disable=SC2034
    PKG="$PKG"
    eval "$fn() { return 1; }"
    # shellcheck disable=SC1090
    source "$WORK/bin/$fn.failure.sh"
    # shellcheck disable=SC1090
    source "$WORK/bin/final-failure-guard.sh"
    : >"$marker"
  ) >"$WORK/$fn.failure.log" 2>&1
  rc=$?
  [ "$rc" -eq 1 ] && [ ! -e "$marker" ] \
    && grep -Fq -- 'Upstream cut FAILED — fix the checks above.' "$WORK/$fn.failure.log" \
    || { echo "FATAL: $fn failure did not reach the cut's final exit guard" >&2; exit 2; }
done

# The symlink guard lives inside the rewrite function and relies on errexit at
# the active top-level call. Check that wiring and make a forced failure abort.
awk '/^upstream_cut_guarded_rewrite\(\)/,/^}/' "$SRC" \
  >"$WORK/bin/guarded-rewrite.sh"
[ -s "$WORK/bin/guarded-rewrite.sh" ] \
  || { echo "FATAL: cannot extract guarded rewrite" >&2; exit 2; }
grep -qE '^set -euo pipefail$' "$SRC" \
  || { echo "FATAL: upstream-cut no longer enables errexit" >&2; exit 2; }
grep -qE '^[[:space:]]*if ! upstream_cut_verify_no_symlinks "\$OUT"; then$' "$SRC" \
  || { echo "FATAL: symlink guard is not an active rewrite failure check" >&2; exit 2; }
grep -qE '^upstream_cut_guarded_rewrite "\$OUT"$' "$SRC" \
  || { echo "FATAL: guarded rewrite is not an active top-level call" >&2; exit 2; }
marker="$WORK/symlink-failure-survived"
rm -f "$marker"
(
  set -euo pipefail
  upstream_cut_verify_no_symlinks() { return 1; }
  # shellcheck disable=SC1090
  source "$WORK/bin/guarded-rewrite.sh"
  upstream_cut_guarded_rewrite "$WORK/out"
  : >"$marker"
) >"$WORK/no-symlink-failure.log" 2>&1
rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$marker" ] \
  && grep -Fq -- 'Upstream cut FAILED — remove symlinks from the package tree before rewriting.' "$WORK/no-symlink-failure.log" \
  || { echo "FATAL: no_symlinks failure did not abort the rewrite" >&2; exit 2; }
echo "gate wiring and failure propagation checks passed"

# ---- base fixture: minimal clean artifact + the real style carriers ----
build_base() {
  local d="$WORK/out"
  rm -rf "$d"; mkdir -p "$d/$JS" "$d/root" "$d/po/templates"
  cat > "$d/README.md" <<'EOF'
# luci-app-fwlive

| Path | Role |
| --- | --- |
| `root/x.sh` | Helper |
EOF
  printf '#!/bin/sh\ntrue\n' > "$d/root/x.sh"
  cat > "$d/po/templates/luci-app-fwlive.pot" <<'EOF'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"

#: applications/luci-app-fwlive/root/x.sh:1
msgid "Helper"
msgstr ""
EOF
  # Real carriers: the colour exemption is written for these exact files.
  cp "$PKG/$JS/css.js"  "$d/$JS/css.js"
  cp "$PKG/$JS/tint.js" "$d/$JS/tint.js"
  # The export rewrites the generated-source banner before the gates run (script step 3).
  sed -i 's|^ \* GENERATED — [Dd][Oo] [Nn][Oo][Tt] [Ee][Dd][Ii][Tt]\. Edit fwlive\.css and run: node scripts/embed-fwlive-css\.js$| * Generated stylesheet snapshot.|' "$d/$JS/css.js"
}

m() { # m <name> -> path to a mutable copy of the base
  local n="$1"; rm -rf "$WORK/${n:?}"; cp -a "$WORK/out" "$WORK/$n"; printf '%s' "$WORK/$n"
}

# ---- case driver ----
PASS=0; FAIL=0; FAILED_NAMES=()
check() { # name expected_rc cmd...
  local name="$1" want="$2"; shift 2
  "$@" >"$WORK/last.out" 2>&1; local got=$?
  if [ "$CAPTURE" -eq 1 ]; then printf '  %-24s rc=%s\n' "$name" "$got"; return 0; fi
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS+1)); printf '  ok   %-24s rc=%s\n' "$name" "$got"
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$name")
    printf '  FAIL %-24s rc=%s want=%s\n' "$name" "$got" "$want"
    sed 's/^/         | /' "$WORK/last.out" | head -3
  fi
}
check_diag() { # name expected_rc expected_diagnostic cmd...
  local name="$1" want="$2" diagnostic="$3"; shift 3
  "$@" >"$WORK/last.out" 2>&1; local got=$?
  if [ "$CAPTURE" -eq 1 ]; then printf '  %-24s rc=%s\n' "$name" "$got"; return 0; fi
  if [ "$got" -eq "$want" ] && grep -Fq -- "$diagnostic" "$WORK/last.out"; then
    PASS=$((PASS+1)); printf '  ok   %-24s rc=%s diagnostic=%s\n' "$name" "$got" "$diagnostic"
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$name")
    printf '  FAIL %-24s rc=%s want=%s diagnostic=%s\n' "$name" "$got" "$want" "$diagnostic"
    sed 's/^/         | /' "$WORK/last.out" | head -3
  fi
}
G_readme()  { python3 "$WORK/bin/upstream_cut_verify_readme_rows.py" "$1"; }
G_art()     { python3 "$WORK/bin/upstream_cut_verify_artifacts.py" "$1"; }
G_pot()     { python3 "$WORK/bin/upstream_cut_verify_pot_refs.py" "$1" "$PKG"; }
G_symlink() { ( set +e; . "$WORK/bin/no_symlinks.sh"; upstream_cut_verify_no_symlinks "$1" ); }

# Content-dependent mutations must prove they changed the file, otherwise the case
# silently degrades into a second copy of the clean-tree case.
sed_assert() { # sed_expr file must_contain case_name
  sed -i "$1" "$2"
  grep -q -- "$3" "$2" && return 0
  FAIL=$((FAIL+1)); FAILED_NAMES+=("$4")
  printf '  FAIL %-24s fixture precondition missing: %s\n' "$4" "$3"
  return 1
}

echo "== upstream-cut gate contract =="
build_base

echo "-- README path-table gate --"
check R-ok              0 G_readme "$WORK/out"
# The #1185 shape: a valid row is already parsed, then a structural break, then
# the orphan. Deleting the orphan rule must turn both of these red.
d=$(m r-hole-blank);     printf '\n| `root/ghost.sh` | Ghost |\n' >> "$d/README.md";              check R-hole-blank      1 G_readme "$d"
d=$(m r-hole-pipeless);  printf 'prose line without a pipe\n| `root/ghost.sh` | Ghost |\n' >> "$d/README.md"; check R-hole-pipeless 1 G_readme "$d"
# A table whose only row sits below a break is caught by the parsed==0 backstop.
d=$(m r-parsed0-blank);    printf '| Path | Role |\n| --- | --- |\n\n| `root/ghost.sh` | Ghost |\n' > "$d/README.md"; check R-parsed0-blank 1 G_readme "$d"
d=$(m r-parsed0-pipeless); printf '| Path | Role |\n| --- | --- |\nprose\n| `root/ghost.sh` | Ghost |\n' > "$d/README.md"; check R-parsed0-pipeless 1 G_readme "$d"
d=$(m r-dangling);       printf '| `root/ghost.sh` | Ghost |\n' >> "$d/README.md";              check R-dangling      1 G_readme "$d"
d=$(m r-empty);          printf '| Path | Role |\n| --- | --- |\n' > "$d/README.md";            check R-empty         1 G_readme "$d"
d=$(m r-no-readme);      rm -f "$d/README.md";                                                  check R-no-readme     1 G_readme "$d"
d=$(m r-tab-row);        printf '\t| `root/ghost.sh` | Ghost |\n' >> "$d/README.md";            check R-tab-row       1 G_readme "$d"
d=$(m r-indent4);        printf '    | `root/ghost.sh` | Ghost |\n' >> "$d/README.md";          check R-indent4       1 G_readme "$d"
d=$(m r-renamed-header); sed -i 's/| Path | Role |/| Path | Purpose |/' "$d/README.md"; \
                         printf '\n| `root/ghost.sh` | Ghost |\n' >> "$d/README.md";            check R-renamed-header 1 G_readme "$d"
d=$(m r-no-delim);       printf '| Path | Role |\n| `root/x.sh` | Helper |\n' > "$d/README.md"; check_diag R-no-delim 1 'invalid delimiter row' G_readme "$d"
d=$(m r-2nd-table);      printf '\n| Path | Role |\n| --- | --- |\n| `root/ghost.sh` | Ghost |\n' >> "$d/README.md"; check R-2nd-table 1 G_readme "$d"
d=$(m r-2nd-ok);         printf '\n| Path | Role |\n| --- | --- |\n| `root/x.sh` | Helper |\n' >> "$d/README.md"; check R-2nd-ok 0 G_readme "$d"
d=$(m r-abs);            printf '| `/etc/passwd` | X |\n' >> "$d/README.md";                    check_diag R-abs 1 'absolute path outside the documented runtime allowlist' G_readme "$d"
d=$(m r-traverse);       printf '| `../secret` | X |\n' >> "$d/README.md";                      check_diag R-traverse 1 'resolves outside the cut artifact' G_readme "$d"

echo "-- artifact scan gate --"
css_carrier() {
	printf 'return baseclass.extend({\n\tstyleText: "color: %s"\n});\n' "$1" > "$2/$JS/css.js"
}
check A-ok              0 G_art "$WORK/out"
d=$(m a-tracker);          printf '// see #1234\n' >> "$d/$JS/tint.js";                          check A-tracker           1 G_art "$d"
d=$(m a-tracker-6);        printf '// see #333333\n' >> "$d/$JS/tint.js";                        check A-tracker-6         1 G_art "$d"
d=$(m a-tracker-css);      sed_assert 's/$/\n\/\/ palette #123456/' "$d/$JS/css.js" '#123456' A-tracker-css \
                           && check A-tracker-css  1 G_art "$d"
d=$(m a-tracker-noncarrier); printf 'var x = "#123456"; // ref\n' > "$d/$JS/log.js";             check A-tracker-noncarrier 1 G_art "$d"
d=$(m a-hex-palette)
css_carrier '#333333' "$d"
check A-hex-palette 0 G_art "$d"
d=$(m a-hex-tint); printf "var T_PROBE_HEX = '#333333';\n" >> "$d/$JS/tint.js"; check A-hex-tint 0 G_art "$d"
d=$(m a-hex-3)
css_carrier '#123' "$d"
check A-hex-3 0 G_art "$d"
d=$(m a-hex-4)
css_carrier '#1234' "$d"
check A-hex-4 0 G_art "$d"
d=$(m a-hex-8)
css_carrier '#12345678' "$d"
check A-hex-8 0 G_art "$d"
d=$(m a-hex-fake-carrier)
printf 'var _probe = { styleText: "color: #333333" };\n' > "$d/$JS/css.js"
check A-hex-fake-carrier 1 G_art "$d"
d=$(m a-hex-comment-carrier)
cat > "$d/$JS/css.js" <<'EOF'
/*
return baseclass.extend({
	styleText: "color: #1234"
});
*/
EOF
check A-hex-comment-carrier 1 G_art "$d"
d=$(m a-hex-template-carrier)
cat > "$d/$JS/css.js" <<'EOF'
const fake = `return baseclass.extend({
	styleText: "color: #1234"
});`;
EOF
check A-hex-template-carrier 1 G_art "$d"
d=$(m a-short-hex-negative); printf '// see #123 outside colour context\n' >> "$d/$JS/css.js"; check A-short-hex-negative 1 G_art "$d"
# Same value with no colour context: the exemption must stay narrow.
d=$(m a-probe-neg);        printf 'var _probe = { color: "#333333" };\n' >> "$d/$JS/css.js";     check A-probe-neg         1 G_art "$d"
d=$(m a-monorepo);         printf '// see openwrt-feed/README.md\n'      >> "$d/$JS/tint.js";    check A-monorepo          1 G_art "$d"
d=$(m a-repo);             printf '// see lucas-albers-lz4/fwlive\n'     >> "$d/$JS/tint.js";    check A-repo              1 G_art "$d"
d=$(m a-changelog);        printf '// see CHANGELOG.md\n'                >> "$d/$JS/tint.js";    check A-changelog         1 G_art "$d"
d=$(m a-upper);            printf '// DO NOT EDIT\n'                     >> "$d/$JS/tint.js";    check A-donotedit-UP      1 G_art "$d"
d=$(m a-mixed);            printf '// Do Not Edit\n'                     >> "$d/$JS/tint.js";    check A-donotedit-Mix     1 G_art "$d"
d=$(m a-lower);            printf '// do not edit\n'                     >> "$d/$JS/tint.js";    check A-donotedit-low     1 G_art "$d"
d=$(m a-url);              printf '// https://openwrt.org/docs/guide\n'  >> "$d/$JS/tint.js";    check A-url-ok            0 G_art "$d"
d=$(m a-url-frag);         printf '// https://example.com/x#1234\n'      >> "$d/$JS/tint.js";    check A-url-frag          0 G_art "$d"
# Legitimate .css shapes that the #1192 narrowing rejects. Pinned so a future
# widening is a deliberate change (see #1209 for the decision).
d=$(m a-css-shadow);       printf '.a { box-shadow: 0 0 5px #333333; }\n' > "$d/$JS/probe.css";  check A-css-shadow        1 G_art "$d"
d=$(m a-css-border);       printf '.a { border: 1px solid #333333; }\n'   > "$d/$JS/probe.css";  check A-css-border        1 G_art "$d"
d=$(m a-css-gradient);     printf '.a { background: linear-gradient(#123456, #ffffff); }\n' > "$d/$JS/probe.css"; check A-css-gradient 1 G_art "$d"
d=$(m a-css-url);          printf '.a { fill: url(#123456); }\n'          > "$d/$JS/probe.css";  check A-css-url           1 G_art "$d"
d=$(m a-css-comment);      printf '/* issue #123456 */\n'                 > "$d/$JS/probe.css";  check A-css-comment       1 G_art "$d"
d=$(m a-css-content);      printf '.a { content: "#123456"; }\n'          > "$d/$JS/probe.css";  check A-css-content       1 G_art "$d"
d=$(m a-css-customprop);   printf '.a { --x: #333333; }\n'                > "$d/$JS/probe.css";  check A-css-customprop    1 G_art "$d"

echo "-- symlink gate --"
check S-ok              0 G_symlink "$WORK/out"
d=$(m s-link); ln -sf /etc/passwd "$d/$JS/ghost.js";                                           check S-symlink       1 G_symlink "$d"

echo "-- .pot reference gate --"
check P-ok              0 G_pot "$WORK/out"
d=$(m p-missing);     rm -f "$d/root/x.sh";                                                    check P-missing-target 1 G_pot "$d"
d=$(m p-unshaped);    sed -i 's|^#: applications/|#: openwrt-feed/luci-app-fwlive/|' \
                        "$d/po/templates/luci-app-fwlive.pot";                                 check P-not-luci-shaped 1 G_pot "$d"
d=$(m p-out-of-range); sed -i 's|root/x.sh:1|root/x.sh:99|' \
                        "$d/po/templates/luci-app-fwlive.pot";                                 check P-line-out-of-range 1 G_pot "$d"

echo
if [ "$CAPTURE" -eq 1 ]; then
  echo "capture only: no assertions evaluated"
else
  echo "passed=$PASS failed=$FAIL"
  [ "$FAIL" -eq 0 ] || { printf 'failed cases: %s\n' "${FAILED_NAMES[*]}"; exit 1; }
  echo "fwlive-upstream-cut gate contract OK"
fi
