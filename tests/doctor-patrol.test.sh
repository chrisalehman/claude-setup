#!/bin/bash
# tests/doctor-patrol.test.sh — doctor.sh's PATROL section (F3, epic-19 wave-01,
# spec AC-F3; design ledger .bionic/docs/record/epic-19/step2-design-ledger.md
# ratification round 2).
#
# THE CONTRACT UNDER TEST. Doctor's Patrol section shows running Patrols or
# nothing: one line per live Patrol — `✓ session <short> · <n> open
# dispatches` — and `– none running` when there is none. Gone from the default
# output: the "reconstructed from the transcript" narrative header, per-job
# cron/prompt detail lines, the stamp's firing/not-firing state and interval
# provenance, and the dispatch-wall tally. The one survivor is the
# duplicate-Patrol fix line (`CronDelete <id>`) — ratified to stay because it
# costs nothing in the healthy, single-Patrol case.
#
# EXECUTED, NOT SOURCED — doctor.sh's own header states this is the only
# supported mode ("Executed, never sourced"), so this suite drives the real
# script exactly the way a user's shell would, through the one seam
# lib/patrol.sh already offers every caller: BIONIC_CLAUDE_HOME. A fixture
# claude-home carries a `sessions/<id>.json` naming a REAL live process (a
# spawned `sleep`, so `kill -0` succeeds the way it would for an actual CLI)
# and that session's own transcript, where a `CronCreate`/`CronDelete` pair is
# a recorded tool_use like any other (lib/patrol.sh:22-29). A fixture repo
# supplies the roster file patrol_roster_state reads directly off disk — no
# session-poker, no cron table, nothing that needs a live CLI.
#
# NO doctor.test.sh EXISTED BEFORE THIS SUITE. The broad one (epic-17 W3 S7)
# fingerprinted a whole fixture machine and was deleted at 8582861 (epic-18
# wave-03, the reliability ruling) with nothing replacing it — this suite
# covers only the Patrol section, scoped the way tests/rc-item.test.sh scopes
# to one setup-managed item rather than re-fingerprinting the world.
#
# ASSERTION-HELPER RACE. No `printf | grep -q` anywhere below
# (tests/assert-helper-race.test.sh): containment is bash `[[ == * ]]`
# in-process, and the one `awk` extraction below reads to EOF rather than
# closing early.
#
# Usage: bash tests/doctor-patrol.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/roster-row.sh"
. "$(dirname "$0")/lib/swept-marker.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
PAYLOAD="${REPO}/payload"
DOCTOR_SH="${PAYLOAD}/scripts/doctor.sh"

command -v jq >/dev/null 2>&1 || { echo "doctor-patrol.test.sh: jq is required"; exit 1; }

TMP="$(mktemp -d)"
LIVE_PIDS=""
cleanup() {
  for p in $LIVE_PIDS; do kill "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

expect_true "payload/scripts/doctor.sh exists" test -f "$DOCTOR_SH"

# ---------- fixture builders ----------

# A live process this machine's `kill -0` will actually find, the same way a
# real CLI session's pid does. SETS $LIVE_PID RATHER THAN PRINTING IT — a
# `$(...)` command substitution runs in its own subshell, and on this machine
# a background job started inside one dies the instant that subshell exits
# (measured: `sleep 100 &` inside `$(...)` was already gone by the caller's
# next line). Called plain, never captured.
spawn_live_pid() {
  sleep 100 &
  LIVE_PID=$!
  LIVE_PIDS="${LIVE_PIDS} ${LIVE_PID}"
}

# A claude-home with one live session named in sessions/<sid>.json.
make_claude_home() {  # <sid> <pid> <cwd> -> claude-home dir on stdout
  local sid="$1" pid="$2" cwd="$3" dir
  dir="$(mktemp -d -p "$TMP")"
  mkdir -p "$dir/sessions" "$dir/projects/-fixture-proj"
  jq -nc --arg sid "$sid" --argjson pid "$pid" --arg cwd "$cwd" \
    '{sessionId:$sid,pid:$pid,cwd:$cwd}' > "$dir/sessions/${sid}.json"
  : > "$dir/projects/-fixture-proj/${sid}.jsonl"
  printf '%s' "$dir"
}

# A claude-home with no live sessions at all — patrol_live_sessions() returns
# nothing without even a `sessions/` directory to look in.
make_empty_claude_home() {
  mktemp -d -p "$TMP"
}

transcript_of() {  # <claude-home> <sid>
  printf '%s/projects/-fixture-proj/%s.jsonl' "$1" "$2"
}

# One CronCreate + its joined tool_result, the shape lib/patrol.sh's join
# reads: the job id comes back in the result's prose ("Scheduled recurring job
# <id> (...)"), never in the request.
plant_patrol_job() {  # <transcript> <tool_use_id> <job-id>
  local t="$1" tid="$2" jobid="$3"
  jq -nc --arg id "$tid" \
    '{type:"assistant",isSidechain:false,
      message:{role:"assistant",content:[{type:"tool_use",id:$id,name:"CronCreate",
        input:{cron:"*/30 * * * *",recurring:true,
               prompt:"Patrol tick for the fixture (bionic). Run: bash /abs/hooks/session-poker.sh tick — then continue."}}]}}' \
    >> "$t"
  jq -nc --arg id "$tid" --arg c "Scheduled recurring job ${jobid} (*/30 * * * *) — Patrol tick" \
    '{type:"user",isSidechain:false,
      message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,content:$c}]}}' \
    >> "$t"
}

# The roster file patrol_roster_state() reads straight off disk — no session-
# poker, no live process, just the append-only shape the wall itself writes.
make_repo_with_roster() {  # <sid> <open-names...> -- <closed-names...> -> repo dir on stdout
  local sid="$1" dir nm; shift
  dir="$(mktemp -d -p "$TMP")"
  mkdir -p "$dir/.bionic/tmp"
  local f="$dir/.bionic/tmp/roster-${sid}.state"
  local mode=open
  for nm in "$@"; do
    if [ "$nm" = "--" ]; then mode=closed; continue; fi
    # THE INVENTED `ts=` IS GONE (S17, on S14's F-S14-2). This fixture carried a field
    # no production writer has ever emitted and no reader in the fleet consumes — proven
    # by grep over payload/hooks and payload/scripts — for as long as nothing checked.
    # `roster_row` refuses the key outright, which is the point: a fixture cannot invent
    # a field the fleet has no reader for.
    roster_row_fixture status=intended session="$sid" name="$nm" >> "$f"
    # THE MARKER IN THE SHAPE ITS ONE ORIGINATOR WRITES IT, `state=` and all
    # (hooks/landing-gate.sh's `SWEPT_SCHEMA` printf). A closing marker says
    # `state=MET`; a marker that says anything else is a contract the sweep
    # judged UNMET, and since S17 those travel — `adopt_copy_marker` copies a
    # predecessor's verdict verbatim onto a successor's roster. A fixture that
    # wrote no `state=` at all could not tell the two apart, which is precisely
    # the distinction `patrol_roster_state` now makes.
    [ "$mode" = "closed" ] && swept_marker_write "$f" 2026-08-27T00:00:01Z "$sid" "$nm" a000 MET
  done
  printf '%s' "$dir"
}

# THE STAMP hooks/session-poker.sh touches on every tick, and the ONE fact that
# separates an armed Patrol from a dead one. `patrol_stamp_state` reads only its
# mtime against 2x the poker interval (20m default → a 2400s limit), so a file
# written now is `firing` and one backdated past that is `not-firing`. Absent is
# a third answer, `never-armed`, and it needs no builder — it is what every
# fixture here had before this existed.
plant_patrol_stamp() {  # <repo> <sid> [<backdate-hours>]
  local repo="$1" sid="$2" hours="${3:-}" f="$1/.bionic/tmp/patrol-$2.state"
  mkdir -p "$repo/.bionic/tmp"
  printf 'patrol-stamp/v1|verb=arm|ts=fixture\n' > "$f"
  [ -n "$hours" ] && touch -t "$(date -v-"${hours}"H +%Y%m%d%H%M.%S)" "$f"
  return 0
}

# A repo whose session never wrote a roster at all — the state this suite's
# Sections 7 and 9 are about, and the one lib/patrol.sh reports as
# `present=no|rows=0|open=0`. `make_repo_with_roster` called with no names
# produces the same tree, which is exactly how Section 3 acquired it by
# accident; this builder says out loud what that fixture is.
make_repo_without_roster() {  # -> repo dir on stdout
  local dir
  dir="$(mktemp -d -p "$TMP")"
  mkdir -p "$dir/.bionic/tmp"
  printf '%s' "$dir"
}

# ONE LAUNCH, AS THE TRANSCRIPT RECORDS IT: the `Agent` tool_use lib/patrol.sh's
# scan counts (`_patrol_scan_jq`, the `A` record) plus the ordinary tool_result
# it joins to.
#
# THE RESULT IS BENIGN ON PURPOSE. A refusal is credited only when a tool_result
# carrying `PreToolUse:Agent hook error:` joins BY tool_use_id to an `Agent`
# tool_use (`_patrol_join_awk`) — the join, not the marker, is the rule — so
# these launches land in `dispatched=` and none of them in `refused=`, and the
# `blind=` arithmetic under test is `agents - rostered - 0`.
#
# `isSidechain:false` and no `agent_id` key anywhere in the entry: both are what
# the scan's two main-thread filters test, and a fixture that failed either would
# be counted as somebody else's turn and vanish from the tally.
plant_agent_dispatch() {  # <transcript> <tool_use_id>
  local t="$1" tid="$2"
  jq -nc --arg id "$tid" \
    '{type:"assistant",isSidechain:false,
      message:{role:"assistant",content:[{type:"tool_use",id:$id,name:"Agent",
        input:{description:"fixture slice",subagent_type:"general-purpose",
               prompt:"Do the fixture work and report back."}}]}}' \
    >> "$t"
  jq -nc --arg id "$tid" \
    '{type:"user",isSidechain:false,
      message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,
        content:"The agent finished and reported back."}]}}' \
    >> "$t"
}

# ---------- driving doctor ----------

# DOCTOR IS ALWAYS RUN FROM INSIDE THE PROJECT IT IS DIAGNOSING, because that is
# the only thing that makes its answer addressable: `project_root "$PWD"` is
# doctor's `DOCTOR_ROOT`, and the Patrol section reports on the sessions belonging
# to THAT root. Before Section 11 this helper took the claude-home alone and let
# doctor inherit the test runner's own cwd — this checkout — while every fixture
# session named a `/var/folders/...` project. The sections passed because doctor
# filtered on nothing at all; a session from any project on the machine printed
# here. The cwd is now an argument, and it is the fixture repo the session under
# test actually lives in.
run_doctor() {  # <claude-home> <project-cwd>
  ( cd "$2" && BIONIC_CLAUDE_HOME="$1" BIONIC_PLUGIN_ROOT="$PAYLOAD" BIONIC_DOCTOR_PROBE_SECONDS=3 \
      bash "$DOCTOR_SH" < /dev/null 2>&1 )
}

# The PATROL section alone — from its bare header to end of output, which is
# where the default (no --updates) run ends.
patrol_block() {  # <full-output>
  printf '%s\n' "$1" | awk '/^PATROL$/{f=1} f'
}

section "Section 1: no live Patrol anywhere"

EMPTY_HOME="$(make_empty_claude_home)"
EMPTY_PROJ="$(make_repo_without_roster)"
OUT1="$(run_doctor "$EMPTY_HOME" "$EMPTY_PROJ")"
PB1="$(patrol_block "$OUT1")"

expect_match    "1: the fallback line prints" "*none running*" "$PB1"
expect_no_match "2: no session line prints alongside the fallback" "*session*" "$PB1"

section "Section 2: one live Patrol, one open dispatch (singular)"

SID2="cccccccc-1111-2222-3333-444455556666"
SHORT2="${SID2%%-*}"
spawn_live_pid; PID2="$LIVE_PID"
# THE SESSION'S cwd MUST BE THE FIXTURE REPO, not a decorative path — it is
# what patrol_roster_state() resolves the roster file's location from
# (lib/patrol.sh:369, _patrol_repo_root on the session's own cwd).
REPO2="$(make_repo_with_roster "$SID2" beta -- alpha)"
HOME2="$(make_claude_home "$SID2" "$PID2" "$REPO2")"
TR2="$(transcript_of "$HOME2" "$SID2")"
plant_patrol_job "$TR2" "toolu_1" "abc12345"
# A FRESH STAMP, because a transcript-visible job is not a running Patrol. The
# row is gated on this file's age (doctor.sh, `_patrol_flush`); Sections 4 and 5
# below are the same fixture with the stamp stale and with it absent.
plant_patrol_stamp "$REPO2" "$SID2"

OUT2="$(run_doctor "$HOME2" "$REPO2")"
PB2="$(patrol_block "$OUT2")"

expect_match "3: the running Patrol prints session · singular open dispatch" \
  "*✓ session ${SHORT2} · 1 open dispatch*" "$PB2"
expect_no_match "4: 'dispatches' (plural) does not also appear on that line" \
  "*1 open dispatches*" "$PB2"

# The five deleted detail classes, checked as absences BESIDE the positive
# assertions above on the SAME fixture and the SAME extractor
# (memory/no-vacuous-tests-at-authoring) — this is not an empty-fixture
# vacuous negative, it is a section proven non-empty (3/4 above) that must not
# also carry the retired detail.
expect_no_match "5: the reconstruction narrative header is gone" \
  "*reconstructed from the transcript*" "$PB2"
expect_no_match "6: the per-job 'patrol jobs' row is gone" "*patrol jobs*" "$PB2"
expect_no_match "7: the job id/cron/prompt detail line is gone" "*abc12345*" "$PB2"
expect_no_match "8: the 'patrol stamp' row is gone" "*patrol stamp*" "$PB2"
expect_no_match "9: the interval-provenance detail is gone" "*came from the poker*" "$PB2"
expect_no_match "10: the 'dispatch wall' row is gone" "*dispatch wall*" "$PB2"
expect_no_match "11: the this-repo cwd detail is gone" "*this repo*" "$PB2"

section "Section 3: duplicate Patrols — the one survivor"

SID3="dddddddd-1111-2222-3333-444455556666"
SHORT3="${SID3%%-*}"
spawn_live_pid; PID3="$LIVE_PID"
REPO3="$(make_repo_with_roster "$SID3" -- alpha)"  # a roster, one closed row — open=0
# THE ROSTER IS PRESENT AND EMPTY OF OPEN WORK, which is not the same fixture as
# a session that never wrote one. This section owns the duplicate-Patrol fix line
# and wants the ordinary `0 open dispatches` row underneath it; the no-roster case
# it used to be built on is Section 7's, where it is asserted rather than incidental.
HOME3="$(make_claude_home "$SID3" "$PID3" "$REPO3")"
TR3="$(transcript_of "$HOME3" "$SID3")"
plant_patrol_job "$TR3" "toolu_1" "old11111"
plant_patrol_job "$TR3" "toolu_2" "new22222"
plant_patrol_stamp "$REPO3" "$SID3"

OUT3="$(run_doctor "$HOME3" "$REPO3")"
PB3="$(patrol_block "$OUT3")"

expect_match "12: the running Patrol still prints, 0 open dispatches (plural)" \
  "*✓ session ${SHORT3} · 0 open dispatches*" "$PB3"
expect_match "13: the duplicate fix line names the OLDER job for deletion" \
  "*session ${SHORT3} has 2 Patrol jobs armed → CronDelete old11111*" "$OUT3"
expect_no_match "14: the fix line does NOT also name the newer (kept) job" \
  "*CronDelete*new22222*" "$OUT3"
expect_no_match "15: the Patrol block itself carries no per-job detail" \
  "*old11111*" "$PB3"

section "Section 4: the job is in the transcript and the Patrol is DEAD"

# WHAT THIS SECTION OWNS, and why nothing above it could see it. Jobs are
# reconstructed from the transcript — CronCreate minus CronDelete — and the four
# events that kill a Patrol (a plugin update, /reload-plugins, a continue, a
# /clear and resume) take the job out of the CLI's in-memory cron table with no
# tool call behind them. So the count stays positive on a machine where nothing
# is firing, and doctor printed `✓ session … · N open dispatches` for it: the
# Step-6 correctness FAIL against AC-F3. The fixture is Section 2's, with one
# thing changed — the stamp is three hours old, well past the 3600s limit.

SID4="dddddddd-1111-2222-3333-444455556666"
SHORT4="${SID4%%-*}"
spawn_live_pid; PID4="$LIVE_PID"
REPO4="$(make_repo_with_roster "$SID4" beta -- alpha)"
HOME4="$(make_claude_home "$SID4" "$PID4" "$REPO4")"
TR4="$(transcript_of "$HOME4" "$SID4")"
plant_patrol_job "$TR4" "toolu_1" "abc12345"
plant_patrol_stamp "$REPO4" "$SID4" 3

OUT4="$(run_doctor "$HOME4" "$REPO4")"
PB4="$(patrol_block "$OUT4")"

expect_no_match "17: a dead Patrol prints no running line" "*✓ session ${SHORT4}*" "$PB4"
expect_no_match "18: and no session line of any kind" "*session ${SHORT4}*" "$PB4"
expect_match    "19: the section falls back to none running" "*none running*" "$PB4"
# NOT SILENCE. Running-or-nothing governs the SECTION; a Patrol that was armed
# and stopped ticking is the one state a person can act on, and the fix channel
# is where doctor says so.
expect_match    "20: the fix section names the session and what to do" \
  "*session ${SHORT4}: the Patrol is armed but not firing*" "$OUT4"
# The deleted detail stays deleted — the stamp is read, not rendered.
expect_no_match "21: the stamp state itself is still not printed" "*not-firing*" "$OUT4"
expect_no_match "22: nor its age or interval provenance" "*came from the poker*" "$OUT4"

section "Section 5: the job is in the transcript and there is no stamp"

# THE THIRD STATE, AND IT IS NOT A FAULT. An absent stamp means never armed —
# or deliberately ended, because the poker's `disarm` verb REMOVES this file
# (S10). Both are decisions, so this machine gets the same quiet page as one
# with no Patrol at all: no row, and no fix line either. This is the assertion
# that keeps Section 4's fix line from becoming noise on every stopped run.

SID5="eeeeeeee-1111-2222-3333-444455556666"
SHORT5="${SID5%%-*}"
spawn_live_pid; PID5="$LIVE_PID"
REPO5="$(make_repo_with_roster "$SID5" beta -- alpha)"
HOME5="$(make_claude_home "$SID5" "$PID5" "$REPO5")"
TR5="$(transcript_of "$HOME5" "$SID5")"
plant_patrol_job "$TR5" "toolu_1" "abc12345"

OUT5="$(run_doctor "$HOME5" "$REPO5")"
PB5="$(patrol_block "$OUT5")"

expect_no_match "23: a never-armed session prints no running line" "*session ${SHORT5}*" "$PB5"
expect_match    "24: the section falls back to none running" "*none running*" "$PB5"
expect_no_match "25: and a deliberate stop earns no fix line" \
  "*session ${SHORT5}: the Patrol*" "$OUT5"

section "Section 7: a firing Patrol with NO roster file and launches in the transcript"

# THE DEFECT THIS SECTION OWNS (Chris, 2026-08-29, on the 1.3.0 plugin):
# `/bionic:doctor` printed `✓ session 61be8dc9 · 0 open dispatches` while two
# agents were running. The launch-time hook was never registered in that
# session — hooks do not survive a continue, a /clear+resume or a
# /reload-plugins — so no roster file was ever written, and doctor rendered the
# ABSENCE of the record as the NUMBER zero. Every Patrol tick on that machine
# was emitting `NOTIFY wall-blind` at the same moment. lib/patrol.sh had both
# facts the whole time (`patrol-roster/v1 … present=no`, `patrol-wall/v1 …
# blind=N`); the renderer parsed the first, read neither, and printed a count
# nobody dispatched.
#
# THE ROW KEEPS ITS ✓. The Patrol IS running — that is what the stamp says and
# what running-or-nothing (F3) reports. The roster is the thing that is missing,
# and that is what the text now says.

SID7="ffffffff-1111-2222-3333-444455556666"
SHORT7="${SID7%%-*}"
spawn_live_pid; PID7="$LIVE_PID"
REPO7="$(make_repo_without_roster)"
HOME7="$(make_claude_home "$SID7" "$PID7" "$REPO7")"
TR7="$(transcript_of "$HOME7" "$SID7")"
plant_patrol_job "$TR7" "toolu_1" "abc12345"
plant_agent_dispatch "$TR7" "toolu_a1"
plant_agent_dispatch "$TR7" "toolu_a2"
plant_agent_dispatch "$TR7" "toolu_a3"
plant_patrol_stamp "$REPO7" "$SID7"

OUT7="$(run_doctor "$HOME7" "$REPO7")"
PB7="$(patrol_block "$OUT7")"

expect_match "27: an absent roster is rendered as absent, not as a count" \
  "*✓ session ${SHORT7} · roster absent — launches unrecorded*" "$PB7"
# THE ORIGINAL LIE, WALLED. Not "the number is right now" — the claim itself is
# withdrawn, because a session with no roster has no open-dispatch count to make.
expect_no_match "28: and the row makes no open-dispatch claim at all" \
  "*open dispatch*" "$PB7"
expect_match "29: the fix line names the unrostered launches and ends in the cure" \
  "*session ${SHORT7}: 3 launches unrostered → re-invoke /bionic:canonical-sdlc*" "$OUT7"

section "Section 8: a firing Patrol whose roster is PRESENT and incomplete"

# THE OTHER HALF, and what keeps Section 7's row honest: here the roster is
# real — one open dispatch, and the row still says exactly that — while the
# transcript carries three launches, so two of them never reached the wall. The
# roster is not absent, it is INCOMPLETE, and the count doctor prints stays the
# count it can stand behind. `blind = 3 launches - 1 rostered - 0 refused = 2`.

SID8="aaaaaaaa-9999-2222-3333-444455556666"
SHORT8="${SID8%%-*}"
spawn_live_pid; PID8="$LIVE_PID"
REPO8="$(make_repo_with_roster "$SID8" beta)"
HOME8="$(make_claude_home "$SID8" "$PID8" "$REPO8")"
TR8="$(transcript_of "$HOME8" "$SID8")"
plant_patrol_job "$TR8" "toolu_1" "abc12345"
plant_agent_dispatch "$TR8" "toolu_a1"
plant_agent_dispatch "$TR8" "toolu_a2"
plant_agent_dispatch "$TR8" "toolu_a3"
plant_patrol_stamp "$REPO8" "$SID8"

OUT8="$(run_doctor "$HOME8" "$REPO8")"
PB8="$(patrol_block "$OUT8")"

expect_match "30: a present roster still prints its own open count, unchanged" \
  "*✓ session ${SHORT8} · 1 open dispatch*" "$PB8"
expect_no_match "31: and a present roster is never re-rendered as absent" \
  "*roster absent*" "$PB8"
expect_match "32: the fix line reports only the launches the roster never saw" \
  "*session ${SHORT8}: 2 launches unrostered → re-invoke /bionic:canonical-sdlc*" "$OUT8"

section "Section 9: one cure, two surfaces — and the column budget"

# ONE CURE, ONE SURFACE NOW (bionic 1.4.0, slice ADOPT). This used to be a two-reader
# agreement: hooks/session-poker.sh decided `wall-blind` at tick time and named the
# repair, and doctor named the same repair hours later off the same `patrol-wall/v1`
# record. The tick's decision is retired — it inferred a dead dispatch wall from
# dispatches outnumbering roster rows, and always-on registration removes the condition
# that made that inference worth drawing — so there is no second speller left to agree
# with, and a pin against a deleted line would be a pin over air.
#
# What remains is worth pinning on its own: the cure doctor prints and the row it prints
# it beside come from ONE record, `patrol-wall/v1`, whose schema token lives in
# lib/patrol.sh. Both halves are asserted, so a doctor that stopped reading that record
# or a library that renamed it goes red.
lines_matching() {  # <text> <glob> -> the matching lines
  local line out=""
  while IFS= read -r line || [ -n "$line" ]; do
    # shellcheck disable=SC2053  # RHS is a glob on purpose
    if [[ "$line" == $2 ]]; then out="${out}${line}"$'\n'; fi
  done <<< "$1"
  printf '%s' "$out"
}

CURE='re-invoke /bionic:canonical-sdlc'
PATROL_LIB_TEXT="$(cat "${PAYLOAD}/scripts/lib/patrol.sh")"
DOCTOR_TEXT="$(cat "$DOCTOR_SH")"
# PINNED TO THE RECORD DOCTOR READS, not merely to the file that contains the phrase.
# An extraction that found nothing fails the match rather than passing it, which is what
# keeps this from becoming a pin over air.
DOCTOR_WALL_LINE="$(lines_matching "$DOCTOR_TEXT" '*patrol-wall/v1*')"
expect_match "33: payload/scripts/doctor.sh reads the patrol-wall/v1 record" \
  "*patrol-wall/v1*" "$DOCTOR_WALL_LINE"
expect_match "33b: …and lib/patrol.sh is where that schema token is defined" \
  "*PATROL_WALL_SCHEMA=\"patrol-wall/v1\"*" "$PATROL_LIB_TEXT"
expect_match "34: payload/scripts/doctor.sh spells the cure" "*${CURE}*" "$DOCTOR_TEXT"

# THE BUDGET, MEASURED WITH THE PRODUCT'S OWN RULER rather than by eye
# (lib/width.sh — `bionic_cols` counts COLUMNS, and every glyph on these rows is
# three bytes and one column wide). Sections 7 and 8 print the only rows and fix
# lines in the product that this suite is the first to produce;
# tests/doctor-version.test.sh walls the rest of the page but never drives a live
# Patrol, so nothing else measures these.
#
# THE RULER OVER-COUNTS `→` AND THAT IS THE SAFE DIRECTION. The arrow is not in
# lib/width.sh's closed glyph set, so each one measures three columns instead of
# one and a fix line carrying two of them is scored four columns wide. The
# effect is a wall that is stricter than the terminal, never looser — which is
# what that file's own header says the omission costs.
# shellcheck source=/dev/null
. "${PAYLOAD}/scripts/lib/width.sh"

first_over_budget() {  # <text> -> the first line wider than the budget, or empty
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if [ "$(bionic_cols "$line")" -gt "$BIONIC_LINE_WIDTH" ]; then printf '%s' "$line"; return 0; fi
  done <<< "$1"
  return 0
}

# TWO CAPTURES, SEPARATED BY A REAL NEWLINE. `$(...)` strips the trailing one,
# so gluing the two captures together concatenated the two fix lines into a
# single 152-column string and the budget check below failed on a line that does
# not exist — caught by this suite's own first green run.
NEW_FIX="$(lines_matching "$OUT7" '*launches unrostered*')
$(lines_matching "$OUT8" '*launches unrostered*')"

# THE POSITIVE THE WALL IS WORTHLESS WITHOUT: both fix lines really were
# produced, so the width check below is measuring text and not an empty string.
expect_match "35: both new fix lines were extracted for measurement" \
  "*3 launches unrostered*2 launches unrostered*" "$(printf '%s' "$NEW_FIX" | tr '\n' ' ')"

WIDE="$(first_over_budget "${PB7}
${PB8}
${NEW_FIX}")"
if [ -z "$WIDE" ]; then
  ok "36: every new Patrol row and fix line fits the ${BIONIC_LINE_WIDTH}-column budget"
else
  no "36: every new Patrol row and fix line fits the ${BIONIC_LINE_WIDTH}-column budget" \
     "$(bionic_cols "$WIDE") columns: ${WIDE}"
fi

section "Section 10: a firing Patrol with NO roster file and NOTHING dispatched"

# THE HEALTHY HALF OF `present=no`, and the reason Section 7's row is gated on a
# COUNT rather than on the file. The roster file is written by the FIRST
# dispatch — hooks/dispatch-preflight.sh appends its header and the first row
# together and nothing pre-creates it at session start — so a perfectly healthy
# session that has not dispatched anything yet has no roster file either. This
# fixture is Section 7's with exactly one thing removed: the three `Agent`
# tool_uses. `blind` is the field that separates the two (`agents - rostered -
# refused`), and a session with no launches has nothing unrecorded.
#
# 1.3.0 printed `0 open dispatches` here and that number was TRUE. This slice
# exists to stop doctor claiming a count nobody dispatched; saying "launches
# unrecorded" over a session that launched nothing is the same error pointed the
# other way. This section is the control that keeps the fix from overshooting,
# and it is why the absent row is gated on `blind > 0` rather than on
# `present = no`.

SID10="bbbbbbbb-7777-2222-3333-444455556666"
SHORT10="${SID10%%-*}"
spawn_live_pid; PID10="$LIVE_PID"
REPO10="$(make_repo_without_roster)"
HOME10="$(make_claude_home "$SID10" "$PID10" "$REPO10")"
TR10="$(transcript_of "$HOME10" "$SID10")"
plant_patrol_job "$TR10" "toolu_1" "abc12345"
# No plant_agent_dispatch call — the absence IS the variable under test.
plant_patrol_stamp "$REPO10" "$SID10"

OUT10="$(run_doctor "$HOME10" "$REPO10")"
PB10="$(patrol_block "$OUT10")"

expect_match "37: a session that dispatched nothing keeps its true zero" \
  "*✓ session ${SHORT10} · 0 open dispatches*" "$PB10"
expect_no_match "38: and is never described as a missing record" \
  "*roster absent*" "$PB10"
expect_no_match "39: nor earns an unrostered-launch fix line it cannot have" \
  "*session ${SHORT10}: * unrostered*" "$OUT10"

section "Section 11: two projects on one machine — doctor answers about ONE"

# THE DEFECT THIS SECTION OWNS (T3 finding 1, AC-35 drive, 2026-09-03). Doctor
# was driven cold in a session whose cwd was a probe project and printed a PATROL
# section naming `b1a850c1` (cwd this checkout) and `6c4fe341` (cwd a synthesis
# repo) — two sessions belonging to two OTHER projects — while the `active run`
# row three lines below it resolved the probe project's own plan. Both facts came
# off the same page, so the page contradicted itself about which machine it was
# describing.
#
# WHERE IT CAME FROM. `patrol_report` (lib/patrol.sh) walks every live session on
# the machine, and already computes for each one whether its repo is the caller's
# — it emits `here=yes|no` and has since it was written. doctor.sh's parse loop
# read `session=`, `open=`, `present=`, `blind=` and `state=`, and never `here=`
# or `cwd=`: the filter was not wrong, it was absent.
#
# THE ADDRESS IS `project_root`, NOT A STRING COMPARE. `lib/root.sh` is the SSoT
# every reader in this payload resolves a cwd through, and a session's recorded
# cwd is routinely a SUBDIRECTORY of its project — so session A below stands in
# `${REPO_A}/sub/deeper`, which only resolves onto the project doctor is
# diagnosing if the comparison goes through the library. A literal `cwd = root`
# test passes every other case in this file and fails this one.

SID_A="11111111-aaaa-2222-3333-444455556666"
SHORT_A="${SID_A%%-*}"
SID_B="22222222-bbbb-2222-3333-444455556666"
SHORT_B="${SID_B%%-*}"

spawn_live_pid; PID_A="$LIVE_PID"
spawn_live_pid; PID_B="$LIVE_PID"

# Project A — the one doctor is pointed at. One open dispatch, and the session
# sits two directories below the root.
REPO_A="$(make_repo_with_roster "$SID_A" beta -- alpha)"
mkdir -p "${REPO_A}/sub/deeper"
HOME_AB="$(make_claude_home "$SID_A" "$PID_A" "${REPO_A}/sub/deeper")"
TR_A="$(transcript_of "$HOME_AB" "$SID_A")"
plant_patrol_job "$TR_A" "toolu_a" "aaa11111"
plant_patrol_stamp "$REPO_A" "$SID_A"

# Project B — a second, entirely unrelated project on the same machine, with its
# own live session, its own firing Patrol, its own roster, and TWO Patrol jobs so
# that it would also emit a duplicate-Patrol fix line if doctor were listening.
REPO_B="$(make_repo_with_roster "$SID_B" gamma delta)"
jq -nc --arg sid "$SID_B" --argjson pid "$PID_B" --arg cwd "$REPO_B" \
  '{sessionId:$sid,pid:$pid,cwd:$cwd}' > "${HOME_AB}/sessions/${SID_B}.json"
: > "${HOME_AB}/projects/-fixture-proj/${SID_B}.jsonl"
TR_B="$(transcript_of "$HOME_AB" "$SID_B")"
plant_patrol_job "$TR_B" "toolu_b1" "bbb11111"
plant_patrol_job "$TR_B" "toolu_b2" "bbb22222"
plant_patrol_stamp "$REPO_B" "$SID_B"

OUT11="$(run_doctor "$HOME_AB" "$REPO_A")"
PB11="$(patrol_block "$OUT11")"

expect_match "40: the session belonging to THIS project prints, resolved from a subdirectory" \
  "*✓ session ${SHORT_A} · 1 open dispatch*" "$PB11"
expect_no_match "41: the other project's live session is not listed here" \
  "*session ${SHORT_B}*" "$PB11"
expect_no_match "42: nor does its duplicate-Patrol fix line reach this page" \
  "*CronDelete*bbb11111*" "$OUT11"
expect_no_match "43: and no row is attributed to the other project's roster" \
  "*2 open dispatches*" "$PB11"

section "Section 13: a NESTED .bionic below a git root — roster must resolve through project_root"
# ============================================================
# FIX-PATROL-ROOT (wave.plan.md Assumptions, FIX-DOCTOR/5). lib/patrol.sh's
# _patrol_repo_root asked git for --git-common-dir FIRST and walked for a
# nested `.bionic` only when no repository existed at all — the ordering
# lib/root.sh's own header names as the bug the other eight copies shared
# before this wave. A git repo holding a `.bionic` BELOW its root (spec AC-10,
# tests/root.test.sh §3) writes its roster under the nested `.bionic/tmp`
# while this resolver answered with the git toplevel — the roster read as
# absent and the session as blind. The session's own repo and doctor's
# `here_repo` both go through the same (buggy) resolver, so the "here" gate
# still agreed; what broke was finding the roster file at all.
SID13="ffffffff-1111-2222-3333-444455556666"
SHORT13="${SID13%%-*}"
spawn_live_pid; PID13="$LIVE_PID"

GITROOT13="$(mktemp -d -p "$TMP")"
git -c init.defaultBranch=main init -q "$GITROOT13" >/dev/null 2>&1
NESTED13="$GITROOT13/apps/inner"
mkdir -p "$NESTED13/.bionic/tmp"
roster_row_fixture status=intended session="$SID13" name=beta \
  > "$NESTED13/.bionic/tmp/roster-${SID13}.state"

HOME13="$(make_claude_home "$SID13" "$PID13" "$NESTED13")"
TR13="$(transcript_of "$HOME13" "$SID13")"
plant_patrol_job "$TR13" "toolu_13" "fff13131"
plant_patrol_stamp "$NESTED13" "$SID13"

OUT13="$(run_doctor "$HOME13" "$NESTED13")"
PB13="$(patrol_block "$OUT13")"

expect_match "46: a nested .bionic below the git root still finds its roster" \
  "*✓ session ${SHORT13} · 1 open dispatch*" "$PB13"

# ---- differential control: .bionic AT the git root resolves the same way ----
# Same shape, .bionic planted at the repo root instead of nested below it — the
# git root and project_root's answer already coincide here, so this passed
# before the fix too. Proves 46 is not vacuous: the harness can find a roster
# through this path, and the nested case above is what specifically breaks.
GITROOT13B="$(mktemp -d -p "$TMP")"
git -c init.defaultBranch=main init -q "$GITROOT13B" >/dev/null 2>&1
mkdir -p "$GITROOT13B/.bionic/tmp"
SID13B="00000000-1111-2222-3333-444455556666"
SHORT13B="${SID13B%%-*}"
spawn_live_pid; PID13B="$LIVE_PID"
roster_row_fixture status=intended session="$SID13B" name=beta \
  > "$GITROOT13B/.bionic/tmp/roster-${SID13B}.state"
HOME13B="$(make_claude_home "$SID13B" "$PID13B" "$GITROOT13B")"
TR13B="$(transcript_of "$HOME13B" "$SID13B")"
plant_patrol_job "$TR13B" "toolu_13b" "fff13132"
plant_patrol_stamp "$GITROOT13B" "$SID13B"

OUT13B="$(run_doctor "$HOME13B" "$GITROOT13B")"
PB13B="$(patrol_block "$OUT13B")"

expect_match "47: control — .bionic AT the git root still resolves" \
  "*✓ session ${SHORT13B} · 1 open dispatch*" "$PB13B"

# THE CONTROL, so 41-43 are not three negatives over an empty section. Pointed at
# project B, the same claude-home, the same two sessions, doctor answers about B
# and says nothing about A.
OUT12="$(run_doctor "$HOME_AB" "$REPO_B")"
PB12="$(patrol_block "$OUT12")"

expect_match "44: pointed at the other project, that project's session prints" \
  "*✓ session ${SHORT_B} · 2 open dispatches*" "$PB12"
expect_no_match "45: and the first project's session is now the one absent" \
  "*session ${SHORT_A}*" "$PB12"

section "Section 14: the engagement field — report only (T4/AC-16)"
# THE SAME SWITCH EVERY RUN-SCOPED HOOK READS FIRST (lib/run.sh
# `engaged_session`) — doctor's row says which side of it this session's
# marker is on, and changes nothing on disk: the `find | sort` fingerprint
# below is taken AFTER the fixture is fully built and BEFORE doctor runs, so
# any write doctor itself made would show up as a mismatch.

SID14="33333333-cccc-2222-3333-444455556666"
SHORT14="${SID14%%-*}"
spawn_live_pid; PID14="$LIVE_PID"
REPO14="$(make_repo_with_roster "$SID14" beta -- alpha)"
HOME14="$(make_claude_home "$SID14" "$PID14" "$REPO14")"
TR14="$(transcript_of "$HOME14" "$SID14")"
plant_patrol_job "$TR14" "toolu_14" "eee14141"
plant_patrol_stamp "$REPO14" "$SID14"
mkdir -p "$REPO14/.bionic/tmp"
: > "$REPO14/.bionic/tmp/engaged-${SID14}.state"
BEFORE14="$(find "$REPO14/.bionic" | sort)"

OUT14="$(run_doctor "$HOME14" "$REPO14")"
PB14="$(patrol_block "$OUT14")"

expect_match "48: an engaged session's row says so" \
  "*✓ session ${SHORT14} · 1 open dispatch · engaged*" "$PB14"
if [ "$BEFORE14" = "$(find "$REPO14/.bionic" | sort)" ]; then
  ok "49: doctor changed nothing on disk for an engaged session"
else
  no "49: doctor changed nothing on disk for an engaged session"
fi

SID15="44444444-dddd-2222-3333-444455556666"
SHORT15="${SID15%%-*}"
spawn_live_pid; PID15="$LIVE_PID"
REPO15="$(make_repo_with_roster "$SID15" beta -- alpha)"
HOME15="$(make_claude_home "$SID15" "$PID15" "$REPO15")"
TR15="$(transcript_of "$HOME15" "$SID15")"
plant_patrol_job "$TR15" "toolu_15" "eee15151"
plant_patrol_stamp "$REPO15" "$SID15"
BEFORE15="$(find "$REPO15/.bionic" | sort)"

OUT15="$(run_doctor "$HOME15" "$REPO15")"
PB15="$(patrol_block "$OUT15")"

expect_match "50: a session with no marker reads not engaged" \
  "*✓ session ${SHORT15} · 1 open dispatch · not engaged*" "$PB15"
if [ "$BEFORE15" = "$(find "$REPO15/.bionic" | sort)" ]; then
  ok "51: doctor changed nothing on disk for a not-engaged session"
else
  no "51: doctor changed nothing on disk for a not-engaged session"
fi

# The roster-absent row carries the field too — the two _patrol_add call
# sites under `firing)` share the one computed value, so neither can drift.
SID16="55555555-eeee-2222-3333-444455556666"
spawn_live_pid; PID16="$LIVE_PID"
REPO16="$(make_repo_without_roster)"
HOME16="$(make_claude_home "$SID16" "$PID16" "$REPO16")"
TR16="$(transcript_of "$HOME16" "$SID16")"
plant_patrol_job "$TR16" "toolu_16" "eee16161"
plant_agent_dispatch "$TR16" "toolu_a16"
plant_patrol_stamp "$REPO16" "$SID16"

OUT16="$(run_doctor "$HOME16" "$REPO16")"
PB16="$(patrol_block "$OUT16")"

expect_match "52: the roster-absent row carries the field too" \
  "*roster absent — launches unrecorded · not engaged*" "$PB16"

# THE COLUMN BUDGET, same ruler as Section 9 — bionic_cols/first_over_budget/
# BIONIC_LINE_WIDTH are already sourced above.
WIDE_ENG="$(first_over_budget "${PB14}
${PB15}
${PB16}")"
if [ -z "$WIDE_ENG" ]; then
  ok "53: every engaged/not-engaged row fits the ${BIONIC_LINE_WIDTH}-column budget"
else
  no "53: every engaged/not-engaged row fits the ${BIONIC_LINE_WIDTH}-column budget" \
    "line is $(bionic_cols "$WIDE_ENG") columns: $WIDE_ENG"
fi

section "Section 15: only a MET marker closes a row (Step-6 security review, out-of-axis 2)"

# FOUR READERS OF ONE SCHEMA DISAGREED ABOUT WHETHER `state=` MATTERS.
# hooks/session-start.sh's `open_rows` and the poker's `adopt_fold` require
# `state=MET` before a `landing-swept/v1` line closes a row; `patrol_roster_state`
# here and `youngest_suite_writer` in the poker took ANY marker at all. S17's
# `adopt_copy_marker` is a second writer that copies a predecessor's verdict —
# UNMET included — verbatim onto a successor's roster, so the two state-blind
# readers are exactly the two that now meet those markers. A row whose contract
# the sweep judged UNMET is open work by every other reader in the fleet, and
# doctor reporting it as closed is doctor reporting a wave as finished.

SID17="ffffffff-7777-2222-3333-444455556666"
SHORT17="${SID17%%-*}"
spawn_live_pid; PID17="$LIVE_PID"
REPO17="$(make_repo_with_roster "$SID17" -- closed-met)"
# The UNMET row, appended in the originator's exact shape beside the MET one.
ROSTER17="$REPO17/.bionic/tmp/roster-${SID17}.state"
roster_row_fixture status=intended session="$SID17" name=unmet-row >> "$ROSTER17"
swept_marker_write "$ROSTER17" 2026-08-27T00:00:01Z "$SID17" unmet-row a000 UNMET
HOME17="$(make_claude_home "$SID17" "$PID17" "$REPO17")"
TR17="$(transcript_of "$HOME17" "$SID17")"
plant_patrol_job "$TR17" "toolu_1" "abc17777"
plant_patrol_stamp "$REPO17" "$SID17"

OUT17="$(run_doctor "$HOME17" "$REPO17")"
PB17="$(patrol_block "$OUT17")"

expect_match "54: an UNMET marker leaves its row OPEN — one open dispatch, not zero" \
  "*✓ session ${SHORT17} · 1 open dispatch*" "$PB17"
expect_no_match "55: …and the MET row beside it is still closed (the count is 1, never 2)" \
  "*2 open dispatches*" "$PB17"

# THE PAIRED POSITIVE, on the same two-row roster: flip the UNMET marker to MET
# and the count falls to zero. Without it, "1 open" above is consistent with a
# reader that had simply stopped closing rows at all.
sed 's/|name=unmet-row|agent_id=a000|state=UNMET$/|name=unmet-row|agent_id=a000|state=MET/' \
  "$ROSTER17" > "$ROSTER17.met" && mv "$ROSTER17.met" "$ROSTER17"
OUT17B="$(run_doctor "$HOME17" "$REPO17")"
PB17B="$(patrol_block "$OUT17B")"
expect_match "56: …and flipping that same marker to MET closes it (54 discriminates)" \
  "*✓ session ${SHORT17} · 0 open dispatches*" "$PB17B"

section "Section 16: dead-session state — one collapsed line, one fix, no \"Nothing to do\" (1.5.1 T5, AC-8)"

# THE DEFECT THIS CLOSES, in its own shape (ideas/fixit-1.5.2-dead-session-sweep.md
# §Observed): a project whose predecessor sessions are all gone, whose `.bionic/tmp`
# holds their roster, preflight and engagement files, and whose doctor page listed
# them as informational dashes — or, for the ones whose rows had all landed, did not
# list them at all — under a header reading "Nothing to do".
#
# FIXTURE FIDELITY: the layout is the defect's, scaled down — three dead sessions
# with three classes each, one live session beside them, and `context-spend.state`,
# which carries no session id and must survive every reading. The residue case is
# the one that matters most: NONE of these rosters carries an open row, which is
# exactly the state the old open-row test rendered nothing for.
SID16_LIVE="e96260d1-6666-4666-8666-666666666666"
SID16_A="018c3ea1-1111-4111-8111-111111111111"
SID16_B="1dc72c57-2222-4222-8222-222222222222"
SID16_C="aa69dcad-3333-4333-8333-333333333333"

spawn_live_pid; PID16="$LIVE_PID"
REPO16="$(mktemp -d -p "$TMP")"
mkdir -p "$REPO16/.bionic/tmp"
for _s16 in "$SID16_A" "$SID16_B" "$SID16_C"; do
  printf '# bionic session roster — schema roster-state/v1 — machine-local, safe to delete\n' \
    > "$REPO16/.bionic/tmp/roster-${_s16}.state"
  printf 'preflight-attestation/v1|session=%s\n' "$_s16" \
    > "$REPO16/.bionic/tmp/preflight-${_s16}.state"
  printf 'engaged/v1|session=%s\n' "$_s16" \
    > "$REPO16/.bionic/tmp/engaged-${_s16}.state"
done
printf '# bionic session roster — schema roster-state/v1 — machine-local, safe to delete\n' \
  > "$REPO16/.bionic/tmp/roster-${SID16_LIVE}.state"
printf 'preflight-attestation/v1|session=%s\n' "$SID16_LIVE" \
  > "$REPO16/.bionic/tmp/preflight-${SID16_LIVE}.state"
printf 'context-spend/v1\n' > "$REPO16/.bionic/tmp/context-spend.state"

HOME16="$(make_claude_home "$SID16_LIVE" "$PID16" "$REPO16")"
OUT16="$(run_doctor "$HOME16" "$REPO16")"
PB16="$(patrol_block "$OUT16")"

# ONE LINE PER DEAD SESSION, counting files rather than open rows.
expect_match "57: a dead session with no open row still earns a line, and it counts files" \
  "*predecessor 018c3ea1*3 leftover files*" "$PB16"
expect_match "58: …so does the second" "*predecessor 1dc72c57*3 leftover files*" "$PB16"
expect_match "59: …and the residue session the defect was filed on" \
  "*predecessor aa69dcad*3 leftover files*" "$PB16"
expect_match "60: …and the line says what a reader can conclude, in words" \
  "*nothing open; the session is gone*" "$PB16"

# THE LIVE SESSION IS NOT ONE OF THEM — the paired positive that keeps the three
# rows above from passing on a page that simply lists every session it finds.
expect_no_match "61: the live session is never called a predecessor" \
  "*predecessor e96260d1*" "$PB16"

# COLLAPSED: a dead session costs the page ONE line, not one per section. Its
# attestation is gone from RESOURCES while the live session's remains.
DSR16="$(printf '%s\n' "$OUT16" | awk '/^RESOURCES$/{f=1;next} f && /^[A-Z][A-Z]/{exit} f')"
expect_no_match "62: a dead session's attestation is dropped from RESOURCES" \
  "*session 018c3ea1*" "$DSR16"
expect_no_match "63: …and so is the residue session's" "*session aa69dcad*" "$DSR16"
expect_match "64: …while the live session's attestation still renders there" \
  "*session e96260d1*" "$DSR16"

# THE FIX LINE, RENDERED FROM THE CHECK TABLE'S ROW — the count is doctor's, the
# verb is the row's.
expect_contains "65: the page names the repair once, with the count" \
  "3 dead sessions left state under .bionic/tmp" "$OUT16"
expect_contains "66: …and the verb comes from the check table's hint" \
  "session-poker.sh sweep" "$OUT16"
expect_absent "67: …and never sends the reader to setup, which has no project concept" \
  "dead sessions left state under .bionic/tmp → /bionic:setup" "$OUT16"
expect_absent "68: the header does not say there is nothing to do" \
  "Nothing to do" "$OUT16"

# CAUSATION, NOT COINCIDENCE. The fixture machine has unrelated problems of its
# own, so "no Nothing-to-do header" proves little on its own. Removing ONLY the
# dead sessions' files from the same tree must drop the fix line and lower the
# problem count by exactly one — which is what says this row, and not the
# machine's other trouble, is what put that line on the page.
# THE HEADER'S OWN COUNT, not a count of glyphs on the page. `N_FIX` is what
# decides between "Nothing to do" and "N problems", and it counts FIX LINES —
# the three collapsed rows are facts and are not among them. Counting `✗` would
# have counted the rows too, which is a different number and not the one the
# header is a function of.
n16_problems() {  # <doctor output> -> the header's problem count, or empty
  printf '%s\n' "$1" | sed -n 's/^→ \([0-9][0-9]*\) problems*\..*$/\1/p' | head -1
}
N16_BEFORE="$(n16_problems "$OUT16")"
rm -f "$REPO16/.bionic/tmp/"roster-018c3ea1*.state "$REPO16/.bionic/tmp/"preflight-018c3ea1*.state \
      "$REPO16/.bionic/tmp/"engaged-018c3ea1*.state \
      "$REPO16/.bionic/tmp/"roster-1dc72c57*.state "$REPO16/.bionic/tmp/"preflight-1dc72c57*.state \
      "$REPO16/.bionic/tmp/"engaged-1dc72c57*.state \
      "$REPO16/.bionic/tmp/"roster-aa69dcad*.state "$REPO16/.bionic/tmp/"preflight-aa69dcad*.state \
      "$REPO16/.bionic/tmp/"engaged-aa69dcad*.state
OUT16B="$(run_doctor "$HOME16" "$REPO16")"
N16_AFTER="$(n16_problems "$OUT16B")"

expect_absent "69: with the dead state gone, the fix line goes with it" \
  "dead sessions left state under .bionic/tmp" "$OUT16B"
expect_no_match "70: …and no predecessor line remains" "*predecessor *" "$(patrol_block "$OUT16B")"
expect_nonempty "71: the header states a problem count both times (72 is not vacuous)" "$N16_BEFORE"
expect_eq "72: …and it counts exactly one problem fewer without the dead state" \
  "$N16_BEFORE" "$((N16_AFTER + 1))"
expect_match "73: …while the live session's attestation is still there (69-72 are not an empty page)" \
  "*session e96260d1*" "$(printf '%s\n' "$OUT16B" | awk '/^RESOURCES$/{f=1;next} f && /^[A-Z][A-Z]/{exit} f')"
expect_true "74: …and the unkeyed context-spend.state was never the subject" \
  test -f "$REPO16/.bionic/tmp/context-spend.state"

finish
