#!/bin/bash
# Post-tool-use hook: report activity to HITL listener
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
sid=$(echo "$input" | jq -r '.session_id // empty') || exit 0
tool=$(echo "$input" | jq -r '.tool_name // empty') || exit 0
[ -z "$sid" ] || [ -z "$tool" ] && exit 0
jq -nc --arg sid "$sid" --arg tool "$tool" \
  '{type:"activity", sessionId:$sid, toolName:$tool}' \
  | nc -U ~/.claude-hitl/sock 2>/dev/null
exit 0
