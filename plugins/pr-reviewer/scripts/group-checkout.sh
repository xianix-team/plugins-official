#!/usr/bin/env bash
# group-checkout.sh — give every member PR its own checkout (step D3).
#
# Why this exists: the container the agent starts holds only one repository. A group
# review needs every member PR's repo, so this script fetches them itself, one folder per
# member PR, and writes the group.json that group-setup.sh reads.
#
# Repos are kept in a cache on the persistent volume the agent mounts (next to its own
# xianix-claude-config and xianix-runtimes folders), so the next group run only fetches
# what changed. Without a writable volume it falls back to fresh partial clones in /tmp.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-checkout.sh"
#
# Inputs:
#   $PRG_WS/discovery.json (from group-discover.sh)
#   GITHUB_TOKEN / AZURE_DEVOPS_TOKEN — used only when git has no credentials configured yet
#   PR_GROUP_CACHE_DIR       — cache folder (default ${REPO_DIR:-/workspace/repo}/xianix-group-cache
#                              when writable; "none" = no cache)
#   PR_GROUP_CACHE_DAYS      — drop cached repos unused for this many days (default 14)
#
# Outputs:
#   $PRG_WS/repos/<slug>/  — a checkout per member PR (pr-setup.sh checks out the PR head later)
#   $PRG_WS/group.json     — { group-key, platform, work-item-*, repositories: [{slug, url, path, pr-number, …}] }
#   One line per member. Exit 1 if no member could be checked out.

set -euo pipefail

export PRG_WS="${PRG_WS:-/tmp/prg-ws}"
DISCOVERY="$PRG_WS/discovery.json"
[ -f "$DISCOVERY" ] || { echo "ERROR: $DISCOVERY not found — run group-discover.sh first" >&2; exit 1; }
mkdir -p "$PRG_WS/repos"

PLATFORM=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['platform'])" "$DISCOVERY")

# Credentials. The executor configures git for the repo it cloned; with no repository
# (an Azure DevOps work-item event) it has not. Then add them to this container's global
# git config — never to the cached repos, which live on the persistent volume.
case "$PLATFORM" in
  github)
    if [ -z "$(git config --global --get credential.helper 2>/dev/null || true)" ] && [ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]; then
      CRED="$PRG_WS/.git-credentials"
      printf 'https://x-access-token:%s@github.com\n' "$(printf '%s' "${GITHUB_TOKEN:-${GH_TOKEN:-}}" | tr -d '[:space:]')" > "$CRED"
      chmod 600 "$CRED"
      git config --global credential.helper "store --file=$CRED"
    fi
    ;;
  azure)
    if [ -z "$(git config --global --get-regexp '^http\..*extraheader' 2>/dev/null || true)" ] && [ -n "${AZURE_DEVOPS_TOKEN:-}" ]; then
      B64=$(printf ':%s' "$(printf '%s' "$AZURE_DEVOPS_TOKEN" | tr -d '[:space:]')" | base64 | tr -d '\n')
      git config --global http.https://dev.azure.com/.extraHeader "Authorization: Basic $B64"
      for host in $(python3 -c "
import json, re, sys
for m in json.load(open(sys.argv[1]))['members']:
    h = re.match(r'https://([^./]+\.visualstudio\.com)/', m['clone-url'])
    if h: print(h.group(1))
" "$DISCOVERY" | sort -u); do
        git config --global "http.https://$host/.extraHeader" "Authorization: Basic $B64"
      done
    fi
    ;;
esac

# Cache folder on the persistent volume, if there is a writable one.
CACHE="${PR_GROUP_CACHE_DIR:-}"
if [ -z "$CACHE" ]; then
  VOL="${REPO_DIR:-/workspace/repo}"
  [ -d "$VOL" ] && [ -w "$VOL" ] && CACHE="$VOL/xianix-group-cache"
fi
[ "$CACHE" = "none" ] && CACHE=""
if [ -n "$CACHE" ]; then
  mkdir -p "$CACHE" 2>/dev/null || CACHE=""
fi
if [ -n "$CACHE" ]; then
  # Forget repos no group has used for a while.
  find "$CACHE" -mindepth 1 -maxdepth 1 -name '*.git' -type d \
    -mtime +"${PR_GROUP_CACHE_DAYS:-14}" -exec rm -rf {} + 2>/dev/null || true
fi

# One bare repo per remote in the cache. Partial (no file contents until needed), with
# branches only — pr-setup.sh fetches the PR head itself.
cached_repo() {  # cached_repo <url> <name> -> prints the bare repo path
  local url="$1" name="$2" bare
  bare="$CACHE/$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_').git"
  if [ ! -d "$bare" ]; then
    git init -q --bare "$bare"
    git -C "$bare" remote add origin "$url"
    git -C "$bare" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git -C "$bare" config remote.origin.promisor true
    git -C "$bare" config remote.origin.partialclonefilter blob:none
  fi
  git -C "$bare" worktree prune --expire=12.hours.ago 2>/dev/null || true
  git -C "$bare" fetch -q --prune --filter=blob:none origin >&2
  git -C "$bare" remote set-head origin -a >/dev/null 2>&1 || true
  touch "$bare"
  echo "$bare"
}

MEMBERS=$(python3 -c "
import json, sys
for m in json.load(open(sys.argv[1]))['members']:
    print('\x1f'.join([m['slug'], m['clone-url'], m['repo'], str(m['pr-number'])]))
" "$DISCOVERY")

OK_SLUGS=""
# \x1f (not a tab) so an empty field never shifts the others.
while IFS=$'\x1f' read -r SLUG URL REPO PRN; do
  [ -n "$SLUG" ] || continue
  DEST="$PRG_WS/repos/$SLUG"
  ERR="$PRG_WS/$SLUG.clone.err"
  if [ -e "$DEST/.git" ]; then
    # A second pass in the same container: the checkout is there, just refresh it.
    if git -C "$DEST" fetch -q --prune origin 2>"$ERR"; then
      echo "  ✓ $SLUG  $REPO #$PRN  (refreshed)"; OK_SLUGS+="$SLUG "
    else
      echo "  ✗ $SLUG  $REPO #$PRN  fetch failed (see $ERR)"
    fi
    continue
  fi
  if [ -n "$CACHE" ]; then
    if BARE=$(cached_repo "$URL" "$REPO" 2>"$ERR") \
       && START=$(git -C "$BARE" symbolic-ref -q refs/remotes/origin/HEAD \
                  || git -C "$BARE" for-each-ref --count=1 --format='%(refname)' refs/remotes/origin/) \
       && [ -n "$START" ] \
       && git -C "$BARE" worktree add -q --detach "$DEST" "$START" 2>>"$ERR"; then
      echo "  ✓ $SLUG  $REPO #$PRN  (cached)"; OK_SLUGS+="$SLUG "
      continue
    fi
    rm -rf "$DEST"
    echo "  … $SLUG  cache unusable, cloning instead (see $ERR)" >&2
  fi
  if git clone -q --filter=blob:none --no-tags "$URL" "$DEST" 2>>"$ERR"; then
    echo "  ✓ $SLUG  $REPO #$PRN"; OK_SLUGS+="$SLUG "
  else
    echo "  ✗ $SLUG  $REPO #$PRN  clone failed (see $ERR)"
  fi
done <<< "$MEMBERS"

python3 - "$DISCOVERY" "$PRG_WS" "$OK_SLUGS" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
ws, ok = sys.argv[2], set(sys.argv[3].split())
wi = d.get("work-item") or {}
group = {
    "group-key": d.get("group-key", ""), "platform": d["platform"],
    "work-item-ref": wi.get("ref", ""), "work-item-title": wi.get("title", ""), "work-item-url": wi.get("url", ""),
    "repositories": [
        {"slug": m["slug"], "url": m["clone-url"], "path": os.path.join(ws, "repos", m["slug"]),
         "pr-number": m["pr-number"], "pr-url": m.get("pr-url", ""), "title": m.get("title", "")}
        for m in d["members"] if m["slug"] in ok
    ],
}
json.dump(group, open(os.path.join(ws, "group.json"), "w", encoding="utf-8"), indent=2)
print(f"Checked out {len(group['repositories'])} of {len(d['members'])} member(s) -> {os.path.join(ws, 'group.json')}")
sys.exit(0 if group["repositories"] else 1)
PY
