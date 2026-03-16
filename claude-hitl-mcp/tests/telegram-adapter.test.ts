import { describe, it, expect, vi, beforeEach } from "vitest";
import { TelegramAdapter } from "../src/adapters/telegram.js";

// Mock node-telegram-bot-api
let mockBot: any;
vi.mock("node-telegram-bot-api", () => {
  return {
    default: vi.fn(() => {
      mockBot = {
        on: vi.fn(),
        removeListener: vi.fn(),
        sendMessage: vi.fn().mockResolvedValue({ message_id: 123 }),
        editMessageText: vi.fn().mockResolvedValue(true),
        answerCallbackQuery: vi.fn().mockResolvedValue(true),
        stopPolling: vi.fn().mockResolvedValue(undefined),
        isPolling: vi.fn().mockReturnValue(true),
      };
      return mockBot;
    }),
  };
});

describe("TelegramAdapter", () => {
  let adapter: TelegramAdapter;

  beforeEach(() => {
    adapter = new TelegramAdapter();
  });

  describe("capabilities", () => {
    it("declares correct capabilities", () => {
      expect(adapter.capabilities.inlineButtons).toBe(true);
      expect(adapter.capabilities.threading).toBe(false);
      expect(adapter.capabilities.messageEditing).toBe(true);
      expect(adapter.capabilities.silentMessages).toBe(true);
      expect(adapter.capabilities.richFormatting).toBe(true);
    });

    it("has name 'telegram'", () => {
      expect(adapter.name).toBe("telegram");
    });
  });

  describe("connect/disconnect", () => {
    it("connects with token and starts polling", async () => {
      await adapter.connect({ token: "test-token" });
      expect(adapter.isConnected()).toBe(true);
    });

    it("disconnects and stops polling", async () => {
      await adapter.connect({ token: "test-token" });
      await adapter.disconnect();
      expect(adapter.isConnected()).toBe(false);
    });
  });

  describe("sendMessage", () => {
    it("sends a message with level emoji prefix and correct args", async () => {
      await adapter.connect({ token: "test-token", chatId: "12345" });
      const result = await adapter.sendMessage({
        text: "Hello world",
        level: "success",
        silent: true,
      });
      expect(result.messageId).toBe("123");
      expect(mockBot.sendMessage).toHaveBeenCalledWith(
        "12345",
        "✅ Hello world",
        { disable_notification: true }
      );
    });

    it("throws when not connected", async () => {
      await expect(adapter.sendMessage({ text: "test" })).rejects.toThrow();
    });
  });

  describe("sendInteractiveMessage", () => {
    it("sends message with inline keyboard (one button per row for mobile)", async () => {
      await adapter.connect({ token: "test-token", chatId: "12345" });
      const result = await adapter.sendInteractiveMessage({
        text: "Pick one",
        requestId: "req-1",
        options: [
          { text: "A", isDefault: true },
          { text: "B" },
        ],
        priority: "preference",
      });
      expect(result.messageId).toBe("123");
      // Verify inline keyboard has one button per row
      const callArgs = mockBot.sendMessage.mock.calls[0];
      const keyboard = callArgs[2].reply_markup.inline_keyboard;
      expect(keyboard).toHaveLength(2); // 2 rows, 1 button each
      expect(keyboard[0][0].text).toBe("A ⭐");
      expect(keyboard[0][0].callback_data).toBe("req-1:0");
      expect(keyboard[1][0].text).toBe("B");
    });
  });

  describe("editMessage", () => {
    it("edits an existing message", async () => {
      await adapter.connect({ token: "test-token", chatId: "12345" });
      await adapter.editMessage({ messageId: "123", text: "Updated" });
      expect(mockBot.editMessageText).toHaveBeenCalledWith("Updated", {
        chat_id: "12345",
        message_id: 123,
      });
    });
  });

  describe("onMessage / callback routing", () => {
    it("routes regular messages to handler with chat_id lockdown", async () => {
      await adapter.connect({ token: "test-token", chatId: "12345" });
      const handler = vi.fn();
      adapter.onMessage(handler);

      const messageListener = mockBot.on.mock.calls.find(
        (c: any[]) => c[0] === "message"
      )[1];

      // Message from bound chat — should be delivered
      messageListener({ chat: { id: 12345 }, message_id: 1, text: "hello" });
      expect(handler).toHaveBeenCalledTimes(1);
      expect(handler.mock.calls[0][0].text).toBe("hello");

      // Message from different chat — should be ignored
      messageListener({ chat: { id: 99999 }, message_id: 2, text: "intruder" });
      expect(handler).toHaveBeenCalledTimes(1); // still 1
    });

    it("routes callback queries with parsed requestId and index", async () => {
      await adapter.connect({ token: "test-token", chatId: "12345" });
      const handler = vi.fn();
      adapter.onMessage(handler);

      const callbackListener = mockBot.on.mock.calls.find(
        (c: any[]) => c[0] === "callback_query"
      )[1];

      callbackListener({
        id: "cb-1",
        data: "req-5:1",
        message: { chat: { id: 12345 }, message_id: 42 },
      });

      expect(handler).toHaveBeenCalledWith({
        text: "req-5:1",
        messageId: "42",
        isButtonTap: true,
        selectedIndex: 1,
        callbackData: "req-5",
      });
      expect(mockBot.answerCallbackQuery).toHaveBeenCalledWith("cb-1");
    });
  });
});
