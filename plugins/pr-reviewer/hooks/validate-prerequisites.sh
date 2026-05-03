#!/usr/bin/env bash
# validate-prerequisites.sh
# Validates that the environment is ready for PR review operations.
# Run as a PreToolUse hook before Bash tool executions.
#
# Reading  — git for diffs/logs (all hosts); gh only when posting to GitHub
# Writing  — requires local git for commit/push; validated here
#
# Credentials
#   GITHUB-TOKEN          — used by git push for HTTPS authentication (GitHub / generic)
#                        injected via GIT_CONFIG env vars, never written to disk
#   AZURE-DEVOPS-TOKEN   — used by git push for HTTPS authentication on Azure DevOps remotes
#                        also used by the az CLI for API calls

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | cut -d'"' -f4 2>/dev/null || echo "")

# GitHub CLI — used for PR view/diff/post on github.com remotes
if echo "$COMMAND" | grep -qE "(^|[[:space:]])gh[[:space:]]"; then
    if ! command -v gh > /dev/null 2>&1; then
        echo '{"decision": "block", "reason": "GitHub CLI (gh) is not installed or not in PATH. Install: https://cli.github.com — see docs/platform-setup.md"}'
        exit 0
    fi
    if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        echo '{"decision": "block", "reason": "Not inside a git repository. gh pr commands require a checked-out repo."}'
        exit 0
    fi

    # Platform-exclusive CLI: gh is for GitHub remotes only.
    # On Azure DevOps / Bitbucket / generic remotes, gh will fail with
    # "gh auth login" prompts and waste turns. Block early with a clear message
    # pointing the orchestrator at the correct provider doc.
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
    if [ -n "$REMOTE_URL" ] && ! echo "$REMOTE_URL" | grep -q "github.com"; then
        if echo "$REMOTE_URL" | grep -qE "(dev\.azure\.com|visualstudio\.com)"; then
            echo '{"decision": "block", "reason": "gh CLI is for GitHub remotes only — this remote is Azure DevOps. Use curl + AZURE-DEVOPS-TOKEN per providers/azure-devops.md."}'
        elif echo "$REMOTE_URL" | grep -q "bitbucket.org"; then
            echo '{"decision": "block", "reason": "gh CLI is for GitHub remotes only — this remote is Bitbucket. Use git only and write to pr-review-report.md per providers/generic.md."}'
        else
            echo '{"decision": "block", "reason": "gh CLI is for GitHub remotes only — this remote is not GitHub. Use git only and write to pr-review-report.md per providers/generic.md."}'
        fi
        exit 0
    fi

    exit 0
fi

# curl to Azure DevOps REST — require AZURE-DEVOPS-TOKEN, with a token-name hygiene check.
# Some upstream environments export the token as AZURE-DEVOPS-TOKEN (with hyphens),
# which is not a valid bash identifier and cannot be referenced as $AZURE-DEVOPS-TOKEN.
# Detect that and surface a clear, actionable error instead of a silent 401.
if echo "$COMMAND" | grep -qE "curl.*(dev\.azure\.com|visualstudio\.com|app\.vssps\.visualstudio\.com)"; then
    if [ -z "${AZURE-DEVOPS-TOKEN:-}" ]; then
        if env | grep -q '^AZURE-DEVOPS-TOKEN='; then
            echo '{"decision": "block", "reason": "Found AZURE-DEVOPS-TOKEN (with hyphens) but AZURE-DEVOPS-TOKEN (with underscores) is empty. Bash cannot reference hyphenated names — re-export as: export AZURE-DEVOPS-TOKEN=\"$(env | sed -n s/^AZURE-DEVOPS-TOKEN=//p)\""}'
        else
            echo '{"decision": "block", "reason": "AZURE-DEVOPS-TOKEN is not set. Pass it at runtime: AZURE-DEVOPS-TOKEN=<pat> claude ... (see docs/platform-setup.md)"}'
        fi
        exit 0
    fi
fi

# Only validate git commands beyond this point
if ! echo "$COMMAND" | grep -qE "^git "; then
    exit 0
fi

# Check: git is available
if ! command -v git > /dev/null 2>&1; then
    echo '{"decision": "block", "reason": "git is not installed or not in PATH."}'
    exit 0
fi

# Check: must be inside a git repository
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo '{"decision": "block", "reason": "Not inside a git repository. PR review requires a git project."}'
    exit 0
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

# For push operations — require a remote and a token
if echo "$COMMAND" | grep -qE "^git push"; then
    if ! git remote | grep -q .; then
        echo '{"decision": "block", "reason": "No git remote configured. Add a remote with: git remote add origin <url>"}'
        exit 0
    fi

    # Detect platform from the remote URL
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")

    if echo "$REMOTE_URL" | grep -qE "(dev\.azure\.com|visualstudio\.com)"; then
        # Azure DevOps — use AZURE-DEVOPS-TOKEN
        if [ -z "${AZURE-DEVOPS-TOKEN:-}" ]; then
            echo '{"decision": "block", "reason": "AZURE-DEVOPS-TOKEN is not set. Pass it at runtime: AZURE-DEVOPS-TOKEN=<pat> claude ... (see docs/platform-setup.md)"}'
            exit 0
        fi

        # Inject the PAT into git credentials for Azure DevOps HTTPS remotes
        # Supports both dev.azure.com and *.visualstudio.com URL formats
        export GIT_CONFIG_COUNT=2
        export GIT_CONFIG_KEY_0="url.https://x-access-token:${AZURE-DEVOPS-TOKEN}@dev.azure.com/.insteadOf"
        export GIT_CONFIG_VALUE_0="https://dev.azure.com/"
        export GIT_CONFIG_KEY_1="url.https://x-access-token:${AZURE-DEVOPS-TOKEN}@visualstudio.com/.insteadOf"
        export GIT_CONFIG_VALUE_1="https://visualstudio.com/"
    else
        # GitHub or generic HTTPS remote — use GITHUB-TOKEN
        if [ -z "${GITHUB-TOKEN:-}" ]; then
            echo '{"decision": "block", "reason": "GITHUB-TOKEN is not set. Pass it at runtime: GITHUB-TOKEN=<token> claude ... (see docs/platform-setup.md)"}'
            exit 0
        fi

        # Inject token via env-based git config — no files written, no global config touched,
        # scoped to this shell session only.
        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0="url.https://x-access-token:${GITHUB-TOKEN}@github.com/.insteadOf"
        export GIT_CONFIG_VALUE_0="https://github.com/"
    fi
fi

# All checks passed — allow the command to proceed
exit 0
