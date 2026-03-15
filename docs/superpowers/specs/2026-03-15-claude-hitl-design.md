# claude-hitl: Human-in-the-Loop MCP Server

**Date:** 2026-03-15
**Status:** Approved design, pending implementation

## Overview

A pluggable MCP server that bridges Claude Code to chat platforms (Telegram first) for bidirectional human-in-the-loop interactions. When Claude Code is running autonomously and hits a decision point, it sends a notification to your phone and blocks until you respond — or auto-resolves based on a priority-tiered timeout system.

The goal: walk away from the terminal, stay informed, respond from your phone when it matters, and never lose time where Claude could be running.

## The Priority Model

This is the core design element. Instead of relying on Claude's judgment to decide when to block vs continue, a tiered priority system makes the behavior structural and rule-based.

### Priority Tiers

| Priority | When Claude Uses It | On Timeout | Default Timeout |
|----------|-------------------|------------|-----------------|
| **critical** | Irreversible, destructive, or security-sensitive actions | Block indefinitely + new reminder messages every 15 min (new messages trigger fresh push notifications on the phone, unlike edits which are silent) | Infinite |
| **architecture** | Design decisions that are expensive to reverse (system boundaries, data models, public interfaces, technology choices) | Return `timed_out` with `timed_out_action: "paused"` — Claude is advised (via behavioral rules) to move to other work, but this is guidance, not enforcement. The MCP tool cannot control Claude's task scheduling. | 2 hours |
| **preference** | Multiple valid paths, wants human taste (aesthetic choices, naming, implementation details) | Pick the marked default option, note what was chosen | 30 minutes |
| **fyi** | Status updates, completions, phase transitions | Never blocks (uses `notify_human`, not `ask_human`) | n/a |

### Classification Rules (installed to claude-global.md)

```markdown
## HITL Notification Priority Guide

When claude-hitl MCP tools are available, use them to keep the
human informed and to request input on decisions:

- **critical**: Irreversible actions — destructive migrations,
  external API calls with side effects, security changes.
  Always provide options including a "cancel" choice.

- **architecture**: Decisions affecting system boundaries, data
  models, public interfaces, or technology choices.
  Provide options with a recommended default.

- **preference**: Aesthetic choices, naming, implementation
  details with multiple valid paths.
  Always mark a default option.

- **fyi**: Progress updates, completions, phase transitions.
  Use notify_human, not ask_human.

When in doubt, prefer a higher priority tier.
False alarms are cheaper than silent mistakes.

Use configure_hitl at the start of each session to set
session_context so the human knows which project is messaging.
```

### Why This Works

- **Claude doesn't need "exquisite taste"** — the priority system IS the taste. The rules above define the classification rubric. Claude follows rules; the tool enforces consequences.
- **Safe defaults are explicit** — the `options` parameter includes a `default` flag. On timeout, `preference` picks the default. No guessing.
- **Nothing destructive happens** — `critical` never times out. It blocks forever with reminders. This stacks on top of existing hooks (protect-main, protect-database) as a judgment layer above the hard blocks.
- **"Keep AI running" principle** — only `critical` truly stops work. `architecture` pauses that task but Claude works on other things. `preference` auto-resolves. The system is biased toward forward progress.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Claude Code                              │
│                    MCP Tool Call                                 │
│            ask_human(priority: "architecture")                  │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                    MCP Server (Node.js)                         │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐ │
│  │  Tool Layer  │  │   Priority   │  │    Session Manager    │ │
│  │              │  │   Engine     │  │                       │ │
│  │ • ask_human  │──│ • timeout    │  │ • chat_id binding     │ │
│  │ • notify_    │  │   rules      │  │ • request tracking    │ │
│  │   human      │  │ • escalation │  │ • response routing    │ │
│  │ • configure  │  │ • defaults   │  │                       │ │
│  └──────────────┘  └──────┬───────┘  └───────────────────────┘ │
│                           │                                     │
│                    ┌──────▼───────┐                             │
│                    │   Adapter    │                             │
│                    │  Interface   │                             │
│                    └──────┬───────┘                             │
│                           │                                     │
│              ┌────────────┼────────────┐                       │
│              ▼            ▼            ▼                       │
│     ┌──────────────┐ ┌────────┐ ┌──────────┐                  │
│     │   Telegram   │ │ Slack  │ │ Discord  │                  │
│     │   Adapter    │ │Adapter │ │ Adapter  │                  │
│     │  (default)   │ │(future)│ │ (future) │                  │
│     └──────┬───────┘ └────────┘ └──────────┘                  │
└────────────┼────────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Telegram Bot API                            │
│         Long Polling (no public URL required)                   │
│     Bot → You: rich messages, code blocks, inline keyboards     │
│     You → Bot: text replies, button taps                        │
└─────────────────────────────────────────────────────────────────┘
```

### Internal Components

**Tool Layer** — Three MCP tools exposed to Claude Code: `ask_human` (blocking), `notify_human` (non-blocking), `configure_hitl` (session setup).

**Priority Engine** — Applies timeout rules, escalation logic (reminders for `critical`), and default-picking based on the priority tier. Adapts message formatting based on adapter capabilities.

**Session Manager** — Tracks active requests, routes incoming responses to the correct pending `ask_human` call, manages chat ID binding. Each `ask_human` call generates a unique request ID embedded in the Telegram message (as inline keyboard callback data). When the user taps a button, the callback data routes to the correct pending request. For free-text replies, the session manager matches responses to the most recent pending request (LIFO). If multiple requests are pending simultaneously, the Telegram message includes a visible request label (e.g., "#2: Redis or Postgres?") so the user can prefix their reply (e.g., "#2 Postgres") for explicit routing. Unprefixed free-text replies go to the most recent request.

**Adapter Interface** — A contract that any chat platform implements. The priority engine uses the adapter's declared capabilities to gracefully degrade (no buttons → numbered list, no threading → reply-to).

## Tool API

### ask_human

Blocking tool. Sends a message to the human and waits for a response.

**Input:**

```typescript
{
  message: string;              // Question or decision (markdown)
  priority: "critical" | "architecture" | "preference";
  options?: Array<{
    text: string;
    description?: string;
    default?: boolean;          // Picked on timeout for "preference"
  }>;
  context?: string;             // Additional detail (collapsed in Telegram)
  timeout_minutes?: number;     // Override default for this tier
}
```

**Response:**

```typescript
{
  status: "answered" | "timed_out" | "error";
  response: string;             // Human's text or button selection
  selected_option?: number;     // Index if they tapped a button
  response_time_seconds: number;
  priority: string;             // Echo back for context
  timed_out_action?: "used_default" | "paused" | null;
}
```

### notify_human

Non-blocking tool. Fire and forget, returns immediately.

**Input:**

```typescript
{
  message: string;              // Status update (markdown)
  level?: "info" | "success" | "warning" | "error";
  silent?: boolean;             // Suppress push notification (default: false)
}
```

**Response:**

```typescript
{
  status: "sent" | "error";
  message_id: string;
}
```

### configure_hitl

Runtime configuration. Called once at session start.

**Input:**

```typescript
{
  session_context?: string;     // "Implementing auth for project-foo"
  timeout_overrides?: {
    critical?: null;            // Cannot override (always infinite)
    architecture?: number;      // Minutes
    preference?: number;        // Minutes
  };
  quiet_hours?: {
    start: string;              // "22:00"
    end: string;                // "08:00"
    timezone: string;           // "America/New_York"
    behavior: "queue" | "skip_preference";
  };
}
```

**Response:**

```typescript
{
  status: "configured" | "error";
  active_config: {              // Merged result of file config + overrides
    adapter: string;
    session_context: string;
    timeouts: { critical: null; architecture: number; preference: number };
    quiet_hours: { start: string; end: string; timezone: string; behavior: string } | null;
  };
  error?: string;
}
```

## Adapter Interface

```typescript
// Priority tier type
type Priority = "critical" | "architecture" | "preference";

// Returned by awaitBinding() after user sends /start
interface UserBinding {
  userId: string;               // Platform-specific user ID
  displayName: string;          // Human-readable name
  chatId: string;               // Platform-specific chat/channel ID
}

// Adapter-specific connection config (token, polling settings, etc.)
interface AdapterConfig {
  token: string;                // Bot token (resolved from env: prefix)
  chatId?: string;              // Pre-bound chat ID (from config file)
  [key: string]: unknown;       // Adapter-specific fields
}

// Normalized inbound message from human
interface InboundMessage {
  text: string;                 // Message text or button label
  messageId: string;            // Platform message ID
  isButtonTap: boolean;         // True if user tapped an inline button
  selectedIndex?: number;       // Button index if isButtonTap
  callbackData?: string;        // Raw callback data (contains request ID)
  replyToMessageId?: string;    // If user explicitly replied to a message
}

type MessageHandler = (message: InboundMessage) => void;

interface ChatAdapter {
  readonly name: string;

  // Lifecycle
  connect(config: AdapterConfig): Promise<void>;
  disconnect(): Promise<void>;
  isConnected(): boolean;

  // Auth — bind to a specific user
  awaitBinding(): Promise<UserBinding>;

  // Outbound
  sendMessage(params: {
    text: string;
    level?: "info" | "success" | "warning" | "error";
    silent?: boolean;
  }): Promise<{ messageId: string }>;

  sendInteractiveMessage(params: {
    text: string;
    requestId: string;          // Embedded in callback data for routing
    options?: Array<{ text: string; description?: string; isDefault?: boolean }>;
    context?: string;
    priority: Priority;
  }): Promise<{ messageId: string }>;

  editMessage(params: {
    messageId: string;
    text: string;
  }): Promise<void>;

  // Inbound
  onMessage(handler: MessageHandler): void;

  // Capabilities (for graceful degradation)
  readonly capabilities: {
    inlineButtons: boolean;
    threading: boolean;
    messageEditing: boolean;
    silentMessages: boolean;
    richFormatting: boolean;
  };
}
```

### Capability-Based Degradation

The priority engine adapts to the adapter's declared capabilities:

- **inlineButtons supported** → render options as tappable buttons; **not supported** → numbered text list ("Reply 1 for Redis, 2 for Postgres")
- **threading supported** → group all messages for one `ask_human` call in a thread; **not supported** → use reply-to-message for context
- **messageEditing supported** → update expired questions with "⏱ Expired — used default: X"

### Telegram Adapter (Ships First)

- Bot token from @BotFather
- Long polling via `getUpdates` (no public URL, works behind NAT)
- Inline keyboards for options
- `reply_to_message_id` for context linking
- `editMessageText` for expiry/confirmation updates

### Future Adapters

- **Slack**: Bolt SDK with Socket Mode, Block Kit for buttons, native threads, App Home for dashboard.
- **Discord**: discord.js with Gateway, message components for buttons, DM-first.

## Authentication

**Chat ID lockdown model:**

1. During `claude-hitl setup`, the bot starts long polling
2. User sends `/start` to the bot in Telegram
3. Bot captures `chat_id` from the message, stores in `~/.claude-hitl.json`
4. All subsequent messages are only accepted from this `chat_id`
5. Any message from another `chat_id` is silently ignored

Re-binding: run `claude-hitl setup` again to bind a different user.

## Configuration

### Config File: ~/.claude-hitl.json

```json
{
  "adapter": "telegram",
  "telegram": {
    "bot_token": "env:TELEGRAM_BOT_TOKEN",
    "chat_id": 123456789
  },
  "defaults": {
    "timeouts": {
      "architecture": 120,
      "preference": 30
    },
    "quiet_hours": {
      "start": "22:00",
      "end": "08:00",
      "timezone": "America/New_York",
      "behavior": "skip_preference"
    }
  }
}
```

- `bot_token` uses `env:` prefix to read from environment variable (no secrets in the file)
- `chat_id` is auto-populated after first `/start` binding
- `adapter` field selects which implementation to use
- `quiet_hours.behavior`: `"queue"` holds all messages until morning; `"skip_preference"` auto-resolves preference tier, queues the rest
- **Quiet hours and critical priority**: `critical` requests always override quiet hours and deliver immediately with full push notification. The "block indefinitely" invariant for `critical` is never violated by quiet hours. Only `architecture` and `preference` are affected by quiet hours settings.

## Integration with claude-setup

### claude-config.txt

```
# Human-in-the-Loop notification bridge
mcp-server   | claude-hitl   | claude-hitl-mcp
```

### claude-global.md

The priority guide (shown above) is added inside `<!-- claude-setup:start -->` / `<!-- claude-setup:end -->` markers, same as existing behavioral rules.

### Bootstrap Behavior

- `claude-bootstrap.sh` installs the MCP server entry in `~/.claude/settings.json`
- If `TELEGRAM_BOT_TOKEN` is not set, bootstrap prints an optional hint — not a failure
- The MCP server itself handles the unconfigured case gracefully (tools return descriptive errors telling Claude to fall back to terminal prompts)

### CLI Commands

```
npx claude-hitl-mcp              # MCP stdio mode (started by Claude Code)
npx claude-hitl-mcp setup        # Interactive first-time setup
npx claude-hitl-mcp test         # Send a test notification
npx claude-hitl-mcp status       # Show config and connection status
```

## Graceful Degradation

When HITL is not configured:

- MCP server starts but tools return structured errors
- Claude falls back to standard terminal prompts
- Existing hooks (protect-main, protect-database) still prevent destructive operations
- No functionality is lost — HITL is additive

## Process Restart Behavior

The MCP server runs as a stdio subprocess of Claude Code. If Claude Code crashes or restarts:

- All pending `ask_human` calls are lost (they were blocking promises in the Node.js process)
- No persistence layer is needed — the MCP server is stateless between sessions
- Any unanswered Telegram messages remain in the chat but are orphaned (no process waiting for the response)
- On the next session, Claude starts fresh and will re-ask if the decision is still relevant
- The Telegram message is not retroactively updated (acceptable — the user sees the new session's questions)

This is the right trade-off: adding persistence (Redis, SQLite) for in-flight requests adds complexity for a rare edge case. Claude Code sessions are typically long-lived, and if one crashes, the human is likely re-engaging in the terminal anyway.

## Distribution

- **Package name**: `claude-hitl-mcp`
- **Runtime**: Node.js (TypeScript)
- **Install**: `npx -y claude-hitl-mcp` (zero pre-installation, matches Playwright/Context7 pattern)
- **Dependencies**: Minimal — MCP SDK, node-telegram-bot-api (or raw HTTP to Telegram API)
- **Target audience**: Any engineer using Claude Code who wants mobile notifications for HITL decisions

## Example Interaction

1. Claude is implementing a feature autonomously
2. Claude hits a design decision: Redis vs Postgres for a job queue
3. Claude calls `ask_human(message: "Redis or Postgres for job queue?", priority: "architecture", options: [{text: "Redis", default: true}, {text: "Postgres"}], context: "~500 jobs/day, Redis is faster but volatile, Postgres is already in the stack")`
4. You get a Telegram message with the question, context, and two buttons
5. You tap "Postgres" on your phone
6. Claude receives `{status: "answered", response: "Postgres", selected_option: 1}` and continues
7. The Telegram message updates to show "✓ Got it — continuing with Postgres."

If you don't respond within 2 hours, the tool returns `{status: "timed_out", timed_out_action: "paused"}` and Claude moves to other work.
