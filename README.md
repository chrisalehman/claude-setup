# claude-setup

Turns Claude Code into a fully autonomous software engineer. One script installs everything.

```bash
git clone git@github.com:chrisalehman/claude-setup.git
cd claude-setup
./claude-bootstrap.sh
```

Re-run anytime to update. Reset with `./claude-reset.sh`.

## What You Get

**Autonomy without recklessness.** A shell alias skips permission prompts. Behavioral rules in `~/.claude/CLAUDE.md` set the judgment layer -- Claude operates continuously but pauses for irreversible actions. Hard guardrail hooks physically block pushes to main and destructive SQL.

**Structured workflow.** The superpowers plugin gives Claude a full SDLC: brainstorm, plan, TDD, parallel subagent execution, code review.

**100+ specialist subagents.** TypeScript, Python, Go, Rust, Terraform, Kubernetes, PostgreSQL, security auditing, and more. Claude dispatches domain experts in parallel.

**Document and design skills.** PDFs, Word docs, spreadsheets, slide decks, diagrams, frontend UIs.

**Live browser.** Playwright MCP server for E2E testing, debugging, and visual verification.

## What's Installed

Everything is defined in [`claude-config.txt`](claude-config.txt). Edit it and re-run the bootstrap.

| Category | What |
|----------|------|
| **CLI tools** | git, node, pnpm, gh, jq, ripgrep, uv |
| **Plugins** | superpowers, frontend-design, document-skills, example-skills |
| **Subagents** | voltagent-core-dev, voltagent-lang, voltagent-infra, voltagent-qa-sec, voltagent-data-ai, voltagent-dev-exp, voltagent-meta |
| **MCP servers** | playwright, context7 |
| **Skills** | excalidraw-diagram |
| **Hooks** | protect-main.sh, protect-database.sh |
| **Global rules** | Autonomy, worktrees, code review ([`claude-global.md`](claude-global.md)) |
| **Shell alias** | `claude` runs with `--dangerously-skip-permissions` |

Optional tools (cloud, databases, deployment) are commented out at the bottom of `claude-config.txt`. Uncomment and re-run.

## Repo Structure

```
claude-setup/
├── claude-config.txt        # What gets installed (single source of truth)
├── claude-global.md         # Behavioral rules → ~/.claude/CLAUDE.md
├── claude-bootstrap.sh      # Install everything (idempotent)
├── claude-reset.sh          # Remove everything
├── hooks/                   # Git + SQL guardrail hooks
└── README.md
```
