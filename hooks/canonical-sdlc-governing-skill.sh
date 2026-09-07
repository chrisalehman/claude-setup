#!/bin/bash
# GOVERNING-SKILL GATE: Blocks Write and Edit to canonical-sdlc artifact
# files that lack the required governing-skill frontmatter.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
#
# Scope: files under <project>/docs/bionic/{specs,plans,adrs}/ matching
#   *.plan.md | *.spec.md | *.requirements.md | adr-*.md | continuation*.md
# (epic.plan.md and epic.spec.md are covered by *.plan.md / *.spec.md)
#
# K5: *.requirements.md gets the same frontmatter contract as *.spec.md — it
# is the Step-1 artifact (design ledger K5; ADR-001) and lives beside the spec
# under specs/epic-NN-<slug>/. It does NOT get the design three-way rule below
# (that arm's own case statement keys on *.spec.md only, so a requirements
# file never reaches it).
#
# Other files under those paths — README.md, images, supporting notes —
# pass through unblocked. Rename-to-bypass is discoverable: the skill's
# own naming gates catch artifacts that aren't named correctly.
#
# Required frontmatter block at the top of the file:
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
#
#   ---
#   governing-skill: superpowers:writing-plans
#   sdlc-step: 3
#   epic: epic-02-checkout
#   wave: wave-01-checkout-refactor
#   canonical_sdlc_version: <SUPPORTED_SDLC_VERSION, bound near the top of this file>
#   intent: build
#   rigor: audited
#   scale: wave
#   ---
#
# This hook enforces the presence of `governing-skill:` only. Other
# fields are documented in the skill but not hook-enforced — the skill's
# content rubric catches malformed values before they ship.
#
# Exit code 2 = block the tool call entirely in Claude Code hooks.
#
# Registered ONCE, in hooks/hooks.json, for both the main thread and agent contexts.
# The two-channel partition it used to need — skill frontmatter for the main thread,
# settings for agent contexts — is gone: what scopes the wall now is an on-disk fact,
# the calling session's own run under the artifact's own project root (`session_run`,
# which was `active_run` until wave-session-bound-run made run identity per-session).

set -u

# ONE supported version. Anything else — an older number, a typo, an empty value, garbage —
# blocks. Bound here, before the first place that quotes it (the missing-frontmatter hint
# below), so every echo of "the" supported version is this one variable and never a second,
# independently-typed literal (review-duplication D-2).
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
SUPPORTED_SDLC_VERSION=14

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

# THIS HOOK ANSWERS ON TWO EVENTS (wave-session-bound-run, 2026-09-04). PreToolUse is the
# wall, unchanged. PostToolUse|Write is the BIND ARM, and it exists because of a hard
# ordering fact: the artifact that creates a run is its plan file, and at PreToolUse that
# file does not exist yet — `open_runs` cannot list it, so `bind_plan`, which refuses any
# path that is not a member of the open-run set at the instant of the write, would refuse
# every binding the arm exists to make. The invariant "a bound path is a member of the
# open-run set at write time" is only satisfiable after the tool has run.
#
# The event is absent on nothing this hook is registered for, but `// empty` keeps a
# payload without it reading as the wall rather than as the bind arm — the direction that
# preserves today's behaviour.
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')

# Only Write and Edit need checking. Other tools pass through.
case "$TOOL" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Is the path under a canonical-sdlc artifact directory AND does the
# basename match an enforced extension? Both must be true.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
# Match files under the project's docs root (default <project>/.bionic/
# docs/, configurable via <project>/.bionic/config.yaml `docs-root:`).
#
# Strategy: the project root is the LIBRARY's answer (lib/root.sh's `project_root`,
# spec AC-10) — the nearest ancestor of the target holding a real `.bionic/`, with a
# linked worktree mapped onto its main repository first. From that root, resolve
# docs-root and check whether FILE_PATH lives under
# <docs-root>/{specs,plans,adrs,incidents}/.
#
# THE WORKTREE MAPPING IS LOAD-BEARING, not a refinement. Every worktree of one repo
# has to resolve to ONE root and therefore one `.bionic/` tree: while this gate and
# the evidence gate disagreed about which tree was real, no artifact placement
# satisfied both — obey this one and every commit from the worktree ran ungated, obey
# that one and every artifact write was blocked.
#

# Resolve a path's ancestors to their physical form, keeping any tail that does
# not exist yet. `git` answers with the PHYSICAL root, while FILE_PATH arrives
# from the tool as whatever path the session used — if the project is reached
# through a symlink the two disagree on prefix and every path comparison below
# misfires. This function is the fix, and the severity is why it could not be
# deferred: under the old pass-through the mismatch was a silent bypass
# (artifacts quietly stopped being gated), but once misplacement BLOCKS, the
# same mismatch inverts into the worse failure — a correctly placed artifact
# false-BLOCKED. Fail-closed turns a hole into a wall in front of legitimate
# work, so closing the hole and resolving symlinks had to land together.
#
# Not exotic on macOS, where /tmp and /var are themselves symlinks.
#
# `pwd -P` needs a directory that EXISTS, and this is a PreToolUse gate, so the
# climb mirrors resolve_project_root's: walk up to the nearest existing
# ancestor, physicalize that, re-attach the tail. Fail-open — an unresolvable
# path is returned unchanged.
# FOLD `.` AND `..` LEXICALLY FIRST, before the filesystem is consulted at all — cs review
# S-2, epic-16 w2 Step-6 remediation R4. The climb below resolves only the EXISTING ancestor
# prefix, so a component that does not exist yet strands everything after it, `..` segments
# included, as an unresolved literal: `<pinned>/.bionic/nonexistent/../../../other/.bionic/
# docs/record/x.md` kept its climb un-folded, the pinned-root comparison found the harmless
# `.bionic` at the front of that string, and the write landed OUTSIDE the repository. The
# Write tool creates parent directories, so the non-existent segment was never an obstacle
# to the write — only to the wall seeing where it was going.
#
# The loop is hooks/dispatch-preflight.sh resolve_in_repo()'s, which already folds this way
# before comparing a deliverable path against the repo, and whose `set -f` guard is
# load-bearing here too: a `*` inside a tool-supplied path is a character, never a glob.
# Two walls in one wave had disagreed about how to resolve a path, and this is the weaker
# one adopting the stronger one.
#
# A LEXICAL fold, deliberately, not realpath: `<symlink>/..` folds to the symlink's parent
# rather than to its target's parent. Same reading resolve_in_repo takes, and for a wall
# whose question is "which tree does this path NAME" it is the right one.
fold_dots() {  # $1=path → `.` and `..` folded lexically, absolute
  local p="$1" abs out part had_f
  case "$p" in
    /*) abs="$p" ;;
    *)  abs="$(pwd)/$p" ;;
  esac
  case "$-" in *f*) had_f=1 ;; *) had_f=0 ;; esac
  set -f
  out=""
  local IFS=/
  for part in $abs; do
    case "$part" in
      ''|.) ;;
      ..)   out="${out%/*}" ;;
      *)    out="$out/$part" ;;
    esac
  done
  unset IFS
  [ "$had_f" -eq 1 ] || set +f
  printf '%s\n' "${out:-/}"
}

physicalize() {  # $1=absolute path (need not exist) → folded, ancestors resolved
  local d rest p folded
  folded=$(fold_dots "$1")
  d=$(dirname "$folded")
  rest=$(basename "$folded")
  while [ ! -d "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ] && [ -n "$d" ]; do
    rest="$(basename "$d")/$rest"
    d=$(dirname "$d")
  done
  if p=$(cd "$d" 2>/dev/null && pwd -P); then
    printf '%s/%s\n' "${p%/}" "$rest"
  else
    # Fail-open on an unresolvable path, but never back to the UNFOLDED spelling: the fold
    # is what the comparisons below are entitled to, and handing back the raw climb is the
    # bypass this function just closed.
    printf '%s\n' "$folded"
  fi
}


# ---------- the library ----------
#
# One loader idiom, byte-identical in every hook (spec AC-16); its source of truth is
# payload/scripts/lib/loader.sh. FAIL OPEN: an artifact written in the wrong place is
# a mistake a person can move, and the evidence gate's own misplacement sweep catches
# the consequential half of it at commit time. Refusing every Write and Edit on the
# machine because a file is missing is not recoverable at that price.
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
if [ -n "$BIONIC_LIB_MISSING" ]; then loader_fail_open "canonical-sdlc-governing-skill"; fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/root.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/run.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/session.sh"
# binding.sh AFTER run.sh, which owns the marker path, the open-run set and the
# line-ending translation it is written in terms of.
# shellcheck source=/dev/null
. "$BIONIC_LIB/binding.sh"

# THE ROOT THAT OWNS THE ARTIFACT — the artifact's own, not the invoking session's.
PROJECT_ROOT_FROM_PATH=$(project_root "$(dirname "$FILE_PATH")")
if [ -z "$PROJECT_ROOT_FROM_PATH" ]; then
  # project_root always answers, so this is unreachable in practice. Kept as a
  # defensive guard; it is not the misplacement fail-open, which is closed below by
  # the UNDER_DOCS_ROOT verdict.
  exit 0
fi

# ---------- THE ENGAGEMENT GUARD (AC-7): is this session bionic's at all? ----------
#
# FIRST, above the four-clause project disjunction below. Chris, 2026-09-03: "all
# guardrails imposed by bionic should only apply when exercising bionic. Nothing should
# apply until bionic is triggered" — and the trigger is the canonical-sdlc skill, which
# writes `.bionic/tmp/engaged-<sid>.state` at the instant it is invoked.
#
# IT SUPERSEDES THE DISJUNCTION WITHOUT REPLACING IT. Those four clauses answer "is this
# artifact one this lifecycle owns" — an open run, a `.bionic/` tree, a path inside one,
# or content declaring `canonical_sdlc_version:`. Every one of them can be true in a
# session that never invoked the skill: a bystander editing a plan file in a repo where
# somebody else ran a wave was exactly the reproduction. So this asks the prior question
# and the disjunction keeps asking its own, unchanged, for engaged sessions.
#
# THE MARKER IS LOOKED FOR UNDER THE ARTIFACT'S ROOT, not the invoking session's cwd —
# the same root every clause below uses. A hook that scoped itself by one root and
# enforced against another would go quiet exactly where it was added to bind.
#
# EVERY UNREADABLE STATE READS AS NOT ENGAGED — absent marker, a symlink at the path, a
# foreign or unshaped session key, no key at all. The arming partition is the consent
# boundary (1.3.2 close-out).
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
GS_SID=$(session_id "$(echo "$INPUT" | jq -r '.session_id // empty')" 2>/dev/null) || GS_SID=""
engaged_session "$PROJECT_ROOT_FROM_PATH" "$GS_SID" || exit 0

# ---------- THE BIND ARM (AC-9): a new run's plan claims the session that wrote it ----------
#
# PostToolUse ONLY, and it does nothing else. The tool has already run, so this arm cannot
# block and must not try: every path below leaves through `exit 0`, prints no decision
# JSON, and the one thing it can change is the session's own marker.
#
# WHY THE WRITE OF A PLAN IS THE RIGHT MOMENT. A run's identity has to attach to a session
# at the act that CREATES the relationship, and that act is the first write of the plan
# file (spec §Design D0, T4). Engagement is too early — at `/bionic:canonical-sdlc` the run
# may not exist yet — and the first commit is far too late, which is the window the bug
# report opened on: a resumed session that engaged, wrote its plan and committed was gated
# on whichever plan in the root happened to be newest.
#
# IT REBINDS WITHOUT ASKING (T4). A session that writes a second run's plan has moved to
# that run; the previous binding is not a claim to defend. The one binding this arm cannot
# make is one `bind_plan` refuses — a file that is not a member of the open-run set — and
# there the marker is left exactly as it was, silently, because a Write under `plans/` that
# is not an open run is an ordinary file and not an event.
#
# WHAT MAKES A FILE A PLAN IS NOT ASKED HERE. `bind_plan` refuses any path `open_runs` does
# not list, and `open_runs` owns the whole rule — the depth-2 walk, the fence-aware
# flush-left `## SDLC State` filter, and the open/closed verdict. Spelling that filter a
# second time inside this hook would give the fleet two readings of "is this a plan", which
# is the class of drift `lib/run.sh` was extracted to end (spec §Ownership table).
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
if [ "$EVENT" = "PostToolUse" ]; then
  # An Edit never binds (AC-9). It changes a plan; it does not create a run.
  [ "$TOOL" = "Write" ] || exit 0

  # A DISPATCHED AGENT'S WRITE NEVER MOVES ITS DISPATCHER'S BINDING (S10a, review A-2/F5).
  # An agent-context payload carries a top-level `agent_id` AND the DISPATCHING session's
  # `session_id` — that is the documented basis of the partition guard
  # (hooks/agent-context-guard.sh:37-40: "the payload carries a top-level `agent_id` … this
  # is an agent context. Main-thread payloads have no such field"). This arm reads
  # `.session_id`, so without this test a subagent drafting the NEXT wave's plan, or a
  # Step-9 close-out writer, silently rebinds the LIVE ORCHESTRATOR — after which the
  # orchestrator's evidence gate gates its commits on the new plan. That is the
  # least-privileged context on the machine redirecting every wall in the fleet.
  #
  # T4 RATIFIED REBINDING FOR THE MAIN THREAD and nothing extended it to depth two. It also
  # sits crosswise to the precedent ADR's "No nested tracking … the roster records only
  # depth-one dispatches": binding is identity state, and a depth-two act must not mutate
  # depth-one identity.
  case "$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)" in
    ?*) exit 0 ;;
  esac

  # A WRITE THAT OVERWROTE AN EXISTING FILE IS NOT A NEW RUN. PostToolUse cannot see the
  # pre-state, so the distinction comes from the payload: Claude Code reports `create` or
  # `update` in `tool_response.type` for Write (measured on this machine, 2026-09-04: 17
  # Write results joined to their tool_use ids across six session transcripts gave 14
  # `create` and 3 `update`; Edit results carry no `type` key at all). An ABSENT field
  # falls through to binding rather than to silence — a missing distinction must not cost
  # AC-9 the case it exists for, and a redundant rebind to a plan the session is already
  # working in is the harmless direction.
  case "$(echo "$INPUT" | jq -r '.tool_response.type // empty' 2>/dev/null)" in
    update) exit 0 ;;
  esac

  # The file the tool left behind, and where it landed. Both sides physicalized before
  # comparing, for the reason the wall below states at greater length: a project reached
  # through a symlink otherwise disagrees with itself about its own prefix.
  [ -f "$FILE_PATH" ] || exit 0
  GS_BIND_TARGET=$(physicalize "$FILE_PATH")
  GS_BIND_DOCS=$(physicalize "$(docs_root "$PROJECT_ROOT_FROM_PATH")")
  case "$GS_BIND_TARGET" in
    "$GS_BIND_DOCS"/plans/*|"$GS_BIND_DOCS"/incidents/*) ;;
    *) exit 0 ;;
  esac

  if bind_plan "$PROJECT_ROOT_FROM_PATH" "$GS_SID" "$GS_BIND_TARGET"; then
    echo "governing-skill: session bound to $GS_BIND_TARGET" >&2
  fi
  exit 0
fi

# ---------- THE SESSION'S RUN, NOT THE ROOT'S (AC-1, AC-3, AC-6) ----------
#
# `active_run` answered "is there a run in this project" — one answer per repository, which
# is exactly the bug: two engaged sessions in one root shared a run identity and each was
# gated on whichever plan was newest. `session_run` answers per session, and says which
# resolution it used.
#
# THE VERDICT IS SPOKEN ALOUD, on stderr, beside every other note this hook makes. AC-3
# requires an unbound session to be TOLD it fell back to the newest plan, and AC-6 requires
# a session whose bound plan has closed to be told that rather than handed another run's.
# Neither line blocks anything.
GS_RUN=$(session_run "$PROJECT_ROOT_FROM_PATH" "$GS_SID" 2>/dev/null) || :
case "$GS_RUN" in
  fallback\ *)
    echo "governing-skill: run resolved by newest-plan fallback (session unbound) — ${GS_RUN#fallback }" >&2 ;;
  bound-closed\ *)
    # A BINDING IS A COMMITMENT (AC-6). Not active, and deliberately not re-scanned: the
    # moment a run closes is the moment a scan would hand its session somebody else's.
    echo "governing-skill: bound plan closed — ${GS_RUN#bound-closed }; this session has no open run" >&2 ;;
esac

# ---------- WHAT ARMS THIS WALL (AC-7) ----------
#
# ENGAGEMENT ARMS IT. Full stop. The guard above exits unless
# `<root>/.bionic/tmp/engaged-<sid>.state` is a regular file under the ARTIFACT's own root,
# so every line from here down runs for a session that invoked `/bionic:canonical-sdlc` in
# the project being written to, and for no other.
#
# THERE USED TO BE THREE MORE CLAUSES AND THEY WERE ALREADY DEAD (S10a, review A-1). The
# wall was described as armed by the PROJECT "shown one of three ways" — a `.bionic/` tree
# at the root, a target inside a `.bionic/` tree, or content declaring
# `canonical_sdlc_version:` — implemented as an early exit guarded by
# `[ ! -d "$PROJECT_ROOT_FROM_PATH/.bionic" ]`. That test can never be true here: a REGULAR
# FILE at `<root>/.bionic/tmp/engaged-<sid>.state` entails a directory at `<root>/.bionic`,
# `PROJECT_ROOT_FROM_PATH` is assigned once and never reassigned, and the engagement guard
# sits above. b2dbb14 said so in its own commit message when it deleted the block's other
# conjunct, and left the corpse; the seventeen lines and their `jq | awk | awk | grep`
# content scan are gone now, with the explanation that outlived them.
#
# WHY THE OLD CLAUSES EXISTED, kept because it explains what still has to hold. The artifact
# this gate exists for is the one that CREATES the run: a wave's plan is written at Step 3
# into a project whose run verdict is `none`, so the frontmatter contract has to bind before
# there is any run to scope by. That is why the run is not a clause and never was one — the
# verdict is announced above for AC-3/AC-6 and decides nothing here. Engagement, not the
# run, is what makes the write this hook's business.
#
# AND WHY A WRITE IN AN UNRELATED PROJECT STILL PASSES IN SILENCE: engagement is per-root.
# A `deploy.plan.md` in a repository this session never engaged in finds no marker under
# that repository and leaves at the guard, which is the same answer the deleted clauses
# gave, reached one test earlier.

DOCS_ROOT=$(docs_root "$PROJECT_ROOT_FROM_PATH")

# Incident 0001: the audit stream must live where a consuming project cannot
# commit it, regardless of that project's .gitignore. $HOME-rooted, per-project,
# durable — the same $HOME/.claude/ audit path the archived epic-10 poker used
# (that work is recoverable at tag archive/epic-10-never-die).
# Slug = <basename>-<cksum of the absolute path>: readable, deterministic, and
# collision-resistant across same-named projects under different parents.
# cksum and basename are POSIX — no new dependency.
# Byte-identical to the copies in farm-out-reminder.sh,
# canonical-sdlc-evidence-gate.sh and context-spend.sh — divergence would give
# one project two audit files. Deliberate per-hook duplication (no shared lib).
# [INSTRUMENT]
audit_path() {  # $1=project root → absolute audit-file path; rc 1 if no $HOME
  [ -n "${HOME:-}" ] || return 1
  local base sum
  base=$(basename "$1" | sed 's/[^A-Za-z0-9._-]/-/g')
  sum=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  printf '%s/.claude/logs/%s-%s/sdlc-audit.md' "$HOME" "$base" "$sum"
}

BASENAME=$(basename "$FILE_PATH")
ENFORCE=0
case "$BASENAME" in
  *.plan.md|*.spec.md|*.requirements.md|continuation*.md) ENFORCE=1 ;;
  adr-*.md) ENFORCE=1 ;;
esac

# ---------- AC-13: misplacement blocks; absence never does ----------
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
#
# Two facts about the target path, kept separate because they answer different
# questions:
#   IN_SCOPE        — inside one of the four enforced subdirectories, so the
#                     full frontmatter contract applies.
#   UNDER_DOCS_ROOT — inside the docs root at all, so the file is PLACED.
#
# The fail-open this closes: an artifact declaring canonical-sdlc frontmatter
# but living outside the docs root used to fall straight out of the scope check
# and exit 0 — written, ungated, in the wrong place. Slice 1's
# resolve_project_root() always answers, so the historical no-root `exit 0` is
# unreachable; the scope check is the fail-open that survived.
#
# ABSENCE is not misplacement. DOCS_ROOT is COMPUTED, so a brand-new project
# with no `.bionic/` still has one, and its first artifact write targets it and
# passes. Nothing here blocks on `.bionic/` being missing — only on a file that
# names itself a canonical-sdlc artifact while sitting somewhere else.
#
# "Placed" means the whole docs root, not just the four subdirectories:
# `<docs-root>/spikes/` and `<docs-root>/record/` hold real files carrying this
# frontmatter. They pass through unenforced, exactly as they did before.
# Both sides physicalized before comparing, or a symlinked project path makes
# every verdict below wrong. FILE_PATH itself is left alone — it is what the
# messages quote back, and quoting a path the user never typed is its own
# confusion.
FILE_PATH_MATCH=$(physicalize "$FILE_PATH")
DOCS_ROOT_MATCH=$(physicalize "$DOCS_ROOT")

# ---------- R9/AC-13: pinned-root wall ----------
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
#
# The `.bionic` tree is pinned to ONE physical location per project:
# PROJECT_ROOT_FROM_PATH already resolves there via --git-common-dir,
# unaffected by which worktree or subdirectory the write's own path happens
# to sit under (AC-10). What that resolution does NOT already guarantee is
# that the WRITE ITSELF lands there: the target path can carry its own
# `.bionic` path segment that names a different tree entirely — a linked
# worktree's phantom copy, or a stray `.bionic` created a level down inside a
# subdirectory of the main repo — even though the computed root is correct.
# PINNED_BIONIC is the one true tree; TARGET_BIONIC is whichever `.bionic`
# segment (if any) the write's own path names. Scope: this project's single
# pinned root (spec assumption 4) — a multi-project session is out of scope
# by design, not by omission.
#
# THE DEEPEST `.bionic` SEGMENT IS THE TARGET, not the first one (`%` and not `%%` —
# shortest suffix removed, so the prefix kept is the longest). cs review S-2, case C: a
# path naming a second `.bionic` INSIDE the pinned tree —
# `<pinned>/.bionic/tmp/scratch/.bionic/docs/record/x.md` — compared equal to the pinned
# root under the first-match reading and passed. R4 rules that in scope: it is the same
# phantom tree this wall already refuses one directory over (a stray `.bionic` a level
# down inside `subdir/`), and the tree the write actually lands in is the deepest one its
# own path names. The cost of the stricter reading is that a genuinely intended nested
# `.bionic` is blocked with a message naming where to write instead.
PINNED_BIONIC="$PROJECT_ROOT_FROM_PATH/.bionic"
case "$FILE_PATH_MATCH" in
  */.bionic/*) TARGET_BIONIC="${FILE_PATH_MATCH%/.bionic/*}/.bionic" ;;
  */.bionic)   TARGET_BIONIC="$FILE_PATH_MATCH" ;;
  *)           TARGET_BIONIC="" ;;
esac

IN_SCOPE=0
case "$FILE_PATH_MATCH" in
  "$DOCS_ROOT_MATCH"/specs/*|"$DOCS_ROOT_MATCH"/plans/*|"$DOCS_ROOT_MATCH"/adrs/*|"$DOCS_ROOT_MATCH"/incidents/*) IN_SCOPE=1 ;;
esac
UNDER_DOCS_ROOT=0
case "$FILE_PATH_MATCH" in
  "$DOCS_ROOT_MATCH"/*) UNDER_DOCS_ROOT=1 ;;
esac

# Placed, and either not in an enforced subdirectory or not an enforced name:
# nothing to check and no content to read.
if [ "$UNDER_DOCS_ROOT" -eq 1 ] && { [ "$IN_SCOPE" -eq 0 ] || [ "$ENFORCE" -eq 0 ]; }; then
  exit 0
fi

# Determine the content that will exist after the tool runs.
# - Write: the posted `content` is the new file body in full.
# - Edit: the file exists; the hook cannot cheaply simulate the edit, so
#   it enforces a weaker invariant: the file already contains the
#   frontmatter field. If a Write established valid frontmatter, any
#   subsequent Edit inherits it. If an Edit targets a file that never
#   had the frontmatter, the hook blocks and directs the user to Write
#   the artifact from scratch with the required frontmatter block.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
CONTENT=""
if [ "$TOOL" = "Write" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
else
  if [ -f "$FILE_PATH" ]; then
    if [ "$IN_SCOPE" -eq 1 ]; then
      CONTENT=$(cat "$FILE_PATH")
    else
      # Misplacement probe only. This path is reached on EVERY Edit anywhere
      # in the project, and all it inspects is the leading frontmatter block —
      # so read a head, not the whole file. 8 KB is two orders of magnitude
      # more than any frontmatter block; a truncated read can only fail to
      # find the closing `---`, which makes the probe print more, never less.
      CONTENT=$(head -c 8192 "$FILE_PATH")
    fi
  fi
fi

# Normalize line endings to plain \n before any parsing. Strip a trailing
# \r from each record (CRLF: \r\n → \n) and translate any remaining lone \r
# (classic-Mac CR-only: \r without \n) into a real newline. Every parse below
# is line-anchored (the exact-match `$0 == "---"` frontmatter delimiter,
# yaml_get, the matrix grep), so it must see real newlines.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
#
# `tr -d '\r'` (the prior normalization) merely DELETED every \r. On a CRLF
# artifact that happened to work, but on a CR-only artifact it removed every
# line break, collapsing the whole file to ONE line — the frontmatter parser
# then never matched and a VALID artifact was false-BLOCKed as "missing a YAML
# frontmatter block". awk splits on \n by default, so a CR-only file arrives as
# a single record that gsub re-splits into real lines; LF and CRLF files are
# unaffected. Twin of the evidence-gate hook's normalize_newlines.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
CONTENT=$(printf '%s' "$CONTENT" | awk '{ sub(/\r$/, ""); gsub(/\r/, "\n"); print }')

# Extract the leading YAML frontmatter block (between the first two `---`
# lines at column 0). If absent, block.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
FRONTMATTER=$(echo "$CONTENT" | awk '
  NR == 1 && $0 == "---" { inside = 1; next }
  inside && $0 == "---" { exit }
  inside { print }
')

# The misplacement verdict, now that the frontmatter is in hand.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
#
# Reading the LEADING block (and only the leading block) is what keeps a
# documentation page that shows the frontmatter inside a fence from being
# mistaken for an artifact — the fenced example is never at line 1. That trap
# is a recorded recurrence in this repo, not a hypothetical.
#
# Either self-declaration identifies the artifact: `canonical_sdlc_version` is
# the run-state marker the lifecycle stamps, and `governing-skill:
# canonical-sdlc` is what the skill's own Step-0 artifact carries. A file
# carrying neither is not a canonical-sdlc artifact and is none of this hook's
# business, wherever it lives — which is why an ordinary file in an ordinary
# project, in a project with no `.bionic/` at all, passes untouched.
if [ "$UNDER_DOCS_ROOT" -eq 0 ]; then
  if echo "$FRONTMATTER" | grep -qE '^[[:space:]]*(canonical_sdlc_version[[:space:]]*:|governing-skill[[:space:]]*:[[:space:]]*canonical-sdlc[[:space:]]*$)'; then
    case "$BASENAME" in
      *.spec.md|*.requirements.md) MISPLACED_SUBDIR=specs ;;
      adr-*.md)                    MISPLACED_SUBDIR=adrs ;;
      *)                           MISPLACED_SUBDIR=plans ;;
    esac
    echo "BLOCKED: canonical-sdlc artifact '$BASENAME' is misplaced." >&2
    echo "Path: $FILE_PATH" >&2
    echo "It declares canonical-sdlc frontmatter but does not live under this project's docs root." >&2
    echo "Docs root: $DOCS_ROOT" >&2
    echo "Fix: write it under $DOCS_ROOT/$MISPLACED_SUBDIR/ instead." >&2
    echo "     (the docs root is <project>/.bionic/docs by default; override with 'docs-root:' in $PROJECT_ROOT_FROM_PATH/.bionic/config.yaml)" >&2
    exit 2
  fi
  # R9/AC-13: the frontmatter arm above only catches artifacts that
  # self-declare canonical-sdlc frontmatter. An operational artifact (a
  # record/ note, a progress file, anything without that frontmatter)
  # written under a NON-pinned `.bionic` tree would otherwise fall straight
  # through here unblocked — the exact gap this wall closes. A write whose
  # own path carries no `.bionic` segment at all (an ordinary project file)
  # is untouched: TARGET_BIONIC is empty and this arm is silent.
  # [WALL: tests/canonical-sdlc-governing-skill.test.sh]
  if [ -n "$TARGET_BIONIC" ] && [ "$TARGET_BIONIC" != "$PINNED_BIONIC" ]; then
    echo "BLOCKED: artifact write targets '$TARGET_BIONIC', not this project's pinned .bionic root." >&2
    echo "Path: $FILE_PATH" >&2
    echo "Pinned root: $PINNED_BIONIC" >&2
    echo "Fix: write under $PINNED_BIONIC instead — the .bionic tree is pinned to the main repository root at Step 0 and is never re-derived from a worktree or subdirectory copy." >&2
    exit 2
  fi
  exit 0
fi

if [ -z "$CONTENT" ]; then
  echo "BLOCKED: canonical-sdlc artifact '$BASENAME' has no content to validate." >&2
  echo "Path: $FILE_PATH" >&2
  echo "Fix: use Write to create the artifact with governing-skill frontmatter." >&2
  exit 2
fi

if [ -z "$FRONTMATTER" ]; then
  echo "BLOCKED: canonical-sdlc artifact '$BASENAME' is missing a YAML frontmatter block." >&2
  echo "Path: $FILE_PATH" >&2
  echo "Fix: prepend:" >&2
  echo "  ---" >&2
  echo "  governing-skill: <skill-id for the step that produced this artifact>" >&2
  echo "  sdlc-step: <step number>" >&2
  echo "  epic: epic-NN-<slug>" >&2
  echo "  wave: wave-NN-<slug>   # omit for epic-level and continuation" >&2
  echo "  canonical_sdlc_version: ${SUPPORTED_SDLC_VERSION}" >&2
  echo "  intent: <build|bugfix|refactor|tune|spike|incident-response>" >&2
  echo "  rigor: <tested|peer-reviewed|audited>" >&2
  echo "  scale: <task|wave|epic>" >&2
  echo "  ---" >&2
  exit 2
fi

# Enforce presence of the governing-skill field with a non-empty value.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
GOVERNING=$(echo "$FRONTMATTER" \
            | grep -E '^[[:space:]]*governing-skill[[:space:]]*:' \
            | head -1 \
            | sed -E 's/^[[:space:]]*governing-skill[[:space:]]*:[[:space:]]*//' \
            | sed -E 's/[[:space:]]+$//')

if [ -z "$GOVERNING" ]; then
  echo "BLOCKED: canonical-sdlc artifact '$BASENAME' is missing a 'governing-skill:' frontmatter field." >&2
  echo "Path: $FILE_PATH" >&2
  echo "Fix: add a non-empty 'governing-skill: <skill-id>' line to the frontmatter block." >&2
  exit 2
fi

# ---------- canonical-sdlc schema enforcement ----------
#
# Discriminator: `canonical_sdlc_version`, NOT `governing-skill`.
# `governing-skill:` records the per-step skill that wrote a given
# artifact — plans correctly declare `superpowers:writing-plans` because
# Step 3 delegates to that skill. We instead read
# `canonical_sdlc_version`, which Step 0 stamps on every canonical-sdlc
# artifact and is therefore the correct run marker.

yaml_get() {
  echo "$FRONTMATTER" \
    | grep -E "^[[:space:]]*${1}[[:space:]]*:" \
    | head -1 \
    | sed -E "s/^[[:space:]]*${1}[[:space:]]*:[[:space:]]*//" \
    | sed -E 's/[[:space:]]+$//'
}

SDLC_VERSION=$(yaml_get canonical_sdlc_version)

# SUPPORTED_SDLC_VERSION is bound once, near the top of the file (before the
# missing-frontmatter hint that also quotes it). There is no version dispatch below this
# line and no path that reaches `exit 0` without passing the whole contract.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
if [ "$SDLC_VERSION" != "$SUPPORTED_SDLC_VERSION" ]; then
  echo "BLOCKED: canonical-sdlc artifact '$BASENAME' declares canonical_sdlc_version: '$SDLC_VERSION'." >&2
  echo "Path: $FILE_PATH" >&2
  echo "Fix: set 'canonical_sdlc_version: ${SUPPORTED_SDLC_VERSION}' — the only supported version." >&2
  exit 2
fi

# ---------- intent × rigor × scale triple + universal contract ----------
#
# Governance keys off the triple (intent × rigor × scale). Presence +
# whole-value enum validation is blocking; CONTENT is already CR-stripped
# (line 143), so whole-line yaml_get reads compare cleanly under CRLF too.
# The triple's presence is the gate — there is no separate mode axis.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
block() {
  echo "BLOCKED: canonical-sdlc artifact '$BASENAME': $1" >&2
  echo "Path: $FILE_PATH" >&2
  exit 2
}

# Split-brain guard: an artifact declares the triple, never mode.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
[ -z "$(yaml_get mode)" ] || block "artifacts declare intent:/rigor:/scale:, never mode:"
INTENT=$(yaml_get intent); RIGOR=$(yaml_get rigor); SCALE=$(yaml_get scale)
[ -n "$INTENT" ] || block "requires intent: (build|bugfix|refactor|tune|spike|incident-response)"
[ -n "$RIGOR" ]  || block "requires rigor: (tested|peer-reviewed|audited)"
[ -n "$SCALE" ]  || block "requires scale: (task|wave|epic)"
case "$INTENT" in
  build|bugfix|refactor|tune|spike|incident-response) ;;
  *) block "invalid intent: '$INTENT' — allowed: build|bugfix|refactor|tune|spike|incident-response" ;;
esac
case "$RIGOR" in
  tested|peer-reviewed|audited) ;;
  *) block "invalid rigor: '$RIGOR' — allowed: tested|peer-reviewed|audited" ;;
esac
case "$SCALE" in
  task|wave|epic) ;;
  *) block "invalid scale: '$SCALE' — allowed: task|wave|epic" ;;
esac

# ---------- walk: enum (epic-14 AC-3) ----------
#
# `walk:` is optional at THIS hook — an absent key is not this hook's
# concern; the evidence-gate hook fail-closes on absence at Step 5 (A1/A7,
# epic-14-verification-power wave-01 plan). When present, only the literal
# values `required` and `exempt` are legal — anything else (typo, other
# value) blocks, naming both legal values.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
WALK=$(yaml_get walk)
if [ -n "$WALK" ]; then
  case "$WALK" in
    required|exempt) ;;
    *) block "invalid walk: '$WALK' — allowed: required|exempt" ;;
  esac
fi

# ---------- floor-consistency checks (LOG-ONLY; D14, spec R3) ----------
#
# Past the blocking gates above INTENT/RIGOR/SCALE are valid enums. These
# checks compute derivable rigor floors and record a finding when the
# declared rigor violates one. Findings NEVER block: each appends one line
# to $HOME/.claude/logs/<project-slug>/sdlc-audit.md — outside every
# consuming project tree (incident 0001) — AND echoes to stderr, then
# returns 0. Promotion to blocking is a separate later decision made from
# this data. Every read path (config.yaml, epic plan, audit file) is
# fail-open. The evidence-gate hook carries a twin of log_finding (hook
# name differs); a shared hooks-lib extraction is deliberately deferred.
# [INSTRUMENT]
#
# Rigor ordering (normative): tested(0) < peer-reviewed(1) < audited(2).
rigor_rank() {
  case "$1" in
    tested) echo 0 ;;
    peer-reviewed) echo 1 ;;
    audited) echo 2 ;;
    *) echo -1 ;;
  esac
}
log_finding() {  # $1=check-id $2=detail — never blocks, always returns 0
  local f
  if f=$(audit_path "$PROJECT_ROOT_FROM_PATH"); then
    local line="- $(date -u +%Y-%m-%dT%H:%M:%SZ) governing-skill $1: $2 ($FILE_PATH)"
    mkdir -p "$(dirname "$f")" 2>/dev/null \
      && printf '%s\n' "$line" >> "$f" 2>/dev/null
  fi
  echo "canonical-sdlc [$1]: $2" >&2
  return 0
}

# rigor-override: <user> <date> derived=<v> chosen=<v> (epic-14 AC-10/AC-11).
# Only PRESENCE of the key is detected — the fields are never validated,
# matching the existing waiver-token precedent. When present, a
# floor-violation finding logs "user-overridden" instead of the violation
# detail; the write still succeeds either way (log-only never blocks). This
# does NOT cover the "invalid rigor-floor value in config.yaml" finding below
# — that is a data-quality problem in the floor itself, not a user choosing a
# rigor below a valid floor, so the marker does not suppress it.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
RIGOR_OVERRIDE=$(yaml_get rigor-override)
log_floor_finding() {  # $1=check-id $2=violation-detail
  if [ -n "$RIGOR_OVERRIDE" ]; then
    log_finding "$1" "user-overridden"
  else
    log_finding "$1" "$2"
  fi
}

RR=$(rigor_rank "$RIGOR")
# Intent floor / spike cap (derivable from intent + rigor).
[ "$INTENT" = "incident-response" ] && [ "$RR" -lt 2 ] \
  && log_floor_finding intent-floor "incident-response floors at audited, declared $RIGOR"
[ "$INTENT" = "spike" ] && [ "$RR" -gt 0 ] \
  && log_floor_finding spike-cap "spike is capped at tested, declared $RIGOR"

# Project floor: rigor-floor: in <project>/.bionic/config.yaml (fail-open;
# an unparseable/invalid value is its own finding, never a block).
# [INSTRUMENT]
PF=$(grep -E '^rigor-floor:' "$PROJECT_ROOT_FROM_PATH/.bionic/config.yaml" 2>/dev/null \
  | head -1 | sed 's/^rigor-floor:[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '\r')
if [ -n "$PF" ]; then
  PR=$(rigor_rank "$PF")
  if [ "$PR" -lt 0 ]; then
    log_finding project-floor "invalid rigor-floor value '$PF' in config.yaml"
  elif [ "$RR" -lt "$PR" ]; then
    log_floor_finding project-floor "project floor $PF, declared $RIGOR"
  fi
fi

# Epic floor: rigor-floor: in the epic plan's frontmatter (read-only,
# fail-open; missing/unreadable epic plan or missing key → no finding,
# floors are opt-in).
EPIC=$(yaml_get epic)
if [ -n "$EPIC" ] && [ -r "$DOCS_ROOT/plans/$EPIC/epic.plan.md" ]; then
  EF=$(awk '/^---$/{n++;next} n==1' "$DOCS_ROOT/plans/$EPIC/epic.plan.md" \
    | grep -E '^rigor-floor:' | head -1 | sed 's/^rigor-floor:[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '\r')
  if [ -n "$EF" ]; then
    ER=$(rigor_rank "$EF")
    [ "$ER" -ge 0 ] && [ "$RR" -lt "$ER" ] \
      && log_floor_finding epic-floor "epic floor $EF (from $EPIC), declared $RIGOR"
  fi
fi

# ---------- the lease wall: a plan write issued from inside a linked worktree ----------
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
# (spec AC-14; plan slice WALLS; assumption WALLS/6.)
#
# The other half of AC-14's pair — hooks/dispatch-preflight.sh carries the dispatch half.
# A plan is the RUN's artifact and it lives under the main checkout; a plan write issued
# from inside a leased tree is an orchestrator that has moved into a writer's workspace,
# and the tree's branch is where that edit would land. The plan then exists on a branch
# nobody merges until the lease ends, while every hook that reads `active_run` reads the
# main checkout's copy.
#
# PLAN-SCOPED. A spec, an ADR, a record note — those are ordinary artifacts and a writer
# in a tree produces them there by design. Only the file the run is steered by is refused.
#
# AN AGENT CONTEXT IS ALLOWED. Two spellings mark one and either is enough: the payload's
# own `agent_type`, which the harness sets for a dispatched agent, and the settings-channel
# guard's BIONIC_HOOK_CHANNEL. This hook is registered directly on Write|Edit rather than
# behind the guard, so `agent_type` is the spelling that answers here — the other is read
# anyway, because a partition maintained by hand is one edit away from covering neither.
#
# AMBIGUITY PASSES. No cwd in the payload, a cwd outside any repository, a tree whose main
# repository cannot be resolved: this wall has no main checkout to name and says nothing.
case "$BASENAME" in
  *.plan.md)
    LEASE_AGENT=0
    [ "${BIONIC_HOOK_CHANNEL:-}" = "agent-context" ] && LEASE_AGENT=1
    [ -n "$(echo "$INPUT" | jq -r '.agent_type // empty')" ] && LEASE_AGENT=1
    LEASE_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
    if [ "$LEASE_AGENT" -eq 0 ] && [ -n "$LEASE_CWD" ] && [ -d "$LEASE_CWD" ]; then
      # A linked worktree's `.git` is a FILE pointing into the shared repository; the main
      # checkout's is a directory. Same test scripts/lib/worktree.sh's land verb uses.
      LEASE_TOP=$(git -C "$LEASE_CWD" rev-parse --show-toplevel 2>/dev/null) || LEASE_TOP=""
      if [ -n "$LEASE_TOP" ] && [ -f "$LEASE_TOP/.git" ]; then
        LEASE_TOP=$( cd "$LEASE_TOP" 2>/dev/null && pwd -P ) || LEASE_TOP=""
      else
        LEASE_TOP=""
      fi
      if [ -n "$LEASE_TOP" ]; then
        # `--path-format=absolute` needs git >= 2.31; the second arm resolves a relative
        # answer against the tree, as lib/root.sh's own walk does.
        LEASE_COMMON=$(git -C "$LEASE_TOP" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || LEASE_COMMON=""
        if [ -z "$LEASE_COMMON" ]; then
          LEASE_COMMON=$(git -C "$LEASE_TOP" rev-parse --git-common-dir 2>/dev/null) || LEASE_COMMON=""
          case "$LEASE_COMMON" in ""|/*) ;; *) LEASE_COMMON="$LEASE_TOP/$LEASE_COMMON" ;; esac
        fi
        LEASE_MAIN=""
        [ -n "$LEASE_COMMON" ] && LEASE_MAIN=$( cd "$LEASE_COMMON/.." 2>/dev/null && pwd -P )
        if [ -n "$LEASE_MAIN" ] && [ "$LEASE_MAIN" != "$LEASE_TOP" ]; then
          echo "BLOCKED: canonical-sdlc plan '$BASENAME' is being written from inside a linked worktree." >&2
          echo "" >&2
          echo "    cwd:           $LEASE_CWD" >&2
          echo "    worktree:      $LEASE_TOP" >&2
          echo "    main checkout: $LEASE_MAIN" >&2
          echo "" >&2
          echo "The plan is the run's own artifact and it lives in the main checkout: written here" >&2
          echo "it lands on the tree's branch, where every hook that reads the active run cannot" >&2
          echo "see it until the lease ends." >&2
          echo "" >&2
          echo "Fix: write the plan from $LEASE_MAIN. A dispatched agent working in its own tree" >&2
          echo "may write there — this refusal is the main thread's alone." >&2
          exit 2
        fi
      fi
    fi
    ;;
esac

# ---------- `parallel-budget:` is ACCEPTED, and deliberately not validated ----------
# (spec AC-26; assumption WALLS/5.)
#
# Step 0 writes the run's resource ceiling into plan frontmatter as one string —
# `parallel-budget: writers=N suites=N worktrees=N test_jobs=N source=probe|override` —
# byte-identical to the `budget=` value the preflight attestation records. It is optional:
# a plan with it and a plan without it both write, which is what keeps every plan predating
# the line writable. This hook does not parse it. Its only consumer is the budget arm in
# hooks/dispatch-preflight.sh, which is where a budget can actually refuse something and
# which already declines to act on a field it cannot read; a second opinion about the same
# string here would be a second place for that reading to drift.

# ---------- required frontmatter flags + model_plan ----------
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
REQUIRED_OPT_IN=("cleanup_on_finish" "use_worktree")
REQUIRED_DISCRIMINATORS=("surface_type" "language" "has_ui" "multi_agent" "deploy_target")

MISSING=()
for flag in "${REQUIRED_OPT_IN[@]}" "${REQUIRED_DISCRIMINATORS[@]}"; do
  if ! echo "$FRONTMATTER" | grep -qE "^[[:space:]]*${flag}[[:space:]]*:"; then
    MISSING+=("$flag")
  fi
done

# `model_plan` (the Step-0 model-tier decision) is checked as a separate
# conditional grep — NOT an array element — to stay safe under `set -u` with
# bash 3.2's empty-array expansion behaviour.
if ! echo "$FRONTMATTER" | grep -qE "^[[:space:]]*model_plan[[:space:]]*:"; then
  MISSING+=("model_plan")
fi

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "BLOCKED: canonical-sdlc plan '$BASENAME' is missing required frontmatter flags: ${MISSING[*]}" >&2
  echo "Path: $FILE_PATH" >&2
  echo "Fix: run Step 0 (Configure) to set these explicitly. See SKILL.md §Step 0." >&2
  echo "Required opt-in flags:        ${REQUIRED_OPT_IN[*]}" >&2
  echo "Required discriminator flags: ${REQUIRED_DISCRIMINATORS[*]}" >&2
  echo "Required:                     model_plan" >&2
  exit 2
fi

# ---------- pre-registered Verification Matrix required at Step 3+ ----------
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
#
# Step 0 derives a "## Verification Matrix" section (per-AC tier + status +
# evidence, locked at Step 3 approval — see canonical-sdlc SKILL.md's
# "Verification Matrix" sub-step under Step 0). This hook checks section
# PRESENCE only (structure, not substance); the evidence-gate hook validates
# the per-row per-tier fields and the CONFIRMED/waived auditor discipline
# (structure vs substance split mirrors the model_plan / flag checks above).
#
# Scope: basename *.plan.md, sdlc-step >= 3 (numeric). Specs,
# continuation*.md and scale: task plans (they carry a ## Tasks ledger, not a
# matrix) are out of scope — the matrix is a wave/epic plan-body artifact
# that exists starting at Step 3 (Plan) approval.
case "$BASENAME" in
  *.plan.md)
    SDLC_STEP=$(yaml_get sdlc-step)
    case "$SDLC_STEP" in
      ''|*[!0-9]*) ;;  # non-numeric or empty sdlc-step → not in scope
      *)
        if [ "$SDLC_STEP" -ge 3 ] 2>/dev/null && [ "$SCALE" != "task" ]; then
          if ! echo "$CONTENT" | grep -qE '^## Verification Matrix'; then
            echo "BLOCKED: canonical-sdlc plan '$BASENAME' (sdlc-step ${SDLC_STEP}) is missing a '## Verification Matrix' section." >&2
            echo "Path: $FILE_PATH" >&2
            echo "Fix: derive the matrix at Step 0 (see SKILL.md §Step 0 'the Verification Matrix') and lock it at Step 3 approval." >&2
            exit 2
          fi
        fi
        ;;
    esac
    ;;
esac

# ---------- design wall: the three-way rule (wave-02 AC-2/AC-3/AC-4) ----------
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
#
# A wave-or-epic-scale SPEC blocks unless it carries one of three things: a
# flush-left `## Design` section in place; a frontmatter `design:` pointer that
# resolves to a real file carrying one; or a `design-waived:` token. Design is
# the back half of Step 2, and this is the wall that makes it load-bearing.
# The arms are not interchangeable in the order they are tried — see the
# PRECEDENCE note at the branch chain below.
#
# PRESENCE AND RESOLUTION ONLY. The hook never inspects the section's five
# parts — an empty `## Design` passes here and fails at the Step-3 approval,
# which is where a human ratifies design + plan + matrix together. Quality is
# not a hook's job (spec §Design, assumption 4).
#
# Scope is `*.spec.md` at scale wave|epic. Task scale is deliberately untouched
# (R5: a task gets a design paragraph in its session plan, prose-obliged and
# reviewer-checked, never a wall), and plans are untouched because the design
# lives in the spec. Keying on BASENAME rather than on the `specs/` directory
# follows the matrix gate immediately above: a spec artifact is a spec artifact
# wherever under the docs root it was filed, and the alternative leaves a
# rename-free dodge.
#
# WRITE ONLY. On Edit, CONTENT is the file's PRE-edit body, so an Edit arm
# would answer a question nobody asked — it would pass an edit that strips the
# section and block every edit to the pre-W2 specs that predate the rule. The
# post-edit hole is the hook's existing, documented Edit weakness (see the
# CONTENT block above); this arm does not widen it and does not pretend to
# close it.
case "$BASENAME" in
  *.spec.md)
    if [ "$TOOL" = "Write" ] && { [ "$SCALE" = "wave" ] || [ "$SCALE" = "epic" ]; }; then

      # Resolution follows the evidence-gate hook's walk-artifact template
      # (resolve_walk_path): absolute stands, a docs-root subdirectory leader is
      # docs-root-relative, anything else is project-relative — so the
      # fully-spelled `.bionic/docs/specs/...` an author is likely to paste
      # lands in the same place as the short form. The leader set is widened
      # from the walk arm's single `record/` because a governing design can live
      # in any artifact directory; unlike the walk artifact it is NOT contained
      # to one, since an epic-level design a wave implements may legitimately
      # sit outside this project's docs root entirely.
      resolve_design_path() {  # $1 = raw design: value
        case "$1" in
          /*) printf '%s\n' "$1" ;;
          specs/*|plans/*|adrs/*|incidents/*|record/*) printf '%s/%s\n' "$DOCS_ROOT" "$1" ;;
          *)  printf '%s/%s\n' "$PROJECT_ROOT_FROM_PATH" "$1" ;;
        esac
      }

      # Every block from this arm names all three ways out, whichever arm the
      # author was reaching for — the author who mistyped a pointer may well be
      # the author who should have written the section.
      block_design() {  # $1 = what went wrong
        echo "BLOCKED: canonical-sdlc spec '$BASENAME' (scale: $SCALE): $1" >&2
        echo "Path: $FILE_PATH" >&2
        echo "A wave- or epic-scale spec must satisfy one of three:" >&2
        echo "  (a) a flush-left '## Design' section in this spec;" >&2
        echo "  (b) frontmatter 'design: <path>' naming a file that carries a flush-left '## Design';" >&2
        echo "  (c) frontmatter 'design-waived: <user> <date> <reason>' — a user-only move." >&2
        exit 2
      }

      # `## Design` must be flush left and must be the whole heading word:
      # `## Design — v2` is the section, `## Designer notes` is not. The matrix
      # gate's bare prefix match would accept both; the trailing-boundary
      # requirement costs nothing and is the difference between a wall and a
      # word search. `[[:space:]]` covers a CRLF target's trailing \r.
      DESIGN_HEADING='^## Design([[:space:]]|$)'

      # Fence-aware on BOTH read paths, matching the evidence-gate hook, whose
      # `## SDLC State` reads all skip ``` fenced blocks for the same reason: a
      # spec that EXPLAINS this contract will show `## Design` as an example,
      # and an example is documentation, not a section. Stripping fences before
      # the grep keeps one heading regex for both paths rather than a second
      # rendering of it inside awk.
      strip_fences() {  # a document on stdin → the same document, fences dropped
        awk '
          /^[[:space:]]*```/ { fence = !fence; next }
          fence { next }
          { print }
        '
      }

      # The pointer target is read off disk, so it needs the same normalization
      # `$CONTENT` got at the top of this hook — the stdin twin of the evidence
      # gate's normalize_newlines(). The template this arm follows was copied for
      # its path half and not its read half: CRLF survives a line-anchored grep
      # (`[[:space:]]` eats the trailing \r), but a CR-only document arrives as
      # ONE record, so no `## Design` is ever at a line start and a legitimate
      # target false-BLOCKs. CRLF coverage does not catch this class — see
      # `.claude/rules/hook-authoring.md`, and c14 for the case that does.
      # [WALL: tests/canonical-sdlc-governing-skill.test.sh]
      normalize_newlines() {  # a document on stdin → the same document, LF-split
        awk '{ sub(/\r$/, ""); gsub(/\r/, "\n"); print }'
      }

      DESIGN_POINTER=$(yaml_get design)
      # Presence-only, matching the `rigor-override:` waiver precedent: the
      # fields are recorded for the reader, never validated here. Read by grep
      # rather than yaml_get so that a bare `design-waived:` — a malformed
      # waiver, but unmistakably a user's waiver — still counts as present.
      DESIGN_WAIVED=0
      if echo "$FRONTMATTER" | grep -qE '^[[:space:]]*design-waived[[:space:]]*:'; then
        DESIGN_WAIVED=1
      fi

      # PRECEDENCE: waiver short-circuits everything; below it, a PRESENT
      # `design:` pointer validates unconditionally — resolved, existence-checked
      # and `..`-refused whether or not the spec also carries its own section —
      # and only the absence of a pointer falls through to the in-place read.
      # [WALL: tests/canonical-sdlc-governing-skill.test.sh]
      #
      # The order matters because the pointer is not one of three interchangeable
      # ways to be quiet: it is the path the Step-3 approval display prints for
      # the user to open (R2/AC-1). The combined shape — pointer plus a local
      # delta section — is the one the docs recommend, so an `elif` that let the
      # section satisfy the wall first made the recommended shape the one where a
      # typo, a moved epic design or a rename produced an approval display citing
      # nothing, with the wall silent. A pointer is never decorative (critic C-3).
      #
      # The waived path is deliberately NOT symmetric: `design-waived:` still
      # silences a broken pointer beside it. That contradiction is a separate,
      # known finding, and closing it here would smuggle a second rule into a
      # repair scoped to the unwaived path.
      if [ "$DESIGN_WAIVED" -eq 1 ]; then
        :
      elif [ -n "$DESIGN_POINTER" ]; then
        # A `..` component is refused outright rather than normalized, mirroring
        # the walk arm: a design named by climbing out of the directory it was
        # named relative to is a spelling nobody should have to audit, and the
        # refusal holds even when the climb would land on a real design.
        if echo "$DESIGN_POINTER" | grep -qE '(^|/)\.\.(/|$)'; then
          block_design "design: '$DESIGN_POINTER' climbs out with a '..' component and is refused."
        fi
        DESIGN_ABS=$(resolve_design_path "$DESIGN_POINTER")
        if [ ! -f "$DESIGN_ABS" ]; then
          block_design "design: '$DESIGN_POINTER' names no file (resolved to $DESIGN_ABS)."
        fi
        if ! normalize_newlines < "$DESIGN_ABS" 2>/dev/null | strip_fences | grep -qE "$DESIGN_HEADING"; then
          block_design "design: '$DESIGN_POINTER' resolves to $DESIGN_ABS, which carries no flush-left '## Design' section."
        fi
      elif ! echo "$CONTENT" | strip_fences | grep -qE "$DESIGN_HEADING"; then
        block_design "no design. It carries no '## Design' section, no 'design:' pointer and no waiver."
      fi
    fi
    ;;
esac

# ---------- adrs: pointer arm (K3 F4 / D6) ----------
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
#
# D6: a momentous decision gets its ADR drafted at Step 2, filed under
# `<docs-root>/adrs/…`, and named from the spec's `adrs:` frontmatter — one
# path, or several joined by ` · ` (the separator env_split_entries in
# canonical-sdlc-evidence-gate.sh and agents.sh's peer-session parser already
# use for a multi-value line; reused here rather than reinvented). Resolution
# copies `resolve_design_path` above one clause up: an absolute path stands,
# a docs-root artifact-directory leader (`specs/`, `plans/`, `adrs/`,
# `incidents/`, `record/`) resolves against the docs root, everything else
# resolves project-relative, and a `..` component is refused outright. Its
# own function (`resolve_adrs_path`) rather than a call into the design arm's
# — that function is defined conditionally, inside the design arm's own `if`,
# and this arm must not assume it ran.
#
# SCOPED to `sdlc-step >= 3` only. Below that — Step 2, where the spec first
# names the ADR it is drafting alongside itself — a dangling path is not yet
# a defect: the pointer and the file it names are authored in the same
# design pass, and the file may not exist on the turn the pointer is typed.
# PRESENCE-ONLY, like `design:`'s pointer check for the target file: unlike
# `design:`, this arm does not also require a fixed heading inside the
# target — an ADR has no equivalent section name to grep for, and D6 asks
# only that the file the pointer names is real.
#
# Absence of `adrs:` is never blocked: a wave that ratified no momentous
# decision cites none, and the arm has nothing to validate.
case "$BASENAME" in
  *.spec.md)
    if [ "$TOOL" = "Write" ] && { [ "$SCALE" = "wave" ] || [ "$SCALE" = "epic" ]; }; then
      ADRS_STEP=$(yaml_get sdlc-step)
      case "$ADRS_STEP" in
        ''|*[!0-9]*) ;;  # non-numeric or empty sdlc-step -> not in scope
        *)
          if [ "$ADRS_STEP" -ge 3 ] 2>/dev/null; then
            ADRS_RAW=$(yaml_get adrs)
            if [ -n "$ADRS_RAW" ]; then
              resolve_adrs_path() {  # $1 = one raw adrs: path
                case "$1" in
                  /*) printf '%s\n' "$1" ;;
                  specs/*|plans/*|adrs/*|incidents/*|record/*) printf '%s/%s\n' "$DOCS_ROOT" "$1" ;;
                  *)  printf '%s/%s\n' "$PROJECT_ROOT_FROM_PATH" "$1" ;;
                esac
              }
              while IFS= read -r ADR_ONE; do
                [ -n "$ADR_ONE" ] || continue
                if echo "$ADR_ONE" | grep -qE '(^|/)\.\.(/|$)'; then
                  echo "BLOCKED: canonical-sdlc spec '$BASENAME' (sdlc-step ${ADRS_STEP}): adrs: '$ADR_ONE' climbs out with a '..' component and is refused." >&2
                  echo "Path: $FILE_PATH" >&2
                  exit 2
                fi
                ADR_ABS=$(resolve_adrs_path "$ADR_ONE")
                if [ ! -f "$ADR_ABS" ]; then
                  echo "BLOCKED: canonical-sdlc spec '$BASENAME' (sdlc-step ${ADRS_STEP}): adrs: '$ADR_ONE' names no file (resolved to $ADR_ABS)." >&2
                  echo "Path: $FILE_PATH" >&2
                  echo "Fix: draft the ADR at that path, or correct the adrs: pointer." >&2
                  exit 2
                fi
              done < <(printf '%s\n' "$ADRS_RAW" | awk '{
                n = split($0, parts, /[ \t]*·[ \t]*/)
                for (i = 1; i <= n; i++) {
                  e = parts[i]
                  gsub(/^[ \t]+|[ \t]+$/, "", e)
                  if (e != "") print e
                }
              }')
            fi
          fi
          ;;
      esac
    fi
    ;;
esac

# ---------- AC-11 / AC-12: tree creation on first lifecycle use ----------
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
#
# Slice 2 (F4): neither hook has an entry point that fires on true first
# lifecycle use without requiring `.bionic/` to pre-exist — except this one.
# The governing-skill hook already knows the target artifact's path and, as
# of slice 1, computes PROJECT_ROOT_FROM_PATH from git rather than by
# walking for an existing `.bionic/`. Creation hangs off that same
# computation.
#
# The discriminator is `canonical_sdlc_version` — the SAME field the schema
# enforcement above reads, and for the same reason. Slice 2 keyed creation on
# `governing-skill: canonical-sdlc` instead, which is the artifact-AUTHOR
# field; `.claude/rules/hook-authoring.md` (machine-local, gitignored, authored
# in place — no script recreates it, so absent from a fresh clone) § "Discriminators in
# enforcement hooks" names that as a known failure mode, because Step 3 plans legitimately
# declare `governing-skill: superpowers:writing-plans` and would have found no
# tree. Slice 2's stated rationale was avoiding a re-fire on later artifacts,
# and re-firing costs nothing: `mkdir -p` is idempotent and the `.gitignore`
# write is `[ -f ]`-guarded.
#
# Deliberately NOT a SessionStart hook: that would create `.bionic/` in
# every repo the user opens a session in. "First lifecycle use" is the
# first canonical-sdlc artifact write, not the first session — see the
# wave-level Not Doing.
#
# PLACEMENT (Step-6 findings C5 / F3 / S4): this block used to sit immediately
# after SDLC_VERSION was read, i.e. AHEAD of the version, triple, flag and
# matrix gates — so a write this hook then REFUSED still left a full tree and a
# `.gitignore` behind, in a repo named by the tool call's own `file_path`. A
# PreToolUse gate must not mutate the filesystem for a call it denies. It now
# runs at the single `exit 0`, past every gate, so the tree is created only for
# an artifact that satisfies the ENTIRE contract — not merely one carrying a
# version marker. Nothing between the old and new positions reads the tree:
# `log_finding` writes under `$HOME/.claude/logs/`, the config.yaml and epic
# plan reads are `[ -r ]`/`2>/dev/null` fail-open and target files this block
# never creates.
#
# Neither call can block — no new exit path is added here; failure to create is
# left to whatever already handles an unwritable project tree elsewhere. The
# `.gitignore` redirect is braced so that the SHELL's failure message (the
# redirection is performed before `printf` runs, so `printf 2>/dev/null` would
# silence nothing) is suppressed too — matching the `mkdir -p ... 2>/dev/null`
# beside it. An allowed tool call must leave stderr clean.
#
# THE SCAFFOLD USES `$DOCS_ROOT`, NOT A LITERAL (epic-22 wave-01, N1). This block spelled
# `$PROJECT_ROOT_FROM_PATH/.bionic/docs/...` while the hook forty lines up had already
# resolved `docs-root:` into `$DOCS_ROOT` — so a project that set the key got the DEFAULT
# tree scaffolded and its configured tree never created, and then met this hook's own
# misplacement refusal for writing into the tree it had asked for. One resolver, one answer:
# the four leaders hang off `$DOCS_ROOT` and the two state directories off `tmp_root` and
# `bionic_root`.
# [WALL: tests/canonical-sdlc-governing-skill.test.sh]
if [ -n "$SDLC_VERSION" ]; then
  mkdir -p \
    "$(tmp_root "$PROJECT_ROOT_FROM_PATH")" \
    "$DOCS_ROOT/specs" \
    "$DOCS_ROOT/plans" \
    "$DOCS_ROOT/adrs" \
    "$DOCS_ROOT/incidents" \
    2>/dev/null
  BIONIC_GITIGNORE="$(bionic_root "$PROJECT_ROOT_FROM_PATH")/.gitignore"
  [ -f "$BIONIC_GITIGNORE" ] || { printf '*\n' > "$BIONIC_GITIGNORE"; } 2>/dev/null
fi

exit 0
