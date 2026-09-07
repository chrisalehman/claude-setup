#!/bin/bash
# tests/impact.test.sh — the impacted-suite derivation, and its planted-edit proof.
# wave-01-verification-cannot-lie slice S12; spec AC-18 (the derivation) and
# AC-19 (completeness by planted edit).
#
# WHAT IS UNDER TEST. `tests/lib/impact.sh <file>...` prints the gating suites
# that read those files — one line per suite, `suite<TAB>reason`, sorted, no
# duplicates. It is the ONE owner of "this change affects that" (design ledger
# D2, "the tree owns impact"): the dispatch wall, the writer-side budget guard
# and the landing reconcile all ask this one question of this one program.
#
# THE EDGE KINDS, and where each comes from in the tree:
#
#   self              the file IS the suite
#   source            the suite sources the file (`. "$(dirname "$0")/lib/x.sh"`)
#   anchor            the suite doctors the file (`grep -v` / `sed` against it)
#   pin               the suite pins the file's text (`grep -q` / `has_pin`)
#   path-ref          the suite names the path, over the root aliases
#   payload-copy      the suite names the payload ROOT, so it reads every file
#                     under it (the ten whole-payload copiers, code map §1.4)
#   dir-ref           the suite names some other directory, same expansion
#   transitive-lib    the suite sources a tests/lib helper that reads the file
#   transitive-doctor payload/scripts/doctor.sh sources the file, and the suite
#                     reads doctor.sh (code map §3.5: one hop from the suite)
#   transitive-script the same rule for the other payload/scripts/*.sh
#
# WHY A FIXTURE TREE FOR THE EDGE KINDS (§A–§C). Asserting edge kinds against
# the real tree would pin this suite to whatever 51 suites happen to reference
# today: every unrelated edit to any suite would rewrite the expected sets, and
# an assertion nobody can re-derive by hand is a pin, not a test (memory
# "good-tests-doctrine"). So each edge kind is proved over a MINIATURE tree this
# suite builds and owns, where the whole dependency graph fits on a screen — and
# every positive is paired with a MUTATION that removes the edge and re-proves
# the same call goes empty (memory "no-vacuous-tests-at-authoring": a positive
# assertion alone cannot tell a real derivation from a program that prints
# everything).
#
# WHAT THE REAL TREE IS STILL ASKED (§D). Only facts a reader can re-derive from
# the code map by hand: docs-pins doctors session-poker.sh (§1.2 rows 5–6), all
# 51 suites source tests/lib/resolve-roots.sh (§3.5), the ten named suites read
# the whole payload (§1.4). Those are properties of the tree, cited to their
# measurement, not a snapshot of this program's output.
#
# THE PLANTED-EDIT PROOF (§F, opt-in). AC-19 asks for a completeness criterion
# that runs REAL suites against a mutated scratch tree and checks that the
# derived set is a superset of the suites that actually go red. That costs
# whole-roster runs — minutes, not the sub-second every other section takes — so
# it does not run in the gating roster. `BIONIC_IMPACT_PLANTED=1` runs it, and
# its authoring-time output is committed as the durable record at
# .bionic/docs/record/wave-verification-cannot-lie/s12-planted-edits.log
# (memory "red-evidence-is-perishable": the red counts die at green, the
# mutation-and-restore log does not).
#
# Usage: bash tests/impact.test.sh
#   BIONIC_IMPACT_PLANTED=1 bash tests/impact.test.sh    # + the §F proof
#   BIONIC_IMPACT_PLANTED_LOG=<path>                     # where §F writes

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
IMPACT="${REPO}/tests/lib/impact.sh"

# NO PRIVATE ASSERTION NAMES HERE (review-b B-6, folded in at Step 6). This suite
# once carried `pass`/`fail` wrappers over ok/no and `expect_has`/`expect_lacks`,
# which were argument-for-argument the framework's `expect_contains` and
# `expect_absent`. The adoption wall did not refuse them — it refuses only the
# exact names the framework OWNS — so the wave that removed 37 private spellings
# from 53 suites added four back in its own new suite. Worse, `_tf_scan` derives
# call tokens matching `ok|no|expect_[a-z_]+|anchor`: `pass` and `fail` are
# outside that set, so an undefined one would have slipped past the load-time
# derivation (AC-14) and surfaced only through the runner's stderr-strict arm.

# ── §0 the subject exists and parses ────────────────────────────────────────
# Nothing below can mean anything if the derivation is missing: an absent
# program makes every `$(... | grep ...)` empty, which is indistinguishable
# from a correct empty answer. Prove the subject first, and stop if it is gone.
section "§0 the subject"

if [ -f "$IMPACT" ]; then
  ok "tests/lib/impact.sh exists"
else
  no "tests/lib/impact.sh exists" "$IMPACT"
  finish
fi

if bash -n "$IMPACT" 2>/dev/null; then
  ok "tests/lib/impact.sh parses under bash -n"
else
  no "tests/lib/impact.sh parses under bash -n" "$(bash -n "$IMPACT" 2>&1)"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# suites() <root> <file>...   → the suite column, sorted, newline-separated
suites() {
  local root="$1"; shift
  BIONIC_IMPACT_ROOT="$root" bash "$IMPACT" "$@" 2>/dev/null | cut -f1
}
# reason_for() <root> <suite> <file>...   → the reason column for one suite
reason_for() {
  local root="$1" want="$2"; shift 2
  BIONIC_IMPACT_ROOT="$root" bash "$IMPACT" "$@" 2>/dev/null \
    | awk -F'\t' -v w="$want" '$1==w{print $2}'
}
# oneline() — the suite column as a single space-joined string, for expect_has
oneline() { suites "$@" | tr '\n' ' '; }

# ── the fixture tree ────────────────────────────────────────────────────────
# A whole repo in eleven files. Every edge kind the derivation claims is
# expressed exactly once here, so the expected sets below are readable off this
# block rather than off the program's output.
#
#   tests/a.test.sh   pins hooks/h1.sh                       → pin
#   tests/b.test.sh   sources tests/lib/helper.sh            → source
#                     …and helper.sh reads lib/run.sh        → transitive-lib
#   tests/c.test.sh   names the payload ROOT                 → payload-copy
#   tests/d.test.sh   doctors hooks/h1.sh via grep -v        → anchor
#   tests/e.test.sh   runs payload/scripts/doctor.sh         → transitive-doctor
#   tests/f.test.sh   pins tests/run.sh                      → pin
#   tests/g.test.sh   names the hooks DIRECTORY              → dir-ref
#   tests/h.test.sh   runs hooks/h3.sh, which sources
#                     payload/scripts/lib/hooklib.sh        → transitive-hook
#   payload/hooks is a symlink to ../hooks, as in the real tree.
mk_fixture() { # mk_fixture <dir>
  local fx="$1"
  mkdir -p "$fx/tests/lib" "$fx/hooks" "$fx/payload/scripts/lib"
  ln -s ../hooks "$fx/payload/hooks"

  printf '#!/bin/bash\necho h1\n' >"$fx/hooks/h1.sh"
  printf '#!/bin/bash\necho h2\n' >"$fx/hooks/h2.sh"
  printf '#!/bin/bash\necho width\n' >"$fx/payload/scripts/lib/width.sh"
  printf '#!/bin/bash\necho run\n' >"$fx/payload/scripts/lib/run.sh"
  printf '#!/bin/bash\necho hooklib\n' >"$fx/payload/scripts/lib/hooklib.sh"
  # h3 is the hook with a library of its own — the transitive-hook edge. It is a
  # SEPARATE hook from h1 and h2 so that adding it moves no set another row pins.
  printf '#!/bin/bash\nHOOK_LIB="$(dirname "$0")/../payload/scripts/lib"\n. "${HOOK_LIB}/hooklib.sh"\n' \
    >"$fx/hooks/h3.sh"
  printf '#!/bin/bash\nDOCTOR_LIB="$(dirname "$0")/lib"\n. "${DOCTOR_LIB}/width.sh"\n' \
    >"$fx/payload/scripts/doctor.sh"

  printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\n' >"$fx/tests/lib/resolve-roots.sh"
  printf '#!/bin/bash\n. "${BIONIC_SCRIPTS_DIR}/payload/scripts/lib/run.sh"\n' \
    >"$fx/tests/lib/helper.sh"

  printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\nREPO="${BIONIC_SCRIPTS_DIR}"\ngrep -q hello "${REPO}/hooks/h1.sh"\n' >"$fx/tests/a.test.sh"
  printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\n. "$(dirname "$0")/lib/helper.sh"\n' >"$fx/tests/b.test.sh"
  printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\nREPO="${BIONIC_SCRIPTS_DIR}"\nPAYLOAD="${REPO}/payload"\ncp -R "$PAYLOAD" "$TMP/p"\n' >"$fx/tests/c.test.sh"
  printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\ngrep -v drop "$BIONIC_HOOKS_DIR/h1.sh" >mutant\n' >"$fx/tests/d.test.sh"
  printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\nREPO="${BIONIC_SCRIPTS_DIR}"\nbash "${REPO}/payload/scripts/doctor.sh"\n' >"$fx/tests/e.test.sh"
  printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\ngrep -q pressure "${BIONIC_SCRIPTS_DIR}/tests/run.sh"\n' >"$fx/tests/f.test.sh"
  printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\nREPO="${BIONIC_SCRIPTS_DIR}"\nfor f in "$REPO/hooks"/*.sh; do echo "$f"; done\n' >"$fx/tests/g.test.sh"
  printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\nbash "$BIONIC_HOOKS_DIR/h3.sh"\n' >"$fx/tests/h.test.sh"

  {
    printf '#!/bin/bash\n'
    for s in a b c d e f g h; do
      printf 'run "%s.test.sh" bash tests/%s.test.sh\n' "$s" "$s"
    done
  } >"$fx/tests/run.sh"
}

FX="$TMP/fx"
mk_fixture "$FX"

# ── §A one edge kind at a time ──────────────────────────────────────────────
section "§A the edge kinds"

# self — a change to a suite reaches that suite, and no other. Without this the
# wall would let a writer edit a suite and never run it.
expect_eq "self: editing a suite derives that suite" \
  "a.test.sh" "$(suites "$FX" tests/a.test.sh)"

# source — b sources tests/lib/helper.sh; nothing else does.
expect_eq "source: the sourcing suite, and only it" \
  "b.test.sh" "$(suites "$FX" tests/lib/helper.sh)"
expect_eq "source: the reason is named" \
  "source" "$(reason_for "$FX" b.test.sh tests/lib/helper.sh | cut -d: -f1)"

# transitive-lib — helper.sh reads payload/scripts/lib/run.sh, so b reads it
# without naming it. The suite-level grep the code map warns about (§3.5) misses
# exactly this edge, which is why it has its own kind.
expect_contains "transitive-lib: the sourcing suite inherits its helper's reads" \
  "b.test.sh" "$(oneline "$FX" payload/scripts/lib/run.sh)"
expect_eq "transitive-lib: the reason is named" \
  "transitive-lib" "$(reason_for "$FX" b.test.sh payload/scripts/lib/run.sh | cut -d: -f1)"

# transitive-doctor — doctor.sh sources lib/width.sh; e runs doctor.sh and never
# names width.sh. This is the FIX_LINES_OTHER edge from code map §3.5.
expect_contains "transitive-doctor: a doctor.sh runner inherits doctor.sh's libs" \
  "e.test.sh" "$(oneline "$FX" payload/scripts/lib/width.sh)"
expect_eq "transitive-doctor: the reason is named" \
  "transitive-doctor" "$(reason_for "$FX" e.test.sh payload/scripts/lib/width.sh | cut -d: -f1)"

# payload-copy — c names the payload root, so every file under payload/ reaches
# it, including files reached only through payload/hooks' symlink.
expect_contains "payload-copy: a payload-root namer reads a file under payload/" \
  "c.test.sh" "$(oneline "$FX" payload/scripts/lib/run.sh)"
expect_contains "payload-copy: …and a file reached only through payload/hooks" \
  "c.test.sh" "$(oneline "$FX" hooks/h1.sh)"
expect_eq "payload-copy: the reason is named" \
  "payload-copy" "$(reason_for "$FX" c.test.sh hooks/h1.sh | cut -d: -f1)"

# anchor and pin — both are path references; the reason column separates them,
# because a moved anchor fails silently and a moved pin fails loudly (§1.1).
expect_eq "anchor: a grep -v doctoring is reported as an anchor" \
  "anchor" "$(reason_for "$FX" d.test.sh hooks/h1.sh | cut -d: -f1)"
expect_eq "pin: a grep -q is reported as a pin" \
  "pin" "$(reason_for "$FX" a.test.sh hooks/h1.sh | cut -d: -f1)"

# dir-ref — g globs the hooks directory. A per-file grep sees no filename here
# (code map §3.4 calls it "a glob, not a path"), so the directory expansion is
# the only thing that finds the edge.
expect_contains "dir-ref: a directory glob reaches every file under it" \
  "g.test.sh" "$(oneline "$FX" hooks/h2.sh)"
expect_eq "dir-ref: the reason is named" \
  "dir-ref" "$(reason_for "$FX" g.test.sh hooks/h2.sh | cut -d: -f1)"

# transitive-hook — h runs hooks/h3.sh and never names hooklib.sh. S12 added this
# edge kind AFTER the planted proof revealed that hooks were not owners, and it is
# the one kind §B never had a mutation row for: the Step-5 revert arm meant to fill
# that hole was VOID after two attempts (step5-audit.md §6), so the hole was open
# at the head this fold-in started from.
expect_contains "transitive-hook: a suite that runs a hook inherits the hook's libs" \
  "h.test.sh" "$(oneline "$FX" payload/scripts/lib/hooklib.sh)"
expect_eq "transitive-hook: the reason is named" \
  "transitive-hook" "$(reason_for "$FX" h.test.sh payload/scripts/lib/hooklib.sh | cut -d: -f1)"

# tests/run.sh — f pins it. This is the 33-suite registration-pin edge (§1.4).
expect_contains "pin: a tests/run.sh registration pin is an edge" \
  "f.test.sh" "$(oneline "$FX" tests/run.sh)"

# A DIRECTORY ARGUMENT COVERS ITS FILES (review-a A-3). The rule the docblock
# states for what a SUITE names was not applied to what the CALLER asks about,
# so `Files: tests/lib` — a legal declaration that reaches this program — derived
# only the suites naming that directory literally: 2 in the real tree, against 55
# for the union of its files. AC-18/AC-19 are SOUNDNESS claims, and that is an
# under-approximation, the one direction this file may not fail in.
# payload/scripts/lib is the directory to ask about: no fixture suite NAMES it,
# so every suite in the answer got there through a file beneath it.
# The file list is pinned, so a file added to the fixture later fails HERE by
# name instead of moving the union row's expectation out from under it.
expect_eq "dir-arg: the fixture directory holds exactly the files this row unions" \
  "payload/scripts/lib/hooklib.sh payload/scripts/lib/run.sh payload/scripts/lib/width.sh" \
  "$( cd "$FX" && find -L payload/scripts/lib -type f | sort | tr '\n' ' ' | sed 's/ $//' )"
DA_UNION="$(suites "$FX" payload/scripts/lib/hooklib.sh payload/scripts/lib/run.sh payload/scripts/lib/width.sh)"
expect_nonempty "dir-arg: the union of the directory's files is not empty (not vacuous)" \
  "$DA_UNION"
expect_eq "dir-arg: a directory query answers the union of its files' queries" \
  "$DA_UNION" "$(suites "$FX" payload/scripts/lib)"
expect_contains "dir-arg: …so it carries a suite only a FILE under it reaches (transitive-lib)" \
  "b.test.sh" "$(oneline "$FX" payload/scripts/lib)"
expect_contains "dir-arg: …and one only another file under it reaches (transitive-doctor)" \
  "e.test.sh" "$(oneline "$FX" payload/scripts/lib)"
# PAIRED: a FILE argument is untouched — the rule is scoped to directories, and a
# derivation that simply answered everything would pass the row above.
expect_eq "dir-arg: a file argument still answers only for that file" \
  "b.test.sh" "$(suites "$FX" tests/lib/helper.sh)"
expect_eq "dir-arg: …and a file under a directory does not drag in the directory" \
  "a.test.sh" "$(suites "$FX" tests/a.test.sh)"

# ── §B every edge kind can go away ──────────────────────────────────────────
# The mutation half. Each positive above is re-run against a fixture with that
# one edge deleted; the suite must DISAPPEAR from the answer. A derivation that
# printed every suite unconditionally would pass §A entirely and fail here.
section "§B the mutation half — remove the edge, lose the suite"

mut() { # mut <name> — a fresh fixture copy to mutate
  local d="$TMP/mut-$1"
  rm -rf "$d"; mkdir -p "$d"
  ( cd "$FX" && tar cf - . ) | ( cd "$d" && tar xf - )
  echo "$d"
}

M="$(mut source)"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\n' >"$M/tests/b.test.sh"
expect_eq "source: dropping the source line empties the answer" \
  "" "$(suites "$M" tests/lib/helper.sh)"

M="$(mut translib)"
printf '#!/bin/bash\necho nothing\n' >"$M/tests/lib/helper.sh"
expect_absent "transitive-lib: emptying the helper drops the suite" \
  "b.test.sh" "$(oneline "$M" payload/scripts/lib/run.sh)"

M="$(mut transdoctor)"
printf '#!/bin/bash\necho nothing\n' >"$M/payload/scripts/doctor.sh"
expect_absent "transitive-doctor: a doctor.sh that sources nothing drops the suite" \
  "e.test.sh" "$(oneline "$M" payload/scripts/lib/width.sh)"

M="$(mut payloadcopy)"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\necho no payload here\n' >"$M/tests/c.test.sh"
expect_absent "payload-copy: dropping the payload-root reference drops the suite" \
  "c.test.sh" "$(oneline "$M" payload/scripts/lib/run.sh)"

M="$(mut symlink)"
rm "$M/payload/hooks"
mkdir -p "$M/payload/hooks"
expect_absent "payload-copy: with payload/hooks no longer a symlink, hooks/h1.sh is outside payload" \
  "c.test.sh" "$(oneline "$M" hooks/h1.sh)"

M="$(mut dirref)"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\necho no directory here\n' >"$M/tests/g.test.sh"
expect_absent "dir-ref: dropping the directory reference drops the suite" \
  "g.test.sh" "$(oneline "$M" hooks/h2.sh)"

# THE ARM THE STEP-5 REVERT PASS COULD NOT LAND. Both of its attempts stubbed the
# label and the loop rather than the filter, so the derivation answered nothing at
# all and every section screamed — a broken script's red, not a removed edge's.
# Here the derivation is untouched and the FIXTURE loses the edge: h3.sh sources
# nothing, so h.test.sh has no path to hooklib.sh. The paired row is what tells a
# removed edge from a broken program — c.test.sh reaches the same file by
# payload-copy and must STAY.
M="$(mut transhook)"
printf '#!/bin/bash\necho nothing\n' >"$M/hooks/h3.sh"
expect_absent "transitive-hook: a hook that sources nothing drops the suite that runs it" \
  "h.test.sh" "$(oneline "$M" payload/scripts/lib/hooklib.sh)"
expect_contains "transitive-hook: …while the payload copier still reaches the same file" \
  "c.test.sh" "$(oneline "$M" payload/scripts/lib/hooklib.sh)"

M="$(mut dirarg)"
printf '#!/bin/bash\necho nothing\n' >"$M/tests/lib/helper.sh"
expect_absent "dir-arg: a directory answer loses the suite whose only edge to a file under it went away" \
  "b.test.sh" "$(oneline "$M" payload/scripts/lib)"
expect_contains "dir-arg: …while the suites reaching it another way stay" \
  "e.test.sh" "$(oneline "$M" payload/scripts/lib)"

M="$(mut pathref)"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\necho nothing\n' >"$M/tests/a.test.sh"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\necho nothing\n' >"$M/tests/d.test.sh"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\necho nothing\n' >"$M/tests/c.test.sh"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/resolve-roots.sh"\necho nothing\n' >"$M/tests/g.test.sh"
expect_eq "path-ref: with every reader rewritten, hooks/h1.sh reaches nobody" \
  "" "$(suites "$M" hooks/h1.sh)"

# ── §C the four root aliases are one file ───────────────────────────────────
# Code map's layout note: hooks/X, payload/hooks/X, $BIONIC_HOOKS_DIR/X and
# $BIONIC_HOOKS_DIR/../payload/hooks/X are four spellings of ONE file. A
# derivation that does not canonicalise them under-counts readers — the exact
# failure the note warns about.
section "§C the root aliases"

A_CANON="$(suites "$FX" hooks/h1.sh)"
expect_eq "alias: payload/hooks/h1.sh derives the same set as hooks/h1.sh" \
  "$A_CANON" "$(suites "$FX" payload/hooks/h1.sh)"
expect_eq "alias: an absolute path derives the same set" \
  "$A_CANON" "$(suites "$FX" "$FX/hooks/h1.sh")"
expect_eq "alias: a path through .. derives the same set" \
  "$A_CANON" "$(suites "$FX" payload/hooks/../hooks/h1.sh)"

# The four SPELLINGS inside a suite must all be found. One fixture suite per
# alias, each naming h2.sh a different way; all four must be derived.
M="$(mut aliases)"
printf '#!/bin/bash\nREPO="${BIONIC_SCRIPTS_DIR}"\ngrep -q x "${REPO}/hooks/h2.sh"\n' >"$M/tests/a.test.sh"
printf '#!/bin/bash\ngrep -q x "$BIONIC_HOOKS_DIR/h2.sh"\n' >"$M/tests/b.test.sh"
printf '#!/bin/bash\nREPO_ROOT="${BIONIC_SCRIPTS_DIR}"\ngrep -q x "$REPO_ROOT/payload/hooks/h2.sh"\n' >"$M/tests/c.test.sh"
printf '#!/bin/bash\ngrep -q x "$BIONIC_HOOKS_DIR/../payload/hooks/h2.sh"\n' >"$M/tests/d.test.sh"
printf '#!/bin/bash\necho nothing\n' >"$M/tests/e.test.sh"
printf '#!/bin/bash\necho nothing\n' >"$M/tests/f.test.sh"
printf '#!/bin/bash\necho nothing\n' >"$M/tests/g.test.sh"
expect_eq "alias: all four in-suite spellings of one file are found" \
  "a.test.sh b.test.sh c.test.sh d.test.sh" "$(suites "$M" hooks/h2.sh | tr '\n' ' ' | sed 's/ $//')"

# ── §D the real tree, on facts the code map measured ────────────────────────
# Only claims a reader can re-derive by hand from
# .bionic/docs/record/wave-verification-cannot-lie/research-code-map.md.
section "§D the real tree"

RT_ROOTS="$(oneline "$REPO" tests/lib/resolve-roots.sh)"
RT_ALL="$(suites "$REPO" tests/lib/resolve-roots.sh | wc -l | tr -d ' ')"
# THE ROSTER IS THE DIRECTORY (fixit 1.5.1). This used to count tests/run.sh's
# `run` lines against this number; the runner hand-lists nothing now, so the
# reference set is the directory itself — which is also what
# tests/lib/impact.sh:437 has always globbed, so what this row holds is one
# derivation against the tree it derives from.
RT_ROSTER="$(ls "$REPO"/tests/*.test.sh | grep -c . | tr -d ' ')"
# code map §3.5: resolve-roots.sh is sourced by every suite in the tree.
expect_eq "real: resolve-roots.sh reaches every suite in tests/" \
  "$RT_ROSTER" "$RT_ALL"

# code map §1.2 rows 5–6: docs-pins doctors hooks/session-poker.sh.
RT_POKER="$(oneline "$REPO" hooks/session-poker.sh)"
expect_contains "real: docs-pins reads hooks/session-poker.sh" "docs-pins.test.sh" "$RT_POKER"
expect_contains "real: session-poker's own suite reads it" "session-poker.test.sh" "$RT_POKER"
expect_eq "real: docs-pins' reason for session-poker.sh is an anchor" \
  "anchor" "$(reason_for "$REPO" docs-pins.test.sh hooks/session-poker.sh | cut -d: -f1)"

# code map §1.4: the ten named suites copy the whole payload tree, so a file
# under payload/ that none of them names still reaches all ten.
RT_WIDTH="$(oneline "$REPO" payload/scripts/lib/width.sh)"
for s in doctor-fleet doctor-patrol doctor-reads doctor-restart doctor-version \
         doctor-walls fresh-home loader patrol-marker command-relay; do
  expect_contains "real: $s.test.sh reads payload/scripts/lib/width.sh" \
    "$s.test.sh" "$RT_WIDTH"
done

# THE REGISTRATION-PIN CENSUS IS GONE (fixit 1.5.1, D-3). It derived the set of
# suites asserting their own `run "<self>"` line in tests/run.sh and required
# impact.sh to reach every one of them FROM tests/run.sh. Both halves ceased to
# exist together: the runner hand-lists nothing, so there are no registration
# pins left to census — twenty-two were deleted in the same commit — and
# "reachable from tests/run.sh" is no longer how a suite comes to be run. The
# property that replaced it is proved once, where the runner lives:
# tests/runner-roster.test.sh.

# ── §E the output contract ──────────────────────────────────────────────────
# S13's wall does `cut -f1` on this and writes the result to a roster row, so
# the shape is a contract, not a convenience.
section "§E the output contract"

E_OUT="$(BIONIC_IMPACT_ROOT="$FX" bash "$IMPACT" hooks/h1.sh 2>/dev/null)"
E_LINES="$(printf '%s\n' "$E_OUT" | grep -c .)"
E_UNIQ="$(printf '%s\n' "$E_OUT" | cut -f1 | sort -u | grep -c .)"
expect_eq "one line per suite — no duplicate suite column" "$E_LINES" "$E_UNIQ"
expect_eq "the suite column is sorted" \
  "$(printf '%s\n' "$E_OUT" | cut -f1)" "$(printf '%s\n' "$E_OUT" | cut -f1 | sort)"
expect_eq "every line has exactly two tab-separated fields" \
  "" "$(printf '%s\n' "$E_OUT" | awk -F'\t' 'NF!=2{print NR}')"
expect_eq "every reason carries the file it came from" \
  "" "$(printf '%s\n' "$E_OUT" | awk -F'\t' '$2 !~ /:hooks\/h1\.sh$/{print $2}')"

# A file nobody reads derives nobody. The path has to sit outside every directory
# any fixture suite names: `hooks/anything.sh` would legitimately derive the
# payload copier and the hooks globber, because if that file existed they WOULD
# read it — a directory reference is a claim about the directory, not about the
# files in it on the day the question is asked, which is also what lets a DELETED
# file still derive its readers.
BIONIC_IMPACT_ROOT="$FX" bash "$IMPACT" design/nobody-reads-this.md >"$TMP/none.out" 2>/dev/null
N_RC=$?
expect_eq "a file no suite reads derives nothing" "" "$(cat "$TMP/none.out")"
expect_eq "…and says so with exit 0, not an error" "0" "$N_RC"
expect_contains "…while a not-yet-created file under a copied directory still derives its readers" \
  "c.test.sh" "$(oneline "$FX" hooks/not-created-yet.sh)"

BIONIC_IMPACT_ROOT="$FX" bash "$IMPACT" >"$TMP/usage.out" 2>"$TMP/usage.err"
U_RC=$?
expect_eq "no arguments is a usage error, not an empty answer" "2" "$U_RC"
expect_eq "…and the usage goes to stderr, leaving stdout clean" "" "$(cat "$TMP/usage.out")"
expect_contains "…and the usage names the program" "impact.sh" "$(cat "$TMP/usage.err")"

expect_eq "several files in one call answer as their union" \
  "$(printf '%s\n%s\n' "$(suites "$FX" hooks/h1.sh)" "$(suites "$FX" tests/lib/helper.sh)" | sort -u | grep -c .)" \
  "$(suites "$FX" hooks/h1.sh tests/lib/helper.sh | grep -c .)"

# ── §F the planted-edit proof (opt-in) ──────────────────────────────────────
# AC-19. For one planted edit in each file class, the derived set ⊇ the suites
# that actually go RED when that edit is applied to a scratch tree.
#
# HOW ⊇ IS FALSIFIED, and therefore what has to run: a suite that goes red and
# is NOT in the derived set. Suites INSIDE the derived set can prove only that
# the edit bites at all. So each class runs the derived set's witness (one suite,
# to show the mutation is real) plus THE WHOLE COMPLEMENT — every roster suite
# outside the derived set — because that is where a counterexample would live.
#
# The planted edits are maximal breakage on purpose (an unconditional early exit,
# a syntax error): a small edit makes a small red set and a weak superset claim.
#
# §F IS A SECTION ONLY WHEN IT RUNS (A-S5c-k, orchestrator ruling 2026-09-06). An
# opt-in proof that opens a section unconditionally and then skips would be exactly
# the vacuous-section lie the floor exists to catch; a section that "asserts" its
# own skip condition is that same lie wearing an assertion. So `section` is called
# only inside the BIONIC_IMPACT_PLANTED=1 branch, where the proof actually asserts;
# the default path prints its SKIP line with no open section at all, and the
# suite's tally reads sections=N without §F on an ordinary run, sections=N+1 when
# the proof runs.
if [ "${BIONIC_IMPACT_PLANTED:-0}" != "1" ]; then
  echo "SKIP: §F the planted-edit proof — not requested (BIONIC_IMPACT_PLANTED=1 to run it; the"
  echo "      authoring-time record is committed at .bionic/docs/record/"
  echo "      wave-verification-cannot-lie/s12-planted-edits.log)"
else
  section "§F the planted-edit proof"
  PLOG="${BIONIC_IMPACT_PLANTED_LOG:-$TMP/planted-edits.log}"

  # WIDTH IS READ, NOT SET — the same rule tests/run.sh:168 follows, and the
  # same ceiling. Six whole-roster runs at width one would take the better part
  # of an hour; the roster's own isolation audit is what makes running them at
  # once safe (tests/run.sh:52-70).
  PJOBS=8
  if [ -f "$REPO/payload/scripts/lib/resources.sh" ]; then
    # shellcheck source=/dev/null
    . "$REPO/payload/scripts/lib/resources.sh" 2>/dev/null || :
    if command -v pressure_level >/dev/null 2>&1; then
      PJOBS="$(pressure_level "${BIONIC_TEST_JOBS_CEILING:-8}" 2>/dev/null)"
    fi
  fi
  case "$PJOBS" in ''|*[!0-9]*) PJOBS=8 ;; esac

  : >"$PLOG"
  {
    echo "planted-edit proof — spec AC-19"
    echo "when:        $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "repo:        $REPO"
    echo "commit:      $(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "interpreter: $(bash --version | head -1)"
    echo "width:       $PJOBS"
    echo
    echo "METHOD. A scratch copy of the checkout is made once. For each file"
    echo "class the derived set is recorded, one maximal edit is planted, the"
    echo "WHOLE roster is run against the mutated tree, and the file is"
    echo "restored. The claim under test is derived ⊇ red: its falsifier is a"
    echo "suite that goes red and is not in the derived set, so the complement"
    echo "is run in full rather than sampled. A control run over the unmutated"
    echo "tree comes first, and any suite red there is discounted everywhere —"
    echo "a suite that cannot pass on its own proves nothing about impact."
  } >>"$PLOG"

  SCRATCH="$TMP/scratch"
  mkdir -p "$SCRATCH"
  ( cd "$REPO" && tar cf - --exclude=.git --exclude=.worktrees --exclude=.bionic . ) \
    | ( cd "$SCRATCH" && tar xf - )

  ROSTER="$(/usr/bin/grep -oE '^run "[^"]+"' "$SCRATCH/tests/run.sh" | sed 's/^run "//; s/"$//' | sort)"
  printf '%s\n' "$ROSTER" >"$TMP/roster"
  echo "roster:      $(grep -c . "$TMP/roster") suites" >>"$PLOG"

  # the parallel arm — one label in, one <label>.rc out. §F's own suite is
  # skipped inside the scratch tree: it would recurse into another whole proof.
  cat >"$TMP/arm.sh" <<'ARM'
#!/bin/bash
# THE SEAM HAS TO BE CLOSED BEFORE THE SUITE STARTS. This suite sourced
# tests/lib/resolve-roots.sh at its top, which EXPORTS BIONIC_HOOKS_DIR,
# BIONIC_SKILLS_DIR and BIONIC_SCRIPTS_DIR pointing at the real checkout —
# and resolve-roots takes an existing export verbatim. Inherited, those three
# send every suite in the scratch tree to read the REAL files, so the planted
# edit is never seen and the proof reports a clean superset while testing
# nothing (memory "seam-blindness-class": a seam that substitutes the value
# under test leaves the production path unverified). Unset them and each suite
# re-derives its roots from its own location, which is the scratch tree.
unset BIONIC_HOOKS_DIR BIONIC_SKILLS_DIR BIONIC_SCRIPTS_DIR
unset BIONIC_IMPACT_ROOT BIONIC_IMPACT_PLANTED BIONIC_IMPACT_PLANTED_LOG
label="$1"
# impact.test.sh's own §F would recurse into another whole proof from inside
# this one; the outer run is what covers it.
if [ "$label" = "impact.test.sh" ]; then echo 0 >"$RESDIR/$label.rc"; exit 0; fi
( cd "$SCRATCHDIR" && bash "tests/$label" ) >"$RESDIR/$label.out" 2>&1
echo $? >"$RESDIR/$label.rc"
ARM

  # list_run <resdir> <list-file> — runs the named suites against $SCRATCH at
  # width $PJOBS, prints the red ones.
  list_run() {
    local rd="$1" list="$2"
    rm -rf "$rd"; mkdir -p "$rd"
    SCRATCHDIR="$SCRATCH" RESDIR="$rd" \
      xargs -P "$PJOBS" -n1 bash "$TMP/arm.sh" <"$list" >/dev/null 2>&1
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      [ -f "$rd/$l.rc" ] || { echo "$l"; continue; }
      [ "$(cat "$rd/$l.rc")" = "0" ] || echo "$l"
    done <"$list"
  }

  # PROVE THE SEAM IS CLOSED before trusting a single result below. A suite
  # launched by the arm must resolve its roots to the SCRATCH tree; if it
  # resolves to the real checkout the whole proof is vacuous, so this is checked
  # rather than assumed, and checked the way the suites themselves do it.
  cat >"$TMP/seam-probe.sh" <<'PROBE'
#!/bin/bash
unset BIONIC_HOOKS_DIR BIONIC_SKILLS_DIR BIONIC_SCRIPTS_DIR
. "$(dirname "$0")/lib/resolve-roots.sh"
printf '%s\n' "$BIONIC_SCRIPTS_DIR"
PROBE
  cp "$TMP/seam-probe.sh" "$SCRATCH/tests/seam-probe.sh"
  SEAM_SAW="$( ( cd "$SCRATCH" && bash tests/seam-probe.sh ) 2>/dev/null )"
  rm -f "$SCRATCH/tests/seam-probe.sh"
  # Compared PHYSICALLY. resolve-roots.sh reports `pwd -P`, and mktemp hands out
  # a path under /var, which is a symlink to /private/var here — so the two
  # spellings of the same directory differ textually and only textually.
  SCRATCH_P="$(cd "$SCRATCH" && pwd -P)"
  {
    echo
    echo "SEAM CHECK — the root a suite in the scratch tree resolves to"
    echo "  scratch:   $SCRATCH_P"
    echo "  suite saw: $SEAM_SAW"
  } >>"$PLOG"
  if [ "$SEAM_SAW" = "$SCRATCH_P" ]; then
    ok "planted seam: a suite in the scratch tree resolves to the scratch tree"
  else
    no "planted seam: a suite in the scratch tree resolves to the scratch tree" \
      "saw [$SEAM_SAW] — every result below would be about the real checkout"
  fi

  # the control. Anything red here is red for its own reasons.
  BASE_RED="$(list_run "$TMP/res-base" "$TMP/roster")"
  {
    echo
    echo "CONTROL (no edit planted)"
    echo "  red: ${BASE_RED:-none}"
  } >>"$PLOG"
  if [ -z "$BASE_RED" ]; then
    ok "planted control: the unmutated scratch tree is wholly green"
  else
    ok "planted control: $(printf '%s\n' "$BASE_RED" | grep -c .) suite(s) red before any edit, discounted below"
  fi

  # plant <class> <file> <how> <witness>
  #
  # WHAT IS RUN, AND WHY NOT EVERYTHING. The claim is derived ⊇ red. Its only
  # falsifier is a suite red OUTSIDE the derived set, so the COMPLEMENT is run in
  # full — never sampled, because a sampled complement proves a sampled claim.
  # Inside the derived set nothing needs proving except that the edit is not
  # inert, and one named witness settles that: the suite whose whole subject is
  # the mutated file. Running the other twenty-odd derived suites would add half
  # again to a proof already measured in roster-runs and answer no question.
  plant() {
    local class="$1" file="$2" how="$3" wit="$4"
    local derived red witness="" outside="" n_out=0 wit_red

    derived="$(BIONIC_IMPACT_ROOT="$SCRATCH" bash "$IMPACT" "$file" | cut -f1 | sort -u)"
    printf '%s\n' "$derived" | grep . >"$TMP/derived" || : >"$TMP/derived"

    cp "$SCRATCH/$file" "$TMP/restore.bak"
    case "$how" in
      early-exit) printf 'exit 99\n' | cat - "$TMP/restore.bak" >"$SCRATCH/$file" ;;
      syntax)     printf '\nif then fi(((\n' >>"$SCRATCH/$file" ;;
      # a file read as TEXT — a roster, an SSoT a pin greps — is not broken by
      # an appended line or an early exit; only losing its content breaks it.
      wipe)       printf '#!/bin/bash\n# BIONIC_IMPACT_PLANTED_WIPE\n' >"$SCRATCH/$file" ;;
    esac

    comm -23 "$TMP/roster" "$TMP/derived" >"$TMP/complement"
    printf '%s\n' "$wit" >"$TMP/witlist"
    wit_red="$(list_run "$TMP/res-wit" "$TMP/witlist")"
    red="$(list_run "$TMP/res-comp" "$TMP/complement")"
    cp "$TMP/restore.bak" "$SCRATCH/$file"

    # discount the control's own reds, then split by the derived set
    printf '%s\n' "$red" | grep . >"$TMP/red" || : >"$TMP/red"
    printf '%s\n' "$BASE_RED" | grep . >"$TMP/basered" || : >"$TMP/basered"
    sort -u "$TMP/red" -o "$TMP/red"
    sort -u "$TMP/basered" -o "$TMP/basered"
    comm -23 "$TMP/red" "$TMP/basered" >"$TMP/outside"
    outside="$(tr '\n' ' ' <"$TMP/outside")"
    n_out="$(grep -c . "$TMP/outside")"
    case "$BASE_RED" in *"$wit"*) witness="" ;; *) witness="$wit_red" ;; esac

    {
      echo
      echo "════════════════════════════════════════════════════════════════"
      echo "class:            $class"
      echo "file:             $file"
      echo "edit:             $how"
      echo "derived ($(grep -c . "$TMP/derived")): $(tr '\n' ' ' <"$TMP/derived")"
      echo "witness (derived, run to prove the edit bites): $wit -> ${wit_red:+RED}${wit_red:-green}"
      echo "complement run in full: $(grep -c . "$TMP/complement") suites"
      echo "red OUTSIDE the derived set, control discounted: ${outside:-none}"
    } >>"$PLOG"

    if [ -n "$witness" ]; then
      ok "planted [$class]: the edit really bites — $witness went red"
    else
      no "planted [$class]: the edit really bites" \
        "no derived suite went red; the planted edit is inert and the superset claim is vacuous"
    fi
    if [ "$n_out" -eq 0 ]; then
      ok "planted [$class]: derived ⊇ red, over the whole roster"
    else
      no "planted [$class]: derived ⊇ red, over the whole roster" \
        "$n_out suite(s) red outside the derived set: $outside"
    fi
  }

  # The five classes AC-19 names, each with the suite whose whole subject is the
  # mutated file, and a maximal edit: a small edit makes a small red set and a
  # correspondingly weak superset claim.
  plant "a hook"                      "hooks/protect-main.sh"         early-exit protect-main.test.sh
  plant "a lib the doctor sources"    "payload/scripts/lib/width.sh"  early-exit width.test.sh
  plant "a tests/lib helper"          "tests/lib/bound-marker.sh"     wipe       session-start.test.sh
  plant "tests/run.sh"                "tests/run.sh"                  wipe       version-compare.test.sh
  plant "a whole-payload-copied file" "payload/scripts/lib/patrol.sh" wipe       patrol-marker.test.sh

  echo
  echo "planted-edit log: $PLOG"
fi

finish
