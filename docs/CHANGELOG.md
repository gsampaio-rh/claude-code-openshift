# Changelog: AgentOps Platform

Release notes for completed work across sprints and exploration phases.

**Related:** [PLAN.md](PLAN.md) (pending work) | [ADRs](adrs/) | [ARCHITECTURE.md](ARCHITECTURE.md)

---

## Sprint 1 — Infrastructure + Inference + Standalone Agent

**Date:** 2026-04-08 – 2026-04-10
**PRD Phases:** 0, 1, 1a
**Status:** Complete (all gates passed)

Validated the OpenShift cluster (OCP 4.20.17), installed operators (GPU, NFD, cert-manager, Sandboxed Containers), provisioned GPU and bare metal nodes, deployed upstream vLLM with Qwen 2.5 14B, and ran Claude Code standalone in a Kata MicroVM. The model go/no-go checkpoint passed — Qwen 14B produces correct, well-typed Python code.

### Key Outcomes

- **Cluster:** 7 namespaces, NetworkPolicies, ResourceQuotas, RBAC configured
- **Inference:** vLLM v0.19.0 serving Qwen 2.5 14B Instruct FP8-dynamic on NVIDIA L40S 48GB. Both OpenAI (`/v1/chat/completions`) and Anthropic (`/v1/messages`) APIs validated
- **Agent:** Claude Code v2.1.96 on UBI9/Node.js 22, running in Kata MicroVM on bare metal (m5.metal). Latency: 2.1s (math), 7.2s (function), 26.3s (class)
- **Kata:** Sandboxed Containers Operator v1.3.3 on bare metal — EC2 VMs don't support `/dev/kvm` (ADR-017)
- **Go/no-go:** GO — Qwen 14B produces functional code with type hints

### Decisions

| ADR | Decision |
|-----|----------|
| [ADR-011](adrs/011-upstream-vllm-over-rhaiis.md) | Upstream vLLM over RHAIIS (no Anthropic Messages API) |
| [ADR-012](adrs/012-plain-deployment-over-kserve.md) | Plain Deployment+Service over KServe ServingRuntime |
| [ADR-013](adrs/013-networkpolicy-corrections.md) | NetworkPolicy corrections (DNS, agent-to-vLLM) |
| [ADR-014](adrs/014-pvc-for-model-cache.md) | PVC for model cache (persist 16GB model across restarts) |
| [ADR-016](adrs/016-gpu-scaling-l40s.md) | GPU scaling L4 to L40S, context window adjustments |
| [ADR-017](adrs/017-kata-containers-for-agent-isolation.md) | Kata requires bare metal (EC2 VMs lack /dev/kvm) |
| [ADR-018](adrs/018-osc-monitor-selinux-bug.md) | osc-monitor SELinux bug workaround |

### Notable Problems Solved

- Dockerfile PATH mismatch with UBI nodejs-22 (`HOME=/opt/app-root/src`)
- Build pod OOM at 1Gi — Claude Code install needs 4Gi
- NetworkPolicy blocking DNS and agent-to-vLLM connectivity
- Context window overflow with 4096 output tokens — tuned to match model limits
- EC2 VMs don't expose `/dev/kvm` — provisioned bare metal m5.metal
- `c5.metal` insufficient capacity in us-east-2a/b — switched to m5.metal in us-east-2c

### Gates Passed

| # | Criterion | Status |
|---|-----------|--------|
| G1.1 | All operators Succeeded | PASS |
| G1.2 | KataConfig ready on nodes | PASS |
| G1.3 | vLLM responding on both APIs | PASS |
| G1.4 | Claude Code standalone talks to vLLM | PASS |
| G1.5 | Latency < 5s for simple prompt | PASS (2.1s) |
| G1.6 | Go/no-go: generated code is functional | GO |
| G1.7 | Namespaces and NetworkPolicies created | PASS |

---

## Sprint 2 — Observability + UI + Multi-Agent (partial)

**Date:** 2026-04-10 – 2026-04-14
**PRD Phases:** 7 (observability), 2 (safety — pending), 3 (CDE — pending)
**Status:** In progress (observability, UI, multi-agent complete; guardrails and Coder pending)

### Completed: Sprint 1 Hardening (2.0)

- Egress NetworkPolicy for `inference` namespace (DNS + HuggingFace 443 only)
- Migrated model cache from `emptyDir` to PVC 30Gi gp3-csi
- Removed temporary NetworkPolicies
- Rebuilt Claude Code image with corrected PATH

### Completed: GPU Scaling (2.0a, ADR-016)

- Provisioned g6e.4xlarge with NVIDIA L40S 48GB
- Reconfigured vLLM: `max_model_len=32768`, `gpu-memory-utilization=0.90`
- Changed Deployment strategy to `Recreate` (EBS RWO doesn't support multi-attach)
- Increased inference quota to 128Gi memory, 32 CPU
- E2E validated: 22K input tokens, 594 output tokens, ~23s

### Completed: Kata on Bare Metal (2.0b, ADR-017/018)

- Validated EC2 VMs lack `/dev/kvm` — provisioned m5.metal (96 vCPU, 384GB RAM)
- Installed Sandboxed Containers Operator v1.3.3, KataConfig CR, RuntimeClass `kata`
- Claude Code running in Kata MicroVM on bare metal — E2E validated
- Fixed context overflow: `MAX_OUTPUT_TOKENS` 16384 exceeded window by 1 token, reduced to 8192

### Completed: Observability Stack (2.1)

Full observability pipeline deployed and validated:

- **MLflow Tracking Server v3.10.1** — native Claude Code tracing via `mlflow autolog claude` (tool calls, tokens, conversations). Accessible via Route with edge TLS.
- **OTel Collector** — receives Claude Code OTLP metrics, exports to Prometheus via `:8889`
- **Grafana OSS 11.5.2** — two dashboards:
  - "Inference Metrics (vLLM)" — 5 sections: Model & Usage, Request Overview, Latency, Cache & Engine, Process & System. Validated under 25-request load test.
  - "Agent Metrics (Claude Code)" — 42 panels across 5 sections: Token Usage, Derived Efficiency, Sessions & Activity, MLflow Traces, Container Resources.
- **User workload monitoring** enabled — ServiceMonitor scrapes 97 vLLM metrics at 15s intervals
- **OTel events/logs** — `OTEL_LOGS_EXPORTER=otlp` sends agent events to collector (debug exporter)

Key architecture decision: OTLP push to OTel Collector (not Prometheus pull) because Claude Code sessions are ephemeral — the Prometheus exporter HTTP server dies when `claude` exits.

### Completed: UI Evaluation and Deployment (2.1.2)

Four community tools evaluated for Claude Code UI/observability:

| Tool | Stars | Outcome |
|------|-------|---------|
| **opcode** | 21.5k | Abandoned — desktop app, requires co-location with `claude` binary |
| **claude-code-hooks-multi-agent-observability** | 1.4k | Abandoned — hook pipeline worked, Vue UI inadequate for enterprise |
| **agent-flow** | 665 | Abandoned — discovery-based hook port incompatible with sidecar networking |
| **agents-observe** | 435 | **Adopted** — React 19 + Hono + SQLite, 12 hook events, subagent hierarchy |

**agents-observe** deployed and validated:
- Initially as sidecar (ADR-022), **decoupled to standalone Deployment** (ADR-024) for independent lifecycle
- 65+ events captured, up to 4 simultaneous subagents, 5 sessions
- WSS patched for OpenShift edge TLS, NetworkPolicy configured for inter-pod communication
- Bug fix: `send_event.sh` background subshell was killed before HTTP request completed — fixed with synchronous execution and `process.exit(0)`

**claude-devtools** deployed as sidecar:
- Built in-cluster via BuildConfig (ADR-023)
- Mounted `~/.claude/` read-only, accessible via Route

### Completed: Multi-Agent and Model Upgrade

- **Agent Teams** enabled (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`), tested with up to 5 simultaneous subagents and 40 events per session
- **gpt-oss-20b** deployed and validated — Claude Code producing functional code with subagents

### Decisions

| ADR | Decision |
|-----|----------|
| [ADR-019](adrs/019-observability-otel-mlflow-grafana.md) | Observability stack: MLflow native + OTel for metrics |
| [ADR-020](adrs/020-trace-metadata-enrichment.md) | Per-trace metadata enrichment disabled (disproportionate for single-agent) |
| [ADR-021](adrs/021-user-workload-monitoring-over-standalone-prometheus.md) | User workload monitoring over standalone Prometheus |
| [ADR-022](adrs/022-agents-observe-hook-sidecar.md) | agents-observe hook sidecar (superseded by ADR-024) |
| [ADR-023](adrs/023-internal-registry-builds-for-sidecars.md) | Internal registry builds for sidecars |
| [ADR-024](adrs/024-decouple-agents-observe-from-sidecar.md) | Decouple agents-observe from sidecar to standalone deployment |

### Notable Problems Solved

- OTel Collector crashloop: `health_check` extension not configured
- MLflow v3 OOMKilled at 1Gi: spawns huey workers, increased to 2Gi
- MLflow `--allowed-hosts` security middleware: must include all Route/service hostnames
- `OTEL_EXPORTER_OTLP_ENDPOINT` hijacks MLflow's internal OTel SDK: use metrics-specific endpoint instead
- `opentelemetry-exporter-otlp-proto-http` required in agent image for MLflow span context
- `OTEL_METRICS_EXPORTER=prometheus` doesn't work for ephemeral sessions: exporter HTTP server dies with process
- agents-observe `send_event.sh` background subshell killed before HTTP request completed

---

## Sprint 1.5 — UI/Observability Adoption + Task Management Evaluation

**Date:** 2026-04-14 – 2026-04-16
**Status:** Complete

Validated and adopted UI/observability sidecars (claude-devtools, claude-task-viewer), evaluated and discarded all third-party task management tools in favor of structured `.claude` rules/skills, upgraded inference to gpt-oss-20b, and configured headless agent permissions and task system.

### Key Outcomes

- **claude-devtools** adopted as sidecar — session transcript viewer, sharing `claude-sessions` volume
- **agents-observe** adopted as standalone Deployment — hook-based observability dashboard
- **claude-task-viewer** adopted as sidecar — read-only Kanban board for Tasks v2 files (`~/.claude/tasks/`), port 3457
- **Tasks v2** enabled in headless mode via `CLAUDE_CODE_ENABLE_TASKS=1` — agent creates persistent task JSON files
- **Headless permissions** configurable via `CLAUDE_PERMISSION_MODE` env var — no image rebuild needed
- **Development workflow** codified in `.claude/rules/` and `.claude/skills/` (cloned from [rules-skills](https://github.com/gsampaio-rh/rules-skills))
- **gpt-oss-20b** deployed and validated on L40S GPU

### Multi-Agent Task Management — Evaluated & Discarded

| Tool | Category | Outcome |
|------|----------|---------|
| Taskmaster | MCP task manager | Integrated → rolled back (context window overflow, excessive tool surface) |
| Backlog.md | MCP + Kanban UI | Integrated → rolled back (requires git init, interactive prompts, fragile MCP) |
| agi-le | Agile CLI | Discarded (single-agent, no headless support) |
| vibe-kanban | Kanban board | Discarded (standalone app, no agent integration) |
| agtx | Agent task executor | Discarded (early stage, insufficient docs) |
| Superpowers | Agent framework | Discarded (opinionated workflow, does not fit) |
| OpenSpec | Spec generator | Discarded (spec-only, no task tracking) |
| spec-kit | Spec toolkit | Discarded (GitHub-native, no OpenShift integration) |
| Scrumboy | Scrum board | Discarded (web app, no MCP) |
| Planka | Kanban board | Discarded (standalone, no agent integration) |

**Decision:** Structured `.claude` rules and skills provide the same workflow enforcement with zero extra infrastructure. See [ADR-025](adrs/025-structured-claude-rules-over-task-management-tools.md).

### Decisions

| ADR | Decision |
|-----|----------|
| [ADR-025](adrs/025-structured-claude-rules-over-task-management-tools.md) | Structured `.claude` rules over third-party task management tools |
| [ADR-026](adrs/026-enable-tasks-v2-headless.md) | Enable Tasks v2 in headless mode via `CLAUDE_CODE_ENABLE_TASKS=1` |
| [ADR-027](adrs/027-claude-task-viewer-sidecar.md) | claude-task-viewer as sidecar for task observability |

### Notable Problems Solved

- `TodoWrite` vs `Tasks v2` in headless mode — `isTodoV2Enabled()` returns false in non-interactive sessions, fixed with env var
- `CLAUDE_PERMISSION_MODE` env var — avoids image rebuild for permission changes
- npm `EACCES` in OpenShift (arbitrary UID) — pre-create `.npm` cache with group-write permissions
- Backlog.md `backlog init` requires git repo with user config — fragile in ephemeral containers
- Context window overflow (32K) with verbose MCP tool schemas — shorter prompts or fewer tools needed
- gpt-oss-20b does not spontaneously create tasks/workflow docs — requires explicit instruction for complex workflows

---

## Exploration Sprint A — Inference Observability (vLLM)

**Date:** 2026-04-13
**Status:** Complete

Enabled user workload monitoring on the cluster, created a ServiceMonitor for vLLM (97 native metrics at 15s intervals), re-enabled Grafana with Thanos Querier datasource, and built the "Inference Metrics (vLLM)" dashboard with 5 sections covering model usage, request overview, latency (TTFT, ITL, E2E), cache, and process health. Validated under a 25-request load test.

---

## Exploration Sprint C — Agent OTel Metrics

**Date:** 2026-04-13
**Status:** Complete

Enabled Claude Code telemetry (`CLAUDE_CODE_ENABLE_TELEMETRY=1`), re-enabled OTel Collector in metrics-only mode, and built the "Agent Metrics (Claude Code)" dashboard with 42 panels across 5 sections: token usage, derived efficiency metrics (cache hit rate, cost/session, LOC/1K tokens), sessions & activity, MLflow trace metrics, and container resources. Key architecture decision: OTLP push (not Prometheus pull) because Claude Code sessions are ephemeral.

Metrics captured: `claude_code_token_usage_tokens_total`, `claude_code_cost_usage_USD_total`, `claude_code_session_count_total`, `claude_code_lines_of_code_count_total`, `claude_code_commit_count_total`, `claude_code_pull_request_count_total`, `claude_code_code_edit_tool_decision_total`, `claude_code_active_time_total_s_total`.
