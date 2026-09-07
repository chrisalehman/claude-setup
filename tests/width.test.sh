#!/bin/bash
# tests/width.test.sh — payload/scripts/lib/width.sh, the one column budget
# (bionic 1.4.0, wave-bionic-1.4.0-update slice DOCTOR handoff 4.6, spec AC-23:
# "the arrow glyph measures one column").
#
# WHAT THIS SUITE IS FOR. width.sh's own header states the property everything
# else in it rests on: the glyph set is CLOSED, and "a glyph added to a report
# and not to this list measures three columns too wide". Nothing walled that
# claim, and the arrow — the single most-printed non-ASCII glyph bionic has, the
# marker on every FIX line and every instruction that must survive a truncation —
# was not in the list. A row built through `bionic_line` with an arrow in its
# prefix therefore had its budget under-computed by two columns and came out
# short: the table steps left, and the instruction the arrow introduces is cut
# two characters earlier than the budget says it should be.
#
# THE ASSERTION IS DIFFERENTIAL, not a hardcoded list. Section 2 reads the
# glyphs the two printing scripts actually put into a bounded row and requires
# each to measure one column — so the next glyph someone reaches for is caught by
# this suite rather than by a crooked table on somebody's terminal.
#
# Usage: bash tests/width.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
WIDTH_SH="${REPO}/payload/scripts/lib/width.sh"

# expect_true is the framework's (tests/lib/assert.sh) — S9b removed the private
# shadow here (AC-12); same semantics (silences the command's own output).

expect_true "payload/scripts/lib/width.sh exists" test -f "$WIDTH_SH"

# shellcheck source=/dev/null
. "$WIDTH_SH"

# MEASURED UNDER `LC_ALL=C`, WHICH IS THE WHOLE POINT OF THE CLOSED SET. Under a
# UTF-8 locale bash's own `${#s}` already counts characters, so every glyph
# measures one whether or not it is in the list and an assertion taken there is
# vacuous — it passes on a file with an EMPTY substitution set. Under the C
# locale `${#s}` counts BYTES, and the substitution is the only thing standing
# between a three-byte glyph and a column that pads two short. That locale is not
# hypothetical: a hook or a script started from a stripped environment gets it,
# and it is the environment the file's own header is arguing about.
cols_c() {  # <string> -> its measured width under the C locale
  LC_ALL=C bash -c '. "$1"; bionic_cols "$2"' _ "$WIDTH_SH" "${1:-}"
}

section "Section 1: every glyph in the closed set measures one column"

for g in '✓' '✗' '–' '—' '≥' '…' '·' '→' '•'; do
  expect_eq "1.${g}: '${g}' measures 1 under a UTF-8 locale" "1" "$(bionic_cols "$g")"
  expect_eq "1c.${g}: '${g}' measures 1 under LC_ALL=C" "1" "$(cols_c "$g")"
done

expect_eq "2: ASCII is measured verbatim" "5" "$(bionic_cols "abcde")"
expect_eq "3: a mixed string counts glyphs as one each" "7" "$(cols_c "ab → cd")"

section "Section 2: no glyph reaches a bounded row unmeasured"

# THE GLYPHS THE PRINTING SCRIPTS ACTUALLY PUT IN A ROW. Taken from the shell
# STRING LITERALS the two report surfaces build rows out of — a glyph that only
# ever appears in a comment or a section banner is prose about the code, not
# output, and holding those to the budget would wall the wrong thing. The banner
# rule (`─`) and the box glyphs are excluded by name for exactly that reason.
row_glyphs() {
  python3 - "$@" <<'PY'
import re, sys, unicodedata
# Comment lines are stripped: a glyph in a header paragraph is never printed.
skip = set('─│┌┐└┘├┤┬┴┼§⊃')
out = set()
for path in sys.argv[1:]:
    for line in open(path, encoding='utf-8'):
        stripped = line.lstrip()
        if stripped.startswith('#'):
            continue
        for ch in line:
            if ord(ch) > 127 and ch not in skip:
                out.add(ch)
print(''.join(sorted(out)))
PY
}

if ! command -v python3 >/dev/null 2>&1; then
  no "4: python3 is needed to enumerate the printed glyphs"
else
  PRINTED="$(row_glyphs "${REPO}/payload/scripts/doctor.sh" "${REPO}/payload/scripts/setup.sh")"
  expect_true "4: the sweep found glyphs to check" test -n "$PRINTED"
  _bad=""
  while [ -n "$PRINTED" ]; do
    _g="${PRINTED%"${PRINTED#?}"}"     # the first CHARACTER, not the first byte
    PRINTED="${PRINTED#?}"
    _w="$(cols_c "$_g")"
    [ "$_w" = "1" ] || _bad="${_bad}${_bad:+ }${_g}(${_w})"
  done
  if [ -z "$_bad" ]; then ok "5: every glyph a row can carry measures one column"
  else no "5: a glyph a row can carry is not in width.sh's closed set" "$_bad"; fi
fi

section "Section 3: the truncator cuts characters, never bytes"

# width.sh's own correction: `printf '%.*s'` counts BYTES, so a length test in
# characters against a cut in bytes slices a multi-byte glyph in half. A cut
# through a run of arrows must leave whole arrows and valid UTF-8.
CUT="$(bionic_trunc "→→→→→→→→→→" 5)"
expect_eq "6: a cut string is measured back at its budget" "5" "$(bionic_cols "$CUT")"
if printf '%s' "$CUT" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
  ok "7: the cut leaves valid UTF-8"
else
  no "7: the cut produced invalid UTF-8" "$(printf '%s' "$CUT" | od -c | head -2)"
fi

# A GLYPH OUTSIDE THE CLOSED SET, WHICH IS WHERE THE CUT USED TO BREAK (AC-8,
# S24 F-25). Section 1 sweeps the set; this is the other half of the world —
# the characters that reach a bounded row as DATA rather than as decoration. A
# user whose home directory carries an accent, a dependency named in a script
# that is not ASCII, a marketplace path under a non-Latin name: none of them are
# in width.sh's list and none of them can be, because the list is the glyphs
# BIONIC prints.
#
# THE LOCALE IS THE DISCRIMINATOR, so the pair below is one call made twice.
# Under a UTF-8 locale `${s%?}` drops a character and the cut was always whole;
# under `LC_ALL=C` it drops a BYTE, and a three-byte character that the loop
# stops in the middle of leaves a fragment — invalid UTF-8, rendered as a
# replacement box, one level below the `printf '%.*s'` failure this file's
# header is about. Measured before the fix: `bionic_trunc "ab★cd" 4` returned
# the bytes `61 62 e2 e2 80 a6` under C and `ab…` under UTF-8.
trunc_c() {  # <string> <budget> -> the cut, made under the C locale
  LC_ALL=C bash -c '. "$1"; bionic_trunc "$2" "$3"' _ "$WIDTH_SH" "${1:-}" "${2:-0}"
}

CUT_C="$(trunc_c "ab★cd" 4)"
if printf '%s' "$CUT_C" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
  ok "7c: a cut through a glyph outside the closed set leaves valid UTF-8 under LC_ALL=C"
else
  no "7c: the cut split a multi-byte character under LC_ALL=C" \
     "$(printf '%s' "$CUT_C" | od -An -tx1 | tr -s ' ')"
fi
# THE PAIRED POSITIVE. The same string and budget under a UTF-8 locale, where
# this has always held — so a `7c` that passes because `bionic_trunc` started
# returning nothing, or because iconv stopped being run, fails here too.
CUT_U="$(bionic_trunc "ab★cd" 4)"
expect_true "7u: …and the same cut under a UTF-8 locale is valid too" \
  sh -c 'printf %s "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1' _ "$CUT_U"
# AND THE TWO LOCALES NOW RETURN THE SAME STRING, which is the property AC-8 is
# actually about: a report whose text depends on the environment the reader's
# shell was started in is a report that says two things. Before the fix the same
# call returned `ab★…` under UTF-8 and the bytes `61 62 e2 e2 80 a6` under C.
# The agreed answer is the CONSERVATIVE one — `★` is outside the closed glyph
# set, so it is measured at its three bytes and the cut takes it whole rather
# than keeping a character it cannot size. Short of the budget, never over it,
# and the same in both places.
expect_eq "7n: …and the C and the UTF-8 cut are now the same string" "$CUT_U" "$CUT_C"
expect_true "7b: the C-locale cut is bounded by the budget it was given" \
  test "$(cols_c "$CUT_C")" -le 4

section "Section 4: bionic_line protects the instruction it is handed"

LINE="$(bionic_line "  ✓ $(printf '%-40s' 'a label')" \
        "$(printf 'x%.0s' $(seq 1 200))" " → run /bionic:setup")"
expect_eq "8: the whole row fits the budget" "$BIONIC_LINE_WIDTH" "$(bionic_cols "$LINE")"
case "$LINE" in
  *" → run /bionic:setup") ok "9: the instruction survives the cut whole" ;;
  *) no "9: the instruction was eaten by the cut" "$(printf '%.120s' "$LINE")" ;;
esac

finish
