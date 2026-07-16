# Xianix Plugins Official

A curated directory of high-quality plugins for [Xianix the-agent](https://opensource.99x.io/xianix-team/) — AI-powered AI-DLC automation tools.

> **Important:** Make sure you trust a plugin before installing, updating, or using it. 99x does not control what MCP servers, files, or other software are included in community plugins and cannot verify that they will work as intended or that they won't change. See each plugin's homepage for more information.

---

## Structure

```
/plugins - Official plugins developed and maintained by 99x / Xianix Team
```

---

## Available Plugins

| Plugin | Version | Description | Category |
|--------|---------|-------------|----------|
| [chatbot-tester](./plugins/chatbot-tester) | 1.0.0 | Automated AI chatbot verification for any web application. Loads widget configuration from a knowledge file, opens the chatbot via Playwright, runs six test categories (UI availability, functional accuracy, fallback handling, response latency, conversation continuity, empty input handling), judges Q&A responses with a batched LLM call, and posts a structured report as a PR/issue comment or local markdown file. | testing |
| [code-archaeology-analyst](./plugins/code-archaeology-analyst) | 2.0.0 | Autonomous codebase archaeology agent. Triggered by a GitHub Issue or Azure DevOps Work Item tagged 'code-archaeology'. Segments the codebase, maps architecture in business language, extracts coding conventions, runs a due diligence audit for defects and structural problems, classifies all work into typed and prioritised items, and delivers a single structured archaeology report as comments on the originating issue or work item. | code-analysis |
| [doc-writer](./plugins/doc-writer) | 1.0.0 | Automated documentation updater. Given a pull request number, analyses the modified source files and synchronises the project's documentation — updating existing docs that drifted from the new behaviour, creating new docs for new public surfaces, and removing stale entries — then commits the doc-only changes on a separate docs branch and opens a companion documentation pull request targeting the original PR's head branch. Works with GitHub, Azure DevOps, and any git repository. | documentation |
| [impact-analyst](./plugins/impact-analyst) | 1.0.0 | Unified impact analysis and risk-based test strategy plugin combining blast radius analysis, dependency tracing, feature mapping, and structured test case generation into a single HTML report. Works with GitHub and Azure DevOps. | impact-analysis |
| [perf-optimizer](./plugins/perf-optimizer) | 2.0.0 | Whole-codebase performance bottleneck detection triggered from a GitHub issue or Azure DevOps work item, delivered as a ready-to-review fix PR. Detects latency, CPU, memory, and I/O / query inefficiencies. | performance |
| [pr-comment-resolver](./plugins/pr-comment-resolver) | 1.0.0 | Automated resolution of pull request review threads — classifies each unresolved comment as apply, discuss, or decline, applies actionable ones as commits, replies to the rest, and posts a structured disposition report. Works with GitHub and Azure DevOps. | code-review |
| [pr-reviewer](./plugins/pr-reviewer) | 1.9.7 | Comprehensive PR review with specialized agents for code quality, security, test coverage, and performance analysis. Works with GitHub, Azure DevOps, Bitbucket, and any git repository. | code-review |
| [req-analyst](./plugins/req-analyst) | 1.0.0 | Requirement grooming plugin focused on user experience. Analyzes user intent, domain knowledge, competitive context, and workflow to produce well-understood, groomed requirements. | requirements |
| [test-strategist](./plugins/test-strategist) | 1.0.0 | Automated impact analysis and risk-based test strategy generation for bug fixes, PBIs, and feature implementations. Posts a business-readable test guide on the PR/issue/work item discussion for QA engineers doing risk-based testing. Works with GitHub and Azure DevOps. | testing |
| [ux-mob-process](./plugins/ux-mob-process-plugin) | 1.0.0 | AI-native UX mob elaboration workflow for Greenfield and Brownfield projects. Runs structured, human-gated phase processes with artifact guardrails, approval gates, context isolation, and AI readiness checks before any brownfield work begins. | ux-design |
| [web-app-tester](./plugins/web-app-tester) | 1.0.0 | Automated web app behaviour verification triggered from a GitHub PR, Issue, or Azure DevOps work item. Finds a testable URL, runs or auto-generates a test plan using Playwright CLI (headless Chromium), and posts a structured test execution report. | testing |

---

## Adding This Marketplace

Add this marketplace to Xianix the-agent using the `plugin marketplace add` command. It accepts a GitHub owner/repo shorthand, git URL, remote URL to a `marketplace.json` file, or a local directory path.

```
claude plugin marketplace add <source> [options]
```

**From GitHub (recommended):**

```
claude plugin marketplace add xianix-team/xianix-plugins-official
```

**Pin to a specific branch or tag** by appending `@ref` to the GitHub shorthand:

```
claude plugin marketplace add xianix-team/xianix-plugins-official@main
```

**From a git URL** (pin to a branch or tag with `#ref`):

```
claude plugin marketplace add https://github.com/xianix-team/xianix-plugins-official.git#main
```

**From a remote `marketplace.json` URL:**

```
claude plugin marketplace add https://raw.githubusercontent.com/xianix-team/xianix-plugins-official/main/.claude-plugin/marketplace.json
```

**From a local directory path:**

```
claude plugin marketplace add ./path/to/xianix-plugins-official
```

---

## Installation

Once the marketplace is added, plugins can be installed via Xianix the-agent's plugin system.

To install, run:

```
/plugin install {plugin-name}@xianix-plugins-official
```

Or browse for the plugin via `/plugin > Discover`.

---

## Contributing

### Official Plugins

Official plugins are developed by the 99x / Xianix team. See [`/plugins/pr-reviewer`](./plugins/pr-reviewer) for a reference implementation.

### Third-Party Plugins

Third-party partners can submit plugins for inclusion in the marketplace. Submitted plugins must meet quality and security standards for approval. To submit a new plugin, open an issue or pull request against this repository.

---

## Plugin Structure

Each plugin follows a standard structure:

```
plugin-name/
├── .claude-plugin/
│   └── plugin.json      # Plugin metadata (required)
├── .mcp.json            # MCP server configuration (optional)
├── commands/            # Slash commands (optional)
├── agents/              # Agent definitions (optional)
├── skills/              # Skill definitions (optional)
├── hooks/               # Lifecycle hooks (optional)
├── providers/           # Provider-specific configuration (optional)
├── styles/              # Output style definitions (optional)
└── README.md            # Documentation
```

---

## License

Please see each linked plugin for the relevant `LICENSE` file.

---

## Documentation

For more information on developing Xianix plugins, visit [opensource.99x.io/xianix-team](https://opensource.99x.io/xianix-team/).
