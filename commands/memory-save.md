---
description: Manually checkpoint .bionic/memory/ — update context.md with current branch/session state, add INDEX.md rules for any lesson that emerged
---

# Memory Save

On-demand memory save. Use when you want a checkpoint mid-session — before a risky operation, after a significant decision, or when you're about to walk away. Complement to the automatic `SessionEnd` save (normal session endings) and the `/memory-sweep` audit (periodic cleanup).

## What to save

Follow the protocol in `~/.claude/CLAUDE.md` under "Keep a project notebook" and "auto memory":

1. **`context.md`** — update with current branch, what changed this session, and next steps. Bump `updated:` frontmatter to today.
2. **`INDEX.md` → Always Apply** — if any correction, lesson, or durable rule emerged this session, add a one-liner. Use the body structure from CLAUDE.md: rule, then **Why:** and **How to apply:** for feedback-type memories.
3. **Topical files** — if a substantial topic deserves its own memory, create or update `<topic>.md` with the standard frontmatter (`name`, `description`, `type`, `updated:`). Add a one-line pointer in `INDEX.md` under "Deep Context."

## Discipline

- **Minimal edits only.** If nothing meaningful to save, respond with "memory already current." and do not edit anything.
- **Don't duplicate.** Check existing memory before writing new entries — update in place rather than creating new files that overlap.
- **Convert relative dates.** "Today," "yesterday," "last Thursday" → absolute dates before writing.
- **Don't save ephemeral state.** Current conversation context, in-progress debug output, and code-derivable facts (file paths, conventions, git state) do not go in memory.
- **Scope is `.bionic/memory/` only.** Do not touch `~/.claude/CLAUDE.md`, hooks, or other config.

## When to report

After saving, summarize in 1–3 bullets what was added or updated. If nothing qualified, just say "memory already current."
