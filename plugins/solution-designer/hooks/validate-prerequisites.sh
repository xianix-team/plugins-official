#!/usr/bin/env bash
# validate-prerequisites.sh
# PreToolUse hook for the Solution Designer plugin.
#
# Reading  — git for the codebase; gh / curl for the item, thread, and PRs.
# Writing  — the agent pushes only `design/*` branches containing docs.
#            Never to the repository's default branch.
#
# Credentials
#   GITHUB-TOKEN / GH_TOKEN — gh CLI and git push for github.com
#   AZURE-DEVOPS-TOKEN      — curl REST + git push for Azure DevOps

set -euo pipefail

# Token names contain hyphens, so they cannot be read with ${VAR} expansion.
AZ_TOKEN=$(printenv 'AZURE-DEVOPS-TOKEN' 2>/dev/null || true)
GH_CREDENTIAL=$(printenv 'GITHUB-TOKEN' 2>/dev/null || printenv GH_TOKEN 2>/dev/null || true)

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | cut -d'"' -f4 2>/dev/null || echo "")

if echo "$COMMAND" | grep -qE "^gh "; then
    if ! command -v gh > /dev/null 2>&1; then
        echo '{"decision": "block", "reason": "GitHub CLI (gh) is not installed or not in PATH. Install: https://cli.github.com — see docs/platform-config.md"}'
        exit 0
    fi
    exit 0
fi

if echo "$COMMAND" | grep -qE "^curl.*(dev\.azure\.com|visualstudio\.com)"; then
    if [ -z "$AZ_TOKEN" ]; then
        echo '{"decision": "block", "reason": "AZURE-DEVOPS-TOKEN is not set. See docs/platform-config.md"}'
        exit 0
    fi
    exit 0
fi

if ! echo "$COMMAND" | grep -qE "^git "; then
    exit 0
fi

if ! command -v git > /dev/null 2>&1; then
    echo '{"decision": "block", "reason": "git is not installed or not in PATH."}'
    exit 0
fi

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo '{"decision": "block", "reason": "Not inside a git repository. The Solution Designer plugin requires a git project."}'
    exit 0
fi

if echo "$COMMAND" | grep -qE "^git commit"; then
    if [ -z "$(git config user.name 2>/dev/null)" ] || [ -z "$(git config user.email 2>/dev/null)" ]; then
        echo '{"decision": "block", "reason": "git user.name / user.email is not set. Configure them before committing the design doc."}'
        exit 0
    fi
    # Only documentation may be committed by this plugin.
    NON_DOCS=$(git diff --cached --name-only | grep -vE '^docs/' || true)
    if [ -n "$NON_DOCS" ]; then
        echo "{\"decision\": \"block\", \"reason\": \"Refusing to commit non-docs files: ${NON_DOCS//$'\n'/, }. The Solution Designer only commits under docs/.\"}"
        exit 0
    fi
fi

if echo "$COMMAND" | grep -qE "^git push"; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ -n "$CURRENT_BRANCH" ] && ! echo "$CURRENT_BRANCH" | grep -qE "^design/"; then
        echo "{\"decision\": \"block\", \"reason\": \"Refusing to push from '${CURRENT_BRANCH}'. The Solution Designer only pushes 'design/*' branches. Never push to the default branch.\"}"
        exit 0
    fi

    if ! git remote | grep -q .; then
        echo '{"decision": "block", "reason": "No git remote configured."}'
        exit 0
    fi

    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")

    if echo "$REMOTE_URL" | grep -qE "(dev\.azure\.com|visualstudio\.com)" && [ -z "$AZ_TOKEN" ]; then
        echo '{"decision": "block", "reason": "AZURE-DEVOPS-TOKEN is not set; cannot push the design branch. See docs/platform-config.md"}'
        exit 0
    fi
    if echo "$REMOTE_URL" | grep -qE "github\.com" && [ -z "$GH_CREDENTIAL" ] && ! gh auth status > /dev/null 2>&1; then
        echo '{"decision": "block", "reason": "No GitHub credentials (GITHUB-TOKEN / GH_TOKEN / gh auth login); cannot push the design branch."}'
        exit 0
    fi
fi

exit 0
