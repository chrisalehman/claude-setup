---
paths:
  - "hooks/*.sh"
---

# Hook authoring

Anchors for the recurring traps when changing hooks in `bionic/hooks/`. Migrated from
`.bionic/memory/hooks-rules.md` (epic-12 wave-01 slice 6) with the correction ledger applied.

## Registration

*(The `MANAGED_HOOKS` clause retired here at epic-17 W5, 4/8. Its own staleness notice
named the trigger — W5's deletion of `claude-bootstrap.sh` — and that fired in 4/6. The
array described how the installer copied a hook into the machine's own hooks directory;
the payload's `hooks/hooks.json`, live since W3, is the whole story now. The rest of this
section, and of this file, was never bootstrap-era and is unchanged.)*

- **STALE-CORRECTED 2026-07-20 (wave-02): there is NO CI — `.github/workflows/` does not
  exist** (CI excised 2026-06-27, "no CI by design"; the old file-listed ci.yml rule is dead).
  *(Corrected again 2026-08-18, epic-17 W4: the glob this bullet described is gone. S9 moved
  the hook tests out of `hooks/` into `tests/` and retired the `hooks/*.test.sh` glob-pick;
  `tests/run.sh` now derives its roster from `tests/*.test.sh` at run time, fixit 1.5.1.)* Registration
  coverage for a new hook is partly structural and partly manual. Structural:
  `tests/scripts.test.sh` 4a/4b/4c used to enforce hook↔test pairing and — for an always-on
  wall — that every command in the payload's `hooks/hooks.json` names a file that exists and is
  rooted at `${CLAUDE_PLUGIN_ROOT}`. That suite was deleted at 8582861 (epic-18 wave-03) and
  nothing replaced either wall — both are logged debt now. Gating is not manual any more:
  `tests/run.sh` derives its roster from `tests/*.test.sh` at run time (fixit 1.5.1, D-1:
  location is the declaration), and an adoption wall refuses, before any suite runs, a file in
  that glob that is not a suite (a `#!/bin/bash` first line and `tests/lib/assert.sh` sourced).
  **Adding a hook = source file + `.test.sh` sibling + a registration (`hooks/hooks.json` — the
  only channel since bionic 1.4.0: every hook is registered there once and scopes itself by the
  on-disk open-run predicate `active_run`; the skill frontmatter carries no `hooks:` block any
  more, and a hook registered only there would arm nothing).** The sibling gates the moment it
  lands in `tests/`; there is no `run` line to add and no self-registration pin to write — the
  harness proves its own completeness once, in `tests/runner-roster.test.sh` (D-3), and a
  suite never names the runner.

- **Architecture diagram policy: composed SVG, not hand-drawn.** The current diagrams
  (`skills/canonical-sdlc/diagrams/lifecycle.svg`, `diagrams/hook-chain.svg`) are each their
  own sole source — hand-composed text, no paired drawing file — so install-layer changes
  (new hooks, new install types, new managed files) are edits to the SVG text itself.

## False-positives and merge-commit handling

- **`protect-main.sh` and the evidence gate read git ARGV, not text** (bionic 1.3.2,
  wave-01-dogfood-fixes B-3). Both source `scripts/lib/git-argv.sh`: leading `VAR=value`
  assignments and git's global options (`-C <dir>`, `-c k=v`, `--no-pager`, …) are skipped
  before the subcommand is read, refspec DESTINATIONS are parsed (`HEAD:refs/heads/main`,
  `:main`, `+main`, quoted forms), and heredoc bodies and quoted strings never match. The
  old `GIT_VAR=... git commit` false positive and its `env` workaround are gone with the
  regexes that caused them. A hook that cannot load the library REFUSES, naming the path —
  never silently allows; `tests/git-argv.test.sh` proves that by renaming the library away.

- **Any hook inspecting HEAD's file list must use `git show -m --name-only --format= HEAD`**,
  not `git show --name-only --pretty=format: HEAD`. Without `-m`, a clean merge commit (no
  conflicts) emits zero output — git's default "combined diff" format is empty unless parents
  diverged with conflicts. Filters/guards that check "is this commit's file set all under X"
  then silently misclassify the merge as empty/matching and falsely skip. Caught 2026-04-16 by
  a Phase 8b adversarial critic on the (since-retired 2026-05-10) `memory-commit-save.sh`
  circular guard; fixed with `-m` before merge. Lesson generalizes to any future
  HEAD-inspecting hook.

## Plan-format-documenting-doc trap — RETIRED 2026-07-19

- **RETIRED (epic-07 wave 2):** the evidence-gate's `## SDLC State` parsing is now fence-aware
  on every read path (extraction, presence check, `## Tasks`, epic-plan merge-target read;
  matrix was fixed earlier in `2766364`). Fenced examples are documentation, invisible to
  parsing; a fenced-ONLY `## SDLC State` means the file passes through as non-canonical. The
  old `touch <real-plan>` workaround is obsolete. Regression tests 19o/19p/19q/19r pin the
  class. Origin: the trap's live recurrence false-blocked wave-2's own first commit (the plan's
  fenced D12 schema example shadowed the real section) — fixed at the root instead of
  re-worked-around.

## MCP dependencies in skills

- **`addy-agent-skills` ships skills with implicit MCP dependencies that the plugin metadata
  does not declare.** Confirmed 2026-04-26 with `browser-testing-with-devtools/SKILL.md`
  (assumes a `chrome-devtools` MCP server is configured; bionic ships
  `chrome-devtools-mcp@latest` as a when-needed row in `payload/scripts/lib/deps.sh` to satisfy it). When installing or
  upgrading the `addy-agent-skills` plugin, grep its skill files for MCP server references
  (`mcpServers`, `mcp__`, "MCP server") and ensure each referenced server has a row in
  `payload/scripts/lib/deps.sh`, with its consumer named. Note also: that same SKILL.md references
  `@anthropic/chrome-devtools-mcp` — wrong package; the real npm name is `chrome-devtools-mcp`.
  Don't copy the bad name from the skill. **Update 2026-06-14:** canonical-sdlc Step 5 no
  longer *mandates* `browser-testing-with-devtools`/chrome-devtools MCP for routine browser
  verify — it now routes to the bionic-owned `browser-verify` skill, which drives via
  `playwright-cli` (CLI-first). The chrome-devtools MCP stays installed but is reserved as the
  deep-debug escalation only (Lighthouse, perf-trace analysis, profiling, network throttling).
  The MCP remains a real dependency — keep its row in `deps.sh`; `tests/plugin-lib.test.sh`
  used to pin the table (deleted at 8582861, epic-18 wave-03; nothing replaced the pin).
  *(Corrected 2026-08-20, epic-17 W6 S3b: `claude-config.txt` and
  `tests/scripts.test.sh` §3 are gone — the dependency roster has one owner.)*

## Refusal voices

- **Two refusal voices coexist; copy the one your hook's family uses.** `BLOCKED` is the
  wall voice — evidence-gate, governing-skill, preflight-probe, protect-database: a write,
  commit, or subagent start is refused fail-closed and the fix is named in the same message.
  `checkpoint:` is the dispatch-discipline voice — farm-out-reminder and dispatch-preflight
  (the Patrol arming wall speaks it even when it refuses). A new wall over an artifact or a
  tool call copies `BLOCKED`; a new main-thread/dispatch gate copies `checkpoint:`. This is
  a naming convention, not a mechanism — nothing parses either word. *(Added 2026-08-20,
  epic-17 W6, discharging W5's trigger-armed note "which refusal voice to copy".)*

## Discriminators in enforcement hooks

- **Enforcement hooks must discriminate by run-state marker, not by artifact-author field.**
  When a skill delegates artifact production to other skills (canonical-sdlc Step 3 →
  `superpowers:writing-plans`), the artifact correctly declares the *producer* via
  `governing-skill:`. Gating enforcement on `governing-skill: <self-skill>` makes the hook
  invisible to the artifacts the lifecycle itself produces. Use a separate state-marker field
  that the lifecycle stamps independently — canonical-sdlc uses `canonical_sdlc_version:`, set
  by Step 0. *(Correction 2026-07-27: the original text cited the then-current value
  `canonical_sdlc_version: 3`. The mechanism is live and unchanged; the supported value is now
  **12** — both hooks pin `SUPPORTED_SDLC_VERSION=12` and block loudly on anything else.)*
  *(Correction 2026-09-07, epic-21 wave-02 S12: the supported value moved again without this
  file following — it is now **14**. Read the live value from the source, not this paragraph:
  `tests/cross-gate-agreement.test.sh` §V pins both hooks, `operational-rules.md`, and both
  diagram SVGs against `canonical-sdlc-evidence-gate.sh`'s copy, with a mutation arm — this is
  exactly the drift that section exists to catch, demonstrated on this very file.)*
  Caught 2026-05-04 in the canonical-sdlc dispatch-gate + governing-skill hooks: every Step 3
  plan declared `governing-skill: superpowers:writing-plans`, both hooks early-returned, and
  `dispatch_enforce: true` was a no-op for the entire epic. Dispatch-gate hook retired
  2026-05-10 (too brittle); the governing-skill hook still uses the version-marker pattern.
  Generalizes to every skill with a multi-skill lifecycle that ships its own enforcement hooks.

## `set -u` and conditionally-bound variables

- **These hooks run `set -u`; a guard that references a variable bound on only SOME code paths
  crashes with "unbound variable" on the others.** Both
  `canonical-sdlc-{governing-skill,evidence-gate}.sh` run `set -u`. Caught 2026-07-20
  (bugfix·tested·task): adding `[ "$SCALE" != "task" ]` to the shared matrix-required block
  tripped `SCALE: unbound variable`, because `SCALE=$(yaml_get scale)` was assigned only inside
  one version arm while the shared block was reachable from another. Fix: read the var
  UNCONDITIONALLY near the other globals so it is `""` on every path — not `${SCALE:-}`
  scattered at each use. That fix is what the code does today: one unconditional line,
  `INTENT=$(yaml_get intent); RIGOR=$(yaml_get rigor); SCALE=$(yaml_get scale)`.

  *(Correction 2026-07-27: the original text described the bug in terms of "the v10-autonomous
  path" versus "the v11 arm", and prescribed mirroring a `MODE=$(yaml_get mode)` read. **Those
  version arms no longer exist** — v12 deleted all backward compatibility — and `mode:` is now
  a hard block, not a variable to mirror. Don't go looking for either. The rule survives on its
  own terms: whenever you add a guard on a variable, grep for its assignment and confirm every
  reaching path sets it.)*

  **What surfaced it: cross-version test coverage** — a suite that only exercised the arm being
  edited would have shipped the crash. With the version ladder gone, the equivalent discipline
  is to exercise every branch that reaches the shared block, not only the one you touched.

- **CR-only (classic-Mac `\r`) line endings: normalize by TRANSLATING `\r`→`\n`, never
  `tr -d '\r'` (delete).** `tr -d '\r'` handles CRLF (`\r\n`→`\n`) but on a CR-only file
  DELETES the sole line separators, collapsing the whole file to ONE line — line-anchored
  parsers (`$0 == "---"`, `^## SDLC State`, matrix grep) then mis-fire. In the evidence gate
  that was a fail-DANGEROUS silent bypass (every commit passed ungated, fixed wave-04
  `b1765c2`); the same `tr -d` in governing-skill was fail-SAFE (valid artifacts false-blocked,
  fixed 2026-07-20 `c191e71`). Canonical transform, used by both hooks now:
  `awk '{ sub(/\r$/, ""); gsub(/\r/, "\n"); print }'` (evidence-gate wraps it as
  `normalize_newlines()` reading a file; governing-skill pipes `$CONTENT` through it).
  CRLF-only test coverage does NOT catch this — add an explicit CR-only case
  (LF→`tr '\n' '\r'`).

- **No apostrophes anywhere inside a single-quoted awk program — comments included**
  (2026-08-08, epic-16 w1). The big awk blocks (e.g. dispatch-preflight's label grammar)
  are single shell-quoted strings; an apostrophe in an awk-side comment terminates the
  shell quote and cascades into ~100 unrelated suite failures. Hit twice in one slice by
  the same agent, both times in a comment, both caught by `bash -n` before commit. Rule:
  `bash -n <hook>` after ANY edit near an awk block, and reword comments rather than
  escaping ("it's" → "it is").
