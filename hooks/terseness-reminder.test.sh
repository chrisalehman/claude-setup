#!/bin/bash
# Tests for terseness-reminder.sh
#
# Strategy: invoke the hook with a synthetic UserPromptSubmit payload
# and verify the emitted JSON has the right shape, references CLAUDE.md,
# carries the load-bearing exemption tokens, stays under the per-turn
# size budget, and is silenced by the disable flag file.
#
# The exemption-tokens assertions are deliberately granular: a future
# "cleanup" that drops the EXEMPT clause must fail this test, not pass
# silently and corrupt structured output downstream.
#
# Usage: bash hooks/terseness-reminder.test.sh

set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/terseness-reminder.sh"
PASS=0
FAIL=0
TOTAL=0

cleanup_dirs=()
cleanup() {
  for d in "${cleanup_dirs[@]}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s (expected=%q actual=%q)\n' "$label" "$expected" "$actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s (missing %q)\n' "$label" "$needle"
  fi
}

run_hook() {
  local prompt="$1"
  local input
  input=$(jq -n --arg p "$prompt" '{prompt: $p}')
  local tmp_out
  tmp_out=$(mktemp)
  if bash "$HOOK" <<< "$input" >"$tmp_out" 2>/dev/null; then
    HOOK_EXIT=0
  else
    HOOK_EXIT=$?
  fi
  HOOK_STDOUT=$(cat "$tmp_out")
  rm -f "$tmp_out"
}

# ---------- cases ----------

echo "Default: hook exits 0 and emits valid UserPromptSubmit JSON"
run_hook "any user prompt"
assert_eq "exit 0" 0 "$HOOK_EXIT"
event=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
assert_eq "hookEventName=UserPromptSubmit" "UserPromptSubmit" "$event"

echo "Payload references CLAUDE.md (rules externalized, not duplicated)"
ctx=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "ctx mentions CLAUDE.md" "CLAUDE.md" "$ctx"

echo "Payload carries load-bearing exemption tokens"
# These four assertions exist to make 'cleanup' that drops the EXEMPT
# clause an explicit test failure. Without these exemptions, terseness
# corrupts structured output that other skills depend on.
assert_contains "exempt: code" "code" "$ctx"
assert_contains "exempt: evidence blocks" "evidence blocks" "$ctx"
assert_contains "exempt: commit messages" "commit messages" "$ctx"
assert_contains "exempt: security warnings" "security warnings" "$ctx"

echo "Payload includes BLUF directive (lead with the answer)"
assert_contains "BLUF directive" "Lead with the answer" "$ctx"

echo "Payload size is bounded (<500 chars per-turn overhead)"
TOTAL=$((TOTAL + 1))
ctx_len=${#ctx}
if [ "$ctx_len" -lt 500 ]; then
  PASS=$((PASS + 1))
  printf '  PASS  context length %d < 500\n' "$ctx_len"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  context length %d ≥ 500 (per-turn bloat risk)\n' "$ctx_len"
fi

echo "Disable flag: HOME-scoped flag file silences the hook"
tmphome=$(mktemp -d)
cleanup_dirs+=("$tmphome")
mkdir -p "$tmphome/.claude"
touch "$tmphome/.claude/.bionic-terse-off"
tmp_out=$(mktemp)
if HOME="$tmphome" bash "$HOOK" <<< '{"prompt":"x"}' >"$tmp_out" 2>/dev/null; then
  HOOK_EXIT=0
else
  HOOK_EXIT=$?
fi
HOOK_STDOUT=$(cat "$tmp_out")
rm -f "$tmp_out"
assert_eq "exit 0 with disable flag" 0 "$HOOK_EXIT"
assert_eq "empty stdout with disable flag" "" "$HOOK_STDOUT"

echo
printf 'Results: %d/%d passed, %d failed\n' "$PASS" "$TOTAL" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
