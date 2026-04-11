#!/bin/bash
# Tests for protect-main.sh Claude Code hook.
# Runs the hook against a matrix of push commands x branch states,
# verifying that pushes to main/master are always blocked and
# pushes to feature branches are allowed.
#
# Usage: bash hooks/protect-main.test.sh

set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/protect-main.sh"
PASS=0
FAIL=0
TOTAL=0

# ---------- helpers ----------

run_hook() {
  # Feeds a simulated tool_input to the hook on stdin.
  local cmd="$1"
  echo "{\"tool_input\":{\"command\":\"$cmd\"}}" | bash "$HOOK" 2>/dev/null
}

expect_block() {
  local label="$1"
  local cmd="$2"
  TOTAL=$((TOTAL + 1))
  if run_hook "$cmd"; then
    echo "FAIL (expected BLOCK): $label"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $label"
    PASS=$((PASS + 1))
  fi
}

expect_allow() {
  local label="$1"
  local cmd="$2"
  TOTAL=$((TOTAL + 1))
  if run_hook "$cmd"; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected ALLOW): $label"
    FAIL=$((FAIL + 1))
  fi
}

# ---------- setup: fake git that reports a controllable branch ----------

FAKE_BIN=$(mktemp -d)
cat > "$FAKE_BIN/git" << 'FAKEGIT'
#!/bin/bash
# Intercept "git symbolic-ref --short HEAD" and return $FAKE_BRANCH.
# Pass everything else through to real git.
if [[ "$*" == "symbolic-ref --short HEAD" ]]; then
  echo "${FAKE_BRANCH:-main}"
  exit 0
fi
# Fall through to real git for any other sub-command
REAL_GIT=$(which -a git | grep -v "$FAKE_BIN" | head -1)
exec "$REAL_GIT" "$@"
FAKEGIT
chmod +x "$FAKE_BIN/git"

export PATH="$FAKE_BIN:$PATH"

cleanup() { rm -rf "$FAKE_BIN"; }
trap cleanup EXIT

# ============================================================
# SECTION 1: On main branch — every push must be blocked
# ============================================================

echo ""
echo "=== Section 1: On 'main' branch (all pushes must be BLOCKED) ==="
export FAKE_BRANCH="main"

expect_block "explicit: push origin main"            "git push origin main"
expect_block "explicit: push upstream main"           "git push upstream main"
expect_block "explicit: push origin master"           "git push origin master"
expect_block "bare push"                              "git push"
expect_block "push origin (implicit branch)"          "git push origin"
expect_block "push origin HEAD"                       "git push origin HEAD"
expect_block "push -u origin main"                    "git push -u origin main"
expect_block "push --set-upstream origin main"        "git push --set-upstream origin main"
expect_block "push origin HEAD:main"                  "git push origin HEAD:main"
expect_block "push origin HEAD:refs/heads/main"       "git push origin HEAD:refs/heads/main"
expect_block "force push -f"                          "git push -f origin main"
expect_block "force push --force"                     "git push --force origin main"
expect_block "force push --force-with-lease"          "git push --force-with-lease origin main"
expect_block "push in compound command"               "cd /tmp && git push origin"
expect_block "push with env prefix"                   "GIT_SSH_COMMAND=ssh git push origin main"
expect_block "compound with ||"                       "false || git push origin main"
expect_block "force push flag at end"                 "git push origin main -f"
expect_block "force push --force at end"              "git push origin feat/x --force"
expect_block "refspec push HEAD:main"                 "git push origin HEAD:main"

# ============================================================
# SECTION 2: On master branch — every push must be blocked
# ============================================================

echo ""
echo "=== Section 2: On 'master' branch (all pushes must be BLOCKED) ==="
export FAKE_BRANCH="master"

expect_block "master: bare push"                      "git push"
expect_block "master: push origin"                    "git push origin"
expect_block "master: push origin HEAD"               "git push origin HEAD"
expect_block "master: push origin master"             "git push origin master"

# ============================================================
# SECTION 3: On feature branch — non-main pushes must be allowed
# ============================================================

echo ""
echo "=== Section 3: On feature branch (safe pushes must be ALLOWED) ==="
export FAKE_BRANCH="feat/cool-thing"

expect_allow "feature: push origin feat/cool-thing"   "git push origin feat/cool-thing"
expect_allow "feature: push -u origin feat/cool-thing" "git push -u origin feat/cool-thing"
expect_allow "feature: bare push"                     "git push"
expect_allow "feature: push origin"                   "git push origin"
expect_allow "feature: push origin HEAD"              "git push origin HEAD"

# Even from a feature branch, explicit main/master must be blocked
expect_block "feature: push origin main (explicit)"   "git push origin main"
expect_block "feature: push origin master (explicit)"  "git push origin master"

# Force pushes always blocked regardless of branch
expect_block "feature: force push -f"                 "git push -f origin feat/cool-thing"
expect_block "feature: force push --force"            "git push --force origin feat/cool-thing"
expect_block "feature: force push --force-with-lease"  "git push --force-with-lease origin feat/cool-thing"

# Branch names containing "main" as substring should be allowed
expect_allow "feature: push branch with main substring" "git push origin feat/maintain-state"
expect_allow "feature: push domain-main branch"        "git push origin domain-main-fix"

# ============================================================
# SECTION 4: Non-push commands must always pass through
# ============================================================

echo ""
echo "=== Section 4: Non-push commands (must be ALLOWED) ==="
export FAKE_BRANCH="main"

expect_allow "git status"                             "git status"
expect_allow "git log"                                "git log --oneline -5"
expect_allow "git diff"                               "git diff HEAD~1"
expect_allow "git commit"                             "git commit -m 'test'"
expect_allow "git pull"                               "git pull origin main"
expect_allow "git fetch"                              "git fetch origin"
expect_allow "git branch"                             "git branch -a"
expect_allow "echo with push in string"               "echo 'not a git push'"
expect_allow "commit message mentioning push"          "git commit -m 'fix: close git push gaps in hook'"
expect_allow "ls command"                             "ls -la"
expect_allow "grep mentioning git push"               "grep 'git push' README.md"
expect_allow "cat file with push content"             "cat deploy.sh"

# Regression: commands with GIT_ env var prefix that are NOT pushes must pass.
# Previously the ^GIT_ alternative in the segment regex caught any command
# starting with GIT_, even git commit with a GIT_AUTHOR_DATE prefix.
expect_allow "GIT_AUTHOR_DATE prefix on commit"       "GIT_AUTHOR_DATE='2026-04-11' git commit -m 'test'"
expect_allow "GIT_COMMITTER_DATE prefix on commit"    "GIT_COMMITTER_DATE='2026-04-11' git commit -m 'test'"
expect_allow "env GIT_AUTHOR_DATE on commit"          "env GIT_AUTHOR_DATE='2026-04-11' git commit -m 'test'"

# But GIT_ env var prefix on an actual push MUST still be caught by the
# downstream "git push anywhere in segment" check.
expect_block "GIT_SSH_COMMAND prefix on push"         "GIT_SSH_COMMAND=ssh git push origin main"
expect_block "GIT_ASKPASS prefix on push"             "GIT_ASKPASS=cat git push origin main"

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
