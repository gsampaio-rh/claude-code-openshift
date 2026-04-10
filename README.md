# AgentOps Platform — Claude Code on OpenShift

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) as a coding agent on OpenShift with local inference, hardware-level isolation, and enterprise safety controls.

## What This Is

A PoC that validates the full Red Hat AI AgentOps stack:

- **Local inference** — vLLM v0.19.0 serving Qwen 2.5 14B FP8 on GPU (no cloud API dependency)
- **MicroVM isolation** — Kata Containers on bare metal for kernel-level agent sandboxing
- **Safety guardrails** — TrustyAI intercepting inputs/outputs for PII detection and content filtering
- **Identity** — SPIFFE/Kagenti for cryptographic agent identity (planned)
- **Tool governance** — MCP Gateway with policy-based access control (planned)
- **Observability** — MLflow Tracking Server with native `mlflow autolog claude` for agent tracing
- **CI/CD safety** — Tekton + Garak adversarial scanning before model deployment (planned)
- **Developer CDE** — Coder workspaces with Claude Code pre-configured (planned)

## Architecture

```
Developer → Coder Workspace (Kata MicroVM)
               ├── Claude Code CLI
               ├── → TrustyAI Guardrails → vLLM (Qwen 14B, local GPU)
               ├── → MCP Gateway (tools filtered by identity)
               └── → MLflow (traces via mlflow autolog claude)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full architecture diagram.

## Current Status

| Sprint | Scope | Status |
|--------|-------|--------|
| 1 | Infra + vLLM + Claude Code standalone | **Complete** |
| 2 | Observability + Safety (TrustyAI) + Coder CDE | In progress |
| 3 | Kata integration + Kagenti identity | Planned |
| 4 | MCP Gateway | Planned |
| 5 | CI/CD + End-to-end integration | Planned |

Sprint 1 gates passed: cluster validated (OCP 4.20), vLLM serving on L40S GPU, Claude Code running in Kata microVM on bare metal, model go/no-go approved.

See [docs/PLAN.md](docs/PLAN.md) for the detailed sprint plan.

## Repository Structure

```
├── docs/                   # PRD, architecture, sprint plan, ADRs
│   ├── PRD.md              # Product requirements
│   ├── ARCHITECTURE.md     # System architecture
│   ├── PLAN.md             # Sprint plan with task status
│   └── adrs/               # Architecture Decision Records (019 decisions)
├── infra/
│   ├── cluster/            # Operators, namespaces, RBAC, quotas, Kata, MachineSets
│   ├── vllm/               # vLLM deployment manifests and scripts
│   ├── claude-code/        # Agent image (UBI9 + Node.js 22 + Claude Code CLI)
│   ├── guardrails/         # TrustyAI Guardrails Orchestrator
│   └── scripts/            # deploy-all.sh, e2e-test.sh
├── observability/
│   ├── otel/               # OTEL Collector (disabled — kept for future use)
│   ├── mlflow/             # MLflow Tracking Server (deployment, service, PVC, route)
│   ├── prometheus/         # Prometheus (disabled — kept for future use)
│   ├── grafana/            # Grafana (disabled — kept for future use)
│   ├── dashboards/         # Grafana dashboard JSON (disabled — kept for future use)
│   └── scripts/            # 01-deploy-observability.sh, 99-verify.sh, config.sh
└── .env.example            # Environment template (copy to .env)
```

## Quick Start

### Prerequisites

- OpenShift 4.16+ cluster with admin access
- GPU node (NVIDIA L40S or L4)
- Bare metal node for Kata (e.g., `m5.metal` on AWS)
- `oc` CLI logged in

### Setup

```bash
cp .env.example .env
# Edit .env with your cluster-specific values

# Full deployment (cluster → Kata → vLLM → Claude Code → E2E test)
./infra/scripts/deploy-all.sh

# Or deploy individual components
./infra/cluster/scripts/00-preflight-check.sh
./infra/vllm/scripts/01-deploy-model.sh
./infra/claude-code/scripts/01-deploy-standalone.sh

# Deploy observability (MLflow)
./observability/scripts/01-deploy-observability.sh
./observability/scripts/99-verify.sh
```

### Verify

```bash
# Validate vLLM model serving
./infra/vllm/scripts/02-validate-model.sh

# Test Claude Code agent
oc exec deploy/claude-code-standalone -n agent-sandboxes -- claude -p "What is 2+2?"

# Full end-to-end test
./infra/scripts/e2e-test.sh
```

## Documentation

- [PRD](docs/PRD.md) — Problem statement, phased delivery, acceptance criteria
- [Architecture](docs/ARCHITECTURE.md) — System layers, namespace layout, component contracts
- [Sprint Plan](docs/PLAN.md) — Task checklist with status per sprint
- [Infrastructure Requirements](docs/infrastructure-requirements.md) — Cluster/GPU/bare-metal sizing
- [ADRs](docs/adrs/) — Architecture Decision Records (019 decisions documented)

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Platform | OpenShift 4.16+ |
| Inference | vLLM v0.19.0 + Qwen 2.5 14B Instruct FP8 |
| Agent | Claude Code CLI on UBI9 + Node.js 22 |
| Isolation | OpenShift Sandboxed Containers (Kata) on bare metal |
| Safety | TrustyAI Guardrails Orchestrator |
| CDE | Coder v2 (planned) |
| Identity | Kagenti + SPIFFE/SPIRE (planned) |
| Tool governance | MCP Gateway + Kuadrant (planned) |
| Observability | MLflow v3 (native `mlflow autolog claude`) |
| CI/CD | Tekton + Garak (planned) |
