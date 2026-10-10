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
# Scope: the gate functions, driven against a minimal clean artifact tree that
# carries the REAL css.js and tint.js carriers, so the colour-context rule is
# exercised against the files it was written for. The end-to-end run (real subtree
# split, real rewrites, real git refs) stays in tests/fwlive-upstream-cut.test.sh.
# This test is hermetic: no network, no node_modules, no git refs.
#
# Run:  bash tests/fwlive-upstream-cut-gate-contract.test.sh
#       bash tests/fwlive-upstream-cut-gate-contract.test.sh --capture    (print observed rc only)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/scripts/upstream-cut.sh"
PKG="$ROOT/openwrt-feed/luci-app-fwlive"
JS=htdocs/luci-static/resources/fwlive
CAPTURE=0
[ "${1:-}" = "--capture" ] && CAPTURE=1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# ---- extract the gate implementations from the live script (survives line drift) ----
extract_py() { # $1 = function name
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\)" { inb=1 }
    inb && /<<.PY./ { py=1; next }
    py && /^PY$/ { exit }
    py { print }
  ' "$SRC" > "$WORK/bin/$1.py"
  [ -s "$WORK/bin/$1.py" ] || { echo "FATAL: cannot extract $1 from $SRC" >&2; exit 2; }
}
extract_py upstream_cut_verify_readme_rows
extract_py upstream_cut_verify_artifacts
extract_py upstream_cut_verify_pot_refs
awk '/^upstream_cut_verify_no_symlinks\(\)/,/^}/' "$SRC" > "$WORK/bin/no_symlinks.sh"
[ -s "$WORK/bin/no_symlinks.sh" ] || { echo "FATAL: cannot extract no_symlinks" >&2; exit 2; }

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
  if [ "$CAPTURE" -eq 1 ]; then printf '  %-22s rc=%s\n' "$name" "$got"; return 0; fi
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS+1)); printf '  ok   %-22s rc=%s\n' "$name" "$got"
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$name")
    printf '  FAIL %-22s rc=%s want=%s\n' "$name" "$got" "$want"
    sed 's/^/         | /' "$WORK/last.out" | head -3
  fi
}
G_readme()  { python3 "$WORK/bin/upstream_cut_verify_readme_rows.py" "$1"; }
G_art()     { python3 "$WORK/bin/upstream_cut_verify_artifacts.py" "$1"; }
G_pot()     { python3 "$WORK/bin/upstream_cut_verify_pot_refs.py" "$1" "$PKG"; }
G_symlink() { ( set +e; . "$WORK/bin/no_symlinks.sh"; upstream_cut_verify_no_symlinks "$1" ); }

# Content-dependent mutations must prove they changed the file, otherwise the case
# silently degrades into a second copy of the A-ok case.
sed_assert() { # sed_expr file must_contain case_name
  sed -i "$1" "$2"
  grep -q -- "$3" "$2" && return 0
  FAIL=$((FAIL+1)); FAILED_NAMES+=("$4")
  printf '  FAIL %-22s fixture precondition missing: %s\n' "$4" "$3"
  return 1
}

echo "== upstream-cut gate contract =="
build_base

echo "-- README path-table gate --"
check R-ok              0 G_readme "$WORK/out"
d=$(m r-dangling);      printf '| `root/ghost.sh` | Ghost |\n' >> "$d/README.md";               check R-dangling      1 G_readme "$d"
d=$(m r-hole-blank);    sed -i '0,/^| `/s//\n| `root\/ghost.sh` | Ghost |\n| `/' "$d/README.md"; check R-hole-blank    1 G_readme "$d"
d=$(m r-hole-pipeless); sed -i '0,/^| `/s//prose line without a pipe\n| `/' "$d/README.md";      check R-hole-pipeless 1 G_readme "$d"
d=$(m r-empty);         printf '| Path | Role |\n| --- | --- |\n' > "$d/README.md";            check R-empty         1 G_readme "$d"
d=$(m r-no-readme);     rm -f "$d/README.md";                                                  check R-no-readme     1 G_readme "$d"
d=$(m r-tab-row);       printf '\t| `root/ghost.sh` | Ghost |\n' >> "$d/README.md";            check R-tab-row       1 G_readme "$d"

echo "-- artifact scan gate --"
check A-ok              0 G_art "$WORK/out"
d=$(m a-tracker);    printf '// see #1234\n' >> "$d/$JS/tint.js";                              check A-tracker       1 G_art "$d"
d=$(m a-tracker-6);  printf '// see #333333\n' >> "$d/$JS/tint.js";                            check A-tracker-6     1 G_art "$d"
d=$(m a-hex-css);    sed_assert 's/#0d9488/#333333/' "$d/$JS/css.js" '#333333' A-hex-palette && check A-hex-palette 0 G_art "$d"
d=$(m a-hex-tint);   sed_assert 's/#0d9488/#000000/' "$d/$JS/tint.js" '#000000' A-hex-tint   && check A-hex-tint    0 G_art "$d"
d=$(m a-monorepo);   printf '// see openwrt-feed/README.md\n'      >> "$d/$JS/tint.js";        check A-monorepo      1 G_art "$d"
d=$(m a-repo);       printf '// see lucas-albers-lz4/fwlive\n'     >> "$d/$JS/tint.js";        check A-repo          1 G_art "$d"
d=$(m a-changelog);  printf '// see CHANGELOG.md\n'                >> "$d/$JS/tint.js";        check A-changelog     1 G_art "$d"
d=$(m a-upper);      printf '// DO NOT EDIT\n'                     >> "$d/$JS/tint.js";        check A-donotedit-UP  1 G_art "$d"
d=$(m a-mixed);      printf '// Do Not Edit\n'                     >> "$d/$JS/tint.js";        check A-donotedit-Mix 1 G_art "$d"
d=$(m a-lower);      printf '// do not edit\n'                     >> "$d/$JS/tint.js";        check A-donotedit-low 1 G_art "$d"
d=$(m a-url);        printf '// https://openwrt.org/docs/guide\n'  >> "$d/$JS/tint.js";        check A-url-ok        0 G_art "$d"
d=$(m a-url-frag);   printf '// https://example.com/x#1234\n'      >> "$d/$JS/tint.js";        check A-url-frag      0 G_art "$d"

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
