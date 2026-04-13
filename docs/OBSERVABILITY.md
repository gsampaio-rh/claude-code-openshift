# Observability

How we monitor the agent and the model on OpenShift.

**Related:** [ADR-019 — Observability Stack](adrs/019-observability-otel-mlflow-grafana.md) | [ADR-021 — User Workload Monitoring](adrs/021-user-workload-monitoring-over-standalone-prometheus.md) | [ARCHITECTURE.md §3.6](ARCHITECTURE.md)

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        OpenShift Cluster                           │
│                                                                    │
│  ┌──────────────────┐      ┌─────────────────────────────────────┐ │
│  │  agent-sandboxes  │      │           observability             │ │
│  │                   │      │                                     │ │
│  │  Claude Code ─────┼─────▸│  MLflow     (traces + experiments) │ │
│  │   (Kata microVM)  │ mlflow│                                     │ │
│  │                   │      │                                     │ │
│  │  Claude Code ─────┼─────▸│  OTEL Collector  (OTLP → Prom)    │ │
│  │                   │ otlp │                                     │ │
│  └──────────────────┘      │  Grafana ───▸ Thanos Querier        │ │
│                             └────────────────┼────────────────────┘ │
│  ┌──────────────────┐                        │                      │
│  │    inference      │                        │                      │
│  │                   │      ┌─────────────────▼────────────────┐   │
│  │  vLLM /metrics ───┼─────▸│ Prometheus (user workload mon.) │   │
│  │                   │  SM  │ ──▸ Thanos Querier               │   │
│  └──────────────────┘      └──────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

There are **two** observability targets and **three** data paths:

| Target | What we observe | Path | Tool |
|---|---|---|---|
| **Agent** (Claude Code) | Rich traces: tool calls, tokens, conversations | `mlflow autolog claude` → MLflow | MLflow UI |
| **Agent** (Claude Code) | Operational metrics: token counts, cost, sessions | OTLP → OTEL Collector → Prometheus | Grafana |
| **Model** (vLLM) | Inference metrics: latency, throughput, KV cache | `/metrics` → ServiceMonitor → Prometheus | Grafana |

---

## 1. Agent observability

### 1.1 Traces — MLflow

MLflow captures **structured traces** of every Claude Code session via the native `mlflow autolog claude` integration (MLflow >= 3.4). This is the primary tool for understanding *what the agent did* — prompt flow, tool usage, token consumption, reasoning steps.

**Data captured:**

- Prompts sent to the model
- Reasoning steps
- Tool invocations (which tool, parameters, result)
- Token counts (input, output, cache read, cache creation)
- Latency per step
- Full conversation structure

**How it works:**

1. The agent container includes `mlflow >= 3.10` and `opentelemetry-exporter-otlp-proto-http`
2. `entrypoint.sh` runs `mlflow autolog claude` at startup, which installs a Claude Code hook
3. Every `claude` invocation sends traces to the MLflow Tracking Server
4. MLflow stores traces in SQLite on a PVC (PoC); production would use PostgreSQL + S3

**Configuration (in `claude-code-config` ConfigMap):**

```yaml
MLFLOW_TRACKING_URI: "http://mlflow-tracking.observability.svc.cluster.local:5000"
MLFLOW_EXPERIMENT_NAME: "claude-code-agents"
```

**Access:**

- MLflow UI: `https://mlflow-tracking-observability.apps.<cluster>/`
- Traces are grouped by experiment → navigate to "claude-code-agents" to see all sessions

**Key constraint:** Do NOT set `OTEL_EXPORTER_OTLP_ENDPOINT` (the general endpoint) — it hijacks MLflow's internal OTEL SDK and routes traces to the OTEL Collector instead of MLflow. Use `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` (metrics-specific) instead.

### 1.2 Metrics — OTel → OTEL Collector → Prometheus → Grafana

Claude Code has native OpenTelemetry support that exports operational metrics. These answer *how much* the agent consumes — tokens, cost, session counts — rather than *what* it does (that's MLflow's job).

**Metrics available:**

| Prometheus metric | Type | Labels | Description |
|---|---|---|---|
| `claude_code_token_usage_tokens_total` | counter | `type`, `model`, `session_id` | Tokens consumed (input, output, cacheRead, cacheCreation) |
| `claude_code_cost_usage_USD_total` | counter | `model`, `session_id` | Estimated cost in USD |
| `claude_code_session_count_total` | counter | `session_id` | Sessions started |
| `claude_code_lines_of_code_count_total` | counter | `type`, `session_id` | Lines added/removed |
| `claude_code_commit_count_total` | counter | `session_id` | Git commits created |
| `claude_code_pull_request_count_total` | counter | `session_id` | Pull requests created |
| `claude_code_code_edit_tool_decision_total` | counter | `tool_name`, `decision`, `session_id` | Accept/reject of edit tools |
| `claude_code_active_time_total_s_total` | counter | `type`, `session_id` | Active time (user interaction vs CLI processing) |

**Why OTLP push instead of Prometheus pull:**

Claude Code sessions are ephemeral — `claude -p "prompt" → exit`. The Prometheus exporter (`OTEL_METRICS_EXPORTER=prometheus`) starts an HTTP server on port 9464, but it dies when the `claude` process exits. Since the container runs `sleep infinity` between sessions, Prometheus has nothing to scrape. OTLP push solves this: metrics are sent to the OTEL Collector *during* the session, and the collector persists them.

**Data path:**

```
Claude Code → OTLP HTTP (:4318) → OTEL Collector → Prometheus endpoint (:8889) → Prometheus (UWM) → Thanos Querier → Grafana
                                                  └→ debug exporter (logs → oc logs)
```

**Configuration (in `claude-code-config` ConfigMap):**

```yaml
CLAUDE_CODE_ENABLE_TELEMETRY: "1"
OTEL_METRICS_EXPORTER: "otlp"
OTEL_EXPORTER_OTLP_METRICS_PROTOCOL: "http/protobuf"
OTEL_EXPORTER_OTLP_METRICS_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4318/v1/metrics"
OTEL_LOGS_EXPORTER: "otlp"
OTEL_EXPORTER_OTLP_LOGS_PROTOCOL: "http/protobuf"
OTEL_EXPORTER_OTLP_LOGS_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4318/v1/logs"
OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE: "cumulative"
```

**Dashboard:** "AgentOps — Claude Code Agent Metrics" in Grafana (5 sections, 42 panels)

- **Token Usage** — input, output, cache read/creation, total, estimated cost, rate over time, tokens by model
- **Derived Efficiency Metrics** — cache hit rate, avg cost/session, avg tokens/session, output/input ratio, LOC per 1K tokens, commits/session, cache hit rate over time, cumulative cost
- **Sessions & Activity** — sessions started, unique sessions, active time, lines of code, commits, PRs, LOC (added vs removed), active time (user vs CLI), tool decisions (accept/reject)
- **MLflow Trace Metrics** — total traces, total LLM calls, avg agent span duration, avg LLM call duration, span duration over time, LLM latency distribution (p50/p90/p99)
- **Container Resources** — memory usage (working set vs requested), CPU requests, pod restarts, memory over time, network I/O (received/transmitted)

**Manifests:**

| File | Purpose |
|---|---|
| `observability/otel/collector.yaml` | OTEL Collector ConfigMap + Deployment |
| `observability/otel/service.yaml` | ClusterIP Service (OTLP + Prometheus ports) |
| `observability/otel/servicemonitor.yaml` | ServiceMonitor for Prometheus scrape on :8889 |
| `observability/dashboards/agent-metrics.json` | Grafana dashboard JSON |

---

## 2. Model observability

vLLM exposes 97 native Prometheus metrics on its `/metrics` endpoint (port 8080). These cover the full inference runtime — request queues, token throughput, latency at every stage, KV cache pressure, GPU utilization proxies.

**Data path:**

```
vLLM :8080/metrics → ServiceMonitor → Prometheus (user workload monitoring) → Thanos Querier → Grafana
```

**Key metrics by category:**

| Category | What it shows | Key metrics |
|---|---|---|
| **Model & Usage** | Which model, how much it's used | `model_name`, prompt/generation tokens, avg tokens/request, requests by `finished_reason` |
| **Latency** | How fast responses are | TTFT, inter-token latency, end-to-end (p50/p95/p99), queue wait, prefill, decode |
| **Cache** | How efficiently the cache works | KV cache usage %, prefix cache hit rate |
| **Throughput** | How much work the model does | Prompt tokens/s, generation tokens/s, request rate |
| **Engine** | Internal runtime state | Requests running/waiting, preemptions, engine sleep state |
| **Process** | System resource usage | RSS/virtual memory, CPU cores, iteration tokens |

**Dashboard:** "AgentOps — Inference Metrics (vLLM)" in Grafana

**Manifests:**

| File | Purpose |
|---|---|
| `inference/vllm/manifests/servicemonitor.yaml` | ServiceMonitor (scrape every 15s) |
| `observability/dashboards/inference-metrics.json` | Grafana dashboard JSON |

---

## 3. Shared infrastructure

### Prometheus backend — OpenShift user workload monitoring

Both agent and model metrics flow through OpenShift's built-in Prometheus, not a standalone instance. See [ADR-021](adrs/021-user-workload-monitoring-over-standalone-prometheus.md).

**Setup:** `enableUserWorkload: true` in `cluster-monitoring-config` ConfigMap (namespace `openshift-monitoring`).

**Discovery:** ServiceMonitor / PodMonitor CRDs — Prometheus auto-discovers scrape targets in any namespace.

### Grafana

Grafana runs in the `observability` namespace and queries the Thanos Querier.

**Auth:** ServiceAccount `grafana` with `cluster-monitoring-view` ClusterRole. Bearer token injected into the datasource ConfigMap.

**Manifests:**

| File | Purpose |
|---|---|
| `observability/grafana/deployment.yaml` | Grafana Deployment |
| `observability/grafana/service.yaml` | ClusterIP Service |
| `observability/grafana/route.yaml` | TLS edge Route |
| `observability/grafana/rbac.yaml` | ServiceAccount + ClusterRoleBinding |
| `observability/grafana/configmap-datasources.yaml` | Thanos Querier datasource (bearer token) |
| `observability/grafana/configmap-dashboards.yaml` | Dashboard provider config |

**Access:** `https://grafana-observability.apps.<cluster>/` (anonymous read via `GF_AUTH_ANONYMOUS_ENABLED=true`)

### NetworkPolicy

| Source | Destination | Port | Why |
|---|---|---|---|
| `agent-sandboxes` | `observability` | 5000 | MLflow traces |
| `agent-sandboxes` | `observability` | 4318 | OTLP metrics push |
| `openshift-user-workload-monitoring` | `inference` | 8080 | Prometheus scrapes vLLM |
| `openshift-user-workload-monitoring` | `observability` | 8889 | Prometheus scrapes OTEL Collector |
| `observability` | `openshift-monitoring` | 9091 | Grafana queries Thanos Querier |

All rules defined in `infra/cluster/namespaces/network-policies.yaml`.

---

### 1.3 Events/Logs — OTel → OTEL Collector → debug

Claude Code emits structured events (prompt events, tool results, API errors) via the OTel Logs SDK. These are pushed to the OTEL Collector and currently exported via the `debug` exporter (visible in `oc logs deploy/otel-collector -n observability`).

**Configuration:**

```yaml
OTEL_LOGS_EXPORTER: "otlp"
OTEL_EXPORTER_OTLP_LOGS_PROTOCOL: "http/protobuf"
OTEL_EXPORTER_OTLP_LOGS_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4318/v1/logs"
```

**Limitation:** Logs are only visible in the collector's stdout. A proper queryable backend (Loki, Elasticsearch) is needed for production use. See Sprint D.3 in [FUTURE_EXPLORATIONS.md](FUTURE_EXPLORATIONS.md).

---

## 4. What's not implemented yet

| Feature | Why | When |
|---|---|---|
| GPU metrics (DCGM) | Requires DCGM exporter on GPU nodes | When GPU utilization debugging is needed |
| Client/caller breakdown | vLLM doesn't tag by caller; agent OTel has `session_id` but no user identity | With SPIFFE/Kagenti identity layer |
| Queryable logs backend | Events/logs flow to OTEL Collector but export to `debug` (stdout only) | When Loki or Elasticsearch is deployed |
| OTel traces (beta) | `OTEL_TRACES_EXPORTER` not configured — distributed tracing from prompt → tools → LLM | When debugging cross-component latency |
| `OTEL_RESOURCE_ATTRIBUTES` | Custom labels for team/cost-center segmentation | Multi-tenant setup |
| Alerting | No `PrometheusRule` CRDs defined | When SLOs are established |
| Runbooks | No troubleshooting guides for "serving slow" / "GPU saturated" | After operational experience |
