# Skill Composability Schema Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the skill composability schema (layer/needs/loading frontmatter), add map-instrument-narrow and skill-factory to the project, refactor existing skills, and update CLAUDE.md with the "Measure before fixing" principle.

**Architecture:** Six independent file changes (CLAUDE.md, 3 skill files, config, README) that share a common frontmatter schema. All deliverables are markdown — no application code. The skill-factory is the most complex new file; the rest are targeted edits to existing files.

**Tech Stack:** Markdown, YAML frontmatter, bash (bootstrap verification)

---

### Task 1: Add "Measure before fixing" principle to CLAUDE.md

**Files:**
- Modify: `claude-global.md:14` (after "Prove it works" paragraph)

- [ ] **Step 1: Add the new principle**

Insert after the "Prove it works" paragraph (after line 16) in `claude-global.md`:

```markdown
**Measure before fixing.** When debugging, instrument the system to gather
evidence before attempting any fix. Hypotheses without data produce circular
debugging. Map the architecture, capture state at boundaries, narrow to the
culprit — then fix. One instrumented test run finds more than ten uninformed
fix attempts.
```

The file should read (lines 13-22):

```markdown
**Prove it works.** Never claim done without evidence. Run tests, show output. If
no test infrastructure exists, create it. Changes without proof are unfinished work.

**Measure before fixing.** When debugging, instrument the system to gather
evidence before attempting any fix. Hypotheses without data produce circular
debugging. Map the architecture, capture state at boundaries, narrow to the
culprit — then fix. One instrumented test run finds more than ten uninformed
fix attempts.

**Act, don't ask.** Operate autonomously. Fix bugs without hand-holding. Resolve
```

- [ ] **Step 2: Verify the file reads correctly**

Run: `head -25 claude-global.md`
Expected: 10 principles visible, "Measure before fixing" appears between "Prove it works" and "Act, don't ask"

- [ ] **Step 3: Commit**

```bash
git add claude-global.md
git commit -m "feat: add 'Measure before fixing' principle to Bionic Philosophy"
```

---

### Task 2: Refactor `rigorous-refactor` with composability schema

**Files:**
- Modify: `skills/rigorous-refactor/SKILL.md:1-19` (frontmatter + REQUIRED SUB-SKILLS block)
- Modify: `skills/rigorous-refactor/SKILL.md` (add new section before Common Rationalizations)

- [ ] **Step 1: Replace the frontmatter**

Replace the existing frontmatter (lines 1-4):

```yaml
---
name: rigorous-refactor
description: Use when performing complex, multi-file refactoring that requires systematic test coverage, independent validation, and proof of correctness before claiming completion
---
```

With:

```yaml
---
name: rigorous-refactor
description: Use when performing complex, multi-file refactoring that requires systematic test coverage, independent validation, and proof of correctness before claiming completion
layer: operational
needs:
  - superpowers:test-driven-development
  - superpowers:verification-before-completion
loading: deferred
---
```

- [ ] **Step 2: Update the REQUIRED SUB-SKILLS block**

Replace lines 16-18:

```markdown
**REQUIRED SUB-SKILLS:**
- `superpowers:test-driven-development` — governs the RED-GREEN cycle within each unit
- `superpowers:verification-before-completion` — governs proof-of-completion claims
```

With:

```markdown
**Layer:** Operational (method constraint). Prevents self-grading, skipping decomposition, and implementing without tests.

**REQUIRED SUB-SKILLS** (declared in `needs` frontmatter):
- `superpowers:test-driven-development` — governs the RED-GREEN cycle within each unit
- `superpowers:verification-before-completion` — governs proof-of-completion claims
```

- [ ] **Step 3: Add Sub-Skill Loading section**

Insert a new section immediately before "## Common Rationalizations" (before line 165):

```markdown
## Sub-Skill Loading

This skill references sub-skills listed in `needs`. Do not preload them.
Load each when you reach the phase that invokes it. Release focus on a
sub-skill's rules when you leave that phase. Depth limit: 3 layers
(governance -> operational -> technique). Beyond that, use judgment.

```

- [ ] **Step 4: Verify the file structure**

Run: `head -25 skills/rigorous-refactor/SKILL.md`
Expected: New frontmatter with `layer: operational`, `needs:` list, `loading: deferred`

Run: `grep -n "Sub-Skill Loading" skills/rigorous-refactor/SKILL.md`
Expected: One match, appearing before "Common Rationalizations"

- [ ] **Step 5: Commit**

```bash
git add skills/rigorous-refactor/SKILL.md
git commit -m "feat: add composability schema to rigorous-refactor skill"
```

---

### Task 3: Refactor `ralph-loop` with composability schema

**Files:**
- Modify: `skills/ralph-loop/SKILL.md:1-19` (frontmatter + REQUIRED SUB-SKILLS block)
- Modify: `skills/ralph-loop/SKILL.md:155-156` (DIAGNOSE section)
- Modify: `skills/ralph-loop/SKILL.md` (add new section before Common Rationalizations)

- [ ] **Step 1: Replace the frontmatter**

Replace the existing frontmatter (lines 1-4):

```yaml
---
name: ralph-loop
description: Use when debugging broken features, implementing greenfield functionality, or researching a codebase before a complex change — any task requiring iterative build-test-diagnose cycles to reach verified working software
---
```

With:

```yaml
---
name: ralph-loop
description: Use when debugging broken features, implementing greenfield functionality, or researching a codebase before a complex change — any task requiring iterative build-test-diagnose cycles to reach verified working software
layer: governance
needs:
  - bionic:rigorous-refactor
  - bionic:map-instrument-narrow
  - superpowers:systematic-debugging
  - superpowers:verification-before-completion
loading: deferred
---
```

- [ ] **Step 2: Update the REQUIRED SUB-SKILLS block**

Replace lines 16-19:

```markdown
**REQUIRED SUB-SKILLS:**
- `bionic:rigorous-refactor` — governs test discipline within each cycle
- `superpowers:systematic-debugging` — governs the diagnose phase
- `superpowers:verification-before-completion` — governs exit condition claims
```

With:

```markdown
**Layer:** Governance (process constraint). Prevents skipping phases, exiting without evidence, and grinding past iteration limits.

**REQUIRED SUB-SKILLS** (declared in `needs` frontmatter):
- `bionic:rigorous-refactor` — governs test discipline within each cycle
- `bionic:map-instrument-narrow` — governs evidence gathering when debugging hits hard/soft triggers
- `superpowers:systematic-debugging` — governs the diagnose phase
- `superpowers:verification-before-completion` — governs exit condition claims
```

- [ ] **Step 3: Expand the DIAGNOSE section**

Replace the DIAGNOSE section (lines 155-156):

```markdown
### DIAGNOSE — Understand why it failed

Follow `superpowers:systematic-debugging`. Root cause before next attempt. No "let me try something else" without understanding why the last thing failed.
```

With:

```markdown
### DIAGNOSE — Understand why it failed

Follow `superpowers:systematic-debugging`. Root cause before next attempt. No "let me try something else" without understanding why the last thing failed.

**Instrumentation trigger:** If the failure involves any hard trigger (prior fix failed without data, async/deferred execution, third-party library internals) or 2+ soft triggers (state correct at A but wrong at B, fix works in isolation but gets overridden, 3+ interacting subsystems, prior session attempted fixes without measurement), load and follow `bionic:map-instrument-narrow` before attempting another fix. Measurement before mutation.
```

- [ ] **Step 4: Add Sub-Skill Loading section**

Insert a new section immediately before "## Common Rationalizations" (before line 187):

```markdown
## Sub-Skill Loading

This skill references sub-skills listed in `needs`. Do not preload them.
Load each when you reach the phase that invokes it. Release focus on a
sub-skill's rules when you leave that phase. Depth limit: 3 layers
(governance -> operational -> technique). Beyond that, use judgment.

```

- [ ] **Step 5: Verify the file structure**

Run: `head -25 skills/ralph-loop/SKILL.md`
Expected: New frontmatter with `layer: governance`, `needs:` list including `bionic:map-instrument-narrow`, `loading: deferred`

Run: `grep -n "Instrumentation trigger" skills/ralph-loop/SKILL.md`
Expected: One match in the DIAGNOSE section

Run: `grep -n "Sub-Skill Loading" skills/ralph-loop/SKILL.md`
Expected: One match, appearing before "Common Rationalizations"

- [ ] **Step 6: Commit**

```bash
git add skills/ralph-loop/SKILL.md
git commit -m "feat: add composability schema to ralph-loop skill with instrumentation trigger"
```

---

### Task 4: Add `map-instrument-narrow` to the project

**Files:**
- Create: `skills/map-instrument-narrow/SKILL.md` (copy from `~/.claude/skills/map-instrument-narrow/SKILL.md` with modifications)

- [ ] **Step 1: Create the skill directory and copy the file**

```bash
mkdir -p skills/map-instrument-narrow
cp ~/.claude/skills/map-instrument-narrow/SKILL.md skills/map-instrument-narrow/SKILL.md
```

- [ ] **Step 2: Replace the frontmatter**

Replace the existing frontmatter (lines 1-4):

```yaml
---
name: map-instrument-narrow
description: Use when debugging requires understanding unfamiliar system internals before instrumentation will be interpretable — especially async execution, third-party library code, state mutations with no obvious code path between cause and effect, or when prior fix attempts failed without data
---
```

With:

```yaml
---
name: map-instrument-narrow
description: Use when debugging requires understanding unfamiliar system internals before instrumentation will be interpretable — especially async execution, third-party library code, state mutations with no obvious code path between cause and effect, or when prior fix attempts failed without data
layer: technique
needs: []
loading: deferred
---
```

- [ ] **Step 3: Update the Layer declaration in prose**

Replace line 16:

```markdown
**Layer:** This is a TECHNIQUE skill, invoked inside systematic-debugging's Phase 1 "Gather Evidence." It does not replace the scientific method — it provides the observation capability that feeds it.
```

With:

```markdown
**Layer:** Technique (observation constraint). Invoked inside `systematic-debugging`'s Phase 1 "Gather Evidence" or `ralph-loop`'s DIAGNOSE phase when hard/soft triggers are met. It does not replace the scientific method — it provides the observation capability that feeds it.
```

- [ ] **Step 4: Verify the file**

Run: `head -12 skills/map-instrument-narrow/SKILL.md`
Expected: Frontmatter with `layer: technique`, `needs: []`, `loading: deferred`

Run: `grep "Technique (observation constraint)" skills/map-instrument-narrow/SKILL.md`
Expected: One match

Run: `wc -l skills/map-instrument-narrow/SKILL.md`
Expected: ~181 lines (same as original plus frontmatter additions)

- [ ] **Step 5: Commit**

```bash
git add skills/map-instrument-narrow/SKILL.md
git commit -m "feat: add map-instrument-narrow technique skill with composability schema"
```

---

### Task 5: Create the `skill-factory` skill

**Files:**
- Create: `skills/skill-factory/SKILL.md`

- [ ] **Step 1: Create the skill directory**

```bash
mkdir -p skills/skill-factory
```

- [ ] **Step 2: Write the skill file**

Create `skills/skill-factory/SKILL.md` with the following content:

```markdown
---
name: skill-factory
description: Use when creating a new bionic skill — interviews the user to extract the constraint, layer, dependencies, and rationalizations, then hands off to writing-skills for file generation
layer: governance
needs:
  - superpowers:writing-skills
loading: deferred
---

# Skill Factory

## Overview

A skill is a constraint on behavior. Its value is not what it tells Claude to do — it's what it prevents Claude from skipping. This factory interviews the user to extract the constraint, then produces a skill skeleton that follows the bionic composability schema.

**Core principle:** Every skill must identify a specific failure mode that Claude exhibits. If there is no failure mode, there is no skill — write documentation instead.

**Violating the letter of this process is violating the spirit of this process.**

## The Iron Law

` ` `
NO SKILL WITHOUT AN IDENTIFIED FAILURE MODE.
` ` `

## The Composability Schema

Every bionic skill declares three metadata fields in its frontmatter:

| Field | Values | Purpose |
|-------|--------|---------|
| `layer` | `governance` / `operational` / `technique` | Where the skill sits in the hierarchy |
| `needs` | List of `namespace:skill-name` | Skills this one references during execution |
| `loading` | `eager` / `deferred` (default) / `inline` | How the LLM should load this when referenced |

### Layers as Constraint Types

| Layer | Constraint type | Prevents | Authoring signal |
|-------|----------------|----------|-----------------|
| **Governance** | Process constraints | Skipping phases, exiting without evidence, grinding past limits | The failure mode is about *process* — Claude doesn't follow a lifecycle |
| **Operational** | Method constraints | Self-grading, skipping decomposition, implementing without tests | The failure mode is about *method* — Claude skips a required technique |
| **Technique** | Observation constraints | Guessing without data, fixing without understanding | The failure mode is about *perception* — Claude doesn't gather enough information |

### Layer-Specific Structures

Skills at different layers follow different structural patterns:

**Governance skills** include:
- Mode selection (what type of task triggers what entry point)
- Lifecycle phases with iteration limits
- Escalation protocol (stop and surface to user after N failures)
- Sub-Skill Loading protocol
- Exit conditions with evidence requirements

**Operational skills** include:
- State machine with gates between phases
- Per-unit cycles with RED/GREEN verification
- Independent validation (separate agent, no self-grading)
- Sub-Skill Loading protocol
- Integration pass (run all test suites, not just default)

**Technique skills** include:
- Sequential phases (each produces a written artifact)
- Hard constraints (no action X without completing Y)
- Trigger conditions (hard triggers + soft triggers)
- No sub-skill loading (leaf nodes in the dependency graph)

## Phase 1: Constraint Extraction (Interview)

Ask these six questions **one at a time**. Do not bundle questions. Wait for the user's answer before proceeding.

### Question 1: Failure Mode
> **"What does Claude skip or get wrong without this skill? Describe the specific failure mode — what goes wrong, and what does the wasted effort look like?"**

If the user cannot identify a specific failure mode: STOP. Output: "This sounds like documentation or a reference guide, not a skill. Skills constrain behavior to prevent a specific failure mode. Would you like to write this as a reference document instead?"

### Question 2: Constraint Layer
> **"Is that failure a process problem, a method problem, or a perception problem?"**
>
> - **Process problem** (governance): Claude doesn't follow a lifecycle — it skips phases, exits without evidence, grinds past limits instead of escalating
> - **Method problem** (operational): Claude skips a required technique — it self-grades, doesn't decompose, implements without tests
> - **Perception problem** (technique): Claude doesn't gather enough information — it guesses without data, fixes without understanding, instruments without architecture

### Question 3: The Iron Law
> **"State the constraint as a single sentence in the form: NO ___ WITHOUT ___."**
>
> Examples from existing skills:
> - `NO ITERATION WITHOUT EVIDENCE. NO EXIT WITHOUT VERIFICATION.` (ralph-loop, governance)
> - `NO IMPLEMENTATION WITHOUT DECOMPOSITION. NO COMPLETION WITHOUT INDEPENDENT VALIDATION.` (rigorous-refactor, operational)
> - `NO FIX CODE WITHOUT DATA. NO INSTRUMENTATION WITHOUT ARCHITECTURE.` (map-instrument-narrow, technique)

### Question 4: Dependencies
> **"What other constraints must be active alongside this one? Which existing skills does this one reference?"**
>
> Available bionic skills: `bionic:ralph-loop`, `bionic:rigorous-refactor`, `bionic:map-instrument-narrow`
> Available superpowers skills: `superpowers:systematic-debugging`, `superpowers:test-driven-development`, `superpowers:verification-before-completion`, `superpowers:writing-skills`

### Question 5: Rationalizations
> **"How will Claude rationalize skipping this constraint? Give at least 5 ways Claude might talk itself out of following this skill."**
>
> Think about: what shortcuts feel productive but violate the constraint? What sounds reasonable but leads to the failure mode?

### Question 6: Evidence
> **"What artifact proves the constraint was respected? For each phase of this skill, what written evidence must exist?"**

## Phase 2: Schema Generation

From the interview answers, generate the complete skill file:

### Frontmatter Template

```yaml
---
name: [skill-name]
description: Use when [trigger condition derived from the failure mode]
layer: [governance | operational | technique]
needs:
  - [from Question 4 answers]
loading: deferred
---
```

### Skill Body Template

Generate the following sections, adapting structure to the layer:

1. **Title** — `# [Skill Name]`
2. **Overview** — One paragraph: what the skill constrains and why. Include:
   - Core principle (derived from Iron Law)
   - "Violating the letter of this process is violating the spirit of this process."
   - Layer declaration: "**Layer:** [Type] ([constraint type]). [One sentence about when it loads]."
   - REQUIRED SUB-SKILLS block (from `needs`) — only for governance and operational layers
3. **The Iron Law** — In a code block, the constraint from Question 3
4. **When to Use** — Hard triggers (any one) and soft triggers (two or more), derived from the failure mode description
5. **Phases** — Layer-appropriate structure (see Layer-Specific Structures above). Each phase must have:
   - A goal statement
   - Concrete actions
   - A completion gate ("phase is complete when...")
   - A written artifact requirement
6. **Constraints** — Explicit rules that cannot be violated during execution
7. **Sub-Skill Loading** — Only for governance and operational skills:
   "This skill references sub-skills listed in `needs`. Do not preload them. Load each when you reach the phase that invokes it. Release focus on a sub-skill's rules when you leave that phase. Depth limit: 3 layers (governance -> operational -> technique). Beyond that, use judgment."
8. **Common Rationalizations** — Table with at least 8 entries: the 5+ from the interview plus factory additions. Format: `| Excuse | Reality |`
9. **Red Flags — STOP and Correct** — Bulleted list of observable behaviors that mean execution has deviated
10. **Quick Reference** — Table: `| Phase | Gate | Evidence |`

### Quality Gates

Before presenting the skeleton to the user:
- Every phase has a completion gate and artifact requirement
- Rationalizations table has at least 8 entries
- Red Flags list has at least 5 entries
- No placeholders, TBDs, or "fill in later" markers
- The Iron Law appears in both the code block and the Overview's core principle

## Phase 3: Handoff

Present the generated skeleton to the user for review. After approval:

1. Invoke `superpowers:writing-skills` to write the file to `skills/[skill-name]/SKILL.md`
2. Add `local-skill  | [skill-name]` to `claude-config.txt`
3. Commit both files

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "This skill is straightforward, I don't need the factory" | The factory ensures every skill follows the composability schema. Skip it and you get inconsistent frontmatter. |
| "I know the failure mode, I can skip the interview" | The interview externalizes implicit knowledge. Your mental model of the failure mode may be incomplete. |
| "The Iron Law is too rigid for this skill" | If you can't state the constraint in one sentence, you don't understand what the skill prevents. |
| "This skill doesn't fit neatly into one layer" | If it constrains both process and method, split it into two skills. One skill, one constraint type. |
| "I'll add rationalizations later" | Rationalizations are the skill's immune system. Without them, Claude finds loopholes on the first invocation. |
| "Five rationalizations is enough" | Five is the minimum. Eight is the target. Claude is creative at finding shortcuts — be more creative at blocking them. |
| "The skill doesn't need a loading protocol" | Only technique skills (leaf nodes) skip loading protocol. Governance and operational skills always need it. |
| "I can write the SKILL.md directly without the factory" | You can. But will you remember the frontmatter schema, layer-specific structures, and quality gates? The factory remembers. |

## Red Flags — STOP and Correct

- Writing a skill file without identifying a failure mode first
- Bundling multiple interview questions into one message
- Generating a skill skeleton with placeholders or TODOs
- Skipping the rationalizations table ("I'll add those later")
- Creating a skill that doesn't fit one constraint type (split it)
- Presenting the skeleton without checking quality gates
- Skipping the handoff to writing-skills (the factory doesn't write files itself)

## Quick Reference

| Phase | Gate | Evidence |
|-------|------|----------|
| **Interview Q1** | Failure mode identified | Written description of what goes wrong |
| **Interview Q2** | Layer determined | governance / operational / technique |
| **Interview Q3** | Iron Law stated | NO ___ WITHOUT ___ |
| **Interview Q4** | Dependencies mapped | `needs` list |
| **Interview Q5** | Rationalizations captured | At least 5 entries |
| **Interview Q6** | Evidence defined | Per-phase artifact list |
| **Gate** | Failure mode exists | If not: STOP, suggest documentation instead |
| **Generation** | Skeleton complete | All sections present, no placeholders, quality gates passed |
| **Handoff** | User approves skeleton | Invoke writing-skills for file creation |
```

Note: Replace the triple-backtick-with-spaces in the Iron Law code block with actual triple backticks. (The spaces are only present here to avoid markdown nesting issues in this plan document.)

- [ ] **Step 3: Verify the file**

Run: `head -15 skills/skill-factory/SKILL.md`
Expected: Frontmatter with `layer: governance`, `needs: - superpowers:writing-skills`, `loading: deferred`

Run: `grep -c "##" skills/skill-factory/SKILL.md`
Expected: 15+ section headers

Run: `grep "NO SKILL WITHOUT" skills/skill-factory/SKILL.md`
Expected: At least one match (the Iron Law)

- [ ] **Step 4: Commit**

```bash
git add skills/skill-factory/SKILL.md
git commit -m "feat: add skill-factory governance skill for composable skill authoring"
```

---

### Task 6: Update `claude-config.txt`

**Files:**
- Modify: `claude-config.txt:52` (after existing local-skill entries)

- [ ] **Step 1: Add new local-skill entries**

After the existing local-skill lines (after line 52 `local-skill  | ralph-loop`), add:

```
local-skill  | map-instrument-narrow
local-skill  | skill-factory
```

The local-skill block should now read:

```
local-skill  | rigorous-refactor
local-skill  | ralph-loop
local-skill  | map-instrument-narrow
local-skill  | skill-factory
```

- [ ] **Step 2: Verify**

Run: `grep "local-skill" claude-config.txt`
Expected: Four entries: rigorous-refactor, ralph-loop, map-instrument-narrow, skill-factory

- [ ] **Step 3: Commit**

```bash
git add claude-config.txt
git commit -m "feat: add map-instrument-narrow and skill-factory to bootstrap config"
```

---

### Task 7: Update README.md

**Files:**
- Modify: `README.md` (skills table and bionic skills description)

- [ ] **Step 1: Update the Skills line in the "What Gets Installed" table**

Replace:

```markdown
| **Skills** | excalidraw-diagram, impeccable (20+ design skills), bionic:rigorous-refactor, bionic:ralph-loop |
```

With:

```markdown
| **Skills** | excalidraw-diagram, impeccable (20+ design skills), bionic:rigorous-refactor, bionic:ralph-loop, bionic:map-instrument-narrow, bionic:skill-factory |
```

- [ ] **Step 2: Update the bionic skills table**

Replace the existing bionic skills table:

```markdown
| Skill | What it enforces |
|-------|-----------------|
| **rigorous-refactor** | Strict state machine for complex refactors: decompose into atomic units → write failing tests → verify RED → implement → independent validation via separate agent → 3-attempt escalation limit → captured proof of completion. Prevents boil-the-ocean refactoring and self-grading. |
| **ralph-loop** | Disciplined build-test-diagnose iteration cycle with three modes: DEBUG (stabilize first, then fix forward), GREENFIELD (research conventions, then build per PRD), RESEARCH-FIRST (exhaustive codebase mapping before implementation). Every iteration produces evidence; every exit requires verification. |
```

With:

```markdown
All bionic skills follow the composability schema: every skill declares a `layer` (governance/operational/technique), `needs` (dependency list), and `loading` hint in its frontmatter. Skills compose additively — each constrains a different failure mode without contradicting the others.

| Skill | Layer | What it constrains |
|-------|-------|--------------------|
| **ralph-loop** | Governance | Disciplined build-test-diagnose iteration cycle. Prevents skipping phases, exiting without evidence, and grinding past iteration limits. Three modes: DEBUG, GREENFIELD, RESEARCH-FIRST. |
| **rigorous-refactor** | Operational | Strict state machine for complex refactors. Prevents self-grading, skipping decomposition, and implementing without tests. Independent validation via separate agent. |
| **map-instrument-narrow** | Technique | Evidence-gathering for complex debugging. Prevents guessing without data, fixing without understanding, and instrumenting without architecture. MAP → INSTRUMENT → NARROW phases. |
| **skill-factory** | Governance | Interviews the user to extract a constraint, layer, dependencies, and rationalizations, then produces a composable skill skeleton. Prevents creating skills without an identified failure mode. |
```

- [ ] **Step 3: Verify**

Run: `grep "map-instrument-narrow" README.md`
Expected: At least 2 matches (table row + "What Gets Installed")

Run: `grep "skill-factory" README.md`
Expected: At least 2 matches (table row + "What Gets Installed")

Run: `grep "composability schema" README.md`
Expected: At least 1 match

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: update README with composability schema and new skills"
```

---

### Task 8: Run bootstrap and verify installation

**Files:**
- No files modified (verification only)

- [ ] **Step 1: Run the bootstrap**

```bash
./claude-bootstrap.sh
```

Expected: All local skills show `✓`, including `map-instrument-narrow (local)... ✓` and `skill-factory (local)... ✓`

- [ ] **Step 2: Verify skills are installed**

```bash
ls -la ~/.claude/skills/map-instrument-narrow/SKILL.md
ls -la ~/.claude/skills/skill-factory/SKILL.md
ls -la ~/.claude/skills/rigorous-refactor/SKILL.md
ls -la ~/.claude/skills/ralph-loop/SKILL.md
```

Expected: All four files exist

- [ ] **Step 3: Verify frontmatter in installed skills**

```bash
head -10 ~/.claude/skills/ralph-loop/SKILL.md
head -10 ~/.claude/skills/rigorous-refactor/SKILL.md
head -10 ~/.claude/skills/map-instrument-narrow/SKILL.md
head -10 ~/.claude/skills/skill-factory/SKILL.md
```

Expected: All four show `layer:`, `needs:`, and `loading:` in their frontmatter

- [ ] **Step 4: Verify CLAUDE.md was updated**

```bash
grep "Measure before fixing" ~/.claude/CLAUDE.md
```

Expected: One match

- [ ] **Step 5: Commit (no changes expected — verification only)**

No commit needed. If verification fails, return to the relevant task and fix.
