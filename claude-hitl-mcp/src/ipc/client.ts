import * as net from "node:net";
import {
  type ServerMessage,
  type IpcMessage,
  type AskMessage,
  type NotifyMessage,
  type ConfigureMessage,
  PROTOCOL_VERSION,
  serialize,
  deserialize,
} from "./protocol.js";

const BACKOFF_INITIAL_MS = 1000;
const BACKOFF_MAX_MS = 30000;
const BACKOFF_MULTIPLIER = 2;

type ServerMessageHandler = (message: ServerMessage) => void;

export class IpcClient {
  private readonly socketPath: string;
  private socket: net.Socket | null = null;
  private connected = false;
  private intentionalDisconnect = false;

  // Registration params saved for reconnection
  private sessionId: string | null = null;
  private project: string | null = null;
  private cwd: string | null = null;
  private worktree: string | undefined = undefined;

  private messageHandler: ServerMessageHandler | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private currentBackoffMs = BACKOFF_INITIAL_MS;
  private buffer = "";

  constructor(socketPath: string) {
    this.socketPath = socketPath;
  }

  isConnected(): boolean {
    return this.connected;
  }

  onMessage(handler: ServerMessageHandler): void {
    this.messageHandler = handler;
  }

  async connect(
    sessionId: string,
    project: string,
    cwd: string,
    worktree?: string
  ): Promise<void> {
    this.intentionalDisconnect = false;
    this.sessionId = sessionId;
    this.project = project;
    this.cwd = cwd;
    this.worktree = worktree;
    this.currentBackoffMs = BACKOFF_INITIAL_MS;

    await this.doConnect();
  }

  private doConnect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection(this.socketPath);
      this.socket = socket;
      this.buffer = "";

      let settled = false;

      const fail = (err: Error) => {
        if (settled) return;
        settled = true;
        reject(err);
      };

      socket.on("error", (err) => {
        if (!settled) {
          fail(err);
        } else {
          // Post-connection error — handle as disconnect
          this.handleDisconnect();
        }
      });

      socket.on("connect", () => {
        // Send register message
        const regMsg = {
          type: "register" as const,
          protocolVersion: PROTOCOL_VERSION,
          sessionId: this.sessionId!,
          project: this.project!,
          cwd: this.cwd!,
          ...(this.worktree ? { worktree: this.worktree } : {}),
        };
        socket.write(serialize(regMsg));
      });

      socket.on("data", (chunk: Buffer) => {
        this.buffer += chunk.toString("utf8");
        const lines = this.buffer.split("\n");
        this.buffer = lines.pop() ?? "";

        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;

          let msg: IpcMessage;
          try {
            msg = deserialize(trimmed);
          } catch {
            continue;
          }

          if (!settled && msg.type === "registered") {
            settled = true;
            this.connected = true;
            this.currentBackoffMs = BACKOFF_INITIAL_MS;
            resolve();
            continue;
          }

          if (!settled && msg.type === "error") {
            fail(new Error(`${msg.code}: ${msg.message}`));
            socket.destroy();
            continue;
          }

          if (msg.type === "shutdown") {
            // Trigger reconnection without marking as intentional
            this.connected = false;
            socket.destroy();
            if (!this.intentionalDisconnect) {
              this.scheduleReconnect();
            }
            continue;
          }

          // Deliver all other server messages
          if (this.messageHandler) {
            this.messageHandler(msg as ServerMessage);
          }
        }
      });

      socket.on("end", () => {
        // Server half-closed — process any remaining buffered data
        if (this.buffer.trim()) {
          const line = this.buffer.trim();
          this.buffer = "";
          try {
            const msg = deserialize(line);
            if (!settled && msg.type === "error") {
              fail(new Error(`${msg.code}: ${msg.message}`));
              return;
            }
          } catch {
            // Ignore unparseable trailing data
          }
        }
      });

      socket.on("close", () => {
        if (!settled) {
          fail(new Error("Socket closed before registration completed"));
          return;
        }
        this.handleDisconnect();
      });
    });
  }

  private handleDisconnect(): void {
    if (!this.connected) return;
    this.connected = false;
    if (!this.intentionalDisconnect) {
      this.scheduleReconnect();
    }
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) return;
    if (this.intentionalDisconnect) return;

    const delay = this.currentBackoffMs;
    this.currentBackoffMs = Math.min(
      this.currentBackoffMs * BACKOFF_MULTIPLIER,
      BACKOFF_MAX_MS
    );

    this.reconnectTimer = setTimeout(async () => {
      this.reconnectTimer = null;
      if (this.intentionalDisconnect) return;

      try {
        await this.doConnect();
      } catch {
        // Schedule another attempt
        this.scheduleReconnect();
      }
    }, delay);
  }

  async disconnect(): Promise<void> {
    this.intentionalDisconnect = true;

    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }

    if (this.socket && this.connected) {
      const deregMsg = {
        type: "deregister" as const,
        sessionId: this.sessionId!,
      };
      await new Promise<void>((resolve) => {
        try {
          this.socket!.write(serialize(deregMsg), () => {
            this.socket!.destroy();
            resolve();
          });
        } catch {
          this.socket?.destroy();
          resolve();
        }
      });
    } else {
      this.socket?.destroy();
    }

    this.connected = false;
    this.socket = null;
  }

  sendConfigure(
    sessionContext?: string,
    timeoutOverrides?: ConfigureMessage["timeoutOverrides"]
  ): void {
    const msg: ConfigureMessage = {
      type: "configure",
      sessionId: this.sessionId!,
      ...(sessionContext !== undefined ? { sessionContext } : {}),
      ...(timeoutOverrides ? { timeoutOverrides } : {}),
    };
    this.send(msg);
  }

  sendAsk(
    requestId: string,
    message: string,
    priority: AskMessage["priority"],
    options?: AskMessage["options"],
    defaultIndex?: number,
    timeoutMinutes?: number,
    context?: string
  ): void {
    const msg: AskMessage = {
      type: "ask",
      sessionId: this.sessionId!,
      requestId,
      message,
      priority,
      ...(options ? { options } : {}),
      ...(defaultIndex !== undefined ? { defaultIndex } : {}),
      ...(timeoutMinutes !== undefined ? { timeoutMinutes } : {}),
      ...(context ? { context } : {}),
    };
    this.send(msg);
  }

  sendNotify(
    requestId: string,
    message: string,
    level?: NotifyMessage["level"],
    silent?: boolean
  ): void {
    const msg: NotifyMessage = {
      type: "notify",
      sessionId: this.sessionId!,
      requestId,
      message,
      ...(level !== undefined ? { level } : {}),
      ...(silent !== undefined ? { silent } : {}),
    };
    this.send(msg);
  }

  private send(msg: IpcMessage): void {
    if (!this.socket || !this.connected) {
      throw new Error("Not connected");
    }
    this.socket.write(serialize(msg));
  }
}
