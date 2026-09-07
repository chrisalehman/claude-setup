#!/bin/bash
# tests/run-predicate.test.sh — payload/scripts/lib/run.sh: docs_root, active_plan,
# active_run (L-RUN, wave-bionic-1.4.0-update, spec AC-8; plan design-ledger S1) and the
# session-bound readers run_open / open_runs / session_plan / session_run
# (wave-session-bound-run S1, 2026-09-04; spec AC-1, AC-3, AC-6).
#
# WHAT IT OWNS. The "is there a run to protect" predicate: active_run <root> is exit 0 +
# the plan path iff the newest plan (by mtime) under the docs root's plans/incidents trees
# carries a flush-left `## SDLC State` and an open state — `current:` 0-8, or 9 without a
# `- Step 9:` line carrying `delivered:`, or a task-scale `current: T<n>` — and the plan's
# frontmatter carries no `abandoned:` line; else exit 1 and prints nothing. Every always-on
# hook gates its own work behind this one call (ADOPT, Batch 1).
#
# AND, SINCE wave-session-bound-run, WHICH run answers for WHICH SESSION. `active_run` is
# root-keyed: two engaged sessions in one repository share its answer, which is the bug that
# wave exists to fix. R5-R8 below own the four readers that key the same question to a
# session — the verdict on one file (R5), the SET of open runs in a root (R6), the marker's
# `plan=` binding (R7), and the verdict a hook acts on (R8) — and R5's agreement rows hold
# `active_run` to being exactly `active_plan` + `run_open`, so the extraction stays lossless.
#
# FIXTURES mirror the plan's own SDLC State block shape (wave.plan.md's frontmatter and
# Step lines). The plan-search shape referenced for context is
# hooks/canonical-sdlc-evidence-gate.sh's resolve_docs_root/current-parsing — read for
# shape only, not copied: this library's interface is the simpler, single-purpose one the
# plan states (no fence-awareness, no misplacement sweep), not a restatement of the gate's
# richer parser.
#
# HERMETIC. Every plan is a fixture file under a mktemp sandbox; nothing reads a real
# .bionic tree or a live wave.
#
# Usage: bash tests/run-predicate.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LIB="$REPO_ROOT/payload/scripts/lib/run.sh"

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/run-predicate-test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# SUBSTRING, AS A FUNCTION. Nine rows below asked this with a one-line `case` inside a
# command substitution. Under bash 3.2 — what `/bin/bash` is on macOS, and what this
# file's own shebang names — that shape PARSES and then truncates the substitution at the
# first `)` at run time, so the assertion compared against the tail of its own source text
# instead of an answer. `bash -n` cannot see it; tests/cross-gate-agreement.test.sh §BP
# greps for it. Step-6 review C-2.
rp_contains() {  # <haystack> <needle> -> yes|no
  case "$1" in
    *"$2"*) printf 'yes' ;;
    *)      printf 'no'  ;;
  esac
}

# ============================================================
section "R0 — the library exists and parses"
# ============================================================
if [ -f "$LIB" ]; then ok "payload/scripts/lib/run.sh is on disk"; else
  no "payload/scripts/lib/run.sh is on disk" "$LIB"
fi
if bash -n "$LIB" 2>"$SANDBOX/.syn"; then ok "the library parses (bash -n)"; else
  no "the library parses (bash -n)" "$(cat "$SANDBOX/.syn")"
fi

# Sourcing prints nothing (plan: "Functions only; sourcing prints nothing.")
SRC_OUT=$(bash -c '. "$1" 2>&1' _ "$LIB")
expect_empty "sourcing the library prints nothing" "$SRC_OUT"

# ---- driven through a child bash that sources the library ----
call_docs_root() {  # <root> -> stdout
  bash -c '. "$1" || exit 1; docs_root "$2"' _ "$LIB" "$1" 2>"$SANDBOX/.err"
}
AR_OUT=""; AR_ST=0
call_active_run() {  # <root> -> sets AR_OUT, AR_ST
  AR_OUT=$(bash -c '. "$1" || exit 1; active_run "$2"' _ "$LIB" "$1" 2>"$SANDBOX/.err")
  AR_ST=$?
}
# call_active_run_pf <root> -> sets AR_OUT, AR_ST, from a child bash with `set -uo
# pipefail` ENABLED IN THAT CHILD. `set -o` options are shell-local, not inherited by a
# nested `bash -c` merely because the parent process has them set (verified: SHELLOPTS
# does not carry pipefail across this bash's own `bash -c` boundary on this machine) — so
# call_active_run above, run under this suite's own top-of-file `set -uo pipefail`,
# NEVER actually exercises active_run under pipefail; every hook that calls this library
# sources it directly in ITS OWN shell, where its own `set -uo pipefail` (dispatch-preflight
# .sh:66 et al.) is genuinely in effect. This helper re-states the option inside the child
# so the R4 fixtures below test the real production condition, not an inherited illusion
# of it (AC-21).
call_active_run_pf() {
  AR_OUT=$(bash -c 'set -uo pipefail; . "$1" || exit 1; active_run "$2"' _ "$LIB" "$1" 2>"$SANDBOX/.err")
  AR_ST=$?
}
AP_OUT=""; AP_ST=0
call_active_plan() {  # <root> -> sets AP_OUT, AP_ST
  AP_OUT=$(bash -c '. "$1" || exit 1; active_plan "$2"' _ "$LIB" "$1" 2>"$SANDBOX/.err")
  AP_ST=$?
}

# ============================================================
section "R1 — docs_root: default and .bionic/config.yaml override"
# ============================================================
ROOT1="$SANDBOX/r1"
mkdir -p "$ROOT1/.bionic"
expect_eq "docs_root defaults to <root>/.bionic/docs" "$ROOT1/.bionic/docs" "$(call_docs_root "$ROOT1")"

printf 'docs-root: .bionic/other-docs\n' > "$ROOT1/.bionic/config.yaml"
expect_eq "docs_root honours a relative docs-root: override" \
  "$ROOT1/.bionic/other-docs" "$(call_docs_root "$ROOT1")"

printf 'docs-root: /elsewhere/docs\n' > "$ROOT1/.bionic/config.yaml"
expect_eq "docs_root honours an absolute docs-root: override" \
  "/elsewhere/docs" "$(call_docs_root "$ROOT1")"
rm -f "$ROOT1/.bionic/config.yaml"

# ============================================================
section "R2 — active_plan / active_run fixtures"
# ============================================================
# mk_plan_in <root> <reldir under the docs root> <name> <current-line-body> [extra-lines...]
# The general form: mk_plan below is its plans/ special case. R6 needs `incidents/` and
# `plans/<epic>/` fixtures to show that open_runs walks the same two trees to the same
# depth as active_plan.
mk_plan_in() {
  local root="$1" rel="$2" name="$3" current="$4"
  shift 4
  local dir; dir="$root/.bionic/docs/$rel"
  mkdir -p "$dir"
  {
    echo "---"
    echo "governing-skill: superpowers:writing-plans"
    echo "sdlc-step: 3"
    echo "---"
    echo
    echo "# fixture plan"
    echo
    echo "## SDLC State"
    echo
    echo "integration-branch: main"
    echo "current: $current"
    for l in "$@"; do echo "$l"; done
  } > "$dir/$name"
  printf '%s/%s\n' "$dir" "$name"
}

# mk_plan <root> <name under docs/plans> <current-line-body> [extra-lines...]
# Writes a plan with the plan's own frontmatter/SDLC-State shape (wave.plan.md), prints
# its absolute path.
mk_plan() {
  local root="$1" name="$2" current="$3"
  shift 3
  mk_plan_in "$root" "plans" "$name" "$current" "$@"
}

# --- current 4 -> active ---
R="$SANDBOX/r2a"; mkdir -p "$R/.bionic"
P=$(mk_plan "$R" "wave.plan.md" "4" "- Step 4: in progress")
call_active_run "$R"
expect_eq "current: 4 -> active_run exits 0" 0 "$AR_ST"
expect_eq "current: 4 -> active_run prints the plan path" "$P" "$AR_OUT"

# --- current 9 without a delivered Step 9 line -> active ---
R="$SANDBOX/r2b"; mkdir -p "$R/.bionic"
P=$(mk_plan "$R" "wave.plan.md" "9" "- Step 9: report drafted, not yet delivered")
call_active_run "$R"
expect_eq "current: 9 without 'delivered:' -> active_run exits 0" 0 "$AR_ST"
expect_eq "current: 9 without 'delivered:' -> prints the plan path" "$P" "$AR_OUT"

# --- current 9 WITH a delivered Step 9 line -> inactive ---
R="$SANDBOX/r2c"; mkdir -p "$R/.bionic"
mk_plan "$R" "wave.plan.md" "9" "- Step 9: report record/x.md, delivered: 2026-09-02" >/dev/null
call_active_run "$R"
expect_eq "current: 9 with 'delivered:' -> active_run exits 1" 1 "$AR_ST"
expect_empty "current: 9 with 'delivered:' -> prints nothing" "$AR_OUT"

# --- frontmatter abandoned: line -> inactive ---
R="$SANDBOX/r2d"; mkdir -p "$R/.bionic/docs/plans"
cat > "$R/.bionic/docs/plans/wave.plan.md" <<'EOF'
---
governing-skill: superpowers:writing-plans
sdlc-step: 3
abandoned: chris 2026-09-02
---

## SDLC State

current: 4
- Step 4: in progress
EOF
call_active_run "$R"
expect_eq "frontmatter abandoned: -> active_run exits 1" 1 "$AR_ST"
expect_empty "frontmatter abandoned: -> prints nothing" "$AR_OUT"

# --- no plans dir -> inactive ---
R="$SANDBOX/r2e"; mkdir -p "$R/.bionic"
call_active_run "$R"
expect_eq "no plans dir -> active_run exits 1" 1 "$AR_ST"
expect_empty "no plans dir -> prints nothing" "$AR_OUT"

# --- task-scale current: T2 -> active ---
R="$SANDBOX/r2f"; mkdir -p "$R/.bionic"
P=$(mk_plan "$R" "task.plan.md" "T2" "- T2: in progress")
call_active_run "$R"
expect_eq "current: T2 -> active_run exits 0" 0 "$AR_ST"
expect_eq "current: T2 -> prints the plan path" "$P" "$AR_OUT"

# --- newest-by-mtime wins over an older closed plan ---
R="$SANDBOX/r2g"; mkdir -p "$R/.bionic"
OLD=$(mk_plan "$R" "old.plan.md" "9" "- Step 9: report record/x.md, delivered: 2026-08-01")
touch -t 202601010000 "$OLD"
NEW=$(mk_plan "$R" "new.plan.md" "4" "- Step 4: in progress")
call_active_plan "$R"
expect_eq "active_plan picks the newest file by mtime" "$NEW" "$AP_OUT"
call_active_run "$R"
expect_eq "newest-by-mtime (open) wins over an older closed plan -> active_run exits 0" 0 "$AR_ST"
expect_eq "…and prints the newer plan's path" "$NEW" "$AR_OUT"

# ============================================================
section "R3 — the plan-search DEPTH BOUND is 2, and it is the fleet's only one"
# ============================================================
#
# THE BOUND IS A CONTRACT, not an implementation detail, and it is pinned here because this
# library is now the ONE reader of "which *.md answers for this run" (POKER/2, ratified
# 2026-09-03: the tick's private copy is deleted and every hook asks this function). Two
# depths were live during the wave — the five hand-copies and the evidence gate walked 2,
# which is the bionic layout's own depth (`plans/<epic>/<wave>.plan.md`), and L-RUN shipped
# 3 — and tests/cross-gate-agreement.test.sh §S.3d PINNED the disagreement rather than
# papering over it. Unification resolves it AT 2: the gate's descend-2 read is the one held
# body-for-body by §S, deeper files under `plans/` are notes and scratch rather than plans,
# and a bound nobody can state from the layout is a bound that drifts again.
#
# BOTH DIRECTIONS, because the shallow half alone would pass on a library that had no bound
# at all: depth 2 is FOUND, depth 3 is NOT.
R="$SANDBOX/r3a"; mkdir -p "$R/.bionic/docs/plans/epic-99"
P2="$R/.bionic/docs/plans/epic-99/wave-01.plan.md"
{ echo "# fixture plan"; echo; echo "## SDLC State"; echo; echo "current: 4"; } > "$P2"
call_active_plan "$R"
expect_eq "a plan at depth 2 (plans/<epic>/<wave>.md) is found" "$P2" "$AP_OUT"

R="$SANDBOX/r3b"; mkdir -p "$R/.bionic/docs/plans/epic-99/sub"
P3="$R/.bionic/docs/plans/epic-99/sub/wave-01.plan.md"
{ echo "# fixture plan"; echo; echo "## SDLC State"; echo; echo "current: 4"; } > "$P3"
call_active_plan "$R"
expect_eq "a plan at depth 3 is OUT of the bound -> active_plan exits 1" 1 "$AP_ST"
expect_empty "…and prints nothing" "$AP_OUT"
call_active_run "$R"
expect_eq "…so active_run does not see it either" 1 "$AR_ST"

# The bound is on the SEARCH, not on the docs root: the same file one level shallower is
# found, so R3b measures the depth and not some other property of the fixture.
mv "$R/.bionic/docs/plans/epic-99/sub/wave-01.plan.md" "$R/.bionic/docs/plans/epic-99/"
call_active_plan "$R"
expect_eq "…while the same file at depth 2 is found (the fixture measures depth)" \
  "$R/.bionic/docs/plans/epic-99/wave-01.plan.md" "$AP_OUT"

# ============================================================
echo
section "R4 — SIGPIPE-under-pipefail does not flip a >64 KB plan's verdict (AC-21)"
# ============================================================
#
# WHY THIS SECTION EXISTS AND R0-R3 DID NOT CATCH IT (research-refusal.md VERDICT,
# 2026-09-03). `active_run` decides Step 9 by `_run_lines "$plan" | grep -qE
# '…delivered:'`. `grep -q`/`-m1` exit at their FIRST match; the awk feeding them is
# still writing when a match sits well before end-of-file, awk takes SIGPIPE and reports
# 141, and this whole suite runs under `set -uo pipefail` (line 24) — same as every hook
# that calls this library — so the PIPELINE's status becomes 141, not the grep's own 0.
# `if pipeline; then return 1; fi` reads that as false: a CLOSED run (current: 9,
# `delivered:` present) falls through to the Step-9-open arm and reads OPEN. Every fixture
# in R0-R3 is a handful of lines, so `awk` always finishes writing before `grep` even
# looks — too small to reach the SIGPIPE window at all. This section is the one place in
# the suite where the fixture is deliberately padded PAST that window, on this shell's own
# options, so a regression here is caught by size rather than only by content.
#
# THE MEASURED THRESHOLD (research-refusal.md INSTRUMENT §threshold table, this machine):
# 16 167 bytes never flips, 20 214 bytes flips 5/5. 64 KB is the plan's own AC-21 floor —
# comfortably past the measured knee — so every fixture below pads to that literal target,
# and each one asserts its own size to keep the premise visible if the target ever drifts.

mk_filler() {  # <min-bytes> -> that many-or-more bytes of inert filler lines on stdout
  local target="$1" n=0
  while [ "$n" -lt "$target" ]; do
    echo "filler filler filler filler filler filler filler filler filler filler"
    n=$((n + 72))
  done
}
FILLER_TARGET=70000   # > 64 KB (65536) with margin

# --- Step 9 delivered:, filler AFTER the state block, > 64 KB -> CLOSED ---
R="$SANDBOX/r4a"; mkdir -p "$R/.bionic/docs/plans"
F="$R/.bionic/docs/plans/wave.plan.md"
{
  echo "---"
  echo "governing-skill: superpowers:writing-plans"
  echo "sdlc-step: 9"
  echo "---"
  echo
  echo "# fixture plan"
  echo
  echo "## SDLC State"
  echo
  echo "integration-branch: main"
  echo "current: 9"
  echo "- Step 9: report record/x.md, delivered: 2026-09-02"
  echo
  echo "## Notes"
  echo
  mk_filler "$FILLER_TARGET"
} > "$F"
SZ=$(wc -c < "$F" | tr -d '[:space:]')
expect_eq "r4a fixture is actually past 64 KB (size=$SZ)" "yes" "$([ "$SZ" -gt 65536 ] && echo yes || echo no)"
call_active_run_pf "$R"
expect_eq "Step 9 delivered:, filler AFTER state, >64 KB -> active_run exits 1 (closed)" 1 "$AR_ST"
expect_empty "…and prints nothing" "$AR_OUT"

# --- Step 9 delivered:, filler BEFORE the state block, > 64 KB -> CLOSED ---
R="$SANDBOX/r4b"; mkdir -p "$R/.bionic/docs/plans"
F="$R/.bionic/docs/plans/wave.plan.md"
{
  echo "---"
  echo "governing-skill: superpowers:writing-plans"
  echo "sdlc-step: 9"
  echo "---"
  echo
  echo "# fixture plan"
  echo
  echo "## Notes"
  echo
  mk_filler "$FILLER_TARGET"
  echo
  echo "## SDLC State"
  echo
  echo "integration-branch: main"
  echo "current: 9"
  echo "- Step 9: report record/x.md, delivered: 2026-09-02"
} > "$F"
SZ=$(wc -c < "$F" | tr -d '[:space:]')
expect_eq "r4b fixture is actually past 64 KB (size=$SZ)" "yes" "$([ "$SZ" -gt 65536 ] && echo yes || echo no)"
call_active_run_pf "$R"
expect_eq "Step 9 delivered:, filler BEFORE state, >64 KB -> active_run exits 1 (closed)" 1 "$AR_ST"
expect_empty "…and prints nothing" "$AR_OUT"

# --- paired positive: current: 4, > 64 KB -> stays OPEN ---
R="$SANDBOX/r4c"; mkdir -p "$R/.bionic/docs/plans"
F="$R/.bionic/docs/plans/wave.plan.md"
{
  echo "---"
  echo "governing-skill: superpowers:writing-plans"
  echo "sdlc-step: 4"
  echo "---"
  echo
  echo "# fixture plan"
  echo
  echo "## SDLC State"
  echo
  echo "integration-branch: main"
  echo "current: 4"
  echo "- Step 4: in progress"
  echo
  echo "## Notes"
  echo
  mk_filler "$FILLER_TARGET"
} > "$F"
SZ=$(wc -c < "$F" | tr -d '[:space:]')
expect_eq "r4c fixture is actually past 64 KB (size=$SZ)" "yes" "$([ "$SZ" -gt 65536 ] && echo yes || echo no)"
call_active_run_pf "$R"
expect_eq "current: 4, >64 KB -> active_run exits 0 (open, paired positive)" 0 "$AR_ST"
expect_eq "…and prints the plan path" "$F" "$AR_OUT"

# --- paired positive: frontmatter abandoned:, > 64 KB -> CLOSED ---
R="$SANDBOX/r4d"; mkdir -p "$R/.bionic/docs/plans"
F="$R/.bionic/docs/plans/wave.plan.md"
{
  echo "---"
  echo "governing-skill: superpowers:writing-plans"
  echo "sdlc-step: 4"
  echo "abandoned: chris 2026-09-03"
  echo "---"
  echo
  echo "# fixture plan"
  echo
  echo "## SDLC State"
  echo
  echo "integration-branch: main"
  echo "current: 4"
  echo "- Step 4: in progress"
  echo
  echo "## Notes"
  echo
  mk_filler "$FILLER_TARGET"
} > "$F"
SZ=$(wc -c < "$F" | tr -d '[:space:]')
expect_eq "r4d fixture is actually past 64 KB (size=$SZ)" "yes" "$([ "$SZ" -gt 65536 ] && echo yes || echo no)"
call_active_run_pf "$R"
expect_eq "frontmatter abandoned:, >64 KB -> active_run exits 1 (closed, paired positive)" 1 "$AR_ST"
expect_empty "…and prints nothing" "$AR_OUT"

# ============================================================
echo
section "R5 — run_open <plan>: the verdict table, on ONE file, with no root walk"
# ============================================================
#
# WHY THIS FUNCTION EXISTS (wave-session-bound-run, spec §Design; AC-6). Until this wave the
# open/closed verdict was reachable only through `active_run <root>`, which chooses the file
# for you — the newest plan in the root. A session bound to a plan needs the verdict on THAT
# file, and `open_runs` needs it on every candidate, so the verdict is extracted here and
# `active_run` becomes `active_plan` + `run_open` + print.
#
# THE CONTRACT IS "UNCHANGED, BYTE FOR BYTE": every row below is a row `active_run` already
# decided the same way, and R2/R4 above still drive `active_run` over the same states. If the
# two ever disagree, one of the two sections goes red.
#
# run_open PRINTS NOTHING — the path is the caller's already. Every row asserts that beside
# its status, so an implementation that leaked the path could not pass.

RO_OUT=""; RO_ST=0
call_run_open() {  # <plan-path> -> sets RO_OUT, RO_ST
  RO_OUT=$(bash -c '. "$1" || exit 1; run_open "$2"' _ "$LIB" "$1" 2>"$SANDBOX/.err")
  RO_ST=$?
}

R5="$SANDBOX/r5"; mkdir -p "$R5/.bionic"

# --- the OPEN rows ---
P=$(mk_plan "$R5" "open-4.plan.md" "4" "- Step 4: in progress")
call_run_open "$P"
expect_eq "run_open: current: 4 -> exit 0 (open)" 0 "$RO_ST"
expect_empty "run_open: current: 4 -> prints nothing" "$RO_OUT"

P=$(mk_plan "$R5" "open-0.plan.md" "0")
call_run_open "$P"
expect_eq "run_open: current: 0 -> exit 0 (open)" 0 "$RO_ST"

P=$(mk_plan "$R5" "open-8b.plan.md" "8b" "- Step 8b: integrating")
call_run_open "$P"
expect_eq "run_open: current: 8b -> exit 0 (the sub-step letter is stripped)" 0 "$RO_ST"

P=$(mk_plan "$R5" "open-8a.plan.md" "8a")
call_run_open "$P"
expect_eq "run_open: current: 8a -> exit 0 (the sub-step letter is stripped)" 0 "$RO_ST"

P=$(mk_plan "$R5" "open-t3.plan.md" "T3" "- T3: in progress")
call_run_open "$P"
expect_eq "run_open: current: T3 -> exit 0 (task scale has no numbered close)" 0 "$RO_ST"

P=$(mk_plan "$R5" "open-9.plan.md" "9" "- Step 9: report drafted, not yet delivered")
call_run_open "$P"
expect_eq "run_open: current: 9 without 'delivered:' -> exit 0 (open)" 0 "$RO_ST"

P=$(mk_plan "$R5" "open-indented.plan.md" "  4" "- Step 4: in progress")
call_run_open "$P"
expect_eq "run_open: leading whitespace on current: is tolerated -> exit 0" 0 "$RO_ST"

# --- the CLOSED rows, each beside the open row above that shares its builder ---
P=$(mk_plan "$R5" "closed-9.plan.md" "9" "- Step 9: report record/x.md, delivered: 2026-09-02")
call_run_open "$P"
expect_eq "run_open: current: 9 WITH 'delivered:' -> exit 1 (closed)" 1 "$RO_ST"
expect_empty "run_open: closed -> prints nothing" "$RO_OUT"

P=$(mk_plan "$R5" "closed-12.plan.md" "12")
call_run_open "$P"
expect_eq "run_open: current: 12 (out of range) -> exit 1" 1 "$RO_ST"

P=$(mk_plan "$R5" "closed-junk.plan.md" "banana")
call_run_open "$P"
expect_eq "run_open: a non-numeric current: -> exit 1" 1 "$RO_ST"

R5D="$R5/.bionic/docs/plans"
cat > "$R5D/closed-abandoned.plan.md" <<'EOF'
---
governing-skill: superpowers:writing-plans
sdlc-step: 3
abandoned: chris 2026-09-04
---

## SDLC State

current: 4
- Step 4: in progress
EOF
call_run_open "$R5D/closed-abandoned.plan.md"
expect_eq "run_open: frontmatter abandoned: -> exit 1 regardless of current:" 1 "$RO_ST"

cat > "$R5D/closed-nocurrent.plan.md" <<'EOF'
---
governing-skill: superpowers:writing-plans
---

## SDLC State

integration-branch: main
EOF
call_run_open "$R5D/closed-nocurrent.plan.md"
expect_eq "run_open: no current: line at all -> exit 1" 1 "$RO_ST"

cat > "$R5D/closed-fenced-current.plan.md" <<'EOF'
---
governing-skill: superpowers:writing-plans
---

## SDLC State

An example of the block, not the block itself:

```
current: 4
```
EOF
call_run_open "$R5D/closed-fenced-current.plan.md"
expect_eq "run_open: a current: line only INSIDE a fence -> exit 1 (fence-aware)" 1 "$RO_ST"

call_run_open "$R5D/no-such-plan.md"
expect_eq "run_open: a path that does not exist -> exit 1" 1 "$RO_ST"
expect_empty "run_open: a missing path -> prints nothing" "$RO_OUT"

call_run_open ""
expect_eq "run_open: an empty path -> exit 1" 1 "$RO_ST"

# --- AGREEMENT: active_run is active_plan + run_open, and says so on the same fixtures ---
# R2's roots are still on disk. For each, active_run's status must equal run_open's status
# on the file active_plan names — the property that makes the extraction lossless.
for _r in r2a r2b r2c r2f; do
  call_active_plan "$SANDBOX/$_r"
  call_run_open "$AP_OUT"
  call_active_run "$SANDBOX/$_r"
  expect_eq "agreement ($_r): active_run's status == run_open on active_plan's file" \
    "$AR_ST" "$RO_ST"
done

# ============================================================
echo
section "R6 — open_runs <root>: every open run in the root, newest first"
# ============================================================
#
# WHY (spec §Design, ownership table "the open-run set"). Engagement binds a session to the
# sole open run when there is exactly one; session-start lists them when there are several;
# poker's `bind` verb validates membership. All three need the SET, which nothing could name
# before this wave — `active_run` answers with at most one path and only ever the newest.
#
# THE WALK IS active_plan's WALK: same two trees, same depth 2, same fence-aware
# `## SDLC State` filter. R6e drives all three of those properties through open_runs so a
# copy that drifted from active_plan's own walk is caught behaviourally, which is the wall
# the spec's ownership table names for this concept.
#
# ORDERING IS NEWEST-MTIME-FIRST, so line 1 is the file active_plan names whenever that file
# is itself open. R6d is the one case where the two answers differ: the newest plan is
# CLOSED, so active_run has no answer at all while the set is non-empty.

OR_OUT=""; OR_ST=0
call_open_runs() {  # <root> -> sets OR_OUT (newline-joined), OR_ST
  OR_OUT=$(bash -c '. "$1" || exit 1; open_runs "$2"' _ "$LIB" "$1" 2>"$SANDBOX/.err")
  OR_ST=$?
}
first_line() { printf '%s\n' "$1" | head -1; }
line_count() { [ -z "$1" ] && { echo 0; return; }; printf '%s\n' "$1" | wc -l | tr -d '[:space:]'; }

# --- R6a: a root whose only plan is CLOSED -> the set is empty; then re-open it ---
R="$SANDBOX/r6a"; mkdir -p "$R/.bionic"
C=$(mk_plan "$R" "only.plan.md" "9" "- Step 9: report record/x.md, delivered: 2026-09-02")
call_open_runs "$R"
expect_eq "open_runs: a root with one CLOSED plan -> exit 1" 1 "$OR_ST"
expect_empty "open_runs: …and prints nothing" "$OR_OUT"
# The paired positive on the SAME fixture: re-open that same file and the set is non-empty,
# so the empty answer above measured the verdict and not a broken walk.
mk_plan "$R" "only.plan.md" "4" "- Step 4: in progress" >/dev/null
call_open_runs "$R"
expect_eq "open_runs: …the same file re-opened -> exit 0" 0 "$OR_ST"
expect_eq "open_runs: …and it is the one line" "$C" "$OR_OUT"

# --- R6b: exactly one open run ---
R="$SANDBOX/r6b"; mkdir -p "$R/.bionic"
ONE=$(mk_plan "$R" "wave.plan.md" "4" "- Step 4: in progress")
call_open_runs "$R"
expect_eq "open_runs: one open run -> exit 0" 0 "$OR_ST"
expect_eq "open_runs: one open run -> one line, that path" "$ONE" "$OR_OUT"
expect_eq "open_runs: one open run -> exactly one line" 1 "$(line_count "$OR_OUT")"
call_active_run "$R"
expect_eq "open_runs line 1 == active_run's answer (one open run)" "$AR_OUT" "$(first_line "$OR_OUT")"

# --- R6c: two open runs and a closed one, mtimes controlled ---
R="$SANDBOX/r6c"; mkdir -p "$R/.bionic"
OLDOPEN=$(mk_plan "$R" "old-open.plan.md" "4" "- Step 4: in progress")
MIDSHUT=$(mk_plan "$R" "mid-closed.plan.md" "9" "- Step 9: report record/x.md, delivered: 2026-09-01")
NEWOPEN=$(mk_plan "$R" "new-open.plan.md" "4" "- Step 4: in progress")
touch -t 202601010000 "$OLDOPEN"
touch -t 202602010000 "$MIDSHUT"
touch -t 202603010000 "$NEWOPEN"
call_open_runs "$R"
expect_eq "open_runs: two open + one closed -> exit 0" 0 "$OR_ST"
expect_eq "open_runs: …exactly two lines" 2 "$(line_count "$OR_OUT")"
expect_eq "open_runs: …newest open first, older open second" \
  "$(printf '%s\n%s' "$NEWOPEN" "$OLDOPEN")" "$OR_OUT"
expect_eq "open_runs: …the CLOSED plan is not in the set" "no" \
  "$(rp_contains "$OR_OUT" "$MIDSHUT")"
call_active_run "$R"
expect_eq "open_runs line 1 == active_run's answer (two open runs)" "$AR_OUT" "$(first_line "$OR_OUT")"

# --- R6d: the newest plan is CLOSED — the set is NOT empty, active_run is ---
R="$SANDBOX/r6d"; mkdir -p "$R/.bionic"
DOPEN=$(mk_plan "$R" "open.plan.md" "4" "- Step 4: in progress")
DSHUT=$(mk_plan "$R" "closed.plan.md" "9" "- Step 9: report record/x.md, delivered: 2026-09-02")
touch -t 202601010000 "$DOPEN"
touch -t 202602010000 "$DSHUT"
call_active_run "$R"
expect_eq "newest plan closed -> active_run exits 1 (today's answer, unchanged)" 1 "$AR_ST"
call_open_runs "$R"
expect_eq "…while open_runs still finds the older OPEN plan -> exit 0" 0 "$OR_ST"
expect_eq "…and lists exactly it" "$DOPEN" "$OR_OUT"

# --- R6e: the walk is active_plan's walk — incidents/, depth 2, fence-aware ---
R="$SANDBOX/r6e"; mkdir -p "$R/.bionic"
EPLAN=$(mk_plan "$R" "wave.plan.md" "4" "- Step 4: in progress")
EINC=$(mk_plan_in "$R" "incidents" "inc-01.md" "4" "- Step 4: in progress")
EDEEP=$(mk_plan_in "$R" "plans/epic-99/sub" "deep.plan.md" "4" "- Step 4: in progress")
EFENCE="$R/.bionic/docs/plans/example.md"
cat > "$EFENCE" <<'EOF'
# a page ABOUT the lifecycle, not a plan

```
## SDLC State

current: 4
```
EOF
touch -t 202603010000 "$EPLAN"
touch -t 202602010000 "$EINC"
touch -t 202604010000 "$EDEEP"
touch -t 202605010000 "$EFENCE"
call_open_runs "$R"
expect_eq "open_runs: plans/ and incidents/ are both walked -> exit 0" 0 "$OR_ST"
expect_eq "open_runs: …two members, plans/ newest first" \
  "$(printf '%s\n%s' "$EPLAN" "$EINC")" "$OR_OUT"
expect_eq "open_runs: …a plan at depth 3 is OUT of the bound even though it is newest" "no" \
  "$(rp_contains "$OR_OUT" "$EDEEP")"
expect_eq "open_runs: …a fenced ## SDLC State is documentation, not a run" "no" \
  "$(rp_contains "$OR_OUT" "$EFENCE")"
call_active_plan "$R"
expect_eq "…and active_plan agrees on which file is newest-and-real" "$EPLAN" "$AP_OUT"

# --- R6g: the ORDER is the mtime's, and no path ever enters the sort (S10a, review P2c) ---
#
# WHY THIS ROW EXISTS. R6a–R6f measure membership; every one of them would stay green with
# the order reversed, because a re-keyed sort still prints every member. S10a rewrote the
# ordering pass (linear insertion → binary insertion, review P2c) and that is exactly the
# class of change whose failure mode is a set that is right and an order that is not — the
# first attempt at it, keyed on `stat`'s nanoseconds instead of the shell's own `-nt`,
# reordered 21 of 500 members on a tree built in one burst and every existing row stayed
# green, because they all set their mtimes with `touch -t`.
#
# THREE mtimes, NONE of them in the walk's own order, so no accident — neither "print in the
# order found" nor "print it backwards" — lands on the expected answer.
#
# THE PATHS CARRY SPACES, deliberately. The ordering keys are the mtime and the discovery
# index and the paths stay in a bash array, so a path that word-split would surface here as a
# member in the wrong slot or a member that vanished.
R="$SANDBOX/r6g"; mkdir -p "$R/.bionic"
G_MID=$(mk_plan "$R" "a walked one.plan.md" "4" "- Step 4: in progress")
G_OLD=$(mk_plan "$R" "b walked two.plan.md" "4" "- Step 4: in progress")
G_NEW=$(mk_plan "$R" "c walked three.plan.md" "4" "- Step 4: in progress")
touch -t 202602010000 "$G_MID"
touch -t 202601010000 "$G_OLD"
touch -t 202603010000 "$G_NEW"
call_open_runs "$R"
expect_eq "open_runs: three open plans -> exit 0" 0 "$OR_ST"
expect_eq "open_runs: …exactly three lines (the ordering dropped no member)" \
  3 "$(line_count "$OR_OUT")"
expect_eq "open_runs: …newest mtime first, oldest last, whatever order the walk found them" \
  "$(printf '%s\n%s\n%s' "$G_NEW" "$G_MID" "$G_OLD")" "$OR_OUT"
call_active_plan "$R"
expect_eq "open_runs line 1 == active_plan's answer, with spaces in every path" \
  "$G_NEW" "$AP_OUT"

# --- R6h: plans written inside ONE SECOND — the two selectors still agree (AC-9) ---
#
# THE LIMITATION IS DOCUMENTED, AND THIS IS WHAT THE DOCUMENTATION BUYS. `-nt`
# compares whole seconds under /bin/bash 3.2, so two plans written in the same
# second tie and the tie is broken by directory order — which of them
# `active_plan` names is genuinely unspecified, and asserting a winner here
# would pin the filesystem rather than the library. What is NOT unspecified is
# that both selectors resolve the tie the SAME way, because they run the same
# comparator over the same walk: `open_runs`' line 1 is `active_plan`'s answer.
# That is the invariant lib/run.sh accepts the whole-second reading in order to
# keep, and the reason a sub-second comparator in ONE of them was rejected
# rather than taken (see the block under `open_runs`).
#
# NO `touch -t` HERE, ON PURPOSE. Every other fixture in R6 sets its mtimes
# explicitly and can therefore never meet a tie; this one writes three plans as
# fast as the shell can and lets them collide, which is the state
# patrol-revive's rows 33/34 actually hit.
R="$SANDBOX/r6-burst"; mkdir -p "$R/.bionic"
mk_plan "$R" "burst-a.plan.md" "4" "- Step 4: in progress" >/dev/null
mk_plan "$R" "burst-b.plan.md" "4" "- Step 4: in progress" >/dev/null
mk_plan "$R" "burst-c.plan.md" "4" "- Step 4: in progress" >/dev/null
call_open_runs "$R"
call_active_plan "$R"
expect_eq "same-second burst: all three plans are in the open set" 3 "$(line_count "$OR_OUT")"
expect_eq "same-second burst: open_runs line 1 == active_plan's answer" \
  "$AP_OUT" "$(first_line "$OR_OUT")"

# --- R6f: no docs tree at all ---
R="$SANDBOX/r6f"; mkdir -p "$R/.bionic"
call_open_runs "$R"
expect_eq "open_runs: no plans dir -> exit 1" 1 "$OR_ST"
expect_empty "open_runs: no plans dir -> prints nothing" "$OR_OUT"

# ============================================================
echo
section "R7 — session_plan <root> <sid>: the marker's plan= field, and only that"
# ============================================================
#
# WHY (spec §Design, "Session binding"). hooks/engage.sh has written `plan=<path>` into
# engaged-<sid>.state since 1.4.1 and nothing has ever read it. This is the reader. It is
# deliberately NOT a verdict: it reports what the marker says, and session_run decides what
# that means.
#
# THE THREE UNBOUND SHAPES ARE ALL REAL. Absent is a session that never engaged; `plan=none`
# is what engage.sh writes when the root holds zero or several open runs; EMPTY is what
# tests/session-poker.test.sh:82 plants (`: > "$1/.bionic/tmp/engaged-$SID.state"`), so a
# reader that treated an empty marker as anything but unbound would break that suite's whole
# fixture set.
#
# THE SYMLINK REFUSAL is engaged_session's, restated: a link at the marker path is refused
# BEFORE it is followed, so a planted link cannot make a session read a plan= line from a
# file outside the tree.

SP_OUT=""; SP_ST=0
call_session_plan() {  # <root> <sid> -> sets SP_OUT, SP_ST
  SP_OUT=$(bash -c '. "$1" || exit 1; session_plan "$2" "$3"' _ "$LIB" "$1" "$2" 2>"$SANDBOX/.err")
  SP_ST=$?
}
mk_marker() {  # <root> <sid> <exact file body>
  local root="$1" sid="$2" body="$3"
  mkdir -p "$root/.bionic/tmp"
  printf '%s' "$body" > "$root/.bionic/tmp/engaged-$sid.state"
  chmod 600 "$root/.bionic/tmp/engaged-$sid.state"
}

R7="$SANDBOX/r7"; mkdir -p "$R7/.bionic/tmp"
P7=$(mk_plan "$R7" "wave.plan.md" "4" "- Step 4: in progress")

# --- the POSITIVE the negatives are measured against ---
mk_marker "$R7" "s-bound" "$(printf 'plan=%s\nengaged_at=2026-09-04T10:00:00Z\n' "$P7")"
call_session_plan "$R7" "s-bound"
expect_eq "session_plan: a marker with plan=<path> -> exit 0" 0 "$SP_ST"
expect_eq "session_plan: …prints exactly that path" "$P7" "$SP_OUT"

# --- the UNBOUND shapes ---
call_session_plan "$R7" "s-absent"
expect_eq "session_plan: no marker -> exit 1" 1 "$SP_ST"
expect_empty "session_plan: no marker -> prints nothing" "$SP_OUT"

mk_marker "$R7" "s-empty" ""
call_session_plan "$R7" "s-empty"
expect_eq "session_plan: an EMPTY marker -> exit 1 (session-poker.test.sh:82 plants one)" 1 "$SP_ST"
expect_empty "session_plan: an empty marker -> prints nothing" "$SP_OUT"

mk_marker "$R7" "s-none" "$(printf 'plan=none\nengaged_at=2026-09-04T10:00:00Z\n')"
call_session_plan "$R7" "s-none"
expect_eq "session_plan: plan=none -> exit 1" 1 "$SP_ST"
expect_empty "session_plan: plan=none -> prints nothing" "$SP_OUT"

mk_marker "$R7" "s-emptyval" "$(printf 'plan=\nengaged_at=2026-09-04T10:00:00Z\n')"
call_session_plan "$R7" "s-emptyval"
expect_eq "session_plan: an empty plan= value -> exit 1" 1 "$SP_ST"

mk_marker "$R7" "s-nofield" "$(printf 'engaged_at=2026-09-04T10:00:00Z\n')"
call_session_plan "$R7" "s-nofield"
expect_eq "session_plan: a marker with no plan= line at all -> exit 1" 1 "$SP_ST"

# --- LINE ENDINGS: translated, never deleted (the _run_lines discipline) ---
printf 'plan=%s\r\nengaged_at=2026-09-04T10:00:00Z\r\n' "$P7" \
  > "$R7/.bionic/tmp/engaged-s-crlf.state"
call_session_plan "$R7" "s-crlf"
expect_eq "session_plan: a CRLF marker -> exit 0" 0 "$SP_ST"
expect_eq "session_plan: …and the path carries no trailing CR" "$P7" "$SP_OUT"

# --- the marker-path guards, inherited from engaged_marker_path/engaged_session ---
ln -s "$R7/.bionic/tmp/engaged-s-bound.state" "$R7/.bionic/tmp/engaged-s-link.state"
call_session_plan "$R7" "s-link"
expect_eq "session_plan: a SYMLINK at the marker path is refused before it is followed" 1 "$SP_ST"
expect_empty "session_plan: …and prints nothing, though its target is a valid marker" "$SP_OUT"

call_session_plan "$R7" "unknown"
expect_eq "session_plan: the 'unknown' sid fallback -> exit 1" 1 "$SP_ST"

call_session_plan "$R7" "bad/sid"
expect_eq "session_plan: a sid outside [A-Za-z0-9_-] -> exit 1" 1 "$SP_ST"

call_session_plan "$R7" ""
expect_eq "session_plan: an empty sid -> exit 1" 1 "$SP_ST"

# ============================================================
echo
section "R8 — session_run <root> <sid>: the verdict a hook acts on"
# ============================================================
#
# THE FOUR VERDICTS (spec §Design, "Run verdict"):
#   bound-open <path>    exit 0   the session's own plan, and it is open
#   bound-closed <path>  exit 2   the session's own plan, delivered/abandoned/missing
#   fallback <path>      exit 0   no binding; today's newest-plan answer, said out loud
#   none                 exit 1   no binding and no open run
#
# THE INVARIANT THIS SECTION EXISTS FOR (AC-6, D2 "a binding is a commitment"): a bound
# session NEVER yields fallback. R8f is the drift case — a session bound to a delivered plan
# while another plan in the same root is wide open — and it must answer bound-closed on its
# OWN plan, never bound-open or fallback on the other one. That is the whole bug: one root,
# two runs, and a hook that re-infers identity by scanning would hand session B session A's
# run at exactly the moment B's own run ended.
#
# session_run DOES NOT REQUIRE THE MARKER TO EXIST. An unengaged caller is simply unbound and
# gets the fallback; whether the hook should act at all is engaged_session's question, asked
# separately and first.

SR_OUT=""; SR_ST=0
call_session_run() {  # <root> <sid> -> sets SR_OUT, SR_ST
  SR_OUT=$(bash -c '. "$1" || exit 1; session_run "$2" "$3"' _ "$LIB" "$1" "$2" 2>"$SANDBOX/.err")
  SR_ST=$?
}

# One root, three plans: two open (alpha older, beta newest) and gamma delivered between
# them, plus delta abandoned. active_run's answer here is beta, for every unbound session.
R8="$SANDBOX/r8"; mkdir -p "$R8/.bionic/tmp"
ALPHA=$(mk_plan "$R8" "alpha.plan.md" "4" "- Step 4: in progress")
GAMMA=$(mk_plan "$R8" "gamma.plan.md" "9" "- Step 9: report record/g.md, delivered: 2026-09-03")
BETA=$(mk_plan "$R8" "beta.plan.md" "4" "- Step 4: in progress")
cat > "$R8/.bionic/docs/plans/delta.plan.md" <<'EOF'
---
governing-skill: superpowers:writing-plans
abandoned: chris 2026-09-04
---

## SDLC State

current: 4
EOF
DELTA="$R8/.bionic/docs/plans/delta.plan.md"
GHOST="$R8/.bionic/docs/plans/ghost.plan.md"
touch -t 202601010000 "$ALPHA"
touch -t 202602010000 "$GAMMA"
touch -t 202601150000 "$DELTA"
touch -t 202603010000 "$BETA"
call_active_run "$R8"
expect_eq "r8 premise: active_run's root-keyed answer is beta" "$BETA" "$AR_OUT"

# --- R8a: unbound sessions get the fallback, and it says so ---
call_session_run "$R8" "u-absent"
expect_eq "session_run: no marker -> exit 0" 0 "$SR_ST"
expect_eq "session_run: no marker -> 'fallback <newest open plan>'" "fallback $BETA" "$SR_OUT"

mk_marker "$R8" "u-empty" ""
call_session_run "$R8" "u-empty"
expect_eq "session_run: an EMPTY marker -> fallback, exit 0" 0 "$SR_ST"
expect_eq "session_run: …naming the newest open plan" "fallback $BETA" "$SR_OUT"

mk_marker "$R8" "u-none" "$(printf 'plan=none\nengaged_at=2026-09-04T10:00:00Z\n')"
call_session_run "$R8" "u-none"
expect_eq "session_run: plan=none -> fallback, exit 0" 0 "$SR_ST"
expect_eq "session_run: …naming the newest open plan" "fallback $BETA" "$SR_OUT"

# --- R8b: bound to the newest open plan ---
mk_marker "$R8" "b-beta" "$(printf 'plan=%s\nengaged_at=2026-09-04T10:00:00Z\n' "$BETA")"
call_session_run "$R8" "b-beta"
expect_eq "session_run: bound to the newest open plan -> exit 0" 0 "$SR_ST"
expect_eq "session_run: …'bound-open <beta>', not 'fallback'" "bound-open $BETA" "$SR_OUT"

# --- R8c: bound to an OLDER open plan — the binding beats the newest-plan scan ---
mk_marker "$R8" "b-alpha" "$(printf 'plan=%s\nengaged_at=2026-09-04T10:00:00Z\n' "$ALPHA")"
call_session_run "$R8" "b-alpha"
expect_eq "session_run: bound to an OLDER open plan -> exit 0" 0 "$SR_ST"
expect_eq "session_run: …'bound-open <alpha>' — the binding beats the newest-plan scan" \
  "bound-open $ALPHA" "$SR_OUT"
expect_eq "session_run: …and beta is nowhere in the answer" "no" \
  "$(rp_contains "$SR_OUT" "$BETA")"

# --- R8d/e/f: the three closed bindings, each beside an open beta in the same root ---
mk_marker "$R8" "b-gamma" "$(printf 'plan=%s\nengaged_at=2026-09-04T10:00:00Z\n' "$GAMMA")"
call_session_run "$R8" "b-gamma"
expect_eq "session_run: bound to a DELIVERED plan -> exit 2" 2 "$SR_ST"
expect_eq "session_run: …'bound-closed <gamma>'" "bound-closed $GAMMA" "$SR_OUT"
expect_eq "session_run: …it NEVER falls through to the other open plan in the root" "no" \
  "$(rp_contains "$SR_OUT" "$BETA")"

mk_marker "$R8" "b-delta" "$(printf 'plan=%s\nengaged_at=2026-09-04T10:00:00Z\n' "$DELTA")"
call_session_run "$R8" "b-delta"
expect_eq "session_run: bound to an ABANDONED plan -> exit 2" 2 "$SR_ST"
expect_eq "session_run: …'bound-closed <delta>'" "bound-closed $DELTA" "$SR_OUT"

mk_marker "$R8" "b-ghost" "$(printf 'plan=%s\nengaged_at=2026-09-04T10:00:00Z\n' "$GHOST")"
call_session_run "$R8" "b-ghost"
expect_eq "session_run: bound to a MISSING path -> exit 2" 2 "$SR_ST"
expect_eq "session_run: …'bound-closed <ghost>', the path it was promised" \
  "bound-closed $GHOST" "$SR_OUT"
expect_eq "session_run: …and not the newest plan in the root" "no" \
  "$(rp_contains "$SR_OUT" "$BETA")"

# --- R8g: line endings on the marker ---
printf 'plan=%s\r\nengaged_at=2026-09-04T10:00:00Z\r\n' "$ALPHA" \
  > "$R8/.bionic/tmp/engaged-b-crlf.state"
call_session_run "$R8" "b-crlf"
expect_eq "session_run: a CRLF marker -> exit 0" 0 "$SR_ST"
expect_eq "session_run: …'bound-open <alpha>' with no trailing CR in the path" \
  "bound-open $ALPHA" "$SR_OUT"

# --- R8h: two sessions, one root, one tree state — the wave's whole point ---
# Nothing about the FILESYSTEM differs between these two calls. Only the session id does,
# and that is the entire fix: before this wave both calls went through active_run and both
# answered beta.
call_session_run "$R8" "b-alpha"; SR_A="$SR_OUT"
call_session_run "$R8" "b-beta";  SR_B="$SR_OUT"
expect_eq "TWO SESSIONS, ONE ROOT: session A resolves to alpha" "bound-open $ALPHA" "$SR_A"
expect_eq "TWO SESSIONS, ONE ROOT: session B resolves to beta, same tree state" \
  "bound-open $BETA" "$SR_B"
expect_eq "TWO SESSIONS, ONE ROOT: the two answers are not the same run" "no" \
  "$([ "$SR_A" = "$SR_B" ] && echo yes || echo no)"

# --- R8i: a root with NO open run ---
R="$SANDBOX/r8b"; mkdir -p "$R/.bionic/tmp"
SHUT=$(mk_plan "$R" "done.plan.md" "9" "- Step 9: report record/x.md, delivered: 2026-09-02")
call_session_run "$R" "n-absent"
expect_eq "session_run: no binding and no open run -> exit 1" 1 "$SR_ST"
expect_eq "session_run: …prints 'none'" "none" "$SR_OUT"

mk_marker "$R" "n-none" "$(printf 'plan=none\nengaged_at=2026-09-04T10:00:00Z\n')"
call_session_run "$R" "n-none"
expect_eq "session_run: plan=none and no open run -> exit 1, 'none'" 1 "$SR_ST"
expect_eq "session_run: …prints 'none'" "none" "$SR_OUT"

# The paired positive on the SAME root: re-open that one plan and the same unbound session
# gets a fallback, so 'none' above measured the run state and not a broken root.
mk_plan "$R" "done.plan.md" "4" "- Step 4: in progress" >/dev/null
call_session_run "$R" "n-absent"
expect_eq "session_run: …the same root with that plan re-opened -> fallback, exit 0" 0 "$SR_ST"
expect_eq "session_run: …naming it" "fallback $SHUT" "$SR_OUT"

# ============================================================
echo
section "R9 — config_value <root> <key> <default>: one reader for .bionic/config.yaml"
# ============================================================
#
# WHY (spec §Design §2, R1). `live-window:` is the second key this library needs out of
# `.bionic/config.yaml`; `docs-root:` was the first and `docs_root` reads it inline. Rather
# than a second inline grep/sed pair drifting away from the first, the read is one function
# and R9 holds it to the conventions `docs_root` already established over its own fixture
# battery: FIRST match wins, the value is trimmed, surrounding quotes come off, an indented
# key still reads, and anything missing — the file, the key, or a value — is the default.
#
# THE DEFAULT IS AN ARGUMENT, NOT A CONSTANT. A library that baked `7d` in would put the
# window in two places the moment a second caller wanted a different one, which is the
# defect this wave is named for.

call_config_value() {  # <root> <key> <default> -> stdout
  bash -c '. "$1" || exit 1; config_value "$2" "$3" "$4"' _ "$LIB" "$1" "$2" "$3" 2>"$SANDBOX/.err"
}

# --- R9a: no config file at all -> the default ---
R9="$SANDBOX/r9a"; mkdir -p "$R9/.bionic"
expect_eq "config_value: no .bionic/config.yaml -> the default" "7d" \
  "$(call_config_value "$R9" "live-window" "7d")"

# --- R9b: the key is present -> its value, and the default is NOT consulted ---
printf 'live-window: 30d\n' > "$R9/.bionic/config.yaml"
expect_eq "config_value: the key is present -> its value" "30d" \
  "$(call_config_value "$R9" "live-window" "7d")"

# --- R9c: a file that exists but does not carry the key -> the default ---
printf 'docs-root: .bionic/docs\n' > "$R9/.bionic/config.yaml"
expect_eq "config_value: a config without the key -> the default" "7d" \
  "$(call_config_value "$R9" "live-window" "7d")"

# --- R9d: the four spellings docs_root already tolerates ---
printf 'live-window:    12h   \n' > "$R9/.bionic/config.yaml"
expect_eq "config_value: surrounding whitespace is trimmed" "12h" \
  "$(call_config_value "$R9" "live-window" "7d")"
printf 'live-window: "3d"\n' > "$R9/.bionic/config.yaml"
expect_eq "config_value: a double-quoted value comes back unquoted" "3d" \
  "$(call_config_value "$R9" "live-window" "7d")"
printf "live-window: '4d'\n" > "$R9/.bionic/config.yaml"
expect_eq "config_value: a single-quoted value comes back unquoted" "4d" \
  "$(call_config_value "$R9" "live-window" "7d")"
printf '  live-window: 5d\n' > "$R9/.bionic/config.yaml"
expect_eq "config_value: an indented key still reads" "5d" \
  "$(call_config_value "$R9" "live-window" "7d")"

# --- R9e: duplicate lines -> the FIRST wins, as docs_root's own head -1 does ---
printf 'live-window: 1d\nlive-window: 99d\n' > "$R9/.bionic/config.yaml"
expect_eq "config_value: duplicate keys -> the first match, not the last" "1d" \
  "$(call_config_value "$R9" "live-window" "7d")"

# --- R9f: a key with an EMPTY value is not a value ---
printf 'live-window:\n' > "$R9/.bionic/config.yaml"
expect_eq "config_value: the key present with no value -> the default" "7d" \
  "$(call_config_value "$R9" "live-window" "7d")"

# --- R9g: it is a general reader — docs_root's own key comes back through it too ---
printf 'docs-root: .bionic/other-docs\nlive-window: 2d\n' > "$R9/.bionic/config.yaml"
expect_eq "config_value: any key, not just this wave's" ".bionic/other-docs" \
  "$(call_config_value "$R9" "docs-root" "")"
expect_eq "config_value: …and the other one from the same file" "2d" \
  "$(call_config_value "$R9" "live-window" "7d")"

# --- R9h: docs_root reads its key THROUGH this function (epic-22 wave-01, N1) ---
#
# WHAT THIS ROW USED TO SAY, AND WHY IT STILL EARNS ITS LINE. `docs_root` read `docs-root:`
# with six inline lines of its own and this function read every other key; the spec kept
# them apart for one wave ("only this key uses it in this wave"), so what held them together
# was agreement on the same input. The sharpest case was the quote-strip running BEFORE the
# trailing-space trim in BOTH, so a quoted value with a trailing space keeps its closing
# quote — a shared WART, pinned so that a slice fixing one reader and not the other failed
# here rather than in a hook.
#
# There is one reader now: `docs_root` and `config_value` both live in lib/roots.sh and
# `docs_root` is a caller. So the pair cannot drift, and the row below is no longer an
# agreement check — it is the wart itself, pinned once, plus the fact that the general
# reader is what `docs-root:` goes through. tests/roots.test.sh §1a pins the same wart from
# the docs_root side.
printf 'docs-root: "d1" \nlive-window: "3d" \n' > "$R9/.bionic/config.yaml"
expect_eq "config_value: a quoted value with a trailing space keeps its closing quote" '3d"' \
  "$(call_config_value "$R9" "live-window" "7d")"
expect_eq "…and docs_root reads its own key exactly the same way" "$R9/d1\"" \
  "$(call_docs_root "$R9")"

# ============================================================
echo
section "R10 — live_runs <root>: the open runs whose plan is still WARM"
# ============================================================
#
# WHY (spec AC-1, R1; design §1 "Run"). `open_runs` answers "not finished". A repository
# accumulates those: a wave abandoned in spirit but never marked, a plan parked for a month.
# Engagement needs "not finished AND recently touched" so it can bind when exactly one run
# is actually being worked, and session-start needs the difference so it can COUNT the quiet
# ones instead of listing them. LIVE ⊆ OPEN, always: this function filters open_runs' answer
# and never widens it, so no gate that measures against the open rule can be loosened by it.
#
# THE CLOCK IS AN INPUT (`BIONIC_NOW_EPOCH`). Every fixture below backdates a plan with
# `touch -t` and pins "now" to a constant, so the rows measure the WINDOW rather than how
# long the suite took to reach them, and nothing here depends on the machine's date.
#
# THE WINDOW IS A DURATION IN PROSE, read through `config_value` with `7d` as the default and
# parsed on the poker's `parse_seconds` grammar widened by one unit — `Nd|Nh|Nm|Ns`. Days are
# the unit the key is written in and the one that grammar lacks.

LR_OUT=""; LR_ST=0
call_live_runs() {  # <root> <now-epoch> -> sets LR_OUT, LR_ST
  LR_OUT=$(BIONIC_NOW_EPOCH="$2" bash -c '. "$1" || exit 1; live_runs "$2"' _ "$LIB" "$1" \
           2>"$SANDBOX/.err")
  LR_ST=$?
}
# lr_age <file> <seconds before LR_NOW> — portable epoch -> `touch -t` stamp. BSD `date -r`
# and GNU `date -d @…` both render LOCAL time, which is the timezone `touch -t` reads, so the
# round trip lands on the instant asked for on either platform.
LR_NOW=1789000000
lr_age() {
  local at=$(( LR_NOW - $2 ))
  touch -t "$(date -r "$at" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$at" +%Y%m%d%H%M.%S)" "$1"
}
LR_DAY=86400

# --- R10a: two open plans, one backdated past the default window ---
R="$SANDBOX/r10a"; mkdir -p "$R/.bionic"
LR_FRESH=$(mk_plan "$R" "fresh.plan.md" "4" "- Step 4: in progress")
LR_STALE=$(mk_plan "$R" "stale.plan.md" "4" "- Step 4: in progress")
lr_age "$LR_FRESH" 3600
lr_age "$LR_STALE" $(( 8 * LR_DAY ))
call_open_runs "$R"
expect_eq "live_runs fixture: BOTH plans are open (the filter has something to remove)" 2 \
  "$(line_count "$OR_OUT")"
call_live_runs "$R" "$LR_NOW"
expect_eq "live_runs: default 7d window -> exit 0" 0 "$LR_ST"
expect_eq "live_runs: …exactly the plan touched an hour ago" "$LR_FRESH" "$LR_OUT"
expect_eq "live_runs: …exactly one line" 1 "$(line_count "$LR_OUT")"
expect_eq "live_runs: …the 8-day-old open plan is NOT live" "no" \
  "$(rp_contains "$LR_OUT" "$LR_STALE")"

# --- R10b: the SAME tree with live-window: 30d -> both ---
printf 'live-window: 30d\n' > "$R/.bionic/config.yaml"
call_live_runs "$R" "$LR_NOW"
expect_eq "live_runs: live-window: 30d on the same tree -> exit 0" 0 "$LR_ST"
expect_eq "live_runs: …now BOTH are live, newest first" \
  "$(printf '%s\n%s' "$LR_FRESH" "$LR_STALE")" "$LR_OUT"
# …and back again on the same fixture, so the row above measured the config and not the tree.
printf 'live-window: 30m\n' > "$R/.bionic/config.yaml"
call_live_runs "$R" "$LR_NOW"
expect_eq "live_runs: live-window: 30m -> the hour-old plan falls out too, exit 1" 1 "$LR_ST"
expect_empty "live_runs: …and prints nothing" "$LR_OUT"
# THE BOUNDARY IS INCLUSIVE, AND IT IS ASSERTED RATHER THAN INHERITED. "Within the window"
# has to decide what happens at exactly the window's own age; a plan touched precisely one
# hour ago under a 1h window is IN, and one second older is out. Left unpinned this is the
# edge that moves silently under any rewrite of the comparison.
printf 'live-window: 1h\n' > "$R/.bionic/config.yaml"
lr_age "$LR_FRESH" 3600
call_live_runs "$R" "$LR_NOW"
expect_eq "live_runs: a plan exactly one window old is INSIDE the window" "$LR_FRESH" "$LR_OUT"
lr_age "$LR_FRESH" 3601
call_live_runs "$R" "$LR_NOW"
expect_eq "live_runs: …and one second older is outside it, exit 1" 1 "$LR_ST"
expect_empty "live_runs: …with no output" "$LR_OUT"
lr_age "$LR_FRESH" 3600
printf 'live-window: 90m\n' > "$R/.bionic/config.yaml"
call_live_runs "$R" "$LR_NOW"
expect_eq "live_runs: live-window: 90m -> the hour-old plan is back inside the window" \
  "$LR_FRESH" "$LR_OUT"
printf 'live-window: 4000s\n' > "$R/.bionic/config.yaml"
call_live_runs "$R" "$LR_NOW"
expect_eq "live_runs: …and seconds are a unit too" "$LR_FRESH" "$LR_OUT"
rm -f "$R/.bionic/config.yaml"

# --- R10c: live_runs ⊆ open_runs on a three-plan fixture ---
#
# THE SUBSET IS ASSERTED LINE BY LINE, not by counting: two sets of the same size can still
# disagree about their members, and "live ⊆ open" is the invariant every gate depends on.
R="$SANDBOX/r10c"; mkdir -p "$R/.bionic"
S_NEW=$(mk_plan "$R" "one.plan.md" "4" "- Step 4: in progress")
S_MID=$(mk_plan "$R" "two.plan.md" "6" "- Step 6: in progress")
S_OLD=$(mk_plan "$R" "three.plan.md" "4" "- Step 4: in progress")
lr_age "$S_NEW" 60
lr_age "$S_MID" $(( 2 * LR_DAY ))
lr_age "$S_OLD" $(( 40 * LR_DAY ))
call_open_runs "$R"
call_live_runs "$R" "$LR_NOW"
expect_eq "live ⊆ open: the open set has all three" 3 "$(line_count "$OR_OUT")"
expect_eq "live ⊆ open: …the live set has the two inside the window" 2 "$(line_count "$LR_OUT")"
LR_MISSING=""
while IFS= read -r lr_line; do
  [ -n "$lr_line" ] || continue
  grep -qxF -- "$lr_line" <<<"$OR_OUT" || LR_MISSING="$LR_MISSING$lr_line "
done <<<"$LR_OUT"
expect_eq "live ⊆ open: every live member is an open member" "" "$LR_MISSING"
expect_eq "live ⊆ open: …and the order is open_runs' own, newest first" \
  "$(printf '%s\n%s' "$S_NEW" "$S_MID")" "$LR_OUT"
expect_eq "live ⊆ open: …the 40-day-old plan is open but not live" "yes" \
  "$(grep -qxF -- "$S_OLD" <<<"$OR_OUT" && echo yes || echo no)"

# --- R10d: a DELIVERED plan is in neither set, however fresh its mtime ---
#
# The filter narrows open_runs; it must never reach past it. A closed plan touched one second
# ago is the case where a filter written against the WALK instead of against the SET would
# show up as a live run that no gate considers open.
R="$SANDBOX/r10d"; mkdir -p "$R/.bionic"
D_OPEN=$(mk_plan "$R" "open.plan.md" "4" "- Step 4: in progress")
D_SHUT=$(mk_plan "$R" "shut.plan.md" "9" "- Step 9: report record/x.md, delivered: 2026-09-02")
lr_age "$D_OPEN" 7200
lr_age "$D_SHUT" 1
call_open_runs "$R"
call_live_runs "$R" "$LR_NOW"
expect_eq "live_runs: a delivered plan touched a second ago is not OPEN" "no" \
  "$(rp_contains "$OR_OUT" "$D_SHUT")"
expect_eq "live_runs: …and therefore not LIVE either, however warm" "no" \
  "$(rp_contains "$LR_OUT" "$D_SHUT")"
expect_eq "live_runs: …while the open one beside it IS live" "$D_OPEN" "$LR_OUT"

# --- R10e: no open runs at all -> exit 1, silent (open_runs' own answer, unchanged) ---
R="$SANDBOX/r10e"; mkdir -p "$R/.bionic"
call_live_runs "$R" "$LR_NOW"
expect_eq "live_runs: no docs tree -> exit 1" 1 "$LR_ST"
expect_empty "live_runs: …and prints nothing" "$LR_OUT"

# --- R10f: a malformed window is a REFUSAL to widen, not a guess ---
#
# `parse_seconds` refuses rather than guesses, and so does this. The safe direction when the
# window cannot be read is the DEFAULT, because a window of zero would empty the live set and
# an unbounded one would make `live` mean `open` — both silently.
R="$SANDBOX/r10f"; mkdir -p "$R/.bionic"
F_FRESH=$(mk_plan "$R" "fresh.plan.md" "4" "- Step 4: in progress")
F_STALE=$(mk_plan "$R" "stale.plan.md" "4" "- Step 4: in progress")
lr_age "$F_FRESH" 3600
lr_age "$F_STALE" $(( 20 * LR_DAY ))
printf 'live-window: soon\n' > "$R/.bionic/config.yaml"
call_live_runs "$R" "$LR_NOW"
expect_eq "live_runs: an unreadable window falls back to the 7d default, not to everything" \
  "$F_FRESH" "$LR_OUT"

# --- R10g: BIONIC_NOW_EPOCH is what "now" means, and the fixtures prove it moves ---
#
# Every row above pins the clock. This one moves it: the SAME tree, read from a moment 20
# days later, has no live run at all — so the env pin is the input the rows depend on and not
# a constant they ignore.
rm -f "$R/.bionic/config.yaml"
call_live_runs "$R" "$LR_NOW"
expect_eq "live_runs: at LR_NOW the fresh plan is live" "$F_FRESH" "$LR_OUT"
call_live_runs "$R" "$(( LR_NOW + 20 * LR_DAY ))"
expect_eq "live_runs: …and 20 days later, on the same tree, nothing is" 1 "$LR_ST"
expect_empty "live_runs: …with no output" "$LR_OUT"
finish
