#!/bin/bash
# ENGAGE: the one act that puts a session inside bionic.
#
# task-engaged-session (Chris, 2026-09-03): "all guardrails imposed by bionic should only
# apply when exercising bionic. Nothing should apply until bionic is triggered" — and the
# trigger is the canonical-sdlc skill, nothing else. 1.4.0 shipped walls scoped by
# `active_run <repo>` alone, so any session in a repo with an open plan was walled and told
# to arm a Patrol it never asked for. This hook records the entry, mechanically, at the
# instant the skill is invoked; every other bionic hook asks `engaged_session` before it
# asks anything else.
#
# TWO PATHS, because invocation has two shapes and only one of them is a tool call:
#   PreToolUse / tool_name "Skill" / tool_input.skill   the model-invoked path
#   UserPromptExpansion / command_name                  the user-typed slash-command path
# A typed `/bionic:canonical-sdlc` is NOT a Skill tool call and NOT a plain
# UserPromptSubmit prompt (measured across every transcript on this machine,
# record/task-engaged-session/research-callsites.md §5.2): it reaches the model as a
# `<command-message>` wrapper, so a prompt-prefix test would never match it. The harness
# fires UserPromptExpansion for exactly that expansion, with the command name as a
# first-class field (docs: "UserPromptExpansion | command name | your skill or command
# names"). Both spellings of the name are accepted, qualified and bare, with or without
# the leading slash the typed form carries.
#
# THE FAIL DIRECTION IS INVERTED HERE, deliberately, and it is the only place in this tree
# where it is. Everywhere else an unreadable state CLOSES a wall; the marker this writes is
# the one artifact whose PRESENCE opens them. So every doubt resolves to NOT engaging: a
# name that is not exactly canonical-sdlc, a root that will not resolve, a session id that
# is empty or misshapen, a symlink anywhere on the path. The cost of not engaging is one
# more invocation; the cost of engaging wrongly is every wall in the fleet binding a
# session that never consented, which is the bug this exists to fix.
#
# IT NEVER BLOCKS AND NEVER SPEAKS ON SUCCESS. Exit is 0 on every path — a trigger that
# could refuse the skill it exists to notice would be a wall in front of the front door.
# Registered twice in hooks/hooks.json.
#
# [WALL: tests/engage.test.sh]

set -u

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat)

_jq() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }

# ---------- IS THIS THE TRIGGER? ----------
#
# Asked before anything else is read, and before a single byte is written anywhere: this
# hook is delivered on every Skill call and every command expansion in every project on
# the machine, and for all but one name it must cost nothing and do nothing.
NAME=""
case "$(_jq '.hook_event_name')" in
  PreToolUse)
    [ "$(_jq '.tool_name')" = "Skill" ] || exit 0
    NAME=$(_jq '.tool_input.skill')
    ;;
  UserPromptExpansion)
    NAME=$(_jq '.command_name')
    ;;
  *) exit 0 ;;
esac

# `^(bionic:)?canonical-sdlc$`, anchored at both ends, plus the leading slash the typed
# form may carry. `canonical-sdlc-notes` and `other:canonical-sdlc` are not this skill.
case "${NAME#/}" in
  canonical-sdlc|bionic:canonical-sdlc) ;;
  *) exit 0 ;;
esac

CWD="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$CWD" ]; then
  CWD=$(_jq '.cwd')
fi
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# ---------- the library ----------
#
# One loader idiom, byte-identical in every hook. FAIL OPEN: a trigger that refused the
# invocation it exists to record would be worse than one that misses it. A missed
# engagement leaves the session unwalled, which is exactly the state it was in a moment
# ago; a refused `/canonical-sdlc` is a broken front door.
BIONIC_LIB_WANT="root.sh run.sh session.sh binding.sh"
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
if [ -n "$BIONIC_LIB_MISSING" ]; then loader_fail_open "engage"; fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/root.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/run.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/session.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/binding.sh"

# ---------- ROOT, SESSION ID, MARKER PATH — the three facts, each from its one owner ----
#
# The env value is primary and the payload is a witness (L-SESSION): the marker filename is
# what sixteen hooks will later build from their own `session_id` answer, so a trigger that
# preferred the payload would write a file nobody reads. `engaged_marker_path` owns the
# whole shape rule — empty, `unknown`, and any character outside [A-Za-z0-9_-] are refused
# there, once, rather than restated here.
REPO=$(project_root "$CWD")
[ -n "$REPO" ] && [ -d "$REPO" ] || exit 0

SID=$(session_id "$(_jq '.session_id')" 2>/dev/null) || SID=""
[ -n "$SID" ] || exit 0

MARKER=$(engaged_marker_path "$REPO" "$SID") || exit 0

# ---------- THE TREE ----------
#
# NOTHING IN THE PAYLOAD OWNS TREE CREATION TODAY — only SKILL.md's Step-0 prose, which is
# a model instruction, not a mechanism. A first run in a fresh project would engage and
# then find nowhere to put the marker, so the walls would stay off for the whole session:
# the fail-open direction turning into a silent no-op precisely where a run is starting.
# The tree is therefore created here, and `.gitignore` = `*` goes with it because
# `.bionic/` is machine-local by decision and a project that committed it would carry
# another machine's session markers.
#
# A SYMLINKED .bionic IS REFUSED, not followed. `project_root` already skips a symlinked
# `.bionic` on its walk, so this is the case where the root came from the git-toplevel
# fallback — and writing through it would put a session's engagement wherever the link
# points.
BDIR="$REPO/.bionic"
[ -L "$BDIR" ] && exit 0

FRESH=no
[ -d "$BDIR" ] || FRESH=yes

mkdir -p "$BDIR/tmp" 2>/dev/null || {
  echo "engage: cannot create $BDIR/tmp — this session stays unengaged" >&2
  exit 0
}
if [ "$FRESH" = "yes" ] && [ ! -e "$BDIR/.gitignore" ]; then
  printf '*\n' > "$BDIR/.gitignore" 2>/dev/null || :
fi

# An existing .bionic/tmp that is not a real writable directory is REPORTED and then let
# go. Never blocked: whatever is wrong with the tree, refusing the skill invocation is not
# the repair, and stderr on a zero exit reaches a debug log rather than the turn.
TMP="$BDIR/tmp"
if [ -L "$TMP" ] || [ ! -d "$TMP" ] || [ ! -w "$TMP" ]; then
  echo "engage: $TMP is not a writable directory — this session stays unengaged" >&2
  exit 0
fi

# ---------- THE MARKER ----------
#
# A symlink at the marker path is refused before it is followed — the guard idiom
# patrol-revive.sh uses on its stamp, and it matters more here: a planted link would let a
# hostile repo have this hook clobber a file outside the tree, on the one write bionic
# performs at the invocation the user just typed.
[ -L "$MARKER" ] && exit 0

# THE PLAN IS A FIELD, NOT A PRECONDITION. Step 0 of a new run precedes its plan file, and
# engagement is what decides WHETHER a hook acts while the binding decides WHAT — so a
# marker written before any plan exists is the normal opening state, not a degraded one.
#
# WHICH plan the field names changed in wave-session-bound-run (2026-09-04, spec §Design
# "Session binding"; AC-7). This used to be `active_run` — the NEWEST open plan in the root
# — written unconditionally on every invocation, and that was the bug: two sessions in one
# repository got one run identity, and a plan landing mid-session silently moved a live
# session onto it. The rule now, in two lines:
#
#   the marker already names a plan  -> LEAVE IT. Re-engagement decides nothing.
#   otherwise, EXACTLY ONE open run  -> bind to it; anything else -> bind to `none`
#
# A BINDING SURVIVES RE-ENGAGEMENT WHETHER OR NOT ITS PLAN IS STILL OPEN (S10a, review C-1).
# It used to survive only while `session_run` said `bound-open`; a `bound-closed` binding
# fell to the count rule, and when the root held exactly one open run that run belonged to
# ANOTHER SESSION. A session whose own wave had just closed re-invoked the skill and was
# silently moved onto the neighbour's plan, after which its evidence gate gated on that
# plan — symptom 1 of the bug this wave was opened on, reached through the engagement door
# instead of the scan. A binding is a commitment (AC-6) and a dead commitment is still not
# somebody else's: the operator ends it with `session-poker.sh bind <plan>`, not the hook.
#
# SO THE VERDICT IS NOT ASKED FOR HERE, ONLY THE FIELD. `session_plan` reads two lines off
# disk and answers "is this session bound"; `session_run` would additionally rule on whether
# the plan is open, and on an UNBOUND session it walks the whole tree through `active_run` to
# produce a `fallback` this hook then discards. That walk was one of three (review P1): a
# bound session now does NONE, and an unbound one does the two `open_runs` walks the count
# rule and the writer's own membership check each need.
#
# SEVERAL OPEN RUNS BINDS NOTHING, deliberately. Picking the newest would be the old bug
# with extra steps; the session is left unbound, session-start lists every candidate, and
# the operator chooses with `session-poker.sh bind <plan>`. An unbound session still
# resolves by `active_run`, out loud, as `fallback`.
#
# THE WRITE ITSELF IS NOT HERE. `payload/scripts/lib/binding.sh` is the single writer —
# shape, mode 600, the symlink refusal and open-run membership are its invariants, shared
# with poker's `bind` verb and the governing skill's bind-on-first-write. This hook only
# decides WHICH plan, and never blocks on the answer: every path below exits 0.
BOUND=0
if PLAN=$(session_plan "$REPO" "$SID" 2>/dev/null); then
  BOUND=1
else
  PLAN="none"
  # wave-roster-lifecycle S2 (spec AC-2; design §2 "engage.sh"): the count rule counts
  # LIVE runs, not merely open ones — an open-but-quiet run is not "being worked", and
  # binding to it reproduces this hook's own bug one layer down. `live_runs ⊆ open_runs`
  # always (run.sh), so this is strictly narrower than the old open-run set; the `= "1"`
  # rule and the single `bind_plan` call site below are unchanged.
  RUNS=$(live_runs "$REPO" 2>/dev/null) || RUNS=""
  if [ -n "$RUNS" ] && [ "$(printf '%s\n' "$RUNS" | wc -l | tr -d ' ')" = "1" ]; then
    PLAN="$RUNS"
  fi
fi

# ONE WRITE STATEMENT, AND THE RETRY RIDES IT. Read left to right: write the binding; if the
# writer refuses and this session was ALREADY BOUND, that refusal is the right answer and the
# marker stands (the bound plan has closed — a commitment is not somebody else's to reassign,
# AC-6); if it refuses and the session was UNBOUND, fall to `none`.
#
# THE UNBOUND RETRY IS NOT DEFENSIVE PADDING (S10a, review C-4). `PLAN` comes off a walk that
# has already finished and `bind_plan` walks AGAIN for its own membership check, so a run
# closing inside that window made the single write refuse and left the session with NO MARKER
# AT ALL — unengaged, and therefore unwalled, which is the one direction this hook's own
# fail-direction argument forbids. `none` is what the count rule would have said had the walk
# seen the close.
#
# ONE LINE, DELIBERATELY. tests/cross-gate-agreement.test.sh §B2 proves this hook writes
# through the single writer by replacing this call site with an inline redirect and requiring
# the marker's SHAPE to change; a second `bind_plan` statement on another line would leave
# that mutation replacing a call the fixture never reaches, and the proof would pass on the
# unmutated path. The shape of the code is holding the shape of the proof.
bind_plan "$REPO" "$SID" "$PLAN" || [ "$BOUND" = 1 ] || bind_plan "$REPO" "$SID" none || :

exit 0
