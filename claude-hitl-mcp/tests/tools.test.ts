import { describe, it, expect, vi, beforeEach } from "vitest";
import { HitlToolHandler } from "../src/tools.js";
import type { ChatAdapter, AdapterConfig } from "../src/types.js";

function createMockAdapter(): ChatAdapter {
  return {
    name: "mock",
    capabilities: {
      inlineButtons: true,
      threading: false,
      messageEditing: true,
      silentMessages: true,
      richFormatting: true,
    },
    connect: vi.fn().mockResolvedValue(undefined),
    disconnect: vi.fn().mockResolvedValue(undefined),
    isConnected: vi.fn().mockReturnValue(true),
    awaitBinding: vi.fn().mockResolvedValue({
      userId: "u1",
      displayName: "Test",
      chatId: "c1",
    }),
    sendMessage: vi.fn().mockResolvedValue({ messageId: "m1" }),
    sendInteractiveMessage: vi.fn().mockResolvedValue({ messageId: "m2" }),
    editMessage: vi.fn().mockResolvedValue(undefined),
    onMessage: vi.fn(),
  };
}

describe("HitlToolHandler", () => {
  let handler: HitlToolHandler;
  let adapter: ChatAdapter;

  beforeEach(() => {
    adapter = createMockAdapter();
    handler = new HitlToolHandler(adapter);
  });

  describe("notify_human", () => {
    it("sends a message via adapter and returns immediately", async () => {
      const result = await handler.notifyHuman({
        message: "Build complete",
        level: "success",
      });
      expect(result.status).toBe("sent");
      expect(result.message_id).toBe("m1");
      expect(adapter.sendMessage).toHaveBeenCalledWith({
        text: "Build complete",
        level: "success",
        silent: undefined,
      });
    });
  });

  describe("configure_hitl", () => {
    it("applies session context and returns merged config", async () => {
      const result = await handler.configureHitl({
        session_context: "Working on auth",
        timeout_overrides: { architecture: 60 },
      });
      expect(result.status).toBe("configured");
      expect(result.active_config.session_context).toBe("Working on auth");
      expect(result.active_config.timeouts.architecture).toBe(60);
    });
  });

  describe("ask_human", () => {
    it("sends interactive message and resolves on adapter response", async () => {
      // Set up the adapter to capture the onMessage handler
      let capturedHandler: any;
      (adapter.onMessage as any).mockImplementation((h: any) => {
        capturedHandler = h;
      });
      handler = new HitlToolHandler(adapter);

      const askPromise = handler.askHuman({
        message: "Redis or Postgres?",
        priority: "preference",
        options: [
          { text: "Redis", default: true },
          { text: "Postgres" },
        ],
        timeout_minutes: 1,
      });

      // Simulate user tapping "Postgres" button
      await vi.waitFor(() => {
        expect(adapter.sendInteractiveMessage).toHaveBeenCalled();
      });
      const callArgs = (adapter.sendInteractiveMessage as any).mock.calls[0][0];
      const requestId = callArgs.requestId;

      capturedHandler({
        text: "Postgres",
        messageId: "m2",
        isButtonTap: true,
        selectedIndex: 1,
        callbackData: requestId,
      });

      const result = await askPromise;
      expect(result.status).toBe("answered");
      expect(result.response).toBe("Postgres");
      expect(result.selected_option).toBe(1);
    });

    it("resolves free-text response when options were provided", async () => {
      let capturedHandler: any;
      (adapter.onMessage as any).mockImplementation((h: any) => {
        capturedHandler = h;
      });
      handler = new HitlToolHandler(adapter);

      const askPromise = handler.askHuman({
        message: "Redis or Postgres?",
        priority: "preference",
        options: [
          { text: "Redis", default: true },
          { text: "Postgres" },
        ],
        timeout_minutes: 1,
      });

      await vi.waitFor(() => {
        expect(adapter.sendInteractiveMessage).toHaveBeenCalled();
      });

      // Simulate user typing free text instead of tapping a button
      capturedHandler({
        text: "Actually use SQLite",
        messageId: "m3",
        isButtonTap: false,
      });

      const result = await askPromise;
      expect(result.status).toBe("answered");
      expect(result.response).toBe("Actually use SQLite");
      expect(result.selected_option).toBeNull();
    });
  });
});
