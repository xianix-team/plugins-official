#!/usr/bin/env bash
# group-setup.sh — per-member setup for /pr-group-review (step G1).
#
# Why this exists as a real script: a group review runs the single-PR setup chain
# (permissions → pr-setup → detect-review-mode → review-tier → start comment) once
# per member PR, each in its own worktree and its own PR_STATE_DIR. Doing that by
# hand per member is exactly where agents cross wires between PRs.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-setup.sh"                       # reads $GROUP_FILE
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-setup.sh" <member> [<member>…]  # explicit members
#
# Explicit member forms (each repo checked out as a sibling directory under cwd,
# named by repo):
#   https://github.com/<owner>/<repo>/pull/<n>
#   https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<n>
#   <repo>#<n>            — PR number in ./<repo>
#   <repo>@<branch>       — branch vs default branch in ./<repo> (generic / local runs)
#
# Inputs:
#   GROUP_FILE              — default $PRG_WS/group.json (written by group-checkout.sh), else ./.xianix/group.json
#   PRG_ROOT                — default /tmp/prg; member state goes to $PRG_ROOT/<slug>
#   PR_REVIEWER_GROUP_FORCE — true = re-review every member even if HEAD hasn't moved
#   XIANIX_MAX_BUDGET_USD   — the run's budget (set by the Xianix agent); with
#   PR_GROUP_MIN_USD_PER_MEMBER (default 2) it decides BUDGET_MODE=normal|lean
#   GITHUB_TOKEN / AZURE_DEVOPS_TOKEN — as for /pr-review
#
# Outputs:
#   $PRG_ROOT/group.json          — normalised group (key, platform, work item, members)
#   $PRG_ROOT/group_state.json    — per-member status, paths, SHAs, mode, tier, diff size
#   $PRG_ROOT/group_state.env     — GROUP_KEY, ACTIVE_SLUGS, ACTIVE_COUNT, TOTAL_DIFF_LINES, BUDGET_MODE
#   $PRG_ROOT/<slug>/             — that member's PR_STATE_DIR (pr_state.env, diffs, …)
#   $PRG_ROOT/<slug>/setup.log    — full output of the member's setup chain
#   Prints one summary line per member. Exit 1 only when no member could be set up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRG_ROOT="${PRG_ROOT:-/tmp/prg}"
GROUP_FILE="${GROUP_FILE:-${PRG_WS:-/tmp/prg-ws}/group.json}"
[ -f "$GROUP_FILE" ] || [ $# -gt 0 ] || GROUP_FILE="$PWD/.xianix/group.json"
WORK_ROOT="$PWD"
: "${PR_REVIEWER_GROUP_FORCE:=false}"

rm -rf "$PRG_ROOT"
mkdir -p "$PRG_ROOT"

# --- 1. Normalise the group definition into $PRG_ROOT/group.json ---
python3 - "$GROUP_FILE" "$WORK_ROOT" "$PRG_ROOT/group.json" "$@" <<'PY'
import json, os, re, sys

group_file, work_root, out_path, *args = sys.argv[1:]

def slugify(name):
    return re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-") or "repo"

members = []
group = {}
if args:
    for arg in args:
        m = (re.match(r"^https?://github\.com/([^/]+)/([^/]+)/pull/(\d+)", arg)
             or re.match(r"^https?://dev\.azure\.com/[^/]+/[^/]+/_git/([^/]+)/pullrequest/(\d+)", arg)
             or re.match(r"^https?://[^/]+\.visualstudio\.com/[^/]+/_git/([^/]+)/pullrequest/(\d+)", arg))
        if m:
            repo, pr = m.groups()[-2], m.groups()[-1]
            members.append({"slug": slugify(repo), "dir": repo, "pr-number": int(pr), "pr-url": arg})
            continue
        m = re.match(r"^([^#@]+)#(\d+)$", arg)
        if m:
            members.append({"slug": slugify(m.group(1)), "dir": m.group(1), "pr-number": int(m.group(2))})
            continue
        m = re.match(r"^([^#@]+)@(.+)$", arg)
        if m:
            members.append({"slug": slugify(m.group(1)), "dir": m.group(1), "branch": m.group(2)})
            continue
        sys.exit(f"ERROR: unrecognised member '{arg}' (expected a PR URL, <repo>#<n> or <repo>@<branch>)")
    group = {"group-key": "local:" + "+".join(sorted(x["slug"] for x in members)), "source": "explicit"}
else:
    if not os.path.isfile(group_file):
        sys.exit(f"ERROR: no members given and {group_file} not found — run group-checkout.sh first, or pass PR URLs")
    raw = json.load(open(group_file, encoding="utf-8"))
    group = {k: v for k, v in raw.items() if k != "repositories"}
    group["source"] = "group.json"
    for repo in raw.get("repositories") or []:
        slug = slugify(repo.get("slug") or os.path.basename(str(repo.get("url", "")).rstrip("/")).removesuffix(".git"))
        member = {"slug": slug, "dir": repo.get("path") or slug, "url": repo.get("url", "")}
        if repo.get("pr-number") not in (None, ""):
            member["pr-number"] = int(repo["pr-number"])
        if repo.get("branch"):
            member["branch"] = repo["branch"]
        for key in ("pr-url", "title"):
            if repo.get(key):
                member[key] = repo[key]
        members.append(member)

if len(members) < 1:
    sys.exit("ERROR: group has no members")

# Two PRs in the same repo get distinct slugs (<slug>, <slug>-2, …).
seen = {}
for m in members:
    base = m["slug"]
    seen[base] = seen.get(base, 0) + 1
    if seen[base] > 1:
        m["slug"] = f"{base}-{seen[base]}"
    if not os.path.isabs(m["dir"]):
        m["dir"] = os.path.join(work_root, m["dir"])

group["members"] = members
json.dump(group, open(out_path, "w", encoding="utf-8"), indent=2)
print(f"Group {group.get('group-key', '?')}: {len(members)} member(s)")
PY

# --- 2. Run the single-PR setup chain per member ---
MEMBER_LINES=$(python3 -c "
import json, sys
g = json.load(open(sys.argv[1]))
for m in g['members']:
    print('\x1f'.join([m['slug'], m['dir'], str(m.get('pr-number', '')), m.get('branch', '')]))
" "$PRG_ROOT/group.json")

GROUP_LABEL=$(python3 -c "
import json, sys
g = json.load(open(sys.argv[1]))
title = g.get('work-item-title') or ''
url = g.get('work-item-url') or ''
n = len(g['members'])
if title and url:
    print(f'part of the group review for work item [{title}]({url}) ({n} PRs)')
elif url:
    print(f'part of the group review for {url} ({n} PRs)')
else:
    print(f'part of a group review of {n} related PRs')
" "$PRG_ROOT/group.json")

STATUS_LINES=""
# \x1f (not a tab): IFS whitespace would collapse the empty PR-number / branch fields.
while IFS=$'\x1f' read -r SLUG DIR PRN BRANCH; do
  [ -n "$SLUG" ] || continue
  STATE="$PRG_ROOT/$SLUG"
  mkdir -p "$STATE"
  LOG="$STATE/setup.log"
  STATUS=ok
  REASON=""

  if [ ! -d "$DIR" ] || ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    STATUS=excluded
    REASON="not a git checkout: $DIR"
  else
    (
      cd "$DIR"
      export PR_STATE_DIR="$STATE"
      export PR_NUMBER="$PRN"
      export BRANCH_ARG="$BRANCH"
      # The marker keeps this note from counting as a link to the work item (group_platform.py).
      export PR_REVIEWER_START_NOTE="This PR is ${GROUP_LABEL}. <!-- xianix:group-start -->"
      echo "=== check-permissions ($SLUG) ==="
      bash "$SCRIPT_DIR/check-permissions.sh" || { echo "SETUP_FAIL=permissions"; exit 3; }
      # shellcheck disable=SC1091
      [ -f "$STATE/pr_permissions.env" ] && source "$STATE/pr_permissions.env"
      # Azure DevOps: resolve the PR now (pr-setup / detect-prior read pr_azure.env), post later.
      [ "${PLATFORM:-}" = "azure" ] && { PR_REVIEWER_SKIP_START_COMMENT=true bash "$SCRIPT_DIR/ado-start-comment.sh" || true; }
      echo "=== pr-setup ($SLUG) ==="
      bash "$SCRIPT_DIR/pr-setup.sh" || { echo "SETUP_FAIL=checkout"; exit 4; }
      echo "=== detect-review-mode ($SLUG) ==="
      bash "$SCRIPT_DIR/detect-review-mode.sh" || echo "WARN: detect-review-mode failed — treating as initial review"
      echo "=== review-tier ($SLUG) ==="
      bash "$SCRIPT_DIR/review-tier.sh" || echo "WARN: review-tier failed — defaulting to haiku"

      # "Review in progress" only on members that will actually be reviewed: a member with
      # no commits since its last review is skipped (group-post.sh), unless the run is forced.
      # shellcheck disable=SC1091
      source "$STATE/pr_state.env"
      # shellcheck disable=SC1091
      [ -f "$STATE/pr_prior.env" ] && source "$STATE/pr_prior.env"
      if [ "$PR_REVIEWER_GROUP_FORCE" != "true" ] && [ "${REVIEW_MODE:-initial}" = "rereview" ] \
         && [ -n "${HEAD_SHA:-}" ] && [ "${PRIOR_SUMMARY_SHA:-}" = "${HEAD_SHA}" ]; then
        echo "=== start comment ($SLUG): skipped — no new commits since the last review ==="
      else
        echo "=== start comment ($SLUG) ==="
        case "${PLATFORM:-}" in
          github) bash "$SCRIPT_DIR/gh-start-comment.sh" || true ;;
          azure)  bash "$SCRIPT_DIR/ado-start-comment.sh" || true ;;
          *)      echo "Generic platform — skipping start comment" ;;
        esac
      fi
    ) >"$LOG" 2>&1 || {
      STATUS=excluded
      case "$(grep -o 'SETUP_FAIL=[a-z]*' "$LOG" | tail -1)" in
        SETUP_FAIL=permissions) REASON="no access (permissions check failed)" ;;
        SETUP_FAIL=checkout)    REASON="checkout failed (closed, merged, or not found)" ;;
        *)                      REASON="setup failed" ;;
      esac
    }
  fi
  STATUS_LINES+="${SLUG}"$'\t'"${STATUS}"$'\t'"${REASON}"$'\n'
done <<< "$MEMBER_LINES"

# --- 3. Summarise into group_state.json / group_state.env ---
printf '%s' "$STATUS_LINES" > "$PRG_ROOT/.status.tsv"
python3 - "$PRG_ROOT" "$PR_REVIEWER_GROUP_FORCE" <<'PY'
import json, os, shlex, sys

root, force = sys.argv[1], sys.argv[2].lower() == "true"
group = json.load(open(os.path.join(root, "group.json"), encoding="utf-8"))
status = {}
for line in open(os.path.join(root, ".status.tsv"), encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if parts and parts[0]:
        status[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else "")

def read_env(path):
    env = {}
    if not os.path.isfile(path):
        return env
    for raw in open(path, encoding="utf-8", errors="replace"):
        raw = raw.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        raw = raw.removeprefix("export ")
        key, _, value = raw.partition("=")
        try:
            parts = shlex.split(value)
            env[key] = parts[0] if parts else ""
        except ValueError:
            env[key] = value
    return env

members, active, total_lines = [], [], 0
for m in group["members"]:
    slug = m["slug"]
    state_dir = os.path.join(root, slug)
    st, reason = status.get(slug, ("excluded", "setup did not run"))
    env = read_env(os.path.join(state_dir, "pr_state.env"))
    env.update({k: v for k, v in read_env(os.path.join(state_dir, "pr_prior.env")).items() if k not in env})
    diff = os.path.join(state_dir, "pr_full_diff.patch")
    diff_lines = sum(1 for _ in open(diff, encoding="utf-8", errors="replace")) if os.path.isfile(diff) else 0
    if st == "ok" and diff_lines == 0:
        st, reason = "excluded", "no changes against the base branch"
    head = env.get("HEAD_SHA", "")
    unchanged = (not force and env.get("REVIEW_MODE") == "rereview"
                 and head and env.get("PRIOR_SUMMARY_SHA") == head)
    entry = {
        "slug": slug, "dir": m["dir"], "state_dir": state_dir, "status": st, "reason": reason,
        "platform": env.get("PLATFORM", ""), "pr_number": env.get("PR_NUMBER", "") or m.get("pr-number", ""),
        "branch": m.get("branch", ""), "pr_url": m.get("pr-url", ""), "title": env.get("PR_TITLE", "") or m.get("title", ""),
        "head_sha": head, "base": env.get("BASE", ""), "review_mode": env.get("REVIEW_MODE", "initial") or "initial",
        "review_tier": env.get("REVIEW_TIER", "haiku") or "haiku", "changed_count": env.get("CHANGED_COUNT", ""),
        "diff_lines": diff_lines, "unchanged_since_last_review": bool(unchanged),
    }
    members.append(entry)
    if st == "ok":
        active.append(slug)
        total_lines += diff_lines

state = {k: v for k, v in group.items() if k != "members"}
state.update({"members": members, "active": active, "total_diff_lines": total_lines,
              "changed_active": [m["slug"] for m in members if m["status"] == "ok" and not m["unchanged_since_last_review"]]})
# The run has one fixed budget. When it is thin for the number of PRs to review (plus the
# cross-repo pass), review in "lean" mode: the cheaper finder tier for every member.
to_review = len(active) if force else len(state["changed_active"])
try:
    budget = float(os.environ.get("XIANIX_MAX_BUDGET_USD") or 0)
except ValueError:
    budget = 0.0
min_per = float(os.environ.get("PR_GROUP_MIN_USD_PER_MEMBER") or 2)
budget_mode = "lean" if budget > 0 and to_review and budget / (to_review + 1) < min_per else "normal"
state["budget_mode"] = budget_mode
json.dump(state, open(os.path.join(root, "group_state.json"), "w", encoding="utf-8"), indent=2)

with open(os.path.join(root, "group_state.env"), "w", encoding="utf-8") as f:
    f.write(f"GROUP_KEY={shlex.quote(str(group.get('group-key', '')))}\n")
    f.write(f"ACTIVE_SLUGS={shlex.quote(' '.join(active))}\n")
    f.write(f"ACTIVE_COUNT={len(active)}\n")
    f.write(f"CHANGED_COUNT={len(state['changed_active'])}\n")
    f.write(f"TOTAL_DIFF_LINES={total_lines}\n")
    f.write(f"BUDGET_MODE={budget_mode}\n")

for e in members:
    if e["status"] == "ok":
        flag = " (unchanged since last review)" if e["unchanged_since_last_review"] else ""
        target = f"PR #{e['pr_number']}" if e["pr_number"] else f"branch {e['branch']}"
        print(f"  ✓ {e['slug']:<20} {target:<14} head={e['head_sha'][:8]} mode={e['review_mode']} "
              f"tier={e['review_tier']} diff={e['diff_lines']} lines{flag}")
    else:
        print(f"  ✗ {e['slug']:<20} excluded — {e['reason']} (see {e['state_dir']}/setup.log)")
print(f"ACTIVE_COUNT={len(active)} CHANGED_COUNT={len(state['changed_active'])} TOTAL_DIFF_LINES={total_lines} BUDGET_MODE={budget_mode}")
if not active:
    sys.exit(1)
PY
