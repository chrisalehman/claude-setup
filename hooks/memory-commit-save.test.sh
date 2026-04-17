#!/bin/bash
# Tests for memory-commit-save.sh PostToolUse hook.
# Verifies the hook fires a save decision only when: the Bash tool call
# is a `git commit`, the project has adopted .bionic/memory/, the
# context.md mtime is outside the 60-sec debounce, and HEAD is not a
# .bionic/memory/-only commit.
#
# Usage: bash hooks/memory-commit-save.test.sh

set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/memory-commit-save.sh"
PASS=0
FAIL=0
TOTAL=0

# ---------- helpers ----------

# Creates a fresh isolated project dir and returns its path on stdout.
# The initial commit is back-dated to avoid skewing any time-based checks.
make_project() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init --quiet
  git -C "$dir" config user.email "test@test"
  git -C "$dir" config user.name "test"
  echo "initial" > "$dir/README.md"
  git -C "$dir" add README.md
  GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
  GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
  git -C "$dir" commit --quiet -m "initial"
  echo "$dir"
}

# Ages context.md outside the 60-sec debounce.
age_context() {
  local ctx="$1/.bionic/memory/context.md"
  # Create + touch to a date far in the past. Portable across BSD + GNU touch.
  : > "$ctx"
  touch -t 202601010000 "$ctx" 2>/dev/null || \
    touch -d "2026-01-01" "$ctx" 2>/dev/null || true
}

# Builds a happy-path project:
#   - has .bionic/memory/
#   - context.md aged past debounce
#   - HEAD is a commit that touches a non-.bionic/memory/ file
happy_project() {
  local dir
  dir=$(make_project)
  mkdir -p "$dir/.bionic/memory"
  age_context "$dir"
  echo "work" > "$dir/file.txt"
  git -C "$dir" add file.txt
  GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
  GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
  git -C "$dir" commit --quiet -m "add file"
  echo "$dir"
}

run_hook() {
  local project="$1"
  local input="$2"
  HOOK_STDOUT=$(CLAUDE_PROJECT_DIR="$project" bash "$HOOK" <<< "$input" 2>/dev/null) || true
  HOOK_EXIT=$?
}

expect_silent_exit() {
  local label="$1" project="$2" input="$3"
  TOTAL=$((TOTAL + 1))
  run_hook "$project" "$input"
  if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected silent exit 0): $label"
    echo "  exit=$HOOK_EXIT stdout='$HOOK_STDOUT'"
    FAIL=$((FAIL + 1))
  fi
}

expect_block_decision() {
  local label="$1" project="$2" input="$3"
  TOTAL=$((TOTAL + 1))
  run_hook "$project" "$input"
  if [ "$HOOK_EXIT" -eq 0 ] && echo "$HOOK_STDOUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    if echo "$HOOK_STDOUT" | jq -e '.reason | type == "string" and length > 20' >/dev/null 2>&1; then
      echo "PASS: $label"
      PASS=$((PASS + 1))
    else
      echo "FAIL (missing/short reason): $label"
      echo "  stdout='$HOOK_STDOUT'"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "FAIL (expected block decision): $label"
    echo "  exit=$HOOK_EXIT stdout='$HOOK_STDOUT'"
    FAIL=$((FAIL + 1))
  fi
}

cleanup_projects=()
cleanup() {
  for d in "${cleanup_projects[@]}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

# The canonical commit-shaped input used across many tests.
COMMIT_CMD='{"tool_input":{"command":"git commit -m \"x\""}}'

# ============================================================
# Section 1: Non-commit commands → silent
# Covers R4 (non-commit silent) and R10b (prose false-positive guard).
# ============================================================
echo ""
echo "=== Section 1: Non-commit commands — always silent ==="

p1a=$(happy_project); cleanup_projects+=("$p1a")
expect_silent_exit "ls -la is not a commit" \
  "$p1a" '{"tool_input":{"command":"ls -la"}}'

p1b=$(happy_project); cleanup_projects+=("$p1b")
expect_silent_exit "empty command" \
  "$p1b" '{"tool_input":{"command":""}}'

p1c=$(happy_project); cleanup_projects+=("$p1c")
expect_silent_exit "missing tool_input key entirely" \
  "$p1c" '{}'

p1d=$(happy_project); cleanup_projects+=("$p1d")
expect_silent_exit "git status alone is not a commit" \
  "$p1d" '{"tool_input":{"command":"git status"}}'

p1e=$(happy_project); cleanup_projects+=("$p1e")
expect_silent_exit "prose containing \"git commit\" inside double quotes" \
  "$p1e" '{"tool_input":{"command":"echo \"git commit\""}}'

p1f=$(happy_project); cleanup_projects+=("$p1f")
expect_silent_exit "git commit-tree is a different command" \
  "$p1f" '{"tool_input":{"command":"git commit-tree HEAD^{tree} -m x"}}'

p1g=$(happy_project); cleanup_projects+=("$p1g")
expect_silent_exit "git commit-graph is a different command" \
  "$p1g" '{"tool_input":{"command":"git commit-graph write"}}'

# ============================================================
# Section 2: Projects without .bionic/memory/ → silent
# Covers R5.
# ============================================================
echo ""
echo "=== Section 2: No .bionic/memory/ — always silent ==="

p2=$(make_project); cleanup_projects+=("$p2")
# No .bionic/memory/. Still put a real commit on HEAD.
echo "work" > "$p2/file.txt"
git -C "$p2" add file.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
git -C "$p2" commit --quiet -m "x"
expect_silent_exit "commit in project without .bionic/memory/" \
  "$p2" "$COMMIT_CMD"

# ============================================================
# Section 3: Debounce via context.md mtime < 60 sec
# Covers R6.
# ============================================================
echo ""
echo "=== Section 3: Debounce — recent context.md means silent ==="

p3=$(make_project); cleanup_projects+=("$p3")
mkdir -p "$p3/.bionic/memory"
: > "$p3/.bionic/memory/context.md"  # touched right now
echo "work" > "$p3/file.txt"
git -C "$p3" add file.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
git -C "$p3" commit --quiet -m "x"
expect_silent_exit "recent context.md within 60 sec — silent" \
  "$p3" "$COMMIT_CMD"

# ============================================================
# Section 4: Circular guard — HEAD only-.bionic/memory/
# Covers R7.
# ============================================================
echo ""
echo "=== Section 4: .bionic/memory/-only HEAD commit — silent ==="

p4=$(make_project); cleanup_projects+=("$p4")
mkdir -p "$p4/.bionic/memory"
age_context "$p4"
echo "# memory" > "$p4/.bionic/memory/topic.md"
git -C "$p4" add .bionic/memory/topic.md
GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
git -C "$p4" commit --quiet -m "save memory"
expect_silent_exit "HEAD touches only .bionic/memory/ — silent (circular guard)" \
  "$p4" "$COMMIT_CMD"

# Mixed commit should NOT be filtered out.
p4b=$(make_project); cleanup_projects+=("$p4b")
mkdir -p "$p4b/.bionic/memory"
age_context "$p4b"
echo "work" > "$p4b/file.txt"
echo "# memory" > "$p4b/.bionic/memory/topic.md"
git -C "$p4b" add file.txt .bionic/memory/topic.md
GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
git -C "$p4b" commit --quiet -m "mixed"
expect_block_decision "HEAD mixes .bionic/memory/ and other files — block" \
  "$p4b" "$COMMIT_CMD"

# Merge commits are a known edge: `git show --name-only` without `-m`
# emits nothing for clean merges, so the circular guard would falsely
# skip any amend of a merge whose parents diverged cleanly. The hook
# uses `git show -m --name-only` to avoid this trap. This test
# regression-proofs the fix.
p4c=$(make_project); cleanup_projects+=("$p4c")
mkdir -p "$p4c/.bionic/memory"
age_context "$p4c"
git -C "$p4c" checkout --quiet -b feature
echo "feat" > "$p4c/feat.txt"
git -C "$p4c" add feat.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
git -C "$p4c" commit --quiet -m "feature work"
git -C "$p4c" checkout --quiet main 2>/dev/null || git -C "$p4c" checkout --quiet master
echo "main" > "$p4c/main.txt"
git -C "$p4c" add main.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
git -C "$p4c" commit --quiet -m "main work"
GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
git -C "$p4c" merge --quiet --no-ff feature -m "merge feature"
expect_block_decision "merge commit HEAD with non-memory files — block" \
  "$p4c" "$COMMIT_CMD"

# ============================================================
# Section 5: Happy-path block decisions
# Covers R8 (canonical), R9 (amend), R10a (segmented), R8 (inline env).
# ============================================================
echo ""
echo "=== Section 5: Happy path — block ==="

p5a=$(happy_project); cleanup_projects+=("$p5a")
expect_block_decision "plain git commit, aged ctx, non-memory HEAD — block" \
  "$p5a" "$COMMIT_CMD"

p5b=$(happy_project); cleanup_projects+=("$p5b")
expect_block_decision "git commit --amend — block" \
  "$p5b" '{"tool_input":{"command":"git commit --amend --no-edit"}}'

p5c=$(happy_project); cleanup_projects+=("$p5c")
expect_block_decision "git status && git commit -m \"work\" (segmented) — block" \
  "$p5c" '{"tool_input":{"command":"git status && git commit -m \"work\""}}'

p5d=$(happy_project); cleanup_projects+=("$p5d")
expect_block_decision "inline env var prefix + git commit — block" \
  "$p5d" '{"tool_input":{"command":"GIT_AUTHOR_DATE=2026-01-01T00:00:00 git commit -m x"}}'

# ============================================================
# Section 6: PROJECT_DIR fallback from JSON .cwd
# Covers R11.
# ============================================================
echo ""
echo "=== Section 6: cwd fallback when CLAUDE_PROJECT_DIR unset ==="

p6=$(happy_project); cleanup_projects+=("$p6")
TOTAL=$((TOTAL + 1))
stdout=$(env -u CLAUDE_PROJECT_DIR bash "$HOOK" \
         <<< "{\"cwd\":\"$p6\",\"tool_input\":{\"command\":\"git commit -m x\"}}" \
         2>/dev/null || true)
if echo "$stdout" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  echo "PASS: cwd fallback from JSON input"
  PASS=$((PASS + 1))
else
  echo "FAIL: cwd fallback"
  echo "  stdout='$stdout'"
  FAIL=$((FAIL + 1))
fi

# ============================================================
# Section 7: Non-git directory → silent
# Covers R12.
# ============================================================
echo ""
echo "=== Section 7: non-git directory ==="

p7=$(mktemp -d); cleanup_projects+=("$p7")
mkdir -p "$p7/.bionic/memory"
age_context "$p7"
expect_silent_exit "non-git project with commit-shaped input — silent" \
  "$p7" "$COMMIT_CMD"

# ============================================================
# Results
# ============================================================
echo ""
echo "========================================"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
