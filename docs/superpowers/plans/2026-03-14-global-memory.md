# Global Memory Management — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add config-driven global memory management that installs curated behavioral rules to `~/.claude/CLAUDE.md` with marker-based idempotency.

**Architecture:** A source file (`claude-global.md`) in the repo is referenced by a new `global-memory` config entry type. Bootstrap installs its content into a marked section in `~/.claude/CLAUDE.md`; reset removes only that section. Personal content outside markers is preserved.

**Tech Stack:** Bash, awk (for safe marker replacement)

**Spec:** `docs/superpowers/specs/2026-03-14-global-memory-design.md`

---

### Task 1: Create `claude-global.md` source file

**Files:**
- Create: `claude-global.md`

- [ ] **Step 1: Create the source file**

```markdown
# Global Behavioral Rules

## Code Review Before Push
Always invoke code review before running `git push`. Unreviewed code should never reach the remote.

## Don't Start Duplicate Dev Servers
Before starting any dev server, check if one is already running (e.g., `lsof -nP -i :3000`). If the user already has a server running in their terminal, don't start another from Claude Code.

## Don't Delete Generated Outputs
Never delete generated output files (PDFs, diagrams, images, etc.) without explicit user confirmation. Leave artifacts in place for the user to review.

## Clean Working Directory
Scripts and tools must not leave intermediary files (logs, temp files, artifacts) in the working directory. If output files are needed, the user will redirect manually.

## Reviews Must Check Conventions
When conducting code reviews, include a dedicated conventions check — file placement, naming patterns, directory structure, import style consistency — not just correctness.
```

- [ ] **Step 2: Commit**

```bash
git add claude-global.md
git commit -m "feat: add global memory source file with curated behavioral rules"
```

---

### Task 2: Add `global-memory` config entry to `claude-config.txt`

**Files:**
- Modify: `claude-config.txt`

- [ ] **Step 1: Update the header comment to document the new type**

Add `#   global-memory |  filename` to the format documentation block (lines 5-8).

- [ ] **Step 2: Add the global-memory entry**

Add between the plugin entries and the github-skill entry:

```
global-memory | claude-global.md
```

- [ ] **Step 3: Verify the config parses correctly**

Run: `grep -v '^\s*#' claude-config.txt | grep -v '^\s*$'`
Expected: the `global-memory | claude-global.md` line appears in the output.

- [ ] **Step 4: Commit**

```bash
git add claude-config.txt
git commit -m "feat: add global-memory config entry for claude-global.md"
```

---

### Task 3: Add `do_install_global_memory` to `claude-bootstrap.sh`

**Files:**
- Modify: `claude-bootstrap.sh`

- [ ] **Step 1: Add the `do_install_global_memory` function after the `do_install_github_skill` function**

```bash
do_install_global_memory() {
  local file="$1"
  local source="${SCRIPT_DIR}/${file}"
  local target=~/.claude/CLAUDE.md
  local start_marker="<!-- claude-setup:start -->"
  local end_marker="<!-- claude-setup:end -->"

  echo -n "  ${file} → ~/.claude/CLAUDE.md... "

  if [ ! -f "$source" ]; then
    echo "ERROR: '${file}' not found in ${SCRIPT_DIR}" >&2
    exit 1
  fi

  mkdir -p ~/.claude

  local content
  content="$(cat "$source")"
  local section="${start_marker}
${content}
${end_marker}"

  if [ ! -f "$target" ]; then
    # No existing file — create with managed section
    echo "$section" > "$target"
  elif grep -q "$start_marker" "$target"; then
    # Markers exist — replace managed section using awk
    awk -v start="$start_marker" -v end="$end_marker" -v replacement="$section" '
      BEGIN { printing=1 }
      $0 == start { printing=0; print replacement; next }
      $0 == end { printing=1; next }
      printing { print }
    ' "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
  else
    # File exists, no markers — append with blank line separator
    printf "\n%s\n" "$section" >> "$target"
  fi

  echo "✓"
}
```

- [ ] **Step 2: Add the Global Memory section between the Plugins and Custom Skills sections**

```bash
# ─── Global Memory ─────────────────────────────────────────────────────────

echo "Global memory:"
read_config "global-memory" do_install_global_memory
echo ""
```

- [ ] **Step 3: Add global memory verification to the Verification section (after the Custom Skills verification block, before `echo "" ; echo "Done"`)**

```bash
echo ""
echo "  Global memory:"
if [ -f ~/.claude/CLAUDE.md ] && grep -q "<!-- claude-setup:start -->" ~/.claude/CLAUDE.md; then
  echo "    ~/.claude/CLAUDE.md ✓"
else
  echo "    ~/.claude/CLAUDE.md — not installed"
fi
```

- [ ] **Step 4: Test bootstrap — clean install**

```bash
rm -f ~/.claude/CLAUDE.md
./claude-bootstrap.sh
```

Expected: output includes `Global memory:` section with `✓`. File `~/.claude/CLAUDE.md` exists with content between markers.

Run: `cat ~/.claude/CLAUDE.md`
Expected: starts with `<!-- claude-setup:start -->`, ends with `<!-- claude-setup:end -->`, contains the 5 rules.

- [ ] **Step 5: Test bootstrap — idempotency**

```bash
./claude-bootstrap.sh
```

Run: `grep -c 'claude-setup:start' ~/.claude/CLAUDE.md`
Expected: `1` (no duplication)

- [ ] **Step 6: Test bootstrap — preserves personal content**

```bash
echo "# My personal rules" | cat - ~/.claude/CLAUDE.md > /tmp/claude-md-tmp && mv /tmp/claude-md-tmp ~/.claude/CLAUDE.md
./claude-bootstrap.sh
head -1 ~/.claude/CLAUDE.md
```

Expected: first line is `# My personal rules` (preserved).

- [ ] **Step 7: Commit**

```bash
git add claude-bootstrap.sh
git commit -m "feat: add global memory install to bootstrap script"
```

---

### Task 4: Add `do_remove_global_memory` to `claude-reset.sh`

**Files:**
- Modify: `claude-reset.sh`

- [ ] **Step 1: Add the `do_remove_global_memory` function after the `do_remove_marketplace` function**

```bash
do_remove_global_memory() {
  local file="$1"
  local target=~/.claude/CLAUDE.md
  local start_marker="<!-- claude-setup:start -->"
  local end_marker="<!-- claude-setup:end -->"

  if ! confirm "global memory (${file})"; then
    echo "  global memory — skipped"
    return 0
  fi

  echo -n "  ~/.claude/CLAUDE.md... "

  if [ ! -f "$target" ]; then
    echo "✓ (already removed)"
    return 0
  fi

  if ! grep -q "$start_marker" "$target"; then
    echo "✓ (no managed section)"
    return 0
  fi

  # Remove managed section using awk
  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"

  # Delete file if only whitespace remains
  if [ ! -s "$target" ] || ! grep -q '[^[:space:]]' "$target"; then
    rm -f "$target"
  fi

  echo "✓"
}
```

- [ ] **Step 2: Add the Global Memory section between the Custom Skills and Plugins sections**

```bash
# ─── Global Memory ──────────────────────────────────────────────────────────

echo "Global memory:"
read_config "global-memory" do_remove_global_memory
echo ""
```

- [ ] **Step 3: Add global memory to verification section (after Custom Skills verification, before `echo "" ; echo "Done"`)**

```bash
echo ""
echo "  Global memory:"
if [ -f ~/.claude/CLAUDE.md ] && grep -q "<!-- claude-setup:start -->" ~/.claude/CLAUDE.md; then
  echo "    ~/.claude/CLAUDE.md — managed section still present"
else
  echo "    ~/.claude/CLAUDE.md ✓ (clean)"
fi
```

- [ ] **Step 4: Test reset — removes managed section**

```bash
./claude-bootstrap.sh
./claude-reset.sh --all
```

Run: `cat ~/.claude/CLAUDE.md 2>/dev/null || echo "[DELETED]"`
Expected: `[DELETED]` (file removed since it contained only the managed section)

- [ ] **Step 5: Test reset — preserves personal content**

```bash
./claude-bootstrap.sh
echo -e "# My personal rules\n\nBe nice." | cat - ~/.claude/CLAUDE.md > /tmp/claude-md-tmp && mv /tmp/claude-md-tmp ~/.claude/CLAUDE.md
./claude-reset.sh --all
cat ~/.claude/CLAUDE.md
```

Expected: file still exists with `# My personal rules` and `Be nice.`, but no markers or managed content.

- [ ] **Step 6: Commit**

```bash
git add claude-reset.sh
git commit -m "feat: add global memory removal to reset script"
```

---

### Task 5: Update `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add Global Memory section between Subagent Plugins and Custom Skills**

```markdown
### Global Memory (installed to ~/.claude/CLAUDE.md)

Curated behavioral rules applied to every Claude Code session across all projects.

| Rule | Purpose |
|------|---------|
| Code Review Before Push | Always invoke code review before `git push` |
| Don't Start Duplicate Dev Servers | Check for running servers before starting another |
| Don't Delete Generated Outputs | Never delete PDFs, diagrams, images without confirmation |
| Clean Working Directory | Scripts must not leave intermediary files |
| Reviews Must Check Conventions | Code reviews must check file placement, not just correctness |

Edit `claude-global.md` to add or remove rules. To disable entirely, comment out or remove the `global-memory` line in `claude-config.txt`.

The bootstrap installs these rules into a managed section of `~/.claude/CLAUDE.md` (between `<!-- claude-setup:start -->` and `<!-- claude-setup:end -->` markers). Any personal content you add outside these markers is preserved across bootstrap runs and resets.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document global memory feature in README"
```

---

### Task 6: End-to-end verification

- [ ] **Step 1: Full reset**

```bash
./claude-reset.sh --all
```

- [ ] **Step 2: Verify clean state**

```bash
cat ~/.claude/CLAUDE.md 2>/dev/null || echo "[CLEAN]"
```

Expected: `[CLEAN]`

- [ ] **Step 3: Full bootstrap**

```bash
./claude-bootstrap.sh
```

Expected: all sections pass with `✓`, including `Global memory:`.

- [ ] **Step 4: Verify global memory content**

```bash
cat ~/.claude/CLAUDE.md
```

Expected: file contains markers and all 5 rules.

- [ ] **Step 5: Idempotency check**

```bash
./claude-bootstrap.sh
grep -c 'claude-setup:start' ~/.claude/CLAUDE.md
```

Expected: `1`

- [ ] **Step 6: Config opt-out check**

Comment out `global-memory` line in `claude-config.txt`, run `./claude-bootstrap.sh`. Verify no error and global memory section is skipped in output. Then uncomment the line.

- [ ] **Step 7: Final commit (if any fixups needed)**

```bash
git add -A
git commit -m "fix: address issues found during end-to-end verification"
```
