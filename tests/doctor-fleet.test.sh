#!/bin/bash
# tests/doctor-fleet.test.sh — doctor's RESOURCES section and the three run-scoped
# rows (bionic 1.4.0, wave-bionic-1.4.0-update slice DOCTOR handoff 5.3 and 1.4;
# spec AC-27, AC-4's doctor line, AC-8, AC-11).
#
# WHAT IS UNDER TEST, and why these four facts belong on one page.
#
#   RESOURCES (AC-27). The live probe — what this machine is right now — and,
#   per live session holding a preflight attestation in this project, the budget
#   that session is dispatching under. A version-1 attestation is the honest
#   record of a machine nobody measured (preflight-probe loads its resources
#   library fail-open, L-RESOURCES/3) and prints as "no budget recorded", never
#   as a budget of zeroes.
#
#   THE ACTIVE RUN (AC-8). `active_run` is the predicate every always-on hook
#   gates its own work behind. Doctor prints what that predicate sees — the plan,
#   its step, and how long since it was touched — so a person can tell a machine
#   whose walls are armed from one whose walls are inert.
#
#   PREDECESSOR ROSTERS (AC-4's doctor line). A `/clear` re-keys the session and
#   leaves the previous session's roster on disk with rows nobody will ever close.
#   Doctor lists them; the counting is doctor's own, through lib/patrol.sh's
#   `patrol_roster_state`, and never through the tick's adopt verb.
#
#   LEGACY .bionic SYMLINKS (AC-11). spawn-worktree.sh used to plant
#   `<wt>/.bionic -> <main>/.bionic`; lib/root.sh now steps over such a link and
#   never roots on it, so one left on disk is a silent second path to the same
#   state. Doctor lists them.
#
# HERMETIC, AND THE FIXTURE IS A WHOLE PROJECT. Doctor is run with its cwd inside
# a fixture project holding its own `.bionic/`, so `project_root` answers the
# fixture and nothing reads this checkout's real state. The "live" sessions are
# session files naming THIS test's own pid, which is alive by construction.
#
# Usage: bash tests/doctor-fleet.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/roster-row.sh"
. "$(dirname "$0")/lib/swept-marker.sh"

REPO="${BIONIC_SCRIPTS_DIR}"
PAYLOAD="${REPO}/payload"
DOCTOR_SH="${PAYLOAD}/scripts/doctor.sh"

command -v jq >/dev/null 2>&1 || { echo "doctor-fleet.test.sh: jq is required"; exit 1; }

TMP="$(mktemp -d /tmp/bionic-doctor-fleet.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

CHOME="${TMP}/claude-home"
mkdir -p "${CHOME}/plugins" "${CHOME}/sessions"
PROJ="${TMP}/proj"
mkdir -p "${PROJ}/.bionic/tmp" "${PROJ}/.bionic/docs/plans/w"
FIXTURE_RC="${TMP}/dot.zshrc"
: > "$FIXTURE_RC"

# THE SESSIONS ARE LIVE BECAUSE THEIR PID IS THIS PROCESS. `patrol_live_sessions`
# drops any session file whose pid does not answer `kill -0`, so a fabricated pid
# would make every case below vacuous.
LIVE_PID=$$
SID_V2="aaaaaaaa-1111-2222-3333-444444444444"
SID_V1="bbbbbbbb-5555-6666-7777-888888888888"
GONE_SID="cccccccc-9999-0000-1111-222222222222"

write_session() {  # <file-stem> <session-id> <pid>
  jq -nc --arg sid "$2" --arg cwd "$PROJ" --argjson pid "$3" \
    '{pid:$pid, sessionId:$sid, cwd:$cwd, startedAt:1788000000000, status:"busy"}' \
    > "${CHOME}/sessions/$1.json"
}

BUDGET="writers=22 suites=18 worktrees=32 test_jobs=18 source=probe"
write_attestation_v2() {  # <session-id>
  {
    printf '# bionic environment attestation — machine-local, safe to delete\n'
    printf 'version=2\nkind=preflight-attestation\n'
    printf 'session_id=%s\n' "$1"
    printf 'written_at=1788000000\nrepo=%s\n' "$PROJ"
    printf 'cores=18\nmem_gb=128\ndisk_free_gb=1663\nload_1m=2.28\nos=darwin\n'
    printf 'budget=%s\n' "$BUDGET"
  } > "${PROJ}/.bionic/tmp/preflight-$1.state"
}
write_attestation_v1() {  # <session-id>
  {
    printf '# bionic environment attestation — machine-local, safe to delete\n'
    printf 'version=1\nkind=preflight-attestation\n'
    printf 'session_id=%s\n' "$1"
    printf 'written_at=1788000000\nrepo=%s\n' "$PROJ"
  } > "${PROJ}/.bionic/tmp/preflight-$1.state"
}

# ─── The bin dir: real tools doctor legitimately needs, and nothing else ─────
#
# WHY PATH IS REPLACED, AND WHY THIS SUITE IS THE ONE THAT NEEDS IT. Doctor's
# THIRD PARTY table asks the machine's package managers what is installed —
# `brew`, `npm ls -g`, `npx`, `pnpm store path`, `uv tool list` — and those
# shell-outs are NOT under `BIONIC_DOCTOR_PROBE_SECONDS`, which bounds the
# plugin-registry probe and patrol, not the dependency roster. Measured on this
# machine with the full PATH: 32 seconds per run, 28 of them inside those five
# probes, times the SEVEN runs below. That is where "doctor-fleet hangs past
# five minutes" came from — not a blocked read but a real-machine roster walk
# that grows with whatever the machine happens to have installed, and grows
# again under load. Nothing in this file asserts a dependency row.
#
# So the fixture describes a machine carrying only base tools. Every package
# manager is off PATH, every dependency probe answers "not on PATH" immediately,
# and the run time stops being a function of this machine's software. The
# pattern and its reasoning are tests/fresh-home.test.sh's, which replaces PATH
# with a shim dir for the same reason.
#
# ─── THE TOOL DIRECTORY IS THE FIXTURE'S, NOT THE MACHINE'S (wave-01 S4, AC-7) ─
#
# WHAT THIS SUITE RENDERED USED TO DEPEND ON WHOSE LAPTOP RAN IT. doctor asks
# `command -v` about the nine `brew-dep` rows of BIONIC_DEP_TABLE, and six of
# them — node, gh, rg, uv, docker, aws — live under /opt/homebrew here and
# nowhere on a stripped PATH. Under the ambient PATH those rows are present;
# under `PATH=/usr/bin:/bin:/usr/sbin:/sbin` six more rows turn absent, the
# dependency roster this file pins shifts by six names, and an assertion fails
# on a page that is perfectly correct. `claude` is the same story one row over,
# and the one that used to hurt: with the CLI off PATH four `mcp-server` rows
# turn `unknown`.
#
# SO THE FIXTURE OWNS THE SET. Every program doctor RUNS is symlinked from the
# real one; every program doctor only ASKS ABOUT is an inert stub answering
# `--version`. PATH is REPLACED, never prepended, so nothing ambient is
# reachable — and `claude` is present or absent because this file says so,
# which is what makes the pair of directories below an experiment rather than
# a reflection of the machine.
_TOOLS_REAL="bash sh env cat grep sed awk mkdir rm cp mv chmod stat readlink ls tr head tail
sort uniq wc cut jq mktemp find xargs shasum uname date touch diff cmp printf true false
sleep dirname basename realpath id ps df sysctl vm_stat git strings"
_TOOLS_STUB="node pnpm gh rg uv docker aws"

make_tool_dir() {  # <dir> <claude: yes|no> -> prints the reals it could NOT find
  local d="$1" want="$2" t p missing=""
  mkdir -p "$d"
  for t in $_TOOLS_REAL; do
    if p="$(command -v "$t" 2>/dev/null)"; then ln -sf "$p" "${d}/${t}"
    else missing="${missing}${missing:+ }${t}"; fi
  done
  for t in $_TOOLS_STUB; do
    printf '#!/bin/sh\ncase "$1" in --version) echo 1.0.0 ;; esac\nexit 0\n' > "${d}/${t}"
    chmod +x "${d}/${t}"
  done
  # A CLI THAT ANSWERS "no such thing" to the one question doctor asks it —
  # `claude mcp get <name>` — which is what a real CLI answers on a machine
  # with no MCP server registered. Present-and-negative and absent are
  # different renders, and telling them apart is this suite's AC-7 pair.
  if [ "$want" = yes ]; then
    printf '#!/bin/sh\nexit 1\n' > "${d}/claude"; chmod +x "${d}/claude"
  else
    rm -f "${d}/claude"
  fi
  printf '%s' "$missing"
}

BIN="${TMP}/toolbox"
BIN_NO_CLAUDE="${TMP}/toolbox-no-claude"
_TOOLS_MISSING="$(make_tool_dir "$BIN" yes)$(make_tool_dir "$BIN_NO_CLAUDE" no)"
if [ -z "$_TOOLS_MISSING" ]; then ok "T0: the fixture's tool directory carries every program doctor runs"
else no "T0: a program doctor runs is missing from the fixture's tool directory" "$_TOOLS_MISSING"; fi

run_doctor() {
  ( cd "$PROJ" && HOME="$TMP" PATH="$BIN" BIONIC_SHELL_RC="$FIXTURE_RC" \
      BIONIC_CLAUDE_HOME="$CHOME" BIONIC_PLUGIN_ROOT="$PAYLOAD" \
      BIONIC_DOCTOR_PROBE_SECONDS=3 \
      bash "$DOCTOR_SH" < /dev/null 2>&1 )
}

run_doctor_no_claude() {  # the same machine with the CLI off PATH (AC-7)
  ( cd "$PROJ" && HOME="$TMP" PATH="$BIN_NO_CLAUDE" BIONIC_SHELL_RC="$FIXTURE_RC" \
      BIONIC_CLAUDE_HOME="$CHOME" BIONIC_PLUGIN_ROOT="$PAYLOAD" \
      BIONIC_DOCTOR_PROBE_SECONDS=3 \
      bash "$DOCTOR_SH" < /dev/null 2>&1 )
}

# doctor_section <output> <SECTION NAME> -> the lines under that heading in
# doctor's own rendered output. NOT the framework's section() banner (A-10c) --
# this is an output EXTRACTOR, renamed rather than deleted so every call site
# keeps working once the framework owns the name `section`.
doctor_section() {
  printf '%s\n' "$1" | awk -v h="$2" '
    $0 == h { on = 1; next }
    on && /^[A-Z][A-Z ]*$/ { on = 0 }
    on { print }'
}

section "Section 1: the live probe"

OUT1="$(run_doctor)"
RES1="$(doctor_section "$OUT1" "RESOURCES")"

expect_match "1: the section exists" "*machine*" "$RES1"
expect_match "2: it names cores, memory, free disk, load and os" \
  "*core*GB*free*load*" "$RES1"

section "Section 2: a version-2 attestation prints its recorded budget and source"

write_session "1001" "$SID_V2" "$LIVE_PID"
write_attestation_v2 "$SID_V2"

OUT2="$(run_doctor)"
RES2="$(doctor_section "$OUT2" "RESOURCES")"

expect_match "3: the session is named by its short id" "*${SID_V2%%-*}*" "$RES2"
expect_match "4: the budget is the recorded string, not a re-derivation" \
  "*writers=22 suites=18 worktrees=32 test_jobs=18*" "$RES2"
expect_match "5: and the source it was recorded with" "*source=probe*" "$RES2"

section "Section 3: a version-1 attestation records no budget, and says so"

write_session "1002" "$SID_V1" "$LIVE_PID"
write_attestation_v1 "$SID_V1"

OUT3="$(run_doctor)"
RES3="$(doctor_section "$OUT3" "RESOURCES")"

expect_match "6: the v1 session is named" "*${SID_V1%%-*}*" "$RES3"
expect_match "7: with the honest line, never a budget of zeroes" \
  "*${SID_V1%%-*}*no budget recorded*" "$RES3"
expect_no_match "8: and no fabricated writers count rides it" \
  "*${SID_V1%%-*}*writers=*" "$RES3"

section "Section 4: the active-run row"

# A plan the `active_run` predicate calls OPEN: a `## SDLC State` heading and a
# flush-left `current:` below 9.
cat > "${PROJ}/.bionic/docs/plans/w/wave.plan.md" <<'PLAN'
# a fixture plan

## SDLC State

integration-branch: main
current: 4
PLAN

OUT4="$(run_doctor)"

expect_match "9: the row names the plan the predicate resolved" "*active run*wave.plan.md*" "$OUT4"
expect_match "10: and the step it is on" "*active run*current: 4*" "$OUT4"

# Closed: step 9 with a delivered line. `active_run` refuses, and the row has to
# follow it rather than keep reporting a run nobody is in.
cat > "${PROJ}/.bionic/docs/plans/w/wave.plan.md" <<'PLAN'
# a fixture plan

## SDLC State

current: 9

- Step 9: delivered: 2026-09-02
PLAN

OUT5="$(run_doctor)"
expect_match "11: a closed run reads as no active run" "*active run*none*" "$OUT5"
expect_no_match "12: and does not quote a step" "*active run*current: 9*" "$OUT5"

section "Section 5: predecessor rosters with open rows"

# A roster belonging to a session that is NOT live: three dispatches intended,
# one swept closed by the landing gate, one never answered for, and one answered
# with a FAILED contract.
#
# THE MARKERS ARE THE ORIGINATOR'S EXACT SHAPE, and this is load-bearing rather
# than cosmetic. hooks/landing-gate.sh writes them from one printf —
# `landing-swept/v1|at=…|session=…|name=…|agent_id=…|state=…` — and
# `patrol_roster_state` decides closure by matching the `state=MET` FIELD, so a
# fixture marker missing `state=` is a line no writer in the fleet produces and
# no reader is obliged to honour. This fixture carried exactly that shape from
# the 1.4.0 doctor work; it read as "closed" only while the predicate ignored
# `state=`, and S21 (`6775c7d`) made `state=MET` the requirement at every reader
# at once. The suite then failed on the fixture, not on the code.
#
# THE UNMET ROW IS THE DISCRIMINATOR. With one MET, one unanswered and one UNMET
# the expected count is 2: a reader that ignored the MET marker would say 3, and
# one that closed on any marker at all would say 1. The count alone therefore
# pins both halves of the rule on the predecessor path, which renders through
# doctor's `_run_add` rather than through the live PATROL block that
# doctor-patrol.test.sh Section 15 covers.
{
  roster_header
  roster_row_fixture status=intended session="$GONE_SID" name=W-ALPHA agent_id= launched_at=x
  roster_row_fixture status=intended session="$GONE_SID" name=W-BETA  agent_id= launched_at=x
  roster_row_fixture status=intended session="$GONE_SID" name=W-GAMMA agent_id= launched_at=x
  swept_marker_write /dev/stdout 2026-09-02T00:00:01Z "$GONE_SID" W-ALPHA a000 MET
  swept_marker_write /dev/stdout 2026-09-02T00:00:02Z "$GONE_SID" W-GAMMA a001 UNMET
} > "${PROJ}/.bionic/tmp/roster-${GONE_SID}.state"

OUT6="$(run_doctor)"

expect_match "13: the predecessor roster is listed by its short id" \
  "*predecessor*${GONE_SID%%-*}*" "$OUT6"
expect_match "14: with the count of rows nobody closed — the MET row is not among them" \
  "*predecessor*2 open*" "$OUT6"
# THE PAIRED HALF, on the same roster: flip the UNMET verdict to MET and the
# count falls to 1. Without it, "2 open" above is equally consistent with a
# reader that had stopped closing rows altogether.
sed 's/|name=W-GAMMA|agent_id=a001|state=UNMET$/|name=W-GAMMA|agent_id=a001|state=MET/' \
  "${PROJ}/.bionic/tmp/roster-${GONE_SID}.state" > "${PROJ}/.bionic/tmp/roster.met" \
  && mv "${PROJ}/.bionic/tmp/roster.met" "${PROJ}/.bionic/tmp/roster-${GONE_SID}.state"
OUT6B="$(run_doctor)"
expect_match "14b: …and flipping that same marker to MET closes it (14 discriminates)" \
  "*predecessor*1 open row*" "$OUT6B"
# Restored to the two-open state the rest of the section reads.
sed 's/|name=W-GAMMA|agent_id=a001|state=MET$/|name=W-GAMMA|agent_id=a001|state=UNMET/' \
  "${PROJ}/.bionic/tmp/roster-${GONE_SID}.state" > "${PROJ}/.bionic/tmp/roster.unmet" \
  && mv "${PROJ}/.bionic/tmp/roster.unmet" "${PROJ}/.bionic/tmp/roster-${GONE_SID}.state"
# MATCHED PER LINE. A whole-output glob would happily span from the predecessor
# row down to the RESOURCES section, where a live session's short id legitimately
# appears — and pass or fail for the wrong reason.
PRED_LINES="$(printf '%s\n' "$OUT6" | awk '/predecessor/')"
expect_no_match "15: a LIVE session's roster is not called a predecessor" \
  "*${SID_V2%%-*}*" "$PRED_LINES"

section "Section 6: legacy .bionic symlinks under .worktrees/"

mkdir -p "${PROJ}/.worktrees/alpha" "${PROJ}/.worktrees/beta"
ln -s "${PROJ}/.bionic" "${PROJ}/.worktrees/alpha/.bionic"
mkdir -p "${PROJ}/.worktrees/beta/.bionic"   # a real directory is not a legacy link

OUT7="$(run_doctor)"

expect_match "16: the symlinked worktree is listed" "*legacy .bionic symlink*alpha*" "$OUT7"
expect_no_match "17: a real .bionic directory is not" "*legacy .bionic symlink*beta*" "$OUT7"
expect_match "18: and the row carries a repair" "*legacy .bionic symlink*1*" "$OUT7"

section "Section 6b: the attestation set is THIS PROJECT's, not the machine's"

# THE DEFECT THIS SECTION OWNS (T3 finding 2, AC-35 drive, 2026-09-03). Doctor
# printed `– no session · none has taken an attestation in this project` on a
# machine where `<proj>/.bionic/tmp/preflight-4241a5cd….state` was on disk, in
# that project, written forty minutes earlier by that project's own dispatch.
# The claim was false about the one directory it names.
#
# WHY IT WAS FALSE. The loop was keyed on LIVE SESSIONS — every live CLI process
# on the machine — and asked, for each, whether this project held an attestation
# under that session's id. A `/clear` re-keys the session, so the session that
# TOOK the attestation is routinely gone by the time anyone runs doctor, and its
# record then belongs to no live id. Two wrong sets at once: sessions from other
# projects were iterated (and only ever missed because their ids do not name a
# file here), and this project's own records were dropped the moment their writer
# exited.
#
# THE SET IS THE FILES. `${root}/.bionic/tmp/preflight-*.state` is what the
# fallback line is a claim about, so it is what the loop reads — bounded to this
# project by its own path, and indifferent to whether the writer is still running.

GONE_ATT_SID="dddddddd-3333-4444-5555-666677778888"
write_attestation_v2 "$GONE_ATT_SID"   # …and NO session file: its writer is gone

# A second project on the same machine, with its own attestation, which must not
# reach this page.
OTHER="${TMP}/other-proj"
mkdir -p "${OTHER}/.bionic/tmp"
OTHER_SID="eeeeeeee-3333-4444-5555-666677778888"
{
  printf '# bionic environment attestation — machine-local, safe to delete\n'
  printf 'version=2\nkind=preflight-attestation\n'
  printf 'session_id=%s\n' "$OTHER_SID"
  printf 'written_at=1788000000\nrepo=%s\n' "$OTHER"
  printf 'cores=18\nmem_gb=128\ndisk_free_gb=1663\nload_1m=2.28\nos=darwin\n'
  printf 'budget=writers=99 suites=99 worktrees=99 test_jobs=99 source=probe\n'
} > "${OTHER}/.bionic/tmp/preflight-${OTHER_SID}.state"
jq -nc --arg sid "$OTHER_SID" --arg cwd "$OTHER" --argjson pid "$LIVE_PID" \
  '{pid:$pid, sessionId:$sid, cwd:$cwd, startedAt:1788000000000, status:"busy"}' \
  > "${CHOME}/sessions/1003.json"

OUT6B="$(run_doctor)"
RES6B="$(doctor_section "$OUT6B" "RESOURCES")"

# RE-POINTED AT 1.5.1 T5, GUARDING THE SAME THING THROUGH THE NEW RENDERING.
# What this case has always defended is that a record of THIS project is not
# dropped the instant its writer exits — the page must not go silent about a file
# that is sitting in the directory. It defended that by pinning the dead writer's
# BUDGET row in RESOURCES, and 1.5.1 moved where the fact lands: a session whose
# owner is gone is now one line in PATROL naming its leftover files, and the fix
# line there names the verb that clears them, so the same file is reported once
# instead of once per section (defect fixit-1.5.2-dead-session-sweep.md; plan
# T5). The budget itself is deliberately no longer rendered as a current one —
# "a budget taken two days ago by a session that no longer exists" reading as
# this machine's live capacity is the second half of that defect.
#
# So: still on the page, no longer as a live budget. Both halves asserted, since
# either alone is satisfied by a bug — the first by a page that prints everything
# twice, the second by a page that dropped the file silently.
expect_match "18b: an attestation whose writer has exited is still this project's record" \
  "*predecessor ${GONE_ATT_SID%%-*}*" "$OUT6B"
expect_no_match "18b2: …and its stale budget no longer renders as a live one" \
  "*${GONE_ATT_SID%%-*}*writers=22*" "$RES6B"
expect_no_match "18c: another project's attestation never reaches this page" \
  "*${OTHER_SID%%-*}*" "$RES6B"
expect_no_match "18d: nor its budget numbers" "*writers=99*" "$RES6B"
expect_no_match "18e: and the page does not claim the project has no attestation" \
  "*none has taken an attestation*" "$RES6B"

# THE POSITIVE THE FALLBACK LINE IS STILL TRUE FOR: a project holding no
# attestation file at all, with the same live sessions on the machine.
BARE="${TMP}/bare-proj"
mkdir -p "${BARE}/.bionic/tmp"
OUT6C="$( cd "$BARE" && HOME="$TMP" PATH="$BIN" BIONIC_SHELL_RC="$FIXTURE_RC" \
  BIONIC_CLAUDE_HOME="$CHOME" BIONIC_PLUGIN_ROOT="$PAYLOAD" \
  BIONIC_DOCTOR_PROBE_SECONDS=3 bash "$DOCTOR_SH" < /dev/null 2>&1 )"
RES6C="$(doctor_section "$OUT6C" "RESOURCES")"
expect_match "18f: a project with no attestation still says so" \
  "*none has taken an attestation in this project*" "$RES6C"

# AND THE THIRD STATE, WHICH 1.5.1 CREATED: a project holding attestations whose
# sessions are ALL gone. Before the collapse those rendered a row each, so the
# fallback could not fire; after it, this is the page that would have said "none
# has taken an attestation in this project" over a directory holding two of them
# — the exact sentence T3 finding 2 was filed on. The line has to say what is
# actually there instead.
DEADONLY="${TMP}/deadonly-proj"
mkdir -p "${DEADONLY}/.bionic/tmp"
for _dsid in "aaaa1111-9999-4444-5555-666677778888" "bbbb2222-9999-4444-5555-666677778888"; do
  {
    printf '# bionic environment attestation — machine-local, safe to delete\n'
    printf 'version=2\nkind=preflight-attestation\n'
    printf 'session_id=%s\n' "$_dsid"
    printf 'written_at=1788000000\nrepo=%s\n' "$DEADONLY"
    printf 'cores=18\nmem_gb=128\ndisk_free_gb=1663\nload_1m=2.28\nos=darwin\n'
    printf 'budget=writers=77 suites=77 worktrees=77 test_jobs=77 source=probe\n'
  } > "${DEADONLY}/.bionic/tmp/preflight-${_dsid}.state"
done
OUT6D="$( cd "$DEADONLY" && HOME="$TMP" PATH="$BIN" BIONIC_SHELL_RC="$FIXTURE_RC" \
  BIONIC_CLAUDE_HOME="$CHOME" BIONIC_PLUGIN_ROOT="$PAYLOAD" \
  BIONIC_DOCTOR_PROBE_SECONDS=3 bash "$DOCTOR_SH" < /dev/null 2>&1 )"
RES6D="$(doctor_section "$OUT6D" "RESOURCES")"
expect_no_match "18g: a project whose every attestation is dead never claims it has none" \
  "*none has taken an attestation in this project*" "$RES6D"
expect_match "18h: …it counts them and sends the reader to the section that names the repair" \
  "*2 attestations here, every one from a session that is gone*" "$RES6D"
expect_no_match "18i: …and still does not render their budgets as live capacity" \
  "*writers=77*" "$RES6D"
expect_contains "18j: …while the page names the verb that clears them" \
  "session-poker.sh sweep" "$OUT6D"

section "Section 7: the column budget"

too_wide() {
  printf '%s\n' "$1" | awk '
    { s = $0
      gsub(/✓|✗|–|—|≥|…|·|→|•/, ".", s)
      if (length(s) > 100) print length(s) ": " $0 }'
}
_over="$(too_wide "${OUT7}
${OUT6B}")"
if [ -z "$_over" ]; then ok "20: every line of the fullest run fits 100 columns"
else no "20: a line exceeds 100 columns" "$_over"; fi


section "Section 8: the claude CLI absent, and present, on one fixture (AC-7)"

# THE PAIR IS THE POINT, AND IT IS THE STATE THAT USED TO BREAK THIS SUITE.
# `claude` is the one program on the fixture's PATH whose presence changes what
# this page says: the four `mcp-server` rows are checked with `claude mcp get`,
# so with the CLI gone they turn from a plain absence into an UNKNOWN with a
# cause, and one of the fix lines that renders from that cause measured 105
# columns. Before the tool directory above, which half a run got was whatever
# the runner's PATH happened to hold. Now the fixture says, and both halves are
# asserted here — the absent render, and the present one that proves the absent
# assertion is not matching everything.
OUT_NOCLI="$(run_doctor_no_claude)"
OUT_WITHCLI="$(run_doctor)"

expect_match "21.1: with the CLI off PATH, an MCP row names that as the cause"   "*chrome-devtools*the claude CLI is not on PATH*" "$OUT_NOCLI"
expect_no_match "21.2: …and with the CLI present that cause is nowhere on the page"   "*the claude CLI is not on PATH*" "$OUT_WITHCLI"
expect_match "21.3: …which answers the same row from the CLI instead (the pair is not vacuous)"   "*chrome-devtools*not installed*" "$OUT_WITHCLI"
_over="$(too_wide "$OUT_NOCLI")"
if [ -z "$_over" ]; then ok "21.4: the CLI-absent page still fits 100 columns"
else no "21.4: a line of the CLI-absent page exceeds 100 columns" "$_over"; fi

finish
