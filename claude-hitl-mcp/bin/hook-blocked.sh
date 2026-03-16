#!/bin/bash
# Permission-request hook: report blocked state to HITL listener
claude-hitl-mcp signal blocked --stdin < /dev/stdin 2>/dev/null || exit 0
