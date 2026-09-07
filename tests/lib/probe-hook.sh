#!/usr/bin/env bash
# tests/lib/probe-hook.sh
#
# E1 measurement probe (epic-22 wave-01 slice 10). Emits a distinguishable,
# mode-keyed marker through one of five hook emission channels, so a scratch
# `claude -p` run can measure what a terminal capture shows the user and what
# a --output-format stream-json transcript shows the model, per channel.
#
# Keyed by env var MODE (1-5):
#
#   MODE=1  exit 2 + stderr text                                    (any hook event; the
#           mechanism 16 of 16 event hooks in this repo use today)
#   MODE=2  PreToolUse JSON hookSpecificOutput.permissionDecision="deny" +
#           permissionDecisionReason, exit 0                        (farm-out-reminder.sh's
#           emit_deny; the only current user)
#   MODE=3  top-level JSON systemMessage, exit 0                    (used nowhere in this
#           repo today; measured for completeness)
#   MODE=4  JSON {decision:"block", reason:...} on stdout, exit 0   (patrol-duties-gate.sh /
#           patrol-revive.sh's Stop-hook channel; also probed on PreToolUse to see if it
#           applies there too)
#   MODE=5  PreToolUse JSON hookSpecificOutput.additionalContext, exit 0
#           (farm-out-reminder.sh's emit_nudge; advisory, not a refusal)
#
# Optional env var PROBE_EVENT restricts activation to one hook_event_name
# (e.g. "PreToolUse" or "Stop"); when set, a call for any other event is a
# silent no-op (exit 0, no output) so the same settings.json can register
# this script on multiple events without cross-firing. A Stop-hook probe also
# checks stdin's stop_hook_active flag and stands down once Claude has
# already been forced to re-run the Stop hook once, to avoid an infinite loop.
#
# Every marker embeds two distinguishable tags so a terminal/pty capture and
# a model transcript capture can be told apart by grep alone, even when both
# are read from the same combined log:
#   PROBE_USER_MODE<n>_<nonce>   -- looked for in the terminal/pty capture
#   PROBE_MODEL_MODE<n>_<nonce>  -- looked for in the stream-json transcript

set -euo pipefail

MODE="${MODE:-1}"
NONCE="${PROBE_NONCE:-$$}"

INPUT="$(cat)"
EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "unknown"' 2>/dev/null || echo unknown)"
STOP_HOOK_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"

if [[ -n "${PROBE_EVENT:-}" && "$EVENT" != "$PROBE_EVENT" ]]; then
  # Not the event this run is measuring — allow silently, do not interfere.
  exit 0
fi

if [[ "$EVENT" == "Stop" && "$STOP_HOOK_ACTIVE" == "true" ]]; then
  # Claude already re-ran the Stop hook once because we blocked it; stand
  # down instead of blocking forever.
  exit 0
fi

USER_TAG="PROBE_USER_MODE${MODE}_${NONCE}"
MODEL_TAG="PROBE_MODEL_MODE${MODE}_${NONCE}"
MARKER="${USER_TAG} :: ${MODEL_TAG} :: event=${EVENT}"

case "$MODE" in
  1)
    # exit 2 + stderr — the loader-wall / most-hooks mechanism.
    printf '%s\n' "$MARKER" >&2
    exit 2
    ;;
  2)
    # PreToolUse permissionDecision:deny + reason, exit 0.
    jq -nc --arg r "$MARKER" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
    ;;
  3)
    # top-level systemMessage, exit 0.
    jq -nc --arg m "$MARKER" '{systemMessage:$m}'
    exit 0
    ;;
  4)
    # decision:block + reason on stdout, exit 0 — the Stop-hook channel;
    # also probed on PreToolUse to see whether it applies there too.
    jq -nc --arg r "$MARKER" '{decision:"block",reason:$r}'
    exit 0
    ;;
  5)
    # PreToolUse additionalContext (advisory, farm-out-reminder's channel), exit 0.
    jq -nc --arg c "$MARKER" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
    exit 0
    ;;
  *)
    echo "probe-hook.sh: unknown MODE=$MODE" >&2
    exit 1
    ;;
esac
