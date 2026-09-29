# Provider: Generic / Plain Text

Use when the remote is neither GitHub nor Azure DevOps, or the requirement is supplied as plain text or a file.

## Behaviour

- **Input:** the requirement text (pasted, or a path such as `requirement-grooming.md` produced by `req-analyst`'s generic mode — use its *Refined description* section).
- **Groomed check:** the `req-analyst` file header says `Status: ready`, or the operator passes `--force`.
- **Output:** the design doc is written to `docs/design/<slug>.md` and proposed ADRs to the repo's ADR folder, on a local `design/<slug>` branch and committed. Push is attempted if a remote exists; failure to push is reported, not fatal.
- **Conversation:** there is no thread. Feedback is given by re-running the command with instructions, e.g. `/software-design --revise "D1: event; drop the cache"`. The doc's *Revision history* records each run.

## Output

```
Design written: docs/design/<slug>.md (r<N>) — conformance <PASS|FIX> — <M> open decisions
```
