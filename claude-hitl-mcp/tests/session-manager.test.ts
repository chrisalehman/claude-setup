import { describe, it, expect, vi, beforeEach } from "vitest";
import { SessionManager } from "../src/session-manager.js";
import type { AskHumanResponse } from "../src/types.js";

describe("SessionManager", () => {
  let manager: SessionManager;

  beforeEach(() => {
    manager = new SessionManager();
  });

  describe("request tracking", () => {
    it("creates a pending request with unique ID", () => {
      const { requestId, promise } = manager.createRequest("preference", null, [
        { text: "A" },
      ]);
      expect(requestId).toMatch(/^req-/);
      expect(manager.getPendingCount()).toBe(1);
    });

    it("generates incrementing request labels", () => {
      const r1 = manager.createRequest("preference", null);
      const r2 = manager.createRequest("architecture", null);
      expect(manager.getRequestLabel(r1.requestId)).toBe("#1");
      expect(manager.getRequestLabel(r2.requestId)).toBe("#2");
    });
  });

  describe("response routing", () => {
    it("resolves pending request by requestId (button tap)", async () => {
      const { requestId, promise } = manager.createRequest("preference", null);
      manager.setMessageId(requestId, "msg-123");

      manager.routeResponse({
        text: "Option A",
        messageId: "msg-123",
        isButtonTap: true,
        selectedIndex: 0,
        callbackData: requestId,
      });

      const result = await promise;
      expect(result.status).toBe("answered");
      expect(result.response).toBe("Option A");
      expect(result.selected_option).toBe(0);
      expect(manager.getPendingCount()).toBe(0);
    });

    it("routes reply-to-message to matching request", async () => {
      const r1 = manager.createRequest("architecture", null);
      const r2 = manager.createRequest("preference", null);
      manager.setMessageId(r1.requestId, "msg-1");
      manager.setMessageId(r2.requestId, "msg-2");

      manager.routeResponse({
        text: "use Postgres",
        messageId: "msg-999",
        isButtonTap: false,
        replyToMessageId: "msg-1",
      });

      const result = await r1.promise;
      expect(result.status).toBe("answered");
      expect(result.response).toBe("use Postgres");
    });

    it("routes unprefixed free-text to most recent request (LIFO)", async () => {
      const r1 = manager.createRequest("architecture", null);
      const r2 = manager.createRequest("preference", null);
      manager.setMessageId(r1.requestId, "msg-1");
      manager.setMessageId(r2.requestId, "msg-2");

      manager.routeResponse({
        text: "go with B",
        messageId: "msg-999",
        isButtonTap: false,
      });

      const result = await r2.promise;
      expect(result.status).toBe("answered");
      expect(result.response).toBe("go with B");
    });

    it("routes prefixed free-text to correct request", async () => {
      const r1 = manager.createRequest("architecture", null);
      const r2 = manager.createRequest("preference", null);
      manager.setMessageId(r1.requestId, "msg-1");
      manager.setMessageId(r2.requestId, "msg-2");

      manager.routeResponse({
        text: "#1 use Postgres",
        messageId: "msg-999",
        isButtonTap: false,
      });

      const result = await r1.promise;
      expect(result.status).toBe("answered");
      expect(result.response).toBe("use Postgres");
    });

    it("returns selected_option as null for free-text when options were provided", async () => {
      const { requestId, promise } = manager.createRequest("preference", null, [
        { text: "Redis" },
        { text: "Postgres" },
      ]);
      manager.setMessageId(requestId, "msg-1");

      manager.routeResponse({
        text: "Actually use SQLite",
        messageId: "msg-999",
        isButtonTap: false,
      });

      const result = await promise;
      expect(result.status).toBe("answered");
      expect(result.response).toBe("Actually use SQLite");
      expect(result.selected_option).toBeNull();
    });
  });

  describe("timeout handling", () => {
    it("resolves with timed_out after timeout", async () => {
      vi.useFakeTimers();
      const { promise } = manager.createRequest(
        "preference",
        5000, // 5 second timeout
        [{ text: "default", default: true }]
      );

      vi.advanceTimersByTime(5000);

      const result = await promise;
      expect(result.status).toBe("timed_out");
      expect(result.timed_out_action).toBe("used_default");
      expect(result.response).toBe("default");
      vi.useRealTimers();
    });
  });

  describe("cleanup", () => {
    it("cancels all pending requests and resolves them with error", async () => {
      const r1 = manager.createRequest("preference", null);
      const r2 = manager.createRequest("architecture", null);
      manager.cancelAll();
      expect(manager.getPendingCount()).toBe(0);

      const result1 = await r1.promise;
      const result2 = await r2.promise;
      expect(result1.status).toBe("error");
      expect(result2.status).toBe("error");
    });
  });
});
