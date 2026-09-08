#!/bin/bash
# SESSION POKER — the tick that decides whether a dispatched session needs a nudge.
# Design: .bionic/docs/specs/epic-16-landing-contract/wave-02-fact-based-supervision.spec.md
#         §Design ("Poker"), succeeding epic-09/epic-10's resident cron poker — deliberately
#         NOT resurrected (spec §Rejected alternatives: "OS cron / launchd for the tick" is
#         residency in configuration form, ratified against).
# [WALL: tests/session-poker.test.sh]
#
# This is NOT a hook, exactly like hooks/session-sweeper.sh: it lives in hooks/ for
# test-harness pairing and to ride the payload's hooks/ directory into the mounted plugin.
# It is registered on NO channel — neither hooks/hooks.json nor a skill's frontmatter.
# It is invoked ON DEMAND, one question per invocation, and holds no process open:
#
#     bash <plugin-root>/hooks/session-poker.sh tick       one decision over this roster (read-only)
#     bash <plugin-root>/hooks/session-poker.sh arm        stamp the Patrol as alive, at engagement
#     bash <plugin-root>/hooks/session-poker.sh disarm     remove that stamp — this Patrol was ended on purpose
#     bash <plugin-root>/hooks/session-poker.sh interval   the configured Patrol interval, seconds
#     bash <plugin-root>/hooks/session-poker.sh adopt      what OTHER sessions launched here (read-only)
#     bash <plugin-root>/hooks/session-poker.sh sweep      delete what DEAD sessions left here (writes, deletes)
#
# `<plugin-root>` IS A PLACEHOLDER, NOT A SPELLING TO PASTE (epic-17 W5, spec AC-5). These
# are commands a MODEL types into its own shell, where `${CLAUDE_PLUGIN_ROOT}` is unset —
# the CLI substitutes that variable inside registered command files and nowhere else. The
# root is resolved ONCE PER SESSION, at Patrol arming, out of the CLI's own registry
# (`installed_plugins.json`, via `detect_plugin_root` in scripts/lib/detect.sh) and the
# resolved absolute path is baked into the session's own text from there on. The old
# `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}` fallback is retired: it silently resolved to a
# bootstrap-era `~/.claude` copy that could be an older build than the installed plugin.
#
# WHAT IT IS. The poker is the decision brain of THE PATROL, not a resident process
# (spec R1). The doctrine that ARMS it lives in skills/canonical-sdlc/SKILL.md
# §Dispatch, and the mechanism is a session-scoped cron job: One clock per run, and only one.
# Arm it at engagement — never on dispatch, never one per unit — and then
# `CronDelete` the job at run close WITH `disarm` beside it, which removes the stamp: the
# cron half stops the firing and the stamp half is what says the stop was deliberate, and a
# `CronDelete` alone leaves a Patrol that every reader — hooks/patrol-revive.sh loudest —
# has to read as a death (critic C-2, epic-19 w1).
# Wakeups are recurring, never date-pinned: a one-shot
# `CronCreate` pinned to a wall-clock minute is banned, because
# a busy minute DROPS the tick rather than queuing it — so a one-shot whose single match
# minute finds the session working dies silently and never fires again. A run that needs a
# wake creates a SHORT RECURRING job and `CronDelete`s it on its first fire.
# Each Patrol tick delivers the patrol prompt, whose FIRST duty is `tick` and whose LAST is
# to continue the run's actual work rather than report on it; THIS SCRIPT DECIDES, the cron
# schedules. (Epic-17 W4 superseded the earlier mechanism, a harness self-wake primitive
# that slept `interval` seconds between calls; `interval` survives it as the cron's period.)
# `tick` is exactly ONE `verdict` read over the whole roster, plus — for any UNMET row only —
# a direct roster lookup of that one row's own `duration=`/`launched_at=` fields (verdict's
# own output carries neither). Never a per-row verdict call, never a second judgment of
# MET/UNMET/STILL-LIVE: that judgment belongs to `verdict` alone (ownership table,
# spec §Design) and this script only consumes it.
#
# WHAT IT NEVER DOES. It never stops, kills, or notifies on its own authority. The
# decision is printed on stdout as ONE machine-readable line, and the caller (the patrol
# prompt the Patrol delivers) is what turns a NOTIFY line into an actual push. Zero
# authority, exactly like `verdict` (ADR-003).
#
# THE ONE THING IT DOES RECORD IS THAT IT RAN. Every invocation of `tick` and every `arm`
# writes a session-keyed Patrol stamp beside the roster — `.bionic/tmp/patrol-<sid>.state`,
# schema `patrol-stamp/v1` — and hooks/dispatch-preflight.sh refuses a dispatch when that
# stamp is absent (the Patrol was never armed) or older than 2x the poker-interval (it was
# armed and has stopped firing). Two properties make that wall honest, and both are pinned
# by tests/session-poker.test.sh §6:
#
#   THE STAMP IS WRITTEN BEFORE ANYTHING IS DECIDED — before the sibling sweeper is even
#   located, before the roster is read, before any exit path branches. What it attests is
#   FIRINGS LANDING, not decisions succeeding. A stamp written on success would measure the
#   wrong thing: this wave's own orchestrator session produced 10+ healthy-but-REFUSED
#   pre-roster ticks across one long interview, and stamp-on-success would have aged the
#   stamp into a false refusal of the wave's first dispatch. The single exception is a tick
#   with no session key at all, which has no stamp path to write.
#
#   `arm` EXISTS BECAUSE ARMING PRECEDES DISPATCH. The doctrine arms at engagement, never on
#   dispatch, so the first stamp cannot come from a tick that has a roster to read; without
#   this verb the wall is a chicken-and-egg that refuses every first dispatch of a run.
#   `arm` therefore needs no roster and asks for none.
#
#   `disarm` EXISTS BECAUSE A DELIBERATE STOP HAS TO BE READABLE. It removes the stamp, and
#   nothing else in production ever did — so an aging stamp meant "the Patrol died" and
#   "the run ended its own Patrol" indistinguishably, and hooks/patrol-revive.sh reported
#   the second as the first on EVERY remaining turn of the session (critic C-2, epic-19 w1).
#   Its two callers are the two deliberate stops there are: the run-close ritual in
#   skills/canonical-sdlc/SKILL.md §Dispatch, beside the `CronDelete`, and the DISARM
#   decision below, which takes it as the last act of its own tick.
#
# The stamp is a LIVENESS signal, not an authority: it says the Patrol fired, and it cannot
# say the CLI's cron table still holds the job. That honest limit is the wall's too.
#
# AN ACKED ROW IS CLOSED HERE, exactly as it is for the other three consumers of the
# verdict line (hooks/landing-gate.sh, hooks/stop-orders.sh, hooks/stop-guard.sh): it is
# neither open nor notifiable. `acked=` is read PER ROW off the verdict line below, never
# from the ledger — the verb that owns the ledger is the verb that prints the answer.
#
# DECISIONS, in precedence order:
#   DISARM   the roster carries no OPEN row — an empty roster (spec's "disarmed on empty
#            roster" invariant, literally) generalizes here to the roster having nothing
#            open at all: every row MET, WAIVED or ACKED is the same "nothing left to wait
#            for" as no rows existing, so all read DISARM (S2 design decision plus epic-16
#            w2 Step-6 remediation R4, both logged to the plan). A DISARM tick REMOVES this
#            session's stamp as its last act — the decision is terminal, so the disk record
#            that a Patrol runs here has to stop saying so.
#   NOTIFY   at least one UNACKED UNMET row's elapsed time (now − launched_at) exceeds its own
#            declared `duration=`, read by the same parser `verdict` uses for `cadence=`
#            (hooks/session-sweeper.sh's parse_seconds, duplicated below — see that file's
#            fix, same commit lineage, epic-16 w2 S2). A row whose duration is unreadable or
#            whose launch time is unreadable is skipped, never guessed at — the same
#            "refuse rather than invent" rule verdict itself follows.
#   QUIET    open rows exist (UNMET-not-past-duration, STILL-LIVE, or AMBIGUOUS) but none
#            qualify for NOTIFY — the tick ran, found nothing to say, and that is reported.
#
# Exit codes mirror hooks/session-sweeper.sh's verdict verb, because a caller already knows
# how to branch on this shape:
#   0 — DISARM or QUIET
#   1 — NOTIFY (something needs surfacing)
#   2 — usage error, or a refusal (propagated from the sweeper read, or raised here)
#   3 — no session key
#
# `bind` IS THE ONE VERB THIS TABLE DOES NOT DESCRIBE, and it is listed rather than left to
# be inferred (review readability F6). It answers about a WRITE, not about a roster, so its
# 1 is a refusal and not a NOTIFY:
#   0 — bound, or NOT-ENGAGED (nothing decided, and that is not a fault)
#   1 — REFUSED: the operand is not a member of this root's open-run set
#   2 — the marker write failed, or a usage error (this file's one argument-error code)
#   3 — no session key, exactly as above
#
# Session key: CLAUDE_CODE_SESSION_ID, exactly as hooks/session-sweeper.sh takes it.
#
# THE SWEEPER IS THIS SCRIPT'S SIBLING, resolved exactly as hooks/landing-gate.sh resolves
# it: no PATH lookup (a hook's PATH is not ours to trust), no environment override (a seam on
# the path under test would leave the production path unverified) — so the same resolution
# holds in the repo and under the mounted plugin's hooks/, which ships both side by side.
# Registered on no channel — invoked on demand from the mounted plugin payload.

set -u

# THIS SCRIPT'S OWN PATH, so the usage it prints names the copy the operator actually
# invoked — identical in a repo checkout, in a bootstrap-installed ~/.claude/hooks/, and in
# an installed plugin payload. Deliberately NOT ${CLAUDE_PLUGIN_ROOT}: this script is run by
# hand and by the harness outside any plugin context, where that variable does not exist.
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || HOOK_DIR="$(dirname "$0")"

# ---------------------------------------------------------------- the library
#
# THE SPINE (bionic 1.4.0, spec AC-16, design §2). Four facts this script used to derive
# from its own copies or its own literals — which project this cwd belongs to, which session
# is asking, whether the run is still open, and how far past a declared interval counts as
# stale — have one owner each in payload/scripts/lib, and the block
# below is the ONE idiom that finds them. It is pasted byte-identically out of
# `bionic_loader_pin` (payload/scripts/lib/loader.sh) into every hook on the spine, because
# a library cannot load itself; tests/cross-gate-agreement.test.sh re-derives each copy from
# that function, so a drifted paste goes red rather than quiet.
#
# FAIL OPEN, deliberately. The poker is not a wall: it prints one decision line and holds no
# authority (ADR-003), so the cost of a missing library is a tick that cannot answer, not an
# irreversible action taken blind. It says so in one line and steps aside.
BIONIC_LIB_WANT="root.sh session.sh run.sh binding.sh patrol.sh resources.sh worktree.sh agents.sh roster.sh"
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
[ -n "$BIONIC_LIB" ] || loader_fail_open "session-poker"
. "$BIONIC_LIB/root.sh"
. "$BIONIC_LIB/session.sh"
. "$BIONIC_LIB/run.sh"
. "$BIONIC_LIB/binding.sh"
. "$BIONIC_LIB/patrol.sh"
. "$BIONIC_LIB/resources.sh"
. "$BIONIC_LIB/worktree.sh"
. "$BIONIC_LIB/agents.sh"
# `adopt` writes a `roster-state/v1` row, and `roster_row` is the one writer of that
# shape — the same function hooks/dispatch-preflight.sh calls (spec AC-25, ledger D3).
. "$BIONIC_LIB/roster.sh"

POKER_DECISION_SCHEMA="poker-tick/v1"
POKER_INTERVAL_DEFAULT="20m"

# THE SHARED CONSTANT (S15, AC-26; research-code-map §2.c). hooks/landing-gate.sh is the one
# ORIGINATOR of this marker — its own `swept_marker_write` owns the printf — and this file's
# `adopt_copy_marker` (below) is the second appender, but it only ever RELAYS a line the
# originator already wrote; it never computes one. Before this wave `adopt_copy_marker`
# spelled the schema as a bare literal inside its own grep pattern rather than through a
# named constant, which is exactly the shape research-code-map §2.c calls out as a hazard:
# "the grep that finds both writers is `grep -rn 'landing-swept/v1' hooks/*.sh` — a
# derivation that greps for the constant NAME misses the literal spelling". Both files now
# carry a `SWEPT_SCHEMA=` line naming it, byte-identical, pinned in
# tests/cross-gate-agreement.test.sh so the two spellings cannot drift apart unnoticed — the
# same duplicated-but-pinned shape payload/scripts/lib/loader.sh's own block uses, for the
# same reason: two separate hook processes have no shared memory to source a single
# in-process constant from.
SWEPT_SCHEMA="landing-swept/v1"

# The Patrol stamp — schema, and the two halves of its per-session filename. Read back by
# hooks/dispatch-preflight.sh's arming wall; the two spellings are held together by
# tests/cross-gate-agreement.test.sh §P, so a rename on one side cannot go quiet on the other.
PATROL_STAMP_SCHEMA="patrol-stamp/v1"
PATROL_STAMP_PREFIX="patrol-"
PATROL_STAMP_SUFFIX=".state"

# THE ARMING RECORD — a sibling of the stamp, whose MTIME is the instant this session armed.
# It is a second file rather than a field inside the stamp because the stamp is rewritten
# whole by every tick: a field would have to be read back and re-emitted on each of them, and
# one silent read-back failure would erase the session's arming instant for good. The marker
# is written once, by `arm`, and removed with the stamp — nothing else touches it, so it
# cannot drift. Its mtime carries full filesystem resolution, which is what lets the
# comparison below be `-nt` (the selection block's own primitive) rather than a
# whole-second arithmetic that ties.
#
# NO OTHER READER SEES IT: every consumer of the stamp addresses the exact
# `patrol-<sid>.state` path (hooks/dispatch-preflight.sh, hooks/patrol-revive.sh,
# scripts/lib/patrol.sh) — none of them globs — so a `patrol-<sid>.state.armed` beside it
# changes nothing they read, and the stamp's own shape, which the arming wall ages, is
# untouched.
PATROL_ARMED_SCHEMA="patrol-armed/v1"
PATROL_ARMED_SUFFIX=".armed"

# THE SCHEDULER KEEPS NO STATE ACROSS TICKS (S8). There used to be a third sibling of the
# stamp here — a `.holds` counter of consecutive holds, the one fact the tick carried from
# one firing to the next, and the input to a halve-the-width recommendation that fired on
# the second of them. Both are gone. Width is now a pure function of the pressure ring and the plan's
# ceiling, read at the moment of use (`pressure_level`, lib/resources.sh), so "sustained"
# is a property of the ring's own smoothing window rather than of two firings twenty minutes
# apart — and a fact nobody stores is a fact that cannot go stale. What the tick owes the
# operator is therefore a REPORT of the rung, printed every tick, not advice to act on.

# `adopt`'s own schema, and the two numbers its report tail is cut with. The floor is what
# separates a REPORT from the one-line sign-offs that usually follow it in an agent's
# transcript ("done", "no task tools here"); the cap is what keeps a 40 KB report out of a
# terminal the operator has to read. Both are display constants: no decision is taken from
# either, so a bad guess costs legibility and never a wrong verdict.
ADOPT_SCHEMA="poker-adopt/v1"
ADOPT_TAIL_MIN=400
ADOPT_TAIL_CAP=2000

say()  { printf 'poker: %s\n' "$1"; }
die()  { printf 'poker: %s\n' "$1" >&2; }

# ONE EXIT CODE FOR EVERY ARGUMENT ERROR IN THIS FILE, AND IT IS 2. `bind` briefly had a 3
# of its own (wave-session-bound-run S6, on the reading that a missing operand is the same
# class as the missing session key the verb refuses ten lines on). It is not: the session key
# is an ENVIRONMENT fact the caller cannot type, and 3 is what this file says about the
# environment; an operand the caller left off the command line is a usage error like every
# other usage error here, and one verb spelling it differently is a surface the operator has
# to learn per verb. Reverted at S8 with the `USAGE_EXIT` indirection deleted with it —
# tests/session-poker.test.sh 16g asserts the 2.
usage() {  # [message]
  [ $# -gt 0 ] && die "$1"
  die "Usage:"
  die "  bash ${HOOK_DIR}/session-poker.sh tick       one decision over this session's roster (read-only)"
  die "  bash ${HOOK_DIR}/session-poker.sh arm        stamp the Patrol as alive for this session (no roster needed)"
  die "  bash ${HOOK_DIR}/session-poker.sh disarm     remove that stamp at run close — this Patrol was ended on purpose"
  die "  bash ${HOOK_DIR}/session-poker.sh interval    the configured Patrol interval, in seconds"
  die "  bash ${HOOK_DIR}/session-poker.sh interval-default   this script's built-in default interval, in seconds (ignores config)"
  die "  bash ${HOOK_DIR}/session-poker.sh window     the instant this session's roster begins, UTC ISO-8601 (empty when it cannot be dated)"
  die "  bash ${HOOK_DIR}/session-poker.sh adopt      every open row a PREDECESSOR session left on this project's rosters"
  die "  bash ${HOOK_DIR}/session-poker.sh adopt --report-only   the same rows, with the adoption itself not taken (writes nothing)"
  die "  bash ${HOOK_DIR}/session-poker.sh sweep      delete every DEAD session's leftover state under this project's .bionic/tmp"
  die "  bash ${HOOK_DIR}/session-poker.sh sweep --report-only   the same files, listed, with nothing deleted"
  die "  bash ${HOOK_DIR}/session-poker.sh bind <plan>   name the open run this session is working (rewrites its binding)"
  exit 2
}

[ $# -ge 1 ] || usage "a verb is required."
VERB="$1"; shift

# `--report-only` IS THE ONE FLAG IN THIS FILE, and `adopt` and `sweep` are the two verbs
# that take it — the same word for the same promise on both, so an operator who has learned
# it once has learned it. `bind` is the ONE verb that takes an operand, and it is required;
# `sweep` deliberately takes NONE (it answers "clear what nobody can act on here", a
# question about the directory rather than about a session anyone would have to name).
# Everything else keeps the old surface exactly — one word, nothing after it — so a stray
# argument is still the usage error it always was rather than something silently ignored.
ADOPT_REPORT_ONLY=no
SWEEP_REPORT_ONLY=no
BIND_ARG=""
case "$VERB" in
  adopt)
    if [ $# -eq 1 ]; then
      [ "$1" = "--report-only" ] || usage "unknown flag for adopt: $1"
      ADOPT_REPORT_ONLY=yes
    elif [ $# -gt 1 ]; then
      usage "adopt takes at most one flag."
    fi
    ;;
  sweep)
    if [ $# -eq 1 ]; then
      [ "$1" = "--report-only" ] || usage "unknown flag for sweep: $1"
      SWEEP_REPORT_ONLY=yes
    elif [ $# -gt 1 ]; then
      usage "sweep takes at most one flag."
    fi
    ;;
  bind)
    # THE OPERAND IS THE WHOLE POINT OF THE VERB, so its absence is a refusal rather than a
    # default. `bind` with no plan cannot mean "unbind" — engagement owns writing `plan=none`
    # (AC-7) and a verb that also unbound would give the marker a second writer with a second
    # rule. It exits 2, this file's one code for an argument error, like every other verb.
    if [ $# -ne 1 ] || [ -z "$1" ]; then
      usage "bind takes exactly one argument: the plan this session is working."
    fi
    BIND_ARG="$1"
    ;;
  tick|arm|disarm|interval|interval-default|window)
    [ $# -eq 0 ] || usage "$VERB takes no arguments."
    ;;
  *) usage "unknown verb: $VERB" ;;
esac

# ---------------------------------------------------------------- portable facts
#
# DELIBERATELY DUPLICATED from hooks/session-sweeper.sh, CODE-identical (not byte-identical —
# each file's comments explain its own copy in its own terms, exactly as
# tests/cross-gate-agreement.test.sh's §I.1 already treats signature comments for its own
# duplicated family), for the reason that file's own header gives (§9 there): a sourced
# library the installer misses is a silently inert consumer, and every duplicate here answers
# the SAME question its sibling answers so the two cannot quietly drift into different
# readings of one fact. `parse_seconds` is duplicated post-fix (epic-16 w2 S2, same commit
# that fixed the original); `file_mtime` joined them for `adopt`, which reads a predecessor
# agent's progress file the way the sweeper reads a live one. The seven are held together by
# tests/cross-gate-agreement.test.sh
# §O, which compares executable text with every pure-comment line stripped from both sides —
# epic-16 w2 Step-6 remediation R3, closing rd review D-1 (this claim used to name no test,
# and was already false for parse_seconds before that fix).

now_epoch() { date -u +%s; }
iso_now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

iso_epoch() {  # <ISO-8601 Z> -> epoch seconds, empty if unreadable
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null
}

# One field out of a versioned pipe-delimited line, BY KEY, never by position — same
# rationale as hooks/session-sweeper.sh's copy: field order is not a contract.
line_field() {  # <line> <key>
  printf '%s' "$1" | tr '|' '\n' | grep "^$2=" | head -1 | cut -d= -f2-
}

clean() {  # <value>
  printf '%s' "$1" | tr '\n\r\t|' '    ' | sed -e 's/[[:cntrl:]]/ /g' -e 's/  */ /g' \
    -e 's/^ *//' -e 's/ *$//' | cut -c 1-400
}

# The prose duration/cadence parser. Deliberate limits, each a refusal rather than a guess —
# see hooks/session-sweeper.sh's copy for the full rationale (its own comments there are
# specific to ITS callers, e.g. `cadence=`, which this script never reads — that is why this
# copy's comments are shorter, not why the code differs). This is that function's POST-FIX
# body, CODE-identical (§O compares it with comments on both sides stripped).
parse_seconds() {  # <prose> -> seconds on stdout; nonzero exit if it cannot be read
  local raw="$1" s pairs count nums hi unit mult n allnums
  [ -n "$raw" ] || return 1
  s="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  s="${s//\~/ }"; s="${s//–/-}"; s="${s//—/-}"; s="${s//,/ }"
  pairs="$(printf '%s' "$s" \
    | grep -oE '[0-9]+([[:space:]]*-[[:space:]]*[0-9]+)?[[:space:]]*(hours?|hrs?|minutes?|mins?|seconds?|secs?|h|m|s)([^a-z0-9]|$)')"
  count="$(printf '%s\n' "$pairs" | grep -c '[0-9]')"
  [ "$count" -eq 1 ] || return 1
  nums="$(printf '%s' "$pairs" | grep -oE '[0-9]+')"
  hi=0
  for n in $nums; do [ "$n" -gt "$hi" ] && hi="$n"; done
  [ "$hi" -gt 0 ] || return 1
  unit="$(printf '%s' "$pairs" | grep -oE '[a-z]+' | tail -1)"
  case "$unit" in
    h|hr|hrs|hour|hours)         mult=3600 ;;
    m|min|mins|minute|minutes)   mult=60 ;;
    s|sec|secs|second|seconds)   mult=1 ;;
    *) return 1 ;;
  esac
  printf '%s' "$s" | grep -qE '[0-9]+\.[0-9]+' && return 1
  allnums="$(printf '%s' "$s" | grep -oE '[0-9]+')"
  [ "$(printf '%s\n' "$allnums" | grep -c '[0-9]')" -eq "$(printf '%s\n' "$nums" | grep -c '[0-9]')" ] \
    || return 1
  printf '%s' "$((hi * mult))"
}

# ---------------------------------------------------------------- the pinned root
#
# THE COPY IS GONE (bionic 1.4.0, spec AC-10). This script used to carry one of eight
# byte-identical resolvers that asked git FIRST and walked for a `.bionic` ancestor only
# when no repository existed at all — so a git repo nested inside the workspace that holds
# the `.bionic` tree resolved to ITSELF, and the roster the tick polled was not the roster
# the wall wrote. `project_root` in payload/scripts/lib/root.sh inverts that order and maps
# a linked worktree onto its main repository, which is the property epic-16 w2's remediation
# R3 added the copy for in the first place (a worktree cwd must not read an empty roster and
# then DISARM, terminally). Every call site below passes "$PWD" and takes the library's
# answer; nothing here re-derives it.

# ---------------------------------------------------------------- the interval knob
#
# `poker-interval:` in <project>/.bionic/config.yaml — the exact convention
# hooks/context-spend.sh (`docs-root:`) and hooks/canonical-sdlc-governing-skill.sh
# (`docs-root:`, `rigor-floor:`) already use: a project-scoped key, grep'd and sed-stripped,
# never a YAML parser. ASSUMPTION (logged to the plan, S2): this is the first CONSUMER of
# that convention outside canonical-sdlc's own hooks; no config.yaml ships by default, so an
# absent file or an absent key both read as the documented default, 20m — a knob nobody has
# touched behaves as if it were never added. A malformed override REFUSES rather than
# silently falling back to the default, matching this repo's "refuse, never guess" posture
# everywhere else a prose value is read (parse_seconds itself, the two hooks above).
poker_interval_seconds() {
  local repo cfg raw ov
  repo="$(project_root "$PWD")"
  cfg="$repo/.bionic/config.yaml"
  raw="$POKER_INTERVAL_DEFAULT"
  if [ -f "$cfg" ] && [ ! -L "$cfg" ]; then
    ov="$(grep -E '^[[:space:]]*poker-interval[[:space:]]*:' "$cfg" 2>/dev/null | head -1 \
      | sed -E 's/^[[:space:]]*poker-interval[[:space:]]*:[[:space:]]*//' \
      | tr -d '\r' | sed -e 's/[[:space:]]*$//')"
    [ -n "$ov" ] && raw="$ov"
  fi
  parse_seconds "$raw"
}

# ---------------------------------------------------------------- the Patrol stamp
#
# One session-keyed file beside the roster, at the SAME pinned root the roster uses — a
# stamp written under a worktree root while the wall reads the main repository's would
# refuse a perfectly live Patrol, silently and for the rest of the run (the exact shape of
# the worktree bug ap review A-1 fixed for the roster read, epic-16 w2).
#
# Never fatal to a tick. A tick that could not stamp has still decided, and turning a
# stamp-write failure into a refused tick would hand the arming wall a second way to say
# "dead" about a Patrol that is firing fine. `arm` is the exception and checks the return:
# arming is an explicit act whose whole product is the stamp, so a silent no-op there would
# leave the operator believing a wall is satisfied when it is not.
#
# Symlinks are refused rather than followed, the same posture every other .bionic/tmp
# writer takes: a hostile repo may make this fail, and must not gain a write through a path
# it aims.
patrol_stamp_file() {  # <session-id> -> absolute path, or empty
  local repo real
  repo="$(project_root "$PWD")"
  real="$(cd "$repo" 2>/dev/null && pwd -P)"
  [ -n "$real" ] || return 1
  printf '%s/.bionic/tmp/%s%s%s' "$real" "$PATROL_STAMP_PREFIX" "$1" "$PATROL_STAMP_SUFFIX"
}

# THE WINDOW. `file_birth` is the creation time the filesystem itself recorded — `stat %B`
# here, `%W` on GNU, where 0 means "this filesystem does not keep one" and is not an answer.
# Never mtime: the roster is append-only, so its mtime is the LAST dispatch, and scoping to
# that would hide every gap but the newest.
file_birth() {  # <path> -> epoch seconds, empty when the platform has none
  local b
  b="$(stat -f %B "$1" 2>/dev/null || stat -c %W "$1" 2>/dev/null)" || return 1
  case "$b" in ''|*[!0-9]*|0) return 1 ;; esac
  printf '%s' "$b"
}

epoch_iso() {  # <epoch seconds> -> UTC ISO-8601, the shape the CLI stamps entries with
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# roster_window <roster file> <session id> -> the ISO instant this roster's own record of
# this session begins, or nothing when neither file can date it (see the block comment).
# The Patrol stamp is the fallback because it is written at ARMING, which precedes the
# first dispatch by doctrine — so on a session whose roster was never written it still
# dates the stretch this session is answerable for.
roster_window() {
  local b
  b="$(file_birth "$1")" || b="$(file_birth "$(patrol_stamp_file "$2")" 2>/dev/null)" || return 1
  [ -n "$b" ] || return 1
  epoch_iso "$b"
}

# THE .bionic/tmp WRITE GUARD, one copy for both of this script's writers — the Patrol
# stamp below and the adopted row further down. It was written inline in the stamp writer
# and is a function now because a second writer arrived (epic-20 W1 B-1): a guard this
# specific, copied by hand into a second call site, is a guard that drifts.
tmp_dir_ok() {  # <.bionic/tmp path> -> 0 safe to write in, 1 refuse
  local d="$1" _repo _target _common _root
  case "$d" in */.bionic/tmp) : ;; *) return 1 ;; esac
  if [ -L "${d%/tmp}" ]; then
    # The spawned-worktree link (.bionic -> main checkout's) is trusted only when its
    # target resolves inside this same repo — mirrors stop-guard's _bionic_symlink_in_repo.
    _repo="${d%/.bionic/tmp}"
    _target="$(cd "${d%/tmp}" 2>/dev/null && pwd -P)" || return 1
    _common="$(git -C "$_repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    _root="$(cd "${_common%/.git}" 2>/dev/null && pwd -P)" || return 1
    case "$_target/" in "$_root"/*) : ;; *) return 1 ;; esac
  fi
  [ -L "$d" ] && return 1
  return 0
}

# The arming record's path — the stamp's, plus one suffix, so the two can never resolve to
# different directories and a mis-resolved root loses both together rather than half.
patrol_armed_file() {  # <session-id> -> absolute path, or empty
  local f
  f="$(patrol_stamp_file "$1")" || return 1
  [ -n "$f" ] || return 1
  printf '%s%s' "$f" "$PATROL_ARMED_SUFFIX"
}

# WRITTEN BY `arm` AND BY NOTHING ELSE. Its content is for a human reading .bionic/tmp; the
# fact the tick reads is its mtime. A failure here is NOT fatal to arming: the stamp is what
# the arming wall reads, and a session armed without a marker simply never auto-DISARMs —
# which is the safe direction (ADR-002 §3), where refusing to arm would take the dispatch
# wall down over a bookkeeping file.
write_patrol_armed_marker() {  # <session-id> -> 0 written, 1 not
  local sid="$1" f d
  f="$(patrol_armed_file "$sid")" || return 1
  [ -n "$f" ] || return 1
  d="${f%/*}"
  tmp_dir_ok "$d" || return 1
  mkdir -p "$d" 2>/dev/null || return 1
  [ -L "$f" ] && return 1
  printf '%s|at=%s|session=%s\n' "$PATROL_ARMED_SCHEMA" "$(iso_now)" "$sid" \
    > "$f" 2>/dev/null || return 1
  chmod 600 "$f" 2>/dev/null
  return 0
}

write_patrol_stamp() {  # <session-id> <verb> -> 0 written, 1 not
  local sid="$1" verb="$2" f d
  f="$(patrol_stamp_file "$sid")" || return 1
  [ -n "$f" ] || return 1
  d="${f%/*}"
  tmp_dir_ok "$d" || return 1
  mkdir -p "$d" 2>/dev/null || return 1
  [ -L "$f" ] && return 1
  printf '%s|at=%s|session=%s|verb=%s\n' "$PATROL_STAMP_SCHEMA" "$(iso_now)" "$sid" "$verb" \
    > "$f" 2>/dev/null || return 1
  chmod 600 "$f" 2>/dev/null
  return 0
}

# THE OTHER END OF THE SAME RECORD, and the only writer in production that ever removes a
# stamp. Until it existed, an aging stamp had exactly one reading available to every
# consumer — "the Patrol died" — and the two deliberate stops this system takes routinely
# (the run-close `CronDelete`, and the DISARM decision below) produced that reading on a
# run that had simply finished. hooks/patrol-revive.sh then blocked the stop of EVERY
# remaining turn of the session, since one block per turn is not a block that stops
# repeating. Removing the stamp is the readable fact that closes it: the revive hook's
# ABSENT state is silent by design, so a stamp that is gone ends the notice rather than
# restarting it, and the arming wall's never-armed refusal is exactly the right thing to
# say to the next dispatch on a run whose clock was deliberately stopped.
#
# A SYMLINK IS NOT A STAMP, here as everywhere else under .bionic/tmp. It is left alone
# rather than unlinked: every reader in the fleet already treats it as absent, so there is
# nothing to close, and a script that deletes files it never wrote is a worse trade than a
# no-op. The directory shape is checked exactly as the writer checks it, so a resolution
# that landed somewhere else removes nothing.
remove_patrol_stamp() {  # <session-id> -> 0 gone (removed, or never there), 1 could not
  local sid="$1" f d a
  f="$(patrol_stamp_file "$sid")" || return 1
  [ -n "$f" ] || return 1
  d="${f%/*}"
  case "$d" in */.bionic/tmp) : ;; *) return 1 ;; esac
  # THE ARMING RECORD GOES WITH THE STAMP, best-effort. Both halves say "this session's
  # Patrol is live", so leaving one behind leaves the disk saying half of a thing that
  # ended. It is best-effort because no reader consults the marker without a stamp beside
  # it, so a survivor claims nothing — where a surviving STAMP claims a live clock, which
  # is why that one decides the return code.
  a="$(patrol_armed_file "$sid")" || a=""
  if [ -n "$a" ] && [ ! -L "$a" ] && [ -e "$a" ]; then rm -f "$a" 2>/dev/null; fi
  [ -L "$f" ] && return 0
  [ -e "$f" ] || return 0
  rm -f "$f" 2>/dev/null
  [ -e "$f" ] && return 1
  return 0
}

# ---------------------------------------------------------------- the blind wall
#
# THE WALL THAT ROSTERS A DISPATCH IS REGISTERED ON THE SKILL CHANNEL, not in hooks.json:
# skills/canonical-sdlc/SKILL.md's own frontmatter registers hooks/dispatch-preflight.sh
# (that partition is deliberate — the wall is armed-scoped, not always-on). A skill-channel
# registration lives in the process's `sessionHooks` table and does NOT survive a session
# continue, a `/clear`+resume, or `/reload-plugins`. When it is gone, NOTHING SAYS SO:
# dispatches launch normally, no row is written, and the first symptom is a tick REFUSING
# with "no roster" — which reads as "nothing has been dispatched yet", the exact opposite of
# what happened. Measured live 2026-08-22; the same symptom is recorded unresolved at
# .bionic/docs/record/session-20260814-wave-detector-terminal-state/min-interactive-agent-hook.md
# §6, and the cure proven the same day is to re-invoke the skill in the same process.
#
# So the tick — which already runs inside the session and already holds its session id —
# compares TWO records of the same event:
#
#   the transcript, which the CLI writes whatever the hooks do:  every `Agent` tool_use
#   the roster,     which only the wall writes:                  every dispatch it saw
#
# A gap between them is the wall's absence, observed rather than assumed. This is a
# DIAGNOSIS, not a gate: it never refuses anything, and it never touches the roster.
#
# WHAT IS DELIBERATELY NOT COUNTED, each because counting it would make a live wall look
# blind: a tool_use inside an agent context (`isSidechain`, or an explicit agent key) — a
# teammate's dispatch never reaches this wall at all (record §5a), so it can never be
# rostered and its absence is not news; and a dispatch the wall REFUSED, which exits before
# the roster append and is therefore a wall doing its job, recognized by the CLI's own
# `PreToolUse:Agent hook error:` marker in the tool result.
#
# TWO HONEST LIMITS, both a false ALARM rather than a false silence, and both cheap because
# the cure is idempotent (re-invoking the skill changes nothing when the wall is live):
# a Step-8 cleanup that wipes `.bionic/tmp` mid-session leaves the transcript's dispatches
# with no rows to match; and a transcript that quotes the refusal marker verbatim (a record
# file read into context) inflates the refusal count, which suppresses rather than raises.
#
# The transcript is resolved EXACTLY as hooks/dispatch-preflight.sh resolves it for its own
# liveness question (`roster_session_live`): a session's transcript is `<sid>.jsonl` under
# some project directory of CLAUDE_CONFIG_DIR/projects. Not resolvable means SILENT — a
# detector that cannot read cannot report.

session_transcript() {  # <session-id> -> path on stdout, nonzero if none
  local sid="$1" cfg d f
  [ -n "$sid" ] || return 1
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [ -d "$cfg/projects" ] || return 1
  for d in "$cfg"/projects/*/; do
    f="${d}${sid}.jsonl"
    if [ -f "$f" ] && [ ! -L "$f" ]; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 1
}

# Occurrences, never lines: a parallel fan-out puts several `Agent` tool_uses in ONE
# assistant entry, and a line-counting read would report that batch as a single dispatch.
# The literal `"name":"Agent"` cannot be forged from prose quoting it, because inside a JSON
# string every quote is backslash-escaped and the escaped form does not contain it.
#
# <since> is the window's ISO instant, empty for "the whole transcript". Comparison is on the
# entry's own `timestamp` truncated to the second — the CLI writes fractional seconds and a
# raw string compare would sort `…:23.9Z` BEFORE `…:23Z` and drop an in-window entry.
count_main_thread_dispatches() {  # <transcript> [<since ISO>] -> count on stdout
  awk -v since="${2:-}" '
    function in_window(   t) {
      if (since == "") return 1
      if (match($0, /"timestamp"[[:space:]]*:[[:space:]]*"[^"]+"/) == 0) return 1
      t = substr($0, RSTART, RLENGTH)
      sub(/^.*:[[:space:]]*"/, "", t); sub(/"$/, "", t)
      return (substr(t, 1, 19) >= substr(since, 1, 19))
    }
    /"isSidechain"[[:space:]]*:[[:space:]]*true/          { next }
    /"agent_?[Ii][dD]"[[:space:]]*:[[:space:]]*"[^"]/     { next }
    {
      # THE CHEAP TEST FIRST. A line with no compact `"name":"Agent"` literal — the shape
      # every entry this partition can count is written in, the CLI own compact
      # serialization, never a hand-spaced one — cannot hold a dispatch, so a plain
      # substring index() runs before the per-line timestamp match() inside in_window()
      # ever does. `line` is `$0` SAVED FIRST, into its own variable, because the counting
      # `gsub` below mutates whatever it is pointed at — targeting `line` rather than the
      # bare (implicit-`$0`) form keeps `$0` intact for the match() inside in_window() to
      # test against the untouched record.
      line = $0
      if (index(line, "\"name\":\"Agent\"") == 0) next
      if (in_window()) n += gsub(/"name"[[:space:]]*:[[:space:]]*"Agent"/, "", line)
    }
    END { print n+0 }
  ' "$1" 2>/dev/null
}

# A REFUSAL IS A JOIN, NOT A LITERAL. `PreToolUse:Agent hook error:` is what the CLI writes
# into a refused dispatch's tool_result — and it is ordinary text everywhere else. The plan
# that specifies this check, the reviews of it and every brief that quotes it carry the
# literal, so reading one of those files puts the marker in a tool_result of THAT read, and
# a transcript-wide grep for it counted 19 refusals in the session that wrote this line
# against a truth of 1 — the detector inert in the repository that builds it. So the marker
# is credited only where it joins BY tool_use_id to an `Agent` tool_use of this thread: the
# refused dispatch's own result. payload/scripts/lib/patrol.sh applies the identical rule
# for doctor's reconstruction, and tests/cross-gate-agreement.test.sh §Q asks both copies
# the same fixture and compares their two answers to each other.
#
# TWO REGIONS OF THE LINE, and only one of them is the result. Beside `message` the CLI
# writes a sibling `toolUseResult` field restating the same result — and for a SPAWN it
# writes the whole brief there, so a brief that quotes the marker (this one does) plants
# one on a successful dispatch's own line. The scan therefore stops at that key: `message`
# precedes it on every entry this machine has written (34k records, 0 counterexamples), and
# a tool_result never appears twice in one entry, which is what lets one line credit at
# most one refusal. If the CLI ever reorders those keys this over-credits again rather than
# going quiet — §Q's spawn-echo fixture is what would say so.
#
# ONE PASS is enough: a result cannot be written before the call it answers, so every Agent
# id is already known by the time its tool_result is read.
#
# THE SAME WINDOW as the dispatch count, and for the same reason: a refusal from the wave
# before this roster would otherwise be subtracted from a gap in this one, turning a real
# blind wall silent.
count_refused_dispatches() {  # <transcript> [<since ISO>] -> count on stdout
  awk -v since="${2:-}" '
    function quoted_value(seg,   v) {     # `"key" : "value"` -> value
      v = seg; sub(/^.*:[[:space:]]*"/, "", v); sub(/"$/, "", v); return v
    }
    function in_window(   t) {
      if (since == "") return 1
      if (match($0, /"timestamp"[[:space:]]*:[[:space:]]*"[^"]+"/) == 0) return 1
      t = substr($0, RSTART, RLENGTH)
      sub(/^.*:[[:space:]]*"/, "", t); sub(/"$/, "", t)
      return (substr(t, 1, 19) >= substr(since, 1, 19))
    }
    /"isSidechain"[[:space:]]*:[[:space:]]*true/          { next }
    /"agent_?[Ii][dD]"[[:space:]]*:[[:space:]]*"[^"]/     { next }
    !in_window()                                          { next }
    {
      # Every `Agent` tool_use on this line, by id. The CLI writes a tool_use as
      # {"type","id","name","input",...}, so the id is the last one before the name.
      rest = $0
      while (match(rest, /"name"[[:space:]]*:[[:space:]]*"Agent"/)) {
        head = substr(rest, 1, RSTART - 1)
        rest = substr(rest, RSTART + RLENGTH)
        if (match(head, /.*"id"[[:space:]]*:[[:space:]]*"[^"]+"/))
          isagent[quoted_value(substr(head, RSTART, RLENGTH))] = 1
      }

      cut = index($0, "\"toolUseResult\"")
      region = (cut > 0) ? substr($0, 1, cut - 1) : $0
      if (index(region, "PreToolUse:Agent hook error:") > 0) {
        while (match(region, /"tool_use_id"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
          if (quoted_value(substr(region, RSTART, RLENGTH)) in isagent) { n++; break }
          region = substr(region, RSTART + RLENGTH)
        }
      }
    }
    END { print n+0 }
  ' "$1" 2>/dev/null
}

# One row per dispatch, and only the row the WALL itself writes: `status=intended` is
# hooks/dispatch-preflight.sh's own append (its ROW, one per Agent PreToolUse). The later
# `status=confirmed` / `status=identified` copies hooks/execution-recorder.sh appends are
# the SAME dispatch re-stated on an append-only file, so counting them would inflate the
# rostered side threefold and hide every real gap. Schema-prefix filtered first, the same
# discipline every other roster reader in the fleet follows.
count_rostered_dispatches() {  # <roster file> <session-id> -> count on stdout
  [ -f "$1" ] || { printf '0'; return 0; }
  grep -F "roster-state/v1|" "$1" 2>/dev/null \
    | grep -F "|session=$2|" \
    | grep -c -F "|status=intended|"
}

# ---------------------------------------------------------------- the run's own state
#
# WHAT THE TICK COULD NOT SEE UNTIL NOW. `open == 0` is not "this run is finished" — it is
# "nothing is dispatched at this instant", which is equally the gap between two batches of a
# live wave: every writer of one slice landed, the next slice not yet briefed. DISARM is
# terminal by doctrine (skills/canonical-sdlc/SKILL.md §Dispatch: "DISARM also ends the
# Patrol"), so taking it in that gap ended the supervision of a run with days of work left,
# silently, and the next stretch of the wave ran unwatched. That is measured on this repo's
# own epic-20 W1 dogfood, not projected (the idea file's §B-4). The roster cannot tell the
# two states apart, because a finished run and a mid-wave lull spell the same zero.
#
# THE PLAN CAN. A canonical-sdlc run publishes where it is in one line of its own plan, and
# it says it is FINISHED in exactly one way: `current: 9` with a `Step 9:` line carrying
# `delivered:`. So the tick takes ONE plan read, bounded to those two fields (D3, Chris
# 2026-08-30), and DISARM now requires the RUN to say it is delivered rather than the roster
# merely being quiet. Everything else the plan holds is none of the tick's business.
#
# THE READ IS THE LIBRARY'S, AND THERE IS NO SECOND ONE (POKER/2, ratified 2026-09-03).
# `docs_root` and `active_plan` in payload/scripts/lib/run.sh answer "which *.md answers for
# this run" for the whole fleet; this file used to carry a private copy of that walk —
# `has_sdlc_state()`, `resolve_docs_root()`, `normalize_newlines()`'s selection loop inside
# `newest_sdlc_plan()` — bounded at depth 2 and fence-aware, while the library walked 3.
# tests/cross-gate-agreement.test.sh §S.3d pinned that disagreement rather than papering over
# it, and slice SCHED closed it by moving the library to depth 2 and deleting the copy. Two
# plan readers with different bounds is the exact drift this wave exists to end.
#
# WHAT THE COPY WAS PROTECTING IS UNCHANGED, because the library carries it: the candidate
# filter is the unfenced `## SDLC State` marker, and the read translates line endings rather
# than deleting them. The UNFILTERED read is a measured incident — on 2026-08-15 a
# marker-less *.md that happened to be newest under plans/ won the newest race, `current:`
# parsed empty, and every wall reading it passed silently for ~15 minutes
# (.bionic/docs/record/session-20260815-landing-supervision/t8-forensic-read.md). A tick
# reading the plan that way would DISARM off a scrap file. hooks/patrol-revive.sh:64-70
# refused a plan read outright for that reason; the marker filter is what makes the read safe
# to take here, and it now lives in one file instead of six.
#
# FAIL DIRECTION IS `open`, without exception. No project root, no docs root, no plan, an
# unreadable plan, a plan whose `current:` will not parse, a `current: 9` with no
# `delivered:`, a delivery this session cannot place in time (no arming record), and a
# delivery that PREDATES this session's arming — every one of them answers `open`, and `open`
# never DISARMs. A wrong `open` costs a Patrol that keeps ticking over a finished run, which
# one `disarm` ends; a wrong `delivered` costs the silent, terminal end of supervision over a
# live wave, which nothing recovers. The asymmetry is the whole design.

# CRLF and CR-only line endings TRANSLATED, never deleted: a deleted CR would join two
# lines into one and hand `current:` a value that was never written. This is a TEXT utility,
# not a plan reader — the plan reader is the library's — and it survives the POKER/2
# unification because the section read below still has to see real newlines.
normalize_newlines() {
  awk '{ sub(/\r$/, ""); gsub(/\r/, "\n"); print }' "$1"
}

# THE TWO FIELDS, AND NOTHING ELSE. `current:` and the `Step 9:` line are read out of the
# fence-aware `## SDLC State` section exactly as the evidence gate reads them, so a plan
# documenting the schema inside a ``` example cannot answer for the run.
#
# The `why` half is not decoration: it is the whole content of the QUIET line this feeds. A
# tick that says "no open row, but the run is not delivered" and stops there tells its reader
# nothing they can act on, and the reader is a model deciding whether the Patrol is broken.
# ---------------------------------------------------------------- whose run is this?
#
# THE TICK HAS TWO PLAN READERS — the run-state read below and the FILL scheduler's budget
# and slice table — and before wave-session-bound-run both asked the ROOT: `active_plan`, the
# newest plan carrying an unfenced `## SDLC State`. A root with two runs in it has one newest
# plan and two sessions, so one of them was always reading the other's run: the session whose
# run was mid-flight DISARMed off the neighbour's close-out, and the session whose run had
# closed kept ticking off the neighbour's open plan (spec AC-1, AC-6).
#
# ONE RESOLUTION, TWO CONSUMERS, ONE ANNOUNCEMENT. Both readers call this and it answers
# once — `session_run` is a find over the docs tree and the announcement is a fact about the
# tick, not about the site that asked. Saying it twice would read as two resolutions.
#
# WHAT EACH VERDICT MEANS HERE (payload/scripts/lib/run.sh:414):
#   bound-open <p>    this session's own run, and it is open        -> p, open
#   fallback <p>      no binding; today's root-keyed answer, said out loud (AC-3) -> p, open
#   bound-closed <p>  this session's own run, and it has closed     -> p, NOT open
#   none              no binding and no open run in the root        -> today's newest plan,
#                                                                      NOT open
#
# THE `none` ARM IS WHY THIS IS NOT A ONE-LINE SUBSTITUTION. `session_run` answers `none`
# when there is no binding AND `active_run` has nothing — which is exactly the state a
# DELIVERED run leaves behind, and exactly the state the tick has to read a plan in to decide
# DISARM at all. Taking `none` as "no plan" would make DISARM unreachable for every unbound
# session in the fleet, so the arm falls back to `active_plan` — the same call this function
# made before the wave, on the one path where the wave has nothing to say. For an unbound
# session the pair (plan, open) this sets is therefore identical to (`active_plan`,
# `active_run` succeeded) at every input: today's behaviour, verbatim (AC-3).
POKER_RUN_PLAN=""
POKER_RUN_OPEN=no
POKER_RUN_RESOLVED=no
# ANSWERS ONCE PER PROCESS, AND THE ARGUMENTS OF EVERY LATER CALL ARE IGNORED — not keyed
# on them, discarded (review readability F7). The guard below returns before `$1` and `$2`
# are ever read, so this is a latch and not a memo table: a second call naming a DIFFERENT
# root would silently receive the first root's answer. It is safe because both call sites
# pass the same pair — `run_state` (below) and the FILL scheduler — and a poker process
# serves exactly one project root and one session key for its whole life. A third caller
# with a different pair would have to key the latch rather than reuse it.
resolve_run() {  # <project root> <session id> -> sets POKER_RUN_PLAN / POKER_RUN_OPEN
  [ "$POKER_RUN_RESOLVED" = yes ] && return 0
  POKER_RUN_RESOLVED=yes
  local repo="$1" sid="${2:-}" raw word path
  raw="$(session_run "$repo" "$sid")" || :
  word="${raw%% *}"
  path="${raw#* }"
  case "$word" in
    bound-open)
      POKER_RUN_PLAN="$path"; POKER_RUN_OPEN=yes ;;
    fallback)
      POKER_RUN_PLAN="$path"; POKER_RUN_OPEN=yes
      die "run resolved by newest-plan fallback (session unbound) — $path" ;;
    bound-closed)
      # A BINDING IS A COMMITMENT (design ledger D2). The plan is carried through rather
      # than dropped, because the 1.3.2 read below is what turns "closed" into a DISARM the
      # operator can read — and it is carried WITHOUT the open verdict, so the library's
      # second opinion cannot re-open a run this session already finished.
      POKER_RUN_PLAN="$path"; POKER_RUN_OPEN=no
      die "bound plan closed — $path; this session has no open run" ;;
    *)
      POKER_RUN_PLAN="$(active_plan "$repo")" || POKER_RUN_PLAN=""
      POKER_RUN_OPEN=no ;;
  esac
  return 0
}

run_state() {  # <project root> <arming-record path, may be empty> <session id> -> "delivered|<why>" or "open|<why>"
  local repo="$1" armed="${2:-}" sid="${3:-}" droot plan section current line
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then
    printf 'open|no project root resolved, so no plan could be read'
    return 0
  fi
  # ONE CALL EACH, AND NEITHER IS RESTATED HERE. `docs_root` is asked only so the refusal
  # below can name the directory it searched; `resolve_run` is the selection itself, and it
  # is THIS SESSION's rather than the root's (see its header).
  droot="$(docs_root "$repo")"
  resolve_run "$repo" "$sid"
  plan="$POKER_RUN_PLAN"
  if [ -z "$plan" ]; then
    printf 'open|no plan carrying an unfenced "## SDLC State" under %s/{plans,incidents}' "$droot"
    return 0
  fi
  # A BOUND PLAN THAT IS GONE. `session_run` reports a missing binding as `bound-closed`, so
  # the path can name a file no longer on disk — and every read below would then be an awk
  # error on stderr and an empty answer. DOUBT IS `open` (ADR-002 §3), which is the same
  # answer the no-plan arm above gives, so the Patrol keeps its stamp rather than stopping
  # on a file nobody can read.
  if [ ! -f "$plan" ]; then
    printf 'open|%s is this session'"'"'s bound plan and it is not on disk' "$plan"
    return 0
  fi
  section="$(normalize_newlines "$plan" | awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    /^## SDLC State/ { flag=1; next }
    /^## / { flag=0 }
    flag')"
  current="$(printf '%s\n' "$section" \
             | grep -E '^[[:space:]]*current[[:space:]]*:' \
             | head -1 \
             | sed -E 's/^[[:space:]]*current[[:space:]]*:[[:space:]]*//' \
             | tr -d '[:space:]')"
  if [ -z "$current" ]; then
    printf 'open|%s carries no readable "current:" line' "$plan"
    return 0
  fi
  if [ "$current" != "9" ]; then
    printf 'open|%s is at current: %s' "$plan" "$current"
    return 0
  fi
  line="$(printf '%s\n' "$section" \
          | grep -E '^[[:space:]]*-?[[:space:]]*Step[[:space:]]+9[[:space:]]*:' \
          | head -1)"
  case "$line" in
    *delivered:*) : ;;
    *) printf 'open|%s is at current: 9 but its Step 9 line records no delivered:' "$plan"
       return 0 ;;
  esac

  # WHOSE DELIVERY IS IT? A `delivered:` on the newest plan says a run finished; it does not
  # say THIS run finished. A session that closes run W and then starts W+1 arms at Step 0 —
  # SKILL.md §Dispatch, "at engagement" — while W+1's plan, and the `## SDLC State` that
  # would answer for it, does not exist until Step 1-3. Through that whole window the newest
  # SDLC-State plan is W's, its Step-9 line still records `delivered:`, and the roster is
  # empty because nothing has been dispatched yet: the tick DISARMed, removed the stamp, and
  # the arming wall refused the new run's first dispatch (critic C-4, wave-1.3.2 Step 6).
  #
  # So a delivery counts only if it POSTDATES this Patrol's arming, and the arming instant is
  # the mtime of the record `arm` wrote. `-nt` rather than a seconds comparison: it is the
  # same primitive the selection block above uses, it carries whatever resolution the
  # filesystem has, and it resolves a tie as NOT newer — which is the fail direction this
  # whole function already takes everywhere else.
  #
  # NO RECORD IS DOUBT, AND DOUBT IS `open` (ADR-002 §3). A tick in a session that never
  # armed cannot place the delivery in time at all.
  if [ -z "$armed" ] || [ ! -f "$armed" ]; then
    printf 'open|%s records delivered:, but this session has no arming record to date it against' "$plan"
    return 0
  fi
  if [ ! "$plan" -nt "$armed" ]; then
    printf 'open|%s records delivered:, but it was delivered before this Patrol armed — that is the previous run' "$plan"
    return 0
  fi
  # THE LIBRARY'S SECOND OPINION, as a CONJUNCT and never as a replacement. `lib/run.sh` is
  # the SSoT for "is this run open" (spec §3, ownership table) and it reads more plans than
  # the block above does — depth 3, and no fence filter. The read above is the evidence
  # gate's, held body-for-body by tests/cross-gate-agreement.test.sh §S, and it is the
  # STRICTER of the two: a fenced `## SDLC State` is documentation here and a run there. So
  # the two are ANDed in the one direction that cannot cost anything — where the library
  # still calls the run open, `open` wins. That is this function's fail direction everywhere
  # else, applied to the one reader that can see a plan this one cannot.
  #
  # THE OPINION IS NOW ABOUT THIS SESSION'S PLAN, not the root's newest (AC-6). It is
  # `resolve_run`'s own verdict — `run_open` on the very file this function just read —
  # rather than a second `active_run` call, which in a two-run root would answer for the
  # neighbour and keep a finished Patrol alive forever.
  if [ "$POKER_RUN_OPEN" = yes ]; then
    printf 'open|%s records delivered:, but lib/run.sh still reads this run as open' "$plan"
    return 0
  fi
  printf 'delivered|%s is at current: 9 and its Step 9 line records delivered:' "$plan"
}

# ---------------------------------------------------------------- the scheduler
#
# FILL / HOLD / EMERGENCY, and the RUNG (spec AC-17, AC-29, AC-31; design-ledger D3).
#
# THE PROBLEM. A wave's width was a number in a brief, and a ceiling nobody reaches is a
# wave running one writer at a time by accident: this repo's own 1.4.0 wave dispatched six
# trees against a budget of twenty-two and then went quiet for a batch at a time. Nothing
# on the machine was watching for the gap, because the only thing that fires on its own is
# the Patrol tick — and the tick had no opinion about width.
#
# THE FOUR DECISIONS, and the ONE rule that orders them. Pressure is read FIRST, every tick,
# before a single fill is considered: filling a machine that is already starving is the one
# mistake that costs work rather than time (lib/resources.sh, "MEMORY IS HARD, COMPUTE IS
# SOFT" — the measured failure is a kernel SIGKILL mid-suite).
#
#   EMERGENCY  free memory under the kill floor -> name the youngest suite-running writer
#              for the orchestrator to stop through the stopping standard. Nothing is
#              filled, and the tick does not stop anything itself.
#   HOLD       free memory or load past the warning line -> no fills this tick, with the
#              measurement printed beside the verdict (a HOLD with no number is
#              indistinguishable from a bug).
#   FILL       otherwise -> the ready slices, up to the gap between the RUNG and the rows
#              already open on this session's roster.
#
# AND ONE REPORT, ON EVERY TICK: `rung=<n>/<ceiling> writers=<w> test_jobs=<j>`. The rung is
# `pressure_level`'s answer over the machine-scoped pressure ring — the median band of the
# last few minutes turned into a fraction of the Step-0 ceiling (ceiling, half, quarter,
# floor of one) — and the one fraction is applied to BOTH numbers the header carries (D3).
# It replaces the retired halve-the-width recommendation, which halved `test_jobs` on the
# second consecutive hold and needed a counter file to know what "second" meant. Nothing is stored now: two
# consumers reading one ring at one moment compute one answer, and a plan header nobody
# edits stays the ceiling it was written as.
#
# THE TICK READS PRESSURE TO THROTTLE, NEVER TO RE-DERIVE THE BUDGET. `resources_budget` is
# a pure function of machine FACTS and is written once, into the plan header, by Step 0. A
# tick that lowered `writers` because the machine was briefly busy would make the ceiling a
# function of the weather, which is the drift lib/resources.sh exists to remove. Everything
# here either reads that string or refuses to act; nothing here writes it.
#
# EVERY DECISION IS ADVISORY. The tick prints; the orchestrator dispatches, stops and edits
# the plan. hooks/patrol-duties-gate.sh is what makes a printed FILL binding — the tick's
# turn may not end until the named dispatches or an explicit decline appear — and that is a
# wall on the ORCHESTRATOR, not an action taken here. A hook that dispatched agents or
# stopped them would be a hook taking irreversible action off a reading it cannot confirm.

# One field out of a space-separated `key=value` record (resources_probe's shape, and the
# plan header's `parallel-budget:` value), BY KEY and never by position.
space_field() {  # <record> <key> -> value on stdout, empty if absent
  printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
}

# The plan header's `parallel-budget:` value, or empty.
#
# THE LEADING FRONTMATTER BLOCK ONLY, byte-for-byte the read hooks/dispatch-preflight.sh's
# budget arm takes: a `parallel-budget:` inside the plan BODY is prose — this wave's own
# plan quotes the header in a slice description — and a reader that took a quotation for
# configuration would fill against a number nobody set.
plan_budget_line() {  # <plan> -> the value after `parallel-budget:`, or empty
  awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { next }
    $0 == "---" { exit }
    /^parallel-budget:[ \t]*/ { sub(/^parallel-budget:[ \t]*/, ""); print; exit }
  ' "$1" 2>/dev/null
}

# One integer field out of that value. NOT AN INTEGER IS ABSENT: an arm this cannot measure
# goes unmeasured and says so, exactly as the dispatch wall's own budget_field does.
budget_int() {  # <budget line> <key> -> a non-negative integer, or empty
  local v
  v="$(space_field "$1" "$2")"
  case "${v:-}" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$v" ;; esac
}

# THE SLICE TABLE, read out of the active plan.
#
# WHAT IT LOOKS FOR is a table HEADER row naming `id`, `deps` and `status`, not a heading
# and not a column count. The plan's `## Slices (machine-readable …)` section is where it
# lives today and its shipped shape is four columns — `| id | deps | complexity | status |`
# — but a reader keyed on position breaks the first time a column is inserted, and a reader
# keyed on the heading breaks on a plan that words it differently. Column INDICES are taken
# from the header row by name, so both stay ordinary edits.
#
# FENCE-AWARE, for the reason every other plan read in this file is: a table inside a ```
# example is documentation about the schema, and filling a wave off a documented example is
# the newest-race incident in a new costume.
#
# Emits one `id<TAB>deps<TAB>status` record per row, in TABLE ORDER, which is the order the
# FILL line prints in — the plan's own dependency ordering, maintained by the orchestrator,
# rather than an ordering this hook invents.
slice_table() {  # <plan> -> id<TAB>deps<TAB>status, one per row
  normalize_newlines "$1" 2>/dev/null | awk '
    function trim(v) { sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); return v }
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    !intable {
      if ($0 !~ /^[[:space:]]*\|/) next
      n = split($0, c, "|")
      idc = 0; depc = 0; stc = 0
      for (i = 1; i <= n; i++) {
        t = trim(c[i])
        if (t == "id") idc = i
        else if (t == "deps") depc = i
        else if (t == "status") stc = i
      }
      if (idc && depc && stc) intable = 1
      next
    }
    {
      if ($0 !~ /^[[:space:]]*\|/) exit
      n = split($0, c, "|")
      id = trim(c[idc])
      # The |---|---| separator row, and any row whose id cell is empty or punctuation.
      if (id == "" || id ~ /^[-: ]+$/) next
      printf "%s\t%s\t%s\n", id, trim(c[depc]), trim(c[stc])
    }'
}

# READY = a `pending` row whose EVERY dependency is `landed`.
#
# A dependency cell is a comma-separated list of ids, or an em dash / hyphen / empty cell
# for "none". An id this table does not carry is NOT ready: an unresolvable dependency is a
# dependency this reader cannot confirm landed, and the fill direction here is the cautious
# one — a slice held back costs a batch, a slice dispatched onto an unlanded dependency
# costs the writer's whole run.
slice_ready() {  # <table> -> the ready ids, one per line, in table order
  # ONE PASS TO REMEMBER, one to decide, over the same stream: a dependency may be named
  # before or after the row that depends on it, so nothing can be answered until the whole
  # table has been read. Table order is preserved by indexing on NR.
  printf '%s\n' "$1" | awk -F'\t' '
    $1 == "" { next }
    { n = n + 1; id[n] = $1; dep[n] = $2; st[$1] = $3 }
    END {
      for (i = 1; i <= n; i++) {
        if (st[id[i]] != "pending") continue
        deps = dep[i]
        gsub(/[[:space:]]/, "", deps)
        # A cell with no alphanumeric character names no dependency: the empty cell, the
        # hyphen and the em dash the plan actually uses are all spelled this one way, and
        # matching the dash byte-for-byte would put a Unicode literal in a bash 3.2 awk
        # program for no gain.
        if (deps !~ /[A-Za-z0-9]/) { print id[i]; continue }
        m = split(deps, d, ",")
        ready = 1
        for (j = 1; j <= m; j++) {
          if (d[j] == "" || d[j] !~ /[A-Za-z0-9]/) continue
          if (st[d[j]] != "landed") { ready = 0; break }
        }
        if (ready) print id[i]
      }
    }'
}

# ---------------------------------------------------------------- the rung report
#
# THE CEILINGS THIS RUN OPTED INTO, read once. Both may be absent — a project with no plan,
# or a plan written before Step 0 ever probed — and absence is INERT: the caller says why it
# is not filling and fills nothing, exactly as the dispatch wall's budget arm goes inert on
# the same missing line. A budget is a ceiling a run opts into.
#
# THE SAME RUN EVERY OTHER DECISION THIS TICK WAS TAKEN ON. `resolve_run` answers once per
# process and memoizes, so calling this twice on one tick costs one `plan_budget_line` and
# nothing else — which is what lets the report below be reached from three exit paths
# without any of them re-deciding which run they are in.
sched_budget_read() {  # <project root> <session id> -> sets SCHED_PLAN/SCHED_BUDGET/SCHED_WRITERS/SCHED_JOBS
  resolve_run "$1" "${2:-}"
  SCHED_PLAN="$POKER_RUN_PLAN"
  SCHED_BUDGET=""
  [ -n "$SCHED_PLAN" ] && SCHED_BUDGET="$(plan_budget_line "$SCHED_PLAN")"
  SCHED_WRITERS="$(budget_int "$SCHED_BUDGET" writers)"
  SCHED_JOBS="$(budget_int "$SCHED_BUDGET" test_jobs)"
}

# ── THE APPROVAL GATE (epic-21 T4, AC-5). A printed FILL is a dispatch instruction — the
# duties gate (hooks/patrol-duties-gate.sh) refuses the turn until every named slice is
# either dispatched or explicitly declined — and dispatching into a plan that has not
# reached Step 4 sends a writer against a slice table nobody has ratified: Steps 0-3 are
# research/spec/plan/REVIEW, and `current:` only reaches 4 once Step 3's approval is given
# (SKILL.md §Steps). Observed 2026-09-05T17:54Z: the tick printed `FILL S1 S2 S3 S4 S12 S14
# S15 S16` against the wave-01 plan sitting at `current: 3`.
#
# THE SAME FENCE-AWARE READ `run_state` USES ABOVE, deliberately duplicated rather than
# shared. `run_state` answers a different question (has THIS run delivered) off a plan
# resolved through its own `resolve_run` call, and folding this into it would couple the
# DISARM decision to the FILL decision — two arms this wave's scope keeps apart. Sharing the
# awk/grep/sed pipeline, not the caller, keeps the two readings from ever disagreeing about
# what one `current:` line says.
_sched_plan_current_field() {  # <plan path> -> the RAW current: value (trimmed), or "" if
                               # no plan, no ## SDLC State section, or no current: line
  local plan="$1" section
  [ -n "$plan" ] && [ -f "$plan" ] || { printf ''; return 0; }
  section="$(normalize_newlines "$plan" | awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    /^## SDLC State/ { flag=1; next }
    /^## / { flag=0 }
    flag')"
  printf '%s\n' "$section" \
    | grep -E '^[[:space:]]*current[[:space:]]*:' \
    | head -1 \
    | sed -E 's/^[[:space:]]*current[[:space:]]*:[[:space:]]*//' \
    | tr -d '[:space:]'
}

# THE ONE GRAMMAR THIS REPO ALREADY HAS (Step-6 review-a C-5, review-b finding (c)/N-2).
# payload/scripts/lib/run.sh's run_open strips a trailing a/b sub-step letter before it
# ever looks at digits (`local step="${current%[ab]}"`) — `current: 3b` and `current: 4b`
# are recognized, in-repo forms, not malformed ones. This mirrors exactly that: strip the
# same optional letter, then require what remains to be all-digits. A task-scale `current:
# T<n>` needs no special case to land here — "T1" ends in neither `a` nor `b`, so the strip
# is a no-op and the leftover `T` fails the digit test on its own, same as it always has.
sched_plan_current() {  # <plan path> -> the current: value (digits only, sub-step letter
                        # stripped), or "" if the raw value is unreadable
  local plan="$1" current step
  current="$(_sched_plan_current_field "$plan")"
  step="${current%[ab]}"
  case "$step" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$step" ;; esac
}

# ── THE RUNG, SAMPLED AND REPORTED (AC-17). One sample appended to the machine-scoped ring,
# then the rung read back off it — the order the design names, because a consumer that read
# without sampling would answer from other sessions' readings alone and a first consumer on
# a cold machine would answer from nothing at all.
#
# ONE FRACTION, BOTH CEILINGS (D3). `pressure_level` is a pure function of (ring, ceiling):
# the median band inside the smoothing window picks the fraction, and the fraction is applied
# to `writers` and to `test_jobs` separately because they are different ceilings, not because
# they are different judgments. Nothing is stored; two ticks a second apart over one ring
# compute one answer.
#
# A MISSING CEILING IS REPORTED AS MISSING. A plan that opts into no budget offers nothing to
# take a fraction OF, and inventing a ceiling here is the one thing this arm may never do —
# so the fields read `-` and the line is still printed. "The tick said nothing" and "the tick
# said there is no ceiling" are different facts, and only the second one is true.
#
# ON EVERY TICK, WHICH MEANS FROM EVERY EXIT PATH (Step-6 review C-5). AC-17 reads "prints
# the current rung as one line of its output on every tick", and this report used to sit in
# the scheduler block — below the pre-dispatch QUIET arm and below DISARM, both of which
# `exit 0` above it. The first tick of every run takes the pre-dispatch arm, by design (arming
# precedes dispatch), so the tick where "what width will this machine carry" is most useful
# was the one tick that never answered it. A FUNCTION rather than a hoisted block, because the
# two early arms exit before the scheduler has read a budget and this is the only place that
# read may live without being taken twice.
rung_report() {  # <project root> <session id> -> sets SCHED_RUNG/SCHED_JOBS_RUNG, says one line
  local cores
  sched_budget_read "$1" "${2:-}"
  # THE CORE COUNT, TAKEN HERE ONLY IF THE CALLER HAS NOT TAKEN IT. The scheduler block reads
  # `resources_probe` for its HOLD/EMERGENCY arm and leaves the answer in `SCHED_CORES`; the
  # two early arms have no such reading, and `pressure_sample` needs one to band a load
  # average. A bad or missing value is 1 rather than a refusal: an unsampled ring is a rung
  # this tick does not have, and that is a worse answer than a conservative core count.
  cores="${SCHED_CORES:-}"
  case "$cores" in ''|*[!0-9]*) cores="$(space_field "$(resources_probe)" cores)" ;; esac
  case "$cores" in ''|*[!0-9]*) cores=1 ;; esac
  [ "$cores" -ge 1 ] || cores=1
  pressure_sample "$cores" >/dev/null 2>&1 || :
  SCHED_RUNG=""
  SCHED_JOBS_RUNG=""
  case "${SCHED_WRITERS:-}" in
    ''|0) : ;;
    *) SCHED_RUNG="$(pressure_level "$SCHED_WRITERS" 2>/dev/null)" || SCHED_RUNG="" ;;
  esac
  case "${SCHED_JOBS:-}" in
    ''|0) : ;;
    *) SCHED_JOBS_RUNG="$(pressure_level "$SCHED_JOBS" 2>/dev/null)" || SCHED_JOBS_RUNG="" ;;
  esac
  case "${SCHED_RUNG:-}" in ''|*[!0-9]*) SCHED_RUNG="" ;; esac
  case "${SCHED_JOBS_RUNG:-}" in ''|*[!0-9]*) SCHED_JOBS_RUNG="" ;; esac
  say "rung=${SCHED_RUNG:--}/${SCHED_WRITERS:--} writers=${SCHED_RUNG:--} test_jobs=${SCHED_JOBS_RUNG:--}"
}

# THE YOUNGEST SUITE-RUNNING WRITER on this session's roster, as the address the stopping
# standard takes — `<name>@session-<id8>`, the one spelling both stop gates accept
# (POKER/8). Empty when there is none.
#
# "SUITE-RUNNING" IS READ OFF THE LEDGER, never off the process table (WALLS/3): an open row
# whose `claims=` field is non-empty declared a subprocess claim and therefore spends a
# suite. A `pgrep` per row would be truer to the word "running" and would put a process
# spawn per row inside a Patrol tick.
#
# "OPEN" IS THE ONE PREDICATE THE REST OF THE TICK USES (S19; Step-6 correctness review,
# out-of-axis note). A `status=intended` row survives the roster pass if no `landing-swept/v1`
# marker has CLOSED it, and it survives the live pass if `live_row_open` — the fleet's single
# row-openness predicate, payload/scripts/lib/agents.sh — still calls its agent live on this
# session's transcript. Before this fix the arm stopped at the roster pass, so the tick's
# advisory `open=` asked the live set while the one NAME it prints for the operator to act on
# did not: the kill floor could hand back a stop address for an agent the harness had already
# let go.
#
# CLOSED MEANS `state=MET`, not "a marker exists". `hooks/session-start.sh`'s `open_rows` and
# `adopt_fold` below both require it; this arm and lib/patrol.sh's `patrol_roster_state` did
# not, and S17's `adopt_copy_marker` is a second writer that copies a predecessor's UNMET
# verdict verbatim onto a successor's roster BY DESIGN. An UNMET contract is open work by
# every other reader in the fleet.
#
# STALE AND NONE KEEP THE ROSTER SPELLING, the same fallback and the same reason as the
# tick's `open=` below: the Patrol's prompt runs before any ListAgents, so an arm that went
# silent on an unusable answer would go silent on the first tick of every session — and a
# kill floor that says nothing while the machine dies is worse than one that names a writer
# who has already finished. Freshness is a property of the TRANSCRIPT, so the first unusable
# answer abandons the whole live pass rather than one row of it.
#
# YOUNGEST, because the rung is a kill floor and the youngest writer has the least work to
# lose. `launched_at` is an ISO-8601 Z stamp, so a lexical max IS a chronological max.
youngest_suite_writer() {  # <roster file> <session-id> -> <name>@session-<id8>, or empty
  local roster="$1" sid="$2" swept cands live_cands live_ok tr lrc name tab RL RN CL
  [ -n "$roster" ] && [ -f "$roster" ] && [ ! -L "$roster" ] || return 0
  tab="$(printf '\t')"

  # THE CLOSING MARKERS, BY FIELD EQUALITY rather than by substring: `state=` is last in the
  # originator's printf today and a future field appended after it must not turn every marker
  # into a non-closing one.
  # THE SHARED CONSTANT (declared above), NOT A SECOND SPELLING (S17, on A-14b). This was
  # the third hand-rolled spelling of the schema in the fleet and the one S15 did not reach:
  # a rename on landing-gate.sh's side would have left this function silently matching
  # nothing, and "no closing markers" reads here as "every row is still open".
  swept="$(grep "^${SWEPT_SCHEMA}|" "$roster" 2>/dev/null \
    | awk -F'|' '{ for (i = 1; i <= NF; i++) if ($i == "state=MET") { print; break } }' || true)"

  # PASS ONE — THE ROSTER. Kept in the current shell rather than a pipeline subshell, because
  # the live pass below carries a decision ACROSS rows (the first STALE abandons all of them)
  # and a subshell would drop it on the floor.
  cands=""
  while IFS= read -r RL; do
    [ -n "$RL" ] || continue
    [ -n "$(line_field "$RL" claims)" ] || continue
    RN="$(line_field "$RL" name)"
    [ -n "$RN" ] || continue
    case "$swept" in *"|name=${RN}|"*) continue ;; esac
    cands="${cands}$(line_field "$RL" launched_at)${tab}${RN}
"
  done <<ROSTER_ROWS
$(grep '^roster-state/v1|status=intended|' "$roster" 2>/dev/null || true)
ROSTER_ROWS
  [ -n "$cands" ] || return 0

  # PASS TWO — THE LIVE SET. The reader's one stderr line is dropped here rather than
  # reported: this function's stdout IS the stop address, and the tick already says out loud
  # when its own live read fell back (`live set <state> — …`) above the report.
  tr="$(session_transcript "$sid")" || tr=""
  if [ -n "$tr" ]; then
    live_cands=""; live_ok=yes
    while IFS= read -r CL; do
      [ -n "$CL" ] || continue
      lrc=0
      { live_row_open "$tr" "${CL##*"$tab"}"; } >/dev/null 2>&1 || lrc=$?
      case "$lrc" in
        0) live_cands="${live_cands}${CL}
" ;;
        1) : ;;
        *) live_ok=no; break ;;
      esac
    done <<ROSTER_CANDS
$cands
ROSTER_CANDS
    [ "$live_ok" = yes ] && cands="$live_cands"
  fi
  [ -n "$cands" ] || return 0

  name="$(printf '%s' "$cands" | sort | tail -1 | cut -f2-)"
  [ -n "$name" ] || return 0
  printf '%s@session-%s' "$(clean "$name")" "$(printf '%s' "$sid" | cut -c1-8)"
}

# ---------------------------------------------------------------- adoption
#
# WHAT A `/clear`+RESUME ACTUALLY LOSES, and what it does not. Lost: the completion message
# (the CLI delivers it to the conversation that dispatched, and that conversation is gone)
# and the orchestrator's in-memory dispatch ledger. NOT lost: the agent itself — same
# process, still working — its artifacts, its transcript under
# `<config>/projects/<slug>/<old-sid>/subagents/agent-<id>.jsonl`, and its roster row, which
# lives in the PROJECT's `.bionic/tmp` rather than in any session.
#
# So the successor session can read every one of those files and still be unable to ACT on
# the agent, because the one thing it cannot re-derive is the AGENT ID — the identity the
# CLI handed back at launch and only the dead conversation held. `SendMessage` and
# `TaskStop` both take it, and hooks/stop-guard.sh refuses a stop by NAME for exactly this
# reason ("a NAME is not an identity — it is reused across waves"), naming the full agent id
# as the deliberate way through. The id is on disk the whole time: hooks/execution-recorder.sh
# writes it onto the row as `status=identified|agent_id=`.
#
# `adopt` is the verb that reads it back. For every roster in this project's `.bionic/tmp`
# that belongs to some OTHER session, it prints each row that is still open, its id, and the
# three addresses derived from that id — observe, message, stop — plus a verdict taken from
# disk rather than from memory.
#
# IT WRITES EXACTLY ONE THING, AND IT IS THIS SESSION'S OWN ROSTER. Everything else this
# verb touches is read: no PREDECESSOR roster is ever written (that session may still be
# appending to it), no Patrol stamp is taken (this is not a tick and must not age the
# arming wall's clock), and nothing is stopped or messaged.
#
# The one write is the adoption itself, and it exists because printing an id was only half
# a cure (epic-20 W1 B-1). Every wall downstream of the id asks THIS session's roster
# whether the agent is ours — hooks/stop-guard.sh establishes ownership from a
# `confirmed`/`identified` row carrying the resolved id, hooks/stop-check.sh classifies
# from the same accepted set — so with no row of ours the predecessor's agent classifies
# FOREIGN and every stop of it is refused. `adopt_write_row` below is the successor saying
# on disk what this verb has just said on the terminal: this contract is mine now.
#
# THIS SESSION'S OWN ROWS ARE NEVER ADOPTED. They are not lost — the running session still
# holds them — and printing them would invite the successor to re-ledger work it is already
# tracking, which is the double-counting the roster exists to prevent.

# `<config>/projects/<slug>/<sid>/subagents` — the same walk session_transcript does, one
# level deeper, and keyed on the DIRECTORY rather than the session's own `.jsonl`: an old
# session's transcript can be reclaimed while its agents' files survive, and the agents are
# what this verb is about.
session_subagent_dir() {  # <session-id> -> path on stdout, nonzero if none
  local sid="$1" cfg d
  [ -n "$sid" ] || return 1
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [ -d "$cfg/projects" ] || return 1
  for d in "$cfg"/projects/*/; do
    if [ -d "${d}${sid}/subagents" ]; then
      printf '%s' "${d}${sid}/subagents"
      return 0
    fi
  done
  return 1
}

# THE REPORT, RECOVERED FROM THE TRANSCRIPT — the recovery skills/canonical-sdlc/SKILL.md
# §Dispatch already prescribes by hand ("the report is the last long `assistant` text block
# in that agent's file"), done by machine. Each assistant entry's text blocks are joined and
# re-emitted as ONE JSON string per entry, because a text block spans lines and a
# line-oriented pass would cut a report in half. The LAST block over the floor wins; if
# nothing clears it, the last block of any size does, so a short-report agent is quoted
# rather than dropped.
#
# It is a QUOTE, not an artifact. SKILL.md's own rule stands: persist it under
# `<docs-root>/record/` before acting on it — a transcript is one cleanup away from gone.
#
# AND IT IS UNTRUSTED TEXT. What is quoted here is whatever the agent typed, printed into
# the operator's terminal by a verb they ran to find out what a predecessor left behind —
# an escape sequence in it would repaint or rewrite that terminal rather than be read. The
# control characters are stripped for that reason, tab and newline excepted because the
# report's own line structure is what the caller indents.
agent_report_tail() {  # <transcript> -> the tail on stdout, nonzero if nothing to quote
  local raw
  [ -f "$1" ] || return 1
  command -v jq >/dev/null 2>&1 || {
    printf '(report tail unavailable: jq is not on PATH)'
    return 0
  }
  raw="$(jq -r 'select(.type == "assistant")
                | ((.message.content // []) | map(select(.type == "text") | .text) | join("\n"))
                | select(length > 0)
                | @json' "$1" 2>/dev/null \
    | awk -v min="$ADOPT_TAIL_MIN" '
        { any = $0 }
        length($0) - 2 >= min { last = $0 }
        END { if (last != "") print last; else if (any != "") print any }')"
  [ -n "$raw" ] || return 1
  # THE C1 BLOCK GOES TOO (Step-6 security review S-6). `tr -d '\000-\010\013-\037\177'`
  # removes ESC and DEL and leaves `U+0080`–`U+009F` — of which `U+009B` is CSI, a control
  # sequence introducer that needs no ESC in front of it on a terminal that honours C1. Those
  # arrive as the two UTF-8 bytes `0xC2 0x80`–`0xC2 0x9F`, which a byte-oriented `tr` cannot
  # name, so the pair is deleted by `sed` before the byte-wise strip runs. Ordered first
  # because the byte strip would otherwise leave a bare `0xC2` behind.
  printf '%s' "$raw" | jq -r '.' 2>/dev/null \
    | LC_ALL=C sed 's/'"$(printf '\302')"'['"$(printf '\200')"'-'"$(printf '\237')"']//g' \
    | tr -d '\000-\010\013-\037\177' | head -c "$ADOPT_TAIL_CAP"
}

# ONE FOLD PER PREDECESSOR ROSTER, and the same rule the fleet's other three folds keep: the
# file is append-only, a contract advances along it (`intended` -> `confirmed` ->
# `identified`), every writer copies the contract fields forward, so the LAST row carrying a
# name is the authoritative one (tests/cross-gate-agreement.test.sh §P). Two departures,
# both because this fold answers a question the others do not:
#
#   THE ID IS TAKEN OFF `identified`/`confirmed` ONLY, never off `intended` — the same
#   accepted set hooks/stop-guard.sh and hooks/stop-check.sh use for ownership, and for the
#   same reason: `intended` carries `agent_id=` empty by design, and a row that never
#   advanced past it has no identity to offer. That row is the UNADDRESSABLE case, reported
#   with its cure rather than skipped, because a silent skip is how a predecessor's agent
#   becomes invisible twice.
#
#   A ROW IS CLOSED BY A LANDED MARKER OR BY AN ACK, and by nothing else. `landing-swept/v1`
#   with `state=MET` is hooks/landing-gate.sh saying the contract landed; the ack ledger is
#   the orchestrator saying so by hand, and the sweeper's own ledger comment already binds
#   it across sessions ("an ack taken in a session that has since died is still in force in
#   its successor"). A `landing-swept` marker reading UNMET closes NOTHING here: an answered
#   failure is exactly the row a resumed session most needs to see.
#
# THE ORIGIN IS CARRIED OUT WITH THE ROW, and it is what the stop address is built from
# (T3 FINDING 1). `adopted_from=` wins over `session=` when the row has one: a row that was
# itself adopted is filed under the session that TOOK it, while the harness's teammate table
# keeps naming the session that made the `Agent` call, and `adopted_from` is the only field
# on the row that still points there. Absent both, the caller falls back to the roster
# file's own session — the invariant every roster writer keeps.
#
# Output is one `|`-delimited record per open row. `|` rather than a tab because every value
# on a roster row is cleaned of `|` at write time, while the shell collapses runs of tabs
# and would silently merge two empty fields into one.
adopt_fold() {  # <roster file> <ack ledger> -> name|id|type|deliverable|progress|cadence|launched_at|origin|plan|waiver|files|suites_allowed|suites_source
  awk -v ackfile="$2" '
    function kv(line, key,   n, a, i, eq, k) {
      n = split(line, a, "|")
      for (i = 1; i <= n; i++) {
        eq = index(a[i], "=")
        if (eq == 0) continue
        k = substr(a[i], 1, eq - 1)
        if (k == key) return substr(a[i], eq + 1)
      }
      return ""
    }
    BEGIN {
      if (ackfile != "") {
        while ((getline l < ackfile) > 0) {
          if (l !~ /^sweeper-ledger\/v1\|/) continue
          if (kv(l, "event") != "ack") continue
          an = kv(l, "name")
          if (an != "") acked[an] = 1
        }
        close(ackfile)
      }
    }
    /^roster-state\/v1\|/ {
      n = kv($0, "name"); if (n == "") next
      if (!(n in seen)) { seen[n] = 1; order[++cnt] = n }
      v = kv($0, "subagent_type"); if (v != "") stype[n] = v
      v = kv($0, "deliverable");   if (v != "") deliv[n] = v
      v = kv($0, "progress");      if (v != "") prog[n]  = v
      v = kv($0, "cadence");       if (v != "") cad[n]   = v
      v = kv($0, "launched_at");   if (v != "") launch[n] = v
      v = kv($0, "session");       if (v != "") sess[n]   = v
      v = kv($0, "adopted_from");  if (v != "") afrom[n]  = v
      # THE WAIVER, carried forward the same way the contract fields are (S17, AC-12 attempt
      # 2). Before this fix it was the one field this fold read off the source row and then
      # dropped: `adopt_write_row` hard-coded `waiver=` empty on every adopted row, so a
      # dispatch this session waived at launch came out the far side of a clear looking like
      # one that never was — the `verdict_row` function in hooks/session-sweeper.sh reads
      # `waiver=` straight off the row (no marker involved) and calls a non-empty one WAIVED
      # before it ever asks about a deliverable, so an empty copy verdicted as an unmet
      # SILENT row instead.
      v = kv($0, "waiver");        if (v != "") waiv[n]   = v
      # THE THREE INSTRUMENT FIELDS (wave-01 S13, spec AC-20), carried forward exactly as
      # the contract fields above are. They are what the writer-side budget guard reads:
      # a resumed agent whose adopted row lost `suites_allowed=` would come out of a
      # /clear with no budget on it, and the wall that refuses an off-budget suite would
      # go quiet for exactly the agents a clear leaves running longest.
      v = kv($0, "files");          if (v != "") files[n]  = v
      v = kv($0, "suites_allowed"); if (v != "") sallow[n] = v
      v = kv($0, "suites_source");  if (v != "") ssrc[n]   = v
      # THE ATTRIBUTION, carried forward exactly as the contract fields are. It is the bound
      # plan of the session that dispatched the row, stamped at the instant the row was
      # written (hooks/dispatch-preflight.sh). Rows written before this wave carry no such
      # field at all — a THIRD state, not an empty plan, and the caller partitions on the
      # difference (spec AC-2, A2). An apostrophe cannot appear in this comment: the awk
      # program is one single-quoted argument.
      if (index($0, "|plan=") > 0) { plan[n] = kv($0, "plan"); hasplan[n] = 1 }
      st = kv($0, "status")
      if (st == "identified" || st == "confirmed") {
        v = kv($0, "agent_id"); if (v != "") id[n] = v
      }
      next
    }
    /^landing-swept\/v1\|/ {
      n = kv($0, "name")
      if (n != "" && kv($0, "state") == "MET") met[n] = 1
      next
    }
    END {
      for (i = 1; i <= cnt; i++) {
        n = order[i]
        if (n in met) continue
        if (n in acked) continue
        printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", n, id[n], stype[n], deliv[n], prog[n], cad[n], \
               launch[n], ((n in afrom) ? afrom[n] : sess[n]), \
               ((n in hasplan) ? (plan[n] == "" ? "none" : plan[n]) : ""), waiv[n], \
               files[n], sallow[n], ssrc[n]
      }
    }
  ' "$1" 2>/dev/null
}

# THE ADOPTED ROW — the verb's one write, and the second half of the B-1 cure. What it
# records is an ownership fact, and each field is there because a named reader asks for it:
#
#   status=identified   the accepted set hooks/stop-guard.sh and hooks/stop-check.sh
#                       establish ownership BY ID from. `confirmed` would do as well and
#                       says less: the id is known, which is exactly what `identified` means.
#   agent_id=           the TRANSCRIPT form, the only form either gate resolves a target to.
#   teammate_id=        the ADDRESSING form `<name>@session-<id8>`, the only spelling the
#                       platform's stop primitive takes for a teammate — built from the
#                       session that LAUNCHED the agent, never from ours (T3 FINDING 1). The
#                       teammate table keys on the session that made the `Agent` call and a
#                       `/clear` does not move it; hooks/stop-guard.sh reads this recorded
#                       address before it constructs one, so a row carrying our own eight
#                       would put the string the harness rejects into every refusal it
#                       prints. The caller hands it in already built, for the same reason
#                       the address is printed from there: one construction, one origin.
#   adopted_from=       provenance. The agent is still filed under the predecessor's own
#                       subagents directory, and that directory is what hooks/stop-guard.sh
#                       must widen its resolution to; without this field it cannot know
#                       which session to widen to, and a blind project-wide walk is exactly
#                       the name-oracle the 4/9 ownership rule removed.
#   the contract        deliverable/progress/cadence, copied forward unchanged — the same
#                       forward-copy every roster writer in the fleet performs, so the
#                       successor's readers see the contract the predecessor declared.
#   waiver=             S17 (AC-12 attempt 2). Copied forward for the same reason: it is a
#                       contract field, and `hooks/session-sweeper.sh verdict_row` reads it
#                       directly off THIS row (no marker involved) to decide WAIVED before it
#                       ever looks at a deliverable. A row with a real waiver and an empty
#                       copy of it verdicts as if the waiver had never been declared.
#
# THE APPEND IDIOM IS hooks/dispatch-preflight.sh's (:1339-1347), copied deliberately:
# header-if-absent, `chmod 600`, ONE `printf` of one line, NO LOCK. A single O_APPEND write
# of well under a pipe buffer is not interleaved by the kernel; a read-modify-write here
# would drop rows another writer appended in between (hooks/execution-recorder.sh:399-419).
#
# IDEMPOTENT BY READ-BEFORE-APPEND. `adopt` is the first verb a resumed session runs and it
# is run again at the next resume, so a row already carrying this agent's id AND a
# provenance is left alone — otherwise the roster would grow one row per run without
# carrying one new fact. The read is ADVISORY, never a lock: a lost race duplicates a row,
# which every reader in the fleet already tolerates (the last row carrying a name wins).
#
# A ROW WITH NO ID IS NEVER WRITTEN. That is the UNADDRESSABLE verdict's whole content —
# there is no identity to file — and a row carrying `agent_id=` empty would be inert at
# every by-id reader while looking like an adoption on disk.
#
# THE ROW CARRIES THE ADOPTING SESSION'S BINDING, in the same trailing `plan=` field
# hooks/dispatch-preflight.sh:1703 writes on the rows it creates — one field name, one
# position, two writers (spec §Ownership table, "roster attribution"; cross-gate §RA).
# Without it an adopted row was the one row on any roster with no attribution at all, so a
# THIRD session bound to the same plan re-read this session's own adoption as
# `unattributed` and declined to take it: the partition would quietly stop working exactly
# where two sessions hand a run back and forth. The value is the ADOPTER's binding, because
# the adopter is now the session that owns the row — the launching session is already
# recorded, separately, in `adopted_from=`.
adopt_write_row() {  # <roster file> <sid> <name> <id> <type> <deliverable> <progress> <cadence> <launched> <from-sid> <teammate address> <plan|none> <waiver> <files> <suites_allowed> <suites_source> -> 0 written/already there, 1 not
  local f="$1" sid="$2" name="$3" id="$4" typ="$5" deliv="$6" prog="$7" cad="$8"
  local launch="$9" osid="${10}" addr="${11}" plan="${12:-none}" waiver="${13:-}" d
  local files="${14:-}" sallow="${15:-}" ssrc="${16:-}"
  local -a INSTRUMENT_FIELDS
  [ -n "$id" ] || return 1
  [ -n "$sid" ] || return 1
  d="${f%/*}"
  tmp_dir_ok "$d" || return 1
  [ -L "$f" ] && return 1
  if [ -f "$f" ] && awk -v k="|agent_id=${id}|" '
        index($0, k) > 0 && index($0, "|adopted_from=") > 0 { found = 1 }
        END { exit !found }' "$f" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$d" 2>/dev/null || return 1
  if [ ! -e "$f" ]; then
    roster_header >> "$f" 2>/dev/null && chmod 600 "$f" 2>/dev/null
  fi
  # EVERY FIELD THROUGH `clean()`, `session=` INCLUDED (Step-6 security review S-4). It was
  # the one interpolation of the thirteen that took its value raw, which is character for
  # character the defect this wave fixed on the other row writer one slice earlier
  # (hooks/dispatch-preflight.sh: "a value carrying a `|` or a newline forges a segment …
  # the asymmetry between the two writers was itself the defect"). Every by-key reader in
  # the fleet takes the FIRST match, so a forged `name=` ahead of the real one wins outright.
  # Unreachable today — `engaged_marker_path` refuses a session id outside `[A-Za-z0-9_-]`
  # before any verb decides anything — and that is a guard in another file for another
  # reason, not this writer's own.
  #
  # THE THREE INSTRUMENT FIELDS TRAVEL AS A GROUP, AND ONLY WHEN THE SOURCE ROW HAD THEM
  # (wave-01 S13, spec AC-20). `roster_row` emits them present-if-PASSED, and the
  # distinction is load-bearing at the writer-side guard: a row with `suites_allowed=`
  # empty stated a budget that came out empty, while a row with no such key at all was
  # written before the wall existed. Adopting the second kind must not manufacture the
  # first. All three go or none do — an empty member of a stated group is itself a
  # statement, and splitting them would let a resumed row claim a source for a set it
  # does not carry.
  INSTRUMENT_FIELDS=()
  if [ -n "$files" ] || [ -n "$sallow" ] || [ -n "$ssrc" ]; then
    INSTRUMENT_FIELDS=("files=$(clean "$files")" \
                       "suites_allowed=$(clean "$sallow")" \
                       "suites_source=$(clean "$ssrc")")
  fi
  # THE ROW IS BUILT BY `roster_row` (payload/scripts/lib/roster.sh), not by a format string
  # here (spec AC-25, ledger D3). The eleven fields this writer leaves EMPTY are still named
  # — `model=`, `duration=`, `claims=`, `absent=` and the rest — because an omitted key and
  # an empty one are different rows to a by-key reader, and this writer has always emitted
  # both of the fields no other writer does (`teammate_id=`, `adopted_from=`), empty address
  # included. `clean()` stays here: it is this file's cap on a value, while the row's SHAPE
  # is the library's.
  roster_row \
    status=identified \
    "session=$(clean "$sid")" \
    "name=$(clean "$name")" \
    "agent_id=$(clean "$id")" \
    "launched_at=$(clean "$launch")" \
    "subagent_type=$(clean "$typ")" \
    model= \
    "deliverable=$(clean "$deliv")" \
    source=adopted \
    duration= \
    "progress=$(clean "$prog")" \
    claims= \
    "cadence=$(clean "$cad")" \
    absent= \
    "waiver=$(clean "$waiver")" \
    ${INSTRUMENT_FIELDS[@]+"${INSTRUMENT_FIELDS[@]}"} \
    "teammate_id=$(clean "$addr")" \
    "adopted_from=$(clean "$osid")" \
    tool_use_id= \
    "plan=$(clean "$plan")" \
    >> "$f" 2>/dev/null || return 1
  return 0
}

# THE MARKER COPY (S17, AC-12 attempt 2) — the other half of the contract-verdict fix beside
# the waiver above. `adopt_write_row` puts the row on this session's roster; this puts the
# SOURCE roster's own landing verdict for that name beside it, verbatim, so a reader that
# trusts the marker rather than re-deriving from disk (`hooks/session-start.sh`'s
# `open_rows`, this file's own `youngest_suite_writer`, both scanning the roster they were
# handed for a `landing-swept/v1|…|name=<X>|` line) sees the same answer on the successor
# that stood on the predecessor.
#
# hooks/landing-gate.sh IS THE ONE WRITER of this schema today — its own comment (:561-563)
# already anticipates a second and calls it "not a live path". This call site is that second
# writer, made deliberately narrow: it never COMPUTES a verdict, it only APPENDS a line that
# writer already produced, byte for byte, off the source roster this verb is only ever
# permitted to read (never write — the row above is still the one file this verb writes to).
#
# THE LATEST LINE, because the marker stream is append-only the same way the roster is: a
# name can be superseded (UNMET -> MET) and the last line wins. A MET line can never be the
# one found here — `adopt_fold`'s `met[]` filter above excludes any name carrying one from
# the fold entirely, so a name that reaches this call was never offered one to adopt in the
# first place, and the only history left to find is non-MET.
#
# IDEMPOTENT BY EXACT-LINE PRESENCE, the same posture `adopt_write_row` takes: the source
# session is the one and only writer of ITS OWN marker lines, so a line copied once from it
# never changes shape on a later read, and comparing the verbatim text is enough to know this
# adopt already carried it.
adopt_copy_marker() {  # <source roster> <own roster> <name> -> 0 copied/already there, 1 nothing to copy
  local src="$1" own="$2" name="$3" line
  [ -n "$name" ] && [ -f "$src" ] && [ ! -L "$src" ] || return 1
  # THE SHARED CONSTANT (declared above), NOT A SECOND SPELLING (S15, AC-26). This used to
  # grep the bare literal 'landing-swept/v1' — see the constant's own comment for why a
  # literal here was the exact hazard research-code-map §2.c named.
  line="$(grep "^${SWEPT_SCHEMA}|" "$src" 2>/dev/null | grep -F "|name=${name}|" | tail -1)"
  [ -n "$line" ] || return 1
  grep -qF "$line" "$own" 2>/dev/null && return 0
  [ -f "$own" ] && [ ! -L "$own" ] || return 1
  printf '%s\n' "$line" >> "$own" 2>/dev/null || return 1
  return 0
}

# TWO PLAN PATHS ARE THE SAME PLAN when they name the same file, and the two sides of the
# comparison come from different writers: the caller's marker holds whatever `bind_plan` was
# given, while a roster row holds whatever `session_plan` returned in the session that
# dispatched it. A worktree cwd, a `/tmp` that is really `/private/tmp`, a `.`/`..` in the
# middle — each of those makes two spellings of one file, and a string compare would call the
# row another run's and refuse to adopt this session's own agent.
#
# ONE SITE, AND IT IS `_bind_resolve` (AC-23). This function used to carry its own copy of
# the "resolve the directory, leave the leaf" rule, and `bind` carried a third — three
# canonicalizers that agreed in the middle and disagreed at every edge: `_bind_resolve`
# refuses a relative path, this one degraded to the raw string, bind's degraded to EMPTY.
# The divergence was latent only because `bind_plan` stores the canonical spelling, so
# nothing yet compared two spellings that had been through different resolvers. The next
# comparison added on either side would have been the bug.
#
# THE DIRECTORY IS RESOLVED AND THE LEAF IS NOT — the rule's reason is stated at
# payload/scripts/lib/binding.sh: `find` does not resolve leaves either, so resolving this
# one would make a plan reached through a symlink compare unequal to the same plan as
# `open_runs` reports it. A trailing slash is stripped by that function's `dirname`/
# `basename` split, which is why `<p>/a.md` and `<p>/a.md/` land on one spelling here.
#
# RELATIVE IS MADE ABSOLUTE FIRST, because `_bind_resolve` refuses a relative operand
# outright (binding.sh:57) and a roster row may carry either. The base is the CALLER'S cwd,
# which is what this function resolved against before — a change of base would silently
# re-attribute rows written by a session standing somewhere else.
#
# IT NEVER FAILS. An unresolvable directory — a plan whose tree has since been removed —
# degrades to the raw string, which still compares equal to an identical raw string. A
# comparison that errored here would silently turn every row unattributable.
adopt_plan_key() {  # <plan path> -> a comparable spelling of it
  local p="$1" out
  [ -n "$p" ] || { printf ''; return 0; }
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  out="$(_bind_resolve "$p")" || { printf '%s' "$1"; return 0; }
  printf '%s' "$out"
}

# A roster path is absolute or project-relative, exactly as the row's writer left it.
adopt_abs() {  # <path> <repo root>
  case "$1" in
    /*) printf '%s' "$1" ;;
    '') : ;;
    *)  printf '%s/%s' "$2" "$1" ;;
  esac
}

# ---------------------------------------------------------------- the sweep
#
# THE OTHER HALF OF `adopt` (fixit 1.5.1 T5; ideas/fixit-1.5.2-dead-session-sweep.md).
# `adopt` reads a predecessor's residue back so a resumed session can act on it. Nothing has
# ever removed that residue once NO session can act on it — so a project's `.bionic/tmp`
# grows one set of files per `/clear`, forever, while every one of those files declares
# itself machine-local and safe to delete in its own first line, and doctor proves the
# sessions dead and then names no way to clear them.
#
# THE HARNESS COMPUTES DEADNESS, A HUMAN RUNS THE VERB (D-5). Deadness is
# `patrol_live_sessions` and nothing else: `kill -0` against the pid the CLI itself wrote
# into its own session file — never `ps`, never an mtime heuristic, and never a judgment of
# the rows inside the file. A dead session's agents are dead by construction, so MET, UNMET,
# acked and open are all the same fact once nobody can act on any of them. Auto-sweeping was
# rejected on the record (D-5): the residue is exactly what `adopt` reads, so a hook that
# cleared it at engagement would delete the evidence of the thing it was helping with.
#
# THE FIVE SESSION-KEYED CLASSES, and no sixth. Each is `<class>-<session id>.state` under
# `<root>/.bionic/tmp`, plus the Patrol stamp's `.armed` sibling:
#
#   roster-<sid>.state         hooks/dispatch-preflight.sh   the dispatch ledger
#   preflight-<sid>.state      hooks/preflight-probe.sh      the budget attestation
#   engaged-<sid>.state        scripts/lib/binding.sh        the engagement marker
#   sweeper-<sid>.state        hooks/session-sweeper.sh      the ack ledger
#   patrol-<sid>.state[.armed] this file                     the Patrol stamp and its marker
#
# THE THREE FILES THAT ARE NOT SESSION-KEYED ARE THEREFORE UNREACHABLE FROM HERE, and that
# is a property of the enumeration rather than a list to maintain: `context-spend.state`,
# `farm-out.state` and `stop-check.state` carry no session id in their names, so no id this
# walk derives can ever address one. A future non-session file is safe on arrival for the
# same reason.
SWEEP_SCHEMA="poker-sweep/v1"

# THE ENUMERATION IS THE LIBRARY'S, NOT A COPY (T5 phase 2). Which files belong
# to a session, and which sessions are dead, are read through
# `patrol_state_session_ids`, `patrol_session_state_files` and
# `patrol_dead_sessions` in scripts/lib/patrol.sh — the same three functions
# scripts/lib/checks.sh's dead-session detector calls. They have to agree: a
# class this verb did not delete but the detector counted would put a row on
# doctor's page whose named cure clears nothing, and a second copy of the class
# list here is exactly how that drift arrives. The library's own header carries
# the class table and the reason the unkeyed files are unreachable.

# A SYMLINK IS NOT A FILE THIS SCRIPT WROTE, so it is refused rather than followed and left
# in place rather than unlinked — the identical posture `remove_patrol_stamp` takes, and for
# the identical reason: every reader in the fleet already treats a symlinked state file as
# absent, so there is nothing to clear, and a hostile repo must not gain a delete through a
# path it aimed. A directory at one of these names is refused too: this verb removes files.
sweep_unlink() {  # <path> -> 0 removed, 1 left alone
  local f="$1"
  [ -L "$f" ] && return 1
  [ -f "$f" ] || return 1
  rm -f "$f" 2>/dev/null
  [ -e "$f" ] && return 1
  return 0
}


# ---------------------------------------------------------------- verbs

case "$VERB" in

  interval)
    SECS="$(poker_interval_seconds)" || {
      die "REFUSED — the configured poker-interval could not be read as a duration."
      die "Fix or remove the 'poker-interval:' line in .bionic/config.yaml; the default is $POKER_INTERVAL_DEFAULT."
      exit 2
    }
    printf '%s\n' "$SECS"
    exit 0
    ;;

  # THE DEFAULT, WITHOUT THE CONFIG — added for hooks/dispatch-preflight.sh's arming wall
  # (critic C-2, W5). That wall needs a threshold even when `interval` above REFUSES,
  # because a project's config file is machine-local and agent-writable and one unparseable
  # line there must not be able to disarm a wall. It could have retyped 1800; then this
  # script's constant and the gate's would drift the first time either moved, which is the
  # duplication this repo's ownership rule exists to forbid. So the constant and the
  # duration parse stay here, where they already lived, and the gate asks.
  #
  # NOTHING ELSE READS THE CONFIG ON THIS PATH, deliberately: the whole value of this verb
  # to its caller is that a hostile or broken config.yaml cannot change what it answers.
  interval-default)
    SECS="$(parse_seconds "$POKER_INTERVAL_DEFAULT")" || {
      die "REFUSED — this script's own POKER_INTERVAL_DEFAULT ('$POKER_INTERVAL_DEFAULT') is not a duration."
      exit 2
    }
    printf '%s\n' "$SECS"
    exit 0
    ;;

  # THE WINDOW, ANSWERED BY ITS OWNER. "Since when does THIS roster's own record of this
  # session begin" is a question two readers ask: hooks/session-poker.sh's own counters
  # (`count_main_thread_dispatches`, `count_refused_dispatches`, both of which take the
  # instant as `<since>`) and payload/scripts/lib/patrol.sh, which reconstructs the same
  # tally for doctor. patrol.sh cannot source this file, so without this verb it would grow
  # its own copy of `file_birth`/`epoch_iso`/`roster_window` — a second, silently driftable
  # answer to one question. `patrol_window()` shells out here instead, the same call
  # `patrol_interval()` already makes for the interval and for the identical reason.
  #
  # OUTSIDE THE ENGAGEMENT GATE, exactly like `interval` above it. The gate in this script
  # is per-verb (`adopt`, `sweep`, `tick`), and it guards verbs that DECIDE something about
  # a run. This one decides nothing: it reports a file's creation instant to whoever asks.
  # A session that never engaged bionic still has a doctor page, and that page must not
  # silently fall back to a whole-transcript count because a read-only date refused.
  #
  # READ-ONLY, and — unlike `tick` and `arm` — it writes no stamp: a caller asking "what
  # window would you use" is not itself a firing, and a stamp written here would make
  # doctor's own diagnosis look like a live Patrol.
  window)
    SESSION_ID="$(session_id)" || SESSION_ID=""
    if [ -z "$SESSION_ID" ]; then
      die "REFUSED — no session key (CLAUDE_CODE_SESSION_ID is unset or empty)."
      die "A window answers for ONE session's roster, so without the key there is nothing to date."
      exit 3
    fi
    REPO="$(project_root "$PWD")"
    REPO_REAL="$(cd "$REPO" 2>/dev/null && pwd -P)"
    if [ -z "$REPO_REAL" ]; then
      die "REFUSED — cannot resolve the working directory."
      exit 2
    fi
    ROSTER_FILE="$REPO_REAL/.bionic/tmp/roster-${SESSION_ID}.state"
    WINDOW="$(roster_window "$ROSTER_FILE" "$SESSION_ID")" || WINDOW=""
    [ -n "$WINDOW" ] && printf '%s\n' "$WINDOW"
    exit 0
    ;;

  arm)
    SESSION_ID="$(session_id)" || SESSION_ID=""
    if [ -z "$SESSION_ID" ]; then
      die "REFUSED — no session key (CLAUDE_CODE_SESSION_ID is unset or empty)."
      die "A Patrol stamp answers for ONE session, so without the key there is nothing to write."
      exit 3
    fi
    if ! write_patrol_stamp "$SESSION_ID" arm; then
      die "REFUSED — the Patrol stamp could not be written; this session is NOT armed."
      die "Check that .bionic/tmp is a writable real directory under the project root."
      exit 2
    fi
    # THE SECOND HALF OF ARMING: the instant, recorded so a later tick can tell THIS run's
    # delivery from the previous one's (R-13). Advisory — a session armed without it keeps
    # ticking and never auto-DISARMs, which is the safe direction — so it warns and the arm
    # still stands.
    write_patrol_armed_marker "$SESSION_ID" \
      || die "WARN — the arming instant could not be recorded; this Patrol will not auto-DISARM (run \`disarm\` to stop it)."
    say "armed — the Patrol stamp is fresh for this session: $(patrol_stamp_file "$SESSION_ID")"
    exit 0
    ;;

  # THE DELIBERATE STOP. Paired with `CronDelete` at run close (the ritual is stated in
  # skills/canonical-sdlc/SKILL.md §Dispatch, and both halves belong to it): `CronDelete`
  # stops the firing, this stops the CLAIM that something is still firing. Either half
  # alone leaves a Patrol that is half-stopped in the direction that lies.
  #
  # IDEMPOTENT, AND SILENT ABOUT NOTHING. A ritual is a thing a model runs from a list, so
  # running it twice, or on a session that never armed, answers 0 and says which of the two
  # it was — a no-op reported as a failure is a line the operator has to stop and interpret
  # at exactly the moment the run is trying to end.
  disarm)
    SESSION_ID="$(session_id)" || SESSION_ID=""
    if [ -z "$SESSION_ID" ]; then
      die "REFUSED — no session key (CLAUDE_CODE_SESSION_ID is unset or empty)."
      die "A Patrol stamp answers for ONE session, so without the key there is nothing to remove."
      exit 3
    fi
    DISARM_STAMP="$(patrol_stamp_file "$SESSION_ID")" || DISARM_STAMP=""
    if [ -n "$DISARM_STAMP" ] && [ -f "$DISARM_STAMP" ] && [ ! -L "$DISARM_STAMP" ]; then
      if remove_patrol_stamp "$SESSION_ID"; then
        say "disarmed — the Patrol stamp for this session is removed: $DISARM_STAMP"
        say "CronDelete the Patrol job too if it is still in the table; this half only stops the claim that it fires."
        exit 0
      fi
      die "REFUSED — the Patrol stamp could not be removed, so this session still reads as armed."
      die "Remove it by hand or the death notice keeps firing every turn: $DISARM_STAMP"
      exit 2
    fi
    say "already disarmed — no Patrol stamp for this session${DISARM_STAMP:+: $DISARM_STAMP}"
    exit 0
    ;;

  adopt)
    SESSION_ID="$(session_id)" || SESSION_ID=""
    if [ -z "$SESSION_ID" ]; then
      die "REFUSED — no session key (CLAUDE_CODE_SESSION_ID is unset or empty)."
      die "adopt answers 'what did the OTHER sessions launch here', and without this session's"
      die "own key it cannot tell their rows from ours."
      exit 3
    fi

    # ---------- THE ENGAGEMENT GUARD (AC-10): is this session bionic's at all? ----------
    #
    # BEFORE ANYTHING IS READ, DECIDED OR WRITTEN — above the stamp, above the roster,
    # above the sweeper. Chris, 2026-09-03: "all guardrails imposed by bionic should only
    # apply when exercising bionic. Nothing should apply until bionic is triggered" — and
    # the trigger is the canonical-sdlc skill, which writes
    # `.bionic/tmp/engaged-<sid>.state` at the instant it is invoked. The Patrol prompt
    # runs this verb, and a Patrol inherited by a session that never invoked the skill
    # must decide nothing about it rather than deciding wrongly.
    #
    # ONE LINE, EXIT 0, and not a refusal: the tick fired correctly and found nothing it
    # is entitled to judge. `arm` is deliberately not guarded (writing a stamp for a
    # session that asked for one is harmless) and neither is `disarm`, which removes the
    # stamp and leaves this marker exactly where it is — a session that invoked the skill
    # is bionic's for its whole life, so every hook still binds after a disarm (AC-15).
    # [WALL: tests/session-poker.test.sh]
    if ! engaged_session "$(project_root "$PWD")" "$SESSION_ID"; then
      say "NOT-ENGAGED — this session has not invoked /bionic:canonical-sdlc; nothing decided"
      exit 0
    fi

    REPO="$(project_root "$PWD")"
    REPO_REAL="$(cd "$REPO" 2>/dev/null && pwd -P)"
    if [ -z "$REPO_REAL" ]; then
      die "REFUSED — cannot resolve the working directory."
      exit 2
    fi
    ADOPT_DIR="$REPO_REAL/.bionic/tmp"
    # The ONE file this verb writes: this session's own roster. Named here, once, so the
    # loop below cannot be read as writing anything it iterates over.
    ADOPT_OWN_ROSTER="$ADOPT_DIR/roster-${SESSION_ID}.state"
    ADOPT_ROWS=0
    ADOPT_SESSIONS=0
    ADOPT_NOW="$(now_epoch)"

    # ---------- THE PARTITION (spec AC-2; design ledger T2) ----------
    #
    # THE BUG THIS CLOSES is symptom 2 of the report: this loop walked every roster in the
    # project and offered every open row on every one of them, filtered by nothing but the
    # filename. Two runs sharing a root meant each session was handed the other run's agents
    # to ledger, message and stop.
    #
    # ATTRIBUTION, NOT A SECOND SCAN. hooks/dispatch-preflight.sh stamps the dispatching
    # session's bound plan onto every row it writes, and a BOUND caller compares that field
    # against its own binding: same plan is its own work, a different plan is another run in
    # this root, no field at all is a roster written before this wave (A2). Only the first is
    # written to this session's roster; the other two are LISTED, because a predecessor's
    # agent that is invisible is exactly the failure `adopt` exists to prevent — the operator
    # still needs to see that something is running here, even when taking it is not theirs.
    #
    # AN UNBOUND CALLER HAS NOTHING TO COMPARE AGAINST and gets today's behaviour verbatim:
    # every row, adopted, `partition=all` (AC-3). `session_plan` is the RAW binding rather
    # than `session_run`'s resolution, deliberately — a session bound to a plan that has
    # since closed still owns the rows it dispatched under it, and the fallback plan of an
    # unbound session was never anyone's attribution.
    ADOPT_OWN_PLAN="$(session_plan "$REPO_REAL" "$SESSION_ID")" || ADOPT_OWN_PLAN=""
    ADOPT_OWN_KEY=""
    [ -n "$ADOPT_OWN_PLAN" ] && ADOPT_OWN_KEY="$(adopt_plan_key "$ADOPT_OWN_PLAN")"
    ADOPT_ADOPTED=0
    ADOPT_LISTED=0
    ADOPT_LAST_PART=""

    for ADOPT_RF in "$ADOPT_DIR"/roster-*.state; do
      [ -f "$ADOPT_RF" ] || continue
      # Symlinks are not followed, the same posture every other .bionic/tmp reader takes.
      [ -L "$ADOPT_RF" ] && continue
      OSID="${ADOPT_RF##*/}"; OSID="${OSID#roster-}"; OSID="${OSID%.state}"
      [ -n "$OSID" ] || continue
      [ "$OSID" = "$SESSION_ID" ] && continue

      ADOPT_LEDGER="$ADOPT_DIR/sweeper-${OSID}.state"
      [ -f "$ADOPT_LEDGER" ] && [ ! -L "$ADOPT_LEDGER" ] || ADOPT_LEDGER=""
      ADOPT_OUT="$(adopt_fold "$ADOPT_RF" "$ADOPT_LEDGER")"
      [ -n "$ADOPT_OUT" ] || continue
      ADOPT_SESSIONS=$((ADOPT_SESSIONS + 1))

      # Resolved ONCE per predecessor session, not once per row: the walk is the same for
      # every agent that session launched.
      OSUB="$(session_subagent_dir "$OSID")" || OSUB=""

      while IFS='|' read -r RNAME RID RTYPE RDELIV RPROG RCAD RLAUNCH RORIG RPLAN RWAIVER \
                            RFILES RSALLOW RSSRC; do
        [ -n "$RNAME" ] || continue
        ADOPT_ROWS=$((ADOPT_ROWS + 1))

        # ---- THE STOP ADDRESS, BUILT FROM THE SESSION THAT LAUNCHED THE AGENT
        #
        # T3 FINDING 1, live 2026-09-03. This was the ADOPTING session's eight until a real
        # `/clear` was driven against a real harness: `TaskStop PROBE-AGENT@session-<adopting
        # 8>` came back `No task found with ID: … Running teammates:
        # PROBE-AGENT@session-<launching 8>`. The probe that argued for the adopting session
        # was right about the env — `CLAUDE_CODE_SESSION_ID` does re-key — and wrong about
        # the teammate table, which keys on the session that made the `Agent` call and does
        # not re-key with it. So the suffix comes off the ROW (its `adopted_from=`, else its
        # own `session=`, else the roster file's session), never off ours.
        #
        # EMPTY WITHOUT AN ID, because the address is only ever offered beside one: a row
        # with no identity has no stop line to carry it, and a machine field that named an
        # address the UNADDRESSABLE branch refuses to print would contradict its own row.
        ADOPT_ADDR_SID="${RORIG:-$OSID}"
        ADOPT_ADDR=""
        [ -n "$RID" ] \
          && ADOPT_ADDR="$(clean "$RNAME")@session-$(printf '%s' "$ADOPT_ADDR_SID" | cut -c1-8)"

        # ---- the deliverable, on disk or not
        RDELIV_ABS="$(adopt_abs "$RDELIV" "$REPO_REAL")"
        DELIV_PRESENT=no
        [ -n "$RDELIV_ABS" ] && [ -e "$RDELIV_ABS" ] && DELIV_PRESENT=yes

        # ---- the progress file's age against the cadence its own row declared
        RPROG_ABS="$(adopt_abs "$RPROG" "$REPO_REAL")"
        PROG_AGE=""
        [ -n "$RPROG_ABS" ] && [ -f "$RPROG_ABS" ] \
          && PROG_AGE=$(( ADOPT_NOW - $(file_mtime "$RPROG_ABS") ))
        CAD_S="$(parse_seconds "$RCAD")" || CAD_S=""

        # ---- the three addresses, all of them derived from the one id
        TX=""
        TX_PRESENT=no
        TX_AGE=""
        if [ -n "$RID" ]; then
          if [ -n "$OSUB" ]; then
            TX="$OSUB/agent-${RID}.jsonl"
            if [ -f "$TX" ]; then
              TX_PRESENT=yes
              # THE SECOND LIVENESS INPUT. The harness appends to this file on every turn
              # the agent takes, so its mtime is a fact about the agent rather than a
              # promise the agent has to remember to keep.
              TX_AGE=$(( ADOPT_NOW - $(file_mtime "$TX") ))
            fi
          else
            # The slug could not be resolved — say where to look rather than inventing a
            # path that would read as a fact.
            TX="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/${OSID}/subagents/agent-${RID}.jsonl"
          fi
        fi

        # ---- the verdict
        #
        # UNADDRESSABLE OUTRANKS THE REST, because it is the only one of the four that is
        # about this verb's own subject — the id. A row without one cannot be messaged or
        # stopped whatever its artifacts say, and the cure is prospective (it fixes the NEXT
        # dispatch, not this row). The deliverable's state is still printed underneath, so
        # nothing is hidden by the ordering.
        #
        # WAIVED IS NEXT (S17, AC-12 attempt 2), ahead of LANDED/RUNNING/SILENT, and for the
        # same reason `session-sweeper.sh verdict_row` puts it first: a carried `waiver=` is
        # an explicit designation that this row's contract is not held, so its deliverable's
        # absence is not "quiet for now" — it was never open. Printing SILENT for such a row,
        # which is what happened before the field was carried at all, read as an unmet
        # contract for one that was closed at dispatch (the live T4 walk this fixes).
        # LIVE ON EITHER MTIME, STALE ONLY ON BOTH (1.6, AC-6). The progress file is a
        # promise the agent keeps by hand — the first thing to lapse when the work gets
        # absorbing, and impossible for a role with no Write tool — so reading it alone
        # called working agents SILENT. The transcript is the harness's own record of the
        # agent taking a turn, at the very path this verb already prints as the observe
        # address, so it costs one stat and answers the question the progress file was
        # standing in for. SILENT now means neither a written line nor a turn taken inside
        # the window, which is a state worth waking someone for.
        #
        # THE WINDOW is `PATROL_STALE_MULTIPLIER × cadence`, out of the library
        # (payload/scripts/lib/patrol.sh) rather than an inline `* 2` — one constant, three
        # readers, spec AC-22. It is more than one cadence because a row promising a line
        # every 10 minutes is, at any random instant, up to 10 minutes stale while perfectly
        # healthy; a threshold at the cadence itself would call half the live fleet SILENT.
        # Same slack hooks/dispatch-preflight.sh allows the Patrol stamp.
        LIVE=no
        if [ -n "$CAD_S" ]; then
          STALE_LIMIT=$(( CAD_S * PATROL_STALE_MULTIPLIER ))
          [ -n "$PROG_AGE" ] && [ "$PROG_AGE" -le "$STALE_LIMIT" ] && LIVE=yes
          [ -n "$TX_AGE" ] && [ "$TX_AGE" -le "$STALE_LIMIT" ] && LIVE=yes
        fi

        if [ -z "$RID" ]; then
          VERDICT=UNADDRESSABLE
        elif [ -n "$RWAIVER" ]; then
          VERDICT=WAIVED
        elif [ "$DELIV_PRESENT" = yes ]; then
          VERDICT=LANDED
        elif [ "$LIVE" = yes ]; then
          VERDICT=RUNNING
        else
          VERDICT=SILENT
        fi

        # ---- WHOSE RUN IS THIS ROW? (AC-2)
        #
        # `plan=none` READS AS UNATTRIBUTED, not as another run. `none` is the marker's own
        # word for "this session had no binding" (payload/scripts/lib/run.sh:378), so a row
        # carrying it names no run at all — and calling it "another run in this root" would
        # assert a run that does not exist. Both answers are un-adoptable, so the choice
        # only decides which heading the operator reads it under.
        if [ -z "$ADOPT_OWN_KEY" ]; then
          PARTITION=all
        elif [ -z "$RPLAN" ] || [ "$RPLAN" = none ]; then
          PARTITION=unattributed
        elif [ "$(adopt_plan_key "$RPLAN")" = "$ADOPT_OWN_KEY" ]; then
          PARTITION=own
        else
          PARTITION=other
        fi
        case "$PARTITION" in
          own|all) ADOPT_ADOPTED=$((ADOPT_ADOPTED + 1)) ;;
          *)       ADOPT_LISTED=$((ADOPT_LISTED + 1)) ;;
        esac

        # THE HEADING IS A GROUP SEPARATOR, printed when the partition CHANGES rather than
        # once for the whole report. Rows arrive in roster order and a predecessor session
        # dispatched under one binding, so in practice each kind is one contiguous run and
        # gets exactly one heading; a session that rebound mid-flight interleaves them and
        # gets the heading again, which is right — a heading standing over rows of another
        # kind would be worse than a repeated one. An unbound caller sees neither line.
        if [ "$PARTITION" != "$ADOPT_LAST_PART" ]; then
          case "$PARTITION" in
            other)        say "other runs in this root — listed, never adopted" ;;
            unattributed) say "unattributed rows (pre-wave rosters) — listed, never adopted" ;;
          esac
        fi
        ADOPT_LAST_PART="$PARTITION"

        # THE TWO NEW FIELDS ARE TRAILING, so every existing field keeps its position for a
        # reader that counts rather than looks up by key. `plan=` is the row's own
        # attribution (`none` when it carried none) and `partition=` is what this caller
        # decided about it.
        printf '%s|at=%s|session=%s|from=%s|name=%s|verdict=%s|agent_id=%s|address=%s|subagent_type=%s|deliverable=%s|deliverable_present=%s|progress=%s|progress_age=%s|cadence=%s|transcript=%s|transcript_present=%s|transcript_age=%s|plan=%s|partition=%s\n' \
          "$ADOPT_SCHEMA" "$(iso_now)" "$SESSION_ID" "$OSID" "$(clean "$RNAME")" "$VERDICT" \
          "$RID" "$ADOPT_ADDR" "$(clean "$RTYPE")" "$(clean "$RDELIV_ABS")" "$DELIV_PRESENT" \
          "$(clean "$RPROG_ABS")" "${PROG_AGE:-unknown}" "${CAD_S:-unknown}" \
          "$(clean "$TX")" "$TX_PRESENT" "${TX_AGE:-unknown}" \
          "$(clean "${RPLAN:-none}")" "$PARTITION"

        # ---- the adoption itself, written before it is printed
        #
        # The row is what makes the address below TRUE: hooks/stop-guard.sh accepts
        # `<name>@session-<this session>` as an identity because THIS session's roster
        # records it, and resolves the agent at all because the row names the session it is
        # filed under. Printing the address without writing the row would hand the operator
        # a second line they cannot use.
        # THE WRITE'S ANSWER IS READ, because `die()` prints and RETURNS — it does not exit
        # (:156, and every other caller depends on that). A warning followed by the address
        # block below would hand the operator a `TaskStop` line that both stop gates refuse
        # as FOREIGN, since ownership is taken from the row that was just NOT written
        # (review-a C-3). So the row's own state decides which rendering it gets.
        #
        # `--report-only` TAKES THE SAME ROW AND DOES NOT FILE IT. The rendering below is
        # unchanged — same verdict, same addresses, same tail — because the whole point of
        # the flag is that the operator reads exactly what `adopt` would then write. The
        # stop address it prints is the address the write MAKES true, so it is printed as
        # the instruction it is: run `adopt`, and this line works. AC-4's "identical rows"
        # is pinned in tests/session-poker.test.sh §8i by comparing the two renderings.
        #
        # AND THE PARTITION DECIDES WHETHER IT IS FILED AT ALL (AC-2). A row belonging to
        # another run in this root is never written to this session's roster: the write is
        # what makes the stop address true, so writing it would take ownership of an agent
        # this session did not launch and is not steering — the exact harm the partition
        # exists to prevent. It is still printed, one arm down.
        ROW_JOURNALLED=no
        ROW_LISTED_ONLY=no
        case "$PARTITION" in
          own|all)
            if [ -n "$RID" ] && [ "$ADOPT_REPORT_ONLY" = yes ]; then
              ROW_JOURNALLED=yes
            elif [ -n "$RID" ]; then
              if adopt_write_row "$ADOPT_OWN_ROSTER" "$SESSION_ID" "$RNAME" "$RID" "$RTYPE" \
                   "$RDELIV" "$RPROG" "$RCAD" "$RLAUNCH" "$OSID" "$ADOPT_ADDR" \
                   "${ADOPT_OWN_PLAN:-none}" "$RWAIVER" \
                   "$RFILES" "$RSALLOW" "$RSSRC"; then
                ROW_JOURNALLED=yes
                # THE MARKER COPY (S17, AC-12 attempt 2). `hooks/landing-gate.sh` is this
                # schema's one writer today — its own comment at :561-563 calls a second
                # writer "not a live path". This makes it one, deliberately: adopt never
                # ORIGINATES a `landing-swept/v1` verdict, it only COPIES a line that writer
                # already produced onto the roster this session is now the owner of, so
                # `hooks/session-start.sh`'s `open_rows` and this file's own
                # `youngest_suite_writer` — both of which read a marker straight off the
                # SAME roster file as ground truth, with no re-derivation — see the same
                # history on the successor that stood on the predecessor. A MET marker can
                # never reach here: `adopt_fold`'s own `met[]` filter (above) excludes any
                # name carrying one from the fold entirely, so only a non-MET history
                # (UNMET/STILL-LIVE/AMBIGUOUS) is ever offered to copy.
                adopt_copy_marker "$ADOPT_RF" "$ADOPT_OWN_ROSTER" "$(clean "$RNAME")"
              else
                die "WARN — this row could not be journalled to $ADOPT_OWN_ROSTER; the stop gate will not treat $RNAME as ours."
              fi
            fi ;;
          *) ROW_LISTED_ONLY=yes ;;
        esac

        say "$(clean "$RNAME") ($(clean "$RTYPE")) from session $OSID — $VERDICT"
        if [ -n "$RID" ] && [ "$ROW_JOURNALLED" = yes ]; then
          printf '  agent id    : %s\n' "$RID"
          printf '  observe     : %s (%s)\n' "$TX" \
            "$([ "$TX_PRESENT" = yes ] && echo 'on disk' || echo 'not on disk')"
          printf '  message     : SendMessage to:%s\n' "$RID"
          # THE ADDRESS THE PLATFORM ACCEPTS, not the one this verb happens to hold. The id
          # on the roster is the TRANSCRIPT form; the stop primitive takes
          # `<name>@session-<id8>` for a teammate and rejects the transcript form (capture
          # record/session-20260814-wave-detector-terminal-state/min/logs/A-p3.jsonl:9), so
          # printing the id cost the operator a refusal they could not clear.
          #
          # ONE SUFFIXED SPELLING, AND IT IS THE LAUNCHING SESSION'S (T3 FINDING 1). The
          # alternate — this session's eight — was printed here until a live `/clear` drive
          # refused it by name and the harness named the launching session's in its place.
          # See the construction above for what the row is read for.
          #
          # AND THE BARE NAME BENEATH IT, because it is the one address that survived every
          # step of that drive: it reached the stop wall before the `/clear` and after it,
          # and it is what finally stopped the adopted agent when the suffixed form did not
          # resolve. Neither stop gate keys on the suffix — each resolves on the base name
          # and takes ownership from the id on this session's roster
          # (tests/stop-guard.test.sh §14, tests/stop-check.test.sh §10(d)) — so offering
          # both costs the operator nothing and covers the case where the suffix is stale.
          printf '  stop        : TaskStop %s\n' "$ADOPT_ADDR"
          printf '                TaskStop %s — the bare name, the address that always survives\n' \
            "$(clean "$RNAME")"
        elif [ "$ROW_LISTED_ONLY" = yes ] && [ -n "$RID" ]; then
          # LISTED, NOT ADOPTED. Everything that does not depend on this session's roster is
          # still printed — the id, the observe address, the message address all belong to
          # the agent rather than to us — and the one line that would be a lie is replaced by
          # the reason it is missing. The operator can still SEE and MESSAGE an agent of the
          # other run; taking ownership of it is what they may not do, and the cure is the
          # other session, not a retry here.
          printf '  agent id    : %s\n' "$RID"
          printf '  observe     : %s (%s)\n' "$TX" \
            "$([ "$TX_PRESENT" = yes ] && echo 'on disk' || echo 'not on disk')"
          printf '  message     : SendMessage to:%s\n' "$RID"
          if [ "$PARTITION" = other ]; then
            printf '  stop        : not adopted — this row belongs to another run in this root\n'
            printf '                (%s), and ownership stays with the session working it.\n' "${RPLAN:-none}"
          else
            printf '  stop        : not adopted — this row carries no plan= attribution\n'
            printf '                (a roster written before session-bound runs existed), so it\n'
            printf '                cannot be told from another run in this root.\n'
          fi
        elif [ -n "$RID" ]; then
          # ADDRESSABLE FOR EVERYTHING BUT THE STOP. The id is real and the transcript and
          # the message address do not depend on this session's roster — only ownership
          # does, and that is precisely what the failed write cost. So the two true lines
          # are still printed and the one that would be false is replaced by its cause,
          # which is the UNADDRESSABLE shape below applied to the half that is missing.
          printf '  agent id    : %s\n' "$RID"
          printf '  observe     : %s (%s)\n' "$TX" \
            "$([ "$TX_PRESENT" = yes ] && echo 'on disk' || echo 'not on disk')"
          printf '  message     : SendMessage to:%s\n' "$RID"
          printf '  stop        : unavailable — this adoption was NOT journalled to\n'
          printf '                %s\n' "$ADOPT_OWN_ROSTER"
          printf '  cure        : both stop gates take ownership from THIS session'"'"'s roster, so\n'
          printf '                until that write lands every stop of %s is refused as\n' "$(clean "$RNAME")"
          printf '                FOREIGN. Clear that path — a symlink where the roster goes, or\n'
          printf '                a .bionic/tmp that is not a writable real directory — and re-run adopt.\n'
        else
          printf '  agent id    : (none — no identified row on that roster)\n'
          printf '  observe     : unavailable without an id\n'
          printf '  message     : unavailable without an id\n'
          printf '  stop        : unavailable without an id\n'
          printf '  cure        : the predecessor'"'"'s dispatch wall or execution recorder was dead when\n'
          printf '                this row was written — re-invoke /bionic:canonical-sdlc before\n'
          printf '                dispatching, or the same thing happens again.\n'
        fi
        printf '  launched    : %s\n' "${RLAUNCH:-unknown}"
        printf '  deliverable : %s (%s)\n' "${RDELIV_ABS:-none declared}" \
          "$([ "$DELIV_PRESENT" = yes ] && echo 'on disk' || echo 'not on disk')"
        printf '  progress    : %s (%s)\n' "${RPROG_ABS:-none declared}" \
          "$([ -n "$PROG_AGE" ] && printf '%ss old, cadence %ss' "$PROG_AGE" "${CAD_S:-unknown}" || echo 'not on disk')"
        if [ "$TX_PRESENT" = yes ]; then
          TAIL_TEXT="$(agent_report_tail "$TX")" || TAIL_TEXT=""
          if [ -n "$TAIL_TEXT" ]; then
            printf '  report tail (last long assistant block, capped at %s chars — quote it into\n' "$ADOPT_TAIL_CAP"
            printf '  the record before acting on it; a transcript is not an artifact):\n'
            printf '%s\n' "$TAIL_TEXT" | sed 's/^/    | /'
          fi
        fi
        printf '\n'
      done <<EOF
$ADOPT_OUT
EOF
    done

    printf '%s|at=%s|session=%s|scanned=%s|open=%s|adopted=%s|listed=%s\n' \
      "$ADOPT_SCHEMA" "$(iso_now)" "$SESSION_ID" "$ADOPT_SESSIONS" "$ADOPT_ROWS" \
      "$ADOPT_ADOPTED" "$ADOPT_LISTED"
    if [ "$ADOPT_ROWS" -eq 0 ]; then
      say "nothing to adopt — no other session has an open row on this project's rosters."
      exit 0
    fi
    say "$ADOPT_ROWS open row(s) from $ADOPT_SESSIONS predecessor session(s) — ledger every one BY AGENT ID before dispatching anything new."
    # THE SECOND LINE EXISTS ONLY WHEN IT SAYS SOMETHING. A caller that adopted everything it
    # found is the case this verb has always described, and a count of zero listed rows would
    # be a line the operator has to read to learn nothing.
    [ "$ADOPT_LISTED" -gt 0 ] \
      && say "$ADOPT_ADOPTED adopted onto this session's roster, $ADOPT_LISTED listed only — a row belonging to another run in this root is never adopted."
    # ONE EXTRA LINE, and the rows above untouched: the mode is stated where it changes what
    # the reader should do next, not woven through a rendering that has to stay comparable.
    [ "$ADOPT_REPORT_ONLY" = yes ] \
      && say "report-only: nothing was written — run 'adopt' to take these rows onto this session's roster."
    exit 1
    ;;

  # ---------------------------------------------------------------- sweep
  #
  # NOT ENGAGEMENT-GATED, AND DELIBERATELY (D-4). The engagement marker is itself one of the
  # files this verb removes: a session that never invoked the skill still leaves preflight
  # and roster state behind when it dies, and a cleanup that refused to run without
  # engagement would refuse hardest on the machines carrying the most residue. The guard the
  # other verbs take exists so bionic decides nothing about a session that never asked it to;
  # this verb decides nothing about any session at all — it removes files whose owners the
  # kernel says are gone.
  #
  # IT TAKES NO SESSION ID, and that is the surface staying closed rather than an omission.
  # The question is "what here can nobody act on any more", which is a question about the
  # directory; an id operand would be a second way to ask it, and the one thing a caller
  # could do with it that the walk does not already do is name a session the walk skipped —
  # which is exactly the live one this verb refuses.
  #
  # THE EXIT CODE SAYS WHETHER ANYTHING IS LEFT THAT THIS VERB MAY NOT TOUCH:
  #   0  the sweep completed — dead state removed (or listed), or there was none to begin with
  #   1  nothing swept: every session with state here is LIVE, so there was nothing to remove
  #   2  usage, or a `.bionic/tmp` this verb will not delete inside
  # A live session's state is not a fault and the 1 is not a scolding — it is the one answer
  # a caller cannot read off "0 files removed", which is also what a live-only run and an
  # empty directory would otherwise share.
  sweep)
    # The current session's own key, when it has one. It is not required — this verb answers
    # for the DIRECTORY, not for a session — but when it is present the session is live by
    # construction, and adding it by hand means a claude-home this process cannot read (an
    # unreadable `~/.claude/sessions`, a missing `jq`) can never let a session sweep its own
    # state out from under itself.
    SESSION_ID="$(session_id)" || SESSION_ID=""

    REPO="$(project_root "$PWD")"
    REPO_REAL="$(cd "$REPO" 2>/dev/null && pwd -P)"
    if [ -z "$REPO_REAL" ]; then
      die "REFUSED — cannot resolve the working directory."
      exit 2
    fi
    SWEEP_DIR="$REPO_REAL/.bionic/tmp"

    # THE SAME GUARD THE WRITERS TAKE, because a delete is a write. `tmp_dir_ok` is this
    # file's one copy of the rule (a `.bionic` symlinked outside the repo, a `tmp` that is
    # itself a link), and taking it here means the walk below cannot enumerate a single path
    # inside a directory the stamp writer would have refused.
    if ! tmp_dir_ok "$SWEEP_DIR"; then
      die "REFUSED — $SWEEP_DIR is not a directory this verb will delete inside."
      die "A .bionic or a tmp that is a symlink out of this repo is refused, never followed."
      exit 2
    fi
    if [ ! -d "$SWEEP_DIR" ]; then
      say "nothing to sweep — this project has no .bionic/tmp."
      exit 0
    fi

    # THE JUDGMENT IS TAKEN ONCE, BY THE LIBRARY, and this loop only renders it.
    # `patrol_dead_sessions` is handed this session's own key as an additional
    # live id: it is live by construction, and naming it by hand is what stops an
    # unreadable claude-home from letting a session sweep its own state.
    SWEEP_DEAD_IDS="$(patrol_dead_sessions "$REPO_REAL" "$SESSION_ID")"

    SWEEP_SCANNED=0
    SWEEP_DEAD=0
    SWEEP_KEPT=0
    SWEEP_FILES=0
    SWEEP_REMOVED=0
    SWEEP_REFUSED=0

    while IFS= read -r SWEEP_SID; do
      [ -n "$SWEEP_SID" ] || continue
      SWEEP_SCANNED=$((SWEEP_SCANNED + 1))

      # Newline-delimited containment against the DEAD set: an id counts as dead
      # only as a whole line, so a live session whose id is a prefix of a dead
      # one is not mistaken for it.
      case "
$SWEEP_DEAD_IDS
" in
        *"
$SWEEP_SID
"*) ;;
        *)
          SWEEP_KEPT=$((SWEEP_KEPT + 1))
          say "$SWEEP_SID — live, kept"
          continue
          ;;
      esac

      SWEEP_DEAD=$((SWEEP_DEAD + 1))
      SWEEP_N=0
      SWEEP_LINES=""
      while IFS= read -r SWEEP_F; do
        [ -n "$SWEEP_F" ] || continue
        SWEEP_FILES=$((SWEEP_FILES + 1))
        SWEEP_N=$((SWEEP_N + 1))
        if [ "$SWEEP_REPORT_ONLY" = yes ]; then
          # A LINK IS NAMED AS A LINK EVEN HERE, so the report of what would happen matches
          # what happens: a run that listed a symlink as a file to delete and then left it
          # would have lied about its own next invocation.
          if [ -L "$SWEEP_F" ]; then
            SWEEP_REFUSED=$((SWEEP_REFUSED + 1))
            SWEEP_LINES="${SWEEP_LINES}  refused (symlink, left alone): $SWEEP_F
"
          else
            SWEEP_LINES="${SWEEP_LINES}  $SWEEP_F
"
          fi
          continue
        fi
        if sweep_unlink "$SWEEP_F"; then
          SWEEP_REMOVED=$((SWEEP_REMOVED + 1))
          SWEEP_LINES="${SWEEP_LINES}  $SWEEP_F
"
        else
          SWEEP_REFUSED=$((SWEEP_REFUSED + 1))
          SWEEP_LINES="${SWEEP_LINES}  refused (symlink or not a file, left alone): $SWEEP_F
"
        fi
      done <<EOF
$(patrol_session_state_files "$REPO_REAL" "$SWEEP_SID")
EOF

      say "$SWEEP_SID — dead, $SWEEP_N file(s)"
      printf '%s' "$SWEEP_LINES" | while IFS= read -r SWEEP_L; do
        [ -n "$SWEEP_L" ] && say "$SWEEP_L"
      done
    done <<EOF
$(patrol_state_session_ids "$REPO_REAL")
EOF

    printf '%s|at=%s|session=%s|mode=%s|scanned=%s|dead=%s|live=%s|files=%s|removed=%s|refused=%s\n' \
      "$SWEEP_SCHEMA" "$(iso_now)" "${SESSION_ID:-none}" \
      "$([ "$SWEEP_REPORT_ONLY" = yes ] && printf 'report-only' || printf 'sweep')" \
      "$SWEEP_SCANNED" "$SWEEP_DEAD" "$SWEEP_KEPT" "$SWEEP_FILES" "$SWEEP_REMOVED" "$SWEEP_REFUSED"

    if [ "$SWEEP_SCANNED" -eq 0 ]; then
      say "nothing to sweep — no session-keyed state under $SWEEP_DIR."
      exit 0
    fi

    if [ "$SWEEP_DEAD" -eq 0 ]; then
      die "REFUSED — nothing swept: all $SWEEP_KEPT session(s) with state under $SWEEP_DIR are LIVE."
      die "A live session's state is its own to keep; this verb removes only what nobody can act on."
      exit 1
    fi

    if [ "$SWEEP_REPORT_ONLY" = yes ]; then
      say "report-only: $SWEEP_FILES file(s) across $SWEEP_DEAD dead session(s) would be deleted — nothing was written."
      say "run 'sweep' to delete them."
      exit 0
    fi

    say "swept $SWEEP_REMOVED file(s) across $SWEEP_DEAD dead session(s); $SWEEP_KEPT live session(s) kept."
    [ "$SWEEP_REFUSED" -gt 0 ] \
      && say "$SWEEP_REFUSED path(s) refused and left alone — a symlink under .bionic/tmp is never followed."
    exit 0
    ;;

  # ---------------------------------------------------------------- bind
  #
  # THE ACT THAT NAMES THIS SESSION'S RUN (spec AC-8; design ledger D1). Identity is
  # DECLARED, never inferred by a scan: engagement binds a session when the root holds
  # exactly one open run and writes `plan=none` when it holds several (AC-7), so a session
  # resumed into a two-run root is deliberately left unbound until it says which run is its
  # own. This verb is how it says so.
  #
  # AND IT IS THE ONLY WAY A BINDING CHANGES AFTER ENGAGEMENT, besides the governing skill's
  # bind-on-first-write (hooks/canonical-sdlc-governing-skill.sh, AC-9). D1 rejected both
  # alternatives on the record: an argument on the engage hook turns a hook into a command,
  # and a hand-edited marker abandons the one-writer invariants that make the file readable
  # at all. Nothing else in this file writes the marker.
  #
  # THE INVARIANTS ARE THE LIBRARY'S, NOT A SECOND COPY. `bind_plan`
  # (payload/scripts/lib/binding.sh) owns the two-line shape, mode 600, the symlink refusal
  # and — the one that matters here — MEMBERSHIP in `open_runs`, the same set `session_run`
  # will later rule on. This verb's own work is to say WHICH refusal happened, because
  # `bind_plan` answers 0/1/2 and an operator handed a bare "refused" cannot tell a typo
  # from a closed run.
  bind)
    SESSION_ID="$(session_id)" || SESSION_ID=""
    if [ -z "$SESSION_ID" ]; then
      die "REFUSED — no session key (CLAUDE_CODE_SESSION_ID is unset or empty)."
      die "A binding answers for ONE session, so without the key there is nothing to write."
      exit 3
    fi

    # THE ENGAGEMENT GUARD, above everything, for `adopt`'s reason verbatim (AC-10): nothing
    # bionic does applies until the session invoked the skill. Note that this guard also
    # answers the planted-symlink case — `engaged_session` refuses a symlink at the marker
    # path before it is followed (payload/scripts/lib/run.sh:351) — so the link's target is
    # never written through, one line before `bind_plan` would have refused it too.
    if ! engaged_session "$(project_root "$PWD")" "$SESSION_ID"; then
      say "NOT-ENGAGED — this session has not invoked /bionic:canonical-sdlc; nothing decided"
      exit 0
    fi

    REPO="$(project_root "$PWD")"
    REPO_REAL="$(cd "$REPO" 2>/dev/null && pwd -P)"
    if [ -z "$REPO_REAL" ]; then
      die "REFUSED — cannot resolve the working directory."
      exit 2
    fi

    # ABSOLUTE, BECAUSE THE MARKER IS READ FROM EVERY CWD IN THE FLEET. A relative operand is
    # taken against the PROJECT ROOT rather than `$PWD`: the plan path an operator has to
    # hand is the one their editor shows, which is project-relative, and a worktree cwd would
    # otherwise resolve it against a tree that does not hold the run.
    #
    # AND AGAINST THE DOCS ROOT WHEN THAT MISSES (S10b phase 2). hooks/session-start.sh
    # prints the open-run listing DOCS-root-relative — `plans/<epic>/<wave>.md` — because
    # every absolute path in that listing shares one long prefix. An operator who copies a
    # listed line straight into this verb was handing over a project-relative path that does
    # not exist, and getting a refusal that reads as if the PLAN were wrong rather than the
    # spelling. Both spellings now bind.
    #
    # THE PROJECT ROOT IS TRIED FIRST AND WINS TIES, so every operand that resolved before
    # resolves to exactly the same file now: the docs root is reached only when the
    # project-relative spelling is not a regular file, which is the case that used to refuse.
    # A miss under both leaves `BIND_PATH` at the project-root spelling, so the refusal names
    # the path an operator typing a repo path would expect to see.
    # A TRAILING SLASH IS NOT A DIFFERENT PLAN (S8). Shell completion on a path an operator
    # is still typing leaves one behind, and `[ -f "<file>/" ]` is FALSE — so the docs-root
    # fallback below used to miss on the one spelling and hit on the other, and the two
    # operands that name one file bound to two different things. The canonicalizer strips it
    # anyway (`dirname`/`basename`); stripping it here is what lets both spellings reach the
    # same probe. `/` keeps its slash: it is the path, not a decoration on one.
    BIND_ARG_P="$BIND_ARG"
    while [ ${#BIND_ARG_P} -gt 1 ]; do
      case "$BIND_ARG_P" in */) BIND_ARG_P="${BIND_ARG_P%/}" ;; *) break ;; esac
    done
    case "$BIND_ARG_P" in
      /*) BIND_PATH="$BIND_ARG_P" ;;
      *)
        BIND_PATH="$REPO/$BIND_ARG_P"
        if [ ! -f "$BIND_PATH" ]; then
          BIND_DOCS_TRY="$(docs_root "$REPO")/$BIND_ARG_P"
          [ -f "$BIND_DOCS_TRY" ] && BIND_PATH="$BIND_DOCS_TRY"
        fi ;;
    esac

    BIND_RC=0
    bind_plan "$REPO_REAL" "$SESSION_ID" "$BIND_PATH" || BIND_RC=$?
    if [ "$BIND_RC" -eq 0 ]; then
      say "bound $BIND_PATH"
      exit 0
    else
      if [ "$BIND_RC" -ge 2 ]; then
        die "REFUSED — marker write failed"
        die "The binding was valid; the marker could not be written. Check that"
        die "$REPO_REAL/.bionic/tmp is a writable real directory."
        exit 2
      fi
      # WHICH REFUSAL, decided POSITIONALLY. `bind_plan` returns one code for every invalid
      # binding, so the reason is re-derived here from where the path is: a regular file in a
      # plan directory of this root is a plan that is not OPEN (delivered, abandoned, or
      # carrying no readable `## SDLC State`), and anything else is not a plan of this root
      # at all. The marker-symlink case is listed for completeness — the guard above answers
      # it first — so that every 1 from the library leaves this verb with something to say.
      BIND_MARKER="$(engaged_marker_path "$REPO_REAL" "$SESSION_ID")" || BIND_MARKER=""
      BIND_DOCS="$(docs_root "$REPO_REAL")"
      # THE SAME CANONICALIZER `bind_plan` JUST USED (AC-23). This arm carried its own copy
      # of the resolve-the-directory rule and degraded to an EMPTY `BIND_REAL` when the
      # directory would not resolve — which then fell through the location `case` below and
      # was reported as "not a plan under this root", a sentence about the wrong thing: the
      # path may well be under this root, it is the directory above it that is missing.
      # `BIND_PATH` is absolute by construction above, which is what `_bind_resolve` requires.
      BIND_REAL=""
      BIND_RESOLVED=yes
      BIND_REAL="$(_bind_resolve "$BIND_PATH")" || { BIND_REAL=""; BIND_RESOLVED=no; }
      if [ -n "$BIND_MARKER" ] && [ -L "$BIND_MARKER" ]; then
        BIND_WHY="marker is a symlink"
      elif [ "$BIND_RESOLVED" = no ]; then
        BIND_WHY="its directory does not resolve"
      else
        # THE SAME DEPTH BOUND THE SET IS BUILT WITH (review D8c, S10b). `open_runs` walks
        # `find <plans|incidents> -maxdepth 2`, so `plans/<a>/<b>/x.md` is not a candidate
        # at all. A `case` glob matches across `/`, so the location test used to call that
        # file a plan of this root and blame its CONTENT ("not an open run") for a miss the
        # walk decided before ever opening it. `BIND_TAIL` is the path below `plans/` or
        # `incidents/`: no slash is depth 1, one slash is depth 2, two or more is outside.
        BIND_TAIL=""
        case "$BIND_REAL" in
          "$BIND_DOCS"/plans/*|"$BIND_DOCS"/incidents/*)
            BIND_TAIL="${BIND_REAL#"$BIND_DOCS"/}"
            BIND_TAIL="${BIND_TAIL#*/}" ;;
        esac
        case "$BIND_TAIL" in
          ''|*/*/*)
            # Outside the walk: not under a plan directory of this root, or nested deeper
            # than the walk reaches.
            BIND_WHY="not a plan under this root" ;;
          *)
            if [ -f "$BIND_PATH" ]; then
              BIND_WHY="not an open run"
            else
              BIND_WHY="not a plan under this root"
            fi ;;
        esac
      fi
      die "REFUSED — $BIND_WHY: $BIND_PATH"
      die "A binding names a member of this root's OPEN-RUN SET — a plan under"
      die "$BIND_DOCS/{plans,incidents} whose run is still open. This session's binding is unchanged."
      exit 1
    fi
    ;;

  tick)
    SESSION_ID="$(session_id)" || SESSION_ID=""
    if [ -z "$SESSION_ID" ]; then
      die "REFUSED — no session key (CLAUDE_CODE_SESSION_ID is unset or empty)."
      die "A tick answers for ONE session's roster, so without the key there is nothing to read."
      exit 3
    fi

    # ---------- THE ENGAGEMENT GUARD (AC-10): is this session bionic's at all? ----------
    #
    # BEFORE ANYTHING IS READ, DECIDED OR WRITTEN — above the stamp, above the roster,
    # above the sweeper. Chris, 2026-09-03: "all guardrails imposed by bionic should only
    # apply when exercising bionic. Nothing should apply until bionic is triggered" — and
    # the trigger is the canonical-sdlc skill, which writes
    # `.bionic/tmp/engaged-<sid>.state` at the instant it is invoked. The Patrol prompt
    # runs this verb, and a Patrol inherited by a session that never invoked the skill
    # must decide nothing about it rather than deciding wrongly.
    #
    # ONE LINE, EXIT 0, and not a refusal: the tick fired correctly and found nothing it
    # is entitled to judge. `arm` is deliberately not guarded (writing a stamp for a
    # session that asked for one is harmless) and neither is `disarm`, which removes the
    # stamp and leaves this marker exactly where it is — a session that invoked the skill
    # is bionic's for its whole life, so every hook still binds after a disarm (AC-15).
    # [WALL: tests/session-poker.test.sh]
    if ! engaged_session "$(project_root "$PWD")" "$SESSION_ID"; then
      say "NOT-ENGAGED — this session has not invoked /bionic:canonical-sdlc; nothing decided"
      exit 0
    fi

    # THE WALK, TAKEN BEFORE THE STAMP IS WRITTEN, and that ordering is load-bearing.
    # `write_patrol_stamp` mkdir -p's `<resolved root>/.bionic/tmp`, so a tick that resolved
    # the WRONG root creates a `.bionic` there as its first act — and every walk taken after
    # that point reports the root it just manufactured as `chosen`. Read here, the walk still
    # describes the filesystem the tick actually arrived in, which is the only version of it
    # an operator can act on and the one AC-38's two arms are told apart by.
    TICK_ROOT_WALK="$(project_root_candidates "$PWD")"
    TICK_ROOT_TAG="$(printf '%s\n' "$TICK_ROOT_WALK" | tail -1 | awk -F'\t' '{ print $2 }')"

    # STAMP FIRST, BEFORE ANYTHING IS READ OR DECIDED. Every line below this one can end in
    # a refusal, and each of those refusals is a HEALTHY Patrol firing into a state it has
    # nothing to say about. What the stamp attests is the firing, so it is taken here — the
    # first thing after the session key exists to name the file with.
    write_patrol_stamp "$SESSION_ID" tick \
      || die "WARN — the Patrol stamp could not be written; the tick itself is unaffected."

    # The sweeper is this script's sibling — same resolution as hooks/landing-gate.sh's.
    SWEEPER="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/session-sweeper.sh"
    if [ ! -f "$SWEEPER" ]; then
      die "REFUSED — sibling hooks/session-sweeper.sh not found; nothing was read."
      exit 2
    fi

    REPO="$(project_root "$PWD")"
    REPO_REAL="$(cd "$REPO" 2>/dev/null && pwd -P)"
    if [ -z "$REPO_REAL" ]; then
      die "REFUSED — cannot resolve the working directory."
      exit 2
    fi
    ROSTER_FILE="$REPO_REAL/.bionic/tmp/roster-${SESSION_ID}.state"

    # THE BLIND-WALL CHECK IS GONE (bionic 1.4.0, spec AC-7). It compared main-thread
    # `Agent` tool_uses in the transcript against rows on the roster and raised a NOTIFY
    # when dispatches outnumbered them, on the reasoning that the dispatch wall lived in
    # the governing skill's frontmatter and therefore died with a `/clear`, a continue or
    # a `/reload-plugins`. Every wall is registered in hooks/hooks.json now and survives
    # all three, so the condition it detected cannot arise the way it did — while its
    # false positive could and did: the check had no "no active run" branch, so a session
    # that had simply not engaged a run read as a session whose wall had died (observed
    # 20:07Z, 2026-09-02). A diagnosis for a failure mode the registration change removes,
    # firing on sessions that have nothing wrong with them, is worth less than nothing.

    # EXACTLY ONE verdict read over the whole roster (no name argument), run from the repo
    # root exactly as landing-gate.sh runs it. `|| exit 9` keeps a failed `cd` out of the
    # exit-1 band, which is NOTIFY's alone.
    VERDICT_OUT=$( cd "$REPO_REAL" 2>/dev/null || exit 9
                   CLAUDE_CODE_SESSION_ID="$SESSION_ID" bash "$SWEEPER" verdict 2>&1 )
    VERDICT_RC=$?
    if [ "$VERDICT_RC" -eq 9 ]; then
      die "REFUSED — could not enter $REPO_REAL to read the roster."
      exit 2
    fi
    # 2 (a refusal the sweeper itself raised — a symlinked roster or ledger) and 3 (no
    # session key, unreachable here since SESSION_ID was already checked) propagate
    # verbatim: a tick that cannot trust its one read has nothing to decide from.
    if [ "$VERDICT_RC" -eq 2 ] || [ "$VERDICT_RC" -eq 3 ]; then
      die "REFUSED — the verdict read did not complete: $VERDICT_OUT"
      exit "$VERDICT_RC"
    fi

    TOTAL=0; OPEN=0; NOTIFY_ROWS=""; NOTIFY_DETAIL=""
    # The names of the rows the verdict leaves open, kept so the live set can trim them
    # AFTER this walk rather than inside it: one transcript resolution per tick, not one
    # per row, and the roster count survives as its own number (S19).
    OPEN_NAMES=""
    while IFS= read -r LINE; do
      case "$LINE" in "landing-verdict/v1|"*) : ;; *) continue ;; esac
      TOTAL=$((TOTAL + 1))
      RNAME="$(line_field "$LINE" name)"
      RSTATE="$(line_field "$LINE" state)"

      # THE ACK CLOSES THE ROW HERE TOO, before the state is looked at at all: excluded from
      # OPEN and therefore from DISARM's precondition, and excluded from NOTIFY eligibility.
      # Read per row off the verdict line this loop is already walking — never from the
      # ledger, whose one owner is the verb that prints this line (hooks/session-sweeper.sh,
      # S9) — and spelled exactly as the three consumers that already read it:
      # hooks/landing-gate.sh:214, hooks/stop-orders.sh:319, hooks/stop-guard.sh:491.
      # This is what makes the ack verb's own closing sentence true —
      #   hooks/session-sweeper.sh:817 "an acked row is closed for every reader"
      # — which it was not while this script was the fourth reader that ignored the field
      # (cs review C-4, epic-16 w2 Step-6 remediation R4). Two structural consequences were
      # riding on the omission, both worse than the noise: an acked-UNMET row is never MET
      # and never WAIVED, and its artifact was accounted for by a human rather than written
      # to disk, so it held OPEN above zero PERMANENTLY and DISARM — the end of the
      # self-wake — was unreachable by the ordinary path that closes an artifact-less row;
      # and every tick re-notified the same closed work, growing the NOTIFY set
      # monotonically across a wave. AC-7's contract moves with this (assumption 41), which
      # is why tests/session-poker.test.sh §3 re-authors the accelerated-clock cases rather
      # than re-running them.
      #
      # TOTAL still counts an acked row: it is on the roster, and "how many contracts does
      # this session carry" is not the question the ack answers. Only `open=` moves.
      [ "$(line_field "$LINE" acked)" = "yes" ] && continue

      case "$RSTATE" in
        MET|WAIVED) : ;;                      # closed — not open
        *)          OPEN=$((OPEN + 1))        # STILL-LIVE, UNMET, AMBIGUOUS — open
                    OPEN_NAMES="${OPEN_NAMES}${RNAME}
" ;;
      esac
      [ "$RSTATE" = "UNMET" ] || continue

      # Duration is a SECOND, ADVISORY-ONLY read of this one row — never a re-judgment of
      # MET/UNMET, which stays verdict's alone. The roster is append-only; the last line
      # carrying this name is its latest contract, the same row verdict itself just folded.
      # Filtered to the roster-state/v1 schema FIRST (t6-review.md F-1): a landing-swept/v1
      # marker for this same name also carries `|name=<name>|` and is appended AFTER the
      # roster rows, so an unfiltered `tail -1` takes the marker instead — it has no
      # duration=/launched_at=, and the row's overdue NOTIFY goes silent for the rest of the
      # session. Same schema-prefix discipline as every other roster reader in the fleet
      # (e.g. hooks/execution-recorder.sh's `roster-state/${ROSTER_VERSION}|` filters).
      ROW_LINE="$(grep -F "roster-state/v1|" "$ROSTER_FILE" 2>/dev/null \
        | grep -F "|name=${RNAME}|" | tail -1)"
      [ -n "$ROW_LINE" ] || continue
      DUR_RAW="$(line_field "$ROW_LINE" duration)"
      LAUNCHED_RAW="$(line_field "$ROW_LINE" launched_at)"
      DUR_S="$(parse_seconds "$DUR_RAW")" || continue
      LE="$(iso_epoch "$LAUNCHED_RAW")"
      [ -n "$LE" ] || continue
      AGE=$(( $(now_epoch) - LE ))
      [ "$AGE" -gt "$DUR_S" ] || continue
      NOTIFY_ROWS="${NOTIFY_ROWS}${NOTIFY_ROWS:+,}$(clean "$RNAME")"
      NOTIFY_DETAIL="${NOTIFY_DETAIL}${NOTIFY_DETAIL:+; }$(clean "$RNAME"): $(line_field "$LINE" detail) (elapsed ${AGE}s past declared duration \"$DUR_RAW\" (${DUR_S}s))"
    done <<EOF
$VERDICT_OUT
EOF

    # ---------- THE LIVE SET TRIMS `open=` AND THE FILL (S19, auditor F-14) ----------
    #
    # THE DEFECT. The spec's ownership table names this tick a rendering surface of the LIVE
    # AGENT SET; it read no such thing. It counted roster rows by sweeper verdict, while the
    # dispatch wall counts a row open only while the harness still calls its agent live
    # (AC-27). One row, two answers: a finished-but-unstopped teammate is NOT open to the
    # wall and WAS open here, so the Patrol could print a FILL the wall was about to refuse
    # — or withhold one it would have allowed. The number below is now the wall's number,
    # because both sides ask the same function.
    #
    # THE TICK DECIDES AND NEVER WRITES. No roster row, marker or verdict moves here: the
    # row stays exactly as the sweeper left it, still counted in `total=`, still eligible to
    # NOTIFY when it is overdue. Only the arithmetic this tick prints is trimmed. That is
    # what keeps the roster readable by every other consumer (D0: one owner per liveness
    # truth, and the ROSTER's owner is not this file).
    #
    # ONLY WHEN THERE IS SOMETHING TO TRIM. A roster with no open row has nothing whose
    # openness a live answer could settle — the same reasoning the dispatch wall's empty-
    # roster arm takes — so the reader is not called and no line is printed. A fallback
    # sentence on every quiet tick of every session is noise a reader learns to skip.
    #
    # ON A STALE OR MISSING ANSWER THE ROSTER COUNT STANDS, and this is deliberately NOT
    # the wall's refuse-and-name-the-fix behaviour. The Patrol's prompt runs this tick
    # BEFORE any ListAgents, so a refusal here would refuse the first tick of every session
    # — a wall that fires on the healthy path is not a wall. The tick holds no authority
    # (ADR-003): it prints a line and the operator acts. The ENFORCEMENT is the dispatch
    # wall, which does refuse on a stale read, so the honest thing here is to say which
    # number this is and point at the gate that will insist.
    OPEN_ROSTER="$OPEN"
    TICK_LIVE_STATE=""
    if [ "$OPEN_ROSTER" -gt 0 ]; then
      TICK_TR="$(session_transcript "$SESSION_ID")" || TICK_TR=""
      if [ -z "$TICK_TR" ]; then
        TICK_LIVE_STATE="none"
      else
        TICK_OPEN_LIVE=0
        # PRIME THE READER'S PER-PROCESS PARSE, ONCE, IN THIS SHELL (Step-6 review P-4, the
        # tick half of the finding the budget wall's loop already answers). `live_agents`
        # memoizes its parse in shell variables keyed on the transcript's path, size and
        # mtime — but the per-row call below runs inside a command substitution, and a
        # subshell INHERITS its parent's variables while its own writes die with it. So the
        # first row would warm a cache nobody sees and every open row would pay a full
        # parse: two whole-file `jq` passes and nine spawns. Measured on this machine, one
        # tick over twelve open rows and a 4.1 MB transcript ran jq 24 times.
        #
        # IT ALSO WARMS `youngest_suite_writer` (the EMERGENCY arm below), which asks the
        # same predicate per candidate row inside its own substitution — a subshell of this
        # one, so it inherits what is cached here and adds no parse of its own.
        #
        # LAZILY, INSIDE THE `OPEN_ROSTER > 0` ARM, for the same reason the wall does it
        # lazily: a roster with nothing open reads the transcript zero times. Its answer is
        # discarded — this line is a cache fill, and every row's verdict is the predicate's.
        live_agents "$TICK_TR" >/dev/null 2>&1 || :
        while IFS= read -r TICK_NAME; do
          [ -n "$TICK_NAME" ] || continue
          # The predicate prints nothing on stdout, so this capture is the reader's one
          # contract line — `live-agents: <state> age=<n|none>` — and nothing else.
          TICK_LRC=0
          TICK_LERR=$( { live_row_open "$TICK_TR" "$TICK_NAME"; } 2>&1 ) || TICK_LRC=$?
          case "$TICK_LRC" in
            0) TICK_OPEN_LIVE=$(( TICK_OPEN_LIVE + 1 )) ;;
            1) : ;;
            *) # 3 STALE / 4 NONE. Freshness is a property of the TRANSCRIPT, not of any
               # one name, so every remaining row would read the same way: stop asking.
               TICK_LIVE_STATE="${TICK_LERR#live-agents: }"
               TICK_LIVE_STATE="${TICK_LIVE_STATE%% *}"
               break ;;
          esac
        done <<EOF
$OPEN_NAMES
EOF
        [ -n "$TICK_LIVE_STATE" ] || OPEN="$TICK_OPEN_LIVE"
      fi
      if [ -n "$TICK_LIVE_STATE" ]; then
        say "live set $TICK_LIVE_STATE — open= counted from the roster; ListAgents before any dispatch"
      elif [ "$OPEN" -ne "$OPEN_ROSTER" ]; then
        # THE TRIM IS SAID OUT LOUD, or `open=0` over a roster carrying two unmet
        # contracts is a number with no story. Only when it actually moved: a tick whose
        # live set agrees with its roster has nothing to explain.
        say "live set fresh — ${OPEN_ROSTER} open row(s) on this roster, ${OPEN} still live; open= and any fill are sized from the live set"
      fi
    fi

    # "No roster" and "empty roster" are different facts, and only the latter may DISARM
    # (ap review A-1, item 2). A roster with zero verdict lines because the file plain does
    # not exist is indistinguishable, from the arithmetic alone, from a roster that exists
    # and legitimately has nothing open yet — but the first case is usually the wrong project
    # root having been resolved, and DISARM is silent and terminal for the rest of the
    # session (doctrine, skills/canonical-sdlc/SKILL.md §Dispatch: "DISARM also ends the
    # Patrol"). Checked only on the TOTAL=0 path: any row at all on the roster proves the
    # file exists, so OPEN=0-with-TOTAL>0 can never be the absent-file case.
    if [ "$TOTAL" -eq 0 ] && [ ! -e "$ROSTER_FILE" ]; then
      # AC-38 (fold-in ratified 2026-09-03): THE ARM SPLITS. "No roster" was one refusal
      # covering two states that deserve opposite answers, and the wrong one was observed on
      # this wave's own Patrol tick #1 — an orchestrator that had armed at engagement, was
      # standing in the right project, and had simply not dispatched anything yet got
      # REFUSED with a wall of candidate paths describing a root that was perfectly correct.
      # Arming precedes dispatch by design (SKILL.md §Dispatch: "arm at engagement"), so the
      # first tick of every run reaches this line, and answering it with a refusal teaches
      # the reader to ignore the one message that also reports a mis-resolved root.
      #
      # THE TWO STATES, and the fact that tells them apart:
      #   armed here, and the walk CHOSE a real `.bionic`  -> QUIET. The Patrol is doing its
      #     job; there is simply nothing on the roster yet. Exit 0, stamp kept (it was
      #     written above), one line, and no candidate walk — the root is not in doubt.
      #   anything else                                     -> the refusal below, unchanged.
      #
      # THE ARMING RECORD IS THE LOAD-BEARING HALF. It is written only by `arm`, and its
      # path is resolved against the SAME root the roster's is, so a tick that resolved the
      # wrong root finds no arming record there either and refuses — which is exactly the
      # failure the refusal exists to report. The root tag is the second guard, and it is
      # read off the walk taken ABOVE the stamp write for the reason given there.
      TICK_ARMED="$(patrol_armed_file "$SESSION_ID")" || TICK_ARMED=""
      if [ -n "$TICK_ARMED" ] && [ -f "$TICK_ARMED" ] && [ ! -L "$TICK_ARMED" ] \
         && [ "$TICK_ROOT_TAG" = "chosen" ]; then
        # THE RUNG, BEFORE THE DECISION LINE, exactly as the scheduler block prints it below
        # (AC-17: on EVERY tick). This is the first tick of every run — arming precedes
        # dispatch by design — so it is also the tick where the width the machine will carry
        # is most worth knowing, right before the batch that has not been sent yet.
        rung_report "$REPO_REAL" "$SESSION_ID"
        printf '%s|at=%s|session=%s|decision=QUIET|total=%s|open=%s\n' \
          "$POKER_DECISION_SCHEMA" "$(iso_now)" "$SESSION_ID" "$TOTAL" "$OPEN"
        say "QUIET — armed, nothing dispatched yet on this session"
        exit 0
      fi
      die "REFUSED — no roster at $ROSTER_FILE; this is not the same as an empty one."
      die "An armed session with nothing dispatched yet is QUIET, and was answered above — so"
      die "reaching this line means the Patrol never armed here, or the wrong project root was"
      die "resolved. Either way nothing was read to decide DISARM from, and DISARM ends the"
      die "Patrol for the rest of this session."
      # THE WALK, SHOWN (2.4, AC-13). The sentence above names the likely cause and then
      # leaves the reader with the one question they cannot answer from a message: WHICH
      # ancestor was taken, and what was passed over to get there. That answer is a property
      # of the filesystem above their cwd, so it is printed rather than described —
      # `project_root_candidates` is the same walk `project_root` just took, one line per
      # ancestor with the reason it was rejected, and the chosen one marked. A phantom
      # `.bionic` nested under a project, a symlinked one, a `.bionic` that only exists
      # inside $HOME: each shows up as its own line with its own tag.
      die "The root came from this walk over the ancestors of $PWD (path, then verdict):"
      printf '%s\n' "$TICK_ROOT_WALK" | while IFS= read -r ROOT_CAND; do
        die "  $ROOT_CAND"
      done
      exit 2
    fi

    # THE RUN-STATE READ, taken only where it can change the answer. `TOTAL == 0` implies
    # `OPEN == 0` — the loop that raises OPEN is the loop that raises TOTAL — so this single
    # test covers both arms of the old predicate, and a roster with open work never pays for
    # a find over the docs tree.
    RUN_STATE=open
    RUN_STATE_WHY="the roster still carries open work"
    # THE TERMINAL DECISION KEEPS THE ROSTER'S COUNT, never the live set's (S19). DISARM
    # removes the stamp and ends the Patrol for the rest of the session, and the state it
    # would fire on here is precisely the one that most needs supervising: a row whose
    # contract is UNMET and whose agent has finished without delivering. `open=` and the
    # fill are advisory arithmetic and may be trimmed; this may not.
    if [ "$OPEN_ROSTER" -eq 0 ]; then
      RUN_STATE_RAW="$(run_state "$REPO_REAL" "$(patrol_armed_file "$SESSION_ID")" "$SESSION_ID")"
      RUN_STATE="${RUN_STATE_RAW%%|*}"
      RUN_STATE_WHY="${RUN_STATE_RAW#*|}"
    fi

    # DISARM — no open row AND a run that says it is delivered, in a delivery that POSTDATES
    # this Patrol's arming (R-13: an older one is the previous run's close-out, still newest
    # while the new run's plan does not exist yet). "No open row" alone was the whole
    # predicate until 1.3.2, and it is also exactly what a live wave looks like between two
    # batches: every writer of a slice landed, the next not yet briefed. The tick ended the
    # Patrol there, terminally, and the rest of the wave ran unsupervised (epic-20 W1
    # dogfood, idea §B-4; R-4, AC-13/AC-14). The first conjunct still generalizes the spec's
    # literal "disarmed on empty roster" to a roster whose every row is MET/WAIVED/acked (S2
    # design decision, logged to the plan); the second is what tells a finish from a lull.
    #
    # An empty roster on a run that has not delivered falls through to QUIET below, and QUIET
    # KEEPS THE STAMP — which is the half that matters on disk. The clock keeps running, the
    # arming wall stays satisfied, and hooks/patrol-revive.sh has nothing to report.
    if [ "$OPEN_ROSTER" -eq 0 ] && [ "$RUN_STATE" = delivered ]; then
      # THE RUNG ON THE TERMINAL TICK TOO (AC-17). The number is moot to a Patrol that is
      # stopping, and that is not the point: the acceptance criterion is that every tick
      # reports it, and an operator reading the last tick of a run in a transcript should not
      # have to know which arm printed the line and which did not.
      rung_report "$REPO_REAL" "$SESSION_ID"
      printf '%s|at=%s|session=%s|decision=DISARM|total=%s|open=%s\n' \
        "$POKER_DECISION_SCHEMA" "$(iso_now)" "$SESSION_ID" "$TOTAL" "$OPEN"
      say "DISARM — no open row on this roster and the run is delivered (${RUN_STATE_WHY}); the Patrol may stop."
      # THE LAST ACT OF A DISARM TICK. The decision is terminal — "the Patrol may stop" —
      # so the stamp this very tick wrote before it decided has to stop claiming a live
      # clock, or hooks/patrol-revive.sh reads the stop this line just chose as a death and
      # blocks every remaining turn of the session demanding a re-arm nobody wants (critic
      # C-2, epic-19 w1). It is LAST so that nothing above it can be skipped by it: the
      # decision line is already printed, and a removal that fails costs a late notice
      # rather than a lost decision.
      remove_patrol_stamp "$SESSION_ID" \
        || die "WARN — the Patrol stamp could not be removed; the death notice may fire on later turns."
      exit 0
    fi

    # ─────────────────────────────────────── the lease overrun (spec AC-28)
    #
    # A spawned worktree is a leased slot bound to the ledger row that dispatched its
    # writer, and the lease ends when that row is fact-discharged (design ledger C1). A tree
    # still standing after that is a slot counted against the worktree budget that nobody
    # holds — and nothing else in the fleet walks `.worktrees` against the roster, so it
    # stays invisible until someone runs out of budget.
    #
    # READ OFF THE VERDICT THIS TICK ALREADY TOOK. `$VERDICT_OUT` is one
    # `session-sweeper.sh verdict` over the whole roster, and it is where the discharge
    # vocabulary lives: `state=MET`/`WAIVED`, and the `acked=` the sweeper folds in from its
    # own ledger. A roster read on its own would miss every acked row. The library takes a
    # FILE, so the lines this tick is already holding are spilled to a temporary one and
    # removed again — never into `.bionic/tmp`, which is state the operator reads.
    #
    # THE CONVENTION AND THE PREDICATE ARE THE LIBRARY'S, not a second copy here:
    # `.worktrees/<dir>` belongs to the row named `W-<DIR>` uppercased, and "discharged"
    # means acked or MET/CLOSED/WAIVED. Three callers share that definition
    # (payload/scripts/lib/worktree.sh's header names them); this is the third.
    #
    # PLACED AFTER DISARM, BEFORE THE SCHEDULER. A run that has DELIVERED exits above, and
    # its standing trees are the integration step's assertion to make rather than a Patrol
    # line nobody is left to read.
    #
    # IT REMOVES NOTHING. `spawn-worktree.sh land` is the act and the orchestrator runs it;
    # the tick says the tree is standing and stops there.
    LEASE_ROWS=""; LEASE_DETAIL=""
    LEASE_FILE="$(mktemp "${TMPDIR:-/tmp}/bionic-poker-verdict.XXXXXX" 2>/dev/null)" || LEASE_FILE=""
    if [ -n "$LEASE_FILE" ]; then
      printf '%s\n' "$VERDICT_OUT" > "$LEASE_FILE" 2>/dev/null
      while IFS= read -r LEASE_LINE; do
        [ -n "$LEASE_LINE" ] || continue
        LEASE_PATH="$(printf '%s' "$LEASE_LINE" | cut -f1)"
        LEASE_ROW="$(printf '%s' "$LEASE_LINE" | cut -f2)"
        [ -n "$LEASE_PATH" ] && [ -n "$LEASE_ROW" ] || continue
        say "NOTIFY lease-overrun $LEASE_PATH row=$LEASE_ROW"
        LEASE_ROWS="${LEASE_ROWS}${LEASE_ROWS:+,}$(clean "$LEASE_ROW")"
        LEASE_DETAIL="${LEASE_DETAIL}${LEASE_DETAIL:+; }$(clean "$LEASE_ROW"): lease-overrun, $(clean "$LEASE_PATH") still stands after the row was discharged"
      done <<EOF
$(worktree_lease_overruns "$REPO_REAL" "$LEASE_FILE")
EOF
      rm -f "$LEASE_FILE" 2>/dev/null || :
    else
      die "WARN — no temporary file for the lease walk; standing worktrees were not checked."
    fi

    # ─────────────────────────────────────── the scheduler: pressure, then fills
    #
    # PLACED HERE, after DISARM and before NOTIFY/QUIET, and the placement is the contract.
    # DISARM exits above: a run that has DELIVERED gets no fills, because there is nothing
    # left to fill. Everything else — a live wave, a lull between batches, a roster with an
    # overdue row — gets both the pressure reading and the fill decision, and then the
    # decision line it was already going to get. A tick that filled instead of notifying
    # would trade a report the operator asked for against one they did not.
    #
    # PRESSURE FIRST, ALWAYS. See the block comment above `space_field` for why the order is
    # not negotiable and why nothing here re-derives the budget.
    SCHED_CORES="$(space_field "$(resources_probe)" cores)"
    case "${SCHED_CORES:-}" in ''|*[!0-9]*) SCHED_CORES=1 ;; esac
    [ "$SCHED_CORES" -ge 1 ] || SCHED_CORES=1
    SCHED_PRESSURE="$(resources_pressure "$SCHED_CORES" 2>/dev/null)" || SCHED_PRESSURE=""
    SCHED_STATE="$(space_field "$SCHED_PRESSURE" state)"
    SCHED_FREE="$(space_field "$SCHED_PRESSURE" free_mb)"
    SCHED_LOAD="$(space_field "$SCHED_PRESSURE" load_1m)"
    # A pressure read that will not parse is not an emergency and not a hold: it is a
    # reading this tick does not have, and the fill decision proceeds on the budget alone.
    # Refusing to fill on an unreadable probe would let one broken `vm_stat` stall a wave.
    case "${SCHED_STATE:-}" in ok|hold|emergency) : ;; *) SCHED_STATE=ok ;; esac

    # The plan and its budget, read once. Both may be absent — a project with no plan, or a
    # plan written before Step 0 ever probed — and absence is INERT: the tick says why it is
    # not filling and fills nothing, exactly as the dispatch wall's budget arm goes inert on
    # the same missing line. A budget is a ceiling a run opts into.
    #
    # THE SAME RUN THE DECISION ABOVE WAS TAKEN ON. `resolve_run` answers once per tick, so
    # a session bound to its own plan fills from its own slice table and quotes its own
    # ceiling — a tick that stood its ground correctly and then filled the neighbour's
    # slices would be worse than either failure alone (AC-1).
    sched_budget_read "$REPO_REAL" "$SESSION_ID"

    if [ "$SCHED_STATE" = emergency ]; then
      # THE KILL FLOOR. The tick NAMES the writer and stops nothing itself: stopping a
      # writer destroys work, and an irreversible act taken by a hook off a single reading
      # is the one thing this design refuses (design-ledger S7). The orchestrator executes
      # it through the stopping standard, which is why the line carries the address that
      # standard takes rather than a name.
      SCHED_TARGET="$(youngest_suite_writer "$ROSTER_FILE" "$SESSION_ID")"
      if [ -n "$SCHED_TARGET" ]; then
        say "EMERGENCY free_mb=${SCHED_FREE} — stop youngest suite-running writer ${SCHED_TARGET}"
      else
        say "EMERGENCY free_mb=${SCHED_FREE} — no suite-running writer on this roster to stop; the pressure is not this session's to relieve"
      fi
    fi

    # THE REPORT, AND THE CEILINGS IT IS TAKEN AGAINST — both in `rung_report` above, which
    # the two arms that exit ABOVE this block call for themselves (AC-17, Step-6 review C-5).
    # The budget read is memoized, so reaching it a second time here costs one plan read.
    rung_report "$REPO_REAL" "$SESSION_ID"

    if [ "$SCHED_STATE" = hold ] || [ "$SCHED_STATE" = emergency ]; then
      # HOLD AND EMERGENCY ARE ADVICE TO THE MODEL, and that is all they have ever been.
      # They keep their meaning here: a measurement, a verdict, and no fills this tick.
      # What they no longer do is accumulate — the counter that made a second consecutive
      # hold mean something was the scheduler's only cross-tick state, and the rung above
      # answers the width question from the ring instead.
      [ "$SCHED_STATE" = hold ] && \
        say "HOLD free_mb=${SCHED_FREE} load_1m=${SCHED_LOAD} — no fills"
    else
      # ── FILL. gap = the RUNG − RUNNING, ready = pending slices whose deps all landed.
      #
      # RUNNING IS `open` (WALLS/2): the rows already counted above, on THIS session's
      # roster — a `status=intended` row with no `landing-swept/v1` marker and no ack. It is
      # the loop's own count rather than a second walk, because two definitions of "running"
      # in one file is the drift the count exists to prevent.
      #
      # THE APPROVAL GATE COMES FIRST, ahead of the budget/readiness checks below (AC-5). A
      # plan below `current: 4` has not passed Step 3, and no reading of the budget or the
      # slice table changes that — so this is a wall in front of the rest of the arm, not one
      # more branch beside them.
      #
      # AN UNREADABLE `current:` WITHHOLDS TOO, UNCONDITIONALLY (Step-6 review-a C-5,
      # review-b finding (c)/N-2). A task-scale `current: T<n>` (no numbered step to compare
      # against 4), an empty field, or a line that will not parse are all cases where this
      # gate cannot tell whether Step 3 has passed — and falling through to the
      # readiness/budget checks below on THAT basis is DOUBT-then-FILL: the one shape this
      # arm exists to prevent, measured live on a plan whose `current:` carried a sub-step
      # letter (`3b`) that the old digit-only read rejected as unreadable and then filled
      # anyway. So this differs from an unreadable RUNG, which falls back to the ceiling —
      # there is no safe fallback for "did Step 3 pass," only "no."
      SCHED_CURRENT=""
      [ -n "$SCHED_PLAN" ] && SCHED_CURRENT="$(sched_plan_current "$SCHED_PLAN")"
      if [ -n "$SCHED_PLAN" ] && [ -z "$SCHED_CURRENT" ]; then
        SCHED_CURRENT_RAW="$(_sched_plan_current_field "$SCHED_PLAN")"
        say "no FILL — plan current: unreadable (${SCHED_CURRENT_RAW:-none})"
      elif [ -n "$SCHED_CURRENT" ] && [ "$SCHED_CURRENT" -lt 4 ]; then
        say "no FILL — plan at current: ${SCHED_CURRENT}, Step-3 approval pending"
      elif [ -z "$SCHED_WRITERS" ]; then
        if [ -z "$SCHED_PLAN" ]; then
          say "no FILL — no plan carrying an unfenced \"## SDLC State\" to read a budget or a slice table from."
        else
          say "no FILL — ${SCHED_PLAN} carries no readable parallel-budget: writers field in its frontmatter; a budget is a ceiling a run opts into."
        fi
      else
        # THE GAP IS MEASURED AGAINST THE RUNG, NOT THE CEILING (AC-17). The ceiling is what
        # the run may ever run at; the rung is what the machine will carry right now, and
        # filling to the first while the second says otherwise is the mistake this whole arm
        # exists to prevent. An unreadable rung falls back to the CEILING rather than to a
        # floor — the same direction `pressure_level` itself takes when the ring holds no
        # usable evidence, for the same reason: no reading is not a bad reading, and a wave
        # that stalled on a missing probe would be worse than one that filled its budget.
        SCHED_WIDTH="${SCHED_RUNG:-$SCHED_WRITERS}"
        SCHED_GAP=$(( SCHED_WIDTH - OPEN ))
        [ "$SCHED_GAP" -lt 0 ] && SCHED_GAP=0
        if [ "$SCHED_GAP" -eq 0 ]; then
          say "no FILL — rung=${SCHED_RUNG:--} of writers=${SCHED_WRITERS} and ${OPEN} open row(s): the budget is full."
        else
          SCHED_READY="$(slice_ready "$(slice_table "$SCHED_PLAN")")"
          SCHED_IDS=""; SCHED_N=0
          while IFS= read -r SLICE_ID; do
            [ -n "$SLICE_ID" ] || continue
            [ "$SCHED_N" -lt "$SCHED_GAP" ] || break
            SCHED_IDS="${SCHED_IDS}${SCHED_IDS:+ }$(clean "$SLICE_ID")"
            SCHED_N=$((SCHED_N + 1))
          done <<EOF
$SCHED_READY
EOF
          if [ "$SCHED_N" -gt 0 ]; then
            say "FILL ${SCHED_IDS}"
          else
            say "no FILL — rung=${SCHED_RUNG:--} of writers=${SCHED_WRITERS} open=${OPEN} gap=${SCHED_GAP}, and no pending slice has all its dependencies landed."
          fi
        fi
      fi
    fi

    # ONE NOTIFY BAND, TWO CONTRIBUTORS. An overdue row and a standing lease are both
    # "something needs surfacing", and the exit-1 band is what the Patrol's prompt reads;
    # a lease overrun that decided QUIET would print a line and then tell the reader
    # nothing was wrong. The rows and the details are concatenated rather than given a
    # field of their own, so no consumer of this schema has to learn a new key to see them.
    if [ -n "$NOTIFY_ROWS" ] || [ -n "$LEASE_ROWS" ]; then
      printf '%s|at=%s|session=%s|decision=NOTIFY|total=%s|open=%s|rows=%s|detail=%s\n' \
        "$POKER_DECISION_SCHEMA" "$(iso_now)" "$SESSION_ID" "$TOTAL" "$OPEN" \
        "${NOTIFY_ROWS}${NOTIFY_ROWS:+${LEASE_ROWS:+,}}${LEASE_ROWS}" \
        "$(clean "${NOTIFY_DETAIL}${NOTIFY_DETAIL:+${LEASE_DETAIL:+; }}${LEASE_DETAIL}")"
      # The lease lines were said where they were found; only the duration half needs a
      # sentence here, and a tick that has only the other half must not print an empty one.
      [ -n "$NOTIFY_DETAIL" ] && say "NOTIFY — past declared duration: $NOTIFY_DETAIL"
      exit 1
    fi

    printf '%s|at=%s|session=%s|decision=QUIET|total=%s|open=%s\n' \
      "$POKER_DECISION_SCHEMA" "$(iso_now)" "$SESSION_ID" "$TOTAL" "$OPEN"
    # THE QUIET LINE HAS TWO READINGS NOW, and printing the wrong one is how this fix would
    # be mistaken for the bug it repairs. "0 open row(s), none past their declared duration"
    # over a mid-run lull says nothing about why the Patrol did not stop, and its reader is a
    # model deciding whether the Patrol is broken. So the empty-roster reading names the run
    # state it decided from — which plan, and where that plan says the run is.
    # KEYED ON THE ROSTER'S COUNT, not the live one (S19). `RUN_STATE_WHY` is read only on
    # the empty-roster path above, and — more to the point — "no open row on this roster" is
    # a statement about the roster, which a liveness reading does not get to make false. The
    # live number is `open=` on the decision line, and the trim line above says so
    # whenever the two differ.
    if [ "$OPEN_ROSTER" -eq 0 ]; then
      say "QUIET — no open row on this roster, but the run is not delivered (${RUN_STATE_WHY}); the Patrol keeps its stamp and its clock."
    else
      say "QUIET — $OPEN_ROSTER open row(s) on this roster, none past their declared duration."
    fi
    exit 0
    ;;
esac
