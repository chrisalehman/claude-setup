---
name: canonical-sdlc
description: Use when starting a large-scale development effort (new feature, architectural change, multi-day project) or when picking the skill for the current SDLC step. Routes to the canonical skill per step and gates every commit on the current step's evidence.
layer: governance
needs:
  - agent-skills:context-engineering
  - agent-skills:source-driven-development
  - agent-skills:documentation-and-adrs
  - agent-skills:idea-refine
  - agent-skills:spec-driven-development
  - agent-skills:incremental-implementation
  - browser-verify
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
  - superpowers:finishing-a-development-branch
  - superpowers:dispatching-parallel-agents
  - shape
  - impeccable
  - polish
  - critique
  - audit
  - harden
  - normalize
loading: deferred
---

<!-- GENERATED FILE — DO NOT EDIT.
     Rendered by agents-src/render.sh from agents-src/templates/skills/canonical-sdlc/SKILL.md.tmpl and the shared
     blocks in agents-src/blocks/. Edit those, then re-run `bash agents-src/render.sh`.
     tests/docs-pins.test.sh goes red whenever this file and its sources disagree. -->

# Canonical SDLC

Governs non-trivial engineering work. Every run declares a triple — `<intent> · <rigor> · <scale>` — and walks the applicable steps, leaving evidence a hook can read.

**Only the `## Hooks` section names anything that blocks. Everything else here is judgment, and you own it.**

**Iron law.** No commit without evidence from the current step. The evidence gate reads the plan's `current:` and validates that step's evidence only — it never re-checks earlier steps, so a skipped step is caught by review, not by code.

**Bulk reference.** Artifact shape, evidence-gating detail, intent-specific behaviors and the full version history live in `skills/canonical-sdlc/operational-rules.md`, beside this file. Read it when you need the detail this file compresses — it is copied with the skill, but nothing loads it for you.

## Load-time announcement

First user-facing action:

> **Canonical SDLC engaged — `<intent>` · `<rigor>` · `<scale>` (`<what that rigor buys>`).**

Triple not yet declared → say so and list the axes. Invoked as `help` → render the axis tables and stop.

## The triple

**intent** — what the deliverable is.

| Intent | Use when | Evidence delta |
|---|---|---|
| `build` | Capability that did not exist, or capability restored by ADDING machinery/interfaces/config (the machinery test). | RED→GREEN per slice. When the build IS a verification instrument, prove it CATCHES planted failures — a check that never fails is not proven to work. |
| `bugfix` | Restore intended behavior WITHIN the existing design. A repair, not new machinery. | The RED test is the failing repro. |
| `refactor` | Change structure, preserve behavior. Covers upgrades, migrations, removals/deprecations. | `behavior-preservation:` in the Step-5 block; migrations add `compat-matrix:`/`revert-plan:` (or `n/a: not a migration`). Log-only. |
| `tune` | Move a NAMED measurement toward a target. If you cannot name the measurement, it is not tune. | `baseline:`/`target:`/`re-measure:` in the Step-5 block, all three. Log-only. |
| `spike` | Timeboxed research. **Ships no code at any rigor.** | Writeup only at `<docs-root>/spikes/spike-<slug>-<YYYYMMDD>.md`. No plan file, no spec, no ADR, no commits to the integration branch. |
| `incident-response` | A live deployed surface — production or tooling — is broken for its users. The clock matters. | RCA, not ADR. Floors at `audited`. Monitoring-gap closure is part of Close-out. |

**Document and research deliverables — writeups, research reports — don't belong here.** Plain
plan mode serves them better than any row in this table, `spike` included: it ships no code at
any rigor, but its writeup is a timeboxed research artifact, not a general document-production
mode.

**rigor** — how hard the evidence tries to lie. Cumulative.

| Rigor | What you get | What you skip |
|---|---|---|
| `tested` | TDD RED→GREEN; matrix discharged at each row's tier; tests floor `pass == total`; 6-axis self-review. | Both independent assurance roles. Self-review only. |
| `peer-reviewed` | + a separate spec, + the INDEPENDENT Step-5 verification auditor on the evidence. At `scale: task` a ledger row must be proof-shaped and, once `done`, name an `auditor` verdict. | The mandatory adversarial critic. |
| `audited` | + the INDEPENDENT Step-6 adversarial critic, per-step checkpoint commits, expanded stop-and-wake. At `scale: task` a `done` row also names a `critic` verdict; at `scale: wave` an audited multi-agent plan must carry a `## Tasks` section at all. | Nothing. |

**scale** — the decomposition unit.

| Scale | Steps | Artifacts | Branch |
|---|---|---|---|
| `task` | Full set, compressed. Several per session. | ONE session plan with a `## Tasks` ledger; no per-task plan or spec. | The session's branch. |
| `wave` | Full set (0–9). Default. | One wave spec + plan; slices inside Step 4. | Wave branch off the epic integration branch; merges back at Step 8. |
| `epic` | 0–3 only. | `epic.spec.md` + `epic.plan.md`; carves waves. Does NOT run 4–9. | Owns `epic/NN-<slug>`; merges to mainline once, at close. |

**Rigor floors.** Default is scale-keyed: at `task`, `bugfix`→tested and `build`/`refactor`/`tune`→peer-reviewed; at `wave` and above, `audited`. Effective rigor is the MAX of the default and four floors — intent (`incident-response` floors at `audited`, `spike` is CAPPED at `tested`), flag (security-touching or privacy/vulnerable-population work floors at `audited`), project (`rigor-floor:` in `.bionic/config.yaml`), epic (`rigor-floor:` in epic frontmatter). Floors only push UP — the *derivation* is a MAX, never a subtraction. Provisional at Step 0, locked at Step 3. **Floors advise; they never force.** Upgrades are free, and a rigor below the derived floor is the user's to choose: advised against at Step 0, then accepted and recorded as `rigor-override:` (see the Override DSL). Nothing enforces the floors — the only check that reads them is log-only, and it logs `user-overridden` wherever that marker is present. One adjacent check does block, and it is not a floor: a task-ledger row whose rigor cell sits *below* the plan's own frontmatter `rigor:` is refused unless the row records a waiver. That is a consistency check against the value the plan declares — lower the frontmatter and the rows follow it down, so it never re-imposes a floor the user has overridden.

Do not carve a sensitive concern into a tiny unflagged wave to dodge a floor. The wave that owns the integration point carries the flag floor.

## Artifact layout

```
<docs-root>/specs/epic-NN-<slug>/{epic.spec.md, wave-NN-<slug>.spec.md, wave-NN-<slug>.requirements.md}
<docs-root>/plans/epic-NN-<slug>/{epic.plan.md, wave-NN-<slug>.plan.md}
<docs-root>/adrs/epic-NN-<slug>/adr-NNN-<slug>.md
<docs-root>/incidents/NNNN-<slug>/{spec.md, plan.md, rca.md}
<docs-root>/spikes/spike-<slug>-<YYYYMMDD>.md
<docs-root>/record/               # operational record: session logs, rotated archives,
                                  # closed-wave handoffs, inert audits. Survives Step 8.
<docs-root>/ideas/                # deferred-work briefs awaiting a wave to adopt them
.bionic/tests/                    # validation protocols re-run by hand, not by tests/run.sh
.bionic/tmp/                      # ephemera only, wiped at Step 8 — NOT a home for evidence.
                                  # Session-keyed state (engaged-/roster-/patrol-/preflight-/
                                  # sweeper-*.state) is NOT ephemera and survives that wipe
.bionic/.gitignore                # literally `*` — written on tree creation; this is what
                                  # keeps the whole tree out of git, not the project .gitignore
.bionic/config.yaml               # optional; `docs-root:` moves <docs-root> off the default
```

The first five are lifecycle artifacts and are gated: the governing-skill hook enforces
frontmatter on them and blocks a canonical artifact written anywhere else. `record/` and
`ideas/` are **operational** — nothing loads them, nothing validates them, and they are reached
only by citing a path. That is the whole distinction, and it is the boundary test applied to
this tree: growth in the gated dirs is governed, growth in the operational ones is free.

**Three artifacts, three steps** (design ledger K5; ADR-001) — Steps 1–3 write exactly one
artifact apiece, chained requirement → criterion → design decision → eval → evidence. Step 1
writes `wave-NN-<slug>.requirements.md`: numbered requirements/user stories, each with
provenance and acceptance criteria written so a "fails when" is nameable, plus Not Doing. Step
2 writes `wave-NN-<slug>.spec.md`: the technical design (domain model, architecture, ownership
table, rejected alternatives), the Eval design table, and ADR pointers. Step 3 writes
`wave-NN-<slug>.plan.md`: slices, sequencing, the dispatch ledger, and the verification matrix
rendered from Step 2's Eval design. Requirements live beside the spec, both under
`specs/epic-NN-<slug>/` — the governing-skill hook validates `*.requirements.md` frontmatter the
same way it validates `*.spec.md`, minus the design three-way rule (that stays spec-only).

**Anything the matrix cites as evidence goes in `record/`, never `tmp/`.** Auditor reports,
critic findings, review-axis artifacts, test-run captures — the matrix names them by path, so
they must outlive the run that produced them. `tmp/` is wiped at Step 8 and takes its contents
with it — everything, that is, except the session-keyed state the wipe spares by name, which is
live fleet state and not evidence either. Learned the expensive way: a wave dispatched every agent to write its report into
`tmp/`, then discharged 14 matrix rows citing those paths, and Step 8's cleanup destroyed 28
artifacts that the plan pointed at. The reasoning survived in the plan's own prose; the primary
evidence did not, which turns an audited record into testimony. Give an agent a `record/` path
in its brief, or you will pay this once too.

Every artifact carries frontmatter with `governing-skill:`, `sdlc-step:`, `intent:`/`rigor:`/`scale:`, `canonical_sdlc_version: 14`, the 5 discriminator flags, the 2 opt-in flags, and `model_plan:`. A missing one blocks the write. Artifacts never declare `mode:`. Plan files additionally carry `walk: required | exempt` — Step 0's derivation, and the key the Verify gate reads — Step 0's `design-interview:` value beside it, and, where the run's rigor sits below its derived floor, `rigor-override:` beside those. None of the three is required to write, but a `walk:` value outside the enum blocks. Spec files at `scale: wave` or `scale: epic` carry `design: <path>` or `design-waived: <user> <date> <reason>` unless the `## Design` section is in place — the three-way rule, Step 2.

**14 is the only supported version.** Any other value — an older number, an empty value, a typo — blocks at both hooks. There is one contract; an artifact either meets it or does not write. A run that predates it is brought forward to 14, not exempted.

## Steps

| Step | Governing skill | Gate |
|---|---|---|
| 0 Configure | `canonical-sdlc` | Frontmatter complete, matrix derived, user confirmed, task list created |
| 1 Scope | `agent-skills:idea-refine` | Refined idea + explicit "Not Doing" + alternatives lens cites prior art; writes `wave-NN-<slug>.requirements.md` — numbered requirements/user stories with provenance and acceptance criteria, plus Not Doing |
| 2 Design | `agent-skills:spec-driven-development` | Every requirement has an acceptance criterion; every criterion cites its `provenance:`; wave+ carries a governing design; writes `wave-NN-<slug>.spec.md` — the technical design, ownership table, and the Eval design table |
| 3 Plan | `superpowers:writing-plans` | No placeholders; `integration-branch:` present; matrix locked; slices tagged; user approved; writes `wave-NN-<slug>.plan.md` — slices, sequencing, and the verification matrix rendered from Step 2's Eval design |
| 4 Implement | `agent-skills:incremental-implementation` | Every slice RED before GREEN; assumptions logged |
| 5 Verify | `superpowers:verification-before-completion` | Walk artifact in `record/`; tests floor green; every matrix row discharged at tier or waived; auditor CONFIRMED |
| 6 Review | `agent-skills:code-review-and-quality` | Every axis has a verdict; independent critic attached |
| 7 Document | `agent-skills:documentation-and-adrs` | Every decision at medium significance or above is recorded |
| 8 Integrate | `superpowers:finishing-a-development-branch` | Wave reachable from the integration branch; worktree removed; tmp ephemera wiped |
| 9 Close-out | `agent-skills:shipping-and-launch` | Checklist + rollback; `continuation.md` written |

Committing is a cross-cutting rhythm (~once per step), not a numbered step. Update `## SDLC State` **before staging** — the gate reads the file, not the diff. Do not add a `commit:` field; the SHA lives in git.

**Engagement:** Step 1 is interactive Q&A and is never skipped. Step 2 is semi-interactive, and its Design Interview is never skipped either — only the user may waive it. Step 3 ends at one approval checkpoint. Steps 4–9 are unattended within the stop-and-wake rules.

**Per-intent deltas.** `bugfix`: Step 4's failing test is the repro. `refactor`: the Step-2 spec is "behavior preserved"; a new acceptance criterion means reclassify as `build`. `tune`: Step 1 routes to the domain skill (`impeccable` for UX, `security-and-hardening`, `performance-optimization`) and Step 5 is the baseline→target→re-measure loop. `spike`: no plan file at all. `incident-response`: Step 1 compresses to triage, and triage asks first whether service can be restored NOW — if a revert restores it, revert and verify before debugging anything; Step 7 is an RCA (summary, timeline, root cause, contributing factors, the fix, prevention with commit links, monitoring-gap analysis); Step 9 is deploy with rollback → monitor ≥1 cycle → close the monitoring gap or prove there is none.

`scale: epic` short-circuits any intent after Step 3.

### Step 0 — Configure

1. **Pre-flight.** `.bionic/` exists; `docs-root:` read from `.bionic/config.yaml` (default `.bionic/docs`) with `{specs,plans,adrs,incidents}/` present; `mkdir -p .bionic/tmp/`; both hooks installed and executable (if not, warn and record in `## Assumptions`). By this point `hooks/engage.sh` has already created `.bionic/tmp` and its `.gitignore` on a fresh project, invoking this skill being what got here — so this `mkdir -p` is idempotent, never the first act to touch the tree. Then probe the machine: `resources_probe` and `resources_budget` from `<plugin-root>/scripts/lib/resources.sh` yield the run's `parallel-budget:` — one string, recorded verbatim in plan frontmatter, printed in the display, and never re-derived downstream. The preflight attestation records the same string as its `budget=` field, so the wall, the tick and `/bionic:doctor` all read one value rather than four numbers and a formula. A machine the probe cannot read yields no line, and every budget-aware wall is inert without one.
2. **Classify the triple silently.** Infer from the request's verbs and named artifacts. Do NOT interrogate. Interview by exception only, 1–3 questions, on exactly three conditions: a genuine intent collision the classification rules do not resolve (the standing gray zones are **mechanism-swap** and **reference-content**); a suspected but unconfirmed security/privacy surface; or a scale that could be one session or several.
3. **Infer the flags.** `language` from repo files; `surface_type`/`has_ui` from the request; `multi_agent` defaults **true** (infer `false` only when there is genuinely nothing to offload — never key it off an installed plugin catalog, which silently disables the dispatched-task ledger guard); `deploy_target` **defaults to `n/a` and is never inferred** — a live surface exists only where the user names one, in the request or at this step's confirmation, and deploy-shaped signals in the repo are not that naming; `cleanup_on_finish` true; `use_worktree` false; `integration_branch` from the epic plan, else the current mainline, else `main` — print it as `unknown` rather than dropping it; `model_plan` is mechanical, never invented or recalled from memory: the orchestrator tier is the detected session model, and every other tier (implementor, senior-implementor, researcher, test-runner, auditor, critic) is read verbatim from that role's `model:` + `effort:` frontmatter in the rendered role files — `agents/*.md` in this repo, or `${CLAUDE_PLUGIN_ROOT}/agents/*.md` for an installed run.
4. **Derive the walk requirement.** From the declared surface flags: a surface an agent can open and drive → `walk: required`; nothing drivable → `walk: exempt`. It prints in the confirmation display and is recorded as plan-frontmatter `walk:`. **Exemptions derive from declared configuration and are ratified at Step 0, never invented mid-run** — there is no mid-run `n/a`, and the Verify gate reads an absent or unrecognized key as `required`, so an omission never becomes an exemption.
5. **Derive the Verification Matrix.** One row per acceptance criterion. Tier defaults: user-visible behavior → **T3**; engine-divergent → **T2 both engines** plus **T3** for the user-visible AC; pure substrate with no runtime surface → **T1/T2** with a one-line justification; perceptual fidelity → **T3**, T4 available; docs → **T0/none**. A criterion whose only evidence is a lifecycle artifact — a close-out report, `continuation.md`, an ADR — is a Step-9 checklist item, never a matrix row: it is a property of the report Step 9 writes, not a product behaviour the gate can validate mid-run. Print it under a `close-out obligations:` line in the confirmation display instead.
6. **Present the confirmation display in full, in the layout below.** Settings only — no matrix, no per-line inference rationale, no hooks-ok line, no slug line, no "at risk" lines; the Verification Matrix renders at Step 3 instead (`## Step-3 card`). Never elide, sample, summarize, defer, or restate it as prose — the user is approving exactly what they can see. An unknown value prints as `unknown` rather than dropping its line. Branches always carries both the `working` and the `integration` line. Omit Seed when no document seeded the run, and Warnings when there is nothing to warn about; every other section always prints, in the order shown.

```
Step 0 · Plan Configuration

  Purpose
    <one paragraph: what this run ships, in plain language>

  Seed                                     (only when a document seeded the run)
    brief         <path>  (rev <n>, <date>)
    source        <path>  (cherry-picks for <theme>)

  Run
    intent        <value>
    rigor         <value>  (<scale default | overridden>)
    scale         <value>
    name          <wave-NN-slug | epic-NN-slug | incident-NNNN-slug>

  Branches
    working       <branch>          (from <base branch> @ <sha>)
    integration   <branch>          (Step 8 merges here)

  Paths
    project       <abs path>
    docs          <path>            (default | from config.yaml)
    tmp           <path>            (default)
    archive       <path>            (default)
    spec          <path>            (Step 2 writes)
    plan          <path>            (Step 3 writes)
    record        <path>            (evidence)

  Machine
    budget        <n> writers · <n> suites · <n> worktrees · <n> test jobs
    probe         <n> cores · <n> GB · <n> GB free · load <f>

  Shape
    surface       <value>
    agents        <multi-agent, tiered dispatch | single-thread>
    deploy        <value>
    worktree      <value>
    cleanup       <value>

  Gates
    walk          <required | exempt>
    interview     <required | waived (<who or why>)>

  Models
    orchestrator        <detected session model>
    implementor         <model>
    senior-implementor  <model>
    researcher          <model>
    auditor             <model>
    critic              <model>
    test-runner         <model>

  Warnings                                  (preflight problems only; omitted when empty)
    <warning text>

Do you approve this configuration? Reply "approved" to ratify it.
explain <axis> · set <flag>=<value>
```

   **This layout is literal, and it is deliberately not marked unenforced.** No hook can check it — the display is conversational, never a file — so the template *is* the whole enforcement. A previous version expressed it as descriptive prose, which read as decoration and was deleted in an instruction-surface cut; the run then drifted into free-form summaries that satisfied nobody. Keep it as a block.
7. **Block until the literal reply `approved`.** No timeout, no implicit acceptance; a question, silence, or a partial reply is never transcribed as approval.
8. **Create the task list immediately on approval** — one task per planned step, `0:` marked completed. Nothing runs in between.

**The `design-interview:` flag.** `design-interview: true | false` is standing Step-0 configuration, default `true`, printed in the confirmation display above and recorded in plan frontmatter beside `walk:`. It is not derived from anything: `false` is the **standing Step-0 form** of Step 2's user-only interview waiver, carrying that waiver's whole force and none of it weakened — the run proceeds without the Design Interview because the user said so. A standing form is **not a second way to discharge that waiver**: the reason is still written verbatim into the design's assumptions, quoting the Step-0 reply, and the flag itself records with attribution — `design-interview: false <user> <date>`, the sibling literal of `design-waived:` and `rigor-override:`, because that attribution is the only trace that a human made the call. `design-interview:` is recorded, not validated — no hook parses it, unlike `walk:`, whose enum blocks at write time, and `rigor-override:`, whose presence the floor checks read; **an agent never sets it**, in either direction, and a later reader meets a decision rather than an absent interview.

**Task-list format — blessed, and it binds across every step, not just Step 0.**

- **Chronological order of execution.** The list reads top to bottom as the work will actually happen.
- **Format A — `<task>: <short desc>`** (e.g. `3: Plan — lock slices and matrix`).
- **Format B — `<task>/<slice>: <short desc>`**, only where slices are involved (e.g. `4/2: fix the window conversion`).
- **A takes precedence over B when slices are present**: the step's own entry is DROPPED and its slices stand in its place. Never print `4: Implement` above `4/1: …` — display space is precious and the parent line is duplicative. It is also a line that can never complete until all its slices do, so it carries no signal.
- **Short descriptions.** The subject is a signal, not a summary — detail belongs in the task body or the plan.
- **No filler.** Every entry is a real unit of work with a real status; nothing decorative, nothing that carries no state.
- **No freeform titles.** An entry without a `<task>:` or `<task>/<slice>:` prefix is malformed.
- Mark `in_progress` on starting and `completed` the moment it is done — never batch completions. When a subagent finishes, the orchestrator updates the entry; dispatched work is ledgered in the plan, never as a bare task.

The list is the user's visible progress surface. Nothing enforces this — no hook can read a task list — so the format is the whole discipline.

**Override DSL.** `set <axis|flag>=<value>` and `set verify(<AC>)=<tier>`, comma-separated, ending in `confirm`. `explain [axis]` renders the axis tables and never counts as confirmation; a free-text question about the display is treated as `explain`, never as a parse error. A rigor override BELOW a derivable floor is **accepted, never refused** — no code refuses it, and neither does this skill. Before locking, name the binding floor, the evidence class it was buying ("audited adds the independent critic; without it, silent wrong assumptions are caught only by self-review"), and what specifically is given up; then proceed with the user's value and record `rigor-override: <user> <date> derived=<v> chosen=<v>` in frontmatter, so every later reader sees a decision rather than a derivation error. The floor checks read that marker and log `user-overridden` instead of a violation. Advisory strength scales with the floor's reason — the security/privacy flag floor gets the strongest language here — but there are **no carve-outs**: every floor accepts the override.

**Evidence:** `Step 0: configured at <ISO> via <reply>; model_plan=<tiers>; integration-branch=<name>; parallel-budget=<writers=N suites=N worktrees=N test_jobs=N source=…>`

### Step 2 — Design

Every acceptance criterion carries a `provenance:` line naming where its requirement came from, authored *with* the criterion. Four forms: `provenance: user <date> "<quote>"` · `spec §N` · `ticket-N` · `report §N`. It is written here because circularity is undetectable downstream by definition — "correctly implements a real requirement" and "requirement transcribed from the code" are observably identical at verification time, so the distinction exists only at authoring. A citation beats a category label: a false citation means fabricating a reference anyone can check by opening the source.

The citation travels with the criterion into the plan's matrix AC block, where the evidence gate reads it. The literal value `provenance: implementation` **blocks** — a change cannot be the source of its own requirement. Only that whole value blocks; a real citation that merely contains the word passes, and a missing `provenance:` line does not block today. The block lands at the evidence gate from the Verify gate onward (`current: 5`–`9`), not while the spec and plan are still being authored: a circular citation commits freely at Steps 2–4 and meets the wall at the first Verify-gate commit. Write the real citation here anyway — this is the step where you still know it. A criterion names the behaviour and the pins that guard it, never a tally: counts of sentences or assertions are descriptive, drift with the tree, and are not requirements — when one turns out wrong the criterion is corrected, visibly and with attribution, not the tree padded to match it.

**The design back-half.** Requirements and criteria come first; the design answers them. A wave-or-epic spec then closes with a flush-left `## Design` section carrying five parts:

1. **Domain model** — the entities this change introduces or moves, each with its invariants.
2. **Component boundaries and interfaces** — which module owns what, and what crosses between them.
3. **Ownership table** — `concept → owning module (SSoT) → rendering surfaces → agreement test`, one row per concept rendered at more than one surface.
4. **Rejected alternatives** — what was considered, and why each lost.
5. **Assumptions** — what the design takes as true and would break if false.

Every design decision cites the requirements it serves. That is the middle link of the provenance chain — **requirement → design decision → criterion → evidence** — and the Step-5 auditor walks it whole. Authoring guidance, and what a table row is worth, live in `operational-rules.md`.

**The Design Interview — mandatory.** Step 2 is semi-interactive, and this is what that interactivity is for. It runs as an interview: a frame, then a walk, one turn at a time. Two shapes are refuted by dogfood — **batch presentation**, the design delivered whole as a wall of text with an ambiguous call to action, and **question-without-frame**, a fork posed before its terms exist.

**Open with the frame**, before any question: the problem and the goal; your own **Design intuition**, the shape you expect to be right, stated so the user can push on it; **Requirements served**, citing the requirements this design answers — the provenance chain's first link, upstream of every decision's own citation; a decision map naming each choice ahead **strategic** or **tactical**; the capture plan, naming where the design ledger accretes; and the artifact form derived from the form menu. Which views the change touches and which you considered and excluded belong here too, one clause each (the view menu lives in `operational-rules.md`). **Question 1 ratifies the frame**; nothing is walked until it holds.

**Then walk the map, one decision per turn.** A strategic choice gets a question stating the tension and your own lean; a tactical choice you may default, but every default is **surfaced at ratification**, never silent. The design ledger accretes visibly — each answer folds in as a named delta the turn it lands, so the user reads a design being built rather than a transcript. Load-bearing assumptions are posed as **questions to the user**, not as statements they must think to challenge.

**Close by composing.** The design goes back whole — decisions, rejected alternatives with the reason each lost, assumptions — for ratification **before the spec's first Write**. Proceed only on the user's engagement, or on the user's explicit waiver of the interview, recorded verbatim in the design's assumptions; `design-interview: false` at Step 0 is that waiver's **standing Step-0 form** — recorded as `false <user> <date>`, and the verbatim assumptions line is still owed, quoting the Step-0 reply. Silence is not engagement, and **an agent never waives it** — there is no agent-side waiver.

No new *approval* stop: the binding approval remains the Step-3 checkpoint, which ratifies design, plan, and matrix together, and the wall below is a write-time structural gate that grants approval to nothing. **No hook can see a conversation** — exactly as with Step 1's Q&A, the mandate is the whole enforcement. It does fix the authoring order: the interview is where the design gets composed, so the spec lands after it in one complete Write — a requirements-only first draft of a wave-or-epic spec blocks on the write that would create the file.

**The form menu — derived, then ratified, never mandated.** What the design is *written as* is itself a decision the frame carries. Five forms: a **design paragraph** in the session plan (the task-scale form); a flush-left **`## Design` section** in the spec (the wave default); a **standalone design doc** for a design that outlives the wave or serves as a `design:` pointer target; **structured models** — a logical domain model, C4 views, sequence diagrams — where the change's shape is the hard part; and a **full Technical Design Document** where the surface is large enough that its decisions no longer fit beside the requirements. Derivation heuristics live in `operational-rules.md`; what they produce is a *suggested default*, printed in the frame and ratified, moved up, or moved down by the user there.

**One wall, three ways to satisfy it.** A spec at `scale: wave` or `scale: epic` must carry at least one of:

- **(a) in place** — a flush-left `## Design` section in the spec itself;
- **(b) by reference** — frontmatter `design: <path>` resolving to a real file that itself contains a flush-left `## Design`; typically an epic-level design a wave implements. Path resolution follows the walk-artifact template, widened by its leader set: an absolute path stands as written; a path led by one of the docs-root artifact directories — `specs/`, `plans/`, `adrs/`, `incidents/`, `record/` — resolves against the docs root; every other relative path resolves against the project root, so the fully-spelled `.bionic/docs/specs/…` an author is likely to paste lands where the short form does; and a `..` component is refused outright. A wave may carry both the pointer and a supplementary local section, and a pointer that is present is validated either way — it names the path the Step-3 approval display prints, so it is never decorative;
- **(c) waived** — frontmatter `design-waived:`, the user's move, documented with the Waiver Protocol.

Presence and resolution are the whole check; the five parts are never inspected and their quality never graded. An empty `## Design` clears the wall and fails the Step-3 approval — which is the ratification that was always going to be the one that could tell.

**Scale.** `task` gets a design paragraph per non-trivial task, written in the session plan — a prose obligation the reviewer reads, with **no wall at task scale at all**. `wave` gets a page or two. Nothing gets forty.

### Step 3 — Plan shape

Two sections are required in every plan file.

`## SDLC State` opens with `integration-branch:`, the triple, and `current: <N>` — the hook greps `^current:` and blocks every commit if it is missing or malformed. Write `current:`, never `current-step:`. Then one `Step N: <evidence>` line per step; bump `current:` and replace the line in place when advancing.

```
## SDLC State

integration-branch: <name>
intent: <intent>
rigor: <rigor>
scale: <scale>
current: <N>

- Step 0: <evidence, ending in the run's parallel-budget string>
- Step 1: (pending)
```

**Task-scale variant.** `current: T<n>`, one `- T<n>: <evidence>` line per task, backed by a `## Tasks` table with columns `| id | intent | rigor | description | status |`, `id` matching `^T[0-9]+$` and status in `pending|active|done|dropped`. A row's rigor cell may RAISE that task above the frontmatter default; lowering it is a downgrade that blocks unless the evidence line carries a `waiver:` marker. Dispatched work is ledgered by the orchestrator, never by the subagent.

`## Assumptions` is seeded from Step 1's "Not Doing" plus spec ambiguities; Step 4 appends inline, before the commit that resolves each one.

Tag every Step-4 slice `complexity: standard | complex`. When uncertain, tag `complex`.

**The approval presentation names the governing design.** One line, listing the absolute path(s) of whatever governs — the spec carrying the `## Design` section, the file its `design:` pointer resolves to, or the word `waived` — with an instruction to review them before answering. Do not render the design's content in the display: paths are what the user opens, and a transcribed domain model is ceremony that makes the display longer without making the decision better. The sole gate is approved / not approved.

**Wave shape locks at approval.** Mid-wave discoveries go to `## Assumptions` as W+1 candidates — they do not reshape the current wave. Two exceptions: a discovery that makes the wave structurally impossible (surface a Wake Note and halt — the answer is "this wave cannot ship," not "ship a different wave"), and one-line trivial corrections.

### Step 5 — Verify

The gate discharges the matrix row by row; the unit is the matrix row (`5/<AC-id>`).

**The walk opens verification.** Before any row discharges, an agent that has NOT read the acceptance criteria opens the real running surface and narrates what it sees at the code and behavior this wave intentionally changed — what was seen, never whether an expectation was met. It runs first because it is the cheapest catcher and sits structurally outside the criteria frame, so it finds what nobody knew to look for, before effort is spent row by row.

The narration goes to `<docs-root>/record/`, named by a `walk-artifact:` line in the Step-5 evidence: `record/<file>.md` resolves against the docs root, a bare path against the project root, an absolute path stands as written — any spelling must land under `record/`, and a `..` component is refused outright. **The artifact carries zero AC identifiers** — a walk that says "AC-4: confirmed" is a checklist wearing prose, and `grep -E 'AC-[0-9]'` is the whole content rule. Existence is the wall the gate can check; running it first is discipline no hook can see. Frontmatter `walk: exempt` makes the demand inert and is a Step-0 ratification — absent or off-enum, the key reads as `required`. The demand re-checks at `current: 5` through `9`, so the artifact cannot be deleted without blocking across that range — but, like every other post-Verify prefix check, a sub-step marker such as `current: 8b` falls outside the checked set, a pre-existing hole this arm inherits rather than introduces.

**Tests floor, always:** run every applicable suite and the build, record `cmd:`/`pass:`/`total:`/`output:`, `pass == total`. No `n/a`.

**Environments — declared, covered, fog.** A plan's frontmatter may carry `environments:`, one line of entries joined by " · ", each `<name> (covered by this wave)` or `<name> (fog — cure: <how it gets covered instead>)`. Naming the set is optional — a plan that never mentions it makes no environment claim and the gate stays out of the way. Naming it binds: the Step-5 evidence must carry an `environments-covered:` line listing every declared non-fog environment, and a fog entry with no cure blocks. This is a claim about *where* the tests floor ran, never a substitute for it — the derived suite set a `Files:`/impact-command wall produces governs dispatch only, and the unconditional whole-suite floor above runs on every change regardless of what `environments:` says. A fog environment is one the plan names but this run cannot execute on, so its claim is honest only with a `cure:` naming how it gets covered instead.

"Every applicable suite" is a **discovered** set, not whatever the default command runs. Check `package.json`, `Makefile`, CI config, test-runner configs, and test directories for suites the default runner omits — a hand-listed runner that silently drops a suite reports green over untested code. When a change touches code with existing tests, triage each affected test as UPDATE / ADD / REMOVE / OK before implementing, not after.

**Matrix section** carries a `stack-health:` line (a before/after snapshot bracketing the discharge pass, or `n/a: <reason>` — bare `n/a` blocks), the tier table `| AC | tier | status | evidence | auditor |` with exactly five cells per row, no literal `|` inside a cell, tier in `T0`–`T4`, status in `pending|blocked|discharged|waived`, and one evidence block per AC. An evidence block opens with its AC identifier flush left — `AC-1:` — or as a flush-left list item (`- AC-1:`, `* AC-1:`, `+ AC-1:`); its evidence lines are indented beneath it, and an indented header is not read. Reading the stack-health snapshot is human judgment; nothing compares before against after.

**The T0–T4 ladder.** Each tier is defined by which lie it makes impossible.

| Tier | Name | Proves | The false green it kills |
|---|---|---|---|
| **T0** | Static | compiles / builds / lints | type & build breaks |
| **T1** | Unit | logic at mocked seams | wrong logic |
| **T2** | Hermetic | real browser + real engine over a **declared-fidelity fixture** | integration breaks — *only if the fixture matches the real data shape* |
| **T3** | Live agent-drive | the **declared real surface**, real data, cold client, trusted input, feature-scoped semantic readback | every proxy: wrong surface, stale artifact, synthetic data, warm caches |
| **T4** | Human walk | the user's own hands and eyes | perceptual / judgment gaps automation can't close |

A lower tier passing while a higher one fails is a **locator, not a contradiction** — the bug lives in exactly the layer the lower tier elides.

**T2 fixture-fidelity.** A T2 row declares in one line where its fixture came from (the `fixture-fidelity` key — not the AC's `provenance:` citation, which names the requirement's source): derived from, or validated against, a real captured artifact of the data the AC concerns. A fixture that cannot structurally reach the failure the AC guards is a proxy regardless of its RED→GREEN history — undeclared, a T2 row is a T1 row wearing a browser.

**Per-tier required keys** — the canonical table; the hooks mirror it, so change this first.

| Tier | Required keys in the AC block |
|---|---|
| T0, T1 | `tier-run`, `readback` |
| T2 | `tier-run`, `readback`, `fixture-fidelity` |
| T3 | `tier-run`, `fresh`, `cold-client`, `contact`, `readback` |
| T4 | `user-confirmed` |

**Tier-Discharge Rule.** Lower-tier evidence never discharges a higher-tier row; higher-tier evidence discharges lower-tier rows for the same AC. A row whose criterion names a PRODUCER and a CONSUMER (a library function AND the hook that calls it; a value AND the surface that renders it) is discharged only by evidence that reaches the consumer — the producer's own suite green is the lower tier of that row, not the row (wave 1.4.0: AC-28's lease-overrun NOTIFY was discharged on the library suite alone while nothing called the function; the architecture axis found it, the matrix had not). A green suite can never stand in for a T3 row — a suite run cannot honestly produce `fresh`/`cold-client`/`contact`. T3's validity conditions live in `browser-verify`; do not restate them. An undrivable T3 row is **blocked**, loudly, never silently skipped. T4 rows are discharged by `user-confirmed: <user> <date> <what was walked>` — agents never self-confirm one. The browser modality's `playwright-cli` is an environment-class dependency: absence is detected via `jit_check`, offered via `jit_offer` (`payload/scripts/lib/jit.sh`), and a decline degrades cleanly per its printed line rather than a row silently going unattempted.

**Absence-readback rule.** A readback that is zero, empty, or not-present proves nothing on its own — an all-zero observation reads identically whether the code works or was deleted. Such a row needs a paired positive case: the same readback returning a non-empty result where the behavior says it should. Without one the row is presumed powerless and cannot discharge, at any tier. No hook reads this; the auditor mandate carries it as judgment.

**False-green rule.** On finding any test that passed over broken code, the gate cannot close until the matrix carries `false-green: <test — what it lied about>` AND a paired `rewritten: <ref>` proving the test now goes RED.

**Vocabulary.** Say "delivered/fixed/verified" only at the row's contracted tier. Below tier the honest phrasing is "implemented, verification pending."

**Mid-discharge commits.** At `current: 5`, rows still `pending`/`blocked` are exempt from per-tier keys and the `auditor:` pointer is required only once none remain. The full contract bites on the 5→6 advance, where the matrix is re-validated as a prefix check at every step from 6 on. **Never regress `current:` to dodge a gate.**

#### Auditor — the Step-5 exit gate

A **fresh, independent** exec-complex agent (`subagent_type: bionic:auditor`) — never the implementer, never a fork of the orchestrator, whose context is the thing under audit. Dispatch carries this mandate **verbatim**; a paraphrase is a weakened auditor:

<!-- AUDITOR-MANDATE-BEGIN -->
> Your job is to falsify the claim that this wave's requirements were faithfully implemented **and proven** — not to review its code. You hold the spec, its governing design, the Verification Matrix, the per-row evidence, and repo access. Walk three levels, top-down. **(1) Coverage** — walk the chain whole: requirement → design decision → criterion → evidence. For every requirement in the spec, name both the design decisions and the criteria that serve it; a requirement answered by criteria but by no design decision is a hole in the chain, not a covered requirement (where the design is waived, say so and walk requirement → criterion). Seed this mechanically: invert the `provenance:` citation map and the design section's requirement references, and requirements with zero inbound citations from either are the uncovered list before any judgment is spent; spend the judgment on the harder half — requirements cited but weakly expressed, covered in letter and missed in substance. A hole is a **wave-level** finding, because the per-row verdict scheme cannot express a missing row: emit one wave-level verdict alongside the row verdicts. **(2) Power** — for every row, state what the observation would have shown had the change been absent; if the answer is "the same thing," the row proves nothing, whatever its tier. A zero, empty, or not-present readback with no paired positive case is presumed powerless and cannot discharge — you are that rule's enforcement. Once per wave, go one step past judgment with a revert-and-watch demonstration: you are read-only and must not revert or stub anything yourself, so have the test-runner revert or stub the named change and capture a named check going red, then validate the capture — the change really absent, the check one the matrix leans on, the red the failure you predicted. Its value over per-slice RED evidence is that it is durable, auditable after integration, and covers the whole change. **(3) Authenticity** — confirm each row's evidence was produced at its declared tier: a T3 row must cite the declared real surface, its per-origin freshness proofs, a cold client, and a feature-scoped semantic readback; a T2 row must carry its fixture-fidelity declaration, and the fixture must be structurally able to reach the failure the AC guards. Re-execute at least one evidence command per tier used (cap 3 total) and compare outputs. Verdict per row **and one for the wave**: CONFIRMED / REFUTED / UNVERIFIABLE. "The evidence is plausible" is not a verdict. Agreement without re-execution is not acceptable output. Hold every report to the reporting contract: a factual claim carrying neither its proving command with output nor the label "unverified" is itself a finding.
<!-- AUDITOR-MANDATE-END -->

Bounds: audits the verification, not the wave — never re-verifies the feature, re-runs the whole suite, or reviews the code. The boundary with Step 6's critic sharpens rather than moves: the auditor proves the *verification* faithful to the *requirements*; the critic attacks the *code*. Read-only is literal — the revert-and-watch demonstration is performed by the `test-runner` on request and the auditor validates the capture it returns. One auditor, one pass, ≤3 re-executions.

Row verdicts land in the matrix `auditor` column; the wave verdict lands on its own `auditor-wave: <verdict> — <coverage finding>` line beside `stack-health:` above the table (no hook reads it — the mandate is the enforcement). Any REFUTED or UNVERIFIABLE row blocks closure absent a waiver, and so does a non-CONFIRMED wave verdict — which is where a requirement with no row can be reported at all.

#### Waiver Protocol

Three moves are the user's, never an agent's: a tier **downgrade**, an **`n/a` on a live tier (T3/T4)**, and **closing over a non-CONFIRMED row**. Each is recorded as `waiver: <user> <date> <reason>` in the row. A waived row is exempt from its per-tier keys and from CONFIRMED. Agents never self-write `n/a` on a live-tier field.

**A user-confirmed T4 row is none of those moves, and needs no waiver.** T4's evidence *is* the user's confirmation, so an auditor sent at it can only re-read what the user said — transcription, not independence. A T4 row whose block carries `user-confirmed: <user> <date> <what they confirmed>` therefore discharges past the Verify gate on that value alone, with no auditor verdict and no waiver. Reaching for the Waiver Protocol here records a waiver where nothing was waived, and the row then reads forever as a criterion that was let go. The attribution is the whole test: an unattributed or agent-written claim ("confirmed after the re-render") is not a user confirmation and still meets the CONFIRMED wall.

Note the hole: the hook checks only that the token `waiver` is present — not who, when, or why. And retyping a tier cell from T3 to T2 is a downgrade no hook sees.

**Design waiver.** A fourth user-only move, sitting on the artifact rather than on a matrix row: `design-waived: <user> <date> <reason>` in a wave-or-epic spec's frontmatter, quieting the design wall for that artifact. Recorded, not validated — presence is the whole check, matching the `waiver:` and `rigor-override:` precedent, and the fields are written for the next reader. An agent never writes one. It means *no design governs this artifact*, which is not the same claim as "the design lives elsewhere" — that one is the `design:` pointer, and reaching for the waiver instead throws away the path the approval display exists to show.

### Step 6 — Review

**Stance 1 — 6-axis self-review, always.** Correctness, readability, architecture, security, performance, duplication; every axis gets an explicit PASS / FLAG / FAIL. Run the axes in parallel. All review agents dispatch at exec-complex regardless of who wrote the code — verification is never cheaper than authorship. Security flags escalate to `agent-skills:security-and-hardening`; performance flags to `agent-skills:performance-optimization`.

**Architecture-axis closure check:** for each new primitive added this wave, trace user input → new code, and confirm the Step-5 T3 readback reached the same code. No callsite reaching it means the substrate is dead and the axis is FAIL.

<!-- DUPLICATION-AXIS-BEGIN -->
**Duplication axis — one implementation site per concept.** The design's ownership table is the anchor: its owner column already says where each concept lives, so the axis is a comparison, not a hunt. A second site computing or deciding the same thing is a FLAG; a concept the table gives two owners is a FAIL; a concept the wave introduced and the table never named is a FLAG against the design, not against the code.

**Agreement tests.** Each shared-truth pair in the ownership table — one concept, more than one rendering surface — names one hermetic test that fails when the surfaces disagree. The standing exemplar is `tests/cross-gate-agreement.test.sh` §N.1: one logical text, the loader idiom, rendered into nineteen hooks, pinned byte-for-byte against `bionic_loader_pin`'s live output, with a mutation arm that doctors one copy and proves the pin goes red. §R does the same for the four-copy `resolve_docs_root` family — and it is also the honest limit: until wave 1.4.0 that section built its mutant and asserted nothing, and two documents cited it as the safety net anyway. A pin nobody has watched fail is prose wearing a test. A listed pair with no named test is a FLAG, and "the suite covers it" is not a named test.
<!-- DUPLICATION-AXIS-END -->

Neither of these is a wall. **No hook sees the duplication axis or the agreement-test obligation** — they are carried by the reviewer and critic mandates and enforced by judgment, which is the whole reason the ownership table is authored at Step 2 where a human ratifies it.

**Stance 2 — adversarial critic.** Mandatory at `audited`. Must be an **independent** agent (`subagent_type: bionic:critic`) — never the author, never self-graded. Distinct from the Step-5 auditor: the critic falsifies the *code*, the auditor falsifies the *evidence*. Prompt template:

<!-- CRITIC-TEMPLATE-BEGIN -->
> _Your job is to find what went wrong in this change. You have the spec, the plan, the diff, and the 6-axis self-review notes. Read them and try to falsify the claim that this is ready to merge. Look specifically for: silent wrong assumptions not logged in the `## Assumptions` section, scope creep beyond the spec, missing edge cases, fabricated evidence, and cross-cutting concerns a single-axis review would miss. Output either: at least one specific, reproducible issue, or an explicit "no issues found" followed by the three strongest falsification attempts you made and why each failed. Confirmation-seeking agreement is not acceptable output._
<!-- CRITIC-TEMPLATE-END -->

Incident framing: does the fix mask a deeper issue, and is the monitoring-gap analysis honest. Sycophantic output is not evidence.

### Step 7 — Document

ADRs attach to decision **significance**, not to rigor: momentous (cross-wave, sets a precedent, expensive to reverse) gets one at any rigor; medium gets one when it will shape later waves; trivial gets none. `incident-response` writes the RCA instead. Where any doc produced here should live is settled by one question — **who reads it unbidden?** Nobody → operational: park it at a path and cite that path when it is needed; nothing loads it on its own, so its size costs nothing and it may grow freely. Every session → knowledge: it reaches a reader only if the always-loaded index points at it, and that index is read in full every time, so it must earn its line or not be written.

This test used to live in the always-loaded global config, which is where a preceding wave deliberately put it. It moved here because it failed itself: it is consulted only when a document is being written, which by its own definition makes it operational, and operational content is path-addressed. A rule that loads every session to answer a question asked occasionally is the exact cost it exists to prevent.

### Step 8 — Integrate & close

Atomic, one task. Merge the wave into the declared integration branch (local merge; pushing is the user's gate) and remove the worktree. Default is merge — parking requires an explicit `## Wake Note`. Then, when `cleanup_on_finish: true`: skip if frontmatter already has `cleaned:`; wipe `.bionic/tmp/` EPHEMERA ONLY, sparing every session-keyed file — `engaged-*.state`, `roster-*.state`, `patrol-*.state*`, `preflight-*.state`, `sweeper-*.state` — because one root can hold another session's live run, and a blanket wipe takes that session's engagement marker, roster and Patrol stamp with it, un-engaging a conversation mid-run and contradicting this file's own rule that the marker is never removed during the session; assert zero non-completed tasks; strip stray `continuation-checkpoint.md`/`handoff-*.md`; set `cleaned: <today>`.

### Step 9 — Close-out

**Close-out is an institution, not a courtesy.** Every finding this run's rigor machinery surfaced — walk, matrix discharge, auditor, critic — gets exactly one terminal disposition. "Continuation candidate" is abolished; nothing leaves this step homeless.

<!-- TERMINAL-DISPOSITION-BEGIN -->
> Abolish "continuation candidate." Every finding gets exactly one of three terminal
> dispositions at wave close:
> 1. **DO-NOW** — folded into the closing wave.
> 2. **ACCEPT-CLOSED** — ruled won't-fix, recorded beside its reasoning, and never
>    carried forward again. An accepted residual is knowledge, not work.
> 3. **PROMOTE** — kept only with one of two homes: **(a) a trigger** — the named
>    EVENT that reactivates it ("diagnose the flake when it next fires — output now
>    preserved"), or **(b) a charter** — promotion into a named future effort (an
>    ideas/ seed or epic charter) by the user's explicit materiality ruling at close.
>    A charter costs a decision and gives the work its own document that competes
>    for prioritization openly. What stays forbidden is the homeless deferral: an
>    item on a wave's continuation list with no decision, no home, no identity —
>    that is what schedules cleanup waves by momentum. (Amended 2026-08-16 on
>    Chris's catch: the original trigger-only form had no bin for legitimately
>    deferred major work — the plugin conversion itself is the proof case.)
<!-- TERMINAL-DISPOSITION-END -->

The vehicle is a single-turn close-out report, sent to the user at Step 9 and never re-run as ceremony: plain English, at the altitude of decisions rather than of code, covering ten parts — goal, accomplished, deferred-with-dispositions (each finding's DO-NOW / ACCEPT-CLOSED / PROMOTE named), special attention, material risks, challenges, decisions, success/failure verdict, learnings, next. Authoring detail per part and the anti-ceremony bound live in `operational-rules.md`. Write `continuation.md` (§Handoff above) alongside it — the report is what the user reads; the file is what the next wave opens.

**Where the run ends.** Every close-out records `delivered:` — the terminal state of the work, which is a PR open and ready for a human to review, or commits landed locally and ready to push. That boundary is the default endpoint of the lifecycle: what happens past it is the human's process, and a run that claims it has overstated what it did.

Where — and only where — `deploy_target` names a live surface this run operates, the close-out also carries `deployed:`, `verified:`, and `monitored:`: the release lands, it is verified on the surface, and it is watched for one cycle before the report claims done. `deploy_target` defaults to `n/a` and is never inferred (Step 0), so this trio is strictly opt-in — the ordinary run owes nothing past delivery.

## Evidence shapes

One evidence artifact per step under `Step N:` in `## SDLC State`. The gate validates the current step only.

| Step | Required fields |
|---|---|
| 0 | `prereqs: ok` |
| 1, 2, 3 | pointer (presence only) |
| 4 | pointer; plus `worktree:`/`base-sha:`/`branch:` when `use_worktree: true` |
| 5 | `cmd:`/`pass:`/`total:`/`output:` with `pass == total`, a valid `## Verification Matrix`, `walk-artifact:` naming a real file under `<docs-root>/record/` once any row is `discharged` (unless `walk: exempt`), and — once no row is `pending`/`blocked` — a non-empty `auditor:` |
| 6 | pointer to the 6-axis body + critic findings; matrix re-validated here |
| 7 | `adr:` OR `rca:` OR `n/a:` |
| 8 | `merge:`, `worktree-removed:`, and (`cleanup:`, `tmp-wiped:`, `tasks-completed:` OR `cleanup: n/a`) |
| 9 | `delivered:` always, ON the `Step 9:` line itself — the run-closure predicate (`lib/run.sh`) greps that one line, so a `delivered:` written on a continuation line leaves the run open forever; plus `deployed:`, `verified:`, `monitored:` exactly when `deploy_target` names a live surface |

**Placeholder ban.** These exact values are rejected anywhere evidence is required: `todo`, `pending`, `in progress`, `inprogress`, `xxx`, `tbd`, `placeholder`.

**Handoff.** A plan spanning sessions carries a `## Handoff` section — resume point (step, sub-task, branch, last commit), decisions ratified this session (reset each time), tried-and-rejected and discovered surprises (persist), open blockers, uncommitted work, and a literal resume instruction. Rewritten in place, never appended. Nothing writes or checks it. At Step 9 write `continuation.md` — wave completed, integration branch + merge SHA, next wave, open carry-overs.

## Hooks

**`canonical-sdlc-evidence-gate.sh`** (`PreToolUse|Bash`) fires only on a real `git commit` segment. It finds the newest `*.md` under the plan dirs, and if it has a `## SDLC State` section, validates the current step's evidence, the matrix, and the task ledger. **From `current: 5` onward** it also blocks on `provenance: implementation` in any AC block — read flush left or as a flush-left list item (`AC-1:`, `- AC-1:`, `* AC-1:`, `+ AC-1:`; an indented header is not read) — and, once any row is `discharged` and the plan does not declare `walk: exempt`, on a missing `walk-artifact:` line, a path that does not resolve to a real file under `<docs-root>/record/`, or an AC identifier inside that file. **The gate reads the plan as it is when the call starts, not as it will be once the rest of the command runs** — a Bash call that edits the plan and commits in the same invocation is judged on the pre-edit plan, so edit the plan in one call and commit in a separate one. Log-only (never blocks): the epic merge-target check, and the `refactor`/`tune` intent-scoped Step-5 keys.

**`canonical-sdlc-governing-skill.sh`** (`PreToolUse|Write,Edit`) blocks any artifact under `<docs-root>/{specs,plans,adrs,incidents}/` lacking `governing-skill:` frontmatter, and blocks a `mode:` line, a missing or non-enum triple, a missing flag or `model_plan`, a `walk:` value outside `required|exempt`, or a missing `## Verification Matrix` at `sdlc-step ≥ 3`. On a **spec** artifact at `scale: wave` or `scale: epic` it also blocks a write satisfying no arm of the three-way design rule: no flush-left `## Design` in place, no `design:` pointer resolving to a real file that itself carries a flush-left `## Design` (a dangling path, a target without the section, and a `..` component each fail the arm), and no `design-waived:` token. A `design:` pointer that is present is validated on the unwaived path whether or not the spec also carries its own section. Plans and every task-scale artifact are untouched by it. Floor-consistency checks are log-only, and log `user-overridden` in place of a floor violation when frontmatter carries `rigor-override:` — presence only; the marker's fields are never validated, and it does not quiet a malformed `rigor-floor:` value in `config.yaml`.

**Known holes — do not mistake these for enforcement.** The governing-skill hook validates `Write` content but not `Edit` content, so one valid write covers every later edit. Flag *values* are never checked, only presence. The evidence gate reads the plan file's text, so an `Edit` that writes evidence for tests never run passes unseen. Proof-shape is a heuristic: a digit plus a `/` satisfies it.

<!-- ORCHESTRATOR-DISPATCH-BEGIN -->
## Dispatch

The orchestrator stays free: it keeps Steps 0–3, slice decomposition, and every approval-shaped decision, and offloads research, execution, verification, and review. Subagents return summaries, never payloads. Dispatch is the orchestrator's authority alone: a dispatched agent never dispatches — it asks the orchestrator — and the wall says so when a subagent tries.

Roles, by `subagent_type`: `researcher` and `test-runner` for exploration and mechanical work; `implementor` for `standard` slices; `senior-implementor` for `complex` slices and root-cause debugging; `auditor` for Step 5; `critic` for Step 6. Each role file carries its own invariant duties and model default — the dispatch prompt carries the seven things the role file cannot know: current step, the triple, scope constraint, expected artifact, exit condition, an expected duration, and — when that duration is 15 minutes or longer — a progress-artifact path the task appends to as it works (D-6). A phase-gated brief (below) adds the deliverable-phase/bookkeeping split and the gate's position to that list — the role file cannot know where its own gate sits any more than it knows its own deadline.

**The brief declares its deliverable under a canonical label — the wall never guesses one from prose.** `Expected artifact:` (or `Deliverable:`) names the one durable path the dispatch is contracted to produce; the label's span must yield exactly one path — zero refuses naming what to add, more than one refuses naming every candidate rather than picking among them. References and inputs the agent should read go outside that span: their own line, under `Read first:` or `Scope constraint:`, or after a blank line — never folded into the deliverable sentence, which is read as the contract, not as narration. A dispatch with genuinely nothing durable to produce declares `Deliverable-waiver: <reason>` instead; the waiver is recorded on the roster beside the absence it excuses, so read-only dispatches (research, review, audit) that return findings in a `SendMessage` rather than a file still land a clean row. A missing or ambiguous deliverable refuses at dispatch with the fix named — never a warning that lets the launch through anyway. **A brief that runs a suite-class command also names an `Evidence log:` line** — the path its output is `tee`'d to — on its own line, after a blank line following `Expected artifact:`: the wall reads a label's span only up to the next blank line, so folding the log path into the deliverable sentence hides it from that read.

**The brief declares the FILES the slice will touch; the machine derives the suites.** `Files:` on a line of its own names the paths this slice will write, and the impact command named in `.bionic/config.yaml` turns them into the closed set of suites the agent may run — recorded on its roster row, and held there by a budget arm that refuses any suite outside it. Where no impact command is configured, name the closed set yourself under `Suites:`; a brief that runs no suite at all waives with `Suites: none`. A brief carrying neither label refuses at dispatch. `tests/run.sh` belongs on one row per run, the Step-5 runner's — a second one refuses unless the plan's `## SDLC State` carries a `regression-cause:` line for it. `Files:` names every path the work FORCES, including a manifest a renderer refreshes and a census file whose count must move (A-28, A-32, f2-hooks-docs).

**Command discipline.** Bound a long command with the Bash tool's own `timeout` parameter — never a `timeout`/`gtimeout` binary; macOS ships neither, and a runner that falls back silently when the prefix command is missing has silently changed the run's own preconditions (the failure that motivates this: a missing `timeout` dropped an `export` prefix the retry needed, and the run went invalid unnoticed). A runner never substitutes or rewrites a brief's command on its own judgment — a command it cannot run as written is refused and reported, not adjusted.

**Five failures this wave hand-fixed, so the next brief doesn't repeat them.** A runner captures a command's exit on the command itself — `{ cmd; echo "rc=$?"; } > log 2>&1` — never `PIPESTATUS`, which is 1-indexed under the tool shell's zsh and expands to nothing (A-37(3)). A cwd guard belongs on the WHOLE command, `cd <tree> || exit 1` first, never on one `&&`-joined assignment — a failed cd with `;`-chained commands runs them in the main checkout (A-46). A writer stops touching its tree the moment it has sent its completion message — the orchestrator lands on that message (A-46). A brief names a knob only after reading its docblock — `BIONIC_TEST_TIMING` is a file path, and `=1` wrote the timing rows to a file named `1` (A-47). A brief's artifact names are checked against `ls <docs-root>/record/<wave>/` before dispatch and never reuse a Step-4 slice label — a reused name overwrote a landed slice's evidence log (A-49).

**Normative values ship as VERBATIM tables in dispatch briefs, never paraphrase** (2026-07-18, epic-07 wave 1). Two competent opus implementers resolved the same spec ambiguity (critic placement in the rigor ladder) in OPPOSITE directions because the tier→gate mapping lived in prose paraphrase; the D1/D4 tables embedded verbatim in the plan had zero drift. Where a value matters, the implementer copies a table — they don't interpret a sentence. Corollary: after correcting any such value, grep EVERY artifact that restates it (ADR ledgers, spec tables, evidence blocks) — decision records drift independently of the prose they record, and single-document review sweeps miss them.

**Liveness fields.** The progress-artifact path carries a `cadence` alongside it — how often the task is expected to write there, extending the 15-minute rule by one number: "too quiet" means quieter than the author's own declaration, not a fixed clock. A subprocess claim — a process pattern plus its output file — is conditional-required: declared only when the task backgrounds a long-running command. While the claimed process exists, quiescence is irrelevant; its absence with no deliverable is what the landing verdict reads as a broken contract. No shape label rides beside these fields — shape emerges from which are present: no progress path is short/turns, progress-plus-cadence is long in-agent, adding a subprocess claim is a delegated command.

**Backgrounding gets DECLARED in the brief** (2026-08-06, epic-15 wave-04 D3, user-ratified): when work genuinely exceeds 10 minutes or must run alongside other work, the dispatch brief MUST declare it — the `claims=` process pattern plus output file that is this subprocess claim by name — so it lands on the session roster the landing verdict later reads. Declaring `claims=` is what lets the verdict call a mid-flight row STILL-LIVE instead of UNMET; nothing watches it between decisions, and the declaration is advisory only — no bionic machinery relies on it existing.

**The Patrol.** One clock per run, and only one. **Arm it at engagement** — the Step-0 confirmation of a new run, or the resume ritual of an open one, in every session of that run — as a session-scoped cron job (`CronCreate`) at the interval `bash <plugin-root>/hooks/session-poker.sh interval` reports (config knob `poker-interval:` in `.bionic/config.yaml`, default 20m), and stamp it alive in the same breath with `bash <plugin-root>/hooks/session-poker.sh arm`. Arming is not conditional on having dispatched anything: the Patrol carries the run, not the roster, and a session that waits for a subagent to exist has no pulse for every stretch it works alone. Never an OS cron, never a resident process — the job is session-scoped, dies with the session, and the roster on disk is the record that survives it; its 7-day auto-expiry is the forgotten-disarm backstop, not the disarm. **At run close, stop it on both sides: `CronDelete` the job AND `bash <plugin-root>/hooks/session-poker.sh disarm`, which removes this session's stamp.** The stamp is the only record on disk that a Patrol is running here, so a `CronDelete` without the `disarm` leaves a deliberate stop that reads exactly like a Patrol a plugin update killed — and `hooks/patrol-revive.sh`, which cannot tell the two apart, then reports the stop you chose as a death on every remaining turn of the session. **Subagents stay timerless:** a dispatched agent arms nothing — it holds its turn and polls its own output, and the one Patrol lives in the session that dispatched it. The manual `/loop` poke ritual is retired with the old poker duty it carried: its work is the patrol prompt's now, and a second timer is a second answer to "what should I be doing right now." **The walls no longer die with the conversation** (bionic 1.4.0), **and they no longer bind a session that never asked for them** (bionic 1.4.1). Every hook is registered once in `hooks/hooks.json`, so a session continue, a `/clear`+resume and a `/reload-plugins` all leave them exactly where they were — the failure this ritual used to exist to repair. What scopes them is two on-disk facts, not one, and they answer different questions: whether this SESSION is engaged, and which run this SESSION is bound to. Engagement decides WHETHER a hook acts at all; the bound run decides WHAT it enforces. `hooks/engage.sh` writes engagement mechanically, the instant this session invokes `canonical-sdlc` — a Skill tool call or a typed `/bionic:canonical-sdlc` — as `.bionic/tmp/engaged-<session-id>.state`; no other skill call writes it, and a session that has never invoked this one is invisible to every bionic hook, the four always-on guards included. Every bionic hook checks engagement FIRST, before the run check that used to be its only gate: a hook that finds no marker does nothing at all, silently, on any input. **Which run is a property of the SESSION, not of the project** (bionic 1.4.2): the open run is the plan this session is BOUND to, recorded as the `plan=` line of its own engagement marker, and a session bound to a plan keeps it until it binds another — a run that closes leaves the session with no open run rather than handing it the neighbour's. Engagement binds the sole open run when the root has exactly one and writes `plan=none` otherwise; a Write that creates a new plan binds that plan; `session-poker.sh bind <plan>` names one by hand, and its operand may be absolute, project-root-relative, or docs-root-relative — the spelling session-start's own listing prints, so a listed line pastes straight into the verb. Only an UNBOUND session falls back to the newest plan under the docs root with a `## SDLC State` heading, `current:` below 9 or 9 without a `delivered:` Step-9 line, and no `abandoned:` frontmatter line — and every hook that takes that fallback announces it on stderr, so a session working the wrong run finds out from the wall rather than from the damage. A hook that finds the marker but no open run still enforces whatever it can enforce without one — the Patrol checkpoint, the deliverable wall, the always-on guards — and skips only the arms that measure against a step, a budget, or a roster. The marker is never removed during the session once written: `disarm` removes only the Patrol stamp, never the marker, so a session that invoked canonical-sdlc is bionic's for the whole rest of its life, run open or closed. So the resume ritual no longer re-invokes this skill to restore the walls; a `/clear`+resume re-invokes it to restore the PROMPT, which rewrites the marker under the new session id as a side effect — no second engagement trigger exists, or is needed, for that path. The 30-second proof still costs nothing and still tells you the truth: a throwaway dispatch carrying no deliverable must come back REFUSED. **The resume ritual is CronList-first:** `CronList`, delete every job whose prompt begins with the patrol marker `bionic-patrol session=` (a predecessor's clock that survived the `/clear`, not the new session's own), and only then `CronCreate` the fresh one — so a resume never runs two clocks side by side the way "one clock per run" forbids. The patrol prompt carries `bionic-patrol session=<session-id[0:8]>` as its first token for exactly this: a stray job's owning session is legible straight off `CronList` output, never guessed. **The resume ritual binds its run before it adopts anything:** if session-start listed more than one open run — or this session is otherwise unbound in a root that holds several — run `bash <plugin-root>/hooks/session-poker.sh bind <plan>` for the plan this session means, immediately after engaging and before the first dispatch. Engagement binds only a SOLE open run, and `adopt` partitions the fleet's rows on that binding, so an unbound resume in a shared root is offered the other run's agents and gated on the other run's plan. **The resume ritual rebuilds the task list after it binds:** run `TaskList`; if it is empty and the bound plan has `## SDLC State`, recreate one entry per step (and per slice at the current step) from the plan, statuses from the step lines. **The resume ritual also runs `bash <plugin-root>/hooks/session-poker.sh adopt` before its first dispatch:** what a `/clear` destroys is the completion message and the in-memory ledger, never the agents a predecessor session left running here, and `adopt` reads every open row off the other sessions' rosters with the one thing the new session cannot re-derive — the agent id, and the observe/message/stop addresses built from it. Ledger every row it prints, by agent id, into the plan's dispatch ledger; a row it reports UNADDRESSABLE is a predecessor that dispatched through a dead wall, and re-invoking the skill is what stops this session from adding another.

**The arming wall.** `arm` is not bookkeeping. Every Patrol firing stamps a session-keyed file beside the roster before the poker decides anything, and during an active run `dispatch-preflight` REFUSES a dispatch whose stamp is absent (never armed) or older than twice the poker-interval (armed, then silently stopped firing) — a dispatch with no Patrol behind it is an agent nobody is waiting on. The refusal names both halves of the fix. What the stamp attests is that firings are landing; it cannot see the CLI's cron table, so a job deleted moments ago still looks alive for up to one stale window. An absent stamp is now two facts rather than one — never armed, or armed and then deliberately disarmed — and the wall says the same thing to both, which is the right thing to say: a run that stopped its own clock and then dispatches again arms first.

**`<plugin-root>` is a placeholder, and it is resolved once — at arming.** Payload paths are written that way throughout this section because these are commands a MODEL types into its own shell, where `${CLAUDE_PLUGIN_ROOT}` is unset: the CLI substitutes that variable inside registered command files and nowhere else. The retired spelling papered over the gap with `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}`, which always resolved and could resolve to an older build than the plugin the CLI actually loads. So resolve the root ONCE per session, at Patrol arming, out of the CLI's own registry, and bake the resulting ABSOLUTE path into everything the session writes afterwards — the patrol prompt first, because a cron job carrying a placeholder fires into a `command not found` every 20 minutes and reports nothing:

```
jq -r '.plugins // {} | to_entries[] | select(.key | split("@")[0] == "bionic") | .value[0].installPath // empty' \
  "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
```

That expression is `detect_plugin_root`'s own, held byte-identical to the copy in `<plugin-root>/scripts/lib/detect.sh` by the span suite. That function is bionic's specialization of the single registry parse the payload has — `/bionic:doctor` resolves every dependency's install path through the same reading — and where the shared parse is quiet, this one refuses loudly: *plugin not installed — run `claude plugin install bionic@bionic`*, rather than falling back to anything. Empty output above means exactly that, and no other root is substituted for it. **Why the registry can be trusted differs by how bionic was installed,** and that is what a root which looks stale turns on: on a git-source (public) feed the cache directory the registry names is what the CLI loads, so the registry is right by construction; on a directory-source marketplace — a local checkout registered as a feed, which is what a dogfood install is — the CLI reads the marketplace SOURCE tree and never opens that cache, so the two are the same build only as of the last (re)install, and on a git-source feed `claude plugin update bionic@bionic` is what re-converges them; on a directory-source marketplace there is nothing to re-converge with that command — it reports "already at the latest version" at an unchanged plugin.json version and leaves the untouched cache exactly where it was, since the CLI never reads it — so the tree and the cache catch up only at the next version bump or reinstall (an already-installed plugin reports "already installed" on `install`).

**Wakeups are recurring, never date-pinned.** A one-shot `CronCreate` pinned to a wall-clock minute is banned: a busy minute DROPS the tick rather than queuing it, so a one-shot whose single match minute finds the session working dies silently and never fires again (re-measured epic-17 W4 S6, alongside the 1m floor and the 7-day expiry). When a run needs a wake, create a SHORT RECURRING job and `CronDelete` it on its first fire — a recurring job that loses a busy tick simply fires on the next one, which is the whole difference between a wake that survives contention and one that does not.

**The patrol prompt.** The armed job carries ONE prompt, its first token `bionic-patrol session=<session-id[0:8]>` so a stray job's prompt names its own session, idempotent by construction so that firing at an awkward moment costs a no-op rather than a duplicate action, and it ends by continuing the run rather than by reporting on it. Four reads, then the work:

- **Tick the poker.** `bash <plugin-root>/hooks/session-poker.sh tick` is the decision brain — the prompt gathers, the poker decides, per row. The tick stamps the Patrol alive before it decides, so a tick that finds nothing to say has still done that job. A QUIET decision is a no-op. A DISARM decision ends the Patrol, and the tick removes this session's stamp as its own last act — so `CronDelete` the job to match, and the Patrol is stopped on both sides rather than half-stopped in the direction that lies. DISARM fires only when the run has reached `current: 9` with a `delivered:` Step-9 line — an empty roster mid-run is QUIET, stamp kept, never DISARM. A NOTIFY decision surfaces the named row through the non-response procedure below — the poker only decides, it never stops or messages on its own. **An armed session that has dispatched nothing yet decides QUIET, never REFUSED** — `poker: QUIET — armed, nothing dispatched yet on this session`, stamp kept — because arming precedes dispatch by design; the refusal is reserved for a tick that never armed here or resolved the wrong project root, and it prints the ancestor walk it took so you can see which one.
- **Read the tick's fourth decision: FILL.** Before it considers a single fill the tick reads `resources_pressure`, and **the tick reads pressure to throttle, never to re-derive the budget** — the ceiling is the plan header's `parallel-budget:`, written once by Step 0 from the probe, and no live reading ever raises or lowers it. Two throttle HOLDS, in order, and neither of them is the rung: **EMERGENCY** (free memory under the kill floor) prints the reading and names the youngest suite-running writer for you to stop through the stopping standard, and fills nothing — the tick never stops anything itself; **HOLD** (free memory or load past the warning line) prints its measurement and fills nothing. Both are advisories that WITHHOLD a fill; neither resizes one. The rung is the separate thing they are often confused with: `pressure_level`'s integer, printed on every tick as `poker: rung=<n>/<ceiling>`, and it is the number a fill is sized by. NARROW and RELAX are retired — regulation is the rung's, read by every consumer at the moment of use, never a tick's advice. The approval gate comes before any of that: a plan whose `current:` is below 4 has not passed its Step-3 approval, so the tick prints `poker: no FILL — plan at current: N, Step-3 approval pending` and names no slice — a wave is never filled before the user has approved its shape (bionic 1.4.4, after a tick filled eight slices of an unapproved wave). Otherwise the tick prints `FILL <ids>`: the slice table's `pending` rows whose every dependency is `landed`, up to the RUNG minus the rows this session's roster still has open — a count the tick trims against the live agent set, and says so on the line above whenever the trim moved it. **A printed FILL is a duty, not a suggestion** — `hooks/patrol-duties-gate.sh` refuses the end of that turn, once, until every named slice is dispatched or a line `fill-declined: <reason>` says why not.
- **Read liveness against the contracted cadence,** never against the tick interval: a row is quiet when it is quieter than the `cadence` its own brief declared (Liveness fields, above), so a tick that finds every progress file inside its declared cadence has found nothing and says nothing.
- **Keep the panel, the task list and the fill honest.** All three duties are TOOL-GROUNDED, never judgment-worded, and they are WALLED: `hooks/patrol-duties-gate.sh` refuses the end of a tick's turn — once — until the transcript shows them since the tick fired, naming whichever is missing.
  - *Panel refresh* = ListAgents, then TaskStop on each listed lineage whose ledger row is fact-discharged (CLOSED / MET / acked). A listed agent with NO ledger row is surfaced as a duplicate-session tell, never silently stopped.
  - *Task-list refresh* = TaskList, then chronological display order (current-step slice entries first, dependency order, later-step entries after) restored mechanically — TaskCreate fresh copies of every entry that must sort later, TaskUpdate status=deleted on the stale originals, no-op when ascending-ID order already matches — then statuses reconciled with verified reality.
  - *Fill answer* = every slice a `poker: FILL` line named, dispatched — or one line `fill-declined: <reason>`. The gate names the slice that was left out, not the count.
  - *Fallback:* where the task tools are absent (version-gated), the plan ledger stands in as the task list.
- **Then continue toward the goal until a wall.** The tick is not a status report. After the reads, resume the run's actual work and keep going until something genuinely blocks — a decision only the user can take, a gate whose evidence is not yet earned, a dependency not yet merged. An interactive stretch is already standing at the blocked-on-user wall, so the tick no-ops quietly there rather than manufacturing activity.

**Phase-gated dispatch.** A brief for slice work splits into a deliverable phase and bookkeeping, with a hard report gate between them: the writer stops at the gate and sends the completion message before touching bookkeeping. A redirect sent mid-phase is read at the gate — not before, and not after the whole task — bounding the steering race instead of pretending mail delivery is instant. Expected-duration estimates quote the deliverable phase only; bookkeeping is not the writer's clock to keep.

**Completion-by-artifact.** A writer's final act is a `SendMessage` naming the artifact path(s) it produced — the report is DELIVERED by that tool, and plain final text is discarded: a subagent's closing prose is written into its own transcript and routed to no one, so a brief that contracts for the report as a final message is contracting for a report that never arrives. Idle is no more a completion signal than that — a quiet agent might be thinking, might be dead, might be between phases; only the sent message closes the phase. Done is established by the artifact existing on disk, which the landing verdict already checks — no new machinery re-derives it.

**When a report is lost anyway.** The artifacts, the ledger row, and the contracted progress file are the safety net and remain the primary proof — the message is the latency channel, not the evidence, so losing it delays a run rather than voiding it. Recovery is mechanical: a dispatched agent's turns are on disk at `~/.claude/projects/<slugged-cwd>/<session-id>/subagents/agent-*.jsonl`, one JSON object per line, and the report is the last long `assistant` text block in that agent's file. Extract it and persist it under `<docs-root>/record/` before acting on it — a transcript is not an artifact, and a read-only dispatch whose findings live only in a transcript is one cleanup away from having produced nothing.

**Redirect stray doc writes, and never commit them.** If a superpowers skill wants to write specs/plans under `docs/superpowers/`, redirect to `.bionic/docs/` (canonical-sdlc layout) — do not recreate the root docs tree, and never git-commit plan/spec artifacts.

**Fresh by default; fork only** when hand-feeding context would cost more than the fork's inheritance — a fork re-pays the whole main-thread context AND the orchestrator's effort, and ignores `model`. Never fork a mechanical task, and never fork to reach a cheaper model. **Dispatch is always background when `multi_agent: true`** — attended or not. A synchronous dispatch freezes the session, and a user who cannot type cannot steer. Serialize dependent units by dispatching the next one on the previous one's completion notification, never by blocking. Synchronous main-thread execution exists only under `multi_agent: false`, where there are no subagents at all.

**Parallel by default, justify sequential** — but dispatch serially when units share state (one local DB, a shared reset, count-based assertions).

**Fill the budget.** The plan's `parallel-budget:` is a ceiling, and a ceiling nobody reaches is a wave running one writer at a time by accident: every slice with no unmet dependency dispatches in one batch sized by the rung the tick prints — `poker: rung=<n>/<ceiling>`, the machine's answer to how wide it will carry right now — with `writers` as the ceiling that rung is taken against and the only number the wall enforces; sequence only for shared state or when the batch would exceed the budget. `hooks/dispatch-preflight.sh` refuses the dispatch that would cross the CEILING — naming the budget and the count — and never on the rung, so a batch sized by reading the plan and the tick is sized correctly rather than by testing the wall. Each brief in the batch points the writer at the rung: `take your test width from pressure_level at suite start; the ceiling is this header's test_jobs`.

**Parallel writers work in spawned worktrees.** Whoever dispatches a parallel writer creates that writer's tree first: creation authority follows dispatch authority at every level, orchestrator included — during a parallel-writer phase an orchestrator that writes tracked files takes a tree of its own, and `.bionic` plan and ledger writes remain a file-ownership question rather than an exemption from this one. The tree comes from `${CLAUDE_PLUGIN_ROOT}/scripts/spawn-worktree.sh`, which verifies what it built and attests it in a single line; that path is written the way the CLI substitutes it inside a registered command file, so a model running the script from its own shell — where `${CLAUDE_PLUGIN_ROOT}` is unset — uses the root already resolved at Patrol arming (above); the dispatcher quotes that line into the unit's ledger row, so what the row claims about a base commit is something the machine measured rather than something the brief asked for. Teardown is never automatic — the merge decision is the dispatcher's, taken later. The harness `isolation: worktree` param is retired from bionic briefs at every level: it creates trees no ledger row can account for.

**The starting standard.** A subagent may be dispatched only when: the environment attestation from this session is present; a work contract exists at launch, naming the task and a durable deliverable path; and the launch is ledgered the moment it happens.

**Ledger the dispatch, not the return.** Write the unit's row the moment you dispatch it, status `active`. An outstanding agent has to exist as a row you can be blocked on, not as something you intend to remember — a dispatch held only in working memory is lost the moment the conversation turns, which is the normal case, not the exception. The row is also what lets you answer "what's still running" without guessing. On the completion notification, verify that the named artifact exists before believing the report, then update the row. The roster the dispatch hook writes at launch and completes at execution-confirmation is the authoritative launch record; the plan's dispatch ledger renders it, not the reverse.

**The reporting contract.** Every factual claim in a subagent's report — a test result, a file's existence, a command's outcome — carries the command that proves it and that command's output, or the explicit label `unverified`. An `unverified` claim obligates the orchestrator to re-check before acting; a claim with neither proof nor label is a contract violation. The contract governs what a report says; Completion-by-artifact, below, governs how it arrives.

**Agent outputs that claim "the docs explicitly state X"** (or any other verbatim-quote-from-authoritative-source assertion) must be verified against the primary source before acting on them, especially when stakes are material (file changes, infrastructure modifications, hook/config swaps). During the 2026-04-11 Stop-hook-label investigation the `claude-code-guide` agent fabricated a verbatim docs quote that did not exist in the actual docs page; catching it required a direct WebFetch. Treat agent "quotes" as leads, not facts.

**Facts discharge stops.** A row whose verdict reads MET, WAIVED, or acked is stopped by a single TaskStop with no observation call first. A user-ordered stop executes at once regardless of verdict; an unmet contract yields one informational line naming what was missing, never a refusal. The ceremony below survives only for a live agent with an unmet contract.

Two operator commands carry the fact-discharged paths: `bash <plugin-root>/hooks/stop-orders.sh standdown` computes the batch of landed/acked rows with stoppable addresses (and names what it will not touch) before closing a batch or wave; `bash <plugin-root>/hooks/stop-orders.sh order <target>` records a human stop order the gate honors immediately (30-minute validity; expiry fails closed). Addressing rule: **observe by the long transcript id, stop by the bare `name`** — different namespaces, and the machinery prints both. The suffixed form `name@session-xxxxxxxx` names the session that LAUNCHED the agent and never the one that adopted it: a `/clear` re-keys your own session id but does not move the harness's teammate table (live drive, 2026-09-03), so a suffix built from the surviving session addresses nothing. The bare name is the address that always survives.

**The stopping standard.** For a live agent with an unmet contract, a subagent may be stopped only when a fresh observation of that target has been recorded first. Freshness is the activity boundary, not a clock (D-1): a stop is permitted only if the target's last working-log activity is no later than what the observation recorded — anything written since is stale by definition, dormancy since the observation is valid however old. One observation discharges exactly one stop (D-2); a second stop needs a fresh observation. Where the brief contracted a progress artifact, the observation of that target names that path — the D-6 channel is evidence the contract already promised, and an observation that omits it is the agent-level look that was insufficient before. The observation that discharges a stop is the stopper's own — a look recorded by a different actor does not close it. What this session did not launch, it does not stop by name; the full agent id is the deliberate path past that refusal. Never on an idle notification, never on elapsed silence alone.

**The non-response procedure.** For a quiet agent, examine its evidence first — for BOTH agent classes, before any other action; an undelivered review is as losable as an uncommitted commit. Then one class-appropriate round: read-only agents may be messaged once and relaunched fresh; writing agents are never resumed — examine their output directly, take over the work, and stand the agent down. Bounded to two rounds, ending in exactly one of: work delivered, work taken over, or agent stopped-and-reported. Every stop is reported to the user, never absorbed silently. **Overdue is a trigger, never evidence:** a task exceeding its declared expected duration routes into this procedure mechanically; it never justifies a stop by itself — the eventual stop still requires its own fresh observation.

**Why writers are never pinged.** A message to an idle WRITE agent resumes a fresh instance from its transcript, and two instances of the same writer will collide on the shared tree (observed: interleaved edits + checkout-reverts) — which is why the procedure above verifies the tree directly (`git status` / `git show --stat`) instead of messaging. Check for a duplicate USER session first.

Rationale, failure model, and use cases for the starting standard, the stopping standard, and the non-response procedure: `design/orchestrator-subagent-coordination.md`.

Before ending a turn, reconcile: every `active` row either has a verified result or is named to the user as still running.

## Escalation

**Diagnostic friction** (direction clear, code misbehaves) → load `map-instrument-narrow` in a fresh subagent carrying its Rigor Mandate verbatim, and write no fix code until NARROW names a root cause with data. "I'll try one thing first" mutates the state you were about to instrument. Recurse on layered causes, depth ≤4.

**Decision friction** (the direction itself is in question) → stop and surface it. The framing rules live in the global config, not here.

**Three-fail rule.** Three failures to produce valid evidence for one step: if diagnostic, run a full MAP-INSTRUMENT-NARROW pass (the counter resets on a completed pass, not on more speculative fixes); if decision-related, stop and surface. A `standard` slice that fails twice re-dispatches once as `senior-implementor` — that is the third try, not a fourth.

**Stop and wake** for: an ambiguous spec needing a judgment call, new external-API auth, anything affecting billing, destructive migrations, secrets or production infrastructure, and anything the user's own config marks as requiring approval. Append a `## Wake Note` and do not proceed past it.
<!-- ORCHESTRATOR-DISPATCH-END -->

## Diagrams

`diagrams/lifecycle.svg` — the 10 steps, the two gates, and the commit rhythm. `diagrams/hook-chain.svg` — which hook fires on which tool event, and which arms block versus log. Each file is its own sole source: hand-composed text, no paired drawing file, no export step, and so nothing that can be stale relative to it. Because the text is greppable, `tests/cross-gate-agreement.test.sh` §V pins the four version renderings across both SVGs against the hooks' `SUPPORTED_SDLC_VERSION`, with a mutation arm that re-proves the pin against a doctored copy on each run. The six always-on entries against `hooks/hooks.json` and the ten steps and the armed hook set against this file are not pinned by anything yet — `tests/diagrams.test.sh`, the suite this paragraph used to cite for all of it, does not exist.

**Format policy.** Composed SVG is the default for a diagram here, because it is the only format that is simultaneously the editable source, the shipped artifact, and a test surface. Excalidraw (`bionic:excalidraw-diagram`) is the backup, for a drawing whose layout is genuinely hand-arranged rather than composed; it ships an export beside its source and re-accepts the is-that-current relationship, so reach for it when the picture is worth that cost. Any other format is a judgment call, argued at the time against one question: what will pin this picture to the truth after its author has moved on.
