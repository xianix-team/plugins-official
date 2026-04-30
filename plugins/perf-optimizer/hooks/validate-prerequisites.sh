#!/usr/bin/env bash
# validate-prerequisites.sh
# Validates that the environment is ready for the Performance Optimizer.
# Run as a PreToolUse hook before Bash tool executions.
#
# Reading  — git for logs / file lists on the default branch; gh / curl only for
#            reading the trigger issue or work item, opening the PR, and linking back.
# Writing  — the agent pushes to a `perf/issue-*` or `perf/workitem-*` branch only.
#            Never to the repository's default branch.
#
# Credentials
#   GITHUB_TOKEN / GH_TOKEN — used by gh CLI and by git push for HTTPS auth on github.com
#   AZURE-DEVOPS-TOKEN      — used by git push for HTTPS auth on Azure DevOps remotes,
#                             and by curl for REST calls (work items, PRs, comments)

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | cut -d'"' -f4 2>/dev/null || echo "")

# GitHub CLI — used for issue read, PR creation, and issue comment posting
if echo "$COMMAND" | grep -qE "^gh "; then
    if ! command -v gh > /dev/null 2>&1; then
        echo '{"decision": "block", "reason": "GitHub CLI (gh) is not installed or not in PATH. Install: https://cli.github.com — see docs/platform-setup.md"}'
        exit 0
    fi
    if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        echo '{"decision": "block", "reason": "Not inside a git repository. gh commands require a checked-out repo."}'
        exit 0
    fi
    exit 0
fi

# Only validate git commands beyond this point
if ! echo "$COMMAND" | grep -qE "^git "; then
    exit 0
fi

if ! command -v git > /dev/null 2>&1; then
    echo '{"decision": "block", "reason": "git is not installed or not in PATH."}'
    exit 0
fi

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo '{"decision": "block", "reason": "Not inside a git repository. The Performance Optimizer requires a git project."}'
    exit 0
fi

# Block pushes from any branch that is not a `perf/issue-*` / `perf/workitem-*` branch.
# The Performance Optimizer must only push to the fix branch it created — never to the
# default branch, never to an existing feature branch.
if echo "$COMMAND" | grep -qE "^git push"; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    if [ -n "$CURRENT_BRANCH" ] && ! echo "$CURRENT_BRANCH" | grep -qE "^perf/(issue|workitem)-"; then
        echo "{\"decision\": \"block\", \"reason\": \"Refusing to push from '${CURRENT_BRANCH}'. The Performance Optimizer only pushes from branches named 'perf/issue-*' or 'perf/workitem-*' created by the perf-pr-author agent. Never push to the default branch.\"}"
        exit 0
    fi
fi

# For commit operations — require git identity to be set
if echo "$COMMAND" | grep -qE "^git commit"; then
    if [ -z "$(git config user.name 2>/dev/null)" ]; then
        echo '{"decision": "block", "reason": "git user.name is not set. Run: git config --global user.name \"Your Name\""}'
        exit 0
    fi
    if [ -z "$(git config user.email 2>/dev/null)" ]; then
        echo '{"decision": "block", "reason": "git user.email is not set. Run: git config --global user.email \"you@example.com\""}'
        exit 0
    fi
fi

# For push operations — require a remote and a token, and inject credentials via env
if echo "$COMMAND" | grep -qE "^git push"; then
    if ! git remote | grep -q .; then
        echo '{"decision": "block", "reason": "No git remote configured. Add a remote with: git remote add origin <url>"}'
        exit 0
    fi

    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")

    if echo "$REMOTE_URL" | grep -qE "(dev\.azure\.com|visualstudio\.com)"; then
        if [ -z "${AZURE-DEVOPS-TOKEN:-}" ]; then
            echo '{"decision": "block", "reason": "AZURE-DEVOPS-TOKEN is not set. Pass it at runtime: AZURE-DEVOPS-TOKEN=<pat> claude ... (see docs/platform-setup.md)"}'
            exit 0
        fi
        export GIT_CONFIG_COUNT=2
        export GIT_CONFIG_KEY_0="url.https://x-access-token:${AZURE-DEVOPS-TOKEN}@dev.azure.com/.insteadOf"
        export GIT_CONFIG_VALUE_0="https://dev.azure.com/"
        export GIT_CONFIG_KEY_1="url.https://x-access-token:${AZURE-DEVOPS-TOKEN}@visualstudio.com/.insteadOf"
        export GIT_CONFIG_VALUE_1="https://visualstudio.com/"
    elif echo "$REMOTE_URL" | grep -qE "github\.com"; then
        GH_CREDENTIAL="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
        if [ -z "${GH_CREDENTIAL}" ]; then
            echo '{"decision": "block", "reason": "GITHUB_TOKEN (or GH_TOKEN) is not set. Pass it at runtime: GITHUB_TOKEN=<token> claude ... (see docs/platform-setup.md)"}'
            exit 0
        fi
        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0="url.https://x-access-token:${GH_CREDENTIAL}@github.com/.insteadOf"
        export GIT_CONFIG_VALUE_0="https://github.com/"
    else
        echo '{"decision": "block", "reason": "Unsupported git remote. The Performance Optimizer supports GitHub (github.com) and Azure DevOps (dev.azure.com, visualstudio.com) remotes only."}'
        exit 0
    fi
fi

exit 0
