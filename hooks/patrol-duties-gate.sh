#!/bin/bash
# THE PATROL-DUTIES WALL — task-dispatch-wall-channel-loss, T5.
#
# Stop. On every orchestrator turn end: if the turn was started by a PATROL TICK,
# refuse the stop once unless the tick's THREE standing duties were performed
# inside it — a subagent-panel refresh (`ListAgents`), a task-list refresh
# (`TaskList`, or a write naming the active plan file), and an ANSWER to any
# `poker: FILL` line the tick printed (the named dispatches, or an explicit
# `fill-declined: <reason>`). Any other turn passes untouched, as does any
# ambiguity along the way.
#
# WHY A WALL AND NOT BETTER WORDING. The duties live in the Patrol prompt today,
# and a prompt is text: it asks. Every rule in this repo that actually binds is a
# wall (memory/rules-are-walls-not-wishes), and the only event that can express
# "this must have happened before the turn ends" is the turn's END. A PreToolUse
# arm cannot say it — at the moment any single tool runs, the turn is not over
# and nothing has been skipped yet. So the predicate is retrospective by
# construction, and Stop is the one channel that can ask it.
#
# WHY ALWAYS-ON, AND WHAT SCOPES IT INSTEAD. This gate was registered in the governing
# skill's frontmatter so that it would be live exactly while that skill was — the duty
# it binds is the skill's own Patrol's. That coupling was the defect, not the design:
# a skill's registrations are looked up per session, so a `/clear`, a compaction or a
# session the skill was never invoked in left the wall installed, green in its own
# suite, and not running. The duty did not stop existing in those sessions; only the
# wall did.
#
# It is registered once in hooks/hooks.json now, on `Stop` — which still fires once per
# orchestrator turn and keeps firing on turns nothing was re-invoked. What scopes it is
# an ON-DISK fact: `session_run` (which was `active_run` until wave-session-bound-run made
# run identity per-session) under the payload's project root. A run is active while
# its plan says so, and that is the same fact that says a Patrol should be ticking.
#
# WHAT A "PATROL TICK" IS, STRUCTURALLY. The tick prompt is composed per session
# by a model and its wording is therefore not a fact anything may key on. What IS
# a fact is the command SKILL.md's Dispatch section makes the first of the
# prompt's reads: `session-poker.sh tick`. That literal in the turn's opening
# user message is the marker — the same structural-not-textual identification
# payload/scripts/lib/patrol.sh uses to recognise a Patrol cron job (T2 judgment
# call (b)), reached independently and agreeing.
#
# WHAT COUNTS, AND WHEN. Only AFTER the tick's own prompt: duties performed in
# some earlier turn are stale by exactly the interval the tick exists to cover.
# Only on the MAIN THREAD: a tool_use inside an agent context (`isSidechain`, or
# a non-empty agent key) belongs to a subagent, and a subagent's ListAgents did
# not refresh the orchestrator's panel — the mirror image of the exclusion
# hooks/session-poker.sh:399-406 makes for the same reason.
#
# THE TASK-LIST FALLBACK IS NOT A CONVENIENCE. The task tools are absent from
# some model/CLI combinations (memory/task-tools-tengu-gate: removed for fable-5
# in CLI 2.1.228–2.1.233), and in those sessions the plan's own ledger IS the
# task list. A wall that demanded `TaskList` there would be unsatisfiable, which
# is the one failure mode a blocking gate must not have. So an Edit/Write/
# NotebookEdit/Bash tool_use whose input names the active plan file discharges
# the same duty.
#
# A SECOND ARM, ADDED FOR bionic 1.4.0 (spec AC-3, plan slice STOPGATES). A `/clear`
# rewrites the session id in place but does not kill a predecessor's cron job — it
# survives and keeps firing into the new conversation (probe A-probe-4). The new
# transcript's very first turn is the literal `<command-name>/clear</command-name>`
# (record/wave-1.4.0-probe.md); a resume is announced the same way, by the literal
# substring `source: resume` this gate's SessionStart sibling
# (hooks/session-start.sh) prints into the title line of its own report, which the
# model reads as context. Either is "a transcript record whose content contains" the
# marker — read as RAW TEXT, not one JSON shape, so this arm does not care whether
# the marker lands on a user prompt, a system entry, or anything else. It does care
# WHO WROTE THE ROW: a `tool_result` is how the content of every file the agent reads
# enters the transcript, and a file is not the CLI announcing a resume, so the marker
# is read off the orchestrator's own rows only (review F2, see $auth below).
#
# THE RULE: since the MOST RECENT such marker, a `CronCreate` tool_use must be
# preceded by a `CronList` tool_use, or the turn refuses — creating a job before
# listing and deleting the stray one leaves two clocks on one project (S5, the
# resume ritual). The scan resets at every marker, so only the ritual for the
# LATEST clear/resume is judged; a Cron call before the marker is not "since" it.
# Agent-context tool_uses are excluded, the same exclusion the tick-duties arm
# already makes, for the same reason. BLOCKS ONCE: this reuses the exact
# `stop_hook_active` mechanism above, unchanged — no new bookkeeping for it.
#
# FAIL DIRECTIONS (pinned by tests/patrol-duties-gate.test.sh):
#   - jq absent                                          -> pass, silent
#   - not a Stop payload (SubagentStop included)          -> pass, silent
#   - stop_hook_active true                               -> pass, silent (blocks ONCE)
#   - no cwd, or it is not a directory                    -> pass, silent
#   - no transcript_path, or no file there, or a symlink  -> pass, silent
#   - a marker older than the scan window (2000 records)  -> pass, silent (fail-open, below)
#   - no user prompt in the transcript at all             -> pass, silent
#   - the last user prompt is not a Patrol tick           -> pass, silent
#   - both duties done since that prompt                  -> pass, silent
#   - either duty missing                                 -> REFUSE, naming which
#   - no `poker: FILL` line in the turn                   -> pass, silent (fill arm inert)
#   - every named slice dispatched, or a decline present  -> pass, silent
#   - a named slice neither dispatched nor declined       -> REFUSE, naming that slice
#   - a marker or a decline read out of a TOOL RESULT      -> ignored (not the orchestrator's)
#   - no clear/resume marker anywhere in the transcript   -> pass, silent (ritual arm inert)
#   - CronList precedes any CronCreate since the marker   -> pass, silent (ritual arm inert)
#   - a CronCreate since the marker with no prior CronList-> REFUSE, naming the ritual
#
# TWO ACCEPTED LIMITS, both a false BLOCK rather than a false silence, and both
# cheap because the refusal is once-only (stop again and the turn ends). First,
# the Stop-time transcript "isn't guaranteed to include the final message ... on
# all versions" (hooks reference, Stop input), so a duty discharged as the very
# last act of the turn may not be on disk when this reads it. Second, a Patrol
# tick that legitimately has nothing to do still owes both duties under this
# gate — which is the contract SKILL.md states, not an accident of the read.
#
# AND THERE IS NO BACKSTOP ABOVE OURS. This used to cite the hooks reference —
# "Claude Code overrides the hook and ends the turn after 8 consecutive blocks"
# — as the net under both limits. It is not one, for the same reason the same
# claim was struck from hooks/patrol-revive.sh (critic C-2, epic-19 w1): this
# gate blocks ONCE PER TURN by design (`stop_hook_active` → pass, below), and
# blocks one per turn are never consecutive, so that override can never engage
# above a hook shaped like this one. What bounds the refusal is the thing
# the reason line already names — do the two duties and stop again — not a
# counter in the CLI.
#
# IT WRITES NOTHING AND DECIDES NOTHING ELSE. No state file, no roster append, no
# stamp: this is a gate, and gates may only read (TDD §3.2). It takes no view on
# whether the tick's WORK was right, only on whether the two duties happened.
#
# Registered once on the Stop channel in hooks/hooks.json, and scoped by ENGAGEMENT — this
# session having invoked canonical-sdlc — not by the repo merely holding an open plan
# (task-engaged-session). The plan still answers "which plan", never "whether".
# [WALL: tests/patrol-duties-gate.test.sh]

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat)

_jq() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }

# ---------- relevance hoist ----------
# SubagentStop is deliberately NOT accepted. A subagent has no Patrol duties, and
# a wall that refused its stop would hold a worker hostage to its orchestrator's
# obligations.
[ "$(_jq '.hook_event_name')" = "Stop" ] || exit 0

# BLOCKS ONCE. Claude Code re-enters the stop with stop_hook_active true after a
# hook blocked it; refusing again would wedge the turn in a loop it has no way
# out of. One refusal names the duties; the second stop is the orchestrator's to
# decide about. That re-entry is also this gate's safety valve: nothing it can
# ever demand is unsatisfiable, because stopping again always passes.
[ "$(_jq '.stop_hook_active')" = "true" ] && exit 0

TRANSCRIPT=$(_jq '.transcript_path')
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && [ ! -L "$TRANSCRIPT" ] || exit 0

# THIS SCRIPT'S OWN DIRECTORY, so the poker the ritual message names is the same
# file a model would actually run — resolved the way hooks/patrol-revive.sh
# resolves its sibling, never through PATH and never a placeholder.
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || HOOK_DIR="$(dirname "$0")"

CWD="${CLAUDE_PROJECT_DIR:-}"
[ -n "$CWD" ] || CWD=$(_jq '.cwd')
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# ---------- the library ----------
#
# One loader idiom, byte-identical in every hook (spec AC-16). FAIL OPEN: this gate
# refuses a STOP, and a stop refused for a missing file is a turn nobody can end.
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
if [ -n "$BIONIC_LIB_MISSING" ]; then loader_fail_open "patrol-duties-gate"; fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/root.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/run.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/session.sh"

PROJECT_DIR=$(project_root "$CWD")

# ---------- THE SESSION KEY ----------
#
# NEW AT task-engaged-session. This gate carried no session id at all — it read the
# transcript and nothing session-keyed — and the engagement switch below is keyed to one.
# Derived exactly as hooks/dispatch-preflight.sh derives it: from the library (design §1,
# env primary and payload witness) so the marker's writer and this reader spell one session
# one way, empty is silent-pass, and the shape is checked before the value is ever
# interpolated into a path. The divergence line is silenced because a bystander session must
# produce no output at all. It serves the tick marker below (AC-22) as well.
SID=$(session_id "$(_jq '.session_id')" 2>/dev/null) || SID=""
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
# (1.3.2 close-out ruling — the arming partition IS the consent boundary). It is also what
# ends this gate's largest cost on a bystander turn: the full-transcript jq pass below never
# starts.
engaged_session "$PROJECT_DIR" "$SID" || exit 0

# ---------- THE RUN PREDICATE (AC-7, AC-8) ----------
#
# Before the transcript is parsed, and that placement is the point. The full-transcript
# jq pass below is this hook's whole cost, and it used to run on every Stop in every
# session on the machine — 32.5ms with no transcript, 44.7ms over a 601-line one, scaling
# with the transcript, to answer a question that is only ever asked inside a run (R-2
# §(c)). Now a project with no open run pays one directory walk.
#
# It also answers "which plan" — the same reader, so this gate and the tick it polices
# cannot disagree about which file the duty is owed against.
#
# IT NO LONGER DECIDES WHETHER THIS GATE ACTS — engagement does (above). Both of this
# gate's duties are owed to a TICK, not to a plan: the ritual arm reads clear/resume
# markers, and the duties and FILL arms fold the tick's own output out of the transcript.
# The plan contributes one thing, a basename that lets a write to the plan file count as
# the task-list refresh, and the fold below already treats an empty name as matching
# nothing. So an engaged session with no plan is policed exactly as one with a plan, minus
# that one alternative way to discharge the refresh.
#
# wave-session-bound-run S5: `active_run` (no session input) is now `session_run`
# (lib/run.sh) — a session BOUND to a plan is policed against THAT plan's basename
# alone, whatever else is open in the root (AC-1); UNBOUND falls back to the
# newest plan exactly as before, and this gate says so once on stderr (AC-3);
# bound to a plan that has since closed is policed exactly as engaged-with-no-plan
# (AC-6) — the basename discharge is the only thing a missing plan costs.
_RUN_VERDICT=$(session_run "$PROJECT_DIR" "$SID")
_RUN_WORD="${_RUN_VERDICT%% *}"
PLAN="${_RUN_VERDICT#* }"
case "$_RUN_WORD" in
  bound-open) : ;;
  fallback)
    echo "patrol-duties-gate: run resolved by newest-plan fallback (session unbound) — $PLAN" >&2
    ;;
  bound-closed)
    echo "patrol-duties-gate: bound plan closed — $PLAN; this session has no open run" >&2
    PLAN=""
    ;;
  none|*)
    PLAN=""
    ;;
esac
PLAN_NAME=""
[ -n "$PLAN" ] && [ -f "$PLAN" ] && PLAN_NAME="$(basename "$PLAN")"

# ---------- the plan's BASENAME ----------
#
# Only the basename is kept. The path a tool_use carries may be absolute, repo-relative
# or cwd-relative depending on which tool wrote it, and the basename is the one form all
# three contain. An empty name matches nothing — guarded at the awk boundary, because an
# empty needle would otherwise make every write in the turn discharge the duty.

# ---------- reading the turn ----------
#
# One pass, two stages. jq flattens each transcript line into at most one record
# per event we care about; awk then folds that stream, resetting at every user
# PROMPT so that what survives to END describes the LAST turn only.
#
# A user-typed entry is a PROMPT only if it carries text. The `user` type is also
# how the CLI records every TOOL RESULT, and treating those as prompts would end
# the tick's turn at its first tool call — the wall would then be permanently
# silent, passing every tick in the fleet while looking installed and green.
#
# Newlines and tabs are squashed inside values because the stream is
# line-and-tab delimited; a prompt is many lines long and would otherwise forge
# records. Nothing downstream reads a value except by substring, so squashing
# costs no fidelity.
# A MARK line is emitted for EITHER marker, and a DECLINE line for the fill duty's
# explicit decline, on any record the ORCHESTRATOR AUTHORED whose text contains it —
# independent of the USER/TOOL typing below, and independent of the record's `type`,
# because the marker is a literal substring search over "a transcript record whose
# content contains" it, not a field read (STOPGATES/1).
#
# WHICH ROWS ARE THE ORCHESTRATOR'S (review F2). Every file the agent reads enters the
# transcript as a `tool_result` element of a `user` record. Read raw, that made a README,
# a fixture or a code comment carrying the literal `fill-declined:` discharge the AC-29
# fill duty nobody had declined — fail-open on the exact wall AC-29 is — and made a file
# carrying the /clear or resume marker force a spurious ritual refusal. So `$auth` below
# is the row's AUTHORED text and these two markers are read only out of it:
#   assistant, or any other type   -> the whole raw line. An assistant record's content is
#                                     the model's own — text, thinking, tool_use inputs —
#                                     and no other type carries a tool result. A
#                                     SessionStart report reaches the transcript as one of
#                                     those other types, which is how `source: resume`
#                                     still arrives (pinned by tests §53).
#   user                           -> the content when it is a STRING (the CLI's own
#                                     command records, the operator's own typing), else
#                                     ONLY the `text` elements of the array. Never a
#                                     `tool_result` element.
#   sidechain / agent-context      -> nothing. A subagent's decline is not the
#                                     orchestrator's, the same exclusion every other arm
#                                     of this gate makes.
#   unparsable                     -> nothing. A line that is not JSON has no author.
# The type-agnostic substring read is unchanged WITHIN a qualifying row; what is scoped is
# which rows qualify.
#
# ONE MORE RAW-TEXT RECORD, DELIBERATELY NOT SCOPED, for the fill duty (AC-29). The tick's
# `poker: FILL <ids>` line arrives as the CONTENT of a Bash tool result — a `user`-typed
# entry whose content is an array, which the prompt rule below deliberately does not treat
# as a prompt, and which the scoping above excludes — so it is read off the RAW line. That
# is the one direction where a planted marker costs a false BLOCK rather than a false
# silence, and this gate blocks once.
#
# The ids are cut at the first `\n` or `"` in the RAW line, which are the escaped newline and
# the closing quote of the JSON string the line is embedded in — so the record carries the
# FILL line and nothing that followed it.
#
# THE WINDOW (review, performance finding 1). This used to read the whole transcript on
# every Stop of an open run — one jq pass from byte zero, ~85 ms of CPU per MB, 4.3 s over
# the 50 MB a long wave session reaches, rising monotonically for the life of the run. Every
# fact this scan needs is a "since the most recent X" fact — the last user prompt, the last
# clear/resume marker, the last FILL line — so a window suffices provided it holds a whole
# orchestrator turn. 2000 lines does: the largest single turn in this repo's own two busiest
# wave transcripts (494cf1b6, b1a850c1, measured 2026-09-03) is 264 records, so the window
# carries ~7.5x the worst turn observed, and 5x hooks/context-spend.sh's `tail -n 400` for a
# scan that must reach further back than that hook's does.
#
# WHAT SCROLLING OUT COSTS, named rather than left to be discovered: when the clear/resume
# marker is older than the window, the ritual arm reads "no marker" and goes INERT — it does
# not refuse. That is FAIL-OPEN, and it is the right direction for a marker whose whole
# purpose is to catch the FIRST stop after a resume: by the time 2000 records have gone by,
# the ritual is either long done or long moot. Same for the tick-duties and fill arms, which
# reset at the last user prompt anyway and can only lose a turn that is 2000 records old.
SCAN_WINDOW_LINES=2000
STREAM=$(tail -n "$SCAN_WINDOW_LINES" "$TRANSCRIPT" 2>/dev/null | jq -Rr '
  . as $line
  | (($line | fromjson?) // null) as $r
  | (
      if $r == null then ""
      elif (($r.isSidechain // false) == true) then ""
      elif (((($r.agentId // $r.agent_id) // "") | tostring) != "") then ""
      elif $r.type == "user" then
        ( if ($r.message.content | type) == "string" then $r.message.content
          else ([$r.message.content[]? | select(.type == "text") | .text] | join(" "))
          end )
      else $line
      end
    ) as $auth
  | (if (($auth // "") | contains("<command-name>/clear</command-name>")) then "MARK\tclear" else empty end),
    (if (($auth // "") | contains("source: resume")) then "MARK\tresume" else empty end),
    (if ($line | contains("poker: FILL ")) then
       "FILL\t" + (($line | split("poker: FILL ")[1] | split("\\n")[0] | split("\"")[0]))
     else empty end),
    (if (($auth // "") | contains("fill-declined:")) then "DECLINE\t1" else empty end),
    (
      ($r // empty)
      | select((.isSidechain // false) != true)
      | select((((.agentId // .agent_id) // "") | tostring) == "")
      | if .type == "user" then
          ( if (.message.content | type) == "string" then .message.content
            else ([.message.content[]? | select(.type == "text") | .text] | join(" "))
            end ) as $t
          | select(($t // "") != "")
          | "USER\t" + ($t | gsub("[\n\t\r]"; " "))
        elif .type == "assistant" then
          .message.content[]?
          | select(.type == "tool_use")
          | "TOOL\t" + (.name // "")
            + "\t" + (((.input.file_path // .input.path // .input.command // "") | tostring) | gsub("[\n\t\r]"; " "))
            + "\t" + (([.input.name?, .input.description?, .input.subagent_type?, .input.prompt?]
                       | map(select(. != null) | tostring) | join(" ")) | gsub("[\n\t\r]"; " "))
        else empty
        end
    )
' 2>/dev/null) || STREAM=""
[ -n "$STREAM" ] || exit 0

# ---------- THE RESUME/CLEAR RITUAL (AC-3), judged FIRST ----------
#
# Folded over the same stream, resetting at every marker so only the ritual for
# the LATEST clear/resume is judged — a Cron call before the marker is not "since"
# it. TOOL rows here are already main-thread-only (the select() above excludes
# sidechain and agentId-carrying entries), the same exclusion the tick-duties fold
# below relies on.
RITUAL=$(printf '%s\n' "$STREAM" | awk -F'\t' '
  BEGIN { marker = 0; listed = 0; violated = 0 }
  $1 == "MARK" { marker = 1; listed = 0; violated = 0; next }
  $1 == "TOOL" {
    if (!marker) next
    if ($2 == "CronList") { listed = 1; next }
    if ($2 == "CronCreate" && !listed) { violated = 1; next }
    next
  }
  END { if (marker && violated) print "block"; else print "quiet" }
')

if [ "$RITUAL" = "block" ]; then
  RITUAL_REASON="This is the first Stop after a /clear or a resume, and the transcript shows a CronCreate with no CronList before it since then. A predecessor Patrol cron survives a /clear and keeps firing into the new conversation — creating a job before listing and deleting the stray one leaves two clocks on one project.

Do the resume ritual, in order, then stop again — this gate blocks once:
  1. CronList
  2. delete every bionic-patrol session=<other> job it lists
  3. CronCreate
  4. bash ${HOOK_DIR}/session-poker.sh arm
  5. … adopt"
  jq -nc --arg r "$RITUAL_REASON" '{decision:"block",reason:$r}'
  exit 0
fi

# ---------- WHAT COUNTS AS A TICK (AC-22) ----------
#
# THE MARKER, NOT THE COMMAND. This gate used to call a turn a tick when the last USER row
# CONTAINED the substring `session-poker.sh tick`. The canonical-sdlc SKILL.md body contains
# that literal (it is the line telling the reader to run it), and the body is injected into
# the transcript as a USER row — so invoking the skill WAS a Patrol tick as far as this gate
# could tell, and the gate then refused the invoking turn for duties no tick had asked for
# (observed twice on session 14dcbee3, 2026-09-03; research-refusal.md §sibling defect).
#
# A tick is now what the patrol prompt was designed to announce: a USER row whose FIRST
# TOKEN is `bionic-patrol session=<session-id[0:8]>` (SKILL.md §The patrol prompt), for THIS
# session. That makes the test positional and session-scoped rather than a substring search,
# so a row that merely quotes the tick command is not a tick, and a predecessor's job still
# firing into this conversation after a /clear is not this session's tick either.
TICK_MARK="bionic-patrol session=${SID:0:8}"

# TICK / LISTAGENTS / TASKLIST, folded over the last turn.
VERDICT=$(printf '%s\n' "$STREAM" | awk -F'\t' -v plan="$PLAN_NAME" -v mark="$TICK_MARK" '
  $1 == "USER" {
    t = $2; sub(/^[ \t]+/, "", t)
    tick = (index(t, mark) == 1)
    la = 0; tl = 0
    next
  }
  $1 == "TOOL" {
    if ($2 == "ListAgents") { la = 1; next }
    if ($2 == "TaskList")   { tl = 1; next }
    if (plan != "" && index($3, plan) > 0) {
      if ($2 == "Edit" || $2 == "Write" || $2 == "NotebookEdit" || $2 == "Bash") tl = 1
    }
    next
  }
  END {
    if (!tick) { print "quiet"; exit }
    if (la && tl) { print "quiet"; exit }
    if (!la && !tl) { print "both"; exit }
    if (!la) { print "listagents"; exit }
    print "tasklist"
  }
')

# ---------- THE THIRD DUTY: a printed FILL is answered before the turn ends (AC-29) ----
#
# WHY THIS IS A WALL AND NOT A LINE IN THE PROMPT. The tick can compute the gap between the
# budget and the roster, and it can name the slices that are ready — but it cannot dispatch,
# and a recommendation nobody is obliged to answer is how this repo's own 1.4.0 wave ran six
# writers against a budget of twenty-two. The turn's END is the only moment at which
# "the FILL went unanswered" is a fact, so it is the moment this asks.
#
# ANSWERED MEANS EITHER: an `Agent` tool_use naming the slice, or an explicit
# `fill-declined: <reason>` anywhere in the turn. The decline is not a loophole — it is the
# point. There are good reasons not to fill (a dependency landing this minute, peers not yet
# idle, a merge in flight), and every one of them is worth one line in the record. What is
# refused is SILENCE.
#
# NAMED, not counted: a turn that dispatched two of three named slices is missing one, and
# the reason says which. An id is matched on a WORD BOUNDARY inside the dispatch's own
# fields — its name, description, subagent_type and prompt — so `ONE` is not found inside
# `PHONE`, and only ids shaped like slice ids (letters, digits, `_`, `.`, `-`) are ever
# echoed back into the refusal. A `.` in an id is a LITERAL dot in that boundary test, not
# the regex wildcard it would otherwise be — see the escape in the fold below.
#
# Folded over the same stream, resetting at every user PROMPT exactly as the duties fold
# above it does, and inert on every turn with no FILL line in it — which is every turn in
# every project whose tick prints none.
FILL_MISSING=$(printf '%s\n' "$STREAM" | awk -F'\t' -v mark="$TICK_MARK" '
  $1 == "USER" {
    t = $2; sub(/^[ \t]+/, "", t)
    tick = (index(t, mark) == 1)
    fills = ""; declined = 0; agents = " "
    next
  }
  $1 == "FILL"    { fills = $2; next }
  $1 == "DECLINE" { declined = 1; next }
  $1 == "TOOL" {
    if ($2 == "Agent") agents = agents $3 " " $4 " "
    next
  }
  END {
    if (!tick || fills == "" || declined) exit
    n = split(fills, ids, /[ \t]+/)
    missing = ""
    for (i = 1; i <= n; i++) {
      id = ids[i]
      if (id !~ /^[A-Za-z0-9_.-]+$/) continue
      # THE ID IS DATA, THE PATTERN IS CODE. The boundary test below is a DYNAMIC regex
      # and the id is spliced into it, so every metacharacter the validity filter above
      # admits has to be neutralised first or it reads as syntax. `.` is the whole class:
      # `-` is special only inside a bracket expression and is spliced outside one, `_`
      # is never special. Unescaped, a FILL for `a.b` was answered by a dispatch naming
      # `axb` — a false negative on the wall, the fail-open direction (review F1).
      pat = id
      gsub(/\./, "[.]", pat)
      if (agents ~ ("(^|[^A-Za-z0-9_.-])" pat "([^A-Za-z0-9_.-]|$)")) continue
      missing = missing (missing == "" ? "" : " ") id
    }
    if (missing != "") print missing
  }
')

if [ -n "$FILL_MISSING" ]; then
  FILL_REASON="Patrol fill unanswered: the tick printed FILL and this turn neither dispatched nor declined ${FILL_MISSING}. Dispatch each named slice, or write a line \"fill-declined: <reason>\" saying why not, then stop again — this gate blocks once."
else
  FILL_REASON=""
fi

# The two folds are judged TOGETHER, so a turn that skipped a duty AND left a FILL
# unanswered is told both things once. Blocking on one and staying silent about the other
# would hide the second behind the one-shot: the next stop passes by design.
if [ "$VERDICT" = "quiet" ] || [ -z "$VERDICT" ]; then
  if [ -n "$FILL_REASON" ]; then
    jq -nc --arg r "$FILL_REASON" '{decision:"block",reason:$r}'
  fi
  exit 0
fi

# ---------- the refusal ----------
#
# THE REASON NAMES WHAT IS MISSING AND NOTHING ELSE. A reason that recites both
# duties whichever one was skipped makes the reader re-derive the answer the gate
# already knows, and a gate that fires on every tick with the same paragraph is
# read as noise inside two ticks. The three duty strings are LITERALS: no payload
# value and no path is interpolated into them. The fill clause is the one
# exception and it carries slice ids read out of the transcript — filtered in the
# fold above to `[A-Za-z0-9_.-]+` and handed to jq through `--arg`, so neither a
# shell nor a JSON quoting surface is opened by them.
case "$VERDICT" in
  both)
    REASON='Patrol duties incomplete: no ListAgents call, and no task-list refresh — TaskList or a plan-ledger write. Do both, then stop again — this gate blocks once.' ;;
  listagents)
    REASON='Patrol duties incomplete: no ListAgents call since this Patrol tick. Refresh the subagent panel, then stop again — this gate blocks once.' ;;
  tasklist)
    REASON='Patrol duties incomplete: no task-list refresh since this Patrol tick — TaskList or a plan-ledger write. Do one, then stop again — this gate blocks once.' ;;
  *)
    exit 0 ;;
esac
[ -n "$FILL_REASON" ] && REASON="$REASON $FILL_REASON"

# The JSON decision payload on STDOUT with exit 0, the form Design (T5) names.
# (hooks/landing-gate.sh refuses through exit 2 + stderr instead; both are live
# Stop-hook block channels in this CLI, and the two gates deliberately do not
# share a mechanism they never share a code path with.)
jq -nc --arg r "$REASON" '{decision:"block",reason:$r}'
exit 0
