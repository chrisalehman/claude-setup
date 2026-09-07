#!/bin/bash
# CROSS-COMPONENT INSTRUMENT PROOFS — epic-15 wave-01R, slice 4/6.
#
# Serves AC-9 (N-way agreement over every copy of a duplicated concept,
# including the actively-maintained origin; one-copy mutation goes red) and the
# cross-script share of AC-8 (no command text in any written artefact;
# unpredictable temp names across all four scripts).
#
# Governing design: design/orchestrator-subagent-coordination.md §8, §9.
# Known-failure checklist: .bionic/docs/record/epic-15-w1r-known-failure-checklist.md
# A8 (duplicated logic with only a 2-way agreement test — the origin missing
# from the test meant to catch drift) and A9 (green suites hid undiscriminated
# parser edges: quoted values, absolute paths, duplicate directive lines,
# indentation — proven by a one-copy mutation staying green).
#
# WHAT THIS SUITE IS FOR, and what it deliberately is not:
#
#   The per-script suites (hooks/{preflight-probe,dispatch-preflight,stop-check,
#   stop-guard}.test.sh) each drive ONE component against its own contract. Every
#   one of them is green while four byte-identical copies of active-wave
#   detection drift apart, because no single-component suite ever asks the other
#   copies the same question. This suite asks all four the SAME question with the
#   SAME fixture and compares the answers. It adds no per-component assertions.
#
# HERMETIC. Throwaway git repos under a mktemp'd sandbox; HOME and
# CLAUDE_CONFIG_DIR redirected into it (the evidence gate appends findings under
# $HOME/.claude/logs — nothing here may touch the real one). No live wave, no
# installed hooks, no network.
#
# THE TWO ROOTS ARE DELIBERATELY DIFFERENT. `$CLAUDE_CONFIG_DIR` is NOT
# `$HOME/.claude` here, because "where Claude Code stores session and project
# metadata" is computed at three sites in this wave and holding the two roots
# equal makes every disagreement between them invisible. That is not
# hypothetical: this file previously pinned the equal case, and behind it the
# observation resolved NOTHING while the recorder wrote a record and the stop
# gate spent it (Step-6 critic, issue 1). Every metadata fixture below is
# planted under $CLAUDE_CONFIG_DIR, which is what the platform does when the
# variable is set; §C case 5 plants under $HOME/.claude and proves it is NOT
# seen.
#
# Usage: bash tests/cross-gate-agreement.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/bound-marker.sh"
. "$(dirname "$0")/lib/live-answer.sh"
. "$(dirname "$0")/lib/roster-row.sh"
. "$(dirname "$0")/lib/swept-marker.sh"
. "$(dirname "$0")/lib/frontmatter-parser.sh"

REPO_ROOT="${BIONIC_SCRIPTS_DIR}"

# The four parties. Overridable so the suite can be driven against a MUTATED
# COPY of any one of them without the shipped file ever being modified — that
# substitution is how §9's mutation-and-restore proof is taken here, and how a
# reviewer can re-take it by hand:
#   W1R_PARTY_DP=/tmp/mutant.sh bash tests/cross-gate-agreement.test.sh
PARTY_DP="${W1R_PARTY_DP:-$BIONIC_HOOKS_DIR/dispatch-preflight.sh}"
PARTY_SG="${W1R_PARTY_SG:-$BIONIC_HOOKS_DIR/stop-guard.sh}"
PARTY_EG="${W1R_PARTY_EG:-$BIONIC_HOOKS_DIR/canonical-sdlc-evidence-gate.sh}"
# The recorder moved out of the stop gate at slice 4/4: observations are written
# post-execution by their own script, from the producer's own printed output.
PARTY_ER="${W1R_PARTY_ER:-$BIONIC_HOOKS_DIR/execution-recorder.sh}"

PROBE="$BIONIC_HOOKS_DIR/preflight-probe.sh"
OBSERVE="$BIONIC_HOOKS_DIR/stop-check.sh"
SWEEPER="$BIONIC_HOOKS_DIR/session-sweeper.sh"
# The landing gate (epic-16 wave-01) is a fifth party and an overridable one for
# the same reason the four above are: §J drives a MUTATED COPY of it to prove the
# verdict/gate battery discriminates, and the shipped file is never touched.
PARTY_LG="${W1R_PARTY_LG:-$BIONIC_HOOKS_DIR/landing-gate.sh}"
# §J also drives a mutated copy of the SWEEPER, to prove the opposite direction:
# a change to the predicate moves both answers rather than splitting them.
PARTY_SW="$SWEEPER"

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/w1r-agreement.XXXXXX")" && pwd -P)"
BG_PIDS=""
cleanup() {
  local p
  for p in $BG_PIDS; do kill -9 "$p" 2>/dev/null; done
  rm -rf "$SANDBOX"
}
trap cleanup EXIT
export HOME="$SANDBOX/home"
export CLAUDE_CONFIG_DIR="$SANDBOX/cfg"     # NOT $HOME/.claude — see the header
mkdir -p "$CLAUDE_CONFIG_DIR" "$HOME/.claude"
# Since slice 4/5, hooks/stop-check.sh reads CLAUDE_CODE_SESSION_ID; since S6 it reads it to
# find the session TRANSCRIPT the live set is recorded in, which is the whole of resolution.
# This suite runs inside a real Claude Code session, which exports a real one, and an
# unpinned call would read THAT session's live set — the suite's hermetic claim quietly false.
# So it is unset here and pinned per call, to the fixture session, everywhere a party has to
# resolve anything.
unset CLAUDE_CODE_SESSION_ID

# ok/no/expect_eq/expect_contains/expect_absent/expect_true/expect_false migrated onto
# tests/lib/assert.sh (S5a, AC-12). The framework's expect_contains/expect_absent are a
# quoted `case` glob, never `grep -F` — no pipe, so the epic-17-w1 SIGPIPE-141 flake this
# block used to describe by hand cannot recur, and no 64 KiB haystack limit either. The
# ONE semantic difference measured against the private definitions this file used to carry
# (byte-identical to the framework's except here): `grep -F` treats a NEWLINE inside the
# needle as alternation ("either line matches"), while the framework's `case` requires the
# whole multi-line needle as one contiguous substring. Exactly one call site in this file
# passed a two-line needle (§B2, "the two-line shape, plan first") — verified line-by-line
# that its fixture always produces the two lines adjacent and in order, so the tighter
# contiguous check is not a narrowing here; see that assertion's own comment.

# SUBSTRING, AS A FUNCTION RATHER THAN A `case` INSIDE `$( … )`. bash 3.2 — what
# `/bin/bash` is on macOS, and what this file's shebang names — mis-parses a `case` inside
# a command substitution: the multi-line form is a hard syntax error, and the ONE-LINE form
# is worse, because it parses and then evaluates to the tail of its own source text
# (measured: `expected 'no', got ' echo yes ;; *) echo no ;; esac)'`). §BP below sweeps for
# both shapes. Step-6 review C-2.
cg_contains() {  # <haystack> <needle> -> yes|no
  case "$1" in
    *"$2"*) printf 'yes' ;;
    *)      printf 'no'  ;;
  esac
}

SID_A="6c85684c-9588-45a0-bd26-e8c46956c94f"
SID_B="1f4a7c02-3bd9-4e15-8a66-90c1de77b204"
# The landing gate's active-wave party (§A1/§A2) plants its own one-row roster; a dedicated
# session id keeps it off roster-$SID_A.state, which verdict_er re-seeds on every call.
SID_LG="2ae9d613-4c07-4b8a-9f51-7d02ac86be40"

# ---------------------------------------------------------------- payloads
#
# FIXTURE FIDELITY. PreToolUse envelope FAITHFUL to
# .bionic/docs/record/epic-15-kill-interception-experiment.md §2.2 (CLI 2.1.220
# verbatim capture), field for field; tool_name/tool_input vary per tool as §2.1
# and §2.12 establish. Session ids, agent ids and plan text are SYNTHESIZED and
# declared as such — none is a platform surface.
#
# The Agent tool_input carries a name and a contract-bearing brief (slice 4/3):
# tool_input became load-bearing when the start gate began journalling the launch
# to the session roster, and a brief with no labeled contract fields is warned
# about on stderr. This suite's claim is producer/consumer AGREEMENT ON THE
# ATTESTATION — "passes in silence" below means the attestation raised nothing —
# so the fixture is the ordinary dispatch, not a malformed one. The warning
# itself is driven where it belongs, in tests/dispatch-preflight.test.sh S10c.

mk_agent_payload() {  # <sid> <cwd>
  jq -n --arg s "$1" --arg c "$2" \
    '{session_id:$s, transcript_path:"/irrelevant.jsonl", cwd:$c,
      prompt_id:"f3cd7d62-305d-47ed-9eaf-46fb12d4f4ed",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      hook_event_name:"PreToolUse", tool_name:"Agent",
      tool_input:{description:"a dispatch", subagent_type:"implementor", name:"w99-impl",
                  prompt:"Expected artifact: .bionic/docs/record/w99.txt\nExpected duration: ~25 minutes.\nProgress artifact: .bionic/tmp/w99.progress\nSuites: tests/widget.test.sh"},
      tool_use_id:"toolu_018jyjgop7KMxP6yKtoAWWtB"}'
}

mk_stop_payload() {  # <sid> <transcript> <cwd> <task_id>
  jq -n --arg s "$1" --arg t "$2" --arg c "$3" --arg k "$4" \
    '{session_id:$s, transcript_path:$t, cwd:$c,
      prompt_id:"f3cd7d62-305d-47ed-9eaf-46fb12d4f4ed",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      hook_event_name:"PreToolUse", tool_name:"TaskStop",
      tool_input:{task_id:$k}, tool_use_id:"toolu_018jyjgop7KMxP6yKtoAWWtB"}'
}

mk_bash_payload() {  # <sid> <transcript> <cwd> <command>
  jq -n --arg s "$1" --arg t "$2" --arg c "$3" --arg m "$4" \
    '{session_id:$s, transcript_path:$t, cwd:$c,
      prompt_id:"f3cd7d62-305d-47ed-9eaf-46fb12d4f4ed",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      hook_event_name:"PreToolUse", tool_name:"Bash",
      tool_input:{command:$m}, tool_use_id:"toolu_018jyjgop7KMxP6yKtoAWWtB"}'
}

# The recorder's event. FAITHFUL to .bionic/docs/record/w3-slice1-posttooluse-probe.md
# capture A (orchestrator-invoked PostToolUse|Bash), field for field including the
# tool_response object; capture A carries no top-level agent_id, which is the
# orchestrator case. The stdout carried here is never synthesized in this suite —
# it is whatever the real hooks/stop-check.sh printed.
mk_bash_post() {  # <sid> <transcript> <cwd> <command> <stdout>
  jq -n --arg s "$1" --arg t "$2" --arg c "$3" --arg m "$4" --arg o "$5" \
    '{session_id:$s, transcript_path:$t, cwd:$c,
      prompt_id:"598cabc5-2776-479c-abcf-52c540a1c60e",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      hook_event_name:"PostToolUse", tool_name:"Bash",
      tool_input:{command:$m, description:"observe"},
      tool_response:{stdout:$o, stderr:"", interrupted:false,
                     isImage:false, noOutputExpected:false},
      tool_use_id:"toolu_01HQV9JAFdKC15TLMDKt2QgF", duration_ms:117}'
}

# FAITHFUL to the same record's capture E (background dispatch, the mode this
# repo uses): tool_response carries `agentId`, tool_input carries `name`.
mk_agent_post() {  # <sid> <transcript> <cwd> <tool_use_id> [name] [agentId]
  jq -n --arg s "$1" --arg t "$2" --arg c "$3" --arg u "$4" \
    --arg n "${5:-battery}" --arg a "${6:-a26bd30bf8616411b}" \
    '{session_id:$s, transcript_path:$t, cwd:$c,
      prompt_id:"33f36a9c-ad3b-4bb4-afbd-325a18e62a9e",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      hook_event_name:"PostToolUse", tool_name:"Agent",
      tool_input:{description:"a dispatch", prompt:"go", subagent_type:"implementor",
                  run_in_background:true, name:$n},
      tool_response:{isAsync:true, status:"async_launched", agentId:$a,
                     description:"a dispatch", resolvedModel:"claude-sonnet-5",
                     prompt:"go", outputFile:("/tmp/tasks/" + $a + ".output"),
                     canReadOutputFile:true},
      tool_use_id:$u, duration_ms:6}'
}

# The TEAMMATE completion (epic-16 wave-01 slice 0). FAITHFUL to
# .bionic/docs/record/landing-wave-capture-probe.md §3-A and the live re-capture
# slice 0 took through the pty harness: `tool_response.status` is
# `teammate_spawned`, and `agent_id`/`teammate_id` both carry the ADDRESSING form
# `<name>@session-<id8>` — never the transcript form, which no PostToolUse
# payload contains. This is the dispatch mode every interactive session on this
# machine really uses; `mk_agent_post` above is the async one.
mk_agent_post_teammate() {  # <sid> <transcript> <cwd> <name> <addressing-id> <tool_use_id>
  jq -n --arg s "$1" --arg t "$2" --arg c "$3" --arg n "$4" --arg a "$5" --arg u "$6" \
    '{session_id:$s, transcript_path:$t, cwd:$c,
      prompt_id:"95b0701b-7814-42ca-a26f-58123e667f9a",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      hook_event_name:"PostToolUse", tool_name:"Agent",
      tool_input:{description:"a dispatch", prompt:"go", subagent_type:"implementor",
                  run_in_background:true, name:$n},
      tool_response:{status:"teammate_spawned", prompt:"go",
                     teammate_id:$a, agent_id:$a, agent_type:"implementor",
                     model:"claude-opus-5", name:$n, color:"blue",
                     tmux_session_name:"in-process", tmux_window_name:"in-process",
                     tmux_pane_id:"in-process", team_name:"session-6c85684c",
                     is_splitpane:false, plan_mode_required:false},
      tool_use_id:$u, duration_ms:9}'
}

# The SubagentStart event (slice 1). VERBATIM shape from capture probe §3-C: six
# keys and no `tool_name` at all, which is why the recorder's third arm cannot sit
# behind the tool-name gate its other two share. `agent_type` is the teammate's
# NAME here — the platform's own rename — and `agent_id` is the TRANSCRIPT form.
mk_start_payload() {  # <sid> <transcript> <cwd> <name> <transcript-id>
  jq -n --arg s "$1" --arg t "$2" --arg c "$3" --arg n "$4" --arg a "$5" \
    '{session_id:$s, transcript_path:$t, cwd:$c,
      prompt_id:"95b0701b-7814-42ca-a26f-58123e667f9a",
      agent_id:$a, agent_type:$n, hook_event_name:"SubagentStart"}'
}

# The SubagentStop event (slice 5). FAITHFUL to capture probe §3-D, a live teammate
# stop: `agent_type` carries the name, `agent_id` the transcript form,
# `background_tasks[]` its task-id key. Only the four fields the gate reads vary.
mk_substop_payload() {  # <cwd> <sid> <agent_type> <stop_hook_active true|false>
  jq -n --arg c "$1" --arg s "$2" --arg a "$3" --argjson h "$4" \
    '{session_id:$s, transcript_path:("/tmp/transcripts/" + $s + ".jsonl"), cwd:$c,
      prompt_id:"95b0701b-7814-42ca-a26f-58123e667f9a",
      permission_mode:"bypassPermissions",
      agent_id:"aprobemate-4da9be517e8f90bd", agent_type:$a,
      effort:{level:"high"}, hook_event_name:"SubagentStop", stop_hook_active:$h,
      agent_transcript_path:("/tmp/transcripts/" + $s + "/subagents/agent-aprobemate-4da9be517e8f90bd.jsonl"),
      last_assistant_message:"DONE\n\nRan the slice; report written.",
      background_tasks:[{id:"tooha5cgi", type:"teammate", status:"running",
                         description:"run the slice and report"}],
      session_crons:[]}'
}

# The LANDING SWEEP's event (epic-16 wave-03, T4c). FAITHFUL to
# .bionic/docs/record/session-20260814-wave-detector-terminal-state/t4b-probe-report.md
# §2.1 (the eleven-key Stop envelope) and §2.2 (the `background_tasks[]` row shape,
# `{id, type, status, description, agent_type}`). The ids passed here are the LIVE set —
# every roster row whose agent_id is absent from it has landed and is judged.
mk_stopsweep_payload() {  # <cwd> <sid> <stop_hook_active true|false> [live-agent-id...]
  local c="$1" s="$2" h="$3"; shift 3
  local live
  live=$(printf '%s\n' "$@" | jq -R 'select(length > 0)' | jq -s \
    'map({id:., type:"subagent", status:"running", description:"a live dispatch",
          agent_type:"general-purpose"})')
  jq -n --arg c "$c" --arg s "$s" --argjson h "$h" --argjson bg "$live" \
    '{session_id:$s, transcript_path:("/tmp/transcripts/" + $s + ".jsonl"), cwd:$c,
      prompt_id:"e30e6fb0-3868-467c-b092-ca03e55b4cd5",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      hook_event_name:"Stop", stop_hook_active:$h,
      last_assistant_message:"The background probe agent completed and returned PONG.",
      background_tasks:$bg, session_crons:[]}'
}

# The landing gate's OTHER arm (session-20260815 T2): a named teammate is judged at its own
# SubagentStop rather than by disappearing from `background_tasks[]`, which it never does.
# Key set from t1-probe-report.md §2.1; `agent_type` carries the dispatch NAME for a teammate.
mk_substop_payload() {  # <cwd> <sid> <agent-id> <agent-type> <stop_hook_active true|false>
  jq -n --arg c "$1" --arg s "$2" --arg a "$3" --arg t "$4" --argjson h "$5" \
    '{session_id:$s, transcript_path:("/tmp/transcripts/" + $s + ".jsonl"),
      agent_transcript_path:("/tmp/transcripts/" + $s + "/subagents/agent-" + $a + ".jsonl"),
      cwd:$c, prompt_id:"e30e6fb0-3868-467c-b092-ca03e55b4cd5",
      permission_mode:"bypassPermissions", effort:{level:"high"},
      agent_id:$a, agent_type:$t,
      hook_event_name:"SubagentStop", stop_hook_active:$h,
      last_assistant_message:"Done.", background_tasks:[], session_crons:[]}'
}

# THE PRODUCER→RECORDER PAIR, DRIVEN END TO END. Since slice 4/4 the recorder
# reads no command line: it copies the machine line the observation printed. So
# the only honest way to ask "what did the recorder write for this command" is to
# RUN the observation and hand its real stdout to the real recorder — which is
# also what makes the two halves one fact rather than two parsers (F-1).
run_pair() {  # <repo> <transcript> <sid> <args…> -> recorder's exit status; sets PAIR_OUT
  local repo="$1" tr="$2" sid="$3"; shift 3
  # The sid is pinned on the observation too, not only stamped into the payload: since S6 it
  # is how hooks/stop-check.sh finds the transcript carrying the live set.
  PAIR_OUT=$( cd "$repo" && env CLAUDE_CODE_SESSION_ID="$sid" bash "$OBSERVE" "$@" 2>/dev/null )
  mk_bash_post "$sid" "$tr" "$repo" "bash ~/.claude/hooks/stop-check.sh $*" "$PAIR_OUT" \
    | bash "$PARTY_ER" >/dev/null 2>&1
}

# THE SESSION ROSTER, in the shape its writer writes it — field for field from
# hooks/dispatch-preflight.sh's `ROW=` line. Both the producer (classification,
# contract state) and the stop gate (the foreign-stop rule) read this file, which
# is precisely why it is planted from ONE helper here: a fixture written twice is
# two shapes, and this suite exists to catch exactly that.
# RENAMED OFF THE WRITER'S NAME (S17). This helper used to be called `roster_row`, which is
# now the production writer's own name — sourcing tests/lib/roster-row.sh with a private
# `roster_row` still defined would have shadowed the one writer with a fixture, which is the
# exact inversion this wave exists to end (S14 renamed dispatch-preflight's reader for the
# same reason). The row itself now comes from `roster_row_fixture`, so the fields this
# fixture used to omit — `source=`, `claims=`, `cadence=`, `waiver=`, `plan=` — are the
# writer's own defaults rather than absent, and the header line is `roster_header`'s.
cg_roster_row() {  # <repo> <sid> <name> <agent-id> [progress] [status]
  local repo="$1" sid="$2" name="$3" aid="$4" prog="${5:-}" status="${6:-confirmed}"
  local f="$repo/.bionic/tmp/roster-$sid.state"
  mkdir -p "$repo/.bionic/tmp"
  [ -f "$f" ] || roster_header > "$f"
  roster_row_fixture \
    status="$status" session="$sid" name="$name" agent_id="$aid" \
    launched_at=2026-08-05T00:00:00Z progress="$prog" >> "$f"
  return 0
}

# THE RECORDED ListAgents ANSWER — the live set (S6, D1′). Since this slice both stop
# scripts resolve a target against the newest recorded ListAgents answer in a session's
# transcript, so a fixture transcript is no longer an empty file. The body's shape is the
# real one, copied from tests/live-agents.test.sh, whose bodies are byte-verbatim captures:
# the separator is U+00B7 and `[8895ce]` is the harness ref suffix the reader strips.
# Accumulated in a sidecar so a second call ADDS a teammate rather than replacing the answer.
# THE RECORDER UPDATES A ROW, IT DOES NOT APPEND ONE. `intended → confirmed → identified` is
# one row moving through three states carrying one contract (§K), so a fixture that appended a
# second row of the same name would leave the CONTRACT on the first and the AGENT ID on the
# second — a shape no writer produces, and one that would make the readers below look broken
# for a reason nothing in production can reach.
roster_identify() {  # <repo> <sid> <name> <agent-id>
  local f="$1/.bionic/tmp/roster-$2.state" prev
  prev=$(grep -F "|name=$3|" "$f" 2>/dev/null | tail -1) || prev=""
  if [ -n "$prev" ]; then
    # FORWARD-COPIED, not rewritten: the identification arm carries the whole row forward with
    # its contract intact (§K), and the earlier state's row stays on the file exactly as the
    # real writers leave it — which is what lets a later section still find an `intended` row
    # to complete. Only the two fields the identification owns are replaced.
    printf '%s\n' "$prev" \
      | sed -e 's/|status=[^|]*|/|status=identified|/' -e "s/|agent_id=[^|]*|/|agent_id=$4|/" >> "$f"
    return 0
  fi
  cg_roster_row "$1" "$2" "$3" "$4" "" "identified"
}

# THE ANSWER BODY IS BUILT BY tests/lib/live-answer.sh (S17, spec AC-27/AC-28). The self
# line, the `Teammates (N):` header and every teammate row come out of the committed corpus
# with only this suite's names, statuses and type substituted in place — so the recognition
# anchor these sections lean on is the one the harness actually writes, not this file's own
# spelling of it, and the bash-3.2 `case`-inside-`$( … )` hazard the old private row builder
# had to be hoisted out of (Step-6 review C-2) is gone with the builder.
#
# `LIVE_ANSWER_TYPE` is the type every composed row carries: §LA.5 and §LA.6 assert on it.
# A bare name is the corpus's own `running`; `name:idle` writes the harness's other status —
# the teammate that finished its turn and was never stopped, which LA.5 turns into the
# discriminator between the two questions the one parse now answers.
LIVE_ANSWER_TYPE="bionic:implementor"

cg_live() {  # <transcript> <name[:status]>...
  local tr="$1"; shift
  local f="${tr%.jsonl}.names" names=() n body
  mkdir -p "$(dirname "$tr")"
  for n in "$@"; do printf '%s\n' "$n" >> "$f"; done
  while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done < "$f"
  body="$(live_answer_body ${names[@]+"${names[@]}"})"
  {
    jq -nc --arg ts "2026-09-05T00:50:00.000Z" \
      '{type:"user",timestamp:$ts,message:{role:"user",content:"go"}}'
    jq -nc --arg ts "2026-09-05T00:51:00.000Z" \
      '{type:"assistant",timestamp:$ts,message:{role:"assistant",content:[{type:"tool_use",id:"toolu_01FIXTURELISTAGENTS",name:"ListAgents",input:{}}]}}'
    jq -nc --arg ts "2026-09-05T00:52:23.349Z" --arg b "$body" \
      '{type:"user",timestamp:$ts,message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_01FIXTURELISTAGENTS",content:$b}]}}'
  } > "$tr"
  return 0
}

# ============================================================
# THE SHARED QUESTION
# ============================================================
#
# All three parties compute the same thing from a repo: resolve the docs root
# (honouring .bionic/config.yaml's `docs-root:`), select the newest plan two
# levels deep under plans/ and incidents/, read the fence-aware `## SDLC State`
# section through the CR-translating normalizer, and take its `current:` value.
#
# They then USE it differently, so the comparable observable is the predicate
# each can answer:
#
#     "does this repo present a plan whose `current:` names a valid step?"
#
#   dispatch-preflight  refuse (exit 2, no attestation planted)  <=> yes
#   stop-guard          refuse (exit 2, target unresolvable)     <=> yes
#   evidence-gate       "has no 'Step N:' line" (exit 2)         <=> yes, and N
#                       is the derived value itself — the only party that
#                       reports it, which is why the fixtures below are built so
#                       that a MIS-PARSE FLIPS THE PREDICATE rather than merely
#                       changing a value. A fixture whose mis-parse is invisible
#                       to two of three parties proves nothing about them (A9).
#
# Deliberately out of the battery, and why:
#   * `current: T<n>` — the two gates accept a task token unconditionally; the
#     evidence gate accepts it only on a `scale: task` plan and then exits 0 on a
#     valid ledger, so its answer to the predicate is unobservable there. Both
#     behaviours are conservative and deliberate; the asymmetry is pinned as a
#     KNOWN DIVERGENCE in section A3 rather than mixed into the agreement rows.
#   * The evidence gate's misplaced-plan sweep (`*.plan.md` carrying
#     canonical_sdlc_version outside the docs root) — a gate-specific rule with
#     no counterpart in the other two. Fixture plans are therefore named
#     `*.md`, not `*.plan.md`: every party's plan SELECTION matches `*.md`, so
#     nothing under test is weakened, and the sweep never fires to confound the
#     observable.

verdict_dp() {  # <repo> -> yes|no|other:<detail>
  local out st
  out=$(mk_agent_payload "$SID_A" "$1" | bash "$PARTY_DP" 2>&1); st=$?
  case "$st" in
    0) if [ -z "$out" ]; then echo no; else echo "other:pass-with-output"; fi ;;
    2) echo yes ;;
    *) echo "other:exit-$st" ;;
  esac
}

verdict_sg() {  # <repo> -> yes|no|other:<detail>
  local out st
  out=$(mk_stop_payload "$SID_A" "$SANDBOX/t.jsonl" "$1" "no-such-agent" \
        | bash "$PARTY_SG" 2>&1); st=$?
  case "$st" in
    0) if [ -z "$out" ]; then echo no; else echo "other:pass-with-output"; fi ;;
    2) echo yes ;;
    *) echo "other:exit-$st" ;;
  esac
}

# The recorder holds the FOURTH copy of active-wave detection (slice 4/4), and a
# duplicated wall nothing drives is a wall that diverges. Its observable is the
# roster: with a wave active it completes an `intended` row on execution
# confirmation, and outside one it is inert. The row is re-seeded on every call so
# the answer describes this run and not a previous one.
verdict_er() {  # <repo> -> yes|no|other:<detail>
  # TWO STATEMENTS, NOT ONE — the trap this file records at `j_mutant` and `mk_root`.
  # `local repo="$1" roster="$repo/…"` expands every word before it assigns any, so
  # `$roster` was built from whatever `repo` happened to be in a CALLER's scope; inside the
  # battery loop that was the right value by accident, and from anywhere else it is an
  # unbound-variable abort under `set -u`.
  local repo="$1" out st roster
  roster="$repo/.bionic/tmp/roster-$SID_A.state"
  mkdir -p "$repo/.bionic/tmp"
  {
    roster_header
    roster_row_fixture status=intended session="$SID_A" name=battery agent_id= \
      launched_at=2026-08-05T00:00:00Z model= tool_use_id=toolu_BATTERY
  } > "$roster"
  out=$(mk_agent_post "$SID_A" "$SANDBOX/t.jsonl" "$repo" "toolu_BATTERY" | bash "$PARTY_ER" 2>&1); st=$?
  if [ "$st" -ne 0 ]; then echo "other:exit-$st"; return; fi
  if [ -n "$out" ]; then echo "other:output"; return; fi
  if grep -q 'status=confirmed' "$roster" 2>/dev/null; then echo yes; else echo no; fi
}

# The evidence gate is the only party that reports the DERIVED VALUE, so its
# answer is `yes:<value>` where the others answer `yes`. Callers split on `:`.
verdict_eg() {  # <repo> -> yes:<current>|no|other:<detail>
  local out st
  out=$(mk_bash_payload "$SID_A" "$SANDBOX/t.jsonl" "$1" "git commit -m x" \
        | env -u CLAUDE_PROJECT_DIR bash "$PARTY_EG" 2>&1); st=$?
  if [ "$st" -eq 0 ]; then echo no; return; fi
  case "$out" in
    *"has no 'Step "*)
      printf 'yes:%s\n' \
        "$(printf '%s' "$out" | sed -n "s/.*has no 'Step \([^']*\):' line.*/\1/p" | head -1)" ;;
    *"missing a valid 'current: N' line"*) echo no ;;
    *"empty '## SDLC State' section"*)     echo "other:empty-section" ;;
    *) echo "other:$(printf '%s' "$out" | head -1 | cut -c1-60)" ;;
  esac
}

# The landing gate holds a FIFTH byte-identical copy of active-wave detection
# (hooks/landing-gate.sh, the block deliberately duplicated from dispatch-preflight's) and
# until this party existed it sat OUTSIDE the very battery meant to catch that copy drifting
# — §J drives the gate's verdict/gate agreement, not its wave detection (Step-6 critic D-1).
# Its observable is a Stop over a roster carrying ONE unmet contract that has LANDED (its
# agent_id is absent from the payload's background_tasks): with a wave active the gate
# reaches the verdict, reads UNMET and refuses (exit 2); with no wave it exits 0 before ever
# taking a verdict. So exit-2-with-the-refusal <=> yes and exit-0 <=> no, the same predicate
# the other four answer. The gate resolves the sweeper as its own sibling, so a MUTATED copy
# of it (§A2) must sit beside a sweeper — $MUTDIR carries one. The roster is re-seeded per
# call under $SID_LG, off verdict_er's $SID_A file — which also clears the sweep's own
# idempotency marker, so every call is this row's first verdict.
verdict_lg() {  # <repo> -> yes|no|other:<detail>
  # TWO STATEMENTS, NOT ONE — the trap this file records at `j_mutant` and `mk_root`.
  # `local repo="$1" roster="$repo/…"` expands every word before it assigns any, so
  # `$roster` was built from whatever `repo` happened to be in a CALLER's scope; inside the
  # battery loop that was the right value by accident, and from anywhere else it is an
  # unbound-variable abort under `set -u`.
  local repo="$1" out st roster
  roster="$repo/.bionic/tmp/roster-$SID_LG.state"
  mkdir -p "$repo/.bionic/tmp"
  {
    roster_header
    roster_row_fixture status=confirmed session="$SID_LG" name=lg-probe \
      agent_id=alg-probe-0001 launched_at=2026-08-05T00:00:00Z \
      deliverable=.bionic/docs/record/never-lg.md tool_use_id=toolu_LGPROBE
  } > "$roster"
  out=$(mk_stopsweep_payload "$repo" "$SID_LG" false | bash "$PARTY_LG" 2>&1); st=$?
  case "$st" in
    0) echo no ;;
    2) if printf '%s' "$out" | grep -qF 'LANDING CONTRACT UNMET'; then echo yes; else echo "other:block-no-detail"; fi ;;
    *) echo "other:exit-$st" ;;
  esac
}

# ---------------------------------------------------------------- fixtures

write_plan() {  # <path> <state-body>
  mkdir -p "$(dirname "$1")"
  {
    printf -- '---\n'
    printf 'governing-skill: canonical-sdlc\ncanonical_sdlc_version: 14\n'
    printf 'intent: build\nrigor: audited\nscale: wave\n'
    printf -- '---\n\n# Fixture plan\n\n## SDLC State\n\nintegration-branch: main\n'
    printf '%s\n' "$2"
    printf '\n- Step 3: prior evidence\n'
  } > "$1"
}

# A LIVE WAVE HAS A LIVE PATROL (epic-17 W5 4/4). hooks/dispatch-preflight.sh refuses a
# dispatch whose session carries no fresh Patrol stamp, so a repo fixture without one answers
# "refused" to every question this suite asks about roster rows, identity chains and progress
# paths — the arming wall would be under test in every section instead of in its own (§P,
# which removes the stamp deliberately). This is the fixture equivalent of an engagement
# arming the Patrol before the first dispatch. Written under the MAIN repository always: the
# stamp shares the roster's pinned root, which §N.3 depends on and would break by planting
# a phantom `.bionic` in a worktree.
arm_patrol() {  # <repo> <session-id>...
  local repo="$1"; shift
  mkdir -p "$repo/.bionic/tmp"
  local sid
  for sid in "$@"; do
    printf 'patrol-stamp/v1|at=%s|session=%s|verb=arm\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sid" > "$repo/.bionic/tmp/patrol-$sid.state"
    chmod 600 "$repo/.bionic/tmp/patrol-$sid.state"
    # …AND AN ENGAGED SESSION (task-engaged-session). Since this wave every gate this suite
    # drives asks `engaged_session` before it asks anything else, so a fixture without the
    # marker answers every question in this file the same way — silence — and the whole
    # suite would be green over nothing. The marker travels with the stamp for the same
    # reason the stamp travels with the plan: SKILL.md arms the Patrol AT engagement, so a
    # world that has one has both.
    : > "$repo/.bionic/tmp/engaged-$sid.state"
  done
}

# ENGAGEMENT (task-engaged-session, 2026-09-03). Every party in this battery asks whether
# the session invoked the canonical-sdlc skill before it asks whether a run is open, so a
# fixture built to make the five parties agree about the RUN has to clear that question
# first — for each session key any party is driven under. Without it every party would
# answer "no run" for a reason that has nothing to do with the plan on disk, and the whole
# battery would agree vacuously.
engage_sids() {  # <repo> <sid>...
  local r="$1"; shift
  mkdir -p "$r/.bionic/tmp"
  local s
  for s in "$@"; do : > "$r/.bionic/tmp/engaged-$s.state"; done
}

new_repo() {  # <name> -> path
  local r="$SANDBOX/fx/$1/repo"
  mkdir -p "$r/.bionic/tmp"
  git -C "$r" init -q 2>/dev/null
  arm_patrol "$r" "$SID_A" "$SID_B" "$SID_LG"
  engage_sids "$r" "$SID_A" "$SID_B" "$SID_LG"
  printf '%s' "$r"
}

# name|expected-answer|expected-current
FIXTURES='
baseline-active|yes|4
no-plan-dir|no|-
no-sdlc-state|no|-
docs-root-double-quoted|yes|4
docs-root-single-quoted|yes|4
docs-root-absolute|yes|4
docs-root-duplicate-lines|yes|4
docs-root-indented|yes|4
docs-root-trailing-space|yes|4
plan-crlf|yes|4
plan-cr-only|yes|4
current-indented|yes|4
current-duplicate-lines|yes|4
current-fenced-only|no|-
newest-plan-wins|yes|8b
marker-less-newest-loses|yes|4
fenced-only-newest-loses|yes|4
only-marker-less-files|no|-
nested-two-deep|yes|4
nested-three-deep|no|-
incidents-dir|yes|4
current-8b|yes|8b
current-placeholder|no|-
'

build_fixture() {  # <name> -> repo path
  local name="$1" repo
  repo=$(new_repo "$name")
  case "$name" in
    baseline-active)
      write_plan "$repo/.bionic/docs/plans/epic-99/wave-01.md" "current: 4" ;;
    no-plan-dir)
      mkdir -p "$repo/.bionic/docs" ;;
    no-sdlc-state)
      mkdir -p "$repo/.bionic/docs/plans/epic-99"
      printf -- '---\ncanonical_sdlc_version: 14\n---\n\n# Notes\n\ncurrent: 4\n' \
        > "$repo/.bionic/docs/plans/epic-99/wave-01.md" ;;

    # --- A9's undiscriminated parser edges, each built so a mis-parse FLIPS ---
    # the answer: the override points at the only directory holding a plan, and
    # the default root holds none.
    docs-root-double-quoted)
      printf 'docs-root: "custom-docs"\n' > "$repo/.bionic/config.yaml"
      write_plan "$repo/custom-docs/plans/epic-99/wave-01.md" "current: 4" ;;
    docs-root-single-quoted)
      printf "docs-root: 'other-docs'\n" > "$repo/.bionic/config.yaml"
      write_plan "$repo/other-docs/plans/epic-99/wave-01.md" "current: 4" ;;
    docs-root-absolute)
      # An ABSOLUTE override is used as-is; treating it as repo-relative yields
      # "$repo/$abs", which does not exist, and the answer flips to no.
      mkdir -p "$SANDBOX/fx/$name/elsewhere"
      printf 'docs-root: %s\n' "$SANDBOX/fx/$name/elsewhere" > "$repo/.bionic/config.yaml"
      write_plan "$SANDBOX/fx/$name/elsewhere/plans/epic-99/wave-01.md" "current: 4" ;;
    docs-root-duplicate-lines)
      # FIRST directive wins (head -1). The second names a real but planless
      # directory, so last-wins flips the answer.
      { printf 'docs-root: live-docs\n'; printf 'docs-root: dead-docs\n'; } \
        > "$repo/.bionic/config.yaml"
      mkdir -p "$repo/dead-docs/plans"
      write_plan "$repo/live-docs/plans/epic-99/wave-01.md" "current: 4" ;;
    docs-root-indented)
      printf '  docs-root: indented-docs\n' > "$repo/.bionic/config.yaml"
      write_plan "$repo/indented-docs/plans/epic-99/wave-01.md" "current: 4" ;;
    docs-root-trailing-space)
      printf 'docs-root: trail-docs   \n' > "$repo/.bionic/config.yaml"
      write_plan "$repo/trail-docs/plans/epic-99/wave-01.md" "current: 4" ;;

    # --- line endings: CRLF is common, CR-only is the fail-dangerous one ---
    plan-crlf)
      write_plan "$repo/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"
      awk '{ printf "%s\r\n", $0 }' "$repo/.bionic/docs/plans/epic-99/wave-01.md" \
        > "$repo/.bionic/docs/plans/epic-99/wave-01.md.x"
      mv "$repo/.bionic/docs/plans/epic-99/wave-01.md.x" \
         "$repo/.bionic/docs/plans/epic-99/wave-01.md" ;;
    plan-cr-only)
      # `tr -d '\r'` collapses this to ONE line and every line-anchored match
      # misses — the silently-inert-wall shape from .claude/rules/hook-authoring.md.
      write_plan "$repo/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"
      tr '\n' '\r' < "$repo/.bionic/docs/plans/epic-99/wave-01.md" \
        > "$repo/.bionic/docs/plans/epic-99/wave-01.md.x"
      mv "$repo/.bionic/docs/plans/epic-99/wave-01.md.x" \
         "$repo/.bionic/docs/plans/epic-99/wave-01.md" ;;

    # --- the `current:` directive's own edges ---
    current-indented)
      write_plan "$repo/.bionic/docs/plans/epic-99/wave-01.md" "   current :  4" ;;
    current-duplicate-lines)
      write_plan "$repo/.bionic/docs/plans/epic-99/wave-01.md" \
        "$(printf 'current: 4\ncurrent: notastep')" ;;
    current-fenced-only)
      # The ONLY `## SDLC State` in the file is inside a fenced example. A
      # fence-blind parser reads it and reports an active wave on a plan that
      # documents the schema rather than running it.
      mkdir -p "$repo/.bionic/docs/plans/epic-99"
      {
        printf -- '---\ncanonical_sdlc_version: 14\nscale: wave\n---\n\n# Schema doc\n\n'
        printf 'The section looks like this:\n\n```\n## SDLC State\n\ncurrent: 4\n```\n'
      } > "$repo/.bionic/docs/plans/epic-99/wave-01.md" ;;
    newest-plan-wins)
      # NEWEST among CANDIDATE PLANS wins. Both files are real plans here, so the
      # predicate cannot discriminate and the DERIVED VALUE is what does: an
      # oldest-wins selection reports 4 instead of 8b. This fixture used to make
      # the newer file a marker-less note and expect `no` — which pinned the
      # off-switch (record/session-20260815-landing-supervision/t8-forensic-read.md)
      # as intended behaviour. That shape is now its own fixture, expecting the
      # opposite; the newest-wins claim survives here, on two plans.
      write_plan "$repo/.bionic/docs/plans/epic-99/a-older.md" "current: 4"
      touch -t 202001010000 "$repo/.bionic/docs/plans/epic-99/a-older.md"
      write_plan "$repo/.bionic/docs/plans/epic-99/b-newer.md" "current: 8b"
      touch -t 203001010000 "$repo/.bionic/docs/plans/epic-99/b-newer.md" ;;
    marker-less-newest-loses)
      # AC-10, THE OFF-SWITCH. A stray marker-less *.md — a continuation note, a
      # probe scrap, a Step-9 artifact — is newest under plans/ while a real plan
      # with a live `current:` sits beside it. Selecting the stray reads `current:`
      # empty and every wall in this battery passes silently with a wave running.
      # That is not hypothetical: it disarmed this repo for ~15 minutes on
      # 2026-08-15, twice, by two agents, neither trying. The real plan must win.
      write_plan "$repo/.bionic/docs/plans/epic-99/session.plan.md" "current: 4"
      touch -t 202001010000 "$repo/.bionic/docs/plans/epic-99/session.plan.md"
      printf -- '---\ncanonical_sdlc_version: 14\n---\n\n# Continuation\n\ncurrent: 4\n' \
        > "$repo/.bionic/docs/plans/epic-99/continuation.md"
      touch -t 203001010000 "$repo/.bionic/docs/plans/epic-99/continuation.md" ;;
    fenced-only-newest-loses)
      # The same shape one turn subtler: the newest file DOES contain the string
      # `## SDLC State`, inside a fenced example. A fence-blind candidate filter
      # accepts it, `current:` parses empty through the fence-aware read, and the
      # off-switch is back — so the candidate filter is fence-aware exactly like
      # the read it feeds. (The fenced file alone still passes silently:
      # `current-fenced-only` holds that direction.)
      write_plan "$repo/.bionic/docs/plans/epic-99/session.plan.md" "current: 4"
      touch -t 202001010000 "$repo/.bionic/docs/plans/epic-99/session.plan.md"
      {
        printf -- '---\ncanonical_sdlc_version: 14\n---\n\n# Schema notes\n\n'
        printf 'The section looks like this:\n\n```\n## SDLC State\n\ncurrent: 4\n```\n'
      } > "$repo/.bionic/docs/plans/epic-99/schema-notes.md"
      touch -t 203001010000 "$repo/.bionic/docs/plans/epic-99/schema-notes.md" ;;
    only-marker-less-files)
      # THE PRESERVED AMBIGUITY. A plans tree holding no valid plan at all still
      # reads as "no wave" and passes SILENTLY — the ratified fail direction, and
      # the reason the fix is a candidate filter rather than a refusal: skipping
      # every candidate must land in the same place as finding none.
      mkdir -p "$repo/.bionic/docs/plans/epic-99"
      printf -- '---\ncanonical_sdlc_version: 14\n---\n\n# Continuation\n' \
        > "$repo/.bionic/docs/plans/epic-99/continuation.md"
      printf '# Scratch\n\ncurrent: 4\n' \
        > "$repo/.bionic/docs/plans/epic-99/scratch.md" ;;
    nested-two-deep)
      write_plan "$repo/.bionic/docs/plans/epic-99/wave-01.md" "current: 4" ;;
    nested-three-deep)
      # DEPTH 3 IS OUT OF THE BOUND, and this fixture is where that is decided for the whole
      # fleet. Two depths were live during bionic 1.4.0 — the hand-copies and the evidence
      # gate walked 2, which is the bionic layout's own depth (plans/<epic>/<wave>.plan.md),
      # and L-RUN shipped 3 — and §S.3d pinned the disagreement rather than papering over it.
      # POKER/2's unification (ratified 2026-09-03) resolves it AT 2: the descend-2 read is
      # the one §S holds body-for-body, anything deeper under plans/ is notes rather than a
      # plan, and a bound nobody can state from the layout is a bound that drifts again. All
      # five parties read the library, so all five must agree it is not a run.
      write_plan "$repo/.bionic/docs/plans/epic-99/sub/wave-01.md" "current: 4" ;;
    incidents-dir)
      write_plan "$repo/.bionic/docs/incidents/inc-01/incident.md" "current: 4" ;;
    current-8b)
      write_plan "$repo/.bionic/docs/plans/epic-99/wave-01.md" "current: 8b" ;;
    current-placeholder)
      # A plan that exists but names no step is not a run in progress.
      write_plan "$repo/.bionic/docs/plans/epic-99/wave-01.md" "current: pending" ;;
    *) echo "UNKNOWN FIXTURE $name" >&2; exit 9 ;;
  esac
  printf '%s' "$repo"
}

echo "building fixture repos..."
while IFS='|' read -r name want cur; do
  [ -n "$name" ] || continue
  build_fixture "$name" >/dev/null
done <<EOF
$(printf '%s' "$FIXTURES")
EOF

# A MUTANT NEEDS THE LIBRARY BESIDE IT (bionic 1.4.0). Every hook loads root.sh, run.sh
# and session.sh through the shared loader idiom, whose first candidate is
# `$(dirname "$0")/../scripts/lib`. A copy alone in a temp directory does not find it
# there — and the loader's HEALING candidates then reach the plugin installed on this
# machine, whose library predates this wave and does not carry the wanted basenames — so
# the copy fails OPEN and every mutation arm below would be measuring the step-aside
# instead of the mutation. `plant_hook_tree` builds the shipped shape around a mutant:
# hooks/ beside scripts/lib/, holding this checkout's library.
plant_hook_tree() {  # <tree root> -> echoes <tree root>/hooks
  local root="$1" src="$BIONIC_HOOKS_DIR/../payload/scripts/lib"
  [ -d "$src" ] || src="$BIONIC_HOOKS_DIR/../scripts/lib"
  mkdir -p "$root/hooks" "$root/scripts/lib"
  cp "$src"/*.sh "$root/scripts/lib/" 2>/dev/null || true
  printf '%s' "$root/hooks"
}

# run_battery <mode>  — mode=assert emits one assertion per fixture;
#                       mode=detect returns 1 at the FIRST disagreement.
run_battery() {
  local mode="$1" name want cur repo a b c d e cnorm cval want_sg want_dp want_er want_lg
  while IFS='|' read -r name want cur; do
    [ -n "$name" ] || continue
    repo="$SANDBOX/fx/$name/repo"
    a=$(verdict_dp "$repo"); b=$(verdict_sg "$repo"); c=$(verdict_eg "$repo")
    d=$(verdict_er "$repo"); e=$(verdict_lg "$repo")
    cnorm="${c%%:*}"; cval=""
    [ "$cnorm" = "yes" ] && cval="${c#*:}"
    # T4 (session-20260815-landing-cleanup): verdict_sg always drives stop-guard
    # with the fixed target "no-such-agent" — non-address-shaped. With a wave
    # active, MATCH_COUNT=0 + the shape carve now PASSES THROUGH instead of
    # refusing, a ratified divergence (design ¶T4), not a defect. Only
    # stop-guard's expectation moves here; the other four parties' semantics
    # are unchanged by T4, so their comparisons still read "$want" directly.
    want_sg="$want"
    [ "$want" = "yes" ] && want_sg="other:pass-with-output"
    # WHAT THE PARTIES AGREE ABOUT CHANGED AT task-engaged-session, and the change is the
    # point of that wave. Four of the five no longer read the plan at all: they are scoped
    # by ENGAGEMENT, and every fixture in this battery is engaged (see `arm_patrol`), so
    # each of them answers the same thing on all 23 plan shapes. That constancy is the
    # claim now — a party that still had a plan opinion of its own would break it — and it
    # is asserted here rather than dropped, because "the plan does not move this gate" is
    # exactly what a future edit could silently undo. The evidence gate is the one party
    # that still derives the plan's `current:`, so it keeps the discriminating column and
    # the derived-value check below.
    want_dp="yes"; want_er="yes"; want_lg="yes"; want_sg="other:pass-with-output"
    if [ "$mode" = "assert" ]; then
      if [ "$a" = "$want_dp" ] && [ "$b" = "$want_sg" ] && [ "$cnorm" = "$want" ] && [ "$d" = "$want_er" ] && [ "$e" = "$want_lg" ]; then
        ok "all five parties agree on '$name': engagement-scoped four constant, evidence gate $want"
      else
        no "all five parties agree on '$name': engagement-scoped four constant, evidence gate $want" \
           "dispatch-preflight=$a stop-guard=$b evidence-gate=$c execution-recorder=$d landing-gate=$e"
      fi
      if [ "$want" = "yes" ]; then
        expect_eq "  and the evidence gate derived current='$cur' for '$name'" "$cur" "$cval"
      fi
    else
      # Detect mode also compares the DERIVED VALUE, so a mutation that selects a
      # different plan without flipping the predicate is caught too.
      if [ "$a" != "$want_dp" ] || [ "$b" != "$want_sg" ] || [ "$cnorm" != "$want" ] || [ "$d" != "$want_er" ] || [ "$e" != "$want_lg" ] \
         || { [ "$want" = "yes" ] && [ "$cval" != "$cur" ]; }; then
        printf 'disagreement on %s: want=%s/%s dp=%s sg=%s eg=%s er=%s lg=%s\n' "$name" "$want" "$cur" "$a" "$b" "$c" "$d" "$e"
        return 1
      fi
    fi
  done <<EOF
$(printf '%s' "$FIXTURES")
EOF
  return 0
}

# ============================================================
section "A1 — N-way agreement on active-wave detection (AC-9, checklist A8/A9)"
# ============================================================
echo "parties: $(basename "$PARTY_DP") · $(basename "$PARTY_SG") · $(basename "$PARTY_EG") · $(basename "$PARTY_ER") · $(basename "$PARTY_LG")"

run_battery assert

# THE OTHER DIRECTION OF THE SWITCH, once. The four constants above are worth nothing
# unless the marker is what produces them: on the SAME fixture, with the marker removed,
# every one of the five answers "no" and says nothing. The plan shape is irrelevant to
# this claim — engagement is asked before the plan is read — so one fixture discharges it,
# and tests/hook-adoption.test.sh §5c drives the same direction across the wider roster.
UNENG="$SANDBOX/fx/baseline-active/repo"
for _u in "$SID_A" "$SID_B" "$SID_LG"; do rm -f "$UNENG/.bionic/tmp/engaged-$_u.state"; done
expect_eq "unengaged: the dispatch wall decides nothing"      "no" "$(verdict_dp "$UNENG")"
expect_eq "unengaged: the stop gate decides nothing"          "no" "$(verdict_sg "$UNENG")"
expect_eq "unengaged: the recorder journals nothing"          "no" "$(verdict_er "$UNENG")"
expect_eq "unengaged: the landing gate takes no verdict"      "no" "$(verdict_lg "$UNENG")"
arm_patrol "$UNENG" "$SID_A" "$SID_B" "$SID_LG"
expect_eq "…and re-engaged, the dispatch wall decides again"  "yes" "$(verdict_dp "$UNENG")"

# The origin is IN the test, not merely cited by it. Checklist A8's defect was
# exactly this: three byte-identical copies, a 2-way agreement test, and the
# actively-maintained origin absent from the test meant to catch drift.
# The landing gate carries a copy too (Step-6 critic D-1) — it is now a driven party, and
# the copy it holds is really the active-wave detection block, not something else.

# ============================================================
section "A2 — a LIBRARY mutation moves every party (checklist A9, TDD §9)"
# ============================================================
#
# WHAT THIS SECTION USED TO PROVE, AND WHY THE PROOF MOVED. Until bionic 1.4.0 the
# active-wave block was five hand-copies, and A9's finding was that a suite which cannot
# tell them apart is decorative: the discriminator was mutating ONE copy and requiring the
# battery to go red. There are no copies left. The block is `lib/run.sh` and the five
# parties source it, so the honest discriminator inverts: mutate the LIBRARY, and EVERY
# party must move. A party that had quietly kept its own answer — a leftover local
# parse, a hook that reads the plan itself — would stay green here and nowhere else.
#
# Each mutation is a plausible drift, not damage: a maintainer editing the one reader and
# getting a rule subtly wrong. The shipped library is never modified; each mutant is a
# copy inside a throwaway tree shaped like the shipped plugin (hooks/ beside scripts/lib/),
# which is also what makes the parties load the mutant at all — the loader's first
# candidate is `$(dirname "$0")/../scripts/lib`.

CKSUM_BEFORE=$(shasum "$PARTY_DP" "$PARTY_SG" "$PARTY_EG" "$PARTY_ER" "$PARTY_LG" 2>/dev/null)
RUN_LIB="$BIONIC_HOOKS_DIR/../payload/scripts/lib/run.sh"
[ -r "$RUN_LIB" ] || RUN_LIB="$BIONIC_HOOKS_DIR/../scripts/lib/run.sh"
LIB_DIR_SRC="$(dirname "$RUN_LIB")"
MUTDIR="$SANDBOX/mutants"; mkdir -p "$MUTDIR"

expect_eq "the library under mutation is on disk (this section is not vacuous)" "yes" \
  "$([ -r "$RUN_LIB" ] && echo yes || echo no)"

# mutate_lib <kind> <dst>  — rc 1 if the mutation matched nothing
mutate_lib() {
  local kind="$1" dst="$2" src="$RUN_LIB"
  case "$kind" in
    docs-root-last-wins)   # head -1 -> tail -1 in docs_root
      awk 'BEGIN{d=0} !d && $0=="      | head -1 \\" {print "      | tail -1 \\"; d=1; next} {print}' \
        "$src" > "$dst" ;;
    keep-quotes)           # drop the quote-stripping sed in docs_root
      awk 'BEGIN{d=0} !d && index($0,";s/[") {print "      | cat \\"; d=1; next} {print}' \
        "$src" > "$dst" ;;
    delete-cr)             # translate-CR -> delete-CR (the fail-dangerous shape)
      awk '{ i=index($0,"gsub(/\\r/, \"\\n\"); ");
             while (i>0) { $0=substr($0,1,i-1) substr($0,i+20); i=index($0,"gsub(/\\r/, \"\\n\"); ") }
             print }' "$src" > "$dst" ;;
    depth-1)               # plan search one level shallower
      awk '{ i=index($0,"-maxdepth 2 -type f -name '"'"'*.md'"'"'");
             if (i>0) { $0=substr($0,1,i-1) "-maxdepth 1 -type f -name '"'"'*.md'"'"'" substr($0,i+33) }
             print }' "$src" > "$dst" ;;
    fence-blind)           # stop skipping fenced content
      awk '{ t=$0; sub(/^[ \t]+/,"",t); sub(/[ \t]+$/,"",t); if (t=="fence { next }") next; print }' \
        "$src" > "$dst" ;;
    no-marker-skip)        # accept marker-less candidates again
      awk '{ t=$0; sub(/^[ \t]+/,"",t); sub(/[ \t]+$/,"",t);
             if (t=="END { exit !found }'"'"' || continue") next; print }' "$src" > "$dst" ;;
    anchor-current)        # lose the leading-whitespace tolerance on `current:`
      awk '{ i=index($0,"'"'"'^[[:space:]]*current[[:space:]]*:'"'"'");
             if (i>0) { $0=substr($0,1,i-1) "'"'"'^current:'"'"'" substr($0,i+38) }
             print }' "$src" > "$dst" ;;
    *) echo "unknown mutation $kind" >&2; return 1 ;;
  esac
  cmp -s "$src" "$dst" && return 1
  return 0
}

MUTATIONS="docs-root-last-wins keep-quotes delete-cr depth-1 fence-blind anchor-current no-marker-skip"

for m in $MUTATIONS; do
  tree="$MUTDIR/$m"
  mkdir -p "$tree/hooks" "$tree/scripts/lib"
  cp "$LIB_DIR_SRC"/*.sh "$tree/scripts/lib/" 2>/dev/null
  if ! mutate_lib "$m" "$tree/scripts/lib/run.sh"; then
    # A mutation that matches nothing is not a passing test — it means the code moved
    # and this proof has gone vacuous (fixtures-can-pin-away-the-test).
    no "mutation '$m' applies to lib/run.sh" "the awk target matched nothing — the library moved"
    continue
  fi
  for _pf in "$PARTY_DP" "$PARTY_SG" "$PARTY_EG" "$PARTY_ER" "$PARTY_LG" "$PARTY_SW"; do
    cp "$_pf" "$tree/hooks/$(basename "$_pf")"
  done
  saved_dp="$PARTY_DP"; saved_sg="$PARTY_SG"; saved_eg="$PARTY_EG"
  saved_er="$PARTY_ER"; saved_lg="$PARTY_LG"
  PARTY_DP="$tree/hooks/$(basename "$saved_dp")"
  PARTY_SG="$tree/hooks/$(basename "$saved_sg")"
  PARTY_EG="$tree/hooks/$(basename "$saved_eg")"
  PARTY_ER="$tree/hooks/$(basename "$saved_er")"
  PARTY_LG="$tree/hooks/$(basename "$saved_lg")"
  if detail=$(run_battery detect); then
    no "library mutation '$m' makes the battery RED" \
       "the battery stayed green with the one reader mutated — it does not discriminate"
  else
    ok "library mutation '$m' makes the battery RED"
  fi
  PARTY_DP="$saved_dp"; PARTY_SG="$saved_sg"; PARTY_EG="$saved_eg"
  PARTY_ER="$saved_er"; PARTY_LG="$saved_lg"
done

# THE PAIRED POSITIVE: the same throwaway tree with an UNMUTATED library must be green,
# or every red above is the copying and not the mutation.
ctrl="$MUTDIR/control"
mkdir -p "$ctrl/hooks" "$ctrl/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$ctrl/scripts/lib/" 2>/dev/null
for _pf in "$PARTY_DP" "$PARTY_SG" "$PARTY_EG" "$PARTY_ER" "$PARTY_LG" "$PARTY_SW"; do
  cp "$_pf" "$ctrl/hooks/$(basename "$_pf")"
done
saved_dp="$PARTY_DP"; saved_sg="$PARTY_SG"; saved_eg="$PARTY_EG"
saved_er="$PARTY_ER"; saved_lg="$PARTY_LG"
PARTY_DP="$ctrl/hooks/$(basename "$saved_dp")"
PARTY_SG="$ctrl/hooks/$(basename "$saved_sg")"
PARTY_EG="$ctrl/hooks/$(basename "$saved_eg")"
PARTY_ER="$ctrl/hooks/$(basename "$saved_er")"
PARTY_LG="$ctrl/hooks/$(basename "$saved_lg")"
if detail=$(run_battery detect); then
  ok "control: the same tree with an UNMUTATED library is green"
else
  no "control: the same tree with an UNMUTATED library is green" "$detail"
fi
PARTY_DP="$saved_dp"; PARTY_SG="$saved_sg"; PARTY_EG="$saved_eg"
PARTY_ER="$saved_er"; PARTY_LG="$saved_lg"

# ============================================================
section "A3 — the one KNOWN divergence, pinned so it cannot drift silently"
# ============================================================
#
# `current: T<n>` on a plan that is not `scale: task`: the two gates read the
# task token as an active wave (conservative — a task run IS a run); the
# evidence gate rejects the plan as invalid, because a T-token is legal only at
# task scale (conservative in the other direction — it blocks the commit). Both
# refuse; neither passes. Nothing here is a defect, and the reason this is
# pinned rather than left implicit is checklist A10: an unpinned asymmetry
# between gates is exactly what shipped last time.

TREPO=$(new_repo "known-divergence")
write_plan "$TREPO/.bionic/docs/plans/epic-99/wave-01.md" "current: T4"
expect_eq "T-token, wave scale: the start gate reads an active wave"  "yes" "$(verdict_dp "$TREPO")"
# T4 (session-20260815-landing-cleanup): the stop gate still READS this as an
# active wave (it reaches the MATCH_COUNT/shape-carve code at all), but
# verdict_sg's fixed target "no-such-agent" is non-address-shaped, so the
# ratified shape carve now passes it through instead of refusing.
expect_eq "T-token, wave scale: the stop gate reads an active wave"   "other:pass-with-output" "$(verdict_sg "$TREPO")"

# ============================================================
section "B — the session-identity key: producer and BOTH consumers agree"
# ============================================================
#
# Ownership table (spec §Design): preflight-probe WRITES the session identity;
# dispatch-preflight and stop-guard READ it. The per-component suites each hold
# their own half — the producer's suite reads back what it wrote, the start
# gate's suite writes attestations as fixtures. Neither proves the two halves
# spell or compare the key the same way. Here ONE value produced by the REAL
# producer flows through both consumers.

IREPO=$(new_repo "identity")
# The metadata lives where the PLATFORM puts it — under the configured metadata
# root, in this project's slug directory, in this session's own directory. The
# earlier version of this fixture invented a transcript path outside any
# projects root, which let the record and the gate-pass below stand behind an
# observation that resolved nothing (Step-6 critic, issue 1). A fixture that
# cannot be reached by BOTH parties proves nothing about their agreement.
ISLUG=$(printf '%s' "$IREPO" | sed 's/[^a-zA-Z0-9]/-/g')
IPROJ="$CLAUDE_CONFIG_DIR/projects/$ISLUG"
ISUB="$IPROJ/$SID_A/subagents"
mkdir -p "$ISUB"
ITR="$IPROJ/$SID_A.jsonl"
printf '{}\n' > "$ITR"
printf '{"name":"worker","agentType":"implementor"}' > "$ISUB/agent-aworker-1111111111111111.meta.json"
printf '{}\n' > "$ISUB/agent-aworker-1111111111111111.jsonl"
# …and the two facts S6 added to "reachable by both parties": a line in this session's live
# set, and a roster row carrying the agent id the working log is filed under.
cg_live "$ITR" "worker"
cg_roster_row "$IREPO" "$SID_A" "worker" "aworker-1111111111111111" "" "identified"
write_plan "$IREPO/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"

# The producer, run for real, with the session key on the channel it actually
# reads (CLAUDE_CODE_SESSION_ID — slice 4/1's resolution) and a credential
# present so the blocking probes pass.
( cd "$IREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" ANTHROPIC_API_KEY="sk-fixture-not-a-real-key" \
    HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
    bash "$PROBE" >"$SANDBOX/probe.out" 2>"$SANDBOX/probe.err" )
PROBE_ST=$?
# slice 4/2 (D-5): the session identity is now carried in TWO places that must agree —
# the FILENAME and the session_id= line inside it. A producer and a consumer that
# disagreed on the filename scheme would refuse every dispatch, so the path is asserted
# here as part of the same agreement the key is.
ATT="$IREPO/.bionic/tmp/preflight-$SID_A.state"
expect_eq "the attestation exists where both consumers look" "yes" "$([ -f "$ATT" ] && echo yes || echo no)"

# The producer's spelling and the consumer's spelling are the same key.
expect_contains "the producer spells the identity key 'session_id='" "session_id=$SID_A" "$(cat "$ATT")"

# Consumer 1 — the start gate: the produced value passes; one character off refuses.
# "Passes in silence" used to need a genuinely LIVE session sweeper armed for this
# session/repo, or the unarmed-sweeper nag fired legitimately and broke the claim. Both the
# nag and the watcher it asked about were deleted in epic-16 wave-02, so silence is the
# gate's own unaided answer here.
OUT=$(mk_agent_payload "$SID_A" "$IREPO" | bash "$PARTY_DP" 2>&1); ST=$?
expect_eq "start gate: the producer's own session passes" "0" "$ST"
# "IN SILENCE" IS NOW "SILENT ABOUT THE ATTESTATION", and the change is a change of
# CHANNEL, not of strength (wave-session-bound-run). Every fixture in this file engages its
# sessions with an EMPTY marker — that is, engaged and UNBOUND — so since S5 the gate
# announces the resolution it used on stderr before it looks at anything else:
# `dispatch-preflight: run resolved by newest-plan fallback (session unbound) — <plan>`.
# That line is a report about which run answered, not a complaint about the attestation,
# and asserting an empty buffer would now make this section fail for a reason it is not
# about. So the resolution line is lifted out and asserted POSITIVELY — a filter that could
# hide a hook gone silent altogether is not a filter, it is a hole — and the remainder is
# held to the emptiness this section has always claimed.
DP_RESOLUTION=$(printf '%s\n' "$OUT" | grep -c '^dispatch-preflight: run resolved by newest-plan fallback (session unbound) — /')
DP_REST=$(printf '%s\n' "$OUT" | grep -v '^dispatch-preflight: run resolved by newest-plan fallback (session unbound) — /')
expect_eq "start gate: it announces the resolution it used, once (AC-3 — the fixture is unbound)" \
  "1" "$DP_RESOLUTION"
expect_eq "start gate: and passes in silence about the attestation" "" "$DP_REST"
# THE NEAR-MISS SESSION IS ENGAGED TOO (task-engaged-session). Both gates ask
# `engaged_session` before anything else, keyed to the session in hand — so without a
# marker for THIS spelling the gate would exit at the switch and the exact-compare claim
# would be discharged by a silence that never reached the attestation.
arm_patrol "$IREPO" "${SID_A%?}0"
OUT=$(mk_agent_payload "${SID_A%?}0" "$IREPO" | bash "$PARTY_DP" 2>&1); ST=$?
expect_eq "start gate: a one-character-different session is refused (exact compare)" "2" "$ST"
OUT=$(mk_agent_payload "$SID_B" "$IREPO" | bash "$PARTY_DP" 2>&1); ST=$?
expect_eq "start gate: a foreign session is refused" "2" "$ST"

# Consumer 2 — the stop gate: the recorder writes the key, the gate compares it.
# Same literal value, produced by the same session, carried by the payload.
#
# Both sessions get a row so that the roster is not what differs between the two
# stops below: the ONLY thing that differs is the session value carried by the
# record and the payload, which is what this section is about.
cg_roster_row "$IREPO" "$SID_A" "worker" "aworker-1111111111111111"
cg_roster_row "$IREPO" "${SID_A%?}0" "worker" "aworker-1111111111111111"
run_pair "$IREPO" "$ITR" "$SID_A" worker
SGSTATE="$IREPO/.bionic/tmp/stop-check.state"
expect_eq "the recorder wrote an observation record" "yes" "$([ -f "$SGSTATE" ] && echo yes || echo no)"
expect_contains "the recorder keys the record with the same session value" \
  "session=$SID_A" "$(cat "$SGSTATE")"
OUT=$(mk_stop_payload "$SID_A" "$ITR" "$IREPO" "worker" | bash "$PARTY_SG" 2>&1); ST=$?
expect_eq "stop gate: the same session's observation discharges the stop" "0" "$ST"

# Re-observe (the first record was consumed by the permitted stop, D-2), then
# prove a one-character-different session cannot spend it.
run_pair "$IREPO" "$ITR" "$SID_A" worker
OUT=$(mk_stop_payload "${SID_A%?}0" "$ITR" "$IREPO" "worker" | bash "$PARTY_SG" 2>&1); ST=$?
expect_eq "stop gate: a one-character-different session is refused (exact compare)" "2" "$ST"

# The two consumers key on the SAME payload field, which is the same value the
# producer took from the environment. If either side ever renamed its field,
# one of the three assertions above would fail — this one states the agreement
# itself, so the reason is legible when it does.

# ============================================================
section "C — target resolution: the observation and BOTH stop-guard arms agree"
# ============================================================
#
# `scan_subagent_dirs` and the portable file facts are duplicated between
# hooks/stop-check.sh and hooks/stop-guard.sh, and both copies carried a comment
# claiming this battery held them together while no such battery existed
# (Step-6 duplication review D1). Byte-identity of the FUNCTION was never the
# claim worth testing anyway: the two callers fed it different directory sets,
# and that divergence is what let an observation print "ambiguous — decide
# nothing" while the recorder wrote a dischargeable record (correctness C1).
#
# So the question this battery asks is the CALLERS' question, over one fixture
# world, with the two halves reaching the directories by their own means: the
# observation by slugifying its cwd (it has no payload), the recorder and the
# gate from the payload's transcript path. Agreement means all three answer the
# same way about the same typed name — or, where they deliberately differ, that
# the difference is pinned and fail-closed.

# The metadata root is the CONFIGURED one. `$CLAUDE_CONFIG_DIR` and
# `$HOME/.claude` are different directories in this suite (header), so every
# case below asks its question with the only variable that separates the two
# callers actually varying. Stated as an assertion rather than a comment,
# because a future edit that collapses the roots would silently make this whole
# battery blind again.

RSLUG=$(printf '%s' "$SANDBOX/fx/resolver/repo" | sed 's/[^a-zA-Z0-9]/-/g')
RPROJ="$CLAUDE_CONFIG_DIR/projects/$RSLUG"
RREPO=$(new_repo "resolver")
write_plan "$RREPO/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"
mkdir -p "$RPROJ/$SID_A/subagents" "$RPROJ/$SID_B/subagents"
printf '{}\n' > "$RPROJ/$SID_A.jsonl"
printf '{}\n' > "$RPROJ/$SID_B.jsonl"
RTR="$RPROJ/$SID_A.jsonl"

# Since S6 a target needs two more facts to resolve at all: a line in its session's LIVE SET
# (the recorded ListAgents answer), and a roster row carrying its agent id — which is what
# the working log is filed under, and what the deleted directory scan used to supply.
plant() {  # <subagents-dir> <agent-id> <name> [repo, default $RREPO]
  printf '{"name":"%s","agentType":"implementor","description":"fixture","model":"opus"}' "$3" \
    > "$1/agent-$2.meta.json"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}\n' \
    > "$1/agent-$2.jsonl"
  cg_live "${1%/subagents}.jsonl" "$3"
  roster_identify "${4:-$RREPO}" "$SID_A" "$3" "$2"
}

# The three questions, each asked of the REAL party.
q_observation() {  # <typed> -> resolved|ambiguous|unresolved
  local out
  out=$( cd "$RREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" "$1" 2>&1 )
  case "$out" in
    *"Resolved:      ambiguous"*)  echo ambiguous ;;
    *"Resolved:      unresolved"*) echo unresolved ;;
    # S6 spells the no-evidence-tier answer two ways where it used to spell it one: a target
    # the live set does not name is `not live`, and a session with no readable answer at all
    # is still `unresolved`. Both mean the same thing to the operator and to the recorder —
    # no evidence tier was shown, so no machine line is printed — so both map here.
    *"Resolved:      not live"*)   echo unresolved ;;
    *"Resolved:      live, but no agent id"*) echo unresolved ;;
    *"Resolved:      a"*)          echo resolved ;;
    *) echo "other" ;;
  esac
}
q_recorder() {  # <typed> -> recorded|nothing
  rm -f "$RREPO/.bionic/tmp/stop-check.state"
  run_pair "$RREPO" "$RTR" "$SID_A" "$1"
  if grep -q '^v1|' "$RREPO/.bionic/tmp/stop-check.state" 2>/dev/null; then
    echo recorded
  else
    echo nothing
  fi
}
q_gate() {  # <typed> -> permitted|refused   (asked AFTER q_recorder, on its state)
  mk_stop_payload "$SID_A" "$RTR" "$RREPO" "$1" | bash "$PARTY_SG" >/dev/null 2>&1
  [ "$?" -eq 0 ] && echo permitted || echo refused
}

# --- case 1: unique in this session. All three say yes. ---
plant "$RPROJ/$SID_A/subagents" "asolo-1111111111111111" "solo"
# …and this session's roster records it. Since slice 4/9 the row is not what makes
# it ours — it is filed under this session's own directory — but keeping the row
# holds this case fixed on the RESOLUTION question the three parties are answering.
cg_roster_row "$RREPO" "$SID_A" "solo" "asolo-1111111111111111"
expect_eq "C1 observation resolves a uniquely-named agent" "resolved" "$(q_observation solo)"
expect_eq "C1 recorder records the same agent" "recorded" "$(q_recorder solo)"
expect_eq "C1 gate discharges the stop on that record" "permitted" "$(q_gate solo)"

# --- case 2: TWO LIVE TEAMMATES answering to one name — which is what "the same name in two
# sessions of this project" became at S6, because the count comes from the harness's answer
# and not from a directory walk. The operator is shown a candidate list and NO evidence tier,
# so nothing may be dischargeable. ---
plant "$RPROJ/$SID_A/subagents" "adup-2222222222222222" "dup"
plant "$RPROJ/$SID_A/subagents" "adup-3333333333333333" "dup"
expect_eq "C2 observation reports the cross-session name as AMBIGUOUS" \
  "ambiguous" "$(q_observation dup)"
expect_eq "C2 gate refuses it" "refused" "$(q_gate dup)"

# --- case 3: resolves only in ANOTHER session of this project. A KNOWN,
# PINNED divergence, not a defect: the observation is project-wide because it has
# no payload to scope it, while a stop is session-scoped because a session can
# only stop its own tasks. Before T4 this ran fail-closed in every direction —
# the operator could look, nothing recorded, the stop refused, naming the scope
# so the loop had a stated exit (readability R4). T4 (session-20260815-
# landing-cleanup) re-bases the stop-guard leg only: "foreign" wears no
# agent-address shape, so MATCH_COUNT=0 now passes it through instead of
# refusing — a ratified divergence (design ¶T4), never silent (one logged
# passthrough line names why it did not refuse). ---
# At S6 the shape of this case changes with the key: a teammate the harness names for THIS
# session is resolvable by both parties wherever its working log happens to be filed, and one
# it does not name is resolvable by neither. What stays is the leg the divergence was about —
# the observation shows, the gate decides — driven here on an agent whose log sits under
# another session's directory while this session's answer names it, which is the /clear shape.
plant "$RPROJ/$SID_B/subagents" "aforeign-4444444444444444" "foreign"
cg_live "$RTR" "foreign"
expect_eq "C3 observation can still SHOW another session's agent" \
  "resolved" "$(q_observation foreign)"

# --- case 4: unknown to both. "nobody" wears no agent-address shape, so T4's
# shape carve passes the stop through rather than refusing (same ratified
# divergence as case 3). ---
expect_eq "C4 observation reports an unknown name unresolved" "unresolved" "$(q_observation nobody)"

# --- case 5: the metadata root itself. The recorder and the gate reach the
# directories through the PAYLOAD's transcript path; the observation has no
# payload and must reach the same root by configuration. Where
# `$CLAUDE_CONFIG_DIR` names a root other than `$HOME/.claude` — which is the
# whole reason the variable exists — an observation rooted at `$HOME` looks in a
# directory the platform is not using: it shows the operator nothing, while the
# recorder records and the gate spends the record. That is the wall opening on a
# look that never happened, and it is the direction this case pins.
#
# Cases 1-4 above already run under the divergent roots and prove the AGREEING
# direction. This one plants a decoy under the default root and proves the
# observation does not answer from it. "decoy" wears no agent-address shape
# either, so T4's shape carve passes the gate's stop through rather than
# refusing (same ratified divergence as cases 3-4). ---
HOMEPROJ="$HOME/.claude/projects/$RSLUG"
mkdir -p "$HOMEPROJ/$SID_A/subagents"
plant "$HOMEPROJ/$SID_A/subagents" "adecoy-6666666666666666" "decoy"
expect_eq "C5 observation ignores metadata under \$HOME/.claude when CLAUDE_CONFIG_DIR names another root" \
  "unresolved" "$(q_observation decoy)"

# --- case 6: the ARGUMENT GRAMMAR itself — RESIDUAL CLOSED at slice 4/4.
#
# Cases 1-5 ask both halves about one typed name; this one asks them about one
# COMMAND LINE, which is the thing they actually share. It used to be the hardest
# row in this file, because there were TWO readers of that line: the observation
# parsed its own `$@`, and a PreToolUse recorder re-parsed the same string with a
# grammar of its own (skip `-*` tokens, take the first non-flag). Nothing held
# them together, and a slice that widened one of them shipped: `--progress <path>
# <agent>` had the operator looking at <agent> while the record named <path> — an
# attestation about an agent nobody examined (Step-6 review F-1). Narrowing the
# producer then CONVERTED two ordinary typos into refused-observation-still-
# recorded, and that residual was pinned here rather than claimed away (critic
# finding A).
#
# There is now ONE reader. The recorder fires PostToolUse and copies the machine
# line hooks/stop-check.sh prints on its success path, so a command the operator
# watched fail printed no line and leaves nothing behind. The rows below are the
# same rows, with the residual expectations replaced by the closure: every
# refused form records NOTHING, and the documented form still records its target.
# ---
plant "$RPROJ/$SID_A/subagents" "aworker-7777777777777777" "worker"
GPROG="$RREPO/.bionic/tmp/w-grammar.progress"
mkdir -p "$RREPO/.bionic/tmp"; printf 'step 1\n' > "$GPROG"

g_observation() {  # <args…> -> the agent id the OBSERVATION resolved, or "refused"
  local out st
  out=$( cd "$RREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" "$@" 2>&1 ); st=$?
  if [ "$st" -ne 0 ] && printf '%s' "$out" | grep -qF 'Usage:'; then echo refused; return; fi
  printf '%s' "$out" | grep -E '^Resolved:' | grep -oE 'a[a-z0-9-]*-[0-9a-f]{16}' | head -1
}
g_recorder() {  # <args…> -> the agent id the RECORDER wrote, or "nothing"
  rm -f "$RREPO/.bionic/tmp/stop-check.state"
  run_pair "$RREPO" "$RTR" "$SID_A" "$@"
  local rec
  rec=$(grep '^v1|' "$RREPO/.bionic/tmp/stop-check.state" 2>/dev/null \
    | tr '|' '\n' | grep '^target=' | cut -d= -f2 | head -1)
  [ -n "$rec" ] && echo "$rec" || echo nothing
}

# The documented interface line: target first, flag trailing. Both halves must
# name the SAME agent — this is the row that would have caught F-1's sibling had
# it been written for the trailing form only.
expect_eq "C6 trailing form — the observation resolves the typed target" \
  "aworker-7777777777777777" "$(g_observation worker report.md --progress "$GPROG")"
expect_eq "C6 trailing form — the recorder records the SAME agent from the same line" \
  "aworker-7777777777777777" \
  "$(g_recorder worker report.md --progress "$GPROG")"

# The leading form, which is what diverged. Both halves refuse together — the
# producer with a usage error, the recorder because a usage error prints no
# machine line.
expect_eq "C6 leading form — the observation refuses it" \
  "refused" "$(g_observation --progress "$GPROG" worker)"

# THE RESIDUAL, CLOSED (critic finding A, spec AC-3). This was the row that
# pinned a refused command still leaving a record because some token in it named
# a live agent: the flag VALUE `solo` was taken as the target while the operator
# saw a usage error. A PreToolUse reader could not do better — it fires before
# the command runs and never learns the outcome. The PostToolUse recorder does
# not read the command line at all, so there is no token for it to mistake.
expect_eq "C6 CLOSED — and the observation gave that operator nothing to act on" \
  "refused" "$(g_observation --progress solo worker)"

# THE SAME CLASS IN THE TARGET-FIRST DIRECTION, which the row above does not
# reach: it pins only the flag-VALUE variant. Two ordinary typos — a mistyped
# flag and the `=`-joined spelling — leave the target as the first non-flag
# token, which is exactly what the old recorder took, so the operator saw a usage
# error and zero evidence while the record still named the target and carried the
# working log's mtime and size that the gate's D-1 comparison spends. Both now
# record nothing, for the one reason that covers every member of the class: the
# run printed no machine line.
expect_eq "C6 CLOSED — a mistyped flag AFTER the target: the observation refuses it" \
  "refused" "$(g_observation worker --progres "$GPROG")"
expect_eq "C6 CLOSED — the =-joined spelling: the observation refuses it" \
  "refused" "$(g_observation worker "--progress=$GPROG")"

# The class, not the instances: the observation's exit status and the recorder's
# output are now ONE fact. Any command line at all — including ones nobody has
# thought of — agrees by construction, because a non-zero producer prints no
# machine line and the recorder has no other input.
for form in "worker --unknown-flag" "--progress" "ghost" "worker@" ; do
  # shellcheck disable=SC2086
  if [ "$(g_observation $form)" = "refused" ] || [ -z "$(g_observation $form)" ]; then
    # shellcheck disable=SC2086
    :
  else
    # shellcheck disable=SC2086
    expect_eq "C6 CLOSED — an evidence tier IS recorded: '$form'" \
      "aworker-7777777777777777" "$(g_recorder $form)"
  fi
done

# The derived FILE FACTS agree too: what the observation shows the reader as the
# working log's size is what the recorder writes down as the activity level. Two
# computations of one truth, previously untested together (D2).
plant "$RPROJ/$SID_A/subagents" "afacts-5555555555555555" "facts"
OBS_OUT=$( cd "$RREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" facts 2>&1 )
OBS_SIZE=$(printf '%s' "$OBS_OUT" | grep -E '^  size:' | grep -oE '[0-9]+' | head -1)
q_recorder facts >/dev/null
REC_SIZE=$(grep -F 'target=afacts-5555555555555555' "$RREPO/.bionic/tmp/stop-check.state" \
  | tr '|' '\n' | grep '^size=' | cut -d= -f2)
expect_eq "the size the observation PRINTS is the size the recorder STORES" \
  "$OBS_SIZE" "$REC_SIZE"

# ============================================================
section "D — cross-script security regressions (AC-8, TDD §8)"
# ============================================================
#
# Per-script coverage already exists for: the credential value never reaching
# the attestation or the producer's own output (preflight-probe.test.sh S4), and
# command text never reaching the observation state file (stop-guard.test.sh
# §7). What no per-script suite can assert is the CROSS-SCRIPT property: after
# driving all four with a secret-bearing command, NOTHING anywhere under the
# sandbox — repo, state, temp, or $HOME (where the evidence gate's audit stream
# lives) — contains that text.

SECRET="sk-ant-LEAKCANARY-9f2b41"
SREPO=$(new_repo "secrets")
# The metadata lives under the CONFIGURED root, because the producer now has to
# resolve the target for real before anything can be recorded (slice 4/4).
SSLUG=$(printf '%s' "$SREPO" | sed 's/[^a-zA-Z0-9]/-/g')
SPROJ="$CLAUDE_CONFIG_DIR/projects/$SSLUG"
mkdir -p "$SPROJ/$SID_A/subagents"
STR="$SPROJ/$SID_A.jsonl"; printf '{}\n' > "$STR"
SSUB="$SPROJ/$SID_A/subagents"
printf '{"name":"worker"}' > "$SSUB/agent-aworker-2222222222222222.meta.json"
printf '{}\n' > "$SSUB/agent-aworker-2222222222222222.jsonl"
cg_live "$STR" "worker"
cg_roster_row "$SREPO" "$SID_A" "worker" "aworker-2222222222222222" "" "identified"
write_plan "$SREPO/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"

# 1. the recorder, with the secret in the command line beside a real run
SOUT=$( cd "$SREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" worker 2>/dev/null )
mk_bash_post "$SID_A" "$STR" "$SREPO" \
  "export TOKEN=$SECRET && bash ~/.claude/hooks/stop-check.sh worker" "$SOUT" \
  | bash "$PARTY_ER" >/dev/null 2>&1
# 2. the start gate, with the secret in the dispatch description
jq -n --arg s "$SID_A" --arg c "$SREPO" --arg d "dispatch carrying $SECRET" \
  '{session_id:$s, transcript_path:"/x.jsonl", cwd:$c, hook_event_name:"PreToolUse",
    tool_name:"Agent", tool_input:{description:$d, subagent_type:"implementor"}}' \
  | bash "$PARTY_DP" >/dev/null 2>&1
# 3. the stop gate, with the secret as the typed target
mk_stop_payload "$SID_A" "$STR" "$SREPO" "$SECRET" | bash "$PARTY_SG" >/dev/null 2>&1
# 4. the producer, with the secret as the live credential
( cd "$SREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" ANTHROPIC_API_KEY="$SECRET" \
    HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
    bash "$PROBE" >/dev/null 2>&1 )
# 5. the observation, with the secret as the target it fails to resolve
( cd "$SREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" "$SECRET" >/dev/null 2>&1 )

LEAKS=$(grep -rlF "$SECRET" "$SREPO" "$SANDBOX/home" 2>/dev/null | grep -c . | tr -d ' ')

# The recorder DOES record the typed target — that is its contract — so the
# check above must not be passing merely because nothing was written at all.
expect_contains "…and the state file the sweep covered is genuinely populated" \
  "target=" "$(cat "$SREPO/.bionic/tmp/stop-check.state" 2>/dev/null)"

# Temp-name unpredictability, all four scripts (AC-8). Static pins first: the
# A2 defect was a literal `"${X}.tmp.$$"`.
for s in "$PROBE" "$OBSERVE" "$PARTY_DP" "$PARTY_SG" "$PARTY_ER"; do
  b=$(basename "$s")
  if grep -q 'mktemp' "$s"; then
    if grep -qE 'mktemp[^|&;]*XXXXXX' "$s"; then ok "$b: every mktemp carries an X-template"
    else no "$b: every mktemp carries an X-template"; fi
  fi
done

# Behavioural, not merely static: two recorder runs must produce two unrelated
# temp names. The instrumentation is applied to a COPY (§9's technique) so the
# shipped script carries no fault-injection seam; the original is re-checksummed.
ER_SUM_BEFORE=$(shasum "$PARTY_ER")
SGI="$(plant_hook_tree "$SANDBOX/er-showtmp")/execution-recorder-showtmp.sh"
awk '{ print }
     /^  tmp=\$\(mktemp "\$STATE_DIR\/\.stop-check\.XXXXXX" 2>\/dev\/null\)/ {
       print "  printf \"TMPNAME=%s\\n\" \"$tmp\" >&2" }' "$PARTY_ER" > "$SGI"
if cmp -s "$PARTY_ER" "$SGI"; then
  :
else
  N1=$(mk_bash_post "$SID_A" "$STR" "$SREPO" "bash ~/.claude/hooks/stop-check.sh worker" "$SOUT" \
       | bash "$SGI" 2>&1 >/dev/null | sed -n 's/^TMPNAME=//p' | head -1)
  N2=$(mk_bash_post "$SID_A" "$STR" "$SREPO" "bash ~/.claude/hooks/stop-check.sh worker" "$SOUT" \
       | bash "$SGI" 2>&1 >/dev/null | sed -n 's/^TMPNAME=//p' | head -1)
  if [ -n "$N1" ] && [ -n "$N2" ] && [ "$N1" != "$N2" ]; then
    ok "two recorder runs produce two different temp names"
  else
    no "two recorder runs produce two different temp names" "got '$N1' and '$N2'"
  fi
fi

# The components' repo footprint — the strongest form of "no artefact holds the
# command text". Snapshot the whole sandbox around a run.
#
# RESCOPED at epic-16 wave-02, not relaxed. The start gate stopped being read-only
# when R5 ("the environment probe auto-runs when needed") folded the attestation
# into the combined preflight: with no attestation on disk the gate now runs
# hooks/preflight-probe.sh inline, which creates its state directory and writes the
# session-keyed attestation, and the gate then journals the accepted dispatch to the
# session roster (wave-01 roster row, R8's "a refused dispatch leaves no row" read
# in the positive direction). Those three paths are the whole ratified set.
#
# The direction the pin now runs: an EXACT delta, never a blanket exclusion of
# .bionic/tmp. Three named paths may appear and a FOURTH entry of ANY kind — file
# or directory, inside .bionic/tmp or anywhere else — still goes RED. The security
# property this block exists for ("gates do not scribble in repos") therefore
# survives at full strength for everything unsanctioned; what changed is that the
# sanctioned set is enumerated instead of empty.
#
# The credential is PINNED rather than inherited. The probe's credential sources are
# $ANTHROPIC_API_KEY first and the machine's LOGIN KEYCHAIN third, so an unpinned
# drive lands on the refused path or the accepted one depending on whose machine
# runs the suite — and only the accepted path writes any file at all. Pinning it
# present is both hermetic and the stronger drive: it exercises the branch that
# actually creates the artefacts this assertion is here to bound. The value is a
# syntactic placeholder; the probe tests PRESENCE, never validity.
QREPO=$(new_repo "quiet")
write_plan "$QREPO/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"
before=$(find "$QREPO" | sort)
# `.bionic/tmp` is no longer among the gate's creations: the fixture arms the Patrol, which
# makes the directory before the gate runs (arm_patrol). What the gate adds is still exactly
# the attestation and the roster row.
expected_after=$(printf '%s\n%s\n%s\n' "$before" \
  "$QREPO/.bionic/tmp/preflight-$SID_A.state" \
  "$QREPO/.bionic/tmp/roster-$SID_A.state" | sort)
mk_agent_payload "$SID_A" "$QREPO" \
  | env ANTHROPIC_API_KEY="pinned-placeholder-not-a-credential" bash "$PARTY_DP" >/dev/null 2>&1
after_start=$(find "$QREPO" | sort)
expect_eq "the start gate writes ONLY the attestation, the roster row and their state dir" \
  "$expected_after" "$after_start"
# The observation stays read-only ABSOLUTELY — zero footprint, no sanctioned set at
# all. Compared against the POST-start listing rather than the pre-start one, so it
# answers for its own writes instead of inheriting the start gate's.
( cd "$QREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" nobody >/dev/null 2>&1 )

# ============================================================
section "E — classification + contract-source ride the machine line into the recorded observation (slice 4/5)"
# ============================================================
#
# hooks/stop-check.sh (producer) computes classification/deliverable_source/
# progress_source and prints them on its machine line; hooks/execution-recorder.sh
# (consumer) is supposed to copy them into the observation record verbatim,
# unparsed — the same "one computation, two renderings" property §D2 above pins
# for the file-facts fields. This section drives the REAL producer's REAL output
# into the REAL recorder over the §C fixture world, so a divergence between the
# two parsers (the F-1 shape this whole file exists to catch) shows up here
# rather than in two suites that never compare notes.
#
# Reuses the §C fixture world (RREPO/RPROJ/RTR/SID_A, the "worker" and "solo"
# agents already planted there) rather than building a new one, because the
# claim under test is agreement over ONE resolution, not a new resolver case.

cg_roster_row "$RREPO" "$SID_A" "worker" "aworker-7777777777777777"

# --- a target THIS session's roster records: OURS, end to end ---
E_OUT=$( cd "$RREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" worker 2>&1 )
E_MLINE=$(printf '%s\n' "$E_OUT" | grep '^stop-check-observation/')
expect_contains "the machine line carries classification=ours" "classification=ours" "$E_MLINE"

mk_bash_post "$SID_A" "$RTR" "$RREPO" "bash ~/.claude/hooks/stop-check.sh worker" "$E_OUT" \
  | bash "$PARTY_ER" >/dev/null 2>&1
E_STATE=$(cat "$RREPO/.bionic/tmp/stop-check.state" 2>/dev/null)
expect_contains "the recorded observation agrees: classification=ours" \
  "classification=ours" "$E_STATE"
expect_contains "the recorded observation carries deliverable_source=none (no CLI arg, no roster deliverable)" \
  "deliverable_source=none" "$E_STATE"
expect_contains "the recorded observation carries progress_source=none" "progress_source=none" "$E_STATE"

# --- an UNROSTERED target under this session's OWN directory: OURS, because the
# metadata's own filing is what ownership reads (slice 4/9). Before that fix this
# classified foreign, of an agent this session had launched — the live defect, and
# the standing state for everything dispatched before the roster hook shipped. ---
plant "$RPROJ/$SID_A/subagents" "aloner-9999999999999999" "loner"
E3_OUT=$( cd "$RREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" loner 2>&1 )
E3_MLINE=$(printf '%s\n' "$E3_OUT" | grep '^stop-check-observation/')
expect_contains "an unrostered target under this session's own directory classifies OURS" \
  "|classification=ours|" "$E3_MLINE"

mk_bash_post "$SID_A" "$RTR" "$RREPO" "bash ~/.claude/hooks/stop-check.sh loner" "$E3_OUT" \
  | bash "$PARTY_ER" >/dev/null 2>&1
E3_STATE=$(cat "$RREPO/.bionic/tmp/stop-check.state" 2>/dev/null)
expect_contains "the recorder forwards that classification into the record" \
  "|classification=ours|" "$E3_STATE"

# --- and the not-ours direction, on the shape that really produced it: a target filed under
# ANOTHER session's directory, carrying a name this session's roster also carries on an
# UNCONFIRMED row. The row must grant nothing — and since S6 neither does the directory. The
# answer is no longer a CLASSIFICATION that rides into the record; it is a refusal, so the
# thing this suite pins is that the producer showed no evidence tier and the recorder
# therefore has nothing to copy. That is a stronger agreement than a shared label: there is
# no second reading of it to drift. ---
plant "$RPROJ/$SID_B/subagents" "acorpse-aaaaaaaaaaaaaaaa" "corpse"
cg_roster_row "$RREPO" "$SID_A" "corpse" "" "" intended
E5_OUT=$( cd "$RREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" corpse 2>&1 )
E5_MLINE=$(printf '%s\n' "$E5_OUT" | grep '^stop-check-observation/')
expect_contains "an unconfirmed row's NAME does not make another session's agent ours" \
  "Resolved:      not live" "$E5_OUT"
expect_eq "the recorder is given nothing to forward, because no tier was shown" \
  "" "$E5_MLINE"

# --- with no own session id at all there is no transcript, so no live set: the producer
# refuses instead of labelling, and the recorder still copies exactly what it was given. The
# `unknown` classification this pair used to assert was the label for "ownership could not be
# established", and ownership is no longer a thing this command decides. ---
E4_OUT=$( cd "$RREPO" && env -u CLAUDE_CODE_SESSION_ID bash "$OBSERVE" worker 2>&1 )
E4_MLINE=$(printf '%s\n' "$E4_OUT" | grep '^stop-check-observation/')
expect_contains "with no own session id the producer refuses, naming the fix" \
  "call ListAgents" "$E4_OUT"
expect_eq "…and prints no machine line at all" "" "$E4_MLINE"
rm -f "$RREPO/.bionic/tmp/stop-check.state"
mk_bash_post "$SID_A" "$RTR" "$RREPO" "bash ~/.claude/hooks/stop-check.sh worker" "$E4_OUT" \
  | bash "$PARTY_ER" >/dev/null 2>&1
E4_STATE=$(cat "$RREPO/.bionic/tmp/stop-check.state" 2>/dev/null)
expect_absent "the recorder writes no record for a run that showed no evidence" \
  "typed=worker|log=" "$E4_STATE"

# ============================================================
section "F — the roster row and the observer/progress fields: writer, producer and GATE agree (slice 4/6)"
# ============================================================
#
# Slice 4/6 turned the stop gate into a reader of four things it had never read:
# the session roster's `name=`/`agent_id=` (the foreign-stop rule), and the
# record's `observer=`, `progress=`/`progress_mtime=`/`progress_state=` (the
# same-actor and progress-staleness checks). Every one of them is written by one
# script and read by another, which is this suite's whole subject — a field whose
# producer and consumer drift apart fails silently and in the OPEN direction (the
# gate simply stops finding what it is looking for).
#
# The roster row here is the one hooks/dispatch-preflight.sh REALLY WROTE in
# section B, from the real brief in mk_agent_payload — not a fixture. So the
# chain driven below is writer → producer → recorder → gate, end to end, over one
# row.

ROSTER_F="$IREPO/.bionic/tmp/roster-$SID_A.state"
expect_contains "the start gate really journalled the dispatch (section B's own row)" \
  "name=w99-impl" "$(cat "$ROSTER_F" 2>/dev/null)"
expect_contains "…carrying the progress path lifted from the brief" \
  "progress=.bionic/tmp/w99.progress" "$(cat "$ROSTER_F" 2>/dev/null)"

# The agent that row describes, now spawned. Its id is what a confirmed row would
# carry; the row itself is still `intended`, which is the mid-dispatch state the
# NAME fallback exists for.
plant "$ISUB" "aw99impl-8888888888888888" "w99-impl" "$IREPO"
printf 'stage 1\n' > "$IREPO/.bionic/tmp/w99.progress"

F_OUT=$( cd "$IREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" w99-impl 2>&1 )
F_MLINE=$(printf '%s\n' "$F_OUT" | grep '^stop-check-observation/')
expect_contains "…and takes the contracted progress path from it" \
  "progress=.bionic/tmp/w99.progress" "$F_MLINE"
expect_contains "…recording where the contract came from" "progress_source=roster" "$F_MLINE"
expect_contains "…and the state it found the artifact in" "progress_state=present" "$F_MLINE"

mk_bash_post "$SID_A" "$ITR" "$IREPO" "bash ~/.claude/hooks/stop-check.sh w99-impl" "$F_OUT" \
  | bash "$PARTY_ER" >/dev/null 2>&1
F_STATE=$(cat "$IREPO/.bionic/tmp/stop-check.state" 2>/dev/null)
expect_contains "the recorder copies the progress path into the record verbatim" \
  "progress=.bionic/tmp/w99.progress" "$F_STATE"
expect_contains "…and the progress state beside it" "progress_state=present" "$F_STATE"
expect_contains "…and the observer, which only it can see" "observer=orchestrator" "$F_STATE"

# The gate now reads that record. Same row, same path, same answer: nothing has
# moved, so the stop stands.
ST=$(mk_stop_payload "$SID_A" "$ITR" "$IREPO" "w99-impl" | bash "$PARTY_SG" >/dev/null 2>&1; echo $?)
expect_eq "the gate agrees the target is OURS and spends the record" "0" "$ST"

# …and a write to THAT path — the one the writer named, the producer resolved and
# the recorder stored — is what the gate calls stale. A disagreement anywhere in
# that chain shows up here as a stop that quietly stays permitted.
F2_OUT=$( cd "$IREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" w99-impl 2>&1 )
mk_bash_post "$SID_A" "$ITR" "$IREPO" "bash ~/.claude/hooks/stop-check.sh w99-impl" "$F2_OUT" \
  | bash "$PARTY_ER" >/dev/null 2>&1
sleep 1
printf 'stage 2\n' >> "$IREPO/.bionic/tmp/w99.progress"
OUT=$(mk_stop_payload "$SID_A" "$ITR" "$IREPO" "w99-impl" | bash "$PARTY_SG" 2>&1); ST=$?
expect_eq "a write to the roster-contracted progress path stales the look" "2" "$ST"

# THE SAME CHAIN, WITH THE ROSTER LONG (Step-6 critic F-1). The shipped
# performance remediation capped the roster at 200 rows and evicted by RECENCY,
# which knows nothing about whether the evicted row belongs to an agent that is
# still running. A live agent's row is the only copy of its contract, and the
# refusal just proven above is sourced from it — so past the cap the wall did not
# weaken, it disappeared: `record/w3-critic-repro-cap.sh` measured the identical
# sequence as exit 2 under the cap and exit 0 over it, with the operator shown
# `progress=(none recorded)`, indistinguishable from a brief that declared none.
#
# This is the row that failed. It belongs in THIS suite rather than the
# recorder's own, because the property is cross-script: the file the recorder
# writes is the file the gate reads, and the recorder alone cannot see that
# dropping a row disarms another program. `tests/execution-recorder.test.sh`
# asserted only that the row THIS event confirmed survived the fold, which is why
# 110/110 was green over the defect.
F4_ROSTER="$IREPO/.bionic/tmp/roster-$SID_A.state"
F4_BEFORE=$(grep -c "^${ROSTER_ROW_SCHEMA}|" "$F4_ROSTER" 2>/dev/null || echo 0)
{
  _i=0
  while [ "$_i" -lt 260 ]; do
    roster_row_fixture status=confirmed session="$SID_A" name="old-$_i" \
      agent_id="aold-$_i" launched_at=2026-08-05T00:00:00Z tool_use_id="toolu_OLD$_i"
    _i=$((_i + 1))
  done
} >> "$F4_ROSTER"

# A SECOND dispatch, journalled by the REAL start gate, whose completion is the
# event that used to rewrite the file. The live agent's row is the OLDEST in it,
# which is exactly the position eviction-by-recency takes first.
mk_agent_payload "$SID_A" "$IREPO" \
  | jq '.tool_input.name = "w99-other" | .tool_use_id = "toolu_OTHERDISPATCH"' \
  | bash "$PARTY_DP" >/dev/null 2>&1
mk_agent_post "$SID_A" "$ITR" "$IREPO" "toolu_OTHERDISPATCH" "w99-other" \
  | bash "$PARTY_ER" >/dev/null 2>&1
expect_contains "the other dispatch's completion is journalled" \
  "agent_id=a26bd30bf8616411b" "$(grep 'status=confirmed|.*name=w99-other|' "$F4_ROSTER" 2>/dev/null)"
expect_eq "no row is evicted to make room for it (append-only, unbounded)" \
  "$((F4_BEFORE + 262))" "$(grep -c "^${ROSTER_ROW_SCHEMA}|" "$F4_ROSTER" 2>/dev/null || echo 0)"
# Both of these read the ROW, never the file. Scoping is load-bearing twice over:
# the second dispatch above carries the same brief, so a file-wide grep for the
# contract would stay green with the live row gone — and `expect_contains` cannot
# be trusted on a haystack this size at all. It is `printf | grep -qF` under
# `pipefail`, so a match near the TOP of a 68 KB haystack makes grep exit before
# printf finishes, printf takes SIGPIPE, and the pipeline returns 141: a FALSE
# FAIL on a string that is present. Verified in isolation — same haystack, early
# match 141, late match 0, and 0 with pipefail off. It fails safe (red, not
# green) and it is not this slice's to fix in six suites at once, but it is why
# nothing here hands a whole roster to an assertion.
F4_LIVE_ROW=$(grep 'name=w99-impl|' "$F4_ROSTER" 2>/dev/null)
expect_contains "the LIVE agent's row survives a long session" \
  "name=w99-impl" "$F4_LIVE_ROW"
expect_contains "…carrying the contract state that is its only copy" \
  "progress=.bionic/tmp/w99.progress" "$F4_LIVE_ROW"

# …and the wall that hangs off that row still fires. Same three steps as the
# refusal above — observe, the agent writes, stop — with nothing different but
# the length of the file.
F4_OUT=$( cd "$IREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" w99-impl 2>&1 )
expect_contains "the producer still reads the contract off the long roster" \
  "progress_source=roster" "$(printf '%s\n' "$F4_OUT" | grep '^stop-check-observation/')"
mk_bash_post "$SID_A" "$ITR" "$IREPO" "bash ~/.claude/hooks/stop-check.sh w99-impl" "$F4_OUT" \
  | bash "$PARTY_ER" >/dev/null 2>&1
sleep 1
printf 'stage 3\n' >> "$IREPO/.bionic/tmp/w99.progress"
OUT=$(mk_stop_payload "$SID_A" "$ITR" "$IREPO" "w99-impl" | bash "$PARTY_SG" 2>&1); ST=$?
expect_eq "the D-6 staleness wall still refuses past the old cap (critic F-1)" "2" "$ST"

# THE OBSERVER FIELD, both ends. The recorder learns who looked from its own
# payload's top-level `agent_id` (absent = the orchestrator); the gate learns who
# is stopping from ITS payload's identical field. One key, two payloads.
F3_OUT=$( cd "$IREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" w99-impl 2>&1 )
mk_bash_post "$SID_A" "$ITR" "$IREPO" "bash ~/.claude/hooks/stop-check.sh w99-impl" "$F3_OUT" \
  | jq '. + {agent_id:"asubagent-2020202020202020", agent_type:"general-purpose"}' \
  | bash "$PARTY_ER" >/dev/null 2>&1
expect_contains "a subagent-invoked observation records that subagent as observer" \
  "observer=asubagent-2020202020202020" "$(cat "$IREPO/.bionic/tmp/stop-check.state" 2>/dev/null)"
OUT=$(mk_stop_payload "$SID_A" "$ITR" "$IREPO" "w99-impl" | bash "$PARTY_SG" 2>&1); ST=$?
expect_eq "the orchestrator cannot spend a subagent's look" "2" "$ST"
OUT=$(mk_stop_payload "$SID_A" "$ITR" "$IREPO" "w99-impl" \
      | jq '. + {agent_id:"asubagent-2020202020202020", agent_type:"general-purpose"}' \
      | bash "$PARTY_SG" 2>&1); ST=$?
expect_eq "the subagent that looked can" "0" "$ST"

# The field NAMES themselves, stated as the agreement they are — so a rename
# breaks this suite with a legible reason rather than turning a wall inert.

# ============================================================
section "G — the roster FILENAME is one pattern with five sites (6-axis D-1)"
# ============================================================
#
# `roster-<session-id>.state` under `.bionic/tmp/` is constructed independently in
# five places: hooks/dispatch-preflight.sh (the writer, via ROSTER_PREFIX/SUFFIX),
# hooks/preflight-probe.sh (a declared reader copy of the same two constants), and
# BARE LITERALS in hooks/execution-recorder.sh, hooks/stop-guard.sh and
# hooks/stop-check.sh. The spec's ownership table named no owner for it, and the
# only cross-surface guard was a substring grep for `roster-` in the gate's source
# — which a change to the SUFFIX, or to the directory, passes untouched.
#
# So the pattern is driven, not grepped: the writer writes at the canonical path,
# each reader is shown finding it there, and the same file at a MUTATED name is
# found by NONE of them. The mutation is what makes this an agreement test rather
# than a restatement — a suffix change goes red here in four places at once.
G_ROSTER="$IREPO/.bionic/tmp/roster-$SID_A.state"
G_MUTANT="$IREPO/.bionic/tmp/roster-$SID_A.txt"

# READER 1 — the recorder's completion arm. At the canonical name a dispatch's
# `intended` row reaches `confirmed`; at any other name there is no row to
# complete and none is invented.
g_confirm() {  # -> the confirmed row, if any
  jq -n --arg s "$SID_A" --arg t "$ITR" --arg c "$IREPO" \
    '{session_id:$s, transcript_path:$t, cwd:$c, hook_event_name:"PostToolUse",
      tool_name:"Agent",
      tool_input:{description:"a dispatch", prompt:"go", subagent_type:"implementor",
                  name:"w99-impl", run_in_background:true},
      tool_response:{isAsync:true, status:"async_launched", agentId:"ag99confirm-5555555555",
                     description:"a dispatch"},
      tool_use_id:"toolu_018jyjgop7KMxP6yKtoAWWtB"}' \
    | bash "$PARTY_ER" >/dev/null 2>&1
  grep 'agent_id=ag99confirm-5555555555' "$G_ROSTER" 2>/dev/null
}
mv "$G_ROSTER" "$G_MUTANT"
g_confirm >/dev/null 2>&1
mv "$G_MUTANT" "$G_ROSTER"
expect_contains "the recorder completes the row at the canonical filename" \
  "status=confirmed" "$(g_confirm)"

# READER 2 — the observation. Its contract source is the roster; at any other
# filename the same look reports no contract at all.
g_progress_source() {
  ( cd "$IREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" w99-impl 2>&1 ) \
    | grep '^stop-check-observation/' | tr '|' '\n' | grep '^progress_source=' | cut -d= -f2-
}
expect_eq "the observation takes its contract from the canonical roster" \
  "roster" "$(g_progress_source)"
mv "$G_ROSTER" "$G_MUTANT"
# At any other name the observation shows NOTHING — a stronger form of the same pin than the
# `progress_source=none` it used to print. Since S6 the roster is also where the agent id
# comes from, so a roster the reader cannot find leaves it without a working log to look at,
# and a run that shows no evidence tier prints no machine line at all.
expect_eq "…and finds no contract, and nothing else either, when the roster is named anything else" \
  "" "$(g_progress_source)"
mv "$G_MUTANT" "$G_ROSTER"

# READER 3 — the stop gate, over the same rename. With the roster at its canonical name the
# whole chain closes: the look resolves through the row, the recorder stores it and the gate
# spends it. At any other name neither party can identify the target, and the gate refuses.
# (The D-6 channel-blind refusal this leg used to drive lives in tests/stop-guard.test.sh §9,
# where a look taken BEFORE the contract was recorded is what makes a look channel-blind now
# — an observation with no session key cannot reach a live set and produces no record at all.)
g_stop_reason() {  # -> which refusal the gate reaches for an unobserved target
  local out
  rm -f "$IREPO/.bionic/tmp/stop-check.state"
  out=$(mk_stop_payload "$SID_A" "$ITR" "$IREPO" "w99-impl" | bash "$PARTY_SG" 2>&1)
  case "$out" in
    *"carries no agent id"*) echo unidentified ;;
    *"No observation"*)      echo identified ;;
    *)                       echo "other" ;;
  esac
}
expect_eq "the stop gate identifies its target through the canonical roster" \
  "identified" "$(g_stop_reason)"
mv "$G_ROSTER" "$G_MUTANT"
expect_eq "…and cannot identify it at all when the roster is named anything else" \
  "unidentified" "$(g_stop_reason)"
mv "$G_MUTANT" "$G_ROSTER"

# READER 4 — the probe's roster coverage, which scans OTHER live sessions' roster
# files by the same pattern.
printf '{}\n' > "$IPROJ/$SID_B.jsonl"
G_ROSTER_B="$IREPO/.bionic/tmp/roster-$SID_B.state"
cp "$G_ROSTER" "$G_ROSTER_B"
g_probe_roster() {
  ( cd "$IREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" ANTHROPIC_API_KEY="sk-fixture-not-a-real-key" \
      HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" bash "$PROBE" 2>&1 ) \
    | grep -F "another live session on this project: $SID_B"
}
expect_contains "the probe finds another session's roster at the canonical filename" \
  "roster: present" "$(g_probe_roster)"
mv "$G_ROSTER_B" "$IREPO/.bionic/tmp/roster-$SID_B.txt"
expect_contains "…and reports absent for the same file under any other name" \
  "roster: absent" "$(g_probe_roster)"
rm -f "$IREPO/.bionic/tmp/roster-$SID_B.txt" "$IPROJ/$SID_B.jsonl"

# Both halves of the name, spelled by all five sites — so a rename of either half
# fails with a legible reason rather than silently halving the fleet's view.
for _party in "$PARTY_DP" "$PROBE" "$PARTY_ER" "$PARTY_SG" "$OBSERVE"; do
  _src=$(cat "$_party")
  expect_contains "$(basename "$_party") spells the roster filename prefix" "roster-" "$_src"
done

# ============================================================
section "H — the LIVENESS fields: writer lifts them, the observation displays them (6-axis A-1)"
# ============================================================
#
# The axis-3 FAIL: hooks/stop-check.sh read `claims=` off the roster row and NO
# writer emitted it, while slice 4/7 shipped procedure prose instructing authors
# to declare both a `cadence` and a subprocess claim. A reader with no producer is
# dead substrate, and the only test exercising it hand-wrote a row shape the
# writer could not produce. Here the row is the one the real start gate wrote from
# a real brief, and the real observation is run over it.

H_BRIEF='Canonical-sdlc Step 4, slice 4/13 of epic-99 wave-01; build · audited · wave.
Expected artifact: .bionic/docs/record/w99-live.txt
Expected duration: ~45 minutes. Progress: .bionic/tmp/w99-live.progress, cadence ~7m.
Subprocess claim: `w99-suite-marker` → .bionic/tmp/w99-live.log
Exit condition: the artifact exists.
Suites: tests/widget.test.sh'
plant "$ISUB" "aw99live-9999999999999999" "w99-live"
jq -n --arg s "$SID_A" --arg c "$IREPO" --arg p "$H_BRIEF" \
  '{session_id:$s, transcript_path:"/irrelevant.jsonl", cwd:$c,
    permission_mode:"bypassPermissions", hook_event_name:"PreToolUse", tool_name:"Agent",
    tool_input:{description:"a liveness dispatch", subagent_type:"implementor",
                name:"w99-live", prompt:$p},
    tool_use_id:"toolu_01LIVENESS"}' \
  | bash "$PARTY_DP" >/dev/null 2>&1
H_ROW=$(grep 'name=w99-live' "$G_ROSTER" 2>/dev/null | tail -1)
expect_contains "the writer lifted the subprocess claim's pattern into the row" \
  "claims=w99-suite-marker" "$H_ROW"
expect_contains "the writer lifted the cadence declared beside the progress path" \
  "cadence=~7m." "$H_ROW"

# The field NAMES, both ends — a rename fails here rather than turning the
# display silently blank, which is how this defect shipped in the first place.
expect_contains "the observation reads that same key" 'line_field "$ROSTER_ROW" claims' "$(cat "$OBSERVE")"
expect_contains "the observation reads that same key" 'line_field "$ROSTER_ROW" cadence' "$(cat "$OBSERVE")"

# ============================================================
section "I — DONE-DETECTION, and the primitives the sweeper says it copied (6-axis D-2, R-1)"
# ============================================================
#
# hooks/session-sweeper.sh's own header declares four functions "DELIBERATELY DUPLICATED
# from hooks/stop-check.sh, byte for byte… held together by the cross-gate agreement
# suite". Until this section existed that last clause was false: nothing here compared a
# single copy, so the comment named a guardrail the next reader would trust and the copies
# could drift silently (6-axis R-1). Below it is true.
#
# The heavier half is D-2. "Is this roster row's deliverable delivered?" has TWO owners and
# they answered differently on the same input. Both answers are asked here of the REAL
# scripts on ONE set of fixtures, and compared to each other rather than only to a literal —
# which is what goes red on the next divergence, whichever side moves.
#
# THE SWEEPER SIDE MOVED IN epic-16 wave-02, and this section moved with it. The sweeper
# used to answer through its watch loop: a row whose declared deliverables were all present
# was SATISFIED, dropped from watching, never woken on, and the loose `[ -s <dir> ]` reading
# behind that was the original defect (true for an EMPTY directory on both BSD and GNU, so a
# freshly-created directory read as landed work). The loop and its satisfied-check are
# deleted. The sweeper is still an owner of this question — through `verdict`, which is now
# its ONLY delivered-predicate — so the pairing is preserved and re-asked against that verb
# rather than dropped with the loop.

# --- I.1 the copied primitives ---
# BODIES are compared, not whole definitions: each file explains its copy in its own terms,
# so the signature comments legitimately differ and only the executable text must not.
fn_body() {  # <file> <function name> -> the function's body, signature and its comment stripped
  awk -v n="$2" '
    !f && index($0, n "()") == 1 {
      f = 1; line = $0
      sub(/^[^{]*\{/, "", line)
      sub(/^[[:space:]]*#.*$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line != "") print line
      if (line ~ /\}$/) exit
      next
    }
    f { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; if ($0 == "}") exit }
  ' "$1"
}

for _fn in file_mtime line_field claims_live; do
  expect_eq "the sweeper's ${_fn}() is the stop gate's, body for body" \
    "$(fn_body "$OBSERVE" "$_fn")" "$(fn_body "$SWEEPER" "$_fn")"
done
# Same body, different name: the sweeper normalizes its findings exactly as the stop gate
# normalizes its machine line, and says so in its comment.

# THE COPY COUNT WAS FIVE, NOT TWO (t6-review.md F-5): execution-recorder.sh's own
# line_field() sat outside this section entirely, and landing-gate.sh's own by-key reader
# was PINNED NOWHERE — it is the fifth copy and the one this wave added. Its signature is a
# genuinely different SHAPE (one argument, reading a global $LINE rather than taking the
# line as a parameter, because every candidate in its sweep loop already lives in that
# variable) — a byte comparison would be comparing apples to a legitimate shape change, so
# this half is BEHAVIOURAL: the same synthetic roster line, asked for the same key by all
# FIVE extractors (three literally named line_field, one named record_field, one shaped as
# _field), each run from ITS OWN file in its own subshell — the same precedent §N.2 uses for
# resolve_project_root — so five same-named definitions never shadow each other and the real
# pipeline is what answers, never a hand-copied stand-in.

field2_via() {  # <file> <fn-name> <line> <key> -> a <line> <key> extractor, real source, real call
  local f="$1" n="$2" line="$3" key="$4"
  ( eval "$(awk -v n="$n" '$0 ~ "^" n "\\(\\)" {f=1} f{print; if ($0=="}") exit}' "$f")"
    "$n" "$line" "$key" ) 2>/dev/null
}
field1_via() {  # <file> <line> <key> -> landing-gate.sh's ONE-argument _field(), real source
  local f="$1" line="$2" key="$3"
  ( eval "$(awk '/^_field\(\)/,/^\}/' "$f")"
    LINE="$line" _field "$key" ) 2>/dev/null
}

# DELIBERATELY NOT A ROW (and so not `roster_row_fixture`'s to build): it carries a
# `state=` key no writer emits, because what is under test is `line_field`'s by-key
# extraction, not the row. Only the schema token comes off the writer.
I1_LINE="${ROSTER_ROW_SCHEMA}|status=confirmed|name=w4-i1|agent_id=ai1test0000000000|deliverable=.bionic/docs/record/i1.md|state=UNMET"
for _key in status name agent_id deliverable state; do
  I1_WANT=$(field2_via "$SWEEPER" line_field "$I1_LINE" "$_key")
  expect_eq "…and stop-check's line_field(${_key}), called for real, agrees" \
    "$I1_WANT" "$(field2_via "$OBSERVE" line_field "$I1_LINE" "$_key")"
done

# THE DISCRIMINATING HALF: a copy of landing-gate.sh with the anchor dropped from _field()'s
# grep — the plausible drift where "asked for the FIELD" turns into an unanchored SUBSTRING
# match. A decoy field (`prev_status=`) that carries the real key as a substring is what
# makes the unanchored pattern answer wrong instead of merely reading identically anyway.
I1_MUT_DIR="$SANDBOX/fx/i1-unanchored"
mkdir -p "$I1_MUT_DIR"
awk '{ sub(/grep "\^\$1="/, "grep \"$1=\""); print }' "$PARTY_LG" > "$I1_MUT_DIR/landing-gate.sh"
I1_DECOY="${ROSTER_ROW_SCHEMA}|prev_status=confirmed|status=UNMET"

# --- I.2 done-detection: one concept, two implementations, one answer ---

DREPO=$(new_repo "done-detection")
DSLUG=$(printf '%s' "$DREPO" | sed 's/[^a-zA-Z0-9]/-/g')
DPROJ="$CLAUDE_CONFIG_DIR/projects/$DSLUG"
mkdir -p "$DPROJ/$SID_A/subagents"
printf '{}\n' > "$DPROJ/$SID_A.jsonl"
plant "$DPROJ/$SID_A/subagents" "adeliv-2222222222222222" "deliv" "$DREPO"

DFX="$DREPO/deliv"
mkdir -p "$DFX/empty-dir" "$DFX/full-dir"
: > "$DFX/empty-file.md"
echo "the report"   > "$DFX/full-file.md"
echo "the report"   > "$DFX/full-dir/one.md"
echo "the report"   > "$DREPO/relative-target.md"
# An hour back, so every fixture written above is NEWER than the launch and the landing
# predicate's staleness conjunct is satisfied for all of them. Staleness is a NAMED
# divergence between these two owners (the stop gate never dates the artifact at all), and
# it is pinned separately below rather than smuggled into every row here.
D_LAUNCHED=$(date -u -v-3600S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "-3600 seconds" +%Y-%m-%dT%H:%M:%SZ)

DROSTER="$DREPO/.bionic/tmp/roster-$SID_A.state"
mkdir -p "$DREPO/.bionic/tmp"
roster_header > "$DROSTER"
# The agent's own row, re-planted because the header write above truncates the file: since S6
# the observation takes the agent id — and therefore the working log — off this row, and every
# `d_row` below is a CONTRACT row named for its case rather than for the agent.
roster_identify "$DREPO" "$SID_A" "deliv" "adeliv-2222222222222222"
d_row() {  # <name> <deliverable value>
  roster_row_fixture status=confirmed session="$SID_A" name="$1" \
    agent_id=adeliv-2222222222222222 launched_at="$D_LAUNCHED" deliverable="$2" \
    duration="1 minute" tool_use_id="toolu_01$1" >> "$DROSTER"
}

# The stop gate's answer, read off the evidence it prints for a human rather than off a
# reimplementation of its branches here.
sc_answer() {  # <path as typed> -> delivered|not-delivered
  local out
  out=$( cd "$DREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" deliv "$1" 2>&1 )
  case "$out" in
    *"${1} — PRESENT as a directory, 0 file(s)"*) echo not-delivered ;;
    *"${1} — PRESENT as a directory,"*)           echo delivered ;;
    *"${1} — PRESENT but EMPTY"*)                 echo not-delivered ;;
    *"${1} — PRESENT,"*)                          echo delivered ;;
    *"${1} — ABSENT"*)                            echo not-delivered ;;
    *) echo "other" ;;
  esac
}

# The sweeper's answer, read off the state its ONE surviving predicate computes. MET is
# delivered; anything else is not. The row carries no claims and no progress, so STILL-LIVE
# cannot mask a failure to deliver — the state is the predicate's answer and nothing else.
sw_answer() {  # <row name> -> delivered|not-delivered
  local st
  st=$( cd "$DREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SWEEPER" verdict "$1" 2>/dev/null \
        | grep -F 'landing-verdict/v1|' | grep -F "|name=$1|" | head -1 \
        | tr '|' '\n' | grep '^state=' | head -1 | cut -d= -f2- )
  [ "$st" = "MET" ] && echo delivered || echo not-delivered
}

agree_on() {  # <label> <row name> <path as typed> <the right answer>
  local sc sw
  d_row "$2" "$3"
  sc=$(sc_answer "$3"); sw=$(sw_answer "$2")
  expect_eq "$1: the stop gate answers $4" "$4" "$sc"
  expect_eq "$1: the sweeper gives the stop gate's answer" "$sc" "$sw"
}

agree_on "a written file"        wfile "$DFX/full-file.md"  delivered
agree_on "an empty file"         efile "$DFX/empty-file.md" not-delivered
agree_on "an absent path"        nofile "$DFX/never.md"     not-delivered
agree_on "an EMPTY directory"    edir  "$DFX/empty-dir"     not-delivered
agree_on "a populated directory" fdir  "$DFX/full-dir"      delivered
# A repo-relative path, asked from the repo root — which is where the roster's own paths are
# written from, and the one place the two owners resolve it identically (the sweeper reads
# it against the REPO, the stop gate against the operator's typed cwd).
agree_on "a repo-relative path, asked from the repo root" relrow "relative-target.md" delivered

# THE NAMED DIVERGENCES, pinned as INEQUALITIES rather than left for the next reader to
# discover. These are the cases where the two owners are SUPPOSED to disagree, and a suite
# that only asserted agreement would go green on a drift that collapsed one into the other.
#
# SYMLINKS (Step-6 security review S-3). The stop gate follows a link on its file branch;
# the landing predicate refuses one on BOTH branches, because a contract satisfied by
# `ln -s` is satisfied with zero bytes written.
ln -s "$DFX/full-file.md" "$DFX/linked-file.md"
d_row linkrow "$DFX/linked-file.md"
expect_eq "a symlink to a written file: the stop gate reads it as delivered" \
  "delivered" "$(sc_answer "$DFX/linked-file.md")"

# STALENESS. The landing predicate requires an mtime AFTER the row's own launched_at; the
# stop gate does not date the artifact at all. Same file, same moment, two answers.
echo "written before this agent was ever dispatched" > "$DFX/prelaunch.md"
touch -t 202001010000 "$DFX/prelaunch.md"
d_row stalerow "$DFX/prelaunch.md"
expect_eq "a PRE-LAUNCH file: the stop gate reads it as delivered (it never dates it)" \
  "delivered" "$(sc_answer "$DFX/prelaunch.md")"

# ============================================================
section "J — THE LANDING CONTRACT: the gate refuses exactly when the verdict says UNMET"
# ============================================================
#
# epic-16 wave-01 split one answer across two scripts on purpose.
# hooks/session-sweeper.sh's `verdict` verb OWNS the delivered predicate (spec
# §Design ownership table); hooks/landing-gate.sh consumes it on SubagentStop and
# refuses the stop when it reads UNMET. The gate holds NO copy of the predicate —
# "a third copy of the delivered predicate in the landing gate" is a rejected
# alternative in the spec — so the property worth driving here is not whether the
# gate stats a file correctly, which it never does. It is AGREEMENT: over one
# roster and one set of artifacts, the gate refuses a stop if and only if the verb
# an orchestrator runs by hand says that contract is UNMET. Two people asking the
# same question about the same agent must not get two answers.
#
# THE ASYMMETRY IS THE SUBJECT, and both directions are asserted rather than
# assumed. §J.2 shows that only a change to the GATE can split the two answers,
# and §J.3 shows that a change to the PREDICATE moves both together. That is what
# having one owner buys operationally, and it is the claim this section keeps true.

JREPO=$(new_repo "landing-contract")
write_plan "$JREPO/.bionic/docs/plans/epic-16/wave-01.md" "current: 4"
JDELIV="$JREPO/deliv"
mkdir -p "$JDELIV" "$JREPO/.bionic/tmp"
JROSTER="$JREPO/.bionic/tmp/roster-$SID_A.state"
J_LAUNCHED=$(date -u -v-3600S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "-3600 seconds" +%Y-%m-%dT%H:%M:%SZ)

# Roster rows in the shape hooks/dispatch-preflight.sh's `ROW=` line really writes
# TODAY — field for field, including `source=` (slice 4/4) and `waiver=` (the
# absent-deliverable wall). A fixture missing a field the writer emits is how a
# suite ends up green over a row shape nothing produces; the sweeper's and the
# recorder's suites each had to make this same correction mid-wave.
#
# `agent_id=` is filled here because it is the SWEEP's join key (epic-16 wave-03, T4c): a
# row whose id is absent from the Stop payload's `background_tasks[]` has landed and is
# judged, and one still listed there is skipped. The rest of the row is the writer's own.
jrow() {  # <name> <deliverable> <progress> <cadence> <waiver> [tool_use_id]
  roster_row_fixture status=confirmed session="$SID_A" name="$1" agent_id="a-$1" \
    launched_at="$J_LAUNCHED" deliverable="$2" progress="$3" cadence="$4" waiver="$5" \
    tool_use_id="${6:-toolu_01LANDING}" >> "$JROSTER"
}

roster_header > "$JROSTER"
echo "the report" > "$JDELIV/met.md"
: > "$JDELIV/empty.md"
echo "written before the agent was ever dispatched" > "$JDELIV/stale.md"
touch -t 202001010000 "$JDELIV/stale.md"
printf 'stage 1\n' > "$JREPO/.bionic/tmp/live.progress"

ln -s "$JDELIV/met.md" "$JDELIV/linked.md"

jrow met    "$JDELIV/met.md"   ""                                    ""     ""
jrow unmet  "$JDELIV/never.md" ""                                    ""     ""
jrow empty  "$JDELIV/empty.md" ""                                    ""     ""
jrow stale  "$JDELIV/stale.md" ""                                    ""     ""
jrow live   "$JDELIV/never.md" "$JREPO/.bionic/tmp/live.progress"    "~5m"  ""
# A GENUINE waiver names no artifact — the wall's own label reads "why this dispatch
# produces nothing durable" (Step-6 review S-1). The row below it is the contradictory
# shape: a declared artifact AND a waiver, which one line of quoted documentation in a
# brief used to produce, and which used to silence the contract entirely.
jrow waived ""                 ""                                    ""     "this dispatch produces nothing durable"
jrow quoter "$JDELIV/never.md" ""                                    ""     "<why this dispatch produces nothing durable>"
# The symlink half of S-3: a contract satisfied by `ln -s` is satisfied with zero bytes
# written, so the landing predicate refuses it and the gate refuses the stop.
jrow linked "$JDELIV/linked.md" ""                                   ""     ""
# C-2: two dispatches share a name, so the fold cannot tell whose contract is whose. The
# verb says AMBIGUOUS and the gate passes — a stop let through is recoverable, the wrong
# agent blocked is not.
jrow dup    "$JDELIV/met.md"   ""                                    ""     ""     toolu_01DUPA
jrow dup    "$JDELIV/never.md" ""                                    ""     ""     toolu_01DUPB

# The battery's baseline, restored before every gate call (see j_gate): the sweep is
# idempotent by design and journals a marker into this file to stay that way.
cp "$JROSTER" "$JROSTER.pristine"

j_line() {  # <name> -> the verb's machine line for that name, or empty
  ( cd "$JREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PARTY_SW" verdict "$1" 2>/dev/null ) \
    | grep -F 'landing-verdict/v1|' | grep -F "|name=$1|" | head -1
}
j_field() {  # <line> <key>
  printf '%s' "$1" | tr '|' '\n' | grep "^$2=" | head -1 | cut -d= -f2-
}
j_verdict() {  # <name> -> the state the verb computed, or NONE when it prints no line
  local l; l=$(j_line "$1")
  if [ -z "$l" ]; then echo NONE; else j_field "$l" state; fi
}
# THE SWEEP JUDGES EVERY LANDED ROW AT ONCE, so asking it about ONE row means declaring
# every OTHER row still in flight. That is the mechanism's own vocabulary rather than a test
# seam: `background_tasks[]` is the payload's list of what is still running, and the gate
# skips exactly those. `ghost` is on no roster row, so nothing lands and nothing is judged.
J_ALL="met unmet empty stale live waived quoter linked dup"
j_live_except() {  # <name> -> every OTHER row's agent id
  local want="$1" n
  for n in $J_ALL; do [ "$n" = "$want" ] || printf 'a-%s\n' "$n"; done
}

# Globals rather than a captured echo: the refusal TEXT is asserted below, and a
# `$(…)` call would throw the stderr away.
J_ANSWER=""; J_GATE_ERR=""
j_gate() {  # <name> [stop_hook_active] -> sets J_ANSWER + J_GATE_ERR
  local st
  # THE ROSTER IS RESTORED FIRST. The sweep verdicts each landed row exactly ONCE and
  # journals a marker into the roster file to keep that promise; a battery that asked twice
  # about one row would be measuring the marker, not the agreement. Restoring is also what
  # every real session gets — a fresh roster per session.
  cp "$JROSTER.pristine" "$JROSTER"
  # shellcheck disable=SC2046
  J_GATE_ERR=$( mk_stopsweep_payload "$JREPO" "$SID_A" "${2:-false}" $(j_live_except "$1") \
                | bash "$PARTY_LG" 2>&1 >/dev/null )
  st=$?
  case "$st" in
    0) J_ANSWER=pass ;;
    2) J_ANSWER=refuse ;;
    *) J_ANSWER="other:exit-$st" ;;
  esac
}

# name|the verb's state|the gate's answer.  `ghost` is on no roster row at all —
# the phantom class the capture probe found firing three times per teammate run,
# where the verb prints nothing and the gate must not invent a contract.
J_CASES='
met|MET|pass
unmet|UNMET|refuse
empty|UNMET|refuse
stale|UNMET|refuse
waived|WAIVED|pass
quoter|UNMET|refuse
linked|UNMET|refuse
dup|AMBIGUOUS|pass
live|STILL-LIVE|pass
ghost|NONE|pass
'

run_j_battery() {  # assert|detect
  local mode="$1" name want ans v
  while IFS='|' read -r name want ans; do
    [ -n "$name" ] || continue
    v=$(j_verdict "$name"); j_gate "$name"
    if [ "$mode" = "assert" ]; then
      expect_eq "the verb computes $want for '$name'" "$want" "$v"
      expect_eq "…and the gate answers $ans, which is what $want means for a stop" \
        "$ans" "$J_ANSWER"
      # The agreement itself, computed from the verb's own answer rather than from
      # the table — so a case added to J_CASES with the wrong pairing cannot pass.
      expect_eq "…gate refuses IFF the verb says UNMET ('$name')" \
        "$([ "$v" = "UNMET" ] && echo refuse || echo pass)" "$J_ANSWER"
    else
      if [ "$v" != "$want" ]; then
        printf 'the verb moved on %s: want=%s got=%s\n' "$name" "$want" "$v"; return 1
      fi
      if [ "$J_ANSWER" != "$ans" ]; then
        printf 'gate/verb disagree on %s: verb=%s gate=%s (expected %s)\n' \
          "$name" "$v" "$J_ANSWER" "$ans"; return 1
      fi
    fi
  done <<EOF
$(printf '%s' "$J_CASES")
EOF
  return 0
}

run_j_battery assert

j_gate dup
expect_eq "a name carrying two contracts is not blocked on either of them" "pass" "$J_ANSWER"

# THE ONE DELIBERATE DIVERGENCE, pinned rather than left implicit. On re-entry the
# gate passes a contract the verb still calls UNMET — and the verb is re-run here
# rather than assumed, so this asserts a difference in AUTHORITY, not a difference
# of opinion about the disk. Blocking once is the R7 term: only the gate has a stop
# to refuse, and an agent refused twice has no way out of the loop.
j_gate unmet true
expect_eq "on re-entry (stop_hook_active true) the gate passes" "pass" "$J_ANSWER"
expect_eq "…while the verb's answer is unchanged, because the disk did not change" \
  "UNMET" "$(j_verdict unmet)"

# ============================================================
section "J.2 — only a GATE change can split the two answers (mutation goes RED)"
# ============================================================
#
# Each mutation is applied to a COPY of the gate, installed in its own directory
# beside a real sweeper — which is how bootstrap's flat `hooks/*.sh` install lets
# the gate find its sibling, and therefore the production resolution rather than a
# test seam. Every one is a plausible drift, not damage.

JMUT="$SANDBOX/landing-mutants"
J_CKSUM_BEFORE=$(shasum "$PARTY_LG" "$PARTY_SW" 2>/dev/null)

j_mutant() {  # <kind> -> path to a mutant gate with a sibling sweeper, or empty
  # Two statements, not one: `local a=1 b="$a"` expands every word BEFORE it
  # assigns any of them, so under `set -u` the second reference is unbound.
  local kind="$1"
  local d
  d="$(plant_hook_tree "$JMUT/$kind")"
  cp "$PARTY_SW" "$d/session-sweeper.sh"
  case "$kind" in
    # THE LANDED/LIVE DISCRIMINATION DROPPED. `background_tasks[]` is the payload's
    # list of what is STILL RUNNING (T4b §2.2), and skipping those rows is the whole
    # of "judge it when it lands". Without the skip the sweep holds every mid-flight
    # agent to a contract it has not finished — the false-alarm direction.
    ignore-background-tasks)
      anchor "$PARTY_LG" 'case "$LIVE_IDS" in' 1
      awk '{ if (index($0, "$LIVE_IDS") > 0 && index($0, "case ") > 0) next
             print }' "$PARTY_LG" > "$d/landing-gate.sh" ;;
    # The hook process's ambient session key instead of the payload's (the gate
    # documents why at the code) — a wrong or absent roster, silently.
    ambient-session-key)
      anchor -E "$PARTY_LG" 'CLAUDE_CODE_SESSION_ID="[$]SID" ' 1
      awk '{ sub(/CLAUDE_CODE_SESSION_ID="[$]SID" /, ""); print }' \
        "$PARTY_LG" > "$d/landing-gate.sh" ;;
    # The sweeper resolves its own state directory from the working directory, so
    # dropping the cd asks the verb about whatever repo the hook happened to run in.
    no-cd-to-repo)
      anchor "$PARTY_LG" 'VERDICT=$( cd ' 1
      awk '{ if (index($0, "VERDICT=$( cd ") > 0) $0 = "VERDICT=$( true"
             print }' "$PARTY_LG" > "$d/landing-gate.sh" ;;
    *) return 1 ;;
  esac
  # CONTROL FLOW, not a precondition: the three anchors above are what report a moved
  # target. This line only decides whether the caller gets a path back.
  cmp -s "$PARTY_LG" "$d/landing-gate.sh" && return 1
  printf '%s' "$d/landing-gate.sh"
}

for m in ignore-background-tasks ambient-session-key no-cd-to-repo; do
  mpath=$(j_mutant "$m") || mpath=""
  if [ -z "$mpath" ]; then
    # A mutation that matched nothing is not a passing test — it means the code
    # moved and this proof has gone vacuous.
    no "gate mutation '$m' applies to landing-gate.sh" \
       "the doctored copy came out byte-identical — see the anchor row above"
    continue
  fi
  j_saved="$PARTY_LG"; PARTY_LG="$mpath"
  if jdetail=$(run_j_battery detect); then
    no "one-gate mutation '$m' makes the landing battery RED" \
       "the battery stayed green with the gate mutated — it does not discriminate"
  else
    ok "one-gate mutation '$m' makes the landing battery RED"
  fi
  PARTY_LG="$j_saved"
done

# ============================================================
section "J.3 — a PREDICATE change moves BOTH answers, never one (the single owner)"
# ============================================================
#
# The mutant sweeper below reads an EMPTY file as delivered — the `[ -s ]` defect
# §I.2 pins on the tick loop, here in the landing predicate. It is installed as the
# sibling of an UNMUTATED copy of the gate, so the only thing that changed is the
# owner of the predicate. Both answers flip together: that is not a lucky
# coincidence, it is what "the gate owns no predicate" means in operation, and it
# is the reason the two can never be caught telling different people different
# things about one contract.
JP="$(plant_hook_tree "$JMUT/predicate")"
cp "$PARTY_LG" "$JP/landing-gate.sh"
awk '{ sub(/\[ ! -s "[$]p" \]/, "[ ! -e \"$p\" ]"); print }' "$PARTY_SW" > "$JP/session-sweeper.sh"
j_saved_lg="$PARTY_LG"; j_saved_sw="$PARTY_SW"
PARTY_LG="$JP/landing-gate.sh"; PARTY_SW="$JP/session-sweeper.sh"
j_gate empty
expect_eq "with the predicate loosened, the verb calls the empty file delivered" \
  "MET" "$(j_verdict empty)"
expect_eq "…and the gate passes the same stop it refused a moment ago" "pass" "$J_ANSWER"
PARTY_LG="$j_saved_lg"; PARTY_SW="$j_saved_sw"

# ============================================================
section "J.4 — still-live has ONE owner now; the row that split the two is pinned"
# ============================================================
#
# "Is this row still live?" used to be computed at TWO sites in hooks/session-sweeper.sh
# that served different masters and were SUPPOSED to disagree (wave-01 Step-6 critic D-2):
#   * evaluate_row — the tick loop, a WAKE heuristic. A row that declared `claims=` opted
#     into process-liveness as its ONLY signal, so a dead claimed process was a dead-claim
#     finding full stop and progress was never consulted.
#   * row_still_live — the verdict verb, a STOP exemption. A dead claim falls THROUGH to
#     progress/cadence, so fresh progress can still answer STILL-LIVE and spare a stopping
#     agent a false UNMET.
# On a dead-claim-plus-fresh-progress row the two answered DIFFERENTLY, and this section
# pinned that inequality so neither could drift toward the other.
#
# THE TICK LOOP IS DELETED (epic-16 wave-02), so there is no second owner and no inequality
# left to pin — an equality assertion between one implementation and nothing is not a test,
# and asserting the difference persists would be asserting that deleted code still runs. What
# survives is the SURVIVOR'S HALF, driven on the identical fixture: the row shape that split
# the two owners is exactly the row shape most likely to be misjudged, and the verdict verb
# must still call it STILL-LIVE. If a future edit collapses row_still_live into the loop's
# old "a dead claim ends the question" reading, this goes red.
DLREPO=$(new_repo "still-live-divergence")
write_plan "$DLREPO/.bionic/docs/plans/epic-16/wave-01.md" "current: 4"
mkdir -p "$DLREPO/.bionic/tmp"
DL_ROSTER="$DLREPO/.bionic/tmp/roster-$SID_A.state"
DL_LAUNCHED=$(date -u -v-3600S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "-3600 seconds" +%Y-%m-%dT%H:%M:%SZ)
# FRESH progress written now, well inside the declared cadence; a DEAD claim no live process
# carries; an ABSENT deliverable so the row has not landed and is genuinely judged.
printf 'stage 1\n' > "$DLREPO/.bionic/tmp/dl.progress"
# `-$$` is load-bearing, not decoration. This claim exists to be DEAD — the arm below asserts
# `pgrep -f` matches nothing, and hooks/stop-check.sh reads liveness the same way. `pgrep -f`
# matches on full argv, and a concurrent `tests/run.sh` running this very file carries the
# literal in its own argv, so a fixed string makes each run's shell satisfy the other run's
# "no such process" claim. The pid suffix gives every run a private literal that no sibling's
# argv can contain, which is what makes the claim's deadness a property of this run alone.
DL_CLAIM="bionic-xgate-D2-deadclaim-no-such-process-9f5c1a2b-$$"
{
  roster_header
  roster_row_fixture status=confirmed session="$SID_A" name=dl-row agent_id=adl-row-0001 \
    launched_at="$DL_LAUNCHED" deliverable=.bionic/docs/record/never-dl.md \
    progress=.bionic/tmp/dl.progress claims="$DL_CLAIM" cadence=~5m tool_use_id=toolu_DL
} > "$DL_ROSTER"
# Not vacuous: the claimed process really is dead.

DL_VERDICT=$( cd "$DLREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PARTY_SW" verdict dl-row 2>/dev/null \
  | grep -F 'landing-verdict/v1|' | grep -F '|name=dl-row|' | head -1 \
  | tr '|' '\n' | grep '^state=' | head -1 | cut -d= -f2- )
expect_eq "the verdict verb calls the dead-claim-plus-fresh-progress row STILL-LIVE" \
  "STILL-LIVE" "$DL_VERDICT"

# The DISCRIMINATING half, and what makes the assertion above mean something: it is the
# PROGRESS that carries the row, not a blanket refusal to judge a claimed row. Stale the
# progress and the same row — same dead claim, same absent deliverable — reads UNMET.
touch -t 202001010000 "$DLREPO/.bionic/tmp/dl.progress"
DL_VERDICT_STALE=$( cd "$DLREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PARTY_SW" verdict dl-row 2>/dev/null \
  | grep -F 'landing-verdict/v1|' | grep -F '|name=dl-row|' | head -1 \
  | tr '|' '\n' | grep '^state=' | head -1 | cut -d= -f2- )
expect_eq "…and once that progress goes stale the same row is UNMET" "UNMET" "$DL_VERDICT_STALE"

# The gate consumes exactly that, both ways round — one owner, and the stop follows it.
j_saved_lg2="$PARTY_LG"
# The sweep answers once per row, ever, so the marker it journals is cleared between the
# two halves: what is being asked twice is the PREDICATE, not the idempotency.
dl_sweep() {  # -> sets JDL_ST; echoes the refusal
  /usr/bin/grep -v '^landing-swept/' "$DL_ROSTER" > "$DL_ROSTER.tmp" 2>/dev/null
  mv "$DL_ROSTER.tmp" "$DL_ROSTER"
  mk_stopsweep_payload "$DLREPO" "$SID_A" false | bash "$PARTY_LG" 2>&1 >/dev/null
}
JDL_ERR=$(dl_sweep); JDL_ST=$?
expect_eq "the gate refuses the stop on the UNMET reading" "2" "$JDL_ST"
printf 'stage 2\n' > "$DLREPO/.bionic/tmp/dl.progress"
JDL_ERR2=$(dl_sweep); JDL_ST2=$?
expect_eq "…and passes it the moment the progress is fresh again" "0" "$JDL_ST2"
PARTY_LG="$j_saved_lg2"

# ============================================================
section "K — the IDENTITY CHAIN: intended → confirmed → identified, one contract"
# ============================================================
#
# The roster is append-only and a contract ADVANCES along it: `intended` at the
# dispatch wall, `confirmed` when the spawn returns, `identified` when the subagent
# starts (spec §1). Three rows, ONE contract — and four readers that must not
# disagree about it: the sweeper's verdict folds to the latest row per name,
# hooks/stop-check.sh and hooks/stop-guard.sh take the row by id and fall back to
# the row by name, and the recorder's own join reads the chain to extend it.
#
# The chain below is built by the REAL writers from a REAL brief — the start gate,
# then the recorder's completion arm on a teammate-shaped payload, then the
# recorder's identification arm on a SubagentStart. Nothing here is a hand-written
# row, because the defect this section exists to catch is a writer that stops
# copying a field forward, and a hand-written fixture would carry the fields the
# test author remembered rather than the ones the writer emits.

KREPO=$(new_repo "identity-chain")
KSLUG=$(printf '%s' "$KREPO" | sed 's/[^a-zA-Z0-9]/-/g')
KPROJ="$CLAUDE_CONFIG_DIR/projects/$KSLUG"
KSUB="$KPROJ/$SID_A/subagents"
KSUB_B="$KPROJ/$SID_B/subagents"
mkdir -p "$KSUB" "$KSUB_B" "$KREPO/.bionic/tmp"
KTR="$KPROJ/$SID_A.jsonl"; printf '{}\n' > "$KTR"
KTR_B="$KPROJ/$SID_B.jsonl"; printf '{}\n' > "$KTR_B"
write_plan "$KREPO/.bionic/docs/plans/epic-16/wave-01.md" "current: 4"
KROSTER="$KREPO/.bionic/tmp/roster-$SID_A.state"
KID="aw16chain-1234567890abcdef"

# The attestation the dispatch wall demands, as a fixture: whether the producer and
# the wall spell that key the same way is §B's subject, not this one.
{
  printf '# bionic environment attestation — machine-local, safe to delete\n'
  printf 'version=1\nkind=preflight-attestation\n'
  printf 'session_id=%s\nwritten_at=1785790000\nrepo=%s\n' "$SID_A" "$KREPO"
} > "$KREPO/.bionic/tmp/preflight-$SID_A.state"

K_BRIEF='Canonical-sdlc Step 4, slice 6 of epic-16 wave-01; build · audited · wave.
Expected artifact: .bionic/docs/record/w16-chain.md
Expected duration: ~30 minutes. Progress artifact: .bionic/tmp/w16-chain.progress, cadence ~7m.
Subprocess claim: `w16-chain-marker` → .bionic/tmp/w16-chain.log
Exit condition: the artifact exists.
Suites: tests/widget.test.sh'

# STAGE 1 — the dispatch wall writes `intended`.
mk_agent_payload "$SID_A" "$KREPO" \
  | jq --arg p "$K_BRIEF" '.tool_input.name = "w16-chain" | .tool_input.prompt = $p
                           | .tool_use_id = "toolu_01CHAIN"' \
  | bash "$PARTY_DP" >/dev/null 2>&1
K_INTENDED=$(grep 'status=intended|.*|name=w16-chain|' "$KROSTER" 2>/dev/null | tail -1)
expect_contains "the dispatch wall journalled the launch as intended" \
  "status=intended" "$K_INTENDED"
expect_contains "…carrying the deliverable the brief declared" \
  "deliverable=.bionic/docs/record/w16-chain.md" "$K_INTENDED"

# STAGE 2 — the spawn returns; the recorder completes the row to `confirmed`. The
# ASYNC shape, which is the one the id join spans end to end: `tool_response.agentId`
# here is the same string SubagentStart carries below and the same string the landing
# sweep matches against `background_tasks[].id` (t4b-probe-report.md §4). The TEAMMATE
# shape — addressing id recorded, `agent_id=` deliberately left empty, and therefore
# never identified — is pinned in tests/execution-recorder.test.sh Section 10.
mk_agent_post "$SID_A" "$KTR" "$KREPO" "toolu_01CHAIN" "w16-chain" "$KID" \
  | bash "$PARTY_ER" >/dev/null 2>&1
K_CONFIRMED=$(grep 'status=confirmed|.*|name=w16-chain|' "$KROSTER" 2>/dev/null | tail -1)
expect_contains "the spawn's completion advances the row to confirmed" \
  "status=confirmed" "$K_CONFIRMED"
expect_contains "…recording the transcript-form id the join needs" \
  "agent_id=$KID" "$K_CONFIRMED"

# STAGE 3 — the subagent starts; the recorder joins BY THAT ID and writes `identified`.
mk_start_payload "$SID_A" "$KTR" "$KREPO" "w16-chain" "$KID" | bash "$PARTY_ER" >/dev/null 2>&1
K_IDENTIFIED=$(grep 'status=identified|.*|name=w16-chain|' "$KROSTER" 2>/dev/null | tail -1)
expect_contains "the start advances the row to identified" "status=identified" "$K_IDENTIFIED"
expect_contains "…carrying the transcript-form id" "agent_id=$KID" "$K_IDENTIFIED"
expect_eq "the chain is three rows for one name, in order" "intended confirmed identified" \
  "$(grep '|name=w16-chain|' "$KROSTER" 2>/dev/null | tr '|' '\n' | grep '^status=' | cut -d= -f2 | tr '\n' ' ' | sed 's/ $//')"

# --- K.1 the chain invariant: every contract field survives every advance ---
#
# "Every field copied forward" is the recorder's own claim, and it is load-bearing
# rather than tidy: the verdict folds to the LATEST row per name and reads the whole
# contract — deliverable, launch clock, progress path, cadence, claims, waiver — off
# that row alone. A row that dropped a field would not merely be terse; it would
# silently RETRACT the contract it inherited, and the verdict would then call it MET
# for naming nothing. Compared generically, so a field added later is covered by this
# test the day it is added rather than the day someone remembers to list it.
k_contract_fields() {  # <row> -> the fields that must not change, one per line
  printf '%s' "$1" | tr '|' '\n' \
    | grep -v '^roster-state/' | grep -v '^status=' | grep -v '^agent_id=' \
    | grep -v '^teammate_id='
}
expect_eq "every contract field survives intended → confirmed" \
  "$(k_contract_fields "$K_INTENDED")" "$(k_contract_fields "$K_CONFIRMED")"

# --- K.2 the four readers, one row, one contract ---
plant "$KSUB" "$KID" "w16-chain"

# READER 1 — the sweeper's verdict. ONE line for the name, not three: a gate handed
# a line per roster row would have to guess which to believe. Taken BEFORE the
# progress artifact exists, because a progress file inside its declared cadence is
# STILL-LIVE by design and this reader is being asked about the deliverable.
K_VERDICT=$( cd "$KREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PARTY_SW" verdict w16-chain 2>/dev/null )
expect_eq "the verdict prints exactly ONE line for a three-row chain" "1" \
  "$(printf '%s\n' "$K_VERDICT" | grep -cF 'landing-verdict/v1|')"
K_VLINE=$(printf '%s\n' "$K_VERDICT" | grep -F 'landing-verdict/v1|' | head -1)
# STILL-LIVE, and asserted rather than engineered away: this chain is seconds old
# and its brief declared a ~7m cadence, so an agent that has not written anything
# yet is visibly in flight, not in breach. What matters here is that the verb read
# the CONTRACT off the chain at all — it names the outstanding artifact either way.
expect_eq "…and it reads the contract off the chain, not off nothing" "STILL-LIVE" \
  "$(j_field "$K_VLINE" state)"

# The paired positive (AC-4's absence-readback rule): the same chain, the same verb,
# with the artifact on disk. `sleep 1` because the delivered predicate is
# mtime > launched_at and the row was written this second.
sleep 1
mkdir -p "$KREPO/.bionic/docs/record"
echo "the slice report" > "$KREPO/.bionic/docs/record/w16-chain.md"
K_VERDICT=$( cd "$KREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PARTY_SW" verdict w16-chain 2>/dev/null )
K_VLINE=$(printf '%s\n' "$K_VERDICT" | grep -F 'landing-verdict/v1|' | head -1)
expect_eq "…and the same chain reads MET once the artifact lands" "MET" \
  "$(j_field "$K_VLINE" state)"

# READER 2 — the observation. Same chain, same contract, reached by its own means:
# it takes no payload, so it finds the roster by slugifying its own cwd.
printf 'stage 1\n' > "$KREPO/.bionic/tmp/w16-chain.progress"
K_OBS=$( cd "$KREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" w16-chain 2>&1 )
K_MLINE=$(printf '%s\n' "$K_OBS" | grep '^stop-check-observation/')
expect_contains "…naming the roster as where that contract came from" \
  "deliverable_source=roster" "$K_MLINE"
expect_contains "…and the same progress path" "progress=.bionic/tmp/w16-chain.progress" "$K_MLINE"
expect_contains "…from the same source" "progress_source=roster" "$K_MLINE"

# THE READERS COMPARED TO EACH OTHER, not each to a literal — which is what goes red
# when either one starts resolving a different row of the chain. The observation's
# machine line renders each deliverable as `<state>:<path>`, so the state is stripped
# before the paths are compared; the STATE itself is asserted separately, because
# both readers must also agree the artifact is not there.
k_sw_path() {  # the path the VERB says the contract names, whatever state it reports
  j_field "$K_VLINE" detail \
    | grep -oE '(missing|delivered|empty)=[^ ]+' | head -1 | cut -d= -f2-
}
K_SC_DELIV=$(printf '%s' "$K_MLINE" | tr '|' '\n' | grep '^deliverables=' | head -1 | cut -d= -f2-)
expect_eq "the verb and the observation name the same deliverable" \
  "$(k_sw_path)" "${K_SC_DELIV#*:}"
expect_eq "…and agree it is on disk" "present" "${K_SC_DELIV%%:*}"
expect_eq "…and it is the value on the row the writer wrote" \
  "$(printf '%s' "$K_IDENTIFIED" | tr '|' '\n' | grep '^deliverable=' | head -1 | cut -d= -f2-)" \
  "$(k_sw_path)"

# READER 3 — the stop gate, over the D-6 channel the chain contracted. The refusal
# is sourced from the roster row this gate resolved, so it names the path the START
# gate lifted out of the brief three rows ago.
mk_bash_post "$SID_A" "$KTR" "$KREPO" "bash ~/.claude/hooks/stop-check.sh w16-chain" "$K_OBS" \
  | bash "$PARTY_ER" >/dev/null 2>&1
sleep 1
printf 'stage 2\n' >> "$KREPO/.bionic/tmp/w16-chain.progress"
# THE CONTRACT IS TAKEN BACK OFF DISK FIRST (epic-16 wave-02 slice S3). D-6 is a rule about
# a stop that would end UNFINISHED work: since this wave, a LANDED contract discharges the
# stop outright and no channel is consulted, which is AC-1 and is asserted as the paired
# half below. Reader 3's question — does the chain carry the progress path all the way to
# the gate's refusal — is only askable while the contract is outstanding, so the artifact
# reader 1 delivered is moved aside for it and restored immediately after. Same chain, same
# roster, same gate; the only thing that varies is the one fact that decides.
mv "$KREPO/.bionic/docs/record/w16-chain.md" "$SANDBOX/k-chain-artifact.md"
K_SG_OUT=$(mk_stop_payload "$SID_A" "$KTR" "$KREPO" "w16-chain" | bash "$PARTY_SG" 2>&1); K_SG_ST=$?
expect_eq "the stop gate refuses a stop whose contracted channel moved under the look" \
  "2" "$K_SG_ST"

# THE OTHER DIRECTION, one fact apart: the artifact comes back, the verdict says MET, and
# the identical stop — same stale observation, same moved progress channel — passes with no
# ceremony at all. This is AC-1 read across the gates rather than inside one: the fact that
# discharges the stop is the same fact the verb reports and the operator can see.
mv "$SANDBOX/k-chain-artifact.md" "$KREPO/.bionic/docs/record/w16-chain.md"
K_SG_OUT=$(mk_stop_payload "$SID_A" "$KTR" "$KREPO" "w16-chain" | bash "$PARTY_SG" 2>&1); K_SG_ST=$?
expect_eq "…and once the contract has landed, the same stop passes with no ceremony" \
  "0" "$K_SG_ST"
expect_eq "…silently — nothing is demanded of a stop the disk already answers for" \
  "" "$K_SG_OUT"

# READER 4 — the recorder's own join. A SECOND start for the SAME agent (the resume
# shape) re-joins the `confirmed` row rather than chaining off its own output — states
# advance, and a repeated start must not compound a field loss — and the row it writes
# still carries the original dispatch's tool_use_id, which is the proof it joined the
# chain rather than starting a new one. The id is the key, so a start for a DIFFERENT
# id is a different agent and joins nothing here.
mk_start_payload "$SID_A" "$KTR" "$KREPO" "w16-chain" "$KID" \
  | bash "$PARTY_ER" >/dev/null 2>&1
K_IDENT2=$(grep 'status=identified|.*|name=w16-chain|' "$KROSTER" 2>/dev/null | tail -1)
expect_eq "a second start writes a second identified row" \
  "2" "$(grep -c 'status=identified|.*|name=w16-chain|' "$KROSTER" 2>/dev/null | tr -d ' ')"
expect_contains "…carrying the id it joined on" "agent_id=$KID" "$K_IDENT2"
expect_contains "…still carrying the original dispatch's tool_use_id" \
  "tool_use_id=toolu_01CHAIN" "$K_IDENT2"
expect_eq "…and the same contract as every row before it" \
  "$(k_contract_fields "$K_INTENDED")" "$(k_contract_fields "$K_IDENT2")"

# --- K.3 the identified row is what makes the by-id walls reachable (paired) ---
#
# R4's whole point, re-aimed at what actually supplies the key (epic-16 wave-03). The
# by-id walls can only vouch for an agent whose TRANSCRIPT-form id is on the roster;
# a row that carries no such id is a row no by-id reader can satisfy. On an async
# dispatch the roster arm supplies it at confirmation and the identification arm
# re-states it; on a TEAMMATE dispatch neither does — `agent_id=` is deliberately
# empty because the launch response carries only the addressing form, and since the
# identification join is by id there is nothing to join with. That gap is real and
# named in hooks/execution-recorder.sh; what is pinned HERE is the consequence, over
# ONE roster, in the one shape where the answer is observable: the agent's metadata
# filed under ANOTHER session's directory, where only the roster can vouch for it.
# The negative half strips the transcript id from every row and nothing else.
# The agent MOVES rather than being copied: the same id filed under two session
# directories of one project is the AMBIGUOUS case (§C2), which would answer this
# question with "the operator was shown a candidate list" instead of with the
# ownership rule under test.
mkdir -p "$SANDBOX/k-own-meta"
mv "$KSUB/agent-$KID.meta.json" "$KSUB/agent-$KID.jsonl" "$SANDBOX/k-own-meta/"
plant "$KSUB_B" "$KID" "w16-chain" "$KREPO"
K_ROSTER_NOID="$SANDBOX/k-roster-without-identified.state"
grep -v 'status=identified' "$KROSTER" | sed -e "s/|agent_id=$KID|/|agent_id=|/" > "$K_ROSTER_NOID"
K_ROSTER_FULL="$SANDBOX/k-roster-full.state"
cp "$KROSTER" "$K_ROSTER_FULL"

k_observation_says() {  # -> the classification of the cross-session agent
  local out
  out=$( cd "$KREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" "$KID" 2>&1 )
  case "$out" in
    *"Classification: OURS"*)         echo ours ;;
    *"Classification: FOREIGN"*)      echo foreign ;;
    *"Classification: DEAD HISTORY"*) echo dead ;;
    *) echo "other" ;;
  esac
}
# The stop is BY NAME, which is the only shape the foreign wall guards: a by-id
# stop is the documented escape hatch (an id is unambiguous by construction), so
# asking by id would answer a different question. The payload's session key and its
# transcript path DISAGREE — the gate's own comment names that as the one way a
# cross-session target reaches it — and the observation/record pair runs first,
# because the record wall sits behind the foreign one and an unrecorded look would
# refuse both halves for the same uninteresting reason.
k_stop_gate_says() {  # -> foreign | ours
  local out
  rm -f "$KREPO/.bionic/tmp/stop-check.state"
  out=$( cd "$KREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$OBSERVE" "$KID" 2>&1 )
  mk_bash_post "$SID_A" "$KTR_B" "$KREPO" "bash ~/.claude/hooks/stop-check.sh $KID" "$out" \
    | bash "$PARTY_ER" >/dev/null 2>&1
  out=$(mk_stop_payload "$SID_A" "$KTR_B" "$KREPO" "w16-chain" | bash "$PARTY_SG" 2>&1)
  case "$out" in
    # One refusal replaces the other: the gate no longer asks whose DIRECTORY the metadata
    # sits in, it asks whether this session's roster names an id for the target. Both are the
    # same row flipping, which is what this section pins.
    *"carries no agent id"*) echo foreign ;;
    *"is not live"*)         echo foreign ;;
    *) echo ours ;;
  esac
}
expect_eq "with the identified row, the observation vouches for a cross-session agent" \
  "ours" "$(k_observation_says)"
expect_eq "…and the stop gate's foreign wall stands down over the same row" \
  "ours" "$(k_stop_gate_says)"
cp "$K_ROSTER_NOID" "$KROSTER"
# Without the transcript id anywhere on the roster there is no working log either reader can
# name — the id is what it is filed under — so both refuse, and they refuse on the same row.
# The verdict used to be `foreign`, an answer about which session's DIRECTORY held the
# metadata; the row's job in the chain is unchanged, only what depends on it is narrower.
expect_eq "without the transcript id anywhere on the roster, the observation shows nothing" \
  "other" "$(k_observation_says)"
# The GATE's half needs one more thing said out loud than it used to. A LANDED contract
# discharges a stop before the gate ever asks where the working log is (epic-16 wave-02 R2),
# and the row under test here has one — so the id gap is invisible on that path, correctly.
# Strip the declared deliverable and nothing discharges any more; the gate then reaches the
# question the row answers, and refuses because no id on it can name a log to look at.
K_ROSTER_NOID_NOCONTRACT="$SANDBOX/k-roster-noid-nocontract.state"
sed 's/|deliverable=[^|]*|/|deliverable=|/' "$K_ROSTER_NOID" > "$K_ROSTER_NOID_NOCONTRACT"
cp "$K_ROSTER_NOID_NOCONTRACT" "$KROSTER"
expect_eq "…and the stop gate refuses it, both readers flipping on the same row" \
  "foreign" "$(k_stop_gate_says)"
cp "$K_ROSTER_FULL" "$KROSTER"

# --- K.4 a forward-copy that drops a field goes RED here ---
#
# The mutation is the plausible one: an identification arm that writes a fresh row
# instead of copying the joined row forward. It is applied to a COPY of the recorder
# and driven over a SECOND chain, so the chain above is untouched.
KMUT="$(plant_hook_tree "$SANDBOX/recorder-mutant")/execution-recorder.sh"
awk '{ print; if (index($0, "if (f ~ /^status=/)")) print "      if (f ~ /^deliverable=/) f = \"deliverable=\"" }' \
  "$PARTY_ER" > "$KMUT"
if cmp -s "$PARTY_ER" "$KMUT"; then
  :
else
  mk_agent_payload "$SID_A" "$KREPO" \
    | jq --arg p "$K_BRIEF" '.tool_input.name = "w16-mut" | .tool_input.prompt = $p
                             | .tool_use_id = "toolu_01MUT"' \
    | bash "$PARTY_DP" >/dev/null 2>&1
  mk_agent_post "$SID_A" "$KTR" "$KREPO" "toolu_01MUT" "w16-mut" "aw16mut-1111111111111111" \
    | bash "$KMUT" >/dev/null 2>&1
  mk_start_payload "$SID_A" "$KTR" "$KREPO" "w16-mut" "aw16mut-1111111111111111" \
    | bash "$KMUT" >/dev/null 2>&1
  K_MUT_INTENDED=$(grep 'status=intended|.*|name=w16-mut|' "$KROSTER" 2>/dev/null | tail -1)
  K_MUT_IDENT=$(grep 'status=identified|.*|name=w16-mut|' "$KROSTER" 2>/dev/null | tail -1)
  if [ "$(k_contract_fields "$K_MUT_INTENDED")" = "$(k_contract_fields "$K_MUT_IDENT")" ]; then
    no "a dropped forward-copy makes the chain invariant RED" \
       "the invariant stayed green with the recorder mutated — it does not discriminate"
  else
    ok "a dropped forward-copy makes the chain invariant RED"
  fi
  # …and the consequence the invariant is a proxy for: the contract is RETRACTED.
  # The verdict now calls a row MET for naming nothing, which is the false clean
  # answer the landing gate would pass a stopping agent on.
  expect_eq "…and the verdict then calls the retracted contract MET, vacuously" "MET" \
    "$( cd "$KREPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PARTY_SW" verdict w16-mut 2>/dev/null \
        | grep -F 'landing-verdict/v1|' | head -1 | tr '|' '\n' | grep '^state=' | cut -d= -f2- )"
fi

# ============================================================
# ============================================================
section "L — the WIRING: one hook, one registration, one manifest"
# ============================================================
#
# A hook that reads an event nobody registered it for is inert, and inert in the
# quietest possible way: it is installed, it is syntactically fine, its own suite is
# green, and it never runs.
#
# THERE IS ONE REGISTRATION SURFACE NOW (bionic 1.4.0, slice ADOPT, spec AC-7):
# hooks/hooks.json. Until this wave there were two, and the split was not laziness —
# it was a partition. Skill-frontmatter hooks bind only in sessions that invoke the
# skill, which is what kept the sdlc walls off every unrelated project on the machine;
# settings-channel hooks are the only ones an AGENT-context event can reach, which is
# what got the same walls into teammate contexts. Three hooks were therefore registered
# on both channels, each entry covering the half the other could not.
#
# THE PARTITION IS WHAT BROKE. A skill's registrations are looked up per session, so a
# `/clear`, a continue or a `/reload-plugins` left every wall installed and not running
# — silently, while dispatches kept launching unrostered. The scope the frontmatter was
# buying is now bought by an ON-DISK fact instead: each hook asks `active_run` under the
# payload's project root and does nothing where there is no run. That is a better
# partition than the channel ever was, because it survives the conversation.
#
# THE THREE WAYS THIS CAN STILL BE SILENTLY WRONG, one assertion each below: the
# frontmatter could keep an entry (the hook then fires TWICE per event — the CLI does
# not deduplicate across the plugin/skill boundary), a hook could be missing from the
# manifest (inert), or a hook could be named twice within it (two refusals, two journal
# rows for one dispatch).
SKILL_SRC="$BIONIC_SKILLS_DIR/canonical-sdlc/SKILL.md"
HOOKS_JSON_SRC="$BIONIC_HOOKS_DIR/hooks.json"

# the shell's bare `grep` is ugrep with ignore-files active and lies about absence
# (reports 0 hits inside paths it silently skips) — every absence check below goes
# through /usr/bin/grep instead.
expect_absent_ug() {
  if /usr/bin/grep -qF -- "$2" <<<"$3"; then no "$1" "unexpectedly present: $2"; else ok "$1"; fi
}

# --- L.1 THE FRONTMATTER REGISTERS NOTHING ---
#
# Not "registers less" — nothing. The `hooks:` key is gone from SKILL.md's frontmatter
# entirely, and that is the half of the change that makes the other half safe: a hook
# named in both manifests fires twice per event, which for the landing sweep means two
# markers journalled per turn and for a wall means one refusal printed twice. The
# avoidance pattern this replaces is documented in the shipped file's own history —
# landing-gate was deliberately split across Stop (skill) and SubagentStop (settings)
# precisely so it would never be registered twice on one event.
SKILL_HOOKS_ROWS=$(skill_hooks_rows "$SKILL_SRC")
expect_eq "SKILL.md's frontmatter registers NOTHING — the hooks: block is gone" \
  "" "$SKILL_HOOKS_ROWS"
expect_eq "…and the key itself is absent, not merely empty" "0" \
  "$(awk 'NR==1 && $0=="---" {f=1; next} f && $0=="---" {exit} f' "$SKILL_SRC" \
     | /usr/bin/grep -c '^hooks:')"
# ANTI-VACUITY. An empty row set is what a BROKEN extractor also produces, so the
# extractor is proved against a fixture that does carry a block.
L1_FIX="$SANDBOX/fx-skill-with-hooks.md"
cat > "$L1_FIX" <<'L1EOF'
---
name: fixture
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: ${CLAUDE_PLUGIN_ROOT}/hooks/x.sh
          timeout: 10
---
body
L1EOF
expect_contains "…and the extractor can still find one when there IS one (not vacuous)" \
  'PreToolUse|Bash|${CLAUDE_PLUGIN_ROOT}/hooks/x.sh|10' "$(skill_hooks_rows "$L1_FIX")"

# THE ALWAYS-ON MANIFEST, flattened to event|matcher|command|timeout rows. The plugin
# format makes both `matcher` and `timeout` optional, and an absent key yields an empty
# field rather than a missing column, so a row is always four fields wide.
HOOKS_JSON_ROWS=$(jq -r '
  .hooks | to_entries[] | .key as $ev | .value[]
  | (.matcher // "") as $mt
  | .hooks[] | "\($ev)|\($mt)|\(.command)|\(.timeout // "")"
' "$HOOKS_JSON_SRC" 2>/dev/null)

# --- L.2 EVERY HOOK ON THE SPINE IS REGISTERED, ON THE EVENTS IT READS ---
#
# Pinned BY VALUE including the ${CLAUDE_PLUGIN_ROOT} spelling, because the manifest is
# what the harness executes: a command that reverted to a machine-local ~ path is a wall
# that cannot resolve inside an installed plugin, and it fails in the quiet direction.
#
# THE GOVERNING SKILL IS REGISTERED THREE TIMES, ON TWO EVENTS, AND THE THIRD IS NOT A
# DUPLICATE (wave-session-bound-run S4, AC-9). Its PreToolUse|Write and PreToolUse|Edit rows
# are the wall; its PostToolUse|Write row is the bind arm, which cannot live on PreToolUse
# because the fact it needs — that this Write CREATED a plan file rather than updating one —
# is only in the tool_response. One hook file, three registrations, three distinct
# event+matcher pairs, which is what §L.3 below checks it against.
#
# ENGAGE.SH IS THE ONE ROW WITH AN EMPTY MATCHER BY CHOICE RATHER THAN BY EVENT SHAPE
# (task-engaged-session, T1). UserPromptExpansion does support a matcher, on the command
# name — the docs' own matcher table says so — but the exact spelling `command_name`
# carries for a plugin-qualified typed command (with the leading slash? without?) was
# measured only from the CLI binary, never from a live payload. A matcher that misses is a
# trigger that never fires and a session that stays unengaged forever, so the name is
# filtered INSIDE the hook, where both spellings and the leading slash are all accepted and
# tests/engage.test.sh drives each one.
L2_EXPECTED='
PreToolUse|Bash|${CLAUDE_PLUGIN_ROOT}/hooks/protect-main.sh|10
PreToolUse|Bash|${CLAUDE_PLUGIN_ROOT}/hooks/protect-database.sh|10
PreToolUse|Bash|${CLAUDE_PLUGIN_ROOT}/hooks/canonical-sdlc-evidence-gate.sh|10
PreToolUse|Bash|${CLAUDE_PLUGIN_ROOT}/hooks/farm-out-reminder.sh|10
PreToolUse|TaskStop|${CLAUDE_PLUGIN_ROOT}/hooks/stop-guard.sh|10
PreToolUse|Agent|${CLAUDE_PLUGIN_ROOT}/hooks/dispatch-preflight.sh|10
PreToolUse|Write|${CLAUDE_PLUGIN_ROOT}/hooks/canonical-sdlc-governing-skill.sh|10
PreToolUse|Edit|${CLAUDE_PLUGIN_ROOT}/hooks/canonical-sdlc-governing-skill.sh|10
PostToolUse|Write|${CLAUDE_PLUGIN_ROOT}/hooks/canonical-sdlc-governing-skill.sh|10
PostToolUse|Bash|${CLAUDE_PLUGIN_ROOT}/hooks/execution-recorder.sh|10
PostToolUse|Agent|${CLAUDE_PLUGIN_ROOT}/hooks/execution-recorder.sh|10
SubagentStart||${CLAUDE_PLUGIN_ROOT}/hooks/execution-recorder.sh|10
Stop||${CLAUDE_PLUGIN_ROOT}/hooks/context-spend.sh|10
Stop||${CLAUDE_PLUGIN_ROOT}/hooks/landing-gate.sh|10
Stop||${CLAUDE_PLUGIN_ROOT}/hooks/patrol-duties-gate.sh|10
Stop||${CLAUDE_PLUGIN_ROOT}/hooks/patrol-revive.sh|10
PreToolUse|Skill|${CLAUDE_PLUGIN_ROOT}/hooks/engage.sh|10
UserPromptExpansion||${CLAUDE_PLUGIN_ROOT}/hooks/engage.sh|10
'
while IFS= read -r _row; do
  [ -n "$_row" ] || continue
  expect_contains "the manifest registers ${_row%%|*} $(printf '%s' "$_row" | cut -d'|' -f3 | sed 's|.*/||')" \
    "$_row" "$HOOKS_JSON_ROWS"
done <<L2EOF
$L2_EXPECTED
L2EOF

# --- L.3 EXACTLY ONCE PER (hook, event, matcher) ---
#
# The CLI does not deduplicate. A hook named twice on one event refuses twice, journals
# twice, or sweeps twice — which is why the two-channel arrangement this replaces went
# to such lengths to keep landing-gate's two registrations on DIFFERENT events.
# THE COMMAND IS THE SECOND-TO-LAST FIELD, never the third — the same reason §L.4b reads
# the timeout as the last field. `startup|clear|resume|compact` is a matcher that contains
# the row delimiter, so a positional read counted from the left lands mid-matcher on that
# row and the SessionStart detector would drop out of this check entirely.
L3_DUPES=$(printf '%s\n' "$HOOKS_JSON_ROWS" \
  | awk -F'|' '{ n=split($(NF-1), parts, "/"); print $1 "|" $2 "|" parts[n] }' \
  | sort | uniq -d)
expect_eq "no hook is registered twice on one event+matcher" "" "$L3_DUPES"
# The exact-set claim, over the rows this section names. Two entries are counted elsewhere
# and excluded here by name rather than by accident: the two guarded pairs belong to §L.5,
# and the SessionStart detector to §L.8, which pins its whole row by value.
expect_eq "…and the manifest carries exactly the rows this section names, and no others" \
  "$(printf '%s' "$L2_EXPECTED" | /usr/bin/grep -c '|')" \
  "$(printf '%s\n' "$HOOKS_JSON_ROWS" \
     | /usr/bin/grep -vc -e 'agent-context-guard\.sh' -e 'session-start\.sh')"

# --- L.4 EVERY registration is bounded by a timeout ---
#
# The Step-6 review's C-4: a registration with no ceiling leaves the platform default in
# front of a gate's verdict subprocess. A timeout is the safe direction here precisely
# because these gates fail open — a hook that is killed lets the turn through. Asserted
# structurally over the parsed JSON rather than over the flattened text, so a leaf
# missing its `timeout` key fails a presence count taken over ALL leaves.
L4_HJ_TOTAL=$(jq '[.hooks | to_entries[] | .value[] | .hooks[]] | length' "$HOOKS_JSON_SRC")
L4_HJ_TIMED=$(jq '[.hooks | to_entries[] | .value[] | .hooks[] | select(has("timeout"))] | length' "$HOOKS_JSON_SRC")
expect_eq "the manifest: EVERY hook entry carries a timeout key — none unbounded" \
  "$L4_HJ_TOTAL" "$L4_HJ_TIMED"
expect_eq "…each bounded by the ceiling the Step-6 review demanded: 10" "0" \
  "$(jq '[.hooks | to_entries[] | .value[] | .hooks[] | select(.timeout != 10)] | length' "$HOOKS_JSON_SRC")"

# --- L.5 THE GUARD SURVIVES WHERE ITS PURPOSE SURVIVES ---
#
# --- L.4b THE TIMEOUT IS THE LAST FIELD, NEVER THE FOURTH ---
#
# $NF, not $4 (bionic 1.4.0, slice SSTART). A row is `event|matcher|command|timeout`, and
# until the SessionStart detector arrived every matcher in this tree was a single tool
# name, so the fourth field and the last field were the same field.
# `startup|clear|resume|compact` is a matcher that CONTAINS the delimiter — the platform's
# own spelling for "all four session sources" — and under `$4` that row's timeout read as
# `resume`. The timeout is always the last field, so read it as the last field; a matcher
# may not be. The cross-CHANNEL half of this check retired with the frontmatter block:
# there is one channel now, and §L.1 asserts the other is empty.
L4B_HJ_VALUES=$(printf '%s\n' "$HOOKS_JSON_ROWS" | awk -F'|' '{print $NF}' | sort -u)
expect_eq "the manifest renders exactly one timeout value across all its rows" \
  "10" "$L4B_HJ_VALUES"

# hooks/agent-context-guard.sh runs the wall behind it only for a payload carrying a
# top-level agent_id in a session that has a roster on disk. It fronted four entries,
# and for three of them — the dispatch wall on Agent, the artifact wall on Write and
# Edit — its ONLY job was the channel partition: restrict the settings registration to
# agent contexts, because the skill channel already covered the main thread. With one
# channel there is no partition to keep, and keeping the guard there would be worse than
# redundant: it would restrict those walls to agent contexts and leave the MAIN THREAD
# uncovered, which is the reverse of what the guard was ever for.
#
# It survives on the two entries where the scope is real rather than channel-shaped:
#   background-suite-guard — refuses a subagent's BACKGROUNDED suite. It has no
#     main-thread meaning at all (farm-out-reminder already refuses a suite there), so
#     the guarded entry is the whole of its coverage.
#   landing-gate on SubagentStop — the teammate landing verdict. SubagentStop only ever
#     fires in an agent context, and the roster half of the guard is real arming.
expect_contains "the guard still fronts the BACKGROUNDED-SUITE wall on Bash" \
  'PreToolUse|Bash|${CLAUDE_PLUGIN_ROOT}/hooks/agent-context-guard.sh ${CLAUDE_PLUGIN_ROOT}/hooks/background-suite-guard.sh|' \
  "$HOOKS_JSON_ROWS"
expect_contains "…and the LANDING verdict on SubagentStop, with no matcher" \
  'SubagentStop||${CLAUDE_PLUGIN_ROOT}/hooks/agent-context-guard.sh ${CLAUDE_PLUGIN_ROOT}/hooks/landing-gate.sh|' \
  "$HOOKS_JSON_ROWS"
for _unguarded in dispatch-preflight canonical-sdlc-governing-skill; do
  expect_absent_ug "…and no longer fronts ${_unguarded}.sh, whose only reason was the partition" \
    "agent-context-guard.sh \${CLAUDE_PLUGIN_ROOT}/hooks/${_unguarded}.sh" "$HOOKS_JSON_ROWS"
done
# The wall behind the guard is the one that skips its JOURNAL in an agent context — the
# reader and the writer of BIONIC_HOOK_CHANNEL are one pair across two files, and a
# rename on either side silently restores nested rostering.
expect_contains "the guard sets the channel marker the dispatch wall reads" \
  'BIONIC_HOOK_CHANNEL=agent-context' "$(cat "$BIONIC_HOOKS_DIR/agent-context-guard.sh")"

# --- L.6 THE EVENT NAMES THE LANDING GATE ANSWERS TO ---
#
# Pinned as the SPAN that decides them rather than as a literal comparison a refactor can
# move: the relevance hoist is one `case` over `$EVENT`, and a registration whose event
# name is absent from these arms is a wall that exits before it reads anything. The gate
# now answers BOTH Stop (the orchestrator's own rows, straight) and SubagentStop (a
# teammate's, behind the guard), so both arms must be present in the script.
LG_EVENT_ARMS=$(awk '/^case "\$EVENT" in$/{f=1} f{print} f&&/^esac$/{exit}' "$PARTY_LG")
expect_eq "the landing gate's event case extracts at all (not vacuous)" "yes" \
  "$([ -n "$LG_EVENT_ARMS" ] && echo yes || echo no)"
expect_contains "…and answers Stop" "Stop" "$LG_EVENT_ARMS"
expect_contains "…and SubagentStop" "SubagentStop" "$LG_EVENT_ARMS"

# --- L.8 THE SESSIONSTART DETECTOR: one event, one channel, one owner (AC-1, SSTART) ---
#
# hooks/session-start.sh reports what `/clear` left behind — predecessor rosters, stamps,
# legacy `.bionic` links and the session-id triple — into the new conversation's context.
# It is registered ALWAYS-ON by necessity: the state it reports is left by the conversation
# that ENDED, so a registration that only binds while a skill is armed would be silent in
# exactly the session that needs it. That makes the always-on channel the right one and the
# ONLY one — a hook registered on both channels fires twice (R-2 §f), which for a detector
# means the block is pasted into context twice and a reader cannot tell the copies apart.
#
# The row is pinned BY VALUE, ${CLAUDE_PLUGIN_ROOT} spelling included, for the reason §L.3
# gives: the manifest is what the harness executes, and a command that reverted to a
# machine-local path is a hook that cannot resolve inside an installed plugin.
L8_ROWS=$(printf '%s\n' "$HOOKS_JSON_ROWS" | /usr/bin/grep -F 'session-start.sh')
expect_eq "session-start.sh is registered in hooks.json exactly once" \
  "1" "$(printf '%s\n' "$L8_ROWS" | /usr/bin/grep -c .)"
expect_eq "…on SessionStart, matching all four sources, bounded by a timeout" \
  'SessionStart|startup|clear|resume|compact|${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh|10' \
  "$L8_ROWS"
# The other half of "nowhere else": the skill frontmatter must not carry it too. Read off
# SKILL_HOOKS_ROWS, the same extractor L.1 pins the twelve armed-session rows with, so an
# empty result here means "absent from a channel this suite can still read" rather than
# "the extractor broke" — L.1's own row assertions above are what prove it still works.
expect_eq "…and NOWHERE in the skill frontmatter, which would fire it a second time" \
  "" "$(printf '%s\n' "$SKILL_HOOKS_ROWS" | /usr/bin/grep -F 'session-start.sh')"
# ONE OWNER OF THE EVENT. A second SessionStart registration would print a second block
# into the same context with no ordering guarantee between them (§L's founding finding F).
expect_eq "SessionStart carries exactly one registration in hooks.json" \
  "1" "$(printf '%s\n' "$HOOKS_JSON_ROWS" | /usr/bin/grep -c '^SessionStart|')"
# The hook the manifest names EXISTS and parses. §L.2's own header records that the
# structural "every command names a file that exists" arm died with tests/scripts.test.sh
# (8582861) and was never replaced; this row restores it for the one entry this slice adds,
# so a renamed or deleted detector fails here instead of silently never firing.
expect_eq "…and the file that row names exists and parses" "ok" \
  "$( [ -f "$BIONIC_HOOKS_DIR/session-start.sh" ] \
      && bash -n "$BIONIC_HOOKS_DIR/session-start.sh" 2>/dev/null && echo ok )"

# ============================================================
section "M — THE ACK, and the stop order: ONE owner, three consumers (epic-16 w2 S3/S9)"
# ============================================================
#
# Two facts reach the stop arc from outside it, and each has ONE writer and several readers:
#
#   the ACK   — written by `hooks/session-sweeper.sh ack`, consumed by the stop gate, the
#               landing gate and the stand-down helper. Until epic-16 wave-02 S9 each of
#               those three opened the ledger itself through a byte-identical copy of a
#               `ledger_acked()` reader, and this section pinned the three bodies against
#               each other — the §9 convention, with the drift risk that convention always
#               carries. S9 promoted the answer onto the verdict machine line as `acked=`,
#               so the ledger now has ONE reader in the fleet: the file that owns it. The
#               three consumers read a field off a line they were already invoking the verb
#               to get.
#   the ORDER — written by `hooks/stop-orders.sh order`, read by the stop gate. Writer and
#               reader each hold the validity window as a literal.
#
# Per-component suites drive each consumer against its own fixtures. What none of them can
# see is the CROSS-SCRIPT property: that no consumer carries an ack-reading of its own, that
# the window is the same number, and that all three answer the same about one ledger the
# real writer wrote — including when the single owner is mutated to lie (§M.5).

SG_M="$BIONIC_HOOKS_DIR/stop-guard.sh"
LG_M="$BIONIC_HOOKS_DIR/landing-gate.sh"
SO_M="$BIONIC_HOOKS_DIR/stop-orders.sh"

# --- M.1 ONE OWNER: no consumer reads the ledger, in any of the three ways it could ---
#
# The extractor is checked against a function that DOES survive, so an emptied `fn_body`
# result below means "the reader is gone" rather than "the extractor stopped working".

# --- M.2 one window, two holders ---
_ttl_of() { grep -E '^ORDER_TTL_SECONDS=' "$1" | head -1 | cut -d= -f2; }

# --- M.3 one ledger, written by the real ack verb, read the same by all three ---
MREPO=$(new_repo "ack-agreement")
MSLUG=$(printf '%s' "$MREPO" | sed 's/[^a-zA-Z0-9]/-/g')
MPROJ="$CLAUDE_CONFIG_DIR/projects/$MSLUG"
MSUB="$MPROJ/$SID_A/subagents"
mkdir -p "$MSUB" "$MREPO/.bionic/tmp"
MTR="$MPROJ/$SID_A.jsonl"
printf '{}\n' > "$MTR"
plant "$MSUB" "afinished-1111111111111111" "finished"
write_plan "$MREPO/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"
# A contract that will NEVER land: the artifact is not written, so every party's verdict is
# UNMET and the ack is the only thing that can discharge anything. A fixture whose contract
# landed would agree for the wrong reason.
roster_row_fixture status=confirmed session="$SID_A" name=finished \
  agent_id=afinished-1111111111111111 launched_at=2026-08-05T00:00:00Z \
  deliverable=.bionic/docs/record/never.md \
  teammate_id="finished@session-$(printf '%s' "$SID_A" | cut -c1-8)" \
  >> "$MREPO/.bionic/tmp/roster-$SID_A.state"

# The landing sweep answers for each row ONCE, ever, and journals a marker into the roster
# to keep that promise. Each of the three drives below is a separate question about the same
# fixture, so the marker is cleared first — the property under test is what the consumers
# read off ONE ledger, not the sweep's idempotency (which tests/landing-gate.test.sh owns).
MROSTER="$MREPO/.bionic/tmp/roster-$SID_A.state"
#
# THE FIXTURE ROW IS A TEAMMATE ROW — it carries a `teammate_id=`, as every row the
# completion arm writes for a named dispatch does — so the arm that answers for it is the
# SubagentStop verdict, not the Stop-sweep (which skips those rows by design: their ids are
# in a namespace `background_tasks[]` does not use, and they never leave that array anyway).
# Driving the gate through the arm that actually owns the row is what keeps this section
# about the ACK rather than about routing, and it asks the new arm the same question the
# other two consumers are asked: does one ack ledger close this row for you too.
m_sweep() {  # <gate path> -> the gate's exit status, refusal on stdout
  /usr/bin/grep -v '^landing-swept/' "$MROSTER" > "$MROSTER.tmp" 2>/dev/null
  mv "$MROSTER.tmp" "$MROSTER"
  mk_substop_payload "$MREPO" "$SID_A" "afinished-1111111111111111" finished false | bash "$1" 2>&1
}

m_vline() {  # -> the verdict machine line all three consumers read for this fixture
  ( cd "$MREPO" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SWEEPER" verdict finished 2>/dev/null ) \
    | grep -F 'landing-verdict/v1|' | head -1
}

# BEFORE the ack — all three say the row is open. This is the paired positive without which
# the three assertions after it would pass over a fixture nothing could ever block.
expect_contains "before the ack: the one line all three read says acked=no" \
  "|acked=no|" "$(m_vline)"
OUT=$(mk_stop_payload "$SID_A" "$MTR" "$MREPO" "finished" | bash "$SG_M" 2>&1); ST=$?
expect_eq "before the ack: the stop gate refuses" "2" "$ST"
OUT=$(m_sweep "$LG_M"); ST=$?
expect_eq "before the ack: the landing gate refuses" "2" "$ST"
OUT=$( cd "$MREPO" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SO_M" standdown 2>&1 )
expect_contains "before the ack: the stand-down leaves it alone" "LEFT ALONE" "$OUT"

# THE REAL WRITER writes the one file all three read.
( cd "$MREPO" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SWEEPER" ack finished ) >/dev/null 2>&1
expect_eq "the ack verb wrote its ledger where its one reader looks" "yes" \
  "$([ -f "$MREPO/.bionic/tmp/sweeper-$SID_A.state" ] && echo yes || echo no)"

# THE PROMOTION, end to end over the real writer: the same line now says acked=yes, and the
# STATE beside it did not move. The ack changed what the consumers know, not what the disk
# says — which is what "the ack's semantics are unchanged" means concretely.
M_VLINE=$(m_vline)
expect_contains "after the ack: the one line all three read says acked=yes" "|acked=yes|" "$M_VLINE"
expect_contains "…while the contract itself is still UNMET, computed from the disk alone" \
  "|state=UNMET|" "$M_VLINE"

OUT=$(mk_stop_payload "$SID_A" "$MTR" "$MREPO" "finished" | bash "$SG_M" 2>&1); ST=$?
expect_eq "after the ack: the stop gate passes" "0" "$ST"
OUT=$(m_sweep "$LG_M"); ST=$?
OUT=$( cd "$MREPO" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SO_M" standdown 2>&1 )
expect_contains "after the ack: the stand-down puts it in the batch" "1 row(s) have landed" "$OUT"
expect_contains "…addressed the way the stop primitive takes it" \
  "finished@session-$(printf '%s' "$SID_A" | cut -c1-8)" "$OUT"

# --- M.3b ONE OWNER, PROVEN BY MUTATION: blind the field, all three go back to holding ---
#
# What the three-copy pin used to buy was drift detection between the copies. With the
# copies gone that proof has to be replaced rather than dropped, and this is the stronger
# form of it: the three consumers are byte-identical copies of what ships, only the OWNER is
# mutated — to report every row unacked — and all three answers move together. A consumer
# that had kept a private reader would stay green here, which is exactly the regression
# §M.1's greps cannot catch on their own (a reader spelled some other way).
#
# The mutant is installed in its own directory beside the gates, which is how bootstrap's
# flat `hooks/*.sh` install lets each of them find its sibling — the production resolution,
# not a test seam.
MMUT="$(plant_hook_tree "$SANDBOX/ack-mutant")"
cp "$SG_M" "$MMUT/stop-guard.sh"
cp "$LG_M" "$MMUT/landing-gate.sh"
cp "$SO_M" "$MMUT/stop-orders.sh"
awk '{ if (index($0, "row_acked \"$_pname\"") > 0) $0 = "    _acked=no"
       print }' "$SWEEPER" > "$MMUT/session-sweeper.sh"
expect_contains "the mutated owner reports the acked row as unacked" "|acked=no|" \
  "$( cd "$MREPO" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$MMUT/session-sweeper.sh" verdict finished 2>/dev/null )"
OUT=$(mk_stop_payload "$SID_A" "$MTR" "$MREPO" "finished" | bash "$MMUT/stop-guard.sh" 2>&1); ST=$?
expect_eq "…and the stop gate refuses the stop it passed a moment ago" "2" "$ST"
OUT=$(m_sweep "$MMUT/landing-gate.sh"); ST=$?
expect_eq "…and the landing gate refuses it too" "2" "$ST"
OUT=$( cd "$MREPO" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$MMUT/stop-orders.sh" standdown 2>&1 )
expect_contains "…and the stand-down puts it back in LEFT ALONE" "LEFT ALONE" "$OUT"
# The shipped files were never touched: the substitution is by path, and this says so.

# --- M.4 the order: one writer, one reader, one boundary ---
_now=$(date -u +%s)
_ttl=$(_ttl_of "$SO_M")
# JUST INSIDE the window and JUST OUTSIDE it, placed by arithmetic rather than by waiting:
# a suite that slept through a thirty-minute window would not be a suite. The pair is what
# makes this an assertion about the boundary rather than about the happy path.
# A FRESH WORLD, and no ack in it: the row above is acked, so an order placed there would
# be discharged by the ack whatever the window said, and the boundary would go untested
# while looking green.
mk_order_world() {  # <label> <name> <agent-id> -> "<repo>|<transcript>"
  local repo tr slug proj sub
  repo=$(new_repo "$1")
  slug=$(printf '%s' "$repo" | sed 's/[^a-zA-Z0-9]/-/g')
  proj="$CLAUDE_CONFIG_DIR/projects/$slug"
  sub="$proj/$SID_A/subagents"
  mkdir -p "$sub" "$repo/.bionic/tmp"
  tr="$proj/$SID_A.jsonl"
  printf '{}\n' > "$tr"
  plant "$sub" "$3" "$2"
  write_plan "$repo/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"
  cg_roster_row "$repo" "$SID_A" "$2" "$3"
  printf '%s|%s\n' "$repo" "$tr"
}

IFS='|' read -r IN_REPO IN_TR <<< "$(mk_order_world "order-inside" "inside" "ainside-1111111111111111")"
( cd "$IN_REPO" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SO_M" order inside --at $((_now - _ttl + 60)) ) >/dev/null 2>&1
OUT=$(mk_stop_payload "$SID_A" "$IN_TR" "$IN_REPO" "inside" | bash "$SG_M" 2>&1); ST=$?
expect_eq "an order inside the shared window discharges the stop" "0" "$ST"

IFS='|' read -r EX_REPO EX_TR <<< "$(mk_order_world "order-expiry" "expired" "aexpired-2222222222222222")"
( cd "$EX_REPO" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SO_M" order expired --at $((_now - _ttl - 60)) ) >/dev/null 2>&1
OUT=$(mk_stop_payload "$SID_A" "$EX_TR" "$EX_REPO" "expired" | bash "$SG_M" 2>&1); ST=$?
expect_eq "an order just outside it does not — the ceremony is where it was" "2" "$ST"

# ============================================================
section "N — the wave-02 facts: one root, one vocabulary, one launch reference (S9)"
# ============================================================
#
# Six rows specified by the slices that could not add them: `record/w2-s45-wallfacts.md` §6
# (the wall and the probe became one preflight, and duplicated the root resolver a fourth
# time doing it) and `record/w2-s6-launchref.md` §6 (the launch reference stopped being
# re-stamped on resume, in a file whose readers live elsewhere). Each is a property no
# single-component suite can see, because in each case the writer and the reader are
# different scripts.
#
# WHAT IS DEFERRED, and named rather than quietly dropped: w2-s6 §6 row 3, teammate-mode
# resume driven end to end. It needs a real repeated `teammate_spawned` PostToolUse capture —
# the same payload delivered twice for one agent — and no such capture exists on disk. The
# suite's `mk_agent_post_teammate` is faithful to a SINGLE spawn (capture probe §3-A); a
# second one synthesized here would be this suite asserting against its own guess about what
# a resume looks like in that mode, which is the fixture-fidelity failure the header forbids.
# The async half of the same property IS driven, at §N.6.

# ------------------------------------------------ N.1 one loader idiom, one root, one id
#
# `resolve_project_root()` WAS an eight-copy family: the governing-skill hook held the
# origin, the evidence gate its long-standing twin, the dispatch wall and the probe took
# copies when the wall ran the probe inline, the poker and stop-orders when answering
# `--show-toplevel` was found to name a worktree's own root, the agent-context guard when
# a guard that rooted a worktree at its own tree answered "unarmed" for every agent
# context inside one, and patrol-revive when the same reasoning reached the Patrol stamp.
# Eight files, one algorithm, held together by a body-for-body pin that could only ever
# prove they had not drifted YET.
#
# THEY ARE GONE (bionic 1.4.0, slice ADOPT, spec AC-10). What is pinned instead is the
# convention that replaced them, and it has three parts, each with its own way of going
# quietly wrong: the loader block that finds the library must be ONE text in every hook
# (a hand edit to one copy), every reader must ASK for the root rather than restate it
# (a straggler keeps its own answer), and every reader must ask for the SESSION ID the
# same way (two spellings of one session make two rosters).
# The shipped paths §N's later subsections read. They named the eight resolver carriers
# before this wave; the ones that survive are the ones those subsections still drive.
DP_N="$BIONIC_HOOKS_DIR/dispatch-preflight.sh"

# expect_ne migrated onto tests/lib/assert.sh (S5a, AC-12) — same semantics, asserted the
# other way round: the value must have MOVED.

N_LOADER_LIB="$BIONIC_HOOKS_DIR/../payload/scripts/lib/loader.sh"
[ -r "$N_LOADER_LIB" ] || N_LOADER_LIB="$BIONIC_HOOKS_DIR/../scripts/lib/loader.sh"
N_BLOCK="$( . "$N_LOADER_LIB" && bionic_loader_pin )"
expect_eq "the canonical loader block extracts from lib/loader.sh (not vacuous)" "yes" \
  "$([ "$(printf '%s\n' "$N_BLOCK" | wc -l | tr -d ' ')" -gt 50 ] && echo yes || echo no)"

n_block_of() {  # <file> -> the marker-delimited span, markers inclusive
  awk '/^# --- bionic-loader\/v2 BEGIN$/{f=1} f{print} f&&/^# --- bionic-loader\/v2 END$/{exit}' "$1"
}

# THE ADOPTED SET, named rather than globbed: a glob would silently shrink to nothing if
# the marker were renamed, and this section would pass over air. session-poker.sh (the
# eighteenth hook off resolve_project_root, converted by slice POKER) and session-start.sh
# (added by slice SSTART) both carry the idiom too — verified live, byte for byte, against
# this section's own $N_BLOCK extraction — and both resolve their root through the library
# the same way every other member of this set does, so they belong in the SAME list rather
# than a sibling one (Step-6 duplication review, record/wave-1.4.0/review-duplication.md,
# ownership row 6: neither was pinned anywhere, so nothing would catch drift in either).
N_ADOPTED='protect-main protect-database canonical-sdlc-evidence-gate farm-out-reminder background-suite-guard
dispatch-preflight canonical-sdlc-governing-skill landing-gate execution-recorder stop-guard
context-spend patrol-duties-gate patrol-revive agent-context-guard preflight-probe stop-orders
session-sweeper stop-check session-poker session-start engage'
for _h in $N_ADOPTED; do
  expect_eq "$_h.sh carries the canonical loader block, byte for byte" \
    "$N_BLOCK" "$(n_block_of "$BIONIC_HOOKS_DIR/$_h.sh")"
done

# NO PRIVATE RESOLVER SURVIVES — none, not one. ADOPT converted seventeen hooks and slice
# POKER the eighteenth, so the eight-copy family is empty and this row is what keeps a
# nineteenth from being written by hand.
N_STRAGGLERS=$(/usr/bin/grep -ln '^resolve_project_root()' "$BIONIC_HOOKS_DIR"/*.sh 2>/dev/null \
  | while IFS= read -r _f; do basename "$_f"; done | sort | tr '\n' ' ' | sed 's/ $//')
expect_eq "no hook defines a private resolve_project_root any more" "" "$N_STRAGGLERS"

# EVERY READER ASKS, and since task-engaged-session that is every member without exception.
# protect-main and background-suite-guard used to be excluded here — they classified a
# command and read no root at all — but the engagement marker lives UNDER a root, so both
# now resolve one through the library like everyone else and the carve-out is gone.
for _h in $N_ADOPTED; do
  expect_eq "$_h.sh resolves its root through the library" "yes" \
    "$(/usr/bin/grep -q 'project_root "' "$BIONIC_HOOKS_DIR/$_h.sh" && echo yes || echo no)"
done

# ------------------------------------------------ §P′ THE SESSION-ID SOURCE, bound
#
# The environment value is primary and the payload is a witness (design §1, R-1). A hook
# that reads `.session_id` straight out of its payload has silently chosen the witness
# over the record — and every roster, stamp and stop address is keyed on the answer, so
# two hooks choosing differently give one session two of each. What is pinned is the
# SOURCE, not the value: every reader calls `session_id`, and any payload read that
# remains is the ARGUMENT to that call.
N_SID_READERS='agent-context-guard preflight-probe stop-orders session-sweeper stop-check
landing-gate execution-recorder dispatch-preflight patrol-revive context-spend farm-out-reminder
session-start engage patrol-duties-gate stop-guard
canonical-sdlc-evidence-gate canonical-sdlc-governing-skill protect-main protect-database
background-suite-guard'
for _h in $N_SID_READERS; do
  expect_eq "$_h.sh takes its session id from lib/session.sh" "yes" \
    "$(/usr/bin/grep -q 'session_id "' "$BIONIC_HOOKS_DIR/$_h.sh" && echo yes || echo no)"
done

# THE LIST IS COMPLETE, not just each named member correct (auditor A-1, AC-2): a static
# list can omit a real reader forever and every row above still passes silently.
# session-start.sh was exactly that member — a session_id caller this wave added,
# unpinned by this list until the line above. Derived from the tree and compared to the
# hand-written list, byte for byte — the same technique N_STRAGGLERS above uses for the
# private-resolver family.
N_SID_ACTUAL=$(/usr/bin/grep -l 'session_id "' "$BIONIC_HOOKS_DIR"/*.sh 2>/dev/null \
  | xargs -n1 basename 2>/dev/null | sed 's/\.sh$//' | sort | tr '\n' ' ' | sed 's/ $//')
N_SID_EXPECTED=$(printf '%s\n' $N_SID_READERS | sort | tr '\n' ' ' | sed 's/ $//')
expect_eq "the session-id reader roster names every hook that calls session_id, and no other" \
  "$N_SID_EXPECTED" "$N_SID_ACTUAL"


# ------------------------------------------------ §P‴ THE ENGAGEMENT-GUARD ROSTER, complete
#
# step-6 review R-7. The ownership table promised "guard line byte-identical across the
# roster" and nothing built it: the behavioural battery at §M covers four hooks of the
# fifteen, so a NEW hook shipped without the guard would deny, nudge or audit in a session
# that never invoked canonical-sdlc, and every suite would stay green. That is the same
# silent-omission class §P′ closes for the session-id readers, and it is closed the same
# way — derive the set from the tree, compare it to a hand-written roster, fail on drift in
# EITHER direction.
#
# WHY THE SHAPE AND NOT THE BYTES. The promise as written was never satisfiable: the
# fourteen guard lines legitimately differ in the root variable name (REPO, PM_REPO,
# DB_REPO, BSG_REPO, PROJECT_DIR, PROJECT_ROOT_FROM_PATH, ROOT — seven of them) and in the
# sid name, because each hook has already resolved both under its own local convention by
# the time it reaches the guard. What has to agree is the DECISION, so what is pinned here
# is the call shape — `engaged_session "$<root>" "$<sid>" || exit 0` at column 0, the
# hook's first scoping decision — not the characters.
#
# TWO ROSTERS, because two hooks read the predicate without exiting on it: session-start.sh
# uses it to choose WHICH notice to print (its whole job is to speak to a bystander) and
# session-poker.sh consults it inside the tick and adopt verbs. Their membership is pinned
# too; what they are exempt from is the `|| exit 0` shape.
N_ENGAGED_READERS='agent-context-guard background-suite-guard canonical-sdlc-evidence-gate
canonical-sdlc-governing-skill context-spend dispatch-preflight execution-recorder
farm-out-reminder landing-gate patrol-duties-gate patrol-revive protect-database
protect-main stop-guard'
N_ENGAGED_DATA='session-poker session-start'

# derive_engaged <hooks-dir> -> sorted, space-joined basenames of every hook calling the predicate
derive_engaged() {
  /usr/bin/grep -l 'engaged_session ' "$1"/*.sh 2>/dev/null \
    | xargs -n1 basename 2>/dev/null | sed 's/\.sh$//' | sort | tr '\n' ' ' | sed 's/ $//'
}

N_ENG_EXPECTED=$(printf '%s\n' $N_ENGAGED_READERS $N_ENGAGED_DATA | sort | tr '\n' ' ' | sed 's/ $//')
N_ENG_ACTUAL=$(derive_engaged "$BIONIC_HOOKS_DIR")
expect_eq "the engagement roster names every hook that calls engaged_session, and no other" \
  "$N_ENG_EXPECTED" "$N_ENG_ACTUAL"

# NOT VACUOUS: the derived set is non-empty and large enough to be the real roster.
expect_ne "…and the derivation actually found hooks (this row is not vacuous)" "" "$N_ENG_ACTUAL"

# THE CALL SHAPE, per guard member. The first `engaged_session` line in the file must be
# the guard itself, at column 0, with two `"$VAR"` arguments and `|| exit 0` — the hook's
# first scoping decision. A guard that resolved a literal, swallowed the result or exited
# non-zero would still satisfy the roster row above and fail here.
for _h in $N_ENGAGED_READERS; do
  _line=$(/usr/bin/grep -m1 'engaged_session ' "$BIONIC_HOOKS_DIR/$_h.sh" 2>/dev/null)
  case "$_line" in
    'engaged_session "$'*'" "$'*'" || exit 0') ok "$_h.sh guards on the canonical call shape" ;;
    *) no "$_h.sh guards on the canonical call shape" "first engaged_session line was: [$_line]" ;;
  esac
done

# THE DATA READERS are members of the roster and are NOT held to that shape — pinned so a
# future reader does not "fix" them into an exit.
for _h in $N_ENGAGED_DATA; do
  expect_eq "$_h.sh reads the predicate (as data, exempt from the guard shape)" "yes" \
    "$(/usr/bin/grep -q 'engaged_session ' "$BIONIC_HOOKS_DIR/$_h.sh" && echo yes || echo no)"
done

# MUTATION, both directions. A completeness row that never moves is a comment. Two doctored
# copies of the hooks directory: one with a guard DELETED (a hook silently leaves the
# roster) and one with a guard ADDED to a file the roster does not name (a new hook ships
# guarded and unlisted). The row above must disagree with the declared roster in both.
N_ENG_MUT="$SANDBOX/fx/engaged-roster"
mkdir -p "$N_ENG_MUT/drop" "$N_ENG_MUT/add"
cp "$BIONIC_HOOKS_DIR"/*.sh "$N_ENG_MUT/drop/" 2>/dev/null
cp "$BIONIC_HOOKS_DIR"/*.sh "$N_ENG_MUT/add/" 2>/dev/null
anchor "$BIONIC_HOOKS_DIR/landing-gate.sh" 'engaged_session ' 1
grep -v 'engaged_session ' "$BIONIC_HOOKS_DIR/landing-gate.sh" > "$N_ENG_MUT/drop/landing-gate.sh"
expect_ne "…and a hook that quietly loses its guard makes the roster row RED" \
  "$N_ENG_EXPECTED" "$(derive_engaged "$N_ENG_MUT/drop")"
printf 'engaged_session "$X" "$Y" || exit 0\n' > "$N_ENG_MUT/add/zz-new-wall.sh"
expect_ne "…and an unlisted NEW hook carrying the guard makes it RED too" \
  "$N_ENG_EXPECTED" "$(derive_engaged "$N_ENG_MUT/add")"

# THE PAIRED POSITIVE: the same copying, unmutated, still agrees — or both reds above are
# the `cp` and not the mutation.
mkdir -p "$N_ENG_MUT/clean"
cp "$BIONIC_HOOKS_DIR"/*.sh "$N_ENG_MUT/clean/" 2>/dev/null
expect_eq "control: an UNMUTATED copy of the hooks directory still matches the roster" \
  "$N_ENG_EXPECTED" "$(derive_engaged "$N_ENG_MUT/clean")"

# ------------------------------------------------ §P″ THE DIVERGENT-CHANNEL FIXTURE, two
# real hooks, one filename (auditor A-1, AC-2's other half)
#
# §P′ above pins the SOURCE by static grep (every reader's call site names `session_id`),
# which the revert-and-watch capture in record/wave-1.4.0/revert-and-watch.md proved
# insensitive to a change INSIDE session_id's own body — a hook that silently switched to
# preferring the payload would still grep-match `session_id "` and every §P′ row would stay
# green. Nothing before this section drives a real hook end to end with env != payload and
# checks what filename it actually touched. This does, with two independent readers over the
# SAME repo under the SAME divergence: hooks/dispatch-preflight.sh, which builds
# `patrol-<sid>.state` / `roster-<sid>.state` by interpolating session_id's resolved value
# (its `PAYLOAD_SID` variable is that resolved value, not a raw payload read — see its own
# header comment), and hooks/session-start.sh, which excludes ITS OWN roster/stamp from the
# predecessor lists it prints because they are its own. If the two disagreed about which
# session this is, they would disagree about which file is "mine" — session-start would
# print a file dispatch-preflight had just written to as though it were a stranger's.
#
# session-poker.sh was considered as the second party and rejected: its `arm` verb calls
# `session_id` with NO payload argument at all (hooks/session-poker.sh, every `SESSION_ID=
# "$(session_id)"` site) — it never reads a payload session id, so there is no divergence
# for a fixture to drive it with. Recorded here rather than left for the next reader to
# rediscover.
P2_REPO=$(new_repo "sid-divergence")
# new_repo arms SID_A, SID_B and SID_LG together (arm_patrol) — re-armed here for SID_A
# ONLY, so a reader that wrongly resolved the payload session (SID_B) hits the loud
# "never armed" refusal instead of quietly finding a stamp under the wrong name too.
rm -f "$P2_REPO/.bionic/tmp/patrol-$SID_A.state" "$P2_REPO/.bionic/tmp/patrol-$SID_B.state" \
      "$P2_REPO/.bionic/tmp/patrol-$SID_LG.state"
arm_patrol "$P2_REPO" "$SID_A"
write_plan "$P2_REPO/.bionic/docs/plans/epic-p2/wave-01.md" "current: 4"
{
  printf '# bionic environment attestation — machine-local, safe to delete\n'
  printf 'version=1\nkind=preflight-attestation\n'
  printf 'session_id=%s\nwritten_at=1785790000\nrepo=%s\n' "$SID_A" "$P2_REPO"
} > "$P2_REPO/.bionic/tmp/preflight-$SID_A.state"

# READER 1 — the dispatch wall, driven with env=A / payload=B. Its OWN call site
# suppresses session_id's stderr (`session_id "$(_jq '.session_id')" 2>/dev/null`,
# hooks/dispatch-preflight.sh) — deliberately, per plan Assumption ADOPT/3: every hook
# but session-start.sh silences the divergence line so it does not land on every tool
# call of a divergent session, and session-start's SessionStart block is the one place
# it is designed to surface. So the wall's own stderr must stay silent about it; reader
# 2 below is where the line is expected.
P2_ERR=$(mk_agent_payload "$SID_B" "$P2_REPO" \
  | env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PARTY_DP" 2>&1 >/dev/null); P2_ST=$?
expect_eq "P2 the dispatch wall passes a well-formed dispatch under a divergent session" \
  "0" "$P2_ST"
expect_absent "P2 …its own call site suppresses the divergence line (ADOPT/3), by design" \
  "session-id:" "$P2_ERR"
expect_eq "P2 reader 1 (the dispatch wall) journalled the launch under the ENV session's roster" \
  "yes" "$([ -f "$P2_REPO/.bionic/tmp/roster-$SID_A.state" ] && echo yes || echo no)"
expect_eq "P2 …never under the payload session's" \
  "no" "$([ -e "$P2_REPO/.bionic/tmp/roster-$SID_B.state" ] && echo yes || echo no)"

# READER 2 — session-start, driven with the SAME env=A / payload=B, over the SAME repo.
# It never prints its own roster/stamp filename; it EXCLUDES them from the predecessor
# lists it prints, because they are its own. `roster-A.state` is a real file now (reader 1
# just wrote it) and carries one open row, so agreement means session-start does NOT list
# it as a predecessor — disagreement means it would, with an open-row count attached.
P2_SS_OUT=$(printf '{"session_id":"%s","transcript_path":"/irrelevant.jsonl","cwd":"%s","hook_event_name":"SessionStart","source":"resume"}' \
    "$SID_B" "$P2_REPO" \
  | env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$BIONIC_HOOKS_DIR/session-start.sh" 2>&1)
expect_absent "P2 reader 2 (session-start) treats roster-A as ITS OWN, not a predecessor" \
  "roster-$SID_A.state" "$P2_SS_OUT"
expect_contains "P2 …and its own printed triple names the ENV value as CUR, agreeing with reader 1" \
  "env=$SID_A" "$P2_SS_OUT"
expect_contains "P2 …session-start is the ONE reader that does not suppress the divergence line" \
  "session-id: payload $SID_B" "$P2_SS_OUT"

# DIFFERENTIAL CONTROL — env UNSET: both readers fall back to the payload (design §1's
# second clause), and must now agree on B instead of A. Without this arm the two checks
# above could pass for a reader that always answers "the env value" as a constant, never
# actually reading either channel.
P2C_REPO=$(new_repo "sid-divergence-ctrl")
rm -f "$P2C_REPO/.bionic/tmp/patrol-$SID_A.state" "$P2C_REPO/.bionic/tmp/patrol-$SID_B.state" \
      "$P2C_REPO/.bionic/tmp/patrol-$SID_LG.state"
arm_patrol "$P2C_REPO" "$SID_B"
write_plan "$P2C_REPO/.bionic/docs/plans/epic-p2c/wave-01.md" "current: 4"
{
  printf '# bionic environment attestation — machine-local, safe to delete\n'
  printf 'version=1\nkind=preflight-attestation\n'
  printf 'session_id=%s\nwritten_at=1785790000\nrepo=%s\n' "$SID_B" "$P2C_REPO"
} > "$P2C_REPO/.bionic/tmp/preflight-$SID_B.state"
P2C_ST=$(mk_agent_payload "$SID_B" "$P2C_REPO" \
  | env CLAUDE_CODE_SESSION_ID="" bash "$PARTY_DP" >/dev/null 2>&1; echo $?)
expect_eq "P2c control: env unset, the wall falls back to the payload session" \
  "0" "$P2C_ST"
expect_eq "P2c …and journals it under the PAYLOAD session's roster this time" \
  "yes" "$([ -f "$P2C_REPO/.bionic/tmp/roster-$SID_B.state" ] && echo yes || echo no)"
P2C_SS_OUT=$(printf '{"session_id":"%s","transcript_path":"/irrelevant.jsonl","cwd":"%s","hook_event_name":"SessionStart","source":"resume"}' \
    "$SID_B" "$P2C_REPO" \
  | env CLAUDE_CODE_SESSION_ID="" bash "$BIONIC_HOOKS_DIR/session-start.sh" 2>&1)
expect_absent "P2c reader 2 also treats roster-B as ITS OWN under the fallback" \
  "roster-$SID_B.state" "$P2C_SS_OUT"

# --------------------------------------------------- N.2 one root, one ANSWER, on disk
#
# Bodies being equal was a claim about text. This is the claim about the ANSWER, taken
# where the field case took it: inside a real `git worktree add`, which is the input that
# separates a resolver that maps a worktree onto its main repository from one that does
# not. There is one implementation now, so what this drives is the library itself —
# and §N.1 above is what ties every hook to it.
NREPO="$SANDBOX/fx/nroot/repo"
mkdir -p "$NREPO/.bionic"
git -C "$NREPO" init -q 2>/dev/null
git -C "$NREPO" config user.email t@example.com
git -C "$NREPO" config user.name "T"
echo seed > "$NREPO/README.md"
git -C "$NREPO" add README.md >/dev/null 2>&1
git -C "$NREPO" commit -qm seed >/dev/null 2>&1
NWT="$SANDBOX/fx/nroot/wt"
git -C "$NREPO" worktree add -q -b n-root-wt "$NWT" >/dev/null 2>&1
NMAIN=$(cd "$NREPO" && pwd -P)

N_ROOT_LIB="$BIONIC_HOOKS_DIR/../payload/scripts/lib/root.sh"
[ -r "$N_ROOT_LIB" ] || N_ROOT_LIB="$BIONIC_HOOKS_DIR/../scripts/lib/root.sh"
root_at() {  # <cwd> -> project_root's answer from inside that directory
  ( . "$N_ROOT_LIB" || exit 1; cd "$1" 2>/dev/null || exit 1; project_root ) 2>/dev/null
}
root_at_path() {  # <path, which need not exist> -> project_root's answer for it
  ( . "$N_ROOT_LIB" || exit 1; project_root "$1" ) 2>/dev/null
}

expect_eq "a linked worktree cwd roots at the MAIN repository" "$NMAIN" "$(root_at "$NWT")"
expect_eq "…and the main repository roots at itself" "$NMAIN" "$(root_at "$NREPO")"
# DEEP INSIDE A DIRECTORY THAT DOES NOT EXIST YET — the shape a PreToolUse gate meets on
# the first artifact write into a project, where the climb to the nearest existing
# ancestor is the part of the resolver that has to answer.
expect_eq "…and so does a path deep inside the worktree that has not been created yet" \
  "$NMAIN" "$(root_at_path "$NWT/deep/not/created/yet")"

# THE PAIRED NEGATIVE, and a precondition it depends on. Outside any repository and with no
# `.bionic` anywhere above, the answer is the path itself. That second half is a fact about
# the MACHINE, not the code: $SANDBOX lives under $TMPDIR, which every bionic suite on this
# machine shares, and the walk climbs to `/` looking for a `.bionic`. Measured 2026-08-23: a
# stray `$TMPDIR/.bionic/` left by a SIBLING suite turned this battery red 7-of-7, naming
# neither the leak nor the leaker. This row measures the precondition first and says which
# directory is dirty — it cannot make the battery immune, but it turns mysterious diffs into
# one legible line.
NOUT="$SANDBOX/fx/nroot/notarepo"
mkdir -p "$NOUT"
NOUT_DIRTY=""
_anc="$NOUT"
while [ -n "$_anc" ] && [ "$_anc" != "/" ] && [ "$_anc" != "." ]; do
  if [ -d "$_anc/.bionic" ]; then NOUT_DIRTY="$_anc"; fi
  _anc=$(dirname "$_anc")
done
expect_eq "no ancestor of the fallback fixture carries a stray .bionic (shared \$TMPDIR)" \
  "" "$NOUT_DIRTY"
expect_eq "outside any repository, with no .bionic above, the answer is the path itself" \
  "$(cd "$NOUT" && pwd -P)" "$(root_at "$NOUT")"

# THE NO-GIT ARM, which the two git-derived checks above never reach. NBWS is a workspace
# carrying a real `.bionic/` that was never `git init`'d — the shape a repo nested under a
# workspace makes, and the one the old resolvers got wrong by answering the git root.
NBWS="$SANDBOX/fx/nroot/bws"
mkdir -p "$NBWS/.bionic/docs/record" "$NBWS/sub/deep"
expect_eq "a non-git workspace holding .bionic roots at the workspace" "$(cd "$NBWS" && pwd -P)" \
  "$(root_at "$NBWS/sub/deep")"

# MUTATION, the discriminator: drop the worktree mapping from a copy of the library and
# the worktree answers itself — the pre-R9 behaviour, and the one that made a worktree its
# own address space. Without this the section proves only that a function exists.
N_MUT_ROOT="$SANDBOX/fx/rootless-root.sh"
anchor "$N_ROOT_LIB" '--git-common-dir' 3
awk '{ if (index($0, "--git-common-dir") > 0) sub(/--git-common-dir/, "--git-dir"); print }' \
  "$N_ROOT_LIB" > "$N_MUT_ROOT"
N_MUT_ANSWER=$( ( . "$N_MUT_ROOT" || exit 1; cd "$NWT" 2>/dev/null || exit 1; project_root ) 2>/dev/null )
expect_ne "…and the mutated library no longer answers the main repository" "$NMAIN" "$N_MUT_ANSWER"

# ------------------------------------------- N.3 producer and consumer, one attestation path
#
# w2-s45 §6 row 2. The probe WRITES the attestation and the dispatch wall READS it, and since
# R5 the wall runs the probe itself when it finds none. From a worktree cwd those two paths
# are only equal because both sides resolve the root the same way — the inequality that would
# silently re-break the combined preflight, and it would present as a wall that auto-probes on
# every single dispatch while an attestation sits on disk one directory over.
#
# The credential is pinned PRESENT (a syntactic placeholder — the probe tests presence, never
# validity) for the reason §D records: unpinned, the probe consults the machine login keychain
# and the drive lands on the refused path or the accepted one depending on whose machine runs
# the suite. Only the accepted path writes anything, which is the path under test here.
write_plan "$NREPO/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"
# Hand-built fixture, so it arms explicitly — under the MAIN repository, which is also the
# only place the arming wall reads from a worktree cwd (the property N.1/N.2 measure).
arm_patrol "$NREPO" "$SID_A"
NENV=(env HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR"
      ANTHROPIC_API_KEY="pinned-placeholder-not-a-credential")

( cd "$NWT" && "${NENV[@]}" CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PROBE" ) >/dev/null 2>&1
NATT="$NREPO/.bionic/tmp/preflight-$SID_A.state"
expect_eq "the PRODUCER, run from the worktree, writes under the main repository" "yes" \
  "$([ -f "$NATT" ] && echo yes || echo no)"
expect_eq "…and leaves no phantom .bionic in the worktree (R9: one address space)" "no" \
  "$([ -e "$NWT/.bionic" ] && echo yes || echo no)"

# THE CONSUMER, from the same worktree cwd. It must FIND that record — the observable is the
# absence of the auto-probe announce line, which the wall prints only when it had to take an
# attestation of its own. A wall that looked in the worktree would announce every time.
#
# THE PAYLOAD IS AN AGENT'S (bionic 1.4.0, spec AC-14, slice WALLS). This section's subject is
# the ADDRESS SPACE — producer and consumer resolving one root from a worktree cwd — and the
# dispatch that legitimately happens there is a dispatched writer's, working in the tree it was
# given. A MAIN-THREAD dispatch from a worktree is now the refusal N.3b drives below, so the
# drives here carry `agent_type`, the spelling the harness puts in a dispatched agent's own
# payload. Deliberately not BIONIC_HOOK_CHANNEL, which is the other spelling of the same fact
# and additionally stops the ledger at depth one — the roster assertion two lines down is what
# this section came for.
N_AGENT_PAYLOAD() { mk_agent_payload "$SID_A" "$NWT" | jq '. + {agent_type:"implementor"}'; }
N_OUT=$(N_AGENT_PAYLOAD | "${NENV[@]}" bash "$PARTY_DP" 2>&1); N_ST=$?
expect_eq "the CONSUMER, from the same worktree, passes the dispatch" "0" "$N_ST"
expect_eq "…and its roster row landed under the main repository too" "yes" \
  "$([ -f "$NREPO/.bionic/tmp/roster-$SID_A.state" ] && echo yes || echo no)"
expect_eq "…with no phantom .bionic in the worktree from the gate either" "no" \
  "$([ -e "$NWT/.bionic" ] && echo yes || echo no)"

# THE DISCRIMINATING HALF: remove the record and the same dispatch announces. Without it the
# assertions above would pass over a wall that had simply stopped announcing anything.
rm -f "$NATT"
N_OUT=$(N_AGENT_PAYLOAD | "${NENV[@]}" bash "$PARTY_DP" 2>&1); N_ST=$?
expect_eq "with the record gone the dispatch still passes (R5: attestation never blocks)" "0" "$N_ST"
expect_eq "…writing it back to the same path the consumer reads" "yes" \
  "$([ -f "$NATT" ] && echo yes || echo no)"

# ------------------------------------------- N.3b the lease wall, on the same one address space
#
# Spec AC-14, slice WALLS. Everything above proves that a worktree cwd and the main checkout
# resolve to ONE address space; this is what the gate now does with that fact. A main-thread
# dispatch made from inside a linked worktree is refused and NAMES the main checkout — the
# same root N.1 measured — while the agent payload three lines up passes through the same
# wall. Asserted here rather than only in tests/dispatch-preflight.test.sh because the root
# in the refusal is the library's answer, which is this suite's whole subject.
N_LEASE_OUT=$(mk_agent_payload "$SID_A" "$NWT" | "${NENV[@]}" bash "$PARTY_DP" 2>&1); N_LEASE_ST=$?
expect_eq "a MAIN-THREAD dispatch from the same worktree is refused (AC-14)" "2" "$N_LEASE_ST"
expect_contains "…naming the main checkout the library already resolves to" \
  "main checkout: $NMAIN" "$N_LEASE_OUT"

# --------------------------------------------------- N.4 source=: one word, and one reader
#
# w2-s45 §6 row 3, RE-EXPRESSED at R1 (inference withdrawn — plan assumption 48). Wave-02 R4
# let `hooks/dispatch-preflight.sh` write `source=inferred` for a deliverable it GUESSED from
# prose; the Step-6 critic (N-1) showed the guess was then enforced with a declared fact's
# full weight, so Chris withdrew inference. The wall now writes `source=` with exactly one
# non-empty value, `declared`. `hooks/session-sweeper.sh` is still its only reader, branching
# on `!= "inferred"` — a branch that is now always true (no writer emits `inferred`), harmless,
# and left in place because touching the sweeper is outside R1's file set. One word, one reader.
N_SRC_VALUES=$(grep -oE '^[[:space:]]*C_SOURCE="[a-z]*"' "$DP_N" \
  | sed -E 's/.*"([a-z]*)"/\1/' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')

# Driven, not just grepped: three briefs, three routes to a path, and what the writer does with
# each now that it never guesses. A LABELED slot-free path is `declared` and lands; an UNLABELED
# prose path and a TEMPLATED `<slot>` are both REFUSED at dispatch (exit 2, no roster row) —
# the withdrawal, asserted from the writer's own output in the paired exit-AND-inventory shape.
NSRC=$(new_repo "source-vocab")
write_plan "$NSRC/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"
# Run in the CURRENT shell (never a command-substitution subshell) so the wall's own exit
# code survives to the assertion; read the roster row in a separate step.
n_dispatch() {  # <name> <prompt> — runs the wall in this shell; its exit is the function's exit
  jq -n --arg s "$SID_A" --arg c "$NSRC" --arg n "$1" --arg p "$2" \
    '{session_id:$s, transcript_path:"/irrelevant.jsonl", cwd:$c,
      hook_event_name:"PreToolUse", tool_name:"Agent",
      tool_input:{description:"a dispatch", subagent_type:"implementor", name:$n, prompt:$p},
      tool_use_id:("toolu_01" + $n)}' \
    | "${NENV[@]}" bash "$PARTY_DP" >/dev/null 2>&1
}
n_row() { grep -F "|name=$1|" "$NSRC/.bionic/tmp/roster-$SID_A.state" 2>/dev/null | tail -1; }

n_dispatch declaring 'Expected artifact: .bionic/docs/record/declared.md
Suites: tests/widget.test.sh'; N_ST=$?
expect_eq "a LABELED slot-free path passes the wall" "0" "$N_ST"
expect_contains "…and records source=declared" "|source=declared|" "$(n_row declaring)"
n_dispatch inferring 'the notes go in .bionic/docs/record/inferred.md when done'; N_ST=$?
expect_eq "an UNLABELED record/ path is REFUSED at dispatch (no inference)" "2" "$N_ST"
n_dispatch filling 'Expected artifact: .bionic/docs/record/<name>.md'; N_ST=$?
expect_eq "a TEMPLATED <slot> path is REFUSED at dispatch (no fill)" "2" "$N_ST"

# ------------------------------------------------- N.5 the ghost row, asked of every writer
#
# w2-s45 §6 row 4. AC-12's "a refused dispatch leaves no row" is pinned in the wall's own
# suite, where the wall is the only writer in the room. The roster has THREE writers, and the
# other two are stop-side: a refused dispatch that later drew a row from `execution-recorder`
# would be a ghost with a different author, invisible to the wall's own before/after check.
#
# The recorder's two roster arms both key on a row the LAUNCH half wrote — ARM 2 on a matching
# `intended` row for the tool_use_id, ARM 3 on a matching intended/confirmed row for the name.
# A refused dispatch wrote neither, so both must find nothing and write nothing. In the field
# the tool call never runs at all (the wall exits 2), which is exactly why the defensive
# question is worth asking here rather than assuming the ordering holds.
NGH=$(new_repo "ghost-row")
write_plan "$NGH/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"
mkdir -p "$NGH/.bionic/tmp"
# A brief naming NO inferable deliverable: the one shape R4 still refuses (AC-3's planted
# failure), and therefore the one that reaches this section with a refusal to leave no trace.
N_REFUSED=$(jq -n --arg s "$SID_A" --arg c "$NGH" \
  '{session_id:$s, transcript_path:"/irrelevant.jsonl", cwd:$c,
    hook_event_name:"PreToolUse", tool_name:"Agent",
    tool_input:{description:"a dispatch", subagent_type:"implementor", name:"ghosted",
                prompt:"Go and do the thing. Report back when you are finished."},
    tool_use_id:"toolu_01GHOST"}')
printf '%s' "$N_REFUSED" | "${NENV[@]}" bash "$PARTY_DP" >/dev/null 2>&1
N_WALL_ST=$?
expect_eq "the wall refuses a brief naming no inferable deliverable" "2" "$N_WALL_ST"
N_INV_BEFORE=$(cat "$NGH/.bionic/tmp/roster-$SID_A.state" 2>/dev/null; echo "[no roster]")

# Now both stop-side writers, for the dispatch that never happened.
jq -n --arg s "$SID_A" --arg c "$NGH" \
  '{session_id:$s, transcript_path:"/irrelevant.jsonl", cwd:$c,
    hook_event_name:"PostToolUse", tool_name:"Agent",
    tool_input:{description:"a dispatch", prompt:"go", subagent_type:"implementor",
                run_in_background:true, name:"ghosted"},
    tool_response:{isAsync:true, status:"async_launched", agentId:"aghosted-1111111111111111"},
    tool_use_id:"toolu_01GHOST"}' | bash "$PARTY_ER" >/dev/null 2>&1
mk_start_payload "$SID_A" "/irrelevant.jsonl" "$NGH" "ghosted" "aghosted-1111111111111111" \
  | bash "$PARTY_ER" >/dev/null 2>&1
N_INV_AFTER=$(cat "$NGH/.bionic/tmp/roster-$SID_A.state" 2>/dev/null; echo "[no roster]")

# THE PAIRED POSITIVE, over the identical machinery: an ACCEPTED dispatch draws exactly one
# row from the wall and one more from each stop-side arm. Without it the three assertions
# above would pass over a recorder that had stopped writing rows at all.
printf '%s' "$N_REFUSED" \
  | jq '.tool_input.prompt = "Expected artifact: .bionic/docs/record/accepted.md\nSuites: tests/widget.test.sh"
        | .tool_input.name = "accepted" | .tool_use_id = "toolu_01ACCEPT"' \
  | "${NENV[@]}" bash "$PARTY_DP" >/dev/null 2>&1
expect_eq "an accepted dispatch draws exactly one row from the wall" "1" \
  "$(grep -cF '|name=accepted|' "$NGH/.bionic/tmp/roster-$SID_A.state" 2>/dev/null)"
jq -n --arg s "$SID_A" --arg c "$NGH" \
  '{session_id:$s, transcript_path:"/irrelevant.jsonl", cwd:$c,
    hook_event_name:"PostToolUse", tool_name:"Agent",
    tool_input:{description:"a dispatch", prompt:"go", subagent_type:"implementor",
                run_in_background:true, name:"accepted"},
    tool_response:{isAsync:true, status:"async_launched", agentId:"aaccepted-2222222222222222"},
    tool_use_id:"toolu_01ACCEPT"}' | bash "$PARTY_ER" >/dev/null 2>&1
expect_eq "…and the recorder advances it rather than ignoring the roster" "1" \
  "$(grep -cF '|status=confirmed|' "$NGH/.bionic/tmp/roster-$SID_A.state" 2>/dev/null)"

# ------------------------------------- N.6 the launch reference: written once, read by three
#
# w2-s6 §6 rows 1 and 2, driven as one arc because they are two halves of one property. The
# roster row is written by `hooks/dispatch-preflight.sh`, carried forward and pinned by
# `hooks/execution-recorder.sh`, and DATED AGAINST by `hooks/session-sweeper.sh` — three
# scripts, one field, and S6 could only prove the middle one from inside its own suite.
#
# THE FIELD-SHAPE HALF FIRST (row 2), because the rest is meaningless without it: a silent
# rename of `launched_at=` at the writer would make the pin scan for a key that no longer
# exists and FAIL OPEN — find nothing, treat every resume as a new agent, restore the exact
# bug S6 fixed, and stay green everywhere. This is what makes that rename fail loud.
# THE KEYS COME FROM THE WRITER, DRIVEN — not from a format string read out of the hook.
# Until S14 this scraped `ROW="roster-state/` from `hooks/dispatch-preflight.sh`, which is
# how it could report "the mutation target matched nothing" the moment the row moved. The
# row now has one writer, `roster_row` (payload/scripts/lib/roster.sh), and the honest way to
# ask what keys it emits is to run it. `$( … )` is a subshell, so the library never leaks
# into the rest of this suite and a mutated copy is a real substitution.
N_ROSTER_LIB="$BIONIC_HOOKS_DIR/../payload/scripts/lib/roster.sh"
[ -r "$N_ROSTER_LIB" ] || N_ROSTER_LIB="$BIONIC_HOOKS_DIR/../scripts/lib/roster.sh"
n_row_keys() {  # <library> -> the keys the row carries, in order, as the writer emits them
  ( . "$1" >/dev/null 2>&1 && roster_row status=probe ) \
    | tr '|' '\n' | sed -n 's/^\([a-z_]*\)=.*/\1/p' | tr '\n' ' ' | sed 's/ $//'
}
N_KEYS=$(n_row_keys "$N_ROSTER_LIB")
expect_contains "the writer's row carries launched_at at all" "launched_at" "$N_KEYS"
# Proven loud by mutation: rename the key at the writer and the assertion above is the one
# that goes red — a suite failure, not a silent fail-open at 3am. Only the EMITTED field is
# renamed (`|launched_at=`, which appears once, in the row `roster_row` builds); renaming the
# variable too would leave the mutant unable to run and prove nothing about the key.
mkdir -p "$SANDBOX/fx"
N_MUT_LIB="$SANDBOX/fx/renamed-roster.sh"
sed 's/|launched_at=/|launchedat=/' "$N_ROSTER_LIB" > "$N_MUT_LIB"
if cmp -s "$N_ROSTER_LIB" "$N_MUT_LIB"; then
  no "the launched_at rename applies to the roster writer" \
     "the mutation target matched nothing — the row moved and this proof is vacuous"
else
  ok "the launched_at rename applies to the roster writer"
fi
# AND THE KEY REALLY LEAVES THE ROW. The `cmp` above only says the edit landed somewhere;
# this says the writer stopped emitting the field, which is the state that would fail open.
N_MUT_KEYS="$(n_row_keys "$N_MUT_LIB")"
expect_eq "…and the mutant's row no longer carries launched_at at all" "0" \
  "$(printf '%s\n' "$N_MUT_KEYS" | tr ' ' '\n' | LC_ALL=C grep -c '^launched_at$' | tr -d ' ')"
# Non-vacuity: the same count over the SHIPPED writer's keys is one, so the zero above is a
# fact about the mutant and not about the counting.
expect_eq "…while the shipped writer's row carries it exactly once" "1" \
  "$(printf '%s\n' "$N_KEYS" | tr ' ' '\n' | LC_ALL=C grep -c '^launched_at$' | tr -d ' ')"

# THE END-TO-END HALF (row 1): every writer real, every reader real, and the observable is the
# VERDICT rather than the roster row — which is the gap S6's own suite could not close, since
# it owns the recorder and not the thing that reads it.
NLR=$(new_repo "launch-ref")
write_plan "$NLR/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"
NLR_ART="$NLR/.bionic/docs/record/resumed.md"
mkdir -p "$NLR/.bionic/docs/record"
NLR_ID="aresumed-3333333333333333"

n_cycle() {  # <tool_use_id> — one full dispatch cycle through all three real hooks
  jq -n --arg s "$SID_A" --arg c "$NLR" --arg u "$1" --arg d "$NLR_ART" \
    '{session_id:$s, transcript_path:"/irrelevant.jsonl", cwd:$c,
      hook_event_name:"PreToolUse", tool_name:"Agent",
      tool_input:{description:"a dispatch", subagent_type:"implementor", name:"resumed",
                  prompt:("Expected artifact: " + $d + "\nSuites: tests/widget.test.sh")},
      tool_use_id:$u}' | "${NENV[@]}" bash "$PARTY_DP" >/dev/null 2>&1
  jq -n --arg s "$SID_A" --arg c "$NLR" --arg u "$1" --arg a "$NLR_ID" \
    '{session_id:$s, transcript_path:"/irrelevant.jsonl", cwd:$c,
      hook_event_name:"PostToolUse", tool_name:"Agent",
      tool_input:{description:"a dispatch", prompt:"go", subagent_type:"implementor",
                  run_in_background:true, name:"resumed"},
      tool_response:{isAsync:true, status:"async_launched", agentId:$a},
      tool_use_id:$u}' | bash "$PARTY_ER" >/dev/null 2>&1
  mk_start_payload "$SID_A" "/irrelevant.jsonl" "$NLR" "resumed" "$NLR_ID" \
    | bash "$PARTY_ER" >/dev/null 2>&1
}
n_state() {  # -> the verdict's state for the row, over the live roster
  ( cd "$NLR" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SWEEPER" verdict resumed 2>/dev/null ) \
    | grep -F 'landing-verdict/v1|' | head -1 | tr '|' '\n' | grep '^state=' | cut -d= -f2-
}
n_latest_row() {  # -> the last row the real recorder wrote for this name
  grep -F '|name=resumed|' "$NLR/.bionic/tmp/roster-$SID_A.state" | tail -1
}
# THE READER, ASKED ABOUT ONE ROW. The row handed over is the REAL recorder's own output
# line, copied verbatim onto a fresh roster — not a hand-built fixture — because the
# discriminating question here is what a reader makes of the row the resume produced, and on
# the live roster that same reader answers AMBIGUOUS about the NAME (see below) whatever the
# row says. This is `latest_rows`' fold with the two-contract count removed, and nothing else.
n_state_of_row() {  # <roster row> -> the verdict's state for it alone
  local d="$SANDBOX/fx/lr-fold"
  rm -rf "$d"; mkdir -p "$d/.bionic/tmp"
  git -C "$d" init -q 2>/dev/null
  roster_header \
    > "$d/.bionic/tmp/roster-$SID_A.state"
  printf '%s\n' "$1" >> "$d/.bionic/tmp/roster-$SID_A.state"
  ( cd "$d" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SWEEPER" verdict resumed 2>/dev/null ) \
    | grep -F 'landing-verdict/v1|' | head -1 | tr '|' '\n' | grep '^state=' | cut -d= -f2-
}

n_cycle toolu_01CYCLEA
# THE ROSTER IS AGED, and only the roster: both cycles would otherwise be stamped in the same
# second and there would be no difference for the pin to preserve. An hour between a dispatch
# and its resume is the field case's own shape (`record/w1-rc-verify-floor.md` §Amendment-2),
# and every hook that reads these rows below is the real one reading a real row.
N_T0=$(date -u -v-3600S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-3600 seconds" +%Y-%m-%dT%H:%M:%SZ)
sed -i.bak -E "s/launched_at=[^|]*/launched_at=$N_T0/" "$NLR/.bionic/tmp/roster-$SID_A.state"
rm -f "$NLR/.bionic/tmp/roster-$SID_A.state.bak"
# The takeover's delivery: written between the original launch and the resume, which is the
# artifact the field case's landing gate called missing.
echo "the takeover wrote this" > "$NLR_ART"
touch -t "$(date -v-1800S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-1800 seconds" +%Y%m%d%H%M.%S)" "$NLR_ART"
expect_eq "before the resume, the delivered contract reads MET" "MET" "$(n_state)"

n_cycle toolu_01CYCLEB
N_RESUMED_ROW=$(n_latest_row)
expect_eq "the resume kept the ORIGINAL launch reference, through the real hooks" "$N_T0" \
  "$(printf '%s' "$N_RESUMED_ROW" | tr '|' '\n' | grep '^launched_at=' | cut -d= -f2-)"
expect_eq "…and appended its own row rather than rewriting one" "2" \
  "$(grep -cF '|status=identified|' "$NLR/.bionic/tmp/roster-$SID_A.state")"
expect_eq "…so the reader still calls the delivered contract MET over that row" \
  "MET" "$(n_state_of_row "$N_RESUMED_ROW")"

# WHAT THE LIVE ROSTER SAYS, and it is not MET — recorded here because it is the thing no
# component suite could see, and because the honest answer is worth more than a green line.
#
# A resume through the real hook path is a SECOND Agent-tool cycle, so it writes a second
# `tool_use_id` under one name, and `verdict` counts contracts by distinct tool_use_id
# (wave-01 Step-6 review C-2: two dispatches sharing a name are indistinguishable to every
# reader downstream). The name therefore reads AMBIGUOUS, not MET, and no row is judged.
#
# THE FAIL DIRECTION IS THE SAFE ONE and that is why this is pinned rather than fixed here:
# the landing gate PASSES an AMBIGUOUS name (§J's `dup` row), so R6 holds — work delivered
# before a resume still cannot be read as undelivered, and the gate still cannot manufacture
# an UNMET over an artifact that exists. What is lost is only the sharpness of AC-5's "yields
# MET": through this route it yields "not judged". Reconciling C-2's contract count with S6's
# resume (same agent id, two tool_use_ids — arguably ONE contract resumed, not two dispatched)
# is a change to a wave-01 remediation and to S6's own keying rule, which is a cross-slice
# decision this slice surfaces rather than takes.
expect_eq "on the LIVE roster the resumed name reads AMBIGUOUS, not MET (recorded finding)" \
  "AMBIGUOUS" "$(n_state)"

# THE DISCRIMINATING HALF, by mutation of the middle party: with the override removed the
# resume re-stamps, the artifact predates the fresh stamp, and the verdict manufactures the
# UNMET the field case actually suffered. This is the assertion that proves the three above
# are about the pin rather than about a fixture that could never have failed.
N_MUT_ER="$SANDBOX/fx/unpinned-recorder.sh"
awk '{ if (index($0, "PRIOR_LAUNCH=$(prior_launch_for_agent") > 0)
         sub(/prior_launch_for_agent/, "true prior_launch_for_agent")
       print }' "$BIONIC_HOOKS_DIR/execution-recorder.sh" > "$N_MUT_ER"
n_saved_er="$PARTY_ER"; PARTY_ER="$N_MUT_ER"
n_cycle toolu_01CYCLEC
N_UNPINNED_ROW=$(n_latest_row)
expect_eq "…and the reader then calls the SAME delivered artifact stale — the field case" \
  "UNMET" "$(n_state_of_row "$N_UNPINNED_ROW")"
PARTY_ER="$n_saved_er"

# ============================================================
section "O — session-poker's copied primitives, CODE-identical (6-axis D-1)"
# ============================================================
#
# hooks/session-poker.sh's own header declared five functions "DELIBERATELY DUPLICATED from
# hooks/session-sweeper.sh, byte for byte" and called parse_seconds's copy "verbatim" —
# rd review D-1 (blocking-grade): nothing anywhere compared a single copy, and the
# "verbatim" claim was already false. `parse_seconds`'s SWEEPER copy carries nine lines of
# internal rationale comments (why "0.5h" and "1h30m" are refused) that the POKER copy
# drops, because that rationale describes the sweeper's own history — reading `cadence=` —
# which this script never does; it reads `duration=` instead. The §I.1 precedent this loop
# follows already excludes SIGNATURE comments from its body comparison ("each file explains
# its copy in its own terms"); this loop goes one step further and excludes every
# pure-comment line inside the body too, because parse_seconds is the one primitive here
# whose internal comments are legitimately script-specific. What must not drift silently is
# the EXECUTABLE TEXT, so that is what is compared — epic-16 w2 Step-6 remediation R3, and
# the two header comments this closes (session-poker.sh:84-88, :109-111) now say exactly
# this: code-identical, not byte-identical (R-3).
SPO="$BIONIC_HOOKS_DIR/session-poker.sh"

fn_code() {  # <file> <function name> -> fn_body with pure-comment lines stripped too
  fn_body "$1" "$2" | grep -v '^#'
}

# THE LOOP THE COMMENT ABOVE PROMISED (wave-01 S11, A-25). Until this slice this section
# defined fn_code, said what the comparison would show, and made no comparison at all — an
# agreement suite asserting nothing, which is this wave's thesis in miniature. The five the
# comment spoke of is SEVEN as measured: every function hooks/session-poker.sh's own
# "DELIBERATELY DUPLICATED" header block introduces has a same-named copy in
# hooks/session-sweeper.sh, and all seven agree as code today. (session-poker.sh's own
# header called the family "the six" — one short of the file — from S11's measurement until
# the F2 fold-in (item 12) corrected it to "the seven" at session-poker.sh:426. The comment
# and this measurement agree now; the discrepancy this parenthetical used to report is gone.)
SPO_DUPES="now_epoch iso_now file_mtime iso_epoch line_field clean parse_seconds"

for _fn in $SPO_DUPES; do
  _poke_code="$(fn_code "$SPO" "$_fn")"
  _swee_code="$(fn_code "$SWEEPER" "$_fn")"
  # EXTRACTED, NOT MISSING. fn_code returns the empty string for a name neither file
  # defines, and two empty strings compare equal — the vacuity the comment below warns
  # about, made impossible per function rather than argued away.
  expect_nonempty "§O the poker's ${_fn}() body is extractable at all" "$_poke_code"
  expect_nonempty "§O the sweeper's ${_fn}() body is extractable at all" "$_swee_code"
  expect_eq "§O the poker's ${_fn}() is the sweeper's, code for code" "$_swee_code" "$_poke_code"
done

# The discriminating half: parse_seconds is NOT byte-identical (the comments legitimately
# differ), which is the whole reason this loop compares code rather than bytes. Without this
# the seven expect_eq's above could be silently vacuous by fn_code stripping everything.
expect_ne "§O parse_seconds is NOT byte-identical — the comments legitimately differ" \
  "$(fn_body "$SWEEPER" parse_seconds)" "$(fn_body "$SPO" parse_seconds)"
expect_eq "§O …and it IS code-identical, which is what the loop above compares" \
  "$(fn_code "$SWEEPER" parse_seconds)" "$(fn_code "$SPO" parse_seconds)"
# …and the byte difference really is comments alone: the two bodies differ, and every line
# present in one and absent from the other starts with `#`.
expect_empty "§O …and every line the two bodies differ by is a comment line" \
  "$(diff <(fn_body "$SWEEPER" parse_seconds) <(fn_body "$SPO" parse_seconds) \
      | grep -E '^[<>]' | sed 's/^[<>] //' | grep -v '^#')"
expect_nonempty "§O …over a diff that really is non-empty (the filter is not eating it all)" \
  "$(diff <(fn_body "$SWEEPER" parse_seconds) <(fn_body "$SPO" parse_seconds) | grep -cE '^[<>]')"

# THE MUTATION ARM. A pin over two files that agree today passes just as loudly if the
# comparison itself is broken, so one copy is DOCTORED in a scratch tree and the same
# comparison is re-run against it: `head -1` becomes `tail -1` inside line_field, which is
# a real drift shape (the two readers would disagree about which of two rows a key comes
# from). The shipped files are never written to.
SPO_MUT="$SANDBOX/o-mutant-poker.sh"
# The needle is `line_field`'s one distinguishing pipeline stage, and it occurs exactly
# once in the file. That count is this mutation's PRECONDITION and it is declared through
# the framework's `anchor` (§S19): a sed whose target had moved would leave an identical
# copy and every row after it would be vacuous, and the anchor names the pattern and the
# count it actually found rather than only reporting that the bytes came out equal.
SPO_NEEDLE='grep "^$2=" | head -1 | cut -d= -f2-'
SPO_MUT_NEEDLE='grep "^$2=" | tail -1 | cut -d= -f2-'
anchor "$SPO" "$SPO_NEEDLE" 1
sed "s@$(printf '%s' "$SPO_NEEDLE" | sed 's/[\\&@]/\\&/g')@$(printf '%s' "$SPO_MUT_NEEDLE" | sed 's/[\\&@]/\\&/g')@" \
  "$SPO" > "$SPO_MUT"
expect_ne "§O …and the SAME comparison calls the doctored copy a drift" \
  "$(fn_code "$SWEEPER" line_field)" "$(fn_code "$SPO_MUT" line_field)"
expect_eq "§O …while every OTHER primitive in the doctored copy still agrees (one row moved, not all)" \
  "$(fn_code "$SWEEPER" parse_seconds)" "$(fn_code "$SPO_MUT" parse_seconds)"

# ============================================================
section "P — the three roster folds agree that the LATER row wins (ap review P-1)"
# ============================================================
#
# The roster is append-only and a contract advances along it (`intended` → `confirmed` →
# `identified`), every writer copying the contract fields forward — so the LAST row carrying
# a name is the authoritative one. Three scripts fold the file on that rule and none of them
# can share code with the others (there is no library in this repo by decision, and each
# fold answers its own caller: hooks/session-sweeper.sh latest_rows also counts contracts
# and filters by session; hooks/session-poker.sh takes one row by name; hooks/stop-orders.sh
# needs a whole batch at once and, since epic-16 w2 Step-6 remediation R4, folds ONCE
# instead of re-walking the file per verdict row — the fix for P-1, whose per-row re-walk
# cost ~14·N² processes and 63 s at N=100).
#
# A code-comparison loop like §O cannot hold these three together, because they are
# legitimately different code. This is the behavioural equivalent: ONE roster in which a
# name appears TWICE, and all three asked what they see. A fold that silently starts taking
# the FIRST row — the plausible drift, and the one an off-by-one in a rewrite produces —
# turns this section red in three places at once.
#
# Overridable for the same reason the parties at the top of this file are: the
# discrimination proof for this section is a MUTATED copy of one fold — made to take the
# first row instead of the last — driven against the same fixture, with the shipped files
# never touched. A mutant copy must sit in a directory that also carries session-sweeper.sh,
# since both scripts resolve it as a sibling:
#   W2_PARTY_ORD=/tmp/mut/stop-orders.sh bash tests/cross-gate-agreement.test.sh
PORD="${W2_PARTY_ORD:-$BIONIC_HOOKS_DIR/stop-orders.sh}"
PPOKE="${W2_PARTY_POKE:-$BIONIC_HOOKS_DIR/session-poker.sh}"
PREPO=$(new_repo "fold-agreement")
mkdir -p "$PREPO/.bionic/tmp" "$PREPO/.bionic/docs/record"
PROSTER="$PREPO/.bionic/tmp/roster-$SID_A.state"
P_LANDED="$PREPO/.bionic/docs/record/p-landed.md"
printf 'landed\n' > "$P_LANDED"
P_OLD=$(date -u -v-100000S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d '-100000 seconds' +%Y-%m-%dT%H:%M:%SZ)
P_NEW=$(date -u -v-60S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d '-60 seconds' +%Y-%m-%dT%H:%M:%SZ)

p_row() {  # <name> <deliverable> <duration> <launched_at> <teammate_id>
  roster_row_fixture status=confirmed session="$SID_A" name="$1" agent_id= \
    launched_at="$4" deliverable="$2" duration="$3" teammate_id="$5" \
    tool_use_id="toolu_P$1"
}

roster_header \
  > "$PROSTER"
# dup-open: the EARLIER row would read as landed and unhurried (a delivered artifact, four
# hours to do it, launched a minute ago); the LATER row is the true contract and is neither.
p_row dup-open "$P_LANDED"                "4 hours"  "$P_NEW" "first@session-p"  >> "$PROSTER"
p_row dup-open "$PREPO/never-written.md"  "1 minute" "$P_OLD" "second@session-p" >> "$PROSTER"
# dup-landed: both rows have landed, so the row that wins is visible in the ADDRESS the
# stand-down prints — the one field standdown reads off the roster for a landed row.
p_row dup-landed "$P_LANDED" "4 hours" "$P_NEW" "first@session-p"  >> "$PROSTER"
p_row dup-landed "$P_LANDED" "4 hours" "$P_NEW" "second@session-p" >> "$PROSTER"


P_VERDICT=$( cd "$PREPO" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SWEEPER" verdict 2>/dev/null )
# PARTY 1 — the sweeper latest_rows. The earlier row points at a file that EXISTS; reading
# it would make this row MET.
expect_contains "the sweeper judges dup-open from the LATER row (UNMET, not the earlier landed one)" \
  "|name=dup-open|state=UNMET|" "$P_VERDICT"
expect_contains "…and its detail names the LATER row deliverable" \
  "never-written.md" "$P_VERDICT"

# PARTY 2 — the poker per-row lookup. `duration=`/`launched_at=` come from the roster, not
# from the verdict line: the earlier row (four hours, launched a minute ago) is nowhere near
# due, the later one (one minute, launched a day ago) is long past.
P_TICK=$( cd "$PREPO" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PPOKE" tick 2>&1 )
expect_contains "the poker reads dup-open duration off the LATER row (NOTIFY, not QUIET)" \
  "decision=NOTIFY" "$P_TICK"
expect_contains "…naming that row" "rows=dup-open" "$P_TICK"

# PARTY 3 — stop-orders single pre-loop fold. Both dup-landed rows have landed, so the
# stand-down prints an address, and the address is the discriminator.
P_STAND=$( cd "$PREPO" && CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PORD" standdown 2>&1 )
# The stand-down must still leave the unlanded row alone, folded or not.
expect_contains "…while dup-open is left alone, not stood down" "LEFT ALONE" "$P_STAND"

# PARTY 4 — landing-gate.sh's OWN copy of the fold (t6-review.md F-3: a fourth "later row
# wins" implementation, outside this section until now). It needs an active wave to reach
# its fold at all, which the three parties above do not. The fixture mirrors dup-open's own
# shape: an EARLIER row that declares NO deliverable (so a fold that took the FIRST row
# would drop the contract entirely — `if (dl[nm] == "") continue`) and a LATER row that
# declares a genuinely missing one — so the correct (last-row-wins) fold refuses, and a
# first-row-wins drift passes the same contract silently.
p_lg_fixture() {  # <repo> -> an active wave + an lg-dup roster, earlier row bare
  mkdir -p "$1/.bionic/tmp" "$1/.bionic/docs/record"
  write_plan "$1/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"
  {
    roster_header
    # SAME tool_use_id on both rows — the real writers (dispatch-preflight, then
    # execution-recorder at confirm/identify) never mint a second one for the same
    # dispatch, and the sweeper's OWN fold counts distinct tool_use_id as distinct
    # CONTRACTS: two different ids here would read as an unrelated second dispatch
    # sharing a name (AMBIGUOUS, §N's `dup` shape) rather than the SAME contract's
    # two rows, which is what this fixture is about.
    p_row lg-dup "" "1 minute" "$P_NEW" "" | sed "s/agent_id=|/agent_id=alg-dup-early001|/"
    roster_row_fixture status=confirmed session="$SID_A" name=lg-dup \
      agent_id=alg-dup-late0001 launched_at="$P_NEW" \
      deliverable="$1/.bionic/docs/record/lg-never-written.md" duration="1 minute" \
      teammate_id= tool_use_id=toolu_Plg-dup
  } > "$1/.bionic/tmp/roster-$SID_A.state"
}

PLGREPO=$(new_repo "fold-agreement-lg")
p_lg_fixture "$PLGREPO"
PLG_ROSTER="$PLGREPO/.bionic/tmp/roster-$SID_A.state"

LG_OUT=$( mk_stopsweep_payload "$PLGREPO" "$SID_A" false | bash "$PARTY_LG" 2>&1 ); LG_RC=$?
expect_eq "landing-gate joins §P: it refuses lg-dup, folding to the LATER row (the genuinely missing artifact)" \
  "2" "$LG_RC"
LG_MARK=$(grep -F '|name=lg-dup|' "$PLG_ROSTER" | grep -F "${SWEPT_SCHEMA}|" | tail -1)
expect_contains "…and the roster marker is keyed to the LATER row agent_id" \
  "agent_id=alg-dup-late0001" "$LG_MARK"

# THE DISCRIMINATING HALF: a copy of landing-gate.sh mutated to take the FIRST row's
# deliverable instead of the last, sibling of a real sweeper, driven against an identical
# fresh fixture (a fresh repo, so the real run's marker above cannot mask the mutant's
# silence).
LG_MUT_DIR="$SANDBOX/fx/lg-first-wins"
mkdir -p "$LG_MUT_DIR"
cp "$SWEEPER" "$LG_MUT_DIR/session-sweeper.sh"
awk '{
       if ($0 == "    dl[name] = deliv") {
         print "    if (!(name in dl)) dl[name] = deliv"
         next
       }
       print
     }' "$PARTY_LG" > "$LG_MUT_DIR/landing-gate.sh"

PLGREPO2=$(new_repo "fold-agreement-lg-mut")
p_lg_fixture "$PLGREPO2"
PLG_ROSTER2="$PLGREPO2/.bionic/tmp/roster-$SID_A.state"
lg_saved="$PARTY_LG"; PARTY_LG="$LG_MUT_DIR/landing-gate.sh"
LG_MUT_OUT=$( mk_stopsweep_payload "$PLGREPO2" "$SID_A" false | bash "$PARTY_LG" 2>&1 ); LG_MUT_RC=$?
PARTY_LG="$lg_saved"
expect_eq "…and with the fold flipped to first-row-wins, the SAME contract passes SILENTLY (§P discriminates)" \
  "0" "$LG_MUT_RC"

# ============================================================
section "Q — has_sdlc_state() has NO carrier left: the library is the only reader"
# ============================================================
#
# It was a five-copy family: the evidence gate held the origin (the file documenting the
# fence-aware, CR-normalizing contract at its definition site) and the dispatch wall,
# stop-guard, execution-recorder and the landing gate each carried a byte-identical twin.
# This section compared them body for body, which is the strongest thing a suite can do
# about a duplication it cannot remove.
#
# It could be removed (bionic 1.4.0, slice ADOPT). The predicate is `lib/run.sh`'s
# `active_plan`, every one of the five asks for it, and §A2 above proves the asking is
# real by mutating the library and watching all five answers move. One straggler survived
# that slice — hooks/session-poker.sh, whose tick carried its own copy — and this section
# NAMED it rather than excusing it. Slice SCHED deleted it (POKER/2, ratified 2026-09-03),
# so the count this pin asserts is now ZERO. An empty answer is a weak assertion on its
# own, which is why the two rows below it are the ones with teeth: the library defines the
# predicate, and the tick reaches it by CALLING that function rather than by restating it.
Q_CARRIERS=$(/usr/bin/grep -ln '^has_sdlc_state()' "$BIONIC_HOOKS_DIR"/*.sh 2>/dev/null \
  | while IFS= read -r _f; do basename "$_f"; done | sort | tr '\n' ' ' | sed 's/ $//')
expect_eq "NO hook defines has_sdlc_state() any more — the family is gone, not shrunk" \
  "" "$Q_CARRIERS"
# TWO NAMES, AND EACH STANDS FOR A DIFFERENT ARM (wave-session-bound-run). The tick's own
# question moved from `active_plan` (which plan is newest in this ROOT) to `session_run`
# (which plan is THIS SESSION's), so `session_run` is what "asks the library by name" means
# for the tick now. The `active_plan` call did not go away and must not: it is
# `resolve_run`'s `none` arm, the one that keeps DISARM reachable for an unbound session
# whose run has already closed (S6 finding A, tests/session-poker.test.sh §18d). Pinning
# only the survivor would pass a tick that had stopped asking whose run it is in.
expect_eq "…and the tick, the last carrier, asks the library by name instead" "yes" \
  "$(/usr/bin/grep -q 'session_run "' "$BIONIC_HOOKS_DIR/session-poker.sh" && echo yes || echo no)"
expect_eq "…and keeps active_plan for the unbound-and-closed arm alone" "yes" \
  "$(/usr/bin/grep -q 'active_plan "' "$BIONIC_HOOKS_DIR/session-poker.sh" && echo yes || echo no)"
expect_eq "…and the evidence gate, which held the origin, no longer carries one" "" \
  "$(fn_body "$PARTY_EG" has_sdlc_state)"
expect_eq "…while the library defines the predicate it replaced them with" "yes" \
  "$(/usr/bin/grep -q '^active_plan()' "$BIONIC_HOOKS_DIR/../payload/scripts/lib/run.sh" && echo yes || echo no)"

# ============================================================
section "R — where a contracted path resolves: four copies, one rule (epic-17 W6 S15)"
# ============================================================
#
# THE DISAGREEMENT THIS ENDS, measured on this epic's own dispatches. A brief writes
# `Expected artifact: record/epic-17-w6/x.md` because that is the spelling the Step-5
# contract and canonical-sdlc-evidence-gate.sh publish for an artifact under the docs root.
# The gate resolved it there. hooks/session-sweeper.sh resolved it against the REPO root
# and reported the row missing; hooks/stop-check.sh resolved it against the observer's cwd
# and printed `progress_state=absent` for a file that was present. Three readers of one
# sentence, two of them wrong — and the cost was not just a wrong reading: one slice wrote
# a duplicate copy at the repo root to satisfy the gate, so the wrong gate taught the work
# to be wrong too.
#
# WHY A BODY-FOR-BODY WALL AND NOT A THIRD ROUND TRIP. There is no shared library under
# hooks/ — every hook is a standalone script the CLI invokes by path — so the honest fix is
# the smallest duplication plus a wall that keeps the copies one text. That is §N.1's and
# §Q's method, and this is the same shape: `canonical-sdlc-evidence-gate.sh` is the
# designated ORIGIN (the copy that documents the rule at its definition site), one
# non-vacuity check proves the extractor pulls a real body from it, then each carrier is
# compared against it. A per-hook suite cannot see this drift: each carrier is green in its
# own suite while all four disagree.
#
# TWO FAMILIES, both duplicated for the same reason:
#   resolve_docs_root()   <docs-root:> in .bionic/config.yaml, else <project>/.bionic/docs
#   the resolver itself   absolute stands · record/-led is docs-root-relative · else project
# The resolver is named `resolve_walk_path` in the gate (its caller asks about a walk
# artifact) and `abs_path` in the two hooks (theirs ask about a roster path). Same body,
# different name — the `clean()`/`mline_value()` precedent in §N.1 above. Only the FIRST
# family — `resolve_docs_root()` — is pinned below; the resolver-itself family and
# canonical-sdlc-governing-skill.sh's own, deliberately WIDER `resolve_design_path()` (it
# adds specs/plans/adrs/incidents/ leaders on top of `record/`, by design — see that hook's
# own comment at the call site) are unchanged by this fix.
#
# THE FOURTH COPY (Step-6 duplication review, record/wave-1.4.0/review-duplication.md,
# 05:55Z finding). ADOPT/4's assumption counted THREE `resolve_docs_root()` carriers — the
# gate, the sweeper, stop-check — and named this section as the test that pins them. It
# never was: this section built a mutant and asserted nothing (dead code — `R_MUT_DIR` was
# read nowhere). A FOURTH live copy sits at canonical-sdlc-governing-skill.sh:150,
# pre-dating this wave and never counted. What follows pins all FOUR: which files define
# the function (a fifth or a missing one goes red), that their bodies agree with the
# origin's, and that a doctored copy is caught.

R_ORIGIN="$PARTY_EG"
R_CARRIERS='canonical-sdlc-evidence-gate session-sweeper stop-check canonical-sdlc-governing-skill'

# (a) THE COUNT. Exactly these four hooks define resolve_docs_root() — named, not globbed,
# for the same reason §N.1's N_ADOPTED is named: a glob shrinks silently to nothing if the
# marker moves, and this row would pass over air.
R_DEFINERS=$(/usr/bin/grep -ln '^resolve_docs_root()' "$BIONIC_HOOKS_DIR"/*.sh 2>/dev/null \
  | while IFS= read -r _f; do basename "$_f" .sh; done | sort | tr '\n' ' ' | sed 's/ $//')
R_EXPECT=$(printf '%s\n' $R_CARRIERS | sort | tr '\n' ' ' | sed 's/ $//')
expect_eq "exactly four hooks define resolve_docs_root (a fifth or a missing one goes red)" \
  "$R_EXPECT" "$R_DEFINERS"

# (b) THE BODY. canonical-sdlc-evidence-gate.sh is the designated origin (it documents the
# rule at its definition site); a non-vacuity check first proves the extractor pulls a real
# body from it, then each of the other three carriers is compared against it, body for body.
expect_eq "the origin's resolve_docs_root is non-vacuous (extractor pulls a real body)" "yes" \
  "$([ "$(fn_body "$R_ORIGIN" resolve_docs_root | wc -l | tr -d ' ')" -gt 3 ] && echo yes || echo no)"

R_ORIGIN_BODY="$(fn_body "$R_ORIGIN" resolve_docs_root)"
for _h in session-sweeper stop-check canonical-sdlc-governing-skill; do
  expect_eq "$_h.sh's resolve_docs_root is the gate's, body for body" \
    "$R_ORIGIN_BODY" "$(fn_body "$BIONIC_HOOKS_DIR/$_h.sh" resolve_docs_root)"
done

# (c) MUTATION, the discriminator: doctor ONE copy back to the repo-root-only form the
# family had before the config.yaml override existed — the shipped file is never touched —
# and the (b) comparison above must be provably able to catch it. Without this, (a) and (b)
# together prove only that four files exist and currently agree, not that disagreement is
# detectable.
R_MUT_DIR="$SANDBOX/resolver-mutant"; mkdir -p "$R_MUT_DIR"
anchor -E "$SWEEPER" '^resolve_docs_root\(\) \{$' 1
awk '
  /^resolve_docs_root\(\) \{$/ {
    print
    print "  local proj=\"$1\""
    print "  echo \"$proj/.bionic/docs\""
    print "}"
    skip = 1
    next
  }
  skip { if ($0 == "}") skip = 0; next }
  { print }
' "$SWEEPER" > "$R_MUT_DIR/session-sweeper.sh"

expect_ne "…and the mutated copy no longer agrees with the origin, body for body" \
  "$R_ORIGIN_BODY" "$(fn_body "$R_MUT_DIR/session-sweeper.sh" resolve_docs_root)"


# ============================================================
section "V — SUPPORTED_SDLC_VERSION: one owner, four carriers, five renderings (AC-19)"
# ============================================================
#
# r3 §1E item 13: one logical constant, five renderings, and the two hooks were not held
# in agreement by anything until this section — the only prior test hit was a single
# spot-check literal in tests/canonical-sdlc-evidence-gate.test.sh, and operational-rules.md
# itself says the pin-sync rows lived in tests/scripts.test.sh, retired at epic-18 W3
# (8582861). `.claude/rules/hook-authoring.md` said both hooks pinned 12 well after they
# moved to 14 — a stale literal in a FILE ABOUT the pin, the same failure mode this section
# exists to catch in the pin's own carriers.
#
# THE OWNER is canonical-sdlc-evidence-gate.sh (spec AC-19, provenance table): it is the
# file operational-rules.md's close-out contract cites by name ("Both hooks check
# `SUPPORTED_SDLC_VERSION=14`") and the one whose refusal message names the fix. Four
# carriers restate it: the governing-skill hook's own copy, the value operational-rules.md
# documents in prose, and two SVG renderings — lifecycle.svg's title and hook-chain.svg's
# three `class="version-pin"` chips (§1E's SVG count is 2; hook-chain.svg alone carries
# three of the five total renderings the census counts as "both SVGs"). A per-file suite
# cannot see this drift: each carrier reads fine on its own while all five disagree.

V_ORIGIN="$PARTY_EG"
V_GSKILL="$BIONIC_HOOKS_DIR/canonical-sdlc-governing-skill.sh"
V_RULES="$BIONIC_SKILLS_DIR/canonical-sdlc/operational-rules.md"
V_LIFECYCLE="$BIONIC_SKILLS_DIR/canonical-sdlc/diagrams/lifecycle.svg"
V_HOOKCHAIN="$BIONIC_SKILLS_DIR/canonical-sdlc/diagrams/hook-chain.svg"

# extractors — each pulls the bare integer out of its file's own rendering shape.
v_hook_val() { grep -m1 '^SUPPORTED_SDLC_VERSION=' "$1" 2>/dev/null | cut -d= -f2 | tr -cd '0-9'; }
v_rules_val() {  # operational-rules.md lists versions newest-first and says so at :17
                 # ("Every version bullet below v14 in this file is historical record
                 # only") — the FIRST `SUPPORTED_SDLC_VERSION=` hit is the live value, the
                 # rest are superseded history. Same first-match convention §N.1's loader
                 # block extraction and the evidence-gate's own frontmatter reads use.
  grep -m1 -o 'SUPPORTED_SDLC_VERSION=[0-9]\+' "$1" 2>/dev/null | cut -d= -f2
}
v_lifecycle_val() {  # <text class="version-pin" data-pin="lifecycle-title" ...>...(v14)</text>
  grep -m1 'data-pin="lifecycle-title"' "$1" 2>/dev/null | grep -oE '\(v[0-9]+\)' | tr -cd '0-9'
}
v_hookchain_vals() {  # three chips, one per line, in the order they render:
                      #   "canonical_sdlc_version == 14" (x2) and
                      #   "canonical_sdlc_version: 14 is the only value either hook accepts."
  grep 'class="version-pin"' "$1" 2>/dev/null | while IFS= read -r _vline; do
    printf '%s\n' "$_vline" | grep -oE 'canonical_sdlc_version[=: ]+[0-9]+' | grep -oE '[0-9]+$'
  done
}

V_ORIGIN_VAL="$(v_hook_val "$V_ORIGIN")"
expect_eq "the origin (evidence gate) declares a non-vacuous SUPPORTED_SDLC_VERSION" "yes" \
  "$([ -n "$V_ORIGIN_VAL" ] && [ "$V_ORIGIN_VAL" -gt 0 ] 2>/dev/null && echo yes || echo no)"

expect_eq "the governing-skill hook's SUPPORTED_SDLC_VERSION agrees with the gate's" \
  "$V_ORIGIN_VAL" "$(v_hook_val "$V_GSKILL")"

expect_eq "operational-rules.md's live SUPPORTED_SDLC_VERSION value agrees with the gate's" \
  "$V_ORIGIN_VAL" "$(v_rules_val "$V_RULES")"

expect_eq "lifecycle.svg's title renders the same version" \
  "$V_ORIGIN_VAL" "$(v_lifecycle_val "$V_LIFECYCLE")"

V_HC_VALS="$(v_hookchain_vals "$V_HOOKCHAIN")"
expect_eq "hook-chain.svg carries exactly three version-pin chips (not fewer, not more)" "3" \
  "$(printf '%s\n' "$V_HC_VALS" | grep -c '[0-9]')"
V_HC_N=0
for _v in $V_HC_VALS; do
  V_HC_N=$((V_HC_N + 1))
  expect_eq "…hook-chain.svg version-pin chip #$V_HC_N agrees with the gate's" \
    "$V_ORIGIN_VAL" "$_v"
done

# MUTATION, the discriminator: doctor the governing-skill hook's value on a COPY — the
# shipped file is never touched — and the comparison above must be provably able to catch
# it. Without this, the rows above prove only that five renderings exist and currently
# agree, not that disagreement is detectable. The replacement value is derived from the
# live one (never a hardcoded "14") so this arm keeps discriminating after the next version
# bump instead of silently passing over air the way the hook-authoring.md staleness did.
V_MUT_DIR="$SANDBOX/version-mutant"; mkdir -p "$V_MUT_DIR"
anchor -E "$V_GSKILL" "^SUPPORTED_SDLC_VERSION=${V_ORIGIN_VAL}\$" 1
sed "s/^SUPPORTED_SDLC_VERSION=${V_ORIGIN_VAL}\$/SUPPORTED_SDLC_VERSION=$((V_ORIGIN_VAL + 1))/" \
  "$V_GSKILL" > "$V_MUT_DIR/canonical-sdlc-governing-skill.sh"
expect_ne "…and a doctored governing-skill copy no longer agrees with the gate" \
  "$V_ORIGIN_VAL" "$(v_hook_val "$V_MUT_DIR/canonical-sdlc-governing-skill.sh")"

# CONTROL — the same copy, unmutated, still agrees. Without this the RED above could be the
# `sed`/copy machinery itself rather than the mutation.
cp "$V_GSKILL" "$V_MUT_DIR/canonical-sdlc-governing-skill.clean.sh"
expect_eq "control: an UNMUTATED copy still agrees with the gate" \
  "$V_ORIGIN_VAL" "$(v_hook_val "$V_MUT_DIR/canonical-sdlc-governing-skill.clean.sh")"

# AC-R6.3 — the governing-skill hook's two HINTS (the version-mismatch Fix line and the
# missing-frontmatter YAML block) read SUPPORTED_SDLC_VERSION; neither one's source states a
# digit. Both sites went through the hook before: the Fix line always interpolated the
# variable, and the YAML block's `canonical_sdlc_version: 14` was a literal until this
# wave's ed78ae3 pick bound the value near the top of the file and interpolated it there too.
V_HINT_REPO="$(new_repo "v-hint")"
V_HINT_PLAN="$V_HINT_REPO/.bionic/docs/plans/epic-99/wave-01-x.plan.md"

# -- the version-mismatch Fix line, against the real (unmutated) hook: a planted write
# declaring canonical_sdlc_version: 13 (one below origin, never hardcoded as 13 anywhere but
# in this plant) must be told to set the LIVE value, not seed its own doctored one back. --
V_MISMATCH_STDERR="$(jq -n --arg p "$V_HINT_PLAN" --arg s "$SID_A" \
    --arg c $'---\ngoverning-skill: canonical-sdlc\ncanonical_sdlc_version: 13\n---\nbody\n' \
    '{session_id:$s, tool_name:"Write", tool_input:{file_path:$p, content:$c}}' \
  | env HOME="$V_HINT_REPO" CLAUDE_CODE_SESSION_ID="$SID_A" bash "$V_GSKILL" 2>&1 >/dev/null)"
expect_contains "…a planted version-13 write's Fix line names the live value, not 13" \
  "canonical_sdlc_version: ${V_ORIGIN_VAL}" "$V_MISMATCH_STDERR"
expect_eq "…and never echoes the doctored value back as the fix" "" \
  "$(printf '%s' "$V_MISMATCH_STDERR" | grep -oE "set 'canonical_sdlc_version: 13'" || true)"

# -- the missing-frontmatter YAML hint: against the real hook it must print the live value,
# and against the §V mutant built above (SUPPORTED_SDLC_VERSION=origin+1) it must print THAT
# value instead — proving the hint tracks the variable rather than a baked-in literal. --
V_MISSING_C='# no frontmatter here
'
V_MISSING_STDERR="$(jq -n --arg p "$V_HINT_PLAN" --arg s "$SID_A" --arg c "$V_MISSING_C" \
    '{session_id:$s, tool_name:"Write", tool_input:{file_path:$p, content:$c}}' \
  | env HOME="$V_HINT_REPO" CLAUDE_CODE_SESSION_ID="$SID_A" bash "$V_GSKILL" 2>&1 >/dev/null)"
expect_contains "…the missing-frontmatter hint prints the live value" \
  "canonical_sdlc_version: ${V_ORIGIN_VAL}" "$V_MISSING_STDERR"

# A hook copied bare into $V_MUT_DIR resolves its libraries via loader.sh's `../scripts/lib`
# fallback, which is not there — see .claude/rules/lib-changes-in-worktrees.md's trap, the
# same shape one level down: a hook run standalone needs its sibling library directory, not
# just its own file. §S.4's S4_MUT builds that sibling once for the whole suite; this arm
# needs its own copy since it mutates the hook the shared one does not.
V_EXEC_MUT="$SANDBOX/version-mutant-exec"
mkdir -p "$V_EXEC_MUT/hooks" "$V_EXEC_MUT/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$V_EXEC_MUT/scripts/lib/" 2>/dev/null
cp "$V_MUT_DIR/canonical-sdlc-governing-skill.sh" "$V_EXEC_MUT/hooks/canonical-sdlc-governing-skill.sh"
V_MISSING_MUT_STDERR="$(jq -n --arg p "$V_HINT_PLAN" --arg s "$SID_A" --arg c "$V_MISSING_C" \
    '{session_id:$s, tool_name:"Write", tool_input:{file_path:$p, content:$c}}' \
  | env HOME="$V_HINT_REPO" CLAUDE_CODE_SESSION_ID="$SID_A" \
    bash "$V_EXEC_MUT/hooks/canonical-sdlc-governing-skill.sh" 2>&1 >/dev/null)"
expect_contains "…and a MUTATED hook's hint prints ITS value, proving the hint follows the variable" \
  "canonical_sdlc_version: $((V_ORIGIN_VAL + 1))" "$V_MISSING_MUT_STDERR"

# -- static proof: no site in the hook's own source states the value as a bare digit; every
# rendering of the field name is followed by the variable, never a literal. --
expect_eq "…no 'canonical_sdlc_version: <digit>' literal anywhere in the hook's source" "" \
  "$(grep -nE 'canonical_sdlc_version:[[:space:]]*[0-9]' "$V_GSKILL" || true)"


# ============================================================
section "Section P — the Patrol stamp: the poker WRITES exactly the path the gate READS"
# ============================================================
#
# epic-17 wave-05 slice 4/4 (spec AC-6). A producer/consumer pair with the path spelled
# once on each side — hooks/session-poker.sh builds it out of PATROL_STAMP_PREFIX/SUFFIX
# under the pinned project root, hooks/dispatch-preflight.sh builds it out of STATE_DIR and
# the payload session id — and no single-component suite can see them disagree. A
# disagreement is not loud: the gate refuses every dispatch of a run whose Patrol is firing
# perfectly, and the named fix (`session-poker.sh arm`) writes to the other path and does
# not clear it. That is an unrecoverable wall by inspection, which is exactly the class this
# file exists for.
#
# Driven as a ROUND TRIP rather than as two greps, because the property is behavioural: the
# gate is asked where it looked, the poker is asked to arm, and the gate is asked again.

PARTY_PK="${W1R_PARTY_PK:-$BIONIC_HOOKS_DIR/session-poker.sh}"
P_SID="$SID_A"
P_REPO=$(new_repo "patrol-stamp-pair")
write_plan "$P_REPO/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"
mkdir -p "$P_REPO/.bionic/tmp"
# new_repo arms every fixture; this is the one section whose subject is an UNARMED session.
rm -f "$P_REPO"/.bionic/tmp/patrol-*.state
{
  printf '# bionic environment attestation — machine-local, safe to delete\n'
  printf 'version=1\nkind=preflight-attestation\nsession_id=%s\n' "$P_SID"
  printf 'written_at=1785790000\nrepo=%s\n' "$P_REPO"
} > "$P_REPO/.bionic/tmp/preflight-$P_SID.state"
chmod 600 "$P_REPO/.bionic/tmp/preflight-$P_SID.state"

P_OUT=$(mk_agent_payload "$P_SID" "$P_REPO" | bash "$PARTY_DP" 2>&1 >/dev/null); P_ST=$?
expect_eq "the gate refuses a dispatch with no Patrol stamp" "2" "$P_ST"

# The path the CONSUMER named, taken out of its own words rather than rebuilt here.
P_READS=$(printf '%s\n' "$P_OUT" | grep -oE '/[^[:space:]]*/patrol-[^[:space:]]+\.state' | head -1)

# The path the PRODUCER wrote, discovered by running the named fix and looking.
( cd "$P_REPO" && CLAUDE_CODE_SESSION_ID="$P_SID" bash "$PARTY_PK" arm ) >/dev/null 2>&1
P_WRITES=$(ls "$P_REPO"/.bionic/tmp/patrol-*.state 2>/dev/null | head -1)
if [ -n "$P_WRITES" ]; then
  ok "the poker's arm verb wrote a stamp"
else
  no "the poker's arm verb wrote a stamp" "nothing matching .bionic/tmp/patrol-*.state"
fi
expect_eq "poker WRITES == gate READS (one stamp path, two spellings)" "$P_READS" "$P_WRITES"

# The round trip closes: the fix the wall named actually opens the wall.
P_OUT2=$(mk_agent_payload "$P_SID" "$P_REPO" | bash "$PARTY_DP" 2>&1 >/dev/null); P_ST2=$?
expect_eq "…and the named fix opens it: the same dispatch now passes" "0" "$P_ST2"

# ============================================================
section "Section Q — refusal credit: one rule, two readers"
# ============================================================
#
# Step-6 findings C1/C2/C3, .bionic/docs/record/task-dispatch-wall-channel-loss/
# review-close.md. "How many dispatches did the wall REFUSE this session" has TWO owners —
# hooks/session-poker.sh's count_refused_dispatches, answering for the live tick, and
# payload/scripts/lib/patrol.sh's _patrol_scan, answering for doctor's reconstruction — and
# on this machine's own transcript they answered 13 and 1 against a truth of 1. Neither
# number was a rounding error. The poker greped the WHOLE transcript for the CLI's marker,
# which the plan, the reports and every brief that quotes it carry too, so the detector was
# inert in the repository that builds it; patrol cut each tool_result to 200 characters
# BEFORE looking for a marker real refusals carry at offset 482.
#
# THE RULE, now single and shared: a refusal is credited only when a tool_result carrying
# `PreToolUse:Agent hook error:` JOINS BY tool_use_id to an `Agent` tool_use in the same
# transcript — the refused dispatch's own result. A literal quoted inside a file read, a
# brief or a report joins to nothing; truncation moves to the display side, after the test.
# The main-thread filter is the poker's, on both sides: `isSidechain:true` OR an explicit
# agent-id key is not this session's own dispatch.
#
# ONE FIXTURE, BOTH READERS, ONE (dispatches, refused) PAIR. The two answers are compared
# to EACH OTHER first — that is what goes red on the next divergence, whichever side moves
# — and only then to the number the rule implies. Neither reader may source the other
# (hooks/ ships as hooks, scripts/lib/ as payload), so the copies stay two and this section
# is what holds them together.

PARTY_PT="${W1R_PARTY_PT:-$REPO_ROOT/payload/scripts/lib/patrol.sh}"

# The transcript shapes, captured off this machine 2026-08-23 with:
#   jq -c 'select((.message.content?|type)=="array") | .message.content[]' <transcript>
# Two of them are the false positives that were being counted as refusals: a `Read`/`Bash`
# result whose text quotes the marker out of a file, and an Agent spawn whose SIBLING
# `toolUseResult` field echoes the brief back (the CLI writes the brief there verbatim, so
# a brief that quotes the marker — this task's own — planted one in the transcript).
q_agent() {  # <tx> <tool-use-id>
  jq -nc --arg id "$2" '{type:"assistant",isSidechain:false,message:{role:"assistant",
    content:[{type:"tool_use",id:$id,name:"Agent",
              input:{name:"q-agent",subagent_type:"bionic:implementor",prompt:"…"}}]}}' >> "$1"
}
q_agent_pair() {  # <tx> <id> <id> — a parallel fan-out: two dispatches in ONE entry
  jq -nc --arg a "$2" --arg b "$3" '{type:"assistant",isSidechain:false,message:{role:"assistant",
    content:[{type:"tool_use",id:$a,name:"Agent",input:{name:"q-alpha",prompt:"…"}},
             {type:"tool_use",id:$b,name:"Agent",input:{name:"q-beta",prompt:"…"}}]}}' >> "$1"
}
q_agent_ctx() {  # <tx> <id> — an entry carrying an explicit agent-id key: not this thread's
  jq -nc --arg id "$2" '{type:"assistant",isSidechain:false,agentId:"agent-inner-1",
    message:{role:"assistant",content:[{type:"tool_use",id:$id,name:"Agent",
      input:{name:"q-inner",prompt:"…"}}]}}' >> "$1"
}
q_agent_side() {  # <tx> <id> — a subagent's own dispatch
  jq -nc --arg id "$2" '{type:"assistant",isSidechain:true,message:{role:"assistant",
    content:[{type:"tool_use",id:$id,name:"Agent",input:{name:"q-side",prompt:"…"}}]}}' >> "$1"
}
q_read() {  # <tx> <id> — a NON-Agent tool_use, the thing a quoted marker belongs to
  jq -nc --arg id "$2" '{type:"assistant",isSidechain:false,message:{role:"assistant",
    content:[{type:"tool_use",id:$id,name:"Read",input:{file_path:"/p/wave.plan.md"}}]}}' >> "$1"
}
q_result() {  # <tx> <id> <text>
  jq -nc --arg id "$2" --arg t "$3" '{type:"user",isSidechain:false,message:{role:"user",
    content:[{type:"tool_result",tool_use_id:$id,content:$t}]}}' >> "$1"
}
q_spawn_echo() {  # <tx> <id> <brief-text> — a SUCCESSFUL spawn whose sibling field echoes the brief
  jq -nc --arg id "$2" --arg b "$3" '{type:"user",isSidechain:false,
    message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,
      content:[{type:"text",text:"Spawned successfully."}]}]},
    toolUseResult:{status:"teammate_spawned",prompt:$b}}' >> "$1"
}

Q_MARK='PreToolUse:Agent hook error:'
# Past patrol's 200-character display cut. Real refusals carry the marker at 482 and 628 —
# the CLI prefixes the hook's own stderr with the tool name and the hook path.
Q_PAD="$(printf 'x%.0s' $(seq 1 400))"
Q_REFUSAL="$Q_PAD $Q_MARK [dispatch-preflight.sh]: BLOCKED: this dispatch brief names no deliverable."
Q_QUOTE="the review says the marker is \`$Q_MARK\` and the poker greps for it"

mkdir -p "$SANDBOX/fx/refusal-credit"
Q_TX="$SANDBOX/fx/refusal-credit/all.jsonl"; : > "$Q_TX"
q_agent_pair "$Q_TX" toolu_q1 toolu_q2      # two main-thread dispatches, one entry
q_agent_ctx  "$Q_TX" toolu_q3               # C2: an agent-context entry — not a dispatch
q_agent_side "$Q_TX" toolu_q5               # a subagent's own dispatch — not a dispatch
q_result     "$Q_TX" toolu_q1 "$Q_REFUSAL"  # C1: the ONE real refusal, marker past 200
q_result     "$Q_TX" toolu_q2 "Spawned successfully."
q_read       "$Q_TX" toolu_q4
q_result     "$Q_TX" toolu_q4 "$Q_QUOTE"    # C3: the marker quoted out of a plan
q_agent      "$Q_TX" toolu_q6
q_spawn_echo "$Q_TX" toolu_q6 "Read first: review-close.md. The marker is $Q_MARK — join it."

# Each reader answers from ITS OWN file, in its own subshell: the poker's counters are
# extracted and called for real (§I.1's precedent), patrol is sourced as doctor sources it.
q_poker() {  # <fn-name> <transcript> [<since ISO>]
  ( eval "$(awk -v n="$1" '$0 ~ "^" n "\\(\\)" {f=1} f{print; if ($0=="}") exit}' "$PARTY_PK")"
    "$1" "$2" "${3:-}" ) 2>/dev/null
}
q_patrol() {  # <transcript> [<since ISO>] -> "<dispatches> <refused>"
  ( . "$PARTY_PT" >/dev/null 2>&1
    _patrol_scan "$1" "${2:-}" ) 2>/dev/null \
  | awk -F'\t' '$1=="AGENTS"{a=$2} $1=="REFUSED"{r=$2} END{printf "%d %d", a+0, r+0}'
}

Q_PK_D="$(q_poker count_main_thread_dispatches "$Q_TX")"
Q_PK_R="$(q_poker count_refused_dispatches "$Q_TX")"
Q_PT="$(q_patrol "$Q_TX")"; Q_PT_D="${Q_PT%% *}"; Q_PT_R="${Q_PT##* }"

expect_eq "fixture: patrol's scan runs at all" \
  "yes" "$([ -n "$Q_PT_D" ] && [ "$Q_PT_D" != 0 ] && echo yes || echo no)"
expect_eq "DISPATCHES: the poker and patrol return one number, not two" "$Q_PK_D" "$Q_PT_D"
expect_eq "REFUSED: the poker and patrol return one number, not two" "$Q_PK_R" "$Q_PT_R"

# --- Q.1 the three findings, one transcript each -----------------------------
# Asked separately so a regression names the defect that came back rather than a total.

Q_C1="$SANDBOX/fx/refusal-credit/c1.jsonl"; : > "$Q_C1"
q_agent  "$Q_C1" toolu_c1
q_result "$Q_C1" toolu_c1 "$Q_REFUSAL"
expect_eq "C1 patrol: the same, from the untruncated content" "1" \
  "$(q_patrol "$Q_C1" | cut -d' ' -f2)"

Q_C3="$SANDBOX/fx/refusal-credit/c3.jsonl"; : > "$Q_C3"
q_agent  "$Q_C3" toolu_d1
q_result "$Q_C3" toolu_d1 "Spawned successfully."
q_read   "$Q_C3" toolu_d2
q_result "$Q_C3" toolu_d2 "$Q_QUOTE"

Q_C3B="$SANDBOX/fx/refusal-credit/c3b.jsonl"; : > "$Q_C3B"
q_agent      "$Q_C3B" toolu_e1
q_spawn_echo "$Q_C3B" toolu_e1 "the marker is $Q_MARK and this brief quotes it"

Q_C2="$SANDBOX/fx/refusal-credit/c2.jsonl"; : > "$Q_C2"
q_agent_ctx  "$Q_C2" toolu_f1
q_agent_side "$Q_C2" toolu_f2

# --- Q.2 the discriminator: blind ONE reader and the pair must split ---------
# Without this the section proves only that two files agree on a fixture neither is
# sensitive to. The mutation is the defect ITSELF — patrol's pre-test truncation, restored
# to a copy — so the assertion is that C1's fixture separates the copies again.
Q_MUT="$SANDBOX/fx/refusal-credit/patrol-truncating.sh"
sed 's/(if ($full | test(/(if (($full | .[0:200]) | test(/' "$PARTY_PT" > "$Q_MUT"
Q_MUT_R="$( ( . "$Q_MUT" >/dev/null 2>&1; _patrol_scan "$Q_C1" ) 2>/dev/null \
            | awk -F'\t' '$1=="REFUSED"{print $2+0}' )"
expect_eq "…and the truncating copy misses the late marker, so the pair splits (§Q discriminates)" \
  "0" "$Q_MUT_R"

# --- Q.3 the WINDOW: one rule, two readers ----------------------------------
#
# §Q above proved the refusal-JOIN rule is one rule on two files with `since` left empty
# ("the whole transcript") on both sides. This is the sibling proof for the WINDOW itself:
# hooks/session-poker.sh scopes count_main_thread_dispatches/count_refused_dispatches to
# the roster's own window (`roster_window()`, exposed as the `window` verb) and
# payload/scripts/lib/patrol.sh takes the identical `since` parameter through
# `_patrol_scan` (patrol_window() shells out to that verb the same way patrol_interval()
# already shells out for the interval). Windowing either file alone splits this pair, which
# is why the whole cluster is one commit.
#
# THE FIXTURE IS A FILE ON DISK, tests/fixtures/patrol-two-wave.jsonl, rather than built
# inline: this section's whole claim is about which entries a reader counts, so the entries
# are reviewable as one artifact instead of as a sequence of jq calls. It can be a static
# file precisely because `since` here is a LITERAL instant. tests/doctor-patrol.test.sh
# Section 12 asks the same question end-to-end through doctor, where the window is the
# roster file's own creation time and the waves have to be dated against it at run time —
# a static file cannot express that, so Section 12 builds its own dated transcript.
#
# TWO WAVES: three entries before 2026-09-01T00:00:00Z carrying one refusal, four entries
# after it carrying one refusal. Lifetime 5 dispatches / 2 refusals, windowed 3 / 1.
Q3_TX="$REPO_ROOT/tests/fixtures/patrol-two-wave.jsonl"
Q3_SINCE="2026-09-01T00:00:00Z"

expect_true "Q.3 fixture: the two-wave transcript is on disk" test -f "$Q3_TX"

Q3_PK_D="$(q_poker count_main_thread_dispatches "$Q3_TX" "$Q3_SINCE")"
Q3_PK_R="$(q_poker count_refused_dispatches "$Q3_TX" "$Q3_SINCE")"
Q3_PT="$(q_patrol "$Q3_TX" "$Q3_SINCE")"; Q3_PT_D="${Q3_PT%% *}"; Q3_PT_R="${Q3_PT##* }"

expect_eq "windowed DISPATCHES: the poker counts only wave two (3)" "3" "$Q3_PK_D"
expect_eq "windowed DISPATCHES: poker and patrol agree" "$Q3_PK_D" "$Q3_PT_D"
expect_eq "windowed REFUSED: the poker counts only wave two's refusal, not wave one's (1)" \
  "1" "$Q3_PK_R"
expect_eq "windowed REFUSED: poker and patrol agree" "$Q3_PK_R" "$Q3_PT_R"

# THE DISCRIMINATOR: with no window at all (since="") both readers fall back to the
# transcript's whole life, so BOTH counts rise (5 dispatches, 2 refusals — one refusal per
# wave) — proof `since`, not some other difference, is what produced the smaller windowed
# counts above, and that this is not the coincidence of a fixture with one refusal in it.
Q3_PK_D_LIFE="$(q_poker count_main_thread_dispatches "$Q3_TX" "")"
Q3_PK_R_LIFE="$(q_poker count_refused_dispatches "$Q3_TX" "")"
Q3_PT_LIFE="$(q_patrol "$Q3_TX" "")"; Q3_PT_D_LIFE="${Q3_PT_LIFE%% *}"; Q3_PT_R_LIFE="${Q3_PT_LIFE##* }"
expect_eq "…and with no window at all, both readers count the earlier wave's dispatches too (5)" \
  "5" "$Q3_PK_D_LIFE"
expect_eq "…poker and patrol agree on the lifetime dispatch count too" \
  "$Q3_PK_D_LIFE" "$Q3_PT_D_LIFE"
expect_eq "…and the earlier wave's refusal too (2, not 1)" "2" "$Q3_PK_R_LIFE"
expect_eq "…poker and patrol agree on the lifetime refused count too" \
  "$Q3_PK_R_LIFE" "$Q3_PT_R_LIFE"

# ============================================================
section "Section R — the ADOPTED address: one construction, three sites"
# ============================================================
#
# `<name>@session-<id8>` is the only spelling the platform's stop primitive takes for a
# teammate (capture record/session-20260814-wave-detector-terminal-state/min/logs/A-p3.jsonl:9),
# and after epic-20 W1 three scripts build or accept it: hooks/stop-guard.sh constructs it
# for its refusals and accepts it as an identity, hooks/stop-check.sh prints it beside every
# ambiguous candidate, and hooks/session-poker.sh's `adopt` prints it as the stop address
# for an agent this session has taken over. The field defect was exactly a disagreement of
# this kind — adopt printed the TRANSCRIPT form, which the platform rejects — so what is
# pinned here is not that three files contain a string but that the string ONE of them
# prints is the string the other two answer to, over one fixture world.

RREPO_AD=$(new_repo "adopted-address")
RSLUG_AD=$(printf '%s' "$RREPO_AD" | sed 's/[^a-zA-Z0-9]/-/g')
RPROJ_AD="$CLAUDE_CONFIG_DIR/projects/$RSLUG_AD"
RSUB_AD="$RPROJ_AD/$SID_A/subagents"
mkdir -p "$RSUB_AD" "$RPROJ_AD/$SID_B/subagents" "$RREPO_AD/.bionic/tmp"
printf '{}\n' > "$RPROJ_AD/$SID_A.jsonl"
printf '{}\n' > "$RPROJ_AD/$SID_B.jsonl"
# The agent's files, planted by hand rather than through `plant()`: this section wants the
# predecessor's roster to carry exactly ONE row for the agent — the one the printf below
# writes — because `adopt` renders what it reads and a second row of the same name would
# render twice.
printf '{"name":"adoptee","agentType":"implementor","description":"fixture","model":"opus"}' \
  > "$RSUB_AD/agent-aadoptee-4444444444444444.meta.json"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}\n' \
  > "$RSUB_AD/agent-aadoptee-4444444444444444.jsonl"
# AND IT IS LIVE IN THE SUCCESSOR'S SET (S6, D1′). That is what a `/clear`+resume leaves
# behind and what the whole adopted address is for: the same process, still listed as a
# teammate by the harness, its working log still filed under the session that LAUNCHED it.
# Both transcripts carry the answer, because both sessions are looking at the same agent.
cg_live "$RPROJ_AD/$SID_A.jsonl" "adoptee"
cg_live "$RPROJ_AD/$SID_B.jsonl" "adoptee"
write_plan "$RREPO_AD/.bionic/docs/plans/epic-99/wave-01.md" "current: 4"

# THE PREDECESSOR'S ROW, as hooks/execution-recorder.sh left it when that session died:
# `identified`, the transcript-form id, a contract that never landed.
roster_row_fixture status=identified session="$SID_A" name=adoptee \
  agent_id=aadoptee-4444444444444444 launched_at=2026-08-05T00:00:00Z \
  deliverable=.bionic/docs/record/never-lands.md cadence="10 minutes" \
  >> "$RREPO_AD/.bionic/tmp/roster-$SID_A.state"

# THE ADOPTING SESSION IS DELIBERATELY UNBOUND, and since wave-session-bound-run that is a
# decision rather than an accident. `adopt` now partitions foreign rows on `plan=`: a BOUND
# caller writes only the rows naming its own plan and merely LISTS the rest, and the
# predecessor row planted below carries no `plan=` at all — it is a pre-wave roster (spec
# assumption A2). Bind `$SID_B` here and that row becomes `unattributed`, adopt declines to
# journal it, and the `stop        : TaskStop ` line every assertion below reads disappears —
# so this section would go red for a reason that has nothing to do with the ADDRESS it is
# about. The partition belongs to tests/session-poker.test.sh §17, which drives all three
# arms; what this section needs is the arm where every row reaches the rendering.
#
# `new_repo` plants an EMPTY marker for `$SID_B` (see `engage_sids`), which lib/run.sh reads
# as engaged-and-unbound. That is now PINNED rather than assumed: the row below asserts the
# partition this fixture depends on, so a future change to what an empty marker means fails
# here with its own name instead of silently emptying the three sites' evidence.
R_AD_OUT=$( cd "$RREPO_AD" && CLAUDE_CODE_SESSION_ID="$SID_B" bash "$SPO" adopt 2>&1 )
expect_contains "the adopting session is unbound, so every row is adoptable (this section's precondition)" \
  "partition=all" "$R_AD_OUT"
# The suffixed address, off the `stop` line. The bare name is printed beneath it on its own
# continuation line, which this grep does not reach.
R_AD_ADDR=$(printf '%s\n' "$R_AD_OUT" | grep -F 'stop        : TaskStop ' | head -1 \
            | sed 's/.*TaskStop //' | awk '{print $1}')
expect_eq "adopt prints the addressing form, built from the LAUNCHING session" \
  "adoptee@session-$(printf '%s' "$SID_A" | cut -c1-8)" "$R_AD_ADDR"

# SITE 2 — the observation answers to that exact string, and says why it is ours.
R_AD_CHECK=$( cd "$RREPO_AD" && CLAUDE_CODE_SESSION_ID="$SID_B" bash "$OBSERVE" "$R_AD_ADDR" 2>&1 )
expect_contains "the observation resolves the address adopt printed" \
  "aadoptee-4444444444444444" "$R_AD_CHECK"
expect_contains "…and classifies it OURS by the adoption the poker wrote" \
  "Classification: OURS" "$R_AD_CHECK"
expect_contains "…naming the session it was adopted from" "adopted_from=$SID_A" "$R_AD_CHECK"
# …and the working log it reads is the one filed under the LAUNCHING session, which is the
# fact `adopted_from=` exists to carry now that no directory scan goes looking for it.
expect_contains "…and reads the working log filed under that session" \
  "$SID_A/subagents/agent-aadoptee-4444444444444444.jsonl" "$R_AD_CHECK"

# SITE 3 — the stop gate resolves the same string and accepts it as an IDENTITY. The
# paired negative first: resolution succeeding is not the ceremony being skipped.
R_AD_ST_OUT=$(mk_stop_payload "$SID_B" "$RPROJ_AD/$SID_B.jsonl" "$RREPO_AD" "$R_AD_ADDR" \
              | bash "$PARTY_SG" 2>&1); R_AD_ST=$?
expect_eq "before any discharge the stop gate still refuses" "2" "$R_AD_ST"
expect_absent "…and never with the unresolved refusal the field hit" \
  "no agent in THIS session's metadata" "$R_AD_ST_OUT"

( cd "$RREPO_AD" && CLAUDE_CODE_SESSION_ID="$SID_B" bash "$SWEEPER" ack adoptee ) >/dev/null 2>&1
R_AD_ST_OUT=$(mk_stop_payload "$SID_B" "$RPROJ_AD/$SID_B.jsonl" "$RREPO_AD" "$R_AD_ADDR" \
              | bash "$PARTY_SG" 2>&1); R_AD_ST=$?
expect_eq "the stop gate accepts the address adopt printed, discharged by the ack" \
  "0" "$R_AD_ST"

# THE CONSTRUCTION ITSELF, at all three sites: eight characters of a session id, cut the
# same way. A site that starts spelling it differently — a full uuid, a different width —
# splits from the other two here rather than in the field.
for _f in "$PARTY_SG" "$OBSERVE" "$SPO"; do
  expect_true "$(basename "$_f") builds the address as @session-<first 8 of a session id>" \
    grep -qE '@session-\$\(printf .%s. "\$[A-Za-z_]+" \| cut -c1-8\)' "$_f"
done

# ============================================================
section "S — which plan answers for the run: the tick reads what the gate reads (wave-1.3.2 4/4, AC-13/AC-14)"
# ============================================================
#
# THE COPY THIS SECTION EXISTS FOR. `hooks/session-poker.sh tick` DISARMs the Patrol —
# terminally, for the rest of the session — and from 1.3.2 that decision needs the RUN to
# say it is delivered, which means the tick reads a plan. It is the sixth reader of "which
# *.md answers for this run", and hooks/patrol-revive.sh:64-70 refused to become the fifth
# for a reason worth restating: an UNFILTERED "newest *.md under plans/" read is a measured
# incident. On 2026-08-15 a marker-less scrap won the newest race, `current:` parsed empty,
# and every wall reading it passed silently for ~15 minutes
# (.bionic/docs/record/session-20260815-landing-supervision/t8-forensic-read.md).
#
# So the tick got the gate's read rather than an approximation of it, and this section is
# the wall that keeps the copy honest — in BOTH directions, because the two failures are
# different. A drifted PREDICATE (the `## SDLC State` filter, the fence rule, the CR
# translation) makes the tick DISARM off a scrap file: silent, terminal, unrecoverable. A
# drifted SELECTION (depth, the strict `-nt` ordering, the two plan directories) makes it
# answer for the wrong wave.
#
# TWO PROOFS, because either alone is weak. First the TEXT: the four bodies the tick copied
# are compared to canonical-sdlc-evidence-gate.sh's, which is the designated origin (it
# documents the contract at its definition site) — §N.1's and §Q's method. Then the
# BEHAVIOUR: both readers are handed the same repository and asked which file answered, and
# their answers are compared to each other. Text agreement without behaviour would miss a
# call site that never invokes its copy; behaviour without text would miss a drift the
# fixtures happen not to reach.

PARTY_PK_S="${W1R_PARTY_PK:-$BIONIC_HOOKS_DIR/session-poker.sh}"

# ---- S.1 the family is down to one carrier, and it is this one -----------
#
# The four bodies this section used to compare — `has_sdlc_state`, `resolve_docs_root`,
# `normalize_newlines`, and the selection block — lived in the evidence gate as the
# designated origin and in the tick as copies. The gate's are gone (bionic 1.4.0, slice
# ADOPT): it asks `lib/run.sh` now, and §A2 proves the asking is real by mutating the
# library and watching every party's answer move. The tick's are gone too (slice SCHED,
# POKER/2 ratified 2026-09-03) — so there is no longer a text COMPARISON to make here,
# and pretending otherwise would leave a section comparing a body against nothing and
# calling it agreement. What §S pins about the TEXT now is the absence itself, in both
# directions: no party carries a private plan reader, and the tick names the library's
# functions where its own used to be.
expect_eq "the evidence gate carries no private has_sdlc_state() any more" "" \
  "$(fn_body "$PARTY_EG" has_sdlc_state)"
expect_eq "…and neither does the tick, the last file that did (SCHED converted it)" "" \
  "$(fn_body "$PARTY_PK_S" has_sdlc_state)"
expect_eq "…nor a private newest-plan selection beside it" "" \
  "$(fn_body "$PARTY_PK_S" newest_sdlc_plan)"
expect_eq "…nor a private docs-root resolver" "" \
  "$(fn_body "$PARTY_PK_S" resolve_docs_root)"
# THE READER THE TICK CALLS IS `session_run` (wave-session-bound-run). It used to be
# `active_plan`, and that call survives — but only on `resolve_run`'s `none` arm, where an
# unbound session over a closed run still needs a plan to read DISARM out of. So the pin
# that stands for "the tick asks the library which run it is in" is `session_run`, and the
# `active_plan` row beside it says what the leftover call is for rather than leaving a
# reader to guess it is the main path. Both, or the sentence above them is only half true.
expect_eq "…and the tick asks the library WHOSE run this session is in, by name" "yes" \
  "$(/usr/bin/grep -q 'session_run "' "$PARTY_PK_S" && echo yes || echo no)"
expect_eq "…and still calls active_plan, for the unbound-and-closed arm and nothing else" "yes" \
  "$(/usr/bin/grep -q 'active_plan "' "$PARTY_PK_S" && echo yes || echo no)"

# ---- S.2 the ONE selection block, proven by what it SELECTS -------------
#
# It used to live twice: at file scope in the evidence gate, and inside the tick's
# `newest_sdlc_plan()`. Both copies are gone and the block is `lib/run.sh`'s, so what is
# pinned here is the LIBRARY's selection on its three load-bearing properties — the DEPTH
# bound the layout needs, the FENCE rule that keeps a page ABOUT the lifecycle out of the
# set, and the STRICT newest ordering that makes `active_plan`'s answer a total one rather
# than one that depends on find's directory order.
#
# PINNED BY BEHAVIOUR, NOT BY SUBSTRING (wave-roster-lifecycle S1, AC-22). Until this wave
# the assertions below read `fn_body run.sh active_plan` and matched `-maxdepth 2 -type f`
# and `-nt "$plan"` inside it. That pinned the block's TEXT to one function's body, so the
# moment the walk moved into the `_run_candidates` helper the two readers now share, every
# one of those matches emptied — and an empty extraction reads as a PASS on a `case` that
# is looking for a substring, which is the failure mode this suite exists to refuse. The
# properties are unchanged; they are asked of the ANSWER now, over one fixture repository
# driven through both readers, so the walk can be refactored under them and only a change
# in what it SELECTS goes red.
#
# BOTH READERS, ONE FIXTURE. `active_plan` picks one file and `open_runs` returns the set;
# they walk the same candidates, so every exclusion below is asserted of BOTH answers. That
# agreement is what this section owns, and the depth discriminator at the end moves both.

# The RETIRED extractor, kept for one job only: proving the tick's copy is really gone.
# It is the exact reader this section used against `newest_sdlc_plan()`, so an empty answer
# means the block it looked for is absent rather than merely renamed out of reach. This one
# reads the TICK, not the library, so the extraction below leaves it exactly as it was.
sel_block_pk() {  # <file> -> the tick's old selection block, or empty
  awk '
    !f && index($0, "PLAN_DIRS=(") { f = 1 }
    f {
      line = $0
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^#/) next
      print line
      if (line == "done") exit
    }
  ' "$1"
}

S_RUN_LIB="$BIONIC_HOOKS_DIR/../payload/scripts/lib/run.sh"
[ -r "$S_RUN_LIB" ] || S_RUN_LIB="$BIONIC_HOOKS_DIR/../scripts/lib/run.sh"
expect_eq "the library under this section is on disk (§S.2 is not vacuous)" "yes" \
  "$([ -r "$S_RUN_LIB" ] && echo yes || echo no)"
expect_eq "…and the tick carries no selection block of its own to disagree with it" "" \
  "$(sel_block_pk "$PARTY_PK_S")"

# THE ANSWER AND THE STATUS RIDE ONE CAPTURE, separated by a byte no path can contain —
# `$?` read after a `$( … )` assignment under this file's `set -u` is the assignment's, not
# the function's. §OR's `or_ask` takes the same reading against the same library.
S2_OUT=""; S2_ST=0
s2_ask() {  # <library> <root> <function> -> sets S2_OUT, S2_ST
  local lib="$1" root="$2" fn="$3" raw
  raw=$( . "$lib" >/dev/null 2>&1; "$fn" "$root" 2>/dev/null; printf '\037%s' "$?" )
  S2_ST="${raw##*$'\037'}"
  S2_OUT="${raw%$'\037'*}"
  S2_OUT="${S2_OUT%$'\n'}"
}

# ONE FIXTURE, FOUR CANDIDATE FILES, EVERY EXCLUSION LOAD-BEARING. The mtimes are ordered so
# that each file the walk must REFUSE is NEWER than the one it must return: a depth-3 plan
# and a fenced example that were merely older would be excluded by the ordering and the
# selection rules would never be asked. Driven straight at the library — no hook, no session,
# no git repo — because the property under test is the walk, and `new_repo`'s patrol stamp
# and engagement markers would only add ways for the fixture to answer for another reason.
S2_R="$SANDBOX/s2-selection"
S2_REAL="$S2_R/.bionic/docs/plans/wave.plan.md"
S2_OLDER="$S2_R/.bionic/docs/plans/epic-99/older.plan.md"
S2_DEEP="$S2_R/.bionic/docs/plans/epic-99/sub/deep.plan.md"
S2_FENCED="$S2_R/.bionic/docs/plans/example.md"
write_plan "$S2_REAL"  "current: 4"
write_plan "$S2_OLDER" "current: 4"
write_plan "$S2_DEEP"  "current: 4"
mkdir -p "$(dirname "$S2_FENCED")"
cat > "$S2_FENCED" <<'S2FENCE'
# A page ABOUT the lifecycle, not a plan

```
## SDLC State

integration-branch: main
current: 4
```
S2FENCE
touch -t 202601010000 "$S2_OLDER"
touch -t 202602010000 "$S2_REAL"
touch -t 202603010000 "$S2_DEEP"
touch -t 202604010000 "$S2_FENCED"

s2_ask "$S_RUN_LIB" "$S2_R" active_plan; S2_AP="$S2_OUT"; S2_AP_ST="$S2_ST"
s2_ask "$S_RUN_LIB" "$S2_R" open_runs;   S2_SET="$S2_OUT"; S2_SET_ST="$S2_ST"

expect_eq "active_plan has an answer on the fixture (non-vacuity)" "0" "$S2_AP_ST"
expect_eq "…and it is the newest REAL plan inside the bound" "$S2_REAL" "$S2_AP"
expect_eq "open_runs has an answer too" "0" "$S2_SET_ST"
expect_eq "…and it is the two in-bound plans, newest first" \
  "$(printf '%s\n%s' "$S2_REAL" "$S2_OLDER")" "$S2_SET"
expect_eq "…so the selection is bounded at depth 2: the NEWER depth-3 plan is in neither" "no" \
  "$(cg_contains "$S2_AP$S2_SET" "$S2_DEEP")"
expect_eq "…and fence-aware: the NEWEST file, whose ## SDLC State is fenced, is in neither" "no" \
  "$(cg_contains "$S2_AP$S2_SET" "$S2_FENCED")"
expect_eq "…and the two readers agree: active_plan's answer IS line 1 of the set" \
  "$S2_AP" "$(printf '%s\n' "$S2_SET" | head -1)"

# THE DEPTH DISCRIMINATOR, AND IT MOVES BOTH READERS. Without it the exclusions above prove
# only that two paths are absent from two strings, which is also what a walk that found
# nothing at all would prove. The bound is raised to 3 on a COPY; the depth-3 plan is the
# newest real plan in the tree, so `active_plan` must switch to it and the set must gain it.
# The shipped file is never touched. One `sed` reaches every copy of the walk there is — two
# before the `_run_candidates` extraction, one after — which is why this proof survives it.
S2_MUT_DIR="$SANDBOX/runstate-mutant"; mkdir -p "$S2_MUT_DIR"
anchor "$S_RUN_LIB" '-maxdepth 2 -type f' 1
sed 's/-maxdepth 2 -type f/-maxdepth 3 -type f/g' "$S_RUN_LIB" > "$S2_MUT_DIR/depth.sh"
s2_ask "$S2_MUT_DIR/depth.sh" "$S2_R" active_plan; S2_AP_M="$S2_OUT"
s2_ask "$S2_MUT_DIR/depth.sh" "$S2_R" open_runs;   S2_SET_M="$S2_OUT"
expect_eq "depth 3: active_plan switches to the deep plan (§S.2 discriminates)" \
  "$S2_DEEP" "$S2_AP_M"
expect_eq "…and the set gains it, newest first — BOTH readers moved on one mutation" \
  "$(printf '%s\n%s\n%s' "$S2_DEEP" "$S2_REAL" "$S2_OLDER")" "$S2_SET_M"

# THE ORDERING DISCRIMINATOR. Depth alone would stay green if `active_plan` stopped choosing
# the newest and started choosing whatever `find` handed it last, so the comparator is
# reversed on a second copy and the answer must become the OLDEST candidate. It is asserted
# of `active_plan` only: `open_runs` keeps its own newest-first insertion, which §OR.1 and
# run-predicate R6g pin, and a mutation that moved both would be measuring one of them twice.
anchor "$S_RUN_LIB" '[ "$f" -nt "$plan" ]' 1
sed 's/\[ "\$f" -nt "\$plan" \]/[ "$plan" -nt "$f" ]/' "$S_RUN_LIB" > "$S2_MUT_DIR/order.sh"
s2_ask "$S2_MUT_DIR/order.sh" "$S2_R" active_plan
expect_eq "reversed comparator: active_plan answers with the OLDEST plan instead" \
  "$S2_OLDER" "$S2_OUT"

# RESTORED. The shipped library answers exactly as it did before either mutation, so the two
# rows above measured the mutations and not a fixture that had drifted underneath them.
s2_ask "$S_RUN_LIB" "$S2_R" active_plan
expect_eq "restored: the shipped library still names the newest in-bound plan" "$S2_REAL" "$S2_OUT"

# ---- S.3 the round trip: one repository, two readers, one answer ---------
#
# Driven rather than grepped, because the property is behavioural. The gate is asked through
# its own refusal (which names `Plan:` and the step it could not find); the tick is asked
# through the QUIET line it now prints over an empty roster, which names the plan it decided
# from and where that plan says the run is. Neither answer is rebuilt here.

s_backdate() {  # <file> — an hour older than everything else in the fixture
  touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null || date -d '-1 hour' +%Y%m%d%H%M.%S)" "$1"
}

# THE READERS TAKE A SESSION ID (wave-session-bound-run). Until this wave "which plan
# answers for the run" was a property of the ROOT, so a reader needed only a repo; it is now
# a property of the SESSION, and a helper that hard-coded one sid could only ever ask half
# the question. Both default to $SID_A so every case below §S.3 reads exactly as it did.
s_eg_read() {  # <repo> [sid] -> "<plan path>|<current>", or "none"
  local out st plan cur sid="${2:-$SID_A}"
  out=$(mk_bash_payload "$sid" "$SANDBOX/t.jsonl" "$1" "git commit -m x" \
        | env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$sid" bash "$PARTY_EG" 2>&1); st=$?
  [ "$st" -eq 0 ] && { echo none; return; }
  plan=$(printf '%s\n' "$out" | sed -n 's/^Plan: //p' | head -1)
  cur=$(printf '%s\n' "$out" | sed -n "s/.*has no 'Step \([^']*\):' line.*/\1/p" | head -1)
  if [ -z "$plan" ] || [ -z "$cur" ]; then echo "other:$(printf '%s' "$out" | head -1 | cut -c1-60)"; return; fi
  printf '%s|%s\n' "$plan" "$cur"
}

s_pk_read() {  # <repo> [sid] -> "<plan path>|<current>", or "none"
  local out plan cur sid="${2:-$SID_A}"
  roster_header \
    > "$1/.bionic/tmp/roster-$sid.state"
  # THE STAMP IS RE-PLANTED PER READ. A tick that decides DISARM removes this session's
  # Patrol stamp as its last act (hooks/session-poker.sh), so a second read of the same
  # fixture would meet a different world than the first. Every §S read is meant to be the
  # first one.
  rm -f "$1/.bionic/tmp/patrol-$sid.state.holds"
  out=$( cd "$1" && env CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_CONFIG_DIR="$1/no-such-config" \
           bash "$PARTY_PK_S" tick 2>&1 )
  case "$out" in *'no plan carrying an unfenced'*) echo none; return ;; esac
  plan=$(printf '%s\n' "$out" | sed -n 's/.*(\(\/[^ ]*\.md\) is at current: .*/\1/p' | head -1)
  cur=$(printf '%s\n' "$out" | sed -n 's/.* is at current: \([^ )]*\).*/\1/p' | head -1)
  if [ -z "$plan" ] || [ -z "$cur" ]; then echo "other:$(printf '%s' "$out" | head -1 | cut -c1-60)"; return; fi
  printf '%s|%s\n' "$plan" "$cur"
}

# S.3a — a NEWER marker-less .md must lose to an older real plan. This is the 2026-08-15
# incident in fixture form, and it is the case that decides whether the tick can DISARM off
# a scrap file.
S_R1=$(new_repo "s-marker-less-newest")
write_plan "$S_R1/.bionic/docs/plans/epic-99/wave-01.plan.md" "current: 4"
printf 'a scratch note — no SDLC State heading anywhere in it\n' \
  > "$S_R1/.bionic/docs/plans/epic-99/zz-newest-scrap.md"
# "Newest" is fixture DATA, set by backdating the loser — never by sleeping, and never left
# to a same-second tie, which `-nt` resolves as "not newer" and would pass this case for a
# reason the fixture never states.
s_backdate "$S_R1/.bionic/docs/plans/epic-99/wave-01.plan.md"
S_EG=$(s_eg_read "$S_R1"); S_PK=$(s_pk_read "$S_R1")
expect_eq "the gate skips the newer marker-less file and answers from the plan" \
  "$S_R1/.bionic/docs/plans/epic-99/wave-01.plan.md|4" "$S_EG"
expect_eq "…and the tick answers from the SAME file, at the same step" "$S_EG" "$S_PK"

# S.3b — the newest REAL plan wins, so the pin is on ordering and not merely on filtering.
# Its paired discriminator is S.3a: one case where the newest file loses, one where it wins.
S_R2=$(new_repo "s-newest-real-plan")
write_plan "$S_R2/.bionic/docs/plans/epic-98/wave-01.plan.md" "current: 4"
write_plan "$S_R2/.bionic/docs/plans/epic-99/wave-02.plan.md" "current: 6"
s_backdate "$S_R2/.bionic/docs/plans/epic-98/wave-01.plan.md"
S_EG=$(s_eg_read "$S_R2"); S_PK=$(s_pk_read "$S_R2")
expect_eq "the gate takes the NEWER of two real plans" \
  "$S_R2/.bionic/docs/plans/epic-99/wave-02.plan.md|6" "$S_EG"
expect_eq "…and so does the tick" "$S_EG" "$S_PK"

# S.3c — a `## SDLC State` that exists only inside a fence is documentation, not a run.
# Both readers must answer "no canonical run here" rather than parsing the example.
S_R3=$(new_repo "s-fenced-only")
mkdir -p "$S_R3/.bionic/docs/plans/epic-99"
{
  printf -- '---\ngoverning-skill: canonical-sdlc\ncanonical_sdlc_version: 14\n'
  printf -- 'intent: build\nrigor: audited\nscale: wave\n---\n\n# a document ABOUT plans\n\n'
  printf '```\n## SDLC State\ncurrent: 4\n```\n'
} > "$S_R3/.bionic/docs/plans/epic-99/schema-notes.md"
S_EG=$(s_eg_read "$S_R3"); S_PK=$(s_pk_read "$S_R3")
expect_eq "a fenced-only heading is not a plan to the gate" "none" "$S_EG"
expect_eq "…and is not a plan to the tick either" "none" "$S_PK"

# S.3d — ONE BOUND, AND IT IS 2. This case used to pin a DISAGREEMENT: L-RUN shipped
# `active_plan` at depth 3 while the tick's private copy walked 2, and the honest thing a
# suite could do about two readers with different bounds was to state it. POKER/2's
# unification (ratified 2026-09-03) ended it — the tick has no reader of its own, the
# library is depth 2, and both parties answer from the same walk.
#
# BOTH DIRECTIONS, because the deep half alone would pass on a reader with no bound and the
# shallow half alone on one that finds nothing: a plan at depth 3 is invisible to BOTH, and
# the SAME content at depth 2 is seen by BOTH.
S_R4=$(new_repo "s-depth")
write_plan "$S_R4/.bionic/docs/plans/epic-99/wave-01/too-deep.plan.md" "current: 4"
S_EG=$(s_eg_read "$S_R4"); S_PK=$(s_pk_read "$S_R4")
expect_eq "a plan at depth 3 is out of the bound for the gate" "none" "$S_EG"
expect_eq "…and out of it for the tick, which now reads the same library" "none" "$S_PK"
write_plan "$S_R4/.bionic/docs/plans/epic-99/wave-01.plan.md" "current: 4"
S_EG=$(s_eg_read "$S_R4"); S_PK=$(s_pk_read "$S_R4")
expect_eq "…and the SAME content at depth 2 is seen by the gate (the bound is pinned)" \
  "$S_R4/.bionic/docs/plans/epic-99/wave-01.plan.md|4" "$S_EG"
expect_eq "…and by the tick" "$S_EG" "$S_PK"

# ============================================================
section "S.4 — THE RUN VERDICT: one root, two sessions, every consumer answers for ITS OWN run"
# ============================================================
#
# THE OWNERSHIP-TABLE ROW THIS DISCHARGES (spec §Design): "the run verdict · owning module
# lib/run.sh session_run · rendering surfaces: evidence-gate, governing-skill,
# dispatch-preflight, duties-gate, poker tick/scheduler, session-start, patrol-revive,
# context-spend".
#
# THE BUG IN ONE SENTENCE. Every hook used to answer "which run am I in" with
# `active_run "$ROOT"` — one answer per REPOSITORY — so two engaged sessions in one root
# shared a run identity: the evidence gate validated the wrong plan, `adopt` offered another
# run's agents, session-start steered a new session at the existing run. §S above pins that
# the parties agree with each other; it cannot see this bug at all, because with one session
# in the fixture the wrong answer and the right answer are the same string.
#
# SO THE FIXTURE HAS TWO SESSIONS AND THE ASSERTION IS ASYMMETRIC. One root, two open plans,
# one bound to each session, and every consumer is driven TWICE — once as A, once as B — and
# must name A's plan for A and B's for B. A consumer that kept the root-keyed reader answers
# the SAME plan both times and fails one of its two rows, whichever way the mtime fell.
#
# THREE VERDICTS, NOT ONE. `bound-open` is where the consumers that read a plan for DATA are
# discriminated; `bound-closed` and `fallback` are where the four consumers that use the run
# only as a boolean can be discriminated at all, because those are the two verdicts they
# ANNOUNCE by name (AC-3, AC-6). Leaving them out would leave half the ownership table's
# rendering surfaces outside the test that exists for it.
#
# WHERE EACH CONSUMER'S ANSWER IS READ FROM — measured, not assumed
# (.bionic/docs/record/wave-session-bound-run/s8-consumer-recon.md):
#
#   evidence-gate      bound-open: `Plan: <p>` on its refusal · closed/fallback: announced
#   dispatch-preflight bound-open: `declared by <p>` in the budget refusal · both announced
#   context-spend      bound-open: field 1 of .bionic/tmp/context-spend.state · both announced
#   session-poker tick bound-open: the QUIET line's `(<p> is at current: N)` · both announced
#   governing-skill    bound-open: NOTHING — the verdict is a boolean here · both announced
#   patrol-duties-gate bound-open: NOTHING (only the basename, into an awk fold) · both announced
#   patrol-revive      bound-open: NOTHING (a pure gate) · both announced
#   session-start      NOTHING, ever — its only plan output is `open_runs`, and only for an
#                      UNBOUND session in a root with two or more. Which is itself the claim,
#                      and S.4d asserts it in both directions.

# THE TWO SENTENCES, EACH PINNED IN FULL. Seven hooks carry a literal copy of each and the
# ownership table names no owner for the wording — row 2 licenses seven RENDERINGS of the
# verdict and says nothing about them being the same string — so these two regexes are the
# single authority for what the fleet says, and the loops below drive all seven against them.
#
# THE CLOSED SENTENCE INCLUDES ITS TAIL (S10a, review D6). It used to be pinned to its prefix
# alone, so the `; this session has no open run` half — the clause that tells the operator
# what the closed binding MEANS rather than merely that it exists — could be dropped by six of
# the seven and stay green. The fallback sentence was already pinned whole; this is the other
# half brought up to it. `.*` spans the path, which each row asserts separately.
S4_FALLBACK_RE='run resolved by newest-plan fallback \(session unbound\) — '
S4_CLOSED_RE='bound plan closed — .*; this session has no open run'

# ---- the fixture world ------------------------------------------------
#
# `write_plan` is this file's own builder; the budget line is appended for
# dispatch-preflight's ceiling, which is the only per-plan DATUM any consumer reads besides
# the step. A plan with no `parallel-budget:` makes the budget wall inert, and an inert wall
# is not an observation.
s4_plan() {  # <path> <current> [writers]
  mkdir -p "$(dirname "$1")"
  {
    printf -- '---\n'
    printf 'governing-skill: canonical-sdlc\ncanonical_sdlc_version: 14\n'
    printf 'intent: build\nrigor: audited\nscale: wave\n'
    # INSIDE THE LEADING FRONTMATTER, which is the only place hooks/dispatch-preflight.sh
    # looks for it. A `parallel-budget:` appended after the body parses as prose and the
    # ceiling reads as absent, which makes the budget wall inert — and an inert wall is not
    # an observation.
    [ -n "${3:-}" ] && printf 'parallel-budget: writers=%s test_jobs=2 model=opus\n' "$3"
    printf -- '---\n\n# Fixture plan\n\n## SDLC State\n\nintegration-branch: main\n'
    printf 'current: %s\n' "$2"
    printf -- '\n- Step 3: prior evidence\n'
  } > "$1"
  return 0
}
s4_close() {  # <path> — the same plan, delivered
  write_plan "$1" "current: 9"
  printf -- '- Step 9: delivered: 2026-09-04\n' >> "$1"
}
# THE MARKER'S EXACT TWO-LINE SHAPE, hooks/engage.sh:287 — `plan=<path>` then
# `engaged_at=<iso>`, mode 600, written by the real `bind_plan` (S11,
# tests/lib/bound-marker.sh; spec AC-24). A fixture that invented a one-line marker
# would be testing a file no writer in the fleet produces.
s4_bind() {  # <repo> <sid> <plan>
  bound_marker "$1" "$2" "$3"
}
s4_unbind() {  # <repo> <sid> — engaged, no binding (the shape engage_sids plants)
  unbound_marker "$1" "$2" empty
}
# WITHOUT AN ATTESTATION THE DISPATCH WALL RUNS THE REAL ENVIRONMENT PROBE INLINE, which
# reads a credential and a config root off the machine this suite happens to be on — so the
# gate's answer would depend on the runner's shell rather than on the fixture, and a refusal
# there would make every assertion below it vacuously true. Planted in the shape
# hooks/preflight-probe.sh writes and tests/dispatch-preflight.test.sh:265 plants.
s4_attest() {  # <repo> <sid>
  mkdir -p "$1/.bionic/tmp"
  {
    printf '# bionic environment attestation — machine-local, safe to delete\n'
    printf 'version=1\nkind=preflight-attestation\n'
    printf 'session_id=%s\n' "$2"
    printf 'written_at=1785790000\n'
    printf 'repo=%s\n' "$1"
  } > "$1/.bionic/tmp/preflight-$2.state"
  chmod 600 "$1/.bionic/tmp/preflight-$2.state"
}

# ---- one driver per consumer, each returning that consumer's whole channel ----
#
# STDOUT AND STDERR ARE MERGED for every driver but session-start's. Each hook chooses its
# own channel for the announcement (stderr for the seven, stdout for session-start's
# listing), and a section about whether the RIGHT PLAN was named has no business also
# pinning which file descriptor it was named on — §L and the per-hook suites own that.
s4_eg() {  # <repo> <sid>
  mk_bash_payload "$2" "$SANDBOX/t.jsonl" "$1" "git commit -m x" \
    | env -u CLAUDE_PROJECT_DIR HOME="$1" CLAUDE_CODE_SESSION_ID="$2" bash "$PARTY_EG" 2>&1
  return 0
}
s4_gs() {  # <repo> <sid> — the PreToolUse WALL arm: no hook_event_name key, per the hook's :56
  jq -n --arg p "$1/.bionic/docs/record/s4-note.md" --arg c "a note" --arg s "$2" \
    '{session_id:$s, tool_name:"Write", tool_input:{file_path:$p, content:$c}}' \
    | env HOME="$1" CLAUDE_CODE_SESSION_ID="$2" bash "$PARTY_SG_W" 2>&1
  return 0
}
s4_dp() {  # <repo> <sid>
  # The transcript is REDIRECTED onto this world's file. `mk_agent_payload` pins
  # `transcript_path:"/irrelevant.jsonl"`, which was true of the dispatch wall until S5: the
  # budget used to count `intended` rows against a landing-swept marker and never opened a
  # transcript. It now counts them against `live_agents_has`, so a payload pointing at a file
  # that does not exist reads NONE and the wall refuses with "call ListAgents, then dispatch"
  # BEFORE it ever computes a ceiling — no plan is named and §S.4a's two `expect_contains`
  # rows go missing. Pointing at the world's own transcript restores what the section asks.
  mk_agent_payload "$2" "$1" \
    | jq -c --arg t "$1/s4-transcript.jsonl" '.transcript_path = $t' \
    | env CLAUDE_CODE_SESSION_ID="$2" bash "$PARTY_DP" 2>&1
  return 0
}
s4_stop_payload() {  # <repo> <sid> <transcript>
  jq -nc --arg c "$1" --arg s "$2" --arg t "$3" \
    '{session_id:$s, transcript_path:$t, cwd:$c, hook_event_name:"Stop", stop_hook_active:false}'
}
s4_pdg() {  # <repo> <sid>
  s4_stop_payload "$1" "$2" "$1/s4-transcript.jsonl" \
    | env CLAUDE_CODE_SESSION_ID="$2" bash "$PARTY_PDG" 2>&1
  return 0
}
s4_prv() {  # <repo> <sid>
  s4_stop_payload "$1" "$2" "$1/s4-transcript.jsonl" \
    | env CLAUDE_CODE_SESSION_ID="$2" bash "$PARTY_PRV" 2>&1
  return 0
}
s4_cs() {  # <repo> <sid>
  rm -f "$1/.bionic/tmp/context-spend.state"
  s4_stop_payload "$1" "$2" "$1/s4-usage.jsonl" \
    | env -u CLAUDE_PROJECT_DIR HOME="$1" CLAUDE_CODE_SESSION_ID="$2" bash "$PARTY_CS" 2>&1
  return 0
}
s4_pk() {  # <repo> <sid>
  roster_header \
    > "$1/.bionic/tmp/roster-$2.state"
  ( cd "$1" && env CLAUDE_CODE_SESSION_ID="$2" CLAUDE_CONFIG_DIR="$1/no-such-config" \
      bash "$PARTY_PK_S" tick 2>&1 )
  return 0
}
s4_ss() {  # <repo> <sid> — SessionStart; stdout is where its listing goes
  jq -nc --arg c "$1" --arg s "$2" \
    '{session_id:$s, transcript_path:"/dev/null", cwd:$c, hook_event_name:"SessionStart", source:"resume"}' \
    | env CLAUDE_CODE_SESSION_ID="$2" BIONIC_CLAUDE_HOME="$1/fakehome" bash "$PARTY_SS" 2>&1
  return 0
}

PARTY_SG_W="$BIONIC_HOOKS_DIR/canonical-sdlc-governing-skill.sh"
PARTY_PDG="$BIONIC_HOOKS_DIR/patrol-duties-gate.sh"
PARTY_PRV="$BIONIC_HOOKS_DIR/patrol-revive.sh"
PARTY_CS="$BIONIC_HOOKS_DIR/context-spend.sh"
PARTY_SS="$BIONIC_HOOKS_DIR/session-start.sh"

# THE SEVEN THAT ANNOUNCE, as a table driven by one loop: a per-consumer `case` written out
# seven times is seven places for one of them to be quietly dropped, which is checklist A8's
# defect in another costume. session-start is not a member — it announces nothing — and
# S.4d drives it separately for exactly that reason.
S4_ANNOUNCERS='evidence-gate|s4_eg
governing-skill|s4_gs
dispatch-preflight|s4_dp
patrol-duties-gate|s4_pdg
patrol-revive|s4_prv
context-spend|s4_cs
poker|s4_pk'

s4_world() {  # <name> -> a root with plans A (older, writers=1) and B (newest, writers=1)
  local r
  r=$(new_repo "$1")
  s4_plan "$r/.bionic/docs/plans/epic-99/run-a.md" 4 1
  s4_plan "$r/.bionic/docs/plans/epic-99/run-b.md" 6 1
  s_backdate "$r/.bionic/docs/plans/epic-99/run-a.md"
  # patrol-duties-gate refuses a payload whose transcript is not a regular file; context-spend
  # needs a last `assistant` line carrying a non-zero usage sum before it will write state.
  printf '{}\n' > "$r/s4-transcript.jsonl"
  jq -nc '{type:"assistant",message:{model:"claude-opus-5",usage:{input_tokens:1000,cache_creation_input_tokens:0,cache_read_input_tokens:2000}}}' \
    > "$r/s4-usage.jsonl"
  mkdir -p "$r/fakehome/.claude"
  s4_attest "$r" "$SID_A"
  s4_attest "$r" "$SID_B"
  printf '%s' "$r"
}

# ---- S.4a — BOUND-OPEN: the four consumers that name the plan they read --------
#
# Each of these reads the plan for DATA — a step, a budget, a `current:` — so each has a
# rendering that names it. Every row is asserted in BOTH directions on the SAME tree: A's
# session names A and never B, B's names B and never A. One direction alone would pass on a
# consumer that always answered "the newest".
S4_R1=$(s4_world "s4-bound-open")
S4_PA="$S4_R1/.bionic/docs/plans/epic-99/run-a.md"
S4_PB="$S4_R1/.bionic/docs/plans/epic-99/run-b.md"
s4_bind "$S4_R1" "$SID_A" "$S4_PA"
s4_bind "$S4_R1" "$SID_B" "$S4_PB"

# the evidence gate — through §S's own reader, which now takes the session
expect_eq "bound-open: the gate answers session A's plan, at session A's step" \
  "$S4_PA|4" "$(s_eg_read "$S4_R1" "$SID_A")"
expect_eq "…and session B's plan for session B, on the same tree" \
  "$S4_PB|6" "$(s_eg_read "$S4_R1" "$SID_B")"

# the tick — through §S's own reader, likewise
expect_eq "…the tick answers session A's plan too" "$S4_PA|4" "$(s_pk_read "$S4_R1" "$SID_A")"
expect_eq "…and session B's for session B" "$S4_PB|6" "$(s_pk_read "$S4_R1" "$SID_B")"

# the dispatch wall — its budget refusal names the plan the ceiling came from. One open row
# on each session's roster meets `writers=1`, so the refusal fires for both.
# `status=intended` IS WHAT THE CEILING COUNTS. `budget_roster_counts` walks only the
# intended rows — a confirmed row is an agent that already reported in, not an open seat —
# so a confirmed fixture row leaves the wall inert and this pair of assertions vacuous.
#
# AND THE ROW MUST BE LIVE. Since S5 the ceiling counts an `intended` row only while
# `live_agents_has` finds its name in the session transcript — the landing-swept marker it
# used to consult is gone. The `{}` transcript s4_world writes reads NONE, every row counts
# closed, the wall stays inert and both `expect_contains` rows below go missing. Seed the
# same transcript with a fresh ListAgents answer naming both dispatched agents; that is the
# only reason this file names s4a/s4b at all.
cg_live "$S4_R1/s4-transcript.jsonl" "s4a" "s4b"
cg_roster_row "$S4_R1" "$SID_A" "s4a" "as4a-1111111111111111" "" "intended"
cg_roster_row "$S4_R1" "$SID_B" "s4b" "as4b-2222222222222222" "" "intended"
S4_DP_A=$(s4_dp "$S4_R1" "$SID_A")
S4_DP_B=$(s4_dp "$S4_R1" "$SID_B")
expect_contains "…the dispatch wall's ceiling is declared by session A's plan" "$S4_PA" "$S4_DP_A"
expect_absent   "…and never by the neighbour's" "$S4_PB" "$S4_DP_A"
expect_contains "…while session B's ceiling is declared by B's plan" "$S4_PB" "$S4_DP_B"
expect_absent   "…and never by A's" "$S4_PA" "$S4_DP_B"

# context-spend — the one consumer whose answer is a FILE rather than a line. Its state file
# is per-project, not per-session (one root, one file), so the driver clears it per drive;
# that collision is the hook's own design and is not this section's to relitigate.
s4_cs "$S4_R1" "$SID_A" >/dev/null
S4_CS_A=$(cut -f1 < "$S4_R1/.bionic/tmp/context-spend.state" 2>/dev/null)
s4_cs "$S4_R1" "$SID_B" >/dev/null
S4_CS_B=$(cut -f1 < "$S4_R1/.bionic/tmp/context-spend.state" 2>/dev/null)
expect_eq "…context-spend measures session A against A's plan" "$S4_PA" "$S4_CS_A"
expect_eq "…and session B against B's, from the same root" "$S4_PB" "$S4_CS_B"

# THE NEGATIVE THAT COVERS ALL SEVEN AT ONCE: a bound session is never told it fell back.
# This is AC-3's other direction and the cheapest row in the section — it is also the one
# that would fail first if a consumer stopped consulting the binding at all.
while IFS='|' read -r _n _fn; do
  [ -n "$_n" ] || continue
  expect_absent "…$_n never announces a fallback to a session that is bound (AC-3's negative)" \
    "fallback (session unbound)" "$("$_fn" "$S4_R1" "$SID_A")"
done <<S4EOF
$S4_ANNOUNCERS
S4EOF

# ---- S.4b — BOUND-CLOSED: every announcer names ITS OWN closed plan -------------
#
# THIS IS THE ROW THE OTHER FOUR CONSUMERS EXIST IN. governing-skill, patrol-duties-gate and
# patrol-revive read the verdict as a boolean and render nothing for `bound-open`, so the
# only place their answer is observable is the verdict they SPEAK. Here session A is bound to
# a plan that has been delivered while B's plan sits open and NEWEST beside it — the exact
# drift AC-6 is about — and the old root-keyed reader would have handed A the neighbour's
# open run. Each consumer must name A's dead plan and never B's live one.
S4_R2=$(s4_world "s4-bound-closed")
S4_R2A="$S4_R2/.bionic/docs/plans/epic-99/run-a.md"
S4_R2B="$S4_R2/.bionic/docs/plans/epic-99/run-b.md"
s4_close "$S4_R2A"
s_backdate "$S4_R2A"          # closed AND older: B is the newest open plan in this root
s4_bind "$S4_R2" "$SID_A" "$S4_R2A"

while IFS='|' read -r _n _fn; do
  [ -n "$_n" ] || continue
  _out=$("$_fn" "$S4_R2" "$SID_A")
  expect_true    "$_n says the bound plan is closed" \
    grep -qE "$S4_CLOSED_RE" <<<"$_out"
  expect_contains "…naming the plan THIS session is bound to" "$S4_R2A" "$_out"
  expect_absent   "…and never the neighbour's open run, which is also the newest" \
    "$S4_R2B" "$_out"
  expect_false   "…and never calls it a fallback (a binding is a commitment, AC-6)" \
    grep -qE "$S4_FALLBACK_RE" <<<"$_out"
done <<S4EOF
$S4_ANNOUNCERS
S4EOF

# ---- S.4c — FALLBACK: unbound, every announcer names the SAME newest plan --------
#
# AC-3 in one fixture: an unbound session behaves exactly as it did before this wave, and
# says so. The agreement here is between the seven, not between two sessions — they must all
# name the one plan `active_run` would have named, which is the newest OPEN one. A consumer
# that fell back to something else, or fell back silently, splits from the other six here.
S4_R3=$(s4_world "s4-fallback")
S4_R3B="$S4_R3/.bionic/docs/plans/epic-99/run-b.md"
s4_unbind "$S4_R3" "$SID_A"

while IFS='|' read -r _n _fn; do
  [ -n "$_n" ] || continue
  _out=$("$_fn" "$S4_R3" "$SID_A")
  expect_true    "$_n announces the newest-plan fallback for an unbound session (AC-3)" \
    grep -qE "$S4_FALLBACK_RE" <<<"$_out"
  expect_contains "…naming the newest OPEN plan, which is what active_run would have said" \
    "$S4_R3B" "$_out"
done <<S4EOF
$S4_ANNOUNCERS
S4EOF

# ---- S.4d — session-start: silent when bound, a listing when not (AC-5) ---------
#
# The eighth consumer, and the one with no announcement at all. Its whole rendering IS the
# open-run listing, and the listing is what a session gets when it is NOT bound — so its
# agreement row is the pair, driven over the same root: bound sees nothing, unbound sees
# every open run and the verb that ends the ambiguity.
# WHAT IS ABSENT FOR A BOUND SESSION IS THE LISTING, not all output. session-start still
# prints its ordinary engaged block — the roster and stamp report it has always printed —
# and falls through rather than exiting; the open-run listing is the part AC-5 adds, and it
# is the part a bound session must not see. Asserting total silence would pin a claim about
# the whole hook that this section is not about and that its own suite already owns.
S4_SS_BOUND=$(s4_ss "$S4_R1" "$SID_A")
expect_absent "session-start does not list the open runs to a session that is already bound (AC-5)" \
  "open runs exist here" "$S4_SS_BOUND"
expect_absent "…and names neither run's path at it" "$S4_PB" "$S4_SS_BOUND"
expect_absent "…not even its own" "$S4_PA" "$S4_SS_BOUND"
S4_SS_UNBOUND=$(s4_ss "$S4_R3" "$SID_A")
# Step-6 P3 (S10b): the listing prints paths RELATIVE to the docs root, so the set is
# asserted by its relative spellings — the absolute form is what the wave stopped printing.
expect_contains "…and lists both open runs to one that is not" "plans/epic-99/run-b.md" "$S4_SS_UNBOUND"
expect_contains "…naming A's too — the listing is the SET, not a verdict" \
  "plans/epic-99/run-a.md" "$S4_SS_UNBOUND"
expect_contains "…and names the verb that ends the ambiguity" \
  "session-poker.sh bind" "$S4_SS_UNBOUND"

# ---- S.4e — THE DISCRIMINATOR: mutate session_run, and EVERY party moves ---------
#
# §A2's pattern, applied to the reader this wave added. The eight rows above prove the fleet
# AGREES; they do not prove the agreement is produced by the library rather than by eight
# copies that happen to match today. So `session_run` is doctored in a COPY of the library —
# the binding branch is skipped, which is precisely "revert to the pre-wave rule" — and the
# consumers are re-driven out of a throwaway tree shaped like the shipped plugin. A party
# that kept its own answer stays green here and nowhere else.
#
# The shipped library is never touched: the mutant is a copy, and the parties are copies
# beside it, which is also what makes them load the mutant at all (the loader's first
# candidate is `$(dirname "$0")/../scripts/lib`).
S4_MUT="$SANDBOX/s4-mutant"
mkdir -p "$S4_MUT/hooks" "$S4_MUT/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$S4_MUT/scripts/lib/" 2>/dev/null
cp "$BIONIC_HOOKS_DIR"/*.sh "$S4_MUT/hooks/" 2>/dev/null
anchor "$RUN_LIB" '  if plan=$(session_plan "$root" "$sid"); then' 1
sed 's/  if plan=$(session_plan "$root" "$sid"); then/  if false \&\& plan=$(session_plan "$root" "$sid"); then/' \
  "$RUN_LIB" > "$S4_MUT/scripts/lib/run.sh"

s4_repoint() {  # aim every driver at the mutant tree
  PARTY_EG="$S4_MUT/hooks/canonical-sdlc-evidence-gate.sh"
  PARTY_SG_W="$S4_MUT/hooks/canonical-sdlc-governing-skill.sh"
  PARTY_DP="$S4_MUT/hooks/dispatch-preflight.sh"
  PARTY_PDG="$S4_MUT/hooks/patrol-duties-gate.sh"
  PARTY_PRV="$S4_MUT/hooks/patrol-revive.sh"
  PARTY_CS="$S4_MUT/hooks/context-spend.sh"
  PARTY_PK_S="$S4_MUT/hooks/session-poker.sh"
}
s4_restore() {
  PARTY_EG="${W1R_PARTY_EG:-$BIONIC_HOOKS_DIR/canonical-sdlc-evidence-gate.sh}"
  PARTY_SG_W="$BIONIC_HOOKS_DIR/canonical-sdlc-governing-skill.sh"
  PARTY_DP="${W1R_PARTY_DP:-$BIONIC_HOOKS_DIR/dispatch-preflight.sh}"
  PARTY_PDG="$BIONIC_HOOKS_DIR/patrol-duties-gate.sh"
  PARTY_PRV="$BIONIC_HOOKS_DIR/patrol-revive.sh"
  PARTY_CS="$BIONIC_HOOKS_DIR/context-spend.sh"
  PARTY_PK_S="${W1R_PARTY_PK:-$BIONIC_HOOKS_DIR/session-poker.sh}"
}

# THE CONTROL FIRST. The same throwaway tree with an UNMUTATED library must give the same
# answers the shipped tree did, or every move below is the copying and not the mutation.
cp "$RUN_LIB" "$S4_MUT/scripts/lib/run.sh"
s4_repoint
S4_CTRL=$(s4_pk "$S4_R2" "$SID_A")
expect_contains "control: the copied tree with an UNMUTATED library still honours the binding" \
  "$S4_R2A" "$S4_CTRL"

sed 's/  if plan=$(session_plan "$root" "$sid"); then/  if false \&\& plan=$(session_plan "$root" "$sid"); then/' \
  "$RUN_LIB" > "$S4_MUT/scripts/lib/run.sh"

# EVERY ANNOUNCER MOVES. On the S.4b world session A is bound to a CLOSED plan while the
# neighbour's is open and newest, so the two answers are maximally far apart: honouring the
# binding says "closed, plan A"; ignoring it says "fallback, plan B". Both halves are
# asserted for each consumer — the closed line must be GONE and the neighbour's plan must
# now be NAMED — because either alone would pass on a consumer that had simply fallen silent.
while IFS='|' read -r _n _fn; do
  [ -n "$_n" ] || continue
  _out=$("$_fn" "$S4_R2" "$SID_A")
  expect_false   "mutated session_run: $_n stops saying the bound plan is closed" \
    grep -qE "$S4_CLOSED_RE" <<<"$_out"
  expect_contains "…and answers for the neighbour's run instead — the pre-wave bug, reproduced" \
    "$S4_R2B" "$_out"
done <<S4EOF
$S4_ANNOUNCERS
S4EOF

s4_restore
# AND THE RESTORE IS PROVED, not assumed: the same drive that moved must move back, or every
# section after this one is running against a mutant.
expect_contains "restored: the shipped tree honours the binding again" \
  "$S4_R2A" "$(s4_pk "$S4_R2" "$SID_A")"

# ============================================================
section "B2 — THE SESSION'S BOUND PLAN: three writers, one marker shape"
# ============================================================
#
# THE OWNERSHIP-TABLE ROW (spec §Design): "the session's bound plan · owning module
# lib/binding.sh bind_plan · rendering surfaces: engage.sh, poker `bind`, governing-skill
# bind-on-write · agreement test: three callers produce one marker shape; a doctored caller
# goes red".
#
# WHY A SHAPE AND NOT A VALUE. The marker is read by `session_plan`, which takes the `plan=`
# line and nothing else — so a caller that wrote the two lines in the other order, or dropped
# `engaged_at=`, or left the file 0644, would still be READ correctly today and would still
# be wrong: `engaged_at` is what the re-engagement path carries forward, and 0600 is the
# invariant the marker has had since it existed. A shape that only one of three writers keeps
# is a shape the next reader cannot rely on.
#
# ONE REPOSITORY, THREE CALLERS, THREE SESSIONS. Same root, same plan, three session ids —
# so the only thing that can differ between the three markers is the WRITER. The three are
# then compared to each other after the timestamp VALUE is masked (it is a clock reading, not
# a shape), which is what leaves the comparison about the shape.

B2_REPO=$(new_repo "b2-one-marker-shape")
B2_PLAN="$B2_REPO/.bionic/docs/plans/epic-99/only-run.md"
write_plan "$B2_PLAN" "current: 4"
B2_SID_E="e2e2e2e2-1111-4bbb-8ccc-000000000001"   # engage.sh's session
B2_SID_P="e2e2e2e2-2222-4bbb-8ccc-000000000002"   # poker bind's session
B2_SID_G="e2e2e2e2-3333-4bbb-8ccc-000000000003"   # the governing skill's session
B2_MARK="$B2_REPO/.bionic/tmp/engaged-"

PARTY_ENGAGE="$BIONIC_HOOKS_DIR/engage.sh"

# b2_shape <marker> -> the marker with the timestamp VALUE masked, plus its mode
b2_shape() {
  [ -f "$1" ] || { printf 'ABSENT\n'; return 0; }
  sed 's/^engaged_at=.*/engaged_at=<iso>/' "$1"
  printf 'mode=%s\n' "$(ls -l "$1" | cut -c1-10)"
}

# WRITER 1 — the engage hook, on the act that creates the relationship (AC-7). Exactly one
# open run in this root, so engagement binds it rather than writing `plan=none`.
jq -nc --arg c "$B2_REPO" --arg s "$B2_SID_E" \
  '{session_id:$s, cwd:$c, hook_event_name:"PreToolUse", tool_name:"Skill",
    tool_input:{skill:"bionic:canonical-sdlc"}}' \
  | ( cd "$B2_REPO" && env CLAUDE_CODE_SESSION_ID="$B2_SID_E" bash "$PARTY_ENGAGE" ) >/dev/null 2>&1

# WRITER 2 — the poker's `bind` verb, the hand-driven one (AC-8). It refuses an unengaged
# caller, so the session is engaged first exactly as the field produces it.
: > "${B2_MARK}${B2_SID_P}.state"
( cd "$B2_REPO" && env CLAUDE_CODE_SESSION_ID="$B2_SID_P" bash "$SPO" bind "$B2_PLAN" ) >/dev/null 2>&1

# WRITER 3 — the governing skill's bind-on-first-write, at PostToolUse (AC-9). The plan
# already exists here, which is what the arm requires; `tool_response.type` says `create`.
: > "${B2_MARK}${B2_SID_G}.state"
jq -n --arg p "$B2_PLAN" --arg s "$B2_SID_G" \
  '{session_id:$s, hook_event_name:"PostToolUse", tool_name:"Write",
    tool_input:{file_path:$p, content:"x"}, tool_response:{type:"create", filePath:$p}}' \
  | env HOME="$B2_REPO" CLAUDE_CODE_SESSION_ID="$B2_SID_G" bash "$PARTY_SG_W" >/dev/null 2>&1

B2_E=$(b2_shape "${B2_MARK}${B2_SID_E}.state")
B2_P=$(b2_shape "${B2_MARK}${B2_SID_P}.state")
B2_G=$(b2_shape "${B2_MARK}${B2_SID_G}.state")

# NON-VACUITY FIRST. Three empty strings compare equal, and an empty marker is what a
# refusing writer leaves behind — so each answer is pinned by VALUE before the three are
# compared to each other.
expect_contains "engage.sh bound the sole open run" "plan=$B2_PLAN" "$B2_E"
expect_contains "poker bind wrote the plan it was handed"  "plan=$B2_PLAN" "$B2_P"
expect_contains "the governing skill bound the plan its Write created" "plan=$B2_PLAN" "$B2_G"

expect_eq "engage.sh and poker bind write ONE marker shape" "$B2_E" "$B2_P"
expect_eq "…and so does the governing skill's bind-on-write" "$B2_E" "$B2_G"
# S5a NOTE (AC-12 migration): this needle is genuinely two lines, and the framework's
# expect_contains (a `case` glob) requires them contiguous and in order — stricter than
# the pre-migration private definition (`grep -F`, which reads the embedded newline as
# alternation and would have passed on EITHER line alone). b2_shape's own output always
# writes `plan=` then `engaged_at=` adjacent, so this call site never relied on the
# looser reading; before/after tallies for this assertion agree (see s5a-report.md).
expect_contains "…which is the two-line shape, plan first" "plan=$B2_PLAN
engaged_at=<iso>" "$B2_E"
expect_contains "…at mode 0600, the invariant the marker has always carried" "rw-------" "$B2_E"

# THE DISCRIMINATOR — one caller doctored, and the pin must go red. `engage.sh` is copied
# into a throwaway plugin-shaped tree and its `bind_plan` call is replaced by an inline
# write, which is exactly the shape this file carried BEFORE lib/binding.sh existed
# (hooks/engage.sh:275-290, pre-wave) — a plausible regression, not damage. The shipped hook
# is never touched.
B2_MUT="$SANDBOX/b2-mutant"
mkdir -p "$B2_MUT/hooks" "$B2_MUT/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$B2_MUT/scripts/lib/" 2>/dev/null
cp "$BIONIC_HOOKS_DIR"/*.sh "$B2_MUT/hooks/" 2>/dev/null
anchor "$PARTY_ENGAGE" 'bind_plan "$REPO" "$SID"' 1
awk '
  /bind_plan "\$REPO" "\$SID"/ && !done {
    print "    printf '"'"'engaged_at=%s\\nplan=%s\\n'"'"' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"$PLAN\" > \"$MARKER\""
    done = 1
    next
  }
  { print }
' "$PARTY_ENGAGE" > "$B2_MUT/hooks/engage.sh"

B2_SID_M="e2e2e2e2-4444-4bbb-8ccc-000000000004"
jq -nc --arg c "$B2_REPO" --arg s "$B2_SID_M" \
  '{session_id:$s, cwd:$c, hook_event_name:"PreToolUse", tool_name:"Skill",
    tool_input:{skill:"bionic:canonical-sdlc"}}' \
  | ( cd "$B2_REPO" && env CLAUDE_CODE_SESSION_ID="$B2_SID_M" bash "$B2_MUT/hooks/engage.sh" ) >/dev/null 2>&1
B2_M=$(b2_shape "${B2_MARK}${B2_SID_M}.state")
expect_eq "a doctored writer's marker is NOT the shape the other two agree on (§B2 discriminates)" \
  "no" "$([ "$B2_M" = "$B2_P" ] && echo yes || echo no)"
# …AND IT IS NOT DISCRIMINATED BY BEING EMPTY. The mutant really did write a marker naming
# the same plan; what differs is only the shape, which is the whole claim of this section.
expect_contains "…while still naming the same plan, so the difference is the SHAPE" \
  "plan=$B2_PLAN" "$B2_M"

# ============================================================
section "OR — THE OPEN-RUN SET: active_run's answer is always a member of open_runs"
# ============================================================
#
# THE OWNERSHIP-TABLE ROW (spec §Design): "the open-run set · owning module lib/run.sh
# open_runs · rendering surfaces: engage uniqueness, session-start listing, poker `bind`
# validation". `tests/run-predicate.test.sh` owns the set's own behaviour over 0/1/2-member
# fixtures; what belongs HERE is the relation between the set and the answer every pre-wave
# reader still takes — because three surfaces now decide from the SET while every fallback in
# the fleet still decides from `active_run`, and a set that did not contain that answer would
# let engagement bind a plan no consumer would then resolve.
#
# THE SENTENCE IS QUALIFIED, AND THE QUALIFICATION IS THE POINT (S1 assumption 1). "Line 1 of
# `open_runs` equals `active_run`'s answer" is true only WHEN `active_run` HAS an answer. The
# case where it does not is not an edge: the newest plan in the root is CLOSED, `active_run`
# exits 1 with nothing while the set is non-empty, and that is precisely the state a
# session-keyed reader exists to survive. Writing the unqualified sentence here would pin a
# claim the library contradicts by design.

OR_LIB_SRC="$RUN_LIB"
# THE STATUS COMES BACK THROUGH THE STRING, not through a variable. `$( … )` is a SUBSHELL:
# a status assigned inside it is discarded at the closing paren, so the obvious spelling
# (`out=$(…); OR_ST=$?`) captures the SUBSHELL's status — always 0 here — and an `OR_ST` read
# afterwards is either stale or, under this file's `set -u`, an abort. Both halves ride one
# capture, separated by a byte no path can contain.
or_ask() {  # <root> <function> -> sets OR_OUT and OR_ST
  local root="$1"; shift
  local raw
  raw=$( . "$OR_LIB_SRC" >/dev/null 2>&1; "$@" "$root" 2>/dev/null; printf '\037%s' "$?" )
  OR_ST="${raw##*$'\037'}"
  OR_OUT="${raw%$'\037'*}"
  # …AND THE TRAILING NEWLINE GOES WITH IT. `$( … )` strips trailing newlines from the whole
  # capture, but the status marker sits after them, so they survive inside OR_OUT and every
  # exact compare below would be off by one byte.
  OR_OUT="${OR_OUT%$'\n'}"
  printf '%s' "$OR_OUT"
}

# --- OR.1 two open plans: the set has both, and line 1 IS active_run's answer ---
OR_R1=$(new_repo "or-two-open")
write_plan "$OR_R1/.bionic/docs/plans/epic-99/older.md" "current: 4"
write_plan "$OR_R1/.bionic/docs/plans/epic-99/newest.md" "current: 6"
s_backdate "$OR_R1/.bionic/docs/plans/epic-99/older.md"
or_ask "$OR_R1" open_runs >/dev/null;  OR_SET="$OR_OUT"
or_ask "$OR_R1" active_run >/dev/null; OR_AR="$OR_OUT"; OR_AR_ST="$OR_ST"
expect_eq "the set has both open plans (non-vacuity: this is not an empty answer)" "2" \
  "$(printf '%s\n' "$OR_SET" | grep -c '\.md$')"
expect_eq "active_run has an answer here" "0" "$OR_AR_ST"
expect_eq "…and it is line 1 of the set, newest first" \
  "$OR_AR" "$(printf '%s\n' "$OR_SET" | head -1)"
expect_true "…and active_run's answer is a MEMBER of the set" \
  grep -qxF -- "$OR_AR" <<<"$OR_SET"

# --- OR.2 a CLOSED plan is in neither, and both answers move together -----------
OR_R2=$(new_repo "or-closed-newest")
write_plan "$OR_R2/.bionic/docs/plans/epic-99/open-older.md" "current: 4"
s4_close "$OR_R2/.bionic/docs/plans/epic-99/closed-newest.md"
s_backdate "$OR_R2/.bionic/docs/plans/epic-99/open-older.md"
or_ask "$OR_R2" open_runs >/dev/null;  OR_SET2="$OR_OUT"
or_ask "$OR_R2" active_run >/dev/null; OR_AR2="$OR_OUT"; OR_AR2_ST="$OR_ST"
# THE QUALIFICATION, ASSERTED RATHER THAN NARRATED. The newest file is closed, so `active_run`
# has NO answer while the set is not empty — the one case where the equality above does not
# hold, and the reason its sentence carries a "when".
expect_eq "the newest plan is closed, so active_run has no answer at all" "1" "$OR_AR2_ST"
expect_eq "…while the set is NOT empty: it still holds the older open plan" \
  "$OR_R2/.bionic/docs/plans/epic-99/open-older.md" "$OR_SET2"
expect_absent "…and the closed plan is in neither" \
  "closed-newest.md" "$OR_SET2$OR_AR2"

# --- OR.3 THE DISCRIMINATOR: mutate run_open, and both readers move together ----
#
# `run_open` is the one predicate `open_runs` and `active_run` share. Force it open and the
# closed plan joins the set AND becomes active_run's answer — so a mutation to the shared
# predicate moves BOTH, which is what "one owner" means here. A copy is mutated; the shipped
# library is untouched.
OR_MUT="$SANDBOX/or-mutant-run.sh"
anchor -E "$OR_LIB_SRC" '^run_open\(\) \{' 1
awk '
  /^run_open\(\) \{/ && !d { print; print "  [ -f \"$1\" ] && return 0"; d = 1; next }
  { print }
' "$OR_LIB_SRC" > "$OR_MUT"
OR_LIB_SRC="$OR_MUT"
or_ask "$OR_R2" open_runs >/dev/null;  OR_SET3="$OR_OUT"
or_ask "$OR_R2" active_run >/dev/null; OR_AR3="$OR_OUT"; OR_AR3_ST="$OR_ST"
OR_LIB_SRC="$RUN_LIB"
expect_eq "mutated run_open: the closed plan joins the set" "2" \
  "$(printf '%s\n' "$OR_SET3" | grep -c '\.md$')"
expect_eq "…and becomes active_run's answer, which it was not a moment ago" "0" "$OR_AR3_ST"
expect_contains "…which is the closed plan itself" "closed-newest.md" "$OR_AR3"
expect_true "…and the relation still holds: the answer is still a member of the set" \
  grep -qxF -- "$OR_AR3" <<<"$OR_SET3"
or_ask "$OR_R2" active_run >/dev/null
expect_eq "restored: the shipped library answers as it did before the mutation" \
  "$OR_AR2_ST" "$OR_ST"

# ============================================================
section "RA — ROSTER ATTRIBUTION: two row writers, one plan= field"
# ============================================================
#
# THE OWNERSHIP-TABLE ROW (spec §Design): "roster attribution · owning module
# dispatch-preflight.sh row writer · rendering surface: `adopt`'s partition".
#
# TWO WRITERS PUT ROWS ON A ROSTER. `hooks/dispatch-preflight.sh` writes the row for an agent
# this session LAUNCHES; `hooks/session-poker.sh adopt` writes the row for an agent this
# session TAKES OVER. `adopt`'s partition then reads `plan=` off every foreign row to decide
# what is adoptable — so the field has to mean the same thing on both, or the partition is
# reading two schemas and calling them one. It shipped on the dispatch writer alone (S5) and
# was added to the adopt writer at S8; before that an adopted row was the one row on any
# roster carrying no attribution, and a THIRD session bound to the same plan re-read this
# session's own adoption as `unattributed` and declined to take it.
#
# THE VALUE IS THE WRITING SESSION'S BINDING IN BOTH CASES — not the launching session's, and
# not the row's previous owner's. That is what makes the field answer one question ("which
# run does this row belong to") rather than two.
#
# ONE FIXTURE, BOTH WRITERS, ONE EXTRACTOR. The field is pulled out by KEY, not by position,
# by the same helper for both rows — a positional read would pass on two rows that agreed
# about the value and disagreed about where it sits.

ra_field() {  # <row> <key> -> the field's value
  printf '%s' "$1" | tr '|' '\n' | grep "^$2=" | head -1 | cut -d= -f2-
}

RA_REPO=$(new_repo "ra-attribution")
RA_PLAN="$RA_REPO/.bionic/docs/plans/epic-99/ra-run.md"
write_plan "$RA_PLAN" "current: 4"
RA_PRED="ra111111-2222-4bbb-8ccc-000000000099"
RA_PRED_ID="arapred-9999999999999999"
s4_attest "$RA_REPO" "$SID_A"

# WRITER 1 — the dispatch wall, from a session bound to RA_PLAN.
s4_bind "$RA_REPO" "$SID_A" "$RA_PLAN"
mk_agent_payload "$SID_A" "$RA_REPO" | env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PARTY_DP" >/dev/null 2>&1
RA_DISPATCH_ROW=$(grep '^roster-state/' "$RA_REPO/.bionic/tmp/roster-$SID_A.state" 2>/dev/null | tail -1)

# WRITER 2 — `adopt`, from a session bound to the SAME plan, over a predecessor's row.
# The predecessor's row carries `plan=` too, so it partitions as `own` and is journalled;
# that it does so is §17's claim in tests/session-poker.test.sh, not this section's.
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$RA_REPO" | sed 's/[^a-zA-Z0-9]/-/g')/$RA_PRED/subagents"
roster_row_fixture status=identified session="$RA_PRED" name=ra-writer \
  agent_id="$RA_PRED_ID" launched_at=2026-08-05T00:00:00Z tool_use_id=toolu_01RAFIX \
  plan="$RA_PLAN" >> "$RA_REPO/.bionic/tmp/roster-$RA_PRED.state"
s4_bind "$RA_REPO" "$SID_B" "$RA_PLAN"
( cd "$RA_REPO" && env CLAUDE_CODE_SESSION_ID="$SID_B" bash "$SPO" adopt ) >/dev/null 2>&1
RA_ADOPT_ROW=$(grep "agent_id=$RA_PRED_ID" "$RA_REPO/.bionic/tmp/roster-$SID_B.state" 2>/dev/null | tail -1)

# NON-VACUITY: both rows exist and are not the same row.
expect_eq "the dispatch wall wrote a row" "yes" \
  "$([ -n "$RA_DISPATCH_ROW" ] && echo yes || echo no)"
expect_eq "…and adopt wrote one on the other session's roster" "yes" \
  "$([ -n "$RA_ADOPT_ROW" ] && echo yes || echo no)"
expect_eq "…and they are two different rows" "no" \
  "$([ "$RA_DISPATCH_ROW" = "$RA_ADOPT_ROW" ] && echo yes || echo no)"

# THE AGREEMENT: same field name, same value rule, same position.
expect_eq "the dispatched row is attributed to its writer's bound plan" \
  "$RA_PLAN" "$(ra_field "$RA_DISPATCH_ROW" plan)"
expect_eq "…and the adopted row to ITS writer's bound plan, by the same rule" \
  "$RA_PLAN" "$(ra_field "$RA_ADOPT_ROW" plan)"
expect_eq "…the field is last on both rows, so a positional reader sees one schema" \
  "$(printf '%s' "$RA_DISPATCH_ROW" | sed 's/.*|\(plan=[^|]*\)$/\1/')" \
  "$(printf '%s' "$RA_ADOPT_ROW" | sed 's/.*|\(plan=[^|]*\)$/\1/')"

# THE UNBOUND SPELLING IS ALSO ONE WORD. Both writers say the literal `none`, never an empty
# field — an empty `plan=` and an absent `plan=` are the same thing to a key-based reader,
# and `adopt` needs to tell "this session had no binding" from "this row predates the field".
RA_REPO_U=$(new_repo "ra-unbound")
RA_PLAN_U="$RA_REPO_U/.bionic/docs/plans/epic-99/ra-run.md"
write_plan "$RA_PLAN_U" "current: 4"
s4_attest "$RA_REPO_U" "$SID_A"
mk_agent_payload "$SID_A" "$RA_REPO_U" | env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PARTY_DP" >/dev/null 2>&1
RA_DISPATCH_U=$(grep '^roster-state/' "$RA_REPO_U/.bionic/tmp/roster-$SID_A.state" 2>/dev/null | tail -1)
roster_row_fixture status=identified session="$RA_PRED" name=ra-writer \
  agent_id="$RA_PRED_ID" launched_at=2026-08-05T00:00:00Z tool_use_id=toolu_01RAFIX \
  plan=none >> "$RA_REPO_U/.bionic/tmp/roster-$RA_PRED.state"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$RA_REPO_U" | sed 's/[^a-zA-Z0-9]/-/g')/$RA_PRED/subagents"
( cd "$RA_REPO_U" && env CLAUDE_CODE_SESSION_ID="$SID_B" bash "$SPO" adopt ) >/dev/null 2>&1
RA_ADOPT_U=$(grep "agent_id=$RA_PRED_ID" "$RA_REPO_U/.bionic/tmp/roster-$SID_B.state" 2>/dev/null | tail -1)
expect_eq "an unbound dispatcher writes the literal none" "none" "$(ra_field "$RA_DISPATCH_U" plan)"
expect_eq "…and so does an unbound adopter, the same word from the other writer" \
  "none" "$(ra_field "$RA_ADOPT_U" plan)"

# THE DISCRIMINATOR — drop the field from ONE writer and the agreement must break. The adopt
# writer is the one doctored, because it is the one the field was added to last and therefore
# the one a later reader is most likely to "simplify" back out. A copy; the shipped hook is
# never touched.
RA_MUT="$SANDBOX/ra-mutant"
mkdir -p "$RA_MUT/hooks" "$RA_MUT/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$RA_MUT/scripts/lib/" 2>/dev/null
cp "$BIONIC_HOOKS_DIR"/*.sh "$RA_MUT/hooks/" 2>/dev/null
# The field is now an ARGUMENT to `roster_row` rather than a slot in a format string
# (S14, AC-25), so the doctoring deletes the line that passes it. What the mutant writes
# is `plan=` empty rather than no `plan=` at all, and both are the same thing to the
# reader under test: `ra_field` returns "" either way, and the row is still written.
anchor "$SPO" '"plan=$(clean "$plan")"' 1
sed '/"plan=$(clean "$plan")"/d' \
  "$SPO" > "$RA_MUT/hooks/session-poker.sh"
RA_REPO_M=$(new_repo "ra-mutant-repo")
RA_PLAN_M="$RA_REPO_M/.bionic/docs/plans/epic-99/ra-run.md"
write_plan "$RA_PLAN_M" "current: 4"
roster_row_fixture status=identified session="$RA_PRED" name=ra-writer \
  agent_id="$RA_PRED_ID" launched_at=2026-08-05T00:00:00Z tool_use_id=toolu_01RAFIX \
  plan="$RA_PLAN_M" >> "$RA_REPO_M/.bionic/tmp/roster-$RA_PRED.state"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$RA_REPO_M" | sed 's/[^a-zA-Z0-9]/-/g')/$RA_PRED/subagents"
s4_bind "$RA_REPO_M" "$SID_B" "$RA_PLAN_M"
( cd "$RA_REPO_M" && env CLAUDE_CODE_SESSION_ID="$SID_B" bash "$RA_MUT/hooks/session-poker.sh" adopt ) >/dev/null 2>&1
RA_ADOPT_M=$(grep "agent_id=$RA_PRED_ID" "$RA_REPO_M/.bionic/tmp/roster-$SID_B.state" 2>/dev/null | tail -1)
expect_eq "…and a doctored adopt writer leaves the row unattributed (§RA discriminates)" \
  "" "$(ra_field "$RA_ADOPT_M" plan)"
# NOT DISCRIMINATED BY WRITING NOTHING: the mutant still wrote a row, it just left the field off.
expect_contains "…while still writing the row, so the difference is the FIELD" \
  "$RA_PRED_ID" "$RA_ADOPT_M"

# --- §RA.2 — ONE WRITER OF roster-state/v1, PINNED TO A CAPTURED REAL ROW ----------
#
# (wave-01 verification-cannot-lie, S14; spec AC-25; design ledger D3.)
#
# WHAT THIS ROW USED TO SAY, AND WHY IT CHANGED. Until S14 the schema had TWO producers
# sharing no builder — `hooks/dispatch-preflight.sh`'s `ROW=` and
# `hooks/session-poker.sh`'s `adopt_write_row` — so the obligation here was a KEY-SET
# COMPARISON scraped out of the two source files: same keys in the same order, plus two
# adopt-only names listed by hand (Step-6 review D-8). That comparison could only ever
# notice the two writers disagreeing WITH EACH OTHER. Both drifting together, away from
# what the fleet's readers parse, was invisible to it — and "wrong but agreeing" is
# exactly the fog D3 ruled unacceptable. `roster_row` (payload/scripts/lib/roster.sh) is
# now the one writer, so the two CANNOT disagree any more, and the obligation becomes the
# one thing the old shape could not check: that the one writer still emits the row the
# fleet actually has on disk.
#
# THE PIN IS AGAINST A CAPTURE, NOT AN EXPECTATION. tests/fixtures/roster-row.captured
# holds two rows written by the two production call sites BEFORE either of them called
# `roster_row`; its header records which line came from which writer and from where.
# Comparing the one writer against a string this repo also wrote is a self-comparison —
# both halves move together and the pin survives any drift. A row the function did not
# write is the only version of this claim that can fail.
#
# THE ARGUMENTS ARE THE CAPTURE'S OWN FIELDS, HANDED OVER BACKWARDS. The test splits the
# captured row on `|`, gives `roster_row` the resulting `key=value` bag in REVERSE order,
# and requires the original line back. Field ORDER, field PRESENCE and the separators are
# therefore all the function's to supply; none of them can be echoed out of the input.
# The adopt row's two extra fields (`teammate_id=`, `adopted_from=`) are pinned in the one
# place they belong — a real row — instead of being listed by name in a test that would
# have to be edited to admit a third.
RA2_ROSTER_LIB="$BIONIC_HOOKS_DIR/../payload/scripts/lib/roster.sh"
[ -r "$RA2_ROSTER_LIB" ] || RA2_ROSTER_LIB="$BIONIC_HOOKS_DIR/../scripts/lib/roster.sh"
RA2_CAPTURE="$REPO_ROOT/tests/fixtures/roster-row.captured"

ra2_captured() {  # <status> -> the one captured row carrying that status
  LC_ALL=C grep "^${ROSTER_ROW_SCHEMA}|status=$1|" "$RA2_CAPTURE" 2>/dev/null | head -1
}

# The rebuild. `$( … )` is a subshell, so sourcing the library here cannot leak
# `roster_row` into the rest of this suite — every call pays for its own load, which is
# also what makes the mutant-library arm below a real substitution rather than a
# redefinition racing the first source.
ra2_rebuild() {  # <row> [library path] -> roster_row's output for that row's own fields
  local row="$1" lib="${2:-$RA2_ROSTER_LIB}" f
  local args=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    args=("$f" ${args[@]+"${args[@]}"})   # prepend: the bag reaches roster_row REVERSED
  done <<RA2_FIELDS
$(printf '%s' "$row" | tr '|' '\n' | tail -n +2)
RA2_FIELDS
  [ "${#args[@]}" -gt 0 ] || return 1
  ( . "$lib" >/dev/null 2>&1 && roster_row "${args[@]}" )
}

RA2_CAP_I="$(ra2_captured intended)"
RA2_CAP_A="$(ra2_captured identified)"
# NON-VACUITY FIRST: a capture that failed to load would make every equality below compare
# two empty strings and pass. Each row is checked for the field that identifies its writer.
expect_contains "the capture holds the launch-time row (dispatch-preflight's)" \
  "|status=intended|" "$RA2_CAP_I"
expect_contains "the capture holds the adopt-time row (session-poker's), with its extras" \
  "|adopted_from=" "$RA2_CAP_A"

expect_eq "roster_row reproduces the captured launch-time row byte for byte" \
  "$RA2_CAP_I" "$(ra2_rebuild "$RA2_CAP_I")"
expect_eq "roster_row reproduces the captured adopt-time row byte for byte" \
  "$RA2_CAP_A" "$(ra2_rebuild "$RA2_CAP_A")"

# THE MUTATION ARMS. Two, because the pin has two halves that can rot independently.
#
# ARM 1 — DOCTOR THE ROW. One field's value is changed in the capture handed to the
# rebuild; the output must then differ from the untouched capture. This is what proves the
# equality above is load-bearing rather than comparing a value to itself.
RA2_DOCTORED="$(printf '%s' "$RA2_CAP_I" | sed 's/|subagent_type=[^|]*|/|subagent_type=DOCTORED|/')"
expect_eq "the row-doctoring arm really changed one field" "yes" \
  "$([ "$RA2_DOCTORED" != "$RA2_CAP_I" ] && echo yes || echo no)"
expect_eq "…and the pin goes red on it (the doctored field does not reproduce the capture)" "no" \
  "$([ "$(ra2_rebuild "$RA2_DOCTORED")" = "$RA2_CAP_I" ] && echo yes || echo no)"
expect_contains "…and what came back carries the doctored value, so the writer was really driven" \
  "subagent_type=DOCTORED" "$(ra2_rebuild "$RA2_DOCTORED")"

# ARM 2 — DOCTOR THE WRITER. A copy of the library drops one field from the row it emits.
# This is the drift the pin exists for: the one writer moving away from the shape on disk.
RA2_MUT="$SANDBOX/ra2-mutant"
mkdir -p "$RA2_MUT"
sed 's/|absent=\$absent//' "$RA2_ROSTER_LIB" > "$RA2_MUT/roster.sh"
expect_eq "the writer-doctoring arm really removed absent= from the emitted row" "yes" \
  "$([ "$(LC_ALL=C grep -c 'absent=\$absent' "$RA2_MUT/roster.sh" | tr -d ' ')" = "0" ] && echo yes || echo no)"
expect_eq "…and the pin goes red on the mutated writer" "no" \
  "$([ "$(ra2_rebuild "$RA2_CAP_I" "$RA2_MUT/roster.sh")" = "$RA2_CAP_I" ] && echo yes || echo no)"

# BOTH CALL SITES REALLY ROUTE THROUGH IT. The pin above proves the FUNCTION is right; these
# two prove the hooks are its callers, which is the other half of "one writer". The absence
# assertion is paired with the positive one on purpose: a hook that deleted its row
# entirely would satisfy the absence alone.
# THE PATTERN MUST NOT CATCH READERS. Both hooks still SELECT rows by prefix
# (`hooks/dispatch-preflight.sh`'s prune, `hooks/session-poker.sh`'s open-row grep) and a
# prefix test names `status=` without ever naming `session=`. A row being BUILT always
# carries the session it belongs to, so that is what separates the two.
ra2_code_hits() {  # <file> <extended regex> -> matching lines, whole-line comments removed
  LC_ALL=C grep -nE -- "$2" "$1" 2>/dev/null | LC_ALL=C grep -v ':[[:space:]]*#' | wc -l | tr -d ' '
}
RA2_BUILT_ROW='roster-state/[^|]*\|status=[a-z]+\|session='
RA2_DP="$BIONIC_HOOKS_DIR/dispatch-preflight.sh"
RA2_PK="$BIONIC_HOOKS_DIR/session-poker.sh"
expect_eq "dispatch-preflight builds its row by calling roster_row, and holds no row literal" \
  "1 0" "$(ra2_code_hits "$RA2_DP" 'roster_row ') $(ra2_code_hits "$RA2_DP" "$RA2_BUILT_ROW")"
expect_eq "session-poker's adopt builds its row by calling roster_row, and holds no row literal" \
  "1 0" "$(ra2_code_hits "$RA2_PK" 'roster_row ') $(ra2_code_hits "$RA2_PK" "$RA2_BUILT_ROW")"


# ============================================================
section "LR — THE LIVE-RUN SET: live_runs is always a subset of open_runs"
# ============================================================
#
# THE OWNERSHIP-TABLE ROW (spec §Design §3): "run is live · owning module `live_runs`
# (run.sh) · rendering surfaces: engage (bind), session-start (list + quiet count) ·
# agreement test: cross-gate new row: live ⊆ open; mutate `run_open`, both move; anti-vacuity
# arm". AC-5 words the obligation directly.
#
# WHY THE RELATION AND NOT THE SET. `tests/run-predicate.test.sh` owns what `live_runs`
# answers over 0/1/2-member fixtures; it cannot see the thing this file exists for. Two
# surfaces decide from the LIVE set (engage binds when exactly one run is live;
# session-start lists the live ones and counts the rest as quiet) while every gate in the
# fleet still rules on the OPEN set — so a live run that was not open would be a binding
# `session_run` then refuses, and `run_open` is the one predicate that can put it there.
# §OR above holds `active_run` to the same set from the other side.
#
# THE SUBSET CLAIM IS ONLY WORTH ASSERTING WHERE THE TWO SETS DIFFER. A fixture where every
# open run is also live makes `live ⊆ open` true by equality, which is the vacuous reading of
# it — so this world carries all three shapes at once: a FRESH open plan (live), a BACKDATED
# open plan (open, outside the `live-window:`, not live) and a DELIVERED plan (neither).

LR_LIB_SRC="$RUN_LIB"

# The status rides back inside the string for the reason §OR's `or_ask` gives: `$( … )` is a
# subshell and a status assigned inside it dies at the closing paren.
lr_ask() {  # <root> <function> -> sets LR_OUT and LR_ST
  local root="$1"; shift
  local raw
  raw=$( . "$LR_LIB_SRC" >/dev/null 2>&1; "$@" "$root" 2>/dev/null; printf '\037%s' "$?" )
  LR_ST="${raw##*$'\037'}"
  LR_OUT="${raw%$'\037'*}"
  LR_OUT="${LR_OUT%$'\n'}"
  printf '%s' "$LR_OUT"
}

# THE RELATION ITSELF, COMPUTED — never eyeballed from two printed sets. Returns how many
# lines of <live> are absent from <open>; zero IS the subset claim, and any other number is
# the counterexample named.
lr_missing() {  # <live> <open> -> count of live lines that are not open lines
  local l n=0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    grep -qxF -- "$l" <<<"$2" || n=$((n + 1))
  done <<<"$1"
  printf '%s' "$n"
}

# A plan older than the default 7-day `live-window:`. `s_backdate`'s hour is what makes one
# plan lose an ORDERING; days are what put a plan outside the WINDOW, and those are different
# fixture facts even though both are a `touch`.
lr_backdate_days() {  # <file> <days>
  touch -t "$(date -v-"$2"d +%Y%m%d%H%M.%S 2>/dev/null \
              || date -d "-$2 days" +%Y%m%d%H%M.%S)" "$1"
}

LR_R=$(new_repo "lr-live-subset")
LR_FRESH="$LR_R/.bionic/docs/plans/epic-99/lr-fresh.md"
LR_STALE="$LR_R/.bionic/docs/plans/epic-99/lr-backdated.md"
LR_DONE="$LR_R/.bionic/docs/plans/epic-99/lr-delivered.md"
write_plan "$LR_FRESH" "current: 4"
write_plan "$LR_STALE" "current: 6"
s4_close "$LR_DONE"
lr_backdate_days "$LR_STALE" 30

lr_ask "$LR_R" open_runs >/dev/null; LR_OPEN="$LR_OUT"; LR_OPEN_ST="$LR_ST"
lr_ask "$LR_R" live_runs >/dev/null; LR_LIVE="$LR_OUT"; LR_LIVE_ST="$LR_ST"

# --- LR.1 the fixture really carries all three shapes (non-vacuity) -------------
expect_eq "open_runs answers here" "0" "$LR_OPEN_ST"
expect_eq "live_runs answers here" "0" "$LR_LIVE_ST"
expect_eq "the open set holds BOTH open plans, fresh and backdated" "2" \
  "$(printf '%s\n' "$LR_OPEN" | grep -c '\.md$')"
expect_eq "…while the live set holds exactly one: the two sets are NOT equal here" "1" \
  "$(printf '%s\n' "$LR_LIVE" | grep -c '\.md$')"
expect_contains "the fresh plan is live" "lr-fresh.md" "$LR_LIVE"
expect_absent "…and the backdated plan is not, though it IS open" "lr-backdated.md" "$LR_LIVE"
expect_contains "…which is what makes the subset claim below a real one" \
  "lr-backdated.md" "$LR_OPEN"

# --- LR.2 THE RELATION: live ⊆ open, and the delivered plan is in neither -------
expect_eq "every live run is an open run (AC-5)" "0" "$(lr_missing "$LR_LIVE" "$LR_OPEN")"
expect_absent "the delivered plan is not open" "lr-delivered.md" "$LR_OPEN"
expect_absent "…and not live either" "lr-delivered.md" "$LR_LIVE"

# --- LR.3 THE SHARED PREDICATE: mutate run_open and BOTH readers move ----------
#
# `run_open` is the one predicate `open_runs` walks and `live_runs` inherits by calling it.
# Force it open and the DELIVERED plan — whose mtime is fresh, so the window admits it —
# joins the open set AND the live set in one step. A mutation that moved only one of them
# would mean `live_runs` had a second opinion about openness, which is the defect this row
# exists to catch. The shipped library is never touched: a copy is mutated in the sandbox.
LR_MUT_OPEN="$SANDBOX/lr-mutant-run-open.sh"
anchor -E "$RUN_LIB" '^run_open\(\) \{' 1
awk '
  /^run_open\(\) \{/ && !d { print; print "  [ -f \"$1\" ] && return 0"; d = 1; next }
  { print }
' "$RUN_LIB" > "$LR_MUT_OPEN"

LR_LIB_SRC="$LR_MUT_OPEN"
lr_ask "$LR_R" open_runs >/dev/null; LR_OPEN_M="$LR_OUT"
lr_ask "$LR_R" live_runs >/dev/null; LR_LIVE_M="$LR_OUT"
LR_LIB_SRC="$RUN_LIB"

expect_eq "mutated run_open: the open set gains the delivered plan" "3" \
  "$(printf '%s\n' "$LR_OPEN_M" | grep -c '\.md$')"
expect_eq "…and the LIVE set gains it too, in the same step" "2" \
  "$(printf '%s\n' "$LR_LIVE_M" | grep -c '\.md$')"
expect_contains "…by name, on the open side" "lr-delivered.md" "$LR_OPEN_M"
expect_contains "…and by name on the live side" "lr-delivered.md" "$LR_LIVE_M"
expect_eq "…and the subset relation still holds under the mutation" "0" \
  "$(lr_missing "$LR_LIVE_M" "$LR_OPEN_M")"
# The backdated plan is STILL not live under the mutation — the window is a second,
# independent rule, and forcing openness did not quietly widen it.
expect_absent "…while the backdated plan is still not live: the window is its own rule" \
  "lr-backdated.md" "$LR_LIVE_M"

# --- LR.4 THE ANTI-VACUITY ARM: prove the subset assertion can go RED ----------
#
# LR.2 asserts a count of zero. A count of zero is also what a broken comparison, an empty
# live set or a helper that never ran would produce, so the assertion is worth nothing until
# it has been SEEN to fail. Here `live_runs` is doctored to emit one path `open_runs` does
# not list — the exact defect the row is written against — and the same helper, over the same
# fixture, must report the counterexample.
LR_MUT_SUB="$SANDBOX/lr-mutant-live-extra.sh"
anchor -E "$RUN_LIB" '^live_runs\(\) \{' 1
awk '
  /^live_runs\(\) \{/ && !d { print; print "  printf '"'"'%s\\n'"'"' \"/nonexistent/ghost-run.md\""; d = 1; next }
  { print }
' "$RUN_LIB" > "$LR_MUT_SUB"

LR_LIB_SRC="$LR_MUT_SUB"
lr_ask "$LR_R" live_runs >/dev/null; LR_LIVE_G="$LR_OUT"
LR_LIB_SRC="$RUN_LIB"
expect_contains "the doctored live_runs really did emit the ghost" \
  "/nonexistent/ghost-run.md" "$LR_LIVE_G"
expect_eq "…and LR.2's own check reports it as NOT a member of the open set (the arm goes red)" \
  "1" "$(lr_missing "$LR_LIVE_G" "$LR_OPEN")"
# NOT DISCRIMINATED BY EMPTINESS: the doctored reader still returned the real live run too,
# so what the check caught is the EXTRA member, not a vanished set.
expect_contains "…while still returning the real live run, so the difference is the MEMBER" \
  "lr-fresh.md" "$LR_LIVE_G"

lr_ask "$LR_R" live_runs >/dev/null
expect_eq "restored: the shipped library answers as it did before the mutations" \
  "$LR_LIVE" "$LR_OUT"

# --- LR.5 EVERY GATE KEEPS THE STRICT OPEN RULE: NO GATE CONSULTS live_runs (AC-4) -------
#
# THE HALF OF AC-4 THE READBACK FLAGGED AS UNPROVEN. LR.1-LR.4 prove the SUBSET relation
# between the two readers; none of them says, in words, that a gate never reads the live
# reader at all. `bind` succeeding on a quiet-but-open plan (session-poker's own suite) is
# only "every gate keeps the strict open rule" if the gates really do stay off `live_runs` —
# so this row greps the two callers this wave gave `live_runs` and the eight gates a
# dispatch/stop/evidence/landing decision runs through, and pins the split directly.
LR_LIVE_CALLERS="engage.sh session-start.sh"
LR_GATES="canonical-sdlc-evidence-gate.sh canonical-sdlc-governing-skill.sh dispatch-preflight.sh stop-guard.sh patrol-duties-gate.sh patrol-revive.sh context-spend.sh landing-gate.sh"

for f in $LR_LIVE_CALLERS; do
  expect_eq "…$f (a live_runs caller) really does reference it (non-vacuity)" "1" \
    "$( [ "$(/usr/bin/grep -c 'live_runs' "$BIONIC_HOOKS_DIR/$f")" -ge 1 ] && echo 1 || echo 0 )"
done

for f in $LR_GATES; do
  expect_eq "…$f carries zero references to live_runs" "0" \
    "$(/usr/bin/grep -c 'live_runs' "$BIONIC_HOOKS_DIR/$f")"
done

# THE ANTI-VACUITY ARM. A doctored copy of one gate (stop-guard.sh) with a live_runs call
# inserted must fail the pin above — proving the grep is a real check on this gate's
# content, not a path that always reads zero regardless of what the file says.
LR_GATE_MUT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lr-gate-live-runs-mut.XXXXXX")"
LR_GATE_MUT="$LR_GATE_MUT_ROOT/stop-guard.sh"
{ printf '# doctored: %s\n' 'RUNS=$(live_runs "$REPO_REAL" 2>/dev/null) || RUNS=""'
  cat "$BIONIC_HOOKS_DIR/stop-guard.sh"
} > "$LR_GATE_MUT"
expect_eq "gate-mut meta: the doctored live_runs call landed (the file is not the original)" "no" \
  "$(cmp -s "$BIONIC_HOOKS_DIR/stop-guard.sh" "$LR_GATE_MUT" && echo yes || echo no)"
expect_eq "…and the doctored gate now fails the very pin above (the arm goes red)" "1" \
  "$(/usr/bin/grep -c 'live_runs' "$LR_GATE_MUT")"
rm -rf "$LR_GATE_MUT_ROOT"

# ============================================================
section "LA — THE LIVE-AGENT SET: one parser, three readers"
# ============================================================
#
# THE OWNERSHIP-TABLE ROW (spec §Design §3): "live agent set · owning module `live_agents`
# (agents.sh) · rendering surfaces: dispatch-preflight budget, stop-guard, stop-check,
# standdown, poker tick · agreement test: cross-gate new row: one parser; mutate it, every
# reader moves". AC-10 words the stop half of it directly.
#
# WHY THIS ROW EXISTS. Liveness used to be answered three ways — a `landing-swept` marker for
# the budget, a directory walk for the observation, a roster read for the gate — and the
# whole wave is the claim that there is now ONE answer, the harness's own recorded
# `ListAgents`, parsed in ONE place. That claim is not visible in any single suite:
# `tests/live-agents.test.sh` owns what the parser returns, and each hook's own suite owns
# what that hook does with it. What is only visible HERE is that the three hooks are reading
# the SAME parser — which is proved by breaking it once and watching all three answers move.
#
# THE THREE READERS ARE ASKED THROUGH THEIR OWN SURFACES, never by calling the library:
#   · dispatch-preflight — its budget refusal, which counts the roster's open rows against
#     the live set (`open=` in the BLOCKED line)
#   · stop-guard          — its resolution of a typed target on the Stop path
#   · stop-check          — the operator's listing, whose `Resolved:` line is the answer
#
# TWO NAMES, ONE ROSTER, FOR A REASON. The budget walks `status=intended` rows and
# resolution needs an `identified` row carrying an agent id, and the row-dedupe keeps the
# LAST row for a name — so one name cannot be both. `la-budget` is the open seat the ceiling
# counts; `la-target` is the identified agent the other two resolve. Both are named in the
# one recorded answer, which is the point: one parser, two questions.

LA_REPO=$(new_repo "la-one-parser")
LA_PLAN="$LA_REPO/.bionic/docs/plans/epic-99/la-run.md"
s4_plan "$LA_PLAN" 4 1
s4_bind "$LA_REPO" "$SID_A" "$LA_PLAN"
s4_attest "$LA_REPO" "$SID_A"

LA_SLUG=$(printf '%s' "$LA_REPO" | sed 's/[^a-zA-Z0-9]/-/g')
LA_PROJ="$CLAUDE_CONFIG_DIR/projects/$LA_SLUG"
mkdir -p "$LA_PROJ/$SID_A/subagents"
LA_TR="$LA_PROJ/$SID_A.jsonl"
LA_TID="alat-9999999999999999"

# THE ONE RECORDED ANSWER both questions are asked against — the harness's `ListAgents`
# result, in the shape `tests/live-agents.test.sh` establishes and the S6 `cg_live` helper
# above builds.
cg_live "$LA_TR" "la-budget" "la-target"

# the open seat (budget) and the identified agent (resolution)
cg_roster_row "$LA_REPO" "$SID_A" "la-budget" "alab-8888888888888888" "" "intended"
printf '{"name":"la-target","agentType":"implementor","description":"fixture","model":"opus"}' \
  > "$LA_PROJ/$SID_A/subagents/agent-$LA_TID.meta.json"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}\n' \
  > "$LA_PROJ/$SID_A/subagents/agent-$LA_TID.jsonl"
roster_identify "$LA_REPO" "$SID_A" "la-target" "$LA_TID"

# ---- the three questions, each asked of the REAL hook, out of a NAMED TREE ----
#
# The tree is a parameter because that is how the mutation is taken: every driver loads its
# hook from `$LA_TREE/hooks`, whose `../scripts/lib` is the library those hooks resolve
# first, so pointing `LA_TREE` at a doctored copy swaps the PARSER under all three at once
# without the shipped files being touched.
la_budget() {  # -> the dispatch wall's whole channel
  mk_agent_payload "$SID_A" "$LA_REPO" \
    | jq -c --arg t "$LA_TR" '.transcript_path = $t' \
    | env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$LA_TREE/hooks/dispatch-preflight.sh" 2>&1
  return 0
}
la_guard() {  # <typed> -> the stop guard's whole channel
  mk_stop_payload "$SID_A" "$LA_TR" "$LA_REPO" "$1" \
    | env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$LA_TREE/hooks/stop-guard.sh" 2>&1
  return 0
}
la_check() {  # <typed> -> the observation's whole channel
  ( cd "$LA_REPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" \
      bash "$LA_TREE/hooks/stop-check.sh" "$1" 2>&1 )
  return 0
}

LA_TREE="$BIONIC_HOOKS_DIR/.."
[ -d "$LA_TREE/scripts/lib" ] || LA_TREE="$BIONIC_HOOKS_DIR/../payload"
expect_eq "the shipped tree this section drives really holds the parser (not vacuous)" "yes" \
  "$([ -r "$LA_TREE/scripts/lib/agents.sh" ] && echo yes || echo no)"

LA_B0=$(la_budget)
LA_G0=$(la_guard la-target)
LA_C0=$(la_check la-target)

# --- LA.1 all three read the live set, and each SAYS what it read --------------
expect_contains "the dispatch wall counts the live open seat against the ceiling" \
  "open=1" "$LA_B0"
expect_contains "…and refuses on it, which is the answer the count produces" \
  "BLOCKED" "$LA_B0"
expect_absent "…rather than refusing because it could not read the answer at all" \
  "call ListAgents" "$LA_B0"
expect_contains "the observation resolves a live target to its agent id" "$LA_TID" "$LA_C0"
expect_absent "…and does not report it as absent from the live set" "not live" "$LA_C0"
# THE GUARD SPEAKS ITS RESOLUTION AS A VERDICT, not as an id: a target it finds in the live
# set is one it has standing to guard, so it BLOCKS the stop and names the observation to
# take; a target it does not find is not this gate's business and PASSES THROUGH. Those two
# words ARE the resolution, and they are what moves when the parser does.
expect_contains "the stop guard has standing over the same target: it blocks the stop" \
  "BLOCKED" "$LA_G0"
expect_contains "…naming that very target in the observation it asks for" \
  "stop-check.sh la-target" "$LA_G0"
expect_absent "…rather than passing it through as no agent of this session" \
  "PASSTHROUGH" "$LA_G0"
# THE LIVE READING IS A SENTENCE IN THE REFUSAL, and it is the half that moves. Standing is
# broader than liveness — a roster row or an agent-address shape also earns it — so BLOCKED
# alone would still be printed by a guard that had stopped consulting the live set entirely.
# What only a live target gets is a refusal that does NOT say it is absent from the answer.
expect_absent "…and it does not call the target absent from the recorded answer" \
  "is not live" "$LA_G0"

# --- LA.2 a name the recorded answer does NOT carry is refused by both readers --
#
# The negative direction, on the SAME transcript: what separates `la-target` from `la-ghost`
# is one line of the harness's answer and nothing else, so a reader that resolved both would
# be resolving from something other than the live set.
LA_CG=$(la_check la-ghost)
LA_GG=$(la_guard la-ghost)
expect_contains "a name the live set does not carry is NOT live to the observation" \
  "not live" "$LA_CG"
expect_absent "…and carries no agent id with it" "$LA_TID" "$LA_CG"
expect_contains "…and the stop guard passes it through, having no standing over it" \
  "PASSTHROUGH" "$LA_GG"
expect_contains "…saying so in the live set's own words" \
  "names no live agent of this session" "$LA_GG"

# --- LA.3 THE DISCRIMINATOR: mutate the parser's awk, all three answers move ----
#
# The mutation removes ONE line of `_la_parse_teammates` — the `sub()` that drops the
# harness's `[ref]` suffix off the name. It is the smallest plausible regression in that awk
# and it leaves the parser working: the set still has two entries, they are just spelled
# `la-target [8895ce]`. So no reader can find its name, and none of them can blame an empty
# answer for it — which is exactly the failure a second, private parser would produce and a
# shared one cannot.
LA_MUT="$SANDBOX/la-mutant"
mkdir -p "$LA_MUT/hooks" "$LA_MUT/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$LA_MUT/scripts/lib/" 2>/dev/null
cp "$BIONIC_HOOKS_DIR"/*.sh "$LA_MUT/hooks/" 2>/dev/null
anchor "$LIB_DIR_SRC/agents.sh" 'drop the harness ref suffix' 1
grep -v 'drop the harness ref suffix' "$LIB_DIR_SRC/agents.sh" > "$LA_MUT/scripts/lib/agents.sh"
# …AND THE MUTANT IS STILL A PARSER. If it returned nothing the three readers would move for
# a reason that proves nothing about sharing — every one of them refuses an unreadable answer
# already. The set is asked for directly, once, to pin that it is non-empty and merely WRONG.
LA_MUT_SET=$( . "$LA_MUT/scripts/lib/agents.sh" >/dev/null 2>&1; live_agents "$LA_TR" 2>/dev/null )
expect_contains "…and the doctored parser still returns a live set" "la-target [" "$LA_MUT_SET"
expect_absent "…which simply spells the name wrong" "la-target|" "$LA_MUT_SET"

LA_TREE="$LA_MUT"
LA_B1=$(la_budget)
LA_G1=$(la_guard la-target)
LA_C1=$(la_check la-target)
LA_TREE="$BIONIC_HOOKS_DIR/.."
[ -d "$LA_TREE/scripts/lib" ] || LA_TREE="$BIONIC_HOOKS_DIR/../payload"

expect_absent "mutated parser: the dispatch wall no longer counts the seat as open" \
  "open=1" "$LA_B1"
expect_absent "mutated parser: the observation no longer resolves the target" "$LA_TID" "$LA_C1"
expect_contains "…it reports it as absent from the live set instead" "not live" "$LA_C1"
expect_contains "mutated parser: the stop guard now calls the same target not live" \
  "Target 'la-target' is not live" "$LA_G1"
expect_contains "…in the parser's own terms: the answer names no such teammate" \
  "names no teammate 'la-target'" "$LA_G1"

# --- LA.4 restored: the shipped tree answers as it did before the mutation ------
# The observation prints an AGE, which moves by a second between two runs of the same
# fixture — so the compare is on the `Resolved:` line, which is the answer this section is
# about, rather than on a whole channel that carries a clock reading.
la_resolved() { printf '%s\n' "$1" | sed -n 's/^Resolved: *//p' | head -1; }
expect_eq "restored: the wall's answer is the one it gave before" "$LA_B0" "$(la_budget)"
expect_eq "…and the observation resolves what it resolved before" \
  "$(la_resolved "$LA_C0")" "$(la_resolved "$(la_check la-target)")"
expect_eq "…which is the agent id, not an empty line (the restore is not vacuous)" \
  "$LA_TID" "$(la_resolved "$LA_C0")"

# --- LA.5 ONE PARSE, TWO QUESTIONS: the status column (spec R2, AC-27; S16) ----
#
# S16 gives the budget a NARROWER question than the guard. The budget stops counting a row
# whose agent reads `idle` — a teammate that finished its turn and was never stopped is not
# a writer. The guard keeps resolving on PRESENCE, because an idle agent is exactly the one
# a stop is for. Both answers come off the SAME parse (`live_agents_status` and
# `live_agents_has` are two views of one `live_agents` call), and that is what this block
# proves: two one-line doctorings of that single parser, each moving exactly the consumer
# whose question it changes, on one fixture neither consumer can otherwise tell apart.
#
# LA.3 already moves all three readers by breaking the NAME. LA.5 is the other half — the
# STATUS is read from that same parse, by one of them.

rm -f "${LA_TR%.jsonl}.names"
cg_live "$LA_TR" "la-budget:idle" "la-target:idle"
expect_contains "LA.5 meta: the one answer now names both teammates idle" \
  "la-budget [8895ce]  ·  bionic:implementor  ·  idle" "$(cat "$LA_TR")"

LA_B5=$(la_budget)
LA_G5=$(la_guard la-target)
expect_absent "idle open seat: the dispatch wall stops counting it" "open=1" "$LA_B5"
expect_absent "…and prints no writers refusal at all" "writers:" "$LA_B5"
expect_contains "…while the SAME answer still gives the stop guard standing over its target" \
  "BLOCKED" "$LA_G5"
expect_absent "…which it does not call absent from the recorded answer" "is not live" "$LA_G5"

# MUTATION A — the parser writes `running` into every row. The status the BUDGET reads is
# gone; the presence the GUARD reads is untouched. Exactly one consumer moves.
LA_MUT_S="$SANDBOX/la-mutant-status"
mkdir -p "$LA_MUT_S/hooks" "$LA_MUT_S/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$LA_MUT_S/scripts/lib/" 2>/dev/null
cp "$BIONIC_HOOKS_DIR"/*.sh "$LA_MUT_S/hooks/" 2>/dev/null
sed 's/print name "|" type "|" status/print name "|" type "|" "running"/' \
  "$LIB_DIR_SRC/agents.sh" > "$LA_MUT_S/scripts/lib/agents.sh"
expect_eq "mutation A applies (the parser's print line has not moved)" "no" \
  "$(cmp -s "$LIB_DIR_SRC/agents.sh" "$LA_MUT_S/scripts/lib/agents.sh" && echo yes || echo no)"
LA_MUTS_SET=$( . "$LA_MUT_S/scripts/lib/agents.sh" >/dev/null 2>&1; live_agents "$LA_TR" 2>/dev/null )
expect_contains "…and the mutant is still a parser: the set is intact, only the status lies" \
  "la-budget|bionic:implementor|running" "$LA_MUTS_SET"

LA_TREE="$LA_MUT_S"
LA_B5A=$(la_budget)
LA_G5A=$(la_guard la-target)
LA_TREE="$BIONIC_HOOKS_DIR/.."
[ -d "$LA_TREE/scripts/lib" ] || LA_TREE="$BIONIC_HOOKS_DIR/../payload"

expect_contains "mutation A: the wall counts the finished agent open again — the budget moved" \
  "open=1" "$LA_B5A"
expect_contains "…and refuses on it" "BLOCKED" "$LA_B5A"
# The guard's channel quotes the tree it was loaded from in its `Fix:` lines, so the
# compare normalises that one path away and is byte-exact on everything else — including
# the verdict, which is the thing under test.
la_norm() { printf '%s\n' "$1" | sed 's#/[^ ]*/hooks/#TREE/#g'; }
expect_eq "…while the guard's whole channel is otherwise unchanged — presence never moved" \
  "$(la_norm "$LA_G5")" "$(la_norm "$LA_G5A")"
expect_contains "…and the normaliser really did rewrite that path (not comparing raw text)" \
  "TREE/stop-check.sh" "$(la_norm "$LA_G5")"
expect_contains "…and that channel is a real refusal, not an empty string (not vacuous)" \
  "BLOCKED" "$LA_G5A"

# MUTATION B — the parser drops every row that is not `running`. This is the WRONG place to
# put S16's rule: filtering in the reader rather than in the budget. Now the GUARD moves and
# the budget does not, which is why the rule lives where it does.
LA_MUT_F="$SANDBOX/la-mutant-filter"
mkdir -p "$LA_MUT_F/hooks" "$LA_MUT_F/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$LA_MUT_F/scripts/lib/" 2>/dev/null
cp "$BIONIC_HOOKS_DIR"/*.sh "$LA_MUT_F/hooks/" 2>/dev/null
sed 's/if (name != "") print name "|" type "|" status/if (name != "" \&\& status == "running") print name "|" type "|" status/' \
  "$LIB_DIR_SRC/agents.sh" > "$LA_MUT_F/scripts/lib/agents.sh"
expect_eq "mutation B applies" "no" \
  "$(cmp -s "$LIB_DIR_SRC/agents.sh" "$LA_MUT_F/scripts/lib/agents.sh" && echo yes || echo no)"
LA_MUTF_SET=$( . "$LA_MUT_F/scripts/lib/agents.sh" >/dev/null 2>&1; live_agents "$LA_TR" 2>/dev/null )
expect_empty "…and it really does drop the idle rows from the set" "$LA_MUTF_SET"
# THE PAIRED POSITIVE FOR THAT ABSENCE (wave-01 S11, AC-14 / A-10a). This `expect_empty`
# was the call the framework did not define: for as long as the suite carried no
# `expect_empty`, it was a `command not found` on a discarded stderr, counted nothing, and
# an 818/818 green covered it. Now that it asserts, it is a NEGATIVE assertion over a
# mutant extractor — and an extractor that returns the empty string for EVERY transcript
# would satisfy it just as well as one that filters. The same mutant, over the same
# builder, against an answer whose teammates are RUNNING, has to come back non-empty.
LA_TR_RUN="$LA_PROJ/$SID_B.jsonl"
rm -f "${LA_TR_RUN%.jsonl}.names"
cg_live "$LA_TR_RUN" "la-budget:running" "la-target:running"
LA_MUTF_RUN=$( . "$LA_MUT_F/scripts/lib/agents.sh" >/dev/null 2>&1; live_agents "$LA_TR_RUN" 2>/dev/null )
expect_nonempty "…while the SAME mutant extractor over a RUNNING answer returns a set" \
  "$LA_MUTF_RUN"
expect_contains "…carrying the row it kept, so the emptiness above is a filter and not a blank" \
  "la-budget|bionic:implementor|running" "$LA_MUTF_RUN"

LA_TREE="$LA_MUT_F"
LA_G5B=$(la_guard la-target)
LA_B5B=$(la_budget)
LA_TREE="$BIONIC_HOOKS_DIR/.."
[ -d "$LA_TREE/scripts/lib" ] || LA_TREE="$BIONIC_HOOKS_DIR/../payload"

expect_contains "mutation B: the guard loses the finished agent it exists to stop" \
  "names no teammate 'la-target'" "$LA_G5B"
# Standing is broader than liveness (LA.1) — the identified roster row alone earns a
# BLOCK — so what moves here is the REASON, and the shipped parser never gives it.
expect_absent "…a sentence the shipped parser never said of the same target" \
  "names no teammate" "$LA_G5"
expect_absent "mutation B: the wall's count is unchanged — it read idle as closed already" \
  "open=1" "$LA_B5B"

# RESTORED, on the idle fixture: neither mutation left anything behind.
expect_eq "restored: the wall answers the idle fixture as it did before both mutations" \
  "$LA_B5" "$(la_budget)"
expect_eq "…and so does the guard" "$LA_G5" "$(la_guard la-target)"

# --- LA.6 ONE PREDICATE, TWO CONSUMERS: the budget and the tick count the same (S19) ---
#
# THE OWNERSHIP-TABLE ROW names `session-poker.sh tick` a rendering surface of the live
# agent set. Until S19 it was not one: the tick counted roster rows by sweeper verdict and
# never read the harness's answer, so the Patrol could print a FILL the dispatch wall was
# about to refuse — a finished-but-unstopped teammate is not open to the budget and WAS
# open to the tick. LA.5 proves the budget and the guard ask DIFFERENT questions off one
# parse. LA.6 is the other shape of the same claim: two consumers asking the SAME question
# must get the same answer, and they do because there is one predicate — `live_row_open`.
#
# THE OBSERVABLE IS A NUMBER EACH SIDE PRINTS ITSELF: `open=` in the wall's refusal and
# `open=` in the tick's decision line. Neither is computed by this suite.
#
# ONE ROSTER, ONE ANSWER, TWO ROWS: an idle teammate beside a running one. Every consumer
# below reads the same two files; only the tree they are loaded from ever changes.

# A SESSION ID OF ITS OWN, and that is not fixture hygiene — it is the contract. The tick
# finds its transcript by walking CLAUDE_CONFIG_DIR/projects/*/<session-id>.jsonl and takes
# the first match, so two fixtures sharing one id would hand it a NEIGHBOUR'S answer. The
# budget is handed its transcript in the hook payload and would not notice. This suite
# already plants `$SID_A.jsonl` under two other project directories, so on the shared id the
# two consumers would be reading two different files — and an agreement row measured that
# way proves nothing about either.
LA6_SID="7d31be55-2c48-4f90-b1a7-63e0c4a91d55"
LA6_REPO=$(new_repo "la-one-predicate")
arm_patrol "$LA6_REPO" "$LA6_SID"
LA6_PLAN="$LA6_REPO/.bionic/docs/plans/epic-99/la6-run.md"
s4_plan "$LA6_PLAN" 4 1
s4_bind "$LA6_REPO" "$LA6_SID" "$LA6_PLAN"
s4_attest "$LA6_REPO" "$LA6_SID"

LA6_SLUG=$(printf '%s' "$LA6_REPO" | sed 's/[^a-zA-Z0-9]/-/g')
LA6_PROJ="$CLAUDE_CONFIG_DIR/projects/$LA6_SLUG"
mkdir -p "$LA6_PROJ"
LA6_TR="$LA6_PROJ/$LA6_SID.jsonl"
cg_live "$LA6_TR" "la6-idle:idle" "la6-live:running"
# NOT SHARED WITH ANY OTHER FIXTURE: the id resolves to exactly this file.
expect_eq "LA.6 meta: this session's id names exactly one transcript on the whole machine" "1" \
  "$(ls "$CLAUDE_CONFIG_DIR"/projects/*/"$LA6_SID.jsonl" 2>/dev/null | wc -l | tr -d ' ')"

# THE ROWS CARRY A DELIVERABLE THAT DOES NOT EXIST, so the sweeper calls both contracts
# UNMET and the tick has two candidate-open rows to narrow. A row declaring nothing stats
# MET for want of anything to hold it to, and would make the tick's count zero for a reason
# that has nothing to do with the live set.
la6_row() {  # <name>
  roster_row_fixture status=intended session="$LA6_SID" name="$1" agent_id= \
    launched_at=2026-08-05T00:00:00Z deliverable="$LA6_REPO/never-written-$1.md" \
    duration="4 hours" tool_use_id="toolu_01LA6$1" \
    >> "$LA6_REPO/.bionic/tmp/roster-$LA6_SID.state"
}
roster_header \
  > "$LA6_REPO/.bionic/tmp/roster-$LA6_SID.state"
la6_row "la6-idle"
la6_row "la6-live"

la6_budget() {  # -> the dispatch wall's whole channel, out of $LA_TREE
  mk_agent_payload "$LA6_SID" "$LA6_REPO" \
    | jq -c --arg t "$LA6_TR" '.transcript_path = $t' \
    | env CLAUDE_CODE_SESSION_ID="$LA6_SID" bash "$LA_TREE/hooks/dispatch-preflight.sh" 2>&1
  return 0
}
la6_tick() {  # -> the Patrol tick's whole channel, out of $LA_TREE
  ( cd "$LA6_REPO" && env CLAUDE_CODE_SESSION_ID="$LA6_SID" \
      BIONIC_PROBE_FREE_MB=8192 BIONIC_PROBE_LOAD_1M=1.0 \
      bash "$LA_TREE/hooks/session-poker.sh" tick 2>&1 )
  return 0
}
la6_open_budget() { printf '%s\n' "$1" | sed -n 's/.*writers: budget=[0-9]* open=\([0-9]*\) .*/\1/p' | head -1; }
la6_open_tick()   { printf '%s\n' "$1" | sed -n 's/.*decision=[A-Z]*|total=[0-9]*|open=\([0-9]*\).*/\1/p' | head -1; }

LA6_B=$(la6_budget); LA6_T=$(la6_tick)
LA6_BN=$(la6_open_budget "$LA6_B"); LA6_TN=$(la6_open_tick "$LA6_T")

# NON-VACUITY FIRST: both consumers really did print a number, and it is the one the
# fixture predicts — two roster rows, one of them finished, so exactly one is open.
expect_eq "LA.6 the dispatch wall counts one open row on this roster" "1" "$LA6_BN"
expect_eq "LA.6 the Patrol tick counts one open row on the SAME roster" "1" "$LA6_TN"
expect_eq "…so the two consumers agree" "$LA6_BN" "$LA6_TN"
# And the tick really did consult the live set rather than land on 1 by luck: its own
# roster carries TWO unmet rows, which is what a tick that read no answer would print.
expect_contains "…while the tick's own roster carries two rows (the narrowing is real)" \
  "total=2" "$LA6_T"

# THE MUTATION: ONE LINE of the shared predicate, and BOTH consumers move together. That
# is the whole point of one owner — a rule spelled twice would move one of them.
LA6_MUT="$SANDBOX/la-mutant-predicate"
mkdir -p "$LA6_MUT/hooks" "$LA6_MUT/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$LA6_MUT/scripts/lib/" 2>/dev/null
cp "$BIONIC_HOOKS_DIR"/*.sh "$LA6_MUT/hooks/" 2>/dev/null
anchor "$LIB_DIR_SRC/agents.sh" '_LA_ROW_CLOSED_STATUS="idle"' 1
sed 's/_LA_ROW_CLOSED_STATUS="idle"/_LA_ROW_CLOSED_STATUS="no-such-status"/' \
  "$LIB_DIR_SRC/agents.sh" > "$LA6_MUT/scripts/lib/agents.sh"
# …and the mutant is still a predicate: it now calls the idle row OPEN rather than
# returning nothing at all.
LA6_MUT_RC=0
( . "$LA6_MUT/scripts/lib/agents.sh" >/dev/null 2>&1; live_row_open "$LA6_TR" "la6-idle" ) 2>/dev/null \
  || LA6_MUT_RC=$?
expect_eq "…and the doctored predicate now calls the idle row OPEN" "0" "$LA6_MUT_RC"

LA_TREE="$LA6_MUT"
LA6_BM=$(la6_budget); LA6_TM=$(la6_tick)
LA_TREE="$BIONIC_HOOKS_DIR/.."
[ -d "$LA_TREE/scripts/lib" ] || LA_TREE="$BIONIC_HOOKS_DIR/../payload"

expect_eq "mutated predicate: the dispatch wall now counts BOTH rows open" "2" \
  "$(la6_open_budget "$LA6_BM")"
expect_eq "…and the tick moves with it, off the same one line" "2" \
  "$(la6_open_tick "$LA6_TM")"
expect_eq "…so they still agree — one owner, moved once, moves both" \
  "$(la6_open_budget "$LA6_BM")" "$(la6_open_tick "$LA6_TM")"

# RESTORED: the shipped tree answers as it did before the mutation, on both surfaces.
expect_eq "restored: the wall counts one open row again" "1" "$(la6_open_budget "$(la6_budget)")"
expect_eq "…and so does the tick" "1" "$(la6_open_tick "$(la6_tick)")"

# ============================================================
section "PC — THE PLAN PATH's CANONICAL FORM: one canonicalizer, three sites"
# ============================================================
#
# THE OWNERSHIP-TABLE ROW (spec §Design §3): "plan path canonical form · owning module
# `_bind_resolve` (binding.sh) · rendering surfaces: bind_plan, poker adopt, poker bind ·
# agreement test: cross-gate new row: relative path + trailing slash, three sites agree".
# AC-23 is its wording.
#
# THE DEFECT THE ROW IS WRITTEN AGAINST. Before S8 each of the three sites spelled the
# canonical form its own way: `bind_plan` resolved through `_bind_resolve`, `adopt_plan_key`
# carried an inline normalizer of its own, and `bind`'s refusal arm carried a third. Two
# spellings of one plan then produced two bindings — and `adopt`, comparing a roster row's
# `plan=` against this session's, read its own run as somebody else's.
#
# THE TWO SPELLINGS ARE THE ONES AN OPERATOR ACTUALLY PRODUCES. `./plans/…` is what a shell
# leaves when the path is completed from the docs root, and `plans/…/` is what completion
# leaves on a directory-looking path the operator was still typing. Neither is exotic and
# both name one file.
#
# EACH SITE IS ASKED IN THE FORM IT ACCEPTS, which is not a weakening of the row — it is what
# the row is about. `bind_plan` is a library function contracted to take an ABSOLUTE path, so
# its odd spellings are absolute ones; the `bind` verb takes what the operator types, so its
# are docs-root-relative; `adopt` never takes a path at all — it READS one off a foreign
# roster row — so its odd spelling is planted in that row. Three interfaces, one answer.

PC_REPO=$(new_repo "pc-canonical")
PC_DOCS="$PC_REPO/.bionic/docs"
PC_PLAN="$PC_DOCS/plans/epic-99/pc-run.md"
write_plan "$PC_PLAN" "current: 4"
# THE CANONICAL SPELLING IS THE LIBRARY'S OWN ANSWER, not a string built here. A hand-written
# expectation would pass on a tree whose sandbox path is itself a symlink (macOS `/tmp` is),
# and would be pinning this suite's idea of canonical rather than `_bind_resolve`'s.
PC_CANON=$( . "$RUN_LIB" >/dev/null 2>&1; . "$LIB_DIR_SRC/binding.sh" >/dev/null 2>&1
            _bind_resolve "$PC_PLAN" )
expect_contains "the canonicalizer answers for the fixture plan at all (not vacuous)" \
  "pc-run.md" "$PC_CANON"

pc_marker() {  # <sid> -> the plan= value on that session's marker, or empty
  sed -n 's/^plan=//p' "$PC_REPO/.bionic/tmp/engaged-$1.state" 2>/dev/null | head -1
}
pc_bind_lib() {  # <sid> <plan spelling> -> drive the LIBRARY's writer directly
  rm -f "$PC_REPO/.bionic/tmp/engaged-$1.state"
  : > "$PC_REPO/.bionic/tmp/engaged-$1.state"
  ( . "$PC_LIB_RUN" >/dev/null 2>&1; . "$PC_LIB_BIND" >/dev/null 2>&1
    bind_plan "$PC_REPO" "$1" "$2" ) >/dev/null 2>&1
  pc_marker "$1"
}
pc_bind_verb() {  # <sid> <operand> -> drive the poker's `bind` verb
  rm -f "$PC_REPO/.bionic/tmp/engaged-$1.state"
  : > "$PC_REPO/.bionic/tmp/engaged-$1.state"
  ( cd "$PC_REPO" && env CLAUDE_CODE_SESSION_ID="$1" bash "$PC_SPO" bind "$2" ) >/dev/null 2>&1
  pc_marker "$1"
}

PC_LIB_RUN="$RUN_LIB"
PC_LIB_BIND="$LIB_DIR_SRC/binding.sh"
PC_SPO="$SPO"

# --- PC.1 the library's writer: three absolute spellings, one stored value -----
PC_DOT="$PC_DOCS/./plans/epic-99/pc-run.md"
PC_SLASH="$PC_PLAN/"
expect_eq "bind_plan stores the canonical spelling for the plain path" \
  "$PC_CANON" "$(pc_bind_lib "$SID_A" "$PC_PLAN")"
expect_eq "…the same value for the ./ spelling" \
  "$PC_CANON" "$(pc_bind_lib "$SID_A" "$PC_DOT")"
expect_eq "…and the same value for the trailing-slash spelling" \
  "$PC_CANON" "$(pc_bind_lib "$SID_A" "$PC_SLASH")"

# --- PC.2 the poker's `bind` verb: the two operands an operator types ----------
#
# DOCS-ROOT-RELATIVE, because that is the spelling hooks/session-start.sh prints in its
# open-run listing and therefore the one an operator copies (S8b).
expect_eq "poker bind stores the same canonical spelling for ./plans/…" \
  "$PC_CANON" "$(pc_bind_verb "$SID_B" "./plans/epic-99/pc-run.md")"
expect_eq "…and for plans/…/ with the slash completion left on it" \
  "$PC_CANON" "$(pc_bind_verb "$SID_B" "plans/epic-99/pc-run.md/")"

# --- PC.3 the poker's `adopt`: the key it compares a foreign row's plan= by -----
#
# `adopt` produces no `plan=` of its own from a spelling — it READS one off a predecessor's
# roster row and asks whether that row belongs to THIS session's run. The canonical form is
# what makes that question answerable, so the observable is the PARTITION: a foreign row
# whose `plan=` is one of the odd spellings must land under this session's own run, and one
# naming a genuinely different plan must not.
PC_PRED="9a9a9a9a-1111-4bbb-8ccc-0000000000c1"
PC_OTHER="$PC_DOCS/plans/epic-99/pc-other.md"
write_plan "$PC_OTHER" "current: 6"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$PC_REPO" | sed 's/[^a-zA-Z0-9]/-/g')/$PC_PRED/subagents"

pc_adopt() {  # <foreign plan= spelling> -> the adopt listing
  roster_header \
    > "$PC_REPO/.bionic/tmp/roster-$PC_PRED.state"
  roster_row_fixture status=identified session="$PC_PRED" name=pc-agent \
    agent_id=apc-1111111111111111 launched_at=2026-08-05T00:00:00Z \
    tool_use_id=toolu_01PCFIX plan="$1" \
    >> "$PC_REPO/.bionic/tmp/roster-$PC_PRED.state"
  s4_bind "$PC_REPO" "$SID_A" "$PC_PLAN"
  ( cd "$PC_REPO" && env CLAUDE_CODE_SESSION_ID="$SID_A" bash "$PC_SPO" adopt 2>&1 )
  return 0
}

PC_A_ABS=$(pc_adopt "$PC_CANON")
PC_A_DOT=$(pc_adopt "./.bionic/docs/plans/epic-99/pc-run.md")
PC_A_SLASH=$(pc_adopt ".bionic/docs/plans/epic-99/pc-run.md/")
PC_A_OTHER=$(pc_adopt "$PC_OTHER")

# NON-VACUITY FIRST: the listing must actually be about the planted row, or every `grep`
# below is asking a question of an empty answer.
expect_contains "adopt listed the planted predecessor row" "pc-agent" "$PC_A_ABS"
expect_absent "…and did NOT file it under another run when the spelling is canonical" \
  "another run" "$PC_A_ABS"
expect_absent "…nor when the row spells it ./…" "another run" "$PC_A_DOT"
expect_absent "…nor when the row spells it with a trailing slash" "another run" "$PC_A_SLASH"
# THE OTHER DIRECTION, WHICH IS WHAT MAKES THE THREE ABOVE MEAN SOMETHING: a row naming a
# genuinely different plan of the same root IS filed under another run. Without this the
# three absences would also be produced by a partition that had stopped comparing at all.
expect_contains "…while a row naming a DIFFERENT plan is filed under another run" \
  "another run" "$PC_A_OTHER"

# --- PC.4 THE DISCRIMINATOR: doctor _bind_resolve, all three sites move --------
#
# The mutation removes the directory resolution — `pwd -P` — and leaves the function
# returning what it was handed. That is precisely the pre-S8 inline normalizer's behaviour on
# these spellings, so it is a regression the codebase has actually shipped rather than
# invented damage. The shipped library is never touched: a mutant plugin tree is built
# alongside it and the three sites are driven out of THAT.
PC_MUT="$SANDBOX/pc-mutant"
mkdir -p "$PC_MUT/hooks" "$PC_MUT/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$PC_MUT/scripts/lib/" 2>/dev/null
cp "$BIONIC_HOOKS_DIR"/*.sh "$PC_MUT/hooks/" 2>/dev/null
anchor -E "$LIB_DIR_SRC/binding.sh" '^_bind_resolve\(\) \{' 1
awk '
  /^_bind_resolve\(\) \{/ && !d { print; print "  printf '"'"'%s\\n'"'"' \"$1\"; return 0"; d = 1; next }
  { print }
' "$LIB_DIR_SRC/binding.sh" > "$PC_MUT/scripts/lib/binding.sh"

PC_LIB_BIND="$PC_MUT/scripts/lib/binding.sh"
PC_SPO="$PC_MUT/hooks/session-poker.sh"
PC_M_DOT=$(pc_bind_lib "$SID_A" "$PC_DOT")
PC_M_PLAIN=$(pc_bind_lib "$SID_A" "$PC_PLAN")
PC_M_VERB=$(pc_bind_verb "$SID_B" "./plans/epic-99/pc-run.md")
PC_M_ADOPT=$(pc_adopt "./.bionic/docs/plans/epic-99/pc-run.md")
PC_LIB_BIND="$LIB_DIR_SRC/binding.sh"
PC_SPO="$SPO"

expect_eq "doctored canonicalizer: bind_plan no longer answers canonically for ./…" \
  "no" "$([ "$PC_M_DOT" = "$PC_CANON" ] && echo yes || echo no)"
expect_eq "doctored canonicalizer: the bind VERB moves with it" \
  "no" "$([ "$PC_M_VERB" = "$PC_CANON" ] && echo yes || echo no)"
expect_contains "doctored canonicalizer: adopt files this session's own row under another run" \
  "another run" "$PC_M_ADOPT"
# NOT DISCRIMINATED BY BREAKING EVERYTHING. The mutant still binds the ALREADY-canonical
# spelling correctly, so what the three rows above caught is the missing canonicalization,
# not a writer that stopped writing.
expect_eq "…while the mutant still binds the already-canonical spelling (the arm is precise)" \
  "$PC_CANON" "$PC_M_PLAIN"

# --- PC.5 restored ------------------------------------------------------------
expect_eq "restored: bind_plan answers canonically again for ./…" \
  "$PC_CANON" "$(pc_bind_lib "$SID_A" "$PC_DOT")"

# ============================================================
section "RG — THE PRESSURE RUNG: two consumers, one ring, one rung"
# ============================================================
#
# THE OWNERSHIP-TABLE ROW (spec §Design §3): "machine pressure level · owning module
# `pressure_level` (resources.sh) over the ring · rendering surfaces: poker fill,
# tests/run.sh, tick report line · agreement test: new row: two consumers over one ring
# compute one rung; band mutation moves both". AC-14 states the function's own contract and
# AC-15 states the consumers' obligation to SAMPLE before they read.
#
# THE TWO CONSUMERS ARE UNRELATED PROGRAMS. `tests/run.sh` sets a suite's job width;
# `session-poker.sh tick` reports the rung and fills writers by it. They share nothing but
# the library and the ring — which is the design (D4: pressure describes the machine, so the
# ring is machine-scoped) and therefore the thing to hold. Every ring in this section lives
# under the sandbox via `BIONIC_PRESSURE_RING`; the machine's own ring is never read or
# written.
#
# THE CLOCK AND THE SENSORS ARE PINNED, or this section would be a weather report.
# `BIONIC_NOW_EPOCH` fixes the smoothing window's `now` and `BIONIC_PROBE_FREE_PCT` /
# `_SWAP_PCT` / `_LOAD_1M` fix the reading a sample takes. The load pin is not optional
# housekeeping: `pressure_band`'s load term compares the real one-minute average against
# 1.5 × cores, and this suite runs inside a parallel test run, so an unpinned drive would
# read `warning` on a busy runner and `clear` on an idle one.

RG_CEIL=8
RG_NOW=1757030000
RG_RING="$SANDBOX/rg/pressure.ring"
mkdir -p "$SANDBOX/rg"
# CLEAR and CRITICAL as the sensors see them: 80 % free is above every band threshold;
# 8 % free is below BAND_FREE_CRITICAL_PCT (12) and above BAND_FREE_EMERGENCY_PCT (5).
RG_CLEAR_ENV="BIONIC_PROBE_FREE_PCT=80 BIONIC_PROBE_SWAP_PCT=0 BIONIC_PROBE_LOAD_1M=0.1"
RG_CRIT_ENV="BIONIC_PROBE_FREE_PCT=8 BIONIC_PROBE_SWAP_PCT=0 BIONIC_PROBE_LOAD_1M=0.1"

# ONE CLEAR READING, WRITTEN BY THE REAL WRITER — not a hand-built ring file. The line's
# shape is `pressure_sample`'s to own, and a fixture that wrote it by hand would keep passing
# after the writer changed it.
rg_seed() {  # the ring, reset to exactly one sample under the given probe env — S25
             # (critic K-4 option 2): `tests/run.sh --dry-run` stopped sampling (a dry
             # run writes nothing), so a case that needs the RUNNER to read a specific
             # band must put that reading in the ring directly rather than counting on
             # the runner's own (now nonexistent) live sample under --dry-run.
  local env="$1"
  rm -f "$RG_RING"
  ( eval "export $env"
    export BIONIC_PRESSURE_RING="$RG_RING" BIONIC_NOW_EPOCH="$RG_NOW"
    . "$RG_LIB_RES" >/dev/null 2>&1
    pressure_sample "$RG_CEIL" ) >/dev/null 2>&1
}
rg_seed_clear() { rg_seed "$RG_CLEAR_ENV"; }  # the ring, reset to exactly one clear sample

# ---- the fixture world the tick needs ----------------------------------------
#
# The tick reaches its scheduler — and therefore its rung line — only with a roster carrying
# at least one row; above that it exits on `armed, nothing dispatched yet` and reports no
# rung at all. The plan carries the ceiling both consumers read against, so the two answers
# are comparable numbers rather than two scales.
RG_REPO=$(new_repo "rg-one-ring")
RG_PLAN="$RG_REPO/.bionic/docs/plans/epic-99/rg-run.md"
mkdir -p "$(dirname "$RG_PLAN")"
{
  printf -- '---\n'
  printf 'governing-skill: canonical-sdlc\ncanonical_sdlc_version: 14\n'
  printf 'intent: build\nrigor: audited\nscale: wave\n'
  printf 'parallel-budget: writers=%s test_jobs=%s model=opus\n' "$RG_CEIL" "$RG_CEIL"
  printf -- '---\n\n# Fixture plan\n\n## SDLC State\n\nintegration-branch: main\n'
  printf 'current: 4\n\n- Step 3: prior evidence\n'
} > "$RG_PLAN"
s4_bind "$RG_REPO" "$SID_A" "$RG_PLAN"
cg_roster_row "$RG_REPO" "$SID_A" "rg-writer" "arg-1111111111111111" "" "identified"

# ---- the two consumers, each asked through its own surface -------------------
rg_runner() {  # -> the width tests/run.sh would run at, under the pinned environment
  ( eval "export $1"
    export BIONIC_PRESSURE_RING="$RG_RING" BIONIC_NOW_EPOCH="$RG_NOW" \
           BIONIC_TEST_JOBS_CEILING="$RG_CEIL"
    bash "$RG_TREE_RUNNER/tests/run.sh" --dry-run 2>/dev/null ) \
    | sed -n 's/^JOBS=//p' | head -1
}
rg_tick() {  # -> the rung field of the tick's report line, under the same environment
  ( cd "$RG_REPO"
    eval "export $1"
    export BIONIC_PRESSURE_RING="$RG_RING" BIONIC_NOW_EPOCH="$RG_NOW" \
           CLAUDE_CODE_SESSION_ID="$SID_A" CLAUDE_CONFIG_DIR="$RG_REPO/no-such-config"
    bash "$RG_TREE_POKER/hooks/session-poker.sh" tick 2>&1 ) \
    | sed -n 's/.*rung=\([0-9-]*\)\/.*/\1/p' | head -1
}

RG_LIB_RES="$LIB_DIR_SRC/resources.sh"
RG_TREE_RUNNER="$REPO_ROOT"
RG_TREE_POKER="$BIONIC_HOOKS_DIR/.."
[ -d "$RG_TREE_POKER/scripts/lib" ] || RG_TREE_POKER="$BIONIC_HOOKS_DIR/../payload"

expect_eq "the runner this section drives is on disk (not vacuous)" "yes" \
  "$([ -r "$RG_TREE_RUNNER/tests/run.sh" ] && echo yes || echo no)"

# --- RG.1 one ring, one rung: a CLEAR machine gives both consumers the ceiling --
rg_seed_clear; RG_RUN_CLEAR=$(rg_runner "$RG_CLEAR_ENV")
rg_seed_clear; RG_TICK_CLEAR=$(rg_tick "$RG_CLEAR_ENV")
expect_eq "a clear machine gives the runner the whole ceiling" "$RG_CEIL" "$RG_RUN_CLEAR"
expect_eq "…and gives the tick the same number" "$RG_CEIL" "$RG_TICK_CLEAR"

# --- RG.2 …and a CRITICAL machine quarters it for both, identically ------------
# The runner's half is seeded directly with the critical reading (S25: --dry-run only
# reads the ring now, it does not sample), while the tick still takes its own live
# sample under the same env — two different mechanisms landing on the same rung.
rg_seed "$RG_CRIT_ENV"; RG_RUN_CRIT=$(rg_runner "$RG_CRIT_ENV")
rg_seed_clear; RG_TICK_CRIT=$(rg_tick "$RG_CRIT_ENV")
expect_eq "a critical machine quarters the runner's width" "2" "$RG_RUN_CRIT"
expect_eq "…and quarters the tick's rung to the same number" "2" "$RG_TICK_CRIT"
expect_eq "the two consumers computed ONE rung, not two" "$RG_RUN_CRIT" "$RG_TICK_CRIT"
# NON-VACUITY: the two numbers differ between RG.1 and RG.2, so the equality above is not
# two constants agreeing.
expect_eq "…and it is not the clear answer wearing a different name" "no" \
  "$([ "$RG_RUN_CRIT" = "$RG_RUN_CLEAR" ] && echo yes || echo no)"

# --- RG.3 THE BAND MUTATION: move one threshold, both consumers move -----------
#
# `BAND_FREE_CRITICAL_PCT` is the constant that decides whether 8 % free is critical. Moved
# to 1, the same reading falls through to the WARNING arm (8 < 25) and the fraction becomes a
# half instead of a quarter — so both consumers must read 4 where they read 2. A mutation
# that moved only one of them would mean one consumer had its own copy of the band table.
#
# ONE MUTANT TREE SERVES BOTH, in the two layouts the two consumers resolve: the poker finds
# its library at `$(dirname "$0")/../scripts/lib`, and `tests/run.sh` sources
# `$REPO/payload/scripts/lib`. The shipped files are never touched.
RG_MUT="$SANDBOX/rg-mutant"
mkdir -p "$RG_MUT/hooks" "$RG_MUT/scripts/lib" "$RG_MUT/tests" "$RG_MUT/payload/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$RG_MUT/scripts/lib/" 2>/dev/null
cp "$BIONIC_HOOKS_DIR"/*.sh "$RG_MUT/hooks/" 2>/dev/null
cp "$REPO_ROOT/tests/run.sh" "$RG_MUT/tests/run.sh"
# ONE STUB SUITE, because the roster is the directory (fixit 1.5.1) and a runner
# asked to gate on an empty tests/ refuses rather than reporting green over
# nothing. This tree is only ever driven with --dry-run, which reads the same
# derived roster; the stub carries the pinned shebang the roster wall asks for,
# and the tree has no framework, so that half of the wall is inert here.
printf '#!/bin/bash\nexit 0\n' > "$RG_MUT/tests/stub.test.sh"
anchor -E "$RG_LIB_RES" '^BAND_FREE_CRITICAL_PCT=12' 1
sed 's/^BAND_FREE_CRITICAL_PCT=12/BAND_FREE_CRITICAL_PCT=1/' \
  "$RG_LIB_RES" > "$RG_MUT/scripts/lib/resources.sh"
cp "$RG_MUT/scripts/lib"/*.sh "$RG_MUT/payload/scripts/lib/" 2>/dev/null

RG_TREE_RUNNER="$RG_MUT"; RG_TREE_POKER="$RG_MUT"
rg_seed "$RG_CRIT_ENV"; RG_RUN_BAND=$(rg_runner "$RG_CRIT_ENV")
rg_seed_clear; RG_TICK_BAND=$(rg_tick "$RG_CRIT_ENV")
RG_TREE_RUNNER="$REPO_ROOT"; RG_TREE_POKER="$BIONIC_HOOKS_DIR/.."
[ -d "$RG_TREE_POKER/scripts/lib" ] || RG_TREE_POKER="$BIONIC_HOOKS_DIR/../payload"

expect_eq "moved band threshold: the runner halves instead of quartering" "4" "$RG_RUN_BAND"
expect_eq "…and the tick moves with it, to the same number" "4" "$RG_TICK_BAND"
expect_eq "…so one threshold change moved BOTH consumers" "$RG_RUN_BAND" "$RG_TICK_BAND"

# --- RG.4 THE SAMPLING PROBE (S8's uncaught-probe finding) --------------------
#
# THE FINDING. S8 observed that every rung fixture in the fleet starts from an EMPTY ring —
# and over an empty ring `pressure_level` takes a sample of its own before answering. So a
# consumer that had stopped sampling would still read the right number, and deleting
# `pressure_sample` from either consumer was a change no suite could catch. AC-15 is exactly
# the obligation that hole hid.
#
# THE TICK HALF is unchanged since S9: seed the ring with ONE clear reading through the real
# writer, then put the sensors in critical. The ring is no longer empty, so `pressure_level`
# takes no sample of its own — a tick that SAMPLES appends the critical reading, medians
# clear+critical to critical (an even count resolves to the higher band) and reads the
# QUARTER: 2; a tick that only READS sees one clear sample and reports the whole CEILING: 8.
#
# THE RUNNER HALF IS RE-POINTED (S25, critic K-4 option 2). `tests/run.sh --dry-run`
# legitimately stopped sampling — a dry run now writes nothing to the ring by design — so
# the band trick above can no longer separate "removed the sample call" from "working as
# specified": neither a shipped nor a doctored --dry-run touches the ring, so both would
# read the same seeded band and this probe would go vacuous for the runner's half. AC-15
# still binds the runner's ORDINARY (non-dry) path — the one that actually launches
# suites — so that half of this probe now drives THAT path directly and checks the RING'S
# OWN LINE COUNT, not a band read back through --dry-run. Both trees below carry ONE
# two-line stub suite and nothing else, so each run completes in well under a second —
# nothing here launches the real suite roster, which would recurse into this very file.
# (The stub is what an empty tests/ became at fixit 1.5.1: the roster is the directory,
# and a runner asked to gate on an empty one refuses instead of sampling and reporting
# green.)
RG_NOSAMP="$SANDBOX/rg-nosample"
mkdir -p "$RG_NOSAMP/hooks" "$RG_NOSAMP/scripts/lib" "$RG_NOSAMP/tests/lib" "$RG_NOSAMP/payload/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$RG_NOSAMP/scripts/lib/" "$RG_NOSAMP/payload/scripts/lib/" 2>/dev/null
cp "$BIONIC_HOOKS_DIR"/*.sh "$RG_NOSAMP/hooks/" 2>/dev/null
cp "$REPO_ROOT/tests/lib/resolve-roots.sh" "$RG_NOSAMP/tests/lib/resolve-roots.sh"
printf '#!/bin/bash\nexit 0\n' > "$RG_NOSAMP/tests/stub.test.sh"
# the runner with its `pressure_sample` line removed, and nothing else changed.
#
# ANCHORED ON THE CALL'S STABLE TOKENS, NOT ON ITS INDENTATION (critic K-1 — the same
# lesson the poker's own anchor just below already carries). S25 moved this call inside an
# `if [ "$DRY_RUN" -eq 0 ]` guard, re-indenting it two spaces; `[[:space:]]*` absorbs that
# reindent and any future one.
anchor -E "$REPO_ROOT/tests/run.sh" '^[[:space:]]*pressure_sample >/dev/null 2>&1 \|\| :$' 1
grep -vE '^[[:space:]]*pressure_sample >/dev/null 2>&1 \|\| :$' "$REPO_ROOT/tests/run.sh" \
  > "$RG_NOSAMP/tests/run.sh"
# the tick with ITS `pressure_sample` line removed, and nothing else changed.
#
# ANCHORED ON THE CALL'S STABLE TOKENS, NOT ON ITS INDENTATION OR ITS VARIABLE NAME (critic
# K-1). The prior anchor pinned both — four leading spaces and the literal `$SCHED_CORES` —
# and S21 (`61b8ca8`) moved the call into `sched_budget_read`, re-indenting it to two spaces
# and renaming the local to `$cores`; the anchor then matched nothing, the "doctored" copy
# was byte-identical to the shipped one, and this section's own meta-check row (below) is what
# caught it. `pressure_sample`, the `>/dev/null 2>&1 || :` suffix and the one-line shape are the
# part of this call that is actually load-bearing; a future reindent or a rename of the local
# holding the core count should not be able to silently disarm this probe again.
anchor -E "$SPO" '^[[:space:]]*pressure_sample "\$[A-Za-z_][A-Za-z0-9_]*" >/dev/null 2>&1 \|\| :$' 1
grep -vE '^[[:space:]]*pressure_sample "\$[A-Za-z_][A-Za-z0-9_]*" >/dev/null 2>&1 \|\| :$' "$SPO" \
  > "$RG_NOSAMP/hooks/session-poker.sh"

# THE SHIPPED CONTROL TREE for the runner half: the real tests/run.sh, byte for byte, in a
# scratch tree with no real suite files — so "shipped" and "no-sample" differ ONLY in the
# one line the grep above removed, never in which suites they would (fail to) run.
RG_SHIPPED="$SANDBOX/rg-shipped"
mkdir -p "$RG_SHIPPED/tests/lib" "$RG_SHIPPED/payload/scripts/lib"
cp "$LIB_DIR_SRC"/*.sh "$RG_SHIPPED/payload/scripts/lib/" 2>/dev/null
cp "$REPO_ROOT/tests/lib/resolve-roots.sh" "$RG_SHIPPED/tests/lib/resolve-roots.sh"
cp "$REPO_ROOT/tests/run.sh" "$RG_SHIPPED/tests/run.sh"
printf '#!/bin/bash\nexit 0\n' > "$RG_SHIPPED/tests/stub.test.sh"
expect_eq "the shipped control tree carries the runner byte for byte (not vacuous)" "yes" \
  "$(cmp -s "$REPO_ROOT/tests/run.sh" "$RG_SHIPPED/tests/run.sh" && echo yes || echo no)"

# rg_runner_samples <tree> -> "yes" if <tree>/tests/run.sh's ORDINARY (non-dry) path
# appends exactly one line to a ring seeded with one clear sample; "no" otherwise.
rg_runner_samples() {
  local tree="$1" before after
  rg_seed_clear
  before="$(wc -l < "$RG_RING" | tr -d ' ')"
  ( eval "export $RG_CRIT_ENV"
    cd "$tree" &&
    export BIONIC_PRESSURE_RING="$RG_RING" BIONIC_NOW_EPOCH="$RG_NOW" \
           BIONIC_TEST_JOBS_CEILING="$RG_CEIL"
    bash tests/run.sh >/dev/null 2>&1 )
  after="$(wc -l < "$RG_RING" | tr -d ' ')"
  [ "$after" -eq "$((before + 1))" ] && echo yes || echo no
}

RG_RUN_SHIPPED_SAMPLES=$(rg_runner_samples "$RG_SHIPPED")
RG_RUN_NOSAMP_SAMPLES=$(rg_runner_samples "$RG_NOSAMP")
expect_eq "the shipped runner's ordinary path samples once (AC-15)" "yes" \
  "$RG_RUN_SHIPPED_SAMPLES"
expect_eq "a runner that stopped sampling leaves the ring untouched: the removal is CAUGHT" \
  "no" "$RG_RUN_NOSAMP_SAMPLES"

# the shipped tick, over the SEEDED ring — it samples, so it reads the quarter
rg_seed_clear; RG_TICK_SEEDED=$(rg_tick "$RG_CRIT_ENV")
expect_eq "over a seeded ring the shipped tick still reads the critical quarter" "2" \
  "$RG_TICK_SEEDED"

RG_TREE_POKER="$RG_NOSAMP"
rg_seed_clear; RG_TICK_NOSAMP=$(rg_tick "$RG_CRIT_ENV")
RG_TREE_POKER="$BIONIC_HOOKS_DIR/.."
[ -d "$RG_TREE_POKER/scripts/lib" ] || RG_TREE_POKER="$BIONIC_HOOKS_DIR/../payload"

expect_eq "a tick that stopped sampling reports the whole ceiling too" \
  "$RG_CEIL" "$RG_TICK_NOSAMP"
expect_eq "…which is not what the shipped tick reports: that removal is CAUGHT as well" "no" \
  "$([ "$RG_TICK_NOSAMP" = "$RG_TICK_SEEDED" ] && echo yes || echo no)"

# --- RG.5 the pin is honoured: this section's readings are on this section's ring ---
#
# Asserted rather than trusted. Every drive above ran with `BIONIC_PRESSURE_RING` set, and a
# consumer that ignored the pin would append to the DEFAULT ring under
# `${CLAUDE_CONFIG_DIR}/bionic/` instead. Both paths are inside the sandbox — the suite
# redirects `CLAUDE_CONFIG_DIR` in its header, which is what keeps the machine's own ring out
# of reach of every section in this file — so the question is not whether a default ring
# exists (other sections in this file drive the tick without a pin and create one), but
# whether any reading STAMPED WITH THIS SECTION'S PINNED CLOCK landed on it.
rg_ring_count() {  # <ring file> -> how many of this section's samples it holds
  [ -f "$1" ] || { printf '0'; return 0; }
  LC_ALL=C awk -F'|' -v n="$RG_NOW" '$1 == n { c++ } END { print c + 0 }' "$1" 2>/dev/null
}
expect_eq "the sandbox ring holds this section's readings" "yes" \
  "$([ "$(rg_ring_count "$RG_RING")" -gt 0 ] && echo yes || echo no)"
expect_eq "…and the default ring holds none of them: the pin was honoured by every consumer" \
  "0" "$(rg_ring_count "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/bionic/pressure.ring")"
expect_contains "…and that default ring is itself inside the sandbox, never the machine's" \
  "$SANDBOX" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/bionic/pressure.ring"
# ============================================================
section "BP — every shell file in the tree parses under the SYSTEM interpreter"
# ============================================================
#
# WHY THIS SECTION EXISTS. `tests/cross-gate-agreement.test.sh` shipped a `case` inside a
# `$( … )` at slice S19. Its own shebang says `#!/bin/bash`, which on macOS is bash 3.2,
# and 3.2's parser cannot read that construct — so the file that holds every one-owner
# agreement row this wave added was unparseable by the interpreter it names. It ran green
# for days because this machine's PATH resolves `bash` to a Homebrew 5.x build, and the
# runner invokes `bash tests/…`, never `/bin/bash tests/…` (Step-6 review C-2). Nothing in
# the tree checked parseability under the system interpreter; this does.
#
# IT IS A PARSE CHECK, NOT A RUN. `-n` reads and parses and executes nothing, so this
# sweep touches no state, spawns no hook and cannot depend on any fixture — it is the
# cheapest possible whole-tree assertion and the only one in this file that reads the
# shipped tree rather than a sandbox copy.
#
# THE ROSTER (critic K-6). Four directories cover almost everything, but two shipped
# scripts sit outside all four: `agents-src/render.sh` (not incidental — it writes the
# version half of AC-26 into `payload/commands/help.md`) and the root `wsl-setup.sh`.
# Both are named directly rather than adding their parents wholesale, so a stray future
# `*.sh` dropped elsewhere at the repo root still falls outside the sweep on purpose —
# widen this list again if that ever needs to change.
BP_SH="$(cd "$BIONIC_SCRIPTS_DIR" && find hooks payload/scripts payload/hooks tests \
  agents-src/render.sh wsl-setup.sh -name '*.sh' -type f 2>/dev/null | LC_ALL=C sort)"
expect_eq "the sweep found shell files to check" "yes" \
  "$([ -n "$BP_SH" ] && echo yes || echo no)"

bp_sweep() {  # <root> <newline-separated relative paths> -> one `FAIL <path>: <msg>` per
              # file that does not parse
  local root="$1" list="$2" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    /bin/bash -n "$root/$f" 2>&1 | sed "s|^|FAIL $f: |"
  done <<EOF
$list
EOF
  return 0
}

BP_OUT="$(bp_sweep "$BIONIC_SCRIPTS_DIR" "$BP_SH")"
expect_eq "every *.sh under hooks, payload/scripts, payload/hooks and tests parses under /bin/bash" \
  "" "$BP_OUT"
expect_eq "…and the system interpreter this asserts against is the one the shebangs name" \
  "yes" "$([ -x /bin/bash ] && echo yes || echo no)"

# THE MUTATION ARM. A sweep that cannot go red is a sweep that proves nothing. Plant the
# exact construct C-2 found — a `case` inside a command substitution — in a COPY of a real
# file under the sandbox, and require the sweep to name that file.
BP_MUT="$SANDBOX/bp-mutant"
mkdir -p "$BP_MUT/tests"
cat > "$BP_MUT/tests/bp-planted.test.sh" <<'BPEOF'
#!/bin/bash
# A copy carrying the bash-3.2 defect C-2 found, for the mutation arm of §BP.
planted() {
  local n="$1"
  body=$(
    for x in $n; do
      case "$x" in
        *:*) echo "${x%%:*}" ;;
        *)   echo "$x" ;;
      esac
    done
  )
  printf '%s\n' "$body"
}
BPEOF
BP_MUT_OUT="$(/bin/bash -n "$BP_MUT/tests/bp-planted.test.sh" 2>&1)"
expect_eq "the mutation arm: the planted construct does NOT parse under /bin/bash" "yes" \
  "$([ -n "$BP_MUT_OUT" ] && echo yes || echo no)"
expect_contains "…and the failure names the case pattern that closes it" ";;" "$BP_MUT_OUT"
BP_SWEPT="$(bp_sweep "$BP_MUT" "tests/bp-planted.test.sh")"
expect_contains "…and the sweep reports it as a FAIL row naming the file" \
  "FAIL tests/bp-planted.test.sh" "$BP_SWEPT"

# THE OTHER SHAPE, WHICH `-n` CANNOT SEE. A ONE-LINE `case` inside a command substitution
# PARSES under 3.2 and then evaluates to the tail of its own source text — two rows of §S2
# in this very file read `expected 'no', got ' echo yes ;; *) echo no ;; esac)'` under
# /bin/bash while `-n` said the file was fine. So the sweep above is necessary and not
# sufficient, and this row covers the gap by forbidding the idiom outright.
# The pattern is written in bracket classes so that this file's own source does not match
# the rule it enforces.
BP_RE='[$][(]case '
BP_INLINE="$(cd "$BIONIC_SCRIPTS_DIR" && LC_ALL=C grep -nE "$BP_RE" \
  $(printf '%s\n' "$BP_SH" | tr '\n' ' ') 2>/dev/null)"
expect_eq "no file opens a \`case\` inside a command substitution on one line" "" "$BP_INLINE"

# The mutation arm, and it is the QUOTED shape on purpose: unquoted, 3.2 refuses to parse
# and `-n` catches it; inside double quotes it parses clean and then truncates the
# substitution at the first `)` at RUN time, leaking the rest as literal text. That is the
# shape `-n` cannot see, and the one this grep exists for.
BP_INLINE_MUT="$SANDBOX/bp-inline.sh"
BP_DOL='$'
printf '#!/bin/bash\nx="%s(case "%s1" in *a*) echo yes ;; *) echo no ;; esac)"\nprintf "%%s" "%sx"\n' \
  "$BP_DOL" "$BP_DOL" "$BP_DOL" > "$BP_INLINE_MUT"
expect_eq "the mutation arm: the quoted one-line shape PARSES, so -n cannot catch it" "0" \
  "$(/bin/bash -n "$BP_INLINE_MUT" >/dev/null 2>&1; echo $?)"
expect_contains "…and at run time it leaks its own source text instead of answering" \
  "esac)" "$(/bin/bash "$BP_INLINE_MUT" abc 2>/dev/null)"
expect_eq "…but the grep catches it" "yes" \
  "$([ -n "$(LC_ALL=C grep -nE "$BP_RE" "$BP_INLINE_MUT")" ] && echo yes || echo no)"

# ------------------------------------------------ §DS OWNERSHIP: the fix hint and the roster
#
# ONE TABLE, TWO RENDERERS, FOUR WAYS OF ASKING WHETHER THEY AGREE (fixit 1.5.1).
# `payload/scripts/lib/checks.sh` holds the table: one row per fact bionic needs true on a
# machine, carrying that fact's detector, the party who repairs it, the setup item when that
# party is setup, and the hint a report must print. doctor.sh and setup.sh render from it and
# neither owns a check of its own, so this section stopped comparing the two SCRIPTS against
# each other and started comparing each of them against the table. The four legs, each with
# its own sub-banner below:
#
#   DS.2a  every labelled row that FIRES renders somewhere on doctor's page, with its hint
#   DS.2   everything doctor renders resolves to a row of the table, party and item included
#   DS.2b  setup's `--list` IS the table's item column, set against set, both directions
#   DS.2c  the same machine, both sides: an item setup would offer is flagged by doctor
#
# and the mutation arms DS.5–DS.10 plant, on copies, each drift those legs exist to catch.
#
# THE TWO PARTIES ARE doctor.sh AND setup.sh, and the question they have to answer the same
# way is "what can /bionic:setup repair on this machine". Doctor ends a row with
# `→ /bionic:setup` to say the command below will clear it; setup's `--list` is the roster of
# what that command can be asked for, and `_setup_item_pending` decides which of those it
# would actually offer on the machine in front of it. Nothing bound the three together, and
# on 2026-09-05 they disagreed in the field: doctor printed `16 legacy hook files … →
# /bionic:setup` and `6/6 differ … → /bionic:setup`, and `/bionic:setup --all` run straight
# afterwards planned one dependency and ended "nothing left to do — this machine is set up."
# (bug report .bionic/docs/ideas/bug-doctor-setup-ownership.md, filed against payload 1.4.3).
# A hint naming a command that then reports nothing to do is worse than no hint: the reader
# runs it, believes the green summary, and the ✗ row is still there on the next run.
#
# ONE FIXTURE, BOTH SCRIPTS, THE SAME MACHINE STATE. Every row below is taken on a
# claude-home this section builds — leftover hook FILES the payload ships by the same name,
# leftover agent role files that no longer match the payload — with `BIONIC_PLUGIN_ROOT`
# pointing at the shipped payload so both scripts read the same idea of what bionic ships.
# Doctor is rendered and its rows are parsed; setup is asked `--list` and then asked to run
# the one item narrowed, with the answer channel CLOSED so a pending item reports itself
# through its action line and nothing on the fixture is ever written.
#
# BOTH TABLES ARE IN SCOPE NOW (1.4.4 fixit T1, AC-1). The scan used to take doctor's
# ENVIRONMENT section alone — the table that reports the machine's own state, where the five
# leftover rows and the environment keys live — and said so here: the THIRD PARTY table was
# "a separate question with a separate answer", because a core dependency doctor reports
# absent is installed by the CLI as bionic's own dependency and not by a setup item. That
# was the right answer to the wrong question. The separate answer is what the ROW must say;
# it is not a reason to leave the row unscanned, and while it was unscanned the row went on
# ending `→ /bionic:setup` over a command that plans nothing for it — the same defect this
# section exists to catch, in the one table it could not see. So the hint is checked in both
# tables against one rule (every `→ /bionic:setup` needs an item that fires), and the core
# row is checked against the other half of the contract: it names the CLI's repair route and
# never sends anyone to setup. §DS.7 and §DS.8 below.
#
# THE MUTATION ARMS ARE BOTH DIRECTIONS OF THE SAME DRIFT. A doctored setup.sh whose roster
# has lost `legacy-hook-files` must take the agreement row red — that is the exact field
# defect, a hint with no item behind it. A doctored doctor.sh carrying a NEW hinted row must
# take the completeness row red — that is the defect arriving tomorrow, a row added with the
# suffix and no item to go with it. Neither mutant is ever the shipped file: both are copies
# under the sandbox, driven through the same `W1R_PARTY_*` override the four parties above
# use.

DS_PAYLOAD="${BIONIC_SCRIPTS_DIR}/payload"
PARTY_DOCTOR="${W1R_PARTY_DOCTOR:-$DS_PAYLOAD/scripts/doctor.sh}"
PARTY_SETUP="${W1R_PARTY_SETUP:-$DS_PAYLOAD/scripts/setup.sh}"

DS_DIR="$SANDBOX/ds"
mkdir -p "$DS_DIR"

# The claude-home the field machine had: hook SCRIPTS the retired installer copied in, and
# role files two builds behind the payload's. Sixteen of the payload's hook names and all six
# of its agent names, which is the shape the bug report measured (16 in ~/.claude/hooks, 6/6
# differ) — and NOT every hook the payload ships, so a run that removed by wildcard instead of
# by name would show up as a count that is too high.
#
# ONE FILE IN EACH DIRECTORY IS NOT BIONIC'S, and it is the whole point of planting them: both
# detectors match payload-side names only, both removals must too, and a machine's own hook or
# its own agent is not bionic's leftover to delete.
# AND THE STATUS LINE THE FIELD MACHINE ACTUALLY HAD (epic-21 1.4.4 T5). Every machine
# that ran setup before this patch carries `npx ccstatusline@latest` in settings.json AND
# the shipped layout under ~/.config/ccstatusline — the two halves `_dep_check_statusline`
# reads. Planting only the first would leave the row absent for the layout's sake and prove
# nothing about the command; planting both is the pre-1.4.4 shape, where the ONLY thing
# wrong is the recorded command. That is the state doctor's `statusLine command` row fires
# on, so it is the state this scan has to see it in.
ds_plant() {  # <home> <hooks:yes|no> <agents:yes|no> [alias:yes|no, default no]
  local h="$1" want_hooks="$2" want_agents="$3" want_alias="${4:-no}" f n=0
  rm -rf "$h"; mkdir -p "$h/.claude"
  # AND ONE ENVIRONMENT NAME WRITTEN TO THE WRONG VALUE (Step-6 review B-1). The
  # environment row has two firing states — the name is absent from the `env`
  # object, or it is there carrying something other than the value bionic sets —
  # and this fixture used to reach only the first, because it wrote no `env`
  # object at all. The second is the state where doctor and setup disagreed in
  # the field's own shape: a tick from the page over a repair setup was still
  # offering. One key is planted wrong and the other two are left absent, so the
  # scans below see both states of the same row on one machine.
  cat > "$h/.claude/settings.json" <<'DSJSON'
{
  "statusLine": {
    "type": "command",
    "command": "npx ccstatusline@latest"
  },
  "env": {
    "BASH_MAX_TIMEOUT_MS": "600000"
  }
}
DSJSON
  mkdir -p "$h/.config/ccstatusline"
  cp "$DS_PAYLOAD/ccstatusline/settings.json" "$h/.config/ccstatusline/settings.json"
  # AND THE PLUGIN REGISTRY, WITH ONE CORE DEPENDENCY MISSING (1.4.4 fixit T1). This is the
  # seam `_dep_check_native` reads — `$BIONIC_CLAUDE_HOME/plugins/installed_plugins.json` via
  # `_dep_installed_json` — and writing it is what makes a core dependency absent WITHOUT
  # installing or uninstalling anything for real. The shape is this machine's own registry
  # (`bionic`, `agent-skills`, `impeccable` from bionic's catalog; the two anthropic skill
  # packs from theirs) minus `superpowers`, which is exactly the machine epic-17 W5 F12 §4.1
  # measured: the CLI refuses to load bionic and its own error names the repair
  # (record/epic-17-w5/f12-runtime-report.md §4.1). Leaving the file out entirely — which is
  # what this fixture used to do — reads as EVERY native row absent, including the ones that
  # are fine, so the table under test would have been all one state.
  mkdir -p "$h/.claude/plugins"
  cat > "$h/.claude/plugins/installed_plugins.json" <<'DSREG'
{
  "plugins": {
    "bionic@bionic":                          [{"version": "1.4.4", "installPath": "/nonexistent/bionic"}],
    "agent-skills@bionic":                    [{"version": "0.6.7", "installPath": "/nonexistent/agent-skills"}],
    "impeccable@bionic":                      [{"version": "4.1.1", "installPath": "/nonexistent/impeccable"}],
    "document-skills@anthropic-agent-skills": [{"version": "41bbe19d1a1a", "installPath": "/nonexistent/document-skills"}],
    "example-skills@anthropic-agent-skills":  [{"version": "41bbe19d1a1a", "installPath": "/nonexistent/example-skills"}]
  }
}
DSREG
  if [ "$want_hooks" = "yes" ]; then
    mkdir -p "$h/.claude/hooks"
    for f in "$DS_PAYLOAD"/hooks/*.sh; do
      [ -f "$f" ] || continue
      [ "$n" -lt 16 ] || break
      printf '#!/bin/bash\n# an older build of %s\n' "${f##*/}" > "$h/.claude/hooks/${f##*/}"
      n=$((n + 1))
    done
    printf '#!/bin/bash\n# the machine owner wrote this one\n' > "$h/.claude/hooks/not-bionics.sh"
  fi
  # THE PRE-MARKER ALIAS, OFF BY DEFAULT (Step-6 recheck part 4, R-2). This is the
  # one leftover whose two rules had genuinely drifted:
  # `bionic_check_legacy_alias` fires on the marked `# ─── bionic:start ───`
  # block OR on a bare `alias claude=…--dangerously-skip-permissions` line, which
  # is the spelling bionic wrote before it wrapped its edits in markers; doctor's
  # own test read the marker and nothing else. Planted here is the SECOND state
  # only — the raw alias, no marker — which is the machine where the two answers
  # differ. BOTH rc names are written because `shell_rc_file` picks between
  # `$HOME/.zshrc` and `$HOME/.bashrc` off `$SHELL`, and the suite must not read
  # the runner's shell. Default `no`, so every fixture planted before this arm
  # existed is byte-identical to what it was.
  if [ "$want_alias" = "yes" ]; then
    printf '%s\n' 'alias claude="claude --dangerously-skip-permissions"' > "$h/.zshrc"
    cp "$h/.zshrc" "$h/.bashrc"
  fi
  if [ "$want_agents" = "yes" ]; then
    mkdir -p "$h/.claude/agents"
    for f in "$DS_PAYLOAD"/agents/*.md; do
      [ -f "$f" ] || continue
      printf -- '---\nname: %s\n---\nan older build of this role.\n' "${f##*/}" \
        > "$h/.claude/agents/${f##*/}"
    done
    printf -- '---\nname: not-bionics\n---\nthe machine owner wrote this one.\n' \
      > "$h/.claude/agents/not-bionics.md"
  fi
}

ds_doctor() {  # <home> -> doctor's whole report
  HOME="$1" BIONIC_CLAUDE_HOME="$1/.claude" BIONIC_PLUGIN_ROOT="$DS_PAYLOAD" \
    bash "$PARTY_DOCTOR" 2>/dev/null
}

# The answer channel is CLOSED on purpose: every question this reaches goes unanswered, the
# step reports itself through its action line, and the fixture is never written to. That is
# what makes a pending item observable without consenting to anything.
ds_setup() {  # <home> <args…> -> setup's whole run
  local h="$1"; shift
  HOME="$h" BIONIC_CLAUDE_HOME="$h/.claude" BIONIC_PLUGIN_ROOT="$DS_PAYLOAD" \
    bash "$PARTY_SETUP" "$@" < /dev/null 2>/dev/null
}

# The one arm that consents, for the removal rows: exactly one `y`, to exactly one question.
ds_setup_yes() {  # <home> <args…>
  local h="$1"; shift
  printf 'y\n' | HOME="$h" BIONIC_CLAUDE_HOME="$h/.claude" BIONIC_PLUGIN_ROOT="$DS_PAYLOAD" \
    bash "$PARTY_SETUP" "$@" 2>/dev/null
}

# ── The table both parties render from ───────────────────────────────────────
#
# ONE SOURCE, READ THE WAY BOTH SCRIPTS READ IT. `payload/scripts/lib/checks.sh`
# holds one row per fact bionic needs true on a machine — id, doctor's label, the
# read-only detector, the repair party, the setup item when that party is setup,
# and the hint the report must carry. Doctor renders from it and setup renders
# from it, so this section asks the table what the answer should be instead of
# carrying a hand-written map of its own. The two maps that used to live here
# (`ds_item_for`, `ds_party_item_for`, 22 dependency names and six labels spelled
# out by hand) were the claim under test only while nothing in the payload held
# the claim; now something does, and a copy of it here would be the second source
# this whole slice exists to remove.
#
# READ UNDER THE FIXTURE'S OWN ENVIRONMENT, exactly as `ds_doctor` and `ds_setup`
# are: the table's generated half asks the dependency catalog and the CLI's own
# duplicate probe, and a table read under the SUITE's environment would be a
# different machine's table than the one the two renderers just read.
DS_CHECKS_LIB="${W1R_PARTY_CHECKS:-$DS_PAYLOAD/scripts/lib/checks.sh}"

ds_rows() {  # <home> -> the whole check table, one row per line
  HOME="$1" BIONIC_CLAUDE_HOME="$1/.claude" BIONIC_PLUGIN_ROOT="$DS_PAYLOAD" \
    bash -c '. "$1" >/dev/null 2>&1 || exit 1; bionic_check_rows' _ "$DS_CHECKS_LIB" 2>/dev/null
}

ds_field() {  # <row> <1..6>
  printf '%s' "$(printf '%s' "$1" | cut -d'|' -f"$2")"
}

# ONE EXTRACTOR, TAKING THE HEADER (fixit B-8). `ds_env_section` and
# `ds_third_section` were the same four lines of awk twice, differing only in the
# header they open on, and `ds_hint_labels`/`ds_party_hint_labels` were the same
# loop twice, differing only in which of those two they called. Four helpers, two
# behaviours, and a fix applied to one copy of either pair would have been a fix
# the other copy did not get. Rows are indented two columns, so a bare capitalised
# line is always a section header and never a row; the header itself is consumed
# before any row is read, so a section name can never be mistaken for a hint.
ds_section() {  # <doctor report> <header pattern>
  awk -v hdr="$2" '
    $0 ~ ("^" hdr) && !inside { inside = 1; next }
    inside && /^[A-Z][A-Z]/ { exit }
    inside { print }' <<<"$1"
}

# Every line in doctor's two machine-state tables that carries a repair route. A
# route is whatever the table says a route is — `/bionic:setup` for the rows setup
# clears, the CLI's own reinstall verb for the rows it does not — so a row that
# names a party gets scanned no matter which party that is, and no matter whether
# the hint reaches it through an arrow or an em-dash. THAT last part is the
# widening: the old extractor matched the literal `→ /bionic:setup`, and three
# hinted rows (doctor.sh's stale-dependency row and both claude()-proxy rows) said
# `— /bionic:setup …` instead and were never scanned at all.
ds_hinted_lines() {  # <doctor report> <routes, one per line>
  local line route hit
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    hit=""
    while IFS= read -r route; do
      [ -n "$route" ] || continue
      case "$line" in *"$route"*) hit=1; break ;; esac
    done <<<"$2"
    [ -n "$hit" ] && printf '%s\n' "$line"
  done <<<"$(ds_section "$1" "ENVIRONMENT$")
$(ds_section "$1" "THIRD PARTY")"
  return 0
}

# EVERY LABELLED ROW THAT FIRES ON THIS MACHINE, asked in ONE process (Step-6
# review A-2/A-4, C-1). `ds_hinted_lines` starts from doctor's page and keeps the
# lines that already carry a route, which can only ever prove "the route you
# printed is the one your row names" — a row that lost its route, or a row doctor
# never renders at all, is filtered out before any leg reads it. This starts from
# the TABLE instead: every row with a label whose detector fires, whatever its
# party, so the walk below can require a rendering rather than notice one.
ds_fired_rows() {  # <home> -> id|label|hint for every labelled row that fires
  HOME="$1" BIONIC_CLAUDE_HOME="$1/.claude" BIONIC_PLUGIN_ROOT="$DS_PAYLOAD" \
    bash -c '. "$1" >/dev/null 2>&1 || exit 1
             bionic_check_rows | while IFS="|" read -r ds_i ds_l ds_d ds_p ds_it ds_h; do
               [ -n "$ds_l" ] || continue
               [ -n "$ds_d" ] || continue
               "$ds_d" "$ds_i" || continue
               printf "%s|%s|%s\n" "$ds_i" "$ds_l" "$ds_h"
             done' _ "$DS_CHECKS_LIB" 2>/dev/null
}

# THE WHOLE PAGE, NOT TWO SECTIONS (plan A-T5-5). A row renders where its section
# puts it — the environment loop, the dependency walk, the leftover block — and a
# leg that reads ENVIRONMENT and THIRD PARTY alone cannot see a row rendered in
# PATROL or RESOURCES, or one rendered nowhere. Every rendered row has the same
# shape: two spaces, one state glyph, a space, then the label. The column-header
# line starts with four spaces and is skipped by the glyph test.
ds_page_line_for() {  # <doctor report> <label> -> the rendered line carrying it
  local line rest
  while IFS= read -r line; do
    case "$line" in ("  "*) ;; (*) continue ;; esac
    rest="${line#  }"
    case "$rest" in (" "*) continue ;; esac
    rest="${rest#* }"
    case "$rest" in
      ("$2") printf '%s' "$line"; return 0 ;;
      ("$2 "*) printf '%s' "$line"; return 0 ;;
    esac
  done <<<"$1"
  return 1
}

# The walk itself, factored out because the two mutation arms at the end of this
# section run the very same code over a doctored library and have to come out
# non-empty. Answers with one line per row that is missing, unrendered or hintless.
ds_unrendered() {  # <doctor report> <fired rows> -> the rows the page does not carry
  local row id label hint line out=""
  while IFS='|' read -r id label hint; do
    [ -n "$id" ] || continue
    if [ -z "$hint" ]; then
      out="${out}${out:+, }${id} carries no hint at all"
      continue
    fi
    if ! line="$(ds_page_line_for "$1" "$label")"; then
      out="${out}${out:+, }${id} (${label}) renders nowhere on the page"
      continue
    fi
    case "$line" in
      (*"$hint"*) ;;
      (*) out="${out}${out:+, }${id} (${label}) renders without its hint" ;;
    esac
  done <<<"$2"
  printf '%s' "$out"
}

# The label a rendered row carries: two spaces, the state glyph, a space, then the
# label padded out with spaces, so cutting at the first DOUBLE space ends it.
ds_label_of() {  # <rendered row>
  local rest="${1#  }"
  rest="${rest#* }"
  printf '%s' "${rest%%  *}"
}

# THE SETTING CELL CAN BE FULL, so a label is not always followed by two spaces:
# `_doctor_env3` pads the setting to 36 columns and one environment key is exactly
# 36 characters long, which runs its label straight into its value column with a
# single space between. A label that IS a table label and one that BEGINS with a
# table label followed by a space are the same row.
ds_row_for() {  # <rendered label> <table> -> the table row that owns it
  local label="$1" row l
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    l="$(ds_field "$row" 2)"
    [ -n "$l" ] || continue
    [ "$label" = "$l" ] && { printf '%s' "$row"; return 0; }
    case "$label" in "$l "*) printf '%s' "$row"; return 0 ;; esac
  done <<<"$2"
  return 1
}

# The completeness half of the scan, factored out because the mutation arm below
# runs the very same code over a doctored doctor and has to come out non-empty.
# It asks nothing of setup, so it is cheap enough to run twice.
ds_unmapped() {  # <doctor report> <table> <routes> -> the hinted labels with no row behind them
  local line label out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    label="$(ds_label_of "$line")"
    ds_row_for "$label" "$2" >/dev/null && continue
    out="${out}${out:+, }${label}"
  done <<<"$(ds_hinted_lines "$1" "$3")"
  printf '%s' "$out"
}

# Is the item on setup's roster at all — the `--list` half of the agreement.
ds_listed() {  # <home> <item>
  local id
  while IFS= read -r id; do
    [ "$id" = "$2" ] && return 0
  done <<<"$(ds_setup "$1" --list)"
  return 1
}

ds_listed_in() {  # <--list output> <item>
  local id
  while IFS= read -r id; do [ "$id" = "$2" ] && return 0; done <<<"$1"
  return 1
}

# Would setup OFFER it on this machine — the presence-check half. A narrowed run
# that found nothing to do says so in its own summary, by name; anything else
# means the step asked.
ds_pending() {  # <home> <item>
  local out
  out="$(ds_setup "$1" --only "$2")"
  case "$out" in
    *"nothing left to do for $2."*) return 1 ;;
    *) return 0 ;;
  esac
}

# EVERY ITEM THIS MACHINE WOULD BE OFFERED, ASKED ONCE. `ds_pending` starts a whole
# setup run per item, which is the right instrument for the handful of rows DS.2
# drives — that arm is about setup's own narrowed behaviour — and the wrong one for
# a walk over the roster: thirty script starts for one fact, on the suite the whole
# fleet waits behind. setup's `_setup_item_pending` IS `bionic_check_item_pending`,
# so this asks setup's own predicate in one process. DS.2c pairs the two below, so
# the cheap oracle is bound to the expensive one rather than trusted.
ds_pending_items() {  # <home> -> the items that fire on it, one per line
  HOME="$1" BIONIC_CLAUDE_HOME="$1/.claude" BIONIC_PLUGIN_ROOT="$DS_PAYLOAD" \
    bash -c '. "$1" >/dev/null 2>&1 || exit 1
             bionic_check_items | while IFS= read -r i; do
               [ -n "$i" ] || continue
               bionic_check_item_pending "$i" && printf "%s\n" "$i"
             done' _ "$DS_CHECKS_LIB" 2>/dev/null
}

# ── DS.1 the field state, and both parties' answers to it ────────────────────
DS_HOME="$DS_DIR/full"
ds_plant "$DS_HOME" yes yes
DS_REPORT="$(ds_doctor "$DS_HOME")"
DS_TABLE="$(ds_rows "$DS_HOME")"
DS_LIST="$(ds_setup "$DS_HOME" --list)"
DS_ROUTES="$(while IFS= read -r ds_r; do [ -n "$ds_r" ] && ds_field "$ds_r" 6 && echo; done <<<"$DS_TABLE" | sort -u | grep -v '^$')"
DS_HINTED="$(ds_hinted_lines "$DS_REPORT" "$DS_ROUTES")"
DS_LABELS="$(while IFS= read -r ds_l; do [ -n "$ds_l" ] && ds_label_of "$ds_l" && echo; done <<<"$DS_HINTED")"

expect_true "DS.1 the check table loaded and carries rows (everything below reads it)" \
  test "$(printf '%s\n' "$DS_TABLE" | grep -c '|')" -ge 20
expect_true "DS.1 …and it names at least two distinct repair routes (setup's and the CLI's)" \
  test "$(printf '%s\n' "$DS_ROUTES" | grep -c .)" -ge 2
expect_contains "DS.1 doctor flags the leftover hook FILES on the fixture machine" \
  "legacy hook files" "$DS_LABELS"
expect_contains "DS.1 …and the installed agent copies that no longer match the payload" \
  "legacy installed agent copies" "$DS_LABELS"
expect_contains "DS.1 …and it counts the sixteen payload-named files, not the whole directory" \
  "16 in ~/.claude/hooks" "$DS_REPORT"
expect_contains "DS.1 …and all six role files as drifted" \
  "6/6 differ" "$DS_REPORT"

# ── DS.2a THE FIRST WAY: every row that fires renders, with its hint ─────────
#
# THE DIRECTION THE OTHER LEGS CANNOT SEE. DS.2 below starts from doctor's page
# and asks whether what it found is in the table; that is `render ⊆ table`, and
# it says nothing about a row the page never printed. This is the other
# containment — every labelled row whose detector fires on this machine has to
# appear SOMEWHERE on doctor's page, carrying the hint its row names — and it is
# the leg the design's first way asks for (plan AC-1).
#
# TWO DEFECTS IT CATCHES THAT NOTHING ELSE DID. A row whose hint went missing
# (a mistyped id resolves to nothing, and `bionic_check_hint`'s non-zero is
# discarded by every call site) used to vanish from the route-keyed scan and
# leave a ✗ row with no cure — the reader-facing half of the field defect. And a
# labelled row added to the table with no call site in doctor.sh renders nowhere
# at all: setup's roster derives from the rows, doctor's page does not, and until
# this leg nothing said so. Both are planted and watched red at DS.9 and DS.10.
DS_FIRED="$(ds_fired_rows "$DS_HOME")"
DS_UNRENDERED="$(ds_unrendered "$DS_REPORT" "$DS_FIRED")"
expect_true "DS.2a the table names labelled rows that fire on this fixture (the rows under it are not vacuous)" \
  test "$(printf '%s\n' "$DS_FIRED" | grep -c '|')" -ge 6
expect_eq "DS.2a every labelled row that fires renders on doctor's page, with its hint" \
  "" "$DS_UNRENDERED"
# The empty-route half said on its own, so a table that lost a hint fails here
# even if the row still renders: an empty hint matches every line ever printed,
# which is how a vacuous scan looks from the inside (review A-2, A-5).
expect_eq "DS.2a …and no row in the whole table carries an empty hint" "" \
  "$(while IFS='|' read -r ds_r; do
       [ -n "$ds_r" ] || continue
       [ -n "$(ds_field "$ds_r" 6)" ] || printf '%s ' "$(ds_field "$ds_r" 1)"
     done <<<"$DS_TABLE")"
# THE ENVIRONMENT ROW'S SECOND FIRING STATE, named (review B-1). The fixture
# writes one key wrong and leaves two absent, so this row is asserted in the
# state that used to render ✓ with no cure.
expect_contains "DS.2a the fixture really does carry an environment name written to the wrong value" \
  "env:BASH_MAX_TIMEOUT_MS" "$DS_FIRED"
expect_contains "DS.2a …and doctor's page says so rather than ticking it" \
  "not the value bionic sets" "$(ds_page_line_for "$DS_REPORT" "BASH_MAX_TIMEOUT_MS")"

# ── DS.2 THE SECOND WAY: everything doctor renders is in the table ───────────
#
# Every hinted row in either machine-state table must resolve to a row of the
# check table, and — where that row is setup's — the item it names must be on the
# roster and must fire on the same machine doctor just read. A row that reaches
# here without a table row is the defect arriving tomorrow: a hint added on
# doctor's side with nothing behind it.
DS_UNMAPPED="$(ds_unmapped "$DS_REPORT" "$DS_TABLE" "$DS_ROUTES")"
DS_UNLISTED=""; DS_UNPENDING=""; DS_MISPARTY=""; DS_SEEN=0
while IFS= read -r ds_line; do
  [ -n "$ds_line" ] || continue
  DS_SEEN=$((DS_SEEN + 1))
  ds_label="$(ds_label_of "$ds_line")"
  ds_row="$(ds_row_for "$ds_label" "$DS_TABLE")" || continue
  ds_party="$(ds_field "$ds_row" 4)"
  ds_item="$(ds_field "$ds_row" 5)"
  ds_hint="$(ds_field "$ds_row" 6)"
  case "$ds_line" in
    *"$ds_hint"*) ;;
    *) DS_MISPARTY="${DS_MISPARTY}${DS_MISPARTY:+, }${ds_label} renders a route its row does not name" ;;
  esac
  if [ "$ds_party" = "setup" ]; then
    [ -n "$ds_item" ] \
      || DS_MISPARTY="${DS_MISPARTY}${DS_MISPARTY:+, }${ds_label} is setup's with no item"
    ds_listed_in "$DS_LIST" "$ds_item" \
      || DS_UNLISTED="${DS_UNLISTED}${DS_UNLISTED:+, }${ds_label} → ${ds_item}"
    ds_pending "$DS_HOME" "$ds_item" \
      || DS_UNPENDING="${DS_UNPENDING}${DS_UNPENDING:+, }${ds_label} → ${ds_item}"
  else
    [ -z "$ds_item" ] \
      || DS_MISPARTY="${DS_MISPARTY}${DS_MISPARTY:+, }${ds_label} is ${ds_party}'s and still names item ${ds_item}"
    case "$ds_line" in
      *"/bionic:setup"*) DS_MISPARTY="${DS_MISPARTY}${DS_MISPARTY:+, }${ds_label} is ${ds_party}'s and sends the reader to setup" ;;
    esac
  fi
done <<<"$DS_HINTED"

# The anti-vacuity control: an extractor that returned nothing would pass every
# row below without asking either script anything.
expect_true "DS.2 the scan found hinted rows to check (the rows under it are not vacuous)" \
  test "$DS_SEEN" -ge 8
expect_eq "DS.2 every hinted row doctor renders is a row of the check table" "" "$DS_UNMAPPED"
expect_eq "DS.2 …and every setup-party row's item is on setup's --list" "" "$DS_UNLISTED"
expect_eq "DS.2 …and every one of those items fires on the machine doctor read" "" "$DS_UNPENDING"
expect_eq "DS.2 …and every row states the party its table row names" "" "$DS_MISPARTY"

# ── DS.2b THE THIRD WAY: setup's roster IS the table's item column ───────────
#
# Set against set, not count against count. A roster that gained an item the table
# has never heard of is a repair nothing diagnoses; a table item missing from the
# roster is a hint pointing at a name setup would refuse.
DS_TABLE_ITEMS="$(while IFS= read -r ds_r; do [ -n "$ds_r" ] && ds_field "$ds_r" 5 && echo; done <<<"$DS_TABLE" | grep -v '^$' | sort -u)"
DS_LIST_ITEMS="$(printf '%s\n' "$DS_LIST" | grep -v '^$' | sort -u)"
expect_true "DS.2b setup's --list is not empty (the two rows under it are not vacuous)" \
  test "$(printf '%s\n' "$DS_LIST_ITEMS" | grep -c .)" -ge 10
expect_eq "DS.2b every item on setup's --list is an item the check table names" \
  "" "$(comm -23 <(printf '%s\n' "$DS_LIST_ITEMS") <(printf '%s\n' "$DS_TABLE_ITEMS") | tr '\n' ' ' | sed 's/ *$//')"
expect_eq "DS.2b …and every item the check table names is on setup's --list" \
  "" "$(comm -13 <(printf '%s\n' "$DS_LIST_ITEMS") <(printf '%s\n' "$DS_TABLE_ITEMS") | tr '\n' ' ' | sed 's/ *$//')"

# ── DS.2c THE FOURTH WAY: the same state, both sides ─────────────────────────
#
# The two parties agree about the ROSTER above; this is whether they agree about
# THIS MACHINE. Every item setup would offer, whose rows doctor renders a label
# for, must be flagged by doctor on the same fixture — that is the field defect in
# its pure form, and it is asked at the ITEM level because several rows can share
# one item (the three environment names are one step).
DS_CLEAN_EARLY="$DS_DIR/clean-early"
ds_plant "$DS_CLEAN_EARLY" no no
DS_PENDING_ITEMS="$(ds_pending_items "$DS_HOME")"

# THE WALK ITSELF, NAMED — because DS.12 below runs the very same comparison over
# a doctored doctor and has to come out non-empty. Every item setup would offer,
# whose table rows carry a label, must have one of those labels on the hinted
# lines of doctor's page; what comes back is the items that went unsaid, and the
# count of items the walk actually reached is left in `DS_STATE_SEEN` so a caller
# can prove it was not vacuous.
# THE COUNT COMES BACK WITH THE ANSWER, on one line, because a command
# substitution is a subshell and a global set inside one never reaches the
# caller — which is how the first draft of this helper turned the non-vacuity
# guard below into an unbound-variable error. No id and no label carries a `|`;
# the table's own record separator is that character, so one could not.
ds_silent_items() {  # <pending items> <page labels> <table> -> "<items reached>|<items doctor never said>"
  local pending="$1" labels="$2" table="$3" silent="" item labs hit r seen=0
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    labs="$(while IFS= read -r r; do
        [ -n "$r" ] || continue
        [ "$(ds_field "$r" 5)" = "$item" ] || continue
        ds_field "$r" 2 && echo
      done <<<"$table" | grep -v '^$')"
    [ -n "$labs" ] || continue
    ds_listed_in "$pending" "$item" || continue
    seen=$((seen + 1))
    hit=""
    while IFS= read -r ds_l; do
      [ -n "$ds_l" ] || continue
      case "$labels" in *"$ds_l"*) hit=1; break ;; esac
    done <<<"$labs"
    [ -n "$hit" ] || silent="${silent}${silent:+, }${item} (${labs//$'\n'/, })"
  done <<<"$(while IFS= read -r r; do [ -n "$r" ] && ds_field "$r" 5 && echo; done <<<"$table" | grep -v '^$' | sort -u)"
  printf '%s|%s' "$seen" "$silent"
}

DS_2C="$(ds_silent_items "$DS_PENDING_ITEMS" "$DS_LABELS" "$DS_TABLE")"
DS_STATE_SEEN="${DS_2C%%|*}"; DS_SILENT="${DS_2C#*|}"

expect_true "DS.2c the fixture leaves setup work to do on labelled rows (the row under it is not vacuous)" \
  test "$DS_STATE_SEEN" -ge 4
# THE CHEAP ORACLE, BOUND TO THE EXPENSIVE ONE. One item both ways: the one-process
# predicate says it fires, and a real `--only` run of setup on the same fixture
# agrees. Without this pair the walk above would be trusting a reading nothing had
# checked against the script it is a claim about.
expect_true "DS.2c the one-process predicate names an item setup's own narrowed run agrees on" \
  ds_listed_in "$DS_PENDING_ITEMS" legacy-hook-files
expect_true "DS.2c …and that run really does have something to do for it" \
  ds_pending "$DS_HOME" legacy-hook-files
# The other direction on the clean fixture, so the pair is a measurement: with no
# leftovers the same item is absent from the predicate's answer AND from setup's.
expect_false "DS.2c …while on a machine with no leftovers the predicate does not name it" \
  ds_listed_in "$(ds_pending_items "$DS_CLEAN_EARLY")" legacy-hook-files
expect_eq "DS.2c every item setup would offer is flagged by doctor on the same machine" "" "$DS_SILENT"

# ── DS.2d the core row: the party that is NOT setup, on a real absence ───────
DS_CORE_ROW="$(ds_section "$DS_REPORT" "THIRD PARTY" | grep -E '^  . +superpowers ' | head -1)"
expect_true "DS.2d doctor renders a THIRD PARTY row for the absent core dependency (the two below are not vacuous)" \
  test -n "$DS_CORE_ROW"
expect_contains "DS.2d …and the row names the route its table row carries, not setup's" \
  "$(ds_field "$(ds_row_for superpowers "$DS_TABLE")" 6)" "$DS_CORE_ROW"
expect_absent "DS.2d …and never /bionic:setup, which has no item that installs a core dependency" \
  "/bionic:setup" "$DS_CORE_ROW"
# The paired positive on the SAME fixture, so the row above is a measurement and not a
# constant: `agent-skills` is present in the planted registry and earns no hint at all.
DS_OK_ROW="$(ds_section "$DS_REPORT" "THIRD PARTY" | grep -E '^  . +agent-skills ' | head -1)"
expect_true "DS.2d …and that dependency has a row at all (the row below is not vacuous)" \
  test -n "$DS_OK_ROW"
expect_absent "DS.2d …while the core dependency the registry DOES carry earns no hint" \
  "→" "$DS_OK_ROW"

# ── DS.2e the two items that had no doctor surface at all before 1.5.1 ───────
#
# `legacy-permission-block` and `permission-mode` were on setup's roster and
# nowhere in doctor: the only mention of either in doctor.sh was a comment naming
# a mutation doctor must never call (step-0 map §B.4). A repair with no diagnosis
# is a half pair, and D-2 closes it — both are rows now, and both render.
expect_true "DS.2e the check table carries a labelled row for the retired permission block" \
  test -n "$(ds_field "$(ds_row_for 'legacy permission block' "$DS_TABLE")" 1)"
expect_true "DS.2e …and one for the default permission mode" \
  test -n "$(ds_field "$(ds_row_for 'default permission mode' "$DS_TABLE")" 1)"
DS_PM_RUN="$(ds_setup "$DS_HOME" --only permission-mode)"
expect_contains "DS.2e …and the narrowed run names the mode it would set" \
  "permission mode" "$DS_PM_RUN"
expect_absent "DS.2e …and setup does not call it an unknown name" \
  "there is nothing called permission-mode" "$DS_PM_RUN"

# ── DS.3 the restored pin: hook files as the ONLY leftover ───────────────────
# tests/doctor.test.sh Group 14 pinned this from the other side — a machine whose only
# leftover is hook files, whose setup run says "nothing to do" — and was deleted at 8582861
# with nothing to replace it (doctor.sh's own comment says so). This is that pin, put back on
# the side that can go red: the narrowed run must have something to do.
DS_HOOKS_ONLY="$DS_DIR/hooks-only"
ds_plant "$DS_HOOKS_ONLY" yes no
DS_HO_RUN="$(ds_setup "$DS_HOOKS_ONLY" --only legacy-hook-files)"
expect_absent "DS.3 legacy-hook-files is a name setup takes" \
  "there is nothing called" "$DS_HO_RUN"
expect_absent "DS.3 …and a hook-files-only machine does NOT read \"nothing to do\" from it" \
  "nothing left to do for legacy-hook-files." "$DS_HO_RUN"
expect_contains "DS.3 …the run names the directory it would clear" \
  ".claude/hooks" "$DS_HO_RUN"
# The other side of the same fixture: with the files gone the item has nothing to say, which
# is what makes the row above a measurement rather than a constant.
DS_CLEAN="$DS_DIR/clean"
ds_plant "$DS_CLEAN" no no
expect_contains "DS.3 …and on a machine with no leftovers it DOES read nothing to do" \
  "nothing left to do for legacy-hook-files." "$(ds_setup "$DS_CLEAN" --only legacy-hook-files)"

# ── DS.4 consented removal takes exactly what it named ───────────────────────
DS_RM="$DS_DIR/removal"
ds_plant "$DS_RM" yes yes
DS_RM_HOOKS="$(ds_setup_yes "$DS_RM" --only legacy-hook-files)"
DS_RM_AGENTS="$(ds_setup_yes "$DS_RM" --only legacy-agent-copies)"
ds_count() { local d="$1" pat="$2" n=0 f; for f in "$d"/$pat; do [ -e "$f" ] && n=$((n + 1)); done; printf '%s' "$n"; }

expect_eq "DS.4 the consented hook-files removal leaves the machine's own hook behind" \
  "1" "$(ds_count "$DS_RM/.claude/hooks" '*.sh')"
expect_true "DS.4 …and that survivor is the one the payload does not ship" \
  test -f "$DS_RM/.claude/hooks/not-bionics.sh"
expect_eq "DS.4 the consented agent-copies removal leaves the machine's own agent behind" \
  "1" "$(ds_count "$DS_RM/.claude/agents" '*.md')"
expect_true "DS.4 …and that survivor is the one the payload does not ship" \
  test -f "$DS_RM/.claude/agents/not-bionics.md"
expect_contains "DS.4 the hook-files step reports what it removed" "removed" "$DS_RM_HOOKS"
expect_contains "DS.4 the agent-copies step reports what it removed" "removed" "$DS_RM_AGENTS"

DS_AFTER="$(ds_doctor "$DS_RM")"
expect_absent "DS.4 …and doctor's hook-files row is gone afterwards" \
  "legacy hook files" "$(ds_section "$DS_AFTER" "ENVIRONMENT$")"
expect_absent "DS.4 …and so is the agent-copies row" \
  "legacy installed agent copies" "$(ds_section "$DS_AFTER" "ENVIRONMENT$")"

# ── DS.4b the walls name the party that can actually repair them ─────────────
#
# A wall missing from the payload is a broken install, not a setup item: setup's
# argv takes `--all`, `--only` and `--list` and there is no `repair` verb anywhere
# in it, so the line doctor printed until 1.5.1 — `run /bionic:setup — repair` —
# named a command that could not have worked. The row's party is the CLI now, and
# this is the state that proves it: a payload root with one wall hook absent.
DS_WALL_ROOT="$DS_DIR/wall-root"
rm -rf "$DS_WALL_ROOT"; mkdir -p "$DS_WALL_ROOT/hooks"
for ds_h in "$DS_PAYLOAD"/hooks/*.sh; do
  [ -f "$ds_h" ] || continue
  case "${ds_h##*/}" in protect-main.sh) continue ;; esac
  cp "$ds_h" "$DS_WALL_ROOT/hooks/"
done
DS_WALL_REPORT="$(HOME="$DS_HOME" BIONIC_CLAUDE_HOME="$DS_HOME/.claude" \
  BIONIC_PLUGIN_ROOT="$DS_WALL_ROOT" bash "$PARTY_DOCTOR" 2>/dev/null)"
expect_true "DS.4b the sparse payload root really is missing the wall (the rows under it are not vacuous)" \
  test ! -e "$DS_WALL_ROOT/hooks/protect-main.sh"
expect_contains "DS.4b doctor raises the missing wall" \
  "protect-main wall is missing from the payload" "$DS_WALL_REPORT"
expect_contains "DS.4b …and routes it to the party its table row names" \
  "$(ds_field "$(printf '%s\n' "$DS_TABLE" | grep '^wall-payload|')" 6)" "$DS_WALL_REPORT"
expect_absent "DS.4b …and never to setup's phantom repair verb" \
  "/bionic:setup — repair" "$DS_WALL_REPORT"

# ── DS.4c the wall row's DETECTOR answers what doctor's page just said ───────
#
# ONE VERDICT PER WALL (Step-6 review B-2). Until this fixit's fix-up batch,
# doctor's wall loop re-implemented "is the file readable" and "does the loader
# answer" beside the two detectors in checks.sh that ask the same two questions —
# and nothing ever invoked those detectors, so the copy the page ran and the copy
# the row named were free to drift with nothing going red. They share one
# implementation now (`bionic_check_wall_state`), and this is the arm that binds
# the sharing to an observation: the same sparse root doctor just reported on,
# asked of the row.
ds_wall_fires() {  # <payload root> <row id> -> yes | no
  HOME="$DS_HOME" BIONIC_CLAUDE_HOME="$DS_HOME/.claude" BIONIC_PLUGIN_ROOT="$1" \
    bash -c '. "$1" >/dev/null 2>&1 || exit 9
             bionic_check_fires "$2" && echo yes || echo no' _ "$DS_CHECKS_LIB" "$2" 2>/dev/null
}
ds_wall_state() {  # <payload root> <wall name> -> the row's own per-wall verdict
  HOME="$DS_HOME" BIONIC_CLAUDE_HOME="$DS_HOME/.claude" BIONIC_PLUGIN_ROOT="$1" \
    bash -c '. "$1" >/dev/null 2>&1 || exit 9
             bionic_check_wall_state "$2"' _ "$DS_CHECKS_LIB" "$2" 2>/dev/null
}
expect_eq "DS.4c the row's detector fires on the very root whose page raised the wall" \
  "yes" "$(ds_wall_fires "$DS_WALL_ROOT" wall-payload)"
expect_eq "DS.4c …and names that wall as the missing one" \
  "missing" "$(ds_wall_state "$DS_WALL_ROOT" protect-main)"
# PAIRED: the shipped payload root, where doctor's page reports 4/4 and the row
# is quiet — so the two rows above are a measurement and not a constant.
expect_eq "DS.4c …while on the shipped payload root the same detector is quiet" \
  "no" "$(ds_wall_fires "$DS_PAYLOAD" wall-payload)"
expect_eq "DS.4c …and that wall resolves its library there" \
  "ok" "$(ds_wall_state "$DS_PAYLOAD" protect-main)"
expect_contains "DS.4c …which is what doctor's page says about it too" \
  "walls" "$(ds_page_line_for "$DS_REPORT" "walls")"

# ── DS.5 mutation: a NEW hinted row with no table row goes red ───────────────
#
# The defect arriving tomorrow, planted. DS.2's completeness row is the one that
# must catch it, and this proves that row can fail: a label the table has never
# heard of resolves to nothing. Neither mutant below is ever the shipped file —
# both are copies under the sandbox, driven through the same `W1R_PARTY_*`
# override the four parties above use.
DS_MUT="$DS_DIR/mutant"
rm -rf "$DS_MUT"; mkdir -p "$DS_MUT"
cp -R "$DS_PAYLOAD/scripts" "$DS_MUT/scripts"
DS_INVENTED="legacy invented leftover"
expect_false "DS.5 a hinted row with no table entry resolves to no row" \
  ds_row_for "$DS_INVENTED" "$DS_TABLE"
# The paired positive: a label the table DOES carry resolves, on the same table.
expect_true "DS.5 …while a label the table carries does resolve (the row above is not vacuous)" \
  ds_row_for "legacy hook files" "$DS_TABLE"
DS_MUT_DOC="$DS_MUT/scripts/doctor.sh"
LC_ALL=C awk -v row="$DS_INVENTED" '
  $0 == "echo \"RESOURCES\"" {
    print "_doctor_env_row \"$DOCTOR_BAD\" \"" row "\" \"present\" \" \xe2\x86\x92 /bionic:setup\""
  }
  { print }' "$PARTY_DOCTOR" > "$DS_MUT_DOC"
expect_eq "DS.5 the doctored doctor differs from the shipped one by exactly the planted row" \
  "1" "$(diff "$PARTY_DOCTOR" "$DS_MUT_DOC" | grep -c '^> ')"
DS_MUT_REPORT="$( PARTY_DOCTOR="$DS_MUT_DOC"; ds_doctor "$DS_HOME" )"
expect_contains "DS.5 …and the completeness scan goes RED on it" \
  "$DS_INVENTED" "$(ds_unmapped "$DS_MUT_REPORT" "$DS_TABLE" "$DS_ROUTES")"
# And the same scan over the UNDOCTORED report is empty, which is what makes the
# row above a measurement rather than a constant.
expect_eq "DS.5 …while the shipped doctor leaves it empty" \
  "" "$(ds_unmapped "$DS_REPORT" "$DS_TABLE" "$DS_ROUTES")"

# ── DS.6 mutation: a renderer that spells the route itself goes red ─────────
#
# The regression this slice exists to prevent, planted. Not the 1.4.4 defect —
# THAT one is now unreachable by the edit that used to cause it: striking out the
# `core` branch of the absent arm leaves the row reading its hint from the table
# anyway, so it still names the CLI. What can still go wrong is a renderer that
# stops asking. This copy of doctor.sh replaces the one line that reads the
# dependency's row with a literal `/bionic:setup`, which is exactly how the file
# was written before 1.5.1, and the core row goes straight back to promising a
# repair setup has no item for. DS.2's party row must go red on it.
DS_MUT_CORE="$DS_MUT/scripts/doctor-literal.sh"
LC_ALL=C awk '
  /_doctor_dep_hint="\$\(bionic_check_dep_hint/ { print "  _doctor_dep_hint=\"/bionic:setup\""; next }
  { print }' "$PARTY_DOCTOR" > "$DS_MUT_CORE"
expect_eq "DS.6 the doctored doctor differs from the shipped one by exactly the one read" \
  "1" "$(diff "$PARTY_DOCTOR" "$DS_MUT_CORE" | grep -c '^< ')"
expect_eq "DS.6 …and by exactly the one literal that replaced it" \
  "1" "$(diff "$PARTY_DOCTOR" "$DS_MUT_CORE" | grep -c '^> ')"
DS_MUT_CORE_REPORT="$( PARTY_DOCTOR="$DS_MUT_CORE"; ds_doctor "$DS_HOME" )"
DS_MUT_CORE_ROW="$(ds_section "$DS_MUT_CORE_REPORT" "THIRD PARTY" | grep -E '^  . +superpowers ' | head -1)"
expect_true "DS.6 the doctored doctor still renders the core row (the rows below are not vacuous)" \
  test -n "$DS_MUT_CORE_ROW"
expect_contains "DS.6 …and it is back on the hint that has no item behind it" \
  "/bionic:setup" "$DS_MUT_CORE_ROW"
expect_absent "DS.6 …while the shipped doctor's same row never says that" \
  "/bionic:setup" "$DS_CORE_ROW"

# The party scan, run over the doctored report exactly as DS.2 runs it over the
# shipped one: a row whose table party is not setup, sending the reader to setup.
ds_misparty() {  # <doctor report> -> the rows that state a party their row does not name
  local line label row out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    label="$(ds_label_of "$line")"
    row="$(ds_row_for "$label" "$DS_TABLE")" || continue
    [ "$(ds_field "$row" 4)" = "setup" ] && continue
    case "$line" in *"/bionic:setup"*) out="${out}${out:+, }${label}" ;; esac
  done <<<"$(ds_hinted_lines "$1" "$DS_ROUTES")"
  printf '%s' "$out"
}
expect_contains "DS.6 …and the party scan goes RED on it" \
  "superpowers" "$(ds_misparty "$DS_MUT_CORE_REPORT")"
expect_eq "DS.6 …while the same scan over the shipped report is empty" \
  "" "$(ds_misparty "$DS_REPORT")"

# ── DS.7 mutation: a row deleted from the TABLE goes red on both renders ─────
#
# The direction neither old arm could reach, because until 1.5.1 there was no
# table to delete from. This is the proof that both renderers actually read it: a
# copy of lib/checks.sh with exactly one row struck out must take the item off
# setup's roster AND take the hint off doctor's row, from one edit, with neither
# script touched. If either render survived the deletion unchanged, that renderer
# is still carrying its own copy of the check — which is the whole defect.
# ITS OWN TREE, so the doctored library cannot reach the arm below it: DS.8 drives
# a setup copy out of $DS_MUT, and a setup reading a library with a row missing
# would make DS.8's set comparison about two edits instead of one.
DS_MUT7="$DS_DIR/mutant-lib"
rm -rf "$DS_MUT7"; mkdir -p "$DS_MUT7"
cp -R "$DS_PAYLOAD/scripts" "$DS_MUT7/scripts"
DS_MUT_CHECKS="$DS_MUT7/scripts/lib/checks.sh"
LC_ALL=C sed '/^  _bionic_checks_emit "legacy-hook-files" /d' "$DS_CHECKS_LIB" > "$DS_MUT_CHECKS"
expect_eq "DS.7 the doctored library differs from the shipped one by exactly the row" \
  "1" "$(diff "$DS_CHECKS_LIB" "$DS_MUT_CHECKS" | grep -c '^< ')"
expect_eq "DS.7 …and by nothing added" \
  "0" "$(diff "$DS_CHECKS_LIB" "$DS_MUT_CHECKS" | grep -c '^> ')"

# The table the doctored library builds no longer knows the row.
DS_MUT_TABLE="$( DS_CHECKS_LIB="$DS_MUT_CHECKS"; ds_rows "$DS_HOME" )"
expect_true "DS.7 the doctored table still builds (the rows below are not vacuous)" \
  test "$(printf '%s\n' "$DS_MUT_TABLE" | grep -c '|')" -ge 20
expect_false "DS.7 …and no longer carries the deleted row" \
  ds_row_for "legacy hook files" "$DS_MUT_TABLE"
expect_true "DS.7 …while the shipped table does" \
  ds_row_for "legacy hook files" "$DS_TABLE"

# THE SETUP SIDE. `setup.sh` sources the library beside it, so the copy under the
# sandbox reads the doctored one and its roster loses the item.
DS_MUT_LISTED=no
( PARTY_SETUP="$DS_MUT7/scripts/setup.sh"; ds_listed "$DS_HOME" legacy-hook-files ) && DS_MUT_LISTED=yes
expect_eq "DS.7 the doctored roster no longer carries the item" "no" "$DS_MUT_LISTED"
expect_true "DS.7 …while the shipped roster does (the row above is a measurement)" \
  ds_listed_in "$DS_LIST" legacy-hook-files

# THE DOCTOR SIDE, from the same one edit. Doctor reads the row's label and its
# hint from the table, so with the row gone the machine's leftover hook files stop
# being reported as anything a reader can act on.
DS_MUT_DOC7="$DS_MUT7/scripts/doctor.sh"
cp "$PARTY_DOCTOR" "$DS_MUT_DOC7"
DS_MUT_REPORT7="$( PARTY_DOCTOR="$DS_MUT_DOC7"; ds_doctor "$DS_HOME" )"
DS_MUT_LABELS7="$(while IFS= read -r ds_l; do [ -n "$ds_l" ] && ds_label_of "$ds_l" && echo; done \
  <<<"$(ds_hinted_lines "$DS_MUT_REPORT7" "$DS_ROUTES")")"
expect_true "DS.7 the doctored doctor still renders hinted rows (the row below is not vacuous)" \
  test "$(printf '%s\n' "$DS_MUT_LABELS7" | grep -c .)" -ge 5
expect_absent "DS.7 …but the deleted row's hint is gone from doctor's render too" \
  "legacy hook files" "$DS_MUT_LABELS7"
expect_contains "DS.7 …while the shipped doctor still carries it, from the same fixture" \
  "legacy hook files" "$DS_LABELS"

# ── DS.8 mutation: an item setup names on its own goes red ──────────────────
#
# The other side of DS.7. A roster line added by hand — the way the roster used to
# be written, before it was the table's item column — is a name /bionic:setup would
# take with nothing in the table to say what it repairs or who repairs it. DS.2b's
# set-against-set row is the one that must catch it.
DS_MUT_SETUP8="$DS_MUT/scripts/setup-invented.sh"
LC_ALL=C awk '
  /^_setup_item_ids\(\) \{$/ { print; print "  say \"invented-item\""; next }
  { print }' "$PARTY_SETUP" > "$DS_MUT_SETUP8"
expect_eq "DS.8 the doctored setup differs from the shipped one by exactly the planted item" \
  "1" "$(diff "$PARTY_SETUP" "$DS_MUT_SETUP8" | grep -c '^> ')"
expect_eq "DS.8 …and by nothing removed" \
  "0" "$(diff "$PARTY_SETUP" "$DS_MUT_SETUP8" | grep -c '^< ')"
DS_MUT_LIST8="$( PARTY_SETUP="$DS_MUT_SETUP8"; ds_setup "$DS_HOME" --list )"
expect_contains "DS.8 the doctored roster carries the planted item (the row below is not vacuous)" \
  "invented-item" "$DS_MUT_LIST8"
DS_MUT_ITEMS8="$(printf '%s\n' "$DS_MUT_LIST8" | grep -v '^$' | sort -u)"
expect_eq "DS.8 …and the set-against-set scan goes RED on exactly that name" \
  "invented-item" \
  "$(comm -23 <(printf '%s\n' "$DS_MUT_ITEMS8") <(printf '%s\n' "$DS_TABLE_ITEMS") | tr '\n' ' ' | sed 's/ *$//')"
expect_eq "DS.8 …while the shipped roster leaves that scan empty" \
  "" "$(comm -23 <(printf '%s\n' "$DS_LIST_ITEMS") <(printf '%s\n' "$DS_TABLE_ITEMS") | tr '\n' ' ' | sed 's/ *$//')"

# ── DS.9 mutation: a row that loses its hint goes red rather than quiet ─────
#
# THE FALSE GREEN THIS LEG WAS BUILT FOR (Step-6 review A-2). Every route doctor
# prints is `$(bionic_check_hint <id>)`, and an id that does not resolve returns
# non-zero having printed nothing — a return value all twenty-odd call sites
# discard. The row still renders, as a ✗ with no cure, which is the reader-facing
# half of the field defect this whole fixit exists to end. The route-keyed scan
# could not see it: a line with no route is filtered out before any leg reads it,
# so removing a hint made the evidence quieter instead of redder. DS.2a starts
# from the table, so it fails on exactly this.
DS_MUT9="$DS_DIR/mutant-hint"
rm -rf "$DS_MUT9"; mkdir -p "$DS_MUT9"
cp -R "$DS_PAYLOAD/scripts" "$DS_MUT9/scripts"
DS_MUT_CHECKS9="$DS_MUT9/scripts/lib/checks.sh"
LC_ALL=C sed 's|^\(  _bionic_checks_emit "legacy-hook-files" .*\) "\$r_setup"$|\1 ""|' \
  "$DS_CHECKS_LIB" > "$DS_MUT_CHECKS9"
expect_eq "DS.9 the doctored library differs from the shipped one by exactly the one hint" \
  "1" "$(diff "$DS_CHECKS_LIB" "$DS_MUT_CHECKS9" | grep -c '^< ')"
DS_MUT_TABLE9="$( DS_CHECKS_LIB="$DS_MUT_CHECKS9"; ds_rows "$DS_HOME" )"
expect_eq "DS.9 …and the table it builds carries an empty hint for that row" "" \
  "$(ds_field "$(ds_row_for 'legacy hook files' "$DS_MUT_TABLE9")" 6)"
expect_true "DS.9 …while the shipped table's same row carries one (the row above is a measurement)" \
  test -n "$(ds_field "$(ds_row_for 'legacy hook files' "$DS_TABLE")" 6)"
# The doctored library is what doctor reads, so the row renders with no cure —
# and the fired-row walk goes red on it, naming the row.
DS_MUT_DOC9="$DS_MUT9/scripts/doctor.sh"
DS_MUT_REPORT9="$( PARTY_DOCTOR="$DS_MUT_DOC9"; ds_doctor "$DS_HOME" )"
DS_MUT_FIRED9="$( DS_CHECKS_LIB="$DS_MUT_CHECKS9"; ds_fired_rows "$DS_HOME" )"
expect_true "DS.9 the doctored doctor still renders that row (the rows below are not vacuous)" \
  test -n "$(ds_page_line_for "$DS_MUT_REPORT9" 'legacy hook files')"
expect_absent "DS.9 …with no cure on it at all" \
  "/bionic:setup" "$(ds_page_line_for "$DS_MUT_REPORT9" 'legacy hook files')"
expect_contains "DS.9 …and the fired-row walk goes RED on it" \
  "legacy-hook-files" "$(ds_unrendered "$DS_MUT_REPORT9" "$DS_MUT_FIRED9")"
expect_eq "DS.9 …while the same walk over the shipped pair is empty" \
  "" "$(ds_unrendered "$DS_REPORT" "$DS_FIRED")"

# ── DS.10 mutation: a labelled row with no doctor call site goes red ────────
#
# THE ASYMMETRY A NEWCOMER WOULD GET WRONG (Step-6 review C-1), planted. Setup's
# roster is DERIVED from the rows — add a row with an item and `--list` carries
# it — while doctor's rows each have a call site written by hand, so a labelled
# row added to the table renders in setup and nowhere in doctor. This plants
# exactly that: one more row, labelled, party `user` (so it can never reach the
# item-keyed legs at all), sharing a detector that fires on this fixture, and
# with no call site anywhere in doctor.sh.
DS_MUT10="$DS_DIR/mutant-row"
rm -rf "$DS_MUT10"; mkdir -p "$DS_MUT10"
cp -R "$DS_PAYLOAD/scripts" "$DS_MUT10/scripts"
DS_MUT_CHECKS10="$DS_MUT10/scripts/lib/checks.sh"
LC_ALL=C awk '
  /^  _bionic_checks_emit "statusline-npx" / {
    print "  _bionic_checks_emit \"probe-unrendered\" \"planted probe row\" \"bionic_check_legacy_hook_files\" \"user\" \"\" \"clear it by hand\""
  }
  { print }' "$DS_CHECKS_LIB" > "$DS_MUT_CHECKS10"
expect_eq "DS.10 the doctored library differs from the shipped one by exactly the planted row" \
  "1" "$(diff "$DS_CHECKS_LIB" "$DS_MUT_CHECKS10" | grep -c '^> ')"
expect_eq "DS.10 …and by nothing removed" \
  "0" "$(diff "$DS_CHECKS_LIB" "$DS_MUT_CHECKS10" | grep -c '^< ')"
DS_MUT_FIRED10="$( DS_CHECKS_LIB="$DS_MUT_CHECKS10"; ds_fired_rows "$DS_HOME" )"
expect_contains "DS.10 the planted row fires on this fixture (the rows below are not vacuous)" \
  "probe-unrendered" "$DS_MUT_FIRED10"
DS_MUT_DOC10="$DS_MUT10/scripts/doctor.sh"
DS_MUT_REPORT10="$( PARTY_DOCTOR="$DS_MUT_DOC10"; ds_doctor "$DS_HOME" )"
expect_absent "DS.10 …and doctor renders it nowhere, because no call site names it" \
  "planted probe row" "$DS_MUT_REPORT10"
expect_contains "DS.10 …so the page-wide walk goes RED on it, by name" \
  "probe-unrendered" "$(ds_unrendered "$DS_MUT_REPORT10" "$DS_MUT_FIRED10")"
# PAIRED: the same doctored library's SETUP side is untouched, which is the
# asymmetry itself — a party `user` row adds no item, and a labelled row lands on
# doctor's page only if someone wrote the call site.
expect_absent "DS.10 …while the roster gains nothing from it" \
  "probe-unrendered" "$( PARTY_SETUP="$DS_MUT10/scripts/setup.sh"; ds_setup "$DS_HOME" --list )"

# ── DS.11 mutation: a renderer that keeps its OWN firing rule goes red ──────
#
# THE SECOND OWNER OF "DOES THIS CHECK FIRE", planted (Step-6 review B-1). Until
# the fix-up batch doctor's environment loop asked its own question — does
# `env_get` fail, i.e. is the name absent from settings.json — while the row's
# detector asks whether the configured value IS the value bionic sets. The two
# answers differ on exactly one machine, the one this fixture now plants: a name
# written to something else. There doctor printed ✓ with no cure while setup went
# on offering to rewrite it, which is the 2026-09-05 field defect inverted. This
# copy of doctor.sh puts that rule back, in one line, and the fired-row walk must
# go red on the name the fixture wrote wrong.
DS_MUT11="$DS_DIR/mutant-env"
rm -rf "$DS_MUT11"; mkdir -p "$DS_MUT11"
cp -R "$DS_PAYLOAD/scripts" "$DS_MUT11/scripts"
DS_MUT_DOC11="$DS_MUT11/scripts/doctor-own-env-rule.sh"
LC_ALL=C awk '
  /if bionic_check_fires "env:\$\{_env_key\}"; then _env_fires=yes; else _env_fires=no; fi/ {
    print "  if [ -z \"$_env_configured\" ]; then _env_fires=yes; else _env_fires=no; fi"; next }
  { print }' "$PARTY_DOCTOR" > "$DS_MUT_DOC11"
expect_eq "DS.11 the doctored doctor differs from the shipped one by exactly the one read" \
  "1" "$(diff "$PARTY_DOCTOR" "$DS_MUT_DOC11" | grep -c '^< ')"
expect_eq "DS.11 …and by exactly the one rule that replaced it" \
  "1" "$(diff "$PARTY_DOCTOR" "$DS_MUT_DOC11" | grep -c '^> ')"
DS_MUT_REPORT11="$( PARTY_DOCTOR="$DS_MUT_DOC11"; ds_doctor "$DS_HOME" )"
DS_MUT_ENV_ROW11="$(ds_page_line_for "$DS_MUT_REPORT11" "BASH_MAX_TIMEOUT_MS")"
expect_true "DS.11 the doctored doctor still renders the environment row (the rows below are not vacuous)" \
  test -n "$DS_MUT_ENV_ROW11"
expect_absent "DS.11 …and it is back to a tick with no cure on it" \
  "/bionic:setup" "$DS_MUT_ENV_ROW11"
expect_contains "DS.11 …while setup, reading the same machine, still offers the item" \
  "environment" "$DS_PENDING_ITEMS"
expect_contains "DS.11 …so the fired-row walk goes RED on that name" \
  "env:BASH_MAX_TIMEOUT_MS" "$(ds_unrendered "$DS_MUT_REPORT11" "$DS_FIRED")"
expect_eq "DS.11 …while the shipped doctor leaves the same walk empty" \
  "" "$(ds_unrendered "$DS_REPORT" "$DS_FIRED")"

# ── DS.12 mutation: the LEFTOVER rows have one owner too ────────────────────
#
# THE SAME SECOND OWNER, ON THE FIVE ROWS B-1 DID NOT COVER (Step-6 recheck part
# 4, ruling R-2). doctor decided `legacy-hook-files`, `legacy-agent-copies`,
# `legacy-alias`, `legacy-hooks` and `legacy-skill-copy` twice each — once for the
# fix line, once for the row — by re-applying the table's rule to the raw fact.
# Four of those five pairs agreed on every state a fixture can reach; the fifth
# did not, and that is what this arm plants.
#
# THE STATE. `bionic_check_legacy_alias` fires on the marked block OR on the bare
# pre-marker `alias claude=…--dangerously-skip-permissions` line. doctor's own
# test read `detect_zshrc_legacy_block`, which knows only the marker. A machine
# carrying the bare line is therefore one setup offers to clean and doctor said
# nothing about — the 2026-09-05 field defect in its own shape, on a different
# row. `ds_plant`'s fourth argument writes exactly that machine and nothing else.
#
# WHY ITS OWN HOME. Adding an rc file to the shared fixture would change what
# `claude-proxy` answers there too (an rc that exists with no bionic block is a
# different state from no rc at all), so the drift is planted where it is the only
# thing that moved.
DS_ALIAS_HOME="$DS_DIR/alias-premarker"
ds_plant "$DS_ALIAS_HOME" no no yes
expect_true "DS.12 the fixture carries the pre-marker alias line (the rows below are not vacuous)" \
  grep -q 'alias claude=' "$DS_ALIAS_HOME/.zshrc"
expect_false "DS.12 …and no marked bionic block, which is what makes the two rules disagree" \
  grep -q 'bionic:start' "$DS_ALIAS_HOME/.zshrc"

DS_ALIAS_TABLE="$(ds_rows "$DS_ALIAS_HOME")"
DS_ALIAS_PENDING="$(ds_pending_items "$DS_ALIAS_HOME")"
# The row's rendered LABEL, read out of the table by id rather than spelled here —
# a literal would go stale the day the column's wording changes, which is the
# class of pin §DS exists to replace.
DS_ALIAS_LABEL="$(while IFS= read -r ds_r; do
    [ -n "$ds_r" ] || continue
    [ "$(ds_field "$ds_r" 1)" = "legacy-alias" ] || continue
    ds_field "$ds_r" 2
  done <<<"$DS_ALIAS_TABLE")"
expect_true "DS.12 the table names a label for the row under test" test -n "$DS_ALIAS_LABEL"
expect_true "DS.12 setup offers the removal on this machine" \
  ds_listed_in "$DS_ALIAS_PENDING" legacy-alias
expect_true "DS.12 …and setup's own narrowed run agrees it has something to do" \
  ds_pending "$DS_ALIAS_HOME" legacy-alias

ds_alias_labels() {  # <report> -> the labels on that page's hinted lines
  local rep="$1" routes hinted
  routes="$(while IFS= read -r r; do [ -n "$r" ] && ds_field "$r" 6 && echo; done <<<"$DS_ALIAS_TABLE" | sort -u | grep -v '^$')"
  hinted="$(ds_hinted_lines "$rep" "$routes")"
  while IFS= read -r l; do [ -n "$l" ] && ds_label_of "$l" && echo; done <<<"$hinted"
}

DS_ALIAS_REPORT="$(ds_doctor "$DS_ALIAS_HOME")"
DS_ALIAS_LABELS="$(ds_alias_labels "$DS_ALIAS_REPORT")"
expect_contains "DS.12 the shipped doctor renders the row, because it asks the table" \
  "$DS_ALIAS_LABEL" "$DS_ALIAS_LABELS"
DS_ALIAS_2C="$(ds_silent_items "$DS_ALIAS_PENDING" "$DS_ALIAS_LABELS" "$DS_ALIAS_TABLE")"
expect_true "DS.12 …and the same-state walk reaches this machine's items at all" \
  test "${DS_ALIAS_2C%%|*}" -ge 2
expect_absent "DS.12 …so DS.2c's walk says nothing about it on the shipped doctor" \
  "legacy-alias" "${DS_ALIAS_2C#*|}"

# THE MUTANT: one line, doctor's own pre-1.5.1 rule put back where the table's
# answer now goes. Everything else on the page is the shipped renderer.
DS_MUT12="$DS_DIR/mutant-alias"
rm -rf "$DS_MUT12"; mkdir -p "$DS_MUT12"
cp -R "$DS_PAYLOAD/scripts" "$DS_MUT12/scripts"
DS_MUT_DOC12="$DS_MUT12/scripts/doctor-own-alias-rule.sh"
LC_ALL=C awk -v repl='LEGACY_ALIAS_FIRES=no; case "$(detect_zshrc_legacy_block)" in *present=yes) LEGACY_ALIAS_FIRES=yes ;; esac' '
  /^LEGACY_ALIAS_FIRES=no; bionic_check_fires legacy-alias/ { print repl; next }
  { print }' "$PARTY_DOCTOR" > "$DS_MUT_DOC12"
expect_eq "DS.12 the doctored doctor differs from the shipped one by exactly the one read" \
  "1" "$(diff "$PARTY_DOCTOR" "$DS_MUT_DOC12" | grep -c '^< ')"
expect_eq "DS.12 …and by exactly the one rule that replaced it" \
  "1" "$(diff "$PARTY_DOCTOR" "$DS_MUT_DOC12" | grep -c '^> ')"

DS_MUT_REPORT12="$( PARTY_DOCTOR="$DS_MUT_DOC12"; ds_doctor "$DS_ALIAS_HOME" )"
expect_contains "DS.12 the doctored doctor still renders a page (the rows below are not vacuous)" \
  "ENVIRONMENT" "$DS_MUT_REPORT12"
expect_absent "DS.12 …and its own rule cannot see the pre-marker line, so the row is gone" \
  "$DS_ALIAS_LABEL" "$DS_MUT_REPORT12"
expect_contains "DS.12 …so DS.2c's walk goes RED on it, by item name" \
  "legacy-alias" "$(DS_M="$(ds_silent_items "$DS_ALIAS_PENDING" "$(ds_alias_labels "$DS_MUT_REPORT12")" "$DS_ALIAS_TABLE")"; printf '%s' "${DS_M#*|}")"


# ============================================================
section "CG — the current: GRAMMAR: sched_plan_current agrees with run.sh's run_open step-read (epic-21 T6)"
# ============================================================
#
# TWO READERS OF ONE FIELD, deliberately duplicated rather than shared (hooks/session-poker.sh
# names the reason at sched_plan_current's definition: folding the FILL gate's read into
# run_state would couple the DISARM decision to the FILL decision). Duplication without an
# agreement test is exactly the shape review-b's finding (c) describes: `run_state` (this
# file's RUN_LIB, function `run_open`) strips a trailing a/b sub-step letter before reading
# digits; `sched_plan_current` used to reject that same letter outright, so `current: 3b`
# read as UNREADABLE to the gate and fell through to a FILL — the bug T6 fixes. This section
# is the smaller of T6's two remediation choices (share one function vs. bind the two readers
# with a test): the callers answer genuinely different questions off genuinely different
# inputs (a session's roster vs. a plan path alone), so a shared function would be an
# awkward abstraction over two unrelated call shapes. An agreement test is the fit.
#
# Both parties are called FOR REAL, not compared as text — sched_plan_current's own body
# calls _sched_plan_current_field and normalize_newlines, so all three are extracted and
# eval'd together (§I.1's precedent, `q_poker` above); run_open is sourced from RUN_LIB
# exactly as §PC below sources it.
cg_extract_fn() {  # <fn-name> -> that function's body text, from session-poker.sh (PARTY_PK)
  awk -v n="$1" '$0 ~ "^" n "\\(\\)" {f=1} f{print; if ($0=="}") exit}' "$PARTY_PK"
}
cg_sched_current() {  # <plan path> -> sched_plan_current's real answer, called for real
  ( eval "$(cg_extract_fn normalize_newlines)"
    eval "$(cg_extract_fn _sched_plan_current_field)"
    eval "$(cg_extract_fn sched_plan_current)"
    sched_plan_current "$1" ) 2>/dev/null
}
cg_run_open() {  # <plan path> -> "0" (open) or "1" (not a recognized open state), run_open
                 # called for real off RUN_LIB
  ( . "$RUN_LIB" >/dev/null 2>&1; run_open "$1" ) >/dev/null 2>&1
  printf '%s' "$?"
}
cg_plan() {  # <current: value, or "" for none> -> a fixture plan path carrying it
  local cur="$1"
  local safe; safe="$(printf '%s' "${cur:-none}" | tr -c 'A-Za-z0-9' '_')"
  local f="$SANDBOX/fx/cg/current-${safe}.plan.md"
  mkdir -p "$(dirname "$f")"
  {
    printf '# cg fixture plan\n\n## SDLC State\n\n'
    [ -n "$cur" ] && printf 'current: %s\n\n' "$cur"
    printf -- '- Step %s: in progress\n' "${cur:-0}"
  } > "$f"
  printf '%s' "$f"
}

# ── CG.1 the a/b sub-step letter: both readers strip it and land on the SAME numbered step ──
for CG_STEP in 3 4 8; do
  for CG_LETTER in '' a b; do
    CG_VAL="${CG_STEP}${CG_LETTER}"
    CG_PLAN="$(cg_plan "$CG_VAL")"
    expect_eq "CG.1 sched_plan_current(current: $CG_VAL) reads the step, letter stripped" \
      "$CG_STEP" "$(cg_sched_current "$CG_PLAN")"
    expect_eq "CG.1 …and run.sh's run_open agrees this is a live, in-range step" \
      "0" "$(cg_run_open "$CG_PLAN")"
  done
done

# ── CG.2 an unparseable current: is never mistaken for an active step by EITHER reader ──
for CG_BAD in "abc" "3 (Step-3 review)" "3c"; do
  CG_PLAN="$(cg_plan "$CG_BAD")"
  expect_eq "CG.2 sched_plan_current withholds on '$CG_BAD'" "" "$(cg_sched_current "$CG_PLAN")"
  expect_eq "CG.2 …and run.sh's run_open agrees this plan is not a recognized open state" \
    "1" "$(cg_run_open "$CG_PLAN")"
done
# no current: line at all — same non-agreement: both give up on the field, neither fills it in
CG_NOLINE="$SANDBOX/fx/cg/no-current.plan.md"
mkdir -p "$(dirname "$CG_NOLINE")"
printf '# cg fixture plan\n\n## SDLC State\n\n- Step 3: in progress\n' > "$CG_NOLINE"
expect_eq "CG.2 no current: line at all — sched_plan_current withholds" \
  "" "$(cg_sched_current "$CG_NOLINE")"
expect_eq "CG.2 …and run_open agrees (no current: field is not an open state)" \
  "1" "$(cg_run_open "$CG_NOLINE")"

# ── CG.3 the DOCUMENTED divergence: task-scale current: T<n> — pinned, not silent ──
# run_state's OTHER `current:` shape: `T<n>` is always an open run (no numbered close — the
# session/task-scale plans this repo also carries, including the plan governing this very
# slice). It has no numbered step to compare against 4, so the FILL gate cannot read "T1" as
# either approved or pending and withholds by design (T6 brief; review-a C-5; review-b N-2).
# This is pinned as a DIVERGENCE, not an agreement: the two readers answer a DIFFERENT
# question about the same value ON PURPOSE. A change that made them agree — teaching
# run_open to reject T<n>, or teaching the gate to treat any T<n> as approved — is exactly
# the kind of silent drift this section exists to catch, so it must turn this red.
for CG_T in T1 T5 T23; do
  CG_PLAN="$(cg_plan "$CG_T")"
  expect_eq "CG.3 sched_plan_current withholds on task-scale '$CG_T' (no numbered step)" \
    "" "$(cg_sched_current "$CG_PLAN")"
  expect_eq "CG.3 …while run.sh's run_open still calls a task-scale plan an OPEN run" \
    "0" "$(cg_run_open "$CG_PLAN")"
done

# ── CG.4 the discriminator: reverting the letter-strip splits the pair (proves CG.1 can go red) ──
# The pre-fix bug, planted. A copy of session-poker.sh with ONLY the a/b-strip line reverted
# to a bare assignment — the exact shape this section would have caught before T6.
CG_MUT="$SANDBOX/fx/cg/session-poker-nostrip.sh"
LC_ALL=C awk '{
  if ($0 == "  step=\"${current%[ab]}\"") { print "  step=\"$current\"" } else { print }
}' "$PARTY_PK" > "$CG_MUT"
expect_eq "CG.4 the mutant differs from the shipped file by exactly the strip line" \
  "1" "$(diff "$PARTY_PK" "$CG_MUT" | grep -c '^< ')"
cg_sched_current_mut() {  # <plan path> -> sched_plan_current's answer off the MUTANT copy
  ( eval "$(awk -v n=normalize_newlines \
      '$0 ~ "^" n "\\(\\)" {f=1} f{print; if ($0=="}") exit}' "$CG_MUT")"
    eval "$(awk -v n=_sched_plan_current_field \
      '$0 ~ "^" n "\\(\\)" {f=1} f{print; if ($0=="}") exit}' "$CG_MUT")"
    eval "$(awk -v n=sched_plan_current \
      '$0 ~ "^" n "\\(\\)" {f=1} f{print; if ($0=="}") exit}' "$CG_MUT")"
    sched_plan_current "$1" ) 2>/dev/null
}
CG_PLAN_3B="$(cg_plan 3b)"
expect_eq "CG.4 …the mutant copy rejects current: 3b as unreadable (the pre-fix bug)" \
  "" "$(cg_sched_current_mut "$CG_PLAN_3B")"
expect_eq "CG.4 …while the shipped file still reads it as step 3 — CG.1 discriminates" \
  "3" "$(cg_sched_current "$CG_PLAN_3B")"


# ============================================================
section "S15 — landing-swept/v1: one writer, pinned to a captured marker"
# ============================================================
#
# THE OWNERSHIP-TABLE ROW (spec AC-26; research-code-map §2.c): hooks/landing-gate.sh's
# originator, `swept_marker_write`, is pinned here against tests/fixtures/landing-swept.captured
# — a real marker taken from a live sweep on this machine
# (roster-84f06e58-9262-4c7f-a199-ca77c24a332e.state, name=research-code-map, MET).
# hooks/session-poker.sh's `adopt_copy_marker` never calls the writer (its job is to relay a
# line the originator already wrote, verbatim) — what it shares is the `SWEPT_SCHEMA`
# constant, so §S15b below pins the two hooks' copies of that constant to agree, byte for
# byte, rather than sourcing one file: two separate hook PROCESSES have no shared memory to
# source an in-process value from, the same reason payload/scripts/lib/loader.sh's own block
# is duplicated-but-pinned rather than sourced.
#
# EXTRACTED, NOT SOURCED FROM A LIB (see tests/lib/swept-marker.sh's own header for why: a
# hook copied out of the tree, as several sections above already do, resolves its
# BIONIC_LIB_WANT files through the loader's registry/cache fallback — whatever was last
# LANDED, not this worktree's uncommitted tree). The real source, `eval`'d, real call — the
# same `field1_via`/`field2_via` idiom this file already uses.
#
# BY KEY, NEVER BY POSITION. The captured line's five fields are read out with the same
# by-key idiom every production reader uses, so a reordering upstream cannot pass this pin
# by accident — only the shared writer producing the identical byte sequence can.

S15_LG="$PARTY_LG"
S15_PK="$PARTY_PK"
S15_CAPTURED="$REPO_ROOT/tests/fixtures/landing-swept.captured"
S15_LINE="$(cat "$S15_CAPTURED")"

s15_field() { printf '%s' "$1" | tr '|' '\n' | grep "^$2=" | head -1 | cut -d= -f2-; }
S15_AT="$(s15_field "$S15_LINE" at)"
S15_SID="$(s15_field "$S15_LINE" session)"
S15_NAME="$(s15_field "$S15_LINE" name)"
S15_AID="$(s15_field "$S15_LINE" agent_id)"
S15_STATE="$(s15_field "$S15_LINE" state)"

s15_write() {  # <hook file> <roster file> <at> <session> <name> <agent id> <state>
  ( eval "$(grep -m1 '^SWEPT_SCHEMA=' "$1")"
    eval "$(awk '/^swept_marker_write\(\)/,/^\}/' "$1")"
    swept_marker_write "$2" "$3" "$4" "$5" "$6" "$7" ) 2>/dev/null
}

S15_OUT="$SANDBOX/s15-roster.state"
s15_write "$S15_LG" "$S15_OUT" "$S15_AT" "$S15_SID" "$S15_NAME" "$S15_AID" "$S15_STATE"
expect_eq "S15 the shared writer reproduces the captured marker byte for byte" \
  "$S15_LINE" "$(cat "$S15_OUT" 2>/dev/null)"

# THE DISCRIMINATOR — one field doctored, and the pin must go red. A copy of the hook with
# `state=%s` in the writer's printf format replaced by the literal `state=MUTATED`, so every
# marker it writes carries the wrong state regardless of what it is called with — a
# plausible schema drift, not damage. The shipped hook is never touched.
S15_MUT="$SANDBOX/s15-landing-gate-mutant.sh"
anchor "$S15_LG" 'state=%s' 1
awk '{ gsub(/state=%s/, "state=MUTATED"); print }' "$S15_LG" > "$S15_MUT"

S15_MUT_OUT="$SANDBOX/s15-roster-mutant.state"
s15_write "$S15_MUT" "$S15_MUT_OUT" "$S15_AT" "$S15_SID" "$S15_NAME" "$S15_AID" "$S15_STATE"
expect_eq "S15 …the mutant's output is NOT the captured shape (the pin discriminates)" \
  "no" "$([ "$(cat "$S15_MUT_OUT" 2>/dev/null)" = "$S15_LINE" ] && echo yes || echo no)"
expect_contains "S15 …the real state value nowhere survives the mutant — it is truly overwritten" \
  "state=MUTATED" "$(cat "$S15_MUT_OUT" 2>/dev/null)"

# ---- §S15b — the constant the two hooks share, pinned to agree ----
#
# hooks/session-poker.sh's `adopt_copy_marker` never calls the writer above; it shares only
# the schema NAME, each hook carrying its own `SWEPT_SCHEMA=` assignment line. A rename on
# one side and not the other is exactly the drift research-code-map §2.c warned a
# constant-by-NAME grep can miss — this pins the two LINES, not just the grep, to agree.
S15_LG_SCHEMA_LINE="$(grep -m1 '^SWEPT_SCHEMA=' "$S15_LG")"
S15_PK_SCHEMA_LINE="$(grep -m1 '^SWEPT_SCHEMA=' "$S15_PK")"
expect_eq "S15b hooks/landing-gate.sh declares the constant" \
  'SWEPT_SCHEMA="landing-swept/v1"' "$S15_LG_SCHEMA_LINE"
expect_eq "S15b …and hooks/session-poker.sh's copy agrees, byte for byte" \
  "$S15_LG_SCHEMA_LINE" "$S15_PK_SCHEMA_LINE"
expect_eq "S15b …the copy is a named constant, not a literal in adopt_copy_marker's own grep" \
  "0" "$(awk '/^adopt_copy_marker\(\)/,/^\}/' "$S15_PK" | grep -cF "grep '^${SWEPT_SCHEMA}|'")"

# ============================================================
section "S13 — the suite budget: one derivation, one row writer, one alphabet"
# ============================================================
#
# (wave-01 verification-cannot-lie, S13; spec AC-20/AC-21; design ledger D2.)
#
# THREE FILES HAVE TO AGREE ABOUT ONE SET, and none of them can see the other two:
#
#   tests/lib/impact.sh                 PRODUCES it, as `suite<TAB>reason` lines (S12)
#   hooks/dispatch-preflight.sh         RECORDS it, as `suites_allowed=` on the roster row
#   hooks/background-suite-guard.sh     ENFORCES it, against basenames read out of a command
#
# Each has its own suite, and each of those suites builds its own fixture — so all three
# can pass while the wall records a spelling the derivation never prints and the guard
# never matches. What is pinned here is the SEAM: the real derivation, driven over a real
# file, answering in the alphabet the guard compares in.

S13_IMPACT="$REPO_ROOT/tests/lib/impact.sh"
S13_DP="$BIONIC_HOOKS_DIR/dispatch-preflight.sh"
S13_BG="$BIONIC_HOOKS_DIR/background-suite-guard.sh"
S13_ROSTER_LIB="$BIONIC_HOOKS_DIR/../payload/scripts/lib/roster.sh"
[ -r "$S13_ROSTER_LIB" ] || S13_ROSTER_LIB="$BIONIC_HOOKS_DIR/../scripts/lib/roster.sh"
S13_CMDCLASS="$BIONIC_HOOKS_DIR/../payload/scripts/lib/cmd-class.sh"
[ -r "$S13_CMDCLASS" ] || S13_CMDCLASS="$BIONIC_HOOKS_DIR/../scripts/lib/cmd-class.sh"

# --- §S13.1 the derivation's output shape is the one the wall consumes ---
#
# Driven over a REAL file of this tree, so the answer is the derivation's own rather than a
# fixture's idea of it. `payload/scripts/lib/cmd-class.sh` is chosen because its own suite
# is on the answer by construction (`self`/`path-ref`), which gives the assertion below a
# value it can name without hardcoding the whole set.
S13_RAW=$(cd "$REPO_ROOT" && bash "$S13_IMPACT" payload/scripts/lib/cmd-class.sh 2>/dev/null)
expect_eq "S13.1 the derivation answers at all (non-vacuity)" "0" \
  "$([ -n "$S13_RAW" ] && echo 0 || echo 1)"
expect_eq "S13.1 every line is exactly two TAB-separated fields" "0" \
  "$(printf '%s\n' "$S13_RAW" | awk -F'\t' 'NF != 2 { n++ } END { print n + 0 }')"
expect_eq "S13.1 the first field is a suite BASENAME, never a path" "0" \
  "$(printf '%s\n' "$S13_RAW" | awk -F'\t' '$1 ~ /\// || $1 !~ /\.test\.sh$/ { n++ } END { print n + 0 }')"
expect_contains "S13.1 …and the suite that owns that file is in the answer" \
  "cmd-class.test.sh" "$(printf '%s\n' "$S13_RAW" | cut -f1 | tr '\n' ' ')"

# --- §S13.2 the wall's OWN reduction, lifted out of the hook and run here ---
#
# WHAT THIS USED TO BE, and why it changed (review-b B-6's sibling, B-3). The section was
# titled as an agreement and asserted nothing about the wall: it re-typed the reduction, ran
# it, and checked its own output for a colon, a tab and a duplicate. A self-check on this
# test's own pipeline reads as the agreement pin for the derived set, so a future reader
# weakening the real coverage would believe this still held the line.
#
# It is an agreement now. The two lines that build `suites_allowed=` are lifted OUT of
# payload/hooks/dispatch-preflight.sh by text and run here over the same raw output, so a
# change to the hook's spelling — a third column kept, a different sort, the trailing-space
# trim dropped — is red HERE. The end-to-end coverage (a real dispatch, a real row) is
# tests/dispatch-preflight.test.sh S27a and its mutation arm S27a2; this section is the
# alphabet check that sits under it.
S13_HOOK="$BIONIC_HOOKS_DIR/dispatch-preflight.sh"
expect_eq "S13.2 the hook this section reads is present" "yes" \
  "$([ -r "$S13_HOOK" ] && echo yes || echo no)"
# THE PRECONDITION OF THE LIFT (AC-29): the two lines are still there, exactly once each.
anchor -E "$S13_HOOK" '^[[:space:]]*SUITES_ALLOWED=\$\(printf' 1
anchor -E "$S13_HOOK" '^[[:space:]]*SUITES_ALLOWED="\$\{SUITES_ALLOWED% \}"' 1
S13_REDUCTION=$(awk '/^[[:space:]]*SUITES_ALLOWED=\$\(printf/,/^[[:space:]]*SUITES_ALLOWED="\$\{SUITES_ALLOWED% \}"/' "$S13_HOOK")
expect_eq "S13.2 the lift took exactly the two assignment lines" "2" \
  "$(printf '%s\n' "$S13_REDUCTION" | grep -c 'SUITES_ALLOWED=')"
expect_eq "S13.2 …and nothing else came with them" "0" \
  "$(printf '%s\n' "$S13_REDUCTION" | grep -vc 'SUITES_ALLOWED=')"

# The hook's own reduction, over the derivation's own output.
S13_HOOK_SET=$(_impact_out="$S13_RAW"; eval "$S13_REDUCTION"; printf '%s' "$SUITES_ALLOWED")
# This test's reading of the same rule, spelled independently.
S13_SET=$(printf '%s\n' "$S13_RAW" | cut -f1 | sort -u | tr '\n' ' ')
S13_SET="${S13_SET% }"

expect_nonempty "S13.2 the hook's reduction answered something (non-vacuity)" "$S13_HOOK_SET"
expect_eq "S13.2 the wall's own reduction and this test's agree, to the byte" \
  "$S13_SET" "$S13_HOOK_SET"
# THE MUTATION: doctor the raw output the way a derivation that grew a column would, and the
# two sides must part. Without this the row above could be two spellings of `true`.
S13_RAW_MUT="$(printf '%s\n' "$S13_RAW" | sed 's/^/x-/')"
S13_HOOK_SET_MUT=$(_impact_out="$S13_RAW_MUT"; eval "$S13_REDUCTION"; printf '%s' "$SUITES_ALLOWED")
expect_ne "S13.2 …and the comparison discriminates on a doctored raw output" \
  "$S13_SET" "$S13_HOOK_SET_MUT"

expect_eq "S13.2 the reduced set carries no reason column" "0" \
  "$(printf '%s' "$S13_HOOK_SET" | grep -c ':')"
expect_eq "S13.2 …and no tab survived the reduction" "0" \
  "$(printf '%s' "$S13_HOOK_SET" | tr -cd '\t' | wc -c | tr -d ' ')"
expect_eq "S13.2 …and holds no duplicate" "0" \
  "$(printf '%s\n' "$S13_HOOK_SET" | tr ' ' '\n' | sort | uniq -d | grep -c .)"

# --- §S13.3 the guard compares in that same alphabet ---
#
# `cmd_suite_targets` is the reader on the enforcement side. Every basename the derivation
# just produced must be a name it can produce too, from the command a writer would type —
# otherwise a suite on the budget is refused by the wall that granted it.
S13_TARGETS_OK=0
for _s13_b in $S13_SET; do
  _s13_got=$(bash -c '
    set -uo pipefail
    . "$1" || exit 1
    cmd_suite_targets "bash tests/$2"
  ' _ "$S13_CMDCLASS" "$_s13_b" 2>/dev/null)
  [ "$_s13_got" = "$_s13_b" ] || S13_TARGETS_OK=$((S13_TARGETS_OK + 1))
done
expect_eq "S13.3 every derived basename round-trips through cmd_suite_targets" "0" "$S13_TARGETS_OK"
# NON-VACUITY: the loop really ran over a non-empty set.
expect_eq "S13.3 …over a set with something in it" "0" \
  "$([ -n "$S13_SET" ] && echo 0 || echo 1)"

# --- §S13.4 the three fields go through the ONE row writer, from both call sites ---
#
# §RA.2 pins that the row has one writer. This pins that the fields S13 added did not
# quietly acquire a second one: neither hook may hold a `suites_allowed=` literal of its
# own, and the library must know all three keys. A hook that built the field into a
# format string beside the call would pass §RA.2 (the captured rows carry none of the
# three) and be invisible until a reader met a row with the key in the wrong place.
for _s13_key in files suites_allowed suites_source; do
  expect_eq "S13.4 roster.sh knows the key [$_s13_key]" "1" \
    "$(awk '/^roster_row\(\)/,/^\}/' "$S13_ROSTER_LIB" | grep -cE "^ *${_s13_key}\)")"
done
# THE ROW-BUILDING SPELLING IS `|suites_allowed=` — a pipe in front of the key is a
# format string assembling the row, and it may exist in exactly one file.
expect_eq "S13.4 dispatch-preflight assembles no row segment of its own" "0" \
  "$(grep -c '|suites_allowed=' "$S13_DP")"
expect_eq "S13.4 …and neither does session-poker's adopt" "0" \
  "$(grep -c '|suites_allowed=' "$BIONIC_HOOKS_DIR/session-poker.sh")"
expect_eq "S13.4 …because the one library that may is the one that does" "1" \
  "$(grep -c '|suites_allowed=' "$S13_ROSTER_LIB")"
# The paired POSITIVE: both writers do pass the key by name, so the two zeros above are
# "no second speller" and not "nobody writes it".
expect_eq "S13.4 dispatch-preflight passes suites_allowed= to the writer" "1" \
  "$(grep -c '"suites_allowed=\${SUITES_ALLOWED}"' "$S13_DP")"
expect_eq "S13.4 …and session-poker builds its three as one group" "1" \
  "$(grep -c 'suites_allowed=\$(clean "\$sallow")' "$BIONIC_HOOKS_DIR/session-poker.sh")"

# --- §S13.5 the field the wall writes is the field the guard reads ---
#
# One key name, two files, neither able to see the other. A rename on either side is the
# whole failure mode, and it is silent: the guard would find no budget and stand aside for
# every named suite in the fleet.
expect_eq "S13.5 the guard reads the key the wall writes" "0" \
  "$(grep -qF 'suites_allowed=' "$S13_BG" && echo 0 || echo 1)"
S13_BG_OFFSET=$(grep -oE 'substr\(\$i, 16\)' "$S13_BG" | head -1)
expect_eq "S13.5 …substr past 'suites_allowed=' is 16, the character after the equals" \
  "substr(\$i, 16)" "$S13_BG_OFFSET"
expect_eq "S13.5 …which is what awk needs for a key of this length" \
  "16" "$(( $(printf '%s' 'suites_allowed=' | wc -c | tr -d ' ') + 1 ))"

# ============================================================
# --- S18 — landing-gate.sh reconciles the diff against Files:, once (spec AC-22) ---
#
# THE OWNERSHIP-TABLE ROW THIS SLICE ADDS. "Impact of a change" (the spec's ## Design
# ownership table) already has one owner — `tests/lib/impact.sh` — rendered at three
# surfaces: `suites_allowed=` on the roster row, the brief's `Files:`, and now the landing
# verdict. This section pins that third rendering the way §S13.4/§S13.5 pin the first two:
# ONE reader of a row's `files=` for reconciliation, ONE place that computes the diff, ONE
# row -> worktree mapping (never re-derived), and ONE re-ask of the SAME `impact-command`
# key S13's dispatch wall already reads — never a second config key or a second derivation.
S18_LG="$BIONIC_HOOKS_DIR/landing-gate.sh"
S18_WT_LIB_DIR="$BIONIC_HOOKS_DIR/../payload/scripts/lib"

# --- §S18.1 exactly one hook computes a Files: diff, and it is landing-gate.sh ---
expect_eq "S18.1 exactly one hook diffs a worktree by name-only" "1" \
  "$(grep -lF -- '--name-only' "$BIONIC_HOOKS_DIR"/*.sh | wc -l | tr -d ' ')"
expect_eq "S18.1 …and it is landing-gate.sh" "1" \
  "$(grep -lF -- '--name-only' "$BIONIC_HOOKS_DIR"/*.sh | grep -c 'landing-gate\.sh$')"

# --- §S18.2 the row -> worktree mapping has ONE definition (worktree.sh's `worktree_for_row`,
# payload/scripts/lib/worktree.sh's own docblock: "a second spelling of it there is a second
# definition of which tree belongs to whom") and landing-gate.sh calls it rather than
# re-deriving the mapping itself ---
expect_eq "S18.2 worktree_for_row is defined in exactly one library file" "1" \
  "$(grep -l '^worktree_for_row()' "$S18_WT_LIB_DIR"/*.sh | wc -l | tr -d ' ')"
expect_eq "S18.2 …and it is worktree.sh" "1" \
  "$(grep -l '^worktree_for_row()' "$S18_WT_LIB_DIR"/*.sh | grep -c 'worktree\.sh$')"
expect_eq "S18.2 landing-gate.sh calls the shared mapping" "1" \
  "$(grep -cF 'worktree_for_row "$repo" "$name"' "$S18_LG")"
expect_eq "S18.2 …and never redefines it" "0" \
  "$(grep -c '^worktree_for_row()' "$S18_LG")"
expect_eq "S18.2 …declaring the dependency, per the loader contract" "1" \
  "$(grep -cF 'BIONIC_LIB_WANT="root.sh run.sh session.sh worktree.sh"' "$S18_LG")"

# --- §S18.3 the reconciliation re-asks the SAME impact-command key S13's dispatch wall
# reads — never a second config key, never a second derivation command ---
expect_eq "S18.3 landing-gate.sh reads impact-command exactly once" "1" \
  "$(grep -cF 'config_value "$REPO" "impact-command" ""' "$S18_LG")"
expect_eq "S18.3 …the same call shape dispatch-preflight.sh uses" "1" \
  "$(grep -cF 'config_value "$REPO" "impact-command" ""' "$S13_DP")"
# ============================================================
section "S19 — THE MUTATION ANCHOR: one call, every doctoring site (AC-29/AC-30/AC-31)"
# ============================================================
#
# WHAT THIS SECTION OWNS. A suite that proves an assertion discriminates builds a
# mutant by stripping or rewriting one line of a shipped source with `grep -v` or
# `sed`. The pattern it strips is the anchor, and when the anchored line moves the
# "mutant" comes out byte-identical to the shipped file — every behavioural row
# under it then goes green against a fixture that was never mutated. Before this
# wave every one of these sites carried its own precondition or none: a `cmp -s`
# against the doctored copy, a count-difference row, or nothing at all. The
# research code map's census found 24 of them; the real number in this tree is 49
# call sites over four suites, because the census read only `grep -v` in this suite
# and `DOCTORED…=` in docs-pins, and missed every `sed`/`awk` mutant tree here plus
# the doctoring `agent-context-guard` and `landing-gate` each carry. Every one of
# them now goes through ONE spelling — the framework's `anchor` — and this section
# is the wall that keeps them there.
#
# THE BRACKETS IN THE PATTERN BELOW ARE DELIBERATE. This file is itself one of the
# files the absence sweep reads, so a pattern spelling the idiom literally would
# match its own definition and could never go green. `[a]nchor` matches "anchor"
# and does not match "[a]nchor", which is what lets the sweep name the idiom out
# loud and still be a real sweep.

S19_TESTS_DIR="$REPO_ROOT/tests"
S19_DOCS_PINS="$S19_TESTS_DIR/docs-pins.test.sh"
S19_ASSERT="$S19_TESTS_DIR/lib/assert.sh"

# The four hand-rolled precondition idioms this wave removed, as one ERE.
S19_HANDROLLED='cmp -[s] [^;]*DOCTORED|the [a]nchor has not moved|the (sed|grep -v) targets? matched [n]othing|mutation [a]pplies'

# --- §S19.1 the framework owns `anchor`, once ---
expect_eq "S19.1 anchor is defined in exactly one file under tests/" "1" \
  "$(/usr/bin/grep -lE '^anchor\(\)' "$S19_TESTS_DIR"/lib/*.sh "$S19_TESTS_DIR"/*.test.sh 2>/dev/null | wc -l | tr -d ' ')"
expect_eq "S19.1 …and it is the framework" "1" \
  "$(/usr/bin/grep -cE '^anchor\(\)' "$S19_ASSERT")"

# --- §S19.2 ABSENCE: no suite hand-rolls its own mutation precondition ---
#
# NO EXCEPTIONS, AND NO NARROWED PATTERN. This row carried a named waiver while two
# doctoring sites the code map's 24-site census never found — `mutate_guard` in
# `tests/agent-context-guard.test.sh` and the inverted-guard awk in
# `tests/landing-gate.test.sh` — sat outside the declared set of the slice that
# built `anchor`. Both are routed now, so the waiver is deleted and the expectation
# is EMPTY: the sweep reads every suite in tests/, and a hand-rolled precondition
# reappearing ANYWHERE turns this row red and names the file and the hit count.
S19_HAND_HITS="$(cd "$S19_TESTS_DIR" && /usr/bin/grep -cE -- "$S19_HANDROLLED" ./*.test.sh 2>/dev/null \
  | /usr/bin/grep -v ':0$' | sed 's|^\./||' | tr '\n' ' ' | sed 's/ $//')"
expect_empty "S19.2 no suite in tests/ hand-rolls a mutation precondition any more" \
  "$S19_HAND_HITS"

# THE PAIRED POSITIVE, and the discriminating one: the same sweep over a copy of
# docs-pins with ONE of those idioms planted back must name that copy. Without
# this row, §S19.2 would pass just as loudly against a pattern that matches
# nothing at all.
S19_SB="$SANDBOX/s19"
mkdir -p "$S19_SB"
cp "$S19_DOCS_PINS" "$S19_SB/replanted.test.sh"
# built with %s so this line does not itself spell the idiom it plants
printf 'if cmp -%s "$SKILL_MD" "$DOCTORED_REPLANTED"; then no "x" "the %s target matched nothing"; fi\n' \
  s sed >> "$S19_SB/replanted.test.sh"
expect_eq "S19.2 …and the same sweep DOES fire on a copy with the idiom planted back" "1" \
  "$(/usr/bin/grep -cE -- "$S19_HANDROLLED" "$S19_SB/replanted.test.sh" | tr -d ' ')"

# --- §S19.3 POSITIVE: every doctoring site declares through `anchor` ---
# The census: a doctoring site in docs-pins is a `DOCTORED…="$TMP/…"` assignment.
# RE-POINTED (epic-22 K1, plan slice 15): Section 12's three K1 anti-vacuity mutants
# (DOCTORED_NO_GATES, DOCTORED_MATRIX_BACK, DOCTORED_NO_INTEGRATION) add three doctoring
# sites and three anchor calls — 23->26, 24->27, folding into the suite-wide total below.
expect_eq "S19.3 docs-pins holds 26 doctoring sites" "26" \
  "$(/usr/bin/grep -cE '^DOCTORED[A-Z0-9_]*="\$TMP/' "$S19_DOCS_PINS")"
expect_eq "S19.3 …declared by 27 anchor calls (Section 8's doctoring rewrites two sentences; Section 12 adds three, K1)" "27" \
  "$(/usr/bin/grep -cE '^[[:space:]]*anchor[[:space:]]' "$S19_DOCS_PINS")"
# 25 since Step 6: §S13.2 lifts the wall's own reduction out of the hook and
# anchors both lines it lifts (review-b B-3). 26 since epic-21 wave-02 S12: §V's
# governing-skill mutation adds one more anchor call.
expect_eq "S19.3 …and this suite's own mutant trees and lifts by 26 more" "26" \
  "$(/usr/bin/grep -cE '^[[:space:]]*anchor[[:space:]]' "$S19_TESTS_DIR/cross-gate-agreement.test.sh")"
# The two suites the waiver used to name. `mutate_guard` anchors per call (its callers pass
# the shipped line they delete). landing-gate anchors its inverted-guard awk, and — since
# the F2 fold-in (review-b B-12) — the two whole-line moves its §17 doctors into
# hooks/landing-gate.sh to prove the swept-marker extraction fails loudly.
expect_eq "S19.3 …and agent-context-guard by one, now that mutate_guard anchors per call" "1" \
  "$(/usr/bin/grep -cE '^[[:space:]]*anchor[[:space:]]' "$S19_TESTS_DIR/agent-context-guard.test.sh")"
expect_eq "S19.3 …and landing-gate by three: the inverted-guard mutant, and the two line moves §17 doctors" "3" \
  "$(/usr/bin/grep -cE '^[[:space:]]*anchor[[:space:]]' "$S19_TESTS_DIR/landing-gate.test.sh")"
# THE TOTAL AC-30 NAMES. Stated as its own measured literal rather than left to the
# reader to add up: this is the number that has to move when a doctoring site is
# added or removed anywhere in the four suites that build mutants.
# 53 since the fold-in landings (A-44). F1 (item 17) and F2 (item 11) each added two
# anchors — F1 in this suite, F2 in landing-gate — and each rewrote this total from 49
# to 51 in BYTE-IDENTICAL text, so the merge was conflict-free and the pin was two short
# of the tree. Measured at the merged head, not predicted: 24 + 25 + 1 + 3 = 53.
# 57 since both epic-22 slices landed on top of the 53 baseline: K1 (plan slice 15) gave
# docs-pins three more anchor calls (Section 12's anti-vacuity mutants, 24 -> 27 in the
# first row above); R6 (plan slice 3, §V's one new anchor call) gave this suite one more,
# 25 -> 26 (see the row above this one). 27 + 26 + 1 + 3 = 57.
expect_eq "S19.3 …57 anchor call sites across the four doctoring suites, all told" "57" \
  "$(cat "$S19_DOCS_PINS" "$S19_TESTS_DIR/cross-gate-agreement.test.sh" \
        "$S19_TESTS_DIR/agent-context-guard.test.sh" "$S19_TESTS_DIR/landing-gate.test.sh" \
     | /usr/bin/grep -cE '^[[:space:]]*anchor[[:space:]]')"

# --- §S19.4 COMPLETENESS: no doctoring site is left undeclared ---
# Mechanically derived rather than counted: every `DOCTORED…="$TMP/…"` assignment
# must carry an `anchor` call within the three lines above it.
s19_unanchored() {  # s19_unanchored <suite> -> how many doctoring sites have no anchor above them
  awk '
    /^DOCTORED[A-Z0-9_]*="\$TMP\// {
      found = 0
      for (i = 1; i <= 3; i++) if (p[i] ~ /^[ \t]*anchor[ \t]/) found = 1
      if (!found) n++
    }
    { p[3] = p[2]; p[2] = p[1]; p[1] = $0 }
    END { print n + 0 }
  ' "$1"
}
expect_eq "S19.4 every docs-pins doctoring site is anchored" "0" \
  "$(s19_unanchored "$S19_DOCS_PINS")"

# THE PAIRED POSITIVE: the same derivation over a copy with one anchor call
# deleted must find exactly the site that lost it.
sed '/^anchor .*BIND_DOCS_TRY=/d' "$S19_DOCS_PINS" > "$S19_SB/unanchored.test.sh"
expect_eq "S19.4 …and the derivation names a site whose anchor was deleted" "1" \
  "$(s19_unanchored "$S19_SB/unanchored.test.sh")"
expect_eq "S19.4 …from a copy that really did lose one line (not vacuous)" "1" \
  "$(( $(wc -l < "$S19_DOCS_PINS") - $(wc -l < "$S19_SB/unanchored.test.sh") ))"

# ============================================================
section "S17 — no private builder of a shared shape remains (AC-28)"
# ============================================================
#
# THE ABSENCE HALF AND THE POSITIVE HALF, TOGETHER (spec AC-28). Three shapes crossed this
# tree in sixty-three hand-written copies: the `roster-state/v1` row (16 suites), the
# `landing-swept/v1` marker (6), and the recorded ListAgents answer (8). S14/S15/S16 built
# the one builder for each; S17 removed the copies. An absence test alone would pass on a
# tree where the suites were deleted, so every absence below is paired with the positive
# that the former site now SOURCES the builder it was replaced by.
#
# THIS SECTION SPELLS NONE OF THE THREE LITERALS. Each is read back out of the writer that
# owns it — the row's token off `roster_row`'s own output, the marker's off the constant the
# two hooks share, the answer's off the committed corpus — so a suite cannot pass this by
# renaming the schema, and this file cannot match its own scan.
#
# WHAT COUNTS AS A HIT. The schema token followed by `|` is a row or marker being written or
# selected; the token alone is the VERSION being asserted, which several suites do on
# purpose (`the row's leading field is the schema version`) and which must stay. Full-line
# comments are skipped: naming the shape in prose is how these files stay readable, and a
# scan that forbade it would buy its zero by making the tree worse.
#
# THE ONE EXEMPTION, NAMED: tests/live-agents.test.sh. That suite is the PARSER's own, and
# its bodies are the parser's inputs — a doubled `Teammates` header, a forged block after
# `Peer sessions`, a garbled separator. A builder able to emit those would be able to emit
# them by accident, so they stay hand-written there and the exemption is held to that one
# file, with the paired positive that the file really does still carry them.

S17_TESTS_DIR="$REPO_ROOT/tests"
S17_ROW_TOKEN="${ROSTER_ROW_SCHEMA}|"
S17_MARK_TOKEN="${SWEPT_SCHEMA}|"
S17_LA_TOKEN="$(live_answer_block_header 1 | cut -d'(' -f1)("

# Non-vacuity of the three tokens themselves: a typo in any of them would make every
# absence assertion below pass over an untouched tree.
expect_contains "S17 the row token came off the writer" "roster-state/" "$S17_ROW_TOKEN"
expect_contains "S17 the marker token came off the hooks' shared constant" "landing-swept/" \
  "$S17_MARK_TOKEN"
expect_contains "S17 the answer token came off the corpus" "Teammates" "$S17_LA_TOKEN"

s17_hits() {  # <literal> [exempt basename] -> "<suite>:<count> …" for every suite still holding it
  local lit="$1" exempt="${2:-}" f b n out=""
  for f in "$S17_TESTS_DIR"/*.test.sh; do
    b="$(basename "$f")"
    [ "$b" = "$exempt" ] && continue
    n="$(grep -v '^[[:space:]]*#' "$f" | grep -cF "$lit")" || n=0
    [ "$n" -gt 0 ] && out="${out}${b}:${n} "
  done
  printf '%s' "$out"
}

expect_eq "S17 no suite hand-writes or hand-selects the roster row any more" \
  "" "$(s17_hits "$S17_ROW_TOKEN")"
expect_eq "S17 no suite hand-writes or hand-selects the swept marker any more" \
  "" "$(s17_hits "$S17_MARK_TOKEN")"
expect_eq "S17 no suite hand-writes a ListAgents answer any more (the parser's own excepted)" \
  "" "$(s17_hits "$S17_LA_TOKEN" live-agents.test.sh)"

# THE EXEMPTION IS NOT A BLANK CHEQUE: it is one file, and that file is exempt because it
# genuinely still carries such bodies. If it ever stops, the exemption goes with it.
expect_true "S17 the exempt suite is the parser's own, and it does still hold answer bodies" \
  test "$(grep -v '^[[:space:]]*#' "$S17_TESTS_DIR/live-agents.test.sh" | grep -cF "$S17_LA_TOKEN")" -gt 0

# --- the paired positive: every former site sources the builder that replaced it ---

s17_sources() {  # <suite basename> <lib basename> -> 1 when the suite sources it
  grep -cF ". \"\$(dirname \"\$0\")/lib/$2\"" "$S17_TESTS_DIR/$1.test.sh" 2>/dev/null || printf '0'
}

for _s17 in cross-gate-agreement dispatch-preflight execution-recorder fail-direction-table \
            session-poker stop-check stop-guard stop-orders; do
  expect_eq "S17 [$_s17] sources the one ListAgents builder" \
    "1" "$(s17_sources "$_s17" live-answer.sh)"
done

for _s17 in cross-gate-agreement dispatch-preflight doctor-fleet doctor-patrol \
            execution-recorder fail-direction-table hook-adoption landing-gate \
            preflight-probe session-poker session-start session-sweeper stop-check \
            stop-guard stop-orders worktree; do
  expect_eq "S17 [$_s17] sources the one roster-row builder" \
    "1" "$(s17_sources "$_s17" roster-row.sh)"
done

for _s17 in dispatch-preflight doctor-fleet doctor-patrol landing-gate session-poker \
            session-start; do
  expect_eq "S17 [$_s17] sources the one swept-marker builder" \
    "1" "$(s17_sources "$_s17" swept-marker.sh)"
done

# --- §S17b the THIRD producer of the roster row, held to the writer's key set (A-15) ---
#
# hooks/execution-recorder.sh does not BUILD a row — it rewrites one field-wise with
# `RS = "|"`, which is why a row that grows a field anywhere still comes back out unchanged.
# But its `END` arm APPENDS `teammate_id=` when the launch row carried none, and that append
# is a from-scratch segment written by a file that is not the writer. Routing the whole
# rewrite through `roster_row` was rejected: the writer emits its optional fields
# present-if-passed, so re-emitting a pre-wall row through it would ADD `files=`,
# `suites_allowed=` and `suites_source=` empty and destroy the third state those keys'
# ABSENCE encodes (payload/scripts/lib/roster.sh's own header). What is pinned instead is
# that the two producers agree on the KEY SET and on every VALUE — the row's readers are by
# key, and position is the one thing they demonstrably do not read.
#
# The recorder's awk is not re-typed here: it is extracted from the shipped file and eval'd,
# the same `field1_via`/`field2_via` idiom this suite already uses.

s17_rewrite_via() {  # <hook file> <row> <agent id> <teammate id> <name> -> the completed row
  ( ROW="$2"; ROW_AGENT_ID="$3"; ROW_TEAMMATE_ID="$4"; ROW_NAME="$5"; PRIOR_LAUNCH=""
    eval "$(awk '/^  COMPLETED=\$\(printf/,/^    END \{ if \(tid/' "$1")"
    printf '%s\n' "$COMPLETED" ) 2>/dev/null
}

s17_keys() { printf '%s' "$1" | tr '|' '\n' | cut -d= -f1 | sort | tr '\n' ' '; }
s17_pairs() { printf '%s' "$1" | tr '|' '\n' | sort | tr '\n' ' '; }

S17_LAUNCH_ROW="$(roster_row_fixture status=intended session=s17sess name=s17-writer \
  agent_id= launched_at=2026-09-06T00:00:00Z deliverable=.bionic/docs/record/s17.md \
  tool_use_id=toolu_01S17)"
S17_TID="s17-writer@session-s17sess"
S17_DONE="$(s17_rewrite_via "$PARTY_ER" "$S17_LAUNCH_ROW" "as17-1111111111111111" "$S17_TID" "s17-writer")"

# What the ONE WRITER produces for the same facts, with the field named.
S17_WRITTEN="$(roster_row_fixture status=confirmed session=s17sess name=s17-writer \
  agent_id=as17-1111111111111111 launched_at=2026-09-06T00:00:00Z \
  deliverable=.bionic/docs/record/s17.md teammate_id="$S17_TID" tool_use_id=toolu_01S17)"

expect_eq "S17b the recorder's appended row carries the writer's key set, exactly" \
  "$(s17_keys "$S17_WRITTEN")" "$(s17_keys "$S17_DONE")"
expect_eq "S17b …and every key's value agrees, field for field" \
  "$(s17_pairs "$S17_WRITTEN")" "$(s17_pairs "$S17_DONE")"
expect_eq "S17b …with exactly one teammate_id on the row, never two" \
  "1" "$(printf '%s' "$S17_DONE" | tr '|' '\n' | grep -c '^teammate_id=')"

# THE DISCRIMINATOR — a copy of the recorder whose appended segment is spelled with a
# different key. Every reader in the fleet is by key, so this is precisely the drift the
# comparison above exists to catch, and it is invisible to every other assertion in the tree.
S17_ER_MUT="$SANDBOX/s17-execution-recorder-mutant.sh"
anchor "$PARTY_ER" '|teammate_id=%s' 1
awk '{ gsub(/\|teammate_id=%s/, "|teammate=%s"); print }' "$PARTY_ER" > "$S17_ER_MUT"
S17_DONE_MUT="$(s17_rewrite_via "$S17_ER_MUT" "$S17_LAUNCH_ROW" "as17-1111111111111111" "$S17_TID" "s17-writer")"
expect_eq "S17b …and the key-set pin goes red on it (the pin discriminates)" \
  "no" "$([ "$(s17_keys "$S17_WRITTEN")" = "$(s17_keys "$S17_DONE_MUT")" ] && echo yes || echo no)"

# --- §S17c the poker's third spelling of the marker schema is gone (A-14b) ---
#
# §S15b pins `adopt_copy_marker`. `youngest_suite_writer` was the OTHER function in the same
# file greping the bare literal, and it is the one whose failure mode is silent: no closing
# markers found reads there as "every row is still open", which fills the writer budget.
expect_eq "S17c youngest_suite_writer greps the shared constant, not a literal" \
  "0" "$(awk '/^youngest_suite_writer\(\)/,/^\}/' "$PARTY_PK" | grep -cF "grep '^${SWEPT_SCHEMA}|'")"
expect_eq "S17c …and it does grep the marker, through the constant (the zero is not absence)" \
  "1" "$(awk '/^youngest_suite_writer\(\)/,/^\}/' "$PARTY_PK" | grep -cF 'grep "^${SWEPT_SCHEMA}|"')"


# ============================================================
section "B — no backtick pair hides inside a double-quoted assertion name (AC-B.1/AC-B.2, epic-22 slice 7)"
# ============================================================
#
# THE DEFECT CLASS (seed ideas/fixit-residue-names.md item 3, critic issue 3 / A-S18a-6).
# `expect_*` calls take their FIRST argument as a human-readable label, always inside double
# quotes. A label that wraps a literal token in backticks for readability — "the neighbour
# the `.` would have swallowed" — is not quoted text to bash: a double-quoted string still
# expands backtick command substitution, so the shell RUNS `.` (the `source` builtin, no
# argument) on every pass, corrupts the label to whatever it printed, and dumps a usage
# error to stderr. This landed three times in this wave alone and once executed `uv tool
# install --force omnigent` for real (critic issue 3) — a machine-mutating class of test
# defect, not a cosmetic one. The instance live on main is tests/stop-check.test.sh:298,
# fixed by 8727375 (this slice's cherry-pick, landed in this same tree).
#
# THE SCAN. A per-line state machine, not a bare regex: it tracks single/double-quote state,
# stops at a `#` outside any quote (comments never execute), and skips heredoc BODY lines
# entirely between an opening `<<[-]DELIM` (quoted or not) and its closing delimiter line —
# heredoc text is never "inside a double-quoted string" as a shell grammar node. An escaped
# backtick (`\``) is consumed by its backslash, so no pair forms. THE ONE CASE THAT NEEDS ITS
# OWN RULE: a legitimate $(...) substitution nested inside a double-quoted string reopens
# ordinary shell quoting for its own body, so a backtick nested inside a SINGLE-quoted
# argument of a $(...) call — e.g. "$(printf '```markdown```')" — is inert there for the
# same reason it is inert anywhere else inside single quotes; the scanner re-enters its own
# state machine for a $(...) span instead of reading it as flat text. Without that rule, four
# genuine committed lines (fenced code blocks passed to `printf` inside $(...), in
# tests/canonical-sdlc-governing-skill.test.sh) false-positive and §B.2 could never be green
# on this tree. Left alone, by design: a bare backtick pair directly inside a $(...) body,
# not nested in further quotes, is real intentional legacy substitution nested in the modern
# form — a style question, not this defect class. A hit prints as `<file>:<line>`, one per
# PAIR found.

B_AWK="$SANDBOX/backtick-scan.awk"
cat > "$B_AWK" <<'AWK_EOF'
function skip_squote(line, i, n,    c) {
  while (i <= n) { c = substr(line, i, 1); if (c == "'") return i + 1; i++ }
  return n + 1
}
function scan_subshell(line, i, n,    c, r) {
  while (i <= n) {
    c = substr(line, i, 1)
    if (c == "\\") { i += 2; continue }
    if (c == "'") { i = skip_squote(line, i + 1, n); continue }
    if (c == "\"") { r = scan_dquote(line, i + 1, n); i = r + 1; continue }
    if (c == "$" && substr(line, i + 1, 1) == "(") { i = scan_subshell(line, i + 2, n); continue }
    if (c == ")") return i + 1
    i++
  }
  return n + 1
}
function find_second_backtick(line, i, n,    c) {
  while (i <= n) {
    c = substr(line, i, 1)
    if (c == "\\") { i += 2; continue }
    if (c == "`") return i
    if (c == "\"") return 0
    i++
  }
  return 0
}
function scan_dquote(line, i, n,    c, j) {
  while (i <= n) {
    c = substr(line, i, 1)
    if (c == "\\") { i += 2; continue }
    if (c == "\"") return i
    if (c == "$" && substr(line, i + 1, 1) == "(") { i = scan_subshell(line, i + 2, n); continue }
    if (c == "`") {
      j = find_second_backtick(line, i + 1, n)
      if (j > 0) { HIT = 1; i = j + 1; continue }
      i++; continue
    }
    i++
  }
  return n + 1
}
function scan_line(line,    i, n, c, r) {
  HIT = 0; i = 1; n = length(line)
  while (i <= n) {
    c = substr(line, i, 1)
    if (c == "#") return HIT
    if (c == "\\") { i += 2; continue }
    if (c == "'") { i = skip_squote(line, i + 1, n); continue }
    if (c == "\"") { r = scan_dquote(line, i + 1, n); i = r + 1; continue }
    i++
  }
  return HIT
}
function heredoc_start(line,    tmp) {
  if (match(line, /<<-?[ \t]*'[A-Za-z_][A-Za-z0-9_]*'/)) {
    tmp = substr(line, RSTART, RLENGTH); HD_STRIP = (tmp ~ /^<<-/) ? 1 : 0
    sub(/^<<-?[ \t]*'/, "", tmp); sub(/'$/, "", tmp); HD_DELIM = tmp; return 1
  }
  if (match(line, /<<-?[ \t]*"[A-Za-z_][A-Za-z0-9_]*"/)) {
    tmp = substr(line, RSTART, RLENGTH); HD_STRIP = (tmp ~ /^<<-/) ? 1 : 0
    sub(/^<<-?[ \t]*"/, "", tmp); sub(/"$/, "", tmp); HD_DELIM = tmp; return 1
  }
  if (match(line, /<<-?[ \t]*[A-Za-z_][A-Za-z0-9_]*/)) {
    tmp = substr(line, RSTART, RLENGTH); HD_STRIP = (tmp ~ /^<<-/) ? 1 : 0
    sub(/^<<-?[ \t]*/, "", tmp); HD_DELIM = tmp; return 1
  }
  return 0
}
function is_delim_line(line,    t) {
  t = line; if (HD_STRIP) sub(/^[ \t]+/, "", t); return (t == HD_DELIM)
}
FNR == 1 { IN_HEREDOC = 0 }
{
  if (IN_HEREDOC) { if (is_delim_line($0)) IN_HEREDOC = 0; next }
  if (scan_line($0)) print FILENAME ":" FNR
  if (heredoc_start($0)) IN_HEREDOC = 1
}
AWK_EOF

b_scan() { awk -f "$B_AWK" "$@" 2>/dev/null; }

# (a) §B.2 — GREEN ON THE COMMITTED TREE. The same two roots 8727375's own sweep grep named
# (minus tests/drill/, which does not exist on main, per plan Assumption A-6).
B_TESTS_HITS="$(b_scan "$REPO_ROOT"/tests/*.test.sh "$REPO_ROOT"/tests/lib/*.sh)"
expect_empty "§B.2 the scan is silent on the committed tree (the fix landed, nothing else hides)" \
  "$B_TESTS_HITS"

# (b) §B.1 — THE MUTATION, the discriminator. A scratch COPY of one suite (the shipped file
# is never touched), with a fresh backtick pair planted at a known line — line 2, right
# after the shebang, so no `anchor` precondition is needed: this is an INSERTION at a fixed
# offset, not a pattern-matched deletion that could silently miss its target.
B_MUT_DIR="$SANDBOX/backtick-mutant"; mkdir -p "$B_MUT_DIR"
{
  head -n 1 "$REPO_ROOT/tests/session-sweeper.test.sh"
  printf 'expect_eq "a planted `pair` right here" "x" "x"\n'
  tail -n +2 "$REPO_ROOT/tests/session-sweeper.test.sh"
} > "$B_MUT_DIR/session-sweeper.test.sh"

B_MUT_HITS="$(b_scan "$B_MUT_DIR/session-sweeper.test.sh")"
expect_eq "§B.1 a planted pair makes the scan RED naming file:line" \
  "$B_MUT_DIR/session-sweeper.test.sh:2" "$B_MUT_HITS"

# CONTROL — the same file, unplanted: still silent, or the RED above was the `cp`/`head`/
# `tail` reshuffle and not the plant.
B_CTRL_DIR="$SANDBOX/backtick-control"; mkdir -p "$B_CTRL_DIR"
cp "$REPO_ROOT/tests/session-sweeper.test.sh" "$B_CTRL_DIR/session-sweeper.test.sh"
expect_empty "…control: the unmutated copy stays silent" \
  "$(b_scan "$B_CTRL_DIR/session-sweeper.test.sh")"

# (c) THE EXCLUSIONS, individually named — one fixture line per shape, so a future edit that
# widens the scan (and starts flagging safe text) is caught here rather than being
# discovered as a false-positive drowning out a real hit. Five shapes: an ESCAPED pair
# (line 2), a legitimate $(...) with a nested SINGLE-quoted pair (line 3), a pair inside a
# COMMENT (line 4), a pair inside a bare SINGLE-quoted string (line 5), and a pair inside a
# HEREDOC body opened with a quoted delimiter (lines 6-8) — the fourth exclusion class
# 8727375's own commit message named. Only line 9, a real unescaped pair inside a plain
# double-quoted string, is a hit.
B_FX="$SANDBOX/backtick-exclusions.sh"
cat > "$B_FX" <<'FX_EOF'
#!/bin/bash
expect_eq "the \`escaped\` pair is inert" "yes" "yes"
expect_eq "fence" "$(printf '```markdown```')" "x"
# this comment mentions `a pair` right here
MSG='the `pair` is inert in single quotes'
cat <<'HEREDOC_EOF'
a heredoc body line with a `pair` in it, quoted delimiter
HEREDOC_EOF
expect_eq "the neighbour the `.` would have swallowed" "x" "y"
FX_EOF
B_FX_HITS="$(b_scan "$B_FX")"
expect_eq "…the five exclusions (escaped, \$(...) w/ nested single quotes, comment, single-quoted, heredoc body) stay silent; only the real pair on line 9 is a hit" \
  "$B_FX:9" "$B_FX_HITS"


# ============================================================
finish
