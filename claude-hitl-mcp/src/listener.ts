/**
 * Listener daemon — wires together IpcServer, Telegram bot, and command handlers.
 *
 * Routing responsibilities:
 *   Telegram → commands → handlers
 *   IpcServer → ask/notify messages → Telegram
 *   Telegram responses (button taps + free text) → IPC response back to MCP server
 *   Quiet hours toggle → broadcast quiet_hours_changed to all sessions
 */

import * as fs from "node:fs";
import * as os from "node:os";
import { fileURLToPath } from "node:url";
import type { ClientMessage } from "./ipc/protocol.js";
import type { SessionInfo } from "./ipc/server.js";
import { IpcServer } from "./ipc/server.js";
import type { AskMessage, NotifyMessage, BlockedMessage } from "./ipc/protocol.js";
import { formatHelpMessage } from "./commands/help.js";
import {
  formatStatusMessage,
  formatSessionDetail,
  readPlanFile,
  type StatusSession,
  type DisconnectedInfo,
} from "./commands/status.js";
import {
  formatQuietStatus,
  handleQuietAction,
  type QuietState,
} from "./commands/quiet.js";
import { loadConfig, saveConfig, resolveEnvValue, HITL_CONFIG_DIR } from "./config.js";
import { PriorityEngine } from "./priority-engine.js";
import type { HitlConfig } from "./types.js";

// Minimal interface for the Telegram bot so we can inject a mock in tests.
export interface TelegramBot {
  sendMessage(
    chatId: number | string,
    text: string,
    options?: Record<string, unknown>
  ): Promise<{ message_id: number }>;
  editMessageText(
    text: string,
    options?: Record<string, unknown>
  ): Promise<unknown>;
  answerCallbackQuery(queryId: string): Promise<boolean | void>;
  on(event: string, handler: (...args: unknown[]) => void): void;
  off(event: string, handler: (...args: unknown[]) => void): void;
}

export interface ListenerOptions {
  /** Path to ~/.claude-hitl — used for loading/saving config */
  configDir: string;
  /** Unix socket path for the IPC server */
  socketPath: string;
  /** node-telegram-bot-api instance (or mock in tests) */
  telegramBot: TelegramBot;
  /** Bound chat ID from config */
  chatId: number;
  /** Maximum concurrent MCP sessions (default 10) */
  maxConnections?: number;
}

/** Maps a pending requestId to the IPC sessionId that owns it */
interface PendingEntry {
  sessionId: string;
  timeoutHandle: ReturnType<typeof setTimeout> | null;
  createdAt: number;
  options?: AskMessage["options"];
  defaultIndex?: number;
  messageId?: number;
  originalText?: string;
}

export class Listener {
  private readonly opts: Required<ListenerOptions>;
  private readonly ipc: IpcServer;
  private readonly bot: TelegramBot;
  private readonly priorityEngine = new PriorityEngine();

  /** requestId → pending entry */
  private pending = new Map<string, PendingEntry>();

  /** quiet hours state (in-memory, persisted to config on change) */
  private quietState: QuietState = { enabled: false, manual: false };

  /** path to the config file (resolved once at construction) */
  private readonly configPath: string;

  constructor(opts: ListenerOptions) {
    this.opts = {
      ...opts,
      maxConnections: opts.maxConnections ?? 10,
    };
    this.configPath = `${opts.configDir}/config.json`;
    this.ipc = new IpcServer(opts.socketPath, {
      maxConnections: this.opts.maxConnections,
    });
    this.bot = opts.telegramBot;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  async start(): Promise<void> {
    // Load persisted quiet hours state from config
    this.loadQuietState();

    // Wire IPC message handler
    this.ipc.onMessage((session, message) => {
      this.handleIpcMessage(session, message);
    });

    // Wire Telegram event handlers
    this.bot.on("message", (raw: unknown) => {
      this.handleTelegramMessage(raw);
    });
    this.bot.on("callback_query", (raw: unknown) => {
      this.handleCallbackQuery(raw);
    });

    // Start IPC server
    await this.ipc.start();
  }

  async stop(): Promise<void> {
    // Clear all pending timeouts
    for (const entry of this.pending.values()) {
      if (entry.timeoutHandle !== null) clearTimeout(entry.timeoutHandle);
    }
    this.pending.clear();
    await this.ipc.stop();
  }

  // ---------------------------------------------------------------------------
  // Quiet hours — load/persist
  // ---------------------------------------------------------------------------

  private loadQuietState(): void {
    try {
      const config = loadConfig(this.configPath);
      if (config?.defaults?.quiet_hours) {
        const qh = config.defaults.quiet_hours as typeof config.defaults.quiet_hours & {
          enabled?: boolean;
          manualOverride?: boolean;
        };
        this.quietState = {
          enabled: qh.enabled ?? false,
          manual: qh.manualOverride ?? false,
          start: qh.start,
          end: qh.end,
          timezone: qh.timezone,
          behavior: qh.behavior,
        };
      }
    } catch {
      // If config can't be loaded, use default (quiet hours off)
    }
  }

  private persistQuietState(): void {
    try {
      const rawConfig: Record<string, unknown> = loadConfig(this.configPath) as unknown as Record<string, unknown> ?? {
        adapter: "telegram",
      };

      const existingDefaults = (rawConfig.defaults as Record<string, unknown>) ?? {};
      const quietHoursPayload: Record<string, unknown> = {
        ...((existingDefaults.quiet_hours as Record<string, unknown>) ?? {}),
        enabled: this.quietState.enabled,
        manualOverride: this.quietState.manual,
      };

      if (this.quietState.start && this.quietState.end && this.quietState.timezone) {
        quietHoursPayload.start = this.quietState.start;
        quietHoursPayload.end = this.quietState.end;
        quietHoursPayload.timezone = this.quietState.timezone;
        quietHoursPayload.behavior = this.quietState.behavior ?? "queue";
      }

      rawConfig.defaults = { ...existingDefaults, quiet_hours: quietHoursPayload };

      saveConfig(rawConfig as unknown as HitlConfig, this.configPath);
    } catch {
      // Non-fatal — continue without persisting
    }
  }

  // ---------------------------------------------------------------------------
  // Telegram inbound message handling
  // ---------------------------------------------------------------------------

  private handleTelegramMessage(raw: unknown): void {
    const msg = raw as {
      message_id?: number;
      chat?: { id?: number };
      text?: string;
    };

    // Filter to bound chat only
    if (msg.chat?.id !== this.opts.chatId) return;

    const text = msg.text ?? "";

    if (text.startsWith("/status")) {
      void this.handleStatusCommand();
    } else if (text.startsWith("/quiet")) {
      void this.handleQuietCommand();
    } else if (text.startsWith("/help")) {
      void this.bot.sendMessage(this.opts.chatId, formatHelpMessage());
    } else {
      // Free-text response — route to most recent pending request (LIFO)
      void this.handleFreeTextResponse(text);
    }
  }

  private handleCallbackQuery(raw: unknown): void {
    const query = raw as {
      id?: string;
      data?: string;
      message?: { message_id?: number; chat?: { id?: number } };
    };

    if (!query.data || !query.message) return;
    if (query.message.chat?.id !== this.opts.chatId) return;

    const data = query.data;
    const queryId = query.id ?? "";

    // Acknowledge the callback immediately so Telegram removes the spinner
    void this.bot.answerCallbackQuery(queryId);

    if (data.startsWith("status:")) {
      const sessionId = data.slice("status:".length);
      void this.handleStatusDrillDown(sessionId);
      return;
    }

    if (data.startsWith("quiet:")) {
      const action = data.slice("quiet:".length);
      void this.handleQuietToggle(action);
      return;
    }

    // Otherwise: requestId:index (button tap for a pending ask)
    const lastColon = data.lastIndexOf(":");
    if (lastColon === -1) return;
    const requestId = data.slice(0, lastColon);
    const indexStr = data.slice(lastColon + 1);
    const selectedIndex = parseInt(indexStr, 10);

    const entry = this.pending.get(requestId);
    if (!entry) return;

    const optionText =
      entry.options && !isNaN(selectedIndex)
        ? (entry.options[selectedIndex]?.text ?? indexStr)
        : indexStr;

    // Edit the original message to show the selection and remove buttons
    if (entry.messageId && entry.originalText) {
      const updatedText = `${entry.originalText}\n\n✅ ${optionText}`;
      void this.bot.editMessageText(updatedText, {
        chat_id: this.opts.chatId,
        message_id: entry.messageId,
      }).catch(() => {
        // Best effort — message may have been deleted
      });
    }

    this.resolvePendingRequest(requestId, entry, {
      text: optionText,
      selectedIndex: isNaN(selectedIndex) ? undefined : selectedIndex,
      isButtonTap: true,
    });
  }

  private async handleFreeTextResponse(text: string): Promise<void> {
    if (this.pending.size === 0) {
      await this.bot.sendMessage(
        this.opts.chatId,
        "No active Claude sessions. Your message wasn't delivered."
      );
      return;
    }

    // LIFO: take the most recently added pending request
    const entries = Array.from(this.pending.entries());
    const [requestId, entry] = entries[entries.length - 1];

    this.resolvePendingRequest(requestId, entry, {
      text,
      selectedIndex: undefined,
      isButtonTap: false,
    });
  }

  // ---------------------------------------------------------------------------
  // Pending request resolution
  // ---------------------------------------------------------------------------

  private resolvePendingRequest(
    requestId: string,
    entry: PendingEntry,
    response: { text: string; selectedIndex?: number; isButtonTap: boolean }
  ): void {
    if (entry.timeoutHandle !== null) clearTimeout(entry.timeoutHandle);
    this.pending.delete(requestId);

    this.ipc.sendToSession(entry.sessionId, {
      type: "response",
      requestId,
      text: response.text,
      selectedIndex: response.selectedIndex,
      isButtonTap: response.isButtonTap,
    });
  }

  // ---------------------------------------------------------------------------
  // IPC message routing
  // ---------------------------------------------------------------------------

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
        // Other message types (register/deregister/configure) handled by IpcServer
        break;
    }
  }

  private async handleAskMessage(
    session: SessionInfo,
    msg: AskMessage
  ): Promise<void> {
    const priorityLabel = this.priorityEngine.formatPriorityLabel(msg.priority);
    const prefix = `[${session.project}]`;
    const fullText = `${prefix} ${priorityLabel}\n\n${msg.message}`;

    // Build inline keyboard options
    const sendOpts: Record<string, unknown> = { parse_mode: "Markdown" };
    if (msg.options && msg.options.length > 0) {
      sendOpts.reply_markup = {
        inline_keyboard: msg.options.map((opt, i) => [
          {
            text: opt.isDefault ? `${opt.text} ⭐` : opt.text,
            callback_data: `${msg.requestId}:${i}`,
          },
        ]),
      };
    }

    const sent = await this.bot.sendMessage(
      this.opts.chatId,
      fullText,
      sendOpts
    );

    // Determine timeout
    const timeoutMs = this.priorityEngine.getTimeoutMs(
      msg.priority,
      msg.timeoutMinutes
    );

    let timeoutHandle: ReturnType<typeof setTimeout> | null = null;
    if (timeoutMs !== null) {
      timeoutHandle = setTimeout(() => {
        const entry = this.pending.get(msg.requestId);
        if (!entry) return;
        this.pending.delete(msg.requestId);
        this.ipc.sendToSession(entry.sessionId, {
          type: "timeout",
          requestId: msg.requestId,
          defaultIndex: entry.defaultIndex,
        });
      }, timeoutMs);
    }

    const defaultIndex =
      msg.options?.findIndex((o) => o.isDefault) ?? undefined;

    this.pending.set(msg.requestId, {
      sessionId: session.sessionId,
      timeoutHandle,
      createdAt: Date.now(),
      options: msg.options,
      defaultIndex: defaultIndex !== undefined && defaultIndex >= 0 ? defaultIndex : msg.defaultIndex,
      messageId: sent.message_id,
      originalText: fullText,
    });

    // Suppress unused-variable warning — message_id tracked for future use
    void sent.message_id;
  }

  private async handleNotifyMessage(
    session: SessionInfo,
    msg: NotifyMessage
  ): Promise<void> {
    const prefix = `[${session.project}]`;
    const fullText = `${prefix} ${msg.message}`;

    const sent = await this.bot.sendMessage(this.opts.chatId, fullText, {
      parse_mode: "Markdown",
      disable_notification: msg.silent ?? false,
    });

    this.ipc.sendToSession(session.sessionId, {
      type: "notified",
      requestId: msg.requestId,
      messageId: String(sent.message_id),
    });
  }

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

    // Respect quiet hours: still deliver (permission prompts are time-sensitive)
    // but silence the notification sound so it doesn't buzz during quiet hours.
    const silent = this.quietState.enabled;

    await this.bot.sendMessage(this.opts.chatId, fullText, {
      disable_notification: silent,
    });
  }

  // ---------------------------------------------------------------------------
  // Command handlers
  // ---------------------------------------------------------------------------

  private async handleStatusCommand(): Promise<void> {
    const sessions = this.ipc.getSessions();
    const disconnected = this.ipc.getDisconnectedSessions();

    const statusSessions: StatusSession[] = sessions.map((s) => {
      // Count pending requests belonging to this session
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
        lastActivityTool: s.lastActivityTool,
        blockedOn: s.blockedOn,
        blockedAge: s.blockedAt
          ? (now - s.blockedAt.getTime()) / 1000
          : undefined,
      };
    });

    const disconnectedInfos: DisconnectedInfo[] = disconnected.map((d) => ({
      project: d.project,
      lastSeen: d.lastSeenAt,
    }));

    const result = formatStatusMessage(statusSessions, disconnectedInfos);

    const sendOpts: Record<string, unknown> = { parse_mode: "Markdown" };
    if (result.buttons && result.buttons.length > 0) {
      sendOpts.reply_markup = {
        inline_keyboard: result.buttons.map((btn) => [
          { text: btn.text, callback_data: btn.callbackData },
        ]),
      };
    }

    await this.bot.sendMessage(this.opts.chatId, result.text, sendOpts);
  }

  private async handleStatusDrillDown(sessionId: string): Promise<void> {
    const sessions = this.ipc.getSessions();
    const session = sessions.find((s) => s.sessionId === sessionId);

    if (!session) {
      await this.bot.sendMessage(
        this.opts.chatId,
        "Session not found or disconnected."
      );
      return;
    }

    let pendingCount = 0;
    let oldestPendingAge: number | undefined;
    const now = Date.now();

    for (const entry of this.pending.values()) {
      if (entry.sessionId === sessionId) {
        pendingCount++;
        const ageSeconds = (now - entry.createdAt) / 1000;
        if (oldestPendingAge === undefined || ageSeconds > oldestPendingAge) {
          oldestPendingAge = ageSeconds;
        }
      }
    }

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
      lastActivityTool: session.lastActivityTool,
      blockedOn: session.blockedOn,
      blockedAge: session.blockedAt
        ? (now - session.blockedAt.getTime()) / 1000
        : undefined,
    };

    const detail = formatSessionDetail(statusSession);
    await this.bot.sendMessage(this.opts.chatId, detail, {
      parse_mode: "Markdown",
    });
  }

  private async handleQuietCommand(): Promise<void> {
    const result = formatQuietStatus(this.quietState);
    const sendOpts: Record<string, unknown> = {};
    if (result.buttons.length > 0) {
      sendOpts.reply_markup = {
        inline_keyboard: result.buttons.map((btn) => [
          { text: btn.text, callback_data: btn.callbackData },
        ]),
      };
    }
    await this.bot.sendMessage(this.opts.chatId, result.text, sendOpts);
  }

  private async handleQuietToggle(action: string): Promise<void> {
    const newState = handleQuietAction(action, this.quietState);
    this.quietState = newState;
    this.persistQuietState();

    // Broadcast to all connected sessions
    this.ipc.broadcastAll({
      type: "quiet_hours_changed",
      quietHours: {
        enabled: newState.enabled,
        manual: newState.manual,
        start: newState.start,
        end: newState.end,
        timezone: newState.timezone,
        behavior: newState.behavior,
      },
    });

    // Show updated quiet status
    await this.handleQuietCommand();
  }

  // ---------------------------------------------------------------------------
  // Accessors (useful in tests)
  // ---------------------------------------------------------------------------

  getPendingCount(): number {
    return this.pending.size;
  }

  getIpcServer(): IpcServer {
    return this.ipc;
  }
}

// ---------------------------------------------------------------------------
// Daemon entrypoint
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const configDir = HITL_CONFIG_DIR;
  const configPath = `${configDir}/config.json`;

  const config = loadConfig(configPath);
  if (!config) {
    throw new Error(`Config not found at ${configPath}. Run setup first.`);
  }
  if (!config.telegram?.bot_token) {
    throw new Error("Config missing telegram.bot_token");
  }
  if (!config.telegram?.chat_id) {
    throw new Error("Config missing telegram.chat_id");
  }

  const botToken = resolveEnvValue(config.telegram.bot_token);
  const chatId = config.telegram.chat_id;
  const socketPath = `${configDir}/sock`;

  // Dynamically import node-telegram-bot-api to avoid issues in test environments
  const { default: TelegramBotImpl } = await import("node-telegram-bot-api");
  const telegramBot = new TelegramBotImpl(botToken, { polling: true });

  const listener = new Listener({
    configDir,
    socketPath,
    telegramBot,
    chatId,
  });

  await listener.start();

  // Write PID file
  const pidPath = `${configDir}/listener.pid`;
  fs.writeFileSync(pidPath, String(process.pid), "utf-8");

  console.error(`[listener] Started, PID ${process.pid}`);

  const shutdown = async (): Promise<void> => {
    await listener.stop();
    try {
      fs.unlinkSync(pidPath);
    } catch {
      // Best effort
    }
    process.exit(0);
  };

  process.on("SIGTERM", () => {
    void shutdown();
  });
  process.on("SIGINT", () => {
    void shutdown();
  });
}

// Only run as daemon when invoked directly (not when imported by tests)
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error("[listener] Fatal error:", err);
    process.exit(1);
  });
}
