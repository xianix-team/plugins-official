# Provider: GitHub

Use this provider when `git remote get-url origin` contains `github.com`.

## Prerequisites for posting

- **GitHub CLI** (`gh`) installed: [https://cli.github.com](https://cli.github.com)
- Authenticated: `gh auth login`, or non-interactive `GH_TOKEN` / `GITHUB-TOKEN`

**Token permissions required:**

| Permission | Access | Why |
|---|---|---|
| **Contents** | Read & Write | Read repo files, commit changes, push to branches |
| **Metadata** | Read | Access repository metadata |
| **Pull requests** | Read & Write | Fetch threads, post replies, resolve threads, open follow-up PRs |

---

## Parse Owner and Repo

```bash
REMOTE=$(git remote get-url origin)
OWNER=$(echo "$REMOTE" | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f1)
REPO=$(echo "$REMOTE"  | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f2 | sed 's|\.git$||')
```

---

## Resolve the PR Number

If the user passed a PR number, use it. Otherwise:

```bash
gh pr list --head "$(git rev-parse --abbrev-ref HEAD)" --json number --jq '.[0].number'
```

Or:

```bash
gh pr view --json number --jq '.number'
```

---

## Posting the "Resolution in Progress" Comment

```bash
gh pr comment <pr-number> --body "$(cat <<'EOF'
🔧 **PR comment resolution in progress**

I'm reviewing all unresolved threads and will apply actionable ones as commits, reply to the rest, and post a disposition summary when complete.
EOF
)"
```

If posting fails, output one warning line and continue.

---

## Fetching Unresolved Threads

Use the GitHub GraphQL API to fetch all review threads with their resolved state:

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          path
          line
          comments(first: 5) {
            nodes {
              id
              body
              author { login }
              createdAt
            }
          }
        }
      }
    }
  }
}' -F owner="$OWNER" -F repo="$REPO" -F pr=<pr-number>
```

Filter to threads where `isResolved == false`. For each unresolved thread, collect:
- `id` — the thread node ID (for resolving via mutation later)
- `comments.nodes[0].id` — the first comment ID (for posting replies)
- `comments.nodes[0].body` — the reviewer's comment text
- `path` — file path (may be null for top-level PR comments)
- `line` — line number (may be null for top-level PR comments)

If the result has more than 100 threads, paginate using the `after` cursor.

---

## Resolving a Thread

After applying a code change for an **apply** thread, mark the thread as resolved:

```bash
gh api graphql -f query='
mutation($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}' -F threadId="<thread-node-id>"
```

---

## Posting a Reply to a Thread

Reply to the first comment in a thread (for **apply** confirmations, **discuss** explanations, and **decline** justifications):

```bash
gh api repos/${OWNER}/${REPO}/pulls/comments/<first-comment-id>/replies \
  --method POST \
  --field body="<reply text>"
```

For top-level PR comments (no `path`), post as a general PR comment instead:

```bash
gh pr comment <pr-number> --body "<reply text>"
```

---

## Posting the Disposition Summary

Post the compiled summary as a PR comment:

```bash
gh pr comment <pr-number> --body "<full disposition summary from styles/report-template.md>"
```

---

## Creating a Follow-up PR (Merged PR Flow)

When the original PR was already merged:

```bash
gh pr create \
  --title "fix: apply review comments from merged PR #<original-pr-number>" \
  --body "Follow-up to #<original-pr-number>. Applies the actionable review comments that were not addressed before merge." \
  --base <base-branch> \
  --head <new-branch-name>
```

---

## Output

On completion:

```
Resolution complete on PR #<number>: <N> applied, <N> discussed, <N> declined — https://github.com/<owner>/<repo>/pull/<number>
```
