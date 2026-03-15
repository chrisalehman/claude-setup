import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { loadConfig, saveConfig, resolveEnvValue } from "./config.js";
import { TelegramAdapter } from "./adapters/telegram.js";

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

const USAGE = `
claude-hitl-mcp — Human-in-the-Loop MCP Server

Usage:
  claude-hitl-mcp              Start MCP server (stdio mode)
  claude-hitl-mcp setup        Interactive first-time setup
  claude-hitl-mcp test         Send a test notification
  claude-hitl-mcp status       Show config and connection status
`;

async function setup() {
  console.log("🔧 claude-hitl setup\n");

  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (!token) {
    console.error("❌ TELEGRAM_BOT_TOKEN environment variable is not set.");
    console.error("\nTo create a bot:");
    console.error("  1. Open Telegram and message @BotFather");
    console.error("  2. Send /newbot and follow the prompts");
    console.error("  3. Copy the token and run:");
    console.error('     export TELEGRAM_BOT_TOKEN="your-token-here"');
    process.exit(1);
  }

  console.log("✓ Found TELEGRAM_BOT_TOKEN in environment");

  // Persist token to ~/.zshrc (idempotent — updates existing or appends)
  persistEnvVar("TELEGRAM_BOT_TOKEN", token);
  console.log("✓ Token persisted to ~/.zshrc");

  const adapter = new TelegramAdapter();
  await adapter.connect({ token });
  console.log("✓ Bot connected");
  console.log("\n→ Open Telegram and send /start to your bot");
  console.log("  Waiting for your message...\n");

  const binding = await adapter.awaitBinding();
  console.log(`✓ Bound to user: ${binding.displayName} (chat_id: ${binding.chatId})`);

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
  console.log("✓ Config written to ~/.claude-hitl.json");

  // Update MCP server env in settings.json so Claude Code can pass the token
  const settingsPath = path.join(os.homedir(), ".claude", "settings.json");
  if (fs.existsSync(settingsPath)) {
    try {
      const settings = JSON.parse(fs.readFileSync(settingsPath, "utf-8"));
      if (settings.mcpServers?.["claude-hitl"]) {
        settings.mcpServers["claude-hitl"].env = {
          ...settings.mcpServers["claude-hitl"].env,
          TELEGRAM_BOT_TOKEN: token,
        };
        fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n", "utf-8");
        console.log("✓ Token added to MCP server config");
      }
    } catch {
      // Best effort — settings.json may not exist yet
    }
  }

  await adapter.sendMessage({
    text: "Claude HITL is connected! You'll receive notifications here when Claude Code needs your input.",
    level: "success",
  });
  console.log("✓ Test notification sent to Telegram");

  await adapter.disconnect();
  console.log("\n✓ Setup complete!");
}

async function test() {
  const config = loadConfig();
  if (!config || !config.telegram) {
    console.error("❌ Not configured. Run: claude-hitl-mcp setup");
    process.exit(1);
  }

  const adapter = new TelegramAdapter();
  const token = resolveEnvValue(config.telegram.bot_token);
  await adapter.connect({
    token,
    chatId: config.telegram.chat_id ? String(config.telegram.chat_id) : undefined,
  });

  await adapter.sendMessage({
    text: "🧪 Test notification from claude-hitl-mcp",
    level: "info",
  });

  console.log("✓ Test notification sent");
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
      console.log("Connection: ✓ connected");
      await adapter.disconnect();
    } catch (err) {
      console.log(`Connection: ✗ ${err}`);
    }
  }
}

async function startServer() {
  await import("./server.js");
}

const command = process.argv[2];

switch (command) {
  case "setup":
    setup().catch((err) => {
      console.error("Setup failed:", err.message);
      process.exit(1);
    });
    break;
  case "test":
    test().catch((err) => {
      console.error("Test failed:", err.message);
      process.exit(1);
    });
    break;
  case "status":
    status().catch((err) => {
      console.error("Status failed:", err.message);
      process.exit(1);
    });
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
