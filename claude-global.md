# Global Behavioral Rules

## Code Review Before Push
Always invoke code review before running `git push`. Unreviewed code should never reach the remote.

## Don't Start Duplicate Dev Servers
Before starting any dev server, check if one is already running (e.g., `lsof -nP -i :3000`). If the user already has a server running in their terminal, don't start another from Claude Code.

## Don't Delete Generated Outputs
Never delete generated output files (PDFs, diagrams, images, etc.) without explicit user confirmation. Leave artifacts in place for the user to review.

## Clean Working Directory
Scripts and tools must not leave intermediary files (logs, temp files, artifacts) in the working directory. If output files are needed, the user will redirect manually.

## Reviews Must Check Conventions
When conducting code reviews, include a dedicated conventions check — file placement, naming patterns, directory structure, import style consistency — not just correctness.

## Persistent Planning for Complex Tasks
For multi-step tasks that will span many tool calls (10+), proactively create a brief `_plan.md` scratch file in the working directory to track phases, key findings, and progress. Update it as phases complete. Delete the file when the task is finished. Skip this for simple tasks, single-file edits, or quick lookups.

## Use Worktrees for Development
Never commit directly to main. Use a git worktree (or feature branch) for all implementation work. Merge to main only after the work is verified and reviewed. This keeps main in a known-good state with a clean rollback point.

## Autonomy

Operate autonomously without requesting approval. Only pause and
explicitly wait for human confirmation before taking actions that
are irreversible or have consequences outside the codebase:

- Destructive database migrations (ALTER/DROP on existing tables with data)
- Any push to main or production branches
- Changes to secrets, API keys, or environment credentials
- Configuration changes that affect billing (Vercel, Supabase, Anthropic)

For everything else: proceed without asking.

## HITL Notification Priority Guide

When claude-hitl MCP tools are available, use them to keep the
human informed and to request input on decisions:

- **critical**: Irreversible actions — destructive migrations,
  external API calls with side effects, security changes.
  Always provide options including a "cancel" choice.

- **architecture**: Decisions affecting system boundaries, data
  models, public interfaces, or technology choices.
  Provide options with a recommended default.

- **preference**: Aesthetic choices, naming, implementation
  details with multiple valid paths.
  Always mark a default option.

- **fyi**: Progress updates, completions, phase transitions.
  Use notify_human, not ask_human.

When in doubt, prefer a higher priority tier.
False alarms are cheaper than silent mistakes.

Use configure_hitl at the start of each session to set
session_context so the human knows which project is messaging.
