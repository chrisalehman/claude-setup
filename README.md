# claude-setup

One script transforms Claude Code from a generalist into a fully agentic engineering team — 100+ specialists, structured SDLC, safety guardrails.

```bash
git clone git@github.com:chrisalehman/claude-setup.git
cd claude-setup
./claude-bootstrap.sh
```

Re-run anytime to update. Reset with `./claude-reset.sh`.

## Patterns That Change How You Ship

Most AI tooling demos show a single agent completing a single task. That's the "hello world" of agentic development. These six patterns are what happens when you treat AI agents the way you'd treat an engineering organization — with specialization, parallelism, feedback loops, and async coordination.

**Agentic Teams** — Dispatch parallel specialist teams at a problem instead of feeding everything through one context window. Audits, refactors, migrations, feature builds, incident investigations — any problem that benefits from multiple perspectives gets decomposed across concurrent agents, each bringing domain expertise, then synthesized into a coordinated result. This is the same reason no serious org assigns one engineer to do a security review, perf analysis, and accessibility audit in one sitting. Parallelism plus specialization compounds.

**Subagent SDLC Pipeline** — The superpowers plugin implements a full development lifecycle as a composable skill: brainstorm → design decisions with explicit tradeoff analysis → implementation plan → TDD → parallel execution → code review. The critical design choice: the pipeline surfaces architectural *decisions* to you rather than burying them in generated code. You make the calls that matter — technology choices, boundary definitions, consistency tradeoffs — while agents scale the implementation across a problem space you'd never tackle alone. Multi-day team efforts executed in hours, or even minutes.

**Domain Specialists on Demand** — 100+ voltagent specialists: Kubernetes debugger, PostgreSQL optimizer, security auditor, Terraform engineer, Rust systems programmer. The problems this unlocks: harden your auth layer, optimize a critical query path, untangle a Helm chart, and audit your IAM policies — simultaneously, in a single session. You don't need to be an expert in every domain. You dispatch one.

**Autonomous Debug Cycles** — A closed feedback loop: test → analyze → hypothesize → fix → build → redeploy → validate with Playwright against a running application. This is a control system, not a suggestion engine. The agent doesn't propose a fix and wait — it executes, observes, and iterates until the test passes or escalates. You come back to a resolved issue, not a diagnostic report.

**Agentic QA** — When your system under test contains agents with non-deterministic behavior, deterministic assertions break immediately. Agentic QA uses agent-based tests that observe outputs, adapt to variation, and validate *intent* rather than exact values. You test AI with AI. This is the testing problem most teams haven't hit yet — and will, the moment they ship agents to production.

**Remote Control** — Claude Code from your phone. Wherever you are on-the-go, dispatch agent teams at a debugging problem, review the design, approve a PR. The real value isn't mobile access — it's async engineering. Launch a refactoring job, get notified when the agent needs an architectural decision, approve it, move on. Every hour your credits sit idle is engineering capacity left on the table. The goal is Claude running continuously — as many parallel workstreams as you can manage. Your throughput decouples from whether you're sitting at a terminal.

## First Session

After bootstrap, try this in any project:

```
Audit this codebase — dispatch an Agent Team. Security, performance, and
architecture reviewed in parallel. Synthesize findings.
```

Watch Claude decompose the request across concurrent specialists. Each explores independently — one surfaces a vulnerability, another flags a query bottleneck, a third challenges a layering boundary. Results arrive synthesized, not sequential.

Other things to try on day one:

- `Fix this failing test. Run it. Iterate until green. Show me the result.`
- `Refactor this module — full SDLC: design decision first, then implement.`
- `Optimize this query. Measure before and after.`

## What Gets Installed

Everything lives in [`claude-config.txt`](claude-config.txt) — edit it and re-run the bootstrap. Here's what unlocks those patterns:

| Category | What |
|----------|------|
| **CLI tools** | git, node, pnpm, gh, jq, ripgrep, uv |
| **Plugins** | superpowers, frontend-design, document-skills, example-skills |
| **Subagents** | voltagent-core-dev, voltagent-lang, voltagent-infra, voltagent-qa-sec, voltagent-data-ai, voltagent-dev-exp, voltagent-meta |
| **MCP servers** | playwright, context7 |
| **Skills** | excalidraw-diagram, impeccable (20+ design skills) |
| **Hooks** | protect-main.sh, protect-database.sh |
| **Philosophy** | 6 principles for agentic development → [`~/.claude/CLAUDE.md`](claude-global.md) |
| **Shell alias** | `claude` → `claude --dangerously-skip-permissions` |

Optional tools (cloud, databases, deployment) are commented out at the bottom of `claude-config.txt`. Uncomment and re-run.

## How It Works

Bootstrap is idempotent — run it anytime, always get the same result. Modify [`claude-config.txt`](claude-config.txt) to add or remove tools, skills, plugins. Fork this repo for team standardization.

```
claude-setup/
├── claude-config.txt        # What gets installed
├── claude-global.md         # Philosophy → ~/.claude/CLAUDE.md
├── claude-bootstrap.sh      # Install (idempotent)
├── claude-reset.sh          # Remove everything
├── hooks/                   # Safety guardrails
│   ├── protect-main.sh      # Blocks pushes to main/master
│   ├── protect-database.sh  # Blocks destructive SQL
│   └── *.test.sh            # Hook test suites
└── README.md
```

## Tool Reference

![Architecture](architecture.png)

Everything below explains why each tool was chosen over alternatives, where it's configured, and how it fits the system. Every entry is declared in [`claude-config.txt`](claude-config.txt) — edit that file and re-run the bootstrap.

### CLI Tools

Installed via `brew install`. These are system-level dependencies that Claude Code and the bootstrap itself depend on.

| Tool | Config | Why this tool |
|------|--------|---------------|
| **git** | `brew-dep \| git` | Version control. Required by Claude Code for worktrees, diffs, and branch operations. |
| **node** | `brew-dep \| node` | JavaScript runtime. Required by npm, MCP servers (`npx`), and Playwright. |
| **pnpm** | `brew-dep \| pnpm` | Fast, disk-efficient package manager. Preferred over npm/yarn for speed and strict dependency resolution. Not currently used by bootstrap itself, but available for project work. |
| **gh** | `brew-dep \| gh` | GitHub CLI. Claude uses `gh pr create`, `gh issue`, `gh api` for GitHub operations without needing browser access or tokens in env vars. |
| **jq** | `brew-dep \| jq` | JSON processor. The bootstrap script uses jq to merge hooks, env vars, and status line config into `~/.claude/settings.json` without clobbering existing settings. Also useful for Claude when parsing API responses. |
| **ripgrep** | `brew-dep \| rg \| ripgrep` | Claude Code's built-in `Grep` tool is powered by ripgrep (`rg`). Without it, code search falls back to slower alternatives. The binary is `rg` but the Homebrew package name is `ripgrep`, hence the two-field config entry. |
| **uv** | `brew-dep \| uv` | Python package manager from Astral. Used exclusively for the excalidraw-diagram skill setup (`uv sync`, `uv run`). Chosen over pip/poetry for speed — installs Python dependencies in seconds, not minutes. |

### MCP Servers

MCP (Model Context Protocol) servers give Claude runtime capabilities beyond its built-in tools. Registered via `claude mcp add -s user` (user-scoped, not project-scoped). Configured in [`claude-config.txt`](claude-config.txt) and registered during bootstrap into `~/.claude/settings.json`.

**Playwright** — `mcp-server | playwright | @playwright/mcp`

Browser automation. Gives Claude tools to navigate pages, click elements, fill forms, take screenshots, and run JavaScript in a real Chromium browser. This is what enables the "Autonomous Debug Cycles" pattern — Claude can start a dev server, navigate to the app, observe the UI, and iterate on fixes against what it actually sees.

Why Playwright over Puppeteer or Cypress: Playwright has first-class MCP support (`@playwright/mcp` is maintained by Microsoft), auto-waits for elements (fewer flaky interactions), and supports Chromium/Firefox/WebKit. Puppeteer is Chrome-only and has no official MCP server. Cypress is a testing framework, not a browser automation tool — different use case.

The bootstrap also installs `@playwright/test` as an npm global and runs `npx playwright install chromium` to ensure the browser binary is available.

**Context7** — `mcp-server | context7 | @upstash/context7-mcp@latest`

Documentation lookup. Gives Claude tools to query up-to-date library documentation and code examples at runtime, rather than relying on training data. When Claude needs to use a library API it's unsure about, it can look it up live.

Why Context7 over other doc servers: Context7 indexes the actual source documentation of libraries and returns relevant code examples. It's purpose-built for LLM consumption — returns concise, structured results rather than raw HTML pages.

### Plugins & Subagents

Plugins extend Claude Code with additional skills and agent types. Installed via `claude plugin install` from two marketplaces.

**Marketplaces** — Where plugins are sourced from:
- `anthropics/skills` — Anthropic's official skill marketplace
- `VoltAgent/awesome-claude-code-subagents` — Community subagent collection

#### SDLC Pipeline

**superpowers** (`claude-plugins-official`) — The backbone of the agentic workflow. Implements a composable development lifecycle as a chain of skills:

1. **Brainstorming** — Explores the idea through structured dialogue. Asks clarifying questions one at a time, proposes 2-3 approaches with tradeoffs, presents a design for approval.
2. **Writing Plans** — Converts approved designs into step-by-step implementation plans with explicit checkpoints.
3. **Executing Plans** — Runs implementation plans with review gates.
4. **Test-Driven Development** — Writes tests before implementation code.
5. **Systematic Debugging** — Structured hypothesis → test → fix cycles instead of shotgun debugging.
6. **Code Review** — Dispatches a reviewer subagent against the plan and coding standards.
7. **Verification Before Completion** — Requires running tests and showing output before claiming done.

The critical design choice: the pipeline surfaces architectural *decisions* to you (technology choices, boundary definitions, tradeoffs) rather than burying them in generated code. You make the calls that matter.

Also includes: `dispatching-parallel-agents`, `subagent-driven-development`, `using-git-worktrees`, `finishing-a-development-branch`, `receiving-code-review`.

#### Design & Document Skills

**frontend-design** (`claude-plugins-official`) — Design-quality frontend generation. Creates production-grade web components, pages, and applications that avoid the generic "AI-generated" look. Includes sub-skills: `animate`, `arrange`, `audit`, `bolder`, `clarify`, `colorize`, `critique`, `delight`, `distill`, `extract`, `harden`, `normalize`, `onboard`, `optimize`, `overdrive`, `polish`, `quieter`, `typeset`.

**document-skills** (`anthropic-agent-skills`) — Document creation and manipulation. Handles PDF, DOCX, PPTX, XLSX, and CSV files. Also includes `claude-api` (Anthropic SDK integration), `mcp-builder` (MCP server creation guide), `webapp-testing` (Playwright test toolkit), `canvas-design`, `algorithmic-art`, and more.

**example-skills** (`anthropic-agent-skills`) — Reference implementations of the document-skills. Included as working examples you can study or modify.

#### Domain Specialists (VoltAgent)

Seven subagent packs providing 100+ specialist agents. These are dispatched via the `Agent` tool with a `subagent_type` parameter — Claude selects the right specialist based on the task. Each agent gets its own context window and tool access.

| Pack | Config | What it covers |
|------|--------|----------------|
| **voltagent-core-dev** | `plugin \| voltagent-core-dev \| voltagent-subagents` | API design, backend/frontend/fullstack development, mobile, Electron, GraphQL, microservices, WebSocket, UI design |
| **voltagent-lang** | `plugin \| voltagent-lang \| voltagent-subagents` | Language specialists: TypeScript, Python, Rust, Go, Java, C#, C++, Ruby/Rails, PHP/Laravel, Swift, Kotlin, Elixir, Angular, React, Vue, Next.js, Django, Spring Boot, .NET, Flutter, SQL, PowerShell |
| **voltagent-infra** | `plugin \| voltagent-infra \| voltagent-subagents` | Cloud architecture, Kubernetes, Terraform, Terragrunt, Docker, CI/CD, DevOps, SRE, security, networking, Azure, Windows infrastructure, incident response |
| **voltagent-qa-sec** | `plugin \| voltagent-qa-sec \| voltagent-subagents` | Code review, security auditing, penetration testing, performance engineering, accessibility, compliance, chaos engineering, debugging, QA strategy, test automation |
| **voltagent-data-ai** | `plugin \| voltagent-data-ai \| voltagent-subagents` | AI/ML engineering, data science, data engineering, NLP, LLM architecture, MLOps, PostgreSQL optimization, prompt engineering |
| **voltagent-dev-exp** | `plugin \| voltagent-dev-exp \| voltagent-subagents` | CLI development, build engineering, documentation, dependency management, Git workflows, legacy modernization, MCP development, refactoring, Slack integration |
| **voltagent-meta** | `plugin \| voltagent-meta \| voltagent-subagents` | Multi-agent coordination, workflow orchestration, task distribution, context management, performance monitoring, knowledge synthesis |

Why VoltAgent over building custom subagents: VoltAgent agents are community-maintained with detailed system prompts tuned for each domain. Building equivalent prompts from scratch for 100+ specializations would be months of work. The tradeoff is you inherit their prompt design opinions — if a specialist's behavior doesn't match your needs, you'd need to fork.

### Custom Skills

Skills are prompt files installed to `~/.claude/skills/` that Claude can invoke via the `Skill` tool. Unlike plugins (which define agent types), skills are instructions that Claude follows within its own context.

**excalidraw-diagram** — `github-skill | excalidraw-diagram | coleam00/excalidraw-diagram-skill`

Generates Excalidraw diagram JSON files for visualizing workflows, architectures, and concepts. Includes a Python renderer (set up via `uv sync` during bootstrap) that uses Playwright to convert diagrams to images.

**impeccable** — `github-skill-pack | impeccable | pbakaus/impeccable`

A skill pack from Paul Bakaus (Google) containing 20+ design skills. Installed as individual skills — each subdirectory in the repo's `.claude/skills/` becomes a separate skill in `~/.claude/skills/`. Includes: `adapt`, `animate`, `arrange`, `audit`, `bolder`, `clarify`, `colorize`, `critique`, `delight`, `distill`, `extract`, `harden`, `normalize`, `onboard`, `optimize`, `overdrive`, `polish`, `quieter`, `teach-impeccable`, `typeset`.

### Hooks (Safety Guardrails)

Hooks are shell scripts that intercept Claude Code tool calls before execution. Registered as `PreToolUse` hooks on the `Bash` matcher in `~/.claude/settings.json`. Exit code 0 allows the command; exit code 2 hard-blocks it. Both hooks receive JSON on stdin with the structure `{"tool_input":{"command":"..."}}`.

**protect-main.sh** — [`hooks/protect-main.sh`](hooks/protect-main.sh) → `~/.claude/hooks/protect-main.sh`

Prevents Claude from pushing to main/master. Three detection layers:

1. **Explicit target** — Blocks `git push origin main`, `git push origin HEAD:main`, etc.
2. **Force push** — Blocks any `-f`, `--force`, or `--force-with-lease` flag on any push.
3. **Implicit push from main** — Checks `git symbolic-ref --short HEAD` and blocks `git push` (bare or with remote) when on main/master locally.

The hook splits compound commands on `&&`, `||`, `;` and strips quoted strings to avoid false positives from "git push" appearing inside commit messages or echo statements.

**protect-database.sh** — [`hooks/protect-database.sh`](hooks/protect-database.sh) → `~/.claude/hooks/protect-database.sh`

Prevents Claude from running destructive SQL. First checks if the command involves a database CLI (`psql`, `mysql`, `sqlite3`, `mongosh`, `clickhouse-client`, `cqlsh`, `cockroach sql`, `mariadb`), then scans for:

| Pattern | What it catches |
|---------|-----------------|
| `DROP TABLE/DATABASE/SCHEMA/INDEX/VIEW/FUNCTION/...` | Any DROP operation |
| `TRUNCATE` | Table truncation |
| `DELETE FROM ... ` without `WHERE` | Mass deletes (splits on `;` to check per-statement) |
| `ALTER TABLE ... DROP` | Column/constraint removal |
| `.drop()` / `.dropDatabase()` / `.deleteMany({})` | MongoDB destructive methods |
| `DROP`/`TRUNCATE` piped to a DB client | Catches `echo "DROP TABLE..." \| psql` patterns |

Both hooks have test suites ([`hooks/protect-main.test.sh`](hooks/protect-main.test.sh), [`hooks/protect-database.test.sh`](hooks/protect-database.test.sh)) run in CI via GitHub Actions.

### Claude Code Configuration

These settings are injected into `~/.claude/settings.json` by the bootstrap. They're not in `claude-config.txt` as separate entries — some are side effects of other installations (hooks), while others are explicit config entries.

**Environment variable: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`** — `env-var | CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS | 1`

Enables the experimental Agent Teams feature in Claude Code. This allows Claude to spawn named, addressable subagents that can communicate with each other via `SendMessage` — not just independent parallel agents, but coordinated teams. This is what powers the "Agentic Teams" pattern.

**Status line: `npx ccstatusline@latest`** — `statusline | npx ccstatusline@latest`

Adds a persistent status bar to the Claude Code terminal showing real-time session metrics. Configuration lives in [`ccstatusline/settings.json`](ccstatusline/settings.json), copied to `~/.config/ccstatusline/settings.json` during bootstrap.

Displays two lines:
- **Line 1:** Model name · thinking effort · context window % · session cost ($) · session clock
- **Line 2:** Git branch · git worktree (if in one)

Why these metrics: Context window % tells you when you're approaching compression (and should start a new session). Session cost tracks spend. Git branch/worktree keeps you oriented when Claude is working across multiple worktrees.

**Shell alias: `claude → claude --dangerously-skip-permissions`**

Added to `~/.zshrc`. Bypasses Claude Code's interactive permission prompts for every tool call. Without this, Claude pauses and asks "Allow this Bash command? [y/n]" on every operation, breaking autonomous workflows.

Why this is safe despite the name: The hooks provide the actual safety net. `--dangerously-skip-permissions` removes the interactive friction, while `protect-main.sh` and `protect-database.sh` hard-block the operations that are genuinely dangerous. The philosophy in `CLAUDE.md` adds the judgment layer — teaching Claude when to act and when to escalate. The result: Claude operates autonomously on safe operations and is physically prevented from the dangerous ones.

### Global Philosophy (`CLAUDE.md`)

The file [`claude-global.md`](claude-global.md) is installed to `~/.claude/CLAUDE.md` (wrapped in `<!-- claude-setup:start/end -->` markers so re-runs update without clobbering your additions). This is the instructions file that Claude Code reads at the start of every session, in every project.

**Why global, not project-level:** Claude Code reads both `~/.claude/CLAUDE.md` (global) and `.claude/CLAUDE.md` (project-level) — they compose. The principles here are *agent-level behavior*, not project-specific conventions. "Deploy the team," "prove it works," and "guard your context" apply regardless of what you're building. Making them global means bootstrap sets it once and every project inherits automatically — no per-project setup, no drift between repos. Project-level `CLAUDE.md` files are still the right place for project-specific instructions (coding style, architecture decisions, repo-specific boundaries). The two layers stack: global provides the base operating model, project-level adds local context.

It teaches six principles and four hard boundaries:

**Principles** — These shape how Claude approaches work:

| Principle | What it teaches | Why it matters |
|-----------|-----------------|----------------|
| **Deploy the team** | Use 100+ specialists in parallel. A solo agent is a wasted army. | Without this, Claude defaults to doing everything in one context window — slower, worse results, wastes the subagent infrastructure you just installed. |
| **Guard your context** | Main conversation is for decisions. Offload research and implementation to subagents. | Context window pollution is the #1 cause of degraded Claude performance mid-session. This principle keeps the main thread clean. |
| **Act, don't ask** | Operate autonomously. Fix bugs without hand-holding. | Claude's default behavior is overly cautious — asking permission for things a senior engineer would just do. This recalibrates. |
| **Prove it works** | Never claim done without evidence. Run tests, show output. | Without this, Claude will say "I've fixed the bug" without running the test suite. Trust but verify. |
| **Learn from corrections** | Save corrections to `memory/` immediately. Never repeat the same mistake. | Claude has no cross-session memory by default. The `memory/` folder is a persistent knowledge base that compounds across sessions. |
| **Keep a project notebook** | Maintain `memory/` with `context.md`, `decisions.md`, `lessons.md`. | Anyone (including future Claude sessions) can open the folder and understand the project state, decisions made, and lessons learned. |

**Boundaries** — Four operations that require explicit human approval:

1. Pushes to main/production branches (enforced by `protect-main.sh` hook)
2. Destructive database migrations (enforced by `protect-database.sh` hook)
3. Changes to secrets, API keys, or credentials (enforced by philosophy)
4. Configuration changes that affect billing (enforced by philosophy)

The first two are hard-blocked by hooks. The last two rely on Claude's judgment informed by the philosophy. This is defense in depth — hooks catch what they can mechanically; principles cover the rest.

### Optional Tools

The bottom of [`claude-config.txt`](claude-config.txt) contains commented-out entries organized by use case. Uncomment what you need and re-run `./claude-bootstrap.sh`.

**Cloud & Infrastructure** — `kubectl`, `helm`, `stern`, `kubectx`, `argocd`, `docker`, `k9s`. Enable if you're working with Kubernetes clusters. The voltagent-infra subagents (Kubernetes specialist, Terraform engineer, etc.) will use these tools when available.

**GCP** — `gcloud`. Requires a manual cask install (`brew install --cask google-cloud-sdk`) since it's not a standard Homebrew formula.

**AWS** — `aws` (package: `awscli`). For AWS infrastructure work.

**Databases** — `psql` (package: `libpq`), `mongosh`, `redis`. Also includes an optional `@anthropic-ai/mcp-server-postgres` MCP server that gives Claude direct PostgreSQL access via MCP tools (read-only queries, schema inspection). Enable this if you want Claude to query your database directly rather than generating SQL for you to run.

**Deployment Platforms** — `vercel`, `supabase`, `firebase`. For deploying directly from Claude sessions.

**API & Serialization** — `httpie` (friendlier curl), `yq` (YAML processor, companion to jq), `grpcurl` (gRPC CLI), `protoc` (protobuf compiler). Enable for API development and testing workflows.

## Safety

Hooks intercept `Bash` commands to catch accidental pushes to main and destructive SQL before they happen. The philosophy in [`claude-global.md`](claude-global.md) teaches Claude judgment — six principles for when to act, when to pause, and when to escalate. See [Hooks](#hooks-safety-guardrails) and [Global Philosophy](#global-philosophy-claudemd) above for details.

## Requirements

macOS with Homebrew. Claude Code CLI installed (`brew install claude-code`).
