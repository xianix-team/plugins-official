#!/usr/bin/env python3
"""group_platform.py — GitHub / Azure DevOps API work for /pr-group-review.

Why this exists: a group review has to find the work item, the PRs linked to it, tell
each member PR it is part of the group and keep a lock on the work item — all before any review
starts, and without help from the agent that started the container. Doing this in one
tested file keeps the bash scripts and the command playbook small.

Called by the group-*.sh scripts, not directly:
  group_platform.py discover   --work-item REF | --pr N   [--force]
  group_platform.py announce
  group_platform.py lock acquire | heartbeat | release | next

Where the group's state lives (lock owner, heartbeat, the commit each PR was reviewed at):
  GitHub        — a hidden git ref, refs/xianix/pr-group/issue-<N>, in the work item's repo.
                  Moving a ref is compare-and-set, so two runs can never both take the lock.
                  If the token may not write refs there, a state comment on the issue is used.
  Azure DevOps  — a state comment on the work item (best effort: write, then read back).

Files (all under $PRG_WS, default /tmp/prg-ws):
  discovery.json  — the group: work item, members, newest push time
  run.env         — RUN_ID, FORCE, STARTED, PASS, PASS_STARTED for the other steps

Settings (env, all optional):
  PR_GROUP_LABEL            ai-dlc/pr/group-review   label/tag on the work item
  PR_GROUP_MAX_MEMBERS      6
  PR_GROUP_PLANNING_REPO    ""   GitHub: only issues in this owner/repo can be a work item
  PR_GROUP_ALLOWED_OWNERS   ""   GitHub: extra owners (comma separated) besides the PR's own
  PR_GROUP_LOCK_TTL_SECONDS 2100 a lock older than this (no heartbeat) is taken over
  PR_GROUP_LOCK_VERIFY_SECONDS 3 comment store only: wait before reading the lock back
  PR_GROUP_STATE_STORE      auto auto | ref | comment
  PR_GROUP_TIME_LIMIT_SECONDS 1500 time this container may spend; another pass only if it fits
  PR_GROUP_MAX_PASSES       2    reviews in one container before handing over to a new run
  GITHUB_TOKEN / AZURE_DEVOPS_TOKEN
  GITHUB_API_URL (https://api.github.com), GITHUB_GRAPHQL_URL ({api}/graphql) — for tests
"""

import base64
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

WS = os.environ.get("PRG_WS", "/tmp/prg-ws")
GROUP_LABEL = os.environ.get("PR_GROUP_LABEL", "ai-dlc/pr/group-review").strip()
MAX_MEMBERS = max(1, int(os.environ.get("PR_GROUP_MAX_MEMBERS", "6") or 6))
PLANNING_REPO = os.environ.get("PR_GROUP_PLANNING_REPO", "").strip()
ALLOWED_OWNERS = {o.strip().lower() for o in os.environ.get("PR_GROUP_ALLOWED_OWNERS", "").split(",") if o.strip()}
LOCK_TTL = int(os.environ.get("PR_GROUP_LOCK_TTL_SECONDS", "2100") or 2100)
LOCK_VERIFY = float(os.environ.get("PR_GROUP_LOCK_VERIFY_SECONDS", "3") or 3)
STATE_STORE = os.environ.get("PR_GROUP_STATE_STORE", "auto").strip().lower()
TIME_LIMIT = int(os.environ.get("PR_GROUP_TIME_LIMIT_SECONDS", "1500") or 1500)
MAX_PASSES = max(1, int(os.environ.get("PR_GROUP_MAX_PASSES", "2") or 2))
GH_API = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
GH_GRAPHQL = os.environ.get("GITHUB_GRAPHQL_URL", GH_API + "/graphql")
MAX_WORK_ITEMS_PER_PR = 5
MAX_TIMELINE = 100
MAX_ISSUE_PR_LINKS = 20  # PR links read from the issue description and comments

STATE_MARKER = "xianix:pr-group-state"
FOLLOW_UP_MARKER = "xianix:group-follow-up"
MEMBER_MARKER = "xianix:group-member"  # on the note that tells a PR it is in a group
OWN_MARKER = "xianix:"  # every comment the plugin writes carries one; such comments are not links

GITHUB, AZURE = "github", "azure"


# ── small helpers ────────────────────────────────────────────────────────────

def now():
    return dt.datetime.now(dt.timezone.utc)


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(s):
    if not s:
        return None
    try:
        return dt.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None


def log(msg):
    print(msg, file=sys.stderr)


def token(platform):
    name = "GITHUB_TOKEN" if platform == GITHUB else "AZURE_DEVOPS_TOKEN"
    value = (os.environ.get(name) or (os.environ.get("GH_TOKEN") if platform == GITHUB else "") or "").strip()
    if not value:
        sys.exit(f"ERROR: {name} is not set — group review needs it to read the work item and PRs")
    return value


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status


def http(method, url, platform, body=None, accept="application/json"):
    headers = {"Accept": accept, "User-Agent": "xianix-pr-group-reviewer"}
    tok = token(platform)
    if platform == GITHUB:
        headers["Authorization"] = f"Bearer {tok}"
    else:
        headers["Authorization"] = "Basic " + base64.b64encode(f":{tok}".encode()).decode()
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        raise ApiError(e.code, detail) from None


def graphql(query, variables):
    data = http("POST", GH_GRAPHQL, GITHUB, {"query": query, "variables": variables})
    if data.get("errors"):
        raise ApiError(200, "; ".join(e.get("message", "?") for e in data["errors"]))
    return data.get("data") or {}


def slugify(name):
    return re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-") or "repo"


def assign_slugs(members):
    seen = {}
    for m in members:
        base = slugify(m["repo"].split("/")[-1])
        seen[base.lower()] = seen.get(base.lower(), 0) + 1
        n = seen[base.lower()]
        m["slug"] = base if n == 1 else f"{base}-{n}"
    return members


def normalize_url(url):
    u = re.sub(r"^https://[^@/]+@", "https://", (url or "").strip())
    return (u[:-4] if u.lower().endswith(".git") else u.rstrip("/")).lower()


def git_origin():
    try:
        return subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True,
                              timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def write_json(name, obj):
    os.makedirs(WS, exist_ok=True)
    with open(os.path.join(WS, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)


def read_json(name):
    with open(os.path.join(WS, name), encoding="utf-8") as f:
        return json.load(f)


# ── reference parsing (pure functions, unit-tested) ──────────────────────────

GH_REPO_RE = re.compile(r"github\.com[/:](?P<owner>[A-Za-z0-9_.-]+)/(?P<repo>[A-Za-z0-9_.-]+?)(?:\.git)?(?:[/?#]|$)", re.I)
ISSUE_REF_RE = re.compile(
    r"(?:https://github\.com/(?P<o1>[A-Za-z0-9_.-]+)/(?P<r1>[A-Za-z0-9_.-]+)/issues/(?P<n1>\d+))"
    r"|(?:(?<![\w/.-])(?P<o2>[A-Za-z0-9_.-]+)/(?P<r2>[A-Za-z0-9_.-]+)#(?P<n2>\d+))", re.I)
BARE_REF_RE = re.compile(r"(?<![\w/#&.-])#(?P<n>\d+)\b")
PR_URL_RE = re.compile(r"https://github\.com/(?P<o>[A-Za-z0-9_.-]+)/(?P<r>[A-Za-z0-9_.-]+)/pull/(?P<n>\d+)", re.I)
ADO_REPO_RE = re.compile(
    r"^https://(?:[^@/]+@)?(?:dev\.azure\.com/(?P<org>[^/]+)|(?P<org2>[^./]+)\.visualstudio\.com(?:/DefaultCollection)?)"
    r"/(?P<project>[^/]+)/_git/(?P<repo>[^/?#]+)", re.I)
ADO_WI_RE = re.compile(
    r"^https://(?:[^@/]+@)?(?:dev\.azure\.com/(?P<org>[^/]+)|(?P<org2>[^./]+)\.visualstudio\.com(?:/DefaultCollection)?)"
    r"/(?:[^/]+/)?(?:_apis/wit/workItems|_workitems/edit)/(?P<id>\d+)", re.I)


def parse_github_repo(url):
    m = GH_REPO_RE.search(url or "")
    return (m.group("owner"), m.group("repo")) if m else None


def find_issue_refs(text, current_repo):
    """Issue references in a PR description: owner/repo#12, issue URLs, and #12 (= current repo)."""
    found = []

    def add(repo, n):
        n = int(n)
        if n > 0 and not any(r == repo.lower() and x == n for r, x in found):
            found.append((repo.lower(), n))

    for m in ISSUE_REF_RE.finditer(text or ""):
        owner, repo, n = (m.group("o1"), m.group("r1"), m.group("n1")) if m.group("n1") else (m.group("o2"), m.group("r2"), m.group("n2"))
        add(f"{owner}/{repo}", n)
    for m in BARE_REF_RE.finditer(text or ""):
        add(current_repo, m.group("n"))
    return found


def find_pr_refs(text, current_repo):
    """Possible PR references in an issue description or comment: PR URLs, owner/repo#12, #12.
    owner/repo#12 and #12 may be issues; the caller resolves them."""
    found = [(m.group("o").lower() + "/" + m.group("r").lower(), int(m.group("n"))) for m in PR_URL_RE.finditer(text or "")]
    for ref in find_issue_refs(PR_URL_RE.sub(" ", text or ""), current_repo):
        if ref not in found:
            found.append(ref)
    return found


def link_texts(bodies):
    """Text that can hold links: everything except the plugin's own comments."""
    return [b for b in bodies if b and OWN_MARKER not in b]


def still_mentions(pr, issue_repo, number):
    """A PR that mentioned the issue (cross-reference) stays linked only while its description,
    a comment or a recent commit message still references it. GitHub keeps the event when the
    reference is deleted."""
    repo = (pr.get("repository") or {}).get("nameWithOwner", "")
    texts = link_texts([pr.get("body") or ""] + [c.get("body") or "" for c in (pr.get("comments") or {}).get("nodes") or []]
                       + [(c.get("commit") or {}).get("message") or "" for c in (pr.get("refCommits") or {}).get("nodes") or []])
    target = (issue_repo.lower(), int(number))
    return any(target in find_issue_refs(t, repo) for t in texts)


def ado_base(org, org2):
    return f"https://dev.azure.com/{org}" if org else f"https://{org2}.visualstudio.com"


def parse_ado_repo(url):
    m = ADO_REPO_RE.match(url or "")
    if not m:
        return None
    return {"base": ado_base(m.group("org"), m.group("org2")), "org": (m.group("org") or m.group("org2")).lower(),
            "project": urllib.parse.unquote(m.group("project")), "repo": urllib.parse.unquote(m.group("repo"))}


def parse_ado_work_item(ref):
    m = ADO_WI_RE.match(ref or "")
    if not m:
        return None
    return {"base": ado_base(m.group("org"), m.group("org2")), "org": (m.group("org") or m.group("org2")).lower(),
            "id": int(m.group("id"))}


def split_tags(tags):
    return [t.strip() for t in (tags or "").split(";") if t.strip()]


def has_label(names, label):
    return any(n.strip().lower() == label.lower() for n in names)


def select_members(linked, max_members, trigger=None):
    """Open PRs oldest first, up to max_members, always keeping the trigger PR. Returns (members, left_out)."""
    distinct = {}
    for pr in linked:
        distinct.setdefault((pr["repo"].lower(), pr["pr-number"]), pr)
    prs = list(distinct.values())
    open_prs = sorted([p for p in prs if p["state"] == "open"],
                      key=lambda p: (p.get("created-at") or "9999", p["pr-number"]))
    kept = open_prs[:max_members]
    if trigger:
        is_trigger = lambda p: p["repo"].lower() == trigger[0].lower() and p["pr-number"] == trigger[1]
        t = next((p for p in open_prs if is_trigger(p)), None)
        if t and t not in kept:
            kept[-1] = t
    left_out = [p for p in prs if p not in kept]
    return assign_slugs(kept), left_out


def apply_timeline(nodes):
    """Linked PRs after replaying the issue timeline in order: connect / mention add, disconnect removes."""
    linked = {}
    for node in nodes:
        kind = node.get("__typename")
        pr = node.get("source") if kind == "CrossReferencedEvent" else node.get("subject")
        if not pr or pr.get("number") is None or not (pr.get("repository") or {}).get("nameWithOwner"):
            continue  # an issue, not a PR
        key = (pr["repository"]["nameWithOwner"].lower(), int(pr["number"]))
        if kind == "DisconnectedEvent":
            linked.pop(key, None)
        else:
            linked[key] = pr
    return list(linked.values())


# ── GitHub ───────────────────────────────────────────────────────────────────

GH_PR_FIELDS = """
  number url title state createdAt headRefOid
  repository { nameWithOwner url }
  commits(last: 1) { nodes { commit { committedDate } } }
  forcePushes: timelineItems(last: 1, itemTypes: [HEAD_REF_FORCE_PUSHED_EVENT]) {
    nodes { ... on HeadRefForcePushedEvent { createdAt } }
  }
"""

GH_ISSUE_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      number title url body
      labels(first: 50) { nodes { name } }
      comments(last: 100) { nodes { body } }
      timelineItems(first: %d, itemTypes: [CONNECTED_EVENT, DISCONNECTED_EVENT, CROSS_REFERENCED_EVENT]) {
        nodes {
          __typename
          ... on ConnectedEvent { subject { ... on PullRequest { ...pr } } }
          ... on DisconnectedEvent { subject { ... on PullRequest { ...pr } } }
          ... on CrossReferencedEvent { source { ... on PullRequest { ...pr ...refText } } }
        }
      }
    }
  }
}
fragment pr on PullRequest { %s }
fragment refText on PullRequest {
  body
  comments(last: 50) { nodes { body } }
  refCommits: commits(last: 50) { nodes { commit { message } } }
}
""" % (MAX_TIMELINE, GH_PR_FIELDS)

GH_ITEM_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issueOrPullRequest(number: $number) { __typename ... on PullRequest { %s } }
  }
}
""" % GH_PR_FIELDS

GH_PR_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      body
      closingIssuesReferences(first: 10) { nodes { number repository { nameWithOwner } } }
      %s
    }
  }
}
""" % GH_PR_FIELDS


def gh_member(pr):
    last_commit = ((pr.get("commits") or {}).get("nodes") or [{}])[-1].get("commit", {}).get("committedDate")
    force = ((pr.get("forcePushes") or {}).get("nodes") or [{}])[-1].get("createdAt")
    pushes = [t for t in (parse_time(last_commit), parse_time(force)) if t]
    name = pr["repository"]["nameWithOwner"]
    state = (pr.get("state") or "").lower()
    return {
        "platform": GITHUB, "repo": name, "pr-number": int(pr["number"]), "pr-url": pr.get("url", ""),
        "clone-url": (pr["repository"].get("url") or f"https://github.com/{name}") + ".git",
        "title": pr.get("title", ""), "state": "open" if state == "open" else ("merged" if state == "merged" else "closed"),
        "head-sha": pr.get("headRefOid", ""), "created-at": pr.get("createdAt", ""),
        "last-push-at": iso(max(pushes)) if pushes else "",
    }


def gh_read_issue(repo, number, trigger=None):
    owner, name = repo.split("/", 1)
    data = graphql(GH_ISSUE_QUERY, {"owner": owner, "name": name, "number": int(number)})
    issue = (data.get("repository") or {}).get("issue")
    if not issue:
        raise ApiError(404, f"issue {repo}#{number} not found")
    labels = [l["name"] for l in issue["labels"]["nodes"]]
    allowed = ALLOWED_OWNERS | {owner.lower()}
    linked, notes = [], []
    nodes = [n for n in issue["timelineItems"]["nodes"]
             if n.get("__typename") != "CrossReferencedEvent" or not (n.get("source") or {}).get("number")
             or still_mentions(n["source"], repo, number)]
    prs = apply_timeline(nodes)
    prs += gh_issue_pr_links(issue, repo, number, prs, allowed, notes)
    for pr in prs:
        m = gh_member(pr)
        if m["repo"].split("/")[0].lower() not in allowed:
            notes.append(f"{m['repo']} #{m['pr-number']}: skipped (owner not allowed)")
            continue
        linked.append(m)
    members, left_out = select_members(linked, MAX_MEMBERS, trigger)
    return {
        "platform": GITHUB,
        "group-key": f"wi:github:{repo.lower()}#{number}",
        "work-item": {"ref": f"{repo}#{number}", "repository": repo, "id": int(number), "url": issue.get("url", ""),
                      "title": issue.get("title", ""), "body": issue.get("body", ""),
                      "labelled": has_label(labels, GROUP_LABEL)},
        "members": members, "others": left_out, "notes": notes,
    }


def gh_issue_pr_links(issue, repo, number, known, allowed, notes):
    """PRs linked by writing them in the issue description or a comment (not the plugin's own)."""
    texts = link_texts([issue.get("body") or ""] + [c.get("body") or "" for c in (issue.get("comments") or {}).get("nodes") or []])
    seen = {(p["repository"]["nameWithOwner"].lower(), int(p["number"])) for p in known} | {(repo.lower(), int(number))}
    refs = []
    for t in texts:
        refs += [r for r in find_pr_refs(t, repo) if r not in seen and r not in refs]
    found = []
    for r_repo, n in refs[:MAX_ISSUE_PR_LINKS]:
        if r_repo.split("/")[0] not in allowed:
            notes.append(f"{r_repo} #{n}: skipped (owner not allowed)")
            continue
        o, name = r_repo.split("/", 1)
        try:
            item = (graphql(GH_ITEM_QUERY, {"owner": o, "name": name, "number": n}).get("repository") or {}).get("issueOrPullRequest")
        except ApiError as e:
            log(f"note: {r_repo}#{n} in the issue skipped ({e})")
            continue
        if item and item.get("__typename") == "PullRequest":
            found.append(item)
    return found


def gh_discover_from_pr(pr_number, repo_url):
    parsed = parse_github_repo(repo_url)
    if not parsed:
        sys.exit(f"ERROR: not a GitHub repository: {repo_url!r}")
    owner, name = parsed
    data = graphql(GH_PR_QUERY, {"owner": owner, "name": name, "number": int(pr_number)})
    pr = (data.get("repository") or {}).get("pullRequest")
    if not pr:
        sys.exit(f"ERROR: PR {owner}/{name}#{pr_number} not found")
    me = gh_member(pr)
    refs = find_issue_refs(pr.get("body"), f"{owner}/{name}")
    for n in pr["closingIssuesReferences"]["nodes"]:
        key = (n["repository"]["nameWithOwner"].lower(), int(n["number"]))
        if key not in refs:
            refs.append(key)
    allowed = ALLOWED_OWNERS | {owner.lower()}
    cands = [r for r in refs
             if (r[0] == PLANNING_REPO.lower() if PLANNING_REPO else r[0].split("/")[0] in allowed)
             and not (r[0] == f"{owner}/{name}".lower() and r[1] == int(pr_number))][:MAX_WORK_ITEMS_PER_PR]
    groups = []
    for repo, n in cands:
        try:
            groups.append(gh_read_issue(repo, n, trigger=(me["repo"], me["pr-number"])))
        except ApiError as e:
            log(f"note: {repo}#{n} skipped ({e})")  # a PR number, or no access
    return choose_group(groups, me)


def gh_pr_comment(member, body):
    owner, name = member["repo"].split("/", 1)
    http("POST", f"{GH_API}/repos/{owner}/{name}/issues/{member['pr-number']}/comments", GITHUB, {"body": body})


def gh_pr_comments(member):
    owner, name = member["repo"].split("/", 1)
    out, page = [], 1
    while page <= 10:
        batch = http("GET", f"{GH_API}/repos/{owner}/{name}/issues/{member['pr-number']}/comments?per_page=100&page={page}", GITHUB)
        out += [c.get("body") or "" for c in batch]
        if len(batch) < 100:
            break
        page += 1
    return out


def gh_state_comments(wi):
    owner, name = wi["repository"].split("/", 1)
    out, page = [], 1
    while page <= 10:
        batch = http("GET", f"{GH_API}/repos/{owner}/{name}/issues/{wi['id']}/comments?per_page=100&page={page}", GITHUB)
        out += [{"id": c["id"], "body": c.get("body") or ""} for c in batch if STATE_MARKER in (c.get("body") or "")]
        if len(batch) < 100:
            break
        page += 1
    return sorted(out, key=lambda c: c["id"])


def gh_write_state(wi, comment_id, body):
    owner, name = wi["repository"].split("/", 1)
    if comment_id:
        http("PATCH", f"{GH_API}/repos/{owner}/{name}/issues/comments/{comment_id}", GITHUB, {"body": body})
        return comment_id
    return http("POST", f"{GH_API}/repos/{owner}/{name}/issues/{wi['id']}/comments", GITHUB, {"body": body})["id"]


def gh_delete_comment(wi, comment_id):
    owner, name = wi["repository"].split("/", 1)
    http("DELETE", f"{GH_API}/repos/{owner}/{name}/issues/comments/{comment_id}", GITHUB)


GH_LABELS_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { issue(number: $number) { labels(first: 50) { nodes { name } } } }
}
"""


def gh_work_item_labelled(wi):
    owner, name = wi["repository"].split("/", 1)
    issue = (graphql(GH_LABELS_QUERY, {"owner": owner, "name": name, "number": int(wi["id"])}).get("repository") or {}).get("issue")
    return bool(issue) and has_label([l["name"] for l in issue["labels"]["nodes"]], GROUP_LABEL)


class RefUnsupported(Exception):
    """The token may not create refs in the work item's repo — use the comment store."""


def gh_ref_path(wi):
    return f"xianix/pr-group/issue-{wi['id']}"


def gh_ref_read(wi):
    owner, name = wi["repository"].split("/", 1)
    try:
        ref = http("GET", f"{GH_API}/repos/{owner}/{name}/git/ref/{gh_ref_path(wi)}", GITHUB)
    except ApiError as e:
        if e.status == 404:
            return None, None
        raise
    sha = ref["object"]["sha"]
    commit = http("GET", f"{GH_API}/repos/{owner}/{name}/git/commits/{sha}", GITHUB)
    message = commit.get("message", "")
    return sha, message[message.find("{"):] if "{" in message else ""


def gh_ref_cas(wi, expected_sha, summary, payload):
    """Point the state ref at a new commit holding `payload`, only if it still points at
    `expected_sha` (None = must not exist yet). False when another run moved it first."""
    owner, name = wi["repository"].split("/", 1)
    repo_api = f"{GH_API}/repos/{owner}/{name}/git"
    try:
        tree = http("POST", f"{repo_api}/trees", GITHUB,
                    {"tree": [{"path": "state.json", "mode": "100644", "type": "blob", "content": payload}]})["sha"]
        commit = http("POST", f"{repo_api}/commits", GITHUB,
                      {"message": f"{summary}\n\n{payload}", "tree": tree, "parents": [expected_sha] if expected_sha else []})["sha"]
    except ApiError as e:
        if e.status in (403, 404, 422):
            raise RefUnsupported(str(e)) from None
        raise
    if expected_sha is None:
        try:
            http("POST", f"{repo_api}/refs", GITHUB, {"ref": f"refs/{gh_ref_path(wi)}", "sha": commit})
            return True
        except ApiError as e:
            if e.status != 422:
                raise RefUnsupported(str(e)) from None
            if gh_ref_read(wi)[0]:
                return False  # another run created it first
            raise RefUnsupported(str(e)) from None
    try:
        # force=false: GitHub only moves the ref if the new commit descends from where it
        # points now — i.e. nobody else moved it since we read it.
        http("PATCH", f"{repo_api}/refs/{gh_ref_path(wi)}", GITHUB, {"sha": commit, "force": False})
        return True
    except ApiError as e:
        if e.status in (409, 422):
            return False
        raise


# ── Azure DevOps ─────────────────────────────────────────────────────────────

ADO_API = "api-version=7.1"
ADO_COMMENTS_API = "api-version=7.1-preview.4"


def ado_member(base, pr, iterations=None):
    repo = pr.get("repository") or {}
    status = (pr.get("status") or "").lower()
    created = [parse_time(i.get("createdDate")) for i in (iterations or [])]
    created = [c for c in created if c]
    project = (repo.get("project") or {})
    return {
        "platform": AZURE, "repo": f"{project.get('name', '')}/{repo.get('name', '')}",
        "repo-id": repo.get("id", ""), "project-id": project.get("id", ""), "base": base,
        "pr-number": int(pr["pullRequestId"]),
        "pr-url": f"{repo.get('webUrl', '')}/pullrequest/{pr['pullRequestId']}" if repo.get("webUrl") else "",
        "clone-url": re.sub(r"^https://[^@/]+@", "https://", repo.get("remoteUrl", "")),
        "title": pr.get("title", ""), "state": "open" if status == "active" else ("merged" if status == "completed" else "closed"),
        "head-sha": (pr.get("lastMergeSourceCommit") or {}).get("commitId", ""),
        "created-at": pr.get("creationDate", ""), "last-push-at": iso(max(created)) if created else "",
    }


def parse_pr_artifact(rel):
    """(project-id, repo-id, pr-id) for a work item relation that links a PR, else None."""
    url = (rel or {}).get("url", "")
    if (rel or {}).get("rel") != "ArtifactLink" or not url.lower().startswith("vstfs:///git/pullrequestid/"):
        return None
    parts = urllib.parse.unquote(url.split("/", 5)[-1]).split("/")
    return tuple(parts) if len(parts) == 3 else None


def ado_read_work_item(base, org, wi_id, trigger=None):
    wi = http("GET", f"{base}/_apis/wit/workitems/{wi_id}?$expand=relations&{ADO_API}", AZURE)
    fields = wi.get("fields") or {}
    labelled = has_label(split_tags(fields.get("System.Tags")), GROUP_LABEL)
    linked = []
    for rel in wi.get("relations") or []:
        art = parse_pr_artifact(rel)
        if not art:
            continue
        project_id, repo_id, pr_id = art
        try:
            pr = http("GET", f"{base}/{project_id}/_apis/git/repositories/{repo_id}/pullrequests/{pr_id}?{ADO_API}", AZURE)
            its = http("GET", f"{base}/{project_id}/_apis/git/repositories/{repo_id}/pullRequests/{pr_id}/iterations?{ADO_API}",
                       AZURE).get("value", [])
        except ApiError as e:
            log(f"note: PR {pr_id} skipped ({e})")
            continue
        linked.append(ado_member(base, pr, its))
    members, left_out = select_members(linked, MAX_MEMBERS, trigger)
    return {
        "platform": AZURE,
        "group-key": f"wi:azure:{org}:{wi_id}",
        "work-item": {"ref": f"{base}/_apis/wit/workItems/{wi_id}", "base": base, "id": int(wi_id),
                      "project": fields.get("System.TeamProject", ""),
                      "url": ((wi.get("_links") or {}).get("html") or {}).get("href", ""),
                      "title": fields.get("System.Title", ""), "body": fields.get("System.Description", "") or "",
                      "labelled": labelled},
        "members": members, "others": left_out, "notes": [],
    }


def ado_discover_from_pr(pr_number, repo_url):
    parsed = parse_ado_repo(repo_url)
    if not parsed:
        sys.exit(f"ERROR: not an Azure DevOps repository: {repo_url!r}")
    base, project, repo = parsed["base"], urllib.parse.quote(parsed["project"]), urllib.parse.quote(parsed["repo"])
    pr = http("GET", f"{base}/{project}/_apis/git/repositories/{repo}/pullrequests/{pr_number}?{ADO_API}", AZURE)
    me = ado_member(base, pr)
    refs = http("GET", f"{base}/{project}/_apis/git/repositories/{repo}/pullRequests/{pr_number}/workitems?{ADO_API}",
                AZURE).get("value", [])
    groups = []
    for ref in refs[:MAX_WORK_ITEMS_PER_PR]:
        try:
            groups.append(ado_read_work_item(base, parsed["org"], int(ref["id"]), trigger=(me["repo"], me["pr-number"])))
        except ApiError as e:
            log(f"note: work item {ref.get('id')} skipped ({e})")
    return choose_group(groups, me)


def ado_pr_path(m):
    return f"{m['base']}/{m['project-id']}/_apis/git/repositories/{m['repo-id']}/pullRequests/{m['pr-number']}"


def ado_pr_comment(member, body):
    # A closed thread: the note is visible but leaves nothing open on the PR.
    http("POST", f"{ado_pr_path(member)}/threads?{ADO_API}", AZURE,
         {"comments": [{"content": body, "commentType": 1}], "status": "closed"})


def ado_pr_comments(member):
    threads = http("GET", f"{ado_pr_path(member)}/threads?{ADO_API}", AZURE).get("value", [])
    return [c.get("content") or "" for t in threads for c in t.get("comments") or []]


def ado_wi_comments_url(wi):
    return f"{wi['base']}/{urllib.parse.quote(wi['project'])}/_apis/wit/workItems/{wi['id']}/comments"


def ado_state_comments(wi):
    data = http("GET", f"{ado_wi_comments_url(wi)}?{ADO_COMMENTS_API}", AZURE)
    out = [{"id": c["id"], "body": c.get("text") or ""} for c in data.get("comments", []) if STATE_MARKER in (c.get("text") or "")]
    return sorted(out, key=lambda c: c["id"])


def ado_write_state(wi, comment_id, body):
    if comment_id:
        http("PATCH", f"{ado_wi_comments_url(wi)}/{comment_id}?{ADO_COMMENTS_API}", AZURE, {"text": body})
        return comment_id
    return http("POST", f"{ado_wi_comments_url(wi)}?{ADO_COMMENTS_API}", AZURE, {"text": body})["id"]


def ado_delete_comment(wi, comment_id):
    http("DELETE", f"{ado_wi_comments_url(wi)}/{comment_id}?{ADO_COMMENTS_API}", AZURE)


def ado_work_item_labelled(wi):
    data = http("GET", f"{wi['base']}/_apis/wit/workitems/{wi['id']}?fields=System.Tags&{ADO_API}", AZURE)
    return has_label(split_tags((data.get("fields") or {}).get("System.Tags")), GROUP_LABEL)


# ── platform dispatch ────────────────────────────────────────────────────────

def choose_group(groups, me):
    """Several work items may be linked: prefer a labelled one with the most open members."""
    if not groups:
        return {"platform": me["platform"], "status": "no-work-item", "members": [], "others": [],
                "notes": ["no linked work item found"], "trigger": me}
    labelled = [g for g in groups if g["work-item"]["labelled"]]
    pool = labelled or groups
    chosen = sorted(pool, key=lambda g: (-len(g["members"]), g["work-item"]["id"]))[0]
    chosen["notes"] += [f"also linked: {g['work-item']['ref']}" for g in labelled if g is not chosen]
    chosen["trigger"] = me
    return chosen


def pr_comment(m, body):
    (gh_pr_comment if m["platform"] == GITHUB else ado_pr_comment)(m, body)


def pr_comments(m):
    return (gh_pr_comments if m["platform"] == GITHUB else ado_pr_comments)(m)


def state_comments(d):
    return (gh_state_comments if d["platform"] == GITHUB else ado_state_comments)(d["work-item"])


def write_state_comment(d, cid, body):
    return (gh_write_state if d["platform"] == GITHUB else ado_write_state)(d["work-item"], cid, body)


def delete_comment(d, cid):
    (gh_delete_comment if d["platform"] == GITHUB else ado_delete_comment)(d["work-item"], cid)


def work_item_labelled(d):
    return (gh_work_item_labelled if d["platform"] == GITHUB else ado_work_item_labelled)(d["work-item"])


# ── commands ─────────────────────────────────────────────────────────────────

def build_group(args):
    """Discovers the group for --work-item / --pr. Returns (discovery, flags); writes nothing."""
    work_item = pr = None
    force = False
    it = iter(args)
    for a in it:
        if a == "--work-item":
            work_item = next(it, "")
        elif a == "--pr":
            pr = next(it, "").lstrip("#")
        elif a == "--force":
            force = True
        else:
            sys.exit(f"ERROR: unknown argument {a!r} (expected --work-item REF | --pr N, --force)")
    if not work_item and not pr:
        sys.exit("ERROR: pass --work-item <owner/repo#N | Azure DevOps work item URL> or --pr <N>")

    if work_item:
        gh = re.match(r"^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(\d+)$", work_item.strip())
        ado = parse_ado_work_item(work_item.strip())
        if gh:
            d = gh_read_issue(gh.group(1), int(gh.group(2)))
        elif ado:
            d = ado_read_work_item(ado["base"], ado["org"], ado["id"])
        else:
            sys.exit(f"ERROR: unrecognised work item {work_item!r} (expected owner/repo#N or an Azure DevOps work item URL)")
    else:
        if not pr.isdigit():
            sys.exit(f"ERROR: --pr needs a number, got {pr!r}")
        origin = git_origin()
        if parse_github_repo(origin):
            d = gh_discover_from_pr(int(pr), origin)
        elif parse_ado_repo(origin):
            d = ado_discover_from_pr(int(pr), origin)
        else:
            sys.exit(f"ERROR: cannot tell the platform from the git remote {origin!r}")

    if "status" not in d:
        if not d["work-item"]["labelled"]:
            d["status"] = "not-labelled"
        elif len(d["members"]) < 2:
            d["status"] = "too-small"
        else:
            d["status"] = "group"
    if d["status"] != "group":
        d["members"] = []
    pushes = [parse_time(m.get("last-push-at")) for m in d.get("members", [])]
    pushes = [p for p in pushes if p]
    d["newest-push-at"] = iso(max(pushes)) if pushes else ""
    d["args"] = list(args)
    return d, {"force": force}


def discover(args):
    d, flags = build_group(args)
    write_json("discovery.json", d)

    run_id = os.environ.get("EXECUTION_ID") or hashlib.sha1(f"{time.time()}-{os.getpid()}".encode()).hexdigest()[:8]
    prev = run_env()
    started = prev.get("STARTED") if prev.get("RUN_ID") == run_id else ""  # keep the first start of this run
    write_run_env({"RUN_ID": run_id, "FORCE": "true" if flags["force"] else "false",
                   "STARTED": started or iso(now()), "PASS": prev.get("PASS", "1") if started else "1",
                   "PASS_STARTED": prev.get("PASS_STARTED", "") if started else iso(now())})

    newest = parse_time(d["newest-push-at"])
    age = int((now() - newest).total_seconds()) if newest else 999999
    wi = d.get("work-item") or {}
    print(f"STATUS={d['status']}")
    print(f"PLATFORM={d['platform']}")
    print(f"GROUP_KEY={d.get('group-key', '')}")
    print(f"WORK_ITEM={wi.get('ref', '')}")
    print(f"MEMBER_COUNT={len(d['members'])}")
    print(f"NEWEST_PUSH_AGE={age}")
    me = d.get("trigger")
    if me:  # --pr: is that PR a member? /pr-review leaves member PRs to the group review
        keys = {(m["repo"].lower(), m["pr-number"]) for m in d["members"]}
        print(f"TRIGGER_MEMBER={'true' if (me['repo'].lower(), me['pr-number']) in keys else 'false'}")
    for m in d["members"]:
        print(f"  member {m['slug']:<20} {m['repo']} #{m['pr-number']} head={m['head-sha'][:8]}", file=sys.stderr)
    for n in d.get("notes", []):
        print(f"  note: {n}", file=sys.stderr)


def announce(_args):
    """Tell each member PR, once, that it is reviewed with the group: a note with a hidden marker."""
    d = read_json("discovery.json")
    added = 0
    wi = d.get("work-item") or {}
    marker = f"<!-- {MEMBER_MARKER} {d.get('group-key', '')} -->"
    for m in d.get("members", []):
        try:
            if any(marker in body for body in pr_comments(m)):
                continue
            pr_comment(m, f"This PR is reviewed together with the other PRs of work item "
                          f"[{wi.get('title') or wi.get('ref', '')}]({wi.get('url', '')}) ({len(d['members'])} PRs). "
                          f"New commits here start a group review.\n\n{marker}")
            added += 1
        except ApiError as e:
            log(f"WARN: could not post the group note on {m['repo']} #{m['pr-number']}: {e}")
    print(f"NOTES added={added}")


STATE_TEMPLATE = {"version": 1, "run": {}, "reviewed": {}, "pending": False, "followed-up": []}


def render_state(d, state):
    run = state.get("run") or {}
    status = {"running": "🔄 review running", "done": "✅ last review complete", "released": "✅ idle"}.get(
        run.get("status"), run.get("status", "idle"))
    when = run.get("finished") or run.get("started") or ""
    members = ", ".join(f"{k}" for k in sorted(state.get("reviewed", {}))) or "—"
    payload = json.dumps(state, indent=2)
    if d["platform"] == GITHUB:
        return (f"<!-- {STATE_MARKER} v1 -->\n**Xianix group review** · {status} · {when}\n\n"
                f"Reviewed PRs: {members}\n\n<details><summary>state (managed automatically, do not edit)</summary>\n\n"
                f"```json\n{payload}\n```\n</details>\n")
    return (f"<p><b>Xianix group review</b> · {status} · {when}</p><p>Reviewed PRs: {members}</p>"
            f"<p>[{STATE_MARKER}]</p><pre>{payload.replace('&', '&amp;').replace('<', '&lt;')}</pre>"
            f"<p>[/{STATE_MARKER}]</p>")


def parse_state(body):
    import html as html_mod
    text = body or ""
    m = re.search(r"```json\s*(\{.*?\})\s*```", text, re.S)
    if not m:
        m2 = re.search(r"\[" + re.escape(STATE_MARKER) + r"\](.*?)\[/" + re.escape(STATE_MARKER) + r"\]", text, re.S)
        if m2:
            inner = html_mod.unescape(re.sub(r"<[^>]+>", "", m2.group(1)))
            m = re.search(r"(\{.*\})", inner, re.S)
    try:
        state = json.loads(m.group(1)) if m else {}
    except json.JSONDecodeError:
        state = {}
    return {**json.loads(json.dumps(STATE_TEMPLATE)), **state}


def run_env():
    env = {}
    path = os.path.join(WS, "run.env")
    if os.path.isfile(path):
        for line in open(path, encoding="utf-8"):
            k, _, v = line.strip().partition("=")
            if k:
                env[k] = v
    return env


def write_run_env(env):
    os.makedirs(WS, exist_ok=True)
    with open(os.path.join(WS, "run.env"), "w", encoding="utf-8") as f:
        f.writelines(f"{k}={v}\n" for k, v in env.items())


def fresh_state():
    return json.loads(json.dumps(STATE_TEMPLATE))


class CommentStore:
    """State in a comment on the work item. Comments cannot be compare-and-set, so a write
    is read back after a short wait; a rare double run is possible (and harmless)."""
    name = "comment"

    def __init__(self, d):
        self.d = d

    def read(self):
        comments = state_comments(self.d)
        if not comments:
            return None, fresh_state()
        c = comments[0]
        return (c["id"], hashlib.sha1(c["body"].encode()).hexdigest()), parse_state(c["body"])

    def cas(self, token, state):
        current, _ = self.read()
        if current != token:
            return False
        cid = write_state_comment(self.d, token[0] if token else None, render_state(self.d, state))
        time.sleep(LOCK_VERIFY)
        comments = state_comments(self.d)
        if token is None and comments and comments[0]["id"] != cid:
            delete_comment(self.d, cid)  # another run created the state comment first
            return False
        return bool(comments) and parse_state(comments[0]["body"]) == {**fresh_state(), **state}


class RefStore:
    """GitHub: state in a hidden ref of the work item's repo. Moving the ref is atomic."""
    name = "ref"

    def __init__(self, d):
        self.d = d

    def read(self):
        sha, payload = gh_ref_read(self.d["work-item"])
        if not sha:
            return None, fresh_state()
        try:
            return sha, {**fresh_state(), **json.loads(payload)}
        except json.JSONDecodeError:
            return sha, fresh_state()

    def cas(self, token, state):
        run = state.get("run") or {}
        summary = f"xianix group review: {run.get('status', 'idle')} ({run.get('id', '-')})"
        return gh_ref_cas(self.d["work-item"], token, summary, json.dumps(state, indent=2))


def make_store(d):
    choice = STATE_STORE
    saved = os.path.join(WS, "state_store")
    if choice == "auto" and os.path.isfile(saved):
        choice = open(saved, encoding="utf-8").read().strip() or "auto"
    if d["platform"] != GITHUB or choice == "comment":
        return CommentStore(d)
    return RefStore(d)


def with_store(d, fn):
    """Run fn(store); if the token may not write refs, fall back to the comment store once."""
    store = make_store(d)
    try:
        return fn(store)
    except RefUnsupported as e:
        if STATE_STORE == "ref":
            raise ApiError(403, f"cannot write the state ref: {e}") from None
        log(f"note: state ref not writable ({e}) — using a state comment on the work item instead")
        with open(os.path.join(WS, "state_store"), "w", encoding="utf-8") as f:
            f.write("comment")
        return fn(CommentStore(d))


def held_by_other(state, me):
    run = state.get("run") or {}
    beat = parse_time(run.get("heartbeat") or run.get("started"))
    return (run.get("status") == "running" and run.get("id") != me
            and beat is not None and (now() - beat).total_seconds() < LOCK_TTL)


def update_owned(store, me, change):
    """Apply change(state) while this run owns the lock. Returns the new state, or None if lost."""
    for _ in range(5):
        token, state = store.read()
        if (state.get("run") or {}).get("id") != me:
            return None
        change(state)
        if store.cas(token, state):
            return state
    return None


def record_reviewed(d, state):
    """Merge the heads group-setup.sh reviewed (status ok) into state['reviewed']."""
    reviewed = dict(state.get("reviewed") or {})
    gs_path = os.path.join(os.environ.get("PRG_ROOT", "/tmp/prg"), "group_state.json")
    by_slug = {m["slug"]: m for m in d["members"]}
    if os.path.isfile(gs_path):
        for gm in json.load(open(gs_path, encoding="utf-8")).get("members", []):
            m = by_slug.get(gm.get("slug"))
            if m and gm.get("status") == "ok" and gm.get("head_sha"):
                reviewed[f"{m['repo']}#{m['pr-number']}"] = gm["head_sha"]
    state["reviewed"] = reviewed


def time_status():
    env = run_env()
    started = parse_time(env.get("STARTED")) or now()
    pass_started = parse_time(env.get("PASS_STARTED")) or started
    elapsed = int((now() - started).total_seconds())
    return elapsed, int((now() - pass_started).total_seconds()), int(env.get("PASS", "1") or 1)


def lock(args):
    action = args[0] if args else ""
    d = read_json("discovery.json")
    if d.get("status") != "group":
        sys.exit("ERROR: lock needs a discovered group (run group-discover.sh first)")
    me = run_env().get("RUN_ID", "")

    if action == "acquire":
        def acquire(store):
            for _ in range(5):
                token, state = store.read()
                if held_by_other(state, me):
                    holder = state["run"].get("id")
                    if not state.get("pending"):
                        state["pending"] = True
                        store.cas(token, state)  # best effort: tells the holder a push is waiting
                    return f"LOCK=busy HOLDER={holder}"
                state["run"] = {"id": me, "status": "running", "started": iso(now()), "heartbeat": iso(now())}
                if store.cas(token, state):
                    return f"LOCK=acquired STORE={store.name}"
            return "LOCK=busy HOLDER=?"
        print(with_store(d, acquire))
        return

    if action == "heartbeat":
        def beat(state):
            state["run"]["heartbeat"] = iso(now())
        ok = with_store(d, lambda s: update_owned(s, me, beat))
        if ok is None:
            print("LOCK=lost")
            return
        elapsed, _, _ = time_status()
        # The label may have been removed while this review ran: stop before posting.
        status = "heartbeat" if work_item_labelled(d) else "disabled"
        print(f"LOCK={status} ELAPSED={elapsed} REMAINING={max(0, TIME_LIMIT - elapsed)}")
        return

    if action == "release":
        def done(state):
            record_reviewed(d, state)
            state["run"].update({"status": "done", "finished": iso(now())})
            state["pending"] = False
        state = with_store(d, lambda s: update_owned(s, me, done))
        print("WARN: lock is not held by this run — not changing it" if state is None
              else f"LOCK=released REVIEWED={len(state['reviewed'])}")
        return

    if action == "next":
        next_pass(d, me)
        return

    sys.exit("ERROR: lock action must be acquire | heartbeat | release | next")


def next_pass(d0, me):
    """After posting: record what was reviewed, then decide — done, review again in this
    container (NEXT=again), or hand over to a new run via a follow-up comment."""
    def keep(state):
        record_reviewed(d0, state)
        state["run"]["heartbeat"] = iso(now())
    state = with_store(d0, lambda s: update_owned(s, me, keep))
    if state is None:
        print("NEXT=done REASON=lock-lost")
        return

    d, _ = build_group([a for a in d0.get("args", []) if a != "--force"])
    if d.get("status") != "group":
        write_json("discovery.json", d)
        release_now(d0, me)
        print(f"NEXT=done REASON={d.get('status')}")
        return

    reviewed = state.get("reviewed") or {}
    changed = [m for m in d["members"] if reviewed.get(f"{m['repo']}#{m['pr-number']}") != m["head-sha"]]
    if not changed:
        release_now(d0, me)
        print("NEXT=done")
        return

    elapsed, last_pass, passes = time_status()
    names = ",".join(f"{m['repo']}#{m['pr-number']}" for m in changed)
    if passes < MAX_PASSES and elapsed + int(last_pass * 1.2) < TIME_LIMIT:
        write_json("discovery.json", d)
        announce([])  # PRs linked meanwhile get the group note now
        env = run_env()
        env.update({"PASS": str(passes + 1), "PASS_STARTED": iso(now()), "FORCE": "false"})
        write_run_env(env)
        print(f"NEXT=again PASS={passes + 1} CHANGED={names}")
        return

    release_now(d0, me)
    print(hand_over(d, changed))


def release_now(d, me):
    def done(state):
        state["run"].update({"status": "done", "finished": iso(now())})
        state["pending"] = False
    with_store(d, lambda s: update_owned(s, me, done))


def hand_over(d, changed):
    """Not enough time or passes left: ask for a new run with a follow-up comment (once per set of commits)."""
    key = hashlib.sha1("|".join(sorted(f"{m['repo']}#{m['pr-number']}@{m['head-sha']}" for m in changed)).encode()).hexdigest()[:12]

    def mark(store):
        for _ in range(5):
            token, state = store.read()
            if key in (state.get("followed-up") or []):
                return False
            state["followed-up"] = (state.get("followed-up") or [])[-19:] + [key]
            if store.cas(token, state):
                return True
        return False

    if not with_store(d, mark):
        return "NEXT=done REASON=follow-up-already-requested"
    target = changed[0]
    names = ", ".join(f"{m['repo']} #{m['pr-number']}" for m in changed)
    pr_comment(target, f"@xianix review group\n\nNew commits arrived on {names} while the last group review was running, "
                       f"so the group is reviewed again.\n\n_({FOLLOW_UP_MARKER})_")
    return f"NEXT=handed-off ON={target['repo']}#{target['pr-number']}"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    os.makedirs(WS, exist_ok=True)
    try:
        if cmd == "discover":
            discover(args)
        elif cmd == "announce":
            announce(args)
        elif cmd == "lock":
            lock(args)
        else:
            sys.exit(f"ERROR: unknown command {cmd!r}")
    except ApiError as e:
        sys.exit(f"ERROR: platform API call failed — {e}")
    except urllib.error.URLError as e:
        sys.exit(f"ERROR: could not reach the platform API — {e.reason}")


if __name__ == "__main__":
    main()
