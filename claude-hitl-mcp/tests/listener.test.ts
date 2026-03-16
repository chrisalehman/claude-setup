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
import type { ServerMessage } from "../src/ipc/protocol.js";
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
      expect(msg.text).toContain("ARCHITECTURE");
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
      vi.useFakeTimers();

      const client = new IpcClient(socketPath);
      await client.connect("sess-timeout", "timeout-project", os.homedir());

      // Wait synchronously for the session to be tracked
      await vi.runAllTimersAsync();
      await waitFor(() => listener.getIpcServer().getSessions().length === 1, 200);

      // Collect messages received by client
      const received: ServerMessage[] = [];
      client.onMessage((msg) => received.push(msg));

      client.sendAsk(
        "req-timeout",
        "Timeout test",
        "preference",
        [{ text: "Default", isDefault: true }],
        0,
        1 // 1 minute
      );

      // Let the sendAsk message travel through the socket
      await vi.runAllTimersAsync();
      await waitFor(() => bot.sentMessages.length > 0, 200);

      // Advance time past the 1-minute timeout
      vi.advanceTimersByTime(61 * 1000);
      await vi.runAllTimersAsync();

      await waitFor(
        () => received.some((m) => m.type === "timeout"),
        200
      );

      const timeoutMsg = received.find((m) => m.type === "timeout") as
        | { type: "timeout"; requestId: string }
        | undefined;
      expect(timeoutMsg).toBeDefined();
      expect(timeoutMsg?.requestId).toBe("req-timeout");

      vi.useRealTimers();
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
});
