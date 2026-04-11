#!/bin/bash
# AUTO-CLEANUP: Scans .bionic/memory/ topical files for stale `updated:`
# frontmatter (older than 30 days) and injects instructions for Claude
# to verify, prune, or consolidate. Fires on SessionStart with the
# "startup" matcher so it runs once per fresh session.
#
# INDEX.md and context.md are never considered stale — only topical files
# (<topic>.md with YAML frontmatter containing `updated:`).
#
# When stale files are found, emits hookSpecificOutput.additionalContext
# so Claude picks up cleanup instructions silently at session start.
# When nothing is stale, exits silently.
#
# Installed globally by claude-bootstrap.sh to ~/.claude/hooks/

set -u

INPUT=$(cat)

# Resolve the project directory. CLAUDE_PROJECT_DIR is the canonical
# source; fall back to the hook input's cwd field.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
fi
if [ -z "$PROJECT_DIR" ]; then
  exit 0
fi

MEMORY_DIR="${PROJECT_DIR}/.bionic/memory"
if [ ! -d "$MEMORY_DIR" ]; then
  exit 0
fi

# Cross-platform epoch conversion for YYYY-MM-DD dates.
# Returns 0 (treated as missing/unknown) on parse failure.
date_to_epoch() {
  local date_str="$1"
  if [ "$(uname)" = "Darwin" ]; then
    date -j -f "%Y-%m-%d" "$date_str" +%s 2>/dev/null || echo 0
  else
    date -d "$date_str" +%s 2>/dev/null || echo 0
  fi
}

NOW_EPOCH=$(date +%s)
THIRTY_DAYS=2592000  # 30 * 86400

STALE_LIST=""
for file in "$MEMORY_DIR"/*.md; do
  [ -f "$file" ] || continue
  base=$(basename "$file")

  # INDEX.md and context.md never expire per the protocol.
  [ "$base" = "INDEX.md" ] && continue
  [ "$base" = "context.md" ] && continue

  # Extract the first `updated:` value from the YAML frontmatter.
  # Frontmatter is delimited by lines containing only "---" at file start.
  updated=$(awk '
    BEGIN { inside = 0; lines = 0 }
    /^---[[:space:]]*$/ {
      if (inside == 0 && lines == 0) { inside = 1; lines++; next }
      if (inside == 1) { exit }
    }
    inside == 1 && /^updated:[[:space:]]*/ {
      sub(/^updated:[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      # Strip surrounding quotes if present
      gsub(/^["'\'']|["'\'']$/, "")
      print
      exit
    }
    { lines++ }
  ' "$file")

  [ -z "$updated" ] && continue

  file_epoch=$(date_to_epoch "$updated")
  [ "${file_epoch:-0}" -eq 0 ] && continue

  age=$((NOW_EPOCH - file_epoch))
  if [ "$age" -gt "$THIRTY_DAYS" ]; then
    age_days=$((age / 86400))
    STALE_LIST="${STALE_LIST}- ${base} (${age_days} days since last update)
"
  fi
done

if [ -z "$STALE_LIST" ]; then
  exit 0
fi

# Emit additionalContext telling Claude to clean up before starting work.
CONTEXT="Memory auto-cleanup: the following topical files in .bionic/memory/ are past their 30-day freshness window:

${STALE_LIST}
Before starting the user's task, spend one pass doing the following:
1. For each stale file, check if the content is still accurate relative to the current codebase. If yes, bump its \`updated:\` frontmatter date. If no, delete it or rewrite it.
2. Review INDEX.md — consolidate duplicate rules, remove rules that have been superseded, and move any Always Apply entries that have grown into real context into their own topical file.
3. Skip files that the user's task will naturally touch — those will get updated during the work.

Keep this fast. This is tidying, not redesign."

jq -n --arg ctx "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
exit 0
