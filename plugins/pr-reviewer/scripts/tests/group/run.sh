#!/usr/bin/env bash
# run.sh — regression tests for the group review scripts (/pr-group-review).
#
# Why this exists: who is in a group, which PRs get the group note, whether the lock lets a second
# run in and when a run reviews again are decided by plain code — exactly what regresses
# silently. No test framework and no network: a fake GitHub API (fake_github.py) and
# local git repos.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/group/run.sh"
#
# Inputs:
#   KEEP_WORK=1 keeps the temp folder for debugging.
#
# Outputs:
#   Prints FAIL lines for failed assertions and a final count. Exits non-zero on any failure.

set -uo pipefail  # not -e: a failed assertion must not abort the remaining tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
FAKE_PID=""

cleanup() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  if [ -n "${KEEP_WORK:-}" ]; then echo "work dir kept: $WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
  fi
}

# Lines like KEY=value from a script's output.
value_of() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }
# First line starting with a prefix.
line_of() { printf '%s\n' "$2" | grep -m1 "^$1" || true; }

echo "=== pure functions ==="

PURE=$(cd "$SCRIPT_DIR" && python3 - <<'PY'
import group_platform as g
out = []
out.append(g.find_issue_refs("Part of acme/planning#1, see #12 and https://github.com/acme/x/issues/3 &#39; a#9", "acme/web"))
nodes = [
    {"__typename": "ConnectedEvent", "subject": {"number": 4, "repository": {"nameWithOwner": "acme/api"}}},
    {"__typename": "CrossReferencedEvent", "source": {}},
    {"__typename": "ConnectedEvent", "subject": {"number": 2, "repository": {"nameWithOwner": "acme/docs"}}},
    {"__typename": "DisconnectedEvent", "subject": {"number": 2, "repository": {"nameWithOwner": "acme/docs"}}},
]
out.append(sorted(p["number"] for p in g.apply_timeline(nodes)))
prs = [{"repo": f"acme/r{i}", "pr-number": i, "state": "open", "created-at": f"2026-01-0{i}T00:00:00Z"} for i in range(1, 5)]
members, left = g.select_members(prs, 2, trigger=("acme/r4", 4))
out.append([m["pr-number"] for m in members] + [p["pr-number"] for p in left])
out.append([m["slug"] for m in g.assign_slugs([{"repo": "acme/api"}, {"repo": "other/api"}])])
out.append(g.parse_ado_work_item("https://dev.azure.com/org1/_apis/wit/workItems/55/updates/3"))
out.append(g.parse_ado_repo("https://org1@dev.azure.com/org1/My%20Proj/_git/web"))
out.append(g.split_tags("a; ai-dlc/pr/group-review ;b"))
out.append(g.parse_pr_artifact({"rel": "ArtifactLink", "url": "vstfs:///Git/PullRequestId/p1%2Fr1%2F12"}))
out.append(g.parse_pr_artifact({"rel": "Related", "url": "x"}))
out.append(g.find_pr_refs("API https://github.com/acme/api/pull/4, UI acme/web#7, see #9", "acme/planning"))
pr = lambda body, comments=(): {"repository": {"nameWithOwner": "acme/web"}, "body": body,
                                "comments": {"nodes": [{"body": c} for c in comments]}}
out.append([g.still_mentions(pr("Part of acme/planning#3"), "acme/planning", 3),
            g.still_mentions(pr("Part of #3"), "acme/planning", 3),
            g.still_mentions(pr("", ["see https://github.com/acme/planning/issues/3"]), "acme/planning", 3),
            g.still_mentions(pr("", ["[w](https://github.com/acme/planning/issues/3) <!-- xianix:group-member k -->"]), "acme/planning", 3)])
for o in out:
    print(o)
PY
)
assert_eq "issue refs: owner/repo#n, #n, URL; not &#39; or a#9" \
  "[('acme/planning', 1), ('acme/x', 3), ('acme/web', 12)]" "$(sed -n 1p <<< "$PURE")"
assert_eq "timeline: disconnect removes, an issue is skipped" "[4]" "$(sed -n 2p <<< "$PURE")"
assert_eq "member cap keeps the trigger PR" "[1, 4, 2, 3]" "$(sed -n 3p <<< "$PURE")"
assert_eq "same repo name, other owner -> -2 slug" "['api', 'api-2']" "$(sed -n 4p <<< "$PURE")"
assert_eq "ADO work item URL" "{'base': 'https://dev.azure.com/org1', 'org': 'org1', 'id': 55}" "$(sed -n 5p <<< "$PURE")"
assert_eq "ADO repo URL" "{'base': 'https://dev.azure.com/org1', 'org': 'org1', 'project': 'My Proj', 'repo': 'web'}" "$(sed -n 6p <<< "$PURE")"
assert_eq "ADO tags" "['a', 'ai-dlc/pr/group-review', 'b']" "$(sed -n 7p <<< "$PURE")"
assert_eq "ADO PR link in relations / history" "('p1', 'r1', '12')" "$(sed -n 8p <<< "$PURE")"
assert_eq "ADO non-PR relation ignored" "None" "$(sed -n 9p <<< "$PURE")"
assert_eq "PR refs in an issue: PR URL, owner/repo#n, #n" "[('acme/api', 4), ('acme/web', 7), ('acme/planning', 9)]" "$(sed -n 10p <<< "$PURE")"
assert_eq "mention kept: description, not #n of another repo, comment, not the plugin's own" \
  "[True, False, True, False]" "$(sed -n 11p <<< "$PURE")"

echo "=== fixture: local repos + fake GitHub ==="

# Two member repos with a local bare origin each; the fake API points clone URLs at them.
make_member() {  # make_member <name> <file> <base-content> <branch-content>
  local name="$1" file="$2" base="$3" change="$4" dir="$WORK/src/$1"
  git init -q --bare "$WORK/remotes/$name.git"
  git clone -q "$WORK/remotes/$name.git" "$dir" 2>/dev/null
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  printf '%s\n' "$base" > "$dir/$file"
  git -C "$dir" add -A && git -C "$dir" commit -q -m base && git -C "$dir" push -q origin HEAD:main
  git -C "$WORK/remotes/$name.git" symbolic-ref HEAD refs/heads/main
  git -C "$dir" checkout -q -b feature/x
  printf '%s\n' "$change" > "$dir/$file"
  git -C "$dir" commit -q -am change && git -C "$dir" push -q origin feature/x
}
mkdir -p "$WORK/remotes" "$WORK/src"
make_member api OrderDto.cs 'public record OrderDto(decimal TotalAmount);' 'public record OrderDto(decimal Total);'
make_member web orders.ts   'export const t = (o) => o.totalAmount;' 'export const t = (o) => o.totalAmount ?? 0;'
API_HEAD=$(git -C "$WORK/src/api" rev-parse HEAD)
WEB_HEAD=$(git -C "$WORK/src/web" rev-parse HEAD)

cat > "$WORK/world.json" <<JSON
{
  "issues": {
    "acme/planning#1": {"title": "Checkout v2", "labels": ["ai-dlc/pr/group-review"], "timeline": [
      {"type": "ConnectedEvent", "pr": "acme/api#4"},
      {"type": "CrossReferencedEvent", "pr": "acme/web#7"},
      {"type": "ConnectedEvent", "pr": "acme/docs#2"},
      {"type": "DisconnectedEvent", "pr": "acme/docs#2"},
      {"type": "CrossReferencedEvent"},
      {"type": "ConnectedEvent", "pr": "evil/x#1"},
      {"type": "ConnectedEvent", "pr": "acme/old#3"}
    ]},
    "acme/planning#2": {"title": "Not labelled", "labels": [], "timeline": [
      {"type": "ConnectedEvent", "pr": "acme/api#4"}, {"type": "ConnectedEvent", "pr": "acme/web#7"}]},
    "acme/planning#5": {"title": "No ref permission", "labels": ["ai-dlc/pr/group-review"], "timeline": [
      {"type": "ConnectedEvent", "pr": "acme/api#4"}, {"type": "ConnectedEvent", "pr": "acme/web#7"}]}
  },
  "prs": {
    "acme/api#4":  {"head": "$API_HEAD", "createdAt": "2026-01-01T00:00:00Z", "repoUrl": "$WORK/remotes/api"},
    "acme/web#7":  {"head": "$WEB_HEAD", "createdAt": "2026-01-02T00:00:00Z", "repoUrl": "$WORK/remotes/web",
                    "body": "Part of acme/planning#1"},
    "acme/docs#2": {},
    "evil/x#1":    {},
    "acme/old#3":  {"state": "MERGED"}
  }
}
JSON
python3 "$SCRIPT_DIR/tests/group/fake_github.py" "$WORK/world.json" "$WORK/port" &
FAKE_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
API="http://127.0.0.1:$(cat "$WORK/port")"
export GITHUB_API_URL="$API" GITHUB_GRAPHQL_URL="$API/graphql" GITHUB_TOKEN=test-token
export PR_GROUP_LOCK_VERIFY_SECONDS=0 PR_GROUP_CACHE_DIR=none
world() { curl -s "$API/_state" | python3 -c "import json,sys; w=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
set_world() { curl -s -X POST "$API/_set" -d "$1" >/dev/null; }
# The group state as stored in the hidden ref of acme/planning (issue 1).
ref_state() { world "json.loads((lambda s: w['commits'][s]['message'][w['commits'][s]['message'].find('{'):])(w['refs']['acme/planning:refs/xianix/pr-group/issue-1']))$1"; }
group_state_file() {  # group_state_file <api-head> <web-head>: what group-setup.sh leaves after a pass
  mkdir -p "$WORK/prg"
  printf '{"members": [{"slug": "api", "status": "ok", "head_sha": "%s"}, {"slug": "web", "status": "ok", "head_sha": "%s"}]}\n' \
    "$1" "$2" > "$WORK/prg/group_state.json"
}
export PRG_ROOT="$WORK/prg"

echo "=== discover from the work item ==="

export PRG_WS="$WORK/ws1" EXECUTION_ID=run-1
OUT=$(bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 2>"$WORK/d1.err")
assert_eq "labelled issue with 2 open PRs is a group" "group" "$(value_of STATUS "$OUT")"
assert_eq "group key" "wi:github:acme/planning#1" "$(value_of GROUP_KEY "$OUT")"
assert_eq "members: open PRs of the same owner, still linked" "2" "$(value_of MEMBER_COUNT "$OUT")"
assert_eq "member slugs, oldest first" "api web" \
  "$(python3 -c "import json,sys; print(' '.join(m['slug'] for m in json.load(open(sys.argv[1]))['members']))" "$PRG_WS/discovery.json")"
assert_eq "other owner is skipped with a note" "yes" "$(grep -q 'evil/x #1: skipped (owner not allowed)' "$WORK/d1.err" && echo yes || echo no)"
assert_eq "no labels put on member PRs" "[] []" "$(world "' '.join(str(w['prs'][k].get('labels', [])) for k in ('acme/api#4', 'acme/web#7'))")"
assert_eq "new members get a note" "2" "$(world "len(w['comments'].get('acme/api#4', [])) + len(w['comments'].get('acme/web#7', []))")"
NOTE=$(world "w['comments']['acme/api#4'][0]['body']")
assert_eq "the note names the work item" "yes" \
  "$(grep -q '^This PR is reviewed together with the other PRs of work item \[Checkout v2\](.*) (2 PRs)\. New commits here start a group review\.$' <<< "$NOTE" && echo yes || echo no)"
assert_eq "the note carries the hidden marker" "yes" "$(grep -qF '<!-- xianix:group-member wi:github:acme/planning#1 -->' <<< "$NOTE" && echo yes || echo no)"
assert_eq "unlinked PR gets no note" "0" "$(world "len(w['comments'].get('acme/docs#2', []))")"
OUT2=$(bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 2>/dev/null)
assert_eq "the note is posted once" "NOTES added=0" "$(line_of NOTES "$OUT2")"

echo "=== discover from a member PR ==="

git -C "$WORK/src/web" remote set-url origin https://github.com/acme/web.git
OUT=$(cd "$WORK/src/web" && PRG_WS="$WORK/ws2" bash "$SCRIPT_DIR/group-discover.sh" --pr 7 2>/dev/null)
assert_eq "PR -> issue reference in the description -> same group" "wi:github:acme/planning#1" "$(value_of GROUP_KEY "$OUT")"
assert_eq "the pushed PR is a member" "true" "$(value_of TRIGGER_MEMBER "$OUT")"
git -C "$WORK/src/web" remote set-url origin https://github.com/acme/docs.git
START=$(date +%s)
OUT=$(cd "$WORK/src/web" && PRG_WS="$WORK/ws2" PR_GROUP_SETTLE_SECONDS=60 bash "$SCRIPT_DIR/group-discover.sh" --pr 2 2>/dev/null)
assert_eq "PR in no group -> no-work-item" "no-work-item" "$(value_of STATUS "$OUT")"
assert_eq "... and not a member" "false" "$(value_of TRIGGER_MEMBER "$OUT")"
assert_eq "... and no quiet-period wait" "yes" "$([ $(( $(date +%s) - START )) -lt 5 ] && echo yes || echo no)"
git -C "$WORK/src/web" remote set-url origin https://github.com/acme/web.git
OUT=$(cd "$WORK/src/web" && PRG_WS="$WORK/ws2" bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#2 2>/dev/null)
assert_eq "issue without the label -> not-labelled" "not-labelled" "$(value_of STATUS "$OUT")"
git -C "$WORK/src/web" remote set-url origin "$WORK/remotes/web.git"

echo "=== quiet period ==="

NOW=$(python3 -c "import datetime as d; print(d.datetime.now(d.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
set_world "{\"prs\": {\"acme/web#7\": {\"committedDate\": \"$NOW\"}}}"
START=$(date +%s)
PRG_WS="$WORK/ws3" PR_GROUP_SETTLE_SECONDS=60 PR_GROUP_SETTLE_MAX_SECONDS=1 \
  bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 >/dev/null 2>"$WORK/settle.err"
assert_eq "fresh push -> waits for the quiet period" "yes" "$(grep -q 'waiting' "$WORK/settle.err" && echo yes || echo no)"
assert_eq "waited at least ~1s" "yes" "$([ $(( $(date +%s) - START )) -ge 1 ] && echo yes || echo no)"
PRG_WS="$WORK/ws3" PR_GROUP_SETTLE_SECONDS=60 \
  bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 --force >/dev/null 2>"$WORK/settle2.err"
assert_eq "--force skips the quiet period" "no" "$(grep -q 'waiting' "$WORK/settle2.err" && echo yes || echo no)"

echo "=== lock (git ref) ==="

L1=$(bash "$SCRIPT_DIR/group-lock.sh" acquire 2>&1)
assert_eq "first run takes the lock in the hidden ref" "LOCK=acquired STORE=ref" "$L1"
assert_eq "no state comment on the issue" "0" "$(world "len(w['comments'].get('acme/planning#1', []))")"
assert_eq "ref holds this run as owner" "run-1" "$(ref_state "['run']['id']")"
PRG_WS="$WORK/ws4" EXECUTION_ID=run-2 bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 >/dev/null 2>&1
L2=$(PRG_WS="$WORK/ws4" bash "$SCRIPT_DIR/group-lock.sh" acquire 2>&1)
assert_eq "second run finds the lock busy" "LOCK=busy HOLDER=run-1" "$L2"
assert_eq "second run marks the group pending" "True" "$(ref_state "['pending']")"
assert_eq "owner still run-1" "run-1" "$(ref_state "['run']['id']")"
HB=$(bash "$SCRIPT_DIR/group-lock.sh" heartbeat 2>&1)
assert_eq "heartbeat by the owner" "LOCK=heartbeat" "${HB%% *}"
assert_eq "release by a non-owner changes nothing" "yes" \
  "$(PRG_WS="$WORK/ws4" bash "$SCRIPT_DIR/group-lock.sh" release 2>&1 | grep -q 'not held by this run' && echo yes || echo no)"

echo "=== compare-and-set: a stale write loses ==="

CAS=$(cd "$SCRIPT_DIR" && PRG_WS="$WORK/ws1" python3 - <<'PY'
import group_platform as g
d = g.read_json("discovery.json")
store = g.RefStore(d)
token, state = store.read()
a = store.cas(token, {**state, "pending": True})    # first writer wins
b = store.cas(token, {**state, "pending": False})   # same old token: must lose
print(a, b)
PY
)
assert_eq "second write with an old token is rejected" "True False" "$CAS"

echo "=== next: done when nothing moved ==="

group_state_file "$API_HEAD" "$WEB_HEAD"
N1=$(bash "$SCRIPT_DIR/group-lock.sh" next 2>/dev/null | grep '^NEXT=')
assert_eq "no new commits -> done" "NEXT=done" "$N1"
assert_eq "lock released" "done" "$(ref_state "['run']['status']")"
assert_eq "both heads recorded" "2" "$(ref_state "['reviewed'].__len__()")"
L3=$(PRG_WS="$WORK/ws4" bash "$SCRIPT_DIR/group-lock.sh" acquire 2>&1)
assert_eq "after release the next run gets the lock" "LOCK=acquired STORE=ref" "$L3"
PRG_WS="$WORK/ws4" bash "$SCRIPT_DIR/group-lock.sh" release >/dev/null 2>&1

echo "=== next: another pass in the same container ==="

EXECUTION_ID=run-5 bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 >/dev/null 2>&1
bash "$SCRIPT_DIR/group-lock.sh" acquire >/dev/null 2>&1
NEW_WEB=1111111111111111111111111111111111111111
set_world "{\"prs\": {\"acme/web#7\": {\"head\": \"$NEW_WEB\"}}}"   # pushed while we reviewed
N2=$(bash "$SCRIPT_DIR/group-lock.sh" next 2>/dev/null | grep '^NEXT=')
assert_eq "moved head + time left -> review again here" "NEXT=again PASS=2 CHANGED=acme/web#7" "$N2"
assert_eq "still holding the lock" "running run-5" "$(ref_state "['run']['status']") $(ref_state "['run']['id']")"
assert_eq "discovery updated with the new head" "$NEW_WEB" \
  "$(python3 -c "import json,sys; print([m for m in json.load(open(sys.argv[1]))['members'] if m['slug']=='web'][0]['head-sha'])" "$PRG_WS/discovery.json")"
assert_eq "second pass is not forced" "FORCE=false" "$(grep '^FORCE=' "$PRG_WS/run.env")"
group_state_file "$API_HEAD" "$NEW_WEB"
N3=$(bash "$SCRIPT_DIR/group-lock.sh" next 2>/dev/null | grep '^NEXT=')
assert_eq "after the second pass -> done" "NEXT=done" "$N3"
assert_eq "no follow-up comment was needed" "0" \
  "$(world "sum('xianix:group-follow-up' in c['body'] for c in w['comments'].get('acme/web#7', []))")"

echo "=== next: hand over when out of passes ==="

EXECUTION_ID=run-6 bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 >/dev/null 2>&1
bash "$SCRIPT_DIR/group-lock.sh" acquire >/dev/null 2>&1
set_world '{"prs": {"acme/web#7": {"head": "2222222222222222222222222222222222222222"}}}'
N4=$(PR_GROUP_MAX_PASSES=1 bash "$SCRIPT_DIR/group-lock.sh" next 2>/dev/null | grep '^NEXT=')
assert_eq "no passes left -> follow-up comment on the changed PR" "NEXT=handed-off ON=acme/web#7" "$N4"
assert_eq "follow-up comment carries the trigger phrase and marker" "True" \
  "$(world "any('@xianix review group' in c['body'] and 'xianix:group-follow-up' in c['body'] for c in w['comments']['acme/web#7'])")"
assert_eq "lock released on hand-over" "done" "$(ref_state "['run']['status']")"
EXECUTION_ID=run-7 bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 >/dev/null 2>&1
bash "$SCRIPT_DIR/group-lock.sh" acquire >/dev/null 2>&1
N5=$(PR_GROUP_MAX_PASSES=1 bash "$SCRIPT_DIR/group-lock.sh" next 2>/dev/null | grep '^NEXT=')
assert_eq "never twice for the same commits" "NEXT=done REASON=follow-up-already-requested" "$N5"

echo "=== next: hand over when out of time ==="

EXECUTION_ID=run-8 bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 >/dev/null 2>&1
bash "$SCRIPT_DIR/group-lock.sh" acquire >/dev/null 2>&1
set_world '{"prs": {"acme/web#7": {"head": "3333333333333333333333333333333333333333"}}}'
N6=$(PR_GROUP_TIME_LIMIT_SECONDS=0 bash "$SCRIPT_DIR/group-lock.sh" next 2>/dev/null | grep '^NEXT=')
assert_eq "no time left -> hand over" "NEXT=handed-off ON=acme/web#7" "$N6"

echo "=== label removed while a review runs ==="

EXECUTION_ID=run-9 bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 >/dev/null 2>&1
bash "$SCRIPT_DIR/group-lock.sh" acquire >/dev/null 2>&1
set_world '{"issues": {"acme/planning#1": {"labels": []}}}'
HB=$(bash "$SCRIPT_DIR/group-lock.sh" heartbeat 2>&1)
assert_eq "heartbeat reports the group as disabled" "LOCK=disabled" "${HB%% *}"
N7=$(bash "$SCRIPT_DIR/group-lock.sh" next 2>/dev/null | grep '^NEXT=')
assert_eq "next stops and releases" "NEXT=done REASON=not-labelled" "$N7"
set_world '{"issues": {"acme/planning#1": {"labels": ["ai-dlc/pr/group-review"]}}}'

echo "=== stale lock is taken over; the old owner notices ==="

EXECUTION_ID=run-10 bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 >/dev/null 2>&1
bash "$SCRIPT_DIR/group-lock.sh" acquire >/dev/null 2>&1   # run-10 holds it and "hangs"
PRG_WS="$WORK/ws5" EXECUTION_ID=run-11 bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 >/dev/null 2>&1
assert_eq "fresh lock blocks" "LOCK=busy HOLDER=run-10" "$(PRG_WS="$WORK/ws5" bash "$SCRIPT_DIR/group-lock.sh" acquire 2>&1)"
assert_eq "lock past its TTL is taken over" "LOCK=acquired STORE=ref" \
  "$(PRG_WS="$WORK/ws5" PR_GROUP_LOCK_TTL_SECONDS=0 bash "$SCRIPT_DIR/group-lock.sh" acquire 2>&1)"
HB=$(bash "$SCRIPT_DIR/group-lock.sh" heartbeat 2>&1)
assert_eq "old owner's heartbeat says the lock is lost" "LOCK=lost" "$HB"
PRG_WS="$WORK/ws5" bash "$SCRIPT_DIR/group-lock.sh" release >/dev/null 2>&1

echo "=== no ref permission -> state comment ==="

set_world '{"deny_refs": true}'
PRG_WS="$WORK/ws6" EXECUTION_ID=run-12 bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#5 >/dev/null 2>&1
L4=$(PRG_WS="$WORK/ws6" bash "$SCRIPT_DIR/group-lock.sh" acquire 2>/dev/null)
assert_eq "falls back to the comment store" "LOCK=acquired STORE=comment" "$L4"
assert_eq "state comment on the issue" "1" "$(world "len(w['comments'].get('acme/planning#5', []))")"
PRG_WS="$WORK/ws7" EXECUTION_ID=run-13 bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#5 >/dev/null 2>&1
assert_eq "comment lock blocks a second run" "LOCK=busy HOLDER=run-12" "$(PRG_WS="$WORK/ws7" bash "$SCRIPT_DIR/group-lock.sh" acquire 2>/dev/null)"
assert_eq "still one state comment" "1" "$(world "len(w['comments']['acme/planning#5'])")"
R=$(PRG_WS="$WORK/ws6" bash "$SCRIPT_DIR/group-lock.sh" release 2>/dev/null)
assert_eq "release via the comment store" "LOCK=released REVIEWED=2" "$R"
FORCED=$(PRG_WS="$WORK/ws7" PR_GROUP_STATE_STORE=ref bash "$SCRIPT_DIR/group-lock.sh" acquire 2>&1)
assert_eq "PR_GROUP_STATE_STORE=ref refuses to fall back" "yes" "$(grep -q 'cannot write the state ref' <<< "$FORCED" && echo yes || echo no)"
set_world '{"deny_refs": false}'

echo "=== checkout through the repo cache + per-member setup, route and post (generic platform) ==="

set_world "{\"prs\": {\"acme/web#7\": {\"head\": \"$WEB_HEAD\"}}}"
export PRG_WS="$WORK/ws8" EXECUTION_ID=run-14
bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 >/dev/null 2>&1
CO=$(PR_GROUP_CACHE_DIR="$WORK/cache" bash "$SCRIPT_DIR/group-checkout.sh" 2>&1)
assert_eq "checkout exits 0" "0" "$?"
assert_eq "members come from the cache" "2" "$(grep -c '(cached)' <<< "$CO")"
assert_eq "cache holds one bare repo per remote" "2" "$(ls -d "$WORK/cache"/*.git 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "group.json lists both checkouts" "api web" \
  "$(python3 -c "import json,sys; print(' '.join(r['slug'] for r in json.load(open(sys.argv[1]))['repositories']))" "$PRG_WS/group.json")"
assert_eq "group.json carries the work item" "Checkout v2" \
  "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['work-item-title'])" "$PRG_WS/group.json")"
# Capture first: `grep -q` closing the pipe early would fail the pipeline under pipefail.
CO2=$(PR_GROUP_CACHE_DIR="$WORK/cache" bash "$SCRIPT_DIR/group-checkout.sh" 2>&1)
assert_eq "second pass refreshes the existing checkouts" "2" "$(grep -c '(refreshed)' <<< "$CO2")"
mkdir -p "$WORK/ws9" && cp "$PRG_WS/discovery.json" "$WORK/ws9/"
CO3=$(PRG_WS="$WORK/ws9" PR_GROUP_CACHE_DIR="$WORK/cache" bash "$SCRIPT_DIR/group-checkout.sh" 2>&1)
assert_eq "a later run reuses the cache" "2" "$(grep -c '(cached)' <<< "$CO3")"

# The local remotes are not GitHub, so pr-setup runs in generic mode on the feature branch.
for m in api web; do git -C "$PRG_WS/repos/$m" fetch -q origin feature/x && git -C "$PRG_WS/repos/$m" checkout -q -b "feature/x" FETCH_HEAD; done
PRG="$WORK/prg-review"
( cd "$PRG_WS/repos" && PRG_ROOT="$PRG" XIANIX_MAX_BUDGET_USD=3 bash "$SCRIPT_DIR/group-setup.sh" api@feature/x web@feature/x >"$WORK/group-setup.out" 2>&1 )
assert_eq "group-setup exits 0" "0" "$?"
assert_eq "both members active" "2" "$(grep '^ACTIVE_COUNT=' "$PRG/group_state.env" 2>/dev/null | cut -d= -f2)"
assert_eq "member state dirs are separate" "OrderDto.cs|orders.ts" \
  "$(cat "$PRG/api/pr_changed_files.txt" 2>/dev/null)|$(cat "$PRG/web/pr_changed_files.txt" 2>/dev/null)"
assert_eq "thin budget -> lean mode" "lean" "$(grep '^BUDGET_MODE=' "$PRG/group_state.env" 2>/dev/null | cut -d= -f2)"
( cd "$PRG_WS/repos" && PRG_ROOT="$WORK/prg-rich" XIANIX_MAX_BUDGET_USD=15 bash "$SCRIPT_DIR/group-setup.sh" api@feature/x web@feature/x >/dev/null 2>&1 )
assert_eq "enough budget -> normal mode" "normal" "$(grep '^BUDGET_MODE=' "$WORK/prg-rich/group_state.env" 2>/dev/null | cut -d= -f2)"

( PRG_ROOT="$PRG" bash "${SCRIPT_DIR}/group-contract-index.sh" >/dev/null 2>&1 )
assert_eq "contract index finds the consumer in the other member" "yes" \
  "$(grep -q 'web: `orders.ts:1`' "$PRG/contracts.md" 2>/dev/null && echo yes || echo no)"

cat > "$PRG/findings.jsonl" <<'JSON'
{"member": "api", "file": "OrderDto.cs", "line": 1, "severity": "CRITICAL", "category": "contract-drift", "related": "web:orders.ts:1", "body": "TotalAmount renamed to Total; web still reads totalAmount.\n\n**Fix:** update web."}
{"member": "web", "file": "orders.ts", "line": 1, "severity": "WARNING", "body": "Silent fallback to 0 hides the missing field.\n\n**Fix:** fail loudly."}
{"member": "nope", "file": "x", "line": 1, "severity": "WARNING", "body": "unknown member"}
JSON
ROUTE_OUT=$(PRG_ROOT="$PRG" bash "${SCRIPT_DIR}/group-route-findings.sh" 2>&1)
assert_eq "routing reports the unknown member" "yes" "$(grep -q "DROPPED.*'nope'" <<< "$ROUTE_OUT" && echo yes || echo no)"
assert_eq "api got its cross-repo finding" "1" "$(grep -c . "$PRG/api/pr_inline_findings.jsonl" 2>/dev/null)"

for m in api web; do printf '## Review of %s\n\nbody\n' "$m" > "$PRG/$m/pr_thread_body.md"; done
echo "REQUEST CHANGES" > "$PRG/api/verdict"
echo "NEEDS DISCUSSION" > "$PRG/web/verdict"
printf '### Cross-repo findings\n- 🔴 **contract-drift** — api ↔ web\n\n### Suggested merge order (advisory)\napi → web\n' > "$PRG/group_notes.md"
( PRG_ROOT="$PRG" bash "${SCRIPT_DIR}/group-post.sh" >"$WORK/group-post.out" 2>&1 )
assert_eq "group-post exits 0" "0" "$?"
API_REPORT="$PRG_WS/repos/api/pr-review-report.md"
assert_eq "group table counts api's critical" "yes" "$(grep -q '| REQUEST CHANGES | 1 | 0 | 1 |' "$API_REPORT" 2>/dev/null && echo yes || echo no)"
assert_eq "group notes on every member" "yes" "$(grep -q 'Suggested merge order' "$PRG_WS/repos/web/pr-review-report.md" 2>/dev/null && echo yes || echo no)"

echo "=== label removed from the work item ==="

set_world '{"issues": {"acme/planning#1": {"labels": []}}}'
OUT=$(PRG_WS="$WORK/ws10" bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#1 2>/dev/null)
assert_eq "label removed -> not-labelled" "not-labelled" "$(value_of STATUS "$OUT")"
assert_eq "... and no new notes" "NOTES added=0" "$(line_of NOTES "$OUT")"
set_world '{"issues": {"acme/planning#1": {"labels": ["ai-dlc/pr/group-review"]}}}'

echo "=== links in the issue; removed mentions ==="

# acme/planning#3: api#4 is linked in the description, web#7 in a comment; api#6 mentioned the
# issue in a commit message (kept); web#8 deleted its mention, web#10 says "#3" (= acme/web#3),
# web#9 has only the plugin's note — all three dropped. docs#2 is in the plugin's own comment.
set_world '{"issues": {
    "acme/planning#3": {"title": "Search", "labels": ["ai-dlc/pr/group-review"],
      "body": "API: https://github.com/acme/api/pull/4 (see also #9 and evil/x#1)",
      "timeline": [{"type": "CrossReferencedEvent", "pr": "acme/api#6"}, {"type": "CrossReferencedEvent", "pr": "acme/web#8"},
                   {"type": "CrossReferencedEvent", "pr": "acme/web#9"}, {"type": "CrossReferencedEvent", "pr": "acme/web#10"}]},
    "acme/planning#9": {"title": "Just an issue"}},
  "prs": {"acme/api#6": {"createdAt": "2026-01-03T00:00:00Z", "commitMessages": ["search endpoint, acme/planning#3"]},
          "acme/web#8": {"body": "nothing here any more"}, "acme/web#9": {}, "acme/web#10": {"body": "Part of #3"}},
  "comments": {"acme/planning#3": [{"id": 1, "body": "UI is acme/web#7"}, {"id": 2, "body": "acme/docs#2 <!-- xianix:pr-group-state -->"}],
               "acme/web#9": [{"id": 3, "body": "[Search](https://github.com/acme/planning/issues/3) <!-- xianix:group-member k -->"}]}}'
OUT=$(PRG_WS="$WORK/ws11" bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#3 2>"$WORK/d11.err")
assert_eq "links in the issue form a group" "group" "$(value_of STATUS "$OUT")"
assert_eq "members: description link, comment link, commit-message mention" "acme/api#4 acme/api#6 acme/web#7" \
  "$(python3 -c "import json,sys; print(' '.join(sorted(m['repo'] + '#' + str(m['pr-number']) for m in json.load(open(sys.argv[1]))['members'])))" "$WORK/ws11/discovery.json")"
assert_eq "a link to another owner is skipped with a note" "yes" "$(grep -q 'evil/x #1: skipped (owner not allowed)' "$WORK/d11.err" && echo yes || echo no)"
set_world '{"issues": {"acme/planning#3": {"body": "API only now"}}, "comments": {"acme/planning#3": []}}'
OUT=$(PRG_WS="$WORK/ws11" bash "$SCRIPT_DIR/group-discover.sh" --work-item acme/planning#3 2>/dev/null)
assert_eq "links removed from the issue -> too-small" "too-small" "$(value_of STATUS "$OUT")"

echo "=== --from-event: one agent rule per platform ==="

EVENTS=$(cd "$SCRIPT_DIR" && python3 - <<'PY'
import group_platform as g
gh = {"platform": "github", "repository-url": "https://github.com/acme/web.git", "work-item-repository": "acme/planning"}
cases = [
    {**gh, "action": "synchronize", "pr-number": 7},
    {**gh, "action": "labeled", "issue-number": 1},
    {**gh, "action": "created", "issue-number": 7, "issue-is-pr": "u", "comment-body": "@xianix review group"},
    {**gh, "action": "created", "issue-number": 7, "issue-is-pr": "u", "comment-body": "@xianix review group <!-- xianix:group-follow-up -->"},
    {**gh, "action": "created", "issue-number": 7, "issue-is-pr": "u", "comment-body": "thanks"},
    {"platform": "azuredevops", "event-type": "workitem.updated", "work-item-url": "https://dev.azure.com/o/_apis/wit/workItems/5/updates/2"},
    {"platform": "azuredevops", "event-type": "git.pullrequest.updated", "pr-number": 12, "pr-repo-url": "https://dev.azure.com/o/p/_git/r"},
    {"platform": "azuredevops", "event-type": "ms.vss-code.git-pullrequest-comment-event", "comment-pr-number": 12,
     "comment-pr-repo-url": "https://dev.azure.com/o/p/_git/r", "comment-body": "@xianix review group"},
    {"platform": "azuredevops", "event-type": "git.pullrequest.merged"},
    {},
]
for c in cases:
    args, settle, skip = g.event_args(c)
    print(skip if skip else f"{' '.join(args)} | {settle}")
PY
)
assert_eq "GitHub push -> --pr with the repo, quiet period" "--pr 7 --repo https://github.com/acme/web.git | 180" "$(sed -n 1p <<< "$EVENTS")"
assert_eq "GitHub label -> --work-item" "--work-item acme/planning#1 | 0" "$(sed -n 2p <<< "$EVENTS")"
assert_eq "GitHub review request -> --force" "--pr 7 --repo https://github.com/acme/web.git --force | 0" "$(sed -n 3p <<< "$EVENTS")"
assert_eq "GitHub follow-up -> no --force" "--pr 7 --repo https://github.com/acme/web.git | 0" "$(sed -n 4p <<< "$EVENTS")"
assert_eq "GitHub other PR comment -> skipped" "the comment is not a group review request" "$(sed -n 5p <<< "$EVENTS")"
assert_eq "ADO work item update -> --work-item" "--work-item https://dev.azure.com/o/_apis/wit/workItems/5/updates/2 | 0" "$(sed -n 6p <<< "$EVENTS")"
assert_eq "ADO push -> --pr with the repo, quiet period" "--pr 12 --repo https://dev.azure.com/o/p/_git/r | 180" "$(sed -n 7p <<< "$EVENTS")"
assert_eq "ADO review request -> --force" "--pr 12 --repo https://dev.azure.com/o/p/_git/r --force | 0" "$(sed -n 8p <<< "$EVENTS")"
assert_eq "ADO other event -> skipped" "event 'git.pullrequest.merged' is not a group event" "$(sed -n 9p <<< "$EVENTS")"
assert_eq "no event -> skipped" "no pull request or work item in the event" "$(sed -n 10p <<< "$EVENTS")"

# End to end through group-discover.sh, from a folder that is not a checkout of the PR's repo.
OUT=$(cd "$WORK" && PRG_WS="$WORK/ws20" XIANIX_INPUTS='{"platform":"github","action":"synchronize","pr-number":7,"repository-url":"https://github.com/acme/web.git"}' \
  PR_GROUP_PUSH_SETTLE_SECONDS=0 bash "$SCRIPT_DIR/group-discover.sh" --from-event 2>/dev/null)
assert_eq "--from-event push finds the group (repo from the event)" "group wi:github:acme/planning#1 true" \
  "$(value_of STATUS "$OUT") $(value_of GROUP_KEY "$OUT") $(value_of TRIGGER_MEMBER "$OUT")"
OUT=$(PRG_WS="$WORK/ws20" XIANIX_INPUTS='{"platform":"github","action":"labeled","issue-number":1,"work-item-repository":"acme/planning"}' \
  bash "$SCRIPT_DIR/group-discover.sh" --from-event 2>/dev/null)
assert_eq "--from-event label -> work item group" "group" "$(value_of STATUS "$OUT")"
OUT=$(PRG_WS="$WORK/ws20" XIANIX_INPUTS='{"platform":"github","action":"created","issue-number":7,"issue-is-pr":"u","comment-body":"nice"}' \
  bash "$SCRIPT_DIR/group-discover.sh" --from-event 2>/dev/null)
assert_eq "--from-event non-group comment -> skipped" "skipped" "$(value_of STATUS "$OUT")"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
