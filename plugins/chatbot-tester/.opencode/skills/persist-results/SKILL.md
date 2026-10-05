---
name: persist-results
description: Phase 5 of chatbot-tester. Writes the full run result as JSON and CSV to a GitHub results repository, computes per-category accuracy across the last 10 runs, and updates the README with a Mermaid accuracy chart.
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Phase 5 — Persist Results

This skill is invoked by the **orchestrator** agent after Phase 4. It is not a standalone slash command.

## Inputs

| Variable | Source | Description |
|---|---|---|
| `JUDGED_RESULTS` | Phase 3 | Full category results with verdicts and reasoning |
| `TEST_URL` | orchestrator | The URL that was tested |
| `ENTRY_TYPE` | orchestrator | `issue`, `wi`, or `url` |
| `ENTRY_ID` | orchestrator | Issue number, work item ID, or the direct URL |
| `PLATFORM` | orchestrator | `GitHub`, `AzureDevOps`, or `DirectURL` |
| `CHATBOT_NAME` | orchestrator | Sanitized chatbot identifier derived from `KNOWLEDGE.name` or hostname |
| `LITE_MODE` | orchestrator | `true` if no issue/work item was provided |

## Environment Variables

| Variable | Purpose |
|---|---|
| `CHATBOT-RESULTS-REPO` | GitHub repo for results (e.g. `xianix-team/chatbot-test-results`). If not set, this phase is skipped. |
| `CHATBOT-RESULTS-GITHUB-TOKEN` | Auth token for cloning and pushing to the results repo. If not set, this phase is skipped. |

---

## Step 1: Check Prerequisites

Run:

```bash
python3 -c "
import os, sys
repo = (os.environ.get('CHATBOT-RESULTS-REPO') or os.environ.get('CHATBOT_RESULTS_REPO', '')).strip()
token = (os.environ.get('CHATBOT-RESULTS-GITHUB-TOKEN') or os.environ.get('CHATBOT_RESULTS_GITHUB_TOKEN', '')).strip()
if not repo:
    print('SKIP: CHATBOT-RESULTS-REPO not set — skipping result persistence')
    sys.exit(0)
if not token:
    print('SKIP: CHATBOT-RESULTS-GITHUB-TOKEN not set — skipping result persistence')
    sys.exit(0)
print('PREREQS_OK')
print('RESULTS_REPO=' + repo)
"
```

If the output contains `SKIP:`, output the skip message as a warning and stop Phase 5 — do not fail the overall run. If `PREREQS_OK`, store `RESULTS_REPO` and continue.

---

## Step 2: Prepare Run Data

Compute `RUN_TIMESTAMP`: use the current UTC time in ISO 8601 format, replacing `:` with `-` to make it filename-safe (e.g., `2026-06-18T10-32-00Z`).

Run:

```bash
python3 -c "
import datetime
ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H-%M-%SZ')
print('RUN_TIMESTAMP=' + ts)
"
```

Store `RUN_TIMESTAMP` from the output.

---

## Step 3: Serialize JUDGED_RESULTS to a Temp File

Write `JUDGED_RESULTS` to `/tmp/cbt_judged_results.json`. Use Python to write the data — do not embed raw JSON in a shell command. Substitute the actual `JUDGED_RESULTS` value from the orchestrator context into the script before running:

```bash
python3 << 'PYEOF'
import json
judged_results = {JUDGED_RESULTS}
with open('/tmp/cbt_judged_results.json', 'w', encoding='utf-8') as f:
    json.dump(judged_results, f, ensure_ascii=False, indent=2)
print('JUDGED_RESULTS_WRITTEN')
PYEOF
```

---

## Step 4: Clone the Results Repo

```bash
CBT_RESULTS_TOKEN=$(python3 -c "import os; print(os.environ.get('CHATBOT-RESULTS-GITHUB-TOKEN') or os.environ.get('CHATBOT_RESULTS_GITHUB_TOKEN', ''))")
CBT_RESULTS_REPO=$(python3 -c "import os; print(os.environ.get('CHATBOT-RESULTS-REPO') or os.environ.get('CHATBOT_RESULTS_REPO', ''))")
git clone "https://x-access-token:${CBT_RESULTS_TOKEN}@github.com/${CBT_RESULTS_REPO}.git" /tmp/cbt_results_repo 2>&1
```

If the clone fails (non-zero exit), output a warning line and stop Phase 5:
```
chatbot-tester WARNING: could not clone results repo {RESULTS_REPO} — skipping result persistence. Error: {error_output}
```

---

## Step 5: Write JSON and CSV Files

Write the result files by running the script below. Substitute `{CHATBOT_NAME}`, `{RUN_TIMESTAMP}`, `{TEST_URL}`, `{ENTRY_TYPE}`, `{ENTRY_ID}`, and `{PLATFORM}` with their actual values before executing:

```bash
python3 << 'PYEOF'
import json, os
from pathlib import Path

chatbot_name = "{CHATBOT_NAME}"
run_timestamp = "{RUN_TIMESTAMP}"
test_url = "{TEST_URL}"
entry_type = "{ENTRY_TYPE}"
entry_id = "{ENTRY_ID}"
platform = "{PLATFORM}"

repo_root = Path('/tmp/cbt_results_repo')
chatbot_dir = repo_root / 'results' / chatbot_name
chatbot_dir.mkdir(parents=True, exist_ok=True)

judged_results = json.loads(Path('/tmp/cbt_judged_results.json').read_text(encoding='utf-8'))

CATEGORIES = [
    'ui_availability', 'functional_accuracy', 'fallback_handling',
    'response_latency', 'conversation_continuity', 'conversation_flow',
    'empty_input_handling'
]

# Build normalised categories dict
categories_dict = {}
for cat in judged_results:
    key = cat.get('category', '').lower().replace(' ', '_')
    categories_dict[key] = {
        'verdict': cat.get('status', 'NOT_RUN'),
        'detail': cat.get('detail', ''),
        'qa_pairs': cat.get('qa_pairs', []),
        'probe_results': cat.get('probe_results', [])
    }

# Compute overall verdict
def compute_verdict(cats):
    active = [v['verdict'] for v in cats.values() if v['verdict'] != 'NOT_RUN']
    if not active:
        return 'NOT_RUN'
    if any(v in ('FAILED', 'BLOCKED') for v in active):
        return 'FAILED'
    if any(v == 'PARTIAL' for v in active):
        return 'PARTIAL'
    return 'PASSED'

overall_verdict = compute_verdict(categories_dict)

# Write JSON
run_data = {
    'run_id': run_timestamp,
    'chatbot_name': chatbot_name,
    'chatbot_url': test_url,
    'entry_type': entry_type,
    'entry_id': str(entry_id),
    'platform': platform,
    'overall_verdict': overall_verdict,
    'categories': categories_dict
}
json_path = chatbot_dir / f'{run_timestamp}.json'
json_path.write_text(json.dumps(run_data, indent=2, ensure_ascii=False), encoding='utf-8')

# Write CSV
def csv_escape(val):
    val = str(val)
    if ',' in val or '"' in val or '\n' in val:
        return '"' + val.replace('"', '""') + '"'
    return val

header = 'timestamp,chatbot_name,chatbot_url,entry_type,entry_id,platform,overall_verdict,' + ','.join(CATEGORIES)
row_values = [run_timestamp, chatbot_name, test_url, entry_type, str(entry_id), platform, overall_verdict]
for cat in CATEGORIES:
    row_values.append(categories_dict.get(cat, {}).get('verdict', 'NOT_RUN'))

csv_path = chatbot_dir / f'{run_timestamp}.csv'
csv_path.write_text(header + '\n' + ','.join(csv_escape(v) for v in row_values) + '\n', encoding='utf-8')

print('JSON_WRITTEN=' + str(json_path))
print('CSV_WRITTEN=' + str(csv_path))
PYEOF
```

If the script exits with a non-zero status, output a warning and skip the remaining steps of Phase 5.

---

## Step 6: Compute Accuracy and Update README

Read the last 10 run JSON files for this chatbot, compute per-category accuracy, and update the README. Substitute `{CHATBOT_NAME}` before running:

```bash
python3 << 'PYEOF'
import json, re
from pathlib import Path

chatbot_name = "{CHATBOT_NAME}"
repo_root = Path('/tmp/cbt_results_repo')
chatbot_dir = repo_root / 'results' / chatbot_name
readme_path = repo_root / 'README.md'

CATEGORIES = [
    'ui_availability', 'functional_accuracy', 'fallback_handling',
    'response_latency', 'conversation_continuity', 'conversation_flow',
    'empty_input_handling'
]
CAT_DISPLAY = {
    'ui_availability':        'UI Availability',
    'functional_accuracy':    'Functional Accuracy',
    'fallback_handling':      'Fallback Handling',
    'response_latency':       'Response Latency',
    'conversation_continuity':'Conversation Continuity',
    'conversation_flow':      'Conversation Flow',
    'empty_input_handling':   'Empty Input Handling'
}
CAT_SHORT = {
    'ui_availability':        'UI Avail',
    'functional_accuracy':    'Functional',
    'fallback_handling':      'Fallback',
    'response_latency':       'Latency',
    'conversation_continuity':'Continuity',
    'conversation_flow':      'Flow',
    'empty_input_handling':   'Empty Input'
}

# Load last 10 runs
json_files = sorted(chatbot_dir.glob('*.json'))[-10:]
accuracy = {cat: {'passed': 0, 'total': 0} for cat in CATEGORIES}
last_date = ''

for jf in json_files:
    data = json.loads(jf.read_text(encoding='utf-8'))
    last_date = data.get('run_id', '').split('T')[0]
    for cat in CATEGORIES:
        verdict = data.get('categories', {}).get(cat, {}).get('verdict', 'NOT_RUN')
        if verdict != 'NOT_RUN':
            accuracy[cat]['total'] += 1
            if verdict == 'PASSED':
                accuracy[cat]['passed'] += 1

total_runs = len(json_files)

# Build accuracy table rows and chart values
table_rows = []
bar_labels = []
bar_values = []
for cat in CATEGORIES:
    total = accuracy[cat]['total']
    passed = accuracy[cat]['passed']
    if total == 0:
        pct_str = 'N/A'
        bar_values.append(0)
    else:
        pct_num = round(passed / total * 100)
        pct_str = f'{pct_num}%'
        bar_values.append(pct_num)
    table_rows.append(f'| {CAT_DISPLAY[cat]} | {pct_str} | {passed}/{total} |')
    bar_labels.append(f'"{CAT_SHORT[cat]}"')

table_md = '\n'.join(table_rows)
bar_labels_str = '[' + ', '.join(bar_labels) + ']'
bar_values_str = '[' + ', '.join(str(v) for v in bar_values) + ']'

# Build the chatbot section
section = f'''## {chatbot_name}

**Last tested:** {last_date} | **Runs in window:** {total_runs}

### Category Accuracy (last 10 runs)

| Category | Accuracy | Passed/Total |
|---|---|---|
{table_md}

### Accuracy Chart

```mermaid
xychart-beta
    title "{chatbot_name} — Category Accuracy (last 10 runs)"
    x-axis {bar_labels_str}
    y-axis "Pass Rate %" 0 --> 100
    bar {bar_values_str}
```

---'''

# Read or initialise README
if readme_path.exists():
    content = readme_path.read_text(encoding='utf-8')
else:
    content = '# Chatbot Test Results\n\nAuto-updated by [chatbot-tester](https://github.com/xianix-team/plugins-official). Showing accuracy across the last 10 runs per chatbot.\n\n---\n'

section_header = f'## {chatbot_name}\n'
if section_header in content:
    start = content.index(section_header)
    next_h2 = content.find('\n## ', start + len(section_header))
    if next_h2 == -1:
        content = content[:start] + section + '\n'
    else:
        content = content[:start] + section + '\n\n' + content[next_h2 + 1:]
else:
    if not content.endswith('\n'):
        content += '\n'
    content += '\n' + section + '\n'

readme_path.write_text(content, encoding='utf-8')
print('README_UPDATED')
PYEOF
```

If the script exits with a non-zero status, output a warning but continue to Step 7 to still commit the JSON and CSV files.

---

## Step 7: Commit and Push

```bash
cd /tmp/cbt_results_repo
git config user.email "chatbot-tester@noreply"
git config user.name "chatbot-tester"
git add results/
git add README.md
git diff --cached --quiet || git commit -m "results: {CHATBOT_NAME} — {OVERALL_VERDICT} ({RUN_TIMESTAMP})"
git push 2>&1
```

Substitute `{CHATBOT_NAME}`, `{OVERALL_VERDICT}`, and `{RUN_TIMESTAMP}` with their actual values before running.

If push fails, output a warning:
```
chatbot-tester WARNING: failed to push results to {RESULTS_REPO} — {error_output}
```

---

## Step 8: Cleanup

```bash
rm -rf /tmp/cbt_results_repo /tmp/cbt_judged_results.json
```

---

## Completion

Output one line:

```
chatbot-tester results persisted to {RESULTS_REPO}/results/{CHATBOT_NAME}/{RUN_TIMESTAMP}
```

If Phase 5 was skipped or failed at any step, output the relevant warning line instead and ensure the overall run still completes normally.
