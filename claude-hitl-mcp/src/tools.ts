import type {
  ChatAdapter,
  AskHumanInput,
  AskHumanResponse,
  NotifyHumanInput,
  NotifyHumanResponse,
  ConfigureHitlInput,
  ConfigureHitlResponse,
  InboundMessage,
} from "./types.js";
import { PriorityEngine } from "./priority-engine.js";
import { SessionManager } from "./session-manager.js";

export class HitlToolHandler {
  private adapter: ChatAdapter;
  private engine: PriorityEngine;
  private session: SessionManager;
  private sessionContext: string = "";
  private messageIdMap: Map<string, string> = new Map(); // requestId → messageId
  private reminderTimers: Map<string, ReturnType<typeof setInterval>> = new Map();

  constructor(adapter: ChatAdapter) {
    this.adapter = adapter;
    this.engine = new PriorityEngine();
    this.session = new SessionManager(this.engine);

    this.adapter.onMessage((msg: InboundMessage) => {
      this.session.routeResponse(msg);
    });
  }

  async notifyHuman(input: NotifyHumanInput): Promise<NotifyHumanResponse> {
    try {
      const result = await this.adapter.sendMessage({
        text: this.prefixContext(input.message),
        level: input.level,
        silent: input.silent,
      });
      return { status: "sent", message_id: result.messageId };
    } catch {
      return { status: "error", message_id: "" };
    }
  }

  async askHuman(input: AskHumanInput): Promise<AskHumanResponse> {
    const timeoutMs = this.engine.getTimeoutMs(input.priority, input.timeout_minutes);

    // Check quiet hours — auto-resolve if applicable
    if (this.engine.isQuietHours() && this.engine.shouldAutoResolve(input.priority)) {
      const action = this.engine.getTimeoutAction(input.priority, input.options);
      return {
        status: "timed_out",
        response: action.response,
        selected_option: action.selectedIndex,
        response_time_seconds: 0,
        priority: input.priority,
        timed_out_action: action.action,
      };
    }

    const { requestId, promise } = this.session.createRequest(
      input.priority,
      timeoutMs,
      input.options
    );

    const label = this.session.getRequestLabel(requestId);
    const priorityLabel = this.engine.formatPriorityLabel(input.priority);
    const messageText = `${priorityLabel}\n${label}: ${this.prefixContext(input.message)}`;

    try {
      const { messageId } = await this.adapter.sendInteractiveMessage({
        text: messageText,
        requestId,
        options: input.options?.map((o) => ({
          text: o.text,
          description: o.description,
          isDefault: o.default,
        })),
        context: input.context,
        priority: input.priority,
      });
      this.session.setMessageId(requestId, messageId);
      this.messageIdMap.set(requestId, messageId);

      // Set up reminder pings for critical
      const reminderMs = this.engine.getReminderIntervalMs(input.priority);
      if (reminderMs) {
        this.startReminders(requestId, messageText, reminderMs);
      }
    } catch (err) {
      return {
        status: "error",
        response: `Failed to send message: ${err}`,
        response_time_seconds: 0,
        priority: input.priority,
        timed_out_action: null,
      };
    }

    const result = await promise;

    // Update the original message with confirmation
    const sentMessageId = this.messageIdMap.get(requestId);
    if (sentMessageId && this.adapter.capabilities.messageEditing) {
      try {
        if (result.status === "answered") {
          await this.adapter.editMessage({
            messageId: sentMessageId,
            text: `${messageText}\n\nGot it — continuing with: ${result.response}`,
          });
        } else if (result.status === "timed_out") {
          const action =
            result.timed_out_action === "used_default"
              ? `used default: ${result.response}`
              : "paused";
          await this.adapter.editMessage({
            messageId: sentMessageId,
            text: `${messageText}\n\nTimed out — ${action}`,
          });
        }
      } catch {
        // Best effort — don't fail the response if edit fails
      }
      this.messageIdMap.delete(requestId);
    }

    return result;
  }

  async configureHitl(input: ConfigureHitlInput): Promise<ConfigureHitlResponse> {
    if (input.session_context !== undefined) {
      this.sessionContext = input.session_context;
    }

    if (input.timeout_overrides) {
      this.engine.setTimeoutOverrides({
        architecture: input.timeout_overrides.architecture,
        preference: input.timeout_overrides.preference,
      });
    }

    // Propagate to listener daemon if using IPC adapter
    if ('sendConfigure' in this.adapter) {
      (this.adapter as { sendConfigure: (ctx?: string, overrides?: { architecture?: number; preference?: number }) => void })
        .sendConfigure(this.sessionContext || undefined, input.timeout_overrides);
    }

    const archTimeout = this.engine.getTimeoutMs("architecture");
    const prefTimeout = this.engine.getTimeoutMs("preference");

    return {
      status: "configured",
      active_config: {
        adapter: this.adapter.name,
        session_context: this.sessionContext,
        timeouts: {
          critical: null,
          architecture: archTimeout ? archTimeout / 60000 : 120,
          preference: prefTimeout ? prefTimeout / 60000 : 30,
        },
      },
    };
  }

  private prefixContext(message: string): string {
    if (this.sessionContext) {
      return `_${this.sessionContext}_\n\n${message}`;
    }
    return message;
  }

  private startReminders(requestId: string, text: string, intervalMs: number): void {
    const timer = setInterval(async () => {
      if (!this.session.isRequestPending(requestId)) {
        clearInterval(timer);
        this.reminderTimers.delete(requestId);
        return;
      }
      try {
        await this.adapter.sendMessage({
          text: `Reminder: Still waiting for your response\n\n${text}`,
        });
      } catch {
        // Best effort
      }
    }, intervalMs);
    this.reminderTimers.set(requestId, timer);
  }
}
