#!/usr/bin/env bash
# lib-token.sh — discover platform tokens from multiple env name variants.
#
# Secrets must never appear on argv (transcript / ps leakage). Scripts still
# read tokens from the environment, but callers must not depend on one exact
# name: the Xianix Executor may inject dashed keys (AZURE-DEVOPS-TOKEN /
# GITHUB-TOKEN) that bash cannot reference as $VAR, and GitHub tooling
# accepts either GH_TOKEN or GITHUB_TOKEN.
#
# Usage:
#   # shellcheck disable=SC1091
#   source "${SCRIPT_DIR}/lib-token.sh"
#   resolve_token azure    # → exports AZURE_DEVOPS_TOKEN when found
#   resolve_token github   # → exports GH_TOKEN and GITHUB_TOKEN when found
#
# Never prints secret values. Presence-check only:
#   echo "AZURE_DEVOPS_TOKEN=${AZURE_DEVOPS_TOKEN:+yes}"
#
# Returns 0 if a token was resolved (or already set), 1 if none found.

# _token_from_env <name>
# Prints the value of env var <name> (supports dashed names via printenv).
# Empty / missing → empty stdout, exit 1.
_token_from_env() {
  local name="$1"
  local val=""
  # Underscored / valid bash identifiers: expand directly when set.
  if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    # shellcheck disable=SC2086
    eval "val=\${$name-}"
    if [ -n "$val" ]; then
      printf '%s' "$val"
      return 0
    fi
  fi
  # Dashed or otherwise non-identifier names: printenv only (never echo).
  if compgen -e | grep -qx "$name"; then
    val="$(printenv "$name" 2>/dev/null || true)"
    if [ -n "$val" ]; then
      printf '%s' "$val"
      return 0
    fi
  fi
  return 1
}

# resolve_token azure|github
resolve_token() {
  local kind="${1:-}"
  local val=""

  case "$kind" in
    azure|ado|azuredevops|azure-devops)
      if [ -n "${AZURE_DEVOPS_TOKEN:-}" ]; then
        return 0
      fi
      for name in AZURE_DEVOPS_TOKEN AZURE-DEVOPS-TOKEN ADO_TOKEN AZURE_TOKEN; do
        if val="$(_token_from_env "$name")"; then
          export AZURE_DEVOPS_TOKEN="$val"
          if [ "$name" != "AZURE_DEVOPS_TOKEN" ]; then
            echo "OK: re-exported ${name} → AZURE_DEVOPS_TOKEN" >&2
          fi
          return 0
        fi
      done
      return 1
      ;;
    github|gh)
      # Prefer GH_TOKEN (what `gh` reads); also keep GITHUB_TOKEN in sync for git push.
      if [ -n "${GH_TOKEN:-}" ]; then
        if [ -z "${GITHUB_TOKEN:-}" ]; then
          export GITHUB_TOKEN="$GH_TOKEN"
        fi
        return 0
      fi
      if [ -n "${GITHUB_TOKEN:-}" ]; then
        export GH_TOKEN="$GITHUB_TOKEN"
        return 0
      fi
      for name in GH_TOKEN GITHUB_TOKEN GITHUB-TOKEN GH-TOKEN; do
        if val="$(_token_from_env "$name")"; then
          export GH_TOKEN="$val"
          export GITHUB_TOKEN="$val"
          if [ "$name" != "GH_TOKEN" ] && [ "$name" != "GITHUB_TOKEN" ]; then
            echo "OK: re-exported ${name} → GH_TOKEN/GITHUB_TOKEN" >&2
          fi
          return 0
        fi
      done
      return 1
      ;;
    *)
      echo "ERROR: resolve_token: unknown kind '$kind' (use azure|github)" >&2
      return 1
      ;;
  esac
}

# token_present azure|github — presence check for logs (never prints the value).
token_present() {
  local kind="${1:-}"
  case "$kind" in
    azure|ado|azuredevops|azure-devops)
      echo "AZURE_DEVOPS_TOKEN=${AZURE_DEVOPS_TOKEN:+yes}"
      ;;
    github|gh)
      if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
        echo "GITHUB_TOKEN/GH_TOKEN=yes"
      else
        echo "GITHUB_TOKEN/GH_TOKEN="
      fi
      ;;
  esac
}
