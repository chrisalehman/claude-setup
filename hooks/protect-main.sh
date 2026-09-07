#!/bin/bash
# HARD BLOCK: Prevents AI from pushing to main/master branches.
# Exit code 2 = block the tool call entirely in Claude Code hooks.
# The user must push to main manually from their own terminal.
# [WALL: tests/protect-main.test.sh]
# Registered always-on in hooks/hooks.json; runs from the mounted plugin payload.

# The command reader. Everything below asks the library what the words of this
# command line are; nothing here greps the raw text. Until 1.3.2 it did, and
# `git -C /tmp/r push origin main`, `git push origin "main"` and
# `git push origin feature:refs/heads/main` all walked past this wall while a
# heredoc that merely MENTIONED a push was refused.
#
# THE COMMAND IS READ BEFORE THE LIBRARY IS. Not for convenience: the repair
# allowlist below needs the command text, and it has to be consulted BEFORE this
# wall decides to refuse. `jq` on the payload is the one read that does not need
# the library, so it is the one read that can precede it.
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')

# FAIL-CLOSED (design ledger S4, Chris D1 2026-08-30): a wall over an IRREVERSIBLE
# action that cannot load its library refuses, because a wall that cannot read a
# command must not wave it through. `loader_fail_closed` permits exactly four repair
# commands by whole-string match first, so a broken publish can still be repaired —
# the lockout R-1 §(5) measured and this wave is named for.
BIONIC_LIB_WANT="git-argv.sh root.sh run.sh session.sh"
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
if [ -n "$BIONIC_LIB_MISSING" ]; then loader_fail_closed "protect-main" "$COMMAND"; fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/git-argv.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/root.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/run.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/session.sh"

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
# [WALL: tests/protect-main.test.sh]
#
# THE LOADER REFUSAL ABOVE IS NOT SCOPED BY THIS and cannot be: the predicate lives in
# the library that just failed to load. A broken plugin still refuses a push in any
# session, engaged or not — the one place this wall outruns the ruling, and the price of
# a fail-closed wall that cannot read its own scope.
PM_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -n "$PM_CWD" ] || PM_CWD=$(pwd)
PM_REPO=$(project_root "$PM_CWD")
PM_SID=$(session_id "$(echo "$INPUT" | jq -r '.session_id // empty')" 2>/dev/null) || PM_SID=""
engaged_session "$PM_REPO" "$PM_SID" || exit 0

# Read every segment. A segment is a push only when git is argv[0] (after
# leading VAR=value assignments, shell openers, command-taking prefixes and
# git's own global options) and `push` is the subcommand — so
# `echo 'git push origin main'`, `grep 'git push' README.md` and a heredoc body
# are not pushes, and `git -C <dir> push`, `sudo git push`,
# `if …; then git push …; fi` and `sh -c 'git push …'` are.
#
# git_argv_EXPAND, not git_argv_segments: the expanded list adds the segments
# of any `sh -c` / `eval` string, which the segment list on its own leaves as a
# single opaque token (R-12, critic C-1/C-5).
IS_PUSH=0
while IFS= read -r segment; do
  [ -n "$segment" ] || continue
  git_argv_parse "$segment" || continue
  [ "$GIT_SUB" = "push" ] || continue
  IS_PUSH=1
  git_push_targets

  # Block 1: this push writes to a protected branch. GIT_DESTS is US-separated;
  # each destination is asked of git_branch_protected, which is the ONE place
  # `main` and `master` are named — payload/scripts/lib/worktree.sh's land wall
  # asks the same function about the branch it is about to merge into, and a
  # second copy of the list here is how the two would drift apart.
  # The split is pure parameter expansion: no subshell on the hot path of a hook
  # that runs on every Bash call. `topic/main` and `main-fixes` are their own
  # branches and stay allowed, because the predicate matches the whole name.
  # [WALL: tests/protect-main.test.sh]
  rest="$GIT_DESTS"
  while [ -n "$rest" ]; do
    dest="${rest%%"$GIT_ARGV_US"*}"
    if [ "$dest" = "$rest" ]; then rest=""; else rest="${rest#*"$GIT_ARGV_US"}"; fi
    [ -n "$dest" ] || continue
    if git_branch_protected "$dest"; then
      echo "BLOCKED: Pushing to main/master is not allowed from Claude Code." >&2
      echo "Push to main must be done manually by the user." >&2
      exit 2
    fi
  done

  # Block 2: force pushes (always dangerous) [WALL: tests/protect-main.test.sh]
  if [ "$GIT_FORCE" -eq 1 ]; then
    echo "BLOCKED: Force pushing is not allowed from Claude Code." >&2
    exit 2
  fi
done <<< "$(git_argv_expand "$COMMAND")"

# Skip if no actual push command found
if [ "$IS_PUSH" -eq 0 ]; then
  exit 0
fi

# Block 3: Any push while on main/master branch (catches implicit pushes
# like "git push origin", "git push origin HEAD", bare "git push")
# [WALL: tests/protect-main.test.sh]
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ -n "$CURRENT_BRANCH" ] && git_branch_protected "$CURRENT_BRANCH"; then
  echo "BLOCKED: Cannot push while on '$CURRENT_BRANCH' branch from Claude Code." >&2
  echo "Switch to a feature branch or push manually from your terminal." >&2
  exit 2
fi

exit 0
