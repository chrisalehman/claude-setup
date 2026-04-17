#!/bin/bash
# AUTO-UPDATE (Stop, fallback): Prompts Claude to save session state to
# .bionic/memory/ at turn end. Fires on Stop. Only activates when:
#   1. The project has adopted the .bionic/memory/ notebook
#   2. context.md hasn't been touched in the last 45 minutes (debounce)
#   3. The project has meaningful git activity worth recording
#   4. We're not already in a stop-hook-triggered continuation (loop guard)
#
# Fallback role: memory-commit-save.sh (PostToolUse|Bash) is the primary
# trigger — commits are the natural unit-of-work boundary. This Stop
# hook's longer 45-min debounce catches sessions with meaningful state
# that hasn't yet been committed (exploratory debug, multi-turn
# investigation, writing before committing).
#
# When it fires, it returns a block decision with a reason that Claude
# reads as in-turn feedback — Claude updates memory, then the Stop hook
# runs again with stop_hook_active=true and exits cleanly.
#
# Installed globally by claude-bootstrap.sh to ~/.claude/hooks/

set -u

INPUT=$(cat)

# Loop guard: if Claude is already in a stop-hook-triggered continuation,
# never block again. This is the Claude Code contract for Stop hooks.
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

# Resolve the project directory. CLAUDE_PROJECT_DIR is the canonical
# source; fall back to the hook input's cwd field, then to pwd.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
fi
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR=$(pwd)
fi

MEMORY_DIR="${PROJECT_DIR}/.bionic/memory"

# The project hasn't adopted the notebook — nothing to update.
if [ ! -d "$MEMORY_DIR" ]; then
  exit 0
fi

# Debounce: if context.md was touched in the last 45 minutes, skip.
# Uses find -mmin which is portable across macOS and Linux.
# Rationale: the primary save path is memory-commit-save.sh (PostToolUse
# on git commit). This Stop hook is the fallback for commitless bursts,
# so the window widens from the original 15 min to 45 min — enough to
# catch a long exploration but coarse enough not to compete with the
# commit path for normal development.
if [ -f "${MEMORY_DIR}/context.md" ] && \
   find "${MEMORY_DIR}/context.md" -mmin -45 2>/dev/null | grep -q .; then
  exit 0
fi

# Only update memory if the project has meaningful state worth recording.
# Heuristic: uncommitted changes to tracked files (excluding the memory
# directory itself, which would be circular) OR commits in the last 30 min.
cd "$PROJECT_DIR" 2>/dev/null || exit 0
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  # Not a git repo — can't assess activity. Exit quietly.
  exit 0
fi

HAS_ACTIVITY=0
# Uncommitted changes outside .bionic/memory/. Two subtleties:
#   - Use -uall so untracked directories are expanded to individual files;
#     default porcelain collapses a fully-untracked dir into a single entry
#     like "?? .bionic/" which defeats path-based filtering.
#   - Porcelain format is "XY path" where XY is a two-char status and
#     column 4 is the path; slice the prefix and test whether the
#     remaining path is inside .bionic/memory/, which we want to ignore
#     (circular: the hook writes there, so it would trigger itself).
if git status --porcelain -uall 2>/dev/null \
   | awk '{ if (substr($0, 4) !~ /^\.bionic\/memory\//) print }' \
   | grep -q .; then
  HAS_ACTIVITY=1
fi
# Recent commits
if [ "$HAS_ACTIVITY" -eq 0 ]; then
  recent_commits=$(git log --since='30 minutes ago' --oneline 2>/dev/null | wc -l | tr -d ' ')
  if [ "${recent_commits:-0}" -gt 0 ]; then
    HAS_ACTIVITY=1
  fi
fi

if [ "$HAS_ACTIVITY" -eq 0 ]; then
  exit 0
fi

# Block the stop and inject instructions. Claude will read the reason,
# update memory in the current turn, then the next Stop will fire with
# stop_hook_active=true and exit cleanly via the guard at the top.
REASON='Auto-save to .bionic/memory/: briefly update context.md with current branch, what changed this session, and next steps. If any correction or lesson emerged, add a one-liner rule to INDEX.md under "Always Apply". Keep edits minimal — only real changes. Follow the protocol in ~/.claude/CLAUDE.md. If nothing meaningful to save, make no edits and respond with "memory already current."'

jq -n --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
