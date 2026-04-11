#!/bin/bash
# Tests for memory-cleanup.sh SessionStart hook.
# Verifies the hook exits silently when no stale files exist and emits
# hookSpecificOutput.additionalContext when topical files are past their
# 30-day freshness window.
#
# Usage: bash hooks/memory-cleanup.test.sh

set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/memory-cleanup.sh"
PASS=0
FAIL=0
TOTAL=0

# ---------- helpers ----------

# Portable date printer: echo a YYYY-MM-DD string N days ago.
days_ago() {
  local n="$1"
  if [ "$(uname)" = "Darwin" ]; then
    date -v-"${n}"d +%Y-%m-%d
  else
    date -d "${n} days ago" +%Y-%m-%d
  fi
}

make_project() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/.bionic/memory"
  echo "$dir"
}

# Write a topical file with `updated:` set to N days ago.
write_topical_file() {
  local project="$1" name="$2" days="$3"
  cat > "$project/.bionic/memory/$name" <<EOF
---
updated: $(days_ago "$days")
---

# ${name%.md}

Sample content.
EOF
}

run_hook() {
  local project="$1"
  local input="${2:-{\}}"
  HOOK_STDOUT=$(CLAUDE_PROJECT_DIR="$project" bash "$HOOK" <<< "$input" 2>/dev/null) || true
  HOOK_EXIT=$?
}

expect_silent_exit() {
  local label="$1" project="$2"
  TOTAL=$((TOTAL + 1))
  run_hook "$project"
  if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected silent exit 0): $label"
    echo "  exit=$HOOK_EXIT stdout='$HOOK_STDOUT'"
    FAIL=$((FAIL + 1))
  fi
}

expect_additional_context() {
  local label="$1" project="$2" needle="$3"
  TOTAL=$((TOTAL + 1))
  run_hook "$project"
  if [ "$HOOK_EXIT" -ne 0 ]; then
    echo "FAIL (exit=$HOOK_EXIT): $label"
    FAIL=$((FAIL + 1))
    return
  fi
  local ctx
  ctx=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  if [ -z "$ctx" ]; then
    echo "FAIL (no additionalContext): $label"
    echo "  stdout='$HOOK_STDOUT'"
    FAIL=$((FAIL + 1))
    return
  fi
  if echo "$ctx" | grep -qF "$needle"; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL (context missing '$needle'): $label"
    echo "  context='$ctx'"
    FAIL=$((FAIL + 1))
  fi
}

expect_hookevent_name() {
  local label="$1" project="$2"
  TOTAL=$((TOTAL + 1))
  run_hook "$project"
  local name
  name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
  if [ "$name" = "SessionStart" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL (hookEventName='$name'): $label"
    FAIL=$((FAIL + 1))
  fi
}

cleanup_projects=()
cleanup() { for d in "${cleanup_projects[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# ============================================================
# Section 1: No memory dir
# ============================================================

echo ""
echo "=== Section 1: Project without .bionic/memory/ ==="

p1=$(mktemp -d); cleanup_projects+=("$p1")
TOTAL=$((TOTAL + 1))
run_hook "$p1"
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ]; then
  echo "PASS: no .bionic/memory/ — silent exit"
  PASS=$((PASS + 1))
else
  echo "FAIL: silent exit expected"
  FAIL=$((FAIL + 1))
fi

# ============================================================
# Section 2: Empty memory dir
# ============================================================

echo ""
echo "=== Section 2: Empty .bionic/memory/ ==="

p2=$(make_project); cleanup_projects+=("$p2")
expect_silent_exit "empty memory dir — silent" "$p2"

# ============================================================
# Section 3: Only INDEX.md and context.md — never stale
# ============================================================

echo ""
echo "=== Section 3: INDEX.md and context.md are never stale ==="

p3=$(make_project); cleanup_projects+=("$p3")
cat > "$p3/.bionic/memory/INDEX.md" <<EOF
# Notebook
## Always Apply
- test rule
EOF
cat > "$p3/.bionic/memory/context.md" <<EOF
---
updated: $(days_ago 365)
---
# Active work
EOF
expect_silent_exit "INDEX.md and very-old context.md — still silent" "$p3"

# ============================================================
# Section 4: Fresh topical file
# ============================================================

echo ""
echo "=== Section 4: Fresh topical file within 30 days ==="

p4=$(make_project); cleanup_projects+=("$p4")
write_topical_file "$p4" "auth.md" 5
write_topical_file "$p4" "deploy.md" 29
expect_silent_exit "all topical files fresh — silent" "$p4"

# ============================================================
# Section 5: Stale topical file
# ============================================================

echo ""
echo "=== Section 5: Stale topical file triggers additionalContext ==="

p5=$(make_project); cleanup_projects+=("$p5")
write_topical_file "$p5" "auth.md" 45
expect_additional_context "single stale file listed" "$p5" "auth.md"
expect_hookevent_name "hookEventName is SessionStart" "$p5"

# ============================================================
# Section 6: Mix of stale and fresh files
# ============================================================

echo ""
echo "=== Section 6: Mix of stale and fresh — only stale listed ==="

p6=$(make_project); cleanup_projects+=("$p6")
write_topical_file "$p6" "old-migration.md" 90
write_topical_file "$p6" "fresh-decisions.md" 3
write_topical_file "$p6" "ancient.md" 400
expect_additional_context "stale file 'old-migration.md' listed" "$p6" "old-migration.md"

run_hook "$p6"
ctx=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
TOTAL=$((TOTAL + 1))
if echo "$ctx" | grep -q "fresh-decisions.md"; then
  echo "FAIL: fresh-decisions.md should NOT be listed"
  FAIL=$((FAIL + 1))
else
  echo "PASS: fresh file excluded from stale list"
  PASS=$((PASS + 1))
fi

TOTAL=$((TOTAL + 1))
if echo "$ctx" | grep -q "ancient.md"; then
  echo "PASS: very-old file also listed"
  PASS=$((PASS + 1))
else
  echo "FAIL: ancient.md should be listed"
  FAIL=$((FAIL + 1))
fi

# ============================================================
# Section 7: Malformed or missing frontmatter
# ============================================================

echo ""
echo "=== Section 7: Files without valid frontmatter are skipped ==="

p7=$(make_project); cleanup_projects+=("$p7")
# No frontmatter at all
cat > "$p7/.bionic/memory/no-frontmatter.md" <<'EOF'
Just some text, no frontmatter.
EOF
# Malformed date
cat > "$p7/.bionic/memory/bad-date.md" <<'EOF'
---
updated: not-a-date
---
Content.
EOF
expect_silent_exit "no frontmatter and bad date — silent (nothing stale)" "$p7"

# Add one legitimately stale file — should still trigger on that one
write_topical_file "$p7" "legit-stale.md" 50
expect_additional_context "legit stale file listed despite malformed siblings" "$p7" "legit-stale.md"

# ============================================================
# Section 8: cwd fallback from JSON input
# ============================================================

echo ""
echo "=== Section 8: cwd fallback when CLAUDE_PROJECT_DIR unset ==="

p8=$(make_project); cleanup_projects+=("$p8")
write_topical_file "$p8" "legacy.md" 60

TOTAL=$((TOTAL + 1))
stdout=$(env -u CLAUDE_PROJECT_DIR bash "$HOOK" <<< "{\"cwd\": \"$p8\"}" 2>/dev/null || true)
if echo "$stdout" | jq -e '.hookSpecificOutput.additionalContext | contains("legacy.md")' >/dev/null 2>&1; then
  echo "PASS: cwd from JSON input"
  PASS=$((PASS + 1))
else
  echo "FAIL: cwd fallback"
  echo "  stdout='$stdout'"
  FAIL=$((FAIL + 1))
fi

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
