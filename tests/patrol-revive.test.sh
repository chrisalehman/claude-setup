#!/bin/bash
# Tests for hooks/patrol-revive.sh — THE PATROL SELF-HEAL (epic-19 wave-01, AC-F6,
# design ledger D4).
#
# THE CONTRACT UNDER TEST. The CLI holds its cron table in process memory with no
# file behind it, so a `claude plugin update`, a `/reload-plugins` or a
# `/clear`+resume can delete the Patrol job and NOTHING says so: the stamp keeps
# reading fresh for one stale window, then goes stale where only a dispatch
# attempt or a hand-run doctor would ever look. This Stop hook is the thing that
# looks. On every orchestrator turn end, if a Patrol stamp exists for THIS session
# and is older than 2x the poker-interval, it blocks once with the notice in the
# terminal and the two-part re-arm the operator's model then performs.
#
# THE THREE STAMP STATES, and why only one of them speaks here:
#   absent  — never armed. Nothing engaged a run on this session, or nothing armed
#             one yet; that is hooks/dispatch-preflight.sh's refusal to make when a
#             dispatch is actually attempted, not a monitor's to raise every turn.
#   fresh   — firings are landing. Silent.
#   stale   — armed, then died. THE notice.
#
# THE HOOK MUST NOT STAMP. `session-poker.sh arm` would freshen the stamp and
# satisfy the arming wall over a cron table that still holds nothing — a Patrol
# that reads alive and never fires again, which is worse than the state it
# replaced. Group 5 asserts the stamp's mtime is untouched; Group 4's reason
# assertions demand the CronCreate half is named, for the same reason
# tests/dispatch-preflight.test.sh S21 demands it.
#
# ACCELERATED CLOCK, NEVER A WAIT. The interval is pinned tiny through the
# project's own knob (`poker-interval:` in .bionic/config.yaml) and staleness is
# manufactured by backdating the stamp's mtime — the `s21_backdate` idiom of
# tests/dispatch-preflight.test.sh, borrowed whole. Nothing in this suite sleeps,
# and every fixture lives in its own mktemp project, so there is no clock to
# restore.
#
# Usage: bash tests/patrol-revive.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"

HOOK="${BIONIC_PATROL_REVIVE_UNDER_TEST:-${BIONIC_HOOKS_DIR}/patrol-revive.sh}"

# pass/fail were pure-rename shadows of the framework's ok/no; the suite's own
# explicit TOTAL=$((TOTAL + 1)) lines (including the ones inside
# expect_quiet/expect_block/expect_reason_names below) are dropped too since
# ok/no already increment it (S7, AC-12). expect_quiet/expect_block/
# expect_reason_names are suite-specific helpers (not owned names) rebuilt on
# the framework's ok/no.

command -v jq >/dev/null 2>&1 || { echo "patrol-revive: jq absent — suite cannot run"; exit 1; }

# THE SUITE IS NOT ALLOWED TO BE VACUOUS. Every silent-pass assertion below reads
# "rc 0 and no stdout", which is exactly what a MISSING hook produces once the
# shell's own 127 is discarded — so an absent or unparsable hook would turn most
# of this file green over nothing. Prove the subject exists and parses before any
# of it runs (memory/no-vacuous-tests-at-authoring).
[ -f "$HOOK" ] || { echo "patrol-revive: no hook at $HOOK — suite refuses to run"; exit 1; }
bash -n "$HOOK" || { echo "patrol-revive: $HOOK does not parse — suite refuses to run"; exit 1; }

SID="11111111-2222-3333-4444-555555555555"
OTHER_SID="99999999-8888-7777-6666-555555555555"

# ---------- fixture builders ----------

# A scratch project carrying a .bionic/tmp and a TINY poker-interval, so 2x the
# interval is two seconds and a backdated stamp is decisively stale without any
# wait. No git repository is created: `project_root` answers at the nearest ancestor
# carrying `.bionic/`, which is this directory itself.
#
# AND AN OPEN RUN (bionic 1.4.0, spec AC-7). The hook is registered always-on now, so it
# is delivered on every Stop in every project on the machine, and its first scope
# condition is `active_run` — there is no Patrol to be dead where there is no run. Every
# fixture that expects this monitor to SPEAK therefore needs a plan; §11 below drives the
# paired negative, where the plan is the only thing missing.
make_env() {  # [interval] -> project dir on stdout
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/.bionic/tmp" "$dir/.bionic/docs/plans"
  # ENGAGED (task-engaged-session). This monitor asks `engaged_session` before it asks
  # anything else, so a fixture without the marker is silent for a reason that has nothing
  # to do with the stamp under test. An armed Patrol implies an engaged session anyway —
  # SKILL.md arms the Patrol AT engagement — so the marker travels with the stamp in
  # write_stamp below as well. §12 drives the unengaged direction deliberately.
  : > "$dir/.bionic/tmp/engaged-$SID.state"
  printf 'poker-interval: %s\n' "${1:-1s}" > "$dir/.bionic/config.yaml"
  cat > "$dir/.bionic/docs/plans/wave-01.plan.md" <<'PRPLAN'
---
canonical_sdlc_version: 14
---

## SDLC State

current: 4

- Step 4: slices in flight
PRPLAN
  printf '%s' "$dir"
}

stamp_path() { printf '%s/.bionic/tmp/patrol-%s.state' "$1" "$2"; }

# The arming record `session-poker.sh arm` writes beside the stamp (bionic 1.3.2, R-13). This
# hook never reads it — it reads the stamp's mtime and nothing else — but Group 7 drives a
# real DISARM tick, and from 1.3.2 a tick DISARMs only on a delivery that POSTDATES this
# session's arming, so the fixture there has to carry one.
armed_path() { printf '%s.armed' "$(stamp_path "$1" "$2")"; }

write_stamp() {  # <project> <session>
  printf 'patrol-stamp/v1|at=2026-08-27T00:00:00Z|session=%s|verb=arm\n' "$2" \
    > "$(stamp_path "$1" "$2")"
  # The engagement marker for the SAME session: a Patrol is armed at engagement, so a
  # stamp without a marker is a state the machine does not produce (task-engaged-session).
  : > "$1/.bionic/tmp/engaged-$2.state"
}

# The `s21_backdate` idiom of tests/dispatch-preflight.test.sh, verbatim in
# behaviour: age is a MTIME, never a sleep.
backdate() {  # <file> <seconds ago>
  local ts
  ts="$(date -v-"$2"S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-$2 seconds" +%Y%m%d%H%M.%S)"
  touch -t "$ts" "$1"
}

mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# ---------- driving the hook ----------

stdin_for() {  # <cwd> [session] [event] [stop_hook_active]
  jq -nc --arg c "$1" --arg s "${2:-$SID}" --arg e "${3:-Stop}" --argjson a "${4:-false}" \
    '{session_id:$s,transcript_path:"/dev/null",cwd:$c,
      hook_event_name:$e,stop_hook_active:$a}'
}

# THE ENVIRONMENT AGREES WITH THE PAYLOAD, because on the machine it does (A-probe-2).
# The hook takes its session key from lib/session.sh, env first, and the stamp filename
# is built from it — so a driver that left the runner's own id in the environment would
# have this monitor watching a file the fixture never wrote.
PR_ERRFILE="$(mktemp)"
HOOK_ERR_USER=""
fire() {  # <cwd> [session] [event] [stop_hook_active]
  HOOK_OUT=$(env CLAUDE_CODE_SESSION_ID="${2:-$SID}" bash "$HOOK" \
    <<< "$(stdin_for "$1" "${2:-$SID}" "${3:-Stop}" "${4:-false}")" 2>"$PR_ERRFILE")
  HOOK_RC=$?
  # THE USER STREAM (slice 13). The JSON reason on stdout is what every arm below reads;
  # this is the one line a reader is shown, and the AC-E1.3 section at the end asserts it.
  HOOK_ERR_USER=$(cat "$PR_ERRFILE" 2>/dev/null)
}

fire_raw() {  # <stdin-json>
  local _sid; _sid=$(printf '%s' "$1" | jq -r '.session_id // ""' 2>/dev/null) || _sid=""
  HOOK_OUT=$(env CLAUDE_CODE_SESSION_ID="$_sid" bash "$HOOK" <<< "$1" 2>/dev/null); HOOK_RC=$?
}

reason_of()   { printf '%s' "$HOOK_OUT" | jq -r '.reason // ""' 2>/dev/null; }
decision_of() { printf '%s' "$HOOK_OUT" | jq -r '.decision // ""' 2>/dev/null; }

expect_quiet() {  # <label>
  if [ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_OUT" ]; then
    ok "$1"
  else
    no "$1" "rc=$HOOK_RC stdout=<$HOOK_OUT>"
  fi
}

# A block is the JSON decision payload on stdout with rc 0 — the channel
# hooks/patrol-duties-gate.sh uses, and the one whose `reason` the CLI renders
# into the operator's terminal. That rendering IS the notice AC-F6 asks for:
# there is no second output surface here.
expect_block() {  # <label>
  local d; d=$(decision_of)
  if [ "$HOOK_RC" -ne 0 ]; then
    no "$1" "rc=$HOOK_RC (a JSON block exits 0); stdout=<$HOOK_OUT>"; return
  fi
  if [ "$d" != "block" ]; then
    no "$1" "decision=<$d> expected block; stdout=<$HOOK_OUT>"; return
  fi
  ok "$1"
}

expect_reason_names() {  # <label> <substring>
  local r; r=$(reason_of)
  case "$r" in
    *"$2"*) ok "$1" ;;
    *)      no "$1" "reason does not name <$2>: $r" ;;
  esac
}

section "Group 1: the three stamp states"

# 1: STALE — armed, and the clock stopped. The one state that speaks.
D=$(make_env); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 600
fire "$D"; expect_block "1: a STALE stamp blocks the stop"

# 2: FRESH — firings are landing. A monitor with nothing to say says nothing.
D=$(make_env); write_stamp "$D" "$SID"
fire "$D"; expect_quiet "2: a FRESH stamp is silent"

# 3: ABSENT — never armed. That is the dispatch wall's refusal to make at a
# dispatch, not a per-turn notice; a hook that spoke here would nag every session
# that has canonical-sdlc armed and has not engaged a run.
D=$(make_env)
fire "$D"; expect_quiet "3: an ABSENT stamp is silent — never armed is not death"

# 4: the boundary is 2x the interval, and it follows the project's own knob.
D=$(make_env 1m); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 100
fire "$D"; expect_quiet "4: 100s old against a 1m interval (limit 120s) is silent"

D=$(make_env 1m); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 200
fire "$D"; expect_block "5: 200s old against a 1m interval (limit 120s) blocks"

section "Group 2: the false-positive guards"

# A stamp belonging to ANOTHER session is not this session's Patrol. Without this
# the hook would raise a dead Patrol on a session that never had one.
D=$(make_env); write_stamp "$D" "$OTHER_SID"; backdate "$(stamp_path "$D" "$OTHER_SID")" 600
fire "$D"; expect_quiet "6: a stale stamp keyed to ANOTHER session is silent"

# SubagentStop is a WORKER's turn ending. A subagent arms no Patrol (SKILL.md
# §Dispatch: "subagents stay timerless"), and blocking its stop would hold a
# worker hostage to its orchestrator's clock — the exact exclusion
# hooks/patrol-duties-gate.sh makes.
D=$(make_env); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 600
fire "$D" "$SID" SubagentStop; expect_quiet "7: SubagentStop is silent"

D=$(make_env); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 600
fire "$D" "$SID" PreToolUse; expect_quiet "8: a non-Stop payload is silent"

# BLOCKS ONCE. The CLI re-enters the stop with stop_hook_active true after a hook
# blocked it; refusing again wedges a turn with no way out.
D=$(make_env); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 600
fire "$D" "$SID" Stop true; expect_quiet "9: stop_hook_active true passes — it blocks once"

# A symlink is not a stamp: the same posture every other .bionic/tmp reader takes.
# It reads as ABSENT, so a hostile repo can close this wall and never open one.
#
# THE LINK ITSELF IS BACKDATED, not only its target, and that is what makes this
# assertion discriminate. `[ -f ]` follows a link to a real file and both `stat -f`
# and `stat -c` read the LINK's own timestamp — so with a fresh link over a stale
# target the hook is silent whether or not the `-L` guard is there, and the test
# would pin nothing. Aged with `touch -h`, dropping the guard blocks.
D=$(make_env); OTHER=$(make_env); write_stamp "$OTHER" "$SID"
backdate "$(stamp_path "$OTHER" "$SID")" 600
ln -s "$(stamp_path "$OTHER" "$SID")" "$(stamp_path "$D" "$SID")"
_lts="$(date -v-600S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-600 seconds" +%Y%m%d%H%M.%S)"
touch -h -t "$_lts" "$(stamp_path "$D" "$SID")"
fire "$D"; expect_quiet "10: a symlinked stamp is silent, never followed"

# No session key, and a key that is not shaped like one: every path this hook
# reads interpolates it, so an unreadable key is an ambiguity, and an ambiguity
# passes.
D=$(make_env); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 600
fire_raw "$(jq -nc --arg c "$D" '{session_id:"",cwd:$c,hook_event_name:"Stop",stop_hook_active:false}')"
expect_quiet "11: no session key is silent"

fire_raw "$(jq -nc --arg c "$D" '{session_id:"../../etc",cwd:$c,hook_event_name:"Stop",stop_hook_active:false}')"
expect_quiet "12: a session key carrying path separators is silent"

# No cwd at all: nothing to root the stamp under.
fire_raw "$(jq -nc '{session_id:"11111111-2222-3333-4444-555555555555",cwd:"",hook_event_name:"Stop",stop_hook_active:false}')"
expect_quiet "13: an empty cwd is silent"

# jq itself absent: the hook cannot read its own payload, so it cannot decide.
#
# THE PAYLOAD IS BUILT BEFORE THE RESTRICTED PATH APPLIES (wave-01 S4, AC-11).
# `PATH="$NOJQ" bash "$HOOK" <<< "$(stdin_for "$D")"` is a temporary assignment
# on a simple command, and bash 3.2 has that assignment IN EFFECT while the
# here-string's command substitution is expanded, where bash 5.3 does not.
# `stdin_for` is itself a `jq` call and `jq` is the one program this directory
# deliberately omits — so, measured on this machine, the same line handed the
# hook `{"session_id":…}` under 5.3 and a bare newline under 3.2. Under the
# interpreter ADR-001 pins the fleet to, this assertion was passing on an EMPTY
# payload: a hook that cannot read a payload it was never given, which is a
# different fact from the one the label names.
D=$(make_env); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 600
# EVERYTHING BUT jq. The list this started as — nine programs — was short of
# what the hook actually runs (`INPUT=$(cat)` on its first working line), so
# the jq-present control below could not have spoken whatever the hook did.
# A directory that is missing eleven things does not test the absence of one.
NOJQ=$(mktemp -d)
for _b in bash sh cat date stat touch git grep sed awk dirname basename mktemp \
          tr head tail cut find rm ls printf realpath readlink id sort uniq wc env; do
  _p=$(command -v "$_b" 2>/dev/null) && ln -sf "$_p" "$NOJQ/$_b"
done
_PAYLOAD14=$(stdin_for "$D")
# AND THE SESSION KEY IS SET, THE WAY `fire` SETS IT. Without
# CLAUDE_CODE_SESSION_ID the hook resolves no session, matches no stamp and is
# silent on ANY input — measured here — so the call below was silent for that
# reason as much as for the missing jq. Two wrong reasons for one right answer.
if [ -n "$_PAYLOAD14" ]; then
  ok "14a: the jq-absent fixture built a real payload to hand the hook"
else
  no "14a: the jq-absent fixture handed the hook nothing" \
       "14 below would then pass for the wrong reason"
fi
_OUT=$(env CLAUDE_CODE_SESSION_ID="$SID" PATH="$NOJQ" bash "$HOOK" <<< "$_PAYLOAD14" 2>/dev/null); _RC=$?
if [ "$_RC" -eq 0 ] && [ -z "$_OUT" ]; then
  ok "14: jq absent — passes, silent"
else
  no "14: jq absent did not pass silently" "rc=$_RC stdout=<$_OUT>"
fi
# THE PAIRED POSITIVE, on the same payload and the same directory with jq put
# back. Silence is the easiest verdict in the world to get by accident, and
# every other reason this hook could be silent — a stamp the fixture failed to
# plant, a payload the hook rejects for some other reason, a hook that says
# nothing on any input — survives assertion 14 untouched. This is the arm that
# rules them out: change one program on the PATH and the same call speaks.
_jq_real=$(command -v jq 2>/dev/null) && ln -sf "$_jq_real" "$NOJQ/jq"
_OUT14B=$(env CLAUDE_CODE_SESSION_ID="$SID" PATH="$NOJQ" bash "$HOOK" <<< "$_PAYLOAD14" 2>/dev/null); _RC14B=$?
if [ "$_RC14B" -eq 0 ] && [ -n "$_OUT14B" ]; then
  ok "14b: …and with jq put back, that same payload DOES produce a finding"
else
  no "14b: the jq-present control said nothing either — 14 proves nothing" \
       "rc=$_RC14B stdout=<$_OUT14B>"
fi
rm -rf "$NOJQ"

# The poker unreachable on both lanes: no interval, therefore no threshold. A
# monitor that cannot measure has nothing to report — the same direction
# hooks/dispatch-preflight.sh takes for its own staleness half.
D=$(make_env); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 600
LONEDIR=$(mktemp -d); cp "$HOOK" "$LONEDIR/patrol-revive.sh"
_OUT=$(CLAUDE_CONFIG_DIR="$LONEDIR" bash "$LONEDIR/patrol-revive.sh" <<< "$(stdin_for "$D")" 2>/dev/null); _RC=$?
if [ "$_RC" -eq 0 ] && [ -z "$_OUT" ]; then
  ok "15: no sibling poker — passes, silent (no threshold, no finding)"
else
  no "15: a hook with no poker beside it did not pass silently" "rc=$_RC stdout=<$_OUT>"
fi
rm -rf "$LONEDIR"

section "Group 3: worktree resolution"

# THE STAMP LIVES AT THE MAIN REPOSITORY'S ROOT, always — hooks/session-poker.sh
# writes it there through the same `--git-common-dir` mapping, and a reader that
# rooted a worktree at its own tree would read an absent stamp and go silent for
# every turn a run spends in one. Both directions are driven: the main
# repository's stale stamp IS seen from a worktree cwd, and a stamp planted under
# the worktree's own tree is NOT what gets read.
WTBASE=$(mktemp -d)
WTREPO="$WTBASE/repo"; mkdir -p "$WTREPO"
git -C "$WTREPO" init -q 2>/dev/null
git -C "$WTREPO" config user.email t@example.com
git -C "$WTREPO" config user.name "T"
echo seed > "$WTREPO/README.md"
git -C "$WTREPO" add README.md >/dev/null 2>&1
git -C "$WTREPO" commit -qm seed >/dev/null 2>&1
mkdir -p "$WTREPO/.bionic/tmp" "$WTREPO/.bionic/docs/plans"
# A 300s interval, not the 1s the other groups use. Group 3 has a FRESH stamp on one side
# of every pair, and "fresh" against a 2s limit is a race with the machine: under a
# parallel suite run the stamp this fixture writes can be three seconds old before the
# hook reads it, and assertion 17 then blocks for a reason that is not the one under test.
# Staleness here is an mtime backdated by ten minutes against a two-minute limit, so both
# sides clear the boundary by an order of magnitude rather than by a second.
printf 'poker-interval: 60s\n' > "$WTREPO/.bionic/config.yaml"
# The open run this monitor is scoped by lives at the MAIN repository too — same
# mapping, same reason: a reader rooted at the worktree would find neither.
cat > "$WTREPO/.bionic/docs/plans/wave-01.plan.md" <<'PRWTPLAN'
---
canonical_sdlc_version: 14
---

## SDLC State

current: 4

- Step 4: slices in flight
PRWTPLAN
WT="$WTBASE/wt"
git -C "$WTREPO" worktree add -q -b pr-wt "$WT" >/dev/null 2>&1

write_stamp "$WTREPO" "$SID"; backdate "$(stamp_path "$WTREPO" "$SID")" 600
fire "$WT"; expect_block "16: a worktree cwd reads the MAIN repository's stale stamp"

# The mirror image: the main stamp is fresh, and a stale one is planted under the
# worktree's own tree. A reader rooted at the worktree would block on a Patrol
# that is firing perfectly.
write_stamp "$WTREPO" "$SID"
mkdir -p "$WT/.bionic/tmp"
write_stamp "$WT" "$SID"; backdate "$(stamp_path "$WT" "$SID")" 600
fire "$WT"; expect_quiet "17: a stale stamp under the WORKTREE's own tree is not read"
rm -rf "$WTBASE"

section "Group 4: what the notice says"

# A 1m interval, so the limit it reports is a deterministic 120s. The AGE is not
# asserted as a literal anywhere: a second can elapse between the backdate and the
# read, and a suite that pinned "600s" would flake on a slow machine. What is
# asserted is that an age is stated at all (assertion 22).
D=$(make_env 1m); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 600
fire "$D"

# The path is a computed fact, not prose: the operator (and the model re-arming)
# has to be able to see WHICH stamp went stale.
expect_reason_names "18: the notice names the stamp file" "$(stamp_path "$D" "$SID")"

# BOTH HALVES OF THE RE-ARM, and the CronCreate half first in importance: a re-arm
# that stamps without re-creating the cron job buys a Patrol that reads alive and
# never fires. This is the assertion tests/dispatch-preflight.test.sh S21 makes
# for the same reason.
expect_reason_names "19: …and the CronCreate half of the re-arm" "CronCreate"
expect_reason_names "20: …and the arm half, as a runnable command" "session-poker.sh arm"

# The hook is invoked as <plugin-root>/hooks/patrol-revive.sh, so the poker it
# names is the sibling it actually measured against — never a placeholder a model
# would paste into a `command not found` (SKILL.md §Dispatch, the resolved-root
# rule).
expect_reason_names "21: …with the poker resolved to an absolute path" "${BIONIC_HOOKS_DIR}/session-poker.sh arm"

# The measurement itself, so the notice is a finding rather than an assertion —
# an age in seconds, and the limit it was judged against, which follows the
# project's own knob (1m here, so 120s).
# MATCHED WITHOUT A PIPE INTO `grep -q`. Under `set -o pipefail` (line 37) a `grep -q` that
# exits on its first match SIGPIPEs the producer, and the pipeline reports 141 — this very
# assertion failed that way once on a reason that plainly said "600s old" (wave-1.3.2 slice
# 4/9). The text is captured first and matched in the shell.
R22_REASON="$(reason_of)"
if [[ "$R22_REASON" =~ [0-9]+s\ old ]]; then
  ok "22: …and states the age it measured"
else
  no "22: the notice states no age" "$R22_REASON"
fi
expect_reason_names "22b: …against the limit this project's interval sets" "120s limit"
expect_reason_names "22c: …naming that interval as its source" "60s poker-interval"

# Why the operator is seeing this at all: the cron table is in process memory and
# a plugin update takes it with no file left behind.
expect_reason_names "23: …and the cause the operator can act on" "plugin update"

# The way out. Without it a blocked stop reads as a wedge.
expect_reason_names "24: …and that it blocks once" "blocks once"

section "Group 5: it writes nothing, and stamps nothing"

# THE CENTRAL SAFETY PROPERTY. A hook that ran `arm` would satisfy the arming wall
# over an empty cron table — a Patrol that reads alive forever and fires never.
D=$(make_env); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 600
BEFORE_M=$(mtime_of "$(stamp_path "$D" "$SID")")
BEFORE_T=$(find "$D" -type f | sort | cksum)
fire "$D"
AFTER_M=$(mtime_of "$(stamp_path "$D" "$SID")")
AFTER_T=$(find "$D" -type f | sort | cksum)

if [ "$BEFORE_M" = "$AFTER_M" ]; then
  ok "25: the stamp's mtime is untouched — the hook never arms"
else
  no "25: the hook re-stamped the Patrol" "$BEFORE_M -> $AFTER_M"
fi

if [ "$BEFORE_T" = "$AFTER_T" ]; then
  ok "26: the hook creates and removes no file in the project"
else
  no "26: the hook touched the project tree" "$BEFORE_T -> $AFTER_T"
fi

section "Group 6: registration"

# A hook with a suite, a run line and no registration is installed, green in its
# own suite, and never fired.
#
# THE CHANNEL MOVED (bionic 1.4.0, slice ADOPT, spec AC-7). It was registered in the
# governing skill's frontmatter, which is what made this monitor share the failure mode
# it monitors: three of the four events that kill a Patrol also deregistered the hook,
# silently and at the same moment. It is in hooks/hooks.json now and survives all four —
# so BOTH halves are asserted, because either alone is a wall in the wrong place: a
# lingering frontmatter entry would fire it twice per turn (the CLI does not deduplicate
# across the two manifests), and a missing manifest entry would not fire it at all.
if grep -q '\${CLAUDE_PLUGIN_ROOT}/hooks/patrol-revive.sh' \
     "${BIONIC_HOOKS_DIR}/hooks.json"; then
  ok "28: hooks/hooks.json registers the hook, always on"
else
  no "28: the hook is not registered in hooks/hooks.json — it would never fire"
fi
# The REGISTRATION spelling, not any mention: the Patrol section names this hook in prose
# (it is what reports a Patrol death, and the disarm ritual exists because of it), and a
# grep for the bare filename would forbid the documentation along with the duplicate.
if grep -q '\${CLAUDE_PLUGIN_ROOT}/hooks/patrol-revive\.sh' \
     "${BIONIC_SKILLS_DIR}/canonical-sdlc/SKILL.md"; then
  no "28b: SKILL.md still registers the hook — a second registration fires it twice per turn"
else
  ok "28b: …and SKILL.md's frontmatter does not, so it fires exactly once"
fi

# 29: THE ASSERTION THAT WOULD HAVE CAUGHT THIS. The manifest registers
# this hook as a BARE PATH — `command: ${CLAUDE_PLUGIN_ROOT}/hooks/patrol-revive.sh`,
# no interpreter — and that is exactly how the CLI's own hook runner invokes it: a
# shell handed the literal path as the command, which requires the tracked file
# itself to carry the execute bit. Every other assertion in this suite drives the
# hook through `bash "$HOOK"`, which reads the file regardless of its mode bits and
# would stay green even if the tracked file were not executable — the walk that
# found this bug caught it by reproducing the registration exactly, and that is
# what this assertion now does: a bare path handed to `sh -c`, matching
# `sh -c ".../patrol-revive.sh"` verbatim.
sh -c "$HOOK" <<< '{"hook_event_name":"Stop"}' >/dev/null 2>&1
REGISTERED_RC=$?
if [ "$REGISTERED_RC" -ne 126 ]; then
  ok "29: the hook runs when invoked exactly as registered (bare path via sh -c, rc=$REGISTERED_RC)"
else
  no "29: rc=126 (Permission denied) invoking the hook as the manifest registers it — the tracked file lost its execute bit"
fi

section "Group 7: the deliberate stop — a removed stamp is what ends the notice"

# THE NOTICE IS PER-TURN, NOT ONCE PER SESSION, and that is the whole reason
# `session-poker.sh disarm` exists (critic C-2, epic-19 w1 Step 6). `stop_hook_active`
# suppresses the SECOND stop inside ONE turn; it resets at the next turn, so a stamp left
# stale blocks turn after turn with no operator action that stops it — and there is no CLI
# backstop above this hook, because blocks that are one-per-turn are never CONSECUTIVE.
#
# Nothing in production removed a stamp before the disarm verb, so both routine ways a run
# ends its own Patrol — the run-close `CronDelete` and the poker's own DISARM decision —
# produced exactly that unbounded loop. These cases drive it: five turns, five blocks, and
# then the two things that stop it.
POKER_FOR_DISARM="${BIONIC_HOOKS_DIR}/session-poker.sh"

D=$(make_env 1m); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 600
G7_BLOCKS=0
for _t in 1 2 3 4 5; do
  fire "$D"
  [ "$(decision_of)" = "block" ] && G7_BLOCKS=$((G7_BLOCKS + 1))
done
if [ "$G7_BLOCKS" -eq 5 ]; then
  ok "30: a stale stamp blocks EVERY turn — five turns, five blocks (the notice is per-turn)"
else
  no "30: the per-turn block is not what this hook does" "blocked $G7_BLOCKS of 5 turns"
fi

# THE CURE, THROUGH THE REAL VERB — never an `rm` in the test, which would pin this suite to
# its own idea of where the stamp lives instead of to the poker that owns it.
( cd "$D" && env CLAUDE_CODE_SESSION_ID="$SID" bash "$POKER_FOR_DISARM" disarm ) >/dev/null 2>&1
G7_RC=$?
if [ "$G7_RC" -eq 0 ] && [ ! -e "$(stamp_path "$D" "$SID")" ]; then
  ok "31: session-poker.sh disarm removes this session's stamp (rc=0)"
else
  no "31: disarm did not remove the stamp" \
       "rc=$G7_RC; still at $(stamp_path "$D" "$SID")"
fi

fire "$D"; expect_quiet "32: …and the very next turn is silent — the forever-block is over"

# THE OTHER PRODUCER, end to end. The poker's own DISARM decision — "the Patrol may stop" —
# is reached on every quiet stretch between dispatch batches, not only at run close. Its
# tick removes the stamp as its last act, so the turn that follows it is silent rather than
# a death notice demanding the re-arm the tick just said was unnecessary.
D=$(make_env 1m)
printf '# bionic session roster — schema roster-state/v1 — machine-local, safe to delete\n' \
  > "$D/.bionic/tmp/roster-$SID.state"
# THE ROSTER IS NO LONGER THE WHOLE PREDICATE (bionic 1.3.2, wave-1.3.2 slice 4/4). An empty
# roster on a run that has not delivered is a lull, not a finish, and the tick QUIETs and
# keeps its stamp — so this fixture has to say the run IS delivered to reach the DISARM this
# case is about. `current: 9` with `delivered:` on the Step-9 line is the only spelling
# hooks/session-poker.sh's run_state() accepts.
mkdir -p "$D/.bionic/docs/plans/epic-99"
{
  printf '# fixture plan\n\n## SDLC State\n\nintegration-branch: main\ncurrent: 9\n\n'
  printf -- '- Step 9: delivered: fixture run closed; report: record/fixture/close-out.md\n'
} > "$D/.bionic/docs/plans/epic-99/wave-01.plan.md"
# AND THE ORDERING IS STATED, NOT LEFT TO THE CLOCK. `make_env` plants a second plan at
# `plans/wave-01.plan.md` reading `current: 4`, and which of the two the tick resolves is
# `active_plan`'s newest-by-mtime pick. Both files are written inside the same second, so
# the pick comes down to how `[ "$f" -nt "$plan" ]` breaks a tie — and that is an
# INTERPRETER-DEPENDENT answer: bash 5 compares st_mtimespec to the nanosecond and calls the
# epic-99 plan newer, while bash 3.2 — the /bin/bash macOS ships — compares whole seconds,
# finds neither newer, and keeps the first candidate the walk produced. Measured, two files
# 61µs apart: 3.2.57 says `b -nt a` is FALSE, 5.3.15 says TRUE. Under the system interpreter
# this case therefore resolved the `current: 4` plan, the tick QUIETed on an undelivered run,
# and cases 33 and 34 failed for a reason that has nothing to do with DISARM. Backdating the
# other plan puts five whole seconds between them, which every interpreter agrees about.
backdate "$D/.bionic/docs/plans/wave-01.plan.md" 5
# ARMED THROUGH THE REAL VERB, and dated back, so the plan written a moment ago is a
# delivery that POSTDATES the arming — which is what the tick now requires before it will
# DISARM (R-13, critic C-4). A hand-written stamp alone leaves the session with no arming
# record at all, and the tick QUIETs rather than reaching the decision this case is about.
# ENGAGED (task-engaged-session, 2026-09-03): the poker's `tick` decides nothing in a
# session that never invoked the canonical-sdlc skill, so the one case in this file that
# drives a real tick has to say the session did. `arm`, on the line below, is deliberately
# not guarded and needs no marker.
: > "$D/.bionic/tmp/engaged-$SID.state"
( cd "$D" && env CLAUDE_CODE_SESSION_ID="$SID" bash "$POKER_FOR_DISARM" arm ) >/dev/null 2>&1
backdate "$(armed_path "$D" "$SID")" 600
backdate "$(stamp_path "$D" "$SID")" 600
G7_TICK=$( cd "$D" && env CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_CONFIG_DIR="$D/no-config" \
             bash "$POKER_FOR_DISARM" tick 2>&1 )
case "$G7_TICK" in
  *decision=DISARM*)
    if [ ! -e "$(stamp_path "$D" "$SID")" ]; then
      ok "33: a DISARM tick removes the stamp it wrote — the decision and the disk agree"
    else
      no "33: a DISARM tick left its stamp behind — the death notice fires on the next turn"
    fi
    ;;
  *) no "33: the fixture roster did not reach a DISARM decision" "$G7_TICK" ;;
esac

# THE DEATH NOTICE AFTER A DISARM IS LATE, NEVER ABSENT, and that is what this case has to
# reach. The tick stamps BEFORE it decides (liveness is firings landing), so a DISARM tick
# that left its stamp behind leaves a FRESH one: the session is quiet for one whole stale
# window and only then starts blocking on every turn, forever. A fire taken immediately
# after the tick is therefore silent whether or not the stamp was removed, and would pin
# nothing. Aging whatever survived the tick is what puts the two outcomes apart — with the
# stamp gone there is nothing to age and the hook is silent for good.
if [ -e "$(stamp_path "$D" "$SID")" ]; then
  backdate "$(stamp_path "$D" "$SID")" 600
fi
fire "$D"; expect_quiet "34: …and one stale window later there is still no notice to fire"

# ---------- what the notice says about the footgun in its own step 2 ----------
#
# STEP 1 IS THE REFUSABLE HALF. `CronCreate` is measured non-deterministically refusable by
# the auto-mode classifier (.bionic/docs/record/epic-19/w1/t3-probes.md finding 1), and a
# model that runs step 2 alone freshens the stamp over an EMPTY cron table — a Patrol that
# reads alive to this hook, to the arming wall and to /bionic:doctor, and never fires again.
# The header argues at length that this is strictly worse than the death it heals; the text
# has to carry that argument to the reader who acts on it, not just to the reader of the
# source.
D=$(make_env 1m); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 600
fire "$D"
expect_block "35: the stale fixture blocks, so there is a notice to read"
expect_reason_names "36: step 2 is conditional on step 1 in the text itself" \
  "ONLY IF step 1 succeeded"
expect_reason_names "37: …and a refused CronCreate is told to stop, not to arm" \
  "do NOT run step 2"
expect_reason_names "38: …and the deliberate-stop path is named, not left to be guessed" \
  "session-poker.sh disarm"

# ---------- the header's own honesty about its backstop ----------
#
# The retired sentence claimed the CLI overrides this hook "after 8 consecutive blocks".
# It cannot: `stop_hook_active` guarantees exactly one block per turn and the re-entry
# always passes, so the blocks are never consecutive and that override can never engage
# here. A limit accepted against a safety net that does not exist is the thing this pin
# exists to keep out — asserted as a PAIR, so the absence rests on an extractor proven to
# find text in this file.
if grep -q 'never consecutive' "$HOOK"; then
  ok "39: the header states why the CLI's consecutive-block override cannot engage here"
else
  no "39: the header does not say why the consecutive-block override cannot engage"
fi
if grep -q 'backstop above ours is the CLI' "$HOOK"; then
  no "39b: the header still claims a backstop that cannot fire for this hook"
else
  ok "39b: …and no longer claims that backstop as its own"
fi

section "Group 8: the second-stamp finding (bionic 1.4.0, AC-3)"
#
# THE CONTRACT UNDER TEST. One clock per run: a second FRESH `patrol-<sid>.state`
# belonging to ANOTHER session in this project's .bionic/tmp means two Patrol crons
# are both alive over the same project at once. This is a FINDING — a plain stderr
# line naming the stray session — not a block: the primary decision above is about
# THIS session's own dead clock, and a sibling's live clock is not this session's
# stop to refuse. One live stamp (this session's own) is silent on this arm.

# Captures stderr SEPARATELY, unlike fire() above (which discards it) — the finding
# is a diagnostic line, and this is the only way to read it.
fire_stderr() {  # <cwd> [session] [event] [stop_hook_active]
  HOOK_ERR=$(env CLAUDE_CODE_SESSION_ID="${2:-$SID}" bash "$HOOK" \
    <<< "$(stdin_for "$1" "${2:-$SID}" "${3:-Stop}" "${4:-false}")" 2>&1 >/dev/null)
  HOOK_RC=$?
}

FINDING_TEXT="a second live Patrol stamp for session"

# 40: TWO fresh stamps — this session's own, and another's — is a finding naming
# the other session's first 8 characters.
D=$(make_env); write_stamp "$D" "$SID"; write_stamp "$D" "$OTHER_SID"
fire_stderr "$D"
case "$HOOK_ERR" in
  *"patrol-revive: $FINDING_TEXT ${OTHER_SID:0:8}"*"one clock per run"*"delete the stray job and stamp"*)
    ok "40: two fresh stamps produce the finding line, naming the other session's first 8 chars" ;;
  *) no "40: no finding for a second fresh stamp" "$HOOK_ERR" ;;
esac

# 41: ONE stamp (this session's own alone) — silent on this arm.
D=$(make_env); write_stamp "$D" "$SID"
fire_stderr "$D"
case "$HOOK_ERR" in
  *"$FINDING_TEXT"*) no "41: a lone stamp wrongly produced the second-stamp finding" "$HOOK_ERR" ;;
  *) ok "41: one stamp — silent on the second-stamp arm" ;;
esac

# 42: the other stamp is STALE, not fresh — a dead predecessor is not "a second
# LIVE Patrol stamp"; this arm speaks only about a live duplicate clock.
D=$(make_env); write_stamp "$D" "$SID"; write_stamp "$D" "$OTHER_SID"
backdate "$(stamp_path "$D" "$OTHER_SID")" 600
fire_stderr "$D"
case "$HOOK_ERR" in
  *"$FINDING_TEXT"*) no "42: a STALE second stamp wrongly produced the finding" "$HOOK_ERR" ;;
  *) ok "42: a stale second stamp is silent — only a fresh duplicate is a finding" ;;
esac

# 43: a symlinked second stamp is not a stamp, same posture as this session's own
# (never followed — a hostile repo can close this arm and never open one).
D=$(make_env); write_stamp "$D" "$SID"
OTHERD=$(make_env); write_stamp "$OTHERD" "$OTHER_SID"
ln -s "$(stamp_path "$OTHERD" "$OTHER_SID")" "$(stamp_path "$D" "$OTHER_SID")"
fire_stderr "$D"
case "$HOOK_ERR" in
  *"$FINDING_TEXT"*) no "43: a symlinked second stamp wrongly produced the finding" "$HOOK_ERR" ;;
  *) ok "43: a symlinked second stamp is silent, never followed" ;;
esac
rm -rf "$OTHERD"

# ---------- Group 12: THE ENGAGEMENT SWITCH (AC-8) ----------
#
# Asked before the stamp is read at all, and each silence is paired with the finding the
# same fixture produces once the marker is back.

E=$(make_env 1s)
write_stamp "$E" "$SID"; backdate "$(stamp_path "$E" "$SID")" 600
fire "$E"
case "$HOOK_OUT" in
  *"Patrol"*) ok "44: engaged: a stale stamp is reported" ;;
  *) no "44: engaged: a stale stamp is reported" "out=<$HOOK_OUT>" ;;
esac
E_FINDING="$HOOK_OUT"

rm -f "$E/.bionic/tmp/engaged-$SID.state"
fire "$E"
if [ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_OUT" ]; then
  ok "45: the same stale stamp unengaged says nothing"
else
  no "45: the same stale stamp unengaged says nothing" "rc=$HOOK_RC out=<$HOOK_OUT>"
fi

# a SYMLINK at the marker path reads as absent, never followed.
E_DECOY=$(mktemp); printf 'plan=none\n' > "$E_DECOY"
ln -s "$E_DECOY" "$E/.bionic/tmp/engaged-$SID.state"
fire "$E"
if [ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_OUT" ]; then
  ok "46: a symlink at the marker path is not an engagement"
else
  no "46: a symlink at the marker path is not an engagement" "rc=$HOOK_RC out=<$HOOK_OUT>"
fi
rm -f "$E/.bionic/tmp/engaged-$SID.state" "$E_DECOY"

# and restoring it restores the finding, word for word — with the one number that is a
# CLOCK normalised out of both sides. The notice quotes the stamp's age in seconds, so two
# drives a second apart differ by a digit for a reason that has nothing to do with the
# switch, and pinning it would make this assertion fail on a slow machine and nowhere else.
: > "$E/.bionic/tmp/engaged-$SID.state"
fire "$E"
E_FINDING_N=$(printf '%s' "$E_FINDING" | sed -E 's/stamp is [0-9]+s old/stamp is Ns old/')
HOOK_OUT_N=$(printf '%s' "$HOOK_OUT" | sed -E 's/stamp is [0-9]+s old/stamp is Ns old/')
E_FINDING="$E_FINDING_N"; HOOK_OUT="$HOOK_OUT_N"
if [ "$HOOK_OUT" = "$E_FINDING" ]; then
  ok "47: re-engaged, the finding is byte-identical"
else
  no "47: re-engaged, the finding is byte-identical" "was <$E_FINDING> now <$HOOK_OUT>"
fi

setup_section "Group 9: active_run -> session_run (wave-session-bound-run S5)"
#
# THE CONTRACT UNDER TEST (design ledger AC-1/AC-3/AC-6). The run predicate at
# `:361` used to be `active_run "$REPO" >/dev/null || exit 0` — the newest open
# plan in the root, with no session input. It is now `session_run "$REPO" "$SID"`:
# a session BOUND to a plan proceeds (to the stamp check) on THAT plan alone,
# whatever else is open in the root; UNBOUND it falls back to the newest plan
# exactly as before, and says so on stderr; bound to a plan that has since
# closed, the hook takes exactly the branch it takes today when there is no open
# run at all — silent, exit 0 — and announces the closure first.

PLAN_A_REL="plan-a.plan.md"
PLAN_B_REL="plan-b.plan.md"

# make_env_two_plans [interval] -> project dir on stdout. Two OPEN plans, ages
# controlled by touch so B is decisively the newest-plan fallback target.
# ENGAGED, UNBOUND by default (make_env's own convention).
make_env_two_plans() {
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/.bionic/tmp" "$dir/.bionic/docs/plans"
  : > "$dir/.bionic/tmp/engaged-$SID.state"
  printf 'poker-interval: %s\n' "${1:-1s}" > "$dir/.bionic/config.yaml"
  cat > "$dir/.bionic/docs/plans/$PLAN_A_REL" <<'EOF'
---
canonical_sdlc_version: 14
---

## SDLC State

current: 4

- Step 4: plan A in flight
EOF
  cat > "$dir/.bionic/docs/plans/$PLAN_B_REL" <<'EOF'
---
canonical_sdlc_version: 14
---

## SDLC State

current: 4

- Step 4: plan B in flight
EOF
  touch -t 202601010000 "$dir/.bionic/docs/plans/$PLAN_A_REL"
  touch -t 202602010000 "$dir/.bionic/docs/plans/$PLAN_B_REL"
  printf '%s' "$dir"
}

# s5_bind <project> <plan-rel-under-docs-plans> — MUST run after write_stamp,
# which (by design, task-engaged-session) resets the marker to empty/unbound.
s5_bind() {
  { printf 'plan=%s/.bionic/docs/plans/%s\n' "$1" "$2"
    printf 'engaged_at=2026-09-04T00:00:00Z\n'
  } > "$1/.bionic/tmp/engaged-$SID.state"
  chmod 600 "$1/.bionic/tmp/engaged-$SID.state"
}

# s5_deliver <plan-abs-path> — closes a plan (Step 9, delivered).
s5_deliver() {
  cat > "$1" <<'EOF'
---
canonical_sdlc_version: 14
---

## SDLC State

current: 9

- Step 9: report record/x.md, delivered: 2026-09-04
EOF
}

section "48: bound-open — proceeds (a stale stamp still blocks), no fallback line"

D=$(make_env_two_plans); write_stamp "$D" "$SID"; s5_bind "$D" "$PLAN_A_REL"
backdate "$(stamp_path "$D" "$SID")" 600
fire "$D"; expect_block "48a: bound to A, a stale stamp still blocks (the predicate did not exit early)"
fire_stderr "$D"
case "$HOOK_ERR" in
  *"run resolved by newest-plan fallback"*) no "48b: bound to A prints no fallback line" "$HOOK_ERR" ;;
  *) ok "48b: bound to A prints no fallback line" ;;
esac

section "49: fallback — unbound resolves to the newest plan (B), and says so"

D=$(make_env_two_plans); write_stamp "$D" "$SID"
backdate "$(stamp_path "$D" "$SID")" 600
# PHYSICAL, because the fallback path comes off active_plan's own resolution —
# `project_root` calls `pwd -P` internally — while `$D` is `mktemp -d`'s raw
# (logical) answer; see patrol-duties-gate.test.sh's own note on this (S5).
D_PHYS=$(cd "$D" && pwd -P)
fire "$D"; expect_block "49a: unbound, a stale stamp still blocks (the predicate did not exit early)"
fire_stderr "$D"
case "$HOOK_ERR" in
  *"patrol-revive: run resolved by newest-plan fallback (session unbound) — $D_PHYS/.bionic/docs/plans/$PLAN_B_REL"*)
    ok "49b: unbound prints the fallback line, naming B (the newest) verbatim" ;;
  *) no "49b: unbound prints the fallback line, naming B (the newest) verbatim" "$HOOK_ERR" ;;
esac

section "50: bound-closed — a plan that closed is no open run at all"

D=$(make_env_two_plans); write_stamp "$D" "$SID"
s5_deliver "$D/.bionic/docs/plans/$PLAN_A_REL"
s5_bind "$D" "$PLAN_A_REL"
backdate "$(stamp_path "$D" "$SID")" 600
fire "$D"
if [ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_OUT" ]; then
  ok "50a: bound to a CLOSED plan (A), the hook is silent — same branch as no open run"
else
  no "50a: bound to a CLOSED plan (A), the hook is silent — same branch as no open run" \
    "rc=$HOOK_RC out=<$HOOK_OUT>"
fi
fire_stderr "$D"
case "$HOOK_ERR" in
  *"patrol-revive: bound plan closed — $D/.bionic/docs/plans/$PLAN_A_REL; this session has no open run"*)
    ok "50b: the closed-plan advisory names A, verbatim" ;;
  *) no "50b: the closed-plan advisory names A, verbatim" "$HOOK_ERR" ;;
esac
case "$HOOK_ERR" in
  *"$PLAN_B_REL"*) no "50c: B's path (the still-open plan) appears nowhere in the output" "$HOOK_ERR" ;;
  *) ok "50c: B's path (the still-open plan) appears nowhere in the output" ;;
esac

section "AC-E1.3/E1.5: the refusal's user stream is one line, in the criterion's shape"

# fails-when: a refusal reaches the user as more than one line, or in any shape but
# `bionic: <verb> refused — <fact> (<fix ≤ 40 cols>)`. This gate refuses over the JSON
# `block` channel, whose model-only wire keeps the whole reason for the model while the
# user stream is the single rendered line. The refusal is tripped through the same
# `fire` helper every arm above uses, so nothing here drives a path the suite invented.

PR_E1_RE='^bionic: [a-z-]+ refused — .+ \(.{1,40}\)$'
# A KNOWN BLOCKING FIXTURE, built the way Group 1 builds one: armed, and the clock
# stopped. Reusing the suite's own helpers rather than inventing a path.
D=$(make_env); write_stamp "$D" "$SID"; backdate "$(stamp_path "$D" "$SID")" 600
fire "$D"
expect_status "E1.3 the stale-stamp fixture still blocks (exit 0 with a verdict)" "0" "$HOOK_RC"
PR_E1_LINE=$(printf '%s\n' "$HOOK_ERR_USER" | /usr/bin/grep '^bionic: ' || true)
expect_eq "E1.3 the last refusal left exactly one rendered line on the user stream" \
  "1" "$(printf '%s\n' "$HOOK_ERR_USER" | /usr/bin/grep -c '^bionic: ')"
if printf '%s' "$PR_E1_LINE" | /usr/bin/grep -qE "$PR_E1_RE"; then
  ok "E1.3 …in AC-E1.3's shape"
else
  no "E1.3 …in AC-E1.3's shape" "line=[$PR_E1_LINE]"
fi
expect_eq "E1.3 …and it is the table's own wording (row 114)" \
  "bionic: stop refused — the Patrol died mid-run and nothing said so (re-arm it, the clock first)" \
  "$PR_E1_LINE"
expect_absent "E1.5 the paragraph the model reads is NOT on the user stream" \
  "blocks once per turn" "$HOOK_ERR_USER"
expect_contains "E1.5 …and the model still gets it whole, on the JSON wire" \
  "blocks once per turn" "$(reason_of)"

finish
