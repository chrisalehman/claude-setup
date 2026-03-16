import * as os from "node:os";
import * as path from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { loadConfig, resolveEnvValue } from "./config.js";
import { createAdapter } from "./adapters/factory.js";
import { HitlToolHandler } from "./tools.js";

async function main() {
  const config = loadConfig();

  const server = new McpServer({
    name: "claude-hitl",
    version: "1.0.0",
  });

  // Adapter initialization — connects to listener eagerly so /status works,
  // but doesn't block the MCP handshake (runs after server.connect).
  let handler: HitlToolHandler | null = null;
  let handlerReady: Promise<HitlToolHandler | null> | null = null;

  function initHandler(): Promise<HitlToolHandler | null> {
    if (handlerReady) return handlerReady;
    handlerReady = (async () => {
      if (config && config.adapter === "telegram" && config.telegram) {
        try {
          const socketPath = path.join(os.homedir(), ".claude-hitl", "sock");
          const adapter = createAdapter(socketPath);
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
    })();
    return handlerReady;
  }

  async function getHandler(): Promise<HitlToolHandler | null> {
    return initHandler();
  }

  // Register tools
  server.tool(
    "ask_human",
    "Send a question to the human and wait for their response. Use priority tiers: critical (irreversible actions), architecture (design decisions), preference (aesthetic choices). Always provide options as suggestions, but the human may respond with free text instead of selecting an option. When this happens, selected_option will be null and response will contain their verbatim text. Handle both structured and free-text responses gracefully.",
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
        .describe("Suggested options shown as buttons. The human may tap one or ignore them and reply with free text instead."),
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

  // Register with the listener eagerly so /status shows this session
  // immediately, not only after the first tool call.
  initHandler().catch(() => {
    // Silently ignore — tools will handle the missing handler gracefully
  });
}

main().catch(console.error);
