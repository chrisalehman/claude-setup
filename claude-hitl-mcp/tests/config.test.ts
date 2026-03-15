import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { loadConfig, resolveEnvValue, saveConfig } from "../src/config.js";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

describe("resolveEnvValue", () => {
  it("resolves env: prefix from environment", () => {
    vi.stubEnv("MY_TOKEN", "secret123");
    expect(resolveEnvValue("env:MY_TOKEN")).toBe("secret123");
    vi.unstubAllEnvs();
  });

  it("returns literal value when no env: prefix", () => {
    expect(resolveEnvValue("literal-token")).toBe("literal-token");
  });

  it("throws when env var is not set", () => {
    expect(() => resolveEnvValue("env:MISSING_VAR")).toThrow("MISSING_VAR");
  });
});

describe("loadConfig", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "hitl-test-"));
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true });
  });

  it("loads valid config file", () => {
    const configPath = path.join(tmpDir, ".claude-hitl.json");
    fs.writeFileSync(configPath, JSON.stringify({
      adapter: "telegram",
      telegram: { bot_token: "test-token", chat_id: 12345 },
    }));
    const config = loadConfig(configPath);
    expect(config?.adapter).toBe("telegram");
    expect(config?.telegram?.chat_id).toBe(12345);
  });

  it("returns null when file does not exist", () => {
    const config = loadConfig(path.join(tmpDir, "nope.json"));
    expect(config).toBeNull();
  });

  it("throws on invalid JSON", () => {
    const configPath = path.join(tmpDir, ".claude-hitl.json");
    fs.writeFileSync(configPath, "not json");
    expect(() => loadConfig(configPath)).toThrow();
  });

  it("resolves CLAUDE_HITL_CONFIG env var as config path", () => {
    const configPath = path.join(tmpDir, "custom.json");
    fs.writeFileSync(configPath, JSON.stringify({ adapter: "telegram" }));
    vi.stubEnv("CLAUDE_HITL_CONFIG", configPath);
    const config = loadConfig();
    expect(config?.adapter).toBe("telegram");
    vi.unstubAllEnvs();
  });

  it("throws when config is missing required adapter field", () => {
    const configPath = path.join(tmpDir, ".claude-hitl.json");
    fs.writeFileSync(configPath, JSON.stringify({ telegram: {} }));
    expect(() => loadConfig(configPath)).toThrow("adapter");
  });
});

describe("saveConfig", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "hitl-test-"));
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true });
  });

  it("writes config as formatted JSON", () => {
    const configPath = path.join(tmpDir, ".claude-hitl.json");
    const config = { adapter: "telegram", telegram: { bot_token: "env:TOKEN", chat_id: 123 } };
    saveConfig(config, configPath);
    const raw = fs.readFileSync(configPath, "utf-8");
    expect(JSON.parse(raw)).toEqual(config);
    expect(raw).toContain("\n");
  });
});
