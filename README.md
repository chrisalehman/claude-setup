# claude-setup

Personal Claude Code bootstrap. Two scripts, one config, fully configured environment. Idempotent — safe to re-run anytime.

## Usage

```bash
git clone git@github.com:chrisalehman/claude-setup.git
cd claude-setup
./claude-bootstrap.sh        # install everything
./claude-reset.sh            # prompts "Remove all?" first, then item-by-item if declined
./claude-reset.sh --all      # remove everything without prompting
```

## What's included

### CLI Tools (installed via Homebrew)

| Tool | Purpose |
|------|---------|
| git | Version control |
| node | JavaScript runtime |
| pnpm | Node package manager |
| gh | GitHub CLI |
| jq | JSON processor |
| ripgrep (`rg`) | Fast text search |
| uv | Python package manager |

### Plugins (from official marketplaces)

| Plugin | Source | Purpose |
|--------|--------|---------|
| superpowers | claude-plugins-official | SDLC workflow: brainstorm → plan → TDD → subagent execution → review |
| frontend-design | claude-plugins-official | Production-grade UI design that avoids generic AI aesthetics |
| document-skills | anthropic-agent-skills | docx, pdf, pptx, xlsx creation and manipulation |
| example-skills | anthropic-agent-skills | skill-creator, webapp-testing (Playwright), mcp-builder |

### Subagent Plugins (from VoltAgent marketplace)

| Plugin | Purpose |
|--------|---------|
| voltagent-core-dev | API design, backend, frontend, fullstack, mobile, WebSocket |
| voltagent-lang | Language specialists: TypeScript, Python, React, Next.js, SQL, Go, Rust, Java + 18 more |
| voltagent-infra | DevOps, cloud, deployment: Kubernetes, Terraform, Docker, AWS/Azure/GCP, SRE |
| voltagent-qa-sec | Testing, security, code quality: code review, debugging, penetration testing, a11y |
| voltagent-data-ai | Data/ML/AI: Postgres, prompt engineering, LLM architecture, data pipelines, MLOps |
| voltagent-dev-exp | Developer productivity: refactoring, documentation, CLI tools, Git workflows, MCP |
| voltagent-meta | Multi-agent orchestration, workflow automation, task distribution |

### Global Memory (installed to ~/.claude/CLAUDE.md)

Curated behavioral rules applied to every Claude Code session across all projects.

| Rule | Purpose |
|------|---------|
| Code Review Before Push | Always invoke code review before `git push` |
| Don't Start Duplicate Dev Servers | Check for running servers before starting another |
| Don't Delete Generated Outputs | Never delete PDFs, diagrams, images without confirmation |
| Clean Working Directory | Scripts must not leave intermediary files |
| Reviews Must Check Conventions | Code reviews must check file placement, not just correctness |
| Persistent Planning for Complex Tasks | Use a scratch `_plan.md` for multi-step tasks, delete when done |
| Use Worktrees for Development | Never commit directly to main — use worktrees/branches, merge after review |
| Autonomy | Operate without approval except for irreversible/out-of-codebase actions |

Edit `claude-global.md` to add or remove rules. To disable entirely, comment out or remove the `global-memory` line in `claude-config.txt`.

The bootstrap installs these rules into a managed section of `~/.claude/CLAUDE.md` (between `<!-- claude-setup:start -->` and `<!-- claude-setup:end -->` markers). Any personal content you add outside these markers is preserved across bootstrap runs and resets.

### Shell Alias (installed to ~/.zshrc)

The bootstrap installs a shell alias that runs Claude Code with `--dangerously-skip-permissions`, bypassing mechanical permission prompts. The Autonomy rule in global memory provides the judgment layer — Claude still pauses for irreversible actions.

```bash
alias claude='/opt/homebrew/bin/claude --dangerously-skip-permissions'
```

These two features work as a pair: the flag removes low-level friction, the rule sets the high-level threshold.

### Custom Skills (fetched from GitHub, installed to ~/.claude/skills/)

| Skill | Source | Purpose |
|-------|--------|---------|
| excalidraw-diagram | [coleam00/excalidraw-diagram-skill](https://github.com/coleam00/excalidraw-diagram-skill) | Excalidraw diagram generation with PNG rendering via Playwright |

Custom skills are fetched from GitHub at bootstrap time, not stored in this repo.

### E2E Testing (Playwright)

The bootstrap installs Playwright for end-to-end browser testing:

- **Test runner:** `@playwright/test` (global npm package) — run tests in any project with `npx playwright test`
- **Browser:** Chromium (downloaded automatically)
- **MCP server:** `@playwright/mcp` — gives Claude live browser control for interactive debugging and visual verification

**Headless by default.** To see the browser UI during tests:

```bash
npx playwright test --headed
```

To initialize Playwright in a new project:

```bash
npm init playwright@latest
```

### MCP Servers

| Server | Package | Purpose |
|--------|---------|---------|
| playwright | `@playwright/mcp` | Live browser control for E2E testing, debugging, and visual verification |
| context7 | `@upstash/context7-mcp` | Up-to-date library documentation — bridges the gap when Claude's training data is stale |

## Repo structure

```
claude-setup/
├── .gitignore
├── claude-config.txt        # Shared config (plugins, skills, marketplaces)
├── claude-global.md         # Global behavioral rules (installed to ~/.claude/CLAUDE.md)
├── claude-bootstrap.sh      # Install everything (idempotent)
├── claude-reset.sh          # Remove everything (interactive or --all)
└── README.md
```

## Prerequisites

- macOS (scripts assume macOS + Homebrew)
- Claude Code CLI (`brew install claude-code`)

The bootstrap script automatically installs Homebrew (if missing) and all other dependencies.

## Updating

Re-running the bootstrap script updates all custom skills to their latest versions from GitHub:

```bash
./claude-bootstrap.sh
```

## Adding new stuff

Everything is defined in `claude-config.txt` — one place, no sync issues:

```
brew-dep      | binary              (package = binary)
brew-dep      | binary  | package   (when binary ≠ package name)
marketplace   | name
plugin        | name    | source
global-memory | filename
github-skill  | name    | owner/repo
npm-global    | package
mcp-server    | name    | package
```

## Optional tools

The bottom of `claude-config.txt` includes commented-out tool profiles for common workflows:

- **Cloud & Infrastructure** — kubectl, helm, stern, kubectx, argocd, docker, k9s
- **GCP / AWS** — gcloud, awscli
- **Databases** — psql, mongosh, redis, Postgres MCP server
- **Deployment Platforms** — vercel, supabase, firebase
- **API & Serialization** — httpie, yq, grpcurl, protobuf

Uncomment what you need and re-run `./claude-bootstrap.sh`. Commented-out entries are ignored by the bootstrap and reset scripts.
