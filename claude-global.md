## 1. Plan Mode Default
- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately — don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

## 2. Subagent Strategy
- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

## 3. Self-Improvement Loop
- After ANY correction from the user: save as a feedback memory AND update `tasks/lessons.md`
- The feedback memory is authoritative (auto-loaded); `tasks/lessons.md` is the human-readable in-repo record
- Write rules for yourself to prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops

## 4. Verification Before Done
- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

## 5. Demand Elegance (Balanced)
- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes — don't over-engineer
- Challenge your own work before presenting it

## 6. Autonomous Bug Fixing
- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests — then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

## Task Management

1. **Plan First**: Write plan to `tasks/todo.md` or the location specified by the active skill (e.g., `docs/superpowers/plans/`)
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review section to `tasks/todo.md`
6. **Capture Lessons**: Update `tasks/lessons.md` after corrections

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Impact minimal code.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.

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
