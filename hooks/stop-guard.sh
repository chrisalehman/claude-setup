#!/bin/bash
# THE STOP GATE — epic-15 wave-01R, extended at wave-03 slice 4/6. ONE
# registration, PreToolUse|TaskStop. A stop during an active wave is permitted
# only against an observation that is:
#
#   OURS      — this session's (D-1), and the STOPPER'S OWN look, not another
#               actor's borrowed one (D-3, slice 4/6);
#   FRESH     — on both activity channels: the target's working log (D-1) and,
#               where the work contract named one, its progress artifact (D-6,
#               slice 4/6);
#   SPENT     — one observation discharges exactly one stop (D-2).
#
# And it is a stop of an agent THIS SESSION LAUNCHED. A target the session roster
# does not record is refused when addressed by name and permitted when addressed
# by full agent id (AC-6, slice 4/6) — a name is not an identity.
#
# Why a gate at all: a stop is irreversible, and the failure mode it guards is
# the orchestrator's own judgment lapsing mid-drift — so the guarantee cannot
# live in the orchestrator's context (design/orchestrator-subagent-coordination.md
# §3.1). The gate reads state and decides; it never judges. Every judgment
# belongs upstream, in the observation.
#
# THIS SCRIPT NO LONGER WRITES THE RECORDS IT SPENDS (slice 4/4). It used to
# carry a second arm on PreToolUse|Bash that watched for hooks/stop-check.sh in a
# command line and recorded an observation from the command TEXT. That arm fired
# BEFORE the command ran, so it could never know whether one had — and it paid
# for that twice: once when its command-line grammar diverged from the producer's
# and the record named an agent nobody had examined (Step-6 review F-1), and once
# as the standing residual where a refused or mistyped invocation still left a
# consumable record (critic finding A). Recording now happens once, in
# hooks/execution-recorder.sh on PostToolUse, from the machine line the
# observation itself prints. There is exactly ONE writer of this state and this
# gate is purely its reader.
#
# FAIL DIRECTIONS (TDD §7, pinned by tests/stop-guard.test.sh):
#   - the gate is OPEN and SILENT before the active-wave verdict (an
#     unconfigured machine is not a stop decision);
#   - the gate is CLOSED and LOUD after it (irreversibility: the ambiguous case
#     is exactly what the wall exists for).
#
# Exit code 2 = block the tool call entirely in Claude Code hooks.
# [WALL: tests/stop-guard.test.sh]
#
# Registered in skills/canonical-sdlc/SKILL.md frontmatter; live only while that skill is armed.

set -uo pipefail

STATE_VERSION="v1"
# The session roster's schema token. Written by hooks/dispatch-preflight.sh at
# launch and completed by hooks/execution-recorder.sh at execution confirmation;
# read here, and by hooks/stop-check.sh, never written. A row this gate cannot
# read is a row it will not guess at — an unknown version simply does not match,
# which lands on the closed side.
ROSTER_VERSION="v1"
# The bound on this file's length lives with its WRITER, hooks/execution-recorder.sh
# — this gate only reads it, and a reader that also capped it would be a second
# opinion about how much evidence a session may hold.
# THIS SCRIPT'S OWN DIRECTORY, and therefore its siblings'. hooks/stop-check.sh and
# hooks/stop-orders.sh ship beside this gate, so `$0` resolves them identically in a repo
# checkout, in a bootstrap-installed ~/.claude/hooks/, and in an installed plugin payload.
# Deliberately NOT ${CLAUDE_PLUGIN_ROOT}: the harness runs this gate straight out of the
# repo, where no plugin is mounted and that variable does not exist. The fix lines below
# stay absolute — a refusal has to hand an operator something runnable from any cwd.
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || HOOK_DIR="$(dirname "$0")"
OBSERVE_CMD="bash ${HOOK_DIR}/stop-check.sh"
ORDER_CMD="bash ${HOOK_DIR}/stop-orders.sh order"
# HOW LONG A HUMAN'S STOP ORDER IS CURRENT. Duplicated as a literal from its WRITER,
# hooks/stop-orders.sh, and held to it by tests/cross-gate-agreement.test.sh §M, which
# places an order either side of this boundary and asks this gate about it. See the
# discharge block below for why an instruction gets a clock when evidence never does.
ORDER_TTL_SECONDS=1800

INPUT=$(cat)
_jq() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }

TOOL_NAME=$(_jq '.tool_name')

# ---------- portable file facts ----------
# DELIBERATELY DUPLICATED from hooks/stop-check.sh, byte for byte. A shared
# library is rejected by design (TDD §9): a sourced file the installer misses is
# a silently inert wall. The copies are held together by the resolver agreement
# battery in tests/cross-gate-agreement.test.sh §C, which drives both copies —
# the observation's and this one — over one fixture world.
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
file_size()  { stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo 0; }

# RESOLUTION IS NO LONGER A DIRECTORY SCAN (wave-roster-lifecycle S6, D2/D2′). This file
# used to carry `scan_subagent_dirs` — a walk of `agent-*.meta.json` matching a typed
# reference against the filename's id or the file's `.name` — duplicated byte for byte into
# hooks/stop-check.sh. It answered "which agent is this" from RECORDS, and records outlive
# agents: after a `/clear` one agent's meta.json is filed under two session directories at
# once (proven on this machine, research-code-map §4.4), so a bare name went ambiguous while
# the agent was still running and its contract had landed. That is the reported defect.
#
# What decides now is `live_agents_has` (scripts/lib/agents.sh): the newest recorded
# ListAgents answer, which is the harness's own statement about which teammates exist THIS
# TURN. `adopted_subagent_dirs` went with the scan — the widening it performed was a way to
# resolve a predecessor's agents, and a successor's live set names them without it.
#
# The session's own subagent directory, from the payload's transcript_path.
# §2.5 of record/epic-15-kill-interception-experiment.md captures the layout
# verbatim: "<transcript-dir>/<session-id>/subagents/agent-<id>.jsonl". Scoping
# resolution to the CALLER'S session is exact rather than heuristic — a session
# can only stop its own tasks — and hooks/execution-recorder.sh scopes its writes
# the same way, so writer and reader agree by construction.
session_subagents_dir() {  # <transcript-path>
  local tr="$1"
  [ -n "$tr" ] || return 1
  case "$tr" in *.jsonl) : ;; *) return 1 ;; esac
  printf '%s/subagents\n' "${tr%.jsonl}"
}

# One field out of a versioned record, BY KEY. Never by position: the discarded
# run's fixed-field-order parser broke undiagnosably the moment a field was
# added (checklist A6), so an unknown extra field must be inert here.
record_field() {  # <record-line> <key>
  printf '%s' "$1" | tr '|' '\n' | grep "^$2=" | head -1 | cut -d= -f2-
}

record_version() { printf '%s' "$1" | cut -d'|' -f1; }

_bionic_symlink_in_repo() {  # <repo> -> 0 iff $repo/.bionic resolves under this repo's own root
  # spawn-worktree.sh links every spawned tree's .bionic to the main checkout's so a wave
  # shares one plan tree. That one link is trusted when its target resolves INSIDE the
  # same repository — under the parent of the git common dir — which a hostile repo cannot
  # point at another repo's tree (Chris, 2026-08-23, epic-18 w3).
  local repo="$1" target common root
  target="$(cd "$repo/.bionic" 2>/dev/null && pwd -P)" || return 1
  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  root="$(cd "${common%/.git}" 2>/dev/null && pwd -P)" || return 1
  case "$target/" in "$root"/*) return 0 ;; *) return 1 ;; esac
}

state_paths() {  # <repo> -> echoes "<state-dir>|<state-file>"; nonzero if unsafe
  local repo="$1"
  # A hostile repo controls its own .bionic/ contents (TDD §8). A symlink at
  # any level lets a repo choose which file this gate reads its evidence out of —
  # the OPEN direction, which §8 forbids a repo from reaching. Refuse rather than
  # follow: this gate refuses the stop, which is the safe side. The one exception
  # is the spawned-worktree link, accepted only when it stays inside this repo.
  if [ -L "$repo/.bionic" ]; then
    _bionic_symlink_in_repo "$repo" || return 1
  fi
  [ -L "$repo/.bionic/tmp" ] && return 1
  local dir="$repo/.bionic/tmp"
  [ -L "$dir/stop-check.state" ] && return 1
  printf '%s|%s\n' "$dir" "$dir/stop-check.state"
}

# ============================================================
# THE GATE (PreToolUse|TaskStop).
# ============================================================

[ "$TOOL_NAME" = "TaskStop" ] || exit 0

# ---------- before the verdict: OPEN and SILENT ----------

CWD=$(_jq '.cwd')
[ -n "$CWD" ] || exit 0
# ---------- the library ----------
#
# One loader idiom, byte-identical in every hook (spec AC-16); its source of truth is
# payload/scripts/lib/loader.sh. FAIL OPEN: the stop verdict is advisory or repeatable, and a
# hook that refused because a file was missing would hold every turn in every session
# on the machine hostage to it.
BIONIC_LIB_WANT="root.sh run.sh session.sh agents.sh"
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
if [ -n "$BIONIC_LIB_MISSING" ]; then loader_fail_open "stop-guard"; fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/root.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/run.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/session.sh"
# THE ONE READER OF THE LIVE SET (wave-roster-lifecycle S4/S6, D1′). `live_agents_has` is
# this gate's whole resolution rule now, and hooks/stop-check.sh calls the same function on
# the same transcript — which is what makes the two agree by construction rather than by a
# duplicated loop held together with an agreement test (AC-10).
# shellcheck source=/dev/null
. "$BIONIC_LIB/agents.sh"

# THE ROOT (spec AC-10, lib/root.sh). `git rev-parse --show-toplevel` answered with the
# WORKTREE's own root, so a stop raised from a linked worktree looked for the roster
# under a tree the dispatch wall had never written one into — and this gate then passed
# every row in silence, exactly where a wave most needs it. `project_root` maps a linked
# worktree onto its main repository and walks for the nearest real `.bionic`, so the
# reader and the writer land on one address space.
REPO=$(project_root "$CWD")
[ -n "$REPO" ] && [ -d "$REPO" ] || exit 0

# ---------- THE ENGAGEMENT SWITCH — asked before anything else ----------
#
# task-engaged-session: bionic's walls are the RUN's, not the repo's, and a run is entered
# by invoking canonical-sdlc. A session that never did is a bystander here and must not see
# a refusal, an advisory, or a state write from this hook. `engaged_session` (lib/run.sh) is
# true only for a REGULAR file at `.bionic/tmp/engaged-<sid>.state`; every unreadable state —
# absent, symlink, foreign sid, `unknown` — reads as NOT engaged. Silent, exit 0 — which is
# the OPPOSITE direction to everything below it in this file, and deliberately so: §7 makes
# this gate fail CLOSED on an ambiguous identity *inside* a run, while engagement is the
# question of whether there is a run to be inside at all (1.3.2 close-out ruling — the
# arming partition IS the consent boundary).
#
# THE KEY COMES FROM THE LIBRARY (design §1: env primary, payload witness), which is what
# the marker's writer uses, so the two spell one session one way. The raw payload read
# further down keeps this gate's OWN state filenames exactly where they were — moving them
# is not this change's business — and the divergence line is silenced here because a
# bystander session must produce no output at all.
ENGAGED_SID=$(session_id "$(_jq '.session_id')" 2>/dev/null) || ENGAGED_SID=""
engaged_session "$REPO" "$ENGAGED_SID" || exit 0

# ---------- THE RUN PREDICATE IS GONE — ENGAGEMENT SCOPES THIS HOOK (task-engaged-session) --
#
# It used to take the run predicate here — `PLAN=$(active_run <repo>)`, exit 0 on false —
# and nothing below ever consulted
# the value: every rule this gate applies — the addressing carve, the
# observation freshness, the human order — reads the roster and the observation record,
# never the plan.
# The plan answered WHETHER, which is now engagement's question and is answered above.
#
# WHY THIS HOOK MOVES WITH THE DISPATCH WALL RATHER THAN KEEPING A RUN GATE. The four
# members of the roster lifecycle — hooks/dispatch-preflight.sh writes an `intended` row,
# this family confirms it, the landing gate takes its verdict, the stop gate polices the
# stop — have to share one scope or the lifecycle splits: the dispatch wall runs for an
# engaged session with no plan yet (AC-23, a fresh run's Step 0 precedes its plan), and a
# recorder or a gate that stayed silent for want of a plan would leave rows nothing ever
# answers for. A landing contract also OUTLIVES the run that created it — engagement does
# not end when `current:` reaches 9 (plan §Lifecycle) — and a verdict owed on an agent this
# session launched is owed after the run closes too.

# ---------- after the verdict: CLOSED and LOUD ----------

RAW=$(_jq '.tool_input.task_id')

# THE ACTOR REQUESTING THIS STOP (D-3, slice 4/6). A subagent-invoked payload
# carries a top-level `agent_id`; the orchestrator's does not (slice 4/1 probe,
# assumption A resolved FULL). hooks/execution-recorder.sh renders the same field
# the same way into `observer=` — absence as the literal token `orchestrator`, so
# neither side ever has to decide what a blank means. One key, two payloads.
ACTOR=$(_jq '.agent_id')
[ -n "$ACTOR" ] || ACTOR="orchestrator"

# What the Fix line names. It stays RUNNABLE AS PRINTED (Step-6 review R2) on
# every path: a refusal that hands back a foreign target rewrites the TARGET to
# the unambiguous full id, and one that names an unlooked-at progress artifact
# appends the flag that looks at it. Both are still one pasteable command.
FIX_TARGET="${RAW:-<agent-name-or-id>}"
FIX_EXTRA=""

deny() {  # <reason line>...
  echo "BLOCKED: a stop needs a fresh observation of its target — a wave is active." >&2
  echo "" >&2
  local line
  for line in "$@"; do echo "$line" >&2; done
  echo "" >&2
  # Runnable AS PRINTED: a blocked orchestrator pastes this line verbatim, and
  # bracketed placeholders on it became three positional arguments the
  # observation reported as absent deliverables (Step-6 review R2). The optional
  # arguments are described beneath the command, never inside it.
  echo "Fix: ${OBSERVE_CMD} ${FIX_TARGET}${FIX_EXTRA}" >&2
  echo "     (pass each contracted deliverable path as a further argument)" >&2
  echo "Then read what it prints, and stop again if the evidence supports it." >&2
  echo "One observation discharges exactly one stop (D-2), and it goes stale the" >&2
  echo "moment the target writes again (D-1)." >&2
  echo "" >&2
  # THE OTHER TWO WAYS PAST THIS GATE, named at the refusal because a wall that only
  # names its ceremony teaches the ceremony. A landed contract needs neither of them —
  # this gate never asked in the first place.
  echo "If a human ordered this stop, it executes — record the order and stop again:" >&2
  echo "     ${ORDER_CMD} ${FIX_TARGET}" >&2
  echo "A stop the human performs themselves does not reach this gate at all." >&2
  exit 2
}

[ -n "$RAW" ] || deny "The stop names no target: tool_input.task_id is empty."

SID=$(_jq '.session_id')
[ -n "$SID" ] || deny "This stop request carries no session key, so no observation can be proven mine."

TRANSCRIPT=$(_jq '.transcript_path')
SUB=$(session_subagents_dir "$TRANSCRIPT") \
  || deny "This stop request carries no usable transcript path, so its session's agents cannot be resolved."

# ---------- RESOLUTION AGAINST THE LIVE SET (D1′/D2′, AC-9…AC-11) ----------
#
# The state paths are taken FIRST, because resolution now reads the roster — for the agent
# id, and for the rosters an `@session-` alias is checked against. `state_paths` declines a
# symlinked state path, which is the same refusal it always made, one step earlier.
PATHS=$(state_paths "$REPO") \
  || deny "The observation state path is a symlink; nothing here will read or write through it."
STATE_DIR="${PATHS%|*}"; STATE_FILE="${PATHS#*|}"

# THE TYPED REFERENCE, split. `TaskStop` hands this gate the operator's string as typed and
# resolves nothing for it (P5). Three spellings reach here: a bare name, that name with an
# `@session-<launcher>` alias suffix, and the transcript-form agent id.
BASE="${RAW%@*}"; [ -n "$BASE" ] || BASE="$RAW"
ALIAS_SUFFIX=""
case "$RAW" in *@*) ALIAS_SUFFIX="${RAW##*@}" ;; esac

# ONE WALK OF THIS SESSION'S ROSTER, BY BOTH KEYS. The roster is read before the live set
# because the transcript-form id is a spelling only it can translate: the harness's answer
# lists teammates by NAME, so an id has to become a name before the live set can be asked
# about it. Nothing here is a name-oracle — a row supplies an id for a name, never the fact
# that the agent exists, which is the whole of what D1′ moved.
ROSTER_FILE="$STATE_DIR/roster-${SID}.state"
ROW_BY_ID=""; ROW_BY_NAME=""; ROW_WITH_ID=""
# TWO ROWS CAN CARRY ONE AGENT. The dispatch writes the CONTRACT and the recorder writes the
# id one state later, so the last row of a name is the current statement about it while the
# id may sit on an earlier one. They are collected separately rather than picking one row and
# reading both facts off it: preferring the row WITH the id loses a contract recorded after
# it, and preferring the last row loses the id.
roster_walk() {  # <key-name>
  local key="$1" rline rid rname
  ROW_BY_ID=""; ROW_BY_NAME=""; ROW_WITH_ID=""
  [ -f "$ROSTER_FILE" ] || return 0
  [ -L "$ROSTER_FILE" ] && return 0
  while IFS= read -r rline; do
    case "$rline" in '#'*|'') continue ;; esac
    case "$rline" in "roster-state/${ROSTER_VERSION}|"*) : ;; *) continue ;; esac
    rid=$(record_field "$rline" agent_id)
    rname=$(record_field "$rline" name)
    # `confirmed` or `identified`, never `intended` (Step-6 review C-2): the id on an
    # unconfirmed row is a claim about a launch nothing has observed.
    case "$(record_field "$rline" status)" in
      confirmed|identified)
        [ -n "$rid" ] && [ "$rid" = "$key" ] && ROW_BY_ID="$rline"
        [ -n "$rid" ] && [ -n "$rname" ] && [ "$rname" = "$key" ] && ROW_WITH_ID="$rline"
        ;;
    esac
    [ -n "$rname" ] && [ "$rname" = "$key" ] && ROW_BY_NAME="$rline"
  done < "$ROSTER_FILE"
  return 0
}
roster_walk "$BASE"

# An id-shaped target becomes the name its row carries, and that name is what the live set is
# asked about. This keeps the by-id spelling working — it is unambiguous by construction,
# which is why it was the escape hatch — without giving it a second resolution path. The
# second walk is by that NAME, so the contract comes off the same row it would for a bare one.
if [ -n "$ROW_BY_ID" ]; then
  BASE=$(record_field "$ROW_BY_ID" name)
  roster_walk "$BASE"
fi

AGENT_NAME="$BASE"
ROSTER_ROW="$ROW_BY_NAME"
AGENT_ID=""
[ -n "$ROW_WITH_ID" ] && AGENT_ID=$(record_field "$ROW_WITH_ID" agent_id)

# THE LIVE SET DECIDES. `live_agents_has` returns 0 for exactly one live teammate of this
# name, 1 for none, 2 for more than one, and propagates 3 (STALE) / 4 (NONE) unchanged; its
# one stderr line carries the state and the newest answer's age, which is what a refusal owes
# the operator. Captured rather than printed: this gate speaks in refusals, not in diagnostics.
LIVE_LINE=""; LIVE_RC=0
LIVE_LINE=$(live_agents_has "$TRANSCRIPT" "$BASE" 2>&1 >/dev/null) || LIVE_RC=$?
LIVE_STATE="${LIVE_LINE#live-agents: }"; LIVE_STATE="${LIVE_STATE%% *}"
LIVE_AGE="${LIVE_LINE##*age=}"
case "$LIVE_STATE" in fresh|stale|none) : ;; *) LIVE_STATE="none" ;; esac
case "$LIVE_AGE" in ''|*[!0-9]*) LIVE_AGE="none" ;; esac

# THE SHAPE CARVE (T4, AC-6, session-20260815-landing-cleanup). The live set only ever names
# AGENTS, so any OTHER kind of TaskStop target — chief among them a background bash task id
# (A-D4) — is absent from it forever, with no code path back to order_current() below: the
# deny() call is an unconditional `exit 2`, so the escape hatch this gate documents in its own
# header (a human's order executes) would be permanently unreachable for a target of that kind
# (step2-research-a1-a3.md §A3). The carve is by SHAPE, not by trying harder to resolve: refuse
# only a target wearing an AGENT-ADDRESS shape — `name@session-xxxx`, or the transcript form
# `a<hex>` / `a<name>-<16hex>` — since only those could ever have named an Agent-tool dispatch
# (A-D3: TaskStop on an unknown id already fails cleanly on the platform side and stops
# nothing). Anything else gets out of the way — logged once, so this is never a silent gate.
is_address_shaped() {  # <typed> -> 0 if it wears an agent-address shape
  local t="$1"
  case "$t" in *@session-*) return 0 ;; esac
  printf '%s' "$t" | grep -qE '^a[0-9a-f]+$' && return 0
  printf '%s' "$t" | grep -qE '^a.+-[0-9a-f]{16}$' && return 0
  return 1
}

# EVERY ROSTER IN THIS REPO THAT CARRIES THIS NAME, as the addresses the platform's stop
# primitive takes. It is the one spelling this gate prints and the one it accepts (Section R),
# and it is built from the roster FILENAME because that is the session that wrote the row.
accepted_addresses() {  # -> "    <name>@session-xxxxxxxx" per launcher, newline separated
  local f b out=""
  for f in "$STATE_DIR"/roster-*.state; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    grep -qF "|name=${BASE}|" "$f" || continue
    b="${f##*/roster-}"; b="${b%.state}"
    out="${out}    ${BASE}@session-$(printf '%s' "$b" | cut -c1-8)
"
  done
  printf '%s' "$out"
}

# THE CARVE IS ASKED BEFORE THE ANSWER'S STATE (T4), and it has TWO limbs now.
#
# It used to be asked only where the directory scan had found nothing, which is the shape
# `LIVE_RC=1` has here. But the live set can also be UNREADABLE — no ListAgents answer this
# turn — and a target this gate has no standing over must not be trapped by that: a
# background bash task id (A-D4) would otherwise be refused by every stop taken before the
# first ListAgents call of a turn, and the refusal is an unconditional exit, so the escape
# hatch this gate's own header advertises (a human's order executes) would be unreachable for
# it (step2-research-a1-a3.md §A3).
#
# STANDING IS TWO FACTS, either of which is enough. A target wearing an AGENT-ADDRESS shape
# could only ever have named an Agent-tool dispatch. And a target this session's own roster
# carries a row for is one this session dispatched, whatever it is spelled like — which is
# what lets a BARE NAME be refused rather than waved through, and a bare name is the spelling
# the whole of B-2 is about. Neither fact needs the live set, so both survive its absence.
guard_has_standing() {
  is_address_shaped "$RAW" && return 0
  [ -n "$ROW_BY_NAME" ] && return 0
  return 1
}
if [ "$LIVE_RC" -ne 0 ] && [ "$LIVE_RC" -ne 2 ] && ! guard_has_standing; then
  # STRUCTURAL, not remote-controlled (Step-6 review flag 2-B): reachable only when standing
  # is absent, and the `if` keeps that true regardless of what `deny()` does — which an
  # unconditional `exit 2` in another function forty lines away did not.
  echo "PASSTHROUGH: '${RAW}' names no live agent of this session, wears no agent-address shape and appears on no roster row of this session — not an Agent-tool dispatch this gate has standing to guard. The stop proceeds." >&2
  exit 0
fi

case "$LIVE_RC" in
  3|4)
    # A STALE OR ABSENT ANSWER IS NOT AN EMPTY SET. The reader still prints a stale answer's
    # teammates, deliberately, so that a caller which misread the status over-counts rather
    # than concluding "all gone" — but only a FRESH answer is a statement about now, and this
    # gate refuses on anything else. The model is the only thing that can ask again, so the
    # fix is named and the newest answer's age is printed with it.
    deny "Target '${RAW}' cannot be resolved: this session has no fresh ListAgents answer." \
         "    newest answer: ${LIVE_STATE}   ·   age: ${LIVE_AGE}" \
         "The live set belongs to the harness and only the model can ask for it (D1′), so this" \
         "gate reads the answer rather than guessing at it: call ListAgents, then stop." \
         "An answer recorded before the last user prompt is not a statement about now."
    ;;
  2)
    # TWO LIVE TEAMMATES OF ONE NAME. The alias cannot rescue this: it must resolve to the
    # same SINGLE entry as the bare name (D2′), so there is no spelling of this target the
    # gate can accept. Both entries are printed as the harness reported them.
    #
    # MATCHED BY FIELD EQUALITY, never as a regular expression (Step-6 security review S-5,
    # third instance — stop-orders.sh and stop-check.sh carry the same fix). `BASE` is the
    # operator's typed target; a `.`, `*` or `[` in it would over-match and this refusal
    # would report a count and a listing that are not the ambiguity it actually found.
    LIVE_DUPES=$(live_agents "$TRANSCRIPT" 2>/dev/null | awk -F'|' -v want="$BASE" '$1 == want') || LIVE_DUPES=""
    LIVE_N=0
    [ -n "$LIVE_DUPES" ] && LIVE_N=$(printf '%s\n' "$LIVE_DUPES" | grep -c .)
    deny "Target '${RAW}' is ambiguous: ${LIVE_N} live agents answer to '${BASE}'." \
         "The harness reports them as:" \
         "$(printf '%s\n' "$LIVE_DUPES" | sed 's/^/    /')" \
         "A name is not an identity, and the @session- alias cannot separate these either — it" \
         "is accepted only when the bare name resolves to exactly ONE live entry. Stop it" \
         "yourself, or record a human order for the one you mean."
    ;;
  1)
    # Naming the SCOPE is what makes this refusal clearable (Step-6 review R4). Only a target
    # this gate has standing over reaches here — the carve above returned for every other.
    deny "Target '${RAW}' is not live: the fresh ListAgents answer names no teammate '${BASE}'." \
         "The platform hands this gate the name AS TYPED and resolves nothing for it (P5)." \
         "What resolves here is the harness's own answer about which teammates exist now —" \
         "not metadata on disk, which outlives the agents that wrote it. An agent that has" \
         "already finished is not in that answer and does not need stopping. If you expected" \
         "it there, call ListAgents and read what came back."
    ;;
esac

# ---------- AC-11: `name@session-<launcher>` IS AN ALIAS, AND ONLY THAT ----------
#
# The suffix is the spelling the platform's stop primitive takes for a teammate and the only
# one an operator can actually type (field data 2026-08-11), so it has to be accepted. What it
# is NOT is a second way to resolve: the bare name has already resolved to exactly one live
# entry above, and this clause only asks whether the launcher the suffix names is one that
# launched something of that name. The check is the launcher's own roster file
# (`roster-<sid>*.state` carrying `|name=<base>|`) — an eight-character prefix is what the
# platform prints, so the filename is matched by prefix — or this session's own row, whose
# `teammate_id=` records the exact address `adopt` printed for a taken-over agent.
if [ -n "$ALIAS_SUFFIX" ]; then
  ROSTER_TEAMMATE=$(record_field "$ROSTER_ROW" teammate_id)
  ALIAS_OK=0
  if [ -n "$ROSTER_TEAMMATE" ] && [ "$RAW" = "$ROSTER_TEAMMATE" ]; then
    ALIAS_OK=1
  else
    case "$ALIAS_SUFFIX" in
      session-*)
        ALIAS_WANT="${ALIAS_SUFFIX#session-}"
        case "$ALIAS_WANT" in
          ''|*[!A-Za-z0-9-]*) : ;;
          *)
            for _af in "$STATE_DIR"/roster-"$ALIAS_WANT"*.state; do
              [ -f "$_af" ] || continue
              [ -L "$_af" ] && continue
              grep -qF "|name=${BASE}|" "$_af" || continue
              ALIAS_OK=1
              break
            done
            ;;
        esac
        ;;
    esac
  fi
  if [ "$ALIAS_OK" -eq 0 ]; then
    ACCEPTED=$(accepted_addresses)
    [ -n "$ACCEPTED" ] || ACCEPTED="    (no roster in this repo carries the name '${BASE}')
"
    deny "Target '${RAW}' is not an accepted alias for '${BASE}'." \
         "An alias suffix names the session that LAUNCHED the agent, spelled" \
         "@session-<first eight of that session's id>, and it is checked against that" \
         "session's own roster: the roster named here does not carry a row for '${BASE}'." \
         "A suffix naming any other session is a guess wearing an identity's shape." \
         "The spellings this gate accepts for it are:" \
         "${ACCEPTED%
}"
  fi
fi

# ---------- WHERE THE WORKING LOG IS, once the target has resolved ----------
#
# The id and the session the log is filed under both come from the ROSTER ROW, which is the
# only record that ever knew them: the harness's answer lists names, and the directory scan
# that used to supply an id is what this slice deleted. `adopted_from` names the session that
# LAUNCHED an agent this one took over after a `/clear` — the log stays filed there, and the
# row is where that fact was written down (session-poker.sh `adopt`).
AFROM=$(record_field "$ROSTER_ROW" adopted_from)
case "$AFROM" in *[!A-Za-z0-9-]*) AFROM="" ;; esac
if [ -n "$AFROM" ]; then
  LOG_DIR="${TRANSCRIPT%/*}/$AFROM/subagents"
else
  LOG_DIR="$SUB"
fi

# HOW THE OPERATOR ADDRESSES THIS AGENT, in a form the platform's stop primitive accepts
# (epic-16 wave-02 slice S3, from field data 2026-08-11). The roster's recorded teammate
# address wins; the constructed form is the fallback, and it is built from the session that
# launched the agent, because that is the session the address names.
ROSTER_TEAMMATE=$(record_field "$ROSTER_ROW" teammate_id)
STOP_ADDRESS="$ROSTER_TEAMMATE"
if [ -z "$STOP_ADDRESS" ]; then
  STOP_ADDRESS="${AGENT_NAME}@session-$(printf '%s' "${AFROM:-$SID}" | cut -c1-8)"
fi

# ---------- epic-16 wave-02: FACTS DISCHARGE THE STOP (R2), ORDERS EXECUTE (R3) ----------
#
# The ceremony below was never the point. The point was that a stop not destroy work
# nobody had looked at — and when the contract has LANDED, the artifact on disk answers
# that better than any look can, because it cannot go stale and nobody has to remember to
# take it. Wave-01 built the reader for exactly this question and gave it no authority:
# `hooks/session-sweeper.sh verdict` is a stateless read of the disk, and this gate
# CONSUMES it rather than forming a second opinion, the same way hooks/landing-gate.sh
# does. A gate with its own copy of the predicate can disagree with the verb an
# orchestrator reads by hand, and the two answers would be given to different people about
# the same contract.
#
# WHAT DISCHARGES, and why each is a fact rather than a ritual:
#   an ORDER    — a human asked for this stop. Not evidence, and not a claim the work
#                 landed: an instruction, which this gate has no standing to argue with.
#                 It reports what is being given up and gets out of the way.
#   an ACK      — the orchestrator verified this agent's completion and made that durable.
#                 It is the ONLY thing that can close a row which declared no
#                 machine-visible artifact, which is the job it exists for. It arrives as
#                 `acked=` on the verdict's own line (epic-16 wave-02 S9): this gate used to
#                 open the sweeper's ledger through a private copy of a reader, one of three
#                 such copies in the fleet, and the verb it was already running for `state=`
#                 owns that file. One reader, one normalization of the name, one answer.
#   MET/WAIVED  — the contract landed, or was explicitly waived at dispatch.
#
# WHAT DOES NOT: a MET over a row that DECLARED NOTHING. The verb calls such a row MET
# correctly — it names nothing to hold the agent to — but that is an absence of a contract,
# not a landing, and discharging on it would open the gate for every contract-less
# dispatch on a fact nobody produced. AC-1 spells MET as "artifact delivered"; ack closes
# the rest. Nothing else changes: a live agent with an unmet contract meets the same arc
# it met before, which is what Sections 4–10 of the suite still pin.
#
# AND AN ACK FOR A NAME NO ROSTER ROW CARRIES no longer discharges anything here, which is
# the one behaviour S9's promotion moved. The ack verb records such a name with a warning
# and holds it "exempt the moment a row of that name appears" — the ack closes a ROW — and
# with the answer riding a per-row verdict line there is no row for it to ride. This gate
# was the only reader that had been closing on the bare name; the landing gate passes such a
# stop for an unrelated reason and the stand-down never sees one, so this is the reading all
# three now share. Pinned in the suite beside its paired positive.

SWEEPER="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/session-sweeper.sh"
ORDERS_FILE="$STATE_DIR/stop-orders-${SID}.state"

V_TAKEN=0; V_STATE=""; V_DETAIL=""; V_ACKED=""
take_verdict() {
  [ "$V_TAKEN" -eq 1 ] && return 0
  V_TAKEN=1
  [ -f "$SWEEPER" ] || return 0
  [ -n "$AGENT_NAME" ] || return 0
  # A NAME THAT CLEANS TO NOTHING WIDENS THE VERB, exactly as it does at the landing gate
  # (Step-6 critic F-1): the verdict scopes on the sweeper's clean() of this value, and a
  # name made only of the characters it folds scopes to the EMPTY predicate — one line per
  # roster row, the first of which is some other agent's contract. Fold the same set and
  # decline to ask rather than ask the wrong question.
  case "$(printf '%s' "$AGENT_NAME" | tr -d '[:space:][:cntrl:]|')" in "") return 0 ;; esac
  local out line
  out=$( cd "$REPO" 2>/dev/null || exit 9
         CLAUDE_CODE_SESSION_ID="$SID" bash "$SWEEPER" verdict "$AGENT_NAME" 2>/dev/null )
  line=$(printf '%s\n' "$out" | grep -F 'landing-verdict/v1|' | head -1)
  [ -n "$line" ] || return 0
  V_STATE=$(record_field "$line" state)
  V_DETAIL=$(record_field "$line" detail)
  V_ACKED=$(record_field "$line" acked)
  return 0
}

# A HUMAN'S ORDER, and the one clock in this gate that belongs. D-1 refuses to put a window
# on EVIDENCE, and that refusal stands: an observation is stale the moment its subject
# writes, however recent, and good however old while the subject is dormant. An INSTRUCTION
# is the other kind of thing — it is current when it is given and it stops being current,
# and a standing order would open this gate for a name some later dispatch reuses. The
# window is generous, the fail direction is the closed one (an expired order leaves the
# ceremony exactly where it was), and the writer is hooks/stop-orders.sh.
order_current() {
  local f="$ORDERS_FILE" line t e now delta
  [ -L "$f" ] && return 1
  [ -f "$f" ] || return 1
  now=$(date -u +%s)
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "stop-order/v1|"*) : ;; *) continue ;; esac
    t=$(record_field "$line" target)
    [ -n "$t" ] || continue
    # The order may name what the operator typed, the agent's name, or its id: all three
    # are things a human says out loud, and an order that resolved to none of them would be
    # a wall built out of spelling.
    [ "$t" = "$RAW" ] || [ "$t" = "$AGENT_NAME" ] || [ "$t" = "$AGENT_ID" ] || continue
    e=$(record_field "$line" epoch)
    case "$e" in ''|*[!0-9]*) continue ;; esac
    delta=$((now - e))
    # A future-dated order is a skewed clock or a hand-edited file; a small tolerance
    # absorbs the first and nothing here honours the second indefinitely.
    [ "$delta" -le "$ORDER_TTL_SECONDS" ] && [ "$delta" -ge -60 ] && return 0
  done < "$f"
  return 1
}

if order_current; then
  take_verdict
  # ONE LINE, and it is information rather than a verdict on the operator. R3: a
  # user-ordered stop executes at once; what an unmet contract earns is a sentence naming
  # what is being given up, never a refusal.
  if [ -z "$V_STATE" ]; then
    echo "STOP ORDERED — executing. No contract row of this name is on the session roster." >&2
  elif [ "$V_STATE" = "MET" ] || [ "$V_STATE" = "WAIVED" ]; then
    echo "STOP ORDERED — executing. Its contract stands ${V_STATE}: nothing is given up." >&2
  else
    echo "STOP ORDERED — executing. Contract ${V_STATE}, giving up: ${V_DETAIL}" >&2
  fi
  exit 0
fi

take_verdict
[ "$V_ACKED" = "yes" ] && exit 0
case "$V_STATE" in
  WAIVED) exit 0 ;;
  MET)    [ -n "$(record_field "$ROSTER_ROW" deliverable)" ] && exit 0 ;;
esac

# ---------- THE OBSERVATION CHANNEL NEEDS AN AGENT ID, AND THE ROSTER OWNS IT ----------
#
# Placed AFTER the discharge set on purpose. An ack, a waiver and a landed contract are facts
# about the ROW, and a row can be discharged without anyone ever having resolved the agent's
# working log — which is the whole point of a landing (epic-16 wave-02 R2). What needs the id
# is the observation: the record is keyed on it, and the log it compares is
# `<session>/subagents/agent-<id>.jsonl`.
#
# Since the directory scan is gone, the roster row is the only thing that knows the id, and a
# `confirmed`/`identified` row is what carries it (an `intended` row's id is a claim about a
# launch nothing has observed — Step-6 review C-2). A live agent with no such row is refused
# rather than passed: it is inside a run, and §7 puts this gate on the CLOSED side of anything
# it cannot establish. The refusal names the missing fact instead of demanding a look that
# cannot be taken, and both other ways past this gate are printed beneath it as always.
if [ -z "$AGENT_ID" ]; then
  deny "Target '${RAW}' is live, but this session's roster carries no agent id for '${AGENT_NAME}'." \
       "An observation is a look at a particular agent's working log, and the log is filed" \
       "under its agent id — which a dispatch records on its roster row when the agent starts" \
       "(status \`identified\`), and which nothing else in this repo knows. Without it there is" \
       "no evidence channel for this target, so there is nothing that could discharge the stop." \
       "If this agent was launched outside bionic's dispatch, stop it yourself or record an order."
fi

LOG="$LOG_DIR/agent-${AGENT_ID}.jsonl"

[ -f "$STATE_FILE" ] \
  || deny "No observation has been recorded in this repo at all."

# Find this target's record. A record for the target under another session key
# or another schema version is reported for what it is — never guessed at.
RECORD=""; FOREIGN=""; BAD_VERSION=""
while IFS= read -r line; do
  case "$line" in '#'*|'') continue ;; esac
  [ "$(record_field "$line" target)" = "$AGENT_ID" ] || continue
  if [ "$(record_version "$line")" != "$STATE_VERSION" ]; then
    BAD_VERSION=$(record_version "$line"); continue
  fi
  if [ "$(record_field "$line" session)" != "$SID" ]; then
    FOREIGN=$(record_field "$line" session); continue
  fi
  RECORD="$line"
done < "$STATE_FILE"

if [ -z "$RECORD" ]; then
  [ -n "$BAD_VERSION" ] && deny \
    "The only observation of '${RAW}' carries schema version '${BAD_VERSION}', which this gate does not read." \
    "A record it cannot read is a record it will not trust. Observe again."
  [ -n "$FOREIGN" ] && deny \
    "The only observation of '${RAW}' was recorded by a different session (${FOREIGN})." \
    "Another session's look is not evidence that I looked."
  deny "No observation of '${RAW}' (${AGENT_ID}) has been recorded by this session."
fi

# ---------- D-3: the look must be the STOPPER'S OWN (AC-4) ----------
#
# D-1 made an observation perishable. It never made one ATTRIBUTABLE: any record
# for the target discharged any actor's stop, so a subagent's look could pay for
# the orchestrator's stop and neither had seen what the other saw. Same session,
# so the session key above says nothing about it — the actor is a finer grain
# than the session, and it is the grain the judgment happens at, because the
# reader of the evidence is who decides.
#
# A record with no observer at all cannot prove this either way, and unprovable
# lands on the closed side (§7): the cost is one re-observation.
REC_OBSERVER=$(record_field "$RECORD" observer)
if [ -z "$REC_OBSERVER" ]; then
  deny "The observation of '${RAW}' records no observer, so it cannot be shown to be yours." \
       "A look nobody signed is not evidence that YOU looked (D-3). Observe again."
fi
if [ "$REC_OBSERVER" != "$ACTOR" ]; then
  deny "The observation of '${RAW}' was made by a different actor." \
       "    it was looked at by:  ${REC_OBSERVER}" \
       "    this stop comes from: ${ACTOR}" \
       "A look you did not take is not evidence that you looked (D-3): the reader of the" \
       "evidence is who decides, and that reader has to be you. Take your own look."
fi

# ---------- D-1: freshness by ACTIVITY BOUNDARY ----------
#
# An observation is a snapshot of the evidence tier; it stops being true the
# moment the evidence changes, and the working log says precisely when that is —
# the agent's next write. No clock window appears anywhere in this comparison:
# dormant since the observation is valid HOWEVER OLD, and one write after it is
# stale immediately. Any difference in the log counts, not only a later mtime —
# a rewritten or truncated log is a changed log.

REC_LOG=$(record_field "$RECORD" log)
REC_MTIME=$(record_field "$RECORD" mtime)
REC_SIZE=$(record_field "$RECORD" size)

NOW_MTIME=0; NOW_SIZE=0
if [ -f "$LOG" ]; then NOW_MTIME=$(file_mtime "$LOG"); NOW_SIZE=$(file_size "$LOG"); fi

if [ "$REC_LOG" != "$LOG" ]; then
  deny "The observation of '${RAW}' recorded a different working log than the one that resolves now." \
       "Something about this target's identity changed since you looked."
fi

if [ "$NOW_MTIME" != "$REC_MTIME" ] || [ "$NOW_SIZE" != "$REC_SIZE" ]; then
  deny "'${RAW}' has written to its working log SINCE your observation, so that observation is stale." \
       "(Any CHANGE counts, not only a later write: a truncated or rewritten log is a changed log.)" \
       "Its evidence tier now includes work you have not seen — which may be the very work a stop would destroy." \
       "This is an activity boundary, not a timer: an agent dormant since your look stays stoppable however long ago it was."
fi

# ---------- D-6: the contracted progress artifact is the SECOND activity channel (AC-5) ----------
#
# The comparison above watches one channel, and an agent that spends forty
# minutes inside a single tool call writes nothing to it. "Dormant since your
# look" is then true of a wedged agent and a working one alike — and the work
# contract's own progress artifact, the one thing that separates them, counted
# for nothing here. The rule is the log's rule, applied to the second channel:
# any activity after the look stales the look.
#
# THE PATH COMES OUT OF THE RECORD, not out of a second resolution. The
# observation already resolved it under the precedence slice 4/5 fixed (an
# explicit --progress overrides the roster's row), and re-deriving it here would
# be a second parser answering the same question — the F-1 divergence class this
# wave closed elsewhere. What the roster is still consulted for is the one thing
# the record cannot say: that a contracted channel was never looked at at all.
#
# A relative path is resolved against the REPO ROOT, which is where the contract
# is written from and where the observation runs; the resolved path is printed in
# the refusal so the comparison is never a hidden one.
REC_PROGRESS=$(record_field "$RECORD" progress)
REC_PMTIME=$(record_field "$RECORD" progress_mtime)
REC_PSTATE=$(record_field "$RECORD" progress_state)

abs_progress() {  # <path> -> absolute
  case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$REPO" "$1" ;; esac
}

case "$REC_PSTATE" in
  present|absent)
    if [ -n "$REC_PROGRESS" ]; then
      PROG_ABS=$(abs_progress "$REC_PROGRESS")
      NOW_PSTATE="absent"; NOW_PMTIME=0
      if [ -e "$PROG_ABS" ]; then NOW_PSTATE="present"; NOW_PMTIME=$(file_mtime "$PROG_ABS"); fi
      if [ "$NOW_PSTATE" != "$REC_PSTATE" ] || [ "$NOW_PMTIME" != "$REC_PMTIME" ]; then
        deny "'${RAW}' has written to its contracted PROGRESS ARTIFACT since your observation," \
             "so that observation is stale." \
             "    artifact: ${PROG_ABS}" \
             "    at your look: ${REC_PSTATE} (mtime ${REC_PMTIME})   ·   now: ${NOW_PSTATE} (mtime ${NOW_PMTIME})" \
             "This is the second activity channel (D-6): a long-running command silences the" \
             "working log for its whole duration, and the progress artifact is what tells a" \
             "wedged agent from a working one. It is an activity boundary, not a timer."
      fi
    fi
    ;;
  *)
    # The look never opened a contracted channel. An artifact nobody looked at can
    # never go stale, so without this the check above is dodgeable by simply
    # looking wrong — which is the ordinary case whenever the observation ran
    # without its own session key and so never saw the roster at all.
    if [ -n "$ROSTER_ROW" ]; then
      ROSTER_PROGRESS=$(record_field "$ROSTER_ROW" progress)
      if [ -n "$ROSTER_PROGRESS" ]; then
        FIX_EXTRA=" --progress ${ROSTER_PROGRESS}"
        deny "The work contract for '${RAW}' names a progress artifact your observation never looked at." \
             "    contracted progress: ${ROSTER_PROGRESS}   (from this session's roster)" \
             "An observation that skips a contracted channel cannot be staled by it, so it is" \
             "not evidence about the work this stop would end (D-6). Look at it, then stop."
      fi
    fi
    ;;
esac

# ---------- D-2: consume on stop ----------
#
# One observation is evidence about one target at one moment. Letting the record
# ride for repeated stops re-admits staleness through the side door, so it is
# spent here, before the stop happens. A REFUSED stop consumes nothing: every
# path above exits without touching the file.

LOCK="$STATE_DIR/.stop-check.lock"
tries=0
reclaimed=0
# The wait is BOUNDED: one stale-lock reclaim, then a refusal. `mkdir` fails for
# reasons no reclaim can fix — an unwritable $STATE_DIR is repo-controlled — and
# `rm -rf` of an absent path succeeds, so an unbounded reclaim-and-retry loop
# never terminates and this gate would render no verdict at all (Step-6 review
# S2/A3). §7 gives this side its direction: after the active-wave verdict the
# stop gate is CLOSED and loud, so a wait that runs out refuses.
while ! mkdir "$LOCK" 2>/dev/null; do
  tries=$((tries + 1))
  if [ "$tries" -gt 20 ]; then
    if [ "$reclaimed" -eq 0 ] && [ -d "$LOCK" ]; then
      now=$(date -u +%s)
      if [ $((now - $(file_mtime "$LOCK"))) -gt 30 ]; then
        reclaimed=1; tries=0
        rm -rf "$LOCK" 2>/dev/null
        continue
      fi
    fi
    deny "The observation record could not be consumed (the state lock at $STATE_DIR could not be taken), and an unconsumed record would discharge a second stop." \
         "Either another writer holds it, or this repo's .bionic/tmp is not writable by you."
  fi
  sleep 0.1 2>/dev/null || sleep 1
done

TMP=$(mktemp "$STATE_DIR/.stop-check.XXXXXX" 2>/dev/null) || {
  rm -rf "$LOCK"
  deny "The observation record could not be consumed (no writable temp file), and an unconsumed record would discharge a second stop."
}
{
  printf '# bionic observation records — schema stop-check-state/%s\n' "$STATE_VERSION"
  while IFS= read -r line; do
    case "$line" in '#'*|'') continue ;; esac
    [ "$line" = "$RECORD" ] && continue
    printf '%s\n' "$line"
  done < "$STATE_FILE"
} > "$TMP" 2>/dev/null
# The rename is the third way the consume can fail, and it fails the same way as
# its two siblings above: CLOSED. Permitting the stop here would leave the record
# intact, and that one observation would then discharge every later stop of this
# target — D-2 broken at the only line that can break it (Step-6 review C3/A2).
mv -f "$TMP" "$STATE_FILE" 2>/dev/null || {
  rm -f "$TMP"
  rm -rf "$LOCK"
  deny "The observation record could not be consumed (the state file could not be replaced), and an unconsumed record would discharge a second stop."
}
rm -rf "$LOCK"

exit 0
