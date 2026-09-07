#!/bin/bash
# Tests for canonical-sdlc-evidence-gate.sh
#
# Strategy: every runner pins HOME to a temp sandbox and pins the hook's
# project to a temp fixture, so no case can reach the developer's real
# ~/.claude/ or any real plan file.
#
# make_home() doubles as the simplest project fixture: the single-argument
# runner (run_hook) posts cwd=$home_dir, so the hook resolves PROJECT_DIR to the
# sandbox HOME and its docs root to $home_dir/.bionic/docs — which is where
# write_plan() puts plans. The sandbox also carries an EMPTY ~/.claude/plans/,
# the directory this gate deliberately does NOT search (2026-07-28); the cases
# that plant something there use write_global_note().
#
# Usage: bash tests/canonical-sdlc-evidence-gate.test.sh

set -euo pipefail

. "$(dirname "$0")/lib/resolve-roots.sh"
. "$(dirname "$0")/lib/assert.sh"
. "$(dirname "$0")/lib/bound-marker.sh"

HOOK="${BIONIC_HOOKS_DIR}/canonical-sdlc-evidence-gate.sh"

# ---------- helpers ----------

cleanup_dirs=()
cleanup() {
  for d in "${cleanup_dirs[@]}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

# Incident 0001: the audit file lives under $HOME, never in the project tree.
# Every runner in this suite already pins HOME to a make_home sandbox, so the
# relocated writes stay off the developer's real ~/.claude/logs. The sandbox
# HOME is always a SIBLING of the make_project fixtures (both are bare
# mktemp -d), never a parent — Section 21a's "nothing under the project tree"
# assertion depends on that.
# Slug must match hooks/canonical-sdlc-evidence-gate.sh audit_path() byte for byte.
slug_for() { printf '%s-%s' "$(basename "$1" | sed 's/[^A-Za-z0-9._-]/-/g')" \
                            "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; }
# $1 = sandbox HOME, $2 = the audit_root the hook resolved (the plan's project).
# THE SLUG IS TAKEN OVER THE CANONICAL PATH (bionic 1.4.0, slice ADOPT). The hook
# now resolves its root through lib/root.sh's `project_root`, which answers with
# `pwd -P` — so on a machine where the fixture root sits under a symlinked prefix
# (macOS: /var/folders -> /private/var/folders, which mktemp -d hands back
# unresolved) the hook's cksum and this helper's cksum are taken over two spellings
# of one directory, and every audit-file assertion looks for a file that was
# written one slug over.
audit_file_for() {
  local proj; proj=$(cd "$2" 2>/dev/null && pwd -P) || proj="$2"
  printf '%s/.claude/logs/%s/sdlc-audit.md' "$1" "$(slug_for "$proj")"
}

# Creates an isolated $HOME-equivalent that is ALSO usable as the project the
# single-argument runners gate against: an empty ~/.claude/plans/ (never
# searched — see write_global_note) plus an empty .bionic/docs/plans/ (searched).
make_home() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/.claude/plans" "$dir/.bionic/docs/plans"
  engage "$dir"
  cleanup_dirs+=("$dir")
  echo "$dir"
}

# ---------- engagement (task-engaged-session, AC-6) ----------
#
# Since 2026-09-03 this gate asks one question before it asks anything else: did this
# session invoke the canonical-sdlc skill? (Chris: "all guardrails imposed by bionic
# should only apply when exercising bionic. Nothing should apply until bionic is
# triggered.") hooks/engage.sh answers it by writing `.bionic/tmp/engaged-<sid>.state`
# under the project root at the instant of invocation, and lib/run.sh's `engaged_session`
# is the only reader.
#
# EVERY FIXTURE BELOW IS AN ENGAGED SESSION, because every assertion below is about what
# this gate does to a commit inside a canonical-sdlc run — which is a run somebody
# invoked. The unengaged world is its own section at the bottom of the file, driven on
# the same plans and the same commands, and it is where the marker's absence is proved.
EG_SID="4c3b2a19-8e7d-4f65-9a0b-1c2d3e4f5061"
engage()   { mkdir -p "$1/.bionic/tmp" && : > "$1/.bionic/tmp/engaged-$EG_SID.state"; }
unengage() { rm -f "$1/.bionic/tmp/engaged-$EG_SID.state"; }

# Creates an isolated project dir with .bionic/docs/plans/ ready to receive
# plan files. Returned path plays the CLAUDE_PROJECT_DIR role.
make_project() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/.bionic/docs/plans"
  engage "$dir"
  cleanup_dirs+=("$dir")
  echo "$dir"
}

# Writes $2 as a plan file inside $1/.bionic/docs/plans/ (project-local dir).
write_project_plan() {
  local project_dir="$1" content="$2" name="${3:-active.md}"
  local path="$project_dir/.bionic/docs/plans/$name"
  printf '%s\n' "$content" > "$path"
  touch "$path"
  echo "$path"
}

# Writes $2 as the content of a plan file in the sandbox HOME's OWN docs root
# ($1/.bionic/docs/plans/) — the plan directory the single-argument runners
# (run_hook, which posts cwd=$home_dir) make the hook search.
# Touches mtime to "now" so it becomes the newest.
write_plan() {
  local home_dir="$1" content="$2" name="${3:-active.md}"
  local path="$home_dir/.bionic/docs/plans/$name"
  printf '%s\n' "$content" > "$path"
  # Ensure mtime > any prior plan in this test by nudging forward.
  touch "$path"
  echo "$path"
}

# Writes $2 into the sandbox's ~/.claude/plans/ — the harness's own,
# project-AGNOSTIC plan directory, which this gate has NOT searched since
# 2026-07-28. Whatever lands here must be invisible to the hook; the fixtures
# using it assert exactly that. Newest mtime by construction, so a case that
# calls it last is planting the newest .md on the machine.
write_global_note() {
  local home_dir="$1" content="$2" name="${3:-note.md}"
  local path="$home_dir/.claude/plans/$name"
  printf '%s\n' "$content" > "$path"
  touch "$path"
  echo "$path"
}

# Runs hook with HOME set to $1 and the given bash-tool-call command $2.
# Sets globals HOOK_EXIT and HOOK_STDERR. The hook is stderr-only on block,
# silent on allow — no need to capture stdout.
# THE RESOLUTION ANNOUNCEMENT IS ITS OWN CHANNEL (wave-session-bound-run, AC-3/AC-6).
# The gate now says out loud which run it resolved and how — one line when an unbound
# session fell back to the newest plan, one when a bound session's plan is closed. Those
# lines are a REPORT, not a refusal, and they ride the only channel a hook has, so every
# `expect_allow` in this file (which asserts stderr is empty) would fail on a fixture
# whose marker carries no binding — which is every fixture above, because `engage` plants
# an empty marker.
#
# So the runners split the stream instead of loosening the assertion: HOOK_RESOLUTION
# holds the announcements and HOOK_STDERR holds EVERYTHING ELSE, still asserted empty on
# an allow. Section 35 reads the announcements on a whole stream of its own (`s35_run`),
# so nothing here can hide a line that was never printed: the pairing is a positive
# assertion that the line IS there for an unbound session and a negative that it is NOT
# for a bound one.
EG_RESOLUTION_RE='^evidence-gate: (run resolved by newest-plan fallback|bound plan closed)'
split_stderr() {  # <file> -> HOOK_RESOLUTION + HOOK_STDERR
  local raw
  raw=$(cat "$1")
  HOOK_RESOLUTION=$(printf '%s\n' "$raw" | grep -E "$EG_RESOLUTION_RE" || true)
  HOOK_STDERR=$(printf '%s\n' "$raw" | grep -v -E "$EG_RESOLUTION_RE" || true)
}

run_hook() {
  local home_dir="$1" command="$2"
  local input
  # Pin the hook's cwd to the sandbox HOME so PROJECT_DIR resolves via the
  # documented input-cwd path instead of falling through to the runner's real
  # pwd — otherwise the suite's verdicts would depend on whatever plan files
  # live under the ambient working directory (a hermeticity leak).
  # THE ENVIRONMENT AGREES WITH THE PAYLOAD, because on the machine it does. lib/session.sh
  # takes the env value as primary and the payload as a witness, so a runner that left the
  # real session id in the environment would have the gate looking for an engagement marker
  # no fixture here ever wrote — and every allow below would pass for the wrong reason.
  input=$(jq -n --arg c "$command" --arg cwd "$home_dir" --arg s "$EG_SID" \
            '{session_id: $s, tool_input: {command: $c}, cwd: $cwd}')
  local tmp_err
  tmp_err=$(mktemp)
  # Capture exit code without letting errexit kill the test runner, and
  # without the `|| true` trick (which replaces $? with 0).
  if HOME="$home_dir" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="$EG_SID" bash "$HOOK" <<< "$input" >/dev/null 2>"$tmp_err"; then
    HOOK_EXIT=0
  else
    HOOK_EXIT=$?
  fi
  split_stderr "$tmp_err"
  rm -f "$tmp_err"
}

# Like run_hook but also sets CLAUDE_PROJECT_DIR so the hook will scan
# project-local plan directories (.bionic/docs/plans/, docs/superpowers/plans/).
run_hook_with_project() {
  local home_dir="$1" project_dir="$2" command="$3"
  local input
  # CLAUDE_PROJECT_DIR (set below) already wins over cwd in the hook's
  # resolution, but pin cwd to the project sandbox anyway so the input is
  # hermetic and never consults the runner's real pwd.
  input=$(jq -n --arg c "$command" --arg cwd "$project_dir" --arg s "$EG_SID" \
            '{session_id: $s, tool_input: {command: $c}, cwd: $cwd}')
  local tmp_err
  tmp_err=$(mktemp)
  if HOME="$home_dir" CLAUDE_PROJECT_DIR="$project_dir" CLAUDE_CODE_SESSION_ID="$EG_SID" bash "$HOOK" <<< "$input" >/dev/null 2>"$tmp_err"; then
    HOOK_EXIT=0
  else
    HOOK_EXIT=$?
  fi
  split_stderr "$tmp_err"
  rm -f "$tmp_err"
}

expect_allow() {
  local label="$1" home_dir="$2" command="$3"
  run_hook "$home_dir" "$command"
  if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
    ok "$label"
  else
    no "$label" "expected allow, exit 0, no stderr; got exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
  fi
}

expect_block() {
  local label="$1" home_dir="$2" command="$3" expected_substr="${4:-BLOCKED}"
  run_hook "$home_dir" "$command"
  if [ "$HOOK_EXIT" -eq 2 ] && grep -q "$expected_substr" <<<"$HOOK_STDERR"; then
    ok "$label"
  else
    no "$label" "expected block exit 2 with substring '$expected_substr'; got exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
  fi
}

# Project-fixture twins of expect_allow/expect_block (run_hook_with_project instead of
# run_hook) — for cases whose subject needs a real file at a project-relative path
# (K5's 'requirements:' pointer among them), which a bare HOME sandbox cannot host.
expect_allow_p() {
  local label="$1" home_dir="$2" project_dir="$3" command="$4"
  run_hook_with_project "$home_dir" "$project_dir" "$command"
  if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
    ok "$label"
  else
    no "$label" "expected allow, exit 0, no stderr; got exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
  fi
}

expect_block_p() {
  local label="$1" home_dir="$2" project_dir="$3" command="$4" expected_substr="${5:-BLOCKED}"
  run_hook_with_project "$home_dir" "$project_dir" "$command"
  if [ "$HOOK_EXIT" -eq 2 ] && grep -q "$expected_substr" <<<"$HOOK_STDERR"; then
    ok "$label"
  else
    no "$label" "expected block exit 2 with substring '$expected_substr'; got exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
  fi
}

# Minimal valid frontmatter for fixtures whose subject is NOT the frontmatter.
# scale: wave + rigor: tested keeps the wave-lane machinery (dispatch ledger,
# rigor lanes) out of the way so each fixture isolates the behavior under test.
FM='---
governing-skill: canonical-sdlc
canonical_sdlc_version: 14
intent: build
rigor: tested
scale: wave
deploy_target: none
use_worktree: false
has_ui: false
---'

# ============================================================
# Section 1: non-commit commands always allowed
# ============================================================

section "Section 1: Non-commit commands pass through"

h1=$(make_home)
# Seed a plan that WOULD block if the command were a commit.
write_plan "$h1" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO" > /dev/null

expect_allow "ls command — not a commit" "$h1" "ls /tmp"
expect_allow "git status — not a commit" "$h1" "git status"
expect_allow "git push — not a commit" "$h1" "git push origin main"

# ============================================================
# Section 2: commit with no plans directory / no plans
# ============================================================

section "Section 2: Commit with no canonical-sdlc state — allowed"

h2=$(make_home)
# plans dir exists but empty

h2b=$(mktemp -d); cleanup_dirs+=("$h2b")
# A bare temp dir: no plan directory of any kind.
expect_allow "no plans dir at all — allow commit" "$h2b" 'git commit -m "x"'

h2c=$(make_home)
write_plan "$h2c" "# regular plan
Some content.
No SDLC State section here." > /dev/null

# ============================================================
# Section 3: valid evidence allows commit
# ============================================================

section "Section 3: Valid evidence in ## SDLC State — allowed"

h3=$(make_home)
write_plan "$h3" "$FM
# plan

## SDLC State
current: 3
Step 1: /path/to/ideate.md
Step 2: /path/to/spec.md
Step 3: .bionic/docs/plans/this.md

## Other section" > /dev/null
expect_allow "valid pointer-step evidence — allow" "$h3" 'git commit -m "step 3 done"'

h3b=$(make_home)
write_plan "$h3b" "$FM
## SDLC State
current: 8b
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 8b: critic report attached in docs/review.md" > /dev/null
expect_allow "valid step 8b evidence — allow" "$h3b" 'git commit -m "critic done"'

h3c=$(make_home)
write_plan "$h3c" "$FM
## SDLC State
current: 10
approved-by: fixture 2026-09-07T00:00Z "approved"
- Step 10: commit SHA abc123 body written" > /dev/null
expect_allow "bulleted Step line — allow" "$h3c" 'git commit -m "x"'

# ============================================================
# Section 4: malformed / missing SDLC State pieces
# ============================================================

section "Section 4: Malformed SDLC State — blocked"

h4=$(make_home)
write_plan "$h4" "$FM
## SDLC State
# no current line, no phase lines

## Next section" > /dev/null
expect_block "missing 'current: N' line" "$h4" 'git commit -m "x"' "missing a valid 'current: N'"

h4b=$(make_home)
write_plan "$h4b" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 1: done
Step 2: done
# no Step 5 line" > /dev/null
expect_block "no matching Step N line" "$h4b" 'git commit -m "x"' "no 'Step 5:' line"

h4c=$(make_home)
write_plan "$h4c" "$FM
## SDLC State
current: five
Step 5: something" > /dev/null
expect_block "non-numeric current" "$h4c" 'git commit -m "x"' "missing a valid 'current: N'"

# ============================================================
# Section 5: empty / placeholder evidence — blocked
# ============================================================

section "Section 5: Placeholder evidence — blocked"

h5=$(make_home)
write_plan "$h5" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5:   " > /dev/null
expect_block "empty evidence line" "$h5" 'git commit -m "x"' "is empty"

for token in TODO pending "in progress" XXX TBD placeholder; do
  h=$(make_home)
  write_plan "$h" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: $token" > /dev/null
  expect_block "placeholder '$token'" "$h" 'git commit -m "x"' "placeholder"
done

# Case-insensitive placeholder match. Under whole-value equality the ENTIRE
# trimmed value must equal a token, so the fixture is the bare token 'Todo'
# (was "Todo — still writing", which is prose that merely starts with the
# token — legal under the new contract; see 5e).
h5b=$(make_home)
write_plan "$h5b" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: Todo" > /dev/null
expect_block "placeholder 'Todo' (mixed case, bare token)" "$h5b" 'git commit -m "x"' "placeholder"

# --- whole-value equality: the placeholder ban matches only when the whole
# trimmed, lowercased value EQUALS a token (todo/pending/in progress/
# inprogress/xxx/tbd/placeholder). A token appearing as a substring of a
# longer value is legal evidence.

# 5c — whole-line 'Step 5: pending' (single-line value) → block.
h5c=$(make_home)
write_plan "$h5c" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: pending" > /dev/null
expect_block "whole-line 'Step 5: pending' → block" "$h5c" 'git commit -m "x"' "placeholder"

# 5d — trim + lowercase before comparison: '  Pending  ' (padded, mixed case)
# as a continuation value still equals the token → block.
h5d=$(make_home)
write_plan "$h5d" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5:
  readback:   Pending  " > /dev/null
expect_block "padded mixed-case 'readback:   Pending  ' → block" "$h5d" 'git commit -m "x"' "placeholder"

# 5e — a value that merely CONTAINS a token as a substring is legal:
# 'resolved all TODOs from the last review' (contains 'todo') → allow. Under
# the OLD substring ban this was a false block.
h5e=$(make_home)
write_plan "$h5e" "$FM
## SDLC State
current: 3
Step 3: resolved all TODOs from the last review" > /dev/null
expect_allow "substring-only 'resolved all TODOs' → allow (whole-value equality)" \
  "$h5e" 'git commit -m "x"'

# 5f — a continuation key whose whole value equals a token still blocks:
# 'stack-health: pending' (value 'pending') → block.
h5f=$(make_home)
write_plan "$h5f" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5:
  stack-health: pending" > /dev/null
expect_block "continuation 'stack-health: pending' (whole value) → block" \
  "$h5f" 'git commit -m "x"' "placeholder"

# ============================================================
# Section 6: compound commands + edge cases
# ============================================================

section "Section 6: Compound commands — commit detection"

h6=$(make_home)
write_plan "$h6" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO" > /dev/null
expect_block "cd && git commit" "$h6" 'cd /tmp && git commit -m "x"' "placeholder"
expect_block "git add && git commit" "$h6" 'git add . && git commit -m "x"' "placeholder"

# False-positive check: quoted "git commit" as prose shouldn't trigger
# gate on its own, but a real `git commit` in the same command does.
h6b=$(make_home)
write_plan "$h6b" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO" > /dev/null
expect_allow "echo only, no real commit" "$h6b" 'echo "we will git commit later"'

# ============================================================
# Section 7: newest-plan-wins
# ============================================================

section "Section 7: Newest plan file is the one enforced"
#
# THIS SECTION IS THE FALLBACK ARM, and since wave-session-bound-run that is a scope rather
# than a description of the whole rule. "Which plan answers for the run" is now a property of
# the SESSION: `session_run` reads the binding out of this session's engagement marker, and
# only a session with NO binding falls back to the newest plan — which is what every fixture
# below is, because `make_home` plants an empty marker (AC-3, and spec assumption A7: this
# pin remains true of the unbound arm and is re-scoped rather than deleted). Section 35 owns
# the bound arm, where the older of two open plans governs its own session and the newest
# governs nobody's.

h7=$(make_home)
# Older plan with valid state
write_plan "$h7" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: tests green" "old.md" > /dev/null
# Make old.md older than now.
touch -t 202001010000 "$h7/.bionic/docs/plans/old.md" 2>/dev/null || \
  touch -d "2020-01-01" "$h7/.bionic/docs/plans/old.md" 2>/dev/null || true
# Newer plan with bad state
write_plan "$h7" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO" "new.md" > /dev/null
expect_block "newest plan rules — bad state blocks even with valid older plan" \
  "$h7" 'git commit -m "x"' "placeholder"

# A marker-less newer file is SKIPPED by plan selection (landing-supervision T8):
# it no longer shields an older plan from enforcement. The bad older plan governs.
h7b=$(make_home)
write_plan "$h7b" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO" "old-bad.md" > /dev/null
touch -t 202001010000 "$h7b/.bionic/docs/plans/old-bad.md" 2>/dev/null || \
  touch -d "2020-01-01" "$h7b/.bionic/docs/plans/old-bad.md" 2>/dev/null || true
write_plan "$h7b" "# unrelated plan, no SDLC State" "new-neutral.md" > /dev/null
expect_block "marker-less newest is skipped — bad older plan still governs" \
  "$h7b" 'git commit -m "x"' "placeholder"

# Preserved ambiguity: when ONLY marker-less files exist, there is no plan to
# enforce and the commit passes silently (the ratified pass-on-ambiguity direction).
h7c=$(make_home)
write_plan "$h7c" "# unrelated plan, no SDLC State" "only-neutral.md" > /dev/null

# ============================================================
# Section 8: project-local plan directory (.bionic/docs/plans/)
# ============================================================

section "Section 8: Project-local plan dir (CLAUDE_PROJECT_DIR)"

# Helpers that exercise both plan-dir paths at once.
expect_allow_both() {
  local label="$1" home_dir="$2" project_dir="$3" command="$4"
  run_hook_with_project "$home_dir" "$project_dir" "$command"
  if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
    ok "$label"
  else
    no "$label" "expected allow; got exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
  fi
}

expect_block_both() {
  local label="$1" home_dir="$2" project_dir="$3" command="$4" substr="${5:-BLOCKED}"
  run_hook_with_project "$home_dir" "$project_dir" "$command"
  if [ "$HOOK_EXIT" -eq 2 ] && grep -q "$substr" <<<"$HOOK_STDERR"; then
    ok "$label"
  else
    no "$label" "expected block with '$substr'; got exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
  fi
}

# 8a — project-local plan alone, global empty: hook honors project plan.
h8a=$(make_home); p8a=$(make_project)
write_project_plan "$p8a" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO" > /dev/null
expect_block_both "project-local plan (bad) blocks with no global plan" \
  "$h8a" "$p8a" 'git commit -m "x"' "placeholder"

# 8b — project-local plan alone, global empty: good evidence allows.
h8b=$(make_home); p8b=$(make_project)
write_project_plan "$p8b" "$FM
## SDLC State
current: 3
Step 3: commit abc123 tests green" > /dev/null
expect_allow_both "project-local plan (good) allows with no global plan" \
  "$h8b" "$p8b" 'git commit -m "x"'

# ---- 8c..8i: the directories this gate deliberately does NOT search ----
#
# BEHAVIOR CHANGE 2026-07-28 (user ruling): `~/.claude/plans/` and
# `<project>/docs/superpowers/plans/` are out of the search set entirely —
# bionic gates bionic's plans. 8c/8d/8e/8f/8h assert the NEW contract and each
# FAILS against the pre-change hook; that is what makes them worth having.
# [WALL: hooks/canonical-sdlc-evidence-gate.sh]

# 8c — a canonical plan in the global directory with no project plan anywhere:
# NOT gated. This blocked until 2026-07-28. The harness's own plan mode owns
# that directory; what it holds is not this project's run state.
h8c=$(make_home); p8c=$(make_project)
write_global_note "$h8c" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO" "global-canonical.md" > /dev/null

# 8d — THE LIVE DEFECT. A project whose plan is correctly placed and whose
# current-step evidence is a placeholder, plus a NEWER non-canonical note in the
# global directory (plan mode drops these routinely). Selection took the newest
# .md across the whole set, so the note won, carried no `## SDLC State`, and the
# hook exited 0 — every commit in that project ran ungated. Two such files were
# sitting in the real ~/.claude/plans when this was found.
h8d=$(make_home); p8d=$(make_project)
write_project_plan "$p8d" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO" > /dev/null
touch -t 202001010000 "$p8d/.bionic/docs/plans/active.md" 2>/dev/null || \
  touch -d "2020-01-01" "$p8d/.bionic/docs/plans/active.md" 2>/dev/null || true
write_global_note "$h8d" "# scratch note from plan mode

Not a canonical-sdlc plan — no SDLC State section." "newer-note.md" > /dev/null
expect_block_both "newer non-canonical global note cannot hijack plan selection" \
  "$h8d" "$p8d" 'git commit -m "x"' "placeholder"

# 8e — the same defect with a genuinely canonical, genuinely newer global plan
# whose own evidence is fine: the project's older, bad plan is still the one
# gated. Until 2026-07-28 the global plan won and the commit was allowed.
h8e=$(make_home); p8e=$(make_project)
write_project_plan "$p8e" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO" "old-proj.md" > /dev/null
touch -t 202001010000 "$p8e/.bionic/docs/plans/old-proj.md" 2>/dev/null || \
  touch -d "2020-01-01" "$p8e/.bionic/docs/plans/old-proj.md" 2>/dev/null || true
write_global_note "$h8e" "$FM
## SDLC State
current: 3
Step 3: commit xyz green" "newer-global.md" > /dev/null
expect_block_both "newer canonical global plan cannot override the project's own" \
  "$h8e" "$p8e" 'git commit -m "x"' "placeholder"

# 8f — a project with no plan directory of its own, and a plan in the global
# directory: nothing to gate, silently. Until 2026-07-28 this "fell back" to the
# global plan and blocked.
h8f=$(make_home)
p8f=$(mktemp -d); cleanup_dirs+=("$p8f") # no .bionic/docs/plans/ inside
write_global_note "$h8f" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO" > /dev/null
expect_allow_both "no project plan dir + global plan → no fallback, allow" \
  "$h8f" "$p8f" 'git commit -m "x"'

# 8g — CLAUDE_PROJECT_DIR unset: the project resolves from the hook input's cwd
# (the sandbox HOME here), and that project's OWN docs root is what is searched.
h8g=$(make_home)
write_plan "$h8g" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO" > /dev/null
expect_block "CLAUDE_PROJECT_DIR unset: gates on the cwd project's own plan" \
  "$h8g" 'git commit -m "x"' "placeholder"

# 8h — docs/superpowers/plans/ is out too. Same vestige: the root docs/ tree was
# deleted 2026-07-16 and nothing writes canonical plans there. Until 2026-07-28
# a plan in it gated every commit in the project.
h8h=$(make_home); p8h=$(mktemp -d); cleanup_dirs+=("$p8h")
mkdir -p "$p8h/docs/superpowers/plans"
printf '%s\n## SDLC State\ncurrent: 5\napproved-by: fixture 2026-09-07T00:00Z approved\nStep 5: TODO\n' "$FM" > "$p8h/docs/superpowers/plans/active.md"
touch "$p8h/docs/superpowers/plans/active.md"
expect_allow_both "docs/superpowers/plans/ plan does NOT gate the commit" \
  "$h8h" "$p8h" 'git commit -m "x"'

# 8i — the complement of 8d, so "ignore the global directory" cannot be
# satisfied by a hook that blocks everything: a correctly-placed project plan
# with good evidence still allows, whatever the global directory holds.
h8i=$(make_home); p8i=$(make_project)
write_project_plan "$p8i" "$FM
## SDLC State
current: 3
Step 3: commit abc123 tests green" > /dev/null
write_global_note "$h8i" "$FM
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO" "newer-global.md" > /dev/null
expect_allow_both "good project plan allows regardless of the global directory" \
  "$h8i" "$p8i" 'git commit -m "x"'

# ============================================================
# Section 17: Verification Matrix gate
# ============================================================
#
# The Verify gate uses a pre-registered Verification Matrix
# stored in a top-level `## Verification Matrix` section of the plan. The
# Step-5 block keeps the tests floor (cmd/pass/total/output) and gains a
# required `auditor:` pointer; the matrix carries a per-session
# `stack-health:` line, a tier table (one row per AC), and one indented
# per-AC evidence block per non-waived row. Each row declares a tier
# (T0..T4); the hook demands that tier's evidence keys (keys_for_tier) —
# non-empty, placeholder-banned, and (on live tiers T3/T4) not self-written
# `n/a`. A `waiver:` entry exempts a row. At `current > 5` every non-waived
# row's auditor cell must read CONFIRMED. The matrix validates at current: 5
# (Step-5 validator) and as a prefix check for current: 6..9.

section "Section 17: Verification Matrix gate"

# `walk: exempt` here and in the other fixture builders below is deliberate and
# load-bearing: the walk arm (Section 26) is fail-closed, so an ABSENT key on a
# plan with a discharged row blocks. These fixtures are about matrix mechanics,
# not the walk, so they declare the exemption and keep isolating their own
# subject. The fail-closed default itself is pinned by 26e, which is the only
# fixture in the suite that leaves the key off on purpose.
matrix_frontmatter() {
  local has_ui="${1:-true}" deploy="${2:-none}" use_wt="${3:-false}"
  cat <<EOF
---
governing-skill: canonical-sdlc
canonical_sdlc_version: 14
intent: build
rigor: audited
scale: wave
deploy_target: ${deploy}
use_worktree: ${use_wt}
has_ui: ${has_ui}
walk: exempt
---
EOF
}

# Shared Step-5 block: tests floor + the required auditor pointer.
step5_base="  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/tmp/audit.md"

# Assemble a full plan: frontmatter + ## SDLC State (current + Step
# block) + a ## Verification Matrix section. $1 current, $2 Step-block
# body (indented lines), $3 full matrix section text.
plan() {
  printf '%s\n## SDLC State\ncurrent: %s\napproved-by: fixture 2026-09-07T00:00Z "approved"\nStep %s:\n%s\n\n%s\n' \
    "$(matrix_frontmatter true)" "$1" "$1" "$2" "$3"
}

# A pointer body for post-Verify steps (6..9): non-empty, non-placeholder.
step6_body="  review: .bionic/docs/plans/wave-01.plan.md#step-6-review"

# --- matrix fixtures -------------------------------------------------------

# Complete, valid matrix: T3 (all five fields), T1 (tier-run+readback),
# waived T3 row. stack-health present. All auditor cells CONFIRMED/waived.
matrix_complete="## Verification Matrix

stack-health: process restarts 0 → 0 across walk; no crash/OOM state change

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see AC-1 | CONFIRMED |
| AC-2 | T1 | discharged | see AC-2 | CONFIRMED |
| AC-3 | T3 | waived | waiver: dana 2026-07-16 env stale | waived |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: https://app.example/panel — opened the panel
  fresh: origin A rebuilt token-9f3a; origin B cdn purged
  cold-client: fresh incognito profile, no SW cache
  contact: clicked open — panel closed → open
  readback: panel.visible === true via page eval
AC-2:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh — unit suite
  readback: 332/332 asserted"

# discharged T3 row with NO matching AC evidence block (AC-1 block absent).
matrix_no_block="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see AC-1 | CONFIRMED |
| AC-2 | T1 | discharged | see AC-2 | CONFIRMED |

AC-2:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh
  readback: 332/332 asserted"

# AC-1 readback is a placeholder token.
matrix_placeholder="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: https://app.example/panel — opened the panel
  fresh: origin A rebuilt token-9f3a
  cold-client: fresh incognito profile
  contact: clicked open — panel closed → open
  readback: TBD"

# AC-1 (T3) contact is a self-written n/a with no waiver.
matrix_live_na="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: https://app.example/panel — opened the panel
  fresh: origin A rebuilt token-9f3a
  cold-client: fresh incognito profile
  contact: n/a: not reachable quickly
  readback: panel.visible === true via page eval"

# AC-1 declared T3 but carries only the suite-credit shape (tier-run +
# readback), missing fresh/cold-client/contact.
matrix_suite_credit="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: suite: hermetic-x
  readback: 12/12 asserted"

# Complete matrix but AC-1 auditor verdict is REFUTED.
matrix_refuted="## Verification Matrix

stack-health: process restarts 0 → 0 across walk; no crash/OOM state change

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see AC-1 | REFUTED |
| AC-2 | T1 | discharged | see AC-2 | CONFIRMED |
| AC-3 | T3 | waived | waiver: dana 2026-07-16 env stale | waived |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: https://app.example/panel — opened the panel
  fresh: origin A rebuilt token-9f3a; origin B cdn purged
  cold-client: fresh incognito profile, no SW cache
  contact: clicked open — panel closed → open
  readback: panel.visible === true via page eval
AC-2:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh — unit suite
  readback: 332/332 asserted"

# Complete matrix; the waived row's auditor cell is empty (legal).
matrix_waived_empty="## Verification Matrix

stack-health: process restarts 0 → 0 across walk; no crash/OOM state change

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see AC-1 | CONFIRMED |
| AC-2 | T1 | discharged | see AC-2 | CONFIRMED |
| AC-3 | T3 | waived | waiver: dana 2026-07-16 env stale |  |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: https://app.example/panel — opened the panel
  fresh: origin A rebuilt token-9f3a; origin B cdn purged
  cold-client: fresh incognito profile, no SW cache
  contact: clicked open — panel closed → open
  readback: panel.visible === true via page eval
AC-2:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh — unit suite
  readback: 332/332 asserted"

# stack-health line absent.
matrix_no_stackhealth="## Verification Matrix

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T1 | discharged | see AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh
  readback: 40/40 asserted"

# stack-health via the n/a escape.
matrix_stackhealth_na="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T1 | discharged | see AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh
  readback: 40/40 asserted"

# T0/T1/T2-only matrix — no T3 fields, no browser artifacts anywhere.
matrix_lower_tiers="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T1 | discharged | see AC-1 | CONFIRMED |
| AC-2 | T2 | discharged | see AC-2 | CONFIRMED |
| AC-3 | T0 | discharged | see AC-3 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh — unit
  readback: 40/40 asserted
AC-2:
  fails-when: the planted defect this eval must go red on
  tier-run: playwright hermetic run
  readback: rendered rows === 5
  fixture-fidelity: derived from captured prod payload 2026-07-10
AC-3:
  fails-when: the planted defect this eval must go red on
  tier-run: pnpm build && tsc
  readback: 0 type errors"

# false-green entry with no paired rewritten entry.
matrix_false_green_unpaired="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T1 | discharged | see AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh
  readback: 40/40 asserted

false-green: hermetic-x — green over broken branch"

# false-green entry WITH a paired rewritten entry.
matrix_false_green_paired="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T1 | discharged | see AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh
  readback: 40/40 asserted

false-green: hermetic-x — green over broken branch
rewritten: fixed in commit abc123, test now RED-first"

# A malformed row: a stray literal | shears an extra cell.
matrix_malformed="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see | AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: x
  fresh: x
  cold-client: x
  contact: x
  readback: x"

# --- cases -----------------------------------------------------------------

# 17a — complete matrix at current: 5 → allow.
h17a=$(make_home)
write_plan "$h17a" "$(plan 5 "$step5_base" "$matrix_complete")" > /dev/null
expect_allow "17a complete matrix (T3 + T1 + waived T3) at current 5 → allow" \
  "$h17a" 'git commit -m "x"'

# 17b — discharged row with NO AC evidence block → block, names the AC.
h17b=$(make_home)
write_plan "$h17b" "$(plan 5 "$step5_base" "$matrix_no_block")" > /dev/null
expect_block "17b discharged T3 row with no AC block → block (names AC-1)" \
  "$h17b" 'git commit -m "x"' "AC-1"

# 17c — placeholder token in an AC evidence field → block.
h17c=$(make_home)
write_plan "$h17c" "$(plan 5 "$step5_base" "$matrix_placeholder")" > /dev/null
expect_block "17c readback: TBD in AC block → block (placeholder ban)" \
  "$h17c" 'git commit -m "x"' "placeholder"

# 17c-substr — a matrix AC field VALUE that merely CONTAINS a placeholder
# token as a substring is legal; only a whole-value match blocks. readback:
# 'status pending → done ...' (contains 'pending') → allow.
matrix_substr_ok="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T1 | discharged | see AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh
  readback: status pending → done, 40/40 asserted"
h17c2=$(make_home)
write_plan "$h17c2" "$(plan 5 "$step5_base" "$matrix_substr_ok")" > /dev/null
expect_allow "17c matrix readback containing 'pending' substring → allow (whole-value equality)" \
  "$h17c2" 'git commit -m "x"'

# 17d — T3 row with self-written n/a on a field, no waiver → block, points
# at the Waiver Protocol.
h17d=$(make_home)
write_plan "$h17d" "$(plan 5 "$step5_base" "$matrix_live_na")" > /dev/null
expect_block "17d T3 contact: n/a, no waiver → block (Waiver Protocol)" \
  "$h17d" 'git commit -m "x"' "Waiver Protocol"

# 17d-case — the live-tier n/a ban must be case-insensitive: 'N/A' and
# 'N/a: <reason>' are the same self-written downgrade as lowercase 'n/a'
# (review-gate finding: a single capital letter must not defeat the ban).
# The variants are written as full literal matrices rather than derived from
# matrix_live_na via ${var/pat/rep}: a slash in the contact value forces
# an escaped slash in the pattern, and bash 3.2 leaves that backslash in the
# replacement (producing 'contact: N\/A'), so the variant is never built.
matrix_live_na_upper="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: https://app.example/panel — opened the panel
  fresh: origin A rebuilt token-9f3a
  cold-client: fresh incognito profile
  contact: N/A
  readback: panel.visible === true via page eval"
h17d2=$(make_home)
write_plan "$h17d2" "$(plan 5 "$step5_base" "$matrix_live_na_upper")" > /dev/null
expect_block "17d T3 contact: N/A (uppercase), no waiver → block" \
  "$h17d2" 'git commit -m "x"' "Waiver Protocol"

matrix_live_na_mixed="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: https://app.example/panel — opened the panel
  fresh: origin A rebuilt token-9f3a
  cold-client: fresh incognito profile
  contact: N/a: not reachable quickly
  readback: panel.visible === true via page eval"
h17d3=$(make_home)
write_plan "$h17d3" "$(plan 5 "$step5_base" "$matrix_live_na_mixed")" > /dev/null
expect_block "17d T3 contact: N/a: <reason> (mixed case), no waiver → block" \
  "$h17d3" 'git commit -m "x"' "Waiver Protocol"

# 17e — T3 row with only the suite-credit shape (missing fresh/cold-client/
# contact) → block.
h17e=$(make_home)
write_plan "$h17e" "$(plan 5 "$step5_base" "$matrix_suite_credit")" > /dev/null
expect_block "17e T3 suite-credit shape missing live-tier fields → block (fresh)" \
  "$h17e" 'git commit -m "x"' "fresh"

# 17f — current: 6, one row auditor REFUTED → block.
h17f1=$(make_home)
write_plan "$h17f1" "$(plan 6 "$step6_body" "$matrix_refuted")" > /dev/null
expect_block "17f current 6 with a REFUTED row → block (CONFIRMED required)" \
  "$h17f1" 'git commit -m "x"' "CONFIRMED"

# 17f — current: 6, all non-waived rows CONFIRMED → allow.
h17f2=$(make_home)
write_plan "$h17f2" "$(plan 6 "$step6_body" "$matrix_complete")" > /dev/null
expect_allow "17f current 6 all CONFIRMED (waived row exempt) → allow" \
  "$h17f2" 'git commit -m "x"'

# 17f — current: 6, waived row with an empty auditor cell → allow.
h17f3=$(make_home)
write_plan "$h17f3" "$(plan 6 "$step6_body" "$matrix_waived_empty")" > /dev/null
expect_allow "17f current 6 waived row with empty auditor cell → allow" \
  "$h17f3" 'git commit -m "x"'

# 17g — current: 5 with NO ## Verification Matrix section → block.
h17g=$(make_home)
write_plan "$h17g" "$(matrix_frontmatter true)
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5:
$step5_base" > /dev/null
expect_block "17g current 5 with no Verification Matrix section → block" \
  "$h17g" 'git commit -m "x"' "Verification Matrix"

# 17h — matrix missing the stack-health line → block.
h17h1=$(make_home)
write_plan "$h17h1" "$(plan 5 "$step5_base" "$matrix_no_stackhealth")" > /dev/null
expect_block "17h matrix missing stack-health → block" \
  "$h17h1" 'git commit -m "x"' "stack-health"

# 17h — stack-health via the n/a escape → allow.
h17h2=$(make_home)
write_plan "$h17h2" "$(plan 5 "$step5_base" "$matrix_stackhealth_na")" > /dev/null
expect_allow "17h stack-health: n/a with reason → allow" \
  "$h17h2" 'git commit -m "x"'

# 17i — T0/T1/T2-only matrix, no T3 fields, no browser artifacts → allow.
h17i=$(make_home)
write_plan "$h17i" "$(plan 5 "$step5_base" "$matrix_lower_tiers")" > /dev/null
expect_allow "17i lower-tier-only matrix (T0/T1/T2) → allow" \
  "$h17i" 'git commit -m "x"'

# 17j — Step-5 block missing the auditor pointer → block.
h17j1=$(make_home)
write_plan "$h17j1" "$(plan 5 "  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5" "$matrix_complete")" > /dev/null
expect_block "17j Step-5 missing auditor → block" \
  "$h17j1" 'git commit -m "x"' "auditor"

# 17j — Step-5 block missing the tests floor (cmd) → block (validator reuse).
h17j2=$(make_home)
write_plan "$h17j2" "$(plan 5 "  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/tmp/audit.md" "$matrix_complete")" > /dev/null
expect_block "17j Step-5 missing tests floor cmd → block" \
  "$h17j2" 'git commit -m "x"' "cmd"

# 17l — false-green entry with NO paired rewritten entry → block.
h17l1=$(make_home)
write_plan "$h17l1" "$(plan 5 "$step5_base" "$matrix_false_green_unpaired")" > /dev/null
expect_block "17l false-green without rewritten → block" \
  "$h17l1" 'git commit -m "x"' "rewritten"

# 17l — false-green entry WITH a paired rewritten entry → allow.
h17l2=$(make_home)
write_plan "$h17l2" "$(plan 5 "$step5_base" "$matrix_false_green_paired")" > /dev/null
expect_allow "17l false-green with paired rewritten → allow" \
  "$h17l2" 'git commit -m "x"'

# 17l — no false-green entry at all (key is optional) → allow.
h17l3=$(make_home)
write_plan "$h17l3" "$(plan 5 "$step5_base" "$matrix_lower_tiers")" > /dev/null
expect_allow "17l no false-green entry (optional key) → allow" \
  "$h17l3" 'git commit -m "x"'

# 17m — a malformed table row (stray literal | shears a cell) → block.
h17m=$(make_home)
write_plan "$h17m" "$(plan 5 "$step5_base" "$matrix_malformed")" > /dev/null
expect_block "17m malformed row (extra literal |) → block" \
  "$h17m" 'git commit -m "x"' "malformed"

# --- mid-discharge commits at the Verify gate ------------------------
#
# At current: 5 a row still being discharged (status pending/blocked) is
# exempt from its per-tier evidence keys, and the Step-5 `auditor:` pointer
# is required only once every row is discharged or waived — the full
# contract bites on the 5→6 advance (the 6..9 prefix check), mirroring the
# CONFIRMED rule. The status cell becomes load-bearing, so it gains an enum
# check (pending|blocked|discharged|waived). Rationale: without this, a
# corrective commit made mid-walk has no honest home — the observed
# workaround was editing `current:` back to 4, which silently disables the
# tests floor and misstates the step.

# Step-5 block with the tests floor but NO auditor pointer — the shape of a
# mid-walk corrective commit.
v101_step5_noauditor="  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5"

# Mixed matrix mid-walk: AC-1 discharged with full T3 evidence, AC-2 still
# pending with no AC block and an empty auditor cell.
v101_matrix_pending="## Verification Matrix

stack-health: before: process restarts 0; walk in progress

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see AC-1 | CONFIRMED |
| AC-2 | T3 | pending | see AC-2 |  |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: https://app.example/panel — opened the panel
  fresh: origin A rebuilt token-9f3a; origin B cdn purged
  cold-client: fresh incognito profile, no SW cache
  contact: clicked open — panel closed → open
  readback: panel.visible === true via page eval"

# Same shape with a blocked row (undrivable interaction, loud).
v101_matrix_blocked="${v101_matrix_pending/| AC-2 | T3 | pending | see AC-2 |  |/| AC-2 | T3 | blocked | montage panel undrivable — see AC-2 |  |}"

# Invalid status token in the status cell.
v101_matrix_bad_status="${v101_matrix_pending/| AC-2 | T3 | pending | see AC-2 |  |/| AC-2 | T3 | done | see AC-2 |  |}"

# Pending row that DOES carry a partial AC block with a live-tier n/a —
# exempt at current: 5 (the whole per-tier check is deferred, caught when
# the row flips to discharged or at the 6..9 prefix check).
v101_matrix_pending_partial="$v101_matrix_pending
AC-2:
  fails-when: the planted defect this eval must go red on
  contact: n/a: staging origin down"

# 17n — pending row, no AC block, current: 5 → allow (mid-walk commit home).
h17n1=$(make_home)
write_plan "$h17n1" "$(plan 5 "$step5_base" "$v101_matrix_pending")" > /dev/null
expect_allow "17n pending row without AC block at current 5 → allow" \
  "$h17n1" 'git commit -m "x"'

# 17n — pending row AND no auditor pointer → allow (the auditor is the
# Step-5 exit gate; it cannot have run while rows are pending).
h17n2=$(make_home)
write_plan "$h17n2" "$(plan 5 "$v101_step5_noauditor" "$v101_matrix_pending")" > /dev/null
expect_allow "17n pending row + no auditor pointer at current 5 → allow" \
  "$h17n2" 'git commit -m "x"'

# 17n — blocked row, no auditor pointer → allow (same relaxation).
h17n3=$(make_home)
write_plan "$h17n3" "$(plan 5 "$v101_step5_noauditor" "$v101_matrix_blocked")" > /dev/null
expect_allow "17n blocked row + no auditor pointer at current 5 → allow" \
  "$h17n3" 'git commit -m "x"'

# 17n — pending row with a partial block carrying a live-tier n/a → allow
# at current 5 (deferred, not licensed: it blocks at discharge/advance).
h17n4=$(make_home)
write_plan "$h17n4" "$(plan 5 "$step5_base" "$v101_matrix_pending_partial")" > /dev/null
expect_allow "17n pending row with partial block (contact: n/a) at current 5 → allow" \
  "$h17n4" 'git commit -m "x"'

# 17o — fully discharged matrix + missing auditor pointer → still block
# (17j1 pins the same shape; this pins it against the mid-discharge relaxation).
h17o1=$(make_home)
write_plan "$h17o1" "$(plan 5 "$v101_step5_noauditor" "$matrix_complete")" > /dev/null
expect_block "17o fully discharged matrix + no auditor pointer → block" \
  "$h17o1" 'git commit -m "x"' "auditor"

# 17p — invalid status token → block, names the row and the enum.
h17p1=$(make_home)
write_plan "$h17p1" "$(plan 5 "$step5_base" "$v101_matrix_bad_status")" > /dev/null
expect_block "17p invalid status 'done' at current 5 → block (enum)" \
  "$h17p1" 'git commit -m "x"' "invalid status"

h17p2=$(make_home)
write_plan "$h17p2" "$(plan 6 "$step6_body" "$v101_matrix_bad_status")" > /dev/null
expect_block "17p invalid status 'done' at current 6 → block (enum)" \
  "$h17p2" 'git commit -m "x"' "invalid status"

# 17q — the relaxation is 5-only: a pending row at current: 6 blocks (its
# per-tier keys are demanded by the prefix check).
h17q=$(make_home)
write_plan "$h17q" "$(plan 6 "$step6_body" "$v101_matrix_pending")" > /dev/null
expect_block "17q pending row at current 6 → block (relaxation is 5-only)" \
  "$h17q" 'git commit -m "x"' "AC-2"

# --- 17r: `slice: 9` rows — evidence only Step 9 can produce --------------
#
# A criterion whose only evidence is a Step-9 lifecycle artifact (the close-out
# report, continuation.md, the ADR the close-out writes) cannot be discharged
# while the plan sits at Steps 5..8: the artifact it would cite does not exist
# yet. Such a row declares `slice: 9` in its AC block — parsed like
# `provenance:`, never a sixth table cell (the 7-field row pin would refuse
# every row) — and is then exempt from TWO separate arms while current < 9:
# the per-tier evidence keys, and the CONFIRMED/auditor wall that bites at
# current > 5. At current: 9 the artifact exists and the row is ordinary.
# The tag is T0-only: every other tier names evidence that exists before Step
# 9, so `slice: 9` there is a mis-tag and blocks, naming the tier.

# T0 pending row whose AC block is the tag, beside a fully discharged T3 row
# so the rest of the matrix is valid (matrix_complete's shape, which 17f2
# pins as an allow at current: 6).
v9_matrix="## Verification Matrix

stack-health: process restarts 0 → 0 across walk; no crash/OOM state change

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see AC-1 | CONFIRMED |
| AC-2 | T0 | pending | see AC-2 |  |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: https://app.example/panel — opened the panel
  fresh: origin A rebuilt token-9f3a; origin B cdn purged
  cold-client: fresh incognito profile, no SW cache
  contact: clicked open — panel closed → open
  readback: panel.visible === true via page eval
AC-2:
  fails-when: the planted defect this eval must go red on
  provenance: spec §Close-out obligations
  slice: 9"

# The same matrix with the tag replaced by an ordinary line — the control that
# keeps every allow below non-vacuous: untagged, this row blocks at current 6.
v9_matrix_untagged="${v9_matrix/  slice: 9/  note: written at close-out}"

# The tag on a tier that has evidence before Step 9 — a mis-tag.
v9_matrix_t1="${v9_matrix/| AC-2 | T0 | pending | see AC-2 |  |/| AC-2 | T1 | pending | see AC-2 |  |}"
v9_matrix_t4="${v9_matrix/| AC-2 | T0 | pending | see AC-2 |  |/| AC-2 | T4 | pending | see AC-2 |  |}"

# The tagged row once Step 9 has run: discharged, T0 keys present, CONFIRMED.
v9_matrix_discharged="${v9_matrix/| AC-2 | T0 | pending | see AC-2 |  |/| AC-2 | T0 | discharged | see AC-2 | CONFIRMED |}"
v9_matrix_discharged="${v9_matrix_discharged/  slice: 9/  slice: 9
  tier-run: read .bionic/docs/record/wave-01/close-out.md
  readback: close-out names all 9 steps and the continuation}"

# Post-Verify step bodies for the 7 / 8 / 9 cases (the shapes their own
# validators demand — 29a and 19's integrate fixtures pin these independently).
v9_step7_body="  n/a: no architectural decision in this wave"
v9_step8_body="  merge: merged wave/bionic-1.3.2 into main
  worktree-removed: n/a
  cleanup: n/a"
v9_step9_body="  delivered: close-out report and continuation.md written"

# 17r — the exemption holds at every post-Verify step before 9 (AC-6).
h17r6=$(make_home)
write_plan "$h17r6" "$(plan 6 "$step6_body" "$v9_matrix")" > /dev/null
expect_allow "17r T0 pending row with slice: 9 at current 6 → allow" \
  "$h17r6" 'git commit -m "x"'

h17r7=$(make_home)
write_plan "$h17r7" "$(plan 7 "$v9_step7_body" "$v9_matrix")" > /dev/null
expect_allow "17r T0 pending row with slice: 9 at current 7 → allow" \
  "$h17r7" 'git commit -m "x"'

h17r8=$(make_home)
write_plan "$h17r8" "$(plan 8 "$v9_step8_body" "$v9_matrix")" > /dev/null
expect_allow "17r T0 pending row with slice: 9 at current 8 → allow" \
  "$h17r8" 'git commit -m "x"'

# 17r — control: the SAME row without the tag blocks at current 6, so the
# three allows above are the tag's doing and not the fixture's.
h17r_ctl=$(make_home)
write_plan "$h17r_ctl" "$(plan 6 "$step6_body" "$v9_matrix_untagged")" > /dev/null
expect_block "17r untagged T0 pending row at current 6 → block (control)" \
  "$h17r_ctl" 'git commit -m "x"' "AC-2"

# 17r — at current: 9 the artifact exists, so the row is ordinary and its
# pending state blocks (AC-7).
h17r9=$(make_home)
write_plan "$h17r9" "$(plan 9 "$v9_step9_body" "$v9_matrix")" > /dev/null
expect_block "17r slice: 9 row still pending at current 9 → block" \
  "$h17r9" 'git commit -m "x"' "AC-2"

# 17r — and discharging it the ordinary way at current: 9 passes, so the block
# above is the row's state and not the tag becoming poison.
h17r9d=$(make_home)
write_plan "$h17r9d" "$(plan 9 "$v9_step9_body" "$v9_matrix_discharged")" > /dev/null
expect_allow "17r slice: 9 row discharged + CONFIRMED at current 9 → allow" \
  "$h17r9d" 'git commit -m "x"'

# 17r — the tag on T1..T4 is a mis-tag: block, naming the tier (AC-8).
h17rt1=$(make_home)
write_plan "$h17rt1" "$(plan 6 "$step6_body" "$v9_matrix_t1")" > /dev/null
# Substring is the tag, not the tier: today's missing-key refusal for this row
# ALSO contains "T1", so a tier-only assertion would pass for the wrong reason.
# The current-5 case below is where "names the tier" discriminates.
expect_block "17r slice: 9 on a T1 row at current 6 → block naming the tier" \
  "$h17rt1" 'git commit -m "x"' "slice: 9"

h17rt4=$(make_home)
write_plan "$h17rt4" "$(plan 6 "$step6_body" "$v9_matrix_t4")" > /dev/null
expect_block "17r slice: 9 on a T4 row at current 6 → block naming the tier" \
  "$h17rt4" 'git commit -m "x"' "slice: 9"

# 17r — the mis-tag is a shape error, so it fires at the Verify gate too,
# where a pending row is otherwise exempt from everything.
h17rt5=$(make_home)
write_plan "$h17rt5" "$(plan 5 "$step5_base" "$v9_matrix_t1")" > /dev/null
expect_block "17r slice: 9 on a T1 row at current 5 → block naming the tier" \
  "$h17rt5" 'git commit -m "x"' "T1"
# ============================================================
# Section 18: matrix parser — section scoping + fenced-code skip
# ============================================================
#
# The matrix validator reads every parse (stack-health, false-green,
# tier-table rows, per-AC blocks) from matrix_section() — the body of the
# top-level `## Verification Matrix` section. Two properties this section
# pins:
#   (1) Row grammar applies ONLY inside that section — a leading-pipe line
#       in another section is never read as a table row.
#   (2) Inside that section, lines within ``` fenced code blocks are
#       skipped — so a jq/shell pipeline written in leading-pipe
#       continuation style does not masquerade as a malformed table row.
# Regression origin: epic-06's matrix section embeds fenced bash/jq blocks;
# a leading-pipe jq continuation line ('| select(.name == "chromium")') was
# parsed as a matrix row and blocked the commit with a bogus malformed-row
# error.

section "Section 18: matrix section scoping + fenced-code skip"

# A fenced bash block whose jq pipeline uses leading-pipe continuation lines
# — the exact shape that tripped the validator live. Single-quoted so the
# triple backticks and inner quotes stay literal (no command substitution).
v10_fence_block='```bash
playwright projects --json | jq -r '"'"'.browsers[]
       | select(.name == "chromium")
       | "\(.name)"'"'"'
```'

# (a) Valid, fully discharged matrix with a fenced pipeline appended inside
# the section (matrix is the last section, so the fence sits at EOF within
# it). RED before the fix: the '| select(...)' lines parse as malformed rows.
matrix_fence_after="$matrix_complete

$v10_fence_block"

h18a=$(make_home)
write_plan "$h18a" "$(plan 5 "$step5_base" "$matrix_fence_after")" > /dev/null
expect_allow "18a fenced jq (leading-pipe) inside matrix section at current 5 → allow" \
  "$h18a" 'git commit -m "x"'

# (b) A leading-pipe line OUTSIDE the matrix section (a later ## section),
# not fenced → allow. Pins that row grammar is scoped to the matrix section.
h18b=$(make_home)
write_plan "$h18b" "$(matrix_frontmatter true)
## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5:
$step5_base

$matrix_complete

## Notes
| this stray pipe line lives outside the matrix section
| and must never be read as a table row" > /dev/null
expect_allow "18b leading-pipe line outside the matrix section → allow" \
  "$h18b" 'git commit -m "x"'

# (c) A fenced pipeline (skipped) AND a genuinely malformed table row (a
# stray literal | shears a cell) → still block. Pins that fence-skip does
# not suppress real malformed rows.
matrix_fence_and_malformed="## Verification Matrix

stack-health: n/a: no long-running serve

$v10_fence_block

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T3 | discharged | see | AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: x
  fresh: x
  cold-client: x
  contact: x
  readback: x"

h18c=$(make_home)
write_plan "$h18c" "$(plan 5 "$step5_base" "$matrix_fence_and_malformed")" > /dev/null
expect_block "18c fenced pipeline + genuinely malformed row → block (malformed)" \
  "$h18c" 'git commit -m "x"' "malformed"

# (d) A fenced pipeline placed between stack-health and the table (mid-
# section), containing leading-pipe lines → allow. Pins that fence-skip works
# anywhere in the section, not just at the tail.
matrix_fence_before_table="## Verification Matrix

stack-health: n/a: no long-running serve

$v10_fence_block

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T1 | discharged | see AC-1 | CONFIRMED |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh
  readback: 40/40 asserted"

h18d=$(make_home)
write_plan "$h18d" "$(plan 5 "$step5_base" "$matrix_fence_before_table")" > /dev/null
expect_allow "18d fenced pipeline before the table (mid-section) → allow" \
  "$h18d" 'git commit -m "x"'

# ============================================================
# Section 15: CRLF and CR-only line endings
# ============================================================
#
# CRLF (\r\n) previously defeated the hook's exact-match awk frontmatter
# parser (`$0=="---"` never matches "---\r"), so the version marker and every
# frontmatter-keyed check were lost. The earlier fix `tr -d '\r'` then broke
# CR-only (classic-Mac) plans by deleting every line break, collapsing the file
# to ONE line so `/^## SDLC State/` never matched and the hook exited 0 as "not
# a canonical-sdlc plan" — every commit passed ungated. The parser now
# TRANSLATES \r to real newlines, so all three line-ending styles parse alike.
#
# Each style is proved BOTH ways: a valid plan must be allowed (no false block
# from a mangled parse) and a plan with a broken matrix row must be blocked on
# THAT row (proving the frontmatter and body actually parsed, rather than the
# file being waved through or rejected wholesale).

section "Section 15: CRLF and CR-only line endings"

# Inserts a literal CR before each newline. Bash-3.2-safe ANSI-C quoting embeds
# a real CR byte in the sed script itself (BSD sed's replacement text does not
# interpret the two-character "\r" as an escape).
to_crlf() {
  printf '%s' "$1" | sed $'s/$/\r/'
}

# Replaces every newline with a carriage return, so the content carries NO \n
# at all. (write_plan then appends one trailing \n; the internal line breaks
# stay pure \r — the faithful CR-only shape.)
to_cr() {
  printf '%s' "$1" | tr '\n' '\r'
}

# 15a — CRLF plan, complete Step 5 + complete matrix → allow.
h15a=$(make_home)
write_plan "$h15a" "$(to_crlf "$(plan 5 "$step5_base" "$matrix_complete")")" > /dev/null
expect_allow "CRLF plan, complete Step 5 + matrix → allow" \
  "$h15a" 'git commit -m "x"'

# 15b — CRLF plan whose matrix has a discharged row with no AC block → block on
# that row. A mangled parse would either allow, or block on the version.
h15b=$(make_home)
write_plan "$h15b" "$(to_crlf "$(plan 5 "$step5_base" "$matrix_no_block")")" > /dev/null
expect_block "CRLF plan, broken matrix row → block on AC-1 (frontmatter parsed)" \
  "$h15b" 'git commit -m "x"' "AC-1"

# 15c — CR-only plan, complete Step 5 + complete matrix → allow.
h15c=$(make_home)
write_plan "$h15c" "$(to_cr "$(plan 5 "$step5_base" "$matrix_complete")")" > /dev/null
expect_allow "CR-only plan, complete Step 5 + matrix → allow" \
  "$h15c" 'git commit -m "x"'

# 15d — CR-only plan with a broken matrix row → block on that row. Before the
# fix the whole file collapsed to one line and the commit passed ungated.
h15d=$(make_home)
write_plan "$h15d" "$(to_cr "$(plan 5 "$step5_base" "$matrix_no_block")")" > /dev/null
expect_block "CR-only plan, broken matrix row → block on AC-1 (body parsed)" \
  "$h15d" 'git commit -m "x"' "AC-1"

# ============================================================
# Section 19: triple, task ledger, merge-target
# ============================================================
#
# Governance keys off the intent × rigor × scale triple. Two shapes follow
# from `scale:`:
#   (1) Wave/epic-scale plans carry the numbered-step shape — pointer steps
#       1/2/3/4, the Verify gate at 5, document at 7, integrate=8, ship=9.
#   (2) Task-scale plans (scale: task) address a ledger TASK, not a numbered
#       step: `current: T<n>` with evidence on `- T<n>:` lines.
#
# A wave plan naming an `epic:` also gets a LOG-ONLY merge-target check at the
# integrate step. `current: T<n>` on a non-task plan still blocks — the
# T-format is scale: task only.

section "Section 19: triple, task ledger, merge-target"

# Log-only assertion helpers: exit 0 with a finding on stderr (the standard
# expect_allow requires EMPTY stderr, which a finding violates).
expect_finding() {
  local label="$1" home_dir="$2" command="$3" substr="$4"
  run_hook "$home_dir" "$command"
  if [ "$HOOK_EXIT" -eq 0 ] && grep -q "$substr" <<<"$HOOK_STDERR"; then
    ok "$label"
  else
    no "$label" "expected allow exit 0 + stderr '$substr'; got exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
  fi
}

expect_finding_both() {
  local label="$1" home_dir="$2" project_dir="$3" command="$4" substr="$5"
  run_hook_with_project "$home_dir" "$project_dir" "$command"
  if [ "$HOOK_EXIT" -eq 0 ] && grep -q "$substr" <<<"$HOOK_STDERR"; then
    ok "$label"
  else
    no "$label" "expected allow exit 0 + stderr '$substr'; got exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
  fi
}

# Asserts the durable audit file exists under the sandbox HOME and carries a
# line matching $4 — pins the D14 file channel (not just the stderr echo).
expect_audit_line() {
  local label="$1" home_dir="$2" command="$3" substr="$4"
  run_hook "$home_dir" "$command"
  # run_hook posts cwd=$home_dir with CLAUDE_PROJECT_DIR="", and the plan lives
  # in that sandbox's own docs root, which is no git repository — so
  # audit_root() falls back to PROJECT_DIR == $home_dir. Incident 0001 keys the
  # file on that root but roots the file itself under HOME.
  local af; af=$(audit_file_for "$home_dir" "$home_dir")
  if [ "$HOOK_EXIT" -eq 0 ] && [ -f "$af" ] && grep -q "$substr" "$af"; then
    ok "$label"
  else
    no "$label" "expected exit 0 + audit-file line '$substr'; got exit=$HOOK_EXIT audit='$( [ -f "$af" ] && cat "$af" )'"
  fi
}

# Frontmatter carrying the triple. $1 scale, $2 deploy, $3 use_worktree,
# $4 epic (omitted when empty).
frontmatter() {
  local scale="${1:-wave}" deploy="${2:-none}" use_wt="${3:-false}" epic="${4:-}"
  printf -- '---\n'
  printf -- 'governing-skill: canonical-sdlc\n'
  printf -- 'canonical_sdlc_version: 14\n'
  printf -- 'intent: build\n'
  printf -- 'rigor: audited\n'
  printf -- 'scale: %s\n' "$scale"
  printf -- 'deploy_target: %s\n' "$deploy"
  printf -- 'use_worktree: %s\n' "$use_wt"
  printf -- 'has_ui: false\n'
  printf -- 'walk: exempt\n'  # see matrix_frontmatter — the walk arm is fail-closed
  [ -n "$epic" ] && printf -- 'epic: %s\n' "$epic"
  printf -- '---\n'
}

# A wave plan: frontmatter + ## SDLC State (current + Step
# block) + ## Verification Matrix. Reuses the Section-17 matrix fixtures.
wave_plan() {
  printf '%s\n## SDLC State\ncurrent: %s\napproved-by: fixture 2026-09-07T00:00Z "approved"\nStep %s:\n%s\n\n%s\n' \
    "$(frontmatter wave)" "$1" "$1" "$2" "$3"
}

# A wave plan naming an epic and carrying an integration-branch line, for
# the merge-target check. $1 current, $2 step body, $3 matrix, $4 epic,
# $5 integration-branch.
wave_epic_plan() {
  printf '%s\n## SDLC State\nintegration-branch: %s\ncurrent: %s\napproved-by: fixture 2026-09-07T00:00Z "approved"\nStep %s:\n%s\n\n%s\n' \
    "$(frontmatter wave none false "$4")" "$5" "$1" "$1" "$2" "$3"
}

# A task-scale plan: frontmatter (scale: task) + the given body (a
# ## Tasks table followed by ## SDLC State).
task_plan() {
  printf '%s\n%s\n' "$(frontmatter task)" "$1"
}

# A task-scale plan at a caller-chosen frontmatter rigor (frontmatter
# hardcodes audited). $1 rigor, $2 body. Used to pin the log-only ledger-shape
# path that slice 4/3 promotes to BLOCKING only under frontmatter rigor:
# audited — a non-audited plan keeps logging findings.
task_frontmatter_rigor() {  # $1 rigor
  printf -- '---\n'
  printf -- 'governing-skill: canonical-sdlc\n'
  printf -- 'canonical_sdlc_version: 14\n'
  printf -- 'intent: build\n'
  printf -- 'rigor: %s\n' "$1"
  printf -- 'scale: task\n'
  printf -- 'deploy_target: none\n'
  printf -- 'use_worktree: false\n'
  printf -- 'has_ui: false\n'
  printf -- '---\n'
}
task_plan_rigor() {  # $1 rigor  $2 body
  printf '%s\n%s\n' "$(task_frontmatter_rigor "$1")" "$2"
}

# A complete integrate (Step 8) block that passes the shape check, so the
# merge-target log-only check can be exercised in isolation.
integrate_body="  merge: merged wave into epic/07-x
  worktree-removed: n/a
  cleanup: n/a"

# --- (2) wave/epic-scale plans: the numbered-step shape ------------------

# 19a — wave plan at Step 5 with an incomplete matrix (discharged T3 row
# with no AC block) → block.
h19a=$(make_home)
write_plan "$h19a" "$(wave_plan 5 "$step5_base" "$matrix_no_block")" > /dev/null
expect_block "19a wave plan Step 5 incomplete matrix → block" \
  "$h19a" 'git commit -m "x"' "AC-1"

# 19b — wave plan at Step 5 with a complete matrix + auditor pointer →
# allow (pointer/matrix evidence in place).
h19b=$(make_home)
write_plan "$h19b" "$(wave_plan 5 "$step5_base" "$matrix_complete")" > /dev/null
expect_allow "19b wave plan Step 5 complete matrix → allow" \
  "$h19b" 'git commit -m "x"'

# 19c — integrate is Step 8. A plan at current: 8 with a
# complete matrix but an integrate block missing merge/worktree-removed →
# block on the shape check (integrate fires at 8).
h19c=$(make_home)
write_plan "$h19c" "$(wave_plan 8 "  note: integrating now" "$matrix_complete")" > /dev/null
expect_block "19c integrate Step 8 missing merge fields → block" \
  "$h19c" 'git commit -m "x"' "merge"

# 19c2 — Step 4 is a pointer step: a pointer body allows.
h19c2=$(make_home)
write_plan "$h19c2" "$(frontmatter wave)
## SDLC State
current: 4
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 4: .bionic/docs/plans/wave.plan.md#step-4" > /dev/null
expect_allow "19c2 wave plan Step 4 pointer → allow" \
  "$h19c2" 'git commit -m "x"'

# --- (2) task-scale ledger fixtures --------------------------------------

# Valid ledger: T1 done with evidence, T2 active with evidence; current: T2.
ledger_valid="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | refactor | peer-reviewed | extract the ledger helper | active |

## SDLC State

integration-branch: main
intent: build
rigor: peer-reviewed
scale: task
current: T2

- T1: fixed in commit abc123, suite 5/5 green
- T2: bash extract-helper.sh 4 cases green, commit def456"

# 19d — valid task ledger, current: T2 accepted → allow, no finding (BLOCKING-
# grade correctness: a false block here would be a defect).
h19d=$(make_home)
write_plan "$h19d" "$(task_plan_rigor tested "$ledger_valid")" > /dev/null
expect_allow "19d task plan current: T2 valid ledger → allow (T-format accepted)" \
  "$h19d" 'git commit -m "x"'

# 19e — no ## Tasks section on a NON-audited plan → exit 0 + task-ledger finding
# (log-only). Slice 4/3 promotes this check to BLOCKING under frontmatter
# rigor: audited (pinned by 22c5); a peer-reviewed plan keeps logging.
ledger_no_tasks="## SDLC State

intent: build
rigor: peer-reviewed
scale: task
current: T2

- T2: some evidence"
h19e=$(make_home)
write_plan "$h19e" "$(task_plan_rigor peer-reviewed "$ledger_no_tasks")" > /dev/null
expect_finding "19e missing ## Tasks section (non-audited) → exit 0 + task-ledger finding" \
  "$h19e" 'git commit -m "x"' "task-ledger"

# 19e2 — the finding is written to the durable audit file with the D14 format.
h19e2=$(make_home)
write_plan "$h19e2" "$(task_plan_rigor peer-reviewed "$ledger_no_tasks")" > /dev/null
expect_audit_line "19e2 missing ## Tasks → audit file line (evidence-gate task-ledger)" \
  "$h19e2" 'git commit -m "x"' "evidence-gate task-ledger:"

# 19f — status outside the enum (doing) on a NON-audited plan → exit 0 + finding
# (log-only). Slice 4/3 blocks this under rigor: audited (pinned by 22c1).
ledger_bad_status="${ledger_valid/| T2 | refactor | peer-reviewed | extract the ledger helper | active |/| T2 | refactor | peer-reviewed | extract the ledger helper | doing |}"
h19f=$(make_home)
write_plan "$h19f" "$(task_plan_rigor tested "$ledger_bad_status")" > /dev/null
expect_finding "19f invalid status 'doing' (non-audited) → exit 0 + task-ledger finding" \
  "$h19f" 'git commit -m "x"' "task-ledger"

# 19g — the ADDRESSED active task (T2, current: T2) with no `- T2:` evidence
# line → BLOCK. Slice 4/1 made the addressed-unit tested floor blocking; this
# case previously logged a finding (see Section 22 for the full lane coverage).
ledger_active_no_line="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | refactor | peer-reviewed | extract the ledger helper | active |

## SDLC State

scale: task
current: T2

- T1: fixed in commit abc123, suite 5/5 green"
h19g=$(make_home)
write_plan "$h19g" "$(task_plan_rigor tested "$ledger_active_no_line")" > /dev/null
expect_block "19g addressed active task without evidence line → block" \
  "$h19g" 'git commit -m "x"' "evidence line"

# 19h — the ADDRESSED active task (T2) with a placeholder evidence value
# (`- T2: TBD`) → BLOCK (slice 4/1 blocking floor; previously a finding).
ledger_active_placeholder="${ledger_valid/- T2: bash extract-helper.sh 4 cases green, commit def456/- T2: TBD}"
h19h=$(make_home)
write_plan "$h19h" "$(task_plan_rigor tested "$ledger_active_placeholder")" > /dev/null
expect_block "19h addressed active task placeholder evidence → block" \
  "$h19h" 'git commit -m "x"' "placeholder"

# 19i — done non-addressed task (T1) with an empty evidence line (`- T1:`) on a
# NON-audited plan → finding (log-only). Slice 4/3 blocks this under rigor:
# audited (pinned by 22c3).
ledger_done_empty="${ledger_valid/- T1: fixed in commit abc123, suite 5\/5 green/- T1:}"
h19i=$(make_home)
write_plan "$h19i" "$(task_plan_rigor peer-reviewed "$ledger_done_empty")" > /dev/null
expect_finding "19i done task missing evidence (non-audited) → exit 0 + task-ledger finding" \
  "$h19i" 'git commit -m "x"' "task-ledger"

# --- (2) task-scale CRLF -------------------------------------------------

# 19j — a valid task ledger with CRLF line endings → exit 0, no false finding
# (every parse path — frontmatter scale, current, ## Tasks, evidence lines —
# strips \r).
h19j=$(make_home)
write_plan "$h19j" "$(to_crlf "$(task_plan_rigor tested "$ledger_valid")")" > /dev/null
expect_allow "19j CRLF task ledger → allow, no false finding" \
  "$h19j" 'git commit -m "x"'

# 19j-cr — the same paths under CR-only (classic-Mac) line endings. Two
# assertions pin both directions of the normalization fix on the task path
# (frontmatter scale, current: T<n>, ## Tasks table, evidence lines):
#
# 19j-cr1 — a bad-status ledger under CR-only → exit 0 + task-ledger finding.
# Before the fix the file collapsed to one line, scale/## Tasks were never
# parsed → no finding at all (RED). After the fix the ledger validates and
# the bad status is caught.
h19jcr1=$(make_home)
write_plan "$h19jcr1" "$(to_cr "$(task_plan_rigor tested "$ledger_bad_status")")" > /dev/null
expect_finding "19j-cr1 CR-only bad-status ledger (non-audited) → exit 0 + task-ledger finding" \
  "$h19jcr1" 'git commit -m "x"' "task-ledger"

# 19j-cr2 — a valid ledger under CR-only → allow, no false finding (guard
# against over-flagging once CR-only parses correctly).
h19jcr2=$(make_home)
write_plan "$h19jcr2" "$(to_cr "$(task_plan_rigor tested "$ledger_valid")")" > /dev/null
expect_allow "19j-cr2 CR-only valid task ledger → allow, no false finding" \
  "$h19jcr2" 'git commit -m "x"'

# --- (4) epic merge-target consistency (log-only) ------------------------

# Build a project with an epic plan declaring integration-branch: epic/07-x.
make_epic_project() {
  local branch="$1"
  local proj
  proj=$(make_project)
  mkdir -p "$proj/.bionic/docs/plans/epic-fix"
  printf -- '---\ncanonical_sdlc_version: 14\nintent: build\nrigor: audited\nscale: epic\n---\n## SDLC State\nintegration-branch: %s\ncurrent: 1\n' \
    "$branch" > "$proj/.bionic/docs/plans/epic-fix/epic.plan.md"
  touch -t 202001010000 "$proj/.bionic/docs/plans/epic-fix/epic.plan.md" 2>/dev/null || \
    touch -d "2020-01-01" "$proj/.bionic/docs/plans/epic-fix/epic.plan.md" 2>/dev/null || true
  echo "$proj"
}

# 19k — plan integration-branch (main) mismatches the epic's (epic/07-x) at
# the integrate step → exit 0 + merge-target finding.
h19k=$(make_home); p19k=$(make_epic_project "epic/07-x")
write_project_plan "$p19k" \
  "$(wave_epic_plan 8 "$integrate_body" "$matrix_complete" epic-fix main)" \
  "wave-newest.plan.md" > /dev/null
expect_finding_both "19k merge-target mismatch → exit 0 + merge-target finding" \
  "$h19k" "$p19k" 'git commit -m "x"' "merge-target"

# 19l — matching integration-branch → no finding (silent allow).
h19l=$(make_home); p19l=$(make_epic_project "epic/07-x")
write_project_plan "$p19l" \
  "$(wave_epic_plan 8 "$integrate_body" "$matrix_complete" epic-fix "epic/07-x")" \
  "wave-newest.plan.md" > /dev/null
expect_allow_both "19l merge-target match → allow, no finding" \
  "$h19l" "$p19l" 'git commit -m "x"'

# --- (5) T-format is scale: task only ------------------------------------

# `current: T2` on a WAVE-scale plan is not a valid step pointer: the T-format
# belongs to the task-scale ledger. It falls through to the numeric check and
# blocks.
h19m=$(make_home)
write_plan "$h19m" "$(frontmatter wave)
## SDLC State
current: T2
Step 5: whatever" > /dev/null
expect_block "19m wave-scale plan with current: T2 → block (T-format is scale: task only)" \
  "$h19m" 'git commit -m "x"' "valid"

# --- fence-aware SDLC-State extraction (blocking-grade correctness) -------

# A fenced ``` example containing a `## SDLC State` heading + `current: T2`
# line — the D12 task-scale schema as it appears in a plan's PROSE. Single-
# quoted so the triple backticks stay literal (no command substitution).
v11_fenced_sdlcstate_shadow='```
## SDLC State
current: T2

- T1: <evidence>
- T2: <evidence>
```'

# 19o — the SDLC-State extraction must be fence-aware, like matrix_section.
# A plan whose body documents the task-scale schema in a fenced block
# BEFORE the real section must validate against the REAL `## SDLC State`
# (current: 5 + complete matrix), not the shadowed `current: T2`. Before the
# fix the fence-blind awk captured the fenced `current: T2` first →
# CURRENT=T2 → non-numeric → false block. Same defect class the matrix parser
# fixed (fence-blind row parsing). This fix removes false blocks, adds none.
h19o=$(make_home)
write_plan "$h19o" "$(matrix_frontmatter true)

Doc note — the task-scale ledger schema (D12) looks like:

$v11_fenced_sdlcstate_shadow

## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5:
$step5_base

$matrix_complete" > /dev/null
expect_allow "19o fenced ## SDLC State shadow before real section → validates real section (allow)" \
  "$h19o" 'git commit -m "x"'

# 19p — the `## Tasks` extraction is fence-aware from the start: a fenced ```
# example carrying a bogus-status row before the REAL ## Tasks table must not
# raise a false task-ledger finding (the real ledger is valid). Fence-blind,
# both tables' rows would be read and the T9 `doing` row would log a finding.
v11_fenced_tasks_shadow='```
## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T9 | bugfix | tested | example row | doing |
```'
h19p=$(make_home)
write_plan "$h19p" "$(task_frontmatter_rigor tested)

Example ledger:

$v11_fenced_tasks_shadow

$ledger_valid" > /dev/null
expect_allow "19p fenced ## Tasks example before real table → no false finding (fence-aware)" \
  "$h19p" 'git commit -m "x"'

# 19q — a doc file whose ONLY `## SDLC State` occurrence is inside a fenced
# ``` example (no real section) must pass through as NON-CANONICAL (exit 0),
# not be parsed and false-blocked on the now-empty extraction. The presence
# check must be fence-aware too, matching the extraction: a fenced heading is
# documentation, not state. Decision recorded in the plan's ## Assumptions.
v11_fenced_only_sdlcstate="# Some skill doc

Here is how a canonical-sdlc plan records its state:

$v11_fenced_sdlcstate_shadow

That is the schema — this file itself is not a plan and carries no real
SDLC-State section of its own."
h19q=$(make_home)
write_plan "$h19q" "$v11_fenced_only_sdlcstate" > /dev/null

# --- fence-aware epic-plan read in merge-target (review fix) --------------

# An epic project whose epic.plan.md documents a `## SDLC State` example in a
# fenced ``` block (bogus integration-branch: fenced-decoy) BEFORE its real
# section (integration-branch: $1). Fence-blind, the cross-file read picks the
# decoy (head -1) and mis-reports the merge target.
make_epic_project_fenced() {
  local branch="$1" proj
  proj=$(make_project)
  mkdir -p "$proj/.bionic/docs/plans/epic-fix"
  cat > "$proj/.bionic/docs/plans/epic-fix/epic.plan.md" <<EOF
---
canonical_sdlc_version: 14
intent: build
rigor: audited
scale: epic
---
# Epic plan

The epic's state block looks like this:

\`\`\`
## SDLC State
integration-branch: fenced-decoy
current: 1
\`\`\`

## SDLC State
integration-branch: ${branch}
current: 1
EOF
  touch -t 202001010000 "$proj/.bionic/docs/plans/epic-fix/epic.plan.md" 2>/dev/null || \
    touch -d "2020-01-01" "$proj/.bionic/docs/plans/epic-fix/epic.plan.md" 2>/dev/null || true
  echo "$proj"
}

# 19r — the merge-target epic-plan read must be fence-aware, like every other
# SDLC-State extraction this wave. The wave plan's integration-branch matches
# the epic's REAL value (epic/07-x); the fenced decoy (fenced-decoy) must be
# ignored → silent (no finding). Before the fix the fence-blind awk read the
# decoy first (head -1) → mismatch → spurious merge-target finding. Log-only
# blast radius, but the exact defect class this wave eliminated everywhere else.
h19r=$(make_home); p19r=$(make_epic_project_fenced "epic/07-x")
write_project_plan "$p19r" \
  "$(wave_epic_plan 8 "$integrate_body" "$matrix_complete" epic-fix "epic/07-x")" \
  "wave-newest.plan.md" > /dev/null
expect_allow_both "19r fenced ## SDLC State in epic plan → merge-target reads real section (silent)" \
  "$h19r" "$p19r" 'git commit -m "x"'

# ============================================================
# Section 20: intent-scoped Step-5 evidence keys (R7, log-only)
# ============================================================
#
# Plans declare an `intent:` in frontmatter. Two intents carry a
# conditional Step-5 evidence key set, checked LOG-ONLY (D14) at the Verify
# gate — never blocks:
#   - refactor: requires `behavior-preservation:` (non-empty); `compat-matrix:`
#     and `revert-plan:` are optional but must not be present-and-empty.
#   - tune: requires `baseline:`, `target:`, `re-measure:` (all non-empty).
# Any other intent (e.g. build) gets no check at all — this is intent-scoped,
# not a universal Step-5 key like bundle-fresh/drive-check/stack-health. A
# — no audit write, no finding.

section "Section 20: intent-scoped Step-5 evidence keys (R7, log-only)"

# Counts occurrences of $substr in stderr — for asserting an exact finding
# count (e.g. the tune intent's three missing keys).
expect_finding_count() {
  local label="$1" home_dir="$2" command="$3" substr="$4" expected="$5"
  run_hook "$home_dir" "$command"
  local count
  count=$(grep -c "$substr" <<<"$HOOK_STDERR") || count=0
  if [ "$HOOK_EXIT" -eq 0 ] && [ "$count" -eq "$expected" ]; then
    ok "$label"
  else
    no "$label" "expected allow exit 0 + ${expected}x '$substr'; got exit=$HOOK_EXIT count=$count stderr='$HOOK_STDERR'"
  fi
}


# Frontmatter with a caller-chosen intent (Section 19's frontmatter
# hardcodes intent: build). $1 intent, $2 scale (default wave).
r7_frontmatter() {
  local intent="$1" scale="${2:-wave}"
  printf -- '---\n'
  printf -- 'governing-skill: canonical-sdlc\n'
  printf -- 'canonical_sdlc_version: 14\n'
  printf -- 'intent: %s\n' "$intent"
  printf -- 'rigor: audited\n'
  printf -- 'scale: %s\n' "$scale"
  printf -- 'deploy_target: none\n'
  printf -- 'use_worktree: false\n'
  printf -- 'has_ui: false\n'
  printf -- 'walk: exempt\n'  # see matrix_frontmatter — the walk arm is fail-closed
  printf -- '---\n'
}

# A wave plan with the given intent, at the given current/Step-5 body/
# matrix. $1 intent, $2 current, $3 Step-block body, $4 matrix.
r7_wave_plan() {
  printf '%s\n## SDLC State\ncurrent: %s\napproved-by: fixture 2026-09-07T00:00Z "approved"\nStep %s:\n%s\n\n%s\n' \
    "$(r7_frontmatter "$1")" "$2" "$2" "$3" "$4"
}

# Refactor Step-5 body with behavior-preservation already satisfied — the
# base for the compat-matrix/revert-plan sub-cases (20c), which isolate
# that one axis by keeping behavior-preservation clean.
r7_refactor_body_ok="$step5_base
  behavior-preservation: suites 211/211 pre @abc, 211/211 post @def"

# --- 20a/20b: refactor — behavior-preservation required ------------------

# 20a — refactor plan, valid tests floor + matrix, NO behavior-preservation
# key → exit 0 + refactor-evidence finding on stderr AND in the audit file.
h20a=$(make_home)
write_plan "$h20a" "$(r7_wave_plan refactor 5 "$step5_base" "$matrix_complete")" > /dev/null
expect_finding "20a refactor plan missing behavior-preservation → finding" \
  "$h20a" 'git commit -m "x"' "canonical-sdlc \[refactor-evidence\]"
h20a2=$(make_home)
write_plan "$h20a2" "$(r7_wave_plan refactor 5 "$step5_base" "$matrix_complete")" > /dev/null
expect_audit_line "20a2 refactor plan missing behavior-preservation → audit file line" \
  "$h20a2" 'git commit -m "x"' "evidence-gate refactor-evidence:"

# 20b — same plan + behavior-preservation present → exit 0, NO finding.
h20b=$(make_home)
write_plan "$h20b" "$(r7_wave_plan refactor 5 "$r7_refactor_body_ok" "$matrix_complete")" > /dev/null
expect_allow "20b refactor plan with behavior-preservation → allow, no finding" \
  "$h20b" 'git commit -m "x"'

# --- 20c: refactor — compat-matrix/revert-plan optional-but-not-empty ----

# 20c1 — compat-matrix present but empty → refactor-evidence finding.
h20c1=$(make_home)
write_plan "$h20c1" "$(r7_wave_plan refactor 5 "$r7_refactor_body_ok
  compat-matrix:" "$matrix_complete")" > /dev/null
expect_finding "20c1 refactor compat-matrix present but empty → finding" \
  "$h20c1" 'git commit -m "x"' "compat-matrix"

# 20c2 — compat-matrix: n/a: not a migration (non-empty) → clean.
h20c2=$(make_home)
write_plan "$h20c2" "$(r7_wave_plan refactor 5 "$r7_refactor_body_ok
  compat-matrix: n/a: not a migration" "$matrix_complete")" > /dev/null
expect_allow "20c2 refactor compat-matrix non-empty n/a → allow, no finding" \
  "$h20c2" 'git commit -m "x"'

# 20c3 — compat-matrix/revert-plan entirely absent → clean (they are
# optional; only presence-and-empty is a finding).
h20c3=$(make_home)
write_plan "$h20c3" "$(r7_wave_plan refactor 5 "$r7_refactor_body_ok" "$matrix_complete")" > /dev/null
expect_allow "20c3 refactor compat-matrix/revert-plan absent → allow, no finding" \
  "$h20c3" 'git commit -m "x"'

# --- 20d: tune — baseline/target/re-measure all required ------------------

# 20d1 — tune plan missing all three keys → exactly THREE tune-evidence
# findings (assert count, not just "at least one").
h20d1=$(make_home)
write_plan "$h20d1" "$(r7_wave_plan tune 5 "$step5_base" "$matrix_complete")" > /dev/null
expect_finding_count "20d1 tune plan missing baseline/target/re-measure → 3 findings" \
  "$h20d1" 'git commit -m "x"' "tune-evidence" 3

# 20d2 — tune plan with all three non-empty → clean.
r7_tune_body_ok="$step5_base
  baseline: p95 340ms @abc
  target: p95 <= 200ms
  re-measure: p95 190ms @def"
h20d2=$(make_home)
write_plan "$h20d2" "$(r7_wave_plan tune 5 "$r7_tune_body_ok" "$matrix_complete")" > /dev/null
expect_allow "20d2 tune plan with baseline/target/re-measure → allow, no finding" \
  "$h20d2" 'git commit -m "x"'

# --- 20e: build — intent-scoped, not universal ----------------------------

# 20e — build intent with none of the refactor/tune keys → NO finding (these
# checks are intent-scoped; build never triggers them).
h20e=$(make_home)
write_plan "$h20e" "$(r7_wave_plan build 5 "$step5_base" "$matrix_complete")" > /dev/null
expect_allow "20e build plan with no intent-scoped keys → allow, no finding" \
  "$h20e" 'git commit -m "x"'

# --- 20g/20h: R7 keys are truly log-only (critic Issue 1) ------------------
#
# The universal placeholder ban (the whole-Step-block scan a few hundred
# lines up) used to scan these six intent-scoped keys too, so a
# placeholder R7 value BLOCKED the commit — contradicting the ratified
# log-only contract. R7 keys are exempted from that ban
# (version-gated: v≤10 plans still block on a stray placeholder R7-named
# line — see 20i); validate_intent_evidence itself now treats a placeholder
# value the same as missing/empty, so the finding still fires.

# 20g — refactor plan, behavior-preservation: TODO (placeholder value, not
# missing) → exit 0 + refactor-evidence finding + audit line (was BLOCKED).
h20g=$(make_home)
write_plan "$h20g" "$(r7_wave_plan refactor 5 "$step5_base
  behavior-preservation: TODO" "$matrix_complete")" > /dev/null
expect_finding "20g refactor behavior-preservation: TODO → allow + refactor-evidence finding" \
  "$h20g" 'git commit -m "x"' "canonical-sdlc \[refactor-evidence\]"
h20g2=$(make_home)
write_plan "$h20g2" "$(r7_wave_plan refactor 5 "$step5_base
  behavior-preservation: TODO" "$matrix_complete")" > /dev/null
expect_audit_line "20g2 refactor behavior-preservation: TODO → audit file line" \
  "$h20g2" 'git commit -m "x"' "evidence-gate refactor-evidence:"

# 20h — tune plan, baseline: tbd (placeholder), target/re-measure valid →
# exit 0 + exactly ONE tune-evidence finding (not three — the other two
# keys are present and non-placeholder).
h20h=$(make_home)
write_plan "$h20h" "$(r7_wave_plan tune 5 "$step5_base
  baseline: tbd
  target: p95 <= 200ms
  re-measure: p95 190ms @def" "$matrix_complete")" > /dev/null
expect_finding_count "20h tune baseline: tbd (rest valid) → exactly 1 tune-evidence finding" \
  "$h20h" 'git commit -m "x"' "tune-evidence" 1

# ============================================================
# Section 21: audit dir follows the plan's project (strategy alignment)
# ============================================================
#
# log_finding's audit_dir now walks up from $PLAN's own directory to the
# nearest ancestor containing .bionic/, matching the governing-skill hook's
# find_project_root_from_path strategy — findings live with the project that
# owns the artifact. PROJECT_DIR is the fallback only.
#
# NOTE (pinning, not RED — see plan ## Assumptions): plan discovery is
# rooted at PROJECT_DIR (PLAN_DIRS is built from $PROJECT_DIR's docs root
# alone), so in every case constructible through the hook's real
# discovery paths, walk-up resolves to the SAME directory PROJECT_DIR already
# names. Both cases below pass identically before and after the refactor;
# they pin the new code path (and its fallback) rather than catch a bug.

section "Section 21: audit dir follows the plan's project (strategy alignment)"

# Like run_hook_with_project, but pins CLAUDE_PROJECT_DIR to $2 (the fixture
# project that owns the plan) while the JSON cwd field AND the actual
# invoking shell's cwd are $3 (an unrelated sibling dir) — proving
# log_finding follows the plan's own project via walk-up, never whatever
# directory happened to invoke the hook.
run_hook_project_elsewhere_cwd() {
  local home_dir="$1" project_dir="$2" elsewhere_dir="$3" command="$4"
  local input
  input=$(jq -n --arg c "$command" --arg cwd "$elsewhere_dir" --arg s "$EG_SID" \
            '{session_id: $s, tool_input: {command: $c}, cwd: $cwd}')
  local tmp_err
  tmp_err=$(mktemp)
  if (cd "$elsewhere_dir" && HOME="$home_dir" CLAUDE_PROJECT_DIR="$project_dir" CLAUDE_CODE_SESSION_ID="$EG_SID" bash "$HOOK" <<< "$input" >/dev/null 2>"$tmp_err"); then
    HOOK_EXIT=0
  else
    HOOK_EXIT=$?
  fi
  split_stderr "$tmp_err"
  rm -f "$tmp_err"
}

# 21a — fixture project owns the plan; the JSON cwd field and the actual
# process cwd both point at an unrelated sibling temp dir. Asserts the audit
# line lands in the audit file KEYED ON the fixture project (incident 0001:
# under the sandbox HOME, slugged by the fixture root — never inside the
# project tree), and that NO .bionic/ gets created under the sibling (no cwd
# leak). The "nothing under the fixture tree" arm is paired with the presence
# arm on purpose: alone it would pass if the hook wrote nothing at all.
h21a=$(make_home)
fixture21a=$(make_project)
elsewhere21a=$(mktemp -d); cleanup_dirs+=("$elsewhere21a")
write_project_plan "$fixture21a" "$(r7_wave_plan tune 5 "$step5_base" "$matrix_complete")" > /dev/null
run_hook_project_elsewhere_cwd "$h21a" "$fixture21a" "$elsewhere21a" 'git commit -m "x"'
fixture_audit=$(audit_file_for "$h21a" "$fixture21a")
in_tree21a=$(find "$fixture21a" "$elsewhere21a" -name 'sdlc-audit.md' 2>/dev/null)
if [ "$HOOK_EXIT" -eq 0 ] && [ -f "$fixture_audit" ] && grep -q "tune-evidence" "$fixture_audit" \
  && [ ! -d "$elsewhere21a/.bionic" ] && [ -z "$in_tree21a" ]; then
  ok "21a audit line follows the plan's fixture project, not the invoking cwd"
else
  no "21a" "expected fixture-keyed audit line under HOME + no audit file in any project tree; exit=$HOOK_EXIT fixture_audit_exists=$([ -f "$fixture_audit" ] && echo yes || echo no) elsewhere_bionic=$([ -d "$elsewhere21a/.bionic" ] && echo yes || echo no) in_tree='$in_tree21a'"
fi

# 21b — fail-open fallback: the sandbox-HOME fixture (Section 19/20's usual
# one) is not a git repository, so resolve_project_root cannot compute a root
# from the plan and falls back to $PROJECT_DIR (== $h21b here, via the cwd
# field) — hook still exits 0 and still writes the audit line, unblocked.
h21b=$(make_home)
write_plan "$h21b" "$(r7_wave_plan tune 5 "$step5_base" "$matrix_complete")" > /dev/null
expect_audit_line "21b fail-open: no .bionic ancestor above the plan → PROJECT_DIR fallback used" \
  "$h21b" 'git commit -m "x"' "tune-evidence"

# ============================================================
# Section 21c: AC-10 — the audit root is COMPUTED, never discovered
# ============================================================
#
# audit_root now delegates to resolve_project_root, which computes the root
# from `git rev-parse --path-format=absolute --git-common-dir` instead of
# walking the plan's ancestors for an existing `.bionic/`. Consequences:
# a project whose `.bionic/` has never existed still resolves, and every
# linked worktree of one repo answers with the parent repo — one repo, one
# audit file, instead of one per worktree.
#
# Fixture fidelity: real `git init` repos and a real `git worktree add` on
# disk. The behaviour under test is git's own path-format handling, which a
# stubbed `git` cannot reproduce.

echo ""
# 21c-e2e — the CALL SITE, driven through the hook's real stdin contract, from
# INSIDE a linked worktree. The plan lives where the governing-skill hook
# demands it live — the MAIN repo's docs root — and the worktree carries a
# newer decoy plan in its own .bionic/docs/plans/. Three arms, asserted
# together:
#   - the decoy is NOT selected (it would block on a placeholder), so
#     PROJECT_DIR/DOCS_ROOT resolved to the main repo, not the worktree;
#   - the finding lands in the audit file keyed on the main repo;
#   - no audit file keyed on the worktree exists.
# The absence arm alone would pass if the hook had written nothing at all.
#
# Step-6 finding C2/S1 rewrote this case's fixture. It used to put the real
# plan INSIDE the worktree's own .bionic/ — a placement the governing-skill
# hook blocks, so the two hooks disagreed about the same repo and no artifact
# location satisfied both. This shape is the reachable one.
ac10_tmp=$(cd "$(mktemp -d)" && pwd -P); cleanup_dirs+=("$ac10_tmp")
ac10_main="$ac10_tmp/main"
mkdir -p "$ac10_main/.bionic/docs/plans" "$ac10_main/deep/sub/dir"
git -C "$ac10_main" init -q .
git -C "$ac10_main" commit -q --allow-empty -m init
git -C "$ac10_main" worktree add -q "$ac10_tmp/wt" -b ac10-wt
ac10_wt="$ac10_tmp/wt"
# ENGAGED, on the MAIN repo: every linked worktree of one repo resolves to one root, so
# that is the one root the engagement marker can live under and the one this gate reads.
engage "$ac10_main"
mkdir -p "$ac10_wt/.bionic/docs/plans"
h21c=$(make_home)
printf '%s\n' "$(r7_wave_plan tune 5 "$step5_base" "$matrix_complete")" \
  > "$ac10_main/.bionic/docs/plans/active.md"
touch "$ac10_main/.bionic/docs/plans/active.md"
printf -- '---\ngoverning-skill: canonical-sdlc\ncanonical_sdlc_version: 14\nintent: build\nrigor: tested\nscale: wave\n---\n## SDLC State\ncurrent: 5\napproved-by: fixture 2026-09-07T00:00Z approved\nStep 5: TODO\n' \
  > "$ac10_wt/.bionic/docs/plans/decoy.md"
touch "$ac10_wt/.bionic/docs/plans/decoy.md"
run_hook_with_project "$h21c" "$ac10_wt" 'git commit -m "x"'
ac10_main_audit=$(audit_file_for "$h21c" "$ac10_main")
ac10_wt_audit=$(audit_file_for "$h21c" "$ac10_wt")
if [ "$HOOK_EXIT" -eq 0 ] && [ -f "$ac10_main_audit" ] && grep -q "tune-evidence" "$ac10_main_audit" \
   && [ ! -f "$ac10_wt_audit" ]; then
  ok "21c-e2e commit from a worktree → main repo's plan, one audit file keyed on the main repo"
else
  no "21c-e2e commit from a worktree → main repo's plan and audit file" \
    "exit=$HOOK_EXIT main_audit=$([ -f "$ac10_main_audit" ] && echo yes || echo no) wt_audit=$([ -f "$ac10_wt_audit" ] && echo yes || echo no) stderr='$HOOK_STDERR'"
fi

# ============================================================
# Section 22: rigor-keyed ledger lanes
# ============================================================
#
# Slice 4/1 makes the task-ledger tested floor BLOCKING for THE ADDRESSED
# UNIT ONLY (the T<n> named by `current: T<n>`). For that one task the gate now
# exits 2 when: its row is absent from `## Tasks`; its `- T<n>:` evidence line
# is missing or a placeholder; or its rigor cell fails `effective_row_rigor`
# (a non-empty cell outside tested|peer-reviewed|audited → INVALID). Every OTHER
# row keeps its log-only handling (D14) at this slice — 22a6 pins that scope.

section "Section 22: rigor-keyed ledger lanes"

# --- 22a: blocking tested floor on the addressed ledger unit --------------

# 22a1 — ## Tasks has no row for the addressed unit (T2) → block.
v22_no_t2_row="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |

## SDLC State

scale: task
current: T2

- T1: fixed in commit abc123, suite 5/5 green"
h22a1=$(make_home)
write_plan "$h22a1" "$(task_plan_rigor tested "$v22_no_t2_row")" > /dev/null
expect_block "22a1 addressed unit T2 has no ## Tasks row → block" \
  "$h22a1" 'git commit -m "x"' "no row"

# 22a2 — T2 row present (active) but no `- T2:` evidence line → block.
v22_t2_no_line="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: fixed in commit abc123, suite 5/5 green"
h22a2=$(make_home)
write_plan "$h22a2" "$(task_plan_rigor tested "$v22_t2_no_line")" > /dev/null
expect_block "22a2 addressed unit T2 missing evidence line → block" \
  "$h22a2" 'git commit -m "x"' "evidence line"

# 22a3 — `- T2: pending` (placeholder value) → block.
v22_t2_placeholder="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: fixed in commit abc123, suite 5/5 green
- T2: pending"
h22a3=$(make_home)
write_plan "$h22a3" "$(task_plan_rigor tested "$v22_t2_placeholder")" > /dev/null
expect_block "22a3 addressed unit T2 placeholder evidence → block" \
  "$h22a3" 'git commit -m "x"' "placeholder"

# 22a4 — honest addressed unit (row + real evidence + valid rigor) → allow.
v22_t2_valid="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: fixed in commit abc123, suite 5/5 green
- T2: fixed enum check, bash suite 12/12"
h22a4=$(make_home)
write_plan "$h22a4" "$(task_plan_rigor tested "$v22_t2_valid")" > /dev/null
expect_allow "22a4 honest addressed unit T2 → allow" \
  "$h22a4" 'git commit -m "x"'

# 22a5 — the addressed unit's rigor cell is INVALID ('rigorous') → block.
v22_t2_bad_rigor="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | bugfix | rigorous | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: fixed in commit abc123, suite 5/5 green
- T2: fixed enum check, bash suite 12/12"
h22a5=$(make_home)
write_plan "$h22a5" "$(task_plan_rigor tested "$v22_t2_bad_rigor")" > /dev/null
expect_block "22a5 addressed unit T2 invalid rigor cell → block" \
  "$h22a5" 'git commit -m "x"' "invalid rigor"

# 22a6 (regression pin) — a broken NON-addressed row (T1 done, no evidence line)
# while the addressed unit T2 is honest → NO block on a NON-audited plan. The
# non-addressed row keeps its log-only handling (this exits 0 with a task-ledger
# finding, not a block), pinning the addressed-unit-only scope of the 4/1
# blocking floor. NB: slice 4/3 makes this same NON-addressed check BLOCKING
# under frontmatter rigor: audited (pinned by 22c3), so this fixture is
# deliberately NON-audited (tested) to keep exercising the surviving log-only
# lane. Tested also keeps every cell at the floor so the 4/8 downgrade gate
# stays silent — the subject here is the missing-evidence log-only path, not a
# downgrade.
v22_nonaddressed_broken="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T2: fixed enum check, bash suite 12/12"
h22a6=$(make_home)
write_plan "$h22a6" "$(task_plan_rigor tested "$v22_nonaddressed_broken")" > /dev/null
expect_finding "22a6 broken non-addressed row (T1) + honest T2 (non-audited) → no block, log-only finding" \
  "$h22a6" 'git commit -m "x"' "task-ledger"

# --- 22b: proof-shape + auditor/critic lanes (slice 4/2) ------------------
#
# Lane scope (D-slice 4/2): the addressed row (any status) AND every OTHER
# row with status `done` are subject to — effective rigor peer-reviewed OR
# audited: evidence must be proof-shaped (is_proof_shaped); done AND rigor
# >= peer-reviewed: evidence must contain "auditor"; done AND rigor audited:
# evidence must ALSO contain "critic". The `tested` floor carries none of
# this — presence + placeholder (4/1) is its whole contract.
#
# These fixtures run at frontmatter rigor: tested (task_plan_rigor tested),
# so each heavier cell (peer-reviewed/audited) is a RAISE above the floor — the
# CELL drives the lane, and the 4/8 downgrade gate never fires (raises are always
# free). This isolates the lane behavior from the floor check. (Was
# task_plan / audited before slice 4/8, where a tested/peer-reviewed cell
# would now be a blocking downgrade and mask the lane under test.)

# 22b1 — addressed row (peer-reviewed, active) with prose evidence (no digit,
# no command token) → block (not proof-shaped).
v22b_t2_prose="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | bugfix | peer-reviewed | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: fixed in commit abc123, suite 5/5 green
- T2: implemented and verified manually"
h22b1=$(make_home)
write_plan "$h22b1" "$(task_plan_rigor tested "$v22b_t2_prose")" > /dev/null
expect_block "22b1 addressed row peer-reviewed active prose evidence → block (not proof-shaped)" \
  "$h22b1" 'git commit -m "x"' "not prose"

# 22b2 — same row, evidence is a command + counts → allow (proof-shaped).
v22b_t2_proof="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | bugfix | peer-reviewed | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: fixed in commit abc123, suite 5/5 green
- T2: bash test.sh 232/232 green"
h22b2=$(make_home)
write_plan "$h22b2" "$(task_plan_rigor tested "$v22b_t2_proof")" > /dev/null
expect_allow "22b2 addressed row peer-reviewed active proof-shaped evidence → allow" \
  "$h22b2" 'git commit -m "x"'

# 22b3 — a DONE non-addressed row (T1, peer-reviewed) with proof-shaped
# evidence but no 'auditor' token → block (done needs auditor).
v22b_t1_no_auditor="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | peer-reviewed | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: bash suite 12/12
- T2: fixed enum check, bash suite 12/12"
h22b3=$(make_home)
write_plan "$h22b3" "$(task_plan_rigor tested "$v22b_t1_no_auditor")" > /dev/null
expect_block "22b3 done row peer-reviewed proof-shaped but no auditor token → block" \
  "$h22b3" 'git commit -m "x"' "auditor"

# 22b4 — same row with an 'auditor' token in the evidence → allow.
v22b_t1_auditor="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | peer-reviewed | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: bash test.sh 12/12, auditor CONFIRMED
- T2: fixed enum check, bash suite 12/12"
h22b4=$(make_home)
write_plan "$h22b4" "$(task_plan_rigor tested "$v22b_t1_auditor")" > /dev/null
expect_allow "22b4 done row peer-reviewed with auditor token → allow" \
  "$h22b4" 'git commit -m "x"'

# 22b5 — a DONE row at audited rigor with 'auditor' but no 'critic' → block
# (audited done additionally needs critic).
v22b_t1_audited_no_critic="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | audited | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: bash test.sh 12/12 auditor CONFIRMED
- T2: fixed enum check, bash suite 12/12"
h22b5=$(make_home)
write_plan "$h22b5" "$(task_plan_rigor tested "$v22b_t1_audited_no_critic")" > /dev/null
expect_block "22b5 done row audited with auditor but no critic → block" \
  "$h22b5" 'git commit -m "x"' "critic"

# 22b6 — same row with both 'auditor' and 'critic' tokens → allow.
v22b_t1_audited_complete="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | audited | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: bash test.sh 12/12 auditor CONFIRMED, critic no-blocking
- T2: fixed enum check, bash suite 12/12"
h22b6=$(make_home)
write_plan "$h22b6" "$(task_plan_rigor tested "$v22b_t1_audited_complete")" > /dev/null
expect_allow "22b6 done row audited with auditor and critic → allow" \
  "$h22b6" 'git commit -m "x"'

# 22b7 — addressed row at the tested floor (active), plain prose evidence →
# allow (tested demands no proof-shape/auditor/critic; presence+placeholder
# from 4/1 is its whole contract).
v22b_t2_tested_prose="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: fixed in commit abc123, suite 5/5 green
- T2: reproduced and fixed the off-by-one"
h22b7=$(make_home)
write_plan "$h22b7" "$(task_plan_rigor tested "$v22b_t2_tested_prose")" > /dev/null
expect_allow "22b7 addressed row tested floor prose evidence → allow (no proof-shape demand)" \
  "$h22b7" 'git commit -m "x"'

# 22b8 — proof-shape unit pin: a command word alone (no digit) is not
# proof-shaped, and a digit alone (no command token) is not proof-shaped
# either — both halves of the AND are load-bearing.

v22b_t2_no_digit="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | bugfix | peer-reviewed | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: fixed in commit abc123, suite 5/5 green
- T2: bash test.sh all green"
h22b8a=$(make_home)
write_plan "$h22b8a" "$(task_plan_rigor tested "$v22b_t2_no_digit")" > /dev/null
expect_block "22b8a proof-shape pin: command word, no digit → block" \
  "$h22b8a" 'git commit -m "x"' "not prose"

v22b_t2_no_command="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | bugfix | peer-reviewed | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: fixed in commit abc123, suite 5/5 green
- T2: fixed 3 cases by hand"
h22b8b=$(make_home)
write_plan "$h22b8b" "$(task_plan_rigor tested "$v22b_t2_no_command")" > /dev/null
expect_block "22b8b proof-shape pin: digit, no command token → block" \
  "$h22b8b" 'git commit -m "x"' "not prose"

# --- 22c: audited plan-level strictness + wave D7 dispatch-ledger (slice 4/3) -
#
# Part A (task scale): the previously log-only NON-addressed-row ledger-shape
# checks (missing ## Tasks, bad status enum, active/done row missing/placeholder
# evidence) BLOCK under frontmatter rigor: audited and stay log-only otherwise
# (ledger_shape_fail router). Part B (wave scale): validate_dispatch_ledger
# demands a `## Tasks` dispatched-task ledger section on scale:wave +
# rigor:audited + multi_agent:true plans (absent → block; empty/none-dispatched
# → allow; rows validate at TESTED-FLOOR shape only — enum + evidence-line
# presence, NO per-row auditor/critic, plan Assumption A2). Every other plan is
# a guard no-op.

section "Section 22c: audited strictness + D7 dispatch-ledger presence"

# ---- Part A: task-scale audited plan-level strictness --------------------

# 22c1 — audited task plan, addressed T1 clean + proof-shaped, a second
# (non-addressed) row T2 with status 'wip' (bad enum) → BLOCK (audited promotes
# the enum check). Isolated: the addressed unit T1 is clean so the block is the
# enum promotion, not the addressed floor. T1's cell is `audited` (= the
# frontmatter floor) so it is not itself a 4/8 downgrade — the subject is T2's
# status promotion. T1's evidence is proof-shaped for the audited-active lane.
v22c_bad_enum="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | build | audited | do the thing | active |
| T2 | build | tested | second thing | wip |

## SDLC State

scale: task
current: T1

- T1: bash suite 12/12 green"
h22c1=$(make_home)
write_plan "$h22c1" "$(task_plan "$v22c_bad_enum")" > /dev/null
expect_block "22c1 audited task plan, non-addressed row bad status enum → block" \
  "$h22c1" 'git commit -m "x"' "invalid status"

# 22c2 — same fixture at frontmatter rigor peer-reviewed → log-only finding, NOT
# a block (the router stays log-only off audited).
h22c2=$(make_home)
write_plan "$h22c2" "$(task_plan_rigor peer-reviewed "$v22c_bad_enum")" > /dev/null
expect_finding "22c2 same fixture at peer-reviewed → finding (still log-only)" \
  "$h22c2" 'git commit -m "x"' "task-ledger"

# 22c3 — audited task plan, addressed T1 clean, non-addressed T2 status done with
# NO `- T2:` evidence line → BLOCK (audited promotes the missing-evidence check).
# T1's cell is `audited` (= the frontmatter floor) so it is not itself a 4/8
# downgrade; its evidence is proof-shaped for the audited-active lane. The
# subject is T2's promoted missing-evidence block.
v22c_done_no_ev="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | build | audited | do the thing | active |
| T2 | build | tested | second thing | done |

## SDLC State

scale: task
current: T1

- T1: bash suite 12/12 green"
h22c3=$(make_home)
write_plan "$h22c3" "$(task_plan "$v22c_done_no_ev")" > /dev/null
expect_block "22c3 audited task plan, non-addressed done row missing evidence line → block" \
  "$h22c3" 'git commit -m "x"' "no evidence"

# 22c4 — same fixture at frontmatter rigor tested → log-only finding, NOT a block.
h22c4=$(make_home)
write_plan "$h22c4" "$(task_plan_rigor tested "$v22c_done_no_ev")" > /dev/null
expect_finding "22c4 same fixture at tested → finding (still log-only)" \
  "$h22c4" 'git commit -m "x"' "task-ledger"

# ---- Part B: wave-scale D7 dispatched-task ledger presence ---------------

# A WAVE frontmatter carrying an explicit multi_agent field — the D7
# dispatch-ledger guard fires ONLY on audited + multi_agent:true + wave.
# frontmatter sets NO multi_agent, so every prior wave fixture (19a/b/c,
# 19r, Section 20) is a guaranteed guard no-op. $1 rigor (default audited),
# $2 multi_agent (default true).
d7_wave_frontmatter() {
  local rigor="${1:-audited}" multi="${2:-true}"
  printf -- '---\n'
  printf -- 'governing-skill: canonical-sdlc\n'
  printf -- 'canonical_sdlc_version: 14\n'
  printf -- 'intent: build\n'
  printf -- 'rigor: %s\n' "$rigor"
  printf -- 'scale: wave\n'
  printf -- 'deploy_target: none\n'
  printf -- 'use_worktree: false\n'
  printf -- 'has_ui: false\n'
  printf -- 'walk: exempt\n'  # see matrix_frontmatter — the walk arm is fail-closed
  printf -- 'multi_agent: %s\n' "$multi"
  printf -- '---\n'
}

# A wave plan at current: 5 reaching the dispatcher with the SAME valid
# Step-5 body + matrix as 19b (so the ONLY variable under test is the
# dispatched-task ledger; validate_dispatch_ledger runs at the top of
# dispatch_modern, before the matrix machinery). $1 = ## Tasks section text
# (empty omits it); $2 = extra ## SDLC State lines, e.g. a `- T<n>:` evidence
# line (empty omits); $3 rigor (default audited); $4 multi_agent (default true).
d7_wave_plan() {
  local tasks="$1" extra_state="$2" rigor="${3:-audited}" multi="${4:-true}"
  printf '%s\n' "$(d7_wave_frontmatter "$rigor" "$multi")"
  [ -n "$tasks" ] && printf '%s\n\n' "$tasks"
  # Both K5 (this slice) and K2 (slice 16) scope-match this fixture (rigor:audited +
  # multi_agent:true + wave, at current: 5 >= 4): K5/AC-K5.2 needs the Step-1
  # requirements: pointer (resolves to the plan file itself — project-relative; this
  # fixture's own subject is D7, not K5, so a real file is all the arm demands, not a
  # real requirements document); K2/AC-K2.4 needs approved-by: at current >= 4.
  printf '## SDLC State\ncurrent: 5\nStep 1: requirements: .bionic/docs/plans/active.md\napproved-by: fixture 2026-09-07T00:00Z approved\nStep 5:\n%s\n' "$step5_base"
  [ -n "$extra_state" ] && printf '%s\n' "$extra_state"
  printf '\n%s\n' "$matrix_complete"
}

# 22c5 — audited multi_agent wave with NO ## Tasks section → block (D7 presence).
h22c5=$(make_home)
write_plan "$h22c5" "$(d7_wave_plan "" "")" > /dev/null
expect_block "22c5 audited multi_agent wave with no ## Tasks → block (D7 presence)" \
  "$h22c5" 'git commit -m "x"' "dispatched-task ledger"

# 22c6 — WITH a ## Tasks section, header-only + a `none dispatched` line, zero
# T-rows → allow (section present suffices; the parser needs no row).
tasks_none="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|

none dispatched — the orchestrator appends one row per dispatched task-shaped unit."
h22c6=$(make_home)
write_plan "$h22c6" "$(d7_wave_plan "$tasks_none" "")" > /dev/null
expect_allow "22c6 audited multi_agent wave with none-dispatched ## Tasks → allow" \
  "$h22c6" 'git commit -m "x"'

# 22c7 — ## Tasks with one dispatched row (done) AND a matching `- T1:` evidence
# line in ## SDLC State → allow. NOTE: the line carries NO auditor/critic token
# yet it passes — tested-floor shape only at wave scale (pins Assumption A2).
tasks_one_done="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | build | audited | dispatched slice | done |"
h22c7=$(make_home)
write_plan "$h22c7" "$(d7_wave_plan "$tasks_one_done" "- T1: bash suite 9/9 green")" > /dev/null
expect_allow "22c7 audited multi_agent wave dispatched T1 + evidence line → allow (tested-floor shape, no auditor/critic)" \
  "$h22c7" 'git commit -m "x"'

# 22c8 — ## Tasks with a dispatched row (done) but NO `- T1:` evidence line
# anywhere in ## SDLC State → block.
h22c8=$(make_home)
write_plan "$h22c8" "$(d7_wave_plan "$tasks_one_done" "")" > /dev/null
expect_block "22c8 audited multi_agent wave dispatched T1 with no evidence line → block" \
  "$h22c8" 'git commit -m "x"' "evidence line"

# 22c9 — NON-audited wave (rigor peer-reviewed) with NO ## Tasks → allow (the
# guard excludes non-audited plans).
h22c9=$(make_home)
write_plan "$h22c9" "$(d7_wave_plan "" "" peer-reviewed true)" > /dev/null
expect_allow "22c9 non-audited (peer-reviewed) wave with no ## Tasks → allow (guard excludes)" \
  "$h22c9" 'git commit -m "x"'

# 22c10 — audited wave with multi_agent: false and NO ## Tasks → allow (the guard
# excludes single-agent plans).
h22c10=$(make_home)
write_plan "$h22c10" "$(d7_wave_plan "" "" audited false)" > /dev/null
expect_allow "22c10 audited wave with multi_agent:false, no ## Tasks → allow (guard excludes)" \
  "$h22c10" 'git commit -m "x"'

# 22c11 (self-reference pin) — reproduce THIS wave-05 plan's exact ## Tasks shape
# (header + `|---|` separator + blank + a `none dispatched — ...` prose line,
# zero T-rows) on an audited multi_agent wave fixture → allow. This is the shape
# the deployed NEW hook must accept when wave-05 itself advances past the pointer
# steps into the dispatcher.
tasks_selfref="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|

none dispatched — D7 ledger opens empty; the orchestrator appends one row
per dispatched task-shaped unit (slices ledger under Step-4 evidence, not
here, unless dispatched as discrete task-shaped work)."
h22c11=$(make_home)
write_plan "$h22c11" "$(d7_wave_plan "$tasks_selfref" "")" > /dev/null
expect_allow "22c11 self-reference pin — THIS plan's exact ## Tasks shape (zero T-rows) → allow" \
  "$h22c11" 'git commit -m "x"'

# ---- 22d: per-row rigor resolution (slice 4/4, R4) ------------------------
#
# effective_row_rigor resolves cell-first: a non-empty, enum-valid cell wins
# outright — it does NOT blend with, or get overridden by, the frontmatter
# rigor. Frontmatter rigor only supplies the fallback when the cell is empty
# (and 'tested' is the final fallback under an unset/invalid frontmatter
# rigor). 22d1/22d2 pin cell-wins-over-frontmatter in both directions
# (lighter cell overrides heavier frontmatter, and vice versa). 22d3/22d4 pin
# the empty-cell inheritance path. 22d5 pins that the cell alone drives the
# audited lane (auditor+critic), independent of frontmatter. 22d6 is a
# confirmation-vs-actual probe on a NON-addressed row's off-enum rigor cell —
# see its comment for the finding.

section "Section 22d: per-row rigor resolution (R4)"

# 22d1 — frontmatter rigor tested, addressed row cell peer-reviewed (heavier),
# weak prose evidence → block. The row CELL overrides the lighter frontmatter:
# proof-shape is demanded because the cell says peer-reviewed, not because of
# the (lighter) frontmatter.
v22d1_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | peer-reviewed | fix enum | active |

## SDLC State

scale: task
current: T1

- T1: fixed it manually"
h22d1=$(make_home)
write_plan "$h22d1" "$(task_plan_rigor tested "$v22d1_body")" > /dev/null
expect_block "22d1 frontmatter tested, cell peer-reviewed (heavier), prose evidence → block (cell wins)" \
  "$h22d1" 'git commit -m "x"' "not prose"

# 22d2 — frontmatter rigor audited (task_plan hardcodes it), addressed row
# cell tested (lighter than the frontmatter floor), plain honest one-line
# evidence → this is a DOWNGRADE (A15: the per-row cell is a FLOOR; a cell
# below the frontmatter rigor must be waived). WITHOUT a waiver marker on the
# `- T1:` line it BLOCKS; WITH one it runs at the (lower) tested lane, so the
# plain evidence is fine and it allows. (Was expect_allow under the pre-A15
# "cell wins freely downward" model; slice 4/8 makes downward a recorded
# decision. 22d2/22d2b are the split; 22f1/22f2 restate the same contract
# in the dedicated floor block.)
v22d2_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T1

- T1: reproduced and fixed the boundary case"
h22d2=$(make_home)
write_plan "$h22d2" "$(task_plan "$v22d2_body")" > /dev/null
expect_block "22d2 frontmatter audited, cell tested (downgrade), no waiver → block (floor)" \
  "$h22d2" 'git commit -m "x"' "lowers rigor"

# 22d2b — same fixture with a Waiver-Protocol marker on the `- T1:` line → allow.
# The recorded downgrade runs at the cell's tested lane, so the plain one-line
# evidence satisfies the (tested) contract.
v22d2b_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T1

- T1: reproduced and fixed the boundary case, waiver: dana 2026-07-19 genuine bugfix"
h22d2b=$(make_home)
write_plan "$h22d2b" "$(task_plan "$v22d2b_body")" > /dev/null
expect_allow "22d2b frontmatter audited, cell tested (downgrade), WITH waiver → allow (recorded, runs at tested lane)" \
  "$h22d2b" 'git commit -m "x"'

# 22d3 — frontmatter rigor peer-reviewed, addressed row cell EMPTY (missing
# field-4 value), weak prose evidence → block. An empty cell inherits the
# frontmatter rigor (peer-reviewed), so proof-shape is demanded.
v22d3_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix |  | fix enum | active |

## SDLC State

scale: task
current: T1

- T1: fixed it manually"
h22d3=$(make_home)
write_plan "$h22d3" "$(task_plan_rigor peer-reviewed "$v22d3_body")" > /dev/null
expect_block "22d3 frontmatter peer-reviewed, cell empty, prose evidence → block (inherits frontmatter)" \
  "$h22d3" 'git commit -m "x"' "not prose"

# 22d4 — frontmatter rigor tested, addressed row cell EMPTY, weak prose
# evidence → allow. An empty cell inherits tested, the floor.
v22d4_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix |  | fix enum | active |

## SDLC State

scale: task
current: T1

- T1: fixed it manually"
h22d4=$(make_home)
write_plan "$h22d4" "$(task_plan_rigor tested "$v22d4_body")" > /dev/null
expect_allow "22d4 frontmatter tested, cell empty, prose evidence → allow (inherits tested floor)" \
  "$h22d4" 'git commit -m "x"'

# 22d5 — frontmatter rigor tested (lighter), addressed row cell audited
# (heavier), status done: proof-shaped evidence + auditor + critic tokens →
# allow; drop the critic token (same frontmatter, same cell) → block. Pins
# that the CELL alone drives the audited lane, independent of frontmatter.
v22d5_body_complete="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | audited | fix enum | done |

## SDLC State

scale: task
current: T1

- T1: bash test.sh 12/12 auditor CONFIRMED, critic no-blocking"
h22d5a=$(make_home)
write_plan "$h22d5a" "$(task_plan_rigor tested "$v22d5_body_complete")" > /dev/null
expect_allow "22d5a frontmatter tested, cell audited, done, proof+auditor+critic → allow (cell drives lane)" \
  "$h22d5a" 'git commit -m "x"'

v22d5_body_no_critic="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | audited | fix enum | done |

## SDLC State

scale: task
current: T1

- T1: bash test.sh 12/12 auditor CONFIRMED"
h22d5b=$(make_home)
write_plan "$h22d5b" "$(task_plan_rigor tested "$v22d5_body_no_critic")" > /dev/null
expect_block "22d5b same, drop critic token → block (cell audited lane still demands it)" \
  "$h22d5b" 'git commit -m "x"' "critic"

# 22d6 — an off-enum rigor cell 'reviewed' on a NON-addressed 'done' row.
# effective_row_rigor("reviewed") resolves to the INVALID sentinel. Slice 4/4
# pinned (as expect_allow) that this evaded detection entirely: INVALID was
# only ever explicitly checked on the ADDRESSED unit's own row (4/1's
# `if [ "$eff" = "INVALID" ]` block), so the non-addressed done-row path called
# apply_rigor_lanes(id, status, "INVALID", ev) directly and its case arms —
# matching only tested|peer-reviewed|audited — fell through as a silent no-op:
# no block, and (unlike the ledger_shape_fail-routed defects) no log-only
# finding either.
#
# Slice 4/6 closes that gap: the non-addressed done-row path now guards for
# eff=INVALID BEFORE calling apply_rigor_lanes, mirroring the addressed unit's
# 4/1 INVALID block. A malformed rigor cell makes the row's lane indeterminate
# — you cannot resolve which evidence contract applies — so it is a hard
# STRUCTURAL error that blocks UNCONDITIONALLY at ANY frontmatter rigor, NOT
# routed through the audited-only ledger_shape_fail. 22d6a/b/c pin the block at
# audited / tested / peer-reviewed frontmatter respectively (proving "at any
# rigor"); 22d6d/e are controls proving ONLY the INVALID sentinel blocks — a
# valid enum cell and an empty (inherits-frontmatter) cell both still allow.
v22d6_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | reviewed | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: bash test.sh 12/12 auditor CONFIRMED, critic no-blocking
- T2: fixed enum check, bash suite 12/12"
h22d6a=$(make_home)
write_plan "$h22d6a" "$(task_plan "$v22d6_body")" > /dev/null
expect_block "22d6a frontmatter audited, non-addressed off-enum rigor cell → block (INVALID lane is a hard structural error)" \
  "$h22d6a" 'git commit -m "x"' "invalid rigor"

h22d6b=$(make_home)
write_plan "$h22d6b" "$(task_plan_rigor tested "$v22d6_body")" > /dev/null
expect_block "22d6b frontmatter tested, non-addressed off-enum rigor cell → block (blocks at any rigor, not just audited)" \
  "$h22d6b" 'git commit -m "x"' "invalid rigor"

# 22d6c — same off-enum cell, frontmatter peer-reviewed → block. Third rigor
# level, proving the INVALID guard fires UNCONDITIONALLY (a, b, c together
# cover audited / tested / peer-reviewed).
h22d6c=$(make_home)
write_plan "$h22d6c" "$(task_plan_rigor peer-reviewed "$v22d6_body")" > /dev/null
expect_block "22d6c frontmatter peer-reviewed, non-addressed off-enum rigor cell → block (blocks at any rigor)" \
  "$h22d6c" 'git commit -m "x"' "invalid rigor"

# 22d6d — negative control: a VALID enum cell (peer-reviewed) on a non-addressed
# done row, with proof-shaped + auditor evidence, frontmatter tested → allow.
# The fix targets ONLY the INVALID sentinel; a well-formed heavier cell resolves
# its lane and (evidence being proof-shaped + auditor-named) passes cleanly.
v22d6d_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | peer-reviewed | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: bash test.sh 12/12 auditor CONFIRMED
- T2: fixed enum check, bash suite 12/12"
h22d6d=$(make_home)
write_plan "$h22d6d" "$(task_plan_rigor tested "$v22d6d_body")" > /dev/null
expect_allow "22d6d control: valid peer-reviewed cell on non-addressed done row, proof+auditor evidence → allow (only INVALID blocks)" \
  "$h22d6d" 'git commit -m "x"'

# 22d6e — empty-cell control: an EMPTY rigor cell on a non-addressed done row
# inherits the frontmatter rigor (tested, the floor), with honest one-line
# evidence → allow. Empty ≠ INVALID: the empty cell resolves via inheritance,
# not the malformation sentinel, so no structural block fires.
v22d6e_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix |  | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: reproduced and fixed the boundary case
- T2: fixed enum check, bash suite 12/12"
h22d6e=$(make_home)
write_plan "$h22d6e" "$(task_plan_rigor tested "$v22d6e_body")" > /dev/null
expect_allow "22d6e control: empty rigor cell on non-addressed done row inherits tested floor, honest evidence → allow (empty ≠ INVALID)" \
  "$h22d6e" 'git commit -m "x"'

# 22d6f/g/h — slice 4/7 closes the residual left by 4/6: an off-enum rigor cell
# blocked only on the addressed unit (any status, 4/1) and on non-addressed DONE
# rows (4/6), but a non-addressed ACTIVE or PENDING row with an off-enum cell
# still passed SILENTLY — its lane was never resolved, so no block and no
# finding. The spec's semantic model bans unknown cell values as a blocking
# malformation "at any rigor" with NO status qualifier (whole-value enum
# equality, the exact idiom used for the status cell, which is validated per-row
# regardless of status). 4/7 consolidates the INVALID check into ONE per-row
# guard that runs before the status-based branching, so a malformed rigor cell
# blocks UNIFORMLY on any row (addressed or not; done, active, pending, dropped)
# at any frontmatter rigor. 22d6f (active) and 22d6g (pending) are the residuals
# this slice closes; 22d6h is a negative control proving an EMPTY cell on an
# active row still inherits and allows (empty ≠ INVALID — active rows without a
# done claim are not over-blocked).

# 22d6f — non-addressed ACTIVE row with an off-enum rigor cell 'reviewed',
# frontmatter tested, addressed unit T2 honest → block. Pre-4/7 this passed
# silently (the active branch never resolves the cell).
v22d6f_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | reviewed | fix the frontmatter parser | active |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: reworking the parser
- T2: fixed enum check, bash suite 12/12"
h22d6f=$(make_home)
write_plan "$h22d6f" "$(task_plan_rigor tested "$v22d6f_body")" > /dev/null
expect_block "22d6f frontmatter tested, non-addressed ACTIVE off-enum rigor cell → block (INVALID blocks regardless of status)" \
  "$h22d6f" 'git commit -m "x"' "invalid rigor"

# 22d6g — non-addressed PENDING row with an off-enum rigor cell, frontmatter
# peer-reviewed, addressed unit T2 honest → block. Pending rows carry no
# evidence line, so pre-4/7 the whole row was skipped and the bad cell never
# surfaced.
v22d6g_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | reviewed | fix the frontmatter parser | pending |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T2: fixed enum check, bash suite 12/12"
h22d6g=$(make_home)
write_plan "$h22d6g" "$(task_plan_rigor peer-reviewed "$v22d6g_body")" > /dev/null
expect_block "22d6g frontmatter peer-reviewed, non-addressed PENDING off-enum rigor cell → block (INVALID blocks even on a pending row)" \
  "$h22d6g" 'git commit -m "x"' "invalid rigor"

# 22d6h — negative control: non-addressed ACTIVE row with an EMPTY rigor cell,
# honest evidence, frontmatter tested → allow. The empty cell inherits the
# frontmatter (tested, the floor); empty ≠ INVALID, so the per-row guard does
# not fire and an active row without a done claim is not over-blocked.
v22d6h_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix |  | fix the frontmatter parser | active |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: reworking the parser
- T2: fixed enum check, bash suite 12/12"
h22d6h=$(make_home)
write_plan "$h22d6h" "$(task_plan_rigor tested "$v22d6h_body")" > /dev/null
expect_allow "22d6h control: empty rigor cell on non-addressed active row inherits tested floor, honest evidence → allow (empty ≠ INVALID)" \
  "$h22d6h" 'git commit -m "x"'

# ---- 22f: row rigor is a FLOOR — downgrade blocks unless waived (slice 4/8) --
#
# A15 (user-ratified, momentous): the per-row `rigor` cell is a FLOOR unified
# with the run-rigor floor model. A cell that RAISES a row above the
# frontmatter rigor is always allowed (the cell drives the heavier lane —
# 22d1/22d5 already pin this). A cell that LOWERS a row below the frontmatter
# rigor is a DOWNGRADE: it BLOCKS (exit 2) UNLESS the row's `- T<n>:` evidence
# line carries a whole-word `waiver` marker (Waiver Protocol), in which case the
# row runs at the (lower) cell lane. The gate fires exactly where the rigor
# lanes apply — the addressed unit (any status) and non-addressed `done` rows
# with real evidence — after the presence/placeholder/INVALID checks, so a
# missing/placeholder-evidence or malformed-cell block still wins. 22f7 also
# pins the F3 word-boundary fix on the critic/auditor lane tokens.

section "Section 22f: row rigor is a floor — downgrade blocks unless waived"

# 22f1 — frontmatter audited, ADDRESSED row cell tested (downgrade), real
# non-placeholder prose evidence, NO waiver → block. This is the critic's F1
# repro: under the pre-A15 model the tested cell "won" downward and this
# allowed; the floor rule flips it to a block.
v22f1_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T1

- T1: reproduced and fixed the boundary case"
h22f1=$(make_home)
write_plan "$h22f1" "$(task_plan "$v22f1_body")" > /dev/null
expect_block "22f1 audited frontmatter, addressed tested cell (downgrade), no waiver → block" \
  "$h22f1" 'git commit -m "x"' "lowers rigor"

# 22f2 — same, but the `- T1:` line carries a Waiver-Protocol marker → allow
# (recorded downgrade; runs at the tested lane so the prose evidence is fine).
v22f2_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T1

- T1: reproduced and fixed the boundary case, waiver: dana 2026-07-19 genuine bugfix"
h22f2=$(make_home)
write_plan "$h22f2" "$(task_plan "$v22f2_body")" > /dev/null
expect_allow "22f2 audited frontmatter, addressed tested cell + waiver → allow (recorded downgrade)" \
  "$h22f2" 'git commit -m "x"'

# 22f3 — frontmatter tested, addressed row cell audited (RAISE), done, evidence
# proof-shaped + auditor + critic → allow. Raising above the floor is always
# free; the cell drives the heavier (audited) lane.
v22f3_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | audited | fix enum | done |

## SDLC State

scale: task
current: T1

- T1: bash test.sh 12/12 auditor CONFIRMED, critic no-blocking"
h22f3=$(make_home)
write_plan "$h22f3" "$(task_plan_rigor tested "$v22f3_body")" > /dev/null
expect_allow "22f3 tested frontmatter, addressed audited cell (raise), proof+auditor+critic → allow" \
  "$h22f3" 'git commit -m "x"'

# 22f4 — frontmatter peer-reviewed, addressed row cell tested (downgrade). No
# waiver → block; with waiver → allow (runs at the tested lane).
v22f4_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T1

- T1: fixed it by hand"
h22f4a=$(make_home)
write_plan "$h22f4a" "$(task_plan_rigor peer-reviewed "$v22f4_body")" > /dev/null
expect_block "22f4a peer-reviewed frontmatter, addressed tested cell (downgrade), no waiver → block" \
  "$h22f4a" 'git commit -m "x"' "lowers rigor"

v22f4b_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T1

- T1: fixed it by hand, waiver: dana 2026-07-19 quick bugfix"
h22f4b=$(make_home)
write_plan "$h22f4b" "$(task_plan_rigor peer-reviewed "$v22f4b_body")" > /dev/null
expect_allow "22f4b peer-reviewed frontmatter, addressed tested cell + waiver → allow" \
  "$h22f4b" 'git commit -m "x"'

# 22f5 — frontmatter audited, addressed row cell audited (EQUAL, no downgrade),
# done, proper evidence → allow. The floor comparison is strict-less-than, so an
# equal cell is never a downgrade.
v22f5_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | audited | fix enum | done |

## SDLC State

scale: task
current: T1

- T1: bash test.sh 12/12 auditor CONFIRMED, critic no-blocking"
h22f5=$(make_home)
write_plan "$h22f5" "$(task_plan "$v22f5_body")" > /dev/null
expect_allow "22f5 audited frontmatter, addressed audited cell (equal) → allow (no downgrade)" \
  "$h22f5" 'git commit -m "x"'

# 22f6 — NON-addressed done row (T1) at frontmatter audited with cell
# peer-reviewed (downgrade). Addressed unit T2 is honest and non-downgrade
# (cell audited). No waiver on T1 → block; with a waiver on T1 → allow (T1 runs
# at the peer-reviewed lane, so its proof-shaped + auditor evidence suffices).
v22f6_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | peer-reviewed | fix the parser | done |
| T2 | build | audited | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: bash test.sh 9/9 auditor CONFIRMED
- T2: bash suite 12/12 green"
h22f6a=$(make_home)
write_plan "$h22f6a" "$(task_plan "$v22f6_body")" > /dev/null
expect_block "22f6a audited frontmatter, non-addressed done peer-reviewed cell (downgrade), no waiver → block" \
  "$h22f6a" 'git commit -m "x"' "lowers rigor"

v22f6b_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | peer-reviewed | fix the parser | done |
| T2 | build | audited | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: bash test.sh 9/9 auditor CONFIRMED, waiver: dana 2026-07-19 scoped down to peer-reviewed
- T2: bash suite 12/12 green"
h22f6b=$(make_home)
write_plan "$h22f6b" "$(task_plan "$v22f6b_body")" > /dev/null
expect_allow "22f6b same, waiver on the non-addressed done row → allow (runs at peer-reviewed lane)" \
  "$h22f6b" 'git commit -m "x"'

# 22f7 (F3 word-boundary) — audited addressed done row whose evidence contains
# `critical` (which embeds the substring `critic`) and `auditor CONFIRMED` but
# NO standalone `critic` token → block on the critic lane. Under the pre-fix
# unanchored `grep -q "critic"` the `critical` substring satisfied the lane and
# this allowed; the whole-word `grep -Ewq 'critic'` fix restores the block.
# Adding a standalone `critic no-blocking` token then allows.
v22f7a_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | audited | fix the parser | done |

## SDLC State

scale: task
current: T1

- T1: bash test.sh 9/9, auditor CONFIRMED, fixed a critical path bug"
h22f7a=$(make_home)
write_plan "$h22f7a" "$(task_plan "$v22f7a_body")" > /dev/null
expect_block "22f7a audited done row, 'critical' (no standalone critic) → block (word-boundary critic token)" \
  "$h22f7a" 'git commit -m "x"' "critic"

v22f7b_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | audited | fix the parser | done |

## SDLC State

scale: task
current: T1

- T1: bash test.sh 9/9, auditor CONFIRMED, fixed a critical path bug, critic no-blocking"
h22f7b=$(make_home)
write_plan "$h22f7b" "$(task_plan "$v22f7b_body")" > /dev/null
expect_allow "22f7b same evidence + standalone 'critic no-blocking' token → allow" \
  "$h22f7b" 'git commit -m "x"'

# ============================================================
# Section 23: canonical_sdlc_version — exactly one supported value
# ============================================================
#
# The hook supports canonical_sdlc_version: 14 and nothing else. Every other
# value blocks with exit 2 and a message naming the value found. One
# table-driven case over representative bad values — an older number, a much
# older number, a legacy single digit, a far-future number, an empty value, and
# non-numeric garbage — because there is one behavior here, not one per value.
#
# The version check sits ahead of every shape check, so these fixtures carry a
# valid ## SDLC State: what is under test is the version, not the evidence.

section "Section 23: canonical_sdlc_version — exactly one supported value"

versioned_plan() {  # $1 = the canonical_sdlc_version value to declare
  printf -- '---\n'
  printf -- 'governing-skill: canonical-sdlc\n'
  printf -- 'canonical_sdlc_version: %s\n' "$1"
  printf -- 'intent: build\nrigor: tested\nscale: wave\n'
  printf -- '---\n'
  printf -- '## SDLC State\ncurrent: 3\nStep 3: .bionic/docs/plans/wave-01.plan.md\n'
}

for bad_version in 13 12 11 9 2 99 "" banana 12.0 v12; do
  h=$(make_home)
  write_plan "$h" "$(versioned_plan "$bad_version")" > /dev/null
  expect_block "unsupported canonical_sdlc_version '${bad_version:-<empty>}' → block, naming the value found" \
    "$h" 'git commit -m "x"' "canonical_sdlc_version: '${bad_version}'"
done

# A plan with NO canonical_sdlc_version line at all is not a special case: it
# reads as the empty value and blocks the same way.
h23none=$(make_home)
write_plan "$h23none" "---
governing-skill: canonical-sdlc
intent: build
rigor: tested
scale: wave
---
## SDLC State
current: 3
Step 3: .bionic/docs/plans/wave-01.plan.md" > /dev/null
expect_block "absent canonical_sdlc_version → block" \
  "$h23none" 'git commit -m "x"' "the only supported version"

# The supported value passes the version gate (proved by reaching — and
# satisfying — the evidence checks beyond it).
h23ok=$(make_home)
write_plan "$h23ok" "$(versioned_plan 14)" > /dev/null
expect_allow "canonical_sdlc_version: 14 → allow" "$h23ok" 'git commit -m "x"'

# ============================================================
# Section 24: AC-13 — the plan-search fail-open
# ============================================================
#
# This hook fails open DIFFERENTLY from the governing-skill hook. It never
# tests `.bionic/` at all: every candidate plan directory is skipped by
# `[ -d "$d" ] || continue`, PLAN comes back empty, and the commit passes
# ungated. Closing the governing-skill hook's fail-open does nothing for this
# one, which is why the two are driven independently here.
#
# The distinction the AC draws, applied to a commit gate:
#   ABSENT     — no plan anywhere. Not a canonical-sdlc run. Never blocks;
#                this is every commit in every project that does not use the
#                lifecycle, and a wall there would be intolerable.
#   MISPLACED  — a plan carrying the run marker exists in the project, but
#                outside every directory the gate searches. The gate is
#                silently disabled and the commit would sail through. Blocks,
#                naming where the plan belongs.
section "Section 24: AC-13 — misplaced plan blocks, absent plan never does"

s24_marked_plan() {  # a plan carrying the run-state marker + a satisfied state
  printf -- '---\ngoverning-skill: superpowers:writing-plans\n'
  printf -- 'canonical_sdlc_version: 14\nintent: build\nrigor: tested\nscale: wave\n---\n'
  printf -- '## SDLC State\ncurrent: 3\nStep 3: .bionic/docs/plans/wave-01.plan.md\n'
}

echo "-- c1: ABSENCE never blocks --"
# A project with no .bionic/ at all and no plan file anywhere. The single most
# common commit in the world; it must pass, silently.
s24_h1=$(make_home)
s24_p1=$(mktemp -d); cleanup_dirs+=("$s24_p1")
mkdir -p "$s24_p1/src"
printf 'echo hi\n' > "$s24_p1/src/main.sh"
run_hook_with_project "$s24_h1" "$s24_p1" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
  ok "no .bionic/, no plan anywhere → allow, silently"
else
  no "no .bionic/, no plan anywhere → allow, silently" "expected allow; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

# .bionic/docs/plans/ exists but is empty — a project that has run Step 0 and
# not yet written a plan. Still absence, still no block.
s24_h1b=$(make_home)
s24_p1b=$(make_project)
run_hook_with_project "$s24_h1b" "$s24_p1b" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
  ok "empty .bionic/docs/plans/ → allow, silently"
else
  no "empty .bionic/docs/plans/ → allow, silently" "expected allow; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

echo "-- c2: MISPLACEMENT blocks, naming the correct path --"
# The legacy layout, and the shape a moved-or-renamed tree leaves behind: a
# real canonical-sdlc plan the gate cannot see.
s24_h2=$(make_home)
s24_p2=$(mktemp -d); cleanup_dirs+=("$s24_p2")
mkdir -p "$s24_p2/docs/bionic/plans/epic-01-demo"
# ENGAGED, and the misplacement is untouched by it: the marker lives in `.bionic/tmp`,
# the docs root this gate names is `.bionic/docs`, and creating one does not create the
# other. hooks/engage.sh makes the tmp directory in exactly this shape of project.
engage "$s24_p2"
s24_marked_plan > "$s24_p2/docs/bionic/plans/epic-01-demo/wave-01-x.plan.md"
run_hook_with_project "$s24_h2" "$s24_p2" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 2 ] \
   && grep -q "misplaced" <<<"$HOOK_STDERR" \
   && grep -qF "$s24_p2/.bionic/docs/plans/" <<<"$HOOK_STDERR"; then
  ok "misplaced plan → block, naming the correct path"
else
  no "misplaced plan → block, naming the correct path" "expected block naming $s24_p2/.bionic/docs/plans/; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

# The identical plan in the right place is found and gated normally — proof the
# block above is about WHERE the file is, not about the file.
s24_h3=$(make_home)
s24_p3=$(make_project)
s24_marked_plan > "$s24_p3/.bionic/docs/plans/wave-01-x.plan.md"

echo "-- c3: unmarked files are unaffected --"
# A *.plan.md with no canonical_sdlc_version is not a canonical-sdlc run
# artifact. Plenty of projects have plan-shaped markdown; none of it is this
# hook's business.
s24_h4=$(make_home)
s24_p4=$(mktemp -d); cleanup_dirs+=("$s24_p4")
mkdir -p "$s24_p4/notes"
printf '# Some plan\n\nnot a canonical-sdlc artifact\n' > "$s24_p4/notes/roadmap.plan.md"
run_hook_with_project "$s24_h4" "$s24_p4" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
  ok "unmarked *.plan.md → allow, silently"
else
  no "unmarked *.plan.md → allow, silently" "expected allow; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

# A FENCED example of the frontmatter is documentation. Only the leading block
# counts — the recurring trap in this repo is a parser that reads fenced
# examples as real declarations.
s24_h5=$(make_home)
s24_p5=$(mktemp -d); cleanup_dirs+=("$s24_p5")
mkdir -p "$s24_p5/docs"
{ printf '# How to write a plan\n\n```\n---\ncanonical_sdlc_version: 14\n---\n```\n'; } \
  > "$s24_p5/docs/example.plan.md"
run_hook_with_project "$s24_h5" "$s24_p5" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
  ok "fenced frontmatter example → allow, silently"
else
  no "fenced frontmatter example → allow, silently" "expected allow; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

echo "-- c4: elsewhere under the docs root is PLACED, not misplaced --"
# <docs-root>/spikes/ and <docs-root>/record/ hold real artifacts carrying this
# frontmatter. The governing-skill hook treats the whole docs root as placed;
# this hook must agree, or the two would disagree about the same file.
s24_h6=$(make_home)
s24_p6=$(make_project)
mkdir -p "$s24_p6/.bionic/docs/spikes"
s24_marked_plan > "$s24_p6/.bionic/docs/spikes/spike-x.plan.md"
run_hook_with_project "$s24_h6" "$s24_p6" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
  ok "marked plan under <docs-root>/spikes/ → placed, allow"
else
  no "marked plan under <docs-root>/spikes/ → placed, allow" "expected allow; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

echo "-- c5: the named path follows docs-root: in config.yaml --"
s24_h7=$(make_home)
s24_p7=$(mktemp -d); cleanup_dirs+=("$s24_p7")
mkdir -p "$s24_p7/.bionic" "$s24_p7/.bionic/docs/plans/epic-01-demo"
printf 'docs-root: custom/docs\n' > "$s24_p7/.bionic/config.yaml"
engage "$s24_p7"
s24_marked_plan > "$s24_p7/.bionic/docs/plans/epic-01-demo/wave-01-x.plan.md"
run_hook_with_project "$s24_h7" "$s24_p7" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 2 ] && grep -qF "$s24_p7/custom/docs/plans/" <<<"$HOOK_STDERR"; then
  ok "block names the CONFIGURED docs root, not a hardcoded .bionic/"
else
  no "block names the CONFIGURED docs root, not a hardcoded .bionic/" "expected block naming $s24_p7/custom/docs/plans/; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

echo "-- c6: a non-commit command is never touched by any of this --"
s24_h8=$(make_home)

echo "-- c7: a NON-EMPTY ~/.claude/plans must not make the sweep unreachable --"
# Step-6 finding C1/S2, still pinned after its root cause was removed. The guard
# on this whole block used to be "no plan was found in ANY searched directory",
# and the FIRST directory searched was the global, project-agnostic
# ~/.claude/plans/. One unrelated .md there — the harness's own plan mode writes
# into exactly that directory — made $PLAN non-empty and the block dead. Two
# such files were sitting on the developing machine, so the branch AC-13 added
# had never executed in production.
#
# C1/S2 fixed that by scoping the guard to a project-only selection. The
# 2026-07-28 ruling fixed it at the root instead: the global directory is no
# longer searched at all, so nothing in it can make $PLAN non-empty and the
# project-only selection collapsed back into $PLAN. These three cases now pin
# that the whole class is structurally gone — a file in ~/.claude/plans/ changes
# none of the three verdicts below. They also stop make_home()'s EMPTY
# ~/.claude/plans/ from substituting away the precondition, which is the
# recorded seam-blindness class and the reason they are written this way.
# [WALL: hooks/canonical-sdlc-evidence-gate.sh]
s24_h9=$(make_home)
printf '# just a note\n' > "$s24_h9/.claude/plans/stray.md"
s24_p9=$(mktemp -d); cleanup_dirs+=("$s24_p9")
mkdir -p "$s24_p9/docs/bionic/plans/epic-01-demo"
engage "$s24_p9"
s24_marked_plan > "$s24_p9/docs/bionic/plans/epic-01-demo/wave-01-x.plan.md"
run_hook_with_project "$s24_h9" "$s24_p9" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 2 ] \
   && grep -q "misplaced" <<<"$HOOK_STDERR" \
   && grep -qF "$s24_p9/.bionic/docs/plans/" <<<"$HOOK_STDERR"; then
  ok "misplaced plan blocks even with a non-empty ~/.claude/plans"
else
  no "misplaced plan blocks even with a non-empty ~/.claude/plans" "expected block; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

# The guard must not widen the BLOCK. A project whose plan is correctly placed
# has a plan, so the sweep never runs — regardless of what the global directory
# holds.
s24_h10=$(make_home)
printf '# just a note\n' > "$s24_h10/.claude/plans/stray.md"
s24_p10=$(make_project)
s24_marked_plan > "$s24_p10/.bionic/docs/plans/wave-01-x.plan.md"
touch "$s24_p10/.bionic/docs/plans/wave-01-x.plan.md"
run_hook_with_project "$s24_h10" "$s24_p10" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
  ok "correctly-placed project plan + non-empty ~/.claude/plans → no false block"
else
  no "correctly-placed project plan + non-empty ~/.claude/plans → no false block" "expected allow; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

# ABSENCE still never blocks, even though the sweep now runs in this state.
s24_h11=$(make_home)
printf '# just a note\n' > "$s24_h11/.claude/plans/stray.md"
s24_p11=$(mktemp -d); cleanup_dirs+=("$s24_p11")
mkdir -p "$s24_p11/src"
printf 'echo hi\n' > "$s24_p11/src/main.sh"
run_hook_with_project "$s24_h11" "$s24_p11" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
  ok "no project plan, nothing misplaced, non-empty ~/.claude/plans → allow"
else
  no "no project plan, nothing misplaced, non-empty ~/.claude/plans → allow" "expected allow; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

# ============================================================
# Section 25: C2/S1 — the two hooks name ONE root per repo
# ============================================================
#
# The governing-skill hook resolves the project root with resolve_project_root
# (`--git-common-dir`, i.e. the MAIN repo even from inside a linked worktree).
# This gate derived PROJECT_DIR — and therefore DOCS_ROOT, PLAN_DIRS and the
# AC-13 misplacement sweep's root — from CLAUDE_PROJECT_DIR/.cwd/pwd, i.e. the
# WORKTREE. Slice 1 migrated only audit_root().
#
# The consequence was that in a linked worktree NO artifact placement satisfied
# both hooks: put the plan where the governing hook demands (the main repo) and
# every commit from the worktree ran ungated; put it in the worktree so the gate
# finds it and every artifact write was blocked. canonical-sdlc ships a
# `use_worktree` flag, so this is the lifecycle's own normal mode.
#
# Fixture fidelity: a real `git init` + `git worktree add`, like Section 21c —
# the behaviour under test is git's own --git-common-dir handling.
# [WALL: hooks/canonical-sdlc-evidence-gate.sh]

section "Section 25: one root per repo across both hooks (worktrees)"

s25_plan() {  # a canonical plan whose current step evidence is a placeholder
  printf -- '---\ngoverning-skill: canonical-sdlc\ncanonical_sdlc_version: 14\n'
  printf -- 'intent: build\nrigor: tested\nscale: wave\n'
  printf -- 'deploy_target: none\nuse_worktree: true\nhas_ui: false\n---\n'
  printf -- '## SDLC State\ncurrent: 5\napproved-by: fixture 2026-09-07T00:00Z approved\nStep 5: TODO\n'
}

s25_tmp=$(cd "$(mktemp -d)" && pwd -P); cleanup_dirs+=("$s25_tmp")
s25_main="$s25_tmp/main"
mkdir -p "$s25_main/.bionic/docs/plans"
git -C "$s25_main" init -q .
git -C "$s25_main" commit -q --allow-empty -m init
git -C "$s25_main" worktree add -q "$s25_tmp/wt" -b s25-wt
s25_wt="$s25_tmp/wt"
engage "$s25_main"
s25_plan > "$s25_main/.bionic/docs/plans/wave-01-x.plan.md"

echo "-- 25a: a commit FROM the worktree is gated against the main repo's plan --"
s25_h1=$(make_home)
run_hook_with_project "$s25_h1" "$s25_wt" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 2 ] \
   && grep -q "placeholder" <<<"$HOOK_STDERR" \
   && grep -qF "$s25_main/.bionic/docs/plans/wave-01-x.plan.md" <<<"$HOOK_STDERR"; then
  ok "25a commit from a linked worktree is gated by the main repo's plan"
else
  no "25a commit from a linked worktree is gated by the main repo's plan" "expected block naming the main repo's plan; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

echo "-- 25b: control — the identical commit from the MAIN repo --"
s25_h2=$(make_home)
run_hook_with_project "$s25_h2" "$s25_main" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 2 ] && grep -q "placeholder" <<<"$HOOK_STDERR"; then
  ok "25b commit from the main repo blocks identically"
else
  no "25b commit from the main repo blocks identically" "expected block; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

echo "-- 25c: the misplacement sweep also walks the MAIN repo, not the worktree --"
# Same shape, no plan anywhere the gate searches, and a marked plan sitting
# outside the docs root in the MAIN repo. Both the sweep's root and the docs
# root it names must be the main repo's.
s25_tmp2=$(cd "$(mktemp -d)" && pwd -P); cleanup_dirs+=("$s25_tmp2")
s25_main2="$s25_tmp2/main"
mkdir -p "$s25_main2/notes"
git -C "$s25_main2" init -q .
git -C "$s25_main2" commit -q --allow-empty -m init
git -C "$s25_main2" worktree add -q "$s25_tmp2/wt" -b s25-wt2
s25_wt2="$s25_tmp2/wt"
engage "$s25_main2"
s25_marked_plan_body() {
  printf -- '---\ngoverning-skill: superpowers:writing-plans\n'
  printf -- 'canonical_sdlc_version: 14\nintent: build\nrigor: tested\nscale: wave\n---\n'
  printf -- '## SDLC State\ncurrent: 3\nStep 3: .bionic/docs/plans/wave-01.plan.md\n'
}
s25_marked_plan_body > "$s25_main2/notes/rogue.plan.md"
s25_h3=$(make_home)
run_hook_with_project "$s25_h3" "$s25_wt2" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 2 ] \
   && grep -q "misplaced" <<<"$HOOK_STDERR" \
   && grep -qF "$s25_main2/notes/rogue.plan.md" <<<"$HOOK_STDERR" \
   && grep -qF "$s25_main2/.bionic/docs/plans/" <<<"$HOOK_STDERR"; then
  ok "25c sweep from a worktree finds the main repo's misplaced plan"
else
  no "25c sweep from a worktree finds the main repo's misplaced plan" "expected block naming the main repo's paths; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

echo "-- 25e: ONE file, BOTH hooks, one worktree — the two must agree --"
# A19: every worktree fixture in this tree had asked ONE hook about the
# placement convenient to that hook, and the two suites' answers contradicted
# each other while both stayed green. This case puts a single artifact path in
# front of both binaries in the order the lifecycle actually uses them:
#   1. the governing-skill hook REFUSES the worktree-local placement and names
#      the main repo's docs root;
#   2. it ACCEPTS the placement it named;
#   3. this gate, invoked from the worktree, gates the commit against that same
#      file.
# Before the C2/S1 repair, (3) was exit 0 — obey (1) and every commit from a
# worktree ran ungated.
s25_gov_hook="$(dirname "$HOOK")/canonical-sdlc-governing-skill.sh"
s25_gov_home=$(make_home)   # keeps the governing hook's audit writes off the real ~/.claude
s25_run_write() {  # $1=file path, $2=content → S25_GOV_EXIT / S25_GOV_STDERR
  local input tmp_err
  # The governing hook is engagement-scoped too, and it looks for the marker under the
  # ARTIFACT's root — which for both arms of 25e is the main repo (engaged above).
  input=$(jq -n --arg p "$1" --arg c "$2" --arg s "$EG_SID" \
    '{session_id: $s, tool_name: "Write", tool_input: {file_path: $p, content: $c}}')
  tmp_err=$(mktemp)
  if HOME="$s25_gov_home" CLAUDE_CODE_SESSION_ID="$EG_SID" bash "$s25_gov_hook" <<< "$input" >/dev/null 2>"$tmp_err"; then
    S25_GOV_EXIT=0
  else
    S25_GOV_EXIT=$?
  fi
  S25_GOV_STDERR=$(cat "$tmp_err")
  rm -f "$tmp_err"
}
s25_artifact='---
governing-skill: superpowers:writing-plans
sdlc-step: 3
epic: epic-01-demo
wave: wave-01-x
canonical_sdlc_version: 14
intent: build
rigor: tested
scale: wave
cleanup_on_finish: true
use_worktree: true
surface_type: none
language: none
has_ui: false
multi_agent: false
deploy_target: none
model_plan: orchestrator=fable-5-high
---

## Verification Matrix

stack-health: n/a: no long-running serve observed

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T1 | discharged | see AC-1 | CONFIRMED |

## SDLC State
current: 5
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 5: TODO
'
s25_run_write "$s25_wt/.bionic/docs/plans/epic-01-demo/both.plan.md" "$s25_artifact"
if [ "$S25_GOV_EXIT" -eq 2 ] && grep -qF "$s25_main/.bionic/docs" <<<"$S25_GOV_STDERR"; then
  ok "25e1 governing hook refuses the worktree-local placement, names the main repo"
else
  no "25e1 governing hook refuses the worktree-local placement, names the main repo" "exit=$S25_GOV_EXIT stderr='$S25_GOV_STDERR'"
fi

mkdir -p "$s25_main/.bionic/docs/plans/epic-01-demo"
s25_run_write "$s25_main/.bionic/docs/plans/epic-01-demo/both.plan.md" "$s25_artifact"
if [ "$S25_GOV_EXIT" -eq 0 ]; then
  ok "25e2 governing hook accepts the placement it named"
else
  no "25e2 governing hook accepts the placement it named" "exit=$S25_GOV_EXIT stderr='$S25_GOV_STDERR'"
fi

printf '%s' "$s25_artifact" > "$s25_main/.bionic/docs/plans/epic-01-demo/both.plan.md"
touch "$s25_main/.bionic/docs/plans/epic-01-demo/both.plan.md"
s25_h5=$(make_home)
run_hook_with_project "$s25_h5" "$s25_wt" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 2 ] \
   && grep -q "placeholder" <<<"$HOOK_STDERR" \
   && grep -qF "$s25_main/.bionic/docs/plans/epic-01-demo/both.plan.md" <<<"$HOOK_STDERR"; then
  ok "25e3 the gate, from the worktree, gates the SAME file the governing hook accepted"
else
  no "25e3 the gate, from the worktree, gates the SAME file the governing hook accepted" "exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

ac10_oldgit=$(mktemp -d); cleanup_dirs+=("$ac10_oldgit")
ac10_real_git=$(command -v git)
{
  printf '#!/bin/bash\n'
  printf 'for a in "$@"; do\n'
  printf '  [ "$a" = "--path-format=absolute" ] && exit 129\n'
  printf 'done\n'
  printf 'exec %s "$@"\n' "$ac10_real_git"
} > "$ac10_oldgit/git"
chmod +x "$ac10_oldgit/git"
echo "-- 25f: git < 2.31 — the two hooks still agree on one root --"
# FIX 1 and FIX 5 meet here. Under old git the resolver's primary branch fails,
# so if the fallback did not exist the gate would keep PROJECT_DIR at the
# worktree and C2/S1 would be reopened on every pre-2.31 machine — a green
# 25a would be proving nothing about them. Same fixture, same assertion, one
# variable changed.
# [WALL: hooks/canonical-sdlc-evidence-gate.sh]
s25_h6=$(make_home)
s25_saved_path="$PATH"
PATH="$ac10_oldgit:$PATH"
run_hook_with_project "$s25_h6" "$s25_wt" 'git commit -m "x"'
PATH="$s25_saved_path"
if [ "$HOOK_EXIT" -eq 2 ] \
   && grep -q "placeholder" <<<"$HOOK_STDERR" \
   && grep -qF "$s25_main/.bionic/docs/plans/" <<<"$HOOK_STDERR"; then
  ok "25f old git — worktree commit still gated by the main repo's plan"
else
  no "25f old git — worktree commit still gated by the main repo's plan" "expected block naming the main repo; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

echo "-- 25d: a non-repo project dir still resolves to itself (fallback intact) --"
# resolve_project_root falls back to the supplied value when git cannot answer,
# so every non-repo fixture in this suite keeps its previous meaning.
s25_h4=$(make_home)
s25_p4=$(make_project)
s24_marked_plan > "$s25_p4/.bionic/docs/plans/wave-01-x.plan.md"
run_hook_with_project "$s25_h4" "$s25_p4" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
  ok "25d non-repo project dir resolves to itself, plan still found"
else
  no "25d non-repo project dir resolves to itself, plan still found" "expected allow; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

# ============================================================
# Section 26: the walk-artifact arm (AC-1, AC-2)
# ============================================================
#
# Walk-first verification: before any matrix row discharges, an agent must have
# narrated the real running surface into <docs-root>/record/. The arm reads
# plan frontmatter `walk:` — `exempt` makes it inert, `required` OR AN ABSENT
# KEY arms it (fail-closed, plan assumption A1: an exemption is ratified at
# Step 0, never inferred from an omission). Armed, at current: 5..9 with any
# matrix row `discharged`, three conditions must all hold:
#   (a) the Step-5 evidence carries a `walk-artifact: <path>` line;
#   (b) that path resolves to a real file under <docs-root>/record/;
#   (c) `grep -E 'AC-[0-9]'` over that file finds nothing — the walk narrates,
#       it never checklists (the artifact is written without having read the
#       acceptance criteria, and an AC identifier is the tell that it was).
# It is a durable PREFIX condition (A5): the 6..9 arm re-checks it, so the
# artifact cannot be deleted once the Verify gate is behind you.
#
# The Step-5 block is read by its own extractor at every step, not from the
# current step's BLOCK — at current: 6 the BLOCK holds Step-6 evidence.

section "Section 26: walk-artifact arm"

# $1 = a full `walk:` frontmatter line, or empty for THE KEY IS ABSENT (the
# fail-closed case). Otherwise the Section-17 shape: audited wave, no
# multi_agent key, so the dispatch-ledger machinery stays out of the way.
walk_frontmatter() {
  local walk_line="${1:-}"
  printf -- '---\n'
  printf -- 'governing-skill: canonical-sdlc\ncanonical_sdlc_version: 14\n'
  printf -- 'intent: build\nrigor: audited\nscale: wave\n'
  printf -- 'deploy_target: none\nuse_worktree: false\nhas_ui: true\n'
  if [ -n "$walk_line" ]; then
    printf -- '%s\n' "$walk_line"
  fi
  printf -- '---\n'
}

# $1 walk line · $2 Step-5 body (indented) · $3 matrix section.
walk_plan5() {
  printf '%s\n## SDLC State\ncurrent: 5\napproved-by: fixture 2026-09-07T00:00Z approved\nStep 5:\n%s\n\n%s\n' \
    "$(walk_frontmatter "$1")" "$2" "$3"
}

# Same, at current: 6 — the Step-5 block stays in the section so the durable
# prefix arm has something to read.
walk_plan6() {
  printf '%s\n## SDLC State\ncurrent: 6\napproved-by: fixture 2026-09-07T00:00Z approved\nStep 5:\n%s\nStep 6:\n%s\n\n%s\n' \
    "$(walk_frontmatter "$1")" "$2" "$step6_body" "$3"
}

# Writes a walk narration into the sandbox's <docs-root>/record/.
# $1 home · $2 content · $3 filename (default walk-20260801.md).
write_walk_artifact() {
  local dir="$1/.bionic/docs/record" name="${3:-walk-20260801.md}"
  mkdir -p "$dir"
  printf '%s\n' "$2" > "$dir/$name"
  echo "$dir/$name"
}

# A real walk narration: what was driven, what came back. No AC identifiers.
walk_clean_text="Started a scratch repo with the hook wired and tried an ordinary commit.
It refused, naming a missing narration file. Wrote one under record/, ran the
same commit again, and it went through. Nothing else in the tree changed."

# The same narration with a criterion identifier in it — a checklist leaking
# into the walk.
walk_dirty_text="Started a scratch repo and tried an ordinary commit.
It refused as AC-3 predicted, then passed once the file existed."

walk_step5_with_artifact="  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/docs/record/audit.md
  walk-artifact: record/walk-20260801.md"

walk_step5_no_artifact="  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/docs/record/audit.md"

# Every row still pending: nothing has discharged, so the arm must not fire —
# a mid-discharge commit before the walk is written stays legal. No auditor
# pointer either (the Step-5 relaxation), which is the honest shape here.
walk_matrix_all_pending="## Verification Matrix

stack-health: before: process restarts 0; walk not yet run

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T1 | pending | see AC-1 |  |
| AC-2 | T1 | pending | see AC-2 |  |"

walk_step5_pending="  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5"

# 26a — walk: required, rows discharged, no walk-artifact line → block.
h26a=$(make_home)
write_plan "$h26a" "$(walk_plan5 'walk: required' "$walk_step5_no_artifact" "$matrix_complete")" > /dev/null
expect_block "26a walk: required + discharged rows + no walk-artifact line → block" \
  "$h26a" 'git commit -m "x"' "no 'walk-artifact:' line"

# 26b — the line, a real file under record/, no AC identifiers → allow.
h26b=$(make_home)
write_walk_artifact "$h26b" "$walk_clean_text" > /dev/null
write_plan "$h26b" "$(walk_plan5 'walk: required' "$walk_step5_with_artifact" "$matrix_complete")" > /dev/null
expect_allow "26b walk: required + clean artifact under record/ → allow" \
  "$h26b" 'git commit -m "x"'

# 26c — the artifact names an acceptance criterion → block.
h26c=$(make_home)
write_walk_artifact "$h26c" "$walk_dirty_text" > /dev/null
write_plan "$h26c" "$(walk_plan5 'walk: required' "$walk_step5_with_artifact" "$matrix_complete")" > /dev/null
expect_block "26c walk artifact containing 'AC-3' → block" \
  "$h26c" 'git commit -m "x"' "names acceptance criteria"

# 26d — walk: exempt, discharged rows, no artifact anywhere → allow (inert).
h26d=$(make_home)
write_plan "$h26d" "$(walk_plan5 'walk: exempt' "$walk_step5_no_artifact" "$matrix_complete")" > /dev/null
expect_allow "26d walk: exempt + discharged rows + no artifact → allow" \
  "$h26d" 'git commit -m "x"'

# 26e — the key is ABSENT: fail-closed, so it behaves exactly like required.
h26e=$(make_home)
write_plan "$h26e" "$(walk_plan5 '' "$walk_step5_no_artifact" "$matrix_complete")" > /dev/null
expect_block "26e walk key absent + discharged rows + no artifact → block (fail-closed)" \
  "$h26e" 'git commit -m "x"' "no 'walk-artifact:' line"

# 26f — nothing discharged yet: the arm does not fire even fail-closed.
h26f=$(make_home)
write_plan "$h26f" "$(walk_plan5 '' "$walk_step5_pending" "$walk_matrix_all_pending")" > /dev/null
expect_allow "26f current 5, all rows pending, no artifact → allow (arm does not fire)" \
  "$h26f" 'git commit -m "x"'

# 26g — durable prefix condition (A5): at current: 6 the named artifact is
# gone, so the commit blocks even though Step 5 is behind us.
h26g=$(make_home)
h26g_art=$(write_walk_artifact "$h26g" "$walk_clean_text")
write_plan "$h26g" "$(walk_plan6 'walk: required' "$walk_step5_with_artifact" "$matrix_complete")" > /dev/null
rm -f "$h26g_art"
expect_block "26g current 6 with the walk artifact deleted → block (durable prefix)" \
  "$h26g" 'git commit -m "x"' "no file exists at"

# 26g-ok — the same plan with the artifact still in place → allow, so the
# block above is the deletion and not the step.
h26g2=$(make_home)
write_walk_artifact "$h26g2" "$walk_clean_text" > /dev/null
write_plan "$h26g2" "$(walk_plan6 'walk: required' "$walk_step5_with_artifact" "$matrix_complete")" > /dev/null

# 26h — a project-relative spelling of the same file resolves too.
h26h=$(make_home)
write_walk_artifact "$h26h" "$walk_clean_text" > /dev/null
write_plan "$h26h" "$(walk_plan5 'walk: required' "  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/docs/record/audit.md
  walk-artifact: .bionic/docs/record/walk-20260801.md" "$matrix_complete")" > /dev/null
expect_allow "26h project-relative walk-artifact path under record/ → allow" \
  "$h26h" 'git commit -m "x"'

# 26i — a path that climbs out of record/ is refused before any file test.
h26i=$(make_home)
printf 'walk narration living outside the record\n' > "$h26i/.bionic/docs/escaped.md"
write_plan "$h26i" "$(walk_plan5 'walk: required' "  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/docs/record/audit.md
  walk-artifact: record/../escaped.md" "$matrix_complete")" > /dev/null
expect_block "26i walk-artifact climbing out of record/ → block" \
  "$h26i" 'git commit -m "x"' "does not resolve under"

# 26j — a real file that simply lives somewhere else is refused the same way.
h26j=$(make_home)
printf 'walk narration in the wrong place\n' > "$h26j/.bionic/docs/plans/walk.md"
write_plan "$h26j" "$(walk_plan5 'walk: required' "  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/docs/record/audit.md
  walk-artifact: .bionic/docs/plans/walk.md" "$matrix_complete")" > /dev/null
expect_block "26j walk-artifact outside record/ → block" \
  "$h26j" 'git commit -m "x"' "does not resolve under"

# 26k — a zero-byte file at the named path is not a walk: existence alone is
# not enough, the artifact must carry content. The message must distinguish
# this case ("file is empty at") from the missing-file case above ("no file
# exists at").
h26k=$(make_home)
mkdir -p "$h26k/.bionic/docs/record"
touch "$h26k/.bionic/docs/record/walk-20260801.md"
write_plan "$h26k" "$(walk_plan5 'walk: required' "$walk_step5_with_artifact" "$matrix_complete")" > /dev/null
expect_block "26k zero-byte walk artifact → block (existence alone is not enough)" \
  "$h26k" 'git commit -m "x"' "file is empty at"

# 26l — an OFF-ENUM walk value arms the arm exactly like `required`. walk_mode()
# treats everything that is not the literal `exempt` as armed (A1/A7: a typo
# must never buy a bypass), and the enum itself is the governing-skill hook's
# job at write time. That split is only sound if the gate really does arm here,
# which is what this pins — independently of the other hook's coverage.
h26l=$(make_home)
write_plan "$h26l" "$(walk_plan5 'walk: bogus' "$walk_step5_no_artifact" "$matrix_complete")" > /dev/null
expect_block "26l off-enum 'walk: bogus' + discharged rows + no artifact → block (arms like required)" \
  "$h26l" 'git commit -m "x"' "no 'walk-artifact:' line"

# 26m/26n/26o — packed-line extraction (bugfix A17). Sibling extractors
# elsewhere in this hook already truncate at ';' to tolerate a Step-5 line
# with more fields packed after the value; the raw walk-artifact extraction
# was the outlier, greedy to end-of-line. A Step-5 line of the shape
# `walk-artifact: record/x.md; cmd: ...` swallowed the semicolon-joined
# remainder as part of the "path", which never resolved even though the real
# file exists.

walk_step5_packed_ok="  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/docs/record/audit.md
  walk-artifact: record/walk-20260801.md; cmd: bash test.sh; pass: 332; total: 332"

walk_step5_packed_bad="  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/docs/record/audit.md
  walk-artifact: record/../escaped.md; cmd: bash test.sh; pass: 332; total: 332"

# 26m — a packed Step-5 line (fields after the path, semicolon-joined) naming
# a real, clean file under record/ → allow.
h26m=$(make_home)
write_walk_artifact "$h26m" "$walk_clean_text" > /dev/null
write_plan "$h26m" "$(walk_plan5 'walk: required' "$walk_step5_packed_ok" "$matrix_complete")" > /dev/null
expect_allow "26m packed walk-artifact line (fields after the path) → allow" \
  "$h26m" 'git commit -m "x"'

# 26n — regression pin: the dedicated continuation-line shape (no packed
# fields) still passes after the truncate-at-';' fix.
h26n=$(make_home)
write_walk_artifact "$h26n" "$walk_clean_text" > /dev/null
write_plan "$h26n" "$(walk_plan5 'walk: required' "$walk_step5_with_artifact" "$matrix_complete")" > /dev/null
expect_allow "26n dedicated continuation-line walk-artifact (unpacked) → allow" \
  "$h26n" 'git commit -m "x"'

# 26o — a packed line whose truncated value is STILL a bad path (climbs out
# of record/ via '..') must still block. The ';' cut must not accidentally
# salvage a genuinely bad path.
h26o=$(make_home)
printf 'walk narration living outside the record\n' > "$h26o/.bionic/docs/escaped.md"
write_plan "$h26o" "$(walk_plan5 'walk: required' "$walk_step5_packed_bad" "$matrix_complete")" > /dev/null
expect_block "26o packed walk-artifact line with a bad truncated path → block" \
  "$h26o" 'git commit -m "x"' "does not resolve under"

# ============================================================
# Section 27: the provenance arm (AC-5)
# ============================================================
#
# A citation of the literal form `provenance: implementation` is circular —
# it names the change itself as the source of its own requirement. The arm
# blocks on that exact value (whitespace-trimmed) inside any AC block, at
# whatever tier/status the row carries. A missing `provenance:` line does NOT
# block (plan assumption A4 — presence is a W+1 candidate, not this wave's).
# A value that merely CONTAINS the word ("implementation-first rewrite of
# spec §3") is a real citation and must not trip the whole-value test.
# validate_matrix() is the single call site for both the current: 5 Verify
# gate and the current: 6..9 prefix re-validation (dispatch() line ~1506), so
# one case at current: 6 confirms the arm fires there without a duplicate
# implementation.

section "Section 27: provenance arm"

# Builds a one-row T1 matrix (discharged, auditor CONFIRMED) whose AC-1 block
# carries tier-run + readback (satisfying T1's own evidence requirement) plus
# an optional `provenance:` line. $1 = the provenance value to write after
# the colon, or empty/omitted for no `provenance:` line at all.
prov_matrix() {
  local prov_line=""
  if [ -n "${1:-}" ]; then
    prov_line="
  provenance: $1"
  fi
  printf '## Verification Matrix\n\nstack-health: n/a: no long-running serve\n\n| AC | tier | status | evidence | auditor |\n|---|---|---|---|---|\n| AC-1 | T1 | discharged | see AC-1 | CONFIRMED |\n\nAC-1:\n  tier-run: bash test.sh — unit suite\n  fails-when: the planted defect this eval must go red on\n  readback: 332/332 asserted%s\n' "$prov_line"
}

# 27a — the literal value blocks.
h27a=$(make_home)
write_plan "$h27a" "$(plan 5 "$step5_base" "$(prov_matrix "implementation")")" > /dev/null
expect_block "27a provenance: implementation → block" \
  "$h27a" 'git commit -m "x"' "provenance: implementation"

# 27b — a real citation allows.
h27b=$(make_home)
write_plan "$h27b" "$(plan 5 "$step5_base" "$(prov_matrix "spec §3")")" > /dev/null
expect_allow "27b provenance: spec §3 → allow" \
  "$h27b" 'git commit -m "x"'

# 27c — no provenance line at all does not block (A4: presence isn't required).
h27c=$(make_home)
write_plan "$h27c" "$(plan 5 "$step5_base" "$(prov_matrix "")")" > /dev/null
expect_allow "27c no provenance line at all → allow" \
  "$h27c" 'git commit -m "x"'

# 27d — a value containing the word, not equal to it, must not trip the
# whole-value test.
h27d=$(make_home)
write_plan "$h27d" "$(plan 5 "$step5_base" "$(prov_matrix "implementation-first rewrite of spec §3")")" > /dev/null
expect_allow "27d provenance substring 'implementation-first ...' → allow (no false trigger)" \
  "$h27d" 'git commit -m "x"'

# 27e — surrounding whitespace around the value is trimmed before the
# equality test, so it still blocks.
h27e=$(make_home)
write_plan "$h27e" "$(plan 5 "$step5_base" "$(prov_matrix "  implementation  ")")" > /dev/null
expect_block "27e provenance:   implementation   (padded) → block" \
  "$h27e" 'git commit -m "x"' "provenance: implementation"

# 27f — the same arm fires at current: 6, the dispatch() prefix
# re-validation, confirming validate_matrix()'s single call site covers both
# without a second implementation.
h27f=$(make_home)
write_plan "$h27f" "$(plan 6 "$step6_body" "$(prov_matrix "implementation")")" > /dev/null
expect_block "27f provenance: implementation at current: 6 (prefix re-validation) → block" \
  "$h27f" 'git commit -m "x"' "provenance: implementation"

# 27g — the compare is case-insensitive, matching the placeholder and
# live-tier convention in the same loop (trim already applies): a capitalized
# value is the same circular citation as the lowercase one.
h27g=$(make_home)
write_plan "$h27g" "$(plan 5 "$step5_base" "$(prov_matrix "Implementation")")" > /dev/null
expect_block "27g provenance: Implementation (capitalized) → block (case-insensitive)" \
  "$h27g" 'git commit -m "x"' "provenance: implementation"

# 27h — pinned control: the case-fold must not widen the match past the
# whole-value test — a real citation prefixed by "the" still allows.
h27h=$(make_home)
write_plan "$h27h" "$(plan 5 "$step5_base" "$(prov_matrix "the implementation")")" > /dev/null
expect_allow "27h provenance: the implementation → allow (pinned control)" \
  "$h27h" 'git commit -m "x"'

# 27i — pinned control: a substring citation still allows after the
# case-fold.
h27i=$(make_home)
write_plan "$h27i" "$(plan 5 "$step5_base" "$(prov_matrix "implementation-first rewrite of spec section 3")")" > /dev/null
expect_allow "27i provenance: implementation-first rewrite of spec section 3 → allow (pinned control)" \
  "$h27i" 'git commit -m "x"'

# --- step scope of the arm (PINNED, not merely observed) -------------------
#
# validate_matrix() runs at the Verify gate (current: 5) and as the prefix
# re-check for current: 6..9, and nowhere else — so the provenance arm is
# SILENT at the authoring steps 2/3/4, where the citation is written and the
# matrix is locked. 27j/27k pin that as the INTENDED shipped scope: the
# provenance rule is a commit-gate property from Verify onward, and a plan
# carrying the barred literal commits freely while it is still being authored.
# This is deliberate rather than accidental — enforcing it at authoring time
# means the governing-skill hook's Write gate, which is a deferred candidate
# and not this wave's. If that ever lands, these two cases are the ones that
# must be rewritten first, and the rewrite is the signal that the scope moved.
# Pointer body: steps 1-4 exit before any matrix validation, so the block only
# has to be non-empty and non-placeholder.
prov_pointer_body="  plan-doc: .bionic/docs/plans/wave-01.plan.md"

# 27j — the barred literal at current: 3 commits clean.
h27j=$(make_home)
write_plan "$h27j" "$(plan 3 "$prov_pointer_body" "$(prov_matrix "implementation")")" > /dev/null

# 27k — and at current: 4, the last step before the gate.
h27k=$(make_home)
write_plan "$h27k" "$(plan 4 "$prov_pointer_body" "$(prov_matrix "implementation")")" > /dev/null

# ============================================================
# Section 28: matrix_block tolerates a markdown list leader
# ============================================================
#
# matrix_block() anchors each AC evidence block with index($0, "AC-n:")==1, so a
# header written as a markdown list item (`- AC-1:`) yielded an EMPTY block, and
# every behavior that reads that block went silent at once: the provenance arm
# saw no citation, the per-tier key loop saw no keys (blocking an otherwise
# conformant plan), the `waiver:` exemption never found its token, and the
# post-Verify CONFIRMED check lost that same exemption. Four behaviors, one
# extractor — so the list leader was a whole-contract bypass, not one arm's bug.
#
# The leader is stripped from a COPY of the line before the index test, which
# leaves two invariants intact: the block TERMINATOR (`/^[^[:space:]]/`) still
# reads the raw line, so a following list item still ends the previous block;
# and AC-1 still does not match the AC-11 block (28f). The strip accepts the
# three CommonMark bullet markers (`-`, `*`, `+`) plus at least one space, flush
# left — 28g/28h pin the two boundaries that stay invisible.

section "Section 28: matrix_block list-leader tolerance"

# T1's own evidence keys, satisfying the per-tier requirement.
leader_t1_keys="  tier-run: bash test.sh — unit suite
  fails-when: the planted defect this eval must go red on
  readback: 332/332 asserted"

# $1 = block-header leader ("" flush-left, "- ", "* ", …)
# $2 = the AC-1 block body (indented lines)
# $3 = the auditor cell value (default CONFIRMED; empty exercises the
#      post-Verify CONFIRMED check).
leader_matrix() {
  local leader="${1:-}" body="$2" aud="${3-CONFIRMED}"
  printf '## Verification Matrix\n\nstack-health: n/a: no long-running serve\n\n| AC | tier | status | evidence | auditor |\n|---|---|---|---|---|\n| AC-1 | T1 | discharged | see AC-1 | %s |\n\n%sAC-1:\n%s\n' \
    "$aud" "$leader" "$body"
}

# 28a — provenance arm: a list-leader block carrying the barred literal blocks
# exactly as a flush-left one does (27a is the flush-left twin).
h28a=$(make_home)
write_plan "$h28a" "$(plan 5 "$step5_base" "$(leader_matrix '- ' "$leader_t1_keys
  provenance: implementation")")" > /dev/null
expect_block "28a '- AC-1:' block with provenance: implementation → block" \
  "$h28a" 'git commit -m "x"' "provenance: implementation"

# 28b — per-tier keys: a list-leader block whose T1 evidence is complete must
# PASS. Before the strip this blocked on a missing key that was sitting in the
# plan the whole time — the shape that made every per-tier check vacuous.
h28b=$(make_home)
write_plan "$h28b" "$(plan 6 "$step6_body" "$(leader_matrix '- ' "$leader_t1_keys")")" > /dev/null

# 28c — waiver-token exemption: the `waiver:` entry lives in the AC block (not
# the evidence cell), so reading the block is the only way to find it. With the
# block visible the row is exempt from the per-tier keys and commits clean.
h28c=$(make_home)
write_plan "$h28c" "$(plan 5 "$step5_base" "$(leader_matrix '- ' "  waiver: dana 2026-08-01 env stale
  fails-when: the planted defect this eval must go red on")")" > /dev/null
# The `fails-when:` line is not part of 28c's subject — the block-side waiver is. It is here
# because that key is unconditional from `current: 4` (epic-22 K2): a waiver dissolves the
# obligation to RUN an eval, never the obligation to have designed one, so a waived row still
# names its failure. 37l pins that reading directly.
expect_allow "28c '- AC-1:' block whose only evidence entry is 'waiver:' → allow (block-side exemption found)" \
  "$h28c" 'git commit -m "x"'

# 28d — post-Verify CONFIRMED check: complete keys, NO waiver anywhere, auditor
# cell empty, at current: 6. The block must be visible for the gate to reach
# this check at all; the expected message is what discriminates, since the same
# plan blocked before the strip for the wrong reason (a missing evidence key).
h28d=$(make_home)
write_plan "$h28d" "$(plan 6 "$step6_body" "$(leader_matrix '- ' "$leader_t1_keys" '')")" > /dev/null
expect_block "28d '- AC-1:' block, keys complete, auditor cell empty at current: 6 → block on the verdict" \
  "$h28d" 'git commit -m "x"' "auditor verdict is 'empty'"

# 28e — the other bullet markers are the same list. An author reaching for `*`
# must not get a silently different parse from one reaching for `-`.
h28e=$(make_home)
write_plan "$h28e" "$(plan 5 "$step5_base" "$(leader_matrix '* ' "$leader_t1_keys
  provenance: implementation")")" > /dev/null
expect_block "28e '* AC-1:' block with provenance: implementation → block" \
  "$h28e" 'git commit -m "x"' "provenance: implementation"

# 28f — the AC-1/AC-11 disambiguation index() bought must survive the strip.
# AC-11's block comes FIRST and is the only one carrying the barred literal; if
# stripping had let AC-1 match the `- AC-11:` header, AC-1 would inherit that
# citation and the block would name row 'AC-1' instead.
h28f=$(make_home)
write_plan "$h28f" "$(plan 5 "$step5_base" "## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T1 | discharged | see AC-1 | CONFIRMED |
| AC-11 | T1 | discharged | see AC-11 | CONFIRMED |

- AC-11:
  fails-when: the planted defect this eval must go red on
$leader_t1_keys
  provenance: implementation
- AC-1:
  fails-when: the planted defect this eval must go red on
$leader_t1_keys
  provenance: spec §3")" > /dev/null
expect_block "28f '- AC-11:' before '- AC-1:' → AC-1 keeps its own block (AC-11 is the row that blocks)" \
  "$h28f" 'git commit -m "x"' "row 'AC-11' cites"

# 28g — pinned boundary: `-AC-1:` with no space after the dash is not a list
# item and stays invisible, so its keys are not found. The strip requires a
# separator; it is not a general "ignore leading punctuation".
h28g=$(make_home)
write_plan "$h28g" "$(plan 5 "$step5_base" "$(leader_matrix '-' "$leader_t1_keys")")" > /dev/null
expect_block "28g '-AC-1:' (no space) → block (pinned boundary: not a list item)" \
  "$h28g" 'git commit -m "x"' "missing evidence key"

# 28h — pinned boundary: an INDENTED list header stays invisible too. The block
# terminator is `/^[^[:space:]]/`, so an indented header would never end the
# preceding block; keeping the strip flush-left preserves that invariant.
h28h=$(make_home)
write_plan "$h28h" "$(plan 5 "$step5_base" "$(leader_matrix '  - ' "$leader_t1_keys")")" > /dev/null
expect_block "28h '  - AC-1:' (indented) → block (pinned boundary: strip is flush-left only)" \
  "$h28h" 'git commit -m "x"' "missing evidence key"

# ============================================================
# Section 29: Step 9 close-out contract (v14)
# ============================================================
#
# The v14 contract, ratified 2026-08-19 (epic-17 W5, design ledger D-A):
#
#   delivered:  ALWAYS. Every run has a terminal state — a PR open and ready
#               for a human to review, or commits landed locally ready to
#               push. Nothing past that boundary is the run's to claim.
#   deployed: / verified: / monitored:
#               owed EXACTLY when frontmatter names a live deploy_target.
#
# What died with v13: the trio was owed whenever a target existed, and `n/a:`
# discharged the step only at `deploy_target: none`. That rule encoded
# wave==release — the exception, not the rule — and it let a run with no live
# surface close by writing `n/a` instead of naming what it delivered.
#
# `deploy_target` itself is n/a by default and is never inferred (AC-3), so
# the trio is strictly opt-in: 29a/29e/29e2 are the ordinary run, 29c is the
# dogfood run that operates its own surface.
section "Section 29: Step 9 close-out contract (v14)"

# A plan at current: 9. $1 = deploy_target value, $2 = the Step-9 block body.
# Reuses Section 17's matrix_complete, since current: 9 revalidates the matrix
# as a prefix check before the step shape is ever reached.
ship_plan() {
  printf '%s\n## SDLC State\ncurrent: 9\napproved-by: fixture 2026-09-07T00:00Z approved\nStep 9:\n%s\n\n%s\n' \
    "$(frontmatter wave "$1")" "$2" "$matrix_complete"
}

ship_delivered="  delivered: PR #412 open and review-ready — 6 commits on wave/17-05"
ship_trio="  deployed: ./claude-bootstrap.sh rc=0 to this machine
  verified: installed hook spot-check reads SUPPORTED_SDLC_VERSION=14
  monitored: one Patrol cycle clean, no wall misfires"

# 29a — no live surface, `delivered:` present → allow. The default run's whole
# close-out obligation is this one line.
h29a=$(make_home)
write_plan "$h29a" "$(ship_plan none "$ship_delivered")" > /dev/null

# 29b — `delivered:` missing → block. The terminal state is not optional.
h29b=$(make_home)
write_plan "$h29b" "$(ship_plan none "  note: wrapped it up")" > /dev/null
expect_block "29b Step 9 without delivered: → block naming the key" \
  "$h29b" 'git commit -m "x"' "delivered"

# 29c — a named live surface: delivered + the full trio → allow.
h29c=$(make_home)
write_plan "$h29c" "$(ship_plan local-harness "$ship_delivered
$ship_trio")" > /dev/null

# 29d — a named live surface with `delivered:` only → block, naming what the
# named target owes.
h29d=$(make_home)
write_plan "$h29d" "$(ship_plan local-harness "$ship_delivered")" > /dev/null
expect_block "29d Step 9, deploy_target named, trio missing → block" \
  "$h29d" 'git commit -m "x"' "deployed"

# 29e — `deploy_target: n/a` is not a named surface (AC-3's default value), so
# the trio is not owed.
h29e=$(make_home)
write_plan "$h29e" "$(ship_plan n/a "$ship_delivered")" > /dev/null

# 29e2 — no `deploy_target` line at all reads the same way. An omission is
# never a named surface, so it can never conjure the trio into existence.
h29e2=$(make_home)
write_plan "$h29e2" "---
governing-skill: canonical-sdlc
canonical_sdlc_version: 14
intent: build
rigor: audited
scale: wave
use_worktree: false
has_ui: false
walk: exempt
---

## SDLC State
current: 9
approved-by: fixture 2026-09-07T00:00Z "approved"
Step 9:
$ship_delivered

$matrix_complete" > /dev/null

# 29f — the v13 shape (deploy:/verified-at:/monitor:) no longer discharges the
# step: it names a release and never names the delivery.
h29f=$(make_home)
write_plan "$h29f" "$(ship_plan none "  deploy: shipped to prod at 14:02
  verified-at: https://app.example/health
  monitor: one cycle clean")" > /dev/null
expect_block "29f Step 9 in the retired v13 shape → block on delivered" \
  "$h29f" 'git commit -m "x"' "delivered"

# 29g — `n/a:` was v13's escape at deploy_target: none. Under v14 there is
# nothing to escape: the run still has to name what it delivered.
h29g=$(make_home)
write_plan "$h29g" "$(ship_plan none "  n/a: nothing to deploy")" > /dev/null
expect_block "29g Step 9 with the retired 'n/a:' escape → block on delivered" \
  "$h29g" 'git commit -m "x"' "delivered"

# 29h — a run with no named target that deployed something anyway and said so
# is recording MORE than it owes, which is never a reason to refuse a commit.
# The trio is unowed here, not forbidden.
h29h=$(make_home)
write_plan "$h29h" "$(ship_plan none "$ship_delivered
$ship_trio")" > /dev/null

# ============================================================
# Section 30: T4 rows discharge on the user's own confirmation
# ============================================================
#
# THE BLIND SPOT THIS CLOSES. Past the Verify gate, every non-waived row must
# carry an auditor verdict of CONFIRMED. T4 is the tier whose evidence IS the
# user's confirmation — an independent agent auditing it can only re-read what
# the user said, which is not independence, it is transcription. So a
# legitimately user-confirmed T4 row had exactly one way past this arm: the
# Waiver Protocol. That recorded a waiver where nothing was waived. Epic-17 W4
# paid it in that form for its AC-7 and the row reads, permanently, as if the
# criterion had been let go.
#
# THE FIX. A T4 row whose AC block carries a well-formed
# `user-confirmed: <user> <date> <what>` discharges without a waiver. Nothing
# else moves: the tier's evidence key was always `user-confirmed` (keys_for_tier),
# and this arm now reads that same value as the discharge it already was.
#
# THE IMPOSTOR, AND THE HONEST LIMIT. The form check is an ATTRIBUTION check —
# a leading user token, an ISO date, and something said. An agent-shaped claim
# ("confirmed after re-render", "2026-08-18 the wall renders") carries no
# attributed human and is refused. What no hook can see is whether the named
# human actually said it; a fabricated `chris 2026-08-19 ...` passes the form.
# The form buys a record that names who and when — it does not buy honesty, and
# it is not sold as if it did.
section "Section 30: T4 rows discharge on user-confirmed, impostors do not"

# $1 = tier, $2 = auditor cell, $3 = the block's user-confirmed value.
t4_matrix() {
  printf '## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | %s | discharged | see AC-1 | %s |

AC-1:
  fails-when: the planted defect this eval must go red on
  user-confirmed: %s
  tier-run: rendered the wall in the live client
  fresh: rebuilt from the deployed payload
  cold-client: fresh session, no snapshot carryover
  contact: user opened it and read the text back
  readback: quoted the rendered literal verbatim\n' "$1" "$2" "$3"
}

GOOD_CONFIRM='chris 2026-08-18 read the rendered wall in his own client and confirmed the wording'

# 30a — the case the blind spot refused: a real user confirmation, no auditor
# verdict, no waiver → allow.
h30a=$(make_home)
write_plan "$h30a" "$(wave_plan 6 "$step6_body" "$(t4_matrix T4 "" "$GOOD_CONFIRM")")" > /dev/null

# 30b — an agent-shaped claim: no attributed human, no date. Still refused.
h30b=$(make_home)
write_plan "$h30b" "$(wave_plan 6 "$step6_body" \
  "$(t4_matrix T4 "" "confirmed by the implementor agent after the re-render")")" > /dev/null
expect_block "30b T4 + agent-shaped user-confirmed → block (no attributed user)" \
  "$h30b" 'git commit -m "x"' "CONFIRMED"

# 30c — a date with nobody attached is not an attribution either.
h30c=$(make_home)
write_plan "$h30c" "$(wave_plan 6 "$step6_body" \
  "$(t4_matrix T4 "" "2026-08-18 the wall renders as specified")")" > /dev/null
expect_block "30c T4 + dated but unattributed user-confirmed → block" \
  "$h30c" 'git commit -m "x"' "CONFIRMED"

# 30d — the exemption is T4-scoped. A T3 row cannot buy its way past the
# auditor by writing a user's name into its block: T3's evidence is a live
# reading an auditor CAN re-take independently, so the verdict still stands.
h30d=$(make_home)
write_plan "$h30d" "$(wave_plan 6 "$step6_body" "$(t4_matrix T3 "" "$GOOD_CONFIRM")")" > /dev/null
expect_block "30d T3 + well-formed user-confirmed → block (exemption is T4-only)" \
  "$h30d" 'git commit -m "x"' "CONFIRMED"

# 30e — no regression: a T4 row an auditor DID confirm still passes.
h30e=$(make_home)
write_plan "$h30e" "$(wave_plan 6 "$step6_body" "$(t4_matrix T4 CONFIRMED "$GOOD_CONFIRM")")" > /dev/null
expect_allow "30e T4 + CONFIRMED auditor cell → allow (unchanged)" \
  "$h30e" 'git commit -m "x"'

# 30f — pinned scope boundary: the form check lives in the post-Verify arm
# only. At current: 5 the row is still being discharged and the contract there
# is the one it always was — `user-confirmed` present, non-empty, not a
# placeholder. An impostor value passes the VERIFY gate and meets the form
# check on the 5->6 advance, which is where the authority claim is actually
# made. Widening the check to Step 5 would false-block mid-discharge commits
# on plans written before this contract existed.
h30f=$(make_home)
write_plan "$h30f" "$(wave_plan 5 "$step5_base" \
  "$(t4_matrix T4 CONFIRMED "confirmed by the implementor agent")")" > /dev/null
expect_allow "30f impostor at current: 5 → allow (form check is post-Verify only)" \
  "$h30f" 'git commit -m "x"'

# 30h — THE REFUTATION ARM (critic C-1, W5). The exemption above replaces the
# WAIVER FORM a user-confirmed row used to be paid in; it does not replace the
# AUDITOR. Those are different authorities and the design ratified only the
# first substitution. Written as a plain `elif` ahead of the verdict test, the
# arm let a T4 row carrying a well-formed `user-confirmed:` walk past an
# auditor's STANDING REFUTED — the one verdict in the vocabulary that is a
# positive finding rather than an absence, and the one this very wave produced
# three of on its first audit pass. So the exemption is scoped to an auditor
# cell that is EMPTY (nobody has ruled) or CONFIRMED (agreement): a refutation
# on the record meets the wall, and the refusal names the refutation rather
# than the attribution, because the attribution is fine and re-writing it is
# not the fix.
h30h=$(make_home)
write_plan "$h30h" "$(wave_plan 6 "$step6_body" "$(t4_matrix T4 REFUTED "$GOOD_CONFIRM")")" > /dev/null
expect_block "30h T4 + well-formed user-confirmed + auditor REFUTED → block" \
  "$h30h" 'git commit -m "x"' "REFUTED"

# 30i — UNVERIFIABLE is the auditor's other positive finding: it says the
# evidence could not be checked, which is not the same as nobody having looked.
# Same arm, same reason.
h30i=$(make_home)
write_plan "$h30i" "$(wave_plan 6 "$step6_body" "$(t4_matrix T4 UNVERIFIABLE "$GOOD_CONFIRM")")" > /dev/null
expect_block "30i T4 + well-formed user-confirmed + auditor UNVERIFIABLE → block" \
  "$h30i" 'git commit -m "x"' "UNVERIFIABLE"

# (30j — an arm asserting the refusal SENTENCE ("does not overturn") on the same
# fixture 30h already blocks on — deleted at epic-18 W1: its only failure mode
# was a reworded message.)

# 30k — and the positive twin, so the pair discriminates: the SAME row with the
# SAME confirmation and a CONFIRMED verdict passes. (30e proves the well-formed
# + CONFIRMED case at the top of this section; this arm is stated beside its
# refutation twin so a future edit that broke the agreement case would fail
# next to the one that proves the refusal.)
h30k=$(make_home)
write_plan "$h30k" "$(wave_plan 6 "$step6_body" "$(t4_matrix T4 CONFIRMED "$GOOD_CONFIRM")")" > /dev/null

# 30g — META-EVIDENCE, and the durable half of this section.
#
# 30b/30c/30d block against the PRE-fix hook too, for the old reason (no
# CONFIRMED verdict at all). A test that reads green on both sides of a change
# proves nothing about the change, so the impostor arms are re-run here against
# a DOCTORED hook whose attribution form check has been loosened to accept any
# non-empty value. If the form check is what refuses the impostor, 30b's
# fixture must ALLOW there. If it does not, the impostor arms above are
# passing on the missing-verdict rule and this section is decorative.
#
# The doctored copy lives in a temp dir and the real hook is never touched.
h30g_dir=$(mktemp -d); cleanup_dirs+=("$h30g_dir")
# Since 1.3.2 the gate reads commands through scripts/lib/git-argv.sh and
# REFUSES when it cannot load it (spec AC-12, Chris D1). A doctored copy alone
# in a bare temp dir therefore refuses everything for the wrong reason, so the
# copy gets the shipped layout around it: hooks/ beside scripts/lib/.
mkdir -p "$h30g_dir/hooks" "$h30g_dir/scripts/lib"
# Since bionic 1.4.0 the gate wants several libraries and the loader qualifies a directory
# only when it holds ALL of them (BIONIC_LIB_WANT). A fixture that plants a subset is a
# fixture that refuses everything for the wrong reason.
#
# THE WHOLE DIRECTORY, NOT A HAND-LIST (epic-22 wave-01, N1). This loop named four
# libraries by hand. That list went stale the moment lib/run.sh grew a soft source of
# lib/roots.sh — `docs_root` came back `command not found`, the gate fell through, and this
# section's mutation arm went GREEN against a hook that had allowed for the wrong reason.
# A hand-list of a shipped directory's contents is a second copy of that directory, kept by
# hand; the glob cannot drift.
for _h30g_cand in "${BIONIC_HOOKS_DIR}/../scripts/lib" \
                  "${BIONIC_HOOKS_DIR}/../payload/scripts/lib"; do
  if [ -d "$_h30g_cand" ]; then
    cp "$_h30g_cand"/*.sh "$h30g_dir/scripts/lib/" 2>/dev/null
    break
  fi
done
DOCTORED_HOOK="$h30g_dir/hooks/loose-gate.sh"
sed 's#user_confirmed_form_ok "\$block_txt"#[ -n "$(user_confirmed_value "$block_txt")" ]#' \
  "$HOOK" > "$DOCTORED_HOOK"

if ! diff -q "$HOOK" "$DOCTORED_HOOK" > /dev/null 2>&1; then
  ok "30g meta: the doctored copy differs from the real hook (mutation landed)"
else
  no "30g meta: the doctored copy differs from the real hook (mutation landed)" "the form-check mutation did not apply — the sed anchor moved, so the arms below prove nothing"
fi

_real_hook="$HOOK"
HOOK="$DOCTORED_HOOK"
# T4-scoping is a separate predicate from the form, so the T3 row must STILL
# block against the doctored hook — the tier arm is not what was loosened.
expect_block "30g meta: the T3 row still blocks under the loosened form (tier scope is a separate arm)" \
  "$h30d" 'git commit -m "x"' "CONFIRMED"
HOOK="$_real_hook"

# Restore-proof: the real hook still refuses the impostor after the detour.
expect_block "30g meta: the real hook still refuses the impostor after the mutation proof" \
  "$h30b" 'git commit -m "x"' "CONFIRMED"

# ============================================================
# Section 31: a refusal on a call that also writes the plan (B-6)
# ============================================================
#
# The gate reads the plan off disk when the CALL starts. So a single Bash call
# that edits the plan and then commits is judged against the PRE-EDIT plan: the
# fix the agent just wrote is invisible, and the refusal reads as though it had
# never been made. The observed reflex is to re-run the same combined call. When
# the refused command's text names the plan, the refusal now says so.

section "Section 31: refusal names the edit-then-commit split"

# 31a — a python3 heredoc writing the plan's absolute path, then a commit,
# refused by the matrix arm → the refusal carries the split line.
h31a=$(make_home)
p31a=$(write_plan "$h31a" "$(plan 6 "$step6_body" "$v101_matrix_pending")")
cmd31a=$(printf 'python3 - <<%s\nopen("%s","a").write("\\nAC-2:\\n  tier-run: x\\n")\nEOF\ngit commit -m "discharge AC-2"' "'EOF'" "$p31a")
expect_block "31a refusal on a call that also writes the plan → names the split" \
  "$h31a" "$cmd31a" "this command also writes the plan"

# 31a — the same refusal still names the row it refused (the note is an extra
# line, not a replacement).
expect_block "31a the split line does not displace the original refusal" \
  "$h31a" "$cmd31a" "AC-2"

# 31b — the project-relative spelling of the same path (what an agent actually
# types) is matched too.
h31b=$(make_home)
write_plan "$h31b" "$(plan 6 "$step6_body" "$v101_matrix_pending")" > /dev/null
expect_block "31b relative plan path in the command → names the split" \
  "$h31b" 'python3 -c "open('"'"'.bionic/docs/plans/active.md'"'"',\"a\")" && git commit -m "x"' \
  "this command also writes the plan"

# 31c — a refused commit that does NOT name the plan gets the ordinary 3-line
# refusal and no split line. Same fixture and same extractor as 31a, so this
# pins the note's scope rather than asserting an empty world.
run_hook "$h31a" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 2 ] \
   && grep -q "AC-2" <<<"$HOOK_STDERR" \
   && ! grep -q "also writes the plan" <<<"$HOOK_STDERR"; then
  ok "31c plain commit refusal carries no split line"
else
  no "31c plain commit refusal carries no split line" "expected a block naming AC-2 with NO split line; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

# 31d — the note rides on a refusal, never on its own: a command that names the
# plan but has nothing to refuse is still allowed silently.
h31d=$(make_home)
p31d=$(write_plan "$h31d" "$(plan 6 "$step6_body" "$matrix_complete")")
expect_allow "31d naming the plan in an otherwise-clean commit → allow, silent" \
  "$h31d" "python3 -c \"open('$p31d','a')\" && git commit -m \"x\""

# ============================================================
# Section 32: the auditor wall is rigor-keyed (B-10 / R-11)
# ============================================================
#
# SKILL.md's rigor table says `tested` skips BOTH independent assurance roles
# — "Self-review only." The gate read the matrix's auditor column
# unconditionally, so a `tested` run met a CONFIRMED wall for a verdict its own
# rigor says nobody was ever sent to write. B-10's repro: a bugfix · tested ·
# task run refused at `current: 9` on "matrix row 'AC-1' auditor verdict is
# 'empty', not CONFIRMED".
#
# The rule: at `tested` the matrix's auditor column is not read (any value —
# empty included — passes the post-Verify CONFIRMED arm at every step 6..9) and
# the Step-5 `auditor:` pointer is not demanded once the rows are discharged.
# At `peer-reviewed` and `audited` both walls are exactly as they were. An
# unknown or missing frontmatter `rigor:` takes the STRICT reading — fail
# closed, since a plan that does not say what rigor it runs at has not bought
# the relaxation.
#
# The task-ledger side (apply_rigor_lanes) was already rigor-keyed; 32f/32k pin
# it as B-10's mirror so the two surfaces cannot drift apart.

section "Section 32: the auditor wall is rigor-keyed"

# A wave plan at a caller-chosen frontmatter rigor. Same shape as
# matrix_frontmatter (walk: exempt, deploy_target: none, no multi_agent — so the
# walk arm and the dispatch ledger stay out of the way), with `rigor` as the one
# variable. Pass an empty string for $1 to omit the key entirely.
plan_rigor() {  # $1 rigor (empty = key absent)  $2 current  $3 step body  $4 matrix
  printf -- '---\n'
  printf -- 'governing-skill: canonical-sdlc\n'
  printf -- 'canonical_sdlc_version: 14\n'
  printf -- 'intent: build\n'
  [ -n "$1" ] && printf -- 'rigor: %s\n' "$1"
  printf -- 'scale: wave\n'
  printf -- 'deploy_target: none\n'
  printf -- 'use_worktree: false\n'
  printf -- 'has_ui: true\n'
  printf -- 'walk: exempt\n'
  printf -- '---\n'
  printf -- '## SDLC State\ncurrent: %s\napproved-by: fixture 2026-09-07T00:00Z approved\nStep %s:\n%s\n\n%s\n' "$2" "$2" "$3" "$4"
}

# Every row discharged, every per-tier key present, EVERY AUDITOR CELL EMPTY.
# The only thing standing between this matrix and a clean commit is the
# CONFIRMED arm, so each verdict below is that arm's doing.
m32_empty_aud="## Verification Matrix

stack-health: process restarts 0 → 0 across walk; no crash/OOM state change

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T1 | discharged | see AC-1 |  |
| AC-2 | T1 | discharged | see AC-2 |  |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: bash tests/canonical-sdlc-evidence-gate.test.sh
  readback: 120/120 asserted
AC-2:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh — unit suite
  readback: 332/332 asserted"

# The same matrix carrying a STANDING REFUTED verdict. At tested the column is
# not read at all, so this passes too — the relaxation is "the column is not a
# gate", not "an empty cell is tolerated".
m32_refuted="${m32_empty_aud/| AC-1 | T1 | discharged | see AC-1 |  |/| AC-1 | T1 | discharged | see AC-1 | REFUTED |}"

# The same matrix with AC-2's `readback:` key removed. The rest of the matrix
# contract is untouched by B-10, so this must still block at tested — the
# discrimination control for every 32a..32d allow.
m32_missing_key="${m32_empty_aud/  readback: 332\/332 asserted/  fixture-fidelity: n\/a}"

# Step-5 tests floor with NO `auditor:` pointer.
step5_noaud="  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5"

# ---- AC-26: at `tested` the wall is not there ------------------------------

# 32a..32d — the post-Verify CONFIRMED arm is a prefix contract at 6, 7, 8 and
# 9 (dispatch()); B-10's own repro was at 9, so all four steps are pinned. The
# 7/8/9 step bodies are Section 17r's, which their own validators pin already.
h32a=$(make_home)
write_plan "$h32a" "$(plan_rigor tested 6 "$step6_body" "$m32_empty_aud")" > /dev/null
expect_allow "32a rigor tested, rows discharged, auditor cells empty, current 6 → allow" \
  "$h32a" 'git commit -m "x"'

h32b=$(make_home)
write_plan "$h32b" "$(plan_rigor tested 7 "$v9_step7_body" "$m32_empty_aud")" > /dev/null
expect_allow "32b same at current 7 → allow" "$h32b" 'git commit -m "x"'

h32c=$(make_home)
write_plan "$h32c" "$(plan_rigor tested 8 "$v9_step8_body" "$m32_empty_aud")" > /dev/null
expect_allow "32c same at current 8 → allow" "$h32c" 'git commit -m "x"'

h32d=$(make_home)
write_plan "$h32d" "$(plan_rigor tested 9 "$v9_step9_body" "$m32_empty_aud")" > /dev/null
expect_allow "32d same at current 9 → allow (B-10's own repro step)" \
  "$h32d" 'git commit -m "x"'

# 32e — the Step-5 `auditor:` pointer is the same wall one step earlier: it is
# demanded once no row is pending. At tested there is no auditor to point at.
h32e=$(make_home)
write_plan "$h32e" "$(plan_rigor tested 5 "$step5_noaud" "$m32_empty_aud")" > /dev/null
expect_allow "32e rigor tested, all rows discharged, no Step-5 auditor: pointer → allow" \
  "$h32e" 'git commit -m "x"'

# 32f — the task-ledger mirror (AC-26, second half): a `done` row at tested
# whose evidence names no auditor verdict commits.
v32f_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | tested | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: reproduced and fixed the boundary case
- T2: fixed enum check, bash suite 12/12"
h32f=$(make_home)
write_plan "$h32f" "$(task_plan_rigor tested "$v32f_body")" > /dev/null
expect_allow "32f task scale: done row at tested with no auditor verdict → allow" \
  "$h32f" 'git commit -m "x"'

# 32n — the column is not READ at tested, not merely tolerated when empty: a
# standing REFUTED verdict passes too. Pinned deliberately (it is the sharpest
# statement of the rule, and the case a narrower fix would get wrong).
h32n=$(make_home)
write_plan "$h32n" "$(plan_rigor tested 6 "$step6_body" "$m32_refuted")" > /dev/null
expect_allow "32n rigor tested, a REFUTED auditor cell at current 6 → allow (column unread)" \
  "$h32n" 'git commit -m "x"'

# 32o — discrimination control: everything ELSE the matrix demands still bites
# at tested. AC-2 (T1) is missing its `readback:` key on the same fixture family
# and at the same step, so 32a..32d are the auditor arm standing down and not
# the matrix going quiet.
h32o=$(make_home)
write_plan "$h32o" "$(plan_rigor tested 6 "$step6_body" "$m32_missing_key")" > /dev/null
expect_block "32o control: tested plan missing a per-tier key still blocks at current 6" \
  "$h32o" 'git commit -m "x"' "readback"

# ---- AC-27: at peer-reviewed and audited the wall is unchanged -------------

h32g=$(make_home)
write_plan "$h32g" "$(plan_rigor audited 6 "$step6_body" "$m32_empty_aud")" > /dev/null
expect_block "32g the same fixture at rigor audited, current 6 → block (CONFIRMED)" \
  "$h32g" 'git commit -m "x"' "auditor verdict is 'empty', not CONFIRMED"

h32h=$(make_home)
write_plan "$h32h" "$(plan_rigor peer-reviewed 6 "$step6_body" "$m32_empty_aud")" > /dev/null
expect_block "32h the same fixture at rigor peer-reviewed, current 6 → block (CONFIRMED)" \
  "$h32h" 'git commit -m "x"' "auditor verdict is 'empty', not CONFIRMED"

# 32i/32j — the Step-5 pointer half of AC-27.
h32i=$(make_home)
write_plan "$h32i" "$(plan_rigor audited 5 "$step5_noaud" "$m32_empty_aud")" > /dev/null
expect_block "32i rigor audited, discharged rows, no Step-5 auditor: pointer → block" \
  "$h32i" 'git commit -m "x"' "requires 'auditor:"

h32j=$(make_home)
write_plan "$h32j" "$(plan_rigor peer-reviewed 5 "$step5_noaud" "$m32_empty_aud")" > /dev/null
expect_block "32j rigor peer-reviewed, discharged rows, no Step-5 auditor: pointer → block" \
  "$h32j" 'git commit -m "x"' "requires 'auditor:"

# 32k — a row whose OWN rigor cell RAISES it above the plan's frontmatter
# follows the row's rigor (the floor model, slice 4/8): a tested plan, one
# `done` row raised to peer-reviewed, proof-shaped evidence naming no auditor →
# that row still demands the verdict. The relaxation is keyed to effective
# rigor, never to the frontmatter alone.
v32k_body="## Tasks

| id | intent | rigor | description | status |
|---|---|---|---|---|
| T1 | bugfix | peer-reviewed | fix the frontmatter parser | done |
| T2 | bugfix | tested | fix enum | active |

## SDLC State

scale: task
current: T2

- T1: bash test.sh 12/12 green
- T2: fixed enum check, bash suite 12/12"
h32k=$(make_home)
write_plan "$h32k" "$(task_plan_rigor tested "$v32k_body")" > /dev/null
expect_block "32k task scale: tested plan, one row raised to peer-reviewed, no auditor → block" \
  "$h32k" 'git commit -m "x"' "no 'auditor' verdict"

# ---- fail-closed on an unknown or missing rigor ----------------------------

# 32l — no `rigor:` key at all. A plan that never says what rigor it runs at
# has not bought the relaxation, so the strict reading holds.
h32l=$(make_home)
write_plan "$h32l" "$(plan_rigor "" 6 "$step6_body" "$m32_empty_aud")" > /dev/null
expect_block "32l frontmatter with NO rigor key at current 6 → block (fail closed)" \
  "$h32l" 'git commit -m "x"' "not CONFIRMED"

# 32m — an off-enum value reads the same way; a typo must not become a bypass
# (same rationale as walk_mode's off-enum arm).
h32m=$(make_home)
write_plan "$h32m" "$(plan_rigor reviewed 6 "$step6_body" "$m32_empty_aud")" > /dev/null
expect_block "32m off-enum rigor 'reviewed' at current 6 → block (a typo is not a bypass)" \
  "$h32m" 'git commit -m "x"' "not CONFIRMED"

# 32m2 — and the Step-5 pointer half fails closed too.
h32m2=$(make_home)
write_plan "$h32m2" "$(plan_rigor "" 5 "$step5_noaud" "$m32_empty_aud")" > /dev/null
expect_block "32m2 no rigor key at current 5, no auditor: pointer → block (fail closed)" \
  "$h32m2" 'git commit -m "x"' "requires 'auditor:"

# ============================================================
# Section 33: a waiver outranks the `slice: 9` tier refusal (review-a C-2)
# ============================================================
#
# The `slice: 9` tag (Section 17r) is T0-only: on any other tier it is a
# mis-tag, and the refusal fires at every step. That check sat ABOVE the
# `waiver:` exemption in the row loop, so a row an author had WAIVED — the
# criterion let go, its evidence contract dissolved — still met the tier
# refusal, and the only way past it was to retier a row nobody intends to
# discharge. A waiver outranks every other per-row demand in this loop (the
# per-tier keys, the CONFIRMED wall); it outranks this one too.
#
# The waiver test is the loop's existing one — a `waiver:` token in the
# evidence cell or a `waiver:` line in the AC block — so "waived" means the
# same thing here as it does for the per-tier keys three lines below.

section "Section 33: a waiver outranks the slice: 9 tier refusal"

# A T1 row (not T0, so the tag is a mis-tag) carrying `slice: 9`, WAIVED via
# the evidence cell. AC-1 is an ordinary discharged row so the matrix is
# otherwise complete and each verdict below is the waived row's doing.
m33_waived="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T1 | discharged | see AC-1 | CONFIRMED |
| AC-2 | T1 | waived | waiver: dana 2026-08-30 criterion dropped | waived |

AC-1:
  fails-when: the planted defect this eval must go red on
  tier-run: bash test.sh — unit suite
  readback: 332/332 asserted
AC-2:
  fails-when: the planted defect this eval must go red on
  slice: 9"

# The same row with the waiver taken away: pending, no token anywhere.
m33_unwaived="${m33_waived/| AC-2 | T1 | waived | waiver: dana 2026-08-30 criterion dropped | waived |/| AC-2 | T1 | pending | see AC-2 |  |}"

# The waiver in the AC BLOCK rather than the evidence cell — the loop's other
# spelling of the same fact.
m33_waived_block="${m33_waived/| AC-2 | T1 | waived | waiver: dana 2026-08-30 criterion dropped | waived |/| AC-2 | T1 | waived | dropped, see block | waived |}"
m33_waived_block="${m33_waived_block/  slice: 9/  slice: 9
  waiver: dana 2026-08-30 criterion dropped}"

# 33a — waived T1 row carrying slice: 9 → commits.
h33a=$(make_home)
write_plan "$h33a" "$(plan 6 "$step6_body" "$m33_waived")" > /dev/null
expect_allow "33a waived T1 row carrying 'slice: 9' at current 6 → allow (waiver outranks)" \
  "$h33a" 'git commit -m "x"'

# 33b — the same row UNWAIVED still blocks on the mis-tag, so 33a is the
# waiver's doing and not the tier refusal having been deleted.
h33b=$(make_home)
write_plan "$h33b" "$(plan 6 "$step6_body" "$m33_unwaived")" > /dev/null
expect_block "33b control: the same T1 row unwaived still blocks on the mis-tag" \
  "$h33b" 'git commit -m "x"' "only a T0 row defers its evidence to the close-out"

# 33c — the block-line spelling of the waiver reads the same way.
h33c=$(make_home)
write_plan "$h33c" "$(plan 6 "$step6_body" "$m33_waived_block")" > /dev/null
expect_allow "33c the waiver as an AC-block line (not the evidence cell) → allow too" \
  "$h33c" 'git commit -m "x"'

# 33d — scope control: the waiver exempts the row from the TIER refusal, not
# from the loop's unconditional arms. The same waived row with a circular
# `provenance: implementation` still blocks — the provenance arm sits above
# both, deliberately, and this fix did not move it.
m33_waived_prov="${m33_waived/AC-2:
  fails-when: the planted defect this eval must go red on
  slice: 9/AC-2:
  fails-when: the planted defect this eval must go red on
  slice: 9
  provenance: implementation}"
h33d=$(make_home)
write_plan "$h33d" "$(plan 6 "$step6_body" "$m33_waived_prov")" > /dev/null
expect_block "33d control: a waived row still meets the provenance arm above it" \
  "$h33d" 'git commit -m "x"' "provenance: implementation"

# ============================================================
# Section 34: the session never invoked the skill (AC-6)
# ============================================================
#
# THE PAIRED WORLD for every section above. Chris, 2026-09-03: "all guardrails imposed
# by bionic should only apply when exercising bionic. Nothing should apply until bionic
# is triggered." The trigger is the canonical-sdlc skill and the record of it is
# `.bionic/tmp/engaged-<sid>.state` under the project root; every fixture above carries
# one because every fixture above describes a run somebody started. Take it away and this
# gate is not quieter, it is absent: exit 0, nothing on stdout, nothing on stderr.
#
# EACH ARM IS A COMMIT THIS GATE REFUSES TWO LINES LATER, on the identical fixture with
# the marker restored — the control is what stops the whole section passing on a gate
# that had simply stopped working.
#
# THE ORDERING CONTRACT IS UNCHANGED BY THIS. Plan hygiene still sits above the run
# predicate, so an ENGAGED session committing against a malformed plan is still refused
# whether or not a run is open (34b's control). What the guard adds is prior to both
# questions, not a fourth clause inside either.

section "Section 34: no engagement marker — the gate is not there at all"

# Captures stdout as well as stderr and the exit code: "silent" here means all three.
run_hook_full() {  # <home> <command> -> S34_EXIT / S34_OUT / S34_ERR
  local home_dir="$1" command="$2" input tmp_err tmp_out
  input=$(jq -n --arg c "$command" --arg cwd "$home_dir" --arg s "$EG_SID" \
            '{session_id: $s, tool_input: {command: $c}, cwd: $cwd}')
  tmp_err=$(mktemp); tmp_out=$(mktemp)
  if HOME="$home_dir" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="$EG_SID" \
       bash "$HOOK" <<< "$input" >"$tmp_out" 2>"$tmp_err"; then
    S34_EXIT=0
  else
    S34_EXIT=$?
  fi
  S34_OUT=$(cat "$tmp_out"); S34_ERR=$(cat "$tmp_err")
  rm -f "$tmp_err" "$tmp_out"
}

expect_silent() {  # <label> — asserts on the last run_hook_full
  if [ "$S34_EXIT" -eq 0 ] && [ -z "$S34_OUT" ] && [ -z "$S34_ERR" ]; then
    ok "$1"
  else
    no "$1" "expected exit 0 and total silence; got exit=$S34_EXIT stdout='$S34_OUT' stderr='$S34_ERR'"
  fi
}

expect_refused() {  # <label> — the control: the SAME fixture, marker restored
  expect_eq "$1" 2 "$S34_EXIT"
}

# --- 34a: an open run whose current step has no evidence — the gate's core refusal ---
h34a=$(make_home)
write_plan "$h34a" "$(plan 5 "" "$matrix_complete")" > /dev/null
unengage "$h34a"
run_hook_full "$h34a" 'git commit -m "x"'
expect_silent "34a an empty Step 5 line passes an unengaged session"
engage "$h34a"
run_hook_full "$h34a" 'git commit -m "x"'
expect_refused "34a control: the same commit, marker restored, is REFUSED"

# --- 34b: PLAN HYGIENE, the half that sits ABOVE the run predicate ---
# A plan with no readable `current:` is refused whether or not a run is open, because a
# plan that lies is a defect in every state. That refusal is owed to an ENGAGED session
# and to nobody else.
h34b=$(make_home)
printf -- '---\ngoverning-skill: canonical-sdlc\ncanonical_sdlc_version: 14\nintent: build\nrigor: tested\nscale: wave\n---\n\n## SDLC State\ncurrent: banana\n' \
  > "$h34b/.bionic/docs/plans/active.md"
touch "$h34b/.bionic/docs/plans/active.md"
unengage "$h34b"
run_hook_full "$h34b" 'git commit -m "x"'
expect_silent "34b a malformed 'current:' passes an unengaged session"
engage "$h34b"
run_hook_full "$h34b" 'git commit -m "x"'
expect_refused "34b control: plan hygiene still refuses the ENGAGED session"

# --- 34c: the misplacement sweep, which needs no open run either ---
h34c=$(make_home)
p34c=$(mktemp -d); cleanup_dirs+=("$p34c")
mkdir -p "$p34c/docs/bionic/plans/epic-01-demo"
s24_marked_plan > "$p34c/docs/bionic/plans/epic-01-demo/wave-01-x.plan.md"
run_hook_with_project "$h34c" "$p34c" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
  ok "34c the misplacement sweep does not fire in an unengaged session"
else
  no "34c the misplacement sweep does not fire in an unengaged session" "expected allow; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi
engage "$p34c"
run_hook_with_project "$h34c" "$p34c" 'git commit -m "x"'
if [ "$HOOK_EXIT" -eq 2 ] && grep -q "misplaced" <<<"$HOOK_STDERR"; then
  ok "34c control: the same tree, marker planted, is REFUSED as misplaced"
else
  no "34c control: the same tree, marker planted, is REFUSED as misplaced" "expected block; exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
fi

# --- 34d: the shapes that are NOT engagement, on a fixture that otherwise refuses ---
h34d=$(make_home)
write_plan "$h34d" "$(plan 5 "" "$matrix_complete")" > /dev/null

# A SYMLINK at the marker path is refused before it is followed (lib/run.sh), so a link
# into an engaged tree cannot open this gate from outside it.
unengage "$h34d"
ln -s "$h34a/.bionic/tmp/engaged-$EG_SID.state" "$h34d/.bionic/tmp/engaged-$EG_SID.state"
run_hook_full "$h34d" 'git commit -m "x"'
expect_silent "34d a SYMLINK at the marker path is not engagement"
rm -f "$h34d/.bionic/tmp/engaged-$EG_SID.state"

# ANOTHER SESSION'S marker is not this session's: the path interpolates the key.
: > "$h34d/.bionic/tmp/engaged-99999999-8888-7777-6666-555555555555.state"
run_hook_full "$h34d" 'git commit -m "x"'
expect_silent "34d another session's marker is not engagement"

# A DIRECTORY at the marker path is not a regular file.
mkdir -p "$h34d/.bionic/tmp/engaged-$EG_SID.state"
run_hook_full "$h34d" 'git commit -m "x"'
expect_silent "34d a DIRECTORY at the marker path is not engagement"
rmdir "$h34d/.bionic/tmp/engaged-$EG_SID.state"

# ============================================================
# Section 35: THE SESSION'S OWN RUN (wave-session-bound-run, AC-1/AC-3/AC-6)
# ============================================================
#
# Until 2026-09-04 this gate answered "which run am I in" by scanning the project root
# for the newest plan carrying `## SDLC State`. Two engaged sessions in one repository
# therefore shared one run identity: a commit from EITHER was measured against whichever
# plan was newest, so the second session's own evidence was never the evidence checked.
# The resolution is session-keyed now — lib/run.sh's `session_run` reads the `plan=`
# field hooks/engage.sh has written into `engaged-<sid>.state` since 1.4.1 and nothing
# read — and both of this hook's resolution sites take its verdict.
#
# EVERY FIXTURE HERE IS ONE ROOT WITH TWO OPEN PLANS, and that is the point: it is the
# only shape in which the old rule and the new one disagree. A one-plan root cannot tell
# them apart, so a section built on one would pass under either and prove nothing.
#
# THE TWO DIRECTIONS ARE BOTH DRIVEN (35a and 35b). "The bound session is gated on its
# own plan" is only half an assertion if the bound plan is also the newest one — the old
# rule agrees there. 35b swaps which plan carries the evidence, so the bound session
# blocks on the OLDER plan while the newest one is clean, which the old rule cannot do.

section "Section 35: two sessions, two plans, one root"

S35_SID_A="a1111111-2222-3333-4444-555555555555"
S35_SID_B="b6666666-7777-8888-9999-000000000000"

# A root that doubles as the sandbox HOME, the same trick make_home plays: the runner
# posts cwd=<root>, so PROJECT_DIR resolves there and the docs root is <root>/.bionic/docs.
s35_root() {
  local dir
  dir=$(mktemp -d)
  cleanup_dirs+=("$dir")
  # CANONICALISED, for the reason audit_file_for records: the hook resolves its root
  # through lib/root.sh, which answers with `pwd -P`, while macOS hands `mktemp -d` back a
  # path under the /var -> /private/var symlink unresolved. Every assertion below matches
  # an announced path CHARACTER FOR CHARACTER, so a fixture holding the other spelling of
  # one directory would fail on the prefix and pass on any substring — which is exactly
  # what a `/var/...` needle does against a `/private/var/...` haystack.
  dir=$(cd "$dir" && pwd -P)
  mkdir -p "$dir/.claude/plans" "$dir/.bionic/docs/plans" "$dir/.bionic/tmp"
  echo "$dir"
}

# THE MARKER'S EXACT TWO-LINE SHAPE, hooks/engage.sh:287 — `plan=<path>` then
# `engaged_at=<iso>`, mode 600, written by the real `bind_plan` (S11,
# tests/lib/bound-marker.sh; spec AC-24). A fixture that invented a one-line marker
# would be testing a file no writer in the fleet produces.
s35_bind() {  # <root> <sid> <plan path>
  bound_marker "$1" "$2" "$3"
}

# The three shapes that are NOT a binding, all of which the fleet really produces: an
# EMPTY marker (tests/session-poker.test.sh:82 plants one, and every `engage` in THIS
# suite writes one), the literal `plan=none` (what engagement writes when the root holds
# zero or several open runs), and a marker carrying no `plan=` line at all.
s35_unbind() {  # <root> <sid> [empty|none|nofield]
  unbound_marker "$1" "$2" "${3:-empty}"
}

# Two open plans, structurally identical except for WHICH ONE carries the current step's
# evidence — the one variable this section turns. Sets S35_A and S35_B.
s35_two_plans() {  # <root> <a|b: which plan carries the evidence>
  local root="$1" with="$2" a_body="" b_body=""
  case "$with" in
    a) a_body="$step6_body" ;;
    b) b_body="$step6_body" ;;
  esac
  S35_A="$root/.bionic/docs/plans/wave-a.plan.md"
  S35_B="$root/.bionic/docs/plans/wave-b.plan.md"
  printf '%s\n' "$(plan 6 "$a_body" "$matrix_complete")" > "$S35_A"
  printf '%s\n' "$(plan 6 "$b_body" "$matrix_complete")" > "$S35_B"
  # B IS THE NEWEST, by an hour rather than a filesystem tick: `active_plan` orders by
  # mtime, and two plans written in the same second make the OLD rule's answer a coin
  # toss — which would make every fallback assertion below flap instead of fail.
  touch -t 202609040000 "$S35_A"
  touch -t 202609040100 "$S35_B"
}

# Runs the hook AS a named session. Unlike run_hook this keeps stderr WHOLE: the
# resolution announcements are this section's subject, not noise to filter past.
s35_run() {  # <root> <sid> <command> -> S35_EXIT / S35_ERR
  local root="$1" sid="$2" command="$3" input tmp_err
  input=$(jq -n --arg c "$command" --arg cwd "$root" --arg s "$sid" \
            '{session_id: $s, tool_input: {command: $c}, cwd: $cwd}')
  tmp_err=$(mktemp)
  if HOME="$root" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="$sid" \
       bash "$HOOK" <<< "$input" >/dev/null 2>"$tmp_err"; then
    S35_EXIT=0
  else
    S35_EXIT=$?
  fi
  S35_ERR=$(cat "$tmp_err")
  rm -f "$tmp_err"
}

# <label> <expected exit> <substring stderr MUST carry, or -> <substring it must NOT, or ->
s35_assert() {
  local label="$1" want="$2" yes="$3" nope="$4" why=""
  [ "$S35_EXIT" = "$want" ] || why="exit=$S35_EXIT want=$want"
  if [ -z "$why" ] && [ "$yes" != "-" ] && ! grep -qF -- "$yes" <<< "$S35_ERR"; then
    why="stderr is missing '$yes'"
  fi
  if [ -z "$why" ] && [ "$nope" != "-" ] && grep -qF -- "$nope" <<< "$S35_ERR"; then
    why="stderr carries '$nope' and must not"
  fi
  if [ -z "$why" ]; then
    ok "$label"
  else
    no "$label" "$why stderr='$S35_ERR'"
  fi
}

# --- 35a AC-1: each session is gated on its OWN plan (the evidence is on A) ---
r35a=$(s35_root)
s35_two_plans "$r35a" a
s35_bind "$r35a" "$S35_SID_A" "$S35_A"
s35_bind "$r35a" "$S35_SID_B" "$S35_B"

s35_run "$r35a" "$S35_SID_A" 'git commit -m "x"'
s35_assert "35a session A, bound to the plan that carries its evidence → allow" 0 - "BLOCKED"

s35_run "$r35a" "$S35_SID_B" 'git commit -m "x"'
s35_assert "35a session B, same tree same commit, bound to the plan with none → BLOCKED on B" \
  2 "$S35_B" "$S35_A"

# --- 35b AC-1, THE INVERSE: swap which plan carries the evidence ---
# The old newest-plan rule allows session A's commit here (the newest plan is clean) and
# blocks session B's (its own plan is not the one read). Both rows below are its mirror.
r35b=$(s35_root)
s35_two_plans "$r35b" b
s35_bind "$r35b" "$S35_SID_A" "$S35_A"
s35_bind "$r35b" "$S35_SID_B" "$S35_B"

s35_run "$r35b" "$S35_SID_A" 'git commit -m "x"'
s35_assert "35b inverse: session A blocks on its OWN older plan while the newest is clean" \
  2 "$S35_A" "$S35_B"

s35_run "$r35b" "$S35_SID_B" 'git commit -m "x"'
s35_assert "35b inverse: session B, bound to the newest plan that carries its evidence → allow" \
  0 - "BLOCKED"

# --- 35c AC-3: no binding → newest-plan exactly as today, and the hook says so ---
for s35_shape in empty none nofield; do
  r35c=$(s35_root)
  s35_two_plans "$r35c" a          # the evidence is on A, so the NEWEST plan has none
  s35_unbind "$r35c" "$S35_SID_A" "$s35_shape"
  s35_run "$r35c" "$S35_SID_A" 'git commit -m "x"'
  s35_assert "35c unbound ($s35_shape) → gated on the NEWEST plan, exactly as today" \
    2 "$S35_B" "$S35_A"
  s35_assert "35c unbound ($s35_shape) → and the fallback resolution is announced" \
    2 "evidence-gate: run resolved by newest-plan fallback (session unbound) — $S35_B" -
done

# THE NEGATIVE BESIDE THE POSITIVE: a BOUND session announces no fallback, because it
# did not use one. Without this row the announcement could be unconditional and every
# assertion above would still pass.
r35c2=$(s35_root)
s35_two_plans "$r35c2" a
s35_bind "$r35c2" "$S35_SID_A" "$S35_A"
s35_run "$r35c2" "$S35_SID_A" 'git commit -m "x"'
s35_assert "35c control: a BOUND session announces no fallback" 0 - "newest-plan fallback"

# --- 35d AC-6: a binding to a CLOSED plan is engaged-with-no-run, never a fall-through ---
r35d=$(s35_root)
s35_two_plans "$r35d" a            # B is newest, open, and carries no evidence
S35_D="$r35d/.bionic/docs/plans/wave-delivered.plan.md"
printf '%s\n## SDLC State\ncurrent: 9\napproved-by: fixture 2026-09-07T00:00Z approved\n- Step 9: delivered: .bionic/docs/record/x.md\n\n%s\n' \
  "$(matrix_frontmatter true)" "$matrix_complete" > "$S35_D"
touch -t 202609040030 "$S35_D"
s35_bind "$r35d" "$S35_SID_A" "$S35_D"
s35_run "$r35d" "$S35_SID_A" 'git commit -m "x"'
s35_assert "35d bound to a DELIVERED plan → this session has no open run: allow" 0 - "BLOCKED"
s35_assert "35d …and the reason is named, with the closed plan's own path" \
  0 "evidence-gate: bound plan closed — $S35_D; this session has no open run" -
s35_assert "35d …and the OPEN plan beside it is never read" 0 - "$S35_B"

# The control: the same tree and the same commit from an UNBOUND session IS gated on the
# newest open plan. Without it 35d's silence could be a gate that had simply stopped.
s35_unbind "$r35d" "$S35_SID_B" empty
s35_run "$r35d" "$S35_SID_B" 'git commit -m "x"'
s35_assert "35d control: the same tree, an UNBOUND session, is gated on the newest open plan" \
  2 "$S35_B" -

# --- 35f AC-1 at the OTHER site: the run predicate is the session's too ---
# 35a and 35b turn the site that picks the file to VALIDATE; both of their plans are open,
# so the site that decides whether a run is live agrees under either rule and is not under
# test there. Here the session's own plan is open and the root's NEWEST plan is delivered,
# which is the shape where the two sites disagree: the old root-keyed predicate reads the
# root as having no run at all and waves the commit through, while the session in fact has
# an open run with no evidence for its current step.
r35f=$(s35_root)
S35_FO="$r35f/.bionic/docs/plans/wave-open.plan.md"
S35_FD="$r35f/.bionic/docs/plans/wave-shipped.plan.md"
printf '%s\n' "$(plan 6 "" "$matrix_complete")" > "$S35_FO"
printf '%s\n## SDLC State\ncurrent: 9\napproved-by: fixture 2026-09-07T00:00Z approved\n- Step 9: delivered: .bionic/docs/record/x.md\n\n%s\n' \
  "$(matrix_frontmatter true)" "$matrix_complete" > "$S35_FD"
touch -t 202609040000 "$S35_FO"
touch -t 202609040100 "$S35_FD"
s35_bind "$r35f" "$S35_SID_A" "$S35_FO"
s35_run "$r35f" "$S35_SID_A" 'git commit -m "x"'
s35_assert "35f bound to an OPEN plan under a DELIVERED newest one → the session's run is live: BLOCKED" \
  2 "$S35_FO" "$S35_FD"

# The control, and it is the old rule stated as a fact: over the same tree a session with
# no binding sees a root whose newest plan is delivered, so there is no run to enforce.
s35_unbind "$r35f" "$S35_SID_B" empty
s35_run "$r35f" "$S35_SID_B" 'git commit -m "x"'
s35_assert "35f control: unbound over the same tree reads the root as closed and allows" \
  0 - "BLOCKED"

# --- 35e AC-6, the vanished plan: a binding outlives the file it names ---
r35e=$(s35_root)
s35_two_plans "$r35e" a
S35_GONE="$r35e/.bionic/docs/plans/wave-gone.plan.md"
s35_bind "$r35e" "$S35_SID_A" "$S35_GONE"
s35_run "$r35e" "$S35_SID_A" 'git commit -m "x"'
s35_assert "35e bound to a plan that no longer exists → closed, not a fall-through" \
  0 "evidence-gate: bound plan closed — $S35_GONE" -
s35_assert "35e …and the OPEN plan beside it is never read" 0 - "$S35_B"

# --- 35g the vanished plan meets the MISPLACEMENT SWEEP (S10a, critic C-1) ---
#
# 35e above proves a binding to a deleted plan reads as closed and allows. It passes on a
# root that happens to hold no stray `*.plan.md`, and that is the whole of the defect: the
# sweep's guard was `[ -z "$PLAN" ] || [ ! -f "$PLAN" ]`, so a bound-but-missing plan walked
# into the depth-5 project-wide sweep six hundred lines before the `bound-closed → exit 0`
# escape, and any unrelated stray plan in the project turned every commit from that session
# into a block naming a file that has nothing to do with it.
#
# PRE-WAVE THIS WAS UNREACHABLE. `PLAN` came from `active_plan`, which reports only files
# `find -type f` just produced, so `[ ! -f "$PLAN" ]` could not be true with `$PLAN` set. A
# bound path is the first `PLAN` in this hook's history that can name a file that is not
# there while the docs root holds a perfectly good plan.
#
# THREE SESSIONS, ONE TREE, and the tree is the point: the ONLY difference between them is
# the marker. A fix that simply disabled the sweep would fail 35g3.
#
# THE EVIDENCE SITS ON B, the newest, so both control arms resolve to a plan that is clean:
# `s35_two_plans "$r35g" a` would have the unbound fallback land on B and block for a reason
# that has nothing to do with this row (that is 35b's subject), and a control that blocks for
# the wrong reason proves nothing about the sweep.
r35g=$(s35_root)
s35_two_plans "$r35g" b
S35_GONE2="$r35g/.bionic/docs/plans/wave-gone.plan.md"
mkdir -p "$r35g/notes"
S35_STRAY="$r35g/notes/stray.plan.md"
printf -- '---\ncanonical_sdlc_version: 14\n---\n\n## SDLC State\n\ncurrent: 3\n' > "$S35_STRAY"

# NON-VACUITY: the stray really is a plan this sweep would name, proved by the state the
# sweep is FOR — a session with no plan at all in the root.
r35g0=$(s35_root)
mkdir -p "$r35g0/notes"
cp "$S35_STRAY" "$r35g0/notes/stray.plan.md"
s35_unbind "$r35g0" "$S35_SID_A" empty
s35_run "$r35g0" "$S35_SID_A" 'git commit -m "x"'
s35_assert "35g0 non-vacuity: with NO plan in the root the sweep still blocks on the stray" \
  2 "$r35g0/notes/stray.plan.md" -

# 35g1 THE DEFECT: bound to a plan that is gone, with a stray somewhere in the project.
s35_bind "$r35g" "$S35_SID_A" "$S35_GONE2"
s35_run "$r35g" "$S35_SID_A" 'git commit -m "x"'
s35_assert "35g1 bound to a DELETED plan beside a stray plan → allowed, not blocked" \
  0 "evidence-gate: bound plan closed — $S35_GONE2" "BLOCKED"
s35_assert "35g1 …and the stray is never named: it is not this session's business" \
  0 - "$S35_STRAY"
s35_assert "35g1 …and the operator is told the bound plan is not on disk" \
  0 "is not on disk" -
s35_assert "35g1 …and told how to get back to a live run" \
  0 "session-poker.sh bind" -

# 35g2 UNBOUND over the identical tree: today's behaviour, and it is the AC-3 baseline the
# bound answer regressed against. `active_plan` finds the live plan, so no sweep.
s35_unbind "$r35g" "$S35_SID_B" empty
s35_run "$r35g" "$S35_SID_B" 'git commit -m "x"'
s35_assert "35g2 unbound over the same tree resolves by fallback and is not blocked" \
  0 "newest-plan fallback" "BLOCKED"

# 35g3 BOUND TO A LIVE PLAN over the identical tree: the control that keeps 35g1 from
# passing on a hook that had stopped sweeping altogether.
s35_bind "$r35g" "$S35_SID_B" "$S35_B"
s35_run "$r35g" "$S35_SID_B" 'git commit -m "x"'
s35_assert "35g3 bound to a LIVE plan over the same tree is gated on it, not on the stray" \
  0 - "$S35_STRAY"

# ============================================================
# Section 36: environments arm — declared, covered, fog (S3, AC-4, AC-23)
# ============================================================
#
# Frontmatter `environments:` is one line of entries joined by " · ", each
# `<name> (covered...)` or `<name> (fog — cure: <text>)`. The arm
# (validate_environments) fires at current: 5..9, the same durable-prefix
# span as the walk-artifact arm. Absent key: no-op — but the no-op still
# names itself on the log channel via a `[environments]` finding, never
# silent-silent. Declared: the Step-5 evidence must carry an
# `environments-covered:` line naming every non-fog environment; a fog entry
# with no cure blocks regardless of the covered line's content.

section "Section 36: environments arm"

# $1 = optional `environments:` frontmatter line (empty = key absent, the
# no-op case). walk: exempt keeps that unrelated arm out of the way so each
# fixture isolates the environments subject.
env_frontmatter() {
  local env_line="${1:-}"
  printf -- '---\n'
  printf -- 'governing-skill: canonical-sdlc\ncanonical_sdlc_version: 14\n'
  printf -- 'intent: build\nrigor: audited\nscale: wave\n'
  printf -- 'deploy_target: none\nuse_worktree: false\nhas_ui: true\n'
  printf -- 'walk: exempt\n'
  if [ -n "$env_line" ]; then
    printf -- '%s\n' "$env_line"
  fi
  printf -- '---\n'
}

# $1 environments line · $2 Step-5 body (indented) · $3 matrix section.
env_plan5() {
  printf '%s\n## SDLC State\ncurrent: 5\napproved-by: fixture 2026-09-07T00:00Z approved\nStep 5:\n%s\n\n%s\n' \
    "$(env_frontmatter "$1")" "$2" "$3"
}

# Same, at current: 6 — the Step-5 block stays in the section so the durable
# prefix arm has something to read, mirroring walk_plan6.
env_plan6() {
  printf '%s\n## SDLC State\ncurrent: 6\napproved-by: fixture 2026-09-07T00:00Z approved\nStep 5:\n%s\nStep 6:\n%s\n\n%s\n' \
    "$(env_frontmatter "$1")" "$2" "$step6_body" "$3"
}

env_single_decl='environments: macos-system (covered by this wave)'
env_two_decl='environments: macos-system (covered by this wave) · linux-system (fog — cure: a Linux host runs tests/run.sh under the pin)'
env_fog_no_cure_decl='environments: macos-system (covered by this wave) · linux-system (fog)'
env_two_covered_decl='environments: macos-system (covered by this wave) · windows-system (covered by this wave)'

env_step5_covered="  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/docs/record/audit.md
  environments-covered: macos-system"

env_step5_no_covered_line="  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/docs/record/audit.md"

# 36a — declared covered set == the Step-5 environments-covered line → allow.
h36a=$(make_home)
write_plan "$h36a" "$(env_plan5 "$env_single_decl" "$env_step5_covered" "$matrix_complete")" > /dev/null
expect_allow "36a declared covered set matches environments-covered → allow" \
  "$h36a" 'git commit -m "x"'

# 36b — declared covered set present, Step-5 evidence has no
# 'environments-covered:' line at all → block.
h36b=$(make_home)
write_plan "$h36b" "$(env_plan5 "$env_single_decl" "$env_step5_no_covered_line" "$matrix_complete")" > /dev/null
expect_block "36b declared covered set, no 'environments-covered:' line → block" \
  "$h36b" 'git commit -m "x"' "no 'environments-covered:' line"

# 36c — a fog entry WITH a cure passes so long as the covered set is listed;
# the fog name itself must NOT be required in environments-covered.
h36c=$(make_home)
write_plan "$h36c" "$(env_plan5 "$env_two_decl" "$env_step5_covered" "$matrix_complete")" > /dev/null
expect_allow "36c fog entry with a cure + covered listed → allow (fog name not required)" \
  "$h36c" 'git commit -m "x"'

# 36d — a fog entry naming no cure blocks, even though the covered set is
# fully and correctly listed.
h36d=$(make_home)
write_plan "$h36d" "$(env_plan5 "$env_fog_no_cure_decl" "$env_step5_covered" "$matrix_complete")" > /dev/null
expect_block "36d fog entry with no cure named → block" \
  "$h36d" 'git commit -m "x"' "fog entry with no cure named"

# 36e — 'environments-covered:' omits a declared non-fog environment → block.
h36e=$(make_home)
write_plan "$h36e" "$(env_plan5 "$env_two_covered_decl" "$env_step5_covered" "$matrix_complete")" > /dev/null
expect_block "36e environments-covered omits a declared non-fog environment → block" \
  "$h36e" 'git commit -m "x"' "omits declared environment"

# 36f — the 'environments:' key is absent entirely → allow, SILENT on
# stderr (an ordinary commit in an ordinary repo never declares this key,
# so the no-op must not become noise the way an actionable finding is).
h36f=$(make_home)
write_plan "$h36f" "$(env_plan5 "" "$env_step5_no_covered_line" "$matrix_complete")" > /dev/null
expect_allow "36f absent 'environments:' → allow, silent on stderr" \
  "$h36f" 'git commit -m "x"'

# 36f2 — the SAME fixture, but the no-op is still recorded on the durable
# audit-file channel (log_finding_quiet) — "log-only" literally: logged,
# but never surfaced on stderr the way Section 20's refactor/tune findings
# are. Mirrors the 19e/19e2 stderr-vs-file split.
expect_audit_line "36f2 …and the no-op is recorded on the audit-file channel only" \
  "$h36f" 'git commit -m "x"' "evidence-gate environments:"

# 36g — durable prefix span (mirrors 26g/A5): at current: 6 the same
# fog-without-cure rule still blocks, so the claim cannot go stale once
# Verify is behind you.
h36g=$(make_home)
write_plan "$h36g" "$(env_plan6 "$env_fog_no_cure_decl" "$env_step5_covered" "$matrix_complete")" > /dev/null
expect_block "36g current: 6 still enforces the fog-cure rule (durable prefix)" \
  "$h36g" 'git commit -m "x"' "fog entry with no cure named"

# 36h — a plan whose frontmatter never mentions 'environments:' AND whose
# rows are all still pending: still a silent allow (no interaction with the
# matrix gate; the two arms are independent), and the no-op still lands on
# the audit file only.
h36h=$(make_home)
write_plan "$h36h" "$(env_plan5 "" "$env_step5_no_covered_line" "$walk_matrix_all_pending")" > /dev/null
expect_allow "36h absent 'environments:' + all rows pending → allow, silent on stderr" \
  "$h36h" 'git commit -m "x"'
expect_audit_line "36h2 …and the no-op is still recorded on the audit-file channel only" \
  "$h36h" 'git commit -m "x"' "evidence-gate environments:"

# 36i/36j — THE OVER-CLAIM DIRECTION (critic K-5). The arm walked the declared non-fog
# names and required each to be covered; nothing walked the covered names, so a plan could
# claim coverage it does not have and the gate was silent. THIS WAVE'S OWN FRONTMATTER is
# the live instance: `environments-covered: macos-system, linux-system` passed while
# linux-system was declared FOG, and a fog entry's entire meaning is "not covered".
env_step5_overclaim_fog="  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/docs/record/audit.md
  environments-covered: macos-system, linux-system"

h36i=$(make_home)
write_plan "$h36i" "$(env_plan5 "$env_two_decl" "$env_step5_overclaim_fog" "$matrix_complete")" > /dev/null
expect_block "36i environments-covered claims a FOG environment → block" \
  "$h36i" 'git commit -m "x"' "declares as FOG"

env_step5_overclaim_undeclared="  cmd: bash test.sh
  pass: 332
  total: 332
  output: .bionic/docs/plans/wave-01.plan.md#step-5
  auditor: 3 rows CONFIRMED — report .bionic/docs/record/audit.md
  environments-covered: macos-system, freebsd"

h36j=$(make_home)
write_plan "$h36j" "$(env_plan5 "$env_single_decl" "$env_step5_overclaim_undeclared" "$matrix_complete")" > /dev/null
expect_block "36j environments-covered names an UNDECLARED environment → block" \
  "$h36j" 'git commit -m "x"' "never declared"

# 36k — CONTROL, so 36i/36j are the over-claim rule and not a fixture that could never
# pass: the same declaration with the fog name dropped from the covered line allows. 36c
# above asserts the same thing from the other side; this one shares 36i's fixture.
h36k=$(make_home)
write_plan "$h36k" "$(env_plan5 "$env_two_decl" "$env_step5_covered" "$matrix_complete")" > /dev/null
expect_allow "36k control: the same declaration, covering only what it declares → allow" \
  "$h36k" 'git commit -m "x"'

# 36l — the durable prefix (mirrors 36g): at current: 6 the over-claim still blocks, so a
# coverage claim cannot go stale once Verify is behind you.
h36l=$(make_home)
write_plan "$h36l" "$(env_plan6 "$env_two_decl" "$env_step5_overclaim_fog" "$matrix_complete")" > /dev/null
expect_block "36l current: 6 still refuses the over-claim (durable prefix)" \
  "$h36l" 'git commit -m "x"' "declares as FOG"

# ============================================================
section "Section 37: K5/AC-K5.2 — Step-1 'requirements:' pointer"
# ============================================================
#
# K5 (design ledger K5; ADR-001): Step 1 authors wave-NN-<slug>.requirements.md; the
# Step-1 evidence line records its path once and this arm reads it back at every commit
# from current: 2 onward — durable, like the Step-5 walk artifact (A5). Scoped to
# rigor:audited + multi_agent:true + scale wave|epic (mirrors D7's own guard, above) so
# the suite's FM (rigor: tested) and frontmatter() (no multi_agent:) fixtures stay
# no-ops — proven directly in 37g below.

# $1 current  $2 raw Step-1 line content (no "Step 1: " prefix)  $3 the CURRENT step's
# own line content (only emitted when current != 1; a pointer step needs its OWN line
# non-empty and non-placeholder — "TODO"/"pending"/"in progress" etc. all block upstream
# of this arm, so every fixture below uses real-shaped prose instead).
k5_plan() {
  local current="$1" step1="$2" own="${3:-.bionic/docs/specs/epic-01-demo/wave-01-x.spec.md}"
  printf '%s\n' "$(d7_wave_frontmatter)"
  printf '## SDLC State\ncurrent: %s\n' "$current"
  printf 'Step 1: %s\n' "$step1"
  [ "$current" = "1" ] || printf 'Step %s: %s\n' "$current" "$own"
}

k5g_h=$(make_home)
k5g_p=$(make_project)
mkdir -p "$k5g_p/.bionic/docs/specs/epic-01-demo"
k5g_real="$k5g_p/.bionic/docs/specs/epic-01-demo/wave-01-x.requirements.md"
printf -- '---\ngoverning-skill: agent-skills:idea-refine\ncanonical_sdlc_version: 14\n---\n# reqs\n' \
  > "$k5g_real"

echo "-- 37a: current: 1 — the arm is inert (Step 1 is still being authored) --"
write_project_plan "$k5g_p" "$(k5_plan 1 "brief ideas/x.md rev 1; ratified in the terminal")" > /dev/null
expect_allow_p "37a current: 1, Step 1 has no requirements: field → allow (arm inert)" \
  "$k5g_h" "$k5g_p" 'git commit -m "x"'

echo "-- 37b: current: 2, Step 1 lacks 'requirements:' → block naming the field --"
write_project_plan "$k5g_p" "$(k5_plan 2 "in progress")" > /dev/null
expect_block_p "37b current: 2, no requirements: field → block" \
  "$k5g_h" "$k5g_p" 'git commit -m "x"' "no 'requirements:' field"

echo "-- 37c: current: 2, 'requirements:' names a file that does not exist → block naming the path --"
write_project_plan "$k5g_p" "$(k5_plan 2 "requirements: specs/epic-01-demo/nowhere.requirements.md")" > /dev/null
expect_block_p "37c current: 2, dangling requirements: path → block, names it" \
  "$k5g_h" "$k5g_p" 'git commit -m "x"' "does not resolve to a real file"

echo "-- 37d: current: 2, 'requirements:' resolves to a real file → allow --"
write_project_plan "$k5g_p" "$(k5_plan 2 "requirements: specs/epic-01-demo/wave-01-x.requirements.md")" > /dev/null
expect_allow_p "37d current: 2, requirements: resolves → allow" \
  "$k5g_h" "$k5g_p" 'git commit -m "x"'

echo "-- 37e: durable — current: 3 (a step past 2) still enforces the same pointer --"
write_project_plan "$k5g_p" "$(k5_plan 3 "in progress" ".bionic/docs/plans/active.md")" > /dev/null
expect_block_p "37e current: 3, no requirements: field → block (durable, not just at 2)" \
  "$k5g_h" "$k5g_p" 'git commit -m "x"' "no 'requirements:' field"

echo "-- 37f: a '..' component in the pointer refuses outright, never resolved --"
write_project_plan "$k5g_p" "$(k5_plan 2 "requirements: specs/../../../etc/passwd")" > /dev/null
expect_block_p "37f '..' component → block, never resolved" \
  "$k5g_h" "$k5g_p" 'git commit -m "x"' "climbs out with a '..' component"

echo "-- 37g: scope guard — rigor: tested (this suite's FM/frontmatter() default) is a no-op --"
# Same current: 2, same missing field, same project — the only variable is rigor. If the
# guard were not real this would block exactly like 37b.
k5g_tested="$(d7_wave_frontmatter tested true)
## SDLC State
current: 2
Step 1: in progress
Step 2: .bionic/docs/specs/epic-01-demo/wave-01-x.spec.md"
write_project_plan "$k5g_p" "$k5g_tested" > /dev/null
expect_allow_p "37g rigor: tested → allow (scope guard makes the arm inert)" \
  "$k5g_h" "$k5g_p" 'git commit -m "x"'


# ============================================================
# Section 37: the approval arm and the fails-when arm (epic-22 K2)
# ============================================================
#
# TWO ARMS, ONE STEP BOUNDARY. Both fire from `current: 4` — the step where the plan
# stops being authored and starts being built — and both are silent below it.
#
#   approved-by:  AC-K2.4, design decision 2. Step 3 ends at one approval checkpoint,
#                 and until this arm existed the user's `approved` left no trace: a run
#                 could be at Step 4 with nobody able to say whether the plan had ever
#                 been ratified. The orchestrator now writes
#                 `approved-by: <user> <ISO-UTC> "<verbatim reply>"` into `## SDLC State`
#                 on the literal word, and this is what makes its absence cost something.
#   fails-when:   AC-K2.3. An eval with no nameable failure is not an eval — a row that
#                 cannot say what planted defect it must go red on is a row that will be
#                 green whatever the code does. The column is authored at Step 2 in the
#                 spec's `## Eval design` and rendered into the matrix at Step 3, so by
#                 Step 4 every AC block already has one or the plan skipped a step.
#
# WHY THE ARMS ARE NOT MUTUAL. 37f/37g drive each one with the OTHER condition satisfied,
# so neither refusal can be credited to the wrong wall.
#
# INERT CONDITIONS, pinned rather than assumed (37h..37k): below current 4 both are
# silent; a matrix with no AC block for a row leaves the fails-when arm with nothing to
# judge; and a plan with no `## Verification Matrix` at all is not a fails-when finding.
# The last two matter because the arms run at Step 4, where a plan is legitimately
# mid-authoring and half its matrix may not exist yet.

section "Section 37: the approval arm and the fails-when arm (epic-22 K2)"

# A Step-4 body the shape checks accept: Step 4 is a pointer step for this gate.
k2_step4="  plan-doc: .bionic/docs/plans/wave-01.plan.md#step-4"

# k2_plan <current> <approved-by line, or ""> <matrix section, or ""> -> a whole plan
k2_plan() {
  local approved_line=""
  [ -n "$2" ] && approved_line="$2
"
  printf '%s\n## SDLC State\ncurrent: %s\n%sStep %s:\n%s\n\n%s\n' \
    "$(matrix_frontmatter true)" "$1" "$approved_line" "$1" "$k2_step4" "${3:-}"
}

K2_APPROVED='approved-by: dana 2026-09-07T19:05Z "Ok, amazing! Approved."'

# k2_matrix <AC-2 fails-when line, or ""> -> a two-row matrix whose AC-1 block always
# names a fails-when and whose AC-2 block carries whatever the caller passes.
k2_matrix() {
  local ac2_fw=""
  [ -n "$1" ] && ac2_fw="
  $1"
  cat <<EOF
## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T0 | pending | see AC-1 | |
| AC-2 | T0 | pending | see AC-2 | |

AC-1:
  criterion: the card carries every ratified row
  provenance: user 2026-09-07 "approved"
  fails-when: a card is missing
AC-2:
  criterion: the arm refuses a block that names no failure
  provenance: user 2026-09-07 "approved"${ac2_fw}
EOF
}

k2_matrix_full="$(k2_matrix 'fails-when: the gate passes it')"
k2_matrix_missing="$(k2_matrix '')"
k2_matrix_empty="$(k2_matrix 'fails-when:')"

# --- 37a/37b: the approval arm ---------------------------------------------

h37a=$(make_home)
write_plan "$h37a" "$(k2_plan 4 "" "$k2_matrix_full")" > /dev/null
expect_block "37a current: 4 with no approved-by: → block" \
  "$h37a" 'git commit -m "x"' "approved-by"

h37b=$(make_home)
write_plan "$h37b" "$(k2_plan 4 "$K2_APPROVED" "$k2_matrix_full")" > /dev/null
expect_allow "37b current: 4 with the approved-by line → allow" \
  "$h37b" 'git commit -m "x"'

# 37c — the line has to SAY something. An `approved-by:` with an empty value records no
# approval, and reading it as one would make the wall satisfiable by typing its key.
h37c=$(make_home)
write_plan "$h37c" "$(k2_plan 4 "approved-by:" "$k2_matrix_full")" > /dev/null
expect_block "37c an empty approved-by: value is not an approval → block" \
  "$h37c" 'git commit -m "x"' "approved-by"

# 37d — the durable prefix: the approval does not stop mattering once Step 4 is behind
# you. A plan that reaches Verify with the line deleted has lost the same fact.
h37d=$(make_home)
write_plan "$h37d" "$(k2_plan 6 "" "$k2_matrix_full")" > /dev/null
expect_block "37d current: 6 with no approved-by: → still blocked (durable prefix)" \
  "$h37d" 'git commit -m "x"' "approved-by"

# --- 37e/37f: the fails-when arm -------------------------------------------

h37e=$(make_home)
write_plan "$h37e" "$(k2_plan 4 "$K2_APPROVED" "$k2_matrix_missing")" > /dev/null
expect_block "37e an AC block with no fails-when: → block, naming the AC" \
  "$h37e" 'git commit -m "x"' "AC-2"

h37e2=$(make_home)
write_plan "$h37e2" "$(k2_plan 4 "$K2_APPROVED" "$k2_matrix_missing")" > /dev/null
expect_block "37e2 …and the refusal names the missing key" \
  "$h37e2" 'git commit -m "x"' "fails-when"

h37f=$(make_home)
write_plan "$h37f" "$(k2_plan 4 "$K2_APPROVED" "$k2_matrix_empty")" > /dev/null
expect_block "37f an empty fails-when: value → block" \
  "$h37f" 'git commit -m "x"' "fails-when"

# 37g — THE CONTROL 37e and 37f need. The same plan with both keys present allows, so
# the two refusals above are the missing key and not the fixture.
h37g=$(make_home)
write_plan "$h37g" "$(k2_plan 4 "$K2_APPROVED" "$k2_matrix_full")" > /dev/null
expect_allow "37g control: every AC block names a fails-when → allow" \
  "$h37g" 'git commit -m "x"'

# --- 37h..37k: the inert conditions ----------------------------------------

# 37h — below Step 4 the plan is still being authored: the approval has not been asked
# for and the matrix is still being written. Neither arm may fire.
h37h=$(make_home)
write_plan "$h37h" "$(k2_plan 3 "" "$k2_matrix_missing")" > /dev/null
expect_allow "37h current: 3 with neither approved-by nor fails-when → allow (both arms inert)" \
  "$h37h" 'git commit -m "x"'

# 37i — a row with no AC block at all is not a fails-when finding: there is no block to
# lack the key, and the per-tier evidence loop at Verify is what owns that gap.
k2_matrix_noblock="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T0 | pending | see AC-1 | |
| AC-9 | T0 | pending | see AC-9 | |

AC-1:
  criterion: the card carries every ratified row
  fails-when: a card is missing"
h37i=$(make_home)
write_plan "$h37i" "$(k2_plan 4 "$K2_APPROVED" "$k2_matrix_noblock")" > /dev/null
expect_allow "37i a matrix row with no AC block is not a fails-when finding → allow" \
  "$h37i" 'git commit -m "x"'

# 37j — no matrix section at all: a Step-4 plan may not have written one yet, and a wall
# that demanded one here would be the Verify gate's demand moved four steps early.
h37j=$(make_home)
write_plan "$h37j" "$(k2_plan 4 "$K2_APPROVED" "")" > /dev/null
expect_allow "37j a Step-4 plan with no '## Verification Matrix' → allow (fails-when arm inert)" \
  "$h37j" 'git commit -m "x"'

# 37l — A WAIVER DOES NOT EXCUSE THE COLUMN. Everywhere else in this loop a waiver
# dissolves a row's demands: the per-tier evidence keys, the CONFIRMED verdict, the
# `slice: 9` tier refusal all yield to one. This arm does not, and the distinction is the
# reason: those are demands for EVIDENCE, and a waiver is precisely the decision not to
# gather it. `fails-when:` is not evidence — it is the design of the eval, authored at
# Step 2 before any waiver exists, and a row that never named a failure was never
# evaluable in the first place. Waiving it waives the question, not the answer.
h37l=$(make_home)
k2_matrix_waived="## Verification Matrix

stack-health: n/a: no long-running serve

| AC | tier | status | evidence | auditor |
|---|---|---|---|---|
| AC-1 | T0 | waived | waiver: dana 2026-09-07 criterion dropped | waived |

AC-1:
  waiver: dana 2026-09-07 criterion dropped"
write_plan "$h37l" "$(k2_plan 4 "$K2_APPROVED" "$k2_matrix_waived")" > /dev/null
expect_block "37l a WAIVED row still has to name its fails-when → block" \
  "$h37l" 'git commit -m "x"' "fails-when"

# THE PLAN THAT SPECIFIED THESE WALLS is the first artifact they judge, and a wall its own
# specification cannot satisfy is a wall that gets turned off within the hour. That check is
# NOT a fixture here: `.bionic/` is machine-local by decision and absent from a fresh clone
# and from every worktree, so an arm reading it would degrade to a vacuous pass on exactly
# the machines the suite is meant to protect. It is a recorded drive instead —
# record/wave-01-plugin-only/s16-step-cards.log, "the real plan" — run against the live
# plan with the live hook, with its command and output.


finish
