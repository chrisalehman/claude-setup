#!/bin/bash
# Tests for hooks/session-poker.sh `sweep` — the verb that deletes what DEAD sessions left
# under a project's .bionic/tmp.
#
# Governing requirement: .bionic/docs/ideas/fixit-1.5.2-dead-session-sweep.md §Proposed fix
# and §Acceptance, ruled into fixit 1.5.1 as T5 (plan D-4, D-5; AC-9, AC-10, AC-11). The
# defect it closes: doctor proves a project's predecessor sessions dead, lists their
# leftover state, and names no way to clear it — so `.bionic/tmp` grows one set of files per
# `/clear`, forever, under a header reading "Nothing to do".
#
# THE SIBLING SUITE IS tests/session-poker.test.sh, which owns every other verb of the same
# script. `sweep` gets its own file because it is the one verb that DELETES: its cases all
# want a directory planted with state belonging to several sessions plus a live process to
# be dead against, and mixing that fixture into the tick's roster fixtures would leave both
# suites harder to read than either is now.
#
# Hermetic, same posture as tests/session-poker.test.sh and tests/session-sweeper.test.sh:
# every case runs inside a throwaway sandbox git repo under $TMPROOT. Nothing reads or
# writes the real .bionic/tmp, the real roster, or a live wave. The only machine-global fact
# any case consults is process liveness, and the process it consults is one this suite
# starts and kills itself.
#
# FIXTURE FIDELITY. The tmp layout is the one recorded in the defect report §Observed
# (six `roster-*.state`, six `preflight-*.state`, five `engaged-*.state`, one
# `context-spend.state`) and in .bionic/docs/record/prune-20260906/inventory.md §2 — the
# manual form of exactly this sweep, taken by hand against the same liveness oracle. File
# CONTENT is not fixture-critical here and is deliberately minimal: this verb decides from
# a filename and a pid, never from a line inside a state file, and a suite that planted
# realistic roster rows would imply otherwise.
#
# Usage: bash tests/session-sweep.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

# Overridable exactly as tests/session-poker.test.sh and tests/session-sweeper.test.sh offer
# theirs, so RED evidence can be taken against a MUTATED COPY without the shipped file ever
# being modified:
#   T5_POKER_UNDER_TEST=/tmp/mutant.sh bash tests/session-sweep.test.sh
POKER="${T5_POKER_UNDER_TEST:-${BIONIC_HOOKS_DIR}/session-poker.sh}"
TMPROOT="$(mktemp -d)"
LIVE_PIDS=""

cleanup() {
  local p
  for p in $LIVE_PIDS; do kill -9 "$p" 2>/dev/null; done
  chmod -R u+rwX "$TMPROOT" 2>/dev/null
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

# THE LOADER'S REGISTRY LANE, POINTED AT NOTHING — the same pin tests/session-poker.test.sh
# takes, for the same reason: a run that ever reached the CLI's plugin registry would be a
# run that failed to find the library beside the script, and an empty directory turns that
# into a visible failure instead of a silent read of this machine's real install.
export BIONIC_PLUGINS_DIR="$TMPROOT/no-plugins"
mkdir -p "$BIONIC_PLUGINS_DIR"

# fixture-fidelity: SHAPE-ONLY well-formed session ids. Only "well-formed, and distinct from
# each other" is load-bearing; the digits are arbitrary.
SID_LIVE="1a2b3c4d-1111-4e05-9f21-7d0c5a8e6b44"
SID_DEAD="5e6f7a8b-2222-42d6-b0e8-3c1f2a94d7e0"
SID_DEAD2="9c0d1e2f-3333-4a17-8b55-6e2d9f0a1c33"
SID_SELF="7f8e9d0c-4444-4b28-9a66-1d3c5e7f9b22"

expect_matches() { expect_regex "$@"; }

# ---------- fixture builders ----------

# A live process this machine's `kill -0` will actually find, the same way a real CLI
# session's pid does. SETS $LIVE_PID RATHER THAN PRINTING IT — a `$(...)` substitution runs
# in its own subshell and a background job started inside one dies with it (the measurement
# is recorded in tests/doctor-patrol.test.sh, whose builder this copies).
spawn_live_pid() {
  # 3600, not 100: the fixture must outlive the SUITE, not a case — under load this suite
  # has taken 323 s (tests-floor3, 2026-09-07), and a fake session whose process has exited
  # before the case that reads it is honestly reported dead (doctor-patrol case 44). The
  # EXIT trap kills every one of these; nothing waits on them.
  sleep 3600 &
  LIVE_PID=$!
  LIVE_PIDS="${LIVE_PIDS} ${LIVE_PID}"
}

make_repo() {  # <label> -> repo path
  local r="$TMPROOT/$1"
  mkdir -p "$r/.bionic/tmp"
  ( cd "$r" && git init -q . 2>/dev/null )
  printf '%s' "$r"
}

# A claude-home whose sessions/ names zero or more LIVE sessions — the one input
# patrol_live_sessions reads, and therefore the only thing that makes a session id "alive"
# for this verb.
# THE PID IS SPAWNED BY THE CALLER, NEVER IN HERE. This builder is called in a `$(...)`
# substitution, and a background job started inside one dies with the subshell — the exact
# measurement tests/doctor-patrol.test.sh records beside its own `spawn_live_pid`. Taking
# the pid as an argument is what keeps the process alive past the call that named it.
make_claude_home() {  # <label> <sid> <pid> -> claude-home path
  local h="$TMPROOT/home-$1"
  mkdir -p "$h/sessions"
  jq -nc --arg sid "$2" --argjson pid "$3" --arg cwd "$TMPROOT" \
    '{sessionId:$sid,pid:$pid,cwd:$cwd}' > "$h/sessions/${2}.json"
  printf '%s' "$h"
}

# A claude-home naming one LIVE session, pid and all. Sets $CLAUDE_HOME rather than printing
# it, for the reason above.
live_home() {  # <label> <sid> -> sets $CLAUDE_HOME
  spawn_live_pid
  CLAUDE_HOME="$(make_claude_home "$1" "$2" "$LIVE_PID")"
}

# The five session-keyed classes, planted for one session id. `patrol` gets its `.armed`
# sibling too — six files per session, the full set the verb has to reach.
plant_session() {  # <repo> <sid> [class...]
  local r="$1" sid="$2" c; shift 2
  [ $# -gt 0 ] || set -- roster preflight engaged sweeper patrol
  for c in "$@"; do
    printf '%s state for %s\n' "$c" "$sid" > "$r/.bionic/tmp/$c-$sid.state"
    [ "$c" = patrol ] \
      && printf 'patrol-armed/v1|session=%s\n' "$sid" > "$r/.bionic/tmp/patrol-$sid.state.armed"
  done
  return 0
}

# The three files under .bionic/tmp that carry NO session id, and which therefore no id this
# verb derives can ever address. Planted in every fixture that matters, because "untouched"
# is the assertion, and an assertion about a file that was never there proves nothing.
plant_unkeyed() {  # <repo>
  printf 'context-spend/v1\n' > "$1/.bionic/tmp/context-spend.state"
  printf 'farm-out/v1\n'      > "$1/.bionic/tmp/farm-out.state"
  printf 'stop-check/v1\n'    > "$1/.bionic/tmp/stop-check.state"
}

f_of() {  # <repo> <class> <sid> -> the path of one planted file
  printf '%s/.bionic/tmp/%s-%s.state' "$1" "$2" "$3"
}

# One invocation, from inside the repo, against a pinned claude-home and a pinned session
# key. Sets $OUT and $RC.
poke() {  # <repo> <claude-home> <session-key|-> [args...]
  local r="$1" h="$2" k="$3"; shift 3
  [ "$k" = "-" ] && k=""
  OUT="$( cd "$r" 2>/dev/null \
          && BIONIC_CLAUDE_HOME="$h" CLAUDE_CODE_SESSION_ID="$k" \
             bash "$POKER" "$@" 2>&1 )"
  RC=$?
}

expect_true "hooks/session-poker.sh exists" test -f "$POKER"

# =============================================================================
section "1. --report-only lists exactly the dead sessions' files, and writes nothing"
# =============================================================================
#
# AC-9's first half. The fixture is the defect's own: several sessions' state in one
# directory, one of them alive, plus the three unkeyed files.

R1="$(make_repo r1)"
live_home 1 "$SID_LIVE"; H1="$CLAUDE_HOME"
plant_session "$R1" "$SID_LIVE"
plant_session "$R1" "$SID_DEAD"
plant_session "$R1" "$SID_DEAD2"
plant_unkeyed "$R1"

poke "$R1" "$H1" "$SID_SELF" sweep --report-only

expect_eq "1.1 a report over dead state completes (exit 0)" "0" "$RC"
expect_contains "1.2 the first dead session is named dead"  "$SID_DEAD — dead"  "$OUT"
expect_contains "1.3 the second dead session is named dead" "$SID_DEAD2 — dead" "$OUT"
expect_contains "1.4 the live session is named live, and kept" "$SID_LIVE — live, kept" "$OUT"

expect_contains "1.5 a dead session's roster file is listed"    "$(f_of "$R1" roster "$SID_DEAD")"    "$OUT"
expect_contains "1.6 …its preflight file is listed"             "$(f_of "$R1" preflight "$SID_DEAD")" "$OUT"
expect_contains "1.7 …its engaged file is listed"               "$(f_of "$R1" engaged "$SID_DEAD")"   "$OUT"
expect_contains "1.8 …its sweeper file is listed"               "$(f_of "$R1" sweeper "$SID_DEAD")"   "$OUT"
expect_contains "1.9 …its patrol stamp is listed"               "$(f_of "$R1" patrol "$SID_DEAD")"    "$OUT"
expect_contains "1.10 …and the stamp's .armed sibling is listed" "$(f_of "$R1" patrol "$SID_DEAD").armed" "$OUT"

# NOTHING ELSE. The live session's files and the three unkeyed ones are the "and nothing
# else" half of AC-9, and they are asserted as PATHS rather than as ids — the live session's
# id does appear in the report, on its own kept line, which is the point of that line.
expect_absent "1.11 the live session's roster file is not listed"    "$(f_of "$R1" roster "$SID_LIVE")"    "$OUT"
expect_absent "1.12 the live session's preflight file is not listed" "$(f_of "$R1" preflight "$SID_LIVE")" "$OUT"
expect_absent "1.13 context-spend.state is not listed" "$R1/.bionic/tmp/context-spend.state" "$OUT"
expect_absent "1.14 farm-out.state is not listed"      "$R1/.bionic/tmp/farm-out.state"      "$OUT"
expect_absent "1.15 stop-check.state is not listed"    "$R1/.bionic/tmp/stop-check.state"    "$OUT"

expect_contains "1.16 the machine line reports the mode" "|mode=report-only|" "$OUT"
expect_contains "1.17 …and counts two dead sessions against one live" "|dead=2|live=1|" "$OUT"
expect_contains "1.18 …and removed nothing" "|removed=0|" "$OUT"
expect_contains "1.19 the tail says nothing was written" "nothing was written" "$OUT"

# A REPORT WRITES NOTHING. Every planted file is still on disk — the dead ones included,
# which is the assertion the mode exists for.
expect_true "1.20 a dead session's roster survives a report" test -f "$(f_of "$R1" roster "$SID_DEAD")"
expect_true "1.21 …its patrol .armed sibling survives too"   test -f "$(f_of "$R1" patrol "$SID_DEAD").armed"
expect_true "1.22 the second dead session's files survive"   test -f "$(f_of "$R1" sweeper "$SID_DEAD2")"
expect_true "1.23 the live session's files survive"          test -f "$(f_of "$R1" roster "$SID_LIVE")"
expect_true "1.24 context-spend.state survives"              test -f "$R1/.bionic/tmp/context-spend.state"

# =============================================================================
section "2. sweep removes the dead sessions' files and leaves everything else"
# =============================================================================
#
# AC-9's second half, over the identical fixture — so the two modes are compared on the same
# directory rather than on two that merely look alike.

R2="$(make_repo r2)"
live_home 2 "$SID_LIVE"; H2="$CLAUDE_HOME"
plant_session "$R2" "$SID_LIVE"
plant_session "$R2" "$SID_DEAD"
plant_session "$R2" "$SID_DEAD2"
plant_unkeyed "$R2"

poke "$R2" "$H2" "$SID_SELF" sweep

expect_eq "2.1 a sweep over dead state completes (exit 0)" "0" "$RC"
expect_contains "2.2 the machine line reports the mode"    "|mode=sweep|" "$OUT"
expect_contains "2.3 …and removes twelve files"            "|files=12|removed=12|" "$OUT"
expect_contains "2.4 the tail counts what it swept and what it kept" \
  "swept 12 file(s) across 2 dead session(s); 1 live session(s) kept." "$OUT"

# GONE — every class, both dead sessions.
expect_false "2.5 the first dead session's roster is gone"    test -e "$(f_of "$R2" roster "$SID_DEAD")"
expect_false "2.6 …its preflight is gone"                     test -e "$(f_of "$R2" preflight "$SID_DEAD")"
expect_false "2.7 …its engaged marker is gone"                test -e "$(f_of "$R2" engaged "$SID_DEAD")"
expect_false "2.8 …its ack ledger is gone"                    test -e "$(f_of "$R2" sweeper "$SID_DEAD")"
expect_false "2.9 …its patrol stamp is gone"                  test -e "$(f_of "$R2" patrol "$SID_DEAD")"
expect_false "2.10 …and the stamp's .armed sibling is gone"   test -e "$(f_of "$R2" patrol "$SID_DEAD").armed"
expect_false "2.11 the second dead session's roster is gone"  test -e "$(f_of "$R2" roster "$SID_DEAD2")"
expect_false "2.12 …and its patrol .armed sibling is gone"    test -e "$(f_of "$R2" patrol "$SID_DEAD2").armed"

# STILL THERE — the live session, and the three unkeyed files. Each negative above has its
# positive here: the same walk that removed twelve files left nine alone.
expect_true "2.13 the live session's roster survives"    test -f "$(f_of "$R2" roster "$SID_LIVE")"
expect_true "2.14 …its preflight survives"              test -f "$(f_of "$R2" preflight "$SID_LIVE")"
expect_true "2.15 …its engaged marker survives"         test -f "$(f_of "$R2" engaged "$SID_LIVE")"
expect_true "2.16 …its ack ledger survives"             test -f "$(f_of "$R2" sweeper "$SID_LIVE")"
expect_true "2.17 …its patrol stamp survives"           test -f "$(f_of "$R2" patrol "$SID_LIVE")"
expect_true "2.18 …and the stamp's .armed sibling survives" test -f "$(f_of "$R2" patrol "$SID_LIVE").armed"
expect_true "2.19 context-spend.state survives"         test -f "$R2/.bionic/tmp/context-spend.state"
expect_true "2.20 farm-out.state survives"              test -f "$R2/.bionic/tmp/farm-out.state"
expect_true "2.21 stop-check.state survives"            test -f "$R2/.bionic/tmp/stop-check.state"

# THE SECOND RUN OF THE DEFECT'S OWN ACCEPTANCE: after the sweep, the directory holds only
# the live session and the unkeyed files, so a re-run has nothing left it may remove.
poke "$R2" "$H2" "$SID_SELF" sweep
expect_eq "2.22 a second sweep finds only live state (exit 1)" "1" "$RC"
expect_contains "2.23 …and says so" "nothing swept" "$OUT"
expect_true "2.24 …having removed nothing on the second pass" test -f "$(f_of "$R2" roster "$SID_LIVE")"

# =============================================================================
section "3. a live session is refused: non-zero, nothing deleted, and it says why"
# =============================================================================
#
# AC-10's first half. The whole directory's state belongs to sessions the kernel says are
# alive, so there is nothing this verb may remove — the one answer that cannot be read off
# "0 files removed", which an empty directory would print too.

R3="$(make_repo r3)"
live_home 3 "$SID_LIVE"; H3="$CLAUDE_HOME"
plant_session "$R3" "$SID_LIVE"
plant_unkeyed "$R3"

poke "$R3" "$H3" "$SID_SELF" sweep

expect_eq "3.1 a live-only sweep exits non-zero" "1" "$RC"
expect_contains "3.2 …refusing out loud"        "REFUSED — nothing swept" "$OUT"
expect_contains "3.3 …naming liveness as the reason" "are LIVE" "$OUT"
expect_contains "3.4 …and naming the session it kept" "$SID_LIVE — live, kept" "$OUT"
expect_contains "3.5 the machine line counts one live session and no dead one" "|dead=0|live=1|" "$OUT"
expect_true "3.6 the live session's roster is untouched"   test -f "$(f_of "$R3" roster "$SID_LIVE")"
expect_true "3.7 …its patrol stamp is untouched"           test -f "$(f_of "$R3" patrol "$SID_LIVE")"
expect_true "3.8 …and its .armed sibling is untouched"     test -f "$(f_of "$R3" patrol "$SID_LIVE").armed"

# --report-only over the same state answers identically: the flag changes what is WRITTEN,
# never what is decided.
poke "$R3" "$H3" "$SID_SELF" sweep --report-only
expect_eq "3.9 --report-only over live-only state refuses the same way" "1" "$RC"
expect_contains "3.10 …with the same reason" "REFUSED — nothing swept" "$OUT"

# THE CURRENT SESSION IS LIVE BY CONSTRUCTION, even when the claude-home says nothing about
# it. A session running this verb must never sweep its own state out from under itself —
# and this is the arm that holds when jq is missing or ~/.claude/sessions is unreadable, the
# two ways patrol_live_sessions legitimately answers nothing.
R3B="$(make_repo r3b)"
H3B="$TMPROOT/home-empty"; mkdir -p "$H3B"
plant_session "$R3B" "$SID_SELF"
plant_session "$R3B" "$SID_DEAD"

poke "$R3B" "$H3B" "$SID_SELF" sweep
expect_eq "3.11 a sweep beside the caller's own state completes (exit 0)" "0" "$RC"
expect_true "3.12 the caller's own roster is never swept"  test -f "$(f_of "$R3B" roster "$SID_SELF")"
expect_true "3.13 …nor its own patrol stamp"               test -f "$(f_of "$R3B" patrol "$SID_SELF")"
expect_contains "3.14 …and it is named live, kept"         "$SID_SELF — live, kept" "$OUT"
expect_false "3.15 while the dead session beside it is swept" test -e "$(f_of "$R3B" roster "$SID_DEAD")"

# =============================================================================
section "4. a symlink at a target path is refused, not followed"
# =============================================================================
#
# AC-10's second half, and the sweeper's own hostile-repo posture: a link is not a file this
# script wrote, so it is neither followed nor unlinked. The decoy lives OUTSIDE .bionic/tmp,
# which is what makes "not followed" a claim about a file a link could reach.

R4="$(make_repo r4)"
live_home 4 "$SID_LIVE"; H4="$CLAUDE_HOME"
plant_session "$R4" "$SID_DEAD"
plant_session "$R4" "$SID_LIVE"
DECOY="$TMPROOT/decoy-outside-tmp.txt"
printf 'a file the sweep must never reach\n' > "$DECOY"
rm -f "$(f_of "$R4" roster "$SID_DEAD")"
ln -sf "$DECOY" "$(f_of "$R4" roster "$SID_DEAD")"

poke "$R4" "$H4" "$SID_SELF" sweep

expect_eq "4.1 a sweep carrying a symlinked target still completes (exit 0)" "0" "$RC"
expect_true  "4.2 the decoy outside .bionic/tmp is not followed"  test -f "$DECOY"
expect_true  "4.3 the symlink itself is left in place, not unlinked" test -L "$(f_of "$R4" roster "$SID_DEAD")"
expect_contains "4.4 …and the refusal is reported" "refused (symlink" "$OUT"
# The machine line ends at `refused=`, with no trailing delimiter — the same shape
# `adopt`'s own line has, so the needle stops there too.
expect_contains "4.5 the machine line counts one refusal" "|refused=1" "$OUT"
# PAIRED WITH THE POSITIVE: the same session's real files went, so the refusal is about the
# link and not about the session.
expect_false "4.6 the same dead session's real preflight file is still swept" \
  test -e "$(f_of "$R4" preflight "$SID_DEAD")"
expect_false "4.7 …and its real patrol stamp too" test -e "$(f_of "$R4" patrol "$SID_DEAD")"

# --report-only names the link as a refusal rather than as a file it would delete, so the
# report and the run agree about the same directory.
R4B="$(make_repo r4b)"
live_home 4b "$SID_LIVE"; H4B="$CLAUDE_HOME"
plant_session "$R4B" "$SID_DEAD"
rm -f "$(f_of "$R4B" roster "$SID_DEAD")"
ln -sf "$DECOY" "$(f_of "$R4B" roster "$SID_DEAD")"
poke "$R4B" "$H4B" "$SID_SELF" sweep --report-only
expect_contains "4.8 a report names the link as refused, not as a file to delete" \
  "refused (symlink" "$OUT"
expect_true "4.9 …and the decoy is still there afterwards" test -f "$DECOY"

# A .bionic/tmp THAT IS ITSELF A LINK IS REFUSED BEFORE THE WALK — the same guard the stamp
# writer takes, because a delete is a write.
R4C="$(make_repo r4c)"
rm -rf "$R4C/.bionic/tmp"
mkdir -p "$TMPROOT/elsewhere-tmp"
printf 'not ours\n' > "$TMPROOT/elsewhere-tmp/roster-$SID_DEAD.state"
ln -sf "$TMPROOT/elsewhere-tmp" "$R4C/.bionic/tmp"
poke "$R4C" "$H4B" "$SID_SELF" sweep
expect_eq "4.10 a symlinked .bionic/tmp is refused outright (exit 2)" "2" "$RC"
expect_true "4.11 …and the aimed-at file is untouched" \
  test -f "$TMPROOT/elsewhere-tmp/roster-$SID_DEAD.state"

# =============================================================================
section "5. every session-keyed class, and only those"
# =============================================================================
#
# The five classes are the verb's whole reach. A session that left only ONE of them behind
# is swept for that one — which is the shape the defect's own herd-app tmp had (six rosters,
# six preflights, five engaged markers: the counts do not line up, so no class may depend on
# another being present).

R5="$(make_repo r5)"
live_home 5 "$SID_LIVE"; H5="$CLAUDE_HOME"
plant_session "$R5" "$SID_DEAD" roster
plant_session "$R5" "$SID_DEAD2" engaged
plant_unkeyed "$R5"

poke "$R5" "$H5" "$SID_SELF" sweep
expect_eq "5.1 a sweep over one-class sessions completes (exit 0)" "0" "$RC"
expect_false "5.2 a session with only a roster is swept"  test -e "$(f_of "$R5" roster "$SID_DEAD")"
expect_false "5.3 a session with only an engaged marker is swept" test -e "$(f_of "$R5" engaged "$SID_DEAD2")"
expect_contains "5.4 both are counted dead" "|dead=2|" "$OUT"
expect_true "5.5 the unkeyed files are still untouched" test -f "$R5/.bionic/tmp/farm-out.state"

# AN EMPTY DIRECTORY IS NOT A REFUSAL. Nothing keyed to a session means nothing is being
# kept from anyone, so this is the 0 the live-only case is not.
R5B="$(make_repo r5b)"
plant_unkeyed "$R5B"
poke "$R5B" "$H5" "$SID_SELF" sweep
expect_eq "5.6 a tmp holding only unkeyed files sweeps nothing, and says so (exit 0)" "0" "$RC"
expect_contains "5.7 …naming what it looked for" "no session-keyed state" "$OUT"
expect_true "5.8 …with the unkeyed files still on disk" test -f "$R5B/.bionic/tmp/context-spend.state"

# NO .bionic/tmp AT ALL is the same answer, one sentence earlier.
R5C="$(make_repo r5c)"
rm -rf "$R5C/.bionic/tmp"
poke "$R5C" "$H5" "$SID_SELF" sweep
expect_eq "5.9 a project with no .bionic/tmp sweeps nothing (exit 0)" "0" "$RC"
expect_contains "5.10 …and says which directory it did not find" "no .bionic/tmp" "$OUT"

# =============================================================================
section "6. the surface: one verb, one flag, no operand, no engagement gate"
# =============================================================================
#
# D-4 approved `sweep` and `--report-only` and nothing else. These cases are what a later
# hand would have to delete deliberately in order to widen the surface.

R6="$(make_repo r6)"
live_home 6 "$SID_LIVE"; H6="$CLAUDE_HOME"
plant_session "$R6" "$SID_DEAD"

poke "$R6" "$H6" "$SID_SELF" sweep --bogus
expect_eq "6.1 an unknown flag is a usage error (exit 2)" "2" "$RC"
expect_contains "6.2 …naming the flag it did not know" "unknown flag for sweep" "$OUT"
expect_true "6.3 …having deleted nothing" test -f "$(f_of "$R6" roster "$SID_DEAD")"

poke "$R6" "$H6" "$SID_SELF" sweep "$SID_DEAD"
expect_eq "6.4 a session id operand is refused (exit 2)" "2" "$RC"
expect_true "6.5 …having deleted nothing" test -f "$(f_of "$R6" roster "$SID_DEAD")"

poke "$R6" "$H6" "$SID_SELF" sweep --report-only --report-only
expect_eq "6.6 a repeated flag is a usage error (exit 2)" "2" "$RC"
expect_contains "6.7 …saying the verb takes at most one flag" "at most one flag" "$OUT"

poke "$R6" "$H6" "$SID_SELF" nosuchverb
expect_contains "6.8 the usage block offers sweep beside the other verbs" \
  "session-poker.sh sweep" "$OUT"
expect_contains "6.9 …and offers its one flag" "sweep --report-only" "$OUT"

# NOT ENGAGEMENT-GATED (D-4). No `engaged-<sid>.state` exists for the caller in any fixture
# in this file — the marker is one of the files the verb REMOVES — so a sweep that behaved
# like `adopt` or `tick` would have answered NOT-ENGAGED in every case above. Asserted here
# once, explicitly, over a repo whose caller has no marker at all.
R6B="$(make_repo r6b)"
plant_session "$R6B" "$SID_DEAD"
poke "$R6B" "$H6" "$SID_SELF" sweep
expect_absent "6.10 a sweep never answers NOT-ENGAGED" "NOT-ENGAGED" "$OUT"
expect_false "6.11 …it sweeps for an unengaged caller" test -e "$(f_of "$R6B" roster "$SID_DEAD")"

# THE VERB WORKS WITHOUT A SESSION KEY AT ALL. It answers for the directory, not for a
# session, so the environment fact the other verbs exit 3 without is not required here.
R6C="$(make_repo r6c)"
plant_session "$R6C" "$SID_DEAD"
poke "$R6C" "$H6" "-" sweep
expect_eq "6.12 a sweep with no session key completes (exit 0)" "0" "$RC"
expect_false "6.13 …and sweeps the dead session" test -e "$(f_of "$R6C" roster "$SID_DEAD")"
expect_contains "6.14 …reporting no session of its own" "|session=none|" "$OUT"

# =============================================================================
section "7. session-start.sh's own silent auto-sweep (R2, ticket-30, AC-R2.1/2.2/2.3)"
# =============================================================================
#
# EVERYTHING ABOVE THIS SECTION drives `sweep` itself, directly, and stays exactly
# as it was (A-5: the verb is wired here, never rewritten). This section drives
# THE CALLER — hooks/session-start.sh — which is what actually decides WHETHER
# `sweep` runs at every session start, and adds one thing the verb itself does
# not have: an age gate, so a session dead one instant ago is not swept before
# anyone could read the predecessor report this same run just printed.
#
# NO wrap.sh / PPID DANCE (unlike tests/session-start.test.sh). This session's
# own liveness, for the sweep decision, is CLAUDE_CODE_SESSION_ID alone — the
# hook's wiring passes it to `patrol_dead_sessions` as an explicit also-live id,
# the same way `session-poker.sh sweep` protects its own caller — so a claude-home
# with no pid entry for it is enough; only the classes under test (a genuinely
# DEAD or LIVE *other* session) need the pid-file machinery `live_home` builds.
HOOK_SESSION_START="${BIONIC_HOOKS_DIR}/session-start.sh"
expect_true "hooks/session-start.sh exists" test -f "$HOOK_SESSION_START"

CUR_SELF="$SID_SELF"

ss_make_project() {  # <label> [poker-interval, default 1s] -> project dir
  local r="$TMPROOT/$1" interval="${2:-1s}"
  mkdir -p "$r/.bionic/tmp"
  ( cd "$r" && git init -q . 2>/dev/null )
  printf 'poker-interval: %s\n' "$interval" > "$r/.bionic/config.yaml"
  printf '%s' "$r"
}

# THE SAME BACKDATING IDIOM tests/dispatch-preflight.test.sh's `s21_backdate` and
# tests/cross-gate-agreement.test.sh's `s_backdate` use — portable across BSD and
# GNU `date`, and nothing here sleeps.
ss_backdate() {  # <file> <seconds ago>
  local ts
  ts="$(date -v-"$2"S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-$2 seconds" +%Y%m%d%H%M.%S)"
  touch -t "$ts" "$1"
}

# Drive the REAL hook (or a stubbed tree — see ss_plant_hook_tree below), against
# a chosen claude-home, as the named current session. Sets $OUT and $RC.
ss_drive_start() {  # <hook path> <repo> <claude-home> <cur sid> [extra env NAME=VALUE ...]
  local hook="$1" r="$2" h="$3" cur="$4"; shift 4
  OUT="$( cd "$r" \
          && printf '{"session_id":"%s","cwd":"%s","source":"startup"}' "$cur" "$r" \
          | env "$@" CLAUDE_CODE_SESSION_ID="$cur" BIONIC_CLAUDE_HOME="$h" \
                BIONIC_PLUGINS_DIR="$TMPROOT/no-plugins" \
                bash "$hook" 2>&1 )"
  RC=$?
}

section "7a. AC-R2.1 — a dead session, aged past the interval, is fully swept"

R7A="$(ss_make_project r7a 1s)"
H7A="$TMPROOT/home-r7a"; mkdir -p "$H7A/sessions"
plant_session "$R7A" "$SID_DEAD"
for f7a in "$R7A/.bionic/tmp/"*"-$SID_DEAD.state"*; do ss_backdate "$f7a" 5; done

ss_drive_start "$HOOK_SESSION_START" "$R7A" "$H7A" "$CUR_SELF"
expect_eq "7a.1 session-start still exits 0" "0" "$RC"
expect_false "7a.2 …its roster is gone"    test -e "$(f_of "$R7A" roster "$SID_DEAD")"
expect_false "7a.3 …its preflight is gone" test -e "$(f_of "$R7A" preflight "$SID_DEAD")"
expect_false "7a.4 …its engaged marker is gone" test -e "$(f_of "$R7A" engaged "$SID_DEAD")"
expect_false "7a.5 …its sweeper ledger is gone"  test -e "$(f_of "$R7A" sweeper "$SID_DEAD")"
expect_false "7a.6 …its patrol stamp is gone"    test -e "$(f_of "$R7A" patrol "$SID_DEAD")"
expect_false "7a.7 …and no sweep-failure marker was left behind" \
  test -e "$R7A/.bionic/tmp/sweep-failed.state"

section "7b. AC-R2.2 — a LIVE session's files survive a session start"

R7B="$(ss_make_project r7b 1s)"
live_home 7b "$SID_LIVE"; H7B="$CLAUDE_HOME"
plant_session "$R7B" "$SID_LIVE"
for f7b in "$R7B/.bionic/tmp/"*"-$SID_LIVE.state"*; do ss_backdate "$f7b" 5; done

ss_drive_start "$HOOK_SESSION_START" "$R7B" "$H7B" "$CUR_SELF"
expect_eq "7b.1 session-start exits 0" "0" "$RC"
expect_true "7b.2 the live session's roster survives"    test -f "$(f_of "$R7B" roster "$SID_LIVE")"
expect_true "7b.3 …its preflight survives"                test -f "$(f_of "$R7B" preflight "$SID_LIVE")"
expect_true "7b.4 …its patrol stamp survives"             test -f "$(f_of "$R7B" patrol "$SID_LIVE")"

section "7c. AC-R2.3 — files younger than one Patrol interval survive, even though the session is dead"

R7C="$(ss_make_project r7c 3600s)"
H7C="$TMPROOT/home-r7c"; mkdir -p "$H7C/sessions"
plant_session "$R7C" "$SID_DEAD"
# NOT backdated: fresh mtimes, well inside the (deliberately huge) 3600s interval.

ss_drive_start "$HOOK_SESSION_START" "$R7C" "$H7C" "$CUR_SELF"
expect_eq "7c.1 session-start exits 0" "0" "$RC"
expect_true "7c.2 a fresh dead session's roster survives (deferred, not swept)" \
  test -f "$(f_of "$R7C" roster "$SID_DEAD")"
expect_true "7c.3 …its preflight survives too"           test -f "$(f_of "$R7C" preflight "$SID_DEAD")"
expect_true "7c.4 …its patrol stamp survives too"        test -f "$(f_of "$R7C" patrol "$SID_DEAD")"
expect_false "7c.5 …and no sweep-failure marker either — nothing FAILED, it was deferred" \
  test -e "$R7C/.bionic/tmp/sweep-failed.state"

# THE PAIRED POSITIVE (anti-vacuity): the SAME dead session, backdated past the
# SAME interval, on a fresh copy of the fixture, is swept — so 7c above is
# proven to be the age gate and not a hook that never sweeps anything.
R7C2="$(ss_make_project r7c2 1s)"
H7C2="$TMPROOT/home-r7c2"; mkdir -p "$H7C2/sessions"
plant_session "$R7C2" "$SID_DEAD"
for f7c2 in "$R7C2/.bionic/tmp/"*"-$SID_DEAD.state"*; do ss_backdate "$f7c2" 5; done
ss_drive_start "$HOOK_SESSION_START" "$R7C2" "$H7C2" "$CUR_SELF"
expect_false "7c.6 …the paired positive: aged past a SHORT interval, it IS swept" \
  test -e "$(f_of "$R7C2" roster "$SID_DEAD")"

section "7d. the failure path — a marker is written, one line prints, and it clears on the next success"

# A STUBBED HOOK TREE, so `session-poker.sh sweep` answers something other than
# 0 or 1 — deterministically, without constructing a real refusal (sweep's own
# rc=2 causes — a symlinked .bionic/tmp, an unresolvable cwd — are either
# pre-empted by this hook's own guard before it would ever call sweep, or too
# machine-fragile to plant reliably). The stub is asked ONLY for `sweep`; every
# other verb this hook calls (`interval`, `interval-default`) gets a real,
# trivial answer so the age gate and the report above still behave normally.
ss_plant_hook_tree() {  # <root> <sweep-exit-code|"hang"> -> echoes <root>/hooks
  local root="$1" mode="$2" lib_src
  lib_src="${BIONIC_HOOKS_DIR}/../payload/scripts/lib"
  [ -d "$lib_src" ] || lib_src="${BIONIC_HOOKS_DIR}/../scripts/lib"
  mkdir -p "$root/hooks" "$root/scripts/lib"
  cp "$HOOK_SESSION_START" "$root/hooks/session-start.sh"
  cp "$lib_src"/*.sh "$root/scripts/lib/" 2>/dev/null
  {
    printf '#!/bin/bash\ncase "$1" in\n'
    printf '  interval|interval-default) echo 1; exit 0 ;;\n'
    if [ "$mode" = hang ]; then
      printf '  sweep) sleep 999 ;;\n'
    else
      printf '  sweep) exit %s ;;\n' "$mode"
    fi
    printf '  *) exit 0 ;;\nesac\n'
  } > "$root/hooks/session-poker.sh"
  chmod +x "$root/hooks/session-poker.sh"
  printf '%s' "$root/hooks"
}

# ---------- a genuine refusal (rc=2): marker written, one line, once ----------
R7D="$(ss_make_project r7d 1s)"
H7D="$TMPROOT/home-r7d"; mkdir -p "$H7D/sessions"
plant_session "$R7D" "$SID_DEAD" roster
ss_backdate "$(f_of "$R7D" roster "$SID_DEAD")" 5
HOOKS_R7D="$(ss_plant_hook_tree "$TMPROOT/tree-r7d" 2)"

ss_drive_start "$HOOKS_R7D/session-start.sh" "$R7D" "$H7D" "$CUR_SELF"
expect_eq "7d.1 session-start still exits 0 — a sweep failure never blocks a start" "0" "$RC"
expect_contains "7d.2 the one line names the failure and the rc" \
  "automatic dead-session sweep failed (rc=2)" "$OUT"
D7D_HITS="$(printf '%s\n' "$OUT" | grep -c 'automatic dead-session sweep failed')"
expect_eq "7d.3 …exactly once" "1" "$D7D_HITS"
expect_true "7d.4 a marker is left under .bionic/tmp" test -f "$R7D/.bionic/tmp/sweep-failed.state"
expect_contains "7d.5 …carrying the schema and the rc" "sweep-failed/v1" \
  "$(cat "$R7D/.bionic/tmp/sweep-failed.state")"
expect_contains "7d.6 …the rc field itself" "rc=2" "$(cat "$R7D/.bionic/tmp/sweep-failed.state")"

# ---------- bounded: a hung sweep is killed within its bound, not left to hang ----------
R7E="$(ss_make_project r7e 1s)"
H7E="$TMPROOT/home-r7e"; mkdir -p "$H7E/sessions"
plant_session "$R7E" "$SID_DEAD" roster
ss_backdate "$(f_of "$R7E" roster "$SID_DEAD")" 5
HOOKS_R7E="$(ss_plant_hook_tree "$TMPROOT/tree-r7e" hang)"

SS_T0="$(date -u +%s)"
ss_drive_start "$HOOKS_R7E/session-start.sh" "$R7E" "$H7E" "$CUR_SELF" BIONIC_SWEEP_BOUND_SECONDS=2
SS_T1="$(date -u +%s)"
SS_ELAPSED=$(( SS_T1 - SS_T0 ))
expect_eq "7e.1 session-start exits 0 even after killing a hung sweep" "0" "$RC"
expect_true "7e.2 the bound actually bound it — well under the sweep's own 999s sleep" \
  test "$SS_ELAPSED" -lt 30
expect_contains "7e.3 the failure line prints (a bounded timeout counts as a failure)" \
  "automatic dead-session sweep failed (rc=124)" "$OUT"
expect_true "7e.4 a marker is left" test -f "$R7E/.bionic/tmp/sweep-failed.state"

# ---------- success clears a marker a PAST failure left ----------
R7F="$(ss_make_project r7f 1s)"
H7F="$TMPROOT/home-r7f"; mkdir -p "$H7F/sessions"
printf 'sweep-failed/v1|at=2026-01-01T00:00:00Z|rc=2\n' > "$R7F/.bionic/tmp/sweep-failed.state"
# No dead session at all this time — the real, unstubbed hook, a clean sweep.
ss_drive_start "$HOOK_SESSION_START" "$R7F" "$H7F" "$CUR_SELF"
expect_eq "7f.1 session-start exits 0" "0" "$RC"
expect_false "7f.2 a stale failure marker is cleared the next time sweeping works" \
  test -e "$R7F/.bionic/tmp/sweep-failed.state"
expect_no_match "7f.3 …and nothing about a failure prints" \
  "*automatic dead-session sweep failed*" "$OUT"

section "7g. the age gate's COST: one stat call for the whole gate, not one per file"
# =============================================================================
#
# Step-6 review F-4. The gate above ran `stat` once per state file per dead session,
# and it ran BEFORE the bounded sweep rather than inside it — so its cost was neither
# bounded nor small. Measured by the reviewer: 400 dead sessions took 13.8 s against
# the 10-second timeout hooks/hooks.json registers for this hook, and
# BIONIC_SWEEP_BOUND_SECONDS defaults to that same 10, so the internal guard could
# never fire first. The user-visible consequence is not a slow sweep: the sweep is
# invoked AFTER the predecessor report is built, so a CLI timeout discards the report
# the hook exists to print, on exactly the residue-heavy project it is most useful on.
#
# PROCESS COUNTS, NOT A CLOCK. A wall-clock assertion on a machine running sibling
# agents measures the machine as much as the hook, and the margin between the two
# shapes at a fixture size a hermetic suite can afford is inside that noise. The
# `stat` execution count is deterministic, is the thing that actually changed, and is
# what the wall clock was a proxy for. The before/after timings themselves are
# measured and recorded in record/wave-01-plugin-only/s24-review-fixes.md rather than
# asserted here.

# A PATH SHIM that counts every `stat` the hook runs and then execs the real one.
SS_SHIM="$TMPROOT/shim"; mkdir -p "$SS_SHIM"
SS_STAT_LOG="$TMPROOT/stat-calls.log"
SS_REAL_STAT="$(command -v stat)"
{
  printf '#!/bin/bash\n'
  printf 'printf "x\\n" >> "%s"\n' "$SS_STAT_LOG"
  printf 'exec "%s" "$@"\n' "$SS_REAL_STAT"
} > "$SS_SHIM/stat"
chmod +x "$SS_SHIM/stat"

# N dead sessions, every file aged past the interval so the gate opens and the real
# sweep runs. 60 is enough to separate one-call-per-file (which would be ~720) from
# one-call-for-the-gate, and small enough that the fixture builds in well under a
# second.
ss_plant_dead_many() {  # <repo> <n> [class...]
  local r="$1" n="$2" i=0 sid; shift 2
  while [ "$i" -lt "$n" ]; do
    sid="$(printf 'dead-%04d-aaaa-bbbb-cccccccccccc' "$i")"
    plant_session "$r" "$sid" "$@"
    i=$(( i + 1 ))
  done
  for f in "$r/.bionic/tmp/"*.state "$r/.bionic/tmp/"*.armed; do
    [ -e "$f" ] && ss_backdate "$f" 60
  done
  return 0
}

R7G="$(ss_make_project r7g 1s)"
H7G="$TMPROOT/home-r7g"; mkdir -p "$H7G/sessions"
ss_plant_dead_many "$R7G" 60 roster preflight engaged sweeper patrol
SS_FILE_COUNT="$(ls "$R7G/.bionic/tmp/" | wc -l | tr -d ' ')"
SS_STAMPS="$(ls "$R7G/.bionic/tmp/"patrol-*.state 2>/dev/null | wc -l | tr -d ' ')"
expect_true "7g.0 the fixture really does carry hundreds of dead-session files" \
  test "$SS_FILE_COUNT" -ge 300

: > "$SS_STAT_LOG"
# THE BOUND HERE IS A HANG-CATCHER, NOT THE THING UNDER TEST. It used to be 2s,
# and that made 7g.4 a wall-clock assertion in disguise — plan A-47 already ruled
# those cannot hold. Measured on this machine at this fixture's exact size (60 dead
# sessions x 5 classes): the bounded sweep completes in ~2s idle and 4-5s beside
# eight busy siblings, so a 2-second bound killed it 3 times out of 3 under the
# 8-wide floor and left `sweep-failed.state` carrying `rc=124` — the bound's own
# timeout code, not a fault in anything this section measures. At 120s only a
# genuine hang trips it, and the hang path already has its own arm at 7e with a
# small bound, so nothing is given up. The `stat` COUNTS this section actually
# asserts are unaffected either way: the gate runs before the sweep, and the count
# was 61 with the sweep killed and 61 with it finishing.
ss_drive_start "$HOOK_SESSION_START" "$R7G" "$H7G" "$CUR_SELF" \
  "PATH=$SS_SHIM:$PATH" BIONIC_SWEEP_BOUND_SECONDS=120
SS_STATS="$(wc -l < "$SS_STAT_LOG" | tr -d ' ')"

expect_eq "7g.1 session-start still exits 0" "0" "$RC"

# THE BUDGET IS "ONE PER PATROL STAMP, PLUS A HANDFUL", and the stamps are not the
# gate's. This hook's predecessor-stamp loop reads one mtime per `patrol-*.state` to
# age it, and has done since before this wave (5740e3f:475) — it is outside F-4 and is
# not touched here. Everything ABOVE that floor was the age gate spending one process
# per state file per dead session: 360 of them at this fixture's size, against the 60
# the stamps account for. The budget refuses to let them come back.
expect_true "7g.2 the gate spends no stat per state file: $SS_STATS calls over $SS_FILE_COUNT files, against $SS_STAMPS pre-existing stamp reads" \
  test "$SS_STATS" -le "$(( SS_STAMPS + 5 ))"

# THE SAME SESSIONS, FEWER FILES EACH — the arm that names F-4's property directly and
# needs no clock to do it. `roster patrol` gives every dead session two classes instead
# of five, so the PATROL STAMP COUNT (the pre-existing per-stamp read) is identical and
# the only thing that changed is how many state files the gate would have had to visit.
# Before the fix that difference was ~180 processes; a gate that reads mtimes in one
# call cannot notice the difference at all.
R7G2="$(ss_make_project r7g2 1s)"
H7G2="$TMPROOT/home-r7g2"; mkdir -p "$H7G2/sessions"
ss_plant_dead_many "$R7G2" 60 roster patrol
SS_FILE_COUNT2="$(ls "$R7G2/.bionic/tmp/" | wc -l | tr -d ' ')"
SS_STAMPS2="$(ls "$R7G2/.bionic/tmp/"patrol-*.state 2>/dev/null | wc -l | tr -d ' ')"
: > "$SS_STAT_LOG"
ss_drive_start "$HOOK_SESSION_START" "$R7G2" "$H7G2" "$CUR_SELF" \
  "PATH=$SS_SHIM:$PATH" BIONIC_SWEEP_BOUND_SECONDS=120
SS_STATS2="$(wc -l < "$SS_STAT_LOG" | tr -d ' ')"

expect_eq "7g.2a the control fixture has the same stamp count, so only the file count differs" \
  "$SS_STAMPS" "$SS_STAMPS2"
expect_true "7g.2b …and the gate costs the same on $SS_FILE_COUNT files as on $SS_FILE_COUNT2 ($SS_STATS vs $SS_STATS2 stat calls)" \
  test "$(( SS_STATS - SS_STATS2 ))" -le 5

# THE MARKER IS THE SWEEP'S, NOT THE GATE'S — the gate is not inside the bound at
# all — so this arm says that the hook, at this size, reaches the end of a sweep
# instead of timing out of one. Under the old 2-second bound its old label ("the
# gate finished") named something it never measured.
expect_false "7g.4 …and no sweep-failure marker: the bounded sweep ran to the end, it was not killed" \
  test -e "$R7G/.bionic/tmp/sweep-failed.state"
expect_false "7g.5 …and the dead residue is actually gone, so the gate still OPENED" \
  test -e "$(f_of "$R7G" roster "dead-0000-aaaa-bbbb-cccccccccccc")"

# THE GATE STILL CLOSES ON A YOUNG FILE, at the same scale — the cheap version must
# not be cheap because it stopped looking. One fresh file among 60 aged sessions
# defers the whole batch, which is section 7c's rule at 7g's size.
R7H="$(ss_make_project r7h 3600s)"
H7H="$TMPROOT/home-r7h"; mkdir -p "$H7H/sessions"
ss_plant_dead_many "$R7H" 60 roster preflight engaged sweeper patrol
touch "$(f_of "$R7H" roster "dead-0059-aaaa-bbbb-cccccccccccc")"
ss_drive_start "$HOOK_SESSION_START" "$R7H" "$H7H" "$CUR_SELF"
expect_eq "7h.1 session-start exits 0" "0" "$RC"
expect_true "7h.2 one young file among 60 dead sessions still defers the whole batch" \
  test -f "$(f_of "$R7H" roster "dead-0000-aaaa-bbbb-cccccccccccc")"

section "7i. the gate reads mtimes on a GNU machine too, not only on a BSD one"
# =============================================================================
#
# Step-6 critic, issue 1. The gate's mtime read chose its `stat` flavour by asking
# whether the BSD form produced any output: `stat -f %m` first, and the GNU
# `-c %Y` form only if that came back EMPTY. GNU `stat` does not leave it empty.
# `-f` there is `--file-system`, so `%m` is read as a FILE operand: GNU complains
# about `%m` on stderr, still prints a full file-system report for the real files
# on STDOUT, and exits 1. The capture is therefore non-empty, the `-c %Y` arm is
# never reached, every captured line fails the numeric test, and the gate decides
# NOTHING IS YOUNG — so on Linux and WSL, both supported (README's install paths),
# session state seconds old was deleted at the next session start. That is the one
# failure mode the whole gate exists to prevent.
#
# THE SHIM, NOT A CONTAINER. This arm has to run on every machine the suite runs
# on, so the GNU behaviour is planted on PATH rather than borrowed from a Linux
# box: a `stat` that answers `-f` the way GNU answers it (a multi-line file-system
# dump on stdout, a complaint on stderr, exit 1) and answers `-c %Y` with the
# real mtimes. A gate that discriminates by FLAVOUR passes; a gate that
# discriminates by EMPTINESS cannot.
SS_GNU="$TMPROOT/gnu-shim"; mkdir -p "$SS_GNU"
# Whatever the REAL `stat` on this machine is, the shim has to be able to answer
# `-c %Y` truthfully — so its flavour is settled here, by the discriminating test,
# and baked in. (On the BSD host this suite normally runs on, `-c` is rejected.)
if [ -n "$(/usr/bin/stat -c %Y /dev/null 2>/dev/null | tr -dc '0-9')" ]; then
  SS_REAL_MTIME='/usr/bin/stat -c %Y'
else
  SS_REAL_MTIME='/usr/bin/stat -f %m'
fi
{
  printf '#!/bin/bash\n'
  printf 'REAL_MTIME="%s"\n' "$SS_REAL_MTIME"
  cat <<'SS_GNU_SHIM'
case "${1:-}" in
  -c)
    shift 2
    for f in "$@"; do $REAL_MTIME "$f"; done
    exit 0
    ;;
  -f)
    shift 2
    echo "stat: cannot read file system information for '%m': No such file or directory" >&2
    for f in "$@"; do
      printf '  File: "%s"\n' "$f"
      printf '    ID: 28d79cb6769f8344 Namelen: 255     Type: ext2/ext3\n'
      printf 'Block size: 4096       Fundamental block size: 4096\n'
      printf 'Blocks: Total: 58623224   Free: 54873547   Available: 51877439\n'
      printf 'Inodes: Total: 14966784   Free: 14381835\n'
    done
    exit 1
    ;;
esac
exec /usr/bin/stat "$@"
SS_GNU_SHIM
} > "$SS_GNU/stat"
chmod +x "$SS_GNU/stat"

# THE SHIM IS THE THING UNDER TEST TOO, so it is proven before it is trusted: it
# must answer `-f %m` the GNU way (dump on stdout, non-zero) and `-c %Y` with a
# number. Without this pair a shim that silently degraded to the real `stat`
# would make 7i.3 pass for the wrong reason.
SS_SHIM_F="$( "$SS_GNU/stat" -f %m /dev/null 2>/dev/null )"; SS_SHIM_F_RC=$?
expect_true "7i.0 the shim answers -f the GNU way: a file-system dump on stdout, not a number" \
  test -n "$SS_SHIM_F" -a "$SS_SHIM_F_RC" -ne 0
expect_no_match "7i.0a …and what it printed is not mtime-shaped" "*[0-9][0-9][0-9][0-9][0-9]*" \
  "$(printf '%s' "$SS_SHIM_F" | head -1)"
expect_match "7i.0b …while -c %Y answers with a number" "[0-9]*" \
  "$( "$SS_GNU/stat" -c %Y /dev/null )"

# 7c's fixture exactly — a dead session with FRESH mtimes against a 3600s interval,
# which must be deferred — driven with the GNU-shaped `stat` on PATH.
R7I="$(ss_make_project r7i 3600s)"
H7I="$TMPROOT/home-r7i"; mkdir -p "$H7I/sessions"
plant_session "$R7I" "$SID_DEAD"
ss_drive_start "$HOOK_SESSION_START" "$R7I" "$H7I" "$CUR_SELF" "PATH=$SS_GNU:$PATH"
expect_eq "7i.1 session-start exits 0 under a GNU-shaped stat" "0" "$RC"
expect_true "7i.2 a seconds-old dead session survives on a GNU machine (deferred, not swept)" \
  test -f "$(f_of "$R7I" roster "$SID_DEAD")"
expect_true "7i.3 …its patrol stamp survives too" \
  test -f "$(f_of "$R7I" patrol "$SID_DEAD")"

# THE PAIRED POSITIVE (anti-vacuity): the same GNU-shaped `stat`, the same hook,
# a dead session aged PAST a short interval — swept. So 7i.2 is the age gate
# reading real mtimes through the GNU form, not a hook that stopped sweeping the
# moment an unfamiliar `stat` appeared on PATH.
R7I2="$(ss_make_project r7i2 1s)"
H7I2="$TMPROOT/home-r7i2"; mkdir -p "$H7I2/sessions"
plant_session "$R7I2" "$SID_DEAD"
for f7i2 in "$R7I2/.bionic/tmp/"*"-$SID_DEAD.state"*; do ss_backdate "$f7i2" 60; done
ss_drive_start "$HOOK_SESSION_START" "$R7I2" "$H7I2" "$CUR_SELF" "PATH=$SS_GNU:$PATH"
expect_eq "7i.4 session-start exits 0" "0" "$RC"
expect_false "7i.5 …and an AGED dead session is still swept under the same GNU stat" \
  test -e "$(f_of "$R7I2" roster "$SID_DEAD")"

finish
