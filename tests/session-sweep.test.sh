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
  sleep 100 &
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

finish
