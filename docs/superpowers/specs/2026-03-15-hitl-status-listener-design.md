# HITL Status Listener Design

**Date:** 2026-03-15
**Status:** Approved
**Extends:** [claude-hitl-design.md](2026-03-15-claude-hitl-design.md)

## Problem

When away from the laptop, there's no way to:
1. Check what Claude Code is working on
2. Know if Claude is running or idle/crashed
3. Manage quiet hours without editing config files

The current architecture ties the Telegram bot to the MCP server's lifecycle — when Claude Code isn't running, the bot is dead. Status queries fail exactly when they're most needed.

## Solution

Introduce a **persistent listener daemon** that owns the Telegram bot connection. The MCP server becomes a client of the listener, communicating over a Unix socket. The listener handles bot commands (`/status`, `/quiet`, `/help`) independently of Claude Code sessions.

## Architecture

### Components

```
┌─────────────────────────────────────────────────────┐
│  claude-hitl-mcp package                            │
│                                                     │
│  ┌──────────────┐         ┌──────────────────────┐  │
│  │  MCP Server   │──Unix───│    Listener Daemon   │  │
│  │  (per Claude  │ Socket  │  (launchd, always-on)│  │
│  │   session)    │         │                      │  │
│  │              │         │  Owns Telegram bot   │  │
│  │  Tools:      │         │  Handles:            │  │
│  │  ask_human   │         │   /status            │  │
│  │  notify_human│         │   /quiet             │  │
│  │  configure   │         │   /help              │  │
│  └──────────────┘         │                      │  │
│                           │  Routes responses    │  │
│  ┌──────────────┐         │  to MCP servers      │  │
│  │  MCP Server   │──Unix───│                      │  │
│  │  (2nd session)│ Socket  └──────────────────────┘  │
│  └──────────────┘                                   │
└─────────────────────────────────────────────────────┘
```

- **Listener daemon** — always-on process, sole owner of the Telegram bot. Registered as macOS `launchd` user agent. Handles bot commands, routes interactive responses to the correct MCP server session.
- **MCP server** — short-lived per Claude Code session. Connects to the listener over Unix socket (`~/.claude-hitl/sock`). Sends messages through the listener, receives responses back.
- **CLI** — adds `install-listener`, `uninstall-listener`, `start-listener`, `stop-listener`, `listener-logs` commands. `setup` updated to install the daemon.

### Why Unix Socket

- No port conflicts (vs localhost HTTP)
- No firewall issues
- Natural cleanup when listener exits
- File-permission based security

## IPC Protocol

JSON-line protocol over Unix socket (one JSON object per `\n`-delimited line). Protocol version `1` — included in the `register` handshake for forward compatibility.

### MCP Server → Listener

```jsonl
{"type":"register","protocolVersion":1,"sessionId":"abc123","project":"claude-setup","cwd":"/Users/clehman/workspace/claude-setup","worktree":"feature/status-cmd"}

{"type":"configure","sessionId":"abc123","sessionContext":"Working on HITL status feature","timeoutOverrides":{"architecture":120,"preference":30}}

{"type":"ask","sessionId":"abc123","requestId":"req_1","message":"Which database?","priority":"architecture","options":["Postgres","SQLite"],"defaultIndex":0,"timeoutMinutes":120}

{"type":"notify","sessionId":"abc123","requestId":"notif_1","message":"Phase 2 complete","level":"info","silent":false}

{"type":"deregister","sessionId":"abc123"}
```

### Listener → MCP Server

```jsonl
{"type":"registered","sessionId":"abc123","protocolVersion":1}

{"type":"response","requestId":"req_1","text":"Postgres","selectedIndex":0,"isButtonTap":true}

{"type":"timeout","requestId":"req_1","defaultIndex":0}

{"type":"notified","requestId":"notif_1","messageId":42}

{"type":"quiet_hours_changed","quietHours":{"enabled":true,"manual":true}}

{"type":"error","requestId":"req_1","code":"unknown_session","message":"Session not found"}
```

### Error Message Types

The listener sends `error` messages for:
- `unknown_session` — `sessionId` not recognized (stale connection)
- `protocol_mismatch` — incompatible `protocolVersion` (sent in response to `register`, connection closed)
- `delivery_failed` — Telegram API error when sending message
- `invalid_message` — malformed IPC message

### Key Behaviors

- Each MCP server maintains a persistent socket connection for its lifetime
- `register` on connect includes `protocolVersion`; listener rejects incompatible versions with `error` + disconnect
- `deregister` on graceful shutdown; socket drop marks session as disconnected with "last seen" timestamp preserved
- Graceful `deregister` clears the session entirely (no "last seen" record)
- The listener routes Telegram responses back to the correct MCP server by matching `requestId` to `sessionId`
- `notify` messages receive a `notified` ack with the Telegram `messageId`, enabling the MCP server to return `{status: "sent", message_id}` from the `notify_human` tool
- All existing MCP tool behavior stays the same from Claude's perspective
- Maximum 10 concurrent MCP server connections; excess connections rejected with `error` code `max_connections`
- `worktree` field in `register` is optional/best-effort — the MCP server determines it via `git branch --show-current` if available, otherwise omits it

## Telegram Commands

### `/status`

Reads all active sessions from connected sockets. For each session: project name, worktree, session context, pending `ask_human` count. Reads `_plan.md` from each session's `cwd` for progress details.

**Single session** — shows full details immediately:

```
📊 Claude Status

claude-setup (worktree: feature/status-cmd)
Context: Working on HITL status feature

📋 Plan (Phase 3/5):
✅ Phase 1: Set up IPC protocol
✅ Phase 2: Implement listener
⏳ Phase 3: Telegram command handlers
◻ Phase 4: CLI commands
◻ Phase 5: Testing

⏳ 1 pending question (architecture, 12m ago)
```

**Multiple sessions** — compact summary with drill-down buttons:

```
📊 Active Sessions

#1 claude-setup (worktree: feature/status-cmd)
   Phase 3/5: Implementing Telegram listener
   ⏳ 1 pending question (12m ago)

#2 modamily (worktree: fix/auth-flow)
   No active plan
   ✅ No pending questions
```

Buttons: `[ claude-setup details ]` `[ modamily details ]`

Tapping a button shows the full detail view for that session.

**No sessions connected:**

```
📊 No active Claude sessions

Last activity: claude-setup disconnected 15m ago
```

### `/quiet`

Toggle-based with inline buttons. Shows current state and available actions:

When off:
```
🔔 Quiet hours: OFF

[ Turn On ]  [ Set Schedule ]
```

When on (manual):
```
🔇 Quiet hours: ON (turned on manually)

[ Turn Off ]  [ Set Schedule ]
```

When on (scheduled):
```
🔇 Quiet hours: ON (schedule: 22:00–08:00 ET)

[ Turn Off Now ]  [ Edit Schedule ]
```

`Set Schedule` / `Edit Schedule` prompts for start time, end time, timezone via sequential messages.

Quiet hours state persisted in `~/.claude-hitl/config.json` with a `manualOverride: boolean` field for distinguishing manual toggle from scheduled activation.

Quiet hours apply globally across all sessions (user preference, not per-session).

**Quiet hours ownership model:** The listener is the single authority for global quiet hours state. When `/quiet` is toggled from Telegram, the listener persists the change to config and pushes a `quiet_hours_changed` IPC message to all connected MCP servers. The MCP server's `PriorityEngine` updates its state accordingly. The `configure_hitl` tool's `quiet_hours` field is removed — quiet hours are managed exclusively through the listener (via Telegram `/quiet` or `config.json`). This eliminates ambiguity about which component is authoritative.

### `/help`

```
Available commands:

/status — What's Claude working on?
/quiet — Manage quiet hours
/help — Show this message
```

### Non-Command Messages

Free text and button taps that aren't command responses route to MCP server sessions as `ask_human` responses, same as current behavior.

If no sessions are connected: "No active Claude sessions. Your message wasn't delivered."

## File Layout

```
~/.claude-hitl/
├── config.json          # Migrated from ~/.claude-hitl.json
├── sock                 # Unix socket (listener creates/removes)
├── listener.pid         # PID file for stop-listener
└── listener.log         # Stdout/stderr from launchd
```

### Config Migration

On first run after upgrade, if `~/.claude-hitl.json` exists:
1. Create `~/.claude-hitl/` directory
2. Copy `~/.claude-hitl.json` → `~/.claude-hitl/config.json`
3. Verify the new file is valid JSON (read and parse it)
4. Delete old `~/.claude-hitl.json`

If the process crashes mid-migration, the next run detects both files exist and re-attempts from step 2. All config read/write paths (`loadConfig`, `saveConfig`, CLI commands) updated to use `~/.claude-hitl/config.json` as `DEFAULT_CONFIG_PATH`.

### No Session Files on Disk

Sessions tracked in-memory via live socket connections. If the listener restarts, MCP servers reconnect and re-register automatically. No persistence layer needed.

### `_plan.md` Reading

The listener reads `_plan.md` from the `cwd` reported in each session's `register` message. Read-only, never writes. If the file doesn't exist, status reports "No active plan."

**Path validation:** The `cwd` from `register` messages must be under the user's home directory (`$HOME`). Paths outside this boundary are rejected and the session's `cwd` is recorded as `null` (no `_plan.md` reading for that session).

**Truncation:** If `_plan.md` exceeds 3000 characters, the status message truncates it and appends "… (truncated, full plan in file)". This keeps the Telegram message under the 4096-character limit with room for the status header.

## Listener Daemon Lifecycle

### launchd Plist

Installed to `~/Library/LaunchAgents/com.claude-hitl.listener.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude-hitl.listener</string>
  <key>ProgramArguments</key>
  <array>
    <string>{{NODE_PATH}}</string>
    <string>dist/listener.js</string>
  </array>
  <key>WorkingDirectory</key>
  <string>{{PACKAGE_DIR}}</string>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>~/.claude-hitl/listener.log</string>
  <key>StandardErrorPath</key>
  <string>~/.claude-hitl/listener.log</string>
</dict>
</plist>
```

- **KeepAlive** — launchd restarts on crash
- **RunAtLoad** — starts on login
- Bot token read from `~/.claude-hitl/config.json` at startup (not in plist)
- `{{NODE_PATH}}` and `{{PACKAGE_DIR}}` resolved dynamically during `install-listener` via `which node` and `__dirname`

### CLI Commands

- `install-listener` — writes plist with resolved paths, runs `launchctl load`
- `uninstall-listener` — runs `launchctl unload`, removes plist
- `start-listener` / `stop-listener` — `launchctl start/stop` shortcuts
- `listener-logs` — tails `~/.claude-hitl/listener.log`

### MCP Server Reconnection

If the listener restarts (crash or manual stop/start):
1. Connected MCP servers get a socket error
2. They retry with exponential backoff: 1s, 2s, 4s, max 30s
3. During reconnection, `ask_human` falls back to terminal prompts (existing graceful degradation)
4. `notify_human` silently drops during reconnection (acceptable — fire-and-forget)
5. On reconnect, MCP server re-sends `register` and `configure` messages

### Graceful Shutdown

**Startup:**
1. If `~/.claude-hitl/sock` exists (stale from unclean exit), unlink it before binding
2. Create new Unix socket at `~/.claude-hitl/sock`
3. Write PID to `~/.claude-hitl/listener.pid`
4. Connect to Telegram bot using token from config
5. Begin accepting MCP server connections

**Graceful Shutdown** (`SIGTERM` from `launchctl stop`):
1. Listener sends `{"type":"shutdown"}` to all connected MCP servers
2. Closes all socket connections
3. Removes `~/.claude-hitl/sock`
4. Removes `~/.claude-hitl/listener.pid`
5. Exits

## Setup & Rollout

Updated `setup` command flow:

1. Migrate config to `~/.claude-hitl/config.json` (if needed)
2. Prompt for `TELEGRAM_BOT_TOKEN` (if not set)
3. Start Telegram bot, wait for `/start` binding
4. Save config with chat ID
5. Install and start listener daemon
6. Send test notification
7. Prompt user to test `/status` from Telegram

### Verification Checklist

After setup:

- [ ] `launchctl list | grep claude-hitl` shows the listener
- [ ] Send `/help` in Telegram — get command list
- [ ] Send `/status` — get "No active Claude sessions"
- [ ] Start a Claude Code session — MCP server connects
- [ ] Send `/status` again — see the session listed
- [ ] `ask_human` works through the listener (response routes back)
- [ ] `notify_human` delivers messages
- [ ] Kill the listener (`stop-listener`) — MCP server falls back to terminal
- [ ] Restart listener (`start-listener`) — MCP server reconnects
- [ ] Send `/quiet` — toggle works, persists across listener restart

## Testing Strategy

### Unit Tests
- IPC protocol serialization/deserialization
- Session registration and deregistration
- Response routing (button tap, reply-to, prefixed, LIFO)
- Quiet hours toggle and persistence
- Config migration logic
- `_plan.md` parsing

### Integration Tests
- MCP server ↔ listener socket lifecycle (connect, register, deregister, reconnect)
- Multi-session routing (two MCP servers, responses go to correct one)
- Telegram command handlers with mocked bot API
- Timeout handling through the listener
- Graceful degradation when listener unavailable

### Manual Verification
- Full setup flow on clean machine
- launchd restart recovery
- `/status` with 0, 1, 2 active sessions
- `/quiet` toggle round-trip
- `_plan.md` reading from worktree directories

## Migration & Backwards Compatibility

- A new `ListenerClientAdapter` class implements the `ChatAdapter` interface, communicating over IPC instead of direct Telegram API calls
- The existing `TelegramAdapter` is preserved for legacy/fallback mode
- An adapter factory selects the implementation: if the listener socket exists at `~/.claude-hitl/sock`, use `ListenerClientAdapter`; otherwise fall back to `TelegramAdapter` (direct Telegram connection)
- The `ChatAdapter` interface stays the same — `sendMessage()`, `sendInteractiveMessage()`, `onMessage()` — consumers are unaffected
- `configure` IPC messages are full replacements (not partial merges) — each `configure_hitl` call sends the complete session configuration
- Config at old path (`~/.claude-hitl.json`) auto-migrates on any CLI command

## Out of Scope

- Mobile app / web dashboard for status
- Persistent session history (sessions are ephemeral)
- Custom notification sounds via Telegram API
- Multi-user support (single user, single chat ID)
- Cross-machine status (listener runs on one machine only)
