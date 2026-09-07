# tests/lib/assert.sh — THE TEST FRAMEWORK. Sections, assertions, counters, the
# helper-presence derivation, and the tally (wave-01 verification-cannot-lie S1,
# spec AC-13/AC-14/AC-15; design ledger D1 "a suite is a client of one test
# framework").
#
#     . "$(dirname "$0")/lib/resolve-roots.sh"
#     . "$(dirname "$0")/lib/assert.sh"      # from tests/*.test.sh
#
# WHAT IT OWNS.
#
#   section <name>        opens a section that MUST assert something
#   setup_section <name>  opens a section exempt from that rule (fixture building)
#   ok <msg>              record a pass
#   no <msg> [detail]     record a fail
#   THE GENERIC ASSERTION FAMILY — the thirteen names below are the framework's
#   and no suite's (A-16, spec AC-12). Every one reports through ok/no, so the
#   counters and the section floor see it.
#
#   expect_eq <msg> <expected> <actual>          string equality
#   expect_ne <msg> <not-expected> <actual>      string inequality
#   expect_true <msg> <cmd>...                   command exits 0 (output silenced)
#   expect_false <msg> <cmd>...                  command exits non-zero (silenced)
#   expect_contains <msg> <needle> <haystack>    literal substring present
#   expect_absent <msg> <needle> <haystack>      literal substring absent
#   expect_match <msg> <glob> <actual>           GLOB match (not a regex)
#   expect_no_match <msg> <glob> <actual>        GLOB non-match
#   expect_regex <msg> <ERE> <actual>            ERE match, unanchored
#   expect_no_regex <msg> <ERE> <actual>         ERE non-match
#   expect_status <msg> <expected> <actual>      exit status equality
#   expect_empty <msg> <value>                   value is the empty string
#   expect_nonempty <msg> <value>                value is not the empty string
#   anchor [-E] <file> <pattern> <count>  the PRECONDITION of a mutation: the
#                               pattern still matches exactly <count> lines of
#                               <file>. Call it BEFORE the grep -v / sed that
#                               builds the mutant.
#   require_helpers <name>...   explicit presence guard (kept for the two suites
#                               that already call it)
#   finish                close the last section, fail every section that asserted
#                         nothing, print the tally, exit by FAIL
#
# THE COUNTERS AND ok/no ARE DEFINED HERE, UNCONDITIONALLY. This file is the ONE
# definition of PASS/FAIL/TOTAL and of what counts as a result (D1). It does not
# DEFER: a suite that defines its own `ok()`/`no()` or resets its own counters at
# column 0 is REFUSED by the runner's adoption wall (`_tf_adoption_refusal`,
# below) and never runs — as is a suite that does not adopt this file at all.
# Every suite on the roster is a client of it; the ones that once carried private
# definitions were migrated by S5–S9 and the wall closed the door behind them.
#
# ── THE GENERIC FAMILY: SEMANTICS, ARGUMENT ORDER, AND THE OLD SPELLINGS ─────
#
# Before this file owned them, 53 suites carried 37 distinct private `expect_*`
# spellings between them. Thirteen of those are GENERIC — they say nothing about
# bionic, only about strings, commands, patterns and exit statuses — and those
# thirteen are now defined here, once. Regex matching is on that list rather than
# left private (A-S1b-2, resolved by the orchestrator 2026-09-06 as option 2):
# eight suites need it, so leaving it out would have made the ownership boundary
# a loophole for exactly the duplication this wave removes. The other 24 are
# suite-specific (expect_finding,
# expect_audit_line, expect_block, expect_allow, …); they are built on ok/no,
# they stay local to the suite that needs them, and they stay legal.
#
# ARGUMENT ORDER is `<label> <expected> <actual>` throughout, which is what the
# tree already did unanimously: expected-side first for eq/ne/status, needle
# before haystack for contains/absent, pattern before subject for match/no_match.
# The two exceptions in the tree (live-agents and resources spelled expect_match
# `<label> <actual> <ERE>`) were outvoted 11 to 2 and were renamed onto
# `expect_regex` by S9b; no `expect_match` call survives in either file.
#
# SEMANTICS are the tree's most common definition of each name, measured:
#
#   expect_true / expect_false SILENCE the command they run (stdout AND stderr).
#     17 of 20 private definitions of expect_true do, and 6 of 9 of expect_false.
#     A command whose output you want to assert on should be captured into a
#     variable and asserted with expect_contains — not run through expect_true.
#
#   expect_contains / expect_absent take a LITERAL substring, implemented with a
#     quoted `case` glob rather than `grep -F`. The tree is split almost evenly
#     (10 `case` to 9 `grep -qF` for contains), and the two agree on every
#     single-line needle. `case` is chosen because it is exact substring
#     semantics: `grep -F` reads a newline in the needle as pattern alternation,
#     so a multi-line needle matches too eagerly under contains and, worse, too
#     eagerly under absent. It also keeps expect_absent the exact complement of
#     expect_contains, and it spawns nothing (no `grep -q` in a pipeline, which
#     exits 141 under pipefail on a large producer).
#
#   expect_match / expect_no_match take a GLOB, not a regex — `[[ $actual == $pat ]]`
#     with the pattern unquoted. 11 of 14 private definitions of expect_match are
#     this, and all 8 of expect_no_match are; between them they carry 266 call
#     sites against 75 for the regex spellings. Anchoring is implicit: the glob
#     must match the WHOLE value, so a substring test needs `*needle*`.
#
#   expect_regex / expect_no_regex take an EXTENDED regular expression and are
#     UNANCHORED: `needle` matches "a needle here" with no `.*` on either side.
#     This is the semantics of the tree's `expect_matches` (5 definitions, 25 call
#     sites), and it is a genuinely different matcher from expect_match — a glob
#     reads `[0-9]+` as a literal bracket expression followed by a literal plus.
#     Pick expect_regex when the pattern needs a quantifier, alternation or an
#     anchor; pick expect_match when a `*needle*` says it.
#
#     The value is matched with a HERESTRING, never `printf ... | grep -q`. Two
#     suites spell their private expect_matches as a pipeline, and under
#     `pipefail` that reports FAILURE on a value the pattern matches, as soon as
#     the value outgrows the 64 KiB pipe buffer: grep leaves early and the
#     producer takes EPIPE. The status is 141 when the producer dies by SIGPIPE
#     and 1 when bash reports the write error instead — it varies with the
#     producer, the size and whether a trap is installed, so only "non-zero" is
#     stable. Either way the assertion says FAIL and the code is fine.
#     framework.test.sh §10 pins both halves. Capture the value, then match it.
#
#   expect_status compares two exit statuses as strings, expected first.
#
# THE OLD SPELLINGS — `old -> canonical`. No aliases are defined here: the
# migration slices rename the call sites. S5-S8 quote this table.
#
#   expect_equal -> expect_eq — pure rename (stop-check, 4 call sites; its
#     failing arm also printed a diff, which is detail text, not semantics).
#   expect_differ -> expect_ne — pure rename (stop-check; defined, never called).
#   expect_not_contains -> expect_absent — pure rename, same `case` semantics
#     (command-relay, env, rc-item; 7 call sites).
#   expect_matches -> expect_regex — PURE rename, same ERE semantics, same
#     argument order (execution-recorder, interpreter-pin, session-sweeper,
#     stop-check, stop-guard; 25 call sites). The two pipeline spellings
#     (interpreter-pin, session-sweeper) lose their 141 exposure in the move.
#   expect_match, in the THREE suites where it is secretly an ERE -> expect_regex.
#     live-agents (8 sites) and resources (17) also REVERSE the arguments, spelling
#     it `<label> <actual> <ERE>`, so those 25 sites need the order corrected as
#     well as the name changed. This is the highest-risk rebinding in the
#     migration: their private definition wins today, so nothing is red now, and
#     the moment the adoption wall removes the shadow the calls bind to the glob
#     helper with the arguments the wrong way round and STILL nothing goes red.
#     preflight-probe (11 sites) is the third: its expect_match takes a FILE, so
#     each call site must grow a read of that file, and its sibling expect_nomatch
#     stays local — that suite ends up with a split idiom until someone routes
#     both together.
#   expect_nomatch -> NOT a rename: it takes a FILE rather than a string
#     (preflight-probe, 14 call sites). Stays local under its own name.
#   expect_absent_ug -> NOT a rename: it pins /usr/bin/grep on purpose, because
#     the shell `grep` on this machine skips hidden directories (cross-gate).
#
# ── THE ANCHOR: THE PRECONDITION OF A MUTATION (AC-29, S19) ──────────────────
#
# A suite that proves an assertion DISCRIMINATES builds a mutant: it strips or
# rewrites one line of a shipped source file with `grep -v` or `sed`, drives the
# mutant through the same check, and asserts the check now disagrees. The pattern
# it strips is the ANCHOR, and it is a precondition, not a detail — when the
# anchored line is reworded, reindented or moved, the pattern matches nothing and
# a mutation whose anchor moved is byte-identical to the shipped file. The mutant
# is then a control, the row below it goes green, and the suite reports that a
# check discriminates when nothing was ever mutated. That is the S21 incident
# (`61b8ca8` reindented a `pressure_sample` call and renamed a local; the anchor
# pinned both, matched nothing, and only a hand-rolled count-difference row caught
# it) and it is the shape this helper makes free.
#
#   anchor <file> <pattern> <count>       <pattern> is a FIXED STRING
#   anchor -E <file> <ERE> <count>        <pattern> is an EXTENDED regular expression
#
# THE DEFAULT IS FIXED-STRING because that is what a maintainer means by "this
# line is still here": most anchors are a sentence or an assignment quoted out of
# the file, and reading `.` or `+` in it as a metacharacter can only make the
# anchor match MORE than the mutation will. `-E` is opt-in and takes the mutation's
# own ERE verbatim, which is what the four `grep -vE` sites need.
#
# IT REPORTS, IT DOES NOT ABORT. A red anchor is a diagnosis: it says the mutation
# below is a no-op, so a reader knows the behavioural reds that follow are about
# the anchor and not about the contract. The suite keeps running, the way every
# other assertion here does.
#
# COUNT, NOT PRESENCE. `<count>` is exact. A sentence that was duplicated rather
# than moved breaks a mutation just as thoroughly as one that vanished — `grep -v`
# would then strip two lines, and `sed` would rewrite both.
#
# MATCHING USES THE SUITE'S OWN `grep`, the same binary the doctoring line uses,
# so the anchor and the mutation cannot disagree about what the pattern means.
#
# THE ANCHOR MUST MATCH AT LEAST AS STRICTLY AS THE MUTATION (A-35a, S19c). A
# fixed-string anchor is a SUBSTRING test, so it still matches a line that has
# drifted by one leading space — while a whole-line-anchored `sed 's/^exact$/…/'`
# or `grep -vx` no-ops on that same line. Anchor a whole-line mutation with `-E`
# and the mutation's own `^…$`, or the precondition is weaker than the thing it
# is the precondition for and the green it gives is worth nothing.
#
# ── ASSERTION DISCIPLINE ─────────────────────────────────────────────────────
#
# PAIRED POSITIVE. A negative assertion — "this string is absent", "this set is
# empty", "this file does not exist" — passes just as loudly when the mechanism
# under test never ran at all. Every negative assertion needs a positive one
# beside it, in the same section, over the same fixture: one row that proves the
# thing you are looking for CAN appear here, and one that proves it does not in
# this state. An assertion that cannot be made to fail by breaking the code it
# names is not an assertion.
#
# LOSSY RENDERS. An assertion about a render that truncates needs a second,
# unlossy source, and a whole-render glob is not an assertion. (Three assertions
# in the 1.4.4 fixit were misled by exactly this: doctor's verdict line is cut at
# 100 columns, so the text the assertion looked for was outside the frame and the
# row went green on a substring of the ellipsis.) Assert against the value the
# renderer was given, or against a non-truncating surface, and let the render
# assertion pin only the framing.
#
# ── HELPER DERIVATION (AC-14) ────────────────────────────────────────────────
#
# Every suite here runs under `set -uo pipefail` with NO `-e`, so a call to an
# assertion helper that was never defined is a silent `command not found` on
# stderr: the row asserts nothing, TOTAL never increments, and `tests/run.sh`
# discards a green suite's stderr (research-code-map §5.3–§5.4). That is how
# `expect_empty` at tests/cross-gate-agreement.test.sh:5960 has been asserting
# nothing.
#
# So the framework does not wait to be told which helpers a suite uses. At load
# it scans the suite's own source ($0) for call tokens matching
# `ok|no|expect_[a-z_]+|anchor` in command position, and exits 1 naming any name
# that neither this file defines nor the suite itself defines. The explicit
# `require_helpers a b c` form stays for the two suites that call it, and for
# names the derivation cannot see.

# ── counters: the ONE definition ─────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0

# THIS FILE'S OWN PATH, absolute. `_tf_owned_names` reads the ownership list out
# of it at call time, and callers run from their own cwd (tests/run.sh cds to the
# repo root, a suite does not), so a relative path here would be read from
# whichever directory happened to be current.
_TF_LIB="${BASH_SOURCE[0]:-$0}"
case "$_TF_LIB" in
  /*) ;;
  *)  _TF_LIB="$(cd "$(dirname "$_TF_LIB")" 2>/dev/null && pwd)/$(basename "$_TF_LIB")" ;;
esac

# ── section state ────────────────────────────────────────────────────────────
_TF_SECTION=""        # name of the open section, empty when none
_TF_SECTION_KIND=""   # assert | setup
_TF_SECTION_ROWS=0    # assertions recorded since the section opened
_TF_SECTIONS=0        # asserting sections opened
_TF_SETUPS=0          # setup sections opened
_TF_EMPTY=""          # newline-separated names of sections that asserted nothing

_tf_close_section() {
  [ -n "$_TF_SECTION" ] || return 0
  if [ "$_TF_SECTION_KIND" = "assert" ] && [ "$_TF_SECTION_ROWS" -eq 0 ]; then
    _TF_EMPTY="${_TF_EMPTY}${_TF_SECTION}
"
  fi
  _TF_SECTION=""
  _TF_SECTION_KIND=""
  _TF_SECTION_ROWS=0
}

# section <name> — opens a section that must record at least one assertion.
section() {
  _tf_close_section
  _TF_SECTION="$1"
  _TF_SECTION_KIND="assert"
  _TF_SECTION_ROWS=0
  _TF_SECTIONS=$((_TF_SECTIONS + 1))
  echo ""
  echo "── $1"
}

# setup_section <name> — a section that builds fixtures and is EXEMPT from the
# no-section-without-an-assertion rule. It is exempt because it is named: a
# section that asserts nothing and does not say so is the defect.
setup_section() {
  _tf_close_section
  _TF_SECTION="$1"
  _TF_SECTION_KIND="setup"
  _TF_SECTION_ROWS=0
  _TF_SETUPS=$((_TF_SETUPS + 1))
  echo ""
  echo "── $1 (setup)"
}

# ── assertions ───────────────────────────────────────────────────────────────
ok() {
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  _TF_SECTION_ROWS=$((_TF_SECTION_ROWS + 1))
  echo "PASS: $1"
}

no() {
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  _TF_SECTION_ROWS=$((_TF_SECTION_ROWS + 1))
  echo "FAIL: $1"
  [ -n "${2:-}" ] && echo "      $2"
  return 0
}

# expect_eq <label> <expected> <actual>
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi; }

# expect_ne <label> <not-expected> <actual>
expect_ne() { if [ "$2" != "$3" ]; then ok "$1"; else no "$1" "expected anything but '$2', got it"; fi; }

# expect_true <label> <cmd>... — the command's own output is silenced.
expect_true() {
  local _l="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$_l"; else no "$_l" "command failed: $*"; fi
}

# expect_false <label> <cmd>... — the command's own output is silenced.
expect_false() {
  local _l="$1"; shift
  if "$@" >/dev/null 2>&1; then no "$_l" "command unexpectedly succeeded: $*"; else ok "$_l"; fi
}

# expect_contains <label> <needle> <haystack> — literal substring.
expect_contains() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *)      no "$1" "missing '$2' in: $(printf '%.400s' "$3")" ;;
  esac
}

# expect_absent <label> <needle> <haystack> — the exact complement of
# expect_contains, and a NEGATIVE assertion: pair it with a positive one over the
# same fixture, or it passes when the producer never ran.
expect_absent() {
  case "$3" in
    *"$2"*) no "$1" "unexpectedly present: '$2' in: $(printf '%.400s' "$3")" ;;
    *)      ok "$1" ;;
  esac
}

# expect_match <label> <glob> <actual> — GLOB, not a regex, and it must match the
# whole value: a substring test is '*needle*'.
expect_match() {
  # shellcheck disable=SC2053  # RHS is a glob on purpose
  if [[ "$3" == $2 ]]; then ok "$1"; else no "$1" "no match for '$2' in: $(printf '%.400s' "$3")"; fi
}

# expect_no_match <label> <glob> <actual> — a NEGATIVE assertion; pair it.
expect_no_match() {
  # shellcheck disable=SC2053  # RHS is a glob on purpose
  if [[ "$3" == $2 ]]; then no "$1" "unexpected match for '$2' in: $(printf '%.400s' "$3")"; else ok "$1"; fi
}

# expect_regex <label> <ERE> <actual> — EXTENDED regular expression, unanchored.
# The value is matched through a herestring, not a pipeline: `printf | grep -q`
# exits 141 under pipefail on a large value and reports a false FAIL.
expect_regex() {
  if grep -qE -- "$2" <<<"$3"; then ok "$1"; else no "$1" "no match for /$2/ in: $(printf '%.400s' "$3")"; fi
}

# expect_no_regex <label> <ERE> <actual> — the exact complement of expect_regex,
# and a NEGATIVE assertion: pair it with a positive one over the same fixture.
expect_no_regex() {
  if grep -qE -- "$2" <<<"$3"; then no "$1" "unexpected match for /$2/ in: $(printf '%.400s' "$3")"; else ok "$1"; fi
}

# expect_status <label> <expected> <actual>
expect_status() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected exit $2, got $3"; fi; }

# expect_empty <label> <value> — a NEGATIVE assertion: pair it with a positive
# one over the same fixture, or it passes when the producer never ran.
expect_empty() { if [ -z "${2:-}" ]; then ok "$1"; else no "$1" "expected no output, got: $2"; fi; }

# expect_nonempty <label> <value>
expect_nonempty() { if [ -n "${2:-}" ]; then ok "$1"; else no "$1" "expected a non-empty value, got nothing"; fi; }

# anchor [-E] <file> <pattern> <expected-count> — the precondition of a mutation.
# Call it immediately BEFORE the `grep -v` / `sed` that builds the mutant. See the
# docblock above for why a mutation whose anchor moved proves nothing.
anchor() {
  local _mode="-F" _file _pat _want _name _got
  if [ "${1:-}" = "-E" ]; then _mode="-E"; shift; fi
  _file="${1:-}"; _pat="${2:-}"; _want="${3:-}"
  _name="anchor: ${_pat} matches ${_want} line(s) of ${_file##*/}"
  if [ ! -f "$_file" ] || [ ! -r "$_file" ]; then
    no "$_name" "cannot read the anchored file: $_file"
    return 0
  fi
  _got="$(grep -c "$_mode" -- "$_pat" "$_file" 2>/dev/null)"
  _got="$(printf '%s' "${_got:-0}" | tr -cd '0-9')"
  [ -n "$_got" ] || _got=0
  # THE DETAIL BRANCHES ON THE DIRECTION (review-c C-7). Fewer than declared is
  # the moved anchor: the mutation is a no-op and everything under it reads the
  # shipped file. MORE than declared is the opposite failure — `grep -v` strips
  # two lines and `sed` rewrites both, which the COUNT, NOT PRESENCE paragraph
  # above already says. One string covering both told the reader the wrong half
  # of the time.
  if [ "$_got" = "$_want" ]; then
    ok "$_name"
  elif [ "${_got:-0}" -lt "${_want:-0}" ] 2>/dev/null; then
    no "$_name" "found $_got line(s) — the anchor MOVED, so the mutation below is a no-op and every row under it is reading the shipped file"
  else
    no "$_name" "found $_got line(s) — the anchor matches MORE than it declared, so the mutation below strips or rewrites lines it was never meant to touch"
  fi
}

# ── the tally ────────────────────────────────────────────────────────────────
#
# finish — closes the open section, turns every section that asserted nothing
# into a named FAIL (AC-13), fails a suite that asserted nothing AT ALL, prints
# the tally with `sections=N setup=M`, and exits by FAIL. Call it as the last
# line of a suite instead of a hand-rolled `[ "$FAIL" -eq 0 ]`.
#
# THE WHOLE-SUITE FLOOR (review-a A-4). AC-13 closes lie class 3 per SECTION; it
# said nothing about a suite that opens none. Such a suite has an empty
# `_TF_EMPTY`, `FAIL=0`, and exits 0 — and tests/run.sh judges on rc and prints
# `✓ PASS`, so `0/0 passed` counts toward `Gating: N passed`. A result that
# covered nothing claimed a covered environment, which is the lie this wave
# exists to close, one level up from the section. The reachable shape is not a
# hand-written empty suite: it is an early `exit 0` on a missing fixture tool,
# or a migration that leaves a file with its sections stripped.
#
# THE FLOOR IS ASSERTIONS, NOT SECTIONS. `tests/loader.test.sh` and
# `tests/patrol-marker.test.sh` legitimately open no `section` at all and assert
# from the top level (`sections=0`, TOTAL > 0); they are not the shape this
# refuses. TOTAL is what a result is made of, so TOTAL is what is floored.
finish() {
  local name suite
  _tf_close_section
  if [ -n "$_TF_EMPTY" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
      echo "FAIL: section asserted nothing: $name — a section that legitimately makes no assertion is declared with \`setup_section\`"
    done <<TF_EMPTY_SECTIONS
$_TF_EMPTY
TF_EMPTY_SECTIONS
  fi
  suite="$(basename "${0:-suite}")"
  if [ "$TOTAL" -eq 0 ]; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "FAIL: suite asserted nothing: ${suite}"
  fi
  echo ""
  echo "──────────────────────────────────────────────"
  echo "${suite}: ${PASS}/${TOTAL} passed, ${FAIL} failed  sections=${_TF_SECTIONS} setup=${_TF_SETUPS}"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

# ── helper presence ──────────────────────────────────────────────────────────

# require_helpers <name>... -> exit 1, naming every undefined one, if any name
# passed is not a defined shell function. Call it once, after every assertion
# helper the suite defines for itself has been defined.
require_helpers() {
  local missing="" name
  for name in "$@"; do
    type -t "$name" >/dev/null 2>&1 || missing="$missing $name"
  done
  if [ -n "$missing" ]; then
    echo "require_helpers: undefined:$missing" >&2
    exit 1
  fi
}

# _tf_scan <file> — prints `CALL <name>` for every call token in command
# position matching ok|no|expect_[a-z_]+|anchor, and `DEF <name>` for every
# function this file defines itself. Heredoc BODIES are skipped: a suite that
# writes a scratch suite with a planted undefined helper is not itself calling
# it. Full-line comments are skipped. Command position means: first word of a
# line, or the first word after ; & | ( ) { } or then/else/elif/do/if/while/
# until/!.
#
# IT ALSO PRINTS THE TWO RECORDS THE ADOPTION WALL READS (S10), because one
# scanner is the point: a second one would skip heredocs differently on the day
# it mattered.
#
#   TOPDEF <name>   a function definition at COLUMN 0 — the shadow that replaces
#                   the framework's own for the rest of the suite. Every TOPDEF
#                   is also a DEF; an indented or subshell-scoped definition is
#                   a DEF and NOT a TOPDEF (A-29).
#   TOPSET <name>   a counter reset (`PASS=0`, `FAIL=0`, `TOTAL=0`) on a line
#                   that BEGINS with one, including the `PASS=0; FAIL=0` form.
#   SOURCES assert.sh   the suite sources this framework, outside a heredoc.
#   USES finish     the suite calls `finish` in command position, outside a
#                   heredoc. Together these two are the ADOPTION half of AC-12
#                   (K-7): the wall used to enforce only that a suite may not
#                   SHADOW the framework, never that it must adopt it.
_tf_scan() {
  awk '
    # hdtag(s) — THE HEREDOC TAG OPENED BY THIS LINE, or "". QUOTE- AND
    # ARITHMETIC-AWARE (review-a A-1/A-9): `echo "see <<EOF"` is text and
    # `$(( 1 << 3 ))` is a shift, and neither opens anything. That is not a
    # nicety. Every line from an opener to its terminator is consumed unread, so
    # ONE phantom opener blinds the adoption wall AND the derivation for the
    # whole rest of the file, silently — which is the state four suites in this
    # tree were in when the textual matcher shipped. The character loop is the
    # one payload/scripts/lib/cmd-class.sh already carries for the same problem
    # (`heredoc_tag`), plus arithmetic state and command-substitution nesting —
    # a $( ) inside a double-quoted string re-enters an UNQUOTED context, and
    # protect-main.test.sh:343 is that exact line. A herestring <<< opens no body.
    # NOTE FOR EDITORS: this awk program is inside a shell single-quoted string,
    # so it must not contain an apostrophe anywhere, comments included. A single
    # quote is spelled \047.
    function hdtag(s,   i, c, L, j, t, ch, q, dep, qs, ar, pc) {
      L = length(s); q = ""; dep = 0; ar = 0; pc = ""
      for (i = 1; i <= L; i++) {
        c = substr(s, i, 1)
        if (ar > 0) {                                  # inside $(( )) / (( ))
          if (c == "(") ar++
          else if (c == ")") ar--
          continue
        }
        if (q == "\047") {                             # inside \047 quotes: nothing is special
          if (c == "\047") q = ""
          continue
        }
        if (q == "\"") {                               # double quotes: \ escapes, $( nests
          if (c == "\\") { i++; continue }
          if (c == "\"") { q = ""; continue }
          if (c == "$" && substr(s, i + 1, 1) == "(") {
            if (substr(s, i + 2, 1) == "(") { ar = 2; i += 2; continue }
            dep++; qs[dep] = q; q = ""; i++; pc = ""; continue
          }
          continue
        }
        if (c == "\047" || c == "\"") { q = c; pc = c; continue }
        if (c == "\\") { i++; pc = ""; continue }
        if (c == "$" && substr(s, i + 1, 1) == "(") {
          if (substr(s, i + 2, 1) == "(") { ar = 2; i += 2; continue }
          dep++; qs[dep] = q; q = ""; i++; pc = ""; continue
        }
        if (c == ")" && dep > 0) { q = qs[dep]; dep--; pc = ")"; continue }
        if (c == "(" && substr(s, i + 1, 1) == "(" \
            && (pc == "" || pc == ";" || pc == "&" || pc == "|" || pc == "(" || pc == "{")) {
          ar = 2; i++; continue
        }
        if (c == "<" && substr(s, i + 1, 1) == "<") {
          if (substr(s, i + 2, 1) == "<") { i += 2; pc = "<"; continue }   # here-STRING
          j = i + 2
          if (substr(s, j, 1) == "-") j++
          while (substr(s, j, 1) == " " || substr(s, j, 1) == "\t") j++
          ch = substr(s, j, 1)
          if (ch == "\047" || ch == "\"") j++
          t = ""
          while (j <= L) {
            c = substr(s, j, 1)
            if (c ~ /[A-Za-z0-9_]/) { t = t c; j++ } else break
          }
          if (t != "") return t
          i = j - 1; pc = "<"; continue
        }
        if (c != " " && c != "\t") pc = c
      }
      return ""
    }
    hd != "" {
      if ($0 ~ ("^[ \t]*" hd "[ \t]*$")) hd = ""
      next
    }
    {
      line = $0
      if (line ~ /^[ \t]*#/) next

      # heredoc opener on this line? (herestrings <<< are not openers)
      pending = hdtag(line)

      # THE TWO RECORDS THE ADOPTION HALF READS (critic K-7). Both are taken
      # from the same heredoc-skipping pass, so a suite that only writes the
      # word `finish` into a scratch fixture does not count as calling it.
      if (line ~ /^[ \t]*(\.|source)[ \t]+.*lib\/assert\.sh/) print "SOURCES assert.sh"

      # a counter reset at column 0, and every one after a `;` on that line
      if (match(line, /^(PASS|FAIL|TOTAL)=0/) && substr(line, RLENGTH + 1, 1) !~ /[0-9A-Za-z_.]/) {
        nseg = split(line, seg, /;/)
        for (si = 1; si <= nseg; si++) {
          s = seg[si]
          sub(/^[ \t]+/, "", s)
          if (match(s, /^(PASS|FAIL|TOTAL)=0/) && substr(s, RLENGTH + 1, 1) !~ /[0-9A-Za-z_.]/)
            print "TOPSET " substr(s, 1, index(s, "=") - 1)
        }
      }

      # A DEFINITION, AND THEN THE REST OF THE LINE. The `name()` head is cut
      # off and what follows falls through to the tokeniser, because a
      # definition written on ONE line carries its whole body there —
      #   eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "..."; fi; }
      # — and a scanner that stopped at the head derived nothing from it. 45
      # framework call sites in 14 suites were invisible that way. All ~150
      # assertions of session-start.test.sh route through three such wrappers,
      # and that suite scanned as ZERO calls (review-a A-2).
      #
      # BOTH SYNTAXES BASH ACCEPTS (critic K-1). `function name { ... }` and
      # `function name() { ... }` define a function exactly as `name()` does,
      # and the POSIX-only test read neither: a suite spelling its private ok as
      # `function ok {` produced no DEF and no TOPDEF, so the wall had nothing
      # to match and the runner launched it. Nothing in the tree exploits that
      # today, which is what makes it a hole rather than a lie.
      isdef = 0
      if (match(line, /^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*\(\))?/)) {
        rs = RSTART; rl = RLENGTH
        d = substr(line, rs, rl)
        sub(/^[ \t]*function[ \t]+/, "", d)
        gsub(/[^A-Za-z0-9_]/, "", d)
        isdef = 1
        istop = (line ~ /^function[ \t]/)
      } else if (match(line, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/)) {
        rs = RSTART; rl = RLENGTH
        d = substr(line, rs, rl)
        gsub(/[^A-Za-z0-9_]/, "", d)
        isdef = 1
        istop = (line ~ /^[A-Za-z_]/)
      }
      if (isdef) {
        print "DEF " d
        if (istop) print "TOPDEF " d
        line = substr(line, rs + rl)
      }

      gsub(/[;()&|{}]/, " \001 ", line)
      n = split(line, w, /[ \t]+/)
      prev = "\001"
      for (i = 1; i <= n; i++) {
        t = w[i]
        if (t == "") continue
        if (prev == "\001" || prev == "then" || prev == "else" || prev == "elif" \
            || prev == "do" || prev == "if" || prev == "while" || prev == "until" || prev == "!") {
          if (t ~ /^(ok|no|expect_[a-z_]+|anchor)$/) print "CALL " t
          else if (t == "finish") print "USES finish"
        }
        prev = t
      }
      hd = pending
    }
  ' "$1"
}

# ── the adoption wall's rule (S10, spec AC-12) ───────────────────────────────
#
# THE RULE. A suite is refused when its source carries, at COLUMN 0 and outside
# any heredoc body, a definition of a name THIS FILE owns, or a counter reset
# (`PASS=0` / `FAIL=0` / `TOTAL=0`). The refusal is the runner's — tests/run.sh
# calls `_tf_adoption_refusal` before it launches a suite — and the rule lives
# here, beside the scanner it reads and the names it protects.
#
# WHY COLUMN 0 (A-29). A top-level definition REPLACES the framework's function
# for the whole suite; an indented or subshell-scoped one cannot. The standing
# example is tests/dispatch-preflight.test.sh r24e, which redefines ok/no and the
# counters inside a `( … )` to prove expect_eq's failure path is not vacuous —
# a legitimate probe that shadows by necessity, and one this wall must not
# refuse.
#
# THE TWO EXEMPTIONS, therefore:
#   - an INDENTED or SUBSHELL-SCOPED redefinition (r24e's probe);
#   - a definition inside a HEREDOC BODY (A-10b) — tests/framework.test.sh
#     plants suites carrying `ok()`, `no()` and `PASS=0` through heredocs, so a
#     scanner that read heredoc bodies would refuse the framework's own suite
#     first.
# A suite-specific helper under a name this file does NOT own is not shadowing
# and stays legal (A-16): `expect_finding`, `expect_audit_line` and the other
# 24 one-offs are built on ok/no and belong to the suite that needs them.
#
# AND THE OTHER HALF: A SUITE MUST ADOPT (critic K-7). Refusing a shadow is only
# half of "one framework, adopted by every suite". Nothing required a roster
# suite to source this file or to call `finish`, so a suite spelling its helpers
# `t_ok`/`t_no` and its counters `P`/`F`, printing its own tally, passed the
# wall untouched — the exact state AC-12 exists to make impossible, while §13's
# `0 refused` read as proof it already was. That every suite adopted was once only
# a measurement (the migration slices' one-time greps), not a mechanism.
# It is a mechanism now.

# _tf_owned_names — the names this framework owns. READ FROM THIS FILE at call
# time, never hand-listed: every `expect_*` it defines at column 0, plus the six
# structural names. A helper added below is owned the moment it is written.
_tf_owned_names() {
  awk '/^expect_[a-z_]+\(\)/ { n = $0; sub(/\(\).*/, "", n); print n }' "$_TF_LIB"
  printf '%s\n' ok no section setup_section finish anchor
}

# _tf_adoption_refusal <suite> — prints ONE line naming the suite, the shadowed
# names and this file, when <suite> breaks the rule above; prints nothing and
# returns 0 when it does not. A suite that cannot be read is not judged: the
# runner is about to fail it for a reason it can state better.
_tf_adoption_refusal() {
  local suite="${1:-}" scan owned shadowed bad="" name unadopted=""
  [ -n "$suite" ] && [ -f "$suite" ] && [ -r "$suite" ] || return 0
  scan="$(_tf_scan "$suite")"
  owned=" $(_tf_owned_names | sort -u | tr '\n' ' ')"
  shadowed="$(printf '%s\n' "$scan" | sed -n 's/^TOPDEF //p' | sort -u)"
  for name in $shadowed; do
    case "$owned" in *" $name "*) bad="$bad ${name}()" ;; esac
  done
  for name in $(printf '%s\n' "$scan" | sed -n 's/^TOPSET //p' | sort -u); do
    bad="$bad ${name}=0"
  done
  if [ -n "$bad" ]; then
    printf '%s defines%s at column 0 — the framework owns those names: %s\n' \
      "$suite" "$bad" "$_TF_LIB"
    return 0
  fi
  # THE ADOPTION HALF, ASKED SECOND (critic K-7). Shadowing is reported first
  # because it is the more specific finding and the one a reader fixes first; a
  # suite can be in both states and one line is enough to refuse it.
  case "$scan" in
    *"SOURCES assert.sh"*) : ;;
    *) unadopted="does not source the framework" ;;
  esac
  if [ -z "$unadopted" ]; then
    case "$scan" in
      *"USES finish"*) : ;;
      *) unadopted="never calls finish" ;;
    esac
  fi
  [ -n "$unadopted" ] || return 0
  printf '%s %s — every gating suite is a client of it, and a suite that is not reports its own verdict on its own terms: %s\n' \
    "$suite" "$unadopted" "$_TF_LIB"
}

# The load-time derivation (AC-14). Runs once, here, for whatever suite sourced
# this file. A suite the framework cannot read cannot be certified by it, so an
# unreadable $0 is an error and not a silent skip.
#
# WHAT IT CAN AND CANNOT SEE (Step-5 audit §5.1, substance finding 1). It derives
# the FRAMEWORK'S OWN name family and nothing else: `_tf_scan` records a CALL
# only for `ok`, `no`, `anchor` and `expect_[a-z_]+` — lower-case and underscores,
# so `expect_case2` is outside it too. A suite that calls a vanished helper under
# any other name is invisible here. The walk demonstrated the consequence live:
# an undefined `walk_vanished_helper` inserted above `finish` left
# docs-pins.test.sh reporting `107/107 passed, 0 failed`, rc=0, with the
# diagnostic only on stderr.
#
# SO A HAND-RUN HAS INTERPRETER PARITY, NOT VERDICT PARITY. AC-2 makes the
# hand-run a first-class path by re-executing it under /bin/bash
# (tests/lib/resolve-roots.sh). What it does NOT give it is the runner's
# stderr-strict arm, which is what catches that class at RUNTIME — under
# `tests/run.sh` the suite above is red; typed at a prompt, nothing says so. That
# is a boundary neither AC-2 nor AC-14 states, and a reader debugging by hand
# should know which half of the verdict they are getting.
_tf_require_derived_helpers() {
  local src="$1" scan calls defs name missing=""
  if [ ! -f "$src" ] || [ ! -r "$src" ]; then
    echo "assert.sh: cannot read the suite source '$src' to derive its helper calls" >&2
    exit 1
  fi
  scan="$(_tf_scan "$src")"
  calls="$(echo "$scan" | sed -n 's/^CALL //p' | sort -u)"
  defs="$(echo "$scan" | sed -n 's/^DEF //p' | sort -u)"
  for name in $calls; do
    type -t "$name" >/dev/null 2>&1 && continue
    # A HERESTRING, not `echo | grep -q` — the form this file bans twice, at :100
    # and :332, and the form it was written in on the load path of every suite
    # (review-a A-6). Harmless today, since $defs is a few hundred bytes of the
    # suite's own function names, and wrong in the file that says so.
    grep -qx -- "$name" <<<"$defs" && continue
    missing="$missing $name"
  done
  if [ -n "$missing" ]; then
    echo "assert.sh: helper called but never defined:$missing" >&2
    echo "assert.sh: derived from the calls in $src — define it in the suite, or fix the call." >&2
    exit 1
  fi
}

# THE DERIVATION IS FOR SUITES. tests/run.sh sources this file too — for the
# scanner the adoption wall reads (S10) — and it is not a suite: it has no
# assertion calls to derive, and dying at its load would take the whole run with
# it. The runner is the ONE exception, recognised by its own name, so nothing in
# the environment can turn this off for a suite.
case "${0##*/}" in
  run.sh) : ;;
  *)      _tf_require_derived_helpers "${0:-}" ;;
esac
