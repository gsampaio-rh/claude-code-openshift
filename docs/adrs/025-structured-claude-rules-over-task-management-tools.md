# ADR-025: Structured .claude Rules/Skills over Third-Party Task Management Tools

**Status:** Accepted
**Date:** 2026-04-16
**Deciders:** Platform Engineering

## Context

AI coding agents need structured workflows to produce consistent, high-quality output — especially in headless containerized environments where there is no human to guide the process in real time.

We evaluated 10+ tools across three categories to solve this:

**Option 1 — Agent-native task management tools:**
- [Taskmaster](https://github.com/eyaltoledano/claude-task-master) (26.6k stars) — MCP server with 36 tools, file-based state, PRD→tasks pipeline
- [agtx](https://github.com/fynnfluegge/agtx) (862 stars) — Terminal kanban with multi-agent orchestration via MCP
- [agi-le](https://github.com/gsampaio-rh/agi-le) — Python CLI, file-based task breakdown
- [vibe-kanban](https://github.com/BloopAI/vibe-kanban) (25k stars) — Rust+TypeScript kanban that spawns local agent subprocesses
- [Backlog.md](https://github.com/MrLesk/Backlog.md) — Markdown-native task manager with MCP and web UI

**Option 2 — Kanban boards with MCP integration (non-agentic):**
- [Planka](https://github.com/plankanban/planka) (11k stars) — Self-hosted Trello alternative, community MCP servers
- [Scrumboy](https://github.com/markrai/scrumboy) (167 stars) — Go binary with built-in MCP server

**Option 3 — Spec-driven development frameworks:**
- [Superpowers](https://github.com/obra/superpowers) (154k stars) — Skills-based workflow framework with subagent orchestration
- [OpenSpec](https://github.com/Fission-AI/OpenSpec) (40.2k stars) — Spec framework with artifact-guided workflow
- [spec-kit](https://github.com/github/spec-kit) — GitHub's official spec-driven development toolkit

**Option 4 — Structured rules and skills via `$HOME/.claude/`:**
- Custom rules (markdown files in `$HOME/.claude/rules/`) define workflow constraints
- Custom skills (SKILL.md files in `$HOME/.claude/skills/`) define active task-driven workflows
- `CLAUDE.md` defines agent behavior preferences
- `settings.json` defines permissions and tool access
- All sourced from a single git repo ([rules-skills](https://github.com/gsampaio-rh/rules-skills)), cloned at image build time

## Decision

**Option 4 — Structured `.claude` rules and skills.**

The agent's development workflow (PRD → PLAN → CHANGELOG → FUTURE_EXPLORATIONS → ADRs → ARCHITECTURE) is enforced via `$HOME/.claude/rules/development-workflow.md`. Task-driven behaviors (sprint planning, spec writing, code review) are defined as skills.

## Rationale

1. **Zero infrastructure overhead.** Rules and skills are plain markdown files baked into the container image. No MCP server, no database, no sidecar, no additional ports or routes.

2. **Works in headless containers.** Taskmaster MCP required interactive prompts and npm runtime. Backlog.md needed git init and a sidecar for its web UI. vibe-kanban spawns local subprocesses. None of these work cleanly in a sandboxed Kata pod with an arbitrary UID and no internet.

3. **Model-agnostic.** Rules work with any LLM that Claude Code can use (Anthropic, vLLM, Bedrock). Third-party tools often assume specific model capabilities or context window sizes — Taskmaster's 36 MCP tools alone consumed significant context on our 32k-token gpt-oss-20b model.

4. **Validated end-to-end.** We tested the workflow by asking the agent to create a new project. With `--dangerously-skip-permissions` (safe in sandboxed pods), the agent correctly created all 5 workflow documents (PRD, PLAN, CHANGELOG, FUTURE_EXPLORATIONS, ARCHITECTURE) following the format defined in the rule.

5. **Composable and versionable.** Rules and skills live in a git repo. Changes are PRs. The same repo serves both Cursor (via `.cursor/rules/`) and Claude Code (via `.claude/rules/`). No vendor lock-in.

## Trade-offs

| Aspect | Rules/Skills (chosen) | Third-party tools |
|--------|----------------------|-------------------|
| Visual kanban board | No | Yes (Backlog.md, Planka, agtx) |
| Task dependency tracking | Manual (agent follows PLAN.md) | Automatic (Taskmaster) |
| Multi-agent task distribution | Not built-in | Supported (agtx, Gastown) |
| Infrastructure cost | Zero | MCP server + DB + sidecar |
| Context window usage | Minimal (rules are short) | Heavy (Taskmaster: 36 tools) |
| Setup complexity | `git clone` + `cp` | npm install + MCP config + init |
| Works in Kata sandbox | Yes | Varies (most had issues) |

## Consequences

- Agents follow the development workflow via rules, not via external tooling
- No visual kanban board — the PLAN.md file is the source of truth for pending work
- Multi-agent task distribution will need a different solution when we reach that phase (see Post-PoC Sprint 10)
- The `rules-skills` repo becomes a critical dependency — changes there affect all agents globally
- Permission mode (`CLAUDE_PERMISSION_MODE` env var in ConfigMap) controls whether the agent can write files in headless mode without prompts
