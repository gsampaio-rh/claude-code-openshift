# ADR-019: Observability Stack — MLflow + OTEL Collector + Grafana

**Status:** Superseded (simplified) — Grafana re-enabled for inference metrics
**Date:** 2026-04-09
**Updated:** 2026-04-13
**Deciders:** Platform Engineering

## Status Update (2026-04-10)

The original three-component stack (MLflow + OTEL Collector + Grafana) was
**fully deployed and validated** — all components were operational, traces flowed
through the OTEL Collector, spanmetrics exported to Prometheus, and Grafana
dashboards displayed operational metrics. However, the stack has been
**simplified to MLflow-only** for the PoC phase.

**What we tried and what worked:**
- OTEL Collector received OTLP spans and converted them to RED metrics via
  the `spanmetrics` connector (span throughput, latency histograms, error rates).
- Dedicated Prometheus scraped OTEL Collector's `:8889/metrics` endpoint.
- Grafana displayed real-time operational dashboards (spans/min, p50/p95/p99
  latency, active services, collector health).
- The full pipeline (Agent → OTEL Collector → Prometheus → Grafana) was validated
  end-to-end with test traces.

**Why we deferred it:**
- `mlflow autolog claude` provides richer, structured traces (tool calls, token
  counts, conversation flow) directly into MLflow — more useful for the PoC than
  raw OTEL spans.
- The OTEL/Prometheus/Grafana stack added operational complexity (crashloops from
  misconfigured `spanmetrics`, NetworkPolicy debugging for 5 ports across 3
  namespaces, `OTEL_EXPORTER_OTLP_ENDPOINT` conflicting with MLflow's internal SDK)
  without proportional value at this stage.
- Operational dashboards (span rates, latency percentiles) become important when
  running multiple agents at scale — not needed for PoC validation.

**What remains:**
- All manifests are kept in-repo under `observability/{otel,prometheus,grafana}/`
  and can be re-enabled by uncommenting the relevant sections in
  `observability/scripts/config.sh` and `01-deploy-observability.sh`.
- NetworkPolicy rules for OTEL ports (4317/4318) can be restored in
  `infra/cluster/namespaces/network-policies.yaml`.

**Current data flow (updated 2026-04-13):**

```
Claude Code Agent
  ├─ mlflow autolog claude ──▸ MLflow Tracking Server (traces + experiments)
  └─ OTLP metrics (OTEL_EXPORTER_OTLP_METRICS_ENDPOINT) ──▸ OTEL Collector ──▸ Prometheus ──▸ Grafana

vLLM /metrics ──▸ ServiceMonitor ──▸ Prometheus (user workload) ──▸ Thanos Querier ──▸ Grafana
```

### Grafana re-enabled for inference metrics (2026-04-13)

Grafana was **re-enabled** — not for agent traces (those stay in MLflow) but for
**vLLM inference metrics**. The approach changed from the original design:

- **Original:** OTEL Collector spanmetrics → standalone Prometheus → Grafana
- **Current:** vLLM native Prometheus metrics → OpenShift user workload monitoring → Thanos Querier → Grafana

Key differences from the original design:

1. **No standalone Prometheus** — uses OpenShift's built-in user workload monitoring
   (`enableUserWorkload: true` in `cluster-monitoring-config`).
2. **No OTEL Collector** — vLLM exposes 97 native Prometheus metrics on `/metrics`;
   no need to derive metrics from traces.
3. **Grafana datasource** — points to Thanos Querier (`openshift-monitoring:9091`)
   with a ServiceAccount bearer token (`cluster-monitoring-view` ClusterRole),
   not a standalone Prometheus instance.
4. **Dashboard focus** — inference metrics (TTFT, ITL, KV cache, token throughput,
   requests by finish reason), not agent span metrics.

**New manifests:**
- `infra/vllm/manifests/servicemonitor.yaml` — ServiceMonitor for vLLM scrape
- `observability/grafana/rbac.yaml` — ServiceAccount + ClusterRoleBinding
- `observability/dashboards/inference-metrics.json` — vLLM inference dashboard
- `observability/otel/servicemonitor.yaml` — ServiceMonitor for OTEL Collector
- `observability/dashboards/agent-metrics.json` — Claude Code agent metrics dashboard

**NetworkPolicy additions:**
- `openshift-user-workload-monitoring` → `inference:8080` (Prometheus scrape)
- `observability` → `openshift-monitoring:9091` (Grafana → Thanos Querier)
- `agent-sandboxes` → `observability:4318` (OTLP metrics push)
- `openshift-user-workload-monitoring` → `observability:8889` (Prometheus scrape OTEL Collector)

### OTEL Collector re-enabled for agent metrics (2026-04-13)

The OTEL Collector was **re-enabled** — not for spanmetrics (original design) but to
receive **native Claude Code metrics** via OTLP and expose them to Prometheus.

**Why OTLP instead of Prometheus exporter:** Claude Code sessions are ephemeral
(`claude -p "..." → exit`). The `OTEL_METRICS_EXPORTER=prometheus` option starts an
HTTP server on port 9464 that only lives during the `claude` process. Since the
container's entrypoint is `sleep infinity`, the metrics endpoint disappears between
sessions and Prometheus misses the data. OTLP push solves this: metrics are sent to
the OTEL Collector during the session; the collector persists and aggregates them.

**Key design choice:** Uses `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` (metrics-specific)
instead of `OTEL_EXPORTER_OTLP_ENDPOINT` (general). This avoids hijacking MLflow's
internal OTEL SDK — the same conflict documented in Lesson #1 above.

> Trace metadata enrichment (Downward API, `set-trace-tags.py` Stop hook) is
> documented in [ADR-020](020-trace-metadata-enrichment.md).

## Context

Agent workloads (Claude Code) running on OpenShift need full-stack observability:
tracing of every tool call, LLM invocation, and orchestration step; experiment
tracking for prompt iterations; and operational dashboards for cluster operators.

Key constraints:
- Must work **without external SaaS** — all data stays on-cluster.
- Must integrate with OpenShift's existing monitoring stack (Prometheus, AlertManager).
- Claude Code emits traces via the **OpenTelemetry SDK** (OTLP protocol).

## Decision

Deploy a three-component stack in the `observability` namespace:

| Component | Image | Role | Status |
|---|---|---|---|
| **MLflow Tracking Server** | `mlflow:v3.10.1` | Trace storage, experiment tracking UI, artifact store | **Active** |
| **OTEL Collector** (contrib) | `otel-collector-contrib:0.120.0` | Receives OTLP metrics from Claude Code, exports via Prometheus | **Active** (metrics only) |
| **Grafana OSS** | `grafana:11.5.2` | Inference dashboards querying Thanos Querier (user workload metrics) | **Active** (inference only) |

### Data flow (original design)

```
Claude Code Agent
  ├─ mlflow autolog claude ──▸ MLflow (rich traces: tools, tokens, conversations)
  │
  └─ OTLP (CLAUDE_CODE_ENABLE_TELEMETRY) ──▸ OTEL Collector
                                                ├─ spanmetrics ──▸ Prometheus ──▸ Grafana
                                                └─ debug ──▸ oc logs
```

Two separate, complementary paths:

1. **`mlflow autolog claude`** — native Claude Code integration (MLflow >= 3.4) that
   captures tool usage, token counts, and conversation structure directly into MLflow.
   Configured via `MLFLOW_TRACKING_URI` env var + `mlflow autolog claude` at pod startup.
   See: https://mlflow.org/docs/latest/genai/tracing/integrations/listing/claude_code/

2. **OTEL Collector → Prometheus → Grafana** (disabled) — Claude Code's built-in OTEL
   telemetry sends raw spans to the collector. The `spanmetrics` connector derives
   Rate/Errors/Duration metrics for operational dashboards.

### Why MLflow (not Jaeger or Tempo)

- MLflow v3 has a **native Claude Code integration** with rich trace data (tool calls,
  token counts, conversation flow) — far richer than raw OTLP spans.
- Experiment-centric views (group traces by prompt version, model, parameters).
- Jaeger/Tempo are infrastructure-focused; they lack experiment tracking and comparison.
- MLflow doubles as the future **experiment registry** for prompt tuning and model evaluation.

### Why OTEL Collector (not just MLflow) — deferred

- MLflow shows traces. It does **not** show operational metrics (span throughput,
  latency percentiles, error rates).
- The `spanmetrics` connector derives RED metrics from traces without requiring
  agents to emit separate metrics.
- Grafana dashboards give cluster operators a real-time operational view.
- Enables future exporters (Tempo, S3, etc.) without changing agent configuration.
- **Deferred:** not needed for PoC. Can be re-enabled when operational dashboards
  become a priority.

## Consequences

- **Storage:** MLflow uses SQLite on a PVC. Sufficient for PoC; production would need
  PostgreSQL and S3-compatible artifact storage.
- **Memory:** MLflow v3 spawns huey workers for scoring jobs, requiring 2Gi memory limit
  (vs ~512Mi for v2.x).
- **Security:** MLflow v3 enforces `--allowed-hosts` — internal service names (with and
  without port), `localhost`, and the Route hostname must all be listed explicitly.
- **Agent image:** Requires `mlflow >= 3.10` Python package in the Claude Code container.
  Entrypoint runs `mlflow autolog claude` before `sleep infinity`.
- **NetworkPolicy:** Agents in `agent-sandboxes` need egress to `observability`
  namespace on port 5000 (MLflow).
- **No HA:** Single-replica deployment. Acceptable for PoC; production needs a shared
  MLflow backend (PostgreSQL + S3).

## Lessons Learned

1. **`OTEL_EXPORTER_OTLP_ENDPOINT` conflicts with MLflow:** Setting this env var
   hijacks MLflow's internal OTEL SDK, routing traces to the OTEL Collector instead
   of the MLflow server. Do **not** set it when using `mlflow autolog claude`.

2. **MLflow `--allowed-hosts` requires host+port variants:** The security middleware
   does exact match on the `Host` header. Must list `service-name`, `service-name:5000`,
   `localhost`, `localhost:5000`, and the Route hostname.

3. **`opentelemetry-exporter-otlp-proto-http` is required:** Without it, MLflow's
   internal OTEL SDK returns `NoOpSpan` and traces silently fail to export.

4. **OpenShift random UID requires `chmod g+w`:** The `.claude/settings.json` file
   needs group-write permission because OpenShift runs containers with a random UID
   but GID=0. Without `chmod -R g+w .claude`, `mlflow autolog claude` cannot write
   its hooks.

5. **NetworkPolicy must allow port 5000:** Agent egress and observability ingress
   policies must explicitly allow TCP 5000 for MLflow, not just the OTLP ports
   (4317/4318).

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| OTEL Collector → MLflow OTLP endpoint | Works (protobuf + x-mlflow-experiment-id header) but produces raw spans. `mlflow autolog claude` gives much richer traces natively. |
| Jaeger + Prometheus | No experiment tracking; two separate UIs for traces and metrics |
| Tempo + Grafana only | Tempo needs S3 backend; no experiment/artifact tracking |
| OpenShift distributed tracing (Tempo Operator) | Heavier footprint; still lacks experiment tracking |
| SaaS (Datadog, Honeycomb) | Violates on-cluster data residency constraint |
