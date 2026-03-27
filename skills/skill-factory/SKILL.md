---
name: skill-factory
description: Use when creating a new bionic skill — interviews the user to extract the constraint, layer, dependencies, and rationalizations, then hands off to writing-skills for file generation
layer: governance
needs:
  - superpowers:writing-skills
  - document-skills:skill-creator
loading: deferred
---

# Skill Factory

## Overview

A skill is a constraint on behavior. Its value is not what it tells Claude to do — it's what it prevents Claude from skipping. This factory interviews the user to extract the constraint, then produces a skill skeleton that follows the bionic composability schema.

**Core principle:** Every skill must identify a specific failure mode that Claude exhibits. If there is no failure mode, there is no skill — write documentation instead.

**Violating the letter of this process is violating the spirit of this process.**

**Layer:** Governance (process constraint). Constrains how skills are authored to ensure composability schema compliance.

**REQUIRED SUB-SKILLS** (declared in `needs` frontmatter):
- `superpowers:writing-skills` — handles file writing and skill verification
- `document-skills:skill-creator` — handles eval testing, description optimization, and performance benchmarking

## The Iron Law

```
NO SKILL WITHOUT AN IDENTIFIED FAILURE MODE.
```

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

1. Invoke `superpowers:writing-skills` to write the file to `skills/[skill-name]/SKILL.md`, then use `document-skills:skill-creator` for eval testing and description optimization
2. Add `local-skill  | [skill-name]` to `claude-config.txt`
3. Commit both files

## Sub-Skill Loading

This skill references sub-skills listed in `needs`. Do not preload them.
Load each when you reach the phase that invokes it. Release focus on a
sub-skill's rules when you leave that phase. Depth limit: 3 layers
(governance -> operational -> technique). Beyond that, use judgment.

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
