# ADR-021: User Workload Monitoring over Standalone Prometheus

**Status:** Accepted
**Date:** 2026-04-13
**Deciders:** Platform Engineering

## Context

The PoC needs Prometheus metrics for two sources:

1. **vLLM inference** — 97 native metrics exposed on `/metrics` (tokens, latency,
   KV cache, queue depth, etc.)
2. **Claude Code agent** — 8 metrics pushed via OTLP through the OTEL Collector
   (token usage, cost, sessions, lines of code, commits, PRs, tool decisions,
   active time)

Sprint 2 deployed a **standalone Prometheus** (`observability/prometheus/`) that
scraped the OTEL Collector's spanmetrics. When OTEL/Grafana were disabled in favor
of MLflow-only, this Prometheus became dead weight.

Re-enabling observability for Sprint A (vLLM) and Sprint C (agent) required
choosing a Prometheus backend.

## Decision

Use **OpenShift user workload monitoring** (`enableUserWorkload: true` in
`cluster-monitoring-config`) instead of deploying a standalone Prometheus.

Grafana queries the **Thanos Querier** (`openshift-monitoring:9091`) with a
ServiceAccount bearer token bound to the `cluster-monitoring-view` ClusterRole.

## Rationale

| Criterion | Standalone Prometheus | User Workload Monitoring |
|---|---|---|
| Deployment | Manual (Deployment + PVC + ConfigMap) | Built-in (one ConfigMap toggle) |
| HA / retention | Single replica, no persistence by default | Managed by cluster, retention policies, Thanos for HA |
| Service discovery | Static `scrape_configs` in ConfigMap | Automatic via ServiceMonitor / PodMonitor CRDs |
| Cross-namespace | Requires manual DNS targets | Native — Prometheus discovers all namespaces |
| RBAC | No auth on query endpoint | Bearer token + `cluster-monitoring-view` |
| Maintenance | We own upgrades, storage, alerting | Red Hat manages it |
| Resource cost | Extra Deployment + PVC in observability ns | Zero — already running for platform monitoring |

The standalone approach adds operational burden with no benefit over the built-in
stack. The only trade-off is that Grafana needs a bearer token for Thanos Querier
(solved with a ServiceAccount + ClusterRoleBinding).

## Implementation

### vLLM metrics (direct scrape)

```
vLLM :8080/metrics → ServiceMonitor → Prometheus (user workload) → Thanos Querier → Grafana
```

- `infra/vllm/manifests/servicemonitor.yaml` — scrape every 15s
- NetworkPolicy: `openshift-user-workload-monitoring` → `inference:8080`

### Agent metrics (OTLP push)

```
Claude Code → OTLP → OTEL Collector :8889/metrics → ServiceMonitor → Prometheus → Thanos → Grafana
```

- `observability/otel/servicemonitor.yaml` — scrape every 30s
- NetworkPolicy: `agent-sandboxes` → `observability:4318` (OTLP push),
  `openshift-user-workload-monitoring` → `observability:8889` (scrape)

### Grafana datasource

- Points to `https://thanos-querier.openshift-monitoring.svc.cluster.local:9091`
- Auth: bearer token from ServiceAccount `grafana` with `cluster-monitoring-view`
- `observability/grafana/rbac.yaml` — ServiceAccount + ClusterRoleBinding

## Consequences

- **Standalone Prometheus removed** — `observability/prometheus/` deleted.
- **ServiceMonitor/PodMonitor required** — each scrape target needs a CR instead of
  a static `scrape_configs` entry. More declarative, but requires understanding the
  CRD model.
- **NetworkPolicy complexity** — Prometheus runs in `openshift-user-workload-monitoring`,
  which is outside our control. Ingress rules must reference that namespace by label.
- **Bearer token management** — the Grafana ServiceAccount token must be created and
  injected into the datasource ConfigMap. Currently done manually; could be automated
  with a CronJob or the Grafana Operator.
- **No standalone alerting** — alerting would use `PrometheusRule` CRDs in the user
  workload stack, not standalone Alertmanager config.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Standalone Prometheus in `observability` ns | Extra resource cost, manual HA, duplicates built-in capability |
| Grafana Mimir / Cortex | Overkill for PoC; multi-tenant long-term storage not needed yet |
| Prometheus remote-write from agent pods | User workload monitoring doesn't accept remote-write from user apps |
| Victoria Metrics | Non-standard in OpenShift ecosystem; no operator support |
