#!/bin/bash
# THE PLUGIN-CHANNEL PARTITION GUARD — session-20260815-landing-supervision, T6.
#
# It stands in hooks/hooks.json — four entries, one per event that needs it — in
# front of a wall that is ALREADY registered on the skill channel, and its whole job
# is to make sure exactly one of those two registrations is ever live for a given
# event:
#
#     hooks.json     ->  this guard  ->  exec the real wall   (agent contexts only)
#     SKILL.md hooks ->  the real wall                        (main thread, unchanged)
#
# (Historically that first lane was the CLI's own settings.json, which is how this
# file was written and named; the epic-17 plugin conversion moved every always-on
# registration into the payload's hooks.json and nothing on that channel is read out
# of settings.json any more.)
#
# WHY A SECOND CHANNEL AT ALL. The skill-frontmatter channel is looked up by SESSION
# key, and a tool-class event raised inside a teammate or subagent context is
# dispatched under the AGENT key — so `PreToolUse|Write`, `PreToolUse|Agent` and
# their PostToolUse twins never reach a skill-registered hook from inside an agent.
# Measured, both directions, with a same-session main-thread positive control:
# .bionic/docs/record/session-20260815-landing-supervision/t1-probe-report.md §3
# (CLI 2.1.233). Every wall this repo has ever installed therefore stopped at depth
# one, and delegating was enough to escape it. The plugin channel IS alive in
# those contexts, which is what this file makes usable.
#
# WHY THE GUARD CANNOT LIVE INSIDE THE WALL. The plugin channel is alive on the
# main thread too, and in every session that mounts the plugin including the ones
# that never invoked the governing skill. A wall invoked through it cannot tell which
# channel called it — same script, same payload — so a guard written into the wall
# would answer the same way on both, and the only predicate that silences the
# plugin channel on a main-thread event (no top-level `agent_id`) would silence
# the skill channel there too, disarming main-thread coverage outright. The guard
# has to be the thing the channel points AT, and nothing else can be.
#
# THE PARTITION (design D1, ratified 2026-08-15; plan AC-8). Run the wall iff:
#
#   1. the payload carries a top-level `agent_id`      — this is an agent context.
#      Main-thread payloads have no such field (t1 §3, `ctx = .agent_id // "MAIN"`).
#   2. `.bionic/tmp/roster-<session_id>.state` exists   — this session is armed.
#      The roster is written by the dispatch wall on the SKILL channel, so it
#      provably precedes any agent context: a teammate exists only after a
#      main-thread dispatch, and that dispatch is what writes the file. An
#      unarmed session therefore fails this check on one stat and pays nothing
#      else, which is what keeps an always-on hooks.json registration from
#      re-globalising walls that were deliberately made skill-scoped.
#
# Anything else — ambiguity included — exits 0 in silence. This guard never
# refuses on its own account and never prints: a refusal here would be a wall
# nobody wrote, and a message here would be attributed to the wall behind it.
#
# THE WALL BEHIND IT IS NAMED BY ARGUMENT, one guard for every wall, because the
# partition is a single fact about a channel rather than a property of any one
# wall. A second copy of this predicate — one per wall, or one per script — is the
# twin the design rejected by name.
#
# THE LEDGER DOES NOT TRAVEL WITH THE WALL. Walls are read-and-refuse predicates
# and cost nothing at depth; writers stay at depth one (the governing principle,
# "distribute the reads, centralize the writes"). hooks/dispatch-preflight.sh is
# both, so this guard hands it BIONIC_HOOK_CHANNEL=agent-context and that script
# skips its roster append alone — a nested dispatch is refused or passed by the
# wall, and never rostered.
#
# Exit code 2 (from the wall behind it) = block the tool call entirely.
# [WALL: tests/agent-context-guard.test.sh]
#
# Registered always-on in hooks/hooks.json, in front of the wall named by its argument.

set -uo pipefail

# ---------- the wall this invocation guards ----------
#
# `~` is expanded by the shell that runs the hooks.json command string, so the
# argument normally arrives absolute; the expansion below only covers a literal
# tilde surviving an exotic invocation. A target that is missing or unnamed is a
# misconfiguration, and a misconfigured guard passes the tool call through rather
# than blocking work on its own confusion.
TARGET="${1:-}"
[ -n "$TARGET" ] || exit 0
case "$TARGET" in '~/'*) TARGET="$HOME/${TARGET#\~/}" ;; esac
[ -f "$TARGET" ] || exit 0

INPUT=$(cat)
_jq() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }

# ---------- 1. is this an agent context? ----------
# The cheapest question, asked first and with no filesystem behind it: every
# main-thread tool call on this machine — armed or not — leaves here.
[ -n "$(_jq '.agent_id')" ] || exit 0

# ---------- 2. is this session armed? ----------
PAYLOAD_SID=$(_jq '.session_id')
CWD=$(_jq '.cwd')
[ -n "$CWD" ] || exit 0

# ---------- the library ----------
#
# One loader idiom, byte-identical in every hook (spec AC-16). FAIL OPEN: this guard
# decides whether a wall RUNS, and a guard that refused when it could not load would
# take every wall behind it down with it in every session on the machine.
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
if [ -n "$BIONIC_LIB_MISSING" ]; then loader_fail_open "agent-context-guard"; fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/root.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/run.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/session.sh"

# THE SESSION ID (design §1): the environment value is primary, the payload a witness.
# The roster filename is built from it, so this guard and the wall behind it have to
# key on the same one — a guard reading the payload while the wall read the
# environment would answer "unarmed" for the roster the wall had just written.
PAYLOAD_SID=$(session_id "$PAYLOAD_SID" 2>/dev/null) || PAYLOAD_SID=""
[ -n "$PAYLOAD_SID" ] || exit 0
# The same belt hooks/dispatch-preflight.sh wears on the same value, in the same
# direction: the roster path is built by interpolating this key, so a key carrying
# a path separator addresses a file outside the state directory entirely.
case "$PAYLOAD_SID" in *[!A-Za-z0-9_-]*) exit 0 ;; esac

# THE ROOT (spec AC-10). This guard must land on the same `.bionic` the dispatch wall
# wrote the roster into, or it answers "unarmed" from a worktree of an armed session —
# a wall that goes quiet exactly where it was added to bind.
REPO=$(project_root "$CWD")
[ -n "$REPO" ] && [ -d "$REPO" ] || exit 0

# ---------- THE ENGAGEMENT GUARD (AC-20): is this session bionic's at all? ----------
#
# FIRST, above every other scoping question this hook asks. Chris, 2026-09-03: "all
# guardrails imposed by bionic should only apply when exercising bionic. Nothing should
# apply until bionic is triggered" — and the trigger is the canonical-sdlc skill, which
# writes `.bionic/tmp/engaged-<sid>.state` at the instant it is invoked. A session that
# never invoked it is one this hook has nothing to say to, and it says nothing: exit 0,
# no stdout, no stderr.
#
# EVERY UNREADABLE STATE READS AS NOT ENGAGED — absent marker, a symlink at the path, a
# foreign or unshaped session key, no key at all. The marker is the one artifact whose
# PRESENCE opens a wall, so the fail direction is inverted here on purpose: the arming
# partition is the consent boundary (1.3.2 close-out), and a wall that binds a session
# which never consented is the defect this guard exists to remove.
# [WALL: tests/agent-context-guard.test.sh]
engaged_session "$REPO" "$PAYLOAD_SID" || exit 0

# A symlink anywhere on the arming path is not followed, the same three levels the
# attestation gets in hooks/dispatch-preflight.sh. The stakes are lower here — the
# only thing a planted roster can do is make a wall RUN — but a repo pointing this
# guard at another tree's arming fact is still a repo deciding which session it
# belongs to, and the answer is cheap.
[ ! -L "$REPO/.bionic" ] && [ ! -L "$REPO/.bionic/tmp" ] || exit 0
ROSTER_FILE="$REPO/.bionic/tmp/roster-${PAYLOAD_SID}.state"
[ ! -L "$ROSTER_FILE" ] && [ -f "$ROSTER_FILE" ] || exit 0

# ---------- both true: hand the payload to the wall ----------
#
# The payload goes back in on stdin exactly as it arrived, and the wall's exit
# status is this guard's — a refusal must reach the harness as the wall's own 2,
# with the wall's own words already on stderr.
printf '%s' "$INPUT" | BIONIC_HOOK_CHANNEL=agent-context bash "$TARGET"
exit $?
