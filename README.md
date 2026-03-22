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

**Remote Control** — Claude Code from your phone, plus Telegram and Slack via Claude Channels. Wherever you are on-the-go, dispatch agent teams at a debugging problem, review the design, approve a PR. The real value isn't mobile access — it's async engineering. Launch a refactoring job, get notified when the agent needs an architectural decision, approve it, move on. Every hour your credits sit idle is engineering capacity left on the table. The goal is Claude running continuously — as many parallel workstreams as you can manage. Your throughput decouples from whether you're sitting at a terminal.

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

## Safety

Hooks intercept `Bash` commands to catch accidental pushes to main and destructive SQL before they happen. The philosophy in [`claude-global.md`](claude-global.md) teaches Claude judgment — six principles for when to act, when to pause, and when to escalate.

## Requirements

macOS with Homebrew. Claude Code CLI installed (`brew install claude-code`).
