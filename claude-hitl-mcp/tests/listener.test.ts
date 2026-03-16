/**
 * Integration tests for the Listener daemon.
 *
 * Uses a real IpcServer on a temp socket path + IpcClient to drive IPC messages,
 * and a MockBot to inspect outbound Telegram messages.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import * as os from "node:os";
import * as path from "node:path";
import * as fs from "node:fs";
import { Listener } from "../src/listener.js";
import * as net from "node:net";
import { IpcClient } from "../src/ipc/client.js";
import type { ServerMessage, NotifyMessage } from "../src/ipc/protocol.js";
import { serialize } from "../src/ipc/protocol.js";
import { createMockBot } from "./helpers/mock-bot.js";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function tmpSocket(): string {
  // macOS Unix domain socket paths are limited to 104 characters.
  // Use a short prefix to stay under the limit.
  return path.join(
    os.tmpdir(),
    `hl-${Date.now()}-${Math.random().toString(36).slice(2, 7)}.sock`
  );
}

function tmpDir(): string {
  const dir = path.join(
    os.tmpdir(),
    `claude-hitl-cfg-${Date.now()}-${Math.random().toString(36).slice(2)}`
  );
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

/** Wait for up to `ms` ms, polling every 10 ms, until predicate returns true. */
async function waitFor(predicate: () => boolean, ms = 800): Promise<void> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  if (!predicate()) throw new Error("waitFor timed out");
}

/**
 * Returns a promise that resolves with the first ServerMessage of the given
 * type received by `client`, or rejects after `timeoutMs`.
 */
function nextMessage<T extends ServerMessage>(
  client: IpcClient,
  type: T["type"],
  timeoutMs = 800
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${type}`)), timeoutMs);
    const prev = (client as unknown as { messageHandler?: (msg: ServerMessage) => void }).messageHandler;
    client.onMessage((msg) => {
      if (msg.type === type) {
        clearTimeout(timer);
        // Restore previous handler if there was one
        if (prev) client.onMessage(prev);
        resolve(msg as T);
      } else if (prev) {
        prev(msg);
      }
    });
  });
}

const CHAT_ID = 12345;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("Listener", () => {
  let listener: Listener;
  let socketPath: string;
  let configDir: string;
  let bot: ReturnType<typeof createMockBot>;

  beforeEach(async () => {
    socketPath = tmpSocket();
    configDir = tmpDir();
    bot = createMockBot(CHAT_ID);

    listener = new Listener({
      configDir,
      socketPath,
      telegramBot: bot as unknown as import("../src/listener.js").TelegramBot,
      chatId: CHAT_ID,
      maxConnections: 10,
    });

    await listener.start();
  });

  afterEach(async () => {
    // Always restore real timers in case a test left fake timers active due to failure
    vi.useRealTimers();
    await listener.stop();
    try {
      fs.unlinkSync(socketPath);
    } catch {
      // already removed
    }
    fs.rmSync(configDir, { recursive: true, force: true });
  });

  // -------------------------------------------------------------------------
  // 1. IPC server starts and accepts connections
  // -------------------------------------------------------------------------

  describe("IPC server lifecycle", () => {
    it("starts the IPC server and accepts a client connection", async () => {
      const client = new IpcClient(socketPath);
      await client.connect("sess-1", "my-project", os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);
      expect(listener.getIpcServer().getSessions()).toHaveLength(1);
      await client.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // 2. /status command
  // -------------------------------------------------------------------------

  describe("/status command", () => {
    it("responds with 'No active Claude sessions' when no sessions", async () => {
      bot.simulateMessage("/status");
      await waitFor(() => bot.sentMessages.length > 0);
      expect(bot.sentMessages[0].text).toContain("No active Claude sessions");
    });

    it("includes session project when a session is connected", async () => {
      const client = new IpcClient(socketPath);
      await client.connect("sess-status", "status-project", os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);

      bot.simulateMessage("/status");
      await waitFor(() => bot.sentMessages.length > 0);

      expect(bot.sentMessages[0].text).toContain("status-project");

      await client.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // 3. /help command
  // -------------------------------------------------------------------------

  describe("/help command", () => {
    it("sends the help message listing all commands", async () => {
      bot.simulateMessage("/help");
      await waitFor(() => bot.sentMessages.length > 0);

      const text = bot.sentMessages[0].text;
      expect(text).toContain("/status");
      expect(text).toContain("/quiet");
      expect(text).toContain("/help");
    });
  });

  // -------------------------------------------------------------------------
  // 4. /quiet command
  // -------------------------------------------------------------------------

  describe("/quiet command", () => {
    it("shows quiet hours status with action buttons", async () => {
      bot.simulateMessage("/quiet");
      await waitFor(() => bot.sentMessages.length > 0);

      const msg = bot.sentMessages[0];
      expect(msg.text).toContain("Quiet hours");

      const keyboard = (
        msg.options as { reply_markup?: { inline_keyboard?: unknown[][] } }
      )?.reply_markup?.inline_keyboard;
      expect(Array.isArray(keyboard)).toBe(true);
      expect((keyboard as unknown[][]).length).toBeGreaterThan(0);
    });
  });

  // -------------------------------------------------------------------------
  // 5. ask IPC message → Telegram interactive message
  // -------------------------------------------------------------------------

  describe("ask IPC message routing", () => {
    it("sends an interactive Telegram message with [project] prefix and priority label", async () => {
      const client = new IpcClient(socketPath);
      await client.connect("sess-ask", "ask-project", os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);

      client.sendAsk(
        "req-001",
        "Which database?",
        "architecture",
        [
          { text: "Postgres", isDefault: true },
          { text: "MySQL" },
        ]
      );

      await waitFor(() => bot.sentMessages.length > 0);

      const msg = bot.sentMessages[0];
      expect(msg.text).toContain("[ask-project]");
      expect(msg.text).toContain("Which database?");

      const keyboard = (
        msg.options as { reply_markup?: { inline_keyboard?: unknown[][] } }
      )?.reply_markup?.inline_keyboard;
      expect(Array.isArray(keyboard)).toBe(true);
      expect((keyboard as unknown[][]).length).toBe(2);

      expect(listener.getPendingCount()).toBe(1);

      await client.disconnect();
    });

    it("sends a timeout IPC message after timeoutMinutes elapses", async () => {
      // Capture real setImmediate before fake timers replace it — we need it
      // below to yield past the I/O poll phase while fake timers are active.
      const realSetImmediate = setImmediate;

      // Connect and wait for the session to register using real timers so the
      // TCP handshake completes before we intercept timers.
      const client = new IpcClient(socketPath);
      await client.connect("sess-timeout", "timeout-project", os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);

      // Collect messages received by client
      const received: ServerMessage[] = [];
      client.onMessage((msg) => received.push(msg));

      // Activate fake timers so the listener's setTimeout for the 1-minute
      // timeout is registered as a fake timer we can fast-forward.
      vi.useFakeTimers();

      client.sendAsk(
        "req-timeout",
        "Timeout test",
        "preference",
        [{ text: "Default", isDefault: true }],
        0,
        1 // 1 minute
      );

      // Socket I/O fires during the libuv I/O poll phase.  Using real
      // setImmediate (captured before fake timers) yields past that phase,
      // allowing the listener to receive the socket data, process the ask,
      // call bot.sendMessage, and register the fake setTimeout for the timeout.
      const ioDeadline = Date.now() + 2000;
      while (bot.sentMessages.length === 0 && Date.now() < ioDeadline) {
        await new Promise<void>((r) => { realSetImmediate(r); });
      }
      expect(bot.sentMessages.length).toBeGreaterThan(0);

      // Advance fake time past the 1-minute timeout.  The fake setTimeout
      // callback fires synchronously inside advanceTimersByTime.
      vi.advanceTimersByTime(61 * 1000);

      // Restore real timers so the socket write from the timeout callback can
      // propagate to the client via real I/O.
      vi.useRealTimers();
      await waitFor(() => received.some((m) => m.type === "timeout"));

      const timeoutMsg = received.find((m) => m.type === "timeout") as
        | { type: "timeout"; requestId: string }
        | undefined;
      expect(timeoutMsg).toBeDefined();
      expect(timeoutMsg?.requestId).toBe("req-timeout");

      await client.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // 6. notify IPC message → Telegram message + notified ack
  // -------------------------------------------------------------------------

  describe("notify IPC message routing", () => {
    it("sends Telegram message and sends notified ack back to session", async () => {
      const client = new IpcClient(socketPath);
      await client.connect("sess-notify", "notify-project", os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);

      const notifiedPromise = nextMessage<{ type: "notified"; requestId: string; messageId: string }>(
        client,
        "notified"
      );

      client.sendNotify("notif-001", "Build succeeded", "success");

      const notified = await notifiedPromise;
      expect(notified.requestId).toBe("notif-001");
      expect(notified.messageId).toBeTruthy();

      // Bot received the Telegram message with project prefix
      await waitFor(() => bot.sentMessages.length > 0);
      expect(bot.sentMessages[0].text).toContain("[notify-project]");
      expect(bot.sentMessages[0].text).toContain("Build succeeded");

      await client.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // 7. Button tap → response IPC message to correct session
  // -------------------------------------------------------------------------

  describe("button tap response routing", () => {
    it("routes a callback_query button tap to the correct pending request", async () => {
      const client = new IpcClient(socketPath);
      await client.connect("sess-btn", "btn-project", os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);

      const responsePromise = nextMessage<{
        type: "response";
        requestId: string;
        text: string;
        selectedIndex?: number;
        isButtonTap: boolean;
      }>(client, "response");

      client.sendAsk("req-btn-001", "Choose one", "preference", [
        { text: "Option A" },
        { text: "Option B" },
      ]);

      await waitFor(() => bot.sentMessages.length > 0);

      // Simulate tapping button index 1 (Option B)
      bot.simulateCallbackQuery("req-btn-001:1");

      const response = await responsePromise;
      expect(response.requestId).toBe("req-btn-001");
      expect(response.text).toBe("Option B");
      expect(response.selectedIndex).toBe(1);
      expect(response.isButtonTap).toBe(true);
      expect(listener.getPendingCount()).toBe(0);

      await client.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // 8. Free text with no pending requests
  // -------------------------------------------------------------------------

  describe("free text response routing", () => {
    it("replies with 'No active Claude sessions' when no pending requests exist", async () => {
      bot.simulateMessage("hello there");
      await waitFor(() => bot.sentMessages.length > 0);

      const text = bot.sentMessages[0].text;
      expect(text).toContain("No active Claude sessions");
      expect(text).toContain("wasn't delivered");
    });

    it("routes free text to the most recent pending request (LIFO)", async () => {
      const client1 = new IpcClient(socketPath);
      const client2 = new IpcClient(socketPath);

      await client1.connect("sess-lifo-1", "project-1", os.homedir());
      await client2.connect("sess-lifo-2", "project-2", os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 2);

      // Collect responses per client
      const responses1: ServerMessage[] = [];
      const responses2: ServerMessage[] = [];
      client1.onMessage((m) => responses1.push(m));
      client2.onMessage((m) => responses2.push(m));

      client1.sendAsk("req-lifo-1", "First question", "architecture");
      await waitFor(() => bot.sentMessages.length >= 1);

      client2.sendAsk("req-lifo-2", "Second question", "preference");
      await waitFor(() => bot.sentMessages.length >= 2);

      // Free text should go to the most recently added request (req-lifo-2 / client2)
      bot.simulateMessage("my free text answer");

      await waitFor(() => responses2.some((m) => m.type === "response"));

      const response2 = responses2.find((m) => m.type === "response") as
        | { type: "response"; text: string }
        | undefined;
      expect(response2?.text).toBe("my free text answer");

      // req-lifo-1 should still be pending
      expect(listener.getPendingCount()).toBe(1);

      await client1.disconnect();
      await client2.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // 9. Quiet toggle via button → persists state, broadcasts to sessions
  // -------------------------------------------------------------------------

  describe("quiet hours toggle", () => {
    it("enables quiet hours and broadcasts quiet_hours_changed to connected sessions", async () => {
      const client = new IpcClient(socketPath);
      await client.connect("sess-quiet", "quiet-project", os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);

      const received: ServerMessage[] = [];
      client.onMessage((msg) => received.push(msg));

      // Simulate tapping "Turn On" quiet button
      bot.simulateCallbackQuery("quiet:on");

      await waitFor(() =>
        received.some((m) => m.type === "quiet_hours_changed")
      );

      const broadcast = received.find(
        (m) => m.type === "quiet_hours_changed"
      ) as
        | { type: "quiet_hours_changed"; quietHours: { enabled: boolean; manual: boolean } }
        | undefined;

      expect(broadcast?.quietHours.enabled).toBe(true);
      expect(broadcast?.quietHours.manual).toBe(true);

      // Turning back off should also broadcast
      bot.simulateCallbackQuery("quiet:off");

      await waitFor(
        () =>
          received.filter((m) => m.type === "quiet_hours_changed").length >= 2
      );

      const allBroadcasts = received.filter(
        (m) => m.type === "quiet_hours_changed"
      ) as Array<{ type: "quiet_hours_changed"; quietHours: { enabled: boolean } }>;

      expect(allBroadcasts).toHaveLength(2);
      expect(allBroadcasts[1].quietHours.enabled).toBe(false);

      await client.disconnect();
    });

    it("sends an updated quiet status message to Telegram after toggle", async () => {
      bot.simulateCallbackQuery("quiet:on");
      await waitFor(() => bot.sentMessages.length > 0);

      expect(bot.sentMessages[0].text).toContain("Quiet hours");
    });
  });

  // -------------------------------------------------------------------------
  // 10. Activity tracking and blocked notifications
  // -------------------------------------------------------------------------


  describe("activity tracking and blocked notifications", () => {
    it("sends Telegram notification when blocked message received", async () => {
      const client = new IpcClient(socketPath);
      await client.connect("sess-blocked", "blocked-project", os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);

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
      expect(bot.sentMessages[0].text.length).toBeLessThan(350);

      await client.disconnect();
    });

    it("/status shows activity state when activity data exists", async () => {
      const client = new IpcClient(socketPath);
      await client.connect("sess-state", "state-project", os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);

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

  // -------------------------------------------------------------------------
  // 11. ask_human priority levels
  // -------------------------------------------------------------------------

  describe("ask_human priority levels", () => {
    it.each([
      ["critical", "critical" as const],
      ["architecture", "architecture" as const],
      ["preference", "preference" as const],
    ])("relays %s ask to Telegram with buttons and routes response back", async (_label, priority) => {
      const client = new IpcClient(socketPath);
      await client.connect(`sess-${priority}`, `${priority}-project`, os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);

      const received: ServerMessage[] = [];
      client.onMessage((m) => received.push(m));

      client.sendAsk(
        `req-${priority}`,
        `Test ${priority} question`,
        priority,
        [{ text: "Option A", isDefault: true }, { text: "Option B" }]
      );

      await waitFor(() => bot.sentMessages.length > 0);

      const msg = bot.sentMessages[0];
      expect(msg.text).toContain(`[${priority}-project]`);
      expect(msg.text).toContain(`Test ${priority} question`);

      // Verify inline keyboard
      const keyboard = (msg.options as { reply_markup?: { inline_keyboard?: unknown[][] } })
        ?.reply_markup?.inline_keyboard;
      expect(Array.isArray(keyboard)).toBe(true);
      expect((keyboard as unknown[][]).length).toBe(2);

      // Verify default option marked with star
      const buttons = (keyboard as Array<Array<{ text: string }>>).flat();
      expect(buttons[0].text).toContain("⭐");

      // Simulate button tap
      bot.simulateCallbackQuery(`req-${priority}:1`);
      await waitFor(() => received.some((m) => m.type === "response"));

      const response = received.find((m) => m.type === "response") as {
        type: "response";
        requestId: string;
        text: string;
        selectedIndex?: number;
        isButtonTap: boolean;
      } | undefined;
      expect(response?.text).toBe("Option B");
      expect(response?.selectedIndex).toBe(1);
      expect(response?.isButtonTap).toBe(true);

      await client.disconnect();
    });

    it("critical priority does not time out", async () => {
      vi.useFakeTimers();
      try {
        const client = new IpcClient(socketPath);
        await client.connect("sess-crit-timeout", "crit-project", os.homedir());
        await vi.runAllTimersAsync();
        await waitFor(() => listener.getIpcServer().getSessions().length === 1, 200);

        const received: ServerMessage[] = [];
        client.onMessage((m) => received.push(m));

        client.sendAsk("req-crit-no-timeout", "Critical question", "critical", [
          { text: "OK", isDefault: true },
        ]);

        await vi.runAllTimersAsync();
        await waitFor(() => bot.sentMessages.length > 0, 200);

        // Verify the request is registered as pending before advancing time
        expect(listener.getPendingCount()).toBe(1);

        // Advance past the default preference timeout (60 min) to prove critical
        // has no timeout.  Disconnect before advancing to avoid the IpcClient
        // reconnect-backoff loop saturating the fake timer queue.
        await client.disconnect();
        vi.advanceTimersByTime(61 * 60 * 1000);
        await vi.runAllTimersAsync();

        // Should NOT have timed out — the pending entry must still be present
        expect(received.filter((m) => m.type === "timeout")).toHaveLength(0);
        expect(listener.getPendingCount()).toBe(1);
      } finally {
        vi.useRealTimers();
      }
    });
  });

  // -------------------------------------------------------------------------
  // 12. notify_human levels
  // -------------------------------------------------------------------------

  describe("notify_human levels", () => {
    it.each([
      ["info"],
      ["success"],
      ["warning"],
      ["error"],
    ])("relays %s notification to Telegram and sends ack", async (level) => {
      const client = new IpcClient(socketPath);
      await client.connect(`sess-${level}`, `${level}-project`, os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);

      const notifiedPromise = nextMessage<{ type: "notified"; requestId: string; messageId: string }>(
        client,
        "notified"
      );

      client.sendNotify(`notif-${level}`, `Test ${level} notification`, level as NotifyMessage["level"]);

      const notified = await notifiedPromise;
      expect(notified.requestId).toBe(`notif-${level}`);
      expect(notified.messageId).toBeTruthy();

      await waitFor(() => bot.sentMessages.length > 0);
      expect(bot.sentMessages[0].text).toContain(`[${level}-project]`);
      expect(bot.sentMessages[0].text).toContain(`Test ${level} notification`);

      await client.disconnect();
    });

    it("silent notification suppresses Telegram push notification", async () => {
      const client = new IpcClient(socketPath);
      await client.connect("sess-silent", "silent-project", os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);

      const notifiedPromise = nextMessage<{ type: "notified"; requestId: string; messageId: string }>(
        client,
        "notified"
      );

      client.sendNotify("notif-silent", "Silent message", "info", true);

      await notifiedPromise;
      await waitFor(() => bot.sentMessages.length > 0);

      const opts = bot.sentMessages[0].options as { disable_notification?: boolean } | undefined;
      expect(opts?.disable_notification).toBe(true);

      await client.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // 13. ask_human with context
  // -------------------------------------------------------------------------

  describe("ask_human with context", () => {
    it("includes context in the Telegram message when provided", async () => {
      const client = new IpcClient(socketPath);
      await client.connect("sess-ctx", "ctx-project", os.homedir());
      await waitFor(() => listener.getIpcServer().getSessions().length === 1);

      client.sendAsk(
        "req-ctx",
        "Question with context",
        "preference",
        [{ text: "OK" }],
        undefined,
        undefined,
        "Additional context here"
      );

      await waitFor(() => bot.sentMessages.length > 0);

      const msg = bot.sentMessages[0];
      expect(msg.text).toContain("Question with context");
      expect(msg.text).toContain("Context:");
      expect(msg.text).toContain("Additional context here");

      await client.disconnect();
    });
  });
});
