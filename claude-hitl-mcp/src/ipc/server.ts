import * as net from "node:net";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  type ClientMessage,
  type ServerMessage,
  type IpcMessage,
  type ConfigureMessage,
  type RegisterMessage,
  type ActivityMessage,
  type BlockedMessage,
  PROTOCOL_VERSION,
  serialize,
  deserialize,
} from "./protocol.js";

export interface SessionInfo {
  sessionId: string;
  project: string;
  cwd: string | null;
  worktree?: string;
  sessionContext?: string;
  timeoutOverrides?: { architecture?: number; preference?: number };
  connectedAt: Date;
  socket: net.Socket;
  lastActivityAt?: Date;
  lastActivityTool?: string;
  blockedOn?: string;
  blockedAt?: Date;
}

export interface DisconnectedSessionInfo {
  sessionId: string;
  project: string;
  cwd: string | null;
  worktree?: string;
  sessionContext?: string;
  connectedAt: Date;
  lastSeenAt: Date;
}

export interface IpcServerOptions {
  maxConnections: number;
}

type MessageHandler = (session: SessionInfo, message: ClientMessage) => void;

function validateCwd(cwd: string): string | null {
  const home = os.homedir();
  // Normalize paths for comparison
  const normalizedCwd = path.resolve(cwd);
  const normalizedHome = path.resolve(home);
  if (
    normalizedCwd === normalizedHome ||
    normalizedCwd.startsWith(normalizedHome + path.sep)
  ) {
    return normalizedCwd;
  }
  return null;
}

export class IpcServer {
  private readonly socketPath: string;
  private readonly options: IpcServerOptions;
  private server: net.Server | null = null;
  private sessions: Map<string, SessionInfo> = new Map();
  private socketToSessionId: Map<net.Socket, string> = new Map();
  private allSockets: Set<net.Socket> = new Set();
  private disconnectedSessions: Map<string, DisconnectedSessionInfo> =
    new Map();
  private messageHandler: MessageHandler | null = null;

  constructor(socketPath: string, options: IpcServerOptions) {
    this.socketPath = socketPath;
    this.options = options;
  }

  onMessage(handler: MessageHandler): void {
    this.messageHandler = handler;
  }

  async start(): Promise<void> {
    // Remove stale socket file if it exists
    try {
      fs.unlinkSync(this.socketPath);
    } catch {
      // File didn't exist — that's fine
    }

    return new Promise((resolve, reject) => {
      this.server = net.createServer((socket) => {
        this.handleConnection(socket);
      });

      this.server.on("error", reject);

      this.server.listen(this.socketPath, () => {
        resolve();
      });
    });
  }

  async stop(): Promise<void> {
    // Send shutdown to all connected sessions
    const shutdownMsg = serialize({ type: "shutdown" } satisfies ServerMessage);
    for (const session of this.sessions.values()) {
      try {
        session.socket.write(shutdownMsg);
      } catch {
        // Ignore errors during shutdown
      }
    }

    // Destroy all sockets (including pre-registration ones)
    for (const socket of this.allSockets) {
      try {
        socket.destroy();
      } catch {
        // Ignore
      }
    }

    this.sessions.clear();
    this.socketToSessionId.clear();
    this.allSockets.clear();

    return new Promise((resolve) => {
      if (!this.server) {
        resolve();
        return;
      }
      this.server.close(() => {
        try {
          fs.unlinkSync(this.socketPath);
        } catch {
          // Already removed
        }
        resolve();
      });
    });
  }

  getSessions(): SessionInfo[] {
    return Array.from(this.sessions.values());
  }

  getDisconnectedSessions(): DisconnectedSessionInfo[] {
    return Array.from(this.disconnectedSessions.values());
  }

  sendToSession(sessionId: string, message: ServerMessage): boolean {
    const session = this.sessions.get(sessionId);
    if (!session) {
      return false;
    }
    try {
      session.socket.write(serialize(message));
      return true;
    } catch {
      return false;
    }
  }

  broadcastAll(message: ServerMessage): void {
    const line = serialize(message);
    for (const session of this.sessions.values()) {
      try {
        session.socket.write(line);
      } catch {
        // Ignore per-socket errors during broadcast
      }
    }
  }

  private handleConnection(socket: net.Socket): void {
    this.allSockets.add(socket);
    socket.on("close", () => this.allSockets.delete(socket));

    const activeCount = this.sessions.size;

    if (activeCount >= this.options.maxConnections) {
      const errorMsg: ServerMessage = {
        type: "error",
        code: "max_connections",
        message: `Server has reached the maximum number of connections (${this.options.maxConnections})`,
      };
      // Use end() so the data is flushed before the connection closes
      socket.write(serialize(errorMsg), () => {
        socket.end();
      });
      return;
    }

    let buffer = "";

    socket.on("data", (chunk: Buffer) => {
      buffer += chunk.toString("utf8");
      const lines = buffer.split("\n");
      // Last element may be an incomplete line
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        this.handleLine(socket, trimmed);
      }
    });

    socket.on("close", () => {
      this.handleSocketClose(socket, false);
    });

    socket.on("error", () => {
      this.handleSocketClose(socket, false);
    });
  }

  private handleLine(socket: net.Socket, line: string): void {
    let msg: IpcMessage;
    try {
      msg = deserialize(line);
    } catch {
      const errorMsg: ServerMessage = {
        type: "error",
        code: "invalid_message",
        message: "Failed to parse message",
      };
      try {
        socket.write(serialize(errorMsg));
      } catch {
        // Socket may be dead
      }
      return;
    }

    const sessionId = this.socketToSessionId.get(socket);

    if (msg.type === "register") {
      this.handleRegister(socket, msg as RegisterMessage);
      return;
    }

    if (msg.type === "deregister") {
      this.handleSocketClose(socket, true);
      return;
    }

    if (msg.type === "configure") {
      this.handleConfigure(socket, msg as ConfigureMessage);
      return;
    }

    // Forward other messages to handler
    if (sessionId) {
      const session = this.sessions.get(sessionId);
      if (session && this.messageHandler) {
        this.messageHandler(session, msg as ClientMessage);
      }
    } else if (msg.type === "activity" || msg.type === "blocked") {
      const hookMsg = msg as ActivityMessage | BlockedMessage;
      // Try exact session ID match first, then fall back to cwd match.
      // Hook scripts send Claude Code's internal session ID, which differs
      // from the MCP server's random UUID used at registration.
      let session = this.sessions.get(hookMsg.sessionId);
      if (!session && hookMsg.cwd) {
        for (const s of this.sessions.values()) {
          if (s.cwd && hookMsg.cwd.startsWith(s.cwd)) {
            session = s;
            break;
          }
        }
      }
      if (session) {
        if (hookMsg.type === "activity") {
          session.lastActivityAt = new Date();
          session.lastActivityTool = hookMsg.toolName;
          session.blockedOn = undefined;
          session.blockedAt = undefined;
        } else {
          session.blockedOn = hookMsg.toolName;
          session.blockedAt = new Date();
          session.lastActivityAt = new Date();
          session.lastActivityTool = hookMsg.toolName;
        }
        if (this.messageHandler) {
          this.messageHandler(session, hookMsg);
        }
      }
      socket.destroy();
    }
  }

  private handleRegister(socket: net.Socket, msg: RegisterMessage): void {
    if (msg.protocolVersion !== PROTOCOL_VERSION) {
      const errorMsg: ServerMessage = {
        type: "error",
        code: "protocol_mismatch",
        message: `Protocol version mismatch: expected ${PROTOCOL_VERSION}, got ${msg.protocolVersion}`,
      };
      socket.write(serialize(errorMsg));
      socket.destroy();
      return;
    }

    const validatedCwd = validateCwd(msg.cwd);

    const session: SessionInfo = {
      sessionId: msg.sessionId,
      project: msg.project,
      cwd: validatedCwd,
      worktree: msg.worktree,
      connectedAt: new Date(),
      socket,
    };

    this.sessions.set(msg.sessionId, session);
    this.socketToSessionId.set(socket, msg.sessionId);
    console.error(`[ipc] Session registered: ${msg.sessionId.slice(0, 8)}… project=${msg.project} cwd=${validatedCwd} (total: ${this.sessions.size})`);

    // Remove from disconnected if reconnecting
    this.disconnectedSessions.delete(msg.sessionId);

    const ack: ServerMessage = {
      type: "registered",
      sessionId: msg.sessionId,
      protocolVersion: PROTOCOL_VERSION,
    };
    socket.write(serialize(ack));
  }

  private handleConfigure(socket: net.Socket, msg: ConfigureMessage): void {
    const sessionId = this.socketToSessionId.get(socket);
    if (!sessionId) return;
    const session = this.sessions.get(sessionId);
    if (!session) return;

    if (msg.sessionContext !== undefined) {
      session.sessionContext = msg.sessionContext;
    }
    if (msg.timeoutOverrides !== undefined) {
      session.timeoutOverrides = msg.timeoutOverrides;
    }
  }

  private handleSocketClose(socket: net.Socket, graceful: boolean): void {
    const sessionId = this.socketToSessionId.get(socket);
    if (!sessionId) return;

    const session = this.sessions.get(sessionId);
    console.error(`[ipc] Session disconnected: ${sessionId.slice(0, 8)}… project=${session?.project} graceful=${graceful} (remaining: ${this.sessions.size - 1})`);
    this.sessions.delete(sessionId);
    this.socketToSessionId.delete(socket);

    if (!graceful && session) {
      // Record as disconnected with last seen timestamp
      const disconnected: DisconnectedSessionInfo = {
        sessionId: session.sessionId,
        project: session.project,
        cwd: session.cwd,
        worktree: session.worktree,
        sessionContext: session.sessionContext,
        connectedAt: session.connectedAt,
        lastSeenAt: new Date(),
      };
      this.disconnectedSessions.set(sessionId, disconnected);
    }
    // Graceful deregister: no disconnected record kept
  }
}
