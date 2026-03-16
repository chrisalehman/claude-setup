export interface QuietState {
  enabled: boolean;
  manual: boolean;
  start?: string;
  end?: string;
  timezone?: string;
  behavior?: "skip_preference";
}

export interface QuietButton {
  text: string;
  callbackData: string;
}

export interface QuietResult {
  text: string;
  buttons: QuietButton[];
}

/**
 * Derives a short timezone abbreviation from an IANA timezone string.
 * Falls back to the raw timezone string if abbreviation extraction fails.
 */
function getTzAbbreviation(timezone: string): string {
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: timezone,
      timeZoneName: "short",
    }).formatToParts(new Date());
    const tzPart = parts.find((p) => p.type === "timeZoneName");
    return tzPart?.value ?? timezone;
  } catch {
    return timezone;
  }
}

/**
 * Formats the current quiet hours state into a display message with action buttons.
 *
 * Three states:
 * - Off: shows bell icon and OFF label, offers Turn On and Set Schedule
 * - On (manual): shows muted icon and ON label with "manually" note, offers Turn Off and Set Schedule
 * - On (scheduled): shows muted icon and ON label with schedule details, offers Turn Off Now and Edit Schedule
 */
export function formatQuietStatus(state: QuietState): QuietResult {
  if (!state.enabled) {
    return {
      text: "\uD83D\uDD14 Quiet hours: OFF",
      buttons: [
        { text: "Turn On", callbackData: "quiet:on" },
        { text: "Set Schedule", callbackData: "quiet:schedule" },
      ],
    };
  }

  if (state.manual) {
    return {
      text: "\uD83D\uDD07 Quiet hours: ON (turned on manually)",
      buttons: [
        { text: "Turn Off", callbackData: "quiet:off" },
        { text: "Set Schedule", callbackData: "quiet:schedule" },
      ],
    };
  }

  // Scheduled on
  const tz = state.timezone ? getTzAbbreviation(state.timezone) : "";
  const scheduleLabel = `${state.start ?? ""}–${state.end ?? ""}${tz ? ` ${tz}` : ""}`;

  return {
    text: `\uD83D\uDD07 Quiet hours: ON (schedule: ${scheduleLabel})`,
    buttons: [
      { text: "Turn Off Now", callbackData: "quiet:off" },
      { text: "Edit Schedule", callbackData: "quiet:schedule" },
    ],
  };
}

/**
 * Handles a button callback action, returning the updated QuietState.
 *
 * - "on"  → enable quiet hours manually, preserving any existing schedule
 * - "off" → disable quiet hours, preserving any existing schedule
 * - any other action → return state unchanged (complex flows handled by the listener)
 */
export function handleQuietAction(action: string, currentState: QuietState): QuietState {
  switch (action) {
    case "on":
      return { ...currentState, enabled: true, manual: true };
    case "off":
      return { ...currentState, enabled: false, manual: false };
    default:
      return currentState;
  }
}
