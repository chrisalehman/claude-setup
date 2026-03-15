// tests/ipc/protocol.test.ts
import { describe, it, expect } from "vitest";
import {
  PROTOCOL_VERSION,
  serialize,
  deserialize,
  type RegisterMessage,
} from "../../src/ipc/protocol.js";

describe("IPC Protocol", () => {
  describe("serialize", () => {
    it("serializes a message to a JSON line", () => {
      const msg: RegisterMessage = {
        type: "register",
        protocolVersion: PROTOCOL_VERSION,
        sessionId: "abc123",
        project: "test-project",
        cwd: "/home/user/project",
      };
      const line = serialize(msg);
      expect(line).toBe(JSON.stringify(msg) + "\n");
    });

    it("handles messages with optional fields omitted", () => {
      const msg: RegisterMessage = {
        type: "register",
        protocolVersion: PROTOCOL_VERSION,
        sessionId: "abc123",
        project: "test-project",
        cwd: "/home/user/project",
      };
      const parsed = JSON.parse(serialize(msg).trim());
      expect(parsed.worktree).toBeUndefined();
    });
  });

  describe("deserialize", () => {
    it("deserializes a JSON line to a message", () => {
      const msg: RegisterMessage = {
        type: "register",
        protocolVersion: PROTOCOL_VERSION,
        sessionId: "abc123",
        project: "test-project",
        cwd: "/home/user/project",
      };
      const result = deserialize(JSON.stringify(msg));
      expect(result).toEqual(msg);
    });

    it("throws on invalid JSON", () => {
      expect(() => deserialize("not json")).toThrow();
    });

    it("throws on message missing type field", () => {
      expect(() => deserialize('{"sessionId":"abc"}')).toThrow(/type/);
    });
  });

  describe("PROTOCOL_VERSION", () => {
    it("is 1", () => {
      expect(PROTOCOL_VERSION).toBe(1);
    });
  });
});
