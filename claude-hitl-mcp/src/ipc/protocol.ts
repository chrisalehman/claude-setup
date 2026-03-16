export const PROTOCOL_VERSION = 1;

// --- MCP Server → Listener messages ---

export interface RegisterMessage {
  type: "register";
  protocolVersion: number;
  sessionId: string;
  project: string;
  cwd: string;
  worktree?: string;
}

export interface ConfigureMessage {
  type: "configure";
  sessionId: string;
  sessionContext?: string;
  timeoutOverrides?: { architecture?: number; preference?: number };
}

export interface AskMessage {
  type: "ask";
  sessionId: string;
  requestId: string;
  message: string;
  priority: "critical" | "architecture" | "preference";
  options?: Array<{ text: string; description?: string; isDefault?: boolean }>;
  defaultIndex?: number;
  timeoutMinutes?: number;
  context?: string;
}

export interface NotifyMessage {
  type: "notify";
  sessionId: string;
  requestId: string;
  message: string;
  level?: "info" | "success" | "warning" | "error";
  silent?: boolean;
}

export interface DeregisterMessage {
  type: "deregister";
  sessionId: string;
}

export interface ActivityMessage {
  type: "activity";
  sessionId: string;
  toolName: string;
  cwd?: string;
}

export interface BlockedMessage {
  type: "blocked";
  sessionId: string;
  toolName: string;
  toolInput?: string;
  cwd?: string;
}

export type ClientMessage =
  | RegisterMessage
  | ConfigureMessage
  | AskMessage
  | NotifyMessage
  | DeregisterMessage
  | ActivityMessage
  | BlockedMessage;

// --- Listener → MCP Server messages ---

export interface RegisteredMessage {
  type: "registered";
  sessionId: string;
  protocolVersion: number;
}

export interface ResponseMessage {
  type: "response";
  requestId: string;
  text: string;
  selectedIndex?: number;
  isButtonTap: boolean;
}

export interface TimeoutMessage {
  type: "timeout";
  requestId: string;
  defaultIndex?: number;
}

export interface NotifiedMessage {
  type: "notified";
  requestId: string;
  messageId: string;
}

export interface QuietHoursChangedMessage {
  type: "quiet_hours_changed";
  quietHours: {
    enabled: boolean;
    manual: boolean;
    start?: string;
    end?: string;
    timezone?: string;
    behavior?: "skip_preference";
  };
}

export interface ShutdownMessage {
  type: "shutdown";
}

export interface ErrorMessage {
  type: "error";
  requestId?: string;
  code:
    | "unknown_session"
    | "protocol_mismatch"
    | "delivery_failed"
    | "invalid_message"
    | "max_connections";
  message: string;
}

export type ServerMessage =
  | RegisteredMessage
  | ResponseMessage
  | TimeoutMessage
  | NotifiedMessage
  | QuietHoursChangedMessage
  | ShutdownMessage
  | ErrorMessage;

export type IpcMessage = ClientMessage | ServerMessage;

export function serialize(msg: IpcMessage): string {
  return JSON.stringify(msg) + "\n";
}

export function deserialize(line: string): IpcMessage {
  const parsed = JSON.parse(line.trim()) as unknown;
  if (
    parsed === null ||
    typeof parsed !== "object" ||
    !("type" in parsed) ||
    typeof (parsed as Record<string, unknown>).type !== "string"
  ) {
    throw new Error("Invalid IPC message: missing type field");
  }
  return parsed as IpcMessage;
}
