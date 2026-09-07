#!/bin/bash
# BACKGROUND-SUITE GUARD — a subagent may not run a suite where nobody reads the output.
# (B-9, wave-bionic-1.3.2; spec R-9, AC-23/AC-24.)
#
# THE DEFECT. A dispatched agent that runs `bash tests/run.sh` with the Bash tool's
# `run_in_background: true` gets a shell id back instead of a result. The suite runs, the
# agent's turn ends, and the evidence the slice was dispatched to produce exists nowhere:
# no file, no transcript, no exit status anyone read. The fix the role files carry in prose
# — foreground, bounded by the Bash tool's own `timeout` parameter, output tee'd to an
# evidence log — is a rule, and a rule that only lives in prose is a wish. This is the wall.
#
# WHAT IT REFUSES. Exactly one shape: a Bash call whose `tool_input.run_in_background` is
# `true` AND whose command is suite-class by payload/scripts/lib/cmd-class.sh. Everything
# else exits 0 in silence — a backgrounded `git status`, a foreground suite, and a suite
# whose `run_in_background` key is simply absent.
#
# ABSENT, NOT FALSE. The CLI omits `run_in_background` from `tool_input` when the caller
# did not set it (@anthropic-ai/claude-code 2.1.251, sdk-tools.d.ts:722 declares it
# optional on the Bash tool input), so the test is `== true` and never `!= false`.
#
# WHERE IT LIVES. hooks/hooks.json, PreToolUse|Bash, BEHIND hooks/agent-context-guard.sh —
# so it is alive only inside an agent context of a session that is armed (design D2, Chris
# 2026-08-30). The main thread is already walled by hooks/farm-out-reminder.sh on the skill
# channel, which refuses a suite there whether backgrounded or not; registering this raw
# as well would refuse background suites in every session on the machine, bionic or not.
# The guard in front owns `agent_id` and the roster; this file re-checks neither, which is
# what lets the positive controls in tests/cmd-class.test.sh drive it straight.
#
# Exit 2 + stderr = block the tool call, the protect-main.sh convention. Exit 0 otherwise.
# [WALL: tests/cmd-class.test.sh]

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat) || exit 0
[ -n "$INPUT" ] || exit 0

_jq() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null || printf ''; }

[ "$(_jq '.tool_name')" = "Bash" ] || exit 0
COMMAND=$(_jq '.tool_input.command')
[ -n "$COMMAND" ] || exit 0

# TWO ARMS NOW LIVE IN THIS FILE, and the cheap pre-filter is their union.
#
#   B-9 (AC-23)  a BACKGROUNDED suite, wherever it is run from — nobody reads the result.
#   S13 (AC-21)  a suite OUTSIDE THE ROW`S BUDGET, inside a dispatched agent — foreground
#                or not, because an extra full-tree run costs 40 minutes either way.
#
# The first needs no agent context (its own suite drives it straight with a main-thread
# payload as a positive control); the second needs nothing but one. So the filter is
# either-or, and a main-thread foreground command still leaves this hook before it loads
# a library — which is what keeps an always-on hooks.json registration cheap.
IS_BACKGROUND=no
[ "$(_jq '.tool_input.run_in_background|tostring')" = "true" ] && IS_BACKGROUND=yes
# THE ACTOR (design D1, slice 4/1 probe): an agent-context payload carries a top-level
# `agent_id`, a main-thread one does not. hooks/stop-guard.sh reads the same field the
# same way.
ACTOR=$(_jq '.agent_id')
[ "$IS_BACKGROUND" = yes ] || [ -n "$ACTOR" ] || exit 0

# ---------- the command reader ----------
#
# One loader idiom, byte-identical in every hook; its source of truth is
# payload/scripts/lib/loader.sh, and tests/hook-adoption.test.sh pins this copy
# against it. The idiom heals before it fails: a library damaged beside this hook is
# still found in the marketplace source tree or the newest plugin-cache version.
#
# FAIL OPEN (design ledger S4, bionic 1.4.0). It refused until 1.4.0, on the reasoning
# the two irreversible-action walls still use. It is not one of them: what this guard
# prevents is a suite whose OUTPUT nobody reads, which costs a re-run — reversible, and
# cheap next to refusing every backgrounded command in every session on the machine
# because one file is missing. The failure directions in this repo are chosen by the
# cost of the mistake, never uniformly.
BIONIC_LIB_WANT="cmd-class.sh root.sh run.sh session.sh"
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
if [ -n "$BIONIC_LIB_MISSING" ]; then loader_fail_open "background-suite-guard"; fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/cmd-class.sh"
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
# [WALL: tests/cmd-class.test.sh]
#
# ASKED HERE TOO, though hooks/agent-context-guard.sh in front asks the same question:
# that guard owns the agent context and the roster, this one is driven straight by its
# own suite, and a wall whose scope depends on a caller remembering to check it is a
# wall with no scope of its own.
BSG_CWD=$(_jq '.cwd')
[ -n "$BSG_CWD" ] || BSG_CWD=$(pwd)
BSG_REPO=$(project_root "$BSG_CWD")
BSG_SID=$(session_id "$(_jq '.session_id')" 2>/dev/null) || BSG_SID=""
engaged_session "$BSG_REPO" "$BSG_SID" || exit 0

[ "$(cmd_class "$COMMAND")" = "suite" ] || exit 0

# ---------- ARM 1 (B-9, AC-23): refuse, naming the shape that works ----------
#
# FIRST, because it is the wider refusal: a backgrounded suite is refused whether or not
# it is on the budget, and being on the budget is no answer to "nobody read the result".
#
# The command is echoed back so the fix is a copy-paste rather than a retype. It is the
# agent's own text going back to the agent — no third party reads this stream — so it is
# quoted whole rather than scrubbed and truncated the way farm-out-reminder.sh's audit
# line is.
if [ "$IS_BACKGROUND" = yes ]; then
cat >&2 <<EOF
BLOCKED: a suite may not run with run_in_background — nobody would read the result.

A backgrounded suite returns a shell id, not an outcome. Your turn can end before it
finishes, and then the evidence this slice exists to produce lives nowhere: no file, no
exit status anyone saw. Reports are turn-scoped; files are not.

Run it in the FOREGROUND instead, bounded by the Bash tool's own timeout parameter (never
a timeout/gtimeout binary), with the output tee'd to the evidence log your brief names:

    $COMMAND 2>&1 | tee <evidence log>

Then read the log and quote the pass/total line. If the suite is genuinely longer than any
timeout you can set, say so in your report and stop — do not background it.
EOF
exit 2
fi

# ---------- ARM 2 (S13, AC-21): THE BUDGET ARM ----------
#
# INSIDE A DISPATCHED AGENT ONLY. `hooks/dispatch-preflight.sh` wrote this agent`s budget
# onto the roster row at launch — `suites_allowed=`, derived from the tree by the impact
# command or declared by the brief — and this is the wall that holds it there. On the
# orchestrator`s own thread hooks/farm-out-reminder.sh owns the same question and answers
# it differently (dispatch it, or take the audited override), so this arm never speaks
# there: no `agent_id`, no arm.
#
# THIS IS A BUDGET, NOT A SAFETY WALL, and the refusal says so in that word (ADR-002). An
# extra suite run is undoable and visible — it costs compute and forty minutes of a
# machine, never a byte of anyone`s work — so the fail directions below are chosen by what
# a wrong answer costs rather than uniformly:
#
#   no row for this agent, or a row with no `suites_allowed` key at all
#       A row is written for every dispatch that passes the wall, so its absence means the
#       journal failed or the row predates the wall. Refusing every suite would punish an
#       agent for a bookkeeping failure it did not cause, so a NAMED suite passes in
#       silence. `tests/run.sh` still does not: a full-tree run is the one act the standing
#       ruling caps at one per run, and no row is not a licence to spend it.
#
#   `suites_allowed=` present but EMPTY
#       A budget was stated and came out empty — the impact command failed or derived
#       nothing, and the dispatch warned about it. Read exactly as the absent case above.
#
#   `suites_allowed=none`
#       The explicit `Suites: none` waiver. A brief that declared it runs no suite at all,
#       and every suite is refused, `tests/run.sh` included.
#
#   a set of basenames
#       Each suite the command names must be in it.
#
# A SUITE-CLASS COMMAND THAT NAMES NO FILE — `pytest`, `make test`, `npm test` — has no
# basename to compare and passes. This repo budgets by suite file; a project that does not
# is not one this row can speak about, and inventing a refusal for it would be the wall
# guessing.
#
# FARM_OUT_ALLOW IS NOT READ HERE, AND THAT IS THE POINT. The override exists so the
# ORCHESTRATOR can run something on its own thread when dispatching it genuinely will not
# work; it is farm-out-reminder.sh`s escape from farm-out-reminder.sh`s wall. A writer that
# could set an environment variable on itself to widen its own instrument would have a
# budget in name only — that is a wish, not a wall — so nothing in this arm looks at it.
[ -n "$ACTOR" ] || exit 0

# THE SHAPE RULE, AT THE SITE THAT FORMS THE PATH (review-a A-10). `session_id` returns the
# host-supplied value verbatim — it validates nothing — and this line turns it into a path.
# hooks/execution-recorder.sh:382 and hooks/agent-context-guard.sh:246 both apply this exact
# case before their own roster path, for the reason hooks/landing-gate.sh:284 states about
# `agent_id`: a key carrying path separators does not trip the symlink guards, it writes (or
# here, reads) outside the directory those guards protect. This roster READ is new in this
# wave and did not inherit the rule. An unusable id leaves the budget unstated, which is the
# documented no-row fail direction: a NAMED suite passes, `tests/run.sh` still does not.
case "$BSG_SID" in *[!A-Za-z0-9_-]*) BSG_SID="" ;; esac
ROSTER_FILE="$BSG_REPO/.bionic/tmp/roster-${BSG_SID}.state"
BUDGET_STATED=no
SUITES_ALLOWED=""
if [ -n "$BSG_SID" ] && [ ! -L "$ROSTER_FILE" ] && [ -f "$ROSTER_FILE" ]; then
  # THE LAST ROW CARRYING THIS ID WINS, which is the whole fleet`s reading of the roster
  # (hooks/stop-guard.sh, hooks/session-poker.sh: "the last row carrying a name wins"). A
  # launch row is later joined by the recorder`s `status=confirmed` copy and, across a
  # /clear, by the poker`s adopted row; each carries the budget forward, and the newest is
  # the current statement about this agent.
  BUDGET_LINE=$(awk -F'|' -v id="$ACTOR" '
    /^roster-state\// {
      hit = 0; stated = 0; allowed = ""
      for (i = 1; i <= NF; i++) {
        if ($i == "agent_id=" id) hit = 1
        else if ($i ~ /^suites_allowed=/) { stated = 1; allowed = substr($i, 16) }
      }
      if (hit) last = stated ":" allowed
    }
    END { if (last != "") print last }
  ' "$ROSTER_FILE" 2>/dev/null)
  case "$BUDGET_LINE" in
    1:*) BUDGET_STATED=yes; SUITES_ALLOWED="${BUDGET_LINE#1:}" ;;
  esac
fi
[ -n "$SUITES_ALLOWED" ] || BUDGET_STATED=no

# `none` is a STATED empty set and reads as one: nothing is on the budget, so the loop
# below refuses every target it is handed.
case "$SUITES_ALLOWED" in none) SUITES_ALLOWED="" ;; *) : ;; esac

budget_refuse() {  # <suite basename>
  # A NAME THE SHELL HAS NOT EXPANDED YET IS A DIFFERENT REFUSAL (review-c C-5, A-35c). A
  # hook sees the command TEXT, so `for s in a b; do bash "tests/$s.test.sh"; done` reaches
  # here as the literal `$s.test.sh`. Refusing is right — the hook cannot check what it
  # cannot read — but the ordinary headline is false in exactly this case: every one of
  # those suites may be on the budget, and it sends the reader to audit a set that is not
  # the problem. Two readers hit it before this branch existed.
  case "$1" in
    *'$'*|*'`'*)
      cat >&2 <<EOF
BLOCKED: $1 cannot be named at hook time.

This command names its suite with a shell variable, and this wall reads your command
text BEFORE the shell expands it — so the name never resolves to a suite it can check
against your budget. It may well be on it; nothing here can tell.

Spell the suite literally, one per call:
    bash tests/alpha.test.sh
    bash tests/beta.test.sh

On the budget: ${2:-(nothing — this brief declared Suites: none)}
EOF
      exit 2 ;;
  esac
  cat >&2 <<EOF
BLOCKED: $1 is not on this agent's suite budget.

This is a BUDGET arm, not a safety wall: an extra suite run breaks nothing, it spends
forty minutes of a machine nobody else can use. The set was recorded on this agent's
roster row at dispatch, from the files its brief declared.

On the budget: ${2:-(nothing — this brief declared Suites: none)}
You asked for: $1

Run only what is on it. If the change genuinely reaches further than the brief said,
say so in your report and let the orchestrator widen the brief — a wider instrument is
its decision to make, and it is the one holding the one-regression budget for the run.
EOF
  exit 2
}

# THE READING IS SCOPED TO THIS REPOSITORY and the split is guarded. `$BSG_REPO` is what
# turns "a file named x.test.sh" into "this row's suite x.test.sh" (critic K-2), and `set
# -f` keeps a target carrying a glob metacharacter — `bash tests/*.test.sh` reads as the
# literal `*.test.sh` — from being expanded against the HOOK PROCESS'S cwd before the loop
# sees it (review-a A-7b). The sibling site at hooks/dispatch-preflight.sh does the same.
_TARGETS=$(cmd_suite_targets "$COMMAND" "$BSG_REPO")
set -f
# shellcheck disable=SC2086  # deliberate split of a newline-joined target list, globbing off
for _target in $_TARGETS; do
  if [ "$_target" = "run.sh" ]; then
    # THE FULL TREE IS REFUSED WITHOUT A ROW THAT NAMES IT — the one place this arm fails
    # closed. AC-21: "tests/run.sh is refused unless the row carries it."
    case " $SUITES_ALLOWED " in
      *" run.sh "*) continue ;;
    esac
    cat >&2 <<EOF
BLOCKED: the full tree (tests/run.sh) is not on this agent's suite budget.

This is a BUDGET arm, not a safety wall. One regression means one: the whole tree is
proved once per run, by one dispatched runner whose row carries tests/run.sh, at
integration close. A second full run costs forty minutes and proves what the first one
already did.

On the budget: ${SUITES_ALLOWED:-(nothing — no set was recorded for this agent)}

Run the suites your brief named instead. If the tree genuinely must be re-proved, say so
in your report: the orchestrator records the cause on the plan and dispatches the runner.
EOF
    exit 2
  fi
  [ "$BUDGET_STATED" = yes ] || continue
  case " $SUITES_ALLOWED " in
    *" $_target "*) : ;;
    *) budget_refuse "$_target" "$SUITES_ALLOWED" ;;
  esac
done
set +f
exit 0
