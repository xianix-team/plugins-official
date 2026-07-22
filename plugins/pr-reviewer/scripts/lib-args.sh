#!/usr/bin/env bash
# lib-args.sh — shared CLI flag parser for pr-reviewer entry-point scripts.
#
# Why: each Claude Code Bash tool call is a fresh shell, so `export FOO=bar`
# from a prior call is gone. Skills/commands must pass agent-chosen scalars as
# flags on the same command line. Env names remain as fallback for backward
# compatibility and for callers that still set them on the same line.
#
# Usage (from an entry-point script):
#   # shellcheck disable=SC1091
#   source "${SCRIPT_DIR}/lib-args.sh"
#   parse_pr_args "$@"
#
# Flags (all optional unless the calling script requires a value):
#   --pr N                 → PR_NUMBER (also sets PR_ID when PR_ID was empty)
#   --branch NAME          → BRANCH_ARG
#   --fix                 → FIX_MODE=true
#   --verdict TEXT         → VERDICT
#   --mode initial|rereview → REVIEW_MODE
#   --platform HINT        → PLATFORM (hint; scripts still re-detect from origin)
#   --block-on-critical    → PR_REVIEWER_BLOCK_ON_CRITICAL=true
#   --optional             → START_COMMENT_OPTIONAL=true (soft-skip when no PR)
#
# Flag values beat pre-existing env values. Unknown flags → usage error + exit 1.
# After parse, remaining positional args are left in PR_ARGS_REMAINING (array).

# shellcheck disable=SC2034  # exported for callers
START_COMMENT_OPTIONAL="${START_COMMENT_OPTIONAL:-false}"

_pr_args_usage() {
  cat >&2 <<'USAGE'
Usage: <script> [options]

Options:
  --pr N                   Pull request number / id
  --branch NAME            Source branch name
  --fix                   Enable fix mode
  --verdict TEXT           Review verdict (e.g. APPROVE, REQUEST CHANGES)
  --mode initial|rereview  Review mode
  --platform HINT          Platform hint (github|azure|azuredevops|…)
  --block-on-critical      Make REQUEST CHANGES blocking on the platform
  --optional               Soft-skip when PR id cannot be resolved (start-comment)
USAGE
}

# parse_pr_args "$@"
# Sets: PR_NUMBER, BRANCH_ARG, FIX_MODE, VERDICT, REVIEW_MODE, PLATFORM,
#        PR_REVIEWER_BLOCK_ON_CRITICAL, START_COMMENT_OPTIONAL, PR_ID (when --pr)
# Leaves unused positionals in PR_ARGS_REMAINING.
parse_pr_args() {
  PR_ARGS_REMAINING=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)
        [ $# -ge 2 ] || { echo "ERROR: --pr requires a value" >&2; _pr_args_usage; return 1; }
        PR_NUMBER="$2"
        # Keep PR_ID in sync for Azure-style callers that read PR_ID.
        if [ -z "${PR_ID:-}" ]; then
          PR_ID="$2"
        fi
        shift 2
        ;;
      --pr=*)
        PR_NUMBER="${1#--pr=}"
        if [ -z "${PR_ID:-}" ]; then
          PR_ID="$PR_NUMBER"
        fi
        shift
        ;;
      --branch)
        [ $# -ge 2 ] || { echo "ERROR: --branch requires a value" >&2; _pr_args_usage; return 1; }
        BRANCH_ARG="$2"
        shift 2
        ;;
      --branch=*)
        BRANCH_ARG="${1#--branch=}"
        shift
        ;;
      --fix)
        FIX_MODE=true
        shift
        ;;
      --verdict)
        [ $# -ge 2 ] || { echo "ERROR: --verdict requires a value" >&2; _pr_args_usage; return 1; }
        VERDICT="$2"
        shift 2
        ;;
      --verdict=*)
        VERDICT="${1#--verdict=}"
        shift
        ;;
      --mode)
        [ $# -ge 2 ] || { echo "ERROR: --mode requires a value" >&2; _pr_args_usage; return 1; }
        REVIEW_MODE="$2"
        shift 2
        ;;
      --mode=*)
        REVIEW_MODE="${1#--mode=}"
        shift
        ;;
      --platform)
        [ $# -ge 2 ] || { echo "ERROR: --platform requires a value" >&2; _pr_args_usage; return 1; }
        PLATFORM="$2"
        shift 2
        ;;
      --platform=*)
        PLATFORM="${1#--platform=}"
        shift
        ;;
      --block-on-critical)
        PR_REVIEWER_BLOCK_ON_CRITICAL=true
        shift
        ;;
      --optional)
        START_COMMENT_OPTIONAL=true
        shift
        ;;
      -h|--help)
        _pr_args_usage
        return 1
        ;;
      --)
        shift
        PR_ARGS_REMAINING+=("$@")
        break
        ;;
      -*)
        echo "ERROR: unknown flag: $1" >&2
        _pr_args_usage
        return 1
        ;;
      *)
        PR_ARGS_REMAINING+=("$1")
        shift
        ;;
    esac
  done

  # Env fallback is already in place for any var the caller did not set via flag
  # (bash inherits the process environment). Export so child processes / sourced
  # state writers see the flag-derived values.
  export PR_NUMBER="${PR_NUMBER:-}"
  export BRANCH_ARG="${BRANCH_ARG:-}"
  export FIX_MODE="${FIX_MODE:-false}"
  export VERDICT="${VERDICT:-}"
  export REVIEW_MODE="${REVIEW_MODE:-}"
  export PLATFORM="${PLATFORM:-}"
  export PR_REVIEWER_BLOCK_ON_CRITICAL="${PR_REVIEWER_BLOCK_ON_CRITICAL:-false}"
  export START_COMMENT_OPTIONAL="${START_COMMENT_OPTIONAL:-false}"
  if [ -n "${PR_NUMBER:-}" ] && [ -z "${PR_ID:-}" ]; then
    export PR_ID="$PR_NUMBER"
  elif [ -n "${PR_ID:-}" ]; then
    export PR_ID
  fi

  return 0
}
