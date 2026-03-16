# Design: ask_human Free-Text Response Awareness

**Date:** 2026-03-16
**Status:** Draft
**Approach:** Description-only change (Approach A) + minor code fix for consistent JSON schema

## Problem

The `ask_human` MCP tool already supports free-text responses at the transport layer — the human can reply with arbitrary text instead of tapping a button, and the response routes correctly through the session manager. However, the MCP tool description doesn't communicate this to Claude, so Claude doesn't know that:

1. The human might ignore the provided options and type something unexpected
2. `selected_option` being absent/null signals a free-text response vs a button tap
3. The `response` field always contains the human's answer regardless of input method

## Design

### Changes Required

**1. Update `ask_human` tool description in `server.ts` (line 52)**

Current:
```
"Send a question to the human and wait for their response. Use priority tiers: critical (irreversible actions), architecture (design decisions), preference (aesthetic choices)."
```

New (draft):
```
"Send a question to the human and wait for their response. Use priority tiers: critical (irreversible actions), architecture (design decisions), preference (aesthetic choices). Always provide options as suggestions, but the human may respond with free text instead of selecting an option. When this happens, selected_option will be null and response will contain their verbatim text. Handle both structured and free-text responses gracefully."
```

**2. Update `options` field description in `server.ts` (line 67)**

Current:
```
"Selectable options with optional default"
```

New:
```
"Suggested options shown as buttons. The human may tap one or ignore them and reply with free text instead."
```

**3. Normalize `selected_option` to explicit `null` in `session-manager.ts`**

In `resolveRequest`, change the response construction so `selected_option` is always present:
```ts
selected_option: selectedIndex ?? null
```

Currently, when `selectedIndex` is `undefined`, the field is omitted entirely from JSON output (`JSON.stringify` drops `undefined` values). This makes Claude's parsing unreliable — a consistent schema with explicit `null` is easier to branch on.

### What Doesn't Change

- `AskHumanResponse` type — no new fields (already allows `null`)
- Transport layer (Telegram adapter, IPC protocol) — already handles free text
- Session manager routing (4-tier: callbackData → replyTo → #N prefix → LIFO) — already works
- `notify_human` and `configure_hitl` — unrelated
- `options` remains optional in the schema

### Test Changes

**Add to `tests/tools.test.ts`:**

A new test case in the `ask_human` describe block that simulates a free-text response when options are provided:

1. Call `askHuman` with options (e.g., "Redis" and "Postgres")
2. Instead of simulating a button tap, simulate a free-text message via the captured `onMessage` handler with `isButtonTap: false` and no `selectedIndex`
3. Assert `result.status === "answered"`
4. Assert `result.response` contains the free text
5. Assert `result.selected_option === null` (explicitly null, not undefined or a number)

**Add to `tests/session-manager.test.ts`:**

A new test case that verifies free-text routing when options were provided to `createRequest`:

1. Create a request with options
2. Route a free-text response (no `callbackData`, no `replyToMessageId`, `isButtonTap: false`)
3. Assert the response resolves with the free text and `selected_option === null`

### Response Format Examples

**Button tap (existing behavior):**
```json
{
  "status": "answered",
  "response": "Postgres",
  "selected_option": 1,
  "response_time_seconds": 12,
  "priority": "preference",
  "timed_out_action": null
}
```

**Free-text override (newly documented behavior):**
```json
{
  "status": "answered",
  "response": "Actually, let's use SQLite for the prototype and migrate later",
  "selected_option": null,
  "response_time_seconds": 45,
  "priority": "preference",
  "timed_out_action": null
}
```

### Edge Cases

- **Free text that matches an option's text:** If the human types "Postgres" instead of tapping the "Postgres" button, the response still routes via LIFO (not callbackData), so `selected_option` will be `null` even though the text matches. This is correct — Claude can compare `response` to option texts if it needs to distinguish.

## Scope

- 2 string changes in `server.ts` (tool description + options field description)
- 1 one-liner in `session-manager.ts` (`selectedIndex ?? null`)
- 1 new test in `tools.test.ts` (free-text response with options provided)
- 1 new test in `session-manager.test.ts` (free-text routing with options)
- 0 new type fields, 0 transport changes, 0 new tools
