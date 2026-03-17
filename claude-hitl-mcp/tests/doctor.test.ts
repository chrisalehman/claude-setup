import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import * as net from "node:net";
import { runDoctorChecks, formatDoctorResults, type CheckResult } from "../src/doctor.js";

function tmpDir(): string {
  const dir = path.join(
    os.tmpdir(),
    `doctor-test-${Date.now()}-${Math.random().toString(36).slice(2)}`
  );
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

describe("runDoctorChecks", () => {
  let configDir: string;
  let settingsPath: string;
  let plistPath: string;

  beforeEach(() => {
    configDir = tmpDir();
    const settingsDir = tmpDir();
    settingsPath = path.join(settingsDir, "settings.json");
    plistPath = path.join(configDir, "test.plist");
  });

  afterEach(() => {
    fs.rmSync(configDir, { recursive: true, force: true });
    fs.rmSync(path.dirname(settingsPath), { recursive: true, force: true });
  });

  function makeOpts(overrides?: Partial<Parameters<typeof runDoctorChecks>[0]>) {
    return {
      configDir,
      settingsPath,
      plistPath,
      fix: false,
      ...overrides,
    };
  }

  function writeConfig(config: Record<string, unknown>) {
    fs.writeFileSync(path.join(configDir, "config.json"), JSON.stringify(config));
  }

  function writeSettings(settings: Record<string, unknown>) {
    fs.writeFileSync(settingsPath, JSON.stringify(settings));
  }

  // --- Check 1: Config exists ---

  it("fails if config does not exist and returns early", async () => {
    const results = await runDoctorChecks(makeOpts());
    expect(results).toHaveLength(1);
    expect(results[0].label).toBe("Config exists");
    expect(results[0].passed).toBe(false);
    expect(results[0].hint).toContain("setup");
  });

  it("passes if config exists", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "literal-token", chat_id: 123 } });
    const results = await runDoctorChecks(makeOpts());
    expect(results[0].label).toBe("Config exists");
    expect(results[0].passed).toBe(true);
    // Should have more checks after the first one
    expect(results.length).toBeGreaterThan(1);
  });

  // --- Check 2: Token resolves ---

  it("passes token check for literal token", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "literal-token", chat_id: 123 } });
    const results = await runDoctorChecks(makeOpts());
    const tokenCheck = results.find((r) => r.label.includes("Telegram token"));
    expect(tokenCheck?.passed).toBe(true);
  });

  it("fails token check when env var is not set", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "env:NONEXISTENT_TEST_VAR_ABC", chat_id: 123 } });
    const results = await runDoctorChecks(makeOpts());
    const tokenCheck = results.find((r) => r.label.includes("Telegram token"));
    expect(tokenCheck?.passed).toBe(false);
  });

  it("fails token check when token field is missing", async () => {
    writeConfig({ adapter: "telegram", telegram: { chat_id: 123 } });
    const results = await runDoctorChecks(makeOpts());
    const tokenCheck = results.find((r) => r.label.includes("Telegram token"));
    expect(tokenCheck?.passed).toBe(false);
    expect(tokenCheck?.hint).toContain("missing");
  });

  // --- Check 3: Listener socket responsive ---

  it("fails socket check when no socket file exists", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    const results = await runDoctorChecks(makeOpts());
    const socketCheck = results.find((r) => r.label.includes("socket"));
    expect(socketCheck?.passed).toBe(false);
  });

  it("passes socket check when a real socket is listening", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    const sockPath = path.join(configDir, "sock");
    const server = net.createServer();
    await new Promise<void>((resolve) => server.listen(sockPath, resolve));
    try {
      const results = await runDoctorChecks(makeOpts());
      const socketCheck = results.find((r) => r.label.includes("socket"));
      expect(socketCheck?.passed).toBe(true);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  // --- Check 4: PID alive ---

  it("fails PID check when pid file does not exist", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    const results = await runDoctorChecks(makeOpts());
    const pidCheck = results.find((r) => r.label.includes("PID"));
    expect(pidCheck?.passed).toBe(false);
    expect(pidCheck?.hint).toContain("not found");
  });

  it("passes PID check for a running process", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    // Use our own PID — guaranteed to be alive
    fs.writeFileSync(path.join(configDir, "listener.pid"), String(process.pid));
    const results = await runDoctorChecks(makeOpts());
    const pidCheck = results.find((r) => r.label.includes("PID") && r.label.includes(String(process.pid)));
    expect(pidCheck?.passed).toBe(true);
  });

  it("fails PID check for a dead process", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    // PID 99999999 is almost certainly not running
    fs.writeFileSync(path.join(configDir, "listener.pid"), "99999999");
    const results = await runDoctorChecks(makeOpts());
    const pidCheck = results.find((r) => r.label.includes("PID"));
    expect(pidCheck?.passed).toBe(false);
    expect(pidCheck?.hint).toContain("not running");
  });

  // --- Check 5: Plist uses stable node path ---

  it("passes plist check when no Cellar path", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    fs.writeFileSync(plistPath, "<string>/usr/local/bin/node</string>");
    const results = await runDoctorChecks(makeOpts());
    const plistCheck = results.find((r) => r.label.includes("Plist") && r.label.includes("node"));
    expect(plistCheck?.passed).toBe(true);
  });

  it("fails plist check when Cellar path is present", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    fs.writeFileSync(plistPath, "<string>/opt/homebrew/Cellar/node/20.0.0/bin/node</string>");
    const results = await runDoctorChecks(makeOpts());
    const plistCheck = results.find((r) => r.label.includes("Plist"));
    expect(plistCheck?.passed).toBe(false);
    expect(plistCheck?.hint).toContain("Cellar");
  });

  it("fails plist check when plist file does not exist", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    const results = await runDoctorChecks(makeOpts());
    const plistCheck = results.find((r) => r.label.includes("Plist"));
    expect(plistCheck?.passed).toBe(false);
  });

  // --- Check 6: MCP registered ---

  it("passes MCP check when claude-hitl is in settings", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    writeSettings({ mcpServers: { "claude-hitl": { command: "node", args: ["dist/server.js"] } } });
    const results = await runDoctorChecks(makeOpts());
    const mcpCheck = results.find((r) => r.label.includes("MCP"));
    expect(mcpCheck?.passed).toBe(true);
  });

  it("fails MCP check when settings has no claude-hitl", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    writeSettings({ mcpServers: {} });
    const results = await runDoctorChecks(makeOpts());
    const mcpCheck = results.find((r) => r.label.includes("MCP"));
    expect(mcpCheck?.passed).toBe(false);
  });

  it("fails MCP check when settings file does not exist", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    const results = await runDoctorChecks(makeOpts());
    const mcpCheck = results.find((r) => r.label.includes("MCP"));
    expect(mcpCheck?.passed).toBe(false);
  });

  // --- Check 7: Hooks registered ---

  it("passes hooks check when both hooks are registered", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    writeSettings({
      hooks: {
        PostToolUse: [{ hooks: [{ type: "command", command: "/path/hook-activity.sh" }] }],
        PermissionRequest: [{ hooks: [{ type: "command", command: "/path/hook-blocked.sh" }] }],
      },
    });
    const results = await runDoctorChecks(makeOpts());
    const hooksCheck = results.find((r) => r.label.includes("Hooks"));
    expect(hooksCheck?.passed).toBe(true);
  });

  it("fails hooks check when only PostToolUse is registered", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    writeSettings({
      hooks: {
        PostToolUse: [{ hooks: [{ type: "command", command: "/path/hook-activity.sh" }] }],
      },
    });
    const results = await runDoctorChecks(makeOpts());
    const hooksCheck = results.find((r) => r.label.includes("Hooks"));
    expect(hooksCheck?.passed).toBe(false);
  });

  it("fails hooks check when no hooks exist", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    writeSettings({});
    const results = await runDoctorChecks(makeOpts());
    const hooksCheck = results.find((r) => r.label.includes("Hooks"));
    expect(hooksCheck?.passed).toBe(false);
  });

  // --- Fix mode ---

  it("calls reinstallListener callback when fix=true and socket fails", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    const reinstallListener = vi.fn();
    const results = await runDoctorChecks(makeOpts({
      fix: true,
      fixCallbacks: { reinstallListener },
    }));
    const socketCheck = results.find((r) => r.label.includes("socket"));
    expect(socketCheck?.passed).toBe(false);
    expect(socketCheck?.fixed).toBe(true);
    expect(reinstallListener).toHaveBeenCalled();
  });

  it("calls installHooks callback when fix=true and hooks are missing", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    writeSettings({});
    const installHooks = vi.fn();
    const results = await runDoctorChecks(makeOpts({
      fix: true,
      fixCallbacks: { installHooks },
    }));
    const hooksCheck = results.find((r) => r.label.includes("Hooks"));
    expect(hooksCheck?.fixed).toBe(true);
    expect(installHooks).toHaveBeenCalled();
  });

  // --- Full healthy system ---

  it("all checks pass when everything is configured correctly", async () => {
    writeConfig({ adapter: "telegram", telegram: { bot_token: "tok", chat_id: 123 } });
    fs.writeFileSync(path.join(configDir, "listener.pid"), String(process.pid));
    fs.writeFileSync(plistPath, "<string>/usr/local/bin/node</string>");
    writeSettings({
      mcpServers: { "claude-hitl": { command: "node" } },
      hooks: {
        PostToolUse: [{ hooks: [{ type: "command", command: "x" }] }],
        PermissionRequest: [{ hooks: [{ type: "command", command: "x" }] }],
      },
    });

    // Create a real socket for the listener check
    const sockPath = path.join(configDir, "sock");
    const server = net.createServer();
    await new Promise<void>((resolve) => server.listen(sockPath, resolve));
    try {
      const results = await runDoctorChecks(makeOpts());
      const failures = results.filter((r) => !r.passed);
      expect(failures).toHaveLength(0);
      expect(results.length).toBe(7); // All 7 checks (CLI on PATH excluded)
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});

describe("formatDoctorResults", () => {
  it("formats passing checks with checkmark", () => {
    const results: CheckResult[] = [{ label: "Config exists", passed: true }];
    const output = formatDoctorResults(results);
    expect(output).toContain("✓ Config exists");
    expect(output).toContain("All checks passed.");
  });

  it("formats failing checks with X and hint", () => {
    const results: CheckResult[] = [{ label: "Config exists", passed: false, hint: "run setup" }];
    const output = formatDoctorResults(results);
    expect(output).toContain("✗ Config exists — run setup");
    expect(output).toContain("1 issue(s) found.");
  });

  it("formats fixed checks with fixed indicator", () => {
    const results: CheckResult[] = [{ label: "Socket", passed: false, hint: "not found", fixed: true }];
    const output = formatDoctorResults(results);
    expect(output).toContain("✗ Socket — not found");
    expect(output).toContain("→ fixed");
    expect(output).toContain("All checks passed."); // Fixed counts as resolved
  });
});
