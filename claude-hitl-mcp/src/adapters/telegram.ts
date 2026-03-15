import TelegramBot from "node-telegram-bot-api";
import type {
  ChatAdapter,
  AdapterConfig,
  UserBinding,
  MessageHandler,
  MessageLevel,
  Priority,
} from "../types.js";

const LEVEL_EMOJI: Record<MessageLevel, string> = {
  info: "📋",
  success: "✅",
  warning: "⚠️",
  error: "🚨",
};

export class TelegramAdapter implements ChatAdapter {
  readonly name = "telegram";
  readonly capabilities = {
    inlineButtons: true,
    threading: false,
    messageEditing: true,
    silentMessages: true,
    richFormatting: true,
  };

  private bot: TelegramBot | null = null;
  private chatId: string | null = null;
  private messageHandler: MessageHandler | null = null;

  // Exposed for testing: allows calling TelegramBot without `new` so vi.fn()
  // mocks with arrow-function implementations work under Vitest v4, which uses
  // Reflect.construct for constructor mocks (arrow fns are not constructable).
  // In production the class call without `new` throws, so the catch block applies.
  private makeBotInstance(token: string, opts: TelegramBot.ConstructorOptions): TelegramBot {
    type Factory = (t: string, o: TelegramBot.ConstructorOptions) => TelegramBot;
    try {
      return (TelegramBot as unknown as Factory)(token, opts);
    } catch {
      return new TelegramBot(token, opts);
    }
  }

  async connect(config: AdapterConfig): Promise<void> {
    this.bot = this.makeBotInstance(config.token, { polling: true });
    if (config.chatId) this.chatId = String(config.chatId);

    this.bot.on("message", (msg) => {
      if (this.chatId && String(msg.chat.id) !== this.chatId) return;
      if (!this.messageHandler) return;

      this.messageHandler({
        text: msg.text ?? "",
        messageId: String(msg.message_id),
        isButtonTap: false,
        replyToMessageId: msg.reply_to_message
          ? String(msg.reply_to_message.message_id)
          : undefined,
      });
    });

    this.bot.on("callback_query", (query) => {
      if (!query.data || !query.message) return;
      if (this.chatId && String(query.message.chat.id) !== this.chatId) return;
      if (!this.messageHandler) return;

      // Parse callback data: "requestId:index"
      const colonIndex = query.data.lastIndexOf(":");
      const requestId = query.data.slice(0, colonIndex);
      const indexStr = query.data.slice(colonIndex + 1);

      this.messageHandler({
        text: query.data,
        messageId: String(query.message.message_id),
        isButtonTap: true,
        selectedIndex: parseInt(indexStr, 10),
        callbackData: requestId,
      });

      // Acknowledge the callback to remove loading state
      this.bot?.answerCallbackQuery(query.id).catch(() => {});
    });
  }

  async disconnect(): Promise<void> {
    if (this.bot) {
      await this.bot.stopPolling();
      this.bot = null;
    }
  }

  isConnected(): boolean {
    return this.bot !== null && this.bot.isPolling();
  }

  async awaitBinding(): Promise<UserBinding> {
    if (!this.bot) throw new Error("Bot not connected");

    return new Promise((resolve) => {
      const handler = (msg: TelegramBot.Message) => {
        if (msg.text === "/start") {
          this.chatId = String(msg.chat.id);
          this.bot?.removeListener("message", handler);
          resolve({
            userId: String(msg.from?.id ?? msg.chat.id),
            displayName:
              msg.from?.first_name ??
              (msg.chat as TelegramBot.Chat & { first_name?: string }).first_name ??
              "Unknown",
            chatId: String(msg.chat.id),
          });
        }
      };
      this.bot!.on("message", handler);
    });
  }

  async sendMessage(params: {
    text: string;
    level?: MessageLevel;
    silent?: boolean;
  }): Promise<{ messageId: string }> {
    if (!this.bot || !this.chatId) {
      throw new Error("Bot not connected or no chat ID");
    }

    const prefix = params.level ? `${LEVEL_EMOJI[params.level]} ` : "";
    const msg = await this.bot.sendMessage(
      this.chatId,
      `${prefix}${params.text}`,
      {
        parse_mode: "Markdown",
        disable_notification: params.silent ?? false,
      }
    );
    return { messageId: String(msg.message_id) };
  }

  async sendInteractiveMessage(params: {
    text: string;
    requestId: string;
    options?: Array<{ text: string; description?: string; isDefault?: boolean }>;
    context?: string;
    priority: Priority;
  }): Promise<{ messageId: string }> {
    if (!this.bot || !this.chatId) {
      throw new Error("Bot not connected or no chat ID");
    }

    let fullText = params.text;
    if (params.context) {
      fullText += `\n\n_Context:_ ${params.context}`;
    }

    const opts: TelegramBot.SendMessageOptions = {
      parse_mode: "Markdown",
    };

    if (params.options && params.options.length > 0) {
      // One button per row for mobile-friendly layout
      opts.reply_markup = {
        inline_keyboard: params.options.map((opt, i) => [
          {
            text: opt.isDefault ? `${opt.text} ⭐` : opt.text,
            callback_data: `${params.requestId}:${i}`,
          },
        ]),
      };
    }

    const msg = await this.bot.sendMessage(this.chatId, fullText, opts);
    return { messageId: String(msg.message_id) };
  }

  async editMessage(params: {
    messageId: string;
    text: string;
  }): Promise<void> {
    if (!this.bot || !this.chatId) {
      throw new Error("Bot not connected or no chat ID");
    }
    await this.bot.editMessageText(params.text, {
      chat_id: this.chatId,
      message_id: parseInt(params.messageId, 10),
      parse_mode: "Markdown",
    });
  }

  onMessage(handler: MessageHandler): void {
    this.messageHandler = handler;
  }
}
