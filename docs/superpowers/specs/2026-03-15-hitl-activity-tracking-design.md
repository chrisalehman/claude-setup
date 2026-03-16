# HITL Activity Tracking & Enhanced /status

**Date:** 2026-03-15
**Status:** Draft
**Scope:** claude-hitl-mcp

## Problem

The `/status` Telegram command shows whether sessions are connected and whether there are pending `ask_human` questions, but gives no indication of whether Claude is actively working, idle, or stuck waiting for terminal input. A session deep in autonomous work looks identical to one blocked on a permission prompt. The user has to go to the terminal to find out.

## Goals

1. Show real-time session activity state in `/status` (Active, Thinking, Blocked, Idle)
2. Proactively notify via Telegram when a session is blocked on a permission prompt
3. Ensure AI-asked questions always route through `ask_human` (CLAUDE.md instruction)

## Non-Goals

- Intercepting/replacing Claude Code's permission prompt UI
- Tracking subagent-level activity (future work)
- Rich tool execution history or dashboards

## Design

### 1. New IPC Message Types

Two new client message types added to `protocol.ts`:

```typescript
interface ActivityMessage {
  type: "activity";
  sessionId: string;
  toolName: string;
}

interface BlockedMessage {
  type: "blocked";
  sessionId: string;
  toolName: string;
  toolInput?: string;
}
```

Added to the `ClientMessage` union type.

**Important: Hook scripts open ephemeral socket connections** via `nc`, not the MCP server's long-lived socket. The IPC server's `handleLine()` currently looks up sessions by socket (`socketToSessionId`), which won't work for ephemeral connections. The fix: when a message with type `activity` or `blocked` arrives on an unregistered socket, look up the session by the `sessionId` field in the message body from the `sessions` map. If no matching session exists, silently drop the message. This is safe because the message can only affect an already-registered session's state — it cannot create sessions or send responses.

### 2. Session State Tracking

New fields on `SessionInfo` in `ipc/server.ts`:

```typescript
interface SessionInfo {
  // ... existing fields ...
  lastActivityAt?: Date;
  lastActivityTool?: string;
  blockedOn?: string;
  blockedAt?: Date;
}
```

**State transitions:**
- `activity` message received: update `lastActivityAt` and `lastActivityTool`, clear `blockedOn` and `blockedAt`
- `blocked` message received: set `blockedOn` (tool name) and `blockedAt`, also update `lastActivityAt`
- `blockedOn` auto-clear: if `blockedAt` is older than 60 seconds and no new `blocked` message has arrived, treat as cleared when computing state for `/status`. This handles the case where the user approves at the terminal but Claude doesn't immediately make another tool call.
- Session disconnect: state is discarded with the session

The IPC server handles `activity` and `blocked` messages in `handleLine()`. Since these arrive on ephemeral sockets (not the MCP server's registered socket), the existing `socketToSessionId` lookup returns `undefined`. An `else` branch handles this:

```typescript
// In handleLine(), after the existing sessionId-based forwarding:
if (sessionId) {
  const session = this.sessions.get(sessionId);
  if (session && this.messageHandler) {
    this.messageHandler(session, msg as ClientMessage);
  }
} else if (msg.type === "activity" || msg.type === "blocked") {
  const session = this.sessions.get((msg as { sessionId: string }).sessionId);
  if (session) {
    this.handleActivityMessage(session, msg as ClientMessage);
  }
  // Close ephemeral socket after processing
  socket.destroy();
}
```

If the `sessionId` doesn't match a registered session, the message is silently dropped.

### 3. Proactive Blocked Notification

When the listener receives a `blocked` message (forwarded from IPC server via `onMessage` handler), it sends a Telegram notification immediately:

```
[modamily-ai-poc] Waiting for permission
Tool: Bash

Go to terminal to approve or deny.
```

- No debounce — immediate send on every `blocked` message
- Respects existing quiet hours suppression
- `toolInput` included if present, truncated to 200 characters

### 4. Enhanced /status Display

**Session state indicator** derived from session fields at query time:

| State | Condition | Display |
|-------|-----------|---------|
| Active | `lastActivityAt` within 30s | `Active (12s ago)` |
| Thinking | `lastActivityAt` 30s-120s ago | `Thinking (45s ago)` |
| Blocked | `blockedOn` is set | `Waiting for permission (Bash)` |
| Idle | `lastActivityAt` > 120s ago | `Idle (5m ago)` |
| No data | `lastActivityAt` not set | `No activity data` |

**`StatusSession` interface** gains new fields:

```typescript
interface StatusSession {
  // ... existing fields ...
  lastActivityAge?: number;    // seconds since last activity
  lastActivityTool?: string;
  blockedOn?: string;
}
```

**Single session format:**

```
Claude Status

modamily-ai-poc (worktree: feature/auth)
Context: auth middleware refactor

Waiting for permission (Bash)

Plan:
## Phase 1 ...

1 pending question (12m ago)
```

**Multi-session compact format:**

```
Active Sessions

#1 modamily-ai-poc
   Active (5s ago)
   1 pending question (12m ago)

#2 claude-setup
   Idle (3m ago)
   No pending questions
```

The state indicator replaces the plan first-line in compact view. Plan details remain in drill-down.

### 5. Hook Scripts

Two shell scripts shipped with the package:

**`bin/hook-activity.sh`:**
```bash
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
```

**`bin/hook-blocked.sh`:**
```bash
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
```

Both scripts:
- Require `jq` and `nc` (standard on macOS)
- Exit 0 unconditionally — hooks must never block Claude
- Silently fail if listener socket is unavailable

### 6. Hook Installation

`claude-hitl-mcp setup` is extended to add hooks to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [{
      "type": "command",
      "command": "/absolute/path/to/bin/hook-activity.sh"
    }],
    "PermissionRequest": [{
      "type": "command",
      "command": "/absolute/path/to/bin/hook-blocked.sh"
    }]
  }
}
```

The path is resolved from the package's install location at setup time.

**Merge strategy:** Setup must read-merge-write the hooks config. If the user already has `PostToolUse` or `PermissionRequest` hooks from other tools, append to the existing arrays rather than overwriting. Check for duplicate entries (same command path) to make setup idempotent.

### 7. CLI Signal Command

For testing and debugging:

```bash
claude-hitl-mcp signal activity --session-id <id> --tool Bash
claude-hitl-mcp signal blocked --session-id <id> --tool Bash --input "npm run build"
```

Opens a one-shot connection to `~/.claude-hitl/sock`, sends the JSON message, and disconnects immediately. Uses a lightweight inline socket connection (not the full `IpcClient` which requires registration). `--session-id` and `--tool` are required. `--input` is optional (blocked only). Prints "sent" on success, "failed: <reason>" on error. Exits 0 on success, 1 on failure.

### 8. CLAUDE.md Rule (manual addition, not automated)

Add to global `~/.claude/CLAUDE.md`:

```markdown
## Always Use ask_human for Questions
When asking the user a question, always use `mcp__claude-hitl__ask_human` with appropriate priority and options. Never print a question to the terminal and wait for stdin input.
```

This is a behavioral instruction, not a code change. It is not installed by setup.

### 9. Hook Input Schema

Claude Code hooks receive JSON on stdin. The relevant fields per the Claude Code hooks documentation:

- **All hooks:** `session_id` (string), `hook_event_name` (string), `cwd` (string)
- **PostToolUse:** `tool_name` (string), `tool_input` (object), `tool_response` (object)
- **PermissionRequest:** `tool_name` (string), `tool_input` (object)

The hook scripts use `session_id` and `tool_name` from this payload. The `tool_input` object varies by tool — for Bash it has `.command`, for Edit/Write it has `.file_path`. The blocked hook extracts `.command` or `.file_path` as a summary.

### 10. Backwards Compatibility

Adding new message types to `ClientMessage` is backwards-compatible. If hook scripts send `activity`/`blocked` messages to an older listener that hasn't been updated, the messages arrive on unregistered sockets and are silently ignored (existing behavior for unknown messages). No protocol version bump needed — rolling upgrades are safe.

## Files Changed

| File | Change |
|------|--------|
| `src/ipc/protocol.ts` | Add `ActivityMessage`, `BlockedMessage` to `ClientMessage` union |
| `src/ipc/server.ts` | Add activity/blocked fields to `SessionInfo`; handle new message types |
| `src/listener.ts` | Send proactive Telegram notification on `blocked`; pass new fields to status |
| `src/commands/status.ts` | Add state indicator to `StatusSession`, update formatters |
| `src/cli.ts` | Add `signal` subcommand; extend `setup` to install hooks |
| `bin/hook-activity.sh` | New file — PostToolUse hook script |
| `bin/hook-blocked.sh` | New file — PermissionRequest hook script |
| `tests/commands/status.test.ts` | Tests for new state indicator display |
| `tests/ipc/server.test.ts` | Tests for activity/blocked message handling |
| `tests/listener.test.ts` | Tests for proactive blocked notification |
| `~/.claude/CLAUDE.md` | Add ask_human usage rule |

## Testing Strategy

- **Unit tests:** status formatting with all state combinations, IPC message routing, session state transitions
- **Integration tests:** hook script sends message, listener receives it, /status reflects updated state
- **Manual test:** trigger a permission prompt in Claude Code, verify Telegram notification arrives and /status shows "Waiting for permission"
