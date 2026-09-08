#!/bin/bash
# Tests for hooks/patrol-duties-gate.sh — the PATROL-DUTIES WALL (task-scale
# session task-dispatch-wall-channel-loss, T5).
#
# THE CONTRACT UNDER TEST. A Patrol tick is a turn the machine started, not the
# user, and its two standing duties — refresh the subagent panel, refresh the
# task list — are carried today by prompt text, which cannot bind. This Stop
# hook makes the TURN'S END the wall: if the last user prompt was a Patrol tick
# (structural marker: it contains `session-poker.sh tick`), the turn may not end
# until the transcript shows, AFTER that prompt, a main-thread `ListAgents` AND
# either a `TaskList` or a write naming the active plan file (the version-gated
# fallback for sessions where the task tools are absent — see
# memory/task-tools-tengu-gate).
#
# HARNESS IDIOM mirrored tests/context-spend.test.sh (deleted at 8582861, epic-18
# wave-03): PASS/FAIL counters, mktemp
# projects, resolve-roots for the hook path, real-shape Stop stdin JSON. The
# transcript fixtures replay the JSONL shapes read out of live transcripts under
# ~/.claude/projects/-Users-admin-workspace-personal-bionic/ on 2026-08-22:
#
#   a cron-fired Patrol tick  -> {"type":"user", ..., "message":{"content":"Patrol tick — ..."}}
#                                content is a STRING, isMeta true, isSidechain false
#   a tool call               -> {"type":"assistant", "isSidechain":false,
#                                 "message":{"content":[{"type":"tool_use","name":"ListAgents","input":{}}]}}
#                                main-thread entries carry NO agentId/agent_id
#   a tool result             -> {"type":"user", "message":{"content":[{"type":"tool_result",...}]}}
#
# Usage: bash tests/patrol-duties-gate.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

HOOK="${BIONIC_PATROL_DUTIES_GATE_UNDER_TEST:-${BIONIC_HOOKS_DIR}/patrol-duties-gate.sh}"

# pass/fail were pure-rename shadows of the framework's ok/no; the suite's own
# explicit TOTAL=$((TOTAL + 1)) lines (including the two inside expect_allow/
# expect_block below) are dropped too since ok/no already increment it
# (S7, AC-12). expect_allow/expect_block are suite-specific helpers (not
# owned names) rebuilt on the framework's ok/no.

command -v jq >/dev/null 2>&1 || { echo "patrol-duties-gate: jq absent — suite cannot run"; exit 1; }

PLAN_REL="task-fixture.plan.md"
PLAN_NAME="$PLAN_REL"

# THE FIXTURE SESSION. Spelled once now that two things are built from it: the payload the
# driver ships, and — since task-engaged-session — the engagement marker every fixture
# plants and the `bionic-patrol session=<sid[0:8]>` token that makes a USER row a TICK.
SID="11111111-2222-3333-4444-555555555555"
SID8="${SID:0:8}"

# ---------- fixture builders ----------

# A scratch project with a docs-root plans dir holding ONE plan file, and an
# empty transcript ready to be appended to.
#
# ENGAGED BY DEFAULT since task-engaged-session: this gate asks `engaged_session` before it
# reads a byte of the transcript, so a fixture without the marker would be silent for a
# reason that has nothing to do with the duties under test. The unengaged direction is
# driven deliberately in Group 25, on the same fixtures.
make_env() {  # -> project dir on stdout
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/.bionic/docs/plans" "$dir/.bionic/tmp"
  : > "$dir/.bionic/tmp/engaged-$SID.state"
  cat > "$dir/.bionic/docs/plans/$PLAN_REL" <<'EOF'
---
governing-skill: canonical-sdlc
---
## SDLC State

current: T5
EOF
  : > "$dir/transcript.jsonl"
  printf '%s' "$dir"
}

# A project with NO plans directory at all.
make_env_planless() {
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/.bionic/tmp"
  : > "$dir/.bionic/tmp/engaged-$SID.state"
  : > "$dir/transcript.jsonl"
  printf '%s' "$dir"
}

# One user PROMPT entry — content is a bare string, the shape a cron-fired tick
# actually has.
u_prompt() {  # <dir> <text>
  jq -nc --arg t "$2" '{type:"user",isMeta:true,isSidechain:false,userType:"external",
                        message:{role:"user",content:$t}}' >> "$1/transcript.jsonl"
}

# The tick itself, verbatim in shape: the patrol prompt leads with the marker
# `bionic-patrol session=<session-id[0:8]>` (skills/canonical-sdlc/SKILL.md §The patrol
# prompt) and the rest of the prompt follows it.
#
# RESHAPED AT task-engaged-session (T6, AC-22). It used to lead with prose and be
# recognised by the substring `session-poker.sh tick` anywhere in the row — a test the
# injected canonical-sdlc SKILL.md body passes, because that body contains the literal.
# Invoking the skill was therefore a Patrol tick as far as this gate could tell, and the
# gate refused the invoking turn for duties no tick had asked for. What identifies a tick
# is the marker the prompt was designed to carry, at the front, naming THIS session.
u_tick() {  # <dir>
  u_prompt "$1" "bionic-patrol session=$SID8 — Patrol tick for the fixture wave (bionic). Run: bash /abs/hooks/session-poker.sh tick — the poker decides per row; QUIET/DISARM = no-op. Then continue toward the goal until a wall."
}

# A tool_result carrier: a `user`-typed entry that is NOT a prompt. It must not
# reset the turn, or every tick with a single tool call in it would read as a
# fresh non-tick turn and the wall would never fire.
u_result() {  # <dir>
  jq -nc '{type:"user",isSidechain:false,
           message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_x",content:"ok"}]}}' \
    >> "$1/transcript.jsonl"
}

# One assistant entry carrying one tool_use.
a_tool() {  # <dir> <name> [file_path-or-command]
  local dir="$1" name="$2" arg="${3:-}"
  local input='{}'
  case "$name" in
    Edit|Write|NotebookEdit) input=$(jq -nc --arg p "$arg" '{file_path:$p}') ;;
    Bash)                    input=$(jq -nc --arg c "$arg" '{command:$c}') ;;
  esac
  jq -nc --arg n "$name" --argjson i "$input" \
    '{type:"assistant",isSidechain:false,
      message:{role:"assistant",content:[{type:"tool_use",id:"toolu_1",name:$n,input:$i}]}}' \
    >> "$dir/transcript.jsonl"
}

# TWO tool_uses in ONE assistant entry — a parallel batch. A line-counting read
# would see one call; occurrences are what matter (the poker's own lesson).
a_tool_batch() {  # <dir> <name1> <name2>
  jq -nc --arg a "$2" --arg b "$3" \
    '{type:"assistant",isSidechain:false,
      message:{role:"assistant",content:[{type:"tool_use",id:"toolu_1",name:$a,input:{}},
                                         {type:"tool_use",id:"toolu_2",name:$b,input:{}}]}}' \
    >> "$1/transcript.jsonl"
}

# The same tool call, but inside an agent context. A subagent's ListAgents is
# not the orchestrator's panel refresh; the poker excludes agent-context
# tool_uses for the mirror-image reason (session-poker.sh:399-406).
a_tool_sidechain() {  # <dir> <name>
  jq -nc --arg n "$2" '{type:"assistant",isSidechain:true,
      message:{role:"assistant",content:[{type:"tool_use",id:"toolu_1",name:$n,input:{}}]}}' \
    >> "$1/transcript.jsonl"
}

a_tool_agentid() {  # <dir> <name>
  jq -nc --arg n "$2" '{type:"assistant",isSidechain:false,agentId:"aworker-5fb2ff80f2de21f7",
      message:{role:"assistant",content:[{type:"tool_use",id:"toolu_1",name:$n,input:{}}]}}' \
    >> "$1/transcript.jsonl"
}

junk() { printf 'not json at all {{{\n' >> "$1/transcript.jsonl"; }

# ---------- driving the hook ----------

stdin_for() {  # <project> <transcript-path> [event] [stop_hook_active]
  jq -nc --arg t "$2" --arg c "$1" --arg e "${3:-Stop}" --argjson a "${4:-false}" --arg s "$SID" \
    '{session_id:$s,transcript_path:$t,cwd:$c,
      hook_event_name:$e,stop_hook_active:$a}'
}

# THE ENVIRONMENT AGREES WITH THE PAYLOAD, because on the machine it does (A-probe-2).
# NEW AT task-engaged-session: this gate now takes its session key from lib/session.sh,
# where the ENV value is primary and the payload a witness — so a driver that left the
# RUNNER's own CLAUDE_CODE_SESSION_ID in the environment would drive every fixture under the
# operator's real session id, find no marker under it, and pass every case in silence. The
# same mirroring hooks/stop-guard.sh's and dispatch-preflight's suites already do.
fire() {  # <project> [event] [stop_hook_active]
  HOOK_OUT=$(env CLAUDE_CODE_SESSION_ID="$SID" bash "$HOOK" <<< "$(stdin_for "$1" "$1/transcript.jsonl" "${2:-Stop}" "${3:-false}")" 2>"${PE1_ERRFILE:-/dev/null}")
  # THE USER STREAM, kept for the AC-E1.3 section at the end (slice 13). The JSON reason
  # on stdout is what every arm above reads; this is the one line a reader is shown.
  HOOK_ERR_USER=$(cat "${PE1_ERRFILE:-/dev/null}" 2>/dev/null)
  HOOK_RC=$?
}

# The raw driver takes the id OUT OF THE PAYLOAD it was handed, so a case that ships a
# deliberately odd session key still drives the gate with that key on both channels.
fire_raw() {  # <project> <stdin-json>
  local _sid; _sid=$(printf '%s' "$2" | jq -r '.session_id // ""' 2>/dev/null) || _sid=""
  HOOK_OUT=$(env CLAUDE_CODE_SESSION_ID="$_sid" bash "$HOOK" <<< "$2" 2>/dev/null); HOOK_RC=$?
}

reason_of() { printf '%s' "$HOOK_OUT" | jq -r '.reason // ""' 2>/dev/null; }
decision_of() { printf '%s' "$HOOK_OUT" | jq -r '.decision // ""' 2>/dev/null; }

expect_allow() {  # <label>
  if [ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_OUT" ]; then
    ok "$1"
  else
    no "$1" "rc=$HOOK_RC stdout=<$HOOK_OUT>"
  fi
}

# A block is the JSON decision payload on stdout, with rc 0 — the form Design
# (T5) names. Every block assertion also states what the reason must NOT say:
# a reason that lists both duties whichever one is missing tells the reader
# nothing, and is the failure this gate's whole value rests on avoiding.
expect_block() {  # <label> <must-contain> [must-not-contain]
  local d r; d=$(decision_of); r=$(reason_of)
  if [ "$HOOK_RC" -ne 0 ]; then
    no "$1" "rc=$HOOK_RC (a JSON block exits 0); stdout=<$HOOK_OUT>"; return
  fi
  if [ "$d" != "block" ]; then
    no "$1" "decision=<$d> expected block; stdout=<$HOOK_OUT>"; return
  fi
  case "$r" in
    *"$2"*) ;;
    *) no "$1" "reason does not name <$2>: $r"; return ;;
  esac
  if [ -n "${3:-}" ]; then
    case "$r" in
      *"$3"*) no "$1" "reason wrongly names <$3>: $r"; return ;;
    esac
  fi
  ok "$1"
}

LA_MISSING="ListAgents"
TL_MISSING="TaskList or a plan-ledger write"

section "Section 1: the six contract cases (Design T5)"

# 1: tick + both duties -> allow.
d=$(make_env); u_tick "$d"; a_tool "$d" ListAgents; a_tool "$d" TaskList
fire "$d"; expect_allow "1: tick + ListAgents + TaskList passes"

# 2: tick + panel refresh only -> block naming the task-list side AND its
# fallback, and NOT naming ListAgents (which was done).
d=$(make_env); u_tick "$d"; a_tool "$d" ListAgents
fire "$d"; expect_block "2: tick + ListAgents only blocks, naming TaskList or a plan-ledger write" \
  "$TL_MISSING" "$LA_MISSING"

# 3: tick + task-list refresh only -> block naming ListAgents, and NOT naming
# TaskList (which was done).
d=$(make_env); u_tick "$d"; a_tool "$d" TaskList
fire "$d"; expect_block "3: tick + TaskList only blocks, naming ListAgents" \
  "$LA_MISSING" "TaskList"

# 4: the version-gated fallback — a write naming the active plan file stands in
# for TaskList, because in a session without the task tools the plan ledger IS
# the task list (memory/task-tools-tengu-gate).
d=$(make_env); u_tick "$d"; a_tool "$d" ListAgents; a_tool "$d" Edit "$d/.bionic/docs/plans/$PLAN_REL"
fire "$d"; expect_allow "4: tick + ListAgents + an Edit naming the plan passes"

# 5: a turn the user started is not a Patrol tick — the wall is silent on it,
# whatever it did or did not do.
d=$(make_env); u_prompt "$d" "run the suite and tell me what broke"
fire "$d"; expect_allow "5: a non-tick turn with neither duty passes"

# 6: blocks ONCE. The harness re-enters the stop with stop_hook_active true;
# refusing again wedges the turn with no way out.
d=$(make_env); u_tick "$d"
fire "$d" Stop true; expect_allow "6: stop_hook_active true passes the same incomplete tick"

section "Section 2: discrimination — what counts, and when"

# 7: neither duty -> the reason names BOTH.
d=$(make_env); u_tick "$d"
fire "$d"; expect_block "7a: tick + neither blocks, naming ListAgents" "$LA_MISSING"
fire "$d"; expect_block "7b: the same block also names TaskList or a plan-ledger write" "$TL_MISSING"

# 8: ORDERING. Both duties performed BEFORE the tick arrived satisfy nothing —
# the panel and the task list are stale by exactly the interval the tick exists
# to cover. Without this the wall passes every tick in any session that ever
# called ListAgents once.
d=$(make_env); a_tool "$d" ListAgents; a_tool "$d" TaskList; u_tick "$d"
fire "$d"; expect_block "8a: duties performed BEFORE the tick do not count (ListAgents)" "$LA_MISSING"
fire "$d"; expect_block "8b: duties performed BEFORE the tick do not count (task list)" "$TL_MISSING"

# 9/10: the fallback's other two shapes.
d=$(make_env); u_tick "$d"; a_tool "$d" ListAgents; a_tool "$d" Write "$d/.bionic/docs/plans/$PLAN_REL"
fire "$d"; expect_allow "9: a Write naming the plan satisfies the task-list duty"

d=$(make_env); u_tick "$d"; a_tool "$d" ListAgents
a_tool "$d" Bash "printf '%s\\n' 'row' >> .bionic/docs/plans/$PLAN_NAME"
fire "$d"; expect_allow "10: a Bash command naming the plan satisfies the task-list duty"

# 11: a write to something else is not a ledger write.
d=$(make_env); u_tick "$d"; a_tool "$d" ListAgents; a_tool "$d" Edit "$d/notes.md"
fire "$d"; expect_block "11: an Edit naming a different file does not satisfy it" "$TL_MISSING" "$LA_MISSING"

# 12/13: agent-context calls are not the orchestrator's. A subagent that ran
# ListAgents did not refresh the orchestrator's panel.
d=$(make_env); u_tick "$d"; a_tool_sidechain "$d" ListAgents; a_tool "$d" TaskList
fire "$d"; expect_block "12: a sidechain ListAgents does not count" "$LA_MISSING" "TaskList"

d=$(make_env); u_tick "$d"; a_tool_agentid "$d" ListAgents; a_tool "$d" TaskList
fire "$d"; expect_block "13: a ListAgents carrying an agentId does not count" "$LA_MISSING" "TaskList"

# 14: a tool_result carrier is not a prompt. The turn's boundary is the last
# PROMPT; if results reset it, a tick whose duties are separated by any tool
# result reads as a fresh non-tick turn and the wall goes permanently silent.
d=$(make_env); u_tick "$d"; a_tool "$d" ListAgents; u_result "$d"; a_tool "$d" TaskList
fire "$d"; expect_allow "14: tool_result entries do not end the tick's turn"

# 14b: a tool_result carrier must not reset internal duty/tick bookkeeping either
# -- same fixture family as 14, but only ONE duty is done, so a wrongful reset
# (tick lost -> quiet/allow) is DISCRIMINABLE from the correct outcome (block,
# naming the missing duty), unlike 14 where both outcomes coincide at allow.
d=$(make_env); u_tick "$d"; a_tool "$d" ListAgents; u_result "$d"
fire "$d"; expect_block "14b: a tool_result carrier does not clear an already-done duty" "$TL_MISSING" "$LA_MISSING"

# 15: a batch — two tool_uses in one assistant entry.
d=$(make_env); u_tick "$d"; a_tool_batch "$d" ListAgents TaskList
fire "$d"; expect_allow "15: both duties in ONE assistant entry pass"

# 16: a later user prompt ends the tick's turn. The duties belong to the tick,
# and a turn the user started is judged by case 5's rule.
d=$(make_env); u_tick "$d"; u_prompt "$d" "actually, do this instead"
fire "$d"; expect_allow "16: a user prompt after the tick ends the tick's turn"

section "Section 3: fail directions — silence on every ambiguity"

# 17: SubagentStop is not this gate's event. A subagent has no Patrol duties.
d=$(make_env); u_tick "$d"
fire "$d" SubagentStop; expect_allow "17: a SubagentStop payload passes"

# 18/19: nothing to read -> nothing to say.
d=$(make_env); u_tick "$d"
fire_raw "$d" "$(stdin_for "$d" "$d/nonexistent.jsonl")"

d=$(make_env); u_tick "$d"
fire_raw "$d" "$(jq -nc --arg c "$d" '{session_id:"s",cwd:$c,hook_event_name:"Stop",stop_hook_active:false}')"

# 20: malformed lines are skipped, not fatal.
d=$(make_env); u_tick "$d"; junk "$d"; a_tool "$d" ListAgents; junk "$d"; a_tool "$d" TaskList
fire "$d"; expect_allow "20: malformed transcript lines do not break the read"

# 21/22: NO PLAN, BUT A TICK IS STILL A TICK (task-engaged-session, AC-23). What scopes
# this gate is ENGAGEMENT, not the plan: bionic 1.4.0 scoped it by `active_run`, and that
# walled every session in a repo that merely held an open plan while leaving an engaged
# session at Step 0 — whose plan does not exist yet — unpoliced. Both duties are owed to
# the TICK, and a tick fires as soon as the Patrol is armed, which is at engagement. So a
# plan-less project with an engaged session and a skipped duty is refused; what the missing
# plan costs is only the ALTERNATIVE way to discharge the task-list duty (a write to the
# plan file), which is why the refusal below names the task list and not the panel.
d=$(make_env_planless); u_tick "$d"; a_tool "$d" ListAgents; a_tool "$d" Edit "$d/notes.md"
fire "$d"; expect_block "21: an engaged session with no plan still owes the tick its duties" "$TL_MISSING" "$LA_MISSING"

# 21b: THE SAME transcript, the SAME plan-less project, the marker removed. A bystander
# session is not policed at all — the pairing that makes 21 a statement about engagement
# rather than about the transcript.
rm -f "$d/.bionic/tmp/engaged-$SID.state"
fire "$d"; expect_allow "21b: …and with no engagement marker it is silent"

# THE PAIRED POSITIVE, and it is what keeps 21 from passing vacuously: the SAME
# transcript, in a project that does have an open run, refuses. Nothing separates the
# two but the plan file.
d=$(make_env); u_tick "$d"; a_tool "$d" ListAgents; a_tool "$d" Edit "$d/notes.md"
fire "$d"; expect_block "22: …and with a plan, that same unrelated Edit satisfies nothing" "$TL_MISSING" "$LA_MISSING"

# 22b: the plan's basename must never be an EMPTY needle — an empty one would make
# every write in the turn discharge the task-list duty. Driven by an Edit whose path
# shares no component with the plan's name.
d=$(make_env); u_tick "$d"; a_tool "$d" ListAgents; a_tool "$d" Edit "$d/unrelated-file.txt"
fire "$d"; expect_block "22b: an Edit that does not name the plan leaves the task-list duty owed" "$TL_MISSING" "$LA_MISSING"

# 23: THE GATE WRITES NOTHING. It is a gate, and gates only read (TDD §3.2).
d=$(make_env); u_tick "$d"
_before=$(find "$d" -type f | sort | cksum)
fire "$d"
_after=$(find "$d" -type f | sort | cksum)
if [ "$_before" = "$_after" ]; then
  ok "23: the gate creates and removes no file in the project"
else
  no "23: the gate touched the project tree" "$_before -> $_after"
fi

# 25: THE GATE IS REGISTERED ON THE STOP CHANNEL. A hook with a suite, a run line
# and no registration is the exact shape the landing sweep spent a wave being:
# installed, syntactically fine, green in its own suite, and never fired.
# A hook with a suite, a run line and no registration is installed, green in its own
# suite, and never fired. THE CHANNEL MOVED (bionic 1.4.0, slice ADOPT, spec AC-7): this
# gate was registered in the governing skill's frontmatter so it would be live exactly
# while that skill was, and that coupling is the defect — a `/clear`, a compaction or a
# session the skill was never invoked in left the wall installed and not running, while
# the duty it binds went on existing. Both halves are asserted, because either alone is a
# wall in the wrong place: a lingering frontmatter entry fires it twice per turn (the CLI
# does not deduplicate across the two manifests), and a missing manifest entry not at all.
if grep -q '\${CLAUDE_PLUGIN_ROOT}/hooks/patrol-duties-gate\.sh' \
     "${BIONIC_HOOKS_DIR}/hooks.json"; then
  ok "25: hooks/hooks.json registers the gate on the Stop channel, always on"
else
  no "25: the gate is not registered in hooks/hooks.json — it would never fire"
fi
if grep -q '\${CLAUDE_PLUGIN_ROOT}/hooks/patrol-duties-gate\.sh' \
     "${BIONIC_SKILLS_DIR}/canonical-sdlc/SKILL.md"; then
  no "25b: SKILL.md still registers the gate — a second registration fires it twice per turn"
else
  ok "25b: …and SKILL.md's frontmatter does not, so it fires exactly once"
fi

# 26/26b: THE HEADER'S OWN HONESTY ABOUT ITS BACKSTOP. This file used to cite the
# hooks reference — "Claude Code overrides the hook and ends the turn after 8
# consecutive blocks" — as the net under both of its accepted limits. It cannot
# be: `stop_hook_active` guarantees exactly one block per turn and the re-entry
# always passes, so the blocks are never consecutive and that override can never
# engage here. hooks/patrol-revive.sh carried the identical claim and lost it at
# S10 (critic C-2); this is the same correction on the other hook that makes it,
# pinned the same way — as a PAIR, so the absence rests on an extractor proven to
# find text in this very file.
if grep -q 'never consecutive' "$HOOK"; then
  ok "26: the header states why the CLI's consecutive-block override cannot engage here"
else
  no "26: the header does not say why the consecutive-block override cannot engage"
fi
if grep -q 'Backstop above ours, from the same reference' "$HOOK"; then
  no "26b: the header still claims a backstop that cannot fire for this hook"
else
  ok "26b: …and no longer claims that backstop as its own"
fi

section "Section 4: the resume/clear ritual arm (bionic 1.4.0, AC-3)"
#
# A /clear rewrites the session id in place but does NOT kill a predecessor's cron
# job (A-probe-4: it survives and keeps firing into the new conversation). The
# probe's own new transcript begins with the literal `<command-name>/clear</command-name>`
# turn (record/wave-1.4.0-probe.md); a resume is announced the same way this gate's
# SessionStart sibling (hooks/session-start.sh) prints it: the literal substring
# `source: resume` inside its title line. Either marker means a CronCreate that is
# not preceded by a CronList SINCE that marker would leave two clocks on one
# project — the wall refuses once, naming the resume ritual.

# A user-role entry shaped exactly like the probe's own new-transcript first turn.
u_clear_marker() { u_prompt "$1" "<command-name>/clear</command-name>"; }

# The marker is type-agnostic by design (a SessionStart report is not a user
# prompt), so this is driven as a "system"-typed entry — proving the scan reads
# raw transcript text, not one JSON shape.
u_resume_marker() {
  jq -nc '{type:"system",isSidechain:false,
           message:{content:"bionic session-start (source: resume) — state the previous conversation left on this project."}}' \
    >> "$1/transcript.jsonl"
}

RITUAL_CRONLIST="CronList"
RITUAL_JOB="bionic-patrol session="
RITUAL_CRONCREATE="CronCreate"
RITUAL_ARM="session-poker.sh arm"
RITUAL_ADOPT="adopt"

# 27: a clear marker, then a CronCreate with no CronList since it -> block, naming
# every step of the ritual.
d=$(make_env); u_clear_marker "$d"; a_tool "$d" CronCreate
fire "$d"
expect_block "27: CronCreate with no prior CronList after a clear marker blocks" "$RITUAL_CRONLIST"
r=$(reason_of)
case "$r" in
  *"$RITUAL_CRONLIST"*"$RITUAL_JOB"*"$RITUAL_CRONCREATE"*"$RITUAL_ARM"*"$RITUAL_ADOPT"*)
    ok "28: the reason states the ritual in order — CronList, delete the stray job, CronCreate, arm, adopt" ;;
  *) no "28: the reason does not state the ritual in order" "$r" ;;
esac

# 29: the same marker, but CronList precedes the CronCreate -> passes.
d=$(make_env); u_clear_marker "$d"; a_tool "$d" CronList; a_tool "$d" CronCreate
fire "$d"; expect_allow "29: CronList before CronCreate after a clear marker passes"

# 30: no marker at all -> the arm is inert, whatever the Cron calls did.
d=$(make_env); a_tool "$d" CronCreate
fire "$d"; expect_allow "30: no marker in the transcript — the arm is inert"

# 31: the resume spelling blocks the same way.
d=$(make_env); u_resume_marker "$d"; a_tool "$d" CronCreate
fire "$d"; expect_block "31: a resume marker with no prior CronList blocks" "$RITUAL_CRONLIST"

# 32: BLOCKS ONCE. The re-entry with stop_hook_active true always passes, exactly
# the mechanism the tick-duties arm already uses — nothing new to enforce it.
d=$(make_env); u_clear_marker "$d"; a_tool "$d" CronCreate
fire "$d" Stop true
expect_allow "32: stop_hook_active true passes the same unresolved ritual — the refusal fires only once"

# 33: ORDERING. A CronCreate that happened BEFORE the marker is not "since" it —
# only a later marker starts the window this rule judges.
d=$(make_env); a_tool "$d" CronCreate; u_clear_marker "$d"
fire "$d"; expect_allow "33: a CronCreate before the marker does not count against it"

# 34: a CronList satisfies the ritual with nothing else following it.
d=$(make_env); u_clear_marker "$d"; a_tool "$d" CronList
fire "$d"; expect_allow "34: a marker followed only by CronList passes — nothing to cure"

# 35: agent-context calls are not the orchestrator's ritual, same exclusion as the
# tick-duties arm's ListAgents/TaskList reads.
d=$(make_env); u_clear_marker "$d"; a_tool_sidechain "$d" CronCreate
fire "$d"; expect_allow "35: a sidechain CronCreate does not count against the ritual"

section "Section 5: the third duty — a printed FILL is answered (AC-29)"

# THE CONTRACT. `session-poker.sh tick` can compute the gap between the plan's budget and
# the roster and name the slices that are ready, but it cannot dispatch — and a
# recommendation nobody is obliged to answer is how this repo's own 1.4.0 wave ran six
# writers against a budget of twenty-two. The turn's END is the only moment at which "the
# FILL went unanswered" is a fact, so it is the moment this gate asks.
#
# ANSWERED = an `Agent` tool_use naming the slice, or an explicit `fill-declined: <reason>`
# anywhere in the turn. The decline is the point, not a loophole: there are good reasons not
# to fill and every one is worth one line in the record. What is refused is SILENCE.
#
# The FILL line reaches the transcript as the CONTENT of the tick's Bash tool result — a
# `user`-typed entry that is deliberately NOT a prompt — so these fixtures carry it the way
# a live transcript does.

# A tool_result carrying the tick's output.
u_tick_out() {  # <dir> <text>
  jq -nc --arg t "$2" \
    '{type:"user",isSidechain:false,
      message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_x",content:$t}]}}' \
    >> "$1/transcript.jsonl"
}

# One Agent dispatch, shaped as the harness sends it: the slice id may land in the name, the
# description or the prompt, and this gate reads all of them.
a_agent() {  # <dir> <name> [prompt]
  jq -nc --arg n "$2" --arg p "${3:-}" \
    '{type:"assistant",isSidechain:false,
      message:{role:"assistant",content:[{type:"tool_use",id:"toolu_9",name:"Agent",
        input:{name:$n,prompt:$p,subagent_type:"implementor"}}]}}' \
    >> "$1/transcript.jsonl"
}

a_agent_sidechain() {  # <dir> <name>
  jq -nc --arg n "$2" \
    '{type:"assistant",isSidechain:true,
      message:{role:"assistant",content:[{type:"tool_use",id:"toolu_9",name:"Agent",
        input:{name:$n,prompt:"x",subagent_type:"implementor"}}]}}' \
    >> "$1/transcript.jsonl"
}

# The orchestrator's own words, which is one of the places a decline may be written.
a_text() {  # <dir> <text>
  jq -nc --arg t "$2" \
    '{type:"assistant",isSidechain:false,
      message:{role:"assistant",content:[{type:"text",text:$t}]}}' \
    >> "$1/transcript.jsonl"
}

both_duties() {  # <dir> — the two standing duties, so §5 measures the THIRD one alone
  a_tool "$1" ListAgents; a_tool "$1" TaskList
}

FILL_MARK="fill unanswered"

# 36: every named slice dispatched -> allow.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL ALPHA BETA"
a_agent "$d" "W-ALPHA" "Slice ALPHA, senior-implementor."
a_agent "$d" "W-BETA" "Slice BETA, implementor."
fire "$d"; expect_allow "36: a FILL whose every slice was dispatched passes"

# 37: one of two dispatched -> block, naming the one that was not, and NOT the one that was.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL ALPHA BETA"
a_agent "$d" "W-ALPHA" "Slice ALPHA, senior-implementor."
fire "$d"; expect_block "37: a half-answered FILL blocks, naming the slice left out" "BETA" "ALPHA"

# 38: neither dispatched nor declined -> block, naming both.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL ALPHA BETA"
fire "$d"; expect_block "38a: an unanswered FILL blocks, naming the first slice" "ALPHA"
fire "$d"; expect_block "38b: …and the second" "BETA"
fire "$d"; expect_block "38c: …and says what would answer it" "fill-declined"

# 39: the DECLINE answers it. Not a loophole — a reason in the record is the point.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL ALPHA BETA"
a_text "$d" "fill-declined: ADOPT has not merged, so neither slice can base off the wave head."
fire "$d"; expect_allow "39: an explicit fill-declined line answers the FILL"

# 40: the decline may be written anywhere the orchestrator writes — including a plan-ledger
# line, which is where a run without the task tools keeps its record.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL ALPHA"
a_tool "$d" Bash "printf '%s\\n' 'fill-declined: peers not idle (D1)' >> .bionic/docs/plans/$PLAN_NAME"
fire "$d"; expect_allow "40: a decline written into the plan ledger answers it too"

# 41: INERT with no FILL line. Every turn in every project whose tick prints none — which is
# every project with no budget in its plan — must pass exactly as it did before.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: QUIET — 0 open row(s)"
fire "$d"; expect_allow "41: a tick that printed no FILL is not asked about one"

# 42: ORDERING. A FILL printed in an EARLIER turn is not this turn's to answer — the fold
# resets at every user prompt, exactly as the duties fold does.
d=$(make_env); u_tick "$d"; u_tick_out "$d" "poker: FILL ALPHA"; u_tick "$d"; both_duties "$d"
fire "$d"; expect_allow "42: a FILL from a previous turn does not bind this one"

# 43: an agent-context dispatch is not the orchestrator's. A subagent that dispatched
# does not discharge the orchestrator's fill — the same exclusion every other arm makes.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL ALPHA"
a_agent_sidechain "$d" "W-ALPHA"
fire "$d"; expect_block "43: a sidechain Agent does not answer the orchestrator's FILL" "ALPHA"

# 44: WORD BOUNDARY. A dispatch that merely CONTAINS the id inside a longer word has not
# named it — the difference between matching `ONE` and matching `PHONE`.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL ONE"
a_agent "$d" "W-PHONE" "Slice PHONEBOOK, implementor."
fire "$d"; expect_block "44: an id inside a longer word does not answer the FILL" "ONE"

# 45: BLOCKS ONCE, through the existing stop_hook_active valve — no new bookkeeping.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL ALPHA"
fire "$d" Stop true
expect_allow "45: stop_hook_active true passes the same unanswered FILL"

# 46: BOTH FAILURES AT ONCE are told at once. Blocking on the standing duty and staying
# silent about the FILL would hide the second behind the one-shot: the next stop passes by
# design, so a duty not named in the first refusal is a duty never named at all.
d=$(make_env); u_tick "$d"; a_tool "$d" ListAgents; u_tick_out "$d" "poker: FILL ALPHA"
fire "$d"; expect_block "46a: a turn missing a standing duty AND a fill names the duty" "$TL_MISSING"
fire "$d"; expect_block "46b: …and names the unanswered slice in the same refusal" "ALPHA"

# 47: a non-tick turn is never asked, whatever its transcript contains.
d=$(make_env); u_prompt "$d" "run the suite and tell me what broke"
u_tick_out "$d" "poker: FILL ALPHA"
fire "$d"; expect_allow "47: a turn the user started is not asked about a FILL"


section "Section 6: marker scope — a file the agent merely READ is not a decline (review F2)"
#
# THE DEFECT. `fill-declined:` and the two clear/resume markers were read as a raw-text
# substring of EVERY transcript record, tool results included. A tool result is how the
# content of any file the agent reads enters the transcript, so a README, a fixture or a
# code comment carrying the literal `fill-declined:` discharged the AC-29 fill duty that
# nobody had declined — fail-open on the exact wall AC-29 exists to be. The mirror case is
# friction rather than compromise: a file carrying the /clear or resume marker forced a
# spurious resume-ritual refusal.
#
# THE SCOPE. These two markers are now read only off rows the ORCHESTRATOR authored: a
# main-thread assistant record (its text and its tool_use inputs alike), a user record
# whose content is a STRING — the CLI's own command records and the operator's own typing
# — and any other record type, which is how a SessionStart report reaches the transcript.
# Never the `tool_result` elements of a user record. STOPGATES/1's type-agnostic substring
# read is kept WITHIN a qualifying row; what changed is which rows qualify. The `poker:
# FILL` line itself is deliberately NOT scoped — it arrives as the content of the tick's
# own Bash tool result, and a planted one costs a false BLOCK, the safe direction.

# An assistant text row inside an agent context — a subagent's words, not the
# orchestrator's.
a_text_sidechain() {  # <dir> <text>
  jq -nc --arg t "$2" \
    '{type:"assistant",isSidechain:true,
      message:{role:"assistant",content:[{type:"text",text:$t}]}}' \
    >> "$1/transcript.jsonl"
}

# 48/49: THE PAIR. The same literal decline text, once as file content the agent read and
# once as the orchestrator's own writing. Only the second answers.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL ALPHA"
u_tick_out "$d" "README.md:4  Write a \"fill-declined: <reason>\" line when you decline a fill."
fire "$d"; expect_block "48: a fill-declined: inside a tool result does not answer the FILL" "ALPHA"

d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL ALPHA"
a_text "$d" "fill-declined: peers not idle (D1)."
fire "$d"; expect_allow "49: …and the same words in the orchestrator's own assistant row do"

# 50/51: THE PAIR, ritual side. The /clear marker as file content the agent read is inert;
# the CLI's own /clear record still arms the ritual.
d=$(make_env)
u_tick_out "$d" "record/wave-1.4.0-probe.md:12  the new transcript opens with <command-name>/clear</command-name> verbatim."
a_tool "$d" CronCreate
fire "$d"; expect_allow "50: a /clear marker inside a tool result does not arm the ritual"

d=$(make_env); u_clear_marker "$d"; a_tool "$d" CronCreate
fire "$d"; expect_block "51: …and the CLI's own /clear record still does" "$RITUAL_CRONLIST"

# 52/53: the resume spelling, same pair. The system-typed record of §31 still arms it
# (STOPGATES/1's type-agnostic read is untouched); the same words read out of a file do not.
d=$(make_env)
u_tick_out "$d" "hooks/session-start.sh:41  prints (source: resume) into its own title line."
a_tool "$d" CronCreate
fire "$d"; expect_allow "52: a resume marker inside a tool result does not arm the ritual"

d=$(make_env); u_resume_marker "$d"; a_tool "$d" CronCreate
fire "$d"; expect_block "53: …and a system-typed session-start report still does" "$RITUAL_CRONLIST"

# 54: a SUBAGENT's decline is not the orchestrator's — the same agent-context exclusion
# every other arm of this gate makes, now applied to the decline it never applied to.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL ALPHA"
a_text_sidechain "$d" "fill-declined: the subagent decided not to."
fire "$d"; expect_block "54: a sidechain assistant's decline does not answer the orchestrator's FILL" "ALPHA"

# 55: THE FILL LINE ITSELF STAYS RAW. It reaches the transcript as the content of the
# tick's own Bash tool result and nothing else carries it — scoping it the way the decline
# is scoped would make the third duty unreachable. §36-§47 all rest on this; asserted here
# so the F2 scoping cannot be widened onto it by a later edit without a red test.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL ALPHA BETA"
a_agent "$d" "W-ALPHA" "Slice ALPHA, implementor."
fire "$d"; expect_block "55: the FILL line is still read out of the tick's tool result" "BETA" "ALPHA"

section "Section 7: a dot in a slice id is a dot, not a wildcard (review correctness F1)"
#
# THE DEFECT. The word-boundary test splices the slice id into a DYNAMIC awk regex:
#   agents ~ ("(^|[^A-Za-z0-9_.-])" id "([^A-Za-z0-9_.-]|$)")
# The validity filter one line above admits `.` as a legal slice-id character, and in a
# regex `.` is not a dot — it matches any single character. So a FILL naming `a.b` was
# answered by a dispatch that named `axb` and never named `a.b` at all. That is a FALSE
# NEGATIVE on FILL_MISSING, which passes a turn this wall exists to refuse: the fail-open
# direction. Latent in this wave — every id it dispatched is letters, digits and hyphens —
# and reachable the moment anyone names a slice `4.2`, which the filter says is legal.
#
# `.` is the ONE extended-regex metacharacter reachable through `[A-Za-z0-9_.-]`: `-` is
# special only inside a bracket expression and is spliced outside one here, and `_` is
# never special. So the pair below is the whole class.

# 56: THE BUG'S OWN SHAPE. `a.b` against a dispatch naming `axb` — same length, differing
# only where the dot is. Answered under a wildcard read; unanswered under a literal one.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL a.b"
a_agent "$d" "W-AXB" "Slice axb, implementor."
fire "$d"; expect_block "56: a dispatch naming axb does not answer a FILL for a.b" "a.b"

# 57: THE PAIRED POSITIVE, which is what keeps 56 from passing by over-escaping: the same
# id, named literally, still answers.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL a.b"
a_agent "$d" "W-AB" "Slice a.b, implementor."
fire "$d"; expect_allow "57: …and a dispatch naming a.b does answer it"

# 58: the word boundary still holds around a dotted id — `a.b` is not found inside
# `xa.by`, exactly as §44's `ONE` is not found inside `PHONE`.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL a.b"
a_agent "$d" "W-XABY" "Slice xa.by, implementor."
fire "$d"; expect_block "58: a dotted id inside a longer word does not answer the FILL" "a.b"

# 59: a hyphen in an id is a literal too, and the id is echoed back verbatim in the reason.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL W-FIX.GATE"
fire "$d"; expect_block "59: an unanswered id carrying both a dot and a hyphen is named verbatim" "W-FIX.GATE"

section "Section 8: the scan is windowed (review performance, finding 1)"
#
# THE DEFECT. This gate read the WHOLE transcript through one jq pass on every Stop of an
# open run — from byte zero, ~85 ms of CPU per MB, measured 4.3 s over the 50 MB a long
# wave session reaches, and rising monotonically for the life of the run: worst exactly
# when the run is oldest and busiest. hooks/context-spend.sh, in this same wave, already
# bounds the same class of read with `tail -n 400`.
#
# THE WINDOW. Every fact this scan needs is a "since the most recent X" fact — the last
# user prompt, the last clear/resume marker, the last FILL line — so a window suffices
# provided it holds a whole orchestrator turn. It does: the largest single turn in this
# repo's own two busiest wave transcripts is 264 records (measured 2026-09-03 over
# 494cf1b6 and b1a850c1), and the window is 2000.
#
# WHAT SCROLLING OUT COSTS, pinned here rather than left to be discovered: a marker older
# than the window reads as NO MARKER, so the ritual arm goes INERT — it does not refuse.
# That is FAIL-OPEN, and it is the right direction for a marker whose whole purpose is to
# catch the FIRST stop after a resume; by the time 2000 records have gone by the ritual is
# either long done or long moot.

# N benign padding records — a main-thread Read, which satisfies no duty, answers no FILL
# and names no plan. Written by awk rather than a shell loop: these fixtures are 20k lines.
pad() {  # <dir> <n>
  local line
  line=$(jq -nc '{type:"assistant",isSidechain:false,
                  message:{role:"assistant",content:[{type:"tool_use",id:"toolu_p",name:"Read",
                    input:{file_path:"/tmp/pad.txt"}}]}}')
  awk -v n="$2" -v l="$line" 'BEGIN{ for (i = 0; i < n; i++) print l }' >> "$1/transcript.jsonl"
}

# 60: 20k records of history BEFORE the marker change nothing — the marker and the
# CronCreate are both inside the window, and the refusal fires exactly as in §27.
d=$(make_env); pad "$d" 20000; u_clear_marker "$d"; a_tool "$d" CronCreate
fire "$d"; expect_block "60: a marker inside the window is still found under 20k records of history" "$RITUAL_CRONLIST"

# 61: THE DOCUMENTED LIMIT. The same marker with 20k records AFTER it has scrolled out of
# the window, and the arm reads "no marker" — inert, not a refusal. Fail-open, stated.
d=$(make_env); u_clear_marker "$d"; pad "$d" 20000; a_tool "$d" CronCreate
fire "$d"; expect_allow "61: a marker beyond the window reads as no marker — the arm goes inert"

# 62: THE BOUND IS NAMED AND IS A CONSTANT. A window that regresses to an unbounded read
# is invisible in every behavioural test above — 60 and 61 both still pass without a
# `tail` if the whole file is small. This is the assertion that the bound exists at all.
if grep -q '^SCAN_WINDOW_LINES=[0-9][0-9]*$' "$HOOK" && grep -q 'tail -n "\$SCAN_WINDOW_LINES"' "$HOOK"; then
  ok "62: the transcript scan is bounded by a named SCAN_WINDOW_LINES constant"
else
  no "62: the transcript scan has no named line bound — it reads from byte zero"
fi
# ---------- Group 25: THE ENGAGEMENT SWITCH (AC-8) ----------
#
# The switch is asked before the transcript is read at all, so each silence below is paired
# with the refusal the same fixture produces once the marker is back.

# 63: the ordinary refusing fixture, engaged -> blocks.
d=$(make_env); u_tick "$d"
fire "$d"; expect_block "63: engaged: a tick with neither duty blocks" "$LA_MISSING"

# 64: the SAME fixture with the marker removed -> nothing at all.
rm -f "$d/.bionic/tmp/engaged-$SID.state"
fire "$d"; expect_allow "64: the same fixture unengaged is silent"

# 65: a SYMLINK at the marker path reads as absent, never followed.
DECOY_MARK=$(mktemp); printf 'plan=none\n' > "$DECOY_MARK"
ln -s "$DECOY_MARK" "$d/.bionic/tmp/engaged-$SID.state"
fire "$d"; expect_allow "65: a symlink at the marker path is not an engagement"
rm -f "$d/.bionic/tmp/engaged-$SID.state"

# 66: ANOTHER session's marker is not this session's.
: > "$d/.bionic/tmp/engaged-99999999-8888-7777-6666-555555555555.state"
fire "$d"; expect_allow "66: another session's marker is not this session's engagement"

# 67: restoring this session's marker restores the refusal, word for word.
: > "$d/.bionic/tmp/engaged-$SID.state"
fire "$d"; expect_block "67: re-engaged, the refusal returns unchanged" "$LA_MISSING"

# ---------- Group 26: WHAT COUNTS AS A TICK (T6, AC-22) ----------
#
# The defect this replaces: the gate called a turn a tick when the last USER row CONTAINED
# `session-poker.sh tick`, and the canonical-sdlc SKILL.md body — injected into the
# transcript as a USER row — contains exactly that literal. Invoking the skill was a tick.

# 68: a USER row that merely CONTAINS the tick command is not a tick.
d=$(make_env)
u_prompt "$d" "Base directory for this skill: /x/skills/canonical-sdlc

# Canonical SDLC

... **Tick the poker.** \`bash <plugin-root>/hooks/session-poker.sh tick\` is the decision brain — the prompt gathers, the poker decides, per row. ..."
fire "$d"; expect_allow "68: the injected SKILL.md body is not a Patrol tick"

# 69: THE PAIRED POSITIVE, so 68 is not silence-by-vacuity: the same fixture with the real
# marker at the front of the row refuses.
d=$(make_env); u_tick "$d"
fire "$d"; expect_block "69: …while a row led by the patrol marker is" "$LA_MISSING"

# 70: ANOTHER session's marker leads the row -> a predecessor's cron firing into this
# conversation after a /clear is not this session's tick.
d=$(make_env)
u_prompt "$d" "bionic-patrol session=deadbeef — Patrol tick. Run: bash /abs/hooks/session-poker.sh tick"
fire "$d"; expect_allow "70: a row led by ANOTHER session's patrol marker is not a tick"

# 71: the marker must LEAD the row, not merely appear in it.
d=$(make_env)
u_prompt "$d" "Here is what the cron job carries: bionic-patrol session=$SID8 — and that is all I wanted to show you."
fire "$d"; expect_allow "71: the marker mid-row is not a tick — it must be the first token"

# 72: the FILL duty reads the same marker. A tick that printed FILL and a turn that
# neither dispatched nor declined is refused; the SKILL.md body carrying the literal is not.
d=$(make_env); u_tick "$d"; both_duties "$d"; u_tick_out "$d" "poker: FILL S3 S4"
fire "$d"; expect_block "72: an unanswered FILL after a real tick blocks" "S3"

d=$(make_env)
u_prompt "$d" "... \`bash <plugin-root>/hooks/session-poker.sh tick\` is the decision brain ..."
both_duties "$d"; u_tick_out "$d" "poker: FILL S3 S4"
fire "$d"; expect_allow "73: …and the same FILL line after a non-tick row is not a duty"

setup_section "Section S5: active_run -> session_run (wave-session-bound-run S5)"
#
# THE CONTRACT UNDER TEST (design ledger AC-1/AC-3/AC-6). `PLAN` — and so
# `PLAN_NAME`, the basename that discharges the task-list duty — used to come
# from `active_run "$PROJECT_DIR"`: the newest open plan in the root, with no
# session input at all. It now comes from `session_run "$PROJECT_DIR" "$SID"`: a
# session BOUND to a plan is policed against that plan's basename alone, whatever
# else is open in the root; UNBOUND (the marker empty, as make_env's own marker
# is) it falls back to the newest plan exactly as before, and says so on stderr;
# bound to a plan that has since closed, it is policed exactly as an engaged
# session with no plan at all (no basename can ever discharge the duty), and
# that closure is announced too.

# Captures stderr SEPARATELY from fire() (which discards it) — the advisory is a
# diagnostic line, and this is the only way to read it. Mirrors
# tests/patrol-revive.test.sh's own fire_stderr.
fire_stderr() {  # <project> [event] [stop_hook_active]
  HOOK_ERR=$(env CLAUDE_CODE_SESSION_ID="$SID" bash "$HOOK" \
    <<< "$(stdin_for "$1" "$1/transcript.jsonl" "${2:-Stop}" "${3:-false}")" 2>&1 >/dev/null)
}

PLAN_A_REL="plan-a.plan.md"
PLAN_B_REL="plan-b.plan.md"

# make_env_two_plans -> project dir on stdout. Two OPEN plans under one docs
# root, ages controlled by touch so the newest (B) is decisively the fallback
# target. ENGAGED, UNBOUND by default (make_env's own convention) — s5_bind
# below overwrites the marker for the bound cases.
make_env_two_plans() {
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/.bionic/docs/plans" "$dir/.bionic/tmp"
  : > "$dir/.bionic/tmp/engaged-$SID.state"
  cat > "$dir/.bionic/docs/plans/$PLAN_A_REL" <<'EOF'
---
governing-skill: canonical-sdlc
---
## SDLC State

current: T5
EOF
  cat > "$dir/.bionic/docs/plans/$PLAN_B_REL" <<'EOF'
---
governing-skill: canonical-sdlc
---
## SDLC State

current: T5
EOF
  touch -t 202601010000 "$dir/.bionic/docs/plans/$PLAN_A_REL"
  touch -t 202602010000 "$dir/.bionic/docs/plans/$PLAN_B_REL"
  : > "$dir/transcript.jsonl"
  printf '%s' "$dir"
}

# s5_bind <project> <plan-rel-under-docs-plans>
s5_bind() {
  { printf 'plan=%s/.bionic/docs/plans/%s\n' "$1" "$2"
    printf 'engaged_at=2026-09-04T00:00:00Z\n'
  } > "$1/.bionic/tmp/engaged-$SID.state"
  chmod 600 "$1/.bionic/tmp/engaged-$SID.state"
}

# s5_deliver <plan-abs-path> — closes a T-scale plan by replacing it with a
# closed numeric-scale one (task scale, per lib/run.sh's own table, is always
# open — there is no "delivered" state to give it).
s5_deliver() {
  cat > "$1" <<'EOF'
---
governing-skill: canonical-sdlc
---
## SDLC State

current: 9

- Step 9: report record/x.md, delivered: 2026-09-04
EOF
}

section "24: bound-open — only the BOUND plan's basename discharges the duty"

d=$(make_env_two_plans); s5_bind "$d" "$PLAN_A_REL"
u_tick "$d"; a_tool "$d" ListAgents; a_tool "$d" Edit "$d/.bionic/docs/plans/$PLAN_A_REL"
fire "$d"; expect_allow "24a: bound to A, an Edit naming A satisfies the task-list duty"

d=$(make_env_two_plans); s5_bind "$d" "$PLAN_A_REL"
u_tick "$d"; a_tool "$d" ListAgents; a_tool "$d" Edit "$d/.bionic/docs/plans/$PLAN_B_REL"
fire "$d"; expect_block "24b: bound to A, an Edit naming B (unrelated to A) does not satisfy it" \
  "$TL_MISSING" "$LA_MISSING"
fire_stderr "$d"
case "$HOOK_ERR" in
  *"run resolved by newest-plan fallback"*) no "24c: bound to A prints no fallback line" "$HOOK_ERR" ;;
  *) ok "24c: bound to A prints no fallback line" ;;
esac

section "25: fallback — unbound resolves to the newest plan (B), and says so"

d=$(make_env_two_plans)
# PHYSICAL, because the fallback path comes off active_plan's own resolution —
# `project_root` calls `pwd -P` internally (payload/scripts/lib/root.sh) — while
# `$d` is `mktemp -d`'s raw (logical) answer. The two differ under macOS's
# /var -> /private/var link; this assertion pins an exact adjacency ("— "
# immediately followed by the path), so — unlike a bare path-substring check —
# it needs the physical form the hook itself prints.
d_phys=$(cd "$d" && pwd -P)
u_tick "$d"; a_tool "$d" ListAgents; a_tool "$d" Edit "$d/.bionic/docs/plans/$PLAN_B_REL"
fire "$d"; expect_allow "25a: unbound, an Edit naming B (the newest) satisfies the duty"
fire_stderr "$d"
case "$HOOK_ERR" in
  *"patrol-duties-gate: run resolved by newest-plan fallback (session unbound) — $d_phys/.bionic/docs/plans/$PLAN_B_REL"*)
    ok "25b: unbound prints the fallback line, naming B verbatim" ;;
  *) no "25b: unbound prints the fallback line, naming B verbatim" "$HOOK_ERR" ;;
esac

# THE PAIRED NEGATIVE: unbound, A's name (the OLDER plan, not the fallback
# target) does not satisfy the duty.
d=$(make_env_two_plans)
u_tick "$d"; a_tool "$d" ListAgents; a_tool "$d" Edit "$d/.bionic/docs/plans/$PLAN_A_REL"
fire "$d"; expect_block "25c: unbound, an Edit naming A (not the fallback target) does not satisfy it" \
  "$TL_MISSING" "$LA_MISSING"

section "26: bound-closed — a plan that closed is no open run at all"

d=$(make_env_two_plans)
s5_deliver "$d/.bionic/docs/plans/$PLAN_A_REL"
s5_bind "$d" "$PLAN_A_REL"
u_tick "$d"; a_tool "$d" ListAgents; a_tool "$d" Edit "$d/.bionic/docs/plans/$PLAN_B_REL"
fire "$d"; expect_block "26a: bound to a CLOSED A, an Edit naming open B satisfies nothing" \
  "$TL_MISSING" "$LA_MISSING"
fire_stderr "$d"
case "$HOOK_ERR" in
  *"patrol-duties-gate: bound plan closed — $d/.bionic/docs/plans/$PLAN_A_REL; this session has no open run"*)
    ok "26b: the closed-plan advisory names A, verbatim" ;;
  *) no "26b: the closed-plan advisory names A, verbatim" "$HOOK_ERR" ;;
esac
case "$HOOK_ERR" in
  *"$PLAN_B_REL"*) no "26c: B's path (the still-open plan) appears nowhere in the output" "$HOOK_ERR" ;;
  *) ok "26c: B's path (the still-open plan) appears nowhere in the output" ;;
esac

section "AC-E1.3/E1.5: the refusal's user stream is one line, in the criterion's shape"

# fails-when: a refusal reaches the user as more than one line, or in any shape but
# `bionic: <verb> refused — <fact> (<fix ≤ 40 cols>)`. This gate refuses over the JSON
# `block` channel, which has a model-only wire — so the reason the arms above read stays
# whole in the JSON while the USER stream is the single rendered line, always, knob or
# no knob. Both halves are asserted on one drive of a real refusal.

PE1_RE='^bionic: [a-z-]+ refused — .+ \(.{1,40}\)$'
PE1_ERRFILE="$(mktemp)"
# Drive a real refusal through the same helper the arms above use, then read the user
# stream it left behind. The status is the block channel's own: exit 0 with a verdict.
PE1_D=$(make_env); u_tick "$PE1_D"; a_tool "$PE1_D" ListAgents
fire "$PE1_D"
expect_contains "E1.3 the JSON verdict is still a block (the model's half is unchanged)" \
  '"decision":"block"' "$HOOK_OUT"
# ONE REFUSAL LINE. The gate also prints its own diagnostics to stderr before it
# decides, so the count is of RENDERED refusals and not of every byte on the stream.
expect_eq "E1.3 the user stream carries exactly one rendered refusal" \
  "1" "$(printf '%s\n' "$HOOK_ERR_USER" | /usr/bin/grep -c '^bionic: ')"
if printf '%s\n' "$HOOK_ERR_USER" | /usr/bin/grep '^bionic: ' | /usr/bin/grep -qE "$PE1_RE"; then
  ok "E1.3 …in AC-E1.3's shape"
else
  no "E1.3 …in AC-E1.3's shape" "line=[$HOOK_ERR_USER]"
fi
expect_contains "E1.3 …and it is one of this gate's ruled facts" \
  "bionic: stop refused — no task-list refresh since this tick" "$HOOK_ERR_USER"
expect_absent "E1.5 the paragraph the model reads is NOT on the user stream" \
  "this gate blocks once" "$HOOK_ERR_USER"

finish
