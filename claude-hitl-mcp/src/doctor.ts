import * as fs from "node:fs";
import * as net from "node:net";
import { loadConfig, resolveEnvValue } from "./config.js";

export interface CheckResult {
  label: string;
  passed: boolean;
  hint?: string;
  fixed?: boolean;
}

export interface DoctorOptions {
  configDir: string;
  settingsPath: string;
  plistPath: string;
  fix: boolean;
  fixCallbacks?: {
    reinstallListener?: () => void;
    registerMcp?: () => void;
    installHooks?: () => void;
  };
}

/**
 * Run all doctor diagnostic checks and return structured results.
 * Checks are run in order; if config is missing, only that check runs.
 */
export async function runDoctorChecks(opts: DoctorOptions): Promise<CheckResult[]> {
  const results: CheckResult[] = [];

  function pass(label: string) {
    results.push({ label, passed: true });
  }

  function fail(label: string, hint: string) {
    results.push({ label, passed: false, hint });
  }

  // 1. Config exists
  const configPath = `${opts.configDir}/config.json`;
  const config = loadConfig(configPath);
  if (config) {
    pass("Config exists");
  } else {
    fail("Config exists", "run: claude-hitl-mcp setup");
    return results; // Early return — can't check anything else
  }

  // 2. Token resolves
  try {
    if (config.telegram?.bot_token) {
      resolveEnvValue(config.telegram.bot_token);
      pass("Telegram token resolves");
    } else {
      fail("Telegram token", "missing in config");
    }
  } catch {
    fail("Telegram token resolves", "TELEGRAM_BOT_TOKEN env var not set");
  }

  // 3. Listener socket responsive
  const socketPath = `${opts.configDir}/sock`;
  const socketAlive = await new Promise<boolean>((resolve) => {
    if (!fs.existsSync(socketPath)) { resolve(false); return; }
    const sock = net.createConnection(socketPath);
    const timer = setTimeout(() => { sock.destroy(); resolve(false); }, 2000);
    sock.on("connect", () => { clearTimeout(timer); sock.destroy(); resolve(true); });
    sock.on("error", () => { clearTimeout(timer); resolve(false); });
  });
  if (socketAlive) {
    pass("Listener socket responsive");
  } else {
    const check: CheckResult = {
      label: "Listener socket responsive",
      passed: false,
      hint: "run: claude-hitl-mcp install-listener",
    };
    if (opts.fix && opts.fixCallbacks?.reinstallListener) {
      try {
        opts.fixCallbacks.reinstallListener();
        check.fixed = true;
      } catch {
        // Fix failed — leave fixed undefined
      }
    }
    results.push(check);
  }

  // 4. PID alive
  const pidPath = `${opts.configDir}/listener.pid`;
  if (fs.existsSync(pidPath)) {
    const pid = parseInt(fs.readFileSync(pidPath, "utf-8").trim(), 10);
    try {
      process.kill(pid, 0);
      pass(`Listener PID ${pid} alive`);
    } catch {
      fail(`Listener PID ${pid}`, "process not running");
    }
  } else {
    fail("Listener PID file", "not found");
  }

  // 5. Plist uses stable node path
  if (fs.existsSync(opts.plistPath)) {
    const plist = fs.readFileSync(opts.plistPath, "utf-8");
    if (plist.includes("/Cellar/")) {
      const check: CheckResult = {
        label: "Plist node path",
        passed: false,
        hint: "uses Cellar path (breaks on brew upgrade)",
      };
      if (opts.fix && opts.fixCallbacks?.reinstallListener) {
        try {
          opts.fixCallbacks.reinstallListener();
          check.fixed = true;
        } catch {
          // Fix failed
        }
      }
      results.push(check);
    } else {
      pass("Plist uses stable node path");
    }
  } else {
    fail("Plist exists", "run: claude-hitl-mcp install-listener");
  }

  // 6. MCP registered in settings.json
  let settings: Record<string, unknown> = {};
  if (fs.existsSync(opts.settingsPath)) {
    settings = JSON.parse(fs.readFileSync(opts.settingsPath, "utf-8")) as Record<string, unknown>;
  }
  const mcpServers = (settings.mcpServers ?? {}) as Record<string, unknown>;
  if (mcpServers["claude-hitl"]) {
    pass("MCP server registered in settings.json");
  } else {
    const check: CheckResult = {
      label: "MCP server registered",
      passed: false,
      hint: "not found in settings.json",
    };
    if (opts.fix && opts.fixCallbacks?.registerMcp) {
      try {
        opts.fixCallbacks.registerMcp();
        check.fixed = true;
      } catch {
        // Fix failed
      }
    }
    results.push(check);
  }

  // 7. Hooks registered
  const hooks = (settings.hooks ?? {}) as Record<string, unknown[]>;
  const hasPostToolUse = Array.isArray(hooks.PostToolUse) && hooks.PostToolUse.length > 0;
  const hasPermissionReq = Array.isArray(hooks.PermissionRequest) && hooks.PermissionRequest.length > 0;
  if (hasPostToolUse && hasPermissionReq) {
    pass("Hooks registered (PostToolUse, PermissionRequest)");
  } else {
    const check: CheckResult = {
      label: "Hooks registered",
      passed: false,
      hint: "missing in settings.json",
    };
    if (opts.fix && opts.fixCallbacks?.installHooks) {
      try {
        opts.fixCallbacks.installHooks();
        check.fixed = true;
      } catch {
        // Fix failed
      }
    }
    results.push(check);
  }

  return results;
}

/**
 * Format doctor check results for console output.
 */
export function formatDoctorResults(results: CheckResult[]): string {
  const lines = ["claude-hitl doctor\n"];
  for (const r of results) {
    if (r.passed) {
      lines.push(`  ✓ ${r.label}`);
    } else {
      lines.push(`  ✗ ${r.label} — ${r.hint}`);
      if (r.fixed) {
        lines.push(`    → fixed`);
      }
    }
  }
  const failures = results.filter((r) => !r.passed && !r.fixed).length;
  lines.push("");
  lines.push(failures === 0 ? "All checks passed." : `${failures} issue(s) found.`);
  return lines.join("\n");
}
