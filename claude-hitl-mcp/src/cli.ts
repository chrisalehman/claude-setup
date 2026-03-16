import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import * as child_process from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  loadConfig,
  saveConfig,
  resolveEnvValue,
  migrateConfig,
  LEGACY_CONFIG_PATH,
  HITL_CONFIG_DIR,
  ensureConfigDir,
} from "./config.js";
import { TelegramAdapter } from "./adapters/telegram.js";
import { createAdapter } from "./adapters/factory.js";
import { HitlToolHandler } from "./tools.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEFAULT_CONFIG_PATH = path.join(HITL_CONFIG_DIR, "config.json");
const PLIST_PATH = path.join(
  os.homedir(),
  "Library",
  "LaunchAgents",
  "com.claude-hitl.listener.plist"
);

function persistEnvVar(varName: string, value: string): void {
  const zshrc = path.join(os.homedir(), ".zshrc");
  const exportLine = `export ${varName}="${value}"`;
  const pattern = new RegExp(`^export ${varName}=`);

  if (!fs.existsSync(zshrc)) {
    fs.writeFileSync(zshrc, exportLine + "\n", "utf-8");
    return;
  }

  const lines = fs.readFileSync(zshrc, "utf-8").split("\n");
  const existingIdx = lines.findIndex((line) => pattern.test(line));

  if (existingIdx !== -1) {
    if (lines[existingIdx] === exportLine) {
      // Already set to the same value — do nothing
      return;
    }
    // Replace the existing line with the new value
    lines[existingIdx] = exportLine;
    fs.writeFileSync(zshrc, lines.join("\n"), "utf-8");
  } else {
    // Append to end
    fs.appendFileSync(zshrc, "\n" + exportLine + "\n", "utf-8");
  }
}

function buildPlistContent(nodePath: string, packageDir: string, configDir: string, envVars?: Record<string, string>): string {
  let envSection = "";
  if (envVars && Object.keys(envVars).length > 0) {
    const entries = Object.entries(envVars)
      .map(([k, v]) => `      <key>${k}</key>\n      <string>${v}</string>`)
      .join("\n");
    envSection = `\n  <key>EnvironmentVariables</key>\n  <dict>\n${entries}\n  </dict>`;
  }

  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude-hitl.listener</string>
  <key>ProgramArguments</key>
  <array>
    <string>${nodePath}</string>
    <string>dist/listener.js</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${packageDir}</string>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${configDir}/listener.log</string>
  <key>StandardErrorPath</key>
  <string>${configDir}/listener.log</string>${envSection}
</dict>
</plist>
`;
}

const SETTINGS_PATH = path.join(os.homedir(), ".claude", "settings.json");

function readSettings(): Record<string, unknown> {
  if (fs.existsSync(SETTINGS_PATH)) {
    return JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf-8"));
  }
  return {};
}

function writeSettings(settings: Record<string, unknown>): void {
  const claudeDir = path.join(os.homedir(), ".claude");
  if (!fs.existsSync(claudeDir)) fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n", "utf-8");
}

function registerMcpInSettings(serverJsPath: string, token: string): void {
  const settings = readSettings();
  if (!settings.mcpServers) settings.mcpServers = {};
  (settings.mcpServers as Record<string, unknown>)["claude-hitl"] = {
    command: "node",
    args: [serverJsPath],
    env: { TELEGRAM_BOT_TOKEN: token },
  };
  writeSettings(settings);
}

function installHooksInSettings(): void {
  const settings = readSettings();
  if (!settings.hooks) settings.hooks = {};
  const hooks = settings.hooks as Record<string, unknown[]>;

  const binDir = path.resolve(__dirname, "..", "bin");
  const hookEvents: Record<string, string> = {
    PostToolUse: path.join(binDir, "hook-activity.sh"),
    PermissionRequest: path.join(binDir, "hook-blocked.sh"),
  };

  for (const [event, hookPath] of Object.entries(hookEvents)) {
    if (!hooks[event]) hooks[event] = [];
    const eventHooks = hooks[event] as Array<{
      matcher?: string;
      hooks: Array<{ type: string; command: string }>;
    }>;
    const alreadyInstalled = eventHooks.some((entry) =>
      entry.hooks?.some((h) => h.command === hookPath)
    );
    if (!alreadyInstalled) {
      eventHooks.push({ hooks: [{ type: "command", command: hookPath }] });
    }
  }
  writeSettings(settings);
}

/** Resolve a stable node path that survives brew upgrades. */
function stableNodePath(): string {
  const execPath = process.execPath;
  // If running from Homebrew Cellar, prefer the stable symlink
  if (execPath.includes("/Cellar/") || execPath.includes("/opt/homebrew/lib/")) {
    const brewNode = "/opt/homebrew/bin/node";
    try {
      if (fs.existsSync(brewNode) && fs.realpathSync(brewNode) === fs.realpathSync(execPath)) {
        return brewNode;
      }
    } catch {}
  }
  return execPath;
}

function doInstallListener(): void {
  const nodePath = stableNodePath();
  const packageDir = path.resolve(__dirname, "..");
  const configDir = HITL_CONFIG_DIR;

  ensureConfigDir(configDir);

  const launchAgentsDir = path.join(os.homedir(), "Library", "LaunchAgents");
  ensureConfigDir(launchAgentsDir);

  // Resolve env vars that the listener needs — launchd doesn't inherit shell env
  const envVars: Record<string, string> = {};
  const config = loadConfig();
  if (config?.telegram?.bot_token) {
    const tokenValue = config.telegram.bot_token;
    if (typeof tokenValue === "string" && tokenValue.startsWith("env:")) {
      const resolved = resolveEnvValue(tokenValue);
      const envName = tokenValue.slice(4);
      envVars[envName] = resolved;
    }
  }

  // Unload existing plist if present (ignore errors)
  try {
    child_process.execSync(`launchctl unload "${PLIST_PATH}" 2>/dev/null`, { stdio: "ignore" });
  } catch {}

  const plistContent = buildPlistContent(nodePath, packageDir, configDir, envVars);
  fs.writeFileSync(PLIST_PATH, plistContent, "utf-8");

  child_process.execSync(`launchctl load "${PLIST_PATH}"`, { stdio: "inherit" });
  console.log("Listener installed and started.");
  console.log(`  Plist: ${PLIST_PATH}`);
  console.log(`  Logs:  ${configDir}/listener.log`);
}

function getArg(args: string[], flag: string): string | undefined {
  const idx = args.indexOf(flag);
  return idx !== -1 && idx + 1 < args.length ? args[idx + 1] : undefined;
}

function sendSignalToSocket(msg: Record<string, string>): void {
  const socketPath = `${HITL_CONFIG_DIR}/sock`;
  const socket = net.createConnection(socketPath);
  socket.on("connect", () => {
    socket.write(JSON.stringify(msg) + "\n", () => {
      socket.destroy();
      process.exit(0);
    });
  });
  socket.on("error", () => {
    process.exit(1);
  });
}

function signal(args: string[]): void {
  const type = args[0];
  if (type !== "activity" && type !== "blocked") {
    console.error("Usage: claude-hitl-mcp signal <activity|blocked> [--stdin | --session-id <id> --tool <name>]");
    process.exit(1);
  }

  // --stdin mode: read Claude Code hook JSON from stdin
  if (args.includes("--stdin")) {
    let data = "";
    process.stdin.setEncoding("utf-8");
    process.stdin.on("data", (chunk) => { data += chunk; });
    process.stdin.on("end", () => {
      try {
        const input = JSON.parse(data);
        const sessionId = input.session_id;
        const toolName = input.tool_name;
        if (!sessionId || !toolName) process.exit(0);

        const msg: Record<string, string> = { type, sessionId, toolName };
        if (type === "blocked") {
          const ti = input.tool_input?.command ?? input.tool_input?.file_path ?? "";
          if (ti) msg.toolInput = String(ti).slice(0, 200);
        }
        const cwd = input.cwd;
        if (cwd) msg.cwd = cwd;
        sendSignalToSocket(msg);
      } catch {
        process.exit(0); // Don't block Claude Code on parse errors
      }
    });
    return;
  }

  // Explicit args mode
  const sessionId = getArg(args, "--session-id");
  const toolName = getArg(args, "--tool");
  if (!sessionId || !toolName) {
    console.error("--session-id and --tool are required (or use --stdin)");
    process.exit(1);
  }

  const toolInput = getArg(args, "--input");
  const msg: Record<string, string> = { type, sessionId, toolName };
  if (toolInput && type === "blocked") msg.toolInput = toolInput;
  sendSignalToSocket(msg);
}

async function doctor(fix: boolean): Promise<void> {
  let failures = 0;

  function pass(label: string) { console.log(`  ✓ ${label}`); }
  function fail(label: string, hint: string) { console.log(`  ✗ ${label} — ${hint}`); failures++; }

  console.log("claude-hitl doctor\n");

  // 1. Config
  const config = loadConfig();
  if (config) {
    pass("Config exists");
  } else {
    fail("Config exists", "run: claude-hitl-mcp setup");
    console.log(`\n${failures} issue(s) found. Fix config first, then re-run doctor.`);
    return;
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

  // 3. Listener socket
  const socketPath = path.join(HITL_CONFIG_DIR, "sock");
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
    fail("Listener socket responsive", "run: claude-hitl-mcp install-listener");
    if (fix) {
      console.log("    → fixing: reinstalling listener...");
      try { doInstallListener(); pass("Listener reinstalled"); } catch { fail("Listener reinstall", "manual intervention needed"); }
    }
  }

  // 4. PID alive
  const pidPath = path.join(HITL_CONFIG_DIR, "listener.pid");
  if (fs.existsSync(pidPath)) {
    const pid = parseInt(fs.readFileSync(pidPath, "utf-8").trim(), 10);
    try { process.kill(pid, 0); pass(`Listener PID ${pid} alive`); }
    catch { fail(`Listener PID ${pid}`, "process not running"); }
  } else {
    fail("Listener PID file", "not found");
  }

  // 5. Plist uses stable node path
  if (fs.existsSync(PLIST_PATH)) {
    const plist = fs.readFileSync(PLIST_PATH, "utf-8");
    if (plist.includes("/Cellar/")) {
      fail("Plist node path", "uses Cellar path (breaks on brew upgrade)");
      if (fix) {
        console.log("    → fixing: rewriting plist with stable path...");
        try { doInstallListener(); pass("Plist rewritten"); } catch { fail("Plist rewrite", "failed"); }
      }
    } else {
      pass("Plist uses stable node path");
    }
  } else {
    fail("Plist exists", "run: claude-hitl-mcp install-listener");
  }

  // 6. MCP registered
  const settings = readSettings();
  const mcpServers = (settings.mcpServers ?? {}) as Record<string, unknown>;
  if (mcpServers["claude-hitl"]) {
    pass("MCP server registered in settings.json");
  } else {
    fail("MCP server registered", "not found in ~/.claude/settings.json");
    if (fix) {
      console.log("    → fixing: registering MCP server...");
      const serverJsPath = path.resolve(__dirname, "..", "dist", "server.js");
      const token = config.telegram?.bot_token ? resolveEnvValue(config.telegram.bot_token) : "";
      if (token) {
        try {
          child_process.execSync(
            `claude mcp add claude-hitl -e "TELEGRAM_BOT_TOKEN=${token}" -s user -- node "${serverJsPath}"`,
            { stdio: "pipe" }
          );
          pass("MCP server registered");
        } catch {
          try { registerMcpInSettings(serverJsPath, token); pass("MCP registered (fallback)"); }
          catch { fail("MCP registration", "failed — register manually"); }
        }
      }
    }
  }

  // 7. Hooks registered
  const hooks = (settings.hooks ?? {}) as Record<string, unknown[]>;
  const hasPostToolUse = Array.isArray(hooks.PostToolUse) && hooks.PostToolUse.length > 0;
  const hasPermissionReq = Array.isArray(hooks.PermissionRequest) && hooks.PermissionRequest.length > 0;
  if (hasPostToolUse && hasPermissionReq) {
    pass("Hooks registered (PostToolUse, PermissionRequest)");
  } else {
    fail("Hooks registered", "missing in ~/.claude/settings.json");
    if (fix) {
      console.log("    → fixing: installing hooks...");
      try { installHooksInSettings(); pass("Hooks installed"); } catch { fail("Hook install", "failed"); }
    }
  }

  // 8. CLI on PATH
  try {
    child_process.execSync("which claude-hitl-mcp", { stdio: "pipe" });
    pass("claude-hitl-mcp on PATH");
  } catch {
    fail("claude-hitl-mcp on PATH", "run: npm link (from claude-hitl-mcp dir)");
  }

  console.log(`\n${failures === 0 ? "All checks passed." : `${failures} issue(s) found.${fix ? "" : " Run with --fix to auto-repair."}`}`);
}

const USAGE = `
claude-hitl-mcp — Human-in-the-Loop MCP Server

Usage:
  claude-hitl-mcp                 Start MCP server (stdio mode)
  claude-hitl-mcp setup           Interactive first-time setup
  claude-hitl-mcp doctor          Check all prerequisites (--fix to auto-repair)
  claude-hitl-mcp test            End-to-end test (all tools + priorities)
  claude-hitl-mcp status          Show config and connection status
  claude-hitl-mcp signal <type>   Send activity/blocked signal to listener
  claude-hitl-mcp install-listener    Install and start the listener daemon
  claude-hitl-mcp uninstall-listener  Stop and remove the listener daemon
  claude-hitl-mcp start-listener      Start the listener daemon
  claude-hitl-mcp stop-listener       Stop the listener daemon
  claude-hitl-mcp listener-logs       Tail the listener log file
`;

async function setup() {
  console.log("claude-hitl setup\n");

  // Migrate legacy config if present
  migrateConfig(LEGACY_CONFIG_PATH, DEFAULT_CONFIG_PATH);

  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (!token) {
    console.error("TELEGRAM_BOT_TOKEN environment variable is not set.");
    console.error("\nTo create a bot:");
    console.error("  1. Open Telegram and message @BotFather");
    console.error("  2. Send /newbot and follow the prompts");
    console.error("  3. Copy the token and run:");
    console.error('     export TELEGRAM_BOT_TOKEN="your-token-here"');
    process.exit(1);
  }

  console.log("Found TELEGRAM_BOT_TOKEN in environment");

  // Persist token to ~/.zshrc (idempotent — updates existing or appends)
  persistEnvVar("TELEGRAM_BOT_TOKEN", token);
  console.log("Token persisted to ~/.zshrc");

  const adapter = new TelegramAdapter();
  await adapter.connect({ token });
  console.log("Bot connected");
  console.log("\n-> Open Telegram and send /start to your bot");
  console.log("  Waiting for your message...\n");

  const binding = await adapter.awaitBinding();
  console.log(`Bound to user: ${binding.displayName} (chat_id: ${binding.chatId})`);

  const config = {
    adapter: "telegram" as const,
    telegram: {
      bot_token: "env:TELEGRAM_BOT_TOKEN",
      chat_id: parseInt(binding.chatId, 10),
    },
    defaults: {
      timeouts: {
        architecture: 120,
        preference: 30,
      },
    },
  };

  saveConfig(config);
  console.log(`Config written to ${DEFAULT_CONFIG_PATH}`);

  // Register MCP server via `claude mcp add` (canonical method)
  const serverJsPath = path.resolve(__dirname, "..", "dist", "server.js");
  try {
    child_process.execSync(
      `claude mcp add claude-hitl -e "TELEGRAM_BOT_TOKEN=${token}" -s user -- node "${serverJsPath}"`,
      { stdio: "pipe" }
    );
    console.log("MCP server registered globally via claude mcp add");
  } catch {
    // Fallback: write directly to settings.json (claude CLI may not be on PATH)
    try {
      registerMcpInSettings(serverJsPath, token);
      console.log("MCP server registered globally in ~/.claude/settings.json");
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.warn(`Warning: could not register MCP server: ${message}`);
      console.warn(`Register manually: claude mcp add claude-hitl -s user -- node "${serverJsPath}"`);
    }
  }

  // Install hooks in ~/.claude/settings.json
  try {
    installHooksInSettings();
    console.log("Claude Code hooks installed for activity tracking");
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.warn(`Warning: could not install hooks: ${message}`);
  }

  await adapter.sendMessage({
    text: "Claude HITL is connected! You'll receive notifications here when Claude Code needs your input.",
    level: "success",
  });
  console.log("Test notification sent to Telegram");

  await adapter.disconnect();

  // Install the listener daemon
  try {
    doInstallListener();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.warn(`Warning: could not install listener daemon: ${message}`);
    console.warn("You can install it manually with: claude-hitl-mcp install-listener");
  }

  console.log("\nSetup complete!");
}

async function test() {
  const config = loadConfig();
  if (!config || !config.telegram) {
    console.error("Not configured. Run: claude-hitl-mcp setup");
    process.exit(1);
  }

  const token = resolveEnvValue(config.telegram.bot_token);
  const socketPath = path.join(HITL_CONFIG_DIR, "sock");
  const adapter = createAdapter(socketPath);
  await adapter.connect({
    token,
    chatId: config.telegram.chat_id ? String(config.telegram.chat_id) : undefined,
  });

  const handler = new HitlToolHandler(adapter);

  console.log("claude-hitl-mcp comprehensive test\n");
  console.log("This exercises all tools and priorities via Telegram.");
  console.log("Watch your Telegram chat and tap the buttons when prompted.\n");

  // 1. configure_hitl
  console.log("1/7  configure_hitl ...");
  const configResult = await handler.configureHitl({ session_context: "HITL test suite" });
  console.log(`     ${configResult.status} (adapter: ${configResult.active_config.adapter})`);

  // 2. notify_human — all levels
  const levels = ["info", "success", "warning", "error"] as const;
  for (let i = 0; i < levels.length; i++) {
    const level = levels[i];
    console.log(`${i + 2}/7  notify_human (${level}) ...`);
    const result = await handler.notifyHuman({
      message: `Test notification — level: ${level}`,
      level,
    });
    console.log(`     ${result.status}`);
  }

  // 3. ask_human — preference (30s timeout, auto-picks default)
  console.log("6/7  ask_human (preference) — tap a button or wait 30s for auto-default ...");
  const prefResult = await handler.askHuman({
    message: "Test preference question: pick a color",
    priority: "preference",
    options: [
      { text: "Red" },
      { text: "Blue", default: true },
      { text: "Green" },
    ],
    timeout_minutes: 0.5, // 30 seconds for test
  });
  console.log(`     ${prefResult.status}: ${prefResult.response}`);

  // 4. ask_human — architecture (60s timeout, returns "paused")
  console.log("7/7  ask_human (architecture) — tap a button or wait 60s for timeout ...");
  const archResult = await handler.askHuman({
    message: "Test architecture question: which database?",
    priority: "architecture",
    options: [
      { text: "PostgreSQL", default: true },
      { text: "SQLite" },
    ],
    timeout_minutes: 1, // 60 seconds for test
  });
  console.log(`     ${archResult.status}: ${archResult.response}`);

  // Note: we skip critical because it blocks forever (no timeout)

  console.log("\nAll tests complete.");
  await adapter.disconnect();
}

async function status() {
  const config = loadConfig();
  if (!config) {
    console.log("Status: Not configured");
    console.log("Run: claude-hitl-mcp setup");
    return;
  }

  console.log(`Adapter: ${config.adapter}`);
  console.log(`Chat ID: ${config.telegram?.chat_id ?? "not bound"}`);
  console.log(`Token: ${config.telegram?.bot_token ? "configured" : "missing"}`);
  if (config.defaults?.timeouts) {
    console.log(`Timeouts: architecture=${config.defaults.timeouts.architecture}m, preference=${config.defaults.timeouts.preference}m`);
  }
  if (config.defaults?.quiet_hours) {
    const qh = config.defaults.quiet_hours;
    console.log(`Quiet hours: ${qh.start}-${qh.end} ${qh.timezone} (${qh.behavior})`);
  }

  // Check listener daemon health via IPC socket (avoids 409 Conflict with Telegram)
  const socketPath = path.join(HITL_CONFIG_DIR, "sock");
  if (fs.existsSync(socketPath)) {
    try {
      const stat = fs.statSync(socketPath);
      if (stat.isSocket()) {
        // Try connecting to the socket to verify the listener is alive
        const alive = await new Promise<boolean>((resolve) => {
          const sock = net.createConnection(socketPath);
          const timer = setTimeout(() => { sock.destroy(); resolve(false); }, 2000);
          sock.on("connect", () => { clearTimeout(timer); sock.destroy(); resolve(true); });
          sock.on("error", () => { clearTimeout(timer); resolve(false); });
        });
        console.log(`Listener: ${alive ? "running" : "socket exists but not responding"}`);
      } else {
        console.log("Listener: socket path exists but is not a socket");
      }
    } catch {
      console.log("Listener: not running (socket check failed)");
    }
  } else {
    console.log("Listener: not running (no socket)");
  }

  // Check PID file
  const pidPath = path.join(HITL_CONFIG_DIR, "listener.pid");
  if (fs.existsSync(pidPath)) {
    const pid = fs.readFileSync(pidPath, "utf-8").trim();
    try {
      process.kill(parseInt(pid, 10), 0); // signal 0 = existence check
      console.log(`Listener PID: ${pid} (alive)`);
    } catch {
      console.log(`Listener PID: ${pid} (stale — process not running)`);
    }
  }
}

function installListener() {
  doInstallListener();
}

function uninstallListener() {
  if (fs.existsSync(PLIST_PATH)) {
    try {
      child_process.execSync(`launchctl unload "${PLIST_PATH}"`, { stdio: "inherit" });
    } catch {
      // Best effort — daemon may already be stopped
    }
    fs.unlinkSync(PLIST_PATH);
    console.log("Listener daemon uninstalled.");
  } else {
    console.log("Listener plist not found — nothing to uninstall.");
  }
}

function startListener() {
  child_process.execSync("launchctl start com.claude-hitl.listener", { stdio: "inherit" });
  console.log("Listener started.");
}

function stopListener() {
  child_process.execSync("launchctl stop com.claude-hitl.listener", { stdio: "inherit" });
  console.log("Listener stopped.");
}

function listenerLogs() {
  const logPath = path.join(HITL_CONFIG_DIR, "listener.log");
  if (!fs.existsSync(logPath)) {
    console.error(`Log file not found: ${logPath}`);
    process.exit(1);
  }
  const tail = child_process.spawn("tail", ["-f", logPath], { stdio: "inherit" });
  tail.on("close", (code) => {
    process.exit(code ?? 0);
  });
}

async function startServer() {
  await import("./server.js");
}

const command = process.argv[2];

switch (command) {
  case "setup":
    setup().catch((err: unknown) => {
      const message = err instanceof Error ? err.message : String(err);
      console.error("Setup failed:", message);
      process.exit(1);
    });
    break;
  case "test":
    test().catch((err: unknown) => {
      const message = err instanceof Error ? err.message : String(err);
      console.error("Test failed:", message);
      process.exit(1);
    });
    break;
  case "doctor":
    doctor(process.argv.includes("--fix")).catch((err: unknown) => {
      const message = err instanceof Error ? err.message : String(err);
      console.error("Doctor failed:", message);
      process.exit(1);
    });
    break;
  case "status":
    status().catch((err: unknown) => {
      const message = err instanceof Error ? err.message : String(err);
      console.error("Status failed:", message);
      process.exit(1);
    });
    break;
  case "install-listener":
    try {
      installListener();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error("install-listener failed:", message);
      process.exit(1);
    }
    break;
  case "uninstall-listener":
    try {
      uninstallListener();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error("uninstall-listener failed:", message);
      process.exit(1);
    }
    break;
  case "start-listener":
    try {
      startListener();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error("start-listener failed:", message);
      process.exit(1);
    }
    break;
  case "stop-listener":
    try {
      stopListener();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error("stop-listener failed:", message);
      process.exit(1);
    }
    break;
  case "listener-logs":
    listenerLogs();
    break;
  case "signal":
    signal(process.argv.slice(3));
    break;
  default:
    if (command && command !== "--help" && command !== "-h") {
      console.error(`Unknown command: ${command}`);
      console.error(USAGE);
      process.exit(1);
    }
    if (command) {
      console.log(USAGE);
    } else {
      startServer();
    }
}
