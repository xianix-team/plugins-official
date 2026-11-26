#!/usr/bin/env bash
# group-contract-index.sh — token-free index of the interface surface a group of PRs
# changed, plus where the other members reference it (step G2).
#
# Why this exists as a real script: the cross-repo reviewer cannot afford to read
# every member's full diff and code. This collects, deterministically, the changed
# lines that look like contracts (routes, public types, schemas, config/env keys,
# topics, migrations, package versions) and greps the identifiers they add or
# remove across the OTHER members' worktrees. Intentionally over-inclusive — the
# reviewer judges; this only narrows where to look.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-contract-index.sh"
#
# Inputs:
#   $PRG_ROOT/group_state.json                      — from group-setup.sh
#   $PRG_ROOT/<slug>/pr_full_diff_numbered.patch    — per active member
#   Member worktrees (checked out at the PR head by pr-setup.sh)
#
# Outputs:
#   $PRG_ROOT/contracts.md   — the index (capped)
#   Prints its size; exit 0 always (an empty index is valid).

set -euo pipefail

PRG_ROOT="${PRG_ROOT:-/tmp/prg}"

python3 - "$PRG_ROOT" <<'PY'
import json, os, re, subprocess, sys

root = sys.argv[1]
state = json.load(open(os.path.join(root, "group_state.json"), encoding="utf-8"))
members = [m for m in state["members"] if m["status"] == "ok"]
out_path = os.path.join(root, "contracts.md")

MAX_LINES_PER_MEMBER = 80
MAX_IDENTIFIERS = 40
MAX_HITS = 5
MAX_TEXT = 180

CONTRACT_FILES = re.compile(
    r"(\.proto$|\.graphqls?$|\.gql$|openapi[^/]*\.(ya?ml|json)$|swagger[^/]*\.(ya?ml|json)$|"
    r"(^|/)migrations?/|(^|/)Migrations/|\.sql$|"
    r"(^|/)package\.json$|\.csproj$|(^|/)Directory\.Packages\.props$|(^|/)go\.mod$|(^|/)pom\.xml$|"
    r"build\.gradle(\.kts)?$|(^|/)requirements[^/]*\.txt$|(^|/)pyproject\.toml$|"
    r"(^|/)appsettings[^/]*\.json$|(^|/)\.env[^/]*$|values[^/]*\.ya?ml$|docker-compose[^/]*\.ya?ml$|"
    r"\.(tf|bicep)$|(^|/)(dtos?|contracts?|models?|schemas?|api|events?)/)",
    re.IGNORECASE)
CONTRACT_LINE = re.compile(
    r"(\[(Http(Get|Post|Put|Delete|Patch)|Route)\b|@(Get|Post|Put|Delete|Patch|Request)Mapping|"
    r"@(app|router|api|bp)\.(get|post|put|delete|patch|route)\b|\.(get|post|put|delete|patch)\(\s*['\"`]/|"
    r"\b(public|export|internal)\s+(abstract\s+|sealed\s+|partial\s+|static\s+)*(class|record|interface|enum|struct|type|const)\b|"
    r"^\s*(message|service|rpc|enum|type|input|interface)\s+\w+|"
    r"process\.env\.|Environment\.GetEnvironmentVariable|os\.environ|os\.getenv|getenv\(|IConfiguration\[|"
    r"\b(topic|queue|subject|channel|event|exchange|routing_?key)\w*\s*[:=]|"
    r"\b(ADD|DROP|ALTER|RENAME)\s+(COLUMN|TABLE)\b|\bCREATE\s+TABLE\b|"
    r"\"version\"\s*:|PackageReference|<Version>|^\s*[\w.-]+==)",
    re.IGNORECASE)
IDENT = re.compile(r"\b([A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+|[a-z]+(?:[A-Z][a-z0-9]*)+|[A-Z][A-Z0-9]*_[A-Z0-9_]+)\b")
ROUTE = re.compile(r"['\"`](/[A-Za-z0-9_\-/{}:.]{2,})['\"`]")
STOP = {"String", "Boolean", "Integer", "Object", "Promise", "Task", "List", "Dictionary", "IEnumerable",
        "ReadOnly", "Nullable", "DateTime", "ToString", "GetValue", "JsonProperty", "HttpGet", "HttpPost",
        "HttpPut", "HttpDelete", "HttpPatch", "FromBody", "FromQuery", "FromRoute", "ApiController"}

def parse_numbered(path):
    """Yield (file, lineno|None, sign, text) for +/- lines of the numbered patch."""
    current = None
    if not os.path.isfile(path):
        return
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.rstrip("\n")
        body = line.split("|", 1)[-1] if "|" in line else line
        if body.startswith(" diff --git ") or body.startswith(" +++ "):
            m = re.search(r"\b(?:b/)?(\S+)$", body.strip())
            if m and not m.group(1).startswith("/dev/null"):
                current = m.group(1)[2:] if m.group(1).startswith("b/") else m.group(1)
            continue
        m = re.match(r"^\s*(\d+)\s*\|\+(.*)$", line)
        if m and current:
            yield current, int(m.group(1)), "+", m.group(2)
            continue
        m = re.match(r"^\s*-\s*\|-(.*)$", line)
        if m and current:
            yield current, None, "-", m.group(1)

def clip(text):
    text = text.strip()
    return text if len(text) <= MAX_TEXT else text[:MAX_TEXT] + "…"

def identifiers(text):
    found = [i for i in IDENT.findall(text) if i not in STOP and len(i) >= 4]
    found += ROUTE.findall(text)
    return found

def grep_member(member, needle):
    try:
        out = subprocess.run(
            ["git", "-C", member["dir"], "grep", "-n", "-I", "-i", "-F", "-w", "--", needle],
            capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return []
    hits = []
    for row in out.splitlines():
        parts = row.split(":", 2)
        if len(parts) == 3:
            hits.append((parts[0], parts[1], clip(parts[2])))
        if len(hits) >= MAX_HITS:
            break
    return hits

doc = [f"# Contract index — group `{state.get('group-key', '?')}`", "",
       "Changed lines that look like interface surface, per member, and where the identifiers they "
       "add or remove appear in the *other* members (case-insensitive, whole word). Over-inclusive by design.", ""]

for member in members:
    rows = list(parse_numbered(os.path.join(member["state_dir"], "pr_full_diff_numbered.patch")))
    surface = [r for r in rows if CONTRACT_FILES.search(r[0]) or CONTRACT_LINE.search(r[3])]
    target = f"PR #{member['pr_number']}" if member["pr_number"] else f"branch {member['branch']}"
    doc.append(f"## {member['slug']} ({target})")
    doc.append("")
    if not surface:
        doc.append("_No interface-like changes detected._")
        doc.append("")
        continue
    doc.append("### Changed interface lines")
    for path, ln, sign, text in surface[:MAX_LINES_PER_MEMBER]:
        where = f"{path}:{ln}" if ln else f"{path} (removed)"
        doc.append(f"- `{where}` [{sign}] `{clip(text)}`")
    if len(surface) > MAX_LINES_PER_MEMBER:
        doc.append(f"- … {len(surface) - MAX_LINES_PER_MEMBER} more not shown")
    doc.append("")

    added, removed = set(), set()
    for path, ln, sign, text in surface:
        (added if sign == "+" else removed).update(identifiers(text))
    gone = sorted(removed - added)
    new = sorted(added - removed)
    others = [o for o in members if o["slug"] != member["slug"]]
    for label, idents in (("Identifiers removed or renamed by this PR", gone),
                          ("Identifiers added by this PR", new)):
        if not idents:
            continue
        doc.append(f"### {label}")
        for ident in idents[:MAX_IDENTIFIERS]:
            refs = []
            for other in others:
                for f, n, text in grep_member(other, ident):
                    refs.append(f"{other['slug']}: `{f}:{n}` `{text}`")
            if refs:
                doc.append(f"- `{ident}` — referenced in other members:")
                doc.extend(f"  - {r}" for r in refs)
            else:
                doc.append(f"- `{ident}` — no references in other members")
        if len(idents) > MAX_IDENTIFIERS:
            doc.append(f"- … {len(idents) - MAX_IDENTIFIERS} more not shown")
        doc.append("")

open(out_path, "w", encoding="utf-8").write("\n".join(doc) + "\n")
print(f"Contract index written: {out_path} ({len(doc)} lines)")
PY
