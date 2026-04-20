#!/usr/bin/env bash
# validate-prerequisites.sh
# Validates that the environment is ready for the Performance Optimizer Agent.
# Run as a PreToolUse hook before Bash tool executions.
#
# Reading  — git for diffs/logs (all hosts); gh only when posting / PR-creating on GitHub
# Writing  — fix-PR mode requires local git for commit/push; validated here
#
# Credentials
#   GIT_TOKEN           — used by git push for HTTPS auth (GitHub / generic)
#                         injected via GIT_CONFIG env vars, never written to disk
#   AZURE_DEVOPS_TOKEN  — used by git push for HTTPS auth on Azure DevOps remotes
#                         also used by REST API calls for posting and PR creation

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | cut -d'"' -f4 2>/dev/null || echo "")

# GitHub CLI — used for PR view/comment/create on github.com remotes
if echo "$COMMAND" | grep -qE "^gh "; then
    if ! command -v gh > /dev/null 2>&1; then
        echo '{"decision": "block", "reason": "GitHub CLI (gh) is not installed or not in PATH. Install: https://cli.github.com — see docs/platform-setup.md"}'
        exit 0
    fi
    if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        echo '{"decision": "block", "reason": "Not inside a git repository. gh pr commands require a checked-out repo."}'
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
    echo '{"decision": "block", "reason": "Not inside a git repository. Performance analysis requires a git project."}'
    exit 0
fi

# Block pushes to the source PR head branch in fix-PR mode.
# The Performance Optimizer Agent must only push to the `perf/optimize-*` branch it created.
if echo "$COMMAND" | grep -qE "^git push"; then
    # Extract the target refspec from the command if present
    # Accepts: `git push`, `git push origin`, `git push origin HEAD`, `git push -u origin <branch>`
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    if [ -n "$CURRENT_BRANCH" ] && ! echo "$CURRENT_BRANCH" | grep -qE "^perf/optimize-"; then
        # Only allow pushes from a perf/optimize-* branch while under this plugin's control.
        # If the user explicitly invoked the plugin outside fix-PR mode, they shouldn't be pushing
        # at all — analysis-first mode never pushes. Block and explain.
        if [ -n "${PERF_OPTIMIZER_FIX_MODE:-}" ]; then
            echo "{\"decision\": \"block\", \"reason\": \"Refusing to push from '${CURRENT_BRANCH}'. The Performance Optimizer Agent only pushes from branches named 'perf/optimize-*' created by the fix-pr-author agent. Never push to the source PR branch.\"}"
            exit 0
        fi
    fi
fi

# For commit operations — require git identity to be set (fix-PR mode)
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
        if [ -z "${AZURE_DEVOPS_TOKEN:-}" ]; then
            echo '{"decision": "block", "reason": "AZURE_DEVOPS_TOKEN is not set. Pass it at runtime: AZURE_DEVOPS_TOKEN=<pat> claude ... (see docs/platform-setup.md)"}'
            exit 0
        fi
        export GIT_CONFIG_COUNT=2
        export GIT_CONFIG_KEY_0="url.https://x-access-token:${AZURE_DEVOPS_TOKEN}@dev.azure.com/.insteadOf"
        export GIT_CONFIG_VALUE_0="https://dev.azure.com/"
        export GIT_CONFIG_KEY_1="url.https://x-access-token:${AZURE_DEVOPS_TOKEN}@visualstudio.com/.insteadOf"
        export GIT_CONFIG_VALUE_1="https://visualstudio.com/"
    else
        if [ -z "${GIT_TOKEN:-}" ]; then
            echo '{"decision": "block", "reason": "GIT_TOKEN is not set. Pass it at runtime: GIT_TOKEN=<token> claude ... (see docs/platform-setup.md)"}'
            exit 0
        fi
        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0="url.https://x-access-token:${GIT_TOKEN}@github.com/.insteadOf"
        export GIT_CONFIG_VALUE_0="https://github.com/"
    fi
fi

exit 0
