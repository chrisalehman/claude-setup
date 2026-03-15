/**
 * Mock Telegram bot for use in listener tests.
 *
 * Simulates the subset of node-telegram-bot-api that the Listener uses directly:
 *   - sendMessage
 *   - answerCallbackQuery
 *   - on / off for event registration
 *   - simulateMessage / simulateCallbackQuery for test control
 */

export interface SentMessage {
  chatId: number | string;
  text: string;
  options?: Record<string, unknown>;
}

export interface MockBot {
  /** All messages sent via sendMessage */
  sentMessages: SentMessage[];
  /** All callback query IDs acknowledged via answerCallbackQuery */
  answeredCallbacks: string[];

  // Bot API surface used by Listener
  sendMessage(
    chatId: number | string,
    text: string,
    options?: Record<string, unknown>
  ): Promise<{ message_id: number }>;
  answerCallbackQuery(queryId: string): Promise<void>;
  on(event: string, handler: (...args: unknown[]) => void): void;
  off(event: string, handler: (...args: unknown[]) => void): void;

  // Test helpers
  simulateMessage(text: string): void;
  simulateCallbackQuery(data: string, messageId?: number): void;
}

export function createMockBot(chatId: number = 12345): MockBot {
  let messageIdCounter = 100;
  const handlers = new Map<string, Array<(...args: unknown[]) => void>>();

  const bot: MockBot = {
    sentMessages: [],
    answeredCallbacks: [],

    sendMessage(
      cId: number | string,
      text: string,
      options?: Record<string, unknown>
    ): Promise<{ message_id: number }> {
      bot.sentMessages.push({ chatId: cId, text, options });
      return Promise.resolve({ message_id: messageIdCounter++ });
    },

    answerCallbackQuery(queryId: string): Promise<void> {
      bot.answeredCallbacks.push(queryId);
      return Promise.resolve();
    },

    on(event: string, handler: (...args: unknown[]) => void): void {
      const list = handlers.get(event) ?? [];
      list.push(handler);
      handlers.set(event, list);
    },

    off(event: string, handler: (...args: unknown[]) => void): void {
      const list = handlers.get(event) ?? [];
      handlers.set(
        event,
        list.filter((h) => h !== handler)
      );
    },

    simulateMessage(text: string): void {
      const list = handlers.get("message") ?? [];
      const msg = {
        message_id: messageIdCounter++,
        chat: { id: chatId },
        text,
      };
      for (const h of list) h(msg);
    },

    simulateCallbackQuery(data: string, messageId: number = 42): void {
      const list = handlers.get("callback_query") ?? [];
      const query = {
        id: `cbq-${messageIdCounter++}`,
        data,
        message: {
          message_id: messageId,
          chat: { id: chatId },
        },
      };
      for (const h of list) h(query);
    },
  };

  return bot;
}
