#!/bin/bash
# Tests for hooks/background-suite-guard.sh — THE BUDGET ARM
# (wave-01 verification-cannot-lie, S13; spec AC-21; seed suite-allowance-wall.md item 3.)
#
# THE INCIDENT. Two dispatched writers finished their own work green at ~45 minutes and
# then spent 40 more re-running the whole tree, one suite at a time, in parallel, on an
# 8 GB machine at load 10. Their briefs said "run impacted suites only; never
# tests/run.sh; run X, Y, Z as consumers", and "consumers" was read as "everything". The
# Patrol notified both as overdue and they were killed by hand. Prose in a brief is a
# wish. This file tests the wall.
#
# WHAT IT COVERS. `hooks/dispatch-preflight.sh` records the budget on the roster row at
# launch — `suites_allowed=`, derived from the tree by the configured impact command or
# declared by the brief (tests/dispatch-preflight.test.sh §S27 owns that half). This file
# owns the other half: inside a dispatched agent, a suite invocation outside that set is
# refused, `tests/run.sh` is refused unless the row carries it, and `FARM_OUT_ALLOW=1`
# does not widen either.
#
# THE B-9 ARM IS NOT RE-TESTED HERE. The backgrounded-suite refusal this hook has carried
# since bionic 1.3.2 belongs to tests/cmd-class.test.sh §C4, which drives it through
# hooks/agent-context-guard.sh exactly as hooks.json registers it. What IS asserted here
# is the one interaction between them: which arm speaks when both apply.
#
# HERMETIC. Every payload is crafted and piped into the hook; repos are throwaway git
# inits under a mktemp'd sandbox, and HOME / CLAUDE_CONFIG_DIR / BIONIC_PLUGINS_DIR are
# all pointed inside it so the loader cannot reach this machine's installed plugin.
#
# FIXTURE FIDELITY (declared, per .claude memory fixtures-can-pin-away-the-test):
#   * PreToolUse|Bash payload envelope — the shape tests/cmd-class.test.sh pins, plus the
#     top-level `agent_id` measured for an agent context in
#     record/session-20260815-landing-supervision/t1-probe-report.md §3 (CLI 2.1.233).
#   * agent id VALUE — the transcript form measured there (`a<name>-<16 hex>`). The hook
#     never parses it; it compares it to the row.
#   * ROSTER ROWS — built through tests/lib/roster-row.sh, which delegates to the one
#     production writer (payload/scripts/lib/roster.sh). No row here is hand-typed, so a
#     field this suite believes in that the writer stopped emitting fails loudly.
#   * session ids, plan text — SYNTHESIZED.
#
# Usage: bash tests/background-suite-guard.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/roster-row.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PAYLOAD_HOOKS="$REPO_ROOT/payload/hooks"
GUARD="$PAYLOAD_HOOKS/background-suite-guard.sh"
CTX_GUARD="$PAYLOAD_HOOKS/agent-context-guard.sh"

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/bg-suite-guard-test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

SID="4e2b9a17-55c8-4d0e-9b31-7f6a2c4e18d9"
ACTOR="as13writer-4c9f1e07ab32d650"
OTHER="as13other-1122334455667788"

FAKE_HOME="$SANDBOX/home"
mkdir -p "$FAKE_HOME/.claude/projects/-sandbox"
: > "$FAKE_HOME/.claude/projects/-sandbox/$SID.jsonl"

# ---------- fixtures ----------

# mk_repo <name> — an ENGAGED, ARMED repo with an empty roster (header only).
mk_repo() {
  local repo="$SANDBOX/$1/repo"
  mkdir -p "$repo/.bionic/tmp"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name "T"
  echo seed > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm seed 2>/dev/null
  : > "$repo/.bionic/tmp/engaged-$SID.state"
  roster_header > "$repo/.bionic/tmp/roster-$SID.state"
  chmod 600 "$repo/.bionic/tmp/roster-$SID.state"
  printf '%s' "$repo"
}

# add_row <repo> <key=value>... — one more row on that repo's roster, through the writer.
add_row() {
  local repo="$1"; shift
  roster_row_fixture "session=$SID" "$@" >> "$repo/.bionic/tmp/roster-$SID.state"
}

mk_payload() {  # <cwd> <command> [agent_id] [run_in_background:true|false|omit]
  local bg="${4:-omit}"
  jq -n --arg s "$SID" --arg c "$1" --arg cmd "$2" --arg a "${3:-}" --arg bg "$bg" \
    '{session_id:$s, transcript_path:"/irrelevant.jsonl", cwd:$c,
      permission_mode:"bypassPermissions",
      hook_event_name:"PreToolUse", tool_name:"Bash",
      tool_input:({command:$cmd}
                  + (if $bg == "omit" then {} else {run_in_background: ($bg == "true")} end)),
      tool_use_id:"toolu_01s13budget"}
     + (if $a == "" then {} else {agent_id:$a} end)'
}

OUT=""; ERR=""; ST=0
EXTRA_ENV=""
run_hook() {  # <payload> <hook> [args...]
  local payload="$1"; shift
  local _sid; _sid=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || _sid=""
  # shellcheck disable=SC2086  # EXTRA_ENV is this file's own space-free assignments
  OUT=$(printf '%s' "$payload" | env HOME="$FAKE_HOME" CLAUDE_CONFIG_DIR="$FAKE_HOME/.claude" \
          BIONIC_PLUGINS_DIR="$SANDBOX/no-plugins" CLAUDE_CODE_SESSION_ID="$_sid" \
          CLAUDE_PROJECT_DIR= $EXTRA_ENV bash "$@" 2>"$SANDBOX/.err")
  ST=$?
  ERR=$(cat "$SANDBOX/.err")
  return 0
}

# THROUGH THE GUARD, as hooks/hooks.json registers the pair. Every cell below is driven
# this way unless it is specifically about the guard being absent: what ships is the pair,
# and a wall proved only when driven straight is a wall nobody proved.
VERR=""
guarded() {  # <repo> <command> [agent_id] [bg]
  # TWO DRIVES OF THE SAME CALL, and the pair is what slice 13's ruling D-1 made
  # necessary. The user stream is ONE line now — `bionic: <verb> refused — <fact>
  # (<fix>)` — and everything this suite used to read off it (the suite asked for, the
  # recorded set, the word BUDGET, the standing ruling) is `detail`, which reaches a
  # reader only under BIONIC_WALL_VERBOSE=1. So `$ERR` is asserted for the LINE and
  # `$VERR` for the detail; asserting the detail on `$ERR` would now be asserting that
  # the wall leaks it.
  run_hook "$(mk_payload "$1" "$2" "${3-$ACTOR}" "${4:-omit}")" "$CTX_GUARD" "$GUARD"
  local _st="$ST" _out="$OUT" _err="$ERR" _saved="$EXTRA_ENV"
  EXTRA_ENV="$EXTRA_ENV BIONIC_WALL_VERBOSE=1"
  run_hook "$(mk_payload "$1" "$2" "${3-$ACTOR}" "${4:-omit}")" "$CTX_GUARD" "$GUARD"
  VERR="$ERR"
  EXTRA_ENV="$_saved"; ST="$_st"; OUT="$_out"; ERR="$_err"
}

section "B0 — the hook exists and parses"
if [ -f "$GUARD" ]; then ok "hooks/background-suite-guard.sh is on disk"; else
  no "hooks/background-suite-guard.sh is on disk" "$GUARD"
fi
if bash -n "$GUARD" 2>"$SANDBOX/.syn"; then ok "it parses (bash -n)"; else
  no "it parses (bash -n)" "$(cat "$SANDBOX/.syn")"
fi

section "B1 — a stated budget: on it passes, off it refuses"
R1=$(mk_repo b1)
add_row "$R1" name=w-b1 "agent_id=$ACTOR" "suites_allowed=alpha.test.sh beta.test.sh" \
  suites_source=derived files=payload/scripts/lib/widget.sh

guarded "$R1" 'bash tests/alpha.test.sh'
expect_eq "B1a a suite ON the budget is allowed" "0" "$ST"
expect_empty "B1a …silently" "$OUT$ERR"

guarded "$R1" 'bash tests/beta.test.sh 2>&1 | tee /tmp/b.log'
expect_eq "B1b …and so is the other one, tee'd as a real brief would run it" "0" "$ST"
expect_empty "B1b …silently" "$OUT$ERR"

guarded "$R1" 'bash tests/gamma.test.sh'
expect_eq "B1c a suite OFF the budget is REFUSED" "2" "$ST"
expect_contains "B1c …naming the suite that was asked for" "gamma.test.sh" "$VERR"
expect_contains "B1c …naming the set that was recorded" "alpha.test.sh beta.test.sh" "$VERR"
# ADR-002: this arm is an instrument budget, not a safety wall, and the refusal says the
# word — an agent that reads it must be able to tell "you may not" from "this costs".
expect_contains "B1c …and calling itself a BUDGET, not a wall" "BUDGET" "$VERR"
expect_empty "B1c …with nothing on stdout" "$OUT"

# EVERY spelling the classifier recognises reaches this arm, or the budget is bypassable by
# typing the same command differently — the superset rule read from the budget side.
for sp in 'sudo bash tests/gamma.test.sh' '( bash tests/gamma.test.sh )' \
          './tests/gamma.test.sh' 'tests/gamma.test.sh' \
          'cd /tmp && bash tests/gamma.test.sh' 'PIN=/tmp/p bash tests/gamma.test.sh'; do
  guarded "$R1" "$sp"
  expect_eq "B1d off-budget through [$sp] is REFUSED" "2" "$ST"
done

# A CHAIN IS REFUSED FOR ITS OFF-BUDGET MEMBER, even when the first member is allowed —
# the arm reads every suite the command names, not the first one.
guarded "$R1" 'bash tests/alpha.test.sh && bash tests/gamma.test.sh'
expect_eq "B1e a chain carrying one off-budget suite is REFUSED" "2" "$ST"
expect_contains "B1e …naming the member that was off it" "gamma.test.sh" "$VERR"

# NEGATIVE CONTROL: prose naming an off-budget suite is not an invocation.
guarded "$R1" 'echo "next up: bash tests/gamma.test.sh"'
expect_eq "B1f prose naming an off-budget suite is allowed" "0" "$ST"
expect_empty "B1f …silently" "$OUT$ERR"

guarded "$R1" 'git status --short'
expect_eq "B1g a non-suite command is allowed" "0" "$ST"
expect_empty "B1g …silently" "$OUT$ERR"

# SUITE-CLASS AND FILELESS. `pytest` runs a suite and names no file this row can speak
# about; inventing a refusal for it would be the wall guessing.
guarded "$R1" 'pytest'
expect_eq "B1h a suite-class command naming no suite FILE is allowed" "0" "$ST"
expect_empty "B1h …silently" "$OUT$ERR"

section "B2 — tests/run.sh is refused unless the row carries it"
guarded "$R1" 'bash tests/run.sh'
expect_eq "B2a the full tree is REFUSED against a narrow budget" "2" "$ST"
expect_contains "B2a …naming the full tree" "tests/run.sh" "$VERR"
expect_contains "B2a …calling itself a BUDGET" "BUDGET" "$VERR"
expect_contains "B2a …and naming the standing ruling it makes mechanical" "One regression means one" "$VERR"

R2=$(mk_repo b2)
add_row "$R2" name=w-b2 "agent_id=$ACTOR" suites_allowed=run.sh suites_source=declared files=
guarded "$R2" 'bash tests/run.sh'
expect_eq "B2b the Step-5 runner, whose row carries run.sh, is allowed" "0" "$ST"
expect_empty "B2b …silently" "$OUT$ERR"
# …and that row is not a licence for everything else.
guarded "$R2" 'bash tests/alpha.test.sh'
expect_eq "B2c …but its row does not license a suite it does not name" "2" "$ST"

section "B3 — FARM_OUT_ALLOW does not widen a budget (AC-21)"
# The override exists so the ORCHESTRATOR can run something on its own thread when
# dispatching it genuinely will not work — it is farm-out-reminder.sh's escape from
# farm-out-reminder.sh's wall. A writer that could set an environment variable on itself
# to widen its own instrument would have a budget in name only.
guarded "$R1" 'FARM_OUT_ALLOW=1 bash tests/run.sh'
expect_eq "B3a the override as a command prefix does not open the full tree" "2" "$ST"
guarded "$R1" 'cd /tmp && FARM_OUT_ALLOW=1 bash tests/gamma.test.sh'
expect_eq "B3b …nor mid-chain, for an off-budget suite" "2" "$ST"
EXTRA_ENV="FARM_OUT_ALLOW=1"
guarded "$R1" 'bash tests/run.sh'
expect_eq "B3c …nor set in the agent's own environment" "2" "$ST"
guarded "$R1" 'bash tests/gamma.test.sh'
expect_eq "B3d …for either arm" "2" "$ST"
# NON-VACUITY: with the override set, an ON-budget suite still passes — so B3c/B3d are the
# budget refusing, not the override breaking the hook.
guarded "$R1" 'bash tests/alpha.test.sh'
expect_eq "B3e non-vacuity: an on-budget suite still passes with the override set" "0" "$ST"
EXTRA_ENV=""

section "B4 — the three states of suites_allowed"
# `none` is a DECLARED empty set (the `Suites: none` waiver); an empty value is a budget
# that was stated and came out empty; an absent key is a row written before the wall. They
# are three different facts and the arm answers each differently.

R4A=$(mk_repo b4a)
add_row "$R4A" name=w-b4a "agent_id=$ACTOR" suites_allowed=none suites_source=declared files=
guarded "$R4A" 'bash tests/alpha.test.sh'
expect_eq "B4a a Suites: none row refuses every named suite" "2" "$ST"
expect_contains "B4a …saying the brief declared none" "Suites: none" "$VERR"
guarded "$R4A" 'bash tests/run.sh'
expect_eq "B4a …and the full tree with it" "2" "$ST"

R4B=$(mk_repo b4b)
add_row "$R4B" name=w-b4b "agent_id=$ACTOR" suites_allowed= suites_source=derived files=x/y.sh
guarded "$R4B" 'bash tests/alpha.test.sh'
expect_eq "B4b an EMPTY budget stands aside for a named suite" "0" "$ST"
expect_empty "B4b …silently" "$OUT$ERR"
guarded "$R4B" 'bash tests/run.sh'
expect_eq "B4b …but never for the full tree" "2" "$ST"

R4C=$(mk_repo b4c)
add_row "$R4C" name=w-b4c "agent_id=$ACTOR"          # a pre-wall row: no key at all
guarded "$R4C" 'bash tests/alpha.test.sh'
expect_eq "B4c a row from before the wall stands aside for a named suite" "0" "$ST"
expect_empty "B4c …silently" "$OUT$ERR"
guarded "$R4C" 'bash tests/run.sh'
expect_eq "B4c …but the full tree is still refused" "2" "$ST"
expect_contains "B4c …saying no set was recorded" "no set was recorded" "$VERR"
# NON-VACUITY: the row really is on the roster and really carries this agent's id, so B4c
# is the ABSENT KEY being read and not a row the hook failed to find.
expect_contains "B4c non-vacuity: the row is on the roster under this agent's id" \
  "agent_id=$ACTOR" "$(cat "$R4C/.bionic/tmp/roster-$SID.state")"
expect_absent "B4c …and it carries no suites_allowed key" \
  "suites_allowed=" "$(cat "$R4C/.bionic/tmp/roster-$SID.state")"

R4D=$(mk_repo b4d)                                   # no row for this agent at all
add_row "$R4D" name=someone-else "agent_id=$OTHER" suites_allowed=alpha.test.sh suites_source=declared files=
guarded "$R4D" 'bash tests/alpha.test.sh'
expect_eq "B4d no row for this agent stands aside for a named suite" "0" "$ST"
guarded "$R4D" 'bash tests/run.sh'
expect_eq "B4d …and still refuses the full tree" "2" "$ST"
# NON-VACUITY: another agent's row IS on this roster and is not read as ours.
guarded "$R4D" 'bash tests/gamma.test.sh'
expect_eq "B4d another agent's narrow budget does not bind this one" "0" "$ST"

section "B5 — the LAST row carrying this id wins"
# One dispatch becomes several rows: the launch row, hooks/execution-recorder.sh's
# `status=confirmed` copy, and — across a /clear — hooks/session-poker.sh's adopted row.
# Each carries the budget forward, and the newest is the current statement about the agent.
R5=$(mk_repo b5)
add_row "$R5" name=w-b5 "agent_id=$ACTOR" status=intended suites_allowed=alpha.test.sh \
  suites_source=declared files=
add_row "$R5" name=w-b5 "agent_id=$ACTOR" status=confirmed suites_allowed="alpha.test.sh delta.test.sh" \
  suites_source=declared files=
guarded "$R5" 'bash tests/delta.test.sh'
expect_eq "B5a a suite the LATER row allows is allowed" "0" "$ST"
guarded "$R5" 'bash tests/epsilon.test.sh'
expect_eq "B5b …and one neither row allows is still refused" "2" "$ST"
expect_contains "B5b …against the later row's set" "alpha.test.sh delta.test.sh" "$VERR"

section "B6 — scope: the arm is the AGENT's, and the session must be engaged"
# A main-thread payload has no top-level agent_id (t1-probe-report.md §3). The
# orchestrator's own thread is hooks/farm-out-reminder.sh's, which answers the same
# question differently, so this arm never speaks there.
run_hook "$(mk_payload "$R1" 'bash tests/gamma.test.sh' "")" "$CTX_GUARD" "$GUARD"
expect_eq "B6a a MAIN-THREAD payload leaves the budget arm silent" "0" "$ST"
expect_empty "B6a …silently" "$OUT$ERR"
# POSITIVE CONTROL: the same command, same repo, from an agent context, refuses — so B6a
# is the partition and not a dud fixture.
guarded "$R1" 'bash tests/gamma.test.sh'
expect_eq "B6a control: the same command from an agent context REFUSES" "2" "$ST"

# DRIVEN STRAIGHT, with no agent_id: the wall owns its own scope and does not depend on
# the guard in front remembering to check.
run_hook "$(mk_payload "$R1" 'bash tests/gamma.test.sh' "")" "$GUARD"
expect_eq "B6b …and driven straight into the wall, still silent" "0" "$ST"
expect_empty "B6b …silently" "$OUT$ERR"

# UNENGAGED: bionic's walls bind only a session that invoked canonical-sdlc.
rm -f "$R1/.bionic/tmp/engaged-$SID.state"
guarded "$R1" 'bash tests/gamma.test.sh'
expect_eq "B6c an unengaged session is silent even off-budget (through the guard)" "0" "$ST"
run_hook "$(mk_payload "$R1" 'bash tests/gamma.test.sh' "$ACTOR")" "$GUARD"
expect_eq "B6c …and driven straight into the wall" "0" "$ST"
expect_empty "B6c …silently" "$OUT$ERR"
: > "$R1/.bionic/tmp/engaged-$SID.state"
guarded "$R1" 'bash tests/gamma.test.sh'
expect_eq "B6c control: with the marker back, it REFUSES again" "2" "$ST"

# UNARMED (no roster): the guard in front never runs the wall, so nothing is refused, and
# the wall driven straight has no row to read and takes the no-statement path.
R6=$(mk_repo b6)
rm -f "$R6/.bionic/tmp/roster-$SID.state"
guarded "$R6" 'bash tests/gamma.test.sh'
expect_eq "B6d an unarmed session is silent (the guard in front never runs the wall)" "0" "$ST"

section "B7 — which arm speaks when both apply"
# A backgrounded suite is refused whether or not it is on the budget, and being on the
# budget is no answer to "nobody read the result" — so the B-9 arm speaks first.
guarded "$R1" 'bash tests/alpha.test.sh' "$ACTOR" true
expect_eq "B7a an ON-budget suite, backgrounded, is still REFUSED" "2" "$ST"
expect_contains "B7a …by the B-9 arm, whose fact is on the user line" \
  "a backgrounded suite's result is never read" "$ERR"
expect_absent "B7a …and not by the budget arm" "BUDGET" "$ERR"

guarded "$R1" 'bash tests/gamma.test.sh' "$ACTOR" true
expect_eq "B7b an OFF-budget suite, backgrounded, is refused too" "2" "$ST"
expect_contains "B7b …still by the B-9 arm, which is the wider refusal" \
  "a backgrounded suite's result is never read" "$ERR"

guarded "$R1" 'bash tests/alpha.test.sh' "$ACTOR" false
expect_eq "B7c run_in_background false is not backgrounded, and on-budget passes" "0" "$ST"
expect_empty "B7c …silently" "$OUT$ERR"

section "B8 — the arm is scoped to THIS repo, and a mode that runs nothing spends nothing"
# THE THREE FALSE REFUSALS (critic K-2, review-a A-7, the walk A-36a). The reading behind
# this arm used to answer with a bare basename, so any file on the machine ending
# `.test.sh` was judged against this row's budget, and `--dry-run` — documented as "run
# nothing" — was refused on the same terms as a forty-minute run.

guarded "$R1" 'bash tests/run.sh --dry-run'
expect_eq "B8a the runner's --dry-run mode is ALLOWED against a narrow budget" "0" "$ST"
expect_empty "B8a …silently" "$OUT$ERR"

# CONTROL: the same command without the flag is the full tree, and still refused.
guarded "$R1" 'bash tests/run.sh'
expect_eq "B8b control: without the flag the full tree is still REFUSED" "2" "$ST"

# A SUITE FILE THAT IS NOT THIS REPO'S is not this row's business either.
guarded "$R1" 'bash /tmp/scratch-probe/probe2.test.sh'
expect_eq "B8c an off-budget basename OUTSIDE the repo is allowed" "0" "$ST"
expect_empty "B8c …silently" "$OUT$ERR"
guarded "$R1" 'bash /some/other/tree/tests/run.sh'
expect_eq "B8d …and so is a full tree that is not this one" "0" "$ST"

# CONTROL: the same basename inside the repo is refused, so B8c is scoping and not silence.
guarded "$R1" 'bash tests/probe2.test.sh'
expect_eq "B8e control: the same basename INSIDE the repo is REFUSED" "2" "$ST"

# THE SPLIT IS GUARDED. `bash tests/*.test.sh` names the literal `*.test.sh`, and the loop
# that reads the targets runs with `set -f` — so the HOOK PROCESS'S OWN CWD cannot expand
# that word into whatever files happen to sit there (review-a A-7b). The cwd below holds
# `alpha.test.sh` and `beta.test.sh`, which are exactly this row's budget: without the
# guard the word expands into two allowed names and the command passes.
BSG_GLOBDIR="$SANDBOX/globcwd"
mkdir -p "$BSG_GLOBDIR"
: > "$BSG_GLOBDIR/alpha.test.sh"
: > "$BSG_GLOBDIR/beta.test.sh"
guarded_from() {  # <cwd for the hook process> <repo> <command>
  local _dir="$1" _payload
  _payload=$(mk_payload "$2" "$3" "$ACTOR" omit)
  OUT=$(cd "$_dir" && printf '%s' "$_payload" | env HOME="$FAKE_HOME" \
          CLAUDE_CONFIG_DIR="$FAKE_HOME/.claude" BIONIC_PLUGINS_DIR="$SANDBOX/no-plugins" \
          CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PROJECT_DIR= \
          bash "$CTX_GUARD" "$GUARD" 2>"$SANDBOX/.err")
  ST=$?
  ERR=$(cat "$SANDBOX/.err")
  # The same call again with the knob, for the arms that read `detail` (slice 13, D-1).
  VERR=$(cd "$_dir" && printf '%s' "$_payload" | env HOME="$FAKE_HOME" \
          CLAUDE_CONFIG_DIR="$FAKE_HOME/.claude" BIONIC_PLUGINS_DIR="$SANDBOX/no-plugins" \
          CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PROJECT_DIR= BIONIC_WALL_VERBOSE=1 \
          bash "$CTX_GUARD" "$GUARD" 2>&1 >/dev/null)
  return 0
}
guarded_from "$BSG_GLOBDIR" "$R1" 'bash tests/*.test.sh'
expect_eq "B8f a glob target is REFUSED by its literal name" "2" "$ST"
expect_contains "B8f …naming the unexpanded word, not the files beside the hook" "*.test.sh" "$VERR"

section "B9 — a suite named by a shell VARIABLE is a different refusal (C-5, A-35c)"
# THE DEFECT. A hook reads the command text BEFORE the shell expands it. A writer looping
# over four suites all of which are on its budget got
#     BLOCKED: $s.test.sh is not on this agent's suite budget.
# — a headline that is false in the case that produces it, sending the reader to check a
# set that is not the problem. Two independent readers hit it (A-35c; the walk's heading
# 10(b), a fresh agent on its first attempt). The correct behaviour is still to refuse;
# the wrong thing was the sentence.

guarded "$R1" 'for s in alpha beta; do bash "tests/$s.test.sh"; done'
expect_eq "B9a a variable-named suite is still REFUSED" "2" "$ST"
expect_contains "B9a …saying the name could not be resolved at hook time" \
  "the suite name here is a shell variable" "$ERR"
expect_contains "B9a …and telling the reader what to type instead" \
  "Spell the suite literally, one per call" "$VERR"
# THE HEADLINE THE READER ACTS ON must not claim the suite is off a budget the hook never
# managed to check it against.
expect_absent "B9a …never claiming it is off the budget" "is not on this agent's suite budget" "$ERR"

# THE BRACE FORM AND A COMMAND SUBSTITUTION ARE THE SAME STATE.
guarded "$R1" 'bash "tests/${s}.test.sh"'
expect_eq "B9b the brace spelling reads the same way" "2" "$ST"
expect_contains "B9b …with the same refusal" \
  "the suite name here is a shell variable" "$ERR"
guarded "$R1" 'bash tests/`suite_name`.test.sh'
expect_eq "B9c a command substitution reads the same way" "2" "$ST"
expect_contains "B9c …with the same refusal" \
  "the suite name here is a shell variable" "$ERR"

# CONTROL: the literal spelling the refusal asks for is allowed, so B9a is about the
# spelling and not about the suite.
guarded "$R1" 'bash tests/alpha.test.sh'
expect_eq "B9e control: the literal spelling of an on-budget suite passes" "0" "$ST"
expect_empty "B9e …silently" "$OUT$ERR"

# THE ORDINARY REFUSAL'S OWN ALIGNMENT. `You asked for : x` carried a space before the
# colon — column alignment against the line above it, and a typo to everyone who did not
# notice. Both labels now end at the colon and the values align on the padding.
guarded "$R1" 'bash tests/gamma.test.sh'
expect_eq "B9f control: an ordinary off-budget suite still refuses" "2" "$ST"
expect_contains "B9f …and its label carries no space before the colon" "You asked for:" "$VERR"
expect_absent "B9f …the stray space is gone" "You asked for :" "$ERR"

section "B10 — every site that turns a session id into a roster path carries the shape rule (A-10)"
# THE INCONSISTENCY. `session_id` (payload/scripts/lib/session.sh) prefers
# CLAUDE_CODE_SESSION_ID, falls back to the payload value, and returns whichever it got
# VERBATIM — it validates nothing. Two hooks that build a roster path apply the shape rule
# before doing so; this hook's roster READ is new in this wave and did not inherit it.
# hooks/landing-gate.sh:284 states the rationale for `agent_id`: a key carrying path
# separators does not trip the symlink guards, it reads outside what those guards protect.
#
# WHY THIS IS A SOURCE ASSERTION AND NOT A DRIVEN ONE, said plainly. The line is
# UNREACHABLE through the supported path: `engaged_session` (payload/scripts/lib/run.sh:566)
# applies the identical case to the same id ~70 lines earlier, so a malformed id exits the
# hook at the engagement switch and never reaches the path. A test that piped a malformed
# id into this hook and watched it pass would be asserting the ENGAGEMENT check while
# claiming to assert this one — a green that proves a different line than the one it names,
# which is the exact class this wave exists to close. What IS true and checkable is the
# family property A-10 names: the same rule, at every path-forming site.
B10_HOOKS="background-suite-guard.sh execution-recorder.sh agent-context-guard.sh"
B10_RULE='case .*\[!A-Za-z0-9_-\]\*\)'
for _h in $B10_HOOKS; do
  expect_regex "B10 $_h shape-checks the session id" "$B10_RULE" "$(cat "$PAYLOAD_HOOKS/$_h")"
done
# NON-VACUITY: the pattern is not one that matches any shell file. A hook with no such rule
# fails it, so the loop above is reading the rule and not the language.
expect_no_regex "B10 …and the pattern discriminates (a hook without the rule fails it)" \
  "$B10_RULE" "$(cat "$PAYLOAD_HOOKS/farm-out-reminder.sh")"
# AND THE RULE IS AT THIS HOOK'S OWN PATH-FORMING SITE, not merely somewhere in the file:
# the roster path is built on the line after it. A rule that drifted away from the line it
# protects is the state A-10 found, spelled differently.
B10_ADJACENT=$(/usr/bin/grep -A1 'case "\$BSG_SID" in' "$GUARD" | tail -1)
expect_match "B10 …on the line immediately before the roster path is formed" \
  'ROSTER_FILE=*' "$B10_ADJACENT"

section "B11 — AC-E1.3/E1.5: every refusal is one line, in the criterion's shape"
#
# fails-when: a refusal reaches the user as more than one line, or in any shape but
# `bionic: <verb> refused — <fact> (<fix ≤ 40 cols>)`. All four of this wall's refusal
# sites are tripped for real and asserted against the criterion's own regex and then
# against the exact wording the ruled table gives them (s12-refusal-wording-draft.md §1
# rows 11 through 14). The detail every arm above reads lives behind the knob, and B11e
# is the pair that proves the split rather than assuming it.

B11_RE='^bionic: [a-z-]+ refused — .+ \(.{1,40}\)$'
b11_line() {  # <label> <expected line>   (reads $ERR from the last `guarded`)
  local _n
  _n="$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')"
  if [ "$_n" = "1" ]; then ok "$1: exactly one line on the user stream"
  else no "$1: exactly one line on the user stream" "got $_n lines: [$ERR]"; fi
  if printf '%s' "$ERR" | /usr/bin/grep -qE "$B11_RE"; then ok "$1: in AC-E1.3's shape"
  else no "$1: in AC-E1.3's shape" "line=[$ERR]"; fi
  if [ "$ERR" = "$2" ]; then ok "$1: and it is the table's own wording"
  else no "$1: and it is the table's own wording" "want [$2] got [$ERR]"; fi
}

guarded "$R1" 'bash tests/alpha.test.sh' "$ACTOR" true
b11_line "B11a row 11 (backgrounded)" \
  "bionic: suite-run refused — a backgrounded suite's result is never read (run it in the foreground)"

guarded "$R1" 'for s in alpha beta; do bash "tests/$s.test.sh"; done'
b11_line "B11b row 12 (an unexpanded name)" \
  "bionic: suite-run refused — the suite name here is a shell variable (spell each suite literally)"

guarded "$R1" 'bash tests/gamma.test.sh'
b11_line "B11c row 13 (off the budget)" \
  "bionic: suite-run refused — that suite is not on this agent's budget (run only the budgeted suites)"

guarded "$R1" 'bash tests/run.sh'
b11_line "B11d row 14 (the full tree)" \
  "bionic: suite-run refused — the full tree is not on this agent's budget (run your brief's suites)"

# AC-E1.5, the pair. The same call, knob off and knob on: the budget set is the value
# the one line had no room for, and the knob is the only thing that puts it back.
guarded "$R1" 'bash tests/gamma.test.sh'
expect_absent "B11e without the knob the recorded set is NOT on the user stream" \
  "alpha.test.sh beta.test.sh" "$ERR"
expect_contains "B11e …and with BIONIC_WALL_VERBOSE=1 it is" \
  "alpha.test.sh beta.test.sh" "$VERR"
expect_eq "B11e …with the one line still first" \
  "bionic: suite-run refused — that suite is not on this agent's budget (run only the budgeted suites)" \
  "$(printf '%s\n' "$VERR" | head -1)"

finish
