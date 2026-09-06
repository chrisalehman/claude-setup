#!/bin/bash
# tests/framework.test.sh — the test framework's own suite (wave-01
# verification-cannot-lie S1; spec AC-13, AC-14, AC-15).
#
# WHAT IT COVERS. tests/lib/assert.sh is the one thing in this tree that decides
# whether a result exists at all, so it is the one thing that cannot be certified
# by the same mechanism it certifies. Every row here plants a scratch suite in a
# sandbox, runs it under the real framework, and reads the verdict the framework
# produced:
#
#   §1  a section that closes with zero assertions FAILS naming that section,
#       and a section that asserted is NOT named (AC-13)
#   §2  setup_section is exempt, and the tally counts it separately (AC-13)
#   §3  a called-but-undefined helper is red AT LOAD, naming it — the r24e shape,
#       which the pre-framework harness reported as a green suite (AC-14)
#   §4  the derivation does not over-fire: a helper the suite defines for itself
#       is exempt, and a helper name inside a heredoc body is not a call site
#   §5  finish exits by FAIL, and the tally line carries sections=N setup=M
#   §6  the counters and the assertion helpers are defined by the framework
#   §7  the assertion-discipline docblock carries its two obligations
#   §8  tests/run.sh registers this suite
#   §9  the thirteen generic expect_* helpers are the framework's, each in a
#       passing and a failing arm (AC-12)
#   §10 expect_regex is an ERE and is not a pipeline (the 141 false FAIL)
#   §11 anchor: a moved mutation anchor is red BEFORE the mutation runs,
#       naming the anchor and the count it actually found (AC-29, AC-31)
#
# HERMETIC. Every planted suite is written into a mktemp'd sandbox holding a COPY
# of the real tests/lib/assert.sh and is run as a child process; nothing here
# edits the repo, and no row reads a live install.
#
# Usage: bash tests/framework.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
FRAMEWORK="${REPO}/tests/lib/assert.sh"

SB="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/framework-test.XXXXXX")" && pwd)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/tests/lib"
cp "$FRAMEWORK" "$SB/tests/lib/assert.sh"

# ---------- local, non-assertion helpers ----------
#
# This suite deliberately defines NO ok/no/expect_* of its own: it is the
# framework's first pure client, and the shape S5-S9 migrate the other suites
# into. `contains` and `plant_run` are plumbing, not assertions.

contains() {  # contains <haystack> <needle> -> yes|no
  case "$1" in
    *"$2"*) echo yes ;;
    *)      echo "no" ;;
  esac
}

P_OUT=""
P_RC=""
plant_run() {  # plant_run <suite-basename> -> sets P_OUT / P_RC
  P_OUT="$(cd "$SB" && bash "tests/$1" 2>&1)"
  P_RC=$?
}

# ---------- planted suites ----------
#
# Written through heredocs. §4 asserts that the framework's own derivation does
# NOT read a heredoc body as a call site — which is what lets this file mention
# an undefined helper by name without dying at its own load.
#
# Declared as a setup section, which is also this suite's own use of the
# exemption §2 tests: a block that builds fixtures and asserts nothing says so.

setup_section "plant the scratch suites"

cat > "$SB/tests/p-empty.test.sh" <<'PLANT_EMPTY'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

section "the probe fires"
:

section "the probe records"
ok "a real row"

finish
PLANT_EMPTY

cat > "$SB/tests/p-setup.test.sh" <<'PLANT_SETUP'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

setup_section "build the fixture"
:

section "the fixture answers"
ok "a real row"

finish
PLANT_SETUP

cat > "$SB/tests/p-undefined.test.sh" <<'PLANT_UNDEFINED'
#!/bin/bash
# The r24e shape, verbatim: a suite in the pre-framework idiom (its own counters,
# its own ok/no, no -e) calling an assertion helper that is defined nowhere.
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

PASS=0
FAIL=0
TOTAL=0
ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo "PASS: $1"; }
no() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); echo "FAIL: $1"; return 0; }

ok "a real row"
expect_nope "the row that asserts nothing" ""
ok "another real row"

echo "TOTAL=$TOTAL PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
PLANT_UNDEFINED

cat > "$SB/tests/p-selfdef.test.sh" <<'PLANT_SELFDEF'
#!/bin/bash
# A helper the suite defines for ITSELF, below the source line — the shape
# tests/dispatch-preflight.test.sh and tests/stop-guard.test.sh are in today.
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

expect_mine() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "mismatch"; fi; }

section "a self-defined helper loads"
expect_mine "the row runs" a a

finish
PLANT_SELFDEF

cat > "$SB/tests/p-heredoc.test.sh" <<'PLANT_HEREDOC'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

cat > /dev/null <<'INNER'
expect_never_defined "this is content, not a call" ""
INNER

section "a heredoc body is not a call site"
ok "the suite loaded"

finish
PLANT_HEREDOC

cat > "$SB/tests/p-fail.test.sh" <<'PLANT_FAIL'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

section "a section with a real failure"
ok "one that passes"
no "one that fails"

finish
PLANT_FAIL

cat > "$SB/tests/p-nosection.test.sh" <<'PLANT_NOSECTION'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

ok "an assertion outside any section still counts"
expect_eq "expect_eq passes on equal values" x x
expect_empty "expect_empty passes on an empty value" ""

finish
PLANT_NOSECTION

cat > "$SB/tests/p-counters.test.sh" <<'PLANT_COUNTERS'
#!/bin/bash
# Defines no counters of its own; `set -u` makes an undefined one an abort.
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

echo "COUNTERS PASS=$PASS FAIL=$FAIL TOTAL=$TOTAL"

section "the framework's counters move"
ok "a real row"

finish
PLANT_COUNTERS

cat > "$SB/tests/p-negatives.test.sh" <<'PLANT_NEGATIVES'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

section "the negative arms of the two framework assertions"
expect_eq "expect_eq fails on unequal values" wanted got
expect_empty "expect_empty fails on a non-empty value" "something"

finish
PLANT_NEGATIVES

# The generic family (S1b): one planted suite whose ONLY assertions are the
# eleven canonical helpers in their PASSING form, and one whose only assertions
# are the same eleven in their FAILING form. Together they prove each helper
# reports through ok/no — the tallies move, and the section floor sees the rows.

cat > "$SB/tests/p-family-pass.test.sh" <<'PLANT_FAMILY_PASS'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

section "the eleven generic helpers, passing arms"
expect_eq        "eq"        same same
expect_ne        "ne"        wanted other
expect_true      "true"      test 1 -eq 1
expect_false     "false"     test 1 -eq 2
expect_contains  "contains"  "need" "a needle here"
expect_absent    "absent"    "haystalk" "a needle here"
expect_match     "match"     '*need*'  "a needle here"
expect_no_match  "no_match"  '*straw*' "a needle here"
expect_status    "status"    0 0
expect_empty     "empty"     ""
expect_nonempty  "nonempty"  "x"
expect_regex     "regex"     'need[a-z]+' "a needle here"
expect_no_regex  "no_regex"  'straw[0-9]+' "a needle here"

finish
PLANT_FAMILY_PASS

cat > "$SB/tests/p-family-fail.test.sh" <<'PLANT_FAMILY_FAIL'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

section "the eleven generic helpers, failing arms"
expect_eq        "eq"        wanted got
expect_ne        "ne"        same same
expect_true      "true"      test 1 -eq 2
expect_false     "false"     test 1 -eq 1
expect_contains  "contains"  "straw" "a needle here"
expect_absent    "absent"    "need"  "a needle here"
expect_match     "match"     '*straw*' "a needle here"
expect_no_match  "no_match"  '*need*'  "a needle here"
expect_status    "status"    0 1
expect_empty     "empty"     "loud"
expect_nonempty  "nonempty"  ""
expect_regex     "regex"     'straw[0-9]+' "a needle here"
expect_no_regex  "no_regex"  'need[a-z]+' "a needle here"

finish
PLANT_FAMILY_FAIL

# expect_true/expect_false SILENCE the command they run (the tree's majority, 17
# of 20 and 6 of 9). This plant proves that: the command writes to stdout and to
# stderr, and neither reaches the suite's output.
cat > "$SB/tests/p-family-silent.test.sh" <<'PLANT_FAMILY_SILENT'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

noisy() { echo "NOISE-ON-STDOUT"; echo "NOISE-ON-STDERR" >&2; return "$1"; }

section "the command's own output does not reach the suite"
expect_true  "true silences a noisy success" noisy 0
expect_false "false silences a noisy failure" noisy 1

finish
PLANT_FAMILY_SILENT

# --- §11's plants (S19, AC-29/AC-31). The fixture lives beside the planted
# suites so a quoted heredoc can name it without expanding anything here.
cat > "$SB/anchor-fx.txt" <<'PLANT_ANCHOR_FX'
a needle here
line 1
line 2
PLANT_ANCHOR_FX

cat > "$SB/tests/p-anchor.test.sh" <<'PLANT_ANCHOR'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

FX="$(dirname "$0")/../anchor-fx.txt"

section "anchor, both arms"
anchor    "$FX" 'needle' 1
anchor -E "$FX" '^line [0-9]+$' 2
anchor    "$FX" '^line [0-9]+$' 2
anchor    "$FX" 'needle' 2
anchor    "$FX" 'moved-away' 1
anchor    "$(dirname "$0")/../no-such-fixture.txt" 'needle' 1
anchor    "$FX" 'line' 2

finish
PLANT_ANCHOR

# The ORDER plant (AC-29: the anchor fails BEFORE the doctoring step). The
# mutation here is a bare echo standing in for the `grep -v`/`sed` that would
# follow it in a real suite; the row must already be on stdout when it runs.
cat > "$SB/tests/p-anchor-order.test.sh" <<'PLANT_ANCHOR_ORDER'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

FX="$(dirname "$0")/../anchor-fx.txt"

section "the anchor precedes the mutation"
anchor "$FX" 'moved-away' 1
echo "MUTATION-RAN"
ok "the suite kept going after the red anchor"

finish
PLANT_ANCHOR_ORDER

# THE ANCHOR STRENGTH PLANT (A-35a, S19c). The drift fixture is anchor-fx.txt
# with ONE leading space on the anchored line — the shape 61b8ca8 produced by
# reindenting a call. A fixed-string anchor is a SUBSTRING test and still matches
# it; a whole-line mutation does not touch it. The -E form, given the mutation's
# own ^…$, is the one that says so.
cat > "$SB/anchor-drift.txt" <<'PLANT_ANCHOR_DRIFT'
a needle here
 line 1
line 2
PLANT_ANCHOR_DRIFT

cat > "$SB/tests/p-anchor-strength.test.sh" <<'PLANT_ANCHOR_STRENGTH'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"

FX="$(dirname "$0")/../anchor-drift.txt"

section "an anchor must match at least as strictly as its mutation"
# THE WEAK ANCHOR: fixed-string, and it is GREEN over the drifted line.
anchor "$FX" 'line 1' 1
# THE STRONG ONE: the mutation's own whole-line ERE, and it is RED.
anchor -E "$FX" '^line 1$' 1
# What the mutation itself does to that file, so the row above is not a claim
# about grep but about the mutant: a whole-line sed no-ops.
MUT="$(sed 's/^line 1$/MUTATED/' "$FX")"
if [ "$MUT" = "$(cat "$FX")" ]; then
  ok "the whole-line mutation is a no-op on the drifted file"
else
  no "the whole-line mutation is a no-op on the drifted file" "it changed something"
fi

finish
PLANT_ANCHOR_STRENGTH

# ============================================================
section "1: a section that asserts nothing fails by name (AC-13)"
# ============================================================

plant_run p-empty.test.sh
expect_eq "1: the planted suite exits 1" "1" "$P_RC"
expect_eq "1: …naming the section that asserted nothing" \
  "yes" "$(contains "$P_OUT" "FAIL: section asserted nothing: the probe fires")"
# PAIRED POSITIVE for the negative row below: the second section is present in
# the run, so its absence from the failure list is a discrimination and not an
# artefact of the section never having opened.
expect_eq "1: …and the section that DID assert ran" \
  "yes" "$(contains "$P_OUT" "PASS: a real row")"
expect_eq "1: …and is not itself named as empty" \
  "no" "$(contains "$P_OUT" "FAIL: section asserted nothing: the probe records")"
expect_eq "1: the tally counts both sections and the planted failure" \
  "p-empty.test.sh: 1/2 passed, 1 failed  sections=2 setup=0" \
  "$(printf '%s\n' "$P_OUT" | sed -n 's/^\(p-empty\.test\.sh: .*\)$/\1/p')"

# ============================================================
section "2: setup_section is exempt and is counted apart (AC-13)"
# ============================================================

plant_run p-setup.test.sh
expect_eq "2: the planted suite exits 0" "0" "$P_RC"
expect_eq "2: no section is reported as empty" \
  "no" "$(contains "$P_OUT" "section asserted nothing")"
expect_eq "2: …and the setup section did run" \
  "yes" "$(contains "$P_OUT" "── build the fixture (setup)")"
expect_eq "2: the tally separates sections from setup sections" \
  "p-setup.test.sh: 1/1 passed, 0 failed  sections=1 setup=1" \
  "$(printf '%s\n' "$P_OUT" | sed -n 's/^\(p-setup\.test\.sh: .*\)$/\1/p')"

# ============================================================
section "3: a called-but-undefined helper is red at load (AC-14)"
# ============================================================

plant_run p-undefined.test.sh
expect_eq "3: the planted suite exits 1" "1" "$P_RC"
expect_eq "3: …naming the helper it calls and nobody defines" \
  "yes" "$(contains "$P_OUT" "helper called but never defined: expect_nope")"
expect_eq "3: …and naming where the derivation read it from" \
  "yes" "$(contains "$P_OUT" "derived from the calls in tests/p-undefined.test.sh")"
# THE LIE THIS CLOSES: before the framework, this same file ran to completion —
# the undefined call was a stderr line, the rows around it passed, and the suite
# exited 0 (research-code-map §5.3). The refusal must happen at LOAD, before any
# row is recorded, or the suite still prints a tally nobody should trust.
expect_eq "3: …before a single row is recorded" \
  "no" "$(contains "$P_OUT" "PASS: a real row")"
expect_eq "3: …and before the suite prints its own tally" \
  "no" "$(contains "$P_OUT" "TOTAL=")"

# --- THE BOUNDARY THE DOCBLOCK NOW STATES (Step-5 audit §5.1) --------------
# The derivation sees the framework's own name family and nothing else, so a
# vanished helper under another name is caught at RUNTIME by the runner's
# stderr-strict arm and not at load. Demonstrated, not asserted from the
# docblock: the same undefined call under a derived name is red at load, and
# under a name outside the family is not.
cat > "$SB/tests/p-outside-family.test.sh" <<'PLANT_OUTSIDE'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"
section "a vanished helper outside the derived name family"
ok "the suite loaded and got this far"
walk_vanished_helper "gone"
finish
PLANT_OUTSIDE
plant_run p-outside-family.test.sh
expect_eq "3: a call outside the derived family does not stop the load" "0" "$P_RC"
expect_eq "3: …and the suite reports a clean tally in spite of it" "yes"   "$(contains "$P_OUT" "1/1 passed, 0 failed")"
expect_eq "3: …with the diagnostic only on stderr, which is the runner's half" "yes"   "$(contains "$P_OUT" "command not found")"
# PAIRED: the SAME shape under a derived name IS red at load.
cat > "$SB/tests/p-inside-family.test.sh" <<'PLANT_INSIDE'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"
section "a vanished helper inside the derived name family"
expect_vanished_helper "gone"
finish
PLANT_INSIDE
plant_run p-inside-family.test.sh
expect_eq "3: the same call under a DERIVED name is red at load" "1" "$P_RC"
expect_eq "3: …naming the helper" "yes"   "$(contains "$P_OUT" "helper called but never defined: expect_vanished_helper")"
# and the docblock says so, with a discriminating pin.
FAMDOC="$(tr '\n' ' ' < "$FRAMEWORK" | sed 's/#//g' | tr -s ' ')"
expect_eq "3: the framework says a hand-run has interpreter parity, not verdict parity" "yes"   "$(contains "$FAMDOC" "SO A HAND-RUN HAS INTERPRETER PARITY, NOT VERDICT PARITY")"
FAMDOC_STRIPPED="$(grep -v 'INTERPRETER PARITY, NOT VERDICT PARITY' "$FRAMEWORK" | tr '\n' ' ' | sed 's/#//g' | tr -s ' ')"
expect_eq "3: …and that pin discriminates" "no"   "$(contains "$FAMDOC_STRIPPED" "SO A HAND-RUN HAS INTERPRETER PARITY, NOT VERDICT PARITY")"

# ============================================================
section "4: the derivation does not over-fire"
# ============================================================

plant_run p-selfdef.test.sh
expect_eq "4: a helper the suite defines for itself is exempt (exit 0)" "0" "$P_RC"
expect_eq "4: …and its row ran" "yes" "$(contains "$P_OUT" "PASS: the row runs")"

plant_run p-heredoc.test.sh
expect_eq "4: a helper name inside a heredoc body is not a call site (exit 0)" "0" "$P_RC"
expect_eq "4: …and the suite below the heredoc ran" \
  "yes" "$(contains "$P_OUT" "PASS: the suite loaded")"
# PAIRED POSITIVE: the exemptions above are worth nothing unless the derivation
# still fires on this very sandbox for a name nobody defines. §3 proved the
# refusal; this proves the two exemptions are not the derivation being off.
expect_eq "4: …while an undefined name in the same sandbox still refuses" \
  "1" "$(cd "$SB" && bash tests/p-undefined.test.sh >/dev/null 2>&1; echo $?)"

# ============================================================
section "5: finish exits by FAIL and prints the tally"
# ============================================================

plant_run p-fail.test.sh
expect_eq "5: a suite with one failing row exits 1" "1" "$P_RC"
expect_eq "5: …and the tally reports it" \
  "p-fail.test.sh: 1/2 passed, 1 failed  sections=1 setup=0" \
  "$(printf '%s\n' "$P_OUT" | sed -n 's/^\(p-fail\.test\.sh: .*\)$/\1/p')"

plant_run p-nosection.test.sh
expect_eq "5: a suite with no sections at all exits 0" "0" "$P_RC"
expect_eq "5: …and its tally reports zero sections" \
  "p-nosection.test.sh: 3/3 passed, 0 failed  sections=0 setup=0" \
  "$(printf '%s\n' "$P_OUT" | sed -n 's/^\(p-nosection\.test\.sh: .*\)$/\1/p')"

plant_run p-negatives.test.sh
expect_eq "5: the negative arm of expect_eq and expect_empty fails (exit 1)" "1" "$P_RC"
expect_eq "5: …expect_eq names what it wanted and what it got" \
  "yes" "$(contains "$P_OUT" "expected 'wanted', got 'got'")"
expect_eq "5: …expect_empty names the value it was handed" \
  "yes" "$(contains "$P_OUT" "expected no output, got: something")"
expect_eq "5: …and both rows are counted as failures" \
  "p-negatives.test.sh: 0/2 passed, 2 failed  sections=1 setup=0" \
  "$(printf '%s\n' "$P_OUT" | sed -n 's/^\(p-negatives\.test\.sh: .*\)$/\1/p')"

# ============================================================
section "6: the framework owns the counters and the helpers"
# ============================================================

for _fn in section setup_section ok no finish require_helpers \
          expect_eq expect_ne expect_true expect_false expect_contains expect_absent \
          expect_match expect_no_match expect_status expect_empty expect_nonempty \
          expect_regex expect_no_regex; do
  expect_eq "6: the framework defines ${_fn}" "function" "$(type -t "$_fn")"
done
# The counters: a planted suite that defines none of its own reads all three
# under `set -u`, so an undefined counter would abort it rather than print.
plant_run p-counters.test.sh
expect_eq "6: the counters exist and start at zero without the suite defining them" \
  "yes" "$(contains "$P_OUT" "COUNTERS PASS=0 FAIL=0 TOTAL=0")"
expect_eq "6: …and the framework's ok() is what moves them" \
  "p-counters.test.sh: 1/1 passed, 0 failed  sections=1 setup=0" \
  "$(printf '%s\n' "$P_OUT" | sed -n 's/^\(p-counters\.test\.sh: .*\)$/\1/p')"

# ============================================================
section "6b: the head docblock describes the tree it heads (review-c C-1/C-2)"
# ============================================================
#
# It is the first paragraph an author writing suite 56 reads about ownership, and
# it said a private `ok()` was tolerated and that the wall was S10's future work.
# Both had been false since S10 landed. A docblock is not testable prose here —
# every claim below is re-derived from the shipped tree in the same run.

C1_DOC="$(tr '\n' ' ' < "$FRAMEWORK" | sed 's/#//g' | tr -s ' ')"
C1_REFUSED=0
C1_SUITES=0
for c1_f in "$REPO"/tests/*.test.sh; do
  C1_SUITES=$((C1_SUITES + 1))
  [ -n "$(_tf_adoption_refusal "$c1_f")" ] && C1_REFUSED=$((C1_REFUSED + 1))
done
# THE COUNT PIN IS RETIRED (fixit 1.5.1, D-1). The roster is tests/*.test.sh read
# at run time, so a suite count is stale the moment anyone adds a file, and a row
# pinning one tests the calendar. What is still worth holding is that the scan
# below read a real tree. The docblock's own "All 55" sentence is stale prose for
# the same reason and is T4's to correct — together with the needle two rows down,
# which quotes it.
expect_eq "6b: the docblock scan read the whole tree (not vacuous)" "yes" \
  "$([ "$C1_SUITES" -ge 40 ] && echo yes || echo no)"
expect_eq "6b: …and none of them carries a private definition" "0" "$C1_REFUSED"
expect_eq "6b: the docblock says all 55 are clients of this file" "yes" \
  "$(contains "$C1_DOC" "All 55 suites on the roster are clients of it")"
expect_eq "6b: …and that it does not DEFER to a private one" "yes" \
  "$(contains "$C1_DOC" "It does not DEFER")"
expect_eq "6b: …and the stale claim that 49 suites still carry one is gone" "no" \
  "$(contains "$C1_DOC" "49 of them do, on the day this is written")"
expect_eq "6b: …and the stale claim that migration is still S5-S9's job is gone" "no" \
  "$(contains "$C1_DOC" "migrating those suites is S5")"
# C-2: the two expect_match exceptions were migrated, so the docblock stops
# calling them migration work — re-derived from the two files it names.
expect_eq "6b: live-agents carries no expect_match call" "0" \
  "$(grep -c '^[[:space:]]*expect_match ' "$REPO/tests/live-agents.test.sh" | tr -d ' ')"
expect_eq "6b: resources carries none either" "0" \
  "$(grep -c '^[[:space:]]*expect_match ' "$REPO/tests/resources.test.sh" | tr -d ' ')"
# The needle is SINGLE-quoted: the docblock spells the helper in backticks, and
# in a double-quoted needle bash would run it as a command substitution.
expect_eq "6b: …and the docblock records that S9b renamed them" "yes" \
  "$(contains "$C1_DOC" 'were renamed onto `expect_regex` by S9b')"
expect_eq "6b: …not that they are still migration work" "no" \
  "$(contains "$C1_DOC" "outvoted 11 to 2 and are migration work")"

# ============================================================
section "7: the assertion-discipline docblock carries its obligations"
# ============================================================
#
# Two obligations the wave put in writing (A-9, the lossy-verdict class). They
# are pinned here because the docblock is where a suite author meets them: the
# framework file is what every migrated suite sources and reads.

# The docblock is comment-wrapped, so the pin reads it de-wrapped: comment marks
# dropped, newlines folded to spaces, runs of spaces squeezed. The pin is on the
# SENTENCE, not on where the wrap happens to fall.
DOC="$(tr '\n' ' ' < "$FRAMEWORK" | sed 's/#//g' | tr -s ' ')"
expect_eq "7: the lossy-render rule is stated" "yes" \
  "$(contains "$DOC" "assertion about a render that truncates needs a second, unlossy source, and a whole-render glob is not an assertion")"
expect_eq "7: the paired-positive rule is stated" "yes" \
  "$(contains "$DOC" "Every negative assertion needs a positive one")"
# PAIRED NEGATIVE: the two pins above discriminate — a framework file with the
# sentence taken out does not satisfy them.
DOC_STRIPPED="$(grep -v 'unlossy source' "$FRAMEWORK" | tr '\n' ' ' | sed 's/#//g' | tr -s ' ')"
expect_eq "7: …and the pin fails on a copy with the rule removed" "no" \
  "$(contains "$DOC_STRIPPED" "assertion about a render that truncates needs a second, unlossy source")"

# ============================================================
section "8: the runner's header points at the live width knob"
# ============================================================
#
# WHAT USED TO BE HERE. A registration pin — "tests/run.sh names this suite" —
# and a count pin comparing the roster's `run` lines against the glob. Both died
# with the hand list (fixit 1.5.1, D-1/D-3): the roster IS `tests/*.test.sh`, so
# membership is not a property a suite can lack, and a count of the roster
# against the directory now compares the directory with itself.
# tests/runner-roster.test.sh proves the derivation once, for the whole set.
#
# WHAT IS LEFT is the header's own prose about the width knob, which lives here
# because no other suite reads it.

RUNSH="$(cat "${REPO}/tests/run.sh")"
# C-4: the header named a retired input as the knob to reach for. Two other
# places in the same file say it is retired, one of them at runtime.
expect_eq "8: the header points at the live width knob" "yes" \
  "$(contains "$RUNSH" 'BIONIC_TEST_JOBS_CEILING` is there for a machine')"
expect_eq "8: …and not at the retired one" "no" \
  "$(contains "$RUNSH" 'BIONIC_TEST_JOBS is there for a machine')"
expect_eq "8: …while the file still says out loud that it is retired" "yes" \
  "$(contains "$RUNSH" 'BIONIC_TEST_JOBS` is retired as an input')"

# ============================================================
section "9: the generic expect family is the framework's (AC-12, S1b)"
# ============================================================
#
# A-16's decision: the framework OWNS the eleven generic assertion names, and a
# suite-specific helper under a name the framework does NOT own stays local. The
# rows below are the framework half. The wall that refuses a suite for shadowing
# an owned name is S10's, and is not asserted here.
#
# PAIRED, BY CONSTRUCTION. Every helper appears twice: once directly in this
# suite where its passing arm must produce a PASS row, and once inside a planted
# suite where its failing arm must produce a FAIL row. A helper that silently did
# nothing would move neither tally.

# --- passing arms, called directly: each of these adds one PASS to THIS suite
expect_eq       "9: expect_eq passes on equal values"              same     same
expect_ne       "9: expect_ne passes on differing values"          wanted   other
expect_true     "9: expect_true passes on a zero-exit command"     test 1 -eq 1
expect_false    "9: expect_false passes on a non-zero command"     test 1 -eq 2
expect_contains "9: expect_contains passes on a present substring" "need"   "a needle here"
expect_absent   "9: expect_absent passes on an absent substring"   "straw"  "a needle here"
expect_match    "9: expect_match passes on a matching glob"        '*need*' "a needle here"
expect_no_match "9: expect_no_match passes on a non-matching glob" '*straw*' "a needle here"
expect_status   "9: expect_status passes on the expected status"   0        0
expect_empty    "9: expect_empty passes on an empty value"         ""
expect_nonempty "9: expect_nonempty passes on a non-empty value"   "x"
expect_regex    "9: expect_regex passes on a matching ERE"            'need[a-z]+' "a needle here"
expect_no_regex "9: expect_no_regex passes on a non-matching ERE"     'straw[0-9]+' "a needle here"

# --- the passing arms move the PASS counter and satisfy the section floor
plant_run p-family-pass.test.sh
expect_eq "9: thirteen passing arms are thirteen PASS rows in one section" \
  "p-family-pass.test.sh: 13/13 passed, 0 failed  sections=1 setup=0" \
  "$(printf '%s\n' "$P_OUT" | sed -n 's/^\(p-family-pass\.test\.sh: .*\)$/\1/p')"
expect_eq "9: …so the section floor does not name that section empty" "no" \
  "$(contains "$P_OUT" "section asserted nothing")"
expect_eq "9: …and the passing suite exits 0" "0" "$P_RC"

# --- the failing arms move the FAIL counter: each helper calls no()
plant_run p-family-fail.test.sh
expect_eq "9: thirteen failing arms are thirteen FAIL rows" \
  "p-family-fail.test.sh: 0/13 passed, 13 failed  sections=1 setup=0" \
  "$(printf '%s\n' "$P_OUT" | sed -n 's/^\(p-family-fail\.test\.sh: .*\)$/\1/p')"
expect_eq "9: …and the failing suite exits 1" "1" "$P_RC"
for _fn in eq ne true false contains absent match no_match status empty nonempty regex no_regex; do
  expect_eq "9: expect_${_fn}'s failing arm printed its FAIL row by label" "yes" \
    "$(contains "$P_OUT" "FAIL: ${_fn}")"
done

# --- expect_true/expect_false silence the command they run
plant_run p-family-silent.test.sh
expect_eq "9: a noisy command under expect_true/expect_false still passes and fails" \
  "p-family-silent.test.sh: 2/2 passed, 0 failed  sections=1 setup=0" \
  "$(printf '%s\n' "$P_OUT" | sed -n 's/^\(p-family-silent\.test\.sh: .*\)$/\1/p')"
expect_eq "9: …and the command's stdout never reaches the suite output" "no" \
  "$(contains "$P_OUT" "NOISE-ON-STDOUT")"
expect_eq "9: …nor its stderr" "no" \
  "$(contains "$P_OUT" "NOISE-ON-STDERR")"

# --- the mapping table is IN the framework, because S5-S8 quote it from there
FAMDOC="$(tr '\n' ' ' < "$FRAMEWORK" | sed 's/#//g' | tr -s ' ')"
expect_eq "9: the docblock carries the old-spelling mapping table" "yes" \
  "$(contains "$FAMDOC" "expect_equal -> expect_eq")"
expect_eq "9: …including the ERE spelling, now a pure rename onto expect_regex" "yes" \
  "$(contains "$FAMDOC" "expect_matches -> expect_regex")"
expect_eq "9: …and the entry that is still NOT a rename (it takes a file)" "yes" \
  "$(contains "$FAMDOC" "expect_nomatch -> NOT a rename")"
FAMDOC_STRIPPED="$(grep -v 'expect_equal ->' "$FRAMEWORK" | tr '\n' ' ' | sed 's/#//g' | tr -s ' ')"
expect_eq "9: …and the pin discriminates on a copy with the row removed" "no" \
  "$(contains "$FAMDOC_STRIPPED" "expect_equal -> expect_eq")"

# ============================================================
section "10: expect_regex is an ERE, and it is not a pipeline (S1b phase 2)"
# ============================================================
#
# A-S1b-2 resolved as option 2: regex matching is generic, so the framework owns
# it rather than leaving eight suites to keep a private copy. Two things have to
# be true of it and are not true of expect_match, so they are asserted here and
# not inferred: it is a REGEX, and it does not run grep in a pipeline.

# --- it is an ERE, not a glob: quantifiers and alternation mean what they say
expect_regex    "10: a quantifier is a quantifier"        'mtime=[0-9]+' "target=x|mtime=1234"
expect_regex    "10: alternation and anchors work"        '(^|\|)v1(\||$)' "v1|target=x"
expect_no_regex "10: …and a non-matching ERE does not fire" 'mtime=[a-z]+' "target=x|mtime=1234"
# PAIRED NEGATIVE, the discriminating one: the glob helper reads the same pattern
# literally, so what expect_regex matches, expect_match must NOT.
expect_no_match "10: expect_match reads that same pattern as a literal glob" \
  'mtime=[0-9]+' "target=x|mtime=1234"

# --- it is unanchored: a substring ERE matches without needing .* on either side
expect_regex "10: the ERE is unanchored (no leading .* required)" 'needle' "a needle here"
expect_match "10: …whereas the glob helper needs the stars" '*needle*' "a needle here"

# --- it is not a pipeline. `producer | grep -q` exits 141 under pipefail once
# the producer outstrips the 64 KiB pipe buffer, because grep leaves early and
# the producer takes SIGPIPE. That is a FALSE FAIL, and it is how two suites
# spell their private expect_matches today.
BIG="$(yes abcdefghij | head -20000)"
expect_regex "10: a large value still matches (no SIGPIPE in the framework's form)" \
  'abcdefghij' "$BIG"
# The paired halves of the defect: the SAME pipeline, the SAME pattern, one small
# value and one large one. Small is correct; large reports failure on a value the
# pattern matches. The exact status is not pinned — it is 141 when printf dies by
# SIGPIPE and 1 when bash reports the write error instead, which varies with the
# producer, the size and whether a trap is installed (measured all three ways on
# this machine). What is stable, and what makes it a lie, is non-zero.
printf '%s\n' "abcdefghij" 2>/dev/null | grep -qE -- 'abcdefghij'
PIPE_SMALL=$?
printf '%s\n' "$BIG" 2>/dev/null | grep -qE -- 'abcdefghij'
PIPE_BIG=$?
expect_eq "10: the pipeline spelling is right on a small value" "0" "$PIPE_SMALL"
expect_ne "10: …and wrong on a large one, non-zero though the pattern matches" \
  "0" "$PIPE_BIG"

# --- AND NOWHERE ELSE IN THE FILE (review-a A-6) ----------------------------
# The ban is stated twice in the framework's own docblocks and was broken in the
# framework's own load path — `echo "$defs" | grep -qx` inside the AC-14
# derivation, on the path every suite crosses. A census, so a new one added
# tomorrow fails here rather than the day a producer outgrows the pipe buffer.
# The pattern is built at runtime so this row does not match itself.
# Comment lines are excluded because the ban is STATED in three of them; the
# census is about code. `grep -c` is not `grep -q`, so it reads to EOF and takes
# no SIGPIPE of its own.
F10_BANNED="$(printf '| %s -q' grep)"
F10_CODE="$(grep -v '^[[:space:]]*#' "$FRAMEWORK")"
expect_eq "10: no producer-into-grep -q in the framework's code" "0" \
  "$(printf '%s\n' "$F10_CODE" | grep -c -- "$F10_BANNED" | tr -d ' ')"
expect_eq "10: …and the ban is still stated in its docblocks" "3" \
  "$(grep -c -- "$F10_BANNED" "$FRAMEWORK" | tr -d ' ')"
expect_eq "10: …and the census can see one in code when there is one (not vacuous)" "1" \
  "$(printf 'echo "$x" %s -- "$y"\n' "$F10_BANNED" | grep -v '^[[:space:]]*#' | grep -c -- "$F10_BANNED" | tr -d ' ')"

# ============================================================
section "11: anchor — the precondition of a mutation (AC-29, AC-31, S19)"
# ============================================================
#
# A doctoring anchor is the `grep -v`/`sed` pattern a suite removes or rewrites
# to build a mutant. When that pattern MOVES, the mutant comes out byte-identical
# to the shipped file and every behavioural row below it goes green against a
# fixture that was never mutated. `anchor` is the row that says so, by name,
# before the mutation runs.
#
# PAIRED, BY CONSTRUCTION, the same shape as §9: each arm appears once here in
# its passing form (a PASS row in THIS suite) and once inside a planted suite in
# its failing form (a FAIL row read back out of that suite's output).

ANCHOR_FX="$SB/anchor-fx.txt"

# --- passing arms, called directly
anchor    "$ANCHOR_FX" 'needle' 1
anchor    "$ANCHOR_FX" 'line' 2
anchor -E "$ANCHOR_FX" '^line [0-9]+$' 2

# --- the failing arms, read back from the planted suite
plant_run p-anchor.test.sh
expect_eq "11: three anchors hold and four are red, in one section" \
  "p-anchor.test.sh: 3/7 passed, 4 failed  sections=1 setup=0" \
  "$(printf '%s\n' "$P_OUT" | sed -n 's/^\(p-anchor\.test\.sh: .*\)$/\1/p')"
expect_eq "11: …and the suite carrying a moved anchor exits 1" "1" "$P_RC"

# AC-29: the failing row NAMES THE ANCHOR — its pattern and the file it anchors.
expect_eq "11: a moved anchor is red by name (pattern and file)" "yes" \
  "$(contains "$P_OUT" "FAIL: anchor: moved-away matches 1 line(s) of anchor-fx.txt")"
# AC-29: …AND THE ACTUAL COUNT, which is what tells a reader it moved rather
# than that the mutation's consumer broke.
expect_eq "11: …and reports the actual count it found" "yes" \
  "$(contains "$P_OUT" "found 0 line(s)")"
expect_eq "11: a wrong count is red with that count, not just with zero" "yes" \
  "$(contains "$P_OUT" "FAIL: anchor: needle matches 2 line(s) of anchor-fx.txt")"
expect_eq "11: …naming the one line it actually found" "yes" \
  "$(contains "$P_OUT" "found 1 line(s)")"
# an anchor whose file is gone is red too, not silently zero
expect_eq "11: an unreadable anchored file is red naming the file" "yes" \
  "$(contains "$P_OUT" "FAIL: anchor: needle matches 1 line(s) of no-such-fixture.txt")"
expect_eq "11: …and says the file could not be read" "yes" \
  "$(contains "$P_OUT" "cannot read the anchored file")"

# --- the two matchers are different matchers, the same discriminator §10 uses:
# what the ERE form matches, the default fixed-string form must NOT.
expect_eq "11: the default form reads its pattern as a fixed string, not an ERE" "yes" \
  "$(contains "$P_OUT" "FAIL: anchor: ^line [0-9]+$ matches 2 line(s) of anchor-fx.txt")"

# THE DETAIL IS RIGHT IN BOTH DIRECTIONS (review-c C-7). Too FEW is the moved
# anchor; too MANY is the opposite failure, and one string covering both told a
# reader the mutation was a no-op when in fact it was about to rewrite two lines.
# Every red in p-anchor.test.sh is the too-FEW direction (0 or 1 found against a
# declared 1 or 2), so the plant below supplies the direction that fixture never
# produced: an anchor declaring 1 over a pattern that matches 2.
expect_eq "11: too FEW says the anchor moved" "yes" \
  "$(contains "$P_OUT" "the anchor MOVED, so the mutation below is a no-op")"
cat > "$SB/tests/p-anchor-over.test.sh" <<'PLANT_ANCHOR_OVER'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"
FX="$(dirname "$0")/../anchor-fx.txt"
section "an anchor that matches more than it declared"
anchor "$FX" 'line' 1
finish
PLANT_ANCHOR_OVER
plant_run p-anchor-over.test.sh
expect_eq "11: too MANY is red as well" "1" "$P_RC"
expect_eq "11: …and says the anchor matches MORE than it declared" "yes" \
  "$(contains "$P_OUT" "the anchor matches MORE than it declared, so the mutation below strips or rewrites lines it was never meant to touch")"
expect_eq "11: …and does NOT call an over-matching anchor a moved one" "no" \
  "$(contains "$P_OUT" "the anchor MOVED")"
expect_eq "11: …still reporting the count it actually found" "yes" \
  "$(contains "$P_OUT" "found 2 line(s)")"

# --- AC-29: the row is recorded BEFORE the mutation runs
plant_run p-anchor-order.test.sh
ANCHOR_ORDER_FAIL="$(printf '%s\n' "$P_OUT" | grep -n 'FAIL: anchor: moved-away' | head -1 | cut -d: -f1)"
ANCHOR_ORDER_MUT="$(printf '%s\n' "$P_OUT" | grep -n '^MUTATION-RAN$' | head -1 | cut -d: -f1)"
expect_nonempty "11: the order plant produced a red anchor row" "$ANCHOR_ORDER_FAIL"
expect_nonempty "11: …and reached the mutation that follows it" "$ANCHOR_ORDER_MUT"
expect_eq "11: the anchor's verdict is on stdout BEFORE the mutation runs" "yes" \
  "$([ -n "$ANCHOR_ORDER_FAIL" ] && [ -n "$ANCHOR_ORDER_MUT" ] && \
     [ "$ANCHOR_ORDER_FAIL" -lt "$ANCHOR_ORDER_MUT" ] && echo yes || echo "no")"
# …and it does not abort the suite: a red anchor is a diagnosis, not a stop.
expect_eq "11: a red anchor does not abort the suite" "yes" \
  "$(contains "$P_OUT" "PASS: the suite kept going after the red anchor")"

# --- THE ANCHOR STRENGTH RULE (A-35a, S19c) ---------------------------------
# An anchor is only a precondition if it fails wherever the mutation would
# no-op. A FIXED-STRING anchor is a substring test, so it stays GREEN over a line
# that drifted by one leading space, while the whole-line `sed 's/^…$/…/'` it
# precedes does nothing to that line — and every behavioural row beneath then
# reads the shipped file. That is the S19c hole, and it is pinned here rather
# than left as a sentence, because the sentence is what was missing.
plant_run p-anchor-strength.test.sh
expect_eq "11: the strength plant ran its three rows in one section" \
  "p-anchor-strength.test.sh: 2/3 passed, 1 failed  sections=1 setup=0" \
  "$(printf '%s\n' "$P_OUT" | sed -n 's/^\(p-anchor-strength\.test\.sh: .*\)$/\1/p')"
expect_eq "11: a fixed-string anchor stays GREEN over a one-space drift" "yes" \
  "$(contains "$P_OUT" "PASS: anchor: line 1 matches 1 line(s) of anchor-drift.txt")"
expect_eq "11: …while the whole-line ERE anchor goes red on the same file" "yes" \
  "$(contains "$P_OUT" "FAIL: anchor: ^line 1$ matches 1 line(s) of anchor-drift.txt")"
expect_eq "11: …and the mutation the strong anchor guards really is a no-op there" "yes" \
  "$(contains "$P_OUT" "PASS: the whole-line mutation is a no-op on the drifted file")"
# PAIRED POSITIVE: on the UNDRIFTED fixture the same whole-line ERE holds, so the
# red above is the drift and not a pattern that could never match.
anchor -E "$ANCHOR_FX" '^line 1$' 1

# --- the docblock carries the reason, and the pin discriminates
ANCHORDOC="$(tr '\n' ' ' < "$FRAMEWORK" | sed 's/#//g' | tr -s ' ')"
expect_eq "11: the framework's docblock says why an anchor is a precondition" "yes" \
  "$(contains "$ANCHORDOC" "a mutation whose anchor moved is byte-identical to the shipped file")"
ANCHORDOC_STRIPPED="$(grep -v 'byte-identical to the shipped file' "$FRAMEWORK" | tr '\n' ' ' | sed 's/#//g' | tr -s ' ')"
expect_eq "11: …and that pin discriminates on a copy with the sentence removed" "no" \
  "$(contains "$ANCHORDOC_STRIPPED" "a mutation whose anchor moved is byte-identical to the shipped file")"
expect_eq "11: …and it states the strength rule the arm above demonstrates" "yes" \
  "$(contains "$ANCHORDOC" "THE ANCHOR MUST MATCH AT LEAST AS STRICTLY AS THE MUTATION")"
ANCHORDOC_STRIPPED2="$(grep -v 'AT LEAST AS STRICTLY' "$FRAMEWORK" | tr '\n' ' ' | sed 's/#//g' | tr -s ' ')"
expect_eq "11: …and that pin discriminates too" "no" \
  "$(contains "$ANCHORDOC_STRIPPED2" "THE ANCHOR MUST MATCH AT LEAST AS STRICTLY AS THE MUTATION")"

# ============================================================
setup_section "plant the adoption wall's scratch tree and its six suites (S10)"
# ============================================================
#
# THE WALL IS THE RUNNER'S, so it is proved by RUNNING the runner — against a
# scratch tree carrying the shipped tests/run.sh and the shipped framework, byte
# for byte, with a roster of six planted suites and nothing else. The real
# roster is never launched from here.
#
# ONE VIOLATION PER PLANT, so a refusal names what it refused rather than a
# soup. Every one of the six is a GREEN suite under the framework alone — that
# is what makes the three refusals the wall's doing and not the suite's own.

W_TREE="$SB/wall-tree"
W_MARKS="$SB/wall-marks"
mkdir -p "$W_TREE/tests/lib" "$W_TREE/payload/scripts/lib" "$W_MARKS"
cp "$REPO/tests/run.sh"                "$W_TREE/tests/run.sh"
cp "$REPO/tests/lib/resolve-roots.sh"  "$W_TREE/tests/lib/resolve-roots.sh"
cp "$FRAMEWORK"                        "$W_TREE/tests/lib/assert.sh"
cp "$REPO"/payload/scripts/lib/*.sh    "$W_TREE/payload/scripts/lib/" 2>/dev/null

# THE ROSTER NEEDS NO REWRITING ANY MORE (fixit 1.5.1). The runner derives it
# from the tests/ directory it is run in, so this scratch tree's roster is
# exactly the eight suites planted below and the shipped file is copied here
# byte for byte — one fewer difference between the runner under drive and the
# runner that ships.

# --- REFUSED (1/3): ok() at column 0 -----------------------------------------
cat > "$W_TREE/tests/w-ok.test.sh" <<'W_PLANT_OK'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"
: > "$S10_MARKS/w-ok.ran"

ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo "PASS: $1"; }

ok "the private ok() reported"

finish
W_PLANT_OK

# --- REFUSED (2/3): a name the framework owns, at column 0 -------------------
cat > "$W_TREE/tests/w-owned.test.sh" <<'W_PLANT_OWNED'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"
: > "$S10_MARKS/w-owned.ran"

expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "mismatch"; fi; }

expect_eq "the private expect_eq reported" x x

finish
W_PLANT_OWNED

# --- REFUSED (3/3): a counter at column 0 ------------------------------------
cat > "$W_TREE/tests/w-counter.test.sh" <<'W_PLANT_COUNTER'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"
: > "$S10_MARKS/w-counter.ran"

PASS=0

ok "a real row"

finish
W_PLANT_COUNTER

# --- REFUSED (4/4): a suite that adopts nothing at all (K-7) -----------------
# It shadows no owned name and resets no counter, so the shadowing half of the
# wall has nothing to say about it. It never calls finish: it reports its own
# verdict on its own terms, which is the state AC-12 exists to make impossible.
#
# WHY IT SOURCES THE FRAMEWORK ANYWAY (fixit 1.5.1). The wall has two adoption
# triggers — sourcing nothing, and never calling `finish` — and the first is now
# caught EARLIER, by the runner's roster wall, which refuses the whole run over a
# file in tests/ that sources the framework nowhere (proved in
# tests/runner-roster.test.sh). So the trigger reachable THROUGH the runner is
# the second one, and this plant drives that; `_tf_adoption_refusal` is asked
# about the first directly in §16.
cat > "$W_TREE/tests/w-unadopted.test.sh" <<'W_PLANT_UNADOPTED'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"
: > "$S10_MARKS/w-unadopted.ran"

P=0; F=0
t_ok() { P=$((P + 1)); echo "PASS: $1"; }
t_no() { P=$((P + 1)); echo "PASS: $1"; }

t_ok "a row that passed"
t_no "a row that failed, reported as a pass"
echo "w-unadopted.test.sh: 2/2 passed, 0 failed"
exit 0
W_PLANT_UNADOPTED

# --- LAUNCHED AND FAILED: a suite that asserts nothing (A-4) -----------------
# Not a wall case. This suite adopts the framework properly, shadows nothing and
# is launched — and it is a FAILURE because it covered nothing while reporting
# a result. Before the whole-suite floor it exited 0 and the runner printed
# ✓ PASS over `0/0 passed`.
cat > "$W_TREE/tests/w-empty.test.sh" <<'W_PLANT_EMPTY'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"
: > "$S10_MARKS/w-empty.ran"

setup_section "a fixture, and no assertion anywhere"
: > /dev/null

finish
W_PLANT_EMPTY

# --- NOT REFUSED (1/3): the same three definitions, inside a heredoc (A-10b) --
cat > "$W_TREE/tests/w-heredoc.test.sh" <<'W_PLANT_HEREDOC'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"
: > "$S10_MARKS/w-heredoc.ran"

cat > /dev/null <<'INNER'
ok() { echo "content, not a definition"; }
PASS=0
expect_eq() { echo "content, not a definition"; }
INNER

ok "a heredoc body is content, not a definition"

finish
W_PLANT_HEREDOC

# --- NOT REFUSED (2/3): the r24e subshell probe (A-29) -----------------------
cat > "$W_TREE/tests/w-indented.test.sh" <<'W_PLANT_INDENTED'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"
: > "$S10_MARKS/w-indented.ran"

(
  PASS=0; FAIL=0; TOTAL=0
  ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); }
  no() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); }
  expect_eq "probe" a a
  exit "$FAIL"
)
W_PROBE_RC=$?

expect_eq "a subshell-scoped shadow is a probe, not an adoption failure" "0" "$W_PROBE_RC"

finish
W_PLANT_INDENTED

# --- NOT REFUSED (3/3): a suite-specific name the framework does not own -----
cat > "$W_TREE/tests/w-local.test.sh" <<'W_PLANT_LOCAL'
#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/assert.sh"
: > "$S10_MARKS/w-local.ran"

expect_finding() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "mismatch"; fi; }

expect_finding "a suite-specific helper stays legal" x x

finish
W_PLANT_LOCAL

W_OUT=""
W_RC=0
w_drive() {  # run the scratch runner over the six planted suites
  W_OUT="$( cd "$W_TREE" && \
    S10_MARKS="$W_MARKS" \
    BIONIC_PRESSURE_RING="$SB/wall-ring" \
    BIONIC_NOW_EPOCH="1700000000" \
    BIONIC_TEST_JOBS_CEILING="2" \
    bash tests/run.sh 2>&1 )"
  W_RC=$?
}
w_drive

# ============================================================
section "12: the adoption wall refuses a shadowing suite, by name (AC-12, S10)"
# ============================================================

# NOT VACUOUS: the runner and the framework under drive are the shipped files.
expect_eq "12: the scratch runner is the shipped one, byte for byte" "yes" \
  "$(cmp -s "$REPO/tests/run.sh" "$W_TREE/tests/run.sh" && echo yes || echo no)"
expect_eq "12: …and it ran over exactly the eight suites planted in its tests/" "8" \
  "$(printf '%s\n' "$W_OUT" | sed -n 's/^  \(w-[a-z]*\.test\.sh\) .*/\1/p' | sort -u | grep -c .)"
expect_eq "12: the framework under drive is the shipped one, byte for byte" "yes" \
  "$(cmp -s "$FRAMEWORK" "$W_TREE/tests/lib/assert.sh" && echo yes || echo no)"

# --- the three refusals, each naming the suite and the shadowed name ---------
expect_eq "12: a private ok() at column 0 is refused, by name" "yes" \
  "$(contains "$W_OUT" "adoption wall: tests/w-ok.test.sh defines ok() at column 0")"
expect_eq "12: a private expect_eq() at column 0 is refused, by name" "yes" \
  "$(contains "$W_OUT" "adoption wall: tests/w-owned.test.sh defines expect_eq() at column 0")"
expect_eq "12: a private PASS=0 at column 0 is refused, by name" "yes" \
  "$(contains "$W_OUT" "adoption wall: tests/w-counter.test.sh defines PASS=0 at column 0")"
expect_eq "12: …and the refusal names the framework that owns the name" "yes" \
  "$(contains "$W_OUT" "the framework owns those names: $W_TREE/tests/lib/assert.sh")"
expect_eq "12: …and the verdict says refused, not failed-some-other-way" "yes" \
  "$(contains "$W_OUT" "✗ REFUSED (the adoption wall)")"
expect_eq "12: …and the failed list names the suite and says it never ran" "yes" \
  "$(contains "$W_OUT" "- w-ok.test.sh (refused by the adoption wall, never run)")"

# --- a refused suite is not run at all: its own marker never appears ---------
# PAIRED with the three markers below, which DO appear — so an absent marker is
# a suite that did not run, not a marker mechanism that never worked.
expect_eq "12: a refused suite never ran (no marker)" "no" \
  "$([ -f "$W_MARKS/w-ok.ran" ] && echo yes || echo no)"
expect_eq "12: …nor the second refused one" "no" \
  "$([ -f "$W_MARKS/w-owned.ran" ] && echo yes || echo no)"
expect_eq "12: …nor the third" "no" \
  "$([ -f "$W_MARKS/w-counter.ran" ] && echo yes || echo no)"

# --- the three exempt suites are launched and pass --------------------------
expect_eq "12: a definition inside a heredoc body is not a definition (A-10b)" "yes" \
  "$([ -f "$W_MARKS/w-heredoc.ran" ] && echo yes || echo no)"
expect_eq "12: a subshell-scoped shadow is exempt (A-29, the r24e probe)" "yes" \
  "$([ -f "$W_MARKS/w-indented.ran" ] && echo yes || echo no)"
expect_eq "12: a name the framework does not own stays legal (A-16)" "yes" \
  "$([ -f "$W_MARKS/w-local.ran" ] && echo yes || echo no)"
expect_eq "12: …and none of the three is named in a refusal" "no" \
  "$(contains "$W_OUT" "w-heredoc.test.sh defines")"
expect_eq "12: …nor the subshell one" "no" \
  "$(contains "$W_OUT" "w-indented.test.sh defines")"
expect_eq "12: …nor the suite-specific one" "no" \
  "$(contains "$W_OUT" "w-local.test.sh defines")"

# --- the tally and the exit status stay honest ------------------------------
expect_eq "12: the tally counts four refusals and one empty suite as five failures" "yes" \
  "$(contains "$W_OUT" "Gating: 3 passed, 5 failed")"
expect_eq "12: …and the run exits 1" "1" "$W_RC"

# --- ONE WALL, BOTH SCHEDULERS ----------------------------------------------
# A mode is a scheduling choice and nothing else (this runner's own header), so
# --serial must refuse the same three and report the same tally. The refusal
# path differs between the two — the queue is walked in one and not the other —
# which is exactly why both are driven.
W_SERIAL_OUT="$( cd "$W_TREE" && \
  S10_MARKS="$W_MARKS" \
  BIONIC_PRESSURE_RING="$SB/wall-ring" \
  BIONIC_NOW_EPOCH="1700000000" \
  BIONIC_TEST_JOBS_CEILING="2" \
  bash tests/run.sh --serial 2>&1 )"
W_SERIAL_RC=$?
expect_eq "12: --serial refuses the same suite, in the same words" "yes" \
  "$(contains "$W_SERIAL_OUT" "adoption wall: tests/w-ok.test.sh defines ok() at column 0")"
expect_eq "12: …and reaches the same tally" "yes" \
  "$(contains "$W_SERIAL_OUT" "Gating: 3 passed, 5 failed")"
expect_eq "12: …and the same exit status" "1" "$W_SERIAL_RC"

# ============================================================
section "13: every suite on the real roster passes the wall (AC-12, S10)"
# ============================================================
#
# The wall's own scan, over the tree as it stands. This is the adoption half of
# AC-12 read as a number: a suite added in the shape S5-S9 migrated away from
# fails here on the day it is written, not on the day someone reads it.

W_SCANNED=0
W_REFUSED=0
W_REFUSED_NAMES=""
for W_F in "$REPO"/tests/*.test.sh; do
  W_SCANNED=$((W_SCANNED + 1))
  W_R="$(_tf_adoption_refusal "$W_F")"
  if [ -n "$W_R" ]; then
    W_REFUSED=$((W_REFUSED + 1))
    W_REFUSED_NAMES="${W_REFUSED_NAMES} $(basename "$W_F")"
  fi
done
echo "   roster scanned: ${W_SCANNED} suites, ${W_REFUSED} refused${W_REFUSED_NAMES}"

expect_eq "13: the scan read the whole roster (not vacuous)" "yes" \
  "$([ "$W_SCANNED" -ge 40 ] && echo yes || echo no)"
expect_eq "13: no suite on the roster shadows the framework" "0" "$W_REFUSED"

# --- THE MUTATION ARM: the count moves when a shadow is planted -------------
# A scratch COPY of the roster's first suite, doctored with one flush-left
# definition. Without this row the zero above could be a scan that never fired.
W_VICTIM=""
for W_F in "$REPO"/tests/*.test.sh; do W_VICTIM="$W_F"; break; done
W_MUT="$SB/wall-mutant"
mkdir -p "$W_MUT"
# THE PRECONDITION OF THIS MUTATION (§11's idiom, AC-29). The plant below adds a
# flush-left ok() to a suite that must not already have one — if it did, the
# mutant would be indistinguishable from the shipped file and the count below
# would move for a reason that has nothing to do with the plant.
anchor -E "$W_VICTIM" '^ok\(\)' 0
{ echo '#!/bin/bash'; echo 'ok() { echo "planted shadow"; }'; cat "$W_VICTIM"; } \
  > "$W_MUT/$(basename "$W_VICTIM")"
W_MUT_REFUSED=0
for W_F in "$W_MUT"/*.test.sh; do
  [ -n "$(_tf_adoption_refusal "$W_F")" ] && W_MUT_REFUSED=$((W_MUT_REFUSED + 1))
done
expect_eq "13: the doctored copy differs from the suite it was made from" "no" \
  "$(cmp -s "$W_VICTIM" "$W_MUT/$(basename "$W_VICTIM")" && echo yes || echo no)"
expect_eq "13: one planted shadow moves the count from zero to one" "1" "$W_MUT_REFUSED"
expect_eq "13: …and the refusal names the planted name" "yes" \
  "$(contains "$(_tf_adoption_refusal "$W_MUT/$(basename "$W_VICTIM")")" "defines ok() at column 0")"

# ============================================================
section "14: the scanner reads the file bash reads (A-1/A-9)"
# ============================================================
#
# ONE SCANNER, TWO WALLS. `_tf_scan` is the single reader behind the adoption
# wall (AC-12) and the load-time derivation (AC-14), so a line it misreads takes
# BOTH out at once — and it does so silently, for every line to the end of the
# file. Four suites in this tree shipped in that state (git-argv, protect-main,
# canonical-sdlc-evidence-gate, cmd-class): each writes a `<<WORD` inside a
# quoted fixture string, and the textual matcher read it as a real opener.
#
# WHY THIS SECTION EXISTS WHEN §4 AND §12 ALREADY PLANT HEREDOCS. Both of those
# plant only WELL-FORMED openers that close, so the catch-proof never sampled
# the class that was live in the tree (review-a A-1, A-31c's shape). Every plant
# below is a file the shell parses as a definition and a call; the framework has
# to agree with the shell about that.

F14_D="$SB/scan14"
mkdir -p "$F14_D"

# EVERY PLANT BELOW IS A REALISTIC SUITE — it sources the framework and calls
# finish — so the ADOPTION half of the wall (§16) has nothing to say about it
# and each row isolates the scanner property it is there for.
f14_plant() {   # f14_plant <name> <line-that-must-not-open-a-heredoc>
  { printf '#!/bin/bash\n'
    printf '. "$(dirname "$0")/lib/assert.sh"\n'
    printf '%s\n' "$2"
    printf 'ok() { PASS=$((PASS + 1)); }\n'
    printf 'expect_fourteen_never_defined "x"\n'
    printf 'finish\n'
  } > "$F14_D/$1.sh"
}
f14_wall()  { _tf_adoption_refusal "$F14_D/$1.sh"; }
f14_deriv() { ( _tf_require_derived_helpers "$F14_D/$1.sh" ) >/dev/null 2>&1; echo $?; }

# --- the openers that are not openers ----------------------------------------
f14_plant quoted   'echo "see <<EOF for the format"'
f14_plant squoted  "printf '%s' 'run <<EOF to open one'"
f14_plant arith    'x=$(( 1 << 3 ))'
f14_plant subst    '_v="$(printf "cat <<EOF")"'
for f14_c in quoted squoted arith subst; do
  expect_contains "14: [$f14_c] a <<WORD that opens nothing leaves the wall awake" \
    "defines ok() at column 0" "$(f14_wall "$f14_c")"
  expect_eq "14: [$f14_c] …and leaves the derivation awake" "1" "$(f14_deriv "$f14_c")"
done

# --- PAIRED NEGATIVE: a REAL opener still hides its body ---------------------
# Without this row the four above could be a scanner that stopped skipping
# heredoc bodies altogether — which would refuse framework.test.sh itself first.
{ printf '#!/bin/bash\n'
  printf '. "$(dirname "$0")/lib/assert.sh"\n'
  printf 'cat > /dev/null <<%s\n' "'F14_INNER'"
  printf 'ok() { echo "content, not a definition"; }\n'
  printf 'expect_fourteen_never_defined "content, not a call"\n'
  printf 'F14_INNER\n'
  printf 'ok "a real row"\n'
  printf 'finish\n'
} > "$F14_D/realhd.sh"
expect_empty "14: a REAL heredoc body is still content, not code" "$(f14_wall realhd)"
expect_eq "14: …and the derivation does not fire on a call inside it" "0" "$(f14_deriv realhd)"

# --- a ONE-LINE definition carries its body on the same line (A-2) ----------
# `eq() { ...; ok "$1"; ... }` is where 45 framework call sites in 14 suites
# lived, session-start.test.sh among them: every one of its ~150 assertions
# routes through three such wrappers, and the suite scanned as ZERO calls.
# PLANTED THROUGH A HEREDOC, like every other fixture in this file: the body is
# content, so the scanner does not read this suite as calling the helper below.
cat > "$F14_D/oneline.sh" <<'F14_ONELINE'
#!/bin/bash
. "$(dirname "$0")/lib/assert.sh"
eq() { if [ "$2" = "$3" ]; then ok "$1"; else expect_oneline_never_defined "$1"; fi; }
eq "a row" x x
finish
F14_ONELINE
expect_eq "14: a call inside a one-line definition body is derived" "1" "$(f14_deriv oneline)"
expect_contains "14: …and the name it names is the one on that line" \
  "expect_oneline_never_defined" \
  "$( ( _tf_require_derived_helpers "$F14_D/oneline.sh" ) 2>&1 >/dev/null )"
# PAIRED: the definition itself is still recorded, so the fall-through did not
# cost the DEF/TOPDEF records the adoption wall reads.
cat > "$F14_D/onelinetop.sh" <<'F14_ONELINETOP'
#!/bin/bash
. "$(dirname "$0")/lib/assert.sh"
ok() { PASS=$((PASS + 1)); no "x" "y"; }
finish
F14_ONELINETOP
expect_contains "14: …and a one-line shadow is still a TOPDEF the wall refuses" \
  "defines ok() at column 0" "$(f14_wall onelinetop)"

# --- BOTH SYNTAXES BASH ACCEPTS (critic K-1) --------------------------------
# `function ok { ... }` defines ok exactly as `ok() { ... }` does. The POSIX-only
# definition test read neither `function` form, so a suite spelling its private
# ok that way produced no TOPDEF, the wall had nothing to match, and the runner
# launched it — and §13s `0 refused` was a census taken with the same blind
# scanner, which cannot tell "no suite shadows" from "no suite shadows in the
# one syntax we read".
cat > "$F14_D/fnkw.sh" <<'F14_FNKW'
#!/bin/bash
. "$(dirname "$0")/lib/assert.sh"
function ok { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
function no { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
finish
F14_FNKW
cat > "$F14_D/fnkwparen.sh" <<'F14_FNKWP'
#!/bin/bash
. "$(dirname "$0")/lib/assert.sh"
function expect_eq() { echo "every comparison is equal"; }
finish
F14_FNKWP
expect_contains "14: function ok { ... } is a shadow the wall refuses" \
  "defines no() ok() at column 0" "$(f14_wall fnkw)"
expect_contains "14: …and so is function name() { ... }" \
  "defines expect_eq() at column 0" "$(f14_wall fnkwparen)"
# PAIRED NEGATIVE: a function-keyword helper under a name the framework does not
# own is a DEF, not a shadow, and must not fire a false red at load (A-16).
cat > "$F14_D/fnkwlocal.sh" <<'F14_FNKWL'
#!/bin/bash
. "$(dirname "$0")/lib/assert.sh"
function expect_local_thing { ok "$1"; }
expect_local_thing "x"
finish
F14_FNKWL
expect_empty "14: a function-keyword helper the framework does not own stays legal" \
  "$(f14_wall fnkwlocal)"
expect_eq "14: …and the derivation counts it as defined" "0" "$(f14_deriv fnkwlocal)"

# --- no file in tests/ ends with a heredoc still open ------------------------
# NOT A COUNT PIN. The property that failed is "the scan reaches EOF", so that
# is what is asserted; counts move with every edit. The tracer runs the SHIPPED
# hdtag, lifted out of the framework by text, so it cannot drift from it.
awk '/^    function hdtag\(/,/^    \}$/' "$FRAMEWORK" > "$F14_D/hdtag.awk"
cat >> "$F14_D/hdtag.awk" <<'F14_TRACE'
hd != "" { if ($0 ~ ("^[ \t]*" hd "[ \t]*$")) hd = ""; next }
{ if ($0 ~ /^[ \t]*#/) next; hd = hdtag($0) }
END { if (hd != "") print hd }
F14_TRACE
expect_eq "14: the tracer is the shipped hdtag (not vacuous)" "1" \
  "$(grep -c 'function hdtag' "$F14_D/hdtag.awk")"
expect_eq "14: …and it still sees a real unterminated opener" "F14_UNCLOSED" \
  "$(printf 'cat <<F14_UNCLOSED\nbody\n' | awk -f "$F14_D/hdtag.awk")"

F14_BLIND=0
F14_BLIND_NAMES=""
for f14_f in "$REPO"/tests/*.test.sh "$REPO"/tests/lib/*.sh; do
  if [ -n "$(awk -f "$F14_D/hdtag.awk" "$f14_f")" ]; then
    F14_BLIND=$((F14_BLIND + 1))
    F14_BLIND_NAMES="${F14_BLIND_NAMES} $(basename "$f14_f")"
  fi
done
echo "   files whose scan ends inside a heredoc:${F14_BLIND_NAMES:- none}"
expect_eq "14: no file under tests/ ends with a heredoc still open" "0" "$F14_BLIND"

# ============================================================
section "15: a suite that asserted nothing is a failure (A-4)"
# ============================================================
#
# AC-13 closed lie class 3 per SECTION. A suite that opens none — or only
# setup_sections — had an empty `_TF_EMPTY`, FAIL=0, and exited 0; the runner
# judges on rc and printed ✓ PASS over `0/0 passed`, counting it toward
# `Gating: N passed`. THE FLOOR IS ASSERTIONS, NOT SECTIONS: loader.test.sh and
# patrol-marker.test.sh open no section and assert from the top level, and they
# are not this shape.

F15_D="$SB/floor15"
mkdir -p "$F15_D/lib"
cp "$REPO/tests/lib/resolve-roots.sh" "$F15_D/lib/resolve-roots.sh"
cp "$FRAMEWORK"                       "$F15_D/lib/assert.sh"
f15_plant() {   # f15_plant <name> <body-line>
  { printf '#!/bin/bash\n'
    printf 'set -uo pipefail\n'
    printf '. "$(dirname "$0")/lib/assert.sh"\n'
    printf '%s\n' "$2"
    printf 'finish\n'
  } > "$F15_D/$1.sh"
}
f15_run() { ( cd "$F15_D" && bash "$1.sh" 2>&1 ); }
f15_rc()  { ( cd "$F15_D" && bash "$1.sh" >/dev/null 2>&1 ); echo $?; }

f15_plant nothing   ':'
f15_plant setuponly 'setup_section "fixture only"'
f15_plant toplevel  'ok "one real row"'

expect_eq "15: a suite with no assertion at all exits 1" "1" "$(f15_rc nothing)"
expect_contains "15: …and says so by name" "FAIL: suite asserted nothing: nothing.sh" \
  "$(f15_run nothing)"
expect_contains "15: …and the failure is IN the tally, not beside it" "0/1 passed, 1 failed" \
  "$(f15_run nothing)"
expect_eq "15: a suite with only a setup_section exits 1 too" "1" "$(f15_rc setuponly)"
expect_contains "15: …and its setup is still counted apart" "sections=0 setup=1" \
  "$(f15_run setuponly)"
# THE PAIRED POSITIVE, and it is the whole reason the floor is TOTAL and not
# _TF_SECTIONS: two suites on the real roster assert from the top level.
expect_eq "15: a suite that opens no section but asserts is green" "0" "$(f15_rc toplevel)"
expect_contains "15: …with sections=0 on its tally" "1/1 passed, 0 failed  sections=0" \
  "$(f15_run toplevel)"
F15_TOPLEVEL=""
for f15_f in "$REPO/tests/loader.test.sh" "$REPO/tests/patrol-marker.test.sh"; do
  F15_TOPLEVEL="${F15_TOPLEVEL} $(grep -c '^section ' "$f15_f")"
done
expect_eq "15: the two real top-level suites still open no section" " 0 0" "$F15_TOPLEVEL"

# --- THROUGH THE RUNNER: the wall tree carries w-empty.test.sh ---------------
# It adopts the framework, shadows nothing, is LAUNCHED (its marker appears) and
# is counted failed — the state that used to read ✓ PASS.
expect_eq "15: the empty suite was launched, not refused" "yes" \
  "$([ -f "$W_MARKS/w-empty.ran" ] && echo yes || echo no)"
expect_eq "15: …and no refusal names it" "no" "$(contains "$W_OUT" "w-empty.test.sh defines")"
expect_eq "15: …and the runner reports it failed" "yes" \
  "$(contains "$W_OUT" "- w-empty.test.sh")"
expect_eq "15: …and its own line says what it failed for" "yes" \
  "$(contains "$W_OUT" "FAIL: suite asserted nothing: w-empty.test.sh")"

# ============================================================
section "16: the wall enforces ADOPTION, not only non-shadowing (K-7)"
# ============================================================
#
# Refusing a shadow is half of "one framework, adopted by every suite". The
# other half — that a roster suite sources the framework and calls finish — was
# a measurement the migration slices took once, and §13's `0 refused` read as
# proof of a wall that did not exist.

F16_D="$SB/adopt16"
mkdir -p "$F16_D"
f16_wall() { _tf_adoption_refusal "$F16_D/$1.sh"; }

cat > "$F16_D/nosource.sh" <<'F16_NOSOURCE'
#!/bin/bash
P=0; F=0
t_ok() { P=$((P + 1)); echo "ok: $1"; }
t_ok "my own row"
echo "1/1 passed"
exit 0
F16_NOSOURCE
cat > "$F16_D/nofinish.sh" <<'F16_NOFINISH'
#!/bin/bash
. "$(dirname "$0")/lib/assert.sh"
ok "a row"
exit 0
F16_NOFINISH
cat > "$F16_D/good.sh" <<'F16_GOOD'
#!/bin/bash
. "$(dirname "$0")/lib/assert.sh"
ok "a row"
finish
F16_GOOD

expect_contains "16: a suite that sources the framework nowhere is refused" \
  "does not source the framework" "$(f16_wall nosource)"
expect_contains "16: …and the refusal names the suite" "nosource.sh" "$(f16_wall nosource)"
expect_contains "16: a suite that never calls finish is refused" \
  "never calls finish" "$(f16_wall nofinish)"
# THE HEREDOC EXEMPTION HOLDS ON THIS HALF TOO: a `finish` written into a
# fixture is content, not a call, so writing one must not buy adoption.
cat > "$F16_D/heredocfinish.sh" <<'F16_HD'
#!/bin/bash
. "$(dirname "$0")/lib/assert.sh"
cat > /dev/null <<'F16_INNER'
finish
F16_INNER
ok "a row"
exit 0
F16_HD
expect_contains "16: a finish written into a heredoc does not count as calling it" \
  "never calls finish" "$(f16_wall heredocfinish)"
# PAIRED POSITIVE, and the roster census below is the real one.
expect_empty "16: a suite that sources it and calls finish is not refused" "$(f16_wall good)"

F16_SCANNED=0
F16_REFUSED=0
for f16_f in "$REPO"/tests/*.test.sh; do
  F16_SCANNED=$((F16_SCANNED + 1))
  [ -n "$(_tf_adoption_refusal "$f16_f")" ] && F16_REFUSED=$((F16_REFUSED + 1))
done
expect_eq "16: the census read the whole roster (not vacuous)" "yes" \
  "$([ "$F16_SCANNED" -ge 40 ] && echo yes || echo no)"
expect_eq "16: every suite on the roster adopts the framework" "0" "$F16_REFUSED"

# --- THROUGH THE RUNNER -----------------------------------------------------
expect_contains "16: the runner refuses the unadopted suite, by name" \
  "adoption wall: tests/w-unadopted.test.sh never calls finish" "$W_OUT"
expect_eq "16: …and it never ran (no marker)" "no" \
  "$([ -f "$W_MARKS/w-unadopted.ran" ] && echo yes || echo no)"
expect_eq "16: …and the verdict reads REFUSED" "yes" \
  "$(contains "$W_OUT" "- w-unadopted.test.sh (refused by the adoption wall, never run)")"
expect_contains "16: --serial refuses it in the same words" \
  "adoption wall: tests/w-unadopted.test.sh never calls finish" "$W_SERIAL_OUT"

finish
