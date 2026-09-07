#!/bin/bash
# Tests for hooks/session-start.sh — THE POST-`/clear` DETECTOR (bionic 1.4.0,
# spec AC-1, AC-4's "the block runs the report", AC-11's symlink listing; plan
# slice SSTART).
#
# THE CONTRACT UNDER TEST. `/clear` re-keys the session id in place (probe
# A-probe-1/2/3: env, payload and `sessions/<pid>.json` all move together, same
# pid, same process) and leaves the PREVIOUS conversation's state on disk beside
# the new session's: a roster with open rows nobody owns any more, a patrol stamp
# under the old sid, and — until the ritual runs — a live predecessor cron
# (A-probe-4, which FIRED into the new conversation 13 minutes late). None of that
# announces itself. This hook is the announcement, and nothing more: it prints one
# block on stdout, which a SessionStart hook's stdout puts into the new
# conversation's context, and it arms, writes and refuses nothing.
#
# WHY EVERY ASSERTION BELOW ALSO CHECKS `writes nothing`. A detector that stamped
# would satisfy the arming wall over a cron table that holds nothing — the exact
# inversion tests/patrol-revive.test.sh was written to prevent one file over. The
# `snap` helper fingerprints the whole `.bionic` subtree (paths and mtimes) before
# and after every drive, so a write of any kind — including a poker subprocess
# that stamped on the way past — fails the group that caused it.
#
# ACCELERATED CLOCK, NEVER A WAIT. Staleness is manufactured by backdating the
# stamp's mtime against a tiny `poker-interval:` in the fixture's own config —
# the `s21_backdate` idiom of tests/dispatch-preflight.test.sh, borrowed through
# tests/patrol-revive.test.sh. Nothing here sleeps.
#
# THE PID FILE IS DRIVEN, NOT ASSUMED. The hook reads `<claude-home>/sessions/
# $PPID.json`, and its parent is whatever launched it, so the fixtures launch it
# through `wrap.sh`, which writes its own `$$` into a fixture claude-home and then
# runs the hook as a CHILD (never `exec`, which would make the hook's parent the
# wrapper's parent instead). BIONIC_CLAUDE_HOME redirects the home, the same knob
# payload/scripts/lib/patrol.sh already reads.
#
# Usage: bash tests/session-start.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/bound-marker.sh"
. "$(dirname "$0")/lib/roster-row.sh"
. "$(dirname "$0")/lib/swept-marker.sh"

HOOK="${BIONIC_SESSION_START_UNDER_TEST:-${BIONIC_HOOKS_DIR}/session-start.sh}"

eq()  { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else no "$1" "missing '$2' in: $3"; fi; }
hasnt() { if printf '%s' "$3" | grep -qF -- "$2"; then no "$1" "unexpected '$2' in: $3"; else ok "$1"; fi; }

command -v jq >/dev/null 2>&1 || { echo "session-start: jq absent — suite cannot run"; exit 1; }

# THE SUITE IS NOT ALLOWED TO BE VACUOUS. Most assertions below read "rc 0 and no
# stdout", which is exactly what a MISSING hook produces once the shell's 127 is
# discarded. Prove the subject exists and parses before any of it runs.
[ -f "$HOOK" ] || { echo "session-start: no hook at $HOOK — suite refuses to run"; exit 1; }
bash -n "$HOOK" || { echo "session-start: $HOOK does not parse — suite refuses to run"; exit 1; }

CUR_SID="11111111-2222-3333-4444-555555555555"
OLD_SID="99999999-8888-7777-6666-555555555555"
OLD2_SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
PAY_SID="77777777-6666-5555-4444-333333333333"

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------- fixture builders ----------

# A scratch project carrying `.bionic/tmp` and a TINY poker-interval, so twice the
# interval is two seconds and a backdated stamp is decisively stale with no wait.
# No git repository: project_root's walk answers at the nearest ancestor carrying
# a real `.bionic/`, which is this directory itself.
make_env() {  # [interval] -> project dir on stdout
  local dir; dir=$(mktemp -d "$WORK/proj.XXXXXX")
  mkdir -p "$dir/.bionic/tmp"
  printf 'poker-interval: %s\n' "${1:-1s}" > "$dir/.bionic/config.yaml"
  printf '%s' "$dir"
}

# A roster row per status transition, exactly as hooks/session-poker.sh's wall and
# hooks/execution-recorder.sh append them: `intended`, then `identified`, then
# `confirmed` for one name. Open rows are counted BY NAME, so three rows for one
# agent are one open row — a counter that counted lines would read 3 here.
roster_rows() {  # <file> <sid> <name>
  local f="$1" sid="$2" n="$3" st
  for st in intended identified confirmed; do
    roster_row_fixture status="$st" session="$sid" name="$n" \
      agent_id="a$n-1111111111111111" launched_at=2026-09-02T20:00:00Z model= \
      deliverable=".bionic/docs/record/$n.md" >> "$f"
  done
}

# THROUGH THE ONE WRITER (S17, spec AC-26): `swept_marker_write` is
# hooks/landing-gate.sh's own function, extracted by tests/lib/swept-marker.sh and called
# for real. The printf that used to sit here wrote a marker the originator would not
# recognise — no `session=`, no `agent_id=` — and stayed green because every reader of the
# marker is by key.
#
# The old spelling here also REORDERED the fields (`name=` before `state=` before `at=`),
# which no reader noticed and no writer has ever produced.
swept() {  # <file> <sid> <name>   the landing gate's closing marker
  swept_marker_write "$1" 2026-09-02T21:00:00Z "$2" "$3" "" MET
}

backdate() {  # <file> <seconds ago>
  local ts
  ts="$(date -v-"$2"S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-$2 seconds" +%Y%m%d%H%M.%S)"
  touch -t "$ts" "$1"
}

write_stamp() {  # <project> <sid>
  printf 'patrol-stamp/v1|at=2026-09-02T20:00:00Z|session=%s|verb=arm\n' "$2" \
    > "$1/.bionic/tmp/patrol-$2.state"
}

# An OPEN RUN, in the shape lib/run.sh's active_plan/active_run read: a
# flush-left `## SDLC State` heading under `.bionic/docs/plans/`, and a
# `current:` step below 9. This is the T4 gate's own precondition (AC-11/
# AC-12) — no earlier section in this suite plants one, so the engagement
# gate is a complete no-op for every fixture above.
write_open_plan() {  # <project> [name] -> plan path on stdout
  local dir="$1/.bionic/docs/plans/fixture" f name="${2:-fixture}"
  mkdir -p "$dir"
  f="$dir/$name.plan.md"
  {
    printf -- '---\n'
    printf 'governing-skill: canonical-sdlc\ncanonical_sdlc_version: 14\n'
    printf 'intent: bugfix\nrigor: tested\nscale: task\n'
    printf -- '---\n\n# Fixture plan\n\n## SDLC State\n\ncurrent: 3\n'
  } > "$f"
  printf '%s' "$f"
}

# A CLOSED run (delivered) — same shape, `current: 9` and a Step-9 evidence line
# carrying `delivered:` (lib/run.sh `run_open`'s own close condition). This is the
# negative fixture for §12: a member of `active_plan`'s candidate walk that
# `open_runs` must never include.
write_delivered_plan() {  # <project> [name] -> plan path on stdout
  local dir="$1/.bionic/docs/plans/fixture" f name="${2:-delivered}"
  mkdir -p "$dir"
  f="$dir/$name.plan.md"
  {
    printf -- '---\n'
    printf 'governing-skill: canonical-sdlc\ncanonical_sdlc_version: 14\n'
    printf 'intent: bugfix\nrigor: tested\nscale: task\n'
    printf -- '---\n\n# Fixture plan\n\n## SDLC State\n\ncurrent: 9\n\n- Step 9: delivered: 2026-09-02\n'
  } > "$f"
  printf '%s' "$f"
}

# A BOUND marker (lib/binding.sh's shape, S1/S2 contract): `plan=<path>` naming a
# member of the open-run set, plus `engaged_at=`. Distinct from `plant_engaged`,
# which writes an empty (unbound) marker. S11: this now calls the real `bind_plan`
# (tests/lib/bound-marker.sh), which stores the CANONICAL spelling itself — the
# `realplan()` workaround this suite used to need at every call site that asserts
# the plan's exact text is gone; the real writer canonicalises for us.
plant_bound() {  # <project> <sid> <plan-path>
  bound_marker "$1" "$2" "$3"
}

# The engagement marker itself (lib/run.sh `engaged_session`) — a REGULAR file
# at this exact path is the whole contract; content is never read here.
plant_engaged() {  # <project> <sid>
  mkdir -p "$1/.bionic/tmp"
  : > "$1/.bionic/tmp/engaged-$2.state"
}

# Every path under .bionic with its mtime — the "wrote nothing" fingerprint.
snap() {  # <project>
  find "$1/.bionic" 2>/dev/null | sort | while read -r f; do
    printf '%s %s\n' "$f" "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)"
  done
}

# The wrapper whose $$ becomes the hook's PPID. Written once, used by every drive.
WRAP="$WORK/wrap.sh"
cat > "$WRAP" <<'WRAP_EOF'
#!/bin/bash
# $1 = fixture claude home, $2 = sessionId to record (or "-" for no pid file),
# $3 = hook path. Payload arrives on stdin and is inherited by the child.
# NOT `exec`: the hook must be a CHILD so that its $PPID is this shell's $$,
# which is the pid this file is named for.
if [ "$2" != "-" ]; then
  mkdir -p "$1/sessions"
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\n' "$$" "$2" "$PWD" > "$1/sessions/$$.json"
fi
bash "$3"
WRAP_EOF

# One drive. Prints stdout, and leaves stdout/stderr/rc in three files.
#
# THE THREE FILES ARE NOT A CONVENIENCE. Every call site reads `OUT=$(drive …)`,
# which runs `drive` inside a command substitution — a SUBSHELL, whose variable
# assignments are discarded the moment it exits. An earlier draft of this harness
# kept rc in a shell variable and every "exit 0" assertion below silently compared
# the initial 0 against itself: forty green rows over an unread status. The status
# and the stderr therefore cross the subshell boundary the only way they can, on
# disk, and `rc` / `errtext` read them back afterwards.
OUTF=""; ERRF=""; RCF=""
drive() {  # <project> <source> <env-sid> <payload-sid> <pidfile-sid|-> -> stdout
  local proj="$1" src="$2" esid="$3" psid="$4" fsid="$5" home
  home="$WORK/home.$RANDOM.$RANDOM"; mkdir -p "$home"
  OUTF="$WORK/last.out"; ERRF="$WORK/last.err"; RCF="$WORK/last.rc"
  (
    cd "$proj" || exit 1
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"%s"}' \
      "$psid" "$home/t.jsonl" "$proj" "$src" \
    | CLAUDE_CODE_SESSION_ID="$esid" BIONIC_CLAUDE_HOME="$home" \
      bash "$WRAP" "$home" "$fsid" "$HOOK" > "$WORK/last.out" 2>"$WORK/last.err"
  )
  printf '%s' "$?" > "$WORK/last.rc"
  cat "$WORK/last.out"
}
rc()      { cat "$WORK/last.rc" 2>/dev/null; }
errtext() { cat "$WORK/last.err" 2>/dev/null; }

# The harness's own catch-proof: a drive of a script that exits 3 with a known
# stderr line must be READ as 3 with that line. Without this row, every rc and
# stderr assertion below could be passing over a broken reader (the failure this
# helper was rewritten to close).
printf '#!/bin/bash\ncat >/dev/null\necho "harness-probe-stderr" >&2\nexit 3\n' > "$WORK/probe.sh"
P0=$(make_env 1s)
BIONIC_SESSION_START_UNDER_TEST_SAVE="$HOOK"; HOOK="$WORK/probe.sh"
drive "$P0" clear "$CUR_SID" "$CUR_SID" "$CUR_SID" >/dev/null
eq  "0.1 the harness reads a non-zero exit as non-zero" "3" "$(rc)"
has "0.2 …and reads the driven script's stderr" "harness-probe-stderr" "$(errtext)"
HOOK="$BIONIC_SESSION_START_UNDER_TEST_SAVE"

section "1 — a predecessor roster on a /clear: the block, and the sequence"
# The whole point of the hook, driven exactly as the probe left the disk: same
# process, new sid, the old conversation's roster still open beside the new one's.
#
# 3600s, NOT THE 1s DEFAULT (R2, ticket-30). session-start.sh now sweeps a DEAD
# predecessor's state whose files are older than one Patrol interval — that is
# the whole feature under test in tests/session-sweep.test.sh §7 — and this
# section is not about that feature at all: OLD_SID's roster here is written
# moments before `drive()` runs it, and under the suite's own 1s default that
# freshness is a coin flip against however long sourcing four libraries and
# parsing the JSON payload actually takes on the machine running this suite. A
# generous interval keeps the file unambiguously YOUNG so "wrote nothing" below
# tests what this section is actually about — the report and the re-arm
# sequence — deterministically, not by how loaded the box happens to be.
P1=$(make_env 3600s)
roster_rows "$P1/.bionic/tmp/roster-$OLD_SID.state" "$OLD_SID" "W-ALPHA"
roster_rows "$P1/.bionic/tmp/roster-$OLD_SID.state" "$OLD_SID" "W-BETA"
swept "$P1/.bionic/tmp/roster-$OLD_SID.state" "$OLD_SID" "W-BETA"
# THIS session's own roster, also with an open row: it must NOT be listed. Without
# this the "predecessor" filter could be a no-op and every assertion still pass.
roster_rows "$P1/.bionic/tmp/roster-$CUR_SID.state" "$CUR_SID" "W-MINE"
S1_BEFORE=$(snap "$P1")
OUT=$(drive "$P1" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq   "1.1 exit 0" "0" "$(rc)"
has  "1.2 the block names the predecessor roster file" "roster-$OLD_SID.state" "$OUT"
has  "1.3 …with ONE open row (three status rows for W-ALPHA are one agent)" "1 open row" "$OUT"
has  "1.4 …under the predecessor's sid8" "${OLD_SID:0:8}" "$OUT"
hasnt "1.5 …and THIS session's own open roster is not a predecessor" "roster-$CUR_SID.state" "$OUT"
has  "1.6 the re-arm sequence: CronList first" "re-arm: CronList" "$OUT"
has  "1.7 …then the stray delete" "delete bionic-patrol session=" "$OUT"
has  "1.8 …then CronCreate" "CronCreate" "$OUT"
has  "1.9 …then arm, by absolute path" "$(cd "$(dirname "$HOOK")/.." && pwd -P)/hooks/session-poker.sh arm" "$OUT"
has  "1.10 …then adopt" "adopt" "$OUT"
has  "1.11 the session-id triple agrees" "— agree" "$OUT"
eq   "1.12 the hook wrote nothing under .bionic" "$S1_BEFORE" "$(snap "$P1")"

section "2 — startup with nothing to report: silence"
P2=$(make_env 1s)
S2_BEFORE=$(snap "$P2")
OUT=$(drive "$P2" startup "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq "2.1 exit 0" "0" "$(rc)"
eq "2.2 nothing on stdout" "" "$OUT"
eq "2.3 wrote nothing" "$S2_BEFORE" "$(snap "$P2")"

section "3 — no .bionic anywhere above the cwd: silence"
# A bare temp directory: no git, no `.bionic`. project_root falls back to the cwd
# and there is no real `.bionic` under it, so there is no project to report on.
P3=$(mktemp -d "$WORK/bare.XXXXXX")
OUT=$(drive "$P3" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq "3.1 exit 0" "0" "$(rc)"
eq "3.2 nothing on stdout" "" "$OUT"
eq "3.3 no .bionic was created" "" "$(ls -A "$P3")"

section "4 — a divergent session-id triple: DIVERGE, named channel by channel"
P4=$(make_env 1s)
OUT=$(drive "$P4" clear "$CUR_SID" "$PAY_SID" "$OLD_SID")
eq  "4.1 exit 0" "0" "$(rc)"
has "4.2 the verdict is DIVERGE" "DIVERGE" "$OUT"
has "4.3 env is named" "env=$CUR_SID" "$OUT"
has "4.4 payload is named" "payload=$PAY_SID" "$OUT"
has "4.5 pidfile is named" "pidfile=$OLD_SID" "$OUT"
# The L-SESSION contract: one warning line on stderr naming both, and the env wins.
has "4.6 lib/session.sh's divergence warning reached stderr" \
  "session-id: payload $PAY_SID ≠ env $CUR_SID — using env" "$(errtext)"

# …and an absent pid file says so rather than inventing agreement.
P4b=$(make_env 1s)
OUT=$(drive "$P4b" clear "$CUR_SID" "$PAY_SID" "-")
has "4.7 an absent pid file is reported absent" "pidfile=absent" "$OUT"
has "4.8 …and two channels that still disagree still DIVERGE" "DIVERGE" "$OUT"

section "5 — a legacy .bionic symlink under .worktrees (AC-11, ledger C2)"
P5=$(make_env 1s)
mkdir -p "$P5/.worktrees/wt-one"
ln -s "$P5/.bionic" "$P5/.worktrees/wt-one/.bionic"
mkdir -p "$P5/.worktrees/wt-two/.bionic"   # a REAL dir there is not a legacy link
S5_BEFORE=$(snap "$P5")
OUT=$(drive "$P5" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq  "5.1 exit 0" "0" "$(rc)"
has "5.2 the legacy link is listed" "legacy .bionic symlinks:" "$OUT"
has "5.3 …by its path" ".worktrees/wt-one/.bionic" "$OUT"
hasnt "5.4 …and a real directory beside it is not" ".worktrees/wt-two/.bionic" "$OUT"
eq  "5.5 wrote nothing" "$S5_BEFORE" "$(snap "$P5")"

section "6 — predecessor stamps: stale past PATROL_STALE_MULTIPLIER x interval"
# interval 1s -> limit 2s. One predecessor stamp backdated well past it, one
# predecessor stamp backdated to EXACTLY the sweep's own 1s interval, and THIS
# session's own stamp backdated too — the last is the anti-vacuity control:
# staleness alone must not make a stamp mine.
P6=$(make_env 1s)
write_stamp "$P6" "$OLD_SID";  backdate "$P6/.bionic/tmp/patrol-$OLD_SID.state" 600
# 1s, NOT freshly-written (R2, ticket-30). The R2 auto-sweep below reads dead
# sessions in ONE BATCH: if ANY dead session anywhere in .bionic/tmp has ANY
# file younger than the interval, the WHOLE sweep defers this round (the age
# gate has no per-session granularity — see hooks/session-start.sh's own
# comment on the tradeoff). A freshly-written OLD2_SID stamp would make that
# call a coin flip against how long sourcing four libraries and parsing JSON
# takes on the machine running this suite — exactly the race that used to make
# this section's assertions non-deterministic. Backdated to EXACTLY 1s, its age
# at read time is >= the 1s interval (real time only adds, never subtracts), so
# it is never "young" — deterministically — while still comfortably under the
# 2s stale LIMIT the report below tests, so 6.4's "fresh" still holds.
write_stamp "$P6" "$OLD2_SID"; backdate "$P6/.bionic/tmp/patrol-$OLD2_SID.state" 1
write_stamp "$P6" "$CUR_SID";  backdate "$P6/.bionic/tmp/patrol-$CUR_SID.state" 600
OUT=$(drive "$P6" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq  "6.1 exit 0" "0" "$(rc)"
has "6.2 the stamps section is present" "predecessor stamps:" "$OUT"
eq  "6.3 the backdated predecessor stamp reads stale" "1" \
  "$(printf '%s\n' "$OUT" | grep -c "^  ${OLD_SID:0:8} .*stale$")"
eq  "6.4 the just-written predecessor stamp reads fresh" "1" \
  "$(printf '%s\n' "$OUT" | grep -c "^  ${OLD2_SID:0:8} .*fresh$")"
hasnt "6.5 THIS session's own stale stamp is not a predecessor" "  ${CUR_SID:0:8}" "$OUT"
has "6.6 the age is reported in seconds" "s old" "$OUT"

# NOT A BLANKET "wrote nothing" ANY MORE (R2, ticket-30). Both predecessor
# stamps are DEAD (no live pid for OLD_SID or OLD2_SID in this fixture's
# claude-home), and the report above is read off the disk BEFORE the sweep
# runs, so 6.3/6.4 stand regardless of what the sweep does next. Both are now
# aged past the 1s interval by construction (600s and exactly 1s), so both are
# swept, deterministically — the age-gate detail above is why OLD2_SID had to
# be backdated at all rather than left fresh. THIS session's own 600s-old stamp
# survives because it is LIVE, not because of its age — the same anti-vacuity
# point 6.5 already makes about the report, made again here about the sweep.
expect_false "6.7 the dead, 600s-old predecessor stamp is swept" \
  test -e "$P6/.bionic/tmp/patrol-$OLD_SID.state"
expect_false "6.8 …and the OTHER dead predecessor, aged to exactly the interval, too" \
  test -e "$P6/.bionic/tmp/patrol-$OLD2_SID.state"
expect_true "6.9 THIS session's own 600s-old stamp survives — it is live, not young" \
  test -f "$P6/.bionic/tmp/patrol-$CUR_SID.state"
expect_false "6.10 …and no sweep-failure marker appeared — nothing failed here" \
  test -e "$P6/.bionic/tmp/sweep-failed.state"

section "7 — the hook never blocks and never refuses"
# Every fixture above already asserted rc 0. What is left is the degenerate input
# a real SessionStart can still deliver: no payload at all, and no session key.
# 3600s: see §1's comment above — this fixture's predecessor roster is fresh and
# unrelated to R2's own age-gate feature, so a generous interval keeps it out of
# the sweep's reach deterministically.
P7=$(make_env 3600s)
roster_rows "$P7/.bionic/tmp/roster-$OLD_SID.state" "$OLD_SID" "W-GAMMA"
S7_BEFORE=$(snap "$P7")
OUT=$( cd "$P7" && printf '' | CLAUDE_CODE_SESSION_ID="" BIONIC_CLAUDE_HOME="$WORK/nohome" bash "$HOOK" 2>/dev/null )
eq "7.1 empty payload, no session key: exit 0" "0" "$?"
eq "7.2 …and still wrote nothing" "$S7_BEFORE" "$(snap "$P7")"
OUT=$( cd "$P7" && printf 'not json at all' | CLAUDE_CODE_SESSION_ID="$CUR_SID" BIONIC_CLAUDE_HOME="$WORK/nohome" bash "$HOOK" 2>/dev/null )
eq "7.3 unparsable payload: exit 0" "0" "$?"

section "8 — an open run, no engagement marker: one line, nothing else (AC-11)"
# A predecessor roster and stamp are seeded too — the positive control that
# proves the gate, not an empty fixture, is what silences the block: under
# today's rules (no open run) this exact disk state would have printed both.
P8=$(make_env 1s)
PLAN8="$(write_open_plan "$P8")"
roster_rows "$P8/.bionic/tmp/roster-$OLD_SID.state" "$OLD_SID" "W-DELTA"
write_stamp "$P8" "$OLD_SID"
S8_BEFORE=$(snap "$P8")
OUT=$(drive "$P8" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq    "8.1 exit 0" "0" "$(rc)"
has   "8.2 the one-line notice names the plan path" "$PLAN8" "$OUT"
has   "8.3 …and names the skill to invoke" "/bionic:canonical-sdlc" "$OUT"
eq    "8.4 exactly one line of output" "1" "$(printf '%s\n' "$OUT" | grep -c .)"
hasnt "8.5 no re-arm instruction" "re-arm" "$OUT"
hasnt "8.6 no adopt instruction" "adopt" "$OUT"
hasnt "8.7 no predecessor roster line" "roster-$OLD_SID.state" "$OUT"
hasnt "8.8 no predecessor stamps section" "predecessor stamps:" "$OUT"
eq    "8.9 the hook wrote nothing under .bionic" "$S8_BEFORE" "$(snap "$P8")"

section "9 — an open run + the engagement marker: today's block, unchanged (AC-12)"
# 3600s: see §1's comment — engaged fixtures reach the predecessor-roster/sweep
# code below the early-exit branches, so this section's fresh OLD_SID roster is
# exactly the R2 age-gate race described there.
P9=$(make_env 3600s)
write_open_plan "$P9" >/dev/null
roster_rows "$P9/.bionic/tmp/roster-$OLD_SID.state" "$OLD_SID" "W-DELTA"
plant_engaged "$P9" "$CUR_SID"
S9_BEFORE=$(snap "$P9")
OUT=$(drive "$P9" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq    "9.1 exit 0" "0" "$(rc)"
has   "9.2 the predecessor roster is listed, exactly as with no run open" \
  "roster-$OLD_SID.state" "$OUT"
has   "9.3 the re-arm sequence still prints: CronList first" "re-arm: CronList" "$OUT"
has   "9.4 …through adopt" "adopt" "$OUT"
hasnt "9.5 the bystander notice does not also print" \
  "invoke /bionic:canonical-sdlc to engage it" "$OUT"
eq    "9.6 the hook wrote nothing under .bionic" "$S9_BEFORE" "$(snap "$P9")"

section "10 — a symlink at the marker path reads as absent, same as no marker (AC-4)"
P10=$(make_env 1s)
PLAN10="$(write_open_plan "$P10")"
mkdir -p "$P10/.bionic/tmp"
: > "$P10/.bionic/tmp/real-engaged-file"
ln -s "$P10/.bionic/tmp/real-engaged-file" "$P10/.bionic/tmp/engaged-$CUR_SID.state"
OUT=$(drive "$P10" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq    "10.1 exit 0" "0" "$(rc)"
has   "10.2 a symlinked marker reads not-engaged: the notice prints" \
  "invoke /bionic:canonical-sdlc to engage it" "$OUT"
has   "10.3 …naming the plan path" "$PLAN10" "$OUT"
hasnt "10.4 …and not the re-arm block" "re-arm" "$OUT"

section "11 — no open run at all: the marker's presence or absence changes nothing (AC-11 pair)"
# The paired control the design calls for: no plan on disk, marker absent —
# today's behaviour, silence over a clean fixture. Marker presence must not
# matter either, since the gate above is conditioned on PLAN being non-empty.
P11=$(make_env 1s)
OUT=$(drive "$P11" startup "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq "11.1 exit 0" "0" "$(rc)"
eq "11.2 nothing on stdout" "" "$OUT"
P11b=$(make_env 1s)
plant_engaged "$P11b" "$CUR_SID"
OUT=$(drive "$P11b" startup "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq "11.3 exit 0 with the marker present too" "0" "$(rc)"
eq "11.4 still nothing on stdout — no run, no notice, no block" "" "$OUT"

section "12 — two or more open runs (AC-5, S7)"

echo "--- 12a: two open plans, not engaged: the listing block, and nothing else ---"
P12=$(make_env 1s)
PLAN12A="$(write_open_plan "$P12" alpha)"
PLAN12B="$(write_open_plan "$P12" beta)"
PLAN12C="$(write_delivered_plan "$P12" gamma)"
roster_rows "$P12/.bionic/tmp/roster-$OLD_SID.state" "$OLD_SID" "W-EPSILON"
write_stamp "$P12" "$OLD_SID"
S12_BEFORE=$(snap "$P12")
OUT=$(drive "$P12" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq    "12a.1 exit 0" "0" "$(rc)"
has   "12a.2 the header names the count" "bionic: 2 open runs exist here" "$OUT"
has   "12a.3 …and the engage instruction" "invoke /bionic:canonical-sdlc" "$OUT"
has   "12a.4 …and the bind instruction" "session-poker.sh bind <plan>" "$OUT"
# DOCS-ROOT-RELATIVE, not absolute (review P3 / security F4, S10b). Every path in the
# listing shares one long prefix, and the instruction beside it already says where the
# paths resolve — `bind` takes either spelling. The absolute row is pinned ABSENT beside
# each relative row, because the relative string is a substring of the absolute one and a
# `has` on it alone would pass over an unchanged hook.
has   "12a.5 the first open plan is listed relative to the docs root" \
  "  ${PLAN12A#$P12/.bionic/docs/}" "$OUT"
hasnt "12a.5b …and not as an absolute path" "$P12/.bionic/docs/" "$OUT"
has   "12a.6 the second open plan is listed relative to the docs root" \
  "  ${PLAN12B#$P12/.bionic/docs/}" "$OUT"
eq    "12a.6b both listed paths are indented two spaces" "2" \
  "$(printf '%s\n' "$OUT" | grep -cE '^  .*\.plan\.md$')"
hasnt "12a.7 the CLOSED plan's path is absent" "$(basename "$PLAN12C")" "$OUT"
hasnt "12a.8 no roster text — the listing is the whole block" "predecessor rosters:" "$OUT"
hasnt "12a.9 …and no re-arm sequence either" "re-arm" "$OUT"
eq    "12a.10 wrote nothing" "$S12_BEFORE" "$(snap "$P12")"

echo ""
echo "--- 12b: one open plan, not engaged: today's singular line, byte-identical to §8 ---"
P12b=$(make_env 1s)
PLAN12b="$(write_open_plan "$P12b")"
S12b_BEFORE=$(snap "$P12b")
OUT=$(drive "$P12b" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq    "12b.1 exit 0" "0" "$(rc)"
has   "12b.2 the one-line notice names the plan path, exactly as §8.2 pins" "$PLAN12b" "$OUT"
has   "12b.3 …and names the skill to invoke, exactly as §8.3 pins" "/bionic:canonical-sdlc" "$OUT"
eq    "12b.4 exactly one line of output, exactly as §8.4 pins" "1" "$(printf '%s\n' "$OUT" | grep -c .)"
hasnt "12b.5 no count-style header" "open runs exist here" "$OUT"
eq    "12b.6 wrote nothing" "$S12b_BEFORE" "$(snap "$P12b")"

echo ""
echo "--- 12c: two open plans, engaged and bound-open to one: today's engaged block, no listing ---"
# 3600s: see §1's comment — a bound session is engaged too, so this also reaches
# the sweep below.
P12c=$(make_env 3600s)
PLAN12cA="$(write_open_plan "$P12c" alpha)"
PLAN12cB="$(write_open_plan "$P12c" beta)"
roster_rows "$P12c/.bionic/tmp/roster-$OLD_SID.state" "$OLD_SID" "W-ZETA"
plant_bound "$P12c" "$CUR_SID" "$PLAN12cA"
S12c_BEFORE=$(snap "$P12c")
OUT=$(drive "$P12c" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq    "12c.1 exit 0" "0" "$(rc)"
has   "12c.2 the predecessor roster is listed, exactly as an engaged session sees it" \
  "roster-$OLD_SID.state" "$OUT"
has   "12c.3 the re-arm sequence still prints" "re-arm: CronList" "$OUT"
hasnt "12c.4 no count-style listing" "open runs exist here" "$OUT"
hasnt "12c.5 the sibling (unbound) plan is not named" "$PLAN12cB" "$OUT"
eq    "12c.6 wrote nothing" "$S12c_BEFORE" "$(snap "$P12c")"

echo ""
echo "--- 12d: two open plans, engaged with an EMPTY (unbound) marker: the listing, then today's engaged block ---"
# 3600s: see §1's comment — engaged and unbound still reaches the sweep below.
P12d=$(make_env 3600s)
PLAN12dA="$(write_open_plan "$P12d" alpha)"
PLAN12dB="$(write_open_plan "$P12d" beta)"
roster_rows "$P12d/.bionic/tmp/roster-$OLD_SID.state" "$OLD_SID" "W-ETA"
plant_engaged "$P12d" "$CUR_SID"   # empty marker: engaged, unbound
S12d_BEFORE=$(snap "$P12d")
OUT=$(drive "$P12d" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq    "12d.1 exit 0" "0" "$(rc)"
has   "12d.2 the not-bound header names the count" \
  "bionic: 2 open runs exist here and this session is not bound to one" "$OUT"
has   "12d.3 …and the bind instruction" "session-poker.sh bind <plan>" "$OUT"
has   "12d.4 the first open plan is listed relative to the docs root" \
  "  ${PLAN12dA#$P12d/.bionic/docs/}" "$OUT"
hasnt "12d.4b …and not as an absolute path" "$P12d/.bionic/docs/" "$OUT"
has   "12d.5 the second open plan is listed relative to the docs root" \
  "  ${PLAN12dB#$P12d/.bionic/docs/}" "$OUT"
has   "12d.6 today's engaged roster block still follows — no early exit" \
  "roster-$OLD_SID.state" "$OUT"
has   "12d.7 …through the re-arm sequence" "re-arm: CronList" "$OUT"
eq    "12d.8 wrote nothing" "$S12d_BEFORE" "$(snap "$P12d")"

echo ""
echo "--- 12e: ten open plans: the listing is CAPPED at 8, with a trailer naming the rest ---"
# WHY A CAP (review P3, security F4 — S10b). A SessionStart hook's stdout is context the
# model pays for on `startup`, `clear`, `resume` AND `compact`. This repository's own tree
# already renders 60 paths (~6.8 KB, ~1,700 tokens) that a reader acts on at most one line
# of. `open_runs` itself stays uncapped — it is a membership predicate with three callers —
# so what is bounded here is the DISPLAY only, and the header still names the true count.
P12e=$(make_env 1s)
_i=1
while [ "$_i" -le 10 ]; do
  write_open_plan "$P12e" "p$_i" >/dev/null
  _i=$((_i + 1))
done
S12e_BEFORE=$(snap "$P12e")
OUT=$(drive "$P12e" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq    "12e.1 exit 0" "0" "$(rc)"
has   "12e.2 the header names the TRUE count, not the capped one" \
  "bionic: 10 open runs exist here" "$OUT"
eq    "12e.3 exactly 8 plan lines are listed" "8" \
  "$(printf '%s\n' "$OUT" | grep -cE '^  .*\.plan\.md$')"
has   "12e.4 …and one trailer line names the remainder" \
  "  … and 2 more — bind names any open plan" "$OUT"
hasnt "12e.5 no absolute path anywhere in the block" "$P12e/.bionic/docs/" "$OUT"
eq    "12e.6 wrote nothing" "$S12e_BEFORE" "$(snap "$P12e")"

echo ""
echo "--- 12f: three open plans: all three listed, and NO trailer ---"
# The paired negative for 12e: below the cap the trailer must not appear at all. Without
# this row a hook that printed "and 0 more" unconditionally would pass 12e.
P12f=$(make_env 1s)
_i=1
while [ "$_i" -le 3 ]; do
  write_open_plan "$P12f" "q$_i" >/dev/null
  _i=$((_i + 1))
done
S12f_BEFORE=$(snap "$P12f")
OUT=$(drive "$P12f" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq    "12f.1 exit 0" "0" "$(rc)"
has   "12f.2 the header names the count" "bionic: 3 open runs exist here" "$OUT"
eq    "12f.3 all three plan lines are listed" "3" \
  "$(printf '%s\n' "$OUT" | grep -cE '^  .*\.plan\.md$')"
hasnt "12f.4 …and no trailer line" "more — bind names any open plan" "$OUT"
eq    "12f.5 wrote nothing" "$S12f_BEFORE" "$(snap "$P12f")"

# Eight days ago: past the default 7d `live-window`, so `live_runs` excludes it while
# `open_runs` still counts it. No BIONIC_NOW_EPOCH pin needed — `backdate` moves the
# file's mtime itself, so the wall clock's real "now" already sees it as stale.
QUIET_AGO=$((8 * 86400))

section "13 — live vs open: the quiet-count line replaces the quiet listing (AC-3, S3)"

echo "--- 13a: 3 open, 1 live, not engaged: only the live plan is listed, plus a quiet-count line ---"
P13=$(make_env 1s)
PLAN13A="$(write_open_plan "$P13" alpha)"
PLAN13B="$(write_open_plan "$P13" beta)"
PLAN13C="$(write_open_plan "$P13" gamma)"
backdate "$PLAN13B" "$QUIET_AGO"
backdate "$PLAN13C" "$QUIET_AGO"
S13_BEFORE=$(snap "$P13")
OUT=$(drive "$P13" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq    "13a.1 exit 0" "0" "$(rc)"
has   "13a.2 the header still names the true OPEN count" "bionic: 3 open runs exist here" "$OUT"
has   "13a.3 the live plan is listed relative to the docs root" \
  "  ${PLAN13A#$P13/.bionic/docs/}" "$OUT"
hasnt "13a.4 the first quiet plan is NOT listed" "$(basename "$PLAN13B")" "$OUT"
hasnt "13a.5 the second quiet plan is NOT listed" "$(basename "$PLAN13C")" "$OUT"
has   "13a.6 one quiet-count line names the two quiet runs" \
  "bionic: 2 quiet open run(s) — bind names any of them" "$OUT"
eq    "13a.7 wrote nothing" "$S13_BEFORE" "$(snap "$P13")"

echo ""
echo "--- 13b: same shape, engaged and NOT bound: the quiet-count line still appears ---"
P13b=$(make_env 1s)
PLAN13bA="$(write_open_plan "$P13b" alpha)"
PLAN13bB="$(write_open_plan "$P13b" beta)"
backdate "$PLAN13bB" "$QUIET_AGO"
plant_engaged "$P13b" "$CUR_SID"
OUT=$(drive "$P13b" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq  "13b.1 exit 0" "0" "$(rc)"
has "13b.2 the not-bound header still fires" \
  "bionic: 2 open runs exist here and this session is not bound to one" "$OUT"
has "13b.3 the live plan is listed" "  ${PLAN13bA#$P13b/.bionic/docs/}" "$OUT"
hasnt "13b.4 the quiet plan is not listed" "$(basename "$PLAN13bB")" "$OUT"
has "13b.5 one quiet-count line" "bionic: 1 quiet open run(s) — bind names any of them" "$OUT"

echo ""
echo "--- 13c: all open runs live: no quiet-count line at all (anti-vacuity) ---"
P13c=$(make_env 1s)
write_open_plan "$P13c" alpha >/dev/null
write_open_plan "$P13c" beta >/dev/null
OUT=$(drive "$P13c" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
hasnt "13c.1 no quiet-count line when nothing is quiet" "quiet open run(s)" "$OUT"

section "14 — engaged and bound: the bound-run line names the plan and its step (AC-21, S3)"

echo "--- 14a: exactly one open run, engaged and bound to it: one line, nothing else ---"
P14=$(make_env 1s)
PLAN14="$(write_open_plan "$P14")"
plant_bound "$P14" "$CUR_SID" "$PLAN14"
S14_BEFORE=$(snap "$P14")
OUT=$(drive "$P14" startup "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq  "14a.1 exit 0" "0" "$(rc)"
has "14a.2 the bound line names the docs-root-relative plan and its current step" \
  "bionic: bound to ${PLAN14#$P14/.bionic/docs/} — current: 3" "$OUT"
eq  "14a.3 exactly one line of output — no predecessor state to also report" \
  "1" "$(printf '%s\n' "$OUT" | grep -c .)"
eq  "14a.4 wrote nothing" "$S14_BEFORE" "$(snap "$P14")"

echo ""
echo "--- 14b: the same fixture on resume and on compact: the bound line fires on every source ---"
for BSRC in resume compact; do
  OUT=$(drive "$P14" "$BSRC" "$CUR_SID" "$CUR_SID" "$CUR_SID")
  has "14b.$BSRC the bound line fires on source=$BSRC" \
    "bionic: bound to ${PLAN14#$P14/.bionic/docs/} — current: 3" "$OUT"
done

echo ""
echo "--- 14c: two open runs, engaged and bound to one: the bound line, no listing, roster unaffected ---"
P14c=$(make_env 1s)
PLAN14cA="$(write_open_plan "$P14c" alpha)"
PLAN14cB="$(write_open_plan "$P14c" beta)"
roster_rows "$P14c/.bionic/tmp/roster-$OLD_SID.state" "$OLD_SID" "W-THETA"
plant_bound "$P14c" "$CUR_SID" "$PLAN14cA"
OUT=$(drive "$P14c" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq    "14c.1 exit 0" "0" "$(rc)"
has   "14c.2 the bound line names the bound plan" \
  "bionic: bound to ${PLAN14cA#$P14c/.bionic/docs/} — current: 3" "$OUT"
hasnt "14c.3 the sibling (unbound) plan is not named" "$(basename "$PLAN14cB")" "$OUT"
hasnt "14c.4 no count-style listing" "open runs exist here" "$OUT"
has   "14c.5 the predecessor roster still prints alongside it" "roster-$OLD_SID.state" "$OUT"

section "15 — engaged, one live run, unbound: unchanged (regression control, S3 scope (c))"
# 3600s: see §1's comment — engaged, N==1, unbound also reaches the sweep below.
P15=$(make_env 3600s)
write_open_plan "$P15" >/dev/null
roster_rows "$P15/.bionic/tmp/roster-$OLD_SID.state" "$OLD_SID" "W-IOTA"
plant_engaged "$P15" "$CUR_SID"
S15_BEFORE=$(snap "$P15")
OUT=$(drive "$P15" clear "$CUR_SID" "$CUR_SID" "$CUR_SID")
eq    "15.1 exit 0" "0" "$(rc)"
hasnt "15.2 no bound line — this session never bound" "bionic: bound to" "$OUT"
hasnt "15.3 no quiet-count line — nothing is quiet" "quiet open run(s)" "$OUT"
has   "15.4 the predecessor roster still prints, exactly as today" "roster-$OLD_SID.state" "$OUT"
eq    "15.5 wrote nothing" "$S15_BEFORE" "$(snap "$P15")"

finish
