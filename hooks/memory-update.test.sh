#!/bin/bash
# Tests for memory-update.sh Stop hook.
# Verifies the hook exits cleanly when there's nothing to save and blocks
# with a reason when there is. Each test runs in an isolated temp project.
#
# Usage: bash hooks/memory-update.test.sh

set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/memory-update.sh"
PASS=0
FAIL=0
TOTAL=0

# ---------- helpers ----------

# Creates a fresh isolated project dir and returns its path on stdout.
# The initial commit is back-dated so `git log --since='30 minutes ago'`
# (the hook's activity check) doesn't treat test setup itself as activity.
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

# Runs the hook against the given project dir with the given JSON input.
# Sets globals HOOK_EXIT and HOOK_STDOUT.
run_hook() {
  local project="$1"
  local input="$2"
  HOOK_STDOUT=$(CLAUDE_PROJECT_DIR="$project" bash "$HOOK" <<< "$input" 2>/dev/null) || true
  HOOK_EXIT=$?
}

expect_silent_exit() {
  local label="$1" project="$2" input="${3:-{\}}"
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
  local label="$1" project="$2" input="${3:-{\}}"
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

# ============================================================
# Section 1: Projects without .bionic/memory/
# ============================================================

echo ""
echo "=== Section 1: No .bionic/memory/ — always silent ==="

p1=$(make_project); cleanup_projects+=("$p1")
expect_silent_exit "no .bionic/memory/ dir" "$p1" '{}'

p1b=$(make_project); cleanup_projects+=("$p1b")
echo "modified" > "$p1b/README.md"  # create activity
expect_silent_exit "no .bionic/memory/ dir even with uncommitted changes" "$p1b" '{}'

# ============================================================
# Section 2: stop_hook_active loop guard
# ============================================================

echo ""
echo "=== Section 2: stop_hook_active loop guard ==="

p2=$(make_project); cleanup_projects+=("$p2")
mkdir -p "$p2/.bionic/memory"
# Make context.md old so debounce would not block us
touch -t 202601010000 "$p2/.bionic/memory/context.md" 2>/dev/null || \
  touch -d "2026-01-01" "$p2/.bionic/memory/context.md" 2>/dev/null || true
# Also create uncommitted activity
echo "dirty" > "$p2/newfile.txt"

expect_silent_exit "stop_hook_active=true exits silently (loop guard)" \
  "$p2" '{"stop_hook_active": true}'

# Sanity: same project WITHOUT stop_hook_active should trigger a block
expect_block_decision "stop_hook_active=false triggers block" \
  "$p2" '{"stop_hook_active": false}'

# ============================================================
# Section 3: Debounce via context.md mtime
# ============================================================

echo ""
echo "=== Section 3: Debounce — recent context.md means silent exit ==="

p3=$(make_project); cleanup_projects+=("$p3")
mkdir -p "$p3/.bionic/memory"
# context.md touched RIGHT NOW — should debounce
touch "$p3/.bionic/memory/context.md"
echo "dirty" > "$p3/newfile.txt"
expect_silent_exit "recent context.md within 45 min — silent" "$p3" '{}'

p3b=$(make_project); cleanup_projects+=("$p3b")
mkdir -p "$p3b/.bionic/memory"
# Old context.md (hours ago)
touch -t 202601010000 "$p3b/.bionic/memory/context.md" 2>/dev/null || \
  touch -d "2026-01-01" "$p3b/.bionic/memory/context.md" 2>/dev/null || true
echo "dirty" > "$p3b/newfile.txt"
expect_block_decision "old context.md plus dirty tree — block" "$p3b" '{}'

# ============================================================
# Section 4: Git activity gating
# ============================================================

echo ""
echo "=== Section 4: Git activity gating ==="

p4=$(make_project); cleanup_projects+=("$p4")
mkdir -p "$p4/.bionic/memory"
# Old context.md so debounce doesn't interfere
touch -t 202601010000 "$p4/.bionic/memory/context.md" 2>/dev/null || \
  touch -d "2026-01-01" "$p4/.bionic/memory/context.md" 2>/dev/null || true
# No uncommitted changes — clean working tree
expect_silent_exit "clean working tree, no recent commits — silent" "$p4" '{}'

# Create uncommitted change — should block
echo "dirty" > "$p4/newfile.txt"
expect_block_decision "uncommitted change — block" "$p4" '{}'

# Now commit the change and verify recent commit still triggers
git -C "$p4" add newfile.txt
git -C "$p4" commit --quiet -m "add newfile"
expect_block_decision "recent commit (within 30 min) — block" "$p4" '{}'

# ============================================================
# Section 5: Memory-dir-only changes do NOT count as activity
# ============================================================

echo ""
echo "=== Section 5: Memory-dir-only changes don't retrigger ==="

p5=$(make_project); cleanup_projects+=("$p5")
mkdir -p "$p5/.bionic/memory"
touch -t 202601010000 "$p5/.bionic/memory/context.md" 2>/dev/null || \
  touch -d "2026-01-01" "$p5/.bionic/memory/context.md" 2>/dev/null || true
# Create a new file ONLY under .bionic/memory/ — git status will show it
# but the hook should filter it out and exit silently.
echo "new rule" > "$p5/.bionic/memory/testing.md"
expect_silent_exit "dirty only under .bionic/memory/ — silent" "$p5" '{}'

# ============================================================
# Section 6: Not a git repo
# ============================================================

echo ""
echo "=== Section 6: Non-git directory ==="

p6=$(mktemp -d); cleanup_projects+=("$p6")
mkdir -p "$p6/.bionic/memory"
echo "junk" > "$p6/file.txt"
expect_silent_exit "non-git project — silent" "$p6" '{}'

# ============================================================
# Section 7: Fallback to cwd from input JSON when env var unset
# ============================================================

echo ""
echo "=== Section 7: cwd fallback from JSON input ==="

p7=$(make_project); cleanup_projects+=("$p7")
mkdir -p "$p7/.bionic/memory"
touch -t 202601010000 "$p7/.bionic/memory/context.md" 2>/dev/null || \
  touch -d "2026-01-01" "$p7/.bionic/memory/context.md" 2>/dev/null || true
echo "dirty" > "$p7/newfile.txt"

TOTAL=$((TOTAL + 1))
stdout=$(env -u CLAUDE_PROJECT_DIR bash "$HOOK" <<< "{\"cwd\": \"$p7\"}" 2>/dev/null || true)
if echo "$stdout" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  echo "PASS: cwd from JSON input when CLAUDE_PROJECT_DIR unset"
  PASS=$((PASS + 1))
else
  echo "FAIL: cwd fallback"
  echo "  stdout='$stdout'"
  FAIL=$((FAIL + 1))
fi

# ============================================================
# Section 8: canonical-sdlc continuation-checkpoint instruction
# ============================================================

echo ""
echo "=== Section 8: Continuation-checkpoint addendum for active SDLC runs ==="

# Helper: expect block AND check for presence/absence of checkpoint text.
expect_block_with_text() {
  local label="$1" project="$2" input="$3" needle="$4"
  TOTAL=$((TOTAL + 1))
  run_hook "$project" "$input"
  if [ "$HOOK_EXIT" -eq 0 ] \
     && echo "$HOOK_STDOUT" | jq -e '.decision == "block"' >/dev/null 2>&1 \
     && echo "$HOOK_STDOUT" | jq -r '.reason' | grep -q "$needle"; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    echo "  exit=$HOOK_EXIT stdout='$HOOK_STDOUT'"
    FAIL=$((FAIL + 1))
  fi
}

expect_block_without_text() {
  local label="$1" project="$2" input="$3" needle="$4"
  TOTAL=$((TOTAL + 1))
  run_hook "$project" "$input"
  if [ "$HOOK_EXIT" -eq 0 ] \
     && echo "$HOOK_STDOUT" | jq -e '.decision == "block"' >/dev/null 2>&1 \
     && ! echo "$HOOK_STDOUT" | jq -r '.reason' | grep -q "$needle"; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    echo "  exit=$HOOK_EXIT stdout='$HOOK_STDOUT'"
    FAIL=$((FAIL + 1))
  fi
}

# Project with active canonical-sdlc plan (## SDLC State present)
p8a=$(make_project); cleanup_projects+=("$p8a")
mkdir -p "$p8a/.bionic/memory"
touch -t 202601010000 "$p8a/.bionic/memory/context.md" 2>/dev/null || \
  touch -d "2026-01-01" "$p8a/.bionic/memory/context.md" 2>/dev/null || true
echo "dirty" > "$p8a/newfile.txt"
mkdir -p "$p8a/docs/bionic/plans/epic-01-demo"
cat > "$p8a/docs/bionic/plans/epic-01-demo/wave-01-x.plan.md" <<'EOF'
# plan

## SDLC State
mode: full
current: 5
Step 1: /x
Step 5: mid-implementation
EOF
expect_block_with_text "active SDLC run → reason includes continuation-checkpoint" \
  "$p8a" '{}' 'continuation-checkpoint.md'

# Project with a plans dir but no SDLC State in the plan — no addendum
p8b=$(make_project); cleanup_projects+=("$p8b")
mkdir -p "$p8b/.bionic/memory"
touch -t 202601010000 "$p8b/.bionic/memory/context.md" 2>/dev/null || \
  touch -d "2026-01-01" "$p8b/.bionic/memory/context.md" 2>/dev/null || true
echo "dirty" > "$p8b/newfile.txt"
mkdir -p "$p8b/docs/bionic/plans"
echo "# regular plan, no SDLC State" > "$p8b/docs/bionic/plans/random.md"
expect_block_without_text "regular plan (no SDLC State) → no checkpoint addendum" \
  "$p8b" '{}' 'continuation-checkpoint.md'

# Project without any plans dir — no addendum
p8c=$(make_project); cleanup_projects+=("$p8c")
mkdir -p "$p8c/.bionic/memory"
touch -t 202601010000 "$p8c/.bionic/memory/context.md" 2>/dev/null || \
  touch -d "2026-01-01" "$p8c/.bionic/memory/context.md" 2>/dev/null || true
echo "dirty" > "$p8c/newfile.txt"
expect_block_without_text "no plans dir → no checkpoint addendum" \
  "$p8c" '{}' 'continuation-checkpoint.md'

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
