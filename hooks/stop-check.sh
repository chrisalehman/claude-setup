#!/bin/bash
# THE OBSERVATION — epic-15 wave-01R, AC-3.
#
# Run this before stopping a subagent:
#
#   bash ~/.claude/hooks/stop-check.sh <agent-name-or-id> [deliverable-path ...] [--progress <path>]
#
# It resolves the target against the metadata the platform writes to disk (P5/P6)
# and prints that agent's EVIDENCE TIER — working-log recency as absolute time
# and age, the agent's last message, repo activity, each contracted
# deliverable's existence and substance, and — when the work contract named a
# progress artifact — that artifact's own recency (D-6).
#
# IT DECIDES NOTHING. No verdict, no recommendation, no stop. The judgment stays
# with the reader; this command only makes the evidence visible. Its run is
# observed by hooks/execution-recorder.sh's PostToolUse|Bash arm, which reads the
# MACHINE LINE this command prints on its success path and turns it into the
# record a later stop spends — so "I looked" becomes a fact rather than a memory
# (design/orchestrator-subagent-coordination.md §4).
#
# THE MACHINE LINE IS THE ONLY THING THE RECORDER READS (slice 4/4). It is
# printed on the SUCCESS path and nowhere else: a usage error, an unresolved
# target and an ambiguous target all exit non-zero having printed no such line,
# so a run that showed the operator no evidence tier leaves nothing behind that
# a stop could spend. That is the whole of the C6 closure — the recorder no
# longer re-parses this command's ARGUMENTS with a second grammar (the F-1
# divergence class), it reads this command's own OUTPUT.
#
# This is a PRODUCER, not a hook — it lives in hooks/ for test-harness pairing
# only. Producers may think and take seconds; gates may only read (§3.2).
# [WALL: tests/stop-check.test.sh]
#
# Registered on no channel — invoked on demand from the mounted plugin payload.

set -uo pipefail

# THIS SCRIPT'S OWN PATH, so the usage it prints names the copy the operator actually
# invoked — identical in a repo checkout, in a bootstrap-installed ~/.claude/hooks/, and in
# an installed plugin payload. Deliberately NOT ${CLAUDE_PLUGIN_ROOT}: this script is run by
# hand and by the harness outside any plugin context, where that variable does not exist.
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || HOOK_DIR="$(dirname "$0")"

MAX_MESSAGE_CHARS=600

# The machine line's schema token. Versioned so the recorder can refuse a shape
# it does not read rather than guess at it, and greppable as a fixed string so
# the recorder's hot path is one `grep -F` on every Bash call in the session.
MACHINE_SCHEMA="stop-check-observation/v1"

usage() {  # [reason]
  [ -n "${1:-}" ] && echo "$1" >&2
  echo "Usage: bash ${HOOK_DIR}/stop-check.sh <agent-name-or-id> [deliverable-path ...] [--progress <path>]" >&2
  echo "" >&2
  echo "Prints one subagent's evidence tier. Decides nothing." >&2
  exit 1
}

# ---------- arguments ----------
#
# TARGET FIRST, and no flag before it. This grammar is not a style choice: the
# Bash arm of hooks/stop-guard.sh re-parses this same command line to record
# WHICH agent was examined, and it reads only what is written here — it skips
# `-*` tokens one at a time and takes the first non-flag token, with no
# knowledge that `--progress` consumes the token after it. Accepting the flag
# ahead of the target therefore makes the two halves name DIFFERENT agents: the
# operator looks at one, the record attests to the other, and a record naming an
# unexamined agent is the stop wall opening on a look that never happened. The
# producer stays inside what its paired reader can parse; the agreement is
# pinned by tests/cross-gate-agreement.test.sh §C case 6.
#
# For the same reason an unrecognized `-`-leading token is a usage error rather
# than a deliverable path. `--progres` and `--progress=<path>` are the likely
# typos, and silently filing them under Deliverables prints an evidence tier
# missing a channel the reader believes they asked for.
#
# After the target, each non-flag argument is rotated to the back, so what
# survives the loop is the contracted deliverables in the order they were typed.
# ONE progress path, or nothing: a second flag makes "which artifact did the
# contract name?" a guess, and guessing about evidence is the failure this
# whole command exists to prevent. An EMPTY value is a missing one — a token
# following the flag is not a path that was named, and `--progress "$PROG"`
# with PROG unset would otherwise print an authoritative ABSENT for an artifact
# nobody contracted, which is the false negative D-6 exists to prevent. Written without arrays — bash 3.2 is what
# macOS ships, and an empty array under `set -u` is a crash there.
case "${1:-}" in
  "") usage ;;
  -*) usage "The target comes first: '$1' is an option, not an agent." ;;
esac
TARGET="$1"; shift

PROGRESS_PATH=""
PROGRESS_NAMED=0
CLAIMS_PATTERN=""
CLAIMS_NAMED=0
ARGN=$#
while [ "$ARGN" -gt 0 ]; do
  arg="$1"; shift; ARGN=$((ARGN - 1))
  case "$arg" in
    --progress)
      [ "$PROGRESS_NAMED" -eq 0 ] || usage "Only one --progress path may be named; got a second."
      [ "$ARGN" -gt 0 ] || usage "--progress needs a path."
      [ -n "$1" ] || usage "--progress needs a path."
      PROGRESS_PATH="$1"; shift; ARGN=$((ARGN - 1)); PROGRESS_NAMED=1 ;;
    --claims)
      # P2 (Liveness contract, ratified 2026-08-05): a subprocess claim is a
      # PATTERN, checked for existence only — same grammar as --progress, and
      # for the same reason (the target-first rule above is what the recorder
      # can parse; a flag anywhere else would be unparseable by it too).
      [ "$CLAIMS_NAMED" -eq 0 ] || usage "Only one --claims pattern may be named; got a second."
      [ "$ARGN" -gt 0 ] || usage "--claims needs a pattern."
      [ -n "$1" ] || usage "--claims needs a pattern."
      CLAIMS_PATTERN="$1"; shift; ARGN=$((ARGN - 1)); CLAIMS_NAMED=1 ;;
    -*)
      usage "Unknown option: $arg" ;;
    *)
      set -- "$@" "$arg" ;;
  esac
done

# ---------- portable file facts ----------
# DELIBERATELY DUPLICATED in hooks/stop-guard.sh, byte for byte. A shared
# library is rejected by design (TDD §9): a sourced file the installer misses is
# a silently inert wall. The copies are held together by the N-way agreement
# suite, which drives every copy including this one.
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
file_size()  { stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo 0; }

# One field out of a versioned pipe-delimited line, BY KEY, never by position
# (checklist A6). DELIBERATELY DUPLICATED from hooks/execution-recorder.sh, which
# reads the session roster with the identical function — the two copies are held
# together by tests/cross-gate-agreement.test.sh. This copy reads the roster row
# for classification and contract state (slice 4/5); it never writes one.
line_field() {  # <line> <key>
  printf '%s' "$1" | tr '|' '\n' | grep "^$2=" | head -1 | cut -d= -f2-
}

# Existence only, for P2 (Liveness contract). `pgrep -f` matches the full
# command line; a `ps` fallback covers a machine without it.
claims_live() {  # <pattern> -> 0 if a process matches, 1 otherwise
  local pat="$1"
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f -- "$pat" >/dev/null 2>&1
    return $?
  fi
  ps -eo command 2>/dev/null | grep -qF -- "$pat"
}

# The machine line is pipe-delimited key=value, like the observation record it
# becomes and like the roster row (hooks/dispatch-preflight.sh). A `|`, a newline
# or a control character inside a VALUE would forge a field, and every value here
# is operator-supplied — the typed target, the deliverable paths, the progress
# path. They are normalized rather than refused: this command's job is to print
# evidence, and a target with an odd character in it is still a target the
# operator asked about.
mline_value() {  # <value>
  printf '%s' "$1" | tr '\n\r\t|' '    ' | sed -e 's/[[:cntrl:]]/ /g' -e 's/  */ /g' \
    -e 's/^ *//' -e 's/ *$//' | cut -c 1-400
}

fmt_epoch() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf 'epoch:%s\n' "$1"
}

fmt_age() {  # <seconds> -> "3m 12s"
  local s="$1"
  [ "$s" -lt 0 ] 2>/dev/null && s=0
  if   [ "$s" -lt 60 ];    then printf '%ds\n' "$s"
  elif [ "$s" -lt 3600 ];  then printf '%dm %ds\n' $((s / 60)) $((s % 60))
  elif [ "$s" -lt 86400 ]; then printf '%dh %dm\n' $((s / 3600)) $(((s % 3600) / 60))
  else                          printf '%dd %dh\n' $((s / 86400)) $(((s % 86400) / 3600))
  fi
}

# ---------- resolving the target (P5: the platform does not translate) ----------
#
# A typed reference is a NAME, an agent id, or `name@team` — all three are legal
# TaskStop inputs, and none of them is resolved for us. Comparison is LITERAL:
# a target string is never treated as a pattern.
# [WALL: tests/stop-check.test.sh]

slugify() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

# WHERE CLAUDE CODE STORES SESSION AND PROJECT METADATA. One concept, three
# renderings in this wave, and they must name one directory: hooks/stop-guard.sh
# derives it from the payload's transcript path (it has one), hooks/preflight-probe.sh
# reads `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, and this producer has no payload
# so it must read the same variable. Rooting this at $HOME alone made the two
# sides name different directories the moment CLAUDE_CONFIG_DIR was set — the
# observation printed "unresolved" while the recorder wrote a record the stop
# gate then spent, which is the wall OPENING on a look that showed nothing
# (Step-6 critic, issue 1). Pinned by tests/cross-gate-agreement.test.sh §C,
# which runs with the two roots deliberately different.
PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
TARGET_BASE="${TARGET%@*}"
[ -n "$TARGET_BASE" ] || TARGET_BASE="$TARGET"

# RESOLUTION IS NO LONGER A DIRECTORY SCAN (wave-roster-lifecycle S6, D2/D2′). This script
# used to carry `scan_subagent_dirs` — a walk of every `agent-*.meta.json` in the project,
# matching a typed reference against the filename's id or the file's `.name` — byte-identical
# to a copy in hooks/stop-guard.sh, the two held together by an agreement suite. It answered
# "which agent is this" from RECORDS, and records outlive agents: after a `/clear` the same
# agent's metadata is filed under two session directories at once (proven on this machine,
# research-code-map §4.4), which the walk reported as two agents.
#
# What decides now is `live_agents_has` on the session's own transcript — the newest recorded
# ListAgents answer, the harness's own statement about which teammates exist this turn. One
# function, called by this script and by the gate, so a change to the reader moves both.

# Candidate project slugs, in order: the cwd, then the enclosing repo root.
# Claude Code names a project directory by slugifying its path — every
# non-alphanumeric character becomes a dash (confirmed against two verbatim
# captures in record/epic-15-kill-interception-experiment.md §1.1/§2.2).
# ---------- the library ----------
#
# One loader idiom, byte-identical in every hook (spec AC-16). FAIL OPEN: this script
# reports, it does not refuse, and a diagnosis that died with the thing being diagnosed
# would be worth nothing.
BIONIC_LIB_WANT="roots.sh root.sh session.sh agents.sh"
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
if [ -n "$BIONIC_LIB_MISSING" ]; then loader_fail_open "stop-check"; fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/roots.sh"
. "$BIONIC_LIB/root.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/session.sh"
# THE ONE READER OF THE LIVE SET (wave-roster-lifecycle S4/S6, D1′). hooks/stop-guard.sh
# calls the SAME function on the SAME transcript, which is what makes the observation and the
# gate resolve one candidate set (AC-10) — where before they carried one loop in two copies.
# shellcheck source=/dev/null
. "$BIONIC_LIB/agents.sh"

CWD="$(pwd)"
# THE ROOT (spec AC-10, lib/root.sh). `rev-parse --show-toplevel` answers with whatever
# tree the SHELL stands in, so from a linked worktree this script looked for the roster
# under a tree nothing had written one into and reported every contracted path absent.
# `project_root` maps a worktree onto its main repository and walks for the nearest real
# `.bionic`. The slug list below still carries both the cwd and the root, because the
# harness names a project directory after the path the SESSION was started in.
REPO_ROOT=$(project_root "$CWD")
SLUGS="$(slugify "$CWD")"
if [ -n "$REPO_ROOT" ] && [ "$REPO_ROOT" != "$CWD" ]; then
  SLUGS="${SLUGS}
$(slugify "$REPO_ROOT")"
fi

# ---------- resolving a contracted path (epic-17 W6 S15, A-6.6 (c)) ----------
#
# WHAT WAS WRONG. The paths this command stats — the deliverables, and the `--progress`
# artifact — arrive as brief prose, and the spelling every slice brief in this epic uses is
# `record/epic-NN-wM/x.md`, because that is the form the Step-5 contract and
# `canonical-sdlc-evidence-gate.sh` publish for an artifact under the docs root. This
# command resolved nothing at all: a relative path was stat'd against whatever directory
# the observer happened to be standing in, so a present progress file read `absent` and a
# landed deliverable read `ABSENT` — an observation that decides nothing, deciding wrongly.
#
# THE RULE IS ONE FUNCTION NOW. The docs root comes from lib/roots.sh's `docs_root` — this
# command used to carry a copy of the evidence gate's `resolve_docs_root()`, held to the
# gate's text by a body-for-body comparison; cross-gate §Roots holds the single definition
# instead (epic-22 wave-01, N1). `abs_path` below is still a copy of the gate's
# `resolve_walk_path()` under another name, deliberately out of that scope.
# `PROJECT_DIR` and `DOCS_ROOT` carry the gate's names for the same reason. The VALUE of PROJECT_DIR is this command's own — the repo it was run
# from, falling back to the cwd when that is not a repository, which is the root every
# other path in this file is already read against.
#
# WHAT IS STILL NOT JUDGED. Resolution is not a verdict. A path that climbs out with `..`
# resolves and is reported like any other: §4's rule is that this command decides nothing,
# and refusing a contract here would be deciding. The landing gate is where a deliverable
# is judged, and hooks/session-sweeper.sh refuses `..` there.

PROJECT_DIR="${REPO_ROOT:-$CWD}"
DOCS_ROOT="$(docs_root "$PROJECT_DIR")"

abs_path() {  # <path, as the roster spells it> -> absolute
  case "$1" in
    /*)       printf '%s\n' "$1" ;;
    record/*) printf '%s/%s\n' "$DOCS_ROOT" "$1" ;;
    *)        printf '%s/%s\n' "$PROJECT_DIR" "$1" ;;
  esac
}

# ---------- THIS SESSION'S OWN id, and the transcript the live set is read from ----------
#
# THE KEY. This script has no hook payload to carry a session key, so it reads the one the
# harness exports into every Bash subprocess — the same resolution hooks/preflight-probe.sh
# makes. Empty when the command runs outside a Claude Code session; the live set is then
# unreadable and this command says so rather than guessing.
ROSTER_VERSION="v1"
OWN_SESSION_ID=$(session_id "" 2>/dev/null) || OWN_SESSION_ID=""

# THE TRANSCRIPT. hooks/stop-guard.sh is handed one in its payload; this script has to find
# the same file. The harness names it `<projects>/<slug>/<session-id>.jsonl`, so the slugs
# above are tried first and a keyed walk of the project directories covers the one case that
# breaks them: a worktree cwd files its session under a different slug from the repo it is
# reading. Exactly the same two-step `adopted_subagent_dirs` used before this slice deleted it.
own_transcript() {  # -> the transcript file of THIS session, or nothing
  local slug d
  [ -n "$OWN_SESSION_ID" ] || return 1
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    if [ -f "$PROJECTS/$slug/$OWN_SESSION_ID.jsonl" ]; then
      printf '%s\n' "$PROJECTS/$slug/$OWN_SESSION_ID.jsonl"; return 0
    fi
  done <<< "$SLUGS"
  for d in "$PROJECTS"/*/"$OWN_SESSION_ID.jsonl"; do
    [ -f "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}
OWN_TRANSCRIPT=$(own_transcript) || OWN_TRANSCRIPT=""

# ---------- the session roster, read BY BOTH KEYS before resolution ----------
#
# The roster is read first because the transcript-form agent id is a spelling only it can
# translate: the harness's answer lists teammates by NAME, so an id has to become a name
# before the live set can be asked about it. And because the id is what the WORKING LOG is
# filed under — `<session>/subagents/agent-<id>.jsonl` — which the deleted scan used to
# supply and nothing else knows.
#
# `confirmed` or `identified`, never `intended`: the id on an unconfirmed row is a claim
# about a launch that has not been observed to happen (Step-6 review C-2). `identified` is
# the state that makes the clause reachable for a teammate at all — a confirmed teammate
# row's `agent_id=` is EMPTY by design, because the launch response knows only the addressing
# form `name@session-xxxx`, and the transcript-form id first appears on SubagentStart.
ROSTER_PATH=""
if [ -n "$REPO_ROOT" ] && [ -n "$OWN_SESSION_ID" ]; then
  ROSTER_PATH="$REPO_ROOT/.bionic/tmp/roster-${OWN_SESSION_ID}.state"
fi
ROSTER_ROW=""
ROW_BY_ID=""; ROW_BY_NAME=""; ROW_WITH_ID=""
# TWO ROWS CAN CARRY ONE AGENT — the dispatch writes the CONTRACT, the recorder writes the id
# one state later — so the id and the contract are collected separately rather than read off
# one chosen row. Same walk as hooks/stop-guard.sh's, deliberately duplicated per TDD §9.
roster_walk() {  # <key>
  local key="$1" rline rid rname
  ROW_BY_ID=""; ROW_BY_NAME=""; ROW_WITH_ID=""
  [ -n "$ROSTER_PATH" ] || return 0
  [ -f "$ROSTER_PATH" ] || return 0
  [ -L "$ROSTER_PATH" ] && return 0
  while IFS= read -r rline; do
    case "$rline" in '#'*|'') continue ;; esac
    case "$rline" in "roster-state/${ROSTER_VERSION}|"*) : ;; *) continue ;; esac
    rid=$(line_field "$rline" agent_id)
    rname=$(line_field "$rline" name)
    case "$(line_field "$rline" status)" in
      confirmed|identified)
        [ -n "$rid" ] && [ "$rid" = "$key" ] && ROW_BY_ID="$rline"
        [ -n "$rid" ] && [ -n "$rname" ] && [ "$rname" = "$key" ] && ROW_WITH_ID="$rline"
        ;;
    esac
    [ -n "$rname" ] && [ "$rname" = "$key" ] && ROW_BY_NAME="$rline"
  done < "$ROSTER_PATH"
  return 0
}
roster_walk "$TARGET_BASE"
if [ -n "$ROW_BY_ID" ]; then
  TARGET_BASE=$(line_field "$ROW_BY_ID" name)
  roster_walk "$TARGET_BASE"
fi
ROSTER_ROW="$ROW_BY_NAME"

# ---------- resolution against the live set ----------
#
# Same function, same exit codes, same transcript the gate reads (AC-10). This command
# DECIDES NOTHING, so every unresolved shape below prints what it saw, exits 1, and — the
# half the whole C6 closure rests on — prints no machine line, because an operator who was
# shown no evidence tier must leave the recorder nothing to copy.
echo "OBSERVATION — target as typed: ${TARGET}"

LIVE_LINE=""; LIVE_RC=0
if [ -n "$OWN_TRANSCRIPT" ]; then
  LIVE_LINE=$(live_agents_has "$OWN_TRANSCRIPT" "$TARGET_BASE" 2>&1 >/dev/null) || LIVE_RC=$?
else
  LIVE_RC=4
  LIVE_LINE="live-agents: none age=none"
fi
LIVE_STATE="${LIVE_LINE#live-agents: }"; LIVE_STATE="${LIVE_STATE%% *}"
LIVE_AGE="${LIVE_LINE##*age=}"
case "$LIVE_STATE" in fresh|stale|none) : ;; *) LIVE_STATE="none" ;; esac
case "$LIVE_AGE" in ''|*[!0-9]*) LIVE_AGE="none" ;; esac

# EVERY ROSTER IN THIS REPO THAT CARRIES THIS NAME, as the addresses the platform's stop
# primitive takes. This is the one spelling hooks/stop-guard.sh accepts as an alias and
# `session-poker.sh adopt` prints for an adopted row (cross-gate Section R).
accepted_addresses() {  # -> one "    <name>@session-xxxxxxxx" line per launcher roster
  local f b out="" dir
  dir="${ROSTER_PATH%/*}"
  [ -n "$ROSTER_PATH" ] || return 0
  for f in "$dir"/roster-*.state; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    grep -qF "|name=${TARGET_BASE}|" "$f" || continue
    b="${f##*/roster-}"; b="${b%.state}"
    out="${out}    stop it as: ${TARGET_BASE}@session-$(printf '%s' "$b" | cut -c1-8)
"
  done
  printf '%s' "$out"
}

case "$LIVE_RC" in
  3|4)
    echo "Resolved:      unresolved — no fresh ListAgents answer for this session."
    echo "               newest answer: ${LIVE_STATE}   ·   age: ${LIVE_AGE}"
    echo ""
    echo "The live set belongs to the harness and only the model can ask for it (D1′), so"
    echo "this command reads the recorded answer rather than walking metadata on disk —"
    echo "which outlives the agents that wrote it. call ListAgents, then observe again."
    echo "This command decides nothing."
    exit 1
    ;;
  2)
    # MATCHED BY FIELD EQUALITY, never as a regular expression (Step-6 security review S-5).
    # `TARGET_BASE` is the operator's typed target; a `.`, `*` or `[` in it would over-match
    # and this refusal would report a count that is not the ambiguity it actually found.
    LIVE_DUPES=$(live_agents "$OWN_TRANSCRIPT" 2>/dev/null \
                 | awk -F'|' -v want="$TARGET_BASE" '$1 == want') || LIVE_DUPES=""
    LIVE_N=0
    [ -n "$LIVE_DUPES" ] && LIVE_N=$(printf '%s\n' "$LIVE_DUPES" | grep -c .)
    echo "Resolved:      ambiguous — ${LIVE_N} live agents answer to '${TARGET_BASE}':"
    printf '%s\n' "$LIVE_DUPES" | sed 's/^/  /'
    accepted_addresses | sed 's/^ *//;s/^/  /'
    echo ""
    echo "A name is not an identity, and the @session- alias cannot separate these either —"
    echo "hooks/stop-guard.sh accepts it only when the bare name resolves to exactly ONE live"
    echo "entry. This command decides nothing."
    exit 1
    ;;
  1)
    echo "Resolved:      not live — the fresh ListAgents answer names no teammate '${TARGET_BASE}'."
    echo ""
    echo "An agent that is not in the answer is not evidence of anything: it may have finished,"
    echo "or the name may be misspelled. Metadata on disk is not consulted — it outlives the"
    echo "agents that wrote it, which is the defect this replaced. This command decides nothing."
    exit 1
    ;;
esac

# ---------- resolved: the id, the session it is filed under, and its files ----------
#
# The id and the owning session both come from the ROSTER ROW, the only record that ever knew
# them. `adopted_from` names the session that LAUNCHED an agent this one took over after a
# `/clear`: the working log stays filed there, and the row is where `adopt` wrote that down.
AGENT_NAME="$TARGET_BASE"
AGENT_ID=$(line_field "$ROW_WITH_ID" agent_id)
ADOPTED_FROM=$(line_field "$ROSTER_ROW" adopted_from)
case "$ADOPTED_FROM" in *[!A-Za-z0-9-]*) ADOPTED_FROM="" ;; esac

if [ -z "$AGENT_ID" ]; then
  echo "Resolved:      live, but no agent id — this session's roster carries no \`confirmed\` or"
  echo "               \`identified\` row with an agent id for '${AGENT_NAME}'."
  echo ""
  echo "A working log is filed under an agent's id, and a dispatch records that id on its"
  echo "roster row when the agent starts. Without it there is no evidence tier to print."
  echo "This command decides nothing."
  exit 1
fi

SESSION_ID="${ADOPTED_FROM:-$OWN_SESSION_ID}"
SESSION_DIR="${OWN_TRANSCRIPT%.jsonl}"
[ -n "$ADOPTED_FROM" ] && SESSION_DIR="${OWN_TRANSCRIPT%/*}/$ADOPTED_FROM"
SUBDIR="$SESSION_DIR/subagents"
LOG="$SUBDIR/agent-${AGENT_ID}.jsonl"
META="$SUBDIR/agent-${AGENT_ID}.meta.json"

# The type comes from the live set — it is what the harness reported for this teammate — and
# the model and the description from the agent's own metadata, read at the ONE path the id
# names. Reading a known path is not a scan: nothing is matched, nothing is searched.
AGENT_TYPE=$(live_agents "$OWN_TRANSCRIPT" 2>/dev/null | awk -F'|' -v n="$AGENT_NAME" '$1==n {print $2; exit}')
[ -n "$AGENT_TYPE" ] || AGENT_TYPE="—"
AGENT_MODEL=$(jq -r '.model // "—"' "$META" 2>/dev/null)
[ -n "$AGENT_MODEL" ] || AGENT_MODEL="—"
AGENT_DESC=$(jq -r '.description // "—"' "$META" 2>/dev/null)
[ -n "$AGENT_DESC" ] || AGENT_DESC="—"

# ---------- classification (slice 4/5, AC-6; re-keyed on the live set at S6) ----------
#
# WHAT THIS USED TO ASK, and why it no longer can. It asked whether the agent's metadata was
# filed under this session's own `subagents/` directory, and answered FOREIGN or DEAD HISTORY
# when it was not. That question was about RECORDS, and records outlive agents: it is why a
# `/clear` left a live agent classified foreign by its own successor.
#
# The live set has already answered the only version of it that means anything: an agent the
# harness reports as THIS session's teammate is ours. What is left to say is HOW — whether by
# an ordinary dispatch or by adoption after a `/clear`, which is what tells the operator
# whose directory the working log below is filed under. It is reported, never judged (§4:
# this command decides nothing). `unknown` survives for the one degraded case that is real:
# a run with no session key at all, which cannot reach a live set and never gets this far.
CLASSIFICATION="ours"
OURS_BECAUSE="the harness reports it as a teammate of this session (roster-${OWN_SESSION_ID}.state carries its row)"
if [ -n "$ADOPTED_FROM" ]; then
  # OURS BY ADOPTION, said out loud. A row carrying `adopted_from=` is one
  # hooks/session-poker.sh's `adopt` wrote after a `/clear`+resume: the agent is still the
  # predecessor's process, its working log still filed under the predecessor's directory,
  # and this session took the contract over. Answering OURS mutely would leave the operator
  # reading about an agent filed under a session they are not in with nothing to explain it.
  OURS_BECAUSE="this session ADOPTED it (adopted_from=${ADOPTED_FROM}); the harness reports it as a teammate and its working log is still filed under the session that launched it"
fi

# ---------- contract state: roster-sourced when OURS, CLI always overrides ----------
#
# "Deliverable/progress display logic itself is unchanged — only the SOURCE of
# the paths widens" (slice 4/5 brief). An explicit CLI value always wins; when it
# differs from what the roster recorded, that is printed, never judged (§4: this
# command decides nothing).
ROSTER_DELIVERABLE=""; ROSTER_PROGRESS=""; ROSTER_CLAIMS=""; ROSTER_CADENCE=""
if [ -n "$ROSTER_ROW" ]; then
  ROSTER_DELIVERABLE=$(line_field "$ROSTER_ROW" deliverable)
  ROSTER_PROGRESS=$(line_field "$ROSTER_ROW" progress)
  ROSTER_CLAIMS=$(line_field "$ROSTER_ROW" claims)
  ROSTER_CADENCE=$(line_field "$ROSTER_ROW" cadence)
fi

ORIG_ARGS_COUNT="$#"
ORIG_ARGS_JOINED=""
if [ "$ORIG_ARGS_COUNT" -gt 0 ]; then
  ORIG_ARGS_JOINED=$(IFS=,; echo "$*")
fi

DELIVERABLE_SOURCE="none"
DELIVERABLE_MISMATCH=""
if [ "$ORIG_ARGS_COUNT" -gt 0 ]; then
  DELIVERABLE_SOURCE="args"
  if [ -n "$ROSTER_DELIVERABLE" ] && [ "$ORIG_ARGS_JOINED" != "$ROSTER_DELIVERABLE" ]; then
    DELIVERABLE_MISMATCH="$ROSTER_DELIVERABLE"
  fi
elif [ -n "$ROSTER_DELIVERABLE" ]; then
  DELIVERABLE_SOURCE="roster"
  # PATHNAME EXPANSION OFF for exactly this split. Setting IFS suppresses word
  # splitting on other characters and says nothing about globbing, so a roster
  # value of `docs/*.md` — which a brief can produce, since the lifter accepts
  # any slash-and-letter token and the writer's sanitizer does not strip `*` —
  # expanded against whatever happened to be sitting in the OBSERVER'S CWD.
  # Files nobody contracted for were then reported PRESENT and rode into the
  # durable record as confirmed deliverables (Step-6 review C-1/S-3). No wall
  # opened; the human judgment this whole command exists to inform was the thing
  # being fooled, which is worse to leave standing.
  OLDIFS="$IFS"; IFS=','; set -f; set -- $ROSTER_DELIVERABLE; set +f; IFS="$OLDIFS"
fi

PROGRESS_SOURCE="none"
PROGRESS_MISMATCH=""
if [ "$PROGRESS_NAMED" -eq 1 ]; then
  PROGRESS_SOURCE="args"
  if [ -n "$ROSTER_PROGRESS" ] && [ "$PROGRESS_PATH" != "$ROSTER_PROGRESS" ]; then
    PROGRESS_MISMATCH="$ROSTER_PROGRESS"
  fi
elif [ -n "$ROSTER_PROGRESS" ]; then
  PROGRESS_SOURCE="roster"
  PROGRESS_PATH="$ROSTER_PROGRESS"
  PROGRESS_NAMED=1
fi

CLAIMS_SOURCE="none"
if [ "$CLAIMS_NAMED" -eq 1 ]; then
  CLAIMS_SOURCE="args"
elif [ -n "$ROSTER_CLAIMS" ]; then
  CLAIMS_SOURCE="roster"
  CLAIMS_PATTERN="$ROSTER_CLAIMS"
  CLAIMS_NAMED=1
fi

echo "Resolved:      ${AGENT_ID}"
echo "               name: ${AGENT_NAME} · type: ${AGENT_TYPE} · model: ${AGENT_MODEL}"
echo "               task: ${AGENT_DESC}"
echo "Session:       ${SESSION_ID}"
# FOREIGN and DEAD HISTORY are gone with the directory scan that produced them (S6). Both
# were verdicts about where an agent's METADATA sat, and a target that reaches this line has
# been named by the harness as a teammate of this session — which is the only sense in which
# an agent is ours. `unknown` is unreachable for the same reason: a session with no key of
# its own cannot read a live set and refuses above, before anything is resolved.
echo "Classification: OURS — ${OURS_BECAUSE}."
echo "Contract (roster):  deliverables=${ROSTER_DELIVERABLE:-(none recorded)}  progress=${ROSTER_PROGRESS:-(none recorded)}"
if [ -n "$ADOPTED_FROM" ]; then
  echo "Note:          its working log is filed under the session that launched it (${ADOPTED_FROM})."
fi
echo ""

# ---------- evidence 1: the working log (§2.2 — unfakeable, written by working) ----------
echo "Working log:   ${LOG}"
LOG_MTIME=0
LOG_SIZE=0
if [ -f "$LOG" ]; then
  LOG_MTIME=$(file_mtime "$LOG")
  LOG_SIZE=$(file_size "$LOG")
  NOW=$(date -u +%s)
  echo "  last write:  $(fmt_epoch "$LOG_MTIME")  (age $(fmt_age $((NOW - LOG_MTIME))))"
  echo "  size:        ${LOG_SIZE} bytes"
  LAST_MSG=$(tail -400 "$LOG" 2>/dev/null \
    | jq -R -r 'fromjson? | select(.type=="assistant")
                | ((.message.content // []) | map(select(.type=="text").text) | join(" "))
                | select(length > 0)' 2>/dev/null \
    | tail -1)
  if [ -n "$LAST_MSG" ]; then
    echo "  last message: ${LAST_MSG:0:$MAX_MESSAGE_CHARS}"
  else
    echo "  last message: (none yet — no assistant text in the last 400 lines)"
  fi
else
  echo "  last write:  (no working log on disk yet)"
fi
echo ""

# ---------- evidence 2: repo activity ----------
echo "Repo activity:"
if [ -n "$REPO_ROOT" ]; then
  echo "  root:        ${REPO_ROOT}"
  echo "  HEAD:        $(git -C "$REPO_ROOT" log -1 --format='%h %s' 2>/dev/null)"
  echo "  uncommitted: $(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | grep -c .) path(s)"
else
  echo "  (cwd is not inside a git repository — no repo evidence available)"
fi
echo ""

# ---------- evidence 3: the contracted deliverables (§2.2 — meaning from the contract) ----------
echo "Deliverables:"
if [ -n "$DELIVERABLE_MISMATCH" ]; then
  echo "  (note: the roster recorded a different deliverable set: ${DELIVERABLE_MISMATCH} — not judged)"
fi
# Each deliverable's state is accumulated for the machine line as
# `<state>:<path>`, comma-joined — the same comma-joined path list the roster row
# uses for the same concept (hooks/dispatch-preflight.sh's `deliverable=`), so
# the two machine artifacts in .bionic/tmp/ render one concept one way.
DELIV_STATES=""
add_deliv() { DELIV_STATES="${DELIV_STATES:+$DELIV_STATES,}$1:$(mline_value "$2")"; }
if [ "$#" -eq 0 ]; then
  echo "  (none named on the command line — pass each contracted path as an argument)"
else
  NOW=$(date -u +%s)
  # STAT THE RESOLVED PATH, REPORT THE CONTRACTED ONE. `$dp` is where this command looked;
  # `$d` is what the contract spelled, and it is what the readback and the machine line
  # carry — so the roster, the brief and this output all name the artifact the same way,
  # which is the property the mismatch note above depends on.
  for d in "$@"; do
    dp="$(abs_path "$d")"
    if [ -f "$dp" ]; then
      DSIZE=$(file_size "$dp"); DMTIME=$(file_mtime "$dp")
      if [ "$DSIZE" -eq 0 ]; then
        echo "  ${d} — PRESENT but EMPTY, 0 bytes"
        add_deliv empty "$d"
      else
        echo "  ${d} — PRESENT, ${DSIZE} bytes, last write $(fmt_epoch "$DMTIME") (age $(fmt_age $((NOW - DMTIME))))"
        add_deliv present "$d"
      fi
    elif [ -d "$dp" ]; then
      echo "  ${d} — PRESENT as a directory, $(find "$dp" -type f 2>/dev/null | grep -c .) file(s)"
      add_deliv dir "$d"
    else
      echo "  ${d} — ABSENT"
      add_deliv absent "$d"
    fi
  done
fi

# ---------- evidence 4: the progress artifact (D-6 — the task's own byproducts) ----------
#
# An hour-long command silences the working log for its whole hour: one tool
# call, one result at the end. "No activity for 47 minutes" therefore describes
# a healthy suite and a wedged one identically, and no amount of reading the
# agent will separate them. The separation lives one level DOWN, in the work's
# own byproducts: a contract that requires the long command to accrue output at
# a named path turns "log quiet 47 minutes, progress file grew 12 seconds ago"
# into proof of life (design/orchestrator-subagent-coordination.md §5 D-6).
#
# Printed only when the contract named a path — the section is additive, and
# without the flag this command's output is what it always was.
PROGRESS_STATE="unnamed"
PROGRESS_MTIME=0
if [ "$PROGRESS_NAMED" -eq 1 ]; then
  echo ""
  echo "-- progress artifact (D-6) --"
  if [ -n "$PROGRESS_MISMATCH" ]; then
    echo "  (note: the roster recorded a different progress path: ${PROGRESS_MISMATCH} — not judged)"
  fi
  # Same rule as the deliverables above: stat the resolved path, print the contracted one.
  PROGRESS_ABS="$(abs_path "$PROGRESS_PATH")"
  if [ -e "$PROGRESS_ABS" ]; then
    PMTIME=$(file_mtime "$PROGRESS_ABS")
    PSIZE=$(file_size "$PROGRESS_ABS")
    NOW=$(date -u +%s)
    echo "progress: ${PROGRESS_PATH}  last-write $(fmt_epoch "$PMTIME") ($(fmt_age $((NOW - PMTIME))) ago)  size ${PSIZE}B"
    PROGRESS_STATE="present"; PROGRESS_MTIME="$PMTIME"
  else
    echo "progress: ${PROGRESS_PATH}  ABSENT"
    PROGRESS_STATE="absent"
  fi
  # THE DECLARED CADENCE, beside the age it qualifies. The ratified liveness
  # contract extends the ≥15m rule by one number — "too quiet" means quieter than
  # the AUTHOR'S OWN declaration, not a fixed clock — so the age above is
  # unreadable without it. Printed, never compared: this command decides nothing,
  # and the comparison belongs to whoever is doing the judging (P3's watcher, or
  # the operator reading this).
  if [ -n "$ROSTER_CADENCE" ]; then
    echo "cadence:  ${ROSTER_CADENCE}  (declared in the dispatch contract)"
  fi
fi

# ---------- P2: claimed-process liveness (Liveness contract, ratified 2026-08-05) ----------
#
# Existence only — is any process matching the claimed pattern running right
# now? This is a display fact, exactly like everything else in this command: it
# names nothing about health, only presence. Source is the roster's `claims=`
# field when OURS and no --claims was typed, or the explicit flag when one
# was — same override rule as deliverables and progress.
if [ "$CLAIMS_NAMED" -eq 1 ]; then
  echo ""
  echo "-- claimed process (P2) --"
  echo "claims:   pattern='${CLAIMS_PATTERN}'  source=${CLAIMS_SOURCE}"
  if claims_live "$CLAIMS_PATTERN"; then
    echo "live:     yes — a process matching this pattern exists right now"
  else
    echo "live:     no — no process matching this pattern was found"
  fi
  echo "This is an existence check only. It decides nothing."
fi

echo ""
echo "This command decides nothing. It prints evidence; the judgment is yours."

# ---------- the machine line (slice 4/4 — the recorder's ONLY input) ----------
#
# Last line of a successful run, and the only line any machine reads. Three
# properties earn their place:
#
#   * it is printed HERE, past every refusal path, so its existence IS the proof
#     that an observation ran and produced an evidence tier. The recorder is
#     PostToolUse and reads it out of the tool RESPONSE, so a command the harness
#     refused to dispatch, a command that exited non-zero, and a command that
#     merely MENTIONS this script all leave no line and therefore no record —
#     the "recorded a look but nothing ran" class closed at its root rather than
#     narrowed (tests/cross-gate-agreement.test.sh §C case 6);
#   * it carries the RESOLVED identity and the file facts THIS RUN computed, so
#     the recorder never re-resolves anything. One resolver decides who was
#     looked at, which is what makes the operator's view and the record the same
#     fact rather than two computations that must be kept in agreement (F-1);
#   * `progress_state=unnamed` distinguishes "the contract named no progress
#     artifact" from "it named one and the artifact is missing" — the D-6
#     distinction a blank value would erase.
printf '%s|target=%s|typed=%s|log=%s|mtime=%s|size=%s|deliverables=%s|progress=%s|progress_mtime=%s|progress_state=%s|classification=%s|deliverable_source=%s|progress_source=%s\n' \
  "$MACHINE_SCHEMA" \
  "$(mline_value "$AGENT_ID")" \
  "$(mline_value "$TARGET")" \
  "$(mline_value "$LOG")" \
  "$LOG_MTIME" \
  "$LOG_SIZE" \
  "$DELIV_STATES" \
  "$(mline_value "$PROGRESS_PATH")" \
  "$PROGRESS_MTIME" \
  "$PROGRESS_STATE" \
  "$(mline_value "$CLASSIFICATION")" \
  "$(mline_value "$DELIVERABLE_SOURCE")" \
  "$(mline_value "$PROGRESS_SOURCE")"
exit 0
