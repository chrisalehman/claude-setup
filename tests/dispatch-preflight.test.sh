#!/bin/bash
# Tests for hooks/dispatch-preflight.sh — THE START GATE (epic-15 wave-01R).
#
# PreToolUse|Agent. Serves AC-2, and the start-side share of AC-9/AC-10.
#
# Governing design: design/orchestrator-subagent-coordination.md §4 "The start
# gate", §3.4 Starting, §7 (fail-direction table).
#
# HERMETIC. Every payload is crafted and piped straight into the script under
# test; nothing here dispatches a real Agent tool call, touches the live
# installed hooks, or depends on a live wave. Repos are throwaway git inits
# under a mktemp'd sandbox; attestations are written directly as fixtures
# (never by invoking the real preflight-probe.sh), except in the S9
# runnability check, which installs a COPY of the real producer into a
# sandboxed HOME specifically to prove its fix command executes.
#
# Usage: bash tests/dispatch-preflight.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/bound-marker.sh"
. "$(dirname "$0")/lib/roster-row.sh"
. "$(dirname "$0")/lib/live-answer.sh"
. "$(dirname "$0")/lib/swept-marker.sh"

GATE="${BIONIC_HOOKS_DIR}/dispatch-preflight.sh"
PROBE_SRC="${BIONIC_HOOKS_DIR}/preflight-probe.sh"

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dispatch-preflight-test.XXXXXX")" && pwd)"
BG_PIDS=""
cleanup() {
  local p
  for p in $BG_PIDS; do kill -9 "$p" 2>/dev/null; done
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# HELPER-PRESENCE GUARD (spec AC-25). This file runs under `set -uo pipefail` — NO
# `-e` — so a call to an assertion helper that was never defined here is a silent
# "command not found" on stderr: the row asserts nothing and the suite's own
# pass/total never notices (r24e was exactly this defect: `expect_eq` was called at
# :2835 with no definition anywhere in this file, caught by research-code-map §6.2).
# `expect_eq` itself and `require_helpers` now come from tests/lib/assert.sh (S11) —
# every helper this file calls is checked to exist as a function before the first
# test runs, so a future undefined call fails the whole suite loudly instead of
# vanishing.
require_helpers ok no expect_status expect_contains expect_absent expect_empty expect_eq

# ---------- fixtures ----------
#
# FIXTURE FIDELITY (declared per checklist §A / spec §Design / rule
# fixtures-can-pin-away-the-test).
#
# Source: .bionic/docs/record/epic-15-kill-interception-experiment.md, CLI
# 2.1.220 verbatim captures.
#
#   * PreToolUse payload ENVELOPE — FAITHFUL to §2.2, field for field:
#     session_id, transcript_path, cwd, prompt_id, permission_mode, effort,
#     hook_event_name, tool_name, tool_input, tool_use_id. §2.2 is captured
#     for tool_name:"TaskStop", but §2.1/§2.12 establish this is the SAME
#     builder for every PreToolUse invocation (only tool_name/tool_input
#     differ) — the matcher "Task" matching tool_name "Agent" (§2.12,
#     confirmed live in §2.1) independently corroborates that "Agent" is the
#     real tool_name value for a subagent dispatch.
#   * tool_name:"Agent" value and tool_input SHAPE — FAITHFUL as of slice 4/3
#     to .bionic/docs/record/w3-slice1-posttooluse-probe.md capture E (an
#     Agent-tool payload captured live at CLI 2.1.222): tool_input carries
#     description, prompt, subagent_type, run_in_background, and — when the
#     dispatch names one — name. The earlier note here ("SHAPE-ONLY, no
#     verbatim Agent capture exists") described the pre-probe state and is
#     superseded. tool_input became load-bearing in slice 4/3: the roster row
#     is lifted from it.
#   * tool_input.model — SHAPE-EXTRAPOLATED and declared: the Agent tool
#     accepts a `model` override, but no captured payload carries one (every
#     probe dispatch inherited). It is fixtured here because the roster
#     records it WHEN PRESENT; its absence is deliberately not an absence
#     finding, and S10c drives the no-model path.
#   * dispatch brief text (BRIEF_FULL / the compact variant) — SYNTHESIZED,
#     but its LABEL GRAMMAR is the shipped one: skills/canonical-sdlc/SKILL.md
#     §Dispatch's seven-field sentence (span-pinned by
#     tests/dispatch-spans.test.sh §5d — that suite was deleted in an earlier
#     purge, commit b959b5e, and nothing replaced the span pin) and the
#     exemplar brief recorded verbatim at .bionic/docs/record/w2-ac3-run.md:25-40.
#   * attestation record — FAITHFUL to hooks/preflight-probe.sh's own
#     schema/comment block: `# comment` + `key=value` lines, read BY KEY
#     (checklist A6), `session_id=` the field this gate keys on (Slice 4/1
#     resolution: spelled to match the payload field name).
#   * SYNTHESIZED and declared: session ids, agent ids, plan text, message
#     text. None is a platform surface.

SID_A="6c85684c-9588-45a0-bd26-e8c46956c94f"
SID_B="1f4a7c02-3bd9-4e15-8a66-90c1de77b204"

# A realistic dispatch brief carrying all seven labeled contract fields in the
# shipped grammar — plus, since S13 (spec AC-20), the eighth: the instrument the
# slice declares. `Suites:` is the DECLARED spelling, which is what a sandbox
# repo with no `impact-command:` in its .bionic/config.yaml must use; the DERIVED
# spelling (`Files:` plus a configured command) gets its own fixtures in S27,
# where the config exists. A brief carrying neither refuses at dispatch, so
# leaving the line off here would have put every case in this file on the
# refusal path instead of the one it means to test.
# The DEFAULT for every payload below, because a brief that
# carries its contract fields is the ordinary case — the roster's absence
# warning must not fire on it (that is what keeps the §7 "positive pair: pass in
# silence" row true), and a fixture that omitted them would have made every
# pre-slice-4/3 pass case silently exercise the absence path instead
# (.claude memory: fixtures-can-pin-away-the-test). The absence path gets its
# own bare-brief fixture in S10c, and both directions are asserted.
BRIEF_FULL='Canonical-sdlc Step 4, slice 4/9 of epic-99 wave-01; build · audited · wave.
Your slice: implement the widget behind the existing seam.
Scope constraint: touch only lib/widget.sh and its paired suite.
Expected artifact: .bionic/docs/record/w99-widget.txt
Exit condition: the artifact exists and the paired suite is green.
Expected duration: ~25 minutes.
Progress artifact: .bionic/tmp/w99-widget.progress
Suites: tests/widget.test.sh'

# ---------- live_agents transcript fixtures (spec AC-6/AC-7/AC-8; slice S5) ----------
#
# Entry-shape helpers, copied from tests/live-agents.test.sh — the one file that owns
# the real transcript entry shapes (assistant tool_use / user tool_result / user
# plain-string prompt), per this slice's brief ("build transcript fixtures by copying
# the fixture helpers' shapes from tests/live-agents.test.sh").

json_str() { printf '%s' "$1" | jq -Rs .; }

entry_prompt() {  # <ts> <text> -> a user PROMPT entry (.message.content a plain string)
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":%s}}\n' \
    "$1" "$(json_str "$2")"
}

entry_tool_use() {  # <ts> <tool-name> <tool_use_id>
  printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"%s","input":{}}]}}\n' \
    "$1" "$3" "$2"
}

entry_tool_result() {  # <ts> <tool_use_id> <body>
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":%s}]}}\n' \
    "$1" "$2" "$(json_str "$3")"
}

# THE ANSWER BODY IS BUILT BY tests/lib/live-answer.sh (S17, spec AC-27/AC-28): the self
# line, the block header and every teammate row come out of the committed corpus with only
# this suite's names and statuses substituted in place. With NO names it is the self line
# alone — recognisable, carrying no teammates block at all, which is AC-6's "zero lines"
# case. This suite's private builder was one of the two that truncated the recognition
# anchor to its own spelling; the corpus's is now the only one in the tree.
#
# A bare name is the corpus's own `running`. `name:idle` writes the OTHER status the real
# harness emits: a teammate that finished its turn and was never TaskStop'd stays listed,
# because it stays addressable, and S22c is where that costs a writer slot or does not.
LIVE_ANSWER_TYPE="bionic:implementor"
la_body() {  # <name[:status]>... -> one real-shaped ListAgents answer body
  live_answer_body "$@"
}

# mk_transcript <path> <fresh|stale|none> [name] ... — writes a jsonl transcript at
# <path>. fresh/stale both carry one ListAgents answer naming the given teammates (zero
# or more); stale adds a LATER prompt so the answer no longer postdates the last one;
# none carries no ListAgents call at all. Fixed 2026-09-05 timestamps throughout, same
# idiom the rest of this file's fixtures use — freshness is a comparison between two
# entries in the file, never against wall-clock "now" (only `age=` is, and no assertion
# below pins its value).
_S5_TID=0
mk_transcript() {
  local path="$1" state="$2" tid body
  shift 2
  if [ "$state" = "none" ]; then
    entry_prompt "2026-09-05T00:50:00.000Z" "who is running" > "$path"
    return 0
  fi
  _S5_TID=$((_S5_TID + 1))
  tid="toolu_s5_${_S5_TID}"
  body="$(la_body "$@")"
  {
    entry_prompt      "2026-09-05T00:50:00.000Z" "who is running"
    entry_tool_use    "2026-09-05T00:52:22.000Z" "ListAgents" "$tid"
    entry_tool_result "2026-09-05T00:52:23.349Z" "$tid" "$body"
    [ "$state" = "stale" ] && entry_prompt "2026-09-05T00:55:00.000Z" "anything else?"
  } > "$path"
}

# THE DEFAULT for every dispatch payload below (mk_agent_payload's 6th argument): a
# FRESH answer naming every roster-row name this file's pre-existing S22/S25 fixtures
# use (W-ONE..W-FOUR), so a row that is not otherwise made absent still reads as the
# live agent it always represented — the one adaptation existing budget fixtures need
# now that AC-7 retires the `landing-swept` marker as the closing signal. Tests that
# need a name ABSENT, or a STALE/NONE answer, build and pass their own transcript.
S5_LIVE_TRANSCRIPT="$SANDBOX/.s5-live-default.jsonl"
mk_transcript "$S5_LIVE_TRANSCRIPT" fresh W-ONE W-TWO W-THREE W-FOUR

# mk_agent_payload <sid> <cwd> [prompt] [name] [model] [transcript]
#
# prompt/name/model default to the contract-complete brief; pass "-" for name or
# model to omit the field from tool_input entirely (the absence cases). transcript
# defaults to $S5_LIVE_TRANSCRIPT (fresh, names every W-* fixture row live).
mk_agent_payload() {
  local prompt="${3-$BRIEF_FULL}" name="${4-w99-impl}" model="${5-claude-sonnet-5}" \
        transcript="${6-$S5_LIVE_TRANSCRIPT}" stype="${7-implementor}"
  jq -n --arg s "$1" --arg c "$2" --arg p "$prompt" --arg n "$name" --arg m "$model" \
        --arg t "$transcript" --arg y "$stype" \
    '{session_id:$s, transcript_path:$t, cwd:$c,
      prompt_id:"f3cd7d62-305d-47ed-9eaf-46fb12d4f4ed",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      hook_event_name:"PreToolUse", tool_name:"Agent",
      tool_input:({description:"a test dispatch", subagent_type:$y,
                   prompt:$p, run_in_background:true}
                  + (if $n == "-" then {} else {name:$n} end)
                  + (if $m == "-" then {} else {model:$m} end)),
      tool_use_id:"toolu_018jyjgop7KMxP6yKtoAWWtB"}'
}

mk_bash_payload() {  # <sid> <cwd>  — an irrelevant tool, for the A7 hoist tests
  jq -n --arg s "$1" --arg c "$2" \
    '{session_id:$s, transcript_path:"/irrelevant.jsonl", cwd:$c,
      prompt_id:"f3cd7d62-305d-47ed-9eaf-46fb12d4f4ed",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      hook_event_name:"PreToolUse", tool_name:"Bash",
      tool_input:{command:"echo hi"}, tool_use_id:"toolu_0irrelevant"}'
}

GATE_OUT=""; GATE_ERR=""; GATE_ST=0
# Set to a directory to drive the gate with a sandboxed CLAUDE_CONFIG_DIR — the
# roster prune's liveness lookup reads <config>/projects/*/<session>.jsonl, and
# the operator's REAL config dir would decide which fixtures survive otherwise.
GATE_CONFIG_DIR=""
# Extra `KEY=VALUE` assignments for the gate's own environment, applied unquoted so a
# space-free list can carry several (none of the values below contain spaces). Added for
# the combined preflight (S16): the gate now runs the real preflight-probe.sh inline, and
# the probe reads a credential and a config dir out of the environment — which must be the
# SANDBOX's, never the operator's.
GATE_ENV=""
# THE ENVIRONMENT AGREES WITH THE PAYLOAD, because on the machine it does. Since
# bionic 1.4.0 the wall takes its session id from lib/session.sh, where the ENV value
# is primary and the payload is a witness (design §1, R-1) — so a driver that shipped
# a fixture id in the payload while the runner's own CLAUDE_CODE_SESSION_ID sat in the
# environment would be driving a DIVERGENCE, not a session. The probe that settled
# this measured the two agreeing on a plain /clear (A-probe-2), and every fixture here
# is a session, so the driver mirrors the payload into the environment. A payload with
# no session key exports an empty one, which is what makes the no-session-key arms
# still reach the fail direction they pin.
run_gate() {  # <payload-json>
  local _sid; _sid=$(printf '%s' "$1" | jq -r '.session_id // ""' 2>/dev/null) || _sid=""
  GATE_ENV="$GATE_ENV CLAUDE_CODE_SESSION_ID=$_sid"
  if [ -n "$GATE_CONFIG_DIR" ]; then
    # shellcheck disable=SC2086
    GATE_OUT=$(printf '%s' "$1" | env $GATE_ENV CLAUDE_CONFIG_DIR="$GATE_CONFIG_DIR" bash "$GATE" 2>"$SANDBOX/.err")
  else
    # shellcheck disable=SC2086
    GATE_OUT=$(printf '%s' "$1" | env $GATE_ENV bash "$GATE" 2>"$SANDBOX/.err")
  fi
  GATE_ST=$?
  GATE_ERR=$(cat "$SANDBOX/.err")
  GATE_ENV="${GATE_ENV% CLAUDE_CODE_SESSION_ID=*}"
  return 0
}

# ---------- the combined preflight's environment (epic-16 w2 S5) ----------
#
# As of R5 the gate RUNS hooks/preflight-probe.sh inline whenever this session has no
# attestation on disk, so most cases in this file now reach the real producer. Its
# blocking probes read a credential and its D-5 pruning reads a config directory, and
# both of those are machine-global by default: the operator's login keychain answers the
# credential probe no matter what a sandbox does, and the operator's own `~/.claude`
# decides which fixture rosters look "live". Substituting the ENVIRONMENT (not the
# script) is the same technique preflight-probe.test.sh uses, and it is on for the whole
# file so that no case accidentally depends on the machine it runs on.
#
# The transcript file makes THIS session look live to the probe's own scan; SESSION B
# gets one too, since several cases below turn on a live foreign session being left
# alone rather than pruned.
PROBE_ENV_HOME="$SANDBOX/probehome"
PROBE_ENV_PROJ="$PROBE_ENV_HOME/.claude/projects/-sandbox"
mkdir -p "$PROBE_ENV_PROJ"
: > "$PROBE_ENV_PROJ/$SID_A.jsonl"
: > "$PROBE_ENV_PROJ/$SID_B.jsonl"
probe_env_on() {
  GATE_CONFIG_DIR="$PROBE_ENV_HOME/.claude"
  GATE_ENV="ANTHROPIC_API_KEY=sk-fixture-marker HOME=$PROBE_ENV_HOME"
}
probe_env_on

# ---------- roster readers (slice 4/3) ----------
#
# BY KEY, never by position — the same rule the attestation and the observation
# record already follow (checklist A6), so an added field is inert here.
roster_path()  { printf '%s/.bionic/tmp/roster-%s.state' "$1" "$2"; }
roster_rows()  { grep -v '^#' "$1" 2>/dev/null | grep -c . ; }
# NAMED FOR WHAT IT DOES, because `roster_row` is now the production WRITER's name and this
# suite sources it (tests/lib/roster-row.sh, S14). Two functions, one name, one of them
# shadowing the other from line 24 onwards is not a collision a test can survive quietly:
# every fixture built through the writer would have silently been fed to this reader.
roster_nth_row() { grep -v '^#' "$1" 2>/dev/null | sed -n "${2}p"; }   # <file> <n>
roster_field() { printf '%s' "$1" | tr '|' '\n' | grep "^$2=" | head -1 | cut -d= -f2-; }

# make_repo <name> <active-wave:yes|no> -> echoes the repo path
make_repo() {
  local name="$1" wave="$2"
  local repo="$SANDBOX/$name/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name "T"
  echo seed > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm seed 2>/dev/null
  if [ "$wave" = "yes" ]; then
    # A live wave has a live Patrol: it is armed at engagement, before the first dispatch
    # (skills/canonical-sdlc/SKILL.md §Dispatch). Every wave-active fixture therefore
    # carries a fresh stamp for the session ids this suite dispatches with, and the S21
    # arms remove or backdate it to drive the arming wall. Without this the wall would be
    # under test in every case in the file rather than in its own section.
    mkdir -p "$repo/.bionic/tmp"
    local _psid
    for _psid in "${SID_A:-}" "${SID_B:-}" "${SID_DEAD:-}" "${SID_LIVE:-}"; do
      [ -n "$_psid" ] || continue
      printf 'patrol-stamp/v1|at=%s|session=%s|verb=arm\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_psid" > "$repo/.bionic/tmp/patrol-$_psid.state"
      chmod 600 "$repo/.bionic/tmp/patrol-$_psid.state"
      # A LIVE WAVE HAS AN ENGAGED SESSION (task-engaged-session). The gate asks
      # `engaged_session` before it asks anything else, so a fixture without this marker is
      # silent for a reason that has nothing to do with the wall under test — every
      # assertion in this file would pass over a hook that exits at its first line. The
      # marker is exactly what hooks/engage.sh writes when canonical-sdlc is invoked.
      : > "$repo/.bionic/tmp/engaged-$_psid.state"
    done
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
  printf '%s' "$repo"
}

# write_attestation <repo> <session_id> [extra kv lines...]
#
# slice 4/2 (D-5): writes to the PER-SESSION filename, preflight-<sid>.state — the
# filename is now the primary key, matching hooks/preflight-probe.sh's own scheme.
write_attestation() {
  local repo="$1" sid="$2"; shift 2
  mkdir -p "$repo/.bionic/tmp"
  {
    printf '# bionic environment attestation — machine-local, safe to delete\n'
    printf 'version=1\n'
    printf 'kind=preflight-attestation\n'
    printf 'session_id=%s\n' "$sid"
    printf 'written_at=1785790000\n'
    printf 'repo=%s\n' "$repo"
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$repo/.bionic/tmp/preflight-$sid.state"
  chmod 600 "$repo/.bionic/tmp/preflight-$sid.state"
}

# write_legacy_attestation <repo> <session_id> — the OLD, pre-wave-03 single-slot
# filename. Used to prove the gate never consults it (slice 4/2).
write_legacy_attestation() {
  local repo="$1" sid="$2"
  mkdir -p "$repo/.bionic/tmp"
  {
    printf '# bionic environment attestation — machine-local, safe to delete\n'
    printf 'version=1\n'
    printf 'kind=preflight-attestation\n'
    printf 'session_id=%s\n' "$sid"
    printf 'written_at=1785790000\n'
    printf 'repo=%s\n' "$repo"
  } > "$repo/.bionic/tmp/preflight.state"
  chmod 600 "$repo/.bionic/tmp/preflight.state"
}

section "S1 — relevance hoist (A7): irrelevant tool passes, silent"


REPO=$(make_repo r1 yes)
# no attestation exists at all — if tool_name gating were bypassed, an
# "Agent" payload here would be REFUSED. A "Bash" payload must still pass.
run_gate "$(mk_bash_payload "$SID_A" "$REPO")"
expect_status "irrelevant tool exits 0 even with no attestation in an active wave" "0" "$GATE_ST"
expect_empty "irrelevant tool produces no stdout" "$GATE_OUT"
expect_empty "irrelevant tool produces no stderr" "$GATE_ERR"

# static pin: the relevance check must appear in the source BEFORE the
# active-wave machinery (resolve_docs_root / the plan-directory find) — this
# is the textual half of A7's hoist proof; the behavioral half is above.
TOOL_LINE=$(grep -n '\[ "\$TOOL_NAME" = "Agent" \]' "$GATE" | head -1 | cut -d: -f1)
# The plan-directory walk is the library's now (lib/run.sh's active_run); what this
# pins is unchanged — the cheap relevance check comes first, before anything touches
# disk.
WALK_LINE=$(grep -n 'session_run "\$REPO"' "$GATE" | head -1 | cut -d: -f1)
if [ -n "$TOOL_LINE" ] && [ -n "$WALK_LINE" ] && [ "$TOOL_LINE" -lt "$WALK_LINE" ]; then
  ok "relevance check (line $TOOL_LINE) precedes the plan-directory walk (line $WALK_LINE)"
else
  no "relevance check precedes the plan-directory walk" "tool=$TOOL_LINE walk=$WALK_LINE"
fi

section "S2 — ambiguity: repo unresolvable -> OPEN, silent"

run_gate "$(mk_agent_payload "$SID_A" "")"
expect_status "empty cwd exits 0" "0" "$GATE_ST"
expect_empty "empty cwd produces no stdout" "$GATE_OUT"
expect_empty "empty cwd produces no stderr" "$GATE_ERR"

# A NON-GIT CWD IS NOT THE QUESTION ANY MORE (bionic 1.4.0, spec AC-12, Decision A2).
# It used to be the whole precondition: `git rev-parse --show-toplevel` had to succeed
# or the wall exited silently, which made the wall's coverage a property of the SHELL's
# cwd rather than of the project. A dispatch from a scratch directory that nonetheless
# sat under a real `.bionic` root disarmed arming, containment and rostering at once.
#
# The question now is whether there is a PROJECT: `project_root` walks for the nearest
# real `.bionic` ancestor and `active_run` asks whether its run is open. The two rows
# below are the same non-git cwd on either side of that line, and nothing separates
# them but a `.bionic` directory above.
NONGIT="$SANDBOX/not-a-repo"; mkdir -p "$NONGIT"
run_gate "$(mk_agent_payload "$SID_A" "$NONGIT")"
expect_status "A2 non-git cwd with NO .bionic above it exits 0" "0" "$GATE_ST"
expect_empty "A2 …producing no stdout" "$GATE_OUT"
expect_empty "A2 …and no stderr" "$GATE_ERR"

# The other side: a non-git cwd INSIDE a project with an open run. The wall runs, and
# with no Patrol stamp for this session it refuses at the arming wall — the refusal
# that was unreachable from here before A2.
A2_ROOT=$(make_repo a2root yes)
rm -rf "$A2_ROOT/.git"
rm -f "$A2_ROOT/.bionic/tmp/patrol-$SID_A.state"   # unarmed: the refusal this row drives
A2_SCRATCH="$A2_ROOT/scratch/deep"; mkdir -p "$A2_SCRATCH"
write_attestation "$A2_ROOT" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$A2_SCRATCH")"
expect_status "A2 non-git cwd WITH a .bionic root above it reaches the wall (exit 2)" "2" "$GATE_ST"
expect_contains "A2 …refusing at the arming wall, which is what the old precondition hid" \
  "Patrol" "$GATE_ERR"

section "S3 — no active wave -> inert, nothing to decide"

REPO_NOWAVE=$(make_repo r3a no)
run_gate "$(mk_agent_payload "$SID_A" "$REPO_NOWAVE")"
expect_status "no plan directory at all exits 0" "0" "$GATE_ST"
expect_empty "no plan directory produces no stdout" "$GATE_OUT"
expect_empty "no plan directory produces no stderr" "$GATE_ERR"

REPO_NOWAVE2=$(make_repo r3b yes)
# UNENGAGED, DELIBERATELY (task-engaged-session). make_repo plants the engagement marker
# with the Patrol stamp, and since this wave an ENGAGED session is walled whether or not a
# plan is on disk (AC-23, driven in S24 below). What this block claims is the older, and
# still true, half: a session that never invoked canonical-sdlc sees nothing at all. Removing
# the marker is what keeps the claim about the run predicate rather than about engagement.
rm -f "$REPO_NOWAVE2/.bionic/tmp/engaged-$SID_A.state"
# overwrite with a plan that has no ## SDLC State at all
cat > "$REPO_NOWAVE2/.bionic/docs/plans/epic-99-test/wave-01-test.plan.md" <<'PLAN'
---
governing-skill: canonical-sdlc
canonical_sdlc_version: 14
---
# A plan with no SDLC State section
PLAN
run_gate "$(mk_agent_payload "$SID_A" "$REPO_NOWAVE2")"
expect_status "plan with no SDLC State section exits 0" "0" "$GATE_ST"
expect_empty "no SDLC State produces no stdout" "$GATE_OUT"
expect_empty "no SDLC State produces no stderr" "$GATE_ERR"

# even with NO attestation present, no-active-wave still passes an Agent
# dispatch — proving the wave check, not the attestation check, gates entry.
run_gate "$(mk_agent_payload "$SID_A" "$REPO_NOWAVE")"
expect_status "Agent dispatch with no wave and no attestation still exits 0" "0" "$GATE_ST"

section "S4 — active wave + payload missing session_id -> OPEN, silent (§7 table)"

REPO=$(make_repo r4 yes)
run_gate "$(mk_agent_payload "" "$REPO")"
expect_status "missing session_id in an active wave exits 0" "0" "$GATE_ST"
expect_empty "missing session_id produces no stdout" "$GATE_OUT"
expect_empty "missing session_id produces no stderr" "$GATE_ERR"

section "S5 — active wave + no attestation on disk -> AUTO-PROBE, then pass (AC-2 / AC-4)"
#
# THE DIRECTION REVERSED IN EPIC-16 WAVE-02 (R5). Through wave-01 this refused and named
# a command for the operator to run by hand — and the Synthesis field report measured
# what that cost: five serialized minutes between deciding to dispatch and the agent
# existing, paid again after every /clear, which re-fires the this-session demand
# mid-wave although nothing about the machine has changed.
#
# A missing attestation is not evidence of a broken environment; it is the absence of
# evidence, and re-reading the fact costs a second and cannot go stale. So the gate takes
# the reading itself. The refusal did not disappear — it MOVED, onto the probe's own
# verdict (S16 drives that half, and the arc end to end).

REPO=$(make_repo r5 yes)
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "no attestation in an active wave no longer refuses" "0" "$GATE_ST"
expect_empty "the auto-probe path produces no stdout" "$GATE_OUT"
expect_absent "…and no refusal is printed" "BLOCKED" "$GATE_ERR"
expect_status "…the attestation it was missing now exists" "0" \
  "$([ -f "$REPO/.bionic/tmp/preflight-$SID_A.state" ] && echo 0 || echo 1)"

# The fix command survives where it still means something — the probe-failure refusal —
# and checklist A1's requirement on it is unchanged: an install-path spelling, runnable
# from any cwd, never this gate itself. Driven here on the one path that still refuses.
REPO=$(make_repo r5b yes)
mkdir -p "$REPO/.bionic/tmp"; chmod 500 "$REPO/.bionic/tmp"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
chmod 700 "$REPO/.bionic/tmp"
expect_contains "a probe-failure refusal still names the install-path fix command" \
  "bash $PROBE_SRC" "$GATE_ERR"
expect_absent "refusal does not name a repo-relative fix command (checklist A1)" "hooks/preflight-probe.sh\"" "$GATE_ERR"
case "$GATE_ERR" in
  *"hooks/dispatch-preflight.sh"*) no "refusal never names itself as the fix" ;;
  *) ok "refusal never names itself as the fix" ;;
esac

section "S6 — active wave + only a FOREIGN session's attestation exists -> AUTO-PROBE (AC-2)"
#
# slice 4/2 (D-5): the foreign attestation is written at ITS OWN per-session filename
# (preflight-<SID_B>.state) — there is no file at all for SID_A, which is exactly what
# "foreign, however fresh, is not an attestation for this session" means once filenames
# are the primary key. That reading is UNCHANGED by R5; what changed is what follows from
# it. A foreign record is still never read as mine — the gate takes my own reading
# instead of refusing, and B's record is left exactly where it was.

REPO=$(make_repo r6 yes)
write_attestation "$REPO" "$SID_B"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "foreign-only attestation auto-probes rather than refusing" "0" "$GATE_ST"
expect_status "…and this session gets a record of its OWN, at its own filename" "0" \
  "$([ -f "$REPO/.bionic/tmp/preflight-$SID_A.state" ] && echo 0 || echo 1)"
expect_status "…while the LIVE foreign session's record is untouched (D-5)" "0" \
  "$([ -f "$REPO/.bionic/tmp/preflight-$SID_B.state" ] && echo 0 || echo 1)"

section "S6b — active wave + BOTH sessions hold valid attestations concurrently (AC-2)"
#
# The D-5 core case: two sessions on one repo, each with its own per-session file. Both
# dispatches pass — session B's attestation existing is neither necessary nor sufficient
# for session A's gate, and vice versa.

REPO=$(make_repo r6b yes)
write_attestation "$REPO" "$SID_A"
write_attestation "$REPO" "$SID_B"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "session A's dispatch passes with both attestations present" "0" "$GATE_ST"
expect_empty "session A's pass produces no stdout" "$GATE_OUT"
run_gate "$(mk_agent_payload "$SID_B" "$REPO")"
expect_status "session B's dispatch ALSO passes with both attestations present" "0" "$GATE_ST"
expect_empty "session B's pass produces no stdout" "$GATE_OUT"

section "S6c — the legacy single-slot file is NEVER consulted (slice 4/2)"
#
# A legacy preflight.state carrying this session's own, perfectly valid-looking
# session_id= must still refuse: only the per-session filename is ever read.

REPO=$(make_repo r6c yes)
write_legacy_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "a legacy single-slot attestation is not consulted; the probe runs instead" "0" "$GATE_ST"
expect_status "…and the record that admits the dispatch is at the PER-SESSION filename" "0" \
  "$([ -f "$REPO/.bionic/tmp/preflight-$SID_A.state" ] && echo 0 || echo 1)"
# The probe prunes the legacy slot on every run — the strongest form of "never consulted"
# is that the file is not there to consult by the time the next dispatch asks.
expect_status "…the legacy slot is gone, not merely ignored" "0" \
  "$([ -f "$REPO/.bionic/tmp/preflight.state" ] && echo 1 || echo 0)"

section "S7 — active wave + attestation IS this session -> pass, verdict silent (AC-2)"
#
# "Silent" here is about the VERDICT (no BLOCKED refusal, nothing on stdout ever) — not
# absolute stderr silence, which S10c's absence warning already established is not the
# invariant. Since the unarmed-sweeper nag was deleted with the watcher (epic-16 w2 S1) a
# contract-complete fixture like this one has nothing to say on stderr either, and that is
# asserted directly below rather than left implied.

REPO=$(make_repo r7 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "matching attestation exits 0" "0" "$GATE_ST"
expect_empty "matching attestation produces no stdout (never print on the allow path)" "$GATE_OUT"
expect_absent "matching attestation prints no BLOCKED refusal on stderr" "BLOCKED" "$GATE_ERR"
expect_absent "…and says nothing about a sweeper being armed (the nag is deleted)" \
  "sweeper" "$GATE_ERR"

# forward-compatibility (A6): unknown extra fields, reordered, must still
# read the session_id BY KEY, not by position — mirrors
# preflight-probe.test.sh's own reorder case. Written at the PER-SESSION path.
REPO=$(make_repo r7b yes)
mkdir -p "$REPO/.bionic/tmp"
printf 'unknown_future_field=x\nsession_id=%s\nversion=1\nrepo=%s\n' "$SID_A" "$REPO" \
  > "$REPO/.bionic/tmp/preflight-$SID_A.state"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "reordered/extended attestation with a matching key still passes" "0" "$GATE_ST"
expect_empty "reordered/extended pass produces no stdout" "$GATE_OUT"

section "S8 — hostile/malformed attestation shapes -> REFUSE, never followed (AC-8-adjacent)"

# attestation path occupied by a directory
REPO=$(make_repo r8a yes)
mkdir -p "$REPO/.bionic/tmp/preflight-$SID_A.state"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "attestation path is a directory -> refuse" "2" "$GATE_ST"

# attestation path is a symlink to a file that DOES contain a matching
# session_id= line — proves the gate never follows it, even when doing so
# would happen to "pass": the wall must not be foolable by planted content.
REPO=$(make_repo r8b yes)
mkdir -p "$REPO/.bionic/tmp"
DECOY="$SANDBOX/decoy-attestation"
printf 'session_id=%s\nversion=1\n' "$SID_A" > "$DECOY"
ln -s "$DECOY" "$REPO/.bionic/tmp/preflight-$SID_A.state"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "attestation path is a symlink -> refuse, not followed" "2" "$GATE_ST"

# S1 (Step-6 security review, slice 4/7): the DIRECTORY levels are guarded too.
# Checking only the file leaves the same class open one level up — a repo
# controls its own `.bionic/` contents, so pointing `.bionic/tmp` (or `.bionic`)
# at a directory holding a valid same-session attestation opens the wall with
# content the repo arranges. §8's load-bearing property is that a hostile repo
# can CLOSE or AIM these walls but never OPEN them, and the sibling gate already
# refuses at both levels (hooks/stop-guard.sh's state_paths(); checklist A3
# names this variant, discharged for the WRITE path only).
for _lvl in .bionic/tmp .bionic; do
  _tag=$(printf '%s' "$_lvl" | tr -d './')
  REPO=$(make_repo "r8d-$_tag" yes)
  ELSEWHERE="$SANDBOX/elsewhere-$_tag/.bionic/tmp"
  mkdir -p "$ELSEWHERE"
  printf 'session_id=%s\nversion=1\nkind=preflight-attestation\n' "$SID_A" \
    > "$ELSEWHERE/preflight-$SID_A.state"
  # THE HOSTILE DIRECTORY CARRIES THE ENGAGEMENT MARKER AS WELL (task-engaged-session).
  # The gate asks `engaged_session` first, and its path runs through the very directory
  # this case redirects — so without a marker on the far side the gate would exit at the
  # switch and the S1 claim (the attestation is not read THROUGH a directory symlink)
  # would be proven by an exit that never reached the attestation at all. Planting it is
  # also the honest shape: engagement is the one artifact whose PRESENCE opens a wall, so
  # a repo that can arrange it can only ever ARM these walls against itself.
  : > "$ELSEWHERE/engaged-$SID_A.state"
  if [ "$_lvl" = ".bionic/tmp" ]; then
    mkdir -p "$REPO/.bionic"
    # make_repo plants a real .bionic/tmp (the Patrol stamp lives there); it has to GO,
    # or `ln -s` lands the link INSIDE it and the hostile shape under test never exists.
    rm -rf "$REPO/.bionic/tmp"
    ln -s "$ELSEWHERE" "$REPO/.bionic/tmp"
  else
    # The whole `.bionic` redirected: the active plan has to travel with it, or
    # the case is vacuous (no wave, nothing to decide).
    cp -R "$REPO/.bionic/docs" "$SANDBOX/elsewhere-$_tag/.bionic/docs"
    rm -rf "$REPO/.bionic"
    ln -s "$SANDBOX/elsewhere-$_tag/.bionic" "$REPO/.bionic"
  fi
  run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
  expect_status "a planted DIRECTORY symlink at ${_lvl} -> refuse, not read through (S1)" \
    "2" "$GATE_ST"
done

# attestation file exists but is empty / has no session_id= line at all. Unlike the
# hostile shapes above, this is not an attack — it is an unreadable fact, which R5 treats
# as no fact at all: the probe re-takes it and overwrites the unreadable record. The
# security property is untouched, because the two are distinguished by WHO fixes them —
# a symlink is refused by the probe, a bad record is replaced by it.
REPO=$(make_repo r8c yes)
mkdir -p "$REPO/.bionic/tmp"
printf 'version=1\nkind=preflight-attestation\n' > "$REPO/.bionic/tmp/preflight-$SID_A.state"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "attestation with no session_id= line -> re-taken, not refused" "0" "$GATE_ST"
expect_status "…and the unreadable record is replaced by a keyed one" "0" \
  "$(grep -qx "session_id=$SID_A" "$REPO/.bionic/tmp/preflight-$SID_A.state" && echo 0 || echo 1)"

section "S9 — the fix command is runnable from a NON-REPO cwd (checklist A1)"

# The fix line now lives on the surviving refusal — a probe that FAILED — rather than on
# a missing attestation, which the gate takes for itself (S5). What A1 asks of it is
# unchanged: whatever command the refusal hands an operator has to run from wherever they
# are standing, which a repo-relative spelling does not.
REPO=$(make_repo r9 yes)
mkdir -p "$REPO/.bionic/tmp"; chmod 500 "$REPO/.bionic/tmp"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
chmod 700 "$REPO/.bionic/tmp"
# THE FIX LINE AS THE GATE ACTUALLY PRINTED IT, never a grep for the spelling we
# hope to find. The old form was `grep -oF "bash $PROBE_SRC"`, which could only ever
# yield the exact absolute command or nothing at all — so the one defect A1 exists to
# catch, a repo-relative spelling, made FIXLINE EMPTY, `bash -c ""` exited 0 with no
# stderr, and all three assertions below passed over a run that never happened. The
# extractor pinned away the property under test (.claude memory:
# fixtures-can-pin-away-the-test); proven vacuous by mutation in epic-18 W3 4/2, where
# rewriting PREFLIGHT_CMD to `bash preflight-probe.sh` flipped nothing.
# Lifting the gate's own text lets a relative spelling reach the execution below.
FIXLINE=$(printf '%s\n' "$GATE_ERR" | sed -n 's/.*re-run by hand: \(.*\))\..*/\1/p' | head -1)
# The extractor's own non-emptiness, positive, on the same fixture — without it the
# three assertions below are again a test of nothing (authoring rule: prove the
# extractor before asserting an absence through it).
expect_contains "a fix line was captured to execute" "preflight-probe.sh" "$FIXLINE"

# A throwaway HOME, so executing the captured fix line cannot touch the real one. Since
# epic-17 W1 S3 the fix line resolves the probe beside the GATE rather than under $HOME, so
# the installed copy below is no longer what makes the line runnable — it stays as the
# hostile case: a stale ~/.claude/hooks/ copy that the fix line must NOT be reaching for.
RUNHOME="$SANDBOX/run9/home"
mkdir -p "$RUNHOME/.claude/hooks"
cp "$PROBE_SRC" "$RUNHOME/.claude/hooks/preflight-probe.sh"
chmod +x "$RUNHOME/.claude/hooks/preflight-probe.sh"

NONREPO_CWD="$SANDBOX/run9/nowhere"
mkdir -p "$NONREPO_CWD"

RUN9_OUT="$SANDBOX/run9.out"; RUN9_ERR="$SANDBOX/run9.err"
( cd "$NONREPO_CWD" && env -i \
    HOME="$RUNHOME" PATH="$PATH" \
    CLAUDE_CONFIG_DIR="$RUNHOME/.claude" \
    CLAUDE_CODE_SESSION_ID="$SID_A" \
    ANTHROPIC_API_KEY="sk-fixture-marker" \
    bash -c "$FIXLINE" ) >"$RUN9_OUT" 2>"$RUN9_ERR"
RUN9_ST=$?

# 127 = command not found, 126 = found but not executable — exactly the
# failure shapes a repo-relative fix command produces from a foreign cwd.
if [ "$RUN9_ST" -eq 127 ] || [ "$RUN9_ST" -eq 126 ]; then
  no "fix command runs from a non-repo cwd" "exit $RUN9_ST (not found/not executable): $(cat "$RUN9_ERR")"
else
  ok "fix command runs from a non-repo cwd"
fi
# `$RUN9_ERR` is the PATH of the capture file; these two used to pass it as the
# HAYSTACK, so they asked whether the string "/tmp/.../run9.err" contains "No such
# file or directory" — which it never can, on any run, however broken. Both were
# vacuous from birth; proven so in epic-18 W3 4/2, where pointing the fix command at
# a file that does not exist (exit 127, that exact message on stderr) flipped neither.
# The arm above already reads the CONTENTS, via `$(cat "$RUN9_ERR")`; these now do too.
RUN9_ERR_TEXT="$(cat "$RUN9_ERR")"
expect_absent "fix-command run produces no 'No such file or directory'" "No such file or directory" "$RUN9_ERR_TEXT"
expect_absent "fix-command run produces no 'command not found'" "command not found" "$RUN9_ERR_TEXT"

section "S10 — the roster row is written on the pass path (AC-1, launch half)"
#
# Governing design: spec §Design "Roster" + §Component boundaries. The row is
# appended at launch with status `intended`; the full agent id and `confirmed`
# are slice 4/4's, not this one's.

REPO=$(make_repo r10 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
R10=$(roster_path "$REPO" "$SID_A")

expect_status "a contract-complete dispatch still passes (verdict unchanged)" "0" "$GATE_ST"
expect_empty "a contract-complete dispatch still prints nothing on stdout" "$GATE_OUT"
# The invariant this row protects is "no BLOCKED refusal", asserted directly. Since the
# unarmed-sweeper nag was deleted with the watcher there is nothing else on this stream for
# a contract-complete dispatch either.
expect_absent "a contract-complete dispatch prints no BLOCKED refusal on stderr" "BLOCKED" "$GATE_ERR"
expect_absent "…and nothing about an unarmed sweeper" "sweeper" "$GATE_ERR"
expect_status "the roster file exists at the per-session path" "0" "$([ -f "$R10" ] && echo 0 || echo 1)"
expect_contains "the roster carries a versioned schema header" "roster-state/v1" "$(head -1 "$R10" 2>/dev/null)"
expect_status "exactly one row was appended" "1" "$(roster_rows "$R10")"

ROW=$(roster_nth_row "$R10" 1)
expect_contains "the row's leading field is the schema version" "roster-state/v1" "$(printf '%s' "$ROW" | cut -d'|' -f1)"
expect_status "row status is 'intended'" "intended" "$(roster_field "$ROW" status)"
expect_status "row carries this session's id" "$SID_A" "$(roster_field "$ROW" session)"
expect_status "row carries the agent name from tool_input" "w99-impl" "$(roster_field "$ROW" name)"
expect_status "row carries subagent_type from tool_input" "implementor" "$(roster_field "$ROW" subagent_type)"
expect_status "row carries the model from tool_input" "claude-sonnet-5" "$(roster_field "$ROW" model)"
expect_status "row carries the tool_use_id (the recorder's correlation key)" \
  "toolu_018jyjgop7KMxP6yKtoAWWtB" "$(roster_field "$ROW" tool_use_id)"
expect_status "row's agent_id is empty at launch (slice 4/4 fills it)" "" "$(roster_field "$ROW" agent_id)"

LAUNCHED=$(roster_field "$ROW" launched_at)
if printf '%s' "$LAUNCHED" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  ok "row carries a UTC ISO launch timestamp"
else
  no "row carries a UTC ISO launch timestamp" "got '$LAUNCHED'"
fi

# contract state, lifted from the brief's labeled fields
expect_status "row lifts the deliverable path from 'Expected artifact:'" \
  ".bionic/docs/record/w99-widget.txt" "$(roster_field "$ROW" deliverable)"
expect_contains "row lifts the expected duration" "25" "$(roster_field "$ROW" duration)"
expect_status "row lifts the progress path from 'Progress artifact:'" \
  ".bionic/tmp/w99-widget.progress" "$(roster_field "$ROW" progress)"
expect_status "no contract field is recorded absent for a complete brief" "" "$(roster_field "$ROW" absent)"

section "S10b — the compact one-line label grammar is lifted too (AC-1)"
#
# Real briefs put two labels on one line ("Expected duration: ~35 minutes.
# Progress: append to <path> per stage") — see the exemplar at
# .bionic/docs/record/w2-ac3-run.md. A line-scoped extractor would swallow the
# second label into the first's value; the span must end at the NEXT LABEL, not
# at the newline.

BRIEF_COMPACT='Slice 4/4 of epic-99 wave-01; build · audited · wave.
Deliverables: (1) one commit `feat(x): thing (epic-99 w1 slice 4/4)`; (2) record/w99-two.txt, verbatim.
Expected duration: ~35 minutes. Progress: append to .bionic/tmp/w99-two.progress per stage.
Exit: both deliverables exist.
Suites: tests/widget.test.sh'

REPO=$(make_repo r10b yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_COMPACT" "w99-two")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "compact grammar: the dispatch passes" "0" "$GATE_ST"
expect_contains "compact grammar: deliverable lifted from 'Deliverables:'" \
  "record/w99-two.txt" "$(roster_field "$ROW" deliverable)"
expect_contains "compact grammar: duration lifted, not swallowed by the next label" \
  "35" "$(roster_field "$ROW" duration)"
expect_absent "compact grammar: the duration value stops at the next label" \
  "Progress" "$(roster_field "$ROW" duration)"
expect_status "compact grammar: progress path lifted from a mid-line 'Progress:'" \
  ".bionic/tmp/w99-two.progress" "$(roster_field "$ROW" progress)"
# "4/4" inside the commit subject is slash-bearing but not a path; a lifted
# deliverable list containing it would mean the extractor is matching fractions.

section "S10c — a missing NON-deliverable field is RECORDED + WARNED, never blocked (AC-1)"
#
# Spec §Component boundaries: "Extraction failure warns and records absence —
# starts fail open (TDD §7)." The verdict is the load-bearing assertion here: a
# brief missing everything BUT its deliverable is a warning, not a refusal.
#
# The deliverable is the one field that escaped this rule (S10W): a dispatch
# that names none is refused outright. So this fixture carries a deliverable and
# nothing else — which is also what keeps the two directions honest, since a
# brief carrying no fields at all now never reaches the roster to be warned about.

REPO=$(make_repo r10c yes)
write_attestation "$REPO" "$SID_A"
# The label sits on its OWN line (R8: final-audit A-1 pinned the deliverable-kind
# labels to line start) — a trailing mid-line occurrence would no longer register
# as a hit at all, and this fixture is meant to test the near-fieldless-brief
# warning path, not the line-start rule.
run_gate "$(mk_agent_payload "$SID_A" "$REPO" \
  "Go and do the thing, please.
Expected artifact: .bionic/docs/record/w99-min.txt
Suites: tests/widget.test.sh" "-" "-")"
R10C=$(roster_path "$REPO" "$SID_A")
ROW=$(roster_nth_row "$R10C" 1)

expect_status "a brief with only its deliverable still PASSES the gate" "0" "$GATE_ST"
expect_empty "the absence warning never goes to stdout" "$GATE_OUT"
expect_contains "the absence is warned on stderr" "WARN" "$GATE_ERR"
expect_contains "the warning names the duration field" "duration" "$GATE_ERR"
expect_contains "the warning names the progress field" "progress" "$GATE_ERR"
expect_absent "the warning is not phrased as a refusal" "BLOCKED" "$GATE_ERR"
expect_status "the row is still appended for a near-fieldless brief" "1" "$(roster_rows "$R10C")"
ABSENT=$(roster_field "$ROW" absent)
expect_contains "the row records the duration absence" "duration" "$ABSENT"
expect_contains "the row records the progress absence" "progress" "$ABSENT"
expect_contains "the row records the missing agent name" "name" "$ABSENT"
expect_absent "the deliverable it DID name is not recorded absent" "deliverable" "$ABSENT"
expect_status "the absent contract field is empty in the row, not fabricated" "" "$(roster_field "$ROW" duration)"
# An OMITTED model is not an absence finding — the Agent tool inherits the
# orchestrator's model when none is given, so a warning here would fire on the
# ordinary case and train the operator to read past the real ones.
expect_absent "an omitted model is NOT recorded as an absence" "model" "$ABSENT"

section "S10W — a brief naming NO deliverable is REFUSED; the in-brief waiver is the only way through"
#
# USER-DIRECTED (epic-15 post-w4): "A wall. It should be a wall." The absence
# warning above was the whole enforcement for the one contract field the rest of
# the machinery cannot work without — the sweeper's landing verdict has nothing to
# stat, and a dispatch that dies quietly leaves nothing behind. So this single
# field escalates from warn to REFUSAL, and every escape from the refusal is a
# line in the brief, which means it lands on the roster.
#
# Everything else stays exactly where it was: progress absence warns, duration
# absence warns. This is one wall, not a policy.

BRIEF_NO_DELIVERABLE='Your slice: go and do the thing, please.
Expected duration: ~25 minutes.
Progress artifact: .bionic/tmp/w99-nodeliv.progress
Suites: tests/widget.test.sh'

REPO=$(make_repo r10w yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_NO_DELIVERABLE" "w99-nodeliv")"

expect_status "a dispatch whose brief names no deliverable is REFUSED" "2" "$GATE_ST"
expect_empty "the refusal never goes to stdout" "$GATE_OUT"
expect_contains "the refusal is phrased as a block" "BLOCKED" "$GATE_ERR"
expect_contains "the refusal names the field that is missing" "names no deliverable" "$GATE_ERR"
expect_contains "the refusal shows a label that lifts one" "Expected artifact:" "$GATE_ERR"
expect_contains "the refusal names the waiver escape verbatim" "Deliverable-waiver:" "$GATE_ERR"
# The wrong fix would be the environment attestation's — this refusal is a
# different one and must not send the operator to re-run the probe.
expect_absent "the refusal does not name the attestation fix command" "preflight-probe.sh" "$GATE_ERR"
expect_status "a refused dispatch writes no roster row" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# ---- deliverable PRESENT: wholly unaffected ----
REPO=$(make_repo r10w2 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-hasdeliv")"
expect_status "a brief that names a deliverable is not touched by the wall" "0" "$GATE_ST"
expect_absent "…and prints no refusal" "BLOCKED" "$GATE_ERR"
expect_status "…and is journalled as before" "1" "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"

# ---- progress absence stays WARN-ONLY: only the deliverable escalated ----
BRIEF_NO_PROGRESS='Your slice: build the widget.
Expected artifact: .bionic/docs/record/w99-noprog.txt
Expected duration: ~25 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r10w3 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_NO_PROGRESS" "w99-noprog")"
expect_status "an absent PROGRESS path still passes — only the deliverable escalated" "0" "$GATE_ST"
expect_contains "…and is still warned" "progress" "$GATE_ERR"
expect_absent "…and is never phrased as a refusal" "BLOCKED" "$GATE_ERR"

# ---- the waiver: refusal becomes a warning that echoes the reason ----
BRIEF_WAIVED='Your slice: answer one question from the tree; nothing durable is produced.
Deliverable-waiver: read-only reconnaissance, the answer is the report itself
Expected duration: ~10 minutes.
Progress artifact: .bionic/tmp/w99-waived.progress
Suites: tests/widget.test.sh'

REPO=$(make_repo r10w4 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_WAIVED" "w99-waived")"
R10W4=$(roster_path "$REPO" "$SID_A")
ROW=$(roster_nth_row "$R10W4" 1)

expect_status "an in-brief waiver converts the refusal into a pass" "0" "$GATE_ST"
expect_absent "a waived dispatch prints no refusal" "BLOCKED" "$GATE_ERR"
expect_contains "the waiver is echoed on stderr, so it is never silent" \
  "read-only reconnaissance, the answer is the report itself" "$GATE_ERR"
expect_contains "the echo is a warning, not a verdict" "WARN" "$GATE_ERR"
expect_status "the waived dispatch is journalled" "1" "$(roster_rows "$R10W4")"
expect_status "the row LEDGERS the waiver reason — every waiver is on the record" \
  "read-only reconnaissance, the answer is the report itself" "$(roster_field "$ROW" waiver)"
# The waiver excuses the refusal; it does not make the fact untrue.
expect_contains "the row still records the deliverable as absent" \
  "deliverable" "$(roster_field "$ROW" absent)"
expect_status "…and fabricates no deliverable path" "" "$(roster_field "$ROW" deliverable)"
# The waiver value must stop where the next labelled field starts.
expect_absent "the waiver reason does not swallow the field after it" \
  "10 minutes" "$(roster_field "$ROW" waiver)"

# ---- a waiver with no reason is not a waiver ----
BRIEF_EMPTY_WAIVER='Your slice: do the thing.
Deliverable-waiver:
Expected duration: ~10 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r10w5 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_EMPTY_WAIVER" "w99-emptywaiver")"
expect_status "a reasonless waiver does not open the wall" "2" "$GATE_ST"
expect_contains "…and the refusal still names the escape" "Deliverable-waiver:" "$GATE_ERR"

# ---- the ordinary brief records no waiver ----
REPO=$(make_repo r10w6 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-nowaiver")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "a brief that waives nothing carries an empty waiver field" \
  "" "$(roster_field "$ROW" waiver)"
expect_absent "…and no waiver is echoed for it" "waived" "$GATE_ERR"

section "S10L — the LIVENESS fields are lifted: cadence + the subprocess claim (6-axis A-1)"
#
# The ratified liveness contract shipped into skills/canonical-sdlc/SKILL.md
# §Dispatch in slice 4/7 — "The progress-artifact path carries a `cadence`
# alongside it" and "A subprocess claim — a process pattern plus its output file
# — is conditional-required". The Step-6 six-axis review found the procedure
# layer instructing authors to declare two fields this writer had no extraction
# site for, with hooks/stop-check.sh:389 already READING `claims=` off the row
# (axis-3 FAIL: a shipped reader with no producer). These cases are the writer
# half of that closure; tests/stop-check.test.sh §8(g) drives the reader half
# over a row THIS gate really wrote.
#
# GRAMMAR, stated because it is the one place this extractor reads a value that
# is not a path and not free text: `cadence` may be introduced by a colon OR by
# whitespace alone, because the ratified sentence puts it "alongside" the
# progress path inside one sentence rather than on a labeled line of its own.
# The subprocess claim's PATTERN is the backticked/quoted run when the author
# marks one, else the text up to the first comma or arrow; the output file half
# is the path the same span carries.

BRIEF_LIVENESS='Canonical-sdlc Step 4, slice 4/10 of epic-99 wave-01; build · audited · wave.
Your slice: the widget, behind the existing seam.
Expected artifact: .bionic/docs/record/w99-live.txt
Expected duration: ~50 minutes. Progress: .bionic/tmp/w99-live.progress, cadence ~6m.
Subprocess claim: `bash tests/run.sh` → .bionic/tmp/w99-suite.log
Exit condition: the artifact exists and the suite is green.
Suites: tests/widget.test.sh'

REPO=$(make_repo r10L yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_LIVENESS" "w99-live")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)

expect_status "liveness brief: the dispatch passes" "0" "$GATE_ST"
expect_status "the row lifts the cadence declared beside the progress path" \
  "~6m." "$(roster_field "$ROW" cadence)"
expect_status "the row lifts the subprocess claim's PATTERN, backticks stripped" \
  "bash tests/run.sh" "$(roster_field "$ROW" claims)"
expect_status "the progress path still stops at the cadence that follows it" \
  ".bionic/tmp/w99-live.progress" "$(roster_field "$ROW" progress)"
# THE REWRITTEN ASSERTION (Step-6 critic N-2). The line here used to read
#   expect_absent "the cadence value stops at the next label" "Subprocess" …
# which certified a property that was never under threat — the span was ALWAYS
# bounded by the next label — while the real defect (a value running ON past its
# own duration token, on its own line, before any label) went undriven and the
# green masked it. The property that matters is that cadence carries the token
# and NOTHING after it; the run-on case below drives the shape the production
# writer actually emits, and this pins the no-run-on baseline exactly.
expect_status "cadence carries the duration token and no run-on (real property, N-2)" \
  "~6m." "$(roster_field "$ROW" cadence)"
expect_status "the duration is unharmed by the new labels" \
  "~50 minutes." "$(roster_field "$ROW" duration)"

# ---- THE RUN-ON case (Step-6 critic N-2, C-1/F-3 root): cadence followed by
# run-on NON-label prose on the SAME line must still lift a bounded token. This
# is the shape the production writer emitted onto the live roster
# (w2-t3-victim2: `cadence=2m) claims=…`) — the field-merge that flipped a
# visibly-alive agent to UNMET by feeding parse_seconds a value it refuses. The
# defect is NOT rescued by a following label: the run-on sits BEFORE the label,
# already inside the value. Bounded extraction stops at the first clause
# boundary (comma / closing bracket / newline), the same restraint claimpat()
# already applies to the subprocess pattern.
BRIEF_CADENCE_RUNON='Canonical-sdlc Step 4, slice 4/12 of epic-99 wave-01; build · audited · wave.
Your slice: the widget behind the seam.
Expected artifact: .bionic/docs/record/w99-runon.txt
Expected duration: ~50 minutes.
Progress: .bionic/tmp/w99-runon.progress, cadence 2m) claims=w99-marker,/var/tmp/f3 and keep going
Exit condition: the artifact exists.
Suites: tests/widget.test.sh'

REPO=$(make_repo r10Lrunon yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_CADENCE_RUNON" "w99-runon")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "run-on cadence: the dispatch passes" "0" "$GATE_ST"
expect_status "run-on cadence: the value is the bounded token, not the swallowed line" \
  "2m" "$(roster_field "$ROW" cadence)"
expect_absent "run-on cadence: the swallowed 'claims=' text never enters the cadence field" \
  "claims=" "$(roster_field "$ROW" cadence)"
expect_absent "run-on cadence: nor does the swallowed path" \
  "/var/tmp/f3" "$(roster_field "$ROW" cadence)"
# The same bounded discipline protects duration from a run-on sentence (A-2:
# an unreadable duration silently exempts a row from overdue notification forever).
BRIEF_DURATION_RUNON='Your slice: build it.
Expected artifact: .bionic/docs/record/w99-durrunon.txt
Expected duration: ~15 minutes. Every verbatim output you quote is its own evidence, laid out.
Progress: .bionic/tmp/w99-durrunon.progress
Suites: tests/widget.test.sh'
REPO=$(make_repo r10Ldur yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_DURATION_RUNON" "w99-durrunon")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "run-on duration: the value stops at the end of its own sentence" \
  "~15 minutes." "$(roster_field "$ROW" duration)"
expect_absent "run-on duration: the following sentence never enters the field" \
  "verbatim" "$(roster_field "$ROW" duration)"

# The colon form and the unquoted comma form — the two other shapes the ratified
# sentence permits an author to write.
#
# The claim line reads `Subprocess claim:` rather than the bare `Claims:` this
# fixture used until the Step-6 critic (F-2). That bare label was withdrawn from
# the grammar because it also matched "verify every claim the report claims:" in
# an ordinary review brief and invented a subprocess from it. The two properties
# this case exists for are untouched by the respelling — a cadence introduced by
# a colon on its own line, and an unquoted pattern that stops at the comma before
# its output file — and the vocabulary it now uses is the contract's own.
BRIEF_LIVENESS2='Slice 4/11 of epic-99 wave-01.
Deliverables: record/w99-b.txt
Expected duration: ~40 minutes.
Progress: .bionic/tmp/w99-b.progress
Cadence: every 5 minutes
Subprocess claim: pgrep-me-w99, output .bionic/tmp/w99-b.log
Exit: the deliverable exists.
Suites: tests/widget.test.sh'

REPO=$(make_repo r10L2 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_LIVENESS2" "w99-live2")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "the colon form of cadence lifts too" \
  "every 5 minutes" "$(roster_field "$ROW" cadence)"
expect_status "an unquoted claim pattern stops at the comma before its output file" \
  "pgrep-me-w99" "$(roster_field "$ROW" claims)"

# CONDITIONAL-REQUIRED, both directions: a brief that declares neither field
# leaves both EMPTY rather than fabricating one, and — because the subprocess
# claim is declared only when the task backgrounds a long command — its absence
# is never an absence FINDING. The whole point of the contract is that shape
# emerges from which fields are present.
REPO=$(make_repo r10L3 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-noclaim")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "a brief with no subprocess claim leaves claims= empty, not fabricated" \
  "" "$(roster_field "$ROW" claims)"
expect_status "a brief with no cadence leaves cadence= empty" "" "$(roster_field "$ROW" cadence)"
expect_absent "an undeclared subprocess claim is NOT an absence finding" \
  "claims" "$(roster_field "$ROW" absent)"

# THE NEGATIVE DIRECTION, which is the one that was missing (Step-6 critic F-2).
# Every case above declares a liveness contract and checks it is read correctly.
# None checked the far more common brief that declares NONE and merely uses one
# of the words in prose — and both labels fabricated a declaration from it.
#
# Fabrication is not neutral noise here. Under the ratified contract
# (skills/canonical-sdlc/SKILL.md) field PRESENCE is the shape key — "shape
# emerges from which are present… adding a subprocess claim is a delegated
# command" — and a claims= value opens a `-- claimed process (P2) --` section
# whose pgrep finds nothing and prints `live: no`, the ALARM direction. So a
# brief that says "keep a steady cadence" was classified long-shape and armed a
# quiescence watcher, and one that says "verify every claim" grew a phantom
# subprocess. Both briefs below are verbatim from the critic's repro
# (.bionic/docs/record/w3-critic-repro-lift.sh, briefs C and D).
BRIEF_PROSE_CADENCE='Your slice: write the report.
Deliverables: .bionic/docs/record/w99.md
Expected duration: ~40 minutes.
Progress: .bionic/tmp/w99.progress, a line per section.
Scope constraint: keep a steady cadence and do not batch the sections.
Exit: report written.
Suites: tests/widget.test.sh'

REPO=$(make_repo r10L4 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_PROSE_CADENCE" "w99-prose1")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "the word 'cadence' in ordinary prose declares no cadence" \
  "" "$(roster_field "$ROW" cadence)"
# …and the fix is not a blunt one: the fields this brief DOES declare still lift.
expect_status "…while the progress path the same brief declares still lifts" \
  ".bionic/tmp/w99.progress" "$(roster_field "$ROW" progress)"
expect_status "…and its duration" "~40 minutes." "$(roster_field "$ROW" duration)"

BRIEF_PROSE_CLAIMS='Your slice: audit the report.
Deliverables: .bionic/docs/record/audit.md
Expected duration: ~20 minutes.
Progress: .bionic/tmp/audit.progress, a line per claim checked.
Scope constraint: verify every claim the report claims: proof or the label unverified.
Exit: audit written.
Suites: tests/widget.test.sh'

REPO=$(make_repo r10L5 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_PROSE_CLAIMS" "w99-prose2")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "a brief that REVIEWS claims declares no subprocess claim" \
  "" "$(roster_field "$ROW" claims)"
expect_status "…and grows no cadence either" "" "$(roster_field "$ROW" cadence)"
expect_status "…while its own progress path is still read" \
  ".bionic/tmp/audit.progress" "$(roster_field "$ROW" progress)"

# The cadence rule stated as the rule it is: the word only declares a cadence
# where the contract puts it — beside the progress path — so the SAME word in the
# SAME brief lifts or does not lift depending on where it falls.
BRIEF_CADENCE_PLACE='Your slice: build it.
Deliverables: .bionic/docs/record/w99.md
Expected duration: ~40 minutes.
Progress: .bionic/tmp/w99.progress, cadence ~9m.
Scope constraint: keep a steady cadence throughout.
Exit: built.
Suites: tests/widget.test.sh'

REPO=$(make_repo r10L6 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_CADENCE_PLACE" "w99-place")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "the cadence beside the progress path is the one that counts" \
  "~9m." "$(roster_field "$ROW" cadence)"

section "S10d — rows APPEND; the roster is a ledger, not a slot"

REPO=$(make_repo r10d yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "first-agent")"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "second-agent")"
R10D=$(roster_path "$REPO" "$SID_A")
expect_status "two dispatches leave two rows" "2" "$(roster_rows "$R10D")"
expect_status "the first row survives the second dispatch" "first-agent" "$(roster_field "$(roster_nth_row "$R10D" 1)" name)"
expect_status "the second row is the second dispatch" "second-agent" "$(roster_field "$(roster_nth_row "$R10D" 2)" name)"
expect_status "the schema header is written once, not per row" "1" \
  "$(grep -c '^# bionic session roster' "$R10D")"

section "S10e — the roster is per-session from birth (D-5)"

REPO=$(make_repo r10e yes)
write_attestation "$REPO" "$SID_A"
write_attestation "$REPO" "$SID_B"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "agent-of-A")"
run_gate "$(mk_agent_payload "$SID_B" "$REPO" "$BRIEF_FULL" "agent-of-B")"
RA=$(roster_path "$REPO" "$SID_A"); RB=$(roster_path "$REPO" "$SID_B")
expect_status "session A has its own roster file" "0" "$([ -f "$RA" ] && echo 0 || echo 1)"
expect_status "session B has its own roster file" "0" "$([ -f "$RB" ] && echo 0 || echo 1)"
expect_status "session A's roster holds only A's launch" "1" "$(roster_rows "$RA")"
expect_status "session B's roster holds only B's launch" "1" "$(roster_rows "$RB")"
expect_status "A's row is A's agent" "agent-of-A" "$(roster_field "$(roster_nth_row "$RA" 1)" name)"
expect_status "B's row is B's agent" "agent-of-B" "$(roster_field "$(roster_nth_row "$RB" 1)" name)"
expect_status "no shared single-slot roster.state was created" "1" \
  "$([ -f "$REPO/.bionic/tmp/roster.state" ] && echo 0 || echo 1)"

section "S10f — dead-session rosters are pruned, LIVE foreign ones are not (D-5)"
#
# Same liveness rule slice 4/2 established for the attestation
# (hooks/preflight-probe.sh: a session is live iff its transcript still exists
# somewhere under CLAUDE_CONFIG_DIR/projects). A live foreign session's roster
# surviving another session's dispatch IS the concurrency D-5 exists for.

SID_DEAD="deadfeed-0000-4000-8000-000000000001"
SID_LIVE="1ivefeed-0000-4000-8000-000000000002"
CFG="$SANDBOX/cfg10f/.claude"
mkdir -p "$CFG/projects/-some-project"
: > "$CFG/projects/-some-project/$SID_LIVE.jsonl"
: > "$CFG/projects/-some-project/$SID_A.jsonl"
# SID_DEAD deliberately has NO transcript anywhere.

REPO=$(make_repo r10f yes)
write_attestation "$REPO" "$SID_A"
mkdir -p "$REPO/.bionic/tmp"
# THE PRUNE READS THE PREFIX, so the fixture is a prefix (tests/lib/roster-row.sh's
# `roster_row_prefix_only`, S14): what decides here is whether the FILE survives, and the
# row exists only to make the file a roster the reader recognises.
{ roster_header; roster_row_prefix_only status=intended "session=$SID_DEAD" name=ghost; } \
  > "$(roster_path "$REPO" "$SID_DEAD")"
{ roster_header; roster_row_prefix_only status=intended "session=$SID_LIVE" name=neighbour; } \
  > "$(roster_path "$REPO" "$SID_LIVE")"

GATE_CONFIG_DIR="$CFG"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
probe_env_on   # restore the file-wide sandbox, never the operator's own config dir

expect_status "the dispatch still passes while pruning" "0" "$GATE_ST"
expect_status "a DEAD session's roster is pruned" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_DEAD")" ] && echo 0 || echo 1)"
expect_status "a LIVE foreign session's roster is left untouched" "0" \
  "$([ -f "$(roster_path "$REPO" "$SID_LIVE")" ] && echo 0 || echo 1)"
expect_contains "the live foreign roster's content is unmodified" "neighbour" \
  "$(cat "$(roster_path "$REPO" "$SID_LIVE")" 2>/dev/null)"
expect_status "our own roster was written" "1" "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"
# The prune must not reach across artifacts: the attestation files share the
# same directory and the same per-session scheme.
expect_status "the prune leaves attestations alone" "0" \
  "$([ -f "$REPO/.bionic/tmp/preflight-$SID_A.state" ] && echo 0 || echo 1)"

section "S10g — a roster WRITE FAILURE warns and leaves the verdict alone"
#
# TDD §7: starts fail open. The roster is a ledger, not a wall — a gate that
# refused a dispatch because it could not journal it would be a new failure
# mode, not a safety property.

REPO=$(make_repo r10g yes)
write_attestation "$REPO" "$SID_A"
chmod 555 "$REPO/.bionic/tmp"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
chmod 755 "$REPO/.bionic/tmp"
expect_status "an unwritable state dir does not change the PASS verdict" "0" "$GATE_ST"
expect_empty "a write failure prints nothing on stdout" "$GATE_OUT"
expect_contains "a write failure is warned on stderr" "WARN" "$GATE_ERR"
expect_status "no roster file was left behind" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

section "S10h — a symlinked roster path is never written through (§8)"
#
# A hostile repo controls its own .bionic/ contents. It may make this gate fail
# to journal; it must not gain an arbitrary-file append. (The DIRECTORY-level
# variants are already refused upstream by the attestation check — S8 drives
# them — so the file level is the only one reachable here.)

REPO=$(make_repo r10h yes)
write_attestation "$REPO" "$SID_A"
DECOY_ROSTER="$SANDBOX/decoy-roster.txt"
printf 'untouched\n' > "$DECOY_ROSTER"
ln -s "$DECOY_ROSTER" "$(roster_path "$REPO" "$SID_A")"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "a symlinked roster path does not change the PASS verdict" "0" "$GATE_ST"
expect_contains "a symlinked roster path is warned" "WARN" "$GATE_ERR"
expect_status "the symlink target is not appended to" "untouched" "$(cat "$DECOY_ROSTER")"

section "S10i — no row on any path that is not a launch"

# refused dispatch (active wave, the environment probe refuses): the launch never
# happens. The driver moved with the wall itself in epic-16 wave-02 — a missing
# attestation is now taken rather than refused, so the refusal this case needs is the one
# that survived: a blocking probe failure, here an unwritable state directory.
REPO=$(make_repo r10i yes)
mkdir -p "$REPO/.bionic/tmp"; chmod 500 "$REPO/.bionic/tmp"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
chmod 700 "$REPO/.bionic/tmp"
expect_status "a REFUSED dispatch still exits 2" "2" "$GATE_ST"
expect_status "a refused dispatch writes no roster row" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# no active wave: this gate has nothing to decide and nothing to ledger.
REPO=$(make_repo r10i2 no)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "a dispatch outside an active wave exits 0" "0" "$GATE_ST"
expect_empty "a dispatch outside an active wave stays silent" "$GATE_ERR"
expect_status "a dispatch outside an active wave writes no roster" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# a non-Agent tool is not a launch.
REPO=$(make_repo r10i3 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_bash_payload "$SID_A" "$REPO")"
expect_status "a Bash call in an attested active wave writes no roster" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

section "S11 — the unarmed-sweeper nag is GONE (epic-16 w2 slice S1)"
#
# A warn-only nag stood here: it asked the sibling sweeper whether a watcher was live for
# this session and, when none was, named the command to arm one. Both the watcher and its
# `status` verb are deleted, so the nag went with them — supervision reads facts off disk at
# the moment a decision needs them rather than depending on a process staying up.
#
# Pinned as an ABSENCE, in the section that used to drive its presence, for two reasons. A
# nag that names a verb the CLI no longer answers to is worse than no nag: it sends an
# operator to a refusal. And this gate has a standing invariant that the allow path prints
# nothing but ratified advisories — a stale one would be invisible to every other assertion
# here, all of which only ask about BLOCKED.

# ---- no ledger at all: the dispatch passes in SILENCE, where it used to warn ----
REPO=$(make_repo r11a yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "no-ledger dispatch passes" "0" "$GATE_ST"
# expect_absent, not expect_empty (wave-session-bound-run S5): an unbound engaged
# session now gets ONE unrelated advisory line here too (the newest-plan fallback
# notice, S25) — this fixture's own claim was always about the sweeper, never
# about the channel being empty outright.
expect_absent "…in silence: there is no sweeper state left to nag about" "sweeper" "$GATE_ERR"

# ---- a ledger present but naming no live anything: still silent ----
#
# The ledger survives as ack's journal, so this fixture is the shape a real session leaves
# behind. The gate must not read it, or resurrect an opinion about it.
REPO=$(make_repo r11b yes)
write_attestation "$REPO" "$SID_A"
mkdir -p "$REPO/.bionic/tmp"
{
  printf '# bionic session sweeper ledger — schema sweeper-ledger/v1 — machine-local, safe to delete\n'
  printf 'sweeper-ledger/v1|event=ack|at=2026-08-06T00:00:00Z|epoch=1780000000|pid=999999|session=%s|name=some-row\n' \
    "$SID_A"
} > "$REPO/.bionic/tmp/sweeper-$SID_A.state"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "a dispatch over an ack-only ledger passes" "0" "$GATE_ST"
# expect_absent, not expect_empty — see r11a's note just above (S5).
expect_absent "…and still says nothing about it" "sweeper" "$GATE_ERR"

# ---- the gate never names the deleted verbs, and never invokes the sweeper at all ----
GATE_SRC="$(cat "$GATE")"
expect_absent "the gate source names no arm command" "session-sweeper.sh arm" "$GATE_SRC"
expect_absent "…and carries no SWEEPER_ARM_CMD constant" "SWEEPER_ARM_CMD" "$GATE_SRC"
# The stronger claim, and the one that keeps a future nag from growing back through some
# other verb: this gate runs the sweeper on NO path. It writes the roster the verdict later
# reads; it never asks the verdict anything.
expect_status "the gate executes the sweeper on no path at all" "0" \
  "$(printf '%s' "$GATE_SRC" | grep -cE 'bash [^\n]*session-sweeper\.sh')"

# ---- a REFUSED dispatch is unchanged: still exits 2, still says nothing about a sweeper ----
REPO=$(make_repo r11d yes)
mkdir -p "$REPO/.bionic/tmp"; chmod 500 "$REPO/.bionic/tmp"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
chmod 700 "$REPO/.bionic/tmp"
expect_status "a refused dispatch (the probe refused) still exits 2" "2" "$GATE_ST"
expect_absent "a refused dispatch prints no sweeper nag" "session-sweeper.sh" "$GATE_ERR"

section "S12 — inference WITHDRAWN: an unlabeled path never satisfies the wall (R1, AC-3)"
#
# THE REVERSAL (Step-6 decision, plan assumption 48). Wave-02 R4 let an unlabeled
# `record/`-prefixed path satisfy the deliverable wall by INFERENCE — walking the
# whole brief for a path-shaped token. The Step-6 critic (N-1) found the machine
# then enforced that GUESS with a declared fact's full weight: the landing gate
# ordered the agent to write a path the wall picked out of prose. Chris's ruling:
# the wall NEVER guesses a deliverable from prose. A deliverable comes ONLY from a
# canonical label; a brief that declares none REFUSES at dispatch, naming what to
# add. These cases pin the withdrawal: every prose path that used to infer now
# refuses, and only a labeled declaration passes.

# ---- an unlabeled .bionic/docs/record/ mention no longer infers -> REFUSE ----
BRIEF_BARE_RECORD='Your slice: read the tree and note what you find.
It belongs in .bionic/docs/record/w99-bare.md when finished.
Expected duration: ~10 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r12a yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_BARE_RECORD" "w99-bare")"
expect_status "an unlabeled .bionic/docs/record/ mention is REFUSED (no inference)" "2" "$GATE_ST"
expect_contains "…with the absent-deliverable refusal" "names no deliverable" "$GATE_ERR"
expect_status "…and no prose path is lifted onto a roster row" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# ---- a bare record/ prefix in prose is refused the same way ----
BRIEF_BARE_RECORD2='Your slice: capture findings as you go.
Write to record/w99-bare2.md at the end.
Expected duration: ~10 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r12a2 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_BARE_RECORD2" "w99-bare2")"
expect_status "a bare record/ prefix in prose is also REFUSED" "2" "$GATE_ST"
expect_contains "…with the absent-deliverable refusal" "names no deliverable" "$GATE_ERR"

# ---- the same, but DECLARED: adding a canonical label is the whole fix ----
#
# The friction R1 accepts is that a brief must DECLARE its deliverable. The same
# work, with `Expected artifact:` in front of the path, passes and is `declared`.
BRIEF_BARE_DECLARED='Your slice: read the tree and note what you find.
Expected artifact: .bionic/docs/record/w99-bare.md
Expected duration: ~10 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r12a3 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_BARE_DECLARED" "w99-baredecl")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "declaring the same path with a canonical label passes" "0" "$GATE_ST"
expect_status "…and the row carries the declared path" \
  ".bionic/docs/record/w99-bare.md" "$(roster_field "$ROW" deliverable)"
expect_status "…marked declared" "declared" "$(roster_field "$ROW" source)"

# ---- a non-record path in a 'Read first:' is still refused (unchanged) ----
BRIEF_ONLY_READFIRST='Read first: skills/canonical-sdlc/SKILL.md
Expected duration: ~10 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r12b yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_ONLY_READFIRST" "w99-readfirst")"
expect_status "a brief whose only path is a non-record 'Read first:' mention is refused" \
  "2" "$GATE_ST"
expect_contains "…with the deliverable refusal" "names no deliverable" "$GATE_ERR"
expect_status "a refused dispatch writes no roster row" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# ---- an unlabeled .bionic/tmp/ path is refused (a scratch path was never durable) ----
BRIEF_ONLY_TMP='Your slice: write scratch notes to .bionic/tmp/w99-scratch.md as you go.
Expected duration: ~10 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r12c yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_ONLY_TMP" "w99-tmp")"
expect_status "a brief whose only unlabeled path is under .bionic/tmp/ is refused" "2" "$GATE_ST"
expect_contains "…with the deliverable refusal" "names no deliverable" "$GATE_ERR"

# ---- a labeled brief records source=declared; behavior otherwise unchanged ----
REPO=$(make_repo r12d yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-declared")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "a labeled deliverable passes the wall (unchanged)" "0" "$GATE_ST"
expect_status "the row's deliverable is exactly the labeled path" \
  ".bionic/docs/record/w99-widget.txt" "$(roster_field "$ROW" deliverable)"
expect_status "the row marks the source as declared" "declared" "$(roster_field "$ROW" source)"
expect_status "duration is unaffected" \
  "~25 minutes." "$(roster_field "$ROW" duration)"
expect_status "progress is unaffected" \
  ".bionic/tmp/w99-widget.progress" "$(roster_field "$ROW" progress)"

# ---- a LABELED .bionic/tmp/ deliverable keeps today's behavior (label is explicit design) ----
BRIEF_LABELED_TMP='Your slice: report interim status to a scratch file.
Expected artifact: .bionic/tmp/w99-labeledtmp.txt
Expected duration: ~10 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r12e yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_LABELED_TMP" "w99-labeledtmp")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "a LABELED .bionic/tmp/ deliverable still passes the wall (unchanged)" "0" "$GATE_ST"
expect_status "…and is recorded exactly as labeled" \
  ".bionic/tmp/w99-labeledtmp.txt" "$(roster_field "$ROW" deliverable)"
expect_status "…marked declared (the label is explicit designation)" \
  "declared" "$(roster_field "$ROW" source)"

# ---- the refusal text names the declared-only rule, not an inference rule ----
REPO=$(make_repo r12f yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_ONLY_READFIRST" "w99-refusaltext")"
expect_contains "the refusal names a canonical label to add" "Expected artifact:" "$GATE_ERR"
expect_contains "the refusal says the wall never guesses" "never guesses" "$GATE_ERR"
expect_absent "…and no longer promises to infer an unlabeled record/ mention" \
  "inferred automatically" "$GATE_ERR"

# ---- SHADOWED LABEL: an earlier pathless deliverable-kind hit no longer hides a
# later real labeled line — the declared extractor iterates every deliverable hit ----
#
# The live specimen (a real brief false-blocked): a brief quoting landing-verdict
# prose — "…per deliverable:" — ahead of its real "Expected artifact:" line. The
# bare `deliverable` label hits FIRST by position, and its span ("missing=<x> |
# empty=<y>") carries no path. Under R1 the extractor does not stop at the first
# hit; it walks EVERY deliverable-kind hit in order and returns the first that
# yields a path — so the real, later, labeled line is recovered, and recorded
# `declared` because it came from a label, not from a prose scan.
BRIEF_SHADOW_LABEL='UNMET detail lists every failing conjunct, per deliverable:
missing=<x> | empty=<y>

Expected artifact: .bionic/docs/record/w1-specimen.md
Suites: tests/widget.test.sh'

REPO=$(make_repo r12g yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_SHADOW_LABEL" "w1-specimen")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "an earlier pathless 'per deliverable:' hit no longer shadows the real labeled line" \
  "0" "$GATE_ST"
expect_absent "…and prints no refusal" "BLOCKED" "$GATE_ERR"
expect_status "the roster records the real declared deliverable, recovered by iterating hits" \
  ".bionic/docs/record/w1-specimen.md" "$(roster_field "$ROW" deliverable)"
expect_status "the recovered value is DECLARED — it came from a label, not a prose scan" \
  "declared" "$(roster_field "$ROW" source)"

section "S13 — Step-6 review remediation A + R1: C-1/C-2/F-RD, S-1, S-2, S-4"
#
# Holes found by the independent Step-6 reviewers (w1-review-corr-sec.md and, for
# this wave, w2-review-cs.md C-2 + w2-review-rd.md F-RD). Each case below was
# written and run against the PRE-FIX gate first and observed to fail.

# ---------- C-1/F-RD (blocking) — a path the brief tells the agent to READ, or
# merely names in prose, must never become the deliverable. Under R1 the property
# is enforced structurally, not by a label whitelist: the deliverable comes ONLY
# from a canonical label, so an input path (labeled or bare prose) is refused, not
# guessed. This ends the whitelist arms race the critic named — F-RD walked past
# the wave-01 `Read first:`/`scope constraint:` whitelist through a `Context:`
# heading the guard did not know.

BRIEF_READFIRST_RECORD='Please review the design.

Read first: .bionic/docs/record/w1-walk.md and the spec.

Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r13a yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_READFIRST_RECORD" "readerbot")"
expect_status "C-1: a record/ path inside a Read-first span is never the deliverable — the dispatch is refused" \
  "2" "$GATE_ST"
expect_contains "C-1: …with the absent-deliverable refusal" "names no deliverable" "$GATE_ERR"
expect_status "C-1: …and no roster row claims the input as a deliverable" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# The other input-designating label, refused the same way.
BRIEF_SCOPE_RECORD='Your slice: tidy the tree.
Scope constraint: do not touch .bionic/docs/record/context.md.
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r13b yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_SCOPE_RECORD" "scopebot")"
expect_status "C-1: a record/ path inside a Scope-constraint span is never the deliverable either" \
  "2" "$GATE_ST"

# F-RD, EXACT re-materialization: the review's own brief named its inputs under a
# `Context:` heading the wave-01 whitelist did not recognise, and the wall inferred
# the AUDITOR's report as the reviewer's deliverable — the landing gate then ordered
# the reviewer to overwrite an independent audit. Under R1 there is no inference:
# `Context:` is not a canonical deliverable label, so the path is never lifted and
# the dispatch REFUSES, naming what to declare.
BRIEF_CONTEXT_PATH='Your slice: an independent read-and-duplication review.
Context: read the auditor report record/w2-auditor-report.md and the spec first.
Report: your findings belong in record/w2-review-rd.md.
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r13frd yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_CONTEXT_PATH" "w2-rev-rd")"
expect_status "F-RD: a 'Context:' record/ path is NOT lifted as the deliverable — the dispatch is refused" \
  "2" "$GATE_ST"
expect_contains "F-RD: …with the absent-deliverable refusal" "names no deliverable" "$GATE_ERR"
expect_status "F-RD: …and no roster row contracts the reviewer to the auditor's report" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# C-2 (w2-review-cs.md) — the LABELLED span used to take up to four path tokens and
# run on into whatever prose followed, so files the brief named as INPUTS ("while
# you are there, read …"; "do not touch …") were recorded `source=declared` and the
# landing gate demanded all four. R1 answered by taking the FIRST path in the label's
# first sentence; the R6 critic showed that is a guess with a declaration's weight
# (R6-1), so R7 refuses instead: a span yielding more than one path names candidates
# and asks the author which one is theirs. The input paths are still never contracted —
# now because nothing is contracted until the brief is unambiguous.
BRIEF_LABEL_RUNON='Your slice: write the report.
Expected artifact: record/w99-report.md — and while you are there, read record/legacy-notes.md
and do not touch tests/run.sh or .bionic/docs/plans/epic-99-test/wave-01-test.plan.md
Expected duration: ~20 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r13c2 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_LABEL_RUNON" "runonbot")"
expect_status "C-2: a run-on labelled span naming four paths is REFUSED as ambiguous (R7)" \
  "2" "$GATE_ST"
expect_contains "C-2: …the refusal names the declared artifact" \
  "record/w99-report.md" "$GATE_ERR"
expect_contains "C-2: …and the 'read …' input path, so neither is chosen for the author" \
  "record/legacy-notes.md" "$GATE_ERR"
expect_contains "C-2: …and the 'do not touch' suite runner" "tests/run.sh" "$GATE_ERR"
expect_status "C-2: …and no roster row demands any of the four" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# THE PAIRED POSITIVE: the exactly-one rule must not become "declaring is off" — a
# properly DECLARED path outside any input mention still lifts, and this is the
# resubmission the refusal above asks for: the same brief with the input clauses moved
# to their own labeled lines.
BRIEF_LABEL_CLEAN='Your slice: write the report.
Expected artifact: record/w99-report.md
Read first: record/legacy-notes.md
Expected duration: ~20 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r13c3 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_LABEL_CLEAN" "cleanbot")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "C-2 paired positive: a cleanly declared deliverable still passes" "0" "$GATE_ST"
expect_status "C-2 paired positive: …recorded as the declared path" \
  "record/w99-report.md" "$(roster_field "$ROW" deliverable)"
expect_status "C-2 paired positive: …marked declared" "declared" "$(roster_field "$ROW" source)"

# ---------- S-1 (High) — the waiver label lifts only at LINE START, and a
# placeholder-shaped reason is not a reason. One quoted line of documentation
# must not silence the landing contract.

# (a) the reviewer's revsec002 quoter: a real deliverable, and the wall's own
# message quoted mid-sentence. The row must carry NO waiver.
BRIEF_QUOTER='Expected artifact: .bionic/docs/record/quoter-out.md
Expected duration: 20 minutes

Check that the wall message still reads: "Or waive it — Deliverable-waiver: <why this dispatch produces nothing durable>".
Report whether the wording drifted.
Suites: tests/widget.test.sh'

REPO=$(make_repo r13d yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_QUOTER" "quoter")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "S-1: a mid-sentence quoted waiver label lifts NO waiver" \
  "" "$(roster_field "$ROW" waiver)"
expect_absent "S-1: …and nothing is echoed as waived" "waived" "$GATE_ERR"
expect_status "S-1: …the real labeled deliverable is unaffected" \
  ".bionic/docs/record/quoter-out.md" "$(roster_field "$ROW" deliverable)"

# (b) the same quoting with NO deliverable — this is the fail-open the review
# named: one quoted line and the wall opens. The reason quoted here is a REAL
# one, so only the line-start rule can refuse it.
BRIEF_QUOTED_WAIVER='Your slice: check the wall text.
Confirm the message still reads: "Or waive it — Deliverable-waiver: read-only reconnaissance".
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r13e yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_QUOTED_WAIVER" "quoter2")"
expect_status "S-1: a quoted mid-sentence waiver does not open the absent-deliverable wall" \
  "2" "$GATE_ST"
expect_contains "S-1: …the refusal still names the escape" "Deliverable-waiver:" "$GATE_ERR"

# (c) a line-start waiver whose reason is the literal placeholder from the wall
# text is not a reason.
BRIEF_PLACEHOLDER_WAIVER='Your slice: do the thing.
Deliverable-waiver: <why this dispatch produces nothing durable>
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r13f yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_PLACEHOLDER_WAIVER" "placeholder")"
expect_status "S-1: a placeholder-shaped waiver reason does not open the wall" "2" "$GATE_ST"

# CONTROL: a real line-start waiver still lifts, indented or not.
BRIEF_INDENTED_WAIVER='Your slice: answer one question from the tree.
    Deliverable-waiver: read-only reconnaissance, the answer is the report itself
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r13g yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_INDENTED_WAIVER" "waived2")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "S-1 control: an indented line-start waiver with a real reason still lifts" \
  "0" "$GATE_ST"
expect_status "S-1 control: …and is ledgered" \
  "read-only reconnaissance, the answer is the report itself" "$(roster_field "$ROW" waiver)"

# ---------- S-2 (Medium) — a deliverable that resolves outside the repo root is
# refused at dispatch, where it is still fixable. Otherwise the verdict stats
# arbitrary paths and reports their mtime back to the stopping agent.

BRIEF_ESCAPE_REL='Your slice: do the thing.
Expected artifact: ../../../../../../etc/hosts
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r13h yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_ESCAPE_REL" "escaper")"
expect_status "S-2: a ..-escaping deliverable is refused at the dispatch wall" "2" "$GATE_ST"
expect_contains "S-2: …the refusal is phrased as a block" "BLOCKED" "$GATE_ERR"
expect_contains "S-2: …and names the offending path" "../../../../../../etc/hosts" "$GATE_ERR"
expect_status "S-2: …and no roster row is written for it" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

BRIEF_ESCAPE_ABS='Your slice: do the thing.
Expected artifact: /usr/share
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r13i yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_ESCAPE_ABS" "escaper2")"
expect_status "S-2: an absolute out-of-repo deliverable is refused too" "2" "$GATE_ST"
expect_contains "S-2: …and names it" "/usr/share" "$GATE_ERR"

# CONTROL: an in-repo ABSOLUTE path is a perfectly good deliverable and must
# still pass — the check is containment, not a ban on absolute paths.
REPO=$(make_repo r13j yes)
write_attestation "$REPO" "$SID_A"
BRIEF_ABS_INREPO="Your slice: do the thing.
Expected artifact: $REPO/.bionic/docs/record/w99-abs.md
Expected duration: 20 minutes
Suites: tests/widget.test.sh"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_ABS_INREPO" "absbot")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "S-2 control: an in-repo absolute deliverable still passes" "0" "$GATE_ST"
expect_status "S-2 control: …and is recorded verbatim" \
  "$REPO/.bionic/docs/record/w99-abs.md" "$(roster_field "$ROW" deliverable)"

# ---------- S-4 (Low, defence-in-depth) — the payload session_id is shape-checked
# before it is interpolated into any state path.
#
# The escape is only OBSERVABLE if the intermediate directories exist, so the
# fixture creates them; the vulnerability is the unchecked interpolation, not the
# directories. With sid `a/../../rogue`, both the attestation path and the roster
# path resolve to $REPO/.bionic/rogue.state — one level ABOVE the state dir the
# symlink guards protect.
SID_EVIL="a/../../rogue"
REPO=$(make_repo r13k yes)
mkdir -p "$REPO/.bionic/tmp/preflight-a" "$REPO/.bionic/tmp/roster-a"
{
  printf '# bionic environment attestation — machine-local, safe to delete\n'
  printf 'version=1\n'
  printf 'kind=preflight-attestation\n'
  printf 'session_id=%s\n' "$SID_EVIL"
  printf 'written_at=1785790000\n'
  printf 'repo=%s\n' "$REPO"
} > "$REPO/.bionic/rogue.state"
run_gate "$(mk_agent_payload "$SID_EVIL" "$REPO" "$BRIEF_FULL" "evilsid")"
expect_status "S-4: a shape-invalid session_id degrades to a silent pass" "0" "$GATE_ST"
expect_status "S-4: …and NO roster row is written outside the state directory" "0" \
  "$(grep -c '^roster-state/' "$REPO/.bionic/rogue.state" 2>/dev/null)"
expect_absent "S-4: …and the escaped path is never named on stderr" "rogue.state" "$GATE_ERR"

section "S14 — a templated deliverable is not a declaration: it REFUSES (R1)"
#
# The `<slot>` shape has a long lineage. Wave-01 remediation A-b made `ispath()`
# reject any token carrying an unfilled `<…>` slot, so a brief quoting the wall's
# own help text — `Expected artifact: .bionic/docs/record/<name>.md` — could not
# lift a contract nothing would satisfy. Wave-02 R4 then FILLED the slot from the
# agent name and recorded `source=inferred`. R1 withdraws that fill: filling a slot
# from the agent's name is guessing a deliverable, which is exactly what the wall
# must never do. A slot is still not a path (ispath rejects it), so a brief whose
# ONLY deliverable is a template names no concrete path and REFUSES — the author is
# told at dispatch to name it exactly. A real declared line alongside the template
# is still recovered (the extractor iterates every deliverable hit).

BRIEF_QUOTES_HELP='Your slice: check that the wall message still reads right.
It currently says: Fix: name a durable artifact path in the brief —
    Expected artifact: .bionic/docs/record/<name>.md
Report whether the wording drifted.
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r14a yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_QUOTES_HELP" "helpquoter")"
expect_status "a brief whose only deliverable is the help-text template is REFUSED (no fill)" \
  "2" "$GATE_ST"
expect_contains "…with the absent-deliverable refusal" "names no deliverable" "$GATE_ERR"
expect_status "…and no roster row is written at all" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# A quoted template ahead of a REAL labeled line: the real one is recovered (the
# extractor walks every deliverable hit), and the slot never reaches the row.
BRIEF_HELP_THEN_REAL='Your slice: verify the wall text, then write up what you find.
The message reads: Expected artifact: .bionic/docs/record/<name>.md
Expected artifact: .bionic/docs/record/w99-shape2.md
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r14b yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_HELP_THEN_REAL" "helpquoter2")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "a quoted template ahead of a real line does not shadow it" "0" "$GATE_ST"
expect_status "…the row carries the REAL artifact, never the slot" \
  ".bionic/docs/record/w99-shape2.md" "$(roster_field "$ROW" deliverable)"
expect_status "…recorded declared (it came from a label)" "declared" "$(roster_field "$ROW" source)"
expect_absent "…and the slot appears nowhere on the row" "<name>" "$ROW"

# An ordinary labeled deliverable is untouched by any of this.
REPO=$(make_repo r14c yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-stillworks")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "control: an ordinary labeled deliverable is unaffected" \
  ".bionic/docs/record/w99-widget.txt" "$(roster_field "$ROW" deliverable)"
expect_status "…and is still marked declared" "declared" "$(roster_field "$ROW" source)"

# A templated PROGRESS path is also not filled — progress is advisory (absent
# warns), so a template that names no concrete path leaves it EMPTY and WARNED,
# exactly as a missing one is. The real deliverable is unaffected.
BRIEF_PLACEHOLDER_PROGRESS='Your slice: build the widget.
Expected artifact: .bionic/docs/record/w99-progplaceholder.md
Progress artifact: .bionic/tmp/<name>.progress
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r14d yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_PLACEHOLDER_PROGRESS" "progplaceholder")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "a templated PROGRESS path is not filled — the field is left empty" \
  "" "$(roster_field "$ROW" progress)"
expect_absent "…so no slot reaches the field the liveness check stats" "<" \
  "$(roster_field "$ROW" progress)"
expect_contains "…and the absent progress path is warned" "progress" "$GATE_ERR"
expect_status "…while the real deliverable still passes the wall" "0" "$GATE_ST"

section "S15 — the ship-day corners now pass BY DECLARING, not by guessing (R1, AC-3)"
#
# The two 2026-08-08 false blocks were GRAMMAR corners
# (`plans/epic-16-landing-contract/continuation.md` §charter-seed, decision 3: "Both of
# the day's false blocks were grammar corners (mid-string `<slot>` vs `^<`, and the
# quoted-help-text deliverable lift)"). R4 answered them by GUESSING a deliverable from
# prose and filling slots from the agent name. The Step-6 critic (N-1) showed the guess
# is then enforced with a declared fact's full weight, so Chris withdrew inference: the
# friction the wave wanted to remove was the requirement to DECLARE, and the reframe is
# that declaring is cheap and robustly parsed while guessing is off-thesis. So each
# corner now takes the same shape — as-written it REFUSES (there is no concrete declared
# path), and adding one canonical label makes it pass as `declared`.
#
# FIXTURE FIDELITY — declared, narrower than "verbatim": no ship-day brief text survives
# on disk (searched: `grep -rn "names no deliverable\|false-block" .bionic/docs/record/`);
# what survives is a DESCRIPTION of each corner in the charter seed, commit 121d277's
# message, and `record/w1-remediation-A2-report.md`. These briefs are RECONSTRUCTED to
# those descriptions. What IS verbatim is the thing that made the corner:
# BRIEF_QUOTES_HELP quotes this gate's own help text, where every ship-day `<name>.md`
# came from. Each corner is driven BOTH ways — refused as-written, accepted once declared.

# ---- corner 1: the MID-STRING slot in prose. As-written -> REFUSE ----
BRIEF_CORNER1='Canonical-sdlc Step 4, slice S4 of epic-99 wave-02; build · audited · wave.
Your slice: reconcile the label grammar with the declared parse.
Write your findings to .bionic/docs/record/w2-<slice>-notes.md when the suite is green.
Expected duration: ~20 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r15a yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_CORNER1" "corner1")"
expect_status "AC-3 corner 1 (mid-string slot in prose): REFUSED, no path is guessed" "2" "$GATE_ST"
expect_contains "AC-3 corner 1: …with the absent-deliverable refusal" "names no deliverable" "$GATE_ERR"
expect_status "AC-3 corner 1: …and no roster row is written" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# corner 1, DECLARED: adding a canonical label with a concrete name is the whole fix.
BRIEF_CORNER1_FIXED='Canonical-sdlc Step 4, slice S4 of epic-99 wave-02; build · audited · wave.
Your slice: reconcile the label grammar with the declared parse.
Expected artifact: .bionic/docs/record/w2-s4-notes.md
Expected duration: ~20 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r15a2 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_CORNER1_FIXED" "corner1")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "AC-3 corner 1 fixed: declaring a concrete path passes" "0" "$GATE_ST"
expect_status "AC-3 corner 1 fixed: …the row carries the declared path" \
  ".bionic/docs/record/w2-s4-notes.md" "$(roster_field "$ROW" deliverable)"
expect_status "AC-3 corner 1 fixed: …marked declared" "declared" "$(roster_field "$ROW" source)"
expect_absent "AC-3 corner 1 fixed: …no slot survives onto the roster" "<" "$ROW"

# ---- corner 2: the QUOTED-HELP-TEXT template. As-written it REFUSES (S14 r14a); the
# fix is BRIEF_HELP_THEN_REAL — the same quote plus a real declared line (S14 r14b).
# Both are pinned in S14; here we assert the FRAMING: the corner's resolution is to
# declare, and the declared line is what carries the contract.
REPO=$(make_repo r15b yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_HELP_THEN_REAL" "helpquoter")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "AC-3 corner 2 (quoted help text + a real declaration): passes" "0" "$GATE_ST"
expect_status "AC-3 corner 2: …the declared line carries the contract, not the quoted slot" \
  ".bionic/docs/record/w99-shape2.md" "$(roster_field "$ROW" deliverable)"
expect_status "AC-3 corner 2: …recorded declared" "declared" "$(roster_field "$ROW" source)"

# ---- THE PLANTED FAILURE (AC-3): a brief naming no concrete path STILL refuses ----
#
# The wall did not become advisory. A brief that names no concrete declared path — no
# label, no record/ mention, no template — has given the machinery nothing to stat.
BRIEF_NOTHING='Your slice: read the wall message through and tell me whether the wording drifted.
Expected duration: ~15 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r15c yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_NOTHING" "saysnothing")"
expect_status "AC-3 planted failure: a brief naming no plausible deliverable is STILL refused" \
  "2" "$GATE_ST"
expect_contains "AC-3 planted failure: …with the absent-deliverable refusal" \
  "names no deliverable" "$GATE_ERR"

# ---- an unnamed dispatch whose only deliverable is a template is refused (no fill,
# no ancestor fallback) — the withdrawal is total, not "fill when a name exists" ----
REPO=$(make_repo r15f yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_QUOTES_HELP" "-")"
expect_status "AC-3: an unnamed dispatch with only a templated path is REFUSED" "2" "$GATE_ST"
expect_contains "AC-3: …with the absent-deliverable refusal" "names no deliverable" "$GATE_ERR"

# ---- a real declared path always wins over a quoted template, wherever it sits, and
# is recorded DECLARED — the extractor walks every deliverable hit and takes the first
# that yields a concrete path ----
REPO=$(make_repo r15h yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_HELP_THEN_REAL" "helpquoter2")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "AC-3: a quoted template ahead of a real line still loses to it" \
  ".bionic/docs/record/w99-shape2.md" "$(roster_field "$ROW" deliverable)"
expect_status "AC-3: …recorded declared, because a label yielded it" \
  "declared" "$(roster_field "$ROW" source)"

section "S16 — the combined preflight: a missing attestation AUTO-RUNS the probe (epic-16 w2 S5, AC-4)"
#
# Synthesis §3, the five serialized minutes between order and spawn: the operator was
# refused, ran the probe by hand, retried, and only then dispatched. R5 makes the
# attestation a FACT the gate takes for itself — the probe is run inline, once, and the
# dispatch proceeds. Blocking survives in exactly one place on this path: the probe
# REFUSING, which means the environment is genuinely broken and the fleet would die.
#
# The probe invoked here is the REAL `hooks/preflight-probe.sh` sitting beside the gate —
# no stub, no seam. Its environment is substituted instead (a sandboxed config dir and a
# fixture credential), which is the same technique preflight-probe.test.sh uses.

# ---- ONE invocation, order to spawn: no attestation in, dispatch out ----
REPO=$(make_repo r16a yes)
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "AC-4: a dispatch with NO attestation is no longer refused" "0" "$GATE_ST"
expect_status "AC-4: …the probe ran inline and left this session's attestation on disk" "0" \
  "$([ -f "$REPO/.bionic/tmp/preflight-$SID_A.state" ] && echo 0 || echo 1)"
expect_status "AC-4: …keyed to THIS session, not whatever the shell was" "0" \
  "$(grep -qx "session_id=$SID_A" "$REPO/.bionic/tmp/preflight-$SID_A.state" && echo 0 || echo 1)"
expect_contains "AC-4: …and the auto-run is announced, not silent" "attestation" "$GATE_ERR"
expect_absent "AC-4: …with no refusal anywhere in it" "BLOCKED" "$GATE_ERR"
expect_status "AC-4: …the dispatch is journalled exactly once (one invocation, one row)" "1" \
  "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"
# The probe roots from the PINNED root, so the record it writes describes the repo the
# gate is guarding — the Synthesis field case (attestation redone because the root came
# from the shell's working directory) read the other way round.
# Compared PHYSICALLY on both sides. The sandbox lives under the platform temp dir,
# which is reached through a symlink on macOS (/var -> /private/var), so a string compare
# against the test's own spelling of the path would fail on a correct answer.
ATT_REPO=$(grep -m1 '^repo=' "$REPO/.bionic/tmp/preflight-$SID_A.state" | cut -d= -f2-)
expect_status "AC-4: …and the attestation names the pinned repo root" \
  "$(cd "$REPO" && pwd -P)" "$(cd "$ATT_REPO" 2>/dev/null && pwd -P)"

# ---- a FOREIGN-only attestation is the same fact: absent for me ----
REPO=$(make_repo r16b yes)
write_attestation "$REPO" "$SID_B"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "AC-4: a foreign-only attestation auto-probes rather than refusing" "0" "$GATE_ST"
expect_status "AC-4: …and session B's record is left strictly alone" "0" \
  "$([ -f "$REPO/.bionic/tmp/preflight-$SID_B.state" ] && echo 0 || echo 1)"

# ---- probe FAILURE fails CLOSED: the one surviving attestation refusal ----
#
# Driven by an unwritable state directory rather than an absent credential: the
# credential's third source is the machine keychain, which no sandbox can take away, so
# an absent-credential fixture would pass on this operator's machine and fail on a build
# box. An unwritable directory is the same blocking-probe class and is deterministic.
REPO=$(make_repo r16c yes)
mkdir -p "$REPO/.bionic/tmp"
chmod 500 "$REPO/.bionic/tmp"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
chmod 700 "$REPO/.bionic/tmp"
expect_status "AC-4: a probe that FAILS blocks the dispatch (the environment is broken)" \
  "2" "$GATE_ST"
expect_contains "AC-4: …the refusal is phrased as a block" "BLOCKED" "$GATE_ERR"
expect_contains "AC-4: …and hands over the probe's own reason, not a paraphrase" \
  "state dir" "$GATE_ERR"
expect_status "AC-4: …and a blocked dispatch is journalled nowhere (AC-12)" "0" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 1 || echo 0)"

section "S17 — ledger hygiene: a refusal leaves NO row; a same-path claim WARNS (epic-16 w2 S4, AC-12)"
#
# The F-4 phantom-intended-rows class, closed by inventory rather than by inspection: the
# roster is compared BYTE FOR BYTE across a refused dispatch, so a row added anywhere on
# any refusal path fails this regardless of what it says. Each absence assertion carries
# its accepted-dispatch twin, because "no row was written" is trivially true of a gate
# that writes no rows at all.

# ---- the paired positive first: an accepted dispatch writes exactly one row ----
REPO=$(make_repo r17a yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "AC-12 paired positive: an ACCEPTED dispatch creates exactly one row" "1" \
  "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"

# ---- and each refusal path leaves the inventory untouched ----
#
# The roster is pre-seeded with a real accepted dispatch so the comparison is against a
# NON-EMPTY ledger: "identical" then means the refusal added nothing, not that the file
# never existed.
for _case in nodeliverable outofrepo; do
  REPO=$(make_repo "r17-$_case" yes)
  write_attestation "$REPO" "$SID_A"
  run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "seed-row")"
  RP="$(roster_path "$REPO" "$SID_A")"
  BEFORE="$(cat "$RP" 2>/dev/null)"
  BEFORE_N="$(roster_rows "$RP")"
  case "$_case" in
    nodeliverable) _brief="$BRIEF_NOTHING" ;;
    outofrepo)     _brief='Your slice: build it.
Expected artifact: ../../../../../../etc/hosts
Expected duration: ~15 minutes.' ;;
  esac
  run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$_brief" "ghost-$_case")"
  expect_status "AC-12 ($_case): the dispatch is refused" "2" "$GATE_ST"
  expect_status "AC-12 ($_case): the roster is byte-identical across the refusal" \
    "$BEFORE" "$(cat "$RP" 2>/dev/null)"
  expect_status "AC-12 ($_case): …and still holds only the accepted dispatch's row" \
    "$BEFORE_N" "$(roster_rows "$RP")"
  expect_absent "AC-12 ($_case): the refused agent's name appears on no row" \
    "ghost-$_case" "$(cat "$RP" 2>/dev/null)"
done

# ---- a second dispatch claiming a path an open row already owns: WARN, never block ----
REPO=$(make_repo r17b yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "first-owner")"
expect_status "AC-12: the first claim on a path passes silently" "0" "$GATE_ST"
expect_absent "AC-12: …with no contention warning, since nothing else owns it" \
  "already" "$GATE_ERR"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "second-owner")"
expect_status "AC-12: a second dispatch claiming the same deliverable is NOT blocked" "0" "$GATE_ST"
expect_contains "AC-12: …it draws a warning" "already" "$GATE_ERR"
expect_contains "AC-12: …that names the OWNING row" "first-owner" "$GATE_ERR"
expect_contains "AC-12: …and the contested path" ".bionic/docs/record/w99-widget.txt" "$GATE_ERR"
expect_status "AC-12: …and the second row is journalled all the same" "2" \
  "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"

# a DIFFERENT path in the same session is not contention
REPO=$(make_repo r17c yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "owner-a")"
BRIEF_OTHER_PATH='Your slice: build the other widget.
Expected artifact: .bionic/docs/record/w99-other.txt
Expected duration: ~25 minutes.
Progress artifact: .bionic/tmp/w99-other.progress
Suites: tests/widget.test.sh'
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_OTHER_PATH" "owner-b")"
expect_status "AC-12 paired negative: a distinct deliverable draws no contention warning" "0" "$GATE_ST"
expect_absent "AC-12 paired negative: …and says nothing about an owner" "already" "$GATE_ERR"

section "S18 — EXACTLY ONE path under the deliverable label (R7: R6 critic R6-1/R6-2/R6-3/R6-4)"
#
# R1 withdrew prose inference but kept a guess inside the label: it read the FIRST
# SENTENCE of the label span and took the FIRST path-shaped token in it. The R6 critic
# showed that is F-RD wearing a declaration's clothes — "same shape as A, written to B"
# contracted A, recorded `source=declared`, and the landing gate then ordered the agent
# to write A (an existing report it was told to READ). Worse than pre-R1, where the
# over-broad span at least CONTAINED the real deliverable.
#
# THE RULE (plan assumption 71, faithful completion of 48s never guess — declare or
# refuse): the deliverable labels span must yield EXACTLY ONE path. Zero refuses (name
# one); more than one REFUSES, naming every candidate, because choosing among them is
# the guess. No position heuristic, no reading-verb whitelist, no first-wins.
#
# Because ambiguity is now fatal rather than resolved, the search window WIDENS back to
# the whole span — which retires the false-block R1s first-sentence bound introduced
# (a path in the labels second sentence was invisible, and the refusal told the author
# to name a path they had already named).

# ---- R6-1 CASE 9: two paths in one deliverable sentence -> REFUSE, both named ----
BRIEF_TWO_PATHS_SHAPE='You are reviewing the wave.

Expected artifact: same shape as .bionic/docs/record/w2-critic-report.md, written to .bionic/docs/record/w2-probe-frd.md
Expected duration: 30 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r18a yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_TWO_PATHS_SHAPE" "shapebot")"
expect_status "R6-1 CASE 9: a deliverable span naming two paths is REFUSED, never resolved" \
  "2" "$GATE_ST"
expect_contains "R6-1 CASE 9: …the refusal names the reference path" \
  ".bionic/docs/record/w2-critic-report.md" "$GATE_ERR"
expect_contains "R6-1 CASE 9: …and the real artifact, so neither is silently contracted" \
  ".bionic/docs/record/w2-probe-frd.md" "$GATE_ERR"
expect_contains "R6-1 CASE 9: …and asks for exactly one" "exactly one" "$GATE_ERR"
expect_status "R6-1 CASE 9: …and no roster row contracts the agent to either" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# ---- R6-1 CASE 10: the read-then-produce ordering, the F-RD harm verbatim ----
BRIEF_TWO_PATHS_READ='Your slice: an independent read-and-duplication review.
Deliverable: read .bionic/docs/record/w2-auditor-report.md first, then produce .bionic/docs/record/w2-probe-frd2.md
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r18b yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_TWO_PATHS_READ" "readproducebot")"
expect_status "R6-1 CASE 10: read-X-then-produce-Y is REFUSED, not contracted to X" "2" "$GATE_ST"
expect_contains "R6-1 CASE 10: …the auditors report is named as a candidate, not taken" \
  ".bionic/docs/record/w2-auditor-report.md" "$GATE_ERR"
expect_contains "R6-1 CASE 10: …alongside the artifact the agent was actually sent to write" \
  ".bionic/docs/record/w2-probe-frd2.md" "$GATE_ERR"
expect_status "R6-1 CASE 10: …and no row is written for either" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# ---- the refusal DIAGNOSES ambiguity, and is not the absent-deliverable message ----
expect_absent "the ambiguity refusal is not misfiled as an absent deliverable" \
  "names no deliverable" "$GATE_ERR"
expect_contains "…it says where references belong instead" "outside" "$GATE_ERR"

# ---- THE RESUBMISSION: CASE 9 with one path in the label and the reference moved out ----
BRIEF_TWO_PATHS_FIXED='You are reviewing the wave.

Read first: .bionic/docs/record/w2-critic-report.md — match its shape.
Expected artifact: .bionic/docs/record/w2-probe-frd.md
Expected duration: 30 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r18c yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_TWO_PATHS_FIXED" "shapebot")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "the resubmission — one path in the label, the reference outside it — passes" \
  "0" "$GATE_ST"
expect_status "…contracted to the artifact the brief actually asked for" \
  ".bionic/docs/record/w2-probe-frd.md" "$(roster_field "$ROW" deliverable)"
expect_status "…marked declared" "declared" "$(roster_field "$ROW" source)"

# ---- R6-4 CASE 5: a path in the labels SECOND sentence is declared, not absent ----
#
# R1 bounded the search at the end of the first sentence, so this brief — which names a
# concrete path under a canonical label — was refused for naming none, and the message
# told the author to do what they had already done. With ambiguity fatal, the window can
# safely be the whole span.
BRIEF_LATE_PATH='Your slice: assess the wave.
Expected artifact: a written report. Put it at .bionic/docs/record/w2-probe-late.md when done.
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r18d yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_LATE_PATH" "latepathbot")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "R6-4 CASE 5: a path in the labels second sentence PASSES (no first-sentence bound)" \
  "0" "$GATE_ST"
expect_status "R6-4 CASE 5: …and is the contract" \
  ".bionic/docs/record/w2-probe-late.md" "$(roster_field "$ROW" deliverable)"
expect_status "R6-4 CASE 5: …recorded declared, because a label yielded it" \
  "declared" "$(roster_field "$ROW" source)"

# ---- paired positive: one path plus surrounding prose in the span still passes ----
BRIEF_ONE_PATH_PROSE='Your slice: build the widget.
Expected artifact: .bionic/docs/record/w99-prose.md — the behavior table, the evidence,
and the judgment calls, written as prose rather than a log. Keep it short.
Expected duration: ~20 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r18e yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_ONE_PATH_PROSE" "prosebot")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "paired positive: a one-path span wrapped in prose passes" "0" "$GATE_ST"
expect_status "paired positive: …with that path as the contract" \
  ".bionic/docs/record/w99-prose.md" "$(roster_field "$ROW" deliverable)"

# ---- the same path named twice is ONE path, not an ambiguity ----
BRIEF_SAME_TWICE='Your slice: build the widget.
Expected artifact: .bionic/docs/record/w99-twice.md — append to .bionic/docs/record/w99-twice.md as you go.
Expected duration: ~20 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r18f yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_SAME_TWICE" "twicebot")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "one path named twice is not an ambiguity" "0" "$GATE_ST"
expect_status "…and lifts once" \
  ".bionic/docs/record/w99-twice.md" "$(roster_field "$ROW" deliverable)"

# ---- a WAIVER does not excuse an ambiguous declaration (R7 judgment call) ----
#
# The waiver excuses declaring NOTHING durable. A brief that declares a label naming two
# artifacts has not waived anything — it has written a contract the machine cannot read,
# and the author is the only one who can say which path is theirs.
BRIEF_AMBIG_WAIVED='Your slice: review the wave.
Deliverable-waiver: this dispatch returns its findings in the final message.
Expected artifact: compare .bionic/docs/record/a-notes.md against .bionic/docs/record/b-notes.md
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r18g yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_AMBIG_WAIVED" "waivedambig")"
expect_status "a waiver does not excuse an ambiguous deliverable label" "2" "$GATE_ST"
expect_contains "…and the refusal still names both candidates" "a-notes.md" "$GATE_ERR"

# ---- S18b: the deliverable span ends at the next LABELLED LINE, not at the next
# registered label (wave-bionic-1.3.2, found at dispatch) ----
#
# A span used to run on until the next label THIS WALL KNOWS or a blank line, so a brief
# that put `Evidence log: <path>` on the line after `Expected artifact: <path>` had two
# paths in one deliverable span and was refused as ambiguous — for a brief whose author had
# named exactly one deliverable and one input, each on its own labelled line. `Evidence
# log:` is not in the label table and does not need to be: any line that OPENS with a short
# `<Word>:` head is a new field, and a field ends where the next one begins. Two paths on
# the deliverable label OWN line are still the ambiguity the wall exists to refuse.
BRIEF_EVIDENCE_LOG='Your slice: build the widget.
Expected artifact: .bionic/docs/record/w99-evlog.md
Evidence log: .bionic/docs/record/w99-evlog.log
Expected duration: ~20 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r18evlog yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_EVIDENCE_LOG" "evlogbot")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "S18b Evidence log: on the NEXT line does not make the deliverable ambiguous" \
  "0" "$GATE_ST"
expect_status "S18b …and the deliverable is the one on the label own line" \
  ".bionic/docs/record/w99-evlog.md" "$(roster_field "$ROW" deliverable)"

# The same brief with the two paths on ONE line is still refused: the fix bounds the span,
# it does not stop the wall counting.
BRIEF_TWO_ON_ONE_LINE='Your slice: build the widget.
Expected artifact: .bionic/docs/record/w99-two.md .bionic/docs/record/w99-two.log
Expected duration: ~20 minutes.
Suites: tests/widget.test.sh'

REPO=$(make_repo r18twoline yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_TWO_ON_ONE_LINE" "twolinebot")"
expect_status "S18b two paths on the deliverable label OWN line are still REFUSED" "2" "$GATE_ST"
expect_contains "S18b …and the refusal still names both candidates" "w99-two.log" "$GATE_ERR"

# A prose continuation line (no label head) still belongs to the span — the R6-4 window
# stays open, so a path named in a later sentence is still found.
BRIEF_PROSE_CONT='Your slice: assess the wave.
Expected artifact: a written report.
Put it at .bionic/docs/record/w99-cont.md when you are done.
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r18prosecont yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_PROSE_CONT" "contbot")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "S18b a prose continuation line is still inside the span" "0" "$GATE_ST"
expect_status "S18b …and its path is the contract" \
  ".bionic/docs/record/w99-cont.md" "$(roster_field "$ROW" deliverable)"

# ---- R6-2: every refusal message recommends a brief the walls ACCEPT ----
#
# The containment refusal handed the author `Expected artifact: .bionic/docs/record/<name>.md`
# — the literal string tests/cross-gate-agreement.test.sh §N.4 pins as REFUSED, and which
# the SIBLING refusal (the absent-deliverable wall) explicitly calls out as not a name.
# Two refusal messages in one file in direct contradiction, green the whole time because
# no test read a Fix: line. This pin reads each walls own recommendation back out of its
# stderr and DRIVES IT: an author who follows the Fix: line verbatim must not be refused.
# It never hardcodes the example, so it holds when the wording is next edited.
fix_example() {  # <stderr> -> the artifact path the Fix: block recommends
  printf '%s\n' "$1" \
    | grep -m1 -E '^[[:space:]]+Expected artifact: ' \
    | sed -e 's/^[[:space:]]*Expected artifact: //' -e 's/[[:space:]]*$//'
}

BRIEF_OUT_OF_REPO='Your slice: build it.
Expected artifact: ../../../../../../etc/hosts
Expected duration: ~15 minutes.
Suites: tests/widget.test.sh'

for _wall in containment absent ambiguous; do
  case "$_wall" in
    containment) _b="$BRIEF_OUT_OF_REPO" ;;
    absent)      _b="$BRIEF_NOTHING" ;;
    ambiguous)   _b="$BRIEF_TWO_PATHS_SHAPE" ;;
  esac
  REPO=$(make_repo "r18h-$_wall" yes)
  write_attestation "$REPO" "$SID_A"
  run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$_b" "fixline-$_wall")"
  expect_status "self-consistency ($_wall): the wall refuses" "2" "$GATE_ST"
  _ex=$(fix_example "$GATE_ERR")
  expect_status "self-consistency ($_wall): its Fix: block recommends a labeled example" "0" \
    "$([ -n "$_ex" ] && echo 0 || echo 1)"
  expect_absent "self-consistency ($_wall): …carrying no slot the walls themselves refuse" \
    "<" "$_ex"
  REPO=$(make_repo "r18i-$_wall" yes)
  write_attestation "$REPO" "$SID_A"
  run_gate "$(mk_agent_payload "$SID_A" "$REPO" "Your slice: do the work.
Expected artifact: $_ex
Expected duration: ~15 minutes.
Suites: tests/widget.test.sh" "followed-$_wall")"
  expect_status "self-consistency ($_wall): a brief following that Fix: line verbatim PASSES" \
    "0" "$GATE_ST"
  expect_status "self-consistency ($_wall): …and the recommended path is what lands on the row" \
    "$_ex" "$(roster_field "$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)" deliverable)"
done

# ---- R6-3: a parenthetical duration lifts readable, not truncated mid-phrase ----
#
# bound_field ended a value at `)` but not `(`, so a balanced parenthetical truncated with
# a dangling open bracket — `~45 minutes (phase 1 only` — which the poker's parse_seconds
# refuses (two numbers, one matched unit pair). An unreadable duration silently exempts the
# row from overdue notification, which is A-2 read from the writer side.
BRIEF_PAREN_DURATION='Your slice: build the widget.
Expected artifact: .bionic/docs/record/w99-paren.md
Expected duration: ~45 minutes (phase 1 only), phase 2 is a separate dispatch.
Suites: tests/widget.test.sh'

REPO=$(make_repo r18j yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_PAREN_DURATION" "parenbot")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "R6-3: a parenthetical duration lifts the clause before the bracket" \
  "~45 minutes" "$(roster_field "$ROW" duration)"
expect_absent "R6-3: …with no dangling open bracket for parse_seconds to choke on" \
  "(" "$(roster_field "$ROW" duration)"
expect_absent "R6-3: …and none of the parentheticals own numbers" \
  "phase" "$(roster_field "$ROW" duration)"

section "S19 — deliverable-kind labels are LINE-START ONLY (R8: final-audit A-1)"
#
# record/w2-r7-audit.md A-1: R7's ambiguity wall refuses when a deliverable SPAN
# holds two paths, but each of its three refusal messages quotes the same
# concrete, liftable example — "Expected artifact: .bionic/docs/record/
# my-slice-notes.md" — and briefs in this repo quote wall text constantly. A
# brief that quotes that line in PROSE ahead of its real, later "Expected
# artifact:" line puts each label in its OWN span (one path apiece), so the
# ambiguity wall never sees two paths in one span; decl_deliverable() then
# takes the FIRST hit that yields any path and silently contracts the agent to
# a file it will never write, recorded source=declared as though a human named
# it — the one shape that routes around the ambiguity wall entirely.
#
# THE FIX: the same mechanism `deliverable-waiver` already uses (S-1) — a
# deliverable-kind label counts only at LINE START. A mid-line occurrence is
# prose, not a declaration, and must not even register as a hit.

# ---- the audit's own P2 specimen, verbatim ----
BRIEF_P2_BAIT='Your slice: build the widget.
The wall told me to write: Expected artifact: .bionic/docs/record/my-slice-notes.md
Expected artifact: .bionic/docs/record/w2-probe-real.md
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r19a yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_P2_BAIT" "p2bot")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "A-1: a quoted wall-message bait ahead of the real label passes" \
  "0" "$GATE_ST"
expect_status "A-1: …contracted to the REAL line-start label's path" \
  ".bionic/docs/record/w2-probe-real.md" "$(roster_field "$ROW" deliverable)"
expect_absent "A-1: …never to the mid-line quoted bait" \
  "my-slice-notes.md" "$(roster_field "$ROW" deliverable)"
expect_status "A-1: …still recorded declared" "declared" "$(roster_field "$ROW" source)"

# ---- CONTROL: the bare `deliverable` label, same shape — proves the pin
# generalizes across the canonical variants, not just `expected artifact` ----
BRIEF_P2_BARE='Your slice: review the wave.
It said: Deliverable: .bionic/docs/record/bait-bare.md is the example.
Deliverable: .bionic/docs/record/w2-real-bare.md
Expected duration: 20 minutes
Suites: tests/widget.test.sh'

REPO=$(make_repo r19b yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_P2_BARE" "p2barebot")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "A-1 control (bare label): passes" "0" "$GATE_ST"
expect_status "A-1 control (bare label): contracted to the real line-start path" \
  ".bionic/docs/record/w2-real-bare.md" "$(roster_field "$ROW" deliverable)"
expect_absent "A-1 control (bare label): never to the mid-line bait" \
  "bait-bare.md" "$(roster_field "$ROW" deliverable)"

section "S20 — the agent-context channel: walls travel, the LEDGER does not (T6, D1)"
#
# hooks/agent-context-guard.sh registers this gate a second time, through
# settings.json, so a dispatch made from INSIDE a teammate or subagent context meets
# the same walls a main-thread one does — the skill channel is dead there
# (.bionic/docs/record/session-20260815-landing-supervision/t1-probe-report.md §3).
# What must not travel with the walls is the journal: the roster is the depth-one
# ledger of what the ORCHESTRATOR launched, and rows for a teammate's own subagents
# are contracts nobody confirms, lands or checks.
#
# The guard is the only writer of BIONIC_HOOK_CHANNEL and this is its only reader;
# tests/cross-gate-agreement.test.sh §L.6 pins the pair across the two files.
#
# BOTH DIRECTIONS, because a suppression that suppressed the WALL as well would look
# identical from the roster's side — and would be the R2 hole reopening in the act of
# closing it.
REPO=$(make_repo r20 yes)
write_attestation "$REPO" "$SID_A"
S20_SAVED_ENV="$GATE_ENV"
GATE_ENV="$GATE_ENV BIONIC_HOOK_CHANNEL=agent-context"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "a contract-complete dispatch in an agent context passes" "0" "$GATE_ST"
expect_status "…and writes NO roster row (the ledger stays at depth one)" "1" \
  "$([ -f "$(roster_path "$REPO" "$SID_A")" ] && echo 0 || echo 1)"

# The wall itself is untouched by the channel — a deliverable-less brief is refused
# at depth, which is the entire point of the second registration.
run_gate "$(mk_agent_payload "$SID_A" "$REPO" 'Canonical-sdlc Step 4. Do the thing.
Exit condition: the suite is green.')"
expect_status "a deliverable-less dispatch in an agent context is still REFUSED" "2" "$GATE_ST"
expect_contains "…by the absent-deliverable wall, in its own words" \
  "BLOCKED: this dispatch brief names no deliverable" "$GATE_ERR"
GATE_ENV="$S20_SAVED_ENV"

# The paired positive: the same dispatch with no channel marker — the main thread, as
# the skill channel delivers it — still journals its row.
REPO=$(make_repo r20b yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "the same dispatch on the main thread passes" "0" "$GATE_ST"
expect_status "…and DOES journal exactly one row" "1" \
  "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"

# An unrelated value in the variable is not the channel: only the guard's exact
# spelling suppresses, so a stray export cannot silently stop the ledger.
S20_SAVED_ENV="$GATE_ENV"
GATE_ENV="$GATE_ENV BIONIC_HOOK_CHANNEL=something-else"
REPO=$(make_repo r20c yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "an unrecognised channel value journals normally" "1" \
  "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"
GATE_ENV="$S20_SAVED_ENV"


section "S21: the arming wall — a dispatch needs a live Patrol (epic-17 W5 4/4, AC-6)"
#
# WHAT THIS WALL IS FOR. Every other wall on this path asks whether the dispatch is
# well-formed or the environment is sound. This one asks whether anything is WATCHING the
# fleet the dispatch is about to join. The Patrol is the run's one clock; when it is not
# armed, or was armed and has silently stopped firing, a launched agent can die quiet and
# nothing notices until a human wanders back. The stamp
# (.bionic/tmp/patrol-<sid>.state, written by hooks/session-poker.sh's `arm` and by every
# `tick` before it decides) is the liveness signal, and its AGE is the whole test:
# absent = never armed, older than 2x the poker-interval = armed-but-dead.
#
# SCOPE IS THE HOOK'S EXISTING ACTIVE-RUN PREDICATE, deliberately — no second definition of
# "active" (design ledger D-C mechanic 4). Outside a wave this gate has already exited long
# before reaching here, which the no-wave arm below drives directly.
#
# THE INTERVAL IS THE POKER'S OWN, read by invoking the sibling `interval` verb rather than
# by re-implementing the config knob. An interval this gate cannot read is an AMBIGUITY, not
# a finding, and takes §7's start-side direction: warn and pass.

s21_stamp_path() { printf '%s/.bionic/tmp/patrol-%s.state' "$1" "$2"; }

s21_backdate() {  # <file> <seconds ago>
  local ts
  ts="$(date -v-"$2"S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-$2 seconds" +%Y%m%d%H%M.%S)"
  touch -t "$ts" "$1"
}

# ---------- absent stamp: never armed ----------
REPO=$(make_repo r21a yes)
write_attestation "$REPO" "$SID_A"
rm -f "$(s21_stamp_path "$REPO" "$SID_A")"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "an ABSENT Patrol stamp refuses the dispatch" "2" "$GATE_ST"
expect_contains "…in the checkpoint house style, not an alarm word" "patrol checkpoint" "$GATE_ERR"
expect_contains "…naming the state it found" "never armed" "$GATE_ERR"
expect_contains "…and naming the exact re-arm command, resolved" "session-poker.sh arm" "$GATE_ERR"
expect_contains "…and the CronCreate half, so the stamp is not re-armed into a dead clock" \
  "CronCreate" "$GATE_ERR"
expect_contains "…and says what to do after" "retry the dispatch" "$GATE_ERR"
expect_status "…and journals nothing: a refused dispatch is not a launch" "0" \
  "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"

# ---------- stale stamp: armed, then died ----------
REPO=$(make_repo r21b yes)
write_attestation "$REPO" "$SID_A"
s21_backdate "$(s21_stamp_path "$REPO" "$SID_A")" 4000   # > 2 x the 1200s default
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "a STALE Patrol stamp refuses the dispatch" "2" "$GATE_ST"
expect_contains "…and names the armed-but-dead state, not the never-armed one" \
  "stopped firing" "$GATE_ERR"
expect_absent "…so the two arms cannot be confused in a transcript" "never armed" "$GATE_ERR"

# ---------- fresh stamp: passes, silently ----------
REPO=$(make_repo r21c yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "a FRESH Patrol stamp lets the dispatch through" "0" "$GATE_ST"
expect_absent "…and the wall says nothing on the pass path" "patrol checkpoint" "$GATE_ERR"
expect_status "…and the launch is journalled as usual" "1" \
  "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"

# ---------- a stamp for ANOTHER session is not this session's liveness ----------
REPO=$(make_repo r21d yes)
write_attestation "$REPO" "$SID_A"
rm -f "$(s21_stamp_path "$REPO" "$SID_A")"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "a stamp keyed to a DIFFERENT session does not arm this one" "2" "$GATE_ST"
expect_contains "…and reads as never-armed here" "never armed" "$GATE_ERR"

# ---------- the wall rides the active-run predicate and nothing else ----------
REPO=$(make_repo r21e no)
rm -f "$(s21_stamp_path "$REPO" "$SID_A")"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "with NO wave active an unarmed Patrol is not this gate's business" "0" "$GATE_ST"
expect_empty "…and the gate is silent, as it is for every other check outside a wave" "$GATE_ERR"

# ---------- the threshold is 2x the poker-interval, and follows the config knob ----------
REPO=$(make_repo r21f yes)
write_attestation "$REPO" "$SID_A"
printf 'poker-interval: 1m\n' > "$REPO/.bionic/config.yaml"
s21_backdate "$(s21_stamp_path "$REPO" "$SID_A")" 100     # inside 2 x 60s
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "a stamp inside 2x the CONFIGURED interval passes (100s of 120s)" "0" "$GATE_ST"

REPO=$(make_repo r21g yes)
write_attestation "$REPO" "$SID_A"
printf 'poker-interval: 1m\n' > "$REPO/.bionic/config.yaml"
s21_backdate "$(s21_stamp_path "$REPO" "$SID_A")" 200     # past 2 x 60s
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "…and one past it refuses, on the same fixture the default would have passed" \
  "2" "$GATE_ST"
expect_contains "…naming the interval it measured against" "120s" "$GATE_ERR"

# ---------- a symlinked stamp is refused, never followed ----------
REPO=$(make_repo r21h yes)
write_attestation "$REPO" "$SID_A"
printf 'patrol-stamp/v1|at=2099-01-01T00:00:00Z|session=%s|verb=arm\n' "$SID_A" \
  > "$SANDBOX/planted-stamp"
rm -f "$(s21_stamp_path "$REPO" "$SID_A")"
ln -s "$SANDBOX/planted-stamp" "$(s21_stamp_path "$REPO" "$SID_A")"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "a SYMLINKED stamp cannot open this wall" "2" "$GATE_ST"

# ---------- an unreadable interval falls back to the poker's own default ----------
#
# CRITIC C-2 (W5). This used to skip BOTH arms of the wall and pass. `poker-interval:` is
# machine-local and agent-writable, so one line in a config file disabled an entire wall —
# in a file whose own §8 says a hostile repo may CLOSE a wall and must never be able to
# OPEN one. And the line that reaches it is the likeliest typo there is: a BARE NUMBER
# (`poker-interval: 30`) makes the poker refuse, where `30m` and `30 minutes` both parse.
#
# The interval is a THRESHOLD, not a precondition, and only one of the two arms needs it.
# So: the stamp-existence arm runs unconditionally (an absent stamp is absent at every
# interval), and the staleness arm falls back to the poker's own POKER_INTERVAL_DEFAULT —
# read from the poker, never retyped here, via its read-only `interval-default` verb. The
# dispatch still passes, because the operator's config really is unreadable and that is an
# ambiguity; what it no longer does is pass with nothing checked.
REPO=$(make_repo r21i yes)
write_attestation "$REPO" "$SID_A"
printf 'poker-interval: whenever\n' > "$REPO/.bionic/config.yaml"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "an interval the poker refuses to read does not refuse the dispatch" "0" "$GATE_ST"
expect_contains "…but says so, rather than passing a wall off as satisfied" \
  "Patrol interval" "$GATE_ERR"
expect_contains "…and says the wall RAN, at the default, rather than that it did not run" \
  "wall ran at default" "$GATE_ERR"

# r21j — THE MISSING COMBINATION, and the one that made C-2 a hole rather than a wording
# problem: the same unreadable interval with NO stamp at all. r21i above drives a FRESH
# stamp, so it can only ever show pass-stays-pass.
REPO=$(make_repo r21j yes)
write_attestation "$REPO" "$SID_A"
printf 'poker-interval: 30\n' > "$REPO/.bionic/config.yaml"   # the bare-number typo: rc=2
rm -f "$(s21_stamp_path "$REPO" "$SID_A")"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "an unreadable interval does NOT open the wall for an unarmed session" "2" "$GATE_ST"
expect_contains "…the never-armed arm still fires" "never armed" "$GATE_ERR"

# r21k — and the staleness arm runs too, measured against the fallback default.
REPO=$(make_repo r21k yes)
write_attestation "$REPO" "$SID_A"
printf 'poker-interval: 30\n' > "$REPO/.bionic/config.yaml"
s21_backdate "$(s21_stamp_path "$REPO" "$SID_A")" 4000   # > 2 x the 1200s default
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "a stale stamp under an unreadable interval refuses at the DEFAULT threshold" \
  "2" "$GATE_ST"
expect_contains "…naming the armed-but-dead state" "stopped firing" "$GATE_ERR"

# r21l — the fallback is the POKER'S constant, not a number retyped in the gate. Proven
# by MUTATION: change POKER_INTERVAL_DEFAULT on a doctored copy of the poker tree and the
# threshold the gate measures against has to move with it. A gate carrying its own 1200
# would pass this fixture unchanged.
# A COPIED HOOK NEEDS THE LIBRARY BESIDE IT — the shape the plugin ships, `hooks/`
# beside `scripts/lib` (bionic 1.4.0). Both the gate and the poker load through the
# shared loader idiom, whose first candidate is `$(dirname "$0")/../scripts/lib`; a copy
# dropped into a bare temp directory finds none, fails open, and every arm below would be
# measuring the step-aside rather than the threshold. The library is LINKED rather than
# copied, so the tree under test reads exactly the functions the shipped scripts read —
# and linking the whole directory means a hook that later wants one more basename does not
# silently fall off the end of a hand-listed set.
s21_plant() {  # <tree root> -> plants hooks/ + scripts/lib and echoes the hooks dir
  local root="$1"
  mkdir -p "$root/hooks" "$root/scripts"
  ln -s "$(cd "${BIONIC_HOOKS_DIR}/../payload/scripts/lib" && pwd -P)" "$root/scripts/lib" 2>/dev/null \
    || ln -s "$(cd "${BIONIC_HOOKS_DIR}/../scripts/lib" && pwd -P)" "$root/scripts/lib" 2>/dev/null || true
  printf '%s' "$root/hooks"
}
S21_TREE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/s21-poker-tree.XXXXXX")
S21_TREE_HOOKS=$(s21_plant "$S21_TREE_ROOT")
S21_TREE="$S21_TREE_HOOKS"   # POKER's spelling; both names address one directory
cp "$GATE" "$S21_TREE_HOOKS/dispatch-preflight.sh"
sed 's/^POKER_INTERVAL_DEFAULT="20m"$/POKER_INTERVAL_DEFAULT="10s"/' \
  "${BIONIC_HOOKS_DIR}/session-poker.sh" > "$S21_TREE_HOOKS/session-poker.sh"
if grep -qF 'POKER_INTERVAL_DEFAULT="10s"' "$S21_TREE_HOOKS/session-poker.sh"; then
  ok "r21l meta: the doctored poker default landed (the sed anchor still matches)"
else
  no "r21l meta: the doctored poker default did NOT land — the arm below proves nothing"
fi
REPO=$(make_repo r21l yes)
write_attestation "$REPO" "$SID_A"
printf 'poker-interval: 30\n' > "$REPO/.bionic/config.yaml"
s21_backdate "$(s21_stamp_path "$REPO" "$SID_A")" 100   # fresh at 1200s, ancient at 10s
S21_SAVED_GATE="$GATE"; GATE="$S21_TREE_HOOKS/dispatch-preflight.sh"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "r21l the fallback threshold moves with the POKER's constant, not the gate's" \
  "2" "$GATE_ST"
expect_contains "…and measures against 2x the doctored default" "20s" "$GATE_ERR"
GATE="$S21_SAVED_GATE"

# r21m — THE POKER ITSELF UNREACHABLE. `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/` is the
# gate's second lane for its siblings, and after the Step-9 legacy teardown that directory
# no longer holds hooks on any machine — so on a plugin-only install the only lane that
# resolves is the sibling one. If BOTH miss, there is no interval and no default to be had,
# and the honest degradation is per-arm: the existence half needs no threshold and still
# refuses, and the staleness half says out loud that it did not run. What must never happen
# is the whole wall going quiet, which is what a teardown would otherwise have bought.
S21_LONE=$(mktemp -d "${TMPDIR:-/tmp}/s21-lone-gate.XXXXXX")
S21_LONE_HOOKS=$(s21_plant "$S21_LONE")
cp "$GATE" "$S21_LONE_HOOKS/dispatch-preflight.sh"
S21_EMPTY_CONFIG=$(mktemp -d "${TMPDIR:-/tmp}/s21-empty-config.XXXXXX")
REPO=$(make_repo r21m yes)
write_attestation "$REPO" "$SID_A"
rm -f "$(s21_stamp_path "$REPO" "$SID_A")"
S21_SAVED_GATE="$GATE"; S21_SAVED_CONFIG="$GATE_CONFIG_DIR"
GATE="$S21_LONE_HOOKS/dispatch-preflight.sh"; GATE_CONFIG_DIR="$S21_EMPTY_CONFIG"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "r21m with NO poker on either lane, the unarmed session is still refused" \
  "2" "$GATE_ST"
expect_contains "…by the existence arm, which never needed the interval" "never armed" "$GATE_ERR"

# …and the staleness half, which genuinely cannot run, says so instead of passing quietly.
REPO=$(make_repo r21n yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "r21n …and a stamped session passes, the staleness half unmeasured" "0" "$GATE_ST"
expect_contains "…saying which half did not run, and why" \
  "staleness half" "$GATE_ERR"
GATE="$S21_SAVED_GATE"; GATE_CONFIG_DIR="$S21_SAVED_CONFIG"

# ================================================== S22: THE PARALLEL-BUDGET ARM
# (spec AC-26; plan slice WALLS; assumptions WALLS/2, WALLS/3, WALLS/4.)
#
# The active plan's frontmatter may carry ONE budget string —
# `parallel-budget: writers=N suites=N worktrees=N test_jobs=N source=…` — written at
# Step 0 from the resources probe and byte-identical to the attestation's `budget=`
# value (L-RESOURCES/2). With that line present the gate refuses a dispatch that would
# push any of the three counted resources past its ceiling; WITHOUT it the gate is
# inert, which is what keeps every plan written before this wave dispatching normally.
#
# The three counts and where each comes from:
#   writers   — OPEN roster rows for this session (a `status=intended` row whose name
#               carries no `landing-swept/v1` marker). Same predicate lib/patrol.sh's
#               patrol_roster_state uses for its own `open=`, and r22g pins the two
#               against each other on one fixture so the wall and the Patrol can never
#               disagree about how many writers are out.
#   suites    — those same open rows carrying a non-empty `claims=` (the subprocess
#               claim a suite-running brief declares).
#   worktrees — live linked trees under `<project root>/.worktrees` — a directory whose
#               `.git` is a FILE, which is exactly how scripts/lib/worktree.sh tells a
#               linked worktree from the main checkout.
# Each arm adds 1 for the dispatch about to happen, per the plan's literal text.

# s22_set_budget <repo> <budget value> — insert `parallel-budget:` into the plan's
# leading frontmatter block (the plan fixture's first line is the opening `---`).
s22_set_budget() {
  local plan="$1/.bionic/docs/plans/epic-99-test/wave-01-test.plan.md" val="$2"
  awk -v v="$val" 'NR == 1 && $0 == "---" { print; print "parallel-budget: " v; next } { print }' \
    "$plan" > "$plan.tmp" && mv "$plan.tmp" "$plan"
}

# s22_roster_row <repo> <sid> <name> [claims] — one launch row in the shipped schema.
s22_roster_row() {
  local f; f="$(roster_path "$1" "$2")"
  mkdir -p "$(dirname "$f")"
  # No `plan=`: these rows are counted by the budget arm, which reads `status=` and
  # `claims=` and nothing else, and `roster_row_no_plan` is the shape this fixture has
  # always had (tests/lib/roster-row.sh, S14).
  roster_row_no_plan status=intended "session=$2" "name=$3" agent_id= \
    launched_at=2026-09-02T00:00:00Z subagent_type=implementor model= \
    "deliverable=/tmp/d-$3" source=declared "duration=~10 minutes" progress= \
    "claims=${4:-}" cadence= absent= waiver= "tool_use_id=t-$3" >> "$f"
}

# s22_sweep <repo> <sid> <name> — the landing marker that closes a row.
# THROUGH THE ONE WRITER (S17, spec AC-26): `swept_marker_write` is
# hooks/landing-gate.sh's own function, extracted by tests/lib/swept-marker.sh and called
# for real. The printf that used to sit here wrote a marker the originator would not
# recognise — no `session=`, no `agent_id=` — and stayed green because every reader of the
# marker is by key.
s22_sweep() {
  swept_marker_write "$(roster_path "$1" "$2")" 2026-09-02T00:00:00Z "$2" "$3" "" MET
}

# s22_fake_tree <repo> <dir> — a linked worktree's on-disk signature: a `.git` FILE.
s22_fake_tree() {
  mkdir -p "$1/.worktrees/$2"
  printf 'gitdir: %s/.git/worktrees/%s\n' "$1" "$2" > "$1/.worktrees/$2/.git"
}

section "S22: the parallel-budget arm"

# --- writers: at the ceiling, refuse; one under it, pass.
REPO=$(make_repo r22a yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=2 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "W-ONE"
s22_roster_row "$REPO" "$SID_A" "W-TWO"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "r22a two open rows against writers=2 → the third dispatch is REFUSED" "2" "$GATE_ST"
expect_contains "…naming the budget line verbatim" \
  "writers=2 suites=9 worktrees=9 test_jobs=4 source=probe" "$GATE_ERR"
expect_contains "…and the count that broke it" "writers: budget=2 open=2 with-this-dispatch=3" "$GATE_ERR"
expect_contains "…naming the plan the budget came from" "$REPO/.bionic/docs/plans/epic-99-test/wave-01-test.plan.md" "$GATE_ERR"

REPO=$(make_repo r22b yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=2 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "W-ONE"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "r22b one open row against writers=2 → the second dispatch passes" "0" "$GATE_ST"
expect_absent "…and says nothing about a budget on the pass path" "parallel budget" "$GATE_ERR"

# --- inert without the line. The same roster that refused above dispatches freely
#     when the plan declares no budget, which is every plan written before this wave.
REPO=$(make_repo r22c yes)
write_attestation "$REPO" "$SID_A"
s22_roster_row "$REPO" "$SID_A" "W-ONE"
s22_roster_row "$REPO" "$SID_A" "W-TWO"
s22_roster_row "$REPO" "$SID_A" "W-THREE"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "r22c no parallel-budget: in the plan → the arm is inert, three rows notwithstanding" "0" "$GATE_ST"
expect_absent "…and prints nothing about a budget it was never given" "parallel budget" "$GATE_ERR"

# --- a row absent from the fresh live set is not an open one (AC-7; the
#     anti-vacuity control: the same fixture refuses while the row is live).
#     `landing-swept` is no longer consulted at all — the row's own PRESENCE in
#     THIS TURN's ListAgents answer is the only thing that opens or closes it.
REPO=$(make_repo r22d yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "W-ONE"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "r22d one LIVE row against writers=1 → refused (the control)" "2" "$GATE_ST"
R22D_ABSENT="$SANDBOX/.r22d-absent.jsonl"
mk_transcript "$R22D_ABSENT" fresh
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22D_ABSENT")"
expect_status "…and the same row, absent from a fresh answer, no longer counts → passes" \
  "0" "$GATE_ST"

# --- suites: an open row carrying a subprocess claim.
REPO=$(make_repo r22e yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=9 suites=1 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "W-ONE" "bash tests/run.sh"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "r22e one claimed suite against suites=1 → REFUSED" "2" "$GATE_ST"
expect_contains "…naming the suite count" "suites: budget=1 claimed=1 with-this-dispatch=2" "$GATE_ERR"

REPO=$(make_repo r22f yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=9 suites=1 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "W-ONE"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "r22f the same row with NO claim does not spend a suite → passes" "0" "$GATE_ST"

# --- worktrees: live linked trees on disk.
REPO=$(make_repo r22h yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=9 suites=9 worktrees=1 test_jobs=4 source=probe"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "r22h worktrees=1 with no tree standing → passes (the control)" "0" "$GATE_ST"
s22_fake_tree "$REPO" "one"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "…one live tree against worktrees=1 → REFUSED" "2" "$GATE_ST"
expect_contains "…naming the tree count" "worktrees: budget=1 live=1 with-this-dispatch=2" "$GATE_ERR"
# A plain directory under .worktrees is not a leased tree — only a linked one is.
REPO=$(make_repo r22i yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=9 suites=9 worktrees=1 test_jobs=4 source=probe"
mkdir -p "$REPO/.worktrees/not-a-tree"
run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "r22i a bare directory under .worktrees is not a lease → passes" "0" "$GATE_ST"

# --- r22g: the wall and the Patrol count the same open rows on THIS fixture. AC-7
#     retires `landing-swept` as the wall's own signal — W-FOUR is left off the fresh
#     transcript instead — but lib/patrol.sh's `patrol_roster_state` is untouched by
#     this slice and still reads the swept marker, so both are kept: one closes
#     W-FOUR for the Patrol's own count, the other closes it for the wall's.
REPO=$(make_repo r22g yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=3 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "W-ONE"
s22_roster_row "$REPO" "$SID_A" "W-TWO"
s22_roster_row "$REPO" "$SID_A" "W-THREE"
s22_roster_row "$REPO" "$SID_A" "W-FOUR"
s22_sweep "$REPO" "$SID_A" "W-FOUR"
R22G_TRANSCRIPT="$SANDBOX/.r22g-live.jsonl"
mk_transcript "$R22G_TRANSCRIPT" fresh W-ONE W-TWO W-THREE
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22G_TRANSCRIPT")"
expect_status "r22g three live rows and one absent, against writers=3 → REFUSED" "2" "$GATE_ST"
expect_contains "…the wall counts three open" "writers: budget=3 open=3 with-this-dispatch=4" "$GATE_ERR"
# shellcheck source=/dev/null
( . "${BIONIC_SCRIPTS_DIR}/payload/scripts/lib/patrol.sh" 2>/dev/null \
  && patrol_roster_state "$REPO" "$SID_A" ) > "$SANDBOX/.r22g" 2>/dev/null
expect_contains "…and so does lib/patrol.sh's patrol_roster_state, on the same file" \
  "open=3" "$(cat "$SANDBOX/.r22g")"

# ================================== S22b: LIVE-AGENTS FRESHNESS GATES THE COUNT
# (spec AC-7, AC-8; slice S5.)
#
# The predicate itself, isolated from every other S22 arm: one `status=intended` row,
# writers budget tight enough that whether it counts open decides pass vs refuse.

section "S22b: the budget count is read off the fresh live set"

# (a) the row's agent is ABSENT from a FRESH answer -> open=0, and the dispatch that
# would have been the SECOND writer (budget=1, one row not counted) is allowed.
REPO=$(make_repo r22ja yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "r1"
R22JA_T="$SANDBOX/.r22ja.jsonl"
mk_transcript "$R22JA_T" fresh W-OTHER
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22JA_T")"
expect_status "r22ja r1 absent from a fresh answer -> open=0, dispatch allowed at budget=1" \
  "0" "$GATE_ST"
expect_absent "…and no budget refusal, live-agents or otherwise" "BLOCKED" "$GATE_ERR"
expect_absent "…specifically no writers count printed" "writers:" "$GATE_ERR"

# (b) the SAME roster, repo and budget; only the answer changes to name r1 itself ->
# open=1, and the same dispatch is now the second writer against a budget of one.
REPO=$(make_repo r22jb yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "r1"
R22JB_T="$SANDBOX/.r22jb.jsonl"
mk_transcript "$R22JB_T" fresh r1
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22JB_T")"
expect_status "r22jb r1 present in the fresh answer -> open=1, REFUSED" "2" "$GATE_ST"
expect_contains "…naming the count" "writers: budget=1 open=1 with-this-dispatch=2" "$GATE_ERR"

# (c) no FRESH answer this turn — STALE and NONE both — REFUSES the whole dispatch,
# naming the fix, before the budget arm is ever consulted (AC-8). Same roster/budget
# as (a)/(b) so the only variable is the transcript.
REPO=$(make_repo r22jc yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "r1"
R22JC_STALE="$SANDBOX/.r22jc-stale.jsonl"
mk_transcript "$R22JC_STALE" stale r1
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22JC_STALE")"
expect_status "r22jc a STALE answer REFUSES the dispatch" "2" "$GATE_ST"
expect_contains "…naming the state and the fix" \
  "live-agents: stale age=" "$GATE_ERR"
expect_contains "…the fix" "call ListAgents, then dispatch" "$GATE_ERR"

R22JC_NONE="$SANDBOX/.r22jc-none.jsonl"
mk_transcript "$R22JC_NONE" none
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22JC_NONE")"
expect_status "r22jc …and NONE (no ListAgents answer at all) REFUSES the same way" "2" "$GATE_ST"
expect_contains "…naming the state" "live-agents: none age=none" "$GATE_ERR"
expect_contains "…and the fix" "call ListAgents, then dispatch" "$GATE_ERR"

# The paired negative: an EMPTY roster (no `status=intended` rows at all) needs no
# live reading, so the same STALE transcript decides nothing — no roster row's
# openness is in question, and refusing every dispatch on an unrelated repo would be
# refusing dispatches that have nothing to do with the budget wall at all.
REPO=$(make_repo r22jd yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22JC_STALE")"
expect_status "r22jd an empty roster needs no live reading -> the same STALE transcript passes" \
  "0" "$GATE_ST"
expect_absent "…and says nothing about live-agents" "live-agents:" "$GATE_ERR"

# (e) THE TOKEN ITSELF IS GONE, NOT MERELY UNCONSULTED (AC-7 "no landing-swept marker is
# consulted"). r22ja/r22jb pin the BEHAVIOUR — presence in the fresh live set is what
# opens or closes a row — but nothing above pins the IMPLEMENTATION: that the retired
# marker cannot quietly become a second, competing signal inside this same function on
# some future edit. A token pin on the function's own body is the only way to close that.
BUDGET_FN_BODY="$(sed -n '/^  budget_roster_counts() {/,/^  }$/p' "$GATE")"
expect_eq "…and the extracted span is non-empty (the pin is not vacuously true)" "1" \
  "$(printf '%s\n' "$BUDGET_FN_BODY" | /usr/bin/grep -c 'budget_roster_counts() {' || true)"
expect_eq "budget_roster_counts's own body carries no landing-swept token" "0" \
  "$(printf '%s\n' "$BUDGET_FN_BODY" | /usr/bin/grep -c 'landing-swept' || true)"

# THE ANTI-VACUITY ARM: a doctored copy that re-adds the token inside the SAME function
# body must fail the pin above. The doctor inserts one inert statement right after the
# function's own opening line — not a comment change to the signature, which would move
# the extractor's own anchor and prove nothing.
GATE_MUT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-preflight-swept-mut.XXXXXX")"
GATE_MUT="$GATE_MUT_ROOT/dispatch-preflight.sh"
awk '
  { print }
  /^  budget_roster_counts\(\) \{  #/ { print "    : # landing-swept/v1 reintroduced by mutation (test-only)" }
' "$GATE" > "$GATE_MUT"
expect_eq "swept-mut meta: the doctor's re-added line landed (the anchor still matches)" "1" \
  "$(/usr/bin/grep -c 'reintroduced by mutation' "$GATE_MUT")"
BUDGET_FN_BODY_MUT="$(sed -n '/^  budget_roster_counts() {/,/^  }$/p' "$GATE_MUT")"
expect_contains "…and the doctored body now DOES carry the token (the pin above discriminates)" \
  "landing-swept" "$BUDGET_FN_BODY_MUT"
rm -rf "$GATE_MUT_ROOT"

# ============================ S22b2: WHOSE TRANSCRIPT IT IS DECIDES THE FIX NAMED
# (F-2 ruling, Chris 2026-09-05: dispatch is an AUTHORITY the orchestrator holds alone,
# not a capability gated by freshness.)
#
# WHEN the refusal fires is unchanged — every arm in S22b above still refuses on exactly
# the same freshness reading. What changes is the FIX it names when the dispatching
# transcript is a SUBAGENT's own: "call ListAgents, then dispatch" is advice a dispatched
# agent cannot follow, because ListAgents is not in its tool roster. The Step-5 auditor hit
# precisely that, live and unplanned (auditor-report.md F-2). It is now told the thing it
# CAN do instead: ask the orchestrator.
#
# A subagent's transcript is the harness's own shape — `<session-uuid>/subagents/agent-<name>-<hash>.jsonl`
# beside the orchestrator's `<session-uuid>.jsonl`.
#
# THE PAIR IS THE POINT. Both halves below use the same repo shape, the same budget, the
# same roster row and the same STALE answer. Only the transcript's own PATH differs, so
# nothing but the path can be what moves the text.
#
# MUTATION NOTE: make the subagent branch of the refusal in hooks/dispatch-preflight.sh
# print the orchestrator line again (delete the branch, keep one echo) and r22jf's two
# text arms go red while every r22jg arm stays green. Captured in s18-mutation.log.

section "S22b2: a subagent is told to ask, not to call a tool it lacks"

REPO=$(make_repo r22jf yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "r1"
mkdir -p "$SANDBOX/.r22jf/subagents"
R22JF_SUB="$SANDBOX/.r22jf/subagents/agent-w99-impl-9b70c3a4dc62ba69.jsonl"
mk_transcript "$R22JF_SUB" stale r1
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22JF_SUB")"
expect_status "r22jf a SUBAGENT own transcript, same STALE answer -> still REFUSED" "2" "$GATE_ST"
expect_contains "...keeping the live-agents prefix with the state and age every consumer parses" \
  "live-agents: stale age=" "$GATE_ERR"
expect_contains "...but the fix names the authority, not the tool call" \
  "subagents do not dispatch; dispatch is the orchestrator's authority — SendMessage the orchestrator (to: main) naming what you need" \
  "$GATE_ERR"
expect_absent "...and never names a tool a subagent does not hold" \
  "call ListAgents, then dispatch" "$GATE_ERR"

# The orchestrator half of the pair: same staleness, a session-level transcript path, and
# the text is the one every existing arm above already pins, byte for byte.
REPO=$(make_repo r22jg yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "r1"
R22JG_MAIN="$SANDBOX/.r22jg-session.jsonl"
mk_transcript "$R22JG_MAIN" stale r1
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22JG_MAIN")"
expect_status "r22jg the orchestrator own transcript, same STALE answer -> REFUSED" "2" "$GATE_ST"
expect_contains "...naming the state and age the same way" "live-agents: stale age=" "$GATE_ERR"
expect_contains "...and the orchestrator fix unchanged" "call ListAgents, then dispatch" "$GATE_ERR"
expect_absent "...saying nothing about subagents" "subagents do not dispatch" "$GATE_ERR"

# THE DISCRIMINATOR. The `subagents/` directory is what the harness uses; a file that
# merely happens to be named `agent-*.jsonl` somewhere else is not a subagent transcript,
# and must still get the orchestrator text. Without this arm a match on the basename alone
# would pass the two arms above.
mkdir -p "$SANDBOX/.r22jg-lookalike"
R22JG_LOOKALIKE="$SANDBOX/.r22jg-lookalike/agent-not-under-subagents.jsonl"
mk_transcript "$R22JG_LOOKALIKE" stale r1
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22JG_LOOKALIKE")"
expect_status "r22jg an agent-*.jsonl NOT under subagents/ is not a subagent -> REFUSED" "2" "$GATE_ST"
expect_contains "...with the orchestrator fix, not the subagent one" \
  "call ListAgents, then dispatch" "$GATE_ERR"

# ============================== S22c: A FINISHED-BUT-UNSTOPPED AGENT IS NOT A WRITER
# (spec R2, AC-27; slice S16, closing the Step-5 auditor's F-1.)
#
# R2 names two departure modes — "delivered and stopped, or finished and never stopped".
# S22b counts a row open on PRESENCE, which discharges the first and misses the second:
# the harness keeps listing a teammate that finished its turn and was never TaskStop'd,
# with status `idle`, because it stays addressable (a SendMessage would resume it). Under
# presence-counting that finished agent holds a writer slot until somebody stops it —
# B-1's stuck-slot defect wearing a new coat.
#
# THE RULE. A roster row counts OPEN only when its name is present in the fresh answer
# with status `running`. Presence is still what the STOP GUARD resolves on (an idle agent
# is exactly the one you stop), and both consumers read the one parse — the budget
# through `live_agents_status`, the guard through `live_agents_has` — so they cannot
# disagree about who is listed, only about what the status means. AMBIGUITY (a name
# listed twice, exit 2) still counts OPEN: the reader could not resolve it, and spending
# a slot beats handing one out on a reading nobody could make.
#
# Every arm below holds the roster, the repo and the budget fixed and moves ONLY the
# status in the answer, so nothing but the status can explain the verdict.

section "S22c: an idle (finished, unstopped) teammate does not count open"

# (a) THE HEADLINE. Byte-for-byte r22jb's fixture — one row `r1`, writers=1, r1 named in
# a fresh answer — with `running` changed to `idle`. r22jb REFUSES. This must pass.
REPO=$(make_repo r22ka yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "r1"
R22KA_T="$SANDBOX/.r22ka.jsonl"
mk_transcript "$R22KA_T" fresh "r1:idle"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22KA_T")"
expect_status "r22ka an idle (finished, unstopped) teammate does NOT count open" "0" "$GATE_ST"
expect_absent "…so no writers refusal is printed at all" "writers:" "$GATE_ERR"
expect_absent "…and the dispatch is not blocked" "BLOCKED" "$GATE_ERR"

# The meta-row: the fixture really did say idle. Without it, a builder that silently
# dropped the status and wrote nothing would make (a) pass for the wrong reason.
expect_contains "r22ka meta: the answer body names r1 idle, not running" \
  "r1 [8895ce]  ·  bionic:implementor  ·  idle" "$(cat "$R22KA_T")"

# (b) THE DISCRIMINATING PAIR, on one answer. Two rows, one idle and one running,
# against writers=1: the count is 1, not 2 and not 0. A rule that ignored status would
# say 2; a rule that stopped counting altogether would say 0 and let this through.
REPO=$(make_repo r22kb yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "r1"
s22_roster_row "$REPO" "$SID_A" "r2"
R22KB_T="$SANDBOX/.r22kb.jsonl"
mk_transcript "$R22KB_T" fresh "r1:idle" "r2:running"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22KB_T")"
expect_status "r22kb one idle row and one running row against writers=1 -> REFUSED" "2" "$GATE_ST"
expect_contains "…counting the running one ONLY: open=1, not open=2" \
  "writers: budget=1 open=1 with-this-dispatch=2" "$GATE_ERR"

# (c) AMBIGUITY IS STILL OPEN, and it is the arm that keeps (a) from being read as
# "anything the reader cannot call running is free". The same name twice — two sessions
# in one root launching same-named agents — is unresolvable, so the slot is spent.
REPO=$(make_repo r22kc yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "r1"
R22KC_T="$SANDBOX/.r22kc.jsonl"
mk_transcript "$R22KC_T" fresh "r1:idle" "r1:idle"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22KC_T")"
expect_status "r22kc the same name listed TWICE is unresolvable -> still counted open" \
  "2" "$GATE_ST"
expect_contains "…open=1 on the safe direction, even though neither copy reads running" \
  "writers: budget=1 open=1 with-this-dispatch=2" "$GATE_ERR"

# (d) FRESHNESS STILL COMES FIRST. A STALE answer refuses the whole dispatch before any
# status is consulted — an idle row on a stale answer says nothing about now.
REPO=$(make_repo r22kd yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "r1"
R22KD_T="$SANDBOX/.r22kd.jsonl"
mk_transcript "$R22KD_T" stale "r1:idle"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22KD_T")"
expect_status "r22kd a STALE answer refuses before the status is read" "2" "$GATE_ST"
expect_contains "…naming the state and the fix" "call ListAgents, then dispatch" "$GATE_ERR"

# (e) THE REAL ANSWER, byte-verbatim. Everything above is synthesised from the harness's
# shape; this arm drives the shipped hook against a body captured from this project's own
# orchestrator session at 2026-09-05T03:07:41.801Z — `s6-stop-resolution` idle beside
# `s5-dispatch-budget` running, the moment S6 had delivered its report and had not yet
# been stopped (the stop is recorded at 03:07:46.215Z, five seconds later). Both names
# are on the roster and the budget is two: presence-counting fills it and refuses; the
# rule under test counts the one running writer and lets the dispatch through.
REPO=$(make_repo r22ke yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=2 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "s6-stop-resolution"
s22_roster_row "$REPO" "$SID_A" "s5-dispatch-budget"
# THE BODY IS THE CORPUS'S OWN LINE, not a copy of it (S17). This section is about ONE
# REAL ANSWER — the 03:07:41.801Z one, an idle writer beside a running one — and that
# answer is committed at tests/fixtures/claude/listagents-answers.jsonl as the line
# `LIVE_ANSWER_MIXED_LINE` names. Read back rather than re-typed, so the two names below
# and the two names on the roster rows above cannot drift apart from it.
R22KE_BODY="$(live_answer_content "$LIVE_ANSWER_MIXED_LINE")"
R22KE_T="$SANDBOX/.r22ke.jsonl"
{
  entry_prompt      "2026-09-05T03:07:30.000Z" "land S6"
  entry_tool_use    "2026-09-05T03:07:40.000Z" "ListAgents" "toolu_01Amv2QjVrsFDp5uVfKEowty"
  entry_tool_result "2026-09-05T03:07:41.801Z" "toolu_01Amv2QjVrsFDp5uVfKEowty" "$R22KE_BODY"
} > "$R22KE_T"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22KE_T")"
expect_status "r22ke the real 03:07:41.801Z answer: one finished writer, one working -> allowed at writers=2" \
  "0" "$GATE_ST"
expect_absent "…no writers refusal, because open=1 and not 2" "writers:" "$GATE_ERR"

# The paired direction on the SAME real body: at writers=1 the one genuinely running
# writer fills the budget, and the refusal names open=1. This is what keeps (e) from
# passing against a gate that had simply stopped counting.
REPO=$(make_repo r22kf yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "s6-stop-resolution"
s22_roster_row "$REPO" "$SID_A" "s5-dispatch-budget"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22KE_T")"
expect_status "r22kf …and at writers=1 the still-running one alone fills it -> REFUSED" \
  "2" "$GATE_ST"
expect_contains "…open=1, the finished agent uncounted" \
  "writers: budget=1 open=1 with-this-dispatch=2" "$GATE_ERR"

# (f) THE CLAIMED (suites) COUNT RIDES THE SAME PREDICATE. A `claims=` row whose agent
# has finished must not hold a suite allowance either — otherwise the two ceilings would
# disagree about the same departed agent.
REPO=$(make_repo r22kg yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=9 suites=1 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "r1" "live-agents"
R22KG_T="$SANDBOX/.r22kg.jsonl"
mk_transcript "$R22KG_T" fresh "r1:running"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22KG_T")"
expect_status "r22kg meta: a RUNNING claimant fills suites=1 (the control)" "2" "$GATE_ST"
expect_contains "…naming the claimed count" "suites: budget=1 claimed=1 with-this-dispatch=2" "$GATE_ERR"
mk_transcript "$R22KG_T" fresh "r1:idle"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22KG_T")"
expect_status "r22kg the SAME claimant, now idle, releases its suite allowance" "0" "$GATE_ST"
expect_absent "…no suites refusal" "suites:" "$GATE_ERR"

# (g) FAIL-CLOSED ON AN UNKNOWN STATUS WORD (S19, Step-5 auditor F-13). S16 counted a row
# open only on the exact word `running`, which made every OTHER word — a renamed status, a
# third one the harness starts printing — read as CLOSED and hand out a writer slot. That is
# fail-OPEN, and it sat inside the same function whose ambiguity arm (c) is deliberately
# fail-CLOSED. The rule is now `open unless the harness said idle`, owned by
# `live_row_open` in payload/scripts/lib/agents.sh, and these two arms are the inversion.
#
# `starting` is deliberately a word the measured corpus does NOT contain: 26 captured
# answers, 44 teammate rows, two words only — 33 `running`, 11 `idle`. The predicate must
# not depend on that staying true.
REPO=$(make_repo r22kh yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "r1"
R22KH_T="$SANDBOX/.r22kh.jsonl"
mk_transcript "$R22KH_T" fresh "r1:starting"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22KH_T")"
expect_status "r22kh an UNKNOWN third status word still counts OPEN -> REFUSED" "2" "$GATE_ST"
expect_contains "…open=1, the slot kept on a reading nobody has seen before" \
  "writers: budget=1 open=1 with-this-dispatch=2" "$GATE_ERR"
expect_contains "r22kh meta: the answer body really says starting, not running" \
  "r1 [8895ce]  ·  bionic:implementor  ·  starting" "$(cat "$R22KH_T")"

# THE DISCRIMINATING PAIR for (g), on one roster and one budget: the SAME row read `idle`
# is let through. Without it, r22kh would pass against a gate that had gone back to
# counting presence — and presence is exactly what S16 removed.
mk_transcript "$R22KH_T" fresh "r1:idle"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22KH_T")"
expect_status "…while the SAME row read idle is still not open -> allowed" "0" "$GATE_ST"
expect_absent "…and prints no writers refusal" "writers:" "$GATE_ERR"

# (h) THE SUITE ALLOWANCE RIDES THE SAME PREDICATE, on the unknown word too. r22kg proved
# `claims=` follows the running/idle split; this proves it follows the ONE predicate rather
# than a second copy of the word `running` living in the claim arm.
REPO=$(make_repo r22ki yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=9 suites=1 worktrees=9 test_jobs=4 source=probe"
s22_roster_row "$REPO" "$SID_A" "r1" "live-agents"
R22KI_T="$SANDBOX/.r22ki.jsonl"
mk_transcript "$R22KI_T" fresh "r1:starting"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22KI_T")"
expect_status "r22ki an unknown-status claimant still HOLDS its suite allowance" "2" "$GATE_ST"
expect_contains "…naming the claimed count" "suites: budget=1 claimed=1 with-this-dispatch=2" "$GATE_ERR"
mk_transcript "$R22KI_T" fresh "r1:idle"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w99-impl" "claude-sonnet-5" "$R22KI_T")"
expect_status "…and the SAME claimant read idle releases it" "0" "$GATE_ST"
expect_absent "…no suites refusal" "suites:" "$GATE_ERR"

# (i) THE PREDICATE HAS ONE OWNER, and this gate is not a second copy of it. The inline
# `status = running` test S16 wrote lived here; S19 deleted it. A grep is the honest
# observable for "the rule is not spelled twice", and the anti-vacuity arm below proves the
# grep can see the string it is looking for.
expect_eq "the hook carries no inline status-word predicate of its own" "0" \
  "$(/usr/bin/grep -c '"\$la_st" = "running"' "$GATE")"
expect_eq "…and asks the library's one predicate by name instead" "1" \
  "$( [ "$(/usr/bin/grep -c 'live_row_open' "$GATE")" -ge 1 ] && echo 1 || echo 0 )"
S22K_MUT="$SANDBOX/.s22k-inline-mut.sh"
{ printf '# doctored: %s\n' '[ "$la_st" = "running" ] && row_open=yes'; cat "$GATE"; } > "$S22K_MUT"
expect_eq "…and the grep really can see that string when it is there (not vacuous)" "1" \
  "$(/usr/bin/grep -c '"\$la_st" = "running"' "$S22K_MUT")"

# ============================================ S23: THE ORCHESTRATOR-IN-WORKTREE ARM
# (spec AC-14; handoff 2.5.)
#
# A worktree is LEASED to the writer it was spawned for. A main-thread dispatch made
# from inside one is an orchestrator that has moved into a writer's tree — the roster
# it appends to hangs off the MAIN checkout (project_root maps the worktree back), so
# the dispatch is journalled in one address space while its author works in another,
# and the tree's own lease has no row that accounts for the orchestrator. The refusal
# names the main checkout, which is where dispatch authority sits.
#
# AN AGENT CONTEXT IS ALLOWED, and that is the whole point of the arm: a writer
# dispatched INTO a tree works there by construction, and refusing it would refuse the
# arrangement the wave is built on. Two spellings mark an agent context — the guard's
# BIONIC_HOOK_CHANNEL on the settings channel, and the payload's own `agent_type`,
# which the harness sets for a dispatched agent — and either one is enough.

section "S23: a main-thread dispatch from inside a linked worktree"

REPO=$(make_repo r23a yes)
write_attestation "$REPO" "$SID_A"
git -C "$REPO" worktree add -q -b wt/one "$REPO/.worktrees/one" >/dev/null 2>&1
S23_TREE="$REPO/.worktrees/one"
# PHYSICAL, because every root this gate prints is: project_root resolves with `pwd -P`
# and the sandbox sits under macOS's /var -> /private/var link. Comparing the refusal's
# main-checkout line against the LOGICAL fixture path would fail on the link alone,
# which is the same trap tests/canonical-sdlc-governing-skill.test.sh's make_project
# documents.
S23_MAIN=$( cd "$REPO" && pwd -P )

run_gate "$(mk_agent_payload "$SID_A" "$REPO")"
expect_status "r23a a dispatch from the MAIN checkout passes (the control)" "0" "$GATE_ST"

run_gate "$(mk_agent_payload "$SID_A" "$S23_TREE")"
expect_status "r23b the same dispatch from inside the linked worktree is REFUSED" "2" "$GATE_ST"
expect_contains "…naming the main checkout" "main checkout: $S23_MAIN" "$GATE_ERR"
expect_contains "…and the tree it was made from" "$S23_TREE" "$GATE_ERR"

# The settings-channel spelling of an agent context.
GATE_ENV="$GATE_ENV BIONIC_HOOK_CHANNEL=agent-context"
run_gate "$(mk_agent_payload "$SID_A" "$S23_TREE")"
GATE_ENV="${GATE_ENV% BIONIC_HOOK_CHANNEL=agent-context}"
expect_status "r23c the same dispatch in an agent context (BIONIC_HOOK_CHANNEL) is allowed" "0" "$GATE_ST"

# The payload spelling.
S23_AGENT_PAYLOAD=$(mk_agent_payload "$SID_A" "$S23_TREE" | jq '. + {agent_type:"senior-implementor"}')
run_gate "$S23_AGENT_PAYLOAD"
expect_status "r23d …and so is one whose payload carries agent_type" "0" "$GATE_ST"

section "S24 — THE ENGAGEMENT SWITCH (AC-5, AC-13, AC-14, AC-23)"
#
# The switch this wave adds, driven in both directions on ONE fixture so neither half can
# be true by accident. Every silence below sits beside the positive it is the negation of:
# the same repo, the same payload, the marker the only difference.

S24_REPO=$(make_repo r24 yes)
# An attestation up front (AC-25 / r24e): without one, r24a's dispatch auto-probes and
# WRITES it as a side effect, adding a one-time "environment check was run
# automatically" advisory line that r24e's later re-dispatch — now that the
# attestation already exists — does not repeat. That made the two refusals differ
# for a reason that had nothing to do with engagement, the thing r24e is testing;
# writing it up front, as every other fixture in this file does, removes the
# confound so "byte-identical" tests only the engagement switch.
write_attestation "$S24_REPO" "$SID_A"
S24_MARK="$S24_REPO/.bionic/tmp/engaged-$SID_A.state"

# (a) ENGAGED — the positive. A dispatch whose brief carries no deliverable is refused
# exactly as it was before this wave existed.
S24_BARE='Go and do the thing. No contract fields at all.'
run_gate "$(mk_agent_payload "$SID_A" "$S24_REPO" "$S24_BARE")"
expect_status "r24a engaged: a dispatch with no deliverable is REFUSED" "2" "$GATE_ST"
expect_contains "…at the absent-deliverable wall" "Expected artifact" "$GATE_ERR"
S24_REFUSAL="$GATE_ERR"

# (b) THE SAME payload, the SAME repo, the marker removed -> nothing at all (AC-5).
rm -f "$S24_MARK"
run_gate "$(mk_agent_payload "$SID_A" "$S24_REPO" "$S24_BARE")"
expect_status "r24b unengaged: the same dispatch exits 0" "0" "$GATE_ST"
expect_empty "r24b …with no stdout" "$GATE_OUT"
expect_empty "r24b …and no stderr" "$GATE_ERR"

# (c) A SYMLINK at the marker path reads as ABSENT, never followed (AC-4's direction, at
# this gate). The link points at a real regular file, so only the -L refusal in
# `engaged_session` can produce this silence.
S24_DECOY="$SANDBOX/r24-decoy-marker"
printf 'plan=none\n' > "$S24_DECOY"
ln -s "$S24_DECOY" "$S24_MARK"
run_gate "$(mk_agent_payload "$SID_A" "$S24_REPO" "$S24_BARE")"
expect_status "r24c a SYMLINK at the marker path exits 0" "0" "$GATE_ST"
expect_empty "r24c …with no stdout" "$GATE_OUT"
expect_empty "r24c …and no stderr" "$GATE_ERR"
rm -f "$S24_MARK"

# (d) A FOREIGN session's marker is not this session's (AC-4).
: > "$S24_REPO/.bionic/tmp/engaged-$SID_B.state"
run_gate "$(mk_agent_payload "$SID_A" "$S24_REPO" "$S24_BARE")"
expect_status "r24d another session's marker exits 0" "0" "$GATE_ST"
expect_empty "r24d …and says nothing" "$GATE_ERR"
rm -f "$S24_REPO/.bionic/tmp/engaged-$SID_B.state"

# (e) THE REFUSAL TEXT IS BYTE-UNCHANGED for an engaged session (AC-13, AC-14). Restoring
# the marker must reproduce (a) exactly — not merely refuse, but refuse in the same words.
: > "$S24_MARK"
run_gate "$(mk_agent_payload "$SID_A" "$S24_REPO" "$S24_BARE")"
expect_eq "r24e re-engaged: the refusal is byte-identical to r24a" "$S24_REFUSAL" "$GATE_ERR"

# META (spec AC-25): r24e must not be vacuous the way it was before this slice — a
# DOCTORED refusal (one byte changed) has to make it FAIL. Run in a subshell so the
# probe's own local ok/no/PASS/FAIL shadow the real ones and never touch this suite's
# actual counts; only the verdict below is a real assertion.
(
  PASS=0; FAIL=0; TOTAL=0
  ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); }
  no() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); }
  expect_eq "probe" "$S24_REFUSAL" "${S24_REFUSAL}Z"
  exit "$FAIL"
)
if [ $? -ne 0 ]; then
  ok "r24e meta: a doctored refusal (one byte changed) makes expect_eq report a failure"
else
  no "r24e meta: a doctored refusal did NOT make expect_eq fail — the assertion is vacuous"
fi

# ---------- ENGAGED WITH NO PLAN ON DISK (AC-23) ----------
#
# The half of the ruling that is not "silence": engagement decides WHETHER a hook acts,
# the plan decides WHAT. A run's Step 0 precedes its own plan, and the walls that need no
# plan are owed from the first dispatch.
S24_NOPLAN=$(make_repo r24np yes)
rm -rf "$S24_NOPLAN/.bionic/docs"

# the Patrol checkpoint is plan-free: no stamp, no dispatch.
rm -f "$S24_NOPLAN/.bionic/tmp/patrol-$SID_A.state"
run_gate "$(mk_agent_payload "$SID_A" "$S24_NOPLAN")"
expect_status "r24f engaged, no plan, no stamp -> REFUSED at the Patrol checkpoint" "2" "$GATE_ST"
expect_contains "…naming the Patrol" "Patrol" "$GATE_ERR"

# the deliverable wall is plan-free too: stamp back, brief stripped.
printf 'patrol-stamp/v1|at=%s|session=%s|verb=arm\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SID_A" > "$S24_NOPLAN/.bionic/tmp/patrol-$SID_A.state"
run_gate "$(mk_agent_payload "$SID_A" "$S24_NOPLAN" "$S24_BARE")"
expect_status "r24g engaged, no plan, no deliverable -> REFUSED" "2" "$GATE_ST"
expect_contains "…at the absent-deliverable wall" "Expected artifact" "$GATE_ERR"

# the BUDGET wall is plan-bound: it measures against a ceiling only a plan can declare,
# so with no plan it says nothing. Driven with a contract-complete brief so the walls
# above have nothing to say, and the silence is the budget wall's own.
run_gate "$(mk_agent_payload "$SID_A" "$S24_NOPLAN")"
expect_status "r24h engaged, no plan, a complete brief -> passes" "0" "$GATE_ST"
expect_absent "r24h …and the budget wall stays silent" "parallel-budget" "$GATE_ERR"

# THE PAIRED POSITIVE, so r24h is not silence-by-vacuity: the same dispatch against a plan
# whose ceiling is already full IS refused by that wall.
S24_BUDGET=$(make_repo r24bw yes)
S24_PLAN="$S24_BUDGET/.bionic/docs/plans/epic-99-test/wave-01-test.plan.md"
awk 'NR==2 { print "parallel-budget: writers=0 suites=4 worktrees=32 test_jobs=8 source=probe" } { print }' \
  "$S24_PLAN" > "$S24_PLAN.tmp" && mv "$S24_PLAN.tmp" "$S24_PLAN"
run_gate "$(mk_agent_payload "$SID_A" "$S24_BUDGET")"
expect_status "r24i the same brief against a FULL budget is REFUSED" "2" "$GATE_ST"
expect_contains "…by the budget wall" "writers" "$GATE_ERR"

# and the same full budget with NO plan-free failure and NO marker is silent.
rm -f "$S24_BUDGET/.bionic/tmp/engaged-$SID_A.state"
run_gate "$(mk_agent_payload "$SID_A" "$S24_BUDGET")"
expect_status "r24j …and unengaged, that same full budget decides nothing" "0" "$GATE_ST"
expect_empty "r24j …silently" "$GATE_ERR"

setup_section "S25 — active_run -> session_run (wave-session-bound-run S5)"
#
# THE CONTRACT UNDER TEST (design ledger AC-1/AC-3/AC-6). `PLAN` used to come from
# `active_run "$REPO"` — the newest open plan in the root, with no session input at
# all. It now comes from `session_run "$REPO" "$PAYLOAD_SID"`: a session BOUND to a
# plan (`.bionic/tmp/engaged-<sid>.state` carrying `plan=<path>`) is gated on that
# plan and that plan alone, whatever else is open in the root; an UNBOUND session
# (the marker empty, as make_repo's own engaged-* fixtures are) resolves by
# newest-plan exactly as before, and says so on stderr; a session bound to a plan
# that has since closed is treated as having no open run at all, and says that too.
#
# s25_bind <repo> <sid> <plan-abs-path> — overwrites the marker make_repo already
# planted (empty = unbound) with a real binding, under the same two-line shape
# hooks/engage.sh writes (spec §Session binding), via the real `bind_plan` (S11,
# tests/lib/bound-marker.sh).
s25_bind() {
  bound_marker "$1" "$2" "$3"
}

# s25_repo <name> <budget-a> <budget-b> -> sets the globals S25_REPO / S25_PLAN_A
# / S25_PLAN_B (a plain call, never `$(...)` — a command substitution runs in a
# subshell, and every assignment here would be lost the instant it returned). A
# and B are the ONLY open plans in the root — make_repo's own default plan is
# removed — and A is older by mtime, so an UNBOUND session's fallback is
# decisively B.
s25_repo() {
  local name="$1" budget_a="$2" budget_b="$3"
  local repo; repo=$(make_repo "$name" yes)
  rm -f "$repo/.bionic/docs/plans/epic-99-test/wave-01-test.plan.md"
  S25_REPO="$repo"
  S25_PLAN_A="$repo/.bionic/docs/plans/epic-99-test/plan-a.plan.md"
  S25_PLAN_B="$repo/.bionic/docs/plans/epic-99-test/plan-b.plan.md"
  cat > "$S25_PLAN_A" <<PLANA
---
governing-skill: canonical-sdlc
canonical_sdlc_version: 14
parallel-budget: $budget_a
---

## SDLC State

current: 4

- Step 4: plan A in flight
PLANA
  cat > "$S25_PLAN_B" <<PLANB
---
governing-skill: canonical-sdlc
canonical_sdlc_version: 14
parallel-budget: $budget_b
---

## SDLC State

current: 4

- Step 4: plan B in flight
PLANB
  touch -t 202601010000 "$S25_PLAN_A"
  touch -t 202602010000 "$S25_PLAN_B"
}

# s25_deliver <plan-abs-path> — closes a plan (Step 9, delivered).
s25_deliver() {
  cat > "$1" <<'PLANDONE'
---
governing-skill: canonical-sdlc
canonical_sdlc_version: 14
---

## SDLC State

current: 9

- Step 9: report record/x.md, delivered: 2026-09-04
PLANDONE
}

section "S25a: bound-open — the caller's OWN plan is the ceiling"

# A's budget is tight (writers=1, already at the ceiling with one open row); B's is
# loose (writers=99). Bound to A, the dispatch is refused by A's ceiling — proof
# that a second open plan in the same root (B, newer, looser) is never consulted.
s25_repo r25a "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe" \
              "writers=99 suites=9 worktrees=9 test_jobs=4 source=probe"
write_attestation "$S25_REPO" "$SID_A"
s25_bind "$S25_REPO" "$SID_A" "$S25_PLAN_A"
s22_roster_row "$S25_REPO" "$SID_A" "W-ONE"
run_gate "$(mk_agent_payload "$SID_A" "$S25_REPO")"
expect_status "25a1: bound to A (tight budget), the dispatch is REFUSED by A's ceiling" "2" "$GATE_ST"
expect_contains "25a2: …naming A as the plan the budget came from" "$S25_PLAN_A" "$GATE_ERR"
expect_absent "25a3: …and B's path is never named" "$S25_PLAN_B" "$GATE_ERR"
expect_absent "25a4: bound: no fallback line is printed" \
  "run resolved by newest-plan fallback" "$GATE_ERR"

section "S25b: fallback — unbound resolves to the newest plan, and says so"

# The SAME shape, a fresh repo, budgets swapped so B (the newest, and now the
# fallback target) is the tight one. Left UNBOUND (make_repo's own empty marker,
# untouched), the dispatch is refused by B's ceiling, not A's — and the gate
# prints the fallback advisory naming B. The positive (line present, B used) sits
# beside its negative (line absent once bound) on the same fixture.
s25_repo r25b "writers=99 suites=9 worktrees=9 test_jobs=4 source=probe" \
              "writers=1 suites=9 worktrees=9 test_jobs=4 source=probe"
S25_REPO2="$S25_REPO"
# PHYSICAL, because the fallback path comes off active_plan's own resolution —
# `project_root` calls `pwd -P` internally (payload/scripts/lib/root.sh) — while
# $S25_PLAN_B is built from the SANDBOX's logical path (plain `pwd`, no `-P`, in
# this file's own SANDBOX= line). The two differ under macOS's /var -> /private/var
# link, and unlike a bare path-substring check (25b2/25b3, which match anywhere
# in GATE_ERR), this assertion pins an exact adjacency — "— " immediately
# followed by the path — so it needs the SAME physical form the hook itself
# prints. Mirrors tests/dispatch-preflight.test.sh S23's own S23_MAIN idiom.
S25_PLAN_B_PHYS="$(cd "$S25_REPO2" && pwd -P)/.bionic/docs/plans/epic-99-test/plan-b.plan.md"
write_attestation "$S25_REPO2" "$SID_A"
s22_roster_row "$S25_REPO2" "$SID_A" "W-ONE"
run_gate "$(mk_agent_payload "$SID_A" "$S25_REPO2")"
expect_status "25b1: unbound, the dispatch is REFUSED by B's (newest) ceiling" "2" "$GATE_ST"
expect_contains "25b2: …naming B as the plan the budget came from" "$S25_PLAN_B" "$GATE_ERR"
expect_absent "25b3: …and A's path is never named" "$S25_PLAN_A" "$GATE_ERR"
expect_contains "25b4: …and the fallback advisory names B, verbatim" \
  "dispatch-preflight: run resolved by newest-plan fallback (session unbound) — $S25_PLAN_B_PHYS" \
  "$GATE_ERR"

# THE NEGATIVE, same repo, same payload, only the binding added: once bound to A
# the fallback line disappears (A's loose budget also lets the dispatch through).
s25_bind "$S25_REPO2" "$SID_A" "$S25_PLAN_A"
run_gate "$(mk_agent_payload "$SID_A" "$S25_REPO2")"
expect_status "25b5: the SAME repo, now bound to A (loose budget), passes" "0" "$GATE_ST"
expect_absent "25b6: …and the fallback advisory is gone" \
  "run resolved by newest-plan fallback" "$GATE_ERR"

section "S25c: bound-closed — a plan that closed is no open run at all"

# A is delivered (closed); B stays open, with a ceiling of zero — so if B were
# consulted at all, ANY dispatch would refuse. Bound to closed A, the dispatch
# passes (the budget wall is inert, as it is for any engaged-with-no-plan
# session) and the closed-plan advisory names A; B's path is nowhere in the
# output, proving B was never the fallback here.
s25_repo r25c "suites=9 worktrees=9 test_jobs=4 source=probe" \
              "writers=0 suites=9 worktrees=9 test_jobs=4 source=probe"
S25_REPO3="$S25_REPO"
s25_deliver "$S25_PLAN_A"
write_attestation "$S25_REPO3" "$SID_A"
s25_bind "$S25_REPO3" "$SID_A" "$S25_PLAN_A"
run_gate "$(mk_agent_payload "$SID_A" "$S25_REPO3")"
expect_status "25c1: bound to a CLOSED plan (A), the dispatch passes — the budget wall is inert" \
  "0" "$GATE_ST"
expect_contains "25c2: …and the closed-plan advisory names A, verbatim" \
  "dispatch-preflight: bound plan closed — $S25_PLAN_A; this session has no open run" \
  "$GATE_ERR"
expect_absent "25c3: …B's path (the still-open plan) appears nowhere" "$S25_PLAN_B" "$GATE_ERR"
expect_absent "25c4: …nor does the writers=0 budget line B carries" "writers=0" "$GATE_ERR"

section "S25d: the roster row's plan= field (AC-2, §Roster attribution)"

# Roster attribution is the BINDING, not the resolved run: a session bound to A
# gets plan=A on its row even though the budget/fallback logic above resolves
# differently case by case. An unbound session's row carries the literal "none".
s25_repo r25d "suites=9 worktrees=9 test_jobs=4 source=probe" \
              "suites=9 worktrees=9 test_jobs=4 source=probe"
S25_REPO4="$S25_REPO"
# PHYSICAL, same reason as S25_PLAN_B_PHYS above: s25_bind (S11) writes through the real
# bind_plan, which stores the CANONICAL directory (`pwd -P`), not the sandbox's logical one.
S25_PLAN_A_PHYS="$(cd "$S25_REPO4" && pwd -P)/.bionic/docs/plans/epic-99-test/plan-a.plan.md"
write_attestation "$S25_REPO4" "$SID_A"
s25_bind "$S25_REPO4" "$SID_A" "$S25_PLAN_A"
run_gate "$(mk_agent_payload "$SID_A" "$S25_REPO4")"
expect_status "25d1: bound dispatch passes" "0" "$GATE_ST"
S25_ROW=$(roster_nth_row "$(roster_path "$S25_REPO4" "$SID_A")" 1)
expect_status "25d2: the row's plan= field is A's path, verbatim" "$S25_PLAN_A_PHYS" \
  "$(roster_field "$S25_ROW" plan)"

s25_repo r25e "suites=9 worktrees=9 test_jobs=4 source=probe" \
              "suites=9 worktrees=9 test_jobs=4 source=probe"
S25_REPO5="$S25_REPO"
write_attestation "$S25_REPO5" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$S25_REPO5")"
expect_status "25d3: unbound dispatch passes" "0" "$GATE_ST"
S25_ROW2=$(roster_nth_row "$(roster_path "$S25_REPO5" "$SID_A")" 1)
expect_status "25d4: the row's plan= field is the literal 'none'" "none" \
  "$(roster_field "$S25_ROW2" plan)"

# --- S25d5: a plan path carrying a `|` cannot forge a row (S10a, review SEC F3) ---
#
# THE ROW IS PIPE-DELIMITED ON ONE LINE, which is why `sanitize()` exists and why every
# other interpolated value on it goes through that filter first. `plan=` is the field this
# wave added and was the one field that skipped it, while the parallel writer in
# `session-poker.sh adopt` filtered the same value through `clean()` — so the two writers
# disagreed about whether the field was trusted.
#
# THE FIXTURE IS A REAL FILE. A plan named `wave-99|status=landed|name=ghost.plan.md` is a
# legal filename on every filesystem bionic runs on, so no part of this is hypothetical.
#
# WHAT IS ASSERTED IS THE ROW'S SHAPE, not just the field's text: a forged `status=landed`
# would lose to the real one at `line_field`'s `head -1` today, which makes a value-only
# assertion pass for a reason that could evaporate under any reader change. The field COUNT
# is what says no segment was injected.
s25_repo r25f "suites=9 worktrees=9 test_jobs=4 source=probe" \
              "suites=9 worktrees=9 test_jobs=4 source=probe"
S25_REPO6="$S25_REPO"
write_attestation "$S25_REPO6" "$SID_A"
S25_EVIL="$S25_REPO6/.bionic/docs/plans/epic-99-test/wave-99|status=landed|name=ghost.plan.md"
cp "$S25_PLAN_A" "$S25_EVIL"
# PHYSICAL, same reason as S25_PLAN_B_PHYS above: s25_bind (S11) now writes through the
# real bind_plan, which resolves the marker's DIRECTORY with `pwd -P` and leaves the leaf
# (the pipe-bearing filename) untouched — so the roster row's plan= field carries this
# physical directory spelling, not the logical $S25_EVIL one.
S25_EVIL_PHYS="$(cd "$(dirname "$S25_EVIL")" && pwd -P)/$(basename "$S25_EVIL")"
expect_status "25d5a: the pipe-bearing plan file really exists (non-vacuity)" "yes" \
  "$([ -f "$S25_EVIL" ] && echo yes || echo no)"
s25_bind "$S25_REPO6" "$SID_A" "$S25_EVIL"
run_gate "$(mk_agent_payload "$SID_A" "$S25_REPO6")"
expect_status "25d5b: the dispatch still passes" "0" "$GATE_ST"
S25_ROW3=$(roster_nth_row "$(roster_path "$S25_REPO6" "$SID_A")" 1)
S25_ROW_CLEAN=$(roster_nth_row "$(roster_path "$S25_REPO4" "$SID_A")" 1)
expect_status "25d5c: the row has exactly as many pipe-delimited fields as a clean row" \
  "$(printf '%s' "$S25_ROW_CLEAN" | tr -cd '|' | wc -c | tr -d ' ')" \
  "$(printf '%s' "$S25_ROW3" | tr -cd '|' | wc -c | tr -d ' ')"
expect_status "25d5d: status is still the writer's own value, not the injected one" "intended" \
  "$(roster_field "$S25_ROW3" status)"
expect_status "25d5e: name is still the dispatched agent's, not the injected one" \
  "$(roster_field "$S25_ROW_CLEAN" name)" "$(roster_field "$S25_ROW3" name)"
expect_status "25d5f: and plan= holds the path with its pipes neutralised" \
  "$(printf '%s' "$S25_EVIL_PHYS" | tr '|' ' ')" "$(roster_field "$S25_ROW3" plan)"

# ================================================== S26: ONE TRANSCRIPT PARSE PER GATE
#
# Step-6 review P-1. The budget loop asks `live_row_open` once per unique `status=intended`
# name, and each ask used to run two whole-file `jq` passes over the transcript. Twelve
# rows against a 4.1 MB transcript measured 1.22 s — over the ~1 s budget for a hook that
# fronts every dispatch — and the row count grows for the life of a session while the
# transcript grows too. `live_agents` now memoizes its parse per process, and the loop
# primes that cache once in the shell the loop runs in, because the per-row call is a
# command substitution and a subshell's cache write dies with it.
#
# THE COUNT IS THE PIN, not the timing. A `jq` shim on PATH records one line per
# invocation whose argv names the transcript; the answer must be 2 (one `_la_scan`, one
# `_la_body`) no matter how many rows the roster carries.
section "S26: the budget parses the transcript once, not once per row"

S26_SHIM="$SANDBOX/s26shim"
mkdir -p "$S26_SHIM"
S26_REAL_JQ="$(command -v jq)"
S26_COUNT="$SANDBOX/.s26-jq-calls"
cat > "$S26_SHIM/jq" <<S26EOF
#!/bin/bash
for _a in "\$@"; do
  case "\$_a" in *"\$LA_COUNT_TRANSCRIPT") printf '%s\n' "\$_a" >> "\$LA_COUNT_FILE" ;; esac
done
exec "$S26_REAL_JQ" "\$@"
S26EOF
chmod +x "$S26_SHIM/jq"

REPO=$(make_repo r26 yes)
write_attestation "$REPO" "$SID_A"
s22_set_budget "$REPO" "writers=99 suites=9 worktrees=9 test_jobs=4 source=probe"
S26_N=1
while [ "$S26_N" -le 12 ]; do
  s22_roster_row "$REPO" "$SID_A" "r26-$S26_N"
  S26_N=$((S26_N + 1))
done
S26_T="$SANDBOX/.r26.jsonl"
mk_transcript "$S26_T" fresh W-OTHER

: > "$S26_COUNT"
S26_SAVED_ENV="$GATE_ENV"
GATE_ENV="$GATE_ENV PATH=$S26_SHIM:$PATH LA_COUNT_FILE=$S26_COUNT LA_COUNT_TRANSCRIPT=$S26_T"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w26-impl" "claude-sonnet-5" "$S26_T")"
GATE_ENV="$S26_SAVED_ENV"

expect_status "26a twelve intended rows and the gate still passes at writers=99" "0" "$GATE_ST"
expect_status "26b …and the transcript was parsed exactly twice — once per jq pass, not once per row" \
  "2" "$(grep -c . "$S26_COUNT" | tr -d ' ')"

# ============================================================================
section "S27: the suite-allowance wall (AC-20, AC-24)"
# ============================================================================
#
# THE INCIDENT THIS SECTION IS ABOUT. Two dispatched writers finished their own work
# green at ~45 minutes and then spent 40 more re-running the whole tree, one suite at a
# time, in parallel, on an 8 GB machine. Their briefs said "run impacted suites only;
# never tests/run.sh". Prose in a brief is a wish; the roster row is what the writer-side
# guard can read. So the brief declares INTENT (`Files:`) or the closed set (`Suites:`),
# the wall records the budget, and a brief that declares neither is refused here.
#
# THE IMPACT COMMAND IS FIXTURED, NOT REAL. What this section proves is that the wall
# RUNS the configured command over the declared paths and records what comes back — so the
# command is a two-line stub whose answer is unmistakably its own, and doctoring it must
# move the row. Driving the real `tests/lib/impact.sh` through this contract is
# tests/cross-gate-agreement.test.sh's job (one owner per shared truth): a fixture that
# reproduced its output would pin this file to a derivation it does not own.

# s27_impact <repo> <suite>... — writes an impact command into <repo> that answers with
# exactly the named suites, in the `suite<TAB>reason:file` shape S12 published, and points
# .bionic/config.yaml at it. The stub ECHOES ITS ARGUMENTS into a side file, so the test
# can prove the declared paths reached it rather than assuming they did.
s27_impact() {
  local repo="$1"; shift
  mkdir -p "$repo/.bionic"
  {
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" "$@" > "$(dirname "$0")/impact-args.txt"\n'
    local _s
    for _s in "$@"; do printf 'printf "%%s\\tpath-ref:fixture\\n" %s\n' "$_s"; done
  } > "$repo/.bionic/impact-stub.sh"
  chmod +x "$repo/.bionic/impact-stub.sh"
  printf 'impact-command: bash %s/.bionic/impact-stub.sh\n' "$repo" > "$repo/.bionic/config.yaml"
}

BRIEF_FILES='Canonical-sdlc Step 4, slice 4/13 of epic-99 wave-01; build · audited · wave.
Your slice: build the widget.
Expected artifact: .bionic/docs/record/w99-files.md
Expected duration: ~20 minutes.
Files: payload/scripts/lib/widget.sh, hooks/widget-guard.sh'

# --- S27a: Files: + a configured impact command -> the DERIVED row ---
REPO=$(make_repo r27a yes)
write_attestation "$REPO" "$SID_A"
s27_impact "$REPO" beta.test.sh alpha.test.sh
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FILES" "w27-files")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "27a a brief declaring Files: with an impact command PASSES" "0" "$GATE_ST"
expect_status "27a …and the row records the declared paths verbatim" \
  "payload/scripts/lib/widget.sh,hooks/widget-guard.sh" "$(roster_field "$ROW" files)"
expect_status "27a …the derived set is the impact command's answer, sorted and deduplicated" \
  "alpha.test.sh beta.test.sh" "$(roster_field "$ROW" suites_allowed)"
expect_status "27a …and the row says the set was DERIVED, not declared" \
  "derived" "$(roster_field "$ROW" suites_source)"
# NON-VACUITY, both directions. The stub really ran, and it really received the paths the
# brief declared — a wall that ignored the command and wrote a constant would pass every
# assertion above.
expect_status "27a …the impact command was really run" "0" \
  "$([ -f "$REPO/.bionic/impact-args.txt" ] && echo 0 || echo 1)"
expect_eq "27a …over the declared paths, one argument each" \
  "payload/scripts/lib/widget.sh
hooks/widget-guard.sh" "$(cat "$REPO/.bionic/impact-args.txt")"

# --- S27a2: MUTATION — doctor the command, and the row must move ---
# The row is the command's answer, not the wall's opinion of it.
REPO=$(make_repo r27a2 yes)
write_attestation "$REPO" "$SID_A"
s27_impact "$REPO" gamma.test.sh
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FILES" "w27-files2")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "27a2 a DIFFERENT impact command answer lands a different budget" \
  "gamma.test.sh" "$(roster_field "$ROW" suites_allowed)"

# --- S27a3: a derivation that answers NOTHING leaves the budget empty, and warns ---
REPO=$(make_repo r27a3 yes)
write_attestation "$REPO" "$SID_A"
s27_impact "$REPO"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FILES" "w27-files3")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "27a3 an impact command that derives nothing still PASSES the dispatch" "0" "$GATE_ST"
expect_status "27a3 …with an empty budget on the row" "" "$(roster_field "$ROW" suites_allowed)"
expect_status "27a3 …still marked derived, so no reader mistakes it for a declaration" \
  "derived" "$(roster_field "$ROW" suites_source)"
expect_contains "27a3 …and the operator is told at dispatch" "derived no suites" "$GATE_ERR"

# --- S27b: Suites: -> the DECLARED row, normalised to basenames ---
REPO=$(make_repo r27b yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" 'Your slice: build it.
Expected artifact: .bionic/docs/record/w27b.md
Suites: tests/one.test.sh, tests/two.test.sh' "w27-decl")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "27b a declared Suites: line PASSES with no impact command configured" "0" "$GATE_ST"
expect_status "27b …recorded as BASENAMES, the same alphabet the derivation prints" \
  "one.test.sh two.test.sh" "$(roster_field "$ROW" suites_allowed)"
expect_status "27b …and the row says the set was DECLARED" \
  "declared" "$(roster_field "$ROW" suites_source)"
expect_status "27b …with no files= value, because the brief declared none" \
  "" "$(roster_field "$ROW" files)"

# --- S27c: NEITHER label -> refused, naming all three fixes ---
REPO=$(make_repo r27c yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" 'Your slice: build it.
Expected artifact: .bionic/docs/record/w27c.md
Expected duration: ~15 minutes.' "w27-neither")"
expect_status "27c a brief declaring neither Files: nor Suites: is REFUSED" "2" "$GATE_ST"
expect_contains "27c …naming the Files: fix" "Files: path/one.sh" "$GATE_ERR"
expect_contains "27c …naming the Suites: fix" "Suites: tests/one.test.sh" "$GATE_ERR"
expect_contains "27c …and the waiver" "Suites: none" "$GATE_ERR"
# THE SPELLING RULE, IN THE ONE MESSAGE AN AUTHOR READS WHEN THE LABELS ARE MISSING. Both
# labels are read out of the brief TEXT before any shell expands anything, and the
# writer-side guard reads its command the same way (review-c C-5/C-6): a name that is still
# a variable when a hook sees it can be neither derived from nor checked against anything.
expect_contains "27c …and the spelling rule the two labels share" \
  "one path per token, no shell variables" "$GATE_ERR"
expect_empty "27c …with nothing on stdout" "$GATE_OUT"
expect_status "27c …and no row journalled for a refused dispatch" \
  "0" "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"

# --- S27d: `Suites: none` is the waiver, and it lands on the row ---
REPO=$(make_repo r27d yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" 'Your slice: read the tree and report.
Expected artifact: .bionic/docs/record/w27d.md
Suites: none' "w27-waived")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "27d a Suites: none brief PASSES" "0" "$GATE_ST"
expect_status "27d …and the waiver is on the row, where the writer-side guard reads it" \
  "none" "$(roster_field "$ROW" suites_allowed)"
expect_status "27d …recorded as a declaration, because a human declared it" \
  "declared" "$(roster_field "$ROW" suites_source)"

# --- S27e: Files: with NO impact command -> refused, naming the two fixes ---
#
# `Files:` states an intent that only a derivation can turn into a budget. bionic runs in
# repositories that configure none, and there the author is the only one who can name the
# set — so this refuses rather than passing with an empty budget, at the one moment the
# author is still holding the brief.
REPO=$(make_repo r27e yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FILES" "w27-nocmd")"
expect_status "27e Files: with no impact-command configured is REFUSED" "2" "$GATE_ST"
expect_contains "27e …naming the declared-set fix" "Suites: tests/one.test.sh" "$GATE_ERR"
expect_contains "27e …and the config key that would derive it" "impact-command:" "$GATE_ERR"

# --- S27f: a brief carrying BOTH — the declaration wins ---
#
# `Suites: none` is a waiver, and a waiver a derivation could overrule is not a waiver.
REPO=$(make_repo r27f yes)
write_attestation "$REPO" "$SID_A"
s27_impact "$REPO" derived-only.test.sh
run_gate "$(mk_agent_payload "$SID_A" "$REPO" 'Your slice: build it.
Expected artifact: .bionic/docs/record/w27f.md
Files: payload/scripts/lib/widget.sh
Suites: tests/declared-only.test.sh' "w27-both")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "27f a brief with both labels takes the DECLARED set" \
  "declared-only.test.sh" "$(roster_field "$ROW" suites_allowed)"
expect_status "27f …and says so" "declared" "$(roster_field "$ROW" suites_source)"
expect_status "27f …while still recording the files the brief declared" \
  "payload/scripts/lib/widget.sh" "$(roster_field "$ROW" files)"
# NON-VACUITY: the impact command that would have answered differently really was configured.
expect_status "27f …non-vacuity: an impact command WAS configured for this repo" "0" \
  "$([ -f "$REPO/.bionic/config.yaml" ] && echo 0 || echo 1)"

# --- S27g: the row's three fields never disturb the ones already on it ---
REPO=$(make_repo r27g yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w27-shape")"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "27g the deliverable is unmoved by the three new fields" \
  ".bionic/docs/record/w99-widget.txt" "$(roster_field "$ROW" deliverable)"
expect_status "27g …and plan= is still the LAST field on the row" "0" \
  "$(printf '%s' "$ROW" | grep -qE '\|plan=[^|]*$' && echo 0 || echo 1)"
expect_status "27g the three fields sit between waiver= and tool_use_id=" "0" \
  "$(printf '%s' "$ROW" | grep -qE '\|waiver=[^|]*\|files=[^|]*\|suites_allowed=[^|]*\|suites_source=[^|]*\|tool_use_id=' && echo 0 || echo 1)"

# --- S27h: SELF-CONSISTENCY — a brief following this wall's own Fix lines passes ---
#
# The same pin R6-2 applies to the deliverable walls, read back off THIS wall's stderr:
# an author who copies the recommended `Suites:` line verbatim must not be refused by the
# wall that recommended it.
S27_FIX=$(printf '%s\n' "$GATE_ERR" | grep -m1 -E '^[[:space:]]+Suites: ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
REPO=$(make_repo r27c2 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" 'Your slice: build it.
Expected artifact: .bionic/docs/record/w27c2.md' "w27-neither2")"
S27_FIX=$(printf '%s\n' "$GATE_ERR" | grep -m1 -E '^[[:space:]]+Suites: tests' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
expect_status "27h the refusal really recommended a Suites: line" "0" \
  "$([ -n "$S27_FIX" ] && echo 0 || echo 1)"
REPO=$(make_repo r27h yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "Your slice: build it.
Expected artifact: .bionic/docs/record/w27h.md
$S27_FIX" "w27-followed")"
expect_status "27h a brief following that Fix: line verbatim PASSES" "0" "$GATE_ST"

# ============================================================================
section "S28: one regression per run (AC-24)"
# ============================================================================
#
# The full tree is proved once per run, by one dispatched runner, at integration close.
# A second full-tree dispatch is not forbidden — it is the shape a re-proof legitimately
# takes after a merge — it is made to COST A WRITTEN REASON on the plan, where the next
# reader finds it beside the run it explains.
#
# NEWER IS COUNTED, NOT TIMED (A-S13-4). The plan file is rewritten after every slice, so
# its mtime is newer than everything within minutes and a timestamp comparison would be
# vacuous by lunchtime. The Nth full-tree dispatch of a run needs the (N-1)th
# `regression-cause:` line — monotone, hermetic, and one new sentence per extra run.

BRIEF_REGRESSION='Your slice: run the tests floor.
Expected artifact: .bionic/docs/record/w28-floor.log
Expected duration: ~40 minutes.
Suites: tests/run.sh'

s28_add_cause() {  # <repo> <reason>
  local plan="$1/.bionic/docs/plans/epic-99-test/wave-01-test.plan.md"
  printf 'regression-cause: %s\n' "$2" >> "$plan"
}

REPO=$(make_repo r28 yes)
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_REGRESSION" "w28-runner-one")"
expect_status "28a the FIRST full-tree dispatch of a run passes" "0" "$GATE_ST"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "28a …and its row carries run.sh, which is what makes it countable" \
  "run.sh" "$(roster_field "$ROW" suites_allowed)"

run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_REGRESSION" "w28-runner-two")"
expect_status "28b a SECOND full-tree dispatch in the same run is REFUSED" "2" "$GATE_ST"
expect_contains "28b …counting what it found" "Full-tree runs on this roster: 1" "$GATE_ERR"
# READ OUT OF THE FIX BLOCK, not merely "somewhere on stderr" — the unbound-session
# advisory this gate prints on every run also names the plan path, so a plain contains
# passes over a wall that never fired.
# Compared from the fixture root rightwards, because the gate resolves symlinks on the
# path it prints (/var -> /private/var on macOS) while $REPO does not.
S28_FIXLINE=$(printf '%s\n' "$GATE_ERR" | grep -A1 -F 'under `## SDLC State` in' | tail -1 | sed 's/^[[:space:]]*//')
expect_status "28b …naming the plan the cause belongs on, inside its own Fix block" \
  "/repo/.bionic/docs/plans/epic-99-test/wave-01-test.plan.md" "${S28_FIXLINE##*/r28}"
expect_contains "28b …and the line to write" "regression-cause:" "$GATE_ERR"
expect_status "28b …and the refused dispatch journalled no second row" \
  "1" "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"

s28_add_cause "$REPO" "the merge changed the loader; the tree must be re-proved"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_REGRESSION" "w28-runner-three")"
expect_status "28c a recorded regression-cause: releases the second run" "0" "$GATE_ST"
expect_status "28c …and it is journalled" \
  "2" "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"

run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_REGRESSION" "w28-runner-four")"
expect_status "28d …but the cause is spent: a THIRD run needs a second one" "2" "$GATE_ST"
expect_contains "28d …and the count says so" "Full-tree runs on this roster: 2" "$GATE_ERR"

# A NARROWER BRIEF NEEDS NO CAUSE — the rule is about the full tree, not about dispatching.
run_gate "$(mk_agent_payload "$SID_A" "$REPO" 'Your slice: fix the widget.
Expected artifact: .bionic/docs/record/w28-narrow.md
Suites: tests/widget.test.sh' "w28-narrow")"
expect_status "28e a narrow brief in the same run is unaffected" "0" "$GATE_ST"

# CONTROL: the cause line only counts under `## SDLC State`. A cause written into the
# prose above it is not a ledger entry, and the wall must not read one.
REPO=$(make_repo r28f yes)
write_attestation "$REPO" "$SID_A"
S28F_PLAN="$REPO/.bionic/docs/plans/epic-99-test/wave-01-test.plan.md"
S28F_BODY=$(cat "$S28F_PLAN")
printf '%s\n' "${S28F_BODY/# Test wave plan/# Test wave plan
regression-cause: written outside the ledger}" > "$S28F_PLAN"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_REGRESSION" "w28f-one")"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_REGRESSION" "w28f-two")"
expect_status "28f a regression-cause above ## SDLC State does not count" "2" "$GATE_ST"
expect_contains "28f …and the wall still reports zero causes" "Recorded causes on the plan: 0" "$GATE_ERR"

section "SECTION 29 — the derivation is BOUNDED, and the overrun is a refusal (review-c C-16)"
# THE DEFECT. The impact command is the whole of this gate's cost — ~0.3 s without it,
# ~2.9-3.1 s with it on an idle tree, 5.06-6.51 s measured while this wave's own writers
# were running. hooks/hooks.json registers the hook at "timeout": 10 and the call had no
# bound of its own. A PreToolUse hook killed on the CLI's timeout does NOT exit 2: the
# dispatch proceeds, NO ROSTER ROW IS WRITTEN, and the writer runs with no budget at all —
# the wall defeated by the cost of the wall. So the bound is built here, and it refuses.
#
# NO SEAM. The bound is the shipped 6 seconds, not a value this suite hands the hook; the
# stub below simply outruns it. A test that shortened the bound would prove a constant it
# had itself supplied and leave the production path unverified.

# s29_impact <repo> <sleep seconds> — an impact command that answers correctly, but late.
s29_impact() {
  local repo="$1" secs="$2"
  mkdir -p "$repo/.bionic"
  {
    printf '#!/bin/bash\n'
    printf 'sleep %s\n' "$secs"
    printf 'printf "alpha.test.sh\\tpath-ref:fixture\\n"\n'
  } > "$repo/.bionic/impact-stub.sh"
  chmod +x "$repo/.bionic/impact-stub.sh"
  printf 'impact-command: bash %s/.bionic/impact-stub.sh\n' "$repo" > "$repo/.bionic/config.yaml"
}

# --- 29a: a derivation that outruns the bound REFUSES, and refuses in time ---
REPO=$(make_repo r29a yes)
write_attestation "$REPO" "$SID_A"
s29_impact "$REPO" 30
S29_T0=$(date +%s)
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FILES" "w29-slow")"
S29_ELAPSED=$(( $(date +%s) - S29_T0 ))
expect_status "29a a derivation that outruns the bound REFUSES the dispatch" "2" "$GATE_ST"
expect_contains "29a …naming the bound it outran" "did not answer within 6s" "$GATE_ERR"
expect_contains "29a …naming the command that was slow" "impact-stub.sh" "$GATE_ERR"
expect_contains "29a …naming the paths it was asked about" "payload/scripts/lib/widget.sh" "$GATE_ERR"
expect_contains "29a …and saying why an unbounded one would be worse" "no roster row" "$GATE_ERR"
# THE POINT OF THE BOUND IS THE CLOCK. The hook is registered at a 10-second timeout, so a
# refusal that arrives after it is no refusal at all.
if [ "$S29_ELAPSED" -lt 10 ]; then
  ok "29a …and it refused inside the hook's own 10s registration (${S29_ELAPSED}s)"
else
  no "29a …and it refused inside the hook's own 10s registration" "took ${S29_ELAPSED}s"
fi
# FAIL-CLOSED MEANS NO ROW. A refused dispatch journals nothing, so there is no row a
# writer-side guard could read as "no budget was stated" and stand aside on.
expect_status "29a …and journalled no row at all" \
  "0" "$(roster_rows "$(roster_path "$REPO" "$SID_A")")"

# --- 29b: CONTROL — the same brief, the same stub, fast, still derives and passes ---
REPO=$(make_repo r29b yes)
write_attestation "$REPO" "$SID_A"
s29_impact "$REPO" 0
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FILES" "w29-fast")"
expect_status "29b control: the same stub, prompt, PASSES" "0" "$GATE_ST"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "29b …and the derived budget is the stub's answer" \
  "alpha.test.sh" "$(roster_field "$ROW" suites_allowed)"
expect_status "29b …recorded as derived" "derived" "$(roster_field "$ROW" suites_source)"

# --- 29c: a derivation that answers NOTHING is unchanged: empty budget, a warning ---
# The overrun is a refusal because the alternative is an unwritten row; a command that
# fails or answers nothing has still answered, and the third state (`suites_allowed=` empty)
# already has readers. This is the boundary between the two, asserted so a later edit
# cannot quietly turn one into the other.
REPO=$(make_repo r29c yes)
write_attestation "$REPO" "$SID_A"
mkdir -p "$REPO/.bionic"
printf '#!/bin/bash\nexit 3\n' > "$REPO/.bionic/impact-stub.sh"
chmod +x "$REPO/.bionic/impact-stub.sh"
printf 'impact-command: bash %s/.bionic/impact-stub.sh\n' "$REPO" > "$REPO/.bionic/config.yaml"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FILES" "w29-empty")"
expect_status "29c a derivation that answers nothing still PASSES" "0" "$GATE_ST"
expect_contains "29c …with the operator warned at the moment the config is fixable" \
  "derived no suites" "$GATE_ERR"
ROW=$(roster_nth_row "$(roster_path "$REPO" "$SID_A")" 1)
expect_status "29c …and the row records the empty third state" "" "$(roster_field "$ROW" suites_allowed)"


# ===========================================================================
section "S30: the approval checkpoint — a writer needs an approved plan (epic-22 K2, AC-K2.4)"
# ===========================================================================
#
# WHY THE WRITER AND NOT ONLY THE COMMIT. The evidence gate refuses a commit made at
# `current: 4` while the plan carries no `approved-by:`. That is the right wall, and it is
# the LATE one: by the time it fires, eight writers have already read the brief, taken
# worktrees and written code against a plan nobody ratified. This arm is the early half —
# it refuses the writer, which is the first act of a plan that closing a file cannot undo.
#
# THE ROLE SET IS THE WHOLE DISCRIMINATION. Researchers, test-runners, auditors and critics
# are dispatched BEFORE approval as a matter of course: the research that informs the plan
# is exactly such a dispatch, and refusing it would refuse the work that produces the
# approval. So the arm names two roles and only two, matched whole.
#
# HERMETIC, like everything else here: `make_repo` writes a plan at `current: 4` with no
# `approved-by:` line, which is precisely the refused state; the pass cases add the line.

# k2_plan_line <repo> <line...> — rewrite the fixture plan's `## SDLC State` body.
k2_write_plan() {  # <repo> <current> <approved-by line, or "">
  local repo="$1" cur="$2" approved="$3"
  local dir="$repo/.bionic/docs/plans/epic-99-test"
  mkdir -p "$dir"
  {
    printf -- '---\ngoverning-skill: canonical-sdlc\ncanonical_sdlc_version: 14\n'
    printf -- 'intent: build\nrigor: audited\nscale: wave\n---\n\n'
    printf -- '# Test wave plan\n\n## SDLC State\n\nintegration-branch: main\ncurrent: %s\n' "$cur"
    [ -n "$approved" ] && printf -- '%s\n' "$approved"
    printf -- '\n- Step %s: slices in flight\n' "$cur"
  } > "$dir/wave-01-test.plan.md"
}

K2_APPROVED_LINE='approved-by: dana 2026-09-07T19:05Z "Ok, amazing! Approved."'

# --- 30a/30b: the two writer roles are refused while the line is absent ---
for _role in bionic:implementor bionic:senior-implementor; do
  _tag="30a"; [ "$_role" = "bionic:senior-implementor" ] && _tag="30b"
  REPO=$(make_repo "r${_tag}" yes)
  write_attestation "$REPO" "$SID_A"
  k2_write_plan "$REPO" 4 ""
  run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w${_tag}" "claude-sonnet-5" \
                               "$S5_LIVE_TRANSCRIPT" "$_role")"
  expect_status "${_tag} a ${_role} dispatch at current: 4 with no approved-by is refused" "2" "$GATE_ST"
  expect_contains "${_tag} …and the refusal names the missing line" "approved-by" "$GATE_ERR"
  # NOT merely the plan path: an unbound session's own resolution announcement carries that
  # already, so a path assertion here would be green with no refusal printed at all.
  expect_contains "${_tag} …and says what a writer needs" "writers run against an APPROVED plan" "$GATE_ERR"
done

# --- 30c: THE CONTROL — the same dispatch with the line present passes ---
REPO=$(make_repo r30c yes)
write_attestation "$REPO" "$SID_A"
k2_write_plan "$REPO" 4 "$K2_APPROVED_LINE"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w30c" "claude-sonnet-5" \
                             "$S5_LIVE_TRANSCRIPT" "bionic:implementor")"
expect_status "30c control: the same writer dispatch with approved-by present passes" "0" "$GATE_ST"
expect_absent "30c …with no refusal printed" "BLOCKED" "$GATE_ERR"

# --- 30d: an approved-by whose value is empty records no approval ---
REPO=$(make_repo r30d yes)
write_attestation "$REPO" "$SID_A"
k2_write_plan "$REPO" 4 "approved-by:"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w30d" "claude-sonnet-5" \
                             "$S5_LIVE_TRANSCRIPT" "bionic:implementor")"
expect_status "30d an empty approved-by: value is not an approval" "2" "$GATE_ST"

# --- 30e: the reading roles pass through the same refused plan ---
for _role in bionic:researcher bionic:test-runner bionic:auditor bionic:critic; do
  REPO=$(make_repo "r30e-${_role##*:}" yes)
  write_attestation "$REPO" "$SID_A"
  k2_write_plan "$REPO" 4 ""
  run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w30e" "claude-sonnet-5" \
                               "$S5_LIVE_TRANSCRIPT" "$_role")"
  expect_status "30e a ${_role} dispatch against the SAME unapproved plan passes" "0" "$GATE_ST"
done

# --- 30f: below Step 4 the arm is inert — the plan is still being authored ---
REPO=$(make_repo r30f yes)
write_attestation "$REPO" "$SID_A"
k2_write_plan "$REPO" 3 ""
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w30f" "claude-sonnet-5" \
                             "$S5_LIVE_TRANSCRIPT" "bionic:implementor")"
expect_status "30f current: 3 with no approved-by — the arm is inert" "0" "$GATE_ST"

# --- 30g: the durable half — the approval still binds after Step 4 ---
REPO=$(make_repo r30g yes)
write_attestation "$REPO" "$SID_A"
k2_write_plan "$REPO" 6 ""
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w30g" "claude-sonnet-5" \
                             "$S5_LIVE_TRANSCRIPT" "bionic:implementor")"
expect_status "30g current: 6 with no approved-by — still refused" "2" "$GATE_ST"

# --- 30h: no plan on disk at all — a plan-bound arm with nothing to measure ---
REPO=$(make_repo r30h no)
mkdir -p "$REPO/.bionic/tmp"
printf 'patrol-stamp/v1|at=%s|session=%s|verb=arm\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SID_A" > "$REPO/.bionic/tmp/patrol-$SID_A.state"
: > "$REPO/.bionic/tmp/engaged-$SID_A.state"
write_attestation "$REPO" "$SID_A"
run_gate "$(mk_agent_payload "$SID_A" "$REPO" "$BRIEF_FULL" "w30h" "claude-sonnet-5" \
                             "$S5_LIVE_TRANSCRIPT" "bionic:implementor")"
expect_status "30h an engaged session with no plan on disk — the arm is inert" "0" "$GATE_ST"


finish
