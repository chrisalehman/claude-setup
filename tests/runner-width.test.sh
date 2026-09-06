#!/bin/bash
# tests/runner-width.test.sh — tests/run.sh takes its job width from the machine's own
# pressure rung (wave-roster-lifecycle S9, spec AC-15, R4).
#
# WHAT CHANGED. `JOBS="${BIONIC_TEST_JOBS:-8}"` — a literal a caller had to notice and set —
# became `pressure_sample` then `JOBS="$(pressure_level "${BIONIC_TEST_JOBS_CEILING:-8}")"`:
# one fresh reading, then the median-smoothed rung over resources.sh's ring, read against a
# ceiling. `BIONIC_TEST_JOBS` is retired as an input; a caller who still sets it is told once,
# on stderr, and ignored.
#
# THE ONLY SAFE WAY TO DRIVE THIS is `tests/run.sh --dry-run` (added by this same slice):
# it reads the rung the ring already carries and prints it, without launching the
# 40-plus-suite roster a real run would. Every case below drives the REAL runner script
# this way; nothing here reimplements the width computation.
#
# --dry-run SAMPLES NOTHING (S25, critic K-4 option 2: a dry run writes nothing to the
# ring — Section 2 pins this). Every fixture below therefore pre-seeds the ring with
# however many lines the case needs BEFORE calling `dry_run` — most seed the SAME
# reading twice, which reads identically whether or not a live sample ever joins them,
# so removing the runner's own dry-run sample changed none of these cases' answers.
# `BIONIC_PROBE_FREE_PCT` / `_SWAP_PCT` / `_LOAD_1M` are still pinned on every call: they
# no longer feed a dry-run sample, but Section 2's ordinary-path case (the one path that
# still samples) reads them, and leaving them unset there would make that one case a
# weather report.
#
# FIXTURE DISCIPLINE (Fail-closed constants idiom, resources.sh:154). `BIONIC_PRESSURE_RING`
# always points under this suite's own mktemp root — never the real
# `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/bionic/pressure.ring` — and `BIONIC_NOW_EPOCH` pins the
# clock so every ring line this suite writes lands inside the smoothing window regardless of
# wall-clock time. A case is not left to the real, unpinned state of the machine running
# this suite.
#
# Usage: bash tests/runner-width.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

RUN="${BIONIC_SCRIPTS_DIR}/tests/run.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/runner-width-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

NOW=1700000000

# ring_of <path> <epoch> <sample>... — rewrite a ring with one line per sample, all at <epoch>
ring_of() {
  local path="$1" t="$2"; shift 2
  mkdir -p "$(dirname "$path")"
  : > "$path"
  local s
  for s in "$@"; do printf '%s|%s\n' "$t" "$s" >> "$path"; done
}

# dry_run <ring> <probe-sample> [ceiling-env-assignment]
# Runs the REAL tests/run.sh --dry-run with the ring, clock and probe pinned so its own
# internal pressure_sample call agrees with the band the pre-seeded ring already carries.
DRY_OUT=""; DRY_ERR=""; DRY_ST=0
dry_run() {
  local ring="$1" sample="$2" ceiling_env="${3:-}"
  local f s l c
  IFS='|' read -r f s l c <<<"$sample"
  DRY_OUT=$(cd "$BIONIC_SCRIPTS_DIR" && \
    env BIONIC_PRESSURE_RING="$ring" BIONIC_NOW_EPOCH="$NOW" \
        BIONIC_PROBE_FREE_PCT="$f" BIONIC_PROBE_SWAP_PCT="$s" BIONIC_PROBE_LOAD_1M="$l" \
        ${ceiling_env:+BIONIC_TEST_JOBS_CEILING="$ceiling_env"} \
        bash "$RUN" --dry-run 2>"$TMPROOT/.err")
  DRY_ST=$?
  DRY_ERR=$(cat "$TMPROOT/.err")
}

# The plan's band table (S7/§I), reused verbatim: free|swap|load|cores.
S_CLEAR='44|69|1.6|8'
S_CRIT='10|50|1|8'

section "Section 1: --dry-run prints JOBS=<n> and exits before any suite runs"

# (a) a critical ring at ceiling 8 -> the quartered rung, 2.
RING_A="$TMPROOT/a/pressure.ring"
ring_of "$RING_A" "$NOW" "$S_CRIT" "$S_CRIT"
dry_run "$RING_A" "$S_CRIT" 8
expect_eq   "1a a critical ring at ceiling 8 prints JOBS=2" "0" "$DRY_ST"
expect_contains "1a …exactly that line" "JOBS=2" "$DRY_OUT"

# (b) a clear ring at ceiling 8 -> the full ceiling, 8.
RING_B="$TMPROOT/b/pressure.ring"
ring_of "$RING_B" "$NOW" "$S_CLEAR" "$S_CLEAR"
dry_run "$RING_B" "$S_CLEAR" 8
expect_contains "1b a clear ring at ceiling 8 prints JOBS=8" "JOBS=8" "$DRY_OUT"

# (c) no BIONIC_TEST_JOBS_CEILING at all -> the old default of 8 is the ceiling.
RING_C="$TMPROOT/c/pressure.ring"
ring_of "$RING_C" "$NOW" "$S_CLEAR" "$S_CLEAR"
dry_run "$RING_C" "$S_CLEAR"
expect_contains "1c no ceiling var: the default ceiling is 8" "JOBS=8" "$DRY_OUT"
# Sharper than (c) alone: a critical ring with no ceiling var quarters exactly 8, not some
# other unstated default.
RING_C2="$TMPROOT/c2/pressure.ring"
ring_of "$RING_C2" "$NOW" "$S_CRIT" "$S_CRIT"
dry_run "$RING_C2" "$S_CRIT"
expect_contains "1c …confirmed against a critical ring too (quarters 8, not another default)" \
  "JOBS=2" "$DRY_OUT"

echo
section "Section 2: --dry-run writes NOTHING (S25, critic K-4 option 2)"
#
# RATIFIED: `tests/run.sh --dry-run` is a user-facing surface, and the obligation that
# rides with it is that a dry run writes nothing. Before S25 the runner sampled the
# machine's pressure UNCONDITIONALLY, before the --dry-run early exit, so every dry run
# quietly appended one line to the ring documented at :131 as "print the job width and
# exit; run nothing" — nothing meant nothing, except one write. §2a proves the ring is
# byte-identical afterwards (count AND checksum — a rewrite that happened to keep the
# same line count would slip past a bare `wc -l`). §2b is the paired POSITIVE: the
# ORDINARY (non-dry) path this is an exception to must still sample exactly once, or the
# exception would have quietly swallowed the rule (AC-15) along with the bug.

ring_fingerprint() {  # <ring> -> "<byte count> <sha256>", cheap non-vacuity for "unchanged"
  printf '%s %s' "$(wc -c < "$1" | tr -d ' ')" "$(shasum "$1" | awk '{print $1}')"
}

RING_D="$TMPROOT/d/pressure.ring"
ring_of "$RING_D" "$NOW" "$S_CLEAR" "$S_CLEAR"
BEFORE_FP="$(ring_fingerprint "$RING_D")"
dry_run "$RING_D" "$S_CLEAR" 8
AFTER_FP="$(ring_fingerprint "$RING_D")"
expect_contains "2a --dry-run still prints the width" "JOBS=8" "$DRY_OUT"
expect_eq "2a …a dry run leaves the ring byte-identical (bytes+sha unchanged)" \
  "$BEFORE_FP" "$AFTER_FP"

# §2b THE PAIRED POSITIVE. Driving the real (non-dry, non-serial) path directly would
# launch this repo's whole roster — including this very suite, and cross-gate-agreement
# and fresh-home, which also drive --dry-run — so instead this copies the REAL
# tests/run.sh, byte for byte, into a scratch tree whose tests/ holds ONE two-line stub
# suite and nothing else. The run costs that one trivial suite, while the width
# computation this case exists to observe runs — and samples — long before the queue is
# even built, so the copy proves the same thing a real run would without paying for one.
#
# WHY A STUB AND NOT AN EMPTY tests/ (fixit 1.5.1). The roster is the directory now, and a
# runner asked to gate on an empty one REFUSES rather than reporting green over nothing —
# which would stop this drive before it ever sampled. The stub carries the pinned shebang
# the roster wall asks for; this tree has no framework, so that half of the wall is inert
# here and the stub needs nothing else.
ORD_TREE="$TMPROOT/ordinary"
mkdir -p "$ORD_TREE/tests/lib" "$ORD_TREE/payload/scripts/lib"
cp "${BIONIC_SCRIPTS_DIR}/tests/run.sh" "$ORD_TREE/tests/run.sh"
cp "${BIONIC_SCRIPTS_DIR}/tests/lib/resolve-roots.sh" "$ORD_TREE/tests/lib/resolve-roots.sh"
cp "${BIONIC_SCRIPTS_DIR}/payload/scripts/lib/"*.sh "$ORD_TREE/payload/scripts/lib/" 2>/dev/null
printf '#!/bin/bash\nexit 0\n' > "$ORD_TREE/tests/stub.test.sh"
expect_eq "2b the scratch runner is the shipped one, byte for byte (not vacuous)" "yes" \
  "$(cmp -s "${BIONIC_SCRIPTS_DIR}/tests/run.sh" "$ORD_TREE/tests/run.sh" && echo yes || echo no)"

RING_D2="$TMPROOT/d2/pressure.ring"
ring_of "$RING_D2" "$NOW" "$S_CLEAR"
BEFORE_LINES2=$(wc -l < "$RING_D2" | tr -d ' ')
( cd "$ORD_TREE" && env BIONIC_PRESSURE_RING="$RING_D2" BIONIC_NOW_EPOCH="$NOW" \
      BIONIC_PROBE_FREE_PCT=44 BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 \
      BIONIC_TEST_JOBS_CEILING=8 \
      bash tests/run.sh >/dev/null 2>&1 )
AFTER_LINES2=$(wc -l < "$RING_D2" | tr -d ' ')
expect_eq "2b the ordinary path still appends exactly one sample (AC-15 intact)" \
  "$((BEFORE_LINES2 + 1))" "$AFTER_LINES2"

echo
section "Section 3: BIONIC_TEST_JOBS is retired"

RING_E="$TMPROOT/e/pressure.ring"
ring_of "$RING_E" "$NOW" "$S_CLEAR"
DRY_OUT=""; DRY_ERR=""
DRY_OUT=$(cd "$BIONIC_SCRIPTS_DIR" && \
  env BIONIC_PRESSURE_RING="$RING_E" BIONIC_NOW_EPOCH="$NOW" \
      BIONIC_PROBE_FREE_PCT=44 BIONIC_PROBE_SWAP_PCT=69 BIONIC_PROBE_LOAD_1M=1.6 \
      BIONIC_TEST_JOBS=4 BIONIC_TEST_JOBS_CEILING=8 \
      bash "$RUN" --dry-run 2>"$TMPROOT/.err3")
DRY_ERR=$(cat "$TMPROOT/.err3")
expect_contains "3a a caller who still sets BIONIC_TEST_JOBS is told once, on stderr" \
  "BIONIC_TEST_JOBS is retired" "$DRY_ERR"
expect_contains "3b …and the value is ignored: width still comes from the rung (clear -> 8, not 4)" \
  "JOBS=8" "$DRY_OUT"

# A caller who never set it at all gets no notice.
RING_F="$TMPROOT/f/pressure.ring"
ring_of "$RING_F" "$NOW" "$S_CLEAR"
dry_run "$RING_F" "$S_CLEAR" 8
expect_absent "3c no notice when BIONIC_TEST_JOBS was never set" "BIONIC_TEST_JOBS is retired" "$DRY_ERR"

echo
section "Section 5: a garbage ceiling falls back, it does not kill the run (C-6)"

# `pressure_level` refuses a ceiling that is not a positive integer with exit 2 and prints
# nothing on stdout. `:-8` covers UNSET and nothing else, so `JOBS` came out empty and
# `xargs -P ""` aborted the whole run — and the wave's own briefs instruct agents to set
# this variable, so a typo is the likely way to meet it.
RING_G="$TMPROOT/g/pressure.ring"
for BAD_CEIL in 0 eight -1 "3 4"; do
  ring_of "$RING_G" "$NOW" "$S_CLEAR" "$S_CLEAR"
  dry_run "$RING_G" "$S_CLEAR" "$BAD_CEIL"
  expect_eq "5 ceiling [$BAD_CEIL]: the runner still exits 0" "0" "$DRY_ST"
  expect_contains "5 ceiling [$BAD_CEIL]: falls back to the default width" "JOBS=8" "$DRY_OUT"
  expect_contains "5 ceiling [$BAD_CEIL]: and the refusal is on stderr to explain it" \
    "pressure_level: need <ceiling> as a positive integer" "$DRY_ERR"
done

# The fallback is a FALLBACK, not a floor: a VALID ceiling still decides the width.
ring_of "$RING_G" "$NOW" "$S_CLEAR" "$S_CLEAR"
dry_run "$RING_G" "$S_CLEAR" 3
expect_contains "5 a valid ceiling of 3 is still honoured (not replaced by 8)" "JOBS=3" "$DRY_OUT"

finish
