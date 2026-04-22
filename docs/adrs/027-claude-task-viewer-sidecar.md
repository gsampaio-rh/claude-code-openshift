# ADR-027: claude-task-viewer as Sidecar for Task Observability

**Status:** Accepted
**Date:** 2026-04-16
**Deciders:** Platform Engineering

## Context

With Tasks v2 enabled (ADR-026), the Claude Code agent persists tasks as JSON files in `~/.claude/tasks/`. We needed a way to visualize these tasks — especially for headless agents where there is no terminal UI.

We evaluated the following options:

**Option 1 — claude-task-viewer as sidecar:**
- [claude-task-viewer](https://github.com/L1AD/claude-task-viewer) (Node.js, 554 stars, MIT)
- Read-only Kanban board that watches `~/.claude/tasks/` via chokidar (filesystem watcher)
- Real-time updates via Server-Sent Events (SSE), no polling
- Features: task dependencies, live activity feed, timeline/Gantt view, session archiving, fuzzy search
- Observation-only philosophy — Claude owns task state, the viewer never modifies it
- Lightweight: express + chokidar + open, ~93 npm packages total

**Option 2 — Build custom task UI in agents-observe:**
- Extend the existing agents-observe dashboard to parse TodoWrite/TaskCreate from hook events
- Would require modifying agents-observe source code and maintaining the feature

**Option 3 — No task visualization:**
- Tasks exist as files on disk but are only visible via `oc exec` or kubectl

## Decision

**Option 1 — claude-task-viewer as sidecar**, following the same pattern as claude-devtools.

## Rationale

1. **Same sidecar pattern.** Follows the established architecture: sidecar container in the standalone pod, sharing the `claude-sessions` emptyDir volume read-only, with its own Service and Route. Identical to how claude-devtools is deployed.

2. **Zero modification needed.** Works out of the box with Claude Code's native task file format. No hooks, no bridges, no format conversion.

3. **Observation-only.** The viewer never writes to the task files — it only reads. This aligns with the BYOA principle (Bring Your Own Agent): the agent controls its own state.

4. **Complementary to claude-devtools.** Devtools shows session transcripts, tool calls, and token usage. Task-viewer shows task status, dependencies, and progress. Different views of the same agent.

## Implementation

| Resource | Details |
|----------|---------|
| Image | `ubi9/nodejs-22-minimal` + `npm install claude-task-viewer` |
| Build | Binary BuildConfig from `agents/claude-task-viewer/Dockerfile` |
| Port | 3457 (devtools uses 3456) |
| Volume | `claude-sessions` mounted at `/data/.claude` (read-only) |
| Service | `claude-task-viewer` → port 3457 |
| Route | TLS edge termination |

## Trade-offs

| Aspect | Chosen (sidecar) | Custom in agents-observe |
|--------|-------------------|-------------------------|
| Maintenance | Upstream community | Internal |
| Features | Full Kanban, timeline, dependencies | Only what we build |
| Extra container | Yes (50m CPU, 128Mi) | No |
| Task format coupling | Depends on `~/.claude/tasks/` format | Depends on hook events |

## Consequences

- Pod now runs 3 containers: claude-code, claude-devtools, claude-task-viewer
- Task-viewer is accessible via Route at `claude-task-viewer-agent-sandboxes.apps.<cluster>`
- Requires `CLAUDE_CODE_ENABLE_TASKS=1` (ADR-026) — without it, no task files are created
- The model does not always create tasks spontaneously — for simple prompts it goes straight to code
