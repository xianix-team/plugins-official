# Provider: Azure DevOps

Use this provider when `git remote get-url origin` contains `dev.azure.com` or `visualstudio.com`.

## Prerequisites

The Azure DevOps REST API is called directly via `curl` using a Personal Access Token (PAT).

Required environment variable:

| Variable | Purpose |
|---|---|
| `AZURE_DEVOPS_TOKEN` | Azure DevOps PAT — must have `Code (Read)`, `Pull Request Threads (Read & Write)`, and `User Profile (Read)` scopes |

> **Note on var-name hygiene:** the variable name must be `AZURE_DEVOPS_TOKEN` (underscores). Some upstream environments export `AZURE-DEVOPS-TOKEN` (hyphens) — bash cannot reference hyphenated names, and `curl -u ":${AZURE-DEVOPS-TOKEN}"` will silently send an empty password. The plugin's `PreToolUse` hook detects this case and blocks with a clear message; if you hit it, re-export with underscores.

Optional — used to override values parsed from the remote URL:

| Variable | Default |
|---|---|
| `AZURE_ORG` | Parsed from remote URL |
| `AZURE_PROJECT` | Parsed from remote URL |
| `AZURE_REPO` | Parsed from remote URL |

---

## Parsing the Remote URL

Extract org, project, and repo from the remote URL before making any API calls. Strip any embedded basic-auth (`user@`) component first — it appears in remotes injected by CI runners.

**HTTPS format:** `https://dev.azure.com/{org}/{project}/_git/{repo}`

```bash
REMOTE=$(git remote get-url origin)

# Strip optional "user@" basic-auth prefix
REMOTE_CLEAN=$(echo "$REMOTE" | sed -E 's|https://[^@]+@|https://|')

AZURE_ORG=$(echo "$REMOTE_CLEAN"     | sed 's|https://dev.azure.com/||' | cut -d'/' -f1)
AZURE_PROJECT=$(echo "$REMOTE_CLEAN" | sed 's|https://dev.azure.com/||' | cut -d'/' -f2)
AZURE_REPO=$(echo "$REMOTE_CLEAN"    | sed 's|.*/_git/||' | sed 's|\.git$||')
```

**Legacy HTTPS format:** `https://{org}.visualstudio.com/{project}/_git/{repo}`

```bash
AZURE_ORG=$(echo "$REMOTE_CLEAN"     | sed 's|https://||' | cut -d'.' -f1)
AZURE_PROJECT=$(echo "$REMOTE_CLEAN"  | cut -d'/' -f4)
AZURE_REPO=$(echo "$REMOTE_CLEAN"    | sed 's|.*/_git/||' | sed 's|\.git$||')
```

### API Base URL

After parsing, set the API base URL to match the remote URL format. Organizations on legacy `visualstudio.com` hosts may not resolve via the `dev.azure.com` endpoint, so the base must reflect the actual host:

```bash
if [[ "$REMOTE_CLEAN" =~ \.visualstudio\.com ]]; then
  API_BASE="https://${AZURE_ORG}.visualstudio.com/${AZURE_PROJECT}"
else
  API_BASE="https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}"
fi

# Export so subsequent python heredocs can read them via os.environ
export AZURE_ORG AZURE_PROJECT AZURE_REPO API_BASE
```

Use `${API_BASE}` in place of a hardcoded host for **every** API call below.

---

## Helper: POST/PUT JSON via python (preferred over `curl -d "$(...)"` heredocs)

Nesting a bash heredoc inside `python3 -c` inside a `curl -d` command substitution is fragile — quoting bugs cost real turns. Instead, use the two-step pattern below for every write call: write the raw body to a temp file, then build and POST the payload from python.

```bash
ado_post_thread() {
  # Args:
  #   $1 = body file (markdown content for the comment)
  #   $2 = optional file path (for inline thread)
  #   $3 = optional line number (for inline thread)
  local BODY_FILE="$1" FILE_PATH="${2:-}" LINE_NUMBER="${3:-}"
  BODY_FILE="$BODY_FILE" FILE_PATH="$FILE_PATH" LINE_NUMBER="$LINE_NUMBER" \
  PR_ID="${PR_ID}" python3 - <<'PY'
import json, os, subprocess, sys
body = open(os.environ['BODY_FILE']).read()
payload = {
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {"Microsoft.TeamFoundation.Discussion.SupportsMarkdown": 1},
}
fp = os.environ.get('FILE_PATH') or ''
ln = os.environ.get('LINE_NUMBER') or ''
if fp and ln:
    payload["threadContext"] = {
        "filePath": "/" + fp.lstrip("/"),
        "rightFileStart": {"line": int(ln), "offset": 1},
        "rightFileEnd":   {"line": int(ln), "offset": 1},
    }
url = (f"{os.environ['API_BASE']}/_apis/git/repositories/"
       f"{os.environ['AZURE_REPO']}/pullrequests/{os.environ['PR_ID']}"
       f"/threads?api-version=7.1")
r = subprocess.run([
    "curl", "-sS", "-w", "\nHTTP_STATUS:%{http_code}",
    "-u", f":{os.environ['AZURE_DEVOPS_TOKEN']}",
    "-X", "POST", "-H", "Content-Type: application/json",
    url, "--data-binary", json.dumps(payload),
], capture_output=True, text=True, check=False)
out = r.stdout
status = out.rsplit("HTTP_STATUS:", 1)[-1].strip() if "HTTP_STATUS:" in out else "?"
body_out = out.rsplit("HTTP_STATUS:", 1)[0]
print(f"HTTP {status}", file=sys.stderr)
if not status.startswith("2"):
    print(body_out, file=sys.stderr)
    sys.exit(1)
PY
}
```

Usage:
- `ado_post_thread /tmp/starting.md` — generic comment thread
- `ado_post_thread /tmp/report.md` — full review report
- `ado_post_thread /tmp/finding.md path/to/file.cs 42` — inline comment

---

## Resolving the PR Number

If no PR number was passed as an argument, find the active PR for the current branch.

In a detached-HEAD worktree (which is how the Xianix Executor runs the plugin), `git rev-parse --abbrev-ref HEAD` returns the literal string `HEAD`. Resolve the source branch from `git branch --contains` instead, or pass the branch name explicitly.

```bash
if [ "$(git rev-parse --abbrev-ref HEAD)" = "HEAD" ]; then
  BRANCH=$(git branch --contains "$(git rev-parse HEAD)" \
    | sed 's|^[* ] *||' | grep -v '^(' | head -1)
else
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
fi

PR_ID=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests?searchCriteria.sourceRefName=refs/heads/${BRANCH}&searchCriteria.status=active&api-version=7.1" \
  | python3 -c "import sys,json; prs=json.load(sys.stdin)['value']; print(prs[0]['pullRequestId'] if prs else '')")
export PR_ID
```

If empty, the branch has no open PR — output a warning and skip posting.

---

## Fetching PR Metadata

The PR object on Azure DevOps is the source of truth for title, description, source/target branches, and the author display name. **Use these instead of commit messages** when building the report header — commit subjects can drift from the actual PR title.

```bash
PR_JSON=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}?api-version=7.1")

PR_TITLE=$(echo       "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('title',''))")
PR_DESC=$(echo        "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('description',''))")
PR_SOURCE=$(echo      "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sourceRefName','').replace('refs/heads/',''))")
PR_TARGET=$(echo      "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('targetRefName','').replace('refs/heads/',''))")
PR_AUTHOR=$(echo      "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('createdBy',{}).get('displayName',''))")
PR_AUTHOR_EMAIL=$(echo "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('createdBy',{}).get('uniqueName',''))")

export PR_TITLE PR_DESC PR_SOURCE PR_TARGET PR_AUTHOR PR_AUTHOR_EMAIL
```

Use `$PR_TARGET` as the **base branch** for diffs (`git diff origin/${PR_TARGET}...HEAD`) — that is authoritative, while heuristics on `origin/HEAD` are not.

---

## Markdown in PR threads

This plugin posts via the **Git** [Pull Request Threads](https://learn.microsoft.com/en-us/rest/api/azure/devops/git/pull-request-threads/create?view=azure-devops-rest-7.1) API (`.../pullrequests/.../threads`). That is **not** the same as Work Item Tracking discussion comments.

For PR threads, put Markdown in `comments[].content`. Also set thread `properties` so the web UI treats the thread as Markdown-capable (otherwise headings, tables, and emphasis can appear as raw text):

| Key | Value |
|---|---|
| `Microsoft.TeamFoundation.Discussion.SupportsMarkdown` | `1` (integer) |

The `ado_post_thread` helper above sets this on every call.

---

## Posting the Starting Comment

Before running any analysis, post a plain PR comment thread to inform the author that a review is underway. This fires as the very first action on Azure DevOps, before sub-agents are launched.

```bash
cat > /tmp/pr_starting.md <<'BODY'
**PR review in progress**

I'm running a comprehensive review covering code quality, security, test coverage, and performance. The full results will be posted as a review comment when complete — this may take a few minutes.
BODY

ado_post_thread /tmp/pr_starting.md
```

If posting the starting comment fails, output a single warning line and continue — do not stop the review.

---

## Posting the Review

### 1. Map verdict to Azure DevOps vote

| Plugin verdict | Azure DevOps vote value | Description |
|---|---|---|
| `APPROVE` | `10` | Approved |
| `REQUEST CHANGES` | `-10` | Rejected |
| `NEEDS DISCUSSION` | `-5` | Waiting for author |

### 2. Resolve the reviewer ID and post the vote

> **Important:** the documented `reviewers/me` alias does **not** work with PAT authentication — it returns an HTML error page that breaks JSON parsers. You must resolve the actual profile ID first.

```bash
# Resolve the profile ID for this PAT
REVIEWER_ID=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
  "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

if [ -z "$REVIEWER_ID" ]; then
  echo "WARN: could not resolve reviewer ID — vote will not be cast" >&2
else
  # Cast the vote (use PUT — Azure DevOps requires the reviewer to already exist on the PR;
  # if it doesn't, fall back to POST .../reviewers with the same body)
  VOTE_RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -u ":${AZURE_DEVOPS_TOKEN}" \
    -X PUT \
    -H "Content-Type: application/json" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/reviewers/${REVIEWER_ID}?api-version=7.1" \
    -d "{\"vote\": ${VOTE}, \"id\": \"${REVIEWER_ID}\"}")

  STATUS=$(echo "$VOTE_RESP" | sed -n 's/^HTTP_STATUS://p')
  if ! echo "$STATUS" | grep -qE '^2'; then
    echo "WARN: vote PUT returned HTTP $STATUS — body: $(echo "$VOTE_RESP" | sed '$d')" >&2
  fi
fi
```

### 3. Post the full report as a PR thread

```bash
# Write the compiled report to a file first — never inline a heredoc inside `curl -d`
cat > /tmp/pr_report.md <<'REPORT'
${REPORT_BODY}
REPORT

ado_post_thread /tmp/pr_report.md
```

### 4. Post inline comments (one thread per finding)

For each finding with a precise file path and line number:

```bash
# For each finding:
cat > /tmp/pr_finding.md <<'BODY'
**[CRITICAL] Sync-over-async deadlock risk**

`.GetAwaiter().GetResult()` on `GetClientAsync()` in a sync context is a well-known deadlock pattern…
BODY

ado_post_thread /tmp/pr_finding.md "Xians.Lib/Agents/Core/ActivityRegistrar.cs" 62
```

Post all inline comments without pausing between them. The helper checks HTTP status on each call and surfaces non-2xx responses to stderr, so failures are visible without crashing the run.

---

## Output

On completion:

```
Review posted on PR #<id>: <verdict> — <N> inline comments — ${API_BASE}/_git/<repo>/pullrequest/<id>
```
