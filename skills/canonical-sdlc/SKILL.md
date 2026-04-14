---
name: canonical-sdlc
description: Use when starting a large-scale development effort (new feature, architectural change, multi-day project) or when picking the skill for the current SDLC phase. Routes to the canonical skill per phase and enforces that every applicable phase is walked before completion.
layer: governance
needs:
  - agent-skills:context-engineering
  - agent-skills:source-driven-development
  - agent-skills:documentation-and-adrs
  - agent-skills:idea-refine
  - agent-skills:spec-driven-development
  - agent-skills:incremental-implementation
  - agent-skills:browser-testing-with-devtools
  - agent-skills:code-review-and-quality
  - agent-skills:security-and-hardening
  - agent-skills:performance-optimization
  - agent-skills:git-workflow-and-versioning
  - agent-skills:shipping-and-launch
  - agent-skills:ci-cd-and-automation
  - agent-skills:frontend-ui-engineering
  - superpowers:systematic-debugging
  - superpowers:writing-plans
  - superpowers:executing-plans
  - superpowers:using-git-worktrees
  - superpowers:test-driven-development
  - superpowers:verification-before-completion
  - superpowers:requesting-code-review
  - superpowers:receiving-code-review
  - superpowers:finishing-a-development-branch
  - shape
  - ui-ux-pro-max:ui-ux-pro-max
  - frontend-design:frontend-design
loading: deferred
---

# Canonical SDLC

## Overview

This skill constrains how large-scale development efforts are executed. The SDLC phases exist because they lead to better outcomes — each phase contributes a dimension of fidelity (scope, contract, plan, isolation, proof, review, decision record, release discipline) that no other phase supplies. Without this skill, Claude truncates the lifecycle on any given effort: individual phases feel skippable in isolation, but the compounding loss of fidelity is invisible mid-effort and surfaces as rework, lost decisions, and features that look complete but aren't production-grade.

**Core principle: NO PHASE SKIPPED WITHOUT A DECLARED FAST-PATH. NO COMPLETION WITHOUT EVIDENCE FROM EVERY APPLICABLE PHASE.**

Violating the letter of this process is violating the spirit of this process.

**Layer:** Governance (process constraint). Loads when a large-scale effort begins or when picking the skill for the current phase.

**REQUIRED SUB-SKILLS** (declared in `needs`):
- Operational and technique skills listed in the frontmatter. Load each only when the phase that invokes it is active.

## The Iron Law

```
NO PHASE SKIPPED WITHOUT A DECLARED FAST-PATH.
NO COMPLETION WITHOUT EVIDENCE FROM EVERY APPLICABLE PHASE.
```

## Non-Negotiable: TDD

`superpowers:test-driven-development` fires on every phase that produces or modifies code. No fast-path skips it. No "it's a small change" justification. Tests that pass are the canonical evidence of fidelity to outcome.

## When to Use

**Hard triggers** (any one → invoke):
- User begins a new feature, architectural change, or multi-day effort.
- User asks "what's next?" on an in-progress large-scale effort.
- Session start on a branch that has an active plan file.

**Soft triggers** (two or more → invoke):
- The effort touches more than one component.
- The effort will ship to users.
- A spec or plan already exists.
- The work requires decisions that future maintainers will need.

## Mode Selector

Declare the mode at entry. The mode determines which phases apply.

| Mode | When | Phases applied |
|---|---|---|
| `full` | New feature, architectural change, user-facing work | 1–13 |
| `bugfix` | Defect with known root cause; no behavior change beyond the fix | Woven debug → 5 (TDD + implement) → 8 → 9 (if non-obvious diagnosis) → 10 |
| `refactor` | Internal change, no behavior change | 3 → 5 → 7 → 8 → 9 → 10 |
| `spike` | Research or prototype; no code ships | Prereqs → woven source-driven → brief writeup |

Mode declaration is reviewable. A feature disguised as `bugfix` to skip phases is drift with a label; declarations must match the actual work.

## Always-On Prerequisites

These load at session start, not as numbered phases:
- `agent-skills:context-engineering` — load the right files before work begins.
- Memory sweep — read `.bionic/memory/INDEX.md` and `context.md`.

## Woven-In Practices

Fire on-trigger, not at a fixed phase:
- `agent-skills:source-driven-development` — whenever touching an unfamiliar API.
- `agent-skills:documentation-and-adrs` — inline capture whenever a decision is made during plan or implement. Also runs as checkpoint at phase 9.
- `superpowers:systematic-debugging` — whenever a test fails or behavior surprises.

## Phases

Each phase has: **goal** · **action** · **completion gate** · **evidence artifact**.

### Phase 1 — Ideate (`agent-skills:idea-refine`)
- **Goal:** Pin scope and non-goals before they get encoded as requirements.
- **Action:** Run the 6-lens refinement + "Not Doing" list. Always prefer `idea-refine` over `superpowers:brainstorming` (user durable preference).
- **Gate:** Refined idea statement + explicit "Not Doing" list written.
- **Evidence:** Both artifacts in the plan file or a dedicated brief.

### Phase 2 — Spec (`agent-skills:spec-driven-development`)
- **Goal:** Convert the refined idea into a testable contract.
- **Action:** Write requirements + acceptance criteria.
- **Gate:** Every requirement has an acceptance criterion.
- **Evidence:** Spec doc in `docs/` or plan file.
- **UI/UX substitution:** prepend `shape` and consult `ui-ux-pro-max:ui-ux-pro-max` for user-facing work.

### Phase 3 — Plan (`superpowers:writing-plans`)
- **Goal:** Produce the execution contract that survives compaction.
- **Action:** Write an ordered, verifiable step list with no placeholders.
- **Gate:** Plan file passes writing-plans' own "no placeholders" check.
- **Evidence:** Plan file at `~/.claude/plans/<name>.md` or equivalent.

### Phase 4 — Isolate (`superpowers:using-git-worktrees`)
- **Goal:** Physically isolate in-progress work from the main workspace.
- **Action:** Create worktree; record path in plan.
- **Gate:** `git worktree list` shows the branch.
- **Evidence:** Worktree path in plan + verification output.

### Phase 5 — Implement (`agent-skills:incremental-implementation`)
- **Goal:** Build in thin vertical slices with per-slice proof.
- **Non-negotiable rhythm:** `superpowers:test-driven-development` — RED → GREEN → commit, per slice.
- **Wrapper:** `superpowers:executing-plans` if a plan file exists.
- **Woven:** source-driven on unfamiliar APIs; systematic-debugging on surprises; inline ADR capture on decisions.
- **Gate:** Every slice has a passing test that was RED before implementation.
- **Evidence:** Commit history shows RED→GREEN transitions.

### Phase 6 — Browser verify (`agent-skills:browser-testing-with-devtools`)
- **Goal:** Real-browser evidence for UI/frontend work.
- **Action:** Run flows in a real browser via DevTools MCP.
- **Gate:** Golden path + at least one edge case verified.
- **Evidence:** DevTools transcript or screenshot.
- **Skip condition:** Non-UI work — declare N/A explicitly.
- **UI/UX substitution:** use `frontend-design:frontend-design` in phase 5 and `agent-skills:frontend-ui-engineering` for production hardening before this phase.

### Phase 7 — Verify done (`superpowers:verification-before-completion`)
- **Goal:** Evidence before assertions. Match the Bionic Philosophy's "Prove it works."
- **Action:** Run all applicable test suites; paste output.
- **Gate:** All tests pass; output is pasted or linked.
- **Evidence:** Command output in conversation or commit trailer.

### Phase 8 — Self-review (`agent-skills:code-review-and-quality`)
- **Goal:** 5-axis review — correctness, readability, architecture, security, performance.
- **Action:** Walk each axis with pass/flag.
- **Gate:** Every axis has an explicit verdict.
- **Evidence:** Review notes.
- **Escalations (conditional):**
  - Security axis flags → `agent-skills:security-and-hardening` deep dive.
  - Performance axis flags → `agent-skills:performance-optimization` deep dive.
  - Escalation evidence attached to review notes.

### Phase 9 — Document decisions (`agent-skills:documentation-and-adrs`) — checkpoint
- **Goal:** Forcing function. Catch decisions that weren't captured inline during phases 3 and 5.
- **Action:** Review plan and implementation commits; verify every significant decision has an ADR or equivalent record.
- **Gate:** Every flagged decision has a written record before commit.
- **Evidence:** ADR file(s) in `docs/adr/` or inline references in plan.
- **Why before commit:** docs and code land in the same commit; ADRs are never an afterthought PR.

### Phase 10 — Commit (`agent-skills:git-workflow-and-versioning`)
- **Goal:** Atomic commits with clean history.
- **Action:** Stage scoped files; write commit body with "THINGS I DIDN'T TOUCH" summary.
- **Gate:** Commit is atomic; scope matches the phase 2 spec.
- **Evidence:** Commit SHA + commit body.

### Phase 11 — Request external review (`superpowers:requesting-code-review`)
- **Goal:** Surface issues self-review can't catch (misalignment with codebase or user intent).
- **Action:** Open PR or review request; on receipt, `superpowers:receiving-code-review` governs response.
- **Gate:** Review request is open.
- **Evidence:** PR link; on receipt, verification notes per `receiving-code-review`.

### Phase 12 — Finish branch (`superpowers:finishing-a-development-branch`)
- **Goal:** Close the branch cleanly; prevent orphaned work.
- **Action:** Merge/PR/cleanup per the skill's structured options.
- **Gate:** Branch is merged or explicitly parked with a note.
- **Evidence:** Merge SHA or closed-PR link; worktree removed.

### Phase 13 — Ship (`agent-skills:shipping-and-launch`)
- **Goal:** Production gate with pre-launch checklist, monitoring, rollback.
- **Action:** Run checklist; configure CI/CD (`agent-skills:ci-cd-and-automation`) if new pipelines needed.
- **Gate:** Checklist complete; rollback plan documented.
- **Evidence:** Deployment record + rollback doc + monitoring dashboard link.

## Constraints

- **TDD is non-negotiable** on any code-producing phase. No fast-path skips it.
- **Mode declaration is reviewable.** A wrong mode is drift with a label.
- **Every phase produces an artifact that outlives the conversation.** In-head evidence doesn't count.
- **Evidence must be pasted or linked**, not claimed. "Tests pass" is not evidence; the test output is.
- **Escalation deep dives are conditional**, not routine. `security-and-hardening` and `performance-optimization` fire only when phase 8 flags.

## Escalation Protocol

If the same phase fails to produce valid evidence three times in a row:

1. Stop. Do not attempt a fourth time.
2. Surface the blocker to the user with: what was attempted, why each attempt failed, what information would unblock.
3. Wait for direction. Do not silently skip the phase or fabricate evidence.

This matches the Bionic Philosophy's "When blocked: stop, re-plan, surface to the user. Don't brute-force past failures."

## Sub-Skill Loading

This skill references sub-skills listed in `needs`. Do not preload them. Load each when you reach the phase that invokes it. Release focus on a sub-skill's rules when you leave that phase. Depth limit: 3 layers (governance → operational → technique). Beyond that, use judgment.

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "This task is simple, I can skip the spec" | Simplicity is a claim, not a fact. Spec is where that claim gets tested. If it's truly simple, the spec is 3 lines and costs nothing. |
| "The plan is obvious, I'll hold it in my head" | Plan files survive context compaction; mental plans don't. The moment context gets summarized, the plan is gone. |
| "I can decide the approach as I implement" | This is the exact failure mode the skill exists to prevent. Implementation-time decisions are un-reviewable and un-recorded. |
| "TDD is overkill for this change" | TDD is non-negotiable. No code-producing phase skips it. "Small change" is the most common rationalization for the largest class of missed bugs. |
| "I already know this API, source-driven-development is unnecessary" | Training data is stale. `context7` takes 10 seconds and catches the rename or deprecation you didn't know about. |
| "This decision is minor, it doesn't need an ADR" | "Minor" is judged from inside the context. Six months later, a maintainer asks why and there's no answer. Phase 9 is the forcing function. |
| "Self-review passed, external review is redundant" | Self-review finds correctness; external review finds misalignment with the broader codebase and user intent. Different classes of issues. |
| "The code works, that's enough evidence" | "Works on my machine" isn't evidence of fidelity. Tests that pass in CI are. |
| "The user is in a hurry, I should skip phases to save time" | The skill exists to resist this pressure. Fidelity is the point. Declare a fast-path explicitly or walk the full path — no hybrid. |
| "I declared a bugfix fast-path, so I'm covered" | Fast-path declarations must match the work. A feature disguised as bugfix to skip spec/plan is drift with a label. |
| "Phase 9 is redundant if I captured ADRs inline" | Then the checkpoint is a 30-second verification. It's cheap when diligent and catches gaps when not. It's still required. |
| "I can skip browser verify, the unit tests cover it" | Unit tests don't catch visual regressions, focus traps, or contrast failures. For UI work, real-browser evidence is distinct. |

## Red Flags — STOP and Correct

- Claiming a phase is "done" without pasting or linking its evidence artifact.
- Declaring `bugfix` or `refactor` mode when the work introduces new behavior.
- Skipping TDD on a code-producing phase for any reason.
- Treating escalations (security, performance) as routine rather than conditional.
- Implementing before a plan file exists (`full` or `refactor` mode).
- Committing before phase 9's ADR checkpoint on a decision-heavy effort.
- Writing an ADR post-commit "as a follow-up" — the phase exists to prevent exactly this.
- Reaching phase 13 with no artifact from phase 3 (plan).
- Grinding past three failed evidence attempts on the same phase without escalating.

## Quick Reference

| Phase | Gate | Evidence |
|---|---|---|
| 0. Prereqs | Context loaded, memory swept | Context notes, INDEX.md read |
| 1. Ideate | Refined idea + "Not Doing" list | Both in plan or brief |
| 2. Spec | Every req has acceptance criterion | Spec doc |
| 3. Plan | No placeholders | Plan file |
| 4. Isolate | Worktree exists | `git worktree list` |
| 5. Implement | Every slice has a passing test that was RED first | Commit history with RED→GREEN |
| 6. Browser verify | Golden path + edge case verified (or N/A declared) | DevTools transcript |
| 7. Verify done | All tests pass | Command output |
| 8. Self-review | Every axis has verdict | Review notes; escalation reports if flagged |
| 9. Document decisions | Every significant decision has a record | ADR file(s) |
| 10. Commit | Atomic, scope matches spec | Commit SHA + body |
| 11. External review | Review request open | PR link |
| 12. Finish branch | Branch merged or parked | Merge SHA; worktree removed |
| 13. Ship | Checklist complete, rollback documented | Deployment record |
