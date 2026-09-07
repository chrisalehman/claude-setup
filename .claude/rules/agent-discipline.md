---
paths:
  - "**/*.sh"
  - "**/*.md"
---

# Agent-behavior discipline

How Claude should operate in this codebase — authoring instruction files, dispatching
subagents, and choosing between overlapping skills. Migrated from
`.bionic/memory/agent-rules.md` (epic-12 wave-01 slice 6) with the correction ledger applied.

**Routing note (slice 6 judgment call).** This is the weakest path-glob *fit* of the rules
files — most of it fires regardless of which file is being touched — and it is here because
`.claude/rules/` is the only channel measured to reach a dispatched subagent. *(Corrected
2026-08-18, epic-17 W4 S3: no longer the only one. A role file under `~/.claude/agents/`
reaches a dispatched agent too — measured by live readback — but it is snapshotted at CLI
start, so an edit lands on the NEXT session while this file lands on the next read. That
timing difference, not reach, is now what decides which channel a rule belongs in.)* Project
`CLAUDE.md` was measured **absent** from a fresh subagent this session despite being committed
before dispatch; auto-memory measures present but contradicts its own documentation, so the
wave forbids depending on it (assumption 3). Auto-memory is a legitimate destination for the
main thread's own recall — it is not a delivery guarantee, and nothing here is justified by it.

The globs are deliberately broad. Bionic is a shell-and-markdown repo, so `**/*.sh` +
`**/*.md` is close to "any work in this tree" — an imperfect glob on a proven channel beats a
clean glob on an unproven one. This is pay-per-read, not pay-per-session: nothing here loads
at session start, so AC-2 is unaffected. The cost is ~8 KB whenever a matching file is read.

## Discourse and judgment

- **Instruction files for Claude** (skills, agent prompts, path-scoped rules like this one):
  sentences naming Claude's default failure modes are TRIGGERS, not elaboration. "Obvious to a senior
  engineer" is the wrong rubric — the audience is the model, which needs the guardrail.
  Example: "Hypotheses without data produce circular debugging" earns its place because Claude
  defaults to hypothesis-patching without measuring, even though a human reader would already
  know that.

## Subagent dispatch

> **Moved (epic-17 W4, 2026-08-18).** Foreground-first and poll-don't-watch now live in
> `agents-src/blocks/survival.md`, rendered into all six `agents/*.md` role files, so a
> dispatched agent carries them in its own role definition instead of reading them here.
> Live readback and the propagation measurement: `.bionic/docs/record/epic-17-w4/s3-report.md`.
> What stays below is addressed to whoever writes the brief, which no role file can reach.

## Skill-creator pitfalls

- **`example-skills:skill-creator`'s `improve_description.py` is NOT a standalone tool** —
  it's a function inside `run_loop.py` that requires eval results as input. "Run just the
  description optimizer without the eval loop" is not a thing; the optimizer IS the loop.
  `run_loop.py` also creates UUID-suffixed test command files in `.claude/commands/` that need
  manual cleanup (`rm canonical-sdlc-skill-*.md` pattern) if aborted mid-run.
