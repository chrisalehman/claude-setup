import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { loadConfig, resolveEnvValue } from "./config.js";
import { TelegramAdapter } from "./adapters/telegram.js";
import { HitlToolHandler } from "./tools.js";
import type { ChatAdapter } from "./types.js";

async function main() {
  const config = loadConfig();

  const server = new McpServer({
    name: "claude-hitl",
    version: "1.0.0",
  });

  // Lazy adapter initialization — don't block MCP handshake with Telegram connection
  let handler: HitlToolHandler | null = null;
  let handlerInitialized = false;

  async function getHandler(): Promise<HitlToolHandler | null> {
    if (handlerInitialized) return handler;
    handlerInitialized = true;

    if (config && config.adapter === "telegram" && config.telegram) {
      try {
        const adapter: ChatAdapter = new TelegramAdapter();
        const token = resolveEnvValue(config.telegram.bot_token);
        await adapter.connect({
          token,
          chatId: config.telegram.chat_id ? String(config.telegram.chat_id) : undefined,
        });
        handler = new HitlToolHandler(adapter);
      } catch {
        // Token missing or connection failed — tools will return error responses
      }
    }
    return handler;
  }

  // Register tools
  server.tool(
    "ask_human",
    "Send a question to the human and wait for their response. Use priority tiers: critical (irreversible actions), architecture (design decisions), preference (aesthetic choices).",
    {
      message: z.string().describe("The question or decision to present"),
      priority: z
        .enum(["critical", "architecture", "preference"])
        .describe("Priority tier"),
      options: z
        .array(
          z.object({
            text: z.string(),
            description: z.string().optional(),
            default: z.boolean().optional(),
          })
        )
        .optional()
        .describe("Selectable options with optional default"),
      context: z.string().optional().describe("Additional context"),
      timeout_minutes: z.number().optional().describe("Override default timeout"),
    },
    async (args) => {
      const h = await getHandler();
      if (!h) {
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                status: "error",
                response:
                  "HITL not configured. Run 'npx claude-hitl-mcp setup' to connect Telegram. Falling back to terminal prompts.",
                response_time_seconds: 0,
                priority: args.priority,
                timed_out_action: null,
              }),
            },
          ],
        };
      }
      const result = await h.askHuman(args);
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    }
  );

  server.tool(
    "notify_human",
    "Send a non-blocking notification to the human. Use for status updates, progress reports, completion notices.",
    {
      message: z.string().describe("The notification message"),
      level: z
        .enum(["info", "success", "warning", "error"])
        .optional()
        .describe("Message level"),
      silent: z.boolean().optional().describe("Suppress push notification"),
    },
    async (args) => {
      const h = await getHandler();
      if (!h) {
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({ status: "error", message_id: "" }),
            },
          ],
        };
      }
      const result = await h.notifyHuman(args);
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    }
  );

  server.tool(
    "configure_hitl",
    "Configure the HITL session. Call at the start of each session to set context and preferences.",
    {
      session_context: z
        .string()
        .optional()
        .describe("Brief description of current work"),
      timeout_overrides: z
        .object({
          architecture: z.number().optional(),
          preference: z.number().optional(),
        })
        .optional()
        .describe("Timeout overrides in minutes"),
    },
    async (args) => {
      const h = await getHandler();
      if (!h) {
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({ status: "error", error: "HITL not configured" }),
            },
          ],
        };
      }
      const result = await h.configureHitl(args);
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    }
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
