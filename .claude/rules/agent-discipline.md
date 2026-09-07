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

## Mechanics

- **Re-read code after editing, especially when moving patterns between contexts.** It's easy
  to lose track of what a file actually says after a sequence of Edit calls; verify by reading.

- **Any refactor must discover ALL test suites, not just the default command.** Before trusting
  a green run as a refactor's safety net — your own or a delegated skill's — confirm the
  discovery step actually enumerated every test entry point: `bash tests/run.sh`, plus any
  standalone `*.test.sh` it does not reach, plus any `package.json` scripts. In this repo
  `tests/run.sh`'s roster is derived from `tests/*.test.sh` at run time (fixit 1.5.1, D-1) —
  a new suite gates on the very next run, and the roster wall refuses anything the glob
  matches that isn't shaped like a suite.

## Discourse and judgment

- **Instruction files for Claude** (skills, agent prompts, path-scoped rules like this one):
  sentences naming Claude's default failure modes are TRIGGERS, not elaboration. "Obvious to a senior
  engineer" is the wrong rubric — the audience is the model, which needs the guardrail.
  Example: "Hypotheses without data produce circular debugging" earns its place because Claude
  defaults to hypothesis-patching without measuring, even though a human reader would already
  know that.

- **When asked "is this idea good?" or "help me refine this," evaluate the literal proposal on
  its merits BEFORE offering alternative framings.** Jumping to "you're actually asking two
  different things" can feel like dodging the question in conceptual design discussions.
  Reframings come after direct engagement with what the user actually said, not instead of it —
  and if the first answer misses the target, the second should answer the literal question, not
  defend the first reframing.

- **Agent outputs that claim "the docs explicitly state X"** (or any other
  verbatim-quote-from-authoritative-source assertion) must be verified against the primary
  source before acting on them, especially when stakes are material (file changes,
  infrastructure modifications, hook/config swaps). During the 2026-04-11 Stop-hook-label
  investigation the `claude-code-guide` agent fabricated a verbatim docs quote that did not
  exist in the actual docs page; catching it required a direct WebFetch. Treat agent "quotes"
  as leads, not facts.

## Subagent dispatch

> **Moved (epic-17 W4, 2026-08-18).** Foreground-first and poll-don't-watch now live in
> `agents-src/blocks/survival.md`, rendered into all six `agents/*.md` role files, so a
> dispatched agent carries them in its own role definition instead of reading them here.
> Live readback and the propagation measurement: `.bionic/docs/record/epic-17-w4/s3-report.md`.
> What stays below is addressed to whoever writes the brief, which no role file can reach.

- **Backgrounding gets DECLARED in the brief** (2026-08-06, epic-15 wave-04 D3,
  user-ratified). When work genuinely exceeds 10 minutes or must run alongside other work,
  the dispatch brief MUST declare it (`claims=` process pattern + output file) so it lands
  on the session roster the landing verdict later reads. *(Amended 2026-08-11, epic-16
  wave-02 S1: the resident sweeper that "watched" a claimed process is deleted. Declaring
  `claims=` still matters — it is what lets the verdict call a mid-flight row STILL-LIVE
  instead of UNMET — but nothing is watching it between decisions.)* This channel is advisory only — no bionic machinery relies on this file
  existing (zero field-reliance, user-ratified 2026-08-06).

- **Normative values ship as VERBATIM tables in dispatch briefs, never paraphrase**
  (2026-07-18, epic-07 wave 1). Two competent opus implementers resolved the same spec
  ambiguity (critic placement in the rigor ladder) in OPPOSITE directions because the tier→gate
  mapping lived in prose paraphrase; the D1/D4 tables embedded verbatim in the plan had zero
  drift. Where a value matters, the implementer copies a table — they don't interpret a
  sentence. Corollary: after correcting any such value, grep EVERY artifact that restates it
  (ADR ledgers, spec tables, evidence blocks) — decision records drift independently of the
  prose they record, and single-document review sweeps miss them.

- **Subagents that idle without delivering: one demand-ping for READERS, direct
  tree-verification for WRITERS.** (2026-07-15, epic-02.) Agents frequently go idle without
  sending their final report. For read-only agents (reviewers, critics), one SendMessage demand
  usually shakes the report loose; re-dispatch fresh under a NEW name if a lineage stays mute —
  re-dispatching pays the whole review again, so ping first. For WRITE agents, do NOT ping — a
  message to an idle agent resumes a fresh instance from its transcript, and two instances of
  the same writer will collide on the shared tree (observed: interleaved edits +
  checkout-reverts). Instead verify the tree directly (`git status` / `git show --stat`),
  finish or commit the work from the orchestrator, and stand the lineage down with at most one
  final message. Check for a duplicate USER session first.

  *(Correction 2026-07-27: an earlier, separate bullet in the source file stated the rule
  without the reader/writer split — "don't re-dispatch, SendMessage the same agent" applied to
  all named agents. That is wrong for writers and is superseded by the text above. The two
  bullets have been merged; only this version is live.)*

- **`CLAUDE_CODE_FORK_SUBAGENT=1` does NOT enable fork inheritance for Agent dispatches** as of
  2026-04-25, even post-restart. First test mid-session: env var propagated to Bash
  subprocesses (`env | grep` shows `=1`) but sentinel/topic recall both returned `NO_CONTEXT`;
  hypothesized restart-required. Second test in a fresh session post-restart: setup checks
  still pass, sentinel recall still returns `NO_CONTEXT`. Restart alone is not the missing
  piece — mechanism unknown (possibly per-agent opt-in, a different env name, version-gated,
  or the third-party report was wrong). Do NOT rely on shorter briefings to subagents.
  Validation protocol at `.bionic/tests/fork-subagent.md`; re-run before assuming fork ever
  activates. The independence concern (review/critique poisoning) is moot until inheritance is
  actually demonstrated.

- **Multi-iteration excalidraw diagram authoring should be dispatched, not done on the main
  thread.** The `excalidraw-diagram` skill mandates a render → Read PNG → fix-JSON → re-render
  loop (typically 2–4 iterations per diagram). Each iteration adds a multi-hundred-KB PNG read
  to context plus a JSON edit cycle. Dispatching keeps the main thread clean and returns a
  single completion notification. Validated 2026-05-03: two diagrams dispatched in parallel,
  ~7 and ~12 minutes each, returned final paths + judgment-call summaries. *(2026-07-15
  amendment: a FRESH `model: opus` agent with a fully self-contained brief — target files,
  content spec, render-loop instruction, known CDN-drift fix — is a validated, cheaper
  alternative to a fork; epic-02's two-diagram regen delivered in 1–2 iterations per diagram
  this way. Prefer fresh-with-brief under a Fable orchestrator, where forks cost ~2× Opus and
  re-pay the whole main context.)* The pattern generalizes to any visual-validation work where
  the "did the rendered output match my intent" judgment requires reading the rendered artifact.

## Skill-creator pitfalls

- **`example-skills:skill-creator`'s `improve_description.py` is NOT a standalone tool** —
  it's a function inside `run_loop.py` that requires eval results as input. "Run just the
  description optimizer without the eval loop" is not a thing; the optimizer IS the loop.
  `run_loop.py` also creates UUID-suffixed test command files in `.claude/commands/` that need
  manual cleanup (`rm canonical-sdlc-skill-*.md` pattern) if aborted mid-run.

## Skill precedence

- **When `agent-skills:idea-refine` and `superpowers:brainstorming` could both fire, always
  prefer `idea-refine`.** Durable user preference set 2026-04-13 during canonical-sdlc design.
  Applies across all creative/pre-spec phases.

- **Design work routes to `impeccable` only.** `frontend-design@claude-plugins-official` and
  `ui-ux-pro-max@ui-ux-pro-max-skill` were evaluated 2026-04-18 and removed. `impeccable`
  (`pbakaus/impeccable`) is a properly-attributed Apache-2.0 superset of `frontend-design`;
  `ui-ux-pro-max` had open scam complaints on its paid tier (GitHub Issue #161). Do NOT
  re-install either without re-running the research + updating this rule. Sibling skills like
  `animate`, `polish`, `audit`, `critique`, `bolder` are part of the impeccable pack, not
  frontend-design.

**`/clear` does not kill agents.** A cleared session loses its own memory of a fleet, never
the fleet: the agents keep running, their rosters stay on disk, and
`bash <plugin-root>/hooks/session-poker.sh adopt` is what reads them back. The bare teammate
name is the address that survives — `SendMessage` to `<name>` still reaches a live teammate
across the clear, while the long transcript id is the observe address and never a delivery
one. Re-dispatch waits for adopt's verdict: a name adopt reports as still running is a
teammate to message, not a slot to refill, and dispatching over it is how one task ends up
with two writers and one of them unledgered. Dispatch itself is never yours: it is the orchestrator's authority alone, so when you need a helper, a suite run or a second pair of eyes, SendMessage the orchestrator naming what you need rather than making an Agent call the wall will refuse.
