#!/bin/bash
# tests/archive.test.sh — payload/scripts/lib/archive.sh: Step 9 archives a closed run
# (epic-22 wave-01, REQ-C; AC-C.1..7; ADR-003 decisions 2/3; design ledger D5).
#
# WHAT IT OWNS. Seven acceptance criteria, each hermetic against a fixture project under a
# mktemp sandbox with HOME redirected into it — never the real ~/bionic-archive and never
# this repository's own tree:
#
#   C.1  a standalone run (no open sibling under the same epic slug) moves.
#   C.2  a wave inside an open epic (an open sibling under the same slug) moves nothing.
#   C.3  an occupied destination slot refuses, source untouched.
#   C.4  an origin-file mismatch (a different project sharing a basename) refuses.
#   C.5  `archive-on-close: false` moves nothing.
#   C.6  the default archive root, unit-level, straight off lib/roots.sh (already the
#        primary coverage in tests/roots.test.sh — restated here because the plan's own
#        Eval design table places this row under §C, and because archive_run's OWN default
#        path is worth a direct check rather than trusting roots.sh's alone).
#   C.7  the rendered SKILL.md's Step-9 span names the call and the `archived:` line —
#        static, docs-pins-shaped (also pinned in tests/docs-pins.test.sh §Archive).
#
# Plus the property AC-C.1's own row names but does not spell out: RENAME, NOT COPY — the
# source directories are gone after a successful move, not merely duplicated.
#
# THE OWNERSHIP RULE UNDER TEST (archive.sh's own header, restated here as the fixture
# shape): one run owns THREE trees — specs/<slug>, plans/<slug>, adrs/<slug> — and never
# record/<anything>. Every fixture below plants all four and asserts record/ survives.
#
# HERMETIC. HOME is redirected into the sandbox for every row, so `archive_root`'s default
# ($HOME/bionic-archive) lands inside the sandbox and never touches a real machine's archive.
#
# Usage: bash tests/archive.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LIB="$REPO_ROOT/payload/scripts/lib/archive.sh"
SKILL_MD="$REPO_ROOT/skills/canonical-sdlc/SKILL.md"

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/archive-test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# contains <haystack> <needle> -> yes|no. A function, not a `case` inside a command
# substitution — bash 3.2 (this file's shebang interpreter) mis-parses that shape and
# truncates the substitution at the first `)` (run-predicate R0's own note, restated in
# tests/roots.test.sh).
contains() {
  case "$1" in
    *"$2"*) printf 'yes' ;;
    *)      printf 'no'  ;;
  esac
}

# fixture_plan <plan-file> <current> [delivered] -> writes a minimal plan, creating its
# parent directory first (never via a caller-side `>` redirection, which bash opens
# BEFORE this function's body runs and would fail on a not-yet-created directory), whose
# run_open verdict is exactly what the caller asked for: current: 9 with a delivered:
# Step-9 line is CLOSED, anything else (or 9 without delivered:) is OPEN.
fixture_plan() {
  local file="$1" current="$2" delivered="${3:-}"
  mkdir -p "$(dirname "$file")"
  {
    printf -- '---\ncanonical_sdlc_version: 14\n---\n\n## SDLC State\n\ncurrent: %s\n' "$current"
    if [ "$current" = "9" ] && [ "$delivered" = "yes" ]; then
      printf -- '\n- Step 9: delivered: yes\n'
    fi
  } > "$file"
}

# new_project <name> -> a fresh sandbox project dir with HOME redirected beside it and the
# four owned/spared trees present under docs_root's default (.bionic/docs). Echoes the
# project's absolute path.
new_project() {
  local name="$1" p
  p="$SANDBOX/$name"
  mkdir -p "$p/.bionic/docs/plans" "$p/.bionic/docs/specs" "$p/.bionic/docs/adrs" \
    "$p/.bionic/docs/record"
  printf '%s\n' "$p"
}

# call_archive <cwd> <run-dir> -> stdout+stderr merged, one call, HOME already exported by
# the caller. A subshell so no fixture's cwd leaks into the next row.
call_archive() {
  local cwd="$1" run_dir="$2"
  ( cd "$cwd" && /bin/bash -c '. "$1" || exit 1; archive_run "$2"' _ "$LIB" "$run_dir" ) 2>&1
}

# call_archive_rc <cwd> <run-dir> -> the same call's exit status alone.
call_archive_rc() {
  local cwd="$1" run_dir="$2"
  ( cd "$cwd" && /bin/bash -c '. "$1" || exit 1; archive_run "$2" >/dev/null 2>&1' _ "$LIB" "$run_dir" )
  echo $?
}

# ============================================================
section "0 — the library exists, parses, defines archive_run"
# ============================================================

expect_eq "archive.sh is on disk" "yes" "$([ -r "$LIB" ] && echo yes || echo no)"
expect_eq "archive.sh parses" "yes" "$(bash -n "$LIB" 2>/dev/null && echo yes || echo no)"
expect_eq "sourcing archive.sh defines archive_run" "yes" \
  "$(bash -c '. "$1" >/dev/null 2>&1 || exit 1; declare -F archive_run >/dev/null 2>&1 && echo yes || echo no' _ "$LIB")"

# ============================================================
section "1 — AC-C.1: a standalone run (no open sibling) moves; a RENAME, not a copy"
# ============================================================

P1="$(new_project p1)"
fixture_plan "$P1/.bionic/docs/plans/epic-01/wave-01.plan.md" 9 yes
mkdir -p "$P1/.bionic/docs/specs/epic-01" "$P1/.bionic/docs/adrs/epic-01"
printf 'a spec\n' > "$P1/.bionic/docs/specs/epic-01/w.spec.md"
printf 'an adr\n' > "$P1/.bionic/docs/adrs/epic-01/adr-001.md"
printf 'a record, never moved\n' > "$P1/.bionic/docs/record/s01.md"
export HOME="$SANDBOX/home-p1"; mkdir -p "$HOME"

OUT1="$(call_archive "$P1" "$P1/.bionic/docs/plans/epic-01")"
RC1=$?
DEST1="$HOME/bionic-archive/p1/.bionic/docs"

expect_eq "1a: archive_run on a standalone-run directory exits 0" "0" "$RC1"
expect_eq "1b: AC-C.1 — plans/epic-01 moved to <archive-root>/<project>/.bionic/<same relative path>" \
  "yes" "$([ -d "$DEST1/plans/epic-01" ] && [ -f "$DEST1/plans/epic-01/wave-01.plan.md" ] && echo yes || echo no)"
expect_eq "1c: …and specs/epic-01 moved alongside it (the trio, not just the plan dir)" \
  "yes" "$([ -f "$DEST1/specs/epic-01/w.spec.md" ] && echo yes || echo no)"
expect_eq "1d: …and adrs/epic-01 too" \
  "yes" "$([ -f "$DEST1/adrs/epic-01/adr-001.md" ] && echo yes || echo no)"
expect_eq "1e: …while record/ — never owned by a run — was never moved" \
  "yes" "$([ -f "$P1/.bionic/docs/record/s01.md" ] && echo yes || echo no)"
expect_eq "1f: …and no record/ tree was created under the archive" \
  "no" "$([ -e "$DEST1/record" ] && echo yes || echo no)"

# RENAME, NOT COPY (AC-C.1's own text: "copied not moved" is the fails-when).
expect_eq "1g: the source plans/epic-01 is GONE, not merely duplicated (rename semantics)" \
  "no" "$([ -e "$P1/.bionic/docs/plans/epic-01" ] && echo yes || echo no)"
expect_eq "1h: …and the source specs/epic-01 is gone too" \
  "no" "$([ -e "$P1/.bionic/docs/specs/epic-01" ] && echo yes || echo no)"

expect_eq "1i: an origin file was written naming this project's absolute root" \
  "$P1" "$(cat "$HOME/bionic-archive/p1/origin" 2>/dev/null)"

expect_eq "1j: the printed line names the moved path (what Step 9's archived: line quotes)" \
  "yes" "$(contains "$OUT1" "$DEST1/plans/epic-01")"

# --- fails-when: a COPY instead of a move would leave the source behind ---
expect_eq "1k: fails-when discriminates — a copy-not-move would leave 1g false; it is true" \
  "no" "$([ -d "$P1/.bionic/docs/plans/epic-01" ] && echo yes || echo no)"

# ============================================================
section "2 — AC-C.2: a wave inside an OPEN epic moves nothing"
# ============================================================

P2="$(new_project p2)"
mkdir -p "$P2/.bionic/docs/plans/epic-02" "$P2/.bionic/docs/specs/epic-02" "$P2/.bionic/docs/adrs/epic-02"
fixture_plan "$P2/.bionic/docs/plans/epic-02/wave-01.plan.md" 9 yes
# THE OPEN SIBLING — a second wave under the SAME epic slug, current: 4 (open).
fixture_plan "$P2/.bionic/docs/plans/epic-02/wave-02.plan.md" 4
printf 'a spec\n' > "$P2/.bionic/docs/specs/epic-02/w.spec.md"
printf 'an adr\n' > "$P2/.bionic/docs/adrs/epic-02/adr-001.md"
export HOME="$SANDBOX/home-p2"; mkdir -p "$HOME"

OUT2="$(call_archive "$P2" "$P2/.bionic/docs/plans/epic-02")"
RC2=$?

expect_eq "2a: archive_run against an open-sibling epic exits 0 (a no-op, not a refusal)" "0" "$RC2"
expect_eq "2b: AC-C.2 — nothing moved: plans/epic-02 is still exactly where it was" \
  "yes" "$([ -f "$P2/.bionic/docs/plans/epic-02/wave-01.plan.md" ] && [ -f "$P2/.bionic/docs/plans/epic-02/wave-02.plan.md" ] && echo yes || echo no)"
expect_eq "2c: …and specs/epic-02 stayed too" \
  "yes" "$([ -f "$P2/.bionic/docs/specs/epic-02/w.spec.md" ] && echo yes || echo no)"
expect_eq "2d: …and no archive directory was created for p2 at all" \
  "no" "$([ -e "$HOME/bionic-archive/p2" ] && echo yes || echo no)"
expect_eq "2e: the printed line names the open sibling (why nothing moved)" \
  "yes" "$(contains "$OUT2" "wave-02.plan.md")"

# --- fails-when: "the wave directory moves" — the paired positive against 2b/2d.
# Absence-readback rule: a zero/empty readback needs a paired positive case, so the SAME
# fixture, with the open sibling removed, must let the identical call move it. ---
rm -f "$P2/.bionic/docs/plans/epic-02/wave-02.plan.md"
call_archive "$P2" "$P2/.bionic/docs/plans/epic-02" >/dev/null 2>&1
expect_eq "2f: the paired positive — remove the open sibling, the same call now moves it" \
  "no" "$([ -e "$P2/.bionic/docs/plans/epic-02" ] && echo yes || echo no)"

# ============================================================
section "3 — AC-C.3: an occupied destination slot refuses, source untouched"
# ============================================================

P3="$(new_project p3)"
mkdir -p "$P3/.bionic/docs/plans/epic-03" "$P3/.bionic/docs/specs/epic-03" "$P3/.bionic/docs/adrs/epic-03"
fixture_plan "$P3/.bionic/docs/plans/epic-03/wave-01.plan.md" 9 yes
printf 'a spec\n' > "$P3/.bionic/docs/specs/epic-03/w.spec.md"
export HOME="$SANDBOX/home-p3"; mkdir -p "$HOME"
mkdir -p "$HOME/bionic-archive/p3/.bionic/docs/plans/epic-03"
printf 'already here\n' > "$HOME/bionic-archive/p3/.bionic/docs/plans/epic-03/occupant.md"

OUT3="$(call_archive "$P3" "$P3/.bionic/docs/plans/epic-03")"
RC3=$?

expect_eq "3a: AC-C.3 — an occupied slot exits non-zero (refused)" "1" "$RC3"
expect_eq "3b: …source plans/epic-03 untouched (fails-when: merged into the slot)" \
  "yes" "$([ -f "$P3/.bionic/docs/plans/epic-03/wave-01.plan.md" ] && echo yes || echo no)"
expect_eq "3c: …the occupant is unharmed, no merge happened" \
  "yes" "$([ -f "$HOME/bionic-archive/p3/.bionic/docs/plans/epic-03/occupant.md" ] && echo yes || echo no)"
expect_eq "3d: …and the sibling specs/epic-03 (unoccupied) ALSO stayed — all-or-nothing" \
  "yes" "$([ -f "$P3/.bionic/docs/specs/epic-03/w.spec.md" ] && echo yes || echo no)"
expect_eq "3e: the printed line names the occupied path" \
  "yes" "$(contains "$OUT3" "plans/epic-03")"

# ============================================================
section "4 — AC-C.4: an origin-file mismatch (basename collision) refuses"
# ============================================================

P4="$(new_project p4)"
mkdir -p "$P4/.bionic/docs/plans/epic-04"
fixture_plan "$P4/.bionic/docs/plans/epic-04/wave-01.plan.md" 9 yes
export HOME="$SANDBOX/home-p4"; mkdir -p "$HOME"
mkdir -p "$HOME/bionic-archive/p4"
printf '%s\n' "$SANDBOX/some-other-p4" > "$HOME/bionic-archive/p4/origin"

OUT4="$(call_archive "$P4" "$P4/.bionic/docs/plans/epic-04")"
RC4=$?

expect_eq "4a: AC-C.4 — an origin mismatch exits non-zero (refused)" "1" "$RC4"
expect_eq "4b: …source untouched (fails-when: the move proceeds)" \
  "yes" "$([ -f "$P4/.bionic/docs/plans/epic-04/wave-01.plan.md" ] && echo yes || echo no)"
expect_eq "4c: …no plans/ tree created under the archive" \
  "no" "$([ -e "$HOME/bionic-archive/p4/.bionic" ] && echo yes || echo no)"
expect_eq "4d: the printed line names THIS project's own root" "yes" "$(contains "$OUT4" "$P4")"
expect_eq "4e: …and the recorded, colliding one" "yes" "$(contains "$OUT4" "some-other-p4")"

# ============================================================
section "5 — AC-C.5: archive-on-close: false moves nothing"
# ============================================================

P5="$(new_project p5)"
mkdir -p "$P5/.bionic/docs/plans/epic-05"
fixture_plan "$P5/.bionic/docs/plans/epic-05/wave-01.plan.md" 9 yes
printf 'archive-on-close: false\n' > "$P5/.bionic/config.yaml"
export HOME="$SANDBOX/home-p5"; mkdir -p "$HOME"

OUT5="$(call_archive "$P5" "$P5/.bionic/docs/plans/epic-05")"
RC5=$?

expect_eq "5a: AC-C.5 — the opt-out exits 0 (a benign no-op, not a refusal)" "0" "$RC5"
expect_eq "5b: …source untouched (fails-when: the key is ignored)" \
  "yes" "$([ -f "$P5/.bionic/docs/plans/epic-05/wave-01.plan.md" ] && echo yes || echo no)"
expect_eq "5c: …no archive directory created for p5 at all" \
  "no" "$([ -e "$HOME/bionic-archive/p5" ] && echo yes || echo no)"
expect_eq "5d: the printed line names the opt-out" "yes" "$(contains "$OUT5" "archive-on-close")"

# --- the paired positive: the SAME fixture without the key present moves normally, so
# row 5a-c is not "archive_run is simply broken here" but the key's own effect ---
rm -f "$P5/.bionic/config.yaml"
OUT5B="$(call_archive "$P5" "$P5/.bionic/docs/plans/epic-05")"
expect_eq "5e: …and removing the key alone (same fixture) lets the same call move it" \
  "no" "$([ -e "$P5/.bionic/docs/plans/epic-05" ] && echo yes || echo no)"

# ============================================================
section "6 — AC-C.6: the default archive root, unit-level (no archive-root: set)"
# ============================================================
#
# lib/roots.sh's archive_root already carries the primary coverage of this AC
# (tests/roots.test.sh §1a); restated here directly against archive.sh's own call site,
# since the plan's Eval design table places this row under §C and a library that read its
# OWN copy of the default rather than roots.sh's would pass roots.test.sh while still being
# wrong here.

P6="$(new_project p6)"
export HOME="$SANDBOX/home-p6"; mkdir -p "$HOME"
ROOTS_LIB="$REPO_ROOT/payload/scripts/lib/roots.sh"
expect_eq "6a: AC-C.6 — no archive-root: set -> \$HOME/bionic-archive" \
  "$HOME/bionic-archive" \
  "$(bash -c '. "$1" >/dev/null 2>&1 || exit 1; archive_root "$2"' _ "$ROOTS_LIB" "$P6")"

mkdir -p "$P6/.bionic/docs/plans/epic-06"
fixture_plan "$P6/.bionic/docs/plans/epic-06/wave-01.plan.md" 9 yes
call_archive "$P6" "$P6/.bionic/docs/plans/epic-06" >/dev/null 2>&1
expect_eq "6b: …and archive_run itself landed the move under that exact default" \
  "yes" "$([ -d "$HOME/bionic-archive/p6/.bionic/docs/plans/epic-06" ] && echo yes || echo no)"

# ============================================================
section "7 — AC-C.7: the rendered SKILL.md's Step-9 span names the call and archived:"
# ============================================================
#
# STATIC, docs-pins-shaped (also pinned in tests/docs-pins.test.sh §Archive). The span is
# bounded the same way the K1 section's step0_card extractor is (tests/docs-pins.test.sh):
# from the Step-9 heading to the next `## ` (not `###`) heading.

step9_span() {
  awk '/^### Step 9 —/{f=1} f{print} f&&/^## [^#]/ && !/^### Step 9 —/{exit}' "$1" 2>/dev/null
}

expect_eq "7a: SKILL.md is on disk (a render output, not hand-edited)" "yes" \
  "$([ -r "$SKILL_MD" ] && echo yes || echo no)"

STEP9="$(step9_span "$SKILL_MD")"
expect_eq "7b: the Step-9 span was found" "yes" "$([ -n "$STEP9" ] && echo yes || echo no)"
expect_eq "7c: AC-C.7 — the Step-9 span names archive_run" "yes" "$(contains "$STEP9" "archive_run")"
expect_eq "7d: …and the archived: evidence line" "yes" "$(contains "$STEP9" "archived:")"

# --- fails-when: a doctored copy with the archiving paragraph stripped is what "a silent
# move" would look like — the pin must discriminate it. ---
anchor "$SKILL_MD" '**Archiving.**' 1
DOCTORED="$SANDBOX/skill-no-archiving.md"
awk '/^\*\*Archiving\.\*\*/{skip=1} skip && /^$/{skip=0; next} skip{next} {print}' "$SKILL_MD" > "$DOCTORED"
DOCTORED_STEP9="$(step9_span "$DOCTORED")"
expect_eq "7e: fails-when — the doctored span no longer names archive_run (pin discriminates)" \
  "no" "$(contains "$DOCTORED_STEP9" "archive_run")"

finish
