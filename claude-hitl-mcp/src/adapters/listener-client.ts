import * as crypto from "node:crypto";
import * as path from "node:path";
import { execSync } from "node:child_process";
import { IpcClient } from "../ipc/client.js";
import type {
  ChatAdapter,
  AdapterConfig,
  UserBinding,
  MessageHandler,
  MessageLevel,
  Priority,
  InboundMessage,
} from "../types.js";
import type { QuietHoursChangedMessage } from "../ipc/protocol.js";

type QuietHoursPayload = QuietHoursChangedMessage["quietHours"];
type QuietHoursHandler = (quietHours: QuietHoursPayload) => void;

/** Derive a project name from the git repository root or fall back to cwd. */
function resolveProjectName(): string {
  try {
    const root = execSync("git rev-parse --show-toplevel", {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return path.basename(root);
  } catch {
    return path.basename(process.cwd());
  }
}

/**
 * ChatAdapter that routes messages through the listener daemon via IPC.
 *
 * Used in place of TelegramAdapter when a listener is running. The listener
 * owns the Telegram bot; this adapter only forwards requests over the Unix
 * socket and translates IPC responses back into InboundMessage form.
 */
export class ListenerClientAdapter implements ChatAdapter {
  readonly name = "listener-client";
  readonly capabilities = {
    inlineButtons: true,
    threading: false,
    messageEditing: true,
    silentMessages: true,
    richFormatting: true,
  };

  private readonly socketPath: string;
  private client: IpcClient | null = null;
  private messageHandler: MessageHandler | null = null;
  private quietHoursHandler: QuietHoursHandler | null = null;
  private notifCounter = 0;

  /** Pending notified-ack callbacks keyed by requestId. */
  private pendingNotified: Map<string, (messageId: string) => void> = new Map();

  constructor(socketPath: string) {
    this.socketPath = socketPath;
  }

  async connect(config: AdapterConfig): Promise<void> {
    // config.chatId is not used — the listener owns the bot and the chat
    void config;

    const sessionId = crypto.randomUUID();
    const project = resolveProjectName();
    const cwd = process.cwd();

    const client = new IpcClient(this.socketPath);

    client.onMessage((msg) => {
      if (msg.type === "notified") {
        const resolve = this.pendingNotified.get(msg.requestId);
        if (resolve) {
          this.pendingNotified.delete(msg.requestId);
          resolve(msg.messageId);
        }
        return;
      }

      if (msg.type === "response") {
        if (this.messageHandler) {
          const inbound: InboundMessage = {
            text: msg.text,
            messageId: msg.requestId,
            isButtonTap: msg.isButtonTap,
            ...(msg.selectedIndex !== undefined
              ? { selectedIndex: msg.selectedIndex }
              : {}),
            callbackData: msg.requestId,
          };
          this.messageHandler(inbound);
        }
        return;
      }

      if (msg.type === "quiet_hours_changed") {
        if (this.quietHoursHandler) {
          this.quietHoursHandler(msg.quietHours);
        }
        return;
      }

      // All other server messages (timeout, shutdown, error, registered) are
      // handled by the IpcClient itself or intentionally ignored here.
    });

    await client.connect(sessionId, project, cwd);
    this.client = client;
  }

  async disconnect(): Promise<void> {
    if (this.client) {
      await this.client.disconnect();
      this.client = null;
    }
  }

  isConnected(): boolean {
    return this.client?.isConnected() ?? false;
  }

  async awaitBinding(): Promise<UserBinding> {
    throw new Error(
      "ListenerClientAdapter does not support awaitBinding — " +
        "binding is handled by the listener daemon during setup."
    );
  }

  async sendMessage(params: {
    text: string;
    level?: MessageLevel;
    silent?: boolean;
  }): Promise<{ messageId: string }> {
    if (!this.client || !this.client.isConnected()) {
      throw new Error("ListenerClientAdapter is not connected");
    }

    const requestId = `notif_${this.notifCounter++}`;

    const messageId = await new Promise<string>((resolve, reject) => {
      this.pendingNotified.set(requestId, resolve);

      // Set a generous timeout to avoid leaking the pending entry
      const timer = setTimeout(() => {
        this.pendingNotified.delete(requestId);
        reject(new Error(`Timed out waiting for notified ack (requestId=${requestId})`));
      }, 30_000);

      // Ensure the timer does not prevent process exit
      timer.unref?.();

      try {
        this.client!.sendNotify(requestId, params.text, params.level, params.silent);
      } catch (err) {
        clearTimeout(timer);
        this.pendingNotified.delete(requestId);
        reject(err);
      }
    });

    return { messageId };
  }

  async sendInteractiveMessage(params: {
    text: string;
    requestId: string;
    options?: Array<{ text: string; description?: string; isDefault?: boolean }>;
    context?: string;
    priority: Priority;
  }): Promise<{ messageId: string }> {
    if (!this.client || !this.client.isConnected()) {
      throw new Error("ListenerClientAdapter is not connected");
    }

    // Determine defaultIndex from options
    const defaultIndex = params.options?.findIndex((o) => o.isDefault);

    this.client.sendAsk(
      params.requestId,
      params.text,
      params.priority,
      params.options,
      defaultIndex !== undefined && defaultIndex >= 0 ? defaultIndex : undefined,
      undefined,
      params.context,
    );

    // The adapter does NOT wait for the response — response routing goes through
    // the onMessage handler, matching the TelegramAdapter pattern.
    return { messageId: params.requestId };
  }

  async editMessage(_params: { messageId: string; text: string }): Promise<void> {
    // No-op: message editing on the Telegram side is handled by the listener.
  }

  onMessage(handler: MessageHandler): void {
    this.messageHandler = handler;
  }

  /**
   * Register a handler for quiet_hours_changed IPC messages.
   * Not part of ChatAdapter; callers that care about quiet hours can call this.
   */
  onQuietHoursChanged(handler: QuietHoursHandler): void {
    this.quietHoursHandler = handler;
  }

  /**
   * Propagate configure_hitl settings to the listener daemon over IPC.
   * Not part of ChatAdapter; called by HitlToolHandler when it detects this adapter.
   */
  sendConfigure(
    sessionContext?: string,
    timeoutOverrides?: { architecture?: number; preference?: number }
  ): void {
    if (!this.client || !this.client.isConnected()) return;
    this.client.sendConfigure(sessionContext, timeoutOverrides);
  }
}
