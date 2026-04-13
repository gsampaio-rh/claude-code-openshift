# ADR-020: Trace Metadata Enrichment via Claude Code Stop Hook

**Status:** Deferred
**Date:** 2026-04-10
**Deciders:** Platform Engineering

## Status: Deferred (2026-04-10)

This ADR was **implemented, validated end-to-end, and then disabled** for the PoC
phase. The implementation works correctly but adds disproportionate complexity for
a single-agent scenario:

- **6-step hook chain** with REST API polling (up to 20s) per trace
- **3 API calls** per conversation just to add metadata tags
- **Race condition handling** via `session_id` polling — fragile by design

**Experiment-level tags** (set once during deploy) already capture the static
metadata (platform, model, gpu, runtime). Per-trace tags add `pod_name` and
`node_name` which only become useful with **multiple concurrent agents**.

**To re-enable:**
1. Uncomment `AGENTOPS_*` vars in `agents/claude-code/manifests/configmap.yaml`
2. Uncomment Downward API env vars in `agents/claude-code/manifests/standalone-pod.yaml`
3. Uncomment hook registration block in `agents/claude-code/entrypoint.sh`
4. Rebuild and redeploy the agent image

All code remains in-repo (`set-trace-tags.py` stays in the image).

## Context

MLflow's `mlflow autolog claude` captures rich traces (tool calls, token counts,
conversation flow), but each trace lacks operational context — which pod generated
it, on which node, using which model, GPU, and runtime class. Without this metadata,
traces from multiple agents are indistinguishable in the MLflow UI.

We need a mechanism to stamp every trace with Kubernetes and platform metadata so
operators can correlate traces to specific infrastructure.

### Constraints

- Claude Code hooks run as **separate processes** — they have no access to the
  MLflow SDK's in-process trace context.
- The MLflow stop-hook (which creates the trace) and our enrichment hook run
  sequentially, but the trace may not be immediately queryable via the API after
  creation.
- Must work with OpenShift's random UID execution model (GID=0).

## Decision

Enrich every MLflow trace with operational metadata using three mechanisms:

### 1. Kubernetes Downward API (per-pod dynamic metadata)

Inject pod identity into the agent Deployment via `fieldRef`:

| Env var | Source |
|---|---|
| `POD_NAME` | `metadata.name` |
| `POD_NAMESPACE` | `metadata.namespace` |
| `NODE_NAME` | `spec.nodeName` |

### 2. ConfigMap (static platform metadata)

Set cluster-wide constants in the `claude-code-config` ConfigMap:

| Env var | Example |
|---|---|
| `AGENTOPS_RUNTIME_CLASS` | `kata` |
| `AGENTOPS_CLUSTER` | `ocp-sandbox` |
| `AGENTOPS_MODEL` | `qwen25-14b` |
| `AGENTOPS_GPU` | `L40S` |

### 3. `set-trace-tags.py` Claude Code Stop hook

A Python script registered as a Claude Code Stop hook handler. On every
conversation end:

1. Reads JSON from stdin (Claude Code provides `session_id`, `transcript_path`).
2. Looks up the MLflow experiment ID by name.
3. **Polls** the MLflow REST API (up to 10 attempts, 2s interval) to find the
   trace matching the `session_id` from stdin.
4. Stamps the trace with `agentops.*` tags via `PATCH /traces/{id}/tags`.

**Tags applied:**

| Tag | Source |
|---|---|
| `agentops.pod_name` | `POD_NAME` env var |
| `agentops.node_name` | `NODE_NAME` env var |
| `agentops.namespace` | `POD_NAMESPACE` env var |
| `agentops.runtime_class` | `AGENTOPS_RUNTIME_CLASS` env var |
| `agentops.model` | `AGENTOPS_MODEL` env var |
| `agentops.cluster` | `AGENTOPS_CLUSTER` env var |
| `agentops.gpu` | `AGENTOPS_GPU` env var |

### 4. Experiment-level tags

Set once during deployment via `01-deploy-observability.sh` on the
`claude-code-agents` experiment (platform, model, gpu, runtime, integration).

### Hook registration

`entrypoint.sh` registers the hook in `.claude/settings.json` as a handler object
within the same matcher group as the MLflow stop-hook:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "mlflow autolog claude stop-hook" },
          { "type": "command", "command": "python3.12 /usr/local/bin/set-trace-tags.py" }
        ]
      }
    ]
  }
}
```

Handlers within the same group execute sequentially, so the enrichment hook runs
after the MLflow hook creates the trace.

## Consequences

- Every trace in MLflow carries enough context to identify the exact pod, node,
  model, and cluster — critical for multi-agent debugging.
- The polling mechanism (up to 20s) handles the latency between trace creation
  and API availability.
- Silent failure by design — if the hook cannot reach MLflow or find the trace,
  it exits 0 without blocking the agent.
- Adding new metadata only requires a new env var in the ConfigMap and a line in
  `set-trace-tags.py`.

## Lessons Learned

1. **`mlflow.update_current_trace()` is process-local:** A Stop hook runs as a
   separate process and has no trace context. Use `MlflowClient.set_trace_tag()`
   or the REST API instead.

2. **Claude Code hooks must use the `{type, command}` format:** Adding a hook as
   a plain string in `.claude/settings.json` breaks the entire hooks array — even
   valid hooks in the same array stop firing.

3. **Polling by `session_id` is required:** Querying for the "most recent trace"
   creates a race condition — the new trace may not be committed yet, causing tags
   to land on the previous conversation's trace. The `session_id` from stdin
   uniquely identifies the correct trace.

4. **Hooks must consume stdin:** Claude Code pipes JSON to hook processes. If the
   script does not `sys.stdin.read()`, the pipe stays open and the hook hangs.

## Artifacts

| File | Role |
|---|---|
| `agents/claude-code/set-trace-tags.py` | Stop hook script |
| `agents/claude-code/entrypoint.sh` | Hook registration logic |
| `agents/claude-code/manifests/standalone-pod.yaml` | Downward API env vars |
| `agents/claude-code/manifests/configmap.yaml` | `AGENTOPS_*` static metadata |
| `scripts/observability/01-deploy-observability.sh` | Experiment-level tags |
| `scripts/observability/99-verify.sh` | Verification (sections 5-6) |
| `scripts/e2e-test.sh` | E2E validation (section 8) |

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| `mlflow.update_current_trace()` in hook | No cross-process trace context — silently does nothing |
| Sidecar container for tagging | Over-engineered for a simple post-processing step |
| Init container with pre-set tags | Traces don't exist at init time |
| MLflow plugin / custom backend | Too coupled to MLflow internals; REST API is stable |
| Tag by "most recent trace" instead of `session_id` | Race condition — tags land on wrong trace |
