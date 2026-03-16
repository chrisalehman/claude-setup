#!/bin/bash
# Post-tool-use hook: report activity to HITL listener
claude-hitl-mcp signal activity --stdin < /dev/stdin 2>/dev/null || exit 0
