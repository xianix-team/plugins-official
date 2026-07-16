#!/usr/bin/env bash
# lib/azure-devops.sh — Azure DevOps remote-URL parsing.
#
# This is the one piece of ADO mechanics gnarly enough to need a shared, tested
# implementation: 4 URL shapes (dev.azure.com with/without a collection segment,
# visualstudio.com with/without a legacy DefaultCollection segment), plus an
# embedded basic-auth prefix some CI runners inject. Every consumer used to
# carry its own copy of this sed/awk chain; this is the single source of truth,
# covered by scripts/tests/run.sh.
#
# _ado_parse_remote_url <url> — pure function, no git dependency, so it's directly
# testable against fixture URLs without needing a real git repository.
_ado_parse_remote_url() {
  local remote="$1"
  local remote_clean host path_parts git_line prefix_start project_line

  remote_clean=$(echo "$remote" | sed -E 's|https?://[^@]+@|https://|; s|\.git$||')
  host=$(echo "$remote_clean" | awk -F/ '{print $3}')
  path_parts=$(echo "$remote_clean" | awk -F/ '{for (i=4; i<=NF; i++) print $i}')

  git_line=$(echo "$path_parts" | grep -nx '_git' | head -1 | cut -d: -f1)
  if [ -z "$git_line" ]; then
    echo "ERROR: not an Azure DevOps git URL (no _git segment): $remote_clean" >&2
    return 1
  fi

  AZURE_HOST="$host"
  AZURE_PROJECT=$(echo "$path_parts" | sed -n "$((git_line - 1))p")
  AZURE_REPO=$(echo "$path_parts" | sed -n "$((git_line + 1))p")

  if [ "$AZURE_HOST" = "dev.azure.com" ]; then
    AZURE_ORG=$(echo "$path_parts" | sed -n '1p')
    prefix_start=2
  else
    AZURE_ORG=$(echo "$AZURE_HOST" | cut -d'.' -f1)
    prefix_start=1
  fi

  project_line=$((git_line - 1))
  if [ "$project_line" -gt "$prefix_start" ]; then
    AZURE_COLLECTION=$(echo "$path_parts" \
      | sed -n "${prefix_start},$((project_line - 1))p" \
      | tr '\n' '/' | sed 's|/$||')
  else
    AZURE_COLLECTION=""
  fi

  local host_and_org_path
  if [ "$AZURE_HOST" = "dev.azure.com" ]; then
    host_and_org_path="https://dev.azure.com/${AZURE_ORG}"
  else
    host_and_org_path="https://${AZURE_HOST}"
  fi
  if [ -n "$AZURE_COLLECTION" ]; then
    API_BASE="${host_and_org_path}/${AZURE_COLLECTION}/${AZURE_PROJECT}"
  else
    API_BASE="${host_and_org_path}/${AZURE_PROJECT}"
  fi

  case "$AZURE_PROJECT" in
    ""|"_git"|"DefaultCollection"|"https:")
      echo "ERROR: parsed AZURE_PROJECT='${AZURE_PROJECT}' looks wrong from URL: $remote_clean" >&2
      return 1
      ;;
  esac
  if [ -z "$AZURE_ORG" ] || [ -z "$AZURE_REPO" ]; then
    echo "ERROR: parsed AZURE_ORG='${AZURE_ORG}' AZURE_REPO='${AZURE_REPO}' from URL: $remote_clean" >&2
    return 1
  fi

  export AZURE_HOST AZURE_ORG AZURE_COLLECTION AZURE_PROJECT AZURE_REPO API_BASE
}
