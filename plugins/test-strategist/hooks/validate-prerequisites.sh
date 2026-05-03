#!/usr/bin/env bash
# validate-prerequisites.sh
# Validates that the environment is ready for test strategy operations.
# Run as a PreToolUse hook before Bash tool executions.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | cut -d'"' -f4 2>/dev/null || echo "")

# Only validate git, gh, curl, and jq commands
if ! echo "$COMMAND" | grep -qE "^(git |gh |curl |jq )"; then
    exit 0
fi

# All providers rely on jq for index.json munging and API response parsing.
if ! command -v jq > /dev/null 2>&1; then
    echo '{"decision": "block", "reason": "jq is not installed or not in PATH. Install it: brew install jq (macOS), winget install jqlang.jq (Windows), or apt install jq (Linux). See docs/platform-config.md"}'
    exit 0
fi

# For git commands — check git is available
if echo "$COMMAND" | grep -qE "^git "; then
    if ! command -v git > /dev/null 2>&1; then
        echo '{"decision": "block", "reason": "git is not installed or not in PATH."}'
        exit 0
    fi
    if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        echo '{"decision": "block", "reason": "Not inside a git repository. Test strategy requires a git project."}'
        exit 0
    fi
fi

# For gh commands — check gh is installed and authenticated
if echo "$COMMAND" | grep -qE "^gh "; then
    if ! command -v gh > /dev/null 2>&1; then
        echo '{"decision": "block", "reason": "gh CLI is not installed. Install it: brew install gh (macOS), winget install GitHub.cli (Windows), or apt install gh (Linux). See docs/platform-config.md"}'
        exit 0
    fi
    if ! gh auth status > /dev/null 2>&1; then
        if [ -z "${GITHUB-TOKEN:-}" ]; then
            echo '{"decision": "block", "reason": "gh CLI is not authenticated and GITHUB-TOKEN is not set. Run: gh auth login — or export GITHUB-TOKEN=ghp_xxx. See docs/platform-config.md"}'
            exit 0
        fi
    fi
fi

# For curl commands targeting Azure DevOps — check token is set
if echo "$COMMAND" | grep -qE "^curl.*dev\.azure\.com"; then
    if [ -z "${AZURE-DEVOPS-TOKEN:-}" ]; then
        echo '{"decision": "block", "reason": "AZURE-DEVOPS-TOKEN is not set. Pass it at runtime: AZURE-DEVOPS-TOKEN=<pat> claude ... (see docs/platform-config.md)"}'
        exit 0
    fi
fi

# All checks passed — allow the command to proceed
exit 0
