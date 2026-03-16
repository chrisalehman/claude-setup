#!/bin/bash
# Permission-request hook: report blocked state to HITL listener
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
sid=$(echo "$input" | jq -r '.session_id // empty') || exit 0
tool=$(echo "$input" | jq -r '.tool_name // empty') || exit 0
[ -z "$sid" ] || [ -z "$tool" ] && exit 0
# Extract tool input summary (e.g. bash command), truncate to 200 chars
tool_input=$(echo "$input" | jq -r '(.tool_input.command // .tool_input.file_path // "") | .[0:200]') 2>/dev/null
jq -nc --arg sid "$sid" --arg tool "$tool" --arg ti "${tool_input:-}" \
  'if $ti == "" then {type:"blocked", sessionId:$sid, toolName:$tool}
   else {type:"blocked", sessionId:$sid, toolName:$tool, toolInput:$ti} end' \
  | nc -U ~/.claude-hitl/sock 2>/dev/null
exit 0
