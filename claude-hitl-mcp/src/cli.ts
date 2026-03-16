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

function doInstallListener(): void {
  const nodePath = process.execPath;
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

function signal(args: string[]): void {
  const type = args[0];
  if (type !== "activity" && type !== "blocked") {
    console.error("Usage: claude-hitl-mcp signal <activity|blocked> --session-id <id> --tool <name> [--input <text>]");
    process.exit(1);
  }

  const sessionId = getArg(args, "--session-id");
  const toolName = getArg(args, "--tool");
  if (!sessionId || !toolName) {
    console.error("--session-id and --tool are required");
    process.exit(1);
  }

  const toolInput = getArg(args, "--input");

  const msg: Record<string, string> = { type, sessionId, toolName };
  if (toolInput && type === "blocked") {
    msg.toolInput = toolInput;
  }

  const socketPath = `${HITL_CONFIG_DIR}/sock`;
  const socket = net.createConnection(socketPath);

  socket.on("connect", () => {
    socket.write(JSON.stringify(msg) + "\n", () => {
      console.log("sent");
      socket.destroy();
      process.exit(0);
    });
  });

  socket.on("error", (err) => {
    console.error(`failed: ${err.message}`);
    process.exit(1);
  });
}

const USAGE = `
claude-hitl-mcp — Human-in-the-Loop MCP Server

Usage:
  claude-hitl-mcp                 Start MCP server (stdio mode)
  claude-hitl-mcp setup           Interactive first-time setup
  claude-hitl-mcp test            Send a test notification
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

  // Register MCP server globally in ~/.claude/settings.json (creates or updates)
  const settingsPath = path.join(os.homedir(), ".claude", "settings.json");
  try {
    const claudeDir = path.join(os.homedir(), ".claude");
    if (!fs.existsSync(claudeDir)) {
      fs.mkdirSync(claudeDir, { recursive: true });
    }

    const settings = fs.existsSync(settingsPath)
      ? JSON.parse(fs.readFileSync(settingsPath, "utf-8"))
      : {};

    if (!settings.mcpServers) {
      settings.mcpServers = {};
    }

    const serverJsPath = path.resolve(__dirname, "..", "dist", "server.js");
    settings.mcpServers["claude-hitl"] = {
      command: "node",
      args: [serverJsPath],
      env: {
        TELEGRAM_BOT_TOKEN: token,
      },
    };

    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n", "utf-8");
    console.log("MCP server registered globally in ~/.claude/settings.json");
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.warn(`Warning: could not register MCP server: ${message}`);
    console.warn("Register manually: claude mcp add claude-hitl -s user -- node " + path.resolve(__dirname, "..", "dist", "server.js"));
  }

  // Install Claude Code hooks for activity tracking
  try {
    const binDir = path.resolve(__dirname, "..", "bin");
    const activityHookPath = path.join(binDir, "hook-activity.sh");
    const blockedHookPath = path.join(binDir, "hook-blocked.sh");

    const hookSettings = fs.existsSync(settingsPath)
      ? JSON.parse(fs.readFileSync(settingsPath, "utf-8"))
      : {};

    if (!hookSettings.hooks) {
      hookSettings.hooks = {};
    }

    const hookEvents: Record<string, string> = {
      PostToolUse: activityHookPath,
      PermissionRequest: blockedHookPath,
    };

    for (const [event, hookPath] of Object.entries(hookEvents)) {
      if (!hookSettings.hooks[event]) {
        hookSettings.hooks[event] = [];
      }
      // Claude Code hooks format: [{matcher?, hooks: [{type, command}]}]
      const eventHooks = hookSettings.hooks[event] as Array<{
        matcher?: string;
        hooks: Array<{ type: string; command: string }>;
      }>;
      const alreadyInstalled = eventHooks.some((entry) =>
        entry.hooks?.some((h) => h.command === hookPath)
      );
      if (!alreadyInstalled) {
        eventHooks.push({
          hooks: [{ type: "command", command: hookPath }],
        });
      }
    }

    fs.writeFileSync(settingsPath, JSON.stringify(hookSettings, null, 2) + "\n", "utf-8");
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

  const adapter = new TelegramAdapter();
  const token = resolveEnvValue(config.telegram.bot_token);
  await adapter.connect({
    token,
    chatId: config.telegram.chat_id ? String(config.telegram.chat_id) : undefined,
  });

  await adapter.sendMessage({
    text: "Test notification from claude-hitl-mcp",
    level: "info",
  });

  console.log("Test notification sent");
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

  if (config.telegram?.bot_token) {
    try {
      const token = resolveEnvValue(config.telegram.bot_token);
      const adapter = new TelegramAdapter();
      await adapter.connect({ token });
      console.log("Connection: connected");
      await adapter.disconnect();
    } catch (err) {
      console.log(`Connection: failed — ${err}`);
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
