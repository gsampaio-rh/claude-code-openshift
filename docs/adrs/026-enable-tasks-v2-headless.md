# ADR-026: Enable Tasks v2 for Headless Agent Invocations

**Status:** Accepted
**Date:** 2026-04-16
**Deciders:** Platform Engineering

## Context

Claude Code has two task management systems:

**Option 1 — TodoWrite (legacy):**
- Stores todos in-memory via `context.setAppState()` — never writes to disk
- Session-bound — todos disappear when the session ends
- No cross-session or cross-agent coordination
- Enabled by default in non-interactive (`-p`) mode

**Option 2 — Tasks v2 (TaskCreate/TaskUpdate/TaskList/TaskGet):**
- Stores tasks as JSON files in `~/.claude/tasks/{session-id}/{id}.json`
- Persists across sessions, context window clears, and restarts
- Supports cross-agent coordination with dependency tracking (blocks/blockedBy)
- File locking for concurrent multi-agent access
- Enabled by default in interactive mode, **disabled** in headless (`-p`) mode

The gate is a single function in `src/utils/tasks.ts`:

```typescript
export function isTodoV2Enabled(): boolean {
  if (isEnvTruthy(process.env.CLAUDE_CODE_ENABLE_TASKS)) {
    return true
  }
  return !getIsNonInteractiveSession()
}
```

`TodoWrite` and `TaskCreate` are mutually exclusive — `isEnabled()` returns `!isTodoV2Enabled()` for TodoWrite and `isTodoV2Enabled()` for TaskCreate.

Our agents run exclusively in headless mode (`claude -p`), so Tasks v2 was disabled by default. This meant:
- Tasks created by the agent were in-memory only
- The claude-task-viewer sidecar (which watches `~/.claude/tasks/`) saw nothing
- No task persistence across invocations

## Decision

Set `CLAUDE_CODE_ENABLE_TASKS=1` in the ConfigMap `claude-code-config`.

## Rationale

1. **Headless agents need persistent tasks more, not less.** In interactive mode, the human sees the todo list in the terminal. In headless mode, there is no terminal — file-based tasks are the only way to observe what the agent is tracking.

2. **Enables claude-task-viewer.** The task-viewer sidecar watches `~/.claude/tasks/` via chokidar and serves a real-time Kanban board. Without Tasks v2, it has nothing to show.

3. **Zero risk.** The env var is documented in the source code specifically for this use case: "Force-enable tasks in non-interactive mode (e.g. SDK users who want Task tools over TodoWrite)".

4. **Model-agnostic.** Validated with gpt-oss-20b via vLLM — the model successfully calls `TaskCreate` and produces correctly formatted task JSON files.

## Consequences

- `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet` tools are now available in headless mode
- `TodoWrite` tool is disabled (mutually exclusive)
- Tasks persist in `~/.claude/tasks/` on the `claude-sessions` emptyDir volume
- Tasks survive session restarts but not pod restarts (emptyDir is ephemeral)
- claude-task-viewer sidecar can observe tasks in real-time
- The model does not automatically create tasks for every prompt — it only uses TaskCreate when the task is complex enough or when explicitly instructed
