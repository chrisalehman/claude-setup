# claude-hitl-mcp

Human-in-the-Loop MCP server for Claude Code. Walk away from the terminal — respond from your phone via Telegram.

When Claude is running autonomously and hits a decision point, it sends a notification to your phone and waits for your response. A priority system controls timeouts: critical decisions block indefinitely, architecture decisions pause after 2 hours, and preference decisions auto-resolve after 30 minutes.

## Quick Start

### Prerequisites

- Node.js >= 20
- A Telegram account
- Claude Code installed

### First-Time Setup (under 2 minutes)

This is the only interactive step. Everything after this is handled by `claude-bootstrap.sh`.

**1. Create a Telegram bot**

Open Telegram, message [@BotFather](https://t.me/BotFather), send `/newbot`, follow the prompts, and copy the token.

**2. Set the token and run setup**

```bash
export TELEGRAM_BOT_TOKEN="your-token-here"
cd claude-hitl-mcp
npm install && npm run build
node dist/cli.js setup
```

Setup will:
- Persist the token to `~/.zshrc`
- Connect to Telegram and wait for you to send `/start` to your bot
- Save config to `~/.claude-hitl/config.json`
- Register the MCP server globally in `~/.claude/settings.json`
- Install the listener daemon (macOS launchd)
- Send a test notification

**3. Verify**

```bash
node dist/cli.js test    # Should send a Telegram notification
node dist/cli.js status  # Shows config and connection status
```

### After First-Time Setup

Once `~/.claude-hitl/config.json` exists (from the setup above), `claude-bootstrap.sh` handles everything deterministically on subsequent runs:

- **Builds** the package (`npm install && npm run build`)
- **Registers** the MCP server via `claude mcp add` (with `TELEGRAM_BOT_TOKEN` from env)
- **Installs hooks** for activity tracking (`PostToolUse`, `PermissionRequest`) in `~/.claude/settings.json`
- **Starts** the listener daemon via launchd

After a reset or on a new machine (with `~/.claude-hitl/config.json` and `TELEGRAM_BOT_TOKEN` in place):

```bash
./claude-bootstrap.sh   # Fully restores HITL — no manual steps needed
```

### Adding to Another Project

Nothing to do. The MCP server is registered globally (`-s user` scope). Every Claude Code session on your machine automatically has access to the HITL tools.

If you need to register manually:

```bash
claude mcp add claude-hitl \
  -e "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" \
  -s user \
  -- node /path/to/claude-hitl-mcp/dist/server.js
```

## Architecture

Three entry points, each with a distinct role:

```
                          Telegram
                             |
                     [Listener Daemon]     <-- owns the bot, runs 24/7
                      ~/.claude-hitl/sock
                       /            \
              [MCP Server]    [MCP Server]  <-- one per Claude Code session
              (project A)     (project B)
```

| Entry Point | File | Purpose |
|-------------|------|---------|
| **CLI** | `dist/cli.js` | Setup, management, status commands |
| **MCP Server** | `dist/server.js` | Claude Code's interface (stdio), exposes 3 tools |
| **Listener** | `dist/listener.js` | Background daemon, owns the Telegram bot, routes messages via IPC |

**Why three?** The listener daemon maintains a single Telegram connection shared across all Claude Code sessions. Without it, each session would create its own bot connection, causing `409 Conflict` errors. The MCP server is a thin client that talks to the listener over a Unix socket (`~/.claude-hitl/sock`).

## MCP Tools

### `ask_human` — Blocking

Sends a question and waits for the human to respond. Supports inline buttons for structured choices.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `message` | string | yes | The question to ask |
| `priority` | `critical` \| `architecture` \| `preference` | yes | Controls timeout behavior |
| `options` | string[] | no | Button choices (e.g., `["Approve", "Reject", "Modify"]`) |
| `context` | string | no | Additional context shown below the question |
| `timeout_minutes` | number | no | Override default timeout |

### `notify_human` — Non-blocking

Sends a one-way notification. Fire and forget.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `message` | string | yes | The notification text |
| `level` | `info` \| `success` \| `warning` \| `error` | no | Controls emoji prefix |
| `silent` | boolean | no | Suppress push notification sound |

### `configure_hitl` — Session setup

Sets project context and timeout overrides for the current session.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `session_context` | string | no | e.g., "modamily-ai-poc: auth refactor" |
| `timeout_overrides` | object | no | Per-priority timeout overrides in minutes |

## Priority System

| Priority | On Timeout | Default Timeout | Use Case |
|----------|-----------|-----------------|----------|
| `critical` | Block indefinitely + reminder pings | Never | Destructive ops, security changes |
| `architecture` | Return "paused" — Claude moves on | 2 hours | System design, data model changes |
| `preference` | Auto-pick the marked default option | 30 min | Naming, style, implementation details |
| `fyi` | Never blocks (`notify_human`) | n/a | Progress updates, completions |

## CLI Commands

```
claude-hitl-mcp                     Start MCP server (stdio mode)
claude-hitl-mcp setup               Interactive first-time setup
claude-hitl-mcp test                Send a test notification
claude-hitl-mcp status              Show config and connection status
claude-hitl-mcp install-listener    Install and start the listener daemon
claude-hitl-mcp uninstall-listener  Stop and remove the listener daemon
claude-hitl-mcp start-listener      Start the listener daemon
claude-hitl-mcp stop-listener       Stop the listener daemon
claude-hitl-mcp listener-logs       Tail the listener log file
```

## Telegram Bot Commands

Once connected, these commands are available in your Telegram chat:

| Command | Action |
|---------|--------|
| `/status` | Show active sessions, pending requests |
| `/quiet` | Toggle quiet hours (suppresses preference-level asks) |
| `/help` | Show available commands |

## File Locations

| Path | Purpose |
|------|---------|
| `~/.claude-hitl/config.json` | Bot token (as `env:` ref), chat ID, timeout defaults |
| `~/.claude-hitl/listener.log` | Listener daemon logs |
| `~/.claude-hitl/listener.pid` | Listener daemon PID |
| `~/.claude-hitl/sock` | Unix socket for IPC between MCP servers and listener |
| `~/.claude/settings.json` | Global MCP server registration |
| `~/Library/LaunchAgents/com.claude-hitl.listener.plist` | macOS launchd config |

## Troubleshooting

### "409 Conflict: terminated by other getUpdates request"

Multiple processes are polling the same Telegram bot. This happens when:
- The listener daemon is running AND an MCP server connects directly (without going through the listener)
- Multiple listener instances are running

Fix: restart the listener to take ownership:

```bash
node dist/cli.js stop-listener && node dist/cli.js start-listener
```

### Listener won't start / launchctl errors

```bash
# Check if already loaded
launchctl print gui/$(id -u)/com.claude-hitl.listener

# Reload (unload + load)
launchctl bootout gui/$(id -u)/com.claude-hitl.listener
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-hitl.listener.plist

# Or reinstall entirely
node dist/cli.js uninstall-listener
node dist/cli.js install-listener
```

### No notification received

1. Check the listener is running: `node dist/cli.js status`
2. Check logs: `node dist/cli.js listener-logs`
3. Send a test: `node dist/cli.js test`
4. Verify Telegram bot token is valid: message your bot directly in Telegram

### MCP tools not showing in Claude Code

The server must be registered globally. Check:

```bash
claude mcp list
```

If `claude-hitl` is missing, re-run `node dist/cli.js setup` or register manually:

```bash
claude mcp add claude-hitl \
  -e "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" \
  -s user \
  -- node /path/to/claude-hitl-mcp/dist/server.js
```

Then restart your Claude Code session — MCP servers are loaded at session start.

## Development

```bash
npm install
npm run build       # Compile TypeScript
npm run dev         # Watch mode
npm test            # Run tests (vitest)
npm run test:watch  # Watch mode tests
```

## Adapter Interface

The Telegram adapter is the default, but the architecture is pluggable. To add a new platform (Slack, Discord, etc.), implement the `ChatAdapter` interface in `src/adapters/`. See `src/adapters/telegram.ts` for the reference implementation.
