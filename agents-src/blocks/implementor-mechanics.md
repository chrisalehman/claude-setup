- **Re-read code after editing, especially when moving patterns between contexts.** It's easy
  to lose track of what a file actually says after a sequence of Edit calls; verify by reading.
- **Any refactor must discover ALL test suites, not just the default command.** Before trusting
  a green run as a refactor's safety net — your own or a delegated skill's — confirm the
  discovery step actually enumerated every test entry point: `bash tests/run.sh`, plus any
  standalone `*.test.sh` it does not reach, plus any `package.json` scripts.
