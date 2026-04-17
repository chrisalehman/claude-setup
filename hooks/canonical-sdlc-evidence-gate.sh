#!/bin/bash
# EVIDENCE GATE: Blocks git commits during a canonical-sdlc run when the
# plan file's ## SDLC State section is missing the current phase's evidence.
#
# Convention: the plan file under ~/.claude/plans/ contains a section like:
#
#   ## SDLC State
#   mode: overnight
#   current: 5
#   Phase 1: /path/or/link
#   Phase 2: /path/to/spec.md
#   Phase 3: ~/.claude/plans/<name>.md
#   Phase 4: git worktree at /path
#   Phase 5: tests passing, commit abc123
#
# If the current phase's line is empty or a placeholder (TODO, pending,
# in progress, XXX, TBD, placeholder), block the commit. The rule is:
# the evidence artifact must be recorded in the plan file *before* the
# commit that closes the phase.
#
# Plans without ## SDLC State pass through unblocked — this hook only
# enforces against canonical-sdlc runs.
#
# Exit code 2 = block the tool call entirely in Claude Code hooks.
#
# Installed globally by claude-bootstrap.sh to ~/.claude/hooks/

set -u

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Not a Bash tool call or empty command — nothing to gate.
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Is any segment of the command a `git commit`? Parse segments split on
# &&, ||, ; like protect-main.sh. Ignore content inside quotes (commit
# messages often contain "git commit" as prose).
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

# Locate the newest plan file across the supported plan-directory
# conventions:
#   - ~/.claude/plans/            (Claude Code global convention)
#   - <project>/docs/bionic/plans/ (bionic canonical-sdlc convention)
#   - <project>/docs/superpowers/plans/ (superpowers convention)
#
# Picks the newest .md across all that exist. If none exist, this isn't a
# canonical-sdlc session — let the commit through.
#
# Project resolution mirrors memory-update.sh: CLAUDE_PROJECT_DIR first,
# then the hook input's cwd field, then pwd. Consistent with existing hooks.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
fi
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR=$(pwd)
fi

PLAN_DIRS=( "${HOME}/.claude/plans" )
if [ -n "$PROJECT_DIR" ]; then
  PLAN_DIRS+=(
    "${PROJECT_DIR}/docs/bionic/plans"
    "${PROJECT_DIR}/docs/superpowers/plans"
  )
fi

PLAN=""
for d in "${PLAN_DIRS[@]}"; do
  [ -d "$d" ] || continue
  while IFS= read -r -d '' f; do
    if [ -z "$PLAN" ] || [ "$f" -nt "$PLAN" ]; then
      PLAN="$f"
    fi
  done < <(find "$d" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)
done

if [ -z "$PLAN" ] || [ ! -f "$PLAN" ]; then
  exit 0
fi

# The newest plan has no ## SDLC State section → not a canonical-sdlc run.
if ! grep -q '^## SDLC State' "$PLAN"; then
  exit 0
fi

# Extract the ## SDLC State section (from its header up to the next ##
# header or EOF).
SECTION=$(awk '/^## SDLC State/{flag=1; next} /^## /{flag=0} flag' "$PLAN")

if [ -z "$SECTION" ]; then
  echo "BLOCKED: canonical-sdlc plan file has an empty '## SDLC State' section." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: populate the section with 'current: N' and per-phase evidence lines." >&2
  exit 2
fi

# Parse current phase. Accepts integers (1-13) and the 8b adversarial
# critic phase.
CURRENT=$(echo "$SECTION" \
          | grep -E '^[[:space:]]*current[[:space:]]*:' \
          | head -1 \
          | sed -E 's/^[[:space:]]*current[[:space:]]*:[[:space:]]*//' \
          | tr -d '[:space:]')

if [ -z "$CURRENT" ] || ! echo "$CURRENT" | grep -qE '^[0-9]+[ab]?$'; then
  echo "BLOCKED: canonical-sdlc plan file's '## SDLC State' section is missing a valid 'current: N' line." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: add a line like 'current: 5' (or 'current: 8b') before committing." >&2
  exit 2
fi

# Find the evidence line for the current phase. Accepts:
#   Phase 5: ...
#   - Phase 5: ...
LINE=$(echo "$SECTION" \
       | grep -E "^[[:space:]]*-?[[:space:]]*Phase[[:space:]]+${CURRENT}[[:space:]]*:" \
       | head -1)

if [ -z "$LINE" ]; then
  echo "BLOCKED: canonical-sdlc plan file has no 'Phase ${CURRENT}:' line in '## SDLC State'." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: add the evidence artifact for phase ${CURRENT} before committing." >&2
  exit 2
fi

RAW_VALUE=$(echo "$LINE" | sed -E "s/^[[:space:]]*-?[[:space:]]*Phase[[:space:]]+${CURRENT}[[:space:]]*:[[:space:]]*//")
VALUE_STRIPPED=$(echo "$RAW_VALUE" | tr -d '[:space:]')

if [ -z "$VALUE_STRIPPED" ]; then
  echo "BLOCKED: canonical-sdlc phase ${CURRENT} evidence line is empty in '## SDLC State'." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: record the evidence artifact (commit SHA, path, link) for phase ${CURRENT} before committing." >&2
  exit 2
fi

# Placeholder detection. Compare lowercase, whitespace-stripped value
# against a set of known placeholder tokens.
NORM=$(echo "$VALUE_STRIPPED" | tr '[:upper:]' '[:lower:]')
case "$NORM" in
  *todo*|*pending*|*inprogress*|*xxx*|*tbd*|*placeholder*)
    echo "BLOCKED: canonical-sdlc phase ${CURRENT} evidence line is a placeholder (\"${RAW_VALUE}\")." >&2
    echo "Plan: $PLAN" >&2
    echo "Fix: replace with the actual evidence artifact before committing." >&2
    exit 2
    ;;
esac

exit 0
