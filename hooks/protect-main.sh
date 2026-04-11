#!/bin/bash
# HARD BLOCK: Prevents AI from pushing to main/master branches.
# Exit code 2 = block the tool call entirely in Claude Code hooks.
# The user must push to main manually from their own terminal.
# Installed globally by claude-bootstrap.sh to ~/.claude/hooks/

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')

# Extract only the actual command portions (before any heredoc/string content).
# Split on && / || / ; and check each segment for "git push".
# This avoids false positives from "git push" appearing inside commit messages.
PUSH_CMD=""
while IFS= read -r segment; do
  # Trim leading whitespace
  segment="${segment#"${segment%%[![:space:]]*}"}"
  if echo "$segment" | grep -qE '^(git push|cd .* git push|env .* git push)'; then
    PUSH_CMD="$segment"
    break
  fi
  # Also catch "git push" after env vars like VAR=val git push
  if echo "$segment" | grep -qE 'git push'; then
    # Only match if "git push" isn't inside quotes
    stripped=$(echo "$segment" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")
    if echo "$stripped" | grep -qE 'git push'; then
      PUSH_CMD="$segment"
      break
    fi
  fi
done <<< "$(echo "$COMMAND" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g')"

# Skip if no actual push command found
if [ -z "$PUSH_CMD" ]; then
  exit 0
fi

# Block 1: Explicit main/master in the push command
if echo "$PUSH_CMD" | grep -qE 'git push.*([[:space:]]|:)(main|master)([[:space:]]|$)'; then
  echo "BLOCKED: Pushing to main/master is not allowed from Claude Code." >&2
  echo "Push to main must be done manually by the user." >&2
  exit 2
fi

# Block 2: Force pushes (always dangerous)
if echo "$PUSH_CMD" | grep -qE '(^|\s)(-f|--force|--force-with-lease)(\s|$)'; then
  echo "BLOCKED: Force pushing is not allowed from Claude Code." >&2
  exit 2
fi

# Block 3: Any push while on main/master branch (catches implicit pushes
# like "git push origin", "git push origin HEAD", bare "git push")
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
  echo "BLOCKED: Cannot push while on '$CURRENT_BRANCH' branch from Claude Code." >&2
  echo "Switch to a feature branch or push manually from your terminal." >&2
  exit 2
fi

exit 0
