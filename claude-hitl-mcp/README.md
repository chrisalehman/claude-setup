# claude-hitl-mcp

Human-in-the-loop MCP server for Claude Code. Walk away from the terminal -- respond from your phone via Telegram.

## Setup

### First time (once, interactive)

1. Message [@BotFather](https://t.me/BotFather) in Telegram, send `/newbot`, copy the token
2. Run:
   ```bash
   export TELEGRAM_BOT_TOKEN="your-token-here"
   cd claude-hitl-mcp && npm install && npm run build && npm link
   claude-hitl-mcp setup
   ```
3. Send `/start` to your bot when prompted
4. Verify: `claude-hitl-mcp doctor`

Once set up, HITL is registered globally. Every Claude Code session on this machine gets it automatically -- no per-project config needed.

### Adoption (new machine or user)

```bash
git clone <this-repo>
cd claude-hitl-mcp
npm install && npm run build && npm link
export TELEGRAM_BOT_TOKEN="your-token-here"
claude-hitl-mcp setup
claude-hitl-mcp doctor     # verify everything
```

## How It Works

```
                      Telegram
                         |
                 [Listener Daemon]     <- owns the bot, runs 24/7
                  ~/.claude-hitl/sock
                   /            \
          [MCP Server]    [MCP Server]  <- one per Claude Code session
          (project A)     (project B)
```

A single listener daemon maintains the Telegram connection. MCP servers (one per Claude Code session) connect to it over a Unix socket. This prevents Telegram `409 Conflict` errors from multiple bot connections.

## MCP Tools

| Tool | Behavior | Use case |
|------|----------|----------|
| `ask_human` | Blocks until response | Decisions needing human input |
| `notify_human` | Fire and forget | Status updates, progress |
| `configure_hitl` | Session config | Set project context, timeout overrides |

## Priority System

| Priority | On timeout | Default | Example |
|----------|-----------|---------|---------|
| `critical` | Block forever + reminders | Never | Destructive ops, security |
| `architecture` | Return "paused" | 2 hours | System design, data models |
| `preference` | Auto-pick default option | 30 min | Naming, style choices |
| `fyi` | Never blocks | n/a | Progress updates |

## CLI

```
claude-hitl-mcp setup               First-time setup
claude-hitl-mcp doctor              Check prerequisites (--fix to auto-repair)
claude-hitl-mcp test                End-to-end test (all tools + priorities)
claude-hitl-mcp status              Show config and connection
claude-hitl-mcp install-listener    Install listener daemon
claude-hitl-mcp uninstall-listener  Remove listener daemon
claude-hitl-mcp start-listener      Start listener
claude-hitl-mcp stop-listener       Stop listener
claude-hitl-mcp listener-logs       Tail logs
```

## Telegram Commands

| Command | Action |
|---------|--------|
| `/status` | Active sessions and pending requests |
| `/quiet` | Toggle quiet hours |
| `/help` | Available commands |

## Troubleshooting

Run `claude-hitl-mcp doctor` first -- it checks everything and tells you exactly what's wrong.

**MCP tools missing** -- `claude-hitl-mcp doctor --fix` will re-register the MCP server.

**409 Conflict** -- Multiple bot connections. Fix: `claude-hitl-mcp stop-listener && claude-hitl-mcp start-listener`

**No notifications** -- Check: `claude-hitl-mcp status`, then `claude-hitl-mcp listener-logs`

**Listener won't start after brew upgrade** -- `claude-hitl-mcp doctor --fix` rewrites the plist with a stable node path.

## Development

```bash
npm install && npm run build    # Build
npm test                        # Run tests
npm run dev                     # Watch mode
```
