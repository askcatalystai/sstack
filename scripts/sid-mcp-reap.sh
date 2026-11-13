#!/usr/bin/env bash
# Hourly per-thread Codex MCP cleanup; all process operations live in the injectable backend.
set -eu
exec python3 "$(dirname "$0")/sid_mcp_reap.py" "$@"
