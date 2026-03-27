# Skill Composability Schema + Skill Factory

**Date:** 2026-03-27
**Status:** Approved
**Author:** Chris Lehman + Claude

## Problem

After 10 days of working with bionic's skill ecosystem, three problems emerged:

1. **Circular debugging without instrumentation.** Claude's default debugging behavior is hypothesis-driven, not evidence-driven. It reasons about what *should* be wrong and tries fixes, when the winning move is to stop reasoning and start measuring. A 7-hour debugging session was resolved in ~1 hour once instrumentation was applied systematically (map-instrument-narrow technique).

2. **Skill overlap and selection confusion.** With 100+ agents, 20+ skills, and multiple plugins, determining the right combination of skills for a task is difficult. Skills overlap without clear hierarchy. Users must explicitly name skills rather than relying on dynamic composition.

3. **No composability model.** Skills reference each other through prose ("REQUIRED SUB-SKILLS", "invoke X skill") but there is no structural schema governing layers, dependencies, or loading behavior. Each skill makes its own architectural decisions about composition.

## Mental Model

**Every skill is a constraint on behavior.**

A skill's value is not what it tells Claude to do — it's what it prevents Claude from skipping. Skills compose additively: each one narrows the space further without contradicting the others.

The authoring test: **"What does this skill prevent Claude from skipping?"** If you can't answer in one sentence, it's not a skill — it's documentation.

Three constraint types define three layers:

| Layer | Constraint type | Prevents | Loads when |
|-------|----------------|----------|------------|
| **Governance** | Process constraints | Skipping phases, exiting without evidence, grinding past limits | User invokes or another governance skill delegates |
| **Operational** | Method constraints | Self-grading, skipping decomposition, implementing without tests | Governance skill reaches the relevant phase |
| **Technique** | Observation constraints | Guessing without data, fixing without understanding | Operational skill reaches a step needing this capability |

## Composability Schema

### Frontmatter Specification

Three new fields added to every bionic skill's YAML frontmatter:

```yaml
---
name: skill-name
description: Use when [trigger condition]...
layer: governance | operational | technique
needs:
  - namespace:skill-name
  - namespace:skill-name
loading: eager | deferred | inline
---
```

### Field Definitions

**`layer`** — Where the skill sits in the hierarchy. Determines when it loads and what kind of constraint it enforces.

- `governance` — Process constraints. Controls lifecycle, iteration, escalation, evidence requirements.
- `operational` — Method constraints. Controls how specific work types are executed (refactoring, testing, reviewing).
- `technique` — Observation constraints. Controls how specific actions are performed (instrumentation, architecture mapping, narrowing).

**`needs`** — Skills this one references during execution. A dependency declaration, NOT an eager-load directive. The LLM decides when (and whether) to invoke each. Listed as `namespace:skill-name` (e.g., `bionic:rigorous-refactor`, `superpowers:systematic-debugging`).

**`loading`** — How the LLM should treat this skill when it appears in another skill's `needs` list:

| Value | Meaning | Use when |
|-------|---------|----------|
| `eager` | Load immediately when parent loads | Safety constraints, governance guardrails |
| `deferred` | Load when parent reaches the referencing step | Most skills (this is the default) |
| `inline` | Don't load; parent contains sufficient inline instructions | Well-known patterns where LLM training suffices |

Default is `deferred` when omitted.

### Loading Protocol

Added as a section to every governance and operational skill (~40 tokens):

```markdown
## Sub-Skill Loading

This skill references sub-skills listed in `needs`. Do not preload them.
Load each when you reach the phase that invokes it. Release focus on a
sub-skill's rules when you leave that phase. Depth limit: 3 layers
(governance -> operational -> technique). Beyond that, use judgment.
```

### Design Rationale

**Why not a routing table or skill manifest?** A routing table would duplicate the dispatch logic already embedded in skill prose and Claude's own judgment. Two sources of truth drift. The `description` field in frontmatter already serves as the trigger condition, evaluated by the LLM using natural language understanding.

**Why not trigger conditions in frontmatter?** The LLM cannot reliably pattern-match against structured boolean expressions. It is better at interpreting natural language descriptions. Trigger conditions are nuanced ("any hard trigger, or 2+ soft triggers") and don't reduce well to `when:` clauses.

**Why not a `behaviors` field?** Forward-compatible addition for when the skill count warrants it. At current scale (4 skills), the constraint mental model + skill factory make named behaviors unnecessary. Can be added later without changing anything already built.

**Why `deferred` as default?** Token budget. A full ralph-loop chain loading all sub-skills eagerly consumes ~11,500 tokens (~6% of context) before any code. Deferred loading means only the currently active skill's instructions occupy attention. The LLM loads sub-skills at phase boundaries and can release focus when leaving a phase.

**Depth limit of 3.** Governance -> operational -> technique is the maximum useful chain. Beyond that, instruction compliance degrades as the LLM tracks too many concurrent state machines. If a technique skill would need a sub-technique, the LLM uses judgment instead.

## Dependency Graph

```
ralph-loop [governance]
|-- bionic:rigorous-refactor [operational] --> TEST phase
|   |-- superpowers:test-driven-development [technique]
|   +-- superpowers:verification-before-completion [technique]
|-- superpowers:systematic-debugging [operational] --> DIAGNOSE phase
|   +-- bionic:map-instrument-narrow [technique] --> when hard/soft triggers met
+-- superpowers:verification-before-completion [technique] --> EXIT gate

skill-factory [governance]
+-- superpowers:writing-skills [operational] --> Phase 3 handoff
```

## Deliverables

### 1. Refactored `ralph-loop`

**Frontmatter:**
```yaml
---
name: ralph-loop
description: Use when debugging broken features, implementing greenfield functionality, or researching a codebase before a complex change -- any task requiring iterative build-test-diagnose cycles to reach verified working software
layer: governance
needs:
  - bionic:rigorous-refactor
  - bionic:map-instrument-narrow
  - superpowers:systematic-debugging
  - superpowers:verification-before-completion
loading: deferred
---
```

**Prose changes:**
- Add Sub-Skill Loading protocol section
- In DIAGNOSE phase, add: "If the failure involves hard triggers (prior fix failed without data, async execution, third-party internals) or 2+ soft triggers from `bionic:map-instrument-narrow`, load and follow that skill before attempting a fix."
- No changes to cycle structure, mode selection, or rationalizations

### 2. Refactored `rigorous-refactor`

**Frontmatter:**
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

**Prose changes:**
- Add Sub-Skill Loading protocol section
- No other changes

### 3. `map-instrument-narrow` (new to project)

Move from `~/.claude/skills/map-instrument-narrow/` to `bionic/skills/map-instrument-narrow/`.

**Frontmatter:**
```yaml
---
name: map-instrument-narrow
description: Use when debugging requires understanding unfamiliar system internals before instrumentation will be interpretable -- especially async execution, third-party library code, state mutations with no obvious code path between cause and effect, or when prior fix attempts failed without data
layer: technique
needs: []
loading: deferred
---
```

**Prose changes:**
- Update Layer declaration to reference schema: "**Layer:** Technique (observation constraint). Invoked inside `systematic-debugging`'s Phase 1 'Gather Evidence' or `ralph-loop`'s DIAGNOSE phase when hard/soft triggers are met."
- No other changes to the MAP/INSTRUMENT/NARROW phases

### 4. `skill-factory` (new skill)

**Frontmatter:**
```yaml
---
name: skill-factory
description: Use when creating a new bionic skill -- interviews the user to extract the constraint, layer, dependencies, and rationalizations, then hands off to skill-creator for file generation
layer: governance
needs:
  - superpowers:writing-skills
loading: deferred
---
```

**Iron Law:** `NO SKILL WITHOUT AN IDENTIFIED FAILURE MODE.`

**Phase 1: Constraint Extraction (Interview)**

Six questions, asked one at a time:

1. *"What does Claude skip or get wrong without this skill?"* -- identifies the failure mode
2. *"Is that a process failure (skipping phases/evidence), a method failure (skipping decomposition/testing), or a perception failure (skipping observation/measurement)?"* -- determines layer (governance/operational/technique)
3. *"State the constraint as: NO ___ WITHOUT ___"* -- the Iron Law
4. *"What other constraints must be active alongside this one?"* -- the `needs` list (from existing bionic/superpowers skills)
5. *"How will Claude rationalize skipping this? Give at least 5 ways."* -- the rationalizations table
6. *"What artifact proves the constraint was respected?"* -- evidence requirements per phase

**Phase 2: Schema Generation**

From interview answers, the factory produces:

- Complete frontmatter (`name`, `description`, `layer`, `needs`, `loading`)
- Iron Law block
- When to Use section (hard/soft triggers derived from the failure mode)
- Phase structure appropriate to the layer type:
  - Governance: lifecycle phases with iteration limits and escalation
  - Operational: state machine with gates and evidence requirements
  - Technique: sequential phases with written artifact requirements
- Constraints section
- Common Rationalizations table (minimum 5 entries from interview + factory additions)
- Red Flags section
- Quick Reference table
- Sub-Skill Loading protocol (if governance or operational)

**Phase 3: Handoff**

Invoke `superpowers:writing-skills` with the skeleton. That skill handles file writing, description trigger testing, and optimization.

**Gate:** If Phase 1 cannot identify a specific failure mode that Claude exhibits, the factory stops. Output: "This is documentation, not a skill. Write it as a reference document instead."

### 5. CLAUDE.md Addition

Add to the Bionic Philosophy section of `claude-global.md`, after "Prove it works":

```markdown
**Measure before fixing.** When debugging, instrument the system to gather
evidence before attempting any fix. Hypotheses without data produce circular
debugging. Map the architecture, capture state at boundaries, narrow to the
culprit -- then fix. One instrumented test run finds more than ten uninformed
fix attempts.
```

### 6. `claude-config.txt` Update

Add new local skills:

```
local-skill  | map-instrument-narrow
local-skill  | skill-factory
```

## Validation Criteria

1. **A new skill can be authored in under 30 minutes** by running the factory and answering 6 questions
2. **Any skill's frontmatter tells you its layer, dependencies, and loading behavior** without reading the prose body
3. **The full ralph-loop -> rigorous-refactor -> map-instrument-narrow chain loads incrementally**, not all at once (deferred loading)
4. **The "measure before fixing" principle prevents circular debugging** in future sessions
5. **The skill factory refuses to produce a skill** when no failure mode is identified (the gate works)

## Future Extensions (Not In Scope)

- **Named `behaviors` in frontmatter** — Extract cross-cutting concerns (`evidence-required`, `no-self-grading`, `three-attempt-escalation`) into named behaviors declared once, referenced by many skills. Add when skill count exceeds ~8.
- **Skill evals** — Use the factory's rationalizations table to generate test scenarios that verify skill compliance. Each rationalization becomes a test case.
- **Skill catalog** — A generated index of all bionic skills with their layers, dependencies, and Iron Laws. Auto-generated from frontmatter during bootstrap.
