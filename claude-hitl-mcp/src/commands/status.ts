import { readFileSync } from "fs";
import { join } from "path";

export interface StatusSession {
  sessionId: string;
  project: string;
  worktree?: string;
  sessionContext?: string;
  plan: string | null;
  pendingCount: number;
  oldestPendingAge?: number; // seconds since oldest pending question
  lastActivityAge?: number;
  blockedOn?: string;
  blockedAge?: number;
}

export interface StateIndicatorInput {
  lastActivityAge?: number;
  blockedOn?: string;
  blockedAge?: number;
}

export interface StatusButton {
  text: string;
  callbackData: string;
}

export interface StatusResult {
  text: string;
  buttons?: StatusButton[];
}

export interface DisconnectedInfo {
  project: string;
  lastSeen: Date;
}

/**
 * Read _plan.md from a working directory. Returns null if cwd is null or file doesn't exist.
 */
export function readPlanFile(cwd: string | null): string | null {
  if (cwd === null) return null;
  try {
    return readFileSync(join(cwd, "_plan.md"), "utf-8");
  } catch {
    return null;
  }
}

/**
 * Truncate a plan to maxLength characters. If truncated, appends a note.
 */
export function truncatePlan(plan: string, maxLength: number): string {
  if (plan.length <= maxLength) return plan;
  return plan.slice(0, maxLength) + "\n\n… (truncated, full plan in file)";
}

/**
 * Format a duration in seconds as a human-readable age string.
 */
export function formatAge(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  return `${Math.floor(seconds / 3600)}h ago`;
}

/**
 * Return a state indicator string based on activity and blocked status.
 */
export function formatStateIndicator(input: StateIndicatorInput): string {
  const { lastActivityAge, blockedOn, blockedAge } = input;

  if (blockedOn && (blockedAge === undefined || blockedAge <= 60)) {
    return `⚠️ Waiting for permission (${blockedOn})`;
  }

  if (lastActivityAge === undefined) {
    return "No activity data";
  }

  if (lastActivityAge < 30) {
    return `🟢 Active (${formatAge(lastActivityAge)})`;
  }
  if (lastActivityAge <= 120) {
    return `💭 Thinking (${formatAge(lastActivityAge)})`;
  }
  return `💤 Idle (${formatAge(lastActivityAge)})`;
}

/**
 * Build the full detail text for a single session.
 */
export function formatSessionDetail(session: StatusSession): string {
  const lines: string[] = [];

  const headerParts = [session.project];
  if (session.worktree) headerParts.push(`(worktree: ${session.worktree})`);
  lines.push(headerParts.join(" "));

  if (session.sessionContext) {
    lines.push(`Context: ${session.sessionContext}`);
  }

  lines.push("");

  // State indicator
  const state = formatStateIndicator({
    lastActivityAge: session.lastActivityAge,
    blockedOn: session.blockedOn,
    blockedAge: session.blockedAge,
  });
  lines.push(state);

  lines.push("");

  if (session.plan) {
    lines.push(`📋 Plan:\n${truncatePlan(session.plan, 3000)}`);
  } else {
    lines.push("No active plan");
  }

  lines.push("");

  if (session.pendingCount > 0) {
    const plural = session.pendingCount === 1 ? "question" : "questions";
    const agePart =
      session.oldestPendingAge !== undefined
        ? ` (${formatAge(session.oldestPendingAge)})`
        : "";
    lines.push(`⏳ ${session.pendingCount} pending ${plural}${agePart}`);
  } else {
    lines.push("✅ No pending questions");
  }

  return lines.join("\n");
}

/**
 * Format the full /status response for zero, one, or many active sessions.
 */
export function formatStatusMessage(
  sessions: StatusSession[],
  disconnected: DisconnectedInfo[]
): StatusResult {
  // --- No active sessions ---
  if (sessions.length === 0) {
    const lines = ["No active Claude sessions"];

    if (disconnected.length > 0) {
      // Show only the most recently seen disconnected session
      const mostRecent = disconnected.reduce((a, b) =>
        a.lastSeen > b.lastSeen ? a : b
      );
      const ageSeconds = (Date.now() - mostRecent.lastSeen.getTime()) / 1000;
      lines.push("");
      lines.push(
        `Last activity: ${mostRecent.project} disconnected ${formatAge(ageSeconds)}`
      );
    }

    return { text: lines.join("\n") };
  }

  // --- Single session ---
  if (sessions.length === 1) {
    const session = sessions[0];
    const lines = ["📊 Claude Status", ""];
    lines.push(formatSessionDetail(session));
    return { text: lines.join("\n") };
  }

  // --- Multiple sessions ---
  const summaryLines = ["📊 Active Sessions", ""];

  const buttons: StatusButton[] = sessions.map((session, i) => {
    const headerParts = [`#${i + 1} ${session.project}`];
    if (session.worktree) headerParts.push(`(worktree: ${session.worktree})`);
    summaryLines.push(headerParts.join(" "));

    // State indicator (replaces plan first-line in compact view)
    const state = formatStateIndicator({
      lastActivityAge: session.lastActivityAge,
      blockedOn: session.blockedOn,
      blockedAge: session.blockedAge,
    });
    summaryLines.push(`   ${state}`);

    // Pending status
    if (session.pendingCount > 0) {
      const plural = session.pendingCount === 1 ? "question" : "questions";
      const agePart =
        session.oldestPendingAge !== undefined
          ? ` (${formatAge(session.oldestPendingAge)})`
          : "";
      summaryLines.push(`   ⏳ ${session.pendingCount} pending ${plural}${agePart}`);
    } else {
      summaryLines.push("   ✅ No pending questions");
    }

    summaryLines.push("");

    return {
      text: `${session.project} details`,
      callbackData: `status:${session.sessionId}`,
    };
  });

  return { text: summaryLines.join("\n").trimEnd(), buttons };
}
