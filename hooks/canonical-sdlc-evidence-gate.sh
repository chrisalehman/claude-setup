#!/bin/bash
# EVIDENCE GATE: Blocks git commits during a canonical-sdlc run when the
# plan file's ## SDLC State section is missing the current step's evidence.
#
# Convention: the plan file contains a section like:
#
#   ## SDLC State
#   mode: overnight
#   integration-branch: main
#   current: 5
#   Step 1: /path/or/link
#   Step 2: /path/to/spec.md
#   Step 3: docs/bionic/plans/epic-NN-<slug>/wave-NN-<slug>.plan.md
#   Step 4: git worktree at /path, base SHA abc123
#   Step 5: tests passing, commit abc123
#
# The hook also accepts `Phase N:` lines for backward compatibility with
# in-flight plans written under the prior "phase" vocabulary. Both forms
# are parsed; new plans should use `Step N:`.
#
# If the current step's line is empty or a placeholder (TODO, pending,
# in progress, XXX, TBD, placeholder), block the commit. The rule is:
# the evidence artifact must be recorded in the plan file *before* the
# commit that closes the step.
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
  # Descend up to 2 levels deep to support the bionic directory-per-epic
  # layout: docs/bionic/plans/epic-NN-<slug>/wave-NN-<slug>.plan.md.
  # Flat conventions (~/.claude/plans/<name>.md) are still covered at
  # depth 1.
  while IFS= read -r -d '' f; do
    if [ -z "$PLAN" ] || [ "$f" -nt "$PLAN" ]; then
      PLAN="$f"
    fi
  done < <(find "$d" -maxdepth 2 -type f -name '*.md' -print0 2>/dev/null)
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
  echo "Fix: populate the section with 'current: N' and per-step evidence lines." >&2
  exit 2
fi

# Parse current step. Accepts integers (1-13) and the 8b adversarial
# critic step.
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

# Find the evidence line for the current step. Accepts both "Step N:"
# (current vocabulary) and "Phase N:" (legacy plans), with or without a
# leading list marker. New plans should use "Step"; "Phase" is retained
# for backward compatibility.
LINE=$(echo "$SECTION" \
       | grep -E "^[[:space:]]*-?[[:space:]]*(Step|Phase)[[:space:]]+${CURRENT}[[:space:]]*:" \
       | head -1)

if [ -z "$LINE" ]; then
  echo "BLOCKED: canonical-sdlc plan file has no 'Step ${CURRENT}:' line in '## SDLC State'." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: add the evidence artifact for step ${CURRENT} before committing." >&2
  exit 2
fi

RAW_VALUE=$(echo "$LINE" | sed -E "s/^[[:space:]]*-?[[:space:]]*(Step|Phase)[[:space:]]+${CURRENT}[[:space:]]*:[[:space:]]*//")
VALUE_STRIPPED=$(echo "$RAW_VALUE" | tr -d '[:space:]')

if [ -z "$VALUE_STRIPPED" ]; then
  echo "BLOCKED: canonical-sdlc step ${CURRENT} evidence line is empty in '## SDLC State'." >&2
  echo "Plan: $PLAN" >&2
  echo "Fix: record the evidence artifact (commit SHA, path, link) for step ${CURRENT} before committing." >&2
  exit 2
fi

# Placeholder detection. Compare lowercase, whitespace-stripped value
# against a set of known placeholder tokens.
NORM=$(echo "$VALUE_STRIPPED" | tr '[:upper:]' '[:lower:]')
case "$NORM" in
  *todo*|*pending*|*inprogress*|*xxx*|*tbd*|*placeholder*)
    echo "BLOCKED: canonical-sdlc step ${CURRENT} evidence line is a placeholder (\"${RAW_VALUE}\")." >&2
    echo "Plan: $PLAN" >&2
    echo "Fix: replace with the actual evidence artifact before committing." >&2
    exit 2
    ;;
esac

exit 0
