# Claude Code Agent — Architecture & Component Guide

**Status:** Current
**Date:** 2026-04-14
**Related:** [ARCHITECTURE.md](ARCHITECTURE.md) | [ADR-022](adrs/022-agents-observe-hook-sidecar.md) | [ADR-024](adrs/024-decouple-agents-observe-from-sidecar.md)

---

## Overview

The Claude Code agent runs as a containerized deployment on OpenShift, connecting to a self-hosted inference backend (vLLM) and emitting telemetry to multiple observability systems. The architecture follows the BYOA (Bring Your Own Agent) principle — Claude Code runs unmodified; all platform capabilities are injected via environment variables, hooks, and sidecars.

```
┌─ OpenShift Cluster ─────────────────────────────────────────────────────────────────────────┐
│                                                                                             │
│  ┌─ ns: agent-sandboxes ──────────────────────────────────────────────────────────────────┐ │
│  │                                                                                        │ │
│  │  ┌─ Deployment: claude-code-standalone ────────────────────────────────────────────┐   │ │
│  │  │  ┌───────────────────────────┐    ┌──────────────────────────┐                  │   │ │
│  │  │  │  claude-code              │    │  claude-devtools         │                  │   │ │
│  │  │  │  UBI9 + Node.js 22       │    │  Session transcript UI   │                  │   │ │
│  │  │  │  Claude Code CLI         │    │  Port 3456               │                  │   │ │
│  │  │  │  MLflow + OTel SDK       │    │  Reads ~/.claude/ (RO)   │                  │   │ │
│  │  │  │  Hooks → send_event.sh   │    │                          │                  │   │ │
│  │  │  └──────────┬───────────────┘    └──────────────────────────┘                  │   │ │
│  │  │             │ emptyDir: claude-sessions (shared volume)                         │   │ │
│  │  └─────────────┼──────────────────────────────────────────────────────────────────┘   │ │
│  │                │                                                                      │ │
│  │                │ HTTP POST (hook events)                                               │ │
│  │                ▼                                                                       │ │
│  │  ┌─ Deployment: agents-observe ────────────────────────────────────────────────────┐   │ │
│  │  │  React 19 + Hono + SQLite │ Port 4981                                          │   │ │
│  │  │  Real-time event dashboard │ WebSocket broadcast                                │   │ │
│  │  └─────────────────────────────────────────────────────────────────────────────────┘   │ │
│  │                                                                                        │ │
│  └────────────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                             │
│  ┌─ ns: inference ────────────┐    ┌─ ns: observability ──────────────────────────────────┐ │
│  │  vLLM (gpt-oss-20b)       │    │  MLflow Tracking     (traces, tool calls, tokens)    │ │
│  │  Anthropic Messages API   │    │  OTEL Collector      (metrics, logs → Prometheus)    │ │
│  │  Port 8080                │    │  Prometheus / Grafana (dashboards, alerts)            │ │
│  └────────────────────────────┘    └──────────────────────────────────────────────────────┘ │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Components

### 1. claude-code (main container)

The agent runtime. Runs Claude Code CLI in a UBI9 + Node.js 22 image with MLflow and OTel SDKs pre-installed.

| Aspect | Detail |
|--------|--------|
| **Image** | Built from `agents/claude-code/Dockerfile` via BuildConfig |
| **Base** | `registry.access.redhat.com/ubi9/nodejs-22` |
| **Entrypoint** | `entrypoint.sh` — copies hook settings, enables MLflow tracing, tails log file, sleeps forever |
| **Invocation** | `oc exec -it <pod> -- claude` (interactive) or `claude-logged "prompt"` (headless + logs) |
| **Runtime class** | `kata` (hardware-isolated MicroVM via QEMU/KVM on bare metal nodes) |
| **Config** | `ConfigMap: claude-code-config` injected via `envFrom` |

**Key environment variables** (from ConfigMap):

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_BASE_URL` | Points to vLLM inference service (no `/v1` suffix) |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | Model name served by vLLM (`gpt-oss-20b`) |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | Prevents startup connections to `api.anthropic.com` |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | Disables per-request hash that breaks vLLM prefix caching |
| `MLFLOW_TRACKING_URI` | MLflow server for native Claude Code tracing |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | Enables multi-agent / subagent spawning |
| `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` | OTLP push endpoint for OTel metrics |

**Manifests:**
- `agents/claude-code/manifests/standalone-pod.yaml` — Deployment (pod spec, volumes, probes)
- `agents/claude-code/manifests/configmap.yaml` — Environment configuration

### 2. claude-devtools (sidecar)

Read-only transcript viewer UI. Runs in the same pod as `claude-code` and shares the `claude-sessions` emptyDir volume.

| Aspect | Detail |
|--------|--------|
| **Why sidecar** | Requires direct filesystem access to `~/.claude/` (JSONL session transcripts, project metadata). This data lives on an emptyDir that cannot be shared across pods without ReadWriteMany PVC. |
| **Volume mount** | `claude-sessions` mounted at `/data/.claude` (read-only) |
| **Port** | 3456 |
| **Access** | OpenShift Route with edge TLS termination |

**Manifests:**
- `agents/claude-devtools/manifests/build.yaml` — BuildConfig + ImageStream
- `agents/claude-devtools/manifests/service.yaml` — Service (selector: `claude-code` pod)
- `agents/claude-devtools/manifests/route.yaml` — Route (edge TLS)

### 3. agents-observe (standalone deployment)

Real-time hook event monitoring dashboard. Receives structured events from Claude Code hooks via HTTP POST and displays them in a React dashboard with WebSocket live updates.

| Aspect | Detail |
|--------|--------|
| **Why standalone** | No filesystem dependency on the agent — communicates exclusively via HTTP. Decoupled for independent lifecycle (ADR-024). |
| **Stack** | React 19 + Hono (server) + SQLite (ephemeral at `/tmp/observe.db`) |
| **Port** | 4981 |
| **Access** | OpenShift Route with edge TLS, `haproxy.router.openshift.io/timeout: 300s` for WebSocket |

**Manifests:**
- `agents/agents-observe/manifests/build.yaml` — BuildConfig + ImageStream
- `agents/agents-observe/manifests/deployment.yaml` — Deployment + Service + Route

---

## Hook Pipeline

Claude Code exposes 12 lifecycle hooks. All are wired to `send_event.sh` via `~/.claude/settings.json` (copied from `hooks/settings.json` at container startup).

### Event flow

```
Claude Code fires hook event
        │
        ▼
  settings.json routes to:
  bash /opt/app-root/hooks/send_event.sh
        │
        ▼
  send_event.sh:
    1. Reads JSON from stdin → temp file
    2. Wraps in envelope with project metadata
    3. HTTP POST to agents-observe service DNS
       http://agents-observe.agent-sandboxes.svc:4981/api/events
    4. Synchronous execution with process.exit(0)
        │
        ▼
  agents-observe:
    1. Stores event in SQLite
    2. Broadcasts via WebSocket to connected dashboards
```

### Hook events captured

| Event | When |
|-------|------|
| `SessionStart` | Agent session begins |
| `SessionEnd` | Agent session ends |
| `UserPromptSubmit` | User sends a prompt |
| `PreToolUse` | Before a tool is called |
| `PostToolUse` | After a tool completes |
| `PostToolUseFailure` | Tool call failed |
| `PermissionRequest` | Agent requests permission |
| `SubagentStart` | Subagent spawned (multi-agent) |
| `SubagentStop` | Subagent finished |
| `PreCompact` | Before context compaction |
| `Stop` | Agent stops (also triggers `mlflow autolog claude stop-hook`) |
| `Notification` | System notification |

### Critical implementation detail

The hook script runs **synchronously** — the node process blocks until the HTTP request completes (or times out at 3s), then exits via `process.exit(0)`. An earlier design used a background subshell (`(node ...) & exit 0`) that was silently killed by Claude Code's process cleanup before the HTTP request completed. This was the root cause of events not being delivered to agents-observe.

---

## Observability Stack

The agent emits telemetry to three independent systems:

### MLflow (traces)

Claude Code has native MLflow integration via `mlflow autolog claude`. The entrypoint runs `mlflow autolog claude -u $MLFLOW_TRACKING_URI` at startup, which hooks into Claude Code's internal tracing to capture:
- Full conversation traces (user prompts, assistant responses)
- Tool call details (name, inputs, outputs, duration)
- Token usage (input, output, cache hits)

The `Stop` hook additionally calls `mlflow autolog claude stop-hook` to flush pending traces.

**Important:** `OTEL_EXPORTER_OTLP_ENDPOINT` must NOT be set globally — it hijacks MLflow's internal OTel SDK, preventing traces from reaching MLflow. Instead, metrics use the specific `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` variable.

### OTel Collector (metrics + logs)

Claude Code pushes OTel metrics and logs via OTLP HTTP/protobuf to the OTel Collector in the `observability` namespace, which forwards to Prometheus for storage and Grafana for dashboards.

### agents-observe (hook events)

Real-time event stream for tool calls, subagent lifecycle, and session tracking. Complements MLflow traces with lower-latency, event-level granularity. See [Hook Pipeline](#hook-pipeline) above.

---

## Networking

### NetworkPolicy rules

The `agent-sandboxes` namespace has restrictive NetworkPolicy. Key rules for the agent:

| Direction | From/To | Port | Purpose |
|-----------|---------|------|---------|
| **Egress** | Agent pods → `ns:inference` | 8080 | vLLM inference API |
| **Egress** | Agent pods → `ns:observability` | 5000 | MLflow tracking server |
| **Egress** | Agent pods → `ns:observability` | 4318 | OTel Collector (OTLP) |
| **Egress** | Agent pods → `agents-observe` pods | 4981 | Hook event delivery |
| **Ingress** | OpenShift Router → agent pods | 3456 | claude-devtools UI |
| **Ingress** | Any pod in namespace → agents-observe | 4981 | Hook event ingress |
| **Ingress** | OpenShift Router → agents-observe | 4981 | agents-observe UI |

### Service DNS

| Service | DNS | Port |
|---------|-----|------|
| vLLM | `gpt-oss-20b.inference.svc.cluster.local` | 8080 |
| MLflow | `mlflow-tracking.observability.svc.cluster.local` | 5000 |
| OTel Collector | `otel-collector.observability.svc.cluster.local` | 4318 |
| agents-observe | `agents-observe.agent-sandboxes.svc` | 4981 |

---

## File Structure

```
agents/
├── claude-code/
│   ├── Dockerfile              # Agent image: UBI9 + Node.js 22 + Claude Code CLI + MLflow
│   ├── entrypoint.sh           # Container startup: hook setup, MLflow init, log tail, sleep
│   ├── claude-logged            # Wrapper: claude -p with NDJSON output to log file
│   ├── set-trace-tags.py       # Per-trace metadata enrichment (disabled for PoC)
│   ├── hooks/
│   │   ├── settings.json       # Claude Code hook config: 12 events → send_event.sh
│   │   └── send_event.sh       # Hook script: stdin JSON → HTTP POST to agents-observe
│   ├── manifests/
│   │   ├── standalone-pod.yaml # Deployment: claude-code + claude-devtools containers
│   │   └── configmap.yaml      # Environment config (inference, MLflow, OTel, model)
├── claude-devtools/
│   └── manifests/
│       ├── build.yaml          # BuildConfig + ImageStream
│       ├── service.yaml        # Service (selector: claude-code pod)
│       └── route.yaml          # Route (edge TLS)
├── agents-observe/
│   └── manifests/
│       ├── build.yaml          # BuildConfig + ImageStream
│       └── deployment.yaml     # Deployment + Service + Route
└── scripts/
    ├── config.sh               # Shared config variables
    ├── 00-setup.sh             # Namespace, RBAC, image streams
    ├── 01-deploy-standalone.sh # Apply manifests and verify
    ├── build-image.sh          # Trigger BuildConfig
    ├── 99-verify.sh            # Health checks
    └── 99-cleanup.sh           # Teardown
```

---

## Deployment Workflow

```bash
# 1. Build agent image
oc start-build claude-code-agent --from-dir=agents/claude-code -n agent-sandboxes

# 2. Build devtools image
oc start-build claude-devtools -n agent-sandboxes

# 3. Build agents-observe image
oc start-build agents-observe -n agent-sandboxes

# 4. Apply manifests
oc apply -f agents/claude-code/manifests/configmap.yaml
oc apply -f agents/claude-code/manifests/standalone-pod.yaml
oc apply -f agents/claude-devtools/manifests/service.yaml
oc apply -f agents/claude-devtools/manifests/route.yaml
oc apply -f agents/agents-observe/manifests/deployment.yaml

# 5. Use the agent
oc exec -it deploy/claude-code-standalone -- claude                  # interactive
oc exec deploy/claude-code-standalone -- claude-logged "prompt"      # headless
```

---

## Design Decisions

| Decision | Rationale | ADR |
|----------|-----------|-----|
| Sidecar for devtools | Requires filesystem access to `~/.claude/` session data | — |
| Standalone for agents-observe | HTTP-only communication, independent lifecycle | [ADR-024](adrs/024-decouple-agents-observe-from-sidecar.md) |
| Synchronous hook execution | Background subshell killed before HTTP completes | [ADR-024](adrs/024-decouple-agents-observe-from-sidecar.md) |
| Kata runtime class | Hardware VM isolation for untrusted agent code | [ADR-017](adrs/017-kata-containers-for-agent-isolation.md) |
| vLLM as inference backend | Anthropic Messages API compatibility, prefix caching | — |
| MLflow for traces | Native Claude Code integration, no custom instrumentation | [ADR-019](adrs/019-observability-otel-mlflow-grafana.md) |
| Separate OTel metrics endpoint | Prevents hijacking MLflow's internal OTel SDK | [ADR-019](adrs/019-observability-otel-mlflow-grafana.md) |
