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
