#!/bin/bash
# Tests for canonical-sdlc-evidence-gate.sh
#
# Strategy: override HOME to a temp dir so the hook reads plan files from
# a test-controlled ~/.claude/plans/ and never touches the real user's
# plans directory.
#
# Usage: bash hooks/canonical-sdlc-evidence-gate.test.sh

set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/canonical-sdlc-evidence-gate.sh"
PASS=0
FAIL=0
TOTAL=0

# ---------- helpers ----------

cleanup_dirs=()
cleanup() {
  for d in "${cleanup_dirs[@]}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

# Creates an isolated $HOME-equivalent with an empty ~/.claude/plans/ dir.
make_home() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/.claude/plans"
  cleanup_dirs+=("$dir")
  echo "$dir"
}

# Creates an isolated project dir with docs/bionic/plans/ ready to receive
# plan files. Returned path plays the CLAUDE_PROJECT_DIR role.
make_project() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/docs/bionic/plans"
  cleanup_dirs+=("$dir")
  echo "$dir"
}

# Writes $2 as a plan file inside $1/docs/bionic/plans/ (project-local dir).
write_project_plan() {
  local project_dir="$1" content="$2" name="${3:-active.md}"
  local path="$project_dir/docs/bionic/plans/$name"
  printf '%s\n' "$content" > "$path"
  touch "$path"
  echo "$path"
}

# Writes $2 as the content of a plan file inside $1/.claude/plans/.
# Touches mtime to "now" so it becomes the newest.
write_plan() {
  local home_dir="$1" content="$2" name="${3:-active.md}"
  local path="$home_dir/.claude/plans/$name"
  printf '%s\n' "$content" > "$path"
  # Ensure mtime > any prior plan in this test by nudging forward.
  touch "$path"
  echo "$path"
}

# Runs hook with HOME set to $1 and the given bash-tool-call command $2.
# Sets globals HOOK_EXIT and HOOK_STDERR. The hook is stderr-only on block,
# silent on allow — no need to capture stdout.
run_hook() {
  local home_dir="$1" command="$2"
  local input
  input=$(jq -n --arg c "$command" '{tool_input: {command: $c}}')
  local tmp_err
  tmp_err=$(mktemp)
  # Capture exit code without letting errexit kill the test runner, and
  # without the `|| true` trick (which replaces $? with 0).
  if HOME="$home_dir" CLAUDE_PROJECT_DIR="" bash "$HOOK" <<< "$input" >/dev/null 2>"$tmp_err"; then
    HOOK_EXIT=0
  else
    HOOK_EXIT=$?
  fi
  HOOK_STDERR=$(cat "$tmp_err")
  rm -f "$tmp_err"
}

# Like run_hook but also sets CLAUDE_PROJECT_DIR so the hook will scan
# project-local plan directories (docs/bionic/plans/, docs/superpowers/plans/).
run_hook_with_project() {
  local home_dir="$1" project_dir="$2" command="$3"
  local input
  input=$(jq -n --arg c "$command" '{tool_input: {command: $c}}')
  local tmp_err
  tmp_err=$(mktemp)
  if HOME="$home_dir" CLAUDE_PROJECT_DIR="$project_dir" bash "$HOOK" <<< "$input" >/dev/null 2>"$tmp_err"; then
    HOOK_EXIT=0
  else
    HOOK_EXIT=$?
  fi
  HOOK_STDERR=$(cat "$tmp_err")
  rm -f "$tmp_err"
}

expect_allow() {
  local label="$1" home_dir="$2" command="$3"
  TOTAL=$((TOTAL + 1))
  run_hook "$home_dir" "$command"
  if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected allow, exit 0, no stderr): $label"
    echo "  exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
    FAIL=$((FAIL + 1))
  fi
}

expect_block() {
  local label="$1" home_dir="$2" command="$3" expected_substr="${4:-BLOCKED}"
  TOTAL=$((TOTAL + 1))
  run_hook "$home_dir" "$command"
  if [ "$HOOK_EXIT" -eq 2 ] && echo "$HOOK_STDERR" | grep -q "$expected_substr"; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected block exit 2 with substring '$expected_substr'): $label"
    echo "  exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
    FAIL=$((FAIL + 1))
  fi
}

# ============================================================
# Section 1: non-commit commands always allowed
# ============================================================

echo ""
echo "=== Section 1: Non-commit commands pass through ==="

h1=$(make_home)
# Seed a plan that WOULD block if the command were a commit.
write_plan "$h1" "## SDLC State
current: 5
Phase 5: TODO" > /dev/null

expect_allow "ls command — not a commit" "$h1" "ls /tmp"
expect_allow "git status — not a commit" "$h1" "git status"
expect_allow "git push — not a commit" "$h1" "git push origin main"
expect_allow "empty command" "$h1" ""

# ============================================================
# Section 2: commit with no plans directory / no plans
# ============================================================

echo ""
echo "=== Section 2: Commit with no canonical-sdlc state — allowed ==="

h2=$(make_home)
# plans dir exists but empty
expect_allow "empty plans dir — allow commit" "$h2" 'git commit -m "x"'

h2b=$(mktemp -d); cleanup_dirs+=("$h2b")
# No ~/.claude/plans/ at all
expect_allow "no plans dir at all — allow commit" "$h2b" 'git commit -m "x"'

h2c=$(make_home)
write_plan "$h2c" "# regular plan
Some content.
No SDLC State section here." > /dev/null
expect_allow "plan without ## SDLC State — allow commit" "$h2c" 'git commit -m "x"'

# ============================================================
# Section 3: valid evidence allows commit
# ============================================================

echo ""
echo "=== Section 3: Valid evidence in ## SDLC State — allowed ==="

h3=$(make_home)
write_plan "$h3" "# plan

## SDLC State
mode: overnight
current: 5
Phase 1: /path/to/ideate.md
Phase 2: /path/to/spec.md
Phase 3: ~/.claude/plans/this.md
Phase 4: git worktree at /tmp/wt
Phase 5: tests passing, commit abc123

## Other section" > /dev/null

# Step-vocabulary variant (new plans) — must be accepted equally.
h3b=$(make_home)
write_plan "$h3b" "# plan (new vocabulary)

## SDLC State
mode: full
current: 5
Step 1: /path/to/ideate.md
Step 2: /path/to/spec.md
Step 3: ~/.claude/plans/this.md
Step 4: git worktree at /tmp/wt
Step 5: tests passing, commit def456

## Other section" > /dev/null
expect_allow "Step N: vocabulary — allowed" "$h3b" 'git commit -m "x"'

# Mixed Phase/Step — legacy plan that partially migrated. The current
# step's line must exist under either prefix; hook accepts either.
h3c=$(make_home)
write_plan "$h3c" "## SDLC State
current: 5
Phase 1: done
Phase 2: done
Step 5: mixed-vocab evidence" > /dev/null
expect_allow "mixed Phase/Step with Step for current — allowed" "$h3c" 'git commit -m "x"'
expect_allow "valid phase 5 evidence — allow" "$h3" 'git commit -m "phase 5 done"'

h3b=$(make_home)
write_plan "$h3b" "## SDLC State
current: 8b
Phase 8b: critic report attached in docs/review.md" > /dev/null
expect_allow "valid phase 8b evidence — allow" "$h3b" 'git commit -m "critic done"'

h3c=$(make_home)
write_plan "$h3c" "## SDLC State
current: 10
- Phase 10: commit SHA abc123 body written" > /dev/null
expect_allow "bulleted Phase line — allow" "$h3c" 'git commit -m "x"'

# ============================================================
# Section 4: malformed / missing SDLC State pieces
# ============================================================

echo ""
echo "=== Section 4: Malformed SDLC State — blocked ==="

h4=$(make_home)
write_plan "$h4" "## SDLC State
# no current line, no phase lines

## Next section" > /dev/null
expect_block "missing 'current: N' line" "$h4" 'git commit -m "x"' "missing a valid 'current: N'"

h4b=$(make_home)
write_plan "$h4b" "## SDLC State
current: 5
Phase 1: done
Phase 2: done
# no Phase 5 line" > /dev/null
expect_block "no matching Step N line (legacy Phase lines don't match)" "$h4b" 'git commit -m "x"' "no 'Step 5:' line"

h4c=$(make_home)
write_plan "$h4c" "## SDLC State
current: five
Phase 5: something" > /dev/null
expect_block "non-numeric current" "$h4c" 'git commit -m "x"' "missing a valid 'current: N'"

# ============================================================
# Section 5: empty / placeholder evidence — blocked
# ============================================================

echo ""
echo "=== Section 5: Placeholder evidence — blocked ==="

h5=$(make_home)
write_plan "$h5" "## SDLC State
current: 5
Phase 5:   " > /dev/null
expect_block "empty evidence line" "$h5" 'git commit -m "x"' "is empty"

for token in TODO pending "in progress" XXX TBD placeholder; do
  h=$(make_home)
  write_plan "$h" "## SDLC State
current: 5
Phase 5: $token" > /dev/null
  expect_block "placeholder '$token'" "$h" 'git commit -m "x"' "placeholder"
done

# Case-insensitive placeholder match
h5b=$(make_home)
write_plan "$h5b" "## SDLC State
current: 5
Phase 5: Todo — still writing" > /dev/null
expect_block "placeholder 'Todo' (mixed case)" "$h5b" 'git commit -m "x"' "placeholder"

# ============================================================
# Section 6: compound commands + edge cases
# ============================================================

echo ""
echo "=== Section 6: Compound commands — commit detection ==="

h6=$(make_home)
write_plan "$h6" "## SDLC State
current: 5
Phase 5: TODO" > /dev/null
expect_block "cd && git commit" "$h6" 'cd /tmp && git commit -m "x"' "placeholder"
expect_block "git add && git commit" "$h6" 'git add . && git commit -m "x"' "placeholder"

# False-positive check: quoted "git commit" as prose shouldn't trigger
# gate on its own, but a real `git commit` in the same command does.
h6b=$(make_home)
write_plan "$h6b" "## SDLC State
current: 5
Phase 5: TODO" > /dev/null
expect_allow "echo only, no real commit" "$h6b" 'echo "we will git commit later"'

# ============================================================
# Section 7: newest-plan-wins
# ============================================================

echo ""
echo "=== Section 7: Newest plan file is the one enforced ==="

h7=$(make_home)
# Older plan with valid state
write_plan "$h7" "## SDLC State
current: 5
Phase 5: tests green" "old.md" > /dev/null
# Make old.md older than now.
touch -t 202001010000 "$h7/.claude/plans/old.md" 2>/dev/null || \
  touch -d "2020-01-01" "$h7/.claude/plans/old.md" 2>/dev/null || true
# Newer plan with bad state
write_plan "$h7" "## SDLC State
current: 5
Phase 5: TODO" "new.md" > /dev/null
expect_block "newest plan rules — bad state blocks even with valid older plan" \
  "$h7" 'git commit -m "x"' "placeholder"

# Inverse: newer plan without ## SDLC State lets commit pass even if
# an older plan has bad state.
h7b=$(make_home)
write_plan "$h7b" "## SDLC State
current: 5
Phase 5: TODO" "old-bad.md" > /dev/null
touch -t 202001010000 "$h7b/.claude/plans/old-bad.md" 2>/dev/null || \
  touch -d "2020-01-01" "$h7b/.claude/plans/old-bad.md" 2>/dev/null || true
write_plan "$h7b" "# unrelated plan, no SDLC State" "new-neutral.md" > /dev/null
expect_allow "newest plan without SDLC State — allow despite bad older plan" \
  "$h7b" 'git commit -m "x"'

# ============================================================
# Section 8: project-local plan directory (docs/bionic/plans/)
# ============================================================

echo ""
echo "=== Section 8: Project-local plan dir (CLAUDE_PROJECT_DIR) ==="

# Helpers that exercise both plan-dir paths at once.
expect_allow_both() {
  local label="$1" home_dir="$2" project_dir="$3" command="$4"
  TOTAL=$((TOTAL + 1))
  run_hook_with_project "$home_dir" "$project_dir" "$command"
  if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDERR" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected allow): $label"
    echo "  exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
    FAIL=$((FAIL + 1))
  fi
}

expect_block_both() {
  local label="$1" home_dir="$2" project_dir="$3" command="$4" substr="${5:-BLOCKED}"
  TOTAL=$((TOTAL + 1))
  run_hook_with_project "$home_dir" "$project_dir" "$command"
  if [ "$HOOK_EXIT" -eq 2 ] && echo "$HOOK_STDERR" | grep -q "$substr"; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected block with '$substr'): $label"
    echo "  exit=$HOOK_EXIT stderr='$HOOK_STDERR'"
    FAIL=$((FAIL + 1))
  fi
}

# 8a — project-local plan alone, global empty: hook honors project plan.
h8a=$(make_home); p8a=$(make_project)
write_project_plan "$p8a" "## SDLC State
current: 5
Phase 5: TODO" > /dev/null
expect_block_both "project-local plan (bad) blocks with no global plan" \
  "$h8a" "$p8a" 'git commit -m "x"' "placeholder"

# 8b — project-local plan alone, global empty: good evidence allows.
h8b=$(make_home); p8b=$(make_project)
write_project_plan "$p8b" "## SDLC State
current: 5
Phase 5: commit abc123 tests green" > /dev/null
expect_allow_both "project-local plan (good) allows with no global plan" \
  "$h8b" "$p8b" 'git commit -m "x"'

# 8c — both plans exist, project is newer → project wins.
h8c=$(make_home); p8c=$(make_project)
write_plan "$h8c" "## SDLC State
current: 5
Phase 5: commit xyz green" "old-global.md" > /dev/null
touch -t 202001010000 "$h8c/.claude/plans/old-global.md" 2>/dev/null || \
  touch -d "2020-01-01" "$h8c/.claude/plans/old-global.md" 2>/dev/null || true
write_project_plan "$p8c" "## SDLC State
current: 5
Phase 5: TODO" > /dev/null
expect_block_both "newer project plan (bad) wins over older global (good)" \
  "$h8c" "$p8c" 'git commit -m "x"' "placeholder"

# 8d — both plans exist, global is newer → global wins.
h8d=$(make_home); p8d=$(make_project)
write_project_plan "$p8d" "## SDLC State
current: 5
Phase 5: TODO" "old-proj.md" > /dev/null
touch -t 202001010000 "$p8d/docs/bionic/plans/old-proj.md" 2>/dev/null || \
  touch -d "2020-01-01" "$p8d/docs/bionic/plans/old-proj.md" 2>/dev/null || true
write_plan "$h8d" "## SDLC State
current: 5
Phase 5: commit xyz green" > /dev/null
expect_allow_both "newer global plan (good) wins over older project (bad)" \
  "$h8d" "$p8d" 'git commit -m "x"'

# 8e — project dir lacks docs/bionic/plans/: hook falls back to global.
h8e=$(make_home)
p8e=$(mktemp -d); cleanup_dirs+=("$p8e") # no docs/bionic/plans/ inside
write_plan "$h8e" "## SDLC State
current: 5
Phase 5: TODO" > /dev/null
expect_block_both "project without docs/bionic/plans/ falls back to global plan" \
  "$h8e" "$p8e" 'git commit -m "x"' "placeholder"

# 8f — CLAUDE_PROJECT_DIR unset: original behavior (global only).
h8f=$(make_home)
write_plan "$h8f" "## SDLC State
current: 5
Phase 5: TODO" > /dev/null
expect_block "CLAUDE_PROJECT_DIR unset: still gates on global plan" \
  "$h8f" 'git commit -m "x"' "placeholder"

# 8g — also covers superpowers convention.
h8g=$(make_home); p8g=$(mktemp -d); cleanup_dirs+=("$p8g")
mkdir -p "$p8g/docs/superpowers/plans"
printf '## SDLC State\ncurrent: 5\nPhase 5: TODO\n' > "$p8g/docs/superpowers/plans/active.md"
touch "$p8g/docs/superpowers/plans/active.md"
expect_block_both "docs/superpowers/plans/ plan is honored alongside bionic" \
  "$h8g" "$p8g" 'git commit -m "x"' "placeholder"

# ============================================================
# Summary
# ============================================================

echo ""
echo "============================================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "============================================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
