#!/usr/bin/env bash
# validate-prerequisites.sh
# Validates that the environment is ready for PR review operations.
# Run as a PreToolUse hook before Bash tool executions.
#
# Reading  — git for diffs/logs (all hosts); gh only when posting to GitHub
# Writing  — requires local git for commit/push; validated here
#
# Credentials (reference the underscored names — bash cannot use dashes in identifiers).
# The framework may inject these secrets under dashed keys (GITHUB-TOKEN /
# AZURE-DEVOPS-TOKEN); the Xianix Executor re-exports any dashed env var as an underscored
# alias, so GITHUB_TOKEN / AZURE_DEVOPS_TOKEN are what is referenceable at runtime.
#   GITHUB_TOKEN          — used by git push for HTTPS authentication (GitHub / generic)
#   AZURE_DEVOPS_TOKEN    — used by git push for HTTPS authentication on Azure DevOps remotes
#                        also used by curl for the Azure DevOps REST API calls
#
# This hook VALIDATES only. It cannot inject credentials: it runs as a separate
# process, and every run happens in a temporary Docker container, so exports made
# here never reach the agent's shell. The push command carries GIT_CONFIG_*
# variables inline on the same command line (see docs/git-auth.md).

set -euo pipefail

# Parse tool_input.command with a real JSON parser, not a quote-blind grep. A grep-based
# `"command":"[^"]*"` extraction breaks on (a) pretty-printed JSON with a space after `:`,
# and (b) any command containing an embedded `"` — e.g. `git commit -m "fix: foo"`, which is
# exactly what commands/pr-review.md's fix-mode instructions tell the agent to run. Either
# failure mode silently truncates COMMAND, which then silently disables every check below.
INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
")

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
    # pointing the review lead at the correct provider doc.
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
    if [ -n "$REMOTE_URL" ] && ! echo "$REMOTE_URL" | grep -q "github.com"; then
        if echo "$REMOTE_URL" | grep -qE "(dev\.azure\.com|visualstudio\.com)"; then
            echo '{"decision": "block", "reason": "gh CLI is for GitHub remotes only — this remote is Azure DevOps. Use curl + AZURE_DEVOPS_TOKEN per providers/azure-devops.md."}'
        elif echo "$REMOTE_URL" | grep -q "bitbucket.org"; then
            echo '{"decision": "block", "reason": "gh CLI is for GitHub remotes only — this remote is Bitbucket. Use git only and write to pr-review-report.md per providers/generic.md."}'
        else
            echo '{"decision": "block", "reason": "gh CLI is for GitHub remotes only — this remote is not GitHub. Use git only and write to pr-review-report.md per providers/generic.md."}'
        fi
        exit 0
    fi

    exit 0
fi

# curl to Azure DevOps REST — require AZURE_DEVOPS_TOKEN (underscored; the referenceable name).
# The token may be injected upstream under the dashed key AZURE-DEVOPS-TOKEN, which bash cannot
# reference as $AZURE-DEVOPS-TOKEN. The Xianix Executor re-exports dashed env vars as underscored
# aliases, so AZURE_DEVOPS_TOKEN should be set. If it is empty but a dashed AZURE-DEVOPS-TOKEN
# exists in the raw environment, the alias step did not run — surface an actionable error.
#
# Secret hygiene: never echo token values (not via env, printenv to stdout, or $VAR expansion).
# Presence-check only with ${AZURE_DEVOPS_TOKEN:+yes}. Detect dashed keys via compgen -e (names
# only). Re-export with printenv into an assignment — never print the value.
if echo "$COMMAND" | grep -qE "curl.*(dev\.azure\.com|visualstudio\.com|app\.vssps\.visualstudio\.com)"; then
    if [ -z "${AZURE_DEVOPS_TOKEN:-}" ]; then
        if compgen -e | grep -qx 'AZURE-DEVOPS-TOKEN'; then
            echo '{"decision": "block", "reason": "AZURE_DEVOPS_TOKEN is empty but a dashed AZURE-DEVOPS-TOKEN exists. Bash cannot reference hyphenated names — re-export as: export AZURE_DEVOPS_TOKEN=\"$(printenv AZURE-DEVOPS-TOKEN)\". Never echo the secret; presence-check only: echo \"AZURE_DEVOPS_TOKEN=${AZURE_DEVOPS_TOKEN:+yes}\""}'
        else
            echo '{"decision": "block", "reason": "AZURE_DEVOPS_TOKEN is not set. Pass it at runtime: AZURE_DEVOPS_TOKEN=<pat> claude ... (see docs/platform-setup.md). Never echo the secret; presence-check only: echo \"AZURE_DEVOPS_TOKEN=${AZURE_DEVOPS_TOKEN:+yes}\""}'
        fi
        exit 0
    fi
fi

# Only validate git commands beyond this point. Match git anywhere at a word
# start, not just column 0 — the recommended push form is prefixed with
# GIT_CONFIG_* variables on the same command line.
if ! echo "$COMMAND" | grep -qE "(^|[[:space:]])git "; then
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
if echo "$COMMAND" | grep -qE "(^|[[:space:]])git commit"; then
    if [ -z "$(git config user.name 2>/dev/null)" ]; then
        echo '{"decision": "block", "reason": "git user.name is not set. Run: git config --global user.name \"Your Name\""}'
        exit 0
    fi
    if [ -z "$(git config user.email 2>/dev/null)" ]; then
        echo '{"decision": "block", "reason": "git user.email is not set. Run: git config --global user.email \"you@example.com\""}'
        exit 0
    fi
fi

# For push operations — require a remote and a token.
#
# VALIDATION ONLY. This hook runs as its own short-lived process, so exporting
# GIT_CONFIG_* here can never reach the agent's shell session (and every run is
# a throwaway Docker container — nothing persists between processes anyway).
# The push command itself must carry the credentials inline via GIT_CONFIG_*
# variables prefixed on the same command line — see docs/git-auth.md and the
# fix-mode push step in commands/pr-review.md.
if echo "$COMMAND" | grep -qE "(^|[[:space:]])git push"; then
    if ! git remote | grep -q .; then
        echo '{"decision": "block", "reason": "No git remote configured. Add a remote with: git remote add origin <url>"}'
        exit 0
    fi

    # Detect platform from the remote URL
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")

    if echo "$REMOTE_URL" | grep -qE "(dev\.azure\.com|visualstudio\.com)"; then
        if [ -z "${AZURE_DEVOPS_TOKEN:-}" ]; then
            echo '{"decision": "block", "reason": "AZURE_DEVOPS_TOKEN is not set in the container environment. It must be injected when the container starts (see docs/platform-setup.md)."}'
            exit 0
        fi
    else
        if [ -z "${GITHUB_TOKEN:-}" ]; then
            echo '{"decision": "block", "reason": "GITHUB_TOKEN is not set in the container environment. It must be injected when the container starts (see docs/platform-setup.md)."}'
            exit 0
        fi
    fi
fi

# All checks passed — allow the command to proceed
exit 0
