import { PRIORITY_DEFAULTS, type Priority, type AskHumanInput } from "./types.js";

interface QuietHoursConfig {
  start: string;
  end: string;
  timezone: string;
  behavior: "skip_preference";
}

const LEVEL_EMOJI: Record<string, string> = {
  critical: "🚨",
  architecture: "🏗",
  preference: "🎨",
};

const REMINDER_INTERVAL_MS = 15 * 60 * 1000; // 15 minutes

export class PriorityEngine {
  private overrides: Partial<Record<Priority, number | null>> = {};
  private quietHours: QuietHoursConfig | null = null;

  getTimeoutMs(priority: Priority, perRequestMinutes?: number): number | null {
    if (priority === "critical") return null;
    if (perRequestMinutes !== undefined) return perRequestMinutes * 60 * 1000;
    const override = this.overrides[priority];
    if (override !== undefined) return (override as number) * 60 * 1000;
    return (PRIORITY_DEFAULTS[priority] as number) * 60 * 1000;
  }

  setTimeoutOverrides(overrides: Partial<Record<Priority, number | null>>): void {
    // Critical timeout is always null (infinite) — strip any attempt to override it
    const { critical: _, ...rest } = overrides;
    this.overrides = rest;
  }

  getTimeoutAction(
    priority: Priority,
    options?: AskHumanInput["options"]
  ): { action: "used_default" | "paused"; response: string; selectedIndex?: number } {
    if (priority === "preference" && options) {
      const defaultIdx = options.findIndex((o) => o.default);
      if (defaultIdx !== -1) {
        return {
          action: "used_default",
          response: options[defaultIdx].text,
          selectedIndex: defaultIdx,
        };
      }
    }
    return { action: "paused", response: "", selectedIndex: undefined };
  }

  setQuietHours(config: QuietHoursConfig | null): void {
    this.quietHours = config;
  }

  isQuietHours(): boolean {
    if (!this.quietHours) return false;
    const now = new Date();
    const timeStr = now.toLocaleTimeString("en-US", {
      hour12: false,
      hour: "2-digit",
      minute: "2-digit",
      timeZone: this.quietHours.timezone,
    });
    const { start, end } = this.quietHours;
    // Overnight range (e.g. 22:00 – 08:00): active when time >= start OR time < end
    if (start > end) {
      return timeStr >= start || timeStr < end;
    }
    // Same-day range (e.g. 09:00 – 17:00)
    return timeStr >= start && timeStr < end;
  }

  /**
   * Returns true if the given priority should still be delivered during quiet hours.
   * Critical interrupts are always delivered regardless of quiet hours.
   */
  shouldDeliverDuringQuietHours(priority: Priority): boolean {
    return priority === "critical";
  }

  /**
   * Returns true if the request should be auto-resolved (skipped) during quiet hours.
   * Only applies when behavior is "skip_preference" and the priority is "preference".
   */
  shouldAutoResolve(priority: Priority): boolean {
    if (!this.isQuietHours()) return false;
    if (!this.quietHours) return false;
    return this.quietHours.behavior === "skip_preference" && priority === "preference";
  }

  /**
   * Returns a human-readable label for a priority tier, including an emoji indicator
   * and timeout information.
   */
  formatPriorityLabel(priority: Priority): string {
    const emoji = LEVEL_EMOJI[priority] ?? "";
    const timeoutMs = this.getTimeoutMs(priority);
    const timeoutStr =
      timeoutMs === null ? "no timeout" : `${timeoutMs / 60000}m timeout`;
    return `${emoji} ${priority.toUpperCase()} • ${timeoutStr}`;
  }

  /**
   * Returns the reminder polling interval for critical requests (15 min), or null
   * for lower-priority tiers that do not require reminders.
   */
  getReminderIntervalMs(priority: Priority): number | null {
    return priority === "critical" ? REMINDER_INTERVAL_MS : null;
  }
}
