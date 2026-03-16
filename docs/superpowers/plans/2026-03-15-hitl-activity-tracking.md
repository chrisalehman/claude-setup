# HITL Activity Tracking Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real-time session activity tracking to the HITL Telegram bot so `/status` shows whether Claude is active, thinking, blocked on a permission prompt, or idle — and proactively notifies via Telegram when a session is blocked.

**Architecture:** Claude Code hooks (`PostToolUse`, `PermissionRequest`) send lightweight JSON messages to the listener daemon's Unix socket via shell scripts. The listener tracks `lastActivityAt` and `blockedOn` per session, uses this to enhance `/status` output, and sends a proactive Telegram notification when a session becomes blocked.

**Tech Stack:** TypeScript (vitest, tsup), shell scripts (bash, jq, nc)

**Spec:** `docs/superpowers/specs/2026-03-15-hitl-activity-tracking-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/ipc/protocol.ts` | Add `ActivityMessage`, `BlockedMessage` types to `ClientMessage` union |
| `src/ipc/server.ts` | Add activity fields to `SessionInfo`; handle ephemeral socket messages; update session state |
| `src/commands/status.ts` | Add `formatStateIndicator()`; update `StatusSession`, `formatSessionDetail`, `formatStatusMessage` |
| `src/listener.ts` | Route `blocked` messages to Telegram notification; plumb new fields to status formatters |
| `src/cli.ts` | Add `signal` subcommand; extend `setup` to install hooks |
| `bin/hook-activity.sh` | Shell script — PostToolUse hook |
| `bin/hook-blocked.sh` | Shell script — PermissionRequest hook |
| `tests/ipc/server.test.ts` | Tests for activity/blocked message handling on ephemeral sockets |
| `tests/commands/status.test.ts` | Tests for state indicator formatting |
| `tests/listener.test.ts` | Tests for proactive blocked notification and status with activity data |

---

## Chunk 1: Protocol & IPC Server

### Task 1: Add ActivityMessage and BlockedMessage to protocol

**Files:**
- Modify: `claude-hitl-mcp/src/ipc/protocol.ts`
- Test: `claude-hitl-mcp/tests/ipc/protocol.test.ts`

- [ ] **Step 1: Write failing test for new message serialization**

In `tests/ipc/protocol.test.ts`, add:

```typescript
it("serializes and deserializes ActivityMessage", () => {
  const msg: ActivityMessage = {
    type: "activity",
    sessionId: "sess-1",
    toolName: "Bash",
  };
  const line = serialize(msg);
  const parsed = deserialize(line.trim());
  expect(parsed).toEqual(msg);
});

it("serializes and deserializes BlockedMessage", () => {
  const msg: BlockedMessage = {
    type: "blocked",
    sessionId: "sess-1",
    toolName: "Bash",
    toolInput: "npm run build",
  };
  const line = serialize(msg);
  const parsed = deserialize(line.trim());
  expect(parsed).toEqual(msg);
});
```

Update the import to include `ActivityMessage`, `BlockedMessage`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd claude-hitl-mcp && npx vitest run tests/ipc/protocol.test.ts`
Expected: FAIL — `ActivityMessage` and `BlockedMessage` not exported.

- [ ] **Step 3: Add the new message types to protocol.ts**

In `src/ipc/protocol.ts`, add after `DeregisterMessage`:

```typescript
export interface ActivityMessage {
  type: "activity";
  sessionId: string;
  toolName: string;
}

export interface BlockedMessage {
  type: "blocked";
  sessionId: string;
  toolName: string;
  toolInput?: string;
}
```

Update the `ClientMessage` union:

```typescript
export type ClientMessage =
  | RegisterMessage
  | ConfigureMessage
  | AskMessage
  | NotifyMessage
  | DeregisterMessage
  | ActivityMessage
  | BlockedMessage;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd claude-hitl-mcp && npx vitest run tests/ipc/protocol.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add claude-hitl-mcp/src/ipc/protocol.ts claude-hitl-mcp/tests/ipc/protocol.test.ts
git commit -m "feat(hitl): add ActivityMessage and BlockedMessage to IPC protocol"
```

---

### Task 2: Add activity tracking fields to SessionInfo and handle ephemeral socket messages

**Files:**
- Modify: `claude-hitl-mcp/src/ipc/server.ts`
- Test: `claude-hitl-mcp/tests/ipc/server.test.ts`

- [ ] **Step 1: Write failing tests for activity/blocked message handling**

In `tests/ipc/server.test.ts`:

1. Add these imports at the file level (alongside existing imports):

```typescript
import * as net from "node:net";
import { serialize } from "../../src/ipc/protocol.js";
```

2. Add a new `describe` block **inside** the existing `describe("IpcServer", ...)` block (after the last existing test). This shares the existing `server`, `socketPath`, `beforeEach`, and `afterEach` lifecycle hooks:

```typescript
  describe("activity and blocked messages from ephemeral sockets", () => {
    it("updates session lastActivityAt when activity message received", async () => {
      server = new IpcServer(socketPath, { maxConnections: 10 });
      await server.start();

    // Register a session via normal client
    const client = new IpcClient(socketPath);
    await client.connect("sess-act", "test-project", "/tmp/project");
    await new Promise((r) => setTimeout(r, 100));

    // Send activity from ephemeral socket
    const ephemeral = net.createConnection(socketPath);
    await new Promise<void>((resolve) => ephemeral.on("connect", resolve));
    ephemeral.write(serialize({
      type: "activity",
      sessionId: "sess-act",
      toolName: "Bash",
    } as any));
    await new Promise((r) => setTimeout(r, 100));
    ephemeral.destroy();

    const sessions = server.getSessions();
    expect(sessions[0].lastActivityAt).toBeInstanceOf(Date);
    expect(sessions[0].lastActivityTool).toBe("Bash");

    await client.disconnect();
  });

  it("sets blockedOn when blocked message received", async () => {
    server = new IpcServer(socketPath, { maxConnections: 10 });
    await server.start();

    const client = new IpcClient(socketPath);
    await client.connect("sess-blk", "test-project", "/tmp/project");
    await new Promise((r) => setTimeout(r, 100));

    const ephemeral = net.createConnection(socketPath);
    await new Promise<void>((resolve) => ephemeral.on("connect", resolve));
    ephemeral.write(serialize({
      type: "blocked",
      sessionId: "sess-blk",
      toolName: "Edit",
      toolInput: "src/main.ts",
    } as any));
    await new Promise((r) => setTimeout(r, 100));
    ephemeral.destroy();

    const sessions = server.getSessions();
    expect(sessions[0].blockedOn).toBe("Edit");
    expect(sessions[0].blockedAt).toBeInstanceOf(Date);
    expect(sessions[0].lastActivityAt).toBeInstanceOf(Date);

    await client.disconnect();
  });

  it("clears blockedOn when activity message follows blocked", async () => {
    server = new IpcServer(socketPath, { maxConnections: 10 });
    await server.start();

    const client = new IpcClient(socketPath);
    await client.connect("sess-clr", "test-project", "/tmp/project");
    await new Promise((r) => setTimeout(r, 100));

    // Send blocked
    let eph = net.createConnection(socketPath);
    await new Promise<void>((resolve) => eph.on("connect", resolve));
    eph.write(serialize({
      type: "blocked",
      sessionId: "sess-clr",
      toolName: "Bash",
    } as any));
    await new Promise((r) => setTimeout(r, 100));
    eph.destroy();

    expect(server.getSessions()[0].blockedOn).toBe("Bash");

    // Send activity — should clear blocked
    eph = net.createConnection(socketPath);
    await new Promise<void>((resolve) => eph.on("connect", resolve));
    eph.write(serialize({
      type: "activity",
      sessionId: "sess-clr",
      toolName: "Read",
    } as any));
    await new Promise((r) => setTimeout(r, 100));
    eph.destroy();

    expect(server.getSessions()[0].blockedOn).toBeUndefined();
    expect(server.getSessions()[0].lastActivityTool).toBe("Read");

    await client.disconnect();
  });

  it("silently drops activity for unknown sessionId", async () => {
    server = new IpcServer(socketPath, { maxConnections: 10 });
    await server.start();

    const ephemeral = net.createConnection(socketPath);
    await new Promise<void>((resolve) => ephemeral.on("connect", resolve));
    ephemeral.write(serialize({
      type: "activity",
      sessionId: "nonexistent",
      toolName: "Bash",
    } as any));
    await new Promise((r) => setTimeout(r, 100));
    ephemeral.destroy();

    // No crash, no sessions affected
    expect(server.getSessions()).toHaveLength(0);
  });
  });  // close nested describe
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd claude-hitl-mcp && npx vitest run tests/ipc/server.test.ts`
Expected: FAIL — `lastActivityAt`, `blockedOn` etc. don't exist on `SessionInfo`; activity/blocked messages are silently dropped.

- [ ] **Step 3: Implement activity tracking in IPC server**

In `src/ipc/server.ts`:

1. Add fields to `SessionInfo`:

```typescript
export interface SessionInfo {
  sessionId: string;
  project: string;
  cwd: string | null;
  worktree?: string;
  sessionContext?: string;
  timeoutOverrides?: { architecture?: number; preference?: number };
  connectedAt: Date;
  socket: net.Socket;
  lastActivityAt?: Date;
  lastActivityTool?: string;
  blockedOn?: string;
  blockedAt?: Date;
}
```

2. Add import for `ActivityMessage` and `BlockedMessage` from `./protocol.js`.

3. In `handleLine()`, add the else branch after the existing `sessionId` forwarding block (after line 254):

```typescript
    // Forward other messages to handler
    if (sessionId) {
      const session = this.sessions.get(sessionId);
      if (session && this.messageHandler) {
        this.messageHandler(session, msg as ClientMessage);
      }
    } else if (msg.type === "activity" || msg.type === "blocked") {
      // Ephemeral socket from hook script — look up session by message body
      const hookMsg = msg as ActivityMessage | BlockedMessage;
      const session = this.sessions.get(hookMsg.sessionId);
      if (session) {
        if (hookMsg.type === "activity") {
          session.lastActivityAt = new Date();
          session.lastActivityTool = hookMsg.toolName;
          session.blockedOn = undefined;
          session.blockedAt = undefined;
        } else {
          session.blockedOn = hookMsg.toolName;
          session.blockedAt = new Date();
          session.lastActivityAt = new Date();
          session.lastActivityTool = hookMsg.toolName;
        }
        // Forward to message handler for listener-level handling (e.g. blocked notification)
        if (this.messageHandler) {
          this.messageHandler(session, hookMsg);
        }
      }
      // Close ephemeral socket
      socket.destroy();
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd claude-hitl-mcp && npx vitest run tests/ipc/server.test.ts`
Expected: PASS

- [ ] **Step 5: Run full test suite to check for regressions**

Run: `cd claude-hitl-mcp && npx vitest run`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add claude-hitl-mcp/src/ipc/server.ts claude-hitl-mcp/tests/ipc/server.test.ts
git commit -m "feat(hitl): track session activity/blocked state from ephemeral hook sockets"
```

---

## Chunk 2: Enhanced /status Formatting

### Task 3: Add state indicator to status formatting

**Files:**
- Modify: `claude-hitl-mcp/src/commands/status.ts`
- Test: `claude-hitl-mcp/tests/commands/status.test.ts`

- [ ] **Step 1: Write failing tests for state indicator**

In `tests/commands/status.test.ts`, add:

```typescript
import { formatStateIndicator } from "../../src/commands/status.js";

describe("formatStateIndicator", () => {
  it("returns 'Active' when lastActivityAge < 30", () => {
    const result = formatStateIndicator({ lastActivityAge: 12 });
    expect(result).toContain("Active");
    expect(result).toContain("12s ago");
  });

  it("returns 'Thinking' when lastActivityAge is 30-120", () => {
    const result = formatStateIndicator({ lastActivityAge: 45 });
    expect(result).toContain("Thinking");
    expect(result).toContain("45s ago");
  });

  it("returns 'Idle' when lastActivityAge > 120", () => {
    const result = formatStateIndicator({ lastActivityAge: 300 });
    expect(result).toContain("Idle");
    expect(result).toContain("5m ago");
  });

  it("returns 'Waiting for permission' when blockedOn is set", () => {
    const result = formatStateIndicator({ lastActivityAge: 5, blockedOn: "Bash" });
    expect(result).toContain("Waiting for permission");
    expect(result).toContain("Bash");
  });

  it("returns 'No activity data' when lastActivityAge is undefined", () => {
    const result = formatStateIndicator({});
    expect(result).toContain("No activity data");
  });

  it("auto-clears blockedOn when blockedAge exceeds 60s", () => {
    const result = formatStateIndicator({ lastActivityAge: 90, blockedOn: "Bash", blockedAge: 65 });
    expect(result).not.toContain("Waiting for permission");
    expect(result).toContain("Thinking");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd claude-hitl-mcp && npx vitest run tests/commands/status.test.ts`
Expected: FAIL — `formatStateIndicator` not exported.

- [ ] **Step 3: Implement formatStateIndicator and update StatusSession**

In `src/commands/status.ts`:

1. Add `blockedAge` to the input type and export the new function:

```typescript
export interface StateIndicatorInput {
  lastActivityAge?: number;  // seconds
  blockedOn?: string;
  blockedAge?: number;       // seconds since blockedAt
}

export function formatStateIndicator(input: StateIndicatorInput): string {
  const { lastActivityAge, blockedOn, blockedAge } = input;

  // Blocked state (auto-clear after 60s)
  if (blockedOn && (blockedAge === undefined || blockedAge <= 60)) {
    return `⚠️ Waiting for permission (${blockedOn})`;
  }

  if (lastActivityAge === undefined) {
    return "No activity data";
  }

  if (lastActivityAge < 30) {
    return `🟢 Active (${formatAge(lastActivityAge)})`;
  }
  if (lastActivityAge <= 120) {
    return `💭 Thinking (${formatAge(lastActivityAge)})`;
  }
  return `💤 Idle (${formatAge(lastActivityAge)})`;
}
```

2. Update `StatusSession` interface to include new fields:

```typescript
export interface StatusSession {
  sessionId: string;
  project: string;
  worktree?: string;
  sessionContext?: string;
  plan: string | null;
  pendingCount: number;
  oldestPendingAge?: number;
  lastActivityAge?: number;
  blockedOn?: string;
  blockedAge?: number;
}
```

Note: `lastActivityTool` is tracked on `SessionInfo` (for the blocked notification) but is not included in `StatusSession` since no formatter displays it.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd claude-hitl-mcp && npx vitest run tests/commands/status.test.ts`
Expected: New tests PASS, existing tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add claude-hitl-mcp/src/commands/status.ts claude-hitl-mcp/tests/commands/status.test.ts
git commit -m "feat(hitl): add formatStateIndicator with Active/Thinking/Blocked/Idle states"
```

---

### Task 4: Update formatSessionDetail and formatStatusMessage to include state indicator

**Files:**
- Modify: `claude-hitl-mcp/src/commands/status.ts`
- Test: `claude-hitl-mcp/tests/commands/status.test.ts`

- [ ] **Step 1: Write failing tests for updated formatters**

In `tests/commands/status.test.ts`, add to the `formatSessionDetail` describe block:

```typescript
it("shows state indicator when activity data is present", () => {
  const session: StatusSession = {
    sessionId: "s1",
    project: "myproject",
    plan: null,
    pendingCount: 0,
    lastActivityAge: 5,
  };
  const text = formatSessionDetail(session);
  expect(text).toContain("Active");
  expect(text).toContain("5s ago");
});

it("shows blocked state in detail view", () => {
  const session: StatusSession = {
    sessionId: "s1",
    project: "myproject",
    plan: null,
    pendingCount: 0,
    blockedOn: "Bash",
    blockedAge: 10,
    lastActivityAge: 10,
  };
  const text = formatSessionDetail(session);
  expect(text).toContain("Waiting for permission");
  expect(text).toContain("Bash");
});
```

Add to the `formatStatusMessage` describe block:

```typescript
it("shows state indicator instead of plan first-line in multi-session compact view", () => {
  const sessions: StatusSession[] = [
    { sessionId: "s1", project: "proj-a", plan: null, pendingCount: 0, lastActivityAge: 5 },
    { sessionId: "s2", project: "proj-b", plan: null, pendingCount: 0, lastActivityAge: 300 },
  ];
  const msg = formatStatusMessage(sessions, []);
  expect(msg.text).toContain("Active");
  expect(msg.text).toContain("Idle");
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd claude-hitl-mcp && npx vitest run tests/commands/status.test.ts`
Expected: FAIL — formatters don't include state indicator yet.

- [ ] **Step 3: Replace the entire `formatSessionDetail` function**

Replace the entire existing `formatSessionDetail` function body in `src/commands/status.ts` with the version below (adds state indicator between context and plan):

```typescript
export function formatSessionDetail(session: StatusSession): string {
  const lines: string[] = [];

  // Header line: project + optional worktree
  const headerParts = [session.project];
  if (session.worktree) headerParts.push(`(worktree: ${session.worktree})`);
  lines.push(headerParts.join(" "));

  // Optional context
  if (session.sessionContext) {
    lines.push(`Context: ${session.sessionContext}`);
  }

  lines.push("");

  // State indicator
  const state = formatStateIndicator({
    lastActivityAge: session.lastActivityAge,
    blockedOn: session.blockedOn,
    blockedAge: session.blockedAge,
  });
  lines.push(state);

  lines.push("");

  // Plan section
  if (session.plan) {
    lines.push(`📋 Plan:\n${truncatePlan(session.plan, 3000)}`);
  } else {
    lines.push("No active plan");
  }

  lines.push("");

  // Pending questions
  if (session.pendingCount > 0) {
    const plural = session.pendingCount === 1 ? "question" : "questions";
    const agePart =
      session.oldestPendingAge !== undefined
        ? ` (${formatAge(session.oldestPendingAge)})`
        : "";
    lines.push(`⏳ ${session.pendingCount} pending ${plural}${agePart}`);
  } else {
    lines.push("✅ No pending questions");
  }

  return lines.join("\n");
}
```

- [ ] **Step 4: Update formatStatusMessage multi-session compact view**

In the multi-session branch of `formatStatusMessage()`, replace the plan first-line with the state indicator:

```typescript
    // State indicator (replaces plan first-line in compact view)
    const state = formatStateIndicator({
      lastActivityAge: session.lastActivityAge,
      blockedOn: session.blockedOn,
      blockedAge: session.blockedAge,
    });
    summaryLines.push(`   ${state}`);
```

Remove the old plan first-line block:
```typescript
    // REMOVE THIS:
    // if (session.plan) {
    //   const firstLine = session.plan.split("\n").find((l) => l.trim() !== "") ?? "No active plan";
    //   summaryLines.push(`   ${firstLine}`);
    // } else {
    //   summaryLines.push("   No active plan");
    // }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd claude-hitl-mcp && npx vitest run tests/commands/status.test.ts`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
git add claude-hitl-mcp/src/commands/status.ts claude-hitl-mcp/tests/commands/status.test.ts
git commit -m "feat(hitl): show session state indicator in /status output"
```

---

## Chunk 3: Listener Integration

### Task 5: Plumb activity data into /status and send proactive blocked notifications

**Files:**
- Modify: `claude-hitl-mcp/src/listener.ts`
- Test: `claude-hitl-mcp/tests/listener.test.ts`

- [ ] **Step 1: Write failing tests**

In `tests/listener.test.ts`, add a new describe block:

```typescript
import * as net from "node:net";
import { serialize } from "../src/ipc/protocol.js";

describe("activity tracking and blocked notifications", () => {
  it("sends Telegram notification when blocked message received", async () => {
    const client = new IpcClient(socketPath);
    await client.connect("sess-blocked", "blocked-project", os.homedir());
    await waitFor(() => listener.getIpcServer().getSessions().length === 1);

    // Send blocked from ephemeral socket
    const eph = net.createConnection(socketPath);
    await new Promise<void>((resolve) => eph.on("connect", resolve));
    eph.write(serialize({
      type: "blocked",
      sessionId: "sess-blocked",
      toolName: "Bash",
      toolInput: "npm run build",
    } as any));
    await new Promise((r) => setTimeout(r, 200));
    eph.destroy();

    await waitFor(() => bot.sentMessages.length > 0);

    const msg = bot.sentMessages[0];
    expect(msg.text).toContain("blocked-project");
    expect(msg.text).toContain("Waiting for permission");
    expect(msg.text).toContain("Bash");
    expect(msg.text).toContain("npm run build");

    await client.disconnect();
  });

  it("truncates toolInput to 200 characters in blocked notification", async () => {
    const client = new IpcClient(socketPath);
    await client.connect("sess-trunc", "trunc-project", os.homedir());
    await waitFor(() => listener.getIpcServer().getSessions().length === 1);

    const longInput = "x".repeat(300);
    const eph = net.createConnection(socketPath);
    await new Promise<void>((resolve) => eph.on("connect", resolve));
    eph.write(serialize({
      type: "blocked",
      sessionId: "sess-trunc",
      toolName: "Bash",
      toolInput: longInput,
    } as any));
    await new Promise((r) => setTimeout(r, 200));
    eph.destroy();

    await waitFor(() => bot.sentMessages.length > 0);
    // Message should not contain the full 300 chars
    expect(bot.sentMessages[0].text.length).toBeLessThan(350);

    await client.disconnect();
  });

  it("/status shows activity state when activity data exists", async () => {
    const client = new IpcClient(socketPath);
    await client.connect("sess-state", "state-project", os.homedir());
    await waitFor(() => listener.getIpcServer().getSessions().length === 1);

    // Send activity
    const eph = net.createConnection(socketPath);
    await new Promise<void>((resolve) => eph.on("connect", resolve));
    eph.write(serialize({
      type: "activity",
      sessionId: "sess-state",
      toolName: "Read",
    } as any));
    await new Promise((r) => setTimeout(r, 200));
    eph.destroy();

    bot.simulateMessage("/status");
    await waitFor(() => bot.sentMessages.length > 0);

    expect(bot.sentMessages[0].text).toContain("Active");

    await client.disconnect();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd claude-hitl-mcp && npx vitest run tests/listener.test.ts`
Expected: FAIL — listener doesn't handle blocked messages or pass activity data to status.

- [ ] **Step 3: Update listener to handle blocked messages**

In `src/listener.ts`:

1. Add import for `BlockedMessage`:

```typescript
import type { AskMessage, NotifyMessage, BlockedMessage } from "./ipc/protocol.js";
```

2. In `handleIpcMessage()`, add the `blocked` case:

```typescript
  private handleIpcMessage(session: SessionInfo, message: ClientMessage): void {
    switch (message.type) {
      case "ask":
        void this.handleAskMessage(session, message as AskMessage);
        break;
      case "notify":
        void this.handleNotifyMessage(session, message as NotifyMessage);
        break;
      case "blocked":
        void this.handleBlockedMessage(session, message as BlockedMessage);
        break;
      default:
        break;
    }
  }
```

3. Add the blocked message handler:

```typescript
  private async handleBlockedMessage(
    session: SessionInfo,
    msg: BlockedMessage
  ): Promise<void> {
    const prefix = `[${session.project}]`;
    const toolLine = `Tool: ${msg.toolName}`;
    const inputLine = msg.toolInput
      ? `\n${msg.toolInput.slice(0, 200)}`
      : "";
    const fullText = `${prefix} ⚠️ Waiting for permission\n${toolLine}${inputLine}\n\nGo to terminal to approve or deny.`;

    await this.bot.sendMessage(this.opts.chatId, fullText, {
      disable_notification: false,
    });
  }
```

- [ ] **Step 4: Update handleStatusCommand to include activity data**

In `handleStatusCommand()`, update the `StatusSession` mapping to include the new fields:

```typescript
    const statusSessions: StatusSession[] = sessions.map((s) => {
      let pendingCount = 0;
      let oldestPendingAge: number | undefined;
      const now = Date.now();

      for (const entry of this.pending.values()) {
        if (entry.sessionId === s.sessionId) {
          pendingCount++;
          const ageSeconds = (now - entry.createdAt) / 1000;
          if (oldestPendingAge === undefined || ageSeconds > oldestPendingAge) {
            oldestPendingAge = ageSeconds;
          }
        }
      }

      return {
        sessionId: s.sessionId,
        project: s.project,
        worktree: s.worktree,
        sessionContext: s.sessionContext,
        plan: readPlanFile(s.cwd),
        pendingCount,
        oldestPendingAge,
        lastActivityAge: s.lastActivityAt
          ? (now - s.lastActivityAt.getTime()) / 1000
          : undefined,

        blockedOn: s.blockedOn,
        blockedAge: s.blockedAt
          ? (now - s.blockedAt.getTime()) / 1000
          : undefined,
      };
    });
```

Also update `handleStatusDrillDown()` — replace the `StatusSession` construction (lines 482-490) with the same mapping. The updated block:

```typescript
    const statusSession: StatusSession = {
      sessionId: session.sessionId,
      project: session.project,
      worktree: session.worktree,
      sessionContext: session.sessionContext,
      plan: readPlanFile(session.cwd),
      pendingCount,
      oldestPendingAge,
      lastActivityAge: session.lastActivityAt
        ? (now - session.lastActivityAt.getTime()) / 1000
        : undefined,
      blockedOn: session.blockedOn,
      blockedAge: session.blockedAt
        ? (now - session.blockedAt.getTime()) / 1000
        : undefined,
    };
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd claude-hitl-mcp && npx vitest run tests/listener.test.ts`
Expected: All tests PASS.

- [ ] **Step 6: Run full test suite**

Run: `cd claude-hitl-mcp && npx vitest run`
Expected: All tests PASS.

- [ ] **Step 7: Commit**

```bash
git add claude-hitl-mcp/src/listener.ts claude-hitl-mcp/tests/listener.test.ts
git commit -m "feat(hitl): proactive blocked notification and activity-aware /status"
```

---

## Chunk 4: Hook Scripts & CLI

### Task 6: Create hook shell scripts

**Files:**
- Create: `claude-hitl-mcp/bin/hook-activity.sh`
- Create: `claude-hitl-mcp/bin/hook-blocked.sh`

- [ ] **Step 1: Create bin directory and hook-activity.sh**

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

- [ ] **Step 2: Create hook-blocked.sh**

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

- [ ] **Step 3: Make scripts executable**

Run: `chmod +x claude-hitl-mcp/bin/hook-activity.sh claude-hitl-mcp/bin/hook-blocked.sh`

- [ ] **Step 4: Commit**

```bash
git add claude-hitl-mcp/bin/hook-activity.sh claude-hitl-mcp/bin/hook-blocked.sh
git commit -m "feat(hitl): add PostToolUse and PermissionRequest hook scripts"
```

---

### Task 7: Add signal CLI subcommand

**Files:**
- Modify: `claude-hitl-mcp/src/cli.ts`

- [ ] **Step 1: Add the signal command function**

In `src/cli.ts`, add before the `USAGE` constant:

```typescript
function signal(args: string[]): void {
  const type = args[0]; // "activity" or "blocked"
  if (type !== "activity" && type !== "blocked") {
    console.error("Usage: claude-hitl-mcp signal <activity|blocked> --session-id <id> --tool <name> [--input <text>]");
    process.exit(1);
  }

  const sessionId = getArg(args, "--session-id");
  const toolName = getArg(args, "--tool");
  if (!sessionId || !toolName) {
    console.error("--session-id and --tool are required");
    process.exit(1);
  }

  const toolInput = getArg(args, "--input");

  const msg: Record<string, string> = { type, sessionId, toolName };
  if (toolInput && type === "blocked") {
    msg.toolInput = toolInput;
  }

  const socketPath = `${HITL_CONFIG_DIR}/sock`;
  const socket = net.createConnection(socketPath);

  socket.on("connect", () => {
    socket.write(JSON.stringify(msg) + "\n", () => {
      console.log("sent");
      socket.destroy();
      process.exit(0);
    });
  });

  socket.on("error", (err) => {
    console.error(`failed: ${err.message}`);
    process.exit(1);
  });
}

function getArg(args: string[], flag: string): string | undefined {
  const idx = args.indexOf(flag);
  return idx !== -1 && idx + 1 < args.length ? args[idx + 1] : undefined;
}
```

Add `import * as net from "node:net";` at the top.

- [ ] **Step 2: Add signal to the switch statement and USAGE**

Update `USAGE` to include:
```
  claude-hitl-mcp signal <type>   Send activity/blocked signal to listener
```

Add to the switch:
```typescript
  case "signal":
    signal(process.argv.slice(3));
    break;
```

- [ ] **Step 3: Manual test**

Run (with listener running and a connected session):
```bash
cd claude-hitl-mcp && node dist/cli.js signal activity --session-id test --tool Bash
```
Expected: "sent" (or "failed" if no listener running — both are correct behavior).

- [ ] **Step 4: Commit**

```bash
git add claude-hitl-mcp/src/cli.ts
git commit -m "feat(hitl): add signal CLI subcommand for testing activity/blocked"
```

---

### Task 8: Extend setup to install hooks

**Files:**
- Modify: `claude-hitl-mcp/src/cli.ts`

- [ ] **Step 1: Add hook installation logic to setup()**

At the end of the `setup()` function (after MCP server registration, before the test notification), add:

```typescript
  // Install Claude Code hooks for activity tracking
  try {
    const binDir = path.resolve(__dirname, "..", "bin");
    const activityHookPath = path.join(binDir, "hook-activity.sh");
    const blockedHookPath = path.join(binDir, "hook-blocked.sh");

    if (!settings.hooks) {
      settings.hooks = {};
    }

    const hookEvents: Record<string, string> = {
      PostToolUse: activityHookPath,
      PermissionRequest: blockedHookPath,
    };

    for (const [event, hookPath] of Object.entries(hookEvents)) {
      if (!settings.hooks[event]) {
        settings.hooks[event] = [];
      }
      const existing = settings.hooks[event] as Array<{ type: string; command: string }>;
      // Idempotent: don't add if already present
      if (!existing.some((h) => h.command === hookPath)) {
        existing.push({ type: "command", command: hookPath });
      }
    }

    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n", "utf-8");
    console.log("Claude Code hooks installed for activity tracking");
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.warn(`Warning: could not install hooks: ${message}`);
  }
```

Note: the `settings` variable is already in scope from the MCP server registration block above.

- [ ] **Step 2: Verify setup still works**

This requires an interactive test (Telegram binding), so just verify the code compiles:
Run: `cd claude-hitl-mcp && npx tsup`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add claude-hitl-mcp/src/cli.ts
git commit -m "feat(hitl): install activity tracking hooks during setup"
```

---

## Chunk 5: CLAUDE.md Rule & Final Verification

### Task 9: Add ask_human rule to CLAUDE.md

**Files:**
- Modify: `~/.claude/CLAUDE.md`

- [ ] **Step 1: Add the rule**

Append to `~/.claude/CLAUDE.md`:

```markdown
## Always Use ask_human for Questions
When asking the user a question, always use `mcp__claude-hitl__ask_human` with appropriate priority and options. Never print a question to the terminal and wait for stdin input.
```

- [ ] **Step 2: Verify (no commit needed — this is a user config file, not repo code)**

---

### Task 10: Full build and test verification

- [ ] **Step 1: Build**

Run: `cd claude-hitl-mcp && npx tsup`
Expected: Build succeeds with no errors.

- [ ] **Step 2: Run full test suite**

Run: `cd claude-hitl-mcp && npx vitest run`
Expected: All tests PASS.

- [ ] **Step 3: Verify hook scripts are executable**

Run: `ls -la claude-hitl-mcp/bin/hook-*.sh`
Expected: Both files have execute permission.

- [ ] **Step 4: Manual end-to-end test**

1. Restart the listener daemon: `claude-hitl-mcp stop-listener && claude-hitl-mcp start-listener`
2. Open a Claude Code session
3. Do something that triggers a tool use (e.g. read a file)
4. Send `/status` from Telegram — should show "Active (Xs ago)"
5. Wait 2+ minutes idle, send `/status` — should show "Idle (Xm ago)"
6. Trigger a permission prompt — should get a proactive "Waiting for permission" notification in Telegram

- [ ] **Step 5: Final commit (if any adjustments needed)**
