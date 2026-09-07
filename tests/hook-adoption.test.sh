#!/bin/bash
# tests/hook-adoption.test.sh — ADOPT: every hook on the library spine, always-on.
# (bionic 1.4.0, wave-bionic-1.4.0-update slice ADOPT; spec AC-7, AC-8, AC-9, AC-12,
# AC-16; design §2 "order in every hook: load, active_run, own work".)
#
# WHAT IS UNDER TEST. Not a library — a CONVENTION, held across eighteen files that
# the CLI invokes independently. Three claims, each of which has its own way of going
# silently wrong:
#
#   1. THE IDIOM IS ONE TEXT. Every hook carries `bionic_loader_pin`'s block byte for
#      byte, under a `BIONIC_LIB_WANT=` line naming exactly what it sources. A hand
#      edit to one copy is the drift this pins; a copy that wants a library it never
#      sources is the drift the WANT/source pairing pins.
#   2. THE FACTS HAVE ONE OWNER. No hook resolves a project root, a session id or an
#      active run by restating the algorithm. `project_root`, `session_id`,
#      `active_run` — the library answers, and the hook asks.
#   3. THE PREDICATE ACTUALLY GATES. A static call to `active_run` proves nothing; a
#      hook could call it and ignore the answer. So every run-scoped hook is DRIVEN
#      three times over real fixtures: no `.bionic` anywhere (silent), a `.bionic`
#      whose plan is CLOSED (silent), and the same fixture with the plan OPEN (NOT
#      silent). The third case is the anti-vacuity control — without it a hook that
#      exits 0 at line 1 would pass the first two.
#
# FAIL DIRECTION BY THE COST OF THE MISTAKE (design ledger S4). Two hooks are walls
# over an irreversible action and refuse when they cannot load — hooks/protect-main.sh
# and hooks/canonical-sdlc-evidence-gate.sh, permitting exactly four repair commands
# by whole-string match so a broken publish cannot lock the user out of the repair.
# Every other hook prints one line and steps aside. §6 drives both classes.
#
# DIRECTION IS NOT REACH, and §6b drives the difference. protect-main is armed in every
# project on the machine, so it refuses everywhere it cannot read a command. The
# evidence gate is run-scoped: outside a run it has nothing to say, and a library it
# cannot load does not give it something to say. A fail-closed wall must therefore know
# whether it is armed BEFORE it refuses — from an on-disk fact, since the library that
# would have told it is the thing that is missing.
#
# HERMETIC. Every fixture lives under one `mktemp -d`; HOME and BIONIC_PLUGINS_DIR are
# overridden into it for every driven call, so nothing here reads the real ~/.claude.
#
# Usage: bash tests/hook-adoption.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/roster-row.sh"

HOOKS="$BIONIC_HOOKS_DIR"
REPO="$BIONIC_SCRIPTS_DIR"
RUNNER="$REPO/tests/run.sh"
LOADER_LIB="$REPO/payload/scripts/lib/loader.sh"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/bionic-adopt.XXXXXX") || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

# expect_eq, expect_empty, expect_nonempty, expect_contains are the
# framework's (tests/lib/assert.sh) — identical semantics to the private
# definitions this suite carried (S7, AC-12).

# ── THE ROSTER OF ADOPTED HOOKS ──────────────────────────────────────────────
#
# Three columns, because the three claims are per-hook properties, not global ones:
#   name | fail class (closed|open) | run-scoped (yes|no)
#
# RUN-SCOPED IS NOT THE SAME AS ADOPTED. hooks/protect-main.sh and
# hooks/protect-database.sh guard damage that is wrong in every project the session
# ENGAGED bionic in, wave or no wave, so they never consult the run. (Machine-wide is what
# they were until 2026-09-03; Chris's ruling put every wall behind the engagement marker,
# which is why protect-database now carries a loader at all — the predicate lives in the
# library. Its direction is OPEN: a wall whose scope it cannot read must not bind a
# session that never consented.) Everything else is a
# governance hook: it has nothing to say outside a run and must say nothing.
# background-suite-guard runs only behind agent-context-guard, whose own roster
# check already scopes it, so it loads the library without the run predicate.
# engage.sh is the one `yes` that is not a gate. It reads the run to decide what to write
# into the marker's `plan=` field and writes the marker either way — engagement is what
# decides WHETHER a wall acts, the plan only WHAT — so the third column here records that
# the call is present, which is all this suite can see, and tests/engage.test.sh owns the
# behaviour the column cannot express (AC-18: no plan on disk, marker still written).
#
# THE THIRD COLUMN IS NARROWER SINCE task-engaged-session, and the change is a change of
# SUBJECT, not of coverage. What scopes a hook now is ENGAGEMENT — this session having
# invoked canonical-sdlc, `engaged_session` in lib/run.sh — and the run predicate is left
# only where a hook reads the plan for DATA: dispatch-preflight for the budget ceiling,
# context-spend for the step boundary, patrol-duties-gate for the plan basename,
# patrol-revive for the run its Patrol serves. landing-gate, execution-recorder and
# stop-guard read nothing out of the plan: they are the roster lifecycle, which begins
# before a plan exists (a run's Step 0 precedes its plan) and outlives the run that
# created it, so their `active_run` reads are gone and their rows say `no`.
ADOPTED='
protect-main|closed|no
protect-database|open|no
canonical-sdlc-evidence-gate|closed|yes
farm-out-reminder|open|no
background-suite-guard|open|no
dispatch-preflight|open|yes
canonical-sdlc-governing-skill|open|yes
landing-gate|open|no
execution-recorder|open|no
stop-guard|open|no
context-spend|open|yes
patrol-duties-gate|open|yes
patrol-revive|open|yes
agent-context-guard|open|no
preflight-probe|open|no
stop-orders|open|no
session-sweeper|open|no
stop-check|open|no
engage|open|no
'

section "0 — the carrier and non-vacuity"

BLOCK="$SANDBOX/canonical-block.txt"
( . "$LOADER_LIB" && bionic_loader_pin ) > "$BLOCK" 2>"$SANDBOX/.pinerr"
BLOCK_LINES=$(wc -l < "$BLOCK" | tr -d ' ')
if [ "${BLOCK_LINES:-0}" -gt 50 ]; then
  ok "bionic_loader_pin prints the canonical block ($BLOCK_LINES lines)"
else
  no "bionic_loader_pin prints the canonical block" "got $BLOCK_LINES lines: $(cat "$SANDBOX/.pinerr")"
fi

# extract_block <file> -> the marker-delimited span, markers inclusive
extract_block() {
  awk '/^# --- bionic-loader\/v2 BEGIN$/{f=1} f{print} f&&/^# --- bionic-loader\/v2 END$/{exit}' "$1"
}
# want_line <file> -> the line immediately ABOVE the BEGIN marker
want_line() {
  awk '/^# --- bionic-loader\/v2 BEGIN$/{print prev; exit} {prev=$0}' "$1"
}

section "1 — one idiom, byte for byte, under a WANT line that matches what is sourced"

while IFS='|' read -r name class scoped; do
  [ -n "$name" ] || continue
  f="$HOOKS/$name.sh"
  if [ ! -f "$f" ]; then no "$name.sh exists" "$f"; continue; fi

  expect_eq "$name carries the canonical loader block byte for byte" \
    "$(cat "$BLOCK")" "$(extract_block "$f")"

  wl=$(want_line "$f")
  case "$wl" in
    BIONIC_LIB_WANT=\"*\") ok "$name declares BIONIC_LIB_WANT on the line above the block" ;;
    *) no "$name declares BIONIC_LIB_WANT on the line above the block" "line above BEGIN was: [$wl]" ;;
  esac

  # Every wanted basename is actually sourced out of $BIONIC_LIB, and nothing is
  # sourced out of it that was not wanted: a hook that sources an unwanted library
  # is a hook the loader never checked for, which is a NUL dereference by another
  # name the first time that file is the one missing.
  wants=$(printf '%s' "$wl" | sed -e 's/^BIONIC_LIB_WANT="//' -e 's/"$//')
  sourced=$(grep -oE '^\. "\$BIONIC_LIB/[a-z.-]+\.sh"' "$f" | sed -E 's|^\. "\$BIONIC_LIB/||; s|"$||' | sort | tr '\n' ' ' | sed 's/ $//')
  expect_eq "$name sources exactly the libraries it wants" \
    "$(printf '%s' "$wants" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')" "$sourced"

  # THE FAIL DIRECTION IS DECLARED, not inferred. Exactly one of the two calls
  # appears, and the closed pair passes the command text so the repair allowlist
  # has something to match.
  n_closed=$(grep -c 'loader_fail_closed "' "$f")
  n_open=$(grep -c 'loader_fail_open "' "$f")
  case "$class" in
    closed) expect_eq "$name fails CLOSED on a missing library (and only that)" "1 0" "$n_closed $n_open" ;;
    open)   expect_eq "$name fails OPEN on a missing library (and only that)"   "0 1" "$n_closed $n_open" ;;
  esac
done <<EOF
$ADOPTED
EOF

section "2 — one root: no hook restates the walk"
#
# The eight `resolve_project_root` copies this replaces were byte-identical by
# assertion and divergent by history; the library ends the family. Slice POKER
# converted the last carrier (session-poker.sh) in parallel with this slice, so the
# family is empty; this assertion is what notices a copy creeping back.
STRAGGLERS=$(grep -ln '^resolve_project_root()' "$HOOKS"/*.sh 2>/dev/null | xargs -n1 basename 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
expect_eq "no hook still defines a private resolve_project_root (POKER landed the poker on the spine)" \
  "" "$STRAGGLERS"

while IFS='|' read -r name class scoped; do
  [ -n "$name" ] || continue
  f="$HOOKS/$name.sh"
  [ -f "$f" ] || continue
  case "$name" in
    protect-main|background-suite-guard) continue ;;  # neither reads a root
  esac
  if grep -qE '=\$\(project_root |=\$\(project_root$|project_root "' "$f"; then
    ok "$name resolves its root through the library"
  else
    no "$name resolves its root through the library" "no project_root call in $f"
  fi
done <<EOF
$ADOPTED
EOF

section "3 — one session id: every reader asks the library"
#
# The env value is primary and the payload is a witness (design §1). A hook that
# reads `.session_id` straight out of its payload has silently chosen the witness
# over the record, which is the divergence R-1 measured. So: every hook that
# derives a session id calls `session_id`, and the payload read that remains is
# the ARGUMENT to that call, never the answer.
SID_READERS='agent-context-guard preflight-probe stop-orders session-sweeper stop-check landing-gate execution-recorder dispatch-preflight patrol-revive context-spend farm-out-reminder session-start engage patrol-duties-gate stop-guard
canonical-sdlc-evidence-gate canonical-sdlc-governing-skill protect-main protect-database background-suite-guard'
for name in $SID_READERS; do
  f="$HOOKS/$name.sh"
  [ -f "$f" ] || { no "$name.sh exists" "$f"; continue; }
  if grep -q 'session_id "' "$f"; then
    ok "$name takes its session id from the library"
  else
    no "$name takes its session id from the library" "no session_id call in $f"
  fi
done

# THE LIST IS COMPLETE, not just each named member correct (auditor A-1, AC-2): a static
# list can omit a real reader forever and every row above still passes silently.
# session-start.sh was exactly that member — a session_id caller this wave added,
# unpinned by this list until the line above — so the roster is now also DERIVED from the
# tree and compared to the hand-written one, byte for byte, the same technique used above
# for the private-resolver family (`ADOPTED`/no-stragglers, §1).
SID_ACTUAL=$(grep -l 'session_id "' "$HOOKS"/*.sh 2>/dev/null \
  | xargs -n1 basename 2>/dev/null | sed 's/\.sh$//' | sort | tr '\n' ' ' | sed 's/ $//')
SID_EXPECTED=$(printf '%s\n' $SID_READERS | sort | tr '\n' ' ' | sed 's/ $//')
expect_eq "the session-id reader roster names every hook that calls session_id, and no other" \
  "$SID_EXPECTED" "$SID_ACTUAL"

section "4 — one run predicate: no hook restates it, the run-scoped ones call it"
#
# has_sdlc_state() was a five-copy family plus one merged reimplementation, and every
# one of them answered "is there a run" by restating the algorithm. The library answers
# it once. session-poker.sh was the last carrier — named here rather than excused — and
# slice SCHED deleted its copy (POKER/2, ratified 2026-09-03), so the family is now EMPTY.
# The second row is the one with teeth: an empty grep also describes a fleet that lost the
# predicate altogether, so the tick is asked to name the library functions it calls instead.
HS_CARRIERS=$(grep -ln '^has_sdlc_state()' "$HOOKS"/*.sh 2>/dev/null | xargs -n1 basename 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
expect_eq "NO hook defines has_sdlc_state any more — the family is gone, not shrunk" \
  "" "$HS_CARRIERS"
# THE TICK NAMES TWO LIBRARY FUNCTIONS NOW, and which one is which matters.
# wave-session-bound-run moved the tick's own question from `active_plan` to `session_run`;
# the surviving `active_plan` call is `resolve_run`'s `none` arm, which is what keeps DISARM
# reachable for an unbound session whose run has already closed (S6 finding A). Asserting
# only `active_plan` would now pass a tick that never asked whose run it was in, so both are
# named and each says which arm it stands for.
if grep -q 'session_run "' "$HOOKS/session-poker.sh" 2>/dev/null; then
  ok "…and the tick asks lib/run.sh:session_run whose run this session is in"
else
  no "…and the tick asks lib/run.sh:session_run whose run this session is in" \
     "no session_run call in $HOOKS/session-poker.sh"
fi
if grep -q 'active_plan "' "$HOOKS/session-poker.sh" 2>/dev/null; then
  ok "…and still reaches active_plan for the unbound-and-closed arm DISARM needs"
else
  no "…and still reaches active_plan for the unbound-and-closed arm DISARM needs" \
     "no active_plan call in $HOOKS/session-poker.sh"
fi

# THE THIRD COLUMN'S PREDICATE IS `session_run`, NOT `active_run` (wave-session-bound-run).
# `active_run "$ROOT"` answered "is there a run in this PROJECT" — one answer per repository,
# which is the bug the wave was opened for: two engaged sessions in one root shared a run
# identity. `session_run "$ROOT" "$SID"` answers per session. Every hook this roster marks
# run-scoped was converted, so the proxy grep moved with them; a hook that reverted to the
# project-keyed reader fails the `yes` row here rather than passing on a call that no longer
# answers the question the column names.
#
# THE `no` ROWS ARE STRICTER THAN THEY WERE: a hook that is not run-scoped must call NEITHER
# reader. Under the old text a non-run-scoped hook could have picked up `session_run` and
# stayed green, which is exactly the direction this wave made reachable.
while IFS='|' read -r name class scoped; do
  [ -n "$name" ] || continue
  f="$HOOKS/$name.sh"
  [ -f "$f" ] || continue
  if grep -q 'session_run "' "$f"; then found=yes; else found=no; fi
  if grep -qE 'active_run "|session_run "' "$f"; then found_any=yes; else found_any=no; fi
  case "$scoped" in
    yes) expect_eq "$name gates on session_run, the session-keyed predicate" "yes" "$found" ;;
    no)  expect_eq "$name is NOT run-scoped and reads neither run predicate" "no" "$found_any" ;;
  esac
done <<EOF
$ADOPTED
EOF

# THE ONE SURVIVING `active_run` CALLER, NAMED RATHER THAN EXCUSED. The evidence gate keeps
# `active_run "$PROJECT_DIR"` on its unbound arm on purpose (S3 assumption 3): the fallback
# path is not a NEW path that agrees with the old one, it IS the old one, re-asked through
# the same function every pre-wave session used. That is the strongest form of AC-3, and it
# is also the thing a reader would delete as redundant — so the roster of hooks still
# calling the project-keyed reader is derived from the tree and pinned by value. A second
# hook picking the call back up shows here.
AR_CALLERS=$(grep -l 'active_run "' "$HOOKS"/*.sh 2>/dev/null \
  | xargs -n1 basename 2>/dev/null | sed 's/\.sh$//' | sort | tr '\n' ' ' | sed 's/ $//')
expect_eq "canonical-sdlc-evidence-gate is the ONLY hook still calling active_run, and it is the AC-3 fallback arm" \
  "canonical-sdlc-evidence-gate" "$AR_CALLERS"

# THE SAME PIN FOR `active_plan`, WHICH HAD NONE (S10a, review D3). `active_run` is one of
# TWO project-keyed readers this wave left standing, and only one of them was held to a set.
# `active_plan` has exactly two callers and each is a named exception: the evidence gate
# re-derives the fallback plan through the pre-wave path on purpose (AC-3 fidelity), and the
# tick keeps it for `resolve_run`'s `none` arm, where an unbound session over a closed run
# still needs a plan to read DISARM out of. Three separate pins name the tick's call by hand
# and nothing named the gate's, so a THIRD hook picking up the project-keyed selector — the
# exact regression this section exists to catch for `active_run` — showed up nowhere.
AP_CALLERS=$(grep -l 'active_plan "' "$HOOKS"/*.sh 2>/dev/null \
  | xargs -n1 basename 2>/dev/null | sed 's/\.sh$//' | sort | tr '\n' ' ' | sed 's/ $//')
expect_eq "active_plan has exactly TWO callers, and both are named exceptions" \
  "canonical-sdlc-evidence-gate session-poker" "$AP_CALLERS"

# ENGAGE IS THE WRITER, NOT A CONSUMER, and the roster's `no` above must not be read as
# "engage ignores the session". It reads the marker's `plan=` FIELD through `session_plan` to
# answer "is this session already bound"; it does not ask for a verdict, because a binding is
# preserved whether or not its plan is still open (S10a, review C-1) and because asking would
# put an `active_run` walk on the unbound path for an answer the hook discards (review P1).
expect_eq "engage reads the binding FIELD (session_plan), which is what the writer needs" "yes" \
  "$(grep -q 'session_plan "' "$HOOKS/engage.sh" && echo yes || echo no)"
expect_eq "…and asks for no run VERDICT: neither session_run nor active_run" "no" \
  "$(grep -qE 'session_run "|active_run "' "$HOOKS/engage.sh" && echo yes || echo no)"

section "5 — the predicate GATES: silent with no run, silent with a closed run, live with an open one"

SID="ad0pt111-2222-3333-4444-555555555555"

# mk_root <name> <state>  -> a project root; state = none|closed|open
#   none   : a real directory, no .bionic anywhere above it (HOME is the sandbox)
#   closed : .bionic with a plan at `current: 9` carrying a delivered Step-9 line
#   open   : the same plan at `current: 4`
mk_root() {
  # TWO STATEMENTS, NOT ONE. `local a="$1" b="$SANDBOX/x/$a"` expands every word BEFORE it
  # assigns any of them, so the second reference reads an EMPTY $a and every fixture lands
  # in one shared directory — which is not a broken test, it is a test that quietly stops
  # discriminating. The same trap is recorded at tests/cross-gate-agreement.test.sh's
  # `j_mutant`.
  local name="$1" state="$2"
  local root="$SANDBOX/roots/$name"
  mkdir -p "$root"
  # `none` STAYS UNENGAGED, and cannot be otherwise: engagement's marker lives in
  # `.bionic/tmp`, so a project with no `.bionic` at all is by construction a project this
  # session never triggered bionic in. That is what the `none` arms below now assert, and
  # it is the same silence they always asserted.
  [ "$state" = "none" ] && { printf '%s' "$root"; return 0; }
  mkdir -p "$root/.bionic/docs/plans/epic-99" "$root/.bionic/tmp"
  # ENGAGED (task-engaged-session, 2026-09-03): every hook in this file asks whether the
  # session invoked the canonical-sdlc skill before it asks anything else, so a fixture
  # meant to exercise the RUN predicate has to get past that question first. Without this
  # line every silence assertion below would hold for the wrong reason and the §5
  # anti-vacuity control would have nothing left to discriminate.
  : > "$root/.bionic/tmp/engaged-$SID.state"
  local cur="4" step9="- Step 9: (pending)"
  case "$state" in
    closed) cur="9"; step9="- Step 9: delivered: record/x.md" ;;
    # open9 is the evidence gate's control pair: the SAME plan as `closed`, one line
    # different. A run at step 9 without a `delivered:` line is still open (AC-8), and
    # the gate then has step-9 evidence to demand — so the two fixtures differ by
    # exactly the fact under test and nothing else.
    open9)  cur="9" ;;
  esac
  cat > "$root/.bionic/docs/plans/epic-99/wave-01.plan.md" <<PLAN
---
canonical_sdlc_version: 14
intent: build
rigor: audited
scale: wave
---

# fixture plan

## SDLC State

integration-branch: main
intent: build
rigor: audited
scale: wave
current: $cur

- Step 4: implementation
$step9
PLAN
  printf '%s' "$root"
}

# seed_hook <hook> <root> — the PRECONDITIONS a hook needs before its run gate is even
# reachable. These are fixtures of each hook's own relevance hoist, never of the fact under
# test: the landing sweep and the recorder read a roster and exit silently without one, and
# the Patrol monitor reads a stamp and exits silently unless it is stale. A fixture that
# skipped them would make every silence below unfalsifiable.
seed_hook() {  # <hook> <root>
  local hook="$1" root="$2" ts
  # ENGAGEMENT IS NOW A PRECONDITION OF REACHING THE RUN PREDICATE AT ALL
  # (task-engaged-session). Every hook below asks `engaged_session` before it asks
  # `active_run`, so without this marker each fixture would be silent for the wrong reason
  # and §5's silence assertions — and the control that discriminates them — would prove
  # nothing about the predicate they are named for. Planted here rather than in mk_root so
  # the `none` fixture, which deliberately has no .bionic at all, keeps its meaning.
  mkdir -p "$root/.bionic/tmp" 2>/dev/null || true
  : > "$root/.bionic/tmp/engaged-$SID.state"
  case "$hook" in
    landing-gate|execution-recorder|stop-guard)
      {
        roster_header
        roster_row_fixture status=intended session="$SID" name=w1-impl agent_id= \
          launched_at=2026-08-05T00:00:00Z model= \
          deliverable="$root/.bionic/docs/record/never.md" duration='30 minutes' \
          tool_use_id=toolu_ADOPT1
        # …and the same row IDENTIFIED, which is what makes it addressable to the landing
        # sweep: a row with no agent id cannot be told apart from one still in flight.
        roster_row_fixture status=identified session="$SID" name=w1-impl \
          agent_id=aw1impl-1111111111111111 launched_at=2026-08-05T00:00:00Z model= \
          deliverable="$root/.bionic/docs/record/never.md" duration='30 minutes' \
          tool_use_id=toolu_ADOPT1
      } > "$root/.bionic/tmp/roster-$SID.state"
      ;;
    patrol-revive)
      # A stale stamp against a one-second interval: staleness is an MTIME, never a sleep.
      printf 'poker-interval: 1s\n' > "$root/.bionic/config.yaml"
      printf 'patrol-stamp/v1|at=2026-08-27T00:00:00Z|session=%s|verb=arm\n' "$SID" \
        > "$root/.bionic/tmp/patrol-$SID.state"
      ts="$(date -v-600S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-600 seconds" +%Y%m%d%H%M.%S)"
      touch -t "$ts" "$root/.bionic/tmp/patrol-$SID.state"
      ;;
  esac
}

# drive <hook> <payload-json> [extra-env...]  -> DRV_ST / DRV_OUT / DRV_ERR
drive() {
  local hook="$1" payload="$2"; shift 2
  DRV_OUT=$(printf '%s' "$payload" | env HOME="$SANDBOX/home" \
      BIONIC_PLUGINS_DIR="$SANDBOX/plugins" CLAUDE_CODE_SESSION_ID="$SID" \
      "$@" bash "$HOOKS/$hook.sh" 2>"$SANDBOX/.err")
  DRV_ST=$?
  DRV_ERR=$(cat "$SANDBOX/.err")
  return 0
}

mkdir -p "$SANDBOX/home" "$SANDBOX/plugins"

# A transcript the Stop-channel hooks can parse: one user prompt that IS a Patrol
# tick, and no duties after it — the shape patrol-duties-gate refuses.
TICK_TR="$SANDBOX/tick.jsonl"
# THE PATROL MARKER LEADS THE ROW (task-engaged-session T6, AC-22). A tick used to be any
# USER row containing `session-poker.sh tick`, which the injected canonical-sdlc SKILL.md
# body also contains; it is now a row whose FIRST TOKEN is `bionic-patrol session=<sid8>`
# for this session. hooks/patrol-duties-gate.sh reads no other shape, so a fixture carrying
# the old one leaves this hook inert and every assertion about it vacuous.
printf '%s\n' \
  "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"bionic-patrol session=${SID:0:8} — Patrol tick. Run: bash hooks/session-poker.sh tick\"}}" \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}],"usage":{"input_tokens":1000}}}' \
  > "$TICK_TR"

# payload_for <hook> <cwd> -> the smallest payload that reaches that hook's work
payload_for() {
  local hook="$1" cwd="$2"
  case "$hook" in
    canonical-sdlc-evidence-gate)
      jq -n --arg s "$SID" --arg c "$cwd" '{session_id:$s,cwd:$c,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"git commit -m wip"}}' ;;
    farm-out-reminder)
      jq -n --arg s "$SID" --arg c "$cwd" '{session_id:$s,cwd:$c,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"bash tests/run.sh"}}' ;;
    stop-guard)
      jq -n --arg s "$SID" --arg c "$cwd" '{session_id:$s,cwd:$c,hook_event_name:"PreToolUse",tool_name:"TaskStop",tool_input:{task_id:"w1-impl"}}' ;;
    execution-recorder)
      # The COMPLETION arm, over the row seed_hook plants: it needs an agentId and a
      # tool_use_id that names a row, or it exits at its relevance hoist.
      jq -n --arg s "$SID" --arg c "$cwd" --arg t "$TICK_TR" \
        '{session_id:$s, transcript_path:$t, cwd:$c,
          hook_event_name:"PostToolUse", tool_name:"Agent",
          tool_input:{description:"a dispatch", prompt:"go", subagent_type:"implementor",
                      run_in_background:true, name:"w1-impl"},
          tool_response:{isAsync:true, status:"async_launched",
                         agentId:"aw1impl-1111111111111111", description:"a dispatch",
                         resolvedModel:"claude-sonnet-5", prompt:"go"},
          tool_use_id:"toolu_ADOPT1", duration_ms:6}' ;;
    context-spend)
      jq -n --arg s "$SID" --arg c "$cwd" --arg t "$TICK_TR" '{session_id:$s,cwd:$c,transcript_path:$t,hook_event_name:"Stop"}' ;;
    patrol-duties-gate)
      jq -n --arg s "$SID" --arg c "$cwd" --arg t "$TICK_TR" '{session_id:$s,cwd:$c,transcript_path:$t,hook_event_name:"Stop",stop_hook_active:false}' ;;
    patrol-revive)
      jq -n --arg s "$SID" --arg c "$cwd" --arg t "$TICK_TR" '{session_id:$s,cwd:$c,transcript_path:$t,hook_event_name:"Stop",stop_hook_active:false}' ;;
    landing-gate)
      # `background_tasks` is what makes a Stop payload legible to the sweep — it is the
      # list of what is STILL RUNNING, and the gate exits before anything else without it.
      jq -n --arg s "$SID" --arg c "$cwd" --arg t "$TICK_TR" '{session_id:$s,cwd:$c,transcript_path:$t,hook_event_name:"Stop",stop_hook_active:false,background_tasks:[]}' ;;
    dispatch-preflight)
      jq -n --arg s "$SID" --arg c "$cwd" '{session_id:$s,cwd:$c,hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{description:"d",subagent_type:"implementor",prompt:"Do the thing.\nExpected artifact: '"$cwd"'/.bionic/docs/record/x.md\n"}}' ;;
    canonical-sdlc-governing-skill)
      jq -n --arg s "$SID" --arg c "$cwd" --arg p "$cwd/.bionic/docs/plans/epic-99/wave-01.plan.md" '{session_id:$s,cwd:$c,hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$p,content:"x"}}' ;;
  esac
}

# canonical-sdlc-governing-skill is NOT in this set, and the omission is the deviation
# logged as ADOPT/5 rather than an oversight. The artifact it exists to gate is the one
# that CREATES a run — a wave's plan, written into a project that has no plan yet — so
# `active_run` is false at the exact moment the frontmatter contract must bind. It is
# armed by the PROJECT instead, and §5b drives that rule on its own terms.
# NARROWED AT task-engaged-session, for the reason §4's preamble gives: a hook is scoped by
# ENGAGEMENT now, and only a hook that still reads the plan for data can be silent because
# the run is closed. dispatch-preflight, landing-gate, execution-recorder, stop-guard and
# patrol-duties-gate left this loop — every one of them acts for an ENGAGED session whether
# or not a plan is on disk (AC-23), which is the change this wave exists to make. Their
# scoping is driven in their own suites, on the switch that actually scopes them: marker
# absent -> silent, marker present -> the same behaviour as today.
# farm-out-reminder LEFT TOO, at step-6 review R-1. It had kept `active_run` below its new
# engagement guard, which made the nudge plan-bound against a design that says the opposite:
# knowing a suite command belongs in a subagent needs no plan, and the sessions most in need
# of the reminder are the ones in Step 0 through Step 3 that have not written one. The
# paired arms live in tests/cmd-class.test.sh §R-1.
RUN_SCOPED='canonical-sdlc-evidence-gate context-spend patrol-revive'

# unrun_mutant <hook> -> a copy of the hook with the run predicate neutralised
#
# THE ANTI-VACUITY DISCRIMINATOR, and it has to be a mutation rather than a happy-path
# fixture. Every assertion in §5 says a hook was SILENT, and silence is also what a hook
# that exits at line 1 produces — so each silence has to be paired with a demonstration
# that THIS payload, in THIS fixture, would have produced something had the run been open.
# Building nine per-hook happy paths would mean nine chances to build a fixture that
# reaches the gate by accident; neutralising the predicate reaches it by construction.
#
# `active_run` is redefined AFTER the hook has sourced the library, so the shim wins, and
# it answers with the fixture's own plan path — the value every caller goes on to use.
unrun_mutant() {  # <hook> -> path to the mutant
  local hook="$1"
  local tree="$SANDBOX/unrun/$hook"
  mkdir -p "$tree/hooks" "$tree/scripts/lib"
  cp "$REPO/payload/scripts/lib"/*.sh "$tree/scripts/lib/" 2>/dev/null || true
  # EVERY sibling comes along, not just the hook under mutation: patrol-revive asks
  # session-poker.sh for the interval and the stop family hands off to session-sweeper.sh,
  # each resolved as `$(dirname "$0")/<name>.sh`. A lone copy loses those and goes silent
  # for a reason that has nothing to do with the predicate.
  cp "$HOOKS"/*.sh "$tree/hooks/" 2>/dev/null || true
  # append the shim after the LAST library source line
  awk -v shim='active_run() { printf "%s\\n" "$BIONIC_FAKE_PLAN"; return 0; }' '
    { lines[NR] = $0; if ($0 ~ /^\. "\$BIONIC_LIB\//) last = NR }
    END { for (i = 1; i <= NR; i++) { print lines[i]; if (i == last) print shim } }
  ' "$HOOKS/$hook.sh" > "$tree/hooks/$hook.sh"
  printf '%s' "$tree/hooks/$hook.sh"
}

for hook in $RUN_SCOPED; do
  # (a) no .bionic anywhere -> exit 0, nothing on either stream
  r_none=$(mk_root "$hook-none" none)
  drive "$hook" "$(payload_for "$hook" "$r_none")"
  expect_eq "$hook: no .bionic -> exit 0" "0" "$DRV_ST"
  expect_empty "$hook: no .bionic -> no stdout" "$DRV_OUT"
  expect_empty "$hook: no .bionic -> no stderr" "$DRV_ERR"

  # (b) a root whose run is CLOSED -> exit 0, nothing on either stream
  r_closed=$(mk_root "$hook-closed" closed)
  seed_hook "$hook" "$r_closed"
  drive "$hook" "$(payload_for "$hook" "$r_closed")"
  expect_eq "$hook: closed run -> exit 0" "0" "$DRV_ST"
  expect_empty "$hook: closed run -> no stdout" "$DRV_OUT"
  expect_empty "$hook: closed run -> no stderr" "$DRV_ERR"

  # (c) ANTI-VACUITY: the SAME payload and the SAME closed-run fixture, against a copy of
  # the hook whose run predicate has been neutralised. It must behave differently — refuse,
  # speak, or write state. If it too is silent, the payload never reached the gate and the
  # two assertions above prove nothing about the predicate.
  r_ctrl=$(mk_root "$hook-ctrl" closed)
  seed_hook "$hook" "$r_ctrl"
  mut=$(unrun_mutant "$hook")
  MUT_OUT=$(printf '%s' "$(payload_for "$hook" "$r_ctrl")" | env HOME="$SANDBOX/home" \
      BIONIC_PLUGINS_DIR="$SANDBOX/plugins" CLAUDE_CODE_SESSION_ID="$SID" \
      BIONIC_FAKE_PLAN="$r_ctrl/.bionic/docs/plans/epic-99/wave-01.plan.md" \
      bash "$mut" 2>"$SANDBOX/.merr")
  MUT_ST=$?
  MUT_ERR=$(cat "$SANDBOX/.merr")
  wrote=""
  [ -n "$(ls -A "$r_ctrl/.bionic/tmp" 2>/dev/null | grep -v "^patrol-\|^roster-" || true)" ] && wrote="state"
  # a roster the seed planted is not a write; a CHANGE to it is
  grep -q 'status=identified\|status=confirmed\|landing-swept' "$r_ctrl/.bionic/tmp/roster-$SID.state" 2>/dev/null && wrote="roster"
  if [ "$MUT_ST" -ne 0 ] || [ -n "$MUT_OUT" ] || [ -n "$MUT_ERR" ] || [ -n "$wrote" ]; then
    ok "$hook: with the run predicate neutralised the SAME payload is not silent (control)"
  else
    no "$hook: with the run predicate neutralised the SAME payload is not silent (control)" \
       "exit $MUT_ST, no output, no state — the silence assertions above prove nothing"
  fi
done

section "5c — THE ENGAGEMENT SWITCH gates every hook, uniformly (task-engaged-session)"
#
# §5 above asks whether a hook is silent when the RUN is closed. This asks the question
# that scopes every hook now: is it silent when THIS SESSION never invoked canonical-sdlc?
# It is the uniformity claim §5 used to carry for the five hooks that left its loop — each
# of them is driven in its own suite too, but a per-hook suite cannot show that the roster
# agrees, and a switch that one hook spells differently is a hook that stays armed for a
# bystander.
#
# The pairing is the same shape §5 uses: the silence is worthless without the demonstration
# that THIS payload, in THIS fixture, produces something once the marker is there.
# The roster is the seven hooks task-engaged-session T2 moved behind the switch.
# canonical-sdlc-evidence-gate, canonical-sdlc-governing-skill and farm-out-reminder are
# T3's and join this list with their own guard, in their own commit.
ENGAGEMENT_SCOPED='dispatch-preflight landing-gate execution-recorder stop-guard patrol-duties-gate patrol-revive context-spend'

for hook in $ENGAGEMENT_SCOPED; do
  # an OPEN run, every precondition seeded, and the marker deliberately removed
  r_eng=$(mk_root "$hook-eng" open)
  seed_hook "$hook" "$r_eng"
  rm -f "$r_eng/.bionic/tmp/engaged-$SID.state"
  drive "$hook" "$(payload_for "$hook" "$r_eng")"
  expect_eq "$hook: open run, NO engagement marker -> exit 0" "0" "$DRV_ST"
  expect_empty "$hook: open run, NO engagement marker -> no stdout" "$DRV_OUT"
  expect_empty "$hook: open run, NO engagement marker -> no stderr" "$DRV_ERR"

  # ANTI-VACUITY: the same payload, the same fixture, the marker restored.
  : > "$r_eng/.bionic/tmp/engaged-$SID.state"
  drive "$hook" "$(payload_for "$hook" "$r_eng")"
  wrote=""
  [ -n "$(ls -A "$r_eng/.bionic/tmp" 2>/dev/null | /usr/bin/grep -v "^patrol-\|^roster-\|^engaged-" || true)" ] && wrote="state"
  /usr/bin/grep -q 'status=identified\|status=confirmed\|landing-swept' "$r_eng/.bionic/tmp/roster-$SID.state" 2>/dev/null && wrote="roster"
  if [ "$DRV_ST" -ne 0 ] || [ -n "$DRV_OUT" ] || [ -n "$DRV_ERR" ] || [ -n "$wrote" ]; then
    ok "$hook: with the marker restored the SAME payload is not silent (control)"
  else
    no "$hook: with the marker restored the SAME payload is not silent (control)" \
       "exit $DRV_ST, no output, no state — the silence assertions above prove nothing"
  fi

  # a SYMLINK at the marker path reads as ABSENT, never followed — the one shape a repo
  # controls that must not be able to OPEN a wall.
  rm -f "$r_eng/.bionic/tmp/engaged-$SID.state"
  ln -s "$SANDBOX/eng-decoy" "$r_eng/.bionic/tmp/engaged-$SID.state"
  printf 'plan=none\n' > "$SANDBOX/eng-decoy"
  drive "$hook" "$(payload_for "$hook" "$r_eng")"
  expect_eq "$hook: a SYMLINK at the marker path is not an engagement" "0" "$DRV_ST"
  expect_empty "$hook: …and it says nothing" "$DRV_ERR"
done

section "5b — the artifact wall is armed by the PROJECT, not by the run (ADOPT/5)"
#
# canonical-sdlc-governing-skill gates the frontmatter contract on a canonical-sdlc
# artifact. The artifact it exists for is the one that CREATES a run, so `active_run` is
# false exactly when the contract most needs to bind — 46 assertions in its own suite go
# red under the bare predicate, every one of them a project's first artifact. It is armed
# by the project instead: an open run, or a `.bionic/` tree at the root, or a target path
# inside one, or CONTENT that declares `canonical_sdlc_version`.
#
# THE TWO ROWS BELOW ARE THE WHOLE OF THE ALWAYS-ON CLAIM. A plan written into a bionic
# project is gated even with no run; the same write in a project that has nothing to do
# with this lifecycle, claiming nothing, is not this gate's business.
GS_UNRELATED="$SANDBOX/roots/gs-unrelated"
mkdir -p "$GS_UNRELATED/docs/plans" "$GS_UNRELATED/.bionic/tmp"
# ENGAGED, and that is what makes these two rows a discrimination rather than a pair of
# silences. The clause under test is the CONTENT clause — a file that calls itself a
# canonical-sdlc artifact is one wherever it lands — and it can only be reached in a
# session bionic was triggered in. "Unrelated" here means the artifact is unrelated, not
# the project.
: > "$GS_UNRELATED/.bionic/tmp/engaged-$SID.state"
drive canonical-sdlc-governing-skill "$(jq -n --arg s "$SID" --arg c "$GS_UNRELATED" \
  --arg p "$GS_UNRELATED/docs/plans/deploy.plan.md" \
  '{session_id:$s,cwd:$c,hook_event_name:"PreToolUse",tool_name:"Write",
    tool_input:{file_path:$p,content:"# deploy steps\n"}}')"
expect_eq "a .plan.md claiming nothing, in a project with no .bionic -> exit 0" "0" "$DRV_ST"
expect_empty "…and nothing on stdout" "$DRV_OUT"
expect_empty "…and nothing on stderr" "$DRV_ERR"

drive canonical-sdlc-governing-skill "$(jq -n --arg s "$SID" --arg c "$GS_UNRELATED" \
  --arg p "$GS_UNRELATED/docs/plans/deploy.plan.md" \
  '{session_id:$s,cwd:$c,hook_event_name:"PreToolUse",tool_name:"Write",
    tool_input:{file_path:$p,content:"---\ncanonical_sdlc_version: 14\n---\n\n# deploy\n"}}')"
expect_eq "…but the same write DECLARING canonical_sdlc_version is refused as misplaced" "2" "$DRV_ST"

# The first-artifact clause, in a project whose `.bionic` does not exist yet — except for
# the one directory engagement itself created, which is exactly the state a real first
# artifact is written in.
GS_FIRST=$(mk_root gs-first none)
mkdir -p "$GS_FIRST/.bionic/tmp"
: > "$GS_FIRST/.bionic/tmp/engaged-$SID.state"
drive canonical-sdlc-governing-skill "$(jq -n --arg s "$SID" --arg c "$GS_FIRST" \
  --arg p "$GS_FIRST/.bionic/docs/plans/epic-01/wave-01.plan.md" \
  '{session_id:$s,cwd:$c,hook_event_name:"PreToolUse",tool_name:"Write",
    tool_input:{file_path:$p,content:"# a plan with no frontmatter at all\n"}}')"
expect_eq "a project's FIRST artifact, written into .bionic before any run exists, is gated" \
  "2" "$DRV_ST"

section "6 — a missing library: refused by cost, never by uniformity"
#
# The lockout this wave is named for (R-1 §5): a wall that refused everything had no
# way to permit the very commands that would repair it, so a broken publish locked
# the user out of `claude plugin update`. The four permitted commands are matched as
# WHOLE STRINGS, checked before the wall touches a library.

# A plugin tree with hooks/ but no scripts/lib anywhere, and an empty registry:
# every loader candidate class fails.
# THE PATH IN THE MESSAGE IS THE PHYSICAL ONE. `loader_fail_closed` computes its root with
# `cd … && pwd -P`, so on a machine whose temp directory sits under a symlinked prefix
# (macOS: /var/folders -> /private/var/folders) the four permitted commands are spelled with
# the resolved path — and a fixture comparing against the unresolved one would fail while
# the wall was behaving correctly.
BROKEN="$SANDBOX/broken-plugin"
mkdir -p "$BROKEN/hooks" "$SANDBOX/plugins-empty"
BROKEN_REAL="$(cd "$BROKEN" && pwd -P)"
for h in protect-main canonical-sdlc-evidence-gate landing-gate; do
  cp "$HOOKS/$h.sh" "$BROKEN/hooks/$h.sh"
done

drive_broken() {  # <hook> <payload>
  DRV_OUT=$(printf '%s' "$2" | env HOME="$SANDBOX/home" \
      BIONIC_PLUGINS_DIR="$SANDBOX/plugins-empty" CLAUDE_CODE_SESSION_ID="$SID" \
      bash "$BROKEN/hooks/$1.sh" 2>"$SANDBOX/.err")
  DRV_ST=$?
  DRV_ERR=$(cat "$SANDBOX/.err")
  return 0
}
bash_payload_at() {  # <command> <cwd>
  jq -n --arg s "$SID" --arg c "$2" --arg m "$1" \
    '{session_id:$s,cwd:$c,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$m}}'
}

# THE CLOSED CLASS IS TWO WALLS WITH DIFFERENT REACH, and each is driven where it is
# armed. hooks/protect-main.sh guards a push in EVERY project on the machine, wave or
# no wave, so its closed arm is driven from a cwd with no `.bionic` at all — exactly
# where it must still refuse. hooks/canonical-sdlc-evidence-gate.sh is RUN-SCOPED: it
# has nothing to say outside a run, and a library it cannot load does not give it
# something to say. Its closed arm is therefore driven from a cwd where a run COULD
# exist — a real `.bionic` above it. §6b drives the other side of that line, which is
# the case this wave got wrong.
GATEPROJ="$SANDBOX/gate-with-bionic"
mkdir -p "$GATEPROJ/.bionic"
closed_cwd() {  # <hook> -> the cwd at which that wall's closed arm is armed
  case "$1" in
    canonical-sdlc-evidence-gate) printf '%s\n' "$GATEPROJ" ;;
    *) printf '%s\n' "$SANDBOX" ;;
  esac
}

# CLOSED CLASS, refusing: a push the wall can no longer read.
for h in protect-main canonical-sdlc-evidence-gate; do
  CCWD="$(closed_cwd "$h")"
  drive_broken "$h" "$(bash_payload_at 'git push origin main' "$CCWD")"
  expect_eq "$h with no library refuses a push (exit 2)" "2" "$DRV_ST"
  expect_contains "…naming the repair verb" "claude plugin update bionic@bionic" "$DRV_ERR"
  expect_contains "…and the install verb" "claude plugin install bionic@bionic" "$DRV_ERR"
  expect_contains "…and doctor" "bash $BROKEN_REAL/scripts/doctor.sh" "$DRV_ERR"
  expect_contains "…and setup" "bash $BROKEN_REAL/scripts/setup.sh" "$DRV_ERR"

  # CLOSED CLASS, permitting: the repair itself, whole-string matched.
  drive_broken "$h" "$(bash_payload_at "bash $BROKEN_REAL/scripts/doctor.sh" "$CCWD")"
  expect_eq "$h with no library PERMITS the doctor repair (exit 0)" "0" "$DRV_ST"
  expect_empty "…silently" "$DRV_ERR"

  # …and only as a whole string: a repair with a push chained after it is a push.
  drive_broken "$h" "$(bash_payload_at "bash $BROKEN_REAL/scripts/doctor.sh; git push origin main" "$CCWD")"
  expect_eq "$h refuses the repair with a command chained after it" "2" "$DRV_ST"
done

# OPEN CLASS: one line on stderr, exit 0, nothing on stdout.
drive_broken landing-gate "$(jq -n --arg s "$SID" --arg c "$SANDBOX" --arg t "$TICK_TR" \
  '{session_id:$s,cwd:$c,transcript_path:$t,hook_event_name:"Stop",stop_hook_active:false,background_tasks:[]}')"
expect_eq "landing-gate with no library steps aside (exit 0)" "0" "$DRV_ST"
expect_empty "…writing nothing to stdout" "$DRV_OUT"
expect_eq "…and exactly one line on stderr" "1" "$(printf '%s\n' "$DRV_ERR" | grep -c .)"
expect_contains "…naming what it could not find" "library" "$DRV_ERR"
expect_contains "…and where to go next" "/bionic:doctor" "$DRV_ERR"

section "6b — a closed wall's REACH: a gate with nothing to say says nothing"
#
# THE BUG THIS PINS (Step-6 critic, finding 1, 2026-09-03). The evidence gate became
# always-on this wave (AC-7) and is fail-CLOSED (AC-16). The two properties met at a
# line the design did not anticipate: `loader_fail_closed` is called at LOAD time, and
# `active_run` — the question "is this a bionic project at all?" — is answered by the
# library that just failed to load, hundreds of lines later. So one half-updated plugin
# refused `ls`, `npm test` and `git commit` in EVERY project on the machine, including
# projects carrying no `.bionic` and no run. §6 above pinned only `git push origin
# main`, which the armed gate refuses anyway, so the fixture agreed with the bug in
# both directions.
#
# THE RULE. Before it refuses, the gate reads the one on-disk fact that needs no
# library: could a run exist HERE? A run lives in a `.bionic` directory at or above the
# payload cwd. None → exit 0, silently, saying nothing about a project it would never
# have gated. One → the wall closes exactly as §6 drives it, repair allowlist and all.
# Rules 3 and 4 of lib/root.sh carry over to the inline walk: a SYMLINKED `.bionic` is
# not one, and `$HOME` and above are never inspected.
FH="$SANDBOX/fakehome"
mkdir -p "$FH/plain/deep" "$FH/proj/.bionic" "$FH/proj/sub" "$FH/symproj" "$FH/store"
ln -s "$FH/store" "$FH/symproj/.bionic"
# A `.bionic` AT $HOME. Rule 4 says $HOME and above are never inspected, so this one is
# invisible to every walk below — and it is planted precisely so that "no .bionic
# anywhere" is proven by the RULE rather than by an empty disk.
mkdir -p "$FH/.bionic"

drive_broken_home() {  # <hook> <home> <payload>
  DRV_OUT=$(printf '%s' "$3" | env HOME="$2" \
      BIONIC_PLUGINS_DIR="$SANDBOX/plugins-empty" CLAUDE_CODE_SESSION_ID="$SID" \
      bash "$BROKEN/hooks/$1.sh" 2>"$SANDBOX/.err")
  DRV_ST=$?
  DRV_ERR=$(cat "$SANDBOX/.err")
  return 0
}

# NO `.bionic` ON THE WALK: the user loses nothing, not even `ls`. The push is in this
# list on purpose — this gate is not protect-main, and protect-main is separately
# always-on and still refuses it (the control at the end of this section).
for c in 'ls' 'npm test' 'git commit -m x' 'git push origin main'; do
  drive_broken_home canonical-sdlc-evidence-gate "$FH" "$(bash_payload_at "$c" "$FH/plain/deep")"
  expect_eq "evidence gate, no library, no .bionic: [$c] passes (exit 0)" "0" "$DRV_ST"
  expect_empty "…saying nothing on stderr — [$c]" "$DRV_ERR"
  expect_empty "…and nothing on stdout — [$c]" "$DRV_OUT"
done

# RULE 4, driven from $HOME ITSELF: the `.bionic` planted there is not a root.
drive_broken_home canonical-sdlc-evidence-gate "$FH" "$(bash_payload_at 'ls' "$FH")"
expect_eq "evidence gate, no library, a .bionic AT \$HOME: [ls] passes (exit 0)" "0" "$DRV_ST"
expect_empty "…silently" "$DRV_ERR"

# RULE 3: a `.bionic` SYMLINK is not a `.bionic` directory (user, 2026-09-02:
# "symlinks to .bionic have been problematic"), so it does not arm the wall either.
drive_broken_home canonical-sdlc-evidence-gate "$FH" "$(bash_payload_at 'ls' "$FH/symproj")"
expect_eq "evidence gate, no library, SYMLINKED .bionic: [ls] passes (exit 0)" "0" "$DRV_ST"
expect_empty "…silently" "$DRV_ERR"

# THE ANTI-VACUITY CONTROL. A hook that exited 0 at line 1 would pass everything above.
# A real `.bionic` ABOVE the cwd arms the wall, and then even `ls` is refused — the
# unchanged fail-closed behaviour, named repair commands and all.
drive_broken_home canonical-sdlc-evidence-gate "$FH" "$(bash_payload_at 'ls' "$FH/proj/sub")"
expect_eq "evidence gate, no library, real .bionic above the cwd: [ls] REFUSED (exit 2)" "2" "$DRV_ST"
expect_contains "…naming the repair verb" "claude plugin update bionic@bionic" "$DRV_ERR"
expect_contains "…and doctor" "bash $BROKEN_REAL/scripts/doctor.sh" "$DRV_ERR"
# …and the repair allowlist still fires from inside such a project.
drive_broken_home canonical-sdlc-evidence-gate "$FH" \
  "$(bash_payload_at "bash $BROKEN_REAL/scripts/doctor.sh" "$FH/proj/sub")"
expect_eq "…and the doctor repair is still PERMITTED there (exit 0)" "0" "$DRV_ST"
expect_empty "…silently" "$DRV_ERR"

# THE DIFFERENTIAL CONTROL: protect-main's reach is deliberately every-project, so the
# same cwd that makes the gate silent leaves protect-main refusing. If this row ever
# goes green-by-exit-0 the walk was copied into the wrong wall.
drive_broken_home protect-main "$FH" "$(bash_payload_at 'git push origin main' "$FH/plain/deep")"
expect_eq "protect-main keeps its every-project reach: push refused with no .bionic (exit 2)" "2" "$DRV_ST"
drive_broken_home protect-main "$FH" "$(bash_payload_at 'ls' "$FH/plain/deep")"
expect_eq "…and refuses [ls] there too — it cannot read the command it must classify" "2" "$DRV_ST"

# ---------------------------------------------------------------------------
# §EXEC — every command hooks.json registers is EXECUTABLE (T3 re-drive finding 3,
# 2026-09-03). The CLI runs a registered command as a bare path with no interpreter
# prefix, so a hook whose exec bit is lost is not a hook that degrades — it is
# `Permission denied` on every event it is registered for, and the wall it was is
# silently gone. FIX-GATE's rewrite of patrol-duties-gate.sh dropped the bit
# (100755 → 100644 at 24d0ddd) and nothing here noticed until a live drive did.
section "§EXEC — every hooks.json command file carries the exec bit"
EXEC_MISSING=""
EXEC_N=0
while IFS= read -r cmdpath; do
  [ -n "$cmdpath" ] || continue
  EXEC_N=$((EXEC_N + 1))
  f="$HOOKS/$(basename "$cmdpath")"
  [ -x "$f" ] || EXEC_MISSING="$EXEC_MISSING $(basename "$cmdpath")"
done <<EOF_CMDS
$(grep -o '"command": *"[^"]*"' "$REPO/hooks/hooks.json" | sed 's/.*"command": *"//; s/"$//' | awk '{print $NF}' | sort -u)
EOF_CMDS
expect_eq "hooks.json registers a non-empty command set" "1" "$([ "$EXEC_N" -gt 0 ] && echo 1 || echo 0)"
expect_empty "every registered command file is executable (missing:$EXEC_MISSING)" "$EXEC_MISSING"

finish
