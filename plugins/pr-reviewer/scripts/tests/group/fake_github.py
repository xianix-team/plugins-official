#!/usr/bin/env python3
"""fake_github.py — a tiny in-memory GitHub API for the group-review tests.

Serves the GraphQL queries group_platform.py sends (issue + timeline, pull request, issueOrPullRequest)
and the REST calls it makes (issue comments, git trees/commits/refs). Test-only endpoints:
  GET  /_state          — the whole world as JSON
  POST /_set            — merge {"prs": {...}, "issues": {...}, "comments": {...}, "deny_refs": bool} into the world
Usage: fake_github.py <world.json> <port-file>
"""

import hashlib
import json
import re
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

world = json.load(open(sys.argv[1], encoding="utf-8"))
world.setdefault("comments", {})   # "owner/repo#n" -> [{id, body}]
world.setdefault("refs", {})       # "owner/repo:refs/..." -> commit sha
world.setdefault("commits", {})    # sha -> {message, parents}
world.setdefault("deny_refs", False)
next_id = [1000]
ref_lock = threading.Lock()  # GitHub moves a ref atomically; so does the fake


def new_sha(*parts):
    next_id[0] += 1
    return hashlib.sha1(("|".join(map(str, parts)) + str(next_id[0])).encode()).hexdigest()


def pr_node(key):
    pr = world["prs"].get(key)
    if pr is None:
        return {}
    repo, n = key.split("#")
    return {
        "number": int(n), "url": f"https://github.com/{repo}/pull/{n}", "title": pr.get("title", key),
        "state": pr.get("state", "OPEN"), "createdAt": pr.get("createdAt", "2026-01-01T00:00:00Z"),
        "headRefOid": pr.get("head", "0" * 40),
        "repository": {"nameWithOwner": repo, "url": pr.get("repoUrl", f"https://github.com/{repo}")},
        "commits": {"nodes": [{"commit": {"committedDate": pr.get("committedDate", "2026-01-01T00:00:00Z")}}]},
        "forcePushes": {"nodes": []},
        "body": pr.get("body", ""),
        "comments": {"nodes": [{"body": c["body"]} for c in world["comments"].get(key, [])]},
        "refCommits": {"nodes": [{"commit": {"message": msg}} for msg in pr.get("commitMessages", [])]},
        "closingIssuesReferences": {"nodes": [
            {"number": int(r.split("#")[1]), "repository": {"nameWithOwner": r.split("#")[0]}} for r in pr.get("closes", [])]},
    }


def issue_node(key):
    issue = world["issues"].get(key)
    if not issue:
        return None
    repo, n = key.split("#")
    nodes = []
    for ev in issue.get("timeline", []):
        target = pr_node(ev["pr"]) if "pr" in ev else {}
        field = "source" if ev["type"] == "CrossReferencedEvent" else "subject"
        nodes.append({"__typename": ev["type"], field: target})
    return {"number": int(n), "title": issue.get("title", key), "url": f"https://github.com/{repo}/issues/{n}",
            "body": issue.get("body", ""), "labels": {"nodes": [{"name": l} for l in issue.get("labels", [])]},
            "comments": {"nodes": [{"body": c["body"]} for c in world["comments"].get(key, [])]},
            "timelineItems": {"nodes": nodes}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj=None):
        body = json.dumps(obj if obj is not None else {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/_state":
            return self.send(200, world)
        m = re.match(r"^/repos/([^/]+/[^/]+)/issues/(\d+)/comments$", path)
        if m:
            return self.send(200, world["comments"].get(f"{m.group(1)}#{m.group(2)}", []))
        m = re.match(r"^/repos/([^/]+/[^/]+)/git/ref/(.+)$", path)
        if m:
            sha = world["refs"].get(f"{m.group(1)}:refs/{m.group(2)}")
            if not sha:
                return self.send(404, {"message": "Not Found"})
            return self.send(200, {"ref": f"refs/{m.group(2)}", "object": {"sha": sha, "type": "commit"}})
        m = re.match(r"^/repos/([^/]+/[^/]+)/git/commits/([0-9a-f]+)$", path)
        if m and m.group(2) in world["commits"]:
            return self.send(200, {"sha": m.group(2), **world["commits"][m.group(2)]})
        self.send(404, {"message": "not found"})

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        data = self.body()
        if path == "/_set":
            for key, patch in data.get("prs", {}).items():
                world["prs"].setdefault(key, {}).update(patch)
            for key, patch in data.get("issues", {}).items():
                world["issues"].setdefault(key, {}).update(patch)
            for key, cs in data.get("comments", {}).items():
                world["comments"][key] = cs
            if "deny_refs" in data:
                world["deny_refs"] = bool(data["deny_refs"])
            return self.send(200, {})
        m = re.match(r"^/repos/([^/]+/[^/]+)/git/(trees|commits|refs)$", path)
        if m:
            if world["deny_refs"]:
                return self.send(403, {"message": "Resource not accessible by integration"})
            repo, kind = m.group(1), m.group(2)
            if kind == "trees":
                return self.send(201, {"sha": new_sha("tree", json.dumps(data["tree"]))})
            if kind == "commits":
                sha = new_sha("commit", data["message"])
                world["commits"][sha] = {"message": data["message"], "parents": [{"sha": p} for p in data.get("parents", [])]}
                return self.send(201, {"sha": sha})
            with ref_lock:
                key = f"{repo}:{data['ref']}"
                if key in world["refs"]:
                    return self.send(422, {"message": "Reference already exists"})
                world["refs"][key] = data["sha"]
            return self.send(201, {"ref": data["ref"], "object": {"sha": data["sha"]}})
        if path == "/graphql":
            q, v = data["query"], data["variables"]
            key = f"{v['owner']}/{v['name']}#{v['number']}"
            if "issueOrPullRequest(" in q:
                if key in world["prs"]:
                    item = {"__typename": "PullRequest", **pr_node(key)}
                elif key in world["issues"]:
                    item = {"__typename": "Issue"}
                else:
                    return self.send(200, {"data": {"repository": {"issueOrPullRequest": None}},
                                           "errors": [{"message": f"Could not resolve to an issue or pull request with the number of {v['number']}."}]})
                return self.send(200, {"data": {"repository": {"issueOrPullRequest": item}}})
            if "pullRequest(number" in q:
                node = pr_node(key)
                return self.send(200, {"data": {"repository": {"pullRequest": node or None}}})
            node = issue_node(key)
            if node is None:
                return self.send(200, {"data": {"repository": {"issue": None}},
                                       "errors": [{"message": f"Could not resolve to an Issue with the number of {v['number']}."}]})
            return self.send(200, {"data": {"repository": {"issue": node}}})
        m = re.match(r"^/repos/([^/]+/[^/]+)/issues/(\d+)/comments$", path)
        if m:
            next_id[0] += 1
            c = {"id": next_id[0], "body": data["body"]}
            world["comments"].setdefault(f"{m.group(1)}#{m.group(2)}", []).append(c)
            return self.send(201, c)
        self.send(404, {"message": "not found"})

    def do_PATCH(self):
        path = urllib.parse.urlparse(self.path).path
        data = self.body()
        m = re.match(r"^/repos/([^/]+/[^/]+)/issues/comments/(\d+)$", path)
        if m:
            for cs in world["comments"].values():
                for c in cs:
                    if c["id"] == int(m.group(2)):
                        c["body"] = data["body"]
                        return self.send(200, c)
        m = re.match(r"^/repos/([^/]+/[^/]+)/git/refs/(.+)$", path)
        if m:
            key = f"{m.group(1)}:refs/{m.group(2)}"
            with ref_lock:
                current = world["refs"].get(key)
                if not current:
                    return self.send(422, {"message": "Reference does not exist"})
                parents = [p["sha"] for p in world["commits"].get(data["sha"], {}).get("parents", [])]
                if not data.get("force") and current not in parents:
                    return self.send(422, {"message": "Update is not a fast forward"})
                world["refs"][key] = data["sha"]
            return self.send(200, {"ref": f"refs/{m.group(2)}", "object": {"sha": data["sha"]}})
        self.send(404, {"message": "not found"})

    def do_DELETE(self):
        path = urllib.parse.urlparse(self.path).path
        m = re.match(r"^/repos/([^/]+/[^/]+)/issues/comments/(\d+)$", path)
        if m:
            for cs in world["comments"].values():
                cs[:] = [c for c in cs if c["id"] != int(m.group(2))]
            return self.send(200)
        self.send(404, {"message": "not found"})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[2], "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
