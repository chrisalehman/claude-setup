#!/bin/bash
# EVIDENCE GATE: Blocks git commits during a canonical-sdlc run when the
# plan file's ## SDLC State section is missing the current step's evidence.
#
# Convention: the plan file contains a section like:
#
#   ## SDLC State
#   integration-branch: main
#   current: 5
#   Step 1: /path/or/link
#   Step 2: /path/to/spec.md
#   Step 3: .bionic/docs/plans/epic-NN-<slug>/wave-NN-<slug>.plan.md
#   Step 4: git worktree at /path, base SHA abc123
#   Step 5: tests passing, commit abc123
#
# If the current step's line is empty or a placeholder (TODO, pending,
# in progress, XXX, TBD, placeholder), block the commit. The rule is:
# the evidence artifact must be recorded in the plan file *before* the
# commit that closes the step.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
#
# Plans without ## SDLC State pass through unblocked — this hook only
# enforces against canonical-sdlc runs.
#
# Exit code 2 = block the tool call entirely in Claude Code hooks.
#
# Registered once in hooks/hooks.json, always on. It is not scoped by whether a skill
# is armed — an on-disk fact is: the hook loads the library, asks `session_run` (which was
# `active_run` until wave-session-bound-run made run identity per-session) whether THIS
# SESSION has an open run, and exits silently when it does not.
#
# WHEN THE LIBRARY DOES NOT LOAD, that order inverts: the scope question has to be
# answered BEFORE the fail-closed refusal, and answered without the library. See the
# ancestor walk just below the loader block.

set -u

# THE COMMAND IS READ BEFORE THE LIBRARY IS. Not for convenience: the repair
# allowlist in `loader_fail_closed` needs the command text, and it has to be
# consulted BEFORE this wall decides to refuse — otherwise a broken publish locks
# the user out of the very commands that repair it (R-1 §(5), the lockout this wave
# is named for). `jq` on the payload is the one read that does not need the library.
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Not a Bash tool call or empty command — nothing to gate, and nothing the library
# would have been consulted about.
if [ -z "$COMMAND" ]; then
  exit 0
fi

# THE LIBRARY: the command reader (git-argv.sh), the root (root.sh) and the run
# predicate (run.sh). One idiom, byte-identical in every hook — see
# payload/scripts/lib/loader.sh, which is where this text comes from and what
# tests/hook-adoption.test.sh pins each copy against.
#
# FAIL-CLOSED (design ledger S4, Chris D1 2026-08-30): this is a wall over an
# IRREVERSIBLE action, so it refuses rather than waving a command through it cannot
# read — after permitting the four repair commands by whole-string match.
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

# ARMED BEFORE REFUSING. This wall is fail-CLOSED, and the decision is taken HERE — at
# load time, hundreds of lines before `active_run` gets asked whether this project has
# a run, because `active_run` lives in the library that just failed to load. Left at
# that, a half-updated plugin refuses every Bash command in EVERY project on the
# machine, `ls` included, in repositories that carry no `.bionic` and never had a run.
# That is not the wall being cautious; it is the wall firing outside its own reach.
# [WALL: tests/hook-adoption.test.sh §6b]
#
# So the cheapest fact that needs no library is read first: COULD a run exist here? A
# run lives in a `.bionic` directory at or above the payload cwd. None → exit 0 in
# silence. One → the fail-closed path below, repair allowlist and all, unchanged.
#
# The walk is lib/root.sh's rules 3 and 4 restated by hand, which is the one place in
# this repo that duplication is the design: the file that owns those rules is exactly
# what cannot be sourced. A `.bionic` SYMLINK is not a `.bionic` (rule 3); `$HOME` and
# above are never inspected (rule 4). Canonicalisation is `cd … && pwd -P` — stock
# macOS ships no `realpath`. The walk is bounded three ways: `/`, `$HOME`, 64 levels.
#
# hooks/protect-main.sh deliberately carries NO such pre-check. It guards a push in
# every project on the machine, wave or no wave, so its reach IS every project.
_bionic_gate_abs() {  # <path> -> absolute, symlink-resolved, nearest existing ancestor
  _bga_p="${1:-}"
  [ -n "$_bga_p" ] || _bga_p="$PWD"
  case "$_bga_p" in /*) ;; *) _bga_p="$PWD/$_bga_p" ;; esac
  while [ -n "$_bga_p" ] && [ "$_bga_p" != "/" ] && [ ! -d "$_bga_p" ]; do
    _bga_p="$(dirname "$_bga_p")"
  done
  ( cd "$_bga_p" 2>/dev/null && pwd -P ) || printf '%s\n' "$_bga_p"
}
_bionic_gate_run_possible() {  # <cwd> -> 0 when a real `.bionic` sits at or above it
  _bgr_p="$(_bionic_gate_abs "${1:-}")"
  _bgr_home=""
  [ -n "${HOME:-}" ] && _bgr_home="$(_bionic_gate_abs "$HOME")"
  _bgr_n=0
  while [ -n "$_bgr_p" ] && [ "$_bgr_p" != "/" ] && [ "$_bgr_n" -lt 64 ]; do
    if [ -n "$_bgr_home" ]; then
      # $HOME itself, or any ancestor of it. Walking further up only finds more
      # ancestors of $HOME, so stopping here is the whole of rule 4.
      [ "$_bgr_p" = "$_bgr_home" ] && return 1
      case "$_bgr_home/" in "$_bgr_p/"*) return 1 ;; esac
    fi
    if [ ! -L "$_bgr_p/.bionic" ] && [ -d "$_bgr_p/.bionic" ]; then return 0; fi
    _bgr_p="$(dirname "$_bgr_p")"
    _bgr_n=$((_bgr_n + 1))
  done
  return 1
}
if [ -n "$BIONIC_LIB_MISSING" ]; then
  # The same cwd this hook resolves its project from below (CLAUDE_PROJECT_DIR, then
  # the payload, then $PWD), read here without the library because the answer decides
  # whether the library's absence is this gate's business at all.
  _BG_CWD="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$_BG_CWD" ] || _BG_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  [ -n "$_BG_CWD" ] || _BG_CWD="$PWD"
  _bionic_gate_run_possible "$_BG_CWD" || exit 0
  loader_fail_closed "canonical-sdlc-evidence-gate" "$COMMAND"
fi
# shellcheck source=/dev/null
. "$BIONIC_LIB/git-argv.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/root.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/run.sh"
# shellcheck source=/dev/null
. "$BIONIC_LIB/session.sh"

# Is any segment of the command a `git commit`? The library answers by argv
# position: git must be argv[0] (after leading VAR=value assignments and git's
# own global options) and `commit` the subcommand. That is what makes
# `git -C <dir> commit`, `git -c user.name=x commit` and
# `git --no-pager commit` commits — all three were invisible to the string
# match this replaced — while `echo "we will git commit later"` and a heredoc
# body naming a commit stay silent.
# [WALL: tests/git-argv.test.sh]
IS_COMMIT=0
if git_argv_has_sub "$COMMAND" commit; then
  IS_COMMIT=1
fi

if [ "$IS_COMMIT" -eq 0 ]; then
  exit 0
fi

# Locate the newest plan file across THIS PROJECT's plan directories:
#   - <docs-root>/plans/      (bionic canonical-sdlc convention)
#   - <docs-root>/incidents/  (incident-response runs)
#
# Picks the newest .md across those that exist. If none exist, this isn't a
# canonical-sdlc session — let the commit through (see ABSENT vs MISPLACED
# below).
#
# NOT searched, deliberately: `~/.claude/plans/` and
# `<project>/docs/superpowers/plans/`. Both were in the search set until
# 2026-07-28; bionic gates bionic's plans, full stop (user ruling). The global
# directory is the harness's own, project-AGNOSTIC one — Claude Code's plan mode
# drops unrelated notes there routinely, and selection takes the newest .md
# across the whole set. One such note therefore won selection, carried no
# `## SDLC State`, and this hook exited 0: every commit in that project ran
# ungated. The superpowers directory was the same pre-`.bionic/docs` vestige
# (the root `docs/` tree was deleted 2026-07-16); nothing writes canonical plans
# to either.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
#
# Project resolution mirrors memory-update.sh: CLAUDE_PROJECT_DIR first,
# then the hook input's cwd field, then pwd. Consistent with existing hooks.
# That value NAMES the invoking directory; the ROOT is computed from it below.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
fi
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR=$(pwd)
fi

# THE ROOT, from the library (spec AC-10, lib/root.sh). This used to be a private
# `resolve_project_root()` — one of eight byte-identical copies across hooks/, held
# together by an agreement suite that could only ever prove they had not drifted YET.
# The eight are gone; `project_root` is the one answer, and it is a strictly better
# one: the old copy asked git for the root and stopped there, so a project whose
# `.bionic/` sat ABOVE the repo (a repo nested in a workspace) resolved to the repo
# and every artifact path this gate checks landed in the wrong tree.
#
# THE WORKTREE CASE, which the old copy did get right and this one keeps: a linked
# worktree maps back onto its main repository, so every worktree of one repo
# resolves to ONE root and therefore one audit file, one docs root, one plan. Obeying
# the governing hook and the gate at once was impossible before that mapping existed.
PROJECT_DIR=$(project_root "$PROJECT_DIR")

# ---------- THE ENGAGEMENT GUARD (AC-6): is this session bionic's at all? ----------
#
# FIRST, above everything this gate decides — above the plan hygiene below, above the
# misplacement sweep, above the run predicate. Chris, 2026-09-03: "all guardrails
# imposed by bionic should only apply when exercising bionic. Nothing should apply until
# bionic is triggered" — and the trigger is the canonical-sdlc skill, which writes
# `.bionic/tmp/engaged-<sid>.state` at the instant it is invoked. A commit from a session
# that never invoked it is not this gate's business: exit 0, no stdout, no stderr.
#
# THE ORDERING CONTRACT BELOW IS UNCHANGED, and this guard does not join it. Plan hygiene
# still sits ABOVE the run predicate, so an engaged session committing against a
# malformed plan is still refused whether or not a run is open — the question this line
# asks is not "is there a run" but "is this session bionic's at all", and it is prior to
# both.
#
# EVERY UNREADABLE STATE READS AS NOT ENGAGED — absent marker, a symlink at the path, a
# foreign or unshaped session key, no key at all. The marker is the one artifact whose
# PRESENCE opens a wall, so the fail direction is inverted here on purpose, and it is
# inverted against this file's own fail-CLOSED posture on the library: the arming
# partition is the consent boundary (1.3.2 close-out), and a wall that binds a session
# which never consented is the defect this guard exists to remove.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
EG_SID=$(session_id "$(echo "$INPUT" | jq -r '.session_id // empty')" 2>/dev/null) || EG_SID=""
engaged_session "$PROJECT_DIR" "$EG_SID" || exit 0

# THE DOCS ROOT, FROM THE LIBRARY. This hook carried `resolve_docs_root()` and was the
# designated ORIGIN of the four hook copies cross-gate §R held body-for-body. There are no
# copies now: lib/roots.sh's `docs_root` is the one definition and every former carrier is
# a caller, held by cross-gate §Roots (epic-22 wave-01, N1).
#
# Read unconditionally, next to the other globals: this hook runs `set -u`, and
# a variable bound on only some code paths crashes the others. See
# `.claude/rules/hook-authoring.md` § "`set -u` and conditionally-bound variables".
# The misplacement sweep below is this value's only remaining consumer — plan
# SELECTION moved to the library.
DOCS_ROOT=$(docs_root "$PROJECT_DIR")

# THE PLAN, from the library (lib/run.sh's `active_plan`). This used to be a private
# `has_sdlc_state()` plus a newest-.md walk — one of five copies of one question
# ("which plan is the active one") that every wall in the fleet asked separately. A
# wall that picks a different plan than the predicate that armed it is a wall
# enforcing against a run nobody is in, so the two facts now come from one reader.
#
# A CANDIDATE IS STILL A PLAN ONLY IF IT CARRIES A `## SDLC State` HEADING. Without
# that filter a stray marker-less *.md that happens to be newest under plans/ — a
# continuation note, a Step-9 artifact, a probe scrap — wins the newest race,
# `current:` parses empty, and every wall reading it passes silently while a wave is
# live. That is measured, not hypothetical: it disarmed the dispatch wall repo-wide
# for ~15 minutes on 2026-08-15 (record/session-20260815-landing-supervision/
# t8-forensic-read.md). The filter lives in `active_plan` now.
#
# WHICH plan, THOUGH, IS THE SESSION'S OWN QUESTION SINCE wave-session-bound-run
# (2026-09-04, spec AC-1/AC-3/AC-6). `active_plan` answers a ROOT: the newest plan under
# this project's docs root. Engagement is keyed to a SESSION. Two engaged sessions in one
# repository therefore shared one run identity, and this gate — whose whole subject is the
# plan a commit is measured against — measured both sessions' commits against whichever
# plan was newest. `session_run` is the reader that asks the session's own marker first;
# its verdict is taken ONCE here and consumed at both of this hook's resolution sites, so
# the file that gets validated and the run that decides whether to enforce can never
# disagree about which run this session is in.
#
#   bound-open <p>    this session's own plan, open      -> <p> is THE plan; enforce
#   bound-closed <p>  its own plan, delivered/gone       -> <p> is THE plan; do not enforce
#   fallback <p>      no binding: today's newest-plan    -> announced, then today's path
#   none              no binding and no open run         -> today's path, unchanged
#
# A BOUND SESSION NEVER FALLS THROUGH TO ANOTHER PLAN (AC-6). `bound-closed` is a terminal
# answer, not a miss to recover from: the moment a run closes is exactly the moment a scan
# would hand its session somebody else's run, which is the failure this wave was opened on.
# So the closed plan stays THE plan here — the hygiene refusals below still judge it,
# because a plan that lies is a defect in every state and this hook's ordering contract
# says so — and nothing else in the root is read to replace it.
EG_RUN=$(session_run "$PROJECT_DIR" "$EG_SID")
EG_VERDICT="${EG_RUN%% *}"
EG_VPATH=""
case "$EG_RUN" in *' '*) EG_VPATH="${EG_RUN#* }" ;; esac

case "$EG_VERDICT" in
  bound-open|bound-closed)
    PLAN="$EG_VPATH"
    ;;
  *)
    # UNBOUND: today's line, untouched, and reached by exactly the same code that
    # reached it before this wave. `fallback` and `none` both mean "no binding", and
    # AC-3's promise is that such a session behaves EXACTLY as it did — so the promise is
    # kept by running the old path rather than by a new one that agrees with it.
    PLAN=$(active_plan "$PROJECT_DIR") || PLAN=""
    ;;
esac

# THE ANNOUNCEMENT, ONCE PER INVOCATION AND NOT ONCE PER SITE (AC-3, AC-6). It is emitted
# where the resolution happens, not where each site consumes it, because the fact being
# reported is the resolution and there is only one of those. Both lines are reports on the
# hook's only channel — never a refusal, and never an exit.
case "$EG_VERDICT" in
  fallback)
    echo "evidence-gate: run resolved by newest-plan fallback (session unbound) — $PLAN" >&2
    ;;
  bound-closed)
    echo "evidence-gate: bound plan closed — $PLAN; this session has no open run" >&2
    ;;
esac

# ---------- AC-13: misplacement blocks; absence never does ----------
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
#
# No plan file was found in this project's plan directories. That used to be an
# unconditional `exit 0`, and it is this hook's fail-open — a structurally
# different one from the governing-skill hook's, which is why the two are fixed
# and tested independently. This one never tests `.bionic/` at all: every
# candidate directory is skipped by `[ -d "$d" ] || continue`, PLAN comes back
# empty, and the commit passes ungated.
#
# The guard was PROJECT_PLAN from the Step-6 C1/S2 repair until 2026-07-28,
# because PLAN then meant "no plan in ANY searched directory" and the first
# directory searched was the project-agnostic `~/.claude/plans/`: one unrelated
# `.md` there made PLAN non-empty and this whole block dead. Deleting that
# directory from the search set fixes the same hole at its root, so the guard is
# back on PLAN — which now means what C1/S2 needed it to mean.
#
# ABSENT is not an error and must never block. No plan anywhere is every commit
# in every project that does not use this lifecycle, plus the normal first-run
# state of one that does.
#
# MISPLACED is: a plan carrying the run-state marker exists inside the project
# but outside every directory this gate searches. The gate is then silently
# disabled — precisely the failure the AC exists to convert into a block.
#
# Scoping, deliberately narrow, because a false positive here walls off every
# commit in the project:
#   - `*.plan.md` only. The gate consumes plans. A misplaced file under the
#     flat `~/.claude/plans/<name>.md` convention is not covered — that whole
#     directory is already searched.
#   - The LEADING frontmatter must declare `canonical_sdlc_version`, the
#     run-state marker (never `governing-skill`, the artifact-author field —
#     see `.claude/rules/hook-authoring.md` — machine-local, gitignored,
#     authored in place; no script recreates it). Reading only the leading block is
#     what keeps a fenced example in a documentation page from counting.
#   - The whole docs root is "placed", not just plans/ and incidents/:
#     <docs-root>/spikes/ and <docs-root>/record/ hold real artifacts carrying
#     this frontmatter, and the governing-skill hook treats them as placed too.
#   - Bounded walk: `.git` and `node_modules` pruned, depth 5, filename match
#     first. It runs only when no plan was found at all, so a project in an
#     active canonical-sdlc run never pays for it.
#
# THE GUARD IS `[ -z "$PLAN" ]` AND NOTHING ELSE (S10a, critic C-1). It read
# `[ -z "$PLAN" ] || [ ! -f "$PLAN" ]` until this wave made the second half
# reachable. Before the wave `PLAN` came from `active_plan`, which reports only
# files `find -type f` had just produced, so a non-empty `PLAN` naming a missing
# file did not exist and the two conditions were one. A BINDING OUTLIVES THE FILE
# IT NAMES: `session_run` answers `bound-closed <p>` when the bound plan has been
# deleted, moved into another epic directory, or restored away, and that path is
# taken as `PLAN` above. It walked in here and turned this sweep — six hundred
# lines above the `bound-closed → exit 0` escape — into a live commit blocker for
# a session whose own plan is simply gone, naming an unrelated stray file and
# telling the operator to move it. The two conditions are different questions now
# and they get different answers: NO PLAN AT ALL is the sweep's question, and a
# bound plan that is not on disk is the arm below it.
if [ -z "$PLAN" ]; then
  MISPLACED_PLAN=""
  if [ -d "$PROJECT_DIR" ]; then
    while IFS= read -r -d '' f; do
      case "$f" in "$DOCS_ROOT"/*) continue ;; esac
      if head -c 8192 "$f" \
         | awk '{ sub(/\r$/, ""); gsub(/\r/, "\n"); print }' \
         | awk 'NR == 1 && $0 == "---" { inside = 1; next }
                inside && $0 == "---" { exit }
                inside { print }' \
         | grep -qE '^[[:space:]]*canonical_sdlc_version[[:space:]]*:'; then
        MISPLACED_PLAN="$f"
        break
      fi
    done < <(find "$PROJECT_DIR" -maxdepth 5 \
               \( -name .git -o -name node_modules \) -prune -o \
               -type f -name '*.plan.md' -print0 2>/dev/null)
  fi

  if [ -n "$MISPLACED_PLAN" ]; then
    echo "BLOCKED: a canonical-sdlc plan is misplaced — this commit would pass ungated." >&2
    echo "Misplaced plan: $MISPLACED_PLAN" >&2
    echo "Docs root:      $DOCS_ROOT" >&2
    echo "The evidence gate searches only the plan directories for this project, so a plan" >&2
    echo "outside them silently disables it — no step evidence is checked at all." >&2
    echo "Fix: move it under $DOCS_ROOT/plans/ (or $DOCS_ROOT/incidents/ for an incident run)." >&2
    exit 2
  fi

  # ABSENCE: nothing misplaced and nothing to validate. Never blocks — this is
  # every commit in every project that does not use the lifecycle, plus the
  # normal first-run state of one that does. This exit lived in a second `if`
  # on its own until 2026-07-28, when the sweep's guard was the narrower
  # PROJECT_PLAN and the two conditions could differ; on one guard they cannot,
  # so the sweep and its fall-through are one block.
  exit 0
fi

# THE PLAN IS NAMED BUT NOT ON DISK (S10a, critic C-1). Reachable only through a
# binding — see the guard above for why. This is engaged-with-no-run, the same
# state `bound-closed` reaches at the enforcement gate below, so the answer is the
# same: allow, and say why. It cannot be the misplacement sweep's answer, because
# nothing is misplaced; and it cannot be the hygiene refusals' answer either,
# because every one of them reads a file that is not there.
#
# THE RECOVERY IS NAMED, because it is not guessable and it is not what it was.
# Re-invoking the skill USED to rewrite a `bound-closed` marker by the count rule;
# since S10a a binding survives re-engagement open or closed (review C-1), so the
# only route back is the operator naming a live run. `poker bind` refuses a plan
# that is not an open run of this root, which is exactly what makes it the right
# instrument here: it cannot re-create this state.
if [ ! -f "$PLAN" ]; then
  echo "evidence-gate: the plan this session is bound to is not on disk — $PLAN" >&2
  echo "  Nothing is validated for this commit. Name a live run for this session with:" >&2
  echo "    bash $(dirname "$0")/session-poker.sh bind <plan>" >&2
  exit 0
fi

# Normalize a plan file's line endings to plain \n on stdout. Strips a trailing
# \r from each record (CRLF: \r\n → \n) and converts any remaining lone \r
# (classic-Mac CR-only: \r without \n) into a real newline. Every parse below is
# line-anchored, so it must see real newlines.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
#
# `tr -d '\r'` (the prior normalization) merely DELETED every \r. On a CRLF file
# that happened to work, but on a CR-only file it removed every line break,
# collapsing the whole plan to ONE line beginning with the frontmatter `---`.
# The line-anchored `/^## SDLC State/` presence check then never matched, the
# hook exited 0 as "not a canonical-sdlc plan", and every commit passed ungated.
# awk splits on \n by default, so a CR-only file arrives as a single record that
# gsub re-splits into real lines; LF and CRLF files are unaffected.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
normalize_newlines() {
  awk '{ sub(/\r$/, ""); gsub(/\r/, "\n"); print }' "$1"
}

# The newest plan has no ## SDLC State section → not a canonical-sdlc run.
# Fence-aware (matches the SECTION extraction below): a `## SDLC State` heading
# that appears ONLY inside a ``` fenced example is documentation, not state, so
# the file passes through as non-canonical rather than being parsed and then
# false-blocked on the empty extraction. Line endings normalized (CRLF and
# CR-only) to real newlines first — see normalize_newlines.
if [ -z "$(normalize_newlines "$PLAN" | awk '
  /^[[:space:]]*```/ { fence = !fence; next }
  fence { next }
  /^## SDLC State/ { print "yes"; exit }
')" ]; then
  exit 0
fi

# Extract YAML frontmatter (between first two `---` lines at column 0)
# if the plan has any. Used to read the version marker, the triple, and the
# discriminator flags the checks below key off.
#
# CRLF/CR-only plans would otherwise defeat the exact-match `$0=="---"`
# comparison ("---\r" != "---"), so line endings are normalized to \n before
# every awk pass (normalize_newlines) — meaning every downstream parse
# (frontmatter values, SECTION lines, CURRENT, evidence blocks) sees plain
# \n text regardless of the file's original line-ending style.
FRONTMATTER=$(normalize_newlines "$PLAN" | awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f')

frontmatter_get() {
  echo "$FRONTMATTER" \
    | grep -E "^[[:space:]]*$1[[:space:]]*:" \
    | head -1 \
    | sed -E "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//" \
    | sed -E 's/[[:space:]]+$//' \
    | sed -E "s/^['\"]//;s/['\"]\$//"
}

DEPLOY_TARGET=$(frontmatter_get deploy_target)
SDLC_VERSION=$(frontmatter_get canonical_sdlc_version)
USE_WORKTREE=$(frontmatter_get use_worktree)
SCALE=$(frontmatter_get scale)
INTENT=$(frontmatter_get intent)
RIGOR=$(frontmatter_get rigor)
MULTI_AGENT=$(frontmatter_get multi_agent)

# ONE supported version. Anything else — an older number, a typo, an empty
# value, garbage — blocks. Symmetric with the governing-skill hook. There is
# no version dispatch anywhere below this line, so there is also no path that
# reaches `exit 0` by matching no arm.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
SUPPORTED_SDLC_VERSION=14

if [ "$SDLC_VERSION" != "$SUPPORTED_SDLC_VERSION" ]; then
  echo "BLOCKED: canonical-sdlc evidence-gate: plan declares canonical_sdlc_version: '$SDLC_VERSION'." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: set 'canonical_sdlc_version: ${SUPPORTED_SDLC_VERSION}' — the only supported version." >&2
  exit 2
fi

# Whole-value placeholder test: trim leading/trailing whitespace, lowercase,
# then require whole-value EQUALITY against the known token set. A token that
# merely appears as a substring of a longer value ("resolved TODOs",
# "*.example placeholders", "status pending → done") is legal evidence.
# "in progress" and its whitespace-free "inprogress" are both listed so
# either spelling of the value matches. Defined here (ahead of the Step-line
# checks) so the task-ledger validator, which runs before them, can reuse it.
is_placeholder_value() {
  local v
  v=$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]')
  case "$v" in
    todo|pending|"in progress"|inprogress|xxx|tbd|placeholder) return 0 ;;
    *) return 1 ;;
  esac
}

# Audit dir follows the PLAN's own project, not necessarily the invoking one:
# findings live with the project that owns the artifact, and every worktree of one
# repo shares one audit file. `project_root` always answers (falling back to the
# path's own directory), so there is no fallback arm left to get wrong — the old
# copy's second argument existed only because its git call could fail silently.
# [INSTRUMENT]
audit_root() {
  local r
  r=$(project_root "$(dirname "$PLAN")")
  # project_root ALWAYS answers: with no `.bionic` ancestor it falls back to the git
  # toplevel, then to the path itself. Those fallbacks name a directory, not a
  # project, so the finding would land keyed on a tree that owns nothing. When the
  # answer is not a real project, the invoking project (itself library-resolved) is
  # the honest owner — which is the fail-open the walk-up this replaced also had.
  if [ -d "$r/.bionic" ]; then printf '%s\n' "$r"; else printf '%s\n' "$PROJECT_DIR"; fi
}

# Incident 0001: the audit stream must live where a consuming project cannot
# commit it, regardless of that project's .gitignore. $HOME-rooted, per-project,
# durable — the same $HOME/.claude/ audit path the archived epic-10 poker used
# (that work is recoverable at tag archive/epic-10-never-die).
# Slug = <basename>-<cksum of the absolute path>: readable, deterministic, and
# collision-resistant across same-named projects under different parents.
# cksum and basename are POSIX — no new dependency.
# Byte-identical to the copies in farm-out-reminder.sh,
# canonical-sdlc-governing-skill.sh and context-spend.sh — divergence would give
# one project two audit files. Deliberate per-hook duplication (no shared lib).
# [INSTRUMENT]
audit_path() {  # $1=project root → absolute audit-file path; rc 1 if no $HOME
  [ -n "${HOME:-}" ] || return 1
  local base sum
  base=$(basename "$1" | sed 's/[^A-Za-z0-9._-]/-/g')
  sum=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  printf '%s/.claude/logs/%s-%s/sdlc-audit.md' "$HOME" "$base" "$sum"
}

# Log-only finding channel (D14): append one line to the durable audit file
# AND echo to stderr, then return 0 — floor/ledger/merge-target findings never
# block this wave. Twin of the governing-skill hook's helper (hook name differs:
# `evidence-gate`). mkdir + append are fail-open. audit_root() still selects
# WHICH project the finding belongs to; incident 0001 moved WHERE the file for
# that project lives — $HOME/.claude/logs/<project-slug>/, outside every
# consuming project tree, never .bionic/memory/ again. An unwritable
# destination drops the line; there is deliberately no fallback branch.
# [INSTRUMENT]
log_finding() {  # $1=check-id  $2=detail
  local f
  if f=$(audit_path "$(audit_root)"); then
    local line="- $(date -u +%Y-%m-%dT%H:%M:%SZ) evidence-gate $1: $2 ($PLAN)"
    mkdir -p "$(dirname "$f")" 2>/dev/null && printf '%s\n' "$line" >> "$f" 2>/dev/null
  fi
  echo "canonical-sdlc [$1]: $2" >&2
  return 0
}

# Normalize a task row's rigor cell to its effective rigor lane. Whole-value
# `case` equality against the rigor enum (bash-3.2 safe — no associative arrays,
# same idiom as is_r7_key below): a cell already naming a lane passes through; a
# non-empty cell outside the enum is INVALID; an empty cell inherits the
# plan-level RIGOR when that itself names a lane, else defaults to `tested` (the
# floor — see plan Assumption A3). Defined ahead of validate_task_ledger (which
# runs at the `current: T<n>` branch, before is_r7_key is defined below) so the
# validator can call it — same placement rationale as is_placeholder_value.
effective_row_rigor() {  # $1 = row's rigor cell
  local cell
  cell=$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  case "$cell" in
    tested|peer-reviewed|audited) echo "$cell"; return ;;
    "") : ;;
    *) echo "INVALID"; return ;;
  esac
  case "$RIGOR" in
    tested|peer-reviewed|audited) echo "$RIGOR" ;;
    *) echo "tested" ;;
  esac
}

# Total order over the rigor enum, for the per-row FLOOR check (slice 4/8).
# tested < peer-reviewed < audited. An empty/unknown value maps to 0 (the tested
# floor) so an unset frontmatter rigor never manufactures a phantom downgrade.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
# Mirrors the governing-skill hook's ord map at its rigor check (kept in sync by
# hand, not imported — the two hooks share no source). bash-3.2 safe whole-value
# `case`, same idiom as effective_row_rigor above.
rigor_ord() {  # $1 = a rigor lane name (or empty)
  case "$1" in
    peer-reviewed) echo 1 ;;
    audited)       echo 2 ;;
    *)             echo 0 ;;  # tested, empty, or unknown → the floor
  esac
}

# Is the independent auditor's verdict a WALL on this run? (B-10 / R-11.)
# SKILL.md's rigor table: `tested` = "Both independent assurance roles.
# Self-review only." — no auditor is ever sent, so demanding an auditor
# CONFIRMED on every matrix row (and an `auditor:` pointer in the Step-5 block)
# refused a `tested` run for the absence of a verdict its own rigor says nobody
# was commissioned to write. B-10's repro: a bugfix · tested · task run refused
# at current: 9 on "matrix row 'AC-1' auditor verdict is 'empty'".
#
# At `tested` the matrix's auditor column is NOT READ — any value, empty
# included, passes — and the Step-5 pointer is not demanded. At
# `peer-reviewed` (which adds the auditor) and `audited` both walls stand
# unchanged.
#
# FAIL-CLOSED on an unknown or missing value: a plan that does not say what
# rigor it runs at has not bought the relaxation, and a typo must not become a
# bypass (same rationale as walk_mode's off-enum arm). This is deliberately
# ASYMMETRIC with effective_row_rigor, which resolves an unknown frontmatter
# rigor DOWN to the tested floor: there, the fallback picks a lane for a row
# that must run in one; here, the fallback decides whether a wall stands.
#
# Scope: the MATRIX wall and the Step-5 pointer only. The task-ledger lanes
# (apply_rigor_lanes) were already rigor-keyed and read EFFECTIVE row rigor, so
# a row whose own cell raises it above the frontmatter keeps its auditor/critic
# demand there — the matrix carries no per-row rigor cell to raise.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
matrix_auditor_required() {
  case "$RIGOR" in
    tested) return 1 ;;
    *)      return 0 ;;  # peer-reviewed, audited, and anything unrecognized
  esac
}

# Proof-shape test (D-slice 4/2): an evidence value counts as "proof-shaped"
# — a command invocation + result counts, not prose — iff it contains BOTH
# at least one digit AND at least one command token. A command token is any
# of: a backtick; a literal '/' anywhere (a path, e.g. 'hooks/foo.sh'); or a
# whole-word match against the fixed runner list (bash-3.2 safe — no
# associative arrays, `grep -Ew` for the bounded whole-word match so `test`
# matches in "bash test.sh 12/12" but `testing` never triggers on a `test`
# substring). Returns 0 (proof-shaped) / 1 (not) — never blocks itself; the
# caller (apply_rigor_lanes) decides what a failure means.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
is_proof_shaped() {  # $1 = evidence value
  local v="$1"
  echo "$v" | grep -qE '[0-9]' || return 1
  if echo "$v" | grep -q '`'; then
    return 0
  fi
  if echo "$v" | grep -qF '/'; then
    return 0
  fi
  if echo "$v" | grep -Ewq 'bash|sh|npm|pnpm|yarn|make|pytest|go|cargo|git|test'; then
    return 0
  fi
  return 1
}

# Rigor-keyed evidence lanes (D-slice 4/2, TASK SCALE ONLY). Applies to
# the addressed row (any status) and to every OTHER row with status `done`
# that has a non-empty, non-placeholder evidence line — the caller only
# invokes this once those upstream 4/1 presence/placeholder checks (and, for
# the addressed row, the rigor-enum check) have already passed. BLOCKS
# (exit 2) on any lane breach:
#   - effective rigor peer-reviewed or audited: evidence must be proof-shaped.
#   - status done AND effective rigor >= peer-reviewed: evidence must name
#     an `auditor` verdict.
#   - status done AND effective rigor audited: evidence must ALSO name a
#     `critic` verdict.
# The `tested` floor carries none of these demands — 4/1's presence +
# placeholder checks are its entire contract (plan Assumption A4: the literal
# substrings are sufficient tokens, no pointer-format sub-schema).
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
apply_rigor_lanes() {  # $1=id $2=status $3=effective-rigor $4=evidence-value
  local id="$1" status="$2" eff="$3" ev="$4"
  case "$eff" in
    peer-reviewed|audited)
      if ! is_proof_shaped "$ev"; then
        echo "BLOCKED: canonical-sdlc task ${id} evidence must show a command + counts, not prose, at rigor '${eff}' ('${ev}')." >&2
        echo "Plan: $PLAN" >&2
        echo "Fix: replace the '- ${id}:' evidence with the actual command invocation and result counts (e.g. 'bash test.sh 12/12 green')." >&2
        exit 2
      fi
      ;;
  esac
  if [ "$status" = "done" ]; then
    case "$eff" in
      peer-reviewed|audited)
        if ! echo "$ev" | grep -Ewq 'auditor'; then
          echo "BLOCKED: canonical-sdlc task ${id} is done at rigor '${eff}' but its evidence has no 'auditor' verdict ('${ev}')." >&2
          echo "Plan: $PLAN" >&2
          echo "Fix: record the independent auditor's verdict in the '- ${id}:' evidence line before marking done." >&2
          exit 2
        fi
        ;;
    esac
    if [ "$eff" = "audited" ]; then
      if ! echo "$ev" | grep -Ewq 'critic'; then
        echo "BLOCKED: canonical-sdlc task ${id} is done at rigor 'audited' but its evidence has no 'critic' verdict ('${ev}')." >&2
        echo "Plan: $PLAN" >&2
        echo "Fix: record the adversarial critic's verdict in the '- ${id}:' evidence line before marking done." >&2
        exit 2
      fi
    fi
  fi
}

# Per-row rigor FLOOR check (slice 4/8, A15 — user-ratified, momentous). The
# per-row `rigor` cell is a FLOOR unified with the run-rigor floor model: a
# cell RAISING a row above the frontmatter rigor is always allowed (the cell
# drives the heavier lane, 4/4), but a cell LOWERING it below the frontmatter
# rigor is a DOWNGRADE — a recorded decision, never silent. A downgrade BLOCKS
# (exit 2) UNLESS the row's `- T<n>:` evidence line carries a whole-word `waiver`
# marker (Waiver Protocol — same `grep -Ewq` word-boundary idiom as the lane
# token checks), in which case the row proceeds at its (lower) cell lane.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
#
# Called on exactly the rows the rigor lanes cover — the addressed unit (any
# status) and non-addressed `done` rows with real evidence — AFTER their
# presence/placeholder checks and the per-row INVALID guard, and BEFORE
# apply_rigor_lanes. Ordering rationale: a missing/placeholder evidence block
# (addressed unit, or audited non-addressed via ledger_shape_fail) and the
# INVALID-cell block both fire upstream of this, so they still win — a row with
# no evidence line never reaches here (there is no line to hold a waiver, and its
# absence already blocks or logs). `eff` is the RESOLVED effective rigor: an
# empty cell resolves to the frontmatter rigor, so rigor_ord(eff) ==
# rigor_ord(RIGOR) and no phantom downgrade fires — only an explicit lower cell
# trips it. A cell EQUAL to the frontmatter is not a downgrade (strict `<`).
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
enforce_rigor_floor() {  # $1=id  $2=effective-rigor  $3=evidence-value
  local id="$1" eff="$2" ev="$3"
  [ "$(rigor_ord "$eff")" -lt "$(rigor_ord "$RIGOR")" ] || return 0
  if echo "$ev" | grep -Ewq 'waiver'; then
    return 0  # recorded downgrade — proceed at the lower cell lane
  fi
  echo "BLOCKED: canonical-sdlc task ${id} lowers rigor from '${RIGOR}' to '${eff}', below the plan's floor." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: raise the cell to at least '${RIGOR}', or record a downgrade: add 'waiver: <user> <date> <reason>' to the '- ${id}:' evidence line (Waiver Protocol)." >&2
  exit 2
}

# Router for the previously-log-only NON-addressed-row ledger-shape checks
# (D-slice 4/3, task scale). On a frontmatter `rigor: audited` plan these
# promote to BLOCKING (exit 2); at any other rigor they stay log-only findings
# (D14, unchanged). The detail string is authored once by the caller and used
# verbatim in whichever channel fires. The addressed-unit floor (4/1) and the
# rigor lanes (4/2) are NOT routed through here — they already block
# unconditionally where they should.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
ledger_shape_fail() {  # $1 = detail
  if [ "$RIGOR" = audited ]; then
    echo "BLOCKED: canonical-sdlc task-ledger: $1" >&2
    echo "Plan: $PLAN" >&2
    echo "Fix: resolve the ledger-shape defect above before committing (audited rigor makes the ledger-shape checks blocking; a non-audited plan would log this as a finding instead)." >&2
    exit 2
  fi
  log_finding task-ledger "$1"
}

# Task-scale ledger validation (D12). Reads the `## Tasks` registration
# table (fence-aware, the matrix_section idiom) and the per-task `- T<n>:`
# evidence lines in the ## SDLC State section (SECTION, already newline-normalized).
#
# Two lanes (slice 4/1), plus rigor-keyed lanes on top (slice 4/2):
#   - THE ADDRESSED UNIT — the `T<n>` named by `current: T<n>` — is BLOCKING at
#     the tested floor: its row must exist in `## Tasks`, carry a non-placeholder
#     `- T<n>:` evidence line, and have a rigor cell that resolves (its cell
#     names a lane, or is empty; a non-empty cell outside the enum is INVALID).
#     Any breach emits a 3-line block message and exit 2. Once past the floor,
#     apply_rigor_lanes (4/2) applies the proof-shape/auditor/critic lanes keyed
#     to its effective rigor.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
#
#   - EVERY OTHER row stays LOG-ONLY (D14, check-id `task-ledger`) for status
#     and presence/placeholder: status outside {pending,active,done,dropped},
#     or an active/done task with no `- T<n>:` line or a placeholder/empty
#     value, each append one finding and never block. Missing `## Tasks`
#     entirely is also log-only here. A `done` row that DOES have a non-empty,
#     non-placeholder evidence line resolves its effective rigor and is
#     additionally passed through apply_rigor_lanes (4/2) — BLOCKING, since a
#     done claim at peer-reviewed+ rigor without real evidence is a false-done
#     claim, not a bookkeeping gap. A malformed (off-enum) rigor cell on ANY row
#     — addressed or not, at ANY status (done, active, pending, dropped) — is
#     caught earlier by the per-row INVALID guard (4/7), which resolves the cell
#     and BLOCKS unconditionally at any frontmatter rigor before this
#     status-based branching; see that guard for the rationale.
# [INSTRUMENT]
validate_task_ledger() {
  local tasks rows line id status rigor_cell ev eff addressed_found=0
  tasks=$(normalize_newlines "$PLAN" | awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    /^## Tasks/ { f=1; next }
    /^## / { f=0 }
    f')
  if [ -z "$tasks" ]; then
    ledger_shape_fail "task-scale plan has no '## Tasks' registration section"
    return 0
  fi
  rows=$(echo "$tasks" | grep -E '^[[:space:]]*\|[[:space:]]*T[0-9]+')
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=$(echo "$line"         | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
    status=$(echo "$line"     | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6}')
    rigor_cell=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')
    # status enum — routed through ledger_shape_fail (4/3): blocking on audited
    # plans, log-only otherwise (was unconditionally log-only in D12).
    case "$status" in
      pending|active|done|dropped) : ;;
      *) ledger_shape_fail "task ${id} has invalid status '${status:-empty}' (want pending|active|done|dropped)" ;;
    esac
    # Per-row INVALID rigor-cell guard (4/7): resolve this row's rigor cell and
    # block if it is off-enum. A malformed rigor cell makes the row's lane
    # indeterminate — a hard STRUCTURAL error, the exact sibling of the
    # status-enum check above (both are whole-value enum equality on a single
    # cell, validated per-row REGARDLESS of the row's status). So it blocks
    # UNIFORMLY: on ANY row (addressed or not; done, active, pending, dropped)
    # and at ANY frontmatter rigor — NOT routed through the audited-only
    # ledger_shape_fail. Placed here, before the evidence extraction and the
    # addressed-vs-other branching, so this ONE guard covers every row —
    # consolidating the former per-branch INVALID checks (4/1 addressed unit,
    # 4/6 non-addressed done) that left non-addressed active/pending rows
    # unchecked. `eff` is reused by both branches below (never INVALID past
    # here). Order vs the status-enum check: status first, then rigor — a row
    # with BOTH defects may block on either; this order is pinned for determinism.
    # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
    eff=$(effective_row_rigor "$rigor_cell")
    if [ "$eff" = "INVALID" ]; then
      echo "BLOCKED: canonical-sdlc task ${id} has an invalid rigor '${rigor_cell}' (want tested|peer-reviewed|audited)." >&2
      echo "Plan: $PLAN" >&2
      echo "Fix: set the '${id}' row's rigor cell to one of tested, peer-reviewed, audited before committing." >&2
      exit 2
    fi
    # Evidence line for this task in ## SDLC State (anchored so T2 never matches T20).
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
    ev=$(echo "$SECTION" | grep -E "^[[:space:]]*-?[[:space:]]*${id}[[:space:]]*:" | head -1 \
         | sed -E "s/^[[:space:]]*-?[[:space:]]*${id}[[:space:]]*:[[:space:]]*//" | sed -E 's/[[:space:]]+$//')
    if [ "$id" = "$CURRENT" ]; then
      # THE ADDRESSED UNIT: the tested floor is BLOCKING (slice 4/1).
      addressed_found=1
      if [ -z "$ev" ]; then
        echo "BLOCKED: canonical-sdlc task ${id} has no '- ${id}:' evidence line in '## SDLC State'." >&2
        echo "Plan: $PLAN" >&2
        echo "Fix: record the evidence artifact on a '- ${id}:' line before committing." >&2
        exit 2
      fi
      if is_placeholder_value "$ev"; then
        echo "BLOCKED: canonical-sdlc task ${id} evidence line is a placeholder ('${ev}')." >&2
        echo "Plan: $PLAN" >&2
        echo "Fix: replace the '- ${id}:' placeholder with the actual evidence artifact before committing." >&2
        exit 2
      fi
      # 4/8: FLOOR check — a cell lowering this row below the frontmatter rigor
      # blocks unless the evidence line records a waiver. Runs after the
      # presence/placeholder blocks above (so those win) and before the lanes.
      enforce_rigor_floor "$id" "$eff" "$ev"
      # 4/2: rigor-keyed proof-shape/auditor/critic lanes on top of the tested
      # floor above. `eff` was resolved and INVALID-guarded at the per-row guard
      # (4/7); it names a valid lane here. Applies regardless of this row's own
      # status — the addressed unit is always in scope.
      # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
      apply_rigor_lanes "$id" "$status" "$eff" "$ev"
    else
      # Every OTHER row's presence/placeholder checks route through
      # ledger_shape_fail (4/3): blocking on audited plans, log-only otherwise.
      case "$status" in
        active|done)
          if [ -z "$ev" ]; then
            ledger_shape_fail "task ${id} is ${status} but has no evidence on a '- ${id}:' line in ## SDLC State"
          elif is_placeholder_value "$ev"; then
            ledger_shape_fail "task ${id} is ${status} but its evidence is a placeholder ('${ev}')"
          elif [ "$status" = "done" ]; then
            # 4/2: a done row WITH real evidence is in scope for the
            # rigor-keyed lanes (BLOCKING) — a false-done claim at
            # peer-reviewed+ rigor, not a bookkeeping gap. A done row with
            # NO evidence line stays log-only above (4/3 territory). `eff` was
            # resolved and INVALID-guarded at the per-row guard (4/7 — was a
            # done-only guard under 4/6; now uniform across statuses), so it
            # names a valid lane here.
            # 4/8: FLOOR check first — a done row whose cell lowers it below the
            # frontmatter rigor blocks unless its evidence line records a waiver.
            enforce_rigor_floor "$id" "$eff" "$ev"
            apply_rigor_lanes "$id" "$status" "$eff" "$ev"
          fi
          ;;
      esac
    fi
  done <<< "$rows"
  # The addressed unit (current: T<n>) must have a row in ## Tasks (BLOCKING).
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
  if [ "$addressed_found" -eq 0 ]; then
    echo "BLOCKED: canonical-sdlc task ${CURRENT} has no row in the '## Tasks' registration table." >&2
    echo "Plan: $PLAN" >&2
    echo "Fix: add a '| ${CURRENT} | <intent> | <rigor> | <description> | <status> |' row to '## Tasks' before committing." >&2
    exit 2
  fi
  return 0
}

# Extract the ## SDLC State section (from its header up to the next ##
# header or EOF). Line endings normalized here too (normalize_newlines), for
# the same reason as FRONTMATTER above. Fence-aware (same idiom as matrix_section): lines inside
# ``` fenced code blocks are skipped, so a plan documenting the D12 task-scale
# schema in a fenced example — a `## SDLC State` heading with `current: T<n>` —
# does not shadow the REAL section (which would mis-parse `current:` and false-
# block). Fence state is tracked across the whole file so section detection
# stays fence-aware.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
SECTION=$(normalize_newlines "$PLAN" | awk '
  /^[[:space:]]*```/ { fence = !fence; next }
  fence { next }
  /^## SDLC State/ { flag=1; next }
  /^## / { flag=0 }
  flag')

if [ -z "$SECTION" ]; then
  echo "BLOCKED: canonical-sdlc plan file has an empty '## SDLC State' section." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: populate the section with 'current: N' and per-step evidence lines." >&2
  exit 2
fi

# The `## Verification Matrix` section body (newline-normalized, like SECTION at
# the top of the hook — a separate awk pass over the whole plan). Lines inside
# ``` fenced code blocks are dropped so a jq/shell pipeline written in
# leading-pipe continuation style is never mistaken for a table row; every
# downstream matrix parse (rows, stack-health, false-green, AC blocks) reads
# this body, so scoping the fence-skip here covers all of them. Fence state
# is tracked across the whole file so section detection stays fence-aware.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
matrix_section() {
  normalize_newlines "$PLAN" | awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    /^## Verification Matrix/ { f=1; next }
    /^## / { f=0 }
    f'
}

# The indented evidence block under "<AC-id>:" within MATRIX (up to the next
# non-indented line). index()==1 anchors at line start without regex-escaping
# the AC id, so AC-1 never matches the AC-11 block.
#
# A markdown list leader before the header is tolerated: `- AC-1:` reads exactly
# like `AC-1:`. Without this, a list-shaped block extracted as EMPTY and every
# consumer below went silent at once — the provenance arm saw no citation, the
# per-tier key loop saw no keys and blocked a conformant plan, and both
# `waiver:` exemptions (per-tier and post-Verify CONFIRMED) lost their token.
# One extractor, four behaviors, so the leader was a whole-contract bypass.
# The strip runs on a COPY (`hdr`), which keeps two invariants: the terminator
# below still tests the RAW line, so a following list item still ends the
# previous block; and the index test still runs against a line that begins with
# the AC id, so AC-1 still does not match `- AC-11:`. Accepted: the three
# CommonMark bullet markers plus at least one space, flush left — `-AC-1:` is
# not a list item, and an INDENTED header is refused on purpose because the
# terminator could never end a block it introduced.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
matrix_block() {
  echo "$MATRIX" | awk -v ac="$1:" '
    { hdr = $0; sub(/^[-*+][[:space:]]+/, "", hdr) }
    index(hdr, ac)==1 {f=1; next}
    /^[^[:space:]]/ {f=0}
    f'
}

# ================================================== THE TWO STEP-4 ARMS (epic-22 K2, K2.5)
#
# Defined HERE, directly before `CURRENT` is parsed — earlier than a numbered-step-only
# wall would need to be. The reason is the task-scale branch a few lines below: epic-22
# K2.5 calls these same two arms from inside the `current: T<n>` branch, which used to
# `exit 0` before ever reaching them (they used to live between the matrix extractors and
# the pointer-step exit, reachable only by the numbered-step path). Moving the DEFINITIONS
# up costs nothing — `matrix_section`/`matrix_block` need only `$PLAN`, which is set long
# before this point — and it lets one pair of checks serve both scales instead of a second
# copy of either. The numbered-step CALL still runs in its original place, right before the
# pointer-step exit below; this is only the definitions moving.
#
# THE STEP NUMBER IS READ AS A NUMBER, ONCE. `CURRENT` reaches here as `4`, `8b`, `10` or a
# task-scale `T<n>`. Numbered steps are read digit-first, the leftmost run before any letter
# (`4`, `8b` → `8`); a value whose digits cannot be read leaves both arms unmeasured rather
# than refusing on a question they cannot ask — the fail direction every start-side
# ambiguity in this tree takes. Task-scale is the one case that is NOT "read the digits":
# `T1`'s leading `T` would strip to empty and read as unmeasured, which is exactly the gap
# K2.5 closes — a task-scale plan is always mid-execution, never mid-authoring, so ANY
# `current: T<n>` (n >= 1) reads as past Step 3 and both arms bind on it the same way they
# do from `current: 4` onward.
k2_step_num() {
  case "$CURRENT" in
    T[0-9]*) printf '4'; return ;;
  esac
  local n="${CURRENT%%[!0-9]*}"
  case "$n" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$n" ;; esac
}

# ---------- the approval arm (AC-K2.4, AC-K2.5, design decision 2) ----------
#
# WHAT `approved` BINDS. Step 3 ends at one approval checkpoint, and until this arm
# existed the user's word left no trace: a run could be building at Step 4 with nobody
# able to say whether the plan had ever been ratified, and the only backstop was the
# Patrol's below-Step-4 fill refusal, which asks a different question. Decision 2 settled
# the recording — on the user's LITERAL `approved` the orchestrator writes
#
#     approved-by: <user> <ISO-UTC> "<verbatim reply>"
#
# into `## SDLC State` — and this is the wall that makes its absence cost something.
# Silence, a question, or a partial reply is never transcribed as approval, so PRESENCE
# is the whole check: nothing here grades the quote, and nothing here can tell a
# transcription from an invention. What it can tell is that nobody wrote one down.
#
# INERT BELOW STEP 4, by construction and not by accident. Steps 0-3 are where the plan
# is authored, and the approval is asked for at the END of Step 3 — a wall there would
# refuse the very commit that writes the plan the user is about to approve.
#
# DURABLE FROM 4 ONWARD, the same shape the matrix prefix check has: deleting the line at
# Step 6 loses the same fact it would have lost at Step 4. AT TASK SCALE (K2.5) there is no
# "below Step 4" — `k2_step_num` reads every `current: T<n>` as past Step 3, so this arm is
# durable from a task-scale plan's first commit onward.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
validate_approved_by() {
  local step approved
  step=$(k2_step_num)
  [ -n "$step" ] || return 0
  [ "$step" -ge 4 ] || return 0

  approved=$(echo "$SECTION" | grep -E '^[[:space:]]*approved-by[[:space:]]*:' | head -1 \
    | sed -E 's/^[[:space:]]*approved-by[[:space:]]*:[[:space:]]*//' | sed -E 's/[[:space:]]+$//')
  [ -n "$approved" ] && return 0

  echo "BLOCKED: canonical-sdlc step ${CURRENT} — '## SDLC State' carries no 'approved-by:' line; the Step-3 approval is what admits Step 4." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: on the user's literal 'approved', record 'approved-by: <user> <ISO-UTC> \"<verbatim reply>\"' under '## SDLC State' — never on silence, a question, or a partial reply." >&2
  exit 2
}

# ---------- the fails-when arm (AC-K2.3, AC-K2.5) ----------
#
# AN EVAL WITH NO NAMEABLE FAILURE IS NOT AN EVAL. A matrix row that cannot say what
# planted defect it must go red on is a row that will be green whatever the code does,
# and the gate cannot tell the two apart at discharge time — which is the whole reason
# the column is authored at Step 2, in the spec's `## Eval design`, and merely RENDERED
# into the plan's matrix at Step 3. By Step 4 every AC block has one, or a step was
# skipped; so this arm is the receipt for that authoring order rather than a new demand.
# AT TASK SCALE (K2.5) the same receipt is owed from a plan's first `current: T<n>`
# commit — a task-scale plan carrying a `## Verification Matrix` is held to the identical
# standard as a numbered-step plan at `current: 4`+.
#
# IT JUDGES BLOCKS, NOT ROWS. A matrix row with no AC block underneath it is not a
# fails-when finding: there is no block to lack the key, and the per-tier evidence loop
# at the Verify gate is what owns that gap. Nor does a plan with no `## Verification
# Matrix` at all become one — a Step-4 plan may not have written the section yet, and
# demanding it here would be the Verify gate's demand moved four steps early.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
validate_fails_when() {
  local step rows line ac block_txt fw
  step=$(k2_step_num)
  [ -n "$step" ] || return 0
  [ "$step" -ge 4 ] || return 0

  MATRIX=$(matrix_section)
  [ -n "$MATRIX" ] || return 0
  rows=$(echo "$MATRIX" | grep -E '^[[:space:]]*\|')
  [ -n "$rows" ] || return 0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "$line" | grep -qE '^[[:space:]]*\|[-|:[:space:]]*$' && continue
    ac=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
    [ "$ac" = "AC" ] && continue
    [ -n "$ac" ] || continue
    block_txt=$(matrix_block "$ac")
    [ -n "$block_txt" ] || continue
    fw=$(echo "$block_txt" | grep -E '^[[:space:]]*fails-when[[:space:]]*:' | head -1 \
      | sed -E 's/^[[:space:]]*fails-when[[:space:]]*:[[:space:]]*//' | sed -E 's/[[:space:]]+$//')
    [ -n "$fw" ] && continue
    echo "BLOCKED: canonical-sdlc step ${CURRENT} — matrix row '${ac}' names no 'fails-when:'; an eval with no nameable failure is not an eval." >&2
    echo "Plan: $PLAN" >&2
    echo "Fix: add 'fails-when: <the planted defect this eval must go red on>' to the '${ac}:' block — it is authored in the spec's '## Eval design' and rendered here." >&2
    exit 2
  done <<< "$rows"
  return 0
}

# The `## Slices` section body, same fence-aware/heading-bounded shape as
# `matrix_section` above — a separate awk pass over the whole plan, stopping at the
# next `## ` heading. Moved up beside the other Step-4 arms (epic-22 K2.5) for the
# same reason: the task-scale branch below needs it defined before it is called.
slices_section() {
  normalize_newlines "$PLAN" | awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    /^## Slices/ { f=1; next }
    /^## / { f=0 }
    f'
}

# ---------- the prototype no-row arm (AC-K4.2, epic-22 K4 + K2.5) ----------
#
# A PROTOTYPE NEVER DISCHARGES A MATRIX ROW (design decision D7). Its output is a
# design ruling written back to the spec, not a shipped behavior — nothing about a
# throwaway is provable by an eval, so a `kind: prototype` slice that also owns a
# Verification Matrix AC block is a category error the gate can catch structurally:
# the `## Slices` table names which slices are prototypes, and each AC block's own
# `slice:` field names which slice discharges it. Reads both tables the same way
# `validate_fails_when` reads the matrix — rows first, then the block underneath
# each row — so an AC id absent from the row table (and therefore from the matrix
# entirely) cannot be judged here either.
#
# INERT BELOW STEP 4 (numbered) OR BELOW `current: T<n>` (task-scale, epic-22 K2.5),
# same reasoning as the two arms above: the Slices table and the Verification Matrix
# are both Step-3 artifacts, not necessarily complete before then, and a task-scale
# plan typically carries neither — `slices_section` returns empty and this is a no-op.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
validate_prototype_no_matrix_row() {
  local step slices proto_nums line num kind rows ac block_txt ac_slice n
  step=$(k2_step_num)
  [ -n "$step" ] || return 0
  [ "$step" -ge 4 ] || return 0

  slices=$(slices_section | grep -E '^[[:space:]]*\|')
  [ -n "$slices" ] || return 0

  proto_nums=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "$line" | grep -qE '^[[:space:]]*\|[-|:[:space:]]*$' && continue
    num=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
    [ "$num" = "#" ] && continue
    kind=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')
    [ "$kind" = "prototype" ] || continue
    [ -n "$num" ] || continue
    proto_nums="$proto_nums $num"
  done <<< "$slices"
  [ -n "$proto_nums" ] || return 0

  MATRIX=$(matrix_section)
  [ -n "$MATRIX" ] || return 0
  rows=$(echo "$MATRIX" | grep -E '^[[:space:]]*\|')
  [ -n "$rows" ] || return 0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "$line" | grep -qE '^[[:space:]]*\|[-|:[:space:]]*$' && continue
    ac=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
    [ "$ac" = "AC" ] && continue
    [ -n "$ac" ] || continue
    block_txt=$(matrix_block "$ac")
    [ -n "$block_txt" ] || continue
    ac_slice=$(echo "$block_txt" | grep -E '^[[:space:]]*slice[[:space:]]*:' | head -1 \
      | sed -E 's/^[[:space:]]*slice[[:space:]]*:[[:space:]]*//' | sed -E 's/[[:space:]]+$//')
    [ -n "$ac_slice" ] || continue
    for n in $proto_nums; do
      [ "$ac_slice" = "$n" ] || continue
      echo "BLOCKED: canonical-sdlc step ${CURRENT} — matrix row '${ac}' names 'slice: ${ac_slice}', a 'kind: prototype' row in '## Slices'; a prototype ships nothing and never discharges a matrix row." >&2
      echo "Plan: $PLAN" >&2
      echo "Fix: remove the '${ac}:' block, or repoint its 'slice:' to the build slice that cites the prototype's ruling — the prototype's own output is a design decision written to the spec, never a matrix discharge." >&2
      exit 2
    done
  done <<< "$rows"
  return 0
}

# Parse current step. Accepts integers (1-13) and the 8b adversarial
# critic step.
CURRENT=$(echo "$SECTION" \
          | grep -E '^[[:space:]]*current[[:space:]]*:' \
          | head -1 \
          | sed -E 's/^[[:space:]]*current[[:space:]]*:[[:space:]]*//' \
          | tr -d '[:space:]')

# Task-scale plans address a ledger TASK, not a numbered step:
# `current: T<n>` with evidence on `- T<n>:` lines (no `Step N:` line). Validate
# the ledger (log-only, D12/D14), then — epic-22 K2.5 — run the SAME three Step-4
# arms a numbered-step plan runs below: a task-scale plan is always mid-execution,
# never mid-authoring, so `current: T<n>` (any n >= 1) reads as past Step 3 and the
# approved-by / fails-when / prototype-no-row walls bind on it exactly as they do
# from `current: 4` onward (`k2_step_num`, above, recognises the T-format
# directly). A `current: T<n>` on a non-task plan is NOT accepted here; it falls
# through to the numeric check below and blocks (T-format is scale: task only).
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
if echo "$CURRENT" | grep -qE '^T[0-9]+$' && [ "$SCALE" = "task" ]; then
  validate_task_ledger
  validate_approved_by
  validate_fails_when
  validate_prototype_no_matrix_row
  exit 0
fi

if [ -z "$CURRENT" ] || ! echo "$CURRENT" | grep -qE '^[0-9]+[ab]?$'; then
  echo "BLOCKED: canonical-sdlc plan file's '## SDLC State' section is missing a valid 'current: N' line." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: add a line like 'current: 5' (or 'current: 8b') before committing." >&2
  exit 2
fi

# ---------- THE RUN PREDICATE (AC-7, AC-8): no open run, nothing to gate ----------
#
# The plan is now known to be well-formed — it carries an unfenced `## SDLC State`
# and a `current:` this gate recognises. Whether there is a RUN is a different
# question, and it is the one every always-on hook asks before doing its own work:
# `active_run` is true while `current:` is below 9, or 9 with no `delivered:` Step-9
# line, and the plan carries no `abandoned:` frontmatter line.
#
# IT SITS HERE AND NOT EARLIER, and the order is the whole point. Everything above
# is the gate's judgment about the PLAN — a misplaced plan, a malformed `current:`,
# a task ledger — and those refusals are owed whether or not a wave is live: a plan
# that lies is a defect in every state. Everything below is enforcement against a
# STEP, which is owed only while the run is open. Move this line up and a project
# whose plan is merely malformed goes ungated; move it down and a shipped wave keeps
# refusing commits forever.
#
# THE VERDICT IS THE SESSION'S, taken at the top with the plan it names
# (wave-session-bound-run, AC-1/AC-3/AC-6): a bound session enforces against its OWN open
# run and against nothing else, and `bound-closed` — its plan delivered, abandoned or gone
# — takes this same exit, the engaged-with-no-run branch, rather than resolving a second
# time and landing on somebody else's wave. The unbound arm still asks `active_run` here,
# in this position, exactly as it did before the wave: that is AC-3's "behaves exactly as
# today", kept by running the old predicate rather than by trusting a new one to agree.
case "$EG_VERDICT" in
  bound-open)   : ;;
  bound-closed) exit 0 ;;
  *)            active_run "$PROJECT_DIR" >/dev/null || exit 0 ;;
esac

# Find the evidence line for the current step: a "Step N:" line, with or
# without a leading list marker.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
LINE=$(echo "$SECTION" \
       | grep -E "^[[:space:]]*-?[[:space:]]*Step[[:space:]]+${CURRENT}[[:space:]]*:" \
       | head -1)

if [ -z "$LINE" ]; then
  echo "BLOCKED: canonical-sdlc plan file has no 'Step ${CURRENT}:' line in '## SDLC State'." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: add the evidence artifact for step ${CURRENT} before committing." >&2
  exit 2
fi

RAW_VALUE=$(echo "$LINE" | sed -E "s/^[[:space:]]*-?[[:space:]]*Step[[:space:]]+${CURRENT}[[:space:]]*:[[:space:]]*//")

# Multi-line form: when the Step line has no inline content, evidence lives on
# indented continuation lines below. Collect them so the rest of the hook treats
# `Step N:\n  field: value\n  ...` as non-empty evidence.
extract_continuation() {
  local section="$1" step="$2"
  local sline
  sline=$(echo "$section" | grep -nE "^[[:space:]]*-?[[:space:]]*Step[[:space:]]+${step}[[:space:]]*:" | head -1 | cut -d: -f1)
  [ -z "$sline" ] && return
  echo "$section" | awk -v start="$sline" '
    NR > start {
      if ($0 ~ /^[[:space:]]*-?[[:space:]]*Step[[:space:]]+[0-9]+[ab]?[[:space:]]*:/) exit
      if ($0 ~ /^[^[:space:]]/) exit
      if ($0 ~ /^[[:space:]]*$/) next
      print $0
    }
  '
}

CONTINUATION=$(extract_continuation "$SECTION" "$CURRENT")

# Combined block used for empty/placeholder/shape checks.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
BLOCK=$RAW_VALUE
if [ -n "$CONTINUATION" ]; then
  BLOCK="${BLOCK}
${CONTINUATION}"
fi
BLOCK_STRIPPED=$(echo "$BLOCK" | tr -d '[:space:]')

if [ -z "$BLOCK_STRIPPED" ]; then
  echo "BLOCKED: canonical-sdlc step ${CURRENT} evidence line is empty in '## SDLC State'." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: record the evidence artifact (commit SHA, path, link) for step ${CURRENT} before committing." >&2
  exit 2
fi

# R7 intent-scoped Step-5 keys (D14 log-only — see validate_intent_evidence
# below). A whole-value match against this exact key name exempts the line from
# the universal placeholder ban; the R7 contract is enforced instead by
# validate_intent_evidence, which logs a finding but never blocks.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
is_r7_key() {
  case "$1" in
    behavior-preservation|compat-matrix|revert-plan|baseline|target|re-measure) return 0 ;;
    *) return 1 ;;
  esac
}

# Placeholder detection. Each line of the block is checked as a whole value:
# the text after the first ':' on a "key: value" continuation line, or the
# whole line when it has no colon (the single-line "Step N: <value>" case,
# which arrives here as RAW_VALUE). ${_bline#*:} yields the after-colon text
# on colon lines and the unchanged line otherwise.
while IFS= read -r _bline; do
  _bkey=$(printf '%s' "$_bline" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*:.*$//')
  if is_r7_key "$_bkey"; then
    continue
  fi
  if is_placeholder_value "${_bline#*:}"; then
    echo "BLOCKED: canonical-sdlc step ${CURRENT} evidence line is a placeholder (\"${BLOCK}\")." >&2
    echo "Plan: $PLAN" >&2
    echo "Fix: replace with the actual evidence artifact before committing." >&2
    exit 2
  fi
done <<< "$BLOCK"

# ---------- K5 / AC-K5.2: Step-1 'requirements:' pointer (durable, current: 2+) ----------
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
#
# K5 fixes three artifacts to three steps (design ledger K5; ADR-001): Step 1 authors
# the wave's `*.requirements.md`, and the Step-1 evidence line is where that artifact's
# path is recorded — once, at Step 1, and never revisited. This arm reads THAT line (not
# the current step's own line) at every commit from current: 2 onward, so a plan cannot
# progress past Step 1 without a resolving pointer and cannot lose it later — the same
# durable-prefix shape validate_walk_artifact uses for the Step-5 walk narration (A5).
# Inert at current: 1 — Step 1 is still being written, and POINTER_STEPS below is what
# governs Step 1's own commit.
#
# SCOPE: rigor:audited + multi_agent:true + scale wave|epic — the same guard
# validate_dispatch_ledger uses (D7) to keep wave-lane machinery that predates a new
# requirement out of the way of fixtures that are not about it. This suite's shared FM
# (rigor: tested) and frontmatter() (no multi_agent: line, so MULTI_AGENT reads empty)
# are both guaranteed no-ops under this guard by the same construction the D7 comment
# documents; only a fixture that opts in — this wave's own plan among them (rigor:
# audited, multi_agent: true) — exercises it. Judgment call recorded because AC-K5.2's
# text names no such guard; the alternative (firing on every wave/epic plan regardless of
# rigor) blocked 170/316 of this suite's pre-existing cases on first RED and is not what
# "touch only your own span" can mean here.
step1_evidence_block() {
  local line raw cont
  line=$(echo "$SECTION" | grep -E '^[[:space:]]*-?[[:space:]]*Step[[:space:]]+1[[:space:]]*:' | head -1)
  [ -n "$line" ] || return 0
  raw=$(echo "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*Step[[:space:]]+1[[:space:]]*:[[:space:]]*//')
  cont=$(extract_continuation "$SECTION" "1")
  printf '%s\n%s\n' "$raw" "$cont"
}

# Resolution mirrors resolve_walk_path: absolute stands, a `specs/` leader is
# docs-root-relative (the form K5's layout names — requirements live beside the spec
# under specs/epic-NN-<slug>/), anything else is project-relative.
resolve_requirements_path() {  # $1 = raw requirements: value
  case "$1" in
    /*)      printf '%s\n' "$1" ;;
    specs/*) printf '%s/%s\n' "$DOCS_ROOT" "$1" ;;
    *)       printf '%s/%s\n' "$PROJECT_DIR" "$1" ;;
  esac
}

validate_requirements_pointer() {
  local current_num b1 raw abs
  case "$SCALE" in wave|epic) : ;; *) return 0 ;; esac
  [ "$RIGOR" = "audited" ] || return 0
  [ "$MULTI_AGENT" = "true" ] || return 0
  current_num=$(echo "$CURRENT" | sed -E 's/[ab]$//')
  [ "$current_num" -ge 2 ] 2>/dev/null || return 0

  b1=$(step1_evidence_block)
  raw=$(echo "$b1" | grep -E '^[[:space:]]*requirements[[:space:]]*:' | head -1 \
        | sed -E 's/^[[:space:]]*requirements[[:space:]]*:[[:space:]]*//' \
        | sed -E 's/;.*$//' | sed -E 's/[[:space:]]+$//')
  if [ -z "$raw" ]; then
    echo "BLOCKED: canonical-sdlc step ${CURRENT} — the Step 1 evidence has no 'requirements:' field." >&2
    echo "Plan: $PLAN" >&2
    echo "Fix: add 'requirements: specs/<epic>/<wave>.requirements.md' to the Step 1 line, naming the Step-1 artifact (K5)." >&2
    exit 2
  fi

  if echo "$raw" | grep -qE '(^|/)\.\.(/|$)'; then
    echo "BLOCKED: canonical-sdlc step ${CURRENT} — Step 1 'requirements: ${raw}' climbs out with a '..' component." >&2
    echo "Plan: $PLAN" >&2
    echo "Fix: name the requirements file relative to the docs root, e.g. 'requirements: specs/<epic>/<wave>.requirements.md'." >&2
    exit 2
  fi
  abs=$(resolve_requirements_path "$raw")
  if [ ! -f "$abs" ]; then
    echo "BLOCKED: canonical-sdlc step ${CURRENT} — Step 1 'requirements: ${raw}' does not resolve to a real file (resolved to ${abs})." >&2
    echo "Plan: $PLAN" >&2
    echo "Fix: write the requirements document at that path (K5 Step-1 artifact) before committing at step ${CURRENT}." >&2
    exit 2
  fi
  return 0
}

validate_requirements_pointer

# A pointer step records a link/path (not shaped fields); having passed the
# presence + placeholder checks above, it needs no shape check, so allow the
# commit. Step 4 is the exception: when use_worktree=true it carries worktree
# fields and must fall through to the shape check below.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
POINTER_STEPS="1 2 3 4"  # Step 6 must reach dispatch for the matrix prefix check

# WHERE THE POINTER-STEP EXIT WENT (epic-22 K2). The loop that used to sit here now
# runs a few hundred lines below, immediately after the two arms this wave added — and
# the move is the whole reason those arms are reachable at all. Steps 1-4 take that
# `exit 0`, so ANY wall written below it is dead at exactly the step it was written for:
# `current: 4` is a pointer step. Everything between here and the new position is
# function definitions and nothing else, so no other behaviour moved with it.

# Extract a value for a key from the BLOCK ("key: value" lines or
# "key: value" appearing on the Step line directly). Returns empty if
# not found.
block_get() {
  local key="$1"
  echo "$BLOCK" \
    | grep -E "^[[:space:]]*${key}[[:space:]]*:" \
    | head -1 \
    | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//" \
    | sed -E 's/[[:space:]]+$//'
}

block_has() {
  echo "$BLOCK" | grep -qE "^[[:space:]]*$1[[:space:]]*:"
}

block_has_na() {
  block_has "n/a"
}

# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
shape_block() {
  local missing=()
  for f in "$@"; do
    if ! block_has "$f"; then
      missing+=("$f")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "BLOCKED: canonical-sdlc step ${CURRENT} evidence missing required field(s): ${missing[*]}" >&2
    echo "Plan: $PLAN" >&2
    echo "Required for step ${CURRENT}: $*" >&2
    echo "Fix: rewrite the Step ${CURRENT} block as multi-line YAML-style fields. See canonical-sdlc/SKILL.md \"Evidence (two tiers)\" → verification shape table." >&2
    exit 2
  fi
}

# ---------- shared per-step validators ----------

# Compose the "canonical-sdlc step <N>" message prefix.
step_prefix() {
  echo "canonical-sdlc step $1"
}

# Tests modality: cmd/pass/total/output present, pass and total integers,
# pass==total. Used by the Step-5 verify gate.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
validate_tests_block() {
  local step="$1" pass total prefix
  shape_block cmd pass total output
  pass=$(block_get pass)
  total=$(block_get total)
  prefix=$(step_prefix "$step")
  if ! echo "$pass" | grep -qE '^[0-9]+$' || ! echo "$total" | grep -qE '^[0-9]+$'; then
    echo "BLOCKED: ${prefix} 'pass:' and 'total:' must be integers (got pass='${pass}', total='${total}')." >&2
    echo "Plan: $PLAN" >&2
    exit 2
  fi
  if [ "$pass" -ne "$total" ]; then
    echo "BLOCKED: ${prefix} evidence has pass=${pass} but total=${total}; the suite is not fully green." >&2
    echo "Plan: $PLAN" >&2
    echo "Fix: do not commit step ${step} until pass equals total." >&2
    exit 2
  fi
}

# Document step: adr OR rca OR n/a.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
validate_document_step() {
  local step="$1" prefix
  if ! block_has adr && ! block_has rca && ! block_has_na; then
    prefix=$(step_prefix "$step")
    echo "BLOCKED: ${prefix} evidence requires 'adr: <path>', 'rca: <path>' (incident-response mode), or 'n/a: <reason>'." >&2
    echo "Plan: $PLAN" >&2
    exit 2
  fi
}

# Integrate & close: merge/worktree-removed always; then the cleanup triple,
# OR an explicit `cleanup: n/a` marker (cleanup_on_finish=false).
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
validate_integrate_step() {
  local cleanup_val
  shape_block merge worktree-removed
  cleanup_val=$(block_get cleanup)
  case "$cleanup_val" in
    n/a|n/a:*)
      : # cleanup_on_finish=false / already-cleaned case (reason optional)
      ;;
    *)
      shape_block cleanup tmp-wiped tasks-completed
      ;;
  esac
}

# Does frontmatter name a LIVE surface this run operates? The default answer
# is no. `deploy_target` is n/a by default and is never inferred from deploy
# signals — a target exists only when the user names one — so an absent line,
# `none`, and `n/a` (with or without a trailing reason) all read as "no live
# surface". Case-insensitive, matching every other value comparison in this
# hook.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
deploy_target_named() {
  case "$(printf '%s' "$DEPLOY_TARGET" | tr '[:upper:]' '[:lower:]')" in
    ""|none|n/a|n/a:*) return 1 ;;
    *)                 return 0 ;;
  esac
}

# Close-out step (v14 contract, ratified 2026-08-19):
#
#   `delivered:` ALWAYS — the terminal state of the work. Step 9's default
#   endpoint is a PR open and ready for a human to review, or commits landed
#   locally and ready to push; everything past that boundary is the human's
#   process, not the run's to claim.
#
#   `deployed:` / `verified:` / `monitored:` owed EXACTLY when a deploy_target
#   is named — the run that operates its own live surface (bionic's own
#   dogfood is the example).
#
# Supersedes v13, where the trio was owed whenever any target existed and
# `n/a:` discharged the step at `deploy_target: none`. That rule encoded
# wave==release, which is the exception and not the rule, and it let a run
# with no live surface close without ever naming what it delivered.
#
# An UNOWED trio is tolerated, not refused: a run that deployed something
# without having declared a target and says so is recording more than it owes,
# and refusing that commit would punish honesty. The wall is on the absent
# claim, never on the extra one.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
validate_ship_step() {
  local step="$1" prefix f
  local missing=()
  shape_block delivered
  deploy_target_named || return 0
  for f in deployed verified monitored; do
    block_has "$f" || missing+=("$f")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  prefix=$(step_prefix "$step")
  echo "BLOCKED: ${prefix} frontmatter names deploy_target=${DEPLOY_TARGET}, so the close-out owes the deploy trio; missing: ${missing[*]}" >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: add 'deployed:', 'verified:', and 'monitored:' to the Step ${step} block — or, if this run operates no live surface, set 'deploy_target: n/a' in frontmatter (the trio is owed exactly when a target is named)." >&2
  exit 2
}

# ---------- pre-registered Verification Matrix ----------
# The Verify gate discharges a Verification Matrix stored in a top-level
# `## Verification Matrix` section of the plan (separate from ## SDLC State).
# validate_matrix parses that section — a per-session stack-health line, a
# tier table (one row per AC), and one indented per-AC evidence block per
# non-waived row — and fires at current: 5 (via the Step-5 validator) and as a
# prefix check for current: 6..9 (via the dispatcher).
#
# Mid-discharge commits: at current: 5, rows with status
# pending/blocked skip the per-tier key check, and the Step-5 `auditor:`
# pointer is required only when no such row remains. The full contract —
# per-tier keys, plus (at peer-reviewed/audited rigor) CONFIRMED on every
# non-waived row — bites on the 5→6 advance via the 6..9 prefix check. At
# `tested` rigor the auditor column is not a wall at all: see
# matrix_auditor_required. The status cell is enum-checked
# (pending|blocked|discharged|waived) since the relaxation makes it
# load-bearing.
#
# Close-out criteria: a T0 row whose AC block carries `slice: 9` keeps that
# same relaxation ALL THE WAY to current: 9 — both the per-tier keys and the
# CONFIRMED wall — because its evidence is a Step-9 artifact that does not
# exist yet. It is two exemptions, not one: the key loop and the CONFIRMED
# arm are separate branches, and a row exempted from only the first still
# meets the second at current: 6. At current: 9 the tag stops exempting
# anything. See the tag's own note inside validate_matrix.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]

# Per-tier required evidence keys — MIRROR of the canonical table in
# skills/canonical-sdlc/SKILL.md Step 5 ("Per-tier required evidence keys").
# Change THAT table first; this function follows it. (R27)
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
keys_for_tier() {
  case "$1" in
    T0|T1) echo "tier-run readback" ;;
    T2)    echo "tier-run readback fixture-fidelity" ;;
    T3)    echo "tier-run fresh cold-client contact readback" ;;
    T4)    echo "user-confirmed" ;;
  esac
}

# THE THREE STEP-4 ARMS (epic-22 K2, K4, K2.5): `matrix_section`, `matrix_block`,
# `slices_section`, `k2_step_num`, `validate_approved_by`, `validate_fails_when` and
# `validate_prototype_no_matrix_row` are now all defined just before `CURRENT` is
# parsed, above — moved there so the task-scale `current: T<n>` branch can call them
# too, instead of `exit 0`ing before ever reaching them. This is the numbered-step
# call: it still runs in the same place it always has, right before the pointer-step
# exit below.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
validate_approved_by
validate_fails_when
validate_prototype_no_matrix_row

# THE POINTER-STEP EXIT, relocated from above (epic-22 K2). A pointer step records a
# link or a path rather than shaped fields; having passed the presence and placeholder
# checks, and now the two arms above, it needs no shape check. Step 4 is the exception:
# with use_worktree=true it carries worktree fields and falls through to the shape check.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
for _ps in $POINTER_STEPS; do
  [ "$CURRENT" = "$_ps" ] || continue
  if [ "$_ps" = "4" ] && [ "$USE_WORKTREE" = "true" ]; then
    break  # fall through to the Step-4 worktree shape check below
  fi
  exit 0
done

# The `user-confirmed:` value out of an AC block (empty when absent).
user_confirmed_value() {
  echo "$1" | grep -E '^[[:space:]]*user-confirmed[[:space:]]*:' | head -1 \
    | sed -E 's/^[[:space:]]*user-confirmed[[:space:]]*:[[:space:]]*//' \
    | sed -E 's/[[:space:]]+$//'
}

# Is an AC block's `user-confirmed:` in the attributed form
# `<user> <YYYY-MM-DD> <what>`? This is what lets a T4 row discharge without a
# waiver below, so it is the one place the shape is checked rather than merely
# recorded — unlike `waiver:` and `rigor-override:`, whose presence is the whole
# test because a human wrote them by definition.
#
# What the form buys: a record naming WHO confirmed and WHEN. What it cannot
# buy, and is not sold as buying: whether the named human actually said it. A
# fabricated `chris 2026-08-19 ...` passes here. The check refuses the shape an
# agent's own claim naturally takes — "confirmed after the re-render",
# "2026-08-18 the wall renders" — which is the failure mode that was actually
# observed, not a defense against a determined forger.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
user_confirmed_form_ok() {
  echo "$(user_confirmed_value "$1")" \
    | grep -qE '^[A-Za-z][A-Za-z0-9._-]*[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[^[:space:]]'
}

# The plan is read off disk when the CALL starts (PLAN is resolved at :245
# before any of the command runs). So a single Bash call that edits the plan
# and THEN commits is judged against the pre-edit plan: the fix the agent just
# wrote is invisible to every arm below, and the refusal reads as though it had
# never been made. The observed reflex on that refusal is to re-run the same
# combined call, which fails identically forever. When the refused command's
# text names the plan, say so. Matched against the absolute path and against
# the path relative to the project root — the two spellings an agent writes.
# A commit MESSAGE that merely quotes the path also matches; the line is
# advice appended to an already-refused call, so a false positive costs a
# sentence and a false negative costs the loop this exists to break.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
plan_write_note() {
  local rel="$PLAN"
  [ -n "$PLAN" ] || return 0
  case "$PLAN" in "$PROJECT_DIR"/*) rel="${PLAN#"$PROJECT_DIR"/}" ;; esac
  case "$COMMAND" in
    *"$PLAN"*|*"$rel"*)
      echo "Note: this command also writes the plan — run the edit first, then commit in a separate call." ;;
  esac
}

# 3-line BLOCKED/Plan/Fix emit for the matrix arm (mirrors the pattern
# every other validator uses), plus the edit-then-commit note when the refused
# command also writes the plan. $1 = message tail, $2 = fix line.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
block_matrix() {
  echo "BLOCKED: canonical-sdlc step ${CURRENT} — $1" >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: $2" >&2
  plan_write_note >&2
  exit 2
}

# Placeholder-token test on a single field value. The matrix section lives
# outside ## SDLC State, so the upstream ban does not cover it; this reuses
# the same whole-value equality test (is_placeholder_value, defined above).
matrix_is_placeholder() {
  is_placeholder_value "$1"
}

validate_matrix() {
  local sh rows line ncols ac tier status ev aud block_txt key val val_lc prov_val prov_val_lc slice_val slice9 row_is_waived

  # Set while any row is still pending/blocked at current: 5. The
  # Step-5 validator reads it to keep the `auditor:` pointer optional
  # mid-walk (the auditor is the exit gate — it has not run yet).
  UNDISCHARGED=0
  MATRIX=$(matrix_section)
  if [ -z "$MATRIX" ]; then
    block_matrix "the Verify gate requires a '## Verification Matrix' section." \
      "add the '## Verification Matrix' section: a stack-health line, the AC tier table, and one per-AC evidence block. See canonical-sdlc/SKILL.md Step 5."
  fi

  # stack-health: non-empty proof, or `n/a: <reason>` with a reason.
  if ! echo "$MATRIX" | grep -qE '^[[:space:]]*stack-health[[:space:]]*:'; then
    block_matrix "'## Verification Matrix' is missing the 'stack-health:' line." \
      "add 'stack-health: <before/after snapshot>' or 'stack-health: n/a: <reason>' above the table."
  fi
  sh=$(echo "$MATRIX" | grep -E '^[[:space:]]*stack-health[[:space:]]*:' | head -1 \
       | sed -E 's/^[[:space:]]*stack-health[[:space:]]*:[[:space:]]*//' | sed -E 's/[[:space:]]+$//')
  case "$sh" in
    ""|n/a|n/a:)
      block_matrix "'stack-health:' needs a non-empty snapshot, or 'n/a: <reason>' with a non-empty reason." \
        "paste the before/after snapshot showing no delta, or give the reason stack-health does not apply." ;;
  esac

  # false-green two-part rule: any `false-green:` entry must have a paired
  # `rewritten:` entry, or the gate blocks (Assumption 12a).
  # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
  if echo "$MATRIX" | grep -qE '^[[:space:]]*false-green[[:space:]]*:'; then
    if ! echo "$MATRIX" | grep -qE '^[[:space:]]*rewritten[[:space:]]*:'; then
      block_matrix "a 'false-green:' entry in the matrix has no paired 'rewritten:' entry." \
        "add 'rewritten: <commit/test ref>' for the false-green test — a logged-but-unfixed false green is a blocking defect."
    fi
  fi

  rows=$(echo "$MATRIX" | grep -E '^[[:space:]]*\|')
  if [ -z "$rows" ]; then
    block_matrix "'## Verification Matrix' has no tier table rows." \
      "add the '| AC | tier | status | evidence | auditor |' table with one row per AC."
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # separator row (only pipes/dashes/colons/spaces) → skip
    echo "$line" | grep -qE '^[[:space:]]*\|[-|:[:space:]]*$' && continue
    ncols=$(echo "$line" | awk -F'|' '{print NF}')
    ac=$(echo "$line"     | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
    tier=$(echo "$line"   | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')
    status=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')
    ev=$(echo "$line"     | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}')
    aud=$(echo "$line"    | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6}')
    # header row → skip
    [ "$ac" = "AC" ] && continue
    # malformed: a well-formed 5-cell row splits into exactly 7 fields on '|'.
    if [ "$ncols" -ne 7 ]; then
      block_matrix "matrix row for '${ac}' is malformed (wrong cell count — no literal '|' inside cells)." \
        "write the row as '| AC | tier | status | evidence | auditor |' with exactly five cells and no literal pipe inside any cell."
    fi
    # tier enum
    if ! echo "$tier" | grep -qE '^T[0-4]$'; then
      block_matrix "matrix row for '${ac}' has an invalid tier '${tier}' (want T0..T4)." \
        "set the tier cell to one of T0, T1, T2, T3, T4."
    fi
    # status enum — the status cell is load-bearing (pending/blocked
    # relax the Verify gate; waived relaxes everything), so a typo must
    # block, not silently read as discharged-like.
    # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
    case "$status" in
      pending|blocked|discharged|waived) : ;;
      *)
        block_matrix "matrix row '${ac}' has an invalid status '${status:-empty}' (want pending|blocked|discharged|waived)." \
          "set the status cell to one of: pending, blocked, discharged, waived." ;;
    esac
    block_txt=$(matrix_block "$ac")
    # Is this row WAIVED? A `waiver:` token in the evidence cell or a
    # `waiver:` line in the AC block — the loop's long-standing test, hoisted
    # into one flag (review-a C-2) so every per-row demand below reads the same
    # fact. Deliberately NOT the status cell alone: a row that says `waived`
    # while recording no waiver has not been through the Waiver Protocol, and
    # the per-tier key loop has always demanded its evidence anyway.
    # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
    row_is_waived=0
    if echo "$ev" | grep -qE 'waiver:' \
       || echo "$block_txt" | grep -qE '^[[:space:]]*waiver[[:space:]]*:'; then
      row_is_waived=1
    fi
    # provenance arm (epic-14 W1, AC-5): the literal value `provenance:
    # implementation` in an AC block is circular — it names the change as the
    # source of its own requirement, which is unfalsifiable by construction.
    # Whole-value match after whitespace-trimming; a citation that merely
    # CONTAINS the word ("implementation-first rewrite of spec §3") is a real
    # citation and passes. A missing `provenance:` line does not block (plan
    # assumption A4 — presence is a W+1 candidate, not this wave's). Fires for
    # every row regardless of tier/status, since the spec (AC-5) says "any AC
    # block" — unlike the tier-key checks below, it does not sit behind the
    # waived/undischarged branches. Compared case-insensitively, matching the
    # placeholder and live-tier n/a checks a few lines below in this same loop.
    # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
    prov_val=$(echo "$block_txt" | grep -E '^[[:space:]]*provenance[[:space:]]*:' | head -1 \
      | sed -E 's/^[[:space:]]*provenance[[:space:]]*:[[:space:]]*//' | sed -E 's/[[:space:]]+$//')
    prov_val_lc=$(echo "$prov_val" | tr '[:upper:]' '[:lower:]')
    if [ "$prov_val_lc" = "implementation" ]; then
      block_matrix "matrix row '${ac}' cites 'provenance: implementation' — the implementation cannot be the source of its own requirement." \
        "cite the real requirement source (user quote, spec section, ticket, report) for '${ac}', not the implementation itself."
    fi
    # `slice: 9` (B-2, 2026-08-30): a criterion whose only evidence is a Step-9
    # lifecycle artifact — the close-out report, continuation.md, the ADR the
    # close-out writes — cannot be discharged at Steps 5..8, because the thing
    # it would cite does not exist yet. Such a row had only dishonest homes: a
    # `waiver:` that records the criterion as let go, or a discharged row
    # citing an artifact nobody had written. The tag is an AC-block line parsed
    # exactly like `provenance:` above — never a sixth table cell, which the
    # 7-field row pin a few lines up would refuse on every row.
    #
    # It exempts the row from TWO SEPARATE ARMS while current < 9: the per-tier
    # key loop below, and the CONFIRMED/auditor wall further down. Exempting
    # only the first leaves the row blocking at current: 6 on an empty auditor
    # cell, which is the same wall wearing a different refusal.
    #
    # T0-ONLY. Every other tier names evidence that exists before Step 9 (a
    # suite run, a live surface, the user's own word), so `slice: 9` there is a
    # mis-tag rather than a deferral: it blocks at ANY step, naming the tier —
    # including current: 5, where a pending row is otherwise exempt from
    # everything and the mis-tag would sit unread until the 5→6 advance.
    # Only the exact value `9` means anything; `slice: 4` is an ordinary
    # annotation this hook does not read.
    # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
    slice_val=$(echo "$block_txt" | grep -E '^[[:space:]]*slice[[:space:]]*:' | head -1 \
      | sed -E 's/^[[:space:]]*slice[[:space:]]*:[[:space:]]*//' | sed -E 's/[[:space:]]+$//')
    slice9=0
    if [ "$slice_val" = "9" ]; then
      # A WAIVED row is exempt from the tier refusal (review-a C-2). The tag on
      # a non-T0 row is a mis-tag, but a waiver has already dissolved that
      # row's evidence contract — every other per-row demand in this loop
      # (per-tier keys, the CONFIRMED wall) yields to it, and refusing here
      # left a waived row with no way out but retiering a criterion nobody
      # intends to discharge. The unwaived mis-tag still blocks at every step.
      # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
      if [ "$tier" != "T0" ] && [ "$row_is_waived" = "0" ]; then
        block_matrix "matrix row '${ac}' is ${tier} and carries 'slice: 9' — only a T0 row defers its evidence to the close-out." \
          "a ${tier} row's evidence exists before Step 9 — discharge '${ac}' at its own tier, or retier the row to T0 if the criterion really is a close-out obligation."
      fi
      slice9=1
    fi
    # waived rows (evidence cell or the AC block carries a `waiver:` entry) are
    # exempt from the per-tier evidence requirement.
    if [ "$row_is_waived" = "1" ]; then
      :
    elif [ "$CURRENT" = "5" ] && { [ "$status" = "pending" ] || [ "$status" = "blocked" ]; }; then
      # A row still being discharged carries no evidence contract at
      # the Verify gate itself — its per-tier keys bite on the 5→6 advance
      # (the 6..9 prefix check), mirroring the CONFIRMED rule. This is what
      # gives a mid-walk corrective commit an honest home at current: 5.
      UNDISCHARGED=1
    elif [ "$slice9" = "1" ] && [ "$CURRENT" -lt 9 ] 2>/dev/null \
         && { [ "$status" = "pending" ] || [ "$status" = "blocked" ]; }; then
      # Close-out row before Step 9 — see the `slice: 9` note above. Sits
      # BELOW the current: 5 arm on purpose: at the Verify gate the existing
      # relaxation must still set UNDISCHARGED, which keeps the Step-5
      # `auditor:` pointer optional while any row is undischarged.
      # A non-numeric CURRENT makes `-lt` fail, so the exemption is
      # fail-closed on a malformed step.
      :
    else
      for key in $(keys_for_tier "$tier"); do
        if ! echo "$block_txt" | grep -qE "^[[:space:]]*${key}[[:space:]]*:"; then
          block_matrix "matrix row '${ac}' (${tier}) is missing evidence key '${key}' in its AC block." \
            "add '${key}: <evidence>' to the '${ac}:' block, or waive the row via the Waiver Protocol."
        fi
        val=$(echo "$block_txt" | grep -E "^[[:space:]]*${key}[[:space:]]*:" | head -1 \
              | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//" | sed -E 's/[[:space:]]+$//')
        if [ -z "$val" ]; then
          block_matrix "matrix row '${ac}' (${tier}) evidence key '${key}' is empty." \
            "record the evidence for '${key}' in the '${ac}:' block, or waive the row."
        fi
        if matrix_is_placeholder "$val"; then
          block_matrix "matrix row '${ac}' (${tier}) evidence key '${key}' is a placeholder (\"${val}\")." \
            "replace '${key}' with the real evidence before committing."
        fi
        # live-tier (T3/T4) fields cannot be self-written n/a — that is a
        # downgrade, which is a user decision via the Waiver Protocol.
        # Case-insensitive: 'N/A' is the same downgrade as 'n/a' (matches
        # matrix_is_placeholder's lowercasing). The tier CELL is not checked
        # here: retyping T3 to T2 is a downgrade this hook does not see.
        # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
        val_lc=$(echo "$val" | tr '[:upper:]' '[:lower:]')
        case "$tier" in
          T3|T4)
            case "$val_lc" in
              n/a|n/a:*)
                block_matrix "matrix row '${ac}' (${tier}) key '${key}' is a self-written 'n/a' on a live tier." \
                  "a live-tier field cannot be n/a — downgrade the row via the Waiver Protocol (record 'waiver: <user> <date> <reason>'), a user decision." ;;
            esac ;;
        esac
      done
    fi
    # Once past the Verify gate, every non-waived row must be CONFIRMED —
    # at peer-reviewed and audited rigor. At `tested` no auditor was ever
    # commissioned (SKILL.md's rigor table), so this whole arm stands down;
    # matrix_auditor_required is the predicate and carries the reasoning.
    #
    # T4 is the exception, and it is not a relaxation. T4's evidence IS the
    # user's own confirmation — an independent auditor sent at it can only
    # re-read what the user said, which is transcription, not independence. So
    # a legitimately user-confirmed row used to have exactly one way past this
    # arm: the Waiver Protocol, which recorded a waiver where nothing had been
    # waived (epic-17 W4 paid its AC-7 in that form, and the row reads forever
    # as if the criterion had been let go). A T4 row carrying a well-formed
    # `user-confirmed: <user> <date> <what>` now discharges on that value —
    # the same value keys_for_tier already demanded of it — and an
    # agent-shaped claim with no attributed human still meets the wall.
    #
    # WHAT THE EXEMPTION REPLACES IS THE WAIVER FORM, NOT THE AUDITOR (critic
    # C-1, W5). Those are two authorities and only the first substitution was
    # ratified. So the exemption is scoped to an auditor cell that is EMPTY —
    # nobody has ruled, which is the ordinary state of a T4 row — or CONFIRMED,
    # where the two authorities agree. A STANDING REFUTED or UNVERIFIABLE is a
    # positive finding on the record (this wave's own first audit pass produced
    # three), and a user's confirmation does not overturn one: the row meets
    # the wall, and the refusal names the FINDING rather than the attribution,
    # because the attribution is correct and sending the user to rewrite it
    # would point them at the one thing that is not broken.
    # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
    if [ "$CURRENT" -gt 5 ] 2>/dev/null && matrix_auditor_required; then
      if [ "$status" = "waived" ] || [ "$row_is_waived" = "1" ]; then
        :
      elif [ "$slice9" = "1" ] && [ "$CURRENT" -lt 9 ] 2>/dev/null \
           && { [ "$status" = "pending" ] || [ "$status" = "blocked" ]; }; then
        # The second of the `slice: 9` tag's two arms. An auditor cannot
        # CONFIRM a row whose evidence Step 9 has not produced; demanding it
        # here would re-impose the wall the key-loop exemption just lifted.
        :
      elif [ "$tier" = "T4" ] && user_confirmed_form_ok "$block_txt" \
           && { [ -z "$aud" ] || [ "$aud" = "CONFIRMED" ]; }; then
        :
      elif [ "$aud" != "CONFIRMED" ]; then
        if [ "$tier" = "T4" ]; then
          if user_confirmed_form_ok "$block_txt"; then
            block_matrix "matrix row '${ac}' (T4) carries a well-formed 'user-confirmed:', but the independent auditor's standing verdict on it is '${aud}', at step ${CURRENT}." \
              "a user's confirmation does not overturn an auditor's finding — it replaces the WAIVER a T4 row used to need, not the audit. Resolve the '${aud}' verdict (re-run the audit and record CONFIRMED, or clear the cell if the finding was withdrawn), or waive the row."
          fi
          block_matrix "matrix row '${ac}' (T4) auditor verdict is '${aud:-empty}', not CONFIRMED, and its 'user-confirmed:' names no attributed user, at step ${CURRENT}." \
            "record the user's own confirmation as 'user-confirmed: <user> <date> <what they confirmed>' in the '${ac}:' block — a T4 row discharges on that, no waiver needed. An unattributed or agent-written claim is not one."
        fi
        block_matrix "matrix row '${ac}' auditor verdict is '${aud:-empty}', not CONFIRMED, at step ${CURRENT}." \
          "the independent auditor must CONFIRM every non-waived row before advancing past the Verify gate, or the row must be waived."
      fi
    fi
  done <<< "$rows"
}

# ---------- walk-first artifact arm (epic-14 W1) ----------
# Verification opens with a walk: an agent narrates the real running surface
# without having read the acceptance criteria, and its narration lands in
# <docs-root>/record/ BEFORE any matrix row discharges. Existence is the wall;
# temporal order stays discipline, since no hook can see when the walk happened.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
#
# FAIL-CLOSED (plan assumption A1, user-ratified): frontmatter `walk: exempt`
# makes the arm inert; `walk: required` OR AN ABSENT KEY arms it. An exemption
# is a Step-0 ratification, never something inferred from an omission — so a
# plan that simply never mentions the key meets this arm at its next Step-5
# commit. A value outside the enum also arms it; validating that enum belongs to
# the governing-skill hook (it gates artifact writes), and treating an
# unrecognized value as "exempt" here would hand every typo a bypass.
walk_mode() {
  case "$(frontmatter_get walk)" in
    exempt) echo exempt ;;
    *)      echo required ;;
  esac
}

# The Step-5 evidence block, read at ANY current step. The module-level BLOCK
# holds the CURRENT step's evidence, so at current: 6..9 it is the Step-6..9
# block and cannot answer for the walk; this extractor re-reads Step 5 out of
# SECTION with the same line + continuation grammar the top of the hook uses.
# Empty when the plan carries no Step-5 line at all — which, post-Verify, is
# itself a missing walk artifact.
step5_evidence_block() {
  local line raw cont
  line=$(echo "$SECTION" | grep -E "^[[:space:]]*-?[[:space:]]*Step[[:space:]]+5[[:space:]]*:" | head -1)
  [ -n "$line" ] || return 0
  raw=$(echo "$line" | sed -E "s/^[[:space:]]*-?[[:space:]]*Step[[:space:]]+5[[:space:]]*:[[:space:]]*//")
  cont=$(extract_continuation "$SECTION" "5")
  printf '%s\n%s\n' "$raw" "$cont"
}

# Resolve a `walk-artifact:` value to an absolute path. Absolute passes through;
# a `record/...` value is docs-root-relative (the form the Step-5 contract
# names); anything else is project-relative, so the fully-spelled
# `.bionic/docs/record/<file>.md` a plan author is likely to paste also lands in
# the right place. Containment is checked by the caller — this only resolves.
resolve_walk_path() {  # $1 = raw walk-artifact value
  case "$1" in
    /*)       printf '%s\n' "$1" ;;
    record/*) printf '%s/%s\n' "$DOCS_ROOT" "$1" ;;
    *)        printf '%s/%s\n' "$PROJECT_DIR" "$1" ;;
  esac
}

# The arm itself. Fires at current: 5..9 (the Verify gate and, as a durable
# prefix condition — plan assumption A5 — every step after it, so the artifact
# cannot be deleted once Verify is behind you). Trigger: at least one matrix row
# with status `discharged`. Rows that are only pending/blocked leave it silent,
# which is what keeps a mid-discharge corrective commit legal. `waived` is NOT a
# trigger: the spec arms this on discharge, and a wave whose every row is waived
# has verified nothing to narrate.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
validate_walk_artifact() {
  local discharged b5 raw abs
  case "$CURRENT" in 5|6|7|8|9) : ;; *) return 0 ;; esac
  [ "$(walk_mode)" = required ] || return 0
  # Reuses the $MATRIX cache validate_matrix() fills. It runs immediately before
  # this arm at both call sites (validate_verify_step, dispatch's 6..9 case) and
  # hard-blocks on an empty matrix, so the cache is populated by the time we get
  # here. The `:-` fallback keeps that an optimization rather than a trap: a
  # third call site that forgot the ordering would re-read the section instead
  # of crashing under `set -u` or, worse, reading an empty matrix as "nothing
  # discharged" and letting the walk gate fall open.
  discharged=$(echo "${MATRIX:-$(matrix_section)}" | grep -E '^[[:space:]]*\|' \
    | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}' \
    | grep -cx 'discharged')
  [ "$discharged" -gt 0 ] || return 0

  # Truncated at the first ';' below: sibling extractors in this hook already
  # tolerate a Step-5 line with more fields packed after the value
  # (`walk-artifact: record/x.md; cmd: ...`); this one was the outlier,
  # greedy to end-of-line, and swallowed the packed remainder as part of the
  # "path" (plan assumption A17). The dedicated continuation-line shape has
  # no ';' in it, so the truncation is a no-op there.
  b5=$(step5_evidence_block)
  raw=$(echo "$b5" | grep -E '^[[:space:]]*walk-artifact[[:space:]]*:' | head -1 \
        | sed -E 's/^[[:space:]]*walk-artifact[[:space:]]*:[[:space:]]*//' \
        | sed -E 's/;.*$//' | sed -E 's/[[:space:]]+$//')
  if [ -z "$raw" ]; then
    block_matrix "the walk gate: matrix rows are discharged but the Step 5 evidence has no 'walk-artifact:' line." \
      "run the walk first and record 'walk-artifact: record/<file>.md' in the Step 5 block. Frontmatter 'walk: exempt' is the only way past this arm, and it is a Step-0 decision."
  fi

  # Containment. A `..` component is refused outright rather than normalized:
  # the artifact belongs in record/, and a path that climbs out of it is a
  # placement error whatever it lands on.
  if echo "$raw" | grep -qE '(^|/)\.\.(/|$)'; then
    block_matrix "the walk gate: walk-artifact '${raw}' climbs out of the record directory and so does not resolve under ${DOCS_ROOT}/record/." \
      "name the walk narration relative to the docs root, e.g. 'walk-artifact: record/<file>.md'."
  fi
  abs=$(resolve_walk_path "$raw")
  case "$abs" in
    "$DOCS_ROOT"/record/*) : ;;
    *)
      block_matrix "the walk gate: walk-artifact '${raw}' does not resolve under ${DOCS_ROOT}/record/ (resolved to ${abs})." \
        "move the walk narration into <docs-root>/record/ and name it there, e.g. 'walk-artifact: record/<file>.md'." ;;
  esac
  if [ ! -f "$abs" ]; then
    block_matrix "the walk gate: walk-artifact '${raw}' is named in the Step 5 evidence but no file exists at ${abs}." \
      "write the walk narration to that path before discharging any matrix row (and do not delete it afterwards — the arm re-checks at every later step)."
  elif [ ! -s "$abs" ]; then
    block_matrix "the walk gate: walk-artifact '${raw}' is named in the Step 5 evidence but the file is empty at ${abs}." \
      "write real narration into the walk artifact before discharging any matrix row — an empty file is not a walk."
  fi

  # The walk narrates a running surface; it never checklists acceptance
  # criteria. An AC identifier in the artifact is the tell that it was written
  # with the criteria in hand, which is exactly the power the walk is meant to
  # have. This grep is the whole enforcement.
  # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
  if grep -qE 'AC-[0-9]' "$abs" 2>/dev/null; then
    block_matrix "the walk gate: walk artifact ${abs} names acceptance criteria (matched 'AC-<n>')." \
      "rewrite the walk as narration of what was driven and what came back, with no AC identifiers — the walk is written without reading the criteria."
  fi
  return 0
}

# S3 (AC-4, AC-23; wave-01-verification-cannot-lie, D-S1b): environments —
# declared, covered, fog. Frontmatter `environments:` is one line naming the
# set this wave's Step-5 tests floor claims to run on, entries joined by
# " · ", each `<name> (covered...)` or `<name> (fog — cure: <text>)`. A plan
# that never mentions the key makes no environment claim at all: the arm
# no-ops. Most plans never declare it (this repo's own wave-01 plan is the
# exception, not the rule), so the no-op is recorded to the durable audit
# file only (log_finding_quiet, below) and never echoed to stderr — an
# ordinary commit stays exactly as silent as it is today. Declared, it
# requires the Step-5 evidence to carry an `environments-covered:` line
# naming every non-fog environment, and blocks a fog entry that names no
# cure — both are real refusals, spoken the normal BLOCKED way.
#
# AC-23: this arm reads only the DECLARATION and the Step-5
# `environments-covered:` line — never a derived suite set. It is
# independent of validate_tests_block, which is what actually requires the
# unconditional whole-suite floor run; nothing here substitutes for that,
# and nothing here is consulted by it.
#
# Fires at current: 5..9, the same durable-prefix span as
# validate_walk_artifact: the covered claim cannot quietly go stale once
# Verify is behind you.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
env_split_entries() {  # $1 = raw `environments:` value -> "name<TAB>descriptor" lines
  printf '%s\n' "$1" | awk '
    {
      n = split($0, parts, /[ \t]*·[ \t]*/)
      for (i = 1; i <= n; i++) {
        entry = parts[i]
        gsub(/^[ \t]+|[ \t]+$/, "", entry)
        if (entry == "") continue
        name = entry
        sub(/[ \t]*\(.*/, "", name)
        desc = entry
        sub(/^[^(]*\(/, "", desc)
        sub(/\)[ \t]*$/, "", desc)
        if (name != "") print name "\t" desc
      }
    }'
}

# Same audit-file write as log_finding, but WITHOUT the stderr echo. The
# absent-`environments:` case fires on nearly every ordinary commit in
# nearly every bionic-using repo (the key is opt-in), so surfacing it there
# the way an actionable finding is surfaced would be noise, not information.
# The durable file still gets the line — "log-only" — but only a plan that
# actually declared the key can make this arm speak on stderr.
# [INSTRUMENT]
log_finding_quiet() {  # $1=check-id  $2=detail
  local f
  if f=$(audit_path "$(audit_root)"); then
    local line="- $(date -u +%Y-%m-%dT%H:%M:%SZ) evidence-gate $1: $2 ($PLAN)"
    mkdir -p "$(dirname "$f")" 2>/dev/null && printf '%s\n' "$line" >> "$f" 2>/dev/null
  fi
  return 0
}

validate_environments() {
  local raw entries name desc cure covered_names fog_names fog_missing_cure
  local b5 covered_line covered_norm missing claimed_fog claimed_undeclared
  case "$CURRENT" in 5|6|7|8|9) : ;; *) return 0 ;; esac
  raw=$(frontmatter_get environments)
  if [ -z "$raw" ]; then
    log_finding_quiet environments "no 'environments:' declared in frontmatter — the covered/fog check is a no-op"
    return 0
  fi

  entries=$(env_split_entries "$raw")
  covered_names=""
  fog_names=""
  fog_missing_cure=""
  while IFS=$'\t' read -r name desc; do
    [ -n "$name" ] || continue
    case "$desc" in
      fog*)
        fog_names="${fog_names:+$fog_names }$name"
        cure=""
        case "$desc" in
          *cure:*) cure=$(printf '%s' "$desc" | sed -E 's/^.*cure:[[:space:]]*//' | sed -E 's/[[:space:]]+$//') ;;
        esac
        [ -n "$cure" ] || fog_missing_cure="${fog_missing_cure:+$fog_missing_cure }$name"
        ;;
      *)
        covered_names="${covered_names:+$covered_names }$name"
        ;;
    esac
  done <<< "$entries"

  if [ -n "$fog_missing_cure" ]; then
    block_matrix "environments: fog entry with no cure named: ${fog_missing_cure} (declared: '${raw}')." \
      "name each fog environment's cure in the frontmatter, e.g. '<name> (fog — cure: <how it gets covered>)'."
  fi

  if [ -n "$covered_names" ]; then
    b5=$(step5_evidence_block)
    covered_line=$(echo "$b5" | grep -E '^[[:space:]]*environments-covered[[:space:]]*:' | head -1 \
      | sed -E 's/^[[:space:]]*environments-covered[[:space:]]*:[[:space:]]*//' \
      | sed -E 's/;.*$//' | sed -E 's/[[:space:]]+$//')
    if [ -z "$covered_line" ]; then
      block_matrix "environments: declared covered set (${covered_names}) but the Step 5 evidence has no 'environments-covered:' line." \
        "record 'environments-covered: <name>[, <name>...]' in the Step 5 block naming every declared non-fog environment."
    fi
    covered_norm=$(printf '%s' "$covered_line" | tr ',' ' ' | tr -s '[:space:]' ' ')
    missing=""
    for name in $covered_names; do
      case " $covered_norm " in
        *" $name "*) : ;;
        *) missing="${missing:+$missing }$name" ;;
      esac
    done
    if [ -n "$missing" ]; then
      block_matrix "environments-covered '${covered_line}' omits declared environment(s): ${missing} (declared covered set: ${covered_names}; fog: ${fog_names:-none})." \
        "run the Step-5 tests floor on every declared non-fog environment and list it in 'environments-covered:', or move it to a fog entry naming its cure."
    fi

    # THE OTHER DIRECTION — OVER-CLAIMING (critic K-5). The loop above walks the DECLARED
    # non-fog names and requires each to be covered. Nothing walked the covered names, so a
    # plan could claim coverage it does not have and the arm was silent: this wave's own
    # frontmatter passes `environments-covered: macos-system, linux-system` while
    # linux-system is declared FOG, and a fog entry's entire meaning is "not covered". A
    # name that was never declared at all (`freebsd`) was equally silent. The ownership row
    # states the containment in this direction — covered ⊆ declared — and until now only
    # the opposite one was implemented.
    claimed_fog=""
    claimed_undeclared=""
    for name in $covered_norm; do
      case " $covered_names " in *" $name "*) continue ;; esac
      case " $fog_names " in
        *" $name "*) claimed_fog="${claimed_fog:+$claimed_fog }$name"; continue ;;
      esac
      claimed_undeclared="${claimed_undeclared:+$claimed_undeclared }$name"
    done
    if [ -n "$claimed_fog" ]; then
      block_matrix "environments-covered '${covered_line}' claims coverage of environment(s) this plan declares as FOG: ${claimed_fog} (fog: ${fog_names:-none})." \
        "a fog entry means NOT covered — either drop the name from 'environments-covered:', or run the Step-5 tests floor there and move it out of fog in the frontmatter."
    fi
    if [ -n "$claimed_undeclared" ]; then
      block_matrix "environments-covered '${covered_line}' names environment(s) the frontmatter never declared: ${claimed_undeclared} (declared: '${raw}')." \
        "declare the environment in the frontmatter's 'environments:' list, or drop it from 'environments-covered:' — the covered set is a subset of the declared one."
    fi
  fi
  return 0
}

# Verify gate: tests floor, the Verification Matrix, and — at peer-reviewed or
# audited rigor, once no row is still pending — a non-empty `auditor:` pointer.
# At `tested` that pointer is not demanded (matrix_auditor_required).
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
validate_verify_step() {
  local aud
  validate_tests_block 5
  validate_environments
  validate_matrix
  # Walk-first: the narration must already exist once anything has discharged.
  validate_walk_artifact
  # The auditor is the Step-5 exit gate — it cannot have run while
  # rows are still pending/blocked, so the pointer is required only once
  # every row is discharged or waived, and only where an auditor exists at
  # all (matrix_auditor_required: never at `tested`).
  # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
  if [ "$UNDISCHARGED" -eq 0 ] && matrix_auditor_required; then
    if ! block_has auditor; then
      block_matrix "the Verify gate requires 'auditor: <verdict summary + report pointer>' in the Step 5 block." \
        "record the independent auditor's one-line verdict summary and report pointer as 'auditor: ...'."
    fi
    aud=$(block_get auditor)
    if [ -z "$aud" ]; then
      block_matrix "the Step 5 'auditor:' pointer is empty." \
        "record the auditor's verdict summary and report pointer."
    fi
  fi
}

# Epic merge-target consistency (LOG-ONLY; D14, check-id `merge-target`).
# On a wave-scale plan naming an `epic:`, when the epic plan exists and
# declares an `integration-branch:` in its ## SDLC State, a mismatch with this
# plan's integration-branch logs a finding. Never blocks. First cross-file read
# in this hook — read-only, fail-open (missing epic plan / missing key → no
# finding). Fires at the integrate step.
# [INSTRUMENT]
validate_merge_target() {
  local epic epic_plan epic_branch this_branch
  epic=$(frontmatter_get epic)
  [ -n "$epic" ] || return 0
  epic_plan="$DOCS_ROOT/plans/$epic/epic.plan.md"
  [ -r "$epic_plan" ] || return 0
  # Fence-aware (matches the SECTION extraction): an epic plan documenting a
  # `## SDLC State` example in a ``` fence must not shadow its real section.
  # [INSTRUMENT]
  epic_branch=$(normalize_newlines "$epic_plan" \
    | awk '
      /^[[:space:]]*```/ { fence = !fence; next }
      fence { next }
      /^## SDLC State/ { f=1; next }
      /^## / { f=0 }
      f' \
    | grep -E '^[[:space:]]*integration-branch[[:space:]]*:' | head -1 \
    | sed -E 's/^[[:space:]]*integration-branch[[:space:]]*:[[:space:]]*//' | sed -E 's/[[:space:]]+$//')
  [ -n "$epic_branch" ] || return 0
  this_branch=$(echo "$SECTION" | grep -E '^[[:space:]]*integration-branch[[:space:]]*:' | head -1 \
    | sed -E 's/^[[:space:]]*integration-branch[[:space:]]*:[[:space:]]*//' | sed -E 's/[[:space:]]+$//')
  if [ -n "$this_branch" ] && [ "$this_branch" != "$epic_branch" ]; then
    log_finding merge-target "plan integration-branch '$this_branch' != epic '$epic' integration-branch '$epic_branch'"
  fi
  return 0
}

# Intent-scoped Step-5 evidence keys (R7) — LOG-ONLY (D14; check-ids
# `refactor-evidence`, `tune-evidence`). Fires on plans whose
# declared intent carries a conditional key set; never blocks. Reuses the
# Step-5 BLOCK/block_has/block_get accessors already populated for the
# current step's evidence (same accessors validate_verify_step uses),
# so this validator is only meaningful when called at current: 5.
# [INSTRUMENT]
validate_intent_evidence() {
  local key val
  case "$INTENT" in
    refactor)
      if ! block_has behavior-preservation || [ -z "$(block_get behavior-preservation)" ] \
         || is_placeholder_value "$(block_get behavior-preservation)"; then
        log_finding refactor-evidence "refactor plan Step 5 missing 'behavior-preservation:' evidence"
      fi
      for key in compat-matrix revert-plan; do
        if block_has "$key"; then
          val=$(block_get "$key")
          if [ -z "$val" ] || is_placeholder_value "$val"; then
            log_finding refactor-evidence "refactor plan Step 5 '${key}:' present but empty"
          fi
        fi
      done
      ;;
    tune)
      for key in baseline target re-measure; do
        val=$(block_get "$key")
        if ! block_has "$key" || [ -z "$val" ] || is_placeholder_value "$val"; then
          log_finding tune-evidence "tune plan Step 5 missing '${key}:' evidence"
        fi
      done
      ;;
  esac
  return 0
}

# Wave-scale D7 dispatched-task ledger PRESENCE (D-slice 4/3). Guarded to
# scale:wave + frontmatter rigor:audited + multi_agent:true plans; for
# every other plan it is a no-op (return 0). scale:epic is intentionally OUT —
# epic plans legitimately dispatch research, not task-shaped units, so demanding
# a dispatched-task ledger there would false-block scoping runs (plan Assumption
# A8). Called from dispatch_modern, so it runs at EVERY step that reaches the
# dispatcher (plan Assumption A5): the ledger is commit-time bookkeeping (D7:
# ledger before marking complete), demanded from the first gated commit.
#
# TESTED-FLOOR SHAPE ONLY (plan Assumption A2): the wave's own Step-5 auditor /
# Step-6 critic are the assurance roles at wave scale, so per-row auditor/critic
# tokens (task-scale machinery) are NOT demanded here.
#   1. `## Tasks` section ABSENT -> exit 2 (empty is fine, absent is not — the
#      audited multi_agent wave must carry its dispatched-task ledger home).
#   2. ZERO data rows -> SATISFIED (a human `none dispatched` prose line is
#      documentation, not required by the parser). return 0.
#   3. Each data row: status (field 6) in {pending,active,done,dropped} else
#      exit 2; a non-placeholder `- T<n>:` evidence line must exist in the
#      ## SDLC State section (SECTION) else exit 2.
# [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
validate_dispatch_ledger() {
  [ "$SCALE" = "wave" ] || return 0
  [ "$RIGOR" = "audited" ] || return 0
  [ "$MULTI_AGENT" = "true" ] || return 0

  local tasks rows line id status ev
  # Fence-aware `## Tasks` extraction — same awk extractor as validate_task_ledger.
  tasks=$(normalize_newlines "$PLAN" | awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    /^## Tasks/ { f=1; next }
    /^## / { f=0 }
    f')
  if [ -z "$tasks" ]; then
    echo "BLOCKED: canonical-sdlc audited multi_agent wave plan has no '## Tasks' dispatched-task ledger section." >&2
    echo "Plan: $PLAN" >&2
    echo "Fix: add a '## Tasks' section (a header plus a 'none dispatched' line is fine); the orchestrator appends one row per dispatched task-shaped unit (D7)." >&2
    exit 2
  fi
  rows=$(echo "$tasks" | grep -E '^[[:space:]]*\|[[:space:]]*T[0-9]+')
  [ -n "$rows" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=$(echo "$line"     | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
    status=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6}')
    # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
    case "$status" in
      pending|active|done|dropped) : ;;
      *)
        echo "BLOCKED: canonical-sdlc dispatched task ${id} has invalid status '${status:-empty}' (want pending|active|done|dropped)." >&2
        echo "Plan: $PLAN" >&2
        echo "Fix: set the '${id}' row's status cell to one of pending|active|done|dropped before committing." >&2
        exit 2
        ;;
    esac
    # Evidence line in ## SDLC State (anchored, same lookup as task scale).
    # [WALL: tests/canonical-sdlc-evidence-gate.test.sh]
    ev=$(echo "$SECTION" | grep -E "^[[:space:]]*-?[[:space:]]*${id}[[:space:]]*:" | head -1 \
         | sed -E "s/^[[:space:]]*-?[[:space:]]*${id}[[:space:]]*:[[:space:]]*//" | sed -E 's/[[:space:]]+$//')
    if [ -z "$ev" ]; then
      echo "BLOCKED: canonical-sdlc dispatched task ${id} has no '- ${id}:' evidence line in '## SDLC State'." >&2
      echo "Plan: $PLAN" >&2
      echo "Fix: record the dispatched unit's evidence artifact on a '- ${id}:' line before committing." >&2
      exit 2
    fi
    if is_placeholder_value "$ev"; then
      echo "BLOCKED: canonical-sdlc dispatched task ${id} evidence line is a placeholder ('${ev}')." >&2
      echo "Plan: $PLAN" >&2
      echo "Fix: replace the '- ${id}:' placeholder with the actual evidence artifact before committing." >&2
      exit 2
    fi
  done <<< "$rows"
  return 0
}

# Step numbering: 4 worktree · 5 Verify gate · 7 Document · 8 Integrate &
# close · 9 Close-out. Steps 1/2/3/6 are pointer steps handled upstream, except
# that Step 6 reaches here so the matrix prefix check can fire.
INTEGRATE_STEP=8
SHIP_STEP=9

dispatch() {
  # Audited multi_agent wave: D7 dispatched-task ledger PRESENCE, at every step
  # that reaches this dispatcher (guarded internally; no-op otherwise).
  validate_dispatch_ledger
  # The Verification Matrix is a prefix contract for every step from the Verify
  # gate on — current: 5 validates it inside validate_verify_step; current: 6..9
  # validate it here, so a REFUTED auditor blocks post-Verify commits too.
  # The walk artifact is a durable prefix condition alongside it (A5): deleting
  # the narration after the Verify gate blocks every later commit. The
  # environments claim (S3, AC-4) is the same shape: covered ⊆ declared and
  # every fog entry's cure stay true across the whole post-Verify span.
  case "$CURRENT" in
    6|7|8|9) validate_matrix; validate_walk_artifact; validate_environments ;;
  esac
  # Log-only epic merge-target check at the integrate step.
  [ "$CURRENT" = "$INTEGRATE_STEP" ] && validate_merge_target
  case "$CURRENT" in
    4) shape_block worktree base-sha branch ;;
    5)
      validate_verify_step
      validate_intent_evidence
      ;;
    7) validate_document_step 7 ;;
    *)
      if [ "$CURRENT" = "$INTEGRATE_STEP" ]; then
        validate_integrate_step
      elif [ "$CURRENT" = "$SHIP_STEP" ]; then
        validate_ship_step "$SHIP_STEP"
      fi
      ;;
  esac
}

dispatch
exit 0
