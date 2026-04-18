---
name: canonical-sdlc
description: Use when starting a large-scale development effort (new feature, architectural change, multi-day project) or when picking the skill for the current SDLC step. Routes to the canonical skill per step and enforces that every applicable step is walked before completion.
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

This skill constrains how large-scale development efforts are executed. The SDLC steps exist because they lead to better outcomes — each step contributes a dimension of fidelity (scope, contract, plan, isolation, proof, review, decision record, release discipline) that no other step supplies. Without this skill, Claude truncates the lifecycle on any given effort: individual steps feel skippable in isolation, but the compounding loss of fidelity is invisible mid-effort and surfaces as rework, lost decisions, and features that look complete but aren't production-grade.

**Core principle: NO STEP SKIPPED WITHOUT A DECLARED FAST-PATH. NO COMPLETION WITHOUT EVIDENCE FROM EVERY APPLICABLE STEP.**

Violating the letter of this process is violating the spirit of this process.

**Layer:** Governance (process constraint). Loads when a large-scale effort begins or when picking the skill for the current step.

**Routing principle — superpowers vs agent-skills.** The two plugins are interleaved because they solve orthogonal problems:

- `superpowers:` owns **discipline anchors** — planning, TDD, debugging, verification, review response, worktree isolation. Its rules are calibrated against Claude's known failure modes (fabrication, sycophancy, rationalization).
- `agent-skills:` owns **content rubrics** — spec shape, 5-axis review, 6-lens ideation, domain deep-dives (security, performance, UI). Supplies the *shape* each step's artifact should take.

On overlap, route by kind, not by plugin. On ties, prefer `superpowers:`. When adding a new sub-skill to `needs`, place it by which kind of gap it fills.

**REQUIRED SUB-SKILLS** (declared in `needs`):
- Operational and technique skills listed in the frontmatter. Load each only when the step that invokes it is active.

## Taxonomy

Large-scale work has structure. The skill uses a strict four-tier vocabulary so that multi-session epics stay composable, artifacts are predictably named, and transitions between sessions are unambiguous.

| Tier | Word | Definition |
|---|---|---|
| 1 | **epic** | Large body of work spanning multiple sessions. Example: "Epic 2 = V2 product pass". |
| 2 | **wave** | One-session chunk of an epic. Default rule: if it doesn't fit in a session, split it into more waves. |
| 3 | **step** | One of the 13 canonical-sdlc steps inside a wave (Ideate, Spec, Plan, Isolate, Implement, Browser verify, Verify done, Self-review, Document decisions, Commit, External review, Finish branch, Ship). |
| — | *slice* | *Informal.* An atomic implementation commit inside a wave's Step 5. A wave can have 1 or many slices. Slices don't get their own plan files. |

**Naming convention (convention over configuration).** All canonical-sdlc artifacts live in a directory-per-epic layout with zero-padded epic numbers and human-readable slugs. One slug per epic is chosen at epic-scope time and used across `specs/`, `plans/`, and `adrs/`:

```
docs/bionic/specs/epic-02-v2-product-pass/
  epic.spec.md
  wave-01-checkout-refactor.spec.md
  wave-02-<slug>.spec.md

docs/bionic/plans/epic-02-v2-product-pass/
  epic.plan.md
  wave-01-checkout-refactor.plan.md
  wave-02-<slug>.plan.md
  continuation.md

docs/bionic/adrs/epic-02-v2-product-pass/
  adr-001-<slug>.md
  adr-002-<slug>.md
```

- **Epic dir:** `epic-NN-<epic-slug>/` — `NN` is two-digit zero-padded; `<epic-slug>` is kebab-case and memorable.
- **Wave file:** `wave-NN-<wave-slug>.<kind>.md` where `<kind>` ∈ {`spec`, `plan`}. ADRs don't carry wave numbers — they number independently per epic.
- **Epic-level files:** `epic.spec.md`, `epic.plan.md` at the root of the epic dir.
- **Continuation:** `continuation.md` (end-of-wave) or `continuation-checkpoint.md` (mid-wave autosave). See *Continuation Artifacts* below.

Reject deviations from this convention unless there is a named, recorded reason. Convention over configuration is the point; cleverness is taxed.

## Epic vs. Wave Execution

The skill runs at two scales:

1. **Epic scoping** — declared via `epic-scope` mode. Runs Steps 1–3 only. Produces `epic.spec.md` + `epic.plan.md` at the root of the epic dir. The epic plan carves the work into waves and names them. Does **not** execute Steps 4–13.
2. **Wave execution** — the default. Declared via any of `full`, `bugfix`, `refactor`, `spike`, `overnight`. Runs the full applicable step set for one wave. Each wave re-enters Steps 1–3 at greater depth than the epic plan supplied; **trust but verify** the epic's assumptions, do not re-derive from scratch, but do re-explore within the wave's scope.

**Wave-level Step 1 re-entry rule.** When a wave begins, the alternatives lens for Step 1 must read the epic plan and any prior wave plans/specs/ADRs under the same epic dir. The epic plan is input, not gospel — if the wave uncovers a design constraint the epic missed, log it in `## Assumptions`, surface it to the user, and continue.

## The Iron Law

```
NO STEP SKIPPED WITHOUT A DECLARED FAST-PATH.
NO COMPLETION WITHOUT EVIDENCE FROM EVERY APPLICABLE STEP.
```

## Non-Negotiable: TDD

`superpowers:test-driven-development` fires on every step that produces or modifies code. No fast-path skips it. No "it's a small change" justification. Tests that pass are the canonical evidence of fidelity to outcome.

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

Declare the mode at entry. The mode determines which steps apply.

| Mode | When | Steps applied |
|---|---|---|
| `epic-scope` | Beginning a new epic; no implementation yet; needs carving into waves | 1–3 only; produces `epic.spec.md` + `epic.plan.md`. Short-circuits before Step 4. |
| `full` | New feature, architectural change, user-facing work (wave-level) | 1–13 |
| `bugfix` | Defect with known root cause; no behavior change beyond the fix | Woven debug → 5 (TDD + implement) → 8 → 9 (if non-obvious diagnosis) → 10 |
| `refactor` | Internal change, no behavior change | 3 → 5 → 7 → 8 → 9 → 10 |
| `spike` | Research or prototype; no code ships | Prereqs → woven source-driven → brief writeup |
| `overnight` | Unattended autonomous run against a high-level problem statement with upfront guidance (wave-level) | 1–13 with Step 8b adversarial critic **mandatory**, per-step checkpoint commit, expanded stop-and-wake list |

Mode declaration is reviewable. A feature disguised as `bugfix` to skip steps is drift with a label; declarations must match the actual work.

**`epic-scope` in particular** is the mode for the *first* canonical-sdlc run on a new epic. It only runs Steps 1–3, producing the epic-level spec and plan that carve work into waves. After `epic-scope` completes, each wave is a separate subsequent invocation — typically `full` or `overnight`. Do not run `epic-scope` without an epic identifier; do not run it on an existing epic unless explicitly rescoping.

**Overnight mode in particular** is the mode to declare when the user sets up the problem, gives discovery guidance, then walks away. Its tighter constraints exist because self-discipline alone is insufficient when there's no one watching: the adversarial critic catches what self-review misses, checkpoint commits produce an auditable trail, and the stop-and-wake list halts on classes of decisions that should never be made autonomously.

**Overnight does NOT mean "skip Step 1 Q&A".** The autonomous span is **Steps 4–13**, not Steps 1–13. The user-engagement sequence is:

| Step | Engagement |
|---|---|
| 1. Ideate | **Interactive Q&A with the user.** Extensive back-and-forth on scope, non-goals, alternatives. No shortcuts. |
| 2. Spec | **Semi-interactive.** Translate Step 1 into a testable contract. Surface remaining ambiguities as Wake Notes; otherwise proceed. |
| 3. Plan | **Autonomous write → one approval checkpoint.** Claude writes the plan; user reviews and approves before Step 4 begins. This is the "walk away" boundary. |
| 4–13 | **Fully autonomous** within the stop-and-wake rules. |

Skipping Step 1 Q&A to "save time" for the user is the single highest-risk move in overnight mode — it guarantees silent wrong assumptions. Every minute spent in Step 1 Q&A is cheaper than every hour spent reviewing a wrong overnight build in the morning.

## Always-On Prerequisites

These load at session start, not as numbered steps:
- `agent-skills:context-engineering` — load the right files before work begins.
- **Memory sweep — recursive.** Read `.bionic/memory/INDEX.md`, `context.md`, AND every file they link to — especially entries under "Deep Context" or equivalent headings. INDEX.md is an *index*, not the whole notebook. Skipping its pointers means missing design decisions already captured in the repo. A stale design picked from an incomplete alternatives set is the #1 autonomous-run failure mode. Plan file conventions: **bionic (canonical)** uses `docs/bionic/plans/epic-NN-<slug>/` per the Taxonomy section; other projects may use `~/.claude/plans/` or `docs/superpowers/plans/` flat. Read prior plans in the active convention as part of the sweep — in bionic, that means walking every existing epic directory, not just the current one.

## Woven-In Practices

Fire on-trigger, not at a fixed step:
- `agent-skills:source-driven-development` — whenever touching an unfamiliar API.
- `agent-skills:documentation-and-adrs` — inline capture whenever a decision is made during plan or implement. Also runs as checkpoint at step 9.
- `superpowers:systematic-debugging` — whenever a test fails or behavior surprises.

## Steps

Each step has: **goal** · **action** · **completion gate** · **evidence artifact**.

### Step 1 — Ideate (`agent-skills:idea-refine`)
- **Goal:** Pin scope and non-goals before they get encoded as requirements.
- **Action:** Run the 6-lens refinement + "Not Doing" list. Always prefer `idea-refine` over `superpowers:brainstorming` (user durable preference).
- **Engagement:** Interactive Q&A with the user. **Mandatory in every mode, including `overnight` and `epic-scope`.** Ask what you do not yet know; do not fill in silently. The alternatives lens specifically must check:
  1. Existing design docs in the repo's memory/notebook (e.g., `.bionic/memory/*.md` including every file linked from `INDEX.md`).
  2. Prior plans and specs in the project's plan/spec directories. For bionic: walk every epic directory under `docs/bionic/plans/` and `docs/bionic/specs/` — not only the current one. Other projects: `docs/superpowers/plans/`, `~/.claude/plans/`, or the project's convention.
  3. Prior ADRs under `docs/bionic/adrs/` (bionic) or equivalent.
  4. In wave mode: the epic plan and spec for the current epic (`epic.plan.md`, `epic.spec.md`). Trust but verify.
  5. Any explicit TODO file or pending-design-decision note already surfaced by the user.
  Missing a prior design document here produces the #1 autonomous-run failure mode — option selected from an incomplete alternatives set.
- **Gate:** Refined idea statement + explicit "Not Doing" list written + alternatives lens cites (or explicitly asserts absence of) prior design artifacts.
- **Evidence:** Both artifacts captured in the spec file (wave mode) or epic spec (`epic-scope` mode). Artifact path per the Taxonomy section.

### Step 2 — Spec (`agent-skills:spec-driven-development`)
- **Goal:** Convert the refined idea into a testable contract.
- **Action:** Write requirements + acceptance criteria.
- **Gate:** Every requirement has an acceptance criterion.
- **Evidence:** Spec doc at the canonical path. Bionic: `docs/bionic/specs/epic-NN-<slug>/wave-NN-<slug>.spec.md` (wave mode) or `docs/bionic/specs/epic-NN-<slug>/epic.spec.md` (`epic-scope` mode). Other projects: equivalent under their spec directory.
- **UI/UX substitution:** prepend `shape` and consult `ui-ux-pro-max:ui-ux-pro-max` for user-facing work.

### Step 3 — Plan (`superpowers:writing-plans`)
- **Goal:** Produce the execution contract that survives compaction.
- **Action:** Write an ordered, verifiable step list with no placeholders. Every plan file used by `canonical-sdlc` must contain two structured sections:
  - `## SDLC State` — the mode declared at entry, the **integration branch** (the long-lived branch this wave's work merges back to at Step 12), the current step, and one line per step of the form `Step N: <evidence path or artifact link>`. The evidence-gate hook reads this section on every `git commit`. **When advancing steps, replace the existing `Step N: (pending)` placeholder in-place — do not prepend a new line. One line per step, forever.**
  - `## Assumptions` — seeded from the Step 1 "Not Doing" list plus any spec ambiguities resolved during planning. Step 5 appends to this section inline.
- **Integration-branch declaration — ask once, stick to it.** When writing a plan file, the integration branch is declared in `## SDLC State` via an `integration-branch: <name>` line. Picking that name is part of the Step 3 interaction:
  - In `epic-scope` mode: ask the user which long-lived branch all waves of this epic will merge back to. Candidates the user should consider: `main`, `develop`, a dedicated epic feature branch (e.g., `epic/02-v2-product-pass`). Record the choice in the epic plan. Every subsequent wave under this epic **inherits** the epic plan's `integration-branch` without re-asking.
  - In any wave mode (`full`, `overnight`, `bugfix`, `refactor`, `spike`) launched under an existing epic: read the epic plan's `integration-branch` and copy it into the wave plan's `## SDLC State`. Do not re-prompt.
  - In a standalone wave (no epic): ask the user at plan time. Default offer: `main`.
  - Changing the integration branch mid-epic requires re-running `epic-scope` (treat as epic rescoping); do not silently edit the field.
- **Gate:** Plan file passes writing-plans' own "no placeholders" check **and** contains both structured sections **and** `## SDLC State` includes a non-empty `integration-branch:` line **and** receives explicit user approval before Step 4 begins (see Approval Checkpoint below).
- **Evidence:** Plan file at the canonical path. Bionic: `docs/bionic/plans/epic-NN-<slug>/wave-NN-<slug>.plan.md` (wave mode) or `docs/bionic/plans/epic-NN-<slug>/epic.plan.md` (`epic-scope` mode). Other projects: `docs/superpowers/plans/<name>.md` or `~/.claude/plans/<name>.md` per their convention.

#### Approval Checkpoint (end of Step 3)

This is the "walk away" boundary. After the plan file is complete:
- Main thread summarizes the plan for the user: mode, scope, Not-Doing list, ordered steps, critical files.
- User approves, requests revisions, or halts.
- **Only on explicit approval** does Step 4 begin. In `overnight` mode, this is the last interactive moment until Steps 4–13 complete or a stop-and-wake fires.
- Revisions loop back to Step 1, 2, or 3 — whichever the revision targets. Do not patch the plan silently.

### Step 4 — Isolate (`superpowers:using-git-worktrees`)
- **Goal:** Physically isolate in-progress work from the main workspace.
- **Action:** Create worktree. The wave's branch is cut **from the integration branch declared in `## SDLC State`** (not assumed `main`) — fetch/pull the integration branch first, then branch off its tip. Record worktree path AND the commit SHA the branch was cut from in the plan.
- **Gate:** `git worktree list` shows the branch; the branch's merge-base with the integration branch equals the recorded SHA.
- **Evidence:** Worktree path + base SHA in plan + `git worktree list` output.

### Step 5 — Implement (`agent-skills:incremental-implementation`)
- **Goal:** Build in thin vertical slices with per-slice proof.
- **Non-negotiable rhythm:** `superpowers:test-driven-development` — RED → GREEN → commit, per slice.
- **Wrapper:** `superpowers:executing-plans` if a plan file exists.
- **Woven:** source-driven on unfamiliar APIs; systematic-debugging on surprises; inline ADR capture on decisions.
- **Assumption-log update:** whenever a decision resolves ambiguity that a reviewer could reasonably question, append a one-line entry to the plan file's `## Assumptions` section **before the commit**. No silent choices.
- **Gate:** Every slice has a passing test that was RED before implementation; new assumptions are logged.
- **Evidence:** Commit history shows RED→GREEN transitions; `## Assumptions` reflects any novel decisions.

### Step 6 — Browser verify (`agent-skills:browser-testing-with-devtools`)
- **Goal:** Real-browser evidence for UI/frontend work.
- **Action:** Run flows in a real browser via DevTools MCP.
- **Gate:** Golden path + at least one edge case verified.
- **Evidence:** DevTools transcript or screenshot.
- **Skip condition:** Non-UI work — declare N/A explicitly.
- **UI/UX substitution:** use `frontend-design:frontend-design` in step 5 and `agent-skills:frontend-ui-engineering` for production hardening before this step.

### Step 7 — Verify done (`superpowers:verification-before-completion`)
- **Goal:** Evidence before assertions. Match the Bionic Philosophy's "Prove it works."
- **Action:** Run all applicable test suites; paste output.
- **Gate:** All tests pass; output is pasted or linked.
- **Evidence:** Command output in conversation or commit trailer.

### Step 8 — Self-review (`agent-skills:code-review-and-quality`)
- **Goal:** 5-axis review — correctness, readability, architecture, security, performance.
- **Action:** Walk each axis with pass/flag.
- **Gate:** Every axis has an explicit verdict.
- **Evidence:** Review notes.
- **Escalations (conditional):**
  - Security axis flags → `agent-skills:security-and-hardening` deep dive.
  - Performance axis flags → `agent-skills:performance-optimization` deep dive.
  - Escalation evidence attached to review notes.

### Step 8b — Adversarial critic (overnight: mandatory · full: recommended · other modes: optional unless Step 8 flagged)
- **Goal:** Catch what self-review missed. Fresh context, red-team framing. Self-review finds what you knew to look for; the critic finds what you didn't.
- **Action:** Dispatch a fresh-context subagent (a review-capable specialist like `code-reviewer`, or `general-purpose` with the prompt below) with the plan file, the diff, and the Step 8 self-review notes. Prompt template:

  > _Your job is to find what went wrong in this change. You have the spec, the plan, the diff, and the Step 8 self-review notes. Read them and try to falsify the claim that this is ready to merge. Look specifically for: silent wrong assumptions not logged in the `## Assumptions` section, scope creep beyond the spec, missing edge cases, fabricated evidence (claims of passing tests without pasted output), and cross-cutting concerns a single-axis review would miss. Output either: at least one specific, reproducible issue, or an explicit "no issues found" followed by the three strongest falsification attempts you made and why each failed. Confirmation-seeking agreement is not acceptable output._
- **Gate:** Critic output attached to plan file or review notes. Sycophantic output ("looks good") is **not** evidence — tighten the prompt and re-run.
- **Evidence:** Critic report with either specific issues raised or specific falsification attempts that failed.
- **Skip condition:** Non-overnight modes may skip only if Step 8 raised zero axis flags.

### Step 9 — Document decisions (`agent-skills:documentation-and-adrs`) — checkpoint
- **Goal:** Forcing function. Catch decisions that weren't captured inline during steps 3 and 5.
- **Action:** Review plan and implementation commits; verify every significant decision has an ADR or equivalent record.
- **Gate:** Every flagged decision has a written record before commit.
- **Evidence:** ADR file(s) at the canonical path. Bionic: `docs/bionic/adrs/epic-NN-<slug>/adr-NNN-<slug>.md`. Other projects: equivalent under their ADR directory. Inline plan references are acceptable for minor decisions that don't warrant a standalone ADR.
- **Why before commit:** docs and code land in the same commit; ADRs are never an afterthought PR.

### Step 10 — Commit (`agent-skills:git-workflow-and-versioning`)
- **Goal:** Atomic commits with clean history.
- **Action:** Stage scoped files; write commit body with "THINGS I DIDN'T TOUCH" summary. Update the plan file's `## SDLC State` section before staging so the evidence-gate hook lets the commit through.
- **Overnight mode:** one checkpoint commit *per step*, not one final commit. Each commit's scope = that step's evidence artifact. This produces a chronological trail the user can audit in the morning without reconstructing from a single blob.
- **Gate:** Commit is atomic; scope matches the Step 2 spec. Overnight mode: one commit per completed step before advancing.
- **Evidence:** Commit SHA + commit body.

### Step 11 — Request external review (`superpowers:requesting-code-review`)
- **Goal:** Surface issues self-review can't catch (misalignment with codebase or user intent).
- **Action:** Open PR or review request; on receipt, `superpowers:receiving-code-review` governs response.
- **Gate:** Review request is open.
- **Evidence:** PR link; on receipt, verification notes per `receiving-code-review`.

### Step 12 — Finish branch (`superpowers:finishing-a-development-branch`)
- **Goal:** Close the branch cleanly; prevent orphaned work. Every wave's commits must exist on the declared integration branch before the wave is called done — this is the invariant that prevents cross-session work loss.
- **Action:** Merge the wave branch into the integration branch declared in `## SDLC State` (local merge; pushing is the user's gate via `protect-main.sh`). Remove the worktree after the merge is verified.
- **Default is merge.** Parking ("park with a note") is only permitted when the user has explicitly endorsed it via a `## Wake Note` in the plan file with a specific reason (e.g., external dependency blocking review, intentional hold for next wave). A parked branch without a Wake Note is drift.
- **Gate:** The wave branch's tip commit is an ancestor of the integration branch's tip (`git merge-base --is-ancestor <wave-tip> <integration-branch>` exits 0), OR a `## Wake Note` documents the park. Worktree is removed.
- **Evidence:** Merge SHA recorded in `## SDLC State` as Step 12's line; `git log --oneline <integration-branch>` showing the merge; worktree absent from `git worktree list`. For parked branches: Wake Note content.

### Step 13 — Ship (`agent-skills:shipping-and-launch`)
- **Goal:** Production gate with pre-launch checklist, monitoring, rollback.
- **Action:** Run checklist; configure CI/CD (`agent-skills:ci-cd-and-automation`) if new pipelines needed. **Before declaring the wave complete**, emit `docs/bionic/plans/epic-NN-<slug>/continuation.md` summarizing the wave, the next wave, and open carry-overs (see *Continuation Artifacts* below). Always produced — a wave without a continuation artifact is an unfinished wave.
- **Gate:** Checklist complete; rollback plan documented; `continuation.md` written with valid `governing-skill` frontmatter.
- **Evidence:** Deployment record + rollback doc + monitoring dashboard link + `continuation.md` path.

## Constraints

- **TDD is non-negotiable** on any code-producing step. No fast-path skips it.
- **Mode declaration is reviewable.** A wrong mode is drift with a label.
- **Every step produces an artifact that outlives the conversation.** In-head evidence doesn't count.
- **Evidence must be pasted or linked**, not claimed. "Tests pass" is not evidence; the test output is.
- **Escalation deep dives are conditional**, not routine. `security-and-hardening` and `performance-optimization` fire only when step 8 flags.

## Governing-Skill Declaration

Every canonical-sdlc artifact carries frontmatter declaring the skill that governs its production. This anchors long-running work: when context compacts or a subagent picks up a file, the declared governing skill tells the reader which rubric produced the artifact and which rules still apply.

**Required frontmatter** on every `*.plan.md`, `*.spec.md`, `adr-*.md`, `continuation*.md`, `epic.plan.md`, `epic.spec.md` under `docs/bionic/{specs,plans,adrs}/`:

```yaml
---
governing-skill: superpowers:writing-plans
sdlc-step: 3
epic: epic-02-v2-product-pass
wave: wave-01-checkout-refactor
mode: full
---
```

Field definitions:
- `governing-skill` — the skill declared in parens after the step's `###` heading (Step 1 → `agent-skills:idea-refine`; Step 2 → `agent-skills:spec-driven-development`; Step 3 → `superpowers:writing-plans`; Step 9 → `agent-skills:documentation-and-adrs`; `continuation*.md` → `canonical-sdlc`).
- `sdlc-step` — the step number that produced this artifact (`2`, `3`, `9`, etc.). Use `0` for epic-scope artifacts, since they precede wave-step numbering. Use `13` for `continuation.md` (emitted at wave completion).
- `epic` — `epic-NN-<slug>` matching the enclosing directory name.
- `wave` — wave identifier (omit for epic-level artifacts and `continuation.md`).
- `mode` — canonical-sdlc mode at declaration time (`epic-scope`, `full`, `bugfix`, `refactor`, `spike`, `overnight`).

### Transition discipline

When advancing from one step to the next, announce the transition explicitly in-thread:

> _**Advancing to Step N — &lt;title&gt;** (governing skill: `<skill-id>`). Loading now._

Then invoke `Skill` to load the governing skill, or verify it's already loaded. The skill stays dominant until the next transition. Do not silently bleed instructions from a prior step's governing skill into the next step's artifact.

## Continuation Artifacts

Long-running epics span sessions. Continuation artifacts make session handoff automatic.

**End-of-wave (`continuation.md`).** Step 13 emits `docs/bionic/plans/epic-NN-<slug>/continuation.md` summarizing:
- Wave just completed (id, scope, outcome).
- **Integration branch** the wave merged into + merge SHA. The next wave branches from this same integration branch at or after this SHA.
- Next wave (id, scope, entry step = 1).
- Open decisions or carry-overs from this wave's `## Assumptions`.
- Pointers to the epic plan, last wave plan, and any relevant ADRs.

This artifact is always produced, regardless of whether a new session is imminent. Its frontmatter: `governing-skill: canonical-sdlc`, `sdlc-step: 13`, no `wave` field (continuation spans waves).

**Mid-wave checkpoint (`continuation-checkpoint.md`).** The Stop hook detects an active canonical-sdlc run (via the plan file's `## SDLC State` section) and autosaves a checkpoint to the same epic dir capturing:
- Current SDLC State snapshot (mode, current step, per-step evidence).
- In-flight work (last RED→GREEN, last ADR draft, last unresolved assumption).
- Next recommended action on resume.

Zero user interaction. When the next session starts, it reads `continuation-checkpoint.md` if present and resumes from the recorded state.

## Evidence Gate Hook

Bionic installs `canonical-sdlc-evidence-gate.sh` as a `PreToolUse|Bash` hook. On any `git commit`, the hook locates the most recent plan file across `docs/bionic/plans/` (recursively across epic directories), `docs/superpowers/plans/`, and `~/.claude/plans/`, reads the `## SDLC State` section, and **blocks the commit (exit 2) if the current step's evidence artifact is missing or unreadable**. The hook accepts both `Step N:` (current) and `Phase N:` (legacy) line formats for backward compatibility with in-flight plans.

Plans without an `## SDLC State` section pass through unblocked — the hook only enforces against canonical-sdlc runs.

## Governing-Skill Hook

Bionic installs `canonical-sdlc-governing-skill.sh` as a `PreToolUse|Write,Edit` hook. It blocks writes to any file matching `docs/bionic/{specs,plans,adrs}/**/{*.plan.md,*.spec.md,adr-*.md,continuation*.md,epic.plan.md,epic.spec.md}` if the resulting file lacks a valid `governing-skill:` frontmatter field.

Files under those paths that don't match the extension patterns (e.g., `README.md`, images, supporting docs) pass through unblocked. The skill drives naming; the hook ensures correctly-named artifacts declare their governing skill. Rename-to-bypass is discoverable — an artifact not named `*.plan.md` is not a plan, and the skill's evidence gates catch that before any hook does.

Together these two hooks form the external backstop to the self-discipline rules: social enforcement + two hard gates, not a sprawling enforcement web.

## Subagent Dispatch Convention

Every subagent invoked during a canonical-sdlc step — implementer, reviewer, critic, or any specialist dispatched for a deep dive — must receive a prompt prefix containing:

1. **Current step** — number, name, sub-skill invoked.
2. **Scope constraint** — what this agent may touch; what it must not.
3. **Artifact expected** — the evidence shape required for the step gate.
4. **Exit condition** — when to stop and report. Includes: "do not pivot approach; surface blockers to the main thread."
5. **Step-specific duties.** For dispatches during Step 5 (implement) in particular: *"Append a one-line entry to the plan file's `## Assumptions` section before your final commit whenever a decision resolves ambiguity that a reviewer could reasonably question. No silent choices. If you make no novel decisions, report that explicitly so the main thread knows no log update was required."* Step 5 is the step where the subagent has sole visibility into implementation-time judgment calls; only it can log them.

This prevents subagent wander, the most common source of drift in dispatched work. The prefix scopes the task; it does not override the agent's identity.

## Escalation Protocol

**Three-fail rule.** If the same step fails to produce valid evidence three times in a row:

1. Stop. Do not attempt a fourth time.
2. Surface the blocker to the user with: what was attempted, why each attempt failed, what information would unblock.
3. Wait for direction. Do not silently skip the step or fabricate evidence.

**Stop-and-wake list** (overnight mode: halt and leave a note; other modes: halt and ask directly):

- Ambiguous spec requiring a judgment call that would take more than one paragraph to resolve.
- New external-API authentication setup (OAuth flows, tokens, new credentials).
- Configuration change that affects billing.
- Destructive database migration (DROP, ALTER on tables with data).
- Changes to secrets, API keys, or production infrastructure.
- Any action the user's `CLAUDE.md` marks as requiring approval.

**On halt:** append a `## Wake Note` section to the plan file describing the blocker, what was tried, and the specific decision needed from the user. Do not proceed past the block. Do not improvise a workaround.

This matches the Bionic Philosophy's "When blocked: stop, re-plan, surface to the user. Don't brute-force past failures."

## Sub-Skill Loading

This skill references sub-skills listed in `needs`. Do not preload them. Load each when you reach the step that invokes it. Release focus on a sub-skill's rules when you leave that step. Depth limit: 3 layers (governance → operational → technique). Beyond that, use judgment.

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "This task is simple, I can skip the spec" | Simplicity is a claim, not a fact. Spec is where that claim gets tested. If it's truly simple, the spec is 3 lines and costs nothing. |
| "The plan is obvious, I'll hold it in my head" | Plan files survive context compaction; mental plans don't. The moment context gets summarized, the plan is gone. |
| "I can decide the approach as I implement" | This is the exact failure mode the skill exists to prevent. Implementation-time decisions are un-reviewable and un-recorded. |
| "TDD is overkill for this change" | TDD is non-negotiable. No code-producing step skips it. "Small change" is the most common rationalization for the largest class of missed bugs. |
| "I already know this API, source-driven-development is unnecessary" | Training data is stale. `context7` takes 10 seconds and catches the rename or deprecation you didn't know about. |
| "This decision is minor, it doesn't need an ADR" | "Minor" is judged from inside the context. Six months later, a maintainer asks why and there's no answer. Step 9 is the forcing function. |
| "Self-review passed, external review is redundant" | Self-review finds correctness; external review finds misalignment with the broader codebase and user intent. Different classes of issues. |
| "The code works, that's enough evidence" | "Works on my machine" isn't evidence of fidelity. Tests that pass in CI are. |
| "The user is in a hurry, I should skip steps to save time" | The skill exists to resist this pressure. Fidelity is the point. Declare a fast-path explicitly or walk the full path — no hybrid. |
| "I declared a bugfix fast-path, so I'm covered" | Fast-path declarations must match the work. A feature disguised as bugfix to skip spec/plan is drift with a label. |
| "Step 9 is redundant if I captured ADRs inline" | Then the checkpoint is a 30-second verification. It's cheap when diligent and catches gaps when not. It's still required. |
| "I can skip browser verify, the unit tests cover it" | Unit tests don't catch visual regressions, focus traps, or contrast failures. For UI work, real-browser evidence is distinct. |
| "I'm confident in my self-review; the adversarial critic is overkill" | Self-review is bounded by what you thought to check. The critic exists to find the questions you didn't ask. Mandatory in overnight mode for that reason. |
| "The assumption was obvious; no need to log it" | "Obvious" is judged from inside the moment. Six hours later when a test fails, the un-logged assumption is indistinguishable from a bug. Log it. |
| "I can update `## SDLC State` after the commit" | Then the evidence gate hook will block the commit. Update first; commit second. |

## Red Flags — STOP and Correct

- Claiming a step is "done" without pasting or linking its evidence artifact.
- Declaring `bugfix` or `refactor` mode when the work introduces new behavior.
- Skipping TDD on a code-producing step for any reason.
- Treating escalations (security, performance) as routine rather than conditional.
- Implementing before a plan file exists (`full` or `refactor` mode).
- Committing before step 9's ADR checkpoint on a decision-heavy effort.
- Writing an ADR post-commit "as a follow-up" — the step exists to prevent exactly this.
- Reaching step 13 with no artifact from step 3 (plan).
- Grinding past three failed evidence attempts on the same step without escalating.
- Committing without the plan file's `## SDLC State` section updated for the current step (the evidence-gate hook will block this, but don't rely on the hook — update first).
- Overnight mode without the `## Assumptions` section seeded at plan time.
- Adversarial critic output that is pure agreement — tighten the prompt and re-run; do not accept as evidence.
- Dispatching a subagent without the current-step + scope-constraint prefix from the Subagent Dispatch Convention.
- Improvising a workaround past a stop-and-wake trigger instead of halting and leaving a `## Wake Note`.
- Step 4 branching from `main` when `## SDLC State` declares a different `integration-branch`.
- Step 12 parking a wave without a `## Wake Note` that records the reason and a user endorsement. Default is merge; park is exceptional.
- Step 12 closing without the wave's commits reachable from the declared integration branch (`git merge-base --is-ancestor <wave-tip> <integration-branch>` must exit 0).
- Declaring a plan without an `integration-branch:` line in `## SDLC State` — the gate doesn't pass.

## Quick Reference

| Step | Gate | Evidence |
|---|---|---|
| 0. Prereqs | Context loaded, memory swept | Context notes, INDEX.md read |
| 1. Ideate | Refined idea + "Not Doing" list | Both in plan or brief |
| 2. Spec | Every req has acceptance criterion | Spec doc |
| 3. Plan | No placeholders | Plan file |
| 4. Isolate | Worktree exists, branch cut from declared `integration-branch` | `git worktree list` + base SHA |
| 5. Implement | Every slice has a passing test that was RED first | Commit history with RED→GREEN |
| 6. Browser verify | Golden path + edge case verified (or N/A declared) | DevTools transcript |
| 7. Verify done | All tests pass | Command output |
| 8. Self-review | Every axis has verdict | Review notes; escalation reports if flagged |
| 8b. Adversarial critic | Specific issues raised or specific falsification attempts logged | Critic report (mandatory in overnight mode) |
| 9. Document decisions | Every significant decision has a record | ADR file(s) |
| 10. Commit | Atomic, scope matches spec | Commit SHA + body |
| 11. External review | Review request open | PR link |
| 12. Finish branch | Wave merged into declared `integration-branch` (default); park only via Wake Note | Merge SHA; worktree removed |
| 13. Ship | Checklist complete, rollback documented | Deployment record |
