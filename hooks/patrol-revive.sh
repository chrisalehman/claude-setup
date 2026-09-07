#!/bin/bash
# THE PATROL SELF-HEAL — epic-19 wave-01, spec AC-F6; design ledger D4, ratified
# 2026-08-27 ("Simply update the user in the terminal of the issue, and reload the
# Patrol").
#
# WHAT IT IS FOR. The CLI holds its cron table in PROCESS MEMORY, with no file
# behind it (payload/scripts/lib/patrol.sh's own honest limit, and doctor's). A
# `claude plugin update`, a `/reload-plugins`, a session continue or a
# `/clear`+resume can therefore delete the Patrol job and leave nothing that says
# so: the run keeps working, the poker never ticks again, no row is ever judged
# against its declared duration, and the fleet dies quiet. The stamp goes stale one
# window later — but only where somebody LOOKS, and until this hook existed the
# only two places that looked were a dispatch attempt (hooks/dispatch-preflight.sh's
# arming wall) and a hand-run `/bionic:doctor`. Between them, nothing observed it
# and nothing told anyone. This hook is the thing that looks, every turn.
#
# WHY THE STOP CHANNEL, and not one of the stop hooks that already exist. The
# detection has to fire on the run's own rhythm rather than on a dispatch — that is
# the whole gap. `Stop` is the only recurring orchestrator event there is: it fires
# once per turn, whatever the turn contained, and it keeps firing on turns the skill
# was not re-invoked on (hooks/landing-gate.sh depends on and documents those exact
# properties). hooks/stop-guard.sh is `PreToolUse|TaskStop` — it fires when the
# orchestrator stops an AGENT, which is neither recurring nor about the session's
# clock; hooks/stop-check.sh is not registered on any channel at all. So the choice
# was Stop or nothing.
#
# WHY A BLOCK AND NOT A PRINT. A shell hook cannot call `CronCreate` — that is a
# model tool, and re-creating the cron job is half of what "reload the Patrol"
# means. What a Stop hook CAN do is refuse the stop once with a `reason`, which the
# CLI renders into the operator's terminal and hands to the model as the next thing
# to act on. One mechanism therefore carries both halves of AC-F6: the reason IS the
# terminal notice, and it is also the instruction that gets the Patrol re-armed. The
# pattern is hooks/patrol-duties-gate.sh's, registered beside it on the same channel.
#
# IT MUST NEVER ARM THE STAMP ITSELF, and this is the sharpest edge in the file. A
# hook that ran `session-poker.sh arm` would freshen the stamp over a cron table
# that still holds nothing — buying a Patrol that reads alive to the arming wall,
# to doctor and to this hook, and that never fires again. That is strictly worse
# than the death it was meant to heal, because the death is at least detectable.
# So this gate READS, exactly like every other gate (TDD §3.2), and the re-arm is
# named in the reason with its cron half FIRST. tests/patrol-revive.test.sh Group 5
# pins the stamp's mtime across a firing.
#
# THE THREE STAMP STATES, and why only one of them speaks:
#   absent  -> silent. Never armed, OR deliberately disarmed — `session-poker.sh
#              disarm` removes the stamp, which is how a run says its Patrol was
#              ended on purpose. Never-armed is a real finding, but it is the ARMING
#              WALL's to make at the moment a dispatch is attempted; raised here it
#              would nag every session that has the skill armed and has not engaged
#              a run yet, which is the first turn of every run.
#   fresh   -> silent. Firings are landing; a monitor with nothing to say says so
#              by saying nothing.
#   stale   -> THE NOTICE. Something armed a Patrol on THIS session and the clock
#              has stopped.
#
# SCOPE — WHAT "AN ACTIVE RUN" IS HERE. Two conditions, and no third. First, this
# project has an OPEN RUN: `session_run` (which was `active_run` until
# wave-session-bound-run made run identity per-session) under the payload's project root,
# the same fact every other governance hook is scoped by since bionic 1.4.0. Second, a stamp
# EXISTS for this session, which by doctrine (SKILL.md §Dispatch) happens at the
# Step-0 confirmation of a new run or the resume ritual of an open one, and at no
# other moment. An armed-then-stale stamp is therefore already the statement "a run
# engaged on this session and its clock died".
#
# THE FIRST CONDITION USED TO BE "the governing skill is armed", and reading the plan
# was REJECTED on two grounds. Both are answered now. It would have been a fifth
# hand-copy of the active-wave block — there is one reader, `lib/run.sh`, and no copy
# to drift. And it would have imported a measured silent-inert mode: a marker-less
# `*.md` winning the newest-file race disarmed the dispatch wall repo-wide for ~15
# minutes on 2026-08-15 (record/session-20260815-landing-supervision/
# t8-forensic-read.md). That mode lived in the copies' selection rule, not in the
# question; `active_plan` requires an unfenced `## SDLC State` heading, which is
# exactly the filter whose absence caused it. A monitor whose job is to notice
# silence must not acquire a new way to go silent — and the alternative it now
# replaces was a worse one, because a skill registration goes quiet without leaving
# anything on disk to notice.
#
# A SECOND ARM, ADDED FOR bionic 1.4.0 (spec AC-3, plan slice STOPGATES): ONE CLOCK
# PER RUN. This session having a stamp of its own says a Patrol was armed here; a
# second FRESH `patrol-<other-sid>.state` in the SAME project's `.bionic/tmp` says
# another one is ALSO alive right now — the duplicate-clock shape S5's ritual
# exists to prevent, caught here even when it happens without a /clear or resume in
# between (a stray `CronCreate` run twice, or two sessions racing an `arm`). This is
# a FINDING, not a block: it is a stderr diagnostic line, exactly `loader_fail_open`'s
# voice, because a sibling's live clock is not this session's stop to refuse — only
# its own dead one is. Read AFTER the threshold is known (so it shares the same
# staleness measurement) and BEFORE this session's own stale/fresh decision, so it
# fires whichever way that decision goes.
#   - the other stamp is this session's own                    -> not counted
#   - the other stamp is a symlink                              -> not counted, never followed
#   - the other stamp's mtime is unreadable                     -> not counted
#   - the other stamp is STALE (past the same 2x limit)          -> not counted, silent
#   - the other stamp is FRESH                                   -> one stderr finding line, naming its session
#   - exactly one live stamp (this session's own, no others)     -> silent on this arm
#
# FAIL DIRECTIONS (pinned by tests/patrol-revive.test.sh):
#   - jq absent                                       -> pass, silent
#   - not a Stop payload (SubagentStop included)      -> pass, silent
#   - stop_hook_active true                           -> pass, silent (ONE block per
#                                                        turn, not one per session)
#   - no session_id, or one not shaped like one       -> pass, silent
#   - no cwd, or no resolvable project root           -> pass, silent
#   - no stamp, or a symlink where the stamp goes     -> pass, silent (never armed,
#                                                        or deliberately disarmed)
#   - no poker on either lane, or no readable interval-> pass, silent (no threshold)
#   - the stamp's mtime unreadable                    -> pass, silent
#   - stamp age within 2x the poker-interval          -> pass, silent
#   - stamp age past it                               -> BLOCK, naming the re-arm
#
# THREE ACCEPTED LIMITS. First, inherited from the stamp and shared with the arming
# wall: this attests that Patrol FIRINGS ARE LANDING and cannot see the cron table,
# so a job deleted moments ago still looks alive for up to one stale window — the
# notice is late by design rather than wrong. Second, and now CLOSED where it
# used to be unbounded: a deliberate stop was indistinguishable from a death.
# Nothing in production removed a stamp, so a Patrol the run ended on purpose —
# the run-close `CronDelete`, or the poker's own DISARM decision, which is reached
# on every quiet stretch between dispatch batches — left an aging stamp behind and
# was reported dead here on EVERY remaining turn of the session. This notice does
# not "block once" in the sense that matters: `stop_hook_active` suppresses only
# the second stop WITHIN one turn and resets at the next, so the blocks are one
# per turn, forever, and the CLI's own override after 8 CONSECUTIVE blocks can
# never engage above us because one-per-turn blocks are never consecutive. There
# is no backstop; the stamp going away is the whole of the exit (critic C-2,
# epic-19 w1). `session-poker.sh disarm` is what makes it go away: the run-close
# ritual (SKILL.md §Dispatch) and a DISARM tick both take it, and an ABSENT stamp
# is silent here by design. WHAT REMAINS is a disarm that FORGOT the verb — a
# `CronDelete` with no `disarm` beside it — which still reads as a death; its cost
# is one re-armed clock on a run that was nearly over, against a fleet nobody is
# waiting on for the opposite error.
#
# Third, THIS HOOK NO LONGER SHARES THE FAILURE MODE IT MONITORS — and that reversal
# is the point of bionic 1.4.0's always-on registration. It used to be registered in
# the governing skill's own frontmatter, where a skill's hooks die with the
# conversation that armed them: three of the four events that kill a Patrol — a
# session continue, a `/clear` + resume, a `/reload-plugins` — deregistered this hook
# itself, silently and at the same moment, so the monitor died with the thing it
# monitors and its real coverage was the one remaining event, a `claude plugin update`
# mid-session. It is registered once in hooks/hooks.json now and survives all four.
# What remains outside its reach is narrower and structural: an event that stops the
# CLI from delivering `Stop` at all.
#
# Registered once on the Stop channel in hooks/hooks.json, always on, and scoped by
# `session_run` (which was `active_run` until wave-session-bound-run made run identity
# per-session) plus this session's own stamp — both facts on disk.
# [WALL: tests/patrol-revive.test.sh]

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat)

_jq() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }

# THIS SCRIPT'S OWN DIRECTORY, so the poker it measures against and the poker it
# NAMES are the same file — resolved the way hooks/dispatch-preflight.sh resolves
# its sibling, never through PATH (a hook's PATH is not ours to trust) and never
# through an env seam (a seam on the path under test leaves the production path
# unverified).
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || HOOK_DIR="$(dirname "$0")"

# ---------- relevance hoist ----------
# SubagentStop is deliberately NOT accepted. A subagent arms no Patrol — SKILL.md
# §Dispatch, "subagents stay timerless" — so a worker's turn end can prove nothing
# about the orchestrator's clock, and refusing it would hold a worker hostage to
# its dispatcher's obligations.
[ "$(_jq '.hook_event_name')" = "Stop" ] || exit 0

# BLOCKS ONCE PER TURN, which is not the same as once. Claude Code re-enters the
# stop with stop_hook_active true after a hook blocked it; refusing a second time
# would wedge the turn with no way out. One refusal names the re-arm; the second
# stop is the orchestrator's to decide about. That re-entry is this hook's safety
# valve — nothing it demands can ever be unsatisfiable, because stopping again
# always passes — but the flag resets at the NEXT turn, so a stamp that stays
# stale is a notice that returns turn after turn. What ends it is the stamp: a
# re-arm freshens it, `session-poker.sh disarm` removes it, and nothing else does.
[ "$(_jq '.stop_hook_active')" = "true" ] && exit 0

# Every path below interpolates the session key, and the stamp filename is the
# whole of what this hook reads — so a key carrying a path separator would leave
# the directory the guards are about. Session ids are harness-minted UUIDs, so
# this refuses nothing real; it is the same belt hooks/dispatch-preflight.sh wears
# on the same value, taken in the same direction: pass, silent.
PAYLOAD_SID=$(_jq '.session_id')

CWD=$(_jq '.cwd')
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0
# ---------- the library ----------
#
# One loader idiom, byte-identical in every hook (spec AC-16). FAIL OPEN: a monitor
# that refused a stop because a file was missing would be a worse outage than the one
# it watches for.
BIONIC_LIB_WANT="root.sh run.sh session.sh"
# --- bionic-loader/v2 BEGIN
# Find the bionic library. This text is pasted BYTE-IDENTICALLY into every hook; a
# library cannot load itself, so the duplication is the design and
# tests/cross-gate-agreement.test.sh pins every copy against `bionic_loader_pin` in
# payload/scripts/lib/loader.sh. Behaviour: tests/loader.test.sh.
#
# CONTRACT. Set BIONIC_LIB_WANT to the space-separated basenames this hook sources,
# on a line above this block. Afterwards exactly one of these is non-empty:
#   BIONIC_LIB          a readable directory holding every wanted basename
#   BIONIC_LIB_MISSING  the library this hook wanted and did not get
# BIONIC_LIB_CANDS always lists, in order, every location that was tried.
#
# CANDIDATES. Later classes are evaluated only after the earlier ones fail, so a
# healthy hook pays nothing for the healing path — not a jq, not a registry read.
#  (1) beside the hook. TWO SPELLINGS OF ONE DIRECTORY, because the shipped tree has
#      two real shapes: the installed plugin root, where hooks/ and scripts/ are
#      siblings, and the repo, where payload/hooks is a symlink to the top-level
#      hooks/ and the library lives under payload/scripts/lib. "$0" is textual and
#      `..` is resolved by the kernel AFTER the symlink, so the first spelling alone
#      would find nothing in a directory-source session.
#  (2) the marketplace SOURCE TREE. installed_plugins.json names the marketplace this
#      plugin was installed from; that marketplace's source.path in
#      known_marketplaces.json is the tree. The marketplace is read, never assumed:
#      a fork installs under its own name.
#  (3) the newest version directory in that marketplace's plugin cache, by
#      THREE-INTEGER compare — 1.10.0 beats 1.3.2, which a lexical sort gets backwards.
# (2) and (3) heal a partial breakage: one location damaged, a sibling intact. An
# upstream-broken publish breaks every location equally and is not covered.
#
# TESTS OVERRIDE THE MACHINE, never the reverse. BIONIC_PLUGINS_DIR (default
# "$HOME/.claude/plugins") is the only door to the registry and the cache.
BIONIC_LIB=""; BIONIC_LIB_MISSING=""; BIONIC_LIB_CANDS=""
_bl_dir="$(dirname "$0")"
_bl_want="${BIONIC_LIB_WANT:-}"
_bl_try() {
  [ -n "${1:-}" ] || return 1
  if [ -z "$BIONIC_LIB_CANDS" ]; then BIONIC_LIB_CANDS="$1"; else BIONIC_LIB_CANDS="$BIONIC_LIB_CANDS, $1"; fi
  [ -d "$1" ] || return 1
  for _bl_f in $_bl_want; do [ -r "$1/$_bl_f" ] || return 1; done
  BIONIC_LIB="$1"
}
if ! _bl_try "$_bl_dir/../scripts/lib" && ! _bl_try "$_bl_dir/../payload/scripts/lib"; then
  _bl_pd="${BIONIC_PLUGINS_DIR:-${HOME:-/nonexistent}/.claude/plugins}"
  _bl_mk=""
  if [ -r "$_bl_pd/installed_plugins.json" ]; then
    # First key only, and the prefix stripped by parameter expansion rather than
    # `sed | head`: the block's only external commands are `dirname` and `jq`, and
    # `jq` runs with its stderr closed, so a machine missing jq degrades to
    # BIONIC_LIB_MISSING in silence instead of printing a shell diagnostic.
    _bl_keys="$(jq -r '(.plugins // {}) | keys[] | select(startswith("bionic@"))' "$_bl_pd/installed_plugins.json" 2>/dev/null)"
    _bl_mk="${_bl_keys%%
*}"
    _bl_mk="${_bl_mk#bionic@}"
  fi
  if [ -n "$_bl_mk" ]; then
    _bl_src=""
    if [ -r "$_bl_pd/known_marketplaces.json" ]; then
      _bl_src="$(jq -r --arg mk "$_bl_mk" '.[$mk].source.path // empty' "$_bl_pd/known_marketplaces.json" 2>/dev/null)"
    fi
    if [ -n "$_bl_src" ]; then _bl_try "$_bl_src/payload/scripts/lib" || :; fi
    if [ -z "$BIONIC_LIB" ]; then
      _bl_best=""; _bl_bestk=""
      for _bl_v in "$_bl_pd/cache/$_bl_mk/bionic"/*; do
        [ -d "$_bl_v" ] || continue
        _bl_n="${_bl_v##*/}"
        case "$_bl_n" in ''|*[!0-9.]*) continue ;; esac
        _bl_x1=""; _bl_x2=""; _bl_x3=""
        IFS=. read -r _bl_x1 _bl_x2 _bl_x3 _bl_rest <<BIONIC_LOADER_VER
$_bl_n
BIONIC_LOADER_VER
        _bl_k="$(printf '%05d%05d%05d' "$((10#${_bl_x1:-0}))" "$((10#${_bl_x2:-0}))" "$((10#${_bl_x3:-0}))" 2>/dev/null)" || continue
        if [ -z "$_bl_bestk" ] || [ "$_bl_k" \> "$_bl_bestk" ]; then _bl_bestk="$_bl_k"; _bl_best="$_bl_n"; fi
      done
      if [ -n "$_bl_best" ]; then _bl_try "$_bl_pd/cache/$_bl_mk/bionic/$_bl_best/scripts/lib" || :; fi
    fi
  fi
fi
if [ -z "$BIONIC_LIB" ]; then
  # The name in the message is the first library this hook asked for. A candidate
  # directory qualifies only when it holds ALL of them, so with none qualifying the
  # first wanted name is the honest thing to hand the reader.
  BIONIC_LIB_MISSING="${_bl_want%% *}"
  [ -n "$BIONIC_LIB_MISSING" ] || BIONIC_LIB_MISSING="scripts/lib"
fi
# FAIL OPEN — for every hook whose work is advisory or reversible. One line, then
# stand aside. Blocking reversible work because a file is missing buys no safety and
# costs the session.
loader_fail_open() {
  echo "$1: library ${BIONIC_LIB_MISSING:-the bionic library} not found at ${BIONIC_LIB_CANDS:-(no candidate)} — hook stepping aside; run /bionic:doctor" >&2
  exit 0
}
# FAIL CLOSED — for a wall over an irreversible action. Refuse, but never lock the
# user out of the repair: four commands are permitted by WHOLE-STRING match, checked
# here, before the hook sources anything. Whole-string and not prefix, so
# `claude plugin update bionic@bionic; git push origin main` is refused like any
# other push. There is no env-var override: a variable an agent turn can set on
# itself is not a wall.
loader_fail_closed() {
  _bl_root="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd -P)" || _bl_root=""
  [ -n "$_bl_root" ] || _bl_root="$(dirname "$0")/.."
  case "${2:-}" in
    "claude plugin update bionic@bionic"|\
    "claude plugin install bionic@bionic"|\
    "bash $_bl_root/scripts/doctor.sh"|\
    "bash $_bl_root/scripts/setup.sh") exit 0 ;;
  esac
  cat >&2 <<BIONIC_LOADER_REFUSE
BLOCKED: $1 cannot load its library (${BIONIC_LIB_MISSING:-the bionic library}), so it
cannot read this command. A wall that cannot read a command refuses it rather than
waving it through.

Looked in: ${BIONIC_LIB_CANDS:-(no candidate)}

Until the plugin is whole again this wall permits exactly four commands, each matched
as a whole string:

    claude plugin update bionic@bionic
    claude plugin install bionic@bionic
    bash $_bl_root/scripts/doctor.sh
    bash $_bl_root/scripts/setup.sh

Anything else is refused, including one of those four with another command chained
after it. Run one of them, or act from your own terminal.
BIONIC_LOADER_REFUSE
  exit 2
}
# --- bionic-loader/v2 END
if [ -n "$BIONIC_LIB_MISSING" ]; then loader_fail_open "patrol-revive"; fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/root.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/run.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/session.sh"

REPO=$(project_root "$CWD")
[ -n "$REPO" ] && [ -d "$REPO" ] || exit 0

# THE SESSION KEY, from the library (design §1): env primary, payload witness. The stamp
# filename is built from it and hooks/session-poker.sh writes that filename from its own
# reading, so the two have to ask one reader or this monitor watches a file nothing
# writes. Session ids are harness-minted UUIDs, so the shape check below refuses nothing
# real; it is the same belt hooks/dispatch-preflight.sh wears on the same value, taken in
# the same direction: pass, silent.
SID=$(session_id "$PAYLOAD_SID" 2>/dev/null) || SID=""
[ -n "$SID" ] || exit 0
case "$SID" in *[!A-Za-z0-9_-]*) exit 0 ;; esac

# ---------- THE ENGAGEMENT SWITCH — asked before anything else ----------
#
# task-engaged-session: bionic's walls are the RUN's, not the repo's, and a run is entered
# by invoking canonical-sdlc. A session that never did is a bystander here and must not see
# a refusal, an advisory, or a state write from this hook. `engaged_session` (lib/run.sh) is
# true only for a REGULAR file at `.bionic/tmp/engaged-<sid>.state`; every unreadable state —
# absent, symlink, foreign sid, `unknown` — reads as NOT engaged. Silent, exit 0: the
# direction §7 gives every start-side ambiguity, and here it is the consent boundary itself
# (1.3.2 close-out ruling — the arming partition IS the consent boundary).
engaged_session "$REPO" "$SID" || exit 0

# ---------- THE RUN PREDICATE (AC-7, AC-8) ----------
#
# The first of this hook's two scope conditions (see SCOPE in the header). No open run,
# no Patrol to be dead, and nothing for a monitor to say.
#
# PLAN-BOUND AND KEPT (task-engaged-session). This hook has exactly one arm and its whole
# subject is a Patrol serving a run: the duties a revived Patrol would resume — FILL, the
# task-list refresh, the roster read — are the run's, so a session engaged with no plan yet
# has nothing for this monitor to be about. Engagement decides WHETHER; here the plan still
# decides WHAT, and there is only the one thing.
#
# wave-session-bound-run S5: `active_run` (no session input) is now `session_run`
# (lib/run.sh) — a session BOUND to a plan proceeds on THAT plan alone, whatever
# else is open in the root (AC-1); UNBOUND falls back to the newest plan exactly
# as before, and this hook says so once on stderr (AC-3); bound to a plan that
# has since closed takes exactly this line's existing branch — exit 0 — after
# announcing the closure (AC-6).
_RUN_VERDICT=$(session_run "$REPO" "$SID")
_RUN_WORD="${_RUN_VERDICT%% *}"
_RUN_PLAN="${_RUN_VERDICT#* }"
case "$_RUN_WORD" in
  bound-open) : ;;
  fallback)
    echo "patrol-revive: run resolved by newest-plan fallback (session unbound) — $_RUN_PLAN" >&2
    ;;
  bound-closed)
    echo "patrol-revive: bound plan closed — $_RUN_PLAN; this session has no open run" >&2
    exit 0
    ;;
  none|*)
    exit 0
    ;;
esac

# ---------- was a Patrol ever armed on this session ----------
#
# The filename is hooks/session-poker.sh's, and the two spellings are held together
# by tests/cross-gate-agreement.test.sh §P so a rename on one side cannot go quiet
# on the other. A symlink is not a stamp: it reads as ABSENT rather than being
# followed, which is the posture every other .bionic/tmp reader takes and the
# direction §8 requires — a hostile repo may CLOSE a wall and must never OPEN one.
STAMP_FILE="$REPO/.bionic/tmp/patrol-${SID}.state"
[ -L "$STAMP_FILE" ] && exit 0
[ -f "$STAMP_FILE" ] || exit 0

# ---------- the threshold ----------
#
# THE INTERVAL IS THE POKER'S OWN, obtained by invoking its `interval` verb rather
# than by re-reading `poker-interval:` here: one knob, one reader. A malformed
# override makes the poker refuse, and the fallback is its own built-in default
# asked for through `interval-default` — never a constant retyped here, which would
# drift the first time either side moved and leave this hook measuring against a
# threshold nobody configured.
#
# NO NUMBER MEANS NO FINDING. Where hooks/dispatch-preflight.sh still has a
# never-armed arm to run without a threshold, this hook's only question IS the
# threshold — so an unreadable interval leaves it with an ambiguity rather than a
# finding, and it takes the direction every start-side ambiguity in this fleet
# takes: pass, silent. A per-turn gate is also the worst possible place to be loud
# about a condition it cannot measure.
POKER="${HOOK_DIR}/session-poker.sh"
[ -f "$POKER" ] || POKER="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/session-poker.sh"
[ -f "$POKER" ] || exit 0

INTERVAL=$( cd "$REPO" 2>/dev/null && bash "$POKER" interval 2>/dev/null )
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL="" ;; esac
if [ -z "$INTERVAL" ] || [ "$INTERVAL" -le 0 ]; then
  INTERVAL=$( bash "$POKER" interval-default 2>/dev/null )
  case "$INTERVAL" in ''|*[!0-9]*) INTERVAL="" ;; esac
fi
[ -n "$INTERVAL" ] && [ "$INTERVAL" -gt 0 ] || exit 0

# 2x, exactly as the arming wall measures it: a Patrol firing on its interval is,
# at any random instant, up to one whole interval stale while perfectly healthy.
LIMIT=$(( INTERVAL * 2 ))

# ---------- the second-stamp finding (AC-3): one clock per run ----------
#
# Every OTHER patrol-*.state beside this session's own, in the same .bionic/tmp,
# judged against the SAME limit — a fresh one is a live duplicate clock, worth a
# finding whether or not THIS session's own clock turns out to be stale or fine.
_rival_now="$(date -u +%s 2>/dev/null || echo 0)"
for _rival_sf in "$REPO"/.bionic/tmp/patrol-*.state; do
  [ -e "$_rival_sf" ] || [ -L "$_rival_sf" ] || continue
  [ "$_rival_sf" = "$STAMP_FILE" ] && continue
  [ -L "$_rival_sf" ] && continue
  _rival_sid="${_rival_sf##*/}"; _rival_sid="${_rival_sid#patrol-}"; _rival_sid="${_rival_sid%.state}"
  [ -n "$_rival_sid" ] || continue
  [ "$_rival_sid" = "$SID" ] && continue
  _rival_mt=$(stat -f %m "$_rival_sf" 2>/dev/null || stat -c %Y "$_rival_sf" 2>/dev/null)
  case "$_rival_mt" in ''|*[!0-9]*) continue ;; esac
  _rival_age=$(( _rival_now - _rival_mt ))
  [ "$_rival_age" -lt 0 ] && _rival_age=0
  if [ "$_rival_age" -le "$LIMIT" ]; then
    echo "patrol-revive: a second live Patrol stamp for session $(printf '%.8s' "$_rival_sid") exists here — one clock per run; delete the stray job and stamp" >&2
  fi
done

MTIME=$(stat -f %m "$STAMP_FILE" 2>/dev/null || stat -c %Y "$STAMP_FILE" 2>/dev/null)
case "$MTIME" in ''|*[!0-9]*) exit 0 ;; esac
AGE=$(( $(date -u +%s) - MTIME ))
[ "$AGE" -lt 0 ] && AGE=0
[ "$AGE" -gt "$LIMIT" ] || exit 0

# ---------- the notice ----------
#
# WHAT IT OWES THE READER, in order: the fact, the measurement it rests on, the
# cause they can recognise, and the two commands that fix it. The path, the age and
# both numbers are interpolated through `jq --arg`, so nothing here has a
# JSON-quoting surface. The poker is named at its RESOLVED ABSOLUTE path, never as
# `<plugin-root>/...`: this text is read by a model that will type it into its own
# shell, where `${CLAUDE_PLUGIN_ROOT}` is unset, and a cron job carrying a
# placeholder fires into a `command not found` every interval and reports nothing
# (SKILL.md §Dispatch states the rule; this is the same rule obeyed by a hook that
# already knows the answer).
#
# THE CRON HALF IS FIRST because the order is a safety property, not a style: `arm`
# alone freshens the stamp and buys a Patrol that reads alive and never fires. And
# FIRST IS NOT ENOUGH, because step 1 is the refusable half — `CronCreate` is measured
# non-deterministically refused by the auto-mode classifier
# (.bionic/docs/record/epic-19/w1/t3-probes.md finding 1) — so the conditional is stated
# in the text a model acts on, not only in this header a model never reads. A step 2 run
# after a refused step 1 produces the exact state the header above argues is worse than
# the death: an undetectably dead Patrol. The way OUT is named too, because a notice that
# offers only "re-arm" to a run that meant to stop is the loop critic C-2 found.
REASON="The Patrol died mid-run and nothing said so.

Its last stamp is ${AGE}s old — past the ${LIMIT}s limit, which is 2x the ${INTERVAL}s poker-interval in force for this project:
    ${STAMP_FILE}

The CLI holds its cron table in process memory with no file behind it, so a plugin update, a /reload-plugins, a session continue or a /clear+resume deletes the job and leaves the stamp as the only trace. Nothing is ticking the poker now: no dispatched row is being judged against its declared duration, and anything this run launched is waiting on a clock that stopped.

Re-arm it — both halves, the clock FIRST, because arming the stamp over an empty cron table buys a Patrol that reads alive and never fires:
  1. CronCreate a RECURRING session job at the interval \`bash ${POKER} interval\` reports, carrying the patrol prompt (the canonical-sdlc skill's Dispatch section).
  2. ONLY IF step 1 succeeded and returned a job: bash ${POKER} arm

If step 1 is refused or fails, do NOT run step 2 — a fresh stamp over an empty cron table reads ALIVE to this hook, to the dispatch wall and to /bionic:doctor while nothing fires again, which is worse than the death this notice is reporting. Tell the user the Patrol is down and that CronCreate was refused, and leave the stamp stale.

If this Patrol was stopped ON PURPOSE, record that instead of re-arming: \`bash ${POKER} disarm\` removes the stamp, and this notice goes with it.

Then stop again — this notice blocks once per turn, and it returns on the next turn until the stamp is re-armed or removed."

# The JSON decision payload on STDOUT with exit 0 — the same Stop-hook block
# channel hooks/patrol-duties-gate.sh uses. (hooks/landing-gate.sh refuses through
# exit 2 + stderr instead; both are live in this CLI, and gates that share no code
# path deliberately do not share a mechanism either.)
jq -nc --arg r "$REASON" '{decision:"block",reason:$r}'
exit 0
