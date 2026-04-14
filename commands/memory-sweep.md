---
description: Audit and tidy .bionic/memory/ in the current project — orphans, dangling refs, duplicates, oversized rules, stale entries
---

# Memory Sweep

One-pass maintenance of `.bionic/memory/` in the current project. Tidying, not redesign.

The SessionStart hook at `~/.claude/hooks/memory-cleanup.sh` only flags topical files whose `updated:` frontmatter is past 30 days. This command is the on-demand, broader pass: it also catches orphans, dangling references, duplicates, and Always Apply rules that have grown oversized.

## Step 1: Verify

Confirm `.bionic/memory/` exists at the project root. If not, tell the user and stop — don't create one.

## Step 2: Inventory

For every `.md` file in `.bionic/memory/`, note:
- Filename
- `updated:` frontmatter date (if present)
- Whether `INDEX.md` links to it

`INDEX.md` and `context.md` are exempt from the staleness axis but are still subject to every other check below.

## Step 3: Audit along five axes

1. **Orphans** — files in the directory that `INDEX.md` does not link to. Either link them (if still useful) or delete them (if dead).
2. **Dangling references** — links in `INDEX.md` pointing to files that no longer exist. Remove the broken link.
3. **Stale content** — topical files with `updated:` older than 30 days. Spot-check against the current codebase: bump the date if the content is still accurate; rewrite or delete otherwise.
4. **Duplicates** — the same rule or fact stated in two places (e.g., `INDEX.md` Always Apply and a topical file, or two topical files covering overlapping ground). Pick one canonical home and remove the other copy.
5. **Oversized Always Apply entries** — bullets in `INDEX.md` → Always Apply that have grown into multi-paragraph explanations or substantial context. These belong in their own topical file with a one-line pointer left behind in Always Apply.

## Step 4: Propose

Present findings grouped by axis. For each item: one line for the finding, one line for the recommended action. **Do not edit anything yet.** Wait for the user to confirm with "do it all", "skip X", or per-item responses.

## Step 5: Execute

Apply the approved changes. When creating or rewriting a topical file, keep the existing frontmatter shape:

```
---
name: ...
description: ...
updated: YYYY-MM-DD
---
```

Use today's date for any bump.

## Step 6: Report

Summarize what changed in 3–5 bullets. Done.

## Discipline

- If content is still accurate, just bump `updated:` — don't rewrite it.
- Don't reorganize the notebook's taxonomy or invent new rules.
- If relevance is ambiguous, ask the user rather than guessing.
- Scope is `.bionic/memory/` only — do not touch `~/.claude/CLAUDE.md`, hooks, or other config.
