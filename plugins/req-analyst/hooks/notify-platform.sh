#!/usr/bin/env bash
# notify-platform.sh
# PostToolUse hook — runs after every Bash tool execution.
# Emits a short nudge once the platform has been detected from the git remote.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | cut -d'"' -f4 2>/dev/null || echo "")

# Only act on git remote commands (used for platform detection)
if ! echo "$COMMAND" | grep -qE "^git remote"; then
    exit 0
fi

echo "Platform detected. Next step: fetch the item and the full comment thread, then determine the grooming state."
