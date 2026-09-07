---
name: canonical-sdlc-operational-rules
description: Canonical-sdlc operational rules — artifact shape, evidence gating, intent-specific behaviors, version history. Bulk procedural reference; copied beside SKILL.md, read on demand — nothing loads it.
updated: 2026-08-02
---

# canonical-sdlc operational rules

The high-priority operational rules for the canonical-sdlc skill — artifact shape, evidence gating, intent-specific behaviors.

Read this when you are running canonical-sdlc and need the detail SKILL.md compresses — its
`## Canonical SDLC` intro points here by name. It is reference, not a standing instruction:
nothing loads it unprompted, and being copied beside the skill is not the same as being loaded.

## Engagement and the axis triple

- **v14 is the ONLY supported version (2026-08-19, epic-17 wave-05 — the close-out contract).** All backward compatibility is deleted again: v13 plans now block, no grandfathering, no version ladder. Both hooks check `SUPPORTED_SDLC_VERSION=14`. **One contract change over v13, and it is Step 9's evidence shape.** `delivered:` is now required on every close-out — the terminal state of the work, which the lifecycle defines as a PR open and ready for a human to review, or commits landed locally and ready to push. `deployed:`, `verified:` and `monitored:` replace v13's `deploy:`/`verified-at:`/`monitor:` and are owed **exactly when `deploy_target` names a live surface**, which pairs with the second half of the change: `deploy_target` defaults to `n/a` at Step 0 and is **never inferred** — a live surface exists only where the user names one, and deploy-shaped signals in a repo are not that naming. What died: v13 owed the trio whenever any target existed and let `n/a:` discharge the step at `deploy_target: none`. That rule encoded wave==release — the exception, not the rule — and it let a run with no live surface close without ever naming what it delivered, while putting every ordinary run on the hook for a release it never performed. An unowed trio recorded anyway is tolerated, never refused: the wall is on the absent claim, not the extra one. Everything else in the contract is IDENTICAL to v13's below — same triple, flags, `model_plan`, Verification Matrix, design wall, `scale: task|wave|epic`; no new frontmatter fields. Same wave, same gate, one adjacent fix that is NOT a contract change: the post-Verify revalidation now accepts a well-formed `user-confirmed: <user> <date> <what>` on a **T4** row in place of an auditor's CONFIRMED, since the user's own confirmation is that tier's evidence and routing it through the Waiver Protocol recorded a waiver where none was owed. **Every version bullet below v14 in this file is historical record only — none of it is live behavior, and the `mode:` vocabulary of v≤10 is dead.**

- **v13 (2026-08-02, epic-14 wave-02 — design-before-build; superseded by v14 on 2026-08-19 — see above).** All backward compatibility was deleted again: v12 plans blocked, no grandfathering, no version ladder. Both hooks checked `SUPPORTED_SDLC_VERSION=13`. Four contract changes over v12, all landed this wave: (a) **Design back-half of Step 2** — SKILL.md now carries the full `## Design` contract (the ownership table, scaling by task/wave/epic, rejected alternatives, assumptions feeding the plan's `## Assumptions`) and the operational-rules companion below (`## Design section authoring`). (b) **Three-way design wall** — a `*.spec.md` write at `scale: wave` or `scale: epic` now blocks unless it satisfies one of three arms: a flush-left `## Design` section in place, a `design: <path>` pointer resolving to a real file that itself carries one, or a `design-waived: <user> <date> <reason>` token; the governing-skill hook enforces this at write time (SKILL.md §Artifact layout, §Step 5 → Waiver Protocol, §Hooks). (c) **6-axis Step-6 review** — the adversarial self-review grew a sixth axis, duplication (one implementation site per concept, anchored on the design's ownership table), alongside correctness/readability/architecture/security/performance; the critic mandate (`agents/critic.md`) carries the duplication axis and the agreement-test obligation verbatim. (d) **Auditor coverage-chain extension** — the Step-5 Verification Auditor mandate (`agents/auditor.md`) now walks the full chain top-down (requirement → design decision → criterion → evidence) as its first pass, before power and authenticity, seeded mechanically from the `provenance:` citation map and the design section's requirement references; an uncovered requirement is a wave-level finding the per-row verdict scheme can't otherwise express. v13's remaining contract is IDENTICAL to v12's — same triple, flags, `model_plan`, Verification Matrix, evidence shapes, `scale: task|wave|epic`; no new required frontmatter fields. (wave-03, 2026-08-02, this epic: layers one OPTIONAL key on top of that same v13 contract — `design-interview: true | false`, default `true`, recorded beside `walk:` — so a v13 plan predating this wave and one written after it both validate, and only the later one carries the key.)

- **v12 is the ONLY supported version (2026-07-26, epic-11; superseded by v13 on 2026-08-02 — see above).** All backward compatibility was deleted: no grandfathering, no version ladder, no per-version shape tables. Both hooks checked `SUPPORTED_SDLC_VERSION=12` and blocked loudly on anything else (previously the evidence gate fell through to a bare `exit 0` on an unrecognized version, so such a plan committed entirely ungated). v12's contract was IDENTICAL to v11's below — same triple, flags, `model_plan`, Verification Matrix, evidence shapes, `scale: task|wave|epic`; no new fields. It is v11 renumbered to mark the pruned-harness generation. The `continuous` scale from the different v12 on the deleted `wave-keepalive` branch is abandoned.

  - **W1 verification power (2026-08-01, epic-14 wave-01) — tightened v12 IN PLACE, NO version bump; the bump belongs to W2.** Four contract changes, all inside `canonical_sdlc_version: 12`. (a) **Walk-first Step 5:** plan frontmatter gains `walk: required | exempt`, derived at Step 0 from the declared surface flags and printed in the confirmation display; at `current: 5..9`, once any matrix row is `discharged`, the evidence gate demands a `walk-artifact:` line in the Step-5 evidence naming a real file under `<docs-root>/record/` that contains no `AC-<n>` identifier. **Fail-closed:** only the literal `exempt` disarms it — an absent key or an off-enum value ARMS it, because an exemption is a Step-0 ratification and never an inference from an omission. The governing-skill hook blocks an off-enum `walk:` value at artifact-write time. Existence is enforceable; "first" is discipline no commit-time hook can see. (b) **Provenance per criterion:** every AC carries `provenance: user <date> "<quote>" | spec §N | ticket-N | report §N`, authored with the criterion; the literal whole value `provenance: implementation` blocks at the evidence gate, a citation merely containing the word passes, and a MISSING `provenance:` line does not block (presence is a W+1 candidate). (c) **Absence-readback rule:** a zero/empty/not-present readback needs a paired positive case or the row is presumed powerless and cannot discharge — judgment-enforced through the auditor mandate, deliberately NOT a hook arm. (d) **Rigor floors advise, never force** — see the supersession note below. Files: SKILL.md (Step 0, new Step-2 section, Step 5, evidence shapes, `## Hooks`), both hooks, `agents/auditor.md`, `agents/test-runner.md`, both hook test suites.

    **Supersedes** the v11 bullet's "downgrades are user decisions via the Waiver Protocol" *as it applied to RUN rigor at Step 0*: a `set rigor=<below floor>` override is now **accepted, never refused** — the skill names the binding floor, the evidence class it was buying, and what is given up, then proceeds with the user's value and records `rigor-override: <user> <date> derived=<v> chosen=<v>` in frontmatter. The log-only floor checks detect the marker by PRESENCE (fields unvalidated, matching the `waiver:` token precedent) and log `user-overridden` in place of the violation; without the marker the violation log is byte-identical to before. No carve-outs — the security/privacy flag floor gets the strongest advisory language and still accepts the override. Two scope limits worth holding: the marker does NOT suppress the project-floor's "invalid `rigor-floor` value in config.yaml" finding (a data-quality problem in the floor itself, not a user choosing below a valid one), and it does NOT touch A15's per-row task-ledger rigor cell below, which still BLOCKS a lowering cell absent a `waiver:` marker — that is a different axis (row rigor, hook-enforced) from the run's Step-0 rigor, and it was left armed deliberately.

- **v11 (2026-07-19, epic-07-intent-rigor-scale wave 3; renumbered to v12 on 2026-07-26 — contract unchanged) — three orthogonal axes replace `mode`.** Every run declares exactly one triple at Step 0: intent (`build|bugfix|refactor|tune|spike|incident-response`) × rigor (`tested|peer-reviewed|audited`, cumulative) × scale (`epic|wave|task`). v11 artifacts declare `intent:`/`rigor:`/`scale:` — never `mode:` (blocked as split-brain). **D13 (universal structural contract):** flags + `model_plan` + a `## Verification Matrix` at `sdlc-step ≥ 3` are required on EVERY v11 artifact, regardless of intent — the triple's presence is the gate, no `mode:` short-circuit. **Effective rigor = MAX across four floor sources, upward-only (never down):** intent floor (`incident-response` floors `audited`; `spike` caps at `tested` since it ships no code), flag floor (security-touching or privacy/vulnerable-population-touching work floors `audited` — evaluate what the work touches and induces, not what it renders), project floor (`rigor-floor:` in `.bionic/config.yaml`), epic floor (`rigor-floor:` in epic frontmatter — a floor, never a fixed `rigor:`). Rigor is provisional at Step 0, locked at Step 3; mid-wave upgrades are free, downgrades are user decisions via the Waiver Protocol *(superseded for Step-0 run rigor by the W1 entry above — advise-then-accept with a recorded `rigor-override:`, never a refusal)*. **D11 (scale-keyed defaults):** `audited` is the default at wave scale and above; `scale: task` keeps the lighter lanes — `tested` for bugfix, `peer-reviewed` for build/refactor/tune (spike stays capped `tested`, incident-response stays floored `audited` at every scale). **D12 (task-scale addressing):** `scale: task` plans use `current: T<n>` against a `## Tasks` ledger, one `- T<n>: <evidence>` line per task — no per-task plan/spec files; the evidence-gate accepts `current: T<n>` structurally (a false block here is a defect), and ledger-shape validation (missing `## Tasks`, bad status enum, active/done task lacking evidence) is log-only. **Orchestrator-owned ledgering (epic-07 wave-4, D7, user-ratified):** when a task-shaped unit is executed by a dispatched subagent, the subagent only reports — the ORCHESTRATOR writes the governing plan's ledger record (row + evidence line) from the verified report before marking the unit complete; a missing ledger row is the orchestrator's defect (SKILL.md §Task Tracking + Dispatch Convention pt 10). **Barred cells (D4, superseded 2026-08-22, epic-18 wave-01 T9 — the check is removed, not merely relaxed):** `bugfix`/`spike`/`incident-response` × `epic` used to block outright. The governing-skill hook no longer refuses any intent × scale cell — the triple is the user's whole call, and a genuine `epic`-scale bugfix/spike/incident-response is for the user to declare, not for a derivable rule to reject on their behalf. **D14 (log-only audit channel):** `$HOME/.claude/logs/<project-slug>/sdlc-audit.md`, written by all four audit-writing hooks (the filename carries no version stamp) — floor-consistency (governing-skill), task-ledger + epic merge-target (evidence-gate), and (wave 3, R7 below) the per-intent evidence checks all append one line + echo stderr + exit 0, never block; promotion of any check to blocking is a user decision made from the accumulated audit data, never automatic.

  **R7 — per-intent Step-5 evidence keys (wave 3, log-only; epic-02 adr-001 boundary analysis: these are intent-scoped conditional keys, not the universal-key family — the "fifth universal key forces consolidation" threshold is untouched):**

  | Intent | Step-5 keys | Contract |
  |---|---|---|
  | `refactor` | `behavior-preservation:` | required — suite green both sides (baseline + post runs, counts + command) |
  | `refactor` | `compat-matrix:` / `revert-plan:` | migrations/upgrades only; `n/a: not a migration` escape; hook checks present-but-empty only |
  | `tune` | `baseline:` / `target:` / `re-measure:` | all three required — metric + number + instrument |

  with check-ids `refactor-evidence` / `tune-evidence` (log-only, fire at the Verify gate on v11 wave/epic-scale plans of those intents; task-scale ledger lines carry no Step-5 block, so the checks don't fire there; missing/empty/placeholder values all log — the R7 key lines are exempt from the universal placeholder block on v11 plans only).

  **D-slice 4 — rigor-keyed task-ledger enforcement, now BLOCKING (wave-05, 2026-07-19; tightened v11 IN PLACE — no v12).** D12's task-ledger validation (log-only above) was rigor-keyed and promoted to blocking. Evidence GATHERING stays rigor-invariant; the row's EFFECTIVE RIGOR (its own `rigor` cell, resolved per A15 below — empty cell inherits frontmatter; an off-enum cell is a blocking malformation on ANY row, at ANY status, regardless of frontmatter rigor) selects which fields must exist, in three cumulative lanes:
  - **tested (floor, all rigors):** the addressed unit (`current: T<n>`) must have a row in `## Tasks` and a non-placeholder `- T<n>:` evidence line. Nothing else — the cheap lane stays one honest line.
  - **peer-reviewed:** the evidence line must be PROOF-SHAPED — ≥1 digit AND a command token (a backtick, a `/`-bearing path, or a whole-word runner from `bash|sh|npm|pnpm|yarn|make|pytest|go|cargo|git|test`) — plus, on `done` rows, an `auditor` token.
  - **audited:** `done` rows additionally carry a `critic` token.

  These lanes apply to the addressed unit always, and to any OTHER `done` row that already carries real (non-empty, non-placeholder) evidence — a false-done claim at peer-reviewed+ blocks even off the addressed row.

  **A15 — row rigor is a FLOOR, not a free two-way override (Step-6 USER DECISION, momentous, ratified 2026-07-19; refines D-slice 4 above, which originally shipped as "cell overrides frontmatter both directions").** A per-row `rigor` cell may RAISE a row's effective rigor above frontmatter `rigor:` freely (drives the heavier lane). A cell that LOWERS it below frontmatter is a DOWNGRADE and BLOCKS (exit 2) unless the row's `- T<n>:` evidence line carries a Waiver-Protocol marker (`waiver: <user> <date> <reason>`, whole-word match), in which case it proceeds at the lower cell's lane. This unifies row-rigor with the v11 run-rigor floor model above (upward-only; downgrade = a recorded user decision) and closes the Step-6 adversarial critic's **F1 finding** (a per-row cell could silently disarm the proof-shape/auditor/critic lanes with no audit trail). An empty cell resolves to frontmatter first, so it is never a phantom downgrade; an EQUAL cell is not a downgrade either (strict `<`). Implemented by `rigor_ord()` + `enforce_rigor_floor()`, riding the same rails as the three lanes above (addressed unit at any status; non-addressed `done` rows with real evidence) — fires immediately before the lanes. Folded same-slice: word-boundary matching for the `auditor`/`critic` tokens (F3 — `critical` no longer satisfies `critic`). Shipped docs (SKILL.md/README.md) updated to "cells raise; lowering = waiver" — the "overrides ... both directions" phrasing is retired.

  **Plan-level audited strictness:** at frontmatter `rigor: audited`, the previously-log-only ledger-shape checks on NON-addressed rows (missing `## Tasks`, bad status enum, an active/done row with missing/placeholder evidence) become BLOCKING too. Below `audited` they stay log-only, unchanged.

  **D7 seed-at-dispatch (bit 2026-07-22, epic-10 wave-01 T7 — cost one blocked commit):** the orchestrator seeds the `- T<n>:` evidence line INSIDE `## SDLC State` at the moment a row goes `active` (a "dispatched — awaiting report" line satisfies presence), never deferring to report time — a dispatched subagent's commit hits the evidence-gate's D7 presence check and the subagent is scope-fenced out of fixing it.

  **D7 ledger placement (bit 2026-07-20, epic-08 wave-03 — cost one blocked commit):** the `## Tasks` table holds the ROWS, but every `- T<n>:` evidence line must live INSIDE `## SDLC State` — the evidence-gate's ledger check greps section-scoped and never sees evidence lines placed under `## Tasks`. Also: matrix `auditor` cells must be exactly `CONFIRMED` (exact match — annotations like "CONFIRMED (re-executed)" block); T0 rows require both `tier-run:` AND `readback:` keys.

  **D7 dispatched-task ledger presence (wave/epic scale):** an audited plan with `multi_agent: true` at `scale: wave` must carry a `## Tasks` section — absence blocks; empty is fine (zero dispatched rows satisfies presence; a human `none dispatched` line is documentation, not parser-required). Present rows validate at tested-floor SHAPE ONLY (status enum + evidence-line presence + placeholder ban) — NOT the proof-shape/auditor/critic lanes, because the wave's own Step-5 auditor and Step-6 critic are the assurance roles at wave scale. `scale: epic` is intentionally excluded — an epic dispatches research, not task-shaped units.

  **What stays log-only (NOT promoted):** floor-consistency (governing-skill), the epic merge-target check, and the R7 refactor/tune per-intent evidence keys (above) — only the ledger-shape + rigor-lane checks became blocking.

  **Version ruling: tightened v11 IN PLACE, no `v12`, no allowlist growth.** v11 was unreleased with zero v11 plans in existence at the time of this tightening — nothing in-flight to grandfather, so the "never retrofit a newer version onto an older plan" rule (which exists to protect in-flight plans from a version bump they didn't sign up for) does not apply here: there was no prior real-world v11 behavior for any plan to be retrofitted away from. Promoting D12's task-ledger checks to blocking within the same `canonical_sdlc_version: 11` is therefore a same-version tightening, not a version bump. The shipped docs (SKILL.md/README.md) describe only the resulting v11 contract as current — this rationale (unreleased, zero adopting plans) stays here in memory, not in shipped content.

  Wave-1 lessons still operational: (a) empirical-gate overrides only via explicit user re-ratification, recorded + counted (AC-W3 waived at 91.5% vs 95% after 3 study runs — the waiver-fatigue watch counts it); (b) decision records (ADR ledger cells) drift independently of corrected prose — after any correction, sweep ALL artifacts cross-referencing the corrected value (stance-2 critic caught adr-002 reintroducing the critic-placement error the R8 correction had just killed); (c) `tune` fired zero times on this repo's corpus as of wave 3 — unvalidated until consumer pilots. Design record: `.bionic/docs/ideas/canonical-sdlc-mode-redesign.md`.

- **Epic integration-branch convention (user-ratified, 2026-07-18): a true epic owns branch `epic/NN-<slug>`** — waves merge into the epic branch; the epic branch merges to main once at epic close (user push gate). Prior epics 01–06 were single waves merging straight to main; epic-07 is the first user of the convention. Wave plans under an epic set `integration-branch: epic/NN-<slug>`, not `main`.

- **Large-scale work (new feature, architectural change, multi-day project) → invoke `canonical-sdlc` at session start.** Enforces the canonical step set (10 steps, 0–9), TDD non-negotiable on code-producing steps, evidence required per step. The run is declared with the `intent · rigor · scale` triple — the old mode names (`autonomous`, `epic-scope`, `design-refresh`) are retired vocabulary.

- **v10 (2026-07-16, epic-05; superseded by v11, then deleted outright at v12 — the v10.1 relaxation below survives as part of the v12 contract, but a `canonical_sdlc_version: 10` plan now blocks) — pre-registered Verification Matrix replaces the flat Step-5 key stack.** New plans declare `canonical_sdlc_version: 10`. One `## Verification Matrix` row per AC (schema `| AC | tier | status | evidence | auditor |`), tiers from browser-verify's T0–T4 ladder, derived at Step 0, locked at Step 3 (governing-skill hook requires the section at `sdlc-step ≥ 3`). Per-tier keys: T0/T1 `tier-run`+`readback`; T2 +`fixture-fidelity`; T3 `tier-run`/`fresh`/`cold-client`/`contact`/`readback`; T4 `user-confirmed`. Tier-Discharge Rule kills suite-credit (T1 never discharges T3). Step-5 exit = Independent Verification Auditor (fresh opus+ agent, verbatim mandate, re-executes ≥1 cmd/tier cap 3, CONFIRMED/REFUTED/UNVERIFIABLE per row); matrix re-validated as prefix check at `current: 6..9`. Waiver Protocol: tier downgrade, live-tier `n/a`, closing over non-CONFIRMED = user decisions, recorded `waiver: <user> <date> <reason>`. `stack-health:` survives as the matrix's once-per-session line. v9-and-earlier grandfathered; one sanctioned mid-life bump: reopened wave with exactly Steps 5–9 remaining may go v9→v10.
  - **v10.1 (2026-07-16, commit `53a6ba3`) — mid-discharge relaxation.** At `current: 5`, rows with status `pending`/`blocked` skip per-tier keys and the `auditor:` pointer is required only once no such row remains — corrective mid-walk commits now have an honest home; the full contract bites at the 5→6 advance. Status cell is enum-checked (`pending|blocked|discharged|waived`). NEVER regress `current:` to dodge a gate (the pre-v10.1 workaround — it misstates the step and drops the tests floor). Not a version bump: `canonical_sdlc_version` stays `10`.
  - **Watch signals for the v10 pilot/sunset review** (5-wave horizon, README §Pilot and sunset): first REFUTED auditor verdict (proves the auditor isn't rubber-stamping), waivers-per-wave (fatigue → v9-with-ceremony), matrix-authoring cost trend (~20 min first-time, expect drop).

- **v9 (2026-07-15) — universal Step-5 stack-health gate.** At `current: 5` the evidence-gate additionally requires `stack-health: <before/after snapshot, no delta>` (serving stack's runtime-integrity indicators — process/container restart counts, crash/OOM last-state — snapshotted before the walk, re-snapshotted after; any delta blocks evidence until run to ground) or `stack-health: n/a: <reason>` on EVERY v9 plan. Same contract as the siblings: universal (not has_ui-gated), presence + non-empty value/reason + placeholder ban only, snapshot command project-specific (like the freshness tool), semantics in prose. CLAIM SCOPE: catches restart/crash-shaped degradation only — never claim broader. The three keys now frame as one family, one proof per failure axis: artifact (bundle-fresh) / contact (drive-check) / runtime (stack-health). v≤8 grandfathered (named regression 16h + live v7-plan proof); allowlist grown to 9. Landed with the evidence-gate validator-table refactor (five cloned per-version branches → shared per-key validators; a v10 key = one table row) and the CRLF fix (\r\n no longer silently defeats either hook). **Binding threshold (ADR epic-02 adr-001): a FIFTH universal Step-5 key forces prose-side consolidation of the key family — do not add a fifth flat key.** Deployed + live smoke-proven 2026-07-15.

- **v8 (2026-07-12) — universal Step-5 drive-check gate.** At `current: 5` the evidence-gate hook additionally requires `drive-check: <observed delta>` (proof one trusted interaction changed app state, read back semantically via page-scope eval — never pixels), `drive-check: suite: <named test — what it asserts>` (axis-qualified suite credit: only a named test making real contact — real input on the actual surface + semantic assertion — discharges it), or `drive-check: n/a: <reason>` on EVERY v8 plan. Same contract as bundle-fresh: universal (not gated on has_ui), hook validates presence + non-empty value/reason + placeholder ban only, semantics in prose. Rationale: the proxy model — every tier below the live walk tests a proxy (input/data/readback) and each proxy passes silently at its blind spot; drive-check is the minimal enforceable contact proof. Step 5's browser modality now picks the input rung by surface (ref-based for a11y-addressable DOM; playwright-cli coordinate primitives / `run-code`+`page.mouse` for canvas/gesture — a bare canvas typically exposes nothing to the a11y tree). Claim-free stance: never assert an engine accepts synthetic input — the drive-check arbitrates per-surface. Mock-fixture coverage cannot discharge a real-data-behavior requirement (mock-green + real-red = locator). v7 and earlier grandfathered (named regression 14l + live proof); allowlist grown to 8 in the governing-skill hook. Both SKILL.mds + READMEs updated; ADR at `.bionic/docs/adrs/epic-01-v8-drive-check/adr-001-*.md`.

- **v7 (2026-07-11) — universal bundle-freshness gate.** At `current: 5` the evidence-gate hook requires `bundle-fresh: <proof>` (pasted output of the project's freshness tool — e.g. a canary round-trip proving the served artifact reflects the working tree) or `bundle-fresh: n/a: <reason>` in the Step 5 block of EVERY v7 plan. Deliberately NOT gated on `has_ui` — modality keys follow the `devtools-trace:` precedent (universal, n/a escape, "not applicable" is a recorded decision); the staleness discipline covers any live-observed serve (API dev servers included), and gating a hard requirement on the heuristically-inferred `has_ui` flag was rejected (USER DECISION, 2026-07-11). Format is project-specific; hook checks presence + non-empty value/reason + placeholder ban only. v6 and earlier are grandfathered — never retrofit the key into in-flight plans. Both hooks changed: evidence-gate gained the v7 shape switch; governing-skill added `7` to its version allowlist (an unlisted version blocks every plan write — the allowlist must grow with every version bump).

- **Canonical-sdlc modes (v3, 2026-05-10):** `autonomous` (default — absorbs prior `full`/`bugfix`/`refactor`/`overnight`; per-step checkpoint commits + adversarial critic mandatory + expanded stop-and-wake are baseline), `epic-scope`, `incident-response`, `design-refresh`, `spike`. Load-time announcement is mandatory: first user-facing action when the skill loads is `Canonical SDLC engaged — mode: <mode>.`. Legacy plans declaring `mode: overnight` still work (the skill text refers to it as a legacy equivalent of `autonomous`), but new plans should use the current mode names. v3 (2026-05-10) flattened step numbering to contiguous 0–14 (cut former Step 4 worktree, former 8b → 8, former 12.5 → 13, former 13 → 14). **v5 (2026-06-19)** adopted a gate model and collapsed to 11 steps (0–10): Steps 5+6 → **5 Verify** (gate; tests/build + browser + perf/a11y modalities), 7+8 → **6 Review** (gate; 5-axis + adversarial stances), 12+13 → **9 Integrate & close**; Step 10 Commit dissolved into a cross-cutting **commit rhythm**; Document→7, External review→8, Ship→10. v1–v4 grandfathered (v3/v4 keep the 0–14 shape table); v5 inherits v4's flag contract (5 discriminator + 2 opt-in + `model_plan`) and uses its own evidence shape switch.

## Artifact paths and frontmatter

- **Canonical-sdlc artifacts live in `.bionic/docs/{specs,plans,adrs,incidents}/epic-NN-<slug>/`** (default docs-root; the `docs/bionic/` override retired 2026-07-16 — epics 01–05 migrated in place, hook resolution probe-proven). Directory-per-epic layout: `epic.plan.md` + `wave-NN-<slug>.plan.md` + `continuation.md` at the epic-dir root; parallel specs/ and adrs/ trees. Zero-padded epic numbers, kebab-case slugs. Evidence-gate hook descends 2 levels to find nested plans; governing-skill hook enforces frontmatter on artifact-named files under these paths. Both dirs gitignored.

- **Canonical-sdlc artifacts require governing-skill frontmatter.** Every `*.plan.md`, `*.spec.md`, `adr-*.md`, `continuation*.md` under `.bionic/docs/{specs,plans,adrs}/` must have:

  ```
  ---
  governing-skill: <skill-id>
  sdlc-step: N
  epic: epic-NN-<slug>
  wave: wave-NN-<slug>
  canonical_sdlc_version: 14
  intent: <intent>
  rigor: <rigor>
  scale: <scale>
  ---
  ```

  at the top. The `canonical-sdlc-governing-skill.sh` PreToolUse|Write,Edit hook blocks writes missing the `governing-skill:` field. Non-artifact files (README.md, images) under those paths pass through.

## Design section authoring (the Step-2 back-half)

SKILL.md carries the contract — the five parts, the three-way rule, the scale line, the
mandatory Design Interview, and the provenance chain each design decision sits in. This is how
to author one that earns its keep.

### The view menu

A design is several *views* of one change, and the way a design goes wrong is rarely a wrong
answer — it is a view nobody looked at. The menu:

- **logical domain model** — the entities and relationships the change reasons about;
- **entity / data design** — the concrete shape of those entities: fields, types, identity;
- **persistence** — schema, mutability, transactions, migration;
- **application / component design** — modules, boundaries, control flow, who calls whom;
- **integration surfaces** — the contracts crossed: APIs, hooks, CLIs, file formats, events;
- **deployment / runtime architecture** — where it runs, in what process, under what lifecycle.

**The design names which views the change touches, and includes those.** A view considered and
excluded costs one clause — "no persistence: nothing is stored" — and that clause is worth its
line, because it is the entire difference between a decision and an oversight. **Silent
omission is the failure the menu exists to prevent**: a view that appears in neither list is
itself the finding, and the reader cannot tell an inapplicable view from a forgotten one.

Not every change touches every view, and padding the section with empty headings is its own
failure. Most work in this repo touches application/component design and integration surfaces
and excludes entity/data design and persistence in a clause apiece; that is a healthy shape,
not a thin one.

### The form menu

The view menu says what the design must look at. This one says what it gets *written as*. That
is a decision too, and it is made in the frame in front of the user rather than by whatever
template the author reached for first. Five rungs, cheapest first:

- **design paragraph in the session plan** — the suggested default at `scale: task`. One
  non-trivial task, one paragraph: what it touches, what owns the concept, what breaks if the
  assumption is wrong.
- **flush-left `## Design` section in the spec** — the suggested default at `scale: wave`, and
  the rung to beat. The design sits beside the requirements it answers, so the whole provenance
  chain reads in one file.
- **standalone design doc** — the suggested default when the design outlives the wave that
  authored it, or when several waves will implement it: an epic-level domain model, a mechanism a
  later wave builds. This is what a `design:` pointer resolves to, so choosing this rung is
  choosing to be pointed at, and the pointer is what the Step-3 approval display prints.
- **structured models** — a logical domain model, C4 context/container/component views, sequence
  diagrams — the suggested default when component or integration *topology* is the hard part and
  would hide in prose. Prose describes two components well and five badly; the moment "who calls
  whom, in what order, across which process boundary" takes a paragraph to state, it wants a
  picture instead.
- **full Technical Design Document** — the suggested default at momentous or cross-system scope,
  where the surface is large enough that its decisions no longer fit beside the requirements and
  the design has readers who will never open the spec.

The rungs compose rather than exclude. Structured models most often live *inside* a `## Design`
section or a standalone doc rather than instead of one, and reading the menu as five mutually
exclusive boxes is its common misuse.

**Derivation produces a suggested default, never a selection.** Scale gives the starting rung —
task to paragraph, wave to `## Design` section — and three signals move it up: a design several
waves will implement (standalone doc), topology prose would flatten (add structured models), a
cross-system surface with its own readership (full Technical Design Document). One signal moves
it down: a wave whose design is one decision wide gets a short section, not a doc. Print the
result in the frame with the one-line reason it was derived; the user moves it up, moves it down,
or lets it stand. The menu suggests, and that is all it does.

**Nothing enforces the rung, deliberately.** The three-way wall already accepts every one of
them — in place as a `## Design` section, or by pointer to whatever the standalone form produced
— so form selection cannot fail a gate and was never going to. It is guidance ratified in
conversation, and the whole cost of getting it wrong is a design in a shape that does not fit
its readers.

### The Design Interview

SKILL.md makes it mandatory and names what it is for. This is what to carry into it.

**Bring four things.** The view declarations, touched and excluded, in that one-clause form.
The design itself, at the altitude of decisions rather than of code. The rejected alternatives,
each with the reason it lost. And the load-bearing assumptions **posed as questions** — "this
assumes the installed hook stays at the old version all wave; is that right?" beats "assumes
hooks stay pinned", because the first is answerable and the second is skimmable.

**Interview on what the repo cannot settle.** The assumptions worth a user's attention are the
ones no amount of reading resolves: intent, operational constraint, which way a future change
is expected to go. Anything you could have checked by opening a file is not an interview
question — go open the file.

#### The opening frame

Those four things reach the user through a frame, and the frame comes before any question. Seven
lines, one or two sentences each — the whole thing is a screen, not a document.

- **Problem** — what is wrong or missing now, in the user's terms rather than the code's.
- **Goal** — what "designed" looks like when this interview ends.
- **Design intuition** — the shape you already expect to be right, stated plainly enough to be
  wrong. Withholding it to seem neutral wastes the user's turn: nobody can push on a lean you
  never named.
- **Requirements served** — one line per requirement this design answers, cited by id. It is the
  provenance chain's first link, upstream of every criterion's own `provenance:`, and each entry
  in the decision map below names the requirement it serves.
- **Decision map** — the choices ahead, every entry marked **strategic** or **tactical**.
  Strategic means the wave comes out shaped differently depending on the answer; tactical means
  you could pick it yourself and be right most of the time.
- **Capture plan** — where the design ledger accretes, named before the first answer lands.
- **Artifact form** — the rung derived from the menu above, printed as a suggested default with
  its one-line reason.

Then question 1, which ratifies the frame and nothing else. Worked, at wave scale:

> **Problem.** Two hooks each hard-code the supported version; nothing makes them move together.
> **Goal.** One owner for that value, and a test that goes red when any rendering site drifts.
> **Design intuition.** A single constant in a sourced lib, with the pin test widened to every
> rendering site — I expect the prose sites to be the hard part, not the shell ones.
> **Requirements served.** R2 (an agreement test names a real failing test) · R4 (no silent
> drift).
> **Decision map.** (1) Where the constant lives — **strategic**, serves R2. (2) Whether the
> prose sites get pinned or recorded as unpinned — **strategic**, serves R4. (3) Which file the
> test lands in — **tactical**, serves R2; I will default it to the existing pin suite.
> **Capture plan.** The ledger accretes in this spec's `## Design`, one delta per turn.
> **Artifact form.** Suggested default: `## Design` in place — wave scale, one file's worth of
> decisions, nothing downstream inherits it.
>
> **Q1.** Does that frame hold, or is there a decision I have not listed?

Three things that example does on purpose: the intuition is specific enough to argue with, every
decision-map entry names the requirement it serves, and the tactical entry announces its default
instead of quietly taking it.

#### Walking the map

**One decision per turn.** The shape this refuses is **batch presentation** — the design
delivered whole as a wall of text ending in "thoughts?" — and it is refuted by dogfood rather
than by taste: nobody answers six coupled questions in one reply, so they answer the easiest one
and the rest ship unexamined. The second refuted shape is **question-without-frame**, a fork
posed before its terms exist; the frame is that one's fix, which is why question 1 spends itself
on the frame and never advances the map.

**A strategic choice gets a question stating the tension and your lean.** "A or B?" is not that
question. The shape is: what A buys and costs, what B buys and costs, which way you lean and why
— which hands the user something to disagree with inside one turn.

**A tactical choice you may default**, which is what the mark is for, but a default is never
silent. State it the turn you take it, or at the latest in the closing ratification, in the form
"I defaulted X to Y because Z; say the word and it changes." A tactical default nobody ever saw
is the same defect as an unlogged assumption, one step earlier.

**The ledger accretes visibly.** Each answer folds in as a named delta the turn it lands — "D3:
the constant lives in `lib/`; the pin suite widens to four sites" — so the user reads a design
being built rather than a transcript being taken. Skip the deltas and the close becomes the
first time the user sees the design whole, which is too late for it to be the first time.

#### The waiver

**The waiver is the user's, and it is recorded verbatim.** If the user declines the interview,
write their words into the design's assumptions — `Design interview waived by <user> <date>:
"<quote>"` — so a later reader meets a decision rather than an absence. "The user did not
respond" is not a waiver; it is an unfinished Step 2. An agent never waives its own interview.
A waiver declared at Step 0 rather than mid-interview — `design-interview: false`, that waiver's
**standing Step-0 form** — carries this same obligation and does not replace it: the frontmatter
value records the decision with its `<user> <date>`, this line records the *reason*, and the words
quoted are the ones the user gave at Step 0.

### The ownership table

The table is the load-bearing row of the whole section, and the only part later steps consume
mechanically: Step 6's duplication axis anchors on the owner column, and the agreement-test
column is the obligation the reviewer reads back. Shape:

```
| concept | owning module (SSoT) | rendering surfaces | agreement test |
|---|---|---|---|
| version pin value | no single place — typed at each site; that IS the finding | both hooks · scripts.test.sh assertions · SKILL.md prose · this file's version history · the two SVG diagrams | pin-sync rows in tests/scripts.test.sh pin the two hook sites, and tests/diagrams.test.sh pins the four diagram renderings against the hook's value; the two prose sites drift silently |
| agreement-test exemplar + authoring rules | SKILL.md §Step 6 | SKILL.md §Step 6 · agents/critic.md AXIS block · this section | AXIS-marker rows in tests/agent-roles.test.sh — the pin covers two of the three surfaces; this section is the unpinned one |
```

- **One row per concept rendered at more than one surface.** A concept that exists in exactly
  one place has nothing to disagree with itself about, and listing it is padding. The table is a
  duplication ledger, not an inventory of the change.
- **The owner is a place, not a layer or a role.** "the governing-skill hook" is an owner; "the
  backend" is not. If you cannot name a file, a function, or a single named constant, the concept
  does not have an owner yet — and that is the finding. Write it down instead of inventing one.
- **Rendering surfaces include prose.** A constant read by two scripts and quoted in a doc has
  three surfaces, and the doc is the one that drifts, because nothing runs it.
- **The agreement test is a real hermetic test that fails when the surfaces disagree** — named,
  not a suite and not "covered by the unit tests". The standing exemplar is the
  `SUPPORTED_SDLC_VERSION` pin-sync rows in `tests/scripts.test.sh`: one logical constant, two
  rendering sites pinned — the two hooks — and one test that goes red the moment either moves
  alone. It is also the honest limit, and the limit is the half worth knowing while you write the
  cell: the version paragraph in `SKILL.md` and the version-history bullet at the top of this file
  are rendering sites *outside* that tuple, and they drift silently — which is exactly the row the
  table above writes down rather than rounding up to "pinned". The diagrams used to sit in that
  same unpinned set and no longer do: composing them as SVG made their four version renderings
  greppable, and `tests/diagrams.test.sh` reads the hook's value rather than restating it. That is
  the general move — a surface becomes pinnable by changing its format, not by promising to
  remember it. `none — <why>`
  is a legitimate cell — some pairs are prose against prose, and a mandate dispatched verbatim
  has no seam to test — but it is a cell the reviewer will stop on, so give it the reason.

### Scaling

- **Task** — a paragraph per non-trivial task, in the session plan: what it touches, what owns
  the concept, what breaks if the assumption is wrong. No table, and no wall.
- **Wave** — a page or two in the spec, all five parts. The ownership table usually runs three to
  six rows; at twenty, the wave is carrying more than one wave's worth of concepts and the
  finding is the slice decomposition, not the table.
- **Epic** — the domain model and boundaries that outlive any single wave, so waves can point at
  them rather than restate them.
- **Never forty pages.** The section exists to make the ownership and duplication decisions
  visible before code is written, not to specify the code. A design longer than the slice list it
  governs has stopped being a design and started being an implementation nobody ran.

Rejected alternatives are one line each — the alternative, and why it lost — and they are the
part a later reader needs most, because the question they answer ("why not just…") is the one
that recurs. Assumptions are what the design would break if false; they seed the plan's
`## Assumptions`, where Step 4 resolves them inline.

### The by-reference form

`design: <path>` in frontmatter is for a design that legitimately lives above the artifact —
typically an epic-level design that several waves implement. The target must be a real file
carrying its own flush-left `## Design`, and path resolution follows the walk-artifact template
(against the docs root, a bare path against the project root, an absolute path as written, a
`..` component refused).

A wave may carry both the pointer and a local `## Design` section, and that is the intended
shape when an inherited design is right about the domain but silent on this wave's specifics:
the pointer names what governs, the local section carries only the delta. The local section does
not excuse the pointer: a `design:` that is present is resolved, existence-checked and
`..`-refused whatever else the spec carries, because the path it names is the one the approval
display prints for the user to open. Whether the inherited design suffices is judgment, ratified
at the Step-3 approval alongside everything else.

`design-waived:` is not a lighter version of the pointer. Waived means no design governs this
artifact; a pointer means one does and here is where. Waiving because the design lives elsewhere
destroys the one thing the approval display is built to carry — the path the user would open.

## Close-out report (Step 9)

SKILL.md carries the terminal-disposition rule and names the report's ten parts; this is the
authoring detail — what each part is for, and the bound that keeps the whole thing from
growing back into ceremony.

The rule itself is not restated here. It lives once, in `agents-src/blocks/terminal-disposition.md`,
and is rendered into `SKILL.md` §Step 9 — read it there. A second copy in this file was the
duplicate wave-02 removed (spec AC-6).

**The report is one turn.** Not a document, not a file the user has to open — it is the
close-out message itself, sent once, at Step 9. A close-out that spans multiple turns or
defers its verdict to a linked artifact has already become the ceremony the rule exists to
forbid.

**Ten parts, plain English, at the altitude of decisions:**

- **Goal** — what this run set out to do, in one sentence.
- **Accomplished** — what shipped, named plainly.
- **Deferred, with dispositions** — every finding that did not ship, each carrying its
  terminal disposition: DO-NOW (folded in already, so this list should hold none of them),
  ACCEPT-CLOSED (won't-fix, with the one-line reason), or PROMOTE (its trigger event or its
  chartered home, named). A finding with no disposition is the defect this template exists
  to catch.
- **Special attention** — anything the reader should look at closely before trusting the
  rest of the report.
- **Material risks** — what could still go wrong, named, not hedged.
- **Challenges** — what made this run harder than the plan assumed.
- **Decisions** — the calls made along the way that a later reader would want to know were
  made on purpose.
- **Success/failure verdict** — one plain sentence: did this run meet its goal.
- **Learnings** — what this run taught that the next one should carry forward.
- **Next** — the immediate next action, named.

**The anti-ceremony bound.** The whole report is readable in the time it takes to read this
paragraph twice. A per-AC breakdown, a restated Verification Matrix, a section for every
step's evidence, or a sub-heading per finding are all the same failure — institutional
confirmation dressed up as an audit. If a part has nothing to say, it gets one clause ("no
material risks") rather than a heading with nothing under it. Plain English means no jargon a
plain reader would have to look up, and conceptual altitude means decisions and outcomes, not
diffs, commands, or file paths.

## Evidence gate

- **Canonical-sdlc plan files must include a `## SDLC State` section** — `current: N` (or `T<n>` at task scale) and `Step N: <evidence>` lines. The `canonical-sdlc-evidence-gate.sh` PreToolUse hook blocks `git commit` when the current step's evidence line is missing, empty, or a placeholder (TODO/pending/in progress/XXX/TBD/placeholder). Update `## SDLC State` *before* staging, not after.

## Verify gate (Step 5) browser modality — CLI-first

- **The Verify gate's browser modality (Step 5) drives the browser via `playwright-cli`, not the chrome-devtools MCP.** Changed 2026-06-14; in v5 (2026-06-19) browser verification became the **browser modality of the Step 5 Verify gate** (alongside the tests/build modality), no longer a standalone step. The governing skill is the bionic-owned `browser-verify` (`skills/browser-verify/`, registered as `local-skill | browser-verify`), which wraps `playwright-cli` (`@playwright/cli`, the token-efficient driver: `snapshot`/`click`/`fill`/`console`/`network`/`screenshot`, sessions via `-s=`). `agent-skills:browser-testing-with-devtools` (chrome-devtools MCP) is demoted to the **deep-debug escalation only** — Lighthouse, performance-trace *analysis*, heap/CPU profiling, network throttling — capabilities `playwright-cli` does not expose. Rationale: MCP tool schemas are an always-on context tax; the CLI is pay-per-call, and browser-verify tokens are dominated by iteration on hard pages, which a robust skill procedure reduces. The evidence key stays `devtools-trace:` (a label, not a tool binding — hook + tests unchanged).

## RCA vs ADR

- **RCA ≠ ADR.** ADRs record forward-facing design decisions ("we chose X because Y"). RCAs (postmortem root cause analyses) record backward-facing incident reconstructions ("this broke because X; fix is Y; prevention is Z"). `intent: incident-response`'s Step 9 produces an RCA at `.bionic/docs/incidents/NNNN-<slug>/rca.md`, not an ADR. Required RCA shape: summary, timeline, root cause, contributing factors, fix, prevention, **monitoring gap analysis** (concrete — either "monitoring caught this at <t>, no gap" with evidence, or a description of the gap + link to the commit that closed it). Hand-waved gap analysis is not accepted.

## Design work

- **Impeccable has an implicit `shape → craft → polish → critique` lifecycle** (visible in how each skill's description references the others; not documented as a single orchestration file). For tracked design work shipping to users, run it under `canonical-sdlc` (`intent: build`; the `design-refresh` mode that used to name this mapping is retired vocabulary — the mapping itself still holds): Step 1 → `shape`, Step 4 → loop of `/impeccable craft` → `polish` (+ `harden` + `normalize`) → `critique` with exit gate (heuristic scores ≥ 3/4, cognitive load ≤ 1, AI-slop test fails, polish checklist complete), Step 5 (Verify) heavily weighted + `audit`, Step 6 (Review) is code-only (5 axes; design quality scored in the Step 4 critique loop), Step 10 optional `extract`. For ad-hoc design iteration (prototype, artifact, one-off polish) use `/impeccable craft` directly — no lifecycle shell. Codified 2026-04-18 in `skills/canonical-sdlc/SKILL.md` (carried into v3, 2026-05-10).

## Test-suite fragility

- **Running `bash test.sh` from the main workspace is sensitive to `.bionic/docs/plans/` content.** The `canonical-sdlc-evidence-gate.test.sh` suite's "no plans found → allow" cases rely on the hook's pwd-fallback finding no plan; but if pwd's `.bionic/docs/plans/` contains an active plan whose current phase evidence line has a placeholder token (todo/pending/in progress/xxx/tbd/placeholder), the tests fail. Workaround: keep the current-phase evidence line free of placeholder tokens when you'll run the full suite locally. Discovered 2026-04-16 post-merge during Phase 12 verification. Not in scope to fix the test fragility now — just avoid "pending" etc. in active phase lines.

- **Sharper form (bit again 2026-07-15, epic-02 Step 8):** on shape-checked steps (v5+: Steps 5, 8, 9) the trap is not just placeholder tokens — advancing `current: N` before the step's FULL multi-field evidence block exists fails the suite even with innocent text like "(awaiting merge)", because the hook shape-validates the real newest plan via pwd-fallback. Rule: run the suite → do the step's work → write the complete evidence block AND advance `current:` in the same edit. Never advance first.

- **Annotated `Step N (stance M):` lines DON'T satisfy the numeric-step matcher (bit 2026-07-22, epic-10 wave-02 Step 6 — cost one blocked commit).** The evidence-gate finds the current step's evidence line with `^[[:space:]]*-?[[:space:]]*(Step|Phase)[[:space:]]+N[[:space:]]*:` — the digit must be followed by ONLY whitespace, then the colon. A `Step 6 (stance 1):` line has ` (stance 1)` between `6` and `:` and does NOT match, so a plan whose only step-N lines are annotated variants BLOCKS every commit at `current: N`. Fix: carry a bare `Step N: <pointer>` line ALONGSIDE the annotated detail lines (the v10 shape's "pointer to 5-axis body + critic findings" is exactly this — one bare line + stance detail below it). Generalizes to any `Step N (…):` form (stance/phase/sub-label). Wave-01 dodged it only because its T6/T7 commits happened to land at other `current:` values.

## Design-time memory check

- **CORRECTED 2026-07-27 (epic-12 wave-01): the always-loaded project-notebook tier this rule described no longer exists.** The old rule ("memory sweep must be recursive — read `INDEX.md` AND every Deep Context pointer") named a load mechanism that epic-12 deleted. What survives is the lesson underneath it, which was never about recursion: **a catalogue entry is not the knowledge.** The 2026-04-16 dry-run that produced the original rule picked a stale design (SessionEnd option C) because the better approach lived one pointer deeper than the entry point that was read.

- **Design-time memory check — the live form of that lesson.** Before ratifying a mechanism at Step 1/2, grep the mechanism's moving parts against the recorded operational record (`.bionic/docs/record/`, `.bionic/docs/ideas/`) and the always-loaded fact bank. Epic-06 shipped "run old playwright CLI under system node" while epic-04's hang lesson sat unread in the record — every downstream gate then verified a doomed design. For anything that executes external binaries, the Verification Matrix needs one live-execution row at Step 5, pre-merge: T2-with-stubbed-binaries cannot catch version-pair incompatibilities.

## Arming doctrine (standing, ratified 2026-08-15 — landing-supervision run)

- **Arming is per-process and never survives a resume.** `--resume` (plain or
  `--fork-session`) rehydrates the conversation, not the skill-channel hook
  registration; the walls are silent in the resumed process until the governing skill is
  re-invoked. Re-invocation after ANY resume is standing practice, not a repair.
- **A `/hooks` listing is never proof of arming — only a wall observably firing is.**
  The healthy probe is a deliverable-less dispatch (expect refusal); the roster row is
  authoritative only within a session already proven armed (an unarmed session's roster
  records nothing).
- **The Skill-tool invocation arms identically to the typed slash command** (proven by
  refused probe immediately after `Skill(canonical-sdlc)` in a process where the same
  probe launched unwalled minutes earlier) — an orchestrator can self-heal arming after
  a resume without user action.
- Origin: the 2026-08-15 "first-arming failure" investigation — root-caused NOT to
  registration (t8-forensic-read.md: the newest-plan off-switch, since fixed) — plus
  direct resume measurements (t7-resume-probe.md rounds 2–3), both under
  record/session-20260815-landing-supervision/.
