#!/bin/bash
# Tests for hooks/stop-guard.sh — the STOP GATE, PreToolUse|TaskStop
# (epic-15 wave-01R; recorder arm removed at wave-03 slice 4/4).
#
# The gate: D-1 activity-boundary freshness, D-2 consume-on-stop, and — since
# wave-03 slice 4/6 — D-3 same-actor, D-6 progress staleness, and the
# foreign-stop rule. Serves wave-01R's AC-4/AC-5 and the stop-side rows of
# AC-8/AC-10, plus wave-03's AC-4 (§8), AC-5 (§9) and AC-6 (§10).
#
# WHAT MOVED OUT. This script used to carry a second arm that WROTE the records
# it now only reads. Those rows live in tests/execution-recorder.test.sh, because
# that is where the writer lives — one writer, one paired suite. The records this
# suite spends are still never hand-written: `observe()` below runs the real
# hooks/stop-check.sh and feeds its real output to the real recorder, so every
# gate row here is discharged through the whole producer→recorder→gate path.
#
# HERMETIC. Every payload is crafted and piped straight into the script under
# test; nothing here invokes the TaskStop tool, touches the live installed hooks,
# or writes outside a mktemp'd sandbox.
#
# Usage: bash tests/stop-guard.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/live-answer.sh"
. "$(dirname "$0")/lib/roster-row.sh"

HERE="${BIONIC_HOOKS_DIR}"
GUARD="$HERE/stop-guard.sh"
RECORDER="$HERE/execution-recorder.sh"
OBSERVE="$HERE/stop-check.sh"
# `cd … && pwd` normalizes the path: $TMPDIR carries a trailing slash on
# macOS, and a doubled separator would slugify differently from the cwd the
# script under test actually sees.
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/stop-guard-test.XXXXXX")" && pwd)"
trap 'rm -rf "$SANDBOX"' EXIT

# ---------- suite-specific assertions (not framework-owned) ----------

expect_file()     { if [ -f "$2" ]; then ok "$1"; else no "$1" "no such file: $2"; fi; }
expect_no_file()  { if [ -f "$2" ]; then no "$1" "file exists but should not: $2"; else ok "$1"; fi; }

# HELPER-PRESENCE GUARD (S11, spec AC-25). `expect_eq` comes from tests/lib/assert.sh
# and is not defined anywhere in this file — before this slice, its one call below
# (":re-engaged: the refusal is byte-identical") ran under `set -uo pipefail` with no
# `-e`, so an undefined `expect_eq` was a silent stderr line and the row asserted
# nothing (the same class of defect r24e was in dispatch-preflight.test.sh,
# research-code-map §6.2). Every helper this file calls is checked to exist as a
# function before the first test runs, so a future undefined call fails the whole
# suite loudly instead of vanishing.
require_helpers ok no expect_status expect_contains expect_regex expect_absent \
  expect_empty expect_file expect_no_file expect_eq

# ---------- fixtures ----------
#
# FIXTURE FIDELITY (declared per checklist §A / spec §Design).
#
# Source: .bionic/docs/record/epic-15-kill-interception-experiment.md, CLI
# 2.1.220 verbatim captures.
#
#   * PreToolUse|TaskStop payload — FAITHFUL to §2.2, field for field:
#     session_id, transcript_path, cwd, prompt_id, permission_mode, effort,
#     hook_event_name, tool_name, tool_input.task_id, tool_use_id. Critically
#     §2.2 establishes that `tool_input.task_id` is THE CALLER'S STRING AS TYPED
#     ("victim", a name) and that no resolved agent id is present in the
#     payload — the property every resolution test here depends on.
#   * PostToolUse|Bash payload — FAITHFUL to
#     .bionic/docs/record/w3-slice1-posttooluse-probe.md capture A (CLI 2.1.222),
#     field for field including the tool_response object. Used only to drive the
#     recorder that seeds this suite's records.
#   * transcript_path → session directory — FAITHFUL to §2.5, which captures
#     `agent_transcript_path` as "<transcript-dir>/<session-id>/subagents/agent-<id>.jsonl".
#   * meta.json — FAITHFUL to §2.8 (verbatim field set), plus the named
#     in-process-teammate fields read live from this machine on 2026-08-04.
#   * SYNTHESIZED and declared: session ids, agent ids, plan text, message text.
#     None is a platform surface.
#
# The GATE itself never sees a PostToolUse payload: it must decide BEFORE the stop
# happens, so it only ever reads §2.2's unresolved reference.

mk_bash_payload() {  # <sid> <transcript> <cwd> <command>
  jq -n --arg s "$1" --arg t "$2" --arg c "$3" --arg cmd "$4" \
    '{session_id:$s, transcript_path:$t, cwd:$c,
      prompt_id:"f3cd7d62-305d-47ed-9eaf-46fb12d4f4ed",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      hook_event_name:"PreToolUse", tool_name:"Bash",
      tool_input:{command:$cmd}, tool_use_id:"toolu_018jyjgop7KMxP6yKtoAWWtB"}'
}

mk_bash_post() {  # <sid> <transcript> <cwd> <command> <stdout>
  jq -n --arg s "$1" --arg t "$2" --arg c "$3" --arg cmd "$4" --arg out "$5" \
    '{session_id:$s, transcript_path:$t, cwd:$c,
      prompt_id:"598cabc5-2776-479c-abcf-52c540a1c60e",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      hook_event_name:"PostToolUse", tool_name:"Bash",
      tool_input:{command:$cmd, description:"observe"},
      tool_response:{stdout:$out, stderr:"", interrupted:false,
                     isImage:false, noOutputExpected:false},
      tool_use_id:"toolu_01HQV9JAFdKC15TLMDKt2QgF", duration_ms:117}'
}

mk_stop_payload() {  # <sid> <transcript> <cwd> <task_id>
  jq -n --arg s "$1" --arg t "$2" --arg c "$3" --arg id "$4" \
    '{session_id:$s, transcript_path:$t, cwd:$c,
      prompt_id:"f3cd7d62-305d-47ed-9eaf-46fb12d4f4ed",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      hook_event_name:"PreToolUse", tool_name:"TaskStop",
      tool_input:{task_id:$id}, tool_use_id:"toolu_018jyjgop7KMxP6yKtoAWWtB"}'
}

# THE SAME PAYLOADS, INVOKED BY A SUBAGENT (slice 4/6, D-3). FAITHFUL to
# .bionic/docs/record/w3-slice1-posttooluse-probe.md captures C and F: a
# subagent-invoked PreToolUse or PostToolUse payload carries top-level `agent_id`
# and `agent_type` alongside every field the orchestrator's payload has, and the
# orchestrator's omits both. That presence/absence IS the actor key — the gate
# reads it out of its own payload and the recorder read it out of its own, so a
# same-actor comparison is one field against one field.
mk_stop_payload_as() {  # <sid> <transcript> <cwd> <task_id> <invoking-agent-id>
  mk_stop_payload "$1" "$2" "$3" "$4" \
    | jq --arg a "$5" '. + {agent_id:$a, agent_type:"general-purpose"}'
}

mk_bash_post_as() {  # <sid> <transcript> <cwd> <command> <stdout> <invoking-agent-id>
  mk_bash_post "$1" "$2" "$3" "$4" "$5" \
    | jq --arg a "$6" '. + {agent_id:$a, agent_type:"general-purpose"}'
}

GUARD_OUT=""; GUARD_ERR=""; GUARD_ST=0
# THE ENVIRONMENT AGREES WITH THE PAYLOAD, because on the machine it does (A-probe-2).
# The gate's siblings — the sweeper, stop-check — take the session key from the
# environment, and since bionic 1.4.0 so does the gate, so a driver that left the
# runner's own id there would split one fixture session into two.
GUARD_VERR=""
run_guard() {  # <payload-json>
  local _sid; _sid=$(printf '%s' "$1" | jq -r '.session_id // ""' 2>/dev/null) || _sid=""
  GUARD_OUT=$(printf '%s' "$1" | env CLAUDE_CODE_SESSION_ID="$_sid" bash "$GUARD" 2>"$SANDBOX/.err"); GUARD_ST=$?
  GUARD_ERR=$(cat "$SANDBOX/.err")
  # THE SAME CALL AGAIN, WITH THE KNOB (slice 13, ruling D-1). This gate's refusal is
  # now ONE line — `bionic: stop refused — <fact> (<fix>)` — and the twelve-line frame
  # this suite reads for counts, spellings, ages and the pasteable Fix line is `detail`,
  # which reaches a reader only under BIONIC_WALL_VERBOSE=1. `$GUARD_ERR` is therefore
  # the LINE and `$GUARD_VERR` is the line plus the detail; an arm that read the detail
  # off `$GUARD_ERR` would now be asserting that the wall leaks it.
  # ONLY WHEN THE FIRST DRIVE REFUSED: a PERMITTED stop consumes the observation
  # record, and a second drive would consume a second one.
  GUARD_VERR=""
  if [ "$GUARD_ST" -ne 0 ]; then
    GUARD_VERR=$(printf '%s' "$1" | env CLAUDE_CODE_SESSION_ID="$_sid" BIONIC_WALL_VERBOSE=1 \
      bash "$GUARD" 2>&1 >/dev/null)
  fi
  return 0
}

SID_A="6c85684c-9588-45a0-bd26-e8c46956c94f"
SID_B="11111111-2222-3333-4444-555555555555"

# make_world <name> <active-wave:yes|no> — echoes "<repo>|<transcript>|<subagents>"
make_world() {
  local name="$1" wave="$2"
  local home="$SANDBOX/$name/home" repo="$SANDBOX/$name/repo"
  local proj="$home/.claude/projects/p-$name"
  mkdir -p "$repo" "$proj/$SID_A/subagents" "$proj/$SID_B/subagents"
  : > "$proj/$SID_A.jsonl"
  : > "$proj/$SID_B.jsonl"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name "T"
  echo seed > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm seed 2>/dev/null
  if [ "$wave" = "yes" ]; then
    # ENGAGED (task-engaged-session). Since this wave the hook asks `engaged_session`
    # before anything else, so a fixture without the marker is silent for a reason that has
    # nothing to do with the wall under test. Planted for both fixture sessions, beside the
    # plan, because an engaged session is what a live wave IS.
    mkdir -p "$repo/.bionic/tmp"
    : > "$repo/.bionic/tmp/engaged-$SID_A.state"
    : > "$repo/.bionic/tmp/engaged-$SID_B.state"
    mkdir -p "$repo/.bionic/docs/plans/epic-99-test"
    cat > "$repo/.bionic/docs/plans/epic-99-test/wave-01-test.plan.md" <<'PLAN'
---
governing-skill: canonical-sdlc
canonical_sdlc_version: 14
intent: build
rigor: audited
scale: wave
---

# Test wave plan

## SDLC State

integration-branch: main
current: 4

- Step 4: slices in flight
PLAN
  fi
  printf '%s|%s|%s\n' "$repo" "$proj/$SID_A.jsonl" "$proj/$SID_A/subagents"
}

# ---------- THE RECORDED ListAgents ANSWER — the live set (S6, D1′) ----------
#
# Since this slice the two stop scripts resolve a target against the newest recorded
# ListAgents answer in the session transcript, not against agent-*.meta.json on disk. So a
# fixture world's transcript is no longer an empty file: it carries a prompt, the assistant's
# ListAgents call and the harness's answer, in that order, which is what makes the answer
# FRESH (recorded after the last user prompt).
#
# THE ANSWER BODY'S SHAPE IS THE REAL ONE, copied from tests/live-agents.test.sh, whose two
# bodies are byte-verbatim captures of this project's own transcript (the separator is
# U+00B7, and the `[8895ce]` ref suffix is what the reader strips off a name). Composing a
# body here rather than reading that suite's is the same call S4 made about the fixture file:
# `.bionic/` is gitignored, so anything read from it passes on this machine and fails in a
# fresh clone.
# THE ANSWER BODY IS BUILT BY tests/lib/live-answer.sh (S17, spec AC-27/AC-28): the self
# line, the `Teammates (N):` header and every teammate row come out of the committed corpus
# at tests/fixtures/claude/listagents-answers.jsonl with only this suite's names and
# statuses substituted in place. The private builder that used to sit here re-typed the
# harness's separator, its ref suffix and its recognition anchor — three spellings of that
# anchor across the tree, and the one thing standing between "empty answer" and
# "unrecognised body".
#
# `LIVE_ANSWER_TYPE` is the type the composed rows carry; the two ambiguity sections and
# §I assert on `bionic:senior-implementor`. A bare name is the corpus's own `running`;
# `name:idle` writes the harness's other status — a teammate that finished its turn and
# was never stopped stays listed, because it stays addressable.
LIVE_ANSWER_TYPE="bionic:senior-implementor"

la_body() {  # <name[:status]>... -> one real-shaped ListAgents answer body
  live_answer_body "$@"
}

# plant_live <transcript> <fresh|stale> <name>...  — rewrite a transcript so its newest
# ListAgents answer names exactly these teammates. `stale` appends one more user prompt
# AFTER the answer, which is the whole of what STALE means (D1′).
plant_live() {
  local tr="$1" freshness="$2"; shift 2
  local body; body=$(la_body "$@")
  {
    jq -nc --arg ts "2026-09-05T00:50:00.000Z" \
      '{type:"user",timestamp:$ts,message:{role:"user",content:"go"}}'
    jq -nc --arg ts "2026-09-05T00:51:00.000Z" \
      '{type:"assistant",timestamp:$ts,message:{role:"assistant",content:[{type:"tool_use",id:"toolu_01FIXTURELISTAGENTS",name:"ListAgents",input:{}}]}}'
    jq -nc --arg ts "2026-09-05T00:52:23.349Z" --arg b "$body" \
      '{type:"user",timestamp:$ts,message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_01FIXTURELISTAGENTS",content:$b}]}}'
    if [ "$freshness" = "stale" ]; then
      jq -nc --arg ts "2026-09-05T00:53:00.000Z" \
        '{type:"user",timestamp:$ts,message:{role:"user",content:"a later turn"}}'
    fi
  } > "$tr"
  return 0
}

# plant_agent <subagents-dir> <agent-id> <name> [mtime-touch]
#
# Plants the working log the observation reads AND adds the name to its session's live set,
# because after S6 an agent that is not in the newest ListAgents answer does not resolve at
# all. The name list is accumulated in a sidecar so a second call adds to the answer rather
# than replacing it.
plant_agent() {
  local dir="$1" aid="$2" aname="$3" touchts="${4:-}"
  printf '{"agentType":"general-purpose","description":"a test agent","name":"%s","toolUseId":"toolu_01TEST","spawnDepth":0,"model":"opus","taskKind":"in_process_teammate"}\n' \
    "$aname" > "$dir/agent-$aid.meta.json"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}\n' \
    > "$dir/agent-$aid.jsonl"
  [ -n "$touchts" ] && touch -t "$touchts" "$dir/agent-$aid.jsonl"
  local tr="${dir%/subagents}.jsonl" names=() n
  printf '%s\n' "$aname" >> "${dir%/subagents}.names"
  while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done < "${dir%/subagents}.names"
  plant_live "$tr" fresh "${names[@]}"
  return 0
}

STATE_REL=".bionic/tmp/stop-check.state"

# THE WHOLE PRODUCER→RECORDER PATH, run for real. Since slice 4/4 an observation
# record exists only if hooks/stop-check.sh actually printed its machine line, so
# seeding one by hand would seed a shape the shipped writer can no longer produce.
# The metadata root is reached through CLAUDE_CONFIG_DIR, derived from the same
# transcript path the gate resolves through, so both halves see one fixture world.
# The observation's own session key travels on CLAUDE_CODE_SESSION_ID (slice
# 4/5): it is how the producer finds THIS session's roster, and therefore how a
# contracted progress path reaches the record at all. This suite runs inside a
# real Claude Code session, which exports a real value — unpinned, every call
# below would classify against whatever session happens to be running the suite
# rather than against the fixture, and the suite's HERMETIC claim would be
# quietly false. Pinned to the fixture session here — and since S6 there is no keyless
# variant to opt out with: hooks/stop-check.sh cannot reach a live set without a session key,
# so a keyless look produces no record at all rather than an incomplete one.
observe() {  # <sid> <transcript> <repo> <typed-target> [args…]
  observe_as "" "$@"
}

# <observer> is the agent id of the actor that RAN the observation — empty for
# the orchestrator, which is exactly how the platform renders it (the field is
# absent, and the recorder writes the literal token `orchestrator`).
observe_as() {  # <observer-agent-id|""> <sid> <transcript> <repo> <typed-target> [args…]
  local observer="$1" sid="$2" tr="$3" repo="$4"; shift 4
  local cfg="${tr%/projects/*}" out payload
  out=$( cd "$repo" && CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID="$sid" \
         bash "$OBSERVE" "$@" 2>/dev/null )
  if [ -n "$observer" ]; then
    payload=$(mk_bash_post_as "$sid" "$tr" "$repo" \
      "bash ~/.claude/hooks/stop-check.sh $*" "$out" "$observer")
  else
    payload=$(mk_bash_post "$sid" "$tr" "$repo" \
      "bash ~/.claude/hooks/stop-check.sh $*" "$out")
  fi
  # The recorder takes its session key from the environment now (lib/session.sh, env
  # primary), so the fixture session travels with the payload rather than beside it —
  # otherwise the record lands under whatever session is running this suite.
  printf '%s' "$payload" | env CLAUDE_CODE_SESSION_ID="$sid" bash "$RECORDER" >/dev/null 2>&1
  return 0
}

# THE SESSION ROSTER, planted as the PRECONDITION it is at a real stop. Row shape
# FAITHFUL to the writer, hooks/dispatch-preflight.sh's `ROW=` line (field for
# field, in order); the writer itself is driven by its own suite and the two
# shapes are held together by tests/cross-gate-agreement.test.sh. Since slice 4/9
# a row is no longer what makes a target ours — its directory is — so a world that
# plants none is a perfectly ordinary one. What a row still carries is the
# CONTRACT, and, when `confirmed`, ownership of a target filed elsewhere.
#
# The CONTRACT FIELDS (deliverable, waiver, teammate_id) are optional trailing
# arguments rather than a second helper: epic-16 wave-02 slice S3 made the row's
# contract the thing that discharges a stop, so a suite that could only plant
# contract-less rows could not express the discharging case at all. Every call
# written before that slice passes none of them and gets the identical row it got
# before — an empty `deliverable=` is what the writer emits for a dispatch that
# declared nothing.
# `adopted_from=` is the tenth optional argument for the same reason the contract fields
# are the seventh through ninth: hooks/session-poker.sh's `adopt` writes it onto a row in
# the ADOPTING session's roster, and a suite that could only plant rows without it could not
# express a taken-over agent at all — which is exactly the state §14 is about.
# RENAMED OFF THE WRITER'S NAME (S17): `roster_row` is the production writer
# (payload/scripts/lib/roster.sh), and a private definition of that name would shadow the
# one writer with a fixture.
sg_roster_row() {  # <repo> <sid> <name> <agent-id> [progress] [status] [deliverable] [waiver] [teammate-id] [adopted-from]
  local repo="$1" sid="$2" name="$3" aid="$4" prog="${5:-}" status="${6:-confirmed}"
  local deliv="${7:-}" waiver="${8:-}" tmid="${9:-}" afrom="${10:-}"
  local f="$repo/.bionic/tmp/roster-$sid.state"
  mkdir -p "$repo/.bionic/tmp"
  [ -f "$f" ] || roster_header > "$f"
  roster_row_fixture status="$status" session="$sid" name="$name" agent_id="$aid" \
    launched_at=2026-08-05T00:00:00Z deliverable="$deliv" progress="$prog" \
    waiver="$waiver" teammate_id="$tmid" adopted_from="$afrom" >> "$f"
  return 0
}

# The sweeper's own ack verb, run for real against the fixture repo — never a
# hand-written ledger line. An ack is the ONLY thing that closes a row which
# declared no machine-visible artifact, so the gate's ack discharge has to be
# driven through the writer that actually ships.
ack_row() {  # <repo> <sid> <name>
  ( cd "$1" && CLAUDE_CODE_SESSION_ID="$2" bash "$HERE/session-sweeper.sh" ack "$3" ) >/dev/null 2>&1
  return 0
}

# A user's stop order, recorded through the shipped helper for the same reason.
order_stop() {  # <repo> <sid> <target> [--at <epoch>]
  ( cd "$1" && CLAUDE_CODE_SESSION_ID="$2" bash "$HERE/stop-orders.sh" order "${@:3}" ) >/dev/null 2>&1
  return 0
}

section "Section 1: the hot path — relevance before any plan walk (checklist A7)"

IFS='|' read -r W1_REPO W1_TR W1_SUB <<< "$(make_world w1 yes)"
plant_agent "$W1_SUB" "aquiet-reviewer-deadbeefdeadbeef" "quiet-reviewer"

run_guard "$(jq -n --arg c "$W1_REPO" '{session_id:"x", cwd:$c, hook_event_name:"PreToolUse", tool_name:"Read", tool_input:{file_path:"/tmp/x"}}')"
expect_status "an unrelated TOOL passes untouched" 0 "$GUARD_ST"
expect_no_file "an unrelated tool writes no state" "$W1_REPO/$STATE_REL"

# A Bash call is no longer this script's business AT ALL (slice 4/4 moved the
# recorder out). It must pass untouched and, more importantly, write nothing:
# a settings file that still carries the retired PreToolUse|Bash registration
# must produce silence rather than a second writer of the same state.
run_guard "$(mk_bash_payload "$SID_A" "$W1_TR" "$W1_REPO" "ls -la && git status")"
expect_status "an unrelated Bash command passes untouched" 0 "$GUARD_ST"
expect_no_file "an unrelated Bash command writes no state" "$W1_REPO/$STATE_REL"

run_guard "$(mk_bash_payload "$SID_A" "$W1_TR" "$W1_REPO" "bash ~/.claude/hooks/stop-check.sh quiet-reviewer")"
expect_status "a REAL observation command is no longer this gate's business" 0 "$GUARD_ST"
expect_no_file "the stop gate writes no observation record, ever (one writer)" "$W1_REPO/$STATE_REL"

run_guard "$(jq -n --arg c "$W1_REPO" '{session_id:"x", cwd:$c, hook_event_name:"PreToolUse", tool_name:"Agent", tool_input:{prompt:"go"}}')"
expect_status "the Agent tool is not this gate's business" 0 "$GUARD_ST"

# Static order pin: the cheap relevance test must precede the plan-directory
# walk in the source, not merely produce the same answer (arch-perf F8/F9 — the
# defect was cost, which behavior alone cannot detect). The relevance test is now
# the tool-name check itself.
_rel_line=$(grep -n 'TOOL_NAME" = "TaskStop" \] || exit 0' "$GUARD" | head -1 | cut -d: -f1)
# The expensive work used to begin at the plan walk; since task-engaged-session this gate
# reads no plan at all, and the first thing it pays for is resolving the project root — the
# ancestor walk `engaged_session` and every state path below it are built on.
_walk_line=$(grep -nE '^[[:space:]]*(REPO=\$\(project_root|PLAN=|find )' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$_rel_line" ] && [ -n "$_walk_line" ] && [ "$_rel_line" -lt "$_walk_line" ]; then
  ok "relevance check precedes the plan walk in source order"
else
  no "relevance check precedes the plan walk in source order" "relevance@${_rel_line:-none} walk@${_walk_line:-none}"
fi

setup_section "Section 2: WRITING moved out — see tests/execution-recorder.test.sh"
#
# Everything that used to be asserted here — a run records its target, a mention
# records nothing, an unresolvable or ambiguous target records nothing, the state
# is bounded and pruned, no command text leaks into it — is asserted against the
# script that now performs it, hooks/execution-recorder.sh. Duplicating those rows
# here would pin this gate to behaviour it no longer has.
#
# What this suite still owes the reader is that the gate SPENDS a real record, and
# every section below does exactly that: each one seeds through `observe()`, which
# runs the real observation and the real recorder end to end.

section "Section 3: the observation record is VERSIONED and key-addressed (checklist A6)"

IFS='|' read -r W3_REPO W3_TR W3_SUB <<< "$(make_world w3 yes)"
plant_agent "$W3_SUB" "atarget-3333333333333333" "target"
sg_roster_row "$W3_REPO" "$SID_A" "target" "atarget-3333333333333333"
observe "$SID_A" "$W3_TR" "$W3_REPO" "target"
STATE=$(cat "$W3_REPO/$STATE_REL")

# Forward compatibility: one MORE field must not break the reader (A6 — the
# defect was a fixed-field-order parser breaking undiagnosably on a new field).
sed -i.bak 's/$/|futurefield=whatever/' "$W3_REPO/$STATE_REL"
rm -f "$W3_REPO/$STATE_REL.bak"
run_guard "$(mk_stop_payload "$SID_A" "$W3_TR" "$W3_REPO" "target")"
expect_status "an unknown EXTRA field does not break the reader" 0 "$GUARD_ST"

# An unknown schema VERSION is not guessed at — it is refused.
observe "$SID_A" "$W3_TR" "$W3_REPO" "target"
sed -i.bak 's/^v1|/v9|/' "$W3_REPO/$STATE_REL"; rm -f "$W3_REPO/$STATE_REL.bak"
run_guard "$(mk_stop_payload "$SID_A" "$W3_TR" "$W3_REPO" "target")"
expect_status "an unknown schema VERSION refuses the stop" 2 "$GUARD_ST"

section "Section 4: fail directions at the stop gate (AC-10, TDD §7)"

# --- before the active-wave verdict: OPEN and SILENT ---
IFS='|' read -r N_REPO N_TR N_SUB <<< "$(make_world nowave no)"
plant_agent "$N_SUB" "aidle-4444444444444444" "idle"
run_guard "$(mk_stop_payload "$SID_A" "$N_TR" "$N_REPO" "idle")"
expect_status "no active wave: the stop passes" 0 "$GUARD_ST"
expect_empty "no active wave: the gate is silent" "$GUARD_ERR"

run_guard "$(jq -n --arg c "$N_REPO" '{cwd:$c, hook_event_name:"PreToolUse", tool_name:"TaskStop", tool_input:{task_id:"idle"}}')"
expect_status "no active wave + no session key: still open (pre-verdict)" 0 "$GUARD_ST"
expect_empty "no active wave + no session key: still silent" "$GUARD_ERR"

# A plan that exists but names no step is not a run in progress — AND SINCE
# task-engaged-session THAT IS NO LONGER THIS GATE'S QUESTION. What scopes it is
# ENGAGEMENT: a stop is policed because this session entered bionic, not because the repo
# holds a plan at a particular step. The roster row this gate answers for outlives the run
# that created it, and a run's Step 0 precedes its own plan, so a gate that read the step
# would go quiet at exactly the two moments a landing contract still exists. The fixture is
# kept and its expectation inverted: an ENGAGED session is policed here whatever the plan
# says, and the paired negative below is the marker, not the step.
IFS='|' read -r P_REPO P_TR P_SUB <<< "$(make_world plannostep yes)"
plant_agent "$P_SUB" "aidle-4444444444444444" "idle"
sg_roster_row "$P_REPO" "$SID_A" "idle" "aidle-4444444444444444"
sed -i.bak 's/^current: 4$/current: pending/' "$P_REPO/.bionic/docs/plans/epic-99-test/wave-01-test.plan.md"
rm -f "$P_REPO/.bionic/docs/plans/epic-99-test/wave-01-test.plan.md.bak"
run_guard "$(mk_stop_payload "$SID_A" "$P_TR" "$P_REPO" "idle")"
expect_status "an engaged session is policed whatever the plan's step says: REFUSED" 2 "$GUARD_ST"
P_REFUSAL="$GUARD_ERR"

rm -f "$P_REPO/.bionic/tmp/engaged-$SID_A.state"
run_guard "$(mk_stop_payload "$SID_A" "$P_TR" "$P_REPO" "idle")"
expect_status "…and the same stop unengaged is open" 0 "$GUARD_ST"
expect_empty "…and silent" "$GUARD_ERR"

# a SYMLINK at the marker path reads as ABSENT, never followed.
P_DECOY="$SANDBOX/plannostep-decoy-marker"; printf 'plan=none\n' > "$P_DECOY"
ln -s "$P_DECOY" "$P_REPO/.bionic/tmp/engaged-$SID_A.state"
run_guard "$(mk_stop_payload "$SID_A" "$P_TR" "$P_REPO" "idle")"
expect_status "a symlink at the marker path is not an engagement: open" 0 "$GUARD_ST"
expect_empty "…and silent" "$GUARD_ERR"
rm -f "$P_REPO/.bionic/tmp/engaged-$SID_A.state"

# ANOTHER session's marker is not this session's.
: > "$P_REPO/.bionic/tmp/engaged-$SID_B.state"
run_guard "$(mk_stop_payload "$SID_A" "$P_TR" "$P_REPO" "idle")"
expect_status "another session's marker is not this session's engagement: open" 0 "$GUARD_ST"
rm -f "$P_REPO/.bionic/tmp/engaged-$SID_B.state"

# restored, the refusal returns byte for byte.
: > "$P_REPO/.bionic/tmp/engaged-$SID_A.state"
run_guard "$(mk_stop_payload "$SID_A" "$P_TR" "$P_REPO" "idle")"
expect_eq "re-engaged: the refusal is byte-identical" "$P_REFUSAL" "$GUARD_ERR"

# --- after the verdict: CLOSED and LOUD ---
IFS='|' read -r W4_REPO W4_TR W4_SUB <<< "$(make_world w4 yes)"
plant_agent "$W4_SUB" "aquiet-reviewer-deadbeefdeadbeef" "quiet-reviewer"
sg_roster_row "$W4_REPO" "$SID_A" "quiet-reviewer" "aquiet-reviewer-deadbeefdeadbeef"

run_guard "$(mk_stop_payload "$SID_A" "$W4_TR" "$W4_REPO" "quiet-reviewer")"
expect_status "active wave + no observation: REFUSED" 2 "$GUARD_ST"

# §7's stop=closed row, and since task-engaged-session it has to be driven on the channel
# that actually carries identity. The gate asks `engaged_session` first, keyed to the
# LIBRARY's session id (env primary, payload witness) — so a payload with no key still
# resolves to a session whenever the environment carries one, which on the machine it
# always does. What §7 pins is unchanged: once this session is known to be engaged, an
# identity the gate cannot read out of its own payload is refused, not waved through.
W4_NOKEY=$(jq -n --arg c "$W4_REPO" --arg t "$W4_TR" \
  '{transcript_path:$t, cwd:$c, hook_event_name:"PreToolUse", tool_name:"TaskStop", tool_input:{task_id:"quiet-reviewer"}}')
GUARD_OUT=$(printf '%s' "$W4_NOKEY" | env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$GUARD" 2>"$SANDBOX/.err"); GUARD_ST=$?
GUARD_ERR=$(cat "$SANDBOX/.err")
expect_status "active wave + payload missing its session key: REFUSED (closed)" 2 "$GUARD_ST"

# AND THE ROW BELOW IT, new with the switch: a payload with no key AND no key in the
# environment cannot be shown to belong to an engaged session at all. Engagement is
# open-by-absence by design — the one artifact whose PRESENCE opens walls — so this is
# silent rather than refused, and it is the only direction consistent with a bystander
# session never seeing a refusal it did not consent to.
GUARD_OUT=$(printf '%s' "$W4_NOKEY" | env -u CLAUDE_CODE_SESSION_ID bash "$GUARD" 2>"$SANDBOX/.err"); GUARD_ST=$?
GUARD_ERR=$(cat "$SANDBOX/.err")
expect_status "…and with no session key on EITHER channel: open, engagement unprovable" 0 "$GUARD_ST"
expect_empty "…and silent" "$GUARD_ERR"

run_guard "$(mk_stop_payload "$SID_A" "$W4_TR" "$W4_REPO" "")"
expect_status "active wave + empty task_id: REFUSED" 2 "$GUARD_ST"

run_guard "$(mk_stop_payload "$SID_A" "$W4_TR" "$W4_REPO" "no-such-agent")"
expect_status "active wave + unresolvable name (not address-shaped): PASSES THROUGH (T4)" 0 "$GUARD_ST"
expect_regex "…and the passthrough is logged, never silent" 'PASSTHROUGH' "$GUARD_ERR"

# Ambiguity: two live agents answering to the same name — two lines in the Teammates block,
# which is what two sessions in one root launching same-named agents looks like (D2′).
plant_agent "$W4_SUB" "adouble-5555555555555555" "twin"
plant_agent "$W4_SUB" "adouble-6666666666666666" "twin"
run_guard "$(mk_stop_payload "$SID_A" "$W4_TR" "$W4_REPO" "twin")"
expect_status "active wave + ambiguous name: REFUSED" 2 "$GUARD_ST"
expect_contains "…and the refusal says how many answer to it" "2 live agents answer to 'twin'" "$GUARD_VERR"

# A plan with CR-only line endings is still a plan. `tr -d` on those separators
# collapses the file to one line, the run-state marker goes unseen, and the gate
# quietly reports "no wave" on a repo mid-wave — the fail-dangerous shape that
# bypassed the evidence gate for a whole wave (.claude/rules/hook-authoring.md).
IFS='|' read -r CR_REPO CR_TR CR_SUB <<< "$(make_world crplan yes)"
plant_agent "$CR_SUB" "acrlf-0123456789abcdef" "crlf"
sg_roster_row "$CR_REPO" "$SID_A" "crlf" "acrlf-0123456789abcdef"
CR_PLAN="$CR_REPO/.bionic/docs/plans/epic-99-test/wave-01-test.plan.md"
tr '\n' '\r' < "$CR_PLAN" > "$CR_PLAN.cr" && mv "$CR_PLAN.cr" "$CR_PLAN"
run_guard "$(mk_stop_payload "$SID_A" "$CR_TR" "$CR_REPO" "crlf")"
expect_status "a CR-only plan is still read: the wave is still detected" 2 "$GUARD_ST"

# The positive pair — a wall that refuses everything is equally broken (§9).
observe "$SID_A" "$W4_TR" "$W4_REPO" "quiet-reviewer"
run_guard "$(mk_stop_payload "$SID_A" "$W4_TR" "$W4_REPO" "quiet-reviewer")"
expect_status "active wave + fresh observation: PERMITTED" 0 "$GUARD_ST"
expect_empty "a permitted stop is silent" "$GUARD_ERR"

# A foreign session's observation is not mine.
IFS='|' read -r W5_REPO W5_TR W5_SUB <<< "$(make_world w5 yes)"
plant_agent "$W5_SUB" "aquiet-reviewer-deadbeefdeadbeef" "quiet-reviewer"
sg_roster_row "$W5_REPO" "$SID_A" "quiet-reviewer" "aquiet-reviewer-deadbeefdeadbeef"
observe "$SID_B" "$W5_TR" "$W5_REPO" "quiet-reviewer"
run_guard "$(mk_stop_payload "$SID_A" "$W5_TR" "$W5_REPO" "quiet-reviewer")"
expect_status "another session's observation does not discharge my stop" 2 "$GUARD_ST"

section "Section 4a: unsupervised-target passthrough (T4, AC-6)"
#
# scan_subagent_dirs only ever iterates agent-*.meta.json — the Agent tool's own
# bookkeeping. A background bash task id never gets one (A-D4), so MATCH_COUNT
# was unconditionally 0 for it, forever, with no code path back to
# order_current() — the escape hatch this gate's own header advertises
# (step2-research-a1-a3.md §A3). The ratified carve (session.plan.md ## Design
# ¶T4): refuse only a target wearing an AGENT-ADDRESS shape (`@session-`, or
# transcript-form `a<hex>` / `a<name>-<16hex>`); everything else passes through,
# logged once, never silent.

# (a) A bash-background-task-shaped id (A-D4 probe evidence: t5triyxvo) carries
# no agent metadata and wears no address shape: PASSES THROUGH.
run_guard "$(mk_stop_payload "$SID_A" "$W4_TR" "$W4_REPO" "t5triyxvo")"
expect_status "a bash-task-shaped target with no metadata: PASSES THROUGH" 0 "$GUARD_ST"
expect_regex "…and the passthrough is logged, never silent" 'PASSTHROUGH' "$GUARD_ERR"

# (b) An addressing-form target (`name@session-xxxx`) with no metadata IS
# address-shaped: stays REFUSED, the verbatim unresolved-target message unchanged.
run_guard "$(mk_stop_payload "$SID_A" "$W4_TR" "$W4_REPO" "ghost@session-deadbeef")"
expect_status "an addressing-form target with no metadata: still REFUSED" 2 "$GUARD_ST"

# (c) Transcript-form targets (`a`+hex, and `a<name>-<16hex>`) with no metadata
# ARE address-shaped: stay REFUSED.
run_guard "$(mk_stop_payload "$SID_A" "$W4_TR" "$W4_REPO" "af3d9128ea3b393af")"
expect_status "a hex transcript-form target with no metadata: still REFUSED" 2 "$GUARD_ST"

run_guard "$(mk_stop_payload "$SID_A" "$W4_TR" "$W4_REPO" "aghost-0123456789abcdef")"
expect_status "a named transcript-form target with no metadata: still REFUSED" 2 "$GUARD_ST"

# (d) A supervised named target (metadata present) still engages the FULL guard
# path, untouched — the passthrough branch is reached only at MATCH_COUNT=0, and
# a target that resolves to a real agent of this session never gets there.
# DRIVEN (Step-6 review flag 2-C: a bare `ok` here asserted nothing and could not
# fail). Quiet-reviewer's own REFUSED/PERMITTED pair above already proves the
# full path for that name; this plants a SECOND, never-observed teammate in the
# same active-wave world so the assertion here carries its own evidence rather
# than pointing at rows planted for a different purpose.
plant_agent "$W4_SUB" "ahushed-reviewer-7777777777777777" "hushed-reviewer"
sg_roster_row "$W4_REPO" "$SID_A" "hushed-reviewer" "ahushed-reviewer-7777777777777777"
run_guard "$(mk_stop_payload "$SID_A" "$W4_TR" "$W4_REPO" "hushed-reviewer")"
expect_status "a supervised named target still engages the full guard path: REFUSED for want of an observation" 2 "$GUARD_ST"
expect_absent "…and this is NOT the passthrough branch" "PASSTHROUGH" "$GUARD_ERR"

section "Section 5: D-1 — freshness by ACTIVITY BOUNDARY, no clocks (AC-4)"

IFS='|' read -r D1_REPO D1_TR D1_SUB <<< "$(make_world d1 yes)"
plant_agent "$D1_SUB" "aworker-7777777777777777" "worker"
sg_roster_row "$D1_REPO" "$SID_A" "worker" "aworker-7777777777777777"

# STALE: the target wrote AFTER the observation. This is the founding incident
# (UC-5) and the flaw the v1 exchange-keyed design provably re-permitted.
observe "$SID_A" "$D1_TR" "$D1_REPO" "worker"
sleep 1
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"committed my work"}]}}\n' \
  >> "$D1_SUB/agent-aworker-7777777777777777.jsonl"
run_guard "$(mk_stop_payload "$SID_A" "$D1_TR" "$D1_REPO" "worker")"
expect_status "target wrote after the observation: REFUSED as stale" 2 "$GUARD_ST"

# SUB-SECOND: a write inside the same mtime second still counts as activity.
IFS='|' read -r D1B_REPO D1B_TR D1B_SUB <<< "$(make_world d1b yes)"
plant_agent "$D1B_SUB" "aworker-8888888888888888" "worker"
sg_roster_row "$D1B_REPO" "$SID_A" "worker" "aworker-8888888888888888"
observe "$SID_A" "$D1B_TR" "$D1B_REPO" "worker"
LOG="$D1B_SUB/agent-aworker-8888888888888888.jsonl"
MT=$(date -r "$LOG" +%Y%m%d%H%M.%S 2>/dev/null)
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}\n' >> "$LOG"
touch -t "$MT" "$LOG"   # restored to the SAME mtime second; only the size grew
run_guard "$(mk_stop_payload "$SID_A" "$D1B_TR" "$D1B_REPO" "worker")"
expect_status "a write within the same mtime second is still activity: REFUSED" 2 "$GUARD_ST"

# DORMANT, HOWEVER OLD: no clock may expire an honest observation.
IFS='|' read -r D2_REPO D2_TR D2_SUB <<< "$(make_world d1old yes)"
plant_agent "$D2_SUB" "asleeper-9999999999999999" "sleeper" "202601010000"
sg_roster_row "$D2_REPO" "$SID_A" "sleeper" "asleeper-9999999999999999"
observe "$SID_A" "$D2_TR" "$D2_REPO" "sleeper"
touch -t 202601010000 "$D2_SUB/agent-asleeper-9999999999999999.jsonl"
run_guard "$(mk_stop_payload "$SID_A" "$D2_TR" "$D2_REPO" "sleeper")"
expect_status "dormant since the observation, however old: PERMITTED" 0 "$GUARD_ST"

# LONG-EXCHANGE, MULTI-AGENT (§9 — the configuration v1 never tested). One
# session, three agents, interleaved observations and stops, with one agent
# waking up mid-sequence.
IFS='|' read -r LX_REPO LX_TR LX_SUB <<< "$(make_world longx yes)"
plant_agent "$LX_SUB" "aalpha-aaaaaaaaaaaaaaaa" "alpha"
plant_agent "$LX_SUB" "abeta-bbbbbbbbbbbbbbbb"  "beta"
plant_agent "$LX_SUB" "agamma-cccccccccccccccc" "gamma"
sg_roster_row "$LX_REPO" "$SID_A" "alpha" "aalpha-aaaaaaaaaaaaaaaa"
sg_roster_row "$LX_REPO" "$SID_A" "beta" "abeta-bbbbbbbbbbbbbbbb"
sg_roster_row "$LX_REPO" "$SID_A" "gamma" "agamma-cccccccccccccccc"
observe "$SID_A" "$LX_TR" "$LX_REPO" "alpha"
observe "$SID_A" "$LX_TR" "$LX_REPO" "beta"
observe "$SID_A" "$LX_TR" "$LX_REPO" "gamma"
sleep 1
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"still here"}]}}\n' \
  >> "$LX_SUB/agent-abeta-bbbbbbbbbbbbbbbb.jsonl"
run_guard "$(mk_stop_payload "$SID_A" "$LX_TR" "$LX_REPO" "alpha")"
expect_status "long exchange: dormant alpha still stoppable" 0 "$GUARD_ST"
run_guard "$(mk_stop_payload "$SID_A" "$LX_TR" "$LX_REPO" "beta")"
expect_status "long exchange: beta woke up — its earlier observation is stale" 2 "$GUARD_ST"
run_guard "$(mk_stop_payload "$SID_A" "$LX_TR" "$LX_REPO" "gamma")"
expect_status "long exchange: gamma's own observation survives the others" 0 "$GUARD_ST"

section "Section 6: D-2 — one observation, one stop (AC-5)"

IFS='|' read -r D2R_REPO D2R_TR D2R_SUB <<< "$(make_world d2 yes)"
plant_agent "$D2R_SUB" "arunner-dddddddddddddddd" "runner"
sg_roster_row "$D2R_REPO" "$SID_A" "runner" "arunner-dddddddddddddddd"
observe "$SID_A" "$D2R_TR" "$D2R_REPO" "runner"
run_guard "$(mk_stop_payload "$SID_A" "$D2R_TR" "$D2R_REPO" "runner")"
expect_status "the first stop is permitted" 0 "$GUARD_ST"
expect_absent "a permitted stop CONSUMES its observation" \
  "arunner-dddddddddddddddd" "$(cat "$D2R_REPO/$STATE_REL" 2>/dev/null)"

run_guard "$(mk_stop_payload "$SID_A" "$D2R_TR" "$D2R_REPO" "runner")"
expect_status "a second stop without a fresh observation: REFUSED" 2 "$GUARD_ST"

observe "$SID_A" "$D2R_TR" "$D2R_REPO" "runner"
run_guard "$(mk_stop_payload "$SID_A" "$D2R_TR" "$D2R_REPO" "runner")"
expect_status "re-observing re-arms the stop" 0 "$GUARD_ST"

# A REFUSED stop consumes nothing — nothing was stopped.
IFS='|' read -r D2B_REPO D2B_TR D2B_SUB <<< "$(make_world d2b yes)"
plant_agent "$D2B_SUB" "abusy-eeeeeeeeeeeeeeee" "busy"
sg_roster_row "$D2B_REPO" "$SID_A" "busy" "abusy-eeeeeeeeeeeeeeee"
observe "$SID_A" "$D2B_TR" "$D2B_REPO" "busy"
sleep 1
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"awake"}]}}\n' \
  >> "$D2B_SUB/agent-abusy-eeeeeeeeeeeeeeee.jsonl"
run_guard "$(mk_stop_payload "$SID_A" "$D2B_TR" "$D2B_REPO" "busy")"
expect_status "the stale stop is refused" 2 "$GUARD_ST"
expect_contains "a REFUSED stop consumes nothing" \
  "abusy-eeeeeeeeeeeeeeee" "$(cat "$D2B_REPO/$STATE_REL" 2>/dev/null)"

section "Section 6a: the refusal's Fix line is runnable AS PRINTED (R2)"
#
# The ownership table names one test for fix-command text across TWO rendering
# gates, and it drove only the start gate's (Step-6 duplication review, row 5).
# This is the stop side's counterpart: capture the literal line a blocked
# orchestrator sees and EXECUTE it, from a non-repo cwd, against a staged copy
# of the real observation. The defect it pins: bracketed placeholders on the
# command line became positional arguments the observation reported as three
# absent deliverables (R2) — a refusal that teaches the reader something false.
IFS='|' read -r R2_REPO R2_TR R2_SUB <<< "$(make_world r2 yes)"
plant_agent "$R2_SUB" "ablocked-aaaaaaaaaaaaaaaa" "blocked"
sg_roster_row "$R2_REPO" "$SID_A" "blocked" "ablocked-aaaaaaaaaaaaaaaa"
run_guard "$(mk_stop_payload "$SID_A" "$R2_TR" "$R2_REPO" "blocked")"
expect_status "the stop with no observation is refused (setup for R2)" 2 "$GUARD_ST"
# THE PASTEABLE FIX LINE IS IN THE DETAIL NOW (slice 13, D-1): the user line names the
# repair in six words and the runnable command is what the knob carries, so this is read
# off the verbose stream. That it still EXECUTES is what the three arms below prove.
FIXLINE=$(printf '%s\n' "$GUARD_VERR" | grep '^Fix: ' | sed 's/^Fix: //')
expect_contains "a fix line was captured to execute" "stop-check.sh" "$FIXLINE"

# The world's OWN home, so the observation genuinely resolves the target and
# reaches its Deliverables section — otherwise it exits at "unresolved" and the
# fabricated-deliverable assertion below is vacuous.
R2_HOME="${R2_TR%%/.claude/projects/*}"
mkdir -p "$R2_HOME/.claude/hooks" "$SANDBOX/r2run/nowhere"
cp "$(dirname "$GUARD")/stop-check.sh" "$R2_HOME/.claude/hooks/stop-check.sh"
R2_OUT=$( cd "$SANDBOX/r2run/nowhere" && HOME="$R2_HOME" bash -c "$FIXLINE" 2>&1 )
R2_ST=$?
if [ "$R2_ST" -eq 127 ] || [ "$R2_ST" -eq 126 ]; then
  no "the captured fix line executes from a non-repo cwd" "exit $R2_ST: $R2_OUT"
else
  ok "the captured fix line executes from a non-repo cwd"
fi
expect_absent "running the fix line as printed produces no usage error" "Usage:" "$R2_OUT"

section "Section 6b: the lock and the consume — the failure paths (C3, S2)"
#
# This region shipped with no callsite at all (Step-6 architecture review A4),
# and both a fail-OPEN consume (C3) and an unbounded spin (S2) lived in it.

# --- C3: a consume that cannot complete must REFUSE the stop ---
#
# The rename is the one consume failure a fixture cannot provoke directly (the
# other two — lock held, no writable temp — deny already and are driven below).
# Proven the way §9 names as durable: mutate a COPY so the rename targets an
# unwritable path, drive it, then re-checksum the shipped file.
GUARD_SUM_BEFORE=$(shasum "$GUARD" | awk '{print $1}')
MUTANT="$SANDBOX/stop-guard.consume-fails.sh"
sed 's|mv -f "$TMP" "$STATE_FILE" 2>/dev/null|mv -f "$TMP" "/nonexistent-dir-0xdead/x" 2>/dev/null|' \
  "$GUARD" > "$MUTANT"

IFS='|' read -r C3_REPO C3_TR C3_SUB <<< "$(make_world c3 yes)"
plant_agent "$C3_SUB" "aunconsumable-5555555555555555" "unconsumable"
sg_roster_row "$C3_REPO" "$SID_A" "unconsumable" "aunconsumable-5555555555555555"
observe "$SID_A" "$C3_TR" "$C3_REPO" "unconsumable"
C3_PAYLOAD=$(mk_stop_payload "$SID_A" "$C3_TR" "$C3_REPO" "unconsumable")
# THE ENVIRONMENT AGREES WITH THE PAYLOAD, as run_guard does: the gate reads its
# engagement marker under the LIBRARY's session id, so a driver that left the runner's own
# id here would exit at the switch and prove nothing about the consume.
C3_ERR=$(printf '%s' "$C3_PAYLOAD" | env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$MUTANT" 2>&1 >/dev/null)
C3_ST=$?
expect_status "a consume that cannot complete REFUSES the stop (C3)" 2 "$C3_ST"
if [ -d "$C3_REPO/.bionic/tmp/.stop-check.lock" ]; then
  no "a refused consume RELEASES the lock" "the lock survived, wedging every later stop"
else
  ok "a refused consume RELEASES the lock"
fi

# --- S2: the gate may not spin forever when the lock cannot be taken ---
#
# `mkdir` fails for reasons a stale-lock reclaim cannot fix — an unwritable state
# directory is repo-controlled — and `rm -rf` of an ABSENT path SUCCEEDS, so a
# reclaim-and-retry loop with no hard bound never terminates. A PreToolUse hook
# that never returns renders no verdict at all, which §7's table has no row for.
# The writer's half of this row is in tests/execution-recorder.test.sh §8.
run_bounded() {  # <label> <secs> <payload> -> sets BOUNDED_ST (137 = killed)
  local secs="$2" payload="$3" waited=0 pid _sid
  # The environment agrees with the payload, as run_guard does — the gate reads its
  # engagement marker under the library's session id (task-engaged-session).
  _sid=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || _sid=""
  printf '%s' "$payload" | env CLAUDE_CODE_SESSION_ID="$_sid" bash "$GUARD" >"$SANDBOX/.bout" 2>"$SANDBOX/.berr" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$secs" ]; do
    sleep 1; waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; BOUNDED_ST=137
  else
    wait "$pid"; BOUNDED_ST=$?
  fi
  return 0
}

IFS='|' read -r S2_REPO S2_TR S2_SUB <<< "$(make_world s2 yes)"
plant_agent "$S2_SUB" "awedged-6666666666666666" "wedged"
sg_roster_row "$S2_REPO" "$SID_A" "wedged" "awedged-6666666666666666"
observe "$SID_A" "$S2_TR" "$S2_REPO" "wedged"        # a valid record, so the gate reaches the consume
mkdir -p "$S2_REPO/.bionic/tmp"
chmod 500 "$S2_REPO/.bionic/tmp"

run_bounded "gate" 12 "$(mk_stop_payload "$SID_A" "$S2_TR" "$S2_REPO" "wedged")"
if [ "$BOUNDED_ST" = "137" ]; then
  no "the GATE arm terminates when the lock cannot be taken (S2)" "still running after 12s"
else
  expect_status "the GATE arm REFUSES rather than spinning (S2, §7 stop=closed)" 2 "$BOUNDED_ST"
fi
chmod 700 "$S2_REPO/.bionic/tmp"

section "Section 7: hostile repo (AC-8, TDD §8, checklist A2/A3)"

# Predictable temp names + symlink-following writes were a PROVEN arbitrary-file
# overwrite in the discarded run (corr-sec S1/S2). Both levels are replanted.
IFS='|' read -r S_REPO S_TR S_SUB <<< "$(make_world sec yes)"
plant_agent "$S_SUB" "avictim-ffffffffffffffff" "victim"
mkdir -p "$S_REPO/.bionic/tmp"
VICTIM_FILE="$SANDBOX/sec-outside-file.txt"
echo "ORIGINAL CONTENT" > "$VICTIM_FILE"
ln -s "$VICTIM_FILE" "$S_REPO/$STATE_REL"
observe "$SID_A" "$S_TR" "$S_REPO" "victim"

# The gate refuses to READ through a planted symlink — the direction that is
# uniquely its own. A repo that can choose which file this gate reads its evidence
# out of can OPEN the wall, which §8 forbids; the write side of the same planted
# path is the writer's row, in tests/execution-recorder.test.sh §7.
run_guard "$(mk_stop_payload "$SID_A" "$S_TR" "$S_REPO" "victim")"
expect_status "a symlinked state path refuses the stop" 2 "$GUARD_ST"
expect_contains "…for the symlink reason specifically, not a fallback missing-observation one" \
  "nothing here will read or write through it" "$GUARD_VERR"

IFS='|' read -r S2_REPO S2_TR S2_SUB <<< "$(make_world sec2 yes)"
plant_agent "$S2_SUB" "avictim-ffffffffffffffff" "victim"
OUTSIDE_DIR="$SANDBOX/sec2-outside-dir"
mkdir -p "$OUTSIDE_DIR" "$S2_REPO/.bionic"
# make_world plants a real .bionic/tmp (the engagement marker lives there); it has to GO,
# or `ln -s` lands the link INSIDE it and the hostile shape under test never exists — the
# same trap tests/dispatch-preflight.test.sh records at its own directory-symlink case.
rm -rf "$S2_REPO/.bionic/tmp"
ln -s "$OUTSIDE_DIR" "$S2_REPO/.bionic/tmp"
# The engagement marker travels to the far side with everything else this case redirects
# (task-engaged-session): the gate asks `engaged_session` first and its path runs through
# the redirected directory, so without it the gate would exit at the switch and the claim
# under test — that the state path is not read THROUGH a directory symlink — would be
# proven by an exit that never reached the state path.
: > "$OUTSIDE_DIR/engaged-$SID_A.state"
observe "$SID_A" "$S2_TR" "$S2_REPO" "victim"
run_guard "$(mk_stop_payload "$SID_A" "$S2_TR" "$S2_REPO" "victim")"
expect_status "a symlinked state DIRECTORY refuses the stop too" 2 "$GUARD_ST"
expect_contains "…for the symlink reason specifically, not a fallback missing-observation one" \
  "nothing here will read or write through it" "$GUARD_VERR"

# The ROSTER is repo-controlled state too, so a symlink at its own level would let
# a repo choose which file answers a question the gate asks — the OPEN direction §8
# forbids a repo from reaching. Since S6 the roster is where the agent ID comes from,
# which is what the observation channel is keyed on, so a planted roster is a repo
# naming the log a look would be compared against. Refusing to read through the link
# leaves the id unestablished, which is the closed side: the target resolves as live
# and the stop is refused for want of the one fact only a real row could supply.
IFS='|' read -r SR_REPO SR_TR SR_SUB <<< "$(make_world secroster yes)"
SR_TR_B="${SR_TR%/*}/$SID_B.jsonl"
plant_agent "${SR_TR_B%.jsonl}/subagents" "avictim-1818181818181818" "victim"
sg_roster_row "$SANDBOX/plantedroster" "$SID_A" "victim" "avictim-1818181818181818"
mkdir -p "$SR_REPO/.bionic/tmp"
ln -s "$SANDBOX/plantedroster/.bionic/tmp/roster-$SID_A.state" \
  "$SR_REPO/.bionic/tmp/roster-$SID_A.state"
run_guard "$(mk_stop_payload "$SID_A" "$SR_TR_B" "$SR_REPO" "victim")"
expect_status "a symlinked roster refuses the stop" 2 "$GUARD_ST"
expect_contains "…because it was not read through: the id claim is never made" \
  "no agent id" "$GUARD_VERR"

# Unpredictable temp names: mktemp with an X-template, and no PID-based name.
expect_regex "temp files use an mktemp X-template" 'mktemp.*XXXXXX' "$(cat "$GUARD")"
expect_absent "no PID-based temp filename" '.tmp.$$' "$(cat "$GUARD")"

# The gate reads the working log; it must never quote it. (§8 keeps that
# disclosure in the observation, whose whole purpose is to show it to a reader.)
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"CANARY_LOG_BODY"}]}}\n' \
  >> "$S_SUB/agent-avictim-ffffffffffffffff.jsonl"
run_guard "$(mk_stop_payload "$SID_A" "$S_TR" "$S_REPO" "victim")"
expect_absent "the refusal prints no working-log contents" "CANARY_LOG_BODY" "$GUARD_ERR"

section "Section 8: D-3 — a stop is discharged only by the STOPPER'S OWN look (AC-4)"
#
# The borrowed look. D-1 makes an observation perishable, but nothing made it
# ATTRIBUTABLE: any record for the target discharged any actor's stop, so a
# subagent's look could pay for the orchestrator's stop and neither one had seen
# what the other saw. Slice 4/1 resolved assumption (A) FULL — a subagent-invoked
# payload carries top-level `agent_id`, the orchestrator's does not — so the
# comparison is one payload field against the `observer=` field the recorder
# wrote out of ITS payload. Same key, both ends.

IFS='|' read -r SA_REPO SA_TR SA_SUB <<< "$(make_world sameactor yes)"
plant_agent "$SA_SUB" "aworker-1010101010101010" "worker"
sg_roster_row "$SA_REPO" "$SID_A" "worker" "aworker-1010101010101010"
SUBAGENT="asubagent-2020202020202020"

observe_as "$SUBAGENT" "$SID_A" "$SA_TR" "$SA_REPO" "worker"

run_guard "$(mk_stop_payload "$SID_A" "$SA_TR" "$SA_REPO" "worker")"
expect_status "a subagent's look does not discharge the ORCHESTRATOR's stop" 2 "$GUARD_ST"
expect_contains "a refused same-actor stop consumes nothing" \
  "aworker-1010101010101010" "$(cat "$SA_REPO/$STATE_REL" 2>/dev/null)"

# The positive pair: the actor that looked may spend its own look.
run_guard "$(mk_stop_payload_as "$SID_A" "$SA_TR" "$SA_REPO" "worker" "$SUBAGENT")"
expect_status "the actor who looked spends its own observation" 0 "$GUARD_ST"
expect_empty "and does so in silence" "$GUARD_ERR"

# The mirror image: the orchestrator looked, a subagent tries to spend it.
IFS='|' read -r SB_REPO SB_TR SB_SUB <<< "$(make_world sameactor2 yes)"
plant_agent "$SB_SUB" "aworker-3030303030303030" "worker"
sg_roster_row "$SB_REPO" "$SID_A" "worker" "aworker-3030303030303030"
observe "$SID_A" "$SB_TR" "$SB_REPO" "worker"
run_guard "$(mk_stop_payload_as "$SID_A" "$SB_TR" "$SB_REPO" "worker" "$SUBAGENT")"
expect_status "the orchestrator's look does not discharge a SUBAGENT's stop" 2 "$GUARD_ST"
run_guard "$(mk_stop_payload "$SID_A" "$SB_TR" "$SB_REPO" "worker")"
expect_status "…and the orchestrator can still spend its own" 0 "$GUARD_ST"

# A record with no observer at all cannot prove same-actor, so it does not
# discharge anything. Fail-closed: this is the §7 stop cell, and the cost of the
# refusal is one re-observation.
IFS='|' read -r SC_REPO SC_TR SC_SUB <<< "$(make_world sameactor3 yes)"
plant_agent "$SC_SUB" "aworker-4040404040404040" "worker"
sg_roster_row "$SC_REPO" "$SID_A" "worker" "aworker-4040404040404040"
observe "$SID_A" "$SC_TR" "$SC_REPO" "worker"
sed -i.bak 's/|observer=[^|]*//' "$SC_REPO/$STATE_REL"; rm -f "$SC_REPO/$STATE_REL.bak"
run_guard "$(mk_stop_payload "$SID_A" "$SC_TR" "$SC_REPO" "worker")"
expect_status "a record carrying no observer discharges nothing" 2 "$GUARD_ST"

section "Section 9: D-6 — the contracted progress artifact is a second activity channel (AC-5)"
#
# D-1 watched ONE channel: the working log. An agent that spends 40 minutes
# inside a single tool call writes nothing to it, so "dormant since your look"
# was true of a wedged agent and a working one alike — and the work contract's
# own progress artifact, the thing that separates them, counted for nothing at
# the gate. Since slice 4/5 the observation records the progress state it saw;
# this gate compares that snapshot against the artifact as it is NOW, by exactly
# the rule the working log already follows: any activity after the look stales
# the look.

PROG_REL=".bionic/tmp/prog.txt"

IFS='|' read -r PG_REPO PG_TR PG_SUB <<< "$(make_world progress yes)"
plant_agent "$PG_SUB" "arunner-1212121212121212" "runner"
sg_roster_row "$PG_REPO" "$SID_A" "runner" "arunner-1212121212121212" "$PROG_REL"
mkdir -p "$PG_REPO/.bionic/tmp"
printf 'stage 1\n' > "$PG_REPO/$PROG_REL"

observe "$SID_A" "$PG_TR" "$PG_REPO" "runner"
PG_STATE=$(cat "$PG_REPO/$STATE_REL" 2>/dev/null)

# A stop taken with nothing having moved is permitted — the check must not refuse
# on the mere existence of a progress contract.
run_guard "$(mk_stop_payload "$SID_A" "$PG_TR" "$PG_REPO" "runner")"
expect_status "progress unchanged since the look: PERMITTED" 0 "$GUARD_ST"

observe "$SID_A" "$PG_TR" "$PG_REPO" "runner"
sleep 1
printf 'stage 2\n' >> "$PG_REPO/$PROG_REL"
run_guard "$(mk_stop_payload "$SID_A" "$PG_TR" "$PG_REPO" "runner")"
expect_status "progress written AFTER the look: REFUSED as stale" 2 "$GUARD_ST"
expect_absent "the progress refusal prints no progress CONTENTS" "stage 2" "$GUARD_ERR"
expect_contains "a stop refused on progress staleness consumes nothing" \
  "arunner-1212121212121212" "$(cat "$PG_REPO/$STATE_REL" 2>/dev/null)"

# A fresh look over the NEW state re-arms it — the loop the refusal names has an exit.
observe "$SID_A" "$PG_TR" "$PG_REPO" "runner"
run_guard "$(mk_stop_payload "$SID_A" "$PG_TR" "$PG_REPO" "runner")"
expect_status "a fresh look over the new progress state re-arms the stop" 0 "$GUARD_ST"

# The artifact APPEARING is activity too: "absent" and "present" are different
# states, and a first write may land inside the same mtime second as the look.
IFS='|' read -r PA_REPO PA_TR PA_SUB <<< "$(make_world progressappear yes)"
plant_agent "$PA_SUB" "arunner-1313131313131313" "runner"
sg_roster_row "$PA_REPO" "$SID_A" "runner" "arunner-1313131313131313" "$PROG_REL"
mkdir -p "$PA_REPO/.bionic/tmp"
observe "$SID_A" "$PA_TR" "$PA_REPO" "runner"
printf 'first write\n' > "$PA_REPO/$PROG_REL"
run_guard "$(mk_stop_payload "$SID_A" "$PA_TR" "$PA_REPO" "runner")"
expect_status "the contracted artifact appearing after the look: REFUSED" 2 "$GUARD_ST"

# NO progress contract: the whole check is inert, and the world behaves exactly
# as it did before this slice. A wall that fires where nothing was contracted
# would refuse every ordinary stop.
IFS='|' read -r PN_REPO PN_TR PN_SUB <<< "$(make_world progressnone yes)"
plant_agent "$PN_SUB" "arunner-1414141414141414" "runner"
sg_roster_row "$PN_REPO" "$SID_A" "runner" "arunner-1414141414141414"
mkdir -p "$PN_REPO/.bionic/tmp"
observe "$SID_A" "$PN_TR" "$PN_REPO" "runner"
sleep 1
printf 'unrelated\n' > "$PN_REPO/$PROG_REL"
run_guard "$(mk_stop_payload "$SID_A" "$PN_TR" "$PN_REPO" "runner")"
expect_status "no progress contract: an unrelated file's write changes nothing" 0 "$GUARD_ST"

# A CONTRACTED channel the look never opened. An artifact nobody looked at can never go
# stale, so without this clause the check above is dodgeable by simply looking wrong.
#
# HOW THE LOOK MISSES IT, since S6. It used to be an observation run with no session key at
# all — the `unknown` classification of slice 4/5, which saw no roster and so no contracted
# path. That state is gone: with no session key there is no transcript, no live set, and
# hooks/stop-check.sh refuses before it resolves anything, so a keyless look now produces no
# record rather than an incomplete one. What still produces one is ORDER: the look ran while
# the row named no progress artifact, and the contract that names one was recorded after it.
IFS='|' read -r PU_REPO PU_TR PU_SUB <<< "$(make_world progressunseen yes)"
plant_agent "$PU_SUB" "arunner-1515151515151515" "runner"
sg_roster_row "$PU_REPO" "$SID_A" "runner" "arunner-1515151515151515"
mkdir -p "$PU_REPO/.bionic/tmp"
printf 'stage 1\n' > "$PU_REPO/$PROG_REL"
observe "$SID_A" "$PU_TR" "$PU_REPO" "runner"
sg_roster_row "$PU_REPO" "$SID_A" "runner" "arunner-1515151515151515" "$PROG_REL"
run_guard "$(mk_stop_payload "$SID_A" "$PU_TR" "$PU_REPO" "runner")"
expect_status "a look that skipped the contracted channel discharges nothing" 2 "$GUARD_ST"
expect_contains "…and the refusal names the channel the look never opened" \
  "$PROG_REL" "$GUARD_VERR"
# Following the fix as printed clears the refusal — the loop has a stated exit.
observe "$SID_A" "$PU_TR" "$PU_REPO" "runner" "--progress" "$PROG_REL"
run_guard "$(mk_stop_payload "$SID_A" "$PU_TR" "$PU_REPO" "runner")"
expect_status "observing the contracted channel as instructed re-arms the stop" 0 "$GUARD_ST"

section "Section 10: AC-9 — resolution IS the live set, and the double file is not an ambiguity"
#
# WHAT THIS SECTION USED TO BE, and why it is gone. It drove the OWNING-DIRECTORY rule: an
# agent whose `agent-<id>.meta.json` sat under another session's `subagents/` was FOREIGN and
# a stop of it by name was refused. That rule answered "is this agent mine" from RECORDS on
# disk, and the records outlive the agents — which is how a `/clear` produced the field defect
# this wave exists to fix (report §B-2): the same agent's metadata filed under two session
# directories, MATCH_COUNT=2, and every spelling of a bare name refused as ambiguous while the
# agent was still running and its contract had landed.
#
# WHAT REPLACES IT (D1′/D2′). The live set: the newest recorded ListAgents answer, which is
# the harness's own statement about which teammates exist right now. An agent it names is one
# this session can address; one it does not name is not stoppable here whatever is on disk.
# Ownership by id and the contract still come from the session roster row, which is the only
# thing that ever knew them.

IFS='|' read -r LV_REPO LV_TR LV_SUB <<< "$(make_world liveset yes)"
mkdir -p "$LV_REPO/.bionic/docs/record"
LV_TR_B="${LV_TR%/*}/$SID_B.jsonl"
LV_SUB_B="${LV_TR_B%.jsonl}/subagents"

# (a) THE DOUBLE FILE, the fixture research-code-map §4.4 proved on this machine: ONE agent,
# ONE name, its meta.json BYTE-IDENTICAL in two session directories, its working log in both.
# The live set names it once, so it is one agent — and with a MET contract the stop passes
# with no observation at all (AC-9).
plant_agent "$LV_SUB" "aw1-rc-e0886335875ba2d1" "w1-rc"
cp "$LV_SUB/agent-aw1-rc-e0886335875ba2d1.meta.json" "$LV_SUB_B/agent-aw1-rc-e0886335875ba2d1.meta.json"
cp "$LV_SUB/agent-aw1-rc-e0886335875ba2d1.jsonl"     "$LV_SUB_B/agent-aw1-rc-e0886335875ba2d1.jsonl"
if cmp -s "$LV_SUB/agent-aw1-rc-e0886335875ba2d1.meta.json" \
          "$LV_SUB_B/agent-aw1-rc-e0886335875ba2d1.meta.json"; then
  ok "the double-file fixture is byte-identical in both session directories"
else
  no "the double-file fixture is byte-identical in both session directories"
fi
echo "the delivered artifact" > "$LV_REPO/.bionic/docs/record/w1-rc.md"
# `adopted_from` is what put BOTH directories in scope for the old scan — the successor
# session took the row over after a /clear — and it is what made the double file a
# MATCH_COUNT=2 ambiguity there. It stays on the row: after this slice it is read only for
# the session the working log is filed under, never for resolution.
sg_roster_row "$LV_REPO" "$SID_A" "w1-rc" "aw1-rc-e0886335875ba2d1" "" "confirmed" \
  ".bionic/docs/record/w1-rc.md" "" "" "$SID_B"
run_guard "$(mk_stop_payload "$SID_A" "$LV_TR" "$LV_REPO" "w1-rc")"
expect_status "the double-filed agent, MET, stopped by BARE NAME: PASSES with no observation" \
  0 "$GUARD_ST"
expect_empty "…and the gate is silent — no ambiguity refusal anywhere" "$GUARD_ERR"

# …and the same double file with an UNMET contract meets the ordinary ceremony, not an
# ambiguity refusal. Without this pair the pass above is equally green on a gate that has
# stopped deciding anything.
plant_agent "$LV_SUB" "aw2-rc-e0886335875ba2d2" "w2-rc"
cp "$LV_SUB/agent-aw2-rc-e0886335875ba2d2.meta.json" "$LV_SUB_B/agent-aw2-rc-e0886335875ba2d2.meta.json"
cp "$LV_SUB/agent-aw2-rc-e0886335875ba2d2.jsonl"     "$LV_SUB_B/agent-aw2-rc-e0886335875ba2d2.jsonl"
sg_roster_row "$LV_REPO" "$SID_A" "w2-rc" "aw2-rc-e0886335875ba2d2" "" "confirmed" \
  ".bionic/docs/record/w2-rc.md" "" "" "$SID_B"
run_guard "$(mk_stop_payload "$SID_A" "$LV_TR" "$LV_REPO" "w2-rc")"
expect_status "the same double file, contract UNMET: the ceremony survives — REFUSED" 2 "$GUARD_ST"
expect_contains "…and it is the observation demand, not an ambiguity" \
  "No observation" "$GUARD_VERR"
expect_absent "…nothing calls the double file ambiguous" "ambiguous" "$GUARD_ERR"

# (b) A NAME THE ANSWER DOES NOT CARRY is not live, and the refusal says so. `ghost` is on
# disk in this world's other session directory and in nobody's live set.
plant_agent "$LV_SUB_B" "aghost-9999999999999999" "ghost"
run_guard "$(mk_stop_payload "$SID_A" "$LV_TR" "$LV_REPO" "ghost@session-${SID_B:0:8}")"
expect_status "a target absent from the live set: REFUSED" 2 "$GUARD_ST"
expect_contains "…and the refusal says it is not live" "is not live" "$GUARD_VERR"
expect_absent "…and never calls it foreign — that rule is gone" "FOREIGN" "$GUARD_ERR"

# (c) TWO LIVE ENTRIES OF ONE NAME. The refusal names both, and it does NOT offer the
# `@session-` alias as a way out: an alias must resolve to the same SINGLE entry (AC-11), so
# there is no spelling of this target the gate can accept.
IFS='|' read -r TW_REPO TW_TR TW_SUB <<< "$(make_world twolaunchers yes)"
plant_agent "$TW_SUB" "atwin-1111111111111111" "twin"
plant_agent "$TW_SUB" "atwin-2222222222222222" "twin"
sg_roster_row "$TW_REPO" "$SID_A" "twin" "atwin-1111111111111111"
run_guard "$(mk_stop_payload "$SID_A" "$TW_TR" "$TW_REPO" "twin")"
expect_status "a name the live set carries twice: REFUSED" 2 "$GUARD_ST"
expect_contains "…the refusal counts them" "2 live agents answer to 'twin'" "$GUARD_VERR"
expect_regex "…and prints both entries as the harness reported them" \
  'twin\|bionic:senior-implementor\|running' "$GUARD_VERR"
run_guard "$(mk_stop_payload "$SID_A" "$TW_TR" "$TW_REPO" "twin@session-${SID_A:0:8}")"
expect_status "…and the alias spelling of an ambiguous name is refused too" 2 "$GUARD_ST"
expect_contains "…for the ambiguity, not for the alias" "2 live agents answer to 'twin'" "$GUARD_VERR"

# (c2) A NAME CARRYING A REGEX METACHARACTER must count and list ONLY its own two entries,
# never a bystander name that merely LOOKS like it under BRE matching (Step-6 security review
# S-5, third instance). `a.b`'s `.` would match any single character, so an unfixed reader
# widens both the count and the listing to include `axb` — a name nobody asked about.
IFS='|' read -r RX_REPO RX_TR RX_SUB <<< "$(make_world regexambig yes)"
plant_agent "$RX_SUB" "arxa-1111111111111111" "a.b"
plant_agent "$RX_SUB" "arxb-2222222222222222" "a.b"
plant_agent "$RX_SUB" "arxc-3333333333333333" "axb"
sg_roster_row "$RX_REPO" "$SID_A" "a.b" "arxa-1111111111111111"
run_guard "$(mk_stop_payload "$SID_A" "$RX_TR" "$RX_REPO" "a.b")"
expect_status "a name with a regex metacharacter, two live entries: REFUSED" 2 "$GUARD_ST"
expect_contains "…the refusal counts exactly the two of that exact name" \
  "2 live agents answer to 'a.b'" "$GUARD_VERR"
expect_regex "…and prints both entries as the harness reported them" \
  'a\.b\|bionic:senior-implementor\|running' "$GUARD_VERR"
expect_absent "…never widened to the bystander name the dot happens to match" \
  "axb" "$GUARD_ERR"

# (d) A LIVE AGENT THIS SESSION'S ROSTER CARRIES NO ID FOR cannot be observed — the working
# log is `<session>/subagents/agent-<id>.jsonl` and the roster row is the only thing that
# knows the id once the directory scan is gone. It is refused, and the refusal says which
# fact is missing rather than demanding a look that cannot be taken.
plant_agent "$LV_SUB" "aunrostered-8888888888888888" "unrostered"
run_guard "$(mk_stop_payload "$SID_A" "$LV_TR" "$LV_REPO" "unrostered")"
expect_status "a live agent with no confirmed id on the roster: REFUSED" 2 "$GUARD_ST"
expect_contains "…and the refusal names the missing fact" "no agent id" "$GUARD_VERR"

# …and an `intended` row is still not an ownership claim: its id is a claim about a launch
# nothing has observed. Unchanged from slice 4/9, on the channel that now carries it.
sg_roster_row "$LV_REPO" "$SID_A" "unrostered" "aunrostered-8888888888888888" "" "intended"
run_guard "$(mk_stop_payload "$SID_A" "$LV_TR" "$LV_REPO" "unrostered")"
expect_status "an INTENDED row's id establishes nothing: still REFUSED" 2 "$GUARD_ST"
expect_contains "…for the same missing fact" "no agent id" "$GUARD_VERR"

# …and the paired positive: the same row `identified` carries the id, and the ordinary
# ceremony resumes.
sg_roster_row "$LV_REPO" "$SID_A" "unrostered" "aunrostered-8888888888888888" "" "identified"
observe "$SID_A" "$LV_TR" "$LV_REPO" "unrostered"
run_guard "$(mk_stop_payload "$SID_A" "$LV_TR" "$LV_REPO" "unrostered")"
expect_status "an IDENTIFIED row's id makes the target observable: PERMITTED" 0 "$GUARD_ST"
expect_empty "…and permitted in silence" "$GUARD_ERR"

# (e) THE TRANSCRIPT-FORM ID still addresses an agent, by way of the roster row that carries
# it — this slice moved where the id comes from, it did not retire the spelling.
observe "$SID_A" "$LV_TR" "$LV_REPO" "unrostered"
run_guard "$(mk_stop_payload "$SID_A" "$LV_TR" "$LV_REPO" "aunrostered-8888888888888888")"
expect_status "the transcript-form id resolves through the roster row: PERMITTED" 0 "$GUARD_ST"

# …and an id NO row carries resolves to nothing, address-shaped, so it is refused.
run_guard "$(mk_stop_payload "$SID_A" "$LV_TR" "$LV_REPO" "anobody-0000000000000000")"
expect_status "a transcript-form id no roster row carries: REFUSED" 2 "$GUARD_ST"

# (f) `name@team` is not an address form this gate accepts — the suffix must name a session.
run_guard "$(mk_stop_payload "$SID_A" "$LV_TR" "$LV_REPO" "unrostered@team")"
expect_status "name@team is not an accepted alias: REFUSED" 2 "$GUARD_ST"
expect_contains "…and the refusal names the accepted form" "@session-" "$GUARD_VERR"

section "Section 11: FACTS DISCHARGE THE STOP (epic-16 w2 S3, AC-1/AC-2, R2)"
#
# The ceremony was never the point — the point was that a stop not destroy work
# nobody had looked at. When the contract has LANDED, the artifact on disk is a
# better answer to that question than any look, and it cannot go stale. So the
# discharge set is a fact set: the sweeper's verdict says MET against a declared
# artifact, or WAIVED, or the orchestrator has acked the row. Everything else is
# unchanged — Sections 4 through 10 above are the same arc they were, and they
# still pass, which is the paired positive for "ceremony survives".

IFS='|' read -r F_REPO F_TR F_SUB <<< "$(make_world facts yes)"
mkdir -p "$F_REPO/.bionic/docs/record"

# --- MET: the artifact is on disk, written after the launch ---
plant_agent "$F_SUB" "alander-1111111111111111" "lander"
echo "the delivered artifact" > "$F_REPO/.bionic/docs/record/lander.md"
sg_roster_row "$F_REPO" "$SID_A" "lander" "alander-1111111111111111" "" "confirmed" \
  ".bionic/docs/record/lander.md"
run_guard "$(mk_stop_payload "$SID_A" "$F_TR" "$F_REPO" "lander")"
expect_status "MET contract: the stop passes with NO observation ever taken" 0 "$GUARD_ST"
expect_empty "…and the gate says nothing at all — zero ceremony" "$GUARD_ERR"

# --- paired negative: same world, same everything, artifact absent ---
plant_agent "$F_SUB" "aslacker-2222222222222222" "slacker"
sg_roster_row "$F_REPO" "$SID_A" "slacker" "aslacker-2222222222222222" "" "confirmed" \
  ".bionic/docs/record/slacker.md"
run_guard "$(mk_stop_payload "$SID_A" "$F_TR" "$F_REPO" "slacker")"
expect_status "UNMET contract: the ceremony survives — REFUSED" 2 "$GUARD_ST"
expect_contains "…with the observation refusal, not a landing one" \
  "No observation has been recorded" "$GUARD_VERR"

# --- WAIVED: an explicit designation discharges as surely as an artifact ---
plant_agent "$F_SUB" "awaived-3333333333333333" "waived-one"
sg_roster_row "$F_REPO" "$SID_A" "waived-one" "awaived-3333333333333333" "" "confirmed" \
  "" "this dispatch produces nothing durable"
run_guard "$(mk_stop_payload "$SID_A" "$F_TR" "$F_REPO" "waived-one")"
expect_status "WAIVED contract: the stop passes with no observation" 0 "$GUARD_ST"
expect_empty "…and silently" "$GUARD_ERR"

# --- ACKED: the orchestrator's verification, made durable, closes the row ---
#
# This is the case the field kept paying for: an agent that finished, was
# verified and was acked still cost an observation, a staleness round and four
# calls to stop. The ack is invisible to `verdict` by wave-01 design (a contract
# is met by artifacts or it is not), so the gate reads the sweeper's LEDGER —
# and it reads a ledger this suite makes the real `ack` verb write.
plant_agent "$F_SUB" "aacked-4444444444444444" "acked-one"
sg_roster_row "$F_REPO" "$SID_A" "acked-one" "aacked-4444444444444444" "" "confirmed" \
  ".bionic/docs/record/never-written.md"
ack_row "$F_REPO" "$SID_A" "acked-one"
run_guard "$(mk_stop_payload "$SID_A" "$F_TR" "$F_REPO" "acked-one")"
expect_status "ACKED row: the stop passes though the contract is UNMET" 0 "$GUARD_ST"
expect_empty "…and silently" "$GUARD_ERR"

# An ack of a DIFFERENT row closes nothing here — whole-name match, never a
# substring, and never the whole roster.
plant_agent "$F_SUB" "aacked-5555555555555555" "acked-one-more"
sg_roster_row "$F_REPO" "$SID_A" "acked-one-more" "aacked-5555555555555555" "" "confirmed" \
  ".bionic/docs/record/never-written-2.md"
run_guard "$(mk_stop_payload "$SID_A" "$F_TR" "$F_REPO" "acked-one-more")"
expect_status "a neighbouring ack does not discharge this row: REFUSED" 2 "$GUARD_ST"

# --- the VACUOUS MET keeps its ceremony ---
#
# `verdict` calls a row that declared no artifact MET, correctly — it names
# nothing to hold the agent to. That is not a landing, and treating it as one
# would discharge every contract-less dispatch on a fact nobody produced. AC-1
# says MET means "artifact delivered"; ack is what closes the rest.
plant_agent "$F_SUB" "anothing-6666666666666666" "declares-nothing"
sg_roster_row "$F_REPO" "$SID_A" "declares-nothing" "anothing-6666666666666666"
run_guard "$(mk_stop_payload "$SID_A" "$F_TR" "$F_REPO" "declares-nothing")"
expect_status "a row that declared NOTHING is not discharged by its vacuous MET" 2 "$GUARD_ST"

# --- a repo-controlled ledger cannot open this gate ---
#
# The CLOSED half of the pair whose open half is at the landing gate
# (tests/landing-gate.test.sh §8f). A repo owns its own .bionic/, so a symlinked ledger is
# a set of acks nobody in this session recorded: the sweeper — the ONE reader of that file
# since S9 — refuses to answer over it at all, so no `acked=` reaches this gate, and this
# gate, which is CLOSED and loud after the active-wave verdict, refuses the stop even though
# the artifact is on disk. That last part is the point: the refusal costs a re-run, and the
# alternative was letting a repo choose which acks this session recorded. The same fixture
# passes at the landing gate,
# which is fail-open by design. Opposite directions, one fixture, both deliberate.
plant_agent "$F_SUB" "alinked-8888888888888888" "linked-ledger"
sg_roster_row "$F_REPO" "$SID_A" "linked-ledger" "alinked-8888888888888888" "" "confirmed" \
  ".bionic/docs/record/lander.md"
mkdir -p "$SANDBOX/elsewhere"
printf '# bionic sweeper ledger — schema sweeper-ledger/v1\nsweeper-ledger/v1|event=ack|at=2026-08-11T00:00:00Z|epoch=1|pid=1|session=%s|name=linked-ledger\n' \
  "$SID_A" > "$SANDBOX/elsewhere/ledger.state"
ln -sf "$SANDBOX/elsewhere/ledger.state" "$F_REPO/.bionic/tmp/sweeper-$SID_A.state"
run_guard "$(mk_stop_payload "$SID_A" "$F_TR" "$F_REPO" "linked-ledger")"
rm -f "$F_REPO/.bionic/tmp/sweeper-$SID_A.state"

# --- no roster row at all: unchanged ---
plant_agent "$F_SUB" "aunrostered-777777777777" "unrostered"
run_guard "$(mk_stop_payload "$SID_A" "$F_TR" "$F_REPO" "unrostered")"
expect_status "a target on no roster row is unchanged by any of this" 2 "$GUARD_ST"

# --- an ack for a name NO ROSTER ROW carries closes nothing here (epic-16 w2 S9) ---
#
# The one behavioural delta of S9's `acked=` promotion, pinned rather than left to be
# discovered. This gate used to open the ledger itself and match a bare name in it, so an
# ack recorded for a name the roster never carried discharged the stop. The ack now reaches
# it as a field on the verdict line for a ROW, and there is no row — so the ceremony stands.
#
# That is the ack verb's OWN semantics, which the gate had been the odd one out on: an ack
# for an unknown name is recorded with a warning and is "exempt the moment a row of that
# name appears" (session-sweeper.sh's ack verb, and tests/session-sweeper.test.sh §4). The
# landing gate has always passed such a stop for an unrelated reason (a name on no row makes
# the verb exit 0 and the gate fail open), and the stand-down never sees one, so this is the
# reading all three now share.
plant_agent "$F_SUB" "aackless-9999999999999999" "acked-but-rowless"
ack_row "$F_REPO" "$SID_A" "acked-but-rowless"
run_guard "$(mk_stop_payload "$SID_A" "$F_TR" "$F_REPO" "acked-but-rowless")"
expect_status "an ack over a name no roster row carries does not discharge the stop" 2 "$GUARD_ST"
# The paired positive is one case up: the SAME ack verb, over a name that HAS a row, passes
# the same gate silently ("ACKED row: the stop passes though the contract is UNMET").

section "Section 12: the USER-ORDERED stop executes, and reports (R3, AC-2)"
#
# A human order is not evidence and it is not a discharge of the contract: it is
# an INSTRUCTION, and the gate's job in front of one is to get out of the way and
# say what is being given up. Never a refusal — a wall that argues with the
# person it exists to serve has mistaken who it works for.

IFS='|' read -r O_REPO O_TR O_SUB <<< "$(make_world orders yes)"
mkdir -p "$O_REPO/.bionic/docs/record"
plant_agent "$O_SUB" "aordered-1111111111111111" "ordered"
sg_roster_row "$O_REPO" "$SID_A" "ordered" "aordered-1111111111111111" "" "confirmed" \
  ".bionic/docs/record/ordered.md"

# Precondition: without the order this is the ordinary live+unmet refusal.
run_guard "$(mk_stop_payload "$SID_A" "$O_TR" "$O_REPO" "ordered")"
expect_status "precondition — unmet and unordered: REFUSED" 2 "$GUARD_ST"

order_stop "$O_REPO" "$SID_A" "ordered"
run_guard "$(mk_stop_payload "$SID_A" "$O_TR" "$O_REPO" "ordered")"
expect_status "a user-ordered stop EXECUTES: permitted, no observation" 0 "$GUARD_ST"

# An order names ONE target. A stop of a different agent is not covered by it.
plant_agent "$O_SUB" "aunordered-22222222222" "unordered"
sg_roster_row "$O_REPO" "$SID_A" "unordered" "aunordered-22222222222" "" "confirmed" \
  ".bionic/docs/record/unordered.md"
run_guard "$(mk_stop_payload "$SID_A" "$O_TR" "$O_REPO" "unordered")"
expect_status "an order for another target discharges nothing here: REFUSED" 2 "$GUARD_ST"

# AN ORDER IS A LIVE INSTRUCTION, NOT A STANDING ONE. It is bounded in time on
# purpose — the one place in this gate where a clock is right, because what is
# being bounded is an instruction's currency and not evidence's freshness. An
# expired order leaves the ceremony exactly where it was.
plant_agent "$O_SUB" "astale-333333333333333" "stale-order"
sg_roster_row "$O_REPO" "$SID_A" "stale-order" "astale-333333333333333" "" "confirmed" \
  ".bionic/docs/record/stale-order.md"
order_stop "$O_REPO" "$SID_A" "stale-order" --at $(( $(date -u +%s) - 86400 ))
run_guard "$(mk_stop_payload "$SID_A" "$O_TR" "$O_REPO" "stale-order")"
expect_status "an EXPIRED order does not discharge: REFUSED" 2 "$GUARD_ST"

section "Section 13: name@session-<launcher> is an ALIAS, checked against that roster (AC-11)"
#
# The suffix is the spelling the platform's stop primitive takes for a teammate, and it is
# the one an operator can actually type (field data 2026-08-11). It is NOT a second way to
# resolve: D2′ keeps it only as an alias that must land on the same single live entry the
# bare name lands on. What the suffix is checked against is the named LAUNCHER's roster —
# `roster-<sid>*.state` carrying `|name=<base>|` — because a suffix naming a session that
# never launched anything of that name is a guess wearing an id's shape.

IFS='|' read -r AL_REPO AL_TR AL_SUB <<< "$(make_world aliasform yes)"
plant_agent "$AL_SUB" "aroamer-1111111111111111" "roamer"
# The LAUNCHER's roster — another session's file, in this repo's own state directory.
sg_roster_row "$AL_REPO" "$SID_B" "roamer" "aroamer-1111111111111111" "" "identified"
# Ours is what carries the id and the contract for the row we answer for.
sg_roster_row "$AL_REPO" "$SID_A" "roamer" "aroamer-1111111111111111" "" "identified"

# The BARE NAME resolves — that is the B-2 fix, and it is the ordinary path.
observe "$SID_A" "$AL_TR" "$AL_REPO" "roamer"
run_guard "$(mk_stop_payload "$SID_A" "$AL_TR" "$AL_REPO" "roamer")"
expect_status "the bare name of a single live entry: PERMITTED" 0 "$GUARD_ST"

# The ALIAS resolves to the same entry, and buys no relief from the ceremony.
observe "$SID_A" "$AL_TR" "$AL_REPO" "roamer"
run_guard "$(mk_stop_payload "$SID_A" "$AL_TR" "$AL_REPO" "roamer@session-${SID_B:0:8}")"
expect_status "the alias whose launcher roster carries the base name: PERMITTED" 0 "$GUARD_ST"
expect_empty "…and permitted in silence" "$GUARD_ERR"

# A suffix naming a launcher whose roster does NOT carry the name is refused — and the
# refusal prints the spellings this gate does accept, which is the one spelling
# hooks/stop-check.sh prints for a candidate and `session-poker.sh adopt` prints for an
# adopted row (cross-gate Section R).
observe "$SID_A" "$AL_TR" "$AL_REPO" "roamer"
run_guard "$(mk_stop_payload "$SID_A" "$AL_TR" "$AL_REPO" "roamer@session-deadbeef")"
expect_status "an alias naming a launcher with no such row: REFUSED" 2 "$GUARD_ST"
expect_contains "…and the refusal says the launcher's roster does not carry the name" \
  "does not carry" "$GUARD_VERR"
expect_contains "…and prints an accepted spelling" "roamer@session-${SID_B:0:8}" "$GUARD_VERR"
expect_contains "…including this session's own" "roamer@session-${SID_A:0:8}" "$GUARD_VERR"

# The refusal above did NOT spend the observation: a refused stop consumes nothing (D-2),
# so the very next well-spelled stop still has its evidence.
run_guard "$(mk_stop_payload "$SID_A" "$AL_TR" "$AL_REPO" "roamer@session-${SID_A:0:8}")"
expect_status "the alias naming THIS session, whose roster carries the name: PERMITTED" 0 "$GUARD_ST"

section "Section 14: an ADOPTED agent is stoppable BY BARE NAME (the /clear defect, B-2)"
#
# THE DEFECT, from the field (epic-20 W1, 2026-08-30; re-diagnosed for this wave as B-2).
# After a `/clear`+resume the agents a predecessor launched are still running — the same
# processes, still listed as this session's teammates by the harness — but their metadata is
# filed under the PREDECESSOR's directory, and one of them had its meta.json in two
# directories at once. Resolution walked directories, so a bare name was either unresolved
# or ambiguous, and the operator could not stop a finished, verified agent at all.
#
# With resolution taken from the live set the bare name simply works. What the roster row
# still supplies is the id and the session the working log is filed under (`adopted_from`),
# which no scan is needed to learn.

IFS='|' read -r AD_REPO AD_TR AD_SUB <<< "$(make_world adoptstop yes)"
AD_TR_B="${AD_TR%/*}/$SID_B.jsonl"
AD_SUB_B="${AD_TR_B%.jsonl}/subagents"

# The agent is filed under the PREDECESSOR ($SID_B) and named in the SUCCESSOR's live set.
plant_agent "$AD_SUB_B" "aadoptee-1111111111111111" "adoptee"
plant_live "$AD_TR" fresh "adoptee"
sg_roster_row "$AD_REPO" "$SID_A" "adoptee" "aadoptee-1111111111111111" "" "identified" "" "" \
  "adoptee@session-${SID_B:0:8}" "$SID_B"

observe "$SID_A" "$AD_TR" "$AD_REPO" "adoptee"
run_guard "$(mk_stop_payload "$SID_A" "$AD_TR" "$AD_REPO" "adoptee")"
expect_status "an observed ADOPTED agent is stoppable BY BARE NAME after a /clear" 0 "$GUARD_ST"
expect_empty "…and permitted in silence" "$GUARD_ERR"

# The address `adopt` prints for the same row resolves as well, through the recorded
# teammate address on the row itself.
observe "$SID_A" "$AD_TR" "$AD_REPO" "adoptee"
run_guard "$(mk_stop_payload "$SID_A" "$AD_TR" "$AD_REPO" "adoptee@session-${SID_B:0:8}")"
expect_status "…and so does the address adopt prints for it" 0 "$GUARD_ST"

# THE CEREMONY IS UNCHANGED: a second adopted agent, never looked at, is refused — and for
# the observation, which is the half a status assertion alone cannot tell from the defect.
plant_agent "$AD_SUB_B" "aadoptee-2222222222222222" "adoptee2"
plant_live "$AD_TR" fresh "adoptee" "adoptee2"
sg_roster_row "$AD_REPO" "$SID_A" "adoptee2" "aadoptee-2222222222222222" "" "identified" "" "" \
  "adoptee2@session-${SID_B:0:8}" "$SID_B"
run_guard "$(mk_stop_payload "$SID_A" "$AD_TR" "$AD_REPO" "adoptee2")"
expect_status "an UNOBSERVED adopted agent is still refused" 2 "$GUARD_ST"
expect_contains "…and the refusal is the observation demand, not an unresolved one" \
  "No observation" "$GUARD_VERR"

# THE DISCRIMINATOR. An agent sitting in the predecessor's directory that this session's
# live set does not name stays invisible — the scope is the harness's statement, not the
# disk, so no widening by directory can creep back in.
plant_agent "$AD_SUB_B" "astranger-4444444444444444" "stranger"
plant_live "$AD_TR" fresh "adoptee" "adoptee2"
sg_roster_row "$AD_REPO" "$SID_A" "stranger" "astranger-4444444444444444" "" "identified"
run_guard "$(mk_stop_payload "$SID_A" "$AD_TR" "$AD_REPO" "stranger@session-${SID_B:0:8}")"
expect_status "an agent on disk but absent from the live set: REFUSED" 2 "$GUARD_ST"
expect_contains "…because it is not live, whatever the disk says" "is not live" "$GUARD_VERR"

section "Section 15: the answer must be FRESH, and a refusal names the fix (AC-9, D1′)"
#
# The live set is only a statement about NOW if it was recorded this turn. A stale answer
# still prints its teammates — S4's reader says so deliberately — so this gate must branch on
# the exit STATUS and never on an empty set. What a stale or absent answer earns is a refusal
# that names the fix and prints the newest answer's age, because the model is the only thing
# that can ask the question again.

IFS='|' read -r FR_REPO FR_TR FR_SUB <<< "$(make_world freshness yes)"
plant_agent "$FR_SUB" "aworker-1111111111111111" "worker"
sg_roster_row "$FR_REPO" "$SID_A" "worker" "aworker-1111111111111111"

# FRESH — the positive this section's negatives are measured against.
observe "$SID_A" "$FR_TR" "$FR_REPO" "worker"
run_guard "$(mk_stop_payload "$SID_A" "$FR_TR" "$FR_REPO" "worker")"
expect_status "a fresh answer naming the target: PERMITTED" 0 "$GUARD_ST"

# STALE — the same world, the same answer, one more user prompt after it.
observe "$SID_A" "$FR_TR" "$FR_REPO" "worker"
plant_live "$FR_TR" stale "worker"
run_guard "$(mk_stop_payload "$SID_A" "$FR_TR" "$FR_REPO" "worker")"
expect_status "a STALE answer refuses the stop even though the target is in it" 2 "$GUARD_ST"
expect_contains "…and the refusal names the fix" "call ListAgents" "$GUARD_ERR"
expect_contains "…and says the answer is stale" "stale" "$GUARD_VERR"
expect_regex "…and prints the newest answer's age" 'age' "$GUARD_VERR"

# NONE — no ListAgents answer in the transcript at all.
: > "$FR_TR"
run_guard "$(mk_stop_payload "$SID_A" "$FR_TR" "$FR_REPO" "worker")"
expect_status "no answer at all refuses the stop" 2 "$GUARD_ST"
expect_contains "…and names the same fix" "call ListAgents" "$GUARD_ERR"
expect_contains "…reporting no answer was found" "none" "$GUARD_VERR"

# A GARBLED newest answer is `none`, never "all gone" (S4 §F): the reader recognises no
# section marker, so the gate refuses rather than reading an empty roster out of it.
plant_live "$FR_TR" fresh "worker"
# THE GARBLE IS APPLIED TO THE HEADER THE BUILDER JUST WROTE, taken back off the corpus
# rather than re-typed here (S17): a mutation arm that spells its own target is green the
# day the target changes shape, because it damages a line the fixture no longer contains.
FR_HDR="$(live_answer_block_header 1)"
sed -i.bak "s/${FR_HDR}/Tea mates (1):/; s/This session is /Thus session is /" "$FR_TR"
rm -f "$FR_TR.bak"
run_guard "$(mk_stop_payload "$SID_A" "$FR_TR" "$FR_REPO" "worker")"
expect_status "a garbled newest answer refuses the stop, it does not read as an empty set" 2 "$GUARD_ST"
expect_contains "…with the same named fix" "call ListAgents" "$GUARD_ERR"

# The paired positive, restored: the fixture is not simply broken.
plant_live "$FR_TR" fresh "worker"
run_guard "$(mk_stop_payload "$SID_A" "$FR_TR" "$FR_REPO" "worker")"
expect_status "…and with the answer restored the same stop is PERMITTED again" 0 "$GUARD_ST"

section "Section 16: an IDLE agent is exactly the one you stop (spec R2, AC-27; S16)"
#
# S16 splits the two questions the live set is asked. The DISPATCH BUDGET stops counting a
# row once its agent reads `idle` — a teammate that finished its turn and was never stopped
# is not a writer, and holding a slot for it is B-1's stuck slot in a new coat. THE STOP
# GUARD must not follow it there. It resolves on PRESENCE, and an idle agent is precisely
# the target a stop exists for: the harness still lists it because it is still addressable,
# and somebody has to close it. A guard that read the budget's rule would refuse to stop
# the very agents the budget just stopped counting, and the finished agent would be
# unstoppable AND uncounted.
#
# One positive, one control. Both drive the shipped guard end to end, by bare name.

IFS='|' read -r I_REPO I_TR I_SUB <<< "$(make_world idlestop yes)"
mkdir -p "$I_REPO/.bionic/docs/record"

plant_agent "$I_SUB" "aidle-7777777777777777" "finished-writer"
echo "the delivered artifact" > "$I_REPO/.bionic/docs/record/finished-writer.md"
sg_roster_row "$I_REPO" "$SID_A" "finished-writer" "aidle-7777777777777777" "" "confirmed" \
  ".bionic/docs/record/finished-writer.md"

# The answer now names it IDLE — plant_agent wrote it running, which is the control below.
plant_live "$I_TR" fresh "finished-writer:idle"
expect_contains "meta: the planted answer really does say idle, not running" \
  "finished-writer [8895ce]  ·  bionic:senior-implementor  ·  idle" "$(cat "$I_TR")"

run_guard "$(mk_stop_payload "$SID_A" "$I_TR" "$I_REPO" "finished-writer")"
expect_status "an IDLE agent with a MET contract is still stoppable BY BARE NAME" 0 "$GUARD_ST"
expect_empty "…and silently, exactly as the running case does" "$GUARD_ERR"

# THE CONTROL, on the same world and the same name: running instead of idle. If this
# differed, the row above would be reporting the status and not the resolution.
plant_live "$I_TR" fresh "finished-writer"
run_guard "$(mk_stop_payload "$SID_A" "$I_TR" "$I_REPO" "finished-writer")"
expect_status "…the same stop with the same name RUNNING also passes (status is not the gate)" \
  0 "$GUARD_ST"

# AND THE PAIRED NEGATIVE that keeps both of those from passing vacuously: absent from the
# newest answer is still unresolvable, idle or not. Only presence resolves.
plant_live "$I_TR" fresh "somebody-else"
run_guard "$(mk_stop_payload "$SID_A" "$I_TR" "$I_REPO" "finished-writer")"
expect_status "…while a name ABSENT from the newest answer still does not resolve: REFUSED" \
  2 "$GUARD_ST"

# An idle agent whose contract is UNMET keeps the whole ceremony. Being finished is not a
# discharge — the artifact is, or the ack is — so `idle` must not become a third one.
plant_agent "$I_SUB" "aidle-8888888888888888" "idle-slacker"
sg_roster_row "$I_REPO" "$SID_A" "idle-slacker" "aidle-8888888888888888" "" "confirmed" \
  ".bionic/docs/record/never-delivered.md"
plant_live "$I_TR" fresh "idle-slacker:idle"
run_guard "$(mk_stop_payload "$SID_A" "$I_TR" "$I_REPO" "idle-slacker")"
expect_status "an IDLE agent with an UNMET contract still meets the ceremony: REFUSED" 2 "$GUARD_ST"
expect_contains "…with the observation refusal, not a resolution one" \
  "No observation has been recorded" "$GUARD_VERR"

section "AC-E1.3/E1.5 — every refusal this gate makes is one line, in the shape"

# fails-when: a refusal reaches the user as more than one line, or in any shape but
# `bionic: <verb> refused — <fact> (<fix ≤ 40 cols>)`.
#
# WHY A SWEEP AND NOT ONE ROW PER SITE. All twenty-two of this gate's refusals go
# through one frame (`deny`), and the sweep below re-drives EVERY refusal this suite
# already sets up: `run_guard` is wrapped so that each refusing call is checked, so the
# arms are as many as the suite has refusals and no site can be migrated without one.
# The three rows the ruled table puts at exactly 100 columns (draft F-9) are among them,
# which is the reason the check is on columns and not on bytes.

SG_RE='^bionic: [a-z-]+ refused — .+ \(.{1,40}\)$'
. "${BIONIC_SCRIPTS_DIR}/payload/scripts/lib/width.sh"

SG_SEEN=0; SG_BAD_SHAPE=""; SG_BAD_LINES=""; SG_BAD_COLS=""; SG_FACTS=""
sg_check() {  # <stderr> — called for every refusing run_guard below
  local err="$1" n cols
  n="$(printf '%s\n' "$err" | wc -l | tr -d ' ')"
  cols="$(bionic_cols "$err")"
  SG_SEEN=$((SG_SEEN + 1))
  printf '%s' "$err" | /usr/bin/grep -qE "$SG_RE" || SG_BAD_SHAPE="${SG_BAD_SHAPE}[$err] "
  [ "$n" = "1" ] || SG_BAD_LINES="${SG_BAD_LINES}[$err] "
  [ "${cols:-999}" -le 100 ] || SG_BAD_COLS="${SG_BAD_COLS}[$cols: $err] "
  SG_FACTS="${SG_FACTS}${err}
"
}

# Re-drive the refusals this suite already builds worlds for, through the same driver.
sg_sweep() {  # <payload>
  run_guard "$1"
  [ "$GUARD_ST" = "2" ] && sg_check "$GUARD_ERR"
  return 0
}

sg_sweep "$(mk_stop_payload "$SID_A" "$R2_TR" "$R2_REPO" "blocked")"
sg_sweep "$(mk_stop_payload "$SID_A" "$R2_TR" "$R2_REPO" "")"
sg_sweep "$(mk_stop_payload "$SID_A" "$S_TR" "$S_REPO" "victim")"
sg_sweep "$(mk_stop_payload "$SID_A" "$TW_TR" "$TW_REPO" "twin")"
sg_sweep "$(jq -n --arg c "$R2_REPO" --arg t "$R2_TR" \
  '{cwd:$c, transcript_path:$t, hook_event_name:"PreToolUse", tool_name:"TaskStop",
    tool_input:{task_id:"blocked"}}')"

expect_eq "E1.3 the sweep drove real refusals (not counting over air)" "yes" \
  "$([ "$SG_SEEN" -ge 4 ] && echo yes || echo no)"
expect_eq "E1.3 every refusal matched the criterion's shape" "" "$SG_BAD_SHAPE"
expect_eq "E1.3 every refusal was exactly one line" "" "$SG_BAD_LINES"
expect_eq "E1.3 every refusal fitted the 100-column budget" "" "$SG_BAD_COLS"
expect_contains "E1.3 …and the facts are this gate's own, from the ruled table" \
  "bionic: stop refused — " "$SG_FACTS"

# THE TABLE'S EXACT WORDING at three sites, one per shape of reason: a missing target,
# a symlinked state path, an ambiguous name.
run_guard "$(mk_stop_payload "$SID_A" "$R2_TR" "$R2_REPO" "")"
expect_eq "E1.3 row 15 (no target) is the table's line" \
  "bionic: stop refused — this stop names no target (name the agent to stop)" "$GUARD_ERR"
run_guard "$(mk_stop_payload "$SID_A" "$S_TR" "$S_REPO" "victim")"
expect_eq "E1.3 row 18 (a symlinked state path) is the table's line" \
  "bionic: stop refused — the observation state path is a symlink (remove that symlink)" "$GUARD_ERR"
run_guard "$(mk_stop_payload "$SID_A" "$TW_TR" "$TW_REPO" "twin")"
expect_eq "E1.3 row 20 (an ambiguous name) is the table's line" \
  "bionic: stop refused — several live agents answer to that name (name the full agent id)" "$GUARD_ERR"

# AC-E1.5, the pair: the frame's twelve lines are off the user stream and on the knob.
expect_absent "E1.5 the pasteable observe command is NOT on the user stream" \
  "Fix: " "$GUARD_ERR"
expect_contains "E1.5 …and BIONIC_WALL_VERBOSE=1 puts it back" "Fix: " "$GUARD_VERR"
expect_contains "E1.5 …along with the human-order route the frame teaches" \
  "If a human ordered this stop" "$GUARD_VERR"
expect_eq "E1.5 …with the one line still first" \
  "bionic: stop refused — several live agents answer to that name (name the full agent id)" \
  "$(printf '%s\n' "$GUARD_VERR" | head -1)"

finish
