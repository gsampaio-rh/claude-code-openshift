# ADR-024: Decouple agents-observe from Sidecar to Standalone Deployment

**Status:** Accepted
**Date:** 2026-04-14
**Supersedes:** ADR-022 (architecture section — agents-observe as sidecar)
**Deciders:** Platform Engineering

## Context

ADR-022 deployed agents-observe as a sidecar container in the agent pod. This
worked for the initial PoC but created operational problems:

1. **Deploy coupling**: Any change to agents-observe (or any other sidecar)
   required redeploying the entire agent pod, killing active Claude Code sessions.
   This was painfully exposed during agent-flow evaluation, where iterating on
   sidecars forced repeated agent restarts.

2. **Scaling mismatch**: Each agent pod carried its own agents-observe instance.
   In a multi-agent scenario, N agents means N redundant observe servers — each
   with its own SQLite database, preventing cross-agent session correlation.

3. **Hook script bug**: The original `send_event.sh` used a background subshell
   (`(node ...) & exit 0`) that exited before the HTTP request completed. This
   worked only because sidecar localhost was near-instant. In any networked
   topology, the process got killed before delivery.

agents-observe communicates with the agent exclusively via HTTP POST (hook events)
and has zero filesystem dependency on the agent. There is no architectural reason
for it to share a pod.

## Decision

Move agents-observe from a sidecar container to its own Deployment with a
dedicated Service and Route.

### Architecture (after)

```
┌─ Deployment: claude-code-standalone ────────┐
│                                              │
│  claude-code ──hooks──→ send_event.sh ──────────HTTP POST──→ ┌─ Deployment: agents-observe ─┐
│       │                                      │               │  agents-observe (port 4981)   │
│       └── ~/.claude/ ──read-only──→ devtools │               │  SQLite + WebSocket + React   │
│                         (port 3456)          │               └──────────────────────────────┘
└──────────────────────────────────────────────┘
```

### Changes

1. **`standalone-pod.yaml`**: Removed agents-observe container. Pod now has 2
   containers: `claude-code` + `claude-devtools`.

2. **`agents-observe.yaml`** (new): Standalone Deployment + Service + Route for
   agents-observe. Labels changed from `app.kubernetes.io/name: claude-code` to
   `app.kubernetes.io/name: agents-observe` for independent lifecycle.

3. **`send_event.sh`**: Default URL changed from `http://localhost:4981` to
   `http://agents-observe.agent-sandboxes.svc:4981` (Kubernetes service DNS).
   Also fixed the background subshell bug — node process now runs synchronously
   with explicit `process.exit(0)` on response/error.

4. **`network-policies.yaml`**: Added egress rule allowing agent pods to reach
   agents-observe on port 4981, and ingress rule allowing intra-namespace traffic
   on port 4981. Previously unnecessary because sidecar localhost bypasses
   NetworkPolicy.

### Why devtools stays as sidecar

`claude-devtools` requires direct filesystem access to `~/.claude/` session files
(JSONL transcripts, project metadata). This data lives on an `emptyDir` volume
that cannot be shared across pods without a ReadWriteMany PVC. The sidecar pattern
is architecturally justified here.

## Consequences

**Positive:**
- agents-observe can be redeployed, scaled, or upgraded without touching agent pods
- Single agents-observe instance can serve multiple agent pods (future)
- Hook delivery is now reliable (synchronous HTTP, no background process kill)
- Cleaner separation of concerns in Kubernetes manifests

**Negative:**
- Requires NetworkPolicy rules for pod-to-pod communication (added)
- Slightly higher latency (~1ms) vs localhost, negligible in practice
- SQLite is still ephemeral — future work to add persistent storage or
  centralized database

**Risks:**
- If agents-observe pod is down, hook events are silently dropped (fire-and-forget)
- DNS resolution adds a dependency on CoreDNS availability
