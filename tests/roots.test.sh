#!/bin/bash
# tests/roots.test.sh — payload/scripts/lib/roots.sh: one resolver per root, and the
# consumers that move when a root moves (epic-22 wave-01, REQ-N1; AC-N1.1/N1.3; ADR-003).
#
# WHAT IT OWNS. Two questions the static pin in tests/cross-gate-agreement.test.sh §Roots
# cannot answer. §Roots counts DEFINITIONS — it proves there is one `docs_root` in the tree
# and that every former carrier stopped defining its own. It cannot prove the one definition
# is right, and it cannot prove a consumer actually routes through it: a hook that dropped
# its copy and then spelled `$PROJECT/.bionic/docs` inline satisfies every count in §Roots.
# So:
#
#   §1  each resolver's own answer, default and override, over fixture roots.
#   §2  ONE CONFIG CHANGE MOVES EVERY CONSUMER. A fixture project sets `docs-root: alt`;
#       lib/run.sh's plan search, doctor's active-run row, hooks/stop-check.sh's contracted
#       -path resolution and hooks/canonical-sdlc-governing-skill.sh's project scaffold must
#       all land under `alt/`. AC-N1.3's fails-when is "one consumer still hard-codes", and
#       §2's mutation arm is exactly that consumer: a scratch copy of stop-check with the
#       library call replaced by the literal must go red where the shipped one is green.
#
# THE LIVE DEFECT §2c FIXES. canonical-sdlc-governing-skill.sh resolved `docs-root:` into
# `$DOCS_ROOT` at the top of the file and then scaffolded `$PROJECT/.bionic/docs/{specs,
# plans,adrs,incidents}` with a literal at the bottom — so a project that set the key got the
# DEFAULT tree created and its configured tree never created, and then met that same hook's
# misplacement refusal for writing into the tree it had asked for (surfaces map §C.2).
#
# HERMETIC. Every root is a fixture directory under a mktemp sandbox; HOME and
# CLAUDE_CONFIG_DIR are redirected into it, and the hooks are driven from a PLANTED TREE
# (hooks/ beside scripts/lib/) holding this checkout's library, never from the installed
# plugin — the loader's first candidate is `$(dirname "$0")/../scripts/lib`, so a hook copied
# alone into a temp directory would heal to whatever is installed on this machine and every
# row below would be measuring that instead.
#
# Usage: bash tests/roots.test.sh

set -uo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"
# THE SHARED FIXTURE BUILDERS, not hand-written shapes. `live_answer_body` composes a
# ListAgents answer out of the committed corpus (tests/lib/live-answer.sh), and
# `roster_row_fixture` writes a roster row through the production writer
# (payload/scripts/lib/roster.sh). §2b needs both because hooks/stop-check.sh resolves a
# target against the session's recorded live set and its roster row before it resolves any
# path at all — and a hand-typed answer or row is how a fixture comes to test its own
# spelling instead of the hook.
. "$(dirname "$0")/lib/live-answer.sh"
. "$BIONIC_SCRIPTS_DIR/lib/roster.sh"
. "$(dirname "$0")/lib/roster-row.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LIB_DIR="$REPO_ROOT/payload/scripts/lib"
LIB="$LIB_DIR/roots.sh"
HOOKS_SRC="$REPO_ROOT/hooks"

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/roots-test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

export HOME="$SANDBOX/home"
export CLAUDE_CONFIG_DIR="$SANDBOX/cfg"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR"
unset CLAUDE_CODE_SESSION_ID
unset BIONIC_CLAUDE_HOME BIONIC_PLUGIN_ROOT CLAUDE_PLUGIN_ROOT 2>/dev/null || true

# call <fn> <args...> — the library in a child shell, so no row can be answered by a
# function some earlier row left defined in this one.
call() {
  local fn="$1"; shift
  bash -c '. "$1" || exit 1; fn="$2"; shift 2; "$fn" "$@"' _ "$LIB" "$fn" "$@" 2>"$SANDBOX/.err"
}

# contains <haystack> <needle> -> yes|no. A function and not a `case` inside a command
# substitution: bash 3.2 — this file's shebang interpreter — mis-parses that shape and
# truncates the substitution at the first `)` (run-predicate R0's own note).
contains() {
  case "$1" in
    *"$2"*) printf 'yes' ;;
    *)      printf 'no'  ;;
  esac
}

# ============================================================
section "1 — the library exists, parses, and defines every root"
# ============================================================

expect_eq "roots.sh is on disk" "yes" "$([ -r "$LIB" ] && echo yes || echo no)"
expect_eq "roots.sh parses" "yes" "$(bash -n "$LIB" 2>/dev/null && echo yes || echo no)"

for _fn in project_root bionic_root docs_root tmp_root archive_root plugin_root \
           claude_home worktree_root transcripts_dir config_value; do
  expect_eq "sourcing roots.sh defines $_fn" "yes" \
    "$(bash -c '. "$1" >/dev/null 2>&1 || exit 1; declare -F "$2" >/dev/null 2>&1 && echo yes || echo no' _ "$LIB" "$_fn")"
done

# SOURCING IS SILENT. The one top-level command in the file is the soft source of root.sh,
# and a library that printed on the way in would corrupt every hook that captures a
# resolver's output in a command substitution.
expect_eq "sourcing roots.sh prints nothing on stdout" "" \
  "$(bash -c '. "$1"' _ "$LIB" 2>/dev/null)"
expect_eq "…and nothing on stderr" "" \
  "$(bash -c '. "$1"' _ "$LIB" 2>&1 >/dev/null)"

# ============================================================
section "1a — the project's roots: default, override, absolute override"
# ============================================================

P="$SANDBOX/p1"; mkdir -p "$P/.bionic"

expect_eq "bionic_root is <root>/.bionic"          "$P/.bionic"      "$(call bionic_root "$P")"
expect_eq "tmp_root is <root>/.bionic/tmp"          "$P/.bionic/tmp"  "$(call tmp_root "$P")"
expect_eq "docs_root defaults to <root>/.bionic/docs" "$P/.bionic/docs" "$(call docs_root "$P")"

printf 'docs-root: alt\n' > "$P/.bionic/config.yaml"
expect_eq "docs_root: a relative docs-root: joins onto the project" "$P/alt" "$(call docs_root "$P")"

printf 'docs-root: /srv/elsewhere\n' > "$P/.bionic/config.yaml"
expect_eq "docs_root: an absolute docs-root: passes through unchanged" "/srv/elsewhere" \
  "$(call docs_root "$P")"

# THE SPELLINGS `config_value` ALREADY TOLERATES reach docs_root now, because docs_root IS a
# caller of it. Before N1 the two readers were six duplicated lines apiece, held together by
# tests/run-predicate.test.sh R9h asserting they agreed edge for edge.
printf '  docs-root:   alt2  \n' > "$P/.bionic/config.yaml"
expect_eq "docs_root: indentation and trailing space, through the one reader" \
  "$P/alt2" "$(call docs_root "$P")"
printf 'docs-root: "alt3"\n' > "$P/.bionic/config.yaml"
expect_eq "docs_root: a quoted value comes back unquoted" "$P/alt3" "$(call docs_root "$P")"
# THE SHARED WART, pinned rather than fixed. The quote strip runs BEFORE the trailing-space
# trim in `config_value`, so a quoted value with a trailing space keeps its closing quote.
# tests/run-predicate.test.sh R9h pinned exactly this on the two readers that used to exist
# separately, as the thing holding them in agreement. There is one reader now, so the wart
# is one wart — and it is pinned here too, because a future slice that fixes it should have
# to come past a row that says so rather than discover it in a hook.
printf 'docs-root: "alt4" \n' > "$P/.bionic/config.yaml"
expect_eq "docs_root: a quoted value with a trailing space keeps its closing quote" \
  "$P/alt4\"" "$(call docs_root "$P")"

rm -f "$P/.bionic/config.yaml"
expect_eq "docs_root: the config file removed -> back to the default" "$P/.bionic/docs" \
  "$(call docs_root "$P")"

# --- archive_root (ADR-003 decision 2, AC-C.6) ---
expect_eq "archive_root defaults to \$HOME/bionic-archive" "$HOME/bionic-archive" \
  "$(call archive_root "$P")"
printf 'archive-root: /vol/arch\n' > "$P/.bionic/config.yaml"
expect_eq "archive_root: an absolute archive-root: stands" "/vol/arch" "$(call archive_root "$P")"
printf 'archive-root: ../arch\n' > "$P/.bionic/config.yaml"
expect_eq "archive_root: a relative one joins onto the project, docs_root's rule" \
  "$P/../arch" "$(call archive_root "$P")"
rm -f "$P/.bionic/config.yaml"

# ============================================================
section "1b — the machine's roots"
# ============================================================

expect_eq "claude_home follows CLAUDE_CONFIG_DIR" "$CLAUDE_CONFIG_DIR" "$(call claude_home)"
expect_eq "…and BIONIC_CLAUDE_HOME wins over it" "$SANDBOX/override" \
  "$(BIONIC_CLAUDE_HOME="$SANDBOX/override" call claude_home)"
expect_eq "transcripts_dir is claude_home's projects/ directory" "$CLAUDE_CONFIG_DIR/projects" \
  "$(call transcripts_dir)"
expect_eq "…and it moves with claude_home, never independently" "$SANDBOX/override/projects" \
  "$(BIONIC_CLAUDE_HOME="$SANDBOX/override" call transcripts_dir)"

expect_eq "plugin_root is the payload root two levels above the library" \
  "$(cd "$LIB_DIR/../.." && pwd -P)" "$(call plugin_root)"
expect_eq "…and BIONIC_PLUGIN_ROOT overrides it" "/opt/bionic" \
  "$(BIONIC_PLUGIN_ROOT=/opt/bionic call plugin_root)"
expect_eq "…and CLAUDE_PLUGIN_ROOT does too" "/opt/from-cli" \
  "$(CLAUDE_PLUGIN_ROOT=/opt/from-cli call plugin_root)"

# --- worktree_root: the answer that made three resolvers exist ---
GITP="$SANDBOX/gitp"
mkdir -p "$GITP"
( cd "$GITP" && git init -q . && git config user.email t@t && git config user.name t \
  && printf 'x\n' > f && git add f && git commit -qm init ) >/dev/null 2>&1
expect_eq "worktree_root in the main checkout is the main checkout" "$(cd "$GITP" && pwd -P)" \
  "$(call worktree_root "$GITP")"
( cd "$GITP" && git worktree add -q -b wtb "$GITP/.wt/one" HEAD ) >/dev/null 2>&1
expect_eq "worktree_root from INSIDE a linked worktree is still the main checkout" \
  "$(cd "$GITP" && pwd -P)" "$(call worktree_root "$GITP/.wt/one")"
# THE PAIRED NEGATIVE: --show-toplevel, asked in the same place, answers with the LINKED
# tree. That difference is the whole reason three resolvers existed for this question, and
# without this row the assertion above could be green against a resolver that just called
# --show-toplevel in a repository that happened to have no worktree.
expect_ne "…which is exactly what --show-toplevel answers differently" \
  "$(cd "$GITP" && pwd -P)" "$(cd "$GITP/.wt/one" && git rev-parse --show-toplevel)"
expect_eq "worktree_root outside a repository exits non-zero" "1" \
  "$(call worktree_root "$SANDBOX/home" >/dev/null 2>&1; echo $?)"

# ============================================================
section "1c — config_value is the one reader, and docs_root goes through it"
# ============================================================
#
# tests/run-predicate.test.sh §R9 owns config_value's twelve behaviours and still does — it
# sources lib/run.sh, which soft-sources this file. What is asserted here is the property
# that made the move worth taking: docs-root: is read by the general reader now, so a fix to
# one is a fix to both, and there is no pair left to hold in agreement.

C="$SANDBOX/cfgroot"; mkdir -p "$C/.bionic"
printf 'docs-root: dd\nlive-window: 30d\n' > "$C/.bionic/config.yaml"
expect_eq "config_value reads docs-root: itself" "dd" "$(call config_value "$C" docs-root "")"
expect_eq "…and docs_root returns exactly that, joined" "$C/dd" "$(call docs_root "$C")"
expect_eq "…and another key from the same file" "30d" "$(call config_value "$C" live-window 7d)"
expect_eq "config_value: a missing key is the default" "7d" "$(call config_value "$C" nope 7d)"

# ============================================================
setup_section "2 — one config change moves EVERY consumer (AC-N1.3)"
# ============================================================
#
# THE PLANTED TREE. hooks/ beside scripts/lib/, holding this checkout's library, because the
# loader's first candidate is `$(dirname "$0")/../scripts/lib` — see the header.

PLANT="$SANDBOX/plant"
mkdir -p "$PLANT/hooks" "$PLANT/scripts/lib"
cp "$HOOKS_SRC"/*.sh "$PLANT/hooks/" 2>/dev/null
cp "$HOOKS_SRC"/hooks.json "$PLANT/hooks/" 2>/dev/null
cp "$LIB_DIR"/*.sh "$PLANT/scripts/lib/" 2>/dev/null

# THE FIXTURE PROJECT. `docs-root: alt`, and every artifact under `alt/` rather than under
# `.bionic/docs/`. A consumer that hard-codes the default finds an empty tree.
PROJ="$SANDBOX/proj"
mkdir -p "$PROJ/.bionic/tmp" "$PROJ/alt/plans/epic-99" "$PROJ/alt/record"
printf 'docs-root: alt\n' > "$PROJ/.bionic/config.yaml"
cat > "$PROJ/alt/plans/epic-99/wave-01.plan.md" <<'PLAN'
---
canonical_sdlc_version: 14
intent: build
rigor: audited
scale: wave
---

# Wave 01

## SDLC State

current: 4

- Step 0: confirmed
PLAN
printf 'progress\n' > "$PROJ/alt/record/s99.md"

# THE OBSERVING SESSION, for §2b. hooks/stop-check.sh resolves a typed target against the
# newest recorded ListAgents answer in that session's transcript, then against the roster
# row carrying the agent id. Only after both does it resolve the contracted path — so
# without these two the row below would measure the resolution refusal, not the root.
PROJ_SID="rootssid1"
PROJ_SLUG="$(printf '%s' "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$PROJ_SLUG"
{
  jq -nc --arg ts "2026-09-05T00:50:00.000Z" \
    '{type:"user",timestamp:$ts,message:{role:"user",content:"go"}}'
  jq -nc --arg ts "2026-09-05T00:51:00.000Z" \
    '{type:"assistant",timestamp:$ts,message:{role:"assistant",content:[{type:"tool_use",id:"toolu_01FIXTURELISTAGENTS",name:"ListAgents",input:{}}]}}'
  jq -nc --arg ts "2026-09-05T00:52:23.349Z" --arg b "$(live_answer_body some-agent)" \
    '{type:"user",timestamp:$ts,message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_01FIXTURELISTAGENTS",content:$b}]}}'
} > "$CLAUDE_CONFIG_DIR/projects/$PROJ_SLUG/$PROJ_SID.jsonl"
roster_row_fixture status=identified session="$PROJ_SID" name=some-agent \
  agent_id=a0000001 deliverable=record/s99.md > "$PROJ/.bionic/tmp/roster-$PROJ_SID.state"

# The same artifacts under the DEFAULT root, holding different content, so a hard-coding
# consumer is not merely wrong-and-empty but demonstrably reading the other tree.
mkdir -p "$PROJ/.bionic/docs/plans/epic-00"
cat > "$PROJ/.bionic/docs/plans/epic-00/decoy.plan.md" <<'PLAN'
---
canonical_sdlc_version: 14
---

## SDLC State

current: 4
PLAN

expect_eq "fixture: the planted tree carries the library" "yes" \
  "$([ -r "$PLANT/scripts/lib/roots.sh" ] && echo yes || echo no)"
expect_eq "fixture: the project's docs root resolves to alt/" "$PROJ/alt" \
  "$(call docs_root "$PROJ")"

# ============================================================
section "2a — lib/run.sh's plan search follows docs-root:"
# ============================================================
#
# run.sh is the consumer whose own `docs_root()` was the fifth copy — the one cross-gate §R
# could not see, because §R globbed hooks/ only.

RUN_PLAN="$(bash -c '. "$1" || exit 1; active_plan "$2"' _ "$PLANT/scripts/lib/run.sh" "$PROJ" 2>/dev/null)"
expect_eq "run.sh's active_plan finds the plan under alt/" \
  "$PROJ/alt/plans/epic-99/wave-01.plan.md" "$RUN_PLAN"
expect_eq "…and not the decoy under the default root" "no" "$(contains "$RUN_PLAN" "decoy")"

# ============================================================
section "2b — hooks/stop-check.sh resolves a contracted path under docs-root:"
# ============================================================
#
# `record/`-led paths are docs-root-relative — the rule this whole lineage exists for, and
# the one stop-check got wrong before epic-17 W6 S15: it stat'd a relative path against
# whatever directory the observer stood in, so a landed deliverable read ABSENT.
#
# THE OBSERVABLE IS PRESENT vs ABSENT, not a path in the prose. The command prints the
# deliverable under the spelling the contract used (`record/s99.md`) and never the resolved
# absolute, so the honest reading of "which root did it resolve against" is whether it
# FOUND the file — and the file exists under `alt/` and nowhere else. The machine line at
# the end of the output is what other bionic readers parse, so it is what is read here.

SC_OUT="$( cd "$PROJ" && CLAUDE_CODE_SESSION_ID="$PROJ_SID" \
  bash "$PLANT/hooks/stop-check.sh" some-agent record/s99.md 2>&1 )"
expect_eq "stop-check found record/s99.md, which exists only under alt/" "yes" \
  "$(contains "$SC_OUT" "deliverables=present:record/s99.md")"
expect_eq "…so it did not resolve against the default root, where nothing is" "no" \
  "$(contains "$SC_OUT" "deliverables=absent:record/s99.md")"

# --- THE FAILS-WHEN ARM (AC-N1.3: "one consumer still hard-codes"). A scratch copy of the
# hook with the library call replaced by the literal the four retired copies used to spell.
# The shipped file is never touched; the mutant is a copy in the sandbox. Without this row
# the two above prove only that the hook currently agrees, not that a hard-coding one would
# be visible here. ---
SC_MUT_DIR="$SANDBOX/stopcheck-mutant"
mkdir -p "$SC_MUT_DIR/hooks" "$SC_MUT_DIR/scripts/lib"
cp "$PLANT/scripts/lib"/*.sh "$SC_MUT_DIR/scripts/lib/"
anchor "$PLANT/hooks/stop-check.sh" 'DOCS_ROOT="$(docs_root "$PROJECT_DIR")"' 1
sed 's|DOCS_ROOT="$(docs_root "$PROJECT_DIR")"|DOCS_ROOT="$PROJECT_DIR/.bionic/docs"|' \
  "$PLANT/hooks/stop-check.sh" > "$SC_MUT_DIR/hooks/stop-check.sh"
expect_eq "the mutant really differs from the shipped hook (the sed landed)" "no" \
  "$(cmp -s "$PLANT/hooks/stop-check.sh" "$SC_MUT_DIR/hooks/stop-check.sh" && echo yes || echo no)"

SC_MUT_OUT="$( cd "$PROJ" && CLAUDE_CODE_SESSION_ID="$PROJ_SID" \
  bash "$SC_MUT_DIR/hooks/stop-check.sh" some-agent record/s99.md 2>&1 )"
expect_eq "…and a hard-coding stop-check reports the SAME deliverable ABSENT" "yes" \
  "$(contains "$SC_MUT_OUT" "deliverables=absent:record/s99.md")"
expect_eq "…so the two rows above do discriminate" "no" \
  "$(contains "$SC_MUT_OUT" "deliverables=present:record/s99.md")"

# ============================================================
section "2c — the governing-skill hook SCAFFOLDS under docs-root: (the live defect)"
# ============================================================
#
# The hook resolved `docs-root:` at the top and then scaffolded a literal at the bottom, so
# a project with the key set got the default tree created and its configured tree never
# created — and then met this same hook's misplacement refusal for writing where it had
# asked to write. Both directions are asserted: the configured tree appears, and no default
# tree is created beside it.
#
# THE PAYLOAD IS A COMPLETE ONE. The scaffold runs at the hook's single `exit 0`, past every
# gate — deliberately, so a Write this hook REFUSES leaves no tree behind — so a fixture
# missing one frontmatter flag proves nothing about the scaffold. The session id is pinned
# in the environment as well as the payload because `session_id` prefers the environment,
# and an unpinned call would engage against the id of whatever session is running the suite.

gs_payload() {  # <cwd> <file_path> -> a complete PreToolUse Write payload on stdout
  jq -nc --arg cwd "$1" --arg fp "$2" --arg c "$GS_CONTENT" \
    '{session_id:"rootssid2",hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Write",
      tool_input:{file_path:$fp,content:$c}}'
}

GS_CONTENT='---
canonical_sdlc_version: 14
governing-skill: agent-skills:spec-driven-development
sdlc-step: 1
intent: build
rigor: audited
scale: wave
surface_type: cli-plugin
language: bash
has_ui: false
multi_agent: false
deploy_target: n/a
cleanup_on_finish: true
use_worktree: false
model_plan: orchestrator=claude-fable-5-1
---

# Spec

## Design

One resolver per root; every former copy calls it.
'

GS_PROJ="$SANDBOX/gsproj"
mkdir -p "$GS_PROJ/.bionic/tmp" "$GS_PROJ/alt/specs/epic-99"
printf 'docs-root: alt\n' > "$GS_PROJ/.bionic/config.yaml"
touch "$GS_PROJ/.bionic/tmp/engaged-rootssid2.state"

GS_OUT="$( cd "$GS_PROJ" && CLAUDE_CODE_SESSION_ID=rootssid2 \
  bash "$PLANT/hooks/canonical-sdlc-governing-skill.sh" \
    < <(gs_payload "$GS_PROJ" "$GS_PROJ/alt/specs/epic-99/w.spec.md") 2>&1 )"; GS_ST=$?

expect_eq "the governing-skill hook allowed the fixture write (the scaffold runs at exit 0)" \
  "0" "$GS_ST"
expect_eq "…with nothing on the refusal channel (a refused write scaffolds nothing)" "" "$GS_OUT"
for _leader in specs plans adrs incidents; do
  expect_eq "…scaffolded alt/$_leader, the CONFIGURED tree" "yes" \
    "$([ -d "$GS_PROJ/alt/$_leader" ] && echo yes || echo no)"
done
expect_eq "…and created no .bionic/docs tree the project never asked for" "no" \
  "$([ -d "$GS_PROJ/.bionic/docs" ] && echo yes || echo no)"
expect_eq "…while the two state paths are still the project's own, not the docs root's" "yes" \
  "$([ -d "$GS_PROJ/.bionic/tmp" ] && [ -f "$GS_PROJ/.bionic/.gitignore" ] && echo yes || echo no)"

# THE OTHER DIRECTION, and the one a fix could break: a project WITHOUT the key still gets
# `.bionic/docs`. `alt/plans` proves the value moved; this proves it moved because of the
# config and not because the literal was simply swapped for another literal.
GS_DEF="$SANDBOX/gsdefault"
mkdir -p "$GS_DEF/.bionic/tmp" "$GS_DEF/.bionic/docs/specs/epic-99"
touch "$GS_DEF/.bionic/tmp/engaged-rootssid2.state"
( cd "$GS_DEF" && CLAUDE_CODE_SESSION_ID=rootssid2 \
  bash "$PLANT/hooks/canonical-sdlc-governing-skill.sh" \
    < <(gs_payload "$GS_DEF" "$GS_DEF/.bionic/docs/specs/epic-99/w.spec.md") ) >/dev/null 2>&1
for _leader in specs plans adrs incidents; do
  expect_eq "no docs-root: set -> .bionic/docs/$_leader, exactly as before" "yes" \
    "$([ -d "$GS_DEF/.bionic/docs/$_leader" ] && echo yes || echo no)"
done
expect_eq "…and no stray alt/ tree in a project that never named one" "no" \
  "$([ -d "$GS_DEF/alt" ] && echo yes || echo no)"

# ============================================================
section "2d — doctor's active-run row reads the same root"
# ============================================================
#
# Doctor is the third consumer AC-N1.3 names, and it reaches the docs root transitively:
# `active_run` -> `active_plan` -> `docs_root`. A doctor that resolved its own way would
# report "none" on a project whose walls are armed, which is the exact class of disagreement
# this library exists to end.

DOC_OUT="$( cd "$PROJ" && bash "$REPO_ROOT/payload/scripts/doctor.sh" 2>&1 )"
expect_eq "doctor's active-run row names the plan under alt/" "yes" \
  "$(contains "$DOC_OUT" "alt/plans/epic-99/wave-01.plan.md")"
expect_eq "…and not the decoy under the default root" "no" "$(contains "$DOC_OUT" "decoy.plan.md")"

finish
