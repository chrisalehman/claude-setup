// --- Priority ---

export type Priority = "critical" | "architecture" | "preference";

export const PRIORITY_DEFAULTS: Record<Priority, number | null> = {
  critical: null,       // infinite — never times out
  architecture: 120,    // minutes
  preference: 30,       // minutes
};

// --- Adapter Types ---

export interface UserBinding {
  userId: string;
  displayName: string;
  chatId: string;
}

export interface AdapterConfig {
  token: string;
  chatId?: string;
  [key: string]: unknown;
}

export interface InboundMessage {
  text: string;
  messageId: string;
  isButtonTap: boolean;
  selectedIndex?: number;
  callbackData?: string;
  replyToMessageId?: string;
}

export type MessageHandler = (message: InboundMessage) => void;

export type MessageLevel = "info" | "success" | "warning" | "error";

export interface ChatAdapter {
  readonly name: string;

  connect(config: AdapterConfig): Promise<void>;
  disconnect(): Promise<void>;
  isConnected(): boolean;

  awaitBinding(): Promise<UserBinding>;

  sendMessage(params: {
    text: string;
    level?: MessageLevel;
    silent?: boolean;
  }): Promise<{ messageId: string }>;

  sendInteractiveMessage(params: {
    text: string;
    requestId: string;
    options?: Array<{ text: string; description?: string; isDefault?: boolean }>;
    context?: string;
    priority: Priority;
  }): Promise<{ messageId: string }>;

  editMessage(params: {
    messageId: string;
    text: string;
  }): Promise<void>;

  onMessage(handler: MessageHandler): void;

  sendConfigure?(sessionContext?: string, timeoutOverrides?: { architecture?: number; preference?: number }): void;

  readonly capabilities: {
    inlineButtons: boolean;
    threading: boolean;
    messageEditing: boolean;
    silentMessages: boolean;
    richFormatting: boolean;
  };
}

// --- Tool Input/Output Types ---

export interface AskHumanInput {
  message: string;
  priority: Priority;
  options?: Array<{
    text: string;
    description?: string;
    default?: boolean;
  }>;
  context?: string;
  timeout_minutes?: number;
}

export interface AskHumanResponse {
  status: "answered" | "timed_out" | "error";
  response: string;
  selected_option?: number;
  response_time_seconds: number;
  priority: Priority;
  timed_out_action?: "used_default" | "paused" | null;
}

export interface NotifyHumanInput {
  message: string;
  level?: MessageLevel;
  silent?: boolean;
}

export interface NotifyHumanResponse {
  status: "sent" | "error";
  message_id: string;
}

export interface ConfigureHitlInput {
  session_context?: string;
  timeout_overrides?: {
    critical?: null;
    architecture?: number;
    preference?: number;
  };
}

export interface ConfigureHitlResponse {
  status: "configured" | "error";
  active_config: {
    adapter: string;
    session_context: string;
    timeouts: { critical: null; architecture: number; preference: number };
  };
  error?: string;
}

export interface QuietHoursState {
  enabled: boolean;
  manual: boolean;
  start?: string;
  end?: string;
  timezone?: string;
  behavior?: "skip_preference";
}

// --- Config File Types ---

export interface HitlConfig {
  adapter: string;
  telegram?: {
    bot_token: string;
    chat_id?: number;
  };
  defaults?: {
    timeouts?: {
      architecture?: number;
      preference?: number;
    };
    quiet_hours?: {
      start: string;
      end: string;
      timezone: string;
      behavior: "skip_preference";
    };
  };
}

// --- Session Types ---

export interface PendingRequest {
  requestId: string;
  messageId: string;
  priority: Priority;
  options?: AskHumanInput["options"];
  createdAt: number;
  timeoutMs: number | null;
  resolve: (response: AskHumanResponse) => void;
}
