#!/bin/bash
# STOP ORDERS — the human's instruction, and the batch stand-down.
# Design: .bionic/docs/specs/epic-16-landing-contract/wave-02-fact-based-supervision.spec.md
#         §Design (R3, R8), slice S3.
# [WALL: tests/stop-orders.test.sh]
#
# This is NOT a hook. Like hooks/session-sweeper.sh and hooks/stop-check.sh it lives in
# hooks/ for test-harness pairing and to ride the payload's hooks/ directory into the
# mounted plugin; it is registered on NO channel. Two questions, one invocation each:
#
#     bash ~/.claude/hooks/stop-orders.sh order <target> [--at <epoch>]
#     bash ~/.claude/hooks/stop-orders.sh standdown
#
# ORDER records that a human asked for an agent to be stopped, and prints what stopping it
# gives up. It is not evidence and it does not discharge the contract — it is an
# INSTRUCTION, and hooks/stop-guard.sh gets out of its way. Why a record at all: the gate
# runs inside a PreToolUse payload that carries nothing about who asked for the stop, so
# the order has to reach it the only way anything reaches a gate in this machine — as a
# fact on disk, written before the stop.
#
# AN ORDER IS BOUNDED IN TIME, and this is the one clock in the stop arc that belongs
# there. hooks/stop-guard.sh refuses to put a window on EVIDENCE (an observation is stale
# the moment its subject writes, however recent, and valid however old while its subject is
# dormant). An instruction is the other thing: it is current when it is given and it stops
# being current, and a standing order that outlived its conversation would open the wall
# for a name a later dispatch reuses. The window is generous — this is not a race — and an
# expired order simply leaves the ceremony where it was.
#
# STANDDOWN answers "which agents can I stop right now, and how do I address them?" in one
# read. Every row whose contract has LANDED — MET against a declared artifact, WAIVED, or
# acked — is listed with an address the platform's stop primitive accepts; every row that
# is still working, or has not landed, is listed as LEFT ALONE and never as a target. It
# stops nothing itself: stopping is the harness's primitive, not a shell script's. What it
# does is compute the batch, so the N stops that follow are N fact-discharged calls with no
# ceremony between them, instead of N observations.
#
# IT OWNS NO PREDICATE. "Did this contract land" is answered by
# `hooks/session-sweeper.sh verdict`, exactly as hooks/landing-gate.sh consumes it. This
# script parses that verb's machine lines and never stats a deliverable of its own.
#
# FILES (all under .bionic/tmp/, all machine-local, all safe to delete):
#   roster-<session>.state       read-only input, owned by hooks/dispatch-preflight.sh
#   sweeper-<session>.state      read-only input, owned by hooks/session-sweeper.sh
#   stop-orders-<session>.state  the orders this script owns (append-only)
#
# Exit codes:
#   0 — the order was recorded / the stand-down was computed
#   2 — usage error, or a refusal (a state path is a symbolic link, or is unwritable)
#   3 — no session key; nothing read, nothing written
#
# Session key: CLAUDE_CODE_SESSION_ID, exactly as hooks/session-sweeper.sh takes it.
#
# Registered on no channel — invoked on demand from the mounted plugin payload.

set -u

# THIS SCRIPT'S OWN PATH, so the usage it prints names the copy the operator actually
# invoked — identical in a repo checkout, in a bootstrap-installed ~/.claude/hooks/, and in
# an installed plugin payload. Deliberately NOT ${CLAUDE_PLUGIN_ROOT}: this script is run by
# hand and by the harness outside any plugin context, where that variable does not exist.
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || HOOK_DIR="$(dirname "$0")"

ORDER_SCHEMA="stop-order/v1"
ROSTER_VERSION="v1"

# HOW LONG AN ORDER IS CURRENT, in seconds. Duplicated as a literal in
# hooks/stop-guard.sh, which is the reader; the two are held together by
# tests/cross-gate-agreement.test.sh's stop-order case, which records an order at a
# boundary epoch and asks the gate about it.
ORDER_TTL_SECONDS=1800

say() { printf 'stop-orders: %s\n' "$1"; }
die() { printf 'stop-orders: %s\n' "$1" >&2; }

usage() {  # [message]
  [ $# -gt 0 ] && die "$1"
  die "Usage:"
  die "  bash ${HOOK_DIR}/stop-orders.sh order <target> [--at <epoch>]"
  die "        record a human's stop order and print what stopping gives up"
  die "  bash ${HOOK_DIR}/stop-orders.sh standdown"
  die "        list every landed row with an address you can stop it by"
  exit 2
}

[ $# -ge 1 ] || usage "no verb given."
VERB="$1"; shift

ORDER_TARGET=""
ORDER_AT=""
case "$VERB" in
  order)
    [ $# -ge 1 ] || usage "order needs a target."
    case "$1" in -*) usage "the target comes first: '$1' is an option, not a target." ;; esac
    ORDER_TARGET="$1"; shift
    while [ $# -gt 0 ]; do
      case "$1" in
        # `--at` exists for the suites, which have to place an order on either side of the
        # window boundary without sleeping through it (standing test discipline: accelerate
        # the clock, never wait on it). It is not a lie the gate can be told — an order is
        # a declaration either way, and backdating one only ever makes it expire sooner.
        --at)
          [ $# -ge 2 ] || usage "--at needs an epoch."
          case "$2" in ''|*[!0-9]*) usage "--at takes epoch seconds; got '$2'." ;; esac
          ORDER_AT="$2"; shift 2 ;;
        *) usage "unknown argument: $1" ;;
      esac
    done
    ;;
  standdown)
    [ $# -eq 0 ] || usage "standdown takes no arguments; got $#."
    ;;
  *) usage "unknown verb: $VERB" ;;
esac

# ---------------------------------------------------------------- session key

# ---------- the library ----------
#
# One loader idiom, byte-identical in every hook (spec AC-16); its source of truth is
# payload/scripts/lib/loader.sh. FAIL OPEN: nothing this script does is irreversible,
# and a reporting verb that refused because a file was missing would take the
# diagnosis down with the thing being diagnosed.
BIONIC_LIB_WANT="root.sh session.sh agents.sh"
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
  # THE ONE LINE, AND THE ONE PLACE IN THE TREE THAT SPELLS IT WITHOUT
  # scripts/lib/refuse.sh. Every other wall calls `refuse`; this one cannot, because
  # refuse.sh is IN the library this function exists to report missing. So the row-1
  # wording (record/wave-01-plugin-only/s12-refusal-wording-draft.md §1) is written
  # out here by hand, in the renderer's exact format, and tests/loader.test.sh §F
  # drives it against AC-E1.3's own regex so the two spellings cannot drift.
  #
  # THE NAME IS BOUNDED IN PURE BASH for the same reason: `bionic_trunc` is in the
  # missing library. 23 columns of prefix, 31 of fact after the name, 3 of brackets
  # and 18 of fix leaves 25 for the hook's name, and the longest caller
  # (`canonical-sdlc-evidence-gate`, 28) is over it — F-8's runtime-width hazard,
  # arriving at the one site that cannot ask the truncator. The ellipsis is spent
  # from inside the budget, exactly as bionic_trunc spends it.
  _bl_who="${1:-a bionic hook}"
  if [ "${#_bl_who}" -gt 25 ]; then _bl_who="${_bl_who:0:24}…"; fi
  printf 'bionic: load refused — %s cannot load the bionic library (run /bionic:doctor)\n' "$_bl_who" >&2
  # THE DETAIL, on the knob only. Ruling D-1: the reader who is interrupted gets one
  # sentence; the rest is for whoever asks. There is no hook log to write here — the
  # library that owns logging is the one that did not load.
  if [ "${BIONIC_WALL_VERBOSE:-}" = "1" ]; then
    cat >&2 <<BIONIC_LOADER_REFUSE
A wall that cannot read a command refuses it rather than waving it through.

Wanted: ${BIONIC_LIB_MISSING:-the bionic library}
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
  fi
  exit 2
}
# --- bionic-loader/v2 END
if [ -n "$BIONIC_LIB_MISSING" ]; then loader_fail_open "stop-orders"; fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/root.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/session.sh"
# THE ONE READER OF THE LIVE SET (wave-roster-lifecycle S4/S6, D1′). `standdown` REPORTS; it
# writes nothing to the roster and decides nothing, and the live set is read for one purpose
# only — to say, beside a row it is leaving alone, whether the agent it names still exists.
# A row that is still working and a row whose agent finished without landing look identical
# on the roster, and the operator reading LEFT ALONE is the one who has to tell them apart.
# shellcheck source=/dev/null
. "$BIONIC_LIB/agents.sh"

# THE SESSION KEY, from the library (design §1): env primary. Both verbs answer for ONE
# session's roster, and the roster filename is built from this value — so it has to be
# the same spelling the walls that wrote it used.
SESSION_ID=$(session_id "" 2>/dev/null) || SESSION_ID=""
if [ -z "$SESSION_ID" ]; then
  die "REFUSED — no session key (CLAUDE_CODE_SESSION_ID is unset or empty)."
  die "Both verbs answer for ONE session's roster. Run this from inside a Claude Code"
  die "session; nothing was read and nothing was written."
  exit 3
fi

# ---------------------------------------------------------------- where state lives


# THE ROOT (spec AC-10, lib/root.sh). `rev-parse --show-toplevel` answers with whatever
# tree the SHELL stands in; inside a linked worktree that is not where the state lives,
# and the reader and the writer then disagree about which `.bionic` is real. This was a
# byte-identical private copy — one of eight — held together by an agreement suite;
# there is one answer now, and it maps a worktree onto its main repository before it
# walks for the nearest real `.bionic`.
REPO="$(project_root "$PWD")"
REPO_REAL="$(cd "$REPO" 2>/dev/null && pwd -P)"
if [ -z "$REPO_REAL" ]; then
  die "REFUSED — cannot resolve the working directory."
  exit 2
fi

BIONIC_DIR="$REPO_REAL/.bionic"
STATE_DIR="$BIONIC_DIR/tmp"
# Hostile-repo posture, byte for byte from hooks/session-sweeper.sh: a repo controls its
# own .bionic/ contents, so a symlink anywhere on the path this script writes through is
# refused rather than followed.
for _component in "$BIONIC_DIR" "$STATE_DIR"; do
  if [ -L "$_component" ]; then
    die "REFUSED — $_component is a symbolic link."
    die "The state directory must be a real directory inside the repo. Remove the link"
    die "and re-run; nothing was written."
    exit 2
  fi
done

# THIS SESSION'S TRANSCRIPT, where the harness records its ListAgents answers. This script
# has no hook payload to carry one, so the file is found the way hooks/stop-check.sh finds
# it: `<projects>/<slug>/<session-id>.jsonl`, with a keyed walk of the project directories
# behind the slug — a worktree cwd files its session under a different slug from the repo it
# is reading. Empty when nothing answers, which simply leaves the annotation off.
own_transcript() {  # -> the transcript file of THIS session, or nothing
  local projects slug d
  projects="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  for slug in "$(printf '%s' "$PWD" | sed 's/[^a-zA-Z0-9]/-/g')" \
              "$(printf '%s' "$REPO_REAL" | sed 's/[^a-zA-Z0-9]/-/g')"; do
    [ -f "$projects/$slug/$SESSION_ID.jsonl" ] || continue
    printf '%s\n' "$projects/$slug/$SESSION_ID.jsonl"; return 0
  done
  for d in "$projects"/*/"$SESSION_ID.jsonl"; do
    [ -f "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

ROSTER_FILE="$STATE_DIR/roster-${SESSION_ID}.state"
ORDERS_FILE="$STATE_DIR/stop-orders-${SESSION_ID}.state"

if [ -L "$ORDERS_FILE" ]; then
  die "REFUSED — $ORDERS_FILE is a symbolic link; nothing was written through it."
  die "Remove it and re-run."
  exit 2
fi

SWEEPER="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/session-sweeper.sh"

# ---------------------------------------------------------------- shared readers

now_epoch() { date -u +%s; }
iso_now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

line_field() {  # <line> <key>
  printf '%s' "$1" | tr '|' '\n' | grep "^$2=" | head -1 | cut -d= -f2-
}

# Values reach this file from a brief and from the operator's keyboard, and every record
# here is pipe-delimited key=value. A `|`, a newline or a control character inside a value
# forges a field, so they are folded to spaces exactly as hooks/session-sweeper.sh's
# clean() folds them — the two must agree, because a name written by one is matched by the
# other.
clean() {  # <value>
  printf '%s' "$1" | tr '\n\r\t|' '    ' | sed -e 's/[[:cntrl:]]/ /g' -e 's/  */ /g' \
    -e 's/^ *//' -e 's/ *$//' | cut -c 1-400
}

# THE ROSTER IS FOLDED ONCE, not once per row. The roster is append-only and a contract
# advances along it (`intended` → `confirmed` → `identified`), every writer copying the
# contract fields forward, so the last row carrying a name is the authoritative one — the
# same question hooks/session-sweeper.sh's latest_rows answers, and the same one
# hooks/session-poker.sh answers for its own single-row lookup (plan assumption 13).
#
# WHY IT IS A PRE-LOOP FOLD (ap review P-1, blocking-grade, epic-16 w2 Step-6 remediation
# R4). This function used to walk the WHOLE roster file per call, spending `line_field`
# (4 processes) and `clean` (~3) on every line — and `standdown` calls it once per verdict
# row, so a roster of N agents cost ~14·N² processes: measured 2.3 s at N=10, 22.9 s at
# N=40 and 127.7 s at N=100, on the one operation SKILL.md:459 tells the orchestrator to
# run "before closing a batch or wave", which is exactly when the roster is at its largest.
# The fold below is one awk pass over the file, and each lookup is then a scan of values
# already in memory — no subprocess at all.
#
# THE THIRD COPY OF ONE FOLD, DELIBERATELY (critic trap #6). The origin is latest_rows in
# hooks/session-sweeper.sh; this file cannot source it — there is no shared library in this
# repo by decision (a sourced library the installer misses is a silently inert consumer,
# hooks/session-sweeper.sh §9), and the two folds are not code-identical in any case: this
# one drops the per-session filter and the contract counting that verdict needs, and keeps
# the FIRST-`name=`-field reading `line_field` has always had here rather than latest_rows
# first-NON-EMPTY reading. What holds them together is behavioural and lives in
# tests/cross-gate-agreement.test.sh §P: given one roster where a name appears twice, the
# sweeper, the poker and this script must all answer with the LATER row.
#
# TWO PARALLEL ARRAYS, not one big string, and this is measured rather than stylistic: a
# `${fold#*"$marker"}` lookup over a folded roster held in a single variable is itself
# quadratic — bash matches a leading-`*` pattern by trying every prefix, so 100 lookups
# over a 31 KB string cost 24.6 s on their own (micro-benchmark, R4). Element-wise string
# EQUALITY over short values does no pattern matching at all: the same 100 lookups are
# ~10 000 comparisons of a few bytes each.
ROSTER_NAMES=(); ROSTER_ROWS=()     # index-aligned; empty until fold_roster runs

fold_roster() {
  ROSTER_NAMES=(); ROSTER_ROWS=()
  [ -L "$ROSTER_FILE" ] && return 0
  [ -f "$ROSTER_FILE" ] || return 0
  local _fn _frow
  # The name is normalised here exactly as clean() normalises it, because that is what the
  # per-line comparison this replaces did: control characters (a tab included, which would
  # otherwise forge the delimiter below) folded to spaces, runs squeezed, ends trimmed,
  # 400 characters kept. A `|` cannot survive into a field, having been the split point.
  #
  # A here-document and not a pipe: `while read` on the right of a pipe runs in a subshell,
  # where every array assignment below would be discarded at the closing `done`.
  #
  # `$'\t'` and not `"$(printf '\t')"`, for the reason hooks/session-sweeper.sh's row_for_name
  # states at its own read loop: an IFS prefix on a `while` condition is re-evaluated on
  # EVERY iteration, so the command substitution would spend a subshell per roster row — the
  # per-row process cost this fold exists to remove, reintroduced one line into the fix.
  while IFS=$'\t' read -r _fn _frow || [ -n "$_fn" ]; do
    [ -n "$_fn" ] || continue
    ROSTER_NAMES[${#ROSTER_NAMES[@]}]="$_fn"
    ROSTER_ROWS[${#ROSTER_ROWS[@]}]="$_frow"
  done <<EOF
$(awk -v pfx="roster-state/${ROSTER_VERSION}|" '
    index($0, pfx) != 1 { next }
    {
      name = ""; got = 0
      nf = split($0, f, "|")
      for (i = 1; i <= nf; i++) {
        # FIRST name= field wins, empty or not — line_field takes head -1 and so did the
        # comparison this fold replaces. A forged later name= must not overrule the writer.
        if (!got && substr(f[i], 1, 5) == "name=") { name = substr(f[i], 6); got = 1 }
      }
      gsub(/[[:cntrl:]]/, " ", name)
      gsub(/  +/, " ", name)
      sub(/^ +/, "", name)
      sub(/ +$/, "", name)
      name = substr(name, 1, 400)
      # An empty name could never match a caller name, which the standdown loop already
      # requires to be non-empty, so it is dropped rather than carried.
      if (name == "") next
      if (!(name in row)) order[++n] = name
      row[name] = $0
    }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\n", order[i], row[order[i]] }
  ' "$ROSTER_FILE" 2>/dev/null)
EOF
}

# The latest row for ONE name, out of the folded roster. WHOLE-VALUE equality and never a
# substring or a pattern: `w4-s1` must not be answered with `w4-s10` row, which is the same
# rule hooks/session-sweeper.sh's row_acked states for the ack ledger. A name that is not on
# the roster answers empty, exactly as the per-line walk this replaces did — the caller then
# reads no deliverable and falls back to the bare name for an address.
roster_row_for() {  # <name>
  local want="$1" i=0 n=${#ROSTER_NAMES[@]}
  while [ "$i" -lt "$n" ]; do
    if [ "${ROSTER_NAMES[$i]}" = "$want" ]; then
      printf '%s\n' "${ROSTER_ROWS[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  printf '\n'
}

# HOW THE OPERATOR ADDRESSES THIS AGENT, in a form the stop primitive accepts. The launch
# response hands back `name@session-xxxxxxxx` and that is what TaskStop takes for a
# teammate; the transcript-form id (`aname-<hex>`) is a THIRD namespace that the roster's
# `identified` row carries and the platform will not resolve for the operator (capture
# probe §3-D/§5). Printing the id the reader cannot type is what cost four calls and an
# ambiguity round on 2026-08-11, so the recorded teammate address wins, the transcript id
# is the fallback, and the bare name is the floor.
stop_address() {  # <roster-row> <name>
  local row="$1" name="$2" tm aid
  tm=$(line_field "$row" teammate_id)
  [ -n "$tm" ] && { printf '%s\n' "$tm"; return 0; }
  aid=$(line_field "$row" agent_id)
  [ -n "$aid" ] && { printf '%s\n' "$aid"; return 0; }
  printf '%s\n' "$name"
}

# ---------------------------------------------------------------- verbs

case "$VERB" in

  order)
    _target="$(clean "$ORDER_TARGET")"
    [ -n "$_target" ] || usage "order needs a non-empty target."

    mkdir -p "$STATE_DIR" 2>/dev/null
    if [ ! -d "$STATE_DIR" ]; then
      die "REFUSED — the state directory could not be created ($STATE_DIR)."
      exit 2
    fi

    _at="${ORDER_AT:-$(now_epoch)}"
    [ -f "$ORDERS_FILE" ] || printf '# bionic stop orders — schema %s — machine-local, safe to delete\n' \
      "$ORDER_SCHEMA" >> "$ORDERS_FILE" 2>/dev/null
    if ! printf '%s|at=%s|epoch=%s|session=%s|target=%s\n' \
         "$ORDER_SCHEMA" "$(iso_now)" "$_at" "$SESSION_ID" "$_target" >> "$ORDERS_FILE" 2>/dev/null; then
      die "REFUSED — the order could not be written to $ORDERS_FILE."
      die "An unrecorded order is one the stop gate will never see, so the failure is"
      die "reported rather than assumed away."
      exit 2
    fi

    say "stop ordered: $_target — the gate will pass it for the next $((ORDER_TTL_SECONDS / 60)) minutes."
    # WHAT IS BEING GIVEN UP, from the verdict's own detail and never from a second
    # opinion about the disk. An order is not a claim that the work landed, and the
    # operator is owed the difference in one line.
    if [ -f "$SWEEPER" ]; then
      _v=$( cd "$REPO_REAL" 2>/dev/null || exit 9
            CLAUDE_CODE_SESSION_ID="$SESSION_ID" bash "$SWEEPER" verdict "$_target" 2>/dev/null )
      _line=$(printf '%s\n' "$_v" | grep -F 'landing-verdict/v1|' | head -1)
      if [ -n "$_line" ]; then
        _state=$(line_field "$_line" state)
        _detail=$(line_field "$_line" detail)
        case "$_state" in
          MET|WAIVED) say "its contract has landed ($_state) — nothing is given up." ;;
          *)          say "UNLANDED ($_state) — stopping gives up: $_detail" ;;
        esac
      else
        say "no contract row of that name on this session's roster — nothing is known to be given up."
      fi
    fi
    exit 0
    ;;

  standdown)
    if [ ! -f "$SWEEPER" ]; then
      die "REFUSED — the sweeper is not beside this script ($SWEEPER)."
      die "The landing question belongs to its verdict verb; this script owns no predicate"
      die "of its own and will not guess one."
      exit 2
    fi

    _v=$( cd "$REPO_REAL" 2>/dev/null || exit 9
          CLAUDE_CODE_SESSION_ID="$SESSION_ID" bash "$SWEEPER" verdict 2>/dev/null )
    _lines=$(printf '%s\n' "$_v" | grep -F 'landing-verdict/v1|')
    if [ -z "$_lines" ]; then
      say "no contract rows on this session's roster; nothing to stand down."
      exit 0
    fi

    # ONE read of the roster for the whole batch, before the loop that consumes it — never
    # a re-walk per verdict row (ap review P-1). Placed after the verdict read so a refused
    # or empty verdict costs nothing at all.
    fold_roster

    # THE LEASE ENDS HERE (bionic 1.4.0, spec AC-28, design ledger C1). A
    # discharged row's worktree is a leased slot nobody holds any more, and
    # standing the agent down is the moment to give the disk back. The act — a
    # --no-ff merge, a removal, a prune, and the refusals around them — belongs
    # to payload/scripts/lib/worktree.sh, which the Patrol tick and
    # spawn-worktree.sh's `land` verb call too; this is a call site and not a
    # second copy of the judgment. Two spellings of the library path because
    # the repo ships payload/hooks as a symlink to hooks/ and `$0` is textual.
    # A missing library costs nothing: the stand-down report is what this verb
    # owes, and the landing is additive to it.
    _wt_lib="${HOOK_DIR}/../payload/scripts/lib/worktree.sh"
    [ -f "$_wt_lib" ] || _wt_lib="${HOOK_DIR}/../scripts/lib/worktree.sh"
    # shellcheck source=/dev/null
    [ -f "$_wt_lib" ] && . "$_wt_lib"

    # THE LIVE SET, read ONCE for the whole batch and only for the LEFT ALONE reason text.
    # A stale or absent answer leaves `_live` empty and `_live_ok` at 0, and every held row
    # is then reported exactly as it was before this slice: this verb owes a report, and an
    # annotation it cannot justify is worse than none.
    _live=""; _live_ok=0
    _own_tr=$(own_transcript) || _own_tr=""
    if [ -n "$_own_tr" ]; then
      if _live=$(live_agents "$_own_tr" 2>/dev/null); then _live_ok=1; else _live=""; fi
    fi
    # A NAME IS NOT A PATTERN (Step-6 security review S-5). The name is a value lifted off a
    # roster row — the operator's typed target one step upstream — and nothing in the fleet
    # charset-guards it, so a `.`, `*` or `[` dropped into a basic regular expression
    # over-matches and annotates a departed row `[live]` off a neighbour's name. Field
    # equality, which is the spelling `live_agents_has` already uses two functions away.
    _is_live() {  # <name> -> 0 iff the fresh answer names it
      [ "$_live_ok" -eq 1 ] || return 1
      printf '%s\n' "$_live" \
        | awk -F'|' -v want="$1" '$1 == want { found = 1 } END { exit found ? 0 : 1 }'
    }

    _ready=""; _held=""; _nready=0; _nheld=0; _landed=""
    while IFS= read -r _l; do
      [ -n "$_l" ] || continue
      _name=$(line_field "$_l" name)
      _state=$(line_field "$_l" state)
      _detail=$(line_field "$_l" detail)
      [ -n "$_name" ] || continue
      _row=$(roster_row_for "$_name")
      _deliv=$(line_field "$_row" deliverable)
      _why=""
      # THE DISCHARGE SET, spelled the same way hooks/stop-guard.sh spells it: an ack, or a
      # WAIVED contract, or a MET one that had a declared artifact to meet. A row that
      # declared nothing stats MET for want of anything to hold it to, and standing one
      # down on that is standing it down on a fact nobody produced — an ack is what closes
      # those, which is the job ack exists for.
      #
      # The ack is read off the SAME LINE this loop is already walking (epic-16 wave-02 S9).
      # It used to come from a private copy of a ledger reader living in this file, one of
      # three; the verb that printed the line owns the ledger, so it prints the answer too.
      if [ "$(line_field "$_l" acked)" = "yes" ]; then
        _why="acked"
      elif [ "$_state" = "WAIVED" ]; then
        _why="waived"
      elif [ "$_state" = "MET" ] && [ -n "$_deliv" ]; then
        _why="met"
      fi
      if [ -n "$_why" ]; then
        _nready=$((_nready + 1))
        _ready="${_ready}  $(stop_address "$_row" "$_name")   ($_why — $_name)
"
        # LANDED or REFUSED, one line per tree, reported either way: a lease
        # this verb could not end is exactly what the operator needs told.
        if declare -f worktree_land >/dev/null 2>&1; then
          _tree="$(worktree_for_row "$REPO_REAL" "$_name")"
          [ -d "$_tree" ] && _landed="${_landed}  $(WORKTREE_CONTRACT_PROG=spawn-worktree worktree_land "$_tree")   ($_name)
"
        fi
      else
        _nheld=$((_nheld + 1))
        # WHY THE ROW IS STILL HELD, and — where the harness can say so — whether anyone is
        # still working on it. `not live` on an unlanded row is the finished-but-unstopped
        # state the roster alone cannot express, which is the whole reported defect.
        _liveness=""
        if [ "$_live_ok" -eq 1 ]; then
          if _is_live "$_name"; then _liveness="   [live]"; else _liveness="   [not live]"; fi
        fi
        _held="${_held}  $_name   ($_state — $_detail)${_liveness}
"
      fi
    done <<EOF
$_lines
EOF

    if [ "$_nready" -gt 0 ]; then
      say "STAND DOWN — $_nready row(s) have landed; stop each by the address on its left:"
      printf '%s' "$_ready"
    else
      say "nothing has landed; there is nobody to stand down."
    fi
    if [ -n "$_landed" ]; then
      say "LEASES ENDED — the worktree of each row above, landed or refused:"
      printf '%s' "$_landed"
    fi
    if [ "$_nheld" -gt 0 ]; then
      # NAMED, NEVER TARGETED. A row still working or not yet landed is left alone by this
      # operation — printing it as a target is how a batch stand-down would end the very
      # work it was supposed to leave running.
      say "LEFT ALONE — $_nheld row(s) are not stood down by this operation:"
      printf '%s' "$_held"
    fi
    say "This script stopped nothing: stopping is the harness's, and each of these passes"
    say "the stop gate on its landed contract with no observation."
    exit 0
    ;;
esac
