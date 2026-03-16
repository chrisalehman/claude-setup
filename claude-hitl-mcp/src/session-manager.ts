import type {
  AskHumanInput,
  AskHumanResponse,
  InboundMessage,
  PendingRequest,
  Priority,
} from "./types.js";
import { PriorityEngine } from "./priority-engine.js";

export class SessionManager {
  private pending: Map<string, PendingRequest> = new Map();
  private labelMap: Map<string, number> = new Map();
  private labelCounter = 0;
  private requestCounter = 0;
  private timers: Map<string, ReturnType<typeof setTimeout>> = new Map();
  private engine: PriorityEngine;

  constructor(engine?: PriorityEngine) {
    this.engine = engine ?? new PriorityEngine();
  }

  createRequest(
    priority: Priority,
    timeoutMs: number | null,
    options?: AskHumanInput["options"]
  ): { requestId: string; promise: Promise<AskHumanResponse> } {
    const requestId = `req-${++this.requestCounter}`;
    this.labelCounter++;
    this.labelMap.set(requestId, this.labelCounter);

    let resolveRef: (response: AskHumanResponse) => void;
    const promise = new Promise<AskHumanResponse>((resolve) => {
      resolveRef = resolve;
    });

    const request: PendingRequest = {
      requestId,
      messageId: "",
      priority,
      options,
      createdAt: Date.now(),
      timeoutMs,
      resolve: resolveRef!,
    };

    this.pending.set(requestId, request);

    if (timeoutMs !== null && timeoutMs !== undefined) {
      const timer = setTimeout(() => {
        this.handleTimeout(requestId);
      }, timeoutMs);
      this.timers.set(requestId, timer);
    }

    return { requestId, promise };
  }

  setMessageId(requestId: string, messageId: string): void {
    const req = this.pending.get(requestId);
    if (req) req.messageId = messageId;
  }

  getRequestLabel(requestId: string): string {
    const num = this.labelMap.get(requestId);
    return `#${num}`;
  }

  getPendingCount(): number {
    return this.pending.size;
  }

  isRequestPending(requestId: string): boolean {
    return this.pending.has(requestId);
  }

  routeResponse(message: InboundMessage): void {
    // 1. Button tap — route by callbackData (requestId)
    if (message.isButtonTap && message.callbackData) {
      const req = this.pending.get(message.callbackData);
      if (req) {
        this.resolveRequest(req, message.text, message.selectedIndex);
        return;
      }
    }

    // 2. Reply-to-message — match by messageId
    if (message.replyToMessageId) {
      for (const [, req] of this.pending) {
        if (req.messageId === message.replyToMessageId) {
          this.resolveRequest(req, message.text);
          return;
        }
      }
    }

    // 3. Prefixed free-text — "#N response"
    const prefixMatch = message.text.match(/^#(\d+)\s+(.+)$/s);
    if (prefixMatch) {
      const label = parseInt(prefixMatch[1], 10);
      for (const [reqId, req] of this.pending) {
        if (this.labelMap.get(reqId) === label) {
          this.resolveRequest(req, prefixMatch[2].trim());
          return;
        }
      }
    }

    // 4. Unprefixed free-text — LIFO (most recent pending request)
    const entries = [...this.pending.entries()];
    if (entries.length > 0) {
      const [, mostRecent] = entries[entries.length - 1];
      this.resolveRequest(mostRecent, message.text);
    }
  }

  cancelAll(): void {
    for (const [, timer] of this.timers) {
      clearTimeout(timer);
    }
    this.timers.clear();
    for (const [, req] of this.pending) {
      req.resolve({
        status: "error",
        response: "Session cancelled",
        response_time_seconds: Math.round((Date.now() - req.createdAt) / 1000),
        priority: req.priority,
        timed_out_action: null,
      });
    }
    this.pending.clear();
  }

  private resolveRequest(
    req: PendingRequest,
    response: string,
    selectedIndex?: number
  ): void {
    const timer = this.timers.get(req.requestId);
    if (timer) {
      clearTimeout(timer);
      this.timers.delete(req.requestId);
    }
    this.pending.delete(req.requestId);

    req.resolve({
      status: "answered",
      response,
      selected_option: selectedIndex ?? null,
      response_time_seconds: Math.round((Date.now() - req.createdAt) / 1000),
      priority: req.priority,
      timed_out_action: null,
    });
  }

  private handleTimeout(requestId: string): void {
    const req = this.pending.get(requestId);
    if (!req) return;

    this.timers.delete(requestId);
    this.pending.delete(requestId);

    const action = this.engine.getTimeoutAction(req.priority, req.options);

    req.resolve({
      status: "timed_out",
      response: action.response,
      selected_option: action.selectedIndex ?? null,
      response_time_seconds: Math.round((Date.now() - req.createdAt) / 1000),
      priority: req.priority,
      timed_out_action: action.action,
    });
  }
}
