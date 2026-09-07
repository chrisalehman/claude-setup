---
name: excalidraw-diagram
description: Create Excalidraw diagram JSON files that make visual arguments. Use when the user wants to visualize workflows, architectures, or concepts.
---

# Excalidraw Diagram Creator

> **VENDORED FORK — do not re-clone upstream.** This is a fork of `coleam00/excalidraw-diagram-skill`, which is unmaintained (2 commits) and broken: it imports `@excalidraw/excalidraw?bundle` **unpinned** from esm.sh, whose transitive-dep resolution drifted and now 404s `@braintree/sanitize-url` `constants.mjs` — so the renderer fails on every diagram. Upstream HEAD is still unpinned and won't be fixed.
> **The fix is a version pin at `references/render_template.html:16` (`@excalidraw/excalidraw@0.18.0`).** Bump it deliberately, and verify a real render before trusting a new version. Installing this skill from upstream reinstates the breakage.
> **This skill ships with bionic.** Installing the plugin installs it — there is nothing to copy and no directory to place. What does NOT arrive with it is the renderer: the browser and the Python environment it drives are `when-needed` dependency rows, offered once, on consent, the first time a diagram is actually rendered.

Generate `.excalidraw` JSON files that **argue visually**, not just display information.

**Setup:** nothing to do up front — see Render & Validate below for how the renderer arms itself.

---

## Core Thesis

**Diagrams should ARGUE, not DISPLAY.** A diagram isn't formatted text — it's a visual argument showing relationships, causality, and flow that words alone can't express. The shape should BE the meaning, so let each concept's visual pattern mirror its behavior (fan-out for one-to-many, timeline for a sequence, convergence for aggregation).

- **The Isomorphism Test**: if you removed all text, would the structure alone communicate the concept? If not, redesign.
- **The Education Test**: could someone learn something concrete from this, or does it just label boxes? A good diagram shows actual formats, real event names, concrete examples.

---

## Depth Assessment (Do This First)

**Simple/Conceptual** — use abstract shapes when explaining a mental model or philosophy, when the audience doesn't need technical specifics, or when the concept IS the abstraction (e.g. "separation of concerns").

**Comprehensive/Technical** — use concrete examples when diagramming a real system, protocol, or architecture; when the diagram will teach or explain; when the audience needs to know what things actually look like; or when showing how multiple technologies integrate.

**For technical diagrams you MUST research the actual specs first and include evidence artifacts** — real code snippets, real JSON/data payloads, real event names, real method names and endpoints from the docs. Labelled boxes are not evidence.

- Bad: "Protocol" → "Frontend"
- Good: "AG-UI streams events (RUN_STARTED, STATE_DELTA, A2UI_UPDATE)" → "CopilotKit renders via createA2UIMessageRenderer()"

Show what things actually look like, not just what they're called.

---

## References

- `references/color-palette.md` — **single source of truth for all colors**: semantic shape fills/strokes, text hierarchy colors, evidence-artifact colors. Read it before generating any diagram; don't invent colors. Edit this one file to rebrand the skill.
- `references/element-templates.md` — copy-paste JSON templates per element type (text, line, dot, rectangle, arrow); pull colors from the palette.
- `references/json-schema.md` — Excalidraw JSON format reference: element types and their properties.

---

## Render & Validate (MANDATORY)

You cannot judge a diagram from JSON alone. After generating or editing the Excalidraw JSON, you MUST render it to PNG, view the image, and fix what you see — in a loop until it's right. This is a core part of the workflow, not a final check.

### How to Render

```bash
XR=${CLAUDE_PLUGIN_ROOT}/skills/excalidraw-diagram/references
uv run --project "$XR" python "$XR/render_excalidraw.py" <path-to-file.excalidraw>
```

`--project` rather than a `cd`: it points uv at the environment without moving you out of the
directory your `.excalidraw` file is in, so the path you pass stays the path you typed. The
script resolves its own HTML template beside itself, so nothing else depends on the cwd.

Three of bionic's dependency-table rows stand behind that line: `uv` itself, the `excalidraw-renderer` project environment `uv sync` builds, and the `playwright-chromium` browser it drives. Before assuming any of them, detect absence with `jit_check` and, on absence, offer a consented install with `jit_offer` (`payload/scripts/lib/jit.sh`) — a decline degrades to "render is unavailable until installed," never a cryptic failure.

This outputs a PNG next to the `.excalidraw` file. Then use the **Read tool** on the PNG to actually view it.

### The Loop

**1. Render & View** — Run the render script, then Read the PNG.

**2. Audit against your original vision** — before hunting bugs, compare the render to what you designed: does the visual structure match the conceptual structure? Does each section use the pattern you intended? Does the eye flow in the order you designed? Is hierarchy correct (hero elements dominant)? For technical diagrams, are the evidence artifacts readable and properly placed?

**3. Check for visual defects:**
- Text clipped by or overflowing its container
- Text or shapes overlapping other elements
- Arrows crossing through elements instead of routing around them
- Arrows landing on the wrong element or pointing into empty space
- Labels floating ambiguously (not clearly anchored to what they describe)
- Uneven spacing between elements that should be evenly spaced
- Sections with too much whitespace next to sections that are too cramped
- Text too small to read at the rendered size
- Overall composition feels lopsided or unbalanced

**4. Fix** — edit the JSON to address everything found. Common fixes: widen containers when text is clipped; adjust `x`/`y` to fix spacing and alignment; add intermediate waypoints to arrow `points` arrays to route around elements; reposition labels closer to what they describe; resize elements to rebalance visual weight.

**5. Re-render & re-view** — run the render script again and Read the new PNG.

**6. Repeat** — keep cycling until the diagram passes both the vision check (2) and the defect check (3). Typically 2-4 iterations. Don't stop after one pass just because there are no critical bugs — if the composition could be better, improve it.

**Multi-iteration authoring should be dispatched, not done on the main thread.** This render → Read PNG → fix-JSON → re-render loop (typically 2–4 iterations per diagram) adds a multi-hundred-KB PNG read to context on every pass plus a JSON edit cycle. Dispatching keeps the main thread clean and returns a single completion notification. Validated 2026-05-03: two diagrams dispatched in parallel, ~7 and ~12 minutes each, returned final paths + judgment-call summaries. *(2026-07-15 amendment: a FRESH `model: opus` agent with a fully self-contained brief — target files, content spec, render-loop instruction, known CDN-drift fix — is a validated, cheaper alternative to a fork; a two-diagram regen delivered in 1–2 iterations per diagram this way. Prefer fresh-with-brief under a Fable orchestrator, where forks cost ~2× Opus and re-pay the whole main context.)* The pattern generalizes to any visual-validation work where the "did the rendered output match my intent" judgment requires reading the rendered artifact.

### When to Stop

The loop is done when the rendered diagram matches the conceptual design; no text is clipped, overlapping, or unreadable; arrows route cleanly and connect to the right elements; spacing is consistent and the composition balanced; and you'd be comfortable showing it to someone without caveats.

### First-Time Setup
There is no manual setup step. The first render on a machine finds `excalidraw-renderer`
absent and offers the `uv sync` that builds it, and finds `playwright-chromium` absent and
offers the browser download — one consented question each, through `jit_offer`. Say yes and
the render proceeds; say no and this route reports that rendering is unavailable rather than
failing somewhere inside the script.

---

## Quality Checklist

1. **Evidence**: technical diagrams show real code/JSON/event names from actual specs, not labelled boxes.
2. **Isomorphism**: each visual structure mirrors its concept's behavior; structure alone carries meaning.
3. **Variety**: each major concept uses a different visual pattern — no card grids or rows of equal boxes.
4. **Connections**: every relationship has an arrow or line; position alone doesn't show a relationship.
5. **Colors from the palette**: every color comes from `references/color-palette.md`; none invented.
6. **Text clean**: the `text` property contains only readable words (no markup/escapes), `fontFamily: 3`.
7. **Rendered**: the diagram has been rendered to PNG and visually inspected via the Read tool.
8. **Render is clean**: no clipped text, no unintended overlaps, arrows land correctly, composition balanced.
