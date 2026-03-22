# claude-setup

Transforms Claude Code from a generalist into a fully autonomous engineering team with 100+ specialists, structured SDLC, and safety guardrails. One script installs everything.

```bash
git clone git@github.com:chrisalehman/claude-setup.git
cd claude-setup
./claude-bootstrap.sh
```

Re-run anytime to update. Reset with `./claude-reset.sh`.

## What You Get

**Specialist subagents** — TypeScript, Python, Go, Rust, Terraform, Kubernetes, PostgreSQL, security auditing, and more. Claude dispatches domain experts in parallel instead of being a generalist.

**Structured SDLC workflow** — The superpowers plugin gives Claude engineering discipline: brainstorm → plan → TDD → parallel execution → code review. No more ad-hoc development.

**Document and design skills** — PDFs, Word docs, spreadsheets, slide decks, diagrams, frontend UI prototypes. Built-in document generation and visual design capabilities.

**Live browser** — Playwright MCP server for E2E testing, screenshot validation, and visual debugging.

**Autonomy without recklessness** — A shell alias skips permission prompts for speed. Behavioral rules in `~/.claude/CLAUDE.md` provide judgment — Claude operates continuously but pauses for irreversible actions. Hard hooks physically block pushes to main and destructive SQL. No accidents.

## What's Installed

Everything is defined in [`claude-config.txt`](claude-config.txt). This is the single source of truth. Edit it and re-run the bootstrap.

| Category | What |
|----------|------|
| **CLI tools** | git, node, pnpm, gh, jq, ripgrep, uv |
| **Plugins** | superpowers, frontend-design, document-skills, example-skills |
| **Subagents** | voltagent-core-dev, voltagent-lang, voltagent-infra, voltagent-qa-sec, voltagent-data-ai, voltagent-dev-exp, voltagent-meta |
| **MCP servers** | playwright, context7 |
| **Skills** | excalidraw-diagram, impeccable (20+ design skills) |
| **Hooks** | protect-main.sh, protect-database.sh |
| **Rules** | Behavioral guardrails → [`~/.claude/CLAUDE.md`](claude-global.md) |
| **Shell alias** | `claude` → `claude --dangerously-skip-permissions` |

Optional tools (cloud, databases, deployment) are commented out at the bottom of `claude-config.txt`. Uncomment and re-run bootstrap.

## How It Works

`claude-config.txt` is the single source of truth for what gets installed. `claude-bootstrap.sh` is idempotent — run it as many times as you need, always get the same result. Hooks use exit code 2 to physically block dangerous operations. Behavioral rules in `~/.claude/CLAUDE.md` provide the judgment layer — teach Claude when to pause.

## Customization

Modify `claude-config.txt` to add or remove tools, skills, plugins. Uncomment optional sections for cloud providers, databases, or deployment platforms. Fork this repo for team standardization across your organization.

## Repo Structure

```
claude-setup/
├── claude-config.txt        # What gets installed (single source of truth)
├── claude-global.md         # Behavioral rules → ~/.claude/CLAUDE.md
├── claude-bootstrap.sh      # Install everything (idempotent)
├── claude-reset.sh          # Remove everything
├── hooks/                   # Safety guardrail hooks
│   ├── protect-main.sh      # Blocks pushes to main/master
│   ├── protect-database.sh  # Blocks destructive SQL
│   └── *.test.sh            # Hook test suites
└── README.md
```

## Safety Model

Hooks cover `PreToolUse` events on `Bash` commands, preventing accidental pushes to main and destructive SQL operations. This is a guardrail for accidents, not a security boundary — the behavioral rules in `~/.claude/CLAUDE.md` provide the judgment layer that teaches Claude when to pause for irreversible actions.

## Requirements

macOS with Homebrew. Claude Code CLI installed (`brew install claude-code`).
