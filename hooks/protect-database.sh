#!/bin/bash
# HARD BLOCK: Prevents AI from running destructive database operations.
# [WALL: tests/protect-database.test.sh]
# Exit code 2 = block the tool call entirely in Claude Code hooks.
# Catches DROP, TRUNCATE, DELETE without WHERE, and ALTER TABLE...DROP
# via psql, mysql, sqlite3, and other common DB CLIs.
# Registered always-on in hooks/hooks.json; runs from the mounted plugin payload.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only check Bash commands
[ -z "$COMMAND" ] && exit 0

# ---------- the library, and the one question that scopes this wall ----------
#
# FAIL OPEN (task-engaged-session, 2026-09-03). This wall carried no library at all
# until now, so a missing one could never have silenced it; what it gains here is the
# engagement predicate, and that predicate cannot be evaluated without the library.
# Refusing every database command in every project on the machine because one file is
# missing would arm this wall in exactly the sessions Chris's ruling takes it out of.
# The direction is chosen by the cost of the mistake: a destructive command that slips
# through a broken plugin is one command, and the plugin being broken is loud.
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
if [ -n "$BIONIC_LIB_MISSING" ]; then loader_fail_open "protect-database"; fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/root.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/run.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/session.sh"

# ---------- THE ENGAGEMENT GUARD (AC-20): is this session bionic's at all? ----------
#
# FIRST, above every other question this hook asks. Chris, 2026-09-03: "all guardrails
# imposed by bionic should only apply when exercising bionic. Nothing should apply until
# bionic is triggered" — and the trigger is the canonical-sdlc skill, which writes
# `.bionic/tmp/engaged-<sid>.state` at the instant it is invoked. A session that never
# invoked it is one this wall has nothing to say to, and it says nothing: exit 0, no
# stdout, no stderr.
#
# EVERY UNREADABLE STATE READS AS NOT ENGAGED — absent marker, a symlink at the path, a
# foreign or unshaped session key, no key at all. The marker is the one artifact whose
# PRESENCE opens a wall, so the fail direction is inverted here on purpose: the arming
# partition is the consent boundary (1.3.2 close-out), and a wall that binds a session
# which never consented is the defect this guard exists to remove.
# [WALL: tests/protect-database.test.sh]
DB_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -n "$DB_CWD" ] || DB_CWD=$(pwd)
DB_REPO=$(project_root "$DB_CWD")
DB_SID=$(session_id "$(echo "$INPUT" | jq -r '.session_id // empty')" 2>/dev/null) || DB_SID=""
engaged_session "$DB_REPO" "$DB_SID" || exit 0


# Uppercase for case-insensitive matching
CMD_UPPER=$(echo "$COMMAND" | tr '[:lower:]' '[:upper:]')

# Check if this involves a database CLI
if echo "$COMMAND" | grep -qEi '(psql|mysql|sqlite3|mongosh|mongo |clickhouse-client|cqlsh|cockroach sql|pg_|mariadb)\b'; then

  # DROP TABLE / DATABASE / SCHEMA / INDEX / COLLECTION / VIEW / FUNCTION / TRIGGER / PROCEDURE / SEQUENCE / TYPE
  # [WALL: tests/protect-database.test.sh]
  if echo "$CMD_UPPER" | grep -qE 'DROP\s+(TABLE|DATABASE|SCHEMA|INDEX|COLLECTION|VIEW|FUNCTION|TRIGGER|PROCEDURE|SEQUENCE|TYPE)'; then
    echo "BLOCKED: Destructive database operation (DROP) detected." >&2
    echo "Run destructive migrations manually from your terminal." >&2
    exit 2
  fi

  # TRUNCATE [WALL: tests/protect-database.test.sh]
  if echo "$CMD_UPPER" | grep -qE 'TRUNCATE\s'; then
    echo "BLOCKED: Destructive database operation (TRUNCATE) detected." >&2
    echo "Run destructive migrations manually from your terminal." >&2
    exit 2
  fi

  # DELETE without WHERE (mass delete) — check per-statement to avoid multi-statement bypass
  # [WALL: tests/protect-database.test.sh]
  while IFS= read -r stmt; do
    stmt_upper=$(echo "$stmt" | tr '[:lower:]' '[:upper:]')
    if echo "$stmt_upper" | grep -qE 'DELETE\s+FROM\s' && ! echo "$stmt_upper" | grep -qE 'DELETE\s+FROM\s+\S+\s+WHERE\s'; then
      echo "BLOCKED: DELETE without WHERE clause detected." >&2
      echo "Run destructive operations manually from your terminal." >&2
      exit 2
    fi
  done <<< "$(echo "$CMD_UPPER" | tr ';' '\n')"

  # ALTER TABLE ... DROP COLUMN [WALL: tests/protect-database.test.sh]
  if echo "$CMD_UPPER" | grep -qE 'ALTER\s+TABLE\s+.*DROP\s'; then
    echo "BLOCKED: Destructive ALTER TABLE (DROP) detected." >&2
    echo "Run destructive migrations manually from your terminal." >&2
    exit 2
  fi

  # MongoDB destructive operations (JavaScript method calls)
  # [WALL: tests/protect-database.test.sh]
  if echo "$COMMAND" | grep -qEi '(\.drop\(\)|\.dropDatabase\(\)|\.deleteMany\(\s*\{\s*\}\s*\))'; then
    echo "BLOCKED: Destructive MongoDB operation detected." >&2
    echo "Run destructive operations manually from your terminal." >&2
    exit 2
  fi
fi

# Also catch raw SQL piped or passed inline (e.g., echo "DROP TABLE..." | psql)
# [WALL: tests/protect-database.test.sh]
if echo "$CMD_UPPER" | grep -qE '(DROP\s+(TABLE|DATABASE|SCHEMA|VIEW|FUNCTION|TRIGGER|PROCEDURE)|TRUNCATE\s)' && echo "$COMMAND" | grep -qEi '(\|\s*(psql|mysql|sqlite3|mongosh)|<< )'; then
  echo "BLOCKED: Destructive SQL piped to database client." >&2
  echo "Run destructive migrations manually from your terminal." >&2
  exit 2
fi

exit 0
