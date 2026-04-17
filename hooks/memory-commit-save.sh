#!/bin/bash
# AUTO-UPDATE on commit: prompts Claude to save session state to
# .bionic/memory/ after a successful `git commit` (or amend). Fires on
# PostToolUse|Bash and only activates when:
#   1. The tool call's command is a real `git commit` (segment-aware).
#   2. The project has adopted the .bionic/memory/ notebook.
#   3. context.md hasn't been touched in the last 60 seconds (debounce).
#   4. HEAD's files aren't all under .bionic/memory/ (circular guard —
#      the save itself may commit memory; that commit must not re-fire).
#
# When all four gates pass, returns `{"decision":"block","reason":...}`
# which Claude Code renders as in-turn feedback — Claude updates memory,
# then subsequent commits hit the debounce and exit silently.
#
# Complements memory-update.sh (Stop-event fallback, 45-min debounce):
# commits are the natural unit-of-work boundary; the Stop hook catches
# long sessions that haven't committed yet.
#
# Installed globally by claude-bootstrap.sh to ~/.claude/hooks/

set -u

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Not a Bash tool call, or empty command — nothing to do.
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Segment-aware detection of `git commit`. Same pattern as
# protect-main.sh and canonical-sdlc-evidence-gate.sh: split on && / || /
# ; , strip quoted strings so prose inside commit messages doesn't match,
# then look for whole-word `git commit` (not commit-tree, commit-graph).
IS_COMMIT=0
while IFS= read -r segment; do
  segment="${segment#"${segment%%[![:space:]]*}"}"
  stripped=$(echo "$segment" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")
  if echo "$stripped" | grep -qE '(^|[[:space:]])git[[:space:]]+commit([[:space:]]|$)'; then
    IS_COMMIT=1
    break
  fi
done <<< "$(echo "$COMMAND" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g')"

if [ "$IS_COMMIT" -eq 0 ]; then
  exit 0
fi

# Resolve the project dir using the same chain as memory-update.sh.
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

# 60-second debounce on context.md mtime. `find -mmin` rounds to whole
# minutes so we use stat+date arithmetic for sub-minute precision. Try
# GNU stat first (`-c`), fall back to BSD stat (`-f`). Both macOS and
# Linux covered. If stat itself fails, MTIME is empty and we fall
# through to firing the save — a broken stat shouldn't silently
# suppress saves.
CTX="${MEMORY_DIR}/context.md"
if [ -f "$CTX" ]; then
  MTIME=$(stat -c '%Y' "$CTX" 2>/dev/null || stat -f '%m' "$CTX" 2>/dev/null || true)
  NOW=$(date +%s)
  if [ -n "$MTIME" ] && [ "$((NOW - MTIME))" -lt 60 ]; then
    exit 0
  fi
fi

cd "$PROJECT_DIR" 2>/dev/null || exit 0
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  # Not a git repo — can't inspect HEAD. Exit quietly.
  exit 0
fi

# Circular guard. The save prompt this hook fires may cause Claude to
# modify (and possibly commit) files under .bionic/memory/. That
# follow-on commit's PostToolUse would otherwise re-fire us. Skip any
# HEAD commit whose file list is entirely under .bionic/memory/.
#
# `git show -m --name-only --format= HEAD` lists the commit's files
# one per line. The `-m` flag is required: without it, merge commits
# emit a combined diff that's empty unless there were conflicts, so a
# clean merge's amend would falsely read as "no files → memory-only."
# `awk` passes through only non-.bionic/memory/ lines; `grep -q .`
# succeeds iff awk emitted anything. Negated: "all paths (if any) are
# .bionic/memory/-only → exit silent."
if ! git show -m --name-only --format= HEAD 2>/dev/null \
     | awk 'NF && $0 !~ /^\.bionic\/memory\//' \
     | grep -q .; then
  exit 0
fi

# Fire. Save prompt is a deliberate near-twin of memory-update.sh's so
# both triggers produce identical save behavior. Difference: reference
# the commit directly, since commits are the narrative unit this hook
# was built around.
REASON='Auto-save to .bionic/memory/ (triggered by commit): briefly update context.md with current branch, the commit subject, what changed this session, and next steps. If any correction or lesson emerged, add a one-liner rule to INDEX.md under "Always Apply". Keep edits minimal — only real changes. Follow the protocol in ~/.claude/CLAUDE.md. If nothing meaningful to save, make no edits and respond with "memory already current."'

jq -n --arg r "$REASON" '{decision: "block", reason: $r}'
exit 0
