# ADR-022: agents-observe Sidecar for Hook-Based Event Monitoring

**Status:** Superseded by [ADR-024](024-decouple-agents-observe-from-sidecar.md)
**Date:** 2026-04-14
**Deciders:** Platform Engineering

## Context

Claude Code v2.1.20+ hides tool-level detail in its CLI output (`Read 3 files`,
`Edited 2 files` — no paths, no diffs). `--verbose` dumps raw JSON. Neither is
usable for real-time monitoring of agent sessions, especially with subagents.

Claude Code exposes 12 lifecycle hooks (PreToolUse, PostToolUse, SubagentStart,
SubagentStop, SessionStart, SessionEnd, etc.) that receive structured JSON on
stdin. These can be wired to external systems.

Three community tools were evaluated:

1. **opcode** (21.5k stars, Tauri 2 + Rust) — desktop app requiring direct access
   to the `claude` binary and project directories. Deployed as sidecar: HTTP 200,
   session browser partially worked, but CLAUDE.md detection, installation check,
   and full session management require co-location with the agent process.
   **Abandoned**: desktop-native architecture incompatible with container isolation.

2. **claude-code-hooks-multi-agent-observability** (1.4k stars, Vue 3 + Bun) —
   hook pipeline worked end-to-end (12 event types captured via `send_event.py`
   stdlib-only script). But the Vue UI is poorly organized, visually unpolished,
   and unsuitable as an enterprise dashboard.
   **Abandoned**: UI inadequate for production use.

3. **agents-observe** (435 stars, React 19 + Hono + SQLite) — clean architecture:
   `Claude Hooks → send_event.sh → HTTP POST → SQLite → WebSocket → React`.
   Subagent hierarchy, session names, tool dedup, search/filter. Docker-native.

## Decision

Deploy **agents-observe** (`simple10/agents-observe`) as a sidecar container in
the agent pod, with a minimal hook script (`send_event.sh`) that pipes Claude Code
lifecycle events to the server.

### Architecture

```
┌─ Pod: claude-code-standalone ──────────────────────────────┐
│                                                            │
│  claude-code ──hooks──→ send_event.sh ──HTTP POST──→ agents-observe  │
│       │                    (background)            (port 4981)       │
│       └── ~/.claude/ ──read-only──→ claude-devtools                   │
│                                    (port 3456)                        │
└────────────────────────────────────────────────────────────┘
```

### Hook Pipeline

1. Claude Code fires a hook event (any of 12 types) with JSON on stdin
2. `send_event.sh` reads stdin to a temp file, wraps it in an envelope with
   project metadata, and POSTs to `http://localhost:4981/api/events` via Node.js
3. The POST runs in background (`&`) to avoid blocking Claude Code
4. agents-observe stores the event in SQLite, broadcasts via WebSocket to
   connected dashboard clients

### Key Design Choices

- **stdlib-only hook script**: `send_event.sh` uses only `bash` + `node` (both
  available in the agent image). No Python, no `uv`, no extra dependencies.
- **Temp file for JSON safety**: stdin JSON is written to a temp file and read by
  Node.js, avoiding shell escaping issues with special characters in payloads.
- **Background execution**: hook script exits immediately (`exit 0`) after
  launching the POST in background, so hook latency doesn't affect agent speed.
- **Auto-shutdown disabled**: `AGENTS_OBSERVE_SHUTDOWN_DELAY_MS=0` prevents the
  server from shutting down when no WebSocket clients are connected.
- **WSS patch**: The upstream client hardcodes `ws://` for WebSocket. The build
  patches this to be protocol-aware (`wss://` on HTTPS, `ws://` on HTTP`) for
  OpenShift edge TLS termination.

## Consequences

**Positive:**
- Real-time visibility into every tool call, subagent lifecycle, and session
- No modifications to Claude Code itself — uses its native hook system
- Minimal footprint: 50m CPU / 128Mi memory request for the sidecar
- SQLite is ephemeral (per-pod) — no persistent storage needed for PoC

**Negative:**
- Event data is lost on pod restart (SQLite in `/tmp`)
- The hook script adds ~10ms per event (background POST, not blocking)
- Build requires patching upstream source for WSS support

**Risks:**
- Upstream `agents-observe` is early-stage (v0.8.6, 435 stars) — may break on updates
- Hook pipeline depends on Node.js being in the agent image

## Alternatives Considered

| Tool | Outcome | Why Not |
|------|---------|---------|
| opcode | Desktop app, sidecar partially worked | Requires `claude` binary co-location |
| claude-code-hooks-multi-agent-observability | Pipeline worked, 12 event types | Vue UI is unpolished, not enterprise-ready |
| Custom dashboard | Full control over UI/UX | Build cost too high for PoC phase |
