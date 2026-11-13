#!/usr/bin/env bash
# lib-azure-remote.sh — shared Azure DevOps remote-URL parser.
#
# Source this file (do not exec). It defines:
#   parse_azure_remote [remote-url]
#     Parses origin (or the given URL) into AZURE_HOST, AZURE_ORG,
#     AZURE_COLLECTION, AZURE_PROJECT, AZURE_REPO, API_BASE and exports them.
#   write_azure_env
#     Writes the parsed vars (+ PR_ID) to /tmp/pr_azure.env for later `source`.
#
# Handles all four URL shapes plus SSH remotes. Anchors on the `_git` segment
# so DefaultCollection / collection prefixes never steal the project name.

# shellcheck shell=bash

parse_azure_remote() {
  local REMOTE REMOTE_CLEAN PATH_PARTS GIT_LINE PREFIX_START PROJECT_LINE HOST_AND_ORG_PATH
  local V3_PATH

  REMOTE="${1:-}"
  if [ -z "$REMOTE" ]; then
    REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
  fi
  if [ -z "$REMOTE" ]; then
    echo "ERROR: no git remote URL to parse" >&2
    return 1
  fi

  # Normalise SSH remotes to the canonical https shape first.
  #   git@ssh.dev.azure.com:v3/{org}/{project}/{repo}
  #   ssh://git@ssh.dev.azure.com/v3/{org}/{project}/{repo}
  #   {org}@vs-ssh.visualstudio.com:v3/{org}/{project}/{repo}
  if echo "$REMOTE" | grep -qE '(ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)'; then
    V3_PATH=$(echo "$REMOTE" | sed -E 's|^ssh://||; s|^[^@]+@||; s|^[^:/]+[:/]+||')
    REMOTE="https://dev.azure.com/$(echo "$V3_PATH" | cut -d/ -f2)/$(echo "$V3_PATH" | cut -d/ -f3)/_git/$(echo "$V3_PATH" | cut -d/ -f4)"
  fi

  # Strip optional "user@" basic-auth prefix and any trailing .git
  REMOTE_CLEAN=$(echo "$REMOTE" | sed -E 's|https?://[^@]+@|https://|; s|\.git$||')

  AZURE_HOST=$(echo "$REMOTE_CLEAN" | awk -F/ '{print $3}')
  PATH_PARTS=$(echo "$REMOTE_CLEAN" | awk -F/ '{for (i=4; i<=NF; i++) print $i}')

  GIT_LINE=$(echo "$PATH_PARTS" | grep -nx '_git' | head -1 | cut -d: -f1 || true)
  if [ -z "$GIT_LINE" ]; then
    echo "ERROR: not an Azure DevOps git URL (no _git segment): $REMOTE_CLEAN" >&2
    return 1
  fi
  AZURE_PROJECT=$(echo "$PATH_PARTS" | sed -n "$((GIT_LINE - 1))p")
  AZURE_REPO=$(echo    "$PATH_PARTS" | sed -n "$((GIT_LINE + 1))p")

  if [ "$AZURE_HOST" = "dev.azure.com" ]; then
    AZURE_ORG=$(echo "$PATH_PARTS" | sed -n '1p')
    PREFIX_START=2
    HOST_AND_ORG_PATH="https://dev.azure.com/${AZURE_ORG}"
  else
    # *.visualstudio.com — org is the subdomain
    AZURE_ORG=$(echo "$AZURE_HOST" | cut -d'.' -f1)
    PREFIX_START=1
    HOST_AND_ORG_PATH="https://${AZURE_HOST}"
  fi

  PROJECT_LINE=$((GIT_LINE - 1))
  if [ "$PROJECT_LINE" -gt "$PREFIX_START" ]; then
    AZURE_COLLECTION=$(echo "$PATH_PARTS" \
      | sed -n "${PREFIX_START},$((PROJECT_LINE - 1))p" \
      | tr '\n' '/' | sed 's|/$||')
  else
    AZURE_COLLECTION=""
  fi

  if [ -n "$AZURE_COLLECTION" ]; then
    API_BASE="${HOST_AND_ORG_PATH}/${AZURE_COLLECTION}/${AZURE_PROJECT}"
  else
    API_BASE="${HOST_AND_ORG_PATH}/${AZURE_PROJECT}"
  fi

  case "$AZURE_PROJECT" in
    ""|"_git"|"DefaultCollection"|"https:")
      echo "ERROR: parsed AZURE_PROJECT='${AZURE_PROJECT}' looks wrong from URL: $REMOTE_CLEAN" >&2
      return 1
      ;;
  esac
  if [ -z "$AZURE_ORG" ] || [ -z "$AZURE_REPO" ]; then
    echo "ERROR: parsed AZURE_ORG='${AZURE_ORG}' AZURE_REPO='${AZURE_REPO}' from URL: $REMOTE_CLEAN" >&2
    return 1
  fi

  export AZURE_HOST AZURE_ORG AZURE_COLLECTION AZURE_PROJECT AZURE_REPO API_BASE
  echo "Azure DevOps target: org=${AZURE_ORG} collection=${AZURE_COLLECTION:-<none>} project=${AZURE_PROJECT} repo=${AZURE_REPO}"
  echo "API_BASE=${API_BASE}"
}

write_azure_env() {
  export AZURE_HOST AZURE_ORG AZURE_COLLECTION AZURE_PROJECT AZURE_REPO API_BASE PR_ID
  {
    echo "export AZURE_HOST=$(printf %q "${AZURE_HOST:-}")"
    echo "export AZURE_ORG=$(printf %q "${AZURE_ORG:-}")"
    echo "export AZURE_COLLECTION=$(printf %q "${AZURE_COLLECTION:-}")"
    echo "export AZURE_PROJECT=$(printf %q "${AZURE_PROJECT:-}")"
    echo "export AZURE_REPO=$(printf %q "${AZURE_REPO:-}")"
    echo "export API_BASE=$(printf %q "${API_BASE:-}")"
    echo "export PR_ID=$(printf %q "${PR_ID:-}")"
  } > ${PR_STATE_DIR:-/tmp}/pr_azure.env
}
