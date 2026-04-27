# MCP Configuration

The `imp-analyst` plugin uses the **GitHub MCP server** as its preferred integration for posting impact reports to GitHub PRs and issues. The MCP path is attempted first; the plugin falls back to `gh` CLI only if MCP is unavailable.

> **Azure DevOps and Generic platforms do not use MCP.** Azure DevOps uses `curl` with `AZURE_TOKEN` directly. See [`docs/platform-setup.md`](./platform-setup.md).

---

## Why MCP for GitHub?

The GitHub MCP server provides structured, authenticated access to GitHub's API without requiring the `gh` CLI to be installed. The plugin uses these MCP tools:

| MCP Tool | Purpose |
|---|---|
| `mcp__github__get_pull_request` | Fetch PR metadata and body (to detect linked issues) |
| `mcp__github__create_issue_comment` | Post the full impact report as a PR comment |
| `mcp__github__create_issue_comment` | Post a condensed summary to linked issues (same tool, different `issue_number`) |

---

## Connecting the GitHub MCP Server

### Step 1 — Add the server to your Claude configuration

Add the GitHub MCP server to your `claude_desktop_config.json` (or equivalent MCP host config). The server requires a GitHub Personal Access Token (PAT):

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_your_token_here"
      }
    }
  }
}
```

**Config file locations:**

| OS | Path |
|---|---|
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Windows | `%APPDATA%\Claude\claude_desktop_config.json` |
| Linux | `~/.config/claude/claude_desktop_config.json` |

### Step 2 — Generate a GitHub PAT

1. Go to [github.com/settings/tokens](https://github.com/settings/tokens)
2. Click **Generate new token (classic)**
3. Select scopes: `repo` (private repos) or `public_repo` (public repos only)
4. For org repos, ensure SSO authorisation if required
5. Copy the token and set it as `GITHUB_PERSONAL_ACCESS_TOKEN` in the config above

### Step 3 — Verify the connection

Restart Claude (or reload the MCP server), then run:

```
/mcp
```

Confirm `github` appears in the list with status `connected`. The plugin checks for this at the start of every GitHub posting operation.

---

## Fallback behaviour

If the GitHub MCP server is not connected when a GitHub posting is attempted, the plugin automatically falls back to `gh` CLI:

```bash
gh pr comment <pr-number> --body "<report>"
```

The `gh` CLI must be installed and authenticated (`gh auth login` or `GH_TOKEN` set) for the fallback to succeed. See [`docs/platform-setup.md`](./platform-setup.md) for `gh` CLI setup.

The fallback is transparent — no manual intervention is needed. The only difference is the posting mechanism; the report content is identical.

---

## Troubleshooting

**`github` does not appear in `/mcp`**
- Verify `npx` is available: `npx --version`
- Check the config file path and JSON syntax
- Restart Claude after editing the config

**`github` shows as `disconnected` or `error`**
- Check that `GITHUB_PERSONAL_ACCESS_TOKEN` is set and valid
- Confirm the token has not expired
- Verify the token has `repo` or `public_repo` scope

**MCP is connected but posting fails with a 404**
- The PR number may be wrong, or the PR may be on a different repo than the one the MCP server token has access to

---

## Related

- `docs/platform-setup.md` — token scopes, `gh` CLI setup, and Azure DevOps credentials
- `docs/git-auth.md` — runtime credential injection for git HTTPS operations
- `providers/github.md` — full MCP and CLI posting logic with exact tool calls and fallback sequence
