# Migration ledger: core / adapter / discard

Research ticket R3 — [chrisalehman/bionic#22](https://github.com/chrisalehman/bionic/issues/22),
child of map #19. Written 2026-09-03 on branch `research/migration-ledger`.

**Question.** Of every omnigent-era change to the shared core, which does bionic keep (core
improvement), which moves to the omnigent adapter (bundle policy or binding), and which is
discarded? Reverse: which bionic-only additions since 1.3.2 must the adapter honour? And,
per paragraph, where does each rule in `.claude/rules/*.md` belong?

**Inputs.** Last common commit `2e98368` "bionic 1.3.2" (2026-08-30). bionic worktree HEAD
`ab817ba` (1.4.1, 126 commits since fork). bionic-omni `epic/20-bionic-on-omnigent` @
`42f4cf8` (164 commits touching the shared core since fork; 274 in all). Citations prefixed
`omni:` are paths in the bionic-omni checkout; unprefixed paths are this worktree; bare
7-hex ids are commits in whichever repo the row names. Method: `git diff --name-status
2e98368 42f4cf8 -- hooks agents agents-src skills tests payload/scripts` on omni, then each
file's omni-side diff read beside bionic's own diff of the same path, split into one-intent
hunks. Three read-only researchers sorted the omni side (agents/skills, hooks/scripts, tests);
the rules-file sort and the adapter-obligation table were done by the ticket owner.

## Headline

| | keep | adapter | discard | rows |
|---|---|---|---|---|
| agents-src / agents / skills | 6 | 17 | 1 | 24 |
| hooks / payload/scripts | 14 | 0 | 3 | 17 |
| tests (modified shared suites) | 5 | 3 | 2 | 10 |
| tests (omni-only additions, grouped) | 1 | 13 | 0 | 14 |
| **total** | **26** | **33** | **6** | **65** |

Five facts shape everything below.

1. **The two forks did not touch the same code.** Omni changed 4 files under `hooks/` and
   `payload/scripts/`; bionic changed 38 and added 8 library files. Omni's work went into
   role text, skill text, the bundle, the bindings and 17 new test files. Textual conflicts
   are near zero; the problem is that omni's hunks sit on a substrate bionic rebuilt.
2. **Both trees diagnosed the same false positive on 2026-09-02 and cured it differently.**
   The "N launches unrostered" alarm fired on a second-wave session after Step 8 wiped
   `.bionic/tmp`. Omni narrowed the count to the roster's own window (`c8a0f89`); bionic
   deleted the tick's check (walls moved to `hooks.json`) but kept doctor's copy, which still
   counts the whole transcript (`payload/scripts/lib/patrol.sh:265`,
   `payload/scripts/doctor.sh:1263-1264`). The window is the highest-value keep in the ledger.
3. **The adapter cannot launch a Claude seat against the bionic that is installed.** The shim
   parses the `hooks:` block of the plugin's `canonical-sdlc/SKILL.md` and refuses (exit 8)
   when there is none (`omni:bindings/claude/shim/claude:124-125`, `:750-760`). bionic 1.4.0
   deleted that block; `hooks/hooks.json` is the only registration channel (`bf296e5`,
   `c9f126f`). The plugin the CLI resolves is bionic 1.4.1 (`payload/.claude-plugin/plugin.json:3`);
   omni's payload says 1.3.5 (`omni:payload/.claude-plugin/plugin.json:3`) and was never
   installed. Table 2 row 2.
4. **No omnigent seat is ever engaged.** 1.4.1 makes every hook read
   `.bionic/tmp/engaged-<sid>.state` first (17 hooks, `payload/scripts/lib/run.sh:229-234`);
   the marker is written only when the session itself invokes `canonical-sdlc`
   (`hooks/engage.sh:51-70`). Worker seats get their identity by `--append-system-prompt-file`
   and never invoke a skill, so every plugin hook is silent in them; the orchestrator seat
   engages only if it obeys its template's instruction to invoke the skill
   (`omni:agents-src/templates/orchestrator.md.tmpl:49-51`). Table 2 row 1; this is the
   map's "is the 1.4.1 marker the right session-scoping mechanism" fog, now with facts.
5. **The `.claude/rules/` prior sort is half right.** `hook-authoring` and `test-harness` are
   pure repo, confirmed. `git-worktree-docs` is not: two of its five paragraphs state the
   artifact layout every bionic consumer depends on, both already shipped in `SKILL.md`.
   `agent-discipline` splits finer than "section = category": 8 of its 18 paragraphs are
   bionic core, of which 4 are orchestrator-facing with **no shipped channel**, 2 are
   implementor-facing with a shipped channel not yet used, 1 belongs in a skill that ships,
   and 1 is already shipped twice. Across all four files, **5 orchestrator-facing core
   paragraphs have no shipped channel**. Table 3.

---

## Table 1 — omnigent-era changes to the shared core

Sort key: **keep** = a harness-neutral improvement bionic takes into the core. **adapter** =
omnigent-specific; lives in the omnigent adapter (bundle policy, binding, or the adapter's
own tests). **discard** = superseded by bionic's own post-1.3.2 change, obsoleted by omnigent
0.12.0's `instructions:` channel, or noise.

### 1a. `agents-src/`, `agents/`, `skills/` (24 rows)

`agents/*.md` are rendered from `agents-src/` by `render.sh`; rows sort at the source and the
six rendered files follow on re-render. bionic never touched `render.sh` since the fork, so
every `render.sh` row is a clean add-or-skip.

| # | path | omni commit | what changed | sort | why | citation |
|---|---|---|---|---|---|---|
| A1 | agents-src/blocks/survival.md | a0022d8 | "(the orchestrator's Agent call ran you as a background task)" → "Dispatch is an intention the platform binds; never name a tool in a brief" | adapter | Exists only to stop the shared block naming Claude Code's `Agent` tool; forward-references a binding table that exists only in omni's SKILL.md. On a one-harness plugin the tool name is correct. bionic's wording wins; the adapter substitutes at render time | omni:agents-src/blocks/survival.md:28-29; rendered at omni:agents/{auditor:78,critic:84,implementor:78,researcher:67,senior-implementor:78,test-runner:81} |
| A2 | agents-src/templates/implementor.md.tmpl | f830c0d | new `disallowedTools: Agent, Task` | keep | Harness-neutral hardening of a rule the role files already state in prose (AC-11 worker containment). Behaviour change: implementors can dispatch today, so it wants an explicit yes, not a ride-along | omni:agents-src/templates/implementor.md.tmpl:6 |
| A3 | agents-src/templates/senior-implementor.md.tmpl | f830c0d | new `disallowedTools: Agent, Task` | keep | same as A2 | omni:…/senior-implementor.md.tmpl:6 |
| A4 | agents-src/templates/researcher.md.tmpl | f830c0d | `Write, Edit, NotebookEdit` → `…, Agent, Task` | keep | same as A2 | omni:…/researcher.md.tmpl:6 |
| A5 | agents-src/templates/test-runner.md.tmpl | f830c0d | `Write, Edit, NotebookEdit` → `…, Agent, Task` | keep | same as A2. Auditor and critic deliberately unchanged: the auditor mandate needs the test-runner, so it must dispatch | omni:…/test-runner.md.tmpl:6; omni:agents-src/render.sh:388-389 |
| A6 | agents-src/render.sh | 710ddeb, 8988c85 | "TWO RENDER UNITS" → "FOUR"; ~50 lines describing bundle-agents and seat-map units | adapter | documents units that exist only for the bundle | omni:agents-src/render.sh:11, :18-57 |
| A7 | agents-src/render.sh | 710ddeb | shipping boundary rewritten around `bundle/` | adapter | whole sentence is about `bundle/` | omni:agents-src/render.sh:69-70 |
| A8 | agents-src/render.sh | 710ddeb | `render_one` gains `<target>` = `md`\|`yaml`; yaml arm consumes frontmatter, no-ops the generated header | adapter | generic-looking but inert in bionic: no consumer passes `yaml` | omni:agents-src/render.sh:267-292 |
| A9 | agents-src/render.sh | 710ddeb | new `bundle_role_dir()`, `generated_header_yaml()` | adapter | bundle directory naming and YAML header | omni:agents-src/render.sh:365-384 |
| A10 | agents-src/render.sh | 710ddeb, f830c0d | `BUNDLE_TOOLS_ORDER` + `bundle_tools_for()`: grant = vocabulary minus `disallowedTools:` | adapter | bundle-only output. The "one fact, two readers" idea is transferable but has no second reader in bionic | omni:agents-src/render.sh:386-390, :414-430 |
| A11 | agents-src/render.sh | 088572c | per-role `spec_version:`; grant moved off `tools:` into `params:` | adapter | omnigent parser conformance (AP-1/AP-2) | omni:agents-src/render.sh:392-403, :659-664 |
| A12 | agents-src/render.sh | 96a3dd3 | `bundle_roster_key()` / `bundle_seat_for()`; `params.seat` emitted | adapter | reads `bundle/config.yaml` `params.roster`, which bionic lacks | omni:agents-src/render.sh:441-461 |
| A13 | agents-src/render.sh | 478ab54 | `permission_mode: auto` gated on `harness = claude-native` | adapter | gated on a roster harness value | omni:agents-src/render.sh:672-682 |
| A14 | agents-src/render.sh | 8988c85 | fourth unit `render_roster_seats()` → `bundle/policies/roster_seats.json` | adapter | feeds a Python policy; explicitly outside `payload/integrity/agents.sha256` | omni:agents-src/render.sh:504-524 |
| A15 | agents-src/render.sh | 1d6c36d | shared loop skips any `templates/*.md.tmpl` not in `$ROLES` instead of rendering a stray `agents/<name>.md` | **keep** | harness-neutral robustness: today a stray template becomes a phantom dispatchable role with no integrity row | omni:agents-src/render.sh:589-598 |
| A16 | agents-src/render.sh | 1d6c36d, b119f59 | body rendered a second time to `bundle/agents/<dir>/seat-prompt.md` + orchestrator seat-prompt block | **discard** | the launch-time injection omnigent 0.12.0's `instructions:` channel (upstream PR 3929) obsoletes; omni's own research records that keeping it puts the role text twice in one system prompt | omni:agents-src/render.sh:706-717, :745-777; omni:.bionic/docs/record/epic-20-w5/research-omnigent-identity-channel.md:209-215, :243-245 |
| A17 | agents-src/render.sh | b119f59 | comment fix (F-DUP-7): `--check` does not pin `tools_denied` against `dispatch_convert.py` | adapter | comment on adapter-only code | omni:agents-src/render.sh:709-715 |
| A18 | agents-src/templates/orchestrator.md.tmpl (new) | 1d6c36d | 52-line orchestrator **seat** identity: Role naming six worker seats (:10-15); load-time duty to state the triple on turn 1 and every resume (:17-26); "dispatch goes by role through your own send, never `Agent`/`Task`", naming `mcp__omnigent__sys_session_send` (:28-40); three standing duties: evidence gate is a hook, the Patrol is yours to arm, skills reach you from the host plugin only (:42-52) | adapter (content 3/4 neutral) | Does **not** render to `agents/orchestrator.md`; renders to `bundle/agents/orchestrator-seat-prompt.md` so omnigent's `_discover_sub_agents` does not pick up a seventh agent. Delivery mechanism is obsolete (row A16). §Dispatch and the seat roster are adapter; the triple announcement and the three standing duties are bionic governance that hold on any harness and are the content to lift when bionic charters an orchestrator channel (Table 3, G3) | omni:agents-src/templates/orchestrator.md.tmpl:3, :10-52; omni:agents-src/render.sh:589-598, :745-758 |
| A19 | skills/browser-verify/SKILL.md | 16b35db | `description:` wrapped in double quotes | **keep** | genuine YAML fix: the plain scalar contains `: `; bionic's copy is still unquoted | omni:skills/browser-verify/SKILL.md:3 vs skills/browser-verify/SKILL.md:3 |
| A20 | skills/canonical-sdlc/SKILL.md | a0022d8 | auditor "(`subagent_type: auditor`)" → "(the `auditor` role)" | adapter | de-tool-naming for seats; on Claude Code the original is what an orchestrator types | omni:skills/canonical-sdlc/SKILL.md:425 vs skills/canonical-sdlc/SKILL.md:369 |
| A21 | skills/canonical-sdlc/SKILL.md | a0022d8 | critic: same substitution | adapter | same | omni:…SKILL.md:455 vs …SKILL.md:399 |
| A22 | skills/canonical-sdlc/SKILL.md | a0022d8 | "Roles, by `subagent_type`" → "Roles, by name" + "Dispatch is an intention" + two-row platform-binding table | adapter | row 2 is entirely omnigent; row 1 restates what bionic says inline; a one-platform core needs no indirection table. Omni's own corrections to the omnigent row (752afd0: `agent/title/args`, not `name/message`) are inside the adapter row | omni:…SKILL.md:530-536 vs …SKILL.md:474 |
| A23 | skills/canonical-sdlc/SKILL.md | 752afd0 | omnigent call parameters corrected | adapter | real fix to an interface bionic never calls | omni:…SKILL.md:535 |
| A24 | skills/canonical-sdlc/SKILL.md | a0022d8 | "fork only" → "fork (Claude Code only)" | adapter | no-op qualifier on bionic | omni:…SKILL.md:576 vs …SKILL.md:515 |

**Asymmetry, not a hunk.** bionic 1.4.0 deleted the 60-line `hooks:` frontmatter block from
`SKILL.md` and rewrote the Patrol paragraph around `hooks/hooks.json` + `hooks/engage.sh`
(`skills/canonical-sdlc/SKILL.md` hunk `@@ -1,66 +1,6`, `c9f126f`). Omni still carries the
old block and the "a skill's hooks die with the conversation" text
(`omni:skills/canonical-sdlc/SKILL.md:1-66`). bionic wins that span wholesale; the adapter's
shim arms walls from that block and must be re-derived (Table 2 row 2).

### 1b. `hooks/`, `payload/scripts/` (17 rows)

Only two omni commits are in scope: `16b35db` (2026-09-01, marketplace source) and `c8a0f89`
(2026-09-02, wall-blind window + poker perf). Zero adapter rows: nothing here couples to
omnigent.

| # | path | omni commit | what changed | sort | why | citation |
|---|---|---|---|---|---|---|
| H1 | hooks/session-poker.sh | c8a0f89 | new read-only `window` verb printing the roster's own ISO start instant | keep\* | the only way a `lib/` file reaches the window rule without a second copy; dependency of P4. Port edit: calls `resolve_project_root`, which bionic replaced with `project_root` (`payload/scripts/lib/root.sh`). Must stay **outside** the engagement gate, like `interval`, or doctor loses its window on every unengaged session | omni:hooks/session-poker.sh:184, :191, :1121-1148; hooks/session-poker.sh:1448-1450 |
| H2 | hooks/session-poker.sh | c8a0f89 | `file_birth()` (stat %B/%W), `epoch_iso()`, `roster_window()` | keep\* | pure helpers; `patrol_stamp_file` exists in bionic | omni:hooks/session-poker.sh:541-561; hooks/session-poker.sh:495 |
| H3 | hooks/session-poker.sh | c8a0f89 | `count_main_thread_dispatches` gains `<since ISO>` + per-entry `in_window()` | keep\* | real bug: `.bionic/tmp` is wiped at Step 8, so a second-wave session counted lifetime dispatches against a roster that began at the wipe. bionic's copy is byte-identical to base, unfixed | omni:hooks/session-poker.sh:570-597 vs hooks/session-poker.sh:697-703 |
| H4 | hooks/session-poker.sh | c8a0f89 | perf: cheap `index(line,"\"name\":\"Agent\"")` short-circuit before the regex, with `$0` saved into `line` | keep | standalone; measured 463 ms → 335 ms on a 7.2 MB transcript; applies verbatim. The `line` save is load-bearing (the counting gsub would clobber the record `in_window()` reads) | omni:hooks/session-poker.sh:583-595 |
| H5 | hooks/session-poker.sh | c8a0f89 | `count_refused_dispatches` gains the same `since` gate | keep\* | other side of the subtraction: a previous wave's refusal cancelled a real gap in this one | omni:hooks/session-poker.sh:627-641 vs hooks/session-poker.sh:728-734 |
| H6 | hooks/session-poker.sh | c8a0f89 | tick passes `TX_WINDOW` to both counters; `poker-tick/v1` NOTIFY gains `since=` | **discard** | bionic deleted the whole blind-wall block (1.4.0 AC-7): walls live in `hooks.json`, survive `/clear`, and the check had no "no active run" branch so unengaged sessions read as dead walls. bionic wins | omni:hooks/session-poker.sh:1443-1462 vs hooks/session-poker.sh:1766-1775 |
| H7 | hooks/session-poker.sh | c8a0f89 | 25-line comment "ONE WINDOW, BOTH SIDES OF IT" | **discard** | narrative for code bionic no longer has | omni:hooks/session-poker.sh:484-520 |
| P1 | payload/scripts/lib/patrol.sh | c8a0f89 | jq scan binds `. as $entry`, rides the entry timestamp on `A` and `R` records | keep | prerequisite for P2; bionic's `_patrol_scan_jq` is at base shape | omni:payload/scripts/lib/patrol.sh:185-206 vs payload/scripts/lib/patrol.sh:185-208 |
| P2 | payload/scripts/lib/patrol.sh | c8a0f89 | `_patrol_join_awk` gains `in_window(ts)`; `agents++` and `refused++` both gated | keep | **the live bug in bionic today**: doctor still prints `fix "session <short>: <blind> launches unrostered → re-invoke /bionic:canonical-sdlc"` from a whole-transcript count | omni:payload/scripts/lib/patrol.sh:255-264 vs payload/scripts/lib/patrol.sh:241-245; payload/scripts/doctor.sh:1252, :1263-1264 |
| P3 | payload/scripts/lib/patrol.sh | c8a0f89 | `_patrol_scan` takes `[<since>]`, threads `awk -v since=` through both arms | keep | mechanical carrier | omni:payload/scripts/lib/patrol.sh:284-292 |
| P4 | payload/scripts/lib/patrol.sh | c8a0f89 | new `patrol_window()`: shells to `session-poker.sh window` via `_detect_plugin_root`, sanitises to ISO chars | keep | mirrors bionic's own `patrol_interval()` shell-out exactly; avoids a second copy in a lib that cannot source `hooks/` | omni:payload/scripts/lib/patrol.sh:328-336 |
| P5 | payload/scripts/lib/patrol.sh | c8a0f89 | `patrol_report` computes `since`, passes it to `_patrol_scan` | keep | the wiring. bionic's two patrol.sh changes (`project_root` delegation :100-130, `PATROL_STALE_MULTIPLIER` :58) are in disjoint regions; clean cherry-pick once H1 lands | omni:payload/scripts/lib/patrol.sh:429-433 |
| D1 | payload/scripts/lib/detect.sh | 16b35db | new `detect_marketplace_source_path()`: `jq -r '.bionic.source.path // .bionic.source.repo // empty'` | keep, **must be adapted** | the capability is right and harness-neutral, but it hardcodes the `.bionic` key, which bionic's L-DETECT/4.1 fix (`cdc1fa3`) stopped doing because a fork registered under any other name reads `unknown` forever. Verbatim port would break on omni itself, a fork. One-line port onto `_detect_marketplace_name`, matching `detect_marketplace_feed_kind` | omni:payload/scripts/lib/detect.sh:675-687 vs payload/scripts/lib/detect.sh:643-670, :681-694 |
| C1 | payload/scripts/doctor.sh | 16b35db | `DOCTOR_REPO_ROOT` resolved from doctor's own location, never `BIONIC_PLUGIN_ROOT` | keep | layout identical in bionic (`DOCTOR_LIB` at same depth) | omni:payload/scripts/doctor.sh:112-124; payload/scripts/doctor.sh:113 |
| C2 | payload/scripts/doctor.sh | 16b35db | `MP_SOURCE_PATH`/`MP_SOURCE_STATE` gathered once beside `FEED_KIND` | keep | follows bionic's own gather-once discipline | omni:payload/scripts/doctor.sh:451-456; payload/scripts/doctor.sh:576 |
| C3 | payload/scripts/doctor.sh | 16b35db | header row `plugin source: <path> [this checkout]` / `[OTHER checkout]` / `unregistered`, realpath-compared | keep, reword | answers bionic's standing hazard "which checkout does the CLI actually load" (repo-hooks-vs-installed-hooks). `bionic_line` 3-arg signature and `_doctor_rtrim` match. Only "seat"/"doctrine" vocabulary is omni's | omni:payload/scripts/doctor.sh:1160-1189; payload/scripts/lib/width.sh:113; payload/scripts/doctor.sh:229 |
| C4 | payload/scripts/doctor.sh | c8a0f89 | `_patrol_flush` comment rewritten for the window rule | **discard** | bionic already rewrote the same comment for its post-1.4.0 truth; P1–P5 landing needs a one-line amendment, not omni's paragraph | omni:payload/scripts/doctor.sh:933-944 vs payload/scripts/doctor.sh:1231-1255 |

\* H1/H2/H3/H5 land **with** P1–P5 or not at all: `tests/cross-gate-agreement.test.sh`
compares session-poker's counters against `_patrol_scan` on one shared fixture, and windowing
one side alone turns it red. Note also that in bionic these two session-poker counters have
no production caller since the blind-wall deletion; they survive only as the agreement partner
for patrol.sh's copy.

**Engagement compatibility (Q4 of the brief).** Omni's window and bionic's marker attack
overlapping halves of one false positive; no incompatibility. The window narrows *which*
dispatches count; the marker decides *whether* the tick judges at all (`hooks/session-poker.sh:1452`,
`:1730`). Bionic's removal comment names the case omni's window does not fix: with no roster
there is no window, and omni leaves that deliberately un-narrowed ("case 7e",
`omni:hooks/session-poker.sh:505-510`). Bionic's gate is the stronger cure; omni's window is
the remaining half.

### 1c. `tests/` — modified shared suites (10 rows)

| # | path | omni commit | what changed | sort | why | citation |
|---|---|---|---|---|---|---|
| T1 | tests/cross-gate-agreement.test.sh | c8a0f89 | `q_poker`/`q_patrol` `since` plumbing + §Q.3 agreement pin (window on both sides) | keep | the agreement partner for H3/H5 + P2; lands with them | omni:tests/cross-gate-agreement.test.sh (§Q) |
| T2 | tests/cross-gate-agreement.test.sh | a0022d8 | survival-block wording pin follows A1 | adapter | pins adapter wording | omni:tests/cross-gate-agreement.test.sh |
| T3 | tests/detect-probes.test.sh | 16b35db | Group 6c: `detect_marketplace_source_path` on fork/other/absent registries | keep (with D1's adaptation) | tests the capability; fixture must be re-keyed on marketplace name with D1 | omni:tests/detect-probes.test.sh (Group 6c); omni:tests/fixtures/known-marketplaces-{fork,other}.json |
| T4 | tests/doctor-patrol.test.sh | c8a0f89 | Section 11: three arms proving doctor's count is windowed to the roster | keep | closes the false alarm bionic still has: the `"N launches unrostered"` fix line is still asserted at `tests/doctor-patrol.test.sh:408-409` from a whole-transcript count | omni:tests/doctor-patrol.test.sh (Section 11) |
| T5 | tests/doctor-version.test.sh | 16b35db | new Section 7: `[this checkout]` / `[OTHER checkout]` plugin-source line | keep | pins C3 | omni:tests/doctor-version.test.sh (Section 7) |
| T6 | tests/run.sh | (omni) | two roster lines outside the `tests/*.test.sh` glob: `pytest -q tests/policies` and `tests/drill/instrument.test.sh`; header count comment | adapter | neither side changed `run()`, which takes arbitrary argv (`tests/run.sh:177-190`); pytest needs a dependency, not a runner change. bionic's invariant `grep -c '^run "' == ls tests/*.test.sh \| wc -l` (49 == 49) is what adopting either line breaks. The live drill runner is barred from the roster by its own header | omni:tests/run.sh; tests/run.sh:56-63 |
| T7 | tests/session-poker.test.sh | c8a0f89 | 7f/7g: tick NOTIFY carries `since=`; window scoping | **discard** | scopes a NOTIFY bionic no longer emits; bionic retired the poker-side detector at 1.4.0 ADOPT with a `hooks.json` registration pin instead | omni:tests/session-poker.test.sh (7f/7g) vs tests/session-poker.test.sh:735-753 |
| T8 | tests/session-poker.test.sh | c8a0f89 | `window` verb tests | keep | pins H1 | omni:tests/session-poker.test.sh |
| T9 | tests/session-poker.test.sh | 5a0ff70 | fixture pins for omni's session model | adapter | omni-specific fixtures | omni:tests/session-poker.test.sh |
| T10 | tests/doctor-patrol.test.sh / cross-gate | c8a0f89 | comment/count drift ("42 suites" etc.) | **discard** | superseded by bionic's own roster (49 suites) | omni:tests/run.sh header |

### 1d. `tests/` — omni-only additions, grouped (14 rows)

| # | group | what it tests | depends on | hermetic? | sort | why |
|---|---|---|---|---|---|---|
| B1 | tests/fixtures/known-marketplaces-{fork,other}.json | registry shapes for D1/T3 | nothing | yes | **keep** | feeds the one keep in this table; re-key with D1 |
| B2 | tests/bindings.test.sh + tests/fixtures/bindings/** | the writer-delivered Stop hook's fail directions on both harnesses; auth fixtures | `bindings/` | yes (fixtures) | adapter | tests the binding |
| B3 | tests/bundle-load.test.sh | `bundle/config.yaml` parses as an omnigent bundle | omnigent installed | no | adapter | AP-2 wall |
| B4 | tests/drill/** (run.sh, lib.sh, probes.tsv, binding-cells.tsv, fixtures, provokers, instrument.test.sh, README) | live provocation drill: one seat per role, does each wall refuse; `instrument.test.sh` is the hermetic half over recorded transcripts | omnigent server, bundle, bindings; `instrument.test.sh` fixtures only | live runner no; instrument yes | adapter | the measurement instrument the ladder's rung 4 (walls refuse, drill-proven) stands on; bionic has nothing equivalent for the plugin (fog: a drill for the Claude plugin) |
| B5 | tests/fixtures/rules/** + tests/rules.test.sh | `bundle/rules.yaml` registry: every rule names a layer, a policy module, a refusal string; doctored fixtures go red | `bundle/` | yes | adapter | the one-table dispatch-tool rule is a harness-neutral idea worth re-authoring, not porting |
| B6 | tests/fixtures/seat/** + tests/seat-constitution.test.sh | the shim's argv and settings edits for a seat launch | `bindings/claude/shim` | yes | adapter | tests the shim; obsolete with row A16 when `instructions:` lands |
| B7 | tests/policies/** (17 pytest modules, 4,659 lines, conftest, fixtures) | every bundle policy's evaluate() against recorded events | pytest, `bundle/policies` | yes | adapter | Python, no slot in `tests/run.sh` |
| B8 | tests/launcher-scoreboard.test.sh | launcher block-by-block residue scoreboard vs `RESIDUE.md` | `bindings/claude/launch.sh` | yes | adapter | |
| B9 | tests/measure-gate.test.sh | AC-2 measurement gate (bionic-launched seat vs bare) over fixture repos | fixtures | yes | adapter | the git-history-with-fixture-repos pattern is worth re-authoring for the plugin's own measurement |
| B10 | tests/readme-diagram.test.sh | README diagram pins against omni's `diagrams/` | `diagrams/` (omni-only) | yes | adapter | bionic has no `diagrams/` at root |
| B11 | tests/reap-closed.test.sh | `bundle/scripts/reap-closed.sh` kill-seam discipline | `bundle/scripts` | yes | adapter | the kill-seam idea is harness-neutral; the script is not |
| B12 | tests/render-bundle.test.sh | render.sh's yaml/bundle units (A6–A14) | `bundle/` | yes | adapter | |
| B13 | tests/roster.test.sh | `bindings/claude/lib/roster.sh` role resolution | `bindings/` | yes | adapter | |
| B14 | tests/skill-dispatch-binding.test.sh | SKILL.md's two-row binding table (A22) agrees with the bundle | `bundle/`, SKILL.md | yes | adapter | falls with A22 |

**Runner note.** The adapter brings two test infrastructures bionic's roster has no slot for:
pytest (B7) and a live drill (B4). `tests/run.sh`'s directory-derived roster (fixit 1.5.1,
D-1) is what any monorepo layout must either extend (a second directory for the adapter) or
partition (the adapter runs its own).

---

## Table 2 — bionic-only additions since 1.3.2 the adapter must honour

Every row is a fact about bionic 1.4.1 with the adapter's exposure beside it. "Exposure" is
what breaks or silently changes if the adapter is ported as it stands.

| # | addition | what it is | bionic citation | adapter exposure | citation |
|---|---|---|---|---|---|
| 1 | **Engagement marker** (`hooks/engage.sh`, `engaged_session`) | The one switch. `engage.sh` writes `.bionic/tmp/engaged-<sid>.state` on the PreToolUse `Skill` call or the UserPromptExpansion of `canonical-sdlc`; 17 hooks call `engaged_session` before anything else and exit silently when false; the marker persists for the session; fail direction inverted (presence opens walls; every unreadable state reads as not engaged) | hooks/engage.sh:12-36, :51-70; payload/scripts/lib/run.sh:200-234; hooks/hooks.json (Skill + UserPromptExpansion entries); commits a497037, e9a0a60, 3bc39c2, 7688a3a | **No seat is engaged.** A worker seat's identity arrives by `--append-system-prompt-file` and it never invokes a skill; its sid is its own (every seat is a top-level session), so `engaged-<sid>.state` never exists and every plugin hook in the seat is silent: protect-main, protect-database, evidence gate, landing gate, dispatch-preflight, all of them. Under omnigent those walls are held at the mediator (`bundle/rules.yaml` guardrails) and by the binding's own Stop hook, so silence in worker seats may be the intended partition; it must be *decided*, not inherited. The orchestrator seat engages only by obeying its template and invoking the skill itself; nothing mechanical guarantees it. If the adapter wants seats engaged, the only doors are the two `engage.sh` reads (a Skill call or a command expansion) or writing the marker itself through `engaged_marker_path`, which needs the seat's sid before its first hook fires | omni:bindings/claude/shim/claude:24, :39-40; omni:agents-src/templates/orchestrator.md.tmpl:49-51; omni:bindings/claude/launch.sh:624-660 |
| 2 | **`hooks/hooks.json` is the only registration channel** | Every hook is registered once in `hooks/hooks.json`; the skill frontmatter carries no `hooks:` block; a hook registered only in frontmatter would arm nothing | hooks/hooks.json; skills/canonical-sdlc/SKILL.md:1-6 (frontmatter); .claude/rules/hook-authoring.md:30; commits bf296e5, c9f126f | **Seat launch refuses.** The shim reads the `hooks:` block of `<plugin-root>/skills/canonical-sdlc/SKILL.md` to write the seat's walls into its settings and exits 8 when the block is absent or unparseable. Against bionic ≥1.4.0 that is every claude-native seat launch. Also redundant: the CLI arms `hooks/hooks.json` in every session on the machine, including seats, so the per-seat settings write duplicated the plugin's own registration. The block must read `hooks/hooks.json`, or be deleted in favour of the plugin's registration plus row 1's engagement decision | omni:bindings/claude/shim/claude:42-46, :124-125, :292-335, :425-432, :750-760 |
| 3 | **`hooks/session-start.sh`** | SessionStart hook (`startup\|clear\|resume\|compact`): reports predecessor rosters, stamps, legacy symlinks and session-id channel agreement; prints nothing when clean; arms nothing; engagement-gated: an unengaged session on a project with an open run gets exactly one line, "an open run exists here (<plan>) — invoke /bionic:canonical-sdlc to engage it" | hooks/session-start.sh:2-52, :242-255, :381-405; hooks/hooks.json (SessionStart) | Every seat launch is a `startup`. On a project with an open run every worker seat's first context carries the one-line nudge to invoke `canonical-sdlc`; a worker that obeys engages itself and arms orchestrator walls in a worker. The adapter either suppresses the line for seats or accepts that workers see it. The pidfile channel reads `sessions/$PPID.json`; under omnigent the seat's parent is the runner, not an interactive CLI, so the third channel is likely `absent` and the `DIVERGE` verdict can only compare env and payload | hooks/session-start.sh:230-235, :257-263 |
| 4 | **`scripts/lib/root.sh` — `project_root`** | One resolver: nearest real `.bionic/` ancestor, a linked worktree mapped to its main repo via `--git-common-dir`, bounded below `$HOME`, symlinked `.bionic` skipped; replaces eight byte-identical `resolve_project_root` copies | payload/scripts/lib/root.sh:1-30; commit 96d05f4, baaac1c | Omni's H1 calls `resolve_project_root`, which no longer exists (port edit). The binding's `landing.sh` resolves the root by `--git-common-dir` on its own (`omni:bindings/claude/hooks/landing.sh:43, :203-205`); compatible in concept, but a second resolver is the class 1.4.0 retired. Spec §3 ownership: any adapter reader that names a root should shell to `project_root` or agree with it by test | omni:hooks/session-poker.sh:1140 |
| 5 | **`scripts/lib/session.sh` — `session_id`** | `$CLAUDE_CODE_SESSION_ID` is primary, the payload's `session_id` a witness; one stderr line on divergence; 20 readers call it; the engagement marker's filename derives from it | payload/scripts/lib/session.sh:1-27; commit 8fcd8b3 | The adapter's hooks read `BIONIC_SESSION_ID` then the payload (`omni:bindings/claude/hooks/landing.sh:215`); nothing in the adapter sets or reads `CLAUDE_CODE_SESSION_ID`. Whether omnigent's runner exports it into a seat is unmeasured; if unset, every hook reads the payload and prints the "env unset — using payload" line. Any marker the adapter writes (row 1) must derive its sid through this function or the 17 readers will look for a different file | omni:bindings/claude/hooks/landing.sh:215; omni:bindings/codex/scripts/landing.sh:235 |
| 6 | **`scripts/lib/run.sh` — `active_run`, `active_plan`, `docs_root`** | Explicit open/close, no clock: a run is active iff the newest `## SDLC State` plan has `current:` 0–8, or 9 without `delivered:`, or `T<n>`, and no `abandoned:` frontmatter. Demoted to data in 1.4.1; engagement decides whether, the plan decides what | payload/scripts/lib/run.sh:1-25; commits a692fe5, 3bc39c2 | `bundle/policies/commit_evidence.py` reads plan state itself (the only policy that does). Its notion of "open run" must agree with `active_run`'s predicate or the mediator and the plugin disagree about whether a run exists | omni:bundle/policies/commit_evidence.py |
| 7 | **`scripts/lib/loader.sh` — the loader idiom v2** | A byte-identical block in 21 hooks: three candidate classes (beside the hook, the marketplace source path read from the registry by the installed marketplace name, the newest cache version by three-integer compare), two fail policies (open for advisory hooks, closed with a four-command repair allowlist for walls); pinned by cross-gate §N.1 | payload/scripts/lib/loader.sh:1-25; hooks/engage.sh:82-208; commit dda565a | The binding's hooks source nothing by design (R16, `omni:bindings/claude/hooks/landing.sh:16-18`), so they are unaffected. Any omni hook hunk ported onto a bionic hook inherits the block; a hook the adapter ships into `hooks/` without it fails cross-gate §N.1. Omni's `hooks/` directory has none of the 21 blocks (its hooks predate the idiom) | omni:hooks/ (listing: no engage.sh, no session-start.sh) |
| 8 | **`scripts/lib/worktree.sh` — the lease; `.bionic` symlink retired** | A spawned worktree is a leased slot bound to a ledger row; `land` = merge, remove, prune, never `--force`; the `<worktree>/.bionic -> <main>/.bionic` symlink is no longer planted, `project_root` maps the tree instead; legacy links are listed and deleted on teardown | payload/scripts/lib/worktree.sh:1-25; commits 60d0abb, 94e179e, 1abbd53 | Omni's `spawn-worktree.sh` still plants the symlink (`ln -s "${main_root}/.bionic" "${wt}/.bionic"`); `session-start.sh` reports every such link as legacy on the next start. The binding's `landing.sh` already reads the roster through the common dir, so it needs no link | omni:payload/scripts/spawn-worktree.sh:31, :177, :224; hooks/session-start.sh:368-374 |
| 9 | **`scripts/lib/resources.sh` + `parallel-budget:`** | Machine probe, budget (memory hard, compute soft), pressure; Step 0 records one `parallel-budget:` string in plan frontmatter; the preflight attestation v2 carries it; dispatch-preflight has a budget arm and a lease wall (a main-thread dispatch from a linked-worktree cwd is refused); the survival block tells writers to export `BIONIC_TEST_JOBS` from the brief | payload/scripts/lib/resources.sh:1-25; skills/canonical-sdlc/SKILL.md:157; agents-src/blocks/survival.md:37-42; commits a7feb02, 32ee917, 49cea8e | `bundle/config.yaml`'s roster carries harness/model/effort per role and no budget; `dispatch_convert.py` has no width arm, so an omnigent wave's fan-out is unbounded by the budget the plan records. The lease wall's "cwd is a linked worktree" refusal applies to whatever cwd the orchestrator seat runs in | omni:bundle/config.yaml (params.roster); omni:bundle/policies/dispatch_convert.py |
| 10 | **Patrol tick decisions and duties** | The tick decides FILL / HOLD / NARROW / EMERGENCY; QUIET before the first dispatch; a printed FILL is a duty the Stop gate reads; CronList-first after a `/clear`/resume marker; one clock per run is a wall (a second stamp is a finding); staleness = interval × `PATROL_STALE_MULTIPLIER`; the tick walks worktree leases and NOTIFYs an overrun | commits 8ec9654, e39eebc, 45112fc, c3b34e2, 67dd659, cf37da0 | `bundle/policies/duties_on_tick.py` and the launcher's pulser (`pulse: {period_s: 900, decay_periods: 2}`) implement a different tick vocabulary. Either the adapter mirrors the four decisions or the omnigent orchestrator's duties diverge from the plugin's | omni:bundle/config.yaml (params.pulse); omni:bundle/policies/duties_on_tick.py; omni:bindings/claude/launch.sh (pulse_loop) |
| 11 | **`payload/scripts/lib/detect.sh` — marketplace name, semver, one rc resolver, staleness constant** | Feed kind keyed on the installed plugin's marketplace name (a fork registered as `bionic@my-fork` works); version compare is three-integer, `ahead` is not lag; `shell.sh` is the one rc-file resolver | commits cdc1fa3, 374185d, 9c2e5cc, cf37da0 | D1 (Table 1b) conflicts on the key; the shim resolves the plugin root by `split("@")[0] == "bionic"` (`omni:bindings/claude/shim/claude:287`), the same fork-blind idiom bionic retired | omni:bindings/claude/shim/claude:273-287 |
| 12 | **`agents-src/blocks/survival.md` additions; `critic.md.tmpl`** | Two additions render into all six role files: the `BIONIC_TEST_JOBS` bullet and the "`/clear` does not kill agents" paragraph naming `session-poker.sh adopt`; the critic template's agreement-test exemplar now names cross-gate §N.1 instead of the deleted `tests/scripts.test.sh` | agents-src/blocks/survival.md:37-51; agents-src/templates/critic.md.tmpl (9 insertions) | The adapter's `seat-prompt.md` bodies render from the same sources, so a re-render carries both paragraphs into every seat; the `/clear` paragraph is Claude-plugin vocabulary (adopt verb, teammate names) that means nothing to an omnigent seat, so it needs the A1 substitution pattern applied in reverse: the adapter substitutes, the core keeps its wording | omni:agents-src/render.sh:706-717 |
| 13 | **`hooks/hooks.json` events** | New registrations: PreToolUse `Skill` (engage), `UserPromptExpansion` (engage), `SessionStart` (session-start); doctor has a restart-needed row for a CLI process older than `hooks.json` | hooks/hooks.json; commit cbbdd99 | The binding's own `hooks.json` registers Stop/SubagentStop only and coexists; the shim's settings merge (`omni:bindings/claude/shim/claude:797-806`) adds entries by command string, so it will not duplicate the plugin's | omni:bindings/claude/hooks/hooks.json |
| 14 | **Version and the skill's predicate text** | plugin 1.4.1; `SKILL.md` §Hooks describes the two-fact predicate (engaged, then active_run) and the Patrol paragraph reads from `hooks.json` + `engage.sh` | payload/.claude-plugin/plugin.json:3; skills/canonical-sdlc/SKILL.md:462-469; commit 5986680 | Omni's payload is 1.3.5 with the pre-1.4.0 skill text and hooks frontmatter; the shim binds to whichever bionic the CLI registry names, so the adapter's assumptions must target 1.4.1 semantics, not its own payload | omni:payload/.claude-plugin/plugin.json:3; omni:skills/canonical-sdlc/SKILL.md:1-66 |

---

## Table 3 — `.claude/rules/*.md`, paragraph by paragraph

Categories: **repo** = repo-development guidance (a contributor guide; every consumer has one,
not a taint) · **core** = bionic operating behaviour (help the dogfood has and the product
does not, unless shipped) · **adapter** = harness-specific → the Claude adapter ·
**personal** = Chris's preference, not the repo's. For each core paragraph: the destination
channel, and whether one exists today. Shipped channels: `agents-src/blocks/` → `agents/*.md`
(dispatched agents, next session); `skills/*/SKILL.md` (whoever invokes the skill, on
invocation); a hook's stdout (SessionStart text lands in the orchestrator's context). There
is **no ambient orchestrator channel**: nothing the plugin ships reaches the orchestrator
before it invokes a skill.

### `agent-discipline.md` (paths `**/*.sh`, `**/*.md`) — 18 paragraphs

| # | lines | paragraph (gist) | sort | prior sort | destination / channel |
|---|---|---|---|---|---|
| AD1 | 9-11 | file's own provenance (migrated from `.bionic/memory/agent-rules.md`) | repo | (unsorted) | stays; confirms |
| AD2 | 13-23 | routing note: which channels measured to reach a dispatched subagent (rules file yes, role file yes-but-next-session, project CLAUDE.md absent, auto-memory unreliable) | repo (a harness measurement that explains this file) | (unsorted) | stays as CONTRIBUTING; the measurement itself is the evidence behind the map's fog entry |
| AD3 | 25-28 | the globs are deliberately broad; pay-per-read | repo | (unsorted) | stays |
| AD4 | 32-33 | **Mechanics:** re-read code after editing | **core** (implementor behaviour, harness-neutral) | repo — **refuted** | `agents-src/blocks/` (implementor + senior-implementor); not there today (0 hits for "re-read" in blocks/templates) |
| AD5 | 35-41 | **Mechanics:** a refactor must discover ALL test suites; in this repo `tests/run.sh` derives its roster from `tests/*.test.sh` at run time (fixit 1.5.1) | split: rule = **core**, example = repo | repo — **partly refuted** | rule → `agents-src/blocks/` (implementor); the derived-roster fact stays in `test-harness.md`. Not shipped today (0 hits) |
| AD6 | 45-50 | **Discourse:** instruction files for Claude: failure-mode sentences are triggers, not elaboration | repo (authoring guide for skills/agents/rules in this repo) | core — **refuted** | stays; it governs how this repo's instruction files are written, which is contributor work |
| AD7 | 52-57 | **Discourse:** on "is this idea good?", evaluate the literal proposal before reframing | **personal** (how Chris wants design conversation to go), orchestrator-facing | core — **refuted** | not the repo's; the auto-memory record already carries it (`plain-english-means-concrete`, `dont-reask-settled-direction`) |
| AD8 | 59-65 | **Discourse:** agent "the docs explicitly state X" quotes are leads, not facts; verify against the primary source | **core**, orchestrator-facing | core — confirmed | **no shipped channel.** Closest surface: `SKILL.md` §Dispatch (0 hits for "primary source"/"leads"). This is the admission rule's "read from primary surfaces, never self-report" in orchestrator form; candidate for P1 |
| AD9 | 69-73 | **Subagent dispatch:** moved-note; foreground-first and poll-don't-watch now in `survival.md`; "what stays below is addressed to whoever writes the brief, which no role file can reach" | repo (provenance), and the sentence that names the hole | (unsorted) | stays; it is the clearest statement in the tree that the orchestrator channel is missing |
| AD10 | 75-82 | **Subagent dispatch:** backgrounding gets DECLARED in the brief (`claims=` + output file) | **core**, orchestrator-facing | core — confirmed | **no shipped channel.** `SKILL.md` has 0 hits for `claims=`; the roster/landing verdict reads the row but nothing shipped tells the brief writer to declare it |
| AD11 | 84-91 | **Subagent dispatch:** normative values ship as VERBATIM tables in briefs; grep every artifact that restates a corrected value | **core**, orchestrator-facing | core — confirmed | **partly shipped**: `SKILL.md` carries "verbatim" for the auditor mandate and the critic template (:369, :543) and the rendered role files say "verbatim" 7 times, but the general rule (any normative value → verbatim table) and its corollary (grep restatements) appear nowhere shipped |
| AD12 | 93-107 | **Subagent dispatch:** idle agents: one demand-ping for readers, tree-verification for writers, never ping a writer; check for a duplicate session first | **core**, orchestrator-facing; the mechanism (SendMessage, `git status`) is Claude-harness vocabulary | core — confirmed | **no shipped channel** for the orchestrator (1 hit in blocks is the agent-side "do not go idle", not the orchestrator's response rule). 1.4.0's `adopt` verb and transcript-mtime liveness (`e023093`) mechanise the reader half; the writer half is prose only |
| AD13 | 109-118 | **Subagent dispatch:** `CLAUDE_CODE_FORK_SUBAGENT=1` does not enable fork inheritance (2026-04-25) | **adapter**, and stale | core (by section) — **refuted** | Claude-harness fact, dated; the current harness ships `subagent_type: "fork"` with full-context inheritance, so the paragraph is refuted by the platform. Retire; if anything survives it is the Claude adapter's note |
| AD14 | 120-131 | **Subagent dispatch:** multi-iteration excalidraw authoring is dispatched, not done on the main thread; fresh-with-brief beats fork | **core**, orchestrator-facing, skill-specific | core (by section) — confirmed with a home | **shipped channel exists**: `payload/skills/excalidraw-diagram/` ships with the plugin; the rule belongs in that SKILL.md's own text, which is read at invocation |
| AD15 | 135-139 | **Skill-creator pitfalls:** `improve_description.py` is not standalone; UUID-suffixed command files need cleanup | repo (tooling trap for skill authors) | repo — confirmed | stays |
| AD16 | 143-145 | **Skill precedence:** prefer `idea-refine` over `brainstorming` | **personal** | personal — confirmed | not the repo's. Note `SKILL.md` already routes Step 1 through `agent-skills:idea-refine` (`needs:` list, 2 hits), so the product encodes the preference where it matters and the paragraph is Chris's standing order for everything else |
| AD17 | 147-153 | **Skill precedence:** design work routes to `impeccable` only; two plugins evaluated and removed | **personal** | personal — confirmed | not the repo's (`SKILL.md` mentions `impeccable` twice as the design route; the removal history is Chris's machine) |
| AD18 | 155-162 | **`/clear` does not kill agents**: rosters stay on disk, `adopt` reads them back, bare teammate name is the surviving address, re-dispatch waits for adopt's verdict | **core**, orchestrator-facing | core — confirmed, "no channel" — **refuted** | **shipped twice already**: verbatim in `agents-src/blocks/survival.md:44-51` (every role file) and mechanised by `hooks/session-start.sh`, whose stdout puts predecessor rosters and the re-arm order into the orchestrator's context on every `clear`/`resume`. The rules-file copy is now the third rendering of one text with no agreement test |

**agent-discipline tally:** repo 6 (AD1, AD2, AD3, AD6, AD9, AD15) · core 8 (AD4, AD5-rule,
AD8, AD10, AD11, AD12, AD14, AD18) · adapter 1 (AD13, stale) · personal 3 (AD7, AD16, AD17).
Of the 8 core: 2 are implementor-facing with a shipped channel not yet used (AD4, AD5 →
`agents-src/blocks/`); 1 has a shipped skill home (AD14); 1 is already shipped twice (AD18);
**4 are orchestrator-facing with no shipped channel (AD8, AD10, AD11, AD12)**, AD11 partly.

### `git-worktree-docs.md` (paths `.bionic/docs/**`, `.worktrees/**`) — 5 paragraphs

| # | lines | paragraph (gist) | sort | prior sort | destination / channel |
|---|---|---|---|---|---|
| GW1 | 9-10 | provenance | repo | pure repo — confirmed | stays |
| GW2 | 14-18 | root `docs/` deleted 2026-07-16; superpowers wanting `docs/superpowers/` is redirected to `.bionic/docs/` (canonical-sdlc layout); never commit plan/spec artifacts | split: history = repo; the redirect and the never-commit rule = **core** | pure repo — **partly refuted** | `superpowers` is a declared plugin dependency (`payload/.claude-plugin/plugin.json:9`), so every consumer hits the same redirect. `SKILL.md` §Artifact layout (:95) states the layout; the explicit "redirect superpowers" sentence has 0 hits shipped. Orchestrator-facing; channel = `SKILL.md` |
| GW3 | 20-26 | canonical-sdlc artifacts live in `.bionic/docs/{specs,plans,adrs,incidents}/epic-NN-<slug>/`; evidence gate descends 2 levels; governing-skill enforces frontmatter | **core**, already shipped | pure repo — **refuted** | `SKILL.md` §Artifact layout and both hooks enforce it; the paragraph is a restatement, safe to leave or drop |
| GW4 | 28-33 | operational record under `.bionic/docs/record/`, `ideas/`; nothing loads it unprompted | **core**, already shipped | pure repo — **refuted** | `SKILL.md` has 10 hits for `record/`; shipped |
| GW5 | 37-44 | `git worktree add` resolves relative paths against pwd; nested-worktree trap | repo (generic git trap), largely superseded by `spawn-worktree.sh` + `lib/worktree.sh` | pure repo — confirmed | stays as a contributor trap; the product path no longer hand-types `git worktree add` |

### `hook-authoring.md` (paths `hooks/*.sh`) — 13 paragraphs

All 13 are addressed to someone editing a hook in this repo: registration coverage (lines
13-37), diagram policy (39-42), git ARGV parsing (46-53), `git show -m` (55-62), the retired
plan-format trap (66-73), MCP dependency roster (77-93), refusal voices (97-104),
run-state discriminators (108-121), `set -u` (125-144), CR-only endings (146-156), awk
apostrophes (158-164). **repo, all 13 — prior sort confirmed.** Two paragraphs *describe*
core behaviour (ARGV parsing at 46-53; the `hooks.json`-only channel at 30) but as facts a
hook author needs, which is what a contributor guide is.

### `test-harness.md` (paths `tests/*.sh`) — 5 paragraphs

Provenance (8-12), the two `installer-behavior` gotchas (14-22), `bash tests/run.sh` is the
gate with a green run saying nothing about the hooks a session loads (24-34), nothing is
auto-discovered (36-41). **repo, all 5 — prior sort confirmed.** Paragraph 4's second half
(the tree's hooks vs the payload the CLI resolved) is the memory `repo-hooks-vs-installed-hooks`
in contributor form.

### Table 3 summary

| file | paragraphs | repo | core | adapter | personal | prior sort |
|---|---|---|---|---|---|---|
| agent-discipline.md | 18 | 6 | 8 | 1 | 3 | half right: sections do not sort as units |
| git-worktree-docs.md | 5 | 2 (+1 split) | 3 (2 already shipped) | 0 | 0 | "pure repo" refuted for 3 of 5 |
| hook-authoring.md | 13 | 13 | 0 | 0 | 0 | confirmed |
| test-harness.md | 5 | 5 | 0 | 0 | 0 | confirmed |
| **total** | **41** | **26** | **11** | **1** | **3** | |

Of the 11 core paragraphs: 3 already shipped (AD18, GW3, GW4); 2 have a shipped channel not
yet used (AD4, AD5 → `agents-src/blocks/`); 1 has a shipped skill home (AD14); **5 are
orchestrator-facing with no shipped channel** (AD8, AD10, AD11, AD12, GW2). The "done when"
test in the fog entry (a fresh clone with only the plugin gets every behavioural rule a
bionic developer gets) fails today on exactly those five plus AD4/AD5, and passes on the rest.

---

## What this means for the map

**Fog that sharpened.**

- *Is the 1.4.1 engagement marker the right session-scoping mechanism for omnigent seats?*
  Facts (Table 2 row 1): no seat engages by construction; walls in worker seats are silent
  under 1.4.1 and were held at the mediator anyway; the orchestrator seat engages only by
  invoking the skill. The decision is whether "engaged" is a per-session act the orchestrator
  seat performs (as now) or a per-run fact the adapter writes at launch. That belongs in G1.
- *Tainted dogfooding.* Sharpened to a list: five orchestrator-facing paragraphs without a
  channel (AD8, AD10, AD11, AD12, GW2), two implementor paragraphs with an unused channel
  (AD4, AD5), one with a skill home (AD14), three already shipped (AD18, GW3, GW4), one stale
  harness note to retire (AD13), three personal preferences to move out (AD7, AD16, AD17).
  Everything else reads as CONTRIBUTING to an outsider. G3 decides the orchestrator channel;
  the rest can move now.

**Tickets the ledger suggests.**

1. **Roster-window port** (keep cluster H1–H5 + P1–P5 + T1/T4/T8): the false alarm doctor
   still raises; one wave-sized change with the agreement test attached. Task, not research.
2. **Shim re-derivation** (Table 2 row 2): the adapter cannot launch a seat against the
   installed plugin. Blocks any measurement on omnigent until fixed; belongs in G1's
   migration wave, or as an in-flight repair in bionic-omni if a measurement is needed sooner.
3. **A drill for the Claude plugin** (Table 1d B4): rung 4 ("walls refuse, drill-proven") has
   an instrument on omnigent and none on the plugin; the plugin's walls are proven by hermetic
   suites that drive hook payloads, never by a seat issuing the violation. The ladder cannot
   be climbed once per vendor on equal footing until this exists. Fog for G2.
4. **Worker containment decision** (A2–A5): `disallowedTools: Agent, Task` on the four worker
   roles is a keep that changes behaviour; needs Chris's yes.
5. **Test roster shape for a monorepo** (Table 1d runner note): pytest and the drill have no
   slot; G1's layout decision should say where the adapter's tests run.

**Out of scope, noted.** The six `discard` rows all die with omnigent 0.12.0's `instructions:`
channel or bionic's `hooks.json` registration; nothing discarded carries an idea the keeps do
not already hold.
