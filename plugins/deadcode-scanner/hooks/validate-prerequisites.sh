#!/usr/bin/env bash
# validate-prerequisites.sh
# PreToolUse hook for deadcode-scanner. Hard-blocks if Node.js is missing AND a
# Bash command is about to invoke knip (knip runs via npx, which needs Node).
# Everything else is soft — knip itself is auto-fetched by `npx --yes`.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | cut -d'"' -f4 2>/dev/null || echo "")

# Only inspect commands that invoke knip (directly or via npx)
if ! echo "$COMMAND" | grep -qE "(^|[;&| ])(npx( --yes)? )?knip( |$)"; then
    exit 0
fi

# Hard block: Node.js is required to run knip
if ! command -v node > /dev/null 2>&1; then
    echo '{"decision": "block", "reason": "Node.js is required to run Knip but is not installed. Install Node.js 18+: https://nodejs.org (or winget install OpenJS.NodeJS.LTS on Windows, brew install node on macOS, apt install nodejs on Linux)."}'
    exit 0
fi

NODE_MAJOR=$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1 || echo "0")
if [ "$NODE_MAJOR" -lt 18 ] 2>/dev/null; then
    echo "{\"decision\": \"block\", \"reason\": \"Node.js v$NODE_MAJOR is below the minimum (18) required by Knip. Please upgrade Node.js.\"}"
    exit 0
fi

exit 0
